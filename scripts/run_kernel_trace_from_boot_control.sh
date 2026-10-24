#!/usr/bin/env bash
# Negative control for kernelcheck-qemu-debug-main's trace-from-boot variant
# (GitHub issue #965): a trace-on boot that cannot pass must fail the lane.
#
# The boot is the debug-main one with KERNEL_QEMU_TRACE_FROM_BOOT=
# fail_after_exec, which also sets the debugger-owned fail-after-exec switch:
# the first real exec commit fail-stops the kernel. If the runner passed
# that, the lane would be blind to a trace that breaks the suite. Run on
# demand (`make kernelcheck-trace-from-boot-control`), not in allcheck: it
# costs a boot, and what it guards -- the runner's verdict wiring -- changes
# only with scripts/run_kernel_qemutest.sh. The cheap half, the verify
# step's verdict, is scripts/check_kernel_trace_from_boot_controls.py.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_TRACE_CONTROL_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-hwtest-qemu-trace-control}"
LOG="$ARTIFACT_DIR/control.log"
mkdir -p "$ARTIFACT_DIR"
# A control that wrongly passed or failed for the wrong reason must keep its
# capture (#877): snapshot it on any nonzero exit.
archive_on_failure() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        KERNEL_QEMU_LABEL="qemu-trace-control" \
            KERNEL_QEMU_ELF="$REPO_ROOT/kernel/build/qemu/kernel-debug.elf" \
            bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" \
            "$REPO_ROOT/_build/kernel-hwtest-qemu-trace-control-failures" \
            "exit status $status" || true
    fi
    return "$status"
}
trap archive_on_failure EXIT

status=0
env KERNEL_QEMU_TRACE_FROM_BOOT=fail_after_exec \
    KERNEL_QEMU_TIMEOUT="${KERNEL_QEMU_TIMEOUT:-30}" \
    KERNEL_QEMU_ELF="$REPO_ROOT/kernel/build/qemu/kernel-debug.elf" \
    KERNEL_QEMU_LABEL=qemu-trace-control \
    KERNEL_QEMU_HWTEST_ARTIFACT_DIR="$ARTIFACT_DIR/boot" \
    KERNEL_QEMU_SERIAL_PORT=18683 KERNEL_QEMU_QMP_PORT=18678 \
    KERNEL_QEMU_NETDEV_LOCAL_PORT=18684 KERNEL_QEMU_NETDEV_REMOTE_PORT=18685 \
    bash "$REPO_ROOT/scripts/run_kernel_qemutest.sh" >"$LOG" 2>&1 || status=$?

if [ "$status" -eq 0 ]; then
    sed 's/^/  /' "$LOG" >&2
    echo "FAIL trace-from-boot-control: a trace-on boot that fail-stops after exec passed the suite" >&2
    exit 1
fi
# It must fail for the planted reason, not because it never armed.
if ! grep -q 'trace-from-boot armed boot=1 live=1' \
        "$ARTIFACT_DIR/boot/trace-from-boot.log"; then
    sed 's/^/  /' "$LOG" >&2
    echo "FAIL trace-from-boot-control: the boot failed before the trace was armed" >&2
    exit 1
fi
echo "PASS trace-from-boot-control: the armed fail-after-exec boot failed the suite (exit $status)"
