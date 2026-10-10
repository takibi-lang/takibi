#!/usr/bin/env python3
"""Exercise adjacent and discontiguous QEMU NUMA DTBs through the allocator."""

from __future__ import annotations

import os
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from await_timing import AwaitTiming  # noqa: E402

# Each boot's wait for its memory line: a fixed budget from QEMU launch, or
# from release after the DTB is patched. GitHub issue #666 records how much
# of it was used, without changing it or the verdict.
OBSERVE_TIMEOUT_SECONDS = 10.0
LABEL = "kernel/qemu fdt-multibank"


MULTIBANK_EXPECTED = (
    b"memory: source=dtb base_bytes=1073741824 detected_mib=1024 "
    b"regions=1 reservations=0 allocator_pages=261552")
# The page count is what is left after every statically laid-out kernel
# region, so it moves whenever the image or the linker script does -- which
# is the point of asserting it exactly rather than as a range. It went
# 31904 -> 31888 for GitHub issue #477, exactly the 16 pages (64 KiB) that
# the second core's own IRQ and overflow stacks cost after the allocator was
# changed to size its runtime inventory from the boot DTB. Enabling kernel
# frame pointers later grew the linked QEMU image by 8 pages (32 KiB), moving
# this count and the topology variants below down by 8. The deterministic
# contention probes later crossed the next stack-group alignment boundary,
# moving them down by another 8 pages. Reserving boot and per-core stacks
# for cores 2 and 3 as well as core 1 then moved them down by 48 pages
# (192 KiB): two 32 KiB boot stacks and two 64 KiB per-core groups.
# The DDB waker snapshot and its bounded network inspection later crossed the
# next 32 KiB alignment granule, moving these QEMU counts down by 8 pages.
LOW_MEMORY_EXPECTED = (
    b"memory: source=dtb base_bytes=1073741824 detected_mib=128 "
    b"regions=1 reservations=0 allocator_pages=32176")
MISSING_EXPECTED = b"memory: boot DTB has no usable /memory; halting"
DISCONTIGUOUS_MEMORY_EXPECTED = (
    b"memory: source=dtb base_bytes=1073741824 detected_mib=768 "
    b"regions=2 reservations=0 allocator_pages=196016")
DISCONTIGUOUS_PROBE_EXPECTED = (
    b"memory: physical hole excluded and both extent boundaries round-trip")


def make_discontiguous(blob: bytes) -> bytes:
    """Shrink QEMU's first NUMA node, leaving a 256 MiB DT-only hole."""
    if len(blob) < 40:
        raise ValueError("short FDT header")
    (magic, total, struct_offset, strings_offset, _, _, _, _,
     strings_size, struct_size) = struct.unpack_from(">10I", blob)
    if magic != 0xD00DFEED or total > len(blob):
        raise ValueError("invalid FDT header")
    struct_end = struct_offset + struct_size
    strings_end = strings_offset + strings_size
    if struct_end > total or strings_end > total:
        raise ValueError("invalid FDT bounds")

    patched = bytearray(blob)
    cursor = struct_offset
    nodes: list[str] = []
    changed = 0
    while cursor < struct_end:
        token = struct.unpack_from(">I", blob, cursor)[0]
        cursor += 4
        if token == 1:
            end = blob.find(b"\0", cursor, struct_end)
            if end < 0:
                raise ValueError("unterminated FDT node name")
            nodes.append(blob[cursor:end].decode("ascii"))
            cursor = (end + 4) & ~3
        elif token == 2:
            if not nodes:
                raise ValueError("unbalanced FDT node")
            nodes.pop()
        elif token == 3:
            if cursor + 8 > struct_end:
                raise ValueError("short FDT property")
            length, name_offset = struct.unpack_from(">II", blob, cursor)
            cursor += 8
            name_start = strings_offset + name_offset
            name_end = blob.find(b"\0", name_start, strings_end)
            if name_end < 0 or cursor + length > struct_end:
                raise ValueError("invalid FDT property")
            name = blob[name_start:name_end]
            if nodes and nodes[-1] == "memory@40000000" and name == b"reg":
                if length != 16 or blob[cursor:cursor + 16] != bytes.fromhex(
                        "00000000400000000000000020000000"):
                    raise ValueError("unexpected first NUMA memory reg")
                struct.pack_into(">I", patched, cursor + 12, 0x10000000)
                changed += 1
            cursor = (cursor + length + 3) & ~3
        elif token == 4:
            continue
        elif token == 9:
            break
        else:
            raise ValueError(f"unknown FDT token {token}")
    if changed != 1:
        raise ValueError(f"expected one first NUMA reg, changed {changed}")
    return bytes(patched)


def observe_process(process: subprocess.Popen[bytes], expected: bytes,
                    timing_path: str | None = None, name: str = "memory line",
                    clock=time.monotonic) -> tuple[bool, bytearray]:
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    started = clock()
    deadline = started + OBSERVE_TIMEOUT_SECONDS
    timing = AwaitTiming(timing_path, started, OBSERVE_TIMEOUT_SECONDS, (), (),
                         label=LABEL, origin="QEMU start of this boot",
                         milestones=(name,))
    transcript = bytearray()
    found = False
    try:
        while clock() < deadline:
            events = selector.select(max(0.0, deadline - clock()))
            if not events:
                break
            chunk = process.stdout.read1(4096)
            if not chunk:
                break
            transcript.extend(chunk)
            if expected in transcript:
                timing.record(name, True, clock())
                found = True
                break
    finally:
        timing.finish(clock())
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    return found, transcript


