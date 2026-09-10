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

prefix="${1:?usage: run_check_lane.sh <check|slowcheck> [timeout_seconds]}"
timeout_seconds="${2:-0}"
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
done

echo "PASS $prefix-lane: ${#members[@]} members"
