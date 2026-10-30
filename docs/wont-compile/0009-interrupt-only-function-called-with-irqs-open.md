# 0009. An interrupt-only function called with IRQs open

| Field | Value |
| --- | --- |
| Status | Enforced |
| Compared against | Linux lockdep and `lockdep_assert_irqs_disabled`, Rust for Linux (2026-10-30) |
| Check | type error, effect checker on calls of `!{interrupt}` functions (`lib/type_inf.ml`) |
| Test case | `from a plain function` |
| Introduced | 2026-10-30, GitHub issue #638 stage 4 (D1 (a)), entry #1235 |
| Specified in | [`EFFECTS.md`](../../EFFECTS.md) |

![A plain function calling an interrupt function with IRQs open, rejected at
compile time](assets/0009-interrupt-only-function-called-with-irqs-open.svg)

## The defect

Some kernel functions are written for the inside of an interrupt handler:
they touch state the handler owns, take a lock without masking because the
CPU is already masked, or assume no other interrupt can arrive on this CPU
until they return. Called from ordinary code with IRQs open, the same
function can be interrupted halfway by the handler it shares that state
with. The handler then finds it half written, or spins on a lock its own CPU
already holds.

The call looks harmless. A flush path wants the drain the TX interrupt
runs, and calls it directly.

## What C and Rust do about it

**C: a run-time assertion.** Linux's `lockdep_assert_irqs_disabled()` checks
the flag when lockdep is built in and the path runs; lockdep also reports a
lock taken both from interrupt context and with IRQs on, again at run time.

**Rust: nothing in the type.** Rust for Linux expresses an IRQ-disabled
section with a guard value in some APIs, but a function does not carry
"requires IRQs masked" in its signature, so a direct call is not refused.

Sources: [Linux lockdep.h](https://github.com/torvalds/linux/blob/master/include/linux/lockdep.h)
and [Rust for Linux sync](https://rust.docs.kernel.org/kernel/sync/index.html).

## What Takibi does

A function declared `!{interrupt}` runs with IRQs masked. The compiler
refuses a direct call to one unless the caller is itself an `interrupt`,
`exception` or `nmi` function, or holds a live guard returned by an
`irq_masking_guard` function at the call. A guard given back before the call
does not count.

## Code that does not compile

```takibi
linear struct IrqGuard[unit: usize] { private flags: usize; }

fn irq_save() -> IrqGuard[0] !{irq_masking_guard} {
    let mut g: IrqGuard[0] = { 0 };
    return g;
}

fn irq_restore(g: sink IrqGuard[0]) { }

fn uart_tx_drain() -> usize !{interrupt} {
    return 1;
}

fn console_flush() -> usize {
    return uart_tx_drain();
}
```

```text
'uart_tx_drain' is an interrupt function, which runs with IRQs masked, but
  function 'console_flush' declares neither interrupt nor exception and
  holds no irq_masking_guard guard here; call it only from a masked context
  (#638)
```

## Code that does compile

```takibi
linear struct IrqGuard[unit: usize] { private flags: usize; }

fn irq_save() -> IrqGuard[0] !{irq_masking_guard} {
    let mut g: IrqGuard[0] = { 0 };
    return g;
}

fn irq_restore(g: sink IrqGuard[0]) { }

fn uart_tx_drain() -> usize !{interrupt} {
    return 1;
}

fn console_flush() -> usize {
    let g: IrqGuard[0] = irq_save();
    let drained: usize = uart_tx_drain();
    irq_restore(g);
    return drained;
}
```

The guard masks IRQs for the call and is given back after it.

## Where this runs

The kernel's interrupt dispatch, the PL011 receive drain and the GIC
handlers are `!{interrupt}`; callers outside an interrupt root reach them
under a masking lock's guard (`process_run_lock`, `console_lock` and the
other `irq_masking_guard` takes).

## Limits of this entry

The rule is about direct calls. A call through a function pointer is
checked by the pointer type's effect row, as for blocking calls (0001). The
guard proves the mask was taken by a function annotated
`irq_masking_guard`; that the annotation is true of the function's body is
the annotation's own check (#528).
