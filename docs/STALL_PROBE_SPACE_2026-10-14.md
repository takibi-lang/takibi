# Stall probes (race-window kernels only): space review (2026-10-14)

Change (#665): kernel/kernel/stall_probe.tkb records per-CPU tick, idle and
refusal facts and, for peer-settings' two processes, their block, wake,
start and yield events. It is on only in the race-window overlays
(KERNEL_STALL_PROBES = 1); production and debug kernels have it at 0.

`python3 scripts/space_delta.py main` (main 00c3026d, production kernels):

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 679764 | 679768 | 727828 | 727832 |
| data | 4632 | 4632 | 2889496 | 2889496 |
| bss | 1509152 | 1509152 | 1696704 | 1696704 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x718000 | 0x718000 |

- Text grows by 4 B on both, one instruction's worth of layout. No stall_probe
  symbol is left in either production kernel.
- A first version grew text by 464 B (QEMU) and 496 B (RPi5). The probe
  functions tested the constant inside themselves, so each call site was
  still a real call to a 16-20 B stub. The event hooks were also gated by
  a call (stall_probe_watching), so the pid lookup they guard stayed too.
  Every call site is now inside `if (KERNEL_STALL_PROBES != 0)`. That folds
  at compile time, so the calls and the stubs go and --gc-sections drops
  the probe storage.
- Data, BSS and usable_ram_start are unchanged, and no data or BSS symbol
  changed size.
- Production behaviour is unchanged.
- Adopted.
