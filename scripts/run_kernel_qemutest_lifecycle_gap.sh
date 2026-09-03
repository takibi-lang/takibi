#!/usr/bin/env bash
# Issue #289 negative-path regression: proves the host harness's own
# last-completed/next-expected lifecycle diagnosis is correct, not just that
# it never triggers. Mirrors scripts/run_kernel_qemutest.sh's normal
# interactive-HTTPd boot exactly, except QEMU starts under GDB (-S -gdb, the
# same technique scripts/run_kernel_oops_qemutest.sh already uses to patch
# memory purely from the debugger side) so the exec-commit checkpoint's own
# one-shot guard (syscall_persistent_shell_checkpoint_exec_commit_logged,
# kernel/kernel/syscall.tkb) is pre-set to true, via a direct remote memory
# write, right after kernel_process_execution_reset (see below for why that
# specific point, not the very start). The checkpoint function's own
# existing `if (... already_logged) return;` guard then skips its print
# entirely on its own, normal control flow -- no breakpoint or stack-frame
# manipulation needed at the print site itself. The real exec-commit logic
# in its caller (kernel/init/test_driver.tkb) is a separate function and is
# completely untouched: HTTPd still starts and answers real HTTP requests
# normally.
#
# A breakpoint directly on the checkpoint function plus `return` was tried
# first (matching run_kernel_oops_qemutest.sh's own "break, continue,
# return" precedent) but does not work here: this checkpoint function is
# small enough that the compiler inlines it at its one call site, so GDB
# has no distinct frame to pop ("Cannot pop the initial frame"). Poking the
# guard variable directly sidesteps that entirely and needs no new
# dedicated kernel-side test switch -- it reuses the checkpoint mechanism's
# own existing one-shot state.
#
# Three environment-specific quirks found empirically getting this working,
# none of them documented gdb/QEMU behavior, all worth recording:
#
# 1. Writing the guard variable immediately after `target remote` connects
#    (while still halted at reset, before any kernel code has run at all)
#    gets silently undone: this kernel's own startup code zero-clears .bss
#    early in boot, and the guard variable is ordinary .bss, so an early
#    write is simply overwritten back to false once that runs. Breaking at
#    kernel_process_execution_reset first (same breakpoint
#    run_kernel_oops_qemutest.sh's own `child_exec` mode uses, chosen
#    because it's an already-proven-safe point well after .bss clear, not
#    for any property specific to this negative test) and writing only
#    after that breakpoint hits avoids this.
# 2. With `-smp 2`, GDB's default/current thread right after `target
#    remote` is CPU0, which `info threads` reports as "[running]" even
#    though `-S` halted it (confirmed via `0x...40000000 in _start ()`,
#    the correct halt PC) -- attempting to write memory against it fails
#    with "Cannot execute this command while the target is running", even
#    though the machine is genuinely halted. This does not reproduce once
#    stopped at a real breakpoint (as opposed to -S's initial halt), which
#    is a second, independent reason the execution_reset breakpoint above
#    is used rather than writing at the very start.
# 3. `set *(char *)&VAR = 1` against this no-`-g` kernel build reports
#    "has unknown type; cast it to its declared type" -- but the explicit
#    `(char *)` cast means the write still completes despite that message
#    (confirmed by reading the value back with `print`); treating that
#    message as fatal was an earlier, wrong assumption. The `print` below
#    is the actual success oracle, not gdb's own wording.
#
# No further `continue` or `detach` after the write: gdb-multiarch's
# `continue` against THIS remote target does not reliably block the batch
# command list the way it appears to for run_kernel_oops_qemutest.sh's own
# multi-step sequences (chaining almost anything after `continue` here can
# hit "Cannot execute this command while the target is running"), and
# batch mode already detaches cleanly on its own once the command list
# ends (confirmed: "[Inferior 1 (process 1) detached]") -- empirically,
# for a target stopped at a breakpoint (not just -S's initial halt), that
# automatic detach resumes it, so no explicit resume command is needed or
# reliable enough to depend on here.
#
# scripts/run_kernel_uart_driver.py now makes each of the four interactive
# HTTPd lifecycle checkpoints a hard requirement, so this run is expected to
# FAIL with a specific diagnosis naming exec-prepare as the last completed
# checkpoint and exec-commit as the next expected one. This script's own
# PASS/FAIL verdict is about whether that diagnosis appeared correctly, not
# about the kernel boot itself succeeding.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel-debug.elf"
COMMON_VIEW_DIR="$REPO_ROOT/kernel/tests/common/views"
ASH_DIR="$REPO_ROOT/kernel/tests/common/ash"
ARTIFACT_DIR="${KERNEL_QEMU_LIFECYCLE_GAP_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-lifecycle-gap-qemu}"
UART_LOG="$ARTIFACT_DIR/uart.log"
UART_DRIVER_LOG="$ARTIFACT_DIR/uart-driver.log"
PEER_LOG="$ARTIFACT_DIR/net-peer.log"
INTERACTIVE_HTTPD_LISTENER="$ARTIFACT_DIR/interactive-httpd.listener"
INTERACTIVE_HTTPD_READY="$ARTIFACT_DIR/interactive-httpd.ready"
INTERACTIVE_HTTPD_DONE="$ARTIFACT_DIR/interactive-httpd.done"
EXT2_IMAGE="$REPO_ROOT/kernel/build/user/ext2.img"
QEMU_EXT2_IMAGE="$ARTIFACT_DIR/ext2.img"
# 18671-18676 are already claimed by scripts/run_kernel_qemutest.sh and
# scripts/run_kernel_oops_qemutest.sh's own (including Makefile-overridden)
# ports; both Makefiles build with -j by default (see AGENTS.md), so
# `make kernelcheck` can run every kernelcheck-*-qemu lane concurrently --
# these defaults must not collide with any of them.
SERIAL_PORT="${KERNEL_QEMU_LIFECYCLE_GAP_SERIAL_PORT:-18679}"
GDB_PORT="${KERNEL_QEMU_LIFECYCLE_GAP_GDB_PORT:-18680}"
TIMEOUT_SECS="${KERNEL_QEMU_LIFECYCLE_GAP_TIMEOUT:-90}"
NETDEV_LOCAL_PORT="${KERNEL_QEMU_LIFECYCLE_GAP_NETDEV_LOCAL_PORT:-18681}"
NETDEV_REMOTE_PORT="${KERNEL_QEMU_LIFECYCLE_GAP_NETDEV_REMOTE_PORT:-18682}"
mkdir -p "$ARTIFACT_DIR"
rm -f "$INTERACTIVE_HTTPD_LISTENER" "$INTERACTIVE_HTTPD_READY" \
    "$INTERACTIVE_HTTPD_DONE"
