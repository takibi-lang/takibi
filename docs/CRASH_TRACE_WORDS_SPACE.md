# Crash trace word protection space review

Normal linked kernels compared with ddf96089. The trace keeps the same
per-CPU slots, record fields, sequence order and caller-visible output.

| Boundary | QEMU baseline to candidate | RPi5 baseline to candidate |
| --- | --- | --- |
| Text | 827848 to 828056 B | 4221044 to 4221236 B |
| Data | 4608 to 4616 B | 5584 to 5592 B |
| BSS | 1310720 B unchanged | 1916928 B unchanged |
| Trace buffer and next counters | 6144 and 32 B unchanged | 6144 and 32 B unchanged |
| Reset generation | adds 8 B | adds 8 B |
| usable_ram_start | 0x40210000 unchanged | 0x7e0000 unchanged |

Both production objects retain 128/16/16-byte static frames for record,
copy and reset, respectively. A recorded event has fourteen release
stores and a slot-counter acquire load in addition to the existing
global sequence fetch-add and early trace policy loads. The disabled
path returns before the record stores. A snapshot uses acquire loads and
skips a slot changed during copying; a reset crossing discards the
snapshot. The AArch64 litmus projection forbids reading newer payload
and then validating the old commit. Relaxing either payload access
admits that outcome. The model interleaves protocol steps separately.

The reset runs in the existing boot fixture sequence, serialized with
normal writers. No repeated snapshot or retry is added. The measurements
cover fixed linked space and static frames. Trace-on/off elapsed costs
still require measurements on Raspberry Pi 5.
