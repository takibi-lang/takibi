#!/usr/bin/env bash
# Injects a bare-metal ELF into a Raspberry Pi 5 (BCM2712) over SWD, using
# the official Raspberry Pi Debug Probe (CMSIS-DAP) -- see
# examples/common_rpi5/AGENTS.md for the full rationale. Adapted from
# scripts/rpi3_jtag_load.sh; the two real differences from RPi3 are: (1)
# transport is SWD via a CMSIS-DAP interface, not JTAG via a generic FTDI
# adapter, and (2) the target config (examples/common_rpi5/bcm2712.cfg) is
# vendored in this repo, since upstream OpenOCD 0.12.0 does not ship one.
#
# Safety check, CORRECTED from an initial RPi3-style "must be at EL2H"
# check that turned out to be unsound here: a live, real-hardware
# connectivity test (2026-07-25) halted this board and found it sitting at
# EL2H with MMU/D-cache/I-cache all enabled and PC at a canonical
# high-kernel-VA address (0xffffd0...) -- i.e. genuinely running
# Raspberry Pi OS, not our stub. RPi3's own "EL2H means safe" assumption
# relied on Linux always dropping to EL1 (true on BCM2837/Cortex-A53,
# ARMv8.0), but BCM2712's Cortex-A76 is ARMv8.1+ and supports VHE
# (Virtualization Host Extensions): a VHE-enabled Linux kernel runs its
# WHOLE normal kernel at EL2H (HCR_EL2.E2H=1) rather than dropping to EL1
# at all, which is the modern default on hardware that supports it. EL2H
# alone therefore does NOT distinguish live Raspberry Pi OS from our own
# code on this board.
#
# The real distinguishing signal is MMU state, not exception level: Stage A
# never calls mmu_init (see examples/common_rpi5/startup.S's header
# comment) for EITHER the jtag_stub or the real payload, so anything we
# ever inject at this stage always runs with the EL2 stage 1 MMU off,
# while genuine Raspberry Pi OS always runs with it on. OpenOCD's own halt
# report already prints "MMU: enabled"/"MMU: disabled" for aarch64
# targets, so this reuses that line rather than a separate register read.
# NOTE: once a future milestone adds mmu_init here (mirroring RPi3's own
# history), this check needs revisiting -- it will no longer distinguish
# "ours" from "live OS" once our own code also runs with the MMU on.
set -euo pipefail
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
mmu_state=$(grep -oE 'MMU: (enabled|disabled)' "$CHECK_LOG" | head -1 | awk '{print $2}')

if [ -z "$current_mode" ] || [ -z "$mmu_state" ]; then
    echo "error: could not parse current exception level / MMU state from openocd output -- log follows" >&2
    cat "$CHECK_LOG" >&2
    rm -f "$CHECK_LOG"
    exit 1
fi
rm -f "$CHECK_LOG"

if [ "$current_mode" != "EL2H" ] || [ "$mmu_state" != "disabled" ]; then
    echo "error: halted core is at $current_mode with MMU $mmu_state (PC=$halted_pc)" \
         "-- this looks like a genuinely running Raspberry Pi OS, not our" \
         "own stub/payload (BCM2712's Cortex-A76 supports VHE, so a live" \
         "kernel can itself be sitting at EL2H -- EL2H alone does not mean" \
         "safe here, unlike on RPi3; MMU-disabled is the real signal, see" \
         "this script's own header comment). Refusing to inject (would" \
         "corrupt the running OS). If kernel_2712.img on the SD card is" \
         "already examples/common_rpi5/jtag_stub.img, run" \
         "scripts/rpi5_jtag_reset.sh; otherwise flash it first and" \
         "power-cycle the board. (The board was left running exactly as" \
         "found -- this check only read/resumed, it never wrote anything.)" >&2
    exit 1
fi
echo "halted core is at EL2H with MMU disabled (PC=$halted_pc) -- safe to inject"

# Pass 2: only reached once the check above confirms a clean catch. Load the
# shared physical RAM through cpu3's debug context, then set/resume cpu0. A
# completed payload leaves cpu0 parked at .Lhalt, where this OpenOCD/aarch64
# combination can subsequently report a sticky debug abort when load_image
# itself uses cpu0. The other core reaches the same RAM without that stale
# cpu0 debug state; execution still starts exclusively on cpu0.
LOG=$(mktemp)
if ! openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'targets bcm2712.cpu0' \
    -c 'halt' \
    -c 'targets bcm2712.cpu3' \
    -c 'halt' \
    -c "load_image $ELF 0 elf" \
    -c 'targets bcm2712.cpu0' \
    -c "reg sp $stack_top" \
    -c "reg pc $entry_pc" \
    -c 'resume' \
    -c 'targets bcm2712.cpu3' \
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
