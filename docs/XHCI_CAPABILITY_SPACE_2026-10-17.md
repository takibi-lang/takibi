# #804/#806: discovered xHCI register blocks, space (2026-10-17)

The RPi5 device map reads CAPLENGTH, RTSOFF, DBOFF, HCSPARAMS1 and
HCCPARAMS1, checks each block inside the device window, and attaches one
handle per block (capability, operational, runtime, doorbell). CSZ sets the
input-context stride and MaxPorts gates the driven port. Measured with
scripts/space_delta.py against main f6850531:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 702212 | 702212 | 752440 | 754592 |
| data | 4776 | 4776 | 2889576 | 2889608 |
| bss | 1486416 | 1486416 | 1692672 | 1692736 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |
data/BSS symbols changed:
  rpi5: rp1_xhci 8 -> None
  rpi5: rp1_xhci_cap None -> 8
  rpi5: rp1_xhci_caps None -> 20
  rpi5: rp1_xhci_db None -> 8
  rpi5: rp1_xhci_op None -> 8
  rpi5: rp1_xhci_rt None -> 8
```

Assessment: QEMU unchanged (no xHCI there). RPi5 text +2152 bytes. The
earlier compare-and-stop version (+832) read two registers and compared
them with constants. This one does more: five capability reads, the
placement check for three blocks, four attaches instead of one, the named
refusal path, a context stride computed at run time where constants were
folded before (and the one guard that bounds its product), the MaxPorts
stage, and a five-value boot log line. BSS +64: three more 8-byte handles
and the 20-byte capability record, with alignment. usable_ram_start does
not move. Accepted: a fixed cost of under 0.3% of RPi5 text buys register
access at the bases the controller reports instead of constants.
