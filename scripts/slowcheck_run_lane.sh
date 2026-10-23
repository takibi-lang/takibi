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

# GitHub issue #526: a control asserts the number of claims it made. A PASS
# that names zero of them is a run that checked nothing, which is the same
# silence scripts/pass_line.py refuses on the Python side.
cases=0
claim() { cases=$((cases + 1)); }

fail() {
    echo "FAIL run-lane control: $*" >&2
    exit 1
}

# --- a slow lane that PASSES is still visible ------------------------------
timing="$work/slow"
TAKIBI_LANE_TIMING_DIR="$timing" bash "$RUN_LANE" slowpoke sleep 1 >/dev/null \
    && claim || fail "a passing slow lane exited nonzero"
TAKIBI_LANE_TIMING_DIR="$timing" bash "$RUN_LANE" quick true >/dev/null \
    && claim || fail "a passing quick lane exited nonzero"
[ -f "$timing/slowpoke.jsonl" ] && claim || fail "no record for the slow lane"
python3 - "$timing/slowpoke.jsonl" <<'PY' && claim || fail "the slow lane's record does not show its duration"
import json, sys
record = json.loads(open(sys.argv[1]).read().strip())
assert record["status"] == 0, record
assert record["elapsed"] >= 0.9, record
PY
summary="$(python3 "$SUMMARIZE" "$timing")" && claim || fail "the summary of two good lanes failed"
grep -q "longest:.*slowpoke" <<<"$summary" \
    && claim || fail "the summary did not name the slow lane as longest: $summary"

# --- a FAILING lane keeps both its status and its record -------------------
timing="$work/failing"
TAKIBI_LANE_TIMING_DIR="$timing" bash "$RUN_LANE" broken false >/dev/null 2>&1
status=$?
[ "$status" -ne 0 ] && claim || fail "a failing lane exited 0, so allcheck would pass"
[ -f "$timing/broken.jsonl" ] \
    && claim || fail "a failing lane left no record at all, which is the run worth measuring"
python3 - "$timing/broken.jsonl" <<'PY' && claim || fail "a failing lane's record does not carry its status"
import json, sys
record = json.loads(open(sys.argv[1]).read().strip())
assert record["status"] != 0, record
PY
python3 "$SUMMARIZE" "$timing" | grep -q "FAILED" \
    && claim || fail "the summary does not mark the failing lane"

# --- a lane run by hand, with no timing configured, is unaffected ----------
out="$(env -u TAKIBI_LANE_TIMING_DIR bash "$RUN_LANE" plain true)" \
    && claim || fail "an unmeasured lane exited nonzero"
[ "$out" = "PASS plain: every step passed" ] \
    && claim || fail "an unmeasured lane changed its receipt: $out"

# --- begin/end, and a lane that begins and never ends ----------------------
timing="$work/stamps"
export TAKIBI_LANE_TIMING_DIR="$timing"
bash "$REPO_ROOT/scripts/lane_timing.sh" begin finished
bash "$REPO_ROOT/scripts/lane_timing.sh" end finished 0
bash "$REPO_ROOT/scripts/lane_timing.sh" begin abandoned
unset TAKIBI_LANE_TIMING_DIR
[ -f "$timing/finished.jsonl" ] && claim || fail "begin/end left no record"
[ -f "$timing/abandoned.start" ] && claim || fail "begin left no stamp"
summary="$(python3 "$SUMMARIZE" "$timing")" && claim || fail "the stamp summary failed"
grep -q "abandoned.*did not finish" <<<"$summary" \
    && claim || fail "a lane that never finished was dropped instead of reported: $summary"

# --- a run that recorded NOTHING is not a run where everything was instant --
# Required to REFUSE, and to say why: a crash would also exit nonzero, and a
# traceback is not a diagnostic a reader of a red allcheck can act on.
mkdir -p "$work/empty"
empty_out="$(python3 "$SUMMARIZE" "$work/empty" 2>&1)" \
    && fail "an empty timing directory produced a summary: $empty_out"
