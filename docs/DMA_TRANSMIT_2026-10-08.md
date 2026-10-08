# Fixed-DMA transmit allocations: space measurement (GitHub issue #717, 2026-10-08)

Change: `dma_begin_tx`/`dma_finish_owned_tx` protect device-read buffers
with the same CPU/Device tokens as receive. The virtio-blk request header
and write data, and the xHCI CBW and bulk-out payload, became `dma_fixed`
records in the mint files `virtio_blk_dma.tkb` and `usb_xhci_dma.tkb`. They
replace `virtio_blk_request_buf`, `virtio_blk_data_buf`, `msc_cbw_buf` and
`msc_bounce_buf`.

Measured with llvm-size-19 and llvm-nm-19 on fresh production builds of
origin/main (ff6fb8c1) and the change.

| | QEMU base | QEMU change | RPi5 base | RPi5 change |
| --- | --- | --- | --- | --- |
| llvm-size text | 709748 | 712468 | 719852 | 722524 |
| data | 5030 | 5062 | 2888736 | 2888768 |
| bss | 1656624 | 1655712 | 1692512 | 1692544 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

Symbol changes (QEMU and RPi5 alike): four compiler-created owner slots of
32 bytes each, and the request header grows from 16 bytes to one 64-byte
cache line, which a protected allocation must own whole. The four buffers
are otherwise renamed at the same size. The BSS totals also move by
alignment padding from the new placement order. `usable_ram_start` is
unchanged on both targets, so the image span and the page reservations
are unchanged.

Text grows by 2720 (QEMU) and 2672 (RPi5) bytes: the owner-slot exchange
functions for four more records, and the token match at each CPU fill.
At run time each USB command and each virtio request makes a few more
uncontended mutex acquire/release pairs, small next to the device
round trip. The CDB setter takes the slot once per byte (up to seven per
READ/WRITE(10)); it could take it once per CDB if a profile ever shows it.
