#!/usr/bin/env bash
# Standalone-kernel RPi5 integration runner (GitHub issue #177).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL_DEV="${RPI5_SERIAL_DEV:-$($REPO_ROOT/scripts/rpi5_uart_dev.sh)}"
ELF="$REPO_ROOT/kernel/build/rpi5/kernel.elf"
VIEW_DIR="$REPO_ROOT/kernel/tests/rpi5/views"
COMMON_VIEW_DIR="$REPO_ROOT/kernel/tests/common/views"
ASH_DIR="$REPO_ROOT/kernel/tests/common/ash"
ARTIFACT_DIR="${RPI5_KERNEL_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-rpi5}"
UART_LOG="$ARTIFACT_DIR/uart.log"
UART_TIMING_LOG="$ARTIFACT_DIR/uart-timing.log"
RESET_LOG="$ARTIFACT_DIR/reset.log"
LOADER_LOG="$ARTIFACT_DIR/loader.log"
ARP_LOG="$ARTIFACT_DIR/arp.log"
ICMP_LOG="$ARTIFACT_DIR/icmp.log"
TCP_LOG="$ARTIFACT_DIR/tcp.log"
HTTPD_LOG="$ARTIFACT_DIR/httpd-curl.log"
HTTPD_BODY="$ARTIFACT_DIR/httpd-body.actual"
SECOND_HTTPD_LOG="$ARTIFACT_DIR/httpd-curl-second.log"
SECOND_HTTPD_BODY="$ARTIFACT_DIR/httpd-body-second.actual"
INTERACTIVE_ARP_LOG="$ARTIFACT_DIR/interactive-httpd-arp.log"
INTERACTIVE_HTTPD_LISTENER="$ARTIFACT_DIR/interactive-httpd.listener"
INTERACTIVE_HTTPD_READY="$ARTIFACT_DIR/interactive-httpd.ready"
INTERACTIVE_HTTPD_DONE="$ARTIFACT_DIR/interactive-httpd.done"
SOCKET_ACCEPT_LOG="$ARTIFACT_DIR/socket-accept.log"
ETH_TEST_IFACE="${ETH_TEST_IFACE:-enp5s0}"
ETH_TEST_SUBNET="${ETH_TEST_SUBNET:-192.168.20}"
ETH_TEST_MAC="${ETH_TEST_MAC:-02:00:20:00:00:02}"
ETH_TEST_HOST_IP="${ETH_TEST_HOST_IP:-192.168.20.1}"

mkdir -p "$ARTIFACT_DIR"
rm -f "$INTERACTIVE_HTTPD_LISTENER" "$INTERACTIVE_HTTPD_READY" \
    "$INTERACTIVE_HTTPD_DONE"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL kernel/rpi5: another hardware runner already owns $ARTIFACT_DIR" >&2
    exit 1
fi
# The lock above covers this clone's artifact directory. The board is shared by
# every clone, so take its lease before touching the device.
. "$REPO_ROOT/scripts/resource_lease.sh"
resource_lease_acquire rpi5 "kernelcheck-rpi5" || exit 1
if [ ! -e "$SERIAL_DEV" ]; then
    echo "error: RPi5 UART device not found: $SERIAL_DEV" >&2
    exit 1
fi
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    exit 1
fi
if ! python3 -c 'import serial' >/dev/null 2>&1; then
    echo "error: pyserial is required; install it with: sudo apt-get install python3-serial" >&2
    exit 1
fi

