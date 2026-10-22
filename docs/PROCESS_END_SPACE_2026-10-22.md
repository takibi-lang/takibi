# ProcessEnd variant space (GitHub issue #886, 2026-10-22)

A process's recorded end went from one usize (an exit code, or a signal
with SYSCALL_STATUS_SIGNALED set) to `variant ProcessEnd { Exited(u8);
Signaled(u8); }`. Measured with `python3 scripts/space_delta.py` against
origin/main a9fbe8b8; the later rebase onto 7417d906 brought only #892's EL0
test payload, which is not linked into kernel.elf.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 736256 | 737080 | 790112 | 791032 |
| data | 4760 | 4760 | 2889608 | 2889608 |
| bss | 1481520 | 1481520 | 1686512 | 1686512 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

Data/BSS symbols changed: `init_boot_fixture_status` 8 -> 4 B on both
(it now holds a ProcessEndWord). ProcessRecord is unchanged in size:
`exit_status` and `sigchld_status` are 8 B either way (i32 tag, two u8
payloads). TakenSignal's `child_status` went 8 -> 4 B. No pool, page or
stack reservation moved.

## Text attribution (qemu, llvm-nm function sizes, +624 B of +824 B; the rest is alignment)

| function | delta B |
|---|---|
| taken_signal_new | +84 |
| kernel_process_reap_zombie | +52 |
| kernel_syscall_exit_current_process | +44 |
| kernel_process_fanout_probe | +44 |
| process_end_word (new) | +36 |
| process_end_exited / process_end_signaled / process_end_of_word (new) | +28 each |
| syscall_signal_frame_write | +28 |
| syscall_status_signaled (removed) | -28 |
| process_end_trace_aux (new) | +24 |
| kernel_process_signal_child_exit, kernel_process_current_termination_signal_take | +24 each |
| 20 other functions | +4 .. +20 each |

The spread is the variant passed by value: each copy loads and stores the
tag and both one-byte payload fields, and each match carries the redundant
csel of #893. A compact variant ABI or #893's fix would recover most of it;
neither is a kernel change.

Assessment: +824 B (qemu) / +920 B (rpi5) text, no data, BSS or layout
change, for a compile-time exclusion of #882's defect class. Adopted pending
the maintainer's view of the text cost.
