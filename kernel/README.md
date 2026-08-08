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
- PSCI starts core 1 through its own stack and EL2-to-EL1 transition; it
  validates shared-MMU visibility and then parks. Core 0 runs the current
  process scheduler and all device interrupts.
- RPi5 UART RX, RP1 Cadence GEM Ethernet, and RP1 xHCI USB are all dispatched
  through GIC-400 and RP1 MIP0/MSI-X interrupts; the ARM generic timer (PPI
  #30) provides a periodic wake source so Ethernet's retry loops keep their
  bounded-timeout behavior without polling.
- Linux-compatible processes run at EL0 with RX text and RW+XN data, heap, and
  stack mappings.
- Ordinary kernel services do not use EL2 HVC as an internal service layer.
- Page, mapping, process, file, socket, frame, and DMA lifetimes retain
  explicit affine or linear ownership.
- A fixed two-slot process table gives each live process a dedicated kernel
  stack, address-space root, ASID, and unified descriptor table. The generic
  timer preempts EL0 round-robin once both slots are runnable; a UART RX wait
  demonstrates a typed Blocked-to-Ready transition.
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
  socket workloads, plus a typed user-memory boundary (`kernel/mm/
  user_memory.tkb`) enforcing non-RWX process mappings -- see `SYSCALLS.md`
  for the full per-syscall support matrix;
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
`read` plus a 1460+1 partial `write` sequence. The focused EL0 socket fixture
also keeps connection A open while accepting connection B: a two-entry typed
connection pool gives each stream independent TCP/retransmission/buffer state,
and the fixed descriptor table maps them to fd 5 and fd 6 before either is
closed. The physical one-descriptor GEM RX capability remains a singleton and
is borrowed by one sequential syscall operation at a time.

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
ELF, then runs `scripts/check_kernel_asm_invariants.py` against the linked
`kernel.elf` -- a static, hardware-free disassembly check that fails the
build if specific past hand-written-assembly bugs (issues #229, #231) ever
regress, without needing a board or a probabilistic real-hardware race to
reproduce them. It also links `kernel/arch/arm64/kernel/user_payload.tkb`/
`user_payload_asm.S` into their own real static-PIE ELF (placed on the ext2
fixture image as `/user_payload` and launched from `kernel/tests/ext2/init.sh`
like any other external command, issue #241) and runs
`scripts/check_user_payload_no_rw_globals.py` against that link -- a static
check for a real issue #228 bug: a top-level mutable global in that file is
not guaranteed to be writable at its runtime address, so writes into it can
silently fail.

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
PASS kernel/rpi5 (25 views, one boot)
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

## Current limits

The passing HTTPd test is a concrete Linux compatibility milestone, not a
claim of general Linux compatibility. `SYSCALLS.md` is the per-syscall
authority and `kernel/tests/rpi5/views/*.expected` is the actual contract;
the list below is orientation for a reader deciding whether a workload will
run, not a specification.

- **Filesystem.** One ext2 block group, direct blocks only, root-directory
  lookup and mutation, allocation bitmaps, fast symlinks. No indirect
  blocks, no additional block groups, no nested directories.
- **Processes.** A fixed three-slot process table (issue #245), all of it on
  core 0. Core 1 proves autonomous EL1 entry and shared-MMU visibility, then
  parks. `execve` dispatches by `argv[0]` path between the registered static
  BusyBox image and `/user_payload`. `wait4` blocks the caller until its
  live child exits (by specific pid or `-1`/`WAIT_ANY`), delivering the
  real reaped pid and exit status (issue #244); a process may have at most
  one live child at a time, so concurrent multi-child wait/reap remains out
  of scope.
- **Signals.** Signal state is recorded honestly, but no signal is ever
  delivered, so an installed handler is never invoked.
- **Memory.** `mmap` is anonymous-only through a heap-break cursor rather
  than a real independent mapping. `mprotect` performs exactly one
  permission transition (`RW+XN` <-> `R+XN` on data, heap, and stack) and
  returns a real error for anything else. `munmap` is unsupported by
  design: the process arena is reclaimed as a unit.
- **Scatter/gather I/O.** `writev` covers the UART descriptors and `readv`
  covers ext2 files. Neither reaches the connected-TCP or inetd-mode paths
  that plain `write`/`read` already support.
- **`ppoll`.** Blocks and wakes on UART RX for the single-descriptor stdin
  shape BusyBox ash's `read` builtin uses. Any other shape reports current
  readiness immediately, and a non-NULL timeout is never armed.
- Unrecognized Linux calls return `-ENOSYS`.

Filesystem, TCP, process, and VM features continue to be added only when an
executable workload requires them.

Planned and in-progress work is tracked on the
[project board](https://github.com/orgs/takibi-lang/projects/2) rather than
enumerated here, so this file stays a description of what the kernel does
today. [`../ROADMAP.md`](../ROADMAP.md) carries the mid-term plan and the
dependency reasoning behind it; [`../HISTORY.md`](../HISTORY.md) carries the
per-milestone engineering record.

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
