#!/usr/bin/env bash
# Standalone-kernel QEMU/AArch64 integration runner (GitHub issue #237).
#
# Structurally mirrors scripts/run_kernel_hwtest_rpi5.sh's "one capture,
# several independent views" pattern (see that script's own header): a
# single boot's UART transcript is projected through every kernel/tests/
# common/views/*.filter plus qemu/views/*.filter are compared exactly
# against their matching *.expected files. Platform-specific files override
# common files with the same name. Unlike the RPi5 runner, this needs no SWD/reset/
# external-serial-device machinery at all -- QEMU's own -nographic pipes
# the guest UART directly to this process's stdout, so capture is a
# single `timeout N qemu-system-aarch64 ... -kernel ... > uart.log` call.
#
# -m 1024: kernel/mm/page.tkb's BOOT_PAGE_COUNT reserves ~800 MiB of real
# physical page content starting right after the kernel image. QEMU
# `virt`'s default RAM (much smaller than that without an explicit -m)
# would leave part of that pool unbacked -- harmless for today's self-test
# bundle (it never allocates anywhere near that much), but a real latent
# bug for any future workload that does. Matches kernel/README.md's
# documented QEMU invocation.
#
# -netdev dgram + -device virtio-net-device (GitHub issue #237 M4): one
# UDP datagram == one raw Ethernet frame, the same private point-to-point
# transport examples/'s own scripts/run_qemutest.sh::run_virtio_test uses
# (no ARP/DHCP noise, unlike -netdev user). scripts/kernel_net_test.py is
# run against it concurrently as the host-side peer, driving ARP, ICMP,
# and the full TCP handshake/echo/close/reconnect sequence
# kernel_tcp_echo_check() waits for, followed by two raw-TCP HTTP GETs
# against the BusyBox daemon on port 8080. The HTTP requests verify the
# ext2-resident index.html body and exercise the daemon's dropped SYN-ACK
# and split-request fixtures, analogous to the RPi5 runner. Unlike that
# lane, this needs no physical NIC, cable, or raw-socket privileges. mac= is pinned
# to kernel/net/netconfig.tkb's OUR_MAC so the boot log's "link ready
# mac=..." line stays a fixed, exact-matchable string. The feature flags
# (csum=off, mrg_rxbuf=off, ...) match run_virtio_test's own list exactly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
VIEW_DIR="$REPO_ROOT/kernel/tests/qemu/views"
COMMON_VIEW_DIR="$REPO_ROOT/kernel/tests/common/views"
ARTIFACT_DIR="${KERNEL_QEMU_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-qemu}"
UART_LOG="$ARTIFACT_DIR/uart.log"
PEER_LOG="$ARTIFACT_DIR/net-peer.log"
UART_INPUT="$ARTIFACT_DIR/uart-input"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
# Safety net only: the run normally ends as soon as the boot's own final
# marker (BOOT_DONE_MARKER below) appears, a few seconds in. This bound
# only matters if the guest wedges before reaching it.
TIMEOUT_SECS="${KERNEL_QEMU_TIMEOUT:-90}"
PEER_TIMEOUT_SECS="${KERNEL_QEMU_PEER_TIMEOUT:-60}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_NETDEV_LOCAL_PORT:-17771}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_NETDEV_REMOTE_PORT:-17772}"
# kernel/platform/qemu/init.tkb's very last boot-log line before it parks in
# `while (true) {}` -- see that file's tail.
BOOT_DONE_MARKER="^resources: pages=0$"

mkdir -p "$ARTIFACT_DIR"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
rm -f "$UART_INPUT"
mkfifo "$UART_INPUT"
exec 8<>"$UART_INPUT"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL kernel/qemu: another QEMU runner already owns $ARTIFACT_DIR" >&2
    exit 1
fi
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF (run 'make kernelbuild-qemu' first)" >&2
    exit 1
fi

