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
    --log "$UART_LOG" &
driver_pid=$!

GDB_COMMANDS=(-ex "target remote 127.0.0.1:$GDB_PORT")
if [ "$BREAK_SOURCE" = software ]; then
    GDB_COMMANDS+=(
        -ex "break kernel_ddb_breakpoint_test_checkpoint"
        -ex "continue"
        -ex "set *(char *)&kernel_ddb_breakpoint_test_enabled = 1"
        -ex "disable 1"
    )
fi
gdb-multiarch -q -batch "$ELF" "${GDB_COMMANDS[@]}" \
    -ex "detach" >/dev/null
wait "$driver_pid"

if ! grep -q '^ddb: interrupt-safe UART debugger$' "$UART_LOG" ||
        ! grep -Eq '^ddb: break seq=[1-9][0-9]* cpu=[0-9]+ elr=0x[0-9a-f]+ sp_el0=0x[0-9a-f]+$' "$UART_LOG" ||
        ! grep -q '^ddb: x0=0x' "$UART_LOG" ||
        ! grep -q '^ddb: sp_el0=0x' "$UART_LOG" ||
        ! grep -q '^ddb: trace count=' "$UART_LOG" ||
        ! grep -q '^ddb: continuing$' "$UART_LOG" ||
        ! grep -q '^init: ash bootstrap$' "$UART_LOG"; then
    echo "FAIL kernel/qemu ddb: BREAK inspection did not resume boot" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

echo "PASS kernel/qemu ddb: $BREAK_SOURCE BREAK inspected and resumed"
