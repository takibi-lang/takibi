#!/usr/bin/env bash
# Controls for the lane timing receipts and the summary built from them.
#
# The measurement exists so a slow lane cannot hide behind a green verdict,
# which means the interesting cases are all ones a healthy allcheck never
# produces: a lane that passes slowly, a lane that fails, a lane that never
# finishes, and a run that recorded nothing at all. Each is planted here.
#
# The tail case is the one worth the trouble. LONGEST and TAIL are different
# numbers and the difference is the whole point -- a long lane running beside
# an equally long one costs nothing to shorten -- so the summary is required
# to name a different lane for each when the records say so.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LANE="$REPO_ROOT/scripts/run_lane.sh"
SUMMARIZE="$REPO_ROOT/scripts/summarize_lane_timing.py"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    echo "FAIL run-lane control: $*" >&2
    exit 1
}

# --- a slow lane that PASSES is still visible ------------------------------
timing="$work/slow"
TAKIBI_LANE_TIMING_DIR="$timing" bash "$RUN_LANE" slowpoke sleep 1 >/dev/null \
    || fail "a passing slow lane exited nonzero"
TAKIBI_LANE_TIMING_DIR="$timing" bash "$RUN_LANE" quick true >/dev/null \
    || fail "a passing quick lane exited nonzero"
[ -f "$timing/slowpoke.jsonl" ] || fail "no record for the slow lane"
python3 - "$timing/slowpoke.jsonl" <<'PY' || fail "the slow lane's record does not show its duration"
import json, sys
record = json.loads(open(sys.argv[1]).read().strip())
assert record["status"] == 0, record
assert record["elapsed"] >= 0.9, record
PY
summary="$(python3 "$SUMMARIZE" "$timing")" || fail "the summary of two good lanes failed"
grep -q "longest:.*slowpoke" <<<"$summary" \
    || fail "the summary did not name the slow lane as longest: $summary"

# --- a FAILING lane keeps both its status and its record -------------------
timing="$work/failing"
TAKIBI_LANE_TIMING_DIR="$timing" bash "$RUN_LANE" broken false >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] || fail "a failing lane exited 0, so allcheck would pass"
[ -f "$timing/broken.jsonl" ] \
    || fail "a failing lane left no record at all, which is the run worth measuring"
python3 - "$timing/broken.jsonl" <<'PY' || fail "a failing lane's record does not carry its status"
import json, sys
record = json.loads(open(sys.argv[1]).read().strip())
assert record["status"] != 0, record
PY
python3 "$SUMMARIZE" "$timing" | grep -q "FAILED" \
    || fail "the summary does not mark the failing lane"

# --- a lane run by hand, with no timing configured, is unaffected ----------
out="$(env -u TAKIBI_LANE_TIMING_DIR bash "$RUN_LANE" plain true)" \
    || fail "an unmeasured lane exited nonzero"
[ "$out" = "PASS plain: every step passed" ] \
    || fail "an unmeasured lane changed its receipt: $out"

# --- begin/end, and a lane that begins and never ends ----------------------
timing="$work/stamps"
export TAKIBI_LANE_TIMING_DIR="$timing"
bash "$REPO_ROOT/scripts/lane_timing.sh" begin finished
bash "$REPO_ROOT/scripts/lane_timing.sh" end finished 0
bash "$REPO_ROOT/scripts/lane_timing.sh" begin abandoned
unset TAKIBI_LANE_TIMING_DIR
[ -f "$timing/finished.jsonl" ] || fail "begin/end left no record"
[ -f "$timing/abandoned.start" ] || fail "begin left no stamp"
summary="$(python3 "$SUMMARIZE" "$timing")" || fail "the stamp summary failed"
grep -q "abandoned.*did not finish" <<<"$summary" \
    || fail "a lane that never finished was dropped instead of reported: $summary"

# --- a run that recorded NOTHING is not a run where everything was instant --
# Required to REFUSE, and to say why: a crash would also exit nonzero, and a
# traceback is not a diagnostic a reader of a red allcheck can act on.
mkdir -p "$work/empty"
empty_out="$(python3 "$SUMMARIZE" "$work/empty" 2>&1)" \
    && fail "an empty timing directory produced a summary: $empty_out"
grep -q "ERROR lane-timing:" <<<"$empty_out" \
    || fail "an empty run was not refused with a diagnostic: $empty_out"
grep -q "Traceback" <<<"$empty_out" \
    && fail "an empty run crashed instead of being refused: $empty_out"

# --- LONGEST and TAIL are different questions ------------------------------
# Two long lanes running side by side and one short lane that starts late and
# finishes last. Shortening `marathon` would save nothing; shortening
# `straggler` would save the run four seconds, and only TAIL says so.
timing="$work/tail"
mkdir -p "$timing"
cat >"$timing/marathon.jsonl" <<'JSON'
{"lane":"marathon","start":1000.000,"finish":1030.000,"elapsed":30.000,"status":0}
JSON
cat >"$timing/twin.jsonl" <<'JSON'
{"lane":"twin","start":1000.000,"finish":1029.000,"elapsed":29.000,"status":0}
JSON
cat >"$timing/straggler.jsonl" <<'JSON'
{"lane":"straggler","start":1029.500,"finish":1034.000,"elapsed":4.500,"status":0}
JSON
summary="$(python3 "$SUMMARIZE" "$timing")" || fail "the tail summary failed"
grep -q "longest: *30.0s  marathon" <<<"$summary" \
    || fail "longest is not marathon: $summary"
grep -q "tail: *4.0s  straggler" <<<"$summary" \
    || fail "tail is not 4.0s of straggler: $summary"
grep -q "span: *34.0s" <<<"$summary" || fail "span is not 34.0s: $summary"

echo "PASS run-lane controls: a slow passing lane is visible, a failing lane "\
"keeps its status and record, an unmeasured lane is unchanged, a lane that "\
"never finished is reported, an empty run is refused, and longest and tail "\
"name different lanes"
