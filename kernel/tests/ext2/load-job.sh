#!/bin/sh
# One job of /bin/load.sh's xargs phase (GitHub issue #742). Job 0 writes
# the reference digests; every other job writes its own and compares them,
# then removes them. No pipe: the kernel has none yet (GitHub issue #1042).
# LOAD_ROOT is load.sh's path prefix (empty on Takibi).
root=${LOAD_ROOT:-}
busybox sha256sum "$root/bin/busybox.static" "$root/bin/taskset" \
    >"$root/load/$1.sum" || exit 1
[ "$1" = 0 ] && exit 0
busybox cmp -s "$root/load/0.sum" "$root/load/$1.sum" || exit 1
busybox rm "$root/load/$1.sum"
