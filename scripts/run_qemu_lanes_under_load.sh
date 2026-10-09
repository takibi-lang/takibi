#!/usr/bin/env bash
# Run QEMU lanes side by side under extra CPU load, round after round, to
# reproduce a stall that only a loaded host shows (2026-10-04: the
# virtio-blk completion-wait stall, reproduced 1 round in 3-4 this way and
# never on an idle host).
#
#   scripts/run_qemu_lanes_under_load.sh [-r ROUNDS] [-p BURNERS]
#       [-l MIN_LOAD] [-w WARMUP_SECONDS] [LANE...]
#
# Defaults: 4 rounds, 20 CPU-burning loops, and kernelcheck-qemu,
# kernelcheck-qemu-debug and kernelcheck-race-window-609-qemu. Each round
# starts the lanes together, waits for exactly those lanes, and prints each
# exit status with the load average; a failing lane's FAIL lines and every
# DDB postmortem written during the round follow. The burners are this
# script's own children, are bounded by `timeout`, and are stopped on exit,
# so nothing outlives the run. It refuses to start while this checkout
# still has a QEMU runner from an earlier, interrupted run.
set -uo pipefail

rounds=4
burners=20
minimum_load=""
warmup=180
while getopts "r:p:l:w:" option; do
    case "$option" in
        r) rounds="$OPTARG" ;;
        p) burners="$OPTARG" ;;
        l) minimum_load="$OPTARG" ;;
        w) warmup="$OPTARG" ;;
        *) echo "usage: $0 [-r ROUNDS] [-p BURNERS] [-l MIN_LOAD] [-w WARMUP_SECONDS] [LANE...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
if ! [[ "$rounds" =~ ^[1-9][0-9]*$ && "$burners" =~ ^[0-9]+$ &&
        "$warmup" =~ ^[0-9]+$ ]] ||
        { [ -n "$minimum_load" ] && ! [[ "$minimum_load" =~ ^[0-9]+([.][0-9]+)?$ ]]; }; then
    echo "error: rounds must be positive; burners, warmup and minimum load must be nonnegative" >&2
    exit 2
fi
lanes=("$@")
if [ "${#lanes[@]}" -eq 0 ]; then
    lanes=(kernelcheck-qemu kernelcheck-qemu-debug kernelcheck-race-window-609-qemu)
fi
for lane in "${lanes[@]}"; do
    case "$lane" in
        kernelcheck-qemu*|kernelcheck-*-qemu*) ;;
        *) echo "error: load reproduction accepts only individual QEMU lanes: $lane" >&2; exit 2 ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# An intentional host overload must not starve another checkout's aggregate.
source "$repo_root/scripts/resource_lease.sh"
resource_lease_acquire suite qemu-lanes-under-load || exit 1
if pgrep -f "qemu-system-aarch64.*$repo_root" >/dev/null ||
        pgrep -f "$repo_root/scripts/run_kernel_" >/dev/null; then
    echo "error: a QEMU runner from this checkout is still running; stop it first" >&2
    exit 2
fi
log_dir="$repo_root/_build/lanes-under-load"
mkdir -p "$log_dir"

burner_pids=()
lane_pids=()
stop_burners() {
    for lane_pid in "${lane_pids[@]}"; do
        kill -- "-$lane_pid" 2>/dev/null || true
        wait "$lane_pid" 2>/dev/null || true
    done
    if [ "${#burner_pids[@]}" -gt 0 ]; then
        kill "${burner_pids[@]}" 2>/dev/null || true
        for burner in "${burner_pids[@]}"; do
            wait "$burner" 2>/dev/null || true
        done
    fi
}
trap stop_burners EXIT
trap 'exit 130' INT TERM
for _ in $(seq 1 "$burners"); do
    timeout 3600 sh -c 'while :; do :; done' 7>&- &
    burner_pids+=("$!")
done

# Load average is a one-minute host-wide observation, not an exact setpoint.
# Bound warmup and report the actual load rather than claiming reproduction
# when other host work or an insufficient burner count prevents the floor.
if [ -n "$minimum_load" ]; then
    started=$SECONDS
    while ! awk -v wanted="$minimum_load" '{exit !($1 >= wanted)}' /proc/loadavg; do
        if [ "$((SECONDS - started))" -ge "$warmup" ]; then
            echo "error: minimum load $minimum_load not reached in ${warmup}s; observed $(cat /proc/loadavg)" >&2
            exit 2
        fi
        sleep 1
    done
fi
echo "reproduction: rounds=$rounds burners=$burners minimum_load=${minimum_load:-none} load=$(cat /proc/loadavg)"

failed=0
for round in $(seq 1 "$rounds"); do
    marker="$log_dir/round-$round.start"
    touch "$marker"
    pids=()
    for lane in "${lanes[@]}"; do
        setsid make "$lane" >"$log_dir/round-$round-$lane.log" 2>&1 7>&- &
        pids+=("$!")
    done
    lane_pids=("${pids[@]}")
    summary="round $round:"
    for index in "${!lanes[@]}"; do
        status=0
        wait "${pids[$index]}" || status=$?
        summary="$summary ${lanes[$index]}=$status"
        [ "$status" -eq 0 ] || failed=1
    done
    lane_pids=()
    echo "$summary load=$(cut -d' ' -f1-3 /proc/loadavg)"
    for lane in "${lanes[@]}"; do
        grep -h '^FAIL kernel' "$log_dir/round-$round-$lane.log" | sed 's/^/  /' || true
    done
    find _build -name ddb-postmortem.log -newer "$marker" -not -path '*reverted*' \
        -exec sh -c 'echo "  postmortem: $1"; grep -E "^ddb: (activity|start-refused|virtio-blk)" "$1" | sed "s/^/    /"' _ {} \;
    find _build -name console-state.log -newer "$marker" -not -path '*reverted*' \
        -exec sh -c 'echo "  console snapshot: $1"; cat "$1"' _ {} \;
done
exit "$failed"
