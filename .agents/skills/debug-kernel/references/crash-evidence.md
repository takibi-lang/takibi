# Crash and hardware evidence

Unrecognized EL0 synchronous exceptions intentionally fail stop: the kernel
captures a fixed `CrashSnapshot`, emits the bounded UART oops report, and parks
in `wfe`. Do not route around that behavior while diagnosing it.

The snapshot includes ESR, FAR, ELR, SPSR, live EL0 and address-space context,
process and scheduler state, saved-frame fields when available, and a bounded
trace. Capture is allocation-free. `valid` is written last and the sequence
changes on each capture so stale or zeroed storage can be distinguished.

Use `kernelcheck-oops-qemu` for deterministic EL0-BRK coverage. For interactive
postmortem work in `gdb-multiarch`, source
`_build/kernel-crash-snapshot-layout.gdb`, then
`scripts/kernel_crash_snapshot.gdb`, and run `takibi-oops`. The generated layout
is authoritative; do not duplicate the exception-frame ABI by hand.

## SWD cache caveat

The CPU cache and RAM visible through SWD can disagree. CrashSnapshot is
explicitly cleaned to memory before the core parks, but still cross-check the
parked core's live `ESR_EL1`, `ELR_EL1`, and `SPSR_EL1` registers against the
retained block. The two views detect different failure classes.

A static object containing the same value every boot cannot prove freshness.
When evidence may be cacheable, arrange for a changing sequence/canary or read
the live register state. A QEMU result cannot validate this property because
TCG uses a unified memory model rather than a physically separate cache.

## Evidence discipline

- Record into bounded globals or diagnostic rings before adding UART output to
  a timing-sensitive window.
- Preserve raw register values and addresses before interpreting them.
- Distinguish `not captured`, `damaged`, and `overwritten` from negative facts.
- Prefer a small external checker over adding more hand-written assembly to the
  exception path.
