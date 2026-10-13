# #720 slice 3a (xHCI session tables and input context): space measurement (2026-10-13)

Slice 3a moves the scratchpad buffers and array, the ERST and the input
context onto device protocols in usb_xhci_rings.tkb. Measured with
scripts/space_delta.py against main 186f0c85, which already contains slice 2:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 715832 | 724288 | 729152 | 737672 |
| data | 5488 | 5584 | 2889352 | 2889448 |
| bss | 1660704 | 1660704 | 1699952 | 1700720 |
| usable_ram_start | 0x40248000 | 0x40250000 | 0x718000 | 0x718000 |
```

New or resized data/BSS symbols (both kernels): five 1-byte claim flags;
xhci_cmd_completions 8; xhci_input_published_at 8; slots 32 + 32 + 64 + 56
(ERST, scratchpad array, two scratchpad buffers, input context);
xhci_tables_claimed 1. xhci_erst grows from 16 to 64 B and
xhci_scratchpad_array from 16 to 64 B: a device protocol region must be a
whole number of cache lines.

Assessment:
- Text grows by 8456 B on QEMU and 8520 B on RPi5. The cost is four
  protocols' generated wrappers and their slot take/park helpers.
- The new state is about 300 B per kernel.
- QEMU's usable_ram_start moves up by one 32 KiB step: the image end crossed
  the boundary it is rounded to. The multibank QEMU fixture's expected
  allocator page counts drop by 8 to match.
- RPi5's usable_ram_start is unchanged.

The per-table helpers are repeated boilerplate. The batched-path issue and
the unreferenced-generated-functions issue cover the generated half of it.
A shared helper per protocol shape would need generic linear slots, which
does not exist yet. No structural tradeoff is pending.
