#!/usr/bin/env python3
"""Refuse an allocating substring comparison in the compiler (GitHub #917).

`String.sub s i m = needle` at a position other than 0 is the shape of a
hand-rolled search loop: it allocates a fresh string at every position it
tries. On the printed kernel such loops in lib/region_builtin.ml were most
of the compiler's front end (53 GB allocated per compile). The compiler
searches with lib/text_search.ml (sub_at, find_sub, contains) instead.

A comparison at offset 0 (a prefix test) allocates once and is allowed;
String.starts_with is still the better spelling. What this misses: a
search loop that allocates some other way (String.sub bound to a name, then
compared), which stays review. Controls: scripts/check_text_search_controls.py.
"""

import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
ARG = r"(?:!?[\w.']+|\([^()]*\))"
SHAPE = re.compile(
    r"String\.sub\s+" + ARG + r"\s+(?!0\s)" + ARG + r"\s+" + ARG + r"\s*(?:=|<>)(?!=)")
COMMENT = re.compile(r"\(\*.*?\*\)", re.S)


def hits(text: str) -> list:
    """Line numbers of the refused shape, outside OCaml comments."""
    code = COMMENT.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
    return [code.count("\n", 0, m.start()) + 1 for m in SHAPE.finditer(code)]


def problems(sources: dict) -> list:
    """`sources` maps a repository-relative .ml path to its text."""
    found = []
    for name, text in sorted(sources.items()):
        for line in hits(text):
            found.append(f"{name}:{line}: String.sub compared at a moving offset "
                         f"allocates per position; use Text_search.sub_at, "
                         f"find_sub or contains")
    return found


def tracked_sources() -> dict:
    return {str(path.relative_to(ROOT)): path.read_text(encoding="utf-8")
            for tree in ("lib", "bin") for path in sorted((ROOT / tree).glob("*.ml"))}


def main() -> int:
    sources = tracked_sources()
    found = problems(sources)
    for problem in found:
        print(f"ERROR\ttext-search: {problem}")
    if found:
        print(f"FAIL text-search: {len(found)} problem(s)")
        return 1
    report_pass("text-search",
                f"no allocating substring search in {len(sources)} compiler sources",
                files=len(sources))
    return 0


if __name__ == "__main__":
    sys.exit(main())
