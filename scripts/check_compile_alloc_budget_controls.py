#!/usr/bin/env python3
"""Controls for buildcheck_compile_alloc_budget.py (GitHub issue #923).

The pre-#917, pre-#921 and pre-#995 allocations, one word over the budget,
a malformed count and an unknown target must be refused; the budget itself
and the post-#995 measurement must pass.
"""

import sys

from buildcheck_compile_alloc_budget import BUDGET_WORDS, check
from pass_line import CaseCount, report_pass


def main() -> int:
    cases = CaseCount()
    failures = []
    budget = BUDGET_WORDS["qemu"]
    refused = {
        "pre-#917 allocation": ("qemu", "6600000000\n"),
        "post-#917, pre-#921 allocation": ("qemu", "903223947\n"),
        "post-#921, pre-#995 allocation": ("qemu", "690697545\n"),
        "one word over": ("qemu", f"{budget + 1}\n"),
        "empty file": ("qemu", ""),
        "float": ("qemu", "9.0e8\n"),
        "unknown target": ("rpi4", "1\n"),
    }
    for name, (target, text) in refused.items():
        cases.note()
        if check(target, text) is None:
            failures.append(f"{name}: accepted")
    accepted = {
        "exactly the budget": ("qemu", f"{budget}\n"),
        "post-#995 measurement": ("qemu", "471111858\n"),
    }
    for name, (target, text) in accepted.items():
        cases.note()
        error = check(target, text)
        if error is not None:
            failures.append(f"{name}: refused: {error}")
    for failure in failures:
        print(f"ERROR\tcompile-alloc-budget-controls: {failure}")
    if failures:
        print("FAIL compile-alloc-budget controls")
        return 1
    report_pass("compile-alloc-budget controls",
                "the pre-#917, pre-#921 and pre-#995 counts, one word over, malformed counts and an "
                "unknown target are refused; the budget and the measurement pass",
                cases=cases.ran)
    return 0


if __name__ == "__main__":
    sys.exit(main())
