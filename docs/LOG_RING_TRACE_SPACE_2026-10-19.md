# Log ring trace window: space review (2026-10-19)

GitHub issue #656, maintainer option A: every compare-swap site and reader
load of `kernel/printk/log.tkb` records an event, inside a window, into a
per-CPU static buffer (`kernel/printk/log_ring_trace.tkb`), and
`log_storm_trace_probe` runs one such window per boot from
`/bin/protocol-trace`. The maintainer approved about +32 KiB of .bss.

Workload and boundary: the two production kernels, linked, measured with
`python3 scripts/space_delta.py` against origin/main a0bfdfbe (the working
tree at the branch head). No pool, allocator or lifetime changes; the
storage is fixed .bss.

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 715824 | 719880 | 768548 | 772636 |
| data | 4688 | 4736 | 2889520 | 2889568 |
| bss | 1477152 | 1510000 | 1684624 | 1717408 |
| usable_ram_start | 0x40220000 | 0x40228000 | 0x720000 | 0x728000 |

Data/BSS symbols that changed (both kernels): `log_ring_trace_cpus`
32832 B (4 CPUs x (2 counters + 256 events x 32 B)), `log_ring_trace_active`
8, `log_ring_trace_from` 8, `log_ring_trace_reader_cpu` 8,
`log_ring_trace_reader_begun` 1, `log_storm_trace_rounds` 8. The image span
grows by 8 pages (usable_ram_start +0x8000), so the RPi5 boot view and the
multibank controls lose 8 allocator pages each.

Text: +4056 B qemu, +4088 B rpi5 -- the recording calls at the sites, the
report printer and the probe.

Assessment: within the approved budget. One cheap improvement was adopted
during the review: a duplicate word holding the opening head was dropped
(`log_ring_trace_from` already held it). The event is already packed to
four words (kind, k, i, outcome and the interval's length share one);
fewer events per CPU would shrink the buffer, but the window uses at most
about 80 of 256 on core 0 today and the margin is what lets a longer storm
be a local rebuild. Not adopted: a separate trace-only image (option D),
which the maintainer chose option A over.

Next trigger: a change to the event layout, to LOG_RING_TRACE_EVENTS, or to
KERNEL_MAX_CORES.
