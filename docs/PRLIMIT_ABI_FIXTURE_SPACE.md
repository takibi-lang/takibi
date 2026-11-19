# Prlimit64 ABI fixture space

Both normal kernels were compared with `434a8c58d`. The existing EL0
payload checks the initial successful RLIMIT_NOFILE result and sentinel
bytes on both sides. The kernel syscall and allocation workload are
unchanged.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Linked text (bytes) | 832252 | 832252 | 4225416 | 4225448 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The normal QEMU kernel is byte-identical. The EL0 payload `.text`
remains 35972 bytes. The compressed fixture embedded in the RPi5 kernel
grows from 3335846 to 3335873 bytes. The EL0 entry's individual frame
grows from 7376 to 7392 bytes. The memory-map check confirms all five
allocator expectations. Physical timing was outside this review.
