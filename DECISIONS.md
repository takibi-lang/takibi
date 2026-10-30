# Maintainer decisions

One line per decision the maintainer made, so any agent or session can find
the current ruling before it proposes or builds something. The reasoning
lives on the linked issue; this file only says what was decided, when, and
whether it still holds.

Rules for keeping it current:

- The coordinator (or whoever records a maintainer decision on an issue)
  adds the same decision here in the same change of work.
- A decision that changes is not deleted. Mark the old line `[superseded by
  YYYY-MM-DD]` and add the new line; the history is part of the record.
- Read this file before proposing an option or recording a decision; an
  option that contradicts an active line needs the maintainer.
- Keep each entry to one or two lines and one issue link. English ASCII.
- The maintainer's latest statement wins. When a new statement contradicts
  an active line, the coordinator points this out to the maintainer, then
  supersedes the old line.

Format: `- YYYY-MM-DD <decision>. [active|superseded by YYYY-MM-DD] #issue`

## How the maintainer decides (worked examples)

These are not a complete statement of principles; they are cases where the
maintainer's judgment changed the course, kept so the pattern can be seen.
They are why the matching calls are escalated (see "Escalate to the
maintainer when" below); routine calls follow the coordinator defaults.

- 2026-10-14 Pursue zero-copy and compile-time safety together, at the edge
  where both still hold; copying everything to stay safe weakens the types,
  and choosing an mbuf layout now is premature. [active] #740
- 2026-10-13 No unexplained size growth: every image growth is explained by
  symbol and section before it lands. [active] #720 #786 #790
- 2026-10-13 Every core's role should be as equal as possible; record a
  reason wherever one core stays special. [active] #775
- 2026-10-14 Benchmarks use widely available Linux tools before anything
  custom is written. [active] #520
- 2026-10-12 Surface syntax and grammar are reviewed together later; take
  reversible spellings now and come back if one is costly. [active] #637 #777 #789
- 2026-10-14 Grow existing mechanisms step by step toward the intended
  syntax rather than replacing them all at once. [active] #789
- 2026-10-12 Closed issues stay forever as project records; only mentions
  in ROADMAP.md are dropped. [active] #720

## Coordinator defaults (decide without asking)

The coordinator applies these itself, records each call as one line on the
issue, and reports it to the maintainer afterwards in one line. Since
2026-10-18 the coordinator also lands without asking when no escalation
condition below applies, and reports the land afterwards.

- 2026-10-12 Remaining items an audit names become filed issues by default;
  work too big for the current slice is filed, not stretched. [active] #719 #739 #772 #791
- 2026-10-16 Recurrence prevention: every defect met will likely recur, so
  prevent its class by the strongest feasible rung: (1) compile-time static
  check, (2) model check, (3) dynamic lint-like build check, (4) unit or
  integration test. Not absolute, but the audit names the rung taken and why
  higher rungs were not; this loop is how Takibi reaches stronger
  compile-time checking in a practical Unix-like kernel. [active] #753
- 2026-10-25 Rung 5 of the ladder, a run-time check, is admitted for its
  value over a stop, not as a way to shrink the trusted base: a check that
  stops the kernel only pays when it guards a frame site (#1017) or a
  premise no model covers, and every firing is a defect to work back up the
  ladder (a followup, never a tolerated stop). The 119
  `kernel_invariant_stop` sites are classified and ratcheted (#1031);
  generated traps stay forbidden (--forbid-trap). Hardware isolation (WXN,
  PXN, PAN, the IOMMU; #1032) is adopted freely, because it narrows what a
  defect can reach rather than detecting one, and it is not a ratchet
  item. [active] #1031 #1032
- 2026-10-16 Prevention an audit finds at the rung the ladder picks (plus a
  failure-only log) is added before land, not filed; cheapness alone does
  not pick the rung. [active] #753 #772 #789
- 2026-10-16 Urgent issues found mid-work: the coordinator rewrites
  ROADMAP.md priorities and reschedules. [active] #753
- 2026-10-16 Debugging aids log only on failure; a passing run leaves
  nothing behind. [active] #772
- 2026-10-16 Do not add artifacts that go stale cheaply (for example --help
  on a fast-changing script). [active] #740
- 2026-10-13 Intermittent failures: try to reproduce first; if costly, stop
  and file with a KNOWN_INTERMITTENTS row (open issue) rather than chase. [active] #665 #780 #795
- 2026-10-16 Concurrency or resource claims: prefer a compile-time check,
  else a TLA+ model with a failing control, at least a dynamic test, before land. [active] #740
- 2026-10-16 Models stay at a tractable size; do not push past state
  explosion; state the bound in the audit. [active] #740
- 2026-10-16 Small, closely related follow-ups found mid-slice (including a
  prerequisite fix) are folded into the current slice. [active] #740
- 2026-10-16 Speculative capacity or scope growth (bigger pools, later
  zero-copy steps, size reduction) waits for measurement when an issue holds
  the plan; commit only to near steps. Growth must still be explained. [active] #497 #740
- 2026-10-16 Related diagnostics fold into the nearest open issue rather
  than a new one. [active] #771 #797
- 2026-10-13 Non-fatal, low-impact defects are filed but kept off ROADMAP.md. [active] #768
- 2026-10-13 A trust-relevant change is at minimum recorded in
  TRUSTED_BASE.md before land, so it can be reviewed later. [active] #720
- 2026-10-15 Evidence for a question deferred to a later review is recorded
  on its issue. [active] #775
- 2026-10-16 Land order, clean audits and choices the worker recommends that
  match an active line are not separate questions. [active] #753
- 2026-10-18 The coordinator assigns the next territory issue itself when it
  needs no design decision, and lands work that meets no escalation condition;
  both are reported afterwards. [active] #753
- 2026-10-18 Rule and instruction changes (DECISIONS.md, .agents/, .claude/)
  also land on the coordinator's judgement when nothing escalates. [active] #753
- 2026-10-16 Low-abstraction details (a specific constant such as a reserve
  count) are not recorded here; record the principle, not the value. [active] #753

### Escalate to the maintainer when

- the call contradicts an active line in this file;
- it is irreversible or outward-facing (publishing, deleting records, ABI);
- it grows image size without an explanation;
- it changes surface syntax or grammar;
- it brings a large language design change beyond surface syntax: new or
  changed semantics, type-system rules, the ownership/linearity model, the
  capability or protocol model, or which programs are accepted;
- it widens scope beyond the issue;
- it trades zero-copy against compile-time safety;
- it is trust-relevant beyond a TRUSTED_BASE.md note, or the coordinator has
  its own concern about it;
- or no default covers it.

## Language and types

- 2026-10-11 One `protocol` declaration generates both the TLA+ model and the
  sealed owner types. [active] #720
- 2026-10-12 `requires` stays inside protocol bodies; revisit if function
  preconditions are adopted. [active] #720
- 2026-10-12 Initialization tracking uses init/uninit per field, aligned
  with Place Empty/Full; reads of uninit fields are rejected everywhere;
  padded structs allowed with padding tracked. [active] #203
- 2026-10-12 Value-dependent initialization is solved by init state
  conditional on refinement facts, not by variants or path analysis. [active] #203
- 2026-10-12 Checked integer-to-enum is `match n as E { ... miss => }` with
  every variant required. [active] #608
- 2026-10-13 Region backing arrays are declared `region let mut`; the name has
  no other use. [active] #637
- 2026-10-13 Header overlays: a proven-length byte slice cast `as &T` to a
  packed every-bit-valid struct gives a borrow-tied reference. [active] #637
- 2026-10-16 `unsafe` marks only writes that can break a type's claim;
  read-only byte views (`[]const u8`) of any value are safe, and writes
  with no safe meaning (zero_fill of a zero-invalid type) are errors, not
  unsafe. [active] #794
- 2026-10-16 Preemption-disabled regions are checked statically: a lexical
  `preempt_off` block first, sugar over a linear PreemptOff token that is the
  end state; may_block is forbidden inside, and CPU authority is derived
  from the region. [active] #638
- 2026-10-17 ext2 scratch held across blocking block I/O is a pool of
  KERNEL_MAX_CORES slots handed out by a linear slot token (option C), not
  kernel-stack or per-task storage; readers stay lock-free (#533). [active] #638
- 2026-10-18 Atomic compare-and-swap returns the observed value on failure
  (Swapped | Observed(v)), so no second load stands in for it. [active] #613
- 2026-10-18 A boolean compare-exchange followed by a load of the same word
  is a compile error; the boolean forms stay until this class recurs, then
  every caller moves to the observed-value form, whose failure is acquire. [active] #613
- 2026-10-14 Lock order moves toward ranked capability tokens (Fuchsia
  lock_order style), absorbing acquires_lock_<rank>_<name>, after the syntax
  review. [active] #789

- 2026-10-23 Refinement soundness: every propagated range is built through a
  base-checked constructor; unsigned max(a - b, 0) and casts that cannot
  hold the range are rejected (programs rejected only where unsound). [active] #935
- 2026-10-23 A product of two non-negative refined factors gets an interval
  when its maximum fits the base. [active] #807
- 2026-10-23 Comparing two arrays with == is rejected; content comparison is
  a separate API, never ==. [active] #941
- 2026-10-23 `for i in 0..<N { P[i] = e }` (no early exit, store at top
  level) initializes P; a general loop-invariant form is wanted later
  rather than more special shapes. [active] #888

- 2026-10-23 Verification direction: explicit contracts at function
  boundaries, decidable local inference, SMT first as a checker; staged with
  the multicore work, B owns the refinement code. New range rules go through
  refined_or_base and add no special shapes. [active] #954 #952
- 2026-10-23 Proof assistants (Lean/Rocq) start only once #955's evidence
  log justifies it; audits record which defects SMT or a proof assistant
  would have prevented. [active] #955 #952

- 2026-10-24 One meaning per type: `borrow T` is always fully initialized;
  partial initialization is written only as `borrow uninit` with
  requires/ensures. [active] #975 #954
- 2026-10-24 #954's skeleton is confirmed: requires/ensures init(...) with
  linear bounds, exhaustive match conditions, slot-owned scratch globals
  only, an interval-union init predicate, z3 re-check, 5 s cold budget.
  [active] #954

- 2026-10-24 No new checker-only word in the `!{...}` effect row (the
  `dynamic_rule` family: lock ranks, IRQ guards, witnesses, invalidation,
  loan transfer). A new need is a token type in the #789 / #638 shape, or
  waits for #850's review; the existing words migrate to types in #789's
  and #638's order. [active] #850 #789
- 2026-10-24 EFFECTS.md lists the checker-only words too (name pattern,
  what it marks, the analysis that reads it, the replacing token type), so
  a new one changes a tracked contract document. [active] #850

## Trust and safety

- 2026-10-13 Only files in kernel/DEVICE_SEMANTICS_FILES may declare device
  protocols. [active] #720
- 2026-10-13 usb_xhci_bus.tkb (one function; two since #994) replaces
  usb_xhci.tkb on the mint list. [active] #637 #720
- 2026-10-13 Generated `<protocol ...>` files are exempt from raw-authority
  confinement; recorded in TRUSTED_BASE.md. [active] #720
- 2026-10-13 Process stack runs keep their PageRunOwner in the process
  record; linker-bounded stacks wait for a section-axiom decision. [active] #672 #777
- 2026-10-12 Page uniqueness by type with put-by-address (B); holder-tied
  identities (C) are #750's central item. [active] #746 #750

## Memory and DMA

- 2026-10-13 Device protocols: tx/rx/txrx regions, `addressed` writable
  states, E1 snapshots for device-written rings. [active] #720 #740
- 2026-10-13 xHCI DCBAA stays legacy until sub-region authority. [active] #720
- 2026-10-14 Packet buffers are pool elements owned linearly: Free ->
  RxPosted -> Filled -> TxPosted -> Free, Unconfirmed terminal. [active] #740
- 2026-10-14 Sharing for TCP retransmit: keep the owner in TxPosted, read
  through access read; S1 copy is an escape hatch; S2 refcounted read-only
  owners after #750, wanted before multicore network benchmarks. [active] #740 #750
- 2026-10-14 virtio moves to the modern virtio-mmio transport (U2-full)
  after the pool migration. [active] #740

## Multicore

- 2026-10-11 QEMU lanes run on 4 vCPUs; uart-wake pinned to 2 until #757. [superseded by 2026-10-20] #719 #757
- 2026-10-20 uart-wake runs on 4 vCPUs; every scheduler-locked step parks CPU2.. first. [active] #757
- 2026-10-13 #9 closed; affinity follow-ups split into #775 and #776. [active] #9

- 2026-10-18 The kernel log ring is option B: fixed slots with a per-slot
  seq|state word, records may span several slots (no fixed line limit);
  hand-written tokens first, replaced by protocol generation after #720. [active] #613
- 2026-10-18 Memory-ordering checks are herd7 model checks tied to the
  emitted instructions; no litmus7 hardware runs. herdtools7 comes from opam,
  pinned in the devcontainer and CI. [active] #645
- 2026-10-23 #830 lands with the hung-core DDB check recorded as expected-fail
  (it fails the lane once the world stop reaches a core with IRQs masked);
  the pseudo-NMI/FIQ stop gets its own issue. [active] #830
- 2026-10-23 The masked-core stop is a GICv2 priority-mask pseudo-NMI: GICC_PMR
  is the IRQ mask, the stop SGI at 0x80 above all else at 0xA0 (PMR 0xA0
  masked, 0xF0 unmasked); handlers run with PMR masked and DAIF.I clear so
  the stop nests; a new `nmi` effect excludes locks, blocking, allocation
  and logs; cost measured on RPi5 before choosing PMR everywhere or a
  hybrid; GICv3 (#926) slots in later. [active] #920

- 2026-10-24 The IRQ mask is the GIC priority mask everywhere (about
  +20 ns per masking lock pair on RPi5, no measurable suite-time change);
  cost reduction is #966. [active] #920 #966
- 2026-10-24 TCP retransmits for unread connections run in the post-IRQ
  EL0-return hook (IRQs unmasked for the pass) and the idle loop, which may
  try-take the network capability; never on syscall return (Linux/BSD
  precedent). Submit-only NIC TX (#972) waits with TCP throughput work.
  [active] #846 #972

- 2026-10-24 Priorities: DDB and the stop/crash paths aim at "consistent and
  works reasonably" (#933 kept the quiescent-only reboot; #980, #957-#959
  are low priority); spare capacity goes to memory safety, multicore and
  the staged refinement/z3/proof-assistant review (#954, #955). [active] #933 #980

## Size and performance

- 2026-10-13 Dead code is removed by the linker (--gc-sections), not by more
  whole-program optimization in the compiler; generated code is on demand,
  internal, inline when small, and linker-removable. [active] #786
- 2026-10-13 KEEP() for sections tied to assembly or placement;
  KERNEL_DEBUGGER_ENTRIES (--undefined) for functions called by name from
  outside the image. [active] #786
- 2026-10-13 An in-kernel sampling profiler, not a perf port. [active] #497
- 2026-10-17 Be conservative with kernel stack use: .data/.bss can be
  estimated after compile, but stack use is dynamic and harder to bound, so
  prefer static storage over large stack buffers even at some .bss cost. [active] #638

## Interfaces

- 2026-10-13 Takibi-only interfaces live under /proc/takibi/. [active] #497

- 2026-10-23 The lane budget counts elapsed minus vCPU lease wait; lease
  grants are ordered longest lane first. [active] #927
- 2026-10-23 page_alloc_contiguous's linear search is parked until a churn or
  long TCP workload shows max_ticks growing. [active] #812
- 2026-10-23 A temporary +1.8 KiB text from #888's DDB byte array is
  accepted; #943 (byte-array struct copies) is raised to recover it. [active] #888 #943

## Process

- 2026-10-12 Audits include a per-defect table (root cause, debugging aid,
  cheap prevention, model check, compile-time check). [active] #753
- 2026-10-13 Workers run `make langcheck linuxcheck test` in full and pass
  space_checkpoint before reporting done. [active] #753
- 2026-10-16 Territory A owns the two pillars, multicore support and memory
  safety, and pursues only them; Territory B takes issues slightly off the
  pillars, supporting A. [superseded by 2026-10-16] #753
- 2026-10-16 Territory A takes pillar work that comes as chains of dependent
  issues (like the #637 family); pillar issues solvable independently go to
  B, so both lanes run; B also takes issues slightly off the pillars. [active] #753
- 2026-10-12 Landing .agents/ and .claude/ changes takes the light route. [active] #753
- 2026-10-16 Compiler and tool input either passes or is an error; anything
  suspicious (a stale list entry, a flag that would be ignored) is never a
  warning, because warnings go unread. [active] #796
- 2026-10-19 Kernel work that needs an instruction the compiler has no
  intrinsic for uses a small .S helper with no logic (precedent pmu.S), not a
  new compiler intrinsic. [active] #759 #811
- 2026-10-24 Folding the `.tkb`-reading build checks into the compiler is
  more urgent than it was: #567's Stage 1 (--emit-call-graph, #987) and the
  first two retirements (#988, #989) go to the head of Territory B's queue,
  ahead of #954 stage 2. [active] #567 #987
- 2026-10-25 The pillars need their support lanes: multicore and memory
  safety stay the near-term goal, but they do not grow soundly alone (the
  z3 second judge found existing defects within days; the build checks
  outgrew the compiler they guard; equivalence oracles turn review chains
  into tests). Territory B's queue is ordered by what serves the pillars,
  and A adopts each support result at its next work boundary. [active]
- 2026-10-25 #742 stage 1 (multicore load with programs Linux distributions
  ship, as a make target outside every aggregate) runs now, before #638's
  stage 2 and #966, which need its baseline; #1014 is measured on that load
  and nowhere else; stages 2 and 3 wait for the #638 flip. [active] #742
- 2026-10-25 The consolidation umbrellas filed by the 2026-10-24/25 review
  (#986, #998, #1002, #1008, #1012, #1027) are decided direction and stay
  off the queues except their stop-gaps in Territory B's band 0; #1009, the
  syntax edition, is done last of them, after #1010 (a lossless printer and
  `takibi fmt`), its only prerequisite. [active] #1009 #1010
- 2026-10-25 The syntax review (#1006) is held until before #789's token
  design starts, and before the next split of `process.tkb` or
  `syscall.tkb` that #1008's `module` line would otherwise have to
  retract. [active] #1006
- 2026-10-25 The evidence a later write-up of Takibi's additions over Rust
  would need is collected as a by-product of ordinary work, never as a
  project: every defect followup answers whether safe Rust, klint, Kani,
  Verus or Flux would have caught the defect (bounded and deductive
  verifiers apart) (#1043, question 9 of the
  defect-followup skill); the trust ledger is a dated series with each
  row attributed to the rule that retired it (#986 slice 1); #742 stage 1
  records each program beside the same program under Linux on the same
  machine. No comparison rewrite is scheduled. [active] #1043 #986 #742
- 2026-10-25 The generated-only `__protocol_dma_*` builtins are hidden from
  user code (a call is an undefined function, `builtin::` does not name
  them, the names stay reserved), the five zero-use builtins are deleted,
  and `stable_replace` moves to a removed-words table. [active] #1004
- 2026-10-25 #1027 step 1's compiler-development flags are spelled
  `--internal-*` (`--internal-range-obligation-fault-control`,
  `--internal-trace-init-flow`). [active] #1027
- 2026-10-25 The solver boundary is fixed and guarded (#1055): obligations
  stay in decidable quantifier-free fragments (QF_BV, QF_LIA); `unknown`
  and timeout fail the build; z3 re-checks and never decides; a goal
  outside the fragment is not met by widening the logic but goes to a
  generated proof-assistant statement or stays a runtime check (#1031);
  an inference engine (abstract interpretation, Spacer) only proposes an
  invariant, and the proposal is re-checked as quantifier-free
  obligations; the SMT-LIB files stay portable so a second solver can run
  the corpus. [active] #1055 #952 #954
- 2026-10-25 Proof assistants, refining 2026-10-23: #955's six
  compiler-level entries justify the meta-level plumbing now (#1054): the
  pure rule functions in one first-order module, Lean 4 statements
  generated by the compiler and digest-checked, proofs written against
  them and closed with bv_decide/omega in a lane with Lean pinned like z3,
  Lean outside the trusted base. No in-house prover. Object-level proofs
  (.tkb programs) still wait for a defect in #955 that needs induction or
  a quantifier. [active] #1054 #955
- 2026-10-25 #742 stage 1: one rootfs image for QEMU and the RPi5, sized
  from its content (6 MiB, KERNEL_EXT2_IMAGE_LEN) so the board runs the
  same load; no second RPi5 build variant. The load programs are built
  from SHA-256-pinned sources into ~/.takibi-sessions/cache, so an image
  build on a cold cache needs the network; that is accepted. #638 stage 2
  landed before #742's baseline, which is taken at the commit before it
  (9860071e). ext2 fixes may land ahead of #1034, whose rows flip after.
  [active] #742 #638 #1034
- 2026-10-19 A rebase conflict confined to docs/SPACE_CHECKPOINT.json is
  resolved by code (scripts/checkpoint_rebase.py, used by land.sh and the
  coordinator): main's side, then the branch's own review, current for its
  pre-rebase head, re-recorded for the rebased head and fully checked. Any
  other conflict still stops the land. [active] #832
- 2026-10-14 sched_yield is implemented as a plain reschedule; harnesses fail
  fast on an unimplemented-syscall line. [active] #665
- 2026-10-15 RX capability split is option A (detached kept owner, holder refills,
  spare reserve with copy fallback; ring never fully drained, TLA+-checked);
  socket receive zero-copy waits for #497 measurement. [active] #740
- 2026-10-25 #981's remaining scratch: process_image_contexts becomes an
  explicit parameter (global state kept minimal), and
  kernel_process_claimed_pid takes option 1 so struct per_cpu does not
  grow. [active] #981
- 2026-10-25 #638 stage 2: preempt_off is a per-CPU count reached through
  TPIDR_EL1, with a debug-build runtime assert; the follow-up questions take
  the recommended answers. [active] #638
- 2026-10-25 #638: TPIDR_EL1 is read through a one-move .S helper
  (`kernel_cpu_offset`, its caller fixed by a call-graph build check), under
  the 2026-10-19 rule; no `mrs_tpidr_el1` builtin is added. The runtime
  preempt-count checks stay on in every image. [active] #638
- 2026-10-25 #987: check_model_function_map.py runs as a buildcheck over both
  kernels' call-graph tables (option A). [active] #987
- 2026-10-25 #994: DMA and cache-maintenance builtins move toward #637's
  direction (trust confined to named mint sites), after their relation to the
  DMA ownership model (#740 and related) is checked. [active] #994 #637
- 2026-10-25 #994: only raw-pointer cache maintenance (dma_prepare_tx/_rx,
  dma_finish_rx) is a counted raw site; ordering builtins and the dma_fixed
  finishes (check_dma_mint_files.py) stay as they are. usb_xhci_bus.tkb now
  holds two functions, the span export and the DCBAA clean. [active] #994 #637 #720
- 2026-10-29 #1028: the one-argument translation intrinsics (tlbi_vae1is,
  tlbi_aside1is, msr_ttbr0/tcr/mair/sctlr_el1) are counted raw sites, like
  #994's cache maintenance; zero-argument TLBI and msr_cntp_* are not.
  Chosen by the worker in the authorized B queue; open to the TCB review.
  [active] #1028 #994 #637
- 2026-10-25 #954 stage 2 is scoped by a stage-2 review first; its first item
  is #798 rebuilt inside the confirmed skeleton as linear facts the checker
  decides and z3 re-checks. [active] #954 #798
- 2026-10-25 #954 stage 2 scope: index bounds are in; items in order are
  #798 (order graph first, `entails` fallback), index bounds from versioned
  locals (committed; #798's site count sets when), then retiring the order
  graph. Index obligations share the 5 s z3 budget with their own report
  line. #799 is out and stays off ROADMAP until a site needs it.
  [active] #954 #798
- 2026-10-25 #921 closes on the measured front-end speedups; the shared
  multi-variant run is not built. #922 (domain-parallel codegen, at most ~25%
  on a solo build and nothing on a land) leaves ROADMAP and stays open until
  compile time is felt again. [active] #921 #922
- 2026-10-25 Loop invariants are not introduced for now; #954 stage 2 item 2
  closes without new code. When they come, the compiler infers them by
  default (abstract interpretation, z3 Spacer where its cost fits the 5 s
  budget), and the programmer writes an invariant or a proof only where
  inference fails. Evidence for #955. [active] #954 #955
- 2026-10-25 #1079 option (c): an execve reserves the new image's pages
  (extent, heap, stack, tables) before the old image is torn down, so memory
  exhaustion is refused with ENOMEM before the point of no return; an image
  read error after that point ends the calling process with a fatal signal,
  as Linux does, never the kernel. Exhaustion found by the load programs is
  welcome test evidence. [active] #1079 #1084
- 2026-10-25 #1041 option (A): DISTRO_ELF_SPAN_MAX is 256 MiB. With #1079
  in place a large image fails before commit or ends only its own process,
  so the bound is a sanity limit, not the OOM defence. [active] #1041 #1079
- 2026-10-25 #1035: hostile ext2 images are generated from seeds; the
  e2fsprogs f_* images (GPL data) are not downloaded. The compiler lowers
  dsb_ish/dsb_ishst to mfence on x86-64 for the host build, as the existing
  x86-64 atomics do. [active] #1035
- 2026-10-25 #1095: DDB's precise "no RX pending" on GEM uses a logic-free
  .S helper (dc civac; dsb) called through extern, restricted to DDB by a
  build check like the MPIDR read; no compiler builtin. Ask again if the
  work grows large. [active] #1095
- 2026-10-25 #1096 new effect [superseded 2026-10-26 by the next line].
- 2026-10-26 #1096 adds no effect: #1080 removed exec_args_store, its only
  adopter. #1096 is rescoped to the generator emitting TaskMutex for
  dma_owner slots (with a negative compiler test) and to the spare stack
  (moved out from under the run lock, or recorded as staying masked). A spin
  effect waits for the effect review (#789, #1135). [active] #1096 #789
- 2026-10-25 #1021/#1100 option (b): /pad stays #742's MiB rounding; the
  comparing lane's runner plants a dedicated doubly-indirect fixture on its
  own disk copy with debugfs. [active] #1021 #1100
- 2026-10-25 #1072 option 1 [superseded 2026-10-26 by the next line].
- 2026-10-26 #1072 adds no declaration syntax: #789's ranked capability
  tokens will place masking and unmasked locks relative to a named IRQ level
  and derive may_block from it. #1072 only names the rank-40 band as one
  constant with matching docs and messages; newcomer-readable levels are
  #1135. [active] #1072 #789 #1135
- 2026-10-26 QEMU lanes from a worktree do not run while a land's allcheck
  runs: host CPU contention inflates busy lane-seconds and trips silence
  watchdogs. Until #1145 makes the lanes wait on the land's lease, the
  coordinator holds workers' QEMU runs during a land. [active] #1145
- 2026-10-25 Assembly is a leaf (#1133): called from Takibi it returns to its
  caller and never relays between Takibi functions; asm-started paths save
  state and enter one Takibi function. #1080 option (A) is the first
  instance. A typed boundary declaration with a disassembly-checked register
  pass-through comes only where a value cannot avoid crossing assembly.
  Untrusted FFI re-validates what it returns (#1134). A pseudo-.tkb model of
  assembly is YAGNI: checking it would shake the trusted base.
  [active] #1080 #1133 #1134
- 2026-10-26 Licensing: Takibi stays GPLv3, with an additional permission
  for the compiler's output and the listed Linux runtime support files
  (COMPILER_OUTPUT_EXCEPTION.md) so compiled programs are not GPLv3 works
  by compilation alone; the kernel and the compiler keep the GPLv3.
  Commercial licenses are offered on request. External contributions come
  under CLA.md (a broad license grant, copyright kept by the
  contributor), in place before the first external contribution. Sponsors
  go to the parent organization, Metasepi. [active]
- 2026-10-28 #1151 option (A): mmap gets its own region apart from the brk
  heap, MMAP_REGION_PAGES = 4096 (16 MiB), mapped on first touch, with its
  own per-process bitmap held by reference; brk keeps its 128 pages. The
  mmap region is outside #1079's exec-time page reservation (lazy, as on
  Linux). Cheap multicore and memory safety come first; the memory map is
  cheap to revisit later. [active] #1151 #1079
- 2026-10-28 #637 stage 3 order: virtio_net keeps its one DDB site in
  RAW_MINT_FILES (option d); then #1161 (virtio_blk typed queue), #1162 (one
  mint for device-visible addresses), #1163 (rp1_gem's writes), the IOMMU
  (#1032), and last #1164, the stopped-machine observation for DDB's ring
  reads (DDB is irregular; the IOMMU matters more). The file count is a
  proxy: the trusted core should end as protocol codegen, one address mint
  and MMU/IOMMU configuration. [active] #637 #1161 #1162 #1163 #1032 #1164
- 2026-10-30 #992: FrameRef carries its exception level as an enum-valued
  static index, `affine struct FrameRef[process: usize, level: ExceptionLevel]`
  with `enum ExceptionLevel { El0; El1; }`, the mechanism
  ScheduledProcessState already uses; a provisional spelling #1006 may rename
  mechanically. The Pending/Delivered index waits for #1000. [active] #992
  #1006 #1000
- 2026-10-30 #1032: every QEMU lane moves to -cpu cortex-a76, the RPi5's
  core, in its own slice before PAN. PAN uses a typed user_access window
  (option A): the window type is portable, and only its open/close assembly
  leaves are per-architecture (ARM PAN, x86-64 SMAP STAC/CLAC, RISC-V
  sstatus.SUM), keeping a later RISC-V or AMD64 port in view. Alongside PAN,
  a compile-time check that a kernel raw dereference cannot target a user
  address (refinements) is wanted; its feasibility is assessed first.
  [active] #1032

## 2026-10-29 #1032 keep the A53 build; one-interval user-address refinement now (#1184 later)
- Keep compiling for cortex-a53 even though every QEMU lane runs on cortex-a76: running without the newer instructions is a requirement.
- The compile-time user-address check uses the existing single-interval refinement, which works because the kernel range fits in one interval. Refinements over several disjoint intervals are tracked in umbrella #1184, which stays off ROADMAP.md (YAGNI) until a real need appears; its representation (for example a union of intervals) is decided when it is started.

## 2026-10-29 #1032 why the QEMU kernel is still compiled for cortex-a53 (refines the entry above)
- Compiling for cortex-a53 (ARMv8.0) keeps the compiler from emitting ARMv8.1+ instructions such as the LSE atomics, and running that kernel on cortex-a76 lanes checks it.
- PAN (ARMv8.1) is required at boot: a core without FEAT_PAN halts, so the kernel no longer boots on a real A53. The maintainer accepted this rather than pay for a no-PAN fallback: "no newer instructions" now means the code the compiler emits, not boot on ARMv8.0 hardware.
- No active reason to change the compile target, so it stays cortex-a53. Revisit only if a v8.0 board must boot or the A53 target starts costing work.

## 2026-10-29 #1193 lane receipts measure check and guest time only (option a)
- A/B runs showed no lane slowed by #1172 or #1032; the growth was build work and host noise counted as busy lane time.
- Build everything (dune, race-window kernels, buildcheck objects) before the first lane receipt starts, so receipts hold only check and guest time, and re-derive the budget from quiet runs of that measurement. Rejected: subtracting build time inside each lane (b), and re-deriving the number without changing the measurement (c, which #1123 discourages).

## 2026-10-29 #1193 the lane budget is re-derived from the (a) measurement (option 1, provisional)
- Under the new measurement a quiet allcheck spends about 4570 busy lane-seconds with no product cause; busy time follows host contention. The limit becomes the measured total plus the documented 30 % host-load headroom (about 5900), with the derivation in check_lane_budget.py. Provisional: re-measure after the cortex-a76 switch (#1032) lands. A contention-insensitive metric (CPU time per lane) is a separate issue.
- The stale kept green copy (4412) is deleted with the maintainer's approval so a green allcheck can be taken.

## 2026-10-29 maintainer decisions on the away list (coordinator file 2026-10-29_away2.md)
- #638 stage 4: D1 (a) an `!{interrupt}` function may be called only from `!{interrupt}`/`exception` functions or inside a masked region, and mints CPU authority there; D2 (i) a fallible `preempt_off (cpu) { ... } else { ... }` block, the else arm running without authority instead of stopping.
- #954 stage 3 scope: (C) contracts beyond init and index bounds first, starting with #986 slice 2 (region arithmetic and overlay length as z3-checked obligations, now authorized). Sparse-init lemmas (#109) and loop-invariant inference are taken when needed.
- #1089: (A) torn writes stay outside the ext2 recovery model, as on Linux ext2 (fsck after power loss); document the boundary and close.
- #1013: (A) one phase-wide linear BootPhase token minted by main, borrowed for set/read during boot, consumed by `boot_phase_end` immediately before secondaries start (CPU_ON); plain loads after.
- #1032 IOMMU: (B) the RPi5 BCM2712 IOMMU first, then (A) QEMU virtio-pci behind smmuv3, so neither platform is left without IOMMU enforcement. Stack guard pages: D3 (i) the entry switches to the overflow stack and reports; D1/D2 pending a Linux/BSD comparison.
- #1027 steps 2-3: start now. Q1 (b) `--regions` stays explicit (`--internal-regions`) until #750; Q2 (a) `--emit-tla`/`--emit-protocol-source` become `--generate tla|protocol-source <dir>`; D2 (a) struct-layout and exception-frame-offsets become facts files, effect-matrix and doc move to `--generate`; D3 the depfile becomes `facts/deps.d`.
- #779: (b) the region type carries line alignment and the split rules preserve it.
- #774: (A) a linear `IrqClaim[id]` from the IAR read, source clears return `IrqAcked[id]`, EOI takes only `IrqAcked`, the default arm proves `id` is no handled source; (a) the handled set is a const array per platform.
- #926: (c) deferred and removed from ROADMAP.md (a 24-hour GICv3 build host is no longer a priority).
- #901: (b) implement the ppoll sigmask as the first consumer of #1000's delivery chokepoint; (c) now: nfds > 0 with a non-NULL sigmask returns EINVAL (Partial in SYSCALLS.md) instead of spinning.

## 2026-10-29 maintainer decisions, second batch
- #1032 stack guard pages: D1 (a) static stacks first, then (c) process kernel stacks from an L3-mapped arena with permanent guards (#1226); D2 (i) unmap the bottom 4 KiB of the reserved half, keeping 12 KiB of poison for high-water evidence; D3 (i) as recorded.
- #1218: (B) shrink the /pad filler first, then (C) embed the image LZ4-compressed (block format, zero-block elision in front) and expand at boot. The LZ4 codec lives in kernel/lib as a general compressor/decompressor over borrowed regions, reusable for a later zram-like feature. Network boot (#555) comes later.
- #709/#710 (after the #1224 audit found no handle crossing the syscall boundary): #709 (a) at release the slot at the last generation retires instead of returning to Free, public API unchanged, with a test-only boundary injection; #710 (a) the insert outcome gains an `Exhausted` case, refused before any freelist mutation.
- #755: (a) an immutable integer binding keeps one static for its lifetime; (d) versioned statics for mutable bindings is considered later if a consumer needs it.
- #901: (c) now, (b) through #1000's chokepoint as tracked in #1225; no separate mask-restore path (a).

## 2026-10-30 maintainer decisions, third batch
- #779: (c) for now: line alignment is decided at each device-protocol P_init from the concrete b and o after monomorphization; (a), a visible `region line(T)` kind, remains the growth path if #1006 wants it spelled (issue #779 comment).
- #774: (A) with the handled set as a per-platform `enum IrqSource` instead of a const array: the IAR id is converted with the checked `match id as IrqSource { ... miss => ... }` (#608), claims are per-variant (`IrqClaim[Pmu]`), source clears take only their own claim and return `IrqAcked`, EOI takes only `IrqAcked`, `miss` consumes the claim through `irq_unclaimed`. Disequality facts are implemented when a consumer first needs them (issue filed 2026-10-30).

## 2026-10-30 maintainer decisions, fourth batch
- External code: never commit external software source (for example parts of the Linux kernel) to this repository; licensing becomes hard to handle. A reference copy, when needed, lives outside the repository under ~/.takibi-sessions/ so it can be grepped.
- #1027 step 3: (a) non-production compiles (overlays, race windows, fixtures, linux_user and test controls) pass `--internal-allow-unused`; check_kernel_compile_flags.py refuses any opt-out in production kernel recipes and KERNEL_*_COMPILE_FLAGS and allows it elsewhere only through a listed exemption with a reason. The COMPILER_OUTPUT_EXCEPTION.md wording change ("--facts and --generate options") and the trap diagnostic wording are accepted.
- #638 stage 4: nmi functions may also call `!{interrupt}` functions (IRQs are masked there).
- #1013: (2) the phase still ends at CPU_ON; `boot_once_get`'s first-slice check is "this cell has been written" (one written word per cell, value stays the first field). Second group: tcp.tkb's our_mac.
- #1032 IOMMU: confirm on the board whether pcie2/RP1 is behind an IOMMU; if not, try (B') confining RP1's DMA to one DMA arena through the BCM2712 PCIe inbound window.
- #1227: (A) the boot key comes from the device tree's /chosen/rng-seed (or kaslr-seed); the fallback when it is missing is pending.
