#!/usr/bin/env python3
"""Inventory ordinary integer operations using the compiler's inferred facts."""

import argparse
import csv
import os
import shlex
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path


HEADER = [
    "surface", "file", "line", "column", "operator",
    "lhs_type", "lhs_fact", "rhs_type", "rhs_fact",
]


def surface(path: str) -> str:
    if path.startswith("kernel/"):
        return "kernel"
    if path.startswith("linux_user/"):
        return "linux_user"
    if path.startswith("examples/"):
        return "examples"
    return "other"


def compiler_commands() -> list[list[str]]:
    dry_run = subprocess.run(
        ["make", "-Bn", "allbuild"], text=True, capture_output=True, check=True
    )
    commands = []
    logical_lines = []
    pending = ""
    for physical in dry_run.stdout.splitlines():
        pending += physical[:-1] + " " if physical.endswith("\\") else physical
        if not physical.endswith("\\"):
            logical_lines.append(pending)
            pending = ""
    if pending:
        logical_lines.append(pending)
    for line in logical_lines:
        argv = shlex.split(line)
        if argv and argv[0].endswith("/bin/main.exe"):
            commands.append(argv)
    if not commands:
        raise RuntimeError("make -Bn allbuild produced no compiler commands")
    return commands


def run_measured(command: list[str]) -> tuple[float, int]:
    started = time.perf_counter()
    pid = os.fork()
    if pid == 0:
        os.execvp(command[0], command)
    _, status, usage = os.wait4(pid, 0)
    seconds = time.perf_counter() - started
    returncode = os.waitstatus_to_exitcode(status)
    if returncode != 0:
        raise subprocess.CalledProcessError(returncode, command)
    return seconds, usage.ru_maxrss


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build every repository target and write a deduplicated overflow audit TSV"
    )
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    baseline = subprocess.run(
        ["make", "allbuild"], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT
    )
    if baseline.returncode != 0:
        sys.stdout.write(baseline.stdout)
        baseline.check_returncode()
    rows = {}
    commands = compiler_commands()
    baseline_seconds = 0.0
    audit_seconds = 0.0
    baseline_peak_kib = 0
    audit_peak_kib = 0
    with tempfile.TemporaryDirectory(prefix="takibi-overflow-audit-") as temp:
        temp_path = Path(temp)
        for index, command in enumerate(commands):
            seconds, peak_kib = run_measured(command)
            baseline_seconds += seconds
            baseline_peak_kib = max(baseline_peak_kib, peak_kib)
            report = temp_path / f"{index}.tsv"
            seconds, peak_kib = run_measured(
                command + ["--emit-overflow-audit", str(report)]
            )
            audit_seconds += seconds
            audit_peak_kib = max(audit_peak_kib, peak_kib)
            with report.open(newline="") as handle:
                for row in csv.DictReader(handle, delimiter="\t"):
                    key = (row["file"], row["line"], row["column"], row["operator"])
                    rows[key] = row

    args.output.parent.mkdir(parents=True, exist_ok=True)
    ordered = [rows[key] for key in sorted(rows)]
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER, delimiter="\t")
        writer.writeheader()
        for row in ordered:
            writer.writerow({"surface": surface(row["file"]), **row})

    counts = Counter((surface(row["file"]), row["operator"]) for row in ordered)
    facts = Counter(
        (surface(row["file"]),
         "both-facts" if row["lhs_fact"] != "unknown" and row["rhs_fact"] != "unknown"
         else "missing-fact")
        for row in ordered
    )
    print(f"wrote {len(ordered)} unique source locations to {args.output}")
    overhead = ((audit_seconds / baseline_seconds) - 1.0) * 100.0
    print(
        f"compile wall time: baseline {baseline_seconds:.3f}s, "
        f"audit {audit_seconds:.3f}s ({overhead:+.1f}%)"
    )
    print(
        f"maximum per-process RSS: baseline {baseline_peak_kib} KiB, "
        f"audit {audit_peak_kib} KiB"
    )
    for key, count in sorted(counts.items()):
        print(f"{key[0]}\t{key[1]}\t{count}")
    for key, count in sorted(facts.items()):
        print(f"{key[0]}\t{key[1]}\t{count}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"overflow survey failed: {error}", file=sys.stderr)
        sys.exit(1)
