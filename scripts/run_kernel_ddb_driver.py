#!/usr/bin/env python3
"""Send a real QEMU serial BREAK, inspect through DDB, then prove resume."""

import argparse
import json
from pathlib import Path
import re
import socket
import time

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
    parser.add_argument("--kernel-address", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--snapshot-ready-file")
    parser.add_argument("--snapshot-release-file")
    parser.add_argument("--network-ready-file", required=True)
    parser.add_argument("--foreground-listener-file", required=True)
    parser.add_argument("--init-listener-file", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if ((args.snapshot_ready_file is None)
            != (args.snapshot_release_file is None)):
        raise SystemExit(
            "snapshot ready and release files must be supplied together")
    deadline = time.monotonic() + args.timeout
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

    serial = connect(args.serial_port, deadline)
    serial.settimeout(0.25)
    received = bytearray()
    break_sent = args.break_source == "software"
    wake_byte_sent = args.break_source == "software"
    prompt_count = 0
    migration_context_sent = False
    peer_tty_sent = False
    peer_tty_reading_at = None
    peer_tty_line_sent = False
    stall_break_at = None
    stall_sent = 0
    stall_reason = ""
    stall_registers = ""
    payload_sent = False
    commands = [
        b"oops\n", b"regs\n", b"intr\n", b"sched\n",
        b"current\n", b"vm\n", b"fds\n",
        b"ps\n", b"stacks\n", b"wait\n", b"waittest\n", b"proc 1\n",
        b"bt\n", b"bt 1\n", b"bt 0\n", b"bt 999999\n",
        b"bt cpu 1\n", b"bt cpu 9\n", b"bt cpu x\n", b"bttest\n",
        b"trace\n", b"events\n",
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

    with serial, open(args.log, "wb") as log:
        while time.monotonic() < deadline:
            try:
                chunk = serial.recv(4096)
            except socket.timeout:
                chunk = None
            if chunk == b"":
                break
            if chunk is not None:
                received.extend(chunk)
                log.write(chunk)
                log.flush()

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
                    b"foreground server: listener ready port=8080\n"
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

            # The pair deliberately waits until its restart verdict before
            # measuring migration. Match the maintained integration lane's
            # third runnable context: its persistent shell starts a
            # background HTTPd, allowing each busy process to become Ready
            # and be selected by the other CPU.
            if (not migration_context_sent and
                    b"workload: busy pair done\n" in received and
                    b"persistent shell: uart blocked\n" in received):
                serial.sendall(b"httpd.sh &\n")
                migration_context_sent = True

            migration_ready = (
                b"workload: busy pair migrated across both cpus with stack "
                b"handoff intact\n" in received
            )
            # The runner armed the held peer record at the checkpoint, so
            # this line means one is published and undrained right now.
            peer_console_pending = (
                b"workload: peer console record pending for DDB\n" in received
            )
            # GitHub issue #547: the BREAK must also find the peer terminal
            # reader asleep, so DDB can name it. The kernel admits the reader
            # once the console writer's verdict is out. The shell then waits
            # in wait4 for it, and it blocks on uart-rx on the secondary.
            peer_console_viewed = (
                b"workload: peer console short-wrote 1024 of 1088 bytes, "
                b"then delivered the final record\n" in received
            )
            if (args.break_source == "uart" and migration_context_sent and
                    peer_console_viewed and not peer_tty_sent):
                send_paced(serial, b"/bin/peer-tty\n")
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
                    ("the held peer console record", peer_console_pending),
                    ("the peer terminal reader asleep", peer_tty_asleep),
                ) if not ready]
                stall_reason = ", ".join(missing) or "nothing it waits for"
                dump, stall_registers = sample_cpu_registers(
                    args.qmp_port, 5.0)
                Path(args.log + ".cpus").write_text(dump)
                failure = send_serial_break(
                    args.qmp_port, QMP_CHARDEV, 5.0)
                stall_break_at = time.monotonic()
                deadline = stall_break_at + postmortem_budget(args.timeout)
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

            if (wake_byte_sent and migration_ready and peer_console_pending
                    and peer_tty_asleep and not break_sent):
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
                b"peer user console: queued before DDB, delivered after "
                b"continue \n" in received
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
