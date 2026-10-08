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

1. Wait for #637 stage 1 to land; both edit the ownership checker.
2. #131's design, together with #672 stage 2 (array elements); #637 stage 2
   adopts the result rather than a parallel mechanism.
3. First concrete driver: #622 (a DMA token held in the RX frame owner).
4. Then #707, the process-record typestate group (#653, #590, #308), #686,
   #687, #704 and #343, each as a consumer of the same rule.

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

## Territories, re-cut 2026-09-25; queues refreshed 2026-10-08

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
   exists but is not enabled for maintained kernel builds. Next in this stage:
   #724's readonly array-slice permission gap, #725's fallible syscall copy
   outcomes, bounded syscall copy forwarding, typed probe atomics, remaining
   per-CPU consumers, then the reviewed finite mint list and kernel flag
   activation.

   - **B, raw atomics:** use the existing typed atomic cell at probe and
     consumer boundaries; remaining raw-address operations must be confined.
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
On 2026-10-04 the maintainer authorized autonomous B work in priority order
where acceptance is settled; leave design investigations and unmet
implementation gates parked.
The spread fixture now observes the actual EL0 timer ToIdle transition
before wait4, with negative controls for a disabled leave and a missed CPU 0
arrival window. #706 evaluates explicit fail-stop provenance; it remains a
design investigation.
#680, #681 and #682 (the pin's cost) stay with A: they need RPi5
measurements first.

**Order set by the maintainer on 2026-10-08,** after an inventory of every
open issue: a hole in an existing compile-time guarantee comes before a new
guarantee, and a time measurement method before the decisions waiting on it.

1. **A time measurement method, after Territory A is mostly done**
   (maintainer, 2026-10-08): #497, then #502. #718, #711, #520 and A's
   #680-#682 wait on it, because space and time are both kept. #719 (every
   QEMU lane on four vCPUs under a host-wide vCPU budget) also waits for A:
   its runners and boot views overlap #637.
2. **Signal delivery at interrupt return (#628), after #637 stage 1
   lands** (both edit `process.tkb` and `syscall.tkb`).
3. **Stored authority (#131),** which starts once #637 stage 1 has landed;
   its order is in "Ordered routes" above.
4. **Remaining work, in this order:** #520 (TCP throughput), #386
   (retransmit frame copy and global chain head),
   #220 (telnet; not urgent, waits on PTY and `pselect6` scoping).
5. **Compiler safety and language research:** #608 (checked integer to
   enum conversion; not urgent), #203, #252, #200, #201, #282, #129, #417,
   #155, #28, #8.
6. **Toolchain, portability and hardware-lane support:** #706 (a design
   investigation), #123, #124, #122, #95, #51, #50, #85.
7. **Evaluations and maintainer decisions, not scheduled:** #648 and #688
   (evaluations), #702 (dedicated soak hardware), #9 (SMP process admission;
   its open items touch `process.tkb`, so after #637 stage 1).
8. **Deferred or not a scheduled work item:** #432, #555, #250, #444,
    #429, #149, #567, #539, #536, #624, #132; #13 for `Phi`, with #216 and
    #109 as candidate examples, only after the solver threshold is met.
    Also deferred: #712 (compiler-derived liveness-escape attribution after
    the concrete source-check parser failure), #58 (static whole-call-path
    stack bounds; lowered by the maintainer on 2026-10-04), #698 (metadata
    mutation exhaustion), #699 (host-side EL0 postmortem symbolization),
    #709 (permanent table generation exhaustion), #710 (intrusive pool
    generation exhaustion), #718 (PageMeta's physical field; waits for the
    time measurement method in band 1), #711 (FD-service allocation
    contention and descriptor-access measurement; observation method and
    representative workload precede candidate implementation).

Items are ordered within each band as well as between bands. The deferred
items stay listed so a changed premise can bring them back into the queue.
