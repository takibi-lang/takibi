#!/usr/bin/env python3
"""Controls for check_kernel_log_expectations.py's byte-string scan (GitHub
issue #817): `b"` inside a word is a plain string's closing quote, not the
start of a log expectation; a real `b"..."` literal is still read.
"""

import sys

sys.dont_write_bytecode = True
import check_kernel_log_expectations as check  # noqa: E402
from pass_line import report_pass  # noqa: E402


def main() -> int:
    cases = [
        ('"one serial job": (makefile, ci),', [],
         "in-word b\" read as a byte string"),
        ('wait(b"boot: ready")', ["boot: ready"], "real byte string missed"),
        ('x = b"a: b" + b"c: d"', ["a: b", "c: d"], "second byte string missed"),
        ('if b"k: v" in out:', ["k: v"], "byte string after a space missed"),
        ('f(sub, b"k: v")', ["k: v"], "byte string after a comma missed"),
    ]
    for line, want, message in cases:
        got = check.line_expectations(line)
        assert got == want, "%s (got %r)" % (message, got)
    report_pass("kernel/log-expectations controls",
                "%d planted lines scanned as expected" % len(cases),
                cases=len(cases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
