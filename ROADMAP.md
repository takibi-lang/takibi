# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories, re-cut 2026-09-25; queues refreshed 2026-09-29

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision. Territory A's route is inherently single-task -- each step needs the
previous one's four-core RPi5 evidence -- so A takes it alone, and every issue
off that route belongs to B even where that risks a merge conflict. The
maintainer rebases and merges often, which is what prevents double
implementation. If a B issue blocks a step of A's route, A pulls it and says
so on the issue. Compiler work a step of A needs is done in A as part of that
step, landed as its own commit.

**Loosely coupled (maintainer, 2026-09-29), since either may stop for days.**
A changes the kernel core's runtime behavior and needs four-core RPi5
evidence. B delivers compiler capabilities and build checks, proven in
compiler tests and `linux_user/`, which A adopts at its own pace. Neither
waits: A does compiler work on its own critical path itself.

### Territory A: the multicore route, in this order

**A red allcheck comes first (maintainer, 2026-09-27).** A failing `make
allcheck` stops every other piece of work, and Territory B is busy, so the
lane that meets such a failure analyses and fixes it, whatever territory
its cause lies in. The goal is to drive the probability of an allcheck
failure toward zero step by step. Held by A under this rule now: the analysis
of #604, #556, #603 and #649 when they next recur.

Step 1, true multicore support, finished on 2026-09-27; #606 stage 1
replays real runs against StackOwnership.tla. Step 2, running the multicore
workload on RPi5 and fixing what it finds, finished its close-out list on
2026-09-30; #584's churn stays a soak run at natural boundaries, and each
defect it finds still gets a deterministic lane (the race-window lanes,
`kernelcheck-race-window-*-qemu`) before its issue closes. The steps keep
their numbers, which issues cite.

3. **Takibi's provisional answer to safe pointers and safe memory access,
   with multicore as a premise.** #637 is the frame: derive every access
   from an authority and shrink the trusted base to named mint sites, in
   four stages, baseline `docs/UNSAFE_INVENTORY.md`. A holds the core
   side (stage 1's atomic, stack/frame and page/user-memory groups, the
   stage 2 decision, the stage 3 flip); stage 0, the device groups and the
   language capabilities are B's. Also A's: #343, #518, #202, #614 (a
   stack-free proof for process start and zombie reap), and #613: a
   lockless multi-writer log ring with its protocol in the type system,
   the multicore-specific subject this discussion is judged against;
   #645's herd7 litmus tests check its orderings, starting with today's
   log. #647 extends #606's trace replay to RecordLifetime and Wait4Block,
   and #606 stage 2 then replaces the Python replay with a TLC trace spec,
   so the replay cannot drift from the `.tla`: the point where model and
   implementation are held together mechanically. Both finish before
   step 4, whose models drop their no-preemption guards.
   #653 moves the wait reason into the Blocked state and retires
   `last_child_pid` as a wait4 input, the class behind #603 and the churn
   hang; it goes with #637 stage 2.
   #638 sets the preemption target this step designs for: full kernel
   preemption, no explicit-point intermediate. Its typed preparation
   belongs here: a preemption-disabled authority, with per-CPU access
   derived from it in place of the 17 `KERNEL_PREEMPTIBLE == 0` asserts.
   Alongside this step, not blocking it (the step 2 audit's follow-ups):
   #641 (a TLA+ model of the world stop), #642 (a boundary fixture for
   signal frames and mmap reuse), #643 (gdb stall dump and ASID jump for
   four-core QEMU churn), #651 (contention probes' rendezvous bounded by
   peer ticks) and #652 (lifecycle trace events for signals and wait4
   results).
4. **Flip to kernel preemption (#638).** Once step 3's authorities exist,
   measure candidate designs' cost on RPi5 and set `KERNEL_PREEMPTIBLE`
   to 1, with the models passing without their no-preemption guards. Never
   while #584's soak is being run for a step's evidence, whose defects
   must stay attributable to multicore.
5. **Apply recent research where a real example needs it** (evaluated
   2026-09-29; the reasoning is on #13). The solver side (#13) is B's.
   A's part, in this order:
   - Prototype on #613: indexed views generated from a TLA+ model's
     actions, so TLC checks the invariant and the type checker checks that
     the code takes only those transitions.
   - Typestate advances with #637 stage 2 (stored authority); #590 and
     #308 are its consumers.
   - Iris supplies design vocabulary for lock and pool invariants (#132,
     deferred in B). A mechanized soundness proof of a Core fragment is
     optional research, not scheduled.
   - Not pursued: the K framework, and a Boogie-style IVL (Why3 if an IVL
     is ever needed).

### Territory B: everything else, ordered by current priority

1. **Kernel and userspace capability:** #595, #635, #640 (report
   unimplemented syscalls reached at run time).
2. **Safe-memory language support that A's route consumes** (moved from A
   2026-09-29; nothing here waits for A): #639 (#637 stage 0, the
   raw-dereference ratchet); #646 (compiler soundness fuzzing, the
   footing of every static guarantee); #342 (null safety); #13 for `Phi`,
   with #216 and #109 as its first examples; #131 and #370 (stored
   ownership and branded containers, which feed #637 stage 2's option
   (c)). Once A's route step 2 closes: #637 stage 1's device groups, MMIO
   and DMA, together with #622 and #623.
3. **Resource use and measured performance:** #220 (telnet; lowered
   2026-09-30 by the maintainer, not urgent, and it waits on PTY and
   `pselect6` scoping), #389, #422, #497, #520, #553,
   #386, #502.
4. **Compiler safety and language research:** #58, #203, #252, #200, #201,
   #282, #129, #374, #417, #155, #28, #8.
5. **Toolchain, portability and hardware-lane support:** #599, #576, #568, #123,
   #124, #122, #95, #51, #50, #85, #268, #636.
6. **Deferred or not a scheduled work item:** #432, #555, #250, #444, #429,
   #149, #567, #539, #536, #624, #132.

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
