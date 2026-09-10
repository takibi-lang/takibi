#!/usr/bin/env bash
# RPi5 RP1 Ethernet hardware tests. Only the raw-socket process runs under
# sudo; SWD and UART remain in the unprivileged devcontainer session.
set -euo pipefail

# `set -e` aborts with no context, and a lane's setup prints nothing on
# success -- a CI failure once reported exit 74 and not one line saying
# which command produced it. Name the line, the command and the status.
trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi5_uart_dev.sh")}"

# Every clone shares one physical board, and AGENTS.md's promise is that each
# runner takes the lease it needs before it starts, so nothing needs
# permission. This runner did not, while scripts/run_kernel_hwtest_rpi5.sh
# next to it did -- so the maintained kernel lane waited its turn and these
# examples lanes walked straight past it into the same board. Measured on
# 2026-09-06: this lane and another clone's `make kernelcheck-rpi5` ran
# concurrently, and three of six tests here came back with empty or truncated
# UART captures while the other run recorded a board failure.
. "$REPO_ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "hwcheck-rpi5-net" || exit 1
export ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
export ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
export ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"
ARTIFACT_ROOT="${RPI5_NET_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/hwtest-rpi5-net}"
SETTLE_SECS="${RPI5_NET_SETTLE_SECS:-3}"
STORAGE_SETTLE_SECS="${RPI5_NET_STORAGE_SETTLE_SECS:-8}"
L2_ONLY=0
[ "${1:-}" = "--l2-only" ] && L2_ONLY=1

# shellcheck source=scripts/artifact_dirs.sh
source "$REPO_ROOT/scripts/artifact_dirs.sh"
mkdir -p "$ARTIFACT_ROOT"
exec > >(tee "$ARTIFACT_ROOT/run.log") 2>&1

if [ -z "$SERIAL_DEV" ] || [ ! -e "$SERIAL_DEV" ]; then
    echo "error: could not resolve the Raspberry Pi 5 UART device (found: '$SERIAL_DEV')" >&2
    exit 1
fi
stty -F "$SERIAL_DEV" 115200 raw -echo

PASS=0
FAIL=0
FAILED_TESTS=()
ACTIVE_UART_PID=""
stop_uart() {
    if [ -n "$ACTIVE_UART_PID" ]; then
        kill "$ACTIVE_UART_PID" 2>/dev/null || true
        wait "$ACTIVE_UART_PID" 2>/dev/null || true
        ACTIVE_UART_PID=""
    fi
}
trap stop_uart EXIT
trap 'stop_uart; exit 130' INT TERM HUP

. "$REPO_ROOT/scripts/board_link_gate.sh"

# GitHub issue #387: the settle sleep below is a guess about how long the
# board needs; this is the board saying so. The two are not the same
# question and both stay: the sleep also covers USB storage init for the
# sdcard tests, which no boot-log line announces, while the link is
# announced and was being waited for by nothing.
#
# Purely additive, so a healthy run is unchanged: by the time the settle
# sleep has elapsed the ready line is already in the log and this returns
# at once. What it buys is the run where the link is LATE, which used to
# be reported as a defect in whichever protocol test ran first.
LINK_READY_TICKS=300

wait_for_board_link() {
    local artifact_dir="$1" name="$2" marker="${name%% *}" reason
    if reason="$(board_link_gate "$artifact_dir/uart.log" \
            "$marker: ready" "$marker: device/link not found" \
            "$LINK_READY_TICKS")"; then
        printf '       %s\n' "$reason"
        return 0
    fi
    printf '       %s\n' "$reason"
    return 1
}

run_net_test() {
    local name="$1" elf="$2" test_script="$3" settle_secs="${4:-$SETTLE_SECS}" artifact_dir
    prepare_artifact_dir "$ARTIFACT_ROOT" "$name"
    artifact_dir="$ARTIFACT_DIR"

    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged > "$artifact_dir/reset.log" 2>&1; then
        echo "FAIL  $name (PSCI reset failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    timeout 0.25 cat "$SERIAL_DEV" > /dev/null 2>&1 || true
    cat "$SERIAL_DEV" > "$artifact_dir/uart.log" &
    ACTIVE_UART_PID=$!
    if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$elf" > "$artifact_dir/loader.log" 2>&1; then
        stop_uart
        echo "FAIL  $name (SWD injection failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    sleep "$settle_secs"
    echo "-- $name --"
    if ! wait_for_board_link "$artifact_dir" "$name"; then
        stop_uart
        echo "FAIL  $name (the board never reported a link)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            ETH_TEST_MAC="$ETH_TEST_MAC" SDCARD_CONTENT_DIR="$REPO_ROOT/examples/sdcard_content" \
            python3 "$test_script" \
            > >(tee "$artifact_dir/host.log") 2>&1; then
        stop_uart
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        stop_uart
        echo "FAIL  $name"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}

