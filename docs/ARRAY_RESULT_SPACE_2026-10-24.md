# Array-holding results and copies: space (2026-10-24)

GitHub issues #962 and #963. Workload: both production kernels, built by
`scripts/space_delta.py origin/main` (base d6290064, with #943) against the
branch that returns an array-holding result through an sret slot and copies
array-holding values with llvm.memcpy.inline.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 709896 | 666768 | 761856 | 720312 |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481856 | 1481856 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40210000 | 0x720000 | 0x710000 |

No data or BSS symbol changed size. Text: -43128 B qemu, -41544 B rpi5. The
image end moved down by 64 KiB, so the page allocator gains 16 pages (boot
view and FDT multi-bank expectations updated).

## Per function (qemu, bytes)

| function | base | change |
|---|---|---|
| procfs_render_file | 8976 | 1012 |
| kernel_process_monitor_ps | 8392 | 564 |
| scheduled_process_diagnostic_copy | 8288 | 656 |
| kernel_process_monitor_proc | 8484 | 884 |
| scheduled_process_diagnostic_snapshot | 8328 | 760 |
| VirtioUsed_virtio_used_peek | 1704 | 280 |
| virtio_used_snapshot | 1704 | 408 |
| virtio_net_used | 1040 | 128 |
| net_rx_acquire | 1312 | 548 |
| ddb_stack_process | 584 | 240 |

Eight functions grew by 12 to 68 B each (about 430 B total), for example
kernel_net_rx_frame_pending 112 -> 180: a result bound by `let ... else`
and read for one field is now copied whole by memcpy.inline, which LLVM
does not shorten, where the per-leaf store let it drop the unused leaves.

Functions with a run of 16 or more consecutive byte stores
(`buildcheck_kernel_byte_copy.py`): 10 -> 0 qemu, 8 -> 0 rpi5.
The same-operand csel count is unchanged (6 qemu, 10 rpi5) and the QEMU
main.o compile used 79% of its allocation budget.
