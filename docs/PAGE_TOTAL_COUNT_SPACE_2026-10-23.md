# page_allocator_total_count: recorded total (#900), 2026-10-23

## What changed

`page_allocator_total_count` walked every page's metadata with the page
lock held, and the page lock masks IRQs. The pages it counts (owner not
`Unavailable`) are fixed once `page_allocator_apply_memory` has run: only
`page_allocator_fill_metadata` marks a page `Unavailable` and nothing clears
the mark. The count is now recorded once at boot in `BootPagePool`
(`available_pages`, with the walk's cost in `available_walk_ticks`) and
answered in O(1). Before the runtime metadata is applied the walk over the
bootstrap pages remains.

## Timing (the reason)

The bounded suite now ends with `RECORDED page allocator total:`, the boot
walk's cost, and a `resources:` line comparing the record to a fresh walk.

| lane | pages | walk ticks | freq | one walk |
|---|---|---|---|---|
| RPi5 kernelcheck-rpi5 run 1 | 259296 | 104129 | 54 MHz | 1.93 ms |
| RPi5 kernelcheck-rpi5 run 2 | 259296 | 98773 | 54 MHz | 1.83 ms |
| QEMU kernelcheck-qemu-main | 261600 | 1097877 | 62.5 MHz | 17.6 ms (emulated) |

So on RPi5 (1 GiB board) every call held IRQs masked for about 1.9 ms,
against 9.8-15.2 us for the longest `page_alloc_contiguous` hold in the same
runs (`RECORDED page run allocator: max_ticks=528..819`). Callers include
`files_stat.max_files` (fd_table), `sysinfo`/meminfo-style syscalls and
process diagnostics. On an 8 GiB board the walk is 8x longer.

## Space

`python3 scripts/space_delta.py` against origin/main 51d61e72:

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 734248 | 734800 (+552) | 786256 | 786792 (+536) |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481840 | 1481856 (+16) | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

`boot_page_pool_cell` 16512 -> 16528 B: two words, one per allocator (there
is one). Text is the boot walk's timing, the O(1) branch, and the
end-of-suite comparison and RECORDED line (`page_allocator_total_count_log`,
224 B qemu). No pool, page, or allocation change.

Assessment: adopted. 16 B of static metadata and about 0.5 KiB of text
remove a ~1.9 ms IRQ-masked span per call on RPi5.
