# Lock-rank wrappers: space review (#789), 2026-10-14

`python3 scripts/space_delta.py main` against main 544b01b9:

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 687408 | 687456 | 738760 | 738792 |
| data | 4664 | 4664 | 2889496 | 2889496 |
| bss | 1513424 | 1513424 | 1704960 | 1704960 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |

No data/BSS symbol changed size. The rank annotations are checker-only; the
text delta (+48 / +32 B) is the TCP pin-cost loop's inline last-pin branch and
the PMU handler's pid read moved before the buffer lock. Adopted.
