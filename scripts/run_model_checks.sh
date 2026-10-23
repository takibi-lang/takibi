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
#   4. Coverage (GitHub issue #802): a variant TLC explored completely must
#      have taken every action of its spec, or allow-listed the dead one in
#      kernel/models/coverage_allow.txt with a reason
#      (scripts/model_coverage.py). Apalache's runs are not judged for it.
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
# Models generated from Takibi protocol declarations (GitHub issue #720):
# `takibi --emit-tla` writes them here, never into the source tree.
GEN="$OUT/generated"
mkdir -p "$GEN"
# A declaration removed from the tree must not leave its old model behind.
find "$GEN" -maxdepth 1 -type f -delete
TAKIBI="${TAKIBI:-$REPO_ROOT/_build/default/bin/main.exe}"
# The directory the next check_model call's .tla/.cfg files live in.
MDIR="$MODELS"

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
    echo "$OUT/$1-$2.tlc.log bash $REPO_ROOT/scripts/run_tlc.sh -XX:+UseParallelGC -cp $TLA_JAR tlc2.TLC -workers 1 -coverage 1 -config $MDIR/$1_$2.cfg -metadir $OUT/$1-$2.states $MDIR/$1.tla" >>"$QUEUE"
}
queue_typecheck() {  # model
    echo "$OUT/$1.typecheck.log $APALACHE typecheck --out-dir=$OUT/apalache/$1-typecheck $MDIR/$1.tla" >>"$QUEUE"
}
queue_apalache() {  # model variant cinit invariant length
    echo "$OUT/$1-$2.apalache.log $APALACHE check --out-dir=$OUT/apalache/$1-$2 --cinit=$3 --init=Init --next=Next --inv=$4 --length=$5 $MDIR/$1.tla" >>"$QUEUE"
}

# check_model <model> <apalache invariant> <apalache length> <variant>...
# Each variant is "<cfg suffix>:<CInit operator>:<TLC expectation>:<Apalache
# expectation>[:<length>]". The optional length overrides the model's for
# that variant alone: a violation that takes more steps needs the longer
# bound, and giving it to every variant makes Apalache's shallow checks the
# slowest thing in allcheck -- StackOwnership at 8 took 77 s a variant and
# slowed every QEMU lane beside it past the network peer's budget.
# A TLC expectation is "pass", "deadlock", "temporal" (a liveness property
# violated; TLC does not name it, so such a variant's .cfg lists exactly the
# one PROPERTY it must lose), or the name of the invariant that must be
# reported violated. An Apalache expectation is "ok"
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

check_model Wait4Block Safety 4 \
    fixed:CInitFixed:pass:ok \
    unfixed:CInitUnfixed:NoLostWakeup:violated \
    sigunfixed:CInitSigUnfixed:NoSleepWithSignal:violated \
    irqunfixed:CInitIrqUnfixed:temporal:ok \
    svcunfixed:CInitSvcUnfixed:SignalWakeEndsWait:violated:8

check_model StackOwnership CoreInvariants 6 \
    fixed:CInitFixed:pass:ok \
    other:CInitOther:pass:ok \
    exitwaits:CInitExitWaits:deadlock:ok \
    leaveunchecked:CInitLeaveUnchecked:RunningMatchesCores:violated \
    wakestartunchecked:CInitWakeStartUnchecked:StartsOnFreeStack:violated:8

# GitHub issue #613: the multi-writer log ring, option B with records of up
# to two slots; kernel/printk/log.tkb implements it (slice 4). The bound
# (writers, slots, K = 2, sequences below 6) is stated in LogRing.tla and the
# README. Shallow for Apalache: the fixed run at length 6 took 8 minutes;
# TLC covers the whole state space. The aba (13 steps), contnoseq (20) and
# silentrefuse (10) violations are TLC's to find; Apalache's short run of
# those shows only that they run. fixed2 is exactprev's own bound with the
# corrected claim rule.
check_model LogRing Safety 7 \
    fixed:CInitFixed:pass:ok:3 \
    fixed4:CInitFixed4:pass:ok:3 \
    fixed2:CInitFixed2:pass:ok:3 \
    aba:CInitAba:NoTornRead:ok:3 \
    trustreserved:CInitTrustReserved:NoTornRead:violated \
    noprev:CInitNoPrev:NoDoubleOwner:violated \
    contnoseq:CInitContNoSeq:NoTornRead:ok:3 \
    silentrefuse:CInitSilentRefuse:NoSilentLoss:ok:3 \
    exactprev:CInitExactPrev:NoNeedlessRefusal:violated

# GitHub issue #829: per-CPU tick-wake lists. Liveness is TLC's; the
# core0only variant loses PeerSleeperWakes, which Apalache does not check,
# so its shallow run shows only that it runs.
check_model TickWake ListsMatchBlocked 6 \
    fixed:CInitFixed:pass:ok \
    core0only:CInitCore0Only:temporal:ok \
    nounlink:CInitNoUnlink:ListsMatchBlocked:violated

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

