# Pool lock wait counters: space review (2026-10-24, #953)

Workload: both production kernels linked from this branch against
origin/main by `scripts/space_delta.py`; no pool, payload or occupancy
change.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 738976 | 740780 | 790904 | 792708 |
| data | 4792 | 4808 | 2889640 | 2889656 |
| bss | 1481856 | 1482640 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40228000 | 0x720000 | 0x728000 |

New BSS: `pool_lock_wait_cores` (per CPU, one 192-byte row of 9
acquires/contended pairs, padded so no two CPUs share a line; 768 bytes)
and `pool_lock_wait_paused` (one word).

Text, RPi5, by symbol (1208 bytes; the rest of the 1.8 KiB is section
alignment padding): 9 wrappers +52 each (468: the held check and the
call), 9 monomorphized region_pool_lock_is_held at 28 (252),
pool_lock_wait_note 116, the reporter 320, pool_lock_wait_pause 60,
contention_probes split +36. Inlining the note made text larger (+2.2 KiB),
because the wrappers are called from 68 sites; the note stays out of line.

## Hot-path cost (RPi5, 2026-10-24)

Temporary probe (not committed): core 0 alone, interrupts as in the
production wrapper, 4096 tcp_connection pool lock/unlock pairs, 3
samples, 54 MHz:

| sample | bare (mask + lock, no counting) | counted (wrapper, counting on) |
|---|---|---|
| 0 | 5096 | 6443 |
| 1 | 5090 | 6447 |
| 2 | 5087 | 6441 |

Per pair: 23.0 ns bare, 29.1 ns counted: +6.1 ns (+26%). With counting
paused (the `tcp pool cost` fixture, which runs paused) the solo lock
interval went from 5444 to 6117-6128 ticks per 4096 (+3.0 ns): the held
check, the call and the pause load alone.

The text growth crosses a 32 KiB image reservation boundary on both
targets, so the page allocator loses 8 pages (32 KiB); the FDT fixture and
the RPi5 boot view were updated to the new allocator page counts.

Assessment: accepted. The counters are the measurement the maintainer
asked for to bring parked #680 back (#953); there is no cheaper source of
the contended share. The 8-page reservation step is a boundary effect of
1.8 KiB of text, not new state.

## Contended-only counting (option B, same day)

The wrapper now calls out of line only when region_pool_lock_is_held
reports the lock held. Text returns under the 32 KiB reservation step, so
the allocator page counts are main's again (no page cost); the temporary
probe's own code pushed it back over, so the margin is small.

The same probe, with the baseline changed to main's wrapper (an out-of-line
call to mask + lock, no counting) so that only the counting differs:

| sample | main's wrapper | B wrapper |
|---|---|---|
| 0 | 5418 | 5998 |
| 1 | 5415 | 5995 |
| 2 | 5419 | 5993 |

Per pair: 24.5 ns vs 27.1 ns, +2.6 ns (+11%). The uncontended path is a
`bl` to the monomorphized region_pool_lock_is_held (one `ldar` of the lock
word), a `tbz`, and one more saved register. The counting itself is not
reached. Against the inlined mask + lock (no wrapper call) the difference
was 5172-5174 vs 5925-5931 (+5.5 ns), but most of that is the wrapper call
main already pays.

## Inline contended hint (final, same day)

The uncontended path now reads the lock word through
region_pool_lock_contended_hint, an inline plain load (an `ldr` and a
`cbz` in each wrapper); region_pool_lock_is_held keeps its acquire load.
Same probe, main's wrapper vs this one:

| sample | main's wrapper | final wrapper |
|---|---|---|
| 0 | 5422 | 5453 |
| 1 | 5417 | 5438 |
| 2 | 5415 | 5462 |

+21..47 ticks per 4096 pairs: +0.1..0.2 ns per pair.

Final size against origin/main d6290064 (scripts/space_delta.py): text
+924 B (QEMU) / +876 B (RPi5), data +16 B, BSS +528 B (QEMU;
`pool_lock_wait_cores` 512 B, `pool_lock_wait_paused` 8 B; on RPi5 the
BSS total is unchanged by alignment). usable_ram_start unchanged on both
targets: no allocator page cost.

## Standing cost line (same day)

The probe is now permanent: `RECORDED pool lock wait cost:` (kernel/net/tcp.tkb,
called at the end of contention_probes), with a 1 ns per pair ceiling in
scripts/validate_parked_triggers.py. With it, against origin/main d6290064:
text +1420 B (QEMU) / +1436 B (RPi5), data +16 B, BSS +528 B (QEMU);
usable_ram_start unchanged on both targets, so the probe ships in the
production image rather than behind a build flag.

## After rebase onto 3dac688b

Against origin/main 3dac688b: text +1420 B (QEMU) / +1436 B (RPi5), data +16 B,
BSS +528 B (QEMU); usable_ram_start 0x40210000 / 0x710000 unchanged, so
the allocator page counts are main's.
