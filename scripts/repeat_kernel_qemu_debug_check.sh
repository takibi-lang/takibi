#!/usr/bin/env bash
# Repeat the timing-sensitive DWARF QEMU lane without overwriting an earlier
# boot's evidence. The ordinary runner is still the single source of verdicts;
# this wrapper only gives each sample its own label and artifact directory.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${KERNEL_QEMU_DEBUG_REPEAT:-5}"

case "$RUNS" in
    ''|*[!0-9]*|0)
        echo "error: KERNEL_QEMU_DEBUG_REPEAT must be a positive integer" >&2
        exit 2
        ;;
esac

run=1
while [ "$run" -le "$RUNS" ]; do
    artifact_dir="$REPO_ROOT/_build/kernel-hwtest-qemu-debug-repeat-$run"
    echo "[kernel/qemu-debug-repeat] sample $run/$RUNS"
    env \
        KERNEL_QEMU_ELF="$REPO_ROOT/kernel/build/qemu/kernel-debug.elf" \
        KERNEL_QEMU_LABEL="qemu-debug-repeat-$run" \
        KERNEL_QEMU_EXPECTED_VIEW_DIR="$REPO_ROOT/kernel/tests/qemu-debug/views" \
        KERNEL_QEMU_HWTEST_ARTIFACT_DIR="$artifact_dir" \
        KERNEL_QEMU_SERIAL_PORT=18683 \
        KERNEL_QEMU_NETDEV_LOCAL_PORT=18684 \
        KERNEL_QEMU_NETDEV_REMOTE_PORT=18685 \
        bash "$REPO_ROOT/scripts/run_kernel_qemutest.sh"
    run=$((run + 1))
done

echo "PASS kernel/qemu-debug-repeat: $RUNS independent boots"
