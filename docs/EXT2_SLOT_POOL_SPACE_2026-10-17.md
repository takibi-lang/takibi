# #638 slice 2: ext2 scratch slot pool, space (2026-10-17)

ext2's scratch (two block buffers and a write's staged block numbers) moved
from per-CPU storage reached through cpu_here_across_blocking() to a pool of
KERNEL_MAX_CORES slots handed out by a linear Ext2Slot. The buffers keep
their size and count; the pool adds one AtomicWord per slot. Each public
entry point acquires and releases the slot, and the internal work takes it
as a parameter. Measured with scripts/space_delta.py against main e85b1850:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 697368 | 701848 | 747976 | 752024 |
| data | 4760 | 4768 | 2889560 | 2889568 |
| bss | 1486352 | 1486384 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  qemu: ext2_slot_words None -> 32
  rpi5: ext2_slot_words None -> 32
```

Assessment:

- BSS +32 B: the slot words (4 x 8 B). The scratch itself is unchanged in
  size, still static, not on the kernel stack (DECISIONS.md, 2026-10-17:
  prefer static storage over large stack buffers).
- Text +4480 B QEMU / +4048 B RPi5 (0.6%): the acquire and release at
  each of 33 entry points and the slot parameter threaded through the
  internal functions. A first cut that kept every entry point as a
  separate wrapper cost +7740 B and moved QEMU usable_ram_start one
  32 KiB step; marking the 25 single-caller bodies `inline` folded wrapper
  and body together and removed both. Data +8 B is alignment.
- usable_ram_start unchanged on both images, so the page reservations do
  not move.

Accepted: the cost buys the removal of the only CPU-authority mint outside
a preempt_off block that served steady-state code, and a compile-time
release obligation for ext2 scratch.