# A killed test runner cannot execute its EXIT trap. In that case its
# background pyserial driver can survive under PID 1 and compete with the next
# run for bytes from the same tty; each reader then receives only fragments.
# Remove only this script's exact, same-user orphan shape. Never take the
# device away from an interactive terminal or another program.
for holder_pid in $(fuser "$SERIAL_DEV" 2>/dev/null || true); do
    [ -r "/proc/$holder_pid/cmdline" ] || continue
    if [ "$(stat -c %u "/proc/$holder_pid" 2>/dev/null || echo -1)" != "$(id -u)" ]; then
        echo "error: RPi5 UART is held by another user (PID $holder_pid)" >&2
        exit 1
    fi
    mapfile -d '' -t holder_argv <"/proc/$holder_pid/cmdline"
    holder_cmdline="$(tr '\0' ' ' <"/proc/$holder_pid/cmdline")"
    stale_driver=0
    if [[ "$holder_cmdline" == *run_kernel_uart_driver.py* &&
          "$holder_cmdline" == *"--port $SERIAL_DEV"* ]]; then
        stale_driver=1
    elif [ "${#holder_argv[@]}" -eq 2 ] &&
            [ "${holder_argv[0]##*/}" = cat ] &&
            [ "${holder_argv[1]}" = "$SERIAL_DEV" ]; then
        stale_driver=1
    fi
    if [ "$stale_driver" -eq 1 ] &&
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
    resource_lease_board_failed
    exit 1
fi

# Peripheral FIFO contents survive SWD injection and the resident stub may
# have emitted bytes before it was reset. Drain that history before opening
# the capture used as evidence for this payload.
timeout 1 cat "$SERIAL_DEV" >/dev/null 2>&1 || true

: >"$UART_LOG"
# SWD load time grows with embedded initramfs images. Keep the common pyserial
# driver alive through the entire load; it owns both capture and ash input.
python3 "$REPO_ROOT/scripts/run_kernel_uart_driver.py" \
    --port "$SERIAL_DEV" --log "$UART_LOG" --timing-log "$UART_TIMING_LOG" --timeout 180 \
    --stdin "$ASH_DIR/ash.stdin" --expected "$ASH_DIR/ash.expected" \
    --stop-marker 'resources: pages=0' \
    --interactive-httpd-listener-file "$INTERACTIVE_HTTPD_LISTENER" \
    --interactive-httpd-ready-file "$INTERACTIVE_HTTPD_READY" \
    --interactive-httpd-done-file "$INTERACTIVE_HTTPD_DONE" \
    --workload-marker 'workload: busy pair done' \
    --validate-ash &
