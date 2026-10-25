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
#   fill P N            write N KiB (N <= 13) in 1 KiB writes (the script's first KiB)
#   overwrite P SRC     write SRC's bytes at offset 0 without O_TRUNC
#   files D N           create N empty files with 200-byte names in D
#
# The script runs from /etc/init.sh after /bin/user_payload has released its
# ENOSPC fillers; the rows share the image's free space (about 230 blocks).
# Every command writing a file is an external one (/bin/busybox APPLET): the
# kernel's dup3 serves only stdin/stdout aliasing, so a redirected shell
# builtin cannot write a file.
#
# Not rows yet (GitHub issue #1034 records why):
#   #1022 truncate(2)/ftruncate(2) are unimplemented syscalls, and the
#         qemu-main view unimplemented_syscalls requires that none is reached.
#   #1023 needs one fd's offset kept across an O_TRUNC through another; the
#         shell can only share an fd through dup2, which the kernel refuses.
#   #1021 needs a doubly-indirect file (over 268 KiB), more than the image's
#         free space.

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
fill unlink_indirect/f 13
unlink unlink_indirect/f

row dir_indirect differ #968
mkdir dir_indirect
files dir_indirect 52

