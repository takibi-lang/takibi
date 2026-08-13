#!/usr/bin/env bash
# Stream one command's combined output through a cross-process line lock.
# allcheck starts independent QEMU/RPi5/compiler lanes concurrently; without
# this tiny relay, their progress output reaches one terminal in arbitrary
# byte chunks.  The command's status remains the script's status (pipefail).
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 LOCK_FILE COMMAND [ARG...]" >&2
    exit 2
fi

lock_file=$1
shift

mkdir -p "$(dirname "$lock_file")"

"$@" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
    flock "$lock_file" printf '%s\n' "$line"
done
