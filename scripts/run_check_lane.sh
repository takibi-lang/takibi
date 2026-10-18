#!/usr/bin/env bash
# Run one check lane, discovered by glob.
#
# GitHub issue #526. `langcheck` began as one grep and grew into forty-eight
# hand-written script invocations, and what that hand-list allowed was a
# control that drove real sockets, real subprocesses and real wall-clock
# budgets sitting in the gate everything else waited behind. It cost CI nine
# consecutive red runs, six of them on that one script, and for several of
# those rounds it gated `allbuild` -- so no kernel lane ran at all and the
# real defects behind it stayed invisible.
#
# So the lane is a glob and the prefix is the dispatch. A file's name says
# which lane runs it and nothing else:
#
#   check_<subject>[_controls].{py,sh}   may run in the fast gate
#   slowcheck_<subject>.{py,sh}          must wait, so it runs in the slow lane
#
# The fast gate passes a timeout, and that is the part that is a mechanism
# rather than a promise: a member that waits is killed and the lane goes red.
# It catches gross violations only -- the bound sits far above the slowest
# legitimate member -- and that limit is accepted deliberately. The bound is a
# MEMBERSHIP rule, not an estimate: a check that cannot finish inside it has
# changed category, so it is investigated or renamed rather than given a
# bigger number, the same discipline the boot-duration bound already carries.
#
# `buildcheck_` names the third population, which is not a lane: those must be
# handed a linked ELF or a built kernel, so they run from the rule that builds
# it. They are deliberately outside both globs.
set -euo pipefail

trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

prefix="${1:?usage: run_check_lane.sh <check|slowcheck> [timeout_seconds] [cpu_budget_ms] [cpu_budget_refs]}"
timeout_seconds="${2:-0}"
# GitHub issue #823: the wall-clock bound above trips only at 10 s, and a CPU-
# bound member that took 2.7 s alone (check_dma_mint_files.py, rescanning every
# kernel file four times) crossed it twice at host load 60. CPU time does not
# grow with load the way wall time does, so the fast gate also bounds each
# member's own CPU (user + system, children included), in milliseconds. The
# slowest legitimate member used about 0.9 s on 2026-10-19; like the wall
# bound this is a membership rule, not an estimate to raise: a member over it
# caches its scans (scripts/source_scan.py per_file) or moves to slowcheck_*.
cpu_budget_ms="${3:-0}"
# GitHub issue #823, reopened: CPU time is not load-independent either. SMT
# sharing, frequency scaling and cache contention took
# check_source_scan_cache_controls.py from about 750 ms quiet to 2295 ms under
# allcheck load, so the absolute budget alone was itself an intermittent. The
# absolute number is now only the fast path: a member under it passes without
# further cost. A member over it is judged against scripts/cpu_reference.py,
# a fixed workload of the same kind run three times right after it under the
# same load, and fails only when it used more than cpu_budget_refs times the
# slowest of those runs. Load inflates both sides, so the verdict follows the
# member's work, not the host's state.
cpu_budget_refs="${4:-0}"

# Children's user+system CPU so far, in milliseconds, from the `times` builtin
# (its second line, "XmS.SSSs XmS.SSSs"), so no process is spawned to measure.
# It sets children_cpu and reads `times` back from a file: any $(...) would run
# `times` in a fresh subshell, whose children have used nothing.
times_file="$(mktemp)"
trap 'rm -f "$times_file"' EXIT
children_cpu_ms() {
    local lines line part m s
    children_cpu=0
    times > "$times_file"
    lines="$(<"$times_file")"
    line="${lines#*$'\n'}"
    for part in $line; do
        m="${part%%m*}"; s="${part#*m}"; s="${s%s}"
        children_cpu=$(( children_cpu + m * 60000 + 10#${s%.*} * 1000 + 10#${s#*.} ))
    done
}
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

members=()
while IFS= read -r member; do
    [ -n "$member" ] || continue
    members+=("$member")
done < <(
    for path in "$repo_root/scripts/$prefix"_*.py "$repo_root/scripts/$prefix"_*.sh; do
        [ -e "$path" ] || continue
        printf '%s\n' "$path"
    done | LC_ALL=C sort
)

# A glob that stops matching must not report success having run nothing --
# the same "PASS about nothing" shape scripts/pass_line.py refuses inside a
# single check, applied to the lane.
if [ "${#members[@]}" -eq 0 ]; then
    echo "FAIL $prefix-lane: no scripts/${prefix}_* members found" >&2
    exit 1
fi

for member in "${members[@]}"; do
    case "$member" in
        *.sh) runner=(bash "$member");;
        *)    runner=(python3 "$member");;
    esac
    status=0
    children_cpu_ms; cpu_before=$children_cpu
    if [ "$timeout_seconds" -gt 0 ]; then
        timeout --kill-after=5 "$timeout_seconds" "${runner[@]}" || status=$?
    else
        "${runner[@]}" || status=$?
    fi
    if [ "$status" -eq 124 ]; then
        echo "FAIL $prefix-lane: $(basename "$member") did not finish within" \
             "${timeout_seconds}s. The fast gate is for checks that read" \
             "tracked files; a member that waits belongs in the slow lane," \
             "so rename it slowcheck_* rather than raising this bound." >&2
        exit 1
    fi
    if [ "$status" -ne 0 ]; then
        echo "FAIL $prefix-lane: $(basename "$member") exited $status" >&2
        exit "$status"
    fi
    children_cpu_ms; cpu_used=$(( children_cpu - cpu_before ))
    if [ "$cpu_budget_ms" -gt 0 ] && [ "$cpu_used" -gt "$cpu_budget_ms" ]; then
        ref_ms=0
        if [ "$cpu_budget_refs" -gt 0 ]; then
            for _ in 1 2 3; do
                children_cpu_ms; ref_before=$children_cpu
                python3 "$repo_root/scripts/cpu_reference.py" > /dev/null
                children_cpu_ms; ref_run=$(( children_cpu - ref_before ))
                [ "$ref_run" -gt "$ref_ms" ] && ref_ms=$ref_run
            done
            if [ "$cpu_used" -le $(( cpu_budget_refs * ref_ms )) ]; then
                echo "NOTE $prefix-lane: $(basename "$member") used ${cpu_used} ms" \
                     "of CPU, over ${cpu_budget_ms} ms but within" \
                     "${cpu_budget_refs} x ${ref_ms} ms reference runs (host load)" >&2
                continue
            fi
        fi
        echo "FAIL $prefix-lane: $(basename "$member") used ${cpu_used} ms of" \
             "CPU, over the ${cpu_budget_ms} ms member budget and over" \
             "${cpu_budget_refs} x ${ref_ms} ms scripts/cpu_reference.py runs" \
             "measured right after it. Under host load" \
             "that becomes a wall-clock timeout; cache repeated scans with" \
             "scripts/source_scan.py per_file, or rename it slowcheck_*." >&2
        exit 1
    fi
done

echo "PASS $prefix-lane: ${#members[@]} members"
