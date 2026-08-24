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
    "surface", "classification", "proof_reason",
    "file", "line", "column", "operator",
    "lhs_type", "lhs_fact", "rhs_type", "rhs_fact",
]

TYPE_RANGES = {
    "i8": (-(1 << 7), (1 << 7) - 1),
    "i16": (-(1 << 15), (1 << 15) - 1),
    "i32": (-(1 << 31), (1 << 31) - 1),
    "i64": (-(1 << 63), (1 << 63) - 1),
    "u8": (0, (1 << 8) - 1),
    "u16": (0, (1 << 16) - 1),
    "u32": (0, (1 << 32) - 1),
    "u64": (0, (1 << 64) - 1),
    # Use the narrowest maintained target for a source location compiled for
    # more than one target.  A proof within 32 bits is valid on 64-bit too.
    "isize": (-(1 << 31), (1 << 31) - 1),
    "usize": (0, (1 << 32) - 1),
}


def fact_interval(fact: str) -> tuple[int, int] | None:
    if fact.startswith("constant:"):
        value = int(fact.removeprefix("constant:"))
        return value, value
    if fact.startswith("range:"):
        lo, hi = fact.removeprefix("range:").split("..<", 1)
        return int(lo), int(hi) - 1
    if fact.startswith("singleton:"):
        try:
            value = int(fact.removeprefix("singleton:"))
        except ValueError:
            return None
        return value, value
    return None


def classify(row: dict[str, str]) -> tuple[str, str]:
    type_range = TYPE_RANGES.get(row["lhs_type"])
    lhs = fact_interval(row["lhs_fact"])
    rhs = fact_interval(row["rhs_fact"])
    if type_range is None:
        return "review", "unsupported-or-mismatched-base-type"

    op = row["operator"]
    if op in ("div", "mod"):
        if type_range[0] == 0:
            return "proven", "unsigned-division-has-no-signed-min-overflow"
        if lhs is not None and not (lhs[0] <= type_range[0] <= lhs[1]):
            return "proven", "dividend-range-excludes-signed-min"
        if rhs is not None and not (rhs[0] <= -1 <= rhs[1]):
            return "proven", "divisor-range-excludes-minus-one"
        return "review", "cannot-exclude-signed-min-divided-by-minus-one"

    if lhs is None or rhs is None:
        missing = "both" if lhs is None and rhs is None else (
            "lhs" if lhs is None else "rhs"
        )
        return "review", f"missing-{missing}-range"

    if op == "add":
        result = (lhs[0] + rhs[0], lhs[1] + rhs[1])
    elif op == "sub":
        result = (lhs[0] - rhs[1], lhs[1] - rhs[0])
    elif op == "mul":
        products = [a * b for a in lhs for b in rhs]
        result = min(products), max(products)
    elif op == "shl":
        width = type_range[1].bit_length() + (1 if type_range[0] < 0 else 0)
        if rhs[0] < 0 or rhs[1] >= width:
            return "review", "shift-count-not-proven-within-width"
        if lhs[0] < 0:
            return "review", "negative-left-shift-not-proven-safe"
        result = lhs[0] << rhs[0], lhs[1] << rhs[1]
    else:
        raise AssertionError(f"unexpected audited operator: {op}")

    if type_range[0] <= result[0] and result[1] <= type_range[1]:
        return "proven", "result-interval-fits-base-type"
    return "review", "result-interval-may-exceed-base-type"


def check_classifier() -> None:
    def row(op: str, ty: str, lhs: str, rhs: str) -> dict[str, str]:
        return {
            "operator": op, "lhs_type": ty,
            "lhs_fact": lhs, "rhs_fact": rhs,
        }

    controls = [
        ("proven", row("add", "u8", "constant:254", "constant:1")),
        ("review", row("add", "u8", "constant:255", "constant:1")),
        ("proven", row("sub", "i8", "range:-10..<11", "range:-2..<3")),
        ("proven", row("mul", "i8", "range:-4..<5", "constant:30")),
        ("review", row("mul", "i8", "range:-5..<6", "constant:30")),
        ("proven", row("div", "i32", "unknown", "constant:2")),
        ("review", row("div", "i32", "unknown", "constant:-1")),
        ("proven", row("shl", "u8", "constant:1", "constant:7")),
        ("review", row("shl", "u8", "constant:2", "constant:7")),
    ]
    for expected, control in controls:
        actual, reason = classify(control)
        if actual != expected:
            raise RuntimeError(
                f"classifier control expected {expected}, got {actual}: {reason}"
            )


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
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument(
        "--self-test", action="store_true",
        help="run arithmetic classifier controls without building",
    )
    args = parser.parse_args()
    check_classifier()
    if args.self_test:
        print("PASS overflow survey classifier controls")
        return 0
    if args.output is None:
        parser.error("output is required unless --self-test is used")

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
                    previous = rows.get(key)
                    if previous is None:
                        rows[key] = row
                    else:
                        # The same shared source can be compiled for several
                        # targets.  Retain a fact only when every compilation
                        # agrees, so the source-level verdict is conservative.
                        for field in ("lhs_type", "lhs_fact", "rhs_type", "rhs_fact"):
                            if previous[field] != row[field]:
                                previous[field] = "unknown"

    args.output.parent.mkdir(parents=True, exist_ok=True)
    ordered = [rows[key] for key in sorted(rows)]
    with args.output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER, delimiter="\t")
        writer.writeheader()
        for row in ordered:
            classification, reason = classify(row)
            writer.writerow({
                "surface": surface(row["file"]),
                "classification": classification,
                "proof_reason": reason,
                **row,
            })

    counts = Counter((surface(row["file"]), row["operator"]) for row in ordered)
    facts = Counter(
        (surface(row["file"]),
         "both-facts" if row["lhs_fact"] != "unknown" and row["rhs_fact"] != "unknown"
         else "missing-fact")
        for row in ordered
    )
    classifications = Counter(
        (surface(row["file"]), classify(row)[0]) for row in ordered
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
    for key, count in sorted(classifications.items()):
        print(f"{key[0]}\t{key[1]}\t{count}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"overflow survey failed: {error}", file=sys.stderr)
        sys.exit(1)
