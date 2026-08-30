#!/usr/bin/env bash
# Run a kernel lane N times and report the failure RATE, not just pass/fail.
#
# GitHub issue #488 and AGENTS.md's "Before calling an intermittent failure
# fixed -- or calling it a flake -- compute your confidence." That entry
# exists because one failure appearing in about one boot in six was declared
# fixed twice on the evidence of a clean run of eight, which happens 23% of
# the time by luck. The arithmetic is easy and nobody does it by hand at
# 2am, so it is a tool.
#
# What it prints that a bare loop does not:
#   - the observed rate;
#   - how many further clean runs would be needed for 90% and 95%
#     confidence AT THAT RATE, which is the number to quote when saying
#     "fixed";
#   - what a clean run of this length would have proven if the rate were
#     the one you already measured -- the sentence that would have stopped
#     both wrong calls.
#
# Usage: repeat_kernel_lane.sh <count> <make-target> [make-target...]
#   scripts/repeat_kernel_lane.sh 20 kernelcheck-qemu
set -uo pipefail

count="${1:?usage: repeat_kernel_lane.sh <count> <make-target...>}"
shift
targets=("$@")
[ "${#targets[@]}" -gt 0 ] || { echo "usage: repeat_kernel_lane.sh <count> <make-target...>" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

log_dir="$(mktemp -d)"
pass=0
fail=0
for i in $(seq 1 "$count"); do
    if make "${targets[@]}" >"$log_dir/run$i.log" 2>&1; then
        pass=$((pass + 1))
        printf '.'
    else
        fail=$((fail + 1))
        printf 'F'
        # The first line of a failure is usually the whole story; the rest
        # is in the archive the lane itself now keeps.
        {
            echo "--- run $i ---"
            grep -E '^FAIL|^error:' "$log_dir/run$i.log" | head -3
        } >>"$log_dir/failures.txt"
    fi
done
printf '\n'

echo "repeat: ${targets[*]} x$count -> $pass pass, $fail fail"
if [ -s "$log_dir/failures.txt" ]; then
    cat "$log_dir/failures.txt"
fi
echo "logs: $log_dir"

python3 - "$count" "$fail" <<'PY'
import math, sys
n = int(sys.argv[1]); f = int(sys.argv[2])
if f == 0:
    print("repeat: no failures observed.")
    print("repeat: that is NOT the same as none existing. A clean run of "
          f"{n} would still happen by luck with probability:")
    for p in (1/4, 1/6, 1/10, 1/20):
        print(f"          {(1-p)**n:6.1%}  if the real rate were 1 in {round(1/p)}")
    print("repeat: quote the rate you have ruled out, not the word 'fixed'.")
else:
    p = f / n
    print(f"repeat: observed rate {f}/{n} = {p:.3f}")
    print(f"repeat: a clean run of {n} at this rate would have probability "
          f"{(1-p)**n:.1%} -- that is what such a run would have proven.")
    for target, label in ((0.10, "90%"), (0.05, "95%")):
        need = math.ceil(math.log(target) / math.log(1 - p))
        print(f"repeat: {need} consecutive clean runs needed for {label} "
              "confidence it is gone")
PY
