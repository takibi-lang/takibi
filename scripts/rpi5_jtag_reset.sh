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
# Confirmed working for CPU-local restarts (2026-07-25): reconnects
# within ~2-3 seconds (sometimes briefly passing through a mid-boot state
# around PC 0x9c before settling), landing back in whatever
# kernel_2712.img was ALREADY resident. Genuinely reboots the CPU/core
# complex, unlike a plain debug halt.
#
# CORRECTED, same day: an earlier version of this comment claimed this
# also reliably reloads a DIFFERENT kernel_2712.img after swapping the
# SD card's file -- that was WRONG. Confirmed the hard way: swapped
# kernel_2712.img from Linux back to jtag_stub.img on the SD card (file
# size on disk verified 8 bytes), ran this script, and it landed back in
# Linux again (PC at a canonical high VA), not the stub -- meaning this
# reset path does NOT reliably re-read the SD card's current file the way
# a real power cycle does; it appears to replay whatever kernel image is
# already resident (DRAM-cached, or the firmware/EEPROM's own boot
# staging skips a fresh SD read on this kind of warm reset). Use this
# script freely to re-run the SAME kernel_2712.img (e.g. between
# `rp1_pcie_smoke` iterations while it stays the stub) -- but after
# swapping the SD card's file to something DIFFERENT, a real physical
# power cycle is still required.
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
#
# The `mww` trampoline writes go through cpu3's debug context, and only
# cpu0's own x0/pc/resume go through cpu0's -- found the hard way
# (GitHub issue #165 real-hardware session, 2026-07-25): writing through
# cpu0 directly repeatedly left this script unable to reconnect to a
# real spin-loop stub after supposedly succeeding (kept reporting the
# SAME pre-reset PC back, meaning the reset silently never ran). This is
# the exact "cpu0 sticky debug abort after a completed payload" hazard
# scripts/rpi5_jtag_load.sh's own load pass already works around by
# writing through cpu3 instead -- this script needed the identical fix,
# just never got it when first written, since it does its own separate
# `mww` writes rather than reusing rpi5_jtag_load.sh's load_image path.
# Force cpu0's debug-restored PSTATE to masked EL2H before executing the
# trampoline. Payloads such as el0_shell deliberately finish at EL1; simply
# replacing their PC with an SMC instruction would issue that SMC from EL1
# and did not reliably reach the resident TF-A reset service on this board.
# The injected address is identity-mapped by every Takibi EL2 table, so this
# is valid whether the interrupted payload had its EL2 MMU enabled or not.
RESET_ADDR=0x00100000
PSCI_SYSTEM_RESET=0x84000009

openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu3' \
    -c 'halt' \
    -c "mww $RESET_ADDR 0xd4000003" \
    -c "mww $((RESET_ADDR + 4)) 0x14000000" \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c 'reg cpsr 0x3c9' \
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
