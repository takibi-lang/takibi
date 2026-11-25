# Secondary bootstrap handoff space

The matched normal QEMU and Raspberry Pi 5 ELFs use `598ff7a94` as
the baseline. The workload is the primary MMU bootstrap and the three
secondary startups through the existing entry paths.

| Linked-image boundary | QEMU baseline | QEMU handoff | RPi5 baseline | RPi5 handoff |
|---|---:|---:|---:|---:|
| Text, read-only data and unwind data (bytes) | 847676 | 847676 | 4242116 | 4242148 |
| Initialized writable data and GOT (bytes) | 4624 | 4624 | 5600 | 5600 |
| BSS and stack sections (bytes) | 1310720 | 1310720 | 1892352 | 1892352 |
| Usable RAM start | 0x40218000 | 0x40218000 | 0x7e0000 | 0x7e0000 |

The static boot root storage grows from 40 to 56 bytes. The new
offset-zero, 16-byte-aligned handoff contains two eight-byte words, the
physical L1 and the reserved boot ASID. Runtime backing starts at byte
16. No page allocation or permanent reservation changes.

The primary writes the handoff after initializing the tables and before
activating its MMU. The boot publication leaf completes the stores with
a system barrier. On RPi5's EL1 debugger reload, it first cleans both
word addresses to the point of coherency because the incoming cache state
can remain enabled. Cold entry skips those cache cleans. Normal and warm
secondary entry then use the same two-word load, independent of the
runtime backing.

Linked inspection covered the primary write and order, same-address
secondary load, RPi5 warm-flag branch, both data-cache cleans, and the
system barrier on both paths. QEMU exercises normal SMP and does not
establish physical cache visibility. Remeasure when the handoff layout,
publication path, or image reservation changes.

The same handoff was also measured with serialized protocol reporting.
Against the report-only build, QEMU's text class remains 848612 bytes
and RPi5's rises from 4243124 to 4243156 bytes. The only writable
symbol size change is the same additional 16-byte handoff. Neither
usable RAM start moves. On RPi5 the stacked handoff starts at
0x6c45c0, the linked boundary at which the old report build's
secondary had read an unpublished runtime backing.

The replay on `22fa7c2f5` reproduced the measured paired normal
QEMU and RPi5 ELFs and packed filesystem byte for byte. The standard
physical path's evidence applies to those unchanged image inputs.
The separate live-image warm loader remains an independent recovery
path that is not established by standard reset validation.
