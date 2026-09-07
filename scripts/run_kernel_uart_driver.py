#!/usr/bin/env python3
"""Capture a kernel UART and drive the shared BusyBox ash smoke scenario."""

import argparse
import difflib
from pathlib import Path
import socket
import time

import serial

# Issue #289: ordered lifecycle boundaries for the interactive HTTPd
# scenario, in the order they must complete. "command-submitted" and
# "parent-resumed" are host-observed (this driver's own state); the rest
# are kernel-printed checkpoints (see kernel/kernel/syscall.tkb's
# `persistent shell: ...` prints, gated to the interactive HTTPd child's own
# fork/exec, not the demo shell's own launch). ARP reply and the two HTTP
# requests that follow "parent-resumed" are the host network peer's own
# concern (scripts/kernel_net_test.py), not this driver's -- its own
# PASS/FAIL output covers that boundary.
LIFECYCLE_CHECKPOINTS = (
    ("command-submitted", lambda output, httpd_sent, httpd_ready: httpd_sent),
    ("fork", lambda output, httpd_sent, httpd_ready:
        b"persistent shell: fork child pid=" in output),
    ("child-selected", lambda output, httpd_sent, httpd_ready:
        b"persistent shell: child selected pid=" in output),
    ("exec-prepare", lambda output, httpd_sent, httpd_ready:
        b"persistent shell: exec prepare pid=" in output),
    ("exec-commit", lambda output, httpd_sent, httpd_ready:
        b"persistent shell: exec commit pid=" in output),
    ("listen", lambda output, httpd_sent, httpd_ready:
        b"persistent server: listener ready port=8080" in output),
    ("parent-resumed", lambda output, httpd_sent, httpd_ready: httpd_ready),
)


def diagnose_lifecycle(output: bytes, httpd_sent: bool,
                       httpd_ready: bool) -> str:
    # Walk in order and stop at the first incomplete checkpoint, rather than
    # scanning the whole list for any completed one: a later checkpoint can
    # complete out of sequence relative to an earlier gap (e.g. exec-commit's
    # own print suppressed while everything downstream of the exec it still
    # performs -- listen, parent-resumed -- goes on to complete normally),
    # and reporting that later one as "last completed" would describe a
    # boundary that hasn't really been reached in order yet.
    last_completed = None
    next_expected = None
    for name, check in LIFECYCLE_CHECKPOINTS:
        if check(output, httpd_sent, httpd_ready):
            last_completed = name
        else:
            next_expected = name
            break
    if last_completed is None:
        return ("no lifecycle checkpoint completed yet, next expected "
                f"'{LIFECYCLE_CHECKPOINTS[0][0]}'")
    if next_expected is None:
        return f"all lifecycle checkpoints completed through '{last_completed}'"
    return (f"last completed checkpoint '{last_completed}', "
            f"next expected '{next_expected}'")


# Below this, a capture that timed out was merely slow rather than stopped.
SILENCE_SECONDS = 2.0


def silence_note(quiet_for: float, timeout: float, output: bytes) -> str:
    """Why a capture that hit its deadline stopped, in the failure's own words.

    Two different failures wear the same timeout, and the distinction is the
    whole diagnosis: a guest still talking when the budget ran out is slow,
    and one that went quiet stopped. Reporting only what a downstream check
    was waiting for reads as a protocol fault -- see GitHub issue #509, where
    it cost a day.
    """
    last_line = next(
        (line for line in reversed(
            output.decode("utf-8", errors="replace")
            .replace("\r", "").splitlines()) if line.strip()),
        "(nothing at all)")
    if quiet_for >= SILENCE_SECONDS:
        return (f"; the guest then sent nothing for {quiet_for:.1f}s of its "
                f"{timeout:.0f}s budget -- it stopped rather than ran late -- "
                f"and its last line was {last_line!r}")
    return (f"; the guest was still sending when its {timeout:.0f}s budget "
            f"ran out, last line {last_line!r}")


