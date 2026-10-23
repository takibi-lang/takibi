# Aggregate select/phi splitting: space (2026-10-23)

GitHub issue #893. Workload: both production kernels, base origin/main
91ddd4bb (after #897) against the branch whose release pipeline splits each
struct-typed `select` and `phi` into per-field selects and phis
(`split_aggregate_merges` in lib/llvm_gen.ml), then runs
early-cse,simplifycfg.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 737920 | 734248 | 792064 | 786256 |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481840 | 1481840 | 1690736 | 1690736 |

Text -3672 B qemu, -5808 B rpi5. Data and BSS unchanged.

## Re-measurement of #893 after #897

#897 changed only variants with two or more scalar payload cases. The
sites #893 named (RootOwner: Kernel | Process(ProcessSlot), one payload
case) were untouched: on 91ddd4bb the QEMU kernel still had 10 csel whose
two operands are one value (`mov x8, x0; cmp x0, #0; csel x0, x8, x0, eq`
in address_space_root_slot_valid and scheduled_process_address_space_root_of,
plus `csel xN, x8, x8` shapes), the RPi5 kernel 16.

Cause: simplifycfg merges a function's returns into one aggregate
`select c, {0, undef}, {1, payload}` (or an aggregate phi); this pipeline
has no instcombine, so the aggregate reaches the backend, which keeps the
undefined field as a csel operand and, after inlining into a match,
switches on a selected tag instead of branching on `c`.

After the change: 6 such csel remain in QEMU, 10 in RPi5, none of them on
a variant payload from a merged return (they are scalar selects formed in
the backend). address_space_root_slot_valid is `cbz x0` followed by the
call; the ProcessEnd sites (two-payload, #897's tag+payload convention)
carry no redundant csel.

## Alternatives measured

1. Adding `instcombine` to the post-inline round: -1176 B qemu, but it
   rewrote the SCTLR_EL1 mask sequence and failed the #480 asm invariant,
   left the #893 sites' count unchanged in the first try, and needs
   `<no-verify-fixpoint>`. Rejected: a whole-pipeline policy change.
2. Splitting only `extractvalue (select ...)`: -48 B, sites remained.
3. Splitting only structs of scalars (no array fields): -760 B qemu; it
   avoids virtio_net_used's +796 B but loses the -3760 B in the process
   diagnostic copy. The adopted rule splits a phi when at most one path
   defines each array field (a variant's inactive cases); it guards the
   two-defined-arrays case (unit-tested) but does not recover
   virtio_net_used, which is accepted and recorded below.

Largest per-symbol changes (qemu): scheduled_process_diagnostic_copy -2796,
scheduled_process_diagnostic_snapshot -964, syscall_exec_format -132;
largest growth virtio_net_used +796 (its Seen(ring) array: one defined
path, but the defined value does not dominate the join, so a phi of the
array remains), ext2_owner_roundtrip_check +144.
