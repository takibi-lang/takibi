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
- A fixed 16-slot scheduler table (`ProcessRecord`) gives each live process a
  dedicated address-space root, ASID, and unified descriptor table. Kernel
  stacks are 16 KiB, allocated on a slot's first use as the upper half of a
  32 KiB-aligned page run whose lower half contains an overflow instead of
  letting it reach a neighbour; page-table pages are directly owned by each
  address space. The generic timer preempts EL0
  round-robin once more than one slot is runnable; a UART RX wait demonstrates
  a typed Blocked-to-Ready transition.
- Kernel Takibi sources build with `--forbid-trap`; fallible internal
  operations return variants and convert to Linux `-errno` only at the syscall
  boundary.

The EL0 exception frame preserves general-purpose registers, q0-q31, FPSR,
FPCR, and the TPIDR_EL0 thread pointer across syscalls -- musl derives errno
from TPIDR_EL0, so a context switch that leaves another process's thread
pointer live sends the next errno write into an unrelated mapping. Process
exit returns to the owning EL1 call frame so the complete address space can be
unmapped and reclaimed.

## Implemented system slices

The current RPi5 kernel includes:

- typed page allocation, AArch64 stage-1 page tables, process images, and
  deterministic teardown, backed by real physical RAM addressed directly
  (`kernel/mm/page.tkb`) and sized against the board's own real detected
  RAM (`kernel/platform/rpi5/mailbox.tkb`, a VideoCore firmware query,
  boot-logged but not yet the allocator's own live bound);
- ELF64 validation, static PIE loading, interpreter-aware PIE plus musl
  loading, initial Linux stack and auxv construction, `brk`, and bounded
  anonymous `mmap` behavior;
- the Linux AArch64 syscall subset reached by the current BusyBox, file, and
  socket workloads, plus a typed user-memory boundary (`kernel/mm/
  user_memory.tkb`) enforcing non-RWX process mappings -- see `SYSCALLS.md`
  for the full per-syscall support matrix;
- a block-device boundary shared by the embedded memory fixture, QEMU
  virtio-blk, and RPi5 USB Mass Storage;
- a bounded ext2 implementation with direct, single-indirect, and
  double-indirect regular-file reads, nested path lookup, root directory
  mutation, allocation bitmaps, and fast symlinks;
- RP1 PCIe, xHCI/USB Mass Storage, Cadence GEM Ethernet, ARP, IPv4, ICMP, and
  a bounded TCP slice with in-order stream reconstruction, short reads,
  partial writes, duplicate/out-of-order acknowledgement, and timed SYN/ACK,
  data, and FIN retransmission;
- an ext2 root filesystem containing reproducibly pinned Alpine BusyBox,
  BusyBox Extras, and the matching musl interpreter without committing those
  GPL binaries;
- one-boot integration views that independently compare boot, VM, process,
  syscall, filesystem, USB, Ethernet, BusyBox, and HTTPd evidence.

The rootfs keeps executable files under `/bin`: Alpine's original
`busybox.static` and `busybox-extras` names identify the two real binaries;
`sh`, `cat`, `echo`, `ls`, `od`, and `uname` are hard links to the static
binary, while `httpd` is a hard link to BusyBox Extras. The independent
Takibi test program is `/bin/user_payload`. Boot policy scripts remain under
`/etc` (`/etc/init.sh` and `/etc/httpd-demo.sh`).

The current HTTPd milestone runs the unmodified pinned BusyBox Extras binary
through its `/bin/httpd` hard link as a persistent foreground daemon:
`httpd -f -p 8080 -h /`.
HTTPd creates its own IPv6 wildcard listener, accepts each connection, and
uses the observed `clone(SIGCHLD)` fork shape. Each child receives a private
copy-on-write view of the parent's initial 331-page VM plus a distinct kernel
stack; it gets private pages only when it writes. It aliases the accepted
socket onto fd 0/fd 1, reads `index.html` from USB ext2, writes the response,
and exits. The same parent accepts two sequential host `curl` requests before
the bounded integration teardown reclaims every child mapping, fd, and socket
reference. The host compares both complete 68-byte bodies with the fixture.
TCP fixtures also split a request across segments, inject bounded drops, and exercise short
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
make kernelcheck-rpi5  # build and run the complete RPi5 integration test (needs real hardware)
make kernelbuild-qemu  # build kernel/build/qemu/kernel.elf
make kernelcheck-qemu  # build and run the complete QEMU integration test (no hardware needed)
make kernelcheck-shell-qemu  # PTY smoke test for the interactive QEMU ash path
make kernelbuild-qemu-debug  # build kernel/build/qemu/kernel-debug.elf with DWARF info
make kernelcheck-qemu-debug  # run the complete QEMU integration test against the DWARF build
make kernelcheck-oops-qemu  # verify parked QEMU oops records and the retained lifecycle trace
make kernelcheck-lifecycle-gap-qemu  # verify the interactive-HTTPd checkpoint diagnosis names a real gap
make kernelbuild       # build every maintained kernel target
make kernelcheck       # build and test every maintained kernel target
make kernelsh-qemu     # boot QEMU and use the current terminal as the ash UART console
make kernelsh-rpi5     # load RPi5 over SWD and use the Debug Probe UART as the ash console
```

The two `kernelsh-*` targets are deliberately interactive and do not run the
automated view suite. RPi5 starts the physical-Ethernet peer needed to keep
the kernel's normal network initialization path from timing out. QEMU instead
uses its user-mode network so that BusyBox httpd started at the ash prompt can
be opened from the host browser. Both use pyserial's
`miniterm`; on Debian/Ubuntu install it with `sudo apt-get install
python3-serial`. Press Ctrl-] to leave either console.
Exiting this way also restores the host terminal settings.

The QEMU shell also reports the elapsed time from QEMU launch to the kernel's
explicit `interactive shell: uart blocked` readiness marker. This is the
point at which ash is waiting for input, rather than merely the point at which
the QEMU process or UART socket exists.

### Publish a page from interactive ash

Both shell targets provide the same BusyBox HTTPd command. Wait for the
`interactive shell: uart blocked` marker and its `/ #` prompt, then run:

```sh
httpd -f -p 8080 -h / &
```

For QEMU, start the shell and open the forwarded loopback URL in a browser:

```bash
make kernelsh-qemu
```

Open `http://127.0.0.1:18080/` in Firefox. QEMU user-mode networking forwards
that host port to the kernel's fixed `192.168.20.2:8080`; set
`KERNEL_QEMU_SHELL_HTTP_PORT` to choose another host port. When the browser is
outside the development container, forward that container port first. The
automated `kernelcheck-qemu` lane remains on its deterministic raw-Ethernet
peer and continues to run the complete network fixture.

For RPi5, connect the host Ethernet interface as described in [Host Ethernet
setup](#host-ethernet-setup), then start the shell:

```bash
make kernelsh-rpi5
```

Open `http://192.168.20.2:8080/` in Firefox. The host interface must be on
`192.168.20.1/24` (or use the corresponding configured subnet); the default
kernel address is `192.168.20.2`.

`kernelsh-rpi5` first performs the existing resident-image reset. The SD card
must have booted this project's `jtag_stub.img` at least once; subsequent
shell/check runs may reset and replace an already resident Takibi payload
without another power cycle. Power-cycle after changing the SD-card payload.
The RPi5 shell prints reset and SWD-load durations and reports the same ash
readiness marker after the UART is attached. It also starts the existing
physical-Ethernet ARP/ICMP/TCP peer after SWD load, so the kernel does not pay
its normal no-peer protocol timeout before reaching ash. This requires a
passwordless `sudo` capability for raw Ethernet access; set
`KERNEL_RPI5_SHELL_NETWORK_PEER=0` to disable it. Configure the peer with the
same `ETH_TEST_IFACE`, `ETH_TEST_SUBNET`, `ETH_TEST_MAC`, and
`ETH_TEST_HOST_IP` variables used by `kernelcheck-rpi5`. The maintained kernel
targets default to 30 MHz SWD on the validated Debug Probe/board setup; set
`RPI5_SWD_SPEED=<kHz>` to use a more conservative speed for another probe or
cable, for example `RPI5_SWD_SPEED=1000`.

`kernelbuild`/`kernelcheck` run both the RPi5 and QEMU targets. See
"QEMU/AArch64 integration" below for what `kernelcheck-qemu` covers and how
it differs from the RPi5 lane -- in particular, `make kernelcheck` still
needs real RPi5 hardware attached, even though `kernelcheck-qemu` alone does
not.

`kernelbuild-rpi5` does not require a board. It generates the ext2 root
fixture, obtains the pinned Alpine packages, compiles all Takibi
code under `--forbid-trap`, assembles the minimal AArch64 files, and links the
ELF, then runs `scripts/check_kernel_asm_invariants.py` against the linked
`kernel.elf` -- a static, hardware-free disassembly check verifying the
kernel identity block's UXN permission bits and the EL0 `eret` path's
DAIF.I masking, catching a class of past hand-written-assembly regression
without needing a board or a probabilistic real-hardware race to
reproduce it. It also links `kernel/arch/arm64/kernel/user_payload.tkb`/
`user_payload_asm.S` into their own real static-PIE ELF (placed on the ext2
fixture image as `/bin/user_payload` and launched from `kernel/tests/ext2/init.sh`
like any other external command) and runs
`scripts/check_user_payload_no_rw_globals.py` against that link -- a static
check that a top-level mutable global in that file is not guaranteed to be
writable at its runtime address, so writes into it can silently fail.

## Raspberry Pi 5 hardware integration

### Destructive-test warning

`make kernelcheck-rpi5` overwrites the first 4 MiB of the USB Mass Storage
device attached to the RPi5 with its generated ext2 fixture. Attach only the
project's dedicated sacrificial test drive. The kernel block adapter exposes
only the first 4096 1-KiB blocks, which bounds this test independently of the
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
checks in that boot. Host progress remains visible during the SWD transfer;
the duration depends substantially on `RPI5_SWD_SPEED` and the attached
probe/board setup. A successful run includes:

```text
[kernel/rpi5] BusyBox httpd curl passed
[kernel/rpi5] second BusyBox httpd curl passed
[kernel/rpi5] userspace connected I/O passed
PASS kernel/rpi5 (38 views, one boot)
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

## QEMU/AArch64 integration

QEMU/AArch64 lets anyone build and boot a substantial, real integration
suite for this kernel without RPi5 hardware, a Debug Probe, or a wired
Ethernet link. It reuses the same architecture-generic exception/syscall,
MMU, and scheduler code RPi5 runs -- only the earliest boot glue and the
platform drivers (`kernel/platform/qemu/`,
`kernel/drivers/net/virtio_net.tkb`) are QEMU-specific, selected by which
files a given build's compile line lists, the same convention
`kernel/platform/rpi5/` uses for its own drivers. See "Differences from
RPi5" below for the one genuinely different piece of boot-time
architectural setup (the EL2-to-EL1 drop).

### Build and run

```bash
make kernelbuild-qemu  # build kernel/build/qemu/kernel.elf (no hardware needed)
make kernelcheck-qemu  # build, boot, drive a host-side network peer, and verify (no hardware needed)
make kernelcheck-shell-qemu  # PTY smoke test for the interactive QEMU ash path
make kernelcheck-qemu-debug  # run the same integration suite with a -g kernel build
```

Both need `qemu-system-aarch64` (part of the compiler dependencies listed in
the top-level README) and Python's `pyserial` package for the shared UART
driver, but no board, no SWD, no NIC, or raw-socket privileges. To use the
BusyBox ash prompt from a terminal, run
`make kernelsh-qemu`. It launches QEMU with the complete virtio block/network
configuration and connects its UART to pyserial miniterm over a local TCP
chardev; this preserves LF input and local echo. Press Ctrl-] to leave the
console and restore the host terminal settings.

`kernelcheck-qemu` includes `kernelcheck-shell-qemu`, a PTY smoke test that
exercises this interactive QEMU path automatically. The standalone target is
also useful when diagnosing a terminal-specific regression without running
the whole QEMU suite.

The kernel never exits (a `while (true) {}` park at the end of boot, same as
RPi5). `scripts/kernel_net_test.py <local-port> <remote-port>` is the host-side
peer `kernelcheck-qemu` drives automatically; use the automated runner rather
than an interactive console when exercising its ARP/ICMP/TCP contracts.

### Terminal fail-stop diagnostic

The kernelcheck-oops-qemu target is a focused QEMU regression for the terminal
exception path. It checks an injected EL0 BRK, an injected EL0 data abort, and
a fail-stop immediately after a real child exec commit. GDB only arms the
fault or the default-false test switch, then detaches; the kernel itself saves
the Lower-EL exception frame, emits the UART oops report, retains
CrashSnapshot, and parks the CPU. The test also sources the compiler-generated
_build/kernel-crash-snapshot-layout.gdb and then
scripts/kernel_crash_snapshot.gdb's read-only takibi-oops command to inspect
that retained record. The helper reads the snapshot's generated layout only;
it does not reproduce the exception-frame ABI.

When enabled for a boot test, the process layer records a fixed 16-entry,
allocation-free lifecycle ring: fork, exec prepare/commit, schedule, block,
wake, resume, exit, reap, and address-space activation. Each numeric record
contains a local sequence, CPU, process and peer identities, state, wait
reason, root, saved SP, and event-specific auxiliary value. Writers never
print; a record publishes its sequence last, so a fail-stop copy skips an
IRQ-interrupted in-progress record and presents committed entries oldest to
newest. Ordinary boots leave tracing disabled. The current scheduler runs only
on core 0; when real SMP scheduling is introduced, this ABI is intended to
become one independently written ring per CPU rather than a false shared
global order.

### Interactive HTTPd lifecycle checkpoints

The bounded self-test suite's own top-level ash execs, via a real `exec`
self-replace (see `kernel/tests/ext2/init.sh`'s final line), directly into
the persistent terminal demo shell -- a single top-level launch, not a
second kernel-side one. That shell forks its own interactive ash, which in
turn forks and execs the background HTTPd the host harness drives. Because
that chain of boundaries used to collapse into one generic "interactive
HTTPd did not become ready" timeout, the kernel now prints a
`persistent shell: <name> pid=<n>` checkpoint at each of fork, child
selected, exec prepare, and exec commit for that HTTPd child specifically
(gated on `kernel_syscall_persistent_shell_active()`, not on any bounded
self-test fork), plus a listener-ready line for the socket boundary.
`scripts/run_kernel_uart_driver.py` tracks these in order alongside its own
host-observed boundaries (command submitted, parent resumed) and, on a
stall, names the last completed checkpoint and the next expected one
instead of a single opaque timeout. `kernelcheck-lifecycle-gap-qemu` proves
that diagnosis is itself correct: GDB pokes only the exec-commit
checkpoint's own one-shot guard variable (no dedicated test-only kernel
switch), so HTTPd still starts and answers real HTTP requests while that
one print is skipped, and the harness is expected to fail naming exactly
that gap.

### What this verifies

`kernelcheck-qemu` boots the kernel once and projects that single UART
transcript through the common views plus the QEMU-specific views, comparing
each exactly against its `.expected` file -- the identical "one boot, many
independent contracts" pattern `kernelcheck-rpi5` uses (see "Expected-file
integration views" below), just without the SWD reset/load dance: QEMU's
TCP-backed serial chardev is read by the shared pyserial driver.
Thirty-eight views currently pass. The target then runs a separate ash smoke
lane using the same pyserial driver and the shared
`kernel/tests/common/ash/ash.stdin` and `ash.expected` fixtures; the RPi5
runner drives those fixtures during its one boot as well. The 38 views
cover:

- the full hardware-independent self-test bundle (FP/SIMD-across-IRQ, a
  real second-core PSCI bring-up, VM layout, user memory + root isolation,
  syscall subset, fd table, scheduler, growable pool, ASID pool);
- a real ext2 mount, read, write, symlink, and multi-block file read
  against a QEMU virtio-blk device backed by the same ext2 image passed to
  the harness;
- the pinned Alpine BusyBox static-PIE image, loaded and run for real
  (`cat`, `uname`, `od`, `execve`, a forked child) with real Linux syscalls;
- real ARP, ICMP echo, and a full TCP handshake/data-echo/close/reconnect
  sequence against a host-side Python peer (`scripts/kernel_net_test.py`)
  over a private `-netdev dgram` transport.
- the BusyBox HTTPd accept/serve loop, split requests, retransmission
  recovery, repeated requests, and exact `index.html` responses;
- the interactive HTTPd child's own fork/child-selected/exec-prepare/
  exec-commit/listener-ready lifecycle checkpoints, in order (see
  "Interactive HTTPd lifecycle checkpoints" above);
- the ext2-resident `init.sh` scenario, including connected socket I/O,
  overlapping connections, partial writes, UART input, and process/VM
  lifecycle checks;
- resource-limit boundary probes (issue #295): each fixed-capacity pool
  (shared object pool, TCP connections, per-process fd table, the
  pending-TCP retransmit queue, and the two large reference-count
  ceilings) is driven to exactly its documented capacity, proving the
  returned variant/error and that a clean rollback/reuse follows --
  `RESOURCE_LIMITS.md` is the full inventory these probes cover.

### Differences from RPi5

QEMU is a design and regression-testing aid, not a hardware-fidelity
replacement -- RPi5 stays the real-hardware lane, and the differences below
are deliberate, not gaps to silently close:

- **No cache-coherency modeling.** QEMU (TCG, the only mode this project
  uses) does not model caches as physically separate from RAM, so a missing
  cache-maintenance operation is invisible here and can only be found on
  real hardware. A change to `kernel/arch/arm64/mm/mmu.tkb` or any DMA path
  passing under QEMU is not evidence it is cache-safe.
- **Boot model differs from RPi5's TF-A hand-off.** QEMU `virt` (with a
  plain `-cpu cortex-a53`, no firmware) starts the guest directly at EL1,
  not EL2, so `kernel/arch/arm64/boot/entry_qemu.S` skips the EL2-drop
  sequence `entry.S` needs for RPi5's real TF-A hand-off. Its PSCI conduit
  is HVC, not RPi5's real-firmware SMC, and its per-core MPIDR numbering
  puts the core index in Aff0, not RPi5/BCM2712's Aff1.
  `kernel/platform/qemu/init.tkb` uses the `hvc4` compiler intrinsic where RPi5
  uses `smc4` for exactly this reason.
- **Storage uses virtio-blk, not RPi5's USB Mass Storage path.** The harness
  attaches `kernel/build/user/ext2.img` as a legacy virtio-mmio block device,
  and the kernel mounts it through `kernel/drivers/block/virtio_blk.tkb`.
  There is no RP1, PCIe, or xHCI/USB Mass Storage under QEMU, so the real USB
  provisioning and hardware-specific storage checks remain RPi5-only.
- **RAM size is an assumed constant, not detected.** RPi5's
  `platform_memory_detect()` queries the real VideoCore mailbox; QEMU has
  no such firmware service, so `kernel/platform/qemu/memory.tkb` reports a
  fixed value matching the harness's own `-m` choice. Neither platform's
  page allocator actually consumes this value today (see "Current limits"
  below) -- it is diagnostic boot-log output on both.
- **The MMU device/RAM layout is inverted from RPi5's.** RPi5's real RAM
  starts at physical address 0; QEMU `virt`'s starts at `0x40000000`, with
  device MMIO below it -- roughly the opposite of RPi5's layout. See
  `kernel/platform/qemu/mmu_layout.tkb`'s own header for the resulting L1
  block-index choices, including why `USER_TEXT_VA` differs from RPi5's.
- **The RP1 GEM Ethernet and USB Mass Storage drivers are not exercised.**
  QEMU verifies equivalent network and storage behavior through virtio-net
  and virtio-blk, while the RPi5 lane remains authoritative for those
  hardware-specific drivers and their interrupt/DMA behavior.

## Expected-file integration views

The hardware runners capture UART once and project that transcript through the
union of `kernel/tests/common/views/*.filter` and the target's
`kernel/tests/<platform>/views/*.filter`. A platform view overrides a common
view with the same name. Each projection is compared exactly with the
same-named `.expected` file, using the platform file when present and otherwise
the common file. A subsystem can therefore gain a focused contract without
adding another expensive reset and SWD load.

Stable operator-visible kernel status uses `kernel_boot_log`. Temporary debug
UART messages are not accepted as expected-file evidence and are removed after
bring-up. Host-side progress output is separate from kernel UART output.

## Current limits

The passing HTTPd test is a concrete Linux compatibility milestone, not a
claim of general Linux compatibility. `SYSCALLS.md` is the per-syscall
authority, `RESOURCE_LIMITS.md` is the per-resource-pool authority (every
resource pool -- process slots, descriptors, shared objects, connections,
pages, and more -- with its exhaustion behavior, and its boundary test
where it still has a boundary), `RUNTIME_STATE.md` is the per-global-state-ownership authority
(every retained runtime `let mut` global, grouped by owner and why it
stays global instead of moving behind a per-slot record),
`MEMORY_MAP.md` is the where-is-this-address authority (both platforms'
physical and virtual layouts, with the rows a build check verifies marked
apart from the ones nobody verifies), and the
common/platform view `.expected` files are the actual contracts; the
list below is orientation for a reader deciding whether a workload will
run, not a specification.

- **Filesystem.** One ext2 block group, nested path lookup, root-directory
  mutation, allocation bitmaps, and fast symlinks. Regular-file reads cover
  twelve direct blocks plus single- and double-indirect blocks; the maximum
  is derived from the 1-KiB block geometry rather than a file-size literal.
  Writes and truncates remain limited to one direct block. Directories and
  symlinks remain one block, and there are no additional block groups.
- **Processes.** A fixed 16-slot `ProcessRecord` scheduler table, with lazily
  backed kernel stacks and directly owned address-space page tables, all on
  core 0.
  Core 1 proves autonomous EL1 entry and shared-MMU visibility, then parks.
  `execve` resolves `argv[0]` as an ext2 path, validates a bounded ELF
  metadata window, and streams each PT_LOAD page from the file. Static
  BusyBox applets such as `/bin/echo` are hard links to its ELF, so their
  argv[0]-driven multi-call dispatch works without a separate registry; an
  unresolved path falls back to that same static image. `wait4` blocks
  the caller until its live child exits (by specific pid or `-1`/
  `WAIT_ANY`), delivering the real reaped pid and exit status, tracked
  per-slot so any live process (not just the tree root) can wait for its
  own child; a process may have at most one live child at a time, so
  concurrent multi-child wait/reap remains out of scope. UART `read(2)`
  blocks and wakes on received input, sufficient for the foreground
  interactive BusyBox ash REPL; there is no controlling-TTY job control.
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

RPi5 and QEMU/AArch64 (see "QEMU/AArch64 integration" above) are both
implemented today. The intended next port is QEMU/RISC-V, now that a second
AArch64 platform has made the real architecture boundary (what is
CPU-generic versus board/platform-specific) concrete in practice.

## Additional dependencies

Beyond the compiler dependencies listed in the top-level README, kernel
workflows use:

```text
llvm-mc-19 and ld.lld-19
openocd and gdb-multiarch
curl
e2fsprogs and e2tools
Python 3 and host raw-socket access
```

The repository devcontainer contains the maintained environment. Detailed
design decisions and hardware debugging history are retained in
[`../HISTORY.md`](../HISTORY.md); this README describes the current supported
workflow rather than replaying every intermediate milestone.
