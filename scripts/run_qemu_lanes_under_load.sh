#!/usr/bin/env bash
# Run QEMU lanes side by side under extra CPU load, round after round, to
# reproduce a stall that only a loaded host shows (2026-10-04: the
# virtio-blk completion-wait stall, reproduced 1 round in 3-4 this way and
# never on an idle host).
#
#   scripts/run_qemu_lanes_under_load.sh [-r ROUNDS] [-p BURNERS] [LANE...]
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
while getopts "r:p:" option; do
    case "$option" in
        r) rounds="$OPTARG" ;;
        p) burners="$OPTARG" ;;
        *) echo "usage: $0 [-r ROUNDS] [-p BURNERS] [LANE...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
lanes=("$@")
if [ "${#lanes[@]}" -eq 0 ]; then
    lanes=(kernelcheck-qemu kernelcheck-qemu-debug kernelcheck-race-window-609-qemu)
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if pgrep -f "qemu-system-aarch64.*$repo_root" >/dev/null ||
        pgrep -f "$repo_root/scripts/run_kernel_" >/dev/null; then
    echo "error: a QEMU runner from this checkout is still running; stop it first" >&2
    exit 2
fi
log_dir="$repo_root/_build/lanes-under-load"
mkdir -p "$log_dir"

burner_pids=()
stop_burners() {
    if [ "${#burner_pids[@]}" -gt 0 ]; then
        kill "${burner_pids[@]}" 2>/dev/null || true
    fi
}
trap stop_burners EXIT INT TERM
for _ in $(seq 1 "$burners"); do
    timeout 3600 sh -c 'while :; do :; done' &
    burner_pids+=("$!")
done

failed=0
for round in $(seq 1 "$rounds"); do
    marker="$log_dir/round-$round.start"
    touch "$marker"
    pids=()
    for lane in "${lanes[@]}"; do
        make "$lane" >"$log_dir/round-$round-$lane.log" 2>&1 &
        pids+=("$!")
    done
    summary="round $round:"
    for index in "${!lanes[@]}"; do
        status=0
        wait "${pids[$index]}" || status=$?
        summary="$summary ${lanes[$index]}=$status"
        [ "$status" -eq 0 ] || failed=1
    done
    echo "$summary load=$(cut -d' ' -f1-3 /proc/loadavg)"
    for lane in "${lanes[@]}"; do
        grep -h '^FAIL kernel' "$log_dir/round-$round-$lane.log" | sed 's/^/  /' || true
    done
    find _build -name ddb-postmortem.log -newer "$marker" -not -path '*reverted*' \
        -exec sh -c 'echo "  postmortem: $1"; grep -E "^ddb: (activity|start-refused|virtio-blk)" "$1" | sed "s/^/    /"' _ {} \;
done
exit "$failed"
