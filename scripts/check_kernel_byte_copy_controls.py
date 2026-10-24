#!/usr/bin/env python3
"""Offline controls for buildcheck_kernel_byte_copy.py (#962, #963)."""

import buildcheck_kernel_byte_copy as checker

from pass_line import CaseCount, report_pass

CASES = CaseCount()


def stores(fn, base, offsets, mnemonic="strb"):
    return [(0x1000 + 4 * i, f"{mnemonic}\tw{i % 8}, [{base}, #{off:#x}]", fn)
            for i, off in enumerate(offsets)]


def flagged(insns):
    CASES.note()
    return [fn for fn, run in checker.longest_runs(insns).items()
            if run[2] >= checker.RUN]


# The shape ddb_stack_process had: the 24-byte command stored one byte at a
# time into the result buffer, out of order.
COPY = stores("ddb_stack_process", "x8",
              [0x80 + k for k in (3, 0, 1, 2)] + [0x84 + k for k in range(20)])
# Sixteen byte fields, every other byte: no run.
FIELDS = stores("fields", "x0", range(0, 32, 2))
# Sixteen consecutive bytes split across two base registers: no run.
SPLIT = stores("split", "x0", range(8)) + stores("split", "x1", range(8, 16))


def main():
    if flagged(COPY) != ["ddb_stack_process"]:
        print("FAIL byte-copy controls: a 24-byte element-wise copy was not seen")
        return 1
    if flagged(stores("unscaled", "x29", range(-0x42, -0x42 + 16), "sturb")) \
            != ["unscaled"]:
        print("FAIL byte-copy controls: a run of sturb at negative offsets was not seen")
        return 1
    if flagged(FIELDS) or flagged(SPLIT):
        print("FAIL byte-copy controls: scattered byte stores counted as a copy")
        return 1
    if flagged(stores("short", "sp", range(checker.RUN - 1))):
        print("FAIL byte-copy controls: a run shorter than the threshold counted")
        return 1
    # At the ceiling passes; one above it is refused.
    CASES.note()
    at = checker.refused(COPY + FIELDS, 1)
    CASES.note()
    above = checker.refused(COPY + FIELDS, 0)
    if at or len(above) != 1:
        print("FAIL byte-copy controls: ceiling not enforced")
        return 1
    report_pass("byte-copy controls",
                "a 24-byte element-wise copy and a sturb run are seen, byte "
                "fields and runs split across bases are not, and one above "
                "the ceiling is refused",
                cases=CASES.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
