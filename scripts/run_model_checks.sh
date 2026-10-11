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

# Every TLC run, typecheck and Apalache run is independent, so they run at
# once, MODELCHECK_JOBS at a time (default: every core), and are judged when
# all have finished. This is deliberately not TAKIBI_JOBS: that one is 1 on
# CI to keep QEMU lanes from starving each other's guest vCPUs, which says
# nothing about these JVMs -- and on CI no other lane runs beside this one.
JOBS="${MODELCHECK_JOBS:-$(nproc)}"
QUEUE="$OUT/jobs.list"
: >"$QUEUE"
EXPECT="$OUT/expect.list"
: >"$EXPECT"

# Each job is one line: a log path, then the command that writes it. Every
# Apalache run gets its own --out-dir, since concurrent runs sharing one
# would write into each other's.
queue_tlc() {  # model variant
    echo "$OUT/$1-$2.tlc.log bash $REPO_ROOT/scripts/run_tlc.sh -XX:+UseParallelGC -cp $TLA_JAR tlc2.TLC -workers 1 -config $1_$2.cfg -metadir $OUT/$1-$2.states $1.tla" >>"$QUEUE"
}
queue_typecheck() {  # model
    echo "$OUT/$1.typecheck.log $APALACHE typecheck --out-dir=$OUT/apalache/$1-typecheck $1.tla" >>"$QUEUE"
}
queue_apalache() {  # model variant cinit invariant length
    echo "$OUT/$1-$2.apalache.log $APALACHE check --out-dir=$OUT/apalache/$1-$2 --cinit=$3 --init=Init --next=Next --inv=$4 --length=$5 $1.tla" >>"$QUEUE"
}

# check_model <model> <apalache invariant> <apalache length> <variant>...
# Each variant is "<cfg suffix>:<CInit operator>:<TLC expectation>:<Apalache
# expectation>[:<length>]". The optional length overrides the model's for
# that variant alone: a violation that takes more steps needs the longer
# bound, and giving it to every variant makes Apalache's shallow checks the
# slowest thing in allcheck -- StackOwnership at 8 took 77 s a variant and
# slowed every QEMU lane beside it past the network peer's budget.
# A TLC expectation is "pass", "deadlock", or the name of the
# invariant that must be reported violated. An Apalache expectation is "ok"
# or "violated". Apalache reports a deadlock only when every run of some
# length is stuck, so a deadlock that one branch reaches is TLC's to find;
# such a variant expects "ok" from Apalache, which then shows only that it
# runs.
check_model() {
    local model="$1" invariant="$2" length="$3"
    shift 3
    queue_typecheck "$model"
    local variant cfg cinit tlc_expect apa_expect bound
    for variant in "$@"; do
        IFS=: read -r cfg cinit tlc_expect apa_expect bound <<<"$variant"
        bound="${bound:-$length}"
        queue_tlc "$model" "$cfg"
        queue_apalache "$model" "$cfg" "$cinit" "$invariant" "$bound"
        echo "$model $cfg $tlc_expect $apa_expect $invariant $bound" >>"$EXPECT"
    done
}

check_model Wait4Block NoLostWakeup 4 \
    fixed:CInitFixed:pass:ok \
    unfixed:CInitUnfixed:NoLostWakeup:violated

check_model StackOwnership CoreInvariants 6 \
    fixed:CInitFixed:pass:ok \
    exitwaits:CInitExitWaits:deadlock:ok \
    leaveunchecked:CInitLeaveUnchecked:RunningMatchesCores:violated \
    wakestartunchecked:CInitWakeStartUnchecked:StartsOnFreeStack:violated:8

check_model LogReader NoTornRead 10 \
    fixed:CInitFixed:pass:ok \
    unchecked:CInitUnchecked:NoTornRead:violated:13

check_model RecordLifetime RecordInvariants 6 \
    fixed:CInitFixed:pass:ok \
    unfixed:CInitUnfixed:ReadsOnlyLiveRecords:violated \
    readerunlocked:CInitReaderUnlocked:ReadsOnlyLiveRecords:violated \
    execunlocked:CInitExecUnlocked:NoTornRead:violated

