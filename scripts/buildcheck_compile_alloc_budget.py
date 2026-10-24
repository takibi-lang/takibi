#!/usr/bin/env python3
"""The kernel main.o compile stays inside a budget of allocated words.

GitHub issue #923. #917 removed quadratic scans from the compiler front end:
the QEMU main.o compile went from 53 GB allocated (about 6.6e9 words) to
7.2 GB. Quadratic list scans have no lintable shape (check_text_search.py
catches only the substring-search one), so this holds the result instead.
The compiler writes the words it allocated on the OCaml heap
(`--emit-alloc-words`, Gc.allocated_bytes at exit). Unlike wall or CPU time
that number does not depend on host load: the same sources and compiler give
the same count, so the check needs no reference run and costs nothing beyond
the compile the build already does.

A budget is a ceiling with headroom, not an estimate. When ordinary kernel
growth reaches it, raise it to the new measurement plus about 25% and say so
in the commit; when a single change crosses it, look for a new quadratic pass
in the compiler first.

Usage: buildcheck_compile_alloc_budget.py qemu WORDS_FILE
"""

import sys
from pathlib import Path

from pass_line import report_pass

# Measured 690,697,545 words on 2026-10-24 (after #921's planner and
# monomorphize fixes; 903,223,947 after #917), the
# same count on repeated runs; the budget is that plus about 25%. The
# pre-#917 compile used about 6.6e9.
BUDGET_WORDS = {
    "qemu": 865_000_000,
}


def check(target: str, text: str) -> str | None:
    """Return an error message, or None when the count is within budget."""
    if target not in BUDGET_WORDS:
        return f"unknown target {target!r}; known: {sorted(BUDGET_WORDS)}"
    stripped = text.strip()
    if not stripped.isdigit():
        return f"allocated-words file is not one decimal integer: {stripped[:40]!r}"
    words = int(stripped)
    budget = BUDGET_WORDS[target]
    if words > budget:
        return (f"{target} main.o compile allocated {words:,} words, over its "
                f"budget of {budget:,} (#923). A jump usually means a new "
                f"quadratic pass in the compiler; ordinary growth means raising "
                f"BUDGET_WORDS in scripts/buildcheck_compile_alloc_budget.py")
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    target, path = argv[1], Path(argv[2])
    try:
        text = path.read_text()
    except OSError as error:
        print(f"FAIL compile-alloc-budget: cannot read {path}: {error}")
        return 1
    error = check(target, text)
    if error:
        print(f"FAIL compile-alloc-budget: {error}")
        return 1
    words = int(text.strip())
    report_pass("compile-alloc-budget",
                f"{target} main.o compile allocated {words:,} words, "
                f"{100 * words // BUDGET_WORDS[target]}% of its budget",
                words=words)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
