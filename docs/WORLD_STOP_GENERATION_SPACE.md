# World-stop generation storage review (2026-11-09)

The standard production kernels are compared with published 34ee3015.
Original ELF/object pairs and layout/caller/global facts were copied from
its retained baseline, verified against that archive's immutable manifest,
and inspected read-only. Input hashes remained stable. Numeric observations
and artifact hashes are in WORLD_STOP_GENERATION_SPACE.json.

Only the generation field and its two operations change: usize becomes the
existing AtomicWord, with an acquire load and release store. Both occur in
private world_stop_begin_claimed after its caller acquired the existing
claim gate. The max-value check still releases the gate and returns Busy
before incrementing. No generation, acknowledgement, participant, token,
IRQ, rank, or request/release logic changes.

| Boundary | QEMU baseline -> candidate | RPi5 baseline -> candidate |
| --- | --- | --- |
| Generation field | 8 -> 8 B, offset 16 | 8 -> 8 B, offset 16 |
| WorldStop controller | 72 -> 72 B | 72 -> 72 B |
| Text (llvm-size) | 822792 -> 822792 B | 4207396 -> 4207428 B |
| Data | 4624 -> 4624 B | 5600 -> 5600 B |
| BSS | 1318912 -> 1318912 B | 1933312 -> 1933312 B |
| usable_ram_start | 0x40210000 -> 0x40210000 | 0x7e0000 -> 0x7e0000 |
| world_stop_begin_claimed | 420 -> 420 B | 408 -> 436 B |

All field offsets are identical: claimed 0, owner 8, generation 16,
requested 24, ack 32 (four words), participants 64. Both the production
controller and the shared stale-ack probe controller keep their 72-byte
symbols and addresses. Allocation workload, pool metadata, payload capacity,
retained pages, and image reservation are unchanged. No physical page is saved.

The QEMU object differs only in world_stop_begin_claimed's text. LLVM adds
one field-address calculation for ldar/stlr and reschedules the block within
existing padding. All linked symbol addresses/sizes and other allocated bytes
are unchanged. The RPi5 function adds one address calculation (4 B) and six
loop-alignment nops (24 B); its next function starts 32 B later, including
4 B additional inter-function padding. Its object differs only in that
function, its two shifted call relocation offsets, the function/mapping-symbol
metadata and the one FDE range (408 -> 436). All other object code sections
are byte-identical. Linked branches and address materializations follow the
32-byte shift; six GOT words match relocated symbol addresses. Data/BSS and
their symbols remain fixed. Unwind section size is unchanged.

This is a bounded stop path, not a scheduler/syscall fast-path change. The
acknowledgement loops retain their operations; RPi5 loop entry alignment adds
nops to the static image. The extra address instruction and acquire/release
ordering are not measurements of physical cycles or cache coherence. QEMU
cannot supply those claims. The small explained image cost is accepted for
an explicit typed cell without changing the claim protocol.

Actual compiler facts include both controllers and all 45 occupancy functions
on both targets, rather than merely mentioning the source in a depfile.
Only world_stop_begin_claimed's body hash changes; signatures, qualifiers,
inferred effects, callers and function-value references are identical.
The two existing private callers are world_stop_begin_config and
world_stop_machine_begin_kind, each acquiring the gate before calling it.
requires_mmu already applied through existing atomic members and is unchanged;
both platform builds enforce the pre-MMU entry restriction. BSS zero remains
the initial generation. No initializer, lock, CAS, or raw access is added.

The existing compiler recursively classifies protected fields and arrays as
composite. Both controllers now qualify, so only their two stale allowance
rows are removed through the existing --drop validator. This is a type-layout
classification, not a fixture exemption or a proof of protocol correctness.
Stale-ack injection, suppressed notification, partial authority and repeated
stop probes remain intact. Existing WorldStop and WorldStopRetry action rows
were re-read and restamped; no TLA+ action, property, bound or semantics changes.

Measure again if controller fields, membership, generation policy, stop callers,
or an allocation lifetime changes, or at the next completed kernel stage.
