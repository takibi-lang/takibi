#!/usr/bin/env python3
"""Write a minimal AArch64 ET_DYN ELF whose PT_INTERP names a given path.

GitHub issue #591: the ext2 fixture's negative controls for execve's
interpreter check. The kernel decides an ELF's interpreter at syscall time,
before any byte of the image is mapped, so the file only has to pass the
header validator: one PT_INTERP and one PT_LOAD covering the file. It is
never run. A copy of a real musl binary would do the same job at sixty times
the size, and the fixture image has no room for that.

Usage: make_interp_probe_elf.py <interpreter-path> <output>
"""

import struct
import sys

ELF_HEADER_SIZE = 64
PROGRAM_HEADER_SIZE = 56
PT_LOAD = 1
PT_INTERP = 3
ET_DYN = 3
EM_AARCH64 = 183


def build(interpreter: bytes) -> bytes:
    table_offset = ELF_HEADER_SIZE
    interp_offset = table_offset + 2 * PROGRAM_HEADER_SIZE
    interp = interpreter + b"\0"
    file_size = interp_offset + len(interp)
    header = struct.pack(
        "<16sHHIQQQIHHHHHH",
        b"\x7fELF\x02\x01\x01" + b"\0" * 9,
        ET_DYN, EM_AARCH64, 1,
        interp_offset,  # entry: inside the one PT_LOAD, never reached
        table_offset, 0, 0,
        ELF_HEADER_SIZE, PROGRAM_HEADER_SIZE, 2, 0, 0, 0)
    interp_header = struct.pack(
        "<IIQQQQQQ", PT_INTERP, 4, interp_offset, interp_offset,
        interp_offset, len(interp), len(interp), 1)
    load_header = struct.pack(
        "<IIQQQQQQ", PT_LOAD, 5, 0, 0, 0, file_size, 0x1000, 0x1000)
    return header + interp_header + load_header + interp


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(sys.argv[2], "wb") as output:
        output.write(build(sys.argv[1].encode("ascii")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
