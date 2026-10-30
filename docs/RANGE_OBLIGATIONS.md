# Range obligations

GitHub issue #952. The type checker derives a refinement range for the result
of `+`, `-`, `* k`, a constant `/`, `% m`, `& k`, the builtin `min`/`max`
(#984) and a widening cast. Each
derived range is built through `refined_or_base` (lib/type_inf.ml, mirrored in
lib/llvm_gen.ml), and each call names the operation and the operand ranges it
reasoned from. `takibi --facts DIR` turns every such
conclusion into one SMT-LIB file under `DIR/rangeobl/`, and `scripts/buildcheck_range_obligations.py`
asks z3 to refute it. The checker keeps deciding; z3 is a second, simpler judge
of its interval arithmetic, at the machine's own bit width.

## Where it runs

- Every kernel `main.o` build (QEMU and RPi5) emits `main.o.rangeobl/` and runs
  the check. On the QEMU kernel (2026-10-23): 513 distinct obligations from
  1790 sites; 3.6 s cold on 8 threads, 0.1 s with the verdict cache.
- `make range-obligation-control` (in `modelcheck`) compiles a Sub with #935's
  rule planted (`--internal-range-obligation-fault-control`: an unsigned base keeps a
  negative lower bound) and a `max` with #961's placeholder planted (an
  unknown u64 bound read as 10^9, #984), and requires z3 to report each
  counterexample. GitHub issue #960: the same flag plants the three historical
  misreadings of a constant, and z3 must refute each from the obligation's own
  expression: #956's native fold (`x & (0xFFFFFFFFFFFFFFFF / 64)` claims
  `{0..<1 as u64}`), #961's native leaf (`max(x & 3, 0xFFFFFFFFFFFFFFFF)`
  claims `{0..<4 as u64}`) and #983's native init leaf (see below).
- z3 4.13.4 is pinned and sha256-checked by `scripts/fetch_model_tools.sh`,
  which the devcontainer and the CI model-tools step already run.
  `TAKIBI_Z3` names another binary. Only `unsat` verdicts are cached, under
  `<model-tools>/range-obligation-cache-z3-<version>/<digest>`.
- GitHub issue #985: `<digest>` there is the MD5 of `canonical-v1` and the
  obligation's canonical form (comments dropped, init atoms `x_...` renamed by
  first occurrence), so obligations equal up to renaming share one verdict, in
  the cache and within one run. Obligations run in a few long-lived z3
  processes, `(reset)` and an `(echo)` marker after each, so each still gets
  its own verdict; anything but `unsat` is solved again alone, and that run
  gives the report and the counterexample; a query unanswered for 30 s kills
  its process. The range obligation control checks one batch keeps its verdicts
  aligned past a sat answer and a malformed query. Init obligations run first,
  in one process, so their budgeted time is not inflated by the parallel range
  obligations. On the QEMU kernel with 114 init obligations at load average 16:
  2.7-3.0 s before, 0.42-0.53 s after.

## File format, version 2

One file per distinct obligation, named `<md5>.smt2`, where the MD5 is over the
file's text without its `; site:` lines. An obligation derived at many sites, or
by both type_inf.ml and llvm_gen.ml, is one file.

```
; takibi-range-obligation v2
; site: kernel/net/tcp.tkb:812:20         (zero or more, sorted; not hashed)
; rule: sub                               add sub mul div mod band min max cast
; claim: {0..<1461 as usize}              the derived range, lo..<hi, and base
(set-logic QF_BV)
(declare-const a (_ BitVec 64))           operand a, at the operation's width
(assert (and (bvsle #b...0 ((_ zero_extend 2) a))
             (bvslt ((_ zero_extend 2) a) #b...)))   a in its known [lo, hi)
(declare-const b (_ BitVec 64))           operand b (binary rules)
(assert ...)
(define-fun r () (_ BitVec 64) (bvsub a b))
(assert (not (and (bvsle LO (ext r)) (bvslt (ext r) HI))))
(check-sat)
```

Meaning: some input inside its known range makes the machine operation land
outside `[lo, hi)`. `unsat` proves the range; `sat` is a counterexample.

