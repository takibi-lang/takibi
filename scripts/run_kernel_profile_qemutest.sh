#!/usr/bin/env bash
# GitHub issue #497: a sampling profile session end to end on QEMU.
#
# Boots the interactive shell kernel, starts a session through
# /proc/takibi/profile, runs a busy EL0 loop pinned to core 1 and a
# kernel-heavy loop, stops, dumps through DDB, and checks that every PMU
# interrupt was accounted and that core 1 sampled. The core-1 requirement
# is the regression test for a secondary whose IRQ dispatch skipped the
# sampler: its level-triggered PMU line stormed and it stored nothing.
# GitHub issue #811: the stop read of /proc/takibi/profile must show an
# irqsoff span whose open and close sites symbolize against the kernel ELF.
# GitHub issue #1320: before that session, two writers on two cores race for
# the start, and each round must have exactly one winner.
# GitHub issue #1339: the same for a stop. A last boot runs the race fixtures on
# a kernel whose claim is a load and a store held apart, and they must see two
# winners of each: a claim that is not atomic does not pass them.
set -euo pipefail
trap 'takibi_status=$?; echo "[$(basename "$0")] aborted at line $LINENO with exit $takibi_status: $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${KERNEL_PROFILE_QEMU_ARTIFACT_DIR:-${TAKIBI_LANE_ARTIFACT_ROOT:-$REPO_ROOT/_build}/kernel-profile-qemu}"
mkdir -p "$ARTIFACT_DIR"
# GitHub issue #877: a failing run's capture was overwritten by the next run
# before anyone read it. Snapshot it on any nonzero exit.
archive_on_failure() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        KERNEL_QEMU_LABEL="kernel-profile-qemu" KERNEL_QEMU_ELF="${ELF:-unknown}" \
            bash "$REPO_ROOT/scripts/archive_kernel_failure.sh" "$ARTIFACT_DIR" \
            "$REPO_ROOT/_build/kernel-profile-qemu-failures" "exit status $status" || true
    fi
    return "$status"
}
trap archive_on_failure EXIT

export KERNEL_QEMU_SHELL_SERIAL_PORT="${KERNEL_QEMU_SHELL_SERIAL_PORT:-18760}"
export KERNEL_QEMU_SHELL_HTTP_PORT="${KERNEL_QEMU_SHELL_HTTP_PORT:-18761}"
export KERNEL_QEMU_SHELL_NETDEV_QEMU_PORT="${KERNEL_QEMU_SHELL_NETDEV_QEMU_PORT:-18762}"
export KERNEL_QEMU_SHELL_NETDEV_PEER_PORT="${KERNEL_QEMU_SHELL_NETDEV_PEER_PORT:-18763}"

python3 "$REPO_ROOT/scripts/profile_kernel_session.py" capture --target qemu \
    --start "start 1000000 1024 16" --http 0 --warmup 0 --two-writers 4 \
    --command "taskset -c 1 sh -c 'i=0; while [ \$i -lt 20000 ]; do i=\$((i+1)); done'; for i in 1 2; do ls -R / >/dev/null; done" \
    --out "$ARTIFACT_DIR"
python3 "$REPO_ROOT/scripts/profile_kernel_session.py" check \
    --console "$ARTIFACT_DIR/console.log" --require-cores 0,1 \
    --elf "$REPO_ROOT/kernel/build/qemu/kernel.elf" --expect-irqsoff --two-writers 4
python3 "$REPO_ROOT/scripts/profile_kernel_session.py" fold \
    --elf "$REPO_ROOT/kernel/build/qemu/kernel.elf" \
    --console "$ARTIFACT_DIR/console.log" --top 10
# The control may die in its double start, so its console decides, not its exit.
CONTROL_ELF="$REPO_ROOT/kernel/build/qemu/kernel-race-1339-load-store-reverted.elf"
KERNEL_QEMU_SHELL_ELF="$CONTROL_ELF" \
    TAKIBI_ARCHIVE_EXPECTED="profile claim control, a non-atomic kernel meant to fail (#1339)" \
    python3 "$REPO_ROOT/scripts/profile_kernel_session.py" capture --target qemu \
    --http 0 --warmup 0 --two-writers 2 --races-only \
    --out "$ARTIFACT_DIR/control" || true
python3 "$REPO_ROOT/scripts/profile_kernel_session.py" check \
    --console "$ARTIFACT_DIR/control/console.log" --expect-double-winners
echo "PASS kernel/qemu profile session: every PMU interrupt accounted, cores 0 and 1 sampled, an irqsoff span measured with symbolized sites, folded stacks written, two-writer stops and starts one winner each, a non-atomic claim caught"
