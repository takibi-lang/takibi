# Litmus tests for the kernel log's memory ordering (GitHub issue #645)

`make litmuscheck` (a prerequisite of `make modelcheck`, so in allcheck and
CI's cicheck) runs herd7 over every test against expected.txt, then ties the
fixed tests to the RPi5 kernel object through emitted_map.txt
(scripts/run_litmus_checks.py). herd7 comes from opam in the devcontainer (herdtools7, pinned in
.devcontainer/devcontainer.json); CI builds it once with
scripts/build_herd7.sh, outside the checkout, and caches it.
scripts/check_herdtools_pin.py keeps the two pins equal. A pass is bounded evidence: the
AArch64 model says the two-thread shape is forbidden, and the lint says the
named functions use those instructions; it does not prove the Takibi code
has no other ordering dependency.

Each test is the two-thread shape of one ordering claim of the kernel log
ring in kernel/printk/log.tkb, with unfixed controls that weaken one access.
The single-writer ring's tests (LogPublish, LogReuse, #612) were removed with
that ring in #613 slice 4.

## The multi-writer ring (GitHub issue #613)

The LogRing tests are the orderings LogRing.tla assumes, written before the
ring existed against the instructions the compiler emits for the RPi5:
`atomic_word_store_release` is STLR, `atomic_word_load_acquire` LDAR, and an
acq_rel compare-exchange the LSE `CASAL` (the kernel object holds CASAL and
CASA, no LDAXR/STLXR loops). Values: state 1 = (s, Reserved), 2 = (s,
Committed), 3 = (s+N, Reserved).

| Test | P0 | P1 | Forbidden outcome |
|---|---|---|---|
| LogRingCommit | writer: STLR text, then CASAL commit 1 -> 2 | reader: LDAR state, then LDAR text | Committed seen, old text read |
| LogRingRecheck | overwriting writer: CASAL claim 2 -> 3, then STLR text | reader: LDAR text, then LDAR state (re-check) | new text copied, re-check still sees the old Committed |
| LogRingReserve | writer: CASAL head 0 -> 1 | writer: CASAL head 0 -> 1 | both reserve sequence 0 |
| LogRingClaim | old writer: STLR text, CASAL commit 1 -> 2 | next claimer: CASAL claim 2 -> 3, STLR text | claim sees Committed, old text lands last |

Controls: `+unfixed-writer` drops the release of the commit CAS (CAS for
CASAL) in Commit and Claim; in Recheck it drops both the claim's acquire
and the text's release (CAS and STR), because either alone forbids the
outcome -- `LogRingRecheck+plain-text` (CASAL with a plain STR, expected
Never) records that the claim's acquire alone suffices, so slice 4 may use
plain text stores after a CASAL claim. `+unfixed-reader` makes P1's first
load plain (LDR). `LogRingReserve+unfixed-loadstore` replaces the CAS with
LDAR, ADD, STLR: atomicity, not ordering, is what the head CAS gives.

Each fixed test is tied to the emitted code by emitted_map.txt (slice 4).
Every compare-swap of the ring is one helper, `kernel_log_cas`, which is
CASAL; the writer's text stores are `kernel_log_write`'s STLRs and its
commit `kernel_log_commit`'s CASAL, called in that order by
`kernel_log_retain_line` (a `callorder` row); the claim is
`kernel_log_reserve`'s; the reader is `kernel_log_snapshot_record`, whose
first slot-word load precedes its text loads (`order-first`) and whose
re-check follows them (`order-last`). run_litmus_checks.py parses the CAS
forms (a compare-swap is direction "rmw", classed CAS, CASA, CASL or CASAL by
its suffixes) and plants seven defects it must report, among them the
helper's CASAL weakened to CAS and the reader cut off before its re-check.

The text stores stay STLR although `LogRingRecheck+plain-text` shows the
claim's acquire would allow plain STR: an AtomicWord has no plain store, and
the text must stay AtomicWord because the reader's loads of it must be
acquires (`LogRingRecheck+unfixed-reader`). Using STR would need a plain
store on an atomic cell, a compiler surface this slice does not add.
