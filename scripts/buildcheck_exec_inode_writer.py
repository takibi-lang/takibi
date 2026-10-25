#!/usr/bin/env python3
"""The judged exec inode is written only by syscall.tkb's token store.

Usage: buildcheck_exec_inode_writer.py <kernel>.callgraph.tsv

GitHub issue #1106. After #1082 the inode execve judged travels as a
SyscallExecInode, a token whose field is private to kernel/kernel/syscall.tkb,
so only that file's verdict can mint one. The token cannot cross the
user_entry.S return (#1080), so it is parked as bits in the process record by
process.tkb's scheduled_process_set_exec_inode, which takes a bare usize. A
call to that setter from any other function would store an inode the format
check never judged, and the exec prepare would load it. This check reads the
--emit-call-graph table (scripts/call_graph_table.py) and refuses:

1. a function other than ALLOWED that calls the setter or takes it as a value;
2. a table in which ALLOWED does not call it (a claim about nothing).

The setter cannot take the token instead: the token's field is private to
syscall.tkb, so process.tkb could not read it, and a private setter would be
file-local to process.tkb and forbid the one legitimate caller. Sibling: buildcheck_cpu_offset_callers.py.

Exit code only (0 = pass, 1 = fail).
"""

import sys

import call_graph_table
from pass_line import report_pass

HELPER = "scheduled_process_set_exec_inode"
ALLOWED = {("kernel/kernel/syscall.tkb", "syscall_exec_inode_store")}
NAME = "exec-inode-writer"


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
                                "the exec inode is stored only from a "
                                "SyscallExecInode by syscall.tkb's "
                                "syscall_exec_inode_store (#1106)")
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
        failed.append("the allowed caller no longer calling the setter")
    return failed


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        table = call_graph_table.read(sys.argv[1])
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL {NAME}: {error}")
        return 1
    problems = problems_in(table)
    for problem in problems:
        print(f"ERROR {NAME}: {problem}")
    if problems:
        print(f"FAIL {NAME}: the exec inode has an unreviewed writer")
        return 1
    if not_refused := controls_fail(table):
        print(f"FAIL {NAME}: negative control(s) "
              f"{'; '.join(not_refused)} were accepted, so this check proves nothing")
        return 1
    report_pass(NAME,
                f"{HELPER} is called only by {len(ALLOWED)} reviewed function "
                f"in {sys.argv[1]}; planted calls and a pointer are refused",
                functions=len(table))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
