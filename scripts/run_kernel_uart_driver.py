#!/usr/bin/env python3
"""Capture a kernel UART and drive the shared BusyBox ash smoke scenario."""

import argparse
import difflib
from pathlib import Path
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
    parser.add_argument("--interactive-httpd-listener-file")
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
