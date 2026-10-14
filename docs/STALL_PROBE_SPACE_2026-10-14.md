# Stall probes (race-window kernels only): space review (2026-10-14)

Change (#665): kernel/kernel/stall_probe.tkb records per-CPU tick, idle and
refusal facts and, for peer-settings' two processes, their block, wake,
start and yield events. It is on only in the race-window overlays
(KERNEL_STALL_PROBES = 1); production and debug kernels have it at 0.

`python3 scripts/space_delta.py main` (main 00c3026d, production kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 679764 | 680228 | 727828 | 728324 |
| data | 4632 | 4632 | 2889496 | 2889496 |
| bss | 1509152 | 1509152 | 1696704 | 1696704 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |

- Text grows by 464 B (QEMU) and 496 B (RPi5). These are the call sites and
  the disabled early returns, which the compiler keeps even though the
  constant gates them.
- Data, BSS and usable_ram_start are unchanged, and no data or BSS symbol
  changed size: gc-sections drops the probe storage in production.
- Production behaviour is unchanged: every probe function returns at once.
- Adopted.
