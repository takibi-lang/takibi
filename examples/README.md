# Examples maintenance policy

The examples are executable language and hardware proofs. They are reference
material for the top-level `kernel/` project, not the directory in which the
Linux-compatible kernel will be grown.

Maintenance priority is:

1. Raspberry Pi 5: primary real-hardware reference. Fix correctness defects
   and keep the hardware suites healthy.
2. QEMU/AArch64: deterministic compiler and integration-test reference. Keep
   `make qemutest` healthy and use it for behavior that does not require RPi5
   peripherals.
3. STM32F746G-DISCOVERY: compatibility maintenance. Existing examples must
   continue to build and run, but no new features or ports are planned.
4. Raspberry Pi 3B: legacy reference outside the freshness policy. It may be
   kept buildable when a shared change makes that inexpensive, but it must not
   constrain RPi5 or kernel design.

Architecture-neutral AArch64 payloads shared by legacy RPi3 and maintained
RPi5 examples live in `common_aarch64/`. Platform HAL and assembly remain in
their target-specific `common_*` directories.

Production kernel direction is tracked by GitHub issue #177: begin with a
standalone RPi5 EL1 kernel under top-level `kernel/`, then add QEMU/AArch64 and
QEMU/RISC-V ports after the RPi5 design has settled. Do not create target
abstractions before a second kernel target actually needs them.
