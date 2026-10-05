# FD pool empty-chunk retention comparison, 2026-10-05

Production retention remains one empty chunk. Experimental zero-retention
kernels used the same adopted 24-byte entry / 400-byte FD block and full-width
handle fields. Only the FD-block and SharedObject empty-chunk thresholds
changed, with identical measurement counters added to both variants.

The [experiment](../kernel/benchmarks/pool_retention/README.md) preserves
source generation, accounting boundaries and reproduction. Its captures,
experiment.json, qemu.tsv and rpi5.tsv preserve actual observations and the
input baseline dbb2852c. The experiment changes no production implementation.

## Physical workload cost

Six RPi5 boots ran in order 1,0,0,1,1,0, three boots per policy. Every boot
completed seven batches of sixteen open/fork/wait/close rounds at each of
1, 32 and 128 FDs in one continuing parent. All operations and workload
exit statuses passed. Each policy therefore has 21 batch observations per
count. Four QEMU boots reproduced functional and allocation accounting;
their elapsed times are recorded separately and are not physical evidence.

RPi5 batch wall-time observations (milliseconds, median and interquartile
range; each batch is sixteen rounds):

| FDs | Keep 1: median [p25, p75] | Keep 0: median [p25, p75] | Median change |
|---:|---:|---:|---:|
| 1 | 42.411 [42.358, 42.505] | 42.395 [42.367, 42.469] | -0.04% |
| 32 | 656.312 [654.979, 656.572] | 656.424 [655.284, 656.797] | +0.02% |
| 128 | 2,666.476 [2,661.468, 2,668.630] | 2,806.695 [2,799.483, 2,807.369] | +5.26% |

The 128-FD case has nonoverlapping interquartile ranges in this trace. The
1/32 differences are small relative to their variation; no useful timing
improvement is claimed there. These are bounded serial-workload observations,
not statistical confidence intervals, throughput guarantees, contention
measurements, or a broad prediction for every service.

## Allocation and reservation tradeoff

All repeated boots on both platforms agreed exactly on the following counter
differences from launch through final process teardown. Launcher startup and
teardown are included in these counters, outside the narrower timed batches.

| Pool | Keep 1: grows / shrinks | Keep 0: grows / shrinks | Keep 1: final bytes | Keep 0: final bytes |
|---|---:|---:|---:|---:|
| FD block | 2 / 1 | 114 / 114 | 8,192 | 4,096 |
| SharedObject | 113 / 112 | 225 / 225 | 8,192 | 4,096 |

Zero retention adds 112 successful chunk grows per pool, 224 total. Both
policies end with one live permanent-root object in each pool and no benchmark
objects. Keep 1 holds an additional empty 4 KiB chunk per pool; keep 0 saves
8 KiB combined after process exit. That is allocator reservation, not a
payload or whole-OS RAM reduction.

The median per-boot total timed growth work on RPi5 was 416,493 / 24,051,574
ticks (FD block / SharedObject) with keep 1, and 24,906,336 / 49,806,761 with
keep 0, at 54 MHz. Summing those per-pool medians gives about 453 ms versus
1,384 ms; this descriptive sum is not an atomic interval or a median of
whole-run sums. Growth timing includes contiguous-page allocation, owner
transfer and successful region_pool_grow. Extra growth work is consistent
with the measured 128-FD slowdown; it does not isolate a single instruction
or allocator component as the entire cause. Shrink timing excludes the
region_pool_shrink search/detach and is reported separately in the TSV.
Timers themselves perturb execution and run in both conditions.

## Same service phases

A separate read-only QEMU/GDB trace repeats the earlier gated service
workload under keep 0. Its FD counts, table capacities, payloads and shared
open-description refcounts match the production keep-1 baseline. The
service/comparison.tsv keeps every phase. At 128 FDs:

| Phase | Keep 1: FD-block + object bytes | Keep 0: FD-block + object bytes |
|---|---:|---:|
| opened | 8,192 + 12,288 | 8,192 + 12,288 |
| inherited | 12,288 + 12,288 | 12,288 + 12,288 |
| reaped | 12,288 + 12,288 | 8,192 + 12,288 |
| closed | 12,288 + 8,192 | 8,192 + 4,096 |
| after process exit | 8,192 + 8,192 | 4,096 + 4,096 |

The occupied-chunk requirement during fork is unchanged. Savings come from
returning empty chunks sooner after the load recedes. The parent retains its
FD table until exit under both policies; this experiment does not implement
FD-table shrinking.

## Separate chunk-lifetime finding

A trap-free native diagnostic exposed an existing handle-lifetime gap: give
and save a slot's address/generation, take/free it, shrink its empty chunk,
release it, then grow a chunk at the same address and allocate its first slot.
region_take accepted the old numeric handle for the new allocation. The
current region_pool_grow initializes all state/generation words to zero, so
slot-generation increments do not survive chunk return and regrowth.

This affects existing retention 1 too, whenever excess empty chunks are
returned. Keeping a reserve is not a correctness repair. Zero retention
increases recycling frequency but did not create the gap. No cross-core race
is necessary. The tested syscall workloads have no deliberately retained
stale handles, so their success cannot establish that lifetime guarantee.
A compiler/built-in repair and its native regression coverage are a separate
design and implementation requirement before further policy adoption.

## Recommendation

Retain production policy 1. In this measured trace, policy 0 saves 8 KiB
at the end while adding 224 page-backed chunk grows and about 5.26 percent
to the 128-FD batch time. That tradeoff does not justify changing the current
anti-thrash reserve by default. A different workload or an explicit tighter
memory requirement could change the decision; neither was measured here.
Address the independent recycled-chunk handle gap before another retention
optimization. Full-width fields and unchanged pin rules alone do not fix it.
