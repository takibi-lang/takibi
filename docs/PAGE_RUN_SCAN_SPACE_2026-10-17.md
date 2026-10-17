# Page run allocation cost and space, 2026-10-17 (#771)

Workload: the bounded suite on both production kernels, with
page_alloc_contiguous's new permanent counters (calls, candidate visits,
ticks held under the IRQ-masking page lock, longest hold) printed as the
`RECORDED page run allocator:` line. Before is commit "page runs:
permanent call, tick and longest-hold counters" alone; after adds the
doubly linked free list, the head pop for a run of one, and the
aligned-address scan.

## Time under the page lock (RPi5, `make kernelcheck-rpi5`, 54 MHz counter)

| | calls | ticks | mean per call | longest hold |
|---|---|---|---|---|
| before | 114 | 19430085 | 170439 ticks = 3.16 ms | 252740 ticks = 4.68 ms |
| after | 115 | 10091 | 88 ticks = 1.6 us | 614 ticks = 11.4 us |

The lock masks IRQs, so the longest hold is this allocator's own
contribution to interrupt latency: 4.68 ms down to 11.4 us. QEMU
(RECORDED only, 62.5 MHz): after, 114 calls, 170282 ticks, longest 42396.

## Space (`python3 scripts/space_delta.py main`)

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 705348 | 708260 | 757968 | 760912 |
| data | 4800 | 4800 | 2889632 | 2889632 |
| bss | 1486480 | 1486512 | 1692736 | 1692736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

boot_page_pool_cell 16480 -> 16512 (four usize counters). Text +2.9 KB:
the counters and their DDB/boot reporters, the unlink and link helpers,
the per-extent candidate loop, and the free-list consistency walk used by
the boot probes. PageMeta stays 24 bytes per page: the one usize link
became two u32 links, and the planner refuses more than 2^32 - 1 pages.
No new stack buffers; the new functions keep a few scalars each
(DECISIONS.md, stack-conservative rule). usable_ram_start did not move.
