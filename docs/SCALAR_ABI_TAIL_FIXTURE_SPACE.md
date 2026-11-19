# Scalar ABI tail fixture space

Both normal kernels were compared with `0a36c6b20`. The existing EL0
fixture now checks the statfs reserved tail and the sysinfo output tail
and extent during successful calls. The kernel syscall handlers and
allocation workload are unchanged.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Linked text (bytes) | 832252 | 832252 | 4225800 | 4225720 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The normal QEMU kernel ELF is byte-identical. The EL0 payload text grows
480 bytes and the compressed fixture image embedded in the RPi5 kernel
shrinks from 3336226 to 3336157 bytes. RPi5 linked text accounting
includes that image and linker alignment. The existing statfs probe's
static frame grows from 288 to 304 bytes, the sysinfo probe has a
160-byte frame, and the calling EL0 entry frame remains 7376 bytes.
Individual frames do not measure a call-chain maximum. Physical timing
was outside this review.
