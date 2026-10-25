#!/bin/sh
# One job of /bin/load.sh's xargs phase (GitHub issue #742). Job 0 writes
# the reference digests; every other job writes its own and compares them,
# then removes them. No pipe: the kernel has none yet (GitHub issue #1042).
busybox sha256sum /bin/busybox.static /bin/hackbench >/load/"$1".sum || exit 1
[ "$1" = 0 ] && exit 0
busybox cmp -s /load/0.sum /load/"$1".sum || exit 1
busybox rm /load/"$1".sum
