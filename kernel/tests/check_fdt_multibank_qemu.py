#!/usr/bin/env python3
"""Boot the kernel with QEMU's real two-node NUMA-generated memory DTB."""

from __future__ import annotations

import selectors
import subprocess
import sys
import tempfile
import time
from pathlib import Path


MULTIBANK_EXPECTED = (
    b"memory: source=dtb base_bytes=1073741824 detected_mib=1024 "
    b"regions=1 reservations=0 allocator_pages=261264")
# The page count is what is left after every statically laid-out kernel
# region, so it moves whenever the image or the linker script does -- which
# is the point of asserting it exactly rather than as a range. It went
# 31904 -> 31888 for GitHub issue #477, exactly the 16 pages (64 KiB) that
# the second core's own IRQ and overflow stacks cost after the allocator was
# changed to size its runtime inventory from the boot DTB.
LOW_MEMORY_EXPECTED = (
    b"memory: source=dtb base_bytes=1073741824 detected_mib=128 "
    b"regions=1 reservations=0 allocator_pages=31888")
INVALID_EXPECTED = b"memory: invalid boot DTB; halting"


def observe(command: list[str], expected: bytes) -> tuple[bool, bytearray]:
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 10.0
    transcript = bytearray()
    found = False
    try:
        while time.monotonic() < deadline:
            events = selector.select(deadline - time.monotonic())
            if not events:
                break
            chunk = process.stdout.read1(4096)
            if not chunk:
                break
            transcript.extend(chunk)
            if expected in transcript:
                found = True
                break
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    return found, transcript


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    kernel = repo / "kernel/build/qemu/kernel.elf"
    if not kernel.is_file():
        print(f"error: missing QEMU kernel: {kernel}", file=sys.stderr)
        return 1

    command = [
        "qemu-system-aarch64",
        "-machine", "virt",
        "-cpu", "cortex-a53",
        "-smp", "2",
        "-m", "1G",
        "-object", "memory-backend-ram,id=ram0,size=512M",
        "-object", "memory-backend-ram,id=ram1,size=512M",
        "-numa", "node,nodeid=0,memdev=ram0",
        "-numa", "node,nodeid=1,memdev=ram1",
        "-display", "none",
        "-monitor", "none",
        "-serial", "stdio",
        "-kernel", str(kernel),
    ]
    found, transcript = observe(command, MULTIBANK_EXPECTED)
    if not found:
        sys.stderr.buffer.write(transcript)
        print("FAIL kernel/qemu FDT multi-bank: expected memory line absent",
              file=sys.stderr)
        return 1
    print("PASS kernel/qemu FDT multi-bank: two adjacent NUMA nodes normalized to one 1024 MiB region")

    low_memory_command = [
        "qemu-system-aarch64",
        "-machine", "virt",
        "-cpu", "cortex-a53",
        "-smp", "2",
        "-m", "128M",
        "-display", "none",
        "-monitor", "none",
        "-serial", "stdio",
        "-kernel", str(kernel),
    ]
    found, transcript = observe(low_memory_command, LOW_MEMORY_EXPECTED)
    if not found:
        sys.stderr.buffer.write(transcript)
        print("FAIL kernel/qemu FDT allocator sizing: expected memory line absent",
              file=sys.stderr)
        return 1
    print("PASS kernel/qemu FDT allocator sizing: 128 MiB DTB supplies 31888 pages")

    with tempfile.TemporaryDirectory(prefix="takibi-fdt-") as directory:
        dtb = Path(directory) / "virt.dtb"
        generated = subprocess.run([
            "qemu-system-aarch64",
            "-machine", f"virt,dumpdtb={dtb}",
            "-cpu", "cortex-a53",
            "-smp", "2",
            "-m", "1G",
            "-display", "none",
            "-monitor", "none",
            "-serial", "none",
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if generated.returncode != 0:
            sys.stderr.buffer.write(generated.stdout)
            print("FAIL kernel/qemu FDT negative control: DTB generation failed",
                  file=sys.stderr)
            return 1
        blob = dtb.read_bytes()
        if blob.count(b"memory\0") != 1:
            print("FAIL kernel/qemu FDT negative control: unexpected QEMU DTB shape",
                  file=sys.stderr)
            return 1

        dtb.write_bytes(blob.replace(b"memory\0", b"xemory\0"))
        invalid_command = [
            "qemu-system-aarch64",
            "-machine", "virt",
            "-cpu", "cortex-a53",
            "-smp", "2",
            "-m", "1G",
            "-display", "none",
            "-monitor", "none",
            "-serial", "stdio",
            "-dtb", str(dtb),
            "-kernel", str(kernel),
        ]
        found, transcript = observe(invalid_command, INVALID_EXPECTED)
        if not found:
            sys.stderr.buffer.write(transcript)
            print("FAIL kernel/qemu FDT negative control: kernel did not halt",
                  file=sys.stderr)
            return 1
    print("PASS kernel/qemu FDT negative control: unusable memory description halted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
