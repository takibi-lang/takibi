#!/usr/bin/env bash
# Regression controls for the cross-Make kernel build lock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/run_kernel_build_locked.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -r "$tmp_dir"' EXIT
lock_file="$tmp_dir/kernel-build.lock"
events="$tmp_dir/events"
wait_log="$tmp_dir/wait.log"

"$runner" "$lock_file" bash -c \
    'echo first-start >>"$1"; sleep 0.2; echo first-end >>"$1"' \
    _ "$events" &
first_pid=$!

for _attempt in $(seq 1 100); do
    [ -s "$events" ] && break
    sleep 0.01
done

"$runner" "$lock_file" bash -c 'echo second >>"$1"' _ "$events" \
    2>"$wait_log"
wait "$first_pid"

expected="$tmp_dir/expected"
printf '%s\n' first-start first-end second >"$expected"
cmp "$expected" "$events"
grep -F "another make owns kernel/build" "$wait_log" >/dev/null

TAKIBI_KERNEL_BUILD_LOCK_HELD=1 \
    "$runner" "$lock_file" bash -c 'echo nested >>"$1"' _ "$events"
tail -n 1 "$events" | grep -Fx nested >/dev/null

echo "PASS kernel-build-lock: independent owners wait and nested builds do not deadlock"
