#!/usr/bin/env python3
"""Only a preempt_off block mints the CPU authority (#704, #1080, #567).

Usage: buildcheck_cpu_authority_mints.py <kernel>.facts/callgraph.tsv

kernel/kernel/cpu_authority.tkb mints CpuHere, the only index a per-CPU
store accepts. A preempt_off block mints it through the private
preempt_off_enter(), which the compiler checks (#638). A public function
returning CpuHere would bypass the block, and the compiler cannot tell it
from the block's mint at a call, so this check refuses one.

It reads the compiler's call-graph table (docs/CALL_GRAPH.md: the
`qualifiers` and `returns` columns), not the .tkb text, so the verdict is the
compiler's view of each definition. It replaced
scripts/check_cpu_authority_mints.py's regular expressions (#567); that
check's reviewed-callers list had been empty since #1080, and a new
exception would be a row of scripts/allowed_callers.tsv.

Refused:
1. a function that is not `private` and whose declared return type is
   CpuHere, anywhere in the program;
2. a table with no private CpuHere mint in cpu_authority.tkb at all, so a
   rename of the authority or of its file cannot leave the check vacuous.
Negative controls on the real table: a planted public mint must be refused.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
from pass_line import report_pass

AUTHORITY = "CpuHere"
MINT_FILE = "kernel/kernel/cpu_authority.tkb"


def problems(rows):
    found = []
    mints = 0
    for row in rows:
        if row["returns"] != AUTHORITY:
            continue
        if "private" in row["qualifiers"]:
            if row["file"] == MINT_FILE:
                mints += 1
            continue
        found.append(f"{row['file']}:{row['line']}: {row['name']} is a public "
                     f"function returning {AUTHORITY}, a CPU-authority mint "
                     "outside a preempt_off block")
    if mints == 0:
        found.append(f"no private {AUTHORITY} mint in {MINT_FILE}: the check "
                     "would hold nothing (was the authority or its file renamed?)")
    return found


def main(argv):
    if len(argv) != 2:
        print(__doc__.split("\n\n")[1])
        return 1
    rows = call_graph_table.read(argv[1])
    planted = dict(rows[0], file="kernel/x.tkb", line="1", name="any_cpu",
                   qualifiers=[], returns=AUTHORITY)
    if not problems(rows + [planted]) or problems([dict(planted, qualifiers=["private"], file=MINT_FILE)]):
        print("FAIL cpu-authority-mints: the check's own controls no longer behave")
        return 1
    found = problems(rows)
    if found:
        for line in found:
            print(f"ERROR cpu-authority-mints: {line}")
        return 1
    report_pass("cpu-authority-mints",
                f"no public function of {len(rows)} returns {AUTHORITY}; its "
                "one mint is a preempt_off block (call-graph table; a planted "
                "public mint is refused)", functions=len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
