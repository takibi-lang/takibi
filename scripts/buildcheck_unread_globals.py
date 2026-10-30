#!/usr/bin/env python3
"""A production global something only writes is a defect, not a counter.

GitHub issue #1263: #1259 deleted two counters nothing read and a survey found
ten more, each paying for a store and a line of comment promising a reader
that did not exist. Reads the `--facts globals.tsv` uses table of both kernels
(docs/GLOBAL_PROTECTION.md) and refuses a global, across the union, whose every
use is a plain assignment or a whole-statement atomic_word_store or
atomic_word_fetch_add on one line.

The table says `address` for `&g` without saying what the callee does, so the
atomic case reads the use's source line. A use it cannot classify counts as a
read: the check can miss a write-only global, never refuse a read one.

A `dma_fixed` global is skipped: the compiler reaches it through its generated
owner, so its name is never used. Readers the table cannot see: scripts/*.gdb reading by symbol (named in a gdb
file).

Usage: buildcheck_unread_globals.py QEMU.facts/globals.tsv RPI5.facts/globals.tsv
"""

from __future__ import annotations

import collections
import pathlib
import re
import sys

from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILTIN = "<builtin"
ATOMIC_WRITE_ONLY = re.compile(
    r"^\s*atomic_word_(store|fetch_add|fetch_sub)\(&[^;]*\);\s*$")


def load(path: pathlib.Path, globs: dict, uses: dict) -> None:
    in_uses = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# uses"):
            in_uses = True
            continue
        if line.startswith("#") or line.startswith("file\t") or not line:
            continue
        row = line.split("\t")
        if in_uses:
            uses[row[2]].append((row[0], int(row[1]), row[3]))
        elif row[6] != "dma_fixed":
            globs[row[2]] = row[0]


def is_write_only(use: tuple[str, int, str], root: pathlib.Path) -> bool:
    file, line, kind = use
    if kind == "write":
        return True
    if kind != "address":
        return False
    source = (root / file).read_text(encoding="utf-8").splitlines()[line - 1]
    return ATOMIC_WRITE_ONLY.match(source) is not None


def find_unread(globs: dict, uses: dict, root: pathlib.Path) -> list[str]:
    outside = "".join(path.read_text(encoding="utf-8")
                      for path in sorted(root.glob("scripts/*.gdb")))
    unread = []
    for name, file in sorted(globs.items()):
        if file.startswith(BUILTIN):
            continue
        if all(is_write_only(use, root) for use in uses[name]) \
                and not re.search(rf"\b{re.escape(name)}\b", outside):
            unread.append(f"{file}: {name} is never read")
    return unread


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    globs: dict = {}
    uses: dict = collections.defaultdict(list)
    for table in argv[1:]:
        load(pathlib.Path(table), globs, uses)
    unread = find_unread(globs, uses, ROOT)
    for row in unread:
        print(f"ERROR unread-globals: {row}", file=sys.stderr)
    if unread:
        return 1
    report_pass("unread-globals",
                f"{len(globs)} globals of both kernels each have a reader",
                globals=len(globs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
