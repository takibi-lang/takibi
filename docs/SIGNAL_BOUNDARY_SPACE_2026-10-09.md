# Signal and anonymous-memory boundary fixture space review

Measured on 2026-10-09 against fc096879 with
`scripts/space_delta.py fc096879`. Both production platforms were rebuilt
from the working tree and the baseline in an isolated worktree.

| Boundary | QEMU base | QEMU fixture | RPi5 base | RPi5 fixture |
| --- | ---: | ---: | ---: | ---: |
| Linked text bytes | 726276 | 726276 | 737596 | 737596 |
| Linked data bytes | 5078 | 5078 | 2888792 | 2888792 |
| Linked BSS bytes | 1658608 | 1658608 | 1697632 | 1697632 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data/BSS symbol changed size. The new program is a standalone ELF inside
an existing fixed-size ext2 image, not code linked into the kernel.
The image remains 2883584 bytes (2816 blocks of 1024 bytes). Free blocks
change from 282 to 276 and free inodes from 936 to 935: the new file and
expanded init script consume six additional blocks and one inode.

The standalone ELF occupies 5512 file bytes. `llvm-size-19` reports 3122 text,
224 data and 280 BSS bytes; these are the ELF segment accounting boundaries,
not an extra kernel reservation. The existing no-writable-globals build check
accepts it. Process storage is reclaimed through the existing exec/exit path;
the fixture forks one child at a time and reaps it before the next case.
The normal QEMU boot passes all 71 views, including the existing resource
teardown evidence and the new signal_boundary view.

Adopt this small fixture cost. No pool metadata, image reservation or retained
kernel page boundary grew, and no storage optimization is warranted. Measure
again when a production allocation workload changes, diagnostics gain storage,
or the next kernel feature or roadmap stage completes. This measurement does
not substitute for a physical-board integration verdict.
