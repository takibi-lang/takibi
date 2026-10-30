#!/usr/bin/env python3
"""Current text does not name a compiler flag that no longer exists.

GitHub issue #1262: #1027 step 3 removed four flags and left about a hundred
comments and paragraphs naming one of them, and a benchmark script that still
passed two, which the compiler now refuses. Nothing compiles a comment, so
only a scan notices.

REMOVED lists the flags by name rather than comparing every --word against
CLI.md: prose and scripts use many --words that are not compiler flags (other
tools' options, the check runners' own), so a whole-tree comparison would
mostly report those. Add a flag here in the commit that removes it.

Records keep their words: HISTORY.md, DECISIONS.md, the talks, and documents
named with a date describe the tree as it was. Two kinds of line in current
files may name a removed flag: the wont-compile Introduced row, which quotes a
past commit's subject, and the unit test that the compiler refuses the flag.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

from pass_line import report_pass
from source_scan import per_file

ROOT = pathlib.Path(__file__).resolve().parents[1]
REMOVED = ("--forbid-trap", "--frame-pointers", "--function-sections",
           "--reject-unused-functions")
FLAG = re.compile(r"(?<![-\w])(" + "|".join(REMOVED) + r")(?![-\w])")
RECORD = re.compile(
    r"^(HISTORY\.md|DECISIONS\.md|docs/talks/|.*_\d{4}-\d{2}-\d{2}[^/]*$)")
SELF = ("scripts/check_removed_flag_mentions.py",
        "scripts/check_removed_flag_mentions_controls.py")
QUOTES_A_COMMIT = "| Introduced |"
TEST_FILE = "test/test_takibi.ml"
TEST_OF_REFUSAL = re.compile(r"""run \["--|unknown flag '--""")


@per_file
def scan(path: str, text: str) -> tuple[str, ...]:
    """Return one error per line of `text` naming a removed flag."""
    if RECORD.match(path) or path in SELF:
        return ()
    errors = []
    for number, line in enumerate(text.splitlines(), 1):
        match = FLAG.search(line)
        if match is None or line.startswith(QUOTES_A_COMMIT):
            continue
        if path == TEST_FILE and TEST_OF_REFUSAL.search(line):
            continue
        errors.append(f"{path}:{number}: names {match.group(1)}, which the "
                      "compiler no longer has")
    return tuple(errors)


def main() -> int:
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True,
                             capture_output=True, text=True).stdout
    errors: list[str] = []
    scanned = 0
    for name in tracked.split("\0"):
        path = ROOT / name
        if not name or not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        scanned += 1
        errors += scan(name, text)
    for error in errors:
        print(f"ERROR removed-flag-mentions: {error}", file=sys.stderr)
    if errors:
        return 1
    report_pass("removed-flag-mentions",
                f"{scanned} tracked text files name none of the "
                f"{len(REMOVED)} removed compiler flags outside records",
                files=scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
