# Takibi Core -- Long-Term Type-System Architecture

Status: DESIGN TARGET. This document defines the direction of travel, not
syntax accepted by the compiler today. `SPEC.md` remains authoritative for
implemented Takibi. `OWNERSHIP_KERNEL.md` records the history and limitations
of the current affine/linear checker.

Implementation status (2026-07-17): Slices 0 through 6 and the currently
selected post-Slice-6 Core increments are implemented. The
`Takibi_core` module owns the four-layer vocabulary, the current checker uses
`Delta.Legacy_flow`, and the indexed runtime-owner subset described in 3.1 is
accepted. Non-indexed erased affine/linear views are also accepted and erased
before LLVM ABI lowering. Closed kind-carrying variants, restricted
existential indexed-owner payloads, and standard affine weakening are
accepted. Scoped mutable owner borrows, direct/indirect blocking effects, and
function-pointer effect contracts are accepted and erase before LLVM.
Integer-indexed erased views and implicitly universal view transitions are
accepted. The post-Slice 6 examples now use erased guard views, an affine RX
acquisition permission, and owner-mediated synchronous TX. Owner-derived
region slices (`-> [T; N..] @ owner_index`, backed by `Delta.Region_taint`)
are implemented: `net_rx_frame`'s slice is now unusable after release.
Finite-enum static states and existential indexed-view payloads now support
closed `TcpConn[conn, state]` runtime dispatch. Plain variants can now carry
unrestricted ordinary structs by value and live in ordinary struct fields; the RTOS SD
server uses that subset for one typed copy-rendezvous request slot. Private
stable owner slots can now hold one linear ownership-bearing variant and
exchange it through `stable_replace` while the address-indexed guard for a
same-container mutex is held; the RTOS demo uses this for one
ownership-bearing rendezvous direction. Static
`addr` indices now bind `MutexGuard[lock]` and `KGuard[lock]` to supported
syntactic lock places and reject a mismatched explicit unlock pointer.
Guard-derived pointer returns make `rtos_demo`'s shared data inaccessible
after its authorizing `KGuard[lock]` is consumed. General linear-owner
place/storage tracking, arbitrary address expressions,
direct/general quantifiers and propositions remain design targets. External
solver/prover integration is not an active implementation target; Z3 and
Lean4 are only possible future tools and must not be selected merely because
they appear in this architecture document.

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
- Refinements put pure propositions in `Phi`. If an external solver is ever
  justified, it can only discharge propositions already retained there; it
  cannot reconstruct a relation that elaboration erased.
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
every exit path. Slice 3 implements these standard meanings; the former
"consumed on at least one path" affine rule has been removed.

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

### 3.2 `MutexGuard` and `KGuard`: address-indexed erased views

The mutex API passes the real mutex pointer to lock and unlock. Slice 2's
erased view representation plus the later `addr` identity replace the old
dummy guard pointer:

```takibi
private linear view MutexGuard[lock: addr];

fn mutex_lock(m: *i32 @ lock) -> MutexGuard[lock] !{may_block} {
    sem_wait(m);
    return view MutexGuard[lock];
}

fn mutex_unlock(held: sink MutexGuard[lock], m: *i32 @ lock) {
    sem_post(m);
}

fn cond_wait(seq: *io i32, held: sink MutexGuard[lock],
             m: *i32 @ lock) -> MutexGuard[lock] !{may_block} {
    let s = *seq;
    mutex_unlock(held, m);
    while (*seq == s) {}
    return mutex_lock(m);
}
```

`MutexGuard` contributes no ABI value. `mutex_lock` takes only `m` and has no
runtime result; `mutex_unlock` takes only `m`. The checker assigns an erased,
rigid address identity to supported `&name` and `&name.field...` places, so a
guard obtained for one mutex cannot be passed with another mutex pointer.
`KGuard` uses the same contract. CPU/interrupt-state identity remains
demand-led until multicore support creates that concrete need.

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

The current backends intentionally permit one CPU-owned RX descriptor at a
time. The successful handle identifies that descriptor, while an erased
affine permission prevents a second acquisition until release:

```takibi
private linear struct NetRxCpuOwned[desc: usize] {
    private index: {0..<RX_DESC_COUNT as usize} @ desc;
    private len: i32;
}

private linear struct NetTxInFlight[desc: usize] {
    private index: {0..<RX_DESC_COUNT as usize} @ desc;
    // Present only when the backend selects a runtime TX ring slot.
    private tx_index: isize;
}

private affine view NetRxCanAcquire;

variant NetInitResult {
    Failed;
    Ready(NetRxCanAcquire);
}

variant NetRxAcquire {
    None(NetRxCanAcquire);
    Acquired(exists desc: usize. NetRxCpuOwned[desc]);
}

fn net_rx_acquire(ready: sink NetRxCanAcquire) -> NetRxAcquire;
fn net_rx_len(frame: borrow NetRxCpuOwned[desc]) -> i32;
fn net_rx_frame(frame: borrow NetRxCpuOwned[desc]) -> [u8; 1514..] @ desc;
fn net_transmit(frame: sink NetRxCpuOwned[desc], len: i32)
    -> NetTxInFlight[desc];
fn net_tx_complete(in_flight: sink NetTxInFlight[desc])
    -> NetRxCanAcquire !{may_block};
fn net_rx_release(frame: sink NetRxCpuOwned[desc]) -> NetRxCanAcquire;

match net_rx_acquire(ready) {
    NetRxAcquire::Acquired(frame) => {
        process(net_rx_frame(frame));
        ready = net_rx_release(frame);
    }
    NetRxAcquire::None(next) => { ready = next; }
}
```

