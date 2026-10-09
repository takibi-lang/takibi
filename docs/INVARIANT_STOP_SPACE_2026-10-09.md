# Explicit invariant-stop provenance space review, 2026-10-09

Workload: maintained production QEMU and RPi5 images with distinct existing-type
invariant stop entries, immediate incoming-LR capture, and stopped-only optional
frame validation. The fixture is a separate image and adds no production
allocation. No user-space or allocator workload changed.

Measured with `python3 scripts/space_delta.py 0b015c7f` against the Place-slot
checkpoint. Values are linked production sections, not debug ELF file sizes.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text bytes | 726164 | 726928 | 737692 | 738456 |
| Data bytes | 5400 | 5400 | 2889152 | 2889152 |
| BSS reservation bytes | 1658352 | 1658432 | 1697344 | 1697344 |
| Usable RAM start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

Each CrashSnapshot grows 2056 -> 2072 bytes. The legacy primary grows by 16
bytes and the four-element peer array by 64 bytes, totaling 80 payload bytes.
These are fixed diagnostic storage, not per-process or per-page metadata.
QEMU's BSS section grows by that 80 bytes; RPi5's existing layout padding
absorbs it. Both image reservation boundaries stay unchanged, so this change
retains no additional allocator pages and does not reduce usable RAM.

Text grows by 764 bytes on each target. The new runtime work occurs only on
an invariant-stop path: the current generation and stack bounds are inspected
under a complete MachineStopped authority without taking a pool lock. Ordinary
successful syscall and driver paths add no operation. FrameRef's machine-word
ABI assertions are compile-time only. No new heap allocation, pool metadata,
frame-pointer archive, reason table or generic unwinder was introduced.

Assessment: adopted. Two scalar provenance fields and a bounded diagnostic
check fix a concrete misleading-origin report at low fixed cost. Compressing
these words or sharing the per-core records would complicate simultaneous
crash publication without recovering a page.

Next measurement trigger: another retained crash-layout change, a production
allocation change, or completion of a kernel feature/stage. Existing process
and DMA workload occupancy evidence remains applicable; this review does not
claim a new concurrency proof or a timing measurement.
