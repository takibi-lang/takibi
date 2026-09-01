# DWARF and QEMU gdbstub

`-g` emits DWARF intended for real `gdb-multiarch` sessions. Use
`make kernelcheck-qemu-debug` for the maintained full-kernel regression; it
builds `kernel-debug.elf` and runs the debug QEMU lanes on ports and artifacts
separate from the ordinary lane.

Use `gdb-multiarch`, not the host's stock x86_64 `gdb`: stock GDB cannot parse
QEMU's AArch64 target description in this environment.

When bisecting a debug-info regression, identify the smallest observable
mapping that changed, such as the source line associated with an address after
a breakpoint. Rebuilding the compiler and querying that mapping is usually
faster and less perturbing than reproducing the full interactive failure at
every candidate commit.

For PC sampling and hot-spot measurement, use `profile-qemu`. Do not interpret
an almost entirely idle result from network or interrupt-driven code as a
useful CPU profile.
