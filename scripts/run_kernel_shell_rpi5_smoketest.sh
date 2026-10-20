#!/usr/bin/env bash
# Keep the board lease outside the bounded interactive-shell smoke session.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_RPI5_SHELL_SMOKE_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-shell-smoke-rpi5}"
export KERNEL_RPI5_SHELL_SMOKE_ARTIFACT_DIR="$ARTIFACT_DIR"
. "$REPO_ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "kernelcheck-shell-rpi5" || exit 1
# GitHub issue #877: a failing run's capture was overwritten by the next run
# before anyone read it. Snapshot it on any nonzero exit. Armed after the
# lease, so a refused lease does not archive the previous run's capture.
archive_on_failure() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        KERNEL_QEMU_LABEL="kernel-shell-smoke-rpi5" KERNEL_QEMU_ELF="${ELF:-unknown}" \
            bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" \
            "$REPO_ROOT/_build/kernel-shell-smoke-rpi5-failures" "exit status $status" || true
    fi
    return "$status"
}
trap archive_on_failure EXIT
echo '[kernel/rpi5 shell smoke] WARNING: the shell rootfs overwrites the attached USB drive. Use only the dedicated sacrificial test drive.'
timeout --foreground 300 python3 "$REPO_ROOT/scripts/run_kernel_shell_rpi5_smoketest.py"
