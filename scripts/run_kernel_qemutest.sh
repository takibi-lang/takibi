#!/usr/bin/env bash
# Standalone-kernel QEMU/AArch64 integration runner (GitHub issue #237).
#
# Structurally mirrors scripts/run_kernel_hwtest_rpi5.sh's "one capture,
# several independent views" pattern (see that script's own header): a
# single boot's UART transcript is projected through every kernel/tests/
# common/views/*.filter plus qemu/views/*.filter are compared exactly
# against their matching *.expected files. Platform-specific files override
# common files with the same name. Unlike the RPi5 runner, this needs no SWD/reset/
# external-serial-device machinery at all -- QEMU's TCP serial chardev is
# opened by the same pyserial driver used for the RPi5 UART, so capture and
# ash input share one transport implementation.
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
ELF="${KERNEL_QEMU_ELF:-$REPO_ROOT/kernel/build/qemu/kernel.elf}"
RUN_LABEL="kernel/${KERNEL_QEMU_LABEL:-qemu}"
VIEW_DIR="$REPO_ROOT/kernel/tests/qemu/views"
COMMON_VIEW_DIR="$REPO_ROOT/kernel/tests/common/views"
ASH_DIR="$REPO_ROOT/kernel/tests/common/ash"
ARTIFACT_DIR="${KERNEL_QEMU_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-qemu}"
UART_LOG="$ARTIFACT_DIR/uart.log"
UART_TIMING_LOG="$ARTIFACT_DIR/uart-timing.log"
PEER_LOG="$ARTIFACT_DIR/net-peer.log"
INTERACTIVE_HTTPD_LISTENER="$ARTIFACT_DIR/interactive-httpd.listener"
INTERACTIVE_HTTPD_READY="$ARTIFACT_DIR/interactive-httpd.ready"
INTERACTIVE_HTTPD_DONE="$ARTIFACT_DIR/interactive-httpd.done"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
SERIAL_PORT="${KERNEL_QEMU_SERIAL_PORT:-18673}"
# The UART driver and network peer below each enforce this bound. QEMU itself
# is deliberately started directly so QEMU_PID names the process that owns
# the lane's sockets; cleanup must wait for that process before a following
# invocation can safely reuse the fixed ports.
TIMEOUT_SECS="${KERNEL_QEMU_TIMEOUT:-90}"
# Keep the maintained kernel lane away from the historical examples' QEMU
# datagram ports. A stale or concurrent legacy runner on 17771/17772 can
# otherwise consume frames and make unrelated kernel views fail.
NETDEV_LOCAL_PORT="${KERNEL_QEMU_NETDEV_LOCAL_PORT:-18671}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_NETDEV_REMOTE_PORT:-18672}"
mkdir -p "$ARTIFACT_DIR"
rm -f "$INTERACTIVE_HTTPD_LISTENER" "$INTERACTIVE_HTTPD_READY" \
    "$INTERACTIVE_HTTPD_DONE"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL $RUN_LABEL: another QEMU runner already owns $ARTIFACT_DIR" >&2
    exit 1
fi
# GitHub issue #407: refuse to start if somebody already owns the ports
# this lane is about to use, and say so in those words. A peer that cannot
# bind used to surface as "no UART output captured -- kernel did not
# boot", which names the kernel for something it was never asked about.
# An orphan of THIS lane -- a qemu-system whose own command line carries
# this port, left behind by an interrupted run -- is reaped; anything else
# is reported and left alone.
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "$RUN_LABEL" \
    "tcp:$SERIAL_PORT" "udp:$NETDEV_LOCAL_PORT" "udp:$NETDEV_REMOTE_PORT" || exit 1
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    exit 1
fi

echo "[$RUN_LABEL] booting $(basename "$ELF") under QEMU"
# This kernel's fn main() never exits (a final `while (true) {}` park,
# same as RPi5's), so QEMU is backgrounded and killed once the boot's own
# final marker appears -- there is no clean-exit signal to wait for. It
# also has to be backgrounded regardless, so the host-side network peer
# below can talk to it while it runs.  Do not let the guest start until the
# capture client owns the UART: with wait=off, a fast boot can emit early
# self-test evidence before run_kernel_uart_driver.py connects.
qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none -monitor none \
    -serial "tcp:127.0.0.1:$SERIAL_PORT,server=on,wait=on" \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=$NETDEV_LOCAL_PORT,remote.type=inet,remote.host=127.0.0.1,remote.port=$NETDEV_REMOTE_PORT" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
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

python3 "$REPO_ROOT/scripts/run_kernel_uart_driver.py" \
    --port "socket://127.0.0.1:$SERIAL_PORT" --log "$UART_LOG" \
    --timing-log "$UART_TIMING_LOG" \
    --stdin "$ASH_DIR/ash.stdin" --expected "$ASH_DIR/ash.expected" \
    --timeout "$TIMEOUT_SECS" --stop-marker 'resources: pages=0' \
    --interactive-httpd-listener-file "$INTERACTIVE_HTTPD_LISTENER" \
    --interactive-httpd-ready-file "$INTERACTIVE_HTTPD_READY" \
    --interactive-httpd-done-file "$INTERACTIVE_HTTPD_DONE" \
    --workload-marker 'workload: busy pair ' \
    --validate-ash &
