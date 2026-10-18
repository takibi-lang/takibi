#!/usr/bin/env bash
# Run independent checks at the same time and report each one whole.
#
# GitHub issue #820: _kernelbuild-check ran three buildchecks one after
# another (backing-exists alone about 7.9 minutes on a hosted runner), and
# CI runs Make at -j1, so splitting them into Make prerequisites would not
# have overlapped them there. They compile into their own temporary
# directories and read only the already-built sources, so nothing they write
# is shared; running them from one recipe keeps them inside the caller's
# kernel build lock.
#
# Each check's output is buffered and printed in argument order once all have
# finished, so the log reads as if they had run serially. Each also leaves a
# lane-timing record (scripts/lane_timing.sh) under its own name, so the
# summary shows what the time before the first lane was spent on. The exit
# status is the first failing check's, and every failure is named.
#
# Usage: run_concurrent_checks.sh NAME COMMAND [NAME COMMAND ...]
#   COMMAND is one shell word, run with `bash -c`.
set -u

if [ "$#" -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
    echo "usage: run_concurrent_checks.sh NAME COMMAND [NAME COMMAND ...]" >&2
    exit 2
fi

timing="$(dirname "$0")/lane_timing.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/takibi-concurrent-XXXXXX")"
trap 'rm -rf "$work"' EXIT

names=()
pids=()
index=0
while [ "$#" -gt 0 ]; do
    name="$1"; command="$2"; shift 2
    names+=("$name")
    (
        started="$(bash "$timing" now)"
        status=0
        bash -c "$command" >"$work/$index.out" 2>&1 || status=$?
        bash "$timing" record "$name" "$started" "$status"
        exit "$status"
    ) &
    pids+=("$!")
    index=$((index + 1))
done

result=0
failed=()
for i in "${!pids[@]}"; do
    status=0
    wait "${pids[$i]}" || status=$?
    cat "$work/$i.out"
    if [ "$status" -ne 0 ]; then
        failed+=("${names[$i]} (exit $status)")
        [ "$result" -ne 0 ] || result="$status"
    fi
done

if [ "$result" -ne 0 ]; then
    echo "FAIL concurrent checks: ${failed[*]}" >&2
fi
exit "$result"
