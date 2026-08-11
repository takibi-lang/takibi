#!/usr/bin/env bash
# Boot the standalone QEMU kernel with its guest UART attached to this tty.
# This intentionally does not run the automated network peer or compare views:
# the point of this target is a human session in the BusyBox ash shell.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"

if [ ! -f "$ELF" ] || [ ! -f "$EXT2_IMAGE" ]; then
    echo "error: kernel build products are missing; run 'make kernelbuild-qemu' first" >&2
    exit 1
fi

if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required; install it with: sudo apt-get install python3-serial" >&2
    exit 1
fi

QEMU_SERIAL_PORT="${KERNEL_QEMU_SHELL_SERIAL_PORT:-17773}"
echo "[kernel/qemu] interactive UART session (Ctrl-] exits miniterm)"
QEMU_COMMAND=(
    qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -nographic \
    -monitor none \
    -serial "tcp:127.0.0.1:$QEMU_SERIAL_PORT,server=on,wait=off" \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=17771,remote.type=inet,remote.host=127.0.0.1,remote.port=17772" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF"
)

"${QEMU_COMMAND[@]}" &
QEMU_PID=$!
cleanup() {
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# pyserial's socket:// backend gives miniterm the same LF and local-echo
# behavior as the RPi5 Debug Probe console, while QEMU remains independent of
# make's recipe stdin handling.
exec python3 -m serial.tools.miniterm --raw --eol LF --echo \
    "socket://127.0.0.1:$QEMU_SERIAL_PORT" 115200
