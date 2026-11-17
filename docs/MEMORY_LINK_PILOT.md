# Source-derived linked-initialization experiment

Experiment date: 2026-11-16. This is research evidence, not shipped language
semantics or a kernel-wide memory-safety claim.

Integration checkpoint (2026-11-17): stored-address and owner-frame inference
is now in the main worktree, with source-resolved acceptance tests and deferred
native output. The normal compiler build and unit tests pass. A QEMU object
rebuild after a structural preflight optimization passes the unchanged
743,000,000-word compiler-allocation budget at 742,978,075 words. The first
allbuild attempt exceeded that budget before the optimization. Subsequent
whole-native builds exposed additional migration cases, documented below;
their arithmetic fixes and allocation improvements pass the QEMU object gate
at 742,959,122 words under the unchanged 743,000,000-word limit. The final
allbuild and native execution suite pass; clean allcheck and publication have
not yet been established. The experiments
below record their evidence at the stage when each was performed.

## Question and result

Can the shared FreelistCore add/pop operations preserve initialization safety
with runtime-selected indices, without clearing unused metadata first?

Yes, under the sequential storage/frame assumptions below. An OCaml research
checker uses Takibi's existing parser to read the actual bodies in
`kernel/lib/freelist.tkb`, builds path conditions and memory updates, and emits
SMT queries. It does not recognize source text with regular expressions.
The input SHA-256 was
`70ad38f871c33dd3e5940329758d7d4f695fa80799f3ca364b70ed2051fb348b`.

The checked property is initialized, in-range traversal, not acyclicity,
unique allocation, correct generation ownership or concurrency safety.
A certified set of initialized indices is closed under stored links; its
head is a member or the sentinel. This set need not include every physically
written cell. An empty list can certify the empty set without clearing its
unused array.

## Evidence

Capacity N and the inserted/returned index are symbolic unsigned-64-bit-range
integers. No enumeration of pool sizes, indices or initial array contents is
used. Array reads require initialized in-range elements; stores require
in-range indices. Function exits preserve the linked invariant.

| Actual bodies composed by the harness | Source paths | Solver result |
| --- | ---: | --- |
| add_index | 2 | UNSAT |
| add_index -> insert_begin -> insert_commit | 8 | UNSAT |
| init_empty | 1 | UNSAT |
| init_empty -> add_index -> insert_begin -> insert_commit | 8 | UNSAT |
| remove -> insert_begin -> insert_commit | 8 | UNSAT |

UNSAT means no violating execution in the encoded sequential semantics.
The init_empty sequence starts with no initialized array cells and does not
assume an initially valid linked invariant. The other sequences require that
invariant at entry. Additional checks fixed N to 0 and to the real bootstrap
capacity 2048; both passed. Individual queries took 0.008-0.015 seconds in
this local run, not a performance budget or scaling guarantee.

Four mutations of the actual input source produced SAT:

- omit the add_index link write;
- change the add_index bound from index < N to index <= N;
- construct Pending with index 0 instead of the head actually read;
- omit the remove link write.

Adding an unsupported real helper call failed extraction explicitly rather
than silently omitting its effects.

## Relevance to the kernel

The bootstrap path in `kernel/mm/page.tkb` uses FreelistCore with capacity
2048, making this shared core relevant to a production kernel path. The
SlotMap and RefcountSlotMap wrappers also call its insert/remove operations,
but no production kernel call sites of those wrappers were found in the
follow-up audit. RefcountSlotMap explicitly documents its native-only current
consumer. Do not count those wrappers as additional active kernel consumers.
The complete page-allocation call graph was not verified. In particular, the bootstrap
consumer's full ascending initialization and its transition to runtime page
metadata are not covered by the init_empty sequence.

## Boundaries and remaining work

- The harness composes named bodies; it does not derive the entire caller
  graph from the wrapper's match expression. begin/commit operate on the
  same storage with no intervening mutation by another execution context.
- Storage identity, exclusivity, alias/frame behavior and lifetime are
  premises. The intentionally unsafe contention-probe API is not certified.
- Small helpers for owner-index projection, pending construction, owner
  construction and generation advancement have explicit research summaries.
  Payload ownership correctness is outside this property.
- The 112-line OCaml extractor supports the exact selected statement forms
  and fails on unsupported forms. It is not a general symbolic interpreter,
  type checker or independently verified compiler.
- The solver uses quantified mathematical arrays and integers. This is NOT
  the production policy where the compiler owns structural rules and Z3
  discharges pure arithmetic obligations. Translating the structural fact
  into the approved restricted type/contract domain is unfinished.
- Zero source annotations in this experiment do not establish zero proof
  cost: the harness supplies the invariant, composition and helper summaries.
  The final user-visible annotation cost is still unmeasured.
- No runtime clearing, bitmap, extra link word or unsafe initialization
  assertion was added. These results give no present reason to add them for
  this sequential add/pop property.

The next acceptance bar is to carry this guarantee through real checked API
contracts, reject the same four defects in the compiler, and apply it at a
maintained kernel caller. Kernel-wide applicability remains unestablished.

## Structural-domain follow-up (2026-11-16)

A second OCaml experiment uses the parsed bodies with a small abstract state,
instead of asking a quantified SMT heap model to establish the relation.
Values carry an initialization certificate for one named backing array. A
link read requires that certificate and returns a value with the same array
certificate. A store of a certified successor certifies its index; an
unproved successor invalidates that array's certificates. Branches intersect
facts. Loops intersect entry and backedge facts to a fixed point, without a
written loop invariant. Unsupported control flow, helper effects, reference
aliases and shadowed bindings reject rather than silently losing effects.

The actual add_index, remove, unlink_range, init_empty and composed
insert_begin/insert_commit bodies pass. The ascending constructor also passes
a narrow symbolic rule for its exact `for i in 0..<N { links[i] = i + 1; }`
shape. That rule does not unroll N; proving its arithmetic and complete-write
footprint belongs to the arithmetic/coverage checker. It is not a general
loop synthesis rule. The existing compiler builds the actual constructor
and its emitted coverage obligations pass Z3.

A candidate growable_pool_activate_chunk body also preserves the structural
relation. The candidate removes the temporary whole-core reference and spells
the same stores as `pool.core.field`, as the partial constructor does. This
does not yet establish that its computed indices are in range. In particular,
the original function's unchecked arithmetic is not made safe by a link
initialization certificate.

Negative controls reject a missing link store, a forged pending index, an
unproved successor written during unlink, an unproved loop cursor, an
unsupported alias and an unknown effectful helper. A separately supplied
pending value certified for another storage identity rejects. The old
off-by-one add-index mutation is rejected by the production compiler's bounds
checker, independently of the structural experiment.

The storage identity supplied at each experimental API entry, exclusive
access, lifetime and small helper summaries are still harness premises.
The checker is not installed in the compiler, and the final user-visible
linked contract count is not yet measured. These results support a finite
structural domain for the real loops; they do not prove the complete calling
convention or justify treating a partially initialized record as wholly
initialized. No runtime storage or per-access proof annotation was added.

### Arithmetic integration

The maintained compiler now specializes const-generic values in `where`
clauses and feeds supported unsigned scalar entry constraints into arithmetic
flow checking. Fixed-array reads, writes and addresses can use these proofs,
including inline record arrays. Machine non-overflow is checked before
using arithmetic terms; accepted indices emit Z3 obligations. The function
instantiation is part of the proof key. Unsupported or address-exposed
values do not acquire a fact merely from a similarly named parameter.

GrowablePool activation uses `chunk: usize @ k` and `where k < MAX_CHUNKS`.
It no longer uses unchecked indexing. The existing capacity check moves to
its callers, where it supplies that input fact; no additional runtime check
is introduced. The page-acquisition helper takes the same bounded chunk and
no longer needs to repeat its bounds branch. Its result distinguishes physical
page exhaustion; the externally indexed API still reports chunk exhaustion
separately. The existing payload-size static_assert remains useful and stays.

A new capacity assertion is not required for the index proof. Specialized
sizes are concrete. The actual six-slot activation compiles without one and
its emitted Z3 checks pass. A five-slot variant rejects with the required
bound, normalized index expression and path facts. The diagnostic points to
`where` for input restrictions and to `static_assert` for explicitly checking
an intended compile-time capacity invariant. Assertions are checked, not
assumed; a false assertion cannot repair wrong constants. General nonlinear
terms remain unsupported.

Permanent compiler controls cover computed reads/writes/addresses, too-small
capacity, unrelated indices, arithmetic overflow, reassignment, singleton
address escape, instance isolation and the diagnostic's assertion guidance.
The native runtime_bounds fixture executes two generic chunk layouts and
checks their different stored sums. A fault-control compile accepts the bad
five-slot index, then Z3 independently reports a counterexample; this control
is part of the existing solver runner, not a new lane. Index counterexamples
no longer request the coverage-only witness `k` that those queries lack.

### Non-link API integration

Eight metadata/shadow APIs use eleven field preconditions in total, with no
body proof statements or handwritten loop invariants. The native test's
`ensure_ok` adapter uses three corresponding preconditions. The constructor
still has its seven field postconditions; its link array remains uninitialized.

A limited native execution compiles the actual library API bodies with the
unrelated legacy self-directed probe omitted from the experimental input.
It checks initial zero occupancy, lazy growth to two chunks, zero-on-grow
payload behavior, preservation of an earlier write, idempotent ensure and
index-at-capacity rejection. Emitted Z3 obligations pass. Omitting a metadata
initialization store rejects the constructor postcondition. The existing raw
payload-address provenance and caller liveness requirements remain trusted;
this experiment is not a proof of raw-pointer lifetime or of the entire pool.

At that stage, the full native fixture rejected five initialization diagnostics, all
at self-directed insertion calls (including its legacy library probe).
No target or production probe was removed to make it pass. The compiler
integration below supersedes that diagnostic count.

### Approved contract strength

The first linked prototype admits only N as a terminal value. Existing
FreelistCore insert treats any head >= N as Empty: a fully initialized core
of capacity four with head five compiles, passes emitted checks and executes
the Empty branch. This is memory-safe existing behavior, not a demonstrated
list-corruption read.

The approved initialization-only contract will certify that following an
in-range index reads initialized storage, with the independent bounds checker
still required before every actual access. A completely initialized array
will then satisfy the initialization requirement without additional
successor-value annotations. A stronger exact-N contract would also enforce
link-value well-formedness and would need corresponding API premises.
The maintainer approved separating initialization from bounds. Production
integration remains unfinished; no new runtime check has been introduced.
The exact-N results above describe the historical prototype, not the approved
contract: terminal values outside the array do not authorize an array read.


The structural follow-up now treats full initialization as sufficient for an
arbitrary successor value, rather than only the literal zero head. The actual
add/remove/unlink bodies pass with a fully initialized array and no initial
head certificate. Partial storage still rejects an unrelated index and a
foreign-storage pending certificate. All six recorded mutation controls
continue to reject, checking both nonzero exit and the expected diagnostic.
This remains a research harness: production transfer across aliased places
and API boundaries is not implemented by this experiment.

## Compiler transfer component

`lib/init_link.ml` implements erased per-storage traversal certificates for
integration into initialization flow. Its transfer rules cover scalar copies,
loads of certified successors, stores of certified or unknown successors,
branch intersection and storage/root invalidation. Bounds and proof of a
terminal value are deliberately external to this component. Storage identities
must come from resolved bindings, not source-name matching.

An independent concrete-heap oracle enumerates all 512 initialization/link
states for capacity three and all 6,144 single stores, checking every retained
certificate against actual initialized traversal. It also checks successor
loads. Separate controls reject cross-storage transfer and retention through
an invalidating branch or unknown alias mutation. These are finite tests of
the transfer component, not a proof for all capacities.

The component is connected to `Init_flow` at unconditional `init_links`
entry, exit and call boundaries. Empty constructors transfer a checked
constant terminal head without clearing the array. Positive and negative
compiler tests exercise constructor calls, foreign storage, noncanonical
terminal values, full arrays and refusal to read unwritten array elements.
Typed successor loads and stores use same-storage certificates while array
bounds remain independently checked. Loops intersect entry certificates with
backedge certificates to a fixed point. Compiler controls accept push/pop
and a bounded cursor walk, reject an omitted node store or unrelated
successor, and reject a cursor whose certificate is lost on a backedge.
Calls use checked body-derived write footprints before applying declared
postconditions. Unknown footprints discard linked certificates. Inline fields
and recoverable aliases are described below; distinct reference parameters
and value-only call signatures do not by themselves prove a frame property.

