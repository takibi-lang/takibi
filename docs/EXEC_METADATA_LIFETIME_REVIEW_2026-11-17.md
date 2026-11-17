# Checked exec-metadata lifetime review

Source implementation: d5572f74, based on published da32b328. Review date:
2026-11-17. This completes the scoped boot exec scratch migration, not the
whole globals or memory-safety contract. SPEC.md defines the accepted syntax
and transfer rules; TRUSTED_BASE.md states the remaining premises.

## Change and assurance

A body-checked `borrows(inputs -> outputs)` summary lets an ELF result retain
its input metadata lifetime. Direct-call results, record copies, variant
payloads, projections and reborrows preserve complete origin sets. The inline
array storage of a by-value argument is distinct from its referent lifetime
and cannot escape through a wrapper/match. Unsupported retention, indirect
or external transfer, tuple/array loan storage and the documented loan-loop
shapes are rejected. Unsafe does not erase a tracked origin.

Internal data-origin tags distinguish the new checked/owned_by domain from
legacy indexed driver/guard contracts. Consumption, destructive-call and
witness invalidation resolve a tag back to its actual authority. The checker
never infers a data loan merely from the owner's type, drops local-storage
origins from a mixed set, or adds a caller-name exemption. Legacy contracts
retain their separately reviewed boundary; this is not general heap
provenance, arbitrary integer-address recovery, allocation uniqueness or a
reclamation/concurrency proof.

The maintained migration adds 29 `borrows` clauses and four source `borrow`
qualifiers at function boundaries. There are no new per-call proof statements,
loop invariants, unsafe blocks, runtime provenance fields or pool capacities.
Boot's dynamic-image check acquires the existing ExecWindowSlot, uses its
windows through the last plan mapping, then releases it. The dedicated
boot_exec_windows global disappears. The protection allowance count falls
from 22 to 21. Slot mint uniqueness, the atomic claim/release implementation,
physical storage correspondence and raw/assembly validity remain trusted.

## Space measurement

Baseline artifacts are the clean da32b328 main checkout's normal/debug
images from its successful full allcheck. Candidate artifacts were built in
the isolated implementation worktree with the maintained normal/debug targets.
`space_delta.sizes` and `space_delta.symbols` read ELF sections/symbols;
`buildcheck_frame_size.frames` reads LLVM stack metadata. Configurations are
compared separately; this is not a cross-OS comparison.

| Image | Text before / after | Writable data before / after | BSS before / after |
| --- | --- | --- | --- |
| QEMU normal | 827800 / 827880 | 4616 / 4608 | 1314816 / 1310720 |
| QEMU debug | 905124 / 905252 | 4616 / 4608 | 1314816 / 1310720 |
| RPi5 normal | 4220948 / 4221044 | 5592 / 5584 | 1916928 / 1916928 |
| RPi5 debug | 4307168 / 4307232 | 5592 / 5584 | 1830912 / 1830912 |

Bytes above separate section totals from payload. The only named data/BSS
symbol whose size changes is boot_exec_windows, 2048 -> 0. Exec_windows stays
8192 bytes, with four existing slots and unchanged claim-word metadata.
The writable-data decrease is the eliminated GOT entry, not a smaller typed
record. Alignment makes QEMU's BSS decrease 4096 bytes and RPi5's aggregate
BSS stay unchanged. No retained page count or pool occupancy saving is
inferred from those section totals.

Normal usable_ram_start stays 0x40210000 on QEMU and 0x7e0000 on RPi5.
RPi5 debug also stays 0x7e0000. QEMU debug moves 0x40228000 -> 0x40220000:
BSS ends at 0x401c1000 -> 0x401c0000, crossing the existing 32768-byte
stack alignment. This 32768-byte reservation difference is linker layout,
not 32768 bytes of removed payload or a new allocator-capacity claim.

Only kernel_test_driver_run changes its LLVM static frame:

| Configuration | Before / after, bytes |
| --- | --- |
| Both normal targets | 1040 / 1120 |
| QEMU debug | 1072 / 1152 |
| RPi5 debug | 1072 / 1136 |

All other defined-function frame records match, and the existing ceiling and
exceptions pass unchanged. These are individual static frames, not a bound
on every dynamic call chain or handwritten assembly stack use.

Accept the small code/frame growth for checked lifetime retention and removal
of a separate unprotected scratch allocation. The workload is the maintained
boot's dynamic HTTPd/musl image validation/mapping followed by ordinary exec
and teardown using the same bounded pools. Boot acquisition adds the existing
slot claim/release operations; no isolated cycle-cost or contention benefit
is claimed. Whole-boot regression verdicts belong to the final clean allcheck,
not the linked-image measurements. New allocation/reclamation paths or the
next completed memory-safety consumer trigger another measurement.

## Compile and verification cost

The published baseline allocates 742891639 OCaml words, nearly the entire
743000000 ceiling. The candidate initially measured 756077880. A brief
completed-type-shape cache experiment saved only 112011 words and did not
resolve the ceiling; the mutable cache was discarded. Sharing the pure
shape helper leaves a final measurement of 756052271 (+1.77%). Following
the existing measured-headroom policy, the ceiling becomes 946000000,
about 25% above the measurement. Lane counts, solver budgets, static rules
and accepted fallbacks do not change. Historical measurements within the
new ceiling are positive budget controls; one-word-over and malformed/unknown
inputs remain negative controls.

`make allbuild` passed before the source commit. Both debug target builds
passed, as did the 1279-case type_inf group. Fifteen compile-only controls
import the real ELF validator/segment API: five live/helper/wrapper/referent
positives and ten release/reuse/retention/summary/storage negatives. Invalid
objects were never executed. Generic maintained unit regressions cover the
same data-flow mechanisms, including direct-reference projections.

A mutation that filters match-payload origins to named contract/owner origins
accepts both the annotated and plain by-value-row dangling returns. The
repaired compiler rejects both; direct-return rejection and the borrowed-row
positive survive in both compilers. This independently exercises transfer
state, rather than asking Z3 to re-check the same lost-origin premise.
A second mutation restoring broad fresh-address taint rejects the legacy
field-address positive; direct owned-data retention remains rejected in both.
The paired maintained regression therefore detects the population overreach.

The initialization integration's build-derived trust ledger is refreshed at
this boundary. Its two user_entry_extern raw sites and 1008 additional
initialization obligations were already published before this migration;
they are attributed to that integration, not silently counted as new trust
or additional proof of the lifetime rules. The lifetime rules add no solver
proof of aliasing or execution. The broader contract and Rust comparison
remain obligations in MEMORY_SAFETY_CONTRACT.md.
