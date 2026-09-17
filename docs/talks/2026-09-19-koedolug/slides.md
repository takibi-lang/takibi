---
marp: true
theme: takibi
paginate: true
footer: "Koedo Linux Users Group, 2026-09-19"
---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: "" -->

# Turning kernel defects into compile errors

## Building a language and a kernel at the same time

Kiwamu Okabe

[github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)

---

# The kernel we rely on cannot be checked by its own language

```text
C gives the kernel complete control
             +
C gives the kernel almost no proof
             =
one bad access can corrupt the whole system, silently
```

A bad access in an application raises an exception something can catch.

In a kernel there is nothing above you to catch it.

> Could more kernel failures be compile errors instead?

---

# Linux-compatible kernels exist. The safe ones are all hosted.

| Implementation | Language | How it runs |
|---|---|---|
| FreeBSD linuxulator | C | bare metal, inside another kernel |
| WSL1 | C | bare metal, inside the NT kernel |
| gVisor | Go | **hosted** on another kernel, with a GC |
| Fuchsia starnix | Rust | **hosted** on Zircon |

The Linux interface is replaceable, and these prove it.

But the memory-safe ones run on somebody else's kernel, and the bare-metal
ones are all C. **That gap is still open.**

---

# Build the language and the kernel together

A kernel cannot ask for a check its language does not have.

<style scoped>
img { display: block; margin: 0 auto; }
</style>

![w:600](assets/human-on-the-loop.svg)

Generative AI is what makes this affordable. It is the method, not the point.

---

<!-- _class: video-slide -->

# It boots, and it runs BusyBox

<video src="assets/demo.mp4" poster="assets/demo.png" muted loop controls></video>

---

# Can you see the bug? (1/3)

```c
/* drivers/uart.c -- correct on its own */
void uart_putc(char c)
{
        wait_for_tx_ready();      /* spins; may sleep */
        write_reg(UART_DR, c);
}
```

```c
/* drivers/timer.c -- correct on its own */
static irqreturn_t timer_isr(int irq, void *dev)
{
        uart_putc('.');
        return IRQ_HANDLED;
}
```

Neither file is wrong. The defect exists only in the combination.

---

# A blocking call inside an interrupt handler

<style scoped>
img { display: block; margin: 0 auto; }
</style>

![w:900](assets/defect-0001.svg)

```text
interrupt function 'timer_irq_handler' may block via
  timer_irq_handler -> uart_put -> uart_wait_ready
```

`uart_put` declares nothing, and is still named in the path.

---

# And this one? (2/3)

```c
/* a handle is a slot index and a generation, not a pointer */
static int report(struct task_handle child)
{
        deliver_signal(0);        /* ... -> wait4() -> release_task() */

        return task_slot(child);  /* the slot may hold a new task now */
}
```

`deliver_signal()` never receives `child`.

Reading this function tells you nothing is wrong.

---

# A handle that may name a destroyed object

<style scoped>
img { display: block; margin: 0 auto; }
</style>

![w:660](assets/defect-0002.svg)

---

# Dead at the call, not at the argument

```rust
fn task_reap(z: sink TaskZombie[id]) !{invalidates_TaskHandle} {}

fn signal_then_use(child: TaskHandle) -> usize {
    deliver_signal(0);
    return task_slot(child);
}
```

```text
'child' (TaskHandle) may name a destroyed object: 'deliver_signal' at line 16
(deliver_signal -> wait_and_reap -> task_reap) reaches a function marked
invalidates_TaskHandle, and no live witness vouches for this handle
```

Re-derive the handle, or hold a witness that keeps the object alive.

---

# And this? (3/3)

```c
static u32 table[64];

void store(size_t index, u32 value)
{
        table[index] = value;    /* index came from a packet header */
}
```

Two lines.

---

# An unproven index leaves a trap in the kernel

<style scoped>
img { display: block; margin: 0 auto; }
</style>

![w:640](assets/defect-0004.svg)

```text
Error: --forbid-trap: 1 runtime trap site(s) remain (listed above)
```

It ships no bounds-check trap because no access needed one.

---

<!-- _class: invert -->

# Rust reaches none of these three

**The blocking call.** Rust has no effect system. That is why Rust for Linux
built `klint`, an out-of-tree MIR lint, to track preemption count: the
property exists, but outside the language, so it is not part of any type.

**The stale handle.** The borrow checker reasons about references. A slot plus
a generation is not a reference, so there is no lifetime to attach. Every
arena crate's answer is a generation compared **at run time**.

**The unproven index.** Rust does prevent the memory error here, and saying
otherwise would be false. What it cannot do is remove the check by *proving*
the index: a runtime check that panics -- on bare metal, the end of the core
-- or `get_unchecked`, which deletes the question instead of answering it.

---

# Why build a new language instead of using Rust

Rust for Linux is right, and it is working. But it inherits Rust's ceiling,
and nobody finds out what is above a ceiling by standing under it.

```text
a self-made language is a cheap scout:
nothing depends on it, so it may be broken and rebuilt
```

If something found here later turns up in Rust or Zig, that is the best
ending this project could have. I would like to be ground someone else
builds on, not a replacement for anything.

---

<!-- _class: lead -->
<!-- _paginate: false -->
<!-- _footer: "" -->

# You do not have to believe me

Every program on these slides is in the repository, with the error it produces.

## [github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi) -- see `docs/wont-compile/`

Copy one, run your compiler, get the same message.

Questioning the assumptions under C and UNIX, with an AI as a co-worker,
turns out to be a great deal of fun.

---

<!-- _class: invert -->

# Appendix: does the catalog rot?

A page that transcribes a program and its error message is a claim with no
verifier, and a stale page renders exactly like a true one.

So the build checks it:

- `check_wont_compile_catalog.py` -- every entry names an Alcotest case that
  exists, and the index agrees with the entries.
- `buildcheck_wont_compile_samples.py` -- every program printed in the catalog
  goes through the compiler that build just produced. **8 must be rejected
  with the message beside them; 5 must be accepted.**

A regression does not make the documentation wrong. It makes the build red.
