#!/usr/bin/env python3
"""Refuse a kernel generation counter that increments outside the budget rule.

GitHub issue #1241: a generation that wraps names a new occupant with an old
identity. Every kernel counter advances through freelist_generation_after,
which refuses rather than wraps. This reads tracked .tkb text and matches a
name containing "generation" being incremented by one, so it catches the shape
that occurred and misses a counter named otherwise.

Allowed: the helper itself, and the ASID generation, whose rollover counts
whole-TLB invalidations of 65535 assignments rather than naming an occupant.
"""
import pathlib
import re
import sys

from pass_line import report_pass
from source_scan import code_only

ROOT = pathlib.Path(__file__).resolve().parent.parent
PATTERN = re.compile(r"(?<![!=<>])=\s*[\w.()*>-]*generation\w*\s*\+\s*1\b")
ALLOWED = {"kernel/lib/freelist.tkb", "kernel/arch/arm64/mm/asid.tkb"}


def violations(path_name, text):
    if path_name in ALLOWED:
        return []
    found = []
    for number, line in enumerate(code_only(text).splitlines(), 1):
        if PATTERN.search(line):
            found.append(f"{path_name}:{number}: {line.strip()}")
    return found


def main():
    planted = violations("kernel/x.tkb", "    pool.next_generation = generation + 1;\n")
    if not planted:
        print("FAIL generation-counters: a planted increment was not refused")
        return 1
    found = []
    files = sorted((ROOT / "kernel").rglob("*.tkb"))
    for path in files:
        found += violations(path.relative_to(ROOT).as_posix(), path.read_text())
    for item in found:
        print(f"  {item}")
    if found:
        print("FAIL generation-counters: advance a generation through "
              "freelist_generation_after, which refuses rather than wraps")
        return 1
    report_pass("generation-counters",
                f"{len(files)} kernel files: no generation counter increments "
                "outside the budget rule; a planted one is refused",
                files=len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
