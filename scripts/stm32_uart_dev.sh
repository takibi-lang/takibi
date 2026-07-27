#!/usr/bin/env bash
# Resolve the STM32 ST-Link VCP UART by its USB identity. ttyACM numbers are
# assigned by enumeration order and can swap with the Raspberry Pi Debug
# Probe between reboots/reconnects.
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
        *STMicroelectronics*STM32*STLink*) candidates+=("$target") ;;
    esac
done

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "error: no STM32 ST-Link ttyACM device found under $BY_ID_DIR" >&2
    exit 1
elif [ "${#candidates[@]}" -gt 1 ]; then
    echo "error: multiple STM32 ST-Link ttyACM devices found: ${candidates[*]}" >&2
    exit 1
fi

echo "${candidates[0]}"
