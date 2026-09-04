#!/usr/bin/env python3
"""Positive and negative controls for workload-profile host artifacts."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


SCRIPT = Path(__file__).with_name("profile_kernel_workload.py")


def run(*arguments):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *arguments], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        uart = root / "uart.log"
        artifact = root / "profile.json"
        timeline = root / "timeline.json"
        chart = root / "chart.svg"
        good_text = (
            "profile: begin name=busy-pair input_steps=10 cpu_count=2 "
            "iterations_goal=4 pid_a=2 pid_b=3\n"
            "profile: end name=busy-pair elapsed_cycles=10 tick_frequency=5 "
            "iterations_a=2 iterations_b=2 result_count=2 "
            "checksum_a=11 checksum_b=12\n"
            "profile: cpu name=busy-pair cpu=0 wall_cycles=10 "
            "el0_cycles=6 el1_cycles=2 irq_cycles=1 idle_cycles=1 "
            "context_switches=2 blocks=1 wakeups=1 syscalls=3 "
            "block_read_bytes=1024 block_write_bytes=0 "
            "network_rx_bytes=60 network_tx_bytes=70\n"
            "profile: cpu name=busy-pair cpu=1 wall_cycles=10 "
            "el0_cycles=1 el1_cycles=0 irq_cycles=0 idle_cycles=9 "
            "context_switches=0 blocks=0 wakeups=0 syscalls=0 "
            "block_read_bytes=0 block_write_bytes=0 "
            "network_rx_bytes=0 network_tx_bytes=0\n"
            "profile: timeline name=busy-pair start_cycles=100 "
            "end_cycles=110 frequency=5 cpu_count=2 capacity=6\n"
            "profile: timeline-cpu name=busy-pair cpu=0 stored=6 "
            "lost=1 attempted=7\n"
            "profile: event name=busy-pair sequence=1 timestamp=100 cpu=0 "
            "kind=schedule-out pid=2 peer=3 arg=0\n"
            "profile: event name=busy-pair sequence=2 timestamp=101 cpu=0 "
            "kind=schedule-in pid=3 peer=2 arg=0\n"
            "profile: event name=busy-pair sequence=3 timestamp=102 cpu=0 "
            "kind=syscall-enter pid=3 peer=0 arg=453\n"
            "profile: event name=busy-pair sequence=4 timestamp=103 cpu=0 "
            "kind=syscall-exit pid=3 peer=0 arg=453\n"
            "profile: event name=busy-pair sequence=5 timestamp=104 cpu=0 "
            "kind=irq-enter pid=3 peer=0 arg=0\n"
            "profile: event name=busy-pair sequence=6 timestamp=105 cpu=0 "
            "kind=irq-exit pid=3 peer=0 arg=0\n"
            "profile: timeline-cpu name=busy-pair cpu=1 stored=1 "
            "lost=0 attempted=1\n"
            "profile: event name=busy-pair sequence=1 timestamp=106 cpu=1 "
            "kind=wakeup pid=2 peer=0 arg=0\n")
        uart.write_text(good_text, encoding="ascii")
        result = run(
            "collect", "--uart-log", str(uart), "--output", str(artifact),
            "--target", "qemu", "--commit", "test")
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        parsed = json.loads(artifact.read_text(encoding="ascii"))
        if (parsed["schema"] != "takibi.kernel.workload/v2" or
                len(parsed["accounting"]["per_cpu"]) != 2 or
                parsed["accounting"]["dominant_state"] != "balanced"):
            raise RuntimeError("positive per-CPU artifact was not preserved")

        timeline_args = [
            "timeline", "--uart-log", str(uart), "--output", str(timeline),
            "--target", "qemu", "--commit", "test",
        ]
        for kind in (
                "schedule-out", "schedule-in", "syscall-enter",
                "syscall-exit", "irq-enter", "irq-exit"):
            timeline_args.extend(("--require-kind", kind))
        result = run(*timeline_args)
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        parsed_timeline = json.loads(timeline.read_text(encoding="ascii"))
        names = {
            event["name"] for event in parsed_timeline["traceEvents"]
            if event.get("ph") == "i"
        }
        if (parsed_timeline["metadata"]["schema"] !=
                "takibi.kernel.timeline/v1" or
                parsed_timeline["metadata"]["per_cpu"][0]["lost"] != 1 or
                "schedule-out" not in names or "wakeup" not in names):
            raise RuntimeError("positive Perfetto timeline was not preserved")

        uart.write_text(good_text.replace(
            "cpu_count=2 capacity=6", "cpu_count=2 capacity=8", 1),
            encoding="ascii")
        result = run(*timeline_args)
        if result.returncode == 0 or \
                "invalid timeline stored/lost accounting" not in result.stderr:
            raise RuntimeError("timeline loss negative control did not reject")

        uart.write_text(good_text.replace(
            "kind=syscall-enter pid=3",
            "kind=syscall-enter pid=9", 1), encoding="ascii")
        result = run(*timeline_args)
        if result.returncode == 0 or \
                "PID does not belong to the workload" not in result.stderr:
            raise RuntimeError("timeline PID negative control did not reject")

        uart.write_text(good_text.replace(
            "sequence=1 timestamp=100 cpu=0",
            "sequence=2 timestamp=100 cpu=0", 1), encoding="ascii")
        result = run(*timeline_args)
        if (result.returncode == 0 or
                "sequence is missing or out of order" not in result.stderr):
            raise RuntimeError("timeline sequence negative control did not reject")

        uart.write_text(good_text.replace(
            "timestamp=100 cpu=0", "timestamp=99 cpu=0", 1),
            encoding="ascii")
        result = run(*timeline_args)
        if (result.returncode == 0 or
                "timestamp is outside the interval" not in result.stderr):
            raise RuntimeError("timeline timestamp negative control did not reject")

        uart.write_text(good_text.replace(
            "kind=wakeup", "kind=unknown", 1), encoding="ascii")
        result = run(*timeline_args)
        if result.returncode == 0 or "unknown timeline event kind" not in result.stderr:
            raise RuntimeError("timeline kind negative control did not reject")

        bad_text = uart.read_text(encoding="ascii").replace(
            "el0_cycles=6", "el0_cycles=5", 1)
        uart.write_text(bad_text, encoding="ascii")
        result = run(
            "collect", "--uart-log", str(uart), "--output", str(artifact),
            "--target", "qemu", "--commit", "test")
        if (result.returncode == 0 or
                "classified cycles do not equal wall cycles" not in result.stderr):
            raise RuntimeError("time-partition negative control did not reject")

        uart.write_text(good_text.replace("wall_cycles=10", "wall_cycles=11", 1)
                        .replace("idle_cycles=1", "idle_cycles=2", 1),
                        encoding="ascii")
        result = run(
            "collect", "--uart-log", str(uart), "--output", str(artifact),
            "--target", "qemu", "--commit", "test")
        if result.returncode == 0 or "wall cycles do not equal" not in result.stderr:
            raise RuntimeError("interval/wall mismatch negative control did not reject")

        first_cpu = good_text.index("profile: cpu")
        end_record = good_text.index("profile: end")
        cpu_newline = good_text.index("\n", first_cpu) + 1
        reordered = (good_text[:end_record] + good_text[first_cpu:cpu_newline] +
                     good_text[end_record:first_cpu] + good_text[cpu_newline:])
        uart.write_text(reordered, encoding="ascii")
        result = run(
            "collect", "--uart-log", str(uart), "--output", str(artifact),
            "--target", "qemu", "--commit", "test")
        if result.returncode == 0 or "does not follow the end record" not in result.stderr:
            raise RuntimeError("pre-end CPU record negative control did not reject")

        legacy = root / "legacy.json"
        legacy.write_text(json.dumps({
            "schema": "takibi.kernel.workload/v1",
            "environment": {"commit": "old", "target": "rpi5", "cpu_count": 1},
            "interval": {"elapsed_cycles": 5, "counter_frequency_hz": 5},
        }) + "\n", encoding="ascii")
        result = run("chart", "--output", str(chart), str(legacy))
        if result.returncode != 0 or "<svg" not in chart.read_text(encoding="ascii"):
            raise RuntimeError("v1 chart compatibility control failed")

    print(
        "PASS profile-kernel-workload: per-CPU summary, Perfetto timeline, "
        "rejection, v1 chart")


if __name__ == "__main__":
    main()
