#!/usr/bin/env bash
# Keep the board lease outside the bounded interactive-shell smoke session.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_RPI5_SHELL_SMOKE_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-shell-smoke-rpi5}"
export KERNEL_RPI5_SHELL_SMOKE_ARTIFACT_DIR="$ARTIFACT_DIR"
. "$REPO_ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "kernelcheck-shell-rpi5" || exit 1
echo '[kernel/rpi5 shell smoke] WARNING: the shell rootfs overwrites the attached USB drive. Use only the dedicated sacrificial test drive.'
timeout --foreground 300 python3 "$REPO_ROOT/scripts/run_kernel_shell_rpi5_smoketest.py"
