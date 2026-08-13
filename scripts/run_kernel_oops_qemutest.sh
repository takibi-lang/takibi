#!/usr/bin/env bash
# Deterministic fail-stop regression: stop QEMU at reset, use GDB only to
# replace one otherwise ordinary kernel instruction with BRK #0, then verify
# both the UART oops record and retained structured CrashSnapshot while the
# kernel itself has parked the CPU.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
ARTIFACT_DIR="${KERNEL_QEMU_OOPS_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-oops-qemu}"
GDB_PORT="${KERNEL_QEMU_OOPS_GDB_PORT:-18674}"
UART_LOG="$ARTIFACT_DIR/uart.log"
mkdir -p "$ARTIFACT_DIR"
: >"$UART_LOG"

if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-oops-qemu" >&2
    exit 1
fi

qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 2 -m 1024 \
    -display none -monitor none -serial "file:$UART_LOG" \
    -S -gdb "tcp::$GDB_PORT" -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
cleanup() {
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# Fault injection is the sole GDB role before the oops.  Patch the first
# instruction of the existing test driver while the guest is stopped at
# reset; no kernel test flag or special code path exists.  Detach then resumes
# the guest, so the subsequent UART transcript is produced by the kernel
# alone -- GDB neither handles the exception nor formats any diagnostic
# output.
armed=false
for _ in $(seq 1 50); do
    if gdb-multiarch -q -batch "$ELF" \
        -ex "target remote :$GDB_PORT" \
        -ex "set {int}&kernel_test_driver_run = 0xd4200000" \
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
    if grep -q '^oops: saved-frame=unavailable$' "$UART_LOG"; then
        break
    fi
    sleep 0.1
done

if ! grep -Eq '^oops: fail-stop seq=[1-9][0-9]* cpu=[0-9]+ slot=4 ec=0x000000000000003c ' "$UART_LOG" ||
        ! grep -q '^oops: saved-frame=unavailable$' "$UART_LOG" ||
        ! grep -q '^oops: scheduler-trace=unavailable$' "$UART_LOG"; then
    echo "FAIL kernel/qemu oops: expected fail-stop UART report" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# The CPU is parked in WFE, so GDB can halt it and inspect the first four
# machine words of the globally named struct (valid, sequence, CPU, vector
# slot).  It reads the kernel's one stored object, not a duplicate
# ExceptionFrame or crash-record ABI in the test harness.
gdb-multiarch -q -batch "$ELF" \
    -ex "target remote :$GDB_PORT" \
    -ex "interrupt" \
    -ex "x/4gx &crash_snapshot" >"$ARTIFACT_DIR/snapshot-gdb.log" 2>&1 || true
if ! grep -Eq 'crash_snapshot>.*0x0000000000000001.*0x0000000000000001' "$ARTIFACT_DIR/snapshot-gdb.log" ||
        ! grep -Eq 'crash_snapshot\+16.*0x0000000000000004' "$ARTIFACT_DIR/snapshot-gdb.log"; then
    echo "FAIL kernel/qemu oops: retained CrashSnapshot was not readable" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/snapshot-gdb.log" >&2 || true
    exit 1
fi

echo "PASS kernel/qemu oops: UART report and CrashSnapshot valid"
