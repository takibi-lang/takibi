# Final session audit, 2026-10-05

## Evidence and scope

Reviewed the session's measurement, trace repairs, indexed-record migration,
global-context changes and FD/pool space work through cdafdd0a. The detailed
final implementation diff is f49859ad^..cdafdd0a; earlier defect premises are
retained in HISTORY.md and their issue discussions. Changes by concurrent
authors are not attributed to this session merely because they occur in that
Git interval. The final worktree was clean and matched origin/main.

The exact published cdafdd0a passed clean make allcheck, including compiler
tests, native fixtures, six model families, QEMU main/debug/fault/rollback/
race lanes, and RPi5's 68 views plus DDB recovery. The durable local log is
.git/takibi-land/allcheck-cdafdd0aa501a042bbe065864e59b9223ace4ec1.log.
Compiler-affecting pool work also passed make allbuild before its first
commit. This audit's control/documentation changes require their own final
clean publication check; the earlier pass is not a pass for a later HEAD.
Hosted CI is a separate observation and was still running when checked.

The preserved allocator, service and retention captures have strict numeric
validators and repeat observations. The equal-object allocator replay is
not an equivalent-feature OS ranking. Current packed FD payload measurements
are separate from the historical 528-byte replay workload. Retention timing
was measured before the generation repair and is historical timing evidence,
not a new timing measurement of the final implementation.

## Defects and recurrence prevention

| Finding | Root cause and why earlier coverage missed it | Cheapest faithful evidence / prevention | Static and model boundary |
| --- | --- | --- | --- |
| Trace opening omitted a Running holder | A scheduler reservation can precede sequence zero while the replay starts with empty reservation state. Earlier passing runs opened outside that interval; the existing replay detected the failing occurrence. | The actual opening gate rejects the captured incomplete snapshot and accepts its later core publication on every probe. Closed retry/invalid outcomes are handled; opening releases its guard after one observation. | Runtime completeness check, not a static scheduler proof. Existing models represent reservations and replay checks them; no new model or raw authority was needed. |
| CI lost the first boot marker | A variable-length trace produced 257 records in a 256-record ring. Local passing runs emitted fewer events. | Snapshot dmesg before protocol-trace; the fast source check and controls reject old order, missing, duplicate and commented canonical commands. The armed QEMU 609 lane and final aggregate passed. | Build-time exclusion of the actual shell-command ordering. Types cannot express this shell rule; the check does not parse arbitrary control flow. Increasing the ring would not remove the dependency. No protocol property changed. |
| Record writes could lack ensure evidence | A bool ensure followed by integer-only setters did not bind success to the requested backing/image/FD record. Correct call sequences hid the missing requirement. | Real maintained-source negative controls reject missing evidence, wrong indices and external minting. Native/kernel probes reject invalid slots without creating records or changing page counts; allocation rollback lanes exercise cleanup. | Existing opaque indexed evidence and erased views statically exclude those calls. Backing evidence is runtime data; image/FD evidence erases. Mint validity, pin checks and record lifetime under ownership remain trusted. Existing model actions were reviewed and restamped, not strengthened into a lifetime proof. |
| Old pool handle revived after same-address regrowth | Chunk growth zeroed slot generations. Tests covered reuse within a chunk, not page release and reacquisition at the identical address. | Native fixture regrows one exclusive page four times; old take and pin fail, current identity works. Adapted old compiler accepts the old handle. Private near-limit injection checks Full, the final stamp, retire/free and permanent exhaustion after regrowth. | A guarded durable 46-bit counter prevents repetition dynamically. Counter arithmetic and page minting remain compiler trusted code. This sequential identity bug needs no multicore model. |
| Retired ownership could be republished; pool state could be rewound | Ordinary Slot returned by retire/last-unpin permitted republication; whole-value pool copying could reset a durable counter. Earlier ordinary ownership tests did not distinguish release-only ownership. | Existing indexed linear RegionReleaseSlot prevents element access and give, including after adoption. Actual retire/last-unpin and pool copy/replacement rejection cases are in compiler tests. | Statically excluded using existing linear/private/no_copy mechanisms. No new raw-pointer escape or per-call ghost annotation. Internal release-state transitions remain trusted and are executed in native coverage. |

The resource-documentation drift came from updating the shared generation
budget paragraph without revisiting older row-level absolute claims, and
from leaving the pre-evidence image-write description intact. Numeric tests
check allocator behavior, not English prose; a broad prose-matching lint
would not establish consistency. The cheapest faithful correction is to
review the affected resource rows against the allocation/ensure signatures,
retain exact API names, and avoid an absolute claim stronger than their
contract. Existing result handling and numeric controls protect executable
behavior; this audit supplies the missing documentation review.

