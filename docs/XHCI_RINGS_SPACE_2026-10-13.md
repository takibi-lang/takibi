# #720 slice 2 (xHCI producer rings on XhciRing): space measurement (2026-10-13)

The four xHCI producer rings move onto the XhciRing tx device protocol:
whole-ring owners kept in four mutex-guarded Place slots. The linked kernels
were measured against main fcacade4 with scripts/space_delta.py:

```
base main -> working tree
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 712488 | 715832 | 725792 | 729152 |
| data | 5392 | 5488 | 2889256 | 2889352 |
| bss | 1660704 | 1660704 | 1700976 | 1699952 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |
new data/BSS symbols, both kernels:
  __region_claimed__xhci_{cmd,ep0,bulk_in,bulk_out}_ring  1 B each
  xhci_ring_slots 224, xhci_await_cc 4, xhci_await_timeout 8,
  xhci_await_type 4, xhci_doorbell_target 8, xhci_doorbell_value 4,
  xhci_rings_claimed 1, xhci_rings_quiesced 1
```

- Text grows by 3344 B on QEMU and 3360 B on RPi5. This is the generated
  wrappers, the slot take/park helpers and the TRB writes through a Ready
  owner, which replace the raw pointer stores.
- The new state is 259 B per kernel: the 224-byte slot array, four
  region-claim flags and the doorbell/await parameters. The ring arrays
  keep their size (4 x 256 B) and are now region backing globals.
- On RPi5 the BSS section total is 1024 B smaller, which has not been
  traced to a symbol; the per-symbol comparison shows no symbol shrinking.
- usable_ram_start is unchanged on both kernels.

No structural tradeoff is pending: the slots are the stored-authority cost
that decision S1 accepted.
