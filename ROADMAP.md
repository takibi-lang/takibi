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
of #604 and #556 when they next recur.

1. **True multicore support**: done (2026-09-27). Every online core runs
   ordinary processes, including PID 1 on core 0's idle loop; exec, clone,
   fork, vfork and syslog run on a peer. The models lead the changes: every
   path a model drops is justified, every row carries a review stamp, and
   a window of real steps is replayed against StackOwnership.tla on every
   kernel lane (#606 stage 1; stages 2 and 3 are unscheduled).
2. **Next: run the multicore workload mainly on RPi5 and fix what it finds.** #584
   is the workload, #572 its fairness verdict. Each defect it finds gets a
   deterministic lane before its issue closes; #615's race-window switch is
   how a window found by chance is made to fail every run.
   **Finish before step 3 starts (maintainer, 2026-09-29)**, because known
   defects left open under step 3's kernel-wide changes would be masked or
   misattributed. In this order:
   - #634: restore a two-core concurrent fault scenario in the oops lane.
     #632's fix removed the premise of the old peer_fault mode.
   - #631: the uart-wake peer-console intermittent. Measure its rate with
     `scripts/repeat_kernel_lane.sh`; if it does not recur, record the
     measurement and decide.
   - #572: a bounded busy-pair fairness verdict.
   - #633: the churn hang (ash in rt_sigsuspend with no children and no
     pending SIGCHLD). Not seen in four RPi5 long runs since #632; decide
     whether to close it or keep it open, since no mechanism is known.
3. **Takibi's provisional answer to safe pointers and safe memory access,
   with multicore as a premise.** #637 is the frame: derive every access
   from an authority and shrink the trusted base to named mint sites, in
   four stages, baseline `docs/UNSAFE_INVENTORY.md`. A holds the core
   side (stage 1's atomic, stack/frame and page/user-memory groups, the
   stage 2 decision, the stage 3 flip); stage 0, the device groups and the
   language capabilities are B's. Also A's: #343, #518, #202, #614 (a
   stack-free proof for process start and zombie reap), and #613: a
   lockless multi-writer log ring with its protocol in the type system,
   the multicore-specific subject this discussion is judged against. #638
   sets the preemption target this step designs for: full kernel
   preemption, with no explicit-point intermediate. Its typed preparation
   belongs here: a preemption-disabled authority, and per-CPU access
   derived from it in place of the 17 `KERNEL_PREEMPTIBLE == 0`
   assertions.
4. **Flip to kernel preemption (#638).** Once step 3's authorities exist,
   measure candidate designs' cost on RPi5 and set `KERNEL_PREEMPTIBLE`
   to 1, with the models passing without their no-preemption guards. Never
   during step 2's soak, whose defects must stay attributable to
   multicore.
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

1. **Kernel and userspace capability:** #220, #595, #635.
2. **Safe-memory language support that A's route consumes** (moved from A
   2026-09-29; nothing here waits for A): #639 (#637 stage 0, the
   raw-dereference ratchet); #342 (null safety); #13 restricted to `Phi`,
   with #216 and #109 as its first examples; #131 and #370 (stored
   ownership and branded containers, which feed #637 stage 2's option
   (c)). Once A's route step 2 closes: #637 stage 1's device groups, MMIO
   and DMA, together with #622 and #623.
3. **Resource use and measured performance:** #389, #422, #497, #520, #553,
   #386, #502.
4. **Compiler safety and language research:** #58, #203, #252, #200, #201,
   #282, #129, #374, #417, #155, #28, #8.
5. **Toolchain, portability and hardware-lane support:** #599, #576, #568, #123,
   #124, #122, #95, #51, #50, #85, #268, #636.
6. **Deferred or not a scheduled work item:** #432, #555, #250, #444, #429,
   #149, #567, #539, #536, #624, #132.

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
