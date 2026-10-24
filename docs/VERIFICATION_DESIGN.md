# Verification design: initialization contracts

GitHub issue #954, step 2 (the thin vertical slice). The maintainer approved
the syntax and semantics skeleton on 2026-10-24. SPEC.md, "Initialization
contracts", is the language reference; this file records the design and why
it is shaped this way.

## Direction it follows (#954)

1. Explicit contracts at function boundaries: `requires` / `ensures`.
2. Inference only inside a function, and only in a fragment with a complete
   decision procedure: the init state is quantifier-free linear integer
   arithmetic over the function's immutable bindings.
3. Quantified properties (sparse init, #109) are out of this slice. They
   are left for explicit proof steps later, not trigger-driven instantiation.
4. z3 is a checker outside the trusted base. The compiler decides, and z3
   re-checks each conclusion through #952's obligation channel.
5. Errors name a concrete uncovered element (`element 8 of it (in [0, 16))`
   for constant terms; the first uncovered term otherwise). A failed z3
   re-check prints z3's model for `k`.
6. Verification time has a budget (below).

## Skeleton

```
requires init(P)                         P: a parameter, or a scratch slot
requires init(P[lo..<hi])                   G[s.index].f reached through a
ensures  init(P[lo..<hi])                   held linear owner s
ensures  init(P[lo..<hi]) if (result)    bool result; also result == false
ensures  match result { K(x) => init(...), K2 => true, _ => true }
```

`lo` and `hi` are linear terms over parameters, their `.len`, constants,
`result` and an arm's payload binder.

### The predicate inside a function

A tracked array or slice leaf that is not wholly `init` carries `Init(k)` for
`k` in a union of half-open intervals with linear bounds (lib/init_pred.ml).
Every fact that initializes a range is an instance of it:

| Source | Interval added |
|---|---|
| `P[j] = x` | `[j, j+1)` |
| `f(P[a..<b])`, `f`'s parameter `borrow uninit` with no ensures | `[a, b)` |
| `f`'s `ensures init(x[lo..<hi])`, argument view at offset `o` | `[o+lo, o+hi)` |
| `let r = slice_copy(P[a..<b], src)` | `[a, a+r)` |
| `for i in lo..<hi { P[i] = e }` (#888's shape) | `[lo, hi)` |
| `zero_fill(P)`, whole assignment | whole leaf |

#888's rule is now the row `for ... lo..<hi` with `lo = 0` and `hi` the
length. Its old restrictions (top-level store, no early exit, the counter as
the index) are unchanged and are what make the row sound. The old "length
equals N" restriction is gone.

Coverage of a goal `[a, b)` is decided by a walk that needs only constant
differences between terms (Init_pred.uncovered). It is sound and
incomplete. It never needs a quantifier or a solver call, so what it accepts
does not depend on a z3 version. Path equalities enter only from a
contract's own result (`return copied == destination.len`).

Representation 2, a bitmask for a constant N, turned out not to be needed:
with constant bounds the interval union is already an exact finite set, and
the walk decides it exactly. A separate bitmask would duplicate it.

### Lowering a contract match (decidability)

`ensures match result { K1(x) => C1, K2 => C2, _ => C3 }` lowers to one
implication per arm, `tag(result) = K1 and payload(result) = x => C1`, and
so on, with `_` covering the remaining tags. Each `Ci` is a conjunction of
`init` intervals with linear bounds, and its membership query is
`exists k. a <= k < b and not (k in union)`. That is quantifier free: `k` is
a free constant, and the payload is one more integer atom. Nothing in the
lowering leaves QF_LIA. Exhaustiveness is checked syntactically against the
variant's cases, like an ordinary match. Two limits keep it decidable rather
than merely satisfiable. A payload that is not an integer cannot appear in a
bound, because the bound must be a linear term. And a caller gets an arm's
facts only in a `match` directly on the call, where the tag and payload are
the arm's.

### Why a scratch-slot contract is tractable (the frame problem)

In VeriFast and ATS2 a pre- or postcondition on global state is hard because
any call in between may change the global. Each callee then needs a frame
condition saying what it leaves alone, and those conditions spread through
the program. Here a contract may name a global only as
`syscall_scratch[slot.index].f` with `slot` a parameter of a `linear struct`
owner (`SyscallSlot`). The frame then comes from ownership, not from
annotations:

- The element is reached only through the slot that indexes it. That is the
  existing per-CPU scratch premise (TRUSTED_BASE.md), and the linear slot
  enforces it at each acquire and release.
- A callee can change the element only if it receives the slot. A callee
  that does not receive it cannot touch the element, so no frame clause is
  needed for it.
- A callee that does receive it can only add initialized bytes. No
  operation makes an initialized byte uninitialized again; staleness is
  reset only at the entry of the next function that sees the scratch global,
  and there `requires` is exactly the statement that the caller hands it
  over initialized.

So an init fact about the slot's element survives every call in the
caller, and the check stays per function. Arbitrary mutable globals have no
such owner, and naming one is an error.

## Applied kernel sites

1. prlimit64 (`kernel/kernel/syscall.tkb`, syscall_prlimit64): the
   zero_fill of `rlimit_buffer` is gone. `syscall_rlimit_store` ensures
   `init(field[0..<8])`; its two calls cover `[0, 8)` and `[8, 16)`, which
   the 16-byte `copy_to_user` reads.
2. `copy_from_user` and `copy_from_user_span` (`kernel/mm/user_memory.tkb`):
   `ensures init(destination[offset..<offset + length]) if (result)`.
   prlimit64's set path then reads `rlimit_buffer` on success without a
   fill. The callee proof goes through `slice_copy`'s built-in contract and
   `return copied == destination.len`.
3. path_buffer: `kernel_syscall_path_name` ensures
   `init(syscall_scratch[slot.index].path_buffer)` (its zero_fill stays: the
   NUL tail is wanted), and `syscall_path_view_here` requires it. Its
   `unsafe { assume_init(...) }` is gone, so TRUSTED_BASE.md lists one site
   fewer. The requires is shown at all nine calls.

The other copy_from_user callers keep their zero_fill for now: each still
reads a range that depends on a path condition the checker does not track
(for example sockaddr's `x2 >= 28` branch).

## Census of workarounds before the slice (origin/main a17c1028)

Compiler `zero_fill(...)` sites: 17 (the other 11 grep hits are
`user_zero_fill`, a user-memory store, and its definition).
`unsafe { assume_init(...) }` sites: 4. `borrow uninit` parameters: 0.

| Shape | Sites | Count |
|---|---|---|
| Partial fill of a staging buffer by a callee, partial copy-out | syscall.tkb 2138, 2338, 2624, 3566, 8207, 8371, 4405 | 7 |
| Disjoint sub-slice stores that cover the buffer | syscall.tkb 6039 (rlimit; removed) | 1 |
| Zero is the meaning (NUL tail, ABI padding, cleared frame) | syscall.tkb 947, 983, 1953, 5997, 6127, 8469; frame_ref.tkb 177 | 7 |
| Default value for a path that never fills (struct, not array) | process.tkb 2318 | 1 |
| Cross-function scratch staging, `assume_init` | syscall.tkb 575, 586, 597 (execve, deferred), 1941 (removed) | 4 |

## Budget

The init obligations' cold z3 time is budgeted at 5 s on a kernel build.
`scripts/buildcheck_range_obligations.py` prints the share used
(`init-obligation-budget`). A cache entry keeps each obligation's cold
time, so the share is reported on warm builds too. Measured on the QEMU kernel on
2026-10-24: 7 obligations, 0.19 s cold (4%). The budget may grow when a
later change needs it, as long as the build and lane budgets are unaffected.

## Out of this slice

- The execve staging helpers (syscall.tkb 575, 586, 597): every function on
  the path from the zero_fill at 8469 to them would need `requires`.
- Path conditions other than a contract's result, interval merging across
  arms with different bounds, and sparse or quantified init (#109).
