#!/usr/bin/env bash
# Resolves the /dev-host/ttyUSB* device that carries the Raspberry Pi's
# console UART, as opposed to the OpenOCD JTAG probe's own auxiliary
# UART channel (see AGENTS.md's Raspberry Pi section for the reasoning:
# JTAG needs 4 signal lines (TCK/TMS/TDI/TDO); a plain ttyUSB only
# exposes 2 (TX/RX), so no ttyUSB device can ever carry JTAG traffic --
# openocd talks to the probe over raw USB (libusb), not through any
# ttyUSB node. The Olimex ARM-USB-TINY-H probe used here additionally
# exposes its own secondary UART channel as a ttyUSB device, which must
# be excluded by name (from its /dev/serial/by-id label), not by device
# number: USB enumeration order (ttyUSB0 vs ttyUSB1) is not stable
# across replug/container-recreate.
set -euo pipefail

BY_ID_DIR=/dev-host/serial/by-id

if [ ! -d "$BY_ID_DIR" ]; then
    echo "error: $BY_ID_DIR not found" >&2
    exit 1
fi

declare -A seen=()
candidates=()
for link in "$BY_ID_DIR"/usb-*; do
    [ -e "$link" ] || continue
    target=$(readlink -f "$link")
    case "$target" in
        */ttyUSB*) ;;
        *) continue ;;
    esac
    case "$(basename "$link")" in
        *JTAG*|*jtag*) continue ;;
    esac
    if [ -z "${seen[$target]+x}" ]; then
        seen[$target]=1
        candidates+=("$target")
    fi
done

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "error: no non-JTAG ttyUSB device found under $BY_ID_DIR" >&2
    exit 1
elif [ "${#candidates[@]}" -gt 1 ]; then
    echo "error: multiple candidate ttyUSB devices found, ambiguous: ${candidates[*]}" >&2
    exit 1
fi

echo "${candidates[0]}"
