#!/usr/bin/env python3
"""Fail a CI part that used more than its time budget (GitHub issue #816).

usage: ci_time_budget.py JOB_START_EPOCH [LANE_TIMING_DIR]

The hardware-free job's `timeout-minutes` in .github/workflows/ci.yml is a
hard limit: a part that reaches it is cancelled with no verdict and, before
#816, no timing either (the failure-evidence upload runs on failure, not on
cancellation). cicheck reached it on 2026-10-17 after growing for weeks with
every run still green, so nothing said it was growing. This step runs after
the checks and fails the part once it has used more than BUDGET_FRACTION of
the limit, while the part still finishes and its lane timing is printed --
a red run that names the slowest lanes instead of a cancelled one.

The fix for a red budget is never only a higher limit: split the part, or
explain the growth (the issue's "no unexplained growth" rule).
"""

import json
import pathlib
import re
import sys
import time

CI = pathlib.Path(".github/workflows/ci.yml")
BUDGET_FRACTION = 0.75
JOB = "hardware-free"


def job_limit_minutes(text: str, job: str = JOB) -> int:
    """The job's timeout-minutes; ValueError when absent or ambiguous."""
    block = re.search(rf"^  {re.escape(job)}:\n((?:    .*\n|\s*\n)+)", text, re.M)
    if not block:
        raise ValueError(f"{CI} has no job {job}")
    limits = re.findall(r"^    timeout-minutes: (\d+)\s*$", block.group(1), re.M)
    if len(limits) != 1:
        raise ValueError(f"{CI}'s job {job} has {len(limits)} timeout-minutes, expected 1")
    return int(limits[0])


def slowest_lanes(directory: pathlib.Path, count: int = 8) -> list:
    records = []
    for path in sorted(directory.glob("*.jsonl")) if directory.is_dir() else []:
        for line in path.read_text().splitlines():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    records.sort(key=lambda r: r.get("elapsed", 0), reverse=True)
    return [(r.get("lane", "?"), float(r.get("elapsed", 0))) for r in records[:count]]


def verdict(elapsed: float, limit_minutes: int) -> tuple:
    """(ok, budget seconds)."""
    budget = limit_minutes * 60 * BUDGET_FRACTION
    return elapsed <= budget, budget


def main(argv: list) -> int:
    if len(argv) not in (2, 3):
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    start = float(argv[1])
    lanes = pathlib.Path(argv[2]) if len(argv) == 3 else pathlib.Path("_build/lane-timing")
    limit = job_limit_minutes(CI.read_text())
    elapsed = time.time() - start
    ok, budget = verdict(elapsed, limit)
    tag = "PASS" if ok else "FAIL"
    print(f"{tag} ci-time-budget: {elapsed / 60:.1f} min used of a {budget / 60:.1f} min "
          f"budget ({BUDGET_FRACTION:.0%} of the {limit} min limit)")
    if not ok:
        print("slowest lanes of this part:")
        for lane, seconds in slowest_lanes(lanes):
            print(f"  {lane:<40} {seconds:7.1f}s")
        print("split the part or explain the growth before raising timeout-minutes (#816)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
