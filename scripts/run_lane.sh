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

status=0
"$@" || status=$?

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
