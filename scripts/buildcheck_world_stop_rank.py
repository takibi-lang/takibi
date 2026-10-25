#!/usr/bin/env python3
"""The world stop holds the lowest lock rank; its unranked body is probe-only.

Usage: buildcheck_world_stop_rank.py <kernel>.callgraph.tsv

GitHub issue #641 keeps the compiler's lock-order check covering the world
stop's retry liveness (kernel/models/WorldStopRetry.tla, variant holdlock):

- `world_stop_machine_begin` declares an `acquires_lock_<rank>_world_stop`
  effect whose rank is below every other lock class's, so a caller holding
  any ranked guard cannot begin a stop its peers cannot acknowledge;
- its unranked body, `world_stop_machine_begin_holding_probe`, is called
  only from `world_stop_machine_begin` or from a function whose name ends
  in `_probe` (a single attempt that may hold a guard across a stop).

GitHub issue #567: these two rules used to be regular expressions over the
kernel's .tkb text inside check_world_stop_refusals.py. They now read the
compiler's --emit-call-graph table of the kernel just compiled
(scripts/call_graph_table.py): the ranks from the `declared` column, the
callers from the `callers` column. A rank or a call kept only in a comment
is not in the table, by construction. The kernel recipes run this on each
kernel's own table.

Exit code only (0 = pass, 1 = fail).
"""

import re
import sys

import call_graph_table
from pass_line import report_pass

BEGIN = "world_stop_machine_begin"
UNRANKED = "world_stop_machine_begin_holding_probe"
FILE = "kernel/lib/occupancy.tkb"
RANK = re.compile(r"^acquires_lock_([0-9]+)_([A-Za-z_0-9]+)$")


def declared_ranks(row: dict) -> list[tuple[int, str]]:
    if row["declared"] in ("-", "{}"):
        return []
    ranks = []
    for effect in row["declared"].split(","):
        match = RANK.match(effect.strip())
        if match:
            ranks.append((int(match.group(1)), match.group(2)))
    return ranks


def rank_problems(rows: list[dict]) -> tuple[list[str], int, int]:
    """Problems, the lock classes compared, the probe callers seen."""
    problems = []
    begins = [row for row in rows if row["name"] == BEGIN and row["file"] == FILE]
    bodies = [row for row in rows if row["name"] == UNRANKED and row["file"] == FILE]
    if len(begins) != 1 or len(bodies) != 1:
        problems.append(f"{BEGIN} and {UNRANKED} are not each defined once in "
                        f"{FILE}; a rename would leave this check matching nothing")
        return problems, 0, 0
    stop = [rank for rank, name in declared_ranks(begins[0]) if name == "world_stop"]
    if len(stop) != 1:
        problems.append(f"{BEGIN} declares no acquires_lock_<rank>_world_stop (#641)")
        return problems, 0, 0
    stop_rank = stop[0]
    others = {}
    for row in rows:
        for rank, name in declared_ranks(row):
            if name != "world_stop":
                others.setdefault((rank, name), row)
    for (rank, name), row in sorted(others.items()):
        if rank <= stop_rank:
            problems.append(
                f"{row['file']}:{row['line']} {row['name']}: lock class {name} "
                f"has rank {rank}, not above the world stop's {stop_rank}: a "
                "caller holding it could begin a stop its peers cannot "
                "acknowledge (#641)")
    callers = 0
    for entry in bodies[0]["callers"]:
        caller = call_graph_table.callee_name(entry)
        callers += 1
        if caller == BEGIN and call_graph_table.callee_file(entry) == FILE:
            continue
        if caller.endswith("_probe"):
            continue
        problems.append(
            f"{entry}: {caller} calls {UNRANKED}, which carries no lock rank; "
            "only a single-attempt *_probe may hold a guard across a stop (#641)")
    return problems, len({name for _, name in others}), callers


def planted(rows: list[dict], name: str, column: str, change) -> list[dict]:
    matches = [row for row in rows if row["name"] == name]
    if len(matches) != 1:
        raise SystemExit(f"FAIL world-stop-rank: the negative control's subject "
                         f"{name} is in the table {len(matches)} times, not once")
    copy = [dict(row) for row in rows]
    target = next(row for row in copy if row["name"] == name)
    target[column] = change(target[column])
    return copy


def controls_fail(rows: list[dict]) -> list[str]:
    """Defects planted in the table that must be refused; the ones that are not."""
    failed = []
    retry = planted(rows, UNRANKED, "callers",
                    lambda callers: callers + ["kernel_retry@kernel/x.tkb:1"])
    if not rank_problems(retry)[0]:
        failed.append("a non-probe caller of the unranked body")
    unranked = planted(rows, BEGIN, "declared",
                       lambda declared: declared.replace("acquires_lock_10_world_stop",
                                                         "unsafe"))
    if not rank_problems(unranked)[0]:
        failed.append("a stop with no declared rank")
    low = planted(rows, BEGIN, "declared",
                  lambda declared: declared + ",acquires_lock_5_console")
    if not rank_problems(low)[0]:
        failed.append("a lock class ranked below the stop")
    renamed = planted(rows, BEGIN, "name", lambda _: "world_stop_begin_all")
    if not rank_problems(renamed)[0]:
        failed.append("a renamed stop")
    return failed


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        rows = call_graph_table.read(sys.argv[1])
    except (OSError, call_graph_table.TableError) as error:
        print(f"FAIL world-stop-rank: {error}")
        return 1
    problems, classes, callers = rank_problems(rows)
    for problem in problems:
        print(f"ERROR world-stop-rank: {problem}")
    if problems:
        print("FAIL world-stop-rank: the world stop's lock rank does not cover its retry")
        return 1
    if not_refused := controls_fail(rows):
        print("FAIL world-stop-rank: negative control(s) "
              f"{'; '.join(not_refused)} were accepted, so this check proves nothing")
        return 1
    report_pass(
        "world-stop-rank",
        f"the stop's rank is below {classes} other lock class(es) and "
        f"{callers} caller(s) of its unranked body are the stop or a probe, "
        f"in {sys.argv[1]}",
        lock_classes=classes, probe_callers=callers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
