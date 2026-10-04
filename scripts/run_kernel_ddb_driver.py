#!/usr/bin/env python3
"""Send a real QEMU serial BREAK, inspect through DDB, then prove resume."""

import argparse
import json
from pathlib import Path
import re
import socket
import os
import subprocess
import time

from await_timing import AwaitTiming

from run_kernel_uart_driver import (
    QMP_CHARDEV, postmortem_budget, send_serial_break)

# GitHub issue #9's peer-read stall. The scripted BREAK below waits for
# fixtures that, one run in five, never start, so a lost run ended as a bare
# timeout with nothing to read. Past the point where the lane cannot pass,
# this breaks in anyway and walks read-only commands, the way the ordinary
# lanes' driver does (#511): run_kernel_uart_driver.py's walk, plus the
# waiting graph, the physical stacks and the peer's own root, which are what
# says why a workload handoff never happened.
STALL_COMMANDS = (b"oops", b"intr", b"bt", b"sched", b"current", b"ps",
                  b"wait", b"stacks", b"bt cpu 1")


# The first caught stall answered the postmortem BREAK with `world-stop
# partial mask=0`: the peer never took the stop SGI, so DDB refused and the
# walk above had nothing to read. QEMU still knows where each CPU is. Sample
# every CPU's registers a few times before the BREAK: a PC that never moves
# and one that circles a loop are different defects, and PSTATE says whether
# IRQs were masked there.
REGISTER_SAMPLES = 3


def sample_cpu_registers(port: int, budget: float) -> tuple[str, str]:
    """Return (raw dump, one-line summary); failures are reported, not raised."""
    deadline = time.monotonic() + budget
    dumps = []
    try:
        with socket.create_connection(("127.0.0.1", port), budget) as qmp:
            qmp.settimeout(max(0.5, deadline - time.monotonic()))
            stream = qmp.makefile("rwb", buffering=0)
            if b"QMP" not in stream.readline():
                return "", "QMP produced no greeting"
            stream.write(b'{"execute":"qmp_capabilities"}\n')
            if b"return" not in stream.readline():
                return "", "QMP capability negotiation failed"
            for _ in range(REGISTER_SAMPLES):
                stream.write(
                    b'{"execute":"human-monitor-command","arguments":'
                    b'{"command-line":"info registers -a"}}\n')
                reply = json.loads(stream.readline())
                if "return" not in reply:
                    return "\n".join(dumps), f"QMP refused: {reply!r:.160}"
                dumps.append(reply["return"])
                time.sleep(0.1)
    except (OSError, ValueError) as error:
        return "\n".join(dumps), f"register sampling failed: {error}"
    samples = []
    for dump in dumps:
        cpus = re.findall(r"CPU#(\d+).*?PC=([0-9a-f]+).*?PSTATE=([0-9a-f]+)",
                          dump, re.S)
        samples.append(" ".join(f"cpu{cpu} pc={pc} pstate={pstate}"
                                for cpu, pc, pstate in cpus))
    return "\n".join(dumps), "; ".join(samples)


def connect(port: int, deadline: float) -> socket.socket:
    while time.monotonic() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", port), 0.5)
        except OSError:
            time.sleep(0.05)
    raise SystemExit(f"tcp/{port} did not accept a connection")


