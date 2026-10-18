# Litmus tests for the kernel log's memory ordering (GitHub issue #645)

`make litmuscheck` (a prerequisite of `make modelcheck`, so in allcheck and
CI's cicheck) runs herd7 over every test against expected.txt, then ties the
fixed tests to the RPi5 kernel object through emitted_map.txt
(scripts/run_litmus_checks.py). herd7 comes from opam: herdtools7, pinned in
.devcontainer/devcontainer.json and .github/workflows/ci.yml, which
scripts/check_herdtools_pin.py keeps equal. A pass is bounded evidence: the
AArch64 model says the two-thread shape is forbidden, and the lint says the
named functions use those instructions; it does not prove the Takibi code
has no other ordering dependency.

Each test is the two-thread message-passing shape of one ordering claim in
kernel/printk/log.tkb (#612), with unfixed controls that weaken one access.

| Test | P0 (core 0, writer) | P1 (reader, any CPU) |
|---|---|---|
| LogPublish | `kernel_log_capture_retained_byte`: STLR text word (`kernel_log_text`), then STLR length (`kernel_log_lengths`), both via `kernel_log_publish` | `kernel_log_snapshot_record`: LDAR length, then LDAR text word, via `kernel_log_observe` |
| LogReuse | record begin: STLR `kernel_log_started` FIRST, then STLR a slot word | `kernel_log_snapshot_record`: LDAR the slot word, then LDAR `kernel_log_started` for the re-check |

Unfixed controls: `+unfixed-writer` makes P0's second store plain (STR);
`+unfixed-reader` makes P1's first load plain (LDR). herd7 must then allow
the outcome the fixed test forbids.

## The multi-writer ring (GitHub issue #613, before its code)

The LogRing tests are the orderings LogRing.tla assumes, written before the
ring exists against the instructions the compiler emits for the RPi5 today:
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

These tests are not yet tied to emitted code: emitted_map.txt marks each
`pending`, and the check refuses a fixed test that has neither access rows
nor a pending row. Slice 4 replaces the pending rows with access and order
rows once `kernel_log_commit`, the reservation and the reader exist. First
it extends `litmus_accesses` and `accesses` in scripts/run_litmus_checks.py
to the CAS forms (`CASAL Xs,Xt,[Xn]` is a load and a store; its A and L
suffixes give the acquire and release class), which neither parses today,
and adds a planted control that weakens a CASAL to CAS.
