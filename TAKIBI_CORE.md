# Takibi Core -- Long-Term Type-System Architecture

Status: DESIGN TARGET. This document defines the direction of travel, not
syntax accepted by the compiler today. `SPEC.md` remains authoritative for
implemented Takibi. `OWNERSHIP_KERNEL.md` records the history and limitations
of the current affine/linear checker.

Implementation status (2026-07-15): Slices 0 and 1 are implemented. The
`Takibi_core` module owns the four-layer vocabulary, the current checker uses
`Delta.Legacy_flow`, and the indexed runtime-owner subset described in 3.1 is
accepted. Views, explicit existentials, general propositions, solver hooks,
and effects remain design targets.

The examples in this document are elaboration fixtures. Their contracts and
runtime representations are decisions; punctuation may change when a fixture
becomes an implementation slice.

## 1. Decision

Takibi will have one dependent, permission-aware core rather than separate
"Rust mode", "ATS mode", "separation-logic mode", and "SMT mode" type
systems. Conceptually, checking a computation transforms four contexts:

```text
Gamma ; Delta ; Phi  --epsilon-->  Gamma' ; Delta' ; Phi'
```

For a conventional typing presentation, `Gamma` maps runtime places to
types, while the output value is written separately:

```text
Sigma ; Gamma ; Delta ; Phi |- e : tau ! epsilon => Delta' ; Phi'
```

`Sigma` is only the environment of declared types, static sorts, predicates,
and functions. The four program-relevant layers are:

| layer | contents | structural rule | runtime representation |
|---|---|---|---|
| `Gamma` | runtime values and places | ordinary value typing | bytes, registers, pointers |
| `Delta` | ownership, permissions, protocol states, heap predicates | affine or linear; no implicit copying | normally erased; may be bundled with a `Gamma` value |
| `Phi` | equality, ranges, arithmetic facts, pure propositions | freely copyable | erased |
| `epsilon` | blocking, interrupt, atomicity, MMIO, suspension effects | inferred and checked as an effect set/row | no value; operations still execute |

This unifies the useful parts of the alternatives considered during the
ownership review:

- Rust-style ownership is a runtime value in `Gamma` bundled with its
  ownership permission in `Delta`.
- An ATS-style view keeps a runtime value in `Gamma` and its permission in
  `Delta` as separate source-level values.
- Separation logic enriches `Delta` with predicates such as `Cell`, `Array`,
  disjoint composition, and lock invariants. It is not another checking mode.
- Refinements and SMT discharge propositions already present in `Phi`. A
  solver cannot reconstruct a relation that elaboration erased.
- Typestate and session types are indexed state transitions in `Delta`.
- Interrupt and blocking restrictions are propagated by `epsilon`.

The surface language exposes only the part needed by an API. Programmers do
not select a foundational logic per function.

## 2. Explicit Runtime/Erased Boundary

The source spelling must make the representation boundary visible. This is
the resolution of the ambiguity found while discussing `SlotLease[n]`,
`MutexGuard[lock]`, `NetRxCpuOwned[desc]`, and `TcpConn[conn, state]`.

### 2.1 Runtime declarations (`Gamma`, with optional `Delta` ownership)

```takibi
struct Pair { x: i32, y: i32 }                 // copyable runtime data
affine struct MaybeDropped[n: usize] { id: usize @ n }
linear struct MustClose[n: usize] { id: usize @ n }
```

All fields of a `struct` have a runtime layout. `affine` means at most one
owning use and permits dropping. `linear` means exactly one owning use on
every exit path. These are the standard meanings; today's affine
"consumed on at least one path" rule is a migration mechanism, not the
destination.

An affine/linear runtime value elaborates to both:

```text
Gamma: h : MustClose[n]
Delta: Own(h, MustClose[n])
```

Moving `h` transfers `Own`; `borrow h` creates a scoped permission without
transferring `Own`; `sink h` consumes it. Unlike today's implementation,
these modes are not restricted to pointers to opaque marker types.

### 2.2 Erased permission declarations (`Delta`)