A review control checks that assigning `cursor = cursor + 1` does not evaluate
the increment again in the post-state and falsely certify an in-range,
uninitialized node as a terminal value. Terminal recognition currently uses
source-constant expressions only; copied scalar certificates remain supported.

A second rejection control clears only part of an array: replacing a
certified successor with zero can redirect traversal to an unwritten node.
Bulk writes therefore invalidate the relation before ordinary initialization
facts are applied. A separate address-erasure control rejects viewing a
partially initialized record as raw memory. That rejection comes from the
ordinary initialization check, not from a demonstrated alias-analysis rule.
An isolated compiler copy with the terminal-expression restriction and
zero-fill invalidation removed fails exactly the two corresponding rejection
tests: both invalid programs are accepted. The linked group runs 21 tests;
the unmodified compiler passes the full unit suite. These mutation controls
exercise compiler acceptance, not execution or an all-capacity proof.

### Maintained pool application

FreelistCore's empty constructor, add, remove and ordinary insert APIs now
carry the linked contract. Ordinary insertion reads the head, pops the node
and updates the generation within one borrow. The separate begin/commit
operations remain for contention probes with fully initialized input. Native
freelist_pool, freelist_generic, slotmap and refcount_slotmap fixtures build
and execute successfully. The unlink-range API still requires full
initialization. No runtime initialization flag or blanket clear was added.

The next GrowablePool migration currently rejects 26 linked-certificate
diagnostics. Its raw payload writes, unresolved address arguments to UART
helpers, and allocation boundaries conservatively invalidate certificates.
The checker does not yet establish that these writes are disjoint from link
storage. Relaxing invalidation without that evidence would weaken the
guarantee. The remaining investigation is to tie write destinations to
existing ownership and borrow information, with unknown raw/extern effects
remaining conservative. Whole-pool integration is not complete.

Keeping link helper setup lazy and grouping cold flow state avoids imposing
its allocation cost on every ordinary function. The measured QEMU main.o
compile allocates 742,952,531 words against the unchanged 743,000,000-word
budget. Its cold initialization-obligation Z3 recheck takes 3.39 seconds
against a 5-second budget. These are measurements of this experimental tree,
not completion evidence for all maintained targets.

### Body-derived write inference: first application

The maintainer approved trying function bodies and existing contracts and
ownership information before adding write-footprint annotations. The first
compiler component, `Init_writes`, proves only an empty external write
footprint. It follows resolved call targets, permits local scalar updates,
and treats unknown callees, recursive edges and non-local stores as unproved.
The result preserves linked certificates across read-only helpers even when
their parameter is a mutable reference. It does not trust an effect
declaration as evidence of no writes and adds no runtime state.

Compiler controls cover a helper with a local counting loop, transitive
read-only calls, direct and transitive writes, and an opaque extern boundary.
The full compiler unit suite passes. Applying this first summary to the
maintained GrowablePool fixture leaves all 26 linked-certificate diagnostics:
empty write footprints alone do not distinguish payload writes from metadata
writes. The next work is destination/region-sensitive inference, including
the indexed page view returned by page_bytes and the raw payload accessor.
Neither the remaining diagnostics nor a failed empty-footprint inference
establish that static checking is impossible. No unresolved raw write has
been treated as disjoint merely to make the fixture pass.

The first implementation ran inference only when the earlier call rule would
lose a certificate. Eagerly trying it for every call raised allocation to
743,774,446 words; restricting it to those actual losses brings it to
742,970,800 words under the unchanged 743,000,000-word ceiling. The QEMU
initialization Z3 recheck still passes. This limits the overhead of the
first summary. The alias audit below supersedes that optimization and rule.

### Parameter-relative field writes

The next summary records inline field paths relative to reference parameters
and composes those paths through direct calls. Writes to a separate metadata
field can therefore preserve a link certificate for the same record. A write
to the head forgets that scalar's certificate; a write to the link array
invalidates all certificates depending on that array. Copies of the old head
remain certified when the backing array is unchanged. Parent-field writes
invalidate descendants, and an array-element write covers the whole array.

Immutable aliases such as `let alias = &p.count` retain their recovered
destination, including when the inferred local type is a pointer. This is
not a general raw-address disjointness rule: pointer arithmetic, pointer
field loads, mutable aliases and unresolved calls remain unknown. Named
global writes were added in the later step below.
Taking the address of a local reference slot is not treated as taking the
address of its referent. Existing initialization checks still reject aliasing
a whole partially initialized record as if the whole record were initialized.

Compiler controls exercise unrelated metadata writes, nested helper calls,
head and array mutations, branch unions, immutable field aliases and mutable
alias rebinding. The certificate-domain test separately distinguishes an
overwritten head from an unchanged scalar copy and a changed link array.
GrowablePool still has 26 diagnostics: these field summaries do not yet
separate page-owner-derived payload regions or opaque external effects.
In particular, linux_write has a three-instruction assembly adapter, not a
Takibi body; an empty write set cannot be inferred merely from its name or
return type. No external frame contract has been added or assumed.

### Alias audit of frame preservation

Two compiler controls demonstrated invalid preservation in the earlier
experimental transfer rules. A function could keep p's linked contract while
writing q.head, even when its caller passed the same object for p and q.
A no-argument helper could overwrite a shared scratch record's head while
the caller retained that same record's certificate through a parameter.
Both rejection tests failed before the fix because inference accepted them.

The checker now treats other reference parameters and scratch roots as
potential aliases when a shared root is written. A distinct resolved binding
is an identity for tracking, not evidence of physical separation. Every call
with active linked certificates needs a proved write footprint or loses the
certificates; scalar-only arguments do not bypass this check. Parent-record
replacement also invalidates descendant scalar certificates. Fresh local
storage remains distinct from pre-existing caller storage, and same-root
inline fields retain the field-sensitive rules above.

Footprint analysis stops once an unknown effect makes a precise summary
impossible and reuses the existing function table for ordinary definitions.
After these changes the full compiler suite and QEMU Z3 recheck pass. QEMU
compile allocation is 742,949,451 / 743,000,000 words. GrowablePool still has
26 diagnostics; no disjointness contract or external frame assertion has
been silently introduced to eliminate them. Owner-derived lifetime ties are
not automatically treated as proof that two physical regions are disjoint.

### Prior art for alias and frame requirements

Research requested by the maintainer on 2026-11-17 preceded approval of a
limited applicability pilot against the current kernel. This approval does
not authorize assuming separation at opaque boundaries or a general heap
inference engine.

- Rust prevents conflicting live mutable borrows in safe code and recognizes
  disjoint struct fields. General container separation is exposed through
  APIs such as split_at_mut. get_disjoint_mut checks overlapping dynamic
  indices at runtime; Rust does not statically solve every separation query.
  Sources: https://doc.rust-lang.org/nomicon/borrow-splitting.html and
  https://doc.rust-lang.org/core/primitive.slice.html#method.get_disjoint_mut.
- SPARK checks harmful aliasing between mutable parameters and between
  parameters and referenced globals. Its ownership rules restrict pointer
  use; global access summaries can be inferred from bodies and propagated to
  callers. This directly addresses both counterexamples above without
  requiring a handwritten contract at every call.
  Sources: https://docs.adacore.com/spark2014-docs/html/ug/en/source/language_restrictions.html#absence-of-interferences
  and https://www.adacore.com/blog/spark-2014-rationale-data-dependencies.
- Separation logic preserves an untouched frame only when the required
  resource separation/permissions have been established. F* Pulse makes
  those permissions part of pre/postconditions. CN combines separation-logic
  refinement types, resource inference and SMT reasoning for systems C;
  its pKVM application is relevant evidence, not a promise of annotation-free
  verification for Takibi.
  Sources: https://fstar-lang.org/tutorial/book/pulse/pulse_ch1.html and
  https://www.cs.ox.ac.uk/people/christopher.pulte/popl23.pdf.
- Bi-abduction infers missing preconditions and untouched frames. Infer
  demonstrates the compositional approach, but its Pulse bug finder uses
  optimistic assumptions for unknown functions and documents missed bugs.
  Copying that acceptance policy would not establish Takibi compile-time
  safety. Infer Pulse and F* Pulse are different tools.
  Sources: https://fbinfer.com/docs/next/separation-logic-and-bi-abduction/
  and https://fbinfer.com/docs/checker-pulse/#unknown-functions.

Assessment: retain compiler-checked field/range permissions and body-derived
read/write summaries as the small initial domain. Use SPARK-like alias checks
and the separation-logic frame rule as design references before attempting
general heap-shape or bi-abductive inference. Array-range separation can
produce ordinary arithmetic obligations once storage provenance is known;
distinct names or lifetime brands alone cannot supply that provenance.
Unknown external behavior remains an explicit boundary. Any API restriction,
inferred caller obligation or additional audited boundary must be assessed
against the real kernel/native callers before it becomes language policy.

### Whole-kernel write-summary census (2026-11-17)

The first applicability measurement uses the current typed, monomorphized
program, including resolved call targets and binding identities. An isolated
compiler copy calls the same body-derived write analysis for every function,
not only functions reached while preserving a linked certificate. The survey
adds a reason to Unknown and prints rows; it does not change acceptance,
code generation, or the trusted boundary. Source parsing and analysis are
OCaml; a temporary Python driver only replays compiler commands and counts
emitted rows. No maintained checker or source parser was added in Python.

All 23 replayed kernel object compilations succeeded, including both platform
main objects and user_payload. Counts below are function instances after
monomorphization and generated builtins, not distinct handwritten functions.
The two platform counts overlap and must not be summed as unique functions.

| Compilation unit | Instances | Empty write set | Parameter-field writes | Unknown |
| --- | ---: | ---: | ---: | ---: |
| QEMU main | 5929 | 2154 | 67 | 3708 |
| RPi5 main | 6804 | 2558 | 67 | 4179 |
| user_payload | 71 | 4 | 0 | 67 |

Thus the deliberately small write-summary domain covers 37.5% and 38.6%
of the two main units without new source annotations. These are NOT memory
safety coverage percentages. Empty writes do not imply no reads, no shared
state, termination, or freedom from concurrent interference. This census
has not installed a whole-program harmful-alias checker or a read footprint.
It cannot yet estimate the final annotation cost of those checks.

The first propagated blocker for each unknown main-unit summary is:

| First blocker | QEMU | RPi5 |
| --- | ---: | ---: |
| Call without a resolved Takibi-body target, including builtins | 2365 | 2627 |
| Store without a parameter-relative inline destination | 804 | 979 |
| Resolved target without an available body, including externs | 513 | 544 |
| Non-scalar assignment not summarized by this domain | 19 | 22 |
| Callee destination not recoverable from the actual argument | 7 | 7 |

These are first-blocker counts, not independent causes or repair estimates:
removing one blocker may expose another. For QEMU, atomic_word_load is the
first blocker in 913 summaries, mrs_daif in 306, atomic_load_acquire in 286,
and the extern preempt_count_add in 435. This is evidence that missing
builtin/global-effect integration dominates before general heap reasoning
can be assessed. An atomic load's absence of ordinary writes would not,
by itself, prove stability of the memory it reads.

Concrete useful summaries already include FreelistCore initialization,
insertion and removal, terminal settings, diagnostic rings and snapshot
field construction. For example, scheduled_process_diagnostic_record_fill
has two reference parameters but writes only snapshot fields; the process
record is read. This is a useful next read/write-and-separation pilot.
Its summary alone does not prove the actual arguments disjoint, even though
they have different record types.

user_payload's first blockers are svc5 (35), unresolved stores (26), an
opaque mmap adapter (4), io_read_span (1), and an external scheduler probe
(1). The existing audited syscall output guarantees cannot automatically be
promoted into a guarantee that every other location is preserved.

No source annotations, unsafe effects, runtime initialization flags or new
trusted assertions were added for this census. The 26 GrowablePool linked
initialization diagnostics remain; this measurement does not waive them.
The next bounded experiment should connect existing builtin effects, infer
named global accesses, and check the snapshot input/output pair and an
owner-derived page accessor. Keep unknown physical separation and external
writes rejected until independently justified. General heap inference and
dynamic fallbacks are not yet indicated by this baseline.

Local evidence is under /tmp/takibi-frame-survey: run-reasons.log records all
23 command exit statuses, per-object logs contain FRAME_SURVEY rows, and
run-refs.log repeats the three principal units with reference counts. The
instrumented compile times include code generation and diagnostic output
on a host running other checks; they are not a solver-overhead benchmark.

### Connecting existing read-only instruction semantics

The next step recognizes Atomic_spec.Load (including AtomicWord cell loads)
and Instr_spec.Read as having no memory writes of their own. It uses the
existing instruction tables, not effect-name guesses or an extern allowlist.
Argument expressions are still traversed for writes. Traps, interrupt-mask
changes, atomic stores and read-modify-write operations remain unknown.
Nothing in this rule proves shared-memory stability or lock correctness.

