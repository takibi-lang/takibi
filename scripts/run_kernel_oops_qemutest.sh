#!/usr/bin/env bash
# Deterministic fail-stop regression: stop QEMU at reset, use GDB only to
# replace the first ordinary EL0 instruction with BRK #0, then verify both
# the UART oops record and retained structured CrashSnapshot while the kernel
# itself has parked the CPU. `child_exec` instead stops immediately after a
# real exec commit through a debugger-owned, default-false test switch, while
# `child_exec_prepare_failure` forces one named prepare result at its real
# call boundary through compiler-emitted variant-return metadata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="${KERNEL_QEMU_OOPS_ELF:-$REPO_ROOT/kernel/build/qemu/kernel-debug.elf}"
DEBUG_METADATA="$REPO_ROOT/_build/kernel-debug-metadata.json"
ARTIFACT_DIR="${KERNEL_QEMU_OOPS_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-oops-qemu}"
GDB_PORT="${KERNEL_QEMU_OOPS_GDB_PORT:-18697}"
SERIAL_PORT="${KERNEL_QEMU_OOPS_SERIAL_PORT:-18698}"
MODE="${KERNEL_QEMU_OOPS_MODE:-brk}"
UART_LOG="$ARTIFACT_DIR/uart.log"
SNAPSHOT_LAYOUT="$REPO_ROOT/_build/kernel-crash-snapshot-layout.gdb"
mkdir -p "$ARTIFACT_DIR"
: >"$UART_LOG"

# GitHub issue #407: see scripts/qemu_port_guard.py. Refuse to start if
# somebody already owns this lane's ports, and say that rather than
# reporting a kernel that was never asked anything.
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports GDB_PORT SERIAL_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu oops" \
    "tcp:$GDB_PORT" "tcp:$SERIAL_PORT" || exit 1
if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-oops-qemu" >&2
    exit 1
fi

case "$MODE" in
    brk)
        fault_instruction=0xd4200000
        expected_ec=3c
        expected_detail=''
        ;;
    data_abort_write)
        # str x0, [x0]: x0 holds argc at this entry, so this is an ordinary
        # EL0 write to an unmapped low address and must take a data abort.
        fault_instruction=0xf9000000
        expected_ec=24
        expected_detail='^oops: data-abort dfsc=0x000000000000000[0-9a-f] access=write$'
        ;;
    child_exec)
        fault_instruction=''
        expected_ec=15
        expected_detail=''
        ;;
    child_exec_prepare_failure)
        fault_instruction=''
        expected_ec=15
        expected_detail=''
        ;;
    *)
        echo "error: unknown KERNEL_QEMU_OOPS_MODE: $MODE" >&2
        exit 1
        ;;
esac

qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 2 -m 1024 \
    -display none -monitor none \
    -serial "tcp:127.0.0.1:$SERIAL_PORT,server=on,wait=on" \
    -S -gdb "tcp::$GDB_PORT" -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
console_driver_pid=""
cleanup() {
    if [ -n "$console_driver_pid" ]; then
        kill "$console_driver_pid" 2>/dev/null || true
        wait "$console_driver_pid" 2>/dev/null || true
    fi
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

python3 "$REPO_ROOT/scripts/run_kernel_crash_console.py" \
    --port "$SERIAL_PORT" --log "$UART_LOG" &
console_driver_pid=$!

# Fault injection is the sole GDB role before the oops. It enables the
# debugger-owned boot-test trace switch before process setup, then stops at
# run_initial_user, where x0 is the mapped EL0 entry, and replaces only that
# first user instruction. Stop once more at the common
# evidence entry and alter the saved TPIDR_EL0 word to a deliberately distinct
# value.  This is a test-only proof that the report contains both the live
# registers and the saved exception context; the injected BRK and its vector
# path are otherwise the ordinary kernel path. In child_exec mode GDB enables
# the default-false lifecycle stop switch, detaches, and ordinary kernel flow
# reaches the same fail-stop entry after a real exec commit. GDB neither
# handles the exception nor formats its diagnostic.
armed=false
for _ in $(seq 1 50); do
    if [ "$MODE" = child_exec ]; then
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
            -ex "break kernel_process_execution_reset"
            -ex "continue"
            -ex "set *(char *)&kernel_process_trace_boot_enabled = 1"
            -ex "set *(char *)&kernel_process_trace_fail_after_exec = 1"
            -ex "disable 1"
            -ex "detach"
        )
    elif [ "$MODE" = child_exec_prepare_failure ]; then
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
            -ex "break kernel_process_execution_reset"
            -ex "continue"
            -ex "set *(char *)&kernel_process_trace_boot_enabled = 1"
            -ex "disable 1"
            -ex "source $REPO_ROOT/scripts/kernel_debug_metadata.gdb"
            -ex "takibi-debug-metadata $DEBUG_METADATA"
            -ex "break kernel_process_child_exec_prepare"
            -ex "continue"
            -ex "takibi-force-variant-return KernelChildExecPrepareResult CloneVmMissing"
            -ex "detach"
        )
    else
        gdb_commands=(
            -ex "target remote :$GDB_PORT"
            -ex "break kernel_process_execution_reset"
            -ex "continue"
            -ex "set *(char *)&kernel_process_trace_boot_enabled = 1"
            -ex "disable 1"
            -ex "break run_initial_user"
            -ex "continue"
            -ex "call (void) kernel_process_trace_report()"
            -ex "set {int}\$x0 = $fault_instruction"
            -ex "break el1_exception_evidence_from_frame"
            -ex "continue"
            -ex "set {long}(\$x1 + 0x320) = 0xfeedfacefeedface"
            -ex "detach"
        )
    fi
    if gdb-multiarch -q -batch "$ELF" "${gdb_commands[@]}" \
            >"$ARTIFACT_DIR/arm-gdb.log" 2>&1; then
        armed=true
        break
    fi
    sleep 0.1
