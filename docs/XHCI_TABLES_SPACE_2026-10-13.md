# #720 slice 3a (xHCI session tables and input context): space measurement (2026-10-13)

Slice 3a moves the scratchpad buffers and array, the ERST and the input
context onto device protocols in usb_xhci_rings.tkb. The base is main
186f0c85, which already contains slice 2.

## As first measured: the QEMU kernel grew too

scripts/space_delta.py against 186f0c85, before the fix below:

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 715832 | 724288 | 729152 | 737672 |
| data | 5488 | 5584 | 2889352 | 2889448 |
| bss | 1660704 | 1660704 | 1699952 | 1700720 |
| usable_ram_start | 0x40248000 | 0x40250000 | 0x718000 | 0x718000 |
```

Why QEMU grew by the same amount as RPi5, although xHCI is RPi5 hardware.
The QEMU kernel.elf of 186f0c85 and of slice 3a were compared section by
section (llvm-size -A) and symbol by symbol (llvm-nm -S):

| QEMU section | 186f0c85 | slice 3a | delta | what it is |
|---|---|---|---|---|
| .text | 569692 | 575084 | +5392 | +4836 B of symbols, the rest alignment padding |
| .eh_frame | 96532 | 99340 | +2808 | unwind entries of the new functions |
| .rodata | 49608 | 49864 | +256 | |
| .got | 5016 | 5112 | +96 | |
| .bss | 1234720 | 1234720 | 0 | +302 B of symbols absorbed by alignment |

- **All of the growth is the xHCI code.** Of the +4836 B of symbol text,
  1744 B is the generated protocol code (XhciErst_*, XhciScratch*_*,
  XhciInput_*). The rest is the hand-written slot helpers and table
  functions (xhci_tables_start 520 B, xhci_input_recover 216 B, the
  park/restart functions), plus small changes to xhci_configure_endpoint
  (+108 B), xhci_address_device (+56 B) and xhci_setup_rings_and_start
  (-180 B).
- **No other code grew.** Nothing outside xHCI changed size.
- **Root cause: the QEMU kernel linked RPi5's whole xHCI driver.**
  kernel/drivers/block/memory.tkb, shared by both platforms, names the
  driver's disk_status, disk_read_sectors and disk_write_sectors for its USB
  backend. The Makefile therefore compiled kernel/platform/rpi5/usb_xhci.tkb
  into QEMU "purely so the whole-program link resolves". That brought in
  everything the driver pulls in: its DMA records, the ring and table
  owners, and the configuration parser. All of it is unreachable on QEMU,
  which never selects the USB backend, and nothing removes unreachable code
  from the link. Every xHCI change was paid twice.
- **The usable_ram_start step.** The QEMU image end moved up 8 KiB in total
  and crossed the 32 KiB step that usable_ram_start is rounded to.

## The fix: the xHCI driver leaves the QEMU image

kernel/platform/qemu/usb_disk_absent.tkb answers those three calls with "no
disk" (DiskIoResult::Err). Every QEMU compile in the Makefile, and the
three buildcheck scripts' QEMU source lists, now name it instead of
usb_xhci.tkb. The QEMU kernel now compares to 186f0c85 as follows:

| QEMU section | 186f0c85 | now | delta |
|---|---|---|---|
| .text | 569692 | 555228 | -14464 |
| .rodata | 49608 | 49056 | -552 |
| .eh_frame | 96532 | 93092 | -3440 |
| .data | 472 | 240 | -232 |
| .bss | 1234720 | 1087264 | -147456 |

The BSS drop is the xHCI fixed DMA allocations, two of them 64 KiB, which
QEMU no longer carries. The QEMU fixture's allocator expectations rise by 48
pages (MULTIBANK 261600, LOW 32224, DISCONTIGUOUS 196064). kernelcheck-qemu
shows QEMU's behaviour is unchanged: virtio-blk is its only block device,
as before.

## RPi5

The RPi5 kernel grows as measured above:
- text +8520 B, of which about 1.7 KB is generated protocol code;
- about 300 B of new state: five 1-byte region claim flags, the slots
  (32 + 32 + 64 + 56 B), the completion counter and the publish mark
  (8 B each);
- ERST and the scratchpad array rounded from 16 to 64 B, because a device
  protocol region must be whole cache lines;
- usable_ram_start unchanged.

Of the generated code, about 116 B is unreferenced accessors (#782). The
per-TRB slot round trips are #783.
