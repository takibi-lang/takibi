# IRQ priority mask (GitHub issue #920) -- space and cost, 2026-10-23

Workload: linked production kernels, qemu and rpi5, measured with
`python3 scripts/space_delta.py origin/main` (base 237595ac) against the
#920 branch: the GICv2 priority-mask pseudo-NMI, two stop SGIs, the
escalating debug stop, and the lock-free DDB/crash side.

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 737168 | 739964 | 789160 | 792116 |
| data | 4792 | 4808 | 2889640 | 2889656 |
| bss | 1481856 | 1481920 | 1690736 | 1690736 |
| usable_ram_start | 0x40220000 | 0x40220000 | 0x720000 | 0x720000 |

Data/BSS symbols added: `irq_pmr_masked` and `irq_pmr_ready`, 32 B each
(one word per core, KERNEL_MAX_CORES = 4) on both targets. No record, pool
or linker change; rpi5 BSS unchanged (absorbed by alignment).

Text grows by +2796 B (qemu) and +2956 B (rpi5): the PMR mask functions,
the nested-dispatch wrapper in both dispatchers, the second stop branch and
the escalation, the try-lock paths of the debug side, and the boot-time
`irq mask cost:` probe.

## Time cost on RPi5 (kernelcheck-rpi5, 2026-10-23)

`irq mask cost:` lines, 4096 save/restore pairs each, 54 MHz counter, seven
samples (all within one tick of each other):

- `pmr` (mutex_irq_save/restore, GIC priority mask): 5886 ticks, 26.6 ns
  per pair.
- `daif` (the pre-#920 DAIF.I pair, same irqsoff hooks): 1478 ticks,
  6.7 ns per pair.

Difference: about +20 ns per lock acquire/release pair. The same boot's
uncontended pool lock/unlock (`tcp pool cost` serial `lock=`) is 17067 to
23908 ticks per 4096, 77 to 108 ns per pair, so the mask is now roughly a
quarter of an uncontended lock pair, from about a twentieth.
