# UART callback registration space review

Measured the normal linked kernels with and without guarded registration on
the 2026-11-19 main baseline, dc4e4a927. The existing native PL011 FIFO fixture
exercises the real registration code, including replacement after BootPhase,
calling a snapshot after replacement, and registering from inside a callback.

| Boundary | QEMU baseline to candidate | RPi5 baseline to candidate |
| --- | --- | --- |
| Text (llvm-size) | 829804 to 830420 B (+616) | 4223176 to 4223760 B (+584) |
| Data | 4608 B unchanged | 5584 B unchanged |
| BSS | 1310720 B unchanged | 1916928 B unchanged |
| uart_rx_handler symbol | 8 to 16 B | 8 to 16 B |
| usable_ram_start | 0x40210000 unchanged | 0x7e0000 unchanged |

The callback payload is one 8-byte function pointer. The IRQ-safe cell adds
an 8-byte lock word, absorbed by padding in the linked images. Registration
does not allocate or retain pages or change pool sizes. Normal linked
objects on both targets report 32-byte delivery, 48-byte snapshot and
setter, and 16-byte boot-reset frames. These are individual frames and
exclude nested lock operations and callback bodies. The host test measures
sequential behavior. IRQ scheduling, timing and cache behavior are outside
its scope.

The measured cost buys checked postboot replacement and invocation after
guard release. Remeasure if the registration lock backend, callback resource
lifetime, or image reservation changes.
