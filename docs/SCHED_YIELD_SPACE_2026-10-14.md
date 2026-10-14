# sched_yield space review (2026-10-14, #665)

Change: syscall 124 (sched_yield) becomes a plain reschedule request in
kernel/kernel/syscall.tkb and is peer-safe. No new state, allocation or
lifetime. Measured with `python3 scripts/space_delta.py main` (main 34dc6be5):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 695200 | 695216 | 745264 | 745264 |
| data | 4744 | 4744 | 2889536 | 2889536 |
| bss | 1486160 | 1486160 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |

No data/BSS symbol changed size. Text +16 B on QEMU, and no change on RPi5
(absorbed by section alignment). Adopted.
