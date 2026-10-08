# Block cache per-bucket retirement: space and I/O, 2026-10-08

Workload: the standard production QEMU main lane (`make kernelcheck-qemu-main`)
and the standard linked QEMU/RPi5 images, before (87517a32) and after
(b1897562) per-bucket write retirement in `kernel/drivers/block/block_cache.tkb`.

## Linked image (llvm-size -A, bytes)

| image | section | before | after | delta |
|---|---|---|---|---|
| QEMU `kernel.elf` | .text | 553392 | 553792 | +400 |
| QEMU `kernel.elf` | .rodata | 45448 | 45480 | +32 |
| QEMU `kernel.elf` | .bss | 1241904 | 1243952 | +2048 |
| RPi5 `kernel-shell.elf` | .text | 559576 | 559992 | +416 |
| RPi5 `kernel-shell.elf` | .rodata | 47528 | 47544 | +16 |
| RPi5 `kernel-shell.elf` | .bss | 1279136 | 1283232 | +4096 |

The new state is `block_cache_writes`, 32 -> 2048 bytes (4 cores x 64
buckets x one word), and `block_single_reads`, 32 bytes. RPi5's +4096 is
that plus section alignment; it moves the RPi5 allocator start past one
32 KiB boundary, so `allocator_pages` goes 259312 -> 259304 (8 pages).
.data is unchanged. No pool, slot, allocation path or retained page changes;
the 16 slots per core and their 64 KiB of data are unchanged.

## Block I/O on the QEMU main boot

| field | before | after |
|---|---|---|
| reads (device blocks) | 226297 | 85411 |
| single_reads | 6132 | 1299 |
| runs | 3441 | 1318 |
| cache_hits | 272765 | 279243 |
| writes | 9732 | 9503 |

Writes differ between runs because the boot's fixtures write a
timing-dependent number of blocks; the read reduction is far larger than
that variation.
