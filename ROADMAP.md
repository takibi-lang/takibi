# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Ordered routes: read before starting any issue named here

Set by the maintainer on 2026-10-08. Each issue below is one step of a
route toward a whole compile-time guarantee. Starting one of them in
isolation, with a local fix that adds its own special case, is strongly
discouraged: it would be absorbed or replaced by the route's shared rule.
If a step seems to need something the route places later, stop and ask.

**Stored authority (#131).** One rule for places that hold ownership: a
linear authority kept in a struct field, array element or global slot,
taken and put back without loss or duplication, and borrowed in place.
Static place identity where the place is known; a runtime option tag only
where it is not (#637 option (b)).

1. #637 stage 1's type-checker work has landed (2026-10-09), and #731
   step 1 supplied the place-derived access rule converging on #672.
2. #131's design, together with #672 stage 2 (array elements); #637 stage 2
   adopts the result rather than a parallel mechanism. Next for A.
3. First concrete driver: #622 (a DMA token held in the RX frame owner),
   done 2026-10-09 on the place rule's first slice (field places,
   field_take/field_put, borrow in place).
4. Then #704 with #637's per-CPU consumers (A's next after #622), #707,
   the process-record typestate group (#653, #590, #308), #686, #687 and
   #343, each as a consumer of the same rule; then #637's mint list and
   confinement flag.

**Fixed DMA lifecycle.** Every stage of one transfer in types, so that the
only trusted parts left are one device-semantics declaration per driver
(which marker means completion, what a reset guarantees) and the platform's
bus translation.

1-3. Done (2026-10-08; issues cite steps 4 and 5 by number): a device span
   binds address and length to one allocation; receive and transmit allocations share the CPU/Device
   tokens; device ownership returns to the CPU only in a record's mint file
   (`virtio_blk_dma.tkb`, `usb_xhci_dma.tkb`), whose finishing functions
   `check_dma_mint_files.py` fixes. #637 adds those two files to its
   mint-file list when its file policy is enabled.
4. After stored authority's step 3: #622, then #707 (GEM's tokens held
   across calls).
5. Evidence layers, not prerequisites: linked layout is done; #625 (cache
   visibility model, bounded), #624 (timeout/reset branch fixture). #374
   (physically contiguous memory) waits for a dynamic DMA allocation; #720
   (session-long xHCI rings and contexts) waits for #131.

## Territories, re-cut 2026-10-08

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision.

**The split (maintainer, 2026-10-08).** Territory A holds the multicore
route and every issue that cannot start until that route settles -- its
dependents, including the compiler work they need (stored authority, the
process-record typestate group, signal delivery at interrupt return,
time measurement and the optimizations waiting on it). Territory B holds
the issues that are independent of it now. The previous split put several
compiler-heavy items in B that then waited on A's queue; they are in A
now, so B's queue is work B can actually start. A's route is single-task --
each step needs the previous one's four-core RPi5 evidence -- so A takes it
alone. If a B issue turns out to block a step of A's route, A pulls it and
says so on the issue; if a B issue turns out to need something A has not
landed, it moves to A's dependents rather than waiting in B.

**Loosely coupled (maintainer, 2026-09-29), since either may stop for days.**
A changes the kernel core's runtime behavior and needs four-core RPi5
evidence. B delivers independent fixes, fixtures, diagnostics, compiler
capabilities and build checks, which A adopts at its own pace. Neither
waits. The maintainer rebases and merges often, which is what prevents
double implementation; a conflict in a shared file is expected to be
incidental.

### Territory A: the multicore route, in this order

