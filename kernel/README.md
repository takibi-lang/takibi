# Takibi kernel

`kernel/` is the standalone RPi5-first monolithic kernel written in Takibi.
It is separate from the executable proofs under `examples/` and does not
compile or link source files from that tree.

The kernel implements the Linux AArch64 ABI incrementally from real userspace
callers. It currently runs pinned, existing Alpine Linux binaries at EL0,
including static BusyBox and the dynamically linked BusyBox HTTPd applet. On a
real Raspberry Pi 5, HTTPd serves `index.html` from USB ext2 over RP1 Ethernet
and the development container verifies the response with real `curl`.

## Current architecture

- Raspberry Pi firmware and TF-A hand control to a minimal AArch64 EL2 shim.
- The shim performs required architectural setup and drops once to EL1.
- The monolithic kernel and its drivers run at EL1.
- RPi5 UART RX is dispatched through GIC-400 and RP1 MIP0/MSI-X interrupts;
  Ethernet and USB remain polling-driven.
- Linux-compatible processes run at EL0 with RX text and RW+XN data, heap, and
  stack mappings.
- Ordinary kernel services do not use EL2 HVC as an internal service layer.
- Page, mapping, process, file, socket, frame, and DMA lifetimes retain
  explicit affine or linear ownership.
- Kernel Takibi sources build with `--forbid-trap`; fallible internal
  operations return variants and convert to Linux `-errno` only at the syscall
  boundary.

The EL0 exception frame preserves general-purpose registers, q0-q31, FPSR,
and FPCR across syscalls. Process exit returns to the owning EL1 call frame so
the complete address space can be unmapped and reclaimed.

## Implemented system slices

The current RPi5 kernel includes:

- typed page allocation, AArch64 stage-1 page tables, process images, and
  deterministic teardown;
- ELF64 validation, static PIE loading, interpreter-aware PIE plus musl
  loading, initial Linux stack and auxv construction, `brk`, and bounded
  anonymous `mmap` behavior;
- the Linux AArch64 syscall subset reached by the current BusyBox, file, and
  socket workloads;
- a block-device boundary shared by an in-memory fixture and RPi5 USB Mass
  Storage;
- a bounded ext2 implementation with direct-block small files, root directory
  mutation, allocation bitmaps, and fast symlinks;
- RP1 PCIe, xHCI/USB Mass Storage, Cadence GEM Ethernet, ARP, IPv4, ICMP, and
  a bounded TCP slice with in-order stream reconstruction, short reads,
  partial writes, duplicate/out-of-order acknowledgement, and timed SYN/ACK,
  data, and FIN retransmission;
- an initramfs containing reproducibly pinned Alpine BusyBox, BusyBox Extras,
  and the matching musl interpreter without committing those GPL binaries;
- one-boot integration views that independently compare boot, VM, process,
  syscall, filesystem, USB, Ethernet, BusyBox, and HTTPd evidence.

The current HTTPd milestone runs the unmodified pinned BusyBox Extras binary
as a persistent foreground daemon: `busybox-httpd httpd -f -p 8080 -h /`.
HTTPd creates its own IPv6 wildcard listener, accepts each connection, and
uses the observed `clone(SIGCHLD)` fork shape. Each child receives a private
331-page VM copy and a distinct kernel stack, aliases the accepted socket onto
fd 0/fd 1, reads `index.html` from USB ext2, writes the response, and exits.
The same parent accepts two sequential host `curl` requests before the bounded
integration teardown reclaims every child page, fd, and socket reference. The
host compares both complete 68-byte bodies with the fixture. TCP fixtures also
split a request across segments, inject bounded drops, and exercise short
`read` plus a 1460+1 partial `write` sequence.

## Tree layout

