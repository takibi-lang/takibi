#!/usr/bin/env bash
# Regression controls for the cross-Make kernel build lock.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/run_kernel_build_locked.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -r "$tmp_dir"' EXIT
# GitHub issue #526: a control asserts the number of claims it made. A PASS
# that names zero of them is a run that checked nothing.
cases=0
claim() { cases=$((cases + 1)); }
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
claim
grep -F "another make owns kernel/build" "$wait_log" >/dev/null
claim

if TAKIBI_KERNEL_BUILD_LOCK_HELD=1 \
    "$runner" "$lock_file" true 2>"$tmp_dir/invalid-marker.log"; then
    echo "FAIL kernel-build-lock: an environment marker bypassed the lock" >&2
    exit 1
fi
claim
grep -F "invalid inherited kernel build lock marker" \
    "$tmp_dir/invalid-marker.log" >/dev/null
claim

"$runner" "$lock_file" "$runner" "$lock_file" \
    bash -c 'echo nested >>"$1"' _ "$events"
tail -n 1 "$events" | grep -Fx nested >/dev/null
claim

# GitHub issue #788: the linux_user lock runs the same protocol on its own
# lock file, descriptor and marker. Owners wait for each other, and either
# lock nests inside the other without being taken for a forged marker.
linux_runner="$repo_root/scripts/run_linux_build_locked.sh"
linux_lock="$tmp_dir/linux-build.lock"
linux_events="$tmp_dir/linux-events"
"$linux_runner" "$linux_lock" bash -c \
    'echo first-start >>"$1"; sleep 0.2; echo first-end >>"$1"' \
    _ "$linux_events" &
first_pid=$!
for _attempt in $(seq 1 100); do
    [ -s "$linux_events" ] && break
    sleep 0.01
done
"$linux_runner" "$linux_lock" bash -c 'echo second >>"$1"' _ "$linux_events" \
    2>"$tmp_dir/linux-wait.log"
wait "$first_pid"
cmp "$expected" "$linux_events"
claim
grep -F "another make owns linux_user" "$tmp_dir/linux-wait.log" >/dev/null
claim
"$runner" "$lock_file" "$linux_runner" "$linux_lock" \
    "$runner" "$lock_file" bash -c 'echo kernel-linux-kernel >>"$1"' _ "$events"
tail -n 1 "$events" | grep -Fx kernel-linux-kernel >/dev/null
claim
if TAKIBI_LINUX_BUILD_LOCK_HELD=1 \
    "$linux_runner" "$linux_lock" true 2>/dev/null; then
    echo "FAIL kernel-build-lock: a linux_user marker bypassed the lock" >&2
    exit 1
fi
claim

echo "PASS kernel-build-lock: $cases claims -- owners wait, false markers fail, and nested builds reuse ownership, for kernel/build and linux_user"
