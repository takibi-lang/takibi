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

WARNING: `kernelcheck-rpi5` overwrites the first 1 MiB of the USB Mass Storage
device attached to the RPi5 with the generated ext2 fixture. Attach only the
project's dedicated sacrificial test drive. The kernel block adapter exposes
exactly those first 1024 1-KiB blocks, bounding this bring-up milestone's
destructive scope independently of the physical device capacity.

`kernelcheck-rpi5` also requires the RPi5 Ethernet port to have an active
link. The standalone RP1 Cadence GEM driver resets and configures the
BCM54213PE PHY, negotiates the link, initializes its typed RX/TX DMA rings,
and uses the dedicated `02:00:20:00:00:02` test MAC. The host runner uses a
privileged raw socket on `ETH_TEST_IFACE` (default `enp5s0`) to prove that a
request for another address stays unanswered and that an ARP request for
`192.168.20.2` receives the exact reply. The same owned RX path then rejects
an ICMP request for another IP and one with a corrupt checksum before
returning a checksum-correct echo reply. The capability then enters a
single-connection TCP state machine on port 7, covering checksum rejection,
SYN options, handshake, data echo, FIN close, and reconnect. Linux socket
boundaries are a subsequent milestone.

The RPi5 runner captures UART once per kernel boot, then projects that one
transcript through every `kernel/tests/rpi5/views/*.filter`. Each projection
is compared exactly with the same-named `.expected` file. This lets boot,
process, VM, syscall, filesystem, and networking contracts grow independently
without paying for a separate hardware reboot for every viewpoint.

The runner reports reset, SWD load, and execution phases from the host. During
kernel execution it prints elapsed time every five seconds and stops capture
as soon as the stable final resource marker arrives. These progress lines are
not kernel UART diagnostics and are not part of any `.expected` contract.

Kernel UART output is classified at its call site. `kernel_boot_log` is only
for stable operator-visible boot/status messages. Temporary kernel debug UART
logging was removed once a distribution BusyBox could report integration
evidence through the userspace Linux `write` boundary.

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

Milestone 1 now runs on real RPi5 hardware: the typed initial process enters
EL0 with RX text and RW+XN data/stack mappings, observes Linux AArch64
`write(64)` success plus `-EBADF`/`-EFAULT` error returns, exits through
`exit(93)`, and returns to the owning EL1 frame to unmap and free every page.

The next compatibility fixture is generated under `kernel/build/user` from
Alpine v3.24's pinned AArch64 `busybox-static` package. It is wrapped in a
`newc` initramfs and embedded in the kernel without committing the GPL binary.
The kernel validates the archive name/bounds and the real static-PIE ELF load
plan before the larger owned process-image mapping is attempted.

That measured load plan now drives the real `PT_LOAD` mappings plus an owned
initial stack and fixed short-lived heap. Alpine BusyBox runs
`cat /hello.txt` at EL0, opens the USB ext2 file through `openat(56)`, emits it
through `sendfile(71)`, closes it, and exits through syscall 93 with status
zero. All 401 image, heap, and stack pages sit
under one linear `ProcessImagePages` teardown obligation and are returned
before the smaller syscall fixture is created.

The first ext2 slice is also active on RPi5. The build creates a checked 1 MiB
RAM fixture with `mke2fs`, populates it with `e2mkdir`/`e2cp`, and embeds it as
a writable image. The filesystem core reaches it only through the 1 KiB block
interface in `kernel/drivers/block/`. It validates the superblock and group
descriptor, decodes the inode table, walks the root directory, reads and
resizes a regular file, resolves a fast symlink, updates allocation bitmaps
and free counts, and creates and unlinks a root file using typed block/inode
owners. Indirect blocks and multi-group images remain deferred until a
concrete caller requires them.

The same ext2 core now mounts the RPi5's real USB Mass Storage device. The
standalone RP1 xHCI/Bulk-Only/SCSI driver reports 512-byte sectors; the USB
block adapter combines each adjacent sector pair into the filesystem core's
1 KiB block contract. During `kernelcheck-rpi5`, the checked embedded image
is copied into the deliberately bounded first-1-MiB device view, then mounted
and `/hello.txt` is looked up and read back from USB. Linux-compatible
`openat`, `read`, `write`, `sendfile`, and `close` bind one process file
descriptor to this mount; the small EL0 fixture also overwrites
`/mutable.txt` through those syscall boundaries. The adapter intentionally
does not expose the rest of the physical medium yet.
