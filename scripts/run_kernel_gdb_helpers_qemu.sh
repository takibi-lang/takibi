#!/usr/bin/env bash
# Runs the read-only gdb helpers that kernel/README.md documents against a
# live QEMU debug kernel, so a helper that has drifted from the kernel's
# layout fails here instead of at the moment someone needs it.
# scripts/kernel_page_allocator.gdb went stale this way twice (a renamed
# global, then the #744 metadata move) without any lane noticing.
set -euo pipefail

ELF="${KERNEL_GDB_HELPERS_ELF:-kernel/build/qemu/kernel-debug.elf}"
GDB_PORT="${KERNEL_GDB_HELPERS_GDB_PORT:-18941}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_GDB_HELPERS_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-gdb-helpers-qemu}"
mkdir -p "$ARTIFACT_DIR"

qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none -monitor none \
    -serial "file:$ARTIFACT_DIR/serial.log" \
    -gdb "tcp:127.0.0.1:$GDB_PORT" -S \
    -global virtio-mmio.force-legacy=on \
    -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
QEMU_PID=$!
trap 'kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true' EXIT

status=0
timeout 120 gdb-multiarch -q -batch "$ELF" \
    -ex "target remote 127.0.0.1:$GDB_PORT" \
    -ex "break page_allocator_timing_probe" \
    -ex "continue" \
    -ex "source scripts/kernel_page_allocator.gdb" \
    -ex "takibi-pages" \
    -ex "source scripts/kernel_boot_dtb.gdb" \
    -ex "takibi-dtb" \
    -ex "kill" >"$ARTIFACT_DIR/gdb.log" 2>&1 || status=$?

if grep -q "invariants: PASS" "$ARTIFACT_DIR/gdb.log" &&
        grep -q "dtb: .*magic=ok" "$ARTIFACT_DIR/gdb.log" &&
        ! grep -q "FAIL" "$ARTIFACT_DIR/gdb.log"; then
    echo "PASS kernel/qemu gdb helpers: takibi-pages validated the live allocator layout, takibi-dtb the boot DTB header"
    exit 0
fi
echo "FAIL kernel/qemu gdb helpers: takibi-pages or takibi-dtb did not validate (gdb exit $status); see $ARTIFACT_DIR/gdb.log" >&2
cat "$ARTIFACT_DIR/gdb.log" >&2
exit 1