```takibi
affine view OptionalPermit[id: addr];
linear view MutexHeld[lock: addr];
linear view TcpConn[conn: addr, state: TcpState];
```

A `view` has no fields, size, address, null value, integer cast, or LLVM
type. Its binding exists only during checking. It can still be affine or
linear. Returning a view from a function and passing it to another function
changes `Delta` but adds no ABI parameter or result.

Views describe authority over state that already lives elsewhere: a mutex,
an MMIO register bank, a DMA descriptor, a protocol phase, or a memory
region. General heap predicates and lock invariants, if later needed, are
forms of `view`, not a new ownership feature.

### 2.3 Erased pure declarations (`Phi`)

```takibi
prop Same[a: addr, b: addr] = (a == b);
```

Refinement bounds, singleton equalities, and propositions are duplicable.
They cannot represent ownership. The expected ordinary syntax is mostly
implicit:

```takibi
idx: {0..<4 as usize} @ n
where n == m
```

`@ n` says that the runtime value is named by static value `n`; it does not
add another runtime field. Unbound static names in a signature are
implicitly universally quantified. `exists n. T[n]` packages an identity
chosen at runtime and hides it from the caller until pattern matching opens
the package. Initial static sorts are integers, addresses, generative `id`
values, and finite enum states; they are distinct even when two happen to use
the same machine-word representation.

### 2.4 Effects (`epsilon`)

Provisional effect notation is `!{...}`:

```takibi
fn wait_for_irq() !{may_block};
fn write_status(r: *io u32, v: u32) !{mmio};
```

Effects answer "what may this computation do?" A permission that must be
returned, such as "interrupts are currently disabled on CPU c", belongs in
`Delta`; the fact that a function may block or touch MMIO belongs in
`epsilon`. An interrupt-handler context can then reject `may_block` calls
without manufacturing a runtime token.

### 2.5 Erasure table

| source construct | checker layer | ABI |
|---|---|---|
| ordinary `struct`/primitive/pointer | `Gamma` | retained |
| `affine struct` / `linear struct` fields | `Gamma` | retained |
| ownership of that runtime value | `Delta` | erased |
| `view` binding/parameter/result | `Delta` | erased |
| static argument, `@ n`, `where` fact, `prop` | `Phi` | erased |
| effect annotation | `epsilon` | erased |
| `Option[T]` / variant tag and runtime payload | `Gamma` | retained |
| `exists n. T[n]` where only `n` is static | `Phi` binder | binder erased; `T`'s runtime payload retained |

Erasure is not forgetting. Static names and facts remain available to the
checker and VC generator until checking finishes.

## 3. How Current Examples Should Look

These examples are intentionally different where their runtime needs are
different. That is a representation choice made explicitly with `struct`
versus `view`, under one core judgement.

### 3.1 `SlotLease`: runtime indexed owner

`slot_read(lease)` must recover the slot without a separate runtime `idx`.
The handle therefore carries data. It is linear if releasing the slot is
mandatory; spell it `affine struct` only if silently abandoning a lease is
part of the API contract.

```takibi
private linear struct SlotLease[n: usize] {
    private idx: {0..<4 as usize} @ n;
}

fn slot_lease(idx: {0..<4 as usize} @ n) -> SlotLease[n] {
    let mut lease: SlotLease[n] = { idx };
    return lease;
}

fn slot_read(lease: borrow SlotLease[n]) -> i32 {
    return slots[lease.idx].value;
}

fn slot_write(lease: borrow SlotLease[n], value: i32) {
    slots[lease.idx].value = value;
}

fn slot_unlease(lease: sink SlotLease[n]) {}

let lease = slot_lease(idx);
slot_write(lease, 99);
uart_print(slot_read(lease));
slot_unlease(lease);
```

Conceptual lowering:

```text
SlotLease[n]                          -> runtime { usize idx }
n, 0 <= n, n < 4                     -> erased Phi
Own(lease, SlotLease[n])              -> erased Delta
slot_read(lease)                      -> runtime call slot_read({ idx })
slot_read body                        -> extractvalue idx, then index slots
```

This fixes E0's failure: the runtime index is real data, while `@ n`
preserves the range and identity statically. No pointer bits are used as a
proof and no independent `idx` argument can disagree with the lease.

