#!/usr/bin/env python3
"""Guarded kernel functions are called only by their reviewed callers.

Usage: buildcheck_allowed_callers.py <kernel>.facts/callgraph.tsv

GitHub issue #1107. Each row of scripts/allowed_callers.tsv names a guarded
function, the (file, function) pairs allowed to call it, and the reason. This
check reads the --facts callgraph.tsv table (scripts/call_graph_table.py), after
name resolution, and for every row refuses:

1. a function outside the allowed set that calls the guarded function or
   takes it as a value (a function-pointer reference);
2. a table in which an allowed caller no longer calls it (a claim about
   nothing).

Every row also runs three negative controls on the real table: a planted
call, a planted function-pointer reference, and the allowed calls removed;
each must be refused, or the check fails.

A caller file that a kernel does not compile (rp1_gem.tkb is RPi5-only)
is not built there: on that table the row allows no caller at all, and the
removed-call control is skipped. Every caller file must exist in the tree,
so a rename cannot make a row vacuous on every kernel.

Rows today: kernel_cpu_offset, the user_entry.S helper that reads TPIDR_EL1
(#638 stage 2; the compiler has no builtin for it, DECISIONS 2026-10-25), and
process.tkb's scheduled_process_set_exec_inode, the bare-usize store of the
judged exec inode (#1106; the token cannot cross the user_entry.S return),
and kernel_ddb_dcache_clean_invalidate, the user_entry.S dc civac helper
used only by rp1_gem.tkb's DDB RX look (#1095; no compiler builtin,
DECISIONS 2026-10-25), and the three functions of the device-address
mint kernel/drivers/dma_address.tkb (virtio_span_address,
rp1_span_bus_address, dma_span_cpu_address; #1162), whose writers are each
a reviewed place a device or the DDB look is given a span's address, and
address_space_root_mint, the maker of an AddressSpaceRoot (#693; moved here
from a regex over .tkb text under #567, which missed a function-value use).
Lexically, scripts/check_mpidr_reads.py is the sibling for MPIDR_EL1.

Exit code only (0 = pass, 1 = fail).
"""

import pathlib
import sys

import call_graph_table
from pass_line import report_pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIST = ROOT / "scripts" / "allowed_callers.tsv"


class ListError(Exception):
    pass


def read_list(path: pathlib.Path = LIST) -> list[dict]:
    rules = []
    names = set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5 or not all(f.strip() for f in fields):
            raise ListError(f"{path.name}:{number}: expected 5 non-empty "
                            "tab-separated fields")
        name, helper, callers, issue, reason = fields
        allowed = set()
        for caller in callers.split(","):
            file, sep, function = caller.partition(":")
            if not sep or not file or not function:
                raise ListError(f"{path.name}:{number}: caller {caller!r} "
                                "is not file:function")
            if not (ROOT / file).is_file():
                raise ListError(f"{path.name}:{number}: caller file {file} "
                                "does not exist")
            allowed.add((file, function))
        if name in names:
            raise ListError(f"{path.name}:{number}: duplicate check {name}")
        names.add(name)
        rules.append({"name": name, "helper": helper, "allowed": allowed,
                      "issue": issue, "reason": reason})
    if not rules:
        raise ListError(f"{path.name}: no rows")
    return rules


def built_allowed(rule: dict, table: list[dict]) -> set:
    """The allowed callers whose file this kernel compiles."""
    files = {row["file"] for row in table}
    return {pair for pair in rule["allowed"] if pair[0] in files}


def problems_in(rule: dict, table: list[dict]) -> list[str]:
    helper, allowed = rule["helper"], built_allowed(rule, table)
    problems = []
    seen = set()
    for row in table:
        uses = [call_graph_table.callee_name(e) for e in row["callees"]]
        uses += [call_graph_table.callee_name(e) for e in row["values"]]
        if helper in uses:
            seen.add((row["file"], row["name"]))
            if (row["file"], row["name"]) not in allowed:
                problems.append(f"{row['file']}: {row['name']} uses {helper}; "
                                f"{rule['reason']} ({rule['issue']})")
    for file, name in sorted(allowed - seen):
        problems.append(f"{file}: {name} no longer calls {helper}; this check "
                        "would reason about nothing")
    return problems


def controls_fail(rule: dict, table: list[dict]) -> list[str]:
    helper, allowed = rule["helper"], built_allowed(rule, table)
    failed = []
    for field, label in (("callees", "a planted call"),
                         ("values", "a planted function-pointer reference")):
        planted = [dict(row) for row in table]
        victim = next(row for row in planted
                      if row["file"].startswith("kernel/")
                      and (row["file"], row["name"]) not in allowed)
        victim[field] = victim[field] + [helper + "@-"]
        if not problems_in(rule, planted):
            failed.append(f"{label} from {victim['name']}")
    if not allowed:
        return failed
    gone = [dict(row) for row in table]
    for row in gone:
        if (row["file"], row["name"]) in allowed:
            row["callees"] = [e for e in row["callees"]
                              if call_graph_table.callee_name(e) != helper]
            row["values"] = [e for e in row["values"]
                             if call_graph_table.callee_name(e) != helper]
    if not problems_in(rule, gone):
        failed.append(f"an allowed caller no longer calling {helper}")
    return failed


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        rules = read_list()
        table = call_graph_table.read(sys.argv[1])
    except (OSError, ListError, call_graph_table.TableError) as error:
        print(f"FAIL allowed-callers: {error}")
        return 1
    failed = False
    for rule in rules:
        problems = problems_in(rule, table)
        for problem in problems:
            print(f"ERROR {rule['name']}: {problem}")
        if problems:
            print(f"FAIL {rule['name']}: {rule['helper']} has an unreviewed "
                  "caller")
            failed = True
            continue
        if not_refused := controls_fail(rule, table):
            print(f"FAIL {rule['name']}: negative control(s) "
                  f"{'; '.join(not_refused)} were accepted, so this check "
                  "proves nothing")
            failed = True
    if failed:
        return 1
    callers = sum(len(built_allowed(rule, table)) for rule in rules)
    report_pass("allowed-callers",
                f"{len(rules)} guarded functions "
                f"({', '.join(r['helper'] for r in rules)}) are called only "
                f"by their {callers} reviewed callers in {sys.argv[1]}; per "
                "row, a planted call, a pointer and a removed call are refused",
                functions=len(table))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
