#!/usr/bin/env bash
# Reboots the RPi5 board via a PSCI SYSTEM_RESET SMC call issued from a
# tiny 2-instruction trampoline injected over SWD -- see
# examples/common_rpi5/AGENTS.md.
#
# REPLACES an earlier version that used OpenOCD's generic `reset halt`,
# which failed with "bcm2712.cpu0: how to reset?" when actually tried
# (2026-07-25): the official Debug Probe's SWD wiring does not carry the
# SoC's nSRST signal, and examples/common_rpi5/bcm2712.cfg defines no
# BCM2712-specific reset handler, so OpenOCD's SRST-based `reset` has
# nothing to drive. PSCI SYSTEM_RESET sidesteps this entirely: BCM2712's
# own device tree declares PSCI with method "smc", and TF-A (already
# confirmed present -- see scripts/rpi5_jtag_load.sh's own EL2-handoff
# research) implements the standard ARM PSCI firmware interface at EL3
# regardless of which lower EL issues the call, so an `smc` from our
# EL2H stub/payload reaches it the same way Linux's own `reboot` does.
# Confirmed working live (2026-07-25): reconnected within ~2-3 seconds,
# landed back in the jtag_stub.S spin loop, a real full firmware reboot
# (config.txt/kernel_2712.img both reread from the SD card), not merely
# a CPU-local restart.
#
# WARNING: like RPi3's watchdog-based reset, this really does reboot the
# whole SoC -- do not run this against a board you intend to keep a live
# Raspberry Pi OS session on (see scripts/rpi5_jtag_load.sh's own header
# comment on why "halted at EL2H" alone cannot rule that out on this
# board, due to VHE).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"

OPENOCD_ARGS=(
    -f interface/cmsis-dap.cfg
    -f "$BCM2712_CFG"
)

# PSCI SYSTEM_RESET (function ID 0x84000009) via `smc #0` (encoding
# 0xd4000003), immediately followed by `b .` (0x14000000) as a landing
# pad in case the SMC ever returns instead of actually resetting.
# Injected at a fixed, always-unused RAM address (0x00100000 -- between
# jtag_stub.ld's 0x80000 and link.ld's 0x200000, clear of both) rather
# than requiring a real ELF load. `reg x0` sets the PSCI function ID
# argument directly; OpenOCD's own SWD session is expected to drop the
# instant the SMC actually reboots the SoC, so its exit status is
# deliberately ignored, same reasoning as RPi3's watchdog-reset script.
RESET_ADDR=0x00100000
PSCI_SYSTEM_RESET=0x84000009

openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c "mww $RESET_ADDR 0xd4000003" \
    -c "mww $((RESET_ADDR + 4)) 0x14000000" \
    -c "reg x0 $PSCI_SYSTEM_RESET" \
    -c "reg pc $RESET_ADDR" \
    -c 'resume' \
    -c 'shutdown' > /dev/null 2>&1 || true

# Full SD-card boot (EEPROM -> TF-A -> config.txt -> kernel_2712.img)
# takes noticeably longer than the reset itself -- poll instead of a
# single fixed sleep, same pattern as scripts/rpi3_jtag_reset.sh.
VERIFY_LOG=$(mktemp)
attempt=0
max_attempts=20
until openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c 'reg pc' \
    -c 'shutdown' > "$VERIFY_LOG" 2>&1
do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "error: could not reconnect after PSCI reset ($max_attempts attempts) -- log follows" >&2
        cat "$VERIFY_LOG" >&2
        rm -f "$VERIFY_LOG"
        exit 1
    fi
    sleep 1
done

halted_pc=$(awk '/^pc \(/{print $3}' "$VERIFY_LOG" | head -1)
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$VERIFY_LOG" | head -1 | awk '{print $3}')
mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$VERIFY_LOG" | head -1 | awk '{print $2}')
rm -f "$VERIFY_LOG"

# jtag_stub.S's spin loop is exactly 2 instructions (wfe; b .Lspin) at
# 0x80000/0x80004 -- either address is a valid catch point depending on
# exactly when this reconnected, unlike an earlier version of this script
# that only accepted the first instruction's exact address.
if [ "$current_mode" = "EL2H" ] && [ "$mmu_state" = "disabled" ] && { [ "$halted_pc" = "0x0000000000080000" ] || [ "$halted_pc" = "0x0000000000080004" ]; }; then
    echo "reset confirmed: back in examples/common_rpi5/jtag_stub.S's spin loop (PC=$halted_pc)"
else
    echo "warning: reset halted, but PC=$halted_pc mode=$current_mode MMU=$mmu_state does not look" \
         "like the spin stub -- either the reset did not reboot the SoC (in which case this" \
         "just halted whatever was already running -- possibly a live Raspberry Pi OS, see" \
         "scripts/rpi5_jtag_load.sh's header comment on VHE), or kernel_2712.img on the SD card" \
         "is not examples/common_rpi5/jtag_stub.img" >&2
    exit 1
fi
