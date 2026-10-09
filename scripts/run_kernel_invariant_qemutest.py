#!/usr/bin/env python3
"""Retain and resolve the isolated no-frame stop's actual linked call site."""

import hashlib
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time


def main():
    elf = Path(sys.argv[1]).resolve()
    out = Path(os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT", "_build")) / "kernel-invariant-qemu"
    out.mkdir(parents=True, exist_ok=True)
    loaded = elf.read_bytes()
    elf = (out / "kernel.elf").resolve()
    elf.write_bytes(loaded)
    data = bytearray()
    command = ["qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a53",
               "-smp", "1", "-m", "128", "-display", "none", "-monitor", "none",
               "-serial", "stdio", "-kernel", str(elf)]
    with (out / "qemu.log").open("wb") as errors:
        guest = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors)
        try:
            until = time.monotonic() + 30
            while time.monotonic() < until:
                if guest.poll() is not None:
                    break
                ready, _, _ = select.select([guest.stdout], [], [], 0.2)
                if ready:
                    chunk = os.read(guest.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    data.extend(chunk)
                    if b"oops: saved-frame=unavailable\r\n" in data or b"oops: saved-frame=unavailable\n" in data:
                        break
        finally:
            guest.terminate()
            try:
                guest.wait(timeout=3)
            except subprocess.TimeoutExpired:
                guest.kill()
                guest.wait()
    (out / "uart.log").write_bytes(data)
    text = data.decode("ascii", "replace").replace("\r", "")
    origin = re.search(r"^oops: origin=explicit caller_return_pc=(0x[0-9a-f]+) architectural-registers=raw$", text, re.M)
    if origin is None or "oops: saved-frame=unavailable\n" not in text:
        print("FAIL invariant-qemu: explicit no-frame evidence missing", file=sys.stderr)
        print(text, file=sys.stderr)
        return 1
    registers = dict(re.findall(r"\b(esr|far|elr|sp_el0|tpidr_el0|ttbr0)=(0x[0-9a-f]+)", text))
    capture = {"schema": "takibi.kernel-stop/v1", "origin": "explicit", "cpu": 0,
               "caller_return_pc": origin.group(1), "elf_sha256": hashlib.sha256(loaded).hexdigest(),
               "uart_sha256": hashlib.sha256(data).hexdigest(),
               "per_cpu_registers": [{"cpu": 0, "registers": registers}]}
    source = out / "capture.json"
    source.write_text(json.dumps(capture, indent=2) + "\n", encoding="ascii")
    result = subprocess.run([sys.executable, "scripts/symbolize_invariant_stop.py",
                             "--capture", str(source), "--elf", str(elf), "--out", str(out / "symbols")],
                            capture_output=True, text=True, timeout=40)
    report = json.loads((out / "symbols/symbols.json").read_text())
    if result.returncode != 0 or report.get("symbol", {}).get("function") != "invariant_stop_fixture_run":
        print("FAIL invariant-qemu: actual fixture call not resolved", file=sys.stderr)
        print(result.stdout, result.stderr, file=sys.stderr)
        return 1
    print("PASS invariant-qemu: explicit no-frame stop resolves its actual linked call, ignoring raw ELR")
    return 0


if __name__ == "__main__":
    sys.exit(main())
