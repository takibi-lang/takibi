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
# That is done by moving the ROOT every lane hangs its directory off
# (TAKIBI_LANE_ARTIFACT_ROOT), not by naming each lane's own
# KERNEL_*_ARTIFACT_DIR. GitHub issue #561: this runner takes an arbitrary
# command, so it cannot know which lanes that command will reach. It used to
# redirect exactly one variable, and every other lane kept writing its fixed
# `_build/kernel-<lane>/` path -- so a failing sample's UART log, gdb log and
# verdict were replaced by the next sample's, and the diagnosis needed a
# second reproduction to recover what the first had already printed.
#
# A sample therefore holds one directory per lane the command ran
# (`sample-3/kernel-ddb-qemu/`, `sample-3/kernel-affinity-gdb-qemu/`),
# which is also what keeps an aggregate target's several lanes from
# overwriting each other inside one sample.
#
# PORTS. Each sample gets its own ports, so one sample cannot inherit the
# previous one's lingering sockets. Both lanes read theirs from the
# environment, and BOTH have to be given a sample's own set: this shifted the
# hwtest lane's three and left the interactive shell lane on its fixed 18080,
# so a sample whose predecessor's QEMU had not yet released that port failed
# with `tcp port 18080 is already in use` -- five times in eighteen samples
# while #571 was being measured, which is a measurement spending its hour on
# the runner rather than on the defect.
#
# The base comes from scripts/qemu_session_ports.sh rather than a command line,
# and the count is checked against the window it defines. Separating two agents
# is no longer this flag's job: the lane runner shifts every port by the
# session's own block, so a base picked by hand to dodge another worktree now
# lands INSIDE that worktree's block instead. The window is above the declared
# lane ports and inside one block, so a session's whole footprint moves as one.
#
# WATCHING FOR A LINE, rather than for a red lane. A lane goes red only if one
# of ITS views asserts the thing that went wrong; a symptom can appear in the
# capture of a lane that never looks at it, and then the run is green and the
# evidence is on disk unread. That happened while measuring GitHub issue
# #569: `process table: records MISSING` turned up in the alloc-rollback
# lane's UART log during a passing `make cicheck`, and only a by-hand grep
# over every sample found it. --watch-for makes that the runner's job, so a
# rate is one command instead of a command and a habit.
#
# Usage:
#   repeat_kernel_lane.sh [options] <count> <command...>
#
# Options:
#   --mode check|measure   default measure
#   --label NAME           artifact/label prefix; default derived from command
#   --port-base N          first port; sample i uses N + i*8. Defaults to the
#                          session repeat window and must stay inside it.
#   --artifacts DIR        parent of the per-sample directories
#   --watch-for REGEX      count samples whose CAPTURES contain REGEX, and
#                          report that beside the pass/fail rate
#
# Examples:
#   scripts/repeat_kernel_lane.sh 20 make kernelcheck-qemu
#   scripts/repeat_kernel_lane.sh --mode check --port-base 18724 5 \
#       bash scripts/run_kernel_qemutest.sh
set -uo pipefail

mode=measure
label=""
port_base=""
artifacts=""
watch_for=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) mode="$2"; shift 2;;
        --label) label="$2"; shift 2;;
        --port-base) port_base="$2"; shift 2;;
        --artifacts) artifacts="$2"; shift 2;;
        --watch-for) watch_for="$2"; shift 2;;
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

# The window these ports must stay inside belongs to the session, not to this
# runner. Reaching past it does not merely collide with another lane of this
# clone: the lane runner adds this session's block offset afterwards, so the
# ports land in a DIFFERENT clone's block, where they can take a lane port a
# session that is not running yet will claim later.
. "$repo_root/scripts/qemu_session_ports.sh"
window_top=$((QEMU_SESSION_REPEAT_BASE \
    + QEMU_SESSION_REPEAT_STEP * QEMU_SESSION_REPEAT_MAX_SAMPLES - 1))
[ -n "$port_base" ] || port_base="$QEMU_SESSION_REPEAT_BASE"
case "$port_base" in
    ''|*[!0-9]*) echo "--port-base must be a port number" >&2; exit 2;;
esac
sample_top=$((port_base + QEMU_SESSION_REPEAT_STEP * (count - 1) + 6))
if [ "$port_base" -lt "$QEMU_SESSION_REPEAT_BASE" ] ||
        [ "$sample_top" -gt "$window_top" ]; then
    echo "FAIL repeat: $count samples from base $port_base need ports" \
         "$port_base..$sample_top, outside this session's repeat window" \
         "$QEMU_SESSION_REPEAT_BASE..$window_top" >&2
    echo "  At most $QEMU_SESSION_REPEAT_MAX_SAMPLES samples fit from the" \
         "default base. Ports past the window land in another clone's block." >&2
    exit 2
fi

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
        "TAKIBI_LANE_ARTIFACT_ROOT=$sample_dir"
        "KERNEL_QEMU_LABEL=$label-$i"
    )
    sample_port=$((port_base + (i - 1) * QEMU_SESSION_REPEAT_STEP))
    env_args+=(
        "KERNEL_QEMU_SERIAL_PORT=$sample_port"
        "KERNEL_QEMU_NETDEV_LOCAL_PORT=$((sample_port + 1))"
        "KERNEL_QEMU_NETDEV_REMOTE_PORT=$((sample_port + 2))"
        "KERNEL_QEMU_SHELL_SERIAL_PORT=$((sample_port + 3))"
        "KERNEL_QEMU_SHELL_HTTP_PORT=$((sample_port + 4))"
        "KERNEL_QEMU_SHELL_NETDEV_QEMU_PORT=$((sample_port + 5))"
        "KERNEL_QEMU_SHELL_NETDEV_PEER_PORT=$((sample_port + 6))"
    )
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

if [ -n "$watch_for" ]; then
    # Every TEXT file under the sample, not only the lane's own UART log:
    # which lane's capture carries the line is exactly what is not known in
    # advance, and is often the interesting half of the answer.
    #
    # -I, and it is the difference between a rate and a nonsense. A sample
    # keeps the guest filesystem image it booted, and the strings a fixture
    # can PRINT are in that image as program data -- so watching for
    # `the peer spinner was not reaped` over #571's forty samples reported
    # 40 of 40 while no UART log carried it at all. A symptom worth watching
    # for is one the product can emit, which is exactly the class of string
    # that also sits in the binary that would emit it.
    seen=0
    seen_samples=""
    for i in $(seq 1 "$count"); do
        if grep -rIqE "$watch_for" "$artifacts/sample-$i" 2>/dev/null; then
            seen=$((seen + 1))
            seen_samples="$seen_samples $i"
        fi
    done
    echo "repeat/$label: $seen of $count samples have a capture matching" \
         "$watch_for"
    if [ "$seen" -ne 0 ]; then
        echo "repeat/$label: matching samples:$seen_samples"
        grep -rIlE "$watch_for" "$artifacts" 2>/dev/null |
            sed "s|^$artifacts/|repeat/$label:   |" | sort | head -20
    fi
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
    if f == n:
        # log(1 - p) is log(0) here. There is also nothing to ask: a failure
        # that happened every time is not intermittent under these conditions,
        # so one clean run already says something changed.
        print("repeat: every run failed, so this is not intermittent at this "
              "load. One clean run would already be evidence of a change.")
    else:
        for target, label in ((0.10, "90%"), (0.05, "95%")):
            need = math.ceil(math.log(target) / math.log(1 - p))
            print(f"repeat: {need} consecutive clean runs needed for {label} "
                  "confidence it is gone")
PY
