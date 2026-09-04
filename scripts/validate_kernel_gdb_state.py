#!/usr/bin/env python3
"""Compare read-only GDB kernel views with DDB from the same stopped fixture."""

import argparse
import re


def fields(line: str) -> dict[str, object]:
    result = {}
    for token in line.split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        symbolic = re.fullmatch(r".+\((-?[0-9]+)\)", value)
        if symbolic:
            result[key] = int(symbolic.group(1))
        elif value.startswith("0x"):
            result[key] = int(value, 16)
        elif re.fullmatch(r"-?[0-9]+", value):
            result[key] = int(value)
        else:
            result[key] = value
    return result


def one(lines: list[str], prefix: str) -> str:
    matches = [line for line in lines if line.startswith(prefix)]
    if not matches:
        raise ValueError(f"missing line: {prefix}")
    return matches[0]


def many(lines: list[str], prefix: str) -> list[str]:
    return [line for line in lines if line.startswith(prefix)]


def compare_fields(label: str, uart_line: str, gdb_line: str,
                   keys: tuple[str, ...]) -> None:
    uart = fields(uart_line)
    gdb = fields(gdb_line)
    for key in keys:
        if uart.get(key) != gdb.get(key):
            raise ValueError(
                f"{label} {key} differs: DDB={uart.get(key)!r}, "
                f"GDB={gdb.get(key)!r}")


def indexed(lines: list[str], prefix: str, key: str) -> dict[int, str]:
    result = {}
    for line in many(lines, prefix):
        parsed = fields(line)
        index = parsed.get(key)
        if not isinstance(index, int):
            raise ValueError(f"{prefix} has no numeric {key}: {line}")
        if index in result:
            raise ValueError(f"duplicate {prefix} {key}={index}")
        result[index] = line
    return result