```text
kernel/arch/arm64/       EL2 entry, EL0 transition, exceptions, MMU, timer
kernel/drivers/block/    block-device interfaces and memory adapter
kernel/drivers/net/      RP1 Cadence GEM driver
kernel/fs/ext2/          ext2 implementation
kernel/init/             top-level kernel initialization and integration flow
kernel/kernel/           process and Linux syscall policy
kernel/mm/               pages, address spaces, mappings, and ELF images
kernel/net/              ARP, checksums, IPv4/ICMP/TCP, socket capabilities
kernel/platform/rpi5/    RPi5 PCIe, GIC, UART, xHCI, and platform setup
kernel/tests/            ext2 fixtures and RPi5 expected-file views
kernel/build/            generated images and linked artifacts
```

## Make targets

Run these from the repository root:

```bash
make kernelbuild-rpi5  # build kernel/build/rpi5/kernel.elf
make kernelcheck-rpi5  # build and run the complete RPi5 integration test
make kernelbuild       # build every maintained kernel target
make kernelcheck       # build and test every maintained kernel target
```

At present RPi5 is the only maintained kernel target, so `kernelbuild` and
`kernelcheck` are aliases for their RPi5 counterparts. These aggregate names
are intentionally ready to include future QEMU/AArch64 and QEMU/RISC-V ports
once those ports exist.

`kernelbuild-rpi5` does not require a board. It generates the ext2 and
initramfs fixtures, obtains the pinned Alpine packages, compiles all Takibi
code under `--forbid-trap`, assembles the minimal AArch64 files, and links the
ELF.

## Raspberry Pi 5 hardware integration

### Destructive-test warning

`make kernelcheck-rpi5` overwrites the first 1 MiB of the USB Mass Storage
device attached to the RPi5 with its generated ext2 fixture. Attach only the
project's dedicated sacrificial test drive. The kernel block adapter exposes
only the first 1024 1-KiB blocks, which bounds this test independently of the
physical device's capacity.

### Equipment

- Raspberry Pi 5;
- Raspberry Pi Debug Probe connected to the board's SWD connector;
- Debug Probe UART connected to RP1 UART0 on GPIO14/GPIO15 and ground;
- microSD card containing Raspberry Pi firmware and the resident spin stub;
- dedicated sacrificial USB Mass Storage device;
- Ethernet cable to a dedicated host NIC;
- Linux development host, preferably the repository devcontainer.

The RPi5 three-pin debug connector carries either SWD or UART, not both. The
suite therefore uses SWD on the debug connector and the separate RP1 UART0
GPIO path for simultaneous injection and logs.

### One-time SD-card preparation

The board boots a small spin stub from `kernel_2712.img`; test kernels are then
injected into RAM over SWD. Build and install the stub:

```bash
make examples/common_rpi5/jtag_stub.img
scripts/rpi5_prepare_sdcard.sh /path/to/mounted/boot/partition
```

Run the preparation script where the SD boot partition is mounted, normally
outside the container. It backs up the original `kernel_2712.img` once,
installs the stub, and adds `os_check=0` to `config.txt`.

Power-cycle the RPi5 after changing the SD-card image. PSCI warm reset reliably
reruns an unchanged resident stub but does not reliably reload a different
`kernel_2712.img`.

### Host Ethernet setup

The kernel uses `192.168.20.2/24` and MAC `02:00:20:00:00:02` by default.
Configure the directly connected host NIC:

```bash
sudo ip addr add 192.168.20.1/24 dev <interface>
sudo ip link set <interface> up
```

The runner defaults to `enp5s0`. Select another interface without changing
source:

```bash
ETH_TEST_IFACE=<interface> make kernelcheck-rpi5
```

Host packet checkers require raw-socket privileges and invoke only those
parts through `sudo`. Do not run OpenOCD itself with `sudo` inside the
devcontainer.

### Run

With the spin stub resident, Debug Probe UART available, Ethernet linked, and
the sacrificial USB device attached:

```bash
make kernelcheck
```

The runner performs one reset and one SWD load, then runs all integration
checks in that boot. Host progress remains visible during the approximately
one-minute SWD transfer. A successful run includes:

