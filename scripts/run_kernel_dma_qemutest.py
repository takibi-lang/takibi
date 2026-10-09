#!/usr/bin/env python3
"""Run the isolated DMA authority fixture with a bounded, port-free QEMU."""
import os
from pathlib import Path
import select
import subprocess
import sys
import time

EXPECTED = [
    "PASS dma: completed error returns all CPU authority",
    "PASS dma: timeout and confirmed reset permit reuse",
    "PASS dma: failed reset retains all Device authority and refuses reuse",
    "PASS dma: fixture complete",
]


def transcript_finished(captured):
    # Serial reads may end halfway through a diagnostic. Stop only after its
    # terminating newline, so the failure witness survives in the capture.
    failure = captured.find(b"FAIL dma:")
    failed_line = failure >= 0 and b"\n" in captured[failure:]
    return failed_line or (EXPECTED[-1] + "\n").encode() in captured


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: run_kernel_dma_qemutest.py ELF")
    artifacts = Path(os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT", "_build")) / "dma-qemu"
    artifacts.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen([
        "qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a53",
        "-smp", "1", "-m", "128M", "-display", "none", "-monitor", "none",
        "-serial", "stdio", "-nic", "none", "-kernel", sys.argv[1],
    ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    captured = bytearray()
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            if select.select([process.stdout], [], [], 0.2)[0]:
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    break
                captured.extend(data)
                if transcript_finished(captured):
                    break
            if process.poll() is not None:
                break
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    text = captured.decode("ascii", errors="replace").replace("\r", "")
    (artifacts / "uart.log").write_text(text, encoding="ascii")
    print(text, end="")
    lines = [line for line in text.splitlines() if line.startswith(("PASS dma:", "FAIL dma:"))]
    if lines != EXPECTED:
        print("FAIL dma-qemu: incomplete or invalid authority transcript", file=sys.stderr)
        return 1
    print("PASS dma-qemu: all maintained ownership branches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
