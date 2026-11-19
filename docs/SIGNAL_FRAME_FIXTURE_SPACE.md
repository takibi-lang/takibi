# Normal signal frame fixture space

The existing signal boundary fixture seeds the two FPSIMD terminator fields
and the padding between `uc_stack.ss_flags` and `uc_stack.ss_size` in the
mode-zero child's ordinary stack. The handler reads those bytes before
recording success. The other modes keep their original setup. Mode four
still enters signal delivery with only the highest user stack page mapped
and exercises growth while writing the signal frame.

The mode-zero setup temporarily reserves 4688 bytes on the user stack, the
extent needed by the signal frame itself. It seeds 12 bytes and restores
the interrupted stack pointer before delivery. Ordinary stack growth can
map the second page earlier for this child. The maximum depth and final
page occupancy during delivery are unchanged. The extra fixture work is
one ordinary setup and readback per run. No physical timing was measured.

Both normal linked kernels were compared with `6e07bd000`. Sizes are in
bytes.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text | 831876 | 831876 | 4225168 | 4225504 |
| Data | 4624 | 4624 | 5600 | 5600 |
| BSS | 1310720 | 1310720 | 1912832 | 1912832 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

The standalone user fixture has 48 more bytes of instructions. The
compressed fixture image embedded in the Pi kernel grows from 3335894 to
3336226 bytes. The kernel text accounting includes that image and linker
alignment. The allocator reservation boundary stays fixed.
