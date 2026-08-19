---
marp: true
theme: takibi
paginate: true
footer: "OCaml Meeting 2026 in Tokyo"
---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: "" -->

# Create your own programming language and OS using OCaml, LLVM, and Generative AI -- accessible to everyone

Kiwamu Okabe

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

<!--
Timing: 0:00-0:20

Takibi is a programming language compiler and a Unix-like kernel I built with
generative AI. Today I will show why OCaml and LLVM made this possible, and
how the running kernel shaped some unusual language features.
-->

---

# I love building operating systems

But the traditional implementation language is a problem:

```text
C gives the kernel complete control
              +
C gives the kernel almost no proof
              =
one bad access can corrupt the entire system
```

I wanted a language designed for the place where a crash is least recoverable.

> Could more kernel failures become compile-time errors?

<!--
Timing: 0:20-0:45

A userspace process can often be restarted. A fault in a monolithic kernel can
silently corrupt memory or stop every service. That made me ask for a safer
language, not just safer coding conventions.
-->

---

<!-- _class: invert -->

# Why OCaml + LLVM + Generative AI?

| Ingredient | Role |
|---|---|
| **OCaml** | Make syntax and static semantics explicit and changeable |
| **LLVM** | Produce real native code without writing machine backends |
| **Generative AI** | Implement enough compiler and kernel code to test ideas end-to-end |

