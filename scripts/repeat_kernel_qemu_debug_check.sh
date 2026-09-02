#!/usr/bin/env bash
# Repeat the timing-sensitive DWARF QEMU lane as a CHECK: N consecutive clean
# boots, each with its own artifact directory and its own ports.
#
# The repetition, the per-sample directories and the port separation are
# scripts/repeat_kernel_lane.sh's; this file supplies only what is specific to
# the debug lane -- which ELF, which expected views, and where its ports start.
# Merged 2026-09-01: this script and the rate-measuring runner had grown the
# same machinery from opposite ends, one able to give a verdict and the other
# able to give a rate.
#
# Override the sample count with KERNEL_QEMU_DEBUG_REPEAT.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${KERNEL_QEMU_DEBUG_REPEAT:-5}"

case "$RUNS" in
    ''|*[!0-9]*|0)
        echo "error: KERNEL_QEMU_DEBUG_REPEAT must be a positive integer" >&2
        exit 2
        ;;
esac

exec bash "$REPO_ROOT/scripts/repeat_kernel_lane.sh" \
    --mode "${KERNEL_QEMU_DEBUG_REPEAT_MODE:-check}" \
    --label qemu-debug-repeat \
    --port-base 18683 \
    --artifacts "$REPO_ROOT/_build/kernel-hwtest-qemu-debug-repeat" \
    "$RUNS" \
    env \
        KERNEL_QEMU_ELF="$REPO_ROOT/kernel/build/qemu/kernel-debug.elf" \
        KERNEL_QEMU_EXPECTED_VIEW_DIR="$REPO_ROOT/kernel/tests/qemu-debug/views" \
        bash "$REPO_ROOT/scripts/run_kernel_qemutest.sh"
