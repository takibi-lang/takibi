# #720: xHCI event ring and output context on E1 snapshots, space (2026-10-13)

The event ring and the output device context become rx device-protocol
owners, read through snapshot observations. The bus-address export moves to
usb_xhci_bus.tkb. Measured with scripts/space_delta.py against main
586b5fa9, which does not yet contain E1:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 697376 | 697376 | 736176 | 739984 |
| data | 4736 | 4736 | 2889448 | 2889496 |
| bss | 1513248 | 1513248 | 1700720 | 1700800 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |
new data/BSS symbols (RPi5): two 1-byte region claim flags, two 1-byte
claimed flags, two 32-byte slots
```

Assessment:
- RPi5 text grows by 3808 B. This is the two protocols' generated
  wrappers and snapshot reads, plus the slot helpers. The per-poll snapshot
  replaces the old dma_refresh_live of the whole ring with an
  invalidation of one entry's line.
- About 70 B of new state.
- The ring and context arrays keep their size: [Trb; 16] is 256 B, and
  [CtxWord; 512] is 2048 B, which was previously [u32; 512].
- RPi5 usable_ram_start is unchanged.
- QEMU is unchanged: it no longer links the xHCI driver.