**A red allcheck comes first (maintainer, 2026-09-27).** A failing `make
allcheck` stops every other piece of work, and Territory B is busy, so the
lane that meets such a failure analyses and fixes it, whatever territory
its cause lies in. The goal is to drive the probability of an allcheck
failure toward zero step by step. A holds the analysis of #604, #556, #603,
#605, #607, #649, #654, #655 (#679 would decide it), #665 (its handoff
memo), #667, #670, #673, #676, #678, #685 and #690 when they next recur;
B's first two bands exist to make those analyses shorter or unnecessary.

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
     ProcessRecord access now derives from a run guard, an indexed current
     phase, or its indexed owner. Private authority makers transfer the pool
     loan instead of returning a bare pointer; generation and Running versus
     Constructing phases are checked at the API boundary. The source gate
     permits no bare record lookup bodies and fixes the reviewed mint set.
     State-changing APIs invalidate live current views at compile time,
     without an added pin, lock, or runtime witness. Private mint sites and
     the physical link to the current CPU remain trusted; stage 2 can narrow
     those remaining boundaries. The run lock is `single_instance_lock`, so
     a slot-only reader takes it itself and nesting is a compile error;
     AddressSpaceRoot carries its backing handle and has declared makers.
     The global-state
     review removed dead FD payloads and coupled boot presence to payload;
     other reductions are YAGNI for current functionality. The three FD pools
     retain their placement; their measurement follow-up (#711) is deferred.
     Space is reviewed at completed
     feature/stage boundaries under `docs/SPACE_REVIEW.md`. #680-#682 retain
     their measured baselines for the optimization decision. The uncontended
     TCP pin/owner and checksum baseline
     is in the shared boot fixture, followed by runtime-online-core empty pool-lock
     and distinct-connection owner contention samples. A same-chunk, distinct-slot
     pin-state comparison now measures same-line versus separate-line traffic;
     its three RPi5 pairs are 5.4-8.8 percent apart. Production packing stays
     unchanged; representative workload evidence is required for a
     subsequent optimization decision.

   The eleven declared liveness escapes are gone. Authority-indexed record
   references, guarded value copies and checked per-CPU places cover process,
   VM, FD, image and syscall consumers. The compiler file-confinement policy
   exists but is not enabled for maintained kernel builds. Done on
   2026-10-09: #724's readonly slices, #725's fallible syscall copy outcomes,
   bounded syscall copy forwarding and typed probe atomics; #731 step 1
   (publish tokens and region elements from checked places are references,
   diagnostic_ring at zero raw sites). **Stage 1's type-checker work ends
   here (maintainer, 2026-10-09)**, so #131 is no longer held for it. The
   remaining per-CPU consumers (exception_evidence's crash caches) need a
   CPU authority that #704 can only design on #131's stored-authority rule,
   so they move after the stored-authority route's step 2; log.tkb's raw
   sites go with #613's rebuild; the AtomicWord reference boundary is
   deferred (no confinement finding at any caller, on #731). The reviewed
   finite mint list and kernel flag activation come last, after those.

   - **B, raw atomics:** the probes use the typed atomic cell (done
     2026-10-09); only atomic_word.tkb, the spinlock and the DDB snapshot
     word call an intrinsic. Whether the cell is reached by `*AtomicWord` or
     by a place-derived reference is #731's question.
     The ordering argument stays with #613.
   - **D, F, H:** retain genuine physical-memory, pool-carving and overlay
     mints with their external evidence. The raw-dereference budget is a
     ratchet, not a reviewed mint-file declaration. High-level consumers must
     not become mint files merely to pass the confinement flag.
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
   `KERNEL_PREEMPTIBLE == 0` asserts. #704 evaluates CPU-local owner
   storage separation and non-migrating access; its design must distinguish
   matching caller indices from trusted storage/authority mint sites.
   Alongside, not blocking: #641 (a TLA+ model of the world stop), #652
   (lifecycle trace events for signals and wait4; it edits `process.tkb`'s
   trace).
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

**A's dependents: issues that start only as A's route settles.** They are
A's because they need its authorities, its process-record and scheduler
shape, or its measurements; none should be started as a local special
case before then (see "Ordered routes").

- **After #637 stage 1 lands:** stored authority (#131 with #672 stage 2)
  and its consumers in the route order -- #622, #707, #720, the
  process-record typestate group (#653, #590, #308), #686, #687, #704,
  #343; signal delivery, #628 (no delivery at an interrupt return) then
  #726 (a caught signal does not interrupt a sleeping syscall; EINTR
  versus restart needs a decision), with #432 (timed blocking) beside it;
  #9 (SMP process admission); #203 (no uninitialized kernel bytes copied
  to userspace; it builds on #725's bounded copy outcomes); #709 and #710
  (generation exhaustion of region tables and the intrusive pool).
- **After A is mostly done -- a time measurement method (maintainer,
  2026-10-08):** #497, then #502. #718, #711, #520 and #680-#682 wait on
  it, because space and time are both kept; #386 (retransmit frame copy
  and global chain head) waits for that profile or for a need for
  per-connection isolation. #719 (every QEMU lane on four vCPUs) waits
  too: its runners and boot views overlap #637.
- **Evidence for the route, scheduled by A:** #613 with #645, #606 stage
  2 with #656, #641, #625 (DMA cache visibility, bounded), #584's soak and
  #702 (dedicated soak hardware, the maintainer's decision).

### Territory B: independent work, ordered by current priority

On 2026-10-04 the maintainer authorized autonomous B work in priority order
where acceptance is settled; leave design investigations and unmet
implementation gates parked. Prefer what A consumes at once -- fewer red
allchecks, faster diagnosis -- and what finishes on its own.

On 2026-10-09, #651's peer-tick waits and #688's evaluation led to the
maintainer-selected existing-type clock and owned resume APIs in #730.
A's AtomicWord probe migration was integrated before the clock API was rebased;
the clock changes preserve its predicates and memory orderings.

1. **Diagnostics A uses on the next recurrence:** #679 (console state dump
   on a stalled shell; a gdb script first, since DDB's file is reshaped
   often), #643 (churn runner: gdb stall dump and an ASID-jump option),
   #699 (symbolize DDB's captured EL0 top PC with exact ELF identity).
2. **Fixtures for paths only refusal and boundary tests reach:** #642
   (corrupted rt_sigreturn, signal-frame overflow, zero-fill on mmap
   reuse), #624 (DMA timeout and failed-reset ownership branches in QEMU).
3. **Tooling:** #727 (positive compiler tests also run codegen, so a
   construct the checker accepts and codegen cannot lower fails `make test`), #728 (a qemu-user reference runner for the
   pinned BusyBox).
4. **Compiler and language research, independent of the ownership
   checker:** #608 (checked integer to enum conversion; the signal table
   is its second instance, syntax deferred until more appear), #252, #200,
   #201, #282, #129, #417, #155, #28, #8.
5. **Toolchain and portability:** #706 (explicit fail-stop provenance; a
   design investigation), #123, #124, #122, #95, #51, #50, #85.
6. **Evaluations and maintainer decisions, not scheduled:** #648.
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
