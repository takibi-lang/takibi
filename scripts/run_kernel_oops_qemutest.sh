#!/usr/bin/env bash
# Deterministic fail-stop regression: stop QEMU at reset, use GDB only to
# replace the first ordinary EL0 instruction with BRK #0, then verify both
# the UART oops record and retained structured CrashSnapshot while the kernel
# itself has parked the CPU.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
ARTIFACT_DIR="${KERNEL_QEMU_OOPS_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-oops-qemu}"
GDB_PORT="${KERNEL_QEMU_OOPS_GDB_PORT:-18674}"
MODE="${KERNEL_QEMU_OOPS_MODE:-brk}"
UART_LOG="$ARTIFACT_DIR/uart.log"
SNAPSHOT_LAYOUT="$REPO_ROOT/_build/kernel-crash-snapshot-layout.gdb"
mkdir -p "$ARTIFACT_DIR"
: >"$UART_LOG"

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
    *)
        echo "error: unknown KERNEL_QEMU_OOPS_MODE: $MODE" >&2
        exit 1
        ;;
esac

qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 2 -m 1024 \
    -display none -monitor none -serial "file:$UART_LOG" \
    -S -gdb "tcp::$GDB_PORT" -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
cleanup() {
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# Fault injection is the sole GDB role before the oops. The process execution
# reset records the initial runnable process in the bounded trace. Stop at
# run_initial_user, where x0 is the mapped EL0 entry, and replace only that
# first user instruction. Stop once more at the common
# evidence entry and alter the saved TPIDR_EL0 word to a deliberately distinct
# value.  This is a test-only proof that the report contains both the live
# registers and the saved exception context; the injected BRK and its vector
# path are otherwise the ordinary kernel path.  Detach then it records:
# the normal Lower-EL synchronous vector saves a real ExceptionFrame before
# the kernel produces its UART report. No kernel test flag or special path
# exists, and GDB neither handles the exception nor formats its diagnostic.
armed=false
for _ in $(seq 1 50); do
    if gdb-multiarch -q -batch "$ELF" \
        -ex "target remote :$GDB_PORT" \
        -ex "break run_initial_user" \
        -ex "continue" \
        -ex "set {int}\$x0 = $fault_instruction" \
        -ex "break el1_exception_evidence_from_frame" \
        -ex "continue" \
        -ex "set {long}(\$x1 + 0x320) = 0xfeedfacefeedface" \
        -ex "detach" >"$ARTIFACT_DIR/arm-gdb.log" 2>&1; then
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
    if grep -q '^oops: saved sp_el0=' "$UART_LOG"; then
        break
    fi
    sleep 0.1
done

if ! grep -Eq "^oops: fail-stop seq=[1-9][0-9]* cpu=[0-9]+ slot=8 ec=0x00000000000000$expected_ec " "$UART_LOG" ||
        ! grep -q '^oops: saved sp_el0=' "$UART_LOG" ||
        ! grep -q ' tpidr_el0=0xfeedfacefeedface ' "$UART_LOG" ||
        ! grep -Eq '^oops: trace count=[1-8]$' "$UART_LOG" ||
        ! grep -Eq '^oops: trace event=6 from=0 to=[1-9][0-9]*$' "$UART_LOG" ||
        ! grep -q '^oops: process pid=1 parent=0 state=2 wait=0 root=0 asid=1 .* image=bootstrap$' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected fail-stop UART report" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi
if [ -n "$expected_detail" ] && ! grep -Eq "$expected_detail" "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected decoded data-abort write" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# The CPU is parked in WFE, so the kernel-aware GDB command can inspect the
# fixed CrashSnapshot. It reads the kernel's one stored object, not a
# duplicate ExceptionFrame or crash-record ABI in the test harness.
gdb-multiarch -q -batch "$ELF" \
    -ex "target remote :$GDB_PORT" \
    -ex "interrupt" \
    -ex "source $SNAPSHOT_LAYOUT" \
    -ex "source $REPO_ROOT/scripts/kernel_crash_snapshot.gdb" \
    -ex "takibi-oops" >"$ARTIFACT_DIR/snapshot-gdb.log" 2>&1 || true
if ! grep -Eq '^takibi-oops: seq=1 cpu=[0-9]+ slot=8 ' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -q '^takibi-oops: saved sp_el0=' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq '^takibi-oops: trace count=[1-8]$' "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: retained CrashSnapshot was not readable" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi

echo "PASS kernel/qemu oops: UART report and CrashSnapshot valid"