uart_driver_pid=$!
archive_reason=""
cleanup() {
    status=$?
    if [ -n "${uart_driver_pid:-}" ]; then
        kill "$uart_driver_pid" 2>/dev/null || true
        wait "$uart_driver_pid" 2>/dev/null || true
    fi
    if [ "$status" -ne 0 ]; then
        bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" \
            "$REPO_ROOT/_build/kernel-hwtest-rpi5-failures" \
            "${archive_reason:-exit status $status}" || true
    fi
    if [ -n "${pinned_neigh:-}" ]; then
        sudo ip neigh del "${ETH_TEST_SUBNET}.2" dev "$ETH_TEST_IFACE" \
            2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM HUP

sleep 0.2
load_started=$SECONDS
echo "[kernel/rpi5] loading kernel over SWD"
if ! "$REPO_ROOT/scripts/rpi5_jtag_load.sh" "$ELF" >"$LOADER_LOG" 2>&1; then
    echo "FAIL kernel/rpi5: load failed (see $LOADER_LOG)" >&2
    resource_lease_board_failed
    exit 1
fi
# Reset and load both answered over SWD, so the board itself is responding.
# Whether the tests below pass is a different question from whether the next
# session will find a board that needs a power cycle.
resource_lease_board_ok
echo "[kernel/rpi5] kernel loaded in $((SECONDS - load_started))s; waiting for integration completion"

# GitHub issue #387: ONE readiness gate, before the FIRST wire test, rather
# than one answer per script.
#
# What this replaces: the three wire tests below used to start the moment
# rpi5_jtag_load.sh returned -- which is when SWD finished injecting, not
# when the board can answer. eth_arp_reply_test.py does retry (RETRIES = 20
# at RETRY_TIMEOUT_SECS = 0.5), so it tolerates ten seconds of silence; that
# budget had to cover boot, PCIe enumeration, RP1 GEM bring-up and PHY
# auto-negotiation, and when it did not, a board that was simply not up yet
# was reported as "ARP integration failed". Measured 2026-08-30: three of
# five consecutive runs failed on the wire tests while the change under test
# was clean.
#
# The kernel already says when it is ready. Waiting for it costs nothing on
# a healthy run and turns a misattributed protocol failure into an accurate
# one -- the same fix the TCP flake took on 2026-08-02, which was the test
# harness firing before the kernel was listening rather than anything in
# kernel/net/tcp.tkb.
#
# The elapsed time is printed because it is GitHub issue #411's number and
# this wait measures it directly: a ten-second retry budget against a boot
# nobody had timed is exactly the pairing that issue was opened about.
echo "[kernel/rpi5] waiting for the RP1 GEM link"
link_started=$SECONDS
link_ready=0
for _wait in $(seq 1 600); do
    if LC_ALL=C grep -aFq 'rp1 gem: link ready' "$UART_LOG"; then
        link_ready=1
        break
    fi
    # A failed bring-up is a different answer from a slow one, and the
    # kernel distinguishes them. Say so immediately instead of spending the
    # whole window discovering it.
    if LC_ALL=C grep -aFq 'rp1 gem: link failed' "$UART_LOG"; then
        echo "FAIL kernel/rpi5: the kernel reported 'rp1 gem: link failed' (see $UART_LOG)" >&2
        exit 1
    fi
    sleep 0.1
done
if [ "$link_ready" -ne 1 ]; then
    echo "FAIL kernel/rpi5: the kernel never announced 'rp1 gem: link ready' (see $UART_LOG) -- the board did not reach a usable link, which is NOT a protocol defect in the tests below" >&2
    exit 1
fi
echo "[kernel/rpi5] RP1 GEM link ready $((SECONDS - link_started))s after load"

# GitHub issue #387: stop the HOST from asking, because the board can only
# answer once.
#
# kernel/platform/rpi5/init.tkb calls kernel_arp_reply_once(link_ready): the
# affine RX readiness capability is spent on exactly ONE real ARP request,
# by design, because spending it once is what the fixture proves. So
# whichever request arrives first gets the reply -- and the host has its own
# reason to send one. `ip neigh` keeps an entry for the board from the
# previous run's TCP and HTTP traffic; it goes STALE between runs and Linux
# re-probes it unprompted. That probe consumes the board's single reply, and
# the test's own `who-has 192.168.20.2` then times out against a kernel that
# has already moved on.
#
# Both observed failure shapes are that one cause: the probe's reply landing
# inside the negative control's window (reported as "unexpected reply for a
# non-owned IP", though its SPA was the board's OWN address), and the
# positive test failing outright.
#
# A permanent neighbour entry means Linux never asks. It does not weaken
# either assertion: eth_arp_reply_test.py builds raw frames on AF_PACKET and
# bypasses the neighbour table entirely, so both its request and the board's
# reply still traverse the whole path. Removed again on exit rather than
# left behind, since a test should not permanently edit the host's network
# state.
echo "[kernel/rpi5] pinning the board's neighbour entry so the host does not ARP for it"
sudo ip neigh replace "${ETH_TEST_SUBNET}.2" lladdr "$ETH_TEST_MAC" \
    dev "$ETH_TEST_IFACE" nud permanent
pinned_neigh=1

# The kernel holds its affine RX readiness capability while waiting for one
# real ARP request. Exercise the wire path now that the link exists and the
# host has been told not to compete for that one reply; keep the raw-socket
# privilege confined to the existing protocol checker.
echo "[kernel/rpi5] checking ARP reply on $ETH_TEST_IFACE"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ARP_TEST_REQUESTER_IP="$ETH_TEST_HOST_IP" \
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

# GitHub issue #195: vm-layout completion is earlier than socket/bind/listen
# and therefore is not evidence that the connected-I/O endpoint is ready.
# Wait for the unique fixture-scoped post-listen marker. An unconditional
# listen marker would match the earlier BusyBox daemon in the same UART log.
echo "[kernel/rpi5] waiting for the kernel to be ready for the userspace connected-I/O fixture"
userspace_ready=0
for _wait in $(seq 1 600); do
    if LC_ALL=C grep -aFq 'linux socket: listener ready port=8080' "$UART_LOG"; then
        userspace_ready=1
        break
    fi
    sleep 0.1
done
if [ "$userspace_ready" -ne 1 ]; then
    echo "FAIL kernel/rpi5: kernel never reached the userspace-fixture readiness marker (see $UART_LOG)" >&2
    exit 1
fi

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

# GitHub issue #187: the kernel injects a one-shot SYN-ACK drop right
# before starting the real BusyBox HTTPd daemon (kernel_tcp_inject_drop_
# next_syn_ack(), kernel/platform/rpi5/init.tkb), so its own bounded retransmit
# budget (TCP_RETRY_LIMIT * retry_ticks, kernel/net/tcp.tkb) can race
# against curl's connection timeout if the FIRST curl attempt's SYN
# happens to arrive while the kernel is still busy with the earlier
# USB-ext2 provisioning step (measured to vary by roughly 10x in wall-clock
# time between otherwise-identical real-hardware runs). Waiting for the
# kernel's actual userspace `listen(2)` marker here, instead of firing curl
# at the image-map marker, means curl's first SYN can only arrive once the
# daemon has published its listening socket -- decoupling this race from
# userspace startup and USB provisioning time
# entirely without touching tcp.tkb's own timing constants or weakening
# what the drop-recovery check proves (still the real daemon's real
# accept() path, still a real dropped packet).
echo "[kernel/rpi5] waiting for the kernel to be ready to start the BusyBox httpd daemon"
httpd_ready=0
for _wait in $(seq 1 600); do
    if LC_ALL=C grep -aFq 'foreground server: listener ready port=8080' "$UART_LOG"; then
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
    if httpd_type="$(curl --silent --show-error --fail \
            --interface "$ETH_TEST_IFACE" --noproxy '*' \
            --connect-timeout 5 --max-time 10 \
            --write-out '%{content_type}' \
            --output "$HTTPD_BODY" \
            "http://${ETH_TEST_SUBNET}.2:8080/" 2>"$HTTPD_LOG")"; then
        if cmp -s "$REPO_ROOT/kernel/tests/ext2/index.html" "$HTTPD_BODY" &&
                [ "$httpd_type" = "text/html" ]; then
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
    if second_httpd_type="$(curl --silent --show-error --fail \
            --interface "$ETH_TEST_IFACE" --noproxy '*' \
            --connect-timeout 5 --max-time 10 \
            --write-out '%{content_type}' \
            --output "$SECOND_HTTPD_BODY" \
            "http://${ETH_TEST_SUBNET}.2:8080/" 2>"$SECOND_HTTPD_LOG")"; then
        if cmp -s "$REPO_ROOT/kernel/tests/ext2/index.html" "$SECOND_HTTPD_BODY" &&
                [ "$second_httpd_type" = "text/html" ]; then
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
            LC_ALL=C grep -aFq 'busybox interactive shell exit: 0' "$UART_LOG" &&
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

# The bounded userspace suite is now complete and has recorded pages=0. The
# same boot installs one final interactive ash. Start the network checks as
# soon as its HTTPd child publishes the listener; waiting first for the shell
# to resume deadlocks against accept4()'s 30-second deadline, because the
# child owns the single RX capability until the first request arrives. The
# separate ready file below still proves the parent shell resumed afterwards.
interactive_listener=0
for _wait in $(seq 1 600); do
    if [ -f "$INTERACTIVE_HTTPD_LISTENER" ]; then
        interactive_listener=1
        break
    fi
    if ! kill -0 "$uart_driver_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if [ "$interactive_listener" -ne 1 ]; then
    echo "FAIL kernel/rpi5: interactive background HTTPd did not publish its listener" >&2
    exit 1
fi

echo "[kernel/rpi5] checking ARP while interactive HTTPd is listening"
if ! sudo ETH_TEST_IFACE="$ETH_TEST_IFACE" ETH_TEST_SUBNET="$ETH_TEST_SUBNET" \
        ARP_TEST_REQUESTER_IP="$ETH_TEST_HOST_IP" \
        ARP_TEST_OTHER_FIRST=1 \
        python3 "$REPO_ROOT/scripts/eth_arp_reply_test.py" \
        > >(tee "$INTERACTIVE_ARP_LOG") 2>&1; then
    echo "FAIL kernel/rpi5: interactive HTTPd ARP check failed" >&2
    exit 1
fi

interactive_assets=(
    "root|/|index.html|text/html"
    "index|/index.html|index.html|text/html"
    "about|/about.html|about.html|text/html"
    "icon|/icon.png|icon.png|image/png"
)
for asset_spec in "${interactive_assets[@]}"; do
    IFS='|' read -r asset_name asset_path asset_file asset_type <<<"$asset_spec"
    interactive_body="$ARTIFACT_DIR/interactive-httpd-$asset_name.actual"
    interactive_log="$ARTIFACT_DIR/interactive-httpd-$asset_name.log"
    echo "[kernel/rpi5] curling interactive background HTTPd $asset_path"
    interactive_httpd_ok=0
    for _attempt in $(seq 1 20); do
        if interactive_type="$(curl --silent --show-error --fail \
                --interface "$ETH_TEST_IFACE" --noproxy '*' \
                --connect-timeout 5 --max-time 10 \
                --write-out '%{content_type}' \
                --output "$interactive_body" \
                "http://${ETH_TEST_SUBNET}.2:8080${asset_path}" \
                2>"$interactive_log")"; then
            if cmp -s "$REPO_ROOT/kernel/tests/ext2/$asset_file" \
                    "$interactive_body" &&
                    [ "$interactive_type" = "$asset_type" ]; then
                interactive_httpd_ok=1
                break
            fi
            echo "unexpected response body or content type: $interactive_type" \
                >"$interactive_log"
            break
        fi
        sleep 0.25
    done
    if [ "$interactive_httpd_ok" -ne 1 ]; then
        echo "FAIL kernel/rpi5: interactive HTTPd curl $asset_path failed (see $interactive_log)" >&2
        exit 1
    fi
