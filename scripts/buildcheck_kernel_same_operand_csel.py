#!/usr/bin/env python3
"""Ceiling on csel instructions that select between one value (#893).

A `csel xd, xa, xb, cond` whose two sources are one register, or are one
register and its copy made by a `mov` among the three instructions before
it, selects nothing. #893 found them where an aggregate select or phi of a
variant reached the backend with an undefined payload field; the compiler
now splits those (split_aggregate_merges in lib/llvm_gen.ml). The ones that
remain are backend-formed scalar selects (#939). This check holds the count
at or under a per-kernel ceiling, so a codegen change that brings the
#893 shape back is refused at build time.

Usage: buildcheck_kernel_same_operand_csel.py <kernel.elf> <ceiling>
"""

import re
import sys

import buildcheck_kernel_asm_invariants as asm
from pass_line import report_pass

CHECK = "kernel-same-operand-csel"


def operands(text):
    """Mnemonic and operand list of one objdump instruction text."""
    text = text.split("//", 1)[0].strip()
    parts = text.split(None, 1)
    if not parts:
        return "", []
    ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []
    return parts[0], ops


def same_operand_csels(insns):
    """(csel count, list of (address, function, text) selecting one value)."""
    total = 0
    found = []
    recent = []
    previous_fn = None
    for address, text, fn in insns:
        if fn != previous_fn:
            recent = []
            previous_fn = fn
        mnemonic, ops = operands(text)
        if mnemonic == "csel" and len(ops) == 4:
            total += 1
            a, b = ops[1], ops[2]
            same = a == b or any(
                m == "mov" and len(o) == 2 and {o[0], o[1]} == {a, b}
                for m, o in recent[-3:])
            if same:
                found.append((address, fn, text))
        recent.append((mnemonic, ops))
    return total, found


def refused(insns, ceiling):
    """The offending csel list when the count is over the ceiling, else []."""
    _, found = same_operand_csels(insns)
    return found if len(found) > ceiling else []


def main(argv):
    if len(argv) != 3 or not re.fullmatch(r"\d+", argv[2]):
        print(__doc__, file=sys.stderr)
        return 2
    elf_path, ceiling = argv[1], int(argv[2])
    insns = asm.parse_instructions(asm.objdump_lines(elf_path))
    total, found = same_operand_csels(insns)
    if len(found) > ceiling:
        print(f"FAIL {CHECK}: {elf_path}: {len(found)} csel select between "
              f"one value, ceiling {ceiling} (#893); split the aggregate "
              "select/phi that feeds them, or lower the ceiling only with a "
              "measured reason", file=sys.stderr)
        for address, fn, text in found:
            print(f"  {address:#x} <{fn}>: {text}", file=sys.stderr)
        return 1
    report_pass(CHECK,
                f"{elf_path}: {len(found)} same-operand csel of {total}, "
                f"ceiling {ceiling}",
                csel=total)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
