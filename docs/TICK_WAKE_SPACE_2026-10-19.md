# Per-CPU tick-wake lists: space review (2026-10-19)

GitHub issue #829. A process blocked on a deadline or a NetRx retry is queued
on an intrusive list of the core it blocked on, threaded through two new
`ProcessRecord` words (`tick_wake_core`, `tick_wake_next`); each core keeps a
list head and an earliest-due word. The boot gains `/bin/peer-sleep`, an EL0
fixture, and three small workload words.

Measured with `python3 scripts/space_delta.py origin/main` (base 578e1b1a,
change at the #829 branch head):

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 722976 | 725072 | 775660 | 777788 |
| data | 4744 | 4784 | 2889576 | 2889616 |
| bss | 1510368 | 1510496 | 1717408 | 1717424 |
| usable_ram_start | 0x40228000 | 0x40228000 | 0x728000 | 0x728000 |

Data/BSS symbols that changed size, both targets alike:

- `kernel_process_tick_wake_head` and `kernel_process_tick_wake_due`: new,
  32 B each (one word per core, `KERNEL_MAX_CORES` = 4).
- `scheduled_process_boot_record`, `scheduled_process_record_absent`,
  `signal_probe_record`: 1912 -> 1928 B, the two list words in every
  `ProcessRecord`.
- `workload_peer_sleep_pid` (8 B), `workload_peer_sleep_done` and
  `workload_peer_sleep_finished` (1 B each): the fixture's state.

Accounting boundaries:

- Image: +2.1 KiB text per target (the list operations, the per-core walk,
  the fixture's syscall arm); data and BSS +40/+128 B (qemu) and +40/+16 B
  (rpi5, where alignment absorbs most of the BSS words);
  `usable_ram_start` unchanged, so no allocator page moves.
- Pool payload: every pooled `ProcessRecord` grows by 16 B (0.8 %). A record
  is a RegionPool slot, so this scales with live processes, about 0.4 KiB at
  the 24-process table probe's peak. The alternative of a static array per
  slot is not available: process slots are pool addresses with no fixed
  count, so per-record links are the only storage bounded by the records
  that exist.
- Retained pages and workload occupancy: unchanged; nothing is allocated to
  queue or wake.

Assessment: accepted. The cost is two words per process and two per core
for removing core 0 as every sleeper's only waker. Singly linked rather than
doubly linked saves the third word; unlink walks one core's list, which holds
that core's sleepers only.
