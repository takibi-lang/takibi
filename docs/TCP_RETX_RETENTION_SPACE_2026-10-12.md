# TCP retransmit pool keeps one empty chunk (2026-10-12)

GitHub issue #767. `tcp_retx_pool_return_empty` now keeps one empty chunk,
like `fd_block_return_empty`, instead of returning every empty chunk to the
page allocator.

## Storage

Linked kernels against main 2f8cf115 (`scripts/space_delta.py main`):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 702992 | 703384 | 716288 | 716656 |
| data | 5328 | 5328 | 2889192 | 2889192 |
| bss | 1660272 | 1660272 | 1696880 | 1696880 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

No data/BSS symbol changed size. Text grows 392 B (QEMU) / 368 B (RPi5):
the retention check and the boot probe's two extra assertions.

Retained capacity: once the first TCP segment has been queued, one
`TCP_RETX_CHUNK_PAGES` (2 pages, 8 KiB) chunk stays with the retransmit pool
when its queue is empty. Before, the pool returned it on every empty queue.
The cost is at most 8 KiB for the life of the kernel, and only after the
first TCP send. The QEMU bounded boot's views and page checks are unchanged
(`make kernelcheck-qemu-main` passes).

## Timing (RPi5)

`scripts/measure_kernel_fileio.py --target rpi5 --no-guest`, HTTP fetches of
/bin/busybox.static (1,116,408 B). 3 alternating boots per tree, 12 fetches
per boot:

| tree | median | per-boot medians |
|---|---|---|
| this change (on main) | 0.126 s | 0.112, 0.130, 0.120 |
| f8809977 (before #745's process pool) | 0.192 s | 0.203, 0.192, 0.192 |
| 654d593c (#745) | 0.280 s | 0.253, 0.251, 0.323 |

Instrumented builds (not committed) attributed the difference:
`page_alloc_contiguous` took about 2.9 ms per call, and it was called 24 to
34 times per transfer on f8809977 and 43 to 74 times on main. Those calls
made up most of `kernel_tcp_send_received`'s time.

## Assessment

Adopted: 8 KiB of retained capacity for a transfer about 35% faster than
before #745 and about 55% faster than main. The underlying cost,
`page_alloc_contiguous` scanning the page table and rebuilding the free list
per call, is unchanged and is a separate follow-up.
