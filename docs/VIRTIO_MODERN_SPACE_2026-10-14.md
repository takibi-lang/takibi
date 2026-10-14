# Modern virtio-mmio and E1 used rings: space (2026-10-14)

Workload: GitHub issue #740 U2. virtio-blk and virtio-net on the modern
(Version 2) virtio-mmio transport; each used ring is a 128-byte region
backing global owned through the VirtioUsed rx device protocol and read
only through snapshots. Linked production kernels, `python3
scripts/space_delta.py main` against main 216cf772.

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 687456 | 695200 | 738792 | 745264 |
| data | 4664 | 4744 | 2889496 | 2889536 |
| bss | 1513424 | 1486160 | 1704960 | 1692672 |
| usable_ram_start | 0x40220000 | 0x40218000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  qemu: __region_claimed__virtio_blk_used_ring None -> 1
  qemu: __region_claimed__virtio_net_rx_used_ring None -> 1
  qemu: __region_claimed__virtio_net_tx_used_ring None -> 1
  qemu: rx_queue_mem 8192 -> 256
  qemu: tx_queue_mem 8192 -> 256
  qemu: virtio_blk_queue 8192 -> 256
  qemu: virtio_blk_used_claimed None -> 1
  qemu: virtio_blk_used_ring None -> 128
  qemu: virtio_net_rx_used_ring None -> 128
  qemu: virtio_net_tx_used_ring None -> 128
  qemu: virtio_net_used_addr None -> 16
  qemu: virtio_used_reset_confirmed None -> 1
  qemu: virtio_used_slots None -> 168
  rpi5: __region_claimed__virtio_blk_used_ring None -> 1
  rpi5: virtio_blk_queue 8192 -> 256
  rpi5: virtio_blk_used_claimed None -> 1
  rpi5: virtio_blk_used_ring None -> 128
  rpi5: virtio_used_reset_confirmed None -> 1
  rpi5: virtio_used_slots None -> 168
```

Assessment:

- BSS falls 27264 B on QEMU and 12288 B on RPi5. The legacy transport
  needed one QueuePFN allocation of two pages per queue (desc, avail and a
  page-aligned used ring); the modern one takes three addresses, so the
  desc/avail arrays are 256 B and each used ring 128 B. QEMU frees 8
  allocator pages (usable_ram_start 0x40220000 -> 0x40218000).
- Text grows 7744 B on QEMU and 6472 B on RPi5 (virtio-blk is linked on
  RPi5 too). It is the generated VirtioUsed protocol code (init, publish
  with clean+invalidate, the snapshot peek that invalidates and copies the
  128-byte ring, the quiesces/reclaim pair), the three owner slots'
  take/park under their Mutexes, and the FEATURES_OK handshake and
  three-address queue setup in both drivers. A used-ring read is now a
  128-byte copy instead of a 2-byte raw load; the drivers poll it a few
  times per request, which is not a measured hot path. Adopted: the raw
  `*io` used-ring reads (6 io dereference sites) are gone.
- Data +80 / +40 B: slot and record globals.
