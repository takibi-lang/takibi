#!/usr/bin/env python3
"""Every kernel log line a host-side script waits for must still be produced.

A boot-log line is an interface with two ends: the kernel writes it and a
test driver waits for it, and only one end is in the compiler's reach. When
`distro stack: argc=3 argv auxv ready` became `argc=2`, the two view
expectations that read it were updated and `scripts/run_kernel_ddb_driver.py`
was not -- so the driver waited forever for a line that no longer existed, no
serial BREAK was ever sent, and the DDB lane failed as a timeout rather than
as a mismatch. Nothing in the build had anything to say about it.

What this checks: each fixed string a host script waits for either appears
inside something the kernel image can emit, or is completed at runtime from
a literal prefix the kernel emits. Both directions are needed. The kernel
writes whole lines with surrounding newlines baked in
(`"\npersistent shell: uart blocked\n"`), so a driver waiting for the bare
line is looking for a substring; and a driver equally legitimately waits for
`persistent shell: fork child pid=`, which the kernel completes with a number
the literal does not contain.

The second direction is floored at a length and required to carry `: `, or a
one-character literal like `"\n"` would vacuously satisfy every expectation
and the check would pass while testing nothing.

What it deliberately does not check: regular-expression expectations
(`grep -Eq '^oops: trace seq=...'`). Those describe a shape rather than a
string, and a checker that guessed at their literal parts would report
failures nobody could act on.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# HTTP protocol text a driver sends or matches on the wire. Not kernel output.
NOT_KERNEL_OUTPUT = ("HTTP/", "Content-Length:", "Host:")

# A kernel literal shorter than this cannot establish that an expectation
# names a real line; see this file's header.
PREFIX_FLOOR = 12


def kernel_strings():
    """Every literal the kernel image can put on the UART.

    Both halves matter: `.tkb` string literals are the kernel's own prints,
    and the ext2 fixture scripts are what the shell it boots echoes.
    """
    out = []
    for path in (REPO / "kernel").rglob("*.tkb"):
        out.extend(re.findall(r'"((?:[^"\\]|\\.)*)"', path.read_text()))
    for path in (REPO / "kernel" / "tests" / "ext2").iterdir():
        if path.is_file():
            try:
                out.append(path.read_text())
            except UnicodeDecodeError:
                continue
    return out


def expectations():
    """(file, line, text) for every fixed string a host script waits for."""
    found = []
    for path in sorted((REPO / "scripts").glob("*.py")):
        if path.name == pathlib.Path(__file__).name:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for text in re.findall(r'b"((?:[^"\\]|\\.)*)"', line):
                found.append((path, number, text))
    for path in sorted((REPO / "scripts").glob("*.sh")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for text in re.findall(r"grep -[a-zA-Z]*F[a-zA-Z]* '([^']*)'", line):
                found.append((path, number, text))
    return found


def main():
    strings = kernel_strings()
    problems = []
    checked = 0
    for path, number, raw in expectations():
        text = raw.replace("\\n", "\n").replace("\\r", "\r").strip("\n\r")
        # A kernel log line is `subsystem: message`. Anything without that
        # shape is a command sent to the shell, not a line waited for.
        if ": " not in text and not text.endswith(":"):
            continue
        if any(marker in text for marker in NOT_KERNEL_OUTPUT):
            continue
        checked += 1
        if any(text in s for s in strings):
            continue
        if any(len(s) >= PREFIX_FLOOR and ": " in s and text.startswith(s)
               for s in strings):
            continue
        problems.append(
            f"{path.relative_to(REPO)}:{number}: waits for a line the kernel "
            f"no longer emits: {text!r}")
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"FAIL kernel/log-expectations: {len(problems)} of {checked} "
              f"host-side expectations name a line nothing emits", file=sys.stderr)
        return 1
    print(f"PASS kernel/log-expectations: all {checked} host-side boot-log "
          f"expectations match a line the kernel can emit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
