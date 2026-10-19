#!/usr/bin/env bash
# Serialize independent Make invocations that write linux_user/ objects and
# executables (GitHub issue #788): `make allbuild linuxcheck` ran two Makes
# that both compiled linux_user/.../*_exe.o, and one linked while the other
# rewrote the object. Same protocol as the kernel build lock, its own lock.
set -euo pipefail
export TAKIBI_BUILD_LOCK_MARKER=TAKIBI_LINUX_BUILD_LOCK_HELD
export TAKIBI_BUILD_LOCK_FD=8
export TAKIBI_BUILD_LOCK_LABEL=linux_user
export TAKIBI_BUILD_LOCK_TREE=linux_user
exec bash "$(dirname "${BASH_SOURCE[0]}")/run_kernel_build_locked.sh" "$@"
