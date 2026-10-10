#!/usr/bin/env bash
# Hold the board lease across the four physical GEM ownership controls.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_GEM_TX_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/gem-tx-rpi5}"
export KERNEL_GEM_TX_ARTIFACT_DIR="$ARTIFACT_DIR"
. "$REPO_ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "kernelcheck-gem-tx-rpi5" || exit 1
export RPI5_SWD_SPEED="${RPI5_SWD_SPEED:-30000}"
python3 "$REPO_ROOT/scripts/run_kernel_gem_tx_rpi5.py" "$@"
