# Kernel assembly-entry inventory space review

The combined kernel build check uses existing source signatures for 166
maintained files and scans the remaining 48 files for source names.
Its operand scan and standalone debug return ABI exclusion are unchanged.
The two-target check and source-only preflight each find 21 assembly entries.

Both normal objects and linked ELFs are byte-identical to the
same toolchain's builds from `767e19d51`.

| Target | Artifact | SHA-256 of both revisions |
| --- | --- | --- |
| QEMU | main.o | 14336c95b7a0dd65ae9d14be65cf22eb3f25f7817143b888172a1a9982ba7d2b |
| QEMU | kernel.elf | ed61387007bf9b6c11e8bedcc4357d5eff1e66dff0c3f83e8906e68639a71abf |
| RPI5 | main.o | 3c406a9a7ab7381aec0db0aa0ac978063220de5d9629e14e0b93526437763055 |
| RPI5 | kernel.elf | cf018e88b0ff1226cef1225665590c7c70000518b23d17172357f5aa8acd35e7 |

The memory-map check preserves both usable RAM starts and five allocator
expectations. The measurement covers linked size and reservation.
Remeasure if kernel code, link inputs, or the entry inventory changes.
