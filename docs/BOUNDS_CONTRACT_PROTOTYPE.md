# Bounded shared order contracts

The compiler's bounded prototype uses one order graph for runtime scalar
preconditions, dynamic Region extents and Region-independent slice lengths.
It is exercised by `test/test_takibi.ml`'s `runtime-bounds` group and
`linux_user/runtime_bounds/`. It changes no production allocator and adds no
physical-span mint, ownership model, runtime refinement syntax or solver.

## Representation and proof boundary

A node names a resolved local binding plus a facet (numeric value, slice
length or Region count), or an existing normalized numeric static term.
Names alone are not identities: a shadowing declaration has a different
binding ID. Edges mean `<` or `<=`; equality is two non-strict edges. Reachable
paths compose, and strictness is the disjunction of their edge strictness.
A wholly non-strict path cannot justify an element index at the endpoint.
The graph performs no runtime arithmetic, interval widening or loop induction.

`where` assumptions enter a function body in its own rigid static scope.
At a call, instantiated singleton parameters and Region counts connect to
actual local values/extents. Static identities are normalized by the existing
static machinery, including the opaque tail-count expression `n-k`; a
relation is not inferred by subtracting runtime integers. Constant/interval
checks retain their previous implementation and diagnostics.

Branch graphs are scoped, and a recognized false comparison follows an
always-returning true branch. Statement traversal kills runtime links before
reassignment or shadowing. Nested scopes restore their incoming graph; the
parent traversal first discards links that the nested body may change, so
restoration cannot resurrect a changed value's proof. Whole-branch write
scans are intentionally conservative. A late write within a guarded branch
may prevent proof of an earlier access.

An address taken anywhere in the function makes the corresponding binding
ineligible for runtime order evidence. This covers pointers retained before
a guard or passed through another call; no callee purity assumption is made.
Taking an element's address does not export the slice descriptor itself.
The source checker and backend endpoint evidence share the scan.
For loops connect the resolved counter to the upper-bound expression in the
same graph, including immutable local aliases of slice lengths. Mutable
global descriptors are excluded. Index evidence is keyed by the instantiated
function identity and source location, keeping overloads and generic bodies
separate.
Only actual slice `.len` and compiler-declared Region counts are extents;
a user struct or a similarly named accessor cannot mint those facts.

The source checker records successful slice-index evidence. LLVM load,
indexed-store and indexed-address lowering consume it, retaining the trap
when it is absent. The executable fixture is built with `--forbid-trap`.
Assertions about scalar order are erased; there is no hidden runtime witness.

The compiler trusts its existing constant/static normalization, correct
lowering of comparisons and fat slices, and the built-in Region invariant:
`region_count` agrees with the count index established by claim/split/merge.
Raw and unsafe memory mints still have their existing trust. An order graph
neither authorizes memory nor verifies initialization or concurrent progress.

## Two consumers and the stored-index adversary

The metadata fixture starts with a declared array, performs a checked dynamic
split, and borrows the resulting extent. `bounds_meta_read` and
`bounds_meta_write` each carry one `where k < n` signature. The caller checks
`index < region_count(meta)` once and forwards the fact across those calls.
The tail also exercises a non-atomic normalized count. Count equality takes
the explicit refusal path, with no remaining trap.

The slice fixture writes and reads `data[index]` after
`prefix.len <= data.len && index < prefix.len`. It has no Region dependency.
Independent negatives retain the check for equality at the endpoint, a
missing relation, disjunction, changed/shadowed values, descriptor replacement
and mutable aliases. Bounds facts do not keep a released Region loan alive.

For storage, `bounds_park` puts an existing `RegionSlot` into `Place` and
`bounds_finish` reads its record and returns it to its own table. The slot's
brand survives the payload and both calls. Two tables with equal capacity
still have different address identities; finishing a saved slot against the
other table is rejected. No order fact is used to unify those identities.
A stored plain index with only a generation brand is independently rejected
at a bounded numeric consumer. Private construction or an erased capacity
name alone does not prove its index is below that capacity.

This is a composition result, not a claim that a precondition becomes a
returned predicate. For an arbitrary naked stored integer, a producer's local
inequality still does not automatically survive existential packaging and
return. The cheap supported storage route is an existing slot authority;
proving predicates for general numeric owner fields would require a separate
signature/type decision. The prototype does not replace the current freelist
owner with a slot, and does not remove its trusted access by assertion.

## Current allocator boundary and migration sketch

Re-derived from maintained sources, rather than the old fixed-RAM premise:

| Item | Current form |
| --- | --- |
| Bootstrap capacity | `BOOTSTRAP_PAGE_COUNT = 2048` |
| Runtime capacity | Sum of aligned normalized FDT regions |
| Page metadata | `PageMeta`, 24 bytes/page |
| Metadata accessor | `page_meta_at_index`, raw pointer plus plain index |
| Accessor call sites | 20 in `kernel/mm/page.tkb` |
| Existing freelist owner | `FreelistOwner[allocation]`, plain `usize` index |
| Existing freelist return | `freelist_core_remove`, unsafe indexed write |

Use a borrowed live metadata extent whose count is tied to its own storage,
with an accessor signature like the fixture's Region signature. Keep the
metadata extent independent from the authority of each allocated payload
page. Do not invent a second page ownership model or a capacity-only brand.
A's array/place work decides how the long-lived extent authority is stored;
this prototype requires no change to that interface.

Most raw metadata consumers are guarded free-head/owner lookups, capacity
walks, or bootstrap-to-runtime reconstruction. Arithmetic guards can feed the
common contract. A bound-checked integer arriving without its pool authority
must not be accepted merely because another pool has the same capacity.
Stale generations, double-free outcomes and payload lifetime retain their
separate ownership/validation rules.

