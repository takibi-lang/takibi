# Syscall affinity handoff cost

Measured on 2026-11-24 against normal production builds of fd2ea229a.
The candidate changes the entry handoff of an untouched ordinary EL0 SVC on
an excluded peer CPU. Re-admission runs the operation on the original frame.
A committed departure retains the existing stack until the idle tail releases
it, and the destination accounts for a new diagnostic attempt. Existing
results, including a completed sched_setaffinity, use their current
syscall-return path. The ext2 admission and EL1 continuation paths keep their
current storage.

| Normal image | Baseline text class | Candidate text class | Data | BSS before -> after | Usable RAM starts before -> after |
| --- | ---: | ---: | ---: | ---: | --- |
| QEMU | 843704 B | 844228 B | 4624 B | 1310720 -> 1310720 B | 0x40210000 -> 0x40218000 |
| RPi5 | 4239316 B | 4239760 B | 5600 B | 1896448 -> 1892352 B | 0x7e0000 -> 0x7e0000 |

The linked data and BSS symbols retain their sizes, including 576 B of
workload profiling storage on each target. The RPi5 BSS section begins one
page later and ends at the same address, using 4096 B of former padding.
The permit adds no task fields or persistent allocation.

On QEMU the end of `.text` crosses the `0x400a2000` read-only page boundary.
This shifts `.bss` by one page and the aligned stack reservation by 32 KiB,
reducing the RAM available to the allocator by 32 KiB. With the following
section sizes and alignment fixed, 448 B less `.text` would bring `.rodata`
back to its previous page and recover that reservation. With `.rodata`
still on its new page, the end of `.data` would have to move back 536 B to
put `.bss` on its previous page. These are linked-image thresholds.

The normal dispatcher frame grows from 112 B to 144 B on both targets.
The body frame shrinks from 320 B to 288 B on QEMU and stays 288 B on
RPi5. The cold commit frame grows from 64 B to 128 B, the old 32 B
migration entry disappears, and the profiling helper has a 32 B frame.
These are individual static frames. They do not establish whole-stack high
water.

Remeasure when the idle handoff, syscall continuation, or affinity admission
changes, and measure per-path latency when assessing general preemption.
