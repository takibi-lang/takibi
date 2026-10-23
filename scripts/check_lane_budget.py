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


def lane_seconds(directory: pathlib.Path) -> tuple[float, int] | None:
    files = sorted(directory.glob("*.jsonl")) if directory.is_dir() else []
    if not files:
        return None
    total, count = 0.0, 0
    for path in files:
        for line in path.read_text().splitlines():
            if line.strip():
                total += float(json.loads(line)["elapsed"])
                count += 1
    return total, count


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
    seconds = lane_seconds(TIMING_DIR)
    failures = verdict(len(leaves), seconds)
    for failure in failures:
        print(f"FAIL lane-budget: {failure}")
    if failures:
        return 1
    timing = ("no lane timing artifact to read" if seconds is None else
              f"last allcheck {seconds[0]:.0f} of at most "
              f"{LANE_SECONDS_LIMIT:.0f} lane-seconds")
    report_pass("lane-budget",
                f"{len(leaves)} of at most {QEMU_LANE_LIMIT} QEMU lanes; {timing}",
                lanes=len(leaves))
    return 0


if __name__ == "__main__":
    sys.exit(main())