cp "$EXT2_IMAGE" "$QEMU_EXT2_IMAGE"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL kernel/qemu lifecycle-gap: another runner already owns $ARTIFACT_DIR" >&2
    exit 1
fi
# GitHub issue #407: see scripts/qemu_port_guard.py. Refuse to start if
# somebody already owns this lane's ports, and say that rather than
# reporting a kernel that was never asked anything.
. "$REPO_ROOT/scripts/qemu_session_ports.sh"
qemu_session_shift_ports SERIAL_PORT GDB_PORT NETDEV_LOCAL_PORT NETDEV_REMOTE_PORT
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu lifecycle-gap" \
    "tcp:$SERIAL_PORT" "tcp:$GDB_PORT" \
    "udp:$NETDEV_LOCAL_PORT" "udp:$NETDEV_REMOTE_PORT" || exit 1
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF (run 'make kernelbuild-qemu-debug' first)" >&2
    exit 1
fi
if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-lifecycle-gap-qemu" >&2
    exit 1
fi

echo "[kernel/qemu lifecycle-gap] booting kernel-debug.elf under QEMU+GDB"
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
    --validate-ash >"$UART_DRIVER_LOG" 2>&1 &
uart_driver_pid=$!

# Skip only the exec-commit checkpoint's own print (a `return` right at its
# breakpoint pops the frame before the body -- the print -- runs); the real
# exec-commit logic in the caller is a separate function and is untouched.
#
# Two distinct waits here, not one retry loop: first, a short poll for the
# gdbstub's own TCP port to accept connections at all (a genuine race
# against QEMU's own startup, resolved within a second or two); then a
# single GDB session whose `continue` may legitimately take most of this
# scenario's boot time to reach the breakpoint (exec-commit is near the end
# of the bounded self-test suite plus the persistent-shell handoff, unlike
# the oops script's much earlier breakpoint), so it gets a generous timeout
# instead of the short per-attempt one that scenario would need. gdb-multiarch
# in -batch mode does not treat a failed `target remote` as fatal to the
# rest of the command list, and can still exit 0 -- this retries on
# `target remote` failures (QEMU's gdbstub not listening yet is a genuine,
# short-lived race) and verifies success by reading the guard variable's
# value back, not by trusting gdb's own exit code or diagnostic wording.
#
# Two environment-specific quirks found empirically, both worth recording
# since neither is documented gdb/QEMU behavior:
#
# 1. With `-smp 2`, GDB's default/current thread after `target remote` is
#    CPU0, which `info threads` reports as "[running]" even though `-S`
#    halted it (confirmed via `0x...40000000 in _start ()`, the correct
#    halt PC) -- attempting to write memory against it fails with "Cannot
#    execute this command while the target is running". CPU1 (this
#    kernel's secondary core, which only proves EL1 entry and parks -- see
#    HISTORY.md) reports correctly as "[halted]", and switching to it
#    (`thread 2`) first works around the write. The guard variable itself
#    is ordinary global BSS, not core-local state, so which thread performs
#    the write doesn't matter otherwise.
# 2. `set *(char *)&VAR = 1` against this no-`-g` kernel build reports
#    "has unknown type; cast it to its declared type" -- but the explicit
#    `(char *)` cast means the write still completes despite that message
#    (confirmed by reading the value back with `print`); treating that
#    message as fatal was an earlier, wrong assumption. The `print` below
#    is the actual success oracle, not gdb's own wording.
#
# No `detach` at the end: gdb-multiarch already detaches cleanly on its own
# once the batch command list ends (confirmed: "[Inferior 1 (process 1)
# detached]"), and chaining more commands after `continue` is unreliable
# here regardless (this remote target's `continue` does not block the batch
# command list the way it appears to for run_kernel_oops_qemutest.sh's
# much-earlier breakpoints).
gdb_commands=(
    -ex "target remote :$GDB_PORT"
    -ex "set confirm off"
    -ex "break kernel_process_execution_reset"
    -ex "continue"
    -ex "set *(char *)&syscall_persistent_shell_checkpoint_exec_commit_logged = 1"
    -ex "print (char)syscall_persistent_shell_checkpoint_exec_commit_logged"
    -ex "disable 1"
)
armed=false
for _ in $(seq 1 50); do
    timeout 20 gdb-multiarch -q -batch "$ELF" "${gdb_commands[@]}" \
            >"$ARTIFACT_DIR/arm-gdb.log" 2>&1 || true
    if grep -q 'could not connect' "$ARTIFACT_DIR/arm-gdb.log"; then
        sleep 0.1
        continue
    fi
    if ! grep -qE "= 1 '\\\\001'" "$ARTIFACT_DIR/arm-gdb.log"; then
        echo "FAIL kernel/qemu lifecycle-gap: GDB could not arm the checkpoint gap" >&2
        sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
        exit 1
    fi
    armed=true
    break
done
if [ "$armed" != true ]; then
    echo "FAIL kernel/qemu lifecycle-gap: QEMU's gdbstub never accepted a connection" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
    exit 1
fi

echo "[kernel/qemu lifecycle-gap] driving host-side network peer (ARP/ICMP/TCP)"
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

expected_diagnosis="last completed checkpoint 'exec-prepare', next expected 'exec-commit'"
if [ "$uart_driver_status" -eq 0 ]; then
    echo "FAIL kernel/qemu lifecycle-gap: harness did not fail despite the skipped checkpoint" >&2
    echo "artifacts: $ARTIFACT_DIR" >&2
    exit 1
fi
if ! grep -qF "$expected_diagnosis" "$UART_DRIVER_LOG"; then
    echo "FAIL kernel/qemu lifecycle-gap: harness failed, but not with the expected diagnosis" >&2
    echo "expected to find: $expected_diagnosis" >&2
    echo "artifacts: $ARTIFACT_DIR" >&2
    exit 1
fi

echo "PASS kernel/qemu lifecycle-gap: harness correctly diagnosed the skipped checkpoint"
