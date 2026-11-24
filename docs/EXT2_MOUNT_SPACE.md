# Ext2 boot mount space

Measured on 2026-11-24 with normal linked QEMU and RPi5 production
images. The baseline is e275083b8. The candidate moves boot ext2 mount
work onto the production path with the fixture observations split out.

| Image | Text before -> after | Data | BSS before -> after | Usable RAM start before -> after |
| --- | ---: | ---: | ---: | --- |
| QEMU | 843704 -> 846088 B | 4624 B | 1310720 -> 1310720 B | 0x40210000 -> 0x40218000 |
| RPi5 | 4237876 -> 4240308 B | 5600 B | 1896448 -> 1892352 B | 0x7e0000 -> 0x7e0000 |

The maintainer accepted the 32 KiB decrease in QEMU allocator space.
RPi5 retains its usable RAM start. These linked-image measurements do
not cover runtime high water or the layout of a combined candidate.
Remeasure after integrating reader admission or syscall affinity changes.

## Combined syscall affinity and ext2 boot mount

Against the same baseline, the combined normal QEMU image has 846612 B
of text and RPi5 has 4240752 B. Data, BSS and usable RAM starts equal
the standalone mount candidate on both targets. The two changes share one
32 KiB reservation step on QEMU.
