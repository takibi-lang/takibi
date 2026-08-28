#!/usr/bin/env bash
# GitHub issue #414: the rollback chain inside scheduled_process_alloc has
# never run. Every resource it acquires -- the pool record, the kernel stack
# run, the address-space root and its backing record, the image record, the
# fd context -- can fail, and each failure has to give back everything
# acquired before it. The arrays these replaced could not fail, so the whole
# chain is a failure mode the pooling introduced and nothing exercised.
#
# Reaching it honestly needs the page allocator genuinely empty (800 MiB),
# which no probe does. This lane makes it empty for the duration of ONE
# acquisition, from the debugger side, the way
# scripts/run_kernel_qemutest_lifecycle_gap.sh and
# scripts/run_kernel_oops_qemutest.sh already poke kernel state without a
# kernel-side test switch. See scripts/kernel_alloc_rollback.gdb for what is
# poked, where it arms, and why the restore point is the exhaustion log call.
#
# The verdict is the kernel's own end-of-run accounting, not the injection:
#
#   - `resource exhausted: physical page allocator capacity=204800` proves
#     the injected failure was actually reached and reported.
#   - `resources: pooled per-process records back to the baseline` proves
#     the rollback gave back the process record, the address-space backing,
#     the image record and the fd context. A pool keeps its chunk page
#     whether or not the record inside it came back, so this is the line
#     that can see a leaked RECORD; the page line below cannot.
#   - `resources: pages=0` proves the stack run was parked and the root's
#     tables were freed rather than leaked.
#   - `resources: no double free` proves the rollback did not give anything
#     back twice, which is the other way a rollback chain fails.
#
# The boot itself is expected to survive: one process creation is refused,
# its caller reports, and the run continues. A view of that boot may
# legitimately differ from the normal lane's (whichever fixture lost its
# process says so), which is why this lane checks the four accounting lines
# rather than the view fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel-debug.elf"
COMMON_VIEW_DIR="$REPO_ROOT/kernel/tests/common/views"
ASH_DIR="$REPO_ROOT/kernel/tests/common/ash"
ARTIFACT_DIR="${KERNEL_QEMU_ALLOC_ROLLBACK_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-alloc-rollback-qemu}"
UART_LOG="$ARTIFACT_DIR/uart.log"
UART_DRIVER_LOG="$ARTIFACT_DIR/uart-driver.log"
PEER_LOG="$ARTIFACT_DIR/net-peer.log"
INTERACTIVE_HTTPD_LISTENER="$ARTIFACT_DIR/interactive-httpd.listener"
INTERACTIVE_HTTPD_READY="$ARTIFACT_DIR/interactive-httpd.ready"
INTERACTIVE_HTTPD_DONE="$ARTIFACT_DIR/interactive-httpd.done"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
# Every kernelcheck-*-qemu lane can run CONCURRENTLY (`make kernelcheck`
# builds with -j by default, see AGENTS.md), so these four numbers must not
# collide with any other lane's. The claims are spread across two places --
# a script's own defaults and the Makefile's `env KERNEL_..._PORT=` recipe
# overrides -- and this file originally took 18683-18686 because only the
# first place was checked: 18683-18685 are kernelcheck-qemu-debug's, set in
# the Makefile, and the collision surfaced as that lane's host peer timing
# out with no UART output, blaming a kernel that was never asked anything.
# scripts/check_qemu_lane_ports.py now reads BOTH places and fails the build
# on a duplicate protocol:port claim, so this comment is no longer the thing
# keeping them apart.
SERIAL_PORT="${KERNEL_QEMU_ALLOC_ROLLBACK_SERIAL_PORT:-18689}"
GDB_PORT="${KERNEL_QEMU_ALLOC_ROLLBACK_GDB_PORT:-18690}"
TIMEOUT_SECS="${KERNEL_QEMU_ALLOC_ROLLBACK_TIMEOUT:-90}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_ALLOC_ROLLBACK_NETDEV_LOCAL_PORT:-18691}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_ALLOC_ROLLBACK_NETDEV_REMOTE_PORT:-18692}"
mkdir -p "$ARTIFACT_DIR"
rm -f "$INTERACTIVE_HTTPD_LISTENER" "$INTERACTIVE_HTTPD_READY" \
    "$INTERACTIVE_HTTPD_DONE"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL kernel/qemu alloc-rollback: another runner already owns $ARTIFACT_DIR" >&2
    exit 1
fi
# GitHub issue #407: see scripts/qemu_port_guard.py. Refuse to start if
# somebody already owns this lane's ports, and say that rather than
# reporting a kernel that was never asked anything.
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu alloc-rollback" \
    "tcp:$SERIAL_PORT" "tcp:$GDB_PORT" \
    "udp:$NETDEV_LOCAL_PORT" "udp:$NETDEV_REMOTE_PORT" || exit 1
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF (run 'make kernelbuild-qemu-debug' first)" >&2
    exit 1
fi
if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-alloc-rollback-qemu" >&2
    exit 1
fi

