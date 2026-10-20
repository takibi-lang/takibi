# PID 1 pooled, boot thread, core 0 idle on its boot stack: space (2026-10-20, #831)

Workload: the maintained QEMU bounded boot and both production kernels,
measured with `scripts/space_delta.py` against origin/main 8ba9354f.

## Linked image

| | qemu base | qemu change | rpi5 base | rpi5 change |
|---|---|---|---|---|
| text | 726992 | 728788 | 780428 | 782368 |
| data | 4688 | 4680 | 2889536 | 2889528 |
| bss | 1512944 | 1478240 | 1719264 | 1686496 |
| usable_ram_start | 0x40228000 | 0x40220000 | 0x728000 | 0x720000 |

Symbols: `scheduled_process_boot_record` (1928 B), `_boot_live`,
`_boot_generation` and the three `core0_idle_stack` symbols go;
`process_image_root0_record` (16 B) and `scheduled_process_boot_handed_off`
(1 B) come. The BSS drop is the static record plus core 0's former 32 KiB
idle stack (now it idles on its boot stack); `usable_ram_start` moves down
0x8000, giving the page allocator 8 more pages on both platforms. Text grows
about 1.8 KiB (PID 1 creation and publication, the boot-thread allocator,
the hand-off, the stack-guard probe on a private record).

## Runtime (QEMU bounded boot)

`ProcessRecord` stays 1928 B: the new `kernel_thread` flag fits the padding
after `core0_for_call`. During the boot fixtures the boot thread holds one
pool record and one fd context, and no stack run, root or image record (it
runs on root 0). After hand-off PID 1 holds what every process holds: one
record, a 32 KiB stack run (the run the probes parked, reused), a root
(two page-table pages and a backing record) and an image record. Against
the static record, PID 1 therefore costs one more root and one more image
record; the static record's never-used stack run is gone.
