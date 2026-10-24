# Lifecycle trace signal/wait4 events and DDB filters: space (2026-10-24)

GitHub issue #652. Measured with `scripts/space_delta.py origin/main`
(origin/main 515a576f) on the linked production kernels.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 666768 | 669968 (+3200) | 720312 | 723480 (+3168) |
| data | 4792 | 4816 (+24) | 2889640 | 2889664 (+24) |
| bss | 1481856 | 1481888 (+32) | 1690736 | 1690736 |
| usable_ram_start | 0x40210000 | 0x40210000 | 0x710000 | 0x710000 |

Data/BSS symbols added: `kernel_process_trace_omit_events` (8 B),
`kernel_process_trace_omit_pid` (8 B), `kernel_process_trace_omit_pid_set`
(1 B), on both targets. No pool, record or allocation change.

Ring size is unchanged (16 records per CPU, 16 in the snapshot). The issue
named the ring size as a limit; with event 10 and HTTPd's pid filtered out,
the race-window 633 hang capture held the last child's exit, its SIGCHLD,
the take into ash's handler, its reap and wait4's returned pid within the 16
records, so growing CrashSnapshot/DdbSnapshot (1.5 KiB each) and the per-CPU
storage (6 KiB more for 32 records) was not needed.

Text: three trace helpers, the DDB `trace` sub-command parser and printer,
and the call sites (signal raise and discard, handler entry, every wait4
return). Hot-path cost with the trace off: one load and branch per signal
raise, handler entry and wait4 return; the filter words are read only after
the enabled check.
