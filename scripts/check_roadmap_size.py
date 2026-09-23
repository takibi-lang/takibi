#!/usr/bin/env python3
"""ROADMAP.md stays a work split, not a knowledge base.

On 2026-09-23 ROADMAP.md was 2858 lines, most of them the history of
completed issues, because each session appended its reasoning to the queue
it was working. It was cut to the current territory split and the rest moved
to HISTORY.md. Its header says where findings go instead; this is what makes
that sentence hold, because the growth was one paragraph at a time and no
single addition looked wrong.

The bound is a membership rule in the sense AGENTS.md uses: if the split
genuinely needs more room, move history out, do not raise the number.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import sys

from pass_line import report_pass

ROADMAP = pathlib.Path("ROADMAP.md")
LIMIT = 120


def main() -> int:
    lines = len(ROADMAP.read_text(encoding="ascii").splitlines())
    if lines > LIMIT:
        print(f"FAIL roadmap-size: ROADMAP.md is {lines} lines, over {LIMIT}. "
              "It is the current work split only: put findings on the issue, "
              "reasoning and past events in HISTORY.md")
        return 1
    report_pass("roadmap-size",
                f"ROADMAP.md is {lines} of at most {LIMIT} lines",
                lines=lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