grep -q "ERROR lane-timing:" <<<"$empty_out" \
    && claim || fail "an empty run was not refused with a diagnostic: $empty_out"
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
summary="$(python3 "$SUMMARIZE" "$timing")" && claim || fail "the tail summary failed"
grep -q "longest: *30.0s  marathon" <<<"$summary" \
    && claim || fail "longest is not marathon: $summary"
grep -q "tail: *4.0s  straggler" <<<"$summary" \
    && claim || fail "tail is not 4.0s of straggler: $summary"
grep -q "span: *34.0s" <<<"$summary" && claim || fail "span is not 34.0s: $summary"

# --- PRE-LANE: the time before the first receipt (GitHub issue #820) ------
grep -q "pre-lane" <<<"$summary" \
    && fail "a run with no origin stamp reported a pre-lane time: $summary"
claim
TAKIBI_LANE_TIMING_DIR="$timing" bash "$REPO_ROOT/scripts/lane_timing.sh" origin 990.000
TAKIBI_LANE_TIMING_DIR="$timing" bash "$REPO_ROOT/scripts/lane_timing.sh" origin 995.000
summary="$(python3 "$SUMMARIZE" "$timing")" && claim || fail "the origin summary failed"
grep -q "pre-lane: *10.0s .*(marathon)" <<<"$summary" \
    && claim || fail "pre-lane is not 10.0s before marathon (or a second origin moved it): $summary"
grep -q "did not finish" <<<"$summary" \
    && fail "the origin stamp was reported as an unfinished lane: $summary"
claim

# --- vCPU lease waits are recorded and summarized (GitHub issue #914) -----
# A real acquire against a private registry: a holder takes the whole budget
# of 2 and keeps it until this test says release, and a lane named `racer`
# must wait for it. The wait must reach the lane-timing directory and the
# summary, per lane and in total; without the record, the minute a race-window
# lane spends here is indistinguishable from a slow boot.
# No step depends on timing (GitHub issue #928: a fixed 1.2 s hold let a racer
# started late under allcheck load wait only 0.087 s). The holder holds until
# `release` exists; the racer runs in the background; the release comes only
# after the racer has said it is waiting; and the assertion is causal -- the
# wait began before the release and was granted after it -- not a duration.
timing="$work/lease"
registry="$work/registry"
mkdir -p "$timing"
TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_QEMU_VCPU_BUDGET=2 bash -c \
    '. "$1/scripts/vcpu_lease.sh"; resource_lease_vcpu_acquire 2 holder || exit 1
     touch "$2"; until [ -e "$3" ]; do sleep 0.05; done' \
    _ "$REPO_ROOT" "$work/held" "$work/release" &
holder=$!
for _ in $(seq 600); do [ -f "$work/held" ] && break; sleep 0.05; done
[ -f "$work/held" ] && claim || { touch "$work/release"; fail "the holder never took its vCPUs"; }
TAKIBI_SESSION_REGISTRY="$registry" TAKIBI_QEMU_VCPU_BUDGET=2 \
TAKIBI_LANE_TIMING_DIR="$timing" TAKIBI_AWAIT_TIMING_LANE=racer bash -c \
    '. "$1/scripts/vcpu_lease.sh"; resource_lease_vcpu_acquire 2 racer-target' \
    _ "$REPO_ROOT" 2>"$work/racer.log" &
racer=$!
for _ in $(seq 600); do grep -q "waiting for 2 more of 2 vCPUs" "$work/racer.log" && break; sleep 0.05; done
grep -q "waiting for 2 more of 2 vCPUs" "$work/racer.log" \
    && claim || { touch "$work/release"; fail "the racer never waited: $(cat "$work/racer.log")"; }
[ ! -e "$timing/vcpu-lease.waits" ] \
    && claim || { touch "$work/release"; fail "the racer was granted while the holder held the budget"; }
