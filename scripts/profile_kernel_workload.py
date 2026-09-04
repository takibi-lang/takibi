#!/usr/bin/env python3
"""Preserve and compare named standalone-kernel workload intervals."""

import argparse
import html
import json
from pathlib import Path
import re
import subprocess


RECORD_RE = re.compile(r"^profile: (begin|end|cpu) (.+)$")
TIMELINE_RE = re.compile(
    r"^profile: (timeline|timeline-cpu|event) (.+)$")
TIMELINE_KINDS = {
    "schedule-out": "scheduler",
    "schedule-in": "scheduler",
    "block": "scheduler",
    "wakeup": "scheduler",
    "syscall-enter": "syscall",
    "syscall-exit": "syscall",
    "syscall-wait": "syscall",
    "irq-enter": "irq",
    "irq-exit": "irq",
}


def parse_fields(text):
    fields = {}
    for item in text.split():
        if "=" not in item:
            raise ValueError(f"malformed profile field: {item!r}")
        key, value = item.split("=", 1)
        if not key or not value or key in fields:
            raise ValueError(f"invalid profile field: {item!r}")
        fields[key] = value
    return fields


def one_record(lines, kind, name):
    records = []
    for line in lines:
        match = RECORD_RE.match(line.rstrip("\r\n"))
        if match and match.group(1) == kind:
            fields = parse_fields(match.group(2))
            if fields.get("name") == name:
                records.append(fields)
    if len(records) != 1:
        raise ValueError(f"expected one {kind} record for {name}, found {len(records)}")
    return records[0]


def all_records(lines, kind, name):
    records = []
    for line in lines:
        match = RECORD_RE.match(line.rstrip("\r\n"))
        if match and match.group(1) == kind:
            fields = parse_fields(match.group(2))
            if fields.get("name") == name:
                records.append(fields)
    return records


def integer(fields, key):
    try:
        value = int(fields[key])
    except (KeyError, ValueError) as error:
        raise ValueError(f"missing or invalid integer field {key}") from error
    if value < 0:
        raise ValueError(f"negative profile field {key}")
    return value