# GitHub issue #511. An ordinary lane's guest is never supposed to reach the
# debugger, so a `ddb> ` in its capture is a stall that has already answered
# most of the questions somebody is about to ask -- the snapshot is taken and
# the prompt is reading the same UART this driver already owns. Until now the
# lane read that prompt as ordinary output and sat there until its budget ran
# out, and on 2026-09-07 a multicore exec assertion produced exactly that: a
# capture whose last line was `ddb>` and a timeout in place of a diagnosis.
#
# This is the prompt trigger, not the silence trigger that was reverted. The
# difference is what makes it reliable: a prompt PROVES the debugger is live
# and its UART receive path is usable, so there is nothing to arm early, no
# BREAK to deliver, and no quiet stretch of ordinary boot to mistake for a
# stall.
DDB_PROMPT = b"ddb> "

# The walk, and it deliberately differs from the DDB lane's own list -- that
# one exercises every command, and this one answers a stall.
#
#   oops     the break's sequence, cpu, elr and sp_el0.
#   intr     esr/far and whether the entry was an irq or a brk. An assertion
#            arrives as brk, which is the 2026-09-07 case.
#   bt       where it stopped. `bt` and `sched` are what ended #509.
#   sched    enabled/pending/current and the ready/running/blocked counts.
#   current  the process the snapshot belongs to.
#   ps       what else existed, so `current` can be placed among them.
#
# Left out on purpose: `vm` and `fds`, which were asked during #509 and
# answered nothing; `regs`, thirty lines whose two interesting registers
# `oops` already prints; `trace` and `events`, bounded rings worth reading by
# hand rather than spending a stalled lane's budget on; `proc`, which needs a
# pid that `ps` and `current` have not been read yet to supply; and `help`.
# `xk`/`xp`/`xu`/`xkfault`/`bttest` are excluded as not read-only in intent,
# and `continue` because resuming a guest that stopped for a reason destroys
# the state the next question would have asked about.
POSTMORTEM_COMMANDS = (b"oops", b"intr", b"bt", b"sched", b"current", b"ps")

# What the walk may spend, granted on top of whatever remains of the capture
# budget rather than taken out of it: a stall found at second 89 of 90 still
# gets its answer, and a stall found at second 3 ends the lane in seconds
# instead of burning the other 87. Bounded, so a debugger that stops
# answering mid-walk cannot make the lane hang -- the deadline ends the loop
# and whatever did arrive is still reported.
#
# Derived from the capture budget rather than fixed, for the reason
# scripts/test_kernel_net_readiness.py exists: a flat sub-wait outlives the
# outer budget of every lane shorter than itself, and the branch that was
# supposed to speak then never runs. The ceiling is what a six-command walk
# over a 115200-baud UART needs several times over; the fraction is what keeps
# it inside a short budget.
POSTMORTEM_FRACTION = 0.25
POSTMORTEM_CEILING = 20.0


def postmortem_budget(timeout: float) -> float:
    return min(POSTMORTEM_CEILING, timeout * POSTMORTEM_FRACTION)


# GitHub issues #509 and #511. The walk above needs a prompt, and a guest that
# stops without reaching the debugger never prints one. #509's twenty-three
# captures all stopped at the same line with nothing after it, and its closing
# comment says plainly what was still missing: the two halves it could not tell
# apart -- a kernel stopped in a loop, and a kernel not running at all -- are
# distinguished by asking the debugger, and nothing asked.
#
# So the lane asks, and WHEN it asks is the whole design. A BREAK sent early is
# the trigger that was reverted in 3f86b75e: a quiet stretch of ordinary boot
# fires it, the debugger's receive path may not be up yet, and a lane that
# would have passed is stopped by its own diagnosis. This one fires only once
# the lane is already lost -- inside the last of the capture budget the walk
# itself would need, with the guest quiet for a quarter of that budget -- so
# there is no passing run left to spoil, and the debugger has had the whole
# boot to come up. Whatever it costs, it costs a run that was about to be
# reported as a timeout with nothing in it.
#
# The BREAK's job is only to PRODUCE a prompt. Everything after it is the walk
# above, unchanged, and a BREAK that produces no prompt is not a wasted attempt
# either: on a guest that was merely stopped in kernel code the debugger
# answers at once, so silence after a delivered BREAK says the guest was not
# running -- which is the half #509 could not name.
#
# Not a command-line option: this has to equal the `-chardev id=` the lane
# gives QEMU, and a flag would let the two drift apart while every run still
# looked fine -- the break would fail only at a stall, which is the one moment
# nobody is watching. scripts/test_kernel_ddb_postmortem.py checks the lanes
# against this name instead.
QMP_CHARDEV = "debug_uart"

