# Result-slot forwarding and short copies: space (2026-10-24)

GitHub issue #964. Workload: both production kernels, built by
`scripts/space_delta.py origin/main` (base 515a576f, with #962/#963)
against the branch that

- replaces a local holding only a copy of (part of) an sret result slot by
  the address of that part (also a written local the slot only
  initializes, and a payload bound out of a forwarded local), and
- cuts a constant-length copy into a local to the bytes the local is read at.

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 666768 | 665968 | 720312 | 719808 |
| data | 4792 | 4792 | 2889640 | 2889640 |
| bss | 1481856 | 1481856 | 1690736 | 1690736 |
| usable_ram_start | 0x40210000 | 0x40210000 | 0x710000 | 0x710000 |

No data or BSS symbol changed size. Text: -800 B qemu, -504 B rpi5.

## The functions #962 grew (bytes: before #962 d6290064, #962, now)

| function | qemu | rpi5 |
|---|---|---|
| crash_snapshot_shared_stopped | 604, 652, 592 | 620, 652, 620 |
| ddb_render_backtrace_process | 516, 572, 516 | 516, 572, 516 |
| distro_elf_validate_with_length | 680, 692, 652 | 672, 704, 664 |
| kernel_ddb_enter_stopped | 2544, 2588, 2544 | 2532, 2592, 2560 |
| kernel_net_rx_frame_pending | 112, 180, 112 | - |
| kernel_process_crash_frame_usable | 280, 332, 280 | 276, 328, 276 |
| virtio_net_tx_used_pending | 76, 148, 76 | - |
| virtio_used_go | 344, 368, 340 | 344, 368, 340 |

The #962 growth (376 B qemu, 256 B rpi5) is gone on qemu; on rpi5
kernel_ddb_enter_stopped stays 28 B over, of which 20 B are loop-alignment
nops and 8 B a 32-byte copy done with unaligned ldur/stur. Also smaller:
kernel_process_monitor_proc 884 -> 612 (qemu), net_rx_acquire 548 -> 512,
virtio_used_snapshot 408 -> 392.

Byte-copy runs stay 0 on both kernels, the same-operand csel count stays at
its ceiling (6 qemu, 10 rpi5), and the QEMU main.o compile used 79% of its
allocation budget.
