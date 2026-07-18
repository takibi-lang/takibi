#!/usr/bin/env bash
# Prepares a Raspberry Pi 3B SD card's boot partition for JTAG-only
# bring-up (examples/common_rpi3/AGENTS.md). Overlays exactly two
# things on top of an otherwise-untouched stock Raspberry Pi OS boot
# partition: kernel8.img (replaced with the spin stub) and two
# config.txt lines. bootcode.bin/start.elf/fixup.dat/cmdline.txt/etc.
# are generic Raspberry Pi firmware already installed by the OS image
# and are never touched -- this project has no reason to vendor copies
# of them.
#
# Usage: scripts/rpi3_prepare_sdcard.sh /path/to/mounted/boot/partition
#
# Run wherever the SD card's boot partition is actually mounted. This
# devcontainer has no access to a raw SD card reader (see
# examples/common_rpi3/AGENTS.md's hardware section) -- in practice that
# means the host, not inside this container. The repo checkout this
# script and jtag_stub.img live in is expected to be reachable from
# wherever this runs (e.g. a shared devcontainer workspace bind mount).
#
# Idempotent and safe to re-run: the original kernel8.img is backed up
# once, on first run, to kernel8.img.orig (restore Raspbian later with
# `cp kernel8.img.orig kernel8.img`); config.txt lines are only appended
# if not already present.
set -euo pipefail

BOOT="${1:?usage: $0 /path/to/mounted/boot/partition}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$REPO_ROOT/examples/common_rpi3/jtag_stub.img"

if [ ! -f "$STUB" ]; then
    echo "error: $STUB not found -- build it first:" >&2
    echo "  make examples/common_rpi3/jtag_stub.img" >&2
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

if [ -f "$BOOT/kernel8.img" ] && [ ! -f "$BOOT/kernel8.img.orig" ]; then
    cp "$BOOT/kernel8.img" "$BOOT/kernel8.img.orig"
    echo "backed up original kernel8.img -> kernel8.img.orig"
fi

cp "$STUB" "$BOOT/kernel8.img"
echo "installed jtag_stub.img as kernel8.img"

for line in "enable_jtag_gpio=1" "dtoverlay=disable-bt"; do
    if grep -qxF "$line" "$BOOT/config.txt"; then
        echo "already present in config.txt: $line"
    else
        echo "$line" >> "$BOOT/config.txt"
        echo "added to config.txt: $line"
    fi
done

echo "done -- power-cycle the board to boot the spin stub"
