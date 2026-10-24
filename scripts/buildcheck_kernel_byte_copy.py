#!/usr/bin/env python3
"""No byte-by-byte copy of an array in the linked kernel (#962, #963).

LLVM lowers a first-class aggregate load, store, argument or return leaf by
leaf, so a value holding a [512 x i8] array was copied with 512 byte loads
and 512 byte stores: five process-diagnostic functions were 8 KiB each, and
ProcessDdbRecord's 24-byte command grew seven DDB functions by 1.8 KiB
(#888) before anyone measured. The compiler now copies such values with
llvm.memcpy.inline (lib/llvm_gen.ml, lower_array_holding_stores and the
sret result slot), which the backend expands into wide loads and stores.

The signature this refuses is a run of byte stores (strb/sturb with an
immediate offset) from one base register covering RUN or more consecutive
byte offsets in one function. Byte fields stored one at a time do not form
such a run; an element-wise array copy does. The number of functions with
one stays at or under the ceiling.

Usage: buildcheck_kernel_byte_copy.py <kernel.elf> <ceiling>
"""

import re
import sys

import buildcheck_kernel_asm_invariants as asm
from pass_line import report_pass

CHECK = "kernel-byte-copy"
RUN = 16
STORE_RE = re.compile(
    r"^(?:strb|sturb)\s+w\d+,\s+\[(x\d+|sp)(?:,\s+#(-?(?:0x)?[0-9a-f]+))?\]$")


def longest_runs(insns):
    """{function: (base register, first offset, length)} of each function's
    longest run of consecutive byte-store offsets from one base."""
    offsets = {}
    for _, text, fn in insns:
        m = STORE_RE.match(text.split("//", 1)[0].strip())
        if m:
            off = int(m.group(2), 0) if m.group(2) else 0
            offsets.setdefault((fn, m.group(1)), set()).add(off)
    best = {}
    for (fn, base), seen in offsets.items():
        for start in seen:
            if start - 1 in seen:
                continue
            length = 1
            while start + length in seen:
                length += 1
            if fn not in best or length > best[fn][2]:
                best[fn] = (base, start, length)
    return best


def refused(insns, ceiling):
    """The (function, run) list when more than `ceiling` functions hold a
    byte-copy run, else []."""
    found = sorted((fn, run) for fn, run in longest_runs(insns).items()
                   if run[2] >= RUN)
    return found if len(found) > ceiling else []


def main(argv):
    if len(argv) != 3 or not re.fullmatch(r"\d+", argv[2]):
        print(__doc__, file=sys.stderr)
        return 2
    elf_path, ceiling = argv[1], int(argv[2])
    insns = asm.parse_instructions(asm.objdump_lines(elf_path))
    runs = longest_runs(insns)
    found = sorted((fn, run) for fn, run in runs.items() if run[2] >= RUN)
    if len(found) > ceiling:
        print(f"FAIL {CHECK}: {elf_path}: {len(found)} function(s) store "
              f"{RUN} or more consecutive bytes one at a time, ceiling "
              f"{ceiling} (#962/#963): an array-holding value is copied "
              "element by element; find the aggregate load, store, argument "
              "or return that reached the backend whole", file=sys.stderr)
        for fn, (base, start, length) in found:
            print(f"  <{fn}>: {length} byte stores at [{base}, #{start:#x}] "
                  "onward", file=sys.stderr)
        return 1
    longest = max((run[2] for run in runs.values()), default=0)
    report_pass(CHECK,
                f"{elf_path}: {len(found)} function(s) with a byte-copy run "
                f"of {RUN}+ stores, ceiling {ceiling}; longest run {longest}",
                functions=len(runs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
