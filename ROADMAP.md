# Takibi roadmap

This file is a mid-term plan for the project's stated ultimate goal: a
practical, monolithic, Linux-syscall-ABI-compatible Unix-like kernel written in
Takibi, whose runtime-error surface is lifted to compile time (see `README.md`
and `AGENTS.md`'s "Design Principle: Detect Errors at Compile Time").

It is a *plan*, not a contract. `AGENTS.md`'s YAGNI principle still governs what
actually gets built: the milestones below describe direction and dependency
order so that work already driven by a real requirement is done in a sensible
sequence, not a license to build ahead of demand. Where a milestone is
deliberately speculative, it says so.

Written 2026-08-05 against the 52 open GitHub issues at that date. `HISTORY.md`
remains the engineering log; `kernel/README.md` remains the description of what
the kernel actually does today.

**This is the one file in the repository where enumerating issue numbers is the
point** (see `AGENTS.md`'s "Issue Numbers Do Not Belong in Tracked Files"). It
is a dated snapshot, refreshed occasionally and wholesale rather than
maintained incrementally: being visibly out of date here is expected and
harmless, which is exactly why the same references are not allowed to leak into
files that are read as descriptions of current behavior. Live status --
what is in progress, what is blocked, who is on it -- lives on the
[project board](https://github.com/orgs/takibi-lang/projects/2), not here.

## Baseline at the time of writing

| Measure | Value |
|---|---|
| `kernel/` Takibi source | 13,881 lines, all built with `--forbid-trap` |
| `kernel/arch/arm64` assembly | 1,300 lines (`user_entry.S` alone is 574, of which 312 are an EL0 test payload) |
| `unsafe { }` blocks in `kernel/` | 39, across 7 files |
| Linux syscalls | 28 Implemented, 10 Partial, 5 deliberately Unsupported (`kernel/SYSCALLS.md`) |
| RPi5 integration views | 24 expected-file projections over one boot |
| Regression detection | one physical RPi5; no CI |

The last row is the one worth staring at. Issue #209's three frame-management
bugs were diagnosable only by reading a parked core's registers over SWD, and
issue #223 documents a latent FP/SIMD corruption that no current test can
observe. As the kernel gets more concurrent, hardware-only failure modes become
the main failure modes.

## Issue inventory

52 open issues at the time of writing. 29 of them (56%) predate the standalone
`kernel/` tree and were filed while `examples/` was the product surface; their
relative priority no longer reflects where the project is. No labels or
milestones are in use.

| Axis | Issues | Note |
|---|---|---|
| A. Kernel features | #209 #220 #204 #182 #208 #207 | the current front line |
| B. Kernel defects / structure | #219 #223 #224 #222 #202 #199 | #219 and #223 are latent bugs |
| C. Shrinking the assembly core | #225 -> #226 -> #227 | serial dependency, fixed by #221's completion |
| D. Proof capability (research) | #200 #201 #203 #216 #109 #90 #13 | five research issues open in parallel |
| E. Language ergonomics | #212 #217 #218 #155 #214 | #217/#218 were split out of #15 |
| F. Portability / infrastructure | #50 #85 #95 #56 #149 #171 #9 #122 #123 #124 | no issue exists for a QEMU kernel target |
| G. Older backlog, needs triage | #5 #8 #17 #19 #26 #28 #36 #58 #65 #91 #103 #129 #131 #132 #15 | some promote, some park |

## The engine this roadmap is built around

The project's demonstrated working pattern is a loop, not a list: a concrete
kernel requirement exposes a real bug or an unprovable pattern, and that becomes
a language or type-system issue, which then makes the next kernel milestone
cheaper.

- #209's frame bugs -> #221 (migrate syscall paths into `.tkb`) -> #225/#226/#227
- #196's syscall boundary work -> #199/#200/#201/#202/#203
- #207's freelist redesign -> const generics -> #214/#216/#217
- `kernel/net/` wire headers -> #186 (`u16be`/`u32be`)

Milestones below are ordered so this loop keeps running, rather than separating
"kernel work" and "compiler work" into tracks that stop feeding each other.

## M0: pay down latent defects

Immediate. Each of these is a known-wrong thing that has not fired yet.

- **#223** -- `el1_current_irq_entry` does not save q0-q31/FPSR/FPCR, unlike the
  EL0 paths. Currently safe only because no function reachable from
  `rpi5_irq_dispatch` happens to use SIMD. Nothing enforces that.
- **#219** -- `process_image_clone_vm_begin` never initializes root 1's
  demand-stack metadata, so a forked child that grows its stack fail-stops the
  core. Blocks M1.
- **#224** -- primary and secondary CPU init configure the same registers in two
  places. The issue itself argues for doing this before #222, not after.

Done when: `make kernelcheck-rpi5` is green with a new fixture that holds live
SIMD across an IRQ, and a fixture where a forked child grows its stack past the
parent's fork-time high-water mark.

## M1: a kernel a human can log into

- **#209** -- interactive BusyBox ash REPL over UART (blocking UART input,
  terminal descriptor behavior). Blocked by #219.
- **#204** -- `writev`/`readv` parity with `write`/`read` for connected TCP and
  inetd-mode fds. Falls out naturally while doing the above.
- **#220** -- BusyBox telnet service, i.e. listener/session lifecycle on top of
  #209's process primitives.

Done when: a telnet session reaches a BusyBox ash prompt and runs external
applets. This is the most externally legible milestone the project has: not
"the kernel serves a page", but "you can log into it".

## M2: a practical root filesystem

- **#182** -- ext2 indirect blocks, multiple block groups, nested directories.
- **#208** -- block buffer cache (today every ext2 operation re-reads the
  superblock and group descriptor from the device).
- **#207** -- O(1) free-slot allocation. `page_alloc`'s 1024-entry linear scan
  is the acute case and gets worse as processes multiply.

Done when: a real Alpine-shaped tree with a `/bin` symlink farm boots and
multiple applets dispatch normally.

## M2': QEMU/AArch64 kernel target, then CI

Runs in parallel with M1 and should be pulled forward rather than left to the
end. **No issue tracks this yet** -- `kernel/README.md` names QEMU/AArch64 as the
intended next port, but nothing tracks it.

Three unrelated problems collapse into this one:

1. **#56 (CI)** becomes possible at all. Today regression detection is one
   physical board.
2. **#149 (GDB without JTAG)** is solved for free by a QEMU target's gdbstub.
3. The #226/#227 iteration cycle stops paying a roughly one-minute SWD transfer
   per attempt.

Real hardware stays the authority for anything involving cache, DMA, interrupt
timing, or true concurrency (`AGENTS.md`'s tier-3 rule is unchanged). QEMU is a
second net, not a replacement.

## M3: real SMP

- **#222** -- generalize `execution_*`/`scheduled_process_*` globals to per-core
  state, using the existing `PerCore(T, N)`-shaped const generics. After #224.
- **#17** -- atomics. A genuine multi-core scheduler needs them.
- Then: cores 1-3 actually run processes, rather than core 1 proving EL1 entry
  and parking.
- **#202** (UserRange TOCTOU across preemption) stops being theoretical once
  genuine concurrency exists; **#85** (lost-wakeup-safe event waiting) is the
  design question for non-AArch64 targets.


Done when: independent EL0 processes run on 4 cores with real-hardware
preemption evidence.

## M4: minimize the hand-verified core

This is the framekernel thesis stated in `AGENTS.md` made measurable, and it can
proceed in parallel with M1-M3. Serial internally:

1. **#225** -- first-class symbol addresses and embedded blobs. Deletes six
   `adrp/add` accessor functions and makes `mmu.S`'s page-table regions nameable
   from `.tkb`, which is the prerequisite for step 2.
2. **#226** -- a closed, enumerated set of system-register/barrier/TLBI
   intrinsics, each carrying its mandatory barrier. Explicitly *not* general
   inline assembly. Lifts `timer.S` and most of `mmu.S`.
3. **#227** -- declare the exception frame and vector table in `.tkb` and
   generate save/restore, removing the hand-maintained `EL0_CONTEXT_SIZE`
   duplicate and the two-divergent-frame-layouts condition that allowed #223.

Done when: `kernel/arch/arm64` assembly drops from 1,300 lines to under ~300,
and the remaining lines are genuine instruction emissions. Unlike most of this
roadmap, progress here is a number, which is exactly what a claim about a
minimal hand-verified core needs.

## M5: raise the proof ceiling

Cheap and concrete first:

- **#199** -- split `UserRange` into `UserReadRange`/`UserWriteRange`.
- **#218** -- require `unsafe` for integer-to-pointer casts from calculated
  values (literal-address casts stay ordinary).
- **#217** -- index expressions targeting a struct field, and bounds-checked
  struct array fields. Both #207 and #216 hit this directly.
- **#131** -- arbitrary stored indexed owners. This is a *promotion*, not
  backlog: the same wall appears in #156's "indexed owners cannot be array
  elements" finding, in #207's freelist, and in #216.

Then, research. Five parallel research issues (#200 #201 #203 #216 #109) is too
many to be a plan. Recommendation: drive exactly one to a real implementation.

**Suggested pick: #203** (prove no syscall copies uninitialized kernel memory to
userspace). It has the clearest security payoff, it is a top-severity real-OS
vulnerability class, an existing runtime discipline (`user_zero_fill`) already
marks every site that would need the static property, and a plausible design
exists that does not require a solver -- initialized-ness as a type state on a
scratch buffer. #200 and #201 both need real solver work (#13) and are a
different order of magnitude.

## M6: a third architecture

Deliberately speculative; recorded as direction, not as scheduled work.

- **#50** RISC-V, or AMD64 (#222's per-core design already anticipates 24
  logical cores).
- **#95** true separate compilation. Suggested numeric trigger for re-evaluation
  rather than a date: `kernel/` exceeding roughly 20,000 lines, or build time
  becoming an actual complaint.

## Proposed issue hygiene

None of this has been applied; it is recorded here as the recommendation.

**Close or merge**

- **#5 (inline assembler)** -- close. #226 makes general inline assembly an
  explicit non-goal, with a specific argument: #209's second bug was caused by a
  human choosing which register would survive a call, and general inline asm
  hands that burden back to `.tkb`. Keeping an issue open that contradicts a
  settled design decision is worse than having no issue.
- **#90 and #200** -- substantially the same request (relational/correlated
  bounds). Merge into #200, with #13 (Z3) as the umbrella for that axis.
