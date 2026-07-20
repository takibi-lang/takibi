#!/usr/bin/env bash
# Runs allcheck's independent QEMU, STM32, and Raspberry Pi 3 lanes in
# parallel after Makefile's allcheck-build has produced every artifact once.
# Tests sharing one physical board remain serial inside that board's lane.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE_COMMAND="${ALLCHECK_MAKE:-make}"
LOG_DIR="$REPO_ROOT/_build/allcheck-logs"
mkdir -p "$LOG_DIR"

: "${STM32_SERIAL_DEV:?STM32_SERIAL_DEV is required; run through make allcheck or set it explicitly}"

qemu_lane() {
    echo "[allcheck-stage] unit, language, build, and QEMU checks"
    "$MAKE_COMMAND" --no-print-directory check
}

stm32_lane() {
    echo "[allcheck-stage] UART hardware checks"
    STM32_SERIAL_DEV="$STM32_SERIAL_DEV" bash "$REPO_ROOT/scripts/run_hwtest_ram.sh"
    echo "[allcheck-stage] HTTP/SD/RTOS profiler check"
    STM32_SERIAL_DEV="$STM32_SERIAL_DEV" bash "$REPO_ROOT/scripts/profile_stm32_http_server_sdcard_rtos.sh"
    echo "[allcheck-stage] KVS/SD/RTOS profiler check"
    STM32_SERIAL_DEV="$STM32_SERIAL_DEV" bash "$REPO_ROOT/scripts/profile_stm32_kvs_server_sdcard_rtos.sh"
    echo "[allcheck-stage] Ethernet hardware checks"
    STM32_SERIAL_DEV="$STM32_SERIAL_DEV" bash "$REPO_ROOT/scripts/run_hwtest_net_ram.sh"
}

rpi3_lane() {
    echo "[allcheck-stage] UART/JTAG hardware checks"
    bash "$REPO_ROOT/scripts/run_hwtest_rpi3.sh"
    echo "[allcheck-stage] Ethernet hardware checks"
    bash "$REPO_ROOT/scripts/run_hwtest_rpi3_net.sh"
}

# Keep complete raw output in LOG while showing only stable progress records
# live. If a lane fails, its raw log is printed later without prefixes, so a
# multi-line expected/actual diagnostic cannot be interleaved with another
# lane's output.
run_lane() {
    local lane="$1" log="$2" function_name="$3"
    set -o pipefail
    "$function_name" 2>&1 | tee "$log" | \
        while IFS= read -r line; do
            case "$line" in
                '[allcheck-stage] '*)
                    printf '[%s] %s\n' "$lane" "${line#\[allcheck-stage\] }"
                    ;;
                PASS\ *|FAIL\ *|All\ *hardware\ test*|*'hardware tests: '*' passed'*|*'tests passed, '*' failed'*)
                    printf '[%s] %s\n' "$lane" "$line"
                    ;;
            esac
        done
}

declare -a lanes=(QEMU STM32 RPI3)
declare -A logs pids results

for lane in "${lanes[@]}"; do
    lower=${lane,,}
    logs[$lane]="$LOG_DIR/$lower.log"
    : > "${logs[$lane]}"
    run_lane "$lane" "${logs[$lane]}" "${lower}_lane" &
    pids[$lane]=$!
    printf '[%s] started (raw log: %s)\n' "$lane" "${logs[$lane]#$REPO_ROOT/}"
done

# Do not fail fast: collecting every lane's result makes the final summary
# useful even when one board fails early.
for lane in "${lanes[@]}"; do
    if wait "${pids[$lane]}"; then
        results[$lane]=PASS
        printf '[%s] completed successfully\n' "$lane"
    else
        results[$lane]=FAIL
        printf '\n===== %s lane FAILED: complete raw log =====\n' "$lane"
        sed 's/\r$//' "${logs[$lane]}"
        printf '===== end %s lane log =====\n\n' "$lane"
    fi
done

failed=0
printf '\nallcheck lanes:\n'
for lane in "${lanes[@]}"; do
    printf '  %-4s %s\n' "${results[$lane]}" "$lane"
    if [ "${results[$lane]}" != PASS ]; then
        failed=1
    fi
done
printf 'raw logs: %s\n' "${LOG_DIR#$REPO_ROOT/}"

exit "$failed"
