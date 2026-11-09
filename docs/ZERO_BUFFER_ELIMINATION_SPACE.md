# Zero-reference buffer elimination: measured milestone

The two process-image page loaders compare bytes directly to literal zero
through byte_slice_is_zero in the existing readonly byte utility. Six logical
whole-page/prefix/suffix comparisons retain their outcomes, empty views are
true, and zero-fill, file copies, overlap arithmetic, mapping and error paths
are unchanged. The permanent zero-reference array and exactly its allowance
are deleted. No readonly-storage or compiler feature is introduced; immutable
array alias protection remains a separate unresolved language requirement.

## Source, ownership and test boundary

The new predicate borrows []const u8, retains nothing and uses safe element
iteration with no index expression or raw/unsafe operation. It reads one byte
per iteration and exits at the first nonzero byte. No lock, IRQ/rank, owner,
readiness, pool, process/wait status, model action/property or public loader
signature changes. Neither loader nor this utility body is in the existing
model function map, so no restamp or protocol semantic change is needed.

The existing linux_user/byte_slice fixture calls the actual maintained utility.
Two independently initialized arrays and slice_eq supply an equality oracle;
all 4096 positions cross all 255 nonzero byte values (1,044,480 mutations).
It also checks zero/empty input, excluded/included prefix/suffix mutations at
every position, and all 4097 zero prefix/suffix boundaries. This is pure native
equivalence coverage, not a hardware/cache/timing claim or a mirrored function.
The original kernel output strings and fixture ordering are unchanged.

Both actual production compiler tables include the predicate and both loader
callers, with no zero-reference global. Existing classification removed only
the stale array row: 29 allowances become 28. The trust ledger records code
removed, not new typed storage. No classifier/fixture exemption is added.

## Actual linked-image and object measurements

Baseline is published cd08c3e89ee76e3936faec857f56439bc22967fb, from its frozen
kernel-green-cd08c3e8 archive. Both original ELFs and main objects were copied
outside the checkout and manifest-hash-verified before read-only inspection.
The adjacent JSON records exact input/output hashes and section/symbol sizes.
Both production target builds are actual, with trap sites rejected.

| Boundary | QEMU before -> after | RPi5 before -> after |
|---|---|---|
| llvm-size text (includes unwind/readonly) | 822840 -> 822736 (-104) | 4207492 -> 4207420 (-72) |
| data | 4624 -> 4616 (-8) | 5600 -> 5592 (-8) |
| BSS total | 1318912 -> 1314816 (-4096) | 1933312 -> 1929216 (-4096) |
| linked .text | 645040 -> 644912 (-128) | 688740 -> 688644 (-96) |
| linked .eh_frame | 122896 -> 122920 (+24) | 133608 -> 133632 (+24) |
| linked .got | 4488 -> 4480 (-8) | 5264 -> 5256 (-8) |
| linked .bss | 925696 -> 921600 (-4096) | 1540096 -> 1536000 (-4096) |
| usable_ram_start | 0x40210000 unchanged | 0x7e0000 unchanged |

The zero symbol is exactly 4096 bytes before and absent after. BSS end retreats
4096 bytes on each target. However, image/pool-start reservation rounding keeps
usable_ram_start unchanged: no additional usable pool page or RAM capacity is
claimed. Pool payload, metadata and lifetime workload do not change; the freed
fixed payload remains within the existing reservation boundary. Existing pool
occupancy evidence is reused only for that unchanged workload, not remeasured
as an allocation improvement. No new Linux/FreeBSD comparison is warranted.

Object loader bodies shrink from 616 to 524 and 664 to 568 bytes on QEMU;
RPi5 shrinks from 632 to 540 and 656 to 568. The new predicate is 64/76 bytes.
Their sums change by -124/-104, while linked .text changes by -128/-96; the
remaining -4/+8 bytes are section/link alignment padding, not extra source
logic. RPi5's predicate has 12 extra bytes of emitted loop padding. Existing
object code/data/readonly/BSS sections otherwise remain byte-identical except
the deleted zero-array section; unwind and the affected relocation/symbol/
string tables change. The removed global reference accompanies the single
8-byte GOT reduction. The +24-byte FDE accounts for llvm-size text being
24 bytes above the linked .text delta; readonly sections are unchanged.

Both loader frames remain 224/240 bytes. The new predicate reserves 16 bytes,
so its direct loader-call edges use 240/256 bytes. This is a static stack cost
at those edges, not a measurement of whole-kernel maximum stack consumption.
The helper adds a call/return and early-exit scalar traversal while removing
the reference-byte stream and old equality loops. Static image/instruction
facts and QEMU do not measure physical cycles, coherence or trace-on/off cost;
coordinator-owned physical/publication validation remains separate.

## Assessment and next trigger

Adopt the small measured improvement: remove a mutable global and its zero
invariant, reduce fixed BSS by 4096 bytes and shrink the linked images, while
accepting the explicit 16-byte predicate frame at its new call edges. There
is no page-capacity gain at current rounding. This completed unit is a measured
milestone, not an incremental reuse label. Re-measure when byte scanning,
loader comparison/copy behavior, stack call structure, pool start or retained
allocation/lifetime workload changes, or at the next completed kernel feature.
