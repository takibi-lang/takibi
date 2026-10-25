# Preempt count space review (#638 stage 2, 2026-10-25)

`preempt_off (cpu) { ... }` now raises a per-CPU preempt count on entry and
lowers it on every exit (`kernel/kernel/cpu_authority.tkb`). The count is a
`struct per_cpu PreemptCount` reached through TPIDR_EL1. Every may_block
leaf (the interrupt wait and the five slot-pool acquires) checks at run
time that the count is zero. `KERNEL_PREEMPTIBLE` stays 0.

## Measurement

`python3 scripts/space_delta.py origin/main` (9860071e, after #981 and
#1015 landed), both production kernels linked. TPIDR_EL1 is read by the
one-move helper `kernel_cpu_offset` in user_entry.S:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 682308 | 682836 (+528) | 736356 | 736772 (+416) |
| data | 4880 | 4888 (+8) | 2889736 | 2889744 (+8) |
| bss | 1485344 | 1485376 (+32) | 1690736 | 1690736 (0) |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |

The one new symbol is `preempt_counts`, 32 B (four 8-byte counts). RPi5's
BSS total is unchanged because the count fits in existing alignment slack.
The image span, and so every page reservation, did not move.

## Code per region

RPi5 `kernel.elf`: `preempt_off_enter` 80 B, `preempt_off_exit` 48 B,
`preempt_slot` 32 B, `preempt_assert_blockable` 28 B,
`preempt_count_here` 32 B. A region adds one call at entry (to the mint,
which it already called) and one call per exit. The exit path is about 20
instructions: a `bl` to the helper (`mrs tpidr_el1; ret`), a shift, a bounds check, one load, a
zero check and one store. Text grows by about 0.07%. No new lock and no
IRQ mask: the count is independent of the mask.

## Assessment

Adopted. The cost is a few hundred bytes of text and 32 B of BSS, and it
buys a real disable/enable pair, nesting, and a runtime witness of the
static no-blocking rule. Time is not measured on RPi5 here: nothing reads
the count to decide a switch until the EL1 IRQ return does (#638 stage 8),
and that stage measures the region cost on the board together with the
switch it enables.
