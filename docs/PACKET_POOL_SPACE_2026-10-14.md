# #740 packet-buffer pool: space measurement (2026-10-14)

The whole #740 branch against main 3059d528 (scripts/space_delta.py):
slices 1 and 3 (docs/NET_DEVICE_PROTOCOL_SPACE_2026-10-14.md), the txrx /
access read / P_S_bytes compiler work, and the pool migration of both
network drivers.

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 679768 | 685080 | 727832 | 736512 |
| data | 4632 | 4664 | 2889496 | 2889496 |
| bss | 1509152 | 1513248 | 1696704 | 1704896 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |
```

## Storage

| platform | before | after | delta |
|---|---|---|---|
| QEMU | rx_bufs 12288 + tx_ready_buf 1524 | virtio_pkt_pool 15360 (10 x 1536) + slots 880 + rx_desc_pkt 64 | +2492 B |
| RPi5 | gem_rx 2048 + gem_tx 1536 + two owner slots 80 | gem_pkt_pool 8192 (4 x 2048) + slots 352 + ring regions and slots 240 | +5120 B |

The pools are larger because a buffer now moves between roles instead of
being copied: QEMU keeps 8 posted for receive plus one Filled frame and one
transmit; GEM keeps one posted for receive while a received frame is held
and another is being transmitted. Both BSS growths fall inside the existing
page rounding: usable_ram_start, and so every page reservation, is
unchanged on both platforms.

## Text

QEMU +5312 B, RPi5 +8680 B. The protocol's generated edges, the slot
take/park functions (one Mutex per slot), and the owner hand-offs on each
receive, release, reply and send. The per-byte copy of the reply is gone
on GEM (gem_tx_submit's slice_copy from the RX buffer), and virtio's
kernel-built frames are copied once into a pool buffer as before.

## Assessment

Accepted for now. The cost buys the property #740 asked for: no CPU write
to a buffer the device owns, and no reuse of a buffer whose transmit was
not confirmed, both as type errors. Candidate reductions, not taken
without the #497 profile and the #520 throughput run the maintainer asked
for: one Mutex for the whole pool instead of one per slot (the driver is
single-core by IRQ routing), and a smaller virtio pool (8 posted + 2 is
the minimum for the driver's two API tokens).
