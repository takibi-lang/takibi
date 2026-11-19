# Scoped memory-safety contract inventory

This is a property and premise inventory, not a soundness theorem or a
Rust-equivalence claim. Source baseline: 7749c2a0 (2026-11-17), containing the
7a3c452c initialization integration. SPEC.md is normative. Historical pilot
results in MEMORY_LINK_PILOT.md and MEMORY_CROSS_STRUCTURE_PILOT.md describe
experiments at their stated revisions, not today's acceptance verdicts.

## Claim boundary

There are two distinct questions: what every accepted program in a safe
language subset guarantees, and what the maintained kernel guarantees under
its enforced build policy and audited interfaces. A green kernel build does
not answer the first. The present inventory establishes neither blanket
claim; unresolved rows below are obligations, not exemptions.

The initial analysis envelope is typed Takibi with checked indexing,
initialization contracts, supported direct-call provenance, affine/linear
owners and checked guards. It excludes executing a raw dereference or an
unsafe assertion as a *safe operation*. Calling an abstraction implemented
with unsafe still depends on that abstraction's stated preconditions and
implementation. An absence of an unsafe effect in a caller alone does not
prove that its inputs, allocator or external environment are valid.

Configurations examined here are the maintained AArch64 QEMU and RPi5 main
source sets and AMD64 compiler controls, using the default trap rejection.
The kernel additionally enforces raw-authority confinement, execution-model
and source/build policies from the root Makefile. This document introduces
no new accepted programs, exclusion flag, trust allowance or runtime fallback.
The final supported subset and any narrowing of the target claim require a
maintainer decision after the inventory has been exercised.

An object is inline local/global storage or an allocation supplied by an
allocator contract. A range is a half-open byte interval within that object.
An index or numeric address does not by itself establish allocation identity,
permission, lifetime or freshness. Alignment and valid typed representation
are independent of initialized-byte coverage. Typed record reads require
fields; byte disclosure also requires padding. An initialized pointer value
does not establish initialized or valid pointee storage.

Aliases name the same object or overlapping ranges; distinct parameter names,
selector spellings or lifetime indices alone do not establish separation.
A permission is the access an owner/guard/view contract grants, conditional
on a valid mint. Storage reuse begins a new ownership interval: retained
numeric addresses are not automatically permissions for the new interval.
Other cores and devices can access storage only under the relevant protocol
premises; an arithmetic proof cannot establish their ordering or completion.
Leaks, fairness, deadlock and functional correctness are separate properties,
except where safe reclamation explicitly needs progress or quiescence.

## Finite initial obligation matrix

Each bad shape is an obligation to reject or to place behind an explicit,
reviewed trust boundary. A mechanism column is not a claim of complete
coverage. Existing source tests are in test/test_takibi.ml unless named.

| Property and bad shape | Current enforcement / positive control | Remaining premise or missing evidence | Owner |
| --- | --- | --- | --- |
| Bounds: read element N from an N-element object | Refined intervals, checked indexing and default trap rejection; narrowed in-range indexing generates code | Layout, lowering and external slice length/address truth; solver checks extracted arithmetic only | #637, #954, #986 |
| Initialization: read an unwritten scalar/array element | Init_flow leaves and intervals; `local array: an unwritten element rejects` versus complete counted fill | Raw writes/assume_init and external outputs are audited; export coverage below is incomplete | #203, #954 |
| Padding: publish init after only field stores, then view bytes | Whole init checks padding; init_fields permits typed fields only; `whole init rejects unwritten padding` versus zero-filled producer | Extraction/transfer rules and layout remain compiler trust; mutable aggregate calls discard old padding | #203, #986 |
| Selected storage: fill slot A, consume slot B; release and reacquire | Selector/authority-sensitive facts; `slot facts: different live owners stay distinct`, same-owner and explicit refill controls | Token mint uniqueness/exclusivity; no inference that two selectors are distinct allocations | #203, #637 |
| Representation/alignment: reinterpret arbitrary bytes as a reference or constrained value | Cast/type restrictions, zero_fill representation gate, checked typed API boundaries | Arbitrary raw/integer conversions, backend placement and FFI representation need audit; no universal provenance claim | #637, #986 |
| Aliasing/frame: modify a certified link through another parameter or global | Body-derived footprints and inferred separation; direct callers discharge separation; init-link concrete-heap oracle | Unknown aliases invalidate supported facts; general stored aliases, indirect calls and integer round trips need consumer controls | #637, #954, #132 |
| Lifetime: free/move authority while a derived view remains usable | Owner/guard-derived views, held spans and body-checked borrows summaries; real exec-metadata result/copy/match/release/reuse controls | Legacy @ contracts retain their separately reviewed boundary; general heap provenance, reclamation and physical owner/storage correspondence remain premises | #637, #132, #1159 |
| Reuse/freshness: old view reaches a removed/reinserted slot | Linear consumption and generation-indexed API rules | Allocator freshness, failed/partial construction, teardown and shared backing require real-consumer coverage | #637, #638, #132 |
| Concurrency: use wrong guard or expose guarded payload through bytes | guarded_by identity, no_copy and typed bulk gates; matching-guard access | Physical mutual exclusion, guard mints, interrupt/preemption transitions, publication/reclamation and raw paths remain distinct obligations | #638, #1159, #986 |
| Devices: CPU reads before DMA completion or reuses an in-flight buffer | Typed device/protocol owners and cache/DMA APIs; bounded models and selected instruction ties | Physical coherence, actual completion, hardware ordering and storage lifetime; QEMU is not hardware evidence | #637, #986 |
| Independent checking: feed a wrong place/transfer fact to Z3 | Arithmetic/finite coverage re-check plus planted-fault controls; concrete heap oracle for Init_link | Z3 does not reconstruct execution or validate arbitrary extractor/transfer rules; LLVM/assembly correctness is trusted | #986, #954, #955 |

