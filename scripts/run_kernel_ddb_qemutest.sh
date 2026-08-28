#!/usr/bin/env bash
# Resumable DDB regression: QEMU injects a real serial BREAK, the kernel
# inspects its compiler-generated IRQ frame, and `continue` resumes boot.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
ARTIFACT_DIR="${KERNEL_QEMU_DDB_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-ddb-qemu}"
SERIAL_PORT="${KERNEL_QEMU_DDB_SERIAL_PORT:-18701}"
QMP_PORT="${KERNEL_QEMU_DDB_QMP_PORT:-18702}"
GDB_PORT="${KERNEL_QEMU_DDB_GDB_PORT:-18703}"
BREAK_SOURCE="${KERNEL_QEMU_DDB_BREAK_SOURCE:-uart}"
UART_LOG="$ARTIFACT_DIR/uart.log"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
KERNEL_READ_ADDRESS="$(llvm-nm-19 "$ELF" | awk '$3 == "kernel_ddb_breakpoint_test_enabled" { print $1; exit }')"
if [ -z "$KERNEL_READ_ADDRESS" ]; then
    echo "kernel DDB read-test symbol not found" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu ddb" \
    "tcp:$SERIAL_PORT" "tcp:$QMP_PORT" "tcp:$GDB_PORT" || exit 1

qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none \
    -qmp "tcp:127.0.0.1:$QMP_PORT,server=on,wait=off" \
    -gdb "tcp:127.0.0.1:$GDB_PORT" -S \
    -chardev "socket,id=debug_uart,host=127.0.0.1,port=$SERIAL_PORT,server=on,wait=off" \
    -serial chardev:debug_uart \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
