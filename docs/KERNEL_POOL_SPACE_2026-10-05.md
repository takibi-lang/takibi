# Kernel pool space baseline, 2026-10-05

The current production allocator layout was measured without changing pool
placement, chunk policy, generation representation, or adding per-CPU fronts.
`KERNEL_POOL_SPACE_2026-10-05.tsv` records both maintained platforms: QEMU with
two active cores and RPi5 with four. Both completed the bounded boot suite,
including BusyBox/musl HTTP, connected socket I/O, process/VM/FD churn, and
resource teardown. Each passed 68 integration views. The observations below
were identical on the two platforms and at the two sampled phases.

## Accounting boundary

`boot` is after permanent root-0 FD/image acquisition and before common probes.
`bounded_end` is after the bounded user fixtures and zombie collection, before
the persistent demo shell. Each pool is sampled under its own allocation
lock. These are endpoint observations, not a simultaneous global snapshot or
maximum live counts during the workload. `nonfree` includes Out/Dying region
states; occupied storage is `nonfree * sizeof(T)`, not caller payload use.

The nine direct production object pools are included. Root-0 records outside
pools, fixture-only pools, physical-page allocation metadata, object-owned
pages/buffers outside the slot, and compiler static state are excluded.
Chunk bytes come from guarded allocator metadata rather than symbol sizes.
Pool/object/slot sizes come from compiler `sizeof` in the running kernel.

| Pool | Object bytes | Pool body | Chunk bytes | Chunks | Capacity | Non-Free |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Process record | 872 | 104 | 8192 | 1 | 9 | 0 |
| TCP connection | 224 | 16 | 4096 | 0 | 0 | 0 |
| Retransmit entry | 1592 | 16 | 8192 | 0 | 0 | 0 |
| Network frame | 1528 | 16 | 8192 | 0 | 0 | 0 |
| Address-space backing | 40 | 16 | 4096 | 0 | 0 | 0 |
| Image record | 88 | 16 | 4096 | 1 | 42 | 1 |
| FD context | 72 | 16 | 4096 | 1 | 50 | 1 |
| FD block | 528 | 16 | 4096 | 1 | 7 | 1 |
| Shared object | 80 | 16 | 4096 | 1 | 46 | 1 |

An empty process pool retains one initialized chunk. Zero network/backing
chunks at the endpoints do not mean those pools were unused during the suite.

| Category | Bytes at either endpoint |
| --- | ---: |
| Occupied object storage | 768 |
| Free object storage in retained chunks | 21752 |
| Per-slot generation/state words | 1232 |
| Reserved chunk headers | 224 |
| Payload alignment padding | 24 |
| Unused chunk tail | 576 |
| All allocated chunks | 24576 |
| Static pool bodies | 232 |
| Pool bodies plus allocated chunks | 24808 |

The 1232 metadata bytes cover allocated slot capacity, including free slots.
They are not metadata only for the four occupied objects. The intrusive pool
reserves 128 bytes per chunk, although its current header fields occupy 72;
its slot stride is 880, including one eight-byte generation. A built-in pool
has a 24-byte chunk header, a separate eight-byte word per slot, and payload
aligned to 16 bytes. Its 64-bit word holds two state bits, sixteen pin-count
bits, and forty-six generation bits. Changing that word to 32 bits while
keeping state/pin widths would leave fourteen generation bits, not a 32-bit
generation. No representation change was made for this measurement.

## Reproduction and limits

Run `make kernelcheck-qemu` and `make kernelcheck-rpi5`. The shared view checks
all nine numeric rows per phase, byte accounting, and complete phase framing;
it writes `pool-space.tsv` beside each UART capture. Recompute independently
with `python3 scripts/measure_kernel_pool_space.py <uart.log>`. Timestamped
dmesg replays are ignored so they do not count as new observations.

The native region fixture additionally checks growth/shrink and pinned dying
states, which the endpoint workload need not leave behind. Parser controls
reject missing/duplicate pools, malformed phases, inconsistent capacity and
bytes, impossible occupancy, and unexpected layout changes.

This baseline does not measure workload peaks or compare Linux SLUB/FreeBSD
UMA totals. A cross-kernel comparison still needs a matching allocation
workload and an explicit accounting boundary: cache descriptors, per-CPU
caches, retained free storage, page metadata, and caller-owned resources must
be treated consistently. Their estimated overheads are not substitutes for
measured totals. Pool tuning remains deferred.
