#!/usr/bin/env python3
"""Every gdb a lane runner starts is bounded from outside.

A lane runner that starts `gdb-multiarch -q -batch` waits for it to exit.
gdb waiting in `continue` for a stop that never comes waits for good, and so
do the lane and every aggregate behind it. That happened on 2026-09-30: the
uart-wake lane's scalar control lost the SIGINT meant to end its
`continue`, and the maintainer's allcheck sat there until it was killed by
hand. The in-script interrupt now repeats (scripts/gdb_interrupt.py), but
only an outside bound covers a gdb that is stuck for any other reason.

So each `gdb-multiarch -q -batch` in scripts/run_kernel_*.sh must run under
`timeout`, on its own line or at the end of the line before it (a
continuation).

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import sys

from pass_line import report_pass

SCRIPTS = pathlib.Path("scripts")
GDB = "gdb-multiarch -q -batch"


def main() -> int:
    runners = 0
    invocations = 0
    failures = []
    for path in sorted(SCRIPTS.glob("run_kernel_*.sh")):
        runners += 1
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            if GDB not in line or line.lstrip().startswith("#"):
                continue
            invocations += 1
            previous = lines[index - 1] if index > 0 else ""
            continued = previous.rstrip().endswith("\\")
            if "timeout" in line or (continued and "timeout" in previous):
                continue
            failures.append(f"{path}:{index + 1}")
    if failures:
        for where in failures:
            print(f"ERROR\tgdb-bounded: {where} starts gdb with no outside "
                  "bound; a `continue` that never stops would hold the lane "
                  "and every aggregate behind it. Run it under `timeout`")
        print(f"FAIL gdb-bounded: {len(failures)} unbounded gdb invocation(s)")
        return 1
    report_pass("gdb-bounded",
                "every gdb a lane runner starts runs under timeout",
                gdb_invocations=invocations)
    return 0


if __name__ == "__main__":
    sys.exit(main())
