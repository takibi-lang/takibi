#!/usr/bin/env bash
# Boot the standalone QEMU kernel with its guest UART attached to this tty.
# This does not compare automated views: the point of this target is a human
# session in the BusyBox ash shell.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
ARTIFACT_DIR="${KERNEL_QEMU_SHELL_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-shell-qemu}"
SHELL_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"

if [ ! -f "$ELF" ] || [ ! -f "$EXT2_IMAGE" ]; then
    echo "error: kernel build products are missing; run 'make kernelbuild-qemu' first" >&2
    exit 1
fi

if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required; install it with: sudo apt-get install python3-serial" >&2
    exit 1
fi

# A human session is allowed to mutate the mounted filesystem. Keep that
# experiment from changing the source fixture used by the next automated
# kernelcheck run.
mkdir -p "$ARTIFACT_DIR"
cp "$EXT2_IMAGE" "$SHELL_EXT2_IMAGE"

QEMU_SERIAL_PORT="${KERNEL_QEMU_SHELL_SERIAL_PORT:-17773}"
HTTP_PORT="${KERNEL_QEMU_SHELL_HTTP_PORT:-18080}"
echo "[kernel/qemu] interactive UART session (Ctrl-] exits miniterm)"
echo "[kernel/qemu] httpd forwarding: http://127.0.0.1:$HTTP_PORT/ -> 192.168.20.2:8080"
QEMU_LAUNCH_NS="$(date +%s%N)"
# Keep the user-network subnet aligned with the kernel's fixed test address.
# hostfwd terminates only on loopback, so the demo is local to the developer
# machine rather than exposed on the LAN.
QEMU_COMMAND=(
    qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none -monitor none \
    -serial "tcp:127.0.0.1:$QEMU_SERIAL_PORT,server=on,wait=off" \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$SHELL_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "user,id=net0,net=192.168.20.0/24,dhcpstart=192.168.20.15,host=192.168.20.1,hostfwd=tcp:127.0.0.1:$HTTP_PORT-192.168.20.2:8080" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF"
)

export KERNEL_SHELL_PLATFORM=qemu
export KERNEL_SHELL_LAUNCH_NS="$QEMU_LAUNCH_NS"
if [ "${KERNEL_QEMU_SHELL_MEASURE_ONLY:-0}" = 1 ]; then
    export KERNEL_SHELL_MEASURE_ONLY=1
fi
"${QEMU_COMMAND[@]}" &
QEMU_PID=$!
cleanup() {
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# The wrapper keeps the complete UART stream in the terminal and reports the
# first explicit ash readiness marker without adding a second TCP consumer.
python3 "$REPO_ROOT/scripts/run_kernel_shell_console.py" \
    "socket://127.0.0.1:$QEMU_SERIAL_PORT" 115200
