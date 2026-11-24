# Bounded user L3 retirement space

The matched normal QEMU and Raspberry Pi 5 production ELFs use
`598ff7a94` as the baseline. Measurements use LLVM 19 linked section
accounting and the linked retirement function's stack prologue.

| Boundary | QEMU baseline | QEMU batch | RPi5 baseline | RPi5 batch |
|---|---:|---:|---:|---:|
| Text, read-only and unwind data (bytes) | 847676 | 848108 | 4242116 | 4242604 |
| Initialized writable data and GOT (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS and stack sections (bytes) | 1310720 | 1310720 | 1892352 | 1892352 |
| Usable RAM start | 0x40218000 | 0x40218000 | 0x7e0000 | 0x7e0000 |
| User mappings release frame (bytes) | 96 | 240 | 96 | 240 |

The release frame contains the sixteen-word (128-byte) retirement array.
One full batch can temporarily retain sixteen detached 4 KiB tables
until invalidation completes. No resident metadata or reservation is
added. The bound is 64 KiB per in-progress release, with no general
call-chain or concurrent allocator high-water measurement.

For an activated root with populated branches, there is one completed
whole-ASID invalidation per sixteen L3 pages or remaining partial batch.
One and sixteen branches each need one invalidation, seventeen need
two, and 512 need 32. Empty active roots retain their single invalidation.
The existing per-leaf invalidations and per-unlink store barriers
remain. Never-activated roots skip the ASID invalidation. The linked
executables use the existing ASIDE1IS, DSB ISH and ISB before returning
the batch to the allocator.

The maintained address-space workload maps seventeen populated
branches in its first root, one in its second, and compares the
allocator's final live page count with the initial count. This exercises
full and partial batch reclamation. It does not measure physical
walk-cache timing. Remeasure when batch capacity, table coverage,
release-path concurrency or the image reservation changes.
