# Equal-workload allocator space measurement, 2026-10-05

Takibi, Linux SLUB and FreeBSD UMA ran the same nine object sizes and the same
serial allocation/free sequence with fresh private pools. No allocator
packing, generation width, retention policy, or per-CPU front was changed.
The [experiment README](../kernel/benchmarks/pool_space/README.md) pins the
versions, configuration, accounting boundary and reproduction commands.
[Raw observations](../kernel/benchmarks/pool_space/captures/) and the
[validated comparison TSV](../kernel/benchmarks/pool_space/comparison.tsv)
retain every per-pool phase, rather than only these totals.

## Summed independent pool observations

Bytes are object slab/chunk pages; aux is private allocation machinery under
the stated boundary. Each cell is `bytes + aux`. These are sums of independent
cases, not a simultaneous system snapshot. Full payload storage is 160,768
bytes for count 32, and 643,072 bytes for count 128.

| Count per pool | Phase | Takibi | Linux SLUB | FreeBSD UMA |
|---:|---|---:|---:|---:|
| 32 | empty | 0 + 232 | 0 + 5,120 | 0 + 10,944 |
| 32 | full | 192,512 + 232 | 212,992 + 5,120 | 233,472 + 17,024 |
| 32 | half | 192,512 + 232 | 212,992 + 5,120 | 233,472 + 17,184 |
| 32 | refill | 192,512 + 232 | 212,992 + 5,120 | 233,472 + 17,184 |
| 32 | free | 16,384 + 232 | 212,992 + 5,120 | 233,472 + 17,792 |
| 128 | empty | 0 + 232 | 0 + 5,120 | 0 + 10,944 |
| 128 | full | 708,608 + 232 | 741,376 + 5,120 | 753,664 + 17,024 |
| 128 | half | 708,608 + 232 | 741,376 + 5,120 | 753,664 + 22,592 |
| 128 | refill | 708,608 + 232 | 741,376 + 5,120 | 753,664 + 21,056 |
| 128 | free | 16,384 + 232 | 716,800 + 5,120 | 753,664 + 25,536 |

## Count 128, full phase, object pages by pool

Capacity is also in the TSV. A lower page count may mean a different slab
order, free-slot reserve, or prefetch policy rather than less metadata.

| Pool | Object bytes | Takibi pages (bytes) | SLUB pages (bytes) | UMA pages (bytes) |
|---|---:|---:|---:|---:|
| process | 872 | 122,880 | 131,072 | 122,880 |
| tcp | 224 | 32,768 | 32,768 | 45,056 |
| retx | 1592 | 212,992 | 229,376 | 212,992 |
| frame | 1528 | 212,992 | 229,376 | 212,992 |
| backing | 40 | 8,192 | 8,192 | 12,288 |
| image | 88 | 16,384 | 12,288 | 24,576 |
| fd_context | 72 | 12,288 | 12,288 | 20,480 |
| fd_block | 528 | 77,824 | 73,728 | 77,824 |
| object | 80 | 12,288 | 12,288 | 24,576 |

## What this supports

The rough issue-era estimates are not the current measured implementation.
Built-in pool bodies are 16 bytes; the intrusive process body is 104 bytes.
All nine together charge 232 bytes, before chunk storage. Current built-in
slots have one packed 64-bit word, not a separate 16-byte state/generation
pair. At count 128 the 1,288 reserved Takibi slots account for 10,304 bytes of
state/generation metadata inside 708,608 chunk bytes (about 1.45%). Payload
storage is 643,072 bytes; 136 extra reserved slots, metadata, headers,
alignment and tail slack explain the rest. A slot word adds 20% to a 40-byte backing payload (16.7% of payload plus
word), but about 0.5% to the largest payloads.

In this trace Takibi's full object-page total was below both OS totals,
including its generation metadata. This does not establish universal space
superiority: SLUB used larger orders for retransmission/frame pools and UMA
prefetched spare objects into buckets. SLUB used fewer image and FD-block
pages than Takibi. The free phase is especially policy-sensitive: Takibi
trimmed empty chunks to its configured reserves while SLUB/UMA retained
cache storage. No delayed drain or memory-pressure experiment was run, and
these free-phase counts are not leak findings.

Each allocator was run twice. All 90 numeric observations were identical in
the second run, including metadata observations; all teardown markers passed.
Takibi returned the native page-provider live count to zero. This is bounded
space evidence for this sequence, not a throughput benchmark, concurrency
proof, global peak, or representative production service-workload result.

No generation compression, bitmap representation, per-CPU allocation front,
or pool relocation is justified solely by these totals. A four-byte packed
word retaining two state bits and sixteen pin bits leaves fourteen generation
bits, compared with forty-six today; changing that needs a lifetime/wrap
contract rather than treating four bytes as free savings. The current full
sample's slot-word bytes are small relative to chunk and cache policy, so keep
the current safety and allocation baseline for now.

The separate small FD/process service comparison is recorded in
`SERVICE_SPACE_2026-10-05.md`. It observes real resource counts, FD capacities,
and stated bookkeeping payloads through open/fork/wait/close phases. Its
internal object graphs and accounting boundary differ from this equal-size
allocator replay; do not pool the two datasets. Neither experiment ranks
whole-OS RAM consumption. Only Takibi, Linux and FreeBSD are compared.
