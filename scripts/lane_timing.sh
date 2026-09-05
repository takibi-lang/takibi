#!/usr/bin/env bash
# One timing receipt per check lane, written where a later run can compare it.
#
# The allcheck latency work took the wall time from 93.6s to 51.5s, and
# finding the critical path took several ad hoc timing runs plus manual
# correlation of interleaved parallel output. Nothing kept a receipt, so a
# regression could stay green while making every routine run slower -- which
# the 30-second HTTP readiness circular wait did for a while (GitHub issue
# #471).
#
# Records are append-only JSONL under $TAKIBI_LANE_TIMING_DIR, one file per
# lane so concurrent lanes never interleave a partial line into a shared file.
# Times are epoch seconds with millisecond resolution: lanes run in separate
# processes, so they need a shared clock to be placed on one timeline, and
# elapsed is computed from the same pair rather than from a second source.
#
# Usage:
#   lane_timing.sh now                      print an epoch timestamp
#   lane_timing.sh record LANE START STATUS append a finished lane's record
#   lane_timing.sh begin LANE               write a start stamp for a lane
#                                           whose recipe cannot be wrapped
#   lane_timing.sh end LANE STATUS          close the stamp begin wrote
#
# `begin`/`end` exist for the three aggregate lanes -- langcheck, test,
# linuxcheck -- whose recipes are many lines and which must NOT be turned into
# one recursive make each: that was tried and four independent makes raced on
# dune's build-directory lock (see the allcheck comment in the Makefile). A
# lane that dies between begin and end leaves its stamp behind, and the
# summary reports it as incomplete rather than dropping it, which is the
# honest answer for a lane that did not finish.
set -u

TIMING_DIR="${TAKIBI_LANE_TIMING_DIR:-}"

now() {
    # `date +%s.%3N` is GNU-specific and this repository's runners are Linux.
    date +%s.%3N
}

sanitize() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

# Silently do nothing when no directory is configured, so a lane run by hand
# outside allcheck costs nothing and needs no flag.
enabled() {
    [ -n "$TIMING_DIR" ]
}

case "${1:-}" in
    now)
        now
        ;;
    record)
        [ "$#" -eq 4 ] || { echo "usage: lane_timing.sh record LANE START STATUS" >&2; exit 2; }
        enabled || exit 0
        mkdir -p "$TIMING_DIR" || exit 0
        lane="$2"; start="$3"; status="$4"
        finish="$(now)"
        elapsed="$(awk -v a="$finish" -v b="$start" 'BEGIN { printf "%.3f", a - b }')"
        printf '{"lane":"%s","start":%s,"finish":%s,"elapsed":%s,"status":%s}\n' \
            "$lane" "$start" "$finish" "$elapsed" "$status" \
            >>"$TIMING_DIR/$(sanitize "$lane").jsonl"
        ;;
    begin)
        [ "$#" -eq 2 ] || { echo "usage: lane_timing.sh begin LANE" >&2; exit 2; }
        enabled || exit 0
        mkdir -p "$TIMING_DIR" || exit 0
        now >"$TIMING_DIR/$(sanitize "$2").start"
        ;;
    end)
        [ "$#" -eq 3 ] || { echo "usage: lane_timing.sh end LANE STATUS" >&2; exit 2; }
        enabled || exit 0
        stamp="$TIMING_DIR/$(sanitize "$2").start"
        [ -f "$stamp" ] || exit 0
        "$0" record "$2" "$(cat "$stamp")" "$3"
        rm -f "$stamp"
        ;;
    *)
        echo "usage: lane_timing.sh now|record|begin|end ..." >&2
        exit 2
        ;;
esac
