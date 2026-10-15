# #740: the RX capability split (2026-10-15)

Linked kernels, working tree against main 993b5945, scripts/space_delta.py:

```
base main -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 695064 | 696648 | 745032 | 746712 |
| data | 4744 | 4752 | 2889536 | 2889544 |
| bss | 1486160 | 1486352 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  qemu: virtio_pkt_kept_len None -> 40
  qemu: virtio_pkt_slots 880 -> 1040
  rpi5: gem_pkt_kept_len None -> 16
  rpi5: gem_pkt_slots 352 -> 416
```

- Text +1584 B QEMU / +1680 B RPi5: net_rx_keep, net_packet_kept_claim,
  net_packet_free, net_packet_kept_send, the out-count scan, the Kept arm
  at every pool match, and the ARP path answering from a kept packet.
- Pool slots +16 B each (QEMU 880 -> 1040 B, RPi5 352 -> 416 B): the slot's
  held variant gained the Kept case, whose payload widens the variant.
- Kept lengths: 40 B (QEMU, 10 slots) and 16 B (RPi5, 4 slots).
- usable_ram_start unchanged on both: no page moved.

Adopted: the cost is the mechanism the next two #740 steps need (the TCP
retransmit queue, then possibly the socket receive queue), and is bounded
by the pool size.
