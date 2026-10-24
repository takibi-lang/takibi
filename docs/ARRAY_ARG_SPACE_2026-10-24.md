# Array-holding by-value arguments: space (2026-10-24)

GitHub issue #943. Workload: both production kernels, built by
`scripts/space_delta.py origin/main` (base 3fcd6f8c, the first main commit
with #888) against the branch that passes a by-value argument whose type
holds an array as the address of a caller-made copy.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 738976 | 709896 | 790904 | 761856 |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481856 | 1481856 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

No data or BSS symbol changed size. Text: -29080 B qemu, -29048 B rpi5.

## The seven DDB functions #888 grew (llvm-nm --size-sort, qemu / rpi5)

| function | base | change |
|---|---|---|
| ddb_render_process | 880 / 860 | 456 / 456 |
| ddb_render_wait_from | 1384 / 1400 | 1116 / 1132 |
| ddb_render_wait_test | 860 / 828 | 556 / 556 |
| ddb_render_ps | 536 / 524 | 236 / 236 |
| ddb_render_proc | 500 / 512 | 228 / 228 |
| ddb_render_command | 492 / 468 | 204 / 204 |
| ddb_stack_process | 584 / 600 | 584 / 600 |
| total | 5236 / 5192 | 3380 / 3412 |

#888 added 1908 B (qemu) to these seven, so their pre-#888 total was
about 3328 B; the change is 3380 B, within 2%. The remainder is
ddb_stack_process, which returns the record inside a variant: results keep
the aggregate convention, and LLVM's sret lowering still copies the
[24 x i8] field one byte at a time there.

## Other functions that shrank (qemu)

The same per-byte argument cost sat in every caller of a function taking an
array-holding struct: procfs_render_file -14008, procfs_put_comm -4140,
kernel_process_monitor_put_command -4132, kernel_process_monitor_ps -2308,
kernel_process_monitor_proc -2264, virtio_used_snapshot -164,
VirtioUsed_virtio_used_peek -156, VirtioUsed_UsedCopy_release -8. No text
symbol grew.
