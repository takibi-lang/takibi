# Crash trace word protection space review

Normal linked kernels compared with 16a659b5e. The trace keeps the same
per-CPU slots, record fields, sequence order and caller-visible output.

| Boundary | QEMU baseline to candidate | RPi5 baseline to candidate |
| --- | --- | --- |
| Text | 832044 to 832252 B | 4225608 to 4225800 B |
| Data | 4616 to 4624 B | 5592 to 5600 B |
| BSS | 1310720 B unchanged | 1908736 B unchanged |
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

## RPi5 trace cost

On the same board and shell ELF (SHA-256
`955c9dc58c1201b1cac282ee2821306a1ef47e0b80431b42265fafb134537cd0`),
four fresh runs used the maintained 100-round churn workload without
trace filters. DDB confirmed live state before and after each run.
The elapsed host monotonic interval spans the shell command through
its completion verdict and excludes boot and debugger setup.

| Run | Trace | Seconds | Latest sequence before / after |
| --- | --- | ---: | ---: |
| 1 | Off | 11.221 | 0 / 0 |
| 2 | On | 11.267 | 0 / 8757 |
| 3 | On | 11.317 | 0 / 8609 |
| 4 | Off | 11.211 | 0 / 0 |

The matching on arms took about 46 and 107 ms longer, respectively
(0.41% and 0.95%). All 400 rounds returned the expected verdict.
Two pairs estimate the effect on this complete workload. The timing
includes shell and serial delivery and does not isolate per-event CPU
cycles. The sequence is a snapshot witness, not an event count.
