# Takibi Kernel Safety and Trusted Base

This document states what a successful Takibi kernel build establishes, what
is checked only at runtime, and what remains trusted. It is an engineering
contract, not a mechanized proof or a claim of general memory safety.

The compiler and kernel live in one repository, so actionable ambiguity is
normally a compile error rather than a warning. A successful build is intended
to be a usable result, not a result that depends on somebody reading advisory
diagnostics. This does not imply that every possible kernel fault is currently
expressible or rejected by the type system.

## Four outcomes

| Outcome | Meaning |
| --- | --- |
| Static rejection | Parsing, typing, ownership, effect, exhaustiveness, or an enabled build policy rejects the program. No executable is produced. |
| Generated runtime check | The compiler accepts the program but emits a check whose failure calls `llvm.trap`. This is development-time containment, not the finished form of kernel code. |
| Explicit trusted boundary | An `unsafe` block, raw pointer, MMIO operation, DMA/cache operation, extern declaration, ABI bridge, or assembly file relies on a locally reviewed assumption the checker cannot establish. |
| Outside the language model | Toolchain correctness, hardware behavior, concurrency protocols, resource exhaustion, and other facts described below are not proved by Takibi. |

## What the compiler checks

Refined integers carry a half-open interval and a concrete representation
type. The checker proves only the interval facts supported by its documented
flow and arithmetic rules. Proven array and slice indices need no runtime
bounds check. An unrefined or insufficiently narrowed index generates a check
in permissive builds and is rejected under `--forbid-trap`.

Slices carry a pointer and a minimum length. Checked indexing and subslicing
use that length evidence. Conversion to a raw pointer discards the length and
moves subsequent validity, bounds, alignment, lifetime, and aliasing arguments
into the trusted boundary.

Affine values cannot be duplicated; linear values must additionally be
consumed. Static owner indices prevent an owner for one resource instance from
being substituted for another, and indexed views/borrows preserve the
relationships described in `SPEC.md`. These checks are path-sensitive within
the supported control-flow model. They are not a general lifetime or
separation-logic proof, do not infer arbitrary heap shapes, and do not prove
that an external resource constructor actually owns the hardware resource it
claims.

Effects constrain control flow. `may_block` propagates through resolved calls;
interrupt and exception roots reject reachable blocking operations. Function
pointer effect rows constrain indirect calls. `unsafe` marks a function that
contains a local trusted operation, and whole-program unsafe reachability can
be forbidden. Extern effect declarations are trusted because their bodies are
unavailable. Effects do not prove lock correctness, interrupt latency, or
hardware progress.

Closed variants provide exhaustive matching, and `must_use variant` prevents a
fallible result from being silently discarded. These rules establish handling
of the declared cases, not correctness of the code inside each arm.

`SPEC.md` is the normative language reference for all of these mechanisms.

## Build policy flags

`--forbid-trap` rejects a compilation when the compiler would otherwise emit
one of its recorded runtime trap checks, including unproved checked indexing,
checked refined casts, and exhaustive-enum casts. The decision is made from
type-checker/code-generator evidence rather than optimizer output. Success
therefore means that no such compiler-recorded trap site remains in the
compiled Takibi source set.

It does not inspect raw-pointer accesses, handwritten assembly, extern
implementations, arbitrary LLVM behavior, or hardware exceptions. It cannot
promise that the CPU will never fault. The maintained kernel targets use this
flag, and the exact source union is recovered from their emitted depfiles by
`make trustedbasecheck`.

`--forbid-unsafe` rejects a whole program when an unsafe effect is reachable.
It is stronger than merely requiring each local `unsafe` block to be necessary
and explicitly annotated. It still cannot inspect assembly or an extern body.
The maintained kernel deliberately does not use this flag: low-level boot,
MMIO, DMA, and context-switching code still require reviewed unsafe sites.

Without these flags, a program may contain generated traps or explicit unsafe
operations. That permissive mode is useful for early bring-up, but it is not
the maintained kernel's trap policy.

## Explicit trusted boundaries

Every `unsafe` block is lexically scoped and must justify at least one operation
the checker identifies as unsafe; an unnecessary block is a compile error. The
block says that the author accepts the missing proof for that local operation.
It does not make neighboring operations correct and does not weaken ownership
rules globally.

- Raw pointers and casts trust address validity, bounds, alignment, provenance,
  lifetime, and aliasing as applicable. A string-literal address, a kernel
  memory cast, and an MMIO cast have different rationales and are inventoried
  separately.
- `*io T` supplies volatile access semantics. The register address, width,
  permitted access direction, ordering requirements, and device state still
  come from the platform specification and driver reasoning.
- DMA/cache builtins provide target-specific cache and ordering operations.
  Buffer ownership, descriptor validity, device completion, cache topology,
  and the chosen protocol remain trusted unless represented by separate
  checked types and state transitions.
- `extern fn` and `extern symbol` declarations trust the linked symbol's ABI,
  effects, lifetime behavior, and implementation. Checker-only borrow and
  effect contracts cannot be verified against an unavailable body.
- Boot, exception entry, context switching, user entry, and architectural
  probe assembly trust instruction semantics, register-save conventions,
  stack setup, privilege transitions, and linker placement. Generated layout
  fragments reduce duplicated constants but remain part of the compiler/build
  toolchain assumption.
- LLVM lowering, the assembler, linker scripts, firmware interfaces, and the
  target CPU are trusted to implement the representations and instructions the
  compiler requests.

Private files and narrow interfaces help contain these assumptions, but
containment is not proof of their implementation.

## Important facts not currently proved

Takibi does not currently establish all of the following:

- validity or lifetime of arbitrary raw pointers;
- freedom from data races, deadlocks, priority inversion, or memory-ordering
  mistakes across CPUs, interrupts, and devices;
- absence of stack overflow, resource exhaustion, or nontermination;
- correctness of linker scripts, memory maps, ABI declarations, assembly, LLVM,
  firmware, peripherals, or silicon;
- semantic correctness of protocols, device state machines, filesystems, or
  scheduler policy;
- confidentiality properties such as clearing every byte before exposing a
  page to another protection domain;
- absence of every architectural exception. `--forbid-trap` covers only the
  compiler-recorded checks described above.

Tests and hardware integration checks provide evidence for these properties;
they do not convert them into language theorems.

## Reproducible inventory

Run:

```sh
make trustedbasecheck
python3 scripts/measure_trusted_base.py --verbose
```

The normal output is a concise inventory. The verbose form lists the exact
depfile-derived `--forbid-trap` source union, any kernel `.tkb` file outside
that union, and every unsafe block with its primary syntactic rationale.
Assembly is split into production handwritten, generated, and fixture input;
raw casts, MMIO, extern declarations, and DMA/cache operations are reported as
separate boundaries. Counts intentionally live in generated output rather than
this document so that prose cannot silently become a stale status dashboard.

The classifier is deliberately mechanical. A block containing several kinds
of operation receives one primary category, so the detailed list is a review
queue rather than a semantic proof. A new explicit escape surface must either
fit a documented category or make the inventory report it as unclassified.
Language guarantee changes belong in `SPEC.md` and must also be reflected here
when they change the meaning of a trusted boundary.
