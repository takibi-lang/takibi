#!/usr/bin/env bash
# Controls for the shared board-link gate.
#
# The gate exists to turn "the board was not up yet" into a different verdict
# from "the protocol is broken", so the cases worth planting are the ones a
# healthy run never produces: a link that arrives late, a bring-up the target
# reports as failed, and a target that says nothing at all. The third is the
# one the wording matters for -- it is the run that used to be reported as an
# ARP or an HTTP defect (GitHub issue #387).
#
# No board: the gate reads a log file, so the log is written by hand.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/board_link_gate.sh"

READY="net_echo: ready"
FAILED="net_echo: device/link not found"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# GitHub issue #526: a control asserts the number of claims it made. A PASS
# that names zero of them is a run that checked nothing, which is the same
# silence scripts/pass_line.py refuses on the Python side.
cases=0
claim() { cases=$((cases + 1)); }

fail() {
    echo "FAIL board-link-gate control: $*" >&2
    exit 1
}

# --- a link that is already up returns at once ----------------------------
log="$work/ready.log"
printf 'net_echo: init\r\nnet_echo: ready\r\n' >"$log"
reason="$(board_link_gate "$log" "$READY" "$FAILED" 100)" \
    && claim || fail "a log that already holds the ready line was not accepted"
grep -q "^link ready " <<<"$reason" \
    && claim || fail "a ready link did not report how long it took: $reason"

# --- a link that arrives LATE is waited for, not missed --------------------
log="$work/late.log"
printf 'net_echo: init\r\n' >"$log"
( sleep 0.6; printf 'net_echo: ready\r\n' >>"$log" ) &
writer=$!
reason="$(board_link_gate "$log" "$READY" "$FAILED" 100)" \
    && claim || fail "a link that arrived after 0.6s was not waited for"
wait "$writer"
grep -q "^link ready " <<<"$reason" && claim || fail "late ready reported oddly: $reason"

# --- a bring-up the target says FAILED is answered immediately -------------
log="$work/failed.log"
printf 'net_echo: init\r\nnet_echo: device/link not found\r\n' >"$log"
started=$SECONDS
reason="$(board_link_gate "$log" "$READY" "$FAILED" 300)" \
    && fail "a reported bring-up failure was treated as a working link"
[ $((SECONDS - started)) -le 5 ] \
    && claim || fail "a reported failure spent the whole window being discovered"
grep -q "the target reported" <<<"$reason" \
    && claim || fail "a reported failure was not named: $reason"

# --- a target that says NOTHING is the case the wording is for -------------
log="$work/silent.log"
: >"$log"
reason="$(board_link_gate "$log" "$READY" "$FAILED" 3)" \
    && fail "a silent target was treated as a working link"
grep -q "never printed" <<<"$reason" && claim || fail "a silent target: $reason"
grep -q "NOT a defect in the tests that follow" <<<"$reason" \
    && claim || fail "a silent target's reason does not say the tests below are not at fault: $reason"

# --- a missing log is silence, not a crash --------------------------------
reason="$(board_link_gate "$work/no-such.log" "$READY" "$FAILED" 2)" \
    && fail "a missing log was treated as a working link"
grep -q "never printed" <<<"$reason" && claim || fail "a missing log: $reason"

echo "PASS board-link-gate controls: $cases claims -- a ready link reports its wait, a late "\
"one is waited for, a reported bring-up failure is answered at once and "\
"named, and a silent or missing log says the board never linked rather than "\
"blaming the tests that follow"
