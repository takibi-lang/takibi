#!/usr/bin/env python3
"""A production global something only writes is a defect, not a counter, and so
is one nothing writes.

GitHub issue #1263: #1259 deleted two counters nothing read and a survey found
ten more, each paying for a store and a line of comment promising a reader
that did not exist. Reads the `--facts globals.tsv` uses table of both kernels
(docs/GLOBAL_PROTECTION.md) and refuses a global, across the union, whose every
use is `write` or `atomic_store`. The table classifies each use, so nothing here
reads a source line (#1275): an unclassified use counts as a read, and the check
can miss a write-only global, never refuse a read one.

A `dma_fixed` global is skipped: the compiler reaches it through its generated
owner, so its name is never used. A reader the table cannot see: scripts/*.gdb
reading by symbol (named in a gdb file).

GitHub issue #1270: the converse. #1012 found two TCP words nothing ever set,
with dead branches behind them. A scalar or single AtomicWord global with at
least one use, none of which can write it, is refused: it should be a `let`, or
gone with its branches. A `load` or `atomic_load` cannot write. A `read`, `index`
or `cast` of an array or struct can yield a pointer something writes through, so
it counts as a write. A writer the table cannot see: a debugger setting the
symbol, declared in scripts/debugger_set_globals.tsv with a script that sets it
(#1273, since any mention used to pass). A row is refused when its script has no assignment of
the name, when the name is not a global, and when the program also writes it.

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
SCALAR = re.compile(r"^(bool|[iu](8|16|32|64)|isize|usize|u16be|u32be|fn|AtomicWord|\*.*)$")
DEBUGGER_SET = "scripts/debugger_set_globals.tsv"
WRITE_ONLY = {"write", "atomic_store"}
# Never writes, whatever the global's type.
CANNOT_WRITE = {"load", "atomic_load"}
# Yields a scalar's value, but an array's or struct's decayed pointer, which the
# table cannot follow.
VALUE_ONLY = {"read", "index", "cast"}


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
            globs[row[2]] = (row[0], row[5])


def is_write_only(use: tuple[str, int, str]) -> bool:
    return use[2] in WRITE_ONLY


def writes(use: tuple[str, int, str], kind: str) -> bool:
    if use[2] in CANNOT_WRITE or (SCALAR.match(kind) and use[2] in VALUE_ONLY):
        return False
    return True


def sets_by_debugger(script: str, name: str) -> bool:
    """`set *(char *)&g = 1` in gdb, or the `g 1` and "g", "1" of a JTAG poke."""
    word = re.escape(name)
    return re.search(rf"&{word}\s*=\s*\d|\b{word}\s+\d\b|\"{word}\",\s*\"\d\"",
                     script) is not None


def declared_debugger_set(globs: dict, uses: dict, root: pathlib.Path) -> tuple[set, list]:
    declared = set()
    errors = []
    rows = (root / DEBUGGER_SET).read_text(encoding="utf-8").splitlines()[1:]
    for row in rows:
        name, setter = row.split("\t")
        declared.add(name)
        if name not in globs:
            errors.append(f"{DEBUGGER_SET}: {name} is not a global")
        elif any(writes(use, globs[name][1]) for use in uses[name]):
            errors.append(f"{DEBUGGER_SET}: {name} is written by the program")
        path = root / setter
        if not path.is_file() or not sets_by_debugger(
                path.read_text(encoding="utf-8", errors="replace"), name):
            errors.append(f"{DEBUGGER_SET}: {setter} does not set {name}")
    return declared, errors


def find_unwritten(globs: dict, uses: dict, root: pathlib.Path) -> list[str]:
    declared, unwritten = declared_debugger_set(globs, uses, root)
    for name, (file, kind) in sorted(globs.items()):
        if file.startswith(BUILTIN) or not uses[name]:
            continue
        if name not in declared \
                and not any(writes(use, kind) for use in uses[name]):
            unwritten.append(f"{file}: {name} is never written")
    return unwritten


def find_unread(globs: dict, uses: dict, root: pathlib.Path) -> list[str]:
    outside = "".join(path.read_text(encoding="utf-8")
                      for path in sorted(root.glob("scripts/*.gdb")))
    unread = []
    for name, (file, _) in sorted(globs.items()):
        if file.startswith(BUILTIN):
            continue
        if all(is_write_only(use) for use in uses[name]) \
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
    unread = find_unread(globs, uses, ROOT) + find_unwritten(globs, uses, ROOT)
    for row in unread:
        print(f"ERROR unread-globals: {row}", file=sys.stderr)
    if unread:
        return 1
    report_pass("unread-globals",
                f"{len(globs)} globals of both kernels each have a reader "
                "and, where the table can tell, a writer",
                globals=len(globs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
