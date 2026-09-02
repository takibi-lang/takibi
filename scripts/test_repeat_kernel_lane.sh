#!/usr/bin/env bash
# Regression controls for the repeat runner's two modes.
#
# Both are shapes that went wrong once. A check that keeps going after a
# failure reports a verdict it has not earned; a measurement that stops at
# the first one cannot produce a rate, which is the whole reason the
# measuring mode exists (see AGENTS.md's confidence entry).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/repeat_kernel_lane.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() { echo "FAIL repeat-runner-control: $*" >&2; exit 1; }

# --- check mode stops at the first failure and reports it -----------------
out="$tmp_dir/check.log"
status=0
bash "$runner" --mode check --label ctl-check --artifacts "$tmp_dir/check" \
    5 sh -c 'exit 1' >"$out" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail "check mode exited $status, expected 1"
grep -q "sample 1 of 5" "$out" || fail "check mode did not stop at the first sample"
[ -d "$tmp_dir/check/sample-1" ] || fail "check mode kept no artifacts for the failing sample"
[ -d "$tmp_dir/check/sample-2" ] && fail "check mode ran past the first failure"

# --- check mode passes when every sample passes ---------------------------
status=0
bash "$runner" --mode check --label ctl-ok --artifacts "$tmp_dir/ok" \
    3 true >"$tmp_dir/ok.log" 2>&1 || status=$?
[ "$status" -eq 0 ] || fail "check mode failed on a command that always succeeds"
grep -q "PASS repeat/ctl-ok: 3 independent runs" "$tmp_dir/ok.log" ||
    fail "check mode printed no verdict"

# --- measure mode keeps going and reports the rate ------------------------
counter="$tmp_dir/counter"
: >"$counter"
bash "$runner" --mode measure --label ctl-rate --artifacts "$tmp_dir/rate" 6 \
    bash -c 'printf x >>"$0"; n=$(wc -c <"$0"); test $((n % 3)) -ne 0' "$counter" \
    >"$tmp_dir/rate.log" 2>&1
grep -q "6 runs -> 4 pass, 2 fail" "$tmp_dir/rate.log" ||
    fail "measure mode did not run every sample: $(grep 'runs ->' "$tmp_dir/rate.log" || true)"
grep -q "observed rate 2/6" "$tmp_dir/rate.log" || fail "measure mode reported no rate"
grep -q "consecutive clean runs needed" "$tmp_dir/rate.log" ||
    fail "measure mode reported no confidence requirement"
[ -d "$tmp_dir/rate/sample-6" ] || fail "measure mode kept no artifacts for the last sample"

# --- a clean measurement still says what it has NOT ruled out -------------
bash "$runner" --mode measure --label ctl-clean --artifacts "$tmp_dir/clean" \
    2 true >"$tmp_dir/clean.log" 2>&1
grep -q "no failures observed" "$tmp_dir/clean.log" || fail "clean run reported nothing"
grep -q "if the real rate were 1 in" "$tmp_dir/clean.log" ||
    fail "clean run did not say what a clean run of that length fails to prove"

echo "PASS repeat-runner-control: check stops at the first failure, measure reports the rate"
