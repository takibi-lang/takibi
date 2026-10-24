# ext2 ENOSPC space review (#698), 2026-10-24

Workload: production QEMU and RPi5 kernels linked at the #698 branch head
against origin/main 751d6bc6, measured with `scripts/space_delta.py`.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 669176 | 673712 | 722984 | 727584 |
| data | 4816 | 4824 | 2889664 | 2889672 |
| bss | 1481888 | 1482912 | 1690736 | 1691760 |
| usable_ram_start | 0x40210000 | 0x40218000 | 0x710000 | 0x718000 |

Symbols: `ext2_full_fixture_saved` (1024 B BSS) added on both kernels.

Assessment: +4.5 KiB text for the NoSpace outcomes (inode allocation,
directory insertion, create, mkdir, rename) and the boot fixture that fills
each bitmap; the fixture's one-block save buffer crosses a page boundary, so
usable_ram_start moves by 32 KiB (8 allocator pages fewer). No pool, record
or allocator change. Adopted: the buffer is the boot fixture's restore copy of
a bitmap block; moving it to a pool allocation is possible if the 8 pages
matter.
