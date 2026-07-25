#!/usr/bin/env bash
# Prepares a Raspberry Pi 5 SD card's boot partition for SWD-only bring-up
# (examples/common_rpi5/AGENTS.md). Overlays exactly two things on top of
# an otherwise-untouched stock Raspberry Pi OS boot partition:
# kernel_2712.img (replaced with the spin stub) and one config.txt line.
# bootloader.bin/start4.elf/fixup4.dat/cmdline.txt/etc. are generic
# Raspberry Pi firmware already installed by the OS image and are never
# touched -- this project has no reason to vendor copies of them.
#
# DIFFERENT from scripts/rpi3_prepare_sdcard.sh in two real ways, both
# found the hard way (see examples/common_rpi5/AGENTS.md's "A real bug
# this port found" section): (1) RPi5 firmware prefers kernel_2712.img
# over kernel8.img when both are present -- overwriting only kernel8.img,
# the way rpi3_prepare_sdcard.sh does, leaves a stock Raspberry Pi OS
# image's own real kernel_2712.img in place and the board just boots the
# real OS, ignoring the stub entirely (confirmed: this is exactly what
# happened on a real board whose SD card had only been run through
# rpi3_prepare_sdcard.sh). (2) RPi5's config.txt needs `os_check=0`, not
# RPi3's `enable_jtag_gpio=1`/`dtoverlay=disable-bt` (those are specific
# to RPi3's repurposed 6-pin GPIO JTAG header and Bluetooth UART conflict;
# irrelevant to RPi5's dedicated SWD debug connector).
#
# Usage: scripts/rpi5_prepare_sdcard.sh /path/to/mounted/boot/partition
#
# Run wherever the SD card's boot partition is actually mounted (see
# scripts/rpi3_prepare_sdcard.sh's own header comment for why that's
# normally the host, not inside this container).
#
# Idempotent and safe to re-run: the original kernel_2712.img (if present)
# is backed up once, on first run, to kernel_2712.img.orig (restore
# Raspberry Pi OS later with `cp kernel_2712.img.orig kernel_2712.img`);
# the config.txt line is only appended if not already present.
set -euo pipefail

BOOT="${1:?usage: $0 /path/to/mounted/boot/partition}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$REPO_ROOT/examples/common_rpi5/jtag_stub.img"

if [ ! -f "$STUB" ]; then
    echo "error: $STUB not found -- build it first:" >&2
    echo "  make examples/common_rpi5/jtag_stub.img" >&2
    exit 1
fi

if [ ! -d "$BOOT" ]; then
    echo "error: $BOOT is not a directory -- is the SD card's boot partition mounted there?" >&2
    exit 1
fi

if [ ! -f "$BOOT/config.txt" ]; then
    echo "error: $BOOT/config.txt not found -- is this really the boot partition of a" >&2
    echo "Raspberry Pi OS SD card?" >&2
    exit 1
fi

if [ -f "$BOOT/kernel_2712.img" ] && [ ! -f "$BOOT/kernel_2712.img.orig" ]; then
    cp "$BOOT/kernel_2712.img" "$BOOT/kernel_2712.img.orig"
    echo "backed up original kernel_2712.img -> kernel_2712.img.orig"
fi

cp "$STUB" "$BOOT/kernel_2712.img"
echo "installed jtag_stub.img as kernel_2712.img"

for line in "os_check=0"; do
    if grep -qxF "$line" "$BOOT/config.txt"; then
        echo "already present in config.txt: $line"
    else
        echo "$line" >> "$BOOT/config.txt"
        echo "added to config.txt: $line"
    fi
done

echo "done -- power-cycle the board to boot the spin stub"
