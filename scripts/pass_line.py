#!/usr/bin/env python3
"""The one place a `scripts/check_*.py` prints its PASS line.

A verdict that cannot tell "the property holds" from "I never looked" is
worth less than no verdict, because it is read as the former. Four mechanisms
in one session reported PASS about nothing: a lock check whose every tag had
been renamed out from under it, a two-core probe that visited no slot at all,
a depfile check whose scan roots had stopped covering a whole directory, and
a memory-map check whose table parse stopped at a conflict marker with
nineteen rows below it unread. Two more turned up the same week.

The shape is always the same. The number that would have said "nothing was
examined" is either not computed, or computed and PRINTED rather than
ASSERTED. Printing is not enough: every one of those was caught by a person
noticing a number that happened to share a line with one that mattered, not
by the build.

So the count goes through here. `report_pass` takes the check's own wording
plus the counts its verdict rests on, and refuses to print PASS when one of
them is zero:

    pass_line.report_pass(
        "stale-depfiles",
        f"{len(depfiles)} generated depfiles have live prerequisites",
        depfiles=len(depfiles),
    )

Pick the count that is zero when the check did no work. That is usually the
size of the set it scanned, not the number of findings: a check that
legitimately finds nothing still examined something, and it is the examining
that has to be proved. `scripts/check_dead_slot_peek_not_retained.py` and
`scripts/check_kernel_asm_invariants.py` wrote that guard by hand before this
helper existed, and remain the worked examples.

A nonzero count is not a claim that the set was COMPLETE. The depfile blind
spot printed "7 generated depfiles" while missing an eighth in a directory
outside its roots, and would have passed this guard. Where completeness is
the property at risk, compare the count against a separately discovered
total, the way `scripts/check_kernel_memory_map.py` counts state-tagged rows
across the whole document and compares that with the number its table parser
returned.

`scripts/check_pass_line_counts.py` enforces that every check reports through
here.
"""

from __future__ import annotations

import sys


def report_pass(check: str, message: str, *, stream=None,
                **examined: int) -> None:
    """Print one PASS line, or exit 1 rather than pass about nothing.

    `check` is the verdict tag ("stale-depfiles"), `message` the check's own
    sentence, and `examined` the counts that are zero when nothing was
    looked at. At least one is required.

    `stream` moves the line off stdout, which one check needs: the batched
    UART report in `check_suite_output.py` is read field by field by
    `scripts/run_qemutest.sh`, and a human sentence in that stream is a row
    the reader silently drops.
    """
    if not examined:
        print(
            f"ERROR {check}: reported PASS without naming anything it "
            "examined. Pass the count that is zero when the check did no "
            "work; see scripts/pass_line.py.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    empty = sorted(
        (name, count) for name, count in examined.items() if count <= 0
    )
    if empty:
        detail = ", ".join(f"{name}={count}" for name, count in empty)
        print(
            f"ERROR {check}: would have reported PASS having examined "
            f"nothing ({detail}). The property is not established -- the "
            "scan found no input. Fix what the check looks at, and if an "
            "empty set is genuinely the right answer, say so in the check "
            "rather than reporting a verdict about it.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    print(f"PASS {check}: {message}", file=stream or sys.stdout)
