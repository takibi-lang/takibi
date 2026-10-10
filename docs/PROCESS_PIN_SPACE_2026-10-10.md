# Process placement pin: space (2026-10-10)

Unit: GitHub issue #686 kernel migration. ProcessRecord gains
`private pin: Place(ProcessPin[self]) guarded_by(scheduled_process_run_lock)`;
ProcessPin is an erased linear view, so the place is its tag alone.

## Payload

`--emit-struct-layout ProcessRecord` (QEMU): size 1832 bytes before and
after; `pin` at offset 1768, in existing padding after `affinity_mask`.

## Linked kernels

`python3 scripts/space_delta.py 9a9788c6` (base 9a9788c6):

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 727520 | 727936 | 740272 | 740720 |
| data | 5400 | 5400 | 2889208 | 2889208 |
| bss | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40250000 | 0x718000 | 0x718000 |

No data or BSS symbol changed size.

## Assessment

Code grows 416 B (QEMU) / 448 B (RPi5): the pin and release functions,
the place_is_full check in the affinity writer, and the callers' new
match. On QEMU that growth crosses a 32 KiB boundary, so the allocator
starts 8 pages later (the FDT lane expectations moved by -8 pages). No
allocation workload changes. Accepted.
