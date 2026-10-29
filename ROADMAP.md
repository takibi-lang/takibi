# Takibi roadmap

The current work split, and nothing else. It is rewritten when priorities
move and is expected to go stale. Findings belong on the GitHub issue they
concern, reasoning and past events in `HISTORY.md`, current behavior in
`kernel/README.md`. Do not add an investigation record here: this file is for
who does what next. The version before 2026-09-23, with every queue's
history, is archived in `HISTORY.md`; the done record of the 2026-10-23
queues is the HISTORY.md entry of 2026-10-25.

Live intermittents are listed in `docs/KNOWN_INTERMITTENTS.md`, not here.

## Territories, re-cut 2026-10-25

A territory is a role, not a set of directories and not a particular agent
(`AGENTS.md`); which agent holds which is the maintainer's per-session
decision.

**Roles (maintainer, 2026-10-16, #753).** The pillars are multicore
support and memory safety. Territory A takes pillar work that comes as
chains of dependent issues (like the #637 family) and still carries the
heavier load. Territory B takes pillar issues that can be solved
independently, so both lanes run, and the issues slightly off the pillars.
An urgent issue that comes up mid-work is scheduled by the coordinator,
which rewrites the priorities below and says so on the issue.

**The pillars need their support lanes (maintainer, 2026-10-25).** The
two pillars remain the most important near-term goal: without them the
kernel's skeleton is not fixed. What the 2026-10-24/25 review showed is
that they do not grow soundly on their own. The z3 second judge (#952,
#954) found several existing defects within days; moving the `.tkb`-reading
build checks into the compiler (#567) stops a tax that takes more of the
commits than the compiler they guard; equivalence oracles against host
Linux and libext2fs (#999, #1034) turn review chains into tests. So
Territory B's queue is ordered by what serves the pillars, and A adopts
each support result (a facts table, an oracle, a ratchet) at its next work
boundary rather than later.

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

- **#742 stage 1 done** (2026-10-25): `make load-qemu` (four vCPUs) and
  `make hwcheck-load-rpi5`, in no aggregate (#742's rules: a finder, never
  the evidence a defect is fixed; time verdicts decided on the RPi5).
  stress-ng 0.20.01 and hackbench 2.9 are built as musl static PIEs by
  `scripts/build_load_programs.sh` into a cache outside the repository.
  Today the BusyBox `xargs -P 4` and hackbench phases run; the load found #1039 (an
  execve argv that fail-stops the kernel; done 2026-10-25), #1040 (an unmappable ELF ran
  BusyBox; done 2026-10-25; #1065 then removed the argv[0] image choice), #1041 (images over
  a 2 MiB span: stress-ng; done 2026-10-26, `stress-ng --version` runs) and #1042 (pipe2,
  done 2026-10-25, unblocks hackbench and stress-ng `--pipe`). #1138 (sigaltstack, done
  2026-10-26) took every stressor past its setup, and #1147 (shared anonymous mmap, statfs,
  getrusage, umask; done 2026-10-26) past its shared region; the stress-ng phases now wait for
  #1151, the 128-page mmap arena that refuses stress-ng's shared cache buffer (ENOMEM). The fixture
  rootfs grew from 2816 to 6144 blocks to hold both programs, so QEMU and
  the board boot the same image (maintainer, option b: one board build,
  sized from content; about 18 s more SWD per RPi5 lane run). Each program is recorded beside the same program under Linux
  on the same machine (maintainer, 2026-10-25): a reference column, never
  a verdict -- the host, natively, on four CPUs, since this tree builds no
  Linux guest. #1014 (run-lock contention, parked) is measured on this load
  and nowhere else. Stages 2 and 3 (threads: CLONE_VM, futex, TLS, TLB
  shootdown, #202's sibling-thread case) wait for the #638 flip.
- #584's soak at natural boundaries; #702 (dedicated soak hardware) is the
  maintainer's decision. Every QEMU lane runs four vCPUs since 2026-10-11.
- The parked triggers #680 and #812 are watched by the RPi5 lane
  (`scripts/validate_parked_triggers.py`, #953).

### Territory A: the trunk, in this order

**Assigned queue (maintainer, 2026-10-23, pruned 2026-10-25).** Memory
safety and multicore backbone only. Taken in order whenever the numbered
trunk items below have no step ready; an item that reaches a decision is
parked and the next one taken:
#1096 (the locks #1071 left masked) is done (HISTORY.md: the generated DMA
owners are TaskMutex, the spare stack stays masked). #980
(reboot through the debug stop) is done (HISTORY.md). #799 waits under #954 until a site needs it.

1. **Stored authority and the mint list (#637 stage 3).** Done since
   2026-10-09 through 2026-10-25 (HISTORY.md): places, per-CPU storage,
   RegionPool records, header overlays, the process-stack run owner, the
   per-CPU scratch migration (#981, #982). What remains: the K category of
   `kernel/RAW_MINT_FILES` -- `rp1_gem`, `virtio_net`, `virtio_blk`
   (`drivers/block/memory` left 2026-10-26: a checked slice; `virtio_net`
   is down to its DDB used-index read, #1164; `virtio_blk` to its span
   export, #1162; next #1162, #1163, #1032) -- leaves through device protocols and
   `IoHandle` as `usb_xhci` did (#720), which is also "drivers out of the
   frame" in #1017; then section regions (#777, awaiting its decision) take
   `stack_poison.tkb`'s last integer ranges and the DTB blob. The frame API
   rule holds as `scripts/check_frame_api.py` (#1018, done 2026-10-25):
   eight ratchet exports remain, two of them (`mmu_user_l3_physical`,
   `fdt_memory_first_base`) to owners under #637. `make
   raw-site-counts` picks the next file. #750 (consolidating the built-ins)
   follows #732.
2. **The process record.** Threads sharing an address space are #742
   stages 2-3, after the preemption flip.
3. **Preemption (#638), nine stages** (worker proposal 2026-10-24, with
   #992 and #993 inserted; the route review is #638's comment of
   2026-10-24): (1) the raw `cpu_id()` inventory check, done; (2)
   `preempt_off` lowers to a per-CPU preempt count reached through
   TPIDR_EL1, with a debug-build assert, constant still 0, measured on
   RPi5 (decided 2026-10-25, DECISIONS.md; done 2026-10-25 except the RPi5
   measurement: a .S helper reads TPIDR_EL1, the asserts run in every
   image; the route review's other
   recommendations are taken with it: an immediate switch at IRQ return
   only, El0-only deliveries, bounded yield-and-retry slot pools,
   `!{interrupt}` deriving `PreemptOff` with `nmi` and `debug_stopped`
   apart); (3) an EL1
   frame in `saved_sp` (#992: `FrameRef` carries its exception level,
   deliveries take El0 only, `StackOwnership.tla` gains `PreemptEL1`); (4)
   a non-stopping CPU-authority mint and the `!{interrupt}`-derives-
   `PreemptOff` rule (#641 item 1); (5) site migration (process_image's
   target root, the log's partial line per #613 option b,
   `syscall_ext2_reader`, exception_evidence); (6) the slot pools'
   capacity premise (#993); (7) the lock-holder group with the `PreemptOff`
   token and #789; (8) the EL1 switch at IRQ return when the count is zero,
   shown once in a deterministic lane; (9) the flip, models passing without
   their no-preemption guards, the three boot-phase stand-ins rewritten,
   never while #584's soak runs. The flip's precondition is a number:
   #1012's ratchet reports no production global outside the typed set.
4. **Globals and hardware isolation (memory safety).** #1012: every
   `let mut` global is `AtomicWord`, lock-protected, `per_cpu`, region
   backing, `Place`, a `dma_fixed` or protocol owner, or boot-once (#1013),
   or allow-listed with its reader named; 406 of 500 production globals
   are outside that set today; the ratchet (slice 1) lands first, the
   migration follows the order the flip breaks things. #1032: WXN and PXN
   first (configuration; a B-sized slice), then PAN with a typed
   `user_access` window, then the IOMMU (QEMU `smmuv3`, then BCM2712's
   PCIe IOMMU for RP1), which turns the device-semantics claims of
   `kernel/DEVICE_SEMANTICS_FILES` from trusted into enforced. Each step
   has a negative control and an RPi5 measurement.

### Territory B: supporting the pillars, by priority

**Assigned queue (maintainer, 2026-10-23, re-cut 2026-10-25).**
Low-dependency issues A does not hold, in this order; compiler work in
this list is authorized; an item that reaches a decision is parked and the
next one taken. The done record of the previous queue is in HISTORY.md
(2026-10-25).

0. **Stop the silent growth (now).** The remaining `.tkb`-reading checks
   move to #987's call-graph table one by one (#567); #850's stop-gap is
   done (EFFECTS.md lists the checker-only effect words from the table
   `dynamic_rule` reads; no new such word, DECISIONS.md; the migration
   stays in band 2); #1003 (`WORDS.md`) and #1027 step 1 (`CLI.md`, the dead
   flags out, the `--internal-*` namespace) and #1004 (dead builtins,
   `stable_replace` to a removed-words table, the generated-only names
   hidden) done 2026-10-25; #994 (address-taking DMA cache builtins counted as raw sites;
   done 2026-10-25) and #1028 (other address-taking intrinsics); #1031 slice 1 (classify the 119
   `kernel_invariant_stop` sites and ratchet them; done 2026-10-25,
   `scripts/invariant_stop_sites.tsv`: 120 sites, frame 31, unmodelled 18,
   ladder 71); #1018 (the frame API rule as a list-file check; done
   2026-10-25, 8 ratchet entries); #986 slice 1 (the trust ledger as a dated
   checkpoint series, each row attributed to the rule that retired it; done
   2026-10-25, `docs/TRUST_LEDGER.json`, #986 stays open).
1. **Verification (#954; B owns the refinement code).** The rest of #954
   stage 2 (docs/VERIFICATION_DESIGN.md, "Stage 2 scope"), then #955's
   evidence log; #986 slice 2 (region arithmetic and overlay length as
   z3-checked obligations) once the maintainer authorizes it (Awaiting).
2. **Equivalence oracles.** ext2: tier B (#1034, landed 2026-10-25:
   `kernel/tests/ext2_eq/ops.eq` replayed on host Linux and libext2fs,
   compared logically in kernelcheck-qemu-main), #1033 (tier A, fsck after
   every writing lane, counters against the kernel's own; done 2026-10-25,
   `scripts/ext2_postcheck.py`), #1035 (tier C, done 2026-10-26: the ext2
   driver as a host process over a RAM disk, `scripts/ext2_host.py` in
   linuxcheck and `make ext2-host-long`; what it found open: #1086 whole-file
   copy per write, #1087 holes allocated, #1089 torn writes). The ext2
   fixes #1019 and #968 flipped their ops.eq rows to `match` when they
   landed (2026-10-25); #1021's doubly-indirect O_TRUNC row matches on a
   sparse fixture the comparing runner plants (2026-10-25; #1022's truncate row and #1023's `peer` row, a held fd
   across O_TRUNC, match since 2026-10-25), and #1067
   (printf) and #1070 (sendfile to a file) are writers the rows avoid.
   Signals: #999 (host-Linux conformance suite), #1000 (one delivery
   chokepoint and `SignalDelivery.tla`, designed with #992), #948 (the
   terminal-read EINTR fixture), #432 (timed blocking).
3. **Compiler consolidation.** #1005 (one instruction table), #1027 steps
   2-3 (`--facts DIR` for the `--emit-*` family; strict defaults with
   opt-outs), #750 after #732.
4. **Fixed DMA lifecycle, finishing the drivers.** #720's remaining xHCI
   item (the DCBAA stays legacy until sub-region authority; #783, the
   batched TD write path), #740's step 3 (a socket's receive queue keeping
   the packet, after the profiler's copy-cost measurement), #779 (line
   ownership of split or converted regions), #790 (size review).
5. **Independent pillar issues, moved from A (2026-10-16).** #789 (lock
   order as ranked capability tokens, absorbing `acquires_lock_<rank>_<name>`,
   after the syntax review); with it, #850's migration of the IRQ words to
   an `IrqState` token in the `preempt_off` shape, which retires the #809
   flow pass; the authority-boundary words follow.
6. **Other compiler and language work, respecting design gates.** #709
   and #710 (generation exhaustion), #203 stage 3 (cross-call contracts,
   byte ranges), #732's later slices, #793 (proofs on type variables),
   #762 (no vector stores in MMU-off code), #774 (every IRQ dispatch arm
   acknowledges its source), #752 (typestate in more of the kernel), #755
   (an immutable integer binding keeps one static), #751 (per-element
   witnesses, deferred until a consumer needs them), #926 (GICv3 for QEMU
   virt), #769 (`--uses-of NAME`; shares #987's module), #747 (host GDB
   test). Audit follow-ups filed 2026-10-23 to 2026-10-25: #901, #902,
   #898, #899, #904, #905, #903, #1024, #1025, #1029, #1030.
7. **Time measurement, then the optimizations waiting on it** (maintainer,
   2026-10-08: space and time are both kept): #502; then #520 (TCP
   throughput, with #972: submit-only NIC TX), #741 (RPi5 HTTP SYN
   retransmission tails), then #680, #682 (region_pool lock-free
   validation, false sharing, pinless single-user pools), #711, #718, #386.
8. **Research applied to a real example, moved from A** (evaluated
   2026-09-29; reasoning on #13): indexed views generated from a TLA+
   model's actions (prototyped on #613; one `protocol` declaration
   generates both TLA+ and permission types since 2026-10-11); Iris
   vocabulary for lock and pool invariants (#132).
9. **Evaluations awaiting a maintainer decision:** #687 (typed terminal
   mode leases), #648.
10. **Compiler and language research, independent of the ownership
   checker:** #201, #282, #129, #417, #155, #28, #8, #200.
11. **Toolchain and portability:** #123, #124, #122, #95, #51, #50, #85.

Items are ordered within each band as well as between bands.

### Two milestones (maintainer, 2026-10-28)

Two moments on this roadmap are the maintainer's to act on, not a
territory's, and each is a GitHub milestone so that the moment is announced
by the repository (`.github/workflows/milestone.yml` opens one issue,
assigned to the maintainer, when a milestone's last issue closes) rather
than noticed by whoever happens to be reading.

- **kernel landed** (milestone 1): #638 and its stages #992 and #993 (the
  preemption flip), on #1159 (the globals ratchet at zero, the flip's
  precondition); #1157 (the trusted-base ledger as a dated series, #986
  slice 1); #1160 (verification stage 2 complete, #954); #1158 (the
  distribution-benchmark load recorded beside Linux, #742 stage 1). When
  all are closed: the maintainer posts the kernel to Hacker News and starts
  the first paper.
- **language settled** (milestone 2): #1010 (the lossless printer and
  `takibi fmt`), then #1009 (the syntax edition). When both are closed: the
  maintainer starts looking for co-authors and co-developers in earnest.

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
- **#986 slice 2**: z3 re-checks region arithmetic and overlay length,
  as B compiler work.
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
#1013 (`BootOnce(T)`, with #1012's migration); #1014 (run-lock contention,
measured on #742 stage 1's load before any per-CPU run queue).

The deferred items stay listed so a changed premise can bring them back
into the queue.
