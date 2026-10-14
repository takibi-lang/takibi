# Stack runs keep their permission: space and time review (2026-10-13)

Change (#672 option A): a process's kernel stack run keeps its PageRunOwner
in the process record's `stack` place from adoption to the reap. Stack bytes
are read through it. A boot-end probe records the guard's cost.

## Linked kernels

`python3 scripts/space_delta.py main` (main 21af10a1):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 697376 | 699024 | 736176 | 737848 |
| data | 4736 | 4736 | 2889448 | 2889448 |
| bss | 1513248 | 1513424 | 1700720 | 1700784 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |

- ProcessRecord grows 1856 -> 1912 B: the place holds the owner inline. The
  same growth shows in the three static records (boot, absent, signal
  probe) and in every pooled record.
- Text grows 1648 B (QEMU) and 1672 B (RPi5): the timing probe, the guarded
  place operations and the range checks.
- usable_ram_start is unchanged.

## Guard cost, RPi5

The probe runs at the end of the boot suite on the first process stack
(the bootstrap's): 4096 rounds of the guard's two 64-byte witness reads,
each preceded by the base snapshot the guard takes. 54 MHz counter.

| path | ticks / 4096 | per guard |
|---|---|---|
| through the run's permission (now) | 62396; 58504 on a second run | 15.2 / 14.3 ticks, about 282 / 265 ns |
| integer ranges (the pre-#672 body) | 42734; 42251 | 10.4 / 10.3 ticks, about 193 / 191 ns |

The guard runs once per tick per core. The increase is about 75 to 90 ns
per tick against a 15.6 ms tick, or about 0.0006% of a core. Adopted.

## Re-measured on main 3059d528 (2026-10-14)

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 679768 | 681392 | 727832 | 729392 |
| data | 4632 | 4632 | 2889496 | 2889496 |
| bss | 1509152 | 1509328 | 1696704 | 1696768 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |

- Text grows by 1624 B (QEMU) and 1560 B (RPi5).
- BSS grows by 176 B and 64 B: the three static records at 56 B each, less
  alignment.
- usable_ram_start is unchanged.

With the boot-process guard probe added (2026-10-14), against main 3059d528:
QEMU text 679768 -> 682096 (+2328 B), RPi5 727832 -> 730080 (+2248 B).
The probe accounts for about 700 B of that. Data, BSS and usable_ram_start
are as above.
