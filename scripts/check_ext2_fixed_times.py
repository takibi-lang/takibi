#!/usr/bin/env python3
"""Self-test for scripts/ext2_fixed_times.py (GitHub issue #890).

The image build runs ext2_fixed_times.py last so two builds of the same
inputs are byte-identical; `make kernel-image-repro-check` proves that on
the real images. This fast member proves the rewriter itself on a synthetic
one-group image: inodes stamped at different wall-clock times converge to
the same bytes, the root and allocated non-reserved inodes are pinned, and
free and reserved inodes are left alone. Its control: a different epoch
gives different bytes, so the convergence is not the rewriter erasing
everything.

Exit code only (0 = pass, 1 = fail).
"""

import struct
import sys

from ext2_fixed_times import pin_times
from pass_line import report_pass

BLOCK = 1024
INODES = 32
INODE_SIZE = 128
BITMAP_BLOCK = 3
TABLE_BLOCK = 4
ALLOCATED = (1, 2, 11, 12)
FREE = 13


def image(clock):
    data = bytearray(BLOCK * (TABLE_BLOCK + INODES * INODE_SIZE // BLOCK))
    sb = 1024
    struct.pack_into("<I", data, sb + 0, INODES)
    struct.pack_into("<I", data, sb + 20, 1)            # first data block
    struct.pack_into("<I", data, sb + 40, INODES)       # inodes per group
    struct.pack_into("<H", data, sb + 56, 0xEF53)
    struct.pack_into("<I", data, sb + 76, 1)            # dynamic revision
    struct.pack_into("<I", data, sb + 84, 11)           # first inode
    struct.pack_into("<H", data, sb + 88, INODE_SIZE)
    gd = 2 * BLOCK
    struct.pack_into("<I", data, gd + 4, BITMAP_BLOCK)
    struct.pack_into("<I", data, gd + 8, TABLE_BLOCK)
    for number in ALLOCATED:
        index = number - 1
        data[BITMAP_BLOCK * BLOCK + index // 8] |= 1 << (index % 8)
    for number in (*ALLOCATED, FREE):
        inode = TABLE_BLOCK * BLOCK + (number - 1) * INODE_SIZE
        for field in (8, 12, 16):
            stamp = clock + number if number in (2, 11, 12) else 5 + number
            struct.pack_into("<I", data, inode + field, stamp)
    return data


def times(data, number):
    inode = TABLE_BLOCK * BLOCK + (number - 1) * INODE_SIZE
    return [struct.unpack_from("<I", data, inode + f)[0] for f in (8, 12, 16)]


def self_test():
    first, second = image(1_800_000_000), image(1_800_000_777)
    assert first != second
    touched = pin_times(first, 1_700_000_000)
    pin_times(second, 1_700_000_000)
    assert first == second, "images stamped at different clocks differ"
    assert touched == [2, 11, 12], touched
    assert times(first, 2) == [1_700_000_000] * 3
    assert times(first, 1) == [6] * 3, "reserved inode rewritten"
    assert times(first, FREE) == [5 + FREE] * 3, "free inode"
    control = image(1_800_000_000)
    pin_times(control, 1_700_000_001)
    assert control != first, "control: a different epoch gave the same bytes"
    try:
        pin_times(bytearray(4096), 1)
    except ValueError:
        return len(touched)
    raise AssertionError("a zeroed image was accepted")


def main():
    touched = self_test()
    report_pass("ext2-fixed-times",
                "clocks converge; reserved and free inodes kept; control"
                " epoch differs", inodes=touched)
    return 0


if __name__ == "__main__":
    sys.exit(main())
