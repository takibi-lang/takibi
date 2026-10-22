#!/usr/bin/env bash
# Controls for the passing-lane archive check (GitHub issue #883).
#
# scripts/run_lane.sh refuses a passing lane that left a failure archive
# (scripts/lane_new_archives.py), unless the archive names why it is
# expected. Each direction is planted through the real wrapper and the real
# archiver: a child meant to fail that archives anyway (the #877 shape), an
# expected archive, a neighbour lane's archive made during this run, an
# archive nested one level down, and a failing lane whose status must
# survive. Then the race-window runner's marking: its reverted kernel is
# expected to archive, its armed kernel never is.
#
# Slow lane, not langcheck: it waits on run_lane.sh and its children.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LANE="$REPO_ROOT/scripts/run_lane.sh"
ARCHIVER="$REPO_ROOT/scripts/archive_kernel_failure.sh"
RACE="$REPO_ROOT/scripts/run_kernel_race_window_qemutest.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# GitHub issue #526: a control asserts the number of claims it made.
cases=0
claim() { cases=$((cases + 1)); }
fail() {
    echo "FAIL lane-new-archives control: $*" >&2
    exit 1
}

mkdir -p "$work/capture"
printf 'uart\n' >"$work/capture/uart.log"
export TAKIBI_LANE_ARTIFACT_ROOT="$work/root"
unset TAKIBI_LANE_TIMING_DIR TAKIBI_ARCHIVE_EXPECTED TAKIBI_LANE_RUN_ID

# run CASE COMMAND...: run_lane.sh with a fake lane body; output in $work/CASE.out.
run() {
    local name="$1"
    shift
    bash "$RUN_LANE" "control-$name" "$@" >"$work/$name.out" 2>&1
}

# A lane body that archives through the real archiver and still passes.
archive_and_pass() {
    printf 'bash %q %q %q x; exit 0' "$ARCHIVER" "$work/capture" "$1"
}

# 1. A clean passing lane passes.
run clean true && claim || fail "a clean passing lane was refused: $(cat "$work/clean.out")"

# 2. A passing lane whose child archived (meant to fail, archived anyway).
if run stray bash -c "$(archive_and_pass "$TAKIBI_LANE_ARTIFACT_ROOT/kernel-x-failures")"; then
    fail "a passing lane that left a failure archive was accepted"
fi
claim
grep -q "kernel-x-failures/" "$work/stray.out" && claim ||
    fail "the refusal does not name the archive: $(cat "$work/stray.out")"
grep -q "^FAIL control-stray:" "$work/stray.out" && claim ||
    fail "the lane receipt does not say FAIL"

# 3. Nested one level under the root (a repeated lane's sample directory).
if run nested bash -c "$(archive_and_pass "$TAKIBI_LANE_ARTIFACT_ROOT/sample-1/kernel-y-failures")"; then
    fail "a nested failure archive was missed"
fi
claim

# 4. An archive the lane makes on purpose, with its reason.
run expected env TAKIBI_ARCHIVE_EXPECTED="reverted control (#665)" \
    bash -c "$(archive_and_pass "$TAKIBI_LANE_ARTIFACT_ROOT/kernel-z-failures")" && claim ||
    fail "an expected archive was refused: $(cat "$work/expected.out")"
grep -q "^NOTE control-expected.*reverted control (#665)" "$work/expected.out" && claim ||
    fail "an expected archive was not listed"

# 5. A neighbour lane's archive, made while this lane ran, is not this lane's.
run neighbour env TAKIBI_LANE_RUN_ID=other-lane:1:1 \
    bash -c "$(archive_and_pass "$TAKIBI_LANE_ARTIFACT_ROOT/kernel-n-failures")" && claim ||
    fail "a neighbour lane's archive was blamed on this lane: $(cat "$work/neighbour.out")"

# 6. A failing lane keeps its own status.
run failing bash -c "bash '$ARCHIVER' '$work/capture' '$TAKIBI_LANE_ARTIFACT_ROOT/kernel-f-failures' x; exit 3"
[ "$?" -eq 3 ] && claim || fail "a failing lane's exit status was not preserved"

# 7. The archiver records the run id and the expectation.
manifest="$(find "$TAKIBI_LANE_ARTIFACT_ROOT/kernel-z-failures" -name MANIFEST | head -1)"
grep -q "^lane-run: control-expected:" "$manifest" && claim || fail "MANIFEST lacks lane-run"
grep -q "^expected: reverted control (#665)$" "$manifest" && claim || fail "MANIFEST lacks expected"

# 8. The race-window runner marks its reverted kernel expected and never its
# armed kernel; both variants pass the marking to their runner.
fn="$(sed -n '/^expected_archive() {$/,/^}$/p' "$RACE")"
[ -n "$fn" ] && claim || fail "race-window runner has no expected_archive"
eval "$fn"
WINDOW=609
[ "$(expected_archive armed)" = no ] && claim || fail "the armed race-window kernel is marked expected"
r="$(expected_archive reverted)"
[ -n "$r" ] && [ "$r" != no ] && claim || fail "the reverted race-window kernel is not marked expected"
[ "$(grep -c 'TAKIBI_ARCHIVE_EXPECTED="$(expected_archive "$variant")"' "$RACE")" -eq 2 ] && claim ||
    fail "a race-window workload does not pass the marking to its runner"

# 9. Every other child a lane runs meaning it to fail is marked too: the
# probe-refusals old resume baseline (it archives through its own EXIT trap).
# The debug-return-abi counterfactuals and the uart-wake scalar control do not
# archive at all (#877).
PROBE="$REPO_ROOT/scripts/run_kernel_probe_refusals_qemutest.sh"
grep -B1 -A3 'TAKIBI_ARCHIVE_EXPECTED=' "$PROBE" | grep -q 'old-baseline' && claim ||
    fail "the probe-refusals old-baseline child is not marked expected"

echo "PASS lane-new-archives control: $cases claims -- a passing lane that left an unexpected failure archive is refused; expected, neighbour and failing runs are not"
