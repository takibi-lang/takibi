#!/usr/bin/env python3
"""TPIDR_EL1 is read only by the CPU authority's preempt_slot().

Usage: buildcheck_cpu_offset_callers.py <kernel>.callgraph.tsv

GitHub issue #638 stage 2. TPIDR_EL1 holds this core's index times the
per-core stack group stride, and kernel/kernel/cpu_authority.tkb uses it to
reach this CPU's preempt count without a CpuHere. The register is read by
the one-move assembly helper kernel_cpu_offset (user_entry.S); the compiler
has no builtin for it (DECISIONS 2026-10-25). Any other caller would be a
second, unreviewed way to name the current CPU, so this check reads the
--emit-call-graph table (scripts/call_graph_table.py) and refuses:

1. a function other than ALLOWED that calls kernel_cpu_offset or takes it
   as a value;
2. a table in which ALLOWED does not call it (a claim about nothing).

Lexically, scripts/check_mpidr_reads.py is the sibling for MPIDR_EL1. This
one is a build check because the helper is an extern, and the table names
every call and function-pointer reference after name resolution.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
from pass_line import report_pass

HELPER = "kernel_cpu_offset"
ALLOWED = {("kernel/kernel/cpu_authority.tkb", "preempt_slot")}


def problems_in(table: list[dict]) -> list[str]:
    problems = []
    seen = set()
    for row in table:
        uses = [call_graph_table.callee_name(e) for e in row["callees"]]
        uses += [call_graph_table.callee_name(e) for e in row["values"]]
        if HELPER in uses:
            seen.add((row["file"], row["name"]))
            if (row["file"], row["name"]) not in ALLOWED:
                problems.append(f"{row['file']}: {row['name']} uses {HELPER}; "
                                "TPIDR_EL1 is read only by cpu_authority.tkb's "
                                "preempt_slot()")
    for file, name in sorted(ALLOWED - seen):
        problems.append(f"{file}: {name} no longer calls {HELPER}; this check "
                        "would reason about nothing")
    return problems


def controls_fail(table: list[dict]) -> list[str]:
    failed = []
    planted = [dict(row) for row in table]
    victim = next(row for row in planted if row["file"].startswith("kernel/")
                  and (row["file"], row["name"]) not in ALLOWED)
    victim["callees"] = victim["callees"] + [HELPER + "@-"]
    if not problems_in(planted):
        failed.append("a planted call from " + victim["name"])
    pointer = [dict(row) for row in table]
    victim = next(row for row in pointer if row["file"].startswith("kernel/")
                  and (row["file"], row["name"]) not in ALLOWED)
    victim["values"] = victim["values"] + [HELPER + "@-"]
    if not problems_in(pointer):
        failed.append("a planted function-pointer reference")
    gone = [dict(row) for row in table]
    for row in gone:
        if (row["file"], row["name"]) in ALLOWED:
            row["callees"] = [e for e in row["callees"]
                              if call_graph_table.callee_name(e) != HELPER]
    if not problems_in(gone):
        failed.append("the allowed caller no longer calling the helper")
    return failed


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        table = call_graph_table.read(sys.argv[1])
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL cpu-offset-callers: {error}")
        return 1
    problems = problems_in(table)
    for problem in problems:
        print(f"ERROR cpu-offset-callers: {problem}")
    if problems:
        print("FAIL cpu-offset-callers: TPIDR_EL1 has an unreviewed reader")
        return 1
    if not_refused := controls_fail(table):
        print("FAIL cpu-offset-callers: negative control(s) "
              f"{'; '.join(not_refused)} were accepted, so this check proves nothing")
        return 1
    report_pass("cpu-offset-callers",
                f"{HELPER} is called only by {len(ALLOWED)} reviewed function "
                f"in {sys.argv[1]}; planted calls and a pointer are refused",
                functions=len(table))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
