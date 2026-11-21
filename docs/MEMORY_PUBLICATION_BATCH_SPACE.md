# Pipe wrap and USB READ(10) linked space

Measured the combined pipe fixture and fixed-size USB READ(10) receipt
against `d9ad31ea0` using `scripts/space_delta.py`. Both versions use
the same normal production build targets.

| Boundary | QEMU base | QEMU combined | RPi5 base | RPi5 combined |
| --- | ---: | ---: | ---: | ---: |
| Linked text (bytes) | 840432 | 840432 | 4233516 | 4235116 |
| Linked data (bytes) | 4624 | 4624 | 5600 | 5600 |
| Linked BSS (bytes) | 1310720 | 1310720 | 1904640 | 1896448 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |

RPi5 linked text grows by 1600 bytes and aggregate BSS shrinks by
8192 bytes. No linked data or BSS symbol changes size. The aggregate BSS
delta describes the linked layout. The checked allocator capacities and
usable RAM starts are unchanged.

The 256 KiB RPi5 inbound DMA window still spans 0x640000 to 0x680000.
The receive buffer occupies its first 64 KiB. The combined ELF retains
the pipe probe's 3168-byte static frame and the unchanged 7392-byte
initial payload frame. The pipe payload text is 37284 bytes and the
compressed fixture is 3336459 bytes. The individual reviews record the
[pipe fixture](PIPE_WRAP_FIXTURE_SPACE.md) and the
[READ(10) receipt](XHCI_READ10_SPACE.md) measurements against their
earlier published baseline. The combined review measures linked space
and retains the existing execution and DMA premises.
