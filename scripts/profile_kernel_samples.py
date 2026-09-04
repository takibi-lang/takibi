#!/usr/bin/env python3
"""Validate and symbolize bounded flat-PC samples from a kernel workload."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


RECORD_RE = re.compile(r"^profile: (begin|end|sample|sample-summary) (.+)$")
LEVELS = {"el0", "el1", "irq"}


def fields(text):
    result = {}
    for item in text.split():
        if "=" not in item:
            raise ValueError(f"malformed sample field: {item!r}")
        key, value = item.split("=", 1)
        if not key or not value or key in result:
            raise ValueError(f"invalid sample field: {item!r}")
        result[key] = value
    return result


def integer(record, key, base=10):
    try:
        value = int(record[key], base)
    except (KeyError, ValueError) as error:
        raise ValueError(f"missing or invalid sample field {key}") from error
    if value < 0:
        raise ValueError(f"negative sample field {key}")
    return value


def one(records, kind, name):
    selected = [record for record_kind, record in records
                if record_kind == kind and record.get("name") == name]
    if len(selected) != 1:
        raise ValueError(f"expected one {kind} record for {name}, found {len(selected)}")
    return selected[0]


def elf_identity(path):
    data = Path(path).read_bytes()
    return {"path": str(Path(path).resolve()), "sha256": hashlib.sha256(data).hexdigest()}


def symbolize(tool, elf, addresses, timeout):
    if not addresses:
        return []
    command = [tool, "-f", "-C", "-e", elf,
               *[f"0x{pc:x}" for pc in addresses]]
    try:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ValueError(f"symbolizer timed out for {elf}") from error
    if result.returncode != 0:
        raise ValueError(f"symbolizer failed for {elf}: {result.stderr.strip()}")
    lines = result.stdout.splitlines()
    if len(lines) != len(addresses) * 2:
        raise ValueError(f"symbolizer returned the wrong row count for {elf}")
    resolved = []
    for index in range(len(addresses)):
        function = lines[index * 2]
        location = lines[index * 2 + 1]
        file_name, separator, line_text = location.rpartition(":")
        line = int(line_text) if separator and line_text.isdigit() else None
        resolved.append({
            "function": None if function == "??" else function,
            "file": None if file_name in ("", "??") else file_name,
            "line": line,
        })
    return resolved


def pid_elf(value):
    try:
        pid_text, path = value.split("=", 1)
        pid = int(pid_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("PID ELF must be PID=PATH") from error
    if pid < 0 or not path:
        raise argparse.ArgumentTypeError("PID ELF must be PID=PATH")
    return pid, path


def collect(args):
    lines = Path(args.uart_log).read_text(encoding="ascii").splitlines()
    records = []
    positions = []
    for position, line in enumerate(lines):
        match = RECORD_RE.match(line)
        if match:
            records.append((match.group(1), fields(match.group(2))))
            positions.append((match.group(1), position, records[-1][1]))
    begin = one(records, "begin", args.name)
    end = one(records, "end", args.name)
    summary = one(records, "sample-summary", args.name)
    begin_pos = next(pos for kind, pos, row in positions
                     if kind == "begin" and row.get("name") == args.name)
    end_pos = next(pos for kind, pos, row in positions
                   if kind == "end" and row.get("name") == args.name)
    summary_pos = next(pos for kind, pos, row in positions
                       if kind == "sample-summary" and row.get("name") == args.name)
    if not begin_pos < end_pos < summary_pos:
        raise ValueError("sample records do not follow the workload interval")
    cpu_count = integer(begin, "cpu_count")
    samples = [(pos, row) for kind, pos, row in positions
               if kind == "sample" and row.get("name") == args.name]
    stored = integer(summary, "stored")
    lost = integer(summary, "lost")
    if len(samples) != stored:
        raise ValueError(f"expected {stored} samples, found {len(samples)}")
    if any(pos <= end_pos or pos >= summary_pos for pos, _ in samples):
        raise ValueError("sample record is outside its dump boundaries")

    parsed = []
    previous_timestamp = None
    for index, (_, row) in enumerate(samples):
        sequence = integer(row, "sequence")
        if sequence != index:
            raise ValueError("sample sequence is missing, duplicate, or out of order")
        timestamp = integer(row, "timestamp")
        cpu = integer(row, "cpu")
        pid = integer(row, "pid")
        pc = integer(row, "pc", 0)
        period = integer(row, "period")
        level = row.get("level")
        if cpu >= cpu_count:
            raise ValueError("sample CPU is outside the active CPU count")
        if level not in LEVELS:
            raise ValueError("sample execution level is invalid")
        if period == 0:
            raise ValueError("sample period is zero")
        if previous_timestamp is not None and timestamp < previous_timestamp:
            raise ValueError("sample timestamps are out of order")
        previous_timestamp = timestamp
        parsed.append({"sequence": sequence, "timestamp": timestamp, "pc": pc,
                       "cpu": cpu, "pid": pid, "level": level, "period": period})
    if integer(summary, "attempted") != stored + lost:
        raise ValueError("sample lost total is inconsistent")
    # A capture that collected nothing parses perfectly and describes
    # nothing. On a lane that ran a real workload interval, zero samples
    # means the hardware source never fired -- an unrouted PMU interrupt, a
    # CPU with no PMUv3 -- and that has to fail where it happened rather
    # than become an empty artifact somebody later reads as a flat profile.
    if stored < args.min_samples:
        raise ValueError(
            f"expected at least {args.min_samples} samples, found {stored}")

    mappings = {}
    for pid, elf in args.pid_elf:
        if pid in mappings:
            raise ValueError(f"duplicate ELF mapping for PID {pid}")
        mappings[pid] = elf
    groups = {}
    for index, sample in enumerate(parsed):
        elf = args.kernel_elf if sample["level"] != "el0" else mappings.get(sample["pid"])
        if elf is None:
            sample["symbol"] = {"function": None, "file": None, "line": None}
            sample["elf"] = None
            continue
        groups.setdefault(elf, []).append((index, sample["pc"]))
    identities = {}
    for elf, entries in groups.items():
        identities[elf] = elf_identity(elf)
        resolved = symbolize(args.symbolizer, elf, [pc for _, pc in entries],
                             args.symbolizer_timeout)
        for (index, _), symbol in zip(entries, resolved):
            parsed[index]["symbol"] = symbol
            parsed[index]["elf"] = identities[elf]["sha256"]

    flat = {}
    for sample in parsed:
        symbol = sample["symbol"]
        key = (sample["level"], sample["pid"], symbol["function"],
               symbol["file"], symbol["line"])
        row = flat.setdefault(key, {"level": key[0], "pid": key[1],
                                   "function": key[2], "file": key[3],
                                   "line": key[4], "samples": 0, "period": 0})
        row["samples"] += 1
        row["period"] += sample["period"]
    artifact = {"schema": "takibi.kernel.flat-pc/v1", "workload": args.name,
                "environment": {"target": args.target, "commit": args.commit,
                                "cpu_count": cpu_count},
                "loss": {"stored": stored, "lost": lost,
                         "attempted": stored + lost},
                "elfs": sorted(identities.values(), key=lambda item: item["path"]),
                "samples": parsed,
                "flat": sorted(flat.values(), key=lambda row: (-row["period"],
                                                                row["level"], row["pid"]))}
    Path(args.output).write_text(json.dumps(artifact, indent=2) + "\n", encoding="ascii")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uart-log", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--kernel-elf", required=True)
    parser.add_argument("--pid-elf", action="append", type=pid_elf, default=[])
    parser.add_argument("--name", default="busy-pair")
    parser.add_argument("--target", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--symbolizer", default="addr2line")
    parser.add_argument("--symbolizer-timeout", type=float, default=10.0)
    parser.add_argument("--min-samples", type=int, default=0)
    args = parser.parse_args()
    if args.symbolizer_timeout <= 0:
        parser.error("--symbolizer-timeout must be positive")
    if args.min_samples < 0:
        parser.error("--min-samples must not be negative")
    collect(args)


if __name__ == "__main__":
    main()
