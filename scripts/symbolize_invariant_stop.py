#!/usr/bin/env python3
"""Resolve an archived explicit kernel stop only against its exact linked ELF."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import struct
import sys

from buildcheck_kernel_asm_invariants import STOP_ENTRIES, objdump_lines, parse_instructions
from profile_kernel_samples import symbolize
from symbolize_ddb import executable, number


def resolve(capture, elf, instructions):
    if not isinstance(capture, dict):
        raise ValueError("capture must be an object")
    digest = hashlib.sha256(elf).hexdigest()
    if capture.get("schema") != "takibi.kernel-stop/v1":
        raise ValueError("unsupported capture schema")
    if capture.get("elf_sha256") != digest:
        raise ValueError("wrong ELF digest")
    kind, _, segments, _ = executable(elf)
    if kind != 2 or struct.unpack_from("<H", elf, 18)[0] != 183:
        raise ValueError("kernel capture requires an AArch64 executable ELF")
    if capture.get("origin") != "explicit":
        raise ValueError("capture is not an explicit invariant stop")
    pc = number(capture["caller_return_pc"])
    if pc < 4 or pc % 4:
        raise ValueError("missing or unaligned caller return PC")
    call = pc - 4
    if not any(start <= call and call + 4 <= end for start, end in segments):
        raise ValueError("call instruction is outside executable ELF segments")
    candidates = [text for address, text, _ in instructions if address == call]
    if len(candidates) != 1 or not re.fullmatch(
            r"bl\s+0x[0-9a-f]+ <kernel_invariant_stop(?:_with_frame)?>", candidates[0]):
        raise ValueError("unsupported call instruction or assembly boundary")
    target = re.search(r"<(\w+)>", candidates[0]).group(1)
    if target not in STOP_ENTRIES:
        raise ValueError("unsupported stop entry")
    return {"status": "resolved", "caller_return_pc": pc, "call_pc": call,
            "entry": target, "elf_sha256": digest}


def validate_ram(capture, directory):
    """Optional ordinary-RAM evidence is copied whole; never read the guest."""
    if not isinstance(capture, dict):
        raise ValueError("capture must be an object")
    if "ram" not in capture:
        return None
    ram = capture["ram"]
    base, extent = number(ram["base"]), number(ram["extent"])
    if not extent or base + extent > 1 << 64:
        raise ValueError("invalid RAM base/extent")
    source = (directory / ram["file"]).resolve()
    if source.parent != directory.resolve():
        raise ValueError("RAM archive must be beside capture")
    data = source.read_bytes()
    if len(data) != extent:
        raise ValueError("truncated RAM archive")
    if hashlib.sha256(data).hexdigest() != ram["sha256"]:
        raise ValueError("wrong RAM digest")
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    report = {"schema": "takibi.kernel-stop-symbols/v1", "status": "unresolved"}
    try:
        raw = args.capture.read_bytes()
        capture = json.loads(raw)
        report["capture_sha256"] = hashlib.sha256(raw).hexdigest()
        (args.out / "capture.json").write_bytes(raw)
        ram = validate_ram(capture, args.capture.parent)
        if ram is not None:
            (args.out / "ram.bin").write_bytes(ram)
        elf = args.elf.read_bytes()
        report["input_elf_sha256"] = hashlib.sha256(elf).hexdigest()
        report.update(resolve(capture, elf, parse_instructions(objdump_lines(str(args.elf)))))
        report["symbol"] = symbolize("llvm-addr2line-19", str(args.elf), [report["call_pc"]], 30)[0]
        if report["symbol"]["function"] is None:
            raise ValueError("exact ELF has no caller symbol")
        (args.out / "kernel.elf").write_bytes(elf)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report.update(status="unresolved", reason=str(error))
    (args.out / "symbols.json").write_text(json.dumps(report, indent=2) + "\n", encoding="ascii")
    print(json.dumps(report))
    return 0 if report["status"] == "resolved" else 1


if __name__ == "__main__":
    sys.exit(main())
