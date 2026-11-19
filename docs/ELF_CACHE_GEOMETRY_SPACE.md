# ELF cache maintenance geometry and space

The ELF loader cleans data and invalidates instructions before publishing an
executable segment page. The AArch64 helper reads CTR_EL0 once, uses DminLine
and IminLine for the two strides, and aligns the start separately for each
loop. The original end and barrier sequence are preserved. This covers the
issuing core's maintenance geometry. First execution on a different core
requires separate observation.

Both normal linked kernels were measured with
`python3 scripts/space_delta.py 4cbf4ef80`. Sizes are in bytes.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text | 831840 | 831876 | 4225132 | 4225168 |
| Data | 4624 | 4624 | 5600 | 5600 |
| BSS | 1310720 | 1310720 | 1912832 | 1912832 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

No data or BSS symbol changed size. The linked memory-map check accepted all
five allocator expectations. The leaf has 24 instructions, up from 15,
with no frame or calls. The instruction count per line visit is unchanged
and the visit count follows the minimum line size. Physical execution time
was outside this review.
