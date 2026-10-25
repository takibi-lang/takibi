# ELF load plan segments: space review (2026-10-25, #1081)

## Final design

`DistroElfLoadPlan` (kernel/fs/elf64.tkb) keeps its original nine words.
Every per-segment PT_LOAD rule lives in one function,
`distro_elf_load_accept`, which yields a `DistroElfSegment` with a closed
`DistroElfAccess`. The validator calls it while it accepts an image; the
mapper (`process_image_map_segments`) calls it through
`distro_elf_plan_segment` for each segment it maps, so the mapper has no
acceptance rule of its own.

Measured with `python3 scripts/space_delta.py origin/main` (base 4d0a18b3):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 687716 | 688076 | 741564 | 742004 |
| data | 4904 | 4904 | 6297632 | 6297632 |
| bss | 1480256 | 1480256 | 1686640 | 1686640 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0xa58000 | 0xa58000 |

+360 B text qemu, +440 B rpi5; no data or BSS symbol changed size; no pool
or reservation change. Stack frames (qemu debug image, prologue sizes):
the new `distro_elf_plan_segment` 208 B and `distro_elf_load_accept` 176 B,
both leaves of `process_image_map_segments` (416 B, was 448); no other
frame grew.

## Rejected first design (landed red)

The first version carried the 16 accepted segments inline in the plan
(private fields, 32 B each, +520 B a plan). Text grew by 8 KiB, and more
importantly every by-value plan copy is a stack temporary: in the qemu
debug image kernel_test_driver_run's frame went 944 -> 6512 B,
kernel_process_child_exec_prepare_with 1104 -> 4800 B,
kernel_exec_resolve_musl_pair 528 -> 3632 B. The land's oops, ddb and
profile lanes overflowed the 16 KiB boot stack ("kernel stack: OVERFLOW",
right after "httpd images"). `scripts/buildcheck_frame_size.py` now refuses
a frame above 2048 B at build time; run on that image it reports all six
grown frames.

Assessment: accepted. Inline segments would also have removed the second
read of the metadata window; that needs either a much smaller plan or
large aggregates copied by a loop and passed by reference, which is a
codegen change proposed separately.