done
if [ "$armed" != true ]; then
    echo "FAIL kernel/qemu oops: GDB could not arm fault injection" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
    exit 1
fi

for _ in $(seq 1 50); do
    if grep -q '^ddb: read-only crash console' "$UART_LOG"; then
        break
    fi
    sleep 0.1
done

if ! wait "$console_driver_pid"; then
    console_driver_pid=""
    echo "FAIL kernel/qemu oops: read-only UART crash console did not respond" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
console_driver_pid=""

if ! grep -Eq "^oops: fail-stop seq=[1-9][0-9]* cpu=[0-9]+ slot=8 ec=0x00000000000000$expected_ec " "$UART_LOG" ||
        ! grep -q '^oops: saved sp_el0=' "$UART_LOG" ||
        ! grep -Eq '^oops: trace count=([1-9]|1[0-6])$' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected fail-stop UART report" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if ! grep -q '^ddb: read-only crash console$' "$UART_LOG" ||
        ! grep -q '^trace count=' "$UART_LOG" ||
        ! grep -q '^ps: pid ppid state pages command$' "$UART_LOG" ||
        ! grep -Eq '^ps: 1 0 [RSZ] [0-9]+ ' "$UART_LOG" ||
        ! grep -Eq '^proc: pid=1 ppid=0 state=[RSZ] wait=[0-9]+ saved_sp=0x[0-9a-f]+ pages=[0-9]+ command=' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: crash-console commands did not render" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
# GitHub issue #402: `asid=` is matched as "some assigned number", not as
# the literal 1 it used to be. A root's ASID is not its identity any more --
# the allocator recycles numbers by rolling the generation over, so root 0
# holds whatever number its last activation gave it. What still has to be
# true is that a running root has one at all, which a nonzero value says.
if [ "$MODE" != child_exec ] && [ "$MODE" != child_exec_prepare_failure ] &&
        { ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=7 pid=1 gen=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -Eq '^oops: process pid=1 parent=0 state=2 wait=0 wait4_status_ptr=0x0+ root=0 asid=[1-9][0-9]* .* image=bootstrap$' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu oops: expected bootstrap process trace" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" != child_exec ] && [ "$MODE" != child_exec_prepare_failure ] &&
        { ! grep -Eq '^process trace: count=([1-9]|1[0-6])$' "$UART_LOG" ||
          ! grep -Eq '^process trace: seq=[1-9][0-9]* cpu=0 event=7 pid=1 gen=[1-9][0-9]* ' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu oops: on-demand process trace report was not callable before the crash" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" != child_exec ] && [ "$MODE" != child_exec_prepare_failure ] &&
        ! grep -q ' tpidr_el0=0xfeedfacefeedface ' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: saved TPIDR_EL0 was not retained" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" = child_exec ] &&
        { ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=1 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=2 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=3 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -q '^oops: exec prepare=debugger-after-commit$' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu oops: child exec lifecycle trace was incomplete" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ "$MODE" = child_exec_prepare_failure ] &&
        { ! grep -Eq '^oops: trace seq=[1-9][0-9]* cpu=0 event=1 pid=[1-9][0-9]* ' "$UART_LOG" ||
          ! grep -q '^oops: exec prepare=clone-vm-missing$' "$UART_LOG" ||
          ! grep -q 'takibi-force-variant-return: KernelChildExecPrepareResult::CloneVmMissing via registers' "$ARTIFACT_DIR/arm-gdb.log"; }; then
    echo "FAIL kernel/qemu oops: forced child exec prepare failure was not named" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
    exit 1
fi
# GitHub issue #384: the report says WHO owns the pages it names, which is
# the lookup #373 spent a day doing by hand.  Both addresses are user VAs
# here, so this also proves the translation through the faulting process's
# own page table happened -- an untranslated VA would report "neither one
# of this allocator's pages nor mapped".
# Which of the two addresses resolves depends on the mode, and that is the
# point rather than an inconvenience: a fault injected at the first user
# instruction names a user text page in ELR, while a kernel-side fail-stop
# after an exec commit names one in FAR and has a kernel ELR.
# GitHub issue #270: child_exec mode used to require FAR to resolve too.
# That fail-stop is SVC-class -- it has no faulting address at all, so FAR
# is whatever the last real data abort left in the register, and whether
# that stale VA happens to be mapped in the exec'ing child's root is a fact
# about the process tree rather than about the report. It resolved while
# init.sh was PID 1 and does not under BusyBox init, having proved nothing
# either time. The default mode injects a real fault and still asserts the
# translation, which is where that coverage belongs; both owner lines are
# still required in every mode by the loop below.
case "$MODE" in
    child_exec|child_exec_prepare_failure) resolved= ;;
    *)          resolved=elr ;;
