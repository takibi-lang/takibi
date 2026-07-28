# Takibi kernel

This is the standalone Linux-compatible kernel tree from GitHub issue #177.
It is not an example and must not depend on files below `examples/`.

The first maintained platform is Raspberry Pi 5. TF-A hands control to a
small AArch64 EL2 boot shim; the monolithic kernel then runs at EL1 and user
processes run at EL0. Ordinary kernel services do not use EL2 HVC calls.

Build targets:

```text
make kernelbuild-rpi5  build the RPi5 kernel
make kernelcheck-rpi5  build and integration-test the RPi5 kernel
make kernelbuild       build every maintained kernel target
make kernelcheck       build and integration-test every maintained target
```

`kernelcheck-rpi5` requires the Raspberry Pi Debug Probe, the project UART
cable, and the resident RPi5 JTAG stub, just like the examples hardware lane.
A build-only result is never reported as an RPi5 integration pass.

The RPi5 runner captures UART once per kernel boot, then projects that one
transcript through every `kernel/tests/rpi5/views/*.filter`. Each projection
is compared exactly with the same-named `.expected` file. This lets boot,
process, VM, syscall, filesystem, and networking contracts grow independently
without paying for a separate hardware reboot for every viewpoint.

Kernel UART output is classified at its call site. `kernel_boot_log` is for
stable operator-visible boot/status messages. `kernel_debug_log` is temporary
bring-up instrumentation and is intended to disappear from the kernel tree
after userspace `write` can carry integration evidence.

All new Takibi sources in this tree are compiled with `--forbid-trap` from
their first commit. Fallible internal operations return variants; conversion
to Linux `-errno` values happens only at the syscall boundary. Process,
address-space, page, mapping, file, and DMA lifetimes retain explicit
affine/linear ownership.

## Initial milestones

1. Boot through a minimal EL2 shim and enter the kernel once at EL1.
2. Install complete fail-stop exception vectors that retain fault evidence.
3. Create one typed process and address space with separate RX text and
   RW+XN data/stack pages.
4. Run one EL0 program through correct AArch64 Linux `write` and `exit`
   syscall boundaries, then reclaim every linear resource.
5. Run a distribution-provided static BusyBox from an initramfs.
6. Mount and mutate a reproducible RAM-backed ext2 image before connecting
   the same block interface to RPi5 USB Mass Storage.