- **#15** -- after #217/#218 were split out, what remains is null safety,
  use-after-free, and address-space typing; the last is already partly real in
  `kernel/mm/user_memory.tkb`. Re-scope against what `kernel/` actually has.

**Create**

- A QEMU/AArch64 kernel target issue (M2'), which #56 and #149 then depend on.

**Project board**

The [project board](https://github.com/orgs/takibi-lang/projects/2) is the
intended home for status, kept by hand. The axes above (A through G) and the
milestones M0 through M6 map onto board fields directly; `blocked` and
`latent-bug` are worth having as their own field or label, since both change
what should be worked on next rather than merely describing a topic.

The division of labor: the board answers "where is this now", this file answers
"why in this order". Neither should try to answer the other's question.

## Relationship to YAGNI

`AGENTS.md`'s YAGNI principle is a durable project stance, and this file is in
tension with it by construction. The intended reading:

- **M0 and M1 are present requirements**: known defects and a stated near-term
  goal.
- **M4 and M5 are not exempted by YAGNI, they are outside it**: the compile-time
  proof machinery is the project's own stated purpose, which that principle
  explicitly carves out.
- **M6 is speculative** and is recorded so that decisions made now (e.g. #222's
  per-core shape) do not accidentally foreclose it. It is not a commitment to
  start.

When a milestone here conflicts with a concrete requirement in front of you, the
concrete requirement wins and this file gets updated.
