# Space review: readonly slices and user-memory store results (2026-10-09)

Units: #724 (readonly slice permission, compiler only) and #725 (must_use
`UserWriteResult` for stores into validated user ranges, the CoW read probe
and its fault-injection lane).

## Measurement

`python3 scripts/space_delta.py origin/main` at base 514116a1, both
production kernels built in the working tree and at the base:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 721748 | 724284 | 731372 | 734036 |
| data | 5078 | 5078 | 2888784 | 2888784 |
| bss | 1658608 | 1658608 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data or BSS symbol changed size.

## Assessment

- Text grows 2536 bytes (QEMU) and 2664 bytes (RPi5): the failure arms
  every caller now matches, `user_write_join`, and the boot-suite CoW read
  probe. The page reservation boundary (`usable_ram_start`) does not move.
- Readonly slices are erased at code generation; they add no storage.
- No resource payload, pool metadata, allocation policy or steady-state
  lifetime changes. The probe takes one user page, one sibling address space
  and one fd for the duration of the boot probe and gives them back; the
  alloc-rollback lane's `resources: pages=0` and pooled-record baseline
  lines confirm it under the injected failure as well.
- Adopted as is: the growth buys a handled failure on every user-memory
  store, which is the point of #725. No cheaper representation was
  identified.
