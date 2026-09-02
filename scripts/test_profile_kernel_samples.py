#!/usr/bin/env python3
"""Controls for bounded flat-PC sample validation and symbolization."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


SCRIPT = Path(__file__).with_name("profile_kernel_samples.py")


def run(root, uart, *extra):
    return subprocess.run([
        sys.executable, str(SCRIPT), "--uart-log", str(uart),
        "--output", str(root / "out.json"), "--kernel-elf", str(root / "image"),
        "--pid-elf", f"7={root / 'image'}", "--target", "test",
        "--commit", "abc", *extra], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE)


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / "image.c"
        source.write_text("int sampled(void) { return 1; }\nint main(void) { return sampled(); }\n",
                          encoding="ascii")
        subprocess.run(["cc", "-g", "-no-pie", str(source), "-o", str(root / "image")],
                       check=True)
        address = subprocess.run(
            ["nm", str(root / "image")], check=True, text=True,
            stdout=subprocess.PIPE).stdout.split(" sampled", 1)[0].splitlines()[-1].split()[0]
        uart = root / "uart.log"
        good = (
            "profile: begin name=busy-pair input_steps=1 cpu_count=1 iterations_goal=1 pid_a=7 pid_b=8\n"
            "profile: end name=busy-pair elapsed_cycles=10 tick_frequency=1 iterations_a=1 iterations_b=1 result_count=2 checksum_a=1 checksum_b=2\n"
            f"profile: sample name=busy-pair sequence=0 timestamp=2 cpu=0 pid=7 level=el0 pc=0x{address} period=100\n"
            f"profile: sample name=busy-pair sequence=1 timestamp=3 cpu=0 pid=0 level=el1 pc=0x{address} period=100\n"
            "profile: sample-summary name=busy-pair stored=2 lost=1 attempted=3\n")
        uart.write_text(good, encoding="ascii")
        result = run(root, uart)
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        artifact = json.loads((root / "out.json").read_text(encoding="ascii"))
        if (artifact["schema"] != "takibi.kernel.flat-pc/v1" or
                artifact["loss"] != {"stored": 2, "lost": 1, "attempted": 3} or
                any(row["symbol"]["function"] != "sampled"
                    for row in artifact["samples"])):
            raise RuntimeError("EL0/EL1 symbolization or loss metadata failed")

        uart.write_text(good.replace("sequence=1", "sequence=2"), encoding="ascii")
        result = run(root, uart)
        if result.returncode == 0 or "sequence is missing" not in result.stderr:
            raise RuntimeError("out-of-order sequence was accepted")

        uart.write_text(good.replace("attempted=3", "attempted=4"), encoding="ascii")
        result = run(root, uart)
        if result.returncode == 0 or "lost total is inconsistent" not in result.stderr:
            raise RuntimeError("inconsistent lost total was accepted")

        uart.write_text(good.replace("pid=7 level=el0", "pid=9 level=el0"),
                        encoding="ascii")
        result = run(root, uart)
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        artifact = json.loads((root / "out.json").read_text(encoding="ascii"))
        if artifact["samples"][0]["symbol"]["function"] is not None:
            raise RuntimeError("unmapped EL0 PID acquired a guessed symbol")

        uart.write_text(good.replace(f"pc=0x{address}", "pc=0x0", 1),
                        encoding="ascii")
        result = run(root, uart)
        if result.returncode != 0:
            raise RuntimeError(result.stderr)
        artifact = json.loads((root / "out.json").read_text(encoding="ascii"))
        if artifact["samples"][0]["symbol"]["function"] is not None:
            raise RuntimeError("unknown address acquired a guessed symbol")

        uart.write_text(good.replace("level=el0", "level=user", 1),
                        encoding="ascii")
        result = run(root, uart)
        if result.returncode == 0 or "execution level is invalid" not in result.stderr:
            raise RuntimeError("malformed execution level was accepted")

        uart.write_text(good, encoding="ascii")
        result = run(root, uart, "--pid-elf", f"7={root / 'image'}")
        if result.returncode == 0 or "duplicate ELF mapping" not in result.stderr:
            raise RuntimeError("duplicate PID ELF mapping was accepted")

        blocker = root / "blocking-symbolizer"
        blocker.write_text("#!/bin/sh\nsleep 5\n", encoding="ascii")
        blocker.chmod(0o755)
        result = run(root, uart, "--symbolizer", str(blocker),
                     "--symbolizer-timeout", "0.1")
        if result.returncode == 0 or "symbolizer timed out" not in result.stderr:
            raise RuntimeError("blocked symbolizer was not bounded by its timeout")

    print("PASS profile-kernel-samples: identities, loss, rejection, timeout")


if __name__ == "__main__":
    main()
