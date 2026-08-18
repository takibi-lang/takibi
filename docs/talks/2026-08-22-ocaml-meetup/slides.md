---
marp: true
theme: default
paginate: true
footer: "OCaml Meeting 2026 in Tokyo - 2026-08-22"
style: |
  section {
    font-family: "Aptos", "Helvetica Neue", sans-serif;
    font-size: 29px;
    padding: 54px 68px;
  }
  section.lead {
    text-align: center;
  }
  h1 { color: #c2410c; }
  h2 { color: #9a3412; }
  strong { color: #c2410c; }
  code { background: #fff7ed; }
  pre { font-size: 21px; }
  footer { font-size: 15px; }
  .small { font-size: 20px; }
---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: "" -->

# Rebuilding a Language and a Kernel

## with OCaml, LLVM, and Generative AI

Takibi Project

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

<!--
Timing: 0:00-0:25

Hello. Takibi is a systems language and a Unix-like kernel that I have been
building with generative AI. My claim today is simple: OCaml, LLVM, and AI
turned out to be an unusually effective combination for this project.
-->

---

# Why redesign this layer now?

Userspace can restart after a crash.

In a monolithic kernel, the same bug may silently corrupt memory.

Yet our kernel interfaces and implementation habits still inherit many
assumptions from **C**.

> What if the kernel's runtime-error surface became a compile-time problem?

<!--
Timing: 0:25-0:55

This is not a claim that C kernels are useless. It is a question about the
design space we stopped exploring. Kernel faults are especially expensive,
so kernel code needs stronger static guarantees, not weaker ones.
-->

---

# Are we at a local maximum?

```text
C-shaped language
      +
C-shaped kernel internals
      +
decades of compatibility constraints
      =
excellent engineering inside an old design envelope
```

Takibi asks what becomes possible if we reopen the **language/kernel pair**.

<!--
Timing: 0:55-1:25

We have become extraordinarily good at engineering inside a design envelope
created for C. The experiment is to reopen both sides together: which kernel
invariants become types, and which language features become necessary only
when a real kernel demands them?
-->

---

# Takibi in one slide

```text
Takibi source (.tkb)
  -> lexer + Menhir parser
  -> inference, refinements, ownership, effects
  -> LLVM 19 IR
  -> AArch64 / x86-64 native code
```

- Compiler: **OCaml 5.4**
- Kernel: monolithic, EL1 on Raspberry Pi 5 and QEMU/AArch64
- Userspace: existing Alpine Linux AArch64 binaries at EL0
- Today: BusyBox + musl, ext2, USB storage, Ethernet, TCP, HTTPd, ash

<!--
Timing: 1:25-2:00

This is real enough to be a useful language-design instrument. On an RPi5 it
serves a file from USB ext2 with an unmodified BusyBox HTTP server, over the
real Ethernet controller. QEMU provides a faster integration loop.
-->

---

# Three ingredients, three jobs

| Ingredient | What it buys |
|---|---|
| **OCaml** | Fast, explicit evolution of syntax and static semantics |
| **LLVM** | Real native code without building target backends |
| **Generative AI** | Enough implementation throughput to test ideas end-to-end |

None replaces the others.

Together, they make a language plus kernel feasible at personal-project scale.

<!--
Timing: 2:00-2:30

OCaml is the control plane for semantics, LLVM makes the output real, and AI
compresses the implementation time. AI without strong compiler checks would
only produce more code to distrust. The combination matters more than any one
tool.
-->

---

# The language follows kernel evidence

```text
AI writes a concrete driver / network stack / kernel path
                         |
                         v
Repeated .tkb pattern exposes missing language support
                         |
                         v
OCaml compiler turns the pattern into a checked abstraction
                         |
                         +-----> the next kernel feature gets cheaper
```

**The kernel is not merely a demo. It is the language-design workload.**

<!--
Timing: 2:30-3:05

I did not try to finish a language specification in isolation. We first made
Takibi express real systems code. Patterns repeated across AI-generated code
then told us which compiler feature would remove risk or boilerplate. The
language and kernel form one feedback loop.
-->

---

# AI is a workload generator

Ask AI to implement a **concrete vertical slice**:

```text
packet -> driver -> TCP -> syscall -> unmodified HTTP server
```

Then inspect what its `.tkb` code repeatedly struggles to express:

- repeated guards become refinement rules;
- manual lifecycle flags become linear capabilities;
- ignored status codes become `must_use variant`;
- hidden blocking or privilege becomes an effect.

<!--
Timing: 3:05-3:35

I do not treat generated code as the final authority. I treat it as a very
fast producer of realistic pressure on the language. Repetition is evidence:
when the same defensive pattern appears across drivers and kernel services,
the compiler may need to understand it.
-->

---

# Compile-time evidence in ordinary code

```rust
fn net_rx_release(frame: sink NetRxValidated[desc])
    -> NetRxCanAcquire;

fn checksum_add(data: borrow []u8, sum: i32) -> i32;

let slot: {0..<8 as usize} = index;

must_use variant PageAllocResult {
  OutOfMemory;
  Allocated(PageOwner[page]);
}
```

Ranges, linear ownership, region-tied borrows, exhaustive results,
and effect rows are all source-level obligations.

<!--
Timing: 3:35-4:15

These are representative forms, not a synthetic type-system puzzle. A frame
must be consumed before its receive capability returns. A refined index
proves array access. A must-use variant cannot be silently ignored. Effects
such as unsafe, interrupt, and may_block are explicit as well.
-->

---

# Ownership is larger than pointers

```text
PageOwner[page]       one physical page
NetRxCanAcquire       permission to receive a frame
NetRxValidated[desc]  a checked descriptor-backed frame
ProcessPages[image]   the pages belonging to one process image
```

Takibi's affine and linear values model **authority over resources**.

Memory is one important instance, not the entire abstraction.

<!--
Timing: 4:15-4:45

This is the central reason to experiment with a language rather than simply
copy pointer ownership. Kernel bugs concern descriptors, interrupt states,
DMA buffers, pages, and mappings. Their legal transitions can share one
resource model even when they are not ordinary heap objects.
-->

---

# Memory safety came late - deliberately

1. First-class refinement types and slices arrived early.
2. Networking, storage, and hardware code established the real workload.
3. Ownership then grew around observed resource lifecycles.
4. New kernel code now starts with `--forbid-trap`.

An unproven bounds check is not "done":

```text
remaining runtime trap
    = missing type-level evidence
    = compile error under --forbid-trap
```

<!--
Timing: 4:45-5:20

Postponing the full memory model was risky, but useful: we avoided designing
ownership for imaginary programs. Refinements and slices were introduced
early enough to shape code. The later ownership model could then target real
page, DMA, frame, descriptor, and process lifecycles.
-->

---

# Why not simply Rust or Zig?

They proved that low-level programming can have modern tools.

Takibi asks a different research question:

- Can proof-carrying resource types extend beyond pointer ownership?
- Can ranges eliminate kernel traps rather than merely catch them?
- Can one small language co-design ownership, effects, and future proofs?

This is an experiment, not a claim of production superiority.

<!--
Timing: 5:20-5:50

Rust and Zig are important precedents, not straw men. But Takibi wants a
smaller proof-driven base, influenced by ATS, where arbitrary resources - not
only memory - can carry affine or linear authority. Reusing an existing
language would also constrain the experiment to its existing semantic model.
-->

---

# Why keep the Linux syscall ABI?

Redesign the boundary between **applications** and **hardware** cheaply:

- keep a vast, stable userspace ecosystem;
- replace the kernel implementation and its internal invariants;
- add syscalls only when a real program reaches them;
- translate typed internal results to `-errno` only at the boundary.

Cheaper than designing a new microkernel, IPC model, and application world
all at once.

<!--
Timing: 5:50-6:25

Linux compatibility is a cost-control strategy. It lets BusyBox and musl act
as demanding, existing tests while the kernel beneath them changes. This is
also YAGNI in practice: syscall coverage grows from observed workloads rather
than from implementing a theoretical complete table.
-->

---

# One vertical slice, end to end

```text
Alpine BusyBox + musl (unmodified AArch64 binaries)
              |
        Linux syscall ABI
              |
 processes / VM / ext2 / TCP / USB / Ethernet
              |
     QEMU virtio or Raspberry Pi 5 hardware
```

The same kernel boots a shell and runs BusyBox HTTPd.

The host verifies it with a real `curl` request.

<!--
Timing: 6:25-6:55

This is why the project can make meaningful claims about language features.
They survive a complete path through process loading, filesystems, networking,
drivers, interrupts, and hardware - not only small examples.
-->

---

# Test where the truth lives

| Tier | Question | Cost |
|---|---|---|
| OCaml compiler tests | Should this program type-check or be rejected? | milliseconds |
| Native Linux `.tkb` tests | Does target-independent behavior compute correctly? | seconds |
| QEMU / real RPi5 | Are MMIO, IRQ, cache, timing, and concurrency real? | expensive |

> Never replace a hardware claim with a convenient host test.

<!--
Timing: 6:55-7:25

The cheapest test that can tell the truth should own each invariant. Pure
typing belongs in OCaml tests. Algorithms can run natively. Timing, interrupts,
and cache behavior need QEMU or physical hardware - and sometimes only the
physical board is honest.
-->

---

# What was actually difficult?

| Problem | Working response |
|---|---|
| AI proposes plausible but unsound shortcuts | Compile-time policies: `must_use`, effects, `--forbid-trap` |
| QEMU hides hardware failures | Keep real RPi5 tests for MMIO, IRQs, caches, and timing |
| Hardware iteration is slow | Three tiers: compiler tests, native Linux tests, QEMU/RPi5 |
| Scope expands too easily | YAGNI: every feature needs a present workload |
| Context drifts across AI sessions | Specification, engineering log, and executable tests |

<!--
Timing: 7:25-8:00

The main problems were not OCaml problems. They were specification drift,
hardware truth, and managing AI's appetite for plausible generalization. The
answer was to encode policy into the compiler and tests, and to make every new
abstraction answer a concrete failure or repeated code pattern.
-->

---

# OCaml as an AI implementation language

What worked:

- algebraic data types make compiler states explicit;
- exhaustive matches turn forgotten cases into build failures;
- small pure transformations are easy to review and test;
- Menhir, Dune, and the LLVM bindings compose without drama.

Practical prompt pattern:

> Give the AI one invariant, accepted and rejected examples, and the smallest
> relevant compiler phase. Require tests before widening the design.

**OCaml was almost never the obstacle.**

<!--
Timing: 8:00-8:35

AI is especially effective when the host language exposes its mistakes. In
OCaml, changing an AST or type often produces a useful checklist of failed
matches. I ask for both positive and negative tests, and avoid prompts such as
"design the most general ownership system." Concrete invariants work better.
-->

---

# A prompt shape that scales

Give the AI:

1. **one invariant** - "this owner is consumed exactly once";
2. **one accepted program**;
3. **one rejected program and exact diagnostic**;
4. **the smallest compiler phase in scope**;
5. **the real repository-wide build as the finish line**.

Then review the semantic diff, not the volume of generated code.

<!--
Timing: 8:35-9:00

This structure works better than asking for a grand design. Accepted and
rejected examples pin down the boundary. A narrow phase limits collateral
changes. The full build then finds source shapes that neither the human nor
the AI anticipated.
-->

---

# One real rough edge: DWARF

Takibi emits useful DWARF and supports GDB on QEMU, but LLVM's OCaml bindings
do not expose all the metadata APIs needed for natural source debugging.

- no suitable `dbg.value` insertion API for SSA values;
- no natural `DISubrange` construction for fixed arrays;
- current debug builds need extra allocas / preservation stores.

Details: [open DWARF issues in the Takibi repository](https://github.com/takibi-lang/takibi/issues?q=is%3Aissue%20is%3Aopen%20DWARF)

<!--
Timing: 9:00-9:25

If I must name one OCaml ecosystem issue, it is this binding gap. It is not a
fundamental compiler problem, but Takibi currently carries workarounds that
would be better solved in the upstream LLVM OCaml API.
-->

---

# The stack is open again

**OCaml** makes the compiler trustworthy and changeable.

**LLVM** makes native backends affordable.

**Generative AI** makes the experiment small-team feasible.

Anyone can now explore a language and a kernel - and perhaps, with
[Hardcaml](https://github.com/janestreet/hardcaml), the CPU below them too.

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

<!--
Timing: 9:25-9:45

My conclusion is deliberately optimistic. This stack does not make language
and kernel design easy, but it makes them accessible. OCaml was the quiet,
reliable air around the project. LLVM supplied the machines, and AI supplied
iteration speed. We can use that leverage to reopen old systems assumptions.
-->

---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: "" -->

# OCaml made the impossible boring

It caught changes in the compiler.

It made AI-generated changes reviewable.

It almost never became the problem itself.

## OCaml did not steal the show.

## It made the show possible.

**Build your next impossible systems project in OCaml.**

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

<!--
Timing: 9:45-10:00

And that is my strongest endorsement of OCaml. It did not demand attention;
it kept turning language ideas into explicit, testable compiler changes. For
this project, OCaml felt like air: stable, trustworthy, and simply there when
we needed it. Thank you.
-->
