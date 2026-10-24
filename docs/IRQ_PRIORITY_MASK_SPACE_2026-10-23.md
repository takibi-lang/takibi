# IRQ priority mask (GitHub issue #920) -- space and cost, 2026-10-23

Workload: linked production kernels, qemu and rpi5, measured with
`python3 scripts/space_delta.py origin/main` (base a17c1028, re-measured 2026-10-24) against the
#920 branch: the GICv2 priority-mask pseudo-NMI, two stop SGIs, the
escalating debug stop, and the lock-free DDB/crash side.

| | qemu base | qemu change | rpi5 base | rpi5 change |
| --- | --- | --- | --- | --- |
| text | 670596 | 673392 | 724420 | 727376 |
| data | 4832 | 4848 | 2889680 | 2889696 |
| bss | 1482416 | 1482480 | 1690736 | 1690736 |
| usable_ram_start | 0x40210000 | 0x40210000 | 0x710000 | 0x718000 |

Data/BSS symbols added: `irq_pmr_masked` and `irq_pmr_ready`, 32 B each
(one word per core, KERNEL_MAX_CORES = 4) on both targets. No record, pool
or linker change; rpi5 BSS unchanged (absorbed by alignment), but the rpi5 image end crosses one 32 KiB reservation step (usable_ram_start +0x8000, 8 allocator pages).

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

## Whole-suite time on RPi5 (2026-10-24)

`make kernelcheck-rpi5`, board otherwise idle, alternating trees after warm
kernelbuilds: main a17c1028 212.2 s (first run, which also builds the debug
images and fixtures kernelbuild leaves) and 147.6 s; branch 275.3 s (first
run, same extra build) and 135.9 s; main again 135.8 s. Steady state is
equal; the first run after a build is slower on both trees for its build
steps. One main run failed (ARP integration, a DDB break) and is not counted.
