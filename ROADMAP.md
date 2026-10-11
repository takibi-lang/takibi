# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories, re-cut 2026-10-09

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision.

**The split (maintainer, 2026-10-09).** Territory A holds only the trunk:
memory safety and multicore -- the stored-authority rule and the kernel-core
consumers that need it, the safe-memory-access route (#637), preemption,
and the evidence those steps are judged by. Its steps run one at a time,
each on the previous one's four-core RPi5 evidence. Everything else is
Territory B's, in the priority order below: drivers and their DMA follow-ups,
diagnostics, fixtures, compiler and language work, measurement and
optimization, toolchain. The rules A has landed -- places (`Place(T)`,
`place_take`/`place_put`), per-CPU storage (`cpu_authority`/`per_cpu`),
fixed DMA records -- are B's to use; a B issue that needs a rule A has not
landed asks A rather than adding a local special case. If a B issue turns
out to block a step of A's route, A pulls it and says so on the issue.

**Loosely coupled (maintainer, 2026-09-29), since either may stop for days.**
A changes the kernel core's runtime behavior and needs four-core RPi5
evidence. B delivers independent fixes, fixtures, diagnostics, compiler
capabilities and build checks, which A adopts at its own pace. Neither
waits. The maintainer rebases and merges often, which is what prevents
double implementation; a conflict in a shared file is expected to be
incidental.

**A red allcheck comes first (maintainer, 2026-09-27).** A failing `make
allcheck` stops every other piece of work, and the lane that meets such a
failure analyses and fixes it, whatever territory its cause lies in. The
goal is to drive the probability of an allcheck failure toward zero step by
step. A holds the analysis of #604, #603, #605, #607, #649, #654, #655, #665
(its handoff memo), #667, #670, #673, #676, #685 and #690 when they next
recur.

**QEMU's role (maintainer, 2026-10-03):** QEMU gates functional verdicts
only; verdicts decided by elapsed time or ticks print RECORDED under QEMU
and are decided on the RPi5. Hardware-specific defects are hunted on the
RPi5 under load (#584's churn); each defect it finds gets a deterministic
lane (`kernelcheck-race-window-*-qemu`) before its issue closes.

### Territory A: the trunk, in this order

Done on the stored-authority route (2026-10-09): #637 stage 1's
type-checker work and #731 step 1; #131's first slices -- field places
(borrow in place) and `Place(T)` with
`place_take`/`place_put` for every stored slot, `stable_replace` removed
from the language -- on #732's generic variants; #704's per-CPU storage
(exec args migrated); GEM's RX and TX buffers as fixed DMA records. exception_evidence's per-core arrays stay ordinary arrays:
DDB reads other CPUs' entries on purpose, which is settled with #637's mint
list (maintainer, 2026-10-09).

1. **Stored authority for arrays and pools.** #131's remaining shapes
   with #672 stage 2: array-element places, an array of indexed owners, and
   borrowing an element in place. #343 (use-after-free now that a heap
   exists) is its first consumer; #518's typed slot addresses are done
   (2026-10-10). B's #720 B+C consumer also needs general retention of a region
   inside a linear protocol owner, with checked field moves and borrow
   expiry; the concrete nested-owner rejection is on #131/#672.
2. **The process record.** #202 (UserRange epoch); the rest of the
   typestate group is done.
3. **#637 stage 3: shrinking the mint list.** The file-confinement flag is
   enabled for both maintained kernels with a reviewed list
   (`kernel/RAW_MINT_FILES`); calls of `region_bytes_assume` count as mints.
   Next: step A (remaining MMIO through IoHandles: RPi5 PCIe, virtio-net,
   virtio-blk, the system timer DTB reader, xHCI registers), then step B
   (page and pool chunks over regions, using the shared bounds-contract
   prototype). xHCI MMIO step A coordinates with B's #720 partial-DMA
   design: preserve matching-completion, publication and stop/reset hooks;
   use IoHandles there without adding a DMA-specific storage rule. B's
   #720 also needs general exclusive backing storage on #637/#672:
   region_of currently permits direct access to the source array. #739
   (stale list entries, per-file counts). log.tkb's
   raw sites go with #613: a lockless multi-writer log ring with its
   protocol in the type system, its orderings checked by #645's herd7
   litmus tests.
4. **Preemption.** #638's typed preparation -- a preemption-disabled
   authority, with per-CPU access (`cpu_authority`) derived from it in place
   of the `KERNEL_PREEMPTIBLE == 0` asserts -- with #606 stage 2 (a TLC trace
   spec replacing the Python replay; #656 extends it to LogReader) and #641
   (the world stop in TLA+). Then the flip: measure candidate designs on
   RPi5 and set `KERNEL_PREEMPTIBLE` to 1, with the models passing without
   their no-preemption guards. Never while #584's soak is being run for a
   step's evidence.
5. **Signals and SMP admission on the settled core.** #628 (delivery at an
   interrupt return), then #726 (a caught signal interrupts a sleeping
   syscall; EINTR versus restart needs a decision), with #432 (timed
   blocking) beside it; #9 (SMP process admission).
