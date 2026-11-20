# PMU sample authority

The PMU overflow handler reads MPIDR once. It stops sampling on an
offline or out-of-bounds CPU before passing that same bounded value
to the sample-only authority constructor. The constructor is inlined.
It changes no preempt count and does not read TPIDR. The interrupt
source clears and rearms the PMU as before. Resolved caller checks
confine the constructor to this handler and the handler to each
platform's PMU IRQ clear path. The physical IRQ and nested stop
premises are recorded in TRUSTED_BASE.md.

Per-CPU sample writes take CpuHere. Reset and report use the complete
world-stop authority already held by the workload. The sample record
layout, capacity, workload and format stay fixed.

## Linked comparison

Normal kernels were compared with fcc42eb95. Sizes are in bytes.

| Boundary | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Text | 834416 | 834484 | 4227460 | 4227520 |
| Data | 4624 | 4624 | 5600 | 5600 |
| BSS | 1310720 | 1310720 | 1908736 | 1908736 |
| Usable RAM start | 0x40210000 | 0x40210000 | 0x7e0000 | 0x7e0000 |
| Sample array | 32832 | 32832 | 32832 | 32832 |

The disassembled sample IRQ, store and report instruction sequences
are identical after resolving branch targets to symbol names. The IRQ
and store symbol sizes remain 188 and 76 bytes. Start grows by three
instructions (12 bytes) on each target. The IRQ, store, start and
report frames remain 48, 16, 48 and 112 bytes on both targets.
These are static instruction and frame observations. IRQ latency
was not measured.

One separate normal main-object compilation per target and source
revision used the same target flags and distinct output paths.

| Measure | QEMU before | QEMU after | RPi5 before | RPi5 after |
| --- | ---: | ---: | ---: | ---: |
| Wall time (s) | 12.76 | 12.29 | 13.46 | 13.15 |
| CPU time (s) | 12.62 | 12.27 | 13.43 | 13.13 |
| Peak RSS (KiB) | 548064 | 552048 | 607152 | 607788 |
| OCaml allocation words | 814734767 | 815564310 | 908870996 | 909799785 |

Each row contains one sample per build. The measurements do not
establish a timing improvement.
