#!/usr/bin/env python3
"""The page allocator's whole-table free-list rebuild runs only at install.

GitHub issue #771: page_alloc_contiguous called
page_runtime_freelist_rebuild -- a pass over every page -- on every run it
handed out, under the IRQ-masking page lock, about 3 ms per call on the
RPi5. The free list is doubly linked now, and every change after the
runtime tables are installed is an O(1) push or unlink. A new call to the
rebuild from an allocation or release path would bring the cost back
without failing any functional test, so this check pins its callers to the
one that installs the tables (page_allocator_fill_metadata).

It reads kernel/mm/page.tkb only: the function is private there. It
misses an equivalent whole-table loop written inline under another name;
the RECORDED page run allocator line and its visit count are what show
that.

Exit code only (0 = pass, 1 = fail).
"""
import re
import sys
from pathlib import Path

from pass_line import report_pass

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "kernel/mm/page.tkb"
REBUILD = "page_runtime_freelist_rebuild"
ALLOWED = {"page_allocator_fill_metadata"}
FN = re.compile(r"^(?:private\s+)?fn\s+(\w+)\s*\(")


def callers(text):
    found = []
    current = None
    for number, line in enumerate(text.splitlines(), 1):
        match = FN.match(line)
        if match:
            current = match.group(1)
            continue
        code = line.split("//", 1)[0]
        if re.search(r"\b%s\s*\(" % REBUILD, code):
            found.append((number, current))
    return found


def main():
    # An optional path stands in for page.tkb (the controls' mutants).
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else SOURCE
    sites = callers(source.read_text(encoding="ascii"))
    if not sites:
        print("FAIL page-freelist-rebuild: no call to %s found; update this check" % REBUILD)
        return 1
    bad = [(n, f) for n, f in sites if f not in ALLOWED]
    for number, function in bad:
        print("FAIL page-freelist-rebuild: %s:%d: %s called from %s; "
              "after install the list changes only by push and unlink (#771)"
              % (source.name, number, REBUILD, function))
    if bad:
        return 1
    report_pass("page-freelist-rebuild",
                "%s runs only from %s" % (REBUILD, ", ".join(sorted(ALLOWED))),
                call_sites=len(sites))
    return 0


if __name__ == "__main__":
    sys.exit(main())
