#!/usr/bin/env python3
"""A host driver never answers BusyBox's cursor query.

GitHub issue #644: with termios working, BusyBox's line editor prints
ESC[6n after each prompt and does not wait for the answer. Four host drivers
answered with ESC[1;1R while also typing the next command at the prompt, so
the reply raced the command. A reply that arrived during a command was
echoed into its output (CI: `^[[1;1Rmkdir: ...`), and one that reached the
editor split across reads left its tail as typed text (RPi5:
`1R/bin/peer-tty: not found`). The drivers now leave the query unanswered,
as scripts/run_kernel_churn.py always had, and remove it from captures.

The shape is silent: a lane with a reply is green on most boots. So no
Python file under scripts/ or kernel/tests/ may contain a cursor position
report literal -- ESC, `[`, row, `;`, column, `R`. Comments that describe
the reply without the escape are not matched.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import re
import sys

from pass_line import report_pass

ROOTS = (pathlib.Path("scripts"), pathlib.Path("kernel/tests"))
REPLY = re.compile(r"(\\x1b|\\033|\\e|\\u001b)\[[0-9]+;[0-9]+R")


def main() -> int:
    scanned = 0
    failures = []
    for root in ROOTS:
        for path in sorted(root.rglob("*.py")):
            scanned += 1
            text = path.read_text(encoding="utf-8", errors="replace")
            for number, line in enumerate(text.splitlines(), 1):
                if REPLY.search(line):
                    failures.append(f"{path}:{number}")
    if failures:
        for where in failures:
            print(f"ERROR\tno-cursor-reply: {where} writes a cursor position "
                  "report. BusyBox does not wait for it, so it lands in the "
                  "next command (#644); leave ESC[6n unanswered and remove "
                  "it from the capture instead")
        print(f"FAIL no-cursor-reply: {len(failures)} reply literal(s)")
        return 1
    report_pass("no-cursor-reply",
                "no host driver answers BusyBox's cursor query",
                python_files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
