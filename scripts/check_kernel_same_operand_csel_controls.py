#!/usr/bin/env python3
"""Offline controls for buildcheck_kernel_same_operand_csel.py (#893)."""

import buildcheck_kernel_same_operand_csel as checker

from pass_line import CaseCount, report_pass

CASES = CaseCount()


def count(insns):
    CASES.note()
    return len(checker.same_operand_csels(insns)[1])


# The #893 shape, as address_space_root_slot_valid had it.
PLANTED = [
    (0x1000, "mov\tx8, x0", "root_valid"),
    (0x1004, "cmp\tx0, #0x0", "root_valid"),
    (0x1008, "csel\tx0, x8, x0, eq", "root_valid"),
]
DIRECT = [(0x2000, "csel\tx1, x8, x8, lo", "page_index")]
DISTINCT = [
    (0x3000, "mov\tw9, #0x2", "f"),
    (0x3004, "csel\tw9, w10, w9, eq", "f"),
]


def main():
    if count(PLANTED) != 1 or count(DIRECT) != 1:
        print("FAIL same-operand-csel controls: a planted csel was not seen")
        return 1
    if count(DISTINCT) != 0:
        print("FAIL same-operand-csel controls: distinct sources counted")
        return 1
    # A mov in another function does not make the sources one value.
    moved = [(0x4000, "mov\tx8, x0", "a"), (0x4004, "csel\tx0, x8, x0, eq", "b")]
    if count(moved) != 0:
        print("FAIL same-operand-csel controls: a mov leaked across functions")
        return 1
    # At the ceiling passes; one planted above it is refused.
    CASES.note()
    at = checker.refused(DIRECT + DISTINCT, 1)
    CASES.note()
    above = checker.refused(DIRECT + DISTINCT + PLANTED, 1)
    if at or len(above) != 2:
        print("FAIL same-operand-csel controls: ceiling 1 not enforced")
        return 1
    report_pass("same-operand-csel controls",
                "the #893 mov+csel and direct same-register csel are counted, "
                "distinct sources are not, and one above the ceiling is refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
