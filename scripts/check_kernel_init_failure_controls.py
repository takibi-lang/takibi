#!/usr/bin/env python3
"""Controls for scripts/kernel_init_failure.py (GitHub issue #1209).

The #1086 shape -- init.sh stops at a step that printed "... failed" and init
logs its nonzero exit -- must name that step; a clean capture, a zero exit
and an exit with no failure line before it are each handled as specified.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import kernel_init_failure as k  # noqa: E402
from pass_line import report_pass  # noqa: E402

CASES = [
    ("the #1086 shape",
     ["profile: move-cost-summary name=move-cost stored=16 lost=0",
      "peer-mutate: mkdirat failed", "peer-mutate failed",
      'exit: init child pid=2 image="/bin/sh" code=1 withheld=0',
      "linux socket syscalls: ok"],
     (1, "peer-mutate failed")),
    ("a clean capture",
     ["busybox dmesg exit: 0", 'exit: init child pid=2 image="/bin/sh" code=0 withheld=0'],
     None),
    ("no init exit at all", ["boot", "busybox interactive shell exit: 0"], None),
    ("an exit with no failure line before it",
     ["something", 'exit: init child pid=2 image="/bin/sh" code=2 withheld=0'],
     (2, "something")),
    ("a nonzero exit of another program is not init.sh's",
     ['exit: init child pid=9 image="/bin/peer-console" code=1 withheld=0'], None),
]


def main():
    failures = []
    ran = 0
    for label, lines, expected in CASES:
        ran += 1
        got = k.init_failure(lines)
        if got != expected:
            failures.append(f"{label}: got {got!r}, expected {expected!r}")
    if failures:
        for failure in failures:
            print(f"FAIL kernel-init-failure controls: {failure}")
        return 1
    report_pass("kernel-init-failure controls",
                f"{ran} captures: the failed step is named, a clean or absent "
                "exit prints nothing, and another program's exit is not init.sh's",
                cases=ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
