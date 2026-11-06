#!/usr/bin/env bash
# Make's SHELL for the lanes timed by `lane_timing.sh begin`/`end`
# (langcheck, slowcheck, test, linuxcheck, modelcheck; GitHub issue #1198).
#
# Those lanes are many recipe lines run by one shared make, so no single
# shell waits for all of a lane's work and nothing can take its CPU delta the
# way scripts/run_lane.sh does. Each recipe line runs here instead: the line
# runs in a child bash, and once it exits the CPU it and its descendants used
# is appended to TAKIBI_LANE_TIMING_DIR/<lane>.cpu, which `end` sums into the
# lane's receipt. The lane is TAKIBI_CPU_LANE, a target-specific export, so
# it also covers that lane's prerequisites; a line counts only while the
# lane's `begin` stamp exists, the same interval its wall time covers.
#
# Without a timing directory this is `bash` and nothing else.
set -u

if [ -z "${TAKIBI_LANE_TIMING_DIR:-}" ] || [ -z "${TAKIBI_CPU_LANE:-}" ]; then
    exec bash "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/lane_cpu.sh"

status=0
lane_cpu_ms before
bash "$@" || status=$?
lane_cpu_ms after
lane="$(printf '%s' "$TAKIBI_CPU_LANE" | tr -c 'A-Za-z0-9_.-' '_')"
if [ -f "$TAKIBI_LANE_TIMING_DIR/$lane.start" ]; then
    # A line whose CPU could not be read marks the lane's figure unknown:
    # `end` then writes the receipt without CPU, and the budget refuses it.
    cpu="$(lane_cpu_seconds "$before" "$after")"
    printf '%s\n' "${cpu:-unknown}" >>"$TAKIBI_LANE_TIMING_DIR/$lane.cpu"
fi
exit "$status"
