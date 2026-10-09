# Space review: probe words on AtomicWord (2026-10-09)

Unit: #637 stage 1 group B, the two-core probes' shared words moved from
plain `usize` globals reached through raw intrinsic addresses to
`AtomicWord` (one `usize`, same layout).

`python3 scripts/space_delta.py origin/main` at base 50a6811f:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 724284 | 723428 | 734036 | 733748 |
| data | 5078 | 5078 | 2888784 | 2888784 |
| bss | 1658608 | 1658608 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data or BSS symbol changed size: every migrated word keeps its one-usize
storage. Text shrinks 856 bytes (QEMU) and 288 bytes (RPi5) as the address
helpers and their casts go. No allocation, pool or lifetime change. Adopted.