The repeat census gives 2588 empty and 69 parameter-field summaries out of
5929 QEMU instances (44.8%), and 3036 empty and 69 parameter-field summaries
out of 6804 RPi5 instances (45.6%). user_payload is unchanged. This improves
coverage without source annotations, but also exposes the next blockers:
preempt_count_add becomes the first blocker in 1103 / 1107 summaries.
Its assembly really writes a reserved word in the current stack; its scalar
argument list must not be interpreted as an empty memory footprint. Proving
that word separate from ordinary object storage needs an explicit boundary,
not an optimistic inference from the extern signature.

Compiler controls accept a linked frame across a raw atomic read and a
system-register read, reject an opaque-destination atomic store, and reject
a read whose argument evaluation overwrites the head. The full compiler test
suite passes. The census remains a write-summary measurement, not a complete
alias or memory-safety proof.
The production QEMU main-object build and its Z3 range/initialization checks
also pass after the connection: 3.39 s cold Z3 time against the 5 s budget,
and 742,949,451 allocation words against 743,000,000. A separate GrowablePool
build still rejects with the same 26 linked-initialization diagnostics.


### Named global write summaries

Write paths now distinguish a reference parameter from a named global. A
callee's global writes propagate through direct calls without being confused
with parameter positions. Global names are resolved only when the expression
has no local binding identity, and the declared type is available. Pointer
and reference values loaded from globals do not identify their referents.
Global arrays are conservatively summarized as whole-array writes.

This preserves a certificate for fresh local storage across a helper that
increments a global counter. It does not preserve a reference parameter's
certificate on an assumption that it cannot alias global storage. Controls
cover the positive local case, the conservative parameter case and a global
pointer dereference; the full compiler suite passes. The production QEMU
main build and Z3 checks pass with 742,986,836 allocation words against the
743,000,000-word limit. This is a write-summary extension, not an inferred
separation precondition or a new trust contract. The earlier census numbers
predate this extension and have not been relabeled as current coverage.

### Separation candidates and external entrances

A non-relaxing instrumented run identifies fake_page_generation as the first
named global whose write invalidates the pool parameter's certificate in
four GrowablePool specializations. A separate counterfactual experiment
ASSUMES separation from fake_page_* metadata only. It exposes four required
global roots: fake_page_generation, fake_page_live, fake_page_next_generation
and fake_page_owner. Diagnostics decrease from 26 to 22: the four allocation
failure returns become acceptable under the assumption; successful allocation
still loses the relation through the page-backed write path. The compiler
still exits nonzero. This experiment is not a proof and its assumption was
not copied into the maintained compiler.

A second control checks the object-file boundary. A private local_helper and
main, compiled with --external-entry main, both have global ELF text symbols
(nm type T). Private source visibility and absence from --external-entry do
not establish a closed caller set. Inferred separation conditions therefore
need an object-boundary policy as well as direct-call checking. Runtime
function types also cannot silently erase a new condition.

The proposed narrow policy is to give Internal linkage only to functions
with inferred entry requirements, reject exporting those functions through
--external-entry, and reject their conversion to runtime function values.
Direct callers must prove or propagate requirements. The maintainer later
approved the refined version described below, including public wrappers that
discharge all conditions; the integration experiment implements it. Explicit
separation contracts remain an alternative for interfaces that need to carry
conditions. Neither approach inherently adds a runtime test.

Evidence and the concrete proposal are in /tmp/takibi-separation-pilot:
growable.log (26 diagnostics), hypothesis.log (22, counterfactual),
export-control.tkb/.o and BOUNDARY_PROPOSAL.md. The remaining page-backed
storage obligation must still be solved or presented as a separate decision;
metadata separation alone is insufficient.

### Typed fake-page view without raw-address erasure

The native provider's page_bytes can use the existing typed-array slice:

```takibi
fn page_bytes(owner: borrow PageOwner[page]) -> [u8; PAGE_SIZE..] @ page {
    let start: usize = owner.index * PAGE_SIZE;
    return fake_pages[start..<start + PAGE_SIZE];
}
```

This compiles on the already published compiler, with trap rejection enabled.
The indexed owner bounds supply the page index and the declared array extent
supplies the endpoint bound. No added annotation, runtime bounds fallback or
new language rule is necessary. It removes the raw pointer round-trip and
the accessor's unsafe effect while preserving its lifetime-indexed return.
This removes a provenance obstacle; it does not itself establish separation
from an arbitrary pool parameter or solve all linked diagnostics.

A native executable writes distinct first/last-byte values to all 64 pages,
then verifies all values remain at their separate backing-array offsets; it
exits zero. A negative control extending the slice by one byte exits nonzero
with the expected array-subslice compile-time-bound diagnostic. The initial
standalone control disables unused-function rejection only, not trap checks.
Evidence is in /tmp/takibi-page-view-pilot (persistent-probe and overflow.log).
The kernel provider already uses its typed region's bytes field; it is not
changed by the native-provider cleanup.

### Separate read/write summaries (experimental census)

A separate, non-enforcing OCaml pilot extends the body traversal with read
paths. It distinguishes evaluating an address from reading its referent,
counts reads of scalar globals, and ignores validated scalar compile-time
constants without confusing shadowing locals with globals. Calls compose
parameter-relative paths and named globals. Atomic memory accesses, raw
referents, and non-scalar parameter-value reads without modeled borrow/value
semantics stay Unknown. This code is not connected to program acceptance.

Twelve emitted-summary controls distinguish field reads, field writes,
input/output copying, scalar global reads/writes/increments, direct-call
composition, raw-address reads, global-pointer writes, constants, shadowing,
and unsupported whole-record values. All three principal kernel object
compilations succeed with the reporting-only hook.

| Unit | Instances | Both summaries known | Read unknown, write known | Read known, write unknown | Both unknown |
| --- | ---: | ---: | ---: | ---: | ---: |
| QEMU main | 5929 | 699 | 1983 | 30 | 3217 |
| RPi5 main | 6804 | 807 | 2323 | 38 | 3636 |
| user_payload | 71 | 2 | 2 | 5 | 62 |

These counts include generated/generic instances and overlap between the
platforms. They are neither safety coverage nor a required annotation count.
The read analysis is deliberately much narrower than the write analysis;
unknown must not mean a program needs a handwritten contract.

On both platforms, scheduled_process_diagnostic_record_fill has ten read
paths rooted in parameter 0 (record), including state.value and command_line,
and thirteen write paths rooted in parameter 3 (snapshot). No source
annotation is added. This supplies a concrete input/output separation
candidate; it does not establish that actual arguments are disjoint. The
approved external-entrance policy and a caller-side provenance check are still
necessary before inferred requirements can preserve initialization facts.

Evidence is in /tmp/takibi-access-survey: controls4.log, verdict.txt,
run-borrowed.log and per-object ACCESS_SURVEY rows. The temporary OCaml
modules reuse the typed AST and resolved binding/call identities; Python
only replays commands and compares emitted rows. No source-language parser
or new maintained Python checker was added.

### Prior art for inferred conditions at public and callback boundaries

A follow-up primary-source review distinguishes three separate mechanisms:
inferring a footprint, discovering a necessary precondition, and preserving
that precondition when the function crosses an interface. None alone proves
the other two. The research alone did not authorize a linkage change; the maintainer
subsequently approved the refined boundary policy below.

- Rust encodes access restrictions in reference/ownership types. Function
  pointer types retain argument types, lifetimes where expressed, and the
  unsafe qualifier. FFI correctness remains a boundary obligation rather
  than a whole-program proof of foreign code. This is a model for carrying
  contracts in interfaces, not automatic internalization from body inference.
  Sources: https://doc.rust-lang.org/nomicon/aliasing.html,
  https://doc.rust-lang.org/reference/types/function-pointer.html,
  https://doc.rust-lang.org/stable/nomicon/ffi.html.
- SPARK infers Global dependency summaries from available bodies. This must
  not be confused with inferring arbitrary Pre contracts: absent an explicit
  Pre, the documented default is True. Its ownership and anti-interference
  rules limit harmful parameter/global aliasing. Imported bodies require
  supplied contracts; their default global assumptions are not appropriate
  for Takibi's conservative unknown-extern policy.
  Source: https://docs.adacore.com/spark2014-docs/html/ug/en/source/how_to_write_subprogram_contracts.html.
- SPARK has a particularly close callback precedent. A designated function's
  precondition must follow from the function-pointer type's precondition,
  and its postcondition must imply the pointer type's promised postcondition.
  Because Global/Depends contracts cannot currently be expressed on those
  pointer types, the documented rule rejects taking Access of subprograms
  with global inputs/outputs. The rule is specifically a restriction on an
  interface unable to carry the contract, not a ban on all callbacks.
  Source: https://docs.adacore.com/spark2014-docs/html/ug/en/source/access.html#contracts-for-subprogram-pointers.
- F* Pulse places resource requirements in pre/postconditions and uses the
  separation-logic frame rule to preserve unrelated resources. It illustrates
  contract-carrying modular verification, but is not evidence that Takibi's
  kernel needs zero manual annotations.
  Source: https://fstar-lang.org/tutorial/book/pulse/pulse_ch1.html.
- Swift's exclusivity design combines static checks with runtime enforcement
  when conflicting access cannot be excluded statically. This is a practical
  alternative tradeoff, not a reason to add runtime checks to this pilot.
  Source: https://www.swift.org/blog/swift-5-exclusivity/.

Calcagno et al., POPL 2009, directly study compositional precondition discovery
by bi-abduction. An important detail is re-execution: candidate preconditions
are checked again to remove unsafe candidates introduced by abstraction.
This supports separating inference from validation in the Takibi pilot.
It does not establish that a caller satisfies an inferred precondition.
Source: https://www.cs.ox.ac.uk/people/hongseok.yang/paper/popl09.pdf,
sections 6.2-6.3. Infer Pulse is a different product from F* Pulse and documents
optimistic assumptions for unknown calls to reduce false positives; that
bug-finder policy cannot justify compiler acceptance here.
Source: https://fbinfer.com/docs/checker-pulse/#unknown-functions.

Assessment: retain the narrow initial restriction only for inferred entry
conditions not carried by an existing checked interface. Prove/discharge
conditions at callers or propagate them; validate the body under the
candidate conditions independently. If an existing owner/view signature or a
checked wrapper discharges the requirement, it need not be barred from
publication merely because internal helpers used inference. Otherwise reject
external-entry conversion and contract-erasing function values, and use
Internal linkage for the constrained implementation. Diagnostics must name
the required regions and the boundary rather than silently changing an ABI.

Automatic internalization of inferred-condition functions is a Takibi staging
choice, not a universal rule found in these languages. LLVM Internal linkage
makes an ELF symbol local; it does not prevent calls through an escaped
function pointer. Callback escape prevention is a separate required control.
Source: https://llvm.org/docs/LangRef.html#linkage-types.
A later contract-carrying function type or resolved-target specialization may
relax that restriction when a concrete caller needs it. No new syntax,
runtime fallback, trust contract or linkage policy is implemented by this
research update.

### Approved separation implementation experiment

The maintainer approved the refined policy after the primary-source review.
The integration now experiments with candidate discovery only after the
conservative initialization pass fails, a second run under frozen candidates,
and a finite direct-caller closure. Conditions propagate as whole entry roots;
callers can discharge them using fresh inline storage or distinct inline
fields. Function values, explicit external entries and generated entry hooks
cannot erase remaining conditions. Wrappers that discharge all conditions
keep external linkage. This is a compiler acceptance check (prevention
placement category 1), not a source-scanning build check.

The initial implementation deliberately does not infer returned-address
provenance, indexed storage separation, mutable reference aliases or a
separation guarantee from an ownership index alone. It adds neither runtime
checks nor unsafe effects. Compiler controls and the real GrowablePool build
must establish its actual usefulness before claiming an integration result.

Validation of the implementation experiment:

- The compiler suite passes, including controls for overlapping actuals,
  immutable aliases, distinct inline fields, propagation through recursive
  callers, internal helper linkage, external wrapper linkage, function-value
  rejection and explicit external-entry rejection.
- Both maintained kernel main objects build with their existing build checks.
  The QEMU allocation gate measures 742,983,129 words against 743,000,000.
  An initial 743,119,490-word result was reduced by sharing the initialization
  runner and struct-field callback, without raising the budget or weakening
  the check. Allocation words measure cumulative OCaml allocation, not elapsed
  compile time or peak resident memory.
