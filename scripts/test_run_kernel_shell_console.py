#!/usr/bin/env python3
"""Regression controls for the interactive console's UART marker detection.

A marker is found in a byte stream that arrives in arbitrarily sized reads, so
the detector has to search each whole read and carry only the overlap a split
could hide. Retaining a fixed window of the marker's own length instead loses
any marker that arrives with something after it in the same read: that is the
ordinary case for a marker inside a line, and it silently reported nothing.
"""

import importlib.util
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CONSOLE = REPO_ROOT / "scripts" / "run_kernel_shell_console.py"

# Real lines, copied from a boot: the guest announces its listener mid-line,
# and reports the interactive shell blocking on UART at the end of one.
LISTENER_LINE = b"foreground server: listener ready port=8080\r\n"
READY_LINE = b"interactive shell: uart blocked\n"
UNRELATED = b"/ # ls /bin\r\nbusybox\r\nhttpd\r\n"


def load_console():
    spec = importlib.util.spec_from_file_location("shell_console", CONSOLE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def hits(detect, chunks):
    carry, fired = b"", 0
    for chunk in chunks:
        seen, carry = detect(carry, chunk)
        fired += seen
    return fired


def check(name, detect, line):
    failures = []
    if hits(detect, [line]) != 1:
        failures.append("a whole line in one read was missed")
    if hits(detect, [line + UNRELATED]) != 1:
        failures.append("a line followed by more output in one read was missed")
    splits = {hits(detect, [line[:at], line[at:]]) for at in range(1, len(line))}
    if splits != {1}:
        failures.append(f"splitting the line reported {sorted(splits)} rather than one")
    if hits(detect, [line[at : at + 1] for at in range(len(line))]) != 1:
        failures.append("one byte per read was missed")
    if hits(detect, [line, line]) != 2:
        failures.append("a second occurrence was not reported")
    if hits(detect, [UNRELATED]) != 0:
        failures.append("unrelated output was reported as a match")
    for failure in failures:
        print(f"ERROR\t{name}: {failure}")
    return not failures


def main() -> int:
    console = load_console()
    ok = check("listener marker", console.listener_seen, LISTENER_LINE)
    ok = check("ash readiness marker", console.ready_seen, READY_LINE) and ok
    if not ok:
        print("FAIL shell-console-markers: a UART marker is not detected reliably")
        return 1
    print(
        "PASS shell-console-markers: the listener and readiness markers are found "
        "whole, followed by more output, split at every boundary, and not in "
        "unrelated traffic"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
