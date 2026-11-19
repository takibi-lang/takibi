# Uname ABI fixture space

Both normal kernels were compared with `78e2068e4`. The existing peer
TTY fixture checks the six uname field tails and the bytes immediately
outside the successful 390-byte result. The kernel syscall and allocation
workload are unchanged.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Linked text (bytes) | 832252 | 832252 | 4225720 | 4225416 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The normal QEMU kernel is byte-identical. The peer TTY ELF `.text` grows
from 5660 to 5916 bytes. The compressed fixture embedded in the RPi5
kernel shrinks from 3336157 to 3335846 bytes, including the effects of
compression on the other entries in the image. The EL0 `peer_identity`
frame grows from 656 to 688 bytes and the calling `peer_tty` frame stays
128 bytes. These are individual frames. The memory-map check confirms
all five allocator expectations. Physical timing was outside this review.
