# Takibi

Takibi is a from-scratch systems language and a Linux-ABI-compatible
monolithic kernel, designed and developed together, to turn kernel runtime
failures into compile-time errors.

The compiler is written in OCaml and emits native code through LLVM 19. The
kernel boots on QEMU/AArch64 and Raspberry Pi 5 with several cores, runs
existing Alpine AArch64 binaries (BusyBox, musl) unmodified at EL0, mounts an
ext2 root, and serves files with BusyBox HTTPd over its own TCP/IP stack.

Takibi is a research prototype, not a production operating system, and its
purpose is not to reproduce Linux. It is to exercise a new language against
real kernel problems -- processes, virtual memory, filesystems, drivers,
interrupts, DMA, networking, and system-call boundaries -- and move the
failures found there into the type system.

## See it run in QEMU

The commands below assume Debian GNU/Linux stable. Everything needed comes
from apt and opam.

```bash
# System packages: LLVM 19, QEMU, filesystem tools, Python, Java
sudo apt install opam cmake llvm-19 llvm-19-dev lld-19 libzstd-dev \
    qemu-system-arm qemu-user ipxe-qemu gdb-multiarch curl \
    mtools cpio e2fsprogs e2tools python3-serial openjdk-21-jre-headless

# OCaml 5.4 and the project's dependencies
opam init
opam switch create takibi 5.4.0
eval $(opam env --switch=takibi)
opam install --deps-only --with-test .

# The TLA+ model checkers and z3, which the build and the tests use
bash scripts/fetch_model_tools.sh
```

Then:

```bash
make kernelsh-qemu
```

This builds the compiler, the kernel and the root filesystem image, starts
QEMU, and after the `interactive shell: uart blocked` marker shows the
BusyBox ash prompt. init starts HTTPd by itself, so opening
<http://127.0.0.1:18080/> in a browser serves a page from the ext2 root
through Takibi's syscall, socket, virtio-net and TCP/IP paths. Set
`KERNEL_QEMU_SHELL_HTTP_PORT` to choose another host port. Press Ctrl-] to
leave the serial console.

For a non-interactive verification of the same kernel:

```bash
make kernelcheck-qemu
```

This boots the kernel, runs its ext2, BusyBox, process and network fixtures,
drives a host-side ARP/ICMP/TCP peer, and checks the results. It needs no
board, SWD probe, physical NIC or raw-socket privileges.

Raspberry Pi 5 is the real-hardware authority for USB Mass Storage, RP1
Ethernet, DMA and cache behavior, and interrupt timing, but it is not needed
to start. Its wiring, its destructive-storage warning, its test procedure and
the development container are in [`kernel/README.md`](kernel/README.md).

## Why make another systems language?

Memory safety is necessary for a kernel, but it is not the whole kernel-safety
problem. A kernel can compile cleanly and still fail because it:

- indexes a hardware- or wire-derived value outside a buffer;
- frees the wrong pool's object, reuses a stale handle, or drops a resource;
- blocks, allocates, or logs from an interrupt context;
- lets the CPU touch a buffer while a DMA device owns it;
- validates a userspace address against the wrong process address space;
- copies partially initialized kernel memory to userspace;
- lets a handwritten exception-frame layout drift from generated code.

Existing systems languages make different and valuable tradeoffs, but Takibi
wants these kernel-specific obligations to be first-class and extensible.
Building a small language and a kernel together lets a real kernel incident
decide the next type rule or proof obligation, and apply it back at the call
site that exposed the problem. The goal is stronger than "written in a
memory-safe language": wherever the language has enough information to prove
a property, an invalid resource transition or an unproved access does not
compile. Raw hardware boundaries still exist; Takibi makes them explicit and
auditable instead of pretending they disappeared.

## Lightweight by design

Strong guarantees about a program's correctness usually cost annotations,
invariants and proof text that outweigh the implementation. Takibi aims at a
different point: removing whole classes of defects across the entire kernel,
at an annotation cost close to that of ordinary typed code. It follows the
lightweight formal methods tradition -- broad guarantees bought cheaply with
types and bounded model checking -- and builds it into the language instead
of adding it beside the code.

- **Types first, and cheap ones.** Refinements, ownership and effects are
  inferred, or carried by one signature, wherever possible. A check that
  needs an annotation at every call site is a design smell.
- **Bounded model checking for protocols.** Concurrency protocols are
  modelled, and the code is tied to the model by types or by replaying real
  runs. The result is bounded evidence, and the project says so rather than
  calling it a proof.
- **Heavy only where trust concentrates.** Stronger reasoning is spent on
  the few places where raw authority is minted and on lock-free protocols,
  not spread across the kernel.
- **Measured, not assumed.** The claim is how many defect classes are
  excluded, and at what annotation cost, with the remaining trust listed in
  [`TRUSTED_BASE.md`](TRUSTED_BASE.md) at its real strength.