done

interactive_ready=0
for _wait in $(seq 1 600); do
    if [ -f "$INTERACTIVE_HTTPD_READY" ]; then
        interactive_ready=1
        break
    fi
    if ! kill -0 "$uart_driver_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if [ "$interactive_ready" -ne 1 ]; then
    echo "FAIL kernel/rpi5: interactive shell did not resume after HTTPd started" >&2
    exit 1
fi
touch "$INTERACTIVE_HTTPD_DONE"
uart_driver_status=0
wait "$uart_driver_pid" || uart_driver_status=$?
uart_driver_pid=""
if [ "$uart_driver_status" -ne 0 ]; then
    echo "FAIL kernel/rpi5: interactive HTTPd UART validation failed" >&2
    exit 1
fi
echo "[kernel/rpi5] interactive background HTTPd passed"

python3 "$REPO_ROOT/scripts/validate_kernel_dmesg_timestamps.py" \
    --platform rpi5 "$UART_LOG"
python3 "$REPO_ROOT/scripts/profile_kernel_workload.py" collect \
    --uart-log "$UART_LOG" --output "$ARTIFACT_DIR/busy-pair-profile.json" \
    --target rpi5

# GitHub issue #501: the same bounded event contract and Perfetto export as
# QEMU, with real interrupt timing checked on the Cortex-A76 board.
python3 "$REPO_ROOT/scripts/profile_kernel_workload.py" timeline \
    --uart-log "$UART_LOG" \
    --output "$ARTIFACT_DIR/busy-pair-perfetto.json" --target rpi5 \
    --require-kind schedule-out --require-kind schedule-in \
    --require-kind syscall-enter --require-kind syscall-exit \
    --require-kind irq-enter --require-kind irq-exit

