#!/usr/bin/env bash
# Serialize independent Make invocations that write kernel/build.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 LOCK_FILE COMMAND [ARG ...]" >&2
    exit 2
fi

lock_file="$1"
shift
mkdir -p "$(dirname "$lock_file")"

# A locked build may legitimately invoke another protected build target.
# The inherited marker makes that recursion reuse the outer ownership instead
# of attempting to take the non-recursive flock a second time.
if [ "${TAKIBI_KERNEL_BUILD_LOCK_HELD:-0}" = 1 ]; then
    exec "$@"
fi

exec 9>"$lock_file"
if ! flock -n 9; then
    echo "WAIT kernel build: another make owns kernel/build ($lock_file)" >&2
    flock 9
fi

export TAKIBI_KERNEL_BUILD_LOCK_HELD=1
exec "$@"
