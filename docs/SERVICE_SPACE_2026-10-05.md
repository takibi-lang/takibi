# Small FD/process service comparison, 2026-10-05

The actual Takibi, Linux and FreeBSD kernels executed the same
open/fork/wait/close workload with 32 and then 128 regular files in one
continuing process. Each sampled phase waited for a host newline; no kernel
state or ordering was forced. All operations and zero exit statuses passed.
Two runs agreed on FD counts, capacities, bookkeeping and Takibi pool samples.
PIDs and address fingerprints were allowed to vary across runs.

The [reproduction and accounting boundary](../kernel/benchmarks/service_space/README.md),
[primary/repeat observations](../kernel/benchmarks/service_space/captures/), and
[validated TSV](../kernel/benchmarks/service_space/comparison.tsv) preserve the
full experiment. It is separate from `POOL_REPLAY_2026-10-05.md`.

The original tables below are the pre-reorder baseline from commit 4c116c7d.
The adopted change and actual after-change observations follow at the end.

## FD bookkeeping payload observations

Each cell counts the actor FD-context bodies, requested dynamic FD-table
storage and unique regular open-description bodies. A fork copies the table
but shares descriptions, so the shared bodies are charged once. Neither
process records nor allocator slabs/metadata are in this table. These are
stated payloads, not total RAM or a functionality-equivalent OS ranking.

| Opens | Phase | Takibi | Linux | FreeBSD |
|---:|---|---:|---:|---:|
| 32 | baseline | 600 | 704 | 1,072 |
| 32 | opened | 4,216 | 6,592 | 6,728 |
| 32 | inherited | 5,872 | 7,296 | 10,896 |
| 32 | reaped | 4,216 | 6,592 | 6,728 |
| 32 | closed | 1,656 | 704 | 4,168 |
| 128 | baseline | 1,656 | 704 | 4,168 |
| 128 | opened | 15,064 | 26,432 | 23,656 |
| 128 | inherited | 19,888 | 29,312 | 33,992 |
| 128 | reaped | 15,064 | 26,432 | 23,656 |
| 128 | closed | 4,824 | 2,880 | 13,416 |

The measured open-description bodies are 80 bytes in Takibi, 184 in this
Linux build, and 80 in FreeBSD. They implement different functionality.
For count 128, the parent table/context part alone is 4,824 / 2,880 / 13,416
bytes. Thus the lower Takibi total is not evidence that its table layout
beats Linux's: Linux has the smaller table despite the larger reserved
capacity. At count 32 Linux's 704-byte embedded table needs no growth.

## Capacity retention and fork

All three closed every regular FD yet kept the parent table capacity until
process exit. The 128 case started with the capacity left by the 32 case.

| OS | Initial parent | After 32 opens/close | After 128 opens/close | 128 child |
|---|---:|---:|---:|---:|
| Takibi | 16 | 48 | 144 | 144 |
| Linux | 64 | 64 | 256 | 256 |
| FreeBSD | 20 | 64 | 256 | 192 |

Takibi allocates linked 16-entry blocks. Linux's default 64 entries are in
files_struct; growth adds pointer arrays and bitmaps while its embedded array
remains. FreeBSD's filedesc0 retains its initial 20 entries; growth allocates
48-byte filedescent entries with capability fields. FreeBSD copied a smaller
192-entry table for the child than the parent's 256-entry table. Pointer
fingerprints matched parent/child in each fork phase; regular descriptions
had reference counts 2 at inheritance and 1 after wait.

Allocation rounding is separate: the Linux parent's dynamic table requests
2,176 bytes and has 2,208 usable bytes. The FreeBSD parent requests 12,344
and has 16,416 usable bytes, while its child requests 9,264 and has 12,320.
These are private dynamic allocation units, not their shared allocator's
whole parent slab/page storage. They are not silently substituted into the
payload totals above.

## Real Takibi pool reservations

All six participating production pools were read under a quiescent,
all-core QEMU stop without target function calls or writes. At count 128:

| Pool | Opened: live / reserved bytes | Inherited | Reaped | Closed | After process exit |
|---|---:|---:|---:|---:|---:|
| process | 1 / 8,192 | 2 / 8,192 | 1 / 8,192 | 1 / 8,192 | 0 / 8,192 |
| fd_context | 2 / 4,096 | 3 / 4,096 | 2 / 4,096 | 2 / 4,096 | 1 / 4,096 |
| fd_block | 10 / 8,192 | 19 / 12,288 | 10 / 12,288 | 10 / 12,288 | 1 / 8,192 |
| object | 129 / 12,288 | 129 / 12,288 | 129 / 12,288 | 1 / 8,192 | 1 / 8,192 |
| image | 2 / 4,096 | 3 / 4,096 | 2 / 4,096 | 2 / 4,096 | 1 / 4,096 |
| backing | 1 / 4,096 | 2 / 4,096 | 1 / 4,096 | 1 / 4,096 | 0 / 0 |

The unchanged object count at fork is the sharing the service requires; the
FD-block count increases with the copied table. At close the FD-block
occupancy stays 10 (nine parent blocks plus one permanent-root block), while
regular object occupancy returns to the permanent-root object. After exit
all benchmark process/context/image/backing/block resources have gone.
FD-block and object pools still reserve two chunks: one containing permanent
root state and the configured one-empty-chunk reserve. That is retention,
not a leftover benchmark object. These phase samples are not a global peak.

## Process records and limits of comparison

The observed per-process record payloads were Takibi 872 bytes, Linux 11,520
(task_struct), and FreeBSD 3,192 (proc plus one thread). This is not an
end-to-end process cost comparison. The feature sets differ, VM and kernel
stacks are excluded, and Takibi runs AArch64 while the reused Linux/FreeBSD
guests run AMD64. No proportion of these record sizes is attributed solely
to the language or allocator. User RSS and whole-OS RAM were not measured;
HTTP, throughput and physical cache behavior were not part of this small
slice. Adding their numbers to the FD payloads would not repair that boundary.

## Small layout sensitivity result

A separate compiler layout probe keeps every current FD field and both
64-bit handle words, but puts close_on_exec next to the one-byte kind. LLVM
reports CurrentEntry 32 bytes, ReorderedEntry 24, and ReorderedBlock 400
instead of the current 528. The source and emitted layout records are in the
experiment directory. This changes no generation width or ownership rule;
it is an existing struct-layout option, not a new compiler capability.

For nine parent blocks it would reduce table payload by 1,152 bytes. The
current region chunk capacity is seven 528-byte blocks; the 400-byte candidate
would fit nine. The observed peak of 19 blocks still requires three chunks
under either capacity, so this trace predicts no reduction of minimum reserved
pages from that reorder alone. This is capacity arithmetic, not a measured
candidate implementation or contention result. Caller migration would include
positional FdEntry construction; no new per-call annotation is proposed.

At the baseline measurement, no production field order, block policy, retention, generation representation
or per-CPU front changed. Keep those decisions separate from the measured
workload and choose any adjustment on its own evidence. In particular, this
trace does not justify narrowing generation bits or adding cache-line padding.


## Adopted field reorder and measured effect

The maintainer selected payload reduction as the first adoption criterion.
Production FdEntry now places close_on_exec next to kind, preserving every
field, both full-width handle words and all ownership/locking behavior.
Compile-time assertions require entry size 24 and block size 400 bytes.
The matching DWARF observer confirmed these sizes in the real kernel.

The same workload completed successfully twice after the change. FD counts,
capacities, fork sharing/refcounts, wait/close behavior and teardown agree
with the baseline; only block payload/packing changed. The new captures and
`packed.tsv` are preserved alongside the baseline.

| Opens | Phase | Baseline FD payload | Adopted FD payload | Reduction |
|---:|---|---:|---:|---:|
| 32 | opened | 4,216 | 3,832 | 384 |
| 32 | inherited | 5,872 | 5,104 | 768 |
| 32 | closed | 1,656 | 1,272 | 384 |
| 128 | opened | 15,064 | 13,912 | 1,152 |
| 128 | inherited | 19,888 | 17,584 | 2,304 |
| 128 | closed | 4,824 | 3,672 | 1,152 |

At 128 opens the parent FD table/context payload is 3,672 instead of 4,824
bytes (23.9 percent less); including regular open-description bodies gives
13,912 instead of 15,064 (7.6 percent less). These are payload reductions,
not whole-service RAM or throughput gains.

The real FD-block pool now fits nine blocks per chunk instead of seven.
The observed 19-live-block fork phase still reserves three chunks (12 KiB),
and post-exit reservation remains two chunks (8 KiB). In the 128-open phase,
ten live blocks still need two chunks (8 KiB). Thus this workload confirms
payload reduction without a reduction of FD-block reserved pages. Generation
width, block length, empty-chunk retention and per-CPU policy are unchanged.