The runtime success payload is `{index, len}` plus the variant tag. `desc`
and its bounds are erased. `NetRxCanAcquire` also erases, so `None` contains
only the tag. The `Acquired` arm opens the existential and owns one descriptor;
its linear owner must be released. The permit itself is affine because giving
up future acquisition is safe, while copying or reusing it is not. This
removes the null-sentinel exception and closes duplicate owner minting at the
public API boundary.

`net_transmit` consumes the RX owner, derives the in-place reply pointer, and
returns a linear TX-in-flight owner rather than trusting an unrelated raw
pointer or retaining an untracked borrow across return. Completion consumes
that owner and restores the acquisition permit. `net_rx_frame`'s returned
slice is tied to the borrowed owner by its region-annotated return type
(`-> [u8; 1514..] @ desc`, see the implemented-slice entry below): using the
slice, or anything derived from it, after either release or TX start consumes
the owner is a compile error. A future
multi-frame-in-flight API would need multiple indexed acquisition credits or
an equivalent queue-capacity resource, not silent extra minting behind this
one-permit interface.

### 3.4 `FatFile`: runtime state, not a dummy capability

`FatFile` operations need the directory entry, cursor, size, and mode. Those
are runtime state and should not remain unrelated singleton globals:

```takibi
private linear struct FatFile[file: usize] {
    private dir_index: {0..<16 as usize} @ file;
    private start_cluster: u32;
    private cur_cluster: u32;
    private pos_in_cluster: u32;
    private fptr: u32;
    private fsize: u32;
    private writing: bool;
}

variant FatOpenResult {
    Error(i32);
    Opened(exists file: usize. FatFile[file]);
}

fn fat_open(name83: *u8, mode: i32) -> FatOpenResult;
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
   built-in decidable fragment. Do not add `solve` or SMT until a real API
   demonstrates that this fragment is insufficient.
6. Expose an explicit lemma/proof only when the proposition is outside that
   fragment. Keep it at a trusted abstraction boundary.
7. Annotate effects at public/unsafe boundaries; infer them within ordinary
   code where possible.

The API designer chooses whether information is runtime (`struct`) or
erased (`view`/`prop`). The application programmer normally just follows the
API's types. There is no requirement to understand several foundational
logics before using a mutex, file, or RX frame.

## 5. Solver and Proof Boundary

**Z3 and Lean4 are deferred, non-active design possibilities. Do not implement
either integration, their source syntax, or infrastructure whose sole driver
is a future solver/prover until a required real example cannot be expressed
soundly with the current built-in checker. A roadmap entry or a removable
`unsafe` is not by itself sufficient justification.**

If that threshold is eventually crossed, the first `Phi` fragment should be
quantifier-free equality plus linear integer arithmetic over named static
values and existing interval refinements. Syntactic equality and interval
propagation should remain fast paths. Z3 would only be a discharger for
generated verification conditions.

A future `solve` would have to mean "prove the current pure goal from named
assumptions". It must not consume or invent `Delta` resources, recover erased
identities, or turn failure into a runtime fallback.

Only after a concrete need exists could a `prove` boundary export assumptions
and a conclusion to a proof artifact checked by a small verifier. Lean4 might
produce that artifact, but it need not be in the compiler's trusted computing
base. The artifact format, allowed axioms, reproducibility, and failure
behavior would have to be specified before source-level `prove` is accepted.

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

### Slice 2: erased linear view (`PendingTcpEvent`, issue #117; implemented 2026-07-15)

- Add `view` declarations and explicit erasure.
- Rewrite `PendingTcpEvent` without dummy pointer minting.
- Demonstrate that LLVM signatures contain no token parameter/result and
  that all-path discharge diagnostics remain source-level precise.

Implemented scope:

- non-indexed `affine view Name;` and `linear view Name;` declarations, with
  optional file-granular `private` mint authority;
- explicit `view Name` production and a distinct internal `TypeView`/`TView`
  constructor, so erased permissions cannot be confused with runtime named
  structs;
- direct local, parameter, and result flow, including plain ownership,
  `borrow`, `sink`, move checking, branch joins, early exits, overwrite, and
  explicit-return checks;
- rejection of casts, address-taking, `sizeof`/`offsetof`, globals, fields,
  arrays, slices, tuples, pointers, function-pointer nesting, and indirect
  stores: an erased view has no runtime place or layout;
- LLVM ABI erasure: view parameters and call operands are omitted, a view
  result lowers to `void`, and local view bindings allocate no stack/debug
  storage;
- `PendingTcpEvent` now uses `private linear view` rather than a forged null
  opaque pointer, and `view_linear_branch_missed` is its focused all-paths
  negative fixture.

The declaring file remains a trusted minting boundary. Slice 2 checks every
minted value's affine/linear flow but does not prove that trusted code mints a
permission only when the corresponding external event really occurred.
Static view parameters, `forall`, view change, propositions, and solver
discharge remain later slices; Slice 2 does not fake them with names or
runtime token bits. Slice 3 subsequently adds only the restricted
variant-payload `exists` form below.

### Slice 3: variants/existentials and standard multiplicity (implemented 2026-07-15)

Implemented scope:

- concrete closed `variant Name { None; Some(T); }` declarations, with one
  optional payload per case, constructors, payload-binding `match` arms,
  duplicate checks, and closed exhaustiveness;
- kind propagation from payloads, consuming match for kinded variants, and
  fresh arm-local obligations for selected payloads. A linear variant cannot
  use a wildcard arm that could hide an obligation;
- restricted `exists n: IntegerSort. Owner[n]` payloads. Construction packs
  the static identity; each match opens it with a fresh rigid identity, so
  independently opened resources cannot be equated accidentally;
- standard affine weakening: affine locals, parameters, fields, views,
  indexed owners, and variants may be dropped, while contraction/use-after-
  move remains rejected. Mandatory-release examples now use `linear`;
- complete bit opacity for ownership-bearing values. Cast-away is rejected
  even in `unsafe`; fallible acquisition uses a variant rather than a null
  sentinel;
- `NetRxAcquire` in both Ethernet drivers now returns
  `None | Acquired(exists desc. NetRxCpuOwned[desc])`. Descriptor index and
  frame length remain runtime owner fields while the existential identity and
  proofs erase;
- at the Slice 3 checkpoint, `FatOpenResult` returned
  `Error(i32) | Opened(*FatFile)`, eliminating nullable linear ownership
  while leaving `FatFile` as a singleton opaque runtime design. Slice 4
  replaced that checkpoint form with `Opened(exists file. FatFile[file])`
  and per-owner runtime state;
- LLVM lowering to a tag plus runtime payload fields, with view payloads and
  existential binders erased. This first layout is not yet a stable C ABI or
  full tagged-union DWARF representation.

At the Slice 3 checkpoint, deliberate limits were concrete named variants,
no generic `Option[T]`/`Result[T,E]`, no nested/container/storage variants,
one payload per case, no concrete struct/array aggregate payloads, and
existentials only around a direct indexed runtime owner. The later typed-copy
channel increment lifts unrestricted ordinary struct payloads and
plain-variant struct fields only. Arrays, indexed-owner payload structs,
ownership-bearing aggregate payloads, and affine/linear variant storage remain
ownership-tracking limits, not claims about the final Core.

### Slice 4: runtime mutable owners and effects (implemented 2026-07-15)

Implemented scope:

- `borrow mut Owner[n]` is a parameter-only scoped exclusive borrow for an
  affine/linear indexed runtime owner. Calls require a bare mutable place and
  reject overlap with another argument; `Case(mut owner)` makes an opened
  existential payload mutable;
- LLVM passes `borrow mut` as a pointer to caller-owned aggregate storage.
  Static indices and the borrow itself erase; checker effects also have zero
  runtime representation;
- `FatFile[file]` now owns the directory index, cluster/cursor, size, and mode.
  `FatOpenResult::Opened(exists file. FatFile[file])` supports simultaneous
  files, while `fat_read`/`fat_write` borrow mutably and `fat_close` consumes;
- `!{may_block}` contracts propagate through the resolved direct-call graph.
  `!{interrupt}` roots reject any transitive blocker, including the intrinsic
  `interrupt_wait`, and report a call path;
- at the Slice 4 boundary, effect-unknown indirect calls were rejected below
  interrupt roots and function-pointer signatures remained for Slice 5;
- mutex/channel APIs and direct ISR roots now carry concrete annotations.
  Lock invariants remain deferred because no concurrent example yet needs a
  heap predicate beyond the existing private API boundary.

### Slice 5: function-pointer effect contracts (implemented 2026-07-15)

Implemented scope:

- `fn !{}(T...) -> R` is an explicitly non-blocking callback type;
  `fn !{may_block}(T...) -> R` permits blocking; an unannotated
  `fn(T...) -> R` remains effect-unknown;
- explicit `fn f() !{} { ... }` declarations are checked against their
  transitive direct and indirect call graph;
- function effect subtyping permits non-blocking-to-`may_block` widening but
  rejects blocking or unknown callbacks at a non-blocking boundary;
- indirect calls feed their row into epsilon propagation. Unknown indirect
  calls remain rejected below `interrupt` and explicit non-blocking roots;
- casts cannot invent effect contracts, and contracted callback types are
  invariant behind writable pointers;
- `USART1_IRQHandler` and both QEMU IRQ dispatch paths are checked interrupt
  roots. The IRQ demo moves potentially blocking UART echoing out of its ISR
  callback and into thread context;
- effect rows erase completely and do not change the function-pointer ABI.

### Slice 6: indexed erased views and universal view change (implemented 2026-07-15)

Implemented scope:

- an erased permission may declare primitive-integer static parameters, for
  example `linear view SlotWrite[slot: usize, state: u8];`;
- type uses and mint expressions carry the same arguments:
  `SlotWrite[slot, 0]` and `view SlotWrite[slot, 0]`;
- unbound static names in function signatures retain the existing implicit
  universal semantics. A transition such as
  `sink SlotWrite[slot, 0] -> SlotWrite[slot, 1]` is checked for every
  `slot` without exposing a runtime proof argument;
- static arity, sort, literal range, identity, and phase mismatches are
  rejected. `examples/indexed_view` ties one such permission to a runtime
  `{0..<2 as usize} @ slot` index and interleaves two independently indexed
  transitions; `indexed_view_identity_wrong` rejects crossing the slots;
- indexed views obey the existing affine/linear flow, privacy, cast, address,
  storage, and runtime-operation bans;
- all view values and static arguments erase. A view-only transition lowers
  to `void ()`, while a linked runtime singleton index remains an ordinary
  integer argument;
- bounds lowering now preserves a refinement through its singleton wrapper,
  so `{0..<N as usize} @ n` proves the same no-trap access as its base range.

This slice does not add explicit `forall`, `exists` over views, existential
runtime state dispatch, address/enum static sorts, propositions, or a solver.
Those are separate surface and Core obligations rather than being inferred
from the indexed spelling.

### Later slices

- The first concrete stable-storage subset and its same-container lock
  coupling are implemented below: a private BSS owner container can exchange
  one linear variant under its address-indexed erased guard. General place
  borrowing and arbitrary indexed-owner storage remain.
- Static lock identity is implemented below for supported named and field
  places. General invariant predicates, arbitrary address expressions, and
  heap predicates remain for examples that require them.
- Ownership transfer through one concrete synchronous channel is implemented
  below. Generic and zero-copy typed channels (#113) remain demand-led.
- Owner-derived region slices (#106), asynchronous TX ownership (#87), and
  the first authority-bound pointer lifetime slice (#128) are implemented
  below. Solver/proof integration is explicitly not queued: it may be
  reconsidered only after a required real API crosses the threshold in
  section 5.

### Post-Slice 6 example audit and consolidation (implemented 2026-07-16)

The first step after Slice 6 is a consolidation slice, not another expansion
of Core semantics. Three current APIs still encode contracts less precisely
than the already-implemented views, variants, indexed owners, and borrows can
express:

1. `MutexGuard` and `KGuard` were dummy opaque pointers even though the real
   mutex/lock remains an explicit runtime argument. They are now non-indexed
   erased linear views. This removes integer-to-token minting
   and their LLVM parameters/results without weakening today's guarantee.
   The later static-address increment below now binds each guard to a
   particular supported lock place.
2. Both network backends could previously be asked to acquire again before
   the previous `NetRxCpuOwned[desc]` was released. A private affine
   `NetRxCanAcquire` view is returned by successful `net_init`, consumed
   by `net_rx_acquire`, returned in the `None` case, and reproduced only by
   `net_rx_release` in the acquired case. This models the implementations'
   actual one-frame-in-flight policy and prevents a caller from obtaining two
   owners for the same descriptor.
   Each backend also has a private process-lifetime initialization flag on the
   current single-threaded boot path, so repeated `net_init` calls cannot
   create a second successful initial mint; failed discovery/link setup
   remains retryable. Concurrent initialization would require an atomic/lock
   invariant and is not claimed by this example API.
   Affine, rather than linear, is deliberate: abandoning the right to acquire
   again is safe, while duplicating it is not. The acquired descriptor owner
   remains linear because returning it to the device is mandatory.
3. `net_transmit` previously accepted a raw pointer with the documented but
   unchecked precondition that it came from `net_rx_frame`. At this
   consolidation checkpoint it borrowed `NetRxCpuOwned[desc]` and recovered
   the buffer from the owner's private descriptor index. The later
   asynchronous-TX increment below replaces that borrow with a consuming
   transition to `NetTxInFlight[desc]`.

The `net_rx_double_acquire_wrong` compile-error fixture fixes the permit's
negative contract: reusing the consumed acquisition right is rejected. The
RX region problem that consolidation deliberately left open is now closed by
the owner-derived region slice below.

### Owner-derived region slices (implemented 2026-07-16)

The first genuinely new post-consolidation slice ties `net_rx_frame`'s
returned slice to the borrowed owner, exactly as specified above: the
positive fixture is ordinary packet processing (all five network examples,
unchanged), and the negative fixture
(`examples/net_rx_use_after_release_wrong`) releases the frame and then
reads the old slice.

Implemented scope:

- a slice RETURN type may carry `@ name`, where `name` must be a static
  index of some `borrow`/`borrow mut` indexed-owner parameter of the same
  function; both backends' `net_rx_frame` now declare
  `-> [u8; 1514..] @ desc`;
- the annotation is a caller-side restriction only. The callee body has no
  new proof obligation (both real backends return a slice of a global
  buffer); an over-applied annotation is conservative, never unsound. The
  grammar already parsed the form via the singleton `@` rule -- return
  position is now the one place a slice base is accepted, and every other
  position keeps its existing rejection;
- checker-side, `Delta.Region_taint` (a sibling of `Legacy_flow` in
  `Takibi_core`) maps local names to the owner paths their value derives
  from. Binding a region call result, immutable aliasing, and subslicing
  (including under `unsafe`) propagate the tie; reassignment clears it. The
  kill is lazy: any use of a tied name after its owner is possibly consumed
  (branch-merge union, same conservatism as affine double-use) is rejected
  with "slice 'f' is derived from linear value 'o' and cannot be used after
  'o' is consumed";
- an authority binding cannot be rebound while an in-scope derived value
  still names its lifetime. This applies to assignment and every local
  binder form; replacing a mutable derived binding with an unrelated value,
  or leaving its scope, ends the restriction;
- escapes are rejected: returning a tied slice from the enclosing function,
  or storing one into a global, struct field, array element, or through a
  pointer;
- the annotation strips before HM unification and has zero LLVM/ABI/DWARF
  footprint;
- documented v1 holes, all function-local like the rest of Delta tracking:
  `as *u8` exits tracking (raw pointers are outside every safety story;
  `net_transmit` uses exactly this internally), callee retention of a
  passed slice is unchecked. Aggregate laundering was an original v1 hole
  and is closed by the storage barrier below.

This deliberately does not implement general region/lifetime polymorphism:
there is no region variable a caller can name, no function signature that
propagates "returns a slice tied to THIS parameter's region" transitively
through wrappers, and no owner-tied slice crossing a function boundary in
either direction. Those stay demand-led, the same tripwire discipline as
every other slice.

### Finite-state existential view dispatch (implemented 2026-07-16)

The next priority increment adds the finite-state vocabulary needed by
`TcpConn[conn, state]` without adding general quantifiers or a solver. The
HTTP server now dispatches through this permission, and
`examples/tcp_conn_view` is its focused executable fixture: the closed
`TcpConnDispatch` variant retains the runtime state tag, while each case
packages `exists conn: usize. TcpConn[conn, TcpState::Case]`.

Implemented scope:

- an erased view or indexed runtime owner may declare an exhaustive enum as a
  static parameter sort; case arguments use the nominal qualified form
  `Enum::Case`;
- non-exhaustive enums are rejected as static sorts, and equal discriminants
  from distinct enum types do not unify;
- an outermost variant payload `exists` may directly package an indexed
  erased view as well as the existing indexed runtime-owner form. Its binder
  sort may be an integer or exhaustive enum;
- matching the closed dispatch variant opens a fresh existential identity and
  a case-specific linear view. Existing all-path flow requires every arm to
  preserve, transition, or sink it;
- state transitions remain ordinary universal consume-and-produce functions.
  Passing a view in the wrong enum state is a static-value mismatch;
- `examples/common/http_conn_state.tkb` is the trusted exhaustive bridge from
  its private runtime `ConnState` byte to `TcpConnDispatch`. Every
  `(state, event)` arm in `http_server_common.tkb` must consume both its
  `PendingTcpEvent` and its state-specific `TcpConn` permission;
- the closed variant tag is the complete runtime representation when all
  payloads are views. Existential binders, enum static states, indices, and
  view values add no fields, parameters, results, or pointer encodings;
- `tcp_conn_state_wrong` and `tcp_conn_dispatch_missed_wrong` are the focused
  negative fixtures. The latter verifies that opening the runtime case cannot
  discard its linear state permission.

The implemented surface uses one closed variant case per runtime state. A
direct first-class `exists state. TcpConn[c, state]` outside a variant payload,
arbitrary existential elimination, address sorts, and storage of the linear
dispatch package remain outside this increment.

### Typed copy-rendezvous requests (implemented 2026-07-16)

The next priority increment removes the untyped request transport from
`http_server_sdcard_rtos` without pretending that linear owner storage is
already solved. Its focused language change is deliberately narrower than a
generic or zero-copy channel:

- a plain variant may carry an unrestricted ordinary concrete struct by value.
  Arrays, indexed owner structs, and structs containing affine/linear fields
  remain rejected as aggregate payloads;
- a plain variant may be an ordinary struct field and may be copied into or
  out of that field. A variant whose payload makes it affine or linear remains
  forbidden in storage, with a focused negative unit test;
- LLVM lays out payload structs before variants and variant-containing structs
  after variants. Copying and matching the aggregate uses typed
  `store`/`load`/`extractvalue`; no pointer-to-integer representation is used;
- the RTOS SD server now sends one `SdRequest` value:
  `Init | ReadChunk(SdReadChunkRequest) | FileSize(*u8)`. The former integer
  tag plus four `WordChan` values and every request-side `as usize`/back-cast
  are removed;
- `SdRequestChan` has one private mutex-protected slot. Its complete current
  invariant is `full == 0` means the value is ignored, while `full == 1`
  means the slot contains one complete request. Send publishes the copied
  value while holding the mutex and waits until receive has copied it out.

This is a typed, synchronous, copy-based request channel. It does not store a
linear owner, transfer an ownership-bearing variant, provide a generic
channel, or formalize the mutex invariant as an openable `Delta` predicate.
Those are the next owner-container slice, not hidden claims of this one.

### Stable linear owner slots (implemented 2026-07-16)

The next priority increment introduces the smallest stable place needed to
put a real linear owner behind a lock. It deliberately does not generalize
ordinary field borrowing or make every global a resource-tracked place:

- a private field that directly holds a linear variant is a stable owner
  slot. Its variant must start with a payload-free case, so an uninitialized
  BSS container has a defined empty value;
- the containing ordinary struct may exist only as a private, mutable,
  uninitialized global. It cannot be copied, returned, passed by value,
  nested in another value, or allocated as a local. A pointer to that one
  stable location is the supported API surface;
- direct read, assignment, and address-of on the owner field are rejected.
  `stable_replace(guard, &container.mutex, container.field, replacement)` is
  the only operation: it moves the replacement into invariant-owned storage
  and returns the old linear variant, which existing Delta flow requires the
  caller to bind, return, or match and discharge;
- `guard` must be a bare binding of a linear erased view with exactly one
  `addr` index. The explicit mutex field must carry that same static identity
  and share the owner field's syntactic container base. The operation keeps
  the guard live, so an owner channel can exchange its slot between
  `Empty` and `Full(exists id. Owner[id])` while the surrounding mutex API
  retains its ordinary lock/unlock obligation;
- LLVM lowers the exchange to one typed aggregate load and store. Static
  indices, existential binders, and the erased guard add no runtime operands,
  and ownership is never encoded in pointer or integer bits;
- `examples/rtos_demo` replaces its ping-to-pong integer channel with
  `OwnerChan`. Ping moves an indexed `OwnerMessage[id]` into the stable slot;
  pong opens the existential package, reads the message under borrow, and
  consumes it. The reverse response remains a plain copied integer channel.

This is a minimal invariant boundary, not a complete lock logic. The checker
proves that the stored owner crosses the boundary only as one exchange, that
neither side can discard or duplicate it, and that the exchange names the
same-container lock whose static identity the guard carries. The declaring
file remains responsible for maintaining its private `full` flag/tag
relationship and for ensuring the guard producer actually acquires that
runtime lock.

The remaining example-driven order at this checkpoint was:

1. asynchronous TX ownership only when an example actually keeps a DMA buffer
   in flight after the call returns (#87).

General heap predicates, arbitrary-place borrowing, and generic zero-copy
channels remain demand-led rather than being inferred from this narrow stable
slot.

### Static address/place identities (implemented 2026-07-16)

The fifth post-Slice-6 increment strengthens the existing erased lock guards
without adding a runtime token:

- `addr` is a checker-only, reserved static sort. A singleton pointer such as
  `m: *i32 @ lock` relates the runtime pointer to the static `lock`; it is not
  a runtime `addr` value and cannot be constructed from an integer static
  argument;
- repeated `&name` and `&name.field...` expressions within one function
  receive the same rigid identity. Different syntactic paths receive distinct
  identities, so a guard for `&a` cannot be consumed with `&b`;
- reassigning a base binding invalidates identities for projections below
  that binding. Taking the address of a pointer binding also invalidates its
  projections because a callee could rebind it through that pointer;
- pointer aliases are deliberately not resolved. Passing the same immutable
  pointer binding twice preserves that binding's identity, but mixing an alias
  with its original `&place`, or using dereference/index expressions, is
  conservatively fresh rather than proved equal;
- `MutexGuard[lock]`, `KGuard[lock]`, the singleton annotation, and the static
  identity all erase. Lock/unlock retain exactly their explicit runtime pointer
  and no `ptrtoint`/`inttoptr` proof encoding is emitted;
- `mutex_guard_identity_wrong` is the focused negative fixture. All existing
  condition-variable, channel, message-queue, KLock, and RTOS examples now use
  the indexed APIs.

This is static identity for a deliberately small syntactic-place language,
not pointer provenance, alias analysis, arbitrary-place borrowing, or a
general lock invariant. The later lock-coupled stable-exchange increment uses
that identity to tie `stable_replace` to a same-container mutex field.

### Asynchronous TX ownership (implemented 2026-07-16)

The sixth post-Slice-6 increment makes both real network backends expose the
DMA interval that already existed inside their formerly synchronous calls:

```takibi
private linear struct NetTxInFlight[desc: usize] {
    private index: {0..<RX_DESC_COUNT as usize} @ desc;
    // STM32 retains this field; QEMU's fixed slot zero needs no runtime index.
    private tx_index: isize;
}

