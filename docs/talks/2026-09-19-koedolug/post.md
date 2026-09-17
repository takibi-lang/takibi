# Turning kernel defects into compile errors

I gave a talk at the Koedo Linux Users Group on 2026-09-19 about Takibi, a
language I am building together with a Linux-compatible kernel written in it.
The slides are below. This post is the longer version of the argument, because
fifteen minutes is enough to show three examples and not much else.

Last time I presented this project, at OCaml Meeting 2026, I spent most of the
slot on the language implementation, because that is what the room had come
for. It was the wrong emphasis. The interesting part of this project is not
that a compiler is written in OCaml; it is that writing the language and the
kernel at the same time lets you move kernel defects into the compiler. A room
full of Linux users is a much better audience for that claim, so this time I
built the talk around it.

## The gap I am trying to stand in

The Linux kernel is an excellent base to build on. That is precisely why its
implementation language matters: C gives a kernel complete control and almost
no proof, and in a kernel there is nothing above you to catch what goes wrong.
A bad access in an application raises an exception the runtime unwinds. A bad
access in a kernel corrupts something and keeps running.

The obvious objection is that people already know this and are already doing
something about it. They are. So before claiming a gap, I went looking for
what fills it:

| Implementation | Language | How it runs |
|---|---|---|
| FreeBSD linuxulator | C | inside another kernel, on bare metal |
| WSL1 | C | inside the NT kernel, on bare metal |
| gVisor | Go | hosted on another kernel, with a garbage collector |
| Fuchsia starnix | Rust | hosted on Zircon |

I find this table encouraging rather than discouraging. It proves the Linux
interface is replaceable -- that reimplementing it is a thing people
successfully do, not a fantasy. But look at the two columns together: the
implementations written in memory-safe languages all run on top of somebody
else's kernel, and the ones that run on bare metal are all written in C. A
Linux-compatible kernel that is both on bare metal and written in a language
that can check it is still an open position.

## Why the language and the kernel have to be built together

A language designed on its own cannot know what a kernel needs to prove. A
kernel written in someone else's language cannot ask for a check that language
does not have. Build them together and each one keeps telling you what the
other is missing -- the kernel produces a defect, and the question becomes
whether the type system could have refused it.

This is only affordable because of generative AI. I am one person, and a
compiler plus a kernel is not a one-person project on a normal budget. The AI
is the method; it is not the point, and I deliberately kept it to one slide.

## Three defects, and how I chose them

The talk showed three defect classes that Takibi rejects at compile time. I
picked them against a deliberately harsh bar: **neither C nor Rust refuses
this when the program is built.** The bar did real work -- it threw out
candidates I liked.

**A blocking call inside an interrupt handler.** A handler runs with
interrupts masked, so a function it reaches that sleeps is waiting for an
event that can no longer arrive. What makes this a defect class rather than a
coding tip is the distance: the handler calls a helper, which calls a logging
routine, which spins on a UART ready bit. Every function on that path is
correct in every other caller. Takibi's `!{interrupt}` roots reject a
transitively reachable `may_block`, and the diagnostic names the whole path --
including the middle function, which declares nothing at all.

Linux does detect this, at run time, through `might_sleep()`. That requires
`CONFIG_DEBUG_ATOMIC_SLEEP`, which production kernels do not ship, and it only
fires if the path actually executes.

**A handle that may name a destroyed object.** Kernels refer to objects by
handle -- a slot index, usually with a generation counter. A handle is plain
data, so it survives the destruction of the thing it names. The call that
destroys the object typically does not take the handle as an argument, which
is why reading the caller reveals nothing. Takibi marks the functions that can
destroy a given handle type and kills the binding at the first call that
reaches one, unless a live witness vouches for it.

**An unproven index that leaves a trap in the kernel.** An index arrives from
a packet or an MMIO read and addresses a table. There are exactly three
possible outcomes in a shipped binary: nobody checks and memory is corrupted;
somebody checks at run time and the failure becomes a trap, which on bare
metal ends the core; or the question is settled before the binary exists.
Takibi's refinement types take the third, and `--forbid-trap` turns every
remaining unproved site into a compile error. The whole maintained kernel is
built that way. It contains no bounds-check trap because no access needed one,
not because the checks were disabled.

Two more entries did not fit in fifteen minutes and are worth reading if this
kind of thing interests you. **An exception frame that does not match the
entry sequence** is my favourite, because it is the one case where C and Rust
are not merely unequal to the task but absent from the conversation: in both,
the frame layout is a struct in one file and an assembly stub in another, and
the compiler is never shown both. Takibi's `exception_entry` is a language
construct that emits the save sequence, so the compiler can tell you exactly
which register your struct left out. **A wire-endian field used as a host
integer** is the weakest claim of the five and I label it as such in the
catalog: C has sparse's `__bitwise`, Rust has crates like `zerocopy`, and both
genuinely work. The difference there is not capability but where the check
lives -- in Takibi it is the field type of a packed struct, so there is
nothing to opt into and nothing to install.

I also threw one candidate out for failing the bar: constructing an MMIO
pointer requires `unsafe` in Takibi, but it requires `unsafe` in Rust too, so
there is no claim to make.

## Why not just use Rust

This is the question I actually get asked, so let me answer it without being
rude about Rust, which is a good language doing good work.

Rust for Linux is right, and it is working. But it inherits Rust's ceiling.
Rust has no effect system, which is why Rust for Linux built `klint`, an
out-of-tree MIR lint, to track preemption count -- the property exists, but
outside the language, so it is not part of any function's type. The borrow
checker reasons about references, so a slot-plus-generation handle has no
lifetime to attach and the practical answer is a generation compared at run
time. And on the index: Rust genuinely prevents the memory error, and saying
otherwise would be false -- what it cannot do is remove the check by proving
the index, leaving a runtime check that panics or a `get_unchecked` that
deletes the question rather than answering it.

My worry is not that Rust is insufficient. It is that "Rust exists, so let us
improve kernel safety as far as Rust reaches" is a ceiling nobody notices they
are standing under. Somebody should go and look at what is above it, and a
self-made language is a cheap way to look: nothing depends on it, so it can be
broken and rebuilt every week. If something found up there eventually turns up
in Rust or Zig, that is the best ending this project could have. I would like
to be ground that someone else builds on, not a replacement for anything.

## Does the catalog rot?

A page that transcribes a program and the error message it produces is a claim
with no verifier, and a stale page renders exactly like a true one. Since the
whole point is to be checked by strangers, the build checks it first:
`check_wont_compile_catalog.py` verifies that every entry names a test case
that really exists in the suite and that the index agrees with the entries,
and `buildcheck_wont_compile_samples.py` compiles every program printed in the
catalog with the compiler that build just produced -- eight must be rejected
with the exact message printed beside them, five must be accepted.

So a compiler regression does not quietly make the documentation wrong. It
makes the build red.

Which means you do not have to take my word for any of this. Copy a program
out of the catalog, run it through the compiler, and see whether you get the
message I said you would.

## Resources

- Slides: (SlideShare link)
- Defect catalog: [docs/wont-compile/](https://github.com/takibi-lang/takibi/tree/main/docs/wont-compile)
- Repository: [github.com/takibi-lang/takibi](https://github.com/takibi-lang/takibi)
