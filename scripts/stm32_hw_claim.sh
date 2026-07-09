#!/usr/bin/env bash
# Shared last-start-wins ownership for STM32 hardware test runners.
# Source this file, then call claim_stm32_hardware SERIAL_DEV.

STM32_HW_LOCK_FILE="${STM32_HW_LOCK_FILE:-/tmp/takibi-stm32-hardware.lock}"
STM32_HW_OWNER_FILE="${STM32_HW_OWNER_FILE:-/tmp/takibi-stm32-hardware.owner}"

stm32_proc_start_time() {
    awk '{print $22}' "/proc/$1/stat" 2>/dev/null
}

stm32_same_uid() {
    local proc_uid
    proc_uid=$(awk '/^Uid:/{print $2}' "/proc/$1/status" 2>/dev/null) || return 1
    [ "$proc_uid" = "$(id -u)" ]
}

stm32_stop_pid() {
    local pid="$1" child deadline
    [ "$pid" -ne "$$" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    stm32_same_uid "$pid" || return 1

    # Stop children first so they cannot retain the inherited flock fd or
    # continue consuming UART bytes after their runner exits. The runner's
    # TERM trap performs its own reader cleanup as well.
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
        kill -TERM "$child" 2>/dev/null || true
    done
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + 3))
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 0.05
    done
    if kill -0 "$pid" 2>/dev/null; then
        for child in $(pgrep -P "$pid" 2>/dev/null || true); do
            kill -KILL "$child" 2>/dev/null || true
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

stm32_stop_previous_runner() {
    local pid start workspace command actual_start
    [ -r "$STM32_HW_OWNER_FILE" ] || return 1
    pid=$(sed -n '1p' "$STM32_HW_OWNER_FILE")
    start=$(sed -n '2p' "$STM32_HW_OWNER_FILE")
    workspace=$(sed -n '3p' "$STM32_HW_OWNER_FILE")
    command=$(sed -n '4p' "$STM32_HW_OWNER_FILE")
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    actual_start=$(stm32_proc_start_time "$pid")
    [ -n "$actual_start" ] && [ "$actual_start" = "$start" ] || return 1
    [ "$workspace" = "$(pwd -P)" ] || return 1
    case "$command" in
        *scripts/run_hwtest_ram.sh|*scripts/run_hwtest_net.sh) ;;
        *) return 1 ;;
    esac
    echo "Taking over STM32 hardware from PID $pid ($command)..." >&2
    stm32_stop_pid "$pid"
}

stm32_stop_serial_holders() {
    local serial_dev="$1" pid
    [ -e "$serial_dev" ] || return 0
    for pid in $(fuser "$serial_dev" 2>/dev/null || true); do
        [ "$pid" -ne "$$" ] || continue
        if stm32_same_uid "$pid"; then
            echo "Releasing stale STM32 VCP holder PID $pid..." >&2
            stm32_stop_pid "$pid" || true
        else
            echo "error: $serial_dev is held by PID $pid owned by another user" >&2
            return 1
        fi
    done
}

claim_stm32_hardware() {
    local serial_dev="$1" attempt start
    exec 9>"$STM32_HW_LOCK_FILE"
    if ! flock -n 9; then
        stm32_stop_previous_runner || {
            echo "error: STM32 lock is held by an unrecognized process; refusing unsafe takeover" >&2
            return 1
        }
        attempt=0
        while ! flock -n 9; do
            attempt=$((attempt + 1))
            [ "$attempt" -lt 60 ] || {
                echo "error: previous STM32 runner did not release $STM32_HW_LOCK_FILE" >&2
                return 1
            }
            sleep 0.05
        done
    fi

    start=$(stm32_proc_start_time "$$")
    {
        printf '%s\n' "$$"
        printf '%s\n' "$start"
        pwd -P
        printf '%s\n' "$0"
    } > "$STM32_HW_OWNER_FILE"
    stm32_stop_serial_holders "$serial_dev"
}
