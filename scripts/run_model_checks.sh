#!/usr/bin/env bash
# Check every TLA+ model under kernel/models/ (GitHub issue #601): `make
# modelcheck`, a lane of allcheck and cicheck.
#
# For each model, the fixed variant must pass and every unfixed variant must
# FAIL for its stated reason -- a model that stopped finding the defect it
# was written for would otherwise go quietly green. Each model is checked
# three ways:
#
#   1. TLC over the whole state space: safety invariants and liveness.
#   2. `apalache-mc typecheck`: the type annotations are consistent.
#   3. A shallow `apalache-mc check` of every variant: Apalache can really run
#      the spec and agrees about the defect, which a typecheck alone does not
#      show. Liveness is TLC's alone.
#
# The tools come from scripts/fetch_model_tools.sh, which downloads them
# once, outside the repository.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$(bash "$REPO_ROOT/scripts/fetch_model_tools.sh")"
TLA_JAR="$TOOLS/tla2tools-1.7.4/tla2tools.jar"
APALACHE="$TOOLS/apalache-0.62.2/bin/apalache-mc"
OUT="$REPO_ROOT/_build/models"
MODELS="$REPO_ROOT/kernel/models"
mkdir -p "$OUT"

failures=0
fail() { echo "FAIL modelcheck: $*"; failures=$((failures + 1)); }

# tlc <model> <variant>: run TLC, keep the log, print it on failure.
tlc() {
    local log="$OUT/$1-$2.tlc.log"
    (cd "$MODELS" && java -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC \
        -workers auto -config "$1_$2.cfg" -metadir "$OUT/$1-$2.states" \
        "$1.tla") >"$log" 2>&1 || true
    echo "$log"
}

# apalache <model> <cinit> <invariant> <length>: a shallow check.
apalache() {
    local log="$OUT/$1-$2.apalache.log"
    (cd "$MODELS" && "$APALACHE" check --out-dir="$OUT/apalache" \
        --cinit="$2" --init=Init --next=Next --inv="$3" --length="$4" \
        "$1.tla") >"$log" 2>&1 || true
    echo "$log"
}

# check_model <model> <apalache invariant> <apalache length> <variant>...
# Each variant is "<cfg suffix>:<CInit operator>:<TLC expectation>:<Apalache
# expectation>". A TLC expectation is "pass", "deadlock", or the name of the
# invariant that must be reported violated. An Apalache expectation is "ok"
# or "violated". Apalache reports a deadlock only when every run of some
# length is stuck, so a deadlock that one branch reaches is TLC's to find;
# such a variant expects "ok" from Apalache, which then shows only that it
# runs.
check_model() {
    local model="$1" invariant="$2" length="$3" before="$failures" log
    shift 3

    log="$OUT/$model.typecheck.log"
    (cd "$MODELS" && "$APALACHE" typecheck --out-dir="$OUT/apalache" \
        "$model.tla") >"$log" 2>&1 || true
    grep -q "Type checker \[OK\]" "$log" ||
        fail "$model: Apalache typecheck failed (see $log)"

    local variant cfg cinit tlc_expect apa_expect
    for variant in "$@"; do
        IFS=: read -r cfg cinit tlc_expect apa_expect <<<"$variant"

        log="$(tlc "$model" "$cfg")"
        case "$tlc_expect" in
            pass) grep -q "Model checking completed. No error has been found." "$log" ||
                      fail "$model $cfg: TLC found an error (see $log)" ;;
            deadlock) grep -q "Error: Deadlock reached." "$log" ||
                      fail "$model $cfg: TLC did not report the deadlock (see $log)" ;;
            *) grep -q "Invariant $tlc_expect is violated." "$log" ||
                   fail "$model $cfg: TLC did not report $tlc_expect (see $log)" ;;
        esac

        log="$(apalache "$model" "$cinit" "$invariant" "$length")"
        case "$apa_expect" in
            ok) grep -q "EXITCODE: OK" "$log" ||
                    fail "$model $cfg: Apalache found an error (see $log)" ;;
            violated) grep -q "EXITCODE: ERROR (12)" "$log" ||
                    fail "$model $cfg: Apalache did not report $invariant (see $log)" ;;
        esac
    done

    [ "$failures" -eq "$before" ] &&
        echo "PASS modelcheck: $model -- $# variant(s) each gave TLC's and Apalache's (length $length) expected verdict, types check"
}

check_model Wait4Block NoLostWakeup 4 \
    fixed:CInitFixed:pass:ok \
    unfixed:CInitUnfixed:NoLostWakeup:violated

check_model StackOwnership RunningMatchesCores 6 \
    fixed:CInitFixed:pass:ok \
    exitwaits:CInitExitWaits:deadlock:ok \
    leaveunchecked:CInitLeaveUnchecked:RunningMatchesCores:violated

check_model RecordLifetime ReadsOnlyLiveRecords 6 \
    fixed:CInitFixed:pass:ok \
    unfixed:CInitUnfixed:ReadsOnlyLiveRecords:violated \
    readerunlocked:CInitReaderUnlocked:ReadsOnlyLiveRecords:violated

[ "$failures" -eq 0 ] || exit 1
