#!/usr/bin/env bash
# Standalone-kernel RPi5 integration runner (GitHub issue #177).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$($REPO_ROOT/scripts/rpi5_uart_dev.sh)}"
ELF="$REPO_ROOT/kernel/build/rpi5/kernel.elf"
VIEW_DIR="$REPO_ROOT/kernel/tests/rpi5/views"
ARTIFACT_DIR="${RPI5_KERNEL_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-rpi5}"
UART_LOG="$ARTIFACT_DIR/uart.log"
RESET_LOG="$ARTIFACT_DIR/reset.log"
LOADER_LOG="$ARTIFACT_DIR/loader.log"
ARP_LOG="$ARTIFACT_DIR/arp.log"
ICMP_LOG="$ARTIFACT_DIR/icmp.log"
TCP_LOG="$ARTIFACT_DIR/tcp.log"
HTTPD_LOG="$ARTIFACT_DIR/httpd-curl.log"
HTTPD_BODY="$ARTIFACT_DIR/httpd-body.actual"
SECOND_HTTPD_LOG="$ARTIFACT_DIR/httpd-curl-second.log"
SECOND_HTTPD_BODY="$ARTIFACT_DIR/httpd-body-second.actual"
SOCKET_ACCEPT_LOG="$ARTIFACT_DIR/socket-accept.log"
ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"