The current Slice 1 ABI passes `SlotLease[n]`, including `borrow` and `sink`
parameters, as its ordinary runtime aggregate by value. `borrow` changes
`Delta` flow only: it neither transfers ownership nor creates a runtime
reference. A later mutable-borrow slice may choose a reference ABI, but must
spell and specify that separately.

Slice 1 trusts the declaring module to issue owners correctly. Creating a
`SlotLease[n]` literal creates a fresh `Delta` obligation; `linear` then checks
that particular value on every path, but does not prove that the private
constructor cannot issue a second lease for the same `n`. Requiring an erased
permission as the constructor input is a later `view` slice, not a property
silently claimed by this runtime-owner syntax.

### 3.2 `MutexGuard` and `KGuard`: erased views when the lock stays explicit

The current mutex API already passes the real mutex pointer to lock and
unlock. Its dummy guard pointer carries no runtime information, so the
natural replacement is an erased view:

```takibi
private linear view MutexHeld[lock: addr];

fn mutex_lock(m: *i32 @ lock) -> MutexHeld[lock] !{may_block} {
    sem_wait(m);
    return view MutexHeld[lock];
}

fn mutex_unlock(m: *i32 @ lock, held: sink MutexHeld[lock]) {
    sem_post(m);
}

fn cond_wait(seq: *io i32, m: *i32 @ lock,
             held: sink MutexHeld[lock]) -> MutexHeld[lock] !{may_block} {
    let s = *seq;
    mutex_unlock(m, held);
    while (*seq == s) {}
    return mutex_lock(m);
}
```

`MutexHeld[lock]` contributes no ABI value. `mutex_lock` takes only `m` and
has no runtime result; `mutex_unlock` takes only `m`. The static `lock`
rejects unlocking a different mutex. `KGuard` can use the same shape, with
an additional CPU/interrupt-state index when multicore support creates that
need.

If an API instead wants `mutex_unlock(guard)` with no mutex argument, use a
runtime package explicitly:

```takibi
private linear struct MutexGuard[lock: addr] {
    private mutex: *i32 @ lock;
}
```

That alternative has one pointer at runtime. The two forms are not
interchangeable or inferred from an opaque declaration; the source states
the representation choice.

### 3.3 `NetRxCpuOwned`: fallible existential runtime owner

Supporting more than one descriptor in flight requires the successful
handle to identify the descriptor. Descriptor and validated length should
move out of singleton globals and into a private runtime value:

```takibi
private linear struct NetRxCpuOwned[desc: usize] {
    private index: {0..<RX_DESC_COUNT as usize} @ desc;
    private len: {0..<1515 as usize};
}

fn net_rx_acquire()
    -> Option[exists desc. NetRxCpuOwned[desc]];
fn net_rx_len(frame: borrow NetRxCpuOwned[desc]) -> usize;
fn net_rx_frame(frame: borrow NetRxCpuOwned[desc]) -> [u8; 1514..];
fn net_rx_release(frame: sink NetRxCpuOwned[desc]);

match net_rx_acquire() {
    Some(frame) => {
        process(net_rx_frame(frame));
        net_rx_release(frame);
    }
    None => {}
}
```

The runtime success payload is `{index, len}` plus the variant tag. `desc`
and its bounds are erased. The `Some` arm opens the existential and owns one
descriptor; the `None` arm has no obligation. This removes the null-sentinel
exception that currently distorts affine branch semantics.

An implementation intentionally limited to one global in-flight RX frame
could instead use an erased view, but that choice would continue to encode
the singleton restriction. It should not masquerade as a descriptor-indexed
API.

### 3.4 `FatFile`: runtime state, not a dummy capability

`FatFile` operations need the directory entry, cursor, size, and mode. Those
are runtime state and should not remain unrelated singleton globals:

```takibi
private linear struct FatFile[file: id] {
    private dir_index: usize;
    private start_cluster: u32;
    private cur_cluster: u32;
    private pos_in_cluster: u32;
    private offset: u32;
    private size: u32;
    private writing: bool;
}

fn fat_open(name83: *u8, mode: i32)
    -> Result[exists file. FatFile[file], FatError];
fn fat_read(fp: borrow mut FatFile[file], buf: *u8,
            requested: u32, read: *u32) -> i32;
fn fat_close(fp: sink FatFile[file]) -> i32;
```

This is the Rust-like use of the same core: runtime state in `Gamma`, with
its unique ownership in `Delta`. `borrow mut` is required because reading
advances the cursor. A later table-backed implementation may store only a
slot index in the runtime handle and put `FileSlot[file, Open]` in its
private ownership invariant; callers need not see that lower-level view.

### 3.5 `PendingTcpEvent` and `TcpConn`: erased obligations and view change

`PendingTcpEvent` exists only to force a disposition. `TcpConn` describes
the phase of runtime connection state held elsewhere. Both are views:

```takibi
private linear view PendingTcpEvent[event: id];
private linear view TcpConn[conn: addr, state: TcpState];

fn tcp_event_accepted()
    -> exists event: id. PendingTcpEvent[event];

fn tcp_event_ignored(pending: sink PendingTcpEvent[event],
                     conn: borrow TcpConn[c, state]);

fn tcp_accept_via_syn_ack(
    pending: sink PendingTcpEvent[event],
    conn: sink TcpConn[c, Listen],
    eth: [u8; 54..]
) -> TcpConn[c, SynRcvd];
```

The views add no runtime parameters or results. `eth` and the real
connection storage remain in `Gamma`; the transition
`TcpConn[c, Listen] -> TcpConn[c, SynRcvd]` occurs in `Delta`. A future
view-change shorthand may write the same contract as
`TcpConn[c, Listen] >> TcpConn[c, SynRcvd]`, but the core operation is
ordinary consume-and-produce.

After runtime dispatch, code may hold `exists state. TcpConn[c, state]`.
Matching the runtime state opens that package; each exhaustive arm returns a
new package. This is a concrete need for both universal and existential
static quantification.

### 3.6 Slices: runtime extent plus static facts

The existing slice is not only a bounds-checking convenience. Network
packets, reads, and subslices genuinely carry runtime extents. A slice such
as `[T; N..]` lowers as:

```text
Gamma: ptr : *T, len : usize
Delta: SliceRegion(ptr, len, T)       when the API owns/borrows memory
Phi:   N <= len
```

Thus its ABI remains a fat `{ptr, usize}` value. `.len` is a runtime load;
`N <= len` is erased. Exact static arrays and pointers to them need no
runtime length, while a raw pointer of unknown extent carries no automatic
bounds authority. These cases should stay distinct rather than deleting
dynamic slices merely because many embedded buffers have static capacity.

### 3.7 Channels and interrupt safety: later use of `Delta` and `epsilon`

The current `Chan` is runtime storage in `Gamma`. A zero-copy or concurrent
version will need a private invariant in `Delta` relating the slot state and
payload ownership. `chan_send`/`chan_recv` also have `may_block` in
`epsilon`; an interrupt handler is rejected from calling them even if it can
name the channel.

This is where selected separation predicates and session-like state become
useful, but ordinary channel users should see a small API, not the invariant
proof. The trusted implementation opens and closes that invariant around
the atomic/locked region.

## 4. Programmer Decision Rule

The language should teach one escalation ladder:

1. Use an ordinary value when the program only needs runtime data.
2. Add a refinement or static `@ name` when a pure value relation matters.
3. Use `affine struct` or `linear struct` when a uniquely owned runtime
   package must carry data.
4. Use `view` when authority or state must be tracked but no runtime payload
   is needed.
5. Put arithmetic/equality obligations in `where`; the compiler handles the
   built-in decidable fragment and `solve` may later invoke SMT.
6. Expose an explicit lemma/proof only when the proposition is outside that
   fragment. Keep it at a trusted abstraction boundary.
7. Annotate effects at public/unsafe boundaries; infer them within ordinary
   code where possible.

The API designer chooses whether information is runtime (`struct`) or
erased (`view`/`prop`). The application programmer normally just follows the
API's types. There is no requirement to understand several foundational
logics before using a mutex, file, or RX frame.