echo "[kernel/qemu alloc-rollback] booting kernel-debug.elf under QEMU+GDB"
qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -display none -monitor none \
    -serial "tcp:127.0.0.1:$SERIAL_PORT,server=on,wait=on" \
    -global virtio-mmio.force-legacy=on \
    -drive "file=$QEMU_EXT2_IMAGE,if=none,format=raw,id=vd0" \
    -device virtio-blk-device,drive=vd0 \
    -netdev "dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=$NETDEV_LOCAL_PORT,remote.type=inet,remote.host=127.0.0.1,remote.port=$NETDEV_REMOTE_PORT" \
    -device virtio-net-device,netdev=net0,mac=02:00:20:00:00:02,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off \
    -S -gdb "tcp::$GDB_PORT" \
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

# No --validate-ash here, unlike every other lane: one process creation in
# this boot is deliberately refused, so whichever fixture loses its process
# says so, and holding the shell transcript to the normal lane's fixture
# would fail this run for the thing it is testing. The driver still drives
# stdin and still stops on the accounting marker; what this lane asserts is
# the accounting, checked below.
#
# Start the UART driver now, before arming GDB: QEMU's serial chardev is
# `wait=on`, and -S leaves the vCPU halted until GDB's own `continue` below,
# so nothing would ever satisfy that wait if the driver only connected
# afterward -- the guest's very first UART write would block forever with
# no client attached. Starting the driver first (same relative order as
# scripts/run_kernel_qemutest.sh's normal lane) lets it connect immediately
# while the vCPU is still halted, then sit idle until GDB unhalts it.
python3 "$REPO_ROOT/scripts/run_kernel_uart_driver.py" \
    --port "socket://127.0.0.1:$SERIAL_PORT" --log "$UART_LOG" \
    --stdin "$ASH_DIR/ash.stdin" --expected "$ASH_DIR/ash.expected" \
    --timeout "$TIMEOUT_SECS" --stop-marker 'resources: pages=0' \
    --interactive-httpd-listener-file "$INTERACTIVE_HTTPD_LISTENER" \
    --interactive-httpd-ready-file "$INTERACTIVE_HTTPD_READY" \
    --interactive-httpd-done-file "$INTERACTIVE_HTTPD_DONE" \
    >"$UART_DRIVER_LOG" 2>&1 &
uart_driver_pid=$!

# Arm the injection: three stops (arm after the baseline, inject, restore),
# after which GDB's batch command list ends and it detaches -- which resumes
# the guest, the same automatic behaviour the lifecycle-gap lane relies on.
# The whole sequence is over before the boot suite's first fixture, so
# nothing here holds the run.
#
# `target remote` is retried the same way and for the same reason as the
# other lanes: QEMU's gdbstub not listening yet is a genuine, short-lived
# race against its own startup. A connected session that did not reach both
# of its markers is a real failure of this lane, not a race, so it is not
# retried.
gdb_log="$ARTIFACT_DIR/arm-gdb.log"
armed=false
for _ in $(seq 1 50); do
    timeout "$TIMEOUT_SECS" gdb-multiarch -q -batch "$ELF" \
        -ex "target remote :$GDB_PORT" \
        -x "$REPO_ROOT/scripts/kernel_alloc_rollback.gdb" \
        >"$gdb_log" 2>&1 || true
    if grep -q 'could not connect\|Connection refused' "$gdb_log"; then
        sleep 0.1
        continue
    fi
    if grep -q 'alloc-rollback: injected' "$gdb_log" &&
       grep -q 'alloc-rollback: restored' "$gdb_log"; then
        armed=true
    fi
    break
done
if [ "$armed" != true ]; then
    echo "FAIL kernel/qemu alloc-rollback: GDB never armed the injected allocation failure" >&2
    sed 's/^/  /' "$gdb_log" >&2 || true
    exit 1
fi

echo "[kernel/qemu alloc-rollback] driving host-side network peer (ARP/ICMP/TCP)"
peer_status=0
timeout "$TIMEOUT_SECS" python3 -u "$REPO_ROOT/scripts/kernel_net_test.py" \
    "$NETDEV_LOCAL_PORT" "$NETDEV_REMOTE_PORT" \
    --interactive-ready-file "$INTERACTIVE_HTTPD_LISTENER" \
    >"$PEER_LOG" 2>&1 || peer_status=$?
sed 's/^/  /' "$PEER_LOG"

touch "$INTERACTIVE_HTTPD_DONE"
uart_driver_status=0
wait "$uart_driver_pid" || uart_driver_status=$?
stop_qemu
trap - EXIT INT TERM HUP

sed 's/^/  /' "$UART_DRIVER_LOG"

if ! grep -q '^resource exhausted: physical page allocator capacity=204800' "$UART_LOG"; then
    echo "FAIL kernel/qemu alloc-rollback: the kernel never reported the injected exhaustion" >&2
    echo "artifacts: $ARTIFACT_DIR" >&2
    exit 1
fi
missing=""
for line in \
    'resources: pooled per-process records back to the baseline' \
    'resources: pages=0' \
    'resources: no double free'; do
    if ! grep -qF "$line" "$UART_LOG"; then
        missing="$missing
  $line"
    fi
done
if [ -n "$missing" ]; then
    echo "FAIL kernel/qemu alloc-rollback: the rollback did not give everything back" >&2
    echo "missing from the end-of-run accounting:$missing" >&2
    grep -E '^resources:|^resource exhausted:|^process table: records MISSING' "$UART_LOG" >&2 || true
    echo "artifacts: $ARTIFACT_DIR" >&2
    exit 1
fi

echo "PASS kernel/qemu alloc-rollback: one acquisition refused mid-chain, every record and page given back"
