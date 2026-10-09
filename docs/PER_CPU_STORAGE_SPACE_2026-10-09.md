# Per-CPU storage: space (2026-10-09)

Change: #704, the CPU authority and per_cpu stores; the exec args store migrated. Measured with `python3 scripts/space_delta.py` against origin/main 4c553cb0:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 726928 | 726920 | 738456 | 738448 |
| data | 5400 | 5400 | 2889152 | 2889152 |
| bss | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
no data/BSS symbol changed size

The authority is one usize passed by value, the same as the core number it replaces; the range check moves into the mint. Text -8 B on both targets; no data, BSS or reservation change. Adopted.