The LLVM project officially maintains
[OCaml bindings](https://github.com/llvm/llvm-project/tree/main/llvm/bindings).

LLVM IR is still hard. AI made the experiment tractable.

<!--
Timing: 0:45-1:10

The bindings gave me a supported route from OCaml to native code. But LLVM IR,
ABIs, optimizations, and debug metadata still make a compiler substantial.
Generative AI supplied iteration speed; OCaml supplied the structure needed to
review those iterations.
-->

---

# The setup

<div class="diagram-placeholder">

**Architecture diagram goes here**

AI agent / development host
<br>&lt;-&gt; JTAG/SWD + UART + Ethernet<br>
STM32F746 / Raspberry Pi 5 / QEMU-AArch64

</div>

<span class="small">Planned replacement: a drawn connection diagram for the physical boards and host.</span>

<!--
Timing: 1:10-1:35

This diagram will show the development host connected directly to STM32 and
Raspberry Pi hardware, plus QEMU. The important point is that the AI can
observe and operate almost every interface used by the project.
-->

---

# Keep the human on the loop

- Let the AI debug Raspberry Pi and STM32 directly over **JTAG/SWD**.
- Let it read and drive the **UART serial console**.
- Prefer applications whose behavior is observable over **Ethernet**.
- Keep QEMU for fast, repeatable AArch64 integration tests.
- Defer display rendering and other hard-to-observe interfaces.

```text
AI can edit -> build -> flash -> observe -> diagnose -> retry
```

The human supplies judgment when that loop reaches the wrong abstraction.

<!--
Timing: 1:35-2:05

I deliberately chose interfaces an agent can operate from a shell. This makes
the feedback loop nearly autonomous, while keeping a human ready to redirect
the investigation when more logs will not reveal the real cause.
-->

---

<!-- _class: video-slide -->

# Demo

<video src="demo.mp4" autoplay muted loop controls></video>

<!--
Timing: 2:05-2:35

This is the Takibi kernel running the real system: existing AArch64 userspace,
storage, networking, and the shell or HTTP workload shown in the recording.
The video is muted and loops so browser autoplay remains reliable.
-->

---

<!-- _class: invert -->

# The kernel is the language-design workload

```text
AI implements a real kernel path
             |
             v
Repeated .tkb patterns expose missing guarantees
             |
             v
The OCaml compiler learns a checked abstraction
             |
             v
The next kernel path becomes safer and simpler
```

Takibi types do not stop at memory ownership.

They represent **authority, identity, state, and mandatory transitions**.

<!--
Timing: 2:35-3:00

The kernel is not merely a demo. Its repeated failure patterns are input to
the language design. The next examples are compiler-enforced techniques used
by the actual network, memory, and syscall implementations.
-->

---

# C technique: describe NIC state with booleans

```c
frame->valid = true;
frame->tx_in_flight = true;
frame->released = false;
```

The representation also permits contradictions:

```c
frame->valid && frame->released
frame->tx_in_flight && frame->available
```

Every caller must remember which combinations are legal.

The compiler sees only fields and integers.

<!--
Timing: 3:00-3:25

A conventional driver often represents its protocol with flags and comments.
Checks may detect some invalid combinations at runtime, but the API still lets
callers construct and pass them around.
-->

---

# Takibi technique 1: the NIC is a capability state machine

```text
NetRxCanAcquire
  -> NetRxValidated[desc]
  -> NetRxReplyReady[desc]
  -> NetTxInFlight[desc]
  -> NetRxCanAcquire
```

```rust
fn net_transmit(reply: sink NetRxReplyReady[desc])
    -> NetTxInFlight[desc];

fn net_tx_complete(in_flight: sink NetTxInFlight[desc])
    -> NetRxCanAcquire !{may_block};
```

Each transition consumes the previous state with `sink`.

<!--
Timing: 3:25-3:55

Each protocol state is a different linear type. The static descriptor identity
survives every transition, while the old state is consumed. QEMU virtio-net
and the real RPi5 Ethernet driver implement the same typed protocol.
-->

---

# Make invalid NIC states unrepresentable

The type checker prevents:

- releasing the same RX frame twice;
- transmitting before validation;
- reacquiring a descriptor before TX completes;
- forgetting to return an active descriptor to DMA.

```text
detect an invalid state later        C flags

make the invalid state impossible    Takibi types
```

The capability types add no new descriptor identity at runtime.

<!--
Timing: 3:55-4:20

Linear means the active descriptor must be consumed exactly once on every
control-flow path. Static indices preserve which descriptor it is. These are
compile-time obligations rather than another runtime state machine layered on
top of the hardware state.
-->

---

# C technique: return a pointer into an RX buffer

```c
uint8_t *packet = net_rx_frame(frame);

net_rx_release(frame);  /* DMA owns it again */

parse(packet);          /* use after release */
```

The pointer still looks valid.

Its type does not remember:

- the available length;
- the descriptor it came from;
- when ownership returned to DMA.

<!--
Timing: 4:20-4:45

This is more subtle than freeing heap memory. The address remains mapped, but
the device may already be writing the next packet into it. Pointer validity
alone does not express that authority change.
-->

---

# Takibi technique 2: tie the slice to descriptor authority

```rust
fn net_rx_frame(frame: borrow NetRxValidated[desc])
    -> [u8; 1514..] @ desc;
```

The result carries two proofs:

```text
at least 1514 bytes are available
                  +
the slice is derived from descriptor desc
```

```rust
let packet = net_rx_frame(frame);
let ready = net_rx_release(frame);
parse(packet); // compile error
```

<!--
Timing: 4:45-5:15

The slice has a minimum length refinement and an authority-region tie. Once
the owner is consumed, all derived slices become unusable. Aliases, subslices,
and even raw-pointer casts retain that tie; unsafe does not erase it.
-->

---

# C technique: who owns a mapped page now?

```c
page = alloc_page();
install_pte(process, page);

/* Does the allocator still own it? */
/* Does the page table own it? */
/* Who decrements the COW reference? */
```

An integer address does not encode lifecycle responsibility.

Comments must define the handoff, and every failure path must reproduce it.

<!--
Timing: 5:15-5:40

Page-table installation changes who is responsible for eventual reclamation.
That boundary is easy to express in prose and easy to violate in cleanup and
copy-on-write paths.
-->

---

# Takibi technique 3: transfer page ownership into a mapping

```rust
fn page_mapping_install(owner: sink PageOwner[page]);
```

```text
exclusive PageOwner[page]
           |
           | install PTE; consume owner
           v
page-table mapping reference + map_refcount
```

After installation, the caller cannot keep using `PageOwner[page]`.

> A lifecycle boundary becomes an ownership transfer in the signature.

<!--
Timing: 5:40-6:05

The newly allocated page begins with one linear allocator owner. Installing
the first mapping consumes it and transfers responsibility into page-table
metadata. The source code makes the ownership boundary explicit.
-->

---

# Copy-on-write failure is not one boolean

```rust
must_use variant PageMappingRetainResult {
  NotMapped;
  RefCeilingReached;
  Retained;
}
```

| Result | Meaning |
|---|---|
| `NotMapped` | Possible broken kernel invariant |
| `RefCeilingReached` | Defined resource limit |
| `Retained` | COW mapping reference acquired |

`must_use` makes ignoring the distinction a compile error.

<!--
Timing: 6:05-6:30

A bool used to collapse corruption and capacity exhaustion into the same
failure. The closed result forces every caller to name all outcomes, while
must_use rejects a dropped result on any path.
-->

---

# C technique: trust a syscall pointer too early

Userspace supplies only numbers:

```c
uintptr_t address;
size_t length;
```

A cast can turn them into a kernel pointer before proving:

- the range belongs to the calling address space;
- every page exists;
- overflow and window bounds are safe;
- the requested read or write permission is present.

Validation becomes a convention repeated by syscall handlers.

<!--
Timing: 6:30-6:55

The syscall boundary is where hostile or simply incorrect integers enter the
kernel. A raw pointer type says nothing about which process mapping was
checked or in which access direction.
-->

---

# Takibi technique 4: validate first, then obtain a type

```rust
must_use variant UserReadRangeResult {
  Fault;
  Ok(UserReadRange);
}

must_use variant UserWriteRangeResult {
  Fault;
  Ok(UserWriteRange);
}
```

Only a validated value can enter the copy API:

```rust
fn copy_from_user(range: UserReadRange, destination: []u8);
fn copy_to_user(range: UserWriteRange, source: []u8);
```

<!--
Timing: 6:55-7:25

The constructors walk the actual page table for the current address-space
root. Their fields are private, so a syscall body cannot manufacture proof.
The must-use result forces it to handle EFAULT explicitly.
-->

---

# Read and write authority are different types

```rust
copy_to_user(read_validated_range, data);
// compile error: UserReadRange is not UserWriteRange
```

This prevents a real class of direction mismatch that a runtime mode once
allowed.

```text
UserWriteRange
      |
      | explicit downgrade
      v
UserReadRange
```

There is no conversion in the other direction.

<!--
Timing: 7:25-7:50

A writable AArch64 userspace mapping is also readable, so write authority may
be explicitly downgraded. The reverse requires a fresh page-table validation.
Even a read-write syscall such as ppoll states its direction in source.
-->

---

# A validated range is a proof-carrying value

```rust
struct UserWriteRange {
  private root: AddressSpaceRoot;
  private address: usize;
  private length: usize;
}
```

Its existence means:

- the correct process page table was checked;
- every page is present and writable, or resolvable through COW;
- `address + length` cannot overflow;
- the range stays inside the userspace window.

Syscall bodies reuse the proof instead of reimplementing validation.

<!--
Timing: 7:50-8:15

This pattern contains unsafe code at the final memory-copy boundary rather
than spreading integer-to-pointer casts across syscall implementations. The
proof-carrying value is ordinary runtime data with a private construction API.
-->

---

<!-- _class: invert -->

# A problem even the AI could not solve: STM32 UART

**AI:** "Serial output is lost while using the SD card."

It kept investigating symptoms.

**Human:**

> Our UART is polling, while the SD card uses DMA. ChibiOS/RT normally uses
> DMA and interrupts for both. What happens if we change UART to DMA + IRQ?

**AI:** Implemented it, tested it on the board -- **problem solved.**

<!--
Timing: 8:15-8:40

The agent had complete access to the logs and hardware, but it needed a human
systems hypothesis. Once redirected toward asymmetric I/O mechanisms, it
could implement and verify the fix itself.
-->

---

<!-- _class: invert -->

# Another blind alley: kernel printf debugging

**AI:** Added more and more kernel-side prints to infer userspace behavior.

**Human:**

> If we need to know what BusyBox does, why not read the BusyBox source?

**AI:** Read the actual userspace implementation -- **problem solved.**

```text
more observability is not always more understanding
```

The human changed the source of evidence, not the amount of logging.

<!--
Timing: 8:40-9:05

This was another abstraction mistake. Kernel logs could only reveal effects.
The userspace source directly explained intent. Human-on-the-loop means
recognizing when the investigation itself needs to change.
-->

---

# Why the human still matters -- and why OCaml helps

The human contributes:

- the right abstraction and causal hypothesis;
- scope control and architectural judgment;
- a decision about which evidence is trustworthy.

OCaml contributes:

- algebraic data types for explicit compiler states;
- exhaustive matching as a checklist after every language change;
- small transformations that are easy to test and review;
- a stable implementation medium that is rarely the problem itself.

<!--
Timing: 9:05-9:30

AI supplies enormous implementation throughput, but not reliably the right
question. OCaml then makes the resulting compiler changes legible: changing
an AST or type produces explicit cases and useful compile failures.
-->

---

# The one OCaml-side rough edge: DWARF

Takibi emits DWARF and supports source debugging through QEMU + GDB.

LLVM's current OCaml bindings still lack convenient APIs for:

- `dbg.value` locations for SSA and entry parameter values;
- natural `DISubrange` metadata for fixed arrays;
- replacing debug-only allocas and preservation stores;
- some future lexical-scope and optimized-debug policies.

I would like to contribute these capabilities upstream.

Details: [Takibi's open DWARF issues](https://github.com/takibi-lang/takibi/issues?q=is%3Aissue%20is%3Aopen%20DWARF)

<!--
Timing: 9:30-9:50

OCaml itself was almost never an obstacle. The concrete gap was the surface
area exposed by LLVM's OCaml debug-info bindings. Takibi works around it today,
but the better long-term answer is an upstream binding contribution.
-->

---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: "" -->

# OCaml + LLVM + Generative AI makes the stack accessible

I tried the experiment:

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

Question today's architectural assumptions.

Design **your** language and **your** OS in OCaml.

Perhaps design the CPU too, with
[Hardcaml](https://github.com/janestreet/hardcaml).

## OCaml makes ambitious systems experiments ordinary.

<!--
Timing: 9:50-10:00

My conclusion is optimistic: this combination makes language and OS work
accessible to far more people. OCaml is the reliable foundation beneath that
experiment. Thank you.
-->
