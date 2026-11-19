# Boot execution context space review

Both normal linked kernels were measured against `4586b164f`. Both use
the same boot workloads and permanent rootfs metadata storage.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text (bytes) | 831892 | 831844 | 4225504 | 4225440 |
| Data (bytes) | 4624 | 4616 | 5600 | 5592 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1912832 | 1908736 |
| Boot execution context (bytes) | 184 | 0 | 184 | 0 |
| Rootfs metadata (bytes) | 1024 | 1024 | 1024 | 1024 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |
| Boot driver normal frame (bytes) | 1120 | 1376 | 1120 | 1376 |
| Boot driver debug frame (bytes) | 1152 | 1424 | 1136 | 1424 |
| Child exec preparation normal frame (bytes) | 1040 | 1104 | 1056 | 1136 |
| BusyBox inode matcher normal frame (bytes) | 64 | 144 | 64 | 144 |

Boot and exec readers share the syscall mount descriptor. The existing
lookup checks its publication state and acquires the descriptor before
returning the configured case. The compiled configured path uses two
acquire reads of the same state word. Path syscalls already used this
lookup. Physical latency was outside this review.

The boot driver's image plan refers to the same permanent window. The
largest measured boot driver frame is 1424 bytes, below the existing
2048-byte per-function ceiling. The frame sizes are individual functions.
The RPi5 linked BSS change includes alignment. The reserved image span and
allocator start are unchanged.
