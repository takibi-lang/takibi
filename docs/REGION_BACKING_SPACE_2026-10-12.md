# Region backing globals: space review (2026-10-12)

Change: `region let mut g: [T; N];` marks a region's source array, and the
compiler refuses every use of that name besides its claim (#637, #720). The
kernel change is two declarations in kernel/mm/page.tkb; the check emits no
code.

Measured with `python3 scripts/space_delta.py main` (main 3d12b7ad, linked
production kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 698536 | 698536 | 711640 | 711640 |
| data | 5328 | 5328 | 2889192 | 2889192 |
| bss | 1660272 | 1660272 | 1696880 | 1696880 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x710000 | 0x710000 |

No data/BSS symbol changed size. No allocation behavior changed, so no
pool workload was rerun.
