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
# Reuse the outer ownership only when both its marker and its inherited lock
# descriptor are present. Trusting the environment variable alone would let
# an unrelated invocation bypass serialization by exporting the same name.
if [ "${TAKIBI_KERNEL_BUILD_LOCK_HELD:-0}" = 1 ]; then
    inherited_lock="$(readlink -f /proc/$$/fd/9 2>/dev/null || true)"
    expected_lock="$(readlink -f "$lock_file" 2>/dev/null || true)"
    if [ -n "$inherited_lock" ] && [ "$inherited_lock" = "$expected_lock" ]; then
        exec "$@"
    fi
    echo "invalid inherited kernel build lock marker ($lock_file)" >&2
    exit 2
fi

exec 9>"$lock_file"
if ! flock -n 9; then
    echo "WAIT kernel build: another make owns kernel/build ($lock_file)" >&2
    flock 9
fi

export TAKIBI_KERNEL_BUILD_LOCK_HELD=1
exec "$@"
