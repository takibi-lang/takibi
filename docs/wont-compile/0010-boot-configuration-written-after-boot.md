# 0010. Boot configuration written after boot

| Field | Value |
| --- | --- |
| Status | Enforced |
| Compared against | Linux `__ro_after_init`, Rust `OnceLock` (2026-10-30) |
| Check | type error, linear-value consumption (`lib/type_inf.ml`) |
| Test case | `a boot-once write after the phase ends is refused` |
| Introduced | 2026-10-30, GitHub issue #1013 |
| Specified in | [`kernel/lib/boot_once.tkb`](../../kernel/lib/boot_once.tkb) |

![A boot-once write after boot_phase_end, rejected because the phase token
was consumed](assets/0010-boot-configuration-written-after-boot.svg)

## The defect

A kernel learns its device bases, interrupt numbers and MAC address while
it boots, and then reads them everywhere: from interrupt handlers, from
every core, without a lock. That is safe only because nothing writes them
again. If a later path does -- a re-probe, a test hook, a copied init
function -- a reader on another core sees the change with no ordering at
all, and the old value may already be in a device register.

The write is rarely wrong where it is written. It is wrong because of when
it runs, and nothing at the write says when that is.

## What C and Rust do about it

**C: a section attribute.** Linux marks such data `__ro_after_init`; once
boot is done the kernel makes the section read-only in the page tables, so
a late write faults at run time, on the path that runs.

**Rust: a run-time cell.** `OnceLock` allows one initialization and refuses
the second at run time; nothing ties the first write to the boot phase.

Sources: [Linux `__ro_after_init`](https://github.com/torvalds/linux/blob/master/include/linux/cache.h)
and [Rust `OnceLock`](https://doc.rust-lang.org/std/sync/struct.OnceLock.html).

## What Takibi does

`kernel/lib/boot_once.tkb`'s `boot_once_set` takes a `borrow BootPhase`, a
linear token each platform's main mints once and gives to `boot_phase_end`
just before it starts the secondary cores. After that call there is no token
on the path, so a later write is a use of a consumed linear value.

## Code that does not compile

```takibi
linear struct BootPhase[phase: addr] { private held: usize; }
private let mut boot_phase_flag: usize;
struct BootCell { private value: usize; }

private fn boot_phase_mint() -> BootPhase[&boot_phase_flag] {
    let mut phase: BootPhase[&boot_phase_flag] = { 1 };
    return phase;
}

fn boot_phase_end(phase: sink BootPhase[boot]) {
    let held: usize = phase.held;
}

fn boot_cell_set(cell: &mut BootCell, phase: borrow BootPhase[boot], value: usize) {
    (*cell).value = value;
}

let mut uart_base: BootCell;

fn main() {
    let mut phase = boot_phase_mint();
    boot_cell_set(&uart_base, phase, 0x09000000);
    boot_phase_end(phase);
    boot_cell_set(&uart_base, phase, 0x08000000);
}
```

```text
linear value 'phase' was already consumed
```

## Code that does compile

```takibi
linear struct BootPhase[phase: addr] { private held: usize; }
private let mut boot_phase_flag: usize;
struct BootCell { private value: usize; }

private fn boot_phase_mint() -> BootPhase[&boot_phase_flag] {
    let mut phase: BootPhase[&boot_phase_flag] = { 1 };
    return phase;
}

fn boot_phase_end(phase: sink BootPhase[boot]) {
    let held: usize = phase.held;
}

fn boot_cell_set(cell: &mut BootCell, phase: borrow BootPhase[boot], value: usize) {
    (*cell).value = value;
}

let mut uart_base: BootCell;

fn main() {
    let mut phase = boot_phase_mint();
    boot_cell_set(&uart_base, phase, 0x09000000);
    boot_cell_set(&uart_base, phase, 0x08000000);
    boot_phase_end(phase);
}
```

Both writes happen during the phase; the second, as the QEMU console does
with its bootstrap and DTB windows, replaces the first.

## Where this runs

The QEMU UART base, GIC windows and UART interrupt number, the PSCI conduit,
and the TCP stack's MAC address are `BootOnce` cells. Each platform's `main`
mints the phase before `kernel_boot_prologue` and ends it just before
`kernel_secondary_boot_report` issues `CPU_ON`.

## Limits of this entry

The mint is trusted: a second `boot_phase_mint` call would open a second
phase (TRUSTED_BASE.md). A read of a cell before its write is refused at run
time, by a named stop, not at compile time (#732 would give the cell a
`Sealed` index). The sample stands in for the library with a plain struct;
the library's own cell is generic.