- GrowablePool still rejects with 26 initialization diagnostics. Candidate
  requirements are retained only after the complete body validates; the
  implementation does not accept the allocation-failure branch in isolation
  while the successful allocation's page writes remain unresolved. Thus the
  earlier counterfactual 26-to-22 result is not a production improvement.
- `make allbuild` has not passed: the native integration remains incomplete.
  No allcheck/push or integration closure is claimed for this experiment.

The next concrete obligation is returned page-view provenance and writes
through that view, including its separation from pool metadata. A lifetime
or owner index alone must not be treated as proof of physical disjointness.
Evidence: /tmp/takibi-separation-pilot/implementation-test3.log,
implementation-kernel3.log, implementation-growable.log and
implementation-allbuild.log. The changed acceptance rules are integrated
locally but not yet published.

### Named global origin of a returned page view

A subsequent implementation step recovers a named inline global array from a
read-only accessor's body when every return has the same origin. It follows
immutable slice bindings and direct accessor wrappers, but not pointer casts,
mutable descriptors, mixed origins, external accessors or a bare ownership
index. A write through such a view conservatively affects the whole backing
array. This supplies write footprints and conditional frame preservation; it
does not prove disjointness between two pages in that array.

The native page_bytes accessor returns a slice of fake_pages. This now lets
the entire growable_pool_grow_one_chunk body validate under inferred separation
from fake_pages and allocator metadata. The actual GrowablePool compilation
reports 18 diagnostics instead of 26: both exit paths in each of four chunk
instances now validate. No new source annotation, unsafe effect, runtime flag
or zeroing operation was added. Existing zeroing of the acquired payload page
is unchanged; the free-chain array remains partially initialized.

The six new compiler controls cover direct/helper writes, a returned-view
wrapper, mixed return origins, mutable aliases and opaque external effects.
The complete compiler suite passes. Both kernel main objects are checked
again; the QEMU allocation gate measures 742,924,177 words without a budget
change, after sharing the remaining per-function immutable lookup callbacks.

Remaining concrete boundaries include writes through growable_pool_ref and
growable_pool_ref_at (their pointer comes from a stored usize chunk address),
and native console output through extern linux_write. The former requires a
provenance-preserving stored representation or a separately reviewed contract;
the latter must not be declared read-only merely from its name or scalar
signature. No such trust expansion has been implemented. Existing owner and
region storage facilities should be examined before proposing new syntax.

Evidence: /tmp/takibi-separation-pilot/origin-growable.log (18 diagnostics),
origin-test2.log and origin-kernel2.log. The integration is still incomplete;
this does not supersede the requirement for allbuild and allcheck before
publication and issue closure.

Declaration controls for retaining page authority were also checked against
the maintained provider and compiler. A linear struct containing one
existential PageOwner field compiles. An array of those owners, an array of
Place(owner), and a pool field containing an array of records with one private
Place owner each all reject with storage diagnostics. These controls do not
show a migrated allocator: they establish the current representation boundary.
They are in /tmp/takibi-stored-page-pilot/{single,array,places,entries}.tkb with
matching logs. The next comparison is narrowly inferred provenance through
stored chunk addresses versus extending retained-owner array storage; neither
has been assumed from an ownership index or from unsafe code.

### Stored integer address: first bounded candidate audit

The maintainer authorized the concrete stored-address experiment. A separate
reporting-only OCaml pass over the real typed AST identifies four stores in
instantiated growable_pool_grow_one_chunk bodies as candidate fake_pages
addresses, four constructor stores as zero (not allocated), and both pointer
accessor return paths as requiring an origin fact for chunk_data_base[index].
It leaves compiler acceptance unchanged: the same 18 initialization diagnostics
remain. Arithmetic offset tracking in this reporting pass is a candidate only;
it does not prove non-wrapping arithmetic, bounds or pointer validity.

A finite OCaml model of capacities 1 through 4 audits the proposed prefix
relation: every chunk below active_chunks has acquired-page provenance.
Across 1,666 growth transitions from states satisfying the relation, 594
transitions satisfying chunk <= active_chunks preserve it; without that
condition 936 transitions are counterexamples. Another 438 mutations of the
allocated prefix to zero, metadata or unknown origins are rejected. This is
bounded evidence, not a proof of the compiler or the allocator.

The smallest counterexample has capacity 2, active_chunks 0 and chunk 1:
writing page provenance at index 1 then setting active_chunks to 2 leaves
index 0 unallocated. The existing chunk < MAX_CHUNKS condition alone permits
this input. Both maintained direct callers instead load chunk from
pool.active_chunks, so their source has the stronger relation. That
observation still needs to become a checked caller obligation; it is not an
assumption to insert into the callee. Reads also need an allocated-chunk
condition, independently of whether the stored usize was initialized.

A faithful minimal unsafe accessor accepting any initialized usize compiles,
confirming that its existing type is not a provenance contract. This is not
reported as a newly discovered safe-code acceptance bug: the control contains
an explicit unsafe integer-to-pointer conversion and does not dereference it.

Evidence: /tmp/takibi-stored-address-pilot/growable.log,
prefix_model.ml/.log and forged-address.tkb/.log. The next step is to connect
candidate origin and allocated-prefix facts to checked source transfers,
without introducing runtime state or accepting the reporting model as proof.

Separately, langcheck found two raw constant lookups in the linked checker.
Certificate keys now use the width-checked leaf reader (including its existing
solver obligation); the syntax-only constant-presence test documents that it
does not read a proof value. The existing proof-fold-width check caught the
gap; named-terminal and out-of-domain controls plus the full compiler suite
and langcheck pass. No wrong accepted memory access was demonstrated by this
finding, and no new trusted assertion was added.

### Source-backed growth-call snapshots and prior-art comparison

The existing init-flow arithmetic domain does not currently name mutable
reference fields: all five specialized growth calls report unknown arithmetic
provenance when directly queried for chunk <= pool.active_chunks. A separate
reporting-only copy-propagation experiment tracks a field-read version until
any possible memory write, reference rebinding or unknown call. It discovers
the equality at all five actual calls. Nine controls cover direct copying,
a read-only intervening call, early exits, loops, direct writes, possible alias
writes, unknown external writes and reference rebinding. A source mutation
that resets active_chunks between the capture and call loses the equality at
all five real call sites.

The exported integer implications produce 19 expected Z3 results: nine
positive proofs and ten stale-version counterexamples across controls and
actual/mutated calls. This checks pure arithmetic after version/copy analysis;
it does not prove the correctness of that analysis, a heap relation, pointer
validity or allocation liveness. Compiler acceptance is unchanged by the
reporting pass. Evidence is in /tmp/takibi-stored-address-pilot:
call-baseline.log, snapshot-controls2.log, snapshot-growable.log,
snapshot-mutated-growable.log, snapshot-z3-final.log and check_snapshot.py.

Primary-source comparison for the newly exposed stored-state question:

- Flux supports strong references with postconditions that update a refined
  state, and its vector API illustrates requiring an index below a logical
  length. Its opaque-vector tutorial explicitly trusts the wrapper APIs;
  that example is not evidence that the allocator implementation is verified.
  Sources: https://flux-rs.github.io/flux/guide/specifications.html and
  https://flux-rs.github.io/flux/tutorial/05-vectors.html.
- Verus separates an address-valued PPtr from a tracked, erased PointsTo
  permission. The permission carries initialization and access authority;
  reconstructing a PPtr from an integer does not establish validity. The
  simple API explicitly omits general pointer provenance, so it is not a
  complete Rust provenance model to copy into Takibi.
  Source: https://verus-lang.github.io/verus/verusdoc/vstd/simple_pptr/struct.PPtr.html.
- SPARK's Relaxed_Initialization and Initialized attribute support partial
  initialization, including a stack whose content above Top need not be
  initialized. This does not equate an initialized address integer with a
  live allocation; nontrivial array properties may still need contracts or
  loop invariants.
  Source: https://docs.adacore.com/live/wave/spark2014/html/spark2014_ug/en/source/specification_features.html.

Inference for Takibi: retaining usize storage need not force runtime tags,
but a checked origin/prefix permission must survive independently of the
integer's initializedness. The read side still needs the selected chunk to
be allocated. GrowablePool's raw accessor requires only initialized base
integers; FreelistOwner's current generation index does not encode that bound
or this pool's identity. Do not enlarge init_links into an allocation or
bounds guarantee: those remain separate obligations. The source snapshot
result is one prerequisite, not a complete solution or an annotation count.

### Scratch-selector root identity correction

Audit of the unpublished separation implementation found that its retry pass
mistook selector-generated roots for distinct declared globals. A helper-call
control using rows[i] and rows[j] with i=j compiled before the correction and
rejects afterwards. Only an actual global declaration may now acquire nominal
global disjointness; selected elements remain unknown. An in-process compiler
regression and the full unit suite pass. Both kernel main-object builds and
checks pass; QEMU allocation is 742,936,052 words under the existing limit.
No runtime check, unsafe escape or trusted assertion was introduced. The
source control and before/after logs are in /tmp/takibi-stored-address-pilot.

### Stored-address read-side controls

Three native controls use the maintained GrowablePool and fake-page provider
with the reporting-only pilot compiler. The isolated fixture loader excludes
only the unrelated growable_pool_probe function before monomorphization;
allocator and accessor bodies are unchanged. This is not a full native-suite
build. Each control compiles, links with the existing Linux startup/syscall
objects, and exits zero after checking the following observation:

- A freshly initialized pool returns address zero for ref_at(pool, 0).
- After ensure(pool, 1) returns Ok, ref_at(pool, 0) returns nonzero.
- After the same successful ensure, assigning zero to chunk_data_base[0]
  makes ref_at(pool, 0) return zero again.

No control dereferences the returned pointer. These are existing unsafe API
behaviors, not evidence of a new safe-code defect. The source and logs are
/tmp/takibi-stored-address-pilot/read-{empty,grown,corrupt}.{tkb,log}; the
linked executables have the same stems. No acceptance rule was relaxed.

The controls isolate two obligations beyond initialized integer storage:
reads need an allocated-chunk bound, and writes to the address table must
invalidate or re-establish the stored-origin fact. A future checked transfer
must distinguish the successful ensure result from its failure results and
preserve the fact only across writes proved unrelated. Nonzero alone is not
an allocation or provenance proof. No runtime tag, additional production
unsafe boundary, or trusted origin assertion was added. Complete read-side
inference, allocation lifetime, extent/alignment and pool identity remain
unproved by this experiment.

### Conditional consumer propagation experiment

A reporting-only OCaml pass in the isolated pilot compiler consumes an
explicit candidate summary: ensure(pool, index) returning Ok covers indices
through index for that pool. This summary is ASSUMED for the consumer
experiment, not inferred from the allocator or installed as a trusted
production contract. All possibly writing calls and memory assignments erase
its facts; body-derived read-only calls preserve them. Branch joins intersect
facts, and paths ending with return do not constrain later statements.

Eight actual-library controls compile and produce the expected reports:
success and a subsequent read-only helper retain coverage; empty pool,
zero overwrite, a continuing failure arm, an out-of-covered-range index,
another pool, and a writing helper do not. No per-read annotations were added.
These reports do not change compiler acceptance or establish pointer safety.
For the concrete usize/2/3/6 instantiation, a separate QF_BV query is unsat
for a counterexample to the chunk and page-offset bounds given active <= 3
and index < active * 2. This uses 64-bit arithmetic; provenance, allocation
lifetime and the invariant's establishment are outside that query.

Applying the same reporter to the full maintained exerciser and its library
probe covers only 1 of 10 ref_at calls. The first payload store erases the
fact under the deliberately conservative write rule. The application also
uses a boolean ensure_ok wrapper and output calls; the prototype neither
infers the wrapper's conditional summary nor preserves facts through opaque
external writes. The ordinary compiler still emits 18 initialization
diagnostics. Thus the small controls do not justify claiming annotation-free
whole-program coverage. Next work must connect payload-write separation to
stored provenance and derive conditional summaries through wrappers, without
assuming that a named output routine cannot modify memory.

Evidence: /tmp/takibi-stored-address-pilot/lib/read_prefix.ml,
read-*-prefix.log, full-read.log, queries/read-range.smt2 and read-range.log.
The pilot adds no runtime tags or production unsafe/trust boundaries.

### Body-derived boolean adapter experiment

The isolated consumer prototype now recognizes the existing ensure_ok body
without depending on its name: one exhaustive match on ensure's result,
with literal true only for Ok and literal false for every failure. Parameter
positions come from resolved binding identities. Both maintained generic
instantiations match this restricted shape. The allocator's Ok summary is
still an explicit experimental premise; recognizing this adapter does not
prove that underlying summary.