esac
if [ -n "$resolved" ] &&
        ! grep -Eq "^oops: $resolved page \(via root [0-9]+ -> 0x[0-9a-f]+\) is mapped into a process address space\$" \
        "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected the $resolved page's owner, resolved through the faulting root" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
for line in far elr; do
    if ! grep -Eq "^oops: $line page " "$UART_LOG"; then
        echo "FAIL kernel/qemu oops: expected a $line-page owner line" >&2
        sed 's/^/  /' "$UART_LOG" >&2 || true
        exit 1
    fi
done

if [ -n "$expected_detail" ] && ! grep -Eq "$expected_detail" "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected decoded data-abort write" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# The CPU is confined to the read-only UART console, so the kernel-aware GDB
# command can still halt it and inspect the fixed CrashSnapshot. It reads the
# kernel's one stored object, not a
# duplicate ExceptionFrame or crash-record ABI in the test harness.
gdb-multiarch -q -batch "$ELF" \
    -ex "target remote :$GDB_PORT" \
    -ex "interrupt" \
    -ex "source $SNAPSHOT_LAYOUT" \
    -ex "source $REPO_ROOT/scripts/kernel_crash_snapshot.gdb" \
    -ex "source $REPO_ROOT/scripts/kernel_debug_metadata.gdb" \
    -ex "takibi-debug-metadata $DEBUG_METADATA" \
    -ex "source $REPO_ROOT/scripts/kernel_state.gdb" \
    -ex "takibi-oops" \
    -ex "takibi-kernel" \
    -ex "takibi-constant ProcessTrace \$snapshot[\$takibi_crashsnapshot_trace / 8 + 2]" \
    -ex "takibi-enum ProcessSlotState \$snapshot[\$takibi_crashsnapshot_trace / 8 + 7]" \
    -ex "takibi-enum ProcessWaitReason \$snapshot[\$takibi_crashsnapshot_trace / 8 + 8]" \
    >"$ARTIFACT_DIR/snapshot-gdb.log" 2>&1 || true
if ! grep -Eq '^takibi-oops: seq=1 cpu=[0-9]+ slot=8 ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -q '^takibi-oops: saved sp_el0=' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-oops: trace count=([1-9]|1[0-6])$' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^ProcessTrace[A-Za-z]+ \([0-9]+\)$' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^ProcessSlotState::[A-Za-z]+ \([0-9]+\)$' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^ProcessWaitReason::[A-Za-z]+ \([0-9]+\)$' "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: retained CrashSnapshot was not readable" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi
if ! grep -q '^takibi-kernel: ddb status=unpublished$' \
        "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-kernel: crash status=valid seq=1 cpu=[0-9]+ slot=8 ' \
        "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-kernel: crash process pid=[0-9]+ .* trace_count=([1-9]|1[0-6])$' \
        "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-kernel: crash-trace seq=[1-9][0-9]* cpu=[0-9]+ event=ProcessTrace[A-Za-z]+\([0-9]+\) ' \
        "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: kernel-aware crash view was incomplete" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi
if [ "$MODE" != child_exec ] &&
        ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=7 pid=1 gen=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: retained bootstrap trace was incomplete" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi
if [ "$MODE" = child_exec ] &&
        { ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=1 pid=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
          ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=2 pid=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
          ! grep -Eq '^takibi-oops: trace seq=[1-9][0-9]* cpu=0 event=3 pid=[1-9][0-9]* ' "$ARTIFACT_DIR/snapshot-gdb.log"; }; then
    echo "FAIL kernel/qemu oops: retained child exec trace was incomplete" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi

echo "PASS kernel/qemu oops: UART report and CrashSnapshot valid"
