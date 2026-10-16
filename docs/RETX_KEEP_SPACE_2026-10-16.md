# #740 step 2: the TCP retransmit queue keeps the sent packet (2026-10-16)

Linked kernels, branch head against main b2ee8abf, scripts/space_delta.py:

```
base main -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 696632 | 697312 | 746712 | 747232 |
| data | 4752 | 4760 | 2889544 | 2889552 |
| bss | 1486352 | 1486352 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  qemu: tcp_kept_segments None -> 8
  rpi5: tcp_kept_segments None -> 8
```

- Text +680 B QEMU / +520 B RPi5: net_tx_keep_slot, net_transmit_keep,
  net_packet_kept_resend, the Kept park at TX completion, the retransmit
  entry's kept-slot paths; less net_rx_keep, net_packet_kept_send/_len/
  _frame and the ARP stand-in path, which were removed.
- Data +8 B: the boot evidence counter tcp_kept_segments.
- RetxEntry gains one usize (kept_slot); an entry is still two to a
  2-page chunk, so the retransmit pool's pages are unchanged. The inline
  1514-byte frame stays as the copy fallback past the reserve.
- usable_ram_start unchanged on both.

Not taken: shrinking RetxEntry by moving the fallback copy into a separate
pool. With the reserve at D + 1, virtio-net keeps one segment and GEM two,
so most outstanding segments still need the copy; the saving would come
only with a larger packet pool, which is a separate decision.
