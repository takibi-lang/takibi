# Lockless multi-writer kernel log ring: design proposal (GitHub issue #613)

Status: option B selected (2026-10-18), with the changes below. Slices 1-4
are implemented: the ring's storage, the hand-written token and the syslog
and DDB readers are in kernel/printk/log.tkb, with core 0 still the only
writer (see "As built, slice 4" below). Peers writing directly is slice 5.

## Maintainer decisions (2026-10-18, recorded on #613, #645, #656)

1. Option B, but no fixed per-line limit. A record may span k consecutive
   slots: one head CAS reserves k slots, and continuation marks in the slot
   state word tie them to the first. 160 B is the allocation unit. Above a
   large cap (a fraction of the ring) a line is split into continuation
   records, never silently truncated. LogRing.tla covers multi-slot records
   within its stated bound (e.g. k <= 2, N = 3-4 slots).
2. Hand-written tokens first; the protocol-declaration generator replaces
   them after #720. Approved.
3. CAS returns the observed value on failure (`Swapped | Observed(v)`).
   Approved.
4. herd7 model checks only; no litmus7 and no RPi5 hardware runs. Instead a
   check ties each litmus test to the instructions the compiler emits.
5. #656 retargets to LogRing.tla.

## As built, slice 4 (2026-10-18)

- Storage: 256 slots x 160 bytes of AtomicWord text, one state word per slot
  `seq << 16 | cpu << 8 | span << 4 | state` (state Free, Reserved,
  Committed, Discarded; span 0 marks a continuation), a tick and a metadata
  word (length, cpu, continued flag) per first slot. A record spans at most 4
  slots (KERNEL_LOG_RECORD_SLOTS, 1/64 of the ring); a longer line is split
  into continuation records whose metadata says so, printed as one line.
  The per-slot stamp, length and cpu arrays and the started count are gone.
- One head compare-swap reserves k slots, so k must be known first: core 0
  stages its line in a static 640-byte buffer (no stack buffer) and reserves
  at the newline. A partial line is therefore never visible, as decided.
- Token: `linear struct LogReservation[unit]` with private fields, built only
  by kernel_log_reserve and consumed by kernel_log_commit or
  kernel_log_discard (`sink`); kernel_log_write borrows it. `no_copy` as
  proposed is not consumable (SPEC: copying it into an argument is an
  error), so the linear owner of the Ext2Slot precedent is what carries
  "write after commit" and "reserved, never finished" as compile errors.
- Reader: kernel_log_slot_view returns a sealed KernelLogUnvalidated (the
  observed word) only for (seq, Committed, span >= 1); kernel_log_still must
  find the same word after the copy. DDB `log` reads raw under the world
  stop and prints a Reserved slot as `in-flight cpu=C`; the stall walk of
  ordinary lanes sends it too.
- Every compare-swap is atomic_compare_swap_acq_rel (CASAL), through one
  helper. The text stores stay STLR: the slice-2 finding that the claim's
  acquire alone orders them holds (LogRingRecheck+plain-text), but an
  AtomicWord has no plain store and the text must stay AtomicWord for the
  reader's acquire loads.
- Claim rule corrected: the previous occupant must be finished and OLDER,
  not exactly seq - N. With the exact rule a refused claim leaves its slot
  holding an older turn and every later turn of that slot is refused for
  ever (LogRing.tla variant exactprev, invariant NoNeedlessRefusal).

The sections below are the original proposal; where they disagree with the
decisions above (fixed 160-byte cap, litmus7 on RPi5), the decisions win.
Related: #645 (herd7 litmus), #656 (LogReader replay), #813 (continuous
trace), #638 (per-core line state left to this issue), #720 (common protocol
declaration generator).

## Current state

