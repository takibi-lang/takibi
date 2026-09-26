#!/usr/bin/env bash
# Check every TLA+ model under kernel/models/ (GitHub issue #601): `make
# modelcheck`. Not part of `make allcheck` yet.
#
# For each model, the fixed variant must pass and the unfixed variant must
# FAIL for its stated reason -- a model that stopped finding the defect it
# was written for would otherwise go quietly green. Each model is checked
# three ways:
#
#   1. TLC over the whole state space: safety invariants and liveness.
#   2. `apalache-mc typecheck`: the type annotations are consistent.
#   3. A shallow `apalache-mc check` of both variants: Apalache can really run
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

check_model() {  # <model> <invariant the unfixed variant must violate>
    local model="$1" defect="$2" log

    log="$(tlc "$model" fixed)"
    grep -q "Model checking completed. No error has been found." "$log" ||
        fail "$model fixed: TLC found an error (see $log)"

    log="$(tlc "$model" unfixed)"
    grep -q "Invariant $defect is violated." "$log" ||
        fail "$model unfixed: TLC did not report $defect (see $log)"

    log="$OUT/$model.typecheck.log"
    (cd "$MODELS" && "$APALACHE" typecheck --out-dir="$OUT/apalache" \
        "$model.tla") >"$log" 2>&1 || true
    grep -q "Type checker \[OK\]" "$log" ||
        fail "$model: Apalache typecheck failed (see $log)"

    log="$(apalache "$model" CInitFixed "$defect" 4)"
    grep -q "EXITCODE: OK" "$log" ||
        fail "$model fixed: Apalache found an error (see $log)"

    log="$(apalache "$model" CInitUnfixed "$defect" 4)"
    grep -q "EXITCODE: ERROR (12)" "$log" ||
        fail "$model unfixed: Apalache did not report $defect (see $log)"

    [ "$failures" -eq 0 ] && echo "PASS modelcheck: $model -- fixed variant holds (TLC, Apalache length 4), unfixed variant violates $defect in both, types check"
}

check_model Wait4Block NoLostWakeup

[ "$failures" -eq 0 ] || exit 1
