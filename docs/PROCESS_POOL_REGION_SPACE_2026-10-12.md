# Process records on RegionPool: space and cost (2026-10-12)

GitHub issue #745 (#637 step B3). Process records moved from the kernel's
IntrusivePool to the built-in RegionPool, each record's permission Held in
its slot for the process's life (decision A3), walked with no lock (W2).
IntrusivePool left the kernel; tag contention evidence was retired with it.

## Linked images (llvm-size, against main 0cabdb42)

| Kernel | text | data | BSS |
|---|---|---|---|
| QEMU main | 706024 | 5432 | 1660672 |
| QEMU #745 | 698536 (-7488) | 5328 (-104) | 1660272 (-400) |
| RPi5 main | 718864 | 2889296 | 1697360 |
| RPi5 #745 | 711640 (-7224) | 2889192 (-104) | 1696880 (-480) |

usable_ram_start is unchanged on both. The image shrinks because
intrusive_pool.tkb and the tag probe are no longer linked.

## Runtime (pool space view, QEMU bounded boot)

| | object | slot | chunk | chunks at boot | chunks at bounded end |
|---|---|---|---|---|---|
| before (IntrusivePool) | 1832 | 1840 | 16384 | 1 | 1 |
| after (RegionPool) | 1856 | 1856 (+8 B state word in the header) | 16384 | 1 | 3 |

- ProcessRecord grew 24 bytes: a process handle's slot reference is now a
  RegionHeld (address and generation) beside the handle's own generation,
  which the static bootstrap record needs. Three handles live in a record.
- Holding a record's permission costs nothing per record: the slot's state
  word is the place tag.
- A RegionPool walked with no lock is never shrunk (TRUSTED_BASE.md), so the
  pool keeps its peak chunks: 3 (48 KiB) at the bounded workload's end where
  IntrusivePool kept 1 (16 KiB) after reclaiming. Bounded by the peak live
  process count; a shrink protocol for walked pools is the follow-up if that
  peak ever matters.

## Pool-operation cost (RPi5, pool contention probe, core 0 uncontended)

4096 allocate/free cycles on the probe's own pool, 54 MHz counter:

| Pool | ticks | per cycle |
|---|---|---|
| IntrusivePool (main, same probe added) | 56452 | 255 ns |
| RegionPool hold/take-back cycle | 34405 | 156 ns |

The RegionPool cycle is about 39% cheaper. Both are single measurements.

## Verification

kernelcheck-qemu, kernelcheck-rpi5, churn-qemu and hwcheck-churn-rpi5 (100
rounds, four cores) green on the #745 branch.