## 5. Solver and Proof Boundary

The first `Phi` fragment is quantifier-free equality plus linear integer
arithmetic over named static values and existing interval refinements.
Syntactic equality and interval propagation remain fast paths. Z3, when
added, is only a discharger for generated verification conditions.

`solve` must mean "prove the current pure goal from named assumptions". It
must not consume or invent `Delta` resources, recover erased identities, or
turn failure into a runtime fallback.

A later `prove` boundary can export assumptions and a conclusion to a proof
artifact checked by a small verifier. Lean may produce that artifact, but
Lean itself need not be in the compiler's trusted computing base. The
artifact format, allowed axioms, reproducibility, and failure behavior must
be specified before source-level `prove` is accepted.

## 6. Core IR Direction

The compiler pipeline should converge on:

```text
surface AST
  -> name/type/static elaboration
  -> Takibi Core judgement (Gamma, Delta, Phi, epsilon)
  -> permission flow and view-change checking
  -> Phi verification-condition generation/discharge
  -> erase static arguments, views, propositions, and effects
  -> existing LLVM lowering for Gamma values
```

The Core IR needs, incrementally:

- stable places, projections, and static identities;
- standard multiplicities (`unrestricted`, `affine`, `linear`);
- runtime owner types and erased view types as different constructors;
- universal and existential static binders;
- singleton/refinement propositions and substitutions;
- consume/produce/borrow operations over `Delta`;
- effect rows/sets and call-site subset checks;
- generated pure goals with source locations and assumptions;
- an explicit erasure pass before LLVM type lowering.

The checker should not continue growing a second, syntax-local ownership
semantics inside `type_inf.ml`. The first code step is to extract its current
branch-flow lattice behind a Core-owned interface. That extraction preserves
behavior and is explicitly called `Legacy_flow`: it is a migration input,
not the final meaning of affine or the final representation of `Delta`.

## 7. Example-Driven Implementation Order

The destination is fixed; examples still determine the order of slices.

### Slice 0: Core boundary (implemented 2026-07-15)

- Introduce a `Takibi_core` module and move the current any-path/all-path
  consumption lattice into `Takibi_core.Delta.Legacy_flow`.
- Keep parser behavior and diagnostics unchanged.
- Unit-test branch join, consume, and re-produce independently of syntax.

### Slice 1: indexed runtime owner (`SlotLease`, issue #89; implemented 2026-07-15)

- Add static integer binders, singleton `@ n`, indexed runtime types, and
  implicit universals to the elaborated Core.
- Add first-class affine/linear runtime structs and generalize `borrow` and
  `sink` beyond opaque pointers.
- Rewrite `affine_escape_via_index` to the shape in 3.1, including negative
  identity/range examples.
- Preserve the runtime index as data and erase only its static name/facts.

This slice is not complete if it merely parses brackets, retains a loose
`idx` call argument, smuggles data through pointer bits, or aliases an invalid
index to slot zero.

Implemented scope:

- integer static parameters on `affine struct` / `linear struct`;
- singleton runtime integers `T @ n`, indexed types `Name[n]`, implicit
  universal static names in signatures, fresh call-site instantiation, and
  generative rigid identities for independent unknown runtime values;
- substitution of an owner's static arguments into its field types;
- first-class aggregate flow through local variables, parameters, returns,
  `borrow`, and `sink`;
- private constructors/fields, range and identity rejection, and static
  erasure in LLVM while runtime fields remain;
- initialization, live-overwrite, borrowed-move, owned-temporary, and
  singleton-alias safety checks; writable fields on mutable owner storage;
- no pointer-bit minting, owner casts, address-taking, globals, fields,
  arrays, slices, or pointer storage for indexed owners in this slice.

Singleton-bearing ordinary storage is restricted for the same reason:
address-taking or pointer/array/global/ordinary-field storage could mutate the
runtime integer while retaining its erased equality. Direct singleton fields
inside non-addressable indexed owners are supported.

