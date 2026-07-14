# Ownership Kernel -- Design Memo

Status: DESIGN MEMO, not yet language spec. Stage 1 below is written to be
normative once approved; Stages 2-4 are outlooks recorded so Stage 1's
semantics are not designed into a corner. As each stage lands, its final
behavior moves into SPEC.md (the authoritative description of the language
as it exists) and this memo's corresponding section shrinks to a pointer.

Driving issues: #117 (witness tokens / protocol obligations -- where this
plan was drawn up), #89 (affine drop/escape/inter-function), #108
(private visibility), #15 (safe pointer / cast audit), #113 (channel v2),
#20 (variant enums), #106 (aliasing), #87 (async TX ownership).

## 1. Motivation: one wall, four axes

Several open issues looked independently expensive, but are faces of one
restriction: what the type system can track about a VALUE'S KIND today is

  (a) function-local only (no cross-function state beyond parameter modes),
  (b) named local variables only (no struct fields, array slots, globals),
  (c) silently exitable via `as` casts,
  (d) guarded by visibility only at file x top-level-global granularity.

Every distortion currently visible in examples/ maps to one of these axes:
null-sentinel tokens + out-parameter lengths (no sum types, #20), forgeable
`N as usize as *Token` mints (c + #108), FatFile's `&file_storage`
singleton trick and the sanctioned index-escape workaround (b, #89 Hurdle
3), UsizeChan/WordChan copies (#113), and silently-swallowable protocol
events (no obligation kind at all). These cannot be designed one at a time
without rework; this memo fixes the shared design once, and stages the
implementation so every stage lands with its own PoC examples.

## 2. Doctrine this design serves (settled with the user, issue #117)

- **The trust root is a narrow, human-reviewed takibi file.** No DSL,
  transition table, or conformance tool is trusted to close the
  spec-vs-implementation gap -- a human signs off on that either way. The
  language's job is to make everything OUTSIDE the reviewed file unable to
  act except through it.
- **Co-location over tokens, where possible.** A witness token is a device
  for coupling two calls separated by unreviewable distance. If the
  coupling fits inside the trusted file (action call directly beside state
  write), no token is needed. Kinds (affine/linear) are for couplings that
  CANNOT be co-located: ownership crossing tasks, ISRs, or time.
- **No test-based exhaustiveness.** State spaces in embedded software
  explode faster than test enumeration; coverage is the type system's and
  the reviewed file's job, not the test suite's.
- **The tripwire.** If kind-carrying values start needing to cross function
  boundaries as threaded parameters in ordinary application logic (the
  ATS2 at-view plumbing burden), stop and reconsider checker-level flow
  analysis instead of threading harder.

## 3. The kind lattice

| kind | guarantee | check discipline | primary use |
|---|---|---|---|
| unrestricted (default) | none | none | plain data |
| `affine` (exists) | used AT MOST once; must be consumed on at least one path | union of branch moved-sets | resource handles that may be conditionally acquired (NetRxCpuOwned's null sentinel, FatFile, KGuard) |
| `linear` (Stage 1, new) | used EXACTLY once on EVERY path | intersection of branch moved-sets | obligations: "this MUST be answered/released/forwarded" (protocol events, channel receives, in-flight DMA) |

`affine` keeps its current, deliberately weak must-consume (consumed on at
least one path counts), because its idiomatic use is inseparable from the
null-sentinel conditional-consumption pattern, which genuinely cannot be
checked stronger without relational reasoning (see 4.6). `linear` is the
kind you pick when you want the stronger promise -- and its rules make the
null-sentinel pattern inexpressible, which is exactly what keeps its
checker a plain dataflow analysis.

## 4. Stage 1: the `linear` kind (normative once approved)

### 4.1 Syntax

    linear opaque struct PendingTcpEvent;

Parallel to `affine opaque struct`. Like affine, the type is nominal,
incomplete (usable only behind a pointer), and participates in kind
tracking only via `*Name` pointers. `linear` becomes a keyword.

### 4.2 Core semantics

Creation: any expression of type `*L` (L linear) creates an obligation in
the creating function: a call returning `*L`, or an integer-to-`*L` cast
(see 4.3). The obligation attaches to the local variable that receives it.

Consumption events (same three as affine):
  - passing the value as a plain (non-`borrow`) `*L` argument,
  - passing it to a `sink *L` parameter,
  - returning it (when the function's return type is `*L`).

To be explicit about what IS allowed (review feedback): linear values pass
through function signatures freely -- taking them as parameters and
returning them are not restrictions but the very definition of
consumption. Branching AROUND a linear value is also fine:
`if (cond) { sink_a(p); } else { sink_b(p); }` satisfies the all-paths
rule (each path consumes once). What is excluded is branching ON the
token itself -- its bits (nullness) or its contents (it is opaque). The
idiom for content-dependent dispatch is a companion plain enum traveling
beside the obligation (TcpEvent beside PendingTcpEvent): branch on the
data, discharge the obligation in every arm. When the token itself needs
to carry data, that is Stage 4's linear variant enums, where `match`
becomes the fourth consumption event (destructuring consumption, as in
Rust's match on an owned enum) -- a planned extension of these semantics,
not a redesign.

Initialization: a linear local must be initialized at its declaration
(`let p: *L;` with no initializer is an error). This keeps the
reassignment-discard rule below simple: every linear variable holds a
live obligation from birth.

The all-paths rule: at the end of the scope that declared it (function
body, if/else branch, match arm, loop body, block), a linear local must be
DEFINITELY consumed -- consumed on every path that reaches the scope end.
Implementation-wise the checker carries two sets where affine carries one:

  - `moved_any` (union at merges) -- governs double-consume errors, exactly
    as affine's `moved` does today;
  - `moved_all` (intersection at merges) -- governs the definite-consumption
    check for linear locals.

A branch that always terminates (returns on every path -- the same
syntactic `always_terminates` refinement affine already uses) is excluded
from both merges: code after the `if`/`match` never sees that branch.

Errors (messages name the variable and its declaration site, with line
numbers per issue #107):
  - never consumed on any path: `linear value 'x' is never consumed`
  - consumed on some but not all paths:
    `linear value 'x' is not consumed on every path (consumed in only some
    branches of the if/match at line N)`
  - double consume: same message as affine today.

Loops: identical restriction to affine (a linear value declared outside a
loop cannot be consumed inside it; declared-and-consumed within one
iteration is fine, enforced by the loop body being a scope).

Early exits (soundness holes affine tolerates but linear must not --
found while working out the checker; each control-flow exit needs its own
check, since the scope-end check only covers falling off the end):
  - `return` anywhere: every linear variable in scope that is not
    definitely consumed by that point (other than the value being
    returned, which the return itself consumes) is an error. Affine's
    union check silently accepts a return path that leaks; linear cannot.
  - `break`/`continue`: any linear variable pending (declared, not
    definitely consumed) at the statement is an error. Deliberately
    conservative: this also rejects a pending obligation declared OUTSIDE
    the loop that would have been consumed after it -- v1 does not track
    loop-boundary ownership precisely; restructure (consume before the
    loop, or avoid break) if this fires. Documented limitation, revisit
    only if it bites a real example.

Reassignment: assigning to a variable that holds a NOT-yet-definitely-
consumed linear value is an error (`assigning over linear value 'x' would
discard its obligation`). This differs from affine, where reassignment
clears consumed status (the cond_wait drop-and-reacquire idiom); for
linear, overwrite is a silent discard and must be rejected. Reassigning
after definite consumption is fine and starts a fresh obligation.

### 4.3 Cast rules (the asymmetry is the point)

  - integer -> `*L`: ALLOWED, same rules as affine today (literal is fine;
    non-literal requires `unsafe { ... }`). Forging an obligation is the
    SAFE direction: the forged value must itself be consumed on every
    path. Until Stage 2 (private types) this is also the only way the
    trusted file's mint functions can work.
  - `*L` -> anything (`as usize`, `as *Other`): FORBIDDEN, hard error, no
    `unsafe` escape in v1. Casting away is the UNSAFE direction -- it
    silently discards the obligation. This deliberately also outlaws the
    `(p as usize) != 0` null-check idiom on linear values: linear tokens
    are never-null by design (see 4.6).

### 4.4 Storage restrictions (v1)

A linear value may not be stored anywhere the tracker cannot see:
  - RHS of a struct-field write, array-element write, or write through a
    pointer, when the RHS type is `*L`: error.
  - a struct field, array element, or global declared with type `*L`:
    error at the declaration.
  - a linear value inside a struct literal: error.
Lifting these is exactly Stage 3 (place tracking); v1 rejects rather than
silently un-tracks, because silent escape for an obligation is unsound in
a way that affine's silent escape is merely weak.

### 4.5 Parameter modes and extern fn

`borrow *L` (non-consuming) and `sink *L` (terminal consumer) work as for
affine; the existing "borrow/sink only on affine opaque struct pointers"
validation widens to "affine or linear". A plain `*L` parameter transfers
the obligation into the callee: the callee must forward, return, or sink
it (the never-consumed-parameter check affine has today, but with
all-paths strength). An `extern fn` taking `*L`/`sink *L` is part of the
trusted surface, like all extern signatures.

### 4.6 Why this dodges the relational-logic wall

Issue #89's thread correctly noted that upgrading AFFINE's must-consume
from union to intersection needs relational reasoning: affine's idiomatic
pattern is `let p = acquire(); if ((p as usize) != 0) { ...; release(p); }`
where consumption is gated behind a nullness check the dataflow cannot
correlate. Linear avoids the wall by CONSTRUCTION, not by solving it: the
`*L -> usize` cast ban makes the nullness check inexpressible, so a linear
value's consumption can never be legitimately conditional, so plain
intersection dataflow is exact, no solver needed. Fallible operations that
would have returned "token or null" must instead keep the fallible part
OUTSIDE the linear world (return a plain status, as the co-located
transition functions in http_conn_state.tkb already do) or wait for #20's
variant enums (`Result`-shaped returns) in Stage 4.

### 4.7 Non-goals in v1

No linear struct fields/slots (Stage 3). No linear values crossing
task/ISR boundaries (Stage 3/4 -- channels). No RAII/defer-style automatic
discharge. No `unsafe` escape for the cast-away ban (add only if a real
need appears; YAGNI). No change to affine's existing semantics -- every
currently-compiling program keeps compiling.

### 4.8 Implementation sketch

  - lexer.mll: `linear` keyword.
  - parser.mly: `LINEAR OPAQUE STRUCT IDENT SEMI`.
  - ast.ml: `OpaqueStructDef of string * kind` where kind distinguishes
    plain/affine/linear (today: `* bool`).
  - type_inf.ml: `linear_opaque_names` set beside `affine_opaque_names`;
    `check_affine_func` grows the second (`moved_all`, intersection) set
    and the linear-specific errors (all-paths, reassign-discard,
    cast-away, storage rejection); `check_affine_ptr_cast_needs_unsafe`
    and the borrow/sink validation widen to linear names.
  - llvm_gen.ml: nothing (opaque pointers codegen identically to affine).
  - test/test_takibi.ml: unit tests per rule, positive and negative.
  - scripts/run_qemutest.sh: `run_compile_error_test` registrations for
    the negative examples.

### 4.9 PoC examples (acceptance gate for the stage)

  - `examples/linear_obligation/` (positive): create + discharge across
    if/else, match, early return; runs under QEMU and prints proof of
    execution. Compiles `--forbid-trap` clean.
  - `examples/linear_never_consumed/` (negative): mirror of
    affine_never_consumed; expects `linear value 'x' is never consumed`.
  - `examples/linear_branch_missed/` (negative): consumed in the `if`
    branch only -- THE case affine cannot catch; expects the
    not-on-every-path error. This example is the stage's reason to exist.
  - `examples/linear_cast_discard/` (negative): `p as usize` on a linear
    value; expects the cast-away error.
  - `examples/linear_overwrite/` (negative): reassignment over an
    undischarged obligation.

Stage 1 is DONE when: all five PoCs behave as specified, the full existing
suite stays green (unit + qemutest + stm32build + langcheck), and the
first real application below compiles and passes qemutest + hwcheck-net.

### 4.10 First real application: PendingTcpEvent

In http_conn_state.tkb: `linear opaque struct PendingTcpEvent;` plus a
mint function, and every transition/coupling function gains a leading
`pending: sink *PendingTcpEvent` parameter; a new
`tcp_event_ignored(pending: sink *PendingTcpEvent)` is the one legal way
to deliberately not respond. In http_server_common.tkb's poll loop, one
obligation is minted per accepted TCP segment (after the port check,
before the state dispatch); the all-paths rule then forces every (state x
event) arm -- and, notably, the currently-implicit `if
(tcp_remote_matches(...))` else-path (segment from an unknown peer) -- to
either reach a coupling function or contain an explicit, greppable
`tcp_event_ignored(pending)`. Silent swallowing of a protocol event stops
compiling; that is this stage's payoff for issue #117.

## 5. Stage 2: private types and fields (#108) + cast tightening (#15)
## (normative once approved)

Goal: turn the trusted-narrow-file methodology from convention into
language guarantee. Usage survey before design (2026-07-14): every
existing mint site (`N as usize as *Handle`, `&global as *Handle`)
already lives in the file that declares its handle type -- fat12.tkb
mints FatFile, eth.tkb/virtio_mmio.tkb mint NetRxCpuOwned, rtos.tkb
mints KGuard, http_conn_state.tkb mints PendingTcpEvent -- and there are
ZERO pointer-to-pointer cast-aways from affine handles anywhere. Stage 2
therefore breaks no existing code: it makes the boundary everyone
already respects impossible to stop respecting.

### 5.1 Part A: `private` on opaque struct declarations

    private linear opaque struct PendingTcpEvent;
    private affine opaque struct KGuard;

Semantics: value CONSTRUCTION of a private opaque type -- any cast whose
TARGET type mentions it (`N as usize as *T`, `&x as *T`) -- is legal only
in the declaring file. NAMING the type stays legal everywhere
(annotations, parameter types, passing values around): the wide file must
still be able to write `let pending: *PendingTcpEvent = ...` and hold the
value; what it cannot do is conjure one. Combined with 4.3's rules this
closes cross-file forgery completely: outside the declaring file, the
only sources of a private handle are the declaring file's own exported
functions. Scope note: `private` applies to OPAQUE struct declarations
only (all three kinds) -- type-level privacy for regular structs/enums
has no driver today and waits for one (fields get their own mechanism,
Part B).

### 5.2 Part B: `private` on struct fields

    struct Chan {
        private seq:  u32;
        private slot: i32;
    }

Semantics: a field marked `private` may be read (FieldGet, including
through `&s.f`), written (AssignField), or named in `offsetof` only from
the struct's declaring file. Constructing a struct that HAS any private
field via a struct literal is likewise declaring-file-only (a positional
literal writes every field, private ones included -- this is what makes
smart constructors real: issue #108's original "hand-assembled FatFile"
gap, applied to non-opaque structs). This turns the accessor idiom
(KGuard's `borrow`-gated getters, documented since examples/klock_guard
as "naming convention only") into an enforced boundary.

Implementation note: privacy is per-field, recorded beside the field
list (the AST's StructDef gains the private-field names and its own
declaration loc; Type_layout and codegen are unaffected -- privacy is a
type-checking concern only, with zero layout/runtime footprint).

### 5.3 Part C: cast and arithmetic tightening (#15 direction)

Revised in review (2026-07-14) after the user asked "can you do
arithmetic on an affine/linear pointer?" and a probe confirmed a real
hole: `let q: *Tok = t + 1;` PASSES type inference and kind checking
(BinOp operands are walked non-consuming, so `q` is a second tracked
value conjured without consuming `t` -- kind-level duplication), and is
stopped only by an ACCIDENT: opaque types have no layout, so LLVM's GEP
is invalid and the compiler dies with an internal error instead of a
diagnostic. Two tightenings:

1. **Pointer arithmetic requires a complete (sized) pointee.** `p + n` /
   `p - n` / `p[i]` on a pointer to ANY opaque struct (plain, affine, or
   linear) is a type error -- the same rule C has for incomplete types.
   This closes the kind-duplication hole for every handle type (all
   kind-carrying types are opaque today) and turns the ICE into a real
   diagnostic for plain opaque pointers too. Hard error, no `unsafe`
   escape: there is no legitimate use (survey: zero occurrences).
2. **Casting an AFFINE handle to another POINTER type** (`t as *Other`
   -- kind laundering into a differently-typed alias) requires
   `unsafe { ... }`. Zero existing uses; SPEC.md itself documented the
   hole.

The null-check idiom `t as usize` on AFFINE handles stays untouched: it
is memory-safe (reads bits, aliases nothing usable -- re-minting the
bits back into a handle is construction, gated by Part A/4.3), and it is
the codebase's sanctioned encoding of "acquired or not". **Recorded
ratchet**: that idiom exists only because takibi lacks Option/Result
(issue #20) -- acquire-may-fail has no other encoding. When Stage 4
lands variant enums and acquisition returns Option-shaped values,
`as usize` on affine handles should be banned too, at which point affine
handles become as bit-opaque as linear ones already are (linear's total
cast ban means a linear token's pointer-ness is observationally
invisible today -- it is already, in effect, the value-less unit
capability).

### 5.3.1 Recorded design note: should handles carry values? (user review)

Two populations exist in today's code: pure tokens whose bit pattern is
meaningless (KGuard, PendingTcpEvent, SlotLease) and identity-carrying
handles (FatFile = the address of real storage, NetRxCpuOwned = a
descriptor identity). At the TYPE level both are pure tokens: `opaque`
means no one -- owner included -- can touch the pointee from takibi
source, so resource state lives in module-private storage and the
module's functions (which demand the handle) are the only access path.
"Ownership gates access" is thus implemented INDIRECTLY today: handle =
capability witness, functions = the gate.

The user's model for the direct version -- a handle that really carries
a pointer, where (a) the pointer value is immutable from mint to
consumption and (b) the POINTEE is readable/writable exactly while the
handle is owned -- is the correct spec for content-carrying handles
(zero-copy channel payload buffers want precisely this), and it is the
"decouple affine from opaque" question already recorded in
affine_escape_via_index's header. It belongs to Stage 3's place-tracking
neighborhood (an `affine struct` WITH fields whose access requires the
live handle), with ATS2's at-view and Rust's Box/&mut as the prior art.
Until then, tokens that are "really just a usize" stay encoded as opaque
pointers for one honest reason: the tracking machinery is keyed on
pointer-to-nominal-struct types, and introducing a separate value-less
token kind now would duplicate machinery that Stage 4's payload-less
linear variant enums subsume anyway.

### 5.4 Application (acceptance gate)

- `private` on PendingTcpEvent (http_conn_state.tkb): minting outside
  the trusted file becomes a compile error -- negative-test it from
  http_server_common.tkb.
- rtos.tkb: `private` on KGuard's type and on Chan/KLock internal fields
  -- the RTOS task-facing API's internals become untouchable from every
  example that uses it, which is the syscall-surface discipline issue
  #108's discussion with issue #67 called for.
- Existing suite stays green untouched (per the survey); PoC compile-
  error examples for: cross-file mint of a private opaque type,
  cross-file read/write of a private field, cross-file struct literal,
  un-unsafe'd affine ptr-to-ptr cast.

## 5.9 Interlude between Stages 2 and 3: function-local tuples (#120)
## (normative once approved -- user-driven design reversal, 2026-07-14)

Issue #120 originally recommended Go-style multiple returns over
first-class tuples, to sidestep the container/place question. User
review reversed this, with an argument that stands: the roadmap for
content-carrying handles is (1) kinds carry no content today, (2) pair
the kind token with its data behind a tuple while usage patterns
accumulate, (3) design native content-carrying from those observed
patterns. Go-style multi-return generates NO observations for (3) --
the pair exists only at the call boundary and scatters into separate
locals at every receiver, so "which pairs travel together, and how" is
never visible in code. The pair must be a first-class value INSIDE
function bodies for the experiment to produce data.

The container objection is neutralized by construction, not by place
tracking:

- **Join-kind rule**: kind(tuple) = max of component kinds
  (unrestricted < affine < linear). A linear-containing tuple IS a
  linear value and inherits every Stage 1 rule at the granularity of
  the tuple variable itself: all-paths consumption, no cast, no
  storage, no overwrite while live, early-exit checks.
- **Destructuring is the only elimination** (v1): `let (a, b) = e;`
  consumes the tuple and births each component as a fresh tracked
  binding (inference records component types in raw_locals, so
  unannotated destructured obligations stay tracked). No `.0`/`.1`
  projection: projecting out of a kinded tuple is partial access,
  i.e. exactly the place-tracking question Stage 3 owns; banning it
  keeps tracking variable-granular and function-local.
- **Tuples are values, not storage**: allowed as function return types,
  parameter types, locals, and literals `(e1, e2)`; rejected in struct
  fields, arrays/slices, globals, writes through pointers, and casts
  (either direction). Stage 3 revisits.
- **Construction moves**: a tracked component of a tuple literal is
  consumed exactly when the literal itself flows into a consuming
  position (bound, passed, returned); a discarded literal consumes
  nothing, so obligations never vanish into a dropped temporary.

Codegen: an LLVM literal struct; construction by insertvalue,
destructuring by extractvalue; ABI lowering for by-value aggregates is
LLVM's problem and verified on both targets.

Resolved-by-default in review (flag if wrong): no projection (above);
no annotations on destructure bindings (types come from the RHS); no
`mut` destructure bindings; nesting allowed (uniform recursion); no
1-tuples or unit tuples. Honest limit, recorded: tuples are products --
"consume on success, hand back on failure" (tcp_respond's real
signature) still needs a SUM (#20, Stage 4); what tuples unlock now is
try-style APIs that always return the obligation paired with data, and
mint/recv APIs returning (data, obligation).

## 6. Stage 3: places (#89 Hurdle 3)

### 6.1 Finding that reframed this stage (2026-07-14, user-directed probe)

Before any design work, a direct probe asked: what actually happens
today if an affine handle is stored in a struct field? Answer: it
already compiles (SPEC's "deliberately restricted" bullet only says the
CHECKER doesn't track it, not that storage is syntactically banned), and
it is completely UNTRACKED -- consuming the same field twice compiled
with no error at all. So Stage 3 is not "lifting a ban", it is closing a
real, silent double-consume hole that exists in the language today. This
reframing is why the stage was split:

- **Stage 3a** (this section, implemented): intraprocedural PATH
  tracking, closing the concrete hole above with the SAME machinery
  Stage 1 already built, generalized to a slightly richer key. No new
  concepts, no interprocedural reasoning.
- **Stage 3b** (still outlook, section 6.5): the genuinely hard part --
  identities that escape the acquiring function (the fd-table shape).
  Deferred until Stage 3a has real usage to observe, per the same
  "prove it with a driver before designing further" discipline every
  earlier stage followed. User decision (2026-07-14): implement 3a now,
  revisit 3b once 3a has concrete examples.

### 6.2 Stage 3a: intraprocedural field-path tracking (normative, implemented)

**Scope, deliberately narrow.** A `path` is either a bare local/parameter
name, or ONE level of field projection through a bare local/parameter
name (`h.t`). `f().t`, `arr[i].t`, and any deeper chain (`h.a.b`) are NOT
paths -- they have no stable syntactic identity to key tracking on
without either an alloca-address analysis or relational reasoning about
index equality (the same wall that keeps affine's null-sentinel idiom
union-based, see 4.6). Expressions of this shape simply fall back to
pre-Stage-3a behavior (untracked), exactly as before -- this is not a
new hole, it is the existing hole left unaddressed outside the newly
covered shape.

**AFFINE only.** LINEAR struct fields remain banned at the type
declaration (Stage 1's `type_mentions_linear` check, unchanged).
Extending linear's stronger ALL-PATHS guarantee through fields needs a
form of definite-assignment/partial-move analysis (was every field of a
partially-consumed struct discharged by scope end?) -- a materially
bigger step than affine's weaker union check gets for free by reusing
the existing machinery. Left for its own increment if a concrete need
appears (no driver for it today: the one real use of struct-field-shaped
storage in this codebase, `examples/affine_escape_via_index`, stores a
plain integer index specifically BECAUSE affine escape wasn't
trackable -- see 6.1's finding for why that pattern remains correct for
cross-function escape regardless of this stage).

**Mechanics.** The single `moved : StringSet.t`-keyed tracking Stage 1/2
built now keys on `path = PVar of string | PField of string * string`
instead of a bare `string`. `FieldGet(Var base, fname)` and
`AssignField(Var base, fname, rhs)` are checked exactly like `Var
name`/`Assign` were, when `(base, fname)` resolves (via `senv`, the same
struct-field environment `infer_expr` already uses) to a field of AFFINE
pointer type. Every other Stage 1/2 rule (double-consume, never-consumed
union check, the return/break/continue early-exit checks, loop
restrictions) applies to `PField` paths exactly as it already applies to
`PVar` paths -- no new rules, only a richer key.

**A finding worth keeping, not a limitation:** returning the WHOLE
containing struct (`fn f() -> Holder { ...; return h; }`) does NOT
discharge a still-pending field obligation, and this is correct, not an
oversight -- `Holder` itself is a plain, untracked type, so if returning
it silently satisfied `h.t`'s obligation, the obligation would vanish at
the caller with no further enforcement anywhere. Confirmed by test
during implementation (an initial test assumed this should compile;
it correctly does not).

**Two-different-locals soundness note.** `h1.t` and `h2.t` (two
variables of the same struct type) are always distinct paths, keyed by
the LOCAL NAME, not a resolved address -- correct for the common case
(two genuinely separate local structs), but not a full aliasing proof:
if two names somehow denoted the SAME storage (e.g. through pointer
aliasing this checker does not reason about), tracking could be fooled.
This is the same class of restriction Stage 1 already accepted for
plain locals (SPEC's "no cross-function or struct-field-level tracking,"
now narrowed rather than removed) -- not a new gap introduced here.

Validation: 8 new unit tests, 3 QEMU PoC examples (field_lease positive;
field_double_consume_wrong, field_never_consumed_wrong negative), full
suite green (600 unit / 101 qemutest / stm32build / langcheck).

### 6.5 Stage 3b outlook: escaping identities (the fd-table shape)

Still open, deliberately not designed further until 3a produces real
examples to observe (per the user's explicit sequencing decision). The
existing answer, `examples/affine_escape_via_index`'s index + runtime
`in_use`-flag idiom, remains the correct pattern for this shape in the
meantime -- Stage 3a does not change or supersede it. Candidate framing
for whenever this is revisited: codify that hand-written idiom
(escaping identity = plain refined index, real state = a slot table,
occupancy = a checked runtime flag) into a compiler-recognized shape,
consistent with the #66 doctrine's third reduction ("what remains
genuinely shared is a small fixed vocabulary, verified once by non-type
means, with only its usage contract enforced by types") -- rather than
attempting full interprocedural ownership/alias analysis, which this
project has repeatedly and deliberately ruled out.

**Experiment tried and ruled out (2026-07-14): pairing `(idx, lease)` as
a tuple.** Before designing further, the user asked whether
`affine_escape_via_index.tkb`'s `slot_read(idx: {0..<4 as usize}, lease:
borrow *SlotLease)`-shaped signatures would become easier to reason
about if `idx` and `lease` traveled together as one tuple. Tried
mechanically, both ways:

- `fn slot_read(session: borrow (usize, *SlotLease)) -> i32` does not
  compile: `borrow`/`sink` are gated to a pointer-to-opaque-struct
  parameter type only (Stage 1/2's own restriction), not tuples, so
  "borrow a tuple" is not expressible today.
- `fn slot_read(session: (usize, *SlotLease)) -> i32` (owning) compiles,
  but `slot_read` then consumes the whole pair, including the lease
  inside it -- so the SAME idx+lease cannot be handed to the following
  `slot_write`/`slot_close` calls (the actual usage shape in the
  example) without re-leasing or threading the tuple back out of every
  call. Strictly worse ceremony than today's two-plain-parameters form.

**Why this is still a useful negative result, not a dead end.** The
failure exposes what was actually being asked for, more precisely than
before: not "co-locate idx and lease as one value" (a tuple gives only
syntactic bundling) but "make `lease` provably ABOUT `idx`" (a semantic
binding). A tuple does not enforce that relationship either --
`(3, lease_that_was_actually_minted_for_slot_1)` type-checks fine as a
tuple, exactly as it does as two loose parameters today; nothing changed.
What would actually enforce the relationship is `SlotLease` carrying
`idx` AS DATA inside itself (so `slot_read` reads the slot number off
the lease it was handed, instead of trusting two independently-supplied
arguments to agree) -- which is precisely section 5.3.1's still-open
question ("should handles carry values, decoupled from `opaque`") aimed
at a Stage 3b driver instead of an abstractly-motivated one. **Tuples
were valuable here as an experiment, not as the mechanism**: pairing
data is not the same problem as binding data, and Stage 3b's design
should start from 5.3.1 (content-carrying handles) rather than from
tuples, when it resumes.

### 6.6 Evidence re-assessed, and the design fork this stage actually faces (2026-07-14)

**On whether "real examples" are needed before starting**: settled. The user's counter-argument
is accepted -- the codebase does not need a NEW driver beyond `affine_escape_via_index.tkb`,
because the SYSTEMIC evidence is already there: `FatFile` (global-singleton via the
`&file_storage` trick), `NetRxCpuOwned` (hard-coded to one live slot), `KGuard` (a giant lock
standing in for what should be N independent locks) are three unrelated features that all hit
the SAME wall (`affine opaque` cannot express multiple simultaneous instances) and all took the
SAME workaround (collapse to a singleton). Leaving `affine opaque` as-is guarantees this pattern
keeps reproducing. That is sufficient grounds to proceed with design.

**The real question raised: is this stage secretly reinventing Rust ownership?** Valid concern,
and the fork it forces is the actual content of this stage. The design space, laid out honestly:

- **(A) Content-carrying handles with owned field access** -- `affine struct Lease { idx: usize
  }`, fields readable only while the handle is live. This genuinely IS a slice of Rust's
  ownership model (an owned record with move semantics), and the slope behind it is real: field
  access invites wanting borrows of fields, which invites re-borrowing, which invites lifetimes
  -- the Rust-shaped mirror of the ATS2 at-view slope the project already rejected once (CLAUDE.md
  records Rust's ownership model as evaluated and judged unsuited to bare-metal kernel code for
  this project's purpose). **Not adopted.** No driver in this codebase has ever needed owned
  field access -- every existing affine handle (FatFile, NetRxCpuOwned, KGuard) is accessed
  exclusively through module-mediated functions (`fat_read(fp)`, `net_rx_frame(acquired)`), never
  by reading a field directly. Revisit only if a concrete case defeats function-mediated access.
- **(B1) ATS2-style dependent/indexed typing** -- a static index variable `n` universally
  quantified and threaded through every signature that touches the resource
  (`idx: int(n), lease: !slot_lease(n)`). This is what "type-level index binding" naturally means
  in the ATS2 tradition the project cites as ancestor. **Explicitly ruled out**: this is exactly
  the proof-parameter-threading-through-ordinary-signatures shape the issue #117 tripwire exists
  to stop. B1 is not a future destination, it is the thing the tripwire was built to prevent this
  project from drifting into.
- **(B2) Index living IN the handle's type, not threaded through call sites** -- e.g.
  `fn slot_lease(idx: {0..<4 as usize}) -> *SlotLease{idx}`, where the refinement is fixed at
  mint time inside the trusted file and every other function just carries `lease: borrow
  *SlotLease` with no index parameter anywhere in its signature. This is takibi's actual
  destination for "type-level index binding" -- structurally different from B1 despite the
  surface-level resemblance, precisely because ordinary application code never sees or threads a
  static index. **Committed as the direction**, not yet implemented (needs its own design pass:
  how a mint-time refinement attaches to an opaque handle type, and how much of "same idx across
  calls" can be proven by plain flow-sensitive tracking -- reusing the SAME invalidation
  machinery `written_names`/narrowing already use for refined locals -- versus needing #90's
  relational constraints or #13's SMT once the index is stored across a function boundary rather
  than tracked flow-sensitively within one).
- **(C) Hardware capabilities (CHERI-style)** -- pointers that carry bounds/permission checked in
  hardware. No target this project builds for has the silicon. Noted as existing in the wider
  design space, not pursued.
- **(E0) Function-mediated bit-recovery, available today with zero language changes** -- observed
  directly in `affine_escape_via_index.tkb`'s own `slot_lease`: `unsafe { idx as *SlotLease }`
  already makes the lease's bit pattern equal to `idx`. The binding already exists at the
  representation level; what today's example fails to do is recover it, instead threading `idx`
  as a SEPARATE, unenforced parameter alongside the lease. Fix: move the recovery inside the
  trusted file (`let idx: usize = lease as usize;`, the sanctioned affine `as usize` cast, per
  Stage 2's private-type discipline) and drop `idx` from every function's signature entirely --
  `fn slot_read(lease: borrow *SlotLease) -> i32` alone. Honest limitation carried over from
  issue #89's own original self-critique of this idiom ("smuggling data through pointer bits ...
  is not a design I'd call good"; recorded here again rather than re-litigated).

**Why E0 is not throwaway, and is the resolution of a real disagreement worked out this
session**: initial framing treated E0 as a temporary shim to be discarded once B2 lands. Pushback
(correct) noted that if B2 = B1's shape, E0 teaches nothing en route to it and both would need
throwing away together. Resolution: because B2 is NOT B1 (the index never appears in an ordinary
call site's signature either way), E0 and B2 present the IDENTICAL external interface --
`slot_read(lease: borrow *SlotLease) -> i32`, no index parameter, callers unchanged. Only the
few lines INSIDE the trusted file differ (E0: recover `idx` from the pointer's bits at runtime,
range-check it; B2: the index is a static, mint-time-fixed refinement, no runtime recovery
needed). E0 pins down the interface shape B2 will keep, and lets real usage surface which
recovered properties call sites actually need (so far: a RANGE proof for bounds-check elimination
-- already expressible today via a refined return type from the recovery step -- not yet an
IDENTITY proof across multiple simultaneously-live leases, which only becomes a real question
once something needs two leases alive at once, e.g. concurrent RTOS access to an fd-style table).
That concurrency trigger is the concrete signal to actually start B2's design, not a calendar
date or an examples count.

**Status**: user is taking a day to think this over before authorizing implementation. E0 is
proposed but NOT YET IMPLEMENTED as of this entry -- do not start without explicit go-ahead.

## 7. Stage 4 outlook: channel v2 (#113) + variant enums (#20)

Consumers of Stages 1-3: zero-copy channel send transfers an
affine/linear payload into the slot (Stage 3), receive returns a linear
obligation (Stage 1) so dropping a received buffer is a compile error;
`Result`/`Option`-shaped variant enums (#20) replace the null-sentinel +
out-param idiom -- with the note that variant payloads carrying
kind-tracked values are themselves a place-tracking question, which is
why #20 waits for Stage 3.

## 8. Prior art notes

Austral: the closest existing design -- linear types without a borrow
checker, spec small enough to review; validates the "kernel" framing.
ATS2: proof/view discipline is the ancestor of the witness/obligation
idea; its at-view plumbing burden is what the tripwire exists to avoid.
Rust: rejected as the base model previously (affine-only, no linear;
Drop makes silent discard a feature, the opposite of an obligation).
Linear Haskell: multiplicity-on-arrows is the closest formal treatment of
"exactly once", but its laziness interactions are irrelevant here.

## 9. Open questions -- RESOLVED in review (2026-07-13)

1. Keyword: `linear`. Matches the literature, greppable, same register as
   `affine`.
2. `tcp_event_ignored` reason argument: REJECTED (user review). A runtime
   enum nobody reads is dead data; for debugging, a breakpoint on
   tcp_event_ignored plus the stack trace identifies the call site, and
   the call site IS the reason. Source-level classification is served by
   call-site comments. If runtime observability of ignores is ever really
   needed (e.g. stale-segment counters), that is a separate feature with
   its own driver.
3. Linear parameters: all-paths strength confirmed. A function's
   signature makes a BINARY promise per linear parameter: `borrow` =
   never consumes, plain/`sink` = consumes on every path. "Conditionally
   consumes" is deliberately inexpressible -- allowing it would push
   effect annotations into signatures, the exact ATS2-plumbing slope the
   tripwire guards against. Same binary Rust uses (by-value always moves,
   reference never does).
