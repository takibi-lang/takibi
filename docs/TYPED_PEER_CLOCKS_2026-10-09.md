# Typed peer clocks and owned resume observations (2026-10-09)

## Workload and choice

Use the existing language for the maintained, non-migrating CPU 0/1 boot
probes. Fifteen consumer files have 46 peer-window construction sites; the
world-stop probe also holds a stopped peer and then observes its release.
The maintainer selected this API change after comparing aggregate invalidation
and scalar provenance checking. Neither compiler extension is introduced.
Atomic predicates, memory orders and the four original tick budgets remain.

## Guarantees at their actual strength

| Construct | Compile-time exclusion | Trusted obligation |
| --- | --- | --- |
| `PeerTickBudget[p]`, `WallHoldBudget` | A wall budget cannot be passed as a peer budget | Named budget policy and hardware counter frequency |
| `PeerTickStamp[p]` | Different peer indices cannot be compared | Counter sampling, wraparound and physical truth |
| `PeerTickWindow[p]` | Private literal construction and uninitialized local minting are rejected; polling borrows and terminal consumption is required | CPU 0/1 peer selection and window duration |
| `WorldResumeTick[stop, peer]` | Old measurements are not tickets; private literal and uninitialized local minting, reuse after cancellation and a changed peer are rejected | Acknowledged stop mask includes the peer; baseline is sampled while stopped |
| `world_stop_release_for_tick` | Consumes the actual stopped authority once and returns the indexed ticket | Correct release implementation and actual remote progress |

The ordinary stamp and budget wrappers are measurements, not linear authority.
An ordinary struct can be zero-initialized without an explicit literal; private
fields do not establish universal source provenance. Their indices prevent
accidental clock/peer mixing, not fabricated physical measurements. The linear
window and resume ticket are the API boundaries that reject this initializer
bypass. Trusted implementations can still mint a semantically wrong ticket.
The constructor-reversion runtime control therefore remains necessary.
A ticket is not a global epoch fence: another stop does not automatically
invalidate it. The maintained consumer completes or cancels its observation
before any later stop; cross-operation provenance was not added.

`world_resume_tick_cancel` ends local bookkeeping. It neither certifies that
the peer resumed nor reverses the release. Partial and unacknowledged stops do
not mint a ticket; the probe reports their refusal directly. A tick is not
proof that a peer reached the awaited instruction. QEMU supplies forced,
bounded regression evidence, not physical cache or interrupt-timing proof.

## Annotation and migration cost

The helper stores the same four machine words as before (32 bytes on AArch64).
Peer indices are erased. The resume ticket has two machine words, with no new
global, allocation or pool. The wall hold retains its two scalar-sized values.
The four named policies preserve 16, 32, 64 and 128 ticks; the emergency wall
backstop remains ten seconds.

Each of the 46 waits now selects a named policy and explicitly consumes its
window after polling. Seven early-success paths also consume before returning.
The world-stop probe retains one ticket during its resume wait and cancels it
at the end. This is the cost of using existing linear initialization rules;
there is no ghost state, new syntax, solver query or per-poll annotation.
Optimized frame sizes are not inferred from these source-level payload sizes.

## Prevention review

The initial ordinary and affine windows accepted an uninitialized local,
allowing zero storage to bypass the intended mint. Literal-constructor tests
missed it because privacy is checked at a literal, while ordinary storage
allows default initialization. The new production-source rejection case failed
on both designs and passes with a linear window. The resume ticket already
used linear ownership. Both boundaries are checked using real declarations
and bodies with an external consumer filename; their authority mint and raw
hardware primitives are stubbed, so these tests do not simulate a CPU stop.

Twelve compiler cases cover a positive codegen path and the invalid consumers
in the table, including wrong-peer resume consumption. The positive case runs
AArch64 LLVM generation and checks that no traps are emitted. These tests use
existing checker rules, rather than adding a source-name-based lint. The
source gate still rejects direct wall-only rendezvous bounds and checks the
shared helper's peer-tick condition. It does not inspect every possible callee.
A new protocol model is unnecessary for this representation change; existing
runtime controls test the trusted sample/release sequence that types do not
prove. The actual source freshness check prevented a stale-ELF test during
this work, before any guest ran.

The source survey covers all 46 maintained peer windows. Ordinary historical
measurements remain valid values; rejecting every retained scalar would need
the larger provenance design that was not selected. Existing deliberate wall
holds remain reviewed separately. Typed atomics are a subsequent migration;
this change does not discharge their memory-ordering obligations.

## Validation and space

The linked-image and runtime observations below use base `50a6811f` and the
same maintained boot workload. Image reservation, data/BSS, source payload
sizes and allocator occupancy are separate boundaries.

`python3 scripts/space_delta.py 50a6811f` built both production kernels and
compared every linked data/BSS symbol:

| | QEMU base | QEMU candidate | RPi5 base | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| text | 724284 | 726828 | 734036 | 736740 |
| data | 5078 | 5078 | 2888784 | 2888784 |
| BSS | 1658608 | 1658608 | 1697600 | 1697600 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data/BSS symbol changed size. Text grows 2544 bytes (QEMU) and 2704 bytes
(RPi5); image/page reservations do not move. Adopt this small fixed code cost
for typed boundaries and explicit local obligations. No allocator payload,
pool metadata, allocation policy or steady-state lifetime changed. The actual
bounded boot exercises the 46 waits and the resume ticket. This is a fresh
linked-image milestone measurement, not a claim of fresh cross-OS comparison
or measured optimized stack-frame sizes. Next measure at the typed-atomic
probe milestone, another new resource lifetime, or a changed allocation
workload.

Before the implementation commit, `make allbuild` passed, including all
historical target builds, and the 142-member `make langcheck` passed. All
1795 compiler tests passed. The IRQ-masked, 750 ms delayed-entry QEMU kernel
passed all 70 views. These targeted checks are not a substitute for the clean, rebased hardware
publication gate.

The delayed-entry boot's pool samples are preserved in
`TYPED_PEER_CLOCK_POOL_ENDPOINT_2026-10-09.tsv`. At `bounded_end`, user pages
are zero, the process pool has one empty 16384-byte chunk, and image,
FD-context, FD-block and object pools each retain one occupied baseline slot.
This is a fresh candidate endpoint, not a before/after occupancy comparison
with the older per-CPU ELF capture: that capture predates the larger process
payload. No production allocation or payload declaration changed from the
linked-image baseline in this implementation.

The complete `kernelcheck-probe-ticks-qemu` target passed: restoring the old
wall-only bound exits nonzero with the console missing-ready diagnosis;
seventeen real consumers refuse a missing participant; the frozen resume
observation reports `resumed=0` and two signal attempts. Restoring the old
trusted baseline and signal loop reports `resumed=1` and 32 attempts, and the
host oracle fails with both specific diagnoses. Status and diagnostic are
checked independently. The corrected refusal control completed in 11.8 host
seconds locally; these are forced schedules, not a natural failure rate.