fn net_transmit(frame: sink NetRxCpuOwned[desc], len: i32)
    -> NetTxInFlight[desc];
fn net_tx_complete(in_flight: sink NetTxInFlight[desc])
    -> NetRxCanAcquire !{may_block};
```

`net_transmit` consumes the CPU-owned RX descriptor, programs and starts TX,
and returns without waiting for the device. `NetTxInFlight[desc]` retains the
same static RX identity and only the runtime completion state each backend
needs.
`net_tx_complete` consumes that owner, waits for authoritative device
completion, re-posts the RX descriptor, and returns the sole acquisition
permit. There is therefore no RX owner available to pass to `net_rx_release`
while DMA may still read the in-place frame.

The current applications deliberately call completion as their next network
operation, preserving their single-frame behavior while still creating a
real call-return interval owned by DMA. QEMU and STM32 share the same public
contract; STM32 retains its TX slot to inspect the exact descriptor, while
QEMU's fixed descriptor zero needs only the RX index. `desc` and the
permit erase. No new Core rule or generic future/promise abstraction was
added.

The positive fixtures are all existing network applications on both targets.
`net_tx_release_while_in_flight_wrong` is the focused negative: it tries to
release the RX owner after TX start and is rejected as a second consume.

The next selected increment is the narrow #128 lifetime boundary exercised by
`rtos_demo`: a guard-authorized accessor returns a pointer that cannot survive
the guard. Arbitrary stable places, generic zero-copy channels, and solver
integration remain demand-led and need a concrete acceptance boundary before
implementation.

### Authority-bound pointer lifetimes (implemented 2026-07-16)

The first #128 slice extends `Delta.Region_taint` from owner-derived slices to
guard-derived pointer returns:

```takibi
fn shared_access(g: borrow KGuard[lock]) -> *Shared @ lock {
    return &shared;
}
```

In return position only, `*T @ name` is a checker-only region annotation.
`name` must be a static index of a borrowed indexed owner or view parameter.
At a call, the returned pointer is tied to that authority path; aliases retain
the tie, and dereference or field access after the authority is possibly
consumed is rejected. Returning the pointer or storing it in a global, field,
array element, or through another pointer is also rejected. Parameter-position
`*T @ name` remains the existing pointer/static-address identity relation.

`rtos_demo` now keeps `Shared` private, obtains `*Shared` only through
`shared_access(g)`, and uses it before `kunlock`. The focused
`guard_pointer_after_unlock_wrong` fixture performs the opposite ordering and
fails. The return annotation, static index, and guard parameter erase; the
accessor's LLVM ABI is an ordinary zero-argument function returning one
pointer.

This is deliberately not a general lock invariant. The accessor declaration
is a reviewed module contract: the checker does not prove that its returned
global is protected by the indexed lock. The stable exchange now has a
separate same-container lock relation, but raw casts and indirect laundering
retain the documented function-local region-v1 holes. The implemented
boundary is specifically that an accessor-issued pointer cannot outlive the
guard that authorized it.

The authority-rebinding barrier added below also applies to these pointers:
assigning a fresh guard to the same local name cannot revive a pointer derived
from the consumed guard.

### Lock-coupled stable owner exchange (implemented 2026-07-17)

The stable owner operation now names its lock place explicitly:

```takibi
stable_replace(g, &ch.mutex, ch.value, replacement)
```

`g` must be a bare linear erased view carrying exactly one `addr` index. That
index must equal the static identity of `&ch.mutex`, and `ch.mutex` and
`ch.value` must share the same supported syntactic container base. Thus a
guard acquired from `a.mutex` cannot exchange `b.value`, whether the call
names `&b.mutex` (identity mismatch) or tries to pair `&a.mutex` with
`b.value` (container mismatch). Pointer aliases remain conservatively outside
the supported place language.

The real positive driver is `rtos_demo`'s ownership-bearing rendezvous.
`stable_owner_wrong_lock_wrong` fixes the cross-lock negative contract, while
the prior missing-guard and dropped-result fixtures remain rejected. The
guard, identity, and lock relation erase; lowering is still one typed load and
store of the owner variant.

This closes the known "any linear guard opens any stable slot" hole but is not
a general invariant predicate. A private module can still mint a lying view,
and it remains responsible for the runtime `full` flag/tag relationship and
for implementing its guard producer with a real lock acquisition.

### Authority binding rebinding barrier (implemented 2026-07-17)

`Delta.Region_taint` now supports the reverse question "which live locals
depend on this authority place?" Before assignment or any local binder reuses
an owner/guard name, the checker rejects the operation if an in-scope derived
slice or pointer still carries that place in its taint. This prevents a fresh
owner or guard from clearing `Legacy_flow`'s consumed bit for the same
name-keyed place and incorrectly reviving a value derived from the old
lifetime.

The restriction is lifetime-sensitive rather than permanent. Reassigning a
mutable derived binding to an unrelated value clears its taint, and leaving
the derived binding's scope removes it from the live-dependent check. The
existing network and RTOS examples are the positive drivers;
`region_authority_rebind_wrong` is the focused negative, and unit tests cover
both slice and guard-derived pointer forms. The check is erased and adds no
runtime state or ABI change.

Raw casts, callee retention, and aggregate laundering were the remaining
explicit function-local limitations at this checkpoint. The next increment
closes aggregate laundering without weakening this rebinding check.

### Authority-derived aggregate storage barrier (implemented 2026-07-17)

An authority-derived slice or pointer can no longer be stored in a tuple,
variant payload, or struct literal. The checker recursively inspects nested
aggregate literals and reports the original directly tracked local. This
closes the function-local path where destructuring, matching, or field access
could recover an untainted alias after its owner/guard was consumed.

This increment deliberately rejects the aggregate construction rather than
adding tuple-component and variant-case shapes to `Delta.Region_taint`. No
current API needs a lifetime-bearing aggregate, while direct locals, aliases,
and subslices already cover the real network and RTOS examples. A future real
driver may justify precise aggregate region tracking without changing this
default-safe boundary.

`region_aggregate_launder_wrong` is the focused full-compiler negative. Unit
tests cover tuple, variant payload, and struct literal paths for both slices
and pointers. The barrier is checker-only and changes no runtime layout or
ABI. Raw casts and callee retention remain the two explicit region-v1
limitations.

### Deferred solver and prover threshold (not an active slice)

The current examples have exactly one executable `unsafe { ... }`, in
`tcp_echo`'s payload subslice. Its missing fact is quantifier-free linear
integer arithmetic:

```text
data_off = 34 + tcp_hdr_len
data_len = tcp_len - tcp_hdr_len
data_off + data_len = 34 + tcp_len
```

An SMT solver could discharge that bounds goal, but this does not justify
adding Z3 or solver-oriented `Phi` infrastructure now. The explicit `unsafe`
is a small, visible boundary and may remain until an independently required
real API demonstrates broader need. **Do not implement immutable symbolic
expression retention, verification-condition generation, or an external
solver solely to remove this site.** Runtime validation of packet- and
device-supplied lengths must remain in any future design; SMT is not
permission to assume external input is valid.

No current example justifies an external solver, proof artifact, `solve`, or
`prove` surface form. Verifying that a TCP builder emits a semantically correct
segment would first require a functional specification, a memory model, and
explicit lemmas; Lean4 integration remains out of scope unless such a
specification and a concrete compiler-facing need both exist. If the section 5
threshold is eventually crossed, a separate design pass must define the
automatic quantifier-free `Phi` fragment and focused negative tests before any
tool integration begins.

## 8. What to Keep and What to Replace

Keep the parser/LLVM pipeline, ordinary type inference, arrays, dynamic
slices, alignment, privacy, exhaustive matching, refinement intervals, and
`--forbid-trap`. They are useful inputs or backends for the Core.

Replace rather than preserve indefinitely:

- ownership being synonymous with `*OpaqueMarker`;
- integer-to-token and dummy-storage minting;
- pointer-only `borrow`/`sink`;
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
| #106 aliasing (closed; #128 carries the rest) | place identity, region/view predicates, and disjointness propositions; owner-derived region slices were its first closed slice |
| #128 escape control (first slices closed) | authority-bound pointer lifetimes extend region ties beyond slice returns, and stable exchange now names a same-container lock; general invariants remain |
| #87 asynchronous TX ownership | linear in-flight buffer/descriptor states and completion transitions |
| #15/#108 cast and visibility hardening | unforgeable constructors and module boundaries for runtime owners and views |
| #13 deferred SMT path (not active) | reconsider only after a required real API exceeds the built-in checker; do not implement Z3 or solver-only infrastructure from the roadmap alone |

When a slice reveals a genuinely independent acceptance criterion, create a
separate issue rather than expanding #89 or this architecture document into
an unclosable umbrella task.