run_kvs_persistence_test() {
    local name="kvs_server_sdcard_rtos (rpi5)" elf="$REPO_ROOT/examples/kvs_server_sdcard_rtos/kernel_rpi5.elf"
    local test_script="$REPO_ROOT/scripts/eth_kvs_server_stm32_test.py" artifact_dir
    prepare_artifact_dir "$ARTIFACT_ROOT" "$name"
    artifact_dir="$ARTIFACT_DIR"

    # This test used to capture no UART at all, so it had neither a boot log
    # to read nor one to leave behind when it failed. Both boots get one
    # now, which is what lets the link gate below run here too (GitHub
    # issue #387).
    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged >"$artifact_dir/reset-boot1.log" 2>&1; then
        echo "FAIL  $name (boot 1 reset failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    timeout 0.25 cat "$SERIAL_DEV" > /dev/null 2>&1 || true
    cat "$SERIAL_DEV" > "$artifact_dir/uart.log" &
    ACTIVE_UART_PID=$!
    if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$elf" >"$artifact_dir/loader-boot1.log" 2>&1; then
        stop_uart
        echo "FAIL  $name (boot 1 load failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    sleep "$STORAGE_SETTLE_SECS"
    echo "-- $name --"
    if ! wait_for_board_link "$artifact_dir" "$name"; then
        stop_uart
        echo "FAIL  $name (the board never reported a link, boot 1)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            python3 "$test_script" > >(tee "$artifact_dir/host-boot1.log") 2>&1; then
        stop_uart
        echo "FAIL  $name (protocol test failed, boot 1)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    stop_uart
    mv "$artifact_dir/uart.log" "$artifact_dir/uart-boot1.log"
    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged >"$artifact_dir/reset-boot2.log" 2>&1; then
        echo "FAIL  $name (boot 2 reset failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    timeout 0.25 cat "$SERIAL_DEV" > /dev/null 2>&1 || true
    cat "$SERIAL_DEV" > "$artifact_dir/uart.log" &
    ACTIVE_UART_PID=$!
    if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$elf" >"$artifact_dir/loader-boot2.log" 2>&1; then
        stop_uart
        echo "FAIL  $name (boot 2 load failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    sleep "$STORAGE_SETTLE_SECS"
    echo "-- $name (persistence-survives-reset check) --"
    if ! wait_for_board_link "$artifact_dir" "$name"; then
        stop_uart
        echo "FAIL  $name (the board never reported a link, boot 2)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            KVS_TEST_PHASE=verify_persistence python3 "$test_script" \
            > >(tee "$artifact_dir/host-boot2.log") 2>&1; then
        stop_uart
        mv "$artifact_dir/uart.log" "$artifact_dir/uart-boot2.log"
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        stop_uart
        mv "$artifact_dir/uart.log" "$artifact_dir/uart-boot2.log"
        echo "FAIL  $name"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}

if [ "$L2_ONLY" -eq 1 ]; then
    run_net_test "net_echo (rpi5)" "$REPO_ROOT/examples/net_echo/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_net_echo_test.py"
    run_net_test "arp_reply (rpi5)" "$REPO_ROOT/examples/arp_reply/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_arp_reply_test.py"
    run_net_test "icmp_echo (rpi5)" "$REPO_ROOT/examples/icmp_echo/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_icmp_echo_test.py"
    echo "RPi5 Ethernet L2 hardware tests: $PASS passed, $FAIL failed"
else
    run_net_test "tcp_echo (rpi5)" "$REPO_ROOT/examples/tcp_echo/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_tcp_echo_test.py"
    run_net_test "http_server (rpi5)" "$REPO_ROOT/examples/http_server/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_http_server_test.py"
    run_net_test "kvs_server (rpi5)" "$REPO_ROOT/examples/kvs_server/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_kvs_server_test.py"
    echo "-- provisioning RPi5 USB drive --"
    if "$REPO_ROOT/scripts/rpi5_provision_http_server_sdcard.sh" \
            "$REPO_ROOT/examples/http_server_sdcard_install/kernel_rpi5.elf" \
            "$REPO_ROOT/examples/sdcard_content"; then
        run_net_test "http_server_sdcard (rpi5)" "$REPO_ROOT/examples/http_server_sdcard/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_http_server_sdcard_test.py" "$STORAGE_SETTLE_SECS"
        run_net_test "http_server_sdcard_rtos (rpi5)" "$REPO_ROOT/examples/http_server_sdcard_rtos/kernel_rpi5.elf" "$REPO_ROOT/scripts/eth_http_server_sdcard_test.py" "$STORAGE_SETTLE_SECS"
        run_kvs_persistence_test
    else
        echo "FAIL  RPi5 USB drive provisioning"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("RPi5 USB drive provisioning")
    fi
    echo "RPi5 network hardware tests: $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1
