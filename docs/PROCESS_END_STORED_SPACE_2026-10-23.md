# ProcessEnd stored directly (GitHub issue #896, 2026-10-23)

#886 stored a ProcessEnd in two places through `ProcessEndWord`, a private
u32 packing, because the compiler did not let an owned struct field or a
global hold a variant. #896 lifts that limit for plain variants, and
TakenSignal's `child_status` and the boot fixture's
`init_boot_fixture_status` now hold the ProcessEnd itself. Measured with
`python3 scripts/space_delta.py origin/main` (base af82f299).

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 737080 | 736816 | 791032 | 790720 |
| data | 4760 | 4760 | 2889608 | 2889608 |
| bss | 1481520 | 1481520 | 1686512 | 1686512 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

Data/BSS symbols changed: `init_boot_fixture_status` 4 -> 8 B on both (an
i32 tag and two u8 payloads instead of one u32). TakenSignal's
`child_status` goes 4 -> 8 B; TakenSignal is a by-value token that lives in
registers and stack frames, never in a pool. ProcessRecord is unchanged.
No pool, page or stack reservation moved.

Text falls by 264 B (qemu) / 312 B (rpi5): the pack and unpack functions
(`process_end_word`, `process_end_of_word`) and their call sites are gone,
which more than pays for copying the wider value.

Assessment: a 4 B BSS growth in one fixture global, absorbed by existing
section alignment, against a text reduction and the removal of a private
encoding that had to be kept in step with the variant by hand. Adopted.
