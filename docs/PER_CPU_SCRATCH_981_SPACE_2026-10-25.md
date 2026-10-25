# Space: #981 process_image target root as a parameter, process claim per_cpu (2026-10-25)

Measured with `python3 scripts/space_delta.py origin/main` (base aab3d783),
both production kernels linked in the working tree and at the base.

| | qemu base | qemu change | rpi5 base | rpi5 change |
| text | 680464 | 679924 | 734368 | 734004 |
| data | 4896 | 4880 | 2889752 | 2889736 |
| bss | 1485520 | 1485344 | 1690736 | 1690736 |
| usable_ram_start | 0x40218000 | 0x40218000 | 0x718000 | 0x718000 |

Data/BSS symbols changed (both platforms):

- process_image_contexts 128 -> removed (the per-CPU target root).
- process_image_root_unset_count 32 -> removed (no unset state remains).
- kernel_process_claimed_pid 32 -> kernel_process_claim 32 (same bytes,
  now a `struct per_cpu` store).

Assessment: text -540 B qemu, -364 B rpi5; 160 B of per-CPU storage gone;
the rpi5 BSS is absorbed by alignment. The explicit root parameter costs
nothing measurable: the removed per-CPU loads outweigh the added argument.
No pool, page reservation or image span moved. Adopted.
