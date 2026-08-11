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

echo "[kernel/qemu] interactive UART session (Ctrl-a x exits QEMU)"
QEMU_COMMAND=(
    qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -nographic \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=17771,remote.type=inet,remote.host=127.0.0.1,remote.port=17772" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF"
)

if [ -t 0 ]; then
    exec "${QEMU_COMMAND[@]}"
fi

# GNU Make runs recipes with stdin detached when its default parallel mode is
# active. Reattach through the controlling terminal and let util-linux
# `script` allocate a pty for QEMU's -nographic stdio console.
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '[kernel/qemu] make stdin is detached; attaching to /dev/tty\n'
    printf -v QEMU_COMMAND_LINE '%q ' "${QEMU_COMMAND[@]}"
    exec script -qefc "$QEMU_COMMAND_LINE" /dev/null </dev/tty >/dev/tty
fi

echo "error: no interactive terminal available for QEMU UART input" >&2
exit 1
