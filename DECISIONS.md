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

Format: `- YYYY-MM-DD <decision>. [active|superseded by YYYY-MM-DD] #issue`

## How the maintainer decides (worked examples)

These are not a complete statement of principles; they are cases where the
maintainer's judgment changed the course, kept so the pattern can be seen.

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
- 2026-10-14 Lock order moves toward ranked capability tokens (Fuchsia
  lock_order style), absorbing acquires_lock_<rank>_<name>, after the syntax
  review. [active] #789

## Trust and safety

- 2026-10-13 Only files in kernel/DEVICE_SEMANTICS_FILES may declare device
  protocols. [active] #720
- 2026-10-13 usb_xhci_bus.tkb (one function) replaces usb_xhci.tkb on the
  mint list. [active] #637 #720
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

- 2026-10-11 QEMU lanes run on 4 vCPUs; uart-wake pinned to 2 until #757. [active] #719 #757
- 2026-10-13 #9 closed; affinity follow-ups split into #775 and #776. [active] #9

## Size and performance

- 2026-10-13 Dead code is removed by the linker (--gc-sections), not by more
  whole-program optimization in the compiler; generated code is on demand,
  internal, inline when small, and linker-removable. [active] #786
- 2026-10-13 KEEP() for sections tied to assembly or placement;
  KERNEL_DEBUGGER_ENTRIES (--undefined) for functions called by name from
  outside the image. [active] #786
- 2026-10-13 An in-kernel sampling profiler, not a perf port. [active] #497

## Interfaces

- 2026-10-13 Takibi-only interfaces live under /proc/takibi/. [active] #497

## Process

- 2026-10-12 Audits include a per-defect table (root cause, debugging aid,
  cheap prevention, model check, compile-time check). [active] #753
- 2026-10-13 Workers run `make langcheck linuxcheck test` in full and pass
  space_checkpoint before reporting done. [active] #753
- 2026-10-12 Landing .agents/ and .claude/ changes takes the light route. [active] #753
- 2026-10-16 Compiler and tool input either passes or is an error; anything
  suspicious (a stale list entry, a flag that would be ignored) is never a
  warning, because warnings go unread. [active] #796
- 2026-10-14 sched_yield is implemented as a plain reschedule; harnesses fail
  fast on an unimplemented-syscall line. [active] #665
- 2026-10-15 RX capability split is option A (detached kept owner, holder refills,
  spare reserve with copy fallback; ring never fully drained, TLA+-checked);
  socket receive zero-copy waits for #497 measurement. [active] #740
