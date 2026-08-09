#!/usr/bin/env bash
# Standalone-kernel QEMU/AArch64 integration runner (GitHub issue #237).
#
# Structurally mirrors scripts/run_kernel_hwtest_rpi5.sh's "one capture,
# several independent views" pattern (see that script's own header): a
# single boot's UART transcript is projected through every kernel/tests/
# qemu/views/*.filter and compared exactly against the matching
# *.expected file. Unlike the RPi5 runner, this needs no SWD/reset/
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
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
VIEW_DIR="$REPO_ROOT/kernel/tests/qemu/views"
ARTIFACT_DIR="${KERNEL_QEMU_HWTEST_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-hwtest-qemu}"
UART_LOG="$ARTIFACT_DIR/uart.log"
TIMEOUT_SECS="${KERNEL_QEMU_TIMEOUT:-10}"

mkdir -p "$ARTIFACT_DIR"
exec 9>"$ARTIFACT_DIR/runner.lock"
if ! flock -n 9; then
    echo "FAIL kernel/qemu: another QEMU runner already owns $ARTIFACT_DIR" >&2
    exit 1
fi
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF (run 'make kernelbuild-qemu' first)" >&2
    exit 1
fi

echo "[kernel/qemu] booting kernel.elf under QEMU (timeout ${TIMEOUT_SECS}s)"
# This kernel's fn main() never exits (a final `while (true) {}` park,
# same as RPi5's) -- there is no clean-exit signal to wait for, so
# `timeout` killing QEMU (exit 124, or 137 if SIGTERM needed a SIGKILL
# follow-up) is the EXPECTED completion path, not a failure. Only some
# OTHER exit status (e.g. QEMU itself rejecting an argument, or the
# guest crashing QEMU) is a real error.
qemu_status=0
timeout "$TIMEOUT_SECS" qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -smp 2 -m 1024 -nographic \
    -kernel "$ELF" >"$UART_LOG" 2>&1 || qemu_status=$?
if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ] && [ "$qemu_status" -ne 137 ]; then
    echo "error: qemu-system-aarch64 exited with status $qemu_status" >&2
    cat "$UART_LOG" >&2
    exit 1
fi
if [ ! -s "$UART_LOG" ]; then
    echo "error: no UART output captured -- kernel did not boot" >&2
    exit 1
fi
tr -d '\r' <"$UART_LOG" >"$UART_LOG.normalized"

# One boot, several independent views -- see this file's header and
# scripts/run_kernel_hwtest_rpi5.sh's own identical loop.
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
        echo "FAIL kernel/qemu view: $name" >&2
        diff -u "$expected" "$actual" >&2 || true
        echo "artifacts: $ARTIFACT_DIR" >&2
        exit 1
    fi
    echo "PASS kernel/qemu view: $name"
    view_count=$((view_count + 1))
done

if [ "$view_count" -eq 0 ]; then
    echo "error: no kernel integration views found under $VIEW_DIR" >&2
    exit 1
fi

echo "PASS kernel/qemu ($view_count views, one boot)"
