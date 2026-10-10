# Bounded order-contract prototype space review, 2026-10-10

Workload: the completed compiler prototype, both normal linked production
kernels, and `linux_user/runtime_bounds`'s dynamic split/borrow/access and
stored-slot round trip. Baseline is main `e8a9989d`; candidate is the shared
order graph, proof consumption and conservative alias repair. Kernel source,
production storage, allocation workloads and image contents are unchanged.
This is a measured milestone, not an incremental reuse of image evidence.

## Production linked images

Command: `python3 scripts/space_delta.py e8a9989d`. The script builds both
candidate kernels and the baseline in an isolated worktree, then compares
`llvm-size-19`, every data/BSS symbol size and `usable_ram_start`.

| Boundary | QEMU baseline | QEMU candidate | RPi5 baseline | RPi5 candidate |
| --- | ---: | ---: | ---: | ---: |
| text bytes | 727664 | 727664 | 740368 | 740368 |
| data bytes | 5400 | 5400 | 2889208 | 2889208 |
| BSS bytes | 1658432 | 1658432 | 1697344 | 1697344 |
| usable_ram_start | 0x40248000 | 0x40248000 | 0x718000 | 0x718000 |

No data/BSS symbol changed size. Text/data/BSS and the image reservation
boundary each have zero delta on both targets. The local complete comparison
is `.git/takibi-diagnostics/734/space-delta-rebased.log`; the table above is the
tracked evidence. There is no hardware timing or cache-coherence claim.

This compiler change alters which programs can prove a bound, not the
production workload's lifetimes or ownership representation. The previous
payload, allocator metadata, retained-page and pool-occupancy observations
therefore remain applicable to that unchanged workload; the linked comparison
alone is not a new measurement of those live occupancy boundaries. Existing
cross-OS comparisons need no repeat because neither normalized functionality
nor the comparison boundary changes.

## Executable shape and representation

`make linuxcheck` compares the real native stdout to the maintained fixture.
The dynamic metadata split reads/writes through the same where contracts as
ordinary numeric APIs; equality at the count takes an explicit refusal path.
The correlated slice writes/reads index 3 and refuses endpoint 4. An allocated
slot is held in Place, passed across calls, read and freed back to its own
table before the table is kept. This tests the actual API operations without
requiring a new allocator or a physical-span mint.

The compiler's checked AMD64 layout reports:

| Representation | Bytes |
| --- | ---: |
| Metadata-shaped three-word record | 24 |
| Region | 16 |
| RegionSlot | 8 |
| Place of RegionSlot | 16 |

The relation and singleton/static identities themselves require zero runtime
storage or extra call arguments. No production per-page field, allocation,
lock or pin is added. This does not claim that Place is free: its existing
slot tag accounts for the difference between 8 and 16 bytes.

The standalone native fixture has text 18343 B, data 8 B and BSS 2152 B
(`llvm-size-19`). These are the whole executable and shared runtime/built-in
Region implementation, not an overhead attributed to the arithmetic rule.
Its declared metadata array is 192 B, value array 64 B and slot payload array
48 B. Existing generated Region metadata and claim flags are separate
symbols; the former are 128 B and 32 B for these two claimed arrays. Static
fixture storage is not inserted into either production kernel. The identical
complete fixture also compiles to an AArch64 cortex-a53 object with
`--regions --forbid-trap`; it is not executed as a hardware test.

## Assessment and next trigger

Keep the prototype: it removes required checks by erased evidence while
preserving necessary checks under aliases, wrong identities and expired
loans. No measured production-space optimization is needed and no safety
rule is weakened for size. `docs/BOUNDS_CONTRACT_PROTOTYPE.md` records the
annotation cost and the separate physical-span, initialization and storage
trust boundaries.

Measure again when the production allocator adopts a runtime metadata extent
or stores its authority through A's array/place rule, including the actual
bootstrap-to-runtime replacement workload. A changed arithmetic rule that
alters linked production images also triggers a new image comparison. The
current numbers do not budget the future allocator migration.
