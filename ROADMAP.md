# Takibi roadmap

This file records priorities, work order, territory assignments, and the
reasons or dependencies that determine them. GitHub issues own their scope,
implementation decisions, acceptance criteria, and findings. Link to the
issue when scheduling work. Record past decisions and events in
`HISTORY.md` and current kernel behavior in `kernel/README.md`.
The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`; the done record of the 2026-10-23
queues is the HISTORY.md entry of 2026-10-25.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories and milestone execution

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision.

### Milestone work allocation

Finish Milestone 1 before starting Milestone 2 implementation. Run one
active work item per territory. Give each shared issue one integrating
territory. When a dependency, decision, or hardware step
blocks an issue, preserve the handoff on that issue and advance independent
work from the current milestone. Land finished branches one at a time.

| Milestone | Territory A | Territory B | Integration dependencies |
| --- | --- | --- | --- |
| 1: kernel landed | Complete the scoped memory-safety contract (#1513), then the remaining globals ratchet (#1159) and preemption integration (#638). | Complete the approved TaskMutex sequence (#1481). Triage #667 when a qualifying capture is available. Board-free preparation for the matched cold-boot comparison (#1158) is complete. Run the RPi5 benchmark on the final Milestone 1 candidate. | #638 flips after #1159 and #1481 meet their gates. Coordinate shared scheduler interfaces and four-core RPi5 regression evidence at these boundaries. |
| 2: language settled | Implement the lossless printer and formatter entry point (#1010). | Develop round-trip and linked-kernel equivalence checks (#1010) against the agreed printer interface. Prepare source inventories and acceptance controls for #1009. | Integrate the printer and its checks before #1009. Use one branch for the syntax migration in the approved order, with the other territory reviewing round-trip and generated-code evidence. Review #1514 before finalizing the relevant syntax. |

This allocation takes precedence over the standing queues. Publish shared
interfaces before dependent work adopts them. The RPi5 lease serializes
regression and benchmark runs. Required regression evidence stays with
each change. Run the #1158 comparison on the final Milestone 1 candidate
and record its revision and configuration. Repeat affected measurements
if a later change alters the measured workload or performance path.

### Standing queue background

**Roles (maintainer, 2026-10-16, #753).** The pillars are multicore
support and memory safety. Territory A takes pillar work that comes as
chains of dependent issues (like the #637 family) and still carries the
heavier load. Territory B takes pillar issues that can be solved
independently, so both lanes run, and the issues slightly off the pillars.
An urgent issue that comes up mid-work is scheduled by the coordinator,
which rewrites the priorities below and says so on the issue.

**Support lanes (maintainer, 2026-10-25).** Territory B's queue serves
the multicore and memory-safety pillars through solver evidence (#954),
compiler checks (#567), and Linux and libext2fs comparisons. Territory A
adopts each support result at its next work boundary.

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
step. A holds the analysis of #604, #603, #605, #607, #649, #654, #655,
#667, #670, #673, #676, #685 and #690 when they next
recur.

**QEMU's role (maintainer, 2026-10-03):** QEMU gates functional verdicts
only; verdicts decided by elapsed time or ticks print RECORDED under QEMU
and are decided on the RPi5. Hardware-specific defects are hunted on the
RPi5 under load (#584's churn); each defect it finds gets a deterministic
lane (`kernelcheck-race-window-*-qemu`) before its issue closes.

### Evidence for the pillars (shared, scheduled by A)

- #742 stages 2 and 3 (CLONE_VM, futex, TLS, TLB shootdown) wait for
  the #638 flip. Use `make load-qemu` and `make hwcheck-load-rpi5` to
  find defects. QEMU records timing; RPi5 decides timing verdicts.
  The stress-ng exec stressor waits for `readlinkat` on
  `/proc/self/exe` (#1190). Record matched Linux evidence in
  `docs/LOAD_SERIES.md` under #1158. #1014 measures run-lock contention
  on this workload and remains parked.
- #584 is the load and soak workload. Dedicated soak hardware (#702)
  is the maintainer's decision. Maintained QEMU lanes default to four vCPUs.
- The RPi5 lane watches the parked triggers for #680 and #812.

### Territory A: the trunk, in this order

1. **Scoped memory safety (#1513).** Fresh user pages and newly published
   L3 tables have initialization checks. Bounded L3 retirement orders
   descriptor unlink, invalidation and reuse at runtime. The static
   lifetime of resident tables remains open. The complete Pipe static
   guarantee is deferred. TCP receive initialization across slot
   reacquisition and the lifetime of the old COW source need design
   decisions. Use #203, #637, #954, #986 and #132 for the supporting
   evidence and contracts.
2. **Global protection (#1159).** The boot handoff and FD probe migrations
   are published. Eleven allowances remain at this snapshot. The child
   EL0 frame keeps dedicated storage after the compile-only experiment
   accepted overlaps and lifetime escape. Continue with the remaining
   reviewed allowances when their design gates clear. The build reports
   the current count; `docs/GLOBAL_PROTECTION.md` describes the ratchet.
3. **Preemption (#638).** The raw CPU reader audit leaves three reads in
   the stack-arrival and task-start paths. Decide how to cover both with
   the existing CPU authority while preserving the unlocked negative
   control. Measure the approved migration path at matched internal
   boundaries and end to end before the flip. The flip requires #1159
   and #1481 to meet their gates. Keep the existing #1323 lifecycle spans.
4. **Stored authority (#637).** Continue the remaining L3 ownership and raw
   exports. The clone saved-SP trial reached a decision on retaining
   parent evidence across the run guard or copying inside that guard.
   The DDB ring reads in `rp1_gem` and `virtio_net` wait on #1286.
   Section regions (#777) need a decision for `stack_poison.tkb` and the
   DTB. Use `make raw-site-counts` to select the next applicable site.
   The frame and built-in consolidation work remains in #1017 and #750.
5. **Hardware isolation (#1032).** The linked PAN, WXN and PXN checks and
   QEMU permission controls are in use. The RPi5 RP1 inbound window
   confines DMA to one arena. QEMU PCI virtio and SMMUv3 remain staged
   block-first, with MMIO coverage retained. The compile-only capability
   experiment checked access bounds. The transport still needs decisions
   on capability selection and who assigns and validates BAR extents.
   Process-stack guard arenas (#1226) need a capacity decision before
   connecting the tested layout to the runtime.

A red allcheck takes precedence. Advance independent work when an item
reaches a decision. #799 waits under #954 until a real site needs it.

### Territory B: supporting the pillars, by priority

**Milestone 1 first.** Finish the #1481 TaskMutex sequence before the
#638 flip. The existing ext2 mutation and getdents64 admission paths can
park. The retained-inode retirement prototype keeps the obligation in its
guarded place and passes a generation-indexed I/O permit. Connecting it to
the real FD teardown paths needs a decision on checked continuation
admission before irreversible teardown. After the eligible reader and
writer paths are connected, measure uncontended and contended acquisition
on RPi5. #667 waits for a qualifying capture, and #1158 waits for the final
Milestone 1 candidate.

**Standing queue (maintainer, 2026-10-23, re-cut 2026-10-25).**
Low-dependency items in this order. Park each design decision and advance
independent work.

0. **Compiler checks and trust ratchets.** Move eligible source and
   call-graph checks to the compiler one at a time (#567). The caller
   policy, diagnostic event IDs and ext2 release-log checks now run in
   OCaml. Preserve input coverage during migrations. Keep #850 in its
   agreed checker band and continue #1031 and #986 where a concrete
   change needs their ratchets.
1. **Verification (#954; B owns refinement code).** Maintain #955
   evidence and the #986 trust ledger. Use `docs/VERIFICATION_DESIGN.md`
   for the existing proof boundaries.
2. **Equivalence oracles.** Maintain the ext2 image, operation and
   host-driver comparisons and the signal conformance suite. Keep
   #1067's ext2 writer fixture constraint and the #946 signal-handler
   contract visible at these boundaries.
3. **Compiler consolidation.** #750 follows #732. The remaining #1027
   CLI steps wait for #1006 and #1009.
4. **Fixed DMA lifecycle.** #720 retains the remaining multi-command and
   subregion-lifetime work after the checked DCBAA publication slice.
   #740 has published the RX split. The queued socket integration needs
   a decision on preserving the current direct TX copy and lock order.
   Keep the matched direct HTTP comparison and RX cost attribution
   distinct.
5. **Independent pillar work.** Review ranked lock tokens (#789) after
   syntax review, then carry IRQ state in a token (#850). Follow with
   the authority-boundary words.
6. **Other compiler and language work.** #203 stage 3 covers cross-call
   contracts and byte ranges. #732 has later slices, #752 covers kernel
   typestate, and #751 waits for a consumer. #747 remains deferred.
   The switch and block DDB diagnostics (#898) are published. Follow-up
   regressions are tracked for alternate-stack signal frame zeroing
   (#1521) and exit-to-successor DDB visibility (#1522).
7. **Measurement before optimization.** #520 (TCP throughput, with #972),
   #741 (RPi5 HTTP SYN retransmission tails), then #680, #682, #711,
   #718 and #386.
8. **Research on real examples.** #613 covers model-derived indexed
   views. #132 covers Iris vocabulary for lock and pool invariants.
   See #13 for the research rationale.
9. **Evaluations awaiting a maintainer decision.** #687 (typed terminal
   mode leases) and #648.
10. **Independent language research.** #201, #282, #129, #417, #155,
    #28, #8 and #200.
11. **Toolchain and portability.** #123, #51, #50 and #85. #95 remains
    research until separately compiled type-contract validation is
    needed. #122 waits for #1009. #124 is lowest priority, with DDB
    ahead of GDB.

Items are ordered within each band as well as between bands.

### Two milestones (maintainer, 2026-10-28)

Two moments on this roadmap are the maintainer's to act on, not a
territory's, and each is a GitHub milestone so that the moment is announced
by the repository (`.github/workflows/milestone.yml` opens one issue,
assigned to the maintainer, when a milestone's last issue closes) rather
than noticed by whoever happens to be reading.

- **kernel landed** (milestone 1): remaining milestone issues are the
  scoped memory-safety contract (#1513), globals at zero (#1159), the
  preemption flip (#638), the settings-wake intermittent (#667), and the
  final distribution-benchmark comparison with Linux (#1158). The
  TaskMutex sequence (#1481) is a prerequisite for the flip. When the
  milestone closes, the maintainer posts the kernel to Hacker News and
  starts the first paper.
- **language settled** (milestone 2): #1010 (the lossless printer and
  `takibi fmt`), #1514 (the generic-constraints evaluation), and #1009 (the
  syntax edition). When the milestone closes, the maintainer starts looking
  for co-authors and co-developers in earnest.

A worker that closes one of these issues says so on the issue; the
coordinator checks the milestone after the land (`coordinate` skill).

### Awaiting the maintainer

Decisions the queues above stop at; each is recorded in DECISIONS.md when
made.

- **The syntax review (#1006)** has its agenda (attributes and inner
  attributes, the reasoned exemption, ranked lock tokens, `region NAME
  from section`, `FrameRef`'s indices, the IRQ-state token, marker
  effects, generic variants, privacy modules, the edition's rows). Trigger
  (maintainer, 2026-10-25): before #789's token design starts, and before
  the next split of `process.tkb` or `syscall.tkb` that #1008's `module`
  line would otherwise have to retract.
- **The consolidation umbrellas** are decided direction and deliberately
  off these queues except their stop-gaps in band 0: #986 (trusted-base
  ledger; #1017 the frame), #998 (signals: three tiers, never silently
  different), #1002 (language surface), #1008 (privacy modules), #1012
  (globals), #1027 (CLI). **#1009 (the syntax edition) is done last** of
  them, after #1010 (a lossless printer and `takibi fmt`), which is its
  only prerequisite.

### Deferred or not a scheduled work item

#220 (telnet; waits on PTY and `pselect6` scoping), #555, #250, #444,
#429, #149, #567's remaining items beyond band 0, #539, #536, #969
(counting `Ext2Slot` holdings in the effect system; #1026 is its token
form), #374 (physically contiguous memory; waits for a dynamic DMA
allocation); #13 for `Phi`, with #216 and #109 as candidate examples, only
after the solver threshold in `TAKIBI_CORE.md` is met; #712
(compiler-derived liveness-escape attribution); #58 (static whole-call-path
stack bounds; lowered by the maintainer on 2026-10-04); #1001 (job control:
refused loudly until a workload reaches it, not before the #638 flip);
#1014 (run-lock contention,
measured on #742 stage 1's load before any per-CPU run queue).

The deferred items stay listed so a changed premise can bring them back
into the queue.
