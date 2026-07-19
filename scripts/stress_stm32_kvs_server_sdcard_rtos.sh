#!/usr/bin/env bash
# Explicit STM32 KVS+SD+RTOS stress runner.
#
# This is intentionally NOT part of make allcheck: it is a sustained real-
# board load test, not a deterministic integration test. Concurrency 4 matches
# the server's TCP slot count; larger values deliberately test overload.
set -euo pipefail

: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run through make or set it explicitly}"

OPENOCD_BOARD_CFG="board/stm32f746g-disco.cfg"
ELF="${TAKIBI_STRESS_ELF:-examples/kvs_server_sdcard_rtos/kernel_stm32_ram.elf}"
HOST="${TAKIBI_STRESS_HOST:-192.168.10.2}"
PORT="${TAKIBI_STRESS_PORT:-80}"
CONCURRENCY="${TAKIBI_STRESS_CONCURRENCY:-4}"
DURATION="${TAKIBI_STRESS_DURATION:-30}"
VALUE_SIZE="${TAKIBI_STRESS_VALUE_SIZE:-64}"
TIMEOUT="${TAKIBI_STRESS_TIMEOUT:-5}"
FIXED_KEY="${TAKIBI_STRESS_FIXED_KEY:-profkey}"
PUT_RATIO="${TAKIBI_STRESS_PUT_RATIO:-0.5}"
GET_RATIO="${TAKIBI_STRESS_GET_RATIO:-0.4}"
DELETE_RATIO="${TAKIBI_STRESS_DELETE_RATIO:-0}"

# shellcheck source=scripts/stm32_hw_claim.sh
source "$(dirname "$0")/stm32_hw_claim.sh"
claim_stm32_hardware "$STM32_SERIAL_DEV"

tmpdir=$(mktemp -d)
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

ram_load_and_run() {
    local elf="$1" log
    log="$tmpdir/openocd-load.log"
    openocd -f "$OPENOCD_BOARD_CFG" \
        -c "init" \
        -c "reset halt" \
        -c "load_image $elf 0 elf" \
        -c "set vec0 [mrw 0x20010000]" \
        -c "set vec1 [mrw 0x20010004]" \
        -c "set pcval [expr {\$vec1 & ~1}]" \
        -c "reg sp \$vec0" \
        -c "reg pc \$pcval" \
        -c "resume" \
        -c "shutdown" > "$log" 2>&1 || {
            echo "openocd RAM load failed:" >&2
            sed 's/^/       /' "$log" >&2
            return 1
        }
}

echo "Loading STM32 KVS+SD+RTOS firmware..."
ram_load_and_run "$ELF"

echo "Running kvs_stress.py against $HOST:$PORT (concurrency=$CONCURRENCY duration=${DURATION}s) ..."
fixed_key_arg=()
if [ -n "$FIXED_KEY" ]; then
    fixed_key_arg=(--fixed-key "$FIXED_KEY")
fi

python3 scripts/kvs_stress.py \
    --host "$HOST" \
    --port "$PORT" \
    --concurrency "$CONCURRENCY" \
    --duration "$DURATION" \
    --value-size "$VALUE_SIZE" \
    --timeout "$TIMEOUT" \
    --put-ratio "$PUT_RATIO" \
    --get-ratio "$GET_RATIO" \
    --delete-ratio "$DELETE_RATIO" \
    "${fixed_key_arg[@]}"