def send_paced(serial, data: bytes) -> None:
    # One byte at a time, like typed input: the kernel's RX interrupt takes
    # one byte each, and a burst longer than the 16-byte PL011 FIFO would
    # drop its tail.
    for value in data:
        serial.sendall(bytes((value,)))
        time.sleep(0.01)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serial-port", type=int, required=True)
    parser.add_argument("--qmp-port", type=int, required=True)
    parser.add_argument("--break-source", choices=("uart", "software"), default="uart")
    parser.add_argument("--gdb-port", type=int)
    parser.add_argument("--elf")
    parser.add_argument("--kernel-address", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--snapshot-ready-file")
    parser.add_argument("--snapshot-release-file")
    parser.add_argument("--network-ready-file", required=True)
    parser.add_argument("--foreground-listener-file", required=True)
    parser.add_argument("--init-listener-file", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--await-timing-log",
                        help="JSONL UART observations against the existing driver deadline")
    args = parser.parse_args()
    if ((args.snapshot_ready_file is None)
            != (args.snapshot_release_file is None)):
        raise SystemExit(
            "snapshot ready and release files must be supplied together")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    started = time.monotonic()
    deadline = started + args.timeout
    return drive(args, started, deadline)


def drive(args, started, deadline):
    ready_file = (
        Path(args.snapshot_ready_file) if args.snapshot_ready_file else None
    )
    release_file = (
        Path(args.snapshot_release_file) if args.snapshot_release_file else None
    )
    network_ready_file = Path(args.network_ready_file)
    foreground_listener_file = Path(args.foreground_listener_file)
    init_listener_file = Path(args.init_listener_file)
    for marker in (network_ready_file, foreground_listener_file,
                   init_listener_file):
        marker.unlink(missing_ok=True)
    if ready_file is not None:
        ready_file.unlink(missing_ok=True)
        release_file.unlink(missing_ok=True)

    commands = [
        b"oops\n", b"regs\n", b"intr\n", b"sched\n",
        b"current\n", b"vm\n", b"fds\n",
        b"ps\n", b"stacks\n", b"wait\n", b"waittest\n", b"proc 1\n",
        b"bt\n", b"bt 1\n", b"bt 0\n", b"bt 999999\n",
        b"bt cpu 1\n", b"bt cpu 9\n", b"bt cpu x\n", b"bttest\n",
        b"trace\n", b"events\n", b"unimpl\n",
        f"xk {args.kernel_address} 2\n".encode("ascii"),
        b"xk ffffffffffffffff 2\n", b"xk 0 0\n",
        b"xk 1000000000 1\n", b"xkfault\n",
        f"xp {args.kernel_address} 2\n".encode("ascii"),
        b"xp 1000000000 1\n",
        b"xu 1 80000000 2\n", b"xu 1 80000fff 2\n",
        b"xu 1 ffffffffffffffff 2\n", b"xu 1 80000000 65\n",
        b"xu 999999 80000000 1\n", b"xu 1 70000000 1\n",
        b"help\n",
        b"continue\n",
    ]

    awaited = [b"ddb: continuing\n", b"init: ash bootstrap\n"]
    if args.break_source == "uart":
        awaited += [
            b"persistent shell: uart blocked\n",
            b"interactive shell: uart blocked\n",
            b"workload: busy pair done\n",
            b"persistent server: listener ready port=8080\n",
            b"workload: busy pair migrated across both cpus with stack handoff intact\n",
            b"workload: peer console accepted all 1071 bytes through the shared queue after ordered writes on both CPUs\n",
            b"workload: peer tty reading the terminal on the secondary cpu\n",
            b"ddb: console lock probe phase=2 release=",
            b"workload: peer tty read its 17-byte line",
        ]
    timing = AwaitTiming(args.await_timing_log, started, args.timeout, awaited,
                         commands[:-1], label="kernel/qemu ddb")
    observers = [timing]
    try:
        serial = connect(args.serial_port, deadline)
        timing.record("UART connection", True, time.monotonic())
        serial.settimeout(0.25)
        return capture_loop(args, serial, deadline, ready_file, release_file,
                       network_ready_file, foreground_listener_file, init_listener_file,
                       awaited, commands, timing, observers)
    finally:
        for observer in observers:
            observer.finish(time.monotonic())


def capture_loop(args, serial, deadline, ready_file, release_file, network_ready_file,
                 foreground_listener_file, init_listener_file, awaited, commands, timing, observers):
    received = bytearray()
    break_sent = args.break_source == "software"
    wake_byte_sent = args.break_source == "software"
    prompt_count = 0
    migration_context_sent = False
    peer_tty_sent = False
    peer_alias_queries = None
    peer_tty_reading_at = None
    peer_tty_line_sent = False
    stall_break_at = None
    stall_sent = 0
    stall_reason = ""
    stall_registers = ""
    payload_sent = False
    post_timing = None
    post_prompt_base = 0

    with serial, open(args.log, "wb") as log:
        while time.monotonic() < deadline:
            try:
                chunk = serial.recv(4096)
            except socket.timeout:
                chunk = None
            if chunk == b"":
                break
            if chunk is not None:
                arrived_at = time.monotonic()
                received.extend(chunk.replace(b"\r", b""))
                log.write(chunk)
                log.flush()
                observer = post_timing or timing
                if post_timing is None:
                    for i, marker in enumerate(awaited):
                        if marker in received:
                            timing.record(f"await-line {i + 1}", True, arrived_at)
                observed_prompts = received.count(b"ddb> ") - post_prompt_base
                for name in observer.prompt_names[:observed_prompts]:
                    observer.record(name, True, arrived_at)

            # BusyBox's cursor query (ESC[6n) follows every prompt, so its
            # count marks a new prompt. It is not answered: a late reply
            # lands in the next command (GitHub issue #644).
            queries = received.count(b"\x1b[6n")

            if (args.break_source == "uart" and peer_alias_queries is None and
                    b"persistent shell: uart blocked\n" in received):
                # Prepare the peer reader while the ordinary console is
                # live. The late guard hold begins only before BREAK.
                peer_alias_queries = queries
                send_paced(serial, b"alias p=/bin/peer-tty\n")

            # Drive the two producers in an evidence-backed order rather than
            # guessing how much host sleep lets the guest run. The marker says
            # the interactive shell has published its UART wait. Submit the
            # ordinary byte first and QEMU's out-of-band BREAK second; the
            # event-ring assertions below prove that the guest actually
            # recorded wake before BREAK.
            if (not wake_byte_sent and
                    b"interactive shell: uart blocked\n" in received):
                # The UART-BREAK lane now stops during the maintained
                # migration workload. Leave this first interactive shell so
                # init can reach the busy pair; a bare newline would wake the
                # read and immediately park at the same prompt forever.
                serial.sendall(b"exit\n")
                wake_byte_sent = True

            if (not network_ready_file.exists() and
                    b"virtio net: link ready " in received):
                network_ready_file.touch()
            if (not foreground_listener_file.exists() and
                    b"persistent server: listener ready port=8080\n"
                    in received):
                foreground_listener_file.touch()
            if (not init_listener_file.exists() and
                    b"linux socket: listener ready port=8080\n" in received):
                init_listener_file.touch()

            if (not payload_sent and
                    b"concurrency: parent progressed while child uart-blocked\n"
                    in received):
                serial.sendall(b"irqtest\n")
                payload_sent = True

            # The init-managed HTTPd is the maintained lane's third runnable
            # context; no shell command is needed to create another server.
            if (not migration_context_sent and
                    b"workload: busy pair done\n" in received and
                    b"persistent server: listener ready port=8080\n"
                    in received):
                migration_context_sent = True

            migration_ready = (
                b"workload: busy pair migrated across both cpus with stack "
                b"handoff intact\n" in received
            )
            # GitHub issue #547: the BREAK must also find the peer terminal
            # reader asleep, so DDB can name it. The kernel admits the reader
            # once the console writer's verdict is out. The shell then waits
            # in wait4 for it, and it blocks on uart-rx on the secondary.
            peer_console_viewed = (
                b"workload: peer console accepted all 1071 bytes through the shared queue "
                b"after ordered writes on both CPUs\n" in received
            )
            if (args.break_source == "uart" and migration_context_sent and
                    peer_console_viewed and not peer_tty_sent and
                    peer_alias_queries is not None and queries > peer_alias_queries):
                send_paced(serial, b"p\n")
                peer_tty_sent = True
            if (peer_tty_reading_at is None and
                    b"workload: peer tty reading the terminal on the "
                    b"secondary cpu\n" in received):
                peer_tty_reading_at = time.monotonic()
            # Its read blocks right after that line; give it the time.
            peer_tty_asleep = (
                args.break_source != "uart" or
                (peer_tty_reading_at is not None and
                 time.monotonic() - peer_tty_reading_at >= 1.0))
            # The lane is inside the last of its budget and the scripted BREAK
            # never fired, so it has already failed. Ask the debugger why. The
            # snapshot-ready file stays untouched: the runner's GDB comparison
            # belongs to the scripted stop, not to this one.
            if (args.break_source == "uart" and not break_sent and
                    stall_break_at is None and
                    time.monotonic()
                    >= deadline - postmortem_budget(args.timeout)):
                missing = [name for name, ready in (
                    ("the first shell's exit", wake_byte_sent),
                    ("the busy-pair migration", migration_ready),
                    ("the terminal ordering verdict", peer_console_viewed),
                    ("the peer terminal reader asleep", peer_tty_asleep),
                ) if not ready]
                stall_reason = ", ".join(missing) or "nothing it waits for"
                timing.finish(time.monotonic())
                dump, stall_registers = sample_cpu_registers(
                    args.qmp_port, 5.0)
                Path(args.log + ".cpus").write_text(dump)
                failure = send_serial_break(
                    args.qmp_port, QMP_CHARDEV, 5.0)
                stall_break_at = time.monotonic()
                deadline = stall_break_at + postmortem_budget(args.timeout)
                post_path = args.await_timing_log + ".postmortem" if args.await_timing_log else None
                post_timing = AwaitTiming(post_path, stall_break_at,
                    postmortem_budget(args.timeout), [], STALL_COMMANDS,
                    label="kernel/qemu ddb postmortem", origin="postmortem start",
                    connection=False)
                post_prompt_base = received.count(b"ddb> ")
                observers.append(post_timing)
                print("[kernel/qemu ddb] the scripted BREAK never fired; still "
                      f"missing: {stall_reason}. Breaking in for a postmortem"
                      + (f" -- {failure}" if failure else ""), flush=True)
            if stall_break_at is not None:
                prompts = received.count(b"ddb> ")
                while (stall_sent < prompts and
                       stall_sent < len(STALL_COMMANDS)):
                    serial.sendall(STALL_COMMANDS[stall_sent] + b"\n")
                    stall_sent += 1
                # One prompt per command plus the one that opened the walk.
                if prompts > len(STALL_COMMANDS):
                    break
                continue

            if (wake_byte_sent and migration_ready and peer_console_viewed
                    and peer_tty_asleep and not break_sent):
                hold_ready = Path(args.log + ".hold-ready")
                hold_release = Path(args.log + ".hold-release")
                hold_ready.unlink(missing_ok=True)
                hold_release.unlink(missing_ok=True)
                hold_env = os.environ.copy()
                hold_env["KERNEL_CONSOLE_HOLD_READY"] = str(hold_ready)
                hold_env["KERNEL_CONSOLE_HOLD_RELEASE"] = str(hold_release)
                hold_log = open(args.log + ".hold-gdb.log", "wb")
                hold = subprocess.Popen([
                    "gdb-multiarch", "-q", "-batch", args.elf,
                    "-ex", f"target remote 127.0.0.1:{args.gdb_port}",
                    "-ex", "source " + str(Path(__file__).with_name("kernel_console_hold_check.py")),
                ], env=hold_env, stdout=hold_log, stderr=subprocess.STDOUT)
                hold_deadline = min(deadline, time.monotonic() + 15.0)
                while not hold_ready.exists() and hold.poll() is None and time.monotonic() < hold_deadline:
                    time.sleep(0.01)
                if not hold_ready.exists():
                    hold.kill()
                    hold.wait()
                    hold_log.close()
                    raise SystemExit("peer console guard was not held before UART BREAK; see .hold-gdb.log")
                with connect(args.qmp_port, deadline) as qmp:
                    qmp_file = qmp.makefile("rwb", buffering=0)
                    # Say what arrived instead of naming only what did
                    # not. A bare "greeting did not appear" is true of a
                    # timeout, of a QEMU that already exited, and of a
                    # capability line read out of order -- three different
                    # repairs. Under `make allcheck` the QEMU subchecks run
                    # concurrently, so a slow start looks exactly like a
                    # broken one from here.
                    greeting_line = qmp_file.readline()
                    if not greeting_line:
                        raise SystemExit(
                            "QMP sent nothing before the deadline: the port "
                            "accepted a connection but QEMU produced no "
                            "greeting, so it is still starting or has already "
                            "exited")
                    try:
                        greeting = json.loads(greeting_line)
                    except json.JSONDecodeError as exc:
                        raise SystemExit(
                            "QMP greeting was not JSON (%s): %r"
                            % (exc, greeting_line[:200]))
                    if "QMP" not in greeting:
                        raise SystemExit(
                            "QMP greeting did not appear; the first line was "
                            "%r" % (greeting_line[:200],))
                    qmp_file.write(b'{"execute":"qmp_capabilities"}\n')
                    if "return" not in json.loads(qmp_file.readline()):
                        raise SystemExit("QMP capability negotiation failed")
                    qmp_file.write(
                        b'{"execute":"chardev-send-break",'
                        b'"arguments":{"id":"debug_uart"}}\n')
                    if "return" not in json.loads(qmp_file.readline()):
                        raise SystemExit("QMP could not send the serial BREAK")
                hold_release.touch()
                if hold.wait(timeout=10) != 0:
                    raise SystemExit("held console BREAK rendezvous failed; see .hold-gdb.log")
                hold_log.close()
                break_sent = True

            found = received.count(b"ddb> ")
            if found > prompt_count and ready_file is not None:
                ready_file.touch()
                if not release_file.exists():
                    continue
            while prompt_count < found:
                if prompt_count < len(commands):
                    serial.sendall(commands[prompt_count])
                prompt_count += 1

            peer_delivery_ready = (
                args.break_source == "software" or
                b"ddb: console lock probe phase=2 release=" in received
            )
            # The reader DDB saw asleep takes its line once DDB has let go.
            if (args.break_source == "uart" and peer_tty_sent and
                    not peer_tty_line_sent and
                    b"ddb: continuing\n" in received):
                send_paced(serial, b"peer-tty-line-ok\n")
                peer_tty_line_sent = True
            peer_tty_done = (
                args.break_source != "uart" or
                b"workload: peer tty read its 17-byte line" in received)
            if (prompt_count >= len(commands) and
                    b"ddb: continuing\n" in received and
                    b"init: ash bootstrap\n" in received and
                    peer_delivery_ready and peer_tty_done):
                return 0

    if stall_break_at is not None:
        answered = max(0, min(received.count(b"ddb> ") - 1,
                              len(STALL_COMMANDS)))
        walked = " ".join(name.decode("ascii")
                          for name in STALL_COMMANDS[:answered])
        raise SystemExit(
            "DDB BREAK/inspect/continue sequence did not complete: the "
            f"scripted BREAK never fired (still missing: {stall_reason}). A "
            f"postmortem BREAK walked {answered} of {len(STALL_COMMANDS)} "
            f"read-only commands ({walked or 'none answered'}). Registers "
            f"before the BREAK: {stall_registers} (full dump in "
            f"{args.log}.cpus); transcript in {args.log}")
    raise SystemExit("DDB BREAK/inspect/continue sequence did not complete")


if __name__ == "__main__":
    raise SystemExit(main())
