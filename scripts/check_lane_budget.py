#!/usr/bin/env python3
"""allcheck's QEMU lanes stay inside a fixed budget (GitHub issue #908).

Land time grows with every QEMU lane. The #886 land ran 34 lanes on 24 host
threads, span 1128 s and about 9000 lane-seconds, so allcheck is throughput
bound and each new lane adds roughly its own cost. Error-case reproductions
keep arriving, and the habit was one new lane each; no single one looked
wrong. This is the same membership rule as check_roadmap_size.py: when the
budget is met, fold the new case into an existing lane (docs/LANE_INVENTORY.md
says which lanes are error-case demonstrations), do not raise the number.
Raising either number is the maintainer's decision.

Two bounds:

  QEMU_LANE_LIMIT  leaf QEMU lanes allcheck runs: KERNELCHECK_QEMU_LANES in
                   the Makefile, with an aggregate member (kernelcheck-qemu,
                   kernelcheck-qemu-debug) expanded into the lanes it runs.
                   Leaves are what each costs a guest and a receipt. 25 on
                   2026-10-23, the count when the budget was set.

  LANE_SECONDS_LIMIT  the summed elapsed time of every receipt in the last
                   allcheck's lane timing artifact (_build/lane-timing, one
                   JSON record per lane, written by scripts/lane_timing.sh).
                   The 2026-10-23 allcheck in the main checkout measured
                   6825 s (5598 s of it in QEMU lanes); #886 measured about
                   9000 s. The limit is 9000 s: today plus about 30 % for
                   host load. Checked only when the artifact is present,
                   since a fresh worktree has none; a partial artifact (this
                   gate runs beside allcheck's lanes) can only sum lower.

Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

from pass_line import report_pass

MAKEFILE = pathlib.Path("Makefile")
TIMING_DIR = pathlib.Path("_build/lane-timing")
QEMU_LANE_LIMIT = 25
LANE_SECONDS_LIMIT = 9000.0


def rules(text: str) -> dict[str, list[str]]:
    """Target -> prerequisites, continuation lines joined; `$VAR` too."""
    joined = re.sub(r"\\\n", " ", text)
    table: dict[str, list[str]] = {}
    for line in joined.splitlines():
        if line.startswith(("\t", "#", ".")):
            continue
        var = re.match(r"^([A-Z_0-9]+)\s*:=(.*)$", line)
        if var:
            table["$" + var.group(1)] = var.group(2).split()
            continue
        rule = re.match(r"^([a-z0-9_-]+)\s*:(?!=)(.*)$", line)
        if rule:
            table.setdefault(rule.group(1), []).extend(rule.group(2).split())
    return table


def qemu_leaf_lanes(text: str) -> list[str]:
    table = rules(text)
    members = table.get("$KERNELCHECK_QEMU_LANES")
    if not members:
        raise ValueError("KERNELCHECK_QEMU_LANES not found in the Makefile")
    leaves: list[str] = []

    def expand(name: str) -> None:
        deps = table.get(name)
        if deps is None:
            raise ValueError(f"lane {name} has no rule in the Makefile")
        sub = [d for d in deps if d.startswith("kernelcheck-")]
        if sub and len(sub) == len(deps):
            for d in sub:
                expand(d)
        else:
            leaves.append(name)

    for name in members:
        expand(name)
    return leaves


def lease_waits(directory: pathlib.Path) -> dict[str, list[tuple[float, float]]] | None:
    """Lane -> granted (start, end) vCPU lease waits; None without the file."""
    path = directory / "vcpu-lease.waits"
    if not path.is_file():
        return None
    waits: dict[str, list[tuple[float, float]]] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        wait = json.loads(line)
        if wait.get("granted") is None:
            continue
        waits.setdefault(str(wait["lane"]), []).append(
            (float(wait["wait_start"]), float(wait["granted"])))
    return waits


def waited(spans: list[tuple[float, float]], start: float, finish: float) -> float:
    """Seconds of [start, finish] covered by at least one wait. A lane that
    leases for several guests at once (alloc-rollback) waits in parallel, and
    summing those would count one idle second several times."""
    total, reach = 0.0, start
    for lo, hi in sorted(spans):
        lo, hi = max(lo, reach), min(hi, finish)
        if hi > lo:
            total += hi - lo
            reach = hi
    return total


def lane_seconds(directory: pathlib.Path,
                 qemu_lanes: frozenset[str] = frozenset()) -> tuple[float, int] | None:
    """Busy lane-seconds: each receipt's elapsed time less the time it spent
    waiting for vCPUs (#927). Raises ValueError when a QEMU lane finished and
    the run recorded no lease waits: every acquire appends one, so the file's
    absence means the recording broke, and the waits would count as work."""
    files = sorted(directory.glob("*.jsonl")) if directory.is_dir() else []
    if not files:
        return None
    records = []
    for path in files:
        for line in path.read_text().splitlines():
            if line.strip():
                records.append(json.loads(line))
    waits = lease_waits(directory)
    if waits is None:
        finished = sorted(r["lane"] for r in records if r["lane"] in qemu_lanes)
        if finished:
            raise ValueError(
                f"{finished[0]} finished but {directory}/vcpu-lease.waits is "
                "missing, so the lane-seconds cannot leave out the lease wait")
        waits = {}
    total = 0.0
    for record in records:
        elapsed = float(record["elapsed"])
        spans = waits.get(record["lane"], [])
        if spans and "start" in record:
            start = float(record["start"])
            elapsed -= waited(spans, start, start + elapsed)
        total += elapsed
    return total, len(records)


def verdict(leaves: int, seconds: tuple[float, int] | None,
            lane_limit: int = QEMU_LANE_LIMIT,
            seconds_limit: float = LANE_SECONDS_LIMIT) -> list[str]:
    failures = []
    if leaves > lane_limit:
        failures.append(
            f"allcheck runs {leaves} QEMU lanes, over the budget of {lane_limit}. "
            "Put a new error case into an existing lane (docs/LANE_INVENTORY.md); "
            "a new lane needs the maintainer (AGENTS.md)")
    if seconds is not None and seconds[0] > seconds_limit:
        failures.append(
            f"the last allcheck spent {seconds[0]:.0f} lane-seconds over "
            f"{seconds[1]} receipts, over the budget of {seconds_limit:.0f}. "
            "Find the lane that grew (scripts/summarize_lane_timing.py) "
            "rather than raising the number")
    return failures


def main() -> int:
    leaves = qemu_leaf_lanes(MAKEFILE.read_text(encoding="ascii"))
    try:
        seconds = lane_seconds(TIMING_DIR, frozenset(leaves))
    except ValueError as error:
        print(f"FAIL lane-budget: {error}")
        return 1
    failures = verdict(len(leaves), seconds)
    for failure in failures:
        print(f"FAIL lane-budget: {failure}")
    if failures:
        return 1
    timing = ("no lane timing artifact to read" if seconds is None else
              f"last allcheck {seconds[0]:.0f} of at most "
              f"{LANE_SECONDS_LIMIT:.0f} busy lane-seconds")
    report_pass("lane-budget",
                f"{len(leaves)} of at most {QEMU_LANE_LIMIT} QEMU lanes; {timing}",
                lanes=len(leaves))
    return 0


if __name__ == "__main__":
    sys.exit(main())
