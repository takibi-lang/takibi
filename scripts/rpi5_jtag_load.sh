#!/usr/bin/env bash
# Injects a bare-metal ELF into a Raspberry Pi 5 (BCM2712) over SWD, using
# the official Raspberry Pi Debug Probe (CMSIS-DAP) -- see
# examples/common_rpi5/AGENTS.md for the full rationale. Adapted from
# scripts/rpi3_jtag_load.sh; the two real differences from RPi3 are: (1)
# transport is SWD via a CMSIS-DAP interface, not JTAG via a generic FTDI
# adapter, and (2) the target config (examples/common_rpi5/bcm2712.cfg) is
# vendored in this repo, since upstream OpenOCD 0.12.0 does not ship one.
#
# Same safety check as RPi3: refuses to inject unless the halted core is at
# EL2H (a live Raspbian boot always halts at EL1H, since Linux runs the
# kernel at EL1 -- and Trusted Firmware-A's own rpi5 platform docs confirm
# BL31 hands 64-bit payloads off at EL2, same as RPi3's GPU firmware, so
# this check is expected to carry over unchanged). UNCONFIRMED as of this
# writing: everything below has not yet been run against real RPi5
# hardware -- this is Stage A's first real-hardware attempt, not a proven
# script.
set -euo pipefail

ELF="${1:-examples/start/kernel_rpi5.elf}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BCM2712_CFG="$REPO_ROOT/examples/common_rpi5/bcm2712.cfg"

if [ ! -f "$ELF" ]; then
    echo "error: $ELF not found -- build it first (make $ELF)" >&2
    exit 1
fi

entry_pc="0x$(llvm-readelf-19 -h "$ELF" | awk '/Entry point address/{sub(/^0x/,"",$NF); print $NF}')"
stack_top="0x$(llvm-nm-19 "$ELF" | awk '$3=="stack_top"{print $1}')"

if [ -z "${entry_pc#0x}" ] || [ -z "${stack_top#0x}" ]; then
    echo "error: could not read entry point / stack_top from $ELF" >&2
    exit 1
fi

echo "target ELF:  $ELF"
echo "entry PC:    $entry_pc"
echo "initial SP:  $stack_top"

OPENOCD_ARGS=(
    -f interface/cmsis-dap.cfg
    -f "$BCM2712_CFG"
)

# Pass 1: halt, read PC + current exception level, resume immediately --
# read-only, same reasoning as rpi3_jtag_load.sh's own check pass.
CHECK_LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c 'reg pc' \
    -c 'resume' \
    -c 'shutdown' > "$CHECK_LOG" 2>&1
then
    echo "error: openocd failed during PC/EL check -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi

halted_pc=$(awk '/^pc \(/{print $3}' "$CHECK_LOG" | head -1)
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$CHECK_LOG" | head -1 | awk '{print $3}')
rm -f "$CHECK_LOG"

if [ -z "$current_mode" ]; then
    echo "error: could not parse current exception level from openocd output -- log follows" >&2
    cat "$CHECK_LOG" >&2
    exit 1
fi

if [ "$current_mode" != "EL2H" ]; then
    echo "error: halted core is at $current_mode, not EL2H (PC=$halted_pc)" \
         "-- this is almost certainly still-running Raspberry Pi OS (Linux" \
         "always runs at EL1), not a bare-metal payload. Refusing to" \
         "inject (would corrupt the running OS). If kernel_2712.img on the" \
         "SD card is already examples/common_rpi5/jtag_stub.img, run" \
         "scripts/rpi5_jtag_reset.sh; otherwise flash it first and" \
         "power-cycle the board. (The board was left running exactly as" \
         "found -- this check only read/resumed, it never wrote anything.)" >&2
    exit 1
fi
echo "halted core is at EL2H (PC=$halted_pc) -- safe to inject"

# Pass 2: only reached once the check above confirms a clean catch.
LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c "load_image $ELF 0 elf" \
    -c "reg sp $stack_top" \
    -c "reg pc $entry_pc" \
    -c 'resume' \
    -c 'shutdown' > "$LOG" 2>&1
then
    echo "error: openocd failed during injection -- log follows" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi

echo "injected $ELF and resumed (PC=$entry_pc SP=$stack_top)"
cat "$LOG"
rm -f "$LOG"