# Measured 2026-09-07: the longest gap between two UART lines in a healthy
# boot is 4.0s, the same to two decimal places across six consecutive samples,
# and it is a wait on the host peer rather than on guest CPU. A quarter of the
# capture budget is 22.5s at the lanes' default 90s and 60s at the 240s CI
# uses, so it clears that measurement several times over at every budget in
# use, while staying far below the 218s of silence this exists for.
STOPPED_FRACTION = 0.25


def send_serial_break(port: int, chardev: str, budget: float) -> str:
    """Ask QEMU for a real serial BREAK; return what went wrong, or "".

    Every failure is returned rather than raised. This runs inside a lane that
    has already failed, and a diagnosis that replaces the real failure with its
    own is worse than no diagnosis: the capture, the silence note and the
    lifecycle report all still have to come out.
    """
    deadline = time.monotonic() + budget
    try:
        with socket.create_connection(("127.0.0.1", port), budget) as qmp:
            qmp.settimeout(max(0.5, deadline - time.monotonic()))
            stream = qmp.makefile("rwb", buffering=0)
            greeting = stream.readline()
            if b"QMP" not in greeting:
                return ("QMP produced no greeting, so QEMU is still starting "
                        f"or has already exited (first line {greeting[:80]!r})")
            stream.write(b'{"execute":"qmp_capabilities"}\n')
            if b"return" not in stream.readline():
                return "QMP capability negotiation failed"
            stream.write(b'{"execute":"chardev-send-break","arguments":'
                         b'{"id":"' + chardev.encode("ascii") + b'"}}\n')
            reply = stream.readline()
            if b"return" not in reply:
                return f"QMP refused the serial BREAK: {reply[:160]!r}"
    except OSError as error:
        return f"QMP on port {port} was unreachable: {error}"
    return ""


def postmortem_note(before: bytes, answered: int, log_path) -> str:
    """What a lane that stopped at a debugger prompt should say instead of a timeout."""
    last_line = next(
        (line for line in reversed(
            before.decode("utf-8", errors="replace")
            .replace("\r", "").splitlines()) if line.strip()),
        "(nothing at all)")
    walked = ", ".join(name.decode("ascii")
                       for name in POSTMORTEM_COMMANDS[:answered])
    if answered == 0:
        walked = ("no command was answered -- the prompt appeared and the "
                  "debugger then went quiet")
    elif answered < len(POSTMORTEM_COMMANDS):
        walked = (f"{walked} (the walk stopped there; "
                  f"{len(POSTMORTEM_COMMANDS) - answered} command(s) went "
                  "unanswered)")
    where = f"; transcript in {log_path}" if log_path else ""
    return (f"the guest stopped at a DDB prompt after {last_line!r} -- this "
            f"lane never expects one, so it is a stall, not a session. "
            f"Walked: {walked}{where}")


