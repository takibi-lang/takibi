# 0003. An exception frame that does not match the entry sequence

| Field | Value |
| --- | --- |
| Status | Enforced |
| Check | type error, `exception_entry` validation (`lib/type_inf.ml`) |
| Test case | `exception_entry rejects a frame struct missing a register field` |
| Introduced | 2026-08-06, commit `50092487` ("Add exception_entry signature checking and exception_resume") |
| Specified in | [`SPEC.md`](../../SPEC.md) exception entries |

![The entry sequence stores x0, x1, x2, x3 while the frame struct declares
x0, x2, x3, so every name below the hole lands on the wrong
word](assets/0003-exception-frame-missing-a-register.svg)

## The defect

An exception handler begins with a stretch of assembly that pushes the
interrupted context onto a stack: the general-purpose registers, the stack
pointer, the link register, the saved program status, the vector registers.
The handler body then reads that context as a struct, and on return the same
assembly pops it back into the hardware.

The struct and the assembly are two descriptions of the same bytes. Nothing
holds them together. Leave one field out of the struct and every field below
the hole silently names the wrong word: the handler reads the interrupted
`x1` believing it is `x2`, and on `eret` the shifted words go back into the
registers the interrupted code was using.

The result is not a crash at the mistake. It is an interrupted thread that
resumes with two registers swapped, thousands of instructions from the
handler, in whatever code happened to be running. Kernel debugging folklore
is full of these; they read as memory corruption, as a compiler bug, as
flaky hardware.

## What C and Rust do about it

**Neither language can check it**, and for the same reason: in both, the
frame layout is a contract between a `struct` in one file and a hand-written
assembly stub in another, and the compiler is never shown both. In C the stub
is a `.S` file or an `__asm__` block; in Rust it is `global_asm!` next to a
`#[repr(C)]` struct. Rust's type system is not weaker here than C's -- it is
simply not in the conversation, because the register saves are not typed
operations. `offset_of!` lets a Rust programmer *assert* an offset; it does
not know what the architecture's entry contract is, so it cannot tell you a
register is missing.

This is the one defect in this catalog where the difference is not a type
system feature at all. It is that the entry sequence is a **language
construct** rather than a file the programmer maintains: Takibi's
`exception_entry` generates the save and restore, so the compiler knows
exactly which words are on that stack and can compare the struct against
them.

## What Takibi does

`exception_entry` names a vector slot, a frame struct, and a dispatch
function, and the compiler emits the entry sequence for the target
architecture. Declaring it is what makes the frame checkable: the layout is
no longer a convention between two artifacts, it is one artifact the compiler
produced and one it validates.

The frame struct must name every register the sequence stores for that
target, with the right type, and nothing else. A missing field is rejected by
name -- the diagnostic says which register, not merely that the sizes
disagree. A field whose name is not a register of the target is rejected too,
which catches the other direction: padding invented to make the size come out
right.

The dispatch function's signature is checked against what the sequence
actually passes it, so the frame cannot be correct while the handler reads it
through the wrong prototype.

## Code that does not compile

```takibi
struct packed IncompleteFrame { x0: usize; }
fn my_dispatch(frame_sp: usize) -> usize { return frame_sp; }
exception_entry el1_current_irq_entry {
  frame: IncompleteFrame;
  dispatch: my_dispatch;
}
```

```text
exception_entry 'el1_current_irq_entry' frame 'IncompleteFrame' is missing
register field 'x1'
```

## Code that does compile

The complete frame, which is also the point: this is the artifact C and Rust
leave unchecked, and its size is the reason a hole in it is so easy to miss.

```takibi
struct packed ExcFrame {
    x0: usize; x1: usize; x2: usize; x3: usize; x4: usize; x5: usize;
    x6: usize; x7: usize; x8: usize; x9: usize; x10: usize; x11: usize;
    x12: usize; x13: usize; x14: usize; x15: usize; x16: usize; x17: usize;
    x18: usize; x19: usize; x20: usize; x21: usize; x22: usize; x23: usize;
    x24: usize; x25: usize; x26: usize; x27: usize; x28: usize; x29: usize;
    x30: usize;
    sp_el0: usize; elr_el1: usize; spsr_el1: usize;
    q0: [u8;16]; q1: [u8;16]; q2: [u8;16]; q3: [u8;16]; q4: [u8;16];
    q5: [u8;16]; q6: [u8;16]; q7: [u8;16]; q8: [u8;16]; q9: [u8;16];
    q10: [u8;16]; q11: [u8;16]; q12: [u8;16]; q13: [u8;16]; q14: [u8;16];
    q15: [u8;16]; q16: [u8;16]; q17: [u8;16]; q18: [u8;16]; q19: [u8;16];
    q20: [u8;16]; q21: [u8;16]; q22: [u8;16]; q23: [u8;16]; q24: [u8;16];
    q25: [u8;16]; q26: [u8;16]; q27: [u8;16]; q28: [u8;16]; q29: [u8;16];
    q30: [u8;16]; q31: [u8;16];
    fpsr: usize; fpcr: usize; tpidr_el0: usize;
}

fn my_dispatch(frame_sp: usize) -> usize { return frame_sp; }

exception_entry el1_current_irq_entry {
    frame: ExcFrame;
    dispatch: my_dispatch;
}
```

## Limits of this entry

The check is per target, and the frame above is the AArch64 one; the same
struct is wrong for a different architecture and the compiler says so. What
is established is that the struct matches the sequence the compiler emits --
not that the sequence is itself correct for the hardware. That belongs to the
reviewed target lowering, and [`TRUSTED_BASE.md`](../../TRUSTED_BASE.md)
states which parts of it are trusted rather than proved.