A renamed adapter retains coverage at a caller which returns on false.
Changing a failure arm to true, adding an address-table write before the
successful return, or reversing the caller's branch prevents coverage.
All twelve consumer controls (the earlier eight plus these four) compile
and report the expected result: three retain coverage and nine do not.
No new annotations, runtime checks or production acceptance rules were added.

Full-exerciser coverage remains 1/10. Invalidation traces locate the next
obstacles precisely: the library probe loses its fact at the first payload
store, and app_main loses successful ensure_ok facts at uart_puts calls.
The latter reaches the opaque linux_write extern; its name and intended OS
behavior are not a checked memory-write footprint. The full ordinary compiler
still rejects with 18 initialization diagnostics. A body-derived boolean
adapter is therefore feasible for the current source shape, but does not
remove the independent payload-separation and foreign-call obligations.

Evidence: /tmp/takibi-stored-address-pilot/lib/wrapper_prefix.ml,
read-*-final.log, wrapper-full.log. Larger adapter shapes (saved boolean
results, nested wrappers, recursive control flow) are not covered by this
experiment and must not inherit the summary by name.

### Relative extent of stored native page addresses

A separate reporting-only straight-line analysis now derives a byte-array
origin together with an offset interval from the actual native provider body.
For page_physical_address, PageOwner.index's existing refinement gives
fake_pages offsets 0..258048 and at least 4096 remaining bytes. The same
minimum follows for page_run_physical_address; this does not establish the
larger extent of an entire multi-page run. No source annotations were added.
The analysis handles immutable local expressions, direct literal constants,
refined usize fields and checked nonnegative interval addition/multiplication;
unsupported expressions or interval overflow produce unknown.

Seven source controls compile. The valid page-index control yields 4096
remaining bytes. The one-past control yields zero remaining bytes and cannot
justify a store. Beyond-object, unbounded-index, arbitrary-integer,
truncated-address and wrapping-offset controls produce no origin/extent
candidate. No control dereferences a pointer and acceptance is unchanged.

A QF_BV query for a page index below 64 and a usize slot below 2 proves the
8-byte access remains in the 262144-byte object when the object's entire
address interval is representable (unsat). Removing that object-validity
premise yields sat. Relative provenance alone therefore does not establish
absolute machine-address non-wrap. A future implementation must connect this
to the memory model's valid static-object extent, not silently assume that
arbitrary integers name valid storage. Allocation lifetime and conditional
prefix establishment remain separate obligations.

Evidence: /tmp/takibi-stored-address-pilot/lib/address_extent.ml,
extent-provider.log, extent-controls.{tkb,log},
queries/extent-{object-valid,object-unconstrained}.smt2 and matching logs.
This experiment does not yet preserve caller facts across payload stores;
it supplies a missing bounded-access premise for that step. No runtime tag,
production unsafe code or new trusted contract was introduced.

### Conditional payload-frame feasibility measurement

The isolated reporter has an opt-in what-if mode,
TAKIBI_PILOT_ASSUME_PAYLOAD_FRAME=1. It explicitly assumes the missing premise
that a covered ref_at result designates a valid in-bounds payload access in
separate global backing storage. This mode does NOT derive that premise from
the stored-address path and does not change production acceptance. It must
not be promoted into a trusted assertion to make integration pass.

Under that premise, a direct payload store preserves candidate facts only
for inline local records, identified by resolved binding IDs and types.
Parameter references, arbitrary pointers, pointer arithmetic and saved pointer
aliases do not gain separation from this rule. Address-table writes invalidate
the prefix before a later accessor can use it. The actual provider's relative
extent analysis is supporting evidence, not a discharge of this premise.

The full reporter then covers all five ref_at sites in growable_pool_probe,
versus one with the mode disabled. All five app_main sites remain unknown
because output calls erase the candidate facts. Production compilation still
fails with 18 initialization diagnostics. The measurement isolates the value
of the missing frame rule; it is not an increase in proved compiler coverage.

Controls confirm retention after a direct covered store and invalidation
after a table corruption, out-of-covered-range store, saved-pointer store or
explicit unsafe arbitrary-address store. With the mode disabled, even the
covered-store control loses its fact. The arbitrary-address controls were
compiled only, never executed; their unsafe cast is confined to temporary
negative fixtures. No maintained unsafe code or trusted contract was added.

Evidence: /tmp/takibi-stored-address-pilot/frame-{write,corrupt,outside,alias,
arbitrary}.tkb and corresponding logs, frame-off.log and frame-full.log.
The next substantive obligation is to derive the stored payload premise from
constructor/growth/read paths, rather than broadening the what-if mode.

### Source-backed growth tail transfer

The pilot now connects the provider's inferred relative address extent to
immutable locals and the actual growth stores. It recognizes the successful
tail in all four maintained growth instantiations: chunk_data_base[index]
receives an address within fake_pages at offset 0..258048, then active_chunks
becomes the same index plus one, leaving at least 4096 bytes at that base.
Receiver and index correspondence use resolved parameter binding identities.
The intervening chunk_page_index write is to a distinct inline field; an
unknown intervening statement discards the candidate.

Five source mutations produce no such tail candidate: storing zero, storing
at a different index, increasing the count by two, publishing the count before
the address, and inserting an unknown external call. The first four still
compile under the existing rules; they were not executed. The unknown-call
control reaches the reporter and then fails two existing initialization
checks. The full unmodified exerciser still fails its 18 initialization checks.

This is a source-backed tail relation, not a complete prefix invariant.
Its outstanding obligations remain the old prefix at entry, index <= the old
count, count non-wrap, and preservation across the earlier allocation and
zeroing operations. The earlier source-copy caller experiment addresses the
index equality at actual callers; it is not yet a connected compiler proof.
Constructor, loop, failure-return and read-side transfers still need checking
before the hypothetical payload-frame premise can be removed. No production
acceptance, runtime checks, unsafe code or trusted contracts changed.

Evidence: /tmp/takibi-stored-address-pilot/lib/growth_transfer.ml,
growth.log, growth-full.log, growth-{zero,wrong-index,wrong-count,reordered,
unknown-call}.tkb with corresponding modified libraries and logs.

### Allocation/zeroing frame premises from the existing checker

Inspection of the actual body-derived summaries at the usize/2/3/6 growth
call gives precise changes before the final table/count stores:

- page_alloc writes fake_page_generation, fake_page_live,
  fake_page_next_generation and fake_page_owner.
- page_bytes, page_physical_address and page_owner_transfer_index have empty
  write footprints.
- The indexed zeroing store targets the inferred fake_pages global view.

The existing initialization checker already infers the corresponding five
separation conditions between the pool parameter and those globals, propagates
them through ensure, and discharges them at the native fixture's fresh inline
local pool. The fixture compiles with no extra annotations. As a negative
control, exporting the specialized ensure directly as an external entry is
rejected with "would erase inferred separation"; the command exited nonzero
and the expected diagnostic was checked independently. This is an existing
checked boundary, not a new trusted read-only declaration for provider names.

These results supply reusable frame premises for the stored-address prefix
work. They prove neither that the current prefix reporter consumes those
premises nor that its allocator invariant is complete. The remaining table
and count writes are intentional transfers and must be validated by the new
prefix domain; they cannot simply be excluded from the write set.

Evidence: /tmp/takibi-stored-address-pilot/lib/growth_frame.ml,
frame-evidence.log and frame-export.log. No maintained acceptance rule,
annotation, unsafe code or runtime check was changed by this inspection.

### Constructor and loop composition evidence

The reporter recognizes a normal-return empty prefix from the actual
constructor's final active_chunks=0 assignment, provided no earlier return
can bypass it. This establishes no page origin and requires no initialized
prefix elements. Mutating the final count to one or adding an earlier return
prevents the report; the earlier-return control also fails the existing
initialization contract independently.

For both maintained ensure instantiations, a separate structural check ties
the loop's comparison, captured active count, capacity guard, actual resolved
growth callee, failure returns and final success together. It reports the
successful exit inequality (index < active_chunks * slots) conditional on the
callee's checked prefix/frame obligations. The loop is identified by its
body and resolved bindings rather than the ensure function's name. Changing
the captured index, returning success for allocation failure, weakening the
loop comparison or clobbering the count before the final return prevents the
candidate. All four loop mutations still compile under the ordinary rules;
none was executed.

This is composition evidence, not an implemented whole-program prefix proof.
The constructor fact, growth tail, frame conditions and loop summary are not
yet propagated as one checked state through callers. In particular the
consumer reporter still uses its explicit candidate summary; the optional
payload-frame assumption must remain disabled for any production claim.
No acceptance rules, runtime checks or maintained unsafe code changed.

Evidence: /tmp/takibi-stored-address-pilot/lib/{prefix_constructor,
loop_transfer}.ml, loop-full.log, loop-{copy,failure,condition,clobber}.log,
read-grown-constructor.log and constructor-*-constructor.log.

### Foreign output boundary: generic write is not memory-readonly

An isolated native control linked to the repository's AMD64 syscall.o calls
the actual linux_write leaf with /proc/self/mem and changes a local buffer in
the same process. A generic write(fd, ...) contract asserting no caller-memory
changes would therefore be false. A readonly buffer type or a logging effect
is insufficient. The experiment touches only its own fixed buffer.

The linuxcheck runner supplies a stdout pipe through shell command
substitution. A future audited console-specific boundary could use that
explicit environment premise, but must account for descriptor replacement,
signals and callbacks before broad migration. Generic linux_write and
linux_syscall must remain unknown. A proposed extern-only memory-frame
contract is a new trust decision, not an implementation authorized by the
stored-provenance experiment. No such contract has been installed.

Rust asm readonly and LLVM 19 memory attributes are useful prior art for
explicit foreign effects, but include optimizer semantics not appropriate to
copy blindly onto console I/O. Any initial Takibi contract should preserve
front-end facts without declaring the output operation pure to LLVM.
Sources: https://doc.rust-lang.org/reference/inline-assembly.html and
https://releases.llvm.org/19.1.0/docs/LangRef.html#function-attributes.

Evidence and reviewable proposal:
/tmp/takibi-stored-address-pilot/write-self-memory.{c,log} and
/tmp/takibi-stored-address-pilot/foreign-frame-proposal.md.

### Whole growth-path check connected to loop candidates

While the foreign-console decision is pending, the isolated prototype now
validates the complete supported growth body under explicit entry obligations.
It accepts only the allocation match with a non-mutating failure return and
a successful path whose earlier operations have known global-only footprints,
followed by the validated table/metadata/count tail. The zeroing loop's write
origin must be the known global view. Unknown statements or parameter writes
before that tail prevent a summary. The resulting obligations remain an old
valid prefix, index <= old count, index < capacity and separation from the
five provider globals; this is not an unconditional allocator theorem.

Loop candidate generation now consumes only these whole-body summaries,
rather than all tail candidates. Three controls demonstrate why this matters:
corrupting an old table entry before the successful tail, corrupting it on the
failure path, and returning success on allocation failure all retain the old
tail candidate but produce neither a whole-body nor a loop summary. A valid
body and a body with an additional read-only call produce both. All five
controls compile under the ordinary checker and were not executed.

The consumer reporter's candidate contract and optional payload-frame premise
are still not replaced by an integrated checked state. No production trust,
extern effect declaration or acceptance change was made. The foreign-console
proposal remains a separate pending decision.

Evidence: /tmp/takibi-stored-address-pilot/lib/growth_body.ml,
read-grown-connected.log and body-*-connected.log.

### Constructor-to-caller state connection

The consumer reporter no longer grants ensure success solely by function name.
Constructor summaries create an empty-prefix fact only for a fresh inline
local. Loop summaries are returned by the source analysis, require a matching
address-table capacity, and consume whole-growth-body summaries. Boolean
adapter inference is gated by the resolved loop summary. At a caller, successful
coverage now additionally requires the same pool's prefix fact to exist before
the call; an unknown intervening write removes it. Fresh inline storage
supplies separation from the provider's declared globals in this limited path.

Thirteen connected controls report as expected with the optional payload-frame
hypothesis disabled: the ordinary success case, boolean adapter and renamed
ensure retain coverage; ten controls, including corrupt-before-ensure, unknown
call, constructor count one and all three growth-path corruptions, do not.
The unknown-call control also fails existing initialization checking; the
others compile. None of the corrupt controls was executed.

This removes a name-based ensure assumption from the reporter, not all gaps
in a production proof. The accessor path and payload-write rule still need
validated source summaries and extent checks, function-boundary propagation
remains limited, and the static-object validity premise is part of the memory
model. Full existing-source compilation still has 18 initialization diagnostics
and only 1/10 read sites retains a candidate fact without the payload-frame
hypothesis. No new extern contract, production acceptance change or runtime
check was introduced. The maintainer's extern question was a clarification,
not approval of the foreign-console proposal.