def write_uart_line(connection, line: bytes) -> None:
    # The kernel UART ISR currently drains one byte per interrupt. Pace the
    # synthetic console like typed input so a command longer than a 16-byte
    # hardware FIFO cannot lose its trailing newline in one host-side burst.
    for byte in line + b"\n":
        connection.write(bytes((byte,)))
        time.sleep(0.01)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True,
                        help="pyserial URL or UART device path")
    parser.add_argument("--log", required=True)
    parser.add_argument("--timing-log",
                        help="optional line-oriented UART receipt timeline")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--stop-marker", default="resources: pages=0")
    # GitHub issue #448: the CPU-bound pair /etc/inittab starts runs
    # concurrently with this ash session and reports its verdict when both
    # halves have run their rounds side by side. The interactive HTTPd
    # handshake finishes first, so without this the capture can end before
    # the workload has anything to say and its view fails on a line that
    # was only ever late.
    #
    # It no longer SEQUENCES anything. It used to hold the HTTPd command
    # back as well, because accept(2) waited for a connection inside the
    # kernel and stopped every other process while it did (issue #469);
    # with accept yielding, the two run concurrently and this is only a
    # "do not stop capturing yet".
    parser.add_argument("--workload-marker", default=None)
    parser.add_argument("--stdin", required=True)
    parser.add_argument("--expected", required=True)
    parser.add_argument("--payload-marker",
                        default="concurrency: parent progressed while child uart-blocked")
    parser.add_argument("--payload", default="irqtest")
    parser.add_argument("--ash-only", action="store_true")
    parser.add_argument("--validate-ash", action="store_true")
    # Where the DDB walk above goes when an ordinary lane's guest stops at a
    # debugger prompt. The walk itself is unconditional -- it costs nothing on
    # a lane that never sees a prompt -- and this only decides whether its
    # transcript also gets a file of its own beside the capture.
    parser.add_argument("--postmortem-log")
    # Without this the driver can still answer a prompt the guest reached on
    # its own; with it, it can also ask for one. Only the QEMU lanes have a
    # QMP monitor to ask through, which is why it is optional rather than
    # required.
    parser.add_argument("--qmp-port", type=int)
    parser.add_argument("--interactive-httpd-listener-file")
    parser.add_argument("--foreground-httpd-listener-file")
    parser.add_argument("--init-listener-file")
    parser.add_argument("--network-ready-file")
    parser.add_argument("--interactive-httpd-ready-file")
    parser.add_argument("--interactive-httpd-done-file")
    args = parser.parse_args()

    interactive_httpd = args.interactive_httpd_ready_file is not None
    if interactive_httpd != (args.interactive_httpd_done_file is not None):
        raise RuntimeError("interactive HTTPd ready/done files must be paired")
    if args.interactive_httpd_listener_file and not interactive_httpd:
        raise RuntimeError("interactive HTTPd listener file requires ready/done files")
    httpd_ready_file = (Path(args.interactive_httpd_ready_file)
                        if interactive_httpd else None)
    httpd_listener_file = (Path(args.interactive_httpd_listener_file)
                           if args.interactive_httpd_listener_file else None)
    httpd_done_file = (Path(args.interactive_httpd_done_file)
                       if interactive_httpd else None)
    if httpd_ready_file is not None:
        httpd_ready_file.unlink(missing_ok=True)
    if httpd_listener_file is not None:
        httpd_listener_file.unlink(missing_ok=True)
    foreground_listener_file = (
        Path(args.foreground_httpd_listener_file)
        if args.foreground_httpd_listener_file else None)
    foreground_listener_published = False
    if foreground_listener_file is not None:
        foreground_listener_file.unlink(missing_ok=True)
    init_listener_file = (Path(args.init_listener_file)
                          if args.init_listener_file else None)
    init_listener_published = False
    if init_listener_file is not None:
        init_listener_file.unlink(missing_ok=True)
    network_ready_file = (Path(args.network_ready_file)
                          if args.network_ready_file else None)
    network_ready_published = False
    if network_ready_file is not None:
        network_ready_file.unlink(missing_ok=True)
    # A transcript left by the PREVIOUS run reads exactly like this one's and
    # is not, the same trap the view runner's stale `.actual` files set (see
    # scripts/run_kernel_qemutest.sh). Its absence has to mean "this lane did
    # not stall".
    if args.postmortem_log:
        Path(args.postmortem_log).unlink(missing_ok=True)

    commands = [line.rstrip("\n") for line in open(args.stdin, encoding="ascii")
                if line.strip() and not line.startswith("#")]
    expected = [line.rstrip("\n") for line in open(args.expected, encoding="ascii")
                if line.strip() and not line.startswith("#")]
    if not commands:
        raise RuntimeError(f"empty ash input fixture: {args.stdin}")
    if not expected:
        raise RuntimeError(f"empty ash expected fixture: {args.expected}")

    deadline = time.monotonic() + args.timeout
    connection = None
    last_error = None
    while time.monotonic() < deadline:
        try:
            connection = serial.serial_for_url(
                args.port, baudrate=args.baud, timeout=0.1,
                write_timeout=1.0)
            break
        except serial.SerialException as error:
            last_error = error
            time.sleep(0.1)
    if connection is None:
        raise RuntimeError(f"could not open UART {args.port}: {last_error}")

    output = bytearray()
    postmortem_at = None
    postmortem_sent = 0
    break_asked = False
    break_failure = ""
    shell_step = 0
    payload_sent = False
    httpd_shell_probe_sent = False
    httpd_sent = False
    httpd_probe_sent = False
    httpd_ready = False
    httpd_done_seen_at = None
    capture_started = time.monotonic()
    last_chunk_at = capture_started
    timing_pending = bytearray()
    timing_capture = (open(args.timing_log, "w", encoding="ascii")
                      if args.timing_log else None)
    try:
        with open(args.log, "wb") as capture:
            while time.monotonic() < deadline:
                chunk = connection.read(4096)
                if chunk:
                    last_chunk_at = time.monotonic()
                    output.extend(chunk)
                    capture.write(chunk)
                    capture.flush()
                    if timing_capture is not None:
                        timing_pending.extend(chunk)
                        while b"\n" in timing_pending:
                            line, _, remainder = timing_pending.partition(b"\n")
                            timing_pending = bytearray(remainder)
                            elapsed = time.monotonic() - capture_started
                            text_line = line.decode(
                                "ascii", errors="replace").replace("\r", "")
                            timing_capture.write(f"{elapsed:9.3f}\t{text_line}\n")
                            timing_capture.flush()

                # The lane is inside the last of its budget and the guest
                # has stopped talking: it will be reported as a timeout in a
                # few seconds whatever happens now, so this is the moment to
                # spend on asking the debugger rather than on waiting.
                if (args.qmp_port and not break_asked and
                        postmortem_at is None and
                        time.monotonic()
                        >= deadline - postmortem_budget(args.timeout) and
                        (time.monotonic() - last_chunk_at)
                        >= args.timeout * STOPPED_FRACTION):
                    break_asked = True
                    print("[kernel/uart] guest silent for "
                          f"{time.monotonic() - last_chunk_at:.0f}s with its "
                          "budget nearly gone; asking QEMU for a serial BREAK",
                          flush=True)
                    break_failure = send_serial_break(
                        args.qmp_port, QMP_CHARDEV, 5.0)
                    deadline = (time.monotonic()
                                + postmortem_budget(args.timeout))

                # Before any of the scenario logic below, because from here
                # on the far end is the debugger and not the shell: a lane
                # that kept typing `ls /bin` at a `ddb>` prompt would bury
                # the one transcript worth keeping.
                prompts = output.count(DDB_PROMPT)
                if prompts:
                    if postmortem_at is None:
                        postmortem_at = output.index(DDB_PROMPT)
                        deadline = max(
                            deadline,
                            time.monotonic()
                            + postmortem_budget(args.timeout))
                        print("[kernel/uart] guest stopped at a DDB prompt; "
                              "walking "
                              + " ".join(name.decode("ascii")
                                         for name in POSTMORTEM_COMMANDS),
                              flush=True)
                    while (postmortem_sent < prompts and
                           postmortem_sent < len(POSTMORTEM_COMMANDS)):
                        write_uart_line(
                            connection, POSTMORTEM_COMMANDS[postmortem_sent])
                        postmortem_sent += 1
                    # One prompt per command plus the one that opened the
                    # walk: the last command has been answered.
                    if prompts > len(POSTMORTEM_COMMANDS):
                        break
                    continue

                prompt_count = output.count(b"/ # ")
                if (shell_step == 0 and
                        b"interactive shell: uart blocked\n" in output):
                    connection.write((commands[0] + "\n").encode("ascii"))
                    shell_step = 1
                elif (shell_step > 0 and shell_step < len(commands) and
                      prompt_count >= shell_step + 1):
                    connection.write(
                        (commands[shell_step] + "\n").encode("ascii"))
                    shell_step += 1

                if (not payload_sent and
                        args.payload_marker.encode("ascii") in output):
                    connection.write((args.payload + "\n").encode("ascii"))
                    payload_sent = True

                # Publish the boot-time HTTP listener the moment the guest
                # announces it. The host-side network peer talks to that
                # server and used to race the boot to it, with no way to tell
                # "not up yet" from "broken" (GitHub issue #56's first CI
                # runs, where the peer failed at 24s on a four-core runner
                # while the guest was still short of this line).
                if (foreground_listener_file is not None
                        and not foreground_listener_published
                        and b"foreground server: listener ready port=8080\n"
                        in output):
                    foreground_listener_file.touch()
                    foreground_listener_published = True

                if (init_listener_file is not None
                        and not init_listener_published
                        and b"linux socket: listener ready port=8080\n"
                        in output):
                    init_listener_file.touch()
                    init_listener_published = True

                if (network_ready_file is not None
                        and not network_ready_published
                        and b"virtio net: link ready " in output):
                    network_ready_file.touch()
                    network_ready_published = True

                workload_seen = (
                    args.workload_marker is None or
                    args.workload_marker.encode("ascii") in output)
                if (interactive_httpd and not httpd_shell_probe_sent and
                        b"persistent shell: uart blocked\n" in output):
                    write_uart_line(connection, b"echo httpd-shell-ready")
                    httpd_shell_probe_sent = True
                if httpd_shell_probe_sent and not httpd_sent:
                    text = output.decode(
                        "utf-8", errors="replace").replace("\r", "")
                    if any(line.removeprefix("/ # ") ==
                           "httpd-shell-ready" for line in text.splitlines()):
                        write_uart_line(
                            connection,
                            b"httpd-serve.sh &")
                        print("[kernel/uart] sent interactive HTTPd command",
                              flush=True)
                        httpd_sent = True
                if (httpd_sent and not httpd_probe_sent and
                        b"persistent server: listener ready port=8080\n"
                        in output):
                    if httpd_listener_file is not None:
                        httpd_listener_file.touch()
                    write_uart_line(connection, b"echo httpd-background-ok")
                    httpd_probe_sent = True
                if httpd_probe_sent and not httpd_ready:
                    text = output.decode(
                        "utf-8", errors="replace").replace("\r", "")
                    if any(line.removeprefix("/ # ") ==
                           "httpd-background-ok" for line in text.splitlines()):
                        httpd_ready_file.touch()
                        httpd_ready = True

                if httpd_ready and httpd_done_file.exists() and workload_seen:
                    if httpd_done_seen_at is None:
                        httpd_done_seen_at = time.monotonic()
                    elif time.monotonic() - httpd_done_seen_at >= 0.5:
                        break

                if args.ash_only:
                    if (payload_sent and
                            b"busybox interactive shell exit: 0" in output):
                        break
                elif (not interactive_httpd and
                      args.stop_marker.encode() in output):
                    break
    finally:
        connection.close()
        if timing_capture is not None:
            if timing_pending:
                elapsed = time.monotonic() - capture_started
                text_line = timing_pending.decode(
                    "ascii", errors="replace").replace("\r", "")
                timing_capture.write(f"{elapsed:9.3f}\t{text_line}\n")
            timing_capture.close()

    # A stall answers every question below it -- the ash transcript never
    # completed, the lifecycle never finished -- and answers them wrongly,
    # naming a protocol boundary for a guest that stopped talking to the
    # shell entirely. Report the debugger's own account of it first.
    if postmortem_at is not None:
        walk = bytes(output[postmortem_at:])
        if args.postmortem_log:
            Path(args.postmortem_log).write_bytes(walk)
        answered = max(0, walk.count(DDB_PROMPT) - 1)
        raise RuntimeError(postmortem_note(
            bytes(output[:postmortem_at]), min(answered, postmortem_sent),
            args.postmortem_log))

    # Every path out of the loop above breaks on a marker, so reaching the
    # deadline means the guest stopped sending. Say so wherever a downstream
    # check reports what it was still waiting for: a lifecycle diagnosis reads
    # as a protocol fault, and under a saturated host the real answer is that
    # the guest went quiet -- see GitHub issue #509, where that cost a day.
    # Appended rather than substituted, because the lifecycle-gap lane asserts
    # the diagnosis it induces.
    silence = ""
    if time.monotonic() >= deadline:
        silence = silence_note(
            time.monotonic() - last_chunk_at, args.timeout, bytes(output))
    # A BREAK that produced no prompt is a finding, not a failed attempt --
    # see this file's QMP_CHARDEV comment. Say which of the two it was, since
    # they call for opposite next steps: a kernel stopped in a loop is read
    # with the debugger, and a kernel not running is read on the host.
    if break_asked and postmortem_at is None:
        if break_failure:
            silence += ("; the debugger could not be asked what it was doing: "
                        + break_failure)
        else:
            silence += (
                "; a serial BREAK was delivered and no debugger prompt "
                "followed within "
                f"{postmortem_budget(args.timeout):.0f}s, so the guest was "
                "not merely stopped inside kernel code -- it was not running")

    text = output.decode("utf-8", errors="replace").replace("\r", "")
    if args.validate_ash:
        lines = text.splitlines()
        try:
            start = lines.index("interactive shell: uart blocked") + 1
            end = next(index for index in range(start, len(lines))
                       if "busybox interactive shell exit: 0" in lines[index])
        except (ValueError, StopIteration) as error:
            raise RuntimeError(
                "ash transcript boundaries were not observed" + silence) from error
        actual = [line.removeprefix("/ # ") for line in lines[start:end + 1]]
        if actual != expected:
            diff = "".join(difflib.unified_diff(
                [line + "\n" for line in expected],
                [line + "\n" for line in actual],
                fromfile=args.expected, tofile="ash.actual"))
            raise RuntimeError("ash output differs from expected:\n" + diff)
        if any(line.startswith("ls: ") for line in actual):
            raise RuntimeError("directory enumeration command reported an ls error")
    if interactive_httpd:
        for name, check in LIFECYCLE_CHECKPOINTS:
            if not check(output, httpd_sent, httpd_ready):
                raise RuntimeError(
                    "interactive HTTPd lifecycle stalled: "
                    + diagnose_lifecycle(output, httpd_sent, httpd_ready)
                    + silence)
        if not httpd_done_file.exists():
            raise RuntimeError(
                "host HTTP checks did not complete; "
                + diagnose_lifecycle(output, httpd_sent, httpd_ready)
                + silence)
        for forbidden in ("can't open '/dev/null'", "sh: can't fork",
                          "exception: fail-stop"):
            if forbidden in text:
                raise RuntimeError(
                    f"interactive HTTPd emitted an error: {forbidden}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"FAIL kernel UART driver: {error}")
        raise SystemExit(1)
