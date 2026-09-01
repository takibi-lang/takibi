# Maintained kernel

The standalone Unix-like kernel is the primary product surface. New kernel
features, fixes, fixtures, and target code belong here.

Use the `write-takibi` skill before adding or substantially changing `.tkb`
code. New code starts with refinement types and `--forbid-trap`; do not use raw
pointers or `unsafe` merely to evade a checked access. Fallible operations use
closed variants rather than integer or boolean sentinels, and must-check
results use `must_use variant`.

The hardware/protocol bring-up exception in `write-takibi` requires an
explicit judgment that behavior is genuinely unknown. Do not silently apply
the old unrefined-first process to an established pattern.

Use `debug-kernel` before investigating kernel hangs, crashes, boot failures,
exceptions, timing-sensitive failures, or QEMU/RPi5 failures. If UART remains
responsive, use DDB before adding logging to scheduler, exception, IRQ, VM, or
process paths. QEMU cannot validate physical cache coherence, real interrupt
timing, or hardware concurrency.

Kernel documentation is authoritative for current behavior:
`kernel/README.md`, `kernel/SYSCALLS.md`, `kernel/MEMORY_MAP.md`,
`kernel/RESOURCE_LIMITS.md`, and `kernel/RUNTIME_STATE.md`.

Every mutable-state kernel file must declare its execution model as required
by the build checks. Preserve lock, pool-release, MMIO-address derivation,
diagnostic-event, and platform-parity invariants rather than weakening their
checks to complete a change.