check_model ConsoleOwner Safety 8 \
    fixed:CInitFixed:pass:ok \
    blind:CInitBlind:TerminalStays:violated \
    nosticky:CInitNoSticky:TerminalStays:violated

# GitHub issue #925: the UART serve try-lock under 1-of-N delivery. Quiesces
# is TLC's; the edge variant also loses NoStranded, which Apalache checks.
check_model UartServe Safety 8 \
    fixed:CInitFixed:pass:ok \
    gated:CInitGated:pass:ok \
    edge:CInitEdge:NoStranded:violated

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

check_model DmaCacheVisibility Safety 8 \
    fixed:CInitFixed:pass:ok \
    noprepare:CInitNoPrepare:DeviceDataKept:violated:5 \
    nofinish:CInitNoFinish:ReadsCurrent:violated:9 \
    earlyinvalidate:CInitEarlyInvalidate:ReadsCurrent:violated:10 \
    lateread:CInitLateRead:ReadsCurrent:violated:9 \
    localinvalidate:CInitLocalInvalidate:DeviceDataKept:violated:7 \
    unpublished:CInitUnpublished:DeviceDataKept:violated:5

check_model DmaTxReadBorrow Safety 7 \
    fixed:CInitFixed:pass:ok \
    writewhileposted:CInitWriteWhilePosted:DeviceReadsPosted:violated \
    noclean:CInitNoClean:DeviceReadsPosted:violated:4

check_model PacketReserve Safety 8 \
    fixed:CInitFixed:pass:ok \
    gem:CInitGem:pass:ok \
    reserved:CInitReserveD:TxNeverStarves:violated \
    noreserve:CInitNoReserve:RingNeverDrains:violated

# Shallow for Apalache: the per-slot cardinalities make each step costly
# (length 8 took over an hour); TLC covers the whole state space.
check_model PacketReserveScan Safety 3 \
    fixed:CInitFixed:pass:ok \
    gem:CInitGem:pass:ok \
    skipempty:CInitSkipEmpty:ScanNeverLow:violated:6

check_model WorldStop NoUnstoppedRead 8 \
    fixed:CInitFixed:pass:ok \
    subset:CInitSubset:NoUnstoppedRead:violated \
    ungatedstart:CInitUngatedStart:NoUnstoppedRead:violated:10

# GitHub issue #641: the Busy/Partial retry, any initiator. Liveness is
# TLC's; Apalache's shallow run checks Safety, which only failstop breaks.
check_model WorldStopRetry Safety 4 \
    fixed:CInitFixed:pass:ok \
    failstop:CInitFailStop:Safety:violated \
    core0ack:CInitCore0Ack:temporal:ok \
    maskedbackoff:CInitMaskedBackoff:temporal:ok \
    holdlock:CInitHoldLock:temporal:ok \
    stuck:CInitStuck:temporal:ok \
    shortbudget:CInitShortBudget:temporal:ok \
    debugstop:CInitDebugStop:pass:ok \
    debuglocks:CInitDebugLocks:temporal:ok

