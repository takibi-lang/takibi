# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories, re-cut 2026-09-25; queues refreshed 2026-10-04

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
failure toward zero step by step. A holds the analysis of #604, #556, #603,
#649, #654, #655 (#679 would decide it), #665 (its handoff memo), #670,
#673, #676 and #678 when they next recur.

**QEMU's role (maintainer, 2026-10-03, plan A, done):** QEMU gates
functional verdicts only; verdicts decided by elapsed time or ticks print
RECORDED under QEMU and are decided on the RPi5. Hardware-specific defects
are hunted on the RPi5 under load (#584's churn). #655's deep reproduction
is paused; its notes are on the issue.

Steps 1 and 2 (true multicore support; the multicore workload on RPi5) are
finished. #584's churn stays a soak run at natural boundaries, and each
defect it finds gets a deterministic lane (`kernelcheck-race-window-*-qemu`)
before its issue closes. The steps keep their numbers, which issues cite.

3. **Takibi's provisional answer to safe pointers and safe memory access,
   with multicore as a premise.** #637 is the frame: derive every access
   from an authority and shrink the trusted base to named mint sites, in
   four stages, baseline `docs/UNSAFE_INVENTORY.md`. Stage 0 is done: the
   compiler lists raw-pointer dereferences and every kernel file is held to
   a budget (`scripts/raw_deref_budget.tsv`), so each step below shows as a
   number going down, including the standalone EL0 payloads. A holds stage 1's
   core groups in this order; each rung stands on the one before, so effort can
   stop at any of them:
   - **C, stack and frame:** done. **Region (#672):** the built-in
     `region`/`region_table`/`region_pool`, with pins for objects several
     cores reach by handle, and a linear struct holding one owner (#131's
     first slice). On it: the three TCP pools, AddressSpaceBacking,
     ProcessImageRecord, ProcessFdContext, FdBlock and SharedObject.
     ProcessRecord follows #693: steps 1-4 and 6 landed, step 5 mostly
     (bare record lookups 300+ -> 26, held to that number by
     `scripts/check_process_record_bare_uses.py`). The run
     lock is `single_instance_lock`, so a slot-only reader can take it
     itself and a caller holding the guard is a compile error. On it, the
     fd context and image record handles are read by authority (run lock,
     owner in the reap, peek in crash/diagnostics). Left in step 5:
     address_space_backing (also read from kernel_mmu_init with the MMU
     off), the slot-keyed setters, and the scheduler's state getters. Then step 7. #700 moves the exec's argv
     page before the Exec decision so a shortage returns ENOMEM. #696 types the
     ensure-then-write of the per-process pools. #674 and #675 follow; #680-#682 (the pin's cost)
     are measured first.
   - **B, raw atomics:** a typed atomic cell (issue when C is under way);
     the ordering argument stays with #613.
   - **D, F, H** are already single files: declared as mint files in the
     budget rather than retired.
   Then the stage 2 decision (how a stored authority works) and the stage 3
   flip, which makes a FILE the unit of a mint site. #653's compile-time
   closure belongs there: its run-time fence and trace check have landed,
   and splitting `process.tkb` along its trust boundary is done once, in
   stage 3; `private` is not widened beyond one file.
   Also A's: #343, #518, #202; #613, a lockless multi-writer log ring with
   its protocol in the type system, the multicore subject this discussion
   is judged against (#645's herd7 litmus tests check its orderings);
   #606 stage 2, a TLC trace spec replacing the Python replay so it cannot
   drift from the `.tla`, finished before step 4, whose models drop their
   no-preemption guards (#656 extends the replay to LogReader).
   #638 sets the preemption target this step designs for: full kernel
   preemption. Its typed preparation belongs here: a preemption-disabled
   authority, with per-CPU access derived from it in place of the 17
   `KERNEL_PREEMPTIBLE == 0` asserts.
   Alongside, not blocking: #641 (a TLA+ model of the world stop), #642 (a
   boundary fixture for signal frames and mmap reuse), #643 (gdb stall dump
   and ASID jump for QEMU churn), #651 (probe rendezvous bounded by peer
   ticks), #652 (lifecycle trace events for signals and wait4).
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
     deferred in B); a mechanized soundness proof of a Core fragment is
     optional research. Not pursued: the K framework, and a Boogie-style
     IVL (Why3 if one is ever needed).

### Territory B: everything else, ordered by current priority

**B's window is short (maintainer, 2026-10-03):** B runs for a few days and
then stops, with no successor. Take only items that finish inside that
window and that A consumes at once; leave the bands below untouched rather
than half-done. The shared terminal queue, ordered migration and two-writer
fixtures, finite lock-held BREAK fixture, and board lock measurements complete
the extended short-window queue. #13 remains conditional on the solver
threshold in `TAKIBI_CORE.md`; its recorded examples do not yet justify an
implementation. The maintainer also selected concrete global Cell brands
for this window.
#666 retains work on other console drivers; its oops, QEMU DDB, common UART,
PTY and aggregate await-margin reporting slices are finished. On 2026-10-04
the maintainer authorized autonomous B work in priority order where acceptance
is settled; leave design investigations and unmet implementation gates parked.
#680, #681 and #682 (the pin's cost) stay with A: they need RPi5
measurements first.

1. **Safe-memory language support that A's route consumes** (nothing here
   waits for A): #131 (stored ownership, which feeds #637 stage 2's
   option (c)). Step 2 is finished, so #637 stage 1's device
   groups, MMIO and DMA, together with #622 and #623, can proceed.
2. **Resource use and measured performance:** #220 (telnet; lowered
   2026-09-30 by the maintainer, not urgent, and it waits on PTY and
   `pselect6` scoping), #389, #422, #497, #520, #553,
   #386, #502.
3. **Compiler safety and language research:** #203, #252, #200, #201,
   #282, #129, #374, #417, #155, #28, #8.
4. **Toolchain, portability and hardware-lane support:** #123,
   #124, #122, #95, #51, #50, #85, #666.
5. **Deferred or not a scheduled work item:** #432, #555, #250, #444, #429,
   #149, #567, #539, #536, #624, #132; #13 for `Phi`, with #216 and #109 as
   candidate examples, only after the solver threshold is met. Also deferred:
   #58 (static whole-call-path stack bounds; lowered by the maintainer on
   2026-10-04), #698 (metadata mutation exhaustion), and #699 (host-side EL0
   postmortem symbolization).

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