# GitHub issue #500: the flat PC samples the same interval collected, and
# the only run of them that is performance evidence -- QEMU's cycle counter
# is virtual time, this one is a real Cortex-A76 PMU. See the QEMU runner
# for why the collector is the assertion and why llvm-addr2line-19.
python3 "$REPO_ROOT/scripts/profile_kernel_samples.py" \
    --uart-log "$UART_LOG" \
    --output "$ARTIFACT_DIR/busy-pair-flat-pc.json" \
    --kernel-elf "$ELF" --target rpi5 --min-samples 1 \
    --symbolizer llvm-addr2line-19 \
    --commit "$(git -C "$REPO_ROOT" rev-parse HEAD)"

cleanup
trap - EXIT INT TERM HUP

# The ordinary integration has completed and released the UART. Enable the
# debugger-only ring and guarded-fault command on this already-loaded kernel,
# then prove real Debug Probe CDC BREAK entry, fault recovery, inspection, and
# resume into the same shell workload.
DDB_LOG="$ARTIFACT_DIR/ddb-uart.log"
: >"$DDB_LOG"
RPI5_SWD_SPEED="${RPI5_SWD_SPEED:-}" \
    "$REPO_ROOT/scripts/rpi5_set_kernel_byte.sh" "$ELF" \
    diagnostic_trace_test_enabled 1 >"$ARTIFACT_DIR/ddb-openocd.log" 2>&1
