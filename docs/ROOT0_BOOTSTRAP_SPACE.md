# Root 0 bootstrap space review

The primary boot entry constructs root 0 using the two existing allocator
pages and the shared identity tables. It enables translation from the local
L1 address and ASID. The five fields of the permanent backing record become
visible after activation and before main starts secondary cores. Failed page
allocation stops in the primary entry, before translation activation. Failure
to allocate the second page returns the first to the boot allocator.

## Normal linked images

Measured with `python3 scripts/space_delta.py 888bdcea2` on the integrated
root 0 change. Sizes are in bytes.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text | 831912 | 831840 | 4225220 | 4225132 |
| Data | 4624 | 4624 | 5600 | 5600 |
| BSS | 1310720 | 1310720 | 1912832 | 1912832 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

No data or BSS symbol changed size. The linked memory-map check accepted all
five allocator expectations. The backing record is still 40 bytes on both
targets and normal construction still retains two pages. Activation adds
no allocation or repeated per-process work.

Both normal linked ELFs put `kernel_mmu_activate` after the table builders
and before the backing stores. The primary entry's allocation-failure
branch loops on WFI. The construction and primary-entry frames are 128 and
16 bytes respectively, as read from their linked prologues. These are
per-function frames. Boot-chain high-water usage and physical timing were
outside this review.
