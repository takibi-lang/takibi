# FD contention probe receipt space

Both normal kernels were compared with `44fa537e2` using the same
compiler, build inputs and flags. The existing contention probe issues
a linear receipt after a successful retain and consumes it at release.
The receipt is a compile-time view of the published handle's storage.
The existing single setup before arming the two participants supplies the
stable handle value.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Probe cycle instructions | 42 | 42 | 24 | 24 |
| Probe cycle frame (bytes) | 32 | 32 | 32 | 32 |
| Normal object text class (bytes) | 828061 | 828117 | 4210800 | 4210856 |
| Linked machine code (bytes) | 653428 | 653428 | 697288 | 697288 |
| Linked unwind table (bytes) | 123728 | 123724 | 134440 | 134436 |

The normal linked `.text` is byte-identical on each target. The probe
cycle also has identical instructions and relocations before linking,
with one call each to the existing retain and release. The inline helper
adds an unlinked symbol and disappears at link time. Linked data, BSS,
usable RAM starts and the five allocator expectations are unchanged.
This comparison records static code and individual frame sizes.