The real bootstrap-to-runtime replacement needs a distinct live view or a
consumed prior authority. `page_allocator_apply_memory` currently publishes
`runtime_applied` and the raw bases/counts before its initialization walks;
that ordering is not evidence that every metadata byte is initialized. Mint
an initialized runtime view only at the successful construction boundary and
end all prior loans before replacement. Bounds alone cannot certify that
phase. No publication or initialization ordering is changed here.

A future reviewed physical-span mint must justify all of these:

- Element count and `count * sizeof(PageMeta)` do not overflow.
- Backing bytes contain the complete extent and begin at valid alignment.
- Metadata and extent records fit the selected page-aligned reserved span;
  address additions and round-up do not overflow.
- The reservation is disjoint from the live DTB, bootstrap payload pages and
  every other authority for the same storage.
- The represented count and initialized lifetime agree with the returned
  authority; replacement invalidates the old view.

The existing construction checks multiplication, addition, page round-up and
reservation candidates, and excludes DTB/occupied bootstrap overlaps. A mint
must audit their composition, rather than trusting a numeric count alone.
No new raw-span constructor is authorized or implemented by this prototype.

## Annotation and representation costs

The fixture changes no data layout: singleton/statics/relations are erased.
A bounded Region accessor needs one index singleton and one precondition in
its signature; ordinary calls need no ghost argument or handwritten loop
invariant. A caller's actual guard supplies the fact. `region_count` remains
a plain `usize` API, with its trusted built-in extent identity recognized by
the compiler, rather than a user-program assertion.

The metadata fixture's record is three `usize` words, matching the real
24-byte metadata size while avoiding production-field dependencies. A Region
is its existing address/count pair; a RegionSlot is its existing address.
A Place of a slot adds the existing variant tag. The contract mechanism adds zero
per-page metadata, allocations, locks, pins or runtime relation storage.
The executable fixture owns its explicitly declared static arrays.
A prospective allocator descriptor/storage redesign still needs its own
measurement; erasure here does not establish that migration's total cost.

The native executable reports these checked AMD64 layouts:

| Representation | Bytes |
| --- | ---: |
| Metadata record | 24 |
| Region address/count pair | 16 |
| RegionSlot address | 8 |
| Place of that RegionSlot | 16 |

The same complete native fixture also compiles to an AArch64 cortex-a53
object with `--regions --forbid-trap`, in addition to focused compiler tests. Layout is not a measurement of a new
physical-span mint or a migrated allocator.

## Before/after compiler evidence

Twelve independent command-line probes were reproduced against baseline
`132a74ec` and the prototype for AArch64 cortex-a53 with
`--regions --forbid-trap`. Each rejection independently requires a nonzero
exit status and its expected diagnostic, rather than a failed output search.
The sources can be reconstructed from the maintained tests/fixture; local
commands and full logs are in `.git/takibi-diagnostics/734/results.json`.

| Probe | Baseline | Prototype |
| --- | --- | --- |
| Constant (8, 3) | Accepted | Accepted |
| Constant endpoint (8, 8) | False constraint | False constraint |
| Constant refined index | Accepted | Accepted |
| Guarded scalar call | Unproved constraint | Accepted |
| Precondition forwarding | Unproved constraint | Accepted |
| Missing scalar guard | Unproved constraint | Unproved constraint |
| Correlated slice load/store | Bounds traps remain | Accepted |
| Guarded dynamic Region access | Unproved constraint | Accepted |
| Replaced slice | Bounds trap remains | Bounds trap remains |
| Descriptor alias retained before guard | Incorrectly accepted | Bounds trap remains |
| Shadowed loop counter | Incorrectly accepted | Bounds trap remains |
| Nominal stored index alone | Unproved constraint | Unproved constraint |

The in-process tests additionally inspect LLVM trap calls, reversed/nested
comparisons, disjunction, reassignment, shadowing, loop scope, early-return
continuations, a false branch, loop/subslice aliases, fake extents, released
loans and wrong-pool storage. This is deterministic compiler evidence, not
hardware concurrency or a protocol proof.

The production linked-image comparison and the executable's separate storage
boundaries are in `docs/BOUNDS_CONTRACT_SPACE_2026-10-10.md`. Both production
kernels have zero text/data/BSS or reservation delta.

## Defect follow-up

A previously retained descriptor pointer escaped before an `if` guard. The
old backend only searched the branch for address-taking/rebinding and removed
the load check even after a helper shortened the descriptor to zero length.
Existing direct-guard and in-branch-rebinding tests missed the pre-existing
alias. A new in-process LLVM regression required one trap and observed zero
before the repair. Companion tests cover a loop and an early-return subslice
endpoint; all require the necessary check after repair.

Prevention is inferred by the checker and shared scan, with no caller
annotation or new trusted mint. With `--forbid-trap`, the unsafe program is
rejected at compilation; ordinary checked code retains its runtime guard.
No multicore protocol or bounded model is implicated. Scanning nested
index/slice bases also prevents those expression shapes hiding an escape.
The direct, correlated, loop and endpoint paths were inspected together.
A build-time textual check would miss aliases through expressions and calls;
the compiler regression is the cheaper faithful control. The existing trap
site count and LLVM inspection helpers made the missing check immediately
visible; a new debugging tool is unnecessary.

A second regression reproduced a shadowed loop counter on both the baseline
and the initial prototype: a same-named arbitrary local inherited the old
backend counter proof. For-loop evidence now uses the common resolved-binding
graph. Tests require checks for a shadowed counter and a mutable global slice;
an immutable local length alias remains provable. Existing loop tests missed
the defect because their accesses used the actual loop counter. The compiler
rule removes the name-based proof path without new annotations or trust.