## Why build a Linux-compatible kernel?

A toy kernel with its own applications can avoid every difficult interface.
An existing Linux userspace cannot. Running Alpine's BusyBox and musl forces
Takibi to implement the observable process, virtual-memory, filesystem,
descriptor, socket and blocking semantics that real software already
depends on.

Linux ABI compatibility is therefore the project's workload and
compatibility boundary, not an attempt to duplicate Linux feature for
feature. A real workload supplies two kinds of evidence: the kernel runs
nontrivial software it did not invent, and the bugs and awkward contracts
found on the way are genuine systems problems worth moving into the
language. The HTTP demo is one turn of that loop: an existing BusyBox binary
reaches the ELF loader, per-process address spaces, copy-on-write, ext2,
descriptor lifecycle, sockets, blocking receive and the network driver
through the Linux AArch64 syscall ABI.

## How Takibi's quality is kept

Takibi's checking has three layers, each with its own subject. Syntax and
details keep changing, so this section says only what is checked and by
what.

**1. The language's types check the kernel code.** Takibi's type system
brings together four ideas with long research histories.

- **Refinement types.** The type of an integer or an index carries the range
  of values it can take. An array access whose range is proved generates no
  bounds check; one that cannot be proved is a compile error. The whole
  maintained kernel is built under a policy that admits no unproved access.
- **Linear and affine types.** A value that stands for a resource is
  guaranteed by its type to be consumed exactly once (linear) or at most
  once (affine). Pages, process records, network descriptors and allocator
  handles take this form, so a double free, a forgotten release or a stale
  handle is a compile error. An owner's type carries the index of the thing
  it owns, so one slot's owner cannot stand in for another's.
- **Effect types.** A function's type says whether it may block, whether it
  runs in interrupt context, and whether it crosses a trust boundary. The
  checker rejects context violations such as an interrupt handler taking a
  lock or calling a blocking operation.
- **Types as capabilities.** Per-CPU storage, buffers a device owns, and the
  kernel's own authority are tokens that only their holder can use and that
  cannot escape their scope. A device protocol is written once and generates
  both the owner types and the model for the model checker.

What raw authority remains -- raw pointers, MMIO, DMA setup -- can be minted
only inside a short, named list of files, and the compiler enforces that
list.

**2. A second judge checks the compiler itself.** The type checker decides,
and a separate judge re-checks its conclusions. Every derived integer range
and every initialization interval is written out as a logical obligation,
and an SMT solver (z3) re-checks it as bit-vector arithmetic at the
machine's width; a disagreement fails the build. The solver never decides: a
goal the checker cannot prove is rejected even if the solver could prove it.
The compiler's output is also fuzzed: generated programs are run against an
independent oracle outside the language, which confirms that a program
compiled with traps forbidden never traps and that runtime values stay inside
the ranges their types promised.

**3. Models check the concurrency protocols.** Locks, pools, DMA rings and
the stop of every core are modelled in TLA+ and checked, within bounds, by
TLC and Apalache. Model and code are tied together by generated types or by
replaying real execution traces. Arm's weak memory ordering is checked with
herd7 litmus tests. The result is bounded evidence, not a proof.

On top of these sit deterministic QEMU test lanes (including kernels built to
reproduce a race window), a multicore Raspberry Pi 5 hardware lane, and
checks of the build products themselves (the trusted-base ledger, a budget
on raw authority sites, lock ordering, and more). The trust that remains is
listed in [`TRUSTED_BASE.md`](TRUSTED_BASE.md) at its real strength.

## A defect happens once

Having these three layers in one project is what makes Takibi's development
process strong. Each time a defect is fixed, the means of never meeting its
class again are tried from the strongest down: a type-checker rule, then a
model check, then a build-time check, then a test. Which one was taken, and
why a stronger one could not be, is recorded before the fix reaches main.

The same procedure applies to the compiler and to the kernel. A kernel defect
becomes a new type rule; a compiler defect, such as a mistake in a range
rule's arithmetic, is caught per instance by z3. Without a language of its
own, a project has no path from a kernel incident to a new language rule.
[`HISTORY.md`](HISTORY.md) and [`DECISIONS.md`](DECISIONS.md) are that
record: which real bugs produced which rules.

## Current kernel

The maintained kernel provides:

- AArch64 EL1 boot on QEMU `virt` and Raspberry Pi 5, on several cores;
- EL0 processes loaded from existing AArch64 ELF binaries, demand-grown page
  tables, and copy-on-write fork;
- the Linux AArch64 syscall subset the BusyBox and musl workloads use,
  including signals, pipes, ppoll, mmap and the process hierarchy;
- a read-write ext2 root over QEMU virtio-blk or Raspberry Pi 5 USB Mass
  Storage;
