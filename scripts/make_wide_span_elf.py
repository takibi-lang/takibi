#!/usr/bin/env python3
"""Write a minimal AArch64 static PIE whose PT_LOAD span is BYTES.

GitHub issue #1041: execve used to refuse any image whose highest PT_LOAD
end passed 2 MiB, which kept stress-ng (8 MiB, mostly .bss) from running.
This fixture is the deterministic lane's image over that old bound: a text
segment at 0 and a zero-filled RW segment ending at BYTES. Its code reads
the last byte of the span (it must be zero), stores and reloads it, prints
one line and exits 0; any mismatch exits 1 without printing. The file is a
few hundred bytes, so it fits the fixture image where a large real program
would not.

Usage: make_wide_span_elf.py <span-bytes> <output>
"""

import struct
import sys

ELF_HEADER_SIZE = 64
PROGRAM_HEADER_SIZE = 56
PT_LOAD = 1
ET_DYN = 3
EM_AARCH64 = 183
DATA_BASE = 0x10000


def adr(rd: int, offset: int) -> int:
    imm = offset & 0x1FFFFF
    return 0x10000000 | (imm & 3) << 29 | (imm >> 2) << 5 | rd


def movz(rd: int, imm: int, hw: int = 0) -> int:
    return 0xD2800000 | hw << 21 | imm << 5 | rd


def movk(rd: int, imm: int, hw: int) -> int:
    return 0xF2800000 | hw << 21 | imm << 5 | rd


def build(span: int) -> bytes:
    if span <= DATA_BASE + 0x1000 or span >= 1 << 32:
        raise ValueError("span out of range")
    message = b"nested: %d KiB span ran\n" % (span // 1024)
    entry = ELF_HEADER_SIZE + 2 * PROGRAM_HEADER_SIZE
    target = span - 1 - entry
    code = [
        adr(4, 0),                                  # x4 = entry address
        movz(5, target & 0xFFFF),
        movk(5, target >> 16, 1),
        0x8B050084,                                 # add x4, x4, x5
        0x39400086,                                 # ldrb w6, [x4]
        None,                                       # cbnz w6, fail
        0x52800B46,                                 # mov w6, #0x5a
        0x39000086,                                 # strb w6, [x4]
        0x39400087,                                 # ldrb w7, [x4]
        0x710168FF,                                 # cmp w7, #0x5a
        None,                                       # b.ne fail
        None,                                       # adr x1, message
        movz(0, 1),
        movz(2, len(message)),
        movz(8, 64),                                # write
        0xD4000001,                                 # svc #0
        movz(0, 0),
        movz(8, 93),                                # exit
        0xD4000001,
    ]
    fail = len(code)
    code += [movz(0, 1), movz(8, 93), 0xD4000001]
    message_index = len(code)
    code[5] = 0x35000000 | ((fail - 5) & 0x7FFFF) << 5 | 6
    code[10] = 0x54000001 | ((fail - 10) & 0x7FFFF) << 5
    code[11] = adr(1, (message_index - 11) * 4)
    body = b"".join(struct.pack("<I", word) for word in code) + message
    file_size = entry + len(body)
    header = struct.pack(
        "<16sHHIQQQIHHHHHH",
        b"\x7fELF\x02\x01\x01" + b"\0" * 9,
        ET_DYN, EM_AARCH64, 1, entry, ELF_HEADER_SIZE, 0, 0,
        ELF_HEADER_SIZE, PROGRAM_HEADER_SIZE, 2, 0, 0, 0)
    text = struct.pack("<IIQQQQQQ", PT_LOAD, 5, 0, 0, 0,
                       file_size, file_size, 0x10000)
    data = struct.pack("<IIQQQQQQ", PT_LOAD, 6, 0, DATA_BASE, DATA_BASE,
                       0, span - DATA_BASE, 0x10000)
    return header + text + data + body


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(sys.argv[2], "wb") as output:
        output.write(build(int(sys.argv[1], 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
