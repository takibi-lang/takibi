# Takibi

Takibi is a from-scratch systems language and a monolithic,
Linux-ABI-compatible kernel designed together to turn kernel runtime failures
into compile-time errors.

The compiler is written in OCaml and emits native code through LLVM 19. The
kernel boots on QEMU/AArch64 and Raspberry Pi 5, runs existing Alpine AArch64
userspace binaries at EL0, mounts ext2, and serves files with BusyBox HTTPd over
its own TCP/IP stack.

Takibi is a research prototype, not a production operating system. Its purpose
is not to reproduce all of Linux. It is to exercise a new language against
real kernel problems -- processes, virtual memory, filesystems, drivers,
interrupts, DMA, networking, and system-call boundaries -- and move failures
found there into the type system.

## See it run in QEMU

The repository devcontainer is the shortest route: it contains the maintained
OCaml, LLVM 19, QEMU, filesystem, and Python tooling used by the project. Open
the repository in the devcontainer, then run:

```bash
make kernelsh-qemu
```

Wait for the `interactive shell: uart blocked` marker and the `/ #` BusyBox ash
prompt. In that shell, start the unmodified Alpine BusyBox Extras HTTP server:

```sh
httpd -f -p 8080 -h / &
```

Open <http://127.0.0.1:18080/> in a browser. QEMU forwards that host port to
the kernel's `192.168.20.2:8080`; the page is read from the ext2 root filesystem
and served through Takibi's syscall, socket, virtio-net, and TCP/IP paths.

If the browser runs outside the devcontainer, forward port 18080 from the
container first. Set `KERNEL_QEMU_SHELL_HTTP_PORT` to choose a different host
port. Press Ctrl-] to leave the serial console.

For a non-interactive verification of the same kernel target:

```bash
make kernelcheck-qemu
```

This builds and boots the kernel, runs its ext2/BusyBox/process/network
fixtures, drives a host-side ARP/ICMP/TCP peer, and checks the results. It needs
no board, SWD probe, physical NIC, or raw-socket privileges.

Raspberry Pi 5 is the real-hardware authority for USB Mass Storage, RP1
Ethernet, DMA/cache behavior, and interrupt timing, but it is not required to
start with Takibi. Its wiring, destructive storage warning, and test procedure
belong in [`kernel/README.md`](kernel/README.md).

## Why make another systems language?

Memory safety is necessary for a kernel, but it is not the whole kernel-safety
problem. A kernel can still compile cleanly and then fail because it:

- indexes a hardware- or wire-derived value outside a buffer;
- frees the wrong pool's object, reuses a stale handle, or drops a resource;
- blocks, allocates, or logs from an interrupt context;
- lets the CPU touch a buffer while a DMA device owns it;
- validates a userspace address against the wrong process address space;
- copies partially initialized kernel memory to userspace;
- lets a handwritten exception-frame layout drift from generated code.

Existing general-purpose systems languages make different and valuable tradeoffs,
but Takibi needs these kernel-specific obligations to be first-class and
extensible. Building a small language and kernel together lets a real kernel
incident drive the next refinement, ownership rule, effect, or proof
obligation, then apply it back at the call site that exposed the problem.

The goal is stronger than "this code used a memory-safe language." It is to
make an invalid kernel resource transition or unproved access impossible to
compile wherever the language has enough information to prove the property.
Raw hardware boundaries still exist; Takibi makes them explicit and auditable
instead of pretending they disappeared.

## Why build a Linux-compatible kernel?

A toy kernel with custom applications can avoid every difficult interface. An
existing Linux userspace cannot. Running Alpine BusyBox and musl forces Takibi
to implement observable process, VM, filesystem, descriptor, socket, and
blocking semantics that real software already depends on.

Linux ABI compatibility is therefore the project's workload and compatibility
boundary, not an attempt to duplicate Linux feature for feature. Each real
workload supplies two kinds of evidence:

1. the kernel is capable of running nontrivial software it did not invent; and
2. the bugs and awkward contracts found while doing so are genuine systems
   problems worth moving into the language.

The HTTP demo is one example of that loop: an existing BusyBox binary reaches
the ELF loader, private process address spaces, copy-on-write pages, ext2,
file-descriptor lifecycle, sockets, blocking receive, and the network driver
through the Linux AArch64 syscall ABI.

## What Takibi checks

