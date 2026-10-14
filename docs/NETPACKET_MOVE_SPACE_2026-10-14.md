# #740: the stack takes NetPacket by move (2026-10-14)

Linked kernels, working tree against main 3474d149, scripts/space_delta.py:

```
base main -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 695216 | 695064 | 745264 | 745032 |
| data | 4744 | 4744 | 2889536 | 2889536 |
| bss | 1486160 | 1486160 | 1692672 | 1692672 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
no data/BSS symbol changed size
```

Text shrinks: the descriptor index fields and net_rx_repost go; virtio_net_rx_refill and GEM's rearm call add less. No data/BSS change.