def collect(args):
    if not args.target or not args.commit:
        raise ValueError("target and commit are required")
    lines = Path(args.uart_log).read_text(encoding="ascii", errors="strict").splitlines()
    begin = one_record(lines, "begin", args.name)
    end = one_record(lines, "end", args.name)
    begin_line = next(index for index, line in enumerate(lines)
                      if line.startswith(f"profile: begin name={args.name} "))
    end_line = next(index for index, line in enumerate(lines)
                    if line.startswith(f"profile: end name={args.name} "))
    if begin_line >= end_line:
        raise ValueError("profile end record does not follow its begin record")
    for key in ("input_steps", "cpu_count", "iterations_goal", "pid_a", "pid_b"):
        integer(begin, key)
    for key in ("elapsed_cycles", "tick_frequency", "iterations_a",
                "iterations_b", "result_count", "checksum_a", "checksum_b"):
        integer(end, key)
    if integer(begin, "pid_a") == integer(begin, "pid_b"):
        raise ValueError("profile workload PIDs are not distinct")
    if integer(begin, "cpu_count") == 0:
        raise ValueError("profile interval has no active CPU")
    completed = integer(end, "iterations_a") + integer(end, "iterations_b")
    if completed < integer(begin, "iterations_goal"):
        raise ValueError("profile ended before its iteration goal")
    if integer(end, "elapsed_cycles") == 0 or integer(end, "tick_frequency") == 0:
        raise ValueError("profile interval has a zero duration or frequency")
    if integer(end, "result_count") != 2:
        raise ValueError("busy-pair profile did not produce two results")
    cpu_count = integer(begin, "cpu_count")
    cpu_records = all_records(lines, "cpu", args.name)
    if len(cpu_records) != cpu_count:
        raise ValueError(
            f"expected {cpu_count} per-CPU records, found {len(cpu_records)}")
    cpu_lines = [index for index, line in enumerate(lines)
                 if line.startswith(f"profile: cpu name={args.name} ")]
    if any(index <= end_line for index in cpu_lines):
        raise ValueError("per-CPU profile record does not follow the end record")
    per_cpu = []
    aggregate_running = 0
    aggregate_idle = 0
    cpu_fields = (
        "wall_cycles", "el0_cycles", "el1_cycles", "irq_cycles",
        "idle_cycles", "context_switches", "blocks", "wakeups",
        "syscalls", "block_read_bytes", "block_write_bytes",
        "network_rx_bytes", "network_tx_bytes")
    for expected_cpu, fields in enumerate(cpu_records):
        if integer(fields, "cpu") != expected_cpu:
            raise ValueError("per-CPU profile records are missing or out of order")
        values = {key: integer(fields, key) for key in cpu_fields}
        if values["wall_cycles"] != integer(end, "elapsed_cycles"):
            raise ValueError(
                f"CPU {expected_cpu} wall cycles do not equal interval cycles")
        classified = (values["el0_cycles"] + values["el1_cycles"] +
                      values["irq_cycles"] + values["idle_cycles"])
        if classified != values["wall_cycles"]:
            raise ValueError(
                f"CPU {expected_cpu} classified cycles do not equal wall cycles")
        running = (values["el0_cycles"] + values["el1_cycles"] +
                   values["irq_cycles"])
        aggregate_running += running
        aggregate_idle += values["idle_cycles"]
        per_cpu.append({"cpu": expected_cpu, **values})
    if aggregate_running > aggregate_idle:
        dominant_state = "running"
    elif aggregate_idle > aggregate_running:
        dominant_state = "idle"
    else:
        dominant_state = "balanced"
    artifact = {
        "schema": "takibi.kernel.workload/v2",
        "workload": args.name,
        "environment": {
            "target": args.target,
            "cpu_count": cpu_count,
            "commit": args.commit,
        },
        "input": {
            "steps_per_iteration": integer(begin, "input_steps"),
            "iteration_goal": integer(begin, "iterations_goal"),
        },
        "interval": {
            "elapsed_cycles": integer(end, "elapsed_cycles"),
            "counter_frequency_hz": integer(end, "tick_frequency"),
            "elapsed_seconds": (integer(end, "elapsed_cycles") /
                                integer(end, "tick_frequency")),
        },
        "results": {
            "completed_iterations": completed,
            "result_count": integer(end, "result_count"),
            "pids": [integer(begin, "pid_a"), integer(begin, "pid_b")],
            "checksums": [integer(end, "checksum_a"), integer(end, "checksum_b")],
        },
        "accounting": {
            "dominant_state": dominant_state,
            "aggregate_running_cycles": aggregate_running,
            "aggregate_idle_cycles": aggregate_idle,
            "per_cpu": per_cpu,
        },
    }
    Path(args.output).write_text(json.dumps(artifact, indent=2) + "\n", encoding="ascii")


def timeline_records(lines, kind, name):
    records = []
    for index, line in enumerate(lines):
        match = TIMELINE_RE.match(line.rstrip("\r\n"))
        if match and match.group(1) == kind:
            values = parse_fields(match.group(2))
            if values.get("name") == name:
                records.append((index, values))
    return records


