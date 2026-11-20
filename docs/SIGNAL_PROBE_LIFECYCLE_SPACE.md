# Signal contention probe lifecycle space

Both normal kernels were compared with `8c14aaa7b`. The existing signal
contention probe closes admission and waits for joined peers before
resetting its standalone record. A timeout abandons the record and
reports failure to the boot driver. The comparison phases and the
production signal operations retain their existing lock behavior.

| Linked-image boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text, read-only data and unwind (bytes) | 833896 | 834736 | 4226996 | 4227788 |
| Initialized writable data and GOT (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS and stack sections (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

One 8-byte gate replaces the 8-byte armed word. The record remains 2192
bytes. Both targets retain the outer probe's 32-byte frame and the peer's
96-byte frame. The phase frame grows from 48 to 64 bytes, and close has
an 80-byte frame. These are individual compiled frames.

Successful admission and departure each use one atomic exchange when
uncontended. The primary closes admission with one atomic operation and
checks the registered peers within the existing peer tick windows. Their
10-second wall backstop applies per remaining peer. The probe adds no
lock acquisitions to the comparison. The linked memory map retains all
five allocator expectations. The comparison does not measure physical
wait time or maximum call-chain stack.
