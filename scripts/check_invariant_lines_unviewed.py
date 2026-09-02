#!/usr/bin/env python3
"""A `process invariant:` boot-log line must not be captured by any view.

These lines report an invariant this kernel is KNOWN to be violating, with a
count, so the number is visible while it is being driven to zero:

    process invariant: REAPED THE CURRENT PROCESS count=26
    process invariant: STALE HANDLE READS count=0

A kernel view compares a filtered slice of the boot log against an expected
file. If a filter captured one of these, the count would have to be written
into that expected file to make the lane pass -- and an expected file is a
statement that the output is CORRECT. Baking a known-nonzero violation in as
correct is the opposite of measuring it, and it would then have to be edited
every time the number moved, which is exactly when somebody stops reading it.

The rule is therefore: report the invariant under a prefix no filter matches,
and move the line into a view only once the count is zero -- because absence
is what should be asserted, and absence is stable across both targets.

That rule was applied by hand twice and written in two comments. This makes
it a build failure instead, which matters because the failure mode is silent:
`process table:` and `process invariant:` differ by one word, and the lane
goes green either way until somebody reads the expected file.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

KERNEL = pathlib.Path("kernel")
PREFIX = "process invariant: "
EMIT_RE = re.compile(r'kernel_boot_log\("(' + re.escape(PREFIX) + r'[^"]*)"')


def emitted_lines():
    lines = []
    for path in sorted(KERNEL.rglob("*.tkb")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for match in EMIT_RE.finditer(line):
                lines.append((str(path), number, match.group(1)))
    return lines


def main():
    emitted = emitted_lines()
    if not emitted:
        # Not a failure: the invariants may all have reached zero and had
        # their lines removed. Say so rather than passing silently, because
        # "no such line" and "the check stopped looking" read the same.
        print("PASS invariant-lines-unviewed: no 'process invariant:' line is "
              "emitted; nothing to keep out of a view")
        return 0

    filters = sorted(KERNEL.rglob("views/*.filter"))
    if not filters:
        print("FAIL invariant-lines-unviewed: no view filters found, which "
              "cannot be right", file=sys.stderr)
        return 1

    failures = []
    for filter_path in filters:
        for number, pattern in enumerate(
                filter_path.read_text().splitlines(), 1):
            pattern = pattern.strip()
            if not pattern:
                continue
            try:
                compiled = re.compile(pattern)
            except re.error:
                continue
            for source, line_number, text in emitted:
                if compiled.search(text):
                    failures.append(
                        "%s:%d pattern %r captures %r, emitted at %s:%d. "
                        "An expected file would then assert a known "
                        "violation as correct; keep the line out of every "
                        "view until its count is zero"
                        % (filter_path, number, pattern, text,
                           source, line_number))

    if failures:
        for line in failures:
            print("FAIL invariant-lines-unviewed: " + line, file=sys.stderr)
        return 1

    print("PASS invariant-lines-unviewed: %d 'process invariant:' line(s), "
          "none captured by any of %d view filters"
          % (len(emitted), len(filters)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
