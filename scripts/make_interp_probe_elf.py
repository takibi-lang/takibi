#!/usr/bin/env python3
"""Write a minimal AArch64 ET_DYN ELF whose PT_INTERP names a given path.

GitHub issue #591: the ext2 fixture's negative controls for execve's
interpreter check. The kernel decides an ELF's interpreter at syscall time,
before any byte of the image is mapped, so the file only has to pass the
header validator: one PT_INTERP and one PT_LOAD covering the file. It is
never run. A copy of a real musl binary would do the same job at sixty times
the size, and the fixture image has no room for that.

GitHub issue #1040: the same file, with `--et-exec` or `--span BYTES`, is the
fixture for an ELF the validator refuses (an ET_EXEC image, or a PT_LOAD
span over DISTRO_ELF_SPAN_MAX, 256 MiB since #1041). An empty interpreter path leaves the
PT_INTERP out. execve must answer such a file with ENOEXEC; it used to run
BusyBox in its place.

Usage: make_interp_probe_elf.py [--et-exec] [--span BYTES] <interpreter-path> <output>
"""

import struct
import sys

ELF_HEADER_SIZE = 64
PROGRAM_HEADER_SIZE = 56
PT_LOAD = 1
PT_INTERP = 3
ET_EXEC = 2
ET_DYN = 3
EM_AARCH64 = 183


def build(interpreter: bytes, elf_type: int = ET_DYN, span: int = 0) -> bytes:
    table_offset = ELF_HEADER_SIZE
    count = 2 if interpreter else 1
    interp_offset = table_offset + count * PROGRAM_HEADER_SIZE
    interp = interpreter + b"\0" if interpreter else b""
    file_size = interp_offset + len(interp)
    header = struct.pack(
        "<16sHHIQQQIHHHHHH",
        b"\x7fELF\x02\x01\x01" + b"\0" * 9,
        elf_type, EM_AARCH64, 1,
        interp_offset if interpreter else table_offset,  # entry: inside the one PT_LOAD, never reached
        table_offset, 0, 0,
        ELF_HEADER_SIZE, PROGRAM_HEADER_SIZE, count, 0, 0, 0)
    interp_header = struct.pack(
        "<IIQQQQQQ", PT_INTERP, 4, interp_offset, interp_offset,
        interp_offset, len(interp), len(interp), 1)
    memory_size = max(0x1000, span)
    load_header = struct.pack(
        "<IIQQQQQQ", PT_LOAD, 5, 0, 0, 0, file_size, memory_size, 0x1000)
    if not interpreter:
        return header + load_header
    return header + interp_header + load_header + interp


def main() -> int:
    arguments = sys.argv[1:]
    elf_type = ET_DYN
    span = 0
    while arguments and arguments[0].startswith("--"):
        option = arguments.pop(0)
        if option == "--et-exec":
            elf_type = ET_EXEC
        elif option == "--span" and arguments:
            span = int(arguments.pop(0), 0)
        else:
            arguments = []
            break
    if len(arguments) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(arguments[1], "wb") as output:
        output.write(build(arguments[0].encode("ascii"), elf_type, span))
    return 0


if __name__ == "__main__":
    sys.exit(main())
