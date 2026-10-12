# freelist.tkb off the mint list: space review (2026-10-12)

Change: freelist_core_remove and freelist_core_unlink_range index next_free
with checked, locally narrowed indices instead of unsafe unchecked access;
the unused Freelist(T, N) wrapper and freelist_ref are removed (#637).

`python3 scripts/space_delta.py 6dafbb57` (linked production kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 698536 | 698496 | 711640 | 711600 |
| data | 5328 | 5328 | 2889192 | 2889192 |
| bss | 1660272 | 1660272 | 1696880 | 1696880 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

No data/BSS symbol changed size; text is 40 B smaller on both. Allocation
behavior is unchanged (same list operations), so no pool workload was rerun.
kernelcheck-rpi5 passed on this tree.
