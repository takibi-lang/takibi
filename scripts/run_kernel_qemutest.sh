#!/bin/bash
# QEMU/AArch64 kernel self-test harness: boots the kernel on QEMU and
# captures the full serial output, verifying that all self-tests pass
# without hardware dependencies.

set -u

KERNEL_ELF="${1:-kernel/build/qemu/kernel.elf}"
TIMEOUT_SECS="${2:-30}"

if [ ! -f "$KERNEL_ELF" ]; then
    echo "error: kernel ELF not found: $KERNEL_ELF" >&2
    exit 1
fi

# Boot the kernel and capture output until it naturally halts or times out
# Use a subshell with explicit error handling to avoid 'set -e' issues
# with timeout's exit code (124 means timeout, which is expected)
output=$(timeout "$TIMEOUT_SECS" qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a53 \
    -smp 2 \
    -kernel "$KERNEL_ELF" \
    -nographic \
    -serial mon:stdio \
    2>&1) || exit_code=$?

# exit_code 124 means timeout (expected), 0 means clean exit (also OK)
if [ "${exit_code:-0}" != 0 ] && [ "${exit_code:-0}" != 124 ]; then
    echo "error: QEMU exited with status $exit_code" >&2
    exit 1
fi

echo "$output"

# Verify expected self-test results
expected_markers=(
    "takibi kernel: EL1"
    "memory: base_bytes"
    "fp/simd irq: q0-q31+fpsr preserved"
    "smp bringup: core1 psci"
    "process table: slots="
    "address spaces: roots="
    "user memory: overflow+cross-page"
    "user memory root isolation"
    "syscall subset:"
    "fd table:"
    "scheduler:"
    "growable pool:"
    "asid pool:"
)

all_found=true
for marker in "${expected_markers[@]}"; do
    if echo "$output" | grep -q "$marker"; then
        echo "PASS: found '$marker'"
    else
        echo "FAIL: missing '$marker'" >&2
        all_found=false
    fi
done

if [ "$all_found" = true ]; then
    echo ""
    echo "PASS kernel-qemu: all self-tests verified on QEMU/AArch64"
    exit 0
else
    echo ""
    echo "FAIL kernel-qemu: some self-tests missing from QEMU output" >&2
    exit 1
fi
