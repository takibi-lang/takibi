---
marp: true
theme: default
paginate: true
footer: "OCaml Meeting 2026 in Tokyo"
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

# Create your own programming language and OS using OCaml, LLVM, and Generative AI -- accessible to everyone.

Kiwamu Okabe

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

---

# Why redesign this layer now?

Userspace can restart after a crash.

In a monolithic kernel, the same bug may silently corrupt memory.

Yet our kernel interfaces and implementation habits still inherit many
assumptions from **C**.

> What if the kernel's runtime-error surface became a compile-time problem?

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

---

# Three ingredients, three jobs

| Ingredient | What it buys |
|---|---|
| **OCaml** | Fast, explicit evolution of syntax and static semantics |
| **LLVM** | Real native code without building target backends |
| **Generative AI** | Enough implementation throughput to test ideas end-to-end |

None replaces the others.

Together, they make a language plus kernel feasible at personal-project scale.

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

---

# Why not simply Rust or Zig?

They proved that low-level programming can have modern tools.

Takibi asks a different research question:

- Can proof-carrying resource types extend beyond pointer ownership?
- Can ranges eliminate kernel traps rather than merely catch them?
- Can one small language co-design ownership, effects, and future proofs?

This is an experiment, not a claim of production superiority.

---

# Why keep the Linux syscall ABI?

Redesign the boundary between **applications** and **hardware** cheaply:

- keep a vast, stable userspace ecosystem;
- replace the kernel implementation and its internal invariants;
- add syscalls only when a real program reaches them;
- translate typed internal results to `-errno` only at the boundary.

Cheaper than designing a new microkernel, IPC model, and application world
all at once.

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

---

# Test where the truth lives

| Tier | Question | Cost |
|---|---|---|
| OCaml compiler tests | Should this program type-check or be rejected? | milliseconds |
| Native Linux `.tkb` tests | Does target-independent behavior compute correctly? | seconds |
| QEMU / real RPi5 | Are MMIO, IRQ, cache, timing, and concurrency real? | expensive |

> Never replace a hardware claim with a convenient host test.

---

# What was actually difficult?

| Problem | Working response |
|---|---|
| AI proposes plausible but unsound shortcuts | Compile-time policies: `must_use`, effects, `--forbid-trap` |
| QEMU hides hardware failures | Keep real RPi5 tests for MMIO, IRQs, caches, and timing |
| Hardware iteration is slow | Three tiers: compiler tests, native Linux tests, QEMU/RPi5 |
| Scope expands too easily | YAGNI: every feature needs a present workload |
| Context drifts across AI sessions | Specification, engineering log, and executable tests |

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

---

# A prompt shape that scales

Give the AI:

1. **one invariant** - "this owner is consumed exactly once";
2. **one accepted program**;
3. **one rejected program and exact diagnostic**;
4. **the smallest compiler phase in scope**;
5. **the real repository-wide build as the finish line**.

Then review the semantic diff, not the volume of generated code.

---

# One real rough edge: DWARF

Takibi emits useful DWARF and supports GDB on QEMU, but LLVM's OCaml bindings
do not expose all the metadata APIs needed for natural source debugging.

- no suitable `dbg.value` insertion API for SSA values;
- no natural `DISubrange` construction for fixed arrays;
- current debug builds need extra allocas / preservation stores.

Details: [open DWARF issues in the Takibi repository](https://github.com/takibi-lang/takibi/issues?q=is%3Aissue%20is%3Aopen%20DWARF)

---

# The stack is open again

**OCaml** makes the compiler trustworthy and changeable.

**LLVM** makes native backends affordable.

**Generative AI** makes the experiment small-team feasible.

Anyone can now explore a language and a kernel - and perhaps, with
[Hardcaml](https://github.com/janestreet/hardcaml), the CPU below them too.

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

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
