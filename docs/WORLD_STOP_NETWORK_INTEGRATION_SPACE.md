# World-stop and network installed-word integration (2026-11-09)

This measured feature milestone covers the actual combination of the existing
AtomicWord migrations for WorldStop.generation and
NetworkCapabilityStore.installed_once. The baseline is published f2bf60f5.
Both baseline production ELF/object pairs and compiler facts were verified
against its immutable retained manifest before read-only inspection. Candidate
inspection held the existing shared kernel build lock after kernelbuild
completed. All input hashes stayed stable.

| Boundary | QEMU baseline -> combined | RPi5 baseline -> combined |
| --- | --- | --- |
| Text | 822792 -> 822808 B | 4207396 -> 4207428 B |
| Data | 4624 -> 4624 B | 5600 -> 5600 B |
| BSS | 1318912 -> 1318912 B | 1933312 -> 1933312 B |
| usable_ram_start | 0x40210000 -> 0x40210000 | 0x7e0000 -> 0x7e0000 |
| WorldStop | 72 -> 72 B | 72 -> 72 B |
| NetworkCapabilityStore | 32 -> 40 B | 24 -> 24 B |

These are combined measurements, not sums of component estimates. Actual
object text changes are confined to world_stop_begin_claimed,
network_capability_install and network_capability_take_waiting. The complete
compiler call-graph tables have the same functions, signatures, qualifiers,
effects, callers and function-value references; only those three body hashes
change. The JSON records actual object-section changes, linked allocated
section changes, selected symbols, struct layouts and artifact/fact hashes.

WorldStop keeps all offsets and its generation's eight-byte payload. The
network flag's byte becomes an eight-byte word. QEMU needs four bytes of
alignment before the word and consumes three old trailing padding bytes,
growing that object by eight bytes. RPi5 uses its existing seven trailing
padding bytes. Rounded BSS staying constant does not erase the QEMU payload
cost: later internal symbols move within the existing reservation. The
actual data/BSS symbol-size comparison changes only the QEMU network store.
No pool, allocator workload, retained capacity or physical page reservation
changes; existing occupancy evidence is reused only at that unchanged boundary.

WORLD_STOP_GENERATION_SPACE.md and NETWORK_INSTALLED_WORD_SPACE.md explain
the component address instructions, alignment gaps, FDE ranges and relocation
changes at their stated baselines. The actual combined size and function
boundaries agree with those explanations. There is no additional unexplained
image growth. Stronger atomic ordering and static instruction changes are
not measurements of physical cycles, IRQ latency or cache coherence.

The claim/overflow/current-generation acknowledgement protocol and the
Mutex/Place/try-lock/waiting protocol remain unchanged. AtomicWord provides
typed atomic access, not a proof of either protocol or of a refined zero/one
domain. BSS zero and the sole private store-one site remain the network
boolean-domain premises. Exactly three old allowance rows disappear through
the existing recursive field classification; no classifier exception or new
authority is introduced. Component runtime receipts retain their original
source/base scope; the final combined runtime and hardware gates are the
coordinator's exact-HEAD publication checks.

Measure again after a controller/flag representation or protocol change, a
new allocation or retention workload, or the next completed kernel stage.
