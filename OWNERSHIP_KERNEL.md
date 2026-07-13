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

## 5. Stage 2 outlook: private types and fields (#108) + cast tightening (#15)

`private` extends from top-level globals to type declarations (a private
type's name -- and thus integer-to-pointer mints of it -- usable only in
its declaring file) and to struct fields (readable/writable only in the
declaring file; the KGuard/FatFile accessor idiom becomes enforced).
Combined with 4.3, this makes obligations non-forgeable outside the
trusted file. Cast rules for kind-carrying values tighten per issue #15's
audit direction.

## 6. Stage 3 outlook: places (#89 Hurdle 3)

Kind tracking extends from named locals to PLACES: struct fields, array
slots, and designated globals. Unlocks: FatFile tables (fd-table),
channel slots holding tokens, multi-instance guards. This is the hard
stage; its design constraint is already fixed by Stage 1: place-stored
linear values keep the all-paths discipline at the granularity of "slot
occupied/vacated", which is what a rendezvous channel slot needs.

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