Takibi combines refinement types, affine and linear ownership, indexed owners,
closed variants, references, and effects. These are compile-time mechanisms;
they do not add garbage collection or transparent exception handling to the
kernel.

### Proved indices instead of runtime bounds traps

`{lo..<hi as base}` is an integer whose range and representation are known to
the type checker. A proven array access generates no bounds check. An ordinary
unrefined integer, such as a value read from MMIO or a packet, remains checked.

```takibi
let mut bytes: [u8; 64];

fn clear(index: {0..<64 as usize}) {
    bytes[index] = 0;
}
```

On bare metal, a failed bounds check becomes a trap rather than a recoverable
application exception. `--forbid-trap` turns every remaining unproved bounds
site into a compile error. All maintained kernel `.tkb` code is built under
that policy.

### Linear values for kernel resources

A `linear` value must be consumed exactly once. Static indices tie an owner to
the resource instance it represents, so an owner from one slot or pool cannot
silently stand in for another.

Real kernel declarations use this shape for pages, address-space identifiers,
network descriptors, process-image pages, and allocator handles:

```takibi
linear struct PageOwner[page: usize] {
    private index: usize @ page;
}
```

A value that must be checked but does not own a linear runtime resource uses a
`must_use variant`; callers must match, return, or transfer every outcome.

### Effects expose dangerous execution contexts

Function types carry effects such as `may_block`, `interrupt`, and `unsafe`:

```takibi
fn virtio_net_irq_handler() !{interrupt} { ... }
fn net_rx_wait() !{may_block} { ... }
```

This gives the checker a place to reject context violations instead of relying
only on comments and call-graph review. The effect system is still growing;
the current guarantees and limitations are specified in [`SPEC.md`](SPEC.md).

### Explicit trusted boundaries

`&T` and `&mut T` are non-arithmetic, non-forgeable references. Raw pointers,
MMIO mappings, address construction, DMA setup, and the remaining handwritten
assembly use explicit `unsafe` boundaries where necessary. The project does
not claim that a successful build proves the compiler, target lowering,
hardware, or every unsafe boundary correct. Defining and shrinking that trusted
base is active work; see [`ROADMAP.md`](ROADMAP.md).

## Current kernel

The maintained kernel currently provides:

- AArch64 EL1 boot on QEMU `virt` and Raspberry Pi 5;
- EL0 processes loaded from existing AArch64 ELF binaries;
- demand-grown user page tables, private fork copy-on-write, and preemption;
- a Linux AArch64 syscall subset driven by the pinned BusyBox/musl workloads;
- an ext2 root filesystem over QEMU virtio-blk or RPi5 USB Mass Storage;
- BusyBox ash and HTTPd, including interactive UART input;
- ARP, IPv4/IPv6, ICMP, TCP, sockets, and blocking receive;
- virtio-net on QEMU and RP1 GEM Ethernet on RPi5;
- typed page, process, descriptor, network, and allocator resources;
- QEMU integration, interactive-shell, DWARF, crash-snapshot, and negative-path
  test lanes.

The syscall subset and its deliberately partial semantics are documented in
[`kernel/SYSCALLS.md`](kernel/SYSCALLS.md). The kernel is single-scheduler-core
today; real SMP, complete signals, a general VFS, broad Linux compatibility,
and production hardening are not implemented. See
[`kernel/README.md`](kernel/README.md) for the current architecture and exact
limitations rather than inferring them from the headline above.

## Repository map

```text
bin/         compiler CLI
lib/         parser, type checking, ownership/refinement analysis, LLVM backend
test/        in-process compiler acceptance/rejection and LLVM IR tests
linux_user/  fast native Linux/AMD64 executable tests for hardware-independent code
kernel/      maintained Linux-compatible monolithic kernel
examples/    historical language and bare-metal milestones
scripts/     integration, hardware, debugging, and measurement helpers
```

New product and feature work belongs under `kernel/`. Hardware-independent
runtime tests for compiler/language features and reusable algorithms belong in
`linux_user/`. The `examples/` tree preserves historical QEMU and real-hardware
milestones and is kept building, but it is not a target for new features. See
[`AGENTS.md`](AGENTS.md) for the precise maintenance and test-tier policy.

## Build and test

The devcontainer is the maintained environment. To build the compiler and run
the fastest checks:

```bash
make build       # build the OCaml compiler
make test        # compiler acceptance/rejection and IR tests
make linuxcheck  # build and execute host-native Takibi tests
```

