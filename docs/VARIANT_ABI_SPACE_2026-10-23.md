# Shared-payload variant calls: space (2026-10-23)

GitHub issue #897. Workload: both production kernels, built by
`scripts/space_delta.py origin/main` (base 3b06f12b) against the branch
that passes a variant with two or more scalar payload cases between Takibi
functions as `{ i32 tag, payload }` instead of one register per case.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 738576 | 737920 | 792528 | 792064 |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481840 | 1481840 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

No data or BSS symbol changed size.

## What the issue assumed, and what was measured

The issue attributed #886's +824 B (QEMU) to copying ProcessEnd through
stack memory. The disassembly showed no memory copy: LLVM already passed the
`{ i32, i8, i8 }` aggregate in registers, one per field, so ProcessEnd took
three registers (w0 tag, w1 Exited, w2 Signaled) and callers kept three
values alive across calls. #886's growth, per text symbol, was the new
helper functions (about 170 B) plus a few instructions in each caller that
moves or saves the extra registers.

Two conventions were tried:

1. The memory image packed into i64 words (ProcessEnd in one register).
   Net +296 B QEMU text: every inactive payload field had to be frozen and
   OR-ed into the word, and two-field variants paid shifts they did not pay
   before. Rejected.
2. Tag plus the active payload (adopted). Packing selects the payload by
   tag; at a constructor the tag is constant and the select folds, and a
   pass-through packs back to the register it arrived in. QEMU text -656 B,
   RPi5 -464 B. The gain is wider than ProcessEnd: the syscall action and
   I/O result variants shrink too (kernel_syscall_dispatch_action -116 B,
   each syscall_* wrapper 8-44 B). A few callers that build a variant from
   a stored one grow by 4-28 B (terminal_echo +28) from the select.

The in-memory layout is unchanged, so no data, BSS or pool size moves.
