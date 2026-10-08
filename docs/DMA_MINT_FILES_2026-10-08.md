# Fixed-DMA mint files: space measurement (GitHub issue #716, 2026-10-08)

Change: `dma_finish_owned_rx` is accepted only in the file that declares
its `dma_fixed` record. The virtio-blk and xHCI receive records, their
owner-slot exchanges and the functions that observe completion or confirm
reset moved to `kernel/drivers/block/virtio_blk_receive.tkb` and
`kernel/platform/rpi5/usb_xhci_receive.tkb`. The CSW path now returns its
CPU token to the owner slot and takes it back to parse, as the data path
already did; the virtio completion path does the same.

Measured with llvm-size-19 and llvm-nm-19 on fresh production builds
(`make kernelbuild-qemu kernelbuild-rpi5`) of the base commit and the change.

| | QEMU base | QEMU change | RPi5 base | RPi5 change |
| --- | --- | --- | --- | --- |
| llvm-size text | 709308 | 709748 | 719444 | 719852 |
| data | 5030 | 5030 | 2888736 | 2888736 |
| bss | 1653664 | 1656624 | 1692832 | 1692512 |

No data or BSS symbol changed size (`llvm-nm -S` symbol/size lists are
identical). The BSS column moves only because global placement order
changed with the moved declarations, which shifts alignment padding inside
`.bss` and between `__bss_end` and the 16 KiB-aligned stacks. Total BSS
alignment padding in the QEMU image is 457209 bytes before and after, so
the image span and the page reservations are unchanged. Text grows by 440
(QEMU) and 408 (RPi5) bytes: the extra owner-slot take/put on two
completion paths and the outcome matches. Each extra exchange is one
uncontended mutex acquire/release per USB CSW or virtio request, small
next to the device round trip.
