# #638 slice 3: block layer slot pool, space (2026-10-17)

The block layer's read-ahead run, block cache entries and write counts, and
counters moved from cpu_id()-indexed storage to indexing by a linear
BlockSlot from a pool of KERNEL_MAX_CORES slots. The arrays keep their size
and count; the pool adds one AtomicWord per slot. Measured with
scripts/space_delta.py against main d92a38d4:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 701848 | 702212 | 752024 | 752440 |
| data | 4768 | 4776 | 2889568 | 2889576 |
| bss | 1486384 | 1486416 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  qemu: block_slot_words None -> 32
  rpi5: block_slot_words None -> 32
```

Assessment:

- BSS +32 B: the slot words (4 x 8 B; RPi5's BSS total is unchanged by
  section alignment). Storage stays static, not on the kernel stack.
- Text +364 B QEMU / +416 B RPi5: acquire (with the cpu_id() hint) and
  release at five entry points; block_read's body is inlined into its one
  wrapper. Data +8 B is alignment.
- usable_ram_start unchanged on both images.

Accepted: removes memory.tkb's KERNEL_PREEMPTIBLE == 0 assert with a
compile-time release obligation for the block layer's per-operation state.
