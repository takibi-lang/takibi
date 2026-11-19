# Frame API fact migration space review

The frame API ratchet reads compiler source signature inventories,
including functions with no compiled generic instance. On the measured
tree it checks the same seven reviewed raw exports and 15 mint files.
The application still uses the original visibility and raw-return rules.

Both normal production kernel objects and linked ELFs are byte-identical
to the same toolchain's builds from `1c2fde3ea`.

| Target | Artifact | SHA-256 of both revisions |
| --- | --- | --- |
| QEMU | main.o | 14336c95b7a0dd65ae9d14be65cf22eb3f25f7817143b888172a1a9982ba7d2b |
| QEMU | kernel.elf | ed61387007bf9b6c11e8bedcc4357d5eff1e66dff0c3f83e8906e68639a71abf |
| RPi5 | main.o | 610354c06cf1bf9be863969582c84d3ff5d342482c668b9e3eed13835ca2443a |
| RPi5 | kernel.elf | bddc611dd5638cecc8f4471cf84bc7e4bfd3dbd5438a76442fbd6123b51add6d |

The memory-map check preserves both usable RAM starts and five allocator
expectations. The generated normal inventories occupy 250696 bytes on
QEMU and 268647 bytes on RPi5. The QEMU compiler allocated 802017888
words on the base and 804391147 with the added fact, within its existing
budget. These are build costs.

`make allbuild` passed in the migration, including the two-target frame
API check. A compiler control with an uninstantiated generic raw return
appeared in the source inventory and was omitted from the resolved call
graph. The frame gate rejected that added signature. Remeasure when the
fact generation affects kernel code or the frame capabilities change
their storage workload.
