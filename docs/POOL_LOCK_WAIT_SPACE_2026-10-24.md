# Pool lock wait counters: space review (2026-10-24, #953)

Workload: both production kernels linked from this branch against
origin/main by `scripts/space_delta.py`; no pool, payload or occupancy
change.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 738976 | 740800 | 790904 | 792664 |
| data | 4792 | 4816 | 2889640 | 2889664 |
| bss | 1481856 | 1482016 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40228000 | 0x720000 | 0x728000 |

New BSS: `pool_lock_wait_acquires` and `pool_lock_wait_contended` (9 words
each) and `pool_lock_wait_paused` (one word), 152 bytes. Text grows
1.8 KiB (one held-load, one counter call per production pool lock
acquire, and the reporter).

The text growth crosses a 32 KiB image reservation boundary on both
targets, so the page allocator loses 8 pages (32 KiB); the FDT fixture and
the RPi5 boot view were updated to the new allocator page counts.

Assessment: accepted. The counters are the measurement the maintainer
asked for to bring parked #680 back (#953); there is no cheaper source of
the contended share. The 8-page reservation step is a boundary effect of
1.8 KiB of text, not new state.