released="$(date +%s.%3N)"
touch "$work/release"
wait "$racer" && claim || fail "the waiting acquire failed"
wait "$holder"
python3 - "$timing/vcpu-lease.waits" "$released" <<'PY' && claim || fail "the lease wait was not recorded around the release"
import json, sys
wait = json.loads(open(sys.argv[1]).read().strip())
released = float(sys.argv[2])
assert wait["lane"] == "racer" and wait["vcpus"] == 2, wait
assert wait["wait_start"] <= released <= wait["granted"], (wait, released)
PY
TAKIBI_LANE_TIMING_DIR="$timing" bash "$REPO_ROOT/scripts/lane_timing.sh" record racer 1000.000 0
cat >>"$timing/vcpu-lease.waits" <<'JSON'
{"lane":"other","vcpus":4,"wait_start":10.0,"granted":13.0}
{"lane":"other","vcpus":4,"wait_start":20.0,"granted":22.0}
{"lane":"stuck","vcpus":4,"wait_start":30.0,"granted":null}
JSON
summary="$(python3 "$SUMMARIZE" "$timing")" && claim || fail "the lease summary failed"
grep -q "^  other  *5.0s  over 2 lease(s)" <<<"$summary" \
    && claim || fail "two waits of one lane were not summed to 5.0s: $summary"
grep -q "^  racer  *[0-9.]*s  over 1 lease(s)" <<<"$summary" \
    && claim || fail "the measured wait was not reported per lane: $summary"
grep -q "stuck.*timed out waiting" <<<"$summary" \
    && claim || fail "a wait that never got its slots was dropped: $summary"
grep -q "^lease wait: *[0-9.]*s  summed over 2 lane(s), 1 timed out" <<<"$summary" \
    && claim || fail "the total lease wait is missing: $summary"
grep -q "Traceback\|did not finish" <<<"$summary" \
    && fail "the lease log was read as a lane: $summary"
claim

# --- concurrent checks overlap, keep their output whole, report failures ---
CONCURRENT="$REPO_ROOT/scripts/run_concurrent_checks.sh"
timing="$work/concurrent"
# Overlap is proven by a rendezvous, not a duration (GitHub issue #928: on a
# starved CPU two 1 s sleeps that did overlap took 2 s). Each check marks
# itself started and waits for the other's mark; run serially, the first
# would wait out its 60 s bound and fail.
meet="$work/meet"
mkdir -p "$meet"
rendezvous='touch "$1/$2"; for _ in $(seq 1200); do [ -e "$1/$3" ] && exit 0; sleep 0.05; done; exit 1'
out="$(TAKIBI_LANE_TIMING_DIR="$timing" bash "$CONCURRENT" \
    one "echo one-a; bash -c '$rendezvous' _ '$meet' one two && echo one-b" \
    two "bash -c '$rendezvous' _ '$meet' two one && echo two")" \
    && claim || fail "two concurrent checks that wait for each other did not both finish, so they ran serially: $out"
[ "$out" = "$(printf 'one-a\none-b\ntwo')" ] \
    && claim || fail "concurrent output was not printed whole in argument order: $out"
[ -f "$timing/one.jsonl" ] && [ -f "$timing/two.jsonl" ] \
    && claim || fail "a concurrent check left no lane-timing record"
out="$(bash "$CONCURRENT" good true bad 'exit 3' 2>&1)"
status=$?
[ "$status" -eq 3 ] && claim || fail "a failing concurrent check gave exit $status, not 3"
grep -q "FAIL concurrent checks: bad (exit 3)" <<<"$out" \
    && claim || fail "the failing concurrent check was not named: $out"

echo "PASS run-lane controls: $cases claims -- a slow passing lane is visible, a failing lane "\
"keeps its status and record, an unmeasured lane is unchanged, a lane that "\
"never finished is reported, an empty run is refused, and longest and tail "\
"name different lanes, pre-lane time is reported from the origin stamp, "\
"concurrent checks overlap and report whole, and vCPU lease waits are "\
"recorded and summed per lane and in total"