def cpu_set(value: object) -> set[int]:
    if not isinstance(value, str):
        return set()
    try:
        return {int(item) for item in value.split(",")}
    except ValueError:
        return set()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--uart-log", required=True)
    parser.add_argument("--gdb-log", required=True)
    args = parser.parse_args()

    with open(args.uart_log, encoding="ascii") as stream:
        uart = stream.read().replace("\r", "").splitlines()
    with open(args.gdb_log, encoding="ascii") as stream:
        gdb = stream.read().replace("\r", "").splitlines()

    one(gdb, "takibi-kernel: ddb status=valid ")
    cpus = fields(one(gdb, "takibi-kernel: cpus "))
    if cpus.get("coherent") != "yes":
        raise ValueError("GDB did not stop every online CPU")
    online_cpus = cpu_set(cpus.get("online_cpus"))
    stopped_cpus = cpu_set(cpus.get("stopped_cpus"))
    if online_cpus != {0, 1}:
        raise ValueError(
            f"maintained two-core fixture reported online CPUs {online_cpus}")
    if not online_cpus.issubset(stopped_cpus):
        raise ValueError(
            f"online CPUs {online_cpus} not all stopped in {stopped_cpus}")
    if one(gdb, "takibi-kernel: crash ") != (
            "takibi-kernel: crash status=unpublished"):
        raise ValueError("DDB fixture unexpectedly contained crash evidence")

    uart_intr = one(uart, "ddb: intr cpu=")
    gdb_intr = one(gdb, "takibi-kernel: intr ")
    uart_intr_fields = fields(uart_intr)
    uart_intr_fields["entry"] = {
        "irq": 1,
        "brk": 2,
    }.get(uart_intr_fields.get("entry"), -1)
    gdb_intr_fields = fields(gdb_intr)
    for key in ("cpu", "entry", "source", "live_daif", "saved_daif"):
        if uart_intr_fields.get(key) != gdb_intr_fields.get(key):
            raise ValueError(
                f"interrupt {key} differs: "
                f"DDB={uart_intr_fields.get(key)!r}, "
                f"GDB={gdb_intr_fields.get(key)!r}")

    compare_fields(
        "register root",
        one(uart, "ddb: break seq="),
        one(gdb, "takibi-kernel: regs "),
        ("elr", "sp_el0"),
    )
    compare_fields(
        "current",
        one(uart, "ddb: current "),
        one(gdb, "takibi-kernel: current "),
        ("pid", "parent", "state", "wait"),
    )
    compare_fields(
        "scheduler",
        one(uart, "ddb: sched "),
        one(gdb, "takibi-kernel: sched "),
        ("enabled", "pending", "current", "ready", "running", "blocked",
         "exited", "truncated"),
    )
    compare_fields(
        "VM",
        one(uart, "ddb: vm "),
        one(gdb, "takibi-kernel: vm "),
        ("pid", "root", "live", "asid", "l1"),
    )

    uart_fds = fields(one(uart, "ddb: fds "))
    gdb_fds = fields(one(gdb, "takibi-kernel: fds "))
    if uart_fds.get("pid") != gdb_fds.get("pid"):
        raise ValueError("descriptor snapshot PID differs")
    if uart_fds.get("slots") != gdb_fds.get("captured"):
        raise ValueError("descriptor snapshot width differs")
    if gdb_fds.get("remainder") != "not-captured":
        raise ValueError("GDB descriptor view hides its bounded remainder")

    uart_fd_records = indexed(uart, "ddb: fd=", "fd")
    gdb_fd_records = indexed(gdb, "takibi-kernel: fd=", "fd")
    if uart_fd_records.keys() != gdb_fd_records.keys():
        raise ValueError("descriptor sets differ")
    for fd in uart_fd_records:
        compare_fields(
            f"fd {fd}", uart_fd_records[fd], gdb_fd_records[fd],
            ("fd", "kind", "object"),
        )

    compare_fields(
        "process header",
        one(uart, "ddb: ps count="),
        one(gdb, "takibi-kernel: processes "),
        ("count", "truncated"),
    )
    uart_processes = indexed(uart, "ddb: ps pid=", "pid")
    gdb_processes = indexed(gdb, "takibi-kernel: process pid=", "pid")
    if uart_processes.keys() != gdb_processes.keys():
        raise ValueError("process sets differ")
    for pid in uart_processes:
        compare_fields(
            f"process {pid}", uart_processes[pid], gdb_processes[pid],
            ("pid", "ppid", "state", "wait", "root", "sp"),
        )
    selected = fields(one(gdb, "takibi-kernel: selected pid=1 "))
    if selected.get("status") != "captured":
        raise ValueError("selected PID 1 was not reported as captured")

    compare_fields(
        "trace header",
        one(uart, "ddb: trace count="),
        one(gdb, "takibi-kernel: trace count="),
        ("count",),
    )
    uart_traces = indexed(uart, "ddb: trace seq=", "seq")
    gdb_traces = indexed(gdb, "takibi-kernel: trace seq=", "seq")
    if uart_traces.keys() != gdb_traces.keys():
        raise ValueError("lifecycle trace sets differ")
    for sequence in uart_traces:
        compare_fields(
            f"trace {sequence}", uart_traces[sequence], gdb_traces[sequence],
            ("seq", "cpu", "event", "pid", "gen", "peer", "state", "wait",
             "root", "sp", "aux"),
        )

    uart_event_headers = indexed(uart, "ddb: events cpu=", "cpu")
    gdb_event_headers = indexed(gdb, "takibi-kernel: events cpu=", "cpu")
    if uart_event_headers.keys() != gdb_event_headers.keys():
        raise ValueError("diagnostic CPU sets differ")
    for cpu in uart_event_headers:
        compare_fields(
            f"events cpu {cpu}",
            uart_event_headers[cpu],
            gdb_event_headers[cpu],
            ("cpu", "count", "damaged", "overwritten"),
        )
    uart_events = indexed(uart, "ddb: event seq=", "seq")
    gdb_events = indexed(gdb, "takibi-kernel: event seq=", "seq")
    if uart_events.keys() != gdb_events.keys():
        raise ValueError("diagnostic event sets differ")
    for sequence in uart_events:
        compare_fields(
            f"event {sequence}", uart_events[sequence], gdb_events[sequence],
            ("seq", "cpu", "id", "a", "b", "c", "d"),
        )

    joined = "\n".join(gdb)
    for symbolic_type in (
        "ProcessSlotState::",
        "ProcessWaitReason::",
    ):
        if symbolic_type not in joined:
            raise ValueError(f"missing symbolic metadata: {symbolic_type}")
    if gdb_fd_records and "UnifiedFdKind::" not in joined:
        raise ValueError("descriptor kinds were not rendered symbolically")
    if gdb_events and "DiagnosticEvent" not in joined:
        raise ValueError("diagnostic event IDs were not rendered symbolically")

    print(
        "PASS kernel-gdb-state: DDB and GDB views agree for current, "
        "scheduler, VM, descriptors, processes, trace, and events"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
