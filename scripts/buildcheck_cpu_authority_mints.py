#!/usr/bin/env python3
"""CPU authority comes only from reviewed region/exception mints (#638, #1159).

Usage: buildcheck_cpu_authority_mints.py <kernel>.facts/callgraph.tsv

kernel/kernel/cpu_authority.tkb mints CpuHere, the only index a per-CPU
store accepts. A preempt_off block mints it through the private
preempt_off_enter(), which the compiler checks (#638). A public function
returning CpuHere bypasses the scoped block guarantee. The approved
exception and PMU constructors stay in the private-field module. Their
callers are checked from compiled calls and values.
Every other public return is refused. Manual authority is trusted, not a
scoped preempt_off loan.

It reads the compiler's call-graph table (docs/CALL_GRAPH.md: the
`qualifiers` and `returns` columns), not the .tkb text, so the verdict is the
compiler's view of each definition. It replaced
scripts/check_cpu_authority_mints.py's regular expressions (#567); that
check's reviewed-callers list had been empty since #1080, and a new
exception would be a row of scripts/allowed_callers.tsv.

Refused:
1. a public CpuHere return other than the exact approved constructors;
   their own caller rules also refuses foreign calls and function values;
2. a table with no private CpuHere mint in cpu_authority.tkb at all, so a
   rename of the authority or of its file cannot leave the check vacuous.
Negative controls on the real table: a planted public mint must be refused.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
import buildcheck_allowed_callers as allowed_callers
from pass_line import report_pass

AUTHORITY = "CpuHere"
MINT_FILE = "kernel/kernel/cpu_authority.tkb"
EXCEPTION_MINT = "exception_cpu_here"
EXCEPTION_RULE = "cpu-exception-authority-callers"
PMU_MINT = "pmu_sample_cpu_here"
PMU_RULE = "pmu-sample-authority-callers"
PMU_CALLER = ("kernel/kernel/profile_samples.tkb", "profile_sample_irq")
PMU_HANDLER_RULE = "pmu-sample-handler-callers"
PMU_HANDLER_CALLERS = {
    (f"kernel/platform/{platform}/irq_source.tkb", "irq_pmu_clear")
    for platform in ("qemu", "rpi5")
}


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
        if row['file'] == MINT_FILE and row['name'] in (EXCEPTION_MINT, PMU_MINT):
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
    exception = [row for row in rows
                 if row['file'] == MINT_FILE and row['name'] == EXCEPTION_MINT]
    rules = {rule['name']: rule for rule in allowed_callers.read_list()}
    if len(exception) != 1 or EXCEPTION_RULE not in rules:
        found.append('the exact exception constructor and its exact caller rule must both exist')
    else:
        rule = rules[EXCEPTION_RULE]
        if (rule['helper'] != EXCEPTION_MINT or
                any(file != 'kernel/arch/arm64/kernel/exception_evidence.tkb'
                    for file, _ in rule['allowed'])):
            found.append('exception constructor permission is confined to reviewed exception_evidence callers')
        found.extend(allowed_callers.problems_in(rule, rows))
        found.extend(allowed_callers.controls_fail(rule, rows))
    pmu = [row for row in rows if row['file'] == MINT_FILE and row['name'] == PMU_MINT]
    if len(pmu) != 1 or pmu[0]['returns'] != AUTHORITY or 'interrupt' not in pmu[0]['declared']:
        found.append('the exact PMU interrupt CPU authority constructor must exist')
    for name, helper, callers in (
            (PMU_RULE, PMU_MINT, {PMU_CALLER}),
            (PMU_HANDLER_RULE, PMU_CALLER[1], PMU_HANDLER_CALLERS)):
        rule = rules.get(name)
        if rule is None or rule['helper'] != helper or rule['allowed'] != callers:
            found.append(f'{helper} must have its exact PMU caller rule')
            continue
        found.extend(allowed_callers.problems_in(rule, rows))
        found.extend(allowed_callers.controls_fail(rule, rows))
    for mint in (EXCEPTION_MINT, PMU_MINT):
        foreign = dict(planted, name=mint)
        if not problems(rows + [foreign]):
            found.append(f'a planted {mint} constructor in another file was accepted')
    if found:
        for line in found:
            print(f"ERROR cpu-authority-mints: {line}")
        return 1
    report_pass("cpu-authority-mints",
                f"{len(rows)} functions admit only the reviewed exception and PMU mints "
                "beside region entry; foreign calls, function values and public "
                "counterfeit mints are refused", functions=len(rows), exception_mints=len(exception))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