driver_pid=""
cleanup() {
    if [ -n "$driver_pid" ]; then kill "$driver_pid" 2>/dev/null || true; fi
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

python3 "$REPO_ROOT/scripts/run_kernel_ddb_driver.py" \
    --serial-port "$SERIAL_PORT" --qmp-port "$QMP_PORT" \
    --break-source "$BREAK_SOURCE" \
    --kernel-address "$KERNEL_READ_ADDRESS" \
    --log "$UART_LOG" &
driver_pid=$!

GDB_COMMANDS=(
    -ex "target remote 127.0.0.1:$GDB_PORT"
    -ex "break kernel_ddb_breakpoint_test_checkpoint"
    -ex "continue"
    -ex "set *(char *)&kernel_ddb_memory_fault_test_enabled = 1"
    -ex "set *(char *)&diagnostic_trace_test_enabled = 1"
    -ex "disable 1"
)
if [ "$BREAK_SOURCE" = software ]; then
    GDB_COMMANDS+=(
        -ex "set *(char *)&kernel_ddb_breakpoint_test_enabled = 1"
    )
fi
gdb-multiarch -q -batch "$ELF" "${GDB_COMMANDS[@]}" \
    -ex "detach" >/dev/null
wait "$driver_pid"

expected_entry=irq
expected_source=33
if [ "$BREAK_SOURCE" = software ]; then
    expected_entry=brk
    expected_source=21579
fi

if ! grep -q '^ddb: interrupt-safe UART debugger$' "$UART_LOG" ||
        ! grep -Eq '^ddb: break seq=[1-9][0-9]* cpu=[0-9]+ elr=0x[0-9a-f]+ sp_el0=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -q '^ddb: x0=0x' "$UART_LOG" ||
        ! grep -q '^ddb: sp_el0=0x' "$UART_LOG" ||
        ! grep -Eq "^ddb: intr cpu=[0-9]+ entry=$expected_entry source=$expected_source live_daif=0x[0-9a-f]+ saved_daif=0x[0-9a-f]+$" "$UART_LOG" ||
        ! grep -Eq '^ddb: intr esr=(0x[0-9a-f]+|unavailable) far=(0x[0-9a-f]+|unavailable)$' "$UART_LOG" ||
        ! grep -Eq '^ddb: sched enabled=[01] pending=[01] current=[0-9]+ ready=[0-9]+ running=[0-9]+ blocked=[0-9]+ exited=[0-9]+ truncated=[01]$' "$UART_LOG" ||
        ! grep -Eq '^ddb: current pid=[0-9]+ parent=[0-9]+ state=[0-9]+ wait=[0-9]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: vm pid=[0-9]+ root=[0-9]+ live=[01] asid=[0-9]+ l1=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: fds pid=[0-9]+ slots=[0-9]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: ps count=[1-9][0-9]* truncated=[01]$' "$UART_LOG" ||
        ! grep -Eq '^ddb: ps pid=1 ppid=0 state=[0-9]+ wait=[0-9]+ root=0 sp=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -Eq '^ddb: proc pid=1 ppid=0 state=[0-9]+ wait=[0-9]+ root=0 sp=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -q '^ddb: trace count=' "$UART_LOG" ||
        ! grep -q '^ddb: events cpu=0 count=' "$UART_LOG" ||
        ! grep -Eq "^ddb: xk address=0x0*$KERNEL_READ_ADDRESS count=2$" "$UART_LOG" ||
        [ "$(grep -c '^ddb: xk byte address=0x.* value=0x' "$UART_LOG")" -lt 2 ] ||
        [ "$(grep -c '^ddb: usage: xk|xp HEX_ADDRESS \[COUNT_1_TO_64\]$' "$UART_LOG")" -ne 2 ] ||
        ! grep -q '^ddb: xk denied (not ordinary kernel RAM) address=0x0000001000000000 count=1$' "$UART_LOG" ||
        ! grep -q '^ddb: xk fault address=0x0000001000000000$' "$UART_LOG" ||
        ! grep -Eq "^ddb: xp physical=0x0*$KERNEL_READ_ADDRESS count=2$" "$UART_LOG" ||
        [ "$(grep -c '^ddb: xp byte physical=0x.* value=0x' "$UART_LOG")" -lt 2 ] ||
        ! grep -q '^ddb: xp denied (not ordinary physical RAM) address=0x0000001000000000 count=1$' "$UART_LOG" ||
        ! grep -q '^ddb: xu pid=1 root=0 address=0x0000000080000000 count=2$' "$UART_LOG" ||
        [ "$(grep -c '^ddb: xu byte address=0x000000008000000[01] physical=0x[0-9a-f]* value=0x[0-9a-f]*$' "$UART_LOG")" -lt 2 ] ||
        ! grep -q '^ddb: xu pid=1 root=0 address=0x0000000080000fff count=2$' "$UART_LOG" ||
        ! grep -q '^ddb: xu byte address=0x0000000080000fff physical=0x' "$UART_LOG" ||
        ! grep -q '^ddb: xu byte address=0x0000000080001000 physical=0x' "$UART_LOG" ||
        [ "$(grep -c '^ddb: usage: xu PID HEX_ADDRESS \[COUNT_1_TO_64\]$' "$UART_LOG")" -ne 2 ] ||
        ! grep -q '^ddb: xu pid not captured$' "$UART_LOG" ||
        ! grep -q '^ddb: xu unmapped address=0x0000000070000000$' "$UART_LOG" ||
        ! grep -q '^ddb: continuing$' "$UART_LOG" ||
        ! grep -q '^init: ash bootstrap$' "$UART_LOG"; then
    echo "FAIL kernel/qemu ddb: BREAK inspection did not resume boot" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

if [ "$BREAK_SOURCE" = uart ] &&
        { ! grep -Eq '^ddb: event seq=1 cpu=0 id=0x0000000000000201 a=0x000000000000000a b=0x0*[1-9a-f][0-9a-f]* c=0x0000000000000000 d=0x0000000000000001$' "$UART_LOG" ||
          ! grep -q '^ddb: event seq=2 cpu=0 id=0x0000000000000101 a=0x' "$UART_LOG"; }; then
    echo "FAIL kernel/qemu ddb: interleaved UART wake/BREAK events missing" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

echo "PASS kernel/qemu ddb: $BREAK_SOURCE BREAK inspected and resumed"
