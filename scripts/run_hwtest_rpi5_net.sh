#!/usr/bin/env bash
# RPi5 RP1 Ethernet hardware tests. Only the raw-socket process runs under
# sudo; SWD and UART remain in the unprivileged devcontainer session.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$("$REPO_ROOT/scripts/rpi5_uart_dev.sh")}"
export ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
export ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
export ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"
ARTIFACT_ROOT="${RPI5_NET_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/hwtest-rpi5-net}"
SETTLE_SECS="${RPI5_NET_SETTLE_SECS:-3}"
STORAGE_SETTLE_SECS="${RPI5_NET_STORAGE_SETTLE_SECS:-8}"
L2_ONLY=0
[ "${1:-}" = "--l2-only" ] && L2_ONLY=1

# shellcheck source=scripts/test_artifacts.sh
source "$REPO_ROOT/scripts/test_artifacts.sh"
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

run_net_test() {
    local name="$1" elf="$2" test_script="$3" settle_secs="${4:-$SETTLE_SECS}" artifact_dir
    prepare_artifact_dir "$ARTIFACT_ROOT" "$name"
    artifact_dir="$ARTIFACT_DIR"

    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" > "$artifact_dir/reset.log" 2>&1; then
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

    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" >"$artifact_dir/reset-boot1.log" 2>&1 ||
       ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$elf" >"$artifact_dir/loader-boot1.log" 2>&1; then
        echo "FAIL  $name (boot 1 load failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    sleep "$STORAGE_SETTLE_SECS"
    echo "-- $name --"
    if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            python3 "$test_script" > >(tee "$artifact_dir/host-boot1.log") 2>&1; then
        echo "FAIL  $name (protocol test failed, boot 1)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" >"$artifact_dir/reset-boot2.log" 2>&1 ||
       ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$elf" >"$artifact_dir/loader-boot2.log" 2>&1; then
        echo "FAIL  $name (boot 2 load failed)"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); return
    fi
    sleep "$STORAGE_SETTLE_SECS"
    echo "-- $name (persistence-survives-reset check) --"
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            KVS_TEST_PHASE=verify_persistence python3 "$test_script" \
            > >(tee "$artifact_dir/host-boot2.log") 2>&1; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
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
