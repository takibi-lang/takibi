# Retained TCP cost words: measured milestone

Four TcpPoolCostSample fields use existing AtomicWord access. The private
array still retains three samples. No owner, mailbox, round/rendezvous,
loop, IRQ/rank, benchmark work or print format changes. This is a completed
storage migration, measured against published 1a2a69ee, not an incremental
metadata correction.

## Access and measurement boundary

CPU 0 records all four lock/owner results before the four stores. The report
loads those four words only after each timed sharing pair completes. All four
stores remain after all four results, and all four loads remain after both
sharing measurements. Neither changes the timed helpers or introduces an
atomic access inside their measured intervals. Later observations can still
be affected by surrounding execution; no claim of identical measured timing
values is made.

The sole writer and reader are tcp_pool_cost_evidence and pin_sharing_evidence,
called in that order by the shared contention probes after normal MMU/network
initialization. The existing sample loop has three bounded indices. There is
no whole-record copy, alternate writer, peer access or escaping field pointer.
Both actual production global tables report [TcpPoolCostSample;3] composite,
with exactly four atomic stores and four atomic loads. Only its existing plain
allowance is removed, naturally, without a fixture exception or classifier
rule. At this published base the allowance count moves 31 to 30.

AtomicWord statically requires typed atomic cell access; it does not prove
CPU-0 ownership, initialized sample sequencing, coherence, a multiword snapshot
or the surrounding mailbox protocol. Those source/caller premises remain
trusted and unchanged. No new guard or capability is introduced. Model actions,
properties and semantics are unchanged; neither changed body is mapped, so no
body-map restamp is required. Existing mapping and caller controls retain their
narrower evidence boundary.

All literal output bytes, decimal formatter calls, argument meanings and their
order are preserved by exact source comparison. Raw timing numbers are
observations and are not expected to be byte-identical between executions.
Existing QEMU-main pool_contention views cover lock/owner completion and
pin-sharing setup/work/cleanup; the raw three timing records can be checked
against their existing format. No mirror test, new lane or budget is added.
QEMU establishes operations/counts only, not physical timing or cache coherence.
Final physical integration belongs to the coordinator's land.

## Actual layout and image observations

Ten selected original production ELF/object/fact inputs are copied from the
published baseline and SHA-256 verified before inspection; originals are
read-only. Candidate inputs are actual built production artifacts. Read-only
inspection and final artifact binding use the existing shared build lock and
before/after hashes. JSON retains hashes, symbols, sections and bounded
instruction histograms; external evidence also retains targeted disassembly,
relocations, FDE dumps and the exact source diff.

| Boundary | QEMU before / after | RPi5 before / after |
|---|---|---|
| Sample size and field offsets | 32 B; 0/8/16/24 / same | 32 B; 0/8/16/24 / same |
| Three-sample retained payload | 96 / 96 B | 96 / 96 B |
| Sample array address | 1075478160 / same | 7836216 / same |
| Linked .text | 645008 / 645056 B | 688676 / 688740 B |
| llvm-size text | 822808 / 822856 B | 4207428 / 4207492 B |
| llvm-size data | 4624 / 4624 B | 5600 / 5600 B |
| llvm-size BSS | 1318912 / 1318912 B | 1933312 / 1933312 B |
| usable_ram_start | 1075904512 / same | 8257536 / same |
| Writer function | 464 / 492 B | 504 / 536 B |
| Reporter function | 464 / 476 B | 456 / 468 B |

The writer replaces two paired stores with four release stores and three
address additions: +20 B of instructions on both targets. QEMU adds two loop
NOPs (+8 B), giving +28 B; RPi5 adds three (+12 B), giving +32 B. The reporter
replaces four loads with four acquire loads plus three address additions:
+12 B on both targets. Stack-frame allocation stays 112 B in each writer and
96 B in each reporter; no new benchmark-stack allocation is introduced.

QEMU inter-function padding after writer/reporter grows 0-to-4 B each, so
28+12+8 = 48 B linked text growth. RPi5 writer padding remains 8 B, reporter
padding grows 8-to-12 B, and padding after unchanged tcp_claim_probe_meet grows
12-to-28 B before tcp_claim_probe_run: 32+12+4+16 = 64 B. These are exact static
code/layout costs, not measured physical cycles, latency or coherence.

Only the two object text sections change. Their relocation counts stay 19 and
50; their offsets change with instructions. Object eh_frame and symtab bytes
change at unchanged sizes; all other object sections retain sizes and bytes.
Linked unwind/GOT sizes and addresses stay fixed while resolved contents move;
five GOT slots change on each target. Changed linked instruction bytes occur
in 248 QEMU and 286 RPi5 functions through relocation resolution, despite only
two changed object text sections. JSON records function address-shift counts;
these are not extra source/API changes. No data/BSS payload or image reservation
changes, no retained-page saving, and no allocator/storage-lifetime change is
claimed. Existing occupancy and cross-OS observations retain their old boundary.

Assessment: accept the small, explained +48/+64 B code cost for existing typed
atomic access without changing retained payload or measured interval contents.
No further structural optimization is justified for this leaf. Remeasure at
the next completed kernel feature, changed sample count/representation,
benchmark interval, retained lifetime or image layout.
