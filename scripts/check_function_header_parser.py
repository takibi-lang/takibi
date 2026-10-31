#!/usr/bin/env python3
"""A script spells a .tkb function header only through source_scan.

GitHub issue #1296. Six checks read `fn` with at most `noinline` before it, so
a stop in an inline function counted against the function above it and a wrong
row of wait-interrupt-sites stayed hidden (#1288). Each spelling was fixed by
hand. source_scan.function_header is now the one spelling, and this refuses a
regular expression anywhere in scripts/ that anchors `fn` or lists a modifier
before it. A search for one known function (`fn name\\(`) is not a header
parser: it finds the name whatever precedes it.

Rung: a build check over text. A check of the compiler's own tables cannot
disagree with the grammar at all, which is the way out (#567), but the fast
lane's checks read tracked files and no table.
Controls: scripts/check_function_header_parser_controls.py.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass
from source_scan import per_file

ROOT = Path(__file__).resolve().parent.parent
OWNER = "source_scan.py"
SELF = {"check_function_header_parser.py", "check_function_header_parser_controls.py"}

SPELLING = re.compile(
    r"\^(?:\\s\*|\[ \\t\]\*)?fn(?:\\s|\s)"               # an anchored bare fn
    r"|\(\?:[^'\"\n]*(?:inline|private)[^'\"\n]*\bfn\b"  # a modifier group
    r"|(?:inline|private)(?:\\s\+|\s)\)\?[^'\"\n]*\bfn\b")


@per_file
def spellings(text):
    return tuple(number for number, line in enumerate(text.splitlines(), 1)
                 if SPELLING.search(line))


def main():
    problems = []
    scanned = 0
    for path in sorted((ROOT / "scripts").iterdir()):
        if path.suffix not in (".py", ".sh") or path.name == OWNER or path.name in SELF:
            continue
        scanned += 1
        problems += [f"scripts/{path.name}:{n}" for n in spellings(path.read_text(encoding="utf-8"))]
    if problems:
        for problem in problems:
            print(f"  {problem}: use source_scan.function_header")
        print(f"FAIL function-header-parser: {len(problems)} hand-written header pattern(s)")
        return 1
    report_pass("function-header-parser",
                "no script outside source_scan spells a function header", files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
