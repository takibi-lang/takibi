# Process state with its wait as a payload: space (2026-10-10)

Unit: GitHub issue #653. ProcessRecord's `state` enum and its wait cell
become one private variant (`Blocked(reason)`, `ReadyWait4(child)`,
`Resuming(child)` carry what the two fields carried). The compiler's
struct and variant layouts are registered in dependency order (no layout
change for any existing type).

## Payload

`--emit-struct-layout ProcessRecord` (QEMU target), before and after:
size 1832 bytes in both; `state` at offset 560 in both; every later field
at the same offset (`pending_block_reason` 584, `pending_signals` 608,
`clone_file_state` 1754). The separate `wait` member is gone (44 -> 43
members). The process pool's per-slot payload is unchanged.

## Linked kernels

`python3 scripts/space_delta.py 132a74ec` against the working tree:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 726920 | 727664 | 739608 | 740368 |
| data | 5400 | 5400 | 2889208 | 2889208 |
| bss | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data or BSS symbol changed size.

## Assessment

Code grows 744 bytes (QEMU) and 760 bytes (RPi5): the reads now match a
variant tag through process_state_kind and process_wait_reason where they
compared a byte, and the transitions match the previous state. The image
span and page reservations are unchanged, and no allocation workload
changes, so no pool measurement is needed. Accepted: the growth buys the
removal of a state that the type could represent and the kernel had to
refuse at run time.
