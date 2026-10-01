#!/usr/bin/env python3
"""The fixture root filesystem keeps a floor of free blocks.

GitHub issue #658. With 18 free blocks left (43 before a 15-block ELF was
added) the QEMU boot stalled after "hello from userspace" with no message
about space. Why it stalls is not yet known; what is known is that the stall
shows up on a boot, minutes into a lane, far from the Makefile line that added
the file. So the image build reads its own superblock and refuses to finish
when the free-block count falls under FLOOR.

FLOOR is well above the 43 that passed and well below the slack the image has
today, so adding a program does not trip it until the slack is mostly spent;
raise the image (and MEMORY_MAP.md's ceiling) then, as a decision.

Usage: check_ext2_image_free_blocks.py IMAGE
       check_ext2_image_free_blocks.py            (the self-test, which is
                                                   what langcheck runs)
Exit code only (0 = pass, 1 = fail).
"""

import struct
import sys

from pass_line import report_pass

FLOOR = 128
SUPERBLOCK = 1024
S_FREE_BLOCKS_COUNT = 12
S_MAGIC = 56


def free_blocks(data):
    if len(data) < SUPERBLOCK + 64:
        raise ValueError("image is shorter than an ext2 superblock")
    (magic,) = struct.unpack_from("<H", data, SUPERBLOCK + S_MAGIC)
    if magic != 0xEF53:
        raise ValueError(f"no ext2 magic in the superblock (found {magic:#x})")
    (free,) = struct.unpack_from("<I", data, SUPERBLOCK + S_FREE_BLOCKS_COUNT)
    return free


def image(free):
    data = bytearray(SUPERBLOCK + 1024)
    struct.pack_into("<H", data, SUPERBLOCK + S_MAGIC, 0xEF53)
    struct.pack_into("<I", data, SUPERBLOCK + S_FREE_BLOCKS_COUNT, free)
    return bytes(data)


def self_test():
    # The check must refuse the shape that stalled and accept the one that did
    # not, or a passing build says nothing.
    refused = [free for free in (18, 43) if free_blocks(image(free)) < FLOOR]
    assert refused == [18, 43], refused
    assert free_blocks(image(FLOOR)) >= FLOOR
    try:
        free_blocks(b"\0" * 4096)
    except ValueError:
        return len(refused)
    raise AssertionError("a zeroed image was accepted")


def main(argv):
    if len(argv) == 1:
        refused = self_test()
        report_pass("ext2-image-free-blocks", "self-test: 18 and 43 refused",
                    cases=refused)
        return 0
    with open(argv[1], "rb") as f:
        free = free_blocks(f.read(SUPERBLOCK + 1024))
    if free < FLOOR:
        print(f"FAIL ext2-image-free-blocks: {argv[1]} has {free} free blocks,"
              f" under the floor of {FLOOR}. A boot with 18 free stalled"
              " silently (GitHub issue #658): make the image larger instead of"
              " adding to it.", file=sys.stderr)
        return 1
    report_pass("ext2-image-free-blocks",
                f"{free} free blocks, floor {FLOOR}", blocks=free)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
