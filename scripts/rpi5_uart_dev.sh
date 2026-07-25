#!/usr/bin/env bash
# Resolves the /dev-host/ttyACM* device that is the Raspberry Pi Debug
# Probe's UART cable, as opposed to the STM32 board's own ST-Link VCP --
# both now show up as ttyACM* nodes on this host (confirmed: ttyACM0/
# ttyACM1 have swapped meaning across at least one reboot already), so,
# same reasoning as scripts/rpi_uart_dev.sh (RPi3 vs the Olimex JTAG
# probe's own secondary ttyUSB channel), identify by /dev/serial/by-id
# label (built by udev from the USB device's own vendor/product string,
# stable across replug/enumeration order), never by ttyACM number.
set -euo pipefail

BY_ID_DIR=/dev-host/serial/by-id

if [ ! -d "$BY_ID_DIR" ]; then
    echo "error: $BY_ID_DIR not found" >&2
    exit 1
fi

candidates=()
for link in "$BY_ID_DIR"/usb-*; do
    [ -e "$link" ] || continue
    target=$(readlink -f "$link")
    case "$target" in
        */ttyACM*) ;;
        *) continue ;;
    esac
    case "$(basename "$link")" in
        *Raspberry_Pi_Debug_Probe*) candidates+=("$target") ;;
    esac
done

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "error: no Raspberry Pi Debug Probe ttyACM device found under $BY_ID_DIR" >&2
    exit 1
elif [ "${#candidates[@]}" -gt 1 ]; then
    echo "error: multiple candidate ttyACM devices found, ambiguous: ${candidates[*]}" >&2
    exit 1
fi

echo "${candidates[0]}"
