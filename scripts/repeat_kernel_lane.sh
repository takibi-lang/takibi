#!/usr/bin/env bash
# Run a kernel lane N times: as a CHECK (N consecutive clean runs) or as a
# MEASUREMENT (N samples, reported as a failure rate).
#
# Two questions, one runner, because they share everything except what they do
# with a failure:
#
#   --mode check     stop at the first failure and give a verdict. What a
#                    timing-sensitive lane wants in a suite.
#   --mode measure   keep going and report the RATE, plus how many clean runs
#                    a claim of "fixed" would actually need. (default)
#
# Why the measurement mode exists: on 2026-08-30 an intermittent failure was
# declared fixed twice on the evidence of a clean run of eight, and a clean
# eight against a one-in-six event happens 23% of the time. The arithmetic is
# trivial and nobody does it by hand, so it is printed.
#
# EVERY sample gets its own artifact directory, pass or fail. For a
# timing-sensitive failure the useful comparison is a passing boot against a
# failing one, and the lane's own directory is overwritten by the next run.
#
# PORTS. With --port-base each sample gets its own serial and netdev ports, so
# repeated runs cannot collide with each other, and two agents working in
# separate worktrees cannot collide either by choosing different bases. The
# QEMU lane already reads all three from the environment.
#
# Usage:
#   repeat_kernel_lane.sh [options] <count> <command...>
#
# Options:
#   --mode check|measure   default measure
#   --label NAME           artifact/label prefix; default derived from command
#   --port-base N          first port; sample i uses N + i*8
#   --artifacts DIR        parent of the per-sample directories
#
# Examples:
#   scripts/repeat_kernel_lane.sh 20 make kernelcheck-qemu
#   scripts/repeat_kernel_lane.sh --mode check --port-base 18720 5 \
#       bash scripts/run_kernel_qemutest.sh
set -uo pipefail

mode=measure
label=""
port_base=""
artifacts=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) mode="$2"; shift 2;;
        --label) label="$2"; shift 2;;
        --port-base) port_base="$2"; shift 2;;
        --artifacts) artifacts="$2"; shift 2;;
        --) shift; break;;
        -*) echo "unknown option: $1" >&2; exit 2;;
        *) break;;
    esac
done

case "$mode" in check|measure) ;; *) echo "--mode must be check or measure" >&2; exit 2;; esac
count="${1:?usage: repeat_kernel_lane.sh [options] <count> <command...>}"
shift
[ $# -gt 0 ] || { echo "usage: repeat_kernel_lane.sh [options] <count> <command...>" >&2; exit 2; }
case "$count" in ''|*[!0-9]*|0) echo "count must be a positive integer" >&2; exit 2;; esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

[ -n "$label" ] || label="$(echo "$*" | tr -c 'A-Za-z0-9' '-' | sed 's/-\+/-/g;s/^-//;s/-$//' | cut -c1-40)"
[ -n "$artifacts" ] || artifacts="$repo_root/_build/repeat-$label"
mkdir -p "$artifacts"

pass=0
fail=0
failed_samples=""
for i in $(seq 1 "$count"); do
    sample_dir="$artifacts/sample-$i"
    rm -rf "$sample_dir"
    mkdir -p "$sample_dir"
    env_args=(
        "KERNEL_QEMU_HWTEST_ARTIFACT_DIR=$sample_dir"
        "KERNEL_QEMU_LABEL=$label-$i"
    )
    if [ -n "$port_base" ]; then
        env_args+=(
            "KERNEL_QEMU_SERIAL_PORT=$((port_base + (i - 1) * 8))"
            "KERNEL_QEMU_NETDEV_LOCAL_PORT=$((port_base + (i - 1) * 8 + 1))"
            "KERNEL_QEMU_NETDEV_REMOTE_PORT=$((port_base + (i - 1) * 8 + 2))"
        )
    fi
    if env "${env_args[@]}" "$@" >"$sample_dir/run.log" 2>&1; then
        pass=$((pass + 1)); printf '.'
    else
        fail=$((fail + 1)); printf 'F'
        failed_samples="$failed_samples $i"
        if [ "$mode" = check ]; then
            printf '\n'
            echo "FAIL repeat/$label: sample $i of $count failed" >&2
            grep -E '^FAIL|^error:' "$sample_dir/run.log" | head -5 >&2
            echo "artifacts: $sample_dir" >&2
            exit 1
        fi
    fi
done
printf '\n'

if [ "$mode" = check ]; then
    echo "PASS repeat/$label: $count independent runs"
    exit 0
fi

echo "repeat/$label: $count runs -> $pass pass, $fail fail"
[ -n "$failed_samples" ] && echo "repeat/$label: failing samples:$failed_samples"
echo "repeat/$label: artifacts kept per sample under $artifacts"

python3 - "$count" "$fail" <<'PY'
import math, sys
n = int(sys.argv[1]); f = int(sys.argv[2])
if f == 0:
    print("repeat: no failures observed.")
    print("repeat: that is NOT the same as none existing. A clean run of "
          f"{n} would still happen by luck with probability:")
    for p in (1/4, 1/6, 1/10, 1/20, 1/50):
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
