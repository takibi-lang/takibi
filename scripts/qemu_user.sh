#!/usr/bin/env bash
# GitHub issue #1386: run an aarch64 Linux program under qemu-user with core
# dumps off. A probe that dies by a core-dumping signal (the #946 xfail row
# does, by design) otherwise leaves qemu_<prog>_<time>_<pid>.core in the
# current directory -- the worktree root under make -- and five such files
# were committed on 2026-11-06. scripts/check_qemu_user_core_limit.py
# refuses a qemu-aarch64 invocation that does not come through here or set
# the limit itself.
ulimit -c 0
if command -v qemu-aarch64 >/dev/null 2>&1; then
    exec qemu-aarch64 "$@"
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
    exec qemu-aarch64-static "$@"
fi
echo "error: install qemu-user (or qemu-user-static)" >&2
exit 127
