# Boot process probe frame space

The scheduler and trace block/wake boot probes share two fixed saved-frame
stand-ins. They park frame addresses, inspect or change the saved SPSR, and
deliver a UART result through x0. The separate EL1 restore probe uses a
frame on a process kernel stack.

The compiler's packed ExceptionFrame is 808 bytes. The generated AArch64
context is 816 bytes (0x330), including the padding for the 16-byte stack
boundary. Each stand-in uses 102 kernel words with explicit 16-byte
alignment. The existing SPSR offset remains 0x108.

Normal linked kernels measured against `3faa06648` with LLVM 19 ELF tools:

| Linked-image boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Parent stand-in (bytes) | 1024 | 816 | 1024 | 816 |
| Child stand-in (bytes) | 1024 | 816 | 1024 | 816 |
| Text (bytes) | 832252 | 832252 | 4225720 | 4225720 |
| Data (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS (bytes) | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

Both symbols meet the 16-byte alignment on both targets. They use 416
fewer bytes in total. The linked BSS size, usable memory start and five
allocator expectations are unchanged. These measurements do not include
physical timing. Remeasure when the exception ABI, probe storage or
linked reservation boundary changes.
