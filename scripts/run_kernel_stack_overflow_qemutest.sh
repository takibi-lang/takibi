#!/usr/bin/env bash
# GitHub issue #377 regression: the exception-entry stack guard.
#
# Every kernel stack in this image is the upper half of a 32K-aligned 32K
# region, so bit 14 of an address says which half it is in.  The generated
# exception entry tests that bit after allocating its frame.  This test
# makes the test fire, deterministically, and checks the two properties the
# guard exists for:
#
#   1. the overflow is REPORTED, naming which stack it fell out of, and
#   2. the report does not run on the stack that just overflowed.
#
# Injection is one GDB write.  At the next timer IRQ entry, SP is moved to
# just above the boot stack's bottom and PC is sent back to the entry
# symbol, so the entry sequence runs again with a stack pointer that cannot
# hold its own frame.  Nothing about the kernel is modified; the path taken
# is the ordinary one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ELF="$REPO_ROOT/kernel/build/qemu/kernel.elf"
ARTIFACT_DIR="${KERNEL_QEMU_STACK_ARTIFACT_DIR:-$REPO_ROOT/_build/kernel-stack-overflow-qemu}"
GDB_PORT="${KERNEL_QEMU_STACK_GDB_PORT:-18677}"
UART_LOG="$ARTIFACT_DIR/uart.log"
mkdir -p "$ARTIFACT_DIR"
: >"$UART_LOG"

# GitHub issue #407: see scripts/qemu_port_guard.py. Refuse to start if
# somebody already owns this lane's ports, and say that rather than
# reporting a kernel that was never asked anything.
python3 "$REPO_ROOT/scripts/qemu_port_guard.py" "kernel/qemu stack-overflow" \
    "tcp:$GDB_PORT" || exit 1
if ! command -v gdb-multiarch >/dev/null 2>&1; then
    echo "error: gdb-multiarch is required for kernelcheck-stack-overflow-qemu" >&2
    exit 1
fi

qemu-system-aarch64 -machine virt -cpu cortex-a53 -smp 2 -m 1024 \
    -display none -monitor none -serial "file:$UART_LOG" \
    -S -gdb "tcp::$GDB_PORT" -kernel "$ELF" >"$ARTIFACT_DIR/qemu.log" 2>&1 &
qemu_pid=$!
cleanup() {
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

armed=false
for _ in $(seq 1 50); do
    if gdb-multiarch -q -batch "$ELF" \
            -ex "target remote :$GDB_PORT" \
            -ex "break *el1_current_irq_entry" \
            -ex "continue" \
            -ex "set \$sp = (unsigned long)&boot_stack_bottom + 16" \
            -ex "set \$pc = el1_current_irq_entry" \
            -ex "delete 1" \
            -ex "detach" >"$ARTIFACT_DIR/arm-gdb.log" 2>&1; then
        armed=true
        break
    fi
    sleep 0.1
done
if [ "$armed" != true ]; then
    echo "FAIL kernel/qemu stack-overflow: GDB could not arm the injection" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/arm-gdb.log" >&2 || true
    exit 1
fi

for _ in $(seq 1 100); do
    if grep -q 'kernel stack: OVERFLOW at exception entry' "$UART_LOG"; then
        break
    fi
    sleep 0.1
done

if ! grep -Eq '^kernel stack: OVERFLOW at exception entry \(issue #377\) sp=[0-9]+ below the boot stack$' \
        "$UART_LOG"; then
    echo "FAIL kernel/qemu stack-overflow: expected the entry guard's report" >&2
    sed 's/^/  /' "$UART_LOG" >&2 || true
    exit 1
fi

# The kernel is parked in the handler.  The acceptance criterion that a
# report cannot be trusted if written using the stack it is about is only
# met if SP is now inside the dedicated overflow stack -- so read it back
# rather than assuming the generated code did what it was asked.
gdb-multiarch -q -batch "$ELF" \
    -ex "target remote :$GDB_PORT" \
    -ex "interrupt" \
    -ex "printf \"parked-sp %llu %llu %llu\\n\", (unsigned long long)\$sp, (unsigned long long)&overflow_stack_bottom, (unsigned long long)&overflow_stack_top" \
    >"$ARTIFACT_DIR/parked-gdb.log" 2>&1 || true
read -r _ parked_sp overflow_bottom overflow_top < <(grep '^parked-sp ' "$ARTIFACT_DIR/parked-gdb.log" | tail -1)
if [ -z "${parked_sp:-}" ]; then
    echo "FAIL kernel/qemu stack-overflow: could not read the parked stack pointer" >&2
    sed 's/^/  /' "$ARTIFACT_DIR/parked-gdb.log" >&2 || true
    exit 1
fi
if [ "$parked_sp" -le "$overflow_bottom" ] || [ "$parked_sp" -gt "$overflow_top" ]; then
    echo "FAIL kernel/qemu stack-overflow: the handler ran on $parked_sp, outside the overflow stack ($overflow_bottom, $overflow_top]" >&2
    exit 1
fi

echo "PASS kernel/qemu stack-overflow: entry guard reported the overflowed stack, from a stack of its own"