echo "[kernel/qemu] booting kernel.elf under QEMU"
# This kernel's fn main() never exits (a final `while (true) {}` park,
# same as RPi5's), so QEMU is backgrounded and killed once the boot's own
# final marker appears -- there is no clean-exit signal to wait for. It
# also has to be backgrounded regardless, so the host-side network peer
# below can talk to it while it runs.
: >"$UART_LOG"
timeout "$TIMEOUT_SECS" qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -nographic \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=$NETDEV_LOCAL_PORT,remote.type=inet,remote.host=127.0.0.1,remote.port=$NETDEV_REMOTE_PORT" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF" <&8 >"$UART_LOG" 2>&1 &
QEMU_PID=$!
stop_qemu() {
    if [ -n "${QEMU_PID:-}" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi
}
trap stop_qemu EXIT
trap 'stop_qemu; exit 130' INT TERM HUP

# interactive ash and the init.sh user_payload fixture both block in the UART
# receive path. Feed each deterministic line after its own blocked marker.
uart_sender_pid=""
(
    shell_sent=0
    payload_sent=0
    for _wait in $(seq 1 "$TIMEOUT_SECS"); do
        if [ "$shell_sent" -eq 0 ] &&
           LC_ALL=C grep -aFq 'interactive shell: uart blocked' "$UART_LOG"; then
            printf 'x=; /bin/ls; /bin/ls -a; /bin/ls /bin; echo repl-ok; exit\n' >&8
            shell_sent=1
        fi
        if [ "$payload_sent" -eq 0 ] &&
           LC_ALL=C grep -aFq \
               'concurrency: parent progressed while child uart-blocked' "$UART_LOG"; then
            printf 'irqtest\n' >&8
            payload_sent=1
        fi
        if [ "$shell_sent" -eq 1 ] && [ "$payload_sent" -eq 1 ]; then
            exit 0
        fi
        sleep 0.1
    done
    exit 1
) &
uart_sender_pid=$!

# Host-side peer: drives ARP, ICMP, and the full TCP handshake/echo/close/
# reconnect sequence kernel_tcp_echo_check() counts before returning
# Verified. Its own retry loops absorb the guest's ~1s boot time, so no
# sleep is needed here. A peer failure is reported but not fatal on its
# own -- the view diff below is the real verdict, and letting it run gives
# a much more useful failure (which exact boot-log line is missing) than
# aborting here would.
echo "[kernel/qemu] driving host-side network peer (ARP/ICMP/TCP)"
peer_status=0
timeout "$PEER_TIMEOUT_SECS" python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" \
    "$NETDEV_LOCAL_PORT" "$NETDEV_REMOTE_PORT" >"$PEER_LOG" 2>&1 || peer_status=$?
sed 's/^/  /' "$PEER_LOG"
if [ "$peer_status" -ne 0 ]; then
    echo "[kernel/qemu] host-side network peer reported failure (status $peer_status)" >&2
fi

# Wait for the boot to reach its own final marker before capturing.
for _wait in $(seq 1 "$TIMEOUT_SECS"); do
    if LC_ALL=C grep -qE "$BOOT_DONE_MARKER" "$UART_LOG"; then
        break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done
stop_qemu
if [ -n "$uart_sender_pid" ]; then
    kill "$uart_sender_pid" 2>/dev/null || true
    wait "$uart_sender_pid" 2>/dev/null || true
fi
exec 8>&-
rm -f "$UART_INPUT"
trap - EXIT INT TERM HUP

if [ ! -s "$UART_LOG" ]; then
    echo "error: no UART output captured -- kernel did not boot" >&2
    exit 1
fi
tr -d '\r' <"$UART_LOG" >"$UART_LOG.normalized"

# One boot, several independent views -- see this file's header and
# scripts/run_kernel_hwtest_rpi5.sh's own identical loop.
view_count=0
view_names="$(
    for filter in "$COMMON_VIEW_DIR"/*.filter "$VIEW_DIR"/*.filter; do
        [ -e "$filter" ] || continue
        basename "$filter" .filter
    done | LC_ALL=C sort -u
)"
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -f "$VIEW_DIR/$name.filter" ]; then
        filter="$VIEW_DIR/$name.filter"
    else
        filter="$COMMON_VIEW_DIR/$name.filter"
    fi
    if [ -f "$VIEW_DIR/$name.expected" ]; then
        expected="$VIEW_DIR/$name.expected"
    else
        expected="$COMMON_VIEW_DIR/$name.expected"
    fi
    actual="$ARTIFACT_DIR/$name.actual"
    if [ ! -f "$expected" ]; then
        echo "error: missing expected file for kernel view $name" >&2
        exit 1
    fi
    LC_ALL=C grep -E -f "$filter" "$UART_LOG.normalized" >"$actual" || true
    if ! cmp -s "$expected" "$actual"; then
        echo "FAIL kernel/qemu view: $name" >&2
        diff -u "$expected" "$actual" >&2 || true
        echo "artifacts: $ARTIFACT_DIR" >&2
        exit 1
    fi
    echo "PASS kernel/qemu view: $name"
    view_count=$((view_count + 1))
done <<<"$view_names"

if [ "$view_count" -eq 0 ]; then
    echo "error: no kernel integration views found under $COMMON_VIEW_DIR or $VIEW_DIR" >&2
    exit 1
fi

echo "PASS kernel/qemu ($view_count views, one boot)"
