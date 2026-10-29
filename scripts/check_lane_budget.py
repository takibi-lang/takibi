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

  LANE_SECONDS_LIMIT  the busy lane-seconds of the last allcheck: every
                   receipt's elapsed time in the lane timing artifact
                   (_build/lane-timing, written by scripts/lane_timing.sh)
                   less the time that lane waited for vCPUs, read from
                   vcpu-lease.waits (#927). Waiting is queueing, not work:
                   when #927 granted leases longest lane first, the span fell
                   and the summed elapsed time rose by about 2100 s, because
                   the short lanes now wait for the long ones. The budget
                   counts what a lane costs the host, so the grant order
                   cannot move it.
                   Derivation (maintainer decision 2026-10-23, #927): a solo
                   allcheck on a quiet host, 2026-10-24, rebased on b10ee276,
                   measured 3301 busy lane-seconds over 34 receipts (summed
                   elapsed 9119 s, lease wait 6546 s, span 610 s). The limit
                   is 4300 s: that plus about 30 % for host load, the same
                   headroom the earlier 9000 s elapsed limit had (#908).
                   Only a GREEN allcheck's receipts are read (#1123): land.sh
                   copies _build/lane-timing, after allcheck passed, to
                   <git common dir>/takibi-land/lane-timing-green
                   (`--keep-green`), and this check reads that copy. A red
                   run's receipts stay in _build/lane-timing for diagnosis but
                   are never measured: a lane that hung to its timeout, and
                   the lanes that queued behind it, inflated the sum past the
                   budget and refused the next land's precheck. A green run
                   that grew past the budget still fails the next land.
                   Checked only when the copy is present, since a fresh
                   worktree has none; a partial artifact (this gate runs
                   beside allcheck's lanes) can only sum lower. A QEMU lane's
                   receipt with no vcpu-lease.waits is refused, since its
                   waits would count as work.

Exit code only (0 = pass, 1 = fail).
"""

from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess
import sys

from pass_line import report_pass

MAKEFILE = pathlib.Path("Makefile")
TIMING_DIR = pathlib.Path("_build/lane-timing")
GREEN_NAME = "lane-timing-green"


def green_dir() -> pathlib.Path | None:
    """Where land.sh keeps the last green allcheck's receipts; None outside git."""
    try:
        common = subprocess.run(["git", "rev-parse", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return pathlib.Path(common).resolve() / "takibi-land" / GREEN_NAME


def unfinished(directory: pathlib.Path) -> list[str]:
    """Lanes whose begin stamp has no receipt (GitHub issue #1193). A lane
    that began and never wrote its receipt is missing from the sum, so the
    sum reads low: the quiet 5f79f0c0 run left langcheck.start and summed
    4498 where its lanes cost about 4580."""
    return sorted(path.name[:-len(".start")] for path in directory.glob("*.start"))


def keep_green(source: pathlib.Path, dest: pathlib.Path) -> None:
    """Replace dest with a copy of a green run's receipts, so a reader sees
    the old copy or the new one, never half of each."""
    if not source.is_dir():
        raise ValueError(f"{source} is not a lane timing artifact")
    missing = unfinished(source)
    if missing:
        raise ValueError(
            f"{source} has no receipt for {', '.join(missing)}: a lane began "
            "and wrote none, so the run cannot be measured")
    dest.parent.mkdir(parents=True, exist_ok=True)
    staging = dest.with_name(dest.name + ".new")
    old = dest.with_name(dest.name + ".old")
    for stale in (staging, old):
        shutil.rmtree(stale, ignore_errors=True)
    shutil.copytree(source, staging)
    if dest.exists():
        dest.rename(old)
    staging.rename(dest)
    shutil.rmtree(old, ignore_errors=True)
QEMU_LANE_LIMIT = 25
LANE_SECONDS_LIMIT = 4300.0


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
    missing = unfinished(directory)
    if missing:
        raise ValueError(
            f"{directory} has no receipt for {', '.join(missing)}: a lane began "
            "and wrote none, and its seconds would be left out of the sum")
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
            f"the last green allcheck spent {seconds[0]:.0f} lane-seconds over "
            f"{seconds[1]} receipts, over the budget of {seconds_limit:.0f}. "
            "Find the lane that grew (scripts/summarize_lane_timing.py) "
            "rather than raising the number")
    return failures


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args[:1] == ["--keep-green"]:
        source = pathlib.Path(args[1]) if len(args) > 1 else TIMING_DIR
        dest = pathlib.Path(args[2]) if len(args) > 2 else green_dir()
        if dest is None:
            print("FAIL lane-budget: no git directory to keep the green receipts in")
            return 1
        try:
            keep_green(source, dest)
        except (OSError, ValueError) as error:
            print(f"FAIL lane-budget: {error}")
            return 1
        print(f"lane-budget: kept the green allcheck's receipts in {dest}")
        return 0
    directory = pathlib.Path(args[0]) if args else green_dir()
    leaves = qemu_leaf_lanes(MAKEFILE.read_text(encoding="ascii"))
    try:
        seconds = (None if directory is None else
                   lane_seconds(directory, frozenset(leaves)))
    except ValueError as error:
        print(f"FAIL lane-budget: {error}")
        return 1
    failures = verdict(len(leaves), seconds)
    for failure in failures:
        print(f"FAIL lane-budget: {failure}")
    if failures:
        return 1
    timing = ("no green lane timing artifact to read" if seconds is None else
              f"last green allcheck {seconds[0]:.0f} of at most "
              f"{LANE_SECONDS_LIMIT:.0f} busy lane-seconds")
    report_pass("lane-budget",
                f"{len(leaves)} of at most {QEMU_LANE_LIMIT} QEMU lanes; {timing}",
                lanes=len(leaves))
    return 0


if __name__ == "__main__":
    sys.exit(main())
