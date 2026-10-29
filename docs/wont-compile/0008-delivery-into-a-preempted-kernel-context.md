# 0008. A delivery written into a preempted kernel context

| Field | Value |
| --- | --- |
| Status | Enforced |
| Compared against | Linux pt_regs, Rust for Linux (2026-10-29) |
| Check | type error, static index unification (`lib/type_inf.ml`) |
| Test case | `frame level: a delivery into an El1 frame is rejected` |
| Introduced | 2026-10-29, GitHub issue #992 |
| Specified in | [`SPEC.md`](../../SPEC.md) "Indexed Variants" |

![A wait4 result written into the saved frame of a process preempted
inside a syscall](assets/0008-delivery-into-a-preempted-kernel-context.svg)

## The defect

A process that sleeps leaves the CPU with its user frame saved, and a wakeup
delivers into it: wait4 writes the reaped pid into x0, a signal rewrites the
PC and stack. Once the kernel itself can be preempted, a process can also
leave the CPU with a kernel frame saved -- the registers of a syscall
interrupted halfway. A delivery written into that frame overwrites a live
kernel register, and the syscall resumes with a pid where it had a pointer.

## What C and Rust do about it

**C: a convention.** Linux delivers into `task_pt_regs(task)`, the user
frame at the top of the task's stack, which is a different frame from the
one a kernel preemption saved; nothing in the type of a `struct pt_regs *`
says which context it is, and `user_mode(regs)` is a run-time test the
caller has to remember.

**Rust: not in the language.** Rust for Linux has no typed frame; a
level would be a library type parameter.

Sources: [Linux arch/arm64 ptrace.h](https://github.com/torvalds/linux/blob/master/arch/arm64/include/asm/ptrace.h).

## What Takibi does

A saved frame is `FrameRef[process, level]`, and `level` is a static index,
`ExceptionLevel::El0` or `ExceptionLevel::El1`, read from the frame's own
SPSR when the frame is minted. Every writer of a frame word takes the El0
form, so a delivery aimed at an El1 frame is a static mismatch. Code that
does not know the level matches a `LeveledFrame` first.

## Code that does not compile

```takibi
enum ExceptionLevel { El0; El1; }

affine struct FrameRef[process: usize, level: ExceptionLevel] { private sp: usize; }

fn frame_general_set(frame: borrow FrameRef[process, ExceptionLevel::El0],
                     value: usize) {
}

fn deliver_status(frame: borrow FrameRef[process, ExceptionLevel::El1],
                  status: usize) {
    frame_general_set(frame, status);
}
```

```text
static value mismatch: ExceptionLevel::El1 vs ExceptionLevel::El0
```

## Code that does compile

```takibi
enum ExceptionLevel { El0; El1; }

affine struct FrameRef[process: usize, level: ExceptionLevel] { private sp: usize; }

variant LeveledFrame[process: usize] {
    El0(FrameRef[process, ExceptionLevel::El0]);
    El1(FrameRef[process, ExceptionLevel::El1]);
}

fn frame_general_set(frame: borrow FrameRef[process, ExceptionLevel::El0],
                     value: usize) {
}

fn deliver_status(frame: sink LeveledFrame[process], status: usize) -> bool {
    match frame {
        LeveledFrame::El0(user_frame) => {
            frame_general_set(user_frame, status);
            return true;
        }
        LeveledFrame::El1(kernel_frame) => { return false; }
    }
}
```

## Where this runs

`kernel/arch/arm64/kernel/frame_ref.tkb` defines the index; every delivery
(wait4's status, the signal frame writers, the UART and deadline results)
takes `FrameRef[process, ExceptionLevel::El0]`, through
`scheduled_process_parked_frame`.

## Limits of this entry

The level is what the frame's SPSR says when it is minted; that the SPSR
word is the one the resume restores is trusted (TRUSTED_BASE.md). The
syscall entry's mint (`frame_ref_from_el0_entry`) trusts its vector rather
than reading the word. The spelling is provisional until the syntax review
(#1006).
