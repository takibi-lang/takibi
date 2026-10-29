# #790 size review of the device-protocol and packet-pool growth (2026-10-30)

GitHub issue #790 asked for a review of what #720 (xHCI rings, tables, the
event ring) and #740 (virtio-net and GEM descriptor rings, the txrx packet
pool) added, with the numbers in hand. It uses only numbers the lanes
already produce (no fresh #497 profile or #520 throughput run, coordinator
2026-10-30). Kernels: origin/main f309626d, `make kernelbuild`.

```
                     text     data      bss
qemu kernel.elf    745960     5000  1490944
rpi5 kernel.elf    800296  6297776  1699840
```

## Per-symbol breakdown

Symbols grouped by name (`llvm-nm -S`); the group pattern is the subsystem
prefix (xhci_/Xhci/usb_/msc_, virtio_net/virtio_pkt, gem_/rp1_gem, and the
pool's net_rx_/net_packet_).

| platform | group | section | bytes | symbols | largest |
|---|---|---|---:|---:|---|
| QEMU | virtio-net + pool slots (#740) | text | 4488 | 44 | virtio_pkts_claim 556, virtio_net_tx_finish 412, virtio_net_send_built 396, virtio_pkt_park 300 |
| QEMU | packet pool API (#740) | text | 1540 | 15 | net_rx_acquire 512, net_packet_kept_claim 232, net_packet_kept_resend 164 |
| QEMU | virtio-net (#740) | bss | 1882 | 10 | virtio_pkt_slots 1040, virtio_net_queues 512, the two used rings 128 each |
| QEMU | packet pool (#740) | bss | 15361 | 2 | virtio_pkt_pool 15360 (10 x 1536) |
| RPi5 | GEM + pool slots (#740) | text | 8828 | 98 | gem_send_built 348, gem_rearm_rx 348, gem_tx_finish 344, gem_pkts_claim 324 |
| RPi5 | packet pool API (#740) | text | 1328 | 15 | net_rx_acquire 364, net_packet_kept_claim 232 |
| RPi5 | GEM (#740) | bss | 707 | 17 | gem_pkt_slots 416, the two descriptor rings 64 each |
| RPi5 | packet pool (#740) | bss | 8193 | 2 | gem_pkt_pool 8192 (4 x 2048) |
| RPi5 | xHCI and USB storage (#720 and earlier) | text | 20960 | 190 | xhci_configure_endpoint 808, xhci_address_device 728, usb_disk_initialize_stages 728, xhci_tables_start 520 |
| RPi5 | xHCI and USB storage | bss | 213036 | 64 | usb_provision_batch 65536, msc_data_transmit 65536, msc_data_receive 65536, scratchpad buffers 4096 each |
| RPi5 | USB provisioning image | data | 6291456 | 1 | usb_provision_image (the embedded ext2 image the board writes to the stick) |

The per-slot owner helpers that #783 and this review asked about:

| helper | QEMU | RPi5 |
|---|---:|---:|
| pool slot take / park (virtio_pkt_*, gem_pkt_*) | 208 + 300 | 208 + 296 |
| pool claim (virtio_pkts_claim, gem_pkts_claim) | 556 | 324 |
| slot array (owner + TaskMutex per slot) | 1040 B BSS (10 x 104) | 416 B BSS (4 x 104) |
| xHCI ring take / park / claim (after #783) | - | 140 + 212 + 60 + 232 |

## Throughput context (from the lanes)

- RPi5 TCP over the init-managed HTTPd: 1612 KiB/s, one transfer
  (`kernel-tcp-throughput`, the #783 run).
- RPi5 USB provisioning: 96 WRITE(10) in 146-184 ms over the last four
  board runs; device latency dominates.
- RPi5 lane: the kernel image loads over SWD in about 37 s for 7.1 MB, at
  187 KiB/s. About 6.3 MB of it is `usb_provision_image` in `.data`.

## Adopted

Nothing. No reduction found here is both measured and behaviour-neutral.
Each candidate below changes a lock granularity, a buffer count, or what
the board loads, and is a proposal under docs/SPACE_REVIEW.md step 3.

## Proposals (for the maintainer)

1. **One TaskMutex per pool instead of one per slot** (#740's own
   candidate). Saving: a TaskMutex is one 8-byte word, so 8 x 9 = 72 B BSS
   on QEMU and 8 x 3 = 24 B on RPi5,
   plus the per-slot lock calls in take/park. Cost: lock granularity
   changes. Today each driver runs on one core by IRQ routing, so there is
   no contention to lose, but the change has to be made in the protocol's
   generated owner shape, not by hand. Small; low priority.
2. **virtio-net pool 10 -> 8 + 2 buffers** (#740's note: 8 posted plus one
   Filled and one transmit is the minimum for the two API tokens). It is
   already 10, so nothing to cut without reducing the posted receive count,
   which trades receive burst capacity. Not recommended without the #520
   run.
3. **The RPi5 lane's load time**, the biggest cost here by far. The board
   loads 6.3 MB of `usb_provision_image` over SWD at about 187 KiB/s, about
   34 s of every RPi5 lane, so it costs wall time rather than kernel space.
   Options: shrink the provisioned image (the space checkpoint's standing
   trigger: "shrink /pad first"), or provision the stick only when its
   contents differ (a hash on the stick). Recommended to measure next; it
   is the largest single lever on allcheck time.
4. **USB DMA buffers, 3 x 64 KiB BSS** (`usb_provision_batch`,
   `msc_data_transmit`, `msc_data_receive`). They are the BSS bulk on RPi5.
   BSS does not load over SWD, so they cost RAM, not lane time. Halving the
   batch would double the WRITE(10) count of provisioning (96 -> 192),
   which the 146-184 ms figure says is cheap. A candidate if RAM becomes a
   constraint; not now.
5. **The xHCI bring-up functions** (xhci_configure_endpoint 808 B,
   xhci_address_device 728 B, usb_disk_initialize_stages 728 B) run once
   per boot. The 2026-10-19 DECISIONS route (a `.S` helper with no logic)
   does not apply: they hold logic. No change proposed.

## Next trigger

The #520 throughput run or the #497 profile when either is next taken, or a
change to a pool's buffer count or the slot shape.