The filesystem and per-CPU image contexts additionally remove split flag/value
representations with closed states. Common probes cover unconfigured refusal,
configured file access, selected root zero and clear. They do not prove
write-once setup, CPU storage separation, non-migration or preemption safety.
Those remain explicitly documented execution/lifetime assumptions. The
CPU-local authority design already has an issue; do not duplicate it.

## Boundary and similar-shape review

All eight production RegionPools, the private pin-sharing pool and native
replay consume the corrected builtin template. Allocation callers handle
Exhausted without treating it as a reason to grow. TCP cleanup still accepts
an ordinary fresh slot on initialization failure and a release-only slot on
retirement. Adoption does not turn release-only ownership back into access.
The compiler instance expansion, overload registration, SPEC.md result types
and maintained consumers agree; allbuild covers the historical callers too.

Permanent region_table has no chunk teardown but still increments a per-slot
usize generation without an exhaustion contract. The intrusive process pool
has a durable pool-wide counter but an unchecked increment; zero means free.
Neither has the repaired chunk-reset shape, but their finite-counter limits
need distinct API decisions and injected boundary tests. They were recorded
as separate follow-up issues after checking existing general arithmetic and
region discussions. Reaching these 64-bit limits naturally is impractical;
that is not a proof of safe wrap behavior. No new behavior was implemented
without settling the release/allocation failure contract.

The space-review gate binds the checkpoint to production source blobs and
requires tracked nonempty evidence. The audit adds a missing negative case
for using the checkpoint itself as evidence: it must be refused even when
that file is tracked. There are now 25 refusal cases. No implementation
change was needed because validation already rejected it. The source scope
is explicit: root Makefile, lib/bin compiler sources, and kernel .tkb/.c/.h/
.S/.ld files excluding benchmarks. Documentation and scripts are outside
that fingerprint; it is not an exhaustive toolchain or workload fingerprint.
The gate cannot verify honest milestone classification, workload selection
or measurement truth. Existing numeric validators cover narrower claims.

## Documentation consistency and space conclusions

SPEC.md, RESOURCE_LIMITS.md and REGION_POOL_GENERATIONS.md agree on a
24-byte pool body, nonwrapping pool-wide generation budget, release-only
retirement and no_copy. Earlier dated reports retain their measured 16-byte
baseline and identify their boundary. HISTORY.md describes past behavior;
those historical numbers must not be mechanically replaced by current ones.
The audit corrected older RESOURCE_LIMITS.md/README.md claims that pages
were the only possible refusal, and the outdated image-record description
that allowed dropped writes. Resource rows now include lifetime budgets,
RetxEntry names its current builtin pool, and image writes require evidence.
Current production endpoint evidence reports 296 pool-body bytes plus 24576
chunk bytes. FD entries/blocks are 24/400 bytes, versus 32/528 earlier.

Nine FD blocks save 1152 requested payload bytes; eight pool counters add
64 bytes. The 1088-byte difference is payload-plus-pool-body accounting,
not a physical-page saving. Observed FD chunk counts stay unchanged. The
standard RPi5 image reservation grows 32768 bytes at an alignment boundary;
QEMU image reservation stays unchanged. No image ceiling was raised.
Accordingly no whole-kernel RAM reduction or superiority over Linux/FreeBSD
is claimed. Endpoints do not establish global peaks, simultaneous snapshots,
network concurrency performance or every future service workload.

## Useful debugging mechanisms

Saved raw UART, sequence-zero replay diagnostics and retained record counts
already supplied independent witnesses for the trace failures. Guarded pool
space TSVs, preserved malformed-capture controls, compiler layout probes and
linked ELF comparisons supply the needed identity/accounting observations.
The same-page native regression and near-limit injection avoid probabilistic
page reuse and trillions of allocations. The milestone checkpoint makes
measurement review visible at publication. A general new debugger or a
shadow allocator model would duplicate this evidence and is not justified
by these defects. Existing host-side EL0 symbolization and churn stall-dump
issues already cover their larger debugging needs.

## Disposition

- Fixed and verified: trace-opening and retained-log repairs, indexed record
  write boundaries, context state migrations, FD packing, nonrepeating
  RegionPool lifetime/release-only ownership, numeric measurement checks and
  recurring milestone review. The added self-evidence refusal control is
  completed in this audit unit.
- Remaining: the global-context review and broader region/authority work
  remain open; permanent-table and intrusive-pool finite-counter contracts
  have separate deferred issues. Hosted CI must be reported with its actual
  conclusion. None is silently declared complete by closing the space issue.
- Deferred by YAGNI: exhaustive packing, per-CPU fronts, allocator rewrites,
  generic proof infrastructure and additional OS measurements. Future
  feature/stage measurements determine whether a concrete change is useful.

ROADMAP.md keeps current queues, not this audit log. Closed issue references
were checked against GitHub and none remained in the roadmap at this audit.
Only the two specific finite-counter follow-ups are added to its deferred
band; the recurring space policy was already present. Stop after publishing
this audit unit rather than starting any next implementation issue.
