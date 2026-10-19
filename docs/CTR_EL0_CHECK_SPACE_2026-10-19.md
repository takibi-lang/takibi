# CTR_EL0 boot check space review (GitHub issue #759), 2026-10-19

Change: every core reads CTR_EL0 at bring-up through the one-instruction
helper `cache_geometry_read_ctr_el0` (kernel/arch/arm64/kernel/cache_geometry.S,
no compiler intrinsic) and halts with one log line unless DminLine and CWG
fit DMA_CACHE_LINE. Silent on success.

Measured with `python3 scripts/space_delta.py` against origin/main b3d826ba (after #811 and #833):

| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 721624 | 722416 | 774364 | 775100 |
| data | 4744 | 4744 | 2889576 | 2889576 |
| bss | 1510352 | 1510352 | 1717408 | 1717408 |
| usable_ram_start | 0x40228000 | 0x40228000 | 0x728000 | 0x728000 |

No data/BSS symbol changed size. Text grows 792 B (qemu) / 736 B (rpi5),
nearly all of it the failure path's log strings and calls; the success path
is one call, one mrs and a few shifts per core. Accepted: the check replaces
a trusted assumption of the DMA lowering.
