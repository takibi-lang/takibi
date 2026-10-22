#!/bin/bash
# One lane, one receipt.
#
# A lane is a wall of PASS lines, and Make stops at the first step that
# fails, so "did all of it pass?" is answered by whether the output simply
# STOPPED -- an absence, read by scrolling up and knowing what should have
# been there. allcheck already refused that bargain and wraps its fan-out to
# print an unmistakable final line either way; this is the same receipt for
# the individual lanes, which are what a person runs directly.
#
# Reaching the end really does mean every step passed: every FAIL in
# scripts/run_kernel_*.sh exits non-zero, including the three that report a
# failing view and keep going so the whole list is reported, which then exit
# 1 once the loop has finished.
#
# The receipt now carries a duration too, when $TAKIBI_LANE_TIMING_DIR names
# somewhere to put it. This is the natural place for it: the lane already has
# a stable name and an exit status here, and every kernelcheck lane already
# goes through this wrapper, so the measurement needs no new process and
# cannot serialize anything (GitHub issue #471).
set -u

if [ "$#" -lt 2 ]; then
    echo "usage: run_lane.sh LANE COMMAND [ARG...]" >&2
    exit 2
fi

lane="$1"
shift

timing="$(dirname "$0")/lane_timing.sh"
started="$(bash "$timing" now)"

export TAKIBI_AWAIT_TIMING_LANE="$lane"
# GitHub issue #883: names this run in every failure archive made under it
# (scripts/archive_kernel_failure.sh), so a passing lane that left one is
# refused below, and a neighbour lane's archive is not blamed on this one.
TAKIBI_LANE_RUN_ID="$lane:$$:$started"
export TAKIBI_LANE_RUN_ID

status=0
"$@" || status=$?

# A passing lane that left an unexpected failure archive is a failing lane
# (#883), and its timing record says so.
if [ "$status" -eq 0 ]; then
    repo_root="$(cd "$(dirname "$0")/.." && pwd)"
    python3 "$repo_root/scripts/lane_new_archives.py" "$TAKIBI_LANE_RUN_ID" \
        "$repo_root/_build" "${TAKIBI_LANE_ARTIFACT_ROOT:-$repo_root/_build}" ||
        status=$?
fi

# Recorded before the verdict is printed, and for a failure as well as a
# pass: a lane that fails slowly is the one most worth measuring, and a
# record that existed only for green runs would be missing exactly then.
bash "$timing" record "$lane" "$started" "$status"

if [ "$status" -eq 0 ]; then
    echo "PASS $lane: every step passed"
else
    echo "FAIL $lane: a step above failed (exit $status)" >&2
    exit "$status"
fi
