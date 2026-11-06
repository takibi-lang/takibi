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

  LANE_CPU_SECONDS_LIMIT  the CPU seconds of the last green allcheck: the
                   sum of every receipt's `cpu` in the lane timing artifact
                   (_build/lane-timing, written by scripts/lane_timing.sh),
                   the user+sys time of the processes each lane waited for
                   (scripts/lane_cpu.sh: run_lane.sh and
                   run_concurrent_checks.sh take it around their command,
                   scripts/lane_cpu_shell.sh around each recipe line of the
                   begin/end lanes). Measured since #1198 (maintainer
                   decision 2026-11-06).
                   History. The budget first summed elapsed seconds (9000 s,
                   #908), then elapsed less vCPU lease waits (#927, 4300 s
                   from a quiet 3301), since waiting is queueing, not work.
                   That was still wall time, and wall time stretches with
                   host contention: kernelcheck-qemu-main ran 269 s alone and
                   340 s inside allcheck, the test lane 13.7 s in one green
                   run and 100 s in another, and green runs with no lane
                   doing more work drifted from 3974 to 4655 busy seconds;
                   the limit was re-derived to 5900 (#1193), and a green
                   allcheck on a5e87d25, inflated uniformly by concurrent
                   worker QEMU lanes, still summed 6221 and blocked every
                   land -- the fifth such block (#1075, #1085, #1123, #1193).
                   A second of CPU is the same second whoever else runs, so
                   a busy host no longer moves the sum, and lease waits need
                   no subtraction: a waiting lane uses no CPU.
                   Derivation: see LANE_CPU_SECONDS_LIMIT below.
                   Only a GREEN allcheck's receipts are read (#1123): land.sh
                   copies _build/lane-timing, after allcheck passed, to
                   <git common dir>/takibi-land/lane-timing-green
                   (`--keep-green`), and this check reads that copy. A red
                   run's receipts stay in _build/lane-timing for diagnosis but
                   are never measured: a lane that hung to its timeout
                   inflated the sum past the budget and refused the next
                   land's precheck. A green run that grew past the budget
                   still fails the next land. Checked only when the copy is
                   present, since a fresh worktree has none; a partial
                   artifact (this gate runs beside allcheck's lanes) can only
                   sum lower. A receipt with no `cpu` is refused, both when
                   kept and when measured: it was written before #1198 or
                   by a lane whose CPU was not taken, and leaving it out
                   would sum low. A lane timed by `lane_timing.sh begin` in
                   the Makefile must be in LANE_CPU_SHELL_LANES, since only
                   that list gives its recipe lines the CPU-taking shell.

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
    lane_cpu_seconds(source)
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
# Derivation (#1198): MEASUREMENT PENDING; see the report on #1198.
LANE_CPU_SECONDS_LIMIT = 0.0


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


def lane_cpu_seconds(directory: pathlib.Path) -> tuple[float, int] | None:
    """CPU seconds summed over every receipt (#1198); None with no
    artifact. Raises ValueError for an unfinished lane or a receipt with no
    CPU, either of which would leave seconds out of the sum."""
    files = sorted(directory.glob("*.jsonl")) if directory.is_dir() else []
    if not files:
        return None
    missing = unfinished(directory)
    if missing:
        raise ValueError(
            f"{directory} has no receipt for {', '.join(missing)}: a lane began "
            "and wrote none, and its seconds would be left out of the sum")
    total, count = 0.0, 0
    for path in files:
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            if "cpu" not in record:
                raise ValueError(
                    f"{path.name}: lane {record.get('lane')} has no cpu figure "
                    "(written before #1198, or its CPU was not taken), so the "
                    "run cannot be measured")
            total += float(record["cpu"])
            count += 1
    return total, count


def cpu_shell_gaps(text: str) -> list[str]:
    """Lanes the Makefile times with `lane_timing.sh begin` that are not in
    LANE_CPU_SHELL_LANES, whose receipts would carry no CPU."""
    begun = set(re.findall(r"lane_timing\.sh begin ([A-Za-z0-9_.-]+)", text))
    listed = rules(text).get("$LANE_CPU_SHELL_LANES", [])
    return sorted(begun - set(listed))


def verdict(leaves: int, seconds: tuple[float, int] | None,
            lane_limit: int = QEMU_LANE_LIMIT,
            seconds_limit: float = LANE_CPU_SECONDS_LIMIT) -> list[str]:
    failures = []
    if leaves > lane_limit:
        failures.append(
            f"allcheck runs {leaves} QEMU lanes, over the budget of {lane_limit}. "
            "Put a new error case into an existing lane (docs/LANE_INVENTORY.md); "
            "a new lane needs the maintainer (AGENTS.md)")
    if seconds is not None and seconds[0] > seconds_limit:
        failures.append(
            f"the last green allcheck spent {seconds[0]:.0f} CPU seconds over "
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
    text = MAKEFILE.read_text(encoding="ascii")
    leaves = qemu_leaf_lanes(text)
    try:
        seconds = None if directory is None else lane_cpu_seconds(directory)
    except ValueError as error:
        print(f"FAIL lane-budget: {error}")
        return 1
    failures = verdict(len(leaves), seconds)
    for lane in cpu_shell_gaps(text):
        failures.append(
            f"lane {lane} is timed by lane_timing.sh begin but missing from "
            "LANE_CPU_SHELL_LANES, so its receipt would carry no CPU (#1198)")
    for failure in failures:
        print(f"FAIL lane-budget: {failure}")
    if failures:
        return 1
    timing = ("no green lane timing artifact to read" if seconds is None else
              f"last green allcheck {seconds[0]:.0f} of at most "
              f"{LANE_CPU_SECONDS_LIMIT:.0f} CPU seconds")
    report_pass("lane-budget",
                f"{len(leaves)} of at most {QEMU_LANE_LIMIT} QEMU lanes; {timing}",
                lanes=len(leaves))
    return 0


if __name__ == "__main__":
    sys.exit(main())