For the maintained kernel:

```bash
make kernelbuild-qemu        # build QEMU/AArch64 without executing it
make kernelcheck-qemu        # build and run the hardware-independent kernel suite
make kernelcheck-qemu-debug  # run the same suite with DWARF information
make kernelbuild-rpi5        # cross-build the real-hardware kernel
```

To check that a change still builds every maintained and historical target
without executing QEMU or touching hardware:

```bash
make allbuild
```

Builds are parallel by default. The RPi5 integration targets require the exact
hardware setup in [`kernel/README.md`](kernel/README.md); do not run them merely
to explore the project, because the storage lane reformats its dedicated USB
drive.

## Compiler command line

After `make build`, the compiler is available at
`_build/default/bin/main.exe`:

```text
takibi <file1.tkb> [file2.tkb ...] -o output.o
       [--target <triple>] [--cpu <cpu>] [--features <features>]
       [-g] [--profile-functions] [--forbid-trap] [--forbid-unsafe]
       [--emit-exception-frame-offsets <StructName>]
       [--emit-struct-layout <StructName>] [--emit-depfile <path>]
       [--version]
```

Multiple source files currently form one flat compilation unit. `use
"path/file.tkb";` resolves source dependencies before compilation. See
[`SPEC.md`](SPEC.md) for the current language rather than treating examples or
old history as syntax documentation.

## Project direction

The near-term work is organized around a loop between kernel requirements and
language guarantees:

- finish and adopt a count-unbounded, page-backed intrusive object pool;
- make QEMU CI and kernel-aware debugging the default development safety net;
- define and reduce the compiler/kernel trusted base;
- turn real dangling-owner, interrupt-context, DMA, and userspace-copy risks
  into static obligations;
- keep exercising those mechanisms through visible BusyBox and filesystem
  workloads;
- approach real SMP only after shared allocator/MMU state has enforced
  synchronization contracts.

[`ROADMAP.md`](ROADMAP.md) is a dated issue-level plan. [`HISTORY.md`](HISTORY.md)
records why the current design exists and the real bugs that led to it.

## Contributing

Contributor documentation and an AI-assisted contribution policy are planned.
Until they are in place, please discuss a nontrivial change in a GitHub issue
before implementing it. Small, independently verifiable contributions are much
easier to review than broad refactors, especially in compiler soundness, MMU,
DMA, interrupt, allocator, and concurrency code.

Using an AI coding tool is not by itself a problem, but the contributor remains
responsible for every submitted line, its provenance, its tests, and the
invariant it is meant to preserve. A change that its author cannot explain is
not ready for review.

Hardware is not required for many useful contributions: compiler rejection
tests, diagnostics, `linux_user/` fixtures, QEMU integration, syscall behavior,
and debugging tools all have hardware-independent paths.

## Documentation

- [`SPEC.md`](SPEC.md) -- current language syntax and semantics;
- [`TAKIBI_CORE.md`](TAKIBI_CORE.md) -- long-term unified ownership/proof model;
- [`OWNERSHIP_KERNEL.md`](OWNERSHIP_KERNEL.md) -- ownership checker design and
  known limitations;
- [`kernel/README.md`](kernel/README.md) -- current kernel architecture, QEMU,
  RPi5, and hardware procedures;
- [`kernel/SYSCALLS.md`](kernel/SYSCALLS.md) -- exact syscall support matrix;
- [`ROADMAP.md`](ROADMAP.md) -- current priorities and dependency order;
- [`HISTORY.md`](HISTORY.md) -- chronological engineering record;
- [`examples/README.md`](examples/README.md) -- frozen historical milestones.

## Primary dependencies

```text
OCaml 5.4.0, dune, menhir, ppx_deriving.show
LLVM 19 libraries and command-line tools
QEMU system emulation for AArch64
Python 3 and pyserial
e2fsprogs and e2tools
```

The `.devcontainer/` configuration installs the maintained versions and the
additional real-hardware tools.

## Prior art

Takibi is not an implementation of a single existing language. Its direction
draws on refinement typing, linear logic, ATS-style proof-driven systems
programming, separation logic, typestate, effect systems, safe-language OSes,
and formally verified kernels. The project deliberately uses a small new
language so its resource and proof model can evolve with the kernel experiment;
that choice is a research tradeoff, not a claim that existing systems languages
have no value.

## License

Takibi is distributed under the [GNU General Public License version 3](LICENSE).