Bounded protocol checks are evidence only at their stated bounds and code
ties (kernel/models/README.md). The matrix does not promote a modeled
protocol to global race freedom. The [scoped Rust 1.91.0
comparison](RUST_MEMORY_SAFETY_COMPARISON.md) records property-level
evidence and unresolved boundaries. Whole-language equivalence remains
unresolved.

## Original initialization acceptance re-audit

On the source baseline above, `make build` succeeded and the unchanged
`init-contracts` group passed all 111 cases. The exact first Takibi code
blocks from the #1511 and #1512 issue bodies were compiled as independent
AMD64 files, with `--external-entry main` (and `--external-entry leak` for
the padding example). No generated control was executed.

| Control | Compiler exit / object | Specific verdict |
| --- | --- | --- |
| Original #1511 padded record producer | 1 / absent | ensures needs p initialized, including padding |
| Same producer with zero_fill(p) before field writes | 0 / present | Byte-view consumer generates code |
| Original #1512 two live distinct slots | 1 / absent | peek requires storage[v1.index].buf initialized |
| Same source with peek(a) | 0 / present | Same-slot helper chain generates code |
| Same source with fill(b) before peek(b) | 0 / present | Disjoint-slot use generates code after initialization |
| Real syscall probe: release initialized slot, acquire fresh, format fresh | 1 / absent, both targets | syscall_exec_format requires syscall_scratch[v2.index].file_buffer initialized |
| Same real mutation, zero-fill fresh.file_buffer before formatting | 0 / present, both targets | Complete source sets generate objects and solver obligations |

The real mutation changes only kernel_syscall_filesystem_unconfigured_probe:
keep the original fill, release slot, acquire fresh, call
syscall_exec_format(fresh, 0), then release fresh. It was compiled in an
isolated source snapshot using the exact main-object command lines expanded
by `make -n -W kernel/kernel/syscall.tkb kernel/build/qemu/main.o
kernel/build/rpi5/main.o`; only output/facts paths and compiler location
changed. Both negative commands independently returned nonzero and the
initialization diagnostic. Both positive emitted obligation sets passed
scripts/buildcheck_range_obligations.py: cold initialization solver time
3.39 s QEMU and 3.99 s RPi5, within the unchanged 5.0 s ceiling. These are
compilation and arithmetic/coverage results, not kernel execution evidence.

Maintained controls additionally cover conditional output success/failure,
record-array prefixes, typed copies/stores, mutable-call padding loss,
whole-byte restoration and readonly preservation. The existing planted
padding fault in scripts/buildcheck_range_obligations.py requires a SAT
counterexample under the internal fault flag. Slot controls test extraction
by comparing distinct selectors, consumption, selector mutation and branches;
the solver alone cannot detect a collapsed selector supplied as a premise.

The historical procfs_put_usize omitted-digit-store mutation was also
re-run on both complete target source sets. Both now reject at digits[at]
with the uninitialized-read diagnostic. The historical accepted result in
MEMORY_CROSS_STRUCTURE_PILOT.md therefore does not describe current behavior.
The current local-array regression group covers omitted and sparse stores
and a complete counted fill; SPEC.md now includes uninitialized local
arrays in its tracked-place inventory.

No new production annotation, runtime store, unsafe site or storage was
needed for this re-audit. Slot mint uniqueness and raw-memory assumptions
remain named trust, rather than being discharged by these controls.

## User-visible byte paths: initial coverage inventory

The initial source audit found nine direct copy-out call sites in
kernel/kernel/syscall.tkb, plus the forwarding call inside
kernel/mm/user_memory.tkb. There is no maintained copy_to_user_raw symbol.
This is a source-backed entry inventory, not complete export certification.