def observe(command: list[str], expected: bytes, timing_path: str,
            name: str) -> tuple[bool, bytearray]:
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return observe_process(process, expected, timing_path, name)


def observe_patched_dtb(command: list[str], dtb: Path, expected: bytes,
                        timing_path: str, name: str
                        ) -> tuple[bool, bytearray]:
    # QEMU's raw-ELF boot places its generated DTB at physical address zero;
    # `-dtb` does not replace that blob for this boot path. Pause at reset and
    # overwrite those bytes through the existing gdbstub before the first
    # instruction, so x0=0 retains the real boot contract.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    process = subprocess.Popen(
        command + ["-S", "-gdb", f"tcp:127.0.0.1:{port}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    debugger = None
    for _ in range(10):
        debugger = subprocess.run([
            "gdb-multiarch", "--batch", "--quiet",
            "-ex", "set confirm off",
            "-ex", f"target remote 127.0.0.1:{port}",
            "-ex", f"restore {dtb} binary 0",
            "-ex", "detach",
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5.0)
        if debugger.returncode == 0:
            break
        time.sleep(0.05)
    assert debugger is not None
    if debugger.returncode != 0:
        process.terminate()
        process.wait(timeout=2.0)
        return False, bytearray(debugger.stdout)
    return observe_process(process, expected, timing_path, name)


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    kernel = repo / "kernel/build/qemu/kernel.elf"
    if not kernel.is_file():
        print(f"error: missing QEMU kernel: {kernel}", file=sys.stderr)
        return 1
    artifacts = Path(os.environ.get("TAKIBI_LANE_ARTIFACT_ROOT",
                                    str(repo / "_build"))) / "kernel-fdt-multibank-qemu"
    artifacts.mkdir(parents=True, exist_ok=True)

    def timing(boot: str) -> str:
        return str(artifacts / f"await-{boot}.jsonl")

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
    found, transcript = observe(command, MULTIBANK_EXPECTED,
                               timing("multibank"), "multi-bank memory line")
    if not found:
        sys.stderr.buffer.write(transcript)
        print("FAIL kernel/qemu FDT multi-bank: expected memory line absent",
              file=sys.stderr)
        return 1
    print("PASS kernel/qemu FDT multi-bank: two adjacent NUMA nodes normalized to one 1024 MiB region")

    with tempfile.TemporaryDirectory(prefix="takibi-fdt-hole-") as directory:
        dtb = Path(directory) / "virt.dtb"
        generated = subprocess.run([
            "qemu-system-aarch64",
            "-machine", f"virt,dumpdtb={dtb}",
            "-cpu", "cortex-a53",
            "-smp", "2",
            "-m", "1G",
            "-object", "memory-backend-ram,id=ram0,size=512M",
            "-object", "memory-backend-ram,id=ram1,size=512M",
            "-numa", "node,nodeid=0,memdev=ram0",
            "-numa", "node,nodeid=1,memdev=ram1",
            "-display", "none",
            "-monitor", "none",
            "-serial", "none",
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if generated.returncode != 0:
            sys.stderr.buffer.write(generated.stdout)
            print("FAIL kernel/qemu FDT physical-hole generation",
                  file=sys.stderr)
            return 1
        try:
            dtb.write_bytes(make_discontiguous(dtb.read_bytes()))
        except ValueError as error:
            print(f"FAIL kernel/qemu FDT physical-hole patch: {error}",
                  file=sys.stderr)
            return 1
        discontiguous_command = [
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
        found, transcript = observe_patched_dtb(
            discontiguous_command, dtb, DISCONTIGUOUS_PROBE_EXPECTED,
            timing("physical-hole"), "physical-hole allocator probe")
        if not found or DISCONTIGUOUS_MEMORY_EXPECTED not in transcript:
            sys.stderr.buffer.write(transcript)
            print("FAIL kernel/qemu FDT physical-hole allocator probe",
                  file=sys.stderr)
            return 1
    print("PASS kernel/qemu FDT physical hole: two extents, excluded hole, and boundary round-trips")

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
    found, transcript = observe(low_memory_command, LOW_MEMORY_EXPECTED,
                               timing("low-memory"), "low-memory sizing line")
    if not found:
        sys.stderr.buffer.write(transcript)
        print("FAIL kernel/qemu FDT allocator sizing: expected memory line absent",
              file=sys.stderr)
        return 1
    print("PASS kernel/qemu FDT allocator sizing: 128 MiB DTB supplies 31856 pages")

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
            "-kernel", str(kernel),
        ]
        found, transcript = observe_patched_dtb(
            invalid_command, dtb, MISSING_EXPECTED,
            timing("missing-memory"), "missing-memory halt")
        if not found:
            sys.stderr.buffer.write(transcript)
            print("FAIL kernel/qemu FDT negative control: kernel did not reject the modified tree",
                  file=sys.stderr)
            return 1
    print("PASS kernel/qemu FDT negative control: patched tree reached the kernel and missing memory halted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
