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
- A pooled scheduler table (`ProcessRecord`) gives each live process a
  dedicated address-space root, ASID, and unified descriptor table. There is
  no process-count constant: a record is a pool allocation, so the page
  allocator is the only limit (`RESOURCE_LIMITS.md` carries the full table). Kernel
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
  RAM (the firmware-resolved DTB captured by the resident SWD stub,
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
- a CPU-bound workload that occupies the scheduler rather than waiting on a
  device: `/etc/inittab` starts `/bin/busy-a` and `/bin/busy-b` as two
  `respawn` entries, each looping on arithmetic and reporting a finished
  round to the kernel, which measures how far ahead of the other either one
  ever got and reports both processes' CPU time, then asks one of them to
  exit and checks that `init` brought back only that one while the other
  kept its pid and its counter;
- one-boot integration views that independently compare boot, VM, process,
  syscall, filesystem, USB, Ethernet, BusyBox, HTTPd, and workload-fairness
  evidence.

The rootfs keeps executable files under `/bin`: Alpine's original
`busybox.static` and `busybox-extras` names identify the two real binaries;
`sh`, `cat`, `echo`, `ls`, `od`, and `uname` are hard links to the static
binary, while `httpd` is a hard link to BusyBox Extras. The independent
Takibi test programs are `/bin/user_payload` (the EL0 syscall-ABI fixture)
and the pair `/bin/busy-a`/`/bin/busy-b`, which are the same object linked
twice with different ELF entry points so each knows which `respawn` entry it
is without parsing `argv`. `/bin/spin` is a third link of the same object: one
round of that work and then exit. The ash session backgrounds two of them
and then asks `jobs`, which answers with both still Running -- that listing
is how the session shows it holds more than one job at once, and it carries
no pid, so it is the same text on every boot. `spin` prints nothing because
output interleaving with the prompt would arrive in an order no fixture
could pin.
Shell scripts are ordinary
executables here: a script's first line names its interpreter and `execve`
resolves it, so `/bin` also holds `httpd-serve.sh` (the browser demo as one
command) and `script-interpreter-argument.sh` (a fixture pinning `#!` argv
construction), both reachable by bare name through ash's `PATH` search.
`/etc` keeps what is never typed as a bare command: BusyBox init's
`/etc/inittab` and the boot scenario it runs (`/etc/init.sh`),
`/etc/script-shebang.sh`, and the two fixtures that pin what `execve`
refuses (`/etc/not-a-program`, `/etc/bad-interpreter.sh`). `/bin/busybox` exists as a hard link because that
is the name BusyBox re-executes itself through.

The current HTTPd milestone runs the unmodified pinned BusyBox Extras binary
through its `/bin/httpd` hard link as a persistent foreground daemon:
`httpd -f -p 8080 -h /`, reached by running `httpd-serve.sh`, which carries
that command line so no prompt has to.
HTTPd creates its own IPv6 wildcard listener, accepts each connection, and
uses the observed `clone(SIGCHLD)` fork shape. Each child receives a private
copy-on-write view of the parent's initial 331-page VM plus a distinct kernel
stack; it gets private pages only when it writes. It aliases the accepted
socket onto fd 0/fd 1, reads `index.html` from USB ext2, writes the response,
and exits. The same parent accepts two sequential host `curl` requests before
the bounded integration teardown reclaims every child mapping, fd, and socket
reference. The document root also carries the SD-card demo's `about.html` and
23,658-byte `icon.png`; interactive integration fetches `/`, all three named
assets, checks their complete bodies, and verifies `text/html`/`image/png`
content types.
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
kernel/fs/procfs.tkb     bounded read-only BusyBox ps compatibility view
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
make kernelcheck-ddb-qemu  # enter DDB through a real UART BREAK, inspect, and resume
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

To stop a live kernel in DDB from either `make kernelsh-qemu` or
`make kernelsh-rpi5`, press Ctrl-T and then the ordinary lowercase `b` key.
Neither key is forwarded to ash. On RPi5 the host sends one automatically
released 250 ms physical serial BREAK; on QEMU the console asks the PL011
chardev to deliver the equivalent BREAK through a private QMP control socket.
The existing TCP UART/miniterm data path is unchanged. The kernel prints
`ddb>` and accepts `oops`, `regs`, `intr`, `sched`, `current`, `vm`, `fds`,
`ps`, `proc PID`, `trace`, `events`, `xk`, `xp`, `xu`, `help`, and
`continue`. Use
`continue` to return through the saved exception frame. Ctrl-C remains an
ordinary terminal byte and is not reserved by the debugger. The console
prints this key reminder when it starts. Miniterm's generic Ctrl-T, Ctrl-B
indefinite BREAK toggle is intentionally not the Takibi DDB binding.

The QEMU shell also reports the elapsed time from QEMU launch to the kernel's
explicit `interactive shell: uart blocked` readiness marker. This is the
point at which ash is waiting for input, rather than merely the point at which
the QEMU process or UART socket exists.

### Publish a page from interactive ash

Both shell targets provide the same BusyBox HTTPd command, as a script in
the rootfs rather than as something to retype. Wait for the
`interactive shell: uart blocked` marker and its `/ #` prompt, then run:

```sh
httpd-serve.sh &
```

No pathname and no interpreter: the script lives in `/bin`, so ash's `PATH`
search finds it, and its `#!/bin/sh` line is what `execve` resolves to decide
what runs it. The trailing `&` is still needed -- `httpd -f` stays in the
foreground for the life of the daemon. Its command line (port 8080, document
root `/`) lives in `kernel/tests/ext2/httpd-serve.sh`.

For QEMU, start the shell and open the forwarded loopback URL in a browser:

```bash
make kernelsh-qemu
```

Open `http://127.0.0.1:18080/` in Firefox. Its links exercise
`/about.html` and `/icon.png`. QEMU user-mode networking forwards
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

`make kernelcheck-rpi5` overwrites the first 2.5 MiB of the USB Mass Storage
device attached to the RPi5 with its generated ext2 fixture. Attach only the
project's dedicated sacrificial test drive. The kernel block adapter exposes
only the first 2560 1-KiB blocks, which bounds this test independently of the
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

The board boots a small DTB-capturing spin stub from `kernel_2712.img`; test
kernels are then injected into RAM over SWD. The stub preserves firmware's
resolved Device Tree below the injected kernel, and the SWD loader verifies
its FDT magic before changing RAM or restoring its address in `x0`. Build and
install the stub:

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
CrashSnapshot, and enters a read-only UART crash console with interrupts
masked. Its initial commands are `oops`, `trace`, `ps`, and `proc PID`;
unknown commands cannot mutate memory, registers, processes, or resume a
terminal failure. The focused regression drives all four commands over the
real QEMU UART connection. The test also sources the compiler-generated
_build/kernel-crash-snapshot-layout.gdb and then
scripts/kernel_crash_snapshot.gdb's read-only takibi-oops command to inspect
that retained record. The helper reads the snapshot's generated layout only;
it does not reproduce the exception-frame ABI.

### Resumable UART DDB

A serial BREAK enters a separate, resumable DDB path from UART IRQ context.
The interrupt controller and UART source are acknowledged first, but DDB
deliberately remains typed `!{interrupt, unsafe}`: it does not pretend that
acknowledgement turns an interrupt frame into ordinary kernel context. Every
reachable operation is fixed-size and polling-only, with no allocator, lock,
scheduler, sleep, filesystem, network, or ordinary logging dependency. Its
commands are `oops`, `regs`, `intr`, `sched`, `current`, `vm`, `fds`, `ps`, `proc PID`,
`trace`, `events`, `xk ADDRESS [COUNT]`, `xp PHYSICAL [COUNT]`,
`xu PID ADDRESS [COUNT]`, and `continue`
(`help` lists them).

`regs` reads the compiler-defined `ExceptionFrame` directly. DDB does not
copy registers with handwritten assembly and does not duplicate frame
offsets; the compiler-generated exception entry and return path remain the
only owner of register save/restore. `trace` takes a bounded copy of the
committed lifecycle ring. `continue` returns through the existing IRQ restore
path. `intr` identifies IRQ versus deliberate BRK entry and reports both the
live and interrupted DAIF masks; ESR/FAR are shown only for synchronous entry,
because those registers do not describe an IRQ. `sched` reports the frozen
scheduler enable/pending bits and process-state counts from the same bounded
snapshot as `ps`, including its truncation flag. `current`, `vm`, and `fds`
read only the fixed snapshot captured at DDB
entry: process identity/state/wait reason, a lookup-only address-space view,
and the first 16 descriptor slots. The VM lookup cannot allocate a missing
backing. `ps` and `proc PID` use a separate bounded entry snapshot: at most 64
physical pool slots are probed and at most 32 live process summaries retained.
The header prints `truncated=1` when either budget prevents a complete view;
`proc PID` then says that an absent PID was not captured rather than claiming
it does not exist. The terminal crash console above intentionally has no
`continue`.

`xk` reads 1 to 64 bytes from a hexadecimal kernel virtual address. It is
limited to the identity-mapped ordinary-RAM span occupied by the kernel image
and page allocator; addresses in device mappings are rejected before access,
because an MMIO read may itself change device state. Each byte is printed with
its address so output remains unambiguous across page boundaries. A guarded
load that still takes a Current-EL data abort is recovered only when FAR
matches the one address DDB published immediately before the load; every other
synchronous exception retains the normal fail-stop path. Current-EL sync
dispatch stays on the interrupted stack so a nested guarded fault cannot
overwrite the suspended DDB call frames on the IRQ stack.

`xu` reads the same bounded byte count from a captured process's user virtual
address space. DDB freezes each captured root's lookup-only L2 address at
entry, walks L2/L3 descriptors without activating the root or changing a TLB,
and re-translates every byte so crossing a page boundary is explicit. Page
table addresses and resolved data pages must themselves lie in ordinary RAM;
bad descriptors stop with `page-table fault` rather than becoming an MMIO or
unmapped dereference. A PID absent from a truncated process snapshot is
reported as not captured, not nonexistent.

`xp` reads a physical address directly. It is independently classified as
managed ordinary RAM before the guarded load; the present identity mapping is
only the mechanism used to access that physical byte, not part of the command's
address semantics. Physical MMIO and addresses outside managed RAM are denied.
Malformed commands, address-range overflow, and byte counts outside 1 through
64 are rejected without attempting a load. The QEMU DDB lane exercises those
parser boundaries as well as a real guarded translation fault, then issues
further commands and `continue`; an accidental address must not consume the
debugging session that exposed the failure.

`events` renders each CPU's independent fixed-record diagnostic tail. It
reports valid, damaged/in-progress, and overwritten counts separately and
does not imply a total order between CPUs. Recording is disabled by default;
the current first producer records UART BREAK entry when explicitly enabled
by the debugger integration test. Process UART wake decisions use a second
event range and retain the input byte, current PID, selected waiter PID, and
outcome. This distinguishes no-current/no-waiter/ownership-loss from consumed
and retry-read outcomes without printing from the interrupt path.

`kernelcheck-ddb-qemu` asks QEMU to deliver a real chardev BREAK to the PL011,
drives all inspection commands over its UART socket, and verifies that boot
continues afterward. A second lane executes Takibi's reserved deliberate
`brk #0x544b`, enters through a compiler-generated Current-EL synchronous
`ExceptionFrame`, advances ELR past that instruction, and proves the same
resume behavior. Other Current-EL synchronous exceptions remain fatal. The
RPi5 implementation uses the same PL011 DR.BE/BEIM
path. The normal RPi5 integration enables the test-only ring byte over SWD
after its ordinary workload, sends an ordinary byte followed by timed CDC
BREAK, runs `events`, and continues in the same boot. This verifies the
process-wake and platform-BREAK records, undamaged per-CPU reading, and resume
on the physical board.

When enabled for a boot test, the process layer records a fixed 16-entry,
allocation-free lifecycle ring: fork, exec prepare/commit, schedule, block,
wake, resume, exit, reap, and address-space activation. Each numeric record
contains a local sequence, CPU, process and peer identities, state, wait
reason, root, saved SP, and event-specific auxiliary value. Writers never
print; a record publishes its sequence last, so a fail-stop copy skips an
IRQ-interrupted in-progress record and presents committed entries oldest to
newest. `kernel_process_trace_report()` snapshots and prints that same tail on
demand without crashing; it is callable from a fixture or as
`call (void) kernel_process_trace_report()` in GDB. The live report and the
oops report use one row formatter, so their field order cannot drift. Ordinary
boots leave tracing and the report disabled. The current scheduler runs only
on core 0; when real SMP scheduling is introduced, this ABI is intended to
become one independently written ring per CPU rather than a false shared
global order.

### Interactive HTTPd lifecycle checkpoints

PID 1 is the pinned BusyBox `init` applet. It reads `/etc/inittab`, runs the
bounded self-test suite as its `sysinit` action (`/etc/init.sh`), waits for
it, and then keeps an interactive ash alive as a `respawn` entry. That ash
forks and execs the background HTTPd the host harness drives. init stays PID
1 for the life of the kernel: there is no `exec` self-replace and no wrapper
shell between it and the interactive ash. Because
that chain of boundaries used to collapse into one generic "interactive
HTTPd did not become ready" timeout, the kernel now prints a
`persistent shell: <name> pid=<n>` checkpoint at each of fork, child
selected, exec prepare, and exec commit for that HTTPd child specifically
(gated on `kernel_syscall_persistent_shell_active()`, not on any bounded
self-test fork), plus a listener-ready line for the socket boundary.
The view that compares those four lines normalizes the pid to `<child>`:
a pid is minted in creation order rather than read off the process slot,
so its value counts how many processes the boot created before this
fixture, which is a fact about fixture order and not about the lifecycle.
That all four checkpoints name the *same* child is enforced in the kernel
-- the last three log only on a match against the pid the fork checkpoint
recorded -- so the view does not need the number to say it.
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
  recovery, repeated requests, and exact HTML/PNG bodies and content types;
- the interactive HTTPd child's own fork/child-selected/exec-prepare/
  exec-commit/listener-ready lifecycle checkpoints, in order (see
  "Interactive HTTPd lifecycle checkpoints" above);
- the ext2-resident `init.sh` scenario, run as BusyBox init's `sysinit`
  action, including connected socket I/O,
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
- **RAM discovery uses the boot DTB on both platforms.** RPi5 firmware passes
  its resolved FDT to the resident SD stub, which preserves it across SWD
  injection. QEMU's direct-kernel loader generates an FDT from the selected
  machine and `-m` value and passes its physical address in `x0`. Both
  platforms read the `/memory` node through the bounded common reader in
  `kernel/boot/fdt.tkb`; an invalid DTB or missing usable memory node is a
  fatal boot-contract violation, not a reason to switch data sources. Neither
  platform's
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

## Kernel text log and multicore publication boundary

`kernel_boot_log()` writes its unchanged text to UART and retains the same
logical line in a fixed 256-record ring. Each record carries the architectural
monotonic-counter time of its first byte; BusyBox `dmesg` retrieves a bounded
snapshot through Linux `syslog(2)`. The printed form is
`[ssssss.uuuuuu] text`. A record retains at most 160 text bytes, and both a
long-line truncation and overwritten oldest records are reported explicitly.
The ring and its 64-KiB formatting snapshot are static storage: logging does
not allocate.

The retained text ring deliberately has one writer: core 0 ordinary
main/syscall context. A `kernel_boot_log()` call from another core remains
live-UART-only and is not retained. Interrupt-context diagnostics continue to
use the fixed-width diagnostic event ring; crash and DDB output continue to
use their direct polled UART path. This is a correctness boundary, not a claim
that the current arrays are accidentally safe under concurrent writes.

A future multicore text writer must reserve a monotonically increasing record
sequence atomically, write timestamp/CPU/text into the reserved slot, then
publish that sequence with release ordering. Readers must acquire the
publication word, reject overwritten or half-published sequences, and order
records by sequence rather than by arrival at UART. CPU id belongs in record
metadata even if the default display initially omits it. A single global
spinlock around UART plus the ring is not the intended extension: a stalled
polled console must not become the serialization mechanism for retaining
diagnostics from another core.

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

- **Execution model: one core, and a kernel that does not preempt.** Most
  of `kernel/` shares mutable state with no lock. That is correct today
  because there is exactly one kernel execution context, which rests on
  three separate facts: only core 0 runs kernel code (core 1 reaches EL1,
  proves it can see the shared page table, and parks); a timer interrupt
  taken inside a syscall only *requests* a reschedule, so the switch
  happens on the way out and a handler always runs to completion
  (Linux's `CONFIG_PREEMPT_NONE`); and interrupt handlers touch no shared
  state, which the effect system enforces by rejecting `locks` on an
  `!{interrupt}` function. The first two are constants in
  `kernel/lib/execution_model.tkb` and nine files assert them, so changing
  either one fails the build at every site that depends on it rather than
  becoming a race. See GitHub issue #453.
- **Filesystem.** One ext2 block group, nested path lookup, root-directory
  mutation, allocation bitmaps, and fast symlinks. Regular-file reads cover
  twelve direct blocks plus single- and double-indirect blocks; the maximum
  is derived from the 1-KiB block geometry rather than a file-size literal.
  Writes and truncates remain limited to one direct block. Directories and
  symlinks remain one block, and there are no additional block groups.
- **Processes.** A pooled `ProcessRecord` scheduler table with no
  process-count ceiling, with lazily backed kernel stacks and directly owned
  address-space page tables, all on core 0.
  Core 1 proves autonomous EL1 entry and shared-MMU visibility, then parks.
  `execve` resolves `argv[0]` as an ext2 path, validates a bounded ELF
  metadata window, and streams each PT_LOAD page from the file. Static
  BusyBox applets such as `/bin/echo` are hard links to its ELF, so their
  argv[0]-driven multi-call dispatch works without a separate registry; an
  `argv[0]` naming no ext2 file falls back to that same static image, which
  is what makes a bare applet name work after ash's own `PATH` search. The
  pathname is a separate question and is answered before that fallback is
  reached: an absent one is `ENOENT`, not a fallback. `wait4` blocks
  the caller until its live child exits (by specific pid or `-1`/
  `WAIT_ANY`), delivering the real reaped pid and exit status, tracked
  per-slot so any live process (not just the tree root) can wait for its
  own child. A process may have as many children as the page allocator
  allows (issue #437), each keeping its own exit status: an exited child
  stays as a zombie until `wait4` collects it, and `wait4(pid)` selects
  among siblings. `wait4(-1)` takes the newest zombie rather than the
  earliest, matching Linux's "some terminated child" rather than promising
  an order. The two process-GROUP selectors Linux also accepts here,
  `pid == 0` and `pid < -1`, are `EINVAL` rather than wrong answers,
  because there are no process groups yet to select over. A parent that never waits keeps its zombies until its own exit
  drains them, which is also Linux's behaviour.
  Scheduling is a round-robin over the process TREE: a process's successor
  is its first child, else its next sibling, else the nearest ancestor's
  next sibling, else the root, and the rotation skips whoever is not
  runnable. A process therefore
  keeps its turn even when the process next to it is blocked -- which is what
  a shell script that starts a background daemon needs, since it parks a
  `wait4` between the interactive shell and the daemon. Each switch re-arms
  the scheduler tick, so the incoming process starts a whole quantum rather
  than inheriting the remainder of the outgoing one's -- without that, a
  switch taken at syscall return (because the tick landed inside a syscall)
  systematically shortchanged whichever process follows a syscall-heavy one
  in the rotation, measured at 2.3x between two identical CPU-bound
  processes. UART `read(2)`
  blocks and wakes on received input, sufficient for the foreground
  interactive BusyBox ash REPL; there is no controlling-TTY job control. A
  process waiting for UART input yields whenever anything else is runnable,
  and the arriving byte is delivered to the waiter wherever it sits in the
  process tree, including a sibling's; only when nothing else can run does
  the kernel wait for the byte in place. An exiting process hands the CPU
  to its parent when the parent is waiting for it, and to whoever the
  scheduler picks otherwise -- which is what a background job needs, since
  its parent is off at its own prompt. An exit that would leave nothing at
  all runnable waits for an interrupt and asks again instead of proceeding.
- **Signals.** Signal state is recorded honestly, but no signal is ever
  delivered, so an installed handler is never invoked. Two consequences are
  worth naming because they decide what a shell script can do here.
  BusyBox `init`'s `respawn` works anyway: `rt_sigtimedwait` returns
  `-ENOSYS`, so its main loop falls through to a `waitpid(-1, WNOHANG)`
  reap and restarts the entry that died. Ash's `wait` builtin does not:
  it polls with `WNOHANG` and then calls `sigsuspend` to wait for
  `SIGCHLD`, so `wait` never returns. A script here must not use it.
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
- **RPi5's ARM generic timer is not configured by its firmware.**
  `MRS CNTFRQ_EL0` there returns a DIFFERENT value on different reads --
  measured on hardware, from one `mrs` whose result fed two stored fields
  that came out 0 and 43750. `timer_tick_rearm` derives the scheduler tick
  from that register on every tick (`read_cntfrq() >> 6`), so the time slice
  on that board is a fresh arbitrary number, and so is every other
  `read_cntfrq()`-derived deadline: the network timeouts, and the PCIe and
  USB bring-up delays. `CNTPCT_EL0` is no better -- its absolute value stays
  under 2^17 sixteen seconds into a boot and is not monotonic across a run,
  while short deltas over a fixed loop are stable to four digits. The kernel
  works and every fixture passes (the busy-pair fairness assertion counts
  syscall-reported rounds, not ticks) but no timeout on that board means
  what its source says it means, and no tick-derived number from it should
  be believed.

  The device tree does not fix this: its `/timer` node carries no
  `clock-frequency`, on this board's pinned firmware blob or in QEMU's
  generated one, because a board whose firmware programs `CNTFRQ_EL0` does
  not need one. It does describe a second counter -- a BCM2835-style system
  timer, 64-bit, free-running, memory-mapped, with its own rate stated on
  the node -- which is what a second opinion about this would be read from.
  Nothing reads it yet.
- **Waiting for the network happens inside the kernel, except in
  `accept`.** The TCP receive path still waits for a frame in a bounded
  in-kernel loop, and since kernel mode does not preempt, every other
  process stops for the duration. `accept(2)` asks first whether anything
  else could run. When nothing can, it waits in the kernel as before, which
  costs nothing. When something can, it takes the handshake one step, parks
  the half-finished handshake on the listener, and BLOCKS the calling
  process -- off the run queue, holding neither the receive capability nor
  a descriptor -- to be woken on the next scheduler tick and run the same
  syscall again. It does not answer `EAGAIN`: a blocking `accept` that said
  "try again" would not be `accept`, and this kernel's own EL0 fixture
  calls it once and checks the descriptor it gets back.
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