def timeline(args):
    if not args.target or not args.commit:
        raise ValueError("target and commit are required")
    lines = Path(args.uart_log).read_text(
        encoding="ascii", errors="strict").splitlines()
    begin = one_record(lines, "begin", args.name)
    end = one_record(lines, "end", args.name)
    headers = timeline_records(lines, "timeline", args.name)
    if len(headers) != 1:
        raise ValueError(
            f"expected one timeline record for {args.name}, "
            f"found {len(headers)}")
    header_line, header = headers[0]
    start = integer(header, "start_cycles")
    finish = integer(header, "end_cycles")
    frequency = integer(header, "frequency")
    cpu_count = integer(header, "cpu_count")
    capacity = integer(header, "capacity")
    if start >= finish or frequency == 0 or cpu_count == 0 or capacity == 0:
        raise ValueError("invalid timeline interval or bounds")
    if finish - start != integer(end, "elapsed_cycles"):
        raise ValueError("timeline interval does not equal profile interval")
    if frequency != integer(end, "tick_frequency"):
        raise ValueError("timeline frequency does not equal profile frequency")
    if cpu_count != integer(begin, "cpu_count"):
        raise ValueError("timeline CPU count does not equal profile CPU count")
    workload_pids = {integer(begin, "pid_a"), integer(begin, "pid_b")}

    cpu_records = timeline_records(lines, "timeline-cpu", args.name)
    if len(cpu_records) != cpu_count:
        raise ValueError(
            f"expected {cpu_count} timeline CPU records, "
            f"found {len(cpu_records)}")
    events = timeline_records(lines, "event", args.name)
    per_cpu_events = [[] for _ in range(cpu_count)]
    for line_index, values in events:
        if line_index <= header_line:
            raise ValueError("timeline event does not follow its header")
        cpu = integer(values, "cpu")
        if cpu >= cpu_count:
            raise ValueError("timeline event CPU is outside the active set")
        sequence = integer(values, "sequence")
        timestamp = integer(values, "timestamp")
        pid = integer(values, "pid")
        peer = integer(values, "peer")
        arg = integer(values, "arg")
        kind = values.get("kind")
        if kind not in TIMELINE_KINDS:
            raise ValueError(f"unknown timeline event kind: {kind!r}")
        if kind in ("schedule-out", "schedule-in"):
            if pid not in workload_pids and peer not in workload_pids:
                raise ValueError(
                    "scheduler timeline event does not involve the workload")
        elif pid not in workload_pids:
            raise ValueError(
                "timeline event PID does not belong to the workload")
        if timestamp < start or timestamp > finish:
            raise ValueError("timeline event timestamp is outside the interval")
        per_cpu_events[cpu].append({
            "sequence": sequence,
            "timestamp": timestamp,
            "cpu": cpu,
            "kind": kind,
            "pid": pid,
            "peer": peer,
            "arg": arg,
        })

    per_cpu = []
    for expected_cpu, (_, values) in enumerate(cpu_records):
        cpu = integer(values, "cpu")
        stored = integer(values, "stored")
        lost = integer(values, "lost")
        attempted = integer(values, "attempted")
        if cpu != expected_cpu:
            raise ValueError(
                "timeline CPU records are missing or out of order")
        if (stored > capacity or attempted != stored + lost or
                (lost > 0 and stored != capacity)):
            raise ValueError("invalid timeline stored/lost accounting")
        records = per_cpu_events[cpu]
        if len(records) != stored:
            raise ValueError(
                f"timeline CPU {cpu} record count does not match stored")
        previous_timestamp = None
        for expected_sequence, event in enumerate(records, 1):
            if event["sequence"] != expected_sequence:
                raise ValueError(
                    f"timeline CPU {cpu} sequence is missing or out of order")
            if (previous_timestamp is not None and
                    event["timestamp"] < previous_timestamp):
                raise ValueError(
                    f"timeline CPU {cpu} timestamp moved backwards")
            previous_timestamp = event["timestamp"]
        per_cpu.append({
            "cpu": cpu,
            "stored": stored,
            "lost": lost,
            "attempted": attempted,
        })

    observed_kinds = {
        event["kind"] for records in per_cpu_events for event in records
    }
    missing = sorted(set(args.require_kind) - observed_kinds)
    if missing:
        raise ValueError(
            "timeline missing required event kinds: " + ", ".join(missing))

    trace_events = [{
        "name": "process_name",
        "ph": "M",
        "pid": 1,
        "tid": 0,
        "args": {"name": "Takibi kernel"},
    }]
    for cpu in range(cpu_count):
        trace_events.append({
            "name": "thread_name",
            "ph": "M",
            "pid": 1,
            "tid": cpu,
            "args": {"name": f"CPU {cpu}"},
        })
    merged = sorted(
        (event for records in per_cpu_events for event in records),
        key=lambda event: (
            event["timestamp"], event["cpu"], event["sequence"]))
    for event in merged:
        trace_events.append({
            "name": event["kind"],
            "cat": TIMELINE_KINDS[event["kind"]],
            "ph": "i",
            "s": "t",
            "ts": ((event["timestamp"] - start) * 1_000_000 /
                   frequency),
            "pid": 1,
            "tid": event["cpu"],
            "args": {
                "process_pid": event["pid"],
                "peer_pid": event["peer"],
                "syscall_number": event["arg"],
                "counter_cycles": event["timestamp"],
                "cpu_sequence": event["sequence"],
            },
        })
    artifact = {
        "traceEvents": trace_events,
        "displayTimeUnit": "ns",
        "metadata": {
            "schema": "takibi.kernel.timeline/v1",
            "workload": args.name,
            "environment": {
                "target": args.target,
                "cpu_count": cpu_count,
                "commit": args.commit,
            },
            "interval": {
                "start_cycles": start,
                "end_cycles": finish,
                "counter_frequency_hz": frequency,
            },
            "pids": sorted(workload_pids),
            "per_cpu": per_cpu,
        },
    }
    Path(args.output).write_text(
        json.dumps(artifact, indent=2) + "\n", encoding="ascii")