Evidence: /tmp/takibi-stored-address-pilot/read-*-consumer.log,
body-*-consumer.log, constructor-nonempty-consumer.log and consumer-full.log.

### Accessor geometry connected to the stored-prefix schema

The isolated consumer now obtains accessor summaries from the actual direct
pointer helper and its forwarding wrapper. The helper's division, remainder,
capacity guard, table load, captured bindings and usize pointer offset must
match the loop's schema. The relative provider extent must accommodate all
8-byte slots in a chunk. The fallback branch is unreachable under that schema's
covered-index premise; this is not permission to use the fallback without it.
Only the concrete usize case is supported by this experiment.

Caller facts now carry the schema (pool type, table/count fields, chunk width,
capacity and provider extent), rather than only an upper covered index.
Constructor facts identify the count field. Joins and success propagation
refuse mismatched schemas. The accessor name remains useful only for reporting
an unsupported familiar call; it no longer grants coverage. Renaming both the
pointer helper and reference wrapper still produces the positive report.

Seven controls have the expected results with the payload-frame hypothesis
disabled. Changing the divisor, remainder divisor, address table or slot offset
prevents coverage. The renamed helper/wrapper and existing boolean adapter
retain it, and corrupting the count before ensure does not. The wrong-table
control also fails the ordinary initialization contract; other controls compile
and corrupt programs were not executed. Full compilation still has 18
initialization diagnostics and 1/10 application/probe sites retains coverage.

Absolute static-object validity, alignment and production integration remain
outstanding; this relative-range composition is not a completed memory-safety
proof. No new extern contract or maintained acceptance change was introduced.
Evidence: /tmp/takibi-stored-address-pilot/lib/accessor_prefix.ml,
accessor-*-accessor.log, read-wrapper-accessor.log,
read-corrupt-before-ensure-accessor.log and accessor-full.log.

### Concrete native alignment obligation

The provider declares fake_pages with align(65536), forms page addresses with
index * 4096, and the current accessor adds a usize slot offset in units of
8 bytes. Three independent 64-bit arithmetic queries check this combination:
with the declared alignment and valid-object interval, a misaligned access
has no solution (unsat); adding one byte yields sat; removing the base
alignment premise also yields sat. These controls distinguish alignment from
relative extent and must both be represented by a future source summary.

This verifies the concrete arithmetic implication, not source extraction of
alignment or the linker's fulfillment of the declaration. The current
accessor reporter still does not carry an alignment fact, so these results
must not enable its hypothetical payload-frame mode in production. No extern
contract, runtime check or acceptance rule changed.
Evidence: /tmp/takibi-stored-address-pilot/queries/alignment-{aligned,shifted,
unknown-base}.smt2 and corresponding alignment-*.log files.

### Source-derived alignment candidate

The isolated address analysis now reads explicit byte-array alignment and
propagates divisibility through immutable local expressions, addition and
multiplication. Reports retain only a power-of-two divisor, which is compatible
with 64-bit modular arithmetic; unsupported or overflowing abstract arithmetic
falls back conservatively. The real native page-address functions yield a
4096-byte alignment candidate. A one-byte offset yields only alignment one,
and removing the array's explicit alignment also yields only one. The
one-past address may be aligned but still has zero extent: alignment does not
replace the independent bounds obligation.

These compiled controls add source evidence to the earlier arithmetic queries.
The alignment result is still reported separately and not yet consumed by the
accessor or payload-frame decision. No production acceptance or extern trust
changed. Evidence: /tmp/takibi-stored-address-pilot/alignment-source.log,
alignment-controls.{tkb,log} and alignment-no-base.{tkb,log}.

### Alignment now gates accessor summaries

The address summary now carries its inferred power-of-two alignment through
the stored-origin and loop schema. The usize accessor requires alignment at
least eight and divisible by eight, in addition to its relative extent and
geometry checks. With the actual provider, the complete constructor-to-read
report remains positive. Removing only fake_pages' explicit alignment makes
the provider guarantee one and the caller report negative. Both controls
compile under existing rules; the modified provider was not executed.

This connects alignment to the experimental consumer rather than just logging
it. It does not change production acceptance, establish absolute object
placement, or remove the optional payload-frame hypothesis. Evidence:
/tmp/takibi-stored-address-pilot/fake_page_provider-aligned.log and
provider-no-alignment-aligned.log.

### Derived payload frame replaces the what-if switch in the pilot

The consumer no longer uses TAKIBI_PILOT_ASSUME_PAYLOAD_FRAME. A direct usize
store preserves facts only when the source-derived accessor schema, initialized
prefix state, covered index, relative extent and alignment all match, and the
preserved facts concern fresh inline local records separate from the named
global backing object. This uses ordinary valid-object placement semantics;
it does not prove the backend/linker or extend the rule to arbitrary heap
objects, reference parameters or saved pointer aliases.

Without any assumption switch, all five growable_pool_probe reads now retain
candidate coverage after its two payload stores. The five app_main reads
still lose it at opaque output calls. Corrupted tables, uncovered indices,
saved pointer aliases and arbitrary pointers lose the fact. Removing explicit
provider alignment also prevents store-frame retention. These controls compile;
invalid-pointer programs were not executed. The ordinary checker still reports
18 initialization diagnostics: the pilot has not changed production acceptance.

This supersedes earlier descriptions of the opt-in frame mode for the current
pilot only. No extern contract, runtime check or maintained unsafe code was
added. Evidence: /tmp/takibi-stored-address-pilot/frame-*-derived.log,
frame-unaligned.log and derived-full.log.

### First connection to initialization-certificate invalidation

In the isolated compiler, the derived direct-store map now feeds Init_flow
through AST expression identity. A recognized store reports its named global
backing object. Init_flow uses its existing global-write and separation logic
to invalidate affected certificates; it does not skip invalidation entirely.
Unrecognized stores retain the previous conservative behavior.

Compiling the unchanged full native exerciser with this connection reduces
initialization diagnostics from 18 to 17. This is the first acceptance-check
integration of the derived store result, still confined to the isolated pilot.
It is not a green full build or a production-ready implementation. Remaining
raw stores, extern effects, regression coverage and broader integration still
need work. No extern contract or maintained compiler source was changed.
Evidence: /tmp/takibi-stored-address-pilot/derived-full.log (18) and
init-connected.log (17), plus the isolated lib/read_prefix.ml, lib/init_flow.ml
and lib/type_inf.ml connection.

### Acceptance control for the initialization connection

A focused fixture initializes a local pool, ensures a chunk, writes a payload
slot, then calls ensure again. With the isolated store-origin connection it
compiles, links to the maintained native startup/syscall objects and exits zero.
A paired fixture inserts chunk_data_base[0]=0 before that store. It fails the
second ensure's linked-initialization precondition: nonzero compiler status
and the expected diagnostic were checked independently. The negative program
was never linked or executed. This tests an actual acceptance boundary, beyond
reporter output, but does not establish the entire pilot's soundness or replace
maintained compiler regression coverage before production integration.
Evidence: /tmp/takibi-stored-address-pilot/init-frame-{positive,negative}.tkb,
matching logs, and the positive native executable. No extern trust was added.

### Adversarial acceptance controls for derived stores

The positive store-then-ensure fixture was paired with four further mutations:
wrong chunk divisor, wrong remainder divisor, shifted slot offset, and a
provider without explicit byte-array alignment. Each fails the subsequent
ensure's linked-initialization precondition. For every command the nonzero
exit and diagnostic substring were checked independently. None of these
programs was linked or executed. This confirms that geometry/alignment failure
reaches the existing acceptance check, not merely the pilot's report output.
It remains a conservative rejection at the dependent use, not a dedicated
pointer-safety diagnostic at the original raw operation.
Evidence: /tmp/takibi-stored-address-pilot/init-frame-{divisor,modulus,offset,
unaligned}.log and the corresponding fixtures/providers. Production integration
and the remaining native diagnostics are still outstanding.

### Existing unit suite against the connected pilot

The current maintained test tree and tracked kernel fixtures were copied into
the isolated compiler workspace, and dune runtest completed successfully:
3124 compiler tests plus 3 linked-certificate tests. This checks the existing
suite against the pilot's actual Init_flow store-origin connection, rather
than against the unchanged main compiler. It does not replace dedicated
in-process coverage for the new domain, allbuild, allcheck or hardware gates.
Evidence: /tmp/takibi-stored-address-pilot/unit-suite.log and its Alcotest logs.

### In-process acceptance regressions in the isolated workspace

Four Alcotest cases now exercise the complete isolated inference pipeline:
valid payload-store framing, table corruption, a mismatched chunk divisor,
and absent explicit backing alignment. All pass. Positive and negative cases
share a flattened copy of the maintained provider/pool fixture and exclude
only the unrelated growable_pool_probe before monomorphization. Negative
cases require the dependent-use initialization diagnostic, not just any error.
The normal test runner completed; unchanged suites were cached from their
previous successful run. These tests are still isolated and their copied
fixture must be replaced with a maintained fixture strategy before landing.
Evidence: /tmp/takibi-stored-address-pilot/test/test_stored_prefix.ml,
test/stored_prefix_fixture.tkb and stored-prefix-tests.log.

### Remaining owner-access boundary

The two remaining library-probe diagnostics follow stores through
 growable_pool_ref with FreelistOwner values; the application has fifteen
remaining diagnostics with output calls and owner accesses interleaved.
The owner's current generation index does not by itself encode pool identity
or allocated coverage. A native control creates an empty initialized pool,
constructs freelist_owner_new(0,1), and observes growable_pool_ref returning
address zero. It compiles and exits zero without dereferencing the address,
then drops the owner normally. This is an existing raw API behavior, not a
newly demonstrated safe-code memory defect.

Consequently owner-based access cannot acquire the new frame merely because
its argument has FreelistOwner type. Further inference must connect the
actual insert/pop path and returned index to this pool's allocated prefix,
or an explicit API-boundary representation must carry that relationship.
The existing init_links guarantee remains initialized traversal only; it
must not silently be promoted to allocated-prefix bounds or pool identity.
Evidence: /tmp/takibi-stored-address-pilot/owner-without-page.{tkb,log} and
its native executable; init-connected.log contains the remaining diagnostics.

### Legitimately allocated owner passed to another pool

A further native control obtains an owner through growable_pool_insert on one
pool and passes it to growable_pool_ref on a different empty pool. It compiles
and confirms that the returned integer address is the zero base plus the
slot-local byte offset. The first allocated index need not be zero, so testing
for a literal null alone was an incorrect initial oracle; the corrected oracle
uses (owner_index % 2) * 8 and exits zero. No pointer is dereferenced.

Thus the missing pool correspondence is observable even without manually
constructing an owner. Existing IntrusiveOwner[pool_id: addr, allocation: usize]
in the maintained native intrusive-pool implementation demonstrates that an
erased pool identity is already expressible. That identity alone would still
not establish the allocated-prefix range; neither property should be silently
inferred from the current FreelistOwner generation parameter.
Evidence: /tmp/takibi-stored-address-pilot/owner-wrong-pool.{tkb,log} and executable.

### Existing erased pool identity control

A minimal existing-language Owner[pool_id: addr] example now confirms the
available distinction: make(&first, index) followed by consume(&first, owner)
compiles, while consume(&second, owner) rejects with static value mismatch.
A static_assert confirms the owner occupies exactly one usize for its one
index field; the address brand adds no stored identifier in this example.
This is a representation feasibility result, not an implemented GrowablePool
migration. The constructor can still accept an arbitrary index, so branding
alone proves neither allocation nor index coverage. Evidence:
/tmp/takibi-stored-address-pilot/pool-brand-{positive,negative}.{tkb,log}.

### Branding the existing owner and actual fallible insert

An isolated BrandedOwner[pool_id: addr, allocation: usize] wraps the existing
FreelistOwner[allocation] as a private linear field. A static_assert verifies
equal size to the underlying owner. Consuming its field through the existing
freelist_owner_drop passes; passing the wrapper to a different pool fails with
static value mismatch. This checks linear composition, not just a synthetic
one-word owner.

A second fixture wraps the actual growable_pool_insert result in an indexed
BrandedResult[pool_id] variant. Its successful branch returns the wrapped
existential owner. The same-pool fixture compiles, links against the maintained
native startup/syscall objects and exits zero. The different-pool fixture
exits compilation with status 1 and the expected static value mismatch;
both facts were checked independently. The unrelated growable_pool_probe is
excluded by the isolated compiler's existing experiment switch. Neither
fixture dereferences a pointer, and neither claims allocated-range coverage.

