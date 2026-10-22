#!/usr/bin/env python3
"""Pin every allocated inode's atime, ctime and mtime in an ext2 image.

GitHub issue #890. The fixture images are built with mke2fs, debugfs and
e2cp. libext2fs takes the times it writes from E2FSPROGS_FAKE_TIME, but e2cp
stamps the inodes it creates (and the directories it adds them to) with the
wall clock, so two builds of the same inputs differed in about 250 bytes and
every kernel object that embeds the image differed with them. This rewrites
those three fields of the root inode and of every allocated non-reserved
inode to one fixed time, in place, after the last tool has run.

Usage: ext2_fixed_times.py IMAGE EPOCH
Exit code only (0 = pass, 1 = fail). The self-test is
scripts/check_ext2_fixed_times.py, which langcheck runs.
"""

import struct
import sys

SUPERBLOCK = 1024
EXT2_MAGIC = 0xEF53
ROOT_INODE = 2
GOOD_OLD_FIRST_INO = 11
GOOD_OLD_INODE_SIZE = 128
GROUP_DESC_SIZE = 32
# Offsets inside an inode: i_atime, i_ctime, i_mtime.
TIME_FIELDS = (8, 12, 16)


def _u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def pin_times(data, epoch):
    """Rewrite the times in bytearray DATA; return the inodes touched."""
    if len(data) < SUPERBLOCK + 1024:
        raise ValueError("image is shorter than an ext2 superblock")
    sb = SUPERBLOCK
    (magic,) = struct.unpack_from("<H", data, sb + 56)
    if magic != EXT2_MAGIC:
        raise ValueError(f"no ext2 magic in the superblock (found {magic:#x})")
    inodes_count = _u32(data, sb + 0)
    first_data_block = _u32(data, sb + 20)
    block_size = 1024 << _u32(data, sb + 24)
    inodes_per_group = _u32(data, sb + 40)
    rev_level = _u32(data, sb + 76)
    if rev_level == 0:
        first_ino, inode_size = GOOD_OLD_FIRST_INO, GOOD_OLD_INODE_SIZE
    else:
        first_ino = _u32(data, sb + 84)
        (inode_size,) = struct.unpack_from("<H", data, sb + 88)
    if inodes_per_group == 0 or inode_size < 20:
        raise ValueError("superblock geometry is not ext2")
    groups = (inodes_count + inodes_per_group - 1) // inodes_per_group
    gdt = (first_data_block + 1) * block_size
    touched = []
    for group in range(groups):
        desc = gdt + group * GROUP_DESC_SIZE
        bitmap = _u32(data, desc + 4) * block_size
        table = _u32(data, desc + 8) * block_size
        for index in range(inodes_per_group):
            number = group * inodes_per_group + index + 1
            if number > inodes_count:
                break
            if number != ROOT_INODE and number < first_ino:
                continue
            if not data[bitmap + index // 8] & (1 << (index % 8)):
                continue
            inode = table + index * inode_size
            if inode + inode_size > len(data):
                raise ValueError(f"inode {number} lies past the image end")
            for field in TIME_FIELDS:
                struct.pack_into("<I", data, inode + field, epoch)
            touched.append(number)
    return touched


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    with open(argv[1], "rb") as f:
        data = bytearray(f.read())
    pin_times(data, int(argv[2]))
    with open(argv[1], "r+b") as f:
        f.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