check_model ConsoleTx Safety 10 \
    fixed:CInitFixed:pass:ok \
    ring:CInitRing:ProgramOrder:violated \
    norecheck:CInitNoRecheck:NoLostWakeup:violated \
    nested:CInitNested:deadlock:ok

check_model FixedDmaOwnership Safety 5 \
    fixed:CInitFixed:pass:ok \
    unfixed:CInitUnfixed:Safety:violated \
    gemfixed:CInitGemFixed:pass:ok \
    gemtimeout:CInitGemTimeout:Safety:violated \
    gemfailedhalt:CInitGemFailedHalt:Safety:violated \
    gemreuse:CInitGemReuse:Safety:violated:8

check_model SharedRegionTransfer Safety 5 \
    fixed:CInitFixed:pass:ok \
    early:CInitEarly:Safety:violated:3 \
    foreign:CInitForeign:Safety:violated:5 \
    timeout:CInitTimeout:Safety:violated:4 \
    failedreset:CInitFailedReset:Safety:violated:6

check_model WorldStop NoUnstoppedRead 8 \
    fixed:CInitFixed:pass:ok \
    subset:CInitSubset:NoUnstoppedRead:violated \
    ungatedstart:CInitUngatedStart:NoUnstoppedRead:violated:10

# Run. A job's own exit status is not the verdict -- an unfixed variant is
# SUPPOSED to fail -- so every job is allowed to fail here and judged below.
(cd "$MODELS" && xargs -P "$JOBS" -L 1 sh -c 'log="$0"; "$@" >"$log" 2>&1 || true' <"$QUEUE")

failures=0
fail() { echo "FAIL modelcheck: $*"; failures=$((failures + 1)); }

for model in $(cut -d' ' -f1 "$EXPECT" | uniq); do
    grep -q "Type checker \[OK\]" "$OUT/$model.typecheck.log" ||
        fail "$model: Apalache typecheck failed (see $OUT/$model.typecheck.log)"
done

declare -A variants shortest longest
while read -r model cfg tlc_expect apa_expect invariant length; do
    variants[$model]=$(( ${variants[$model]:-0} + 1 ))
    if [ -z "${shortest[$model]:-}" ] || [ "$length" -lt "${shortest[$model]}" ]; then
        shortest[$model]=$length
    fi
    if [ -z "${longest[$model]:-}" ] || [ "$length" -gt "${longest[$model]}" ]; then
        longest[$model]=$length
    fi
    log="$OUT/$model-$cfg.tlc.log"
    case "$tlc_expect" in
        pass) grep -q "Model checking completed. No error has been found." "$log" ||
                  fail "$model $cfg: TLC found an error (see $log)" ;;
        deadlock) grep -q "Error: Deadlock reached." "$log" ||
                  fail "$model $cfg: TLC did not report the deadlock (see $log)" ;;
        *) grep -q "Invariant $tlc_expect is violated." "$log" ||
               fail "$model $cfg: TLC did not report $tlc_expect (see $log)" ;;
    esac
    log="$OUT/$model-$cfg.apalache.log"
    case "$apa_expect" in
        ok) grep -q "EXITCODE: OK" "$log" ||
                fail "$model $cfg: Apalache found an error (see $log)" ;;
        violated) grep -q "EXITCODE: ERROR (12)" "$log" ||
                fail "$model $cfg: Apalache did not report $invariant (see $log)" ;;
    esac
done <"$EXPECT"

[ "$failures" -eq 0 ] || exit 1
for model in $(cut -d' ' -f1 "$EXPECT" | uniq); do
    bounds=${shortest[$model]}
    [ "${longest[$model]}" = "$bounds" ] || bounds="$bounds-${longest[$model]}"
    echo "PASS modelcheck: $model -- ${variants[$model]} variant(s) each gave TLC's and Apalache's (length $bounds) expected verdict, types check"
done
