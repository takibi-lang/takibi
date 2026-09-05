#!/usr/bin/env python3
"""Fail when a tracked file still contains an unresolved merge conflict.

An unresolved merge is not a document, a program, or a fixture, but it looks
enough like one to be read as valid. The instance that produced this check:
check_kernel_memory_map.py reported PASS on a kernel/MEMORY_MAP.md that still
held `<<<<<<< HEAD`, because its table parser ends a table at the first line
that is not a table row -- so the conflict truncated the table to one row and
the check verified that row and nothing else. It passed at the one moment the
document was certainly wrong.

That parser now refuses markers itself, but the class is not one file's. Any
reader that scans for a pattern -- a fixture comparison, a view filter, a
grep-based assertion -- can be handed a conflicted file and answer about the
half above the marker. This check is the general form, and it is cheap: it
asks nothing about content, only that no tracked file is mid-merge.

Only the two markers git always writes at column 0 are matched, plus diff3's
base marker. `=======` alone is deliberately NOT matched: it is a legal setext
heading underline in Markdown and appears in ordinary prose, and a real
conflict always carries an opening and closing marker with it.
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Assembled rather than written, so this file and its control do not match
# themselves when the check is run over the tree that contains them.
OPEN_MARKER = "<" * 7
CLOSE_MARKER = ">" * 7
BASE_MARKER = "|" * 7
MARKERS = (OPEN_MARKER, CLOSE_MARKER, BASE_MARKER)


def tracked_files(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                         capture_output=True, check=True).stdout
    return [root / name.decode() for name in out.split(b"\0") if name]


def conflicted_lines(path):
    """(line number, marker) for every conflict marker at column 0."""
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        # A binary blob cannot be mid-merge in a way a reader would mistake
        # for content, and a path in the index but not on disk is git's
        # business rather than this check's.
        return []
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        for marker in MARKERS:
            if line.startswith(marker):
                found.append((number, line.strip()[:60]))
                break
    return found


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT
    problems = []
    scanned = 0
    for path in tracked_files(root):
        scanned += 1
        for number, line in conflicted_lines(path):
            problems.append(f"{path.relative_to(root)}:{number}: {line!r}")

    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("  Resolve the merge before committing. A check that reads one "
              "of these files answers about the half above the marker, which "
              "is why this fails rather than warns.", file=sys.stderr)
        print(f"FAIL no-conflict-markers: {len(problems)} unresolved conflict "
              f"marker(s) in tracked files", file=sys.stderr)
        return 1

    print(f"PASS no-conflict-markers: {scanned} tracked files hold no "
          f"unresolved merge")
    return 0


if __name__ == "__main__":
    sys.exit(main())
