# ext2 equivalence, tier B (GitHub issue #1034). Read by scripts/ext2_eq.py.
#
# row NAME match|differ ISSUE   -- the kernel's result for the operations
# below is expected to match host Linux + libext2fs, or (an open divergence)
# to differ. The comparison fails on an unexpected outcome in either
# direction, so a fix flips its row to `match` in the same commit.
#
# Operations (paths are under the row's own directory, /eq/NAME):
#   mkdir P | rmdir P | unlink P | rename A B
#   write P TEXT        open(O_CREAT|O_TRUNC) and write TEXT
#   fill P N            write N KiB of '0' in 1 KiB writes
#   overwrite P SRC     write SRC's bytes at offset 0 without O_TRUNC
#   truncate P LEN      truncate(2)
#   files D N           create N empty files with 200-byte names in D
#   peer P TEXT         read 3 bytes through one fd, rewrite P through
#                       another with O_TRUNC, then read through the first
#
# Only the image's free space bounds a row: the fixture keeps about a
# hundred free blocks at the point the ash script runs this.

row base match -
mkdir base
mkdir base/d
write base/d/a hello
rename base/d/a base/b
write base/c one
unlink base/c
rmdir base/d

row otrunc match #1016
mkdir otrunc
write otrunc/f 0123456789
write otrunc/f ab

row overwrite differ #1019
mkdir overwrite
write overwrite/f abcdefgh
write overwrite/src XY
overwrite overwrite/f overwrite/src

row unlink_indirect differ #1020
mkdir unlink_indirect
fill unlink_indirect/f 14
unlink unlink_indirect/f

row truncate differ #1022
mkdir truncate
write truncate/f hello
truncate truncate/f 0

row peer_offset differ #1023
mkdir peer_offset
write peer_offset/f abcdefgh
peer peer_offset/f ab

row dir_indirect differ #968
mkdir dir_indirect
files dir_indirect 52
