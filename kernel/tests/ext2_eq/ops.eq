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
#   fill P N            write the BusyBox binary's first N KiB (N <= 1024), dd bs=1024
#   copy P SRC          cat SRC with stdout redirected to a distinct P
#   overwrite P SRC     write SRC's bytes at offset 0 without O_TRUNC
#   files D N           create N empty files with 200-byte names in D
#   truncate P          truncate -s 0: ftruncate(2) to length 0
#   peer P              write 0123456789 to P, hold it open as fd 3 and read
#                       6 bytes, truncate P to "ab" through another open,
#                       then read and write "Z" through fd 3 (#1023)
#   adopt P             mv the doubly-indirect fixture the comparing lane's
#                       runner planted at /lib/ext2-eq-dind to P (#1021;
#                       scripts/ext2_eq.py DIND_BLOCKS; at most once)
#
# The script runs from /etc/init.sh after /bin/user_payload has released its
# ENOSPC fillers; the rows share the image's free space (about 360 blocks
# since #1413 shrank /pad by 128).
# File writes use external BusyBox applets. The copy row exercises cat's
# read/write fallback when its sendfile destination is an ext2 file.

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

row overwrite match #1019
mkdir overwrite
write overwrite/f abcdefgh
write overwrite/src XY
overwrite overwrite/f overwrite/src

row unlink_indirect match #1020
mkdir unlink_indirect
fill unlink_indirect/f 14
unlink unlink_indirect/f

row dir_indirect match #968
mkdir dir_indirect
files dir_indirect 52

row truncate match #1022
mkdir truncate
fill truncate/f 14
truncate truncate/f

row peer match #1023
mkdir peer
peer peer/f

# #1016's O_TRUNC release of a doubly-indirect tree (#1021). The kernel
# writes no file past the singly-indirect range (268 KiB), so the file is
# the runner's planted sparse fixture: 270 KiB long, data in a direct
# block, under the singly-indirect block, and two under the doubly-indirect
# block's second-level block. The O_TRUNC write frees all seven blocks.
row truncate_dind match #1021
mkdir truncate_dind
adopt truncate_dind/f
write truncate_dind/f ab

row cat_copy match #1070
mkdir cat_copy
write cat_copy/src correct-bytes
write cat_copy/dst previous-longer-content
copy cat_copy/dst cat_copy/src
