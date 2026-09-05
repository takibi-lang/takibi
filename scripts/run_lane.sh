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
set -u

if [ "$#" -lt 2 ]; then
    echo "usage: run_lane.sh LANE COMMAND [ARG...]" >&2
    exit 2
fi

lane="$1"
shift

if "$@"; then
    echo "PASS $lane: every step passed"
else
    status=$?
    echo "FAIL $lane: a step above failed (exit $status)" >&2
    exit "$status"
fi