- BusyBox init, ash and HTTPd, with interactive UART input;
- ARP, IPv4, ICMP, TCP, sockets and blocking receive over virtio-net and RP1
  GEM Ethernet;
- typed page, process, descriptor, network and allocator resources;
- a kernel debugger reached over the UART, crash snapshots, and QEMU lanes
  with DWARF.

The syscall subset and its deliberately partial semantics are in
[`kernel/SYSCALLS.md`](kernel/SYSCALLS.md); the current limits are in
[`kernel/README.md`](kernel/README.md). Not implemented: preemption inside
the kernel (in progress), threads, a general VFS, broad Linux compatibility,
and production hardening.

## Repository map

```text
bin/         compiler CLI
lib/         parser, type checking, ownership and refinement analysis, LLVM backend
test/        compiler acceptance/rejection and LLVM IR tests
linux_user/  host-native executable tests for hardware-independent code
kernel/      the maintained Linux-compatible monolithic kernel
scripts/     integration, hardware, debugging and measurement helpers
docs/        design documents and measurement records
```

New features belong under `kernel/`. Hardware-independent executable tests
of language features and reusable algorithms belong in `linux_user/`. The
exact maintenance and test-tier policy is in [`AGENTS.md`](AGENTS.md).

## Build and test

```bash
make build              # the OCaml compiler
make test               # compiler acceptance/rejection and IR tests
make linuxcheck         # host-native Takibi tests and the compiler fuzzer
make langcheck          # the fast gate: language and build checks
make kernelcheck-qemu   # boot the kernel and verify it
make modelcheck         # TLA+ and litmus
make allcheck           # everything, before a change reaches main
```

Builds are parallel by default. The Raspberry Pi 5 integration targets
reformat their dedicated USB drive, so do not run them to explore the
project; their procedure is in [`kernel/README.md`](kernel/README.md). The
compiler's flags are generated into [`CLI.md`](CLI.md).

## Documentation

- [`SPEC.md`](SPEC.md) -- language syntax and semantics;
- [`TAKIBI_CORE.md`](TAKIBI_CORE.md) -- the long-term ownership and proof
  model, and the solver boundary;
- [`EFFECTS.md`](EFFECTS.md) -- the effects;
- [`WORDS.md`](WORDS.md) -- keywords and built-in names;
- [`CLI.md`](CLI.md) -- compiler flags;
- [`TRUSTED_BASE.md`](TRUSTED_BASE.md) -- the trust that remains;
- [`OWNERSHIP_KERNEL.md`](OWNERSHIP_KERNEL.md) -- the ownership checker's
  design and known limitations;
- [`docs/VERIFICATION_DESIGN.md`](docs/VERIFICATION_DESIGN.md) -- the design
  of the z3 re-check;
- [`docs/COMPILER_FUZZING.md`](docs/COMPILER_FUZZING.md) -- the compiler
  fuzzer;
- [`docs/BUILD_CHECKS.md`](docs/BUILD_CHECKS.md) -- the complete inventory of
  build checks;
- [`kernel/README.md`](kernel/README.md) -- kernel architecture, QEMU,
  Raspberry Pi 5, the development container;
- [`kernel/SYSCALLS.md`](kernel/SYSCALLS.md) -- the syscall support matrix;
- [`kernel/models/README.md`](kernel/models/README.md) -- the TLA+ models and
  their ties to the code;
- [`ROADMAP.md`](ROADMAP.md), [`DECISIONS.md`](DECISIONS.md),
  [`HISTORY.md`](HISTORY.md) -- plan, decisions, history;
- [`AGENTS.md`](AGENTS.md) -- maintenance and test-tier policy.

## Prior art

Takibi is not an implementation of a single existing language. Its direction
draws on refinement typing, linear logic, ATS-style proof-driven systems
programming, separation logic, typestate, effect systems, lightweight formal
methods and model checking, safe-language OSes, and formally verified
kernels. The project deliberately uses a small new language so its resource
and proof model can evolve with the kernel experiment; that choice is a
research tradeoff, not a claim that existing systems languages have no value.

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

## License

Takibi is distributed under the [GNU General Public License version 3](LICENSE),
with an additional permission, the
[Takibi Compiler Output Exception](COMPILER_OUTPUT_EXCEPTION.md): programs
compiled with the Takibi compiler may be distributed under terms of their
own choice. The compiler, the kernel and every other file stay under the
GPLv3.

Commercial licenses for Takibi, for uses the GPLv3 does not fit, are
available on request; please contact the maintainer, Kiwamu Okabe
<kiwamu@metasepi.org>.

Contributions are accepted under the
[Takibi Contributor License Agreement](CLA.md).

## Sponsoring

Takibi is developed under [Metasepi](https://github.com/metasepi), a
long-running project to redesign a Unix-like operating system with strong
compile-time checking. You can support the work through
[GitHub Sponsors](https://github.com/sponsors/metasepi/).
