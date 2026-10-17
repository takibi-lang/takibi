# #638 slice 4: exec staging and syscall scratch slot pools, space (2026-10-17)

process_image's ext2 exec staging (source, pair source, one-block buffer)
moved from its per-CPU context into a ProcessImageSlot pool, and every
SyscallScratch field moved from cpu_id() indexing to a SyscallSlot pool. The
buffers keep their size and count; each pool adds one AtomicWord per slot.
Measured with scripts/space_delta.py against main b49c2043:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 702212 | 705292 | 754592 | 757912 |
| data | 4776 | 4800 | 2889608 | 2889632 |
| bss | 1486416 | 1486480 | 1692736 | 1692736 |
| usable_ram_start | 0x40218000 | 0x40220000 | 0x718000 | 0x720000 |
data/BSS symbols changed:
  qemu: process_image_contexts 4992 -> 128
  qemu: process_image_slot_words None -> 32
  qemu: process_image_staging None -> 4864
  qemu: syscall_slot_words None -> 32
  rpi5: (the same four)
```

Assessment:

- BSS +64 B: the two pools' slot words. The staging buffers only moved
  (4992 = 128 + 4864). Storage stays static, not on the kernel stack.
- Text +3080 B QEMU / +3320 B RPi5: an acquire/release wrapper around each
  of 18 scratch-using syscall handlers (six dispatch arms became functions),
  the slot parameter threaded through the exec and path helpers, and the
  three exec-loader entry points. A noinline acquire made no difference.
  Data +24 B is alignment.
- usable_ram_start moves one 32 KiB step on both images (8 pages fewer for
  the allocator), and the RPi5 image end reaches 0x520000, the recorded
  ceiling; kernel/MEMORY_MAP.md raises it to 0x540000 pending the
  maintainer's approval. The growth is code, about 0.02 s of SWD time.

Accepted (pending the ceiling approval): removes the per-CPU scratch
dependency on KERNEL_PREEMPTIBLE == 0 for the exec staging and syscall
buffers, with a compile-time release obligation and a build check that no
slot is held across a scheduler sleep.
