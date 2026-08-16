# takibi - Takibi Language

Takibi is a from-scratch systems programming language and compiler written in
OCaml 5.4.0. It emits native machine code through LLVM 19.

The project is aimed at bare-metal and kernel-space software, where a runtime
panic or silent memory corruption can stop an entire system. Its long-term
goal is to demonstrate that failures in a monolithic Unix-like kernel can be
moved from runtime to compile time with refinement types, affine and linear
ownership, effects, and eventually SMT-backed proof obligations.

The current language syntax and semantics are specified in
[`SPEC.md`](SPEC.md). This README introduces the project; it is not a second
language specification.

## What is in this repository?

The repository has three related layers:

- The compiler in `lib/` and `bin/` parses Takibi, checks its types and
  resource rules, generates LLVM IR, and writes native object files.
- [`examples/`](examples/README.md) preserves the executable language,
  bare-metal, driver, filesystem, scheduler, and networking milestones that
  preceded the standalone kernel. It is historical and is not an actively
  maintained product surface.
- [`kernel/`](kernel/README.md) is the standalone RPi5-first monolithic kernel.
  It runs existing Alpine Linux AArch64 binaries through a growing
  Linux-compatible syscall boundary and currently serves USB-ext2 content
  with BusyBox HTTPd over RP1 Ethernet.

The examples and kernel have separate purposes. Historical example builds may
still be useful as evidence, but new features, fixes, tests, fixtures, and
ports are developed only under `kernel/`, which does not depend on sources
under `examples/`. An example is changed only when that exact historical
artifact is explicitly requested.

## Language direction

Takibi treats a remaining runtime bounds trap as evidence that the program has
not yet expressed enough information for a proof.

- `{lo..<hi as base}` refines an integer range while retaining an explicit
  representation type.
- `affine` and `linear` values express resources that may be consumed at most
  once or exactly once.
- `borrow`, `borrow mut`, indexed owners, and region-tied pointers permit
  temporary access without losing the underlying ownership obligation.
- `&T` and `&mut T` are non-arithmetic, non-forgeable references to a
  struct, distinct from the raw, arithmetic-capable `*T` at the type
  level -- an ordinary "pass by reference to avoid copying" parameter can
  be written this way with no runtime cost and no `unsafe`.
- closed variants describe fallible operations without integer sentinels;
  `must_use variant` makes ignoring an outcome a compile error.
- effect rows such as `!{may_block}`, `!{interrupt}`, and `!{unsafe}` expose
  operations that matter to low-level callers.
- `unsafe { ... }` is an auditable boundary, not an implicit escape from
  checked indexing.

Ordinary compilation may insert a runtime check for an access whose bounds are
not proven. `--forbid-trap` turns every remaining such site into a compile
error. New kernel code is written under that policy from the start.

For details, see:

- [`SPEC.md`](SPEC.md) - current syntax, types, statements, and semantics;
- [`TAKIBI_CORE.md`](TAKIBI_CORE.md) - the long-term unified core model;
- [`OWNERSHIP_KERNEL.md`](OWNERSHIP_KERNEL.md) - ownership checker design and
  current limitations;
- [`HISTORY.md`](HISTORY.md) - the engineering history and hardware debugging
  record.

## Current status

The compiler has a lexer, Menhir parser, HM-style inference core, refinement,
effect, ownership, static-index, privacy, and authority-region checks, and an
LLVM 19 backend. The test suite covers both accepted programs and compile-time
rejections.

The historical example suite records language use from arithmetic and
aggregates up to preemptive scheduling, FAT12, SD and USB storage, Ethernet
DMA, TCP/IP, HTTP, and persistent key-value servers. See
[`examples/README.md`](examples/README.md) when reproducing those artifacts;
their continued compatibility is not part of active kernel maintenance.

The standalone kernel boots at EL1 on RPi5, runs userspace at EL0, manages
typed pages and mappings, mounts ext2 through USB Mass Storage, implements the
Linux AArch64 syscall subset reached by the current workloads, dynamically
loads Alpine BusyBox plus musl, and passes a real container-to-board `curl`
test. See [`kernel/README.md`](kernel/README.md) for its architecture, current
limitations, and hardware procedure.

## Quick start

The provided devcontainer is the easiest way to obtain the exact compiler and
hardware tooling. For the compiler required by the kernel:

```bash
make build       # build the Takibi compiler
make test        # run compiler unit tests
make allbuild     # build EVERYTHING (compiler, kernel/, linux_user/, every examples/ target) -- no execution/hardware step, cheapest full-repo sanity check
```

For the maintained kernel surface:

```bash
make kernelbuild-rpi5  # build without physical hardware
make kernelcheck-rpi5  # run the destructive RPi5 hardware integration suite
```

Historical example targets remain documented under `examples/`, but are not
part of the maintained acceptance surface. The RPi5 kernel hardware procedure
and its USB-drive safety warning are documented in:

- [`kernel/README.md`](kernel/README.md) for the standalone RPi5 kernel.

Builds are parallel by default. Pass `-j1` when serial output is more useful
for diagnosing a failure.

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
[`SPEC.md`](SPEC.md) for source syntax and [`examples/README.md`](examples/README.md)
for working programs.

## Repository layout

```text
bin/       compiler CLI
lib/       parser, type checking, ownership/refinement analysis, LLVM backend
test/      compiler unit tests
examples/  executable language and bare-metal proofs
kernel/    standalone Linux-compatible monolithic kernel
scripts/   integration, hardware, image, and profiling helpers
```

## Primary dependencies

```text
OCaml 5.4.0, dune, menhir, ppx_deriving.show
LLVM 19 libraries and command-line tools
```

Kernel real-hardware workflows need the additional tools listed in
[`kernel/README.md`](kernel/README.md). The `.devcontainer/` configuration
contains the maintained development environment. Historical QEMU and board
workflows remain described under `examples/` for reproduction only.

## Prior art

Takibi is not an implementation of a single existing language. Its direction
draws on refinement typing, linear logic, ATS-style proof-driven systems
programming, separation logic, typestate, and effect systems. Rust's ownership
model was evaluated but was not selected as the base for the kernel experiment;
Takibi instead develops a smaller language whose resource and proof model can
be extended together. [`TAKIBI_CORE.md`](TAKIBI_CORE.md) records the intended
unification and references.

## Acknowledgements

The project uses OCaml, Menhir, LLVM, QEMU, OpenOCD, and the hardware and
filesystem tooling named in the subtree documentation.

## License

See [`LICENSE`](LICENSE).