def git_commit():
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], check=True, text=True,
        stdout=subprocess.PIPE).stdout.strip()


def load_artifact(path):
    artifact = json.loads(Path(path).read_text(encoding="ascii"))
    if artifact.get("schema") not in (
            "takibi.kernel.workload/v1", "takibi.kernel.workload/v2"):
        raise ValueError(f"unsupported artifact schema in {path}")
    cycles = artifact["interval"]["elapsed_cycles"]
    frequency = artifact["interval"]["counter_frequency_hz"]
    if not isinstance(cycles, int) or not isinstance(frequency, int) or frequency <= 0:
        raise ValueError(f"invalid interval in {path}")
    return artifact, cycles / frequency


def chart(args):
    rows = [load_artifact(path) for path in args.artifacts]
    maximum = max(seconds for _, seconds in rows)
    width, left, bar_width = 900, 310, 520
    height = 80 + len(rows) * 54
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             '<rect width="100%" height="100%" fill="white"/>',
             '<style>text{font:14px sans-serif} .title{font:bold 18px sans-serif}</style>',
             '<text class="title" x="20" y="28">Takibi post-boot workload elapsed time</text>']
    for index, (artifact, seconds) in enumerate(rows):
        y = 62 + index * 54
        env = artifact["environment"]
        label = f'{env["commit"][:12]} {env["target"]} cpu={env["cpu_count"]}'
        length = 0 if maximum == 0 else seconds / maximum * bar_width
        parts.append(f'<text x="20" y="{y + 18}">{html.escape(label)}</text>')
        parts.append(f'<rect x="{left}" y="{y}" width="{length:.2f}" height="24" fill="#4472c4"/>')
        parts.append(f'<text x="{left + length + 8:.2f}" y="{y + 18}">{seconds:.6f} s</text>')
    parts.append('</svg>')
    Path(args.output).write_text("\n".join(parts) + "\n", encoding="ascii")


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(required=True)
    collect_parser = subparsers.add_parser("collect")
    collect_parser.add_argument("--uart-log", required=True)
    collect_parser.add_argument("--output", required=True)
    collect_parser.add_argument("--name", default="busy-pair")
    collect_parser.add_argument("--target", required=True)
    collect_parser.add_argument("--commit", default=None)
    collect_parser.set_defaults(run=collect)
    timeline_parser = subparsers.add_parser("timeline")
    timeline_parser.add_argument("--uart-log", required=True)
    timeline_parser.add_argument("--output", required=True)
    timeline_parser.add_argument("--name", default="busy-pair")
    timeline_parser.add_argument("--target", required=True)
    timeline_parser.add_argument("--commit", default=None)
    timeline_parser.add_argument(
        "--require-kind", action="append", default=[],
        choices=sorted(TIMELINE_KINDS))
    timeline_parser.set_defaults(run=timeline)
    chart_parser = subparsers.add_parser("chart")
    chart_parser.add_argument("--output", required=True)
    chart_parser.add_argument("artifacts", nargs="+")
    chart_parser.set_defaults(run=chart)
    args = parser.parse_args()
    if hasattr(args, "commit") and args.commit is None:
        args.commit = git_commit()
    args.run(args)


if __name__ == "__main__":
    main()
