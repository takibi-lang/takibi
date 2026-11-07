#!/usr/bin/env python3
"""Controls for scripts/decode_srcloc.py (GitHub issue #1024).

A SrcLoc is file index << 20 | line; user_payload's fail_if prints it as
"srcloc=0x%08x". The decoder must split it at bit 20, name the file from the
table, say so when the index is not in it, and find every srcloc= in a
capture and nothing else.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import decode_srcloc as d  # noqa: E402
from pass_line import report_pass  # noqa: E402

TABLE = {0: "kernel/arch/arm64/kernel/user_payload.tkb", 1: "lib/other.tkb"}

VALUES = [
    ("file 0", 0x0000005F, "kernel/arch/arm64/kernel/user_payload.tkb:95"),
    ("file 1, the largest line", 0x001FFFFF, "lib/other.tkb:1048575"),
    ("an index the table lacks", 0x00300001,
     "<file index 3 not in the table>:1"),
]

LOGS = [
    ("the fail_halt_at shape",
     ["boot", "userspace syscall fixture: failed srcloc=0x00100007", "exit"],
     ["srcloc: 0x00100007 = lib/other.tkb:7"]),
    ("a clean capture", ["userspace syscall fixture: ok"], []),
]


def main():
    failures = []
    ran = 0
    for label, value, expected in VALUES:
        ran += 1
        got = d.decode(TABLE, value)
        if got != expected:
            failures.append(f"{label}: got {got!r}, expected {expected!r}")
    for label, lines, expected in LOGS:
        ran += 1
        got = d.decode_log(TABLE, lines)
        if got != expected:
            failures.append(f"{label}: got {got!r}, expected {expected!r}")
    if failures:
        for failure in failures:
            print(f"FAIL decode-srcloc controls: {failure}")
        return 1
    report_pass("decode-srcloc controls",
                f"{ran} cases: a SrcLoc splits at bit 20 into a named file and "
                "a line, an unknown index says so, and a capture yields each "
                "srcloc= and nothing else",
                cases=ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