6. **Research applied to a real example** (evaluated 2026-09-29; reasoning
   on #13): indexed views generated from a TLA+ model's actions, prototyped
   on #613; coordinate that generator's authoring surface with B's #720
   B+C prototype before building separate generators. Iris vocabulary for
   lock and pool invariants (#132).

**Evidence for the trunk, scheduled by A:** #584's soak at natural
boundaries, #702 (dedicated soak hardware, the maintainer's decision),
#652 (lifecycle trace events for signals and wait4).

### Territory B: everything else, ordered by priority

On 2026-10-04 the maintainer authorized autonomous B work in priority order
where acceptance is settled; leave design investigations and unmet
implementation gates parked. Prefer what A consumes at once -- fewer red
allchecks, faster diagnosis -- and what finishes on its own.

Done on 2026-10-10: see HISTORY.md and the closed issues. Production #252
allocator migration remains a separate design gate.

Initialization does not prove CPU freshness across preemption.

1. **Fixed DMA lifecycle, finishing the drivers.** Every stage of one
   transfer in types, leaving one device-semantics declaration per driver
   and the platform bus translation as the only trusted parts.
   - #720 (session-long xHCI rings and contexts): B+C selected on
     2026-10-11, general region authority plus model-derived permissions.
     B advances the partial-handoff model and type connection; A supplies
     the demonstrated general memory prerequisites on #131/#672/#637
     (region retention in a linear owner and exclusive backing storage).
     No local DMA storage exception. Coordinate MMIO observation hooks;
     see docs/XHCI_SHARED_DMA_DESIGN.md. #625 (cache visibility across DMA
     ownership handoffs, bounded model). #740
     (virtio-net fixed TX/RX-reply authority) awaits the stored-array
     boundary and an in-place reply design decision.
2. **Other compiler and language work, respecting design gates:** #608
   (checked integer-to-enum conversion), #709 and #710
   (generation exhaustion of region tables and the intrusive pool), #203
   (no uninitialized kernel bytes copied to userspace; builds on bounded
   syscall copy outcomes),
   #732's later slices (static parameters on generic variants, implicit
   statics inside a type argument).
3. **Time measurement, then the optimizations waiting on it** (maintainer,
   2026-10-08: space and time are both kept): #497, then #502; then #520
   (TCP throughput), with #741 (locate the measured RPi5 HTTP SYN
   retransmission tails), then #680, #681, #682 (region_pool lock-free
   validation,
   false sharing, pinless single-user pools), #711, #718, #386; #719 (every
   QEMU lane on four vCPUs).
4. **Evaluations awaiting a maintainer decision:** #687 (typed terminal
   mode leases), #648.
5. **Compiler and language research, independent of the ownership
   checker:** #201, #282, #129, #417, #155, #28, #8.
6. **Toolchain and portability:** #123, #124, #122, #95, #51, #50, #85.
7. **Deferred or not a scheduled work item:** #220 (telnet; waits on PTY
   and `pselect6` scoping), #555, #250, #444, #429, #149, #567, #539, #536,
   #698 (ext2 metadata exhaustion as ENOSPC), #374 (physically contiguous
   memory; waits for a dynamic DMA allocation); #13 for `Phi`, with #216
   and #109 as candidate examples, only after the solver threshold in
   `TAKIBI_CORE.md` is met; #712 (compiler-derived liveness-escape
   attribution, after a concrete source-check parser failure); #58 (static
   whole-call-path stack bounds; lowered by the maintainer on 2026-10-04).

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
