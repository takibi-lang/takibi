#!/usr/bin/env bash
# Triggers a full BCM2837 chip reset via JTAG, using the watchdog-reset
# mechanism poked directly through OpenOCD memory writes. This is a warm
# SoC reboot -- the same mechanism Linux's own `reboot` goes through on
# this board (see below) -- NOT equivalent to a physical power cycle: the
# GPU firmware does rerun from scratch (re-reading config.txt and
# kernel8.img off the SD card) and every ARM core/peripheral register on
# the SoC itself returns to its power-on-reset state, but board-level 5V
# stays up throughout, so anything only reset by actually removing power
# is NOT reset by this -- confirmed empirically: a USB Mass Storage
# drive's own file content survives this reset untouched (issue #145's
# fatfs-family hardware tests rely on exactly that -- provisioning it
# once and reading it back after a deliberate reset is how
# kvs_server_sdcard_rtos's persistence-survives-a-reset check works).
# Still achievable entirely over JTAG, no physical access needed, and
# still useful for recovering from any uncertain/bad SoC-side CPU/
# peripheral state (see examples/common_rpi3/AGENTS.md) without asking a
# human to unplug/replug power every time -- just don't reach for it
# expecting attached USB devices to also come back to a truly cold state.
#
# This is the SAME mechanism Linux's own bcm2835_wdt driver and
# U-Boot's bcm2835 reset driver use for `reboot`: arm PM_WDOG with a
# short timeout, then PM_RSTC with the "full reset" config, both gated
# by the fixed PM_PASSWORD magic value the PM block requires in the top
# byte of any write to that block -- a write without it is silently
# ignored by the hardware, not risky.
#
# Unlike scripts/rpi3_jtag_load.sh's safety check (which refuses to
# inject unless the halted core is already at EL2H, i.e. already one of
# ours), this script does NOT check what's currently running before
# resetting -- it is explicitly a "start over" operation. Don't run it
# against a board you intend to keep a live Raspbian session on.
set -euo pipefail

PM_PASSWORD=0x5a000000
PM_RSTC=0x3F10001C
PM_WDOG=0x3F100024
PM_RSTC_WRCFG_FULL_RESET=0x00000020
WDOG_TICKS=10   # short timeout (a few hundred microseconds); this
                # script's own openocd session has already finished and
                # exited well before the watchdog fires

wdog_value=$(( PM_PASSWORD | WDOG_TICKS ))
rstc_value=$(( PM_PASSWORD | PM_RSTC_WRCFG_FULL_RESET ))

OPENOCD_ARGS=(
    -f interface/ftdi/olimex-arm-usb-tiny-h.cfg
    -c 'transport select jtag'
    -f target/bcm2837.cfg
    -c 'adapter speed 1000'
)

# The watchdog fires DURING this openocd session (WDOG_TICKS is short
# enough that the chip starts resetting before this session's own `mww`
# calls finish exchanging JTAG traffic), so this session almost always
# ends with "Invalid ACK"/"JTAG-DP STICKY ERROR" and a non-zero openocd
# exit status -- confirmed to correlate with a SUCCESSFUL reset, not a
# failed one (the DAP simply can't hold a stable connection to a chip
# that is actively resetting underneath it). Ignoring that exit status
# here is deliberate; the real verification is the reconnect below,
# once the reset has had time to complete.
openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c "mww $PM_WDOG $wdog_value" \
    -c "mww $PM_RSTC $rstc_value" \
    -c 'shutdown' > /dev/null 2>&1 || true

# Full SD-card boot (bootcode.bin -> start.elf -> reads config.txt ->
# loads kernel8.img) takes noticeably longer than the watchdog reset
# itself -- confirmed empirically: reconnecting after only 2s hit "JTAG
# scan chain interrogation failed: all ones" (the chip mid-boot, not
# yet responding to JTAG at all). Poll instead of a single fixed sleep.
VERIFY_LOG=$(mktemp)
attempt=0
max_attempts=15
until openocd "${OPENOCD_ARGS[@]}" \
    -c 'init' \
    -c 'halt' \
    -c 'reg pc' \
    -c 'shutdown' > "$VERIFY_LOG" 2>&1
do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "error: could not reconnect after reset ($max_attempts attempts) -- log follows" >&2
        cat "$VERIFY_LOG" >&2
        rm -f "$VERIFY_LOG"
        exit 1
    fi
    sleep 1
done

halted_pc=$(awk '/^pc \(/{print $3}' "$VERIFY_LOG" | head -1)
current_mode=$(grep -oE 'current mode: EL[0-9][A-Za-z]' "$VERIFY_LOG" | head -1 | awk '{print $3}')
rm -f "$VERIFY_LOG"

if [ "$current_mode" = "EL2H" ] && [ "$halted_pc" = "0x0000000000080004" ]; then
    echo "reset confirmed: back in examples/common_rpi3/jtag_stub.S's spin loop (PC=$halted_pc)"
else
    echo "warning: reconnected, but PC=$halted_pc mode=$current_mode does not look like" \
         "the spin stub -- reset may not have fully completed, or kernel8.img on the" \
         "SD card is no longer jtag_stub.img" >&2
    exit 1
fi