- Operands. A range operand is declared and constrained to its `[lo, hi)`. An
  operand with no known range (`% m` and `& k` on a plain unsigned value) is
  declared unconstrained. A compile-time constant operand is
  `(define-fun a () (_ BitVec W) EXPR)`, where EXPR is the constant's SOURCE
  expression (GitHub issue #960): a literal is the low W bits of its 64-bit
  pattern (`0xFFFFFFFFFFFFFFFF` on u64 is all ones, not -1), a `const` name is
  its declared literal (`Const_env.raw_literal`), and `+ - * /` are `bvadd`,
  `bvsub`, `bvmul`, `bvudiv`/`bvsdiv` at W by the base's signedness. The
  checker's folded value is never written, so z3 evaluates the fold itself: a
  fold that differs from the machine's value (#956's
  `0xFFFFFFFFFFFFFFFF / 64` read as 0) is a counterexample, not an assumption.
  Version 1 inlined the folded value; z3 then checked the rule against the
  checker's own reading and answered unsat for #956, #961 and #983.
- Width and signedness. A binary rule's operands and result share the base's
  width (`usize`/`isize` follow the target's pointer width). A cast's operand
  `a` has the source width; `r` is `a` truncated (`extract`) or extended by the
  source's signedness.
- Operations: `bvadd`, `bvsub`, `bvmul`, `bvudiv`/`bvsdiv`, `bvurem`/`bvsrem`,
  `bvand`, by the base's signedness. `min` and `max` are the machine's compare
  and select, `(ite (bvult a b) a b)` and `(ite (bvugt a b) a b)` (`bvslt`/
  `bvsgt` when signed), the same `icmp` and `select` codegen emits; a bound an
  operand does not give is the base's own, so an unrefined operand is
  unconstrained. These two rules use only QF_BV terms the format already
  allowed, so they are not a version bump.
- Comparisons. Every bound comparison extends the value by two bits
  (`zero_extend` for unsigned, `sign_extend` for signed) and compares signed at
  width + 2, so `hi = 2^w` (u8's 256) is a constant like any other. Constants
  are written in binary (`#b...`).

The format is deliberately plain QF_BV with one existential query, so another
back end can read it unchanged: a Lean `bv_decide` proof of the same statement
(`forall a b, in_range a -> in_range b -> in_range (op a b)`) is the negation
of this query at the same widths. A constant operand's `define-fun` is a
closed QF_BV term, so such a proof would evaluate it by `decide`/`bv_decide`
too; a back end that instead took the constant as a parameter would have to
add the equation `a = EXPR` (#960). Changing anything above is a version bump:
the first line names the version, and the checker refuses other versions.

## Initialization obligations (GitHub issue #954)

The same directory holds one file per initialization coverage conclusion of
`lib/init_flow.ml` (lib/init_pred.ml builds it), under its own header:

```
; takibi-init-obligation v1
; site: kernel/mm/user_memory.tkb:302:5
; rule: init
; claim: init(destination[0..<destination.len])
(set-logic QF_LIA)
(declare-const x_len1 Int)                 one Int per atom (a binding, a .len)
(assert (and (<= 0 x_len1) (< x_len1 18446744073709551616)))
...
(assert (= x_len1 x_v4))                   path equalities the checker used
(declare-const k Int)
(assert (and (<= 0 k) (< k x_len1)))       k inside the goal [a, b)
(assert (not (or false (and (<= 0 k) (< k x_v4)))))   k in no known interval
(check-sat)
```

`unsat` proves the goal covered. Terms are mathematical integers: each comes
from a slice bound or index the program bounds-checks, so no wrap is
modelled. The checker prints the share of the cold z3 time budget these use
(`init-obligation-budget`, 5 s on a kernel build; a cache entry keeps each
obligation's cold time), and `make range-obligation-control` also plants a
false coverage claim and requires the counterexample `k = 7`.

GitHub issue #960: an init term is exact over mathematical integers (Init_pred
refuses a native overflow), so the one fold it carries is the reading of each
literal or `const` leaf. Each leaf the checker reads gets its own obligation
in the same header, `; rule: leaf`:

```
; takibi-init-obligation v1
; rule: leaf
; claim: literal 0xffffffffffffffff at usize
(set-logic QF_LIA)
(declare-const k Int)
(assert (= k 5))                           the checker's reading
(assert (not (= k 5)))                     the literal's pattern, unsigned at usize
(check-sat)
```

The right-hand value is printed from the source's 64-bit pattern
(`Const_env.raw_literal` for a `const`), not through the checker's reading, so
`sat` (z3's `k`) names a misreading such as #983's -1. A new rule in the same
QF_LIA shape, so not a version bump. `SizeOf` leaves have no literal and are
not checked this way. On the QEMU kernel (2026-10-24, load average 23): 871
obligations, 231 of them leaves; the init share of the cold budget went from
0.33 s to 0.93 s (19% of 5 s), and the whole check runs 2.7 s cold on 8
threads.

GitHub issue #990: a term is built from `a - b`, `a + b` or `k * a` only
when the checker judges that the step does not wrap at usize (#983). Each such
judgement also gets an obligation, `; rule: nowrap-sub` (the term is >= 0) or
`; rule: nowrap-add` (the term is below 2^W), under the same path equalities
and facts that the checker searched:

```
; takibi-init-obligation v1
; rule: nowrap-sub
; claim: m - 1
(set-logic QF_LIA)
...                                        atoms, equalities, facts
(declare-const k Int)
(assert (= k (+ x_v3 (- 1))))
(assert (not (>= k 0)))                    or (not (< k 2^W)) for nowrap-add
(check-sat)
```

The query states the machine property itself, not the checker's sufficient
reason (an atom bound, a fact chain), so `sat` names the wrapped value. Like
the leaf rule, this is a new rule in the same shape, not a version bump.
`make range-obligation-control` plants a checker that judges every `a - b`
not to wrap, and requires `k = -1` for `m - 1`. On the QEMU kernel
(2026-10-24): 85 no-wrap obligations out of 954; the init share of the cold
budget is 1.06 s (21% of 5 s), and the whole check runs 2.6 s cold.

## Region statics and header overlays (GitHub issue #986 slice 2)

Two more memory-safety decisions write obligations in the init format
(`; takibi-init-obligation v1`, so they count against the same 5 s cold
budget):

- `rule: region`. When `Types.unify_static`'s polynomial normal form says two
  different static terms are equal -- the offset and count arithmetic that
  makes a wrong-order `region_merge` or a count mismatch a type error -- the
  terms as written become `(assert (not (= s1 s2)))` over integer atoms
  (`x_p<id>` a rigid parameter, `x_v<id>` an unbound one), in QF_NIA. A
  variable solved by linking, and two identical terms, write nothing: there
  is no conclusion to check.
- `rule: overlay`. An accepted header overlay (`bytes as &T`) writes the
  header's size as z3 sums it from the field types as written (a recount,
  not `const_type_size`) against the slice's proven minimum length:
  `(assert (not (<= size n)))`.

`make range-obligation-control` plants both: an off-by-one static identity
(a merge whose tail starts one element late) and an overlay that accepts a
slice one byte short, and requires z3 to refute each. On the QEMU kernel
(2026-10-30): 1 region and 8 overlay obligations; the init share is
3.41 s (68% of 5 s).

## The other type-size decisions (GitHub issue #1233)

Every other decision that reads `const_type_size`'s figure for memory safety
writes an obligation of the same shape: z3 recounts the size from the field
types as written (packed structs, integers, `bool`, arrays) and the
decision's conclusion over that recount is asserted false.

| rule | decision | asserted false |
|---|---|---|
| `size-cast` | a byte slice cast to `*T` outside `unsafe` | `sizeof(T) <= n` (proven minimum length) |
| `size-byte-view` | a pointer viewed as `[const u8; M..]` | `sizeof(T) >= M` |
| `size-dma-span` | `dma_device_span`'s largest end | `end <= sizeof(allocation)` |
| `size-dma-range` | `dma_prepare_rx`/`dma_finish_rx` on a fixed allocation | `bytes <= sizeof(allocation)` |
| `size-dma-lines` | a fixed DMA allocation's extent | `sizeof(allocation) mod L = 0` |
| `size-value` | `sizeof(T)` as a refined constant | `sizeof(T) = v` |

A type whose size depends on the target layout (an unpacked struct) has no
recount and writes nothing; `const_type_size` refuses those too. `make
range-obligation-control` plants a size one byte short (a cast then accepts
a 7-byte slice for an 8-byte struct) and one byte long (`sizeof` answers 9)
and requires z3 to refute both. On the QEMU kernel (2026-10-30): 3
`size-dma-lines`, 4 `size-dma-span` and 5 `size-value` obligations.

## Not covered

- A wire-endian cast (`u16be <-> u16`) keeps the logical value's range and has
  no arithmetic to check; its `refined_or_base` call carries a
  `no-range-obligation:` comment, which `check_refined_range_constructor.py`
  requires of any call without `~ob`.
- Facts that are not built through `refined_or_base`: Value_facts, narrowing
  from conditions, for-loop counters, and the constant folds other proof sites
  read directly (`Const_env.folded_value`). Moving whole judgments to
  obligations is the later step of #952 and #13.
