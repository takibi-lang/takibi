# #786 function sections and --gc-sections: space measurement (2026-10-13)

The compiler's `--function-sections` puts every defined function and named
global in its own section; every kernel link passes `--gc-sections`.
Protocol code gets internal linkage and its small accessors are `inline fn`.
Measured first against main d307f685 (tables below, plus stage-by-stage
images), then re-measured after rebasing onto main 33cfbc32 (the xHCI event
ring and output context on E1 snapshots):

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 697376 | 679764 | 739984 | 727828 |
| data | 4736 | 4632 | 2889496 | 2889496 |
| bss | 1513248 | 1509152 | 1700800 | 1696704 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |
```

On 33cfbc32 RPi5 text falls by 12156 B, QEMU's by the same 17612 B.

## Linked kernels (llvm-size, scripts/space_delta.py)

```
| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 697376 | 679764 | 736176 | 724564 |
| data | 4736 | 4632 | 2889448 | 2889448 |
| bss | 1513248 | 1509152 | 1700720 | 1696624 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |
```

QEMU text -17612 B (-2.5%), RPi5 text -11612 B (-1.6%). The page
reservation (`usable_ram_start`) does not move on either platform.

## By section

| section | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| .text | 555228 | 544908 | 583988 | 580148 |
| .rodata | 49056 | 44088 | 52024 | 46504 |
| .eh_frame | 93092 | 90768 | 100164 | 97912 |
| .got | 4496 | 4448 | 5256 | 5256 |
| .data | 240 | 184 | 2884192 | 2884192 |
| .bss | 1087264 | 1083168 | 1274736 | 1270640 |

## What went

- **Out-of-line copies of `inline fn`.** An `inline fn` is inlined at every
  call but kept external linkage, so its body stayed in the image unused:
  `syscall_getdents64_current` 1964 B, `syscall_execve_current` 1092 B,
  `syscall_readv/writev/sendfile/mprotect_current` about 1.7 KB, and many
  16-24 B view helpers (`scheduled_process_*_view_*`,
  `*_execution_model_assumption`). Both kernels.
- **The other platform's code in a shared file.** On QEMU: the RPi5 PCIe
  bring-up (`pcie2_*`, about 1.6 KB), the RP1/MIP/PCIe DTB finders
  (`fdt_find_compatible_rp1_gpio_regions` 948 B, `fdt_find_pcie_address_map`
  520 B, ...), and their 8-byte globals (`rpi5_pcie2_base`, ...). On RPi5:
  the GIC DTB finders QEMU uses, `virtio_blk_capacity_sectors`,
  `virtio_block_device_ext2`. This is the class #720 slice 3a fixed by hand.
- **Named constants.** 702 (RPi5, 5461 B) / 633 (QEMU, 4913 B) constant globals
  -- region-state constants per element type, `KERNEL_LOG_*` sizes -- that
  every use folds. GDB scripts read these from
  kernel-debug-metadata.json, not from the ELF.
- **Unwind entries** of every removed function (.eh_frame -2.3 KB).
- **Generated protocol accessors (RPi5 only, the inline step: -1128 B).**
  `XhciRing_Ready_write`, `XhciErst_Ready_write`, the `_span`s and the
  witness `_spend`s were 16-60 B functions each; as `inline fn` with
  internal linkage none survives as a function.
- .bss -4096 B on both is alignment padding before a page-aligned object;
  no BSS symbol changed size or vanished on RPi5.

Function sizes that changed without the function going (314 symbols on
RPi5, net -224 B) are loop-alignment `nop` padding, which depends on where
a function starts.

## Is #782's compiler-side pruning still needed?

Not for space: an RPi5 kernel built with #782's drop disabled links to the
identical size (text 724564) under --gc-sections. It is still needed for a
verdict: without it the never-called `XhciScratchBuf` u8 accessors are
compiled, and the raw-deref ratchet (`measure_trusted_base.py
--check-raw-deref`) refuses the build (2 dereference sites with no budget
row). Keep it, as part of what the audit counts, not as a size measure.

## Assessment

Adopted: a cheap, mechanical improvement with no safety cost. Nothing is
removed that something in the image reaches; the debugger entries are
rooted explicitly. The next measurement trigger is unchanged.
