# Header overlays (arp, icmp, tcp off the mint list): space review (2026-10-13)

Change: `bytes as &mut T` header overlays replace raw `*T` header casts in
kernel/net/arp.tkb, icmp.tkb and tcp.tkb (#637). The check is compile time
only; the reference lowers to the same pointer the raw cast produced.

`python3 scripts/space_delta.py main` (main e8b4af06, linked production
kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 703384 | 703384 | 716656 | 716656 |
| data | 5328 | 5328 | 2889192 | 2889192 |
| bss | 1660272 | 1660272 | 1696880 | 1696880 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

No size changed and no data/BSS symbol changed. kernelcheck-qemu-main and
kernelcheck-rpi5 passed on this tree.
