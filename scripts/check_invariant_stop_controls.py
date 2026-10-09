#!/usr/bin/env python3
"""Offline refusal controls for explicit-stop call-site interpretation."""

import hashlib
from pathlib import Path
import struct
import tempfile

from pass_line import CaseCount, report_pass
import symbolize_invariant_stop as reader


def main():
    cases = CaseCount()
    elf = bytearray(256)
    elf[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHIQQ", elf, 16, 2, 183, 1, 0x1080, 64)
    struct.pack_into("<HHH", elf, 52, 64, 56, 1)
    struct.pack_into("<IIQQQQQQ", elf, 64, 1, 5, 128, 0x1080, 0, 128, 128, 1)
    capture = {"schema": "takibi.kernel-stop/v1", "origin": "explicit",
               "caller_return_pc": "0x1084", "elf_sha256": hashlib.sha256(elf).hexdigest(),
               "cpu": 0, "registers": {"elr_el1": "0x10f0"}}
    instructions = [(0x1080, "bl 0x10c0 <kernel_invariant_stop>", "real_caller")]
    cases.note()
    assert reader.resolve(capture, elf, instructions)["call_pc"] == 0x1080
    for name, changed, data, insns in (
        ("wrong ELF", capture, bytes(elf[:-1]), instructions),
        ("exception origin", {**capture, "origin": "exception"}, elf, instructions),
        ("missing PC", {**capture, "caller_return_pc": 0}, elf, instructions),
        ("outside text", {**capture, "caller_return_pc": "0x5004"}, elf, instructions),
        ("tail boundary", capture, elf, [(0x1080, "b 0x10c0 <kernel_invariant_stop>", "boundary")]),
        ("other call", capture, elf, [(0x1080, "bl 0x10c0 <other>", "caller")]),
        ("missing instruction", capture, elf, []),
    ):
        cases.note()
        try:
            reader.resolve(changed, data, insns)
        except ValueError:
            pass
        else:
            raise AssertionError(name)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        ram = b"ordinary RAM"
        (root / "ram.bin").write_bytes(ram)
        archive = {"ram": {"file": "ram.bin", "base": "0x40000000", "extent": len(ram),
                           "sha256": hashlib.sha256(ram).hexdigest()}}
        cases.note()
        assert reader.validate_ram(archive, root) == ram
        (root / "ram.bin").write_bytes(ram[:-1])
        cases.note()
        try:
            reader.validate_ram(archive, root)
        except ValueError as error:
            assert "truncated RAM" in str(error)
        else:
            raise AssertionError("truncated RAM accepted")
    report_pass("invariant-stop controls", "exact ELF call resolved; stale ELR ignored; wrong ELF, origin, instruction and truncated RAM refused", cases=cases.ran)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