The wrapper helper and consumer use existing init_links pre/postconditions
because an otherwise uncontracted borrow uninit parameter requires complete
initialization on return. These are API-boundary clauses, not loop invariants
or caller assertions. No compiler change, runtime identity field, dynamic
check, or extern trust contract was introduced for this experiment.

This leaves two distinct obligations: associating owners with their pool is
already expressible; deriving that a popped index lies in the allocated
prefix still needs the activate/pop/remove invariant. Public low-level owner
construction and mutable pool metadata prevent treating branding alone as
that invariant. Production API migration has not been selected or performed.
Evidence: /tmp/takibi-stored-address-pilot/owner-wrapper{,-negative}.{tkb,log}
and owner-insert-brand{,-negative}.{tkb,log}, plus the positive executable.

### Candidate coverage invariant across pop and remove

A finite OCaml model enumerates capacities 1 through 4, including unknown
links, out-of-capacity terminal values and cycles. Its candidate invariant is
that every reachable free-list node is below allocated coverage and every
nonzero occupancy entry is below that same coverage. Under these premises,
328034 states admit 172318 pops, 553179 accepted removes and 192888 suffix
activations that preserve the invariant. Pop also returns an index below
coverage. Generation exhaustion and failed operations do not mutate this
state. The existing remove guard on nonzero occupant_generation is enough
for this range property; generation equality would be a separate ownership
property. Cycles are intentionally allowed: no uniqueness or termination
guarantee is claimed.

Negative controls show that initialized traversal alone permits uncovered
nodes, and that removing a nonzero occupancy entry outside coverage pollutes
an otherwise empty valid chain. The source initializes occupancy to zero,
sets it in finish_insert, and clears it in remove. Therefore finish_insert
needs a covered-index premise in addition to the existing initialization
contracts; chunk activation likewise needs acquired coverage, not merely
the metadata-array bound. This is a candidate for body-derived requirements,
not a new meaning assigned to init_links.

A native control confirms the helper boundary matters: on an empty pool,
call finish_insert with freelist_owner_new(0,1), remove that owner, and then
call the ordinary insert. The resulting accessor address is zero. Compilation,
linking and execution all succeed; the program only compares the integer
address and never dereferences it. Thus even a returned owner from ordinary
insert is insufficient without preserving the pool invariant through prior
helper calls. No safe-code dereference defect is claimed by this control.

Evidence: /tmp/takibi-stored-address-pilot/owner_range_model.ml and
owner-finish-uncovered.{tkb,log}, plus its executable. The model is finite
evidence and is not connected to compiler acceptance. Source-derived invariant
inference, rejection controls, and production integration remain outstanding.

### Source recognition of chunk activation

The isolated compiler now recognizes the concrete activation body from its
resolved AST: an immutable chunk-times-slots base, a counted loop over exactly
slots, the base-plus-loop-index slot, and the two ordered link/head writes.
Resolved binding identities tie the calculations together; the old and new
head must have the same field path and pool root. Extra statements prevent
recognition. The report states the still-undischarged requirements: prior
reachable-node coverage, chunk below acquired chunks, and separate arithmetic
non-overflow. It does not grant an acceptance fact or claim an inferred
connection to the actual active_chunks field yet.

The actual body produces this report. Replacing the base by zero or adding
an active_chunks reset produces no report, even though the ordinary compiler
accepts those controls. Replacing the old-head link by zero also produces no
report and independently fails the existing init_links check. Renaming the
activation function preserves recognition. These are source-summary controls,
not new compiler rejection coverage. No mutated executable was run.

Evidence: /tmp/takibi-stored-address-pilot/lib/activation_range.ml and
activation-{positive,wrong-link,wrong-base,extra-write,renamed}.log. The next
connection must discharge the acquired-coverage requirement on the actual
growth-success branch before using activation to justify an owner range.

### Growth-success composition at the activation call

The isolated AST analysis now connects the actual insert branch to its
recognized activation callee. It checks an immutable capture of the count,
the upper-bound early return, the resolved growth callee's checked body
summary, a failure arm that returns, an empty success arm, and the immediately
following resolved activation call. Both calls must use the same pool and
captured chunk; the growth summary must update the captured count field.
This reports active_chunks = captured chunk + 1 at that activation call,
conditional on the growth summary's entry-prefix and separation obligations.
It does not yet discharge arithmetic geometry or the prior covered-chain
invariant, nor grant a fact to the acceptance checker.

The actual insert body and a renamed activation function both produce this
conditional report. Failure-continues, different-chunk, and intervening-state-
write controls produce none. All three mutant fixtures still compile under
existing acceptance rules, so these results must not be described as compiler
rejection tests. No mutant executable was run. The positive fixture compiles.

Evidence: /tmp/takibi-stored-address-pilot/lib/activation_call.ml and
activation-call-{positive,failure-continues,different-chunk,intervening-write,
renamed}.log. Owner-result range propagation and caller-entry validation remain
necessary before this evidence can preserve initialization facts after an
owner-based payload store.

### Same-pool reinitialization invalidates old owner coverage

A native control allocates an owner, reinitializes that same pool while
retaining the owner, and converts its later raw accessor result to an integer.
Compilation, linking and execution succeed; the observed address is zero base
plus the slot-local offset. No pointer is dereferenced. Thus pool identity
and an earlier successful allocation together are insufficient after state
replacement. Owner-range propagation must invalidate the relationship on
reinitialization and unknown destructive writes; an erased pool brand alone
does not encode this temporal property.

The existing index-based inference already handles reset conservatively.
An added in-process regression ensures a range, resets the pool, performs a
payload store through the old index, then requires linked initialization on
another ensure. The dependent use rejects with the expected initialization
diagnostic. All five isolated stored-prefix acceptance tests pass. An initial
direct runner invocation used the wrong fixture working directory and failed
before compilation; rerunning from the fixture directory produced the test
result above. These results do not extend coverage to owner-based access yet.

Evidence: /tmp/takibi-stored-address-pilot/owner-reset-pool.{tkb,log}, its
executable, and stored-prefix-reset-tests.log. No runtime epoch field or new
trust contract has been added.

### Direct owner construction and projection summaries

An isolated record-transfer pass derives field-to-argument mappings from a
two-statement construction/return body and field projections from a direct
return. It uses resolved binding identities and declaration field order.
For the real FreelistOwner it derives index=arg0, generation=arg1 and the
index accessor's arg0.index projection. No function-name rule or range fact
is introduced; these are value-transfer summaries only.

In direct owner fixtures, changing the constructor to store generation in
index changes the summary to index=arg1; changing the accessor to read
generation changes its projection accordingly. Both controls compile. An
extra write after construction prevents a constructor summary, and renaming
the constructor preserves recognition. Initial controls in the full flattened
pool fixture also triggered pre-existing refined-range errors before this
analysis, so those failures are not evidence for the new summaries; direct
fixtures isolate the intended behavior. No mutated executable was run.

Evidence: /tmp/takibi-stored-address-pilot/lib/record_transfer.ml,
record-transfer-{positive,extra-write,renamed}.log and
record-direct-{changed-input,changed-projection}.log. Connecting a covered pop
result through these mappings is still required; construction alone neither
proves allocation nor survives invalidating pool mutations.

### Conditional coverage of the popped owner's field

The isolated pop analysis recognizes the actual complete freelist_core_insert
body: capture the head, compare it to the link-array capacity, return on
generation exhaustion, advance the head through that link, update a distinct
generation field through a write-free call, and return a directly constructed
owner in the success variant. It composes the constructor's field mapping
with the captured head. Under an entry covered-chain premise, it reports that
the returned FreelistOwner.index is the old head and the remaining chain stays
covered. The input chain premise is still conditional, not minted by this
analysis; no acceptance fact is granted yet.

The real allocation fixture and a renamed pop function produce the summary.
Returning the generation as the index compiles but produces none. Replacing
the next-head load with zero or adding a link write produces none and also
fails existing initialization checks. Initial controls used an ensure-only
fixture that did not instantiate pop, so absence of a summary there was not
valid evidence. They were replaced with actual insert consumers; the paired
unchanged and renamed controls now both instantiate and produce the summary.
No mutated executable was run.

Evidence: /tmp/takibi-stored-address-pilot/lib/pop_range.ml and
pop-range-{control,wrong-result,wrong-next,extra-write,renamed}.log. The remaining
composition must establish entry coverage from initialization/activation,
preserve it through finish/remove and invalidation, and associate the returned
field with the caller's current pool state before using it for a payload frame.

### Literal constructor state for the empty owner invariant

The isolated record-initialization pass derives literal usize field values
and full-array uniform values from straight-line assignments and counted
loops. It accepts only one parameter root, inline record paths, and full
declared array bounds; unknown statements reject the summary. Later writes
replace earlier values. It does not follow reference-valued interior fields
or treat metadata capacity as allocation coverage.

For the actual six-slot, three-chunk initializer it derives active_chunks=0,
core.free_head=6, core.next_generation=1, both three-entry chunk arrays zero,
all six occupancy entries zero, and the double-remove counter zero. These
are the concrete initial values needed for the empty covered-chain/occupancy
invariant, but the pass itself records values rather than granting an owner
coverage fact to callers.

Controls that initialize occupancy to one or overwrite the final head with
zero report those changed values, not the original ones. The occupancy mutant
still compiles; the head mutant fails existing initialization checks. An
early return prevents the summary and also fails existing checks. Renaming
the initializer preserves the derived values. No mutated executable was run.
Evidence: /tmp/takibi-stored-address-pilot/lib/record_init.ml and
record-init-{positive,occupied,head-overwrite,early-return,renamed}.log.

After the owner-source reporting passes were added, the isolated dune runtest
completed successfully, including 3124 compiler tests and five stored-prefix
acceptance tests. Evidence: owner-source-unit-suite.log. This checks the
isolated compiler, not a production integration or whole-tree build.

### Conditional finish-insert occupancy update

The isolated finish analysis composes direct owner-field projections with the
actual guarded occupancy store and final variant return. It checks the index
binding, declared array capacity, common owner argument and unchanged returned
owner, with no additional statements. Its summary requires prior occupancy
coverage and coverage of the specific owner field used as the index; it does
not grant that requirement merely because the argument is an owner.

The real body yields occupant_generation[owner.index] followed by the same
owner in Allocated. Storing to index zero instead or adding an active_chunks
write produces no summary. Using the generation projection instead changes
the required covered field to generation; it must not consume a pop summary
that only proves index coverage. Renaming the finish function preserves its
summary. All four controls compile under existing rules; none was executed.
This remains conditional source evidence, not an acceptance change.

Evidence: /tmp/takibi-stored-address-pilot/lib/finish_range.ml and
finish-range-{positive,wrong-slot,extra-write,different-field,renamed}.log.
The next composition must tie the actual pop payload binder to the finish
argument and check the same pool path and covered field, not just compatible
record types.

### Pop payload to finish argument at actual call sites

The isolated composition now uses the match arm's resolved payload binding,
the resolved pop/finish summaries, the exact covered field, and the caller's
pool field path. It recognizes both real insert paths: the initial pop and
the pop after growth/activation. The finish arm must immediately return the
call with that same payload; constructor type compatibility alone is not
enough. This remains conditional on coverage at the pop entry and the prior
occupancy invariant, not a whole-insert proof.

The actual two sites and renamed finish function produce reports. Changed
index-to-generation projection, substitution of a freshly constructed owner,
and an intervening active_chunks write produce none. All those controls
compile under existing rules. A separate two-pool bridge produces a report
when finishing against the source pool and none when finishing against the
other pool; both bridge controls compile. No mutated executable was run.

Evidence: /tmp/takibi-stored-address-pilot/lib/pop_finish.ml and
pop-finish-{positive,different-field,renamed,substitute-owner,intervening-write,
same-pool,other-pool}.log. No caller annotations or runtime checks were added.

### Conditional coverage through removal

The isolated single-push analysis derives the owner-field projection, metadata
capacity guard and ordered link/head writes from freelist_core_remove. Its
requirement is a covered input index and covered old chain. The pool-level
remove analysis then ties that same owner field to the actual occupancy
nonzero guard, matching clear, and push into the same pool's core. The empty
and outside-capacity arms return after write-free owner disposal; the empty
arm's counter update must not overlap the core, occupancy, or known growth
count/table fields.

Under the prior invariant that nonzero occupancy implies acquired coverage,
this discharges the push's covered-index requirement without a new runtime
check. It proves neither matching generations nor allocation uniqueness.
The prior invariant is still an obligation, not a fact inferred from the
owner type or granted unconditionally at entry.

