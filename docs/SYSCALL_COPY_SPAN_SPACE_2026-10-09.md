# Space review: syscall copies through checked slices (2026-10-09)

Unit: #637 stage 1 item 1, the ten raw kernel-buffer copy forwarders in
syscall.tkb replaced by copy_from_user_span / copy_to_user_span.

`python3 scripts/space_delta.py origin/main` at base 3b805323:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 726084 | 726236 | 736484 | 736604 |
| data | 5078 | 5078 | 2888784 | 2888784 |
| bss | 1658608 | 1658608 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data or BSS symbol changed size. Text grows 152 bytes (QEMU) and 120
bytes (RPi5): the span checks and the copy-in failure arms that used to be
ignored. No buffer, payload, pool or lifetime change. Adopted.
