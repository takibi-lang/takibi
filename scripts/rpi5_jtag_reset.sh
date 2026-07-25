#!/usr/bin/env bash
# Attempts a full BCM2712 chip reset via the Debug Probe's SWD connection --
# see examples/common_rpi5/AGENTS.md.
#
# UNCONFIRMED / exploratory, unlike scripts/rpi3_jtag_reset.sh (which uses a
# well-documented BCM2835-family watchdog-register trick -- Broadcom's own
# peripheral datasheet and Linux's bcm2835_wdt driver confirm those PM_RSTC/
# PM_WDOG addresses; no equivalent primary source was found for BCM2712's
# reset controller while researching this port). Rather than guess an MMIO
# address on an unfamiliar SoC's power-management block, this script uses
# OpenOCD's own generic `reset halt`, which relies on the adapter's SRST
# line. Whether that line is actually wired on the official Debug Probe's
# dedicated connector (unlike RPi3's 6-pin GPIO header, which has none) is
# exactly what running this script once will tell us.
#
# If this errors with something like "bcm2712.cpu0: how to reset?", the
# vendored examples/common_rpi5/bcm2712.cfg needs an explicit
# `reset_config` line added (community reports mention
# `trst_and_srst trst_pulls_srst` or commenting out `srst_nogate`
# variants) before this script can work at all -- do not paper over that
# by falling back to an unconfirmed register poke instead.
#
# WARNING: `reset halt` really does reboot the whole SoC (unlike
# scripts/rpi5_jtag_load.sh's read-only check pass) -- do not run this
# against a board you intend to keep a live Raspberry Pi OS session on.
# A live connectivity test (2026-07-25) confirmed this board's core can be
# genuinely running Raspberry Pi OS at EL2H (see scripts/
# rpi5_jtag_load.sh's header comment on VHE) -- the post-reset check below
# requires BOTH an exact PC match to the stub's own entry AND MMU
# disabled, not EL2H alone, for the same VHE-related reason.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"

OPENOCD_ARGS=(
    -f interface/cmsis-dap.cfg
    -f "$BCM2712_CFG"
)

VERIFY_LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'reset halt' \
    -c 'reg pc' \
    -c 'shutdown' > "$VERIFY_LOG" 2>&1
then
    echo "error: 'reset halt' failed -- log follows (see this script's" \
         "header comment: bcm2712.cfg likely needs an explicit" \
         "reset_config line before SRST works over this adapter)" >&2
    cat "$VERIFY_LOG" >&2
    rm -f "$VERIFY_LOG"
    exit 1
fi

halted_pc=$(awk '/^pc \(/{print $3}' "$VERIFY_LOG" | head -1)
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$VERIFY_LOG" | head -1 | awk '{print $3}')
mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$VERIFY_LOG" | head -1 | awk '{print $2}')
rm -f "$VERIFY_LOG"

if [ "$current_mode" = "EL2H" ] && [ "$mmu_state" = "disabled" ] && [ "$halted_pc" = "0x0000000000080000" ]; then
    echo "reset confirmed: back in examples/common_rpi5/jtag_stub.S's spin loop (PC=$halted_pc)"
else
    echo "warning: reset halted, but PC=$halted_pc mode=$current_mode MMU=$mmu_state does not look" \
         "like the spin stub -- either the reset did not reboot the SoC (in which case this" \
         "just halted whatever was already running -- possibly a live Raspberry Pi OS, see" \
         "scripts/rpi5_jtag_load.sh's header comment on VHE), or kernel_2712.img on the SD card" \
         "is not examples/common_rpi5/jtag_stub.img" >&2
    exit 1
fi