mkdir -p "$ARTIFACT_DIR"
if [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: $SERIAL_DEV" >&2
    exit 1
fi
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    exit 1
fi

# A killed test runner cannot execute its EXIT trap. In that case its
# background `cat SERIAL_DEV` survives under PID 1 and competes with the next
# run for bytes from the same tty; each reader then receives only fragments,
# and the orphan can also keep writing into a truncated uart.log at its old
# file offset. Remove only this script's exact, same-user orphan shape. Never
# take the device away from an interactive terminal or another program.
for holder_pid in $(fuser "$SERIAL_DEV" 2>/dev/null || true); do
    [ -r "/proc/$holder_pid/cmdline" ] || continue
    if [ "$(stat -c %u "/proc/$holder_pid" 2>/dev/null || echo -1)" != "$(id -u)" ]; then
        echo "error: RPi5 UART is held by another user (PID $holder_pid)" >&2
        exit 1
    fi
    mapfile -d '' -t holder_argv <"/proc/$holder_pid/cmdline"
    if [ "${#holder_argv[@]}" -eq 2 ] &&
            [ "${holder_argv[0]##*/}" = cat ] &&
            [ "${holder_argv[1]}" = "$SERIAL_DEV" ] &&
            [ "$(awk '/^PPid:/{print $2}' "/proc/$holder_pid/status" 2>/dev/null || echo -1)" = 1 ]; then
        kill "$holder_pid"
        for _wait in $(seq 1 100); do
            kill -0 "$holder_pid" 2>/dev/null || break
            sleep 0.01
        done
        if kill -0 "$holder_pid" 2>/dev/null; then
            echo "error: stale RPi5 UART reader did not exit (PID $holder_pid)" >&2
            exit 1
        fi
        continue
    fi
    echo "error: RPi5 UART is already in use by PID $holder_pid" >&2
    exit 1
done

stty -F "$SERIAL_DEV" 115200 raw -echo
echo "[kernel/rpi5] resetting board"
if ! "$REPO_ROOT/scripts/rpi5_jtag_reset.sh" --resident-image-unchanged >"$RESET_LOG" 2>&1; then
    echo "FAIL kernel/rpi5: reset failed (see $RESET_LOG)" >&2
    exit 1
fi

# Peripheral FIFO contents survive SWD injection and the resident stub may
# have emitted bytes before it was reset. Drain that history before opening
# the capture used as evidence for this payload.
timeout 1 cat "$SERIAL_DEV" >/dev/null 2>&1 || true

: >"$UART_LOG"
# SWD load time grows with embedded initramfs images. Keep the reader alive
# through the entire load instead of imposing a deadline that can expire
# before the CPU is resumed; cleanup below bounds the post-load capture.
cat "$SERIAL_DEV" >"$UART_LOG" 2>/dev/null &
reader_pid=$!
uart_sender_pid=
cleanup() {
    if [ -n "$uart_sender_pid" ]; then
        kill "$uart_sender_pid" 2>/dev/null || true
        wait "$uart_sender_pid" 2>/dev/null || true
    fi
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

sleep 0.2
load_started=$SECONDS
echo "[kernel/rpi5] loading kernel over SWD"
if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF" >"$LOADER_LOG" 2>&1; then
    echo "FAIL kernel/rpi5: load failed (see $LOADER_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] kernel loaded in $((SECONDS - load_started))s; waiting for integration completion"

# The kernel holds its affine RX readiness capability while waiting for one
# real ARP request. Exercise the wire path immediately after resume; keep the
# raw-socket privilege confined to the existing protocol checker.
echo "[kernel/rpi5] checking ARP reply on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ARP_TEST_OTHER_FIRST=1 \
        python3 "$REPO_ROOT/scripts/eth_arp_reply_test.py" \
        > >(tee "$ARP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: ARP integration failed (see $ARP_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] ARP integration passed"

echo "[kernel/rpi5] checking ICMP echo reply on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ETH_TEST_MAC="$ETH_TEST_MAC" ICMP_TEST_NEGATIVE_FIRST=1 \
        python3 "$REPO_ROOT/scripts/eth_icmp_echo_test.py" \
        > >(tee "$ICMP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: ICMP integration failed (see $ICMP_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] ICMP integration passed"

echo "[kernel/rpi5] checking TCP echo lifecycle on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ETH_TEST_MAC="$ETH_TEST_MAC" \
        python3 "$REPO_ROOT/scripts/eth_tcp_echo_test.py" \
        > >(tee "$TCP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: TCP integration failed (see $TCP_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] TCP integration passed"

# GitHub issue #187: the kernel injects a one-shot SYN-ACK drop right
# before starting the real BusyBox HTTPd daemon (kernel_tcp_inject_drop_
# next_syn_ack(), kernel/init/main.tkb), so its own bounded retransmit
# budget (TCP_RETRY_LIMIT * retry_ticks, kernel/net/tcp.tkb) can race
# against curl's --connect-timeout 1 if the FIRST curl attempt's SYN
# happens to arrive while the kernel is still busy with the earlier
# USB-ext2 provisioning step (measured to vary by roughly 10x in wall-clock
# time between otherwise-identical real-hardware runs). Waiting for the
# kernel's own last pre-daemon log line here, instead of firing curl blind
# immediately after the TCP echo check above, means curl's first SYN can
# only ever arrive once the kernel is already about to enter the daemon's
# accept() loop -- decoupling this race from USB provisioning time
# entirely without touching tcp.tkb's own timing constants or weakening
# what the drop-recovery check proves (still the real daemon's real
# accept() path, still a real dropped packet).
echo "[kernel/rpi5] waiting for the kernel to be ready to start the BusyBox httpd daemon"
httpd_ready=0
for _wait in $(seq 1 600); do
    if LC_ALL=C grep -aFq 'httpd map: combined pages=331 musl-bias=0x40000 auxv ready clean' "$UART_LOG"; then
        httpd_ready=1
        break
    fi
    sleep 0.1
done
if [ "$httpd_ready" -ne 1 ]; then
    echo "FAIL kernel/rpi5: kernel never reached the pre-daemon readiness marker (see $UART_LOG)" >&2
    exit 1
fi

echo "[kernel/rpi5] curling BusyBox httpd index.html on port 8080"
httpd_ok=0
for _attempt in $(seq 1 20); do
    if curl --silent --show-error --fail \
            --interface "$ETH_TEST_IFACE" --noproxy '*' \
            --connect-timeout 1 --max-time 5 \
            --output "$HTTPD_BODY" \
            "http://${ETH_TEST_SUBNET}.2:8080/" 2>"$HTTPD_LOG"; then
        if cmp -s "$REPO_ROOT/kernel/tests/ext2/index.html" "$HTTPD_BODY"; then
            httpd_ok=1
            break
        fi
        echo 'unexpected response body (see httpd-body.actual)' >"$HTTPD_LOG"
        break
    fi
    sleep 0.25
done
if [ "$httpd_ok" -ne 1 ]; then
    echo "FAIL kernel/rpi5: BusyBox httpd curl failed (see $HTTPD_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] BusyBox httpd curl passed"

# GitHub issues #180/#181: the same foreground daemon parent accepts this
# second connection after its first request child exits, without a reboot or
# process-image restart.
echo "[kernel/rpi5] curling BusyBox httpd index.html a second time (same boot)"
second_httpd_ok=0
for _attempt in $(seq 1 20); do
    if curl --silent --show-error --fail \
            --interface "$ETH_TEST_IFACE" --noproxy '*' \
            --connect-timeout 1 --max-time 5 \
            --output "$SECOND_HTTPD_BODY" \
            "http://${ETH_TEST_SUBNET}.2:8080/" 2>"$SECOND_HTTPD_LOG"; then
        if cmp -s "$REPO_ROOT/kernel/tests/ext2/index.html" "$SECOND_HTTPD_BODY"; then
            second_httpd_ok=1
            break
        fi
        echo 'unexpected response body (see httpd-body-second.actual)' >"$SECOND_HTTPD_LOG"
        break
    fi
    sleep 0.25
done
if [ "$second_httpd_ok" -ne 1 ]; then
    echo "FAIL kernel/rpi5: second BusyBox httpd curl failed (see $SECOND_HTTPD_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] second BusyBox httpd curl passed"

# GitHub issue #187: same reasoning as the pre-daemon wait above -- this
# fixture's own accept() only becomes live after the BusyBox distro-image
# fixture between it and the httpd checks finishes, so wait for its last
# pre-fixture log line rather than firing the connected-I/O check blind.
echo "[kernel/rpi5] waiting for the kernel to be ready for the userspace connected-I/O fixture"
userspace_ready=0
for _wait in $(seq 1 600); do
    if LC_ALL=C grep -aFq 'vm layout: text=rx data=rw+xn stack=rw+xn' "$UART_LOG"; then
        userspace_ready=1
        break
    fi
    sleep 0.1
done
if [ "$userspace_ready" -ne 1 ]; then
    echo "FAIL kernel/rpi5: kernel never reached the userspace-fixture readiness marker (see $UART_LOG)" >&2
    exit 1
fi

# Watch concurrently with the connected-I/O client: the child reaches its
# UART wait immediately after that socket exchange. Do not send input merely
# because Blocked is visible: wait until the kernel has also verified that the
# parent completed its compute section while that child remained Blocked.
(
    for _wait in $(seq 1 6000); do
        if LC_ALL=C grep -aFq \
                'concurrency: parent progressed while child uart-blocked' \
                "$UART_LOG"; then
            printf 'irqtest\n' >"$SERIAL_DEV"
            exit 0
        fi
        sleep 0.01
    done
    exit 1
) &
uart_sender_pid=$!

echo "[kernel/rpi5] checking userspace connected I/O on port 8080"
socket_accept_ok=0
for _attempt in $(seq 1 60); do
    if sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" \
            ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
            ETH_TEST_MAC="$ETH_TEST_MAC" TCP_TEST_PORT=8080 \
            TCP_TEST_CONNECTED_IO=1 \
            python3 "$REPO_ROOT/scripts/eth_tcp_echo_test.py" \
            >"$SOCKET_ACCEPT_LOG" 2>&1; then
        socket_accept_ok=1
        cat "$SOCKET_ACCEPT_LOG"
        break
    fi
    sleep 0.25
done
if [ "$socket_accept_ok" -ne 1 ]; then
    cat "$SOCKET_ACCEPT_LOG" >&2
    echo "FAIL kernel/rpi5: userspace connected I/O failed (see $SOCKET_ACCEPT_LOG)" >&2
    exit 1
fi
echo "[kernel/rpi5] userspace connected I/O passed"

# USB Mass Storage may briefly report Not Ready after enumeration. Keep the
# single capture alive through its bounded readiness loop and ext2 checks.
# This is host-side progress only: no temporary debug UART messages are added
# to the kernel. Stop as soon as the stable final resource marker arrives,
# while retaining a deadline for a hung kernel.
#
# The sender above waits for kernel-validated interleaving, then the completion
# loop waits for the IRQ-driven Blocked -> Ready evidence.
capture_deadline="${RPI5_KERNEL_CAPTURE_SECONDS:-90}"
capture_elapsed=0
capture_complete=0
while [ "$capture_elapsed" -lt "$capture_deadline" ]; do
    sleep 1
    capture_elapsed=$((capture_elapsed + 1))
    if LC_ALL=C grep -aFq 'uart rx: scheduler block+wake ok' "$UART_LOG" &&
            LC_ALL=C grep -aFq 'resources: pages=0' "$UART_LOG"; then
        capture_complete=1
        break
    fi
    if [ $((capture_elapsed % 5)) -eq 0 ]; then
        echo "[kernel/rpi5] running integration checks: ${capture_elapsed}s elapsed"
    fi
done
if [ "$capture_complete" -eq 1 ]; then
    echo "[kernel/rpi5] integration completion observed after ${capture_elapsed}s"
else
    echo "[kernel/rpi5] completion marker not observed before ${capture_deadline}s deadline" >&2
fi
cleanup
trap - EXIT INT TERM HUP
tr -d '\r' <"$UART_LOG" >"$UART_LOG.normalized"

# One boot, several independent views. Each filter projects the shared UART
# transcript onto one contract, whose expected file is then compared exactly.
# Adding a subsystem test does not require another reset/load cycle.
view_count=0
for filter in "$VIEW_DIR"/*.filter; do
    [ -e "$filter" ] || continue
    name="$(basename "$filter" .filter)"
    expected="$VIEW_DIR/$name.expected"
    actual="$ARTIFACT_DIR/$name.actual"
    if [ ! -f "$expected" ]; then
        echo "error: missing expected file for kernel view $name" >&2
        exit 1
    fi
    LC_ALL=C grep -E -f "$filter" "$UART_LOG.normalized" >"$actual" || true
    if ! cmp -s "$expected" "$actual"; then
        echo "FAIL kernel/rpi5 view: $name" >&2
        diff -u "$expected" "$actual" >&2 || true
        echo "artifacts: $ARTIFACT_DIR" >&2
        exit 1
    fi
    echo "PASS kernel/rpi5 view: $name"
    view_count=$((view_count + 1))
done

if [ "$view_count" -eq 0 ]; then
    echo "error: no kernel integration views found under $VIEW_DIR" >&2
    exit 1
fi

echo "PASS kernel/rpi5 ($view_count views, one boot)"