Not implemented by Slice 1: explicit `forall`/`exists`, existential opening,
static addresses/enums, `where`, `prop`, `view`, mutable references, solver
discharge, or effects. Those remain later slices rather than being simulated
by ad hoc syntax.

### Slice 2: erased linear view (`PendingTcpEvent`, issue #117)

- Add `view` declarations and explicit erasure.
- Rewrite `PendingTcpEvent` without dummy pointer minting.
- Demonstrate that LLVM signatures contain no token parameter/result and
  that all-path discharge diagnostics remain source-level precise.

### Slice 3: variants/existentials and standard multiplicity

- Add kind-carrying `Option`/`Result` payloads and existential opening.
- Rewrite `NetRxCpuOwned` acquisition without null tokens.
- Change `affine` to its standard at-most-once meaning; use `linear` where
  release is mandatory. Delete the current any-path must-consume exception
  after its examples migrate.

### Slice 4: runtime mutable owners and effects

- Move `FatFile` state into a runtime owner and add scoped mutable borrow.
- Add `may_block`/interrupt-context checking to `mutex`, channel, and ISR
  examples.
- Introduce lock invariants or richer views only when a concurrent example
  needs them.

### Later slices

- `TcpConn[conn, state]` view change and existential state dispatch.
- Zero-copy typed channels (#113) and ownership transfer through variants.
- Aliasing/region predicates (#106), asynchronous TX ownership (#87), and
  solver/proof integration, each with a concrete driver and negative tests.

## 8. What to Keep and What to Replace

Keep the parser/LLVM pipeline, ordinary type inference, arrays, dynamic
slices, alignment, privacy, exhaustive matching, refinement intervals, and
`--forbid-trap`. They are useful inputs or backends for the Core.

Replace rather than preserve indefinitely:

- ownership being synonymous with `*OpaqueMarker`;
- integer-to-token and dummy-storage minting;
- affine's nonstandard "consumed on at least one path" obligation;
- pointer-only `borrow`/`sink`;
- null as a fallible resource package;
- local-name/one-field-only tracking as the semantic endpoint;
- proof-carrying runtime data and erased views sharing one ambiguous
  `resource` spelling;
- checker logic whose only IR is the surface AST.

No source compatibility promise applies to these experimental ownership
features before the corresponding Core slice is specified in `SPEC.md`.

## 9. Acceptance Principles

Every slice must show all of the following:

- its surface program and elaborated `Gamma`/`Delta`/`Phi`/`epsilon` shape;
- its runtime ABI after erasure;
- at least one real positive example and focused negative companions;
- no new forge path through casts or visibility;
- diagnostics at the source contract, not internal proof plumbing;
- a monotonic extension of this Core rather than a special checker for one
  example.

If routine application code starts threading static indices or proof terms
through every call, the slice has failed its surface-design requirement.
Add inference, implicit arguments, existential packaging, or a narrower
module API before proceeding.

## 10. Issue Map

This architecture does not make every issue one implementation project. It
gives each issue a stable destination and lets vertical slices close
independently:

| issue | Core destination |
|---|---|
| #89 affine escape/inter-function behavior | indexed runtime owners, stable places, and standard Delta flow; `SlotLease` is its closing slice |
| #117 protocol action obligations | erased linear views first, then indexed `TcpConn` view change |
| #113 generic typed channels | runtime generic payloads in Gamma, payload ownership transfer and private channel invariants in Delta |
| #66 Simple RTOS | lock/task identities in Delta plus `may_block`, scheduling, and interrupt constraints in epsilon |
| #20 variant enums | kind-carrying runtime variants and existential resource payloads |
| #6 multiple cores | CPU-indexed guards, per-CPU state, and interrupt permissions |
| #106 aliasing | place identity, region/view predicates, and disjointness propositions |
| #87 asynchronous TX ownership | linear in-flight buffer/descriptor states and completion transitions |
| #15/#108 cast and visibility hardening | unforgeable constructors and module boundaries for runtime owners and views |
| #13 future SMT path | discharge generated Phi goals only after static names and assumptions exist |

When a slice reveals a genuinely independent acceptance criterion, create a
separate issue rather than expanding #89 or this architecture document into
an unclosable umbrella task.