RPI5_SWD_SPEED="${RPI5_SWD_SPEED:-}" \
    "$REPO_ROOT/scripts/rpi5_set_kernel_byte.sh" "$ELF" \
    kernel_ddb_memory_fault_test_enabled 1 >>"$ARTIFACT_DIR/ddb-openocd.log" 2>&1
python3 "$REPO_ROOT/scripts/run_kernel_ddb_rpi5_driver.py" \
    --port "$SERIAL_DEV" --log "$DDB_LOG"

# The real UART echoes a shell command immediately after the prompt, so a
# command's short output can arrive as `/ # repl-ok` rather than as a separate
# line. Views describe semantic output, not the interactive prompt; normalize
# that prefix before projecting the shared capture.
# The persistent-shell checkpoints name the tracked child's pid, and a pid
# is minted monotonically rather than read off the process slot (issue
# #392), so its VALUE counts how many processes the boot created before
# this fixture -- an artifact of fixture order, not of what this view
# means. That the four checkpoints all name the SAME child is enforced in
# the kernel, which logs each of the last three only on a match against
# the pid the fork checkpoint recorded.
sed -e 's|^/ # ||' \
    -e 's|^\(persistent shell: [a-z ]*\)pid=[0-9][0-9]*$|\1pid=<child>|' \
    <"$UART_LOG" | tr -d '\r' >"$UART_LOG.normalized"

# One boot, several independent views. Common views are supplemented by
# platform-specific views; a platform file overrides a common file with the
# same name. Each filter projects the shared UART transcript onto one
# contract, whose expected file is then compared exactly.
# Adding a subsystem test does not require another reset/load cycle.
# Same purge, same reason, as scripts/run_kernel_qemutest.sh's own loop: the
# comparison stops at the first mismatch, so a leftover .actual from the
# previous run reads like this run's output and is not.
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
        # Report and keep going, then archive once after the loop. Stopping
        # at the first mismatch made the output say one view failed when
        # several had, because every view after it was never compared.
        echo "FAIL kernel/rpi5 view: $name" >&2
        diff -u "$expected" "$actual" >&2 || true
        failed_views="$failed_views $name"
        continue
    fi
    echo "PASS kernel/rpi5 view: $name"
    view_count=$((view_count + 1))
done <<<"$view_names"

if [ -n "$failed_views" ]; then
    echo "FAIL kernel/rpi5 views:$failed_views" >&2
    echo "artifacts: $ARTIFACT_DIR" >&2
    # The archive is taken by the EXIT trap now (issue #233's reasoning,
    # widened): it used to happen only here, so every failure that stops
    # EARLIER than the view comparison -- ARP, TCP, the reset, a load --
    # left nothing behind. That is what made issue #387's ARP diagnosis
    # wait for a failure to land on the last run of a batch.
    #
    # Recorded here so the archive names the views rather than only the
    # exit status.
    archive_reason="failing views:$failed_views"
    exit 1
fi

if [ "$view_count" -eq 0 ]; then
    echo "error: no kernel integration views found under $COMMON_VIEW_DIR or $VIEW_DIR" >&2
    exit 1
fi

echo "PASS kernel/rpi5 ($view_count views, one boot)"