Actual and renamed removers produce the conditional report. Inverting the
occupancy guard or clearing another slot produces none even though the
controls compile. Overlapping the counter with active_chunks or pushing to
the wrong link slot produces none and also fails existing checks. No mutated
executable was run. Evidence: /tmp/takibi-stored-address-pilot/lib/push_range.ml,
lib/remove_range.ml and remove-range-{control,inverted-guard,wrong-clear,
counter-overlap,wrong-push,renamed}.log. Whole-function/caller state composition
and acceptance integration remain outstanding.

### Whole insert-body composition under explicit entry premises

The isolated insert-body pass now requires the actual complete three-arm
initial pop, both payload-to-finish compositions, the guarded growth and
activation sequence, and the complete second pop. Both pops must target the
same resolved callee and pool core. Activation must write the exact link/head
paths that pop consumes, not merely another core within the same pool. Every
failure path returns a non-success result without additional statements.

The actual body and renamed pop produce a conditional whole-body report.
Failure-continues, different activation chunk, intervening state write,
substituted owner and changed finish index field produce none; all five
mutants still compile under current acceptance rules. No mutant executable
was run. The report retains entry acquired-prefix, covered-chain and occupancy
premises, growth separation and arithmetic geometry. It is not a caller
certificate, an unconditional allocation guarantee, or an acceptance change.

Evidence: /tmp/takibi-stored-address-pilot/lib/insert_body.ml and
insert-body-{pop-range-control,activation-call-failure-continues,
activation-call-different-chunk,activation-call-intervening-write,
pop-finish-substitute-owner,finish-range-different-field,pop-range-renamed}.log.

The isolated unit suite was rerun after finish, pop-call, push/remove and
whole-insert composition: 3124 compiler, three linked-certificate and five
stored-prefix tests passed. Evidence: insert-body-unit-suite.log. No allbuild
or allcheck claim follows from this isolated unit result.

### Concrete insert schema and matching empty constructor

The whole-insert composition now returns a structured conditional schema:
pool type/argument, count and address-table fields, exact chain paths,
occupancy field, owner field/result case, backing origin and global-write
separation requirements. It checks the actual address-table capacity against
the growth guard, occupancy capacity against the pop array, and positive
slots/chunks with chunks <= metadata_capacity / slots. Thus the product fits
the metadata bound without host-integer multiplication overflow. On the real
fixture this is three chunks times two slots within six metadata entries.
This schema still requires a valid entry invariant and separation; relative
pointer alignment/extent belongs to the accessor check.

A constructor pass matches source-derived field values to that exact pool
type/schema: count zero, head at least metadata capacity, and every occupancy
entry zero. The actual initializer matches; occupancy initialized to one,
head overwritten to zero and early return do not. The occupancy mutant still
compiles under current rules; the other two fail existing initialization
checks. Renaming the initializer retains the match. No mutated executable
was run. This constructs the empty-state description for future caller flow,
not an owner or an unconditional allocation certificate.

Evidence: /tmp/takibi-stored-address-pilot/lib/owner_constructor.ml,
insert-schema-positive.log and owner-constructor-{pop-range-control,
record-init-occupied,record-init-head-overwrite,record-init-early-return,
record-init-renamed}.log. Caller state transitions/invalidation and owner
payload-store acceptance remain to be connected.

### Caller flow from empty initialization to a returned owner

The isolated owner-flow pass now records the concrete schema for fresh inline
local pools, checks it at insert, follows the success arm's resolved payload
binding through a let-match yield, and retains that owner's originating pool.
Unknown writes discard facts; reinitialization invalidates old owners. Branch
joins retain only common facts and loops start without owner facts. Insert
retains only its target pool's facts, so this prototype remains conservative
for independent pools. No general heap or alias inference is introduced.

The same-pool control reports a covered owner use. The different-pool,
same-pool-reset, metadata-corruption and helper-created-uncovered-slot controls
do not. All compile under existing rules, and none was executed in this round.
The raw accessor's name is used only to print the diagnostic probe; snapshots
are recorded at all calls. No name-based access permission is granted. A
source-derived accessor mapping and alignment/extent checks are still needed
before these facts may justify a payload store.

Initially, initializing a second independent local pool discarded the first
pool's fact. The cause was applying the generic write invalidation before the
known constructor summary. The corrected path uses the checked constructor's
single inline target root and invalidates that pool's old owners only. The
paired two-local-pool positive and reset/corruption controls cover this overly
conservative behavior without relaxing unknown writes.

Evidence: /tmp/takibi-stored-address-pilot/lib/owner_flow.ml,
owner-flow-{owner-flow-same-pool,owner-wrong-pool,owner-reset-pool,
owner-finish-uncovered}.log and owner-flow-corrupted.log. Acceptance integration
and whole-tree verification remain outstanding.

### Owner-derived payload stores connected to initialization acceptance

The isolated owner accessor composes the exact owner-field projection with
the existing direct pointer accessor's geometry, relative extent and alignment
checks. It uses resolved callees, not an accessor-name permission. Owner flow
now preserves fresh local metadata across a covered payload store and supplies
that assignment's named backing-global origin to the existing Init_flow
invalidation path. Unknown stores still discard linked guarantees; the named
global's own aliases remain invalidated by the existing machinery.

A fixture initializes a pool, allocates an owner, stores through the actual
owner accessor, then allocates again. Before the connection, the second
allocation failed linked initialization. It now compiles, links to maintained
native startup/syscall objects and exits zero. Paired metadata-corruption,
pool-reset and wrong-divisor fixtures each exit compilation with status 1 and
the specific linked-initialization diagnostic. Status and message were checked
independently. None of those invalid fixtures was executed.

Six in-process owner acceptance tests cover the positive frame, corruption,
reset, wrong divisor, missing alignment, and a renamed owner accessor. They
pass alongside five existing prefix tests, three linked tests and 3124 compiler
tests. Their flattened fixtures remain isolated and need a maintained fixture
strategy before production integration.

The complete native GrowablePool compilation, without excluding its library
probe, now reports 15 initialization diagnostics instead of 17. Three library
owner stores receive derived frames, and the two remaining library-probe
diagnostics disappear; all 15 remaining diagnostics are in the application.
The overall command still fails. No extern trust, runtime tag, caller annotation
or production compiler integration was added. Static backing-object validity
remains a memory-model premise; this is not a whole-kernel safety proof.

Evidence: /tmp/takibi-stored-address-pilot/lib/owner_accessor.ml,
owner-frame-{before-connection,positive,corrupt,reset,divisor}.log,
owner-connected-full.log, owner-acceptance-suite.log and the positive native
executable. The fixture selection switch is used for focused controls only,
not the complete native compilation result above.

### External-output isolation and source-resolved acceptance fixtures

A control replaces only the exerciser's output calls with direct Takibi
no-op functions; all arguments, pool operations and conditional branches
remain in the source. The complete native compilation then succeeds instead
of reporting the remaining 15 initialization diagnostics. This isolates the
unknown external-output effect as the outstanding acceptance boundary. It is
not an equivalent executable test: output verdicts are absent, and the control
was not adopted or executed as the maintained test. The choice between
deferring real output and introducing an audited external frame remains open.
Evidence: /tmp/takibi-stored-address-pilot/growable-pool-no-output.{tkb,log}.

The isolated acceptance tests now resolve actual maintained library/provider
files through Use_resolver, with explicit dune source dependencies. Two small
entry fixtures replace the flattened source copies. All eleven prefix/owner
acceptance cases pass with this arrangement; the unchanged compiler and
linked suites were cached from their previous passing run. The old flattened
fixtures were moved to archived-fixtures for historical controls, not used by
the test runner. Evidence: test/test_stored_prefix.ml, test/dune,
test/{stored_prefix_case,owner_prefix_case}.tkb and
source-resolved-acceptance.log in the isolated workspace. Production integration
is still outstanding.

### Deferred native output with preserved transcript

The maintained native exerciser now returns from its pool operations before
flushing the transcript. Its target-specific console uses a bounded 2048-byte
buffer and the existing shared number formatter; no kernel console is changed.
Overflow exits with status 1 rather than silently truncating. The final write
checks for a short or failed syscall result. No memory_readonly contract is
introduced. This is test output storage, not a runtime initialization tag or
replacement for static pool validation.

The isolated analyses preserve fresh-local pool facts across known writes to
other named globals, excluding all globals modified by the checked page-growth
path. Parameter writes and unknown writes remain conservative. This derives
the buffer's separation from its Takibi body; it does not trust an extern.
The report's string walker uses a scalar offset so pointer rebinding does not
turn its footprint unknown. Existing initialization framing already handles
the resulting named-global writes.

Using the isolated compiler through the root Makefile's real native target,
the complete exerciser now compiles, links and exits zero. Its output matches
the existing 1326-byte expected file byte-for-byte. A separate early-return
control retains its failure text; a deliberately eight-byte report buffer
exits with status 1. Neither control replaces the maintained success verdict.

The source and Makefile changes are in the main worktree; compiler inference
changes are still isolated, so this is not a production-compiler or allbuild
claim. Evidence: /tmp/takibi-stored-address-pilot/deferred-root-build.log,
deferred-root.out, deferred-{early,overflow}.{log,out}, and
deferred-acceptance-suite.log. Remaining work includes compiler integration,
whole-tree builds and the required aggregate checks.

### Whole-native migration after stored-address integration

A keep-going native build found three remaining fixtures after migrating the
memset/memcpy demo: alignment, TCP parsing and FDT parsing. This census is
stronger than repeatedly stopping at the first failed native target.

- The five-byte memory demo now uses bounded borrowed slices, a refined
  count and explicit initialized-prefix postconditions. Bodies retain their
  original counted writes; there is no extra clear or trusted assertion.
  Slice arithmetic now imports immutable scalar parameter refinements and
  slice minimum lengths when ordinary path facts do not suffice. The existing
  Z3 index obligations retain those premises.
- The shared native network writers declare their actual two- and four-byte
  output prefixes through checked borrow-uninit contracts. TCP's pseudo-header
  no longer relies on an ordinary mutable argument implying initialization.
- FDT's fixed global byte arrays already have exact sizes. The checker now
  retains those lengths through byte-slice casts when applying slice_copy's
  existing minimum-of-source-and-destination rule. No FDT source change or
  additional initialization is needed.
- The maintainer approved clearing only the alignment fixture's 32-byte
  local buffer before its address-to-integer conversion. This preserves the
  address-alignment verdict and does not resolve or relax the general
  uninitialized-address-erasure boundary.

The mem, TCP and FDT executables compile and reproduce their existing expected
output byte-for-byte. Four compiler regression cases cover trap-free bounded
prefix writes and global-byte-array copies, with suffix-read rejection controls.
The unit suite passes. Earlier native fixtures exercised execution but did not
assert that these arithmetic premises reached the initialization checker;
the new controls do so through generated indexing code as well as acceptance.
The responsibility belongs in the OCaml compiler, not an external source scan.

Whole-kernel compilation also exercises a tight allocation budget. Importing
all parameter facts eagerly exceeded it; the implementation now uses a cold
fallback, avoids re-solving unchanged facts, and constructs parameter tables
without temporary lists/options. The QEMU object gate passes at 742,959,122
words under the unchanged 743,000,000-word limit. The final allbuild and
linuxcheck pass; clean allcheck and publication remain outstanding. Evidence:
/tmp/takibi-stored-address-pilot/{mem-contract-build.log,mem-contract.out,
native-census.log,native-migration-build.log,native-migration-tests.log,
fdt-migration.out,tcp-migration.out,integrated-allbuild-native.log}.
The final successful logs are integrated-allbuild-final.log,
integrated-linuxcheck.log and native-allocation-final.log in that directory.

### Integration annotation inventory

The 2026-11-17 working-tree diff against e971bc2f, including new maintained
Takibi files, adds the following source lines. These are textual line counts,
not instantiated contracts, proved properties, or a memory-safety percentage.
A line may appear in more than one column. No corresponding removed lines
contain these forms in this diff.

| Maintained surface | requires | ensures | borrow uninit | assume_init | zero_fill |
| --- | ---: | ---: | ---: | ---: | ---: |
| kernel | 19 | 50 | 63 | 19 | 1 |
| linux_user | 29 | 20 | 21 | 1 | 4 |

The assume_init entries are explicit trust-boundary assertions, counted
separately from checked pre/postconditions; their audited scopes are listed in
TRUSTED_BASE.md. The kernel zero_fill line writes the crash-trace tail beyond
the audited assembly output. Native clears include the approved alignment
fixture and representation tests, not a GrowablePool initialization flag.
No new static_assert line is added in this diff. Existing assertions and
earlier published annotations are outside this incremental count. The
stored-address/owner inference itself adds no per-access annotation.
