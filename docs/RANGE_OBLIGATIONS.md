# Range obligations

GitHub issue #952. The type checker derives a refinement range for the result
of `+`, `-`, `* k`, a constant `/`, `% m`, `& k` and a widening cast. Each
derived range is built through `refined_or_base` (lib/type_inf.ml, mirrored in
lib/llvm_gen.ml), and each call names the operation and the operand ranges it
reasoned from. `takibi --emit-range-obligations DIR` turns every such
conclusion into one SMT-LIB file, and `scripts/buildcheck_range_obligations.py`
asks z3 to refute it. The checker keeps deciding; z3 is a second, simpler judge
of its interval arithmetic, at the machine's own bit width.

## Where it runs

- Every kernel `main.o` build (QEMU and RPi5) emits `main.o.rangeobl/` and runs
  the check. On the QEMU kernel (2026-10-23): 513 distinct obligations from
  1790 sites; 3.6 s cold on 8 threads, 0.1 s with the verdict cache.
- `make range-obligation-control` (in `modelcheck`) compiles a Sub with #935's
  rule planted (`--range-obligation-fault-control`: an unsigned base keeps a
  negative lower bound) and requires z3 to report the counterexample.
- z3 4.13.4 is pinned and sha256-checked by `scripts/fetch_model_tools.sh`,
  which the devcontainer and the CI model-tools step already run.
  `TAKIBI_Z3` names another binary. Only `unsat` verdicts are cached, under
  `<model-tools>/range-obligation-cache-z3-<version>/<digest>`.

## File format, version 1

One file per distinct obligation, named `<md5>.smt2`, where the MD5 is over the
file's text without its `; site:` lines. An obligation derived at many sites, or
by both type_inf.ml and llvm_gen.ml, is one file.

```
; takibi-range-obligation v1
; site: kernel/net/tcp.tkb:812:20         (zero or more, sorted; not hashed)
; rule: sub                               add sub mul div mod band cast
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
  declared unconstrained. A literal is inlined as its bit pattern at the width,
  which is the value the machine holds (`0xFFFFFFFFFFFFFFFF` on u64 is all ones,
  not -1).
- Width and signedness. A binary rule's operands and result share the base's
  width (`usize`/`isize` follow the target's pointer width). A cast's operand
  `a` has the source width; `r` is `a` truncated (`extract`) or extended by the
  source's signedness.
- Operations: `bvadd`, `bvsub`, `bvmul`, `bvudiv`/`bvsdiv`, `bvurem`/`bvsrem`,
  `bvand`, by the base's signedness.
- Comparisons. Every bound comparison extends the value by two bits
  (`zero_extend` for unsigned, `sign_extend` for signed) and compares signed at
  width + 2, so `hi = 2^w` (u8's 256) is a constant like any other. Constants
  are written in binary (`#b...`).

The format is deliberately plain QF_BV with one existential query, so another
back end can read it unchanged: a Lean `bv_decide` proof of the same statement
(`forall a b, in_range a -> in_range b -> in_range (op a b)`) is the negation
of this query at the same widths. Changing anything above is a version bump:
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

## Not covered

- A wire-endian cast (`u16be <-> u16`) keeps the logical value's range and has
  no arithmetic to check; its `refined_or_base` call carries a
  `no-range-obligation:` comment, which `check_refined_range_constructor.py`
  requires of any call without `~ob`.
- Facts that are not built through `refined_or_base`: Value_facts, narrowing
  from conditions, for-loop counters, and the constant folds other proof sites
  read directly (`Const_env.folded_value`). Moving whole judgments to
  obligations is the later step of #952 and #13.
