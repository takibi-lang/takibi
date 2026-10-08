# Per-signal action table space measurement (2026-10-08)

GitHub issue #629 replaces ProcessRecord's four SIGCHLD action words with an
action for each standard signal 1..31 (handler, flags, restorer, mask: 32
bytes each). Measured with `python3 scripts/space_delta.py origin/main`
(base cf4f650d) on the standard production QEMU and RPi5 linked kernels,
llvm-size-19/llvm-nm-19:

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 717340 | 719052 | 727172 | 728740 |
| data | 5070 | 5070 | 2888776 | 2888776 |
| bss | 1655712 | 1658592 | 1692544 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

Changed data/BSS symbols, on both targets: `scheduled_process_boot_record`,
`scheduled_process_record_absent` and `signal_probe_record` each grow from
872 to 1832 bytes (the record itself: +960 = 31 x 32 - 4 x 8). Neither
image's reserved span moves.

Runtime pool accounting (computed from the record size, not a fresh boot
capture): the process pool's 8192-byte chunk held nine 880-byte slots
(`PROCESS_RECORD_AUTHORITY_SPACE_2026-10-06.md`); at about 1840 bytes a
chunk holds four. A workload with five to eight live processes now needs a
second chunk, one more 8 KiB allocation; per process the record roughly
doubles.

Assessment: adopt. Linux keeps the same table per process (its sighand
holds 64 k_sigactions, about 2 KiB on arm64), and a per-signal action is
what makes the handler correct. The structural alternative -- a separately
allocated table only for a process that installs a non-default action, or
one shared by a fork until written -- is recorded for when a measured
workload shows process-pool pressure; it costs an allocation path and a
failure case in rt_sigaction that this change avoids.
