#!/usr/bin/env bash
# Serialize independent Make invocations that write one build tree.
#
# By default the tree is kernel/build. scripts/run_linux_build_locked.sh
# reuses this for linux_user/ (GitHub issue #788) with its own marker,
# descriptor and label, so the two locks nest without either one mistaking
# the other's inherited descriptor for its own.
set -euo pipefail

# `set -e` aborts with no context, and a lane's setup prints nothing on
# success -- a CI failure once reported exit 74 and not one line saying
# which command produced it. Name the line, the command and the status.
trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

if [ "$#" -lt 2 ]; then
    echo "usage: $0 LOCK_FILE COMMAND [ARG ...]" >&2
    exit 2
fi

marker="${TAKIBI_BUILD_LOCK_MARKER:-TAKIBI_KERNEL_BUILD_LOCK_HELD}"
lock_fd="${TAKIBI_BUILD_LOCK_FD:-9}"
label="${TAKIBI_BUILD_LOCK_LABEL:-kernel}"
tree="${TAKIBI_BUILD_LOCK_TREE:-kernel/build}"
unset TAKIBI_BUILD_LOCK_MARKER TAKIBI_BUILD_LOCK_FD TAKIBI_BUILD_LOCK_LABEL TAKIBI_BUILD_LOCK_TREE
case "$marker" in TAKIBI_*_LOCK_HELD) ;; *) echo "bad lock marker $marker" >&2; exit 2 ;; esac
case "$lock_fd" in [3-9]) ;; *) echo "bad lock descriptor $lock_fd" >&2; exit 2 ;; esac

lock_file="$1"
shift
mkdir -p "$(dirname "$lock_file")"

# A locked build may legitimately invoke another protected build target.
# Reuse the outer ownership only when both its marker and its inherited lock
# descriptor are present. Trusting the environment variable alone would let
# an unrelated invocation bypass serialization by exporting the same name.
if [ "${!marker:-0}" = 1 ]; then
    inherited_lock="$(readlink -f "/proc/$$/fd/$lock_fd" 2>/dev/null || true)"
    expected_lock="$(readlink -f "$lock_file" 2>/dev/null || true)"
    if [ -n "$inherited_lock" ] && [ "$inherited_lock" = "$expected_lock" ]; then
        exec "$@"
    fi
    echo "invalid inherited $label build lock marker ($lock_file)" >&2
    exit 2
fi

eval "exec $lock_fd>\"\$lock_file\""
if ! flock -n "$lock_fd"; then
    echo "WAIT $label build: another make owns $tree ($lock_file)" >&2
    flock "$lock_fd"
fi

export "$marker=1"
exec "$@"