| Boundary / consumers | Current check | Remaining audit |
| --- | --- | --- |
| copy_to_user | borrow init []const u8; length check, COW resolution, UserAccessWindow | Source construction/provenance and actual source lifetime; destination mapping/assembly are trusted |
| copy_to_user_span | borrow uninit source with requires init(source[offset..<offset + length]); checked tail forwards to copy_to_user | Every producer's range fact and alias/lease identity |
| Pipe reads (two wrap segments) | copy_to_user_span from pipe_of(owner).buffer | Stored-owner lifetime and written ring ranges across wrap/reuse |
| TCP reads (buffered and freshly received) | copy_to_user_span from tcp_frame_bytes | Frame ownership, received extent, publication and DMA completion |
| procfs rendering, ext2 file reads, getrandom | copy_to_user_span from the selected syscall scratch file_buffer | Producer prefix, cursor/count transfer, partial/failure paths and reacquisition |
| prlimit64 | copy_to_user from constructed scratch bytes; the initial RLIMIT_NOFILE read checks both words and adjacent sentinels | Scratch source lifetime and output cases beyond the initial successful read |
| uname | copy_to_user from constructed scratch bytes; successful field tails and adjacent sentinels checked by the peer TTY fixture | Source initialization and lifetime proof across scratch reacquisition; other field values and faulting destinations |
| user_write_byte/u16/u32/u64 and user_zero_fill | Typed scalar inputs or constant zero; range/COW checks and access windows | All callers and all padding/holes of user ABI records; untouched user bytes are not kernel disclosure |
| Fresh user pages, including exec/stack and COW copies | [User page publication](PAGE_PUBLICATION.md) checks full initialization of the incoming `PageOwner` at `address_space_map_page` | Allocator and frame identity, COW source lifetime, descriptor visibility and TLB ordering |
| Retained fork/COW mappings, signal frames, shared backing | Existing-page reference or ABI paths | Reference and teardown lifetimes, and record-specific initialization |
| Raw/assembly/device output paths | Named mint files and external contracts | Audit bypasses of the typed entry set; confinement is not initialization proof |

The next consumer review starts with the selected scratch-to-procfs output
chain and its alias/lifetime transfer, followed by the ring/frame consumers.
It must also enumerate allocation-backed exports and scalar ABI writers;
closing only the nine copying call sites would weaken the required claim.

The kernel-only EL0 fixture checks successful scalar ABI output in the
existing userspace view. For statfs, both the ext2 root and procfs overwrite
a nonzero 32-byte reserved tail with zero. For sysinfo, all 104 bytes after
uptime overwrite a nonzero pattern with zero, while eight sentinel bytes on
each side of the 112-byte result are preserved. These checks cover the
observed tail and extent. They do not add any claim about uptime, other
record fields, or faulting destinations.

## Refreshed trust measurement

`make trustedbasecheck` passed on 2026-11-17. The depfile-derived inventory
reported 180 source files / 99,365 lines (RPi5 164 files, QEMU 143, EL0 test
payload 4), with 35 kernel Takibi files outside that union. It counted 115
explicit unsafe blocks / 139 enclosed lines, 454 raw-pointer casts and 108
extern function/symbol declarations. Production handwritten assembly was
34 files / 2,837 lines; generated assembly 15 / 1,125; fixture assembly
1 / 27. These syntactic counts describe review surfaces, not independent
premises or a proof strength.

The ledger report uses different scopes: its source-wide unsafe count was
178, extern functions 74, and assembly lines 2,864. Build-derived raw-site
facts were 146 QEMU / 156 RPi5 (78 / 88 after excluding probe-linked evidence
files), while the older ledger recorded 144 / 154 (76 / 86). Do not replace
one scope with another or describe the old recorded values as freshly
measured. The report alone does not establish that each new site was
individually reviewed; ledger refresh/reduction remains under #986.

No trust premise is retired or added by this document. Before making the
final scoped claim, complete each matrix row's source-backed controls,
export inventory, compiler/external trust justification, measured migration
costs and property-by-property Rust comparison. Any required new language
rule, runtime fallback or broader trust premise returns for a decision.

The scoped exec-metadata lifetime migration and its address/authority controls
are reviewed in [the measured lifetime report](EXEC_METADATA_LIFETIME_REVIEW_2026-11-17.md).
It extends the lifetime row above; it does not discharge the other rows or
turn the source-pinned initialization/export inventory into a universal proof.

Ordinary direct-helper lifetime inference and its termination, transfer and
cost controls are reviewed in [the inference report](INFERRED_REFERENCE_LIFETIMES_2026-11-17.md).
This closes the demonstrated unannotated reference-to-slice helper gap; it
does not establish general heap inference or discharge the remaining rows.
