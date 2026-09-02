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
            "network_rx_bytes=0 network_tx_bytes=0\n")
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

    print("PASS profile-kernel-workload: per-CPU artifact, rejection, v1 chart")


if __name__ == "__main__":
    main()