uart_driver_pid=$!

# Host-side peer: drives ARP, ICMP, and the full TCP handshake/echo/close/
# reconnect sequence kernel_tcp_echo_check() counts before returning
# Verified. Its own retry loops absorb the guest's ~1s boot time, so no
# sleep is needed here. A peer failure is reported but not fatal on its
# own -- the view diff below is the real verdict, and letting it run gives
# a much more useful failure (which exact boot-log line is missing) than
# aborting here would.
echo "[$RUN_LABEL] driving host-side network peer (ARP/ICMP/TCP)"
peer_status=0
timeout "$TIMEOUT_SECS" python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" \
    "$NETDEV_LOCAL_PORT" "$NETDEV_REMOTE_PORT" \
    --interactive-ready-file "$INTERACTIVE_HTTPD_LISTENER" \
    >"$PEER_LOG" 2>&1 || peer_status=$?
sed 's/^/  /' "$PEER_LOG"
if [ "$peer_status" -ne 0 ]; then
    echo "[$RUN_LABEL] host-side network peer reported failure (status $peer_status)" >&2
fi

interactive_peer_status=$peer_status
touch "$INTERACTIVE_HTTPD_DONE"
uart_driver_status=0
wait "$uart_driver_pid" || uart_driver_status=$?
uart_driver_pid=""
stop_qemu
trap - EXIT INT TERM HUP

if [ ! -s "$UART_LOG" ]; then
    # GitHub issue #407: an empty UART log means the guest said nothing,
    # which is a claim about the KERNEL -- so only make it when the host
    # side actually got to ask. If the peer above failed too, it is the
    # more likely cause and the one to read first: a lane whose peer
    # cannot start never gets far enough to learn anything about the
    # guest.
    if [ "$peer_status" -ne 0 ]; then
        echo "error: no UART output captured, and the host-side peer above failed too -- read the peer's error first; this says nothing about the kernel" >&2
    else
        echo "error: no UART output captured -- kernel did not boot" >&2
    fi
    exit 1
fi
# The persistent-shell checkpoints name the tracked child's pid, and a pid
# is minted monotonically rather than read off the process slot (issue
# #392), so its VALUE counts how many processes the boot created before
# this fixture -- an artifact of fixture order, not of what this view
# means. That the four checkpoints all name the SAME child is enforced in
# the kernel, which logs each of the last three only on a match against
# the pid the fork checkpoint recorded.
sed -e 's|^/ # ||' \
    -e 's|^\[[0-9][0-9]*\.[0-9][0-9]*\] |[<time>] |' \
    -e 's|^\(persistent shell: [a-z ]*\)pid=[0-9][0-9]*$|\1pid=<child>|' \
    <"$UART_LOG" | tr -d '\r' >"$UART_LOG.normalized"

python3 "$REPO_ROOT/scripts/validate_kernel_dmesg_timestamps.py" "$UART_LOG"

# One boot, several independent views -- see this file's header and
# scripts/run_kernel_hwtest_rpi5.sh's own identical loop.
# The view loop stops at the first mismatch, so every .actual after it keeps
# LAST run's content -- which reads exactly like this run's output and is
# not. That cost a debugging round trip: a fixed leak was re-diagnosed from
# a stale file. Purge them so a missing .actual means "never compared",
# which is the truth.
rm -f "$ARTIFACT_DIR"/*.actual
view_count=0
failed_views=""
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
        # Report and keep going. Stopping at the first mismatch made the
        # output say "one view failed" when seventeen had, because every
        # view after it was never compared -- which is also why the .actual
        # purge above exists. Comparing all of them costs one grep each
        # against an already-captured log, and a change that moves several
        # views at once is exactly when the whole list is what you need.
        echo "FAIL $RUN_LABEL view: $name" >&2
        diff -u "$expected" "$actual" >&2 || true
        failed_views="$failed_views $name"
        continue
    fi
    echo "PASS $RUN_LABEL view: $name"
    view_count=$((view_count + 1))
done <<<"$view_names"

if [ -n "$failed_views" ]; then
    echo "FAIL $RUN_LABEL views:$failed_views" >&2
    echo "artifacts: $ARTIFACT_DIR" >&2
    exit 1
fi

if [ "$view_count" -eq 0 ]; then
    echo "error: no kernel integration views found under $COMMON_VIEW_DIR or $VIEW_DIR" >&2
    exit 1
fi

if [ "$interactive_peer_status" -ne 0 ] ||
        [ "$uart_driver_status" -ne 0 ]; then
    echo "FAIL $RUN_LABEL: interactive HTTPd integration failed" >&2
    echo "artifacts: $ARTIFACT_DIR" >&2
    exit 1
fi

echo "PASS $RUN_LABEL ($view_count views, one boot)"
