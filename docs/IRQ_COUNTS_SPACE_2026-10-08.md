# IRQ counts space measurement (2026-10-08)

GitHub issue #715 adds `kernel/kernel/irq_counts.tkb`: per-CPU rows of
AtomicWord counters (32 banked INTIDs, 8 SPI slots of INTID and count, one
`other`), 49 words per CPU for KERNEL_MAX_CORES = 4. GitHub issue #721 adds
host scripts only.

Measured with `python3 scripts/space_delta.py origin/main` on the standard
production QEMU and RPi5 linked kernels (llvm-size-19/llvm-nm-19):

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 712468 | 714036 | 722524 | 724092 |
| data | 5062 | 5070 | 2888768 | 2888776 |
| bss | 1655712 | 1655712 | 1692544 | 1692544 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x718000 |

The only data/BSS symbol that changed is `irq_count_cores`, new at 1568
bytes on both targets; the BSS totals are unchanged because the new array
fills existing alignment padding. Text grows by 1568 bytes (the dispatch
record call, the DDB rendering and the boot fixture). On RPi5 that growth
crosses a 32 KiB boundary of the image span, so `usable_ram_start` moves by
0x8000 and the allocator has 8 fewer pages (259312 to 259304, the RPi5 boot
view). QEMU's span is unchanged.

Assessment: adopt. 1568 bytes of counters is the bounded cost the issue
asked for (SGIs, PPIs and a handful of SPIs, not 1020 INTIDs per CPU); the
RPi5 page loss is a boundary effect of text growth, not of the counters.
