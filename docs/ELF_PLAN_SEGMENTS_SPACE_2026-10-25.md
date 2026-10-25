# ELF load plan segments: space review (2026-10-25, #1081)

Change: `DistroElfLoadPlan` (kernel/fs/elf64.tkb) carries the validator's
accepted PT_LOAD segments, 16 private `DistroElfSegment` records of 32 bytes
(p_offset, p_filesz as usize; p_vaddr, p_memsz as u32; a `DistroElfAccess`),
plus a count. The mapper (`process_image_map_segments`) walks them instead of
re-reading program headers.

Measured with `python3 scripts/space_delta.py origin/main` (base 0433e09c):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 686276 | 694468 | 740132 | 748300 |
| data | 4888 | 4888 | 6297616 | 6297616 |
| bss | 1480256 | 1480784 | 1686640 | 1686640 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0xa58000 | 0xa58000 |

BSS: `boot_execution` 184 -> 704 B (it holds one plan); on rpi5 the growth
falls in existing alignment slack. No pool, page reservation or
usable_ram_start change.

Text: +8192 B qemu, +8168 B rpi5. The plan is passed and returned by value
along the exec path, and the compiler emits each aggregate copy as unrolled
load/store pairs, so every by-value site pays for the 520 added bytes. The
largest growth (qemu, per function): kernel_test_driver_run +1736,
kernel_exec_resolve_musl_pair +916, kernel_exec_resolve_dynamic_ext2_images
+856, distro_elf_validate_with_length +676, kernel_exec_resolve_ext2_exec
+628. A first version with 56-byte records (precomputed page spans, all
fields usize) cost +15456 B text; narrowing p_vaddr/p_memsz to 32 bits
(the validator's 2 MiB extent bound) and deriving the span through
`distro_elf_segment_pages` halved it.

Kernel stack: each live plan copy is about 520 B larger. The measured
high-water mark was 4368 of 16384 B (RESOURCE_LIMITS.md); the exec path
holds at most a few plans at once. Not re-measured here (QEMU lanes
unavailable in this worktree); the land's kernelcheck reports the watermark.

Assessment: accepted. The cost buys the removal of the mapper's own ELF
acceptance rules (the #1058 defect class) and of the second read of the
metadata window. The text cost is a codegen property (unrolled aggregate
copies) rather than the representation; a copy loop or memcpy for large
aggregates would remove most of it and is proposed separately.
