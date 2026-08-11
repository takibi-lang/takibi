#!/usr/bin/env bash
# Boot the standalone QEMU kernel with its guest UART attached to this tty.
# This does not compare automated views: the point of this target is a human
# session in the BusyBox ash shell.
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
QEMU_LAUNCH_NS="$(date +%s%N)"
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

export KERNEL_QEMU_SHELL_LAUNCH_NS="$QEMU_LAUNCH_NS"
"${QEMU_COMMAND[@]}" &
QEMU_PID=$!
NETWORK_PEER_PID=""
if [ "${KERNEL_QEMU_SHELL_NETWORK_PEER:-1}" = 1 ]; then
    # The kernel runs its normal ARP/ICMP/TCP fixture before reaching ext2 and
    # ash. Without the peer, the interactive shell pays the full protocol
    # timeout even though the human console does not need to test the peer.
    python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" 17771 17772 \
        >"${KERNEL_QEMU_SHELL_NETWORK_LOG:-/tmp/takibi-kernel-qemu-network.log}" 2>&1 &
    NETWORK_PEER_PID=$!
fi
cleanup() {
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    if [ -n "$NETWORK_PEER_PID" ]; then
        kill "$NETWORK_PEER_PID" 2>/dev/null || true
        wait "$NETWORK_PEER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP

# The wrapper keeps the complete UART stream in the terminal and reports the
# first explicit ash readiness marker without adding a second TCP consumer.
python3 "$REPO_ROOT/scripts/run_kernel_shell_console.py" \
    "socket://127.0.0.1:$QEMU_SERIAL_PORT" 115200
