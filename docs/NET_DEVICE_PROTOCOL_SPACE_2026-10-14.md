# #740 slices 1 and 3: network device protocols, space measurement (2026-10-14)

Slice 1 puts virtio-net's scratch TX buffer on a tx device protocol
(`kernel/drivers/net/virtio_net_tx_dma.tkb`). Slice 3 puts the RP1 GEM RX
and TX descriptor rings on rx device protocols
(`kernel/drivers/net/rp1_gem_desc.tkb`). Base: main 00c3026d
(scripts/space_delta.py).

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 679764 | 681844 | 727828 | 732876 |
| data | 4632 | 4656 | 2889496 | 2889552 |
| bss | 1509152 | 1509152 | 1696704 | 1696704 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |
```

Text grows by 2080 B (QEMU) and 5048 B (RPi5); data and BSS do not change
in a way that matters, and usable_ram_start does not move.

## Where the text goes

- **Owner plumbing.** Every owner lives in a Place slot under its own
  Mutex, so each send or receive takes and parks an owner: take/park/lock
  functions of 100-170 B per ring (virtio: take 116, park 172; GEM: the
  same per ring), plus the claim at init.
- **Generated wrappers.** The publishing edges (cache work plus the state
  change) and, on GEM, two snapshot observations of about 200 B each:
  invalidate one 16-byte descriptor's line, copy it, call the lowering.
- **The rewritten paths.** Descriptor writes go through the Ready owner
  (`gem_rings_program` 316 B replaces about 180 B of net_init;
  `gem_tx_ring_settle` 192 B, `gem_tx_ring_poll`/`gem_rx_ring_poll` 196 and
  192 B), and the virtio payload is written through the owner one byte at a
  time (`virtio_net_tx_fill` 164 B; the `_write` accessor is inline).

## Storage

- virtio: the 1524-byte `tx_ready_buf` becomes the 1536-byte
  `virtio_net_tx_buf` (rounded to whole cache lines), plus a 56-byte owner
  slot and 8 bytes for the pending length.
- GEM: the two 64-byte descriptor arrays become two 64-byte region
  backing globals of four 16-byte descriptors, plus two 56-byte slots and
  three flag bytes.

## Assessment

Accepted: the cost is the owner slots and the generated cache work at each
edge, which is what makes "no write while the device owns it" a type
error. The per-byte fill on virtio is QEMU-only; the packet-buffer pool
design on #740 replaces the scratch buffer and its copy altogether. No
cheap reduction is left that keeps the guarantee: the slot plumbing could
shrink if one Mutex guarded both GEM rings, but they are independent and
taken on different paths.
