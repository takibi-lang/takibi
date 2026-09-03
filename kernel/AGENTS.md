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
`kernel/RESOURCE_LIMITS.md`, `kernel/RUNTIME_STATE.md`, and
`kernel/CONCURRENCY.md`.

Read `kernel/CONCURRENCY.md` before adding a lock, a two-core probe, or any
mechanism that reads a pooled object through a handle. It states the lock
classes and order, what must be asked before a lock is the answer, how a lock
is bound to what it protects, why reporters take none, and what QEMU cannot
measure.

A new or extended shared data structure under `kernel/lib/` carries a "Current
limitations" section near the top of the file, stating what today's actual
callers guarantee that the file itself does not enforce -- verified by
checking, not assumed, and dated. The purpose is that a future caller adopting
the library outside its original execution context has to consciously override
a documented limitation instead of silently assuming a guarantee that was
never there. Keep the section current as call sites change; a stale limitation
is worse than none.

Several boot-time evidence counters are global and cumulative across a whole
boot, and a later fixture may assert on the cumulative value. Append a new
process-image scenario at the end of the boot sequence, after every existing
fixture has taken its own evidence, rather than inserting it beside the
scenario it is topically related to. Inserting one in the middle can break an
unrelated later view even when the new scenario touches no shared resource.

The QEMU and RPi5 platform trees are never compiled together, so two copies of
the same function in them cannot be compared by the compiler or by any
type-level check. Platform-independent code does not belong in a platform
file; `scripts/check_platform_file_parity.py` enforces this, and an entry in
its allow list requires a stated reason.

Every mutable-state kernel file must declare its execution model as required
by the build checks. Preserve lock, pool-release, MMIO-address derivation,
diagnostic-event, and platform-parity invariants rather than weakening their
checks to complete a change.