# GitHub issue #720: RegionTransfer.tkb is the protocol declaration form of
# SharedRegionTransfer above. Its generated model must reproduce the fixed
# verdict and the early-publication control the faulty one. The foreign,
# timeout and failed-reset faults no longer compile (Protocol_decl's static
# rules; test/test_takibi.ml, "protocol-declarations").
for decl in "$MODELS"/protocols/*.tkb; do
    "$TAKIBI" "$decl" --emit-tla "$GEN" || {
        echo "FAIL modelcheck: takibi --emit-tla rejected $decl"
        exit 1
    }
done
# GitHub issue #778: a device protocol's model carries the cache. The
# generator always emits the cache step, so each fault control is the same
# declaration's model with one kind of step left out by the generator.
# GitHub issue #801: RxTransfer:refresh leaves out a snapshot observation's
# per-element invalidate.
for control in TxTransfer:publish RxTransfer:publish RxTransfer:finish \
        RxTransfer:refresh; do
    "$TAKIBI" "$MODELS/protocols/${control%%:*}.tkb" --emit-tla "$GEN" \
        --emit-tla-omit-cache "${control##*:}" || {
        echo "FAIL modelcheck: takibi --emit-tla-omit-cache rejected $control"
        exit 1
    }
done
for tla in "$GEN"/*.tla; do
    name="$(basename "$tla" .tla)"
    cp "$GEN/$name.cfg" "$GEN/${name}_generated.cfg"
done
MDIR="$GEN"
check_model RegionTransfer Safety 6 generated:CInit:pass:ok
check_model RegionTransferEarly Safety 6 generated:CInit:Safety:violated
check_model TxTransfer Safety 8 generated:CInit:pass:ok
check_model TxTransfer_omitpublish Safety 8 generated:CInit:Safety:violated
check_model RxTransfer Safety 8 generated:CInit:pass:ok
check_model RxTransfer_omitpublish Safety 8 generated:CInit:Safety:violated
check_model RxTransfer_omitfinish Safety 8 generated:CInit:Safety:violated
check_model RxTransfer_omitrefresh Safety 8 generated:CInit:Safety:violated
check_model PacketBuffer Safety 8 generated:CInit:pass:ok
MDIR="$MODELS"

# GitHub issue #606, stage 2: the protocol-trace check is TLC run on
# StackOwnershipTrace.tla. Its controls (the recorded windows accepted, each
# planted defect refused) run beside the model jobs; each is a short TLC.
TRACE_CONTROLS_LOG="$OUT/protocol-trace-controls.log"
python3 "$REPO_ROOT/scripts/protocol_trace_tlc_controls.py" >"$TRACE_CONTROLS_LOG" 2>&1 &
trace_controls_pid=$!
# GitHub issue #656: the same for the log ring, LogRingTrace.tla.
RING_TRACE_CONTROLS_LOG="$OUT/log-ring-trace-controls.log"
python3 "$REPO_ROOT/scripts/log_ring_trace_tlc_controls.py" >"$RING_TRACE_CONTROLS_LOG" 2>&1 &
ring_trace_controls_pid=$!

# Run. A job's own exit status is not the verdict -- an unfixed variant is
# SUPPOSED to fail -- so every job is allowed to fail here and judged below.
(cd "$MODELS" && xargs -P "$JOBS" -L 1 sh -c 'log="$0"; "$@" >"$log" 2>&1 || true' <"$QUEUE")

failures=0
fail() { echo "FAIL modelcheck: $*"; failures=$((failures + 1)); }

if wait "$trace_controls_pid"; then
    grep "^PASS" "$TRACE_CONTROLS_LOG"
else
    cat "$TRACE_CONTROLS_LOG"
    fail "the protocol-trace TLC controls (see $TRACE_CONTROLS_LOG)"
fi
if wait "$ring_trace_controls_pid"; then
    grep "^PASS" "$RING_TRACE_CONTROLS_LOG"
else
    cat "$RING_TRACE_CONTROLS_LOG"
    fail "the log-ring-trace TLC controls (see $RING_TRACE_CONTROLS_LOG)"
fi

for model in $(cut -d' ' -f1 "$EXPECT" | uniq); do
    grep -q "Type checker \[OK\]" "$OUT/$model.typecheck.log" ||
        fail "$model: Apalache typecheck failed (see $OUT/$model.typecheck.log)"
done

declare -A variants shortest longest
coverage_runs=()
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
        pass) if grep -q "Model checking completed. No error has been found." "$log"; then
                  coverage_runs+=("$model:$cfg:$log")
              else
                  fail "$model $cfg: TLC found an error (see $log)"
              fi ;;
        deadlock) grep -q "Error: Deadlock reached." "$log" ||
                  fail "$model $cfg: TLC did not report the deadlock (see $log)" ;;
        temporal) grep -q "Error: Temporal properties were violated." "$log" &&
                  [ "$(grep -c '^PROPERTY' "$MODELS/${model}_$cfg.cfg")" = 1 ] ||
                  fail "$model $cfg: TLC did not report its one liveness property violated (see $log)" ;;
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

# GitHub issue #802: a run that explored the whole state space must have
# taken every action of its spec, or have allow-listed the dead one with a
# reason; a model that passes because part of it never runs is a failure.
python3 "$REPO_ROOT/scripts/model_coverage.py" "$MODELS/coverage_allow.txt" \
    "${coverage_runs[@]}" || fail "an action of a passing TLC run is never taken (above)"
# The control: StackOwnership's two-process fixed run really leaves
# CloneReschedule untaken, so without the allow-list the same check must
# refuse it. A coverage check that stopped seeing dead actions fails here.
control_log="$OUT/coverage-control.log"
if python3 "$REPO_ROOT/scripts/model_coverage.py" /dev/null \
        "StackOwnership:fixed:$OUT/StackOwnership-fixed.tlc.log" >"$control_log" 2>&1 ||
        ! grep -q "action CloneReschedule (line [0-9]*) is never taken" "$control_log"; then
    fail "the coverage check accepted StackOwnership fixed's dead CloneReschedule without an allow-list entry (see $control_log)"
fi

[ "$failures" -eq 0 ] || exit 1
for model in $(cut -d' ' -f1 "$EXPECT" | uniq); do
    bounds=${shortest[$model]}
    [ "${longest[$model]}" = "$bounds" ] || bounds="$bounds-${longest[$model]}"
    echo "PASS modelcheck: $model -- ${variants[$model]} variant(s) each gave TLC's and Apalache's (length $bounds) expected verdict, types check"
done