- `kernel/printk/log.tkb`: core 0 is the only writer of the retained ring
  (256 fixed slots x 160 bytes, text in AtomicWords, every store a release).
  Readers (syslog(2) on any CPU) acquire-load `kernel_log_started`, copy, and
  re-validate the slot stamp (`kernel/models/LogReader.tla`, #612).
- Peers publish whole lines into per-core peer slots
  (`kernel_log_peer_*`, ~6 KiB text + per-core 192-byte line buffer in
  `KernelLogCoreState`) that core 0 drains later. Consequences: order is
  arrival-at-core-0, ticks are the peer's but sequence is core 0's, peer
  lines are lost if core 0 is slow, and the per-core line state is one of
  the #638 per-CPU sites blocking preemption.
- Atomics: `atomic_word_{load_acquire,store_release,swap,fetch_add_relaxed,
  compare_exchange}`; CAS returns bool only, so "CAS then load" treats two
  observations as one (the #556 recurrence).
- Ordering is a comment, not a type (`kernel/lib/atomic_word.tkb`, first
  limitation). The protocol (who may write a slot when) is not typed.
- UART output of boot-validation markers is synchronous and separate from
  the retained ring; the ring must not change marker order or timing.

## Options

### A. Linux printk_ringbuffer shape (descriptor ring + data ring)

Reserve: CAS on desc head id, then CAS on the data ring head (variable-size
blocks, blk_lpos with wrap). Desc state word = id | state {reserved,
committed, finalized, reusable}; tail pushed by writers that need space.
Readers copy and re-validate state+id.
- Types: linear reservation token (existing `no_copy` + private fields);
  data block bound to the token as a region capsule (needs #131/#672 field
  moves and #637 exclusive backing storage).
- Model: two rings, tail pushing, data-block wrap: large state space;
  likely beyond the "tractable model" line at 2 writers + reader + wrap.
- Litmus: ~8 tests (desc reserve, data reserve, commit, finalize, tail push,
  reader re-validate, ABA, unfinalized trust), each with unfixed variant.
- .bss: data ring 32-64 KiB + 256 desc x 32 B. Space-efficient for short lines.
- Faithful to #613's text; heaviest.

### B. Fixed-slot global ring with state+sequence word (recommended)

Keep today's 256 x 160 slot layout. Per slot one state word
`seq << 2 | state` with state in {Reserved, Committed(=finalized), Discarded}.
- Reserve: CAS (acq_rel) `head` s -> s+1 claims sequence s; then CAS the
  slot word from `(s-N, Committed|Discarded)` to `(s, Reserved)`. If the
  previous occupant is still Reserved (a stalled writer), the new writer
  does not wait: it records s as lost (counter + loss-by-sequence report)
  and returns `Refused` (exhaustive failure, no token).
- Write: text into the slot through the token (release word stores, as
  today); no stack buffer.
- Commit: release CAS `(s, Reserved)` -> `(s, Committed)`, consuming the token.
  Discard likewise -> Discarded. A line is committed at its newline, so
  partial lines are never visible; "finalize" folds into commit because
  slots are fixed-size (no extension of a committed record).
- Reader: acquire-load slot word, require `(s, Committed)`, copy, re-load the
  word; anything else is in-flight or overwritten, reported by sequence.
- Overwrite policy: oldest overwritten (as today); loss is never silent.
- Preemption: holding a token requires a `PreemptOff` borrow (decided #638
  mechanism), so a reservation lives within one CPU's non-preemptible
  region and per-core line state disappears into the token (#638 site
  closes). IRQ context: the protocol is IRQ-safe (CAS only, no wait); the
  effect rule keeping handlers out of `kernel_boot_log` stays, so enabling
  IRQ writers is a separate later decision. A nested writer on the same
  CPU simply reserves a later sequence.
- DDB / postmortem: world stopped, so a trusted raw reader prints every
  slot by sequence including `Reserved` ones as "[in flight seq N cpu C]".
- UART: the writer still emits its line synchronously under the console
  lock after commit; markers keep today's order per line. Peer rings and
  core 0's drain are deleted.
- Types (existing features): `struct no_copy LogReservation { private seq;
  private slot: {0..<N} }`, constructed only inside log.tkb, consumed by
  `kernel_log_commit` / `kernel_log_discard`; text writes take `borrow mut`
  of it, so "write after commit" and "reserved, never committed" are
  compile errors (linear leak check). Reader side: `Unvalidated` copy type
  that becomes a record only through re-validation (sealed constructor).
- Model `kernel/models/LogRing.tla`: 2-3 writers, 1 reader, N=2-3 slots,
  sequence bound ~6. Invariants NoTornRead, NoSilentLoss (every seq below
  head is returned, in flight, or reported lost), NoDoubleOwner. Unfixed
  configs: ABA (state word without seq), reader trusts Reserved, reserve
  without checking previous occupant. Tractable.
- Litmus (AArch64, using the instructions the compiler actually emits):
  MP text->commit (STLR words, CAS-rel commit; LDAR reader), reader
  re-validate (seqlock-read shape), reserve CAS chain vs reader, reuse/ABA.
  ~5 tests + unfixed variants (each release/acquire weakened to plain).
- .bss: today's 40 KiB text + 256 x 8 B state words; minus peer rings and
  per-core line buffers: net smaller. Stack: none added.
- Wastes space for short lines; caps line length at 160 (as today).

### C. Per-CPU single-writer rings, merged by readers

Each CPU owns one ring with today's #612 protocol; a global sequence from
`fetch_add` orders records; readers merge.
- Types: reuse single-writer protocol; `PreemptOff` gives CPU authority.
  Simplest, almost no new language need.
- IRQ on the same CPU breaks single-writer unless IRQs are masked per line.
- Not multi-writer: misses #613's purpose (the severe multicore subject for
  route step 3). Readers see sequence gaps that are in-flight on another CPU.
- .bss: same total split per CPU; a quiet CPU's share is wasted.

## Language-design items (need maintainer)

1. Protocol declaration for shared atomic state. DECISIONS 2026-10-11 picks one
   `protocol` declaration generating TLA+ and sealed owners, but today it is
   device-only (DEVICE_SEMANTICS_FILES). Using it for the log ring extends it
   to CPU-shared memory with per-slot identity (seq) and transitions realised
   by named atomic operations. That is a language design change. Proposal:
   slices 1-5 hand-write the token types (existing features), and the
   generator replaces them once #720's generator exists.
2. CAS returning the observed value (`atomic_word_compare_exchange` ->
   `Swapped | Observed(value)`), proposed on #613 after #556. New compiler
   builtin/API surface.
3. Whether transitions name their ordering in the declaration (so a lint can
   compare against emitted instructions and litmus files). Recommend NOT
   generating litmus tests; hand-write them with a mapping table (#645 step 4).

## Tooling: herd7 / litmus7

- herdtools7 via opam, pinned 7.58 (current opam version; deps ocaml>=4.08,
  dune, menhir, zarith). Do not install into the shared `ocaml` switch.
- Install location: `scripts/fetch_model_tools.sh` gains a herdtools7 entry
  that builds the pinned source tarball (sha256-checked) into
  `$root/herdtools7-7.58/` under the existing model-tools root
  (`~/.takibi-sessions/cache/model-tools`, `TAKIBI_MODEL_TOOLS_DIR`
  override), e.g. a local opam switch at that path or `dune build` +
  `make install PREFIX=`. Lanes call the fetch script, as they do for TLC.
- As built (2026-10-18): the devcontainer installs herdtools7.7.58 with
  opam into its switch; CI builds it with `scripts/build_herd7.sh` in a
  throwaway OPAMROOT into `/home/runner/herd7`, cached under a key that
  hashes the script, and passes `HERD7` to make. `opam install` in CI's
  in-checkout `_opam` switch failed: herdtools7's dune took takibi's
  dune-project as its root.
- litmus7 emits C with pthreads for a Linux host. The RPi5 lane boots the
  Takibi kernel, not Linux, so running litmus7 output needs either the
  Takibi userland to run the generated static binary or a separate Linux
  boot of the board. Open question for #645.

## Slice plan

1. #645: tooling fetch, litmus tests for the current #612 protocol, make target.
2. LogRing.tla + unfixed configs in `make modelcheck`; litmus tests for
   reserve/commit/reuse with unfixed variants (before code, #645 step 5).
3. (decision 2) CAS-with-observed-value builtin, if accepted.
4. Ring storage + hand-written token, core 0 still the only caller; syslog
   reader and DDB raw reader on the new protocol.
5. Peers write directly; delete peer rings and drain; per-core line state
   (#638) into the token; RPi5 long all-core run with loss-by-sequence.
6. Route step 3 note: what types carried, what not.
7. After #720's generator: protocol declaration replaces hand-written token.
#656: retarget to LogRing.tla (serialization point = the slot word CAS) or
close as superseded. #813: unblocked after slice 5 (trace records need a
second payload kind or channel; decide then).
