#!/usr/bin/env python3
"""Controls for check_removed_flag_mentions.py: each claim it makes, tested."""

from __future__ import annotations

import sys

from check_removed_flag_mentions import REMOVED, scan
from pass_line import report_pass

CASES = [
    ("a comment in current code is refused",
     "kernel/a.tkb", "// built with --forbid-trap\n", 1),
    ("every listed flag is refused",
     "SPEC.md", "\n".join(REMOVED), len(REMOVED)),
    ("the opt-out spelling is not the removed flag",
     "lib/a.ml", "--no-frame-pointers and --no-function-sections\n", 0),
    ("a longer flag is not the removed flag",
     "lib/a.ml", "--forbid-trap-sites\n", 0),
    ("HISTORY.md is a record", "HISTORY.md", "--forbid-trap\n", 0),
    ("DECISIONS.md is a record", "DECISIONS.md", "--forbid-trap\n", 0),
    ("a talk is a record", "docs/talks/t/slides.md", "--forbid-trap\n", 0),
    ("a dated document is a record",
     "docs/X_2026-10-10.md", "--forbid-trap\n", 0),
    ("an undated document is not", "docs/X.md", "--forbid-trap\n", 1),
    ("an Introduced row quotes a commit",
     "docs/wont-compile/1.md", '| Introduced | "--forbid-trap" |\n', 0),
    ("the refusal test may name it",
     "test/test_takibi.ml", 'run ["--forbid-trap"] in\n', 0),
    ("the test file's prose may not",
     "test/test_takibi.ml", "(* under --forbid-trap *)\n", 1),
]


def main() -> int:
    failed = 0
    for what, path, text, expected in CASES:
        got = len(scan(path, text))
        if got != expected:
            print(f"ERROR removed-flag-mentions controls: {what}: "
                  f"{got} errors, expected {expected}", file=sys.stderr)
            failed += 1
    if failed:
        return 1
    report_pass("removed-flag-mentions controls",
                f"{len(CASES)} claims -- current text naming a removed flag "
                "is refused, and records, the opt-out spellings, an "
                "Introduced row and the refusal test are not",
                cases=len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