```text
[kernel/rpi5] BusyBox httpd curl passed
[kernel/rpi5] second BusyBox httpd curl passed
[kernel/rpi5] userspace connected I/O passed
PASS kernel/rpi5 (15 views, one boot)
```

It tests negative and positive ARP/ICMP behavior, TCP lifecycle, USB ext2
provisioning and mutation, static BusyBox file access, dynamic musl plus
BusyBox HTTPd, exact `curl` content, Linux socket I/O, VM layout, and complete
resource teardown. After teardown, the host sends `irqtest` over RP1 UART0 and
the final view verifies that EL1 received the line through the interrupt path.

### Device overrides and artifacts

The Debug Probe serial device is selected by its USB identity rather than
unstable `ttyACM` numbering. Override it when needed:

```bash
RPI5_SERIAL_DEV=/dev/ttyACM1 make kernelcheck-rpi5
```

Useful runner variables include:

```text
RPI5_SERIAL_DEV
ETH_TEST_IFACE
ETH_TEST_SUBNET
ETH_TEST_MAC
RPI5_KERNEL_CAPTURE_SECONDS
RPI5_KERNEL_HWTEST_ARTIFACT_DIR
```

Default logs and projected actual files are written under
`_build/kernel-hwtest-rpi5/`. Load, reset, UART, ARP, ICMP, TCP, curl, and
userspace-socket evidence remain separate for diagnosis.

## Expected-file integration views

The hardware runner captures UART once and projects that transcript through
every `kernel/tests/rpi5/views/*.filter`. Each projection is compared exactly
with the same-named `.expected` file. A subsystem can therefore gain a focused
contract without adding another expensive reset and SWD load.

Stable operator-visible kernel status uses `kernel_boot_log`. Temporary debug
UART messages are not accepted as expected-file evidence and are removed after
bring-up. Host-side progress output is separate from kernel UART output.

## Current limits and follow-up work

The passing HTTPd test is a concrete Linux compatibility milestone, not a
claim of general Linux compatibility.

- [Issue #180](https://github.com/takibi-lang/takibi/issues/180) completed the
  bounded multi-segment transmit queue, retransmission and stream-reassembly
  behavior, exact host comparison above one MTU with a dropped segment, and
  two independent `curl` connections in one boot.
- [Issue #181](https://github.com/takibi-lang/takibi/issues/181) completed the
  foreground BusyBox HTTPd daemon, eager fork VM ownership, parent/child
  kernel stacks, descriptor references, and deterministic child reaping.
- [Issue #182](https://github.com/takibi-lang/takibi/issues/182) tracks ext2
  indirect blocks, multiple block groups, and nested directory operations.
- [Issue #187](https://github.com/takibi-lang/takibi/issues/187) tracks the
  interrupt-driven device conversion. GIC-400 dispatch and RP1 UART0 RX are
  implemented; Cadence GEM Ethernet and xHCI USB remain polling-driven.

Unsupported Linux calls return `-ENOSYS`. Filesystem, TCP, process, and VM
features continue to be added only when an executable workload requires them.

## Future kernel targets

RPi5 remains the only implemented kernel platform today.

The intended next ports are:

1. QEMU/AArch64, reusing the common AArch64 EL1 kernel with a QEMU boot and
   device layer;
2. QEMU/RISC-V, after the second AArch64 platform has made the real
   architecture boundary concrete.

No QEMU kernel Make target exists yet. When a port is implemented, document
its build, run, debug, and integration procedure in this README and add it to
the aggregate `kernelbuild` and `kernelcheck` targets.

## Additional dependencies

Beyond the compiler dependencies listed in the top-level README, kernel
workflows use:

```text
llvm-mc-19 and ld.lld-19
openocd and gdb-multiarch
cpio and curl
e2fsprogs and e2tools
Python 3 and host raw-socket access
```

The repository devcontainer contains the maintained environment. Detailed
design decisions and hardware debugging history are retained in
[`../HISTORY.md`](../HISTORY.md); this README describes the current supported
workflow rather than replaying every intermediate milestone.
