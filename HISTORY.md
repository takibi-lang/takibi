# takibi Engineering History

This file holds the detailed, per-feature engineering log for takibi:
design rationale, bugs found and fixed, file-by-file change checklists,
and the chronological "why" behind each decision. It was split out of
`CLAUDE.md` on 2026-07-08 because `CLAUDE.md` is auto-loaded into every
Claude Code session's context and had grown past the 150k-character
context budget; this file is NOT auto-loaded, so read it explicitly when
you need the reasoning behind an existing feature or a checklist of files
a similar change should touch.

For the current language syntax/grammar, see `SPEC.md`. For build
commands, directory layout, and day-to-day operating instructions, see
`CLAUDE.md`.

---

### LLVM 19 Opaque Pointers
LLVM 19 has only one pointer type (`pointer_type context`). The element type must be passed explicitly to `build_load`.
For this reason, `gen_expr` returns `(Ast.type_expr * llvalue)` rather than just `llvalue`.

### Type Inference Environment is an Immutable Map
`tyenv` is `(ty * bool) Types.StringMap.t` (`Map.Make(String)` based; bool = is_mutable).
`Hashtbl` is not used. The signature of `infer_stmt`:
```ocaml
val infer_stmt : tyenv -> fenv -> ty -> ty StringMap.t -> Ast.stmt
               -> tyenv * ty StringMap.t
```
The second element of the return value, `raw_locals`, is the Let-binding type map for codegen (contains both mutable and immutable bindings).

### Files to Update When Adding a binop
When adding a new constructor to `Ast.binop`:
- **Reusing an existing token (3 files)**: `lib/ast.ml`, `lib/type_inf.ml`, `lib/llvm_gen.ml`
- **Adding a new symbol (5 files)**: the 3 files above plus `lib/lexer.mll` (token definition) and `lib/parser.mly` (precedence and grammar rules)

OCaml's exhaustive match check will report any omissions as compile errors.

### Bitwise Operator Precedence (differs from C in some cases)
`&` (Band) has **higher** precedence than comparison operators (lower in C).
This means `n & mask == 0` is interpreted as `(n & mask) == 0` (avoiding a well-known C pitfall).
`^` (Bxor) is **lower** than comparison (same as C). `a ^ b == c` becomes `a ^ (b == c)`.
`|` (Bor) is **lower** than `^` (same as C). `a | b ^ c` becomes `a | (b ^ c)`.
`>>` (Shr) and `<<` (Shl) are higher than `&` and lower than `+/-`. `n >> 4 & 0xf` becomes `(n >> 4) & 0xf`.
`%` (Mod) has the same precedence as `*` and `/` (multiplicative group).
`~` (Bnot) is a unary prefix operator at the same precedence as other unary ops (`*` deref, `&` addrof, unary `-`).

Precedence (low -> high): `||` < `|` < `^` < comparison < `&` < `as` < `+/-` < `>>` `<<` < `*` `/` `%` < unary (`~` `-` `*` `&`)

**`>>` is sign-aware**: for signed types (i8/i16/i32/i64) `>>` generates `ashr` (arithmetic, sign-extending);
for unsigned types (u8/u16/u32/u64) it generates `lshr` (logical, zero-extending). This matches standard C behavior.

### Refined-Type Bases Are Explicit in Source

**Superseded in part by "Refinement Numerical Type" below**: `TRefinedInt`/
`TypeRefined` no longer always represents as i32 at the LLVM level in
general -- it now carries its own base type (`TRefinedInt of int * int *
ty`), and `ltype_of_ast`/codegen represent it at that base's actual
width. Source annotations now require the explicit `{lo..<hi as base}`
form; bare `{lo..<hi}` is reserved for future contextual inference and is
currently rejected instead of silently choosing i32. The explicit form
can select any primitive integer base, and the
compiler's range-propagation machinery (Add/Sub/Mul/Band/Mod/min/max/
narrowing) also preserves non-i32 bases. Bounds are validated against the
selected base, not against a universal i32 limit. Subtyping a refined value into a
wider/narrower concrete type (u8, u64, usize, ...) remains a separate
check (`lib/types.ml`'s `TRefinedInt _, TU8/TU16/TU32/TU64/TUsize/TI8/
TI16/TI64 when ...` cases), unrelated to which base the value's own
representation happens to carry.

`lo`/`hi` come from the `INT` token (originally OCaml `int`, 63-bit; now
`Int64.t` -- see "64-bit Integer Literals" below for why that changed), so
a bound outside i32's range (e.g. `{0..<5000000000}`) used to parse and
type-check with no error, then silently misbehave at codegen time -- e.g.
`emit_refined_cast_check`'s `const_int (i32_type context) hi` truncates
`hi` to its low 32 bits, turning a nonsensical range into a wrapped-around
one with no warning. This was a real, if never-yet-triggered, latent
soundness hole (no example ever wrote a bound this large -- embedded
buffer sizes stay well under 2^31 -- but nothing stopped it).

Fixed in `lib/parser.mly`'s `type_expr` rule (the single grammar
production that ever constructs a literal `TypeRefined` from source,
covering every use site: parameter/return types, `let` annotations, and
`expr as {lo..<hi}` casts): `lo < -2147483648L || hi > 2147483647L` (an
`Int64.t` comparison now) is a compile error (`Types.TypeError`), raised
at the same `$symbolstartpos` pattern already used by `array_size`'s
unknown-constant error, before the checked value is narrowed to `int` via
`Int64.to_int` for storage in `TypeRefined`'s `int * int` fields (safe at
that point -- the check already proved it fits comfortably in i32, let
alone a 63-bit native int). The lower bound is currently unreachable via
source syntax (`{lo..<hi}`'s grammar only accepts a bare non-negative
`INT` token for `lo`/`hi` -- no unary minus support at the type level, a
separate pre-existing limitation, not one this check introduces), but is
included for when that syntax gap is closed. Test coverage:
`test/test_takibi.ml`'s parser_tests (in-range bound parses, out-of-range
upper bound is a `TypeError` mentioning "i32 range").

**Deliberately NOT addressed by this fix**: widening `TRefinedInt` itself
to genuinely support ranges beyond i32 (e.g. for `usize`/`u64`/`i64`
values whose real range exceeds 2^31, such as an SD card LBA offset
`lba * 512` on a card larger than 2GB). This is a bigger change (a new
LLVM-level representation choice, propagating through every binop/
narrowing rule) with no concrete example needing it yet -- deferred until
one does, per this project's usual practice of not generalizing ahead of
a real need. The guard added here only prevents *silent miscompilation*
of an out-of-range bound; it does not lift the range limit itself.

### 64-bit Integer Literals (IntLit's Payload: `int` -> `Int64.t`)

**The bug**: `Ast.IntLit` was `IntLit of int` -- OCaml's native `int`,
63 bits on a 64-bit host (`Sys.int_size = 63`). `lib/lexer.mll` parsed
literals via plain `int_of_string`, which raises an uncaught `Failure`
(a raw OCaml exception, not a clean compile error) for any literal at or
beyond 2^62 -- e.g. `0xFFFFFFFFFFFFFFFF` crashed the compiler outright,
even in a plain function body with no global involved. Below that
threshold there was a second, quieter bug: `lib/llvm_gen.ml`'s `gen_expr`
unconditionally embedded every `IntLit` as `const_int (i32_type context)
i`, truncating the value to 32 bits before the surrounding `coerce`/widen
logic ever got a chance to see it -- so `let x: u64 = 5000000000;` (a
value comfortably within OCaml's 63-bit int and requiring no cast at all)
silently became a *wrong*, truncated-then-zero-extended value, since
`const_int` wraps its input to the target type's width with no warning.
Filed as GitHub issue "IntLit support 64bit value" and fixed here.

**Representation choice: `Int64.t`, not a bignum**. u64's range
(0..2^64-1) does not fit in a *signed* 64-bit container either in
principle, but `Int64.t` is exactly the right tool anyway: LLVM constants
have no inherent signedness (a bit pattern is a bit pattern; `icmp`/
`ashr`/`lshr` are what apply a signed or unsigned *interpretation*), and
`Llvm.const_of_int64 ty v signed` already takes exactly this kind of raw
64-bit container. `Int64.t` -1 and u64's `0xFFFFFFFFFFFFFFFF` are the
same bit pattern; which one a piece of code means is a question the
*type* answers, not the *value*. This mirrors how the whole codebase
already treats integers (see `is_unsigned`, `coerce`'s sext/zext choice).

**Deliberately not a step toward i128/u128 today, but not a dead end
either**: no primitive type beyond u64/i64/usize exists in takibi yet, so
actually supporting one is out of scope here (per this project's usual
practice of not building ahead of a concrete need -- see the `TRefinedInt`
i32-range note above for the same reasoning applied to a different
subsystem). What this change *does* do is remove the one hard blocker
that would have made ANY future widening impossible: OCaml's native `int`
literally cannot hold a full 64-bit pattern, so no width wider than
"64 bits minus a bit for the tag" could ever have been represented at
all, no matter how the rest of the compiler was designed. `Int64.t` itself
tops out at 64 bits too, so it does not directly hold a future i128
value -- a real i128 add would still need a further representation change
(e.g. a pair of `Int64.t`, or a bignum library like `zarith`). What
*does* carry forward is the pattern this change establishes: a literal's
storage type is independent of, and wider than, what any *particular*
consumer needs, and consumers that only ever need a small, realistic
value narrow explicitly (see `int_of_intlit` below) with a defined,
sound fallback on overflow -- rather than every one of the ~30 call
sites across the compiler assuming the literal already fits whatever
width it happens to need.

**Lexer (`lib/lexer.mll`)**: hex and decimal digits are now accumulated
by hand in `Int64.t` space (`int64_of_digits`), not via `int_of_string`/
`Int64.of_string`. This is not just a width change -- `Int64.of_string`
range-checks a plain decimal digit string against Int64's *signed* range
(rejecting a perfectly valid u64 value like 2^63) and raises `Failure`
past 16 hex digits. Neither restriction matches what an integer literal
here means (a raw bit pattern, not a signed magnitude), so hand-rolled
digit-by-digit accumulation (`Int64.add (Int64.mul acc base) digit`) is
used for both bases instead, wrapping silently past 64 bits exactly like
hex already did -- an astronomically unrealistic edge case (no type in
this language is wider than 64 bits, so no literal ever legitimately
needs more), accepted as wraparound rather than turned into a new
diagnostic category no other part of the compiler has.

**The narrowing discipline (`Ast.int_of_intlit`)**: most of the compiler
(range propagation, narrowing, array sizes, alignment, enum
discriminants, `Const_env`) only ever needs to reason about small,
realistic values and was written entirely in native `int`, long before
this change. Rather than rewrite that machinery in `Int64.t` arithmetic
(high risk, no benefit -- these subsystems are already capped to small
values by their own domain, and refined bounds are stored as native `int`),
every one of those call sites now narrows via one shared helper:
```ocaml
let int_of_intlit (k : Int64.t) : int option =
  let i = Int64.to_int k in
  if Int64.of_int i = k then Some i else None
```
Round-tripping through `Int64.of_int (Int64.to_int k)` and comparing
catches exactly the case a plain `Int64.to_int` would get wrong: OCaml's
`int` is 63 bits, one bit short of `Int64.t`, so a genuinely-wide value
can silently wrap into the wrong native int with no warning -- the same
class of silent-miscompilation risk the `{lo..<hi}` i32-range check above
and the `Mod`/`lo>=0` sync rule both already guard against. What a caller
does with `None` splits into two disciplines, matching whether the call
site already had a defined "can't reason about this" fallback:
- **Analysis/proof call sites** (range propagation's `TRefinedInt`
  formulas, if-narrowing, the same-base subslice rule, `var_plus_const`,
  `slice_len_mins`) already had a conservative fallback for "this operand
  isn't a usable compile-time constant" -- `None` is routed into that
  exact same fallback (unrefined `TI32`, "don't narrow", "not this
  shape"), via a small `intlit_opt`/`IntLit k -> Ast.int_of_intlit k`
  wrapper duplicated (sync rule) in `type_inf.ml` and `llvm_gen.ml`.
- **Grammar positions with no such fallback** (`array_size`, `align(N)`,
  a struct's `align(N)`, an enum's explicit discriminant) use a second
  helper, `parser.mly`'s `narrow_int64 pos what n`, which raises a
  `Types.TypeError` instead -- there is no sensible "conservative" array
  size or alignment, so overflow here is a hard compile error, not a
  silent fallback.
- **Constant-index bounds checks** (`Index`/`AssignIndex` in
  `type_inf.ml`) are a hybrid: a literal too large to narrow is not
  merely "unprovable", it is certainly out of bounds for any real array
  (arrays are never anywhere near 2^63 elements), so it is reported as an
  out-of-bounds error directly rather than silently passing through.
- **`Const_env`** (`define_if_literal`/`bound_value`, backing array-size
  names and for-loop bounds) treats a too-large literal as if it were
  never a recognized bare-literal constant at all -- simply not recorded
  -- so each consumer's own pre-existing "not found" handling (an
  `array_size` name-lookup error, or `bound_value`'s conservative
  unrefined case) applies unchanged.

**Codegen (`lib/llvm_gen.ml`)**: `Llvm.const_int` takes a plain `int`, so
every direct construction site now uses `Llvm.const_of_int64` instead.
Two places needed more than a mechanical swap:
- **`eval_const_int`** (the global-initializer constant-folding
  evaluator added for `as`-cast/cross-global-reference folding -- see
  "Global Constant Folding" below) now threads `Int64.t` all the way
  through instead of `int`, including `mask_to_bits`'s truncating-cast
  masks (`Int64.logand`/`Int64.shift_left`, not native bit operators) --
  otherwise the SAME representational gap this whole feature closes
  would have just reappeared one level down, inside global constant
  folding specifically.
- **`gen_expr`'s `IntLit` case** (ordinary expression codegen, function
  bodies -- distinct from `eval_const`, which only handles global
  initializers) picks i32 vs i64 representation per-literal: i32 when the
  value is `0 <= i <= 0x7FFFFFFF`, i64 otherwise. This is **deliberately
  narrower than the full signed i32 range**, not merely "whatever fits in
  32 bits" -- `gen_expr` has no visibility into whether the surrounding
  context will eventually sign- or zero-extend this value (that decision
  lives in `coerce`, driven by the destination type's signedness, at some
  later, unrelated call site), and an i32 representation can only be
  safely widened *either* way -- reconstructing the identical 64-bit
  value regardless of which extension is later applied -- when bit 31 is
  clear. Once bit 31 is set, sign- and zero-extension diverge:
  `0xFFFFFFFFFFFFFFFF` (`Int64.t` -1) naively "fits" the full signed i32
  range too, but truncating it to i32 -1 and then *zero*-extending (as
  `coerce`'s `TypeU64` case does) gives the wrong
  `0x00000000FFFFFFFF`, not the correct all-ones value -- a real bug this
  project's own test suite caught (see `examples/int64`'s "argument" case
  below) before this narrower threshold was chosen. Routing anything with
  bit 31 set through the i64-native path instead sidesteps the ambiguity
  entirely: `i64 -> narrower` is always a sign-agnostic `build_trunc` (see
  `coerce`'s and `to_i32`'s narrowing branches), so a wide value
  reconstructs correctly regardless of which narrower type it ends up
  used as, with no need to guess a destination's signedness upfront.
- The old `to_i32` index helper described by the original implementation is
  gone. Current array/slice indices are `usize`, raw-pointer offsets are
  `isize`, and codegen normalizes them with `to_index_width` using the target
  pointer width without truncating 64-bit indices to i32.

**Files**: `lib/ast.ml` (`IntLit of Int64.t`, `int_of_intlit`,
`var_plus_const`/`slice_len_mins` narrowing), `lib/lexer.mll`
(`int64_of_digits`, `INT` token, char-literal productions),
`lib/parser.mly` (`%token <Int64.t> INT`, `narrow_int64`, every
`align`/struct-`align`/enum-discriminant/`array_size`/`{lo..<hi}` site),
`lib/const_env.ml` (`define_if_literal`/`bound_value`), `lib/type_inf.ml`
(`intlit_opt`, all range-propagation and bounds-check sites),
`lib/llvm_gen.ml` (`intlit_opt`, `gen_expr`'s `IntLit` case, `to_index_width`,
`eval_const_int`/`eval_const`, all range-propagation mirror sites),
`test/test_takibi.ml` (39 existing `IntLit n` patterns gained the `L`
suffix; new tests for full-width hex/decimal parsing, the local-u64 and
wide-function-argument codegen regressions, and array-size/`align(N)`
overflow producing a clean `TypeError`), `examples/int64/` (new QEMU
example exercising all three runtime-codegen-relevant forms -- a global,
a local variable, and a bare wide literal passed as a function argument
-- registered in `run_qemutest.sh`'s ordinary and no-trap example lists
and in the Makefile's `EXAMPLES`/`STM32_EXAMPLES`).

### Follow-up: `gen_expr`'s `?expected_ty` Hint (Genuinely Polymorphic
### Literals, Not Just Correct-by-Constant-Folding)

The 64-bit fix above left one honestly-documented gap: `gen_expr`'s
`IntLit` case, with no hint available, still had to *guess* i32 vs i64
from the literal's own magnitude, because it had no visibility into what
type the surrounding context actually wanted. For a literal already
sitting in an unambiguously-typed position (`let v: u64 = LITERAL;`, a
`return`, a function call argument, an assignment, a struct/array
literal field), this guess-then-`coerce` two-step happened to produce
the right final *value* -- but only because `coerce`'s `build_zext`/
`build_trunc`, given a compile-time-constant operand, get silently
constant-folded by LLVM into a single direct constant, erasing the i32
intermediate from the emitted IR. That erasure is an LLVM implementation
detail, not something this compiler's own architecture guaranteed --
confirmed by dumping unoptimized IR for `let w: u64 = LITERAL + n;`
(`n: i32`), where the i32 stage is NOT erased (`add i32 <lit>, %n` then a
real `zext i32 %addtmp to i64` instruction), because a runtime value is
involved and there is nothing left to fold.

**The fix**: `gen_expr` gained an optional `?expected_ty : Ast.type_expr`
parameter, defaulting to `None` (so every existing recursive call within
`gen_expr` itself, and any call site that has no natural type hint to
offer, is unaffected byte-for-byte). `IntLit`'s case checks it first: if
`expected_ty` names a concrete scalar type (`TypeI8`..`TypeUsize`,
`TypeBool`, or `TypeIo` wrapping one -- `io` is a storage qualifier, so
it is stripped before the check, matching how `io` is handled everywhere
else in this file), the literal is constructed DIRECTLY at that width via
`const_of_int64`, with the old magnitude-based i32-or-i64 guess now only
a fallback for when no hint is available or the destination is something
`?expected_ty` deliberately doesn't special-case (`TypeRefined`,
`TypeSlice`, a pointer -- the existing guess already serves those
correctly).

**Threaded from every call site that already knows a concrete expected
type**, each a small, targeted change (no broad "expected-type inference"
system added -- `Types.program_types` still only carries types by name,
not per-expression-node, so this is deliberately a *codegen-side*
threading of already-available name-keyed type information, not a new
type-inference capability):
- `Let` (both the immutable case, and the mutable case via
  `init_memory` -- which also covers nested struct/array literal fields,
  since `init_memory` recurses into those with each field's own type)
- `Return` (hinted by the function's own return type, `ret_ast`)
- `Assign` (a second, cheap lookup of the assignment target's stored type
  happens *before* evaluating the RHS, so the existing store-side match
  logic afterward is unchanged)
- `AssignField` (hinted by `field_info`'s already-resolved field type)
- `AssignDeref` (the pointer is evaluated first as before; its pointee
  type, once known, hints the value expression evaluated second)
- `AssignIndex` (a lightweight peek at the container's element type,
  mirroring the fuller match used later for the actual store, happens
  before the RHS is evaluated)
- Function call arguments, both direct (`Call` resolving to a known
  `fenv` function) and indirect (a function-pointer-typed variable) --
  each argument is hinted by its corresponding parameter's declared type

**Deliberately NOT threaded**: `BinOp` operands. `LITERAL + n` (`n: i32`)
genuinely should compute the literal as i32 -- that IS what unification
already required of the whole expression (both operands unify to the
same type) -- so there is no bug to fix there; only the FINAL result,
if used somewhere needing a wider type, needs a real runtime extension,
which already happens correctly. Conflating "the literal's own natural
type in this expression" with "the type some later cast might want" would
be a mistake, not a generalization.

**Verification**: `test/test_takibi.ml` gained
`assert_direct_i64_literal`, which inspects the actual generated
function body text (`Llvm.string_of_llvalue`) for the ABSENCE of any
`zext`/`trunc` instruction and the PRESENCE of the literal's exact bit
pattern -- a stronger check than "compiles and returns the right value",
since that weaker check cannot distinguish "genuinely direct" from
"correct only because LLVM folded it". Confirmed directly via manual
unoptimized-IR dumps (a throwaway scratch executable linking this
project's own `Llvm_gen`/`Parser`/`Type_inf` modules and calling
`Llvm.dump_module`) before writing the automated tests, covering all of:
global, immutable local, mutable local, function argument (direct and
indirect call), assignment, struct field, array index, and pointer
deref -- all confirmed to emit the literal directly as `i64 -1`
(`0xFFFFFFFFFFFFFFFF`'s bit pattern) with no `zext`/`trunc` anywhere.
`examples/int64/int64.tkb` gained a `local_full_mask()` function
exercising this at runtime under QEMU too (a value that, unlike
`local_big_value()`'s 5\_000\_000\_000, only reaches the correct answer
because of this fix -- 5 billion happened to already round-trip through
the old guess-based path correctly, since it doesn't have bit 31 set;
`0xFFFFFFFFFFFFFFFF` is the case that actually needed a hint).

### Refinement Numerical Type: {lo..<hi} Generalized to Carry Any Base Integer Type

Historically `TRefinedInt`/`TypeRefined` was ALWAYS represented as i32 at
the LLVM level, no matter which integer type a `{lo..<hi}` value was used
with (see the older note on this below, now superseded) -- this meant
`is_unsigned (TypeRefined _)` always returned `false` unconditionally,
which was a real bug: a refined value derived from a u64 (e.g. via `&`,
`min`/`max`, if-narrowing) silently lost its unsignedness the moment it
became refined, so a subsequent i32/i64 BinOp width-sync could pick
`sext` instead of `zext` for it. Fixed by generalizing `TRefinedInt`/
`TypeRefined` to a 3-argument form that carries its own base type:
`TRefinedInt of int * int * ty` (`types.ml`) / `TypeRefined of int * int *
type_expr` (`ast.ml`) -- `{lo..<hi}` is no longer implicitly i32, it is
"a value of type `base` known to be in `[lo, hi)`", where `base` is
(by convention, not enforced by the type system itself) one of
i8/i16/i32/i64/u8/u16/u32/u64/isize/usize.

**Files changed** (the same "sync rule" duplication pattern as every
other feature in this file -- type_inf.ml and llvm_gen.ml were changed in
lockstep, verified by re-running the full test suite after each pass):
1. `lib/types.ml` -- `TRefinedInt of int * int * ty`; `unify`'s
   `TRefinedInt, TRefinedInt` case now also unifies the two bases (not
   just checking bounds equality); every subtyping-into-concrete-type rule
   (`TRefinedInt _, TI32/TI64/TU8/.../TUsize`) keeps its existing
   bounds-only condition, now with `_` for the ignored base field; the
   generalized anti-subtyping guard (`t1, TRefinedInt (lo, hi, base) when
   t1 = repr base -> raise (Unify_error "cannot pass unproven ...")`) now
   fires for ANY base, not just i32.
2. `lib/ast.ml` -- `TypeRefined of int * int * type_expr` (surface AST
   mirror).
3. `lib/parser.mly` -- at this stage of the original generalization, the
   literal `{lo..<hi}` syntax still constructed
   `TypeRefined (lo, hi, TypeI32)`. This was subsequently superseded twice:
   first by explicit `{lo..<hi as base}` syntax, then by rejecting the bare
   form entirely so it no longer carries an implicit i32 default.
4. `lib/type_inf.ml` -- every TRefinedInt-producing site threads/unifies
   `base` instead of hardcoding TI32: `canon_ty` (widens to the value's
   OWN base, not always TI32 -- this single change is what fixed several
   previously-latent bugs in Mul/Bor/Bxor/Shr/Shl's fallback cases, see
   below), BinOp Add/Sub/Mul/Band/Mod, `narrow_from_cond`/`collect_bounds`
   (generalized from matching only `TI32` locals to matching any of
   i8/i16/i32/i64/u8/u16/u32/u64/isize/usize), the `Let` "proofs survive weaker
   annotations" `bind_ty` check, min/max (see its own paragraph below).
   `For` loop counters originally stayed `base = TI32` always regardless
   of the bounds' own type -- since generalized to follow the bounds
   instead; see "For-Loop Counters Follow the Bounds' Own Base Type"
   below for why that original choice turned out to be a real gap, not
   a settled design decision.
5. `lib/llvm_gen.ml` -- the codegen mirror of all of the above, plus the
   actual representation-width change: `ltype_of_ast (TypeRefined (_, _,
   base)) = ltype_of_ast base` (was hardcoded `i32_type context`), so a
   `{lo..<hi}` value with a u64/i64 base now genuinely occupies an LLVM
   `i64`, not a truncated-then-implicitly-widened i32. `is_unsigned`
   (**the fix for the originally-reported bug**) now recurses:
   `TypeRefined (_, _, base) -> is_unsigned base`. `coerce`, `ditype_of_ast`,
   `int_bits_of_ast`, and every Index/SliceOf/narrowing site were updated
   the same way.
6. `test/test_takibi.ml` -- all existing `TypeRefined`/`TRefinedInt`
   pattern matches and constructions updated to the 3-arg form (the
   literal-syntax tests all expect base = `TypeI32`, matching point 3
   above); new regression tests added for the two bugs found during this
   work (see below).

**Two latent bugs fixed as side effects of the systematic pass** (not the
originally-reported bug, but found while touching every call site):
- `canon_ty`'s old fallback (`TRefinedInt _ -> TI32` unconditionally)
  meant Mul/Bor/Bxor/Shr/Shl's "operation doesn't preserve the range"
  fallback cases returned a STALE, no-longer-valid refined range in some
  paths instead of correctly widening to the value's actual base type --
  a real, if narrow, pre-existing soundness gap. `canon_ty` now widens to
  the value's OWN base (`TRefinedInt (_, _, base) -> base`), which fixed
  this everywhere `canon_ty` is already called, with no new call sites
  needed.
- `llvm_gen.ml`'s min/max codegen previously called `to_i32` unconditionally
  on both operands (silently truncating a genuine u64 argument) and always
  used signed comparison (`Icmp.Slt/Sgt`, wrong for e.g. a u32 value with
  the top bit set). Both fixed to mirror BinOp's existing i32/i64
  width-sync-with-`is_unsigned`-for-extension-direction pattern, and to
  pick `Icmp.Ult/Ugt` vs `Icmp.Slt/Sgt` based on `is_unsigned`.

**Bug found and fixed DURING verification (a real regression caught by
the existing test suite, not a new one)**: the `Let` binding's "proofs
survive weaker annotations" check and the generalized anti-subtyping
guard both originally compared the extracted `base` field directly with
OCaml's structural `=` (`t_ann = base`, `t1 = base`). This is unsound
because `repr` (the HM union-find dereference function) only resolves
the TOP-LEVEL type passed to it -- it does NOT recursively resolve fields
NESTED inside an already-matched constructor. If `base` came from a
still-unresolved unification variable at the time the `TRefinedInt` was
constructed (e.g. `0x0f & v` where `0x0f`'s own type variable only gets
unified with `v`'s type LATER, inside the same expression), `base` could
still be a raw `TVar (ref (Link TI32))` rather than the plain `TI32`
constant, so `t_ann = base` compared `TI32` against a boxed TVar wrapper
and (structurally) never matched, silently discarding an already-proven
range. Caught by the existing "mask propagation is symmetric ... (v &
0x0f) * 4 carries {0..<16} to {0..<61}" test (which started failing with
an unexpected trap site after the generalization). Fixed by comparing
`repr base` instead of the raw `base` in both places. **Sync note for any
future code touching an extracted `base` field**: always `repr` it
before comparing/pattern-matching its concrete shape; the field is not
guaranteed pre-resolved just because the outer `TRefinedInt`/`TypeRefined`
value itself was matched via an already-`repr`'d discriminant.

**Second bug found and fixed DURING post-verification manual testing (not
caught by the existing suite -- none of it exercised min/max with a
non-i32 base before this work)**: min/max's "unknown bound" sentinel
range (`sentinel_lo = -1_000_000_000`, `sentinel_hi = 1_000_000_000`,
used when neither argument's range is statically known) is only a legal
value of the RESULT's base type when that base accepts negative numbers.
Before this generalization, min/max's result was always unified against
`TI32` (whose `TRefinedInt _, TI32 -> ()` subtyping rule has no `lo >= 0`
restriction), so the negative sentinel was always fine. Once min/max
started unifying its two arguments against EACH OTHER (letting e.g. two
`u64` arguments through), the SAME negative sentinel became illegal
against any unsigned destination (`TU8/TU16/TU32/TU64/TUsize`'s subtyping
rules all require `lo >= 0`), so `min(a, b)` with two unconstrained `u64`
parameters raised `cannot unify {-1000000000..<1000000000} with u64`, an
outright regression for a previously-nonexistent capability. Fixed in
both files (sync rule) by making `sentinel_lo` conditional:
`is_unsigned_ty base` (type_inf.ml) / `is_unsigned at` (llvm_gen.ml)
selects `0` instead of `-1_000_000_000`; `sentinel_hi` was left at
`1_000_000_000` unconditionally at the time, believed "imprecise for a
narrow base like u8, but conservative/safe, not unsound" -- **this belief
was wrong, corrected below.** The `base`/`at` value consulted here must
ALSO be resolved through `repr` before this check (same class of issue as
the `Let`/anti-subtyping fix above, applied proactively here since
`is_unsigned_ty` PATTERN MATCHES the base's concrete shape rather than
comparing it, and an unresolved TVar would silently fall through to "not
unsigned" regardless of what it actually resolves to). Regression tests:
`test/test_takibi.ml`'s `refnum_min_u64`/`refnum_max_u64` (unconstrained
u64 arguments, must not raise), `refnum_min_clamp_u64` (min against a
literal still proves an array index against a smaller buffer),
`refnum_narrow_u64` (if-narrowing a u64 variable proves an index with
zero trap sites).

**Follow-up fix (same session, prompted by the user asking specifically
whether the sentinel should be "clamped to the base's actual width"):
the "conservative/safe" claim above was wrong.** `sentinel_hi =
1_000_000_000` is only harmless for bases whose subtyping rule has no
upper-bound restriction at all (`TI32`/`TI64`, unconditional; `TU32`/
`TU64`/`TUsize`, `lo >= 0` only) -- but `TU8` requires `hi <= 256`, `TU16`
requires `hi <= 65536`, and `TI8`/`TI16` require `hi <= 128`/`32768`
(with a matching `lo` floor). A sentinel of 1 billion FAILS all four of
those checks outright, so a fully-unconstrained `min`/`max` call on two
u8/u16/i8/i16-typed arguments (e.g. `min(a: u8, b: u8)` with neither
argument statically bounded) raised a spurious `cannot unify` error --
the exact same class of regression as the u64 case above, just not
triggered by anything in the existing test suite (nothing exercised
min/max on a narrow base with no known bound at all) or by the earlier
manual verification (which only tried u64). Fixed by replacing the
single hardcoded sentinel pair with `min_max_sentinel base` (added right
after `is_unsigned_ty`/`is_unsigned`, sync rule), which returns the
correct per-base placeholder: `(-128, 128)` for i8, `(-32768, 32768)` for
i16, `(0, 256)` for u8, `(0, 65536)` for u16, `(0, 1_000_000_000)` for any
other unsigned base, `(-1_000_000_000, 1_000_000_000)` otherwise (i32/
i64) -- i.e. each narrow type's placeholder is its own true representable
range, while the wide types keep the original arbitrary-but-sufficient
constant (their subtyping rules don't care how large `hi` is anyway, so
there's no benefit to computing their true 2^31/2^63-ish bounds, and doing
so for i64/u64 would risk overflowing OCaml's 63-bit native `int`).
**`llvm_gen.ml`'s codegen mirror needed one additional correction found
while wiring this up**: `at` (the min/max call's own operand type) can
itself still be a `TypeRefined` wrapping the true base (e.g. one operand
was already narrowed by an outer `if` before reaching this call) --
`min_max_sentinel` pattern-matches concrete base constructors directly, so
calling it on a raw, un-`canon_ty`'d `at` would miss the `TypeU8`/`TypeI8`
/etc. cases, silently fall through to the wide generic sentinel, and
produce a bound that then fails `ret_ty`'s OWN subtyping check one line
later -- the same "extract the base without canonicalizing/repr'ing it
first" mistake as the two bugs above, just one call deeper. Fixed by
computing `let base = canon_ty at in` once and reusing that same `base`
for both the sentinel lookup and `ret_ty`'s construction (previously
`ret_ty` computed `canon_ty at` separately, a second call that coincidentally
gave the same right answer for `ret_ty` itself but not for the sentinel
if evaluated on the raw value). Regression test:
`test/test_takibi.ml`'s `refnum_min_u8_unconstrained` (u8/u16/i8/i16, all
four fully-unconstrained, must not raise).

**Deliberately NOT addressed by this generalization (both since resolved --
see the later sections in this file)**:
- The surface `{lo..<hi}` type syntax still meant "base i32" at this stage,
  with no source-level way to write a refined u64/i64 literally. Explicit
  `{lo..<hi as base}` syntax resolved the first problem; the implicit i32
  fallback was later removed as well, and the bare form is now rejected.
- `For` loop counters were hardcoded to `base = TI32` regardless of the
  loop bound's own type -- this was believed to have "no motivating
  example," which turned out to be wrong (`for i in 0..<s.len` is exactly
  such an example, and failed outright); see "For-Loop Counters Follow
  the Bounds' Own Base Type" below.
- This work does NOT change anything about how bare integer LITERALS are
  typed in a `BinOp` (`LITERAL + n` still directly computes as `n`'s own
  type, which was already correct -- see the "Deliberately NOT threaded"
  paragraph in the Polymorphic Literal section above). The user explicitly
  separated these two topics and asked for this generalization FIRST,
  planning to revisit BinOp/literal handling as a distinct discussion
  afterward.

**Full verification**: `make check` (langcheck, 363 unit tests -- up from
360, +3 for this work's own regressions -- stm32build, and all 125
qemutest cases including every `--forbid-trap`/no-trap check) passes with
zero regressions after both bugs above were fixed.

### Explicit-Base {lo..<hi as base} Surface Syntax

Motivated by a concrete need the "Deliberately NOT addressed" list above
predicted but didn't yet have an example for: rewriting the protocol
examples (`ip_parse`, `tcp_parse`, `icmp_echo`, `tcp_echo`, `http_server`)
to use natural wire-width types (`u8` for IP version/IHL/TTL/protocol,
TCP flags/data-offset; `u16` for ports/total-length; `u32` for TCP
sequence/ack numbers) instead of i32 everywhere. Several of these files
pass an `ihl: {20..<21}` value across a function boundary (e.g.
`build_echo_reply`, `build_syn_ack`, `parse_tcp`) to prove the same-base
subslice rule `ip[ihl..<ihl+tcp_len]`. Because the surface `{lo..<hi}`
syntax could only ever spell base = i32, passing a narrower-based local
into such a parameter failed to unify at all (`TRefinedInt`'s
subtyping/unification requires bounds AND base to match exactly for a
function argument -- there's no "narrower fits into wider" rule the way
slice minimum-length subtyping has), which transitively forced every
variable entangled in that one proof chain to stay i32-based even when
every one of them is naturally narrower on the wire. Lifting this
required letting a programmer spell a non-i32 base directly in source,
not just receive one indirectly from the compiler's own range-propagation
machinery (Add/Sub/Mul/Band/Mod/min/max/narrowing).

**Syntax**: `{lo..<hi as base}`, where `base` is one of i8/i16/i32/i64/
u8/u16/u32/u64/isize/usize (the same set "by convention" already documented as
`TRefinedInt`'s allowed bases). Reuses the existing `AS` token rather than
inventing new grammar -- `{20..<21 as u8}` reads as "a value in this
range, as this base type", and there is no ambiguity with the ordinary
`expr AS type_expr` cast (this form only ever appears between `hi` and
`RBRACE`, strictly inside the braces). The bare `{lo..<hi}` form (no `as`)
is reserved for future contextual inference and currently produces a
compile error asking for an explicit base.

**Per-base range validation, generalizing the existing i32-only check**:
just like a bare `{lo..<hi}` bound outside i32's range used to silently
wrap at codegen time before that check was added, `{lo..<hi as u8}` with
`hi > 256` would silently wrap via `const_int i8_type <hi>` with no
warning. `lib/parser.mly`'s new production validates `lo`/`hi` against
each base's own representable range (`base_bound_range`): i8 needs
`lo >= -128 && hi <= 128`, i16 needs `lo >= -32768 && hi <= 32768`, i32
matches the existing bare-form check, u8 needs `lo >= 0 && hi <= 256`, u16
needs `lo >= 0 && hi <= 65536`, u32 needs `lo >= 0 && hi <= 4294967296`.
i64/u64 impose no upper-bound check at all, matching `types.ml`'s own
`TRefinedInt` subtyping rules for those bases (which likewise never
restrict `hi`) -- and also sidestepping a real representational limit:
`i64`'s true upper bound (2^63) does not fit in an `Int64.t` `hi` value
either. `usize` is checked the same as `u32` (`hi <= 4294967296`) even
though it's i64-wide on AArch64/RISC-V64, because it's only 32-bit on
Cortex-M and the parser doesn't know the target yet at parse time --
conservatively assuming the narrowest supported width is the safe
direction (rejects some values that would be fine on a 64-bit target
rather than silently accepting values that would wrap on a 32-bit one).

**A real, previously-latent bug found immediately while testing this**:
the first program exercised through this new syntax (`let x: u8 = a &
mask; let y: u8 = x * 4;` then passing `y` into a `{20..<21 as u8}`
parameter) crashed `gen_func`'s own `Llvm_analysis.verify_function` with
`mul i8 %x, i32 4` -- an LLVM type mismatch. Root cause: `widen_load`
(aliased `to_arith_width`, used by every `Var`/`Index`/`FieldGet`/`Deref`
codegen case per the project's "narrow-typed gen_expr results must be
widened in-flight" invariant) pattern-matches `TypeI8|TypeI16|TypeI32` /
`TypeU8|TypeU16|TypeU32` explicitly but had no case for `TypeRefined` at
all, falling through to `| _ -> v` (return unchanged). **This was
harmless before the "Refinement Numerical Type" generalization above**,
because every `TypeRefined` value was i32-shaped in memory regardless of
what it represented, so returning it unwidened was a no-op (it was
already the right width). Once a `TypeRefined` value can genuinely be
i8/i16-shaped (e.g. `base = TypeU8`, reachable ever since that
generalization landed, just never exercised end-to-end until this new
syntax made it easy to write), the SAME fallthrough silently returned a
still-narrow value to a caller (e.g. `BinOp`'s Mul case) that assumes
arithmetic-width (i32/i64) input. This is the same class of oversight as
the `is_unsigned`/`canon_ty` fixes documented above, just in a THIRD
function that also needed the "recurse into `TypeRefined`'s base" case
and was missed in the original pass. Fixed by making `widen_load`
`rec` and adding `TypeRefined (_, _, base) -> widen_load base v` as its
first case (`lib/llvm_gen.ml`). Regression test:
`test/test_takibi.ml`'s `refnum_widen_mul`/`refnum_widen_add`/
`refnum_widen_call_site` (Imm bindings with a narrow refined base used in
further arithmetic and passed across a `{lo..<hi as base}` parameter
boundary; `expect_codegen_ok` catches a regression here because
`gen_func`'s IR verifier -- not a hand-written assertion -- is what
actually fails).

**Files**: `lib/parser.mly` (`int_base_type_expr`, `base_bound_range`,
`check_refined_base_range`, the new `{lo..<hi as base}` production),
`lib/llvm_gen.ml` (`widen_load`'s `TypeRefined` case), `test/
test_takibi.ml` (parser tests for all 10 bases + the out-of-range/
no-upper-bound-for-64-bit cases, codegen regression tests for the
`widen_load` bug). This unblocks, but does not itself perform, the
protocol-examples rewrite described above -- that is tracked separately.

### The Protocol Examples Rewrite: i32-Forced Refinement Locals -> Natural
### Wire-Width Types

Rewrote `ip_parse.tkb`, `tcp_parse.tkb`, `icmp_echo.tkb`, `tcp_echo.tkb`,
and `http_server.tkb` so that fields naturally a single byte (IP version/
IHL/TTL/protocol, TCP flags/data-offset), a 16-bit half-word (ports,
total-length, window), or a 32-bit word (TCP sequence/ack numbers) use
`u8`/`u16`/`u32` instead of the i32 that was the only option before the
Refinement Numerical Type generalization and the explicit-base syntax
above. `arp_reply.tkb` needed no change (every field is compared inline,
no i32-forced refinement locals exist there); `refined.tkb`/`narrow.tkb`
(deliberately illustrate narrowing an i32-of-unknown-range index/MMIO
value -- i32 is the CORRECT type there) and `crc8.tkb`/`foreach.tkb`/
`int64.tkb` (checksum accumulators needing i32 headroom, or generic i32
input by design) were likewise left alone.

**A real, previously-latent bug found immediately while testing the
first rewritten file**: `pkt[0..<ihl]` (`ihl: u8`, `ip_parse.tkb`'s
existing `min(...)`-clamped IHL) raised `cannot unify u8 with i32`.
Root cause: `SliceOf`'s bound check in `lib/type_inf.ml` did `unify_at
lo_e.loc (canon_ty lo_t) TI32` -- `canon_ty` WIDENS a refined bound to
its bare base FIRST (e.g. `TRefinedInt(0,21,TU8) -> TU8`), and a bare
`TU8` has no unification rule against `TI32` at all. `Index`'s parallel
check (`unify_at idx.loc it TI32`, no `canon_ty`) never had this bug,
because unifying the RAW `TRefinedInt` directly relies on `types.ml`'s
existing base-agnostic subtyping rule (`TRefinedInt _, TI32 -> ()`,
unconditional regardless of the refined value's own base) -- exactly what
a u8/u16/etc.-based bound needs. This was invisible before this session's
work only because every refined bound was i32-based anyway (`canon_ty`'d
i32 unifies with i32 trivially, masking that `canon_ty` was doing nothing
useful there even then). Fixed by removing the `canon_ty` call, matching
Index's pattern exactly: `unify_at lo_e.loc lo_t TI32` /
`unify_at hi_e.loc hi_t TI32`. `llvm_gen.ml`'s codegen mirror
(`gen_bound`) needed no change -- it calls `to_i32` directly on the
LLVALUE (not the AST type), which already handles any integer LLVM width
correctly regardless of the AST type tag. Regression test:
`test/test_takibi.ml`'s `refnum_slice_bound_u8`.

**The `ihl`-entanglement finding, and why several fields stay i32 after
all**: the explicit-base syntax unblocks `ihl: {20..<21 as base}` as a
parameter, but `tcp_parse.tkb`/`icmp_echo.tkb`/`tcp_echo.tkb`/
`http_server.tkb` all compare `ihl`/`total_len`/`tcp_len` against
quantities ultimately derived from `net_rx_len()`'s device-reported value (`len`),
which is deliberately-unconstrained `i32` (external, device-reported,
per this project's `i32 = unknown range` convention). Casting a value to
a plain (non-refined-syntax) target type ALWAYS discards any refined
range the source had (`type_inf.ml`'s `Cast` case: `| _ -> tgt`,
unconditional) -- so bridging `total_len`/`ihl` into a narrower base at
the point they're compared against `ip_len_in_frame = len - 14` would
silently break the narrowing chain the whole checksum-span proof depends
on. Consequences, worked out per file:
- `ip_parse.tkb`: no entanglement at all (its `ihl` is a purely local
  `min(...)`-clamped value, never compared against anything `len`
  -derived) -- `version`/`ihl`/`ttl`/`protocol` -> `u8`, `total_len` ->
  `u16`, no explicit-base syntax needed.
- `tcp_parse.tkb`: `ihl` IS a `{lo..<hi}` parameter, but `ip_total_len`
  there comes directly from `read_u16be` (inherently 16-bit, never
  compared against a `len`-derived value) -- `ihl: {20..<21 as u16}`,
  `ip_total_len`/`tcp_len` follow at `u16`; `flags`/`data_offset` (display
  -only, never touch the `ihl` chain) -> `u8`; ports -> `u16`; seq/ack ->
  `u32` (display-only via `uart_println_hex`).
- `icmp_echo.tkb`/`tcp_echo.tkb`/`http_server.tkb`: `ihl`/`total_len`/
  `ip_len_in_frame`/`tcp_len`/`tcp_hdr_len`/`data_len`/`data_off` ALL stay
  `i32` (the `len`-entanglement above). Only `version` (standalone),
  `doff`/`flags` (TCP's own byte-scale fields, never directly combined
  with the `ihl` chain -- `tcp_hdr_len = doff * 4` upcasts `doff` back to
  `i32`), ports, and seq/ack/`conn_snd_nxt`/`conn_rcv_nxt` (equality/
  increment only, confirmed no `<`/`>` ordering comparisons exist, so the
  CLAUDE.md caveat about `read_u32be`'s signed bit pattern for large seq
  numbers no longer applies to these fields at all) narrow.
- Wire-VALUE constants compared against a narrowed field follow it
  (`TCP_FLAG_*`/`PROTO_TCP` -> `u8`; `TCP_ECHO_PORT`/`HTTP_PORT` -> `u16`;
  `OUR_ISN` -> `u32`) -- unlike the pure OFFSET constants (`IP_TTL`,
  `TCP_SEQ`, `ARP_SHA`, ...), which stay `i32` as array indices, matching
  the codebase's existing for-loop-counter convention.
- A narrowed counter combined with an i32-entangled value needs one
  explicit cast at the point of combination, not a redeclaration:
  `conn_rcv_nxt = conn_rcv_nxt + (data_len as u32);` (`conn_rcv_nxt: u32`,
  `data_len: i32`, entangled). Safe because `conn_rcv_nxt`/`conn_snd_nxt`
  are never used as a slice bound or index anywhere -- no proof depends
  on their refined-ness (they have none to begin with, being plain
  running counters), so discarding it via the cast costs nothing.
- `netutil.tkb`/`inet_checksum.tkb`'s shared function signatures
  (`read_u16be`/`read_u32be`/`write_u16be`/`write_u32be`, `checksum_add`/
  `checksum_fold`) were NOT changed -- narrowing those ripples into every
  caller across 5 files for uncertain benefit; an explicit `as u16`/
  `as u32` cast at the call site gets the same local clarity without
  that ripple. `checksum_add`'s running `sum` accumulator keeps `i32` too
  (needs >16-bit headroom during folding, a correct design choice, not
  an oversight).

**A second real regression found via `--forbid-trap` while rewriting
`http_server.tkb`** (not merely a type error this time -- a SILENT loss
of a proof that had been catching zero trap sites before): naively
upcasting `doff` to `i32` right before multiplying (`(doff as i32) * 4`)
compiles fine and LOOKS equivalent, but a plain `as i32` cast discards
`doff`'s if-narrowed `{5..<16 as u8}` range (same "Cast to a
non-refined-syntax target always drops refinement" rule as above), so
`tcp_hdr_len` came out unrefined instead of the `{20..<61}` its own
comment claimed -- and `data_off = 34 + tcp_hdr_len` lost its upper bound
as a direct consequence, reopening a trap site at
`frame[data_off..<data_off+3]` (the TCP-options-skip / "GET" sniff,
previously proven by the same-base rule with ZERO runtime check). Caught
immediately by re-running `--forbid-trap` after the rewrite (exactly the
verification step the plan called for), not by a passing-but-wrong test.
Fixed with the EXPLICIT refined cast instead of a plain one:
`(doff * 4) as {20..<61 as i32}` -- `doff * 4` on the narrowed
(u8-based) `doff` proves `{20..<61 as u8}` via ordinary Mul propagation,
and casting that to an EXPLICIT `{20..<61 as i32}` target (same bounds,
different base) is a free coercion (the checked-refined-cast machinery
proves it needs no runtime check, since the source range already implies
the target range exactly) -- carrying the proven range across the width
change instead of discarding it. Applied to `tcp_echo.tkb` too for
consistency (not strictly required there for `--forbid-trap`, since that
file's equivalent `data_off`/`data_len` site is already `unsafe`-wrapped
and skips the check regardless of `tcp_hdr_len`'s range -- but a plain
cast would still have been quietly wrong in the same way, just invisible
there). **General lesson reinforced**: any `as ConcreteType` cast on a
value whose refined range is later needed for a proof is a potential
silent proof-loss point, not just a width conversion -- the explicit
refined-cast form (`as {lo..<hi as base}`) is the correct tool whenever
that range must survive a base change, now that the syntax exists to
express it.

**Verification**: every one of the 5 rewritten files was checked
individually (not just at the end) -- `dune build`, `--forbid-trap`
(zero new trap sites in each), a byte-exact diff against `.expected`
output for the parse-only demos (`ip_parse`, `tcp_parse`), and the live
`scripts/*_test.py` protocol tests under QEMU for the networked ones
(`icmp_echo_test.py`, `tcp_echo_test.py` -- including the data-echo stage
that exercises `tcp_echo.tkb`'s one `unsafe` site, `http_server_test.py`
-- including the request-counter bump). Full `make check` (langcheck,
370 unit tests, stm32build, all 125 qemutest cases) passes with zero
regressions after both bugs above were fixed.

### Follow-up: Narrowing the Remaining i32 Chain (ihl/total_len/tcp_len/
### tcp_hdr_len/data_len/data_off) in icmp_echo/tcp_echo/http_server

The three networked files above still had `ihl` and everything derived
from it declared `i32`, entangled via `total_len <= ip_len_in_frame`
(`ip_len_in_frame = len - 14`) with `net_rx_len()`'s deliberately
-unconstrained `i32` device-reported length. This entanglement is real,
but not an unliftable wall: `len` itself, once narrowed by its own
`if (len >= N && len <= 1514)` check, CAN be bridged into `u16` with the
explicit refined-cast syntax above -- the blocker was only ever "no way
to spell a non-i32 base," which that syntax now provides.

**The technique, worked out once and reused in all three files**:
1. Snapshot `len` into an immutable local (`let len_n: i32 = len;`)
   immediately upon entering the length-checked branch. This step is NOT
   optional: `len` is a function PARAMETER (always a `Mut` binding), and
   a `Mut` binding's if-narrowing lives in the separate `narrowing_ctx`
   side-table, consulted only by specific `Index`/`SliceOf` call sites --
   a bare `Cast` on `len` directly sees only its plain, unnarrowed
   declared type and would need a runtime check. An immutable snapshot's
   type inherits the CURRENT narrowing directly (the same mechanism
   already used elsewhere in these files for exactly this reason, e.g.
   `http_server.tkb`'s pre-existing `let n: i32 = len;` for the response
   -length case) -- confirmed empirically via a scratch test before
   touching the real files: casting the bare parameter left one trap
   site (`checked cast remains: i32 as {...} needs a runtime range
   check`); casting the snapshot instead proved clean.
2. Bridge the snapshot's proven range into `u16` with ONE explicit
   refined cast, right after the branch narrowing `ihl` establishes it's
   exactly 20: `let len16: u16 = len_n as {54..<1515 as u16};` (bounds
   matching that file's own `len >= 54 && len <= 1514` check exactly).
   This is a free coercion (no runtime check): the source range already
   implies the target range.
3. Everything downstream (`ip_len_in_frame`, `total_len`, `tcp_len`)
   inherits u16-based refined ranges through ORDINARY Sub/comparison
   propagation from `len16` -- no further hardcoded-bounds casts needed
   anywhere else in the chain, since propagation itself is already
   base-parametric (this session's earlier generalization).
4. `ihl`'s own declared type changes from `((ip[0] as i32) & 0x0f) * 4`
   (needing the `as i32` cast on `ip[0]`, itself u8) to plain
   `(ip[0] & 0x0f) * 4` with a `u16` annotation -- the initializer's own
   u8-based proof is DISCARDED by the mismatched annotation (`bind_ty`
   only preserves a refined initializer when the annotation's type
   EXACTLY matches the initializer's base; u16 != u8), but this is
   harmless here because the only thing that matters, `ihl == 20`
   equality-narrowing right below, re-establishes `{20..<21 as u16}`
   fresh regardless of what `ihl` carried on the way in.
5. Every `{lo..<hi}`-typed FUNCTION PARAMETER (`build_syn_ack`/
   `build_fin_ack`/`build_data_echo`/`build_http_response_fin`'s `ihl`)
   must change to the SAME explicit base (`{20..<21 as u16}`) for the
   call to type-check at all -- passing a `u16`-based argument into an
   `i32`-based `{lo..<hi}` parameter fails the exact-match requirement
   for `TRefinedInt`-into-`TRefinedInt` parameters.

**A real, previously-latent bug found in `http_server.tkb` specifically
(NOT present in `tcp_echo.tkb`)**: `let data_len: u16 = tcp_len -
tcp_hdr_len;` (no `max(.., 0)` clamp, unlike `tcp_echo.tkb`'s already
-existing one) failed with `cannot unify {-60..<1461} with u16`.
`tcp_len - tcp_hdr_len`'s raw Sub-derived range has a spuriously negative
lower bound (the type system can't see the `tcp_len >= tcp_hdr_len` guard
just above that makes a genuinely negative result impossible) -- this was
ALWAYS true, even in the original i32 code, but harmless there because
`TRefinedInt`-into-`TI32` subtyping has no `lo >= 0` restriction. Once
`data_len` targeted `u16` (whose subtyping DOES require `lo >= 0`), the
same latent imprecision became a hard type error. Fixed by adding the
identical `max(tcp_len - tcp_hdr_len, 0)` clamp `tcp_echo.tkb` already
had -- a genuinely safe, behavior-preserving fix (0 still fails the same
downstream `data_len > 0`-style check a negative value would have), not
a workaround.

**Sites needing exactly one explicit cast, and why others don't**: any
expression mixing a now-`u16`-based `ihl`/`tcp_len`/etc. with an
UNRELATED plain-i32 value needs one cast at that mixing point (e.g.
`build_http_response_fin`'s `(ihl as i32) + 20 + n`, where `n` is an
app-level HTTP response length with no wire-width meaning; `app_main()`'s
`tx_len = 14 + (ihl as i32) + 20 + payload_len`). Conversely,
`tcp_echo.tkb`'s `build_data_echo` needed NO such cast for its
`ihl + 20 + n` because its `n` (a snapshot of `data_len`, itself derived
from the SAME entangled chain) was changed to `u16` too, keeping the
whole expression consistently based -- the general principle is: a value
genuinely PART OF the wire-width chain should follow it into `u16`; a
value that is merely APP-LEVEL bookkeeping (response byte counts,
request counters) should stay `i32` and get an explicit cast at the one
point it's combined with the chain, per this session's earlier
established `request_count`/`body_len`/`payload_len` decision.

**Verification**: identical discipline to the initial rewrite --
`dune build`, `--forbid-trap` (zero trap sites) per file, the live
`scripts/*_test.py` protocol tests (including `tcp_echo_test.py`'s
data-echo stage, exercising the file's one `unsafe` site with the new
u16-typed `data_off`/`data_len`), STM32 cross-compilation, and a final
full `make check` (langcheck, 370 unit tests, stm32build, all 125
qemutest cases) with zero regressions.

### For-Loop Counter Typing (Current)

A `for` counter follows the bounds integer base and carries a refinement when
the bounds are compile-time constants. An explicit annotation such as
`for i: usize in 0..<n` pins the base directly. Body constraints may infer an
otherwise unresolved base, but if neither bounds nor body determine it the
compiler reports an undetermined-counter error; there is no implicit i32
fallback. Array/slice use pins the counter to `usize`, while raw-pointer use
requires `isize`. Code generation reads the resolved `__for_<name>` type, so
the LLVM PHI and arithmetic width match the inferred source type.

### Array and Slice Indices Must Be usize

Safe array/slice indexing is not polymorphic.
`Index`, `AssignIndex`, and both bounds of an array/slice `SliceOf` require
`usize` (or a `TypeRefined` whose own base is `usize`). An unresolved bare
literal or for-loop counter is pinned to `usize` by the indexing use. A
refined value with another base must cross the boundary explicitly, e.g.
`ihl as {0..<21 as usize}`, so its range proof is retained. A plain
`as usize` is legal but intentionally discards the proof and may leave a
runtime bounds check.

Raw pointers are intentionally separate: `p[i]` and
`unsafe { p[lo..<hi] }` are low-level signed displacement operations and
require `isize` (or a refined integer whose own base is `isize`). Bare
literals infer as `isize`; an already-typed `i32`/`usize` value needs an
explicit cast. They carry no array-length guarantee or runtime bounds check.

Codegen normalizes every GEP index to the target's pointer width through
`to_index_width`: i64 on AArch64 and i32 on Cortex-M. The former `to_i32`
path silently truncated a genuine AArch64 `usize` index to i32; GEP treats
that i32 index as signed, so values from 2^31 onward addressed the wrong
element. Widening preserves the
source signedness for raw-pointer offsets; safe array/slice indices are
unsigned. Slice runtime checks compare `usize` bounds with unsigned
comparisons, avoiding the incorrect rejection of valid values with the top
bit set.

One codegen bug surfaced during this migration: BinOp width synchronization
replaced the narrower operand's semantic AST type with the wider operand's
type. Consequently `{0..<7 as usize} + 1` was treated as adding two
`{0..<7}` ranges and became `{0..<13}`, instead of `{1..<8}`. Width sync now
changes only LLVM values; interval propagation keeps each operand's original
semantic type.

### Undetermined let/let mut Types Are a Compile Error, Not an i32 Default

Prompted by a design discussion after the for-loop fix above: should this
language have ANY silent default for a type the compiler can't determine?
`Types.to_ast`'s `TVar (Unbound _) -> Ast.TypeI32` fallback meant a bare
`let x = 5;` (no annotation, nothing else ever constraining `x`) silently
became a plain `i32` local -- including for `let mut`, where `x` gets a
REAL, stable alloca (a debugger-visible memory location). The concern,
distilled: "looks fine, wrong binary representation" is exactly the class
of bug this project exists to eliminate elsewhere (the explicit
`{lo..<hi as base}` syntax, the Polymorphic Literal `?expected_ty`
threading) -- a stable memory location whose width the programmer never
consciously chose is the same shape of gap, just at the `let` level
instead of the type-literal level.

**Scope, deliberately narrower than "no defaults anywhere"**: this ONLY
applies to `let`/`let mut` (local and global). It deliberately does NOT
extend to internal, ephemeral type-inference decision points like a
for-loop's residual "neither bound determines anything" fallback (see the
section above) or `min`/`max`'s sentinel handling. Two distinct reasons,
not one:
- Most "can't infer" cases at those OTHER sites turn out to be "hasn't
  been propagated yet" rather than genuinely undecidable -- the for-loop
  fix above is the concrete proof: `for i in 0..<s.len` wasn't
  undecidable, it was just being forced into i32 without ever looking at
  `s.len`'s own type. Punting every such gap to a mandatory annotation
  would make the PROGRAMMER responsible for closing compiler
  completeness gaps that are better fixed by propagating more
  information, exactly as `for` was.
- A for-loop counter is very often a purely ephemeral SSA/register value
  with no stable, independently-inspectable memory representation the way
  a `let mut` binding's alloca has -- the "wrong binary representation in
  a hardware-debugging dump" concern that motivates this section applies
  much more directly to a value that is actually, stably stored somewhere.

**Implementation**: a new `is_undetermined t` (in `lib/type_inf.ml`, right
after `canon_ty`/`require_integer`) recognizes a bare unresolved
`TVar (Unbound _)`, or a `TRefinedInt` whose own `base` still is (e.g.
`let x = min(5, 10);` with no annotation -- `min`/`max`'s Call case can
itself leave the base an open TVar when NEITHER argument pins one).
Nested TVars are otherwise unreachable in this language: no written
type-expression position ever embeds an inference placeholder, so this
covers every realistic case without needing a fully general recursive
type-tree walk.

**A real design mistake found and fixed WHILE implementing this, not
after**: the first attempt checked `is_undetermined` immediately, inline
in the `Let` case itself, right after computing `bind_ty`. This rejected
the entirely ordinary `let x = 1; return x;` pattern (10 existing unit
tests broke) -- the function's own return-type unification, which
determines `x`'s type, is processed by a LATER statement, so checking
eagerly at the `Let` site sees `x` as still-unresolved and reports a
false positive. The same class of mistake, one level up: an EARLIER
GLOBAL's type can be pinned by a LATER global's reference (`let g = 5;
let h: i32 = g;`, via the existing `Var vname` cross-reference case in
Pass 2) or by a FUNCTION BODY'S usage (`let g = 1; fn f() i32 { return g;
}`, only resolved in Pass 3) -- checking right after Pass 2 (the first
placement tried for the global case) is still too eager.

**Fix: defer the check to the point where nothing further could ever
constrain the type.** For locals, this means AFTER the whole function
body has been processed, not inline in `Let`: a new `check_undetermined_lets
fdef raw_locals` (mirroring `check_const_shadowing`'s existing `go_stmt`
traversal shape exactly) re-walks the already-parsed AST purely to
recover each un-annotated `Let`'s source location for the error message
-- `raw_locals` only maps name -> type, with no location, and threading a
location map through `infer_stmt`'s signature everywhere was judged more
invasive than one extra lightweight syntactic pass, the same tradeoff
`check_const_shadowing` already made. For globals, this means AFTER Pass
3 (function bodies) entirely, not right after Pass 2 -- moved to
immediately after `functions` is computed, before `program_types` is
constructed. `LetDef`/`genv` carry no source location at all (the
codebase's existing `Lexing.dummy_pos` precedent for other whole-program
global checks applies here too).

**Verification**: `test/test_takibi.ml` gained two rejection tests (a bare
local `let x = 5;`, a bare global `let g = 5;`) and three
deferred-resolution regression tests (local: determined by a later
`return`; global: determined by a later global's reference; global:
determined only by a function body's usage) -- the exact three "checking
too eagerly would reject this" shapes found while building this feature.
Four pre-existing tests needed an explicit annotation added (their
snippets, e.g. `let mut x = 0; x = 1;` in an enum-match-arm body, never
actually determined `x`'s type any other way -- confirmed by tracing
through `unify`'s own `TVar, TVar` case, which only LINKS the two
placeholders together without ever attaching anything concrete). Full
`make check` (langcheck, 379 unit tests, stm32build, all 125 qemutest
cases) passes with zero regressions -- notably, not a single example in
the entire codebase relies on an undetermined bare literal anywhere.

### for i: T in lo..<hi -- Explicit Base Annotation on the Loop Counter

The programmer can spell a counter's base directly when bounds and body
usage do not determine it. Surface
syntax: `for i: u8 in 0..<4 { ... }` gives `i` the type
`{0..<4 as u8}` -- exactly, both the width AND the compile-time bounds
proof, unlike the pre-existing `for i in 0..<(4 as u8) { ... }`
cast-based workaround (confirmed empirically to already work, at a real
cost: casting the bound literal makes it a `Cast` node, which
`Const_env.bound_value` doesn't recognize as a constant, AND `Cast` to a
non-refined-syntax target always discards the source's proven range --
see the "Refinement Numerical Type" section's Cast-and-proof-loss
discussion -- so the cast-based form gets `i: u8` but reopens a trap site
that the annotated form does not).

**Grammar**: `Ast.For` gained a second field,
`ident * type_expr option * expr * expr * stmt list` (the annotation sits
right after the identifier, matching source order and this language's
existing `IDENT COLON type_expr` convention for `let`/parameters). The
annotation's type is restricted to `int_base_type_expr` (the same 9
primitive integer types `{lo..<hi as base}` accepts), not the full
`type_expr` grammar -- a loop counter's type is always one of these by
convention, and a pointer/array/struct annotation would be nonsensical.
No new tokens needed (`COLON` and `int_base_type_expr` already existed);
`FOR IDENT COLON int_base_type_expr IN ...` is unambiguous against the
existing `FOR IDENT IN ...` (single-token lookahead after `IDENT`).

**Type-checking**: in `type_inf.ml`'s `For` case, an annotation unifies
`base_raw` against `of_ast ann_ty` IMMEDIATELY, right after the bounds are
unified against each other and before anything else -- this makes
`base_raw` concrete from the very start, so the deferred "still
unresolved after the body" path from the previous section simply never
fires for an annotated loop (its `TVar (Unbound _)` branch is dead code
for this case, reached only when there's no annotation and nothing else
pinned it either). A conflicting bound (`for i: u8 in 0..<n` where
`n: u16`) surfaces as an ordinary "cannot unify" error, the same way any
other concrete type mismatch is caught -- no special-casing needed.

**A real soundness gap found and closed while implementing this, not
after**: a bare-literal for-loop bound has no inherent width of its own,
so when BOTH bounds are recognized by `Const_env.bound_value` (i.e. the
counter gets wrapped in `TRefinedInt(lo, hi, base)`) AND an explicit
annotation is given, the bounds must be validated against the ANNOTATED
base -- without this, `for i: u8 in 0..<300 { ... }` would silently
construct `TRefinedInt(0, 300, TU8)` and wrap around at codegen time via
`const_int i8_type 300`, exactly the class of bug the `{lo..<hi as
base}` surface syntax's own `check_refined_base_range` already exists to
prevent for the OTHER place a base gets attached to a literal bound.
Fixed by adding an analogous `for_annotation_bound_range`/
`check_for_annotation_range` pair in `type_inf.ml` (sync rule with
`parser.mly`'s `base_bound_range`/`check_refined_base_range` -- same
reasoning and the exact same per-base numeric ranges, just operating on
plain OCaml `int` bounds already narrowed via `Const_env.bound_value`
against a `Types.ty` base at TYPE-CHECK time, rather than `Int64.t`
bounds against an `Ast.type_expr` base at PARSE time for the literal
syntax).

**Verification**: `test/test_takibi.ml` gained parser/type-check tests
(the annotation parses for all 10 bases, gives the exact expected
`TRefinedInt`, rejects an out-of-range bound, rejects a conflicting
bound) and a codegen test confirming `for i: u8 in 0..<4 { buf[i] = ...;
}` proves the array access with ZERO trap sites (unlike the cast-based
workaround, which has one).

### The Undetermined-For-Loop-Counter Case Is Now Also a Compile Error

With the annotation syntax above in place, the one remaining reason the
previous two sections kept a SILENT i32 default for for-loop counters
(distinguishing them from `let`/`let mut`'s hard error) disappears: there
is now an explicit escape hatch, so guessing is no longer the only
alternative to an error. `type_inf.ml`'s `For` case's post-body check
changed from silently defaulting an unresolved `base_raw` to i32, to
raising the same class of error `let`/`let mut` already raise:
`"cannot determine a concrete type for for-loop counter '<name>': add an
explicit type annotation (e.g. `for <name>: i32 in ...`)"`.

**This is a genuinely wide-reaching, mechanical change, not just a
policy flip**: MOST existing for-loops in this codebase use a bare
literal bound (`for i in 0..<8`) and never pass the counter to anything
with a concrete type of its own (`buf[i]`/`arr[i]` alone never pins a
type -- see the previous two sections for exactly why), so this newly
requires an explicit `: i32` annotation across roughly 20 example files.
Every one was updated (`ip_parse`-style protocol files were unaffected --
their loops were already migrated to slices/`ForEach` earlier in this
project's history, or their bounds were already named constants/runtime
variables with their own concrete type, which was never the problem
case).

**A serious, unrelated methodology gap found while verifying this,
important enough to record on its own**: an initial `make -k check` run
(without `make clean` first) reported ZERO new failures, which was
WRONG -- a subsequent `make clean && make check` found 16 more affected
files the first run had silently missed entirely. Root cause: per this
file's own Makefile section, every per-example object-file rule depends
on `dune build` as an ORDER-ONLY prerequisite specifically so that
rebuilding the COMPILER doesn't force every example to recompile on
every invocation (a deliberate, previously-documented optimization).
The side effect, never previously exercised because no earlier compiler
change in this project's history happened to change ACCEPT/REJECT
behavior for code that was never touched: `make check` without `make
clean` first only recompiles `.tkb` files that changed, or that have
never been built -- an unchanged `.tkb` file's `.o`/`.elf` from a
PREVIOUS run (built with an OLDER version of the compiler) is treated as
up to date and never recompiled, so its stale, already-compiled binary
silently "passes" regardless of what the CURRENT compiler would do with
it. **Any compiler change that could plausibly alter accept/reject
behavior or generated code for existing, unchanged example files now
needs `make clean` before `make check` to get an honest signal** --
this was not needed for changes scoped to specific example files (which
naturally force their own rebuild), but IS needed for compiler-wide
policy changes like this one. Confirmed concretely: `examples/fibonacci/
fibonacci.tkb` (completely untouched by this change) passed under a
non-clean `-k check` and failed immediately after `make clean`.

**Verification**: after `make clean`, a full `make check` (langcheck, 388
unit tests, stm32build, all 125 qemutest cases including every
`forbid_trap_*` check) passes with zero regressions -- the first fully
honest, complete verification of this entire change (the pre-`make
clean` run's "zero failures" was a false negative, not a real pass).

### Soundness Condition for % Range Propagation

Range propagation for `n % m` (where m is a positive integer literal) returns `{0..<m}` **only when the left operand is guaranteed non-negative at the type level**.

- `n: {lo..<_}` with `lo >= 0` -> `TRefinedInt(0, m)` / `TypeRefined(0, m)` (safe)
- `n: i32` (possibly negative) -> `TI32` / `TypeI32` (conservative fallback)

**Rationale**: LLVM's `srem` returns a negative remainder when the dividend is negative (`(-5) % 8 = -5`, not 3).
Unconditionally returning `{0..<m}` for `n: i32` would cause `arr[(-5) % 8]` to be judged "safe",
producing an unsound buffer under-read with the bounds check omitted.

**Sync rule**: Both `lib/type_inf.ml` (`Mod` case) and `lib/llvm_gen.ml` (`Mod` case) have a `lo >= 0` guard.
Relaxing only one side causes them to disagree; always change them together.

### break / continue Implementation (4 Files)

Files changed when `break` and `continue` were added:
1. `lib/ast.ml` -- `Break` and `Continue` constructors in `stmt_desc`
2. `lib/lexer.mll` -- `"break"` and `"continue"` keywords
3. `lib/parser.mly` -- `BREAK SEMI` / `CONTINUE SEMI` statement rules
4. `lib/type_inf.ml` -- `in_loop: bool` parameter added to `infer_stmt`; `Break | Continue` raises `TypeError` when `in_loop = false`. `While`/`For` bodies pass `true`; `Block`/`If` propagate the current value.
5. `lib/llvm_gen.ml` -- `loop_stack : (break_bb * continue_bb) Stack.t` inside `gen_func`. Pushed on loop entry, popped on exit. `Break` emits `br break_bb`; `Continue` emits `br continue_bb`.

**`for` loop `continue` target is `incr_bb`, not `cond_bb`**:
The for loop has a dedicated `incr_bb` block that increments the counter and jumps to `cond_bb`.
`continue` jumps to `incr_bb` so the counter is always incremented before rechecking the condition.
`i_val` loaded in `cond_bb` dominates `incr_bb` (all paths to `incr_bb` go through `cond_bb`), so the SSA use is valid.

```
cond_bb: i_val = load ctr; if i_val < hi -> body_bb else exit_bb
body_bb: [body]  break -> exit_bb / continue -> incr_bb / fallthrough -> incr_bb
incr_bb: i_next = i_val + 1; store -> ctr; br cond_bb   <- continue target
exit_bb: ...                                              <- break target
```

### Unary Minus is Desugared in the Parser
`-expr` is converted to `BinOp(Sub, IntLit 0, expr)` (the `%prec UNARY` rule in `parser.mly`).
No changes to AST, type inference, or codegen are needed. `sub i32 0, %x` is also the canonical form of integer negation in LLVM IR.

### The as Cast Spans 5 Files
Files changed when `expr as T` was added:
1. `lib/ast.ml` -- `Cast of type_expr * expr` constructor
2. `lib/lexer.mll` -- `"as"` keyword
3. `lib/parser.mly` -- `%nonassoc AS` (lower precedence than arithmetic), `expr AS type_expr` rule
4. `lib/type_inf.ml` -- checks the source expression and returns the target type.
   **Pointer cast restriction**: `*T as X` where X is a fixed-width integer (`i8/i16/i32/i64/u8/u16/u32/u64`) is a compile error.
   Only `*T as usize` and `*T as *U` are allowed. Use `(ptr as usize) as i32` to make any truncation explicit.
5. `lib/llvm_gen.ml` -- `coerce` function selects the conversion instruction per target type:
   - `i32 -> u8`: `trunc i32, i8`
   - `u8/i1 -> i32`: `zext`
   - `i32 -> *T`: `inttoptr` directly (no manual zext step -- see the STM32 usize note below for why)
   - `*T -> usize`: `ptrtoint ptr, <usize_lltype>` (width follows the target's actual pointer size, not hardcoded)
   - `*T -> *U`: **no-op** (in LLVM 19, all pointers are the same `ptr` type, so the leading `if vty = dst_ll then v` in `coerce` applies; no compiler change needed)

**Invariant: narrow-typed (`i8/u8/i16/u16`) `gen_expr` results must be
i32/i64-widened in-flight, never returned as a bare narrow value.**
`widen_load` documents this: "arithmetic values arrive at `coerce` already
widened; `coerce` narrows only at the point of storage." `Var`/`Index`/
`FieldGet`/`Deref` all follow it. The `Cast` case's fallback branch once
didn't (`coerce v target_ty` with no re-widening), so `expr as u8` composed
with e.g. `arr[i]` (an i32-widened u8) via `==` produced two operands that
disagreed on LLVM type despite matching AST type -- `icmp eq i32 ..., i8 6`
crashed the LLVM verifier. Fixed via `to_arith_width target_ty (coerce v
target_ty)`. **Any future `gen_expr` case returning a narrow type must
widen before returning**, even though the AST type says narrow.

**`gen_func` verifies generated IR with `Llvm_analysis.verify_function` +
`raise (Error ...)`, not `Llvm_analysis.assert_valid_function`.** The
assert variant calls C's `abort()` on invalid IR (uncatchable OCaml-side),
which during the bug above killed `test_takibi.exe` with SIGABRT and
silently dropped every later test with no indication which one crashed;
`verify_function` produces a normal, attributable `[FAIL]` instead. Any
future `gen_func`-adjacent change should keep using this catchable path.
Regression coverage: `test/test_takibi.ml`'s `codegen_tests` group (via a
`gen_codegen`/`expect_codegen_ok` helper running parse -> infer ->
`Llvm_gen.gen_program` with no target machine).

### isize and Raw Pointer Arithmetic

`isize` is the pointer-sized signed integer counterpart to `usize`. Both use
LLVM DataLayout's actual pointer width (`i64` on AArch64, `i32` on Cortex-M),
but their roles are intentionally distinct: `usize` represents addresses,
lengths, and non-negative sizes; `isize` represents relative pointer offsets
and pointer differences.

Pointer arithmetic accepts no legacy `i32` exception:
- `*T + isize`, `isize + *T`, and `*T - isize` operate in units of `T` and return `*T`.
- `*T - *T` requires identical pointee types and returns an element count as `isize` via `Llvm.build_ptrdiff`.
- `p[i]`, `p[i] = value`, and raw-pointer slice bounds require `isize`, matching signed pointer displacement semantics.
- `*T + *T` is always a type error.
- A bare literal in pointer arithmetic infers as `isize`; an already-typed `i32`/`usize` value requires an explicit `as isize` cast.

The compiler does not track allocation provenance for raw pointers, so pointer
subtraction is only meaningful when both operands derive from the same array or
allocation. Slices remain the checked abstraction for ordinary bounded access.

### sizeof(T) Spans 4 Files
Files changed when `sizeof(T)` was added:
1. `lib/ast.ml` -- `SizeOf of type_expr` constructor in `expr_desc`
2. `lib/lexer.mll` -- `"sizeof"` keyword -> `SIZEOF` token
3. `lib/parser.mly` -- `SIZEOF LPAREN type_expr RPAREN` primary-expression rule (no special precedence needed; fully bracketed)
4. `lib/type_inf.ml` -- `SizeOf ty -> TUsize`, with a `senv`/`eenv` lookup that raises `TypeError "unknown type '%s' in sizeof"` for an undefined `TypeNamed` (catches typos at compile time rather than surfacing as an internal codegen error)
5. `lib/llvm_gen.ml` -- `ltype_of_ast ty` (resolves `TypeNamed` through the already-registered `struct_lltypes`, so packed/tail-padded sizes are correct) -> `Llvm_target.DataLayout.abi_size` against the `target_data` ref (same mechanism used for struct tail-padding) -> `const_int (ltype_of_ast TypeUsize) sz`

**Design note -- fixed `usize`, not a polymorphic literal**: unlike `IntLit` (which infers as `fresh ()` and unifies with any integer type via context), `SizeOf` always has type `usize`. This matches the project's established "explicit cast" philosophy for anything involving sizes/addresses (see the pointer-cast restriction above): `if (len >= sizeof(Hdr))` requires `len: usize`, not `len: i32`, since `unify TI32 TUsize` fails (no implicit coercion between fixed integer types in comparisons). Use `(len as usize) >= sizeof(Hdr)` when `len` is genuinely `i32`.

**Not supported**: `sizeof(T)` as an array size (`[T; sizeof(Foo)]`). Array-size constants are resolved entirely in the parser via `Const_env` (see "Global let / let mut and Array-Size Constants" above), before struct layout exists; `sizeof` needs `struct_lltypes`/`DataLayout`, which are only available at codegen time. Combining the two would require moving array-size resolution out of the parser into a later phase -- deferred until a concrete need arises.

### offsetof(T, field) Spans 5 Files

`offsetof(StructName, field)` is a compile-time constant of type `usize`
giving the field's byte offset in the target's actual struct layout. It
uses `Llvm_target.DataLayout.offset_of_element`, so natural padding, packed
structs, and target-specific alignment rules are handled by the same LLVM
DataLayout used by `sizeof(T)` and field GEP generation.

Files involved:
1. `lib/ast.ml` -- `OffsetOf of type_expr * string`
2. `lib/lexer.mll` -- `"offsetof"` keyword
3. `lib/parser.mly` -- `OFFSETOF LPAREN type_expr COMMA IDENT RPAREN`
4. `lib/type_inf.ml` -- requires a named struct, validates the field, and returns `TUsize`
5. `lib/llvm_gen.ml` -- resolves the field index through `field_info` and emits a `usize` constant from `DataLayout.offset_of_element`

Like `sizeof(T)`, `offsetof` is not supported in parser-time array-size
formulas because target DataLayout is unavailable during parsing.

### Codegen for Immutable and Mutable Variables
The locals table in `llvm_gen.ml` is managed as `(string, local_binding) Hashtbl.t`.

```ocaml
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* immutable: no alloca; holds the SSA value directly *)
  | Mut of Ast.type_expr * llvalue  (* mutable: alloca pointer *)
```

- `let x = e` -> evaluates the expression to an llvalue and registers it as `Imm`. No `alloca/store/load` is generated.
- `let mut x = e` -> allocates an `alloca` in the entry block (`Mut`) and emits a `store` at the declaration site.
- Function arguments are always `Mut` (parameters can be reassigned).

**`gen_stmt` is defined inside `gen_func`**. This is because the type of an immutable `let` must be resolved via the `res` function that references the HM type inference result. As an OCaml closure, `res` in the `gen_func` scope can be referenced naturally.

### Global Arrays and Uninitialized Global Variables
Uninitialized global variable declarations such as `let heap: [u8; 256];` are supported.

- Emitted as `undef` in LLVM IR (not `zeroinitializer`)
- Since `startup.S` zero-clears the BSS section, values are always zero at runtime
- Array type `[T; N]` can only be declared in global scope. Decays to `*T` in function arguments.

Uninitialized case in `gen_global`:
```ocaml
| None -> undef llty  (* BSS is zero-cleared by startup.S, so this is safe *)
```

### Global Variable Alignment -- align(N) (5 Files)

Files changed when `let x: T align(N)` was added:
1. `lib/ast.ml` -- `LetDef` 4th field: `int option` (`None` = no alignment, `Some N` = N-byte alignment)
2. `lib/lexer.mll` -- `"align"` keyword -> `ALIGN` token
3. `lib/parser.mly` -- `ALIGN` token; two new `item` rules for `align(N)` with and without initializer
4. `lib/type_inf.ml` -- all `LetDef` patterns updated to 4-tuple; alignment field is ignored during type checking
5. `lib/llvm_gen.ml` -- `gen_global` gains `align_opt` parameter; calls `set_alignment n gvar` when `Some n`

**Design note**: alignment is a property of a specific variable instance, not of the type.
`VirtqDesc` structs don't inherently need 4096B alignment -- only the descriptor ring array does.
Type-level alignment (`struct Name align(N) { ... }`) is a separate feature -- see
"Packed Struct and Struct Type-Level Alignment" below.

**Syntax**:
```
let mut buf: [u8; 4096] align(4096);      // no initializer (must be `mut`: no init requires mutability)
let reg: i32 align(64) = 0;               // immutable, with initializer
let mut counter: i32 align(64) = 0;       // mutable, with initializer
```
N must be a power of two (not enforced by the compiler; LLVM will assert at IR generation time).

### Global let / let mut and Array-Size Constants (7 Files)

Global scope now distinguishes immutable constants from mutable variables, mirroring local
variable semantics (`let` = immutable, `let mut` = variable), and a named immutable constant
with a literal initializer can be used as an array size.

Files changed:
1. `lib/ast.ml` -- `LetDef` gains a 5th field `bool` (`is_mutable`); `TypeArray`'s `int` size is
   unchanged (array-size constants are resolved entirely inside the parser, see below).
2. `lib/const_env.ml` (new) -- `(string, int) Hashtbl.t` mapping constant name -> value, populated
   incrementally as the parser consumes top-level items left to right. `reset ()` clears it (called
   once per compiler invocation in `main.ml`, and once per `parse` call in `test_takibi.ml` for test
   isolation). `define_if_literal is_mutable name init_opt` records `name` only when `is_mutable =
   false` and `init_opt` is a bare `IntLit` (no forward references, no constant folding).
3. `lib/parser.mly` -- `%inline mut_flag` nonterminal (`MUT` -> `true`, empty -> `false`) threaded
   through all `item`-level `LetDef` productions. The plain (non-`align`) production calls
   `Const_env.define_if_literal`. New `array_size` nonterminal used in the `[T; N]` grammar
   production: `INT` is used directly; `IDENT` is looked up via `Const_env.find`, raising
   `Types.TypeError` if not found (e.g. undeclared, declared later in the file, or declared with
   `mut`/a non-literal initializer). `array_size` also has `+`/`-`/`*`/`/` and parenthesized-grouping
   productions (added later, see "Array-Size Arithmetic Formulas" below) evaluating directly to an
   `int` during parsing, using the same flat-ambiguous-alternatives-plus-global-`%left`-precedence
   idiom the main `expr` grammar already uses for `PLUS`/`MINUS`/`TIMES`/`DIV` (confirmed this
   resolves precedence correctly for a second, unrelated nonterminal reusing the same token
   declarations -- `2 + 3 * 4` parses as `2 + (3 * 4)` = 14, not `(2 + 3) * 4`).
4. `lib/type_inf.ml` -- `LetDef` patterns updated to 5-tuple. `genv` now stores the real
   `is_mutable` flag instead of a hardcoded `true`. Because `Assign`/`AddrOf` already key their
   mutability checks off the shared `tyenv` (used for both locals and globals), `&const_global` and
   `const_global = ...` become compile errors automatically, with no new enforcement code. Pass 2
   additionally rejects an immutable global with no initializer.
5. `lib/llvm_gen.ml` -- `LetDef` patterns updated to 5-tuple; `gen_global` takes an `is_mutable`
   parameter and calls `set_global_constant true` on the LLVM global when `false`.
6. `bin/main.ml` -- calls `Const_env.reset ()` once before parsing the (possibly multi-file,
   concatenated) input.
7. `test/test_takibi.ml` -- `parse` helper calls `Const_env.reset ()` first (test isolation); all
   `LetDef` patterns updated to 5-tuple.

**Why resolve array-size constants in the parser, not via a `Types.ty`-level pass**: `Ast.TypeArray`
is pattern-matched directly (not via `Types.ty`) in roughly 15 places across `llvm_gen.ml` (locals,
globals, struct fields, `StructLit` codegen, tail-padding, etc.). Resolving the constant reference to
a plain `int` at parse time means `TypeArray` itself never changes shape, so none of those call sites
needed touching. The trade-off is that the constant must be declared textually before its use (no
forward references) -- acceptable since the feature is scoped to simple "declare a size, use it
below" readability, not a general compile-time-constant system.

**Example**:
```takibi
let QUEUE_SIZE: i32 = 4;              // immutable constant; &QUEUE_SIZE and QUEUE_SIZE = ... are compile errors
let mut ring: [i32; QUEUE_SIZE];      // resolved to [i32; 4] at parse time
```
See `examples/const_global/` (valid usage) and `examples/const_global_wrong/` (compile-error demo).

### Array-Size Arithmetic Formulas

`array_size` originally only accepted a bare `INT` or a single `Const_env`-resolvable name --
combining two constants (`QNUM * RX_BUF_SIZE`, `ETH_RX_DESC_COUNT * ETH_DESC_SIZE`) had to be
hand-computed into a literal, with a comment recording the formula so a future edit to either
constant wouldn't silently leave the array size out of sync (exactly the drift risk "Global
Constant Folding" below closes for a global's *value*, just on the *array-size* side instead).
`examples/common_qemu/virtio_mmio.tkb`'s `rx_queue_mem`/`tx_queue_mem`/`rx_bufs` and
`examples/common_stm32/eth.tkb`'s `eth_rx_descs`/`eth_tx_descs`/`eth_rx_bufs` all had exactly
this shape before this feature.

**Extended `array_size` to a small arithmetic grammar**, evaluated to a plain `int` directly
during parsing (no new phase, no `Types.ty` involvement -- same reasoning as the original
"resolve in the parser, not via a `Types.ty`-level pass" trade-off above still applies): a
literal, a `Const_env`-resolvable name, `+`/`-`/`*`/`/` combining two `array_size`s, or a
parenthesized `array_size` for grouping. Division by zero is a `Types.TypeError` at the
division site, not a crash. No forward references (same restriction as before -- a referenced
name must already be in `Const_env`'s table). `sizeof(T)` still cannot appear in an array-size
formula (unchanged from the existing "Not supported" note above -- `sizeof` needs
`struct_lltypes`/`DataLayout`, only available at codegen time, well after array sizes are
already resolved).

**Scope boundary vs. "Global Constant Folding" below**: this only widens the `[T; N]` grammar
position specifically. A global `let`'s own initializer expression is a completely separate
code path (`lib/llvm_gen.ml`'s `eval_const`/`eval_const_int`, operating on an already-parsed
`Ast.expr` at codegen time) and still cannot fold arithmetic BinOps -- `let ETH_DESC_SIZE: i32 =
ETH_DESC_WORDS * 4;` still fails with "unsupported constant expression" today, only
`let mut eth_rx_descs: [u8; ETH_RX_DESC_COUNT * ETH_DESC_SIZE];` (the array-size position) is
fixed by this feature. Likewise, a few remaining hand-computed literals with an explanatory
comment are deliberately NOT touched by this feature because they are not in the array-size
grammar position at all -- e.g. `examples/common_qemu/virtio_mmio.tkb`'s and
`examples/common_stm32/eth.tkb`'s `min(net_last_rx_desc_idx, 7)` / `min(eth_rx_cur, 3)` calls,
where the `7`/`3` is a plain function-call argument that needs to be recognized as a
compile-time constant by `Const_env.bound_value` (used by the refined-type range machinery),
not by `array_size` -- `Const_env.bound_value` still only recognizes a bare `IntLit` or `Var`,
not arithmetic, so `min(idx, QNUM - 1)` there still does not resolve to a proven range today.
Extending `Const_env.bound_value` the same way is a natural, still-open follow-up, not done as
part of this feature.

Files: `lib/parser.mly` (`array_size` grammar), `examples/common_qemu/virtio_mmio.tkb` +
`examples/common_stm32/eth.tkb` (hand-computed literals replaced with their formulas), 7 new
parser unit tests in `test/test_takibi.ml` (product/difference of named constants, operator
precedence without and with explicit parentheses, division, division-by-zero error, and an
undefined name inside a formula).

### Global Constant Folding: `as` Casts and Cross-Global References

Extends the same "compile-time constant" idea as the array-size constants
above (and reuses the same no-forward-references convention), but for the
*value* side: an immutable global's initializer can now be an `as` cast
chain (`let ETH_RDES0_OWN: i32 = 0x80000000 as i32;`) or a reference to an
earlier immutable global constant (`let HTTP_SERVER_IP: [u8;4] = OUR_IP;`),
not just a bare `IntLit`/`StructLit`. Motivated by two real pain points hit
during the STM32 Ethernet work (see git history around 2026-07): the `as
i32` cast above used to fail with "unsupported constant expression" (had to
be written as a bare literal instead), and `examples/common_stm32/
netconfig.tkb`'s `HTTP_SERVER_IP` had to duplicate `OUR_IP`'s array literal
verbatim, so the two could silently drift apart if only one was ever
edited. Both are fixed now (see that file and `examples/common_stm32/
eth.tkb`'s `ETH_RDES0_OWN`/`ETH_TDES0_OWN`).

**Design: fold in OCaml-int space, not via LLVM constant-expression ops.**
`lib/llvm_gen.ml`'s `eval_const_int` reduces an integer/bool-valued
constant expression (`IntLit`, an `as` cast chain, the unary-minus desugar
`BinOp(Sub, IntLit 0, _)` -- see "Unary Minus is Desugared in the Parser"
above -- or a `Var` reference) to a plain OCaml `int`, entirely without
calling into LLVM. This sidesteps a real gap: the LLVM 19 OCaml bindings
expose `const_trunc` but not `const_zext`/`const_sext`, so there is no
direct constant-folding primitive for a *widening* cast. Working in OCaml
int space avoids needing one at all -- `Llvm.const_int` already wraps/
truncates its input to the target width when the value is finally
embedded, exactly like the pre-existing `IntLit i, _ -> const_int
(ltype_of_ast ft) i` case already relied on. The only place explicit
masking is still needed is a *narrowing* cast **in the middle of a chain**:
`(300 as u8) as i32` must truncate to 44 before widening back to i32, or
the outer i32 cast would silently see the untruncated 300. `eval_const_int`
handles this by masking at every `Cast` layer using *that layer's own*
target width (from the AST node itself, not the outer caller's `ft`), so
each truncation happens at exactly the point the source `as` chain says it
should.

**Cross-global references reuse one table, `global_const_defs`**
(name -> declared type + original initializer expr), populated by
`gen_global` in source order as each immutable global with an initializer
is processed. `eval_const`'s new `Var name, _` case looks the name up and
recursively re-evaluates the *referenced global's own initializer
expression* against the current `ft` -- this one case handles scalar,
array, and struct references uniformly (no separate array-specific logic
needed), and `eval_const_int`'s own `Var` case does the same for the
integer-folding path. A `let mut` global is never recorded (its value can
change at runtime, so it is never a compile-time constant); referencing
one, or referencing a global declared *later* in the source (no forward
references, same restriction as `Const_env`'s array-size constants),
simply finds no entry and raises a clear `Llvm_gen.Error` rather than
silently reading a stale or wrong value.

**Why this didn't need a `type_inf.ml` change for scalars, but did for
arrays/structs**: `infer_expr`'s ordinary `Var` case decays an array-typed
variable to a pointer (correct for using the array as an ordinary
expression value, e.g. passed to a function) -- but a global referencing
another global by name means "copy that global's value", so unifying the
declared array type against the decayed pointer type was rejecting exactly
the case this feature exists to allow. Pass 2 of `infer_program` (global
initializer checking) now has a dedicated `Var vname` branch that looks
`vname` up in `genv` directly (the raw, undecayed type) and unifies
against that instead of going through `infer_expr`. Scalar references
already worked before this change (a scalar type never decays), so this
branch is a pure generalization, not a behavior change for the cases that
already passed.

**Deliberately NOT implemented**: general constant-expression arithmetic
(`Add`/`Mul`/etc. between two constants). The unary-minus case is handled
only because it is a single, very common, already-desugared shape
(`BinOp(Sub, IntLit 0, _)`); a broader "constexpr" evaluator was judged
out of scope for what was actually asked for (an `as` cast and a
same-value global reference), per this project's usual practice of not
generalizing ahead of a concrete need. Revisit if a real example needs
e.g. `let X: i32 = A + B;` between two global constants.

**Files**: `lib/type_inf.ml` (Pass 2's `Var` branch), `lib/llvm_gen.ml`
(`global_const_defs`, `eval_const_int`, `eval_const`'s `Cast`/`Var` cases),
`examples/common_stm32/eth.tkb` (`ETH_RDES0_OWN` cast restored,
`ETH_TDES0_OWN` now references it), `examples/common_stm32/netconfig.tkb`
(`HTTP_SERVER_IP` now references `OUR_IP`), 7 new unit-test cases in
`test/test_takibi.ml`'s `codegen_tests` (cast folding, chained truncating
cast, unary minus, scalar/array cross-references, and the two rejection
cases: mutable-global reference and forward reference).

### Function Pointer Types Span 5 Files
Files changed when the `fn(T...) -> R` type was added:
1. `lib/ast.ml` -- `TypeFn of type_expr list * type_expr` constructor
2. `lib/lexer.mll` -- `"->"` token, `"void"` keyword
3. `lib/parser.mly` -- `fn_type` non-terminal (`FN LPAREN type_list RPAREN ARROW type_expr`)
4. `lib/type_inf.ml` -- `Var` retrieves a function name as `TFun` from `fenv`; `Call` supports both direct and indirect calls
5. `lib/llvm_gen.ml` -- `ltype_of_ast (TypeFn _) = pointer_type context` (opaque ptr); indirect calls reconstruct `function_type` and use `build_call`

**Function pointers in LLVM 19**:
LLVM 19 has a single pointer kind (`ptr`, opaque pointer). `fn(i32) -> u8` and `fn() -> void` are both the same `ptr` in LLVM IR. The takibi type checker enforces type distinction; correct calling conventions are generated by passing `function_type` to `build_call`. Unlike C's `void*`, takibi's type checker enforces signature compatibility.

### extern fn Spans 5 Files
Files changed when external assembly function declarations like `extern fn timer_init();` were added:
1. `lib/ast.ml` -- `ExternFuncDef of ident * (ident * type_expr option) list * type_expr option`
2. `lib/lexer.mll` -- `"extern"` keyword
3. `lib/parser.mly` -- `EXTERN FN IDENT LPAREN params RPAREN (ARROW type_expr)? SEMI` rule
4. `lib/type_inf.ml` -- adds `TFun` in Pass 1 for `fenv`; `ExternFuncDef _ -> m` in the `genv` fold
5. `lib/llvm_gen.ml` -- emits `declare_function` in Pass 1 (Pass 2 does `ExternFuncDef _ -> ()`)

### Struct Implementation (7 Files)

Files changed when `struct Name { field: type; }` was added:
1. `lib/ast.ml` -- `TypeNamed of string` (type), `FieldGet of expr * string` (expr), `AssignField of expr * string * expr` (stmt), `StructDef of string * (string * type_expr) list * bool` (last bool = is_packed)
2. `lib/types.ml` -- `TStruct of string` (internal type), added `program_types.structs` field
3. `lib/lexer.mll` -- `"struct"` -> `STRUCT`, `'.'` -> `DOT` token
4. `lib/parser.mly` -- `%left DOT` (highest precedence), `struct_fields` rule, field assignment for both `s.field = v` and `arr[i].field = v`, `expr DOT IDENT` field read expression, `IDENT` -> `TypeNamed` type expression
5. `lib/type_inf.ml` -- `senv : (string * Ast.type_expr) list StringMap.t` collected in Pass 0 and threaded through all inference functions
6. `lib/llvm_gen.ml` -- registers `struct_type context fields` in Pass 0; `TypeNamed` returns the alloca/global pointer as-is (same approach as arrays); `FieldGet` uses `build_in_bounds_gep` + load; `AssignField` uses GEP + store
7. `test/test_takibi.ml` + `examples/struct/` -- parser/type-inference tests + QEMU demo

**Struct variable codegen design** (unified approach with arrays):
- `let mut s: Name;` local -> `alloca [struct_type]` -> `Mut (TypeNamed "Name", alloca_ptr)`
- `Var "s"` where `TypeNamed _` -> return the alloca pointer as-is (no load)
- Global struct variables are handled the same way (value of `define_global` = return the pointer as-is)
- `s.field` / `p.field` where `p: *Name` -> GEP `[0, field_idx]` -> load (auto-distinguished by type check)
- `s.field = v` -> GEP -> store (non-volatile; not MMIO)
- `arr[i].field = v` -> bounds-checked element GEP -> field GEP -> store; `ptr[i].field = v` uses pointer indexing without an array bounds check
- `&s` -> return the alloca pointer as `*Name` (for pass-by-pointer)

**Stale note, corrected while extracting SPEC.md**: this originally said
`let mut` was not supported for global struct variables. That is no
longer true (or was never actually enforced) -- `examples/irq/irq.tkb`,
`examples/scheduler/scheduler.tkb`, and `examples/bump/bump.tkb` all
declare `let mut x: Name;` at global scope and build/run correctly today.
A struct variable is always mutable storage regardless of the `let`/
`let mut` keyword, same as arrays.

### Packed Struct and Struct Type-Level Alignment (5 Files)

Files changed when `struct packed Name { ... }` and `struct Name align(N) { ... }` were added:
1. `lib/ast.ml` -- `StructDef of string * (string * type_expr) list * bool * int option` (is_packed, align_bytes)
2. `lib/lexer.mll` -- `"packed"` keyword -> `PACKED` token (`ALIGN` was already present)
3. `lib/parser.mly` -- 4 rules: plain / packed / align(N) / packed+align(N)
4. `lib/type_inf.ml` -- `StructDef (name, fields, _, _)` in Pass 0 (both flags irrelevant for type checking)
5. `lib/llvm_gen.ml` -- `packed_struct_type` when is_packed; `struct_alignments` table stores align_bytes per struct name; `set_alignment` applied at alloca (locals) and `define_global` (globals) time; also propagates to `[Name; N]` array allocas/globals

**Use case for packed**: protocol headers (Ethernet, IP, USB descriptors) and MMIO register maps where field layout must match hardware exactly without alignment padding.

**Use case for align(N)**: SIMD types (`Vec4 align(16)`), DMA descriptor rings (`Ring align(4096)`), cache-line-separated data. Alignment is set automatically on every variable of that type without repeating `align(N)` at each declaration site.

**Struct tail padding** (`lib/llvm_gen.ml` Pass 0): When `align(N)` is specified and `sizeof(struct) % N != 0`, an `[i8; pad]` field is appended to the LLVM struct type so that `sizeof(struct)` becomes the next multiple of N. This ensures every element of `[Name; K]` arrays satisfies the alignment requirement (same behavior as C `__attribute__((aligned(N)))`). `struct_fields` stores only user-visible fields; the padding field is invisible to GEP and type inference. Tail padding uses the LLVM DataLayout (`Llvm_target.DataLayout.abi_size`) stored in `target_data` ref set by `setup_target`.

**IntLit width sync in BinOp** (`lib/llvm_gen.ml`): `IntLit` always emits `i32` in codegen. When one BinOp operand is `i64` (usize on a 64-bit target) and the other is `i32` (from IntLit), the i32 is widened before the operation. This prevents an LLVM IR type-mismatch error on patterns like `usize_val == 0` or `usize_val & 15`. On a 32-bit target (Cortex-M), usize is itself `i32`, so this widening branch's `i64`-vs-`i32` mismatch condition simply never fires -- no separate code path needed for the two widths.

### Enum Implementation (5 Files)

Files changed when `enum Name: u16 { V = n; _; }` was added:
1. `lib/ast.ml` -- `EnumVariant of string * string` (expr), `Match / match_arm` (stmt, mutual recursion with `and`), `EnumDef of string * type_expr option * (string * int option) list * bool` (last bool = is_nonexhaustive)
2. `lib/lexer.mll` -- `"enum"` `"match"` keywords, `"::"` `"=>"` `"_"` tokens
3. `lib/parser.mly` -- `enum_variants` returns `(string * int option) list * bool`; `UNDERSCORE SEMI` sets `true`; `IDENT COLONCOLON IDENT` expr; `match expr { arms }` stmt
4. `lib/type_inf.ml` -- `eenv : (Ast.type_expr * (string * int) list * bool) StringMap.t` (bool = is_nonexhaustive) collected in Pass 0. `Match` exhaustiveness: exhaustive enum requires all variants or `_`; non-exhaustive enum requires `_` (listing all known variants is not enough).
5. `lib/llvm_gen.ml` -- `enum_underlying`, `enum_variants_tbl`, `enum_nonexhaustive` tables. `EnumVariant` -> integer constant. `Match` -> LLVM `switch`. `int as ExhaustiveEnum` -> switch+trap. `int as NonExhaustiveEnum` -> no-op (any integer is valid).

**Two kinds of enum**:
- Exhaustive (`_` absent): the type guarantees the value is one of the named variants. `int as Enum` traps on unknown values. `match` requires all variants or `_`.
- Non-exhaustive (`_` present): models open sets (IANA-registered protocol fields, etc.). `int as Enum` never traps. `match` requires a `_` wildcard arm (compiler enforces this).

**Round-trip guarantee** (intentional design, must not be broken):
`(raw as NonExhaustiveEnum) as u16 == raw` for any `raw: u16`, including values that fall through to the `_` arm. This holds because `enum -> int` cast is a no-op at the LLVM IR level: no `unreachable` is inserted, so LLVM cannot assume the value is one of the named variants. This differs from C enum (UB for out-of-range values) and is essential for protocol implementations where unknown field values must be forwarded or logged intact.

**Enum variants are valid global constant initializers**: both
`let mut state: State = State::Idle;` and an underlying-type constant such
as `let code: u16 = Code::Ready as u16;` are folded by `eval_const`/
`eval_const_int` to the variant's resolved discriminant. This keeps enum
globals explicitly initialized instead of relying on BSS zeroing and the
first variant remaining discriminant zero. `examples/tcp_echo` and
`examples/http_server` use this for their exhaustive `ConnState: u8`
state variables (Listen/SynRcvd/Established/LastAck), replacing the old
unrestricted i32 constants.

**eenv lookup pattern** (3-tuple destructuring):
```ocaml
let (_, variants, is_ne) = StringMap.find ename eenv in
```
`EnumVariant` inference and `Match` exhaustiveness check both use this pattern.

### --forbid-trap: Gradual Verification (permissive dev mode / proven ship mode)

**This workflow is a central goal of the project, not a side feature**:
start permissive (traps allowed -- a trap is not a bug but a SIGNAL that
type information is missing), strengthen types incrementally (for-loop
refinement, {lo..<hi}, slice minimum lengths, narrowing), and finally ship
with --forbid-trap, which guarantees the emitted binary contains zero trap
instructions. SPARK/Dafny assume rigor from day one; takibi's bet is that
raising rigor PER DEVELOPMENT PHASE, supported at the language level, is
the right shape for embedded work ("Gradual Elimination of Runtime Traps").
Two invariants keep the path to ship monotonic:
- **Proofs are only lost at mutation points, never at annotation**: an
  immutable `let` keeps the initializer's proven type (slice minimum /
  refined range) even under a weaker annotation -- a weaker annotation must
  never manufacture trap sites out of already-proven code, because those
  would resurface as ship-time rejections with no real proof gap behind
  them. `let mut` keeps its declared (honestly weak) type: reassignment
  can bring weaker values, so its checks mark real gaps.
- **Unchecked assertions are visibly marked** (`unsafe { ... }`, see below):
  the checks/trap axis and the trust axis stay separate.
Naming note for the future: --forbid-trap may later split into per-category
options (array-bounds trap freedom, checked-cast freedom, safe-pointers-
only, ...) with today's flag becoming the umbrella that enables all of
them; a rename (e.g. --notrap) is on the table then. Not worth churn yet.

`takibi ... --forbid-trap` rejects compilation if ANY runtime trap check
remains in the generated code, listing every unproven site with its source
location (all of them, not just the first -- same report-all philosophy as
run_qemutest.sh). Without the flag, behavior is unchanged: unproven accesses
compile fine and get a runtime check (llvm.trap on violation) -- that IS the
intended permissive development mode for quick driver bring-up. The flag is
ship mode: only type-proven accesses may exist. **The current example suite
compiles clean under --forbid-trap**.

**Mechanism** (`lib/llvm_gen.ml` `trap_sites` / `record_trap`): every trap
check codegen emits (array bounds check, checked refined cast, exhaustive-
enum cast) is recorded with loc + human-readable reason at IR-generation
time. bin/main.ml reads the list after gen_program and errors under the
flag. **The judgment is deliberately type-level, not post-optimizer**: LLVM
passes (correlated-propagation etc.) may well fold a given check away, but
"the optimizer happened to remove it" must never count as proof -- the
guarantee has to stay deterministic across LLVM versions. Consequence:
`while (i < 8) { arr[i] }` is rejected even though LLVM elides its check;
the answer is `for i in 0..<8`, which is proven at the type level.

**What --forbid-trap does NOT guarantee**: pointer indexing (`p[i]` where
`p: *T`) has no bounds checks at all and is therefore invisible to this
mechanism -- raw pointers are takibi's unsafe escape hatch (all the network
code indexes packet buffers through pointers). A future slice type
(pointer + type-level length) is the long-term answer; until then
--forbid-trap means "no runtime trap instructions", not "memory-safe".

**Checked refined cast** (`expr as {lo..<hi}`): previously this cast was
silently UNCHECKED -- type_inf returned the target type for any non-pointer
source, and codegen emitted no check, so `arr[v as {0..<8}]` with `v: i32`
elided the bounds check and produced an unchecked OOB access (a genuine
soundness hole, found while building this feature). Now it mirrors
`int as ExhaustiveEnum`: if the source's static range proves the target
range (`{2..<5} as {0..<8}`, literals, bool/u8/u16 fitting entirely), it is
a free subtype coercion; otherwise a range check + llvm.trap is emitted (and
recorded, so --forbid-trap rejects it). This cast is the explicit bridge
from unproven integers into refined types -- the gradual-verification story
in one construct: permissive mode traps at runtime, ship mode demands the
source range be provable.

**Narrowing invalidation (kill) rule** (`Ast.written_names`, shared by
`type_inf.ml:narrow_from_cond` and `llvm_gen.ml:apply_narrowing/_mut` --
sync rule: both sides MUST use this same function, like the Mod lo >= 0
guard): if-condition narrowing (`if (v >= 0 && v < 8) { ... }`) must not
apply to a variable the branch body can (a) assign, (b) alias via `&v`, or
(c) rebind (let redeclaration or for-counter). All three were soundness
holes before this rule existed: `if (v >= 0 && v < 8) { v = 100; buf[v] }`
compiled with the check fully elided (silent OOB, no trap at all), same for
a write through `&v`, same for `for v in 0..<100` shadowing the narrowed
name. The pre-scan is deliberately flow-insensitive within the branch (a
write anywhere kills narrowing for the whole body, even before the write)
-- simple to reason about, and refining it to a statement-ordered kill is
future work that must keep both consumers in lockstep. `io` variables were
already excluded (apply_narrowing_mut only matches `Mut (TypeI32, _)`);
globals were already excluded (narrowing tables only hold function locals);
function calls cannot touch locals whose address was never taken, and
address-taking is exactly case (b).

**For-loop bounds from named constants** (`Const_env.bound_value`, shared
by both sides -- same sync rule): `for i in 0..<QUEUE_SIZE` now refines `i`
to `{0..<QUEUE_SIZE's value}` when the bound names a Const_env constant
(immutable global with literal initializer), not just when it is a literal.
This is what made examples/const_global --forbid-trap clean. Soundness
precondition: the name must actually denote the global constant, so
**shadowing a Const_env constant name with a local let / parameter /
for-counter is now a compile error** (`type_inf.ml:check_const_shadowing`,
run per function AFTER parsing so declaration order cannot smuggle a shadow
in). Const_env resolves by name with zero scope information; allowing a
local `QUEUE_SIZE` would refine against the global's value while the loop
runs to the local's. Rejecting the shadow keeps by-name resolution sound by
construction (and it also retroactively hardens the existing array-size
feature, which had the same latent ambiguity).

**Exhaustive-enum cast from a refined source** (`llvm_gen.ml` Cast case):
`i as Color` where `i: {0..<3}` and Color = {0,1,2} now emits no switch/no
trap -- the range proves every possible value is a variant. A range with
any non-variant value (e.g. `{0..<3}` into a {1,2}-valued enum) keeps the
runtime check. This removed examples/enum's for-loop cast site.

**Files**: `lib/llvm_gen.ml` (trap_sites/record_trap/ty_str, emit_trap_when
/ emit_bounds_check loc+type params / emit_refined_cast_check, Cast
TypeRefined + enum-proof branches, For bound_value, narrowing kill),
`lib/type_inf.ml` (narrow_from_cond kill, For bound_value,
check_const_shadowing), `lib/ast.ml` (written_names), `lib/const_env.ml`
(bound_value), `bin/main.ml` (flag + report), `test/test_takibi.ml`
(expect_trap_sites helper + 12 cases), `examples/forbid_trap_wrong/` +
`examples/forbid_trap_ok/` (compile-only tests registered in
run_qemutest.sh; run_compile_error_test now accepts trailing extra takibi
flags, and run_forbid_trap_ok_test is the success-side counterpart).

**`unsafe { expr }`** (expression form; `lib/ast.ml` Unsafe, gated in
`lib/type_inf.ml` via a module-level `unsafe_depth` counter, transparent in
codegen): permits unchecked-assertion constructs inside -- currently
exactly one, slice construction from a raw pointer (`unsafe { p[0..<n] }`,
the driver-boundary op whose false length claim would poison every
downstream proof; that categorical difference from an ordinary local
pointer bug is why unsafe starts HERE and not at general pointer
arithmetic). Key distinction, deliberately preserved: **unsafe produces no
traps** -- a trap is a CHECK the compiler still doubts; unsafe is a
checkless ASSERTION the compiler is told to trust. --forbid-trap polices
the first axis; auditing the second is a future `--list-unsafe`-style
concern (how many human oaths underlie the shipped binary's proofs).
Deliberately NOT yet unsafe-gated: int->ptr / ptr->ptr casts and the
integer-literal->pointer Let coercion (Tier 2 -- ~16 `as *io` sites plus
ring-manipulation reinterprets, concentrated in the HALs; needs a decision
on the no-`as` literal coercion form first), and general pointer
deref/index/arith (Tier 3 -- ~113 pointer bindings in the HALs; marking
everything would drown the signal. Revisit as an `unsafe fn`-style marker
once slices have pushed pointers out of application code).

**Deliberately deferred** (recorded so the next step starts from data, not
guesswork): flow-sensitive assignment kill (narrow until the first write
instead of killing the whole branch), while-condition narrowing
(`while (i < 8)`), symbolic/relational bounds (`{0..<n}` where n is a
runtime value, `i < len` facts) -- the last one is the honest decision
point for a VC+SMT (Z3) backend; everything above stays in the
non-relational interval world where plain OCaml implementation is the
right tool. The empirical result from the P4 census is that most examples
did not need relational reasoning, which is the argument for not
introducing a solver yet.

### Slice Type (P1): []T / [T; N..] -- fat pointer with a compile-time minimum length

Designed from a full census of examples/http_server's raw-pointer usage (see
git history around 2026-07): ~77 of its pointer operations are constant
offsets/lengths inside views whose size was guarded by a constant comparison
-- i.e. provable with interval reasoning only -- so the slice type carries a
compile-time MINIMUM length and nothing more. `[]u8` = minimum 0 (length
unknown), `[u8; 54..]` = at least 54 bytes. No relational (`i < len`-style)
reasoning was added; the census showed exactly one app-layer site that needs
it (tcp_hdr_len options skip), deferred to a later phase.

**Representation / ABI**: an LLVM first-class struct value `{ptr, usize}`
(`ltype_of_ast TypeSlice`), so `gen_expr` returns it as one llvalue and
LLVM's own ABI lowering passes it in register pairs on both targets. The
len half follows the target pointer width: `{ptr, i64}` on AArch64,
`{ptr, i32}` on Cortex-M7. Slices never cross `extern fn` boundaries.

**`.len` is usize, not i32** (deliberate): composes cast-free with
`sizeof(T)` (`if (s.len >= sizeof(Hdr))`), encodes non-negativity in the
type instead of as an out-of-band invariant, and forces an explicit
`(wire_value as usize)` exactly at the untrusted-input trust boundary,
consistent with the pointer-cast philosophy.

**Creation forms**:
- `arr as []u8` -- array variable to slice; the array's static size becomes
  the minimum ([u8; 16] -> [u8; 16..]). Note infer_expr's Var case decays
  arrays to *T, so BOTH type_inf's and llvm_gen's Cast cases recover the
  length from the declared binding, not from the decayed source type.
- `s[a..<b]` on a slice/array -- constant-bound subslice, proven against
  the base's minimum at compile time (a runtime-bound subslice is a
  compile error for now -- P3), yields `[T; (b-a)..]`.
- `unsafe { p[a..<b] }` on a raw pointer -- UNCHECKED slice construction
  (the driver-boundary escape hatch; as unsafe as the pointer arithmetic it
  replaces, but done once, after which accesses are bounds-governed). The
  `unsafe { ... }` marker is REQUIRED (compile error without it -- see the
  unsafe paragraph in the --forbid-trap section): this is a length
  assertion with no evidence, and it must be visible when writing and when
  reading. Constant bounds still yield a minimum. Rejected on `*io T`
  (slice loads/stores are non-volatile and would silently drop io
  semantics).

**Indexing / proof rule**: `s[i]` is proven (no check, no trap site) iff
i's range `{lo..<hi}` satisfies `lo >= 0 && hi <= minimum`; the minimum is
a lower bound of the runtime length, so this is sound. Anything unproven
gets a runtime check against the RUNTIME length (`emit_bounds_check_dyn`:
the index is already target-width `usize`, so one unsigned compare catches
values at or beyond the length -- llvm.trap, recorded as a
--forbid-trap site).

**Length narrowing**: `if (s.len >= K)` upgrades the binding's minimum to K
inside the branch. Single shared recognizer `Ast.slice_len_mins` consumed
by type_inf's narrow_from_cond AND llvm_gen's apply_narrowing/_mut (sync
rule), subject to the same written_names kill rule as integer narrowing
(assign/alias/rebind of the slice kills it). Mut bindings go through
narrowing_ctx (consulted via effective_slice_min at Index/AssignIndex/
SliceOf sites); Imm bindings are replaced in the locals table directly.

**Subtyping**: `unify (TSlice m_actual) (TSlice m_expected)` succeeds iff
m_actual >= m_expected (mirrors TRefinedInt's one-directional rule; unify's
call sites all pass (actual, expected)). **Annotations do NOT weaken
immutable bindings**: `let m: []u8 = s[2..<6];` keeps the initializer's
proven `[u8; 4..]` (and `let x: i32 = v` keeps v's `{lo..<hi}`) -- see the
"proofs are only lost at mutation points" invariant in the --forbid-trap
section for why (an earlier version let the annotation win, which
manufactured ship-time --forbid-trap rejections out of already-proven
code). `let mut` keeps the declared type; its checks mark real proof gaps.
Documented in examples/slice/slice.tkb's header.

**Codegen re-verifies what type_inf proved** (constant subslice range vs.
its own effective minimum) and raises a "BUG:" Error on disagreement,
rather than trusting silently -- keeps the two-sided sync-rule discipline
auditable.

**Files**: `lib/ast.ml` (TypeSlice, SliceOf, slice_len_mins, written_names
case), `lib/lexer.mll` (DOTDOT -- ".." lexes after "..<" by longest-match),
`lib/parser.mly` ([]T, [T; N..] via array_size, IDENT[e..<e]),
`lib/types.ml` (TSlice + subtyping unify), `lib/type_inf.ml` (.len, Index,
SliceOf, AssignIndex, Cast, narrow_from_cond), `lib/llvm_gen.ml` (ltype,
ditype-as-pointer, slice_ptr/slice_len/make_slice/effective_slice_min,
emit_bounds_check_dyn, Index/AssignIndex/SliceOf/Cast/FieldGet cases,
narrowing), `examples/slice/` (demo, both targets, --forbid-trap clean:
forbid_trap_slice in run_qemutest.sh), 11 unit-test cases.

P2 (for-in + builtins), P3 (checked/refined subslices + the http_server
migration), and P4a (interval extensions + same-base rule -- see its
section below) are delivered. **P4a proved the "no solver needed"
hypothesis**: the TCP-options skip and the runtime-length segment view --
the two sites P3 classified as relational -- are both PROVABLE now (the
ftp4_probe unit test reproduces http_server's full guard chain with zero
trap sites). What remains (P4b, source migrations + one genuine leftover):
- rewriting http_server's checksum spans and options skip onto the
  now-provable slice forms (needs inet_checksum's slice signatures first,
  which drags all its callers -- one migration wave with the `*_p`
  removal below);
- response building (copy_str / write_udec appends at runtime offsets) --
  bounded today only by a documented static margin; needs bounded-append
  forms (e.g. range-carrying slice_copy returns), the one item where new
  design is still open;
- migrating arp_reply / icmp_echo / tcp_parse / tcp_echo off the
  TRANSITIONAL `*_p` netutil wrappers (mechanical, http_server is the
  template).

### for-in Element Iteration and Slice Builtins (P2)

The P2 goal: variable-length buffer code (the netutil.tkb /
inet_checksum.tkb shape) must be writable with zero trap sites and zero
relational reasoning. Three pieces, all demonstrated end-to-end in
examples/foreach (which runs under QEMU on both targets and is
--forbid-trap clean -- forbid_trap_foreach in run_qemutest.sh):

**`for x in s { ... }`** (`Ast.ForEach`): element iteration over a slice.
The compiler generates the counter (`__foreach_<name>`, usize-width, pre
-allocated by collect_lets like For's `__for_`), the length compare, and
the in-bounds element load -- safe by construction, no index exists so no
index proof exists. The slice expression is evaluated ONCE at loop entry
(snapshot semantics, like For's bounds); x is an immutable per-iteration
value (widened per the widen_load invariant). Block layout mirrors For
exactly, including `continue` -> incr_bb. Iterating a non-slice is a
compile error suggesting `arr as []T`. ForEach is covered by
written_names (rebinding kills outer narrowing) and
check_const_shadowing -- both have explicit ForEach cases; note
check_const_shadowing and collect_lets have `_ -> ()` fallbacks, so a
future statement form must be added there BY HAND (the OCaml
exhaustiveness check will not flag those two).

**`slice_copy(dst, src) -> usize` / `slice_eq(a, b) -> bool`** (compiler
builtins, dispatched in type_inf's and llvm_gen's Call cases BEFORE the
fenv/functions lookup; the names are reserved -- defining fn/extern fn
with them is a compile error via check_reserved_fn, since a user
definition would be silently unreachable). Both are TOTAL functions:
- slice_copy copies min(dst.len, src.len) elements FORWARD and returns the
  count; a length mismatch shows in the return value, never as a trap.
  The forward loop keeps the overlap guarantee bytes_copy's callers
  already rely on (dst not leading src -- tcp_echo's payload shift).
- slice_eq is false on length mismatch, true iff all elements match.
Codegen builds phi-based loops, NOT allocas (an alloca at the call site
would sit inside any enclosing loop and grow the stack per iteration),
and NOT llvm.memcpy (with a dynamic length the intrinsic lowers to a
memcpy libcall = bare-metal link error, the same reason run_optimizations
excludes the loop-idiom pass).

**The checksum pattern**: examples/foreach's checksum_slice writes RFC
1071 without indexed access -- a hi/lo alternation flag replaces
inet_checksum.tkb's stride-2 loop (`data[i]`, `data[i+1]`, guarded by
`i + 1 < len`), which is exactly the loop shape that would otherwise
demand relational reasoning. Same algorithm, verified against the same
kind of vector at runtime under QEMU.

Files: `lib/ast.ml` (ForEach + written_names case), `lib/parser.mly`
(second FOR production -- LBRACE vs DOTDOTLT after the expression
disambiguates, no grammar conflict), `lib/type_inf.ml` (ForEach inference,
check_const_shadowing case, two builtin Call cases, check_reserved_fn),
`lib/llvm_gen.ml` (collect_lets case, gen_stmt ForEach, two builtin Call
intercepts), `examples/foreach/`, 7 unit-test cases.

### Checked/Refined Subslices and the http_server Migration (P3)

**Refined-bound subslice proof**: subslice bounds are judged by their
STATIC VALUE RANGES (a constant k is {k..<k+1}; a refined-typed expression
contributes its {lo..<hi}), shared formula in type_inf's SliceOf
`bound_range` and llvm_gen's SliceOf `gen_bound` (sync rule; llvm_gen also
consults narrowing_ctx for Mut bound variables, like Index does). Proven
iff `min(lo) >= 0 && max(lo) <= min(hi) && max(hi) <= base minimum`; the
result minimum is the guaranteed length `min(hi) - max(lo)`. This is what
makes the driver-boundary pattern interval-only: after
`if (len >= 54 && len <= 1514)`, `frame[0..<len]` on a [u8; 1514..] frame
is proven with NO runtime check and yields [u8; 54..].

**Runtime-checked subslice (gradual form)**: an unprovable subslice on a
slice base emits `0 <= lo && lo <= hi && hi <= s.len -> llvm.trap`, one
recorded --forbid-trap site; the result keeps whatever minimum the static
ranges still guarantee. SEMANTICS CHANGE from P1: a constant subslice
beyond the base's minimum (s[2..<10] on [u8; 8..]) is now a checked
subslice, NOT a compile error -- the runtime length may exceed the
minimum. Only definitely-malformed bounds (lo < 0, lo > hi) and
array-base violations (arrays have EXACT lengths) remain compile errors.

**Smaller pieces**: `"literal" as []u8` (compile-time byte length, NUL
excluded, becomes the minimum -- `slice_copy(dst, "..." as []u8)` is the
bounded replacement for copy_str's unbounded scan, not yet used by
http_server's response island); `s as *T` (explicit bridge back to the
pointer world, just the ptr half -- casting a slice to anything else is
still an error); Const_env constant names as PROVEN INDICES
(`tcp[TCP_FLAGS]` -- Index/AssignIndex idx_ty now checks
Const_env.bound_value first, sound because check_const_shadowing forbids
shadowing).

**Driver boundary**: both backends gained
`net_rx_frame() -> [u8; 1514..]` (the return ANNOTATION matters: an
earlier `-> []u8` silently erased the minimum and broke every downstream
proof -- annotation weakening still applies at function boundaries, only
immutable `let` bindings are exempt). The single `unsafe { p[0..<1514] }`
lives inside the driver, next to the buffer-size evidence that justifies
it; application code contains no unsafe at all.

**http_server migration** (the payoff; wire behavior verified byte-exact
by the existing protocol tests + real handshake/GET/counter flow): all
header parsing and rewriting now goes through constant-offset views
(`frame[14..<34]` ip, `frame[34..<54]` tcp) and the slice-based
read/write_u16/32be; adjacent offset constants double as field subslices
(`arp[ARP_SHA..<ARP_SPA]`). The DEVICE-REPORTED length is clamped once
(`len <= 1514` in the IPv4 branch) before total_len may trust it --
killing the latent OOB found in the P3 census. http_server remains
--forbid-trap clean (locked in by forbid_trap_http_server in
run_qemutest.sh). Its remaining pointer islands are enumerated in the
file header and in the P4 list above.

**netutil.tkb**: read/write_u16be/u32be now take [u8; 2..] / [u8; 4..]
(bodies are fully proven, zero checks); `*_p` TRANSITIONAL pointer
wrappers (each containing the one unsafe assertion its pointer caller was
implicitly making) keep arp_reply / icmp_echo / tcp_parse / tcp_echo
compiling until they migrate -- do not use `*_p` in new code.
bytes_copy/bytes_eq/copy_str/write_udec keep pointer signatures for the
un-migrated callers and http_server's response island.

Files: `lib/type_inf.ml` + `lib/llvm_gen.ml` (SliceOf rework, Cast
additions, Index const-name rule), `examples/common/netutil.tkb`,
`examples/common_qemu/virtio_mmio.tkb`, `examples/common_stm32/eth.tkb`,
`examples/http_server/http_server.tkb`, `_p` renames in the four
un-migrated examples, 5 unit-test cases + 2 updated to the new checked
semantics.

### Interval Extensions and the Same-Base Subslice Rule (P4a)

Four small, individually-sound extensions that together discharge both
sites P3 had classified as "genuinely relational" -- still with no
relational abstract domain and no solver. The ftp4_probe unit test
reproduces http_server's complete guard chain (device-length clamp, ihl
equality, total_len-vs-frame-room, runtime-length segment view, options
skip) and proves it end to end with zero trap sites.

1. **Interval arithmetic propagation** (type_inf's and llvm_gen's BinOp
   typing, sync rule -- change together):
   `{a..<b}+{c..<d} -> {a+c..<b+d-1}`, `{a..<b}-{c..<d} -> {a-d+1..<b-c}`,
   `{a..<b}*k -> {a*k..<(b-1)*k+1}` for a positive literal k (what carries
   doff's {5..<16} into tcp_hdr_len's {20..<61}).
2. **Equality narrowing**: `if (ihl == 20)` narrows to {20..<21} (Eq joins
   Ge/Gt/Le/Lt in both bound collectors).
3. **Comparison against a range-known operand**: the bound collectors were
   rewritten around a range_of helper -- a literal / Const_env constant is
   {k..<k+1} (subsuming the old 8 patterns) and a VARIABLE with a refined
   binding contributes its own range, so `total_len <= ip_len_in_frame`
   narrows total_len's upper bound to ip_len_in_frame's static maximum.
   The fact collapses to a constant AT COLLECTION TIME, which is why this
   is still interval reasoning and needs no new kill obligations (the
   constant was true when the condition executed; the narrowed variable's
   own kill is governed by written_names as before). type_inf's
   collect_bounds now takes tyenv; llvm_gen's collect_bounds_cond takes
   locals (+ narrowing_ctx, which moved above it in the file).
4. **Same-base subslice rule** (`Ast.var_plus_const`, single shared
   decomposition -- sync rule): `s[v + j ..< v + k]` (same variable,
   constant offsets) has length exactly k - j, and lo <= hi holds iff
   j <= k regardless of v's value -- the correlation plain intervals treat
   as two independent occurrences. This is the depth-1 "difference
   constraint" (ABCD's minimal subset) obtained syntactically. io-qualified
   bases are excluded in both checkers: the two bound loads would be
   volatile and could disagree. With v's range known the subslice is fully
   proven; without it, the runtime check remains but the EXACT length k - j
   still survives into the result minimum (so `frame[off..<off+3]` with an
   unbounded off is 1 site, and d[2] inside is still proven).

**Known conservative gap (safe direction, documented in
collect_bounds_cond's comment)**: codegen does not consult narrowing_ctx
for variables reached through arithmetic inside bound expressions, and
does not see refined globals -- where type_inf proves but codegen cannot,
the check stays and --forbid-trap reports it; binding the value to an
immutable local (the natural style anyway) resolves it. All the guard
values in the probe/http_server chain are immutable lets, so this gap
never fires there.

Files: `lib/type_inf.ml` (BinOp Add/Sub/Mul, collect_bounds rewrite,
SliceOf same-base), `lib/llvm_gen.ml` (BinOp mirror, collect_bounds_cond
rewrite, SliceOf same-base), `lib/ast.ml` (var_plus_const), 6 unit-test
cases including the probe.

### P4b: The Migration Wave (netutil/inet_checksum -> slices, all five
### protocol examples off pointer+length pairs)

P4a's probe proved the TECHNIQUE works; P4b applied it everywhere and, in
doing so, found and fixed one more real gap in the narrowing machinery
plus confirmed exactly where the honest relational boundary sits in
practice (one file, one path, precisely accounted for -- not "the census
was wrong").

**inet_checksum.tkb migrated to slices**: `checksum_add(data: []u8,
sum_in: i32)` and `inet_checksum(data: []u8)` -- no length parameter; the
slice's own `.len` (walked via `for b in data`, examples/foreach's hi/lo
alternation technique) replaces the old stride-2 index loop entirely.
`checksum_fold` is unchanged (pure integer folding, never touched a
buffer).

**The critical redesign that made checksum spans provable across a
function call: pass an ALREADY-SLICED SEGMENT, never an integer length.**
`fix_tcp_checksum(ip: [u8; 20..], tcp_seg: [u8; 20..])` takes the full
segment directly and reads `tcp_seg.len` back for the pseudo-header's
length field (so it can never disagree with what it's actually
checksumming). This sidesteps a hard limit: **TRefinedInt-to-TRefinedInt
function arguments require an EXACT range match, not subtyping**
(`unify`'s TRefinedInt/TRefinedInt case raises unless `lo1=lo2 && hi1=hi2`
-- there is no general "narrower fits into wider" rule the way slice
minimum-length subtyping has). Passing an integer LENGTH into a function
and trying to prove a subslice INSIDE that function against a plain `i32`
parameter therefore never works (the parameter carries no range at all).
Passing an already-constructed SLICE VALUE instead works, because slice
parameters use genuine covariant subtyping (`m_actual >= m_expected`) --
so the proof happens once, at the call site (where the length variable's
real refined range is still in scope), and the callee just consumes the
slice's own runtime `.len`.

**Where exact-match refined parameters DO work**: `ihl: {20..<21}` is used
as a parameter type in every migrated file's header-touching functions.
This is legitimate specifically because each file's scope is "IHL always
exactly 20, no IP options" -- an existing runtime precondition, previously
enforced only by an `if`, now stated in the type signature -- and the ONE
caller narrows via `ihl == 20` (Eq narrowing), producing the EXACT SAME
`{20..<21}` the callee declares. This only works because caller and
callee agree on the identical literal range; it would NOT generalize to
"pass any 16..<24 IHL", which is the real content of the TRefinedInt
exact-match limitation above.

**Second real bug found and fixed: if-narrowing silently no-oped on an
ALREADY-refined variable.** Both `narrow_from_cond` (type_inf.ml) and
`apply_narrowing`/`apply_narrowing_mut` (llvm_gen.ml) originally matched
only `Some (TI32, is_mut)` / `Some (Mut (TypeI32, _))` -- if the variable
arriving at the `if` was ALREADY `TRefinedInt` (extremely common once
P4a's interval propagation and the B-plan "proofs survive weaker
annotations" rule are both in play -- e.g. `icmp_len: i32 = total_len -
ihl` picks up a refined range straight from its Sub-propagated
initializer), the narrowing branch didn't match, fell through to `_ ->
env`/`_ -> saved`, and the condition's tighter bounds were silently
DISCARDED -- the variable kept its wider pre-existing range instead of
the INTERSECTION. Found migrating icmp_echo (`if (icmp_len >= 8 &&
icmp_len <= 1480)` failed to narrow icmp_len past its Sub-derived
`{0..<1481}`, so the resulting subslice's minimum stayed 0, failing to
satisfy a callee's `[u8; 8..]` parameter). Fixed by adding an
`TRefinedInt (elo, ehi) -> intersect` case to all three call sites (a
Mut variable can also arrive already-narrowed from an OUTER if via
narrowing_ctx -- llvm_gen's fix intersects with any existing narrowing_ctx
entry too, not just the locals table's declared type). Two regression
tests added (`ftp4b_intersect`, `ftp4b_nested_mut`).

**Companion technique for a MUTABLE accumulator (http_server's response
length, tcp_echo's data_len parameter): snapshot into an immutable
local.** `apply_narrowing`/`_mut`'s narrowing_ctx overlay is only consulted
when the narrowed variable is used DIRECTLY as an index/subslice bound
(`Var n` pattern match in `gen_bound`/Index's idx_ty lookup) -- burying it
inside an arithmetic expression like `54 + len` bypasses narrowing_ctx
entirely (gen_expr's ordinary `Var` case for a Mut binding just returns
the DECLARED type, ignoring narrowing_ctx). The fix used throughout: after
the bounding `if`, `let n: i32 = len;` -- an immutable let's initializer
type comes from `tyenv` directly (which DOES reflect the narrowing) and
the B-plan keeps it via the refined-initializer-survives-weaker-annotation
rule, so plain arithmetic on `n` is fully visible to codegen with no gap.
Documented as a **known conservative gap** (safe direction: codegen may
keep a check type_inf proved away) rather than fixed at the root, since
"make narrowing_ctx aware of arbitrary bound sub-expressions" is
materially more machinery for a problem this local snapshot solves in one
extra line, at the one place it's needed. Both http_server's
`HTTP_MAX_PAYLOAD` check and tcp_echo's `TCP_MAX_PAYLOAD` check are this
pattern AND close a real latent gap simultaneously (the payload/segment
length was previously trusted downstream with no capacity check at all).

**http_server.tkb**: fully migrated, remains --forbid-trap clean
(`forbid_trap_http_server`). The options-skip and the request-checksum
span are now both PROVEN (not just "gradual", per P4a's confirmation);
the two-line `n` snapshot proves the REPLY's checksum span too. Response
BODY CONSTRUCTION (copy_str/write_udec into a raw pointer) remains the one
deliberately-deferred pointer island -- see its own header comment for
exactly why (needs bounded-append primitives, not subslice/interval
machinery) and the enforced `HTTP_MAX_PAYLOAD` margin that bounds it today.

**arp_reply.tkb, icmp_echo.tkb**: fully migrated and fully proven (both
now registered as `forbid_trap_arp_reply` / `forbid_trap_icmp_echo`).
icmp_echo needed the same `len <= 1514` upper clamp http_server already
had (without it, `ip_len_in_frame` stays unrefined and the
narrowing-against-a-range-known-variable extension never fires) plus the
intersect fix above.

**tcp_parse.tkb, ip_parse.tkb**: migrated to slices but DELIBERATELY left
with one genuine runtime-checked (gradual) subslice each -- these
parse-only demos never validate a wire-derived length (`ihl` / `tcp_len`)
against the packet's actual capacity (that's the whole point of their
"corrupted packet" demonstrations), so the checksum span is honestly
unprovable, and the check is a REAL SAFETY IMPROVEMENT over the original
raw-pointer code (which read out of bounds on a corrupted length with no
check at all). Both were removed from run_qemutest.sh's no-trap example
list (which predates this migration and only passed before because
pointer indexing has no checks to begin with, not because these files
were ever proof-complete).

**tcp_echo.tkb**: fully migrated but keeps 2 recorded trap sites in
`build_data_echo`'s data-echo path -- the one place across this entire
migration wave that is genuinely, unavoidably relational with the current
toolkit. `data_off` (where payload starts, past any TCP options) and
`data_len` (how much payload there is) are independently-derived
quantities; proving `data_off + data_len <= frame's capacity` needs a
two-variable fact plain interval arithmetic cannot carry, and the
same-base rule doesn't apply either (it only handles a variable plus a
COMPILE-TIME CONSTANT offset -- `data_len` is a runtime variable, not a
constant). Confirmed concretely by trying to compute `data_len`'s own
Sub-propagated range here: with `tcp_len`/`tcp_hdr_len` both refined, the
formula gives `{-40..<1461}` -- a NEGATIVE lower bound, even though the
existing runtime guard (`tcp_len >= tcp_hdr_len`) makes that impossible at
runtime. Intervals only see each variable's OWN range, not the RELATION
between two of them, so this pessimism is fundamentally the domain's
limit, not a missing extension. Removed from the no-trap example list for
the same honest reason. This is the ONE (out of five protocol examples,
one algorithm library, and one server) file/path in the whole P4 wave that
would need a genuine relational domain or VC+SMT to close -- a strong
empirical data point for "not yet, and maybe not ever, for this
codebase's actual shape."

Files: `examples/common/inet_checksum.tkb`, `examples/common/netutil.tkb`
(`_p` transitional wrappers deleted -- every caller migrated),
`examples/http_server/http_server.tkb`, `examples/arp_reply/arp_reply.tkb`,
`examples/icmp_echo/icmp_echo.tkb`, `examples/ip_parse/ip_parse.tkb`,
`examples/tcp_parse/tcp_parse.tkb`, `examples/tcp_echo/tcp_echo.tkb`,
`examples/inet_checksum/inet_checksum.tkb`, `lib/type_inf.ml` +
`lib/llvm_gen.ml` (the intersect-narrowing fix), `scripts/run_qemutest.sh`
(no-trap list correction + 2 new forbid_trap_* registrations), 2 new
unit-test cases.

### P4c: Closing the P4 Census -- Band Masking, min/max, Same-Base
### Generalization, and unsafe Extended to Slice Bases

Goal stated at the top of P4: every idiom found in http_server (and, by
extension, the other protocol examples) should land in exactly one of two
buckets -- (1) compiles fine without `--forbid-trap` and traps on
violation, unchanged from today, or (2) compiles clean WITH
`--forbid-trap`, either because it's genuinely proven or because an
`unsafe { ... }` marks an explicit, evidence-backed assertion. No third
"silently checked, --forbid-trap just rejects it forever" bucket should
exist without a documented reason. **Result: the current example suite is
--forbid-trap clean**.

**enum.tkb: Color made non-exhaustive.** The residual cast-check trap
(`raw as Color`, `raw: u8` with no static evidence bounding it to
{0,1,2}) was correct, not a bug -- but it also wasn't the RIGHT fix to
just accept forever. The user's insight: this demo's own cast site has no
evidence at all, so the type-level choice matching REALITY is "any byte
value is a legal Color" (open-ended), which is exactly what `_;`
(non-exhaustive) already means. Color gained `_;`; `color_name`'s match
gained a required `_` arm (compiler-enforced for non-exhaustive enums).
**Important distinction surfaced while investigating this**: a `match`
with no `_` on an EXHAUSTIVE enum compiles its uncovered case to LLVM
`unreachable`, not `llvm.trap` -- so the cast's check is not a redundant
courtesy alongside match exhaustiveness, it's the ONLY thing standing
between an invalid value and genuine undefined behavior (the optimizer is
free to assume `unreachable` never executes). This is why `unsafe { raw
as Color }` (skipping an exhaustive-enum cast's check) is a materially
more dangerous escape hatch than the slice/pointer cases below, and was
deliberately NOT added -- non-exhaustive enum is the existing, already-
sound tool for "I don't have evidence, and I'm ok with any value."

**Band (`&`) mask range propagation** (`lib/type_inf.ml` + `lib/llvm_gen.ml`
BinOp Band case, sync rule): `x & k` for a non-negative literal mask k ->
`{0..<k+1}`, regardless of x's own sign or range (bitwise AND with a
non-negative value can only clear bits, so the result is always in
[0, k] in two's complement, for ANY x). Symmetric (k may be either
operand). This is what gives `(byte & 0x0f) * 4` (the ubiquitous IHL
field extraction) a real range with NO prior narrowing at all -- `& 0x0f`
alone gives {0..<16}, and P4a's existing Mul rule carries that to
{0..<61}.

**`min(a,b)` / `max(a,b)` builtins** (compiler builtins, reserved names,
dispatched like slice_copy/slice_eq): the tool for clamping a wire-derived
value against a compile-time buffer capacity -- `min(ihl, 20)` is
provably <= 20 no matter what ihl turns out to be at runtime. The
asymmetry in what each bound needs is the actual content of the rule, not
an implementation shortcut:
- `min(a,b) <= a` and `<= b` ALWAYS (definition of min), so if EITHER
  operand's upper bound is known, that alone bounds the result's upper
  side -- the other operand may be completely unconstrained.
- A LOWER bound for min needs BOTH operands' lower bounds known (an
  unconstrained operand could always be the one that's smaller, dragging
  the result down with it).
- max is the mirror image: `max(tcp_len, 0)` proves >= 0 even though
  tcp_len itself is a bare, unconstrained i32 parameter (lower bound needs
  only one operand known); an upper bound needs both.
"Unknown" is represented with a wide sentinel range (+-1 billion) rather
than a genuine option type, so the result is always a plain TRefinedInt --
a subslice/index proof against any REAL buffer capacity correctly fails to
close against a sentinel (never falsely succeeds), so this is a
representational convenience, not a soundness-relevant choice.

**Two latent gaps found and fixed while building this** (both were
pre-existing, surfaced by exercising min/max against real code, not
introduced by it):
1. `TRefinedInt` had no subtyping rule into `TUsize` at all (only into
   TU64/TU32/etc.) -- `let b: usize = a & 63;` (a: usize) failed to
   unify once Band started returning a refined type. Fixed by adding
   `TRefinedInt (lo, _), TUsize when lo >= 0 -> ()` alongside the
   existing TU64 rule in `lib/types.ml`.
2. Sub only propagated ranges when checking its FIRST operand
   (`TRefinedInt (a,b), _ -> ...`) for refinement -- `40 - ihl` (literal
   MINUS a refined variable) fell through to plain i32, asymmetric with
   Add (which already handles both directions). Added the mirror case:
   `k - {c..<d} -> {k-d+1..<k-c+1}` for a literal k, matching Add's
   existing both-directions handling (sync rule, both files).

**Same-base rule generalized from constant offsets to any non-negative
lower-bounded expression** (`lib/type_inf.ml` + `lib/llvm_gen.ml` SliceOf,
sync rule): P4a's same-base rule only recognized `s[v ..< v + k]` for a
literal k. Needed generalizing the moment a REAL min/max-clamped variable
appeared as the offset (`ip[ihl ..< ihl + tcp_len]`): plain interval
bound_range on `ihl` and `ihl + tcp_len` independently treats the two
occurrences of `ihl` as unrelated, so `ihl`'s own worst case (its upper
bound) can look like it exceeds `ihl + tcp_len`'s best case (its lower
bound) even though they're the same variable and can't actually diverge
like that. The rule now accepts `s[v ..< v + w]` for ANY w (not just a
literal) whose own range has a known non-negative lower bound -- a
literal's lower bound IS the literal itself, so this subsumes the old
rule exactly, no regression. **Deliberate implementation restriction**:
w must be a bare literal or a bare variable, not an arbitrary expression --
llvm_gen's mirror of this check must look up w's range via a direct table
lookup (locals/globals/narrowing_ctx), NOT by calling gen_expr/gen_bound
on it again, because w has already been evaluated once as part of hi_e
itself; re-evaluating an arbitrary expression a second time would risk
duplicating side effects (a general function call, not just a harmless
redundant load). Both sides of the sync rule enforce the same
restriction.

**Honest negative result: CHAINED/correlated clamps do not close.**
Tried extending the above to prove tcp_parse's `ip[ihl ..< ihl + tcp_len]`
fully, using `ihl = min(raw_ihl & 0x3f, 20)` and
`tcp_len = min(tcp_len_raw, 40 - ihl)` (room derived from the ALREADY-
clamped ihl). This does NOT reach zero trap sites: `tcp_len`'s own
{0..<~41} range (from the min/max combination) is correct in isolation,
but combining it with `ihl` via ordinary interval Add loses the fact that
`tcp_len <= 40 - ihl` was how it was DERIVED -- the combined upper bound
computed independently (`ihl`'s own worst case + `tcp_len`'s own worst
case) overshoots the true capacity (40), because that specific worst-case
COMBINATION can't actually co-occur (it would require `tcp_len` to be
large exactly when `ihl` is ALSO large, but `tcp_len`'s clamp was built
FROM `ihl`, so they move together, not independently). This is a genuine,
different-in-KIND limitation from anything else P4c-2 closes: it's the
same class of "two variables secretly correlated via subtraction" problem
as tcp_echo's `data_off`/`data_len`, just one level more indirect (through
an intermediate `room` variable). Confirmed empirically (not just argued)
via a regression test (`ftp4c_chained` in test_takibi.ml) that DOES record
exactly 1 trap site despite every individual clamp being provably correct
on its own. This is the precise, now twice-confirmed boundary of what
interval + same-base + min/max can do without a genuine relational
(difference-constraint) domain or VC+SMT.

**unsafe extended to slice/array-BASE subslice construction, not just
pointer-base** (`lib/llvm_gen.ml`; deliberately NO type_inf.ml change --
see below): previously `unsafe { ... }` only gated pointer -> slice
construction (a length assertion with zero evidence). Extended the SAME
gate to a slice/array-base subslice whose bounds fail the interval/same-
base proof: `unsafe { s[a..<b] }` now SKIPS the runtime check entirely
when `s` is already a slice, an explicit "trust me" with the identical
semantics as the pointer case, closing exactly the correlated-bounds
residue found above (tcp_echo's two sites) without needing a relational
domain at all. **Type_inf.ml needed zero changes**: unsafe doesn't grant
new STATIC information (the computed type/minimum is identical whether
checked or unsafe-skipped -- skipping the check just means "don't verify
what was already computed," not "know something new"), so the type
computation in SliceOf is completely unaffected by unsafe; only
llvm_gen's decision of whether to EMIT the check changes. Implementation:
a module-level `Llvm_gen.unsafe_depth` mirrors type_inf's counter (reset
per compilation like `trap_sites`), incremented/decremented in the
`Unsafe` codegen case (previously fully transparent); `sub_of_slice`
checks it before emitting the check/calling `record_trap`. Applied to
tcp_echo's two documented sites (`tcp_seg[20..<20+n]` and
`frame[data_off..<data_off+data_len]`), both now with comments explaining
the specific evidence backing the assertion (an adjacent runtime check,
or an algebraic identity that the type system can't see but a human can
verify). NOT applied to enum casts (see above) or to tcp_parse (see next).

**tcp_parse's checksum span: fixed by VALIDATING, not asserting away.**
Initially left CHECKED (not unsafe) and flagged back to the user as a
judgment call -- wrapping `ip[ihl..<ihl+tcp_len]` in unsafe would have
silently traded away real protection against a realistic corruption
class (a malformed `ip_total_len`) for --forbid-trap cleanliness this
file was never promised to have. **The user's response identified the
actually-correct fix**: a real binary parser cannot assume its input is
well-formed, so add the SAME validation icmp_echo/tcp_echo/http_server
already do (`if (ip_total_len >= ihl && ip_total_len <= 40)`), report a
malformed segment on failure, and only compute the checksum in the
validated branch. This is not a workaround -- it is the missing input
validation any parser needs regardless of the type system, and it
happens to ALSO make the checksum span fully provable: once
`ip_total_len` is narrowed to `{ihl..<41}`, `tcp_len = ip_total_len - ihl`
gets a real `{0..<21}` range via ordinary Sub propagation (both operands
now refined), and the same-base rule closes `ip[ihl..<ihl+tcp_len]`
outright -- no unsafe, no relational domain, zero trap sites. **All 44
examples are now --forbid-trap clean.** This is arguably the most
important finding of the whole P4 arc: the "one remaining case" wasn't a
type-system gap at all -- it was a missing `if` that any correct parser
needed anyway, and the type system was correctly refusing to let a
genuinely unvalidated wire value drive a buffer access. Worth remembering
before reaching for unsafe or a bigger abstract domain: check whether the
REAL fix is just the input validation the code was missing regardless.

**Practical implication for the enum finding**: the two enum-cast unsafe
questions (whether to extend unsafe to `raw as Color`-style checked casts
in general, and whether enum.tkb's own demo should use it) remain
deliberately unresolved -- flagged as dangerous (unreachable-based, not
trap-based) rather than implemented. Revisit only with a concrete need
distinct from "make this specific demo forbid-trap clean," which
non-exhaustive already solved more honestly.

Files: `examples/enum/enum.tkb` (non-exhaustive Color + match wildcard),
`lib/type_inf.ml` + `lib/llvm_gen.ml` (Band propagation, min/max builtins,
Sub literal-minus-refined case, same-base generalization, reserved names),
`lib/types.ml` (TRefinedInt->TUsize subtyping fix), `examples/ip_parse/
ip_parse.tkb` (min-clamp, now fully proven), `examples/tcp_parse/
tcp_parse.tkb` (ip_total_len validation, now fully proven),
`examples/tcp_echo/tcp_echo.tkb` (one unsafe-wrapped site remaining, down
from two -- see below), `scripts/run_qemutest.sh` (enum/ip_parse/
tcp_parse/tcp_echo all moved back into the no-trap list; 3 new
forbid_trap_* registrations), 7 new unit-test cases including the
honest-negative-result regression.

### P4c Follow-up: Three of Four unsafe Sites Removed, One Confirmed Necessary

After the above, the codebase still had 4 `unsafe` uses: two identical
`net_rx_frame()` implementations (virtio_mmio.tkb / eth.tkb) and
tcp_echo's two data-echo sites. Asked, for each one, "can an `if` remove
this the same way tcp_parse's fix did" -- the honest answer turned out to
be "yes" for three of the four, and each `unsafe` removal PROVED something
genuinely true and useful, not just "make the compiler happy":

**`net_rx_frame()` (both backends): the pointer assertion was itself
hiding an unvalidated device value.** `unsafe { p[0..<1514] }` asserted
"this pointer is good for 1514 bytes" with zero evidence -- but the REAL
issue one line up was that `net_last_rx_desc_idx` (virtio) /
`eth_rx_cur` (STM32), the index selecting WHICH ring slot's buffer `p`
points into, is read from a mutable global with no range at all (in
virtio's case, genuinely DEVICE-REPORTED via `used_ring_get_id()`, never
previously checked against QNUM). Fix: skip the pointer step entirely --
clamp the index with `max(min(idx, QNUM-1), 0)` and construct the
capacity view DIRECTLY from the underlying array (`rx_bufs[offset..<
offset+1514]` / `eth_rx_bufs[...]`), which the interval + Mul/Add +
same-base machinery already proves outright (same-base's literal offset
1514 covers the lo<=hi side; the array's real declared size covers the
capacity side). Net result: closes a real "trust an unvalidated
device-reported ring index" gap, not merely a cosmetic --forbid-trap
fix -- a corrupted index now degrades to reading the wrong (but always
in-bounds) slot instead of driving raw pointer arithmetic with no bound
at all.

**Another Const_env gap found in the process**: `idx * RX_BUF_SIZE`
failed to propagate a range, because Mul's positive-literal-multiplier
check only matched a bare `IntLit` AST node (`e2.desc`), not a
Const_env-resolvable NAMED constant (`RX_BUF_SIZE`, an ordinary
`let RX_BUF_SIZE: i32 = 1536;`) -- the exact same "reference vs. literal
token" distinction already fixed for the `min`/`max` builtins' range
lookups, just missed in Mul specifically. Fixed by using
`Const_env.bound_value` in place of the raw `e2.desc`/`e1.desc` match
(both files, sync rule) -- this is now consistent with how every other
P4a/P4c rule resolves constants.

**tcp_echo's `tcp_seg[20..<20+n]` (one of its two sites): fixed by NOT
re-slicing.** The problem was never irreducible -- `tcp_seg` (itself
`eth[34..<54+n]`, fully proven) has a declared minimum of only 20 (the
worst case n=0), so subslicing INTO it a second time
(`tcp_seg[20..<20+n]`) loses the connection to `n` that `tcp_seg`'s own
construction still has. Constructing the copy destination DIRECTLY from
`eth` instead -- `eth[54..<54+n]` (54 = 34+20, same memory, just reached
without the lossy intermediate step) -- reuses the exact same
literal-offset same-base proof that already closed `tcp_seg` itself.
General lesson: when a same-base-proven slice's OWN subslice fails to
prove, try reconstructing from the ORIGINAL wider-capacity base with the
combined literal offset, rather than assuming the failure is fundamental.

**tcp_echo's `frame[data_off..<data_off+data_len]`: confirmed necessary,
not just assumed.** Two additional reformulations were tried and BOTH
failed, empirically (not just argued by hand): (1) clamping `data_len`
directly with an extra `if (data_len <= TCP_MAX_PAYLOAD)` intersected into
its existing (already broken, spuriously negative) Sub-derived range --
still overshoots, because `data_off`'s own upper bound and `data_len`'s
own upper bound can't actually co-occur (they move in OPPOSITE
directions, both driven by `tcp_hdr_len`), but ordinary interval Add has
no way to know that; (2) introducing an explicit `hi = data_off +
data_len` local and validating `hi >= 0 && hi <= 1514 && data_off <= hi`
directly -- still fails, because `data_off <= hi` narrows `data_off`'s
own upper bound using `hi`'s STATIC range (the existing
comparison-against-a-range-known-variable rule), which is a DIFFERENT,
weaker fact than "lo <= hi holds for THIS specific pair," and the
same-base rule doesn't apply either (`hi` is a separate named variable,
not syntactically `data_off + <something>`). This is the one site in the
entire example suite that needs an actual relational/difference-
constraint domain to close without `unsafe` -- confirmed by exhausting
the interval toolkit's reasonable extensions, not by assumption.

**Final count: 3 of 4 `unsafe` uses removed; the remaining one is the
same site already identified as the P4 census's sole genuinely relational
case.** This is a second strong, now twice-independently-confirmed
empirical data point (after tcp_parse's "it wasn't a type-system gap"
finding) for calibrating VC+SMT's actual necessity in this codebase: even
under direct pressure to eliminate every remaining `unsafe`, the type
system's non-relational toolkit closed everything except this single,
already-diagnosed correlation.

Files: `examples/common_qemu/virtio_mmio.tkb` + `examples/common_stm32/
eth.tkb` (`net_rx_frame()` rewritten, unsafe removed), `lib/type_inf.ml`
+ `lib/llvm_gen.ml` (Mul's Const_env-constant fix), `examples/tcp_echo/
tcp_echo.tkb` (one site fixed, one site's necessity reinforced with the
two failed-reformulation findings), 1 new unit-test case for the Mul fix.

**Two follow-up refinements on the remaining site** (same session,
prompted by asking "could net_rx_frame's return type just be more
flexible instead?"):

1. `data_len` is now computed as `max(tcp_len - tcp_hdr_len, 0)` instead
   of the raw subtraction. This is a genuine, safe-side improvement, not
   just cosmetic: the raw Sub result's spuriously negative lower bound
   (an artifact of the type system, not a real possibility) is exactly
   what made the same-base rule's `wlo >= 0` guard fail. Clamping changes
   NO observable behavior (a genuinely-negative raw result clamps to 0,
   and 0 still fails the very next `data_len > 0` check exactly like a
   negative value would have) -- it only makes `data_len`'s own type
   honestly reflect a fact that was already true.

2. **Confirmed by direct algebra why "make net_rx_frame's return type
   more flexible" does not close this, and why the assertion is
   nonetheless 100% true** (not merely "probably fine"): `data_off +
   data_len = (34 + tcp_hdr_len) + (tcp_len - tcp_hdr_len) = 34 + tcp_len`
   -- `tcp_hdr_len` cancels algebraically. And `tcp_len = total_len - ihl
   <= (len - 14) - 20 = len - 34` (using the already-checked `total_len <=
   len - 14` and `ihl == 20`), so `data_off + data_len <= len <= 1514`
   ALWAYS, for any packet that passed the earlier validation -- not a rare
   case, not a protocol edge case, a plain algebraic certainty. Verified
   empirically too, not just by hand: widening `frame`'s declared minimum
   to an absurd 100000 does NOT make the proof succeed with the raw
   (unclamped) `data_len`, because the FIRST failing check is the lo<=hi
   proof (same-base's `wlo>=0` guard), independent of capacity entirely;
   only after fixing that (item 1 above) does the capacity check even
   become the active constraint, and at that point it needs frame's
   minimum to be an inflated (dishonest) ~1554 to close -- confirming the
   gap is purely representational (the type system cannot express "these
   two variables' sum is invariant"), not a real runtime possibility and
   not something any amount of "flexibility" on frame's OWN declared type
   can fix, since frame's type has nothing to do with the data_off/
   data_len relationship at all.

### Synchronization Primitive Design and Current Limitations

Synchronization primitives have a 3-layer structure:

```
assembly (ldaxr / stlxr)
  +---- sem_wait / sem_post          <- atomic guarantee only here (extern fn)

takibi
  +---- mutex_lock / mutex_unlock    <- named wrappers around sem_wait/sem_post
  +---- cond_wait / cond_signal      <- sequence counter method (written in takibi)
```

See the comment in each `.tkb` file for implementation details (`condvar.tkb` explains missed-wakeup prevention in `cond_wait`).

**Current limitation: single-core only**
- `cond_signal`'s `*seq = *seq + 1` is not atomic. The convention of calling it while holding the mutex makes it correct on a single core, but it is insufficient for multi-core.
- `cond_wait`'s spin `while (*seq == s) {}` is a plain volatile load without a hardware memory barrier. Multi-core requires replacing it with `ldar` (load-acquire).

### Distinguishing MMIO from Regular Pointers (`io T`, `*io T` vs `*T`)

**Type relationships**:
- `io T` -- volatile-qualified value type (AST: `TypeIo T`). LLVM type is the same as T. A storage qualifier.
- `*io T` -- volatile MMIO pointer (AST: `TypePtr (TypeIo T)`). LLVM type is opaque ptr.
- `*T` -- regular pointer (AST: `TypePtr T`). Non-volatile.

**Where volatile is generated**:
- `let irq_done: io i32;` -- all reads and writes to this global variable are volatile
- `irq_done = 1;` -> volatile store (automatic)
- `while (irq_done == 0) {}` -> `irq_done` is a direct volatile load (automatic)
- `&irq_done` -> automatically returns `*io i32` (no `as *io i32` cast needed)
- Struct field `done: io i32;` -> `s.done = 1;` is a volatile store
- `*p` where `p: *io i32` -> volatile load
- `*p = v` where `p: *io i32` -> volatile store
- `p.field` where `p: *io Struct` -> volatile load (`through_io` flag)

**`io` is stripped on Deref**: `*p` where `p: *io i32` -> result type is `i32` (not `io`). Volatile is confined to `set_volatile true` on the load.

- `*io T` is a compiler-level distinction. CPU-level memory barriers are provided by `ldaxr/stlxr` (extern fn).
- Pointer arithmetic `*io T + isize` -> remains `*io T` (matches `TypePtr _`)
- `i32 as *io T` -- MMIO address literal assignment (inttoptr coercion, `TypePtr _` case)

### Volatile Reads of Global Variables (Interrupt-Shared Flags)
LLVM may hoist a global variable load out of a tight loop like `while (flag == 0) {}`,
resulting in an infinite loop (`cbz reg, self`).
Use `io i32` for flags shared with interrupt handlers:

Declare flags shared with interrupt handlers as `io i32`:
```takibi
let sched_done: io i32 = 0;        // volatile global declaration
sched_done = 1;                    // volatile store (automatic)
let p: *io i32 = &sched_done;      // &io_var automatically returns *io i32 (no cast needed)
while (*p == 0) {}                 // volatile load -- prevents hoisting
```
`AddrOf (Var name)` where `name: io T` -> automatically returns `TypePtr (TypeIo T)` = `*io T`. No cast needed.

### Integer Literal -> Pointer Coercion
`let dr: *io u8 = 0x09000000;` assigns an integer literal to an MMIO pointer type variable.
The `coerce` function in `llvm_gen.ml` emits `inttoptr(zext(i32, i64), ptr)` (`TypePtr _` case).

### Makefile Example Registration Convention
Adding a name to the `EXAMPLES` list is all that's needed to register a new example.
Convention: `examples/<name>/<name>.tkb` -> `examples/<name>/kernel.elf`

```makefile
EXAMPLES := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined narrow for loop  # <- just add the name here
```

Only targets that require interactive manual startup (like `qemu-echo`) are added individually.
Automatable programs are registered in `qemutest` by providing `.expected` / `.stdin` files.
Use `run_test_timed` for tests that need timing verification (to confirm a delay actually waited).

**Compilation groups** (which common `.tkb` files are prepended to each example)
-- see the Makefile's own "Common file sets passed to takibi" comment
(just above `IRQ_OBJS`) for the authoritative, currently-maintained list;
summarized here:
- Standard (uart.tkb + print.tkb): most examples
- IRQ group (+ gic.tkb): `irq`
- Timer group (+ gic.tkb + timer.tkb): `preempt`, `semaphore`, `watchdog`
- Sync group (+ gic.tkb + timer.tkb + sync.tkb): `condvar`, `msgqueue`
- Net group (+ gic.tkb + virtio_mmio.tkb + netutil.tkb): `net_echo`, `arp_reply`
- Checksum group (+ inet_checksum.tkb + netutil.tkb): `inet_checksum`, `ip_parse`, `tcp_parse`
- App group (+ gic.tkb + virtio_mmio.tkb + inet_checksum.tkb + netutil.tkb): `icmp_echo`, `tcp_echo`, `http_server`

Note: `semaphore.tkb` declares its own `extern fn sem_wait/sem_post` (no `sync.tkb` needed), but still needs `sem_asm.o` at link time.

**Link groups** (which common assembly objects are linked in):
```makefile
TIMER_KERNELS := examples/preempt/kernel.elf examples/watchdog/kernel.elf
                 # linked with: startup.o + timer_asm.o
SEM_KERNELS   := examples/semaphore/kernel.elf examples/condvar/kernel.elf examples/msgqueue/kernel.elf
                 # linked with: startup.o + timer_asm.o + sem_asm.o
GENERIC_KERNELS := (all others)
                 # linked with: startup.o only
```

When adding a new example that needs timer or semaphore support, add it to the appropriate `*_OBJS` and `*_KERNELS` variable in the Makefile. No new `*_asm.S` files should be created; place any new assembly in `examples/common/` and add a build rule there.

**This `EXAMPLES` registration flow is separate from the `-g` debug-build
rules** (`examples/<name>/<name>.debug.o` / `kernel.debug.elf`, e.g. for
`fizzbuzz`, `fibonacci`, `http_server`, `tcp_echo`) -- those are one-off,
manually-written rules outside `EXAMPLES`, not a third compilation group.
See "Execution Profiling (QEMU)" below for why they're kept separate from
the normal (always `-g`-free) build outputs.

### STM32 Hardware Test Harness: RAM Execution Instead of Flash (make hwcheck)

**The concern, raised before any code was written**: `make hwcheck` flashes
every STM32 example over `st-flash write`. Every example binary (3KB-8KB)
is well under Flash Sector0's 32KB, so every one of hwcheck's ~41 tests
erases/writes that *same* physical sector on *every single run* -- one
`make hwcheck` invocation alone burns 41 erase cycles on Sector0. STM32's
internal Flash is generally specified at a guaranteed minimum of ~10,000
erase cycles (standard across the STM32 family), so that is only ~200
`make hwcheck` runs before Sector0's guaranteed lifetime is exhausted --
not a concern for occasional manual runs, but a real one once hwcheck
starts running frequently in CI (planned, not yet wired up). This was
raised and discussed BEFORE any of the discussion below about consolidating
tests to reduce flash writes -- the two ideas were evaluated independently:
consolidating multiple examples into fewer `st-flash` calls would help
(same physical sector, fewer erases per run), but RAM execution removes
the constraint category entirely (SRAM has no comparable wear-out), so
that was pursued instead, keeping the existing one-example-per-test
granularity (deliberately NOT consolidated -- see the flash-endurance
discussion above this entry for why fine-grained per-example tests are
otherwise worth keeping: trivial failure attribution, and consistency
with the same 1-example=1-artifact=1-test shape `stm32build`/`qemutest`
already use).

**AXI SRAM1 (240K, 0x20010000), not DTCM (64K, 0x20000000)** -- deliberately,
even though DTCM would have been the simpler choice (see the earlier
discussion of RAM execution feasibility): DTCM sits outside the Cortex-M7
cache hierarchy entirely, so code executing there would never exercise the
genuinely cacheable-memory code paths this project cares about (and which
motivated asking "can this double as a way to more rigorously test cache
behavior" in the first place). The Ethernet DMA master also cannot reach
DTCM at all -- a real, pre-existing constraint (see `link_eth.ld`'s own
comment), meaning DTCM is if anything the MORE restricted region once
Ethernet is in the picture, not a safer default.

**No explicit MPU region needed for AXI SRAM1** -- a genuine, and pleasant,
finding rather than an assumption carried in from the start: ARMv7-M's
architectural default memory map already describes the whole
0x20000000-0x3FFFFFFF SRAM range (which covers AXI SRAM1) as Normal,
Write-Back Write-Allocate cacheable, shareable, AND executable. This is
exactly the "genuinely cacheable, genuinely executable" behavior wanted,
with zero MPU configuration -- unlike `startup.S`'s existing Ethernet DMA
window, which exists specifically to OVERRIDE this same default down to
non-cacheable for one 64KB sub-region (see that file's comment). A single
MPU region covering exactly AXI SRAM1's odd 240KB size at its 64KB-aligned
base (0x20010000) isn't even expressible as one region anyway (MPU regions
must be a power-of-two size, naturally aligned to that size) -- another
reason the "rely on the default map, configure nothing" answer turned out
to be the right one, not just the easy one.

**The core technique -- bypassing the hardware boot-vector fetch**: Cortex-M
always fetches its initial SP (word 0) and PC (word 1) from address 0x0 at
reset, which is hardwired and aliased to Flash; this cannot itself be
redirected to RAM without physically changing the board's BOOT pins.
Instead, `examples/common_stm32/startup_ram.S` + `examples/common_stm32/
link_ram.ld` (new files, siblings of `startup.S`/`link.ld`) target AXI
SRAM1 for the whole image (vector table, `.text`, `.rodata`, `.data`,
`.bss`, stack), and `scripts/run_hwtest_ram.sh` does by hand, from OpenOCD,
exactly what silicon would have done automatically: `reset halt` (halts
the core before any Flash code executes), `load_image` the linked ELF
directly into AXI SRAM1 over SWD, reads the initial SP/PC back out of word
0/word 1 of the freshly-loaded vector table, pokes them into the debug
SP/PC registers, and `resume`s. `startup_ram.S`'s `Reset_Handler` sets
`SCB_VTOR` to point at its own vector table as its very first instruction
(before anything could plausibly fault or before any interrupt could be
enabled) -- this is the one boot step the debugger cannot do by poking
registers alone, since VTOR resets to 0x00000000 (the Flash alias) and
nothing else would ever correct it, and every later interrupt (SysTick,
USART1, PendSV) depends on it being right.

**`reset halt`, never `reset init`, is deliberate and load-bearing**: the
board's OpenOCD config (`board/stm32f746g-disco.cfg`) has a `reset-init`
event handler that reprograms the clock tree to 192MHz for QSPI flash
access -- completely incompatible with every example's `uart_init()`,
which computes its BRR divider assuming the default 16MHz HSI clock (see
the USART1 entry in this file's STM32 bring-up section). `reset init` is
the OpenOCD command that fires that handler; `reset halt` performs a
plain hardware reset with none of the vendor clock-boost logic, leaving
the chip exactly where a real Flash boot would. Confirmed empirically,
not just reasoned about: the first end-to-end test (`hello`) produced
byte-exact UART output at 115200 baud with no clock mismatch.

**`.data` needs no copy loop in the RAM variant, unlike `startup.S`**:
`link_ram.ld` gives `.data` the same load address and run address (no
`AT> FLASH` clause) -- there is no separate Flash copy for it to be
copied out of at boot, since the debug probe writes the final bytes
directly into RAM. `startup_ram.S` omits the copy loop entirely rather
than keeping a now-pointless self-copy, to keep the file's intent clear.

**Validated on real hardware before generalizing to all 41 tests, not
assumed to work from the design alone**: `hello` (baseline UART output,
no interrupts) and `preempt` (SysTick+PendSV preemptive scheduler,
interrupt-driven, directly exercising the VTOR-relocation requirement)
were both hand-tested via a raw `openocd -c "..."` invocation first,
each producing byte-exact UART output matching their existing `.expected`
files, before any Makefile/script generalization was written. After
generalizing, a full `make hwcheck` run passed all 41 tests in ~49
seconds (comparable to the old Flash-based ~50-60s), with zero `st-flash`
invocations anywhere in the run.

**Scope: the 5 real-Ethernet examples (`net_echo`/`arp_reply`/`icmp_echo`/
`tcp_echo`/`http_server`) are deliberately NOT part of this migration.**
They were never part of `make hwcheck` to begin with -- they're exercised
separately, over real wiring, by `make hwcheck-net`/`run_hwtest_net.sh`,
which this change does not touch at all. Migrating them to RAM execution
later needs one more decision this session flagged but did not resolve:
their DMA descriptor/buffer region is currently marked non-cacheable via
an explicit MPU window specifically so cache-coherence correctness doesn't
matter operationally (see the Ethernet DMA section of this file); a
RAM-execution version of those examples would need to decide whether to
keep that same non-cacheable policy (simple, but still not exercising the
`dma_publish`/`dma_consume`/`device_fence` cache-maintenance code paths
in anger) or make that region genuinely cacheable and rely on those
builtins for real (closer to this session's original motivation of
wanting to actually test cache behavior, but a bigger change to the
driver's correctness model). Revisit when there is a concrete need to
exercise that path specifically, per this project's usual practice of not
generalizing ahead of one.

**Files**: `examples/common_stm32/startup_ram.S` (new), `examples/
common_stm32/link_ram.ld` (new), `scripts/run_hwtest_ram.sh` (new,
supersedes the deleted `scripts/run_hwtest.sh`), `scripts/
stm32_hw_claim.sh` (recognized-runner pattern updated), `Makefile`
(`STM32_RAM_EXAMPLES`/`STM32_RAM_ELFS`/`STM32_RAM_ELFS_GENERIC`, the
`startup_ram.o` and `kernel_stm32_ram.elf` build rules, `stm32build-ram`,
`hwcheck`'s implementation switched over). `make check`/`make stm32build`
(the Flash-based product/demo build) and `make hwcheck-net` are both
unaffected -- this migration is scoped entirely to `make hwcheck`'s own
implementation.

### Follow-up: hwcheck-net Migrated to RAM Execution Too, DMA Buffers Made
### Genuinely Cacheable

Direct follow-up to the RAM-execution entry above, prompted by the
question "can hwcheck-net move to RAM execution too, with the DMA buffer
region made genuinely cacheable" -- i.e. actually doing the thing the
previous entry's own motivation ("wanting to more rigorously test cache
behavior") had left as an open follow-up rather than deferring it further.

**Investigated before writing any code, not assumed**: whether
`examples/common_stm32/eth.tkb`'s existing `dma_prepare_tx`/
`dma_prepare_rx`/`dma_finish_rx` calls actually emit real cache
maintenance, or were themselves just no-ops that happened to be harmless
on the previously-non-cacheable window. Reading `lib/llvm_gen.ml`
confirmed the former: on `arm`/`thumb` targets, `dma_prepare_tx` emits a
real cache-line CLEAN loop (`emit_cortex_m_cache_range CacheClean`, via
Cortex-M7's memory-mapped `SCB_DCCMVAC` register at `0xE000EF68`, looping
32-byte lines across the address range) followed by a DSB; `dma_prepare_rx`
emits INVALIDATE (`SCB_DCIMVAC`, `0xE000EF5C`) before a DMA write;
`dma_finish_rx` does barrier+invalidate+barrier after one. This is
genuine, already-implemented, already-correct cache-maintenance codegen --
never exercised against real cacheable memory before this session, but not
a stub either.

**Read through every RX/TX ownership transition in `eth.tkb` before
flipping the memory attribute**, specifically checking each CPU<->DMA
handoff cleans (CPU writes -> device reads) or invalidates (device writes
-> CPU reads) at the right point relative to the actual read/write, not
just "somewhere nearby": `eth_rx_ring_init`/`net_rx_release` invalidate
the RX buffer before handing it to DMA and clean the descriptor after
writing OWN; `net_rx_acquire`/`dma_finish_rx` invalidate the descriptor
before reading OWN/FL and invalidate the buffer before the caller reads
frame data; `net_transmit` cleans both the payload buffer and the
descriptor before kicking DMA, and invalidates the descriptor on every
poll of the completion loop. Every site checked out -- the driver was
written as if cache correctness already mattered, matching this project's
own prior note that "the compiler DMA builtins... remain correct if
buffers later move elsewhere." MMIO peripheral registers (`ETH_DMATPDR`
etc.) are unaffected regardless of this change -- they sit in the
`0x40000000-0x5FFFFFFF` Peripheral region, a completely different part of
the ARMv7-M default memory map (Device, non-cacheable) than AXI SRAM1.

**The change itself turned out to need no new linker script or startup
file**: `link_ram.ld`/`startup_ram.S` (from the entry above) already put
the *whole* image in AXI SRAM1 with no MPU region at all, relying on
ARMv7-M's default map -- which is exactly "genuinely cacheable" already.
The 5 Ethernet examples' existing `examples/NAME/NAME_stm32.o` objects
(built the same way regardless of link target, same reasoning as every
other RAM-exec example) just needed adding to `STM32_RAM_EXAMPLES` in the
Makefile and a link against `link_ram.ld` instead of `link_eth.ld` --
no new MPU non-cacheable window, no code change to `eth.tkb` at all.
The Flash-shipped product build (`stm32build`, `make stm32-http-server`)
is untouched -- it still links against `link_eth.ld`/`startup.S`'s
existing non-cacheable window, so the shipped device's behavior does not
change.

**`scripts/run_hwtest_net_ram.sh`** (new, supersedes the deleted
`scripts/run_hwtest_net.sh`) is the Ethernet counterpart of
`run_hwtest_ram.sh`: same `reset halt` + `load_image` + read-vector-table
+ poke-SP/PC/VTOR + `resume` sequence, duplicated rather than shared
(same self-contained-runner convention as before), feeding into the
existing `sudo python3 <test_script>` raw-socket test invocation
unchanged -- those scripts talk over the wire and have no idea how the
firmware got onto the chip.

**Validated against real hardware over the actual wired point-to-point
link before considering this done** -- not just "compiles and the driver
code looks right": `make hwcheck-net` (all 5 examples) passed in full,
including `net_echo`'s varying-payload-size sweep (46 to 1486 bytes,
spanning many cache lines each), `tcp_echo`'s complete handshake/
data-echo/close/reconnect cycle, and `http_server`'s two-sequential-
request counter-bump check -- i.e. real multi-frame, multi-cache-line DMA
traffic in both directions, not a single trivial packet. Total wall time
~17s for all 5, comparable to (slightly faster than) the old Flash-based
run.

**Files**: `Makefile` (`STM32_RAM_EXAMPLES` extended with the 5 Ethernet
names, `hwcheck-net`'s implementation switched over), `scripts/
run_hwtest_net_ram.sh` (new), `scripts/stm32_hw_claim.sh`
(recognized-runner pattern updated again). No changes to `lib/llvm_gen.ml`
or `examples/common_stm32/eth.tkb` -- the cache-maintenance codegen and
the driver's call sites were already correct; only the memory attribute
governing whether they matter changed, and only for this RAM-execution
test path.

### Follow-up: stm32build Itself Consolidated onto RAM Execution, with
### examples/http_server Kept as the One Deliberate Flash Exception

Direct follow-up to the two RAM-execution entries above, prompted by the
question "should ALL STM32 code execution in this repo move to RAM, so
every memory region is uniformly cacheable, avoiding the confusion of two
different cache policies (Flash-build non-cacheable vs. RAM-build
cacheable)?"

**Pushed back before implementing, rather than doing what was literally
asked.** RAM execution only exists while a debugger is actively driving
the core over SWD (halt at reset, load into AXI SRAM1, poke SP/PC/VTOR,
resume) -- AXI SRAM1 has no non-volatile retention, so a genuinely
all-RAM build would mean every STM32 example, including
`examples/http_server`, could no longer boot standalone from a power-on
with no debugger attached. This directly conflicts with `make
stm32-http-server`'s whole point (flash it once, then just plug in power
and browse to it) and with this project's own stated top-level goal
(CLAUDE.md's first paragraph: "run an HTTP server on ... STM32 bare-metal
environments"), not just a stylistic inconsistency. Proposed the
alternative that actually addresses the stated motivation (uniform,
always-cacheable memory, no non-cacheable special case) without losing
standalone boot: keep `examples/http_server`'s Flash build, but remove its
AXI SRAM1 MPU non-cacheable window too, relying on the same ARMv7-M
default-map reasoning already validated for the RAM-execution path. Used
`AskUserQuestion` to make the tradeoff explicit rather than silently
picking one interpretation of an ambiguous request whose literal reading
would have been a significant, hard-to-reverse-in-spirit regression across
every example in the repository.

**The user's actual answer, after seeing the tradeoff, was a third option
neither originally offered**: keep `http_server` Flash-resident (for
standalone boot) with genuinely cacheable RAM (addressing the original
motivation), AND separately consolidate the general `stm32build`/
`stm32build-ram` Makefile targets into one RAM-only target for everything
else (since nothing else in the repository has ever had a "must boot
standalone" requirement -- only `http_server` does, via `make
stm32-http-server`). This is narrower and more surgical than either
original option, and is what got implemented.

**Concrete changes**:
- `examples/common_stm32/startup.S`'s MPU non-cacheable-window setup
  (region 0, 0x20010000, 64KB, TEX=1/C=0/B=0/S=1) was deleted entirely --
  not reconfigured, removed -- matching `startup_ram.S`'s existing
  no-MPU-region approach exactly (same architectural-default-map
  reasoning, same comment cross-referencing the other file). `startup.S`
  is now used by exactly one build: `examples/http_server/kernel_stm32.elf`.
- `examples/common_stm32/link.ld` (the DTCM-only Flash linker script) was
  deleted -- once every non-`http_server` example dropped its Flash
  build, nothing referenced it anymore, and this project's established
  practice throughout its history has been to remove superseded
  infrastructure rather than leave it unreferenced (see the earlier
  "no `_stm32.tkb` variant exists anywhere in this repo" precedent in the
  STM32 bring-up section).
- `link_eth.ld` was kept unchanged (it never had a non-cacheable MPU
  region of its own -- that lived entirely in `startup.S` -- so nothing
  about the linker script itself needed to change for the cacheability
  flip).
- Every per-example Flash `kernel_stm32.elf`/`.bin` rule was deleted
  except `examples/http_server`'s (18 rules across rtc/timer/echo/irq/
  preempt/semaphore/condvar/msgqueue/watchdog/net_echo/arp_reply/
  icmp_echo/tcp_echo, plus the generic `$(STM32_KERNELS)`/`$(STM32_BINS)`
  and checksum-group pattern rules). Every example's `.o` compile rule
  (`examples/NAME/NAME_stm32.o`) was left untouched -- compiling to
  object code never depended on which linker script would later consume
  it, the same reasoning that made the original RAM-execution migration
  cheap to generalize across ~44 examples in the first place.
- `stm32build` and `stm32build-ram` (two Makefile targets) became one:
  `stm32build` now builds `$(STM32_RAM_ELFS)` (everything, RAM-execution),
  and `stm32build-ram` no longer exists as a separate name. `make check`
  (which already depended on `stm32build`) and `make hwcheck`/`make
  hwcheck-net` (updated from depending on `stm32build-ram` to depending on
  `stm32build`) all continue to work with no further changes, since the
  target NAME `stm32build` was kept stable even though its underlying
  BEHAVIOR changed.

**Validated at three separate levels, not just "it compiles"**:
1. `make check` (125 software tests, including the now-RAM-execution
   `stm32build` as one of its prerequisites) -- unaffected, all pass.
2. `make hwcheck` (41 tests) and `make hwcheck-net` (5 tests) against real
   hardware -- both re-run in full after the consolidation, all pass,
   confirming the Makefile restructuring didn't silently break anything
   the two hardware test harnesses depend on.
3. **The one thing neither hwcheck nor hwcheck-net actually exercises:
   the genuinely-standalone Flash boot path itself.** Both hardware test
   harnesses use OpenOCD's `reset halt` + register-poke technique
   (`--connect-under-reset`-equivalent), which is NOT the same code path
   as a real device being flashed and power-cycled/reset normally.
   Explicitly flashed `examples/http_server/kernel_stm32.bin` via a plain
   `st-flash write` + `st-flash reset` (the exact sequence `make
   stm32-http-server` itself performs, deliberately NOT the debugger
   halt-and-poke sequence used elsewhere in this session), then ran
   `scripts/eth_http_server_test.py` against the now-standalone-booted
   board -- both requests passed, confirming the genuinely-cacheable DMA
   region works correctly even when the CPU reaches it via a real
   hardware reset from Flash, not just via a debugger-mediated boot.

**Files**: `examples/common_stm32/startup.S` (MPU window removed, header
comment updated to note it's now http_server-only), `examples/
common_stm32/link.ld` (deleted), `Makefile` (`STM32_KERNELS`/
`STM32_BINS`/`STM32_EXTRA_BINS`/`STM32_CHECKSUM_KERNELS`/
`STM32_CHECKSUM_BINS` variables removed; ~18 Flash build rules removed;
`stm32build`/`stm32build-ram` merged; `hwcheck`/`hwcheck-net` updated to
depend on the merged `stm32build`; `COMMON_STM32_LINK_LD` variable
removed; `examples/http_server/kernel_stm32.elf`'s rule kept, with an
expanded comment explaining why it's the one exception).

### Follow-up: The Flash Boot Path Had Zero Automated Coverage -- Fixed by
### Testing http_server Twice in hwcheck-net

Found by the user re-reading the previous entry's own closing validation
step ("verified with a genuine st-flash write + st-flash reset... followed
by the real HTTP test script") and asking a sharp question: that
verification was a one-off manual command run once, in this session, not
a test that would run again on the next `make hwcheck-net`. Once every
STM32 example except `examples/http_server` dropped its Flash build
(previous entry), the real hardware boot-vector fetch from Flash (silicon
reading SP/PC from address 0x0 directly) became the ONE code path in this
entire repository that no automated test exercised at all -- every
hardware test elsewhere uses OpenOCD's `reset halt` + debugger
register-poke instead, a related but genuinely different mechanism (see
the RAM-execution entries above). Before this consolidation, a regression
in Flash-boot behavior would likely have been caught by ANY of ~45
similar Flash-booting examples failing; after it, http_server was the
only one left, and it had no automated coverage of that specific path.

**Investigated whether this concern was actually substantive first**
(specifically: is `startup.S`'s `.data` copy-from-Flash loop -- the most
Flash-boot-specific piece of logic in that file -- meaningfully
untested?), rather than assuming the gap mattered just because it existed.
Checked `examples/http_server/kernel_stm32.elf`'s actual section sizes:
`.data` is 0 bytes (every current example's initialized-global data ends
up entirely in zero-initialized `.bss` instead), so the copy loop's
bounds are equal and its body never iterates -- the loop's SHAPE runs but
copies nothing. This weakens (but does not eliminate) the "untested code"
argument: the genuinely irreplaceable things a Flash-execution automated
test provides are the real hardware boot-vector fetch itself, actual
Flash-resident instruction fetch (behind the ART accelerator, not SRAM),
and the standalone/no-debugger-attached property -- not the empty copy
loop specifically.

**Implemented as a second, explicit test rather than replacing the
existing RAM test**, since the two test different things: `http_server
(stm32/ram)` continues validating driver/cacheable-DMA correctness in
isolation (same technique as the other 4 Ethernet examples);
`http_server (stm32/flash)` (new) validates the actual deployed boot path
end to end. `scripts/run_hwtest_net_ram.sh` gained `run_net_hw_test_flash`,
a `st-flash --connect-under-reset write` + `st-flash --connect-under-reset
reset` counterpart of `run_net_hw_test` (matching `make
stm32-http-server`'s own exact invocation, not a new third convention),
run against the same `scripts/eth_http_server_test.py`. `hwcheck-net`'s
Makefile prerequisites gained `examples/http_server/kernel_stm32.bin`
accordingly (previously only implicitly built via the now-removed
`stm32build`-includes-everything assumption, which no longer holds since
`stm32build` dropped Flash builds).

**This does reintroduce one Flash erase/write cycle into `hwcheck-net`
specifically** (bounded to exactly the one example this project
deliberately keeps Flash-resident, on a target that only runs
occasionally and needs physical Ethernet wiring -- a very different
frequency/scale concern than the original ~46-erases-per-run problem the
whole RAM-execution migration exists to solve, see the first
RAM-execution entry above). Judged an acceptable, narrowly-scoped
trade-off: this is literally the one artifact whose entire reason for
existing is to be flashed, so testing it via the same mechanism it will
actually be used with is more correct, not less, than testing it only
through the debugger-mediated RAM path.

**Validated on real hardware**: `make hwcheck-net` now runs 6 tests
(previously 5), all passing, total wall time ~20s (up from ~18s -- the
one added Flash write/reset/verify cycle is the entire difference).

**Files**: `scripts/run_hwtest_net_ram.sh` (`run_net_hw_test_flash`,
`FLASH_ADDR`, the new `http_server (stm32/flash)` invocation, header
comment expanded), `Makefile` (`hwcheck-net`'s prerequisites gained
`examples/http_server/kernel_stm32.bin`). No changes to
`examples/common_stm32/eth.tkb`, `startup.S`, or any linker script --
this entry is purely about test coverage, not behavior.

### GitHub Issue #77: sizeof(...)/offsetof(...) Lost Compile-Time-Constant
### Status When Threaded Through Lets/Globals Into Subslice Bounds

**The bug, reproduced before touching any code**: `sizeof(T)`/`offsetof(T,
field)` type-checked and evaluated to correct numeric constants, but using
one -- directly, or via a `let`/global -- as a slice subslice bound
(`s[0..<sizeof(Hdr)]`) fell back to a runtime bounds check under
`--forbid-trap`, even for a packed struct whose layout is fully known at
compile time. Reproduced with three shapes (direct use, `sizeof` via a
local `let`, `offsetof` via a local `let`) matching the issue's own
description exactly -- all three emitted `subslice bounds check remains`
under `--forbid-trap` before this fix, zero after.

**Root cause, confirmed by reading the code rather than assumed**:
`SizeOf`/`OffsetOf` in `lib/type_inf.ml` always returned the bare type
`TUsize` -- never a `TRefinedInt`. Every subslice-bound proof in this
compiler (`SliceOf`'s `bound_range` in both `type_inf.ml` and
`llvm_gen.ml`) recognizes a bound as "known" only via `Const_env`
(bare `IntLit`/named-literal-global) or via the expression's own
`TRefinedInt`-shaped type -- a bare `TUsize`, no matter how it arrived,
looks identical to "an arbitrary unconstrained usize value" to that
machinery, which is exactly "the compiler losing the fact that the value
is a compile-time constant" the issue describes. This was not a
propagation bug (nothing was failing to THREAD an already-known fact
through lets) -- `sizeof`/`offsetof` simply never became refined in the
first place, at the one place (`type_inf.ml`, before any target/
DataLayout is set up) that decides the type.

**Why "before any target is set up" is the crux of the fix's scope**:
`sizeof`/`offsetof`'s true numeric value for an ordinary (non-packed)
struct depends on target-specific alignment/padding (`Llvm_target.
DataLayout`), which genuinely is not available during type inference --
this is exactly why `sizeof(T)` was never usable as an array size either
(see that section above). But a PACKED struct (`struct packed Name {
...}`) composed entirely of fixed-width primitive fields (u8/u16/u32/u64/
i8/i16/i32/i64/bool, or fixed arrays/nested packed structs of such) has a
size and field offsets that are target-INDEPENDENT by construction --
packed structs have zero implicit padding, by LLVM's own definition, on
every target. This is exactly the shape of every real protocol header in
`examples/common/netutil.tkb` (EthHdr/ArpHdr/Ipv4Hdr/TcpHdr/IcmpHdr, all
`u8`/`[u8;N]` fields, no `align(N)`) -- the issue's own motivating case.

**The fix**: `lib/type_inf.ml` gained `const_type_size`/
`const_field_offset`, a pair of pure-OCaml functions computing sizeof/
offsetof by hand for exactly this restricted shape (packed struct, no
`align(N)`, every field's size itself computable the same way,
recursively) and returning `None` for anything else (non-packed structs,
`align(N)` structs -- tail padding is a deliberately deferred extension,
not a hard wall, see the function's own comment -- pointers, usize/isize
fields, enums). `SizeOf`/`OffsetOf` now return `TRefinedInt (v, v+1,
TUsize)` (a singleton range -- "exactly this value") when computable,
falling back to the original plain `TUsize` otherwise -- zero behavior
change for every case this doesn't cover. Once typed as a genuine
`TRefinedInt`, `sizeof`/`offsetof` values thread through `let`/global
bindings and interval arithmetic (`+`) automatically, via machinery this
project already built for every other refined constant -- no changes were
needed to the subslice-proof logic itself, only to what type `SizeOf`/
`OffsetOf` report.

**`lib/llvm_gen.ml` needed the identical restriction independently
implemented (sync rule)**, not because it lacks the real answer -- codegen
already has genuine `Llvm_target.DataLayout` access and could in
principle compute a correct value for ANY struct shape -- but because this
project's `--forbid-trap` guarantee is deliberately type-level, not
codegen-level (see that section's own "the judgment is deliberately
type-level, not post-optimizer" note): codegen must never prove a WIDER
class of bounds than type inference already decided, or the two phases'
notions of "provable" would silently diverge. `struct_is_packed` (new
Hashtbl, populated in Pass 0 alongside the existing `struct_fields`/
`struct_alignments`) and mirror `const_type_size`/`const_field_offset`
functions (operating purely on `Ast.type_expr`, never touching
`DataLayout`) reproduce type_inf.ml's decision exactly.

**A genuine soundness cross-check, not defensive boilerplate**: since two
independent implementations (OCaml hand-arithmetic vs. real DataLayout)
now both compute a numeric value for the same packed-struct case, `lib/
llvm_gen.ml`'s `SizeOf`/`OffsetOf` codegen compares them and raises a
"BUG:" `Error` if they ever disagree, rather than trusting the OCaml
formula silently. This is the same "codegen re-verifies rather than
trusts type_inf" discipline `SliceOf` codegen already uses elsewhere in
this file, applied to a new pair of functions whose correctness this
change's whole soundness argument depends on -- if the hand-rolled
byte-size arithmetic ever had a bug (e.g. missing a primitive type case,
or getting bool's size wrong on some future target), this assertion
would fail loudly on the very next test exercising a packed struct's
sizeof, rather than silently proving an unsound bound.

**Verified, not just implemented**:
- The three originally-reported shapes (direct, sizeof-via-let,
  offsetof-via-let) now compile clean under `--forbid-trap` (zero trap
  sites; previously three).
- Negative controls confirmed the fix does not over-claim: a non-packed
  struct's `sizeof`, and a packed-but-`align(N)` struct's `sizeof`, both
  still correctly require a runtime check (one recorded trap site each) --
  no regression in soundness for the cases deliberately left out of scope.
- The actual `netutil.tkb` header shapes (`EthHdr`, `Ipv4Hdr`) were tried
  directly, including the realistic chained pattern the issue's own
  protocol-example refactor needs (`f[ip_off..<ip_off + sizeof(Ipv4Hdr)]`
  where `ip_off` is itself `sizeof(EthHdr)`, plus `offsetof(Ipv4Hdr,
  total_len)` through a `let`) -- compiles clean under `--forbid-trap`.
- 6 new unit tests (3 type-level, checking the exact inferred type for
  primitive/packed/non-packed/aligned-packed sizeof and packed offsetof;
  2 codegen-level, using `expect_trap_sites` to check the issue's exact
  repro shapes prove with zero trap sites and the non-packed negative
  control still records one) plus 1 existing test updated (it asserted
  `sizeof(i32)` -- a primitive, now correctly refined -- had bare
  `TUsize`; that assertion was the old under-refined behavior this issue
  is about, not a case this fix needed to preserve). Full `make check`
  (langcheck, 453 unit tests, stm32build, all 125 qemutest cases) passes
  with zero regressions.

**Deliberately not addressed** (per this project's usual practice of not
generalizing ahead of a concrete need, and because widening scope here
directly trades against the soundness argument's simplicity): `align(N)`
tail padding (the round-up arithmetic is pure and target-independent in
principle -- `sz + (n - sz mod n) mod n`, matching `llvm_gen.ml`'s own
Pass 0 formula exactly -- so this is a natural, low-risk future
extension, not a hard architectural wall, just not something any current
example needs); non-packed structs in general (would require type
inference to know target-specific alignment rules, a materially bigger
change); enum fields, nested non-packed structs, and pointer/usize/isize
fields within an otherwise-packed struct (all correctly fall through to
the existing unrefined `TUsize` today).

**Actually replacing netutil.tkb's hand-maintained offset constants
(`ETH_HDR_LEN`, `IP_TOTAL_LEN_OFF`, etc.) with `sizeof(...)`/`offsetof
(...)` expressions using this now-working machinery** is a natural
follow-up this fix unblocks, but was not done as part of it -- the issue
itself is scoped to the compiler gap, not the examples refactor that
surfaced it.

**Files**: `lib/type_inf.ml` (`senv`'s value type extended to `(fields,
is_packed, align_bytes)`, `const_type_size`/`const_field_offset`,
`SizeOf`/`OffsetOf` cases), `lib/llvm_gen.ml` (`struct_is_packed`,
mirror `const_type_size`/`const_field_offset`, `SizeOf`/`OffsetOf`
cases with the BUG cross-check), `lib/types.ml` (`program_types.structs`'
type updated to match `senv`'s new shape -- constructed but not
consumed anywhere else in the codebase today), `test/test_takibi.ml`
(1 test updated, 6 new).

### Follow-up: The netutil.tkb Migration to sizeof(...)/offsetof(...), and a
### Second, Deeper Bug Found Along the Way (Global Initializers)

Direct follow-up to the issue #77 fix above -- actually doing the
netutil.tkb refactor the issue's own motivating example described, rather
than leaving it as a hypothetical the compiler fix merely unblocked.

**Scoping check done before writing any code**: grepped every offset/
length constant netutil.tkb defined against all consumers repository
-wide. Found the `isize`-typed "_OFF"/"_HDR_LEN" constants (`ETH_HDR_LEN`,
`ARP_HDR_LEN`, every `ARP_*_OFF`, `IP_HDR_LEN`, `IP_ADDR_LEN`, every
`IP_*_OFF`, `TCP_HDR_LEN`, every `TCP_*_OFF`, `ICMP_HDR_LEN`, every
`ICMP_*_OFF`) had ZERO callers anywhere in the repository -- dead code
left behind when the P4b migration wave deleted the pointer-based `*_p`
wrappers that used to consume them, never cleaned up at the time. Only
the `usize`-typed field-offset constants (`ETH_DST`, `ARP_SHA`, `IP_SRC`,
`TCP_FLAGS`, etc.) are actually used, exclusively as slice indices/
subslice bounds in the 5 protocol examples. A further check found those
`usize` constants were ALREADY provable before this fix, via `Const_env`
recognizing their bare-`IntLit` initializers directly -- meaning this
refactor's value is single-source-of-truth/drift-prevention against the
packed struct definitions, not fixing broken proofs (those constants were
never broken). `ETH_MAC_LEN`/`ETH_DST_OFF`/`ETH_SRC_OFF` (isize) were kept
as hand-maintained literals rather than converted: they feed
`examples/net_echo/net_echo.tkb`'s raw-pointer/for-loop arithmetic, not a
slice bound, so a `usize`-producing `sizeof`/`offsetof` would only add an
unneeded `as isize` cast for no proof benefit (raw pointers carry no
bounds proof in this language regardless).

**The refactor itself**: every live `usize` constant's bare-literal
initializer was replaced with the matching `offsetof(StructName, field)`
call against `EthHdr`/`ArpHdr`/`Ipv4Hdr`/`TcpHdr`/`IcmpHdr` (the packed
struct definitions already present in the file, previously decorative --
see the "Shared protocol layouts" comment predating this change). The 34
confirmed-dead isize constants were deleted outright, not converted --
matching this project's established practice of removing superseded code
rather than leaving it unreferenced.

**A second, deeper bug found immediately on the first compile attempt, not
assumed away**: `let ETH_DST: usize = offsetof(EthHdr, dst);` failed to
type-check at all, with an error ("cannot pass unproven usize where
{0..<1} is required") that traced to a genuinely different, pre-existing
gap than the one issue #77's compiler fix addressed -- one specific to
GLOBAL initializers, never triggered before because no global initializer
had ever produced a type more refined than its own bare annotation prior
to sizeof/offsetof gaining refined-singleton types. Two distinct problems,
found and fixed in sequence:

1. **Argument order**: `infer_program`'s Pass 2 (global initializer
   checking) called `unify (strip_io ty) et` -- declared annotation FIRST,
   initializer's actual type SECOND -- backwards from the "actual,
   expected" convention every other `unify`/`unify_at` call site in this
   file already follows (e.g. `unify_at e2.loc t2 TIsize`). Because
   `unify`'s `TRefinedInt` rules are directional (refined-into-wider
   succeeds; the reverse hits an anti-subtyping guard meant to catch an
   UNPROVEN base-typed value flowing into a position demanding a refined
   type), the backwards order made `unify TUsize (TRefinedInt (0, 1,
   TUsize))` incorrectly fire that guard -- rejecting a case that is
   actually the opposite of what the guard exists to catch (a PROVEN
   refined value flowing into a permissive plain-type annotation, which
   every TRefinedInt-into-base-type subtyping rule already allows once
   the arguments are the right way round). Fixed by swapping both
   `unify` calls in Pass 2 (the plain-expression case, and the `Var
   vname` cross-global-reference case) to actual-first.

2. **The argument-order fix alone was not sufficient**, confirmed
   empirically rather than assumed: `arp_reply.tkb` progressed past the
   crash but then failed a DIFFERENT check (`ip[IP_SRC..<IP_DST]` produced
   an unproven `[]u8` instead of `[u8; 2..]`). Root cause: fixing the
   `unify` call only stopped Pass 2 from REJECTING the refined initializer
   -- for two already-concrenete, non-`TVar` types, `unify` performs a
   validation with no mutation, so `genv`'s STORED type for `ETH_DST`
   remained the original bare `TUsize` from Pass 1, never upgraded to the
   refined type `unify` had just confirmed was valid. Every later
   consumer of `genv` (Pass 3's function-body inference -- the actual
   mechanism that lets `arp_reply.tkb` prove its subslice bounds -- and
   the final `program_types.globals`) therefore still saw the unrefined
   type. Fixed by restructuring Pass 2 from a plain `List.iter` into a
   `List.fold_left` threading an updated `genv` forward, applying the
   exact same `bind_ty` upgrade rule local lets already use ("proofs are
   only lost at mutation points, never at annotation" -- an immutable
   global's entry is upgraded to its initializer's refined type when the
   annotation's own type exactly matches the refined value's base),
   applied symmetrically to both the plain-expression case and the `Var
   vname` global-aliases-global case.

**Both fixes needed to be found via a REAL compile attempt against REAL
protocol-header code, not anticipated from reading the type_inf.ml diff
in isolation** -- this is the same lesson the original P4a-c migration
waves repeatedly recorded: a refined-type improvement in one place
reliably surfaces latent gaps in adjacent machinery that never had a
reason to be exercised before.

**Verified at every level available**, not just "it type-checks":
- All 6 protocol example files (`arp_reply`, `icmp_echo`, `ip_parse`,
  `tcp_echo`, `tcp_parse`, `http_server`) compile clean under
  `--forbid-trap` with the refactored `netutil.tkb` (zero trap sites,
  same as before the refactor -- confirming no proof was lost, and the
  originally-broken direct/let-threaded sizeof/offsetof cases from the
  first issue #77 fix remain fixed).
- Full `make check` (langcheck, 453 unit tests -- unchanged from the
  compiler-fix commit, confirming this refactor needed no new unit tests
  of its own -- stm32build, all 125 qemutest cases including every live
  protocol test: ARP reply correctness, ICMP checksum validation
  including the deliberately-malformed-checksum rejection case, the full
  TCP handshake/data-echo/close/reconnect cycle, and the HTTP
  request-counter bump) passes with zero regressions -- confirming the
  offsetof()-derived values are BYTE-IDENTICAL to the literals they
  replaced, not just type-compatible.
- `make hwcheck-net` (6 tests: all 5 examples via RAM execution plus
  `http_server`'s genuine Flash boot) re-run on real hardware over the
  actual wired Ethernet link -- all pass, confirming the refactor holds
  under real wire traffic on both execution paths, not just QEMU's
  synthetic dgram transport.

**Files**: `examples/common/netutil.tkb` (34 dead isize constants
deleted; every live usize constant converted to `offsetof(...)`),
`lib/type_inf.ml` (Pass 2 restructured from `List.iter` to a genv
-threading `List.fold_left`; both `unify` calls swapped to actual-first
argument order; the local-let `bind_ty` upgrade rule mirrored for
globals).

### GitHub Issue #55: Lightweight `use "path/to/file.tkb";` File
### Dependencies

**Scoped deliberately narrower than the issue's own long-term framing**,
via an explicit split proposed and agreed before writing any code: the
issue conflates two differently-sized problems -- (A) letting a `.tkb`
file declare its own dependencies so the compiler can compute the correct
file set and catch a missing dependency immediately, and (B) genuine
separate compilation (`.tkb` -> `.o` -> `ld.lld`, C-style), which the
issue's own text names as the eventual goal. Implemented (A) only; (B) is
tracked as a distinct follow-up with its own outlook memo (see the
GitHub issue directly for that memo's full text -- it was written to be
pasted there, not duplicated here).

**Why (A) needed no change to type_inf.ml/llvm_gen.ml at all**: this
project's whole-program compilation model (every file concatenated into
one flat AST, type-checked and codegen'd as a single unit) is exactly
what makes its heaviest machinery possible -- refined-type proofs
threading through `let`/global bindings (see the issue #77 entries
above), `Const_env`'s cross-file constant folding, `sizeof`/`offsetof`
seeing every struct definition. Real separate compilation would need to
either preserve all of that across compilation-unit boundaries (a
metadata/interface-export system, architecturally equivalent in
complexity to what a header file solves, just auto-generated instead of
hand-maintained -- the issue explicitly does not want the maintenance
burden of the hand-maintained kind) or accept a real reduction in proof
power at module boundaries. (A) sidesteps this entirely by leaving the
whole-program model untouched: `use` only changes WHICH files get
concatenated and in WHAT ORDER, decided by the compiler instead of a
human-maintained Makefile list, with every downstream phase unaware
anything changed.

**Syntax**: `use "path/to/file.tkb";`, a plain string literal (not a
Rust-style `mod`/`use path::segments` with an implied namespace tree --
this language has no module/crate namespace concept, and inventing one
was judged out of scope for a "lightweight" feature). The path is
resolved relative to the compiler's own working directory, the same
convention every file already named on the command line uses -- not
relative to the file the `use` appears in, avoiding the need for
per-file relative-path resolution logic.

**Mechanism (`lib/use_resolver.ml`, new module)**: a DFS-based closure
resolution over `use` declarations, run in `bin/main.ml` BEFORE the real
parse-and-concatenate step that already existed. Two phases per file,
run in careful order for a specific reason:
1. `prescan_uses`: a LEX-ONLY scan (calling `Lexer.read` directly, never
   invoking `Parser.program`) for LEADING `use "path";` tokens. Lex-only
   is not an optimization choice -- it is required for correctness:
   `parser.mly`'s grammar actions have ordering-sensitive side effects
   (`Const_env.define_if_literal`, `Type_layout.begin_struct`/
   `finish_struct`/`register_enum`), so a `use`d file's own declarations
   must be FULLY parsed (registering all of those) before the file that
   `use`s it undergoes ITS OWN real parse. A prescan that only tokenizes
   never triggers any of them, keeping this ordering possible.
2. Once a file's own leading `use`s are known, each is resolved
   recursively (dependencies fully processed, including their own
   transitive `use`s) BEFORE the file itself is fully parsed and
   appended to the result list. This produces exactly the "dependencies
   first, dependents last" order every hand-written Makefile file list
   already followed by convention (`COMMON_STM32_UART`/`COMMON_STM32_ETH`
   first, the example's own file last) -- not a style match by
   coincidence, but the same underlying correctness requirement:
   `Const_env`'s "no forward references" constant resolution needs a
   name's defining file to be parsed before anything referencing it.

**Cycles are broken, not rejected**: a file already mid-resolution
(reached again before finishing) is treated as already available rather
than re-entered or reported as an error. Two files whose functions call
each other are an ordinary pattern this project's flat-concatenation
model already supports (function/struct/enum resolution is NOT order
-sensitive, only `Const_env`-recognized constant resolution is) --
requiring a strict DAG would reject working code for no correctness
benefit. Verified directly (`use_resolver_tests`): a two-file mutual
`use` with each file calling the other's function compiles cleanly.

**A genuine, deliberately-chosen silent-failure trap, closed**: since
`prescan_uses` only ever looks at LEADING tokens, a `use` declaration
placed AFTER another item in the same file would type-check and parse
fine as an ordinary (if oddly-placed) `UseDef` item, but would never
actually be seen by the resolver -- silently ineffective, exactly the
class of bug this project's "detect errors at compile time" principle
exists to rule out. `check_uses_are_leading` rejects this outright with a
dedicated error ("`use` declarations must appear before any other item
in the file") rather than accepting it as a harmless no-op.

**Files**: `lib/lexer.mll` (`"use"` keyword -> `USE` token -- a genuine,
deliberately-accepted breaking change: any existing code using `use` as
an identifier now fails to parse; found and fixed exactly one such case,
a test fixture function named `use` unrelated to the feature it was
testing, by renaming it), `lib/parser.mly` (`%token USE`, `USE STRING
SEMI` production), `lib/ast.ml` (`UseDef of string`), `lib/type_inf.ml` +
`lib/llvm_gen.ml` (every exhaustive match over `Ast.toplevel` gained a
`UseDef _` no-op case -- OCaml's compiler flagged every site that needed
one, per this project's usual "compiler-enforced completeness" pattern
for this class of change), `lib/use_resolver.ml` (new), `lib/dune`
(module list), `bin/main.ml` (wires `Use_resolver.resolve` in place of
the old plain `List.concat_map parse_file input_files`), `test/
test_takibi.ml` (2 parser tests, 7 `use_resolver` tests using an
in-memory fake filesystem -- `parse_file`/`prescan` are dependency
-injected specifically so the ordering algorithm is unit-testable
without real files on disk -- plus the one renamed identifier-collision
fixture).

**Verified end-to-end against the real compiler, not just unit tests**:
five scratch scenarios run through the actual `main.exe` binary before
considering this done -- (1) an entry file with a `use` of a second file
defining an array-size constant and a function compiles successfully
with ONLY the entry file named on the command line; (2) the same entry
file with the `use` declaration removed fails immediately with a clear
"not a known compile-time integer constant" error, reproducing the
issue's own motivating scenario (a missing dependency silently breaking
only when something references it) but now caught at the point of
compiling the file itself; (3) a `use` placed after another item fails
with the dedicated leading-use error; (4) two mutually-`use`ing files
compile cleanly (cycle tolerance); (5) a 3-level transitive chain
(A `use`s B, B `use`s C, C defines a constant A needs) resolves
correctly with only A named on the command line. Full `make check`
(langcheck, 462 unit tests -- up from 453, +9 for this feature -- plus
the one renamed fixture, stm32build, all 125 qemutest cases) passes with
zero regressions, confirming every existing Makefile invocation (none of
which use any `use` declarations yet) continues to resolve to exactly
its own command-line file list, unchanged.

**Deliberately not done as part of this feature**: migrating any of the
~40 existing Makefile rules to actually rely on `use` instead of manually
-listed file dependencies. The feature is additive and fully backward
compatible (confirmed above), so this migration is a free-standing,
separately-schedulable follow-up, not a requirement for the feature to
be complete or usable on new code.

### Issue #55 Part (A) Follow-up: Migrating the ~40 Makefile Rules to
### Actually Rely on `use`

The follow-up flagged above. Every example/common `.tkb` file that had a
hand-maintained Makefile dependency now declares that dependency itself
via a leading `use "path/to/file.tkb";`, and the corresponding Makefile
recipes were shrunk to match -- the payoff isn't smaller Makefile text so
much as moving the "which files does X need" fact from a human-maintained
list next to the *build* rule to a machine-checked declaration next to
the *code* that actually needs it, closing exactly the class of drift
this project's own `irq.tkb`/`uart.tkb` incident (see the "No module/
import system" bullet under Known Limitations) was an example of.

**Where each `use` was added, and why each one is safe** (every addition
was checked against the actual Makefile dependency lists via `grep`
before being made, not assumed from memory):
- `examples/common_qemu/print.tkb` / `examples/common_stm32/print.tkb`:
  each now `use`s `examples/common/print.tkb` +
  `examples/common/runtime.tkb` (the old `COMMON_PRINT_BASE` pair) --
  every consumer of either file already needed both unconditionally, in
  that order.
- `examples/common_qemu/virtio_mmio.tkb`: `use`s
  `examples/common_qemu/gic.tkb` -- the driver's own IRQ ack/EOI code
  (`gic.cpu_iar`/`gic.cpu_eoir`) references the `gic` struct directly, so
  every application file that used to need `$(COMMON_GIC)` listed
  alongside `$(COMMON_VIRTIO_MMIO)` in the Makefile (`net_echo`,
  `arp_reply`, `icmp_echo`, `tcp_echo`, `http_server`) gets it
  transitively now, with no per-application `use` needed at all.
- `examples/common_stm32/eth.tkb`: `use`s `examples/common/netutil.tkb`
  (its own `net_read_mac`'s `bytes_copy` call),
  `examples/common_stm32/netconfig.tkb` (`OUR_MAC`), and
  `examples/common_stm32/nvic.tkb` (`enable_eth_irq`) -- the same
  "the driver needs it, not the application" reasoning as virtio_mmio.tkb
  above, closing the equivalent gap on the STM32 side for the same five
  examples.
- `irq.tkb`, `echo.tkb`, `preempt.tkb`, `semaphore.tkb`, `watchdog.tkb`,
  `condvar.tkb`, `msgqueue.tkb`: each `use`s
  `examples/common_qemu/gic.tkb` directly. Unlike virtio_mmio.tkb/eth.tkb
  above, these are the *shared* (both-target) example files themselves,
  and the dependency is genuinely their own: each defines a QEMU-shaped
  interrupt entry point (`irq_dispatch`, or `SysTick_Handler`+
  `pendsv_dispatch` for the scheduler-pattern examples) that references
  the `gic` struct, and this entry point is compiled unconditionally on
  *both* targets (dead code on STM32, matching every other "both entry
  points always defined" example in this codebase) -- confirmed by
  `grep`ping the STM32 recipes, which already listed `$(COMMON_GIC)`
  alongside `$(COMMON_STM32_NVIC)`/`$(COMMON_STM32_SCHEDULER)` for
  exactly this reason, before this migration. `condvar.tkb`/
  `msgqueue.tkb` additionally `use` `examples/common/sync.tkb` (mutex/
  condvar wrappers, pure takibi logic, already reused verbatim on both
  targets).
- `net_echo.tkb`/`arp_reply.tkb`: `use` `examples/common/netutil.tkb`
  only (not gic.tkb -- confirmed via `grep` that their STM32 recipes never
  listed `$(COMMON_GIC)`, unlike the scheduler-pattern group above; the
  GIC dependency lives entirely inside virtio_mmio.tkb, which these files
  don't reference `gic` from directly).
- `icmp_echo.tkb`/`tcp_echo.tkb`/`http_server.tkb`: `use` both
  `examples/common/inet_checksum.tkb` and `examples/common/netutil.tkb`.
- `ip_parse.tkb`/`inet_checksum.tkb` (the example, not the shared file):
  `use` only `examples/common/inet_checksum.tkb` -- neither ever called a
  netutil.tkb function (confirmed by `grep`ping for
  `bytes_eq`/`bytes_copy`/`read_u16be`/etc., all absent), even though the
  old `CHECKSUM_OBJS` Makefile group passed netutil.tkb to all three
  examples in the group uniformly (harmless -- one inert extra file). This
  migration is a genuine (small) precision improvement: `ip_parse.tkb`
  and the `inet_checksum` example no longer pull in a file they never
  used.
- `tcp_parse.tkb`: `use`s both (confirmed via `grep` that it does call
  `read_u16be`/`read_u32be`/`slice_copy`/`write_u16be`).

**What deliberately stays Makefile-curated, and why**: any file with no
single path that's correct for both targets. `uart.tkb`, print.tkb's
per-target half, `timer.tkb`/`scheduler.tkb`, `rtc.tkb`,
`uart_irq_stub.tkb`, and `netconfig.tkb` all have this shape -- a shared
example file that compiles for both targets cannot declare `use
"examples/common_qemu/X.tkb"` without breaking the STM32 build, and vice
versa. `uart_irq_stub.tkb` specifically must NOT be blanket-`use`d from
`irq.tkb`/`echo.tkb` even on the QEMU side alone: STM32's real `uart.tkb`
already defines a real `uart_set_rx_handler()`, and (per the
"Function overloading uses exact parameter types" limitation) two
identically-signed definitions reaching the same compilation unit would
be a genuine conflict on the QEMU side too if uart_irq_stub.tkb's own
no-op ever needed to coexist with a real one -- it stays exactly where it
was, named only in the QEMU-only Makefile recipes.

**A pre-existing, currently-harmless duplicate-definition non-error found
while auditing this** (not changed, only confirmed and documented, since
it's out of scope for this migration and nothing regressed): the STM32
build for `irq`/`preempt`/`semaphore`/`condvar`/`watchdog`/`msgqueue`
compiles BOTH `examples/common_stm32/nvic.tkb`
(or `scheduler.tkb`) AND `examples/common_qemu/gic.tkb` together, and
both files define functions with the exact same name and signature
(`irq_uart_rx_setup`/`irq_uart_rx_unmask`) -- confirmed empirically (not
just by inspection) that this compiles successfully with no duplicate-
definition error, which was surprising given this project's own
documented "exact parameter types" overload model. Whichever
definition's effect actually reaches the final binary was not
independently verified beyond "the STM32 hardware/QEMU test suite
already passes with this exact file combination" (a pre-existing
condition, unrelated to this migration, which only preserves it
unchanged by continuing to pass both files on the STM32 command line).
Worth investigating on its own if a future change ever makes the
distinction observable.

**Two-variable command-line/prerequisite split, applied everywhere in
this migration**: every Makefile recipe touched keeps the now-redundant
file in its PREREQUISITE list (left of the `:`) even though it was
removed from the RECIPE's command line -- Make has no visibility into a
`.tkb` file's own `use` declarations, only into what the Makefile lists
explicitly, so dropping a file from the prerequisite list entirely would
silently break staleness tracking (an edit to, say, `netutil.tkb` would
no longer trigger a rebuild of `icmp_echo.o`). Confirmed concretely, not
just reasoned about: touched `examples/common/netutil.tkb`'s mtime and
ran `make -n`/`make` on `examples/icmp_echo/icmp_echo.o` afterward --
correctly reported and performed exactly one rebuild (using the new,
shorter command line with netutil.tkb no longer named on it), then a
second `make` run on the same target performed no further rebuild
(confirming the earlier one wasn't a fluke of `$(TAKIBI)`'s own
always-checked `dune build` step, which runs on every invocation
regardless but only actually changes `main.exe`'s mtime when the compiled
output changes -- see this file's own Makefile section for that
mechanism).

**Verification**: `make clean && make check` (the fully honest, no-stale-
artifact form, per this project's own established lesson from the
undetermined-for-loop-counter incident) -- langcheck, all 462 unit tests,
stm32build (including the RAM-execution and http_server Flash builds),
and all 125 qemutest cases -- passes with zero regressions. Real STM32/
Ethernet hardware (`make hwcheck`/`make hwcheck-net`) was NOT reachable
in this session's environment (no ST-LINK USB device present), so this
migration is verified end-to-end on the QEMU side only; the change is a
build-dependency reorganization with no compiler or driver logic touched,
and the STM32 RAM/Flash build outputs were confirmed to compile
successfully (`make stm32build`), but a real-hardware UART-diff run is
still recommended before the next `make hwcheck-net` opportunity.

**Files**: `examples/common_qemu/print.tkb`, `examples/common_stm32/
print.tkb`, `examples/common_qemu/virtio_mmio.tkb`, `examples/
common_stm32/eth.tkb`, `examples/irq/irq.tkb`, `examples/echo/echo.tkb`,
`examples/preempt/preempt.tkb`, `examples/semaphore/semaphore.tkb`,
`examples/watchdog/watchdog.tkb`, `examples/condvar/condvar.tkb`,
`examples/msgqueue/msgqueue.tkb`, `examples/net_echo/net_echo.tkb`,
`examples/arp_reply/arp_reply.tkb`, `examples/icmp_echo/icmp_echo.tkb`,
`examples/tcp_echo/tcp_echo.tkb`, `examples/http_server/http_server.tkb`,
`examples/tcp_parse/tcp_parse.tkb`, `examples/ip_parse/ip_parse.tkb`,
`examples/inet_checksum/inet_checksum.tkb`, `Makefile` (variable
definitions and ~20 recipe command lines shrunk, prerequisite lists left
unchanged).

### Issue #79: `--forbid-trap` Applied to Every Example, Both Targets

Before this: only 8 of the 49 examples (`slice`, `foreach`, `http_server`,
`arp_reply`, `icmp_echo`, `ip_parse`, `tcp_echo`, `tcp_parse`) were
actually compiled with `--forbid-trap` (via `run_qemutest.sh`'s
`run_forbid_trap_ok_test`, AArch64/QEMU target only). The other 41 were
only checked by a weaker post-hoc proxy, `run_no_trap_test`: disassemble
the linked `kernel.elf` with `llvm-objdump-19` and require zero `brk`
instructions. This is suggestive but not equivalent to `--forbid-trap` --
it inspects the *final linked binary* after all LLVM optimization passes,
whereas `--forbid-trap` inspects the compiler's own frontend bookkeeping
of which sites needed a trap check at IR-generation time, before any
optimizer gets a chance to (in principle) fold one away. `--forbid-trap`
had also never been applied to the STM32/Cortex-M7 target at all, for any
example.

**Investigation first, then the fix -- and the investigation surfaced a
real gap, not just a formality.** Before touching any example, every
example's *existing* Makefile file list (both targets) was compiled once
with `--forbid-trap` appended, unmodified, purely to see what would
break:
- **QEMU/AArch64 side: all 41 previously-unverified examples passed
  immediately, zero changes needed.** Every bound in the existing
  AArch64-side example suite was already fully proven at the type level;
  the weaker `run_no_trap_test` proxy had not been hiding anything on
  this target.
- **STM32/Cortex-M7 side: all 49 examples failed, all with the identical
  two error sites**, both in `examples/common_stm32/uart.tkb` (a file
  concatenated into literally every STM32 example): `uart_putc`'s
  `uart_tx_buf[head] = c;` (line 104) and `uart_tx_isr`'s
  `*usart1_tdr = uart_tx_buf[tail];` (line 148, at the time). Root cause:
  `uart_tx_head`/`uart_tx_tail` were declared as plain `io usize`
  globals, with every *write* site going through `% 128` (so the ring
  buffer's own invariant -- these two counters only ever hold a value in
  `[0, 128)` -- genuinely always held at runtime) but every *read* site
  (`let head: usize = uart_tx_head;` before indexing) losing that
  invariant, because a plain `usize` global carries no memory of the
  refined range its writers always respect. QEMU's own `uart.tkb` never
  hit this because it has no TX ring buffer at all -- PL011 is written
  synchronously, one register write per byte, no buffering, no index.
  **This is exactly the class of bug `--forbid-trap` exists to catch**:
  correct by construction (a human reading the file can see every write
  is `% 128`), correct in every test run to date (QEMU passing the STM32
  examples' behavioral tests never exercises this at all, and even real
  hardware runs never happened to overflow it), yet not *provably*
  correct until the type itself says so -- exactly the "code with
  remaining bounds checks = code whose type annotations are still
  insufficient" principle from this file's own top section, caught by
  the compiler instead of by luck.
- **The fix was two lines**: `let mut uart_tx_head: io usize;` /
  `let mut uart_tx_tail: io usize;` became
  `let mut uart_tx_head: io {0..<128 as usize};` /
  `let mut uart_tx_tail: io {0..<128 as usize};`. Every write site
  already produced a value in that range (`0` at init, `(x + 1) % 128`
  everywhere else) so no write site needed to change; every read site
  automatically inherited the refined type through the existing
  local-`let`-upgrade rule (the same mechanism issue #77's Pass 2 fix
  relies on), which is what let the two indexing sites prove clean with
  no further changes anywhere. Re-running the same all-49-examples sweep
  with only this two-line fix applied: 49/49 pass under `--forbid-trap`
  on the STM32 target too.

**The fix is applied at the build-system level, not as a parallel check
script.** Once every example (both targets) was confirmed to compile
clean under `--forbid-trap`, `--forbid-trap` was appended directly to
every example-compiling `takibi` invocation in the Makefile (29 recipe
lines: the 9 QEMU-side example object groups, 4 DWARF debug builds, and
16 STM32-side example object rules) via one targeted `sed` pass matching
every `$(TAKIBI) ... -o $@` line (and separately the 4 `-g -o $@` debug
lines), verified afterward by `grep` to confirm exactly the expected 29
lines changed and nothing else (no `$(LLVM_MC)`/`$(LLD)` linking lines
matched the same pattern). This means `make build`/`make stm32build`/
`make check` -- literally every normal build -- now fails immediately,
with an exact file/line list, the moment any example regresses into
having an unproven bounds check, rather than that only being caught by a
separate, optional, easy-to-forget verification pass. This was judged the
right level for this specific guarantee (as opposed to keeping
`--forbid-trap` as an opt-in flag exercised only by dedicated checks):
the project's own stated design principle is "detect errors at compile
time," and folding this into the default build is the most literal
possible realization of that for this specific property, at zero ongoing
cost (no separate script to remember to run, no drift between "what the
build produces" and "what was verified").

**Consequence: the weaker `run_no_trap_test` check is now fully
redundant and was deleted, not just left in place alongside the stronger
one.** If `make check`'s normal build phase already refuses to produce
`kernel.elf` for any example with a remaining trap site, a later
objdump-based re-check of that same binary can only ever pass (skipping
it changes nothing, per this project's YAGNI principle: don't keep
verifying something a step earlier already guarantees). Deleted:
`run_qemutest.sh`'s `run_no_trap_test` function and its 41-example
invocation loop, and the 7 now-redundant `run_forbid_trap_ok_test`
registrations for `slice`/`foreach`/`http_server`/`arp_reply`/
`icmp_echo`/`ip_parse`/`tcp_echo`/`tcp_parse` (the main build already
proves this more strongly, at `make build`/`stm32build` time rather than
only at `qemutest` time). Kept unchanged: `forbid_trap_wrong`/
`forbid_trap_ok`, the two dedicated fixture files (not part of
`EXAMPLES`) that test the `--forbid-trap` flag's OWN correctness --
that a program with a genuine unproven trap is rejected, and that a
provably-clean one is accepted -- independent of which example happens to
exercise it.

**End state matches the target set out in discussion before this work
started**: every example the QEMU/STM32 test suites build is now
verified via exactly one mechanism (`--forbid-trap`, baked into the
default build) rather than a two-tier strong/weak split. The "runtime
brk detection via objdump" category (previously a real, separate check
category) no longer exists anywhere in this repository's test
infrastructure.

**Verification**: `make clean && make check` (langcheck, all 462 unit
tests, stm32build, all QEMU integration/compile-error tests) passes with
70 tests (down from 125 -- the removed 41 `run_no_trap_test` entries and
7 redundant `run_forbid_trap_ok_test` entries account for the
difference; no test was weakened, the coverage they provided is now a
build precondition instead of a separate pass/fail line). Real STM32
hardware (`make hwcheck`/`make hwcheck-net`) was not reachable in this
session's environment (no ST-LINK USB device present); this change only
alters which flag every existing STM32 build already used, so the
existing hardware-verified behavior of every example is unaffected in
principle, but a real-hardware confirmation run is still recommended
before the next opportunity, consistent with this project's own standard
for STM32/Ethernet-touching changes.

**Files**: `examples/common_stm32/uart.tkb` (the actual bug fix -- two
global declarations refined from `io usize` to
`io {0..<128 as usize}`), `Makefile` (`--forbid-trap` appended to 29
`takibi` invocation lines), `scripts/run_qemutest.sh` (`run_no_trap_test`
function and its invocation loop deleted; 7 redundant
`run_forbid_trap_ok_test` registrations deleted).

### Issue #72: Scoped Refinement-Type-Inference for Bare Casts

The ask was framed as "type inference for refinement types" in general,
which is a research-scale problem (Liquid Haskell/F*-class systems still
require explicit function-boundary annotations; full inference of
refinement types across function boundaries without them is undecidable
in general, not just hard to implement here). Rather than attempt that,
this was scoped down the same way issue #55 was (Part A/B split): audit
the ACTUAL annotation burden in `examples/` first, then implement only
the piece the data justified.

**The audit** (before writing any inference code): grepped every
`{lo..<hi as base}` occurrence across `examples/` (86 `.tkb` files total,
14 containing at least one, 52 real code occurrences after excluding
comments). Classified into three buckets:
1. **Function/global boundary declarations** (~16): parameter types,
   return types, `io`-qualified globals -- e.g. `ihl: {20..<21 as u16}`,
   repeated identically 8 times across 5 files, and `uart_tx_head`/
   `uart_tx_tail`'s newly-refined globals from the issue #79 work just
   above. Left untouched -- these are exactly the boundary annotations no
   known refinement-type system escapes either.
2. **Literal-only local `let` annotations** (~6): mostly in dedicated
   demo/fixture files (`refined.tkb`, the `refined_*_mismatch` compiler-
   feature fixtures) -- low real burden, mostly pedagogical.
3. **Bridge casts restating an ALREADY-known range across a base change**
   (~29, roughly HALF of every occurrence in the whole tree): `ihl as
   {20..<21 as usize}` (8x, always identical), `len_n as {NN..<1515 as
   u16}` (3x), `n as {0..<NNN as usize}` (2x), `tcp_len`/`data_off`/
   `data_len as {...}` (5x), `max(min(x,N),0) as {0..<N+1 as usize}` (2x,
   eth.tkb/virtio_mmio.tkb), `(doff * 4) as {20..<61 as u16}` (2x,
   initially assumed to need extra external narrowing beyond what Mul
   propagation proves -- rechecked by hand and confirmed the u8-based Mul
   result, {5..<16}*4, already IS exactly {20..<61}; the explicit cast
   was pure base-conversion after all, no different from the others),
   plus a few one-offs in `ip_parse.tkb`/`narrow.tkb`/`refined.tkb`/
   `tcp_parse.tkb`. Every one of these has the same shape: the cast's
   SOURCE already has a compiler-known range (via if-narrowing, an
   exact-match refined parameter, or arithmetic propagation), and the
   only thing the explicit `{lo..<hi as base}` is doing is restating that
   range in a different base -- a purely mechanical, LOCAL fact the
   compiler already has in hand, not a boundary/generalization problem.

**Scope decision**: implement inference for bucket 3 only, leave buckets
1 and 2 exactly as they are today. This is local (never crosses a
function signature), needs no SMT/constraint solver, and reuses existing
range-propagation machinery verbatim -- explicitly NOT the general
"never write a refinement type" goal the issue's title suggested, which
would have been the same kind of open-ended, YAGNI-violating scope issue
#55 was split away from.

**Design**: a bare cast `x as <base>` (target_ty syntactically a plain
integer base name, not an explicit `{lo..<hi as base}`) now infers
`{lo..<hi as base}` automatically whenever `x`'s current type is already
`TRefinedInt(lo, hi, _)` and `[lo, hi)` fits `<base>`'s native
representable range. A cast that does NOT fit (a genuine narrowing/
truncating cast, e.g. `{0..<1481}` into `u8`) is completely unaffected --
falls through to exactly today's plain-unrefined-target behavior, silent
truncation, no error, no change in generated code.

**Implementation touches both passes independently, matching this
project's established sizeof/offsetof-style "computed twice, must
agree" discipline** -- confirmed by direct investigation that
type_inf.ml and llvm_gen.ml are genuinely separate AST walks that do NOT
share inferred-type state through the AST itself (llvm_gen.ml re-derives
what it needs, e.g. `narrowing_ctx` is populated entirely inside
llvm_gen.ml's own walk, never by type_inf.ml), so a fix needed in only
one pass would silently fail to help (or silently break --forbid-trap
soundness in) the other:
- `type_inf.ml`'s `Cast` case (the final `TRefinedInt (lo, hi, _)` arm on
  `repr src_ty`, inside the existing `None, None` / non-enum branch):
  when `tgt` (from `of_ast target_ty`) is one of the plain integer base
  variants (never true when target_ty was already an explicit
  `TypeRefined`, since then `tgt` is already a `TRefinedInt`, so this
  never double-wraps), `try unify src_ty tgt` -- reusing `unify`'s
  existing `TRefinedInt`-into-bare-base subtyping arms as the single
  source of truth for "does this range fit", rather than re-deriving a
  second copy of that logic that could drift -- and returns
  `TRefinedInt (lo, hi, tgt)` on success, or falls back to plain `tgt` on
  `Unify_error` (an intentional narrowing cast, left exactly as before).
- `llvm_gen.ml`'s `Cast` case: right after `src_ty` is computed (with its
  existing `narrowing_ctx` substitution for a bare `Var` source, already
  needed for the pre-existing explicit-refined-cast path), `target_ty` is
  rewritten in place -- from a bare `TypeI8..TypeUsize` to
  `TypeRefined (lo, hi, target_ty)` -- whenever `src_ty` is already
  `TypeRefined` and the range fits (a small local `fits` predicate,
  hand-mirrored from types.ml's `unify` subtyping arms with a comment
  cross-referencing them so a future change to one is easy to notice
  needs the other updated too). This is the ONLY change needed in
  llvm_gen.ml: once `target_ty` has this shape, the EXISTING
  `TypeRefined (lo, hi, _) -> ...` branch (already there for an
  explicitly-written `{lo..<hi as base}` cast) handles everything else
  unchanged, including its own "proven -> no runtime check" logic --
  confirming the rewrite is a pure upstream massage, not a new code path.

**Verified empirically at each step, not just by code review**: a
standalone if-narrowed bare cast (`buf[v as usize]` with `v` narrowed by
`if (v >= 0 && v < 8)`) compiles clean under `--forbid-trap` with no
explicit range; a bare cast whose source has NO known range still
requires a runtime check under `--forbid-trap` (rejected, as before,
confirming the feature doesn't invent proofs from nothing); a bare cast
whose source range doesn't fit the target base (`{0..<1481}` into `u8`)
still compiles as a plain silent-truncating cast with no explicit range
needed and no runtime check added (confirming the feature never
regresses today's narrowing-cast behavior either).

**All ~27 real bridge-cast occurrences in `examples/` were then actually
rewritten** to the bare form, as the concrete deliverable proving the
inference works against real code, not just synthetic test snippets:
`icmp_echo.tkb`, `tcp_echo.tkb`, `http_server.tkb`, `tcp_parse.tkb`,
`ip_parse.tkb`, `common_stm32/eth.tkb`, `common_qemu/virtio_mmio.tkb`
all dropped their explicit `{lo..<hi as base}` ranges in favor of `as
<base>`. `narrow.tkb` and `refined.tkb` (dedicated pedagogical demos
whose whole point was showing this exact manual-cast idiom) had their
comments rewritten to explain that the bridge is now free to WRITE, not
just free to RUN -- while Approach 1's genuinely-boundary annotations
(`fill_pair(i: {0..<7 as usize}, ...)`) stayed untouched, since those
demonstrate exactly the case this feature deliberately does not
automate. `http_server.tkb`/`tcp_echo.tkb` also had a stale inline
comment corrected: it used to say a plain `as u16` on the Mul-derived
`doff * 4` "would silently discard the range... reintroducing a trap
site" -- true before this feature, false after, rewritten to explain
both states rather than leaving a comment that now reads as flatly
wrong.

**5 new unit tests** lock in the feature at the codegen level
(`test/test_takibi.ml`, `expect_trap_sites`): the exact-match-parameter
bridge, the if-narrowed-value bridge, the Mul-derived-narrower-than-
native-range bridge (the `doff * 4` case, confirmed by hand-checking the
arithmetic that {5..<16}(u8) * 4 already IS exactly {20..<61}, not the
{20..<64} first assumed from a too-hasty read of the file's own old
comment), and two negative controls (source range doesn't fit the target
base; source has no known range at all) confirming the feature only ever
WIDENS what a cast can prove, never invents unsound proofs and never
silently changes narrowing-cast semantics.

**Verification**: `make clean && make check` (langcheck, 467 unit tests
-- up from 462, +5 for this feature -- stm32build, all 70 QEMU
integration/compile-error tests, all under the issue #79 `--forbid-trap`
-baked-into-every-build regime from immediately before this issue) passes
with zero regressions, confirming all ~27 rewritten examples still prove
fully trap-free on both targets with the shorter syntax.

**Issue #72 is considered closed by this work** -- scoped to exactly
bucket 3 above, per explicit agreement before implementation started;
buckets 1 and 2 (function-boundary annotations) are a deliberate,
permanent design boundary, not a follow-up.

**Files**: `lib/type_inf.ml` (`Cast` case, new `TRefinedInt` arm),
`lib/llvm_gen.ml` (`Cast` case, `target_ty` rewrite before the existing
dispatch), `test/test_takibi.ml` (5 new codegen tests), `examples/
icmp_echo/icmp_echo.tkb`, `examples/tcp_echo/tcp_echo.tkb`, `examples/
http_server/http_server.tkb`, `examples/tcp_parse/tcp_parse.tkb`,
`examples/ip_parse/ip_parse.tkb`, `examples/common_stm32/eth.tkb`,
`examples/common_qemu/virtio_mmio.tkb`, `examples/narrow/narrow.tkb`,
`examples/refined/refined.tkb` (comments + bridge-cast rewrites).

### Issue #79 Follow-up: Cross-File Duplicate Function Definitions Are Now a Compile Error

Flagged during the session-end review of issue #55's Makefile migration
work (not something either issue's own verification had caught): the
STM32 build for `irq`/`echo` compiles BOTH `examples/common_qemu/
gic.tkb` and `examples/common_stm32/nvic.tkb`, and both files define
`irq_uart_rx_setup()`/`irq_uart_rx_unmask()` under the exact same name
and signature -- yet this compiled with zero error, which was surprising
given this project's own documented "Function overloading uses exact
parameter types" model.

**Root cause, found by reading the actual codegen path, not guessed**:
two independent effects compound into "whichever definition comes first
in file-concatenation order silently wins, the other is silently dead-
coded, no verifier error":
1. `type_inf.ml`'s `register_definition` DOES have a "duplicate" guard,
   but it only fires `when previous = file` -- i.e. it only catches
   copy-pasting the same function twice in ONE file, never two
   definitions from two DIFFERENT files.
2. `llvm_gen.ml`'s `declare_func` (Pass 1) only adds an llvalue to the
   `functions` table `if not (Hashtbl.mem functions key)` -- so only the
   FIRST FuncDef with a given key is ever declared. `gen_func` (Pass 2)
   has no equivalent guard: it runs unconditionally for EVERY FuncDef,
   looks up the SAME (single) llvalue via `Hashtbl.find_opt functions
   key`, and unconditionally `append_block`s a fresh "entry" block into
   it. The result is a function with the FIRST definition's blocks (the
   real, reachable ones, since they're linked from the actual entry
   block) followed by the SECOND definition's blocks (present in the IR,
   but unreachable -- nothing branches into them, so they're either dead
   or optimized away) -- valid LLVM IR, so `Llvm_analysis.verify_function`
   never complains.

Confirmed empirically, not just reasoned about: compiled `examples/irq/
irq.tkb` for STM32 with `nvic.tkb` + `gic.tkb` both present (matching the
actual Makefile file list before this fix) and disassembled the
`irq_uart_rx_setup` symbol -- only `nvic.tkb`'s single-`bl`-to-
`enable_usart1_irq` body was present; `gic.tkb`'s `gic_init`/
`gic_enable_uart_spi` calls were entirely absent from that symbol (though
still present as their OWN separate symbols in the object, since other
code paths reference them). This happened to be CORRECT on this specific
build only because `nvic.tkb` happens to come before `gic.tkb` in file-
concatenation order (confirmed this ordering predates issue #55's
migration -- the original Makefile line already listed
`$(COMMON_STM32_NVIC) $(COMMON_GIC)` in that order, so issue #55 didn't
introduce this, only inherited it) -- a hand-maintained ordering
coincidence, not a compiler guarantee. A future reordering (a `use`
resolution change, a Makefile edit) could silently flip which
definition wins, with no compile error and no test catching it short of
a real-hardware UART-interrupt test actually exercising the wrong path.

**Agreed with the user's assessment: this should be a hard compile
error, full stop** -- this is squarely the "Detect Errors at Compile
Time" principle from this file's own top section applied to the
compiler's own internals, not just user code. Silently keeping one of
two conflicting definitions by accident of file order, with the other
dead-coded and invisible, is exactly the kind of landmine that
principle exists to eliminate.

**Fix**: `type_inf.ml`'s `register_definition` now raises whenever a
SECOND definition with the same overload key is registered, regardless
of which file it came from -- same-file duplicates keep the existing
`"duplicate overload '%s'"` message; cross-file duplicates get a new
`"duplicate definition of '%s': already defined in %s"` message naming
the first file. Since `type_inf.ml`'s `infer_program` runs to completion
(and any `TypeError` aborts) before `llvm_gen.ml`'s `gen_program` is ever
called (confirmed via `bin/main.ml`'s pipeline), this alone is sufficient
-- no change needed in `llvm_gen.ml`'s declare/gen_func pair itself, since
codegen is simply never reached once the duplicate is caught earlier.

**Fixing the actual collision, not just tightening the check**: rebuilding
with the stricter check surfaced exactly the two files predicted --
`examples/irq/irq.tkb` and `examples/echo/echo.tkb` -- and no others (the
other five scheduler-pattern shared files, `preempt`/`semaphore`/
`watchdog`/`condvar`/`msgqueue`, use `examples/common_stm32/scheduler.tkb`
on STM32, not `nvic.tkb`, and `scheduler.tkb` defines no colliding
names, so `use`ing full `gic.tkb` unconditionally remains correct and
necessary for them -- their QEMU build genuinely needs gic.tkb's real
functions too, indirectly via `examples/common_qemu/timer.tkb`'s own
`gic_init()`/`gic_enable_timer_ppi()` calls). Split
`examples/common_qemu/gic.tkb` into two files:
- **`examples/common_qemu/gic_regs.tkb`** (new): just the `GicRegs`
  struct and the `gic` global -- the part `irq.tkb`/`echo.tkb`'s own
  dead-on-STM32 `irq_dispatch` needs for its `gic.cpu_iar`/`gic.cpu_eoir`
  references to type-check, with no functions to collide with anything.
- **`gic.tkb`** itself: now `use`s `gic_regs.tkb` for the struct/global,
  keeps its actual functions (`gic_init`, `gic_enable_timer_ppi`,
  `gic_enable_uart_spi`, `irq_uart_rx_setup`, `irq_uart_rx_unmask`)
  unchanged. Still the right thing for the five scheduler-pattern files
  and `virtio_mmio.tkb` (QEMU-only, no collision risk at all since it's
  never compiled for STM32) to `use` in full.

`irq.tkb`/`echo.tkb` now `use "examples/common_qemu/gic_regs.tkb";`
instead of full `gic.tkb`. Their QEMU-side Makefile recipes gained
`$(COMMON_GIC)` back on the actual command line (no longer reachable
transitively through their own `use`, since that now only pulls in the
struct); their STM32-side recipes' prerequisite changed from
`$(COMMON_GIC)` to the new `$(COMMON_GIC_REGS)` (all the STM32 build
ever needed).

**Verified the fix resolves ambiguity, not just silences the error**:
same disassembly check as above, re-run after the split -- STM32's
`irq_uart_rx_setup` object now contains ONLY `nvic.tkb`'s body, and
`gic_init`/`gic_enable_uart_spi` don't appear anywhere in that object at
all (not present, not just dead) -- STM32 genuinely never sees gic.tkb's
functions anymore, not "wins by luck of ordering." The QEMU-side object
was checked the same way -- contains `gic_init`/`gic_enable_timer_ppi`/
`gic_enable_uart_spi`/`irq_uart_rx_setup`/`irq_uart_rx_unmask` (gic.tkb's
real functions, still reachable via the explicit Makefile command-line
argument), with no `nvic.tkb` symbols at all (STM32-only, never part of
the QEMU build).

**2 new unit tests** (`test/test_takibi.ml`, using a new `infer_files`
helper that parses multiple sources under distinct `Lexing.set_filename`
values and concatenates them, mirroring how `use`/multi-file compilation
actually produces one flat AST): confirms two DIFFERENT files defining
the identical signature under the same name is now rejected (mentioning
the first file and "duplicate definition"), and confirms a genuinely
different-signature overload split across two files is NOT a false
positive (still type-checks as a valid overload set).

**Verification**: `make clean && make check` (langcheck, 470 unit tests
-- up from 468, +2 for this fix -- stm32build, all 70 QEMU integration/
compile-error tests) passes with zero regressions. Real STM32 hardware
(`make hwcheck`) was not reachable in this session's environment; the
disassembly-level verification above (confirming which functions
literally appear in each object file) is strong evidence but is not a
substitute for an actual UART-interrupt hardware test of `irq`/`echo` --
recommended before the next `make hwcheck` opportunity, same standing
recommendation as issue #79's own STM32 rollout.

**Follow-up not done here, flagged for a future session**: this fix
only closes the gap for FUNCTION definitions (`register_definition`'s
own scope). Whether an equivalent gap exists for GLOBAL `let`
declarations (two files declaring the same-named global) was not
audited -- worth a similar investigation if it comes up.

**Files**: `lib/type_inf.ml` (`register_definition`, same-file guard
widened to any file), `examples/common_qemu/gic_regs.tkb` (new),
`examples/common_qemu/gic.tkb` (now `use`s gic_regs.tkb), `examples/irq/
irq.tkb`, `examples/echo/echo.tkb` (now `use` gic_regs.tkb instead of
full gic.tkb), `Makefile` (`COMMON_GIC_REGS` added; IRQ_OBJS/GETC_OBJS
QEMU recipes get `$(COMMON_GIC)` back on their command line;
`irq_stm32.o`/`echo_stm32.o` prerequisites switched to
`$(COMMON_GIC_REGS)`), `test/test_takibi.ml` (`infer_files` helper, 2
new tests).

### Issue #79 Follow-up, Continued: Duplicate Global `let` Declarations

Immediately after the function-duplicate fix above, checked whether the
same gap existed for global `let` declarations -- it did, and broke
differently. `type_inf.ml`'s `genv`-building fold did `StringMap.add name
... m` unconditionally, no duplicate check at all (not even a same-file
one, unlike `register_definition`'s partial guard for functions).
Confirmed with a throwaway two-`let` example
(`let mut counter: i32 = 1; let mut counter: i32 = 2;`) and a
disassembly, not just read from the code: unlike the function case (one
llvalue, second definition's blocks silently unreachable),
`llvm_gen.ml`'s `Hashtbl.add global_vars` (also non-overwriting) plus
LLVM's own `define_global` auto-renaming a second same-named global to
`"name.1"` at the module level meant the two initializers landed in
**two separate, real globals** -- `counter` (value 1) sitting in the
binary completely unread, `counter.1` (value 2) the one every read/write
in the program actually resolved to via `Hashtbl.find`'s "most recently
added wins" lookup semantics. Same underlying category of bug (silent
tolerance where a compile error belongs), different concrete failure
mode.

**Fix**: a `Hashtbl.create`-backed `seen_globals` set in the `genv` fold,
raising `TypeError (Lexing.dummy_pos, "duplicate global '%s'")` on a
second `LetDef` for the same name. `Lexing.dummy_pos` (no real line/
column) is a deliberate match to the existing convention, not a
shortcut: `Ast.toplevel` has no `{ desc; loc }` wrapper the way
`expr`/`stmt` do (only `FuncDef` carries a location, via `func.def_loc`),
so `LetDef`/`ExternFuncDef` genuinely have no position to report --
`ExternFuncDef`'s own pre-existing "cannot be overloaded" error already
uses the identical `dummy_pos` convention, confirmed side-by-side (both
print `File "", line 0, character 0: ...`) rather than assumed to match.
Adding a real location to `LetDef` (touching `ast.ml`, `parser.mly`, and
every one of the ~7 pattern-match sites across `type_inf.ml`/
`llvm_gen.ml`) was considered and set aside as disproportionate scope for
what this fix needs -- YAGNI: the error firing correctly and naming the
duplicate is the actual requirement, and matching an already-accepted
lesser precedent (`ExternFuncDef`) rather than introducing new AST
capability nothing else uses.

**This one WAS live in real example code, not just latent**: rebuilding
surfaced `examples/tcp_echo/tcp_echo.tkb` and `examples/http_server/
http_server.tkb`, both with a `duplicate global 'IP_TOTAL_LEN'`/
`'ARP_HTYPE'` error. Root cause: both files hand-declared their own
`IP_TOTAL_LEN`/`IP_TTL`/.../`TCP_URGENT` (and `http_server.tkb` also
`ARP_HTYPE`/.../`ARP_TPA`) offset constants with hardcoded literal
values -- silently redundant with `examples/common/netutil.tkb`'s own
`offsetof(Ipv4Hdr/TcpHdr/ArpHdr, field)`-based versions of the exact same
names ever since GitHub issue #77's offsetof refactor added those to
netutil.tkb (both files already `use netutil.tkb`, inherited from the
issue #55 Makefile migration). Nothing else in `examples/` had this
pattern (`icmp_echo.tkb`/`tcp_parse.tkb`/`ip_parse.tkb` -- also
`netutil.tkb` consumers -- never redeclared their own copies). Fixed by
deleting the two files' entire redundant offset-constant blocks, relying
on `netutil.tkb`'s canonical versions instead (a pure deduplication --
same values, confirmed by the full `tcp_echo`/`http_server` QEMU test
suites, including the real TCP handshake/data-echo/close cycle and HTTP
request/response cycle, passing byte-identically afterward).

**A third, adjacent case was found but deliberately NOT fixed this
session**: a global `let` and a `fn` sharing a name (e.g. `let mut foo:
i32 = 1; fn foo() {}`) also compiles with no error today. Checked what
actually happens at the object level (not assumed): LLVM auto-renames
the function to `foo.1` (no raw symbol collision, unlike a naive guess),
but the source-level name `foo` becomes ambiguous/confusing regardless.
This lives in a different namespace/fold (`fenv` vs `genv`) than either
fix above, so closing it would need a shared cross-namespace name
registry, not a small extension of either existing check -- flagged for
a future session rather than expanded into scope here mid-session.

**Verification**: `make clean && make check` (langcheck, 472 unit tests
-- up from 470, +2 for this fix -- stm32build, all 70 QEMU integration/
compile-error tests, including the full `tcp_echo`/`http_server`
protocol test suites re-verifying the netutil.tkb-only constants produce
identical wire behavior) passes with zero regressions.

**Files**: `lib/type_inf.ml` (`genv` fold, `seen_globals` duplicate
check), `examples/tcp_echo/tcp_echo.tkb`, `examples/http_server/
http_server.tkb` (redundant offset-constant blocks deleted),
`test/test_takibi.ml` (2 new tests).

### Issue #79 Follow-up, Continued Again: One Flat Namespace for Functions and Globals

The third case flagged (deliberately left open) at the end of the two
fixes above: a global `let` and a `fn` sharing a name (e.g. `let mut foo:
i32 = 1; fn foo() {}`) also compiled with no error. Discussed with the
user before fixing rather than assumed: should takibi have separate
namespaces for functions and variables (as some languages do), or one
flat namespace? Agreed on one flat namespace, deliberately -- takibi
already behaves like C here in every other respect (globals are all
static storage, one flat top-level symbol space), and C itself has no
separate function/variable namespace either (`int foo; void foo();` is a
real conflict there too). A genuine module/namespace system is
explicitly out of scope until (if ever) actually needed -- YAGNI, per
this file's own top-level design principle -- not designed for
speculatively now.

**Fix**: `genv`'s fold (already carrying the `seen_globals` duplicate
check from the entry just above) also checks `StringMap.mem name fenv`
for each `LetDef` and raises `"'%s' is already defined as a function"`
if found. This catches BOTH orderings (`let` after `fn`, and `fn` after
`let`) with the same single check, because `fenv` is fully built (every
`FuncDef`/`ExternFuncDef` in the whole program processed) before `genv`'s
fold ever starts -- so by the time any `LetDef` is examined, `fenv`
already reflects the complete function set regardless of which line
came first in source order. Confirmed both orderings are rejected with
two standalone throwaway examples before writing the corresponding unit
tests, not assumed from reading the fold order alone.

**Verification**: `make clean && make check` (langcheck, 474 unit tests
-- up from 472, +2 for this fix -- stm32build, all 70 QEMU integration/
compile-error tests) passes with zero regressions; no existing example
anywhere in the tree has a function/global name collision, so this was a
purely latent gap, not something already lurking in `examples/` the way
the previous two checks in this session's follow-up turned out to be.

**Files**: `lib/type_inf.ml` (`genv` fold, `fenv` cross-check added
alongside the existing `seen_globals` check), `test/test_takibi.ml` (2
new tests, one per ordering).

### Issue #79 Follow-up, Consolidated: `claim_toplevel_name`, One Mechanism for the Whole Family

Immediately after landing the three checks above (function/function,
global/global, function/global), verified whether the same gap existed
for `struct`/`enum`/`opaque struct` too -- it did, confirmed empirically
with throwaway examples for each combination (struct/struct, enum/enum,
struct/fn) before writing any fix, not assumed from the shape of the
earlier three bugs. Reported this to the user as a "next session"
finding; the user asked to close it in the same session instead, and
confirmed the design direction: ONE flat namespace for every GLOBAL
definition (matching C, which the project already resembles in every
other respect -- all globals are static storage, one flat top-level
symbol space), deliberately leaving how LOCAL (function-body-scoped)
definitions should be namespaced as an open question -- moot for now,
since takibi has no local `struct`/`enum`/`fn` definitions today, only
local `let`/`let mut` bindings.

**Discussed C/Rust/Zig for context before implementing** (user asked
specifically): C actually has a TAG namespace separate from the
"ordinary identifier" namespace (`struct Foo` needs the `struct` keyword
to reach the tag; `typedef struct Foo Foo;` is the common idiom for
aliasing the tag into the ordinary-identifier namespace so the keyword
can be dropped) -- takibi does NOT replicate this split; a struct name
and a function name share the space, no keyword needed to disambiguate.
Rust has a genuinely separate TYPE namespace (struct/enum/trait/type
alias/module) from the VALUE namespace (fn/static/const/let), which is
why `struct Foo; fn Foo() {}` is legal Rust. Zig is the closest existing
analogue to what was just built here: types are ordinary compile-time
values bound via the same `const`/`var` mechanism as everything else
(`const Foo = struct {...};`), so Zig has one flat identifier namespace
per scope with no type/value split at all -- and, separately but
relatedly, Zig explicitly DISALLOWS shadowing an outer-scope identifier
in an inner scope (a deliberate safety choice, not a limitation), unlike
C/Rust's permissive shadowing.

**Consolidation, not just an N-th one-off check**: rather than bolt a
fourth and fifth ad-hoc `Hashtbl` onto `senv`'s and `eenv`'s own build
folds (mirroring how the function and global checks were each added
separately), the two existing checks (the same-file-only `fenv`
`register_definition` guard, and `genv`'s own `seen_globals` +
`StringMap.mem name fenv` check) were replaced with ONE shared mechanism:
`claim_toplevel_name`, a single `(string, string) Hashtbl.t` mapping
name to a human-readable kind string ("function"/"global"/"struct"/
"enum"), populated by ONE self-contained pass over the whole program
run at the very top of `infer_program`, before `senv`/`eenv`/`fenv`/
`genv` exist at all. Functions are the one special case threaded through
it: two functions sharing a name is fine ON ITS OWN (a valid overload,
or a genuine duplicate signature -- both still handled by
`register_definition`/`fenv`'s existing signature-aware logic
unchanged, further down); `claim_toplevel_name` only rejects a function
name colliding with a NON-function kind, or two non-function kinds
colliding with each other or themselves. `genv`'s own fold had its now-
redundant `seen_globals`/`fenv`-membership check removed accordingly --
every name reaching that fold is already known globally unique by the
time it runs.

**Opaque structs share the struct namespace, deliberately**: `struct
Foo {...}` and `opaque struct Foo;` are treated as the same kind
("struct") for this check, so they collide with each other exactly like
two concrete structs would -- confirmed with a dedicated test, since
this project has no forward-declare-then-define pattern for opaque
structs (they exist specifically for permanently-incomplete types used
only behind a pointer, never later completed), so there was no
legitimate use case to preserve by keeping them separate.

**Verification**: `make clean && make check` (langcheck, 479 unit tests
-- up from 474, +5 for the new struct/enum/cross-kind coverage, 2 of the
earlier fn/global tests updated in place since their expected message
text changed from the ad-hoc wording to the new unified "already defined
as a <kind>" phrasing -- stm32build, all 70 QEMU integration/compile-
error tests) passes with zero regressions. No existing example anywhere
in the tree has a struct/enum/opaque-struct name collision (unlike the
earlier two checks in this follow-up, which both found real bugs in
`examples/`) -- this one was purely latent.

**Files**: `lib/type_inf.ml` (`claim_toplevel_name` + the single pass at
the top of `infer_program`; `genv`'s fold simplified back down, its
redundant checks removed), `test/test_takibi.ml` (2 existing tests'
expected message text updated, 5 new tests for the struct/enum/cross-
kind combinations).

### GitHub Issue #61: `fatfs` -- FAT12 on an In-Memory Block Device, Then on the Real STM32 Board

New example, `examples/fatfs/fatfs.tkb`: a from-scratch FAT12 filesystem
driver, deliberately built and verified against an in-memory block device
(no real SD/eMMC hardware, that's the separate, deferred issue #62) before
any real storage hardware exists -- discussed and agreed with the user on
the issue itself before starting: bringing up the filesystem logic and the
SD card's SPI/SDIO timing at the same time would make failures hard to
attribute to either one, the same reasoning that put `ip_parse`/`tcp_parse`
before `icmp_echo`/`tcp_echo` earlier in this project's history.

**New durable process, established mid-session, not just for this
feature**: this work is what prompted `CLAUDE.md`'s "Development Process:
Prove New `.tkb` Code Without `--forbid-trap` First, Then Turn It On"
section -- write and fully verify new `.tkb` work with plain checked
array/slice indexing and ordinary unrefined types first (no raw pointers
used just to dodge a bounds check, no `--forbid-trap`), commit that as a
known-good baseline, and only turn refinement types/`--forbid-trap` on
once the *whole milestone* (`fatfs` + real SD card) works end to end. The
first draft of this file actually *did* reach directly for raw-pointer
arithmetic everywhere specifically to make `--forbid-trap` pass trivially
-- the user caught this immediately ("that's not in the spirit of what I
asked for") and had it rewritten to plain checked-array indexing before
continuing; see that `CLAUDE.md` section for the full rule and reasoning,
including the literal-only restriction on `{lo..<hi as base}` bounds that
made some of the checked-array rewrite awkward (documented properly in
`SPEC.md` afterward too, see below).

**FAT12 core** (`examples/fatfs/fatfs.tkb`): `mem_block_read`/
`mem_block_write` are the swappable block-device boundary the issue asked
for (only these two need a different implementation once issue #62 wires
up real SD/eMMC hardware); everything else operates on `disk` (a global
`[u8; SECTOR_SIZE * TOTAL_SECTORS]`, currently a 64KB placeholder disk)
only through them. `Fat12BootSector`/`DirEntry` are `struct packed`
overlays (same `sector_buf as *Fat12BootSector`-style cast
`examples/common_qemu/virtio_mmio.tkb` already uses for its own
descriptor rings) with plain `u16`/`u32` fields, not `[u8;N]` + explicit
endian helpers like the network protocol structs in
`examples/common/netutil.tkb` -- FAT12 is little-endian on disk and this
target is little-endian, so a plain scalar field's native store already
produces the correct bytes (same argument already used for
`VirtqDesc`/`VirtqAvail`). `fat_get_entry`/`fat_set_entry` handle FAT12's
one genuinely fiddly piece (two 12-bit entries packed into 3 bytes).
`root_dir_buf` is a checked `[DirEntry; ROOT_ENTRY_COUNT]` array (not a
byte buffer + a `*DirEntry` overlay cast) so indexing an entry by slot
number is a real, checked array access, only reinterpreted as raw bytes at
the `mem_block_write` boundary.

**Public API tracks elm-chan's FatFs (https://elm-chan.org/fsw/ff/)
Application Interface naming, `fat_` prefix instead of `f_`** -- the
user's explicit request, driven by the concrete next milestone
(`http_server_sdcard`, combining `fatfs` with `http_server` to serve files
from an SD card; the further-out "ultimate demo" goal is a Forth
interpreter on STM32 with its REPL exposed through that same HTTP server,
letting a browser user freely read/write files and directories -- explicitly
scoped OUT of this issue, a separate not-yet-started milestone). Scope was
deliberately kept to exactly what `http_server_sdcard` needs and no more
(discussed and agreed as a YAGNI call): a flat root directory only, no
subdirectories/seek/rename/unlink/multiple-open-files. The original
one-shot `fat_create_file(name, data, len)` (needs the whole content and
length up front) was replaced with a real file-handle API --
`struct FatFile` (`dir_index`, `start_cluster`, `cur_cluster`,
`pos_in_cluster`, `fptr`, `fsize`, `writing`) plus `fat_open`/`fat_read`/
`fat_write`/`fat_close`/`fat_find_entry`, `FA_READ`/`FA_WRITE`/
`FA_CREATE_ALWAYS` mode flags -- `fat_write` allocates clusters lazily and
chains them as needed instead of computing the whole chain up front,
closer to what a streamed HTTP response body or a Forth REPL would
actually need later.

**Verification is three-way, not just "does it compile"**: real
`mformat`/`mcopy` write a seed image, `fatfs.tkb`'s own
`fat_open`(`FA_READ`)/`fat_read` reads it back (loaded into `disk` via a
new ARM semihosting `SYS_READ` stub, `semihosting_read`, added to
`examples/common_qemu/semihosting_asm.S` alongside the existing
`SYS_OPEN`/`SYS_WRITE`/`SYS_CLOSE` stubs); `fatfs.tkb` creates/writes two
files and reads one straight back in the same process (a same-process
round trip); `fatfs.tkb` dumps the whole disk back out via semihosting,
and `scripts/fatfs_mtools_test.py` (new) verifies it independently with
real `mdir`/`mcopy`. `scripts/run_qemutest.sh`'s new `run_fatfs_test`
builds the seed image with `mformat -C -i ... -t 2 -h 2 -n 32 -c 1 -r 1
-L 1 ::` -- mtools' own flags turned out not to map 1:1 onto BPB field
values empirically (`-r 1` produces 16 root directory entries, not 1;
confirmed by dumping the produced boot sector's actual bytes before
trusting any flag's effect) -- forced to match `fatfs.tkb`'s own fixed
layout constants exactly, since the driver assumes its own compile-time
layout rather than parsing the on-disk BPB dynamically (a known,
deliberately deferred limitation -- fine for a self-formatted image or a
geometry-matched `mformat` image, would misread an arbitrary real FAT
image such as a factory-formatted SD card; revisit if issue #62 needs it).

**Bug #1, found by actually running the seeded-read test, not by
`--forbid-trap`** (worth being precise about, since it was almost
mis-attributed in conversation): `fat_open(FA_READ, ...)` came back
"not found" against a freshly-loaded seed image. Root cause: `fat_buf`/
`root_dir_buf` are in-memory mirrors that `fat_flush()` only ever writes
*to* disk, never reads *from* it -- after `load_seed_from_host()`
populated `disk` from the host file, the mirrors were still BSS-zero, so
`fat_find_entry` was searching an empty in-memory directory that never
saw the loaded bytes at all. Fixed by adding `fat_mount()` (the
`fat_flush()` counterpart: two `mem_block_read`s instead of two
`mem_block_write`s), called once after `load_seed_from_host()` succeeds
and before the first `fat_open`. This has nothing to do with array-bounds
proofs or `--forbid-trap` -- it is an ordinary "forgot to load the cache"
logic bug, caught by the QEMU+`mtools` integration test doing its job.

**STM32 hardware bring-up** (`examples/fatfs/kernel_stm32_ram.elf`, RAM
execution, same pattern as every other STM32 example per the "STM32
Hardware Test Harness: RAM Execution" section below): STM32 has no ARM
semihosting host-file I/O, so `examples/common_stm32/semihosting_stub.S`
(new) provides trivial Thumb-2 stand-ins for the four `extern fn`
symbols `fatfs.tkb` declares (`semihosting_open` always returns `-1`;
`semihosting_read`/`semihosting_write` return their `len` argument
unchanged, ARM semihosting's own "0 bytes transferred" convention;
`semihosting_close` returns `0`) -- same idea as
`examples/common_qemu/stm32_stub.tkb`'s no-op stand-in for a symbol only
the other target's code path calls, just the reverse direction and in
assembly since these are `extern fn` (an unmangled symbol is an external
ABI contract, not overloadable).

The user explicitly wanted the seeded-read test (mtools writes, takibi
reads) exercised on real hardware too, not just stubbed out as
"unsupported" -- issue #61's own original discussion had already proposed
the technique: export/import a memory range as a raw binary with
OpenOCD's `dump_image`/`load_image`. `app_main()`'s Phase 1 was
restructured to stop gating on `load_seed_from_host()`'s return value
(the STM32 stub always reports failure regardless of whether the harness
actually seeded `disk`, since there's no real host-file-read happening
either way from the on-target code's point of view) and instead always
attempt `fat_mount()`+`fat_open(FA_READ, ...)` -- the real proof either
way, succeeding only if `disk`'s bytes are genuinely a valid FAT12 image.
`scripts/run_hwtest_ram.sh`'s new `ram_load_and_run_seeded` (a variant of
the existing `ram_load_and_run`) sets a hardware breakpoint at `app_main`
(address found via `llvm-nm-19` on the linked ELF -- confirmed both
`disk` and `app_main` are emitted unmangled, since takibi's `_TK_...`
mangling only applies to actually-overloaded names and neither is),
`resume`s, `wait_halt`s for it to hit (so `Reset_Handler`'s BSS-clear has
already run but `fatfs.tkb` hasn't touched `disk` yet), `load_image`s the
seed file directly into `disk`'s live RAM, removes the breakpoint, and
resumes again. This breakpoint+`wait_halt` sequencing is new to this
project's hardware scripts -- every other existing hardware test only
ever pokes SP/PC once, at the very start. A new `dump_disk_image`
(separate `halt`, i.e. NOT `reset halt`, + `dump_image`, run once UART
output goes quiet) extracts `disk` afterward for
`scripts/fatfs_mtools_test.py` to verify the same way the QEMU test does.
Passed on the real board on the first attempt, and again on a repeat run.

**Bug #2, found only by the user asking a follow-up question, not by any
test passing or failing**: neither the seed injection nor the post-run
dump accounted for the STM32F7's D-cache. `link_ram.ld`'s AXI SRAM1 is
cacheable (see the RAM-execution section below), and OpenOCD's
`load_image`/`dump_image` write/read physical RAM directly over the debug
port, bypassing the CPU's cache entirely -- exactly the same class of
problem `examples/common_stm32/eth.tkb`'s real DMA engine already has,
just with the debug port standing in for the DMA engine as the "external"
memory agent. Without an explicit invalidate, the CPU could still see
stale pre-seed cached data when Phase 1 reads `disk`; without an explicit
clean/write-back, the harness's post-run dump could read stale
pre-write-back RAM, missing the CPU's own not-yet-flushed writes. Both
hardware test runs had already passed *before* this fix -- almost
certainly because `disk` (64KB) vastly exceeds the STM32F7's D-cache
(a few KB), so ordinary cache eviction pressure over the run had already
displaced the relevant lines by the time it mattered, not because the
code was actually correct. Fixed by reusing the exact existing
cache-maintenance builtins `eth.tkb` already relies on for this same
external-agent-vs-cache pattern: `dma_finish_rx(disk, SECTOR_SIZE *
TOTAL_SECTORS)` as the first statement in `app_main()` (D-cache
invalidate on ARM/Thumb before Phase 1 reads the seeded data; a harmless
barrier on QEMU/AArch64, where semihosting reads are an ordinary
same-core CPU write with nothing to invalidate), and
`dma_prepare_tx(disk, SECTOR_SIZE * TOTAL_SECTORS)` right before Phase 4's
`dump_disk_to_host()` (D-cache clean/write-back before the harness's
external dump; likewise a harmless barrier on QEMU). Verified this
doesn't change QEMU's output at all (still an exact `fatfs.expected`
match) and that the hardware test still passes with the fix in place --
this time for the right reason, not by size-driven luck. Also prompted a
`CLAUDE.md` addition explaining *why* QEMU can never catch this class of
bug at all: QEMU here runs in TCG (software) mode, which has no separate
cache storage to go stale in the first place -- guest memory is a single
unified representation, so cache-coherency bugs are invisible under QEMU
regardless of how thorough the test is, and can only be found on real
silicon. Flagged as directly relevant to the still-Backlog multi-core
issue (#6) for whenever that work starts: get real-hardware integration
testing into the loop early for anything involving genuinely concurrent
hardware state, not just as a final check once "it already works in
QEMU."

**`SPEC.md` corrections made in the course of writing this file**
(discovered empirically while working around each, then verified against
the actual compiler before writing anything down, not assumed): `let mut
x: T;` (no initializer) was documented as global-scope-only, but a local
uninitialized `let mut` (scalar, array, or struct) has in fact always
type-checked (already covered by an existing unit test,
`test/test_takibi.ml`'s "let mut local without initializer type-checks")
-- SPEC.md's own wording was simply stale, now corrected to describe both
cases (global: BSS-zeroed; local: undefined content). Also newly
documented, none of them previously written down anywhere: `&arr[i]`
(address of an array/slice element, as opposed to `&ident`/`&s.field`) is
a compile error; `s.field[i] = v` (assigning into an indexed array field
reached through a struct) is a syntax error even though the reverse
`arr[i].field = v` already works and was already documented; `if`/`else`
is a statement only, with no if-expression/ternary form at all; and
`{lo..<hi as base}`'s `lo`/`hi` must be bare integer literals, unlike an
array size or a `for` loop's bounds, which both also accept a name
resolving to a literal via the array-size-constant mechanism.

**Files**: `examples/fatfs/fatfs.tkb`, `examples/fatfs/fatfs.expected`,
`examples/fatfs/fatfs_stm32.expected`, `examples/common_qemu/
semihosting_asm.S`, `examples/common_stm32/semihosting_stub.S`,
`scripts/fatfs_mtools_test.py`, `scripts/run_qemutest.sh`
(`run_fatfs_test`), `scripts/run_hwtest_ram.sh` (`ram_load_and_run_seeded`,
`dump_disk_image`, `run_hw_test_ram_fatfs`), `Makefile` (QEMU + STM32
build/link rules for `fatfs`, deliberately without `--forbid-trap`),
`CLAUDE.md` (new "Development Process" section, the QEMU-cache-model
note), `SPEC.md` (the five corrections/additions above), `README.md`
(fatfs mentioned in "Current Status," the "entire suite is
`--forbid-trap`-clean" claim corrected to note this one deliberate,
temporary exception).

**Verification**: `make check` (langcheck, unit tests, `stm32build`,
71 QEMU integration tests including `fatfs`) passes with zero
regressions. `make hwcheck`'s new `fatfs (stm32/ram)` test passed twice
in a row on the real STM32F746G-DISCOVERY board, both before and after
the cache-coherency fix (confirming the fix didn't just get lucky a
second time either).

### GitHub Issue #62: `examples/sdcard` -- a Real SDMMC1 Driver, Built Independently of `fatfs`

New example, `examples/sdcard/sdcard.tkb` and `examples/common_stm32/
sdmmc.tkb`: a from-scratch SDMMC1 (native SD mode, not SPI) driver for the
STM32F746G-DISCOVERY's onboard microSD slot, exposing the same scoped-down
FatFs Media Access Interface naming as issue #61's Application Interface
choice (`disk_initialize`/`disk_status`/`disk_read`/`disk_write`, no
`pdrv`/`count`/`disk_ioctl` -- exactly one drive, one block size, nothing
else needed yet). Deliberately built and hardware-verified as its own
independent example, **not** wired into `examples/fatfs` yet -- the user's
own explicit reasoning, mirroring why `fatfs` itself came before real SD
hardware in the first place: a bug in either FAT12 logic or the SD driver
should be attributable to one integration test, not conflated into a single
"everything touches SD card" test. 1-bit bus width, SD (not eMMC) only,
single 512-byte block transfers, no `--forbid-trap`/refinement types yet
(same milestone-wide reason as `fatfs`).

**Hardware test harness is fully automated, no card swap needed** (the
user's own explicit request, trading some rigor for full automation):
`scripts/sdcard_test.py` + `run_hw_test_ram_sdcard` in
`scripts/run_hwtest_ram.sh` write a fixed, deterministic byte pattern
(`(sector + i) & 0xFF`) into a handful of sectors via `disk_write`, read it
back via `disk_read`, and check the hex dump the firmware prints over UART
against the same pattern computed independently host-side -- no `mtools`,
no filesystem at this layer at all, and the card's previous contents are
destroyed every run (confirmed acceptable by the user in advance).

**Three real hardware/driver bugs found via live openocd/gdb-multiarch
debugging during the initial (polling-only) bring-up**, same technique
`eth.tkb`'s own bring-up needed:
- A card physically not fully seated in the slot (`CTIMEOUT` on CMD8,
  confirmed via reading GPIOC_IDR's card-detect bit) -- a user-side fix
  (re-seat the card), not a code bug.
- `sd_cmd7()` (SELECT_CARD) passed the RCA value straight through as
  CMD7's argument, but `sd_cmd3()` had already right-shifted it down out of
  bits 31:16 when extracting it from CMD3's R6 response -- CMD7 needs the
  RCA back in bits 31:16, same as CMD55's `rca << 16`. Fixed by adding the
  missing `<< 16` in `sd_cmd7`.
- The second consecutive `disk_write` (sector 1) timed out on its CMD24
  command: the card is still in its post-write busy/programming state and
  won't respond to a new command yet. Fixed by adding `sd_cmd13()`
  (SEND_STATUS) and `sd_wait_not_busy()` (polls CMD13's R1 response until
  READY_FOR_DATA/bit8), called at the end of `disk_write`.

#### Follow-up: DMA + Interrupt-Driven Transfers, a Real TXUNDERR Bug, and Cross-Checking ChibiOS

Once the polling-only driver was hardware-verified and committed as a
baseline, the user asked (explicitly flagging it as possibly premature)
to try converting `disk_read`/`disk_write`'s bulk
512-byte transfer to DMA + interrupt-driven completion, mirroring
`eth.tkb`'s own shape: `interrupt_wait()`/`interrupt_notify()`, an
`SDMMC1_IRQHandler` wired into NVIC (IRQ49) and the RAM/Flash vector
tables (`startup.S`/`startup_ram.S`, split IRQ38-60's `.rept 23` block to
insert the new handler at IRQ49, keeping both files' vector tables
identical per their existing convention).

**First attempt (DMA2 Stream3/Channel4, then Stream6/Channel4, PFCTRL +
FIFO-burst and later plain direct-mode transfers) reliably failed**: every
`disk_write` got a `TXUNDERR` a handful of words short of the end of the
512-byte block (confirmed via live register dumps: `DCOUNT` stuck at
`0x10` with 496 of 512 bytes already transferred). Live debugging
confirmed everything *except* the actual data flow was correct -- the NVIC
vector table entry, ISR entry/exit (`EXC_RETURN` value unchanged
throughout, confirmed by breakpointing both the ISR's first and last
instruction), and MASK/STA interrupt gating were all provably right, and
reading back DMA2's own `SxCR`/`SxPAR`/`SxM0AR` showed the stream
configured exactly as programmed. Reverting to the polling-only driver on
the exact same card/board immediately passed all 4 sectors again, ruling
out a card/hardware fault. Web research (`WebSearch`/`WebFetch`) turned up
multiple independent ST community forum reports of this *exact* symptom
(a DMA-driven SDIO/SDMMC transfer stalling a few words before completion)
across the F4/F7/H7 family, including one engineer who spent "many hours"
on it and gave up, reverting to polling -- looking like a genuinely hard,
easy-to-get-subtly-wrong timing interaction, not an obviously wrong
register value.

**Root cause found by reading ChibiOS's own STM32 SDMMCv1 driver**
(`os/hal/ports/STM32/LLD/SDMMCv1/hal_sdc_lld.c`, fetched from
`github.com/ChibiOS/ChibiOS` via `gh api`/`WebFetch` -- the user
specifically trusts this RTOS's STM32 support and asked for it to be
checked), cross-referenced against its own official STM32F746G-DISCOVERY
demo (`demos/STM32/RT-STM32F746G-DISCOVERY/cfg/mcuconf.h`, confirming DMA2
Stream3/Channel4 -- `STM32_DMA_STREAM_ID(2, 3)` -- matching this project's
*first* attempt, not the second Stream6 guess). ChibiOS's
`sdc_lld_read_aligned`/`sdc_lld_write_aligned` configure and **enable the
DMA stream, and arm `SDMMC_MASK`/`DLEN`, BEFORE sending the read/write
command (CMD17/CMD24) at all** -- only `DCTRL`'s `DMAEN`/`DTEN` bits are
set after the command's response comes back. This project's driver had
the DMA arm/enable step happening *after* the command response, giving
the DMA controller only a handful of CPU instructions' worth of time to
settle before `DTEN` immediately started real data flow, instead of a full
command/response round trip. Also noticed: ChibiOS's SDMMC ISR does
`SDMMC1->MASK = 0;` and wakes the waiting thread -- **nothing else** --
deliberately leaving `STA`/`ICR` untouched so the woken thread can inspect
`STA` itself to distinguish `DATAEND` from an error; this project's ISR
had been clearing `ICR` itself instead.

**Fix**: reordered `disk_read`/`disk_write` to configure+enable DMA and
arm `MASK`/`DLEN` before `sd_send_cmd`, matching ChibiOS exactly, and
changed `SDMMC1_IRQHandler` to only clear `MASK` and set the wake flag,
moving the `STA` check and `ICR` clear into `disk_read`/`disk_write`
themselves after waking. Also added `STA_STBITERR` to the armed mask,
matching ChibiOS's own mask contents. Result: DMA+interrupt-driven
`disk_read`/`disk_write` passed all 4 sectors, confirmed reliable across 3
consecutive hardware runs, then across the full `make hwcheck` (43/43) and
`make check` (71/71) with zero regressions elsewhere.

**Lesson worth keeping**: when a from-scratch peripheral driver hits a
hard-to-diagnose hardware timing bug, checking a mature, widely-deployed
RTOS's driver for the *same* IP block (not just the reference manual) can
surface an ordering/sequencing requirement the reference manual doesn't
spell out explicitly -- the register-level configuration here was already
provably correct; the bug was purely about *when*, relative to the
command, the DMA stream got armed.

**Files**: `examples/common_stm32/sdmmc.tkb` (new driver, both the
polling-only baseline and the later DMA+interrupt rewrite),
`examples/sdcard/sdcard.tkb` (new standalone test/demo, no filesystem),
`scripts/sdcard_test.py` (new, byte-pattern verification), `scripts/
run_hwtest_ram.sh` (`run_hw_test_ram_sdcard`), `examples/common_stm32/
startup.S`/`startup_ram.S` (new `SDMMC1_IRQHandler` NVIC vector table
entry and weak default), `Makefile` (`examples/sdcard/sdcard_stm32.o`
rule, STM32-only, no `--forbid-trap`).

**Verification**: `make check` (71/71) and the full real-hardware suite
(`make hwcheck`, 43/43 including `sdcard (stm32/ram)`) both pass with zero
regressions; the DMA+interrupt `disk_read`/`disk_write` path was confirmed
reliable across 3 independent hardware runs before being treated as done.

### GitHub Issue #98: `examples/fatfs_sdcard` -- FAT12 on the Real SD Card, and a Second, Unresolved `disk_read` DMA Bug

With `fatfs` (issue #61, in-memory block device) and `sdcard` (issue #62, real
SDMMC1 driver) each independently hardware-verified, this issue wired them
together: mount a real FAT12 filesystem on the real SD card through `fatfs`'s
own API, the same thing a normal PC or RTOS does. Three hard constraints from
the user drove the design: `examples/fatfs` and `examples/sdcard` both had to
remain **exactly as they were**, unmodified and independently testable, and a
**new** example would provide the combination.

**Design**: `examples/fatfs/fatfs.tkb`'s FAT12 core -- everything that only
ever touches storage through `mem_block_read(sector, buf)`/
`mem_block_write(sector, buf)`, never the `disk` array directly -- was moved
verbatim into a new shared `examples/common/fat12.tkb` (geometry constants,
`Fat12BootSector`/`DirEntry`, `fat_open`/`fat_read`/`fat_write`/`fat_close`/
`fat_format`/`fat_mount`, plus `cstr_len`/`create_demo_file`/
`uart_print_bytes`, also backend-agnostic). `fatfs.tkb` itself shrank to just
its in-memory `mem_block_read`/`mem_block_write` and its QEMU/host-interop
test harness (`use "examples/common/fat12.tkb";` in place of the moved code)
-- confirmed byte-identical via its existing QEMU `.expected` diff and
`run_hw_test_ram_fatfs`, both unchanged. The new `examples/fatfs_sdcard/
fatfs_sdcard.tkb` (STM32-only, no QEMU build, same reasoning as `sdcard`)
supplies `mem_block_read`/`mem_block_write` as two-line adapters over
`sdmmc.tkb`'s real `disk_read`/`disk_write` -- exactly the seam issue #61's
own header comment had anticipated. `disk_read`/`disk_write` return `i32`
(can fail) but `mem_block_read`/`mem_block_write` are `void`; the adapter
silently discards a real I/O failure, matching `fatfs.tkb`'s own existing
"assume success" scope -- a deliberate, named limitation, not an oversight,
left for whenever a real caller needs the error to actually propagate.
`app_main()` does `disk_initialize`/`disk_status`, `fat_format()`, creates one
file via `fat_open`(create)+`fat_write`+`fat_close`, then reads it back via
`fat_open`(read)+`fat_read` in the same process -- deliberately *not*
`fatfs.tkb`'s own mtools cross-check or semihosting dump/seed, since neither
reaches real SD card content and `fatfs.tkb` already covers that check
thoroughly.

**A second, more elusive real-hardware bug, this time in `disk_read`
specifically, and never fully root-caused.** Bringing the new example up
immediately reproduced a crash: `disk_initialize`/`disk_status`/`format`/
`create HELLO.TXT` all succeeded, then the very first `disk_read` (via
`fat_open(FA_READ)`+`fat_read`) hung, and a live register dump showed a
genuine `HardFault` (`INVSTATE`/`IACCVIOL` depending on the exact run) with
`DMA2_S3NDTR` (the transfer's own remaining-word counter) wrapped hundreds of
counts past its expected 128-word value -- the DMA had kept writing past the
caller's 512-byte buffer into whatever memory followed it (the stack,
corrupting a saved return address). Bisected with a series of throwaway
scratch `.tkb` programs (no existing example touched) down to an exact,
reproducible threshold: 128 prior `disk_write` calls then a `disk_read`
always worked; 129 always corrupted memory and crashed, regardless of which
sectors were used, whether any were repeated, an inserted multi-second delay
before the read, or whether the 130th operation was a write instead (writes
kept succeeding indefinitely). Three fixes cross-checked against ChibiOS's
own proven `hal_sdc_lld.c` were tried and did **not** resolve it: explicitly
clearing `SDMMC_DCTRL` to 0 after every transaction (matching ChibiOS's
unconditional `sdc_lld_wait_transaction_end`/`sdc_lld_error_cleanup`),
draining `SDMMC_STA`'s `RXDAVL` bit before disabling the data path (matching
ChibiOS's own read-completion handling, present specifically because
`DATAEND` can fire before the FIFO is fully drained), and, as a more
invasive fourth experiment, disabling `PFCTRL` entirely so DMA itself (not
SDMMC1) decides when to stop via a fixed `NDTR` count -- this one did stop
the crash, but traded it for a different failure (some transfers cut off
early, `DATAEND` never arriving). None of the four pointed at a clear root
cause.

**Resolution: `disk_read` reverted to plain STA/FIFO polling (its original,
already-hardware-verified pre-DMA implementation from earlier in issue #62),
kept deliberately asymmetric with `disk_write`, which stays DMA+interrupt
driven and continues to pass every existing test reliably** (confirmed via
`examples/sdcard`'s own existing automated hardware test, unaffected by any
of this). This is recorded as a genuinely **unresolved, open issue** in
`sdmmc.tkb`'s own header comment, not quietly worked around: it is not known
whether the root cause is a real bug in this driver's DMA2/SDMMC1 pairing, an
undocumented STM32F7 silicon quirk, something specific to the individual
STM32F746G-DISCOVERY board this was debugged on, or something specific to the
individual microSD card used for testing -- none of these have been ruled
out. Worth noting as its own small data point: `disk_write`'s DMA+interrupt
path, under the exact same configuration/ordering, has never shown this
failure across (at time of writing) hundreds of consecutive calls in this
session's own testing -- only `disk_read`, and only after a specific prior
write count. Revisit only with a genuinely new, concrete lead (a documented
silicon erratum, a logic-analyzer trace, or a second STM32 board/SD card to
compare against), not by re-trying more register combinations blind.

**Files**: `examples/common/fat12.tkb` (new, shared FAT12 core),
`examples/fatfs/fatfs.tkb` (shrunk to its in-memory backend + test harness,
confirmed byte-identical), `examples/fatfs_sdcard/fatfs_sdcard.tkb` (new),
`examples/fatfs_sdcard/fatfs_sdcard.expected` (new, captured from a real
verified hardware run), `examples/common_stm32/sdmmc.tkb` (`disk_read`
reverted to polling, `disk_write` unchanged; new header comment documenting
the open issue), `Makefile` (`COMMON_FAT12` variable, `fatfs_sdcard` added to
`STM32_RAM_EXAMPLES`, new `examples/fatfs_sdcard/fatfs_sdcard_stm32.o` rule,
no `--forbid-trap`), `scripts/run_hwtest_ram.sh` (new `fatfs_sdcard
(stm32/ram)` entry, using the plain `run_hw_test_ram` expected-output diff
with a longer 15s/40-poll capture window since `fat_format()`'s ~128 real
`disk_write` calls, each with its own CMD13 busy-wait, take noticeably longer
than the default window -- same reasoning as `rtc`/`timer`'s own override).

**Scope note**: per explicit user direction, `--forbid-trap`/refinement
types were deliberately **not** enabled in this pass, even though this
combination is what CLAUDE.md's existing "Development Process" text
describes as the milestone-completion trigger for doing so across
`fatfs.tkb`/`fat12.tkb`/`sdmmc.tkb`/`fatfs_sdcard.tkb` together -- treated
as a separate, later checkpoint instead of bundled into this already-large
change.

**Verification**: `make check` (71/71, including the QEMU `fatfs` test
confirming the `fat12.tkb` extraction changed nothing observable) and the
full real-hardware suite (`make hwcheck`, 44/44 including the new
`fatfs_sdcard (stm32/ram)` and the still-passing `sdcard (stm32/ram)`) both
pass with zero regressions. `fatfs_sdcard` itself confirmed reliable across
3 independent real-hardware runs (format + create + read-back, all matching)
before being wired into the automated suite.

#### Follow-up: `--forbid-trap` Enabled Across the Whole Milestone, and a Third, Separate Bug Found -- Not Fixed

With `fatfs_sdcard` proven working end to end, the user asked to complete
the milestone by turning `--forbid-trap` on across all five affected files
(`examples/fatfs/fatfs.tkb`, `examples/common/fat12.tkb`,
`examples/common_stm32/sdmmc.tkb`, `examples/fatfs_sdcard/fatfs_sdcard.tkb`,
and `examples/sdcard/sdcard.tkb`, since it also calls `sdmmc.tkb`'s
`disk_read`/`disk_write` directly), per CLAUDE.md's already-agreed process.
A dry run (`--forbid-trap` added to each compile command without committing
to fixes yet) found `sdcard.tkb` already clean (its own fixed-size loops
were already fully provable) and 26 flagged sites across `fat12.tkb` and
`fatfs.tkb`'s `mem_block_read`/`mem_block_write`.

**All 26 sites shared the same shape**: a value whose real invariant (a
valid FAT12 cluster number, root-directory slot index, or sector number for
this small, self-formatted volume) is bookkeeping this project's own
callers establish at runtime, not something a plain `u32`/`usize`
parameter's type lets the compiler see. Fixed with explicit if-narrowing at
the point of use (`if (v >= lo && v < hi) { ... }`, SPEC.md's documented
form) rather than widening any parameter or return type -- discovered
along the way that this two-sided form is required for the narrowing to
actually take hold: a single-sided `if (off < 511)` did **not** close the
trap (even though `off: usize` is unsigned and thus trivially `>= 0`);
writing it as `if (off >= 0 && off < 511)` did. **Filed as GitHub issue
#99 and fixed in a later session** (see this file's own issue #99 entry
below) -- these sites, and every other unsigned-base site this pattern
touched, were simplified back to the hi-only form once the fix landed.
Also discovered that
if-narrowing tracks a plain variable, not a repeated struct-field-access
expression (`fp.dir_index` had to be bound to a local first, then that
local narrowed, for `fat_close`'s access to close). And confirmed again
the already-documented literal-only restriction on comparisons feeding
narrowing: `next_free_root_entry >= ROOT_ENTRY_COUNT as u32` (a named
global) did not narrow the following code at all; only rewriting the
comparison against the literal `16` did (the array's own `[DirEntry;
ROOT_ENTRY_COUNT]` size declaration was left using the named constant --
only the *narrowing comparison* needs the literal). `fat_get_entry`/
`fat_set_entry` additionally gained a real (if practically unreachable)
out-of-range fallback (`return 0x0FFF` / a no-op) instead of assuming the
caller's cluster number is always valid, since narrowing here has no
natural "return -1" error path to reuse.

All five files' Makefile rules gained `--forbid-trap`. `make check` (71/71)
passed immediately. **The real-hardware suite did not**, but not because of
any of the above: `fatfs_sdcard (stm32/ram)` intermittently failed with
exactly one byte missing from the captured output -- the colon in
`format: OK`, appearing as `format OK` instead, roughly 1 run in 6-10.
Bisected carefully before concluding anything: temporarily checked out the
pre-`--forbid-trap` committed version of `fat12.tkb` (via `git checkout
<commit> -- examples/common/fat12.tkb`, rebuilt, tested, then restored the
fixed version) and reproduced the *identical* single-byte drop on that
version too, at a similar rate. This rules out the `--forbid-trap` fixes
above as the cause -- **a third, genuinely separate, pre-existing bug**,
apparently a rare race somewhere in the interrupt-driven UART TX path
(`examples/common_stm32/uart.tkb`) or an NVIC priority interaction with
SDMMC1, that this session's testing happened to surface only now because
`fatfs_sdcard` is the first example to put this much interrupt-driven
SDMMC1 traffic immediately before a UART print. Documented as an open,
unresolved issue in `uart.tkb`'s own header comment (suspected mechanism: a
read-modify-write race between `uart_putc`'s and `uart_tx_isr`'s shared
`USART1->CR1` TXEIE bit access) rather than guessed at further -- per
explicit user direction, this pass closes out with `--forbid-trap` itself
done and verified, and treats hunting down this new bug as its own,
separate follow-up. An occasional single-missing-byte
`fatfs_sdcard (stm32/ram)` hwcheck failure should be read as this known,
already-flagged issue, not a fresh regression, until it is actually fixed.

**Files**: `examples/common/fat12.tkb`, `examples/fatfs/fatfs.tkb`
(if-narrowing fixes), `examples/common_stm32/uart.tkb` (new header comment
documenting the UART byte-loss issue, unfixed), `Makefile` (`--forbid-trap`
added to `FATFS_OBJS`, `examples/fatfs/fatfs_stm32.o`,
`examples/sdcard/sdcard_stm32.o`, `examples/fatfs_sdcard/
fatfs_sdcard_stm32.o`).

**Verification**: `make check` (71/71) with `--forbid-trap` enabled across
all five files. Full real-hardware suite (`make hwcheck`) passes except for
`fatfs_sdcard`'s pre-existing, now-documented intermittent single-byte UART
issue described above, unrelated to the refinement-type work in this pass.

## GitHub Issue #101 ("Drop char on UART, race condition?") -- Investigated and Fixed

Follow-up to the intermittent single-byte UART loss found above. Filed as
issue #101 and investigated as its own dedicated pass.

**First confirmed the board's exact silicon**: OpenOCD reports this specific
board as Cortex-M7 **r0p1**, an early revision. This matters because ARM
errata 837070 ("Increasing priority using a write to BASEPRI does not take
effect immediately") affects exactly r0p0/r0p1 (fixed in r0p2), and ChibiOS's
own ARMv7-M port (`chcore.h`) has a `#if __CM7_REV <= 1` special case
wrapping its BASEPRI-based kernel lock with `CPSID i`/`CPSIE i` specifically
for this silicon family. This looked like a strong, well-documented lead.

**Two PRIMASK-based critical-section fix attempts, both genuine dead ends.**
Added `extern fn disable_irq()/restore_irq(saved)` (hand-written Thumb
`mrs/cpsid/bx` and `msr/bx`) wrapping `uart_putc`'s `USART1->CR1` TXEIE
read-modify-write:
- Plain PRIMASK save/restore, no barriers: made the bug catastrophically
  worse (~99% failure on a simple synthetic stress test, up from ~11%).
- Same, with `dsb`+`isb` added around the PRIMASK writes (following the
  errata's spirit, even though ARM's own text says PRIMASK itself -- unlike
  BASEPRI -- is not affected by 837070): reduced the simple synthetic test
  to a deterministic 2/300 failures, a large apparent improvement. But
  against the REAL `fatfs_sdcard` reproduction (not the simplified
  synthetic one), the same fix showed ~50% failure -- worse than baseline,
  not better. A fix that improves a simplified stress test but does not
  generalize to the real target scenario is not a fix; both attempts were
  reverted (`git checkout <pre-#101 commit> -- uart.tkb startup.S
  startup_ram.S`) rather than kept as a partial improvement.

**The actual fix: an architectural change, not a critical section.** The
user's own hypothesis, offered explicitly as "weak evidence" but worth
testing: this project's UART TX was per-byte-interrupt driven while
`sdmmc.tkb`'s `disk_write` was already DMA+interrupt driven -- an asymmetric
combination most STM32 codebases don't exercise (either everything uses
DMA+interrupt, as ChibiOS/RT does for both UART and SD, or a byte-interrupt
UART is never combined with DMA-heavy traffic on another peripheral under
load), which would explain why this race is obscure rather than a
well-known errata. Tested with a throwaway one-shot DMA-based UART TX
experiment (never wired into the real driver) against the exact realistic
reproduction pattern (128 ascending `disk_write` calls immediately followed
by a UART print, x60 iterations per run): **0 failures across 4 independent
runs (240 total iterations)**, versus ~47-50% failure with the existing
per-byte-interrupt `uart_putc`/`uart_tx_isr` on the identical pattern. A
dramatic, repeatable result.

**Production implementation** (`examples/common_stm32/uart.tkb`): TX moved
to DMA2 Stream7/Channel4 (SDMMC1 already owns DMA2 Stream3/Channel4 --
different stream, no conflict). The existing 128-byte ring buffer and its
head/tail producer/consumer protocol are unchanged; only how a buffered run
of bytes is drained to hardware changed -- one DMA burst per contiguous
ring run (split at the buffer's physical wraparound point when needed)
instead of one interrupt per byte. `dma_uart_tx_kick()` starts a burst
whenever the ring is non-empty and no burst is already in flight; the new
`DMA2_Stream7_IRQHandler` (added at IRQ70, both `startup.S` and
`startup_ram.S` gained the vector table entry plus a `.weak` no-op default,
same pattern as `SDMMC1_IRQHandler`) advances the tail on completion and
chains the next burst. `USART1_IRQHandler` now only services RX; TXEIE and
the old per-byte drain (`uart_tx_isr`) are gone entirely.

**A second real bug found and fixed during bring-up, distinct from the
byte-loss race itself**: the first working version of the DMA rewrite
compiled cleanly and passed `make check`/`make stm32build`, but every real
hardware test failed completely (`hello`'s "Hello, World!\n" came back as
all-zero bytes) -- not an intermittent byte loss, total silence. Root cause:
AXI SRAM1 is genuinely cacheable (see the RAM-execution notes elsewhere in
this file), and `uart_putc`'s plain CPU stores into `uart_tx_buf` were
sitting in the D-cache, invisible to DMA2 reading physical RAM directly --
exactly the class of bug this project's own `dma_prepare_tx`/`dma_prepare_rx`/
`dma_finish_rx` builtins exist to prevent, and exactly the kind flagged
elsewhere in this file as only reproducible on real hardware, never in
QEMU. Missed initially because the throwaway DMA experiment above never
hit it by luck (its buffer's cache state happened to already be clean at
the point DMA read it). Fixed with one `dma_prepare_tx(src_ptr, burst_len)`
call in `dma_uart_tx_kick()`, right before the DMA registers are armed --
after which `hello` and every other test passed immediately. Confirmed via
`llvm-objdump` disassembly of `dma_uart_tx_kick` that every register write
(DMA2 S7CR/NDTR/PAR/M0AR/FCR, HIFCR clear mask) matched the intended values
bit-for-bit before looking for a cache explanation, ruling out a codegen or
register-address mistake first.

**Verification**: the exact issue #101 reproduction (`fatfs_sdcard` real-
hardware test) run 30 consecutive times with **0 failures** (previously
roughly 1 failure in 6-10 runs). Full `make check` (71/71), `make
stm32build` (all STM32 examples, since `uart.tkb` is shared by every one of
them), `make hwcheck` (44/44 real hardware), and `make hwcheck-net` (6/6,
including the Flash-execution `http_server` boot path) all pass with no
regressions.

As with the abandoned PRIMASK attempts, the possibility that the original
bug was, in part, specific to this individual physical board or this
specific SD card cannot be fully excluded -- but the fix's dramatic,
repeatable effect on the exact reproduction pattern, combined with the
architectural asymmetry it corrects (and which matches ChibiOS/RT's own
design choice), is strong enough evidence to treat this as resolved rather
than coincidentally masked.

**Files**: `examples/common_stm32/uart.tkb` (TX rewritten to DMA2 Stream7/
Channel4 + interrupt), `examples/common_stm32/startup.S` and
`examples/common_stm32/startup_ram.S` (new `DMA2_Stream7_IRQHandler` vector
at IRQ70, `.weak` no-op default), `README.md` (updated to describe the fix
instead of the open issue).

## Issue #101 Follow-up: `disk_read` Also Rebuilt as DMA+Interrupt (`examples/common_stm32/sdmmc.tkb`)

After closing #101, the user drew a broader lesson from it: matching a
proven reference implementation's actual usage pattern (ChibiOS/RT using
DMA+interrupt uniformly, not mixing it with polling on an adjacent
peripheral) avoids obscure silicon/driver interaction bugs that a novel
combination can trip over. `disk_read` in `sdmmc.tkb` was the one other
place in the codebase matching this asymmetric shape -- polling-only,
sitting right next to `disk_write`'s DMA+interrupt path -- and had its own
long, unresolved history (see the issue #62/#98 entries above): a first
DMA+interrupt `disk_read` attempt reliably corrupted memory (`DMA2_S3NDTR`
running away past its expected 128-word count) once issued after roughly
129 or more prior `disk_write` calls, survived four separate ChibiOS-
informed fixes, and was reverted to polling as a genuinely unresolved dead
end.

**Revisited specifically because issue #101 supplied a new, previously-
untried angle**: none of the four earlier fixes had touched cache
maintenance around `disk_read`'s destination buffer, and issue #101's own
UART investigation had just found a real, previously-missed cache-
coherency bug in this project's DMA code elsewhere (a DMA source buffer
never flushed from the D-cache before the DMA engine read it). `disk_read`
was rebuilt to mirror `disk_write`'s DMA+interrupt structure exactly
(same `sd_dma_config`/arm-before-command ordering, same `SDMMC1_IRQHandler`
wakeup protocol), with `dma_prepare_rx`/`dma_finish_rx` added around the
DMA destination -- something none of the earlier attempts had tried.

**A second, distinct bug found during bring-up, not the same mechanism as
the original NDTR-runaway mystery.** The first version of this rebuild
called `dma_prepare_rx`/`dma_finish_rx` directly on the caller's own `buf`
parameter (mirroring `disk_write`'s `dma_prepare_tx(buf, 512)` exactly) and
immediately HardFaulted on real hardware, even on the ordinary 4-sector
`examples/sdcard` test -- far short of the historical 129-write threshold,
so this was clearly a different bug from the one being chased.
`llvm_gen.ml`'s cache-maintenance codegen (`emit_cortex_m_cache_range`)
documents the mechanism directly in its own comment: it operates on whole
32-byte cache lines, rounding the requested `[ptr, ptr+len)` range OUTWARD
to line boundaries, and warns "callers must still ensure that DMA buffers
do not share cache lines with unrelated mutable data." `dma_finish_rx` (and
`dma_prepare_rx`) lower to an INVALIDATE (`DCIMVAC`), which discards
whatever is currently in a touched cache line with no writeback -- unlike
`dma_prepare_tx`'s CLEAN (`DCCMVAC`), which only flushes a line's existing
value to RAM and therefore cannot destroy data even if its own rounding
spills into an unrelated live cache line. `examples/sdcard/sdcard.tkb`
passes a plain stack-local `[u8; 512]` as `disk_read`'s `buf` argument, and
per SPEC.md, **local-variable alignment is not supported by this language
at all** -- so that stack buffer had no 32-byte alignment guarantee, and
invalidating its (possibly unaligned) address range could silently discard
adjacent live stack data (a saved register, a return address), producing
exactly the observed real-hardware HardFault. `examples/common_stm32/
eth.tkb` never hits this because its own `dma_prepare_rx`/`dma_finish_rx`
calls are always on `eth_rx_bufs`, a driver-owned GLOBAL declared
`align(32)` -- `disk_read`'s public API, unlike `eth.tkb`'s, hands DMA
ownership of an arbitrary CALLER-supplied buffer, which cannot be assumed
aligned.

**Fix**: `disk_read` no longer touches the caller's `buf` with any cache-
maintenance call at all. A new driver-owned `disk_read_bounce: [u8; 512]
align(32)` global is the actual DMA destination; `dma_prepare_rx`/
`dma_finish_rx` run against `disk_read_bounce` (always safe, since it is
correctly aligned and driver-private), and the 512 bytes are copied into
the caller's `buf` with a plain byte loop only after `dma_finish_rx` has
completed -- so `buf` itself can be any alignment, preserving `disk_read`'s
existing public contract. `disk_write` needed no equivalent bounce buffer:
`dma_prepare_tx` being a CLEAN rather than an INVALIDATE means it cannot
corrupt data regardless of the source buffer's alignment.

**Verification**: with the bounce buffer in place, `examples/sdcard`'s
existing hardware test passed 15/15 consecutive runs (previously HardFault-
ing 100% of the time on the very first read). A dedicated stress test
mirroring the exact historical reproduction (150 ascending `disk_write`
calls -- comfortably past the old 129 threshold -- immediately followed by
a `disk_read`, x5 rounds per run) passed **20/20 rounds with zero
failures** across 4 independent runs; an earlier apparent hang on this same
test turned out to be the test harness's own idle-quiet capture timeout
firing during a legitimate multi-second pause (150 real card writes with no
UART output in between), not a firmware problem -- resolved by widening the
capture's stable-quiet threshold, the same class of harness tuning issue
CLAUDE.md's `rtc`/`timer` entries already document. Full `make check`
(71/71), `make hwcheck` (44/44, including `fatfs_sdcard` which exercises
`disk_read` through `fat_read`), and `make hwcheck-net` (6/6) all pass with
no regressions.

It remains possible the original NDTR-runaway crash was never purely a
cache-coherency issue and this rewrite's exact register sequence differs
from the original failing attempt in some other, unidentified way -- but
the fix has now held across extensive, repeated real-hardware testing
targeting the precise historical failure condition.

**Files**: `examples/common_stm32/sdmmc.tkb` (`disk_read` rewritten to
DMA+interrupt with an `align(32)` bounce buffer; `SDMMC_FIFO`/
`STA_RXFIFOHF`, only ever used by the old polling implementation, removed
as dead code; header comment and `disk_read`'s own comment rewritten),
`README.md` (updated to describe the fix instead of the open issue).

## GitHub Issue #27: Local-Variable `align(N)`

The `disk_read` bounce-buffer bug above (an unaligned STACK-local buffer
being passed to `dma_finish_rx`'s cache-line invalidate) was exactly the
motivating use case long tracked as issue #27 ("Alignment of stack
value"), previously deprioritized for lack of a concrete driving need --
this session's real hardware bug was that concrete need, so it was
implemented immediately afterward.

**Design**: mirrors the existing global `let mut x: T align(N);` syntax
(added earlier for struct-level/global alignment) but for a local
declaration inside a function body. Restricted to `let mut` only (no plain
`let`): an immutable local in this compiler's codegen is an SSA value with
no `alloca`/memory location at all (see `gen_stmt`'s `Let (false, ...)`
case, which stores the initializer's LLVM value directly into the
`locals` table, never calling `build_alloca`) -- there is nothing for
LLVM's `set_alignment` to attach to. A `mut` local, by contrast, is always
pre-allocated via `collect_lets`/`build_alloca` regardless of alignment,
so this restriction only narrows syntax, it does not require new codegen
machinery for the immutable case.

**Files touched** (5, the same shape as every other language-level
feature's "N files" pattern documented elsewhere in this file):
1. `lib/ast.ml` -- `Let` gained a 5th field, `int option` (align), matching
   `LetDef`'s existing 4th field for the global case. Every existing
   pattern match on `Ast.Let` across `lib/type_inf.ml`, `lib/llvm_gen.ml`,
   and `test/test_takibi.ml` needed a trailing wildcard/field added (a
   compile error at every site until fixed -- OCaml's exhaustiveness
   checking caught all of them mechanically).
2. `lib/parser.mly` -- two new `stmt` productions,
   `LET MUT IDENT COLON type_expr ALIGN LPAREN INT RPAREN SEMI` and the
   `ASSIGN expr` variant, mirroring the existing global `item`-level
   productions exactly (down to reusing `narrow_int64` for the alignment
   literal). No grammar conflicts: the token immediately following
   `type_expr` (`ALIGN` vs. `SEMI`/`ASSIGN` from the existing `let_rhs`-
   based productions) disambiguates cleanly under the parser's existing
   LALR(1) lookahead, the same way the global case already did.
3. `lib/type_inf.ml` -- no new logic; every existing `Ast.Let` match site
   just threads the new field through unused (`_`). Alignment doesn't
   affect a variable's TYPE, only its storage, so nothing here needed to
   inspect the new field at all.
4. `lib/llvm_gen.ml` -- `collect_lets` (the pre-scan that pre-allocates
   every mutable local's `alloca` at function entry, before any statement
   codegen) now also returns each local's `align_opt`, threaded from the
   4-tuple to a new 4th element. The pre-alloca loop in `gen_func` applies
   `set_alignment n ptr` when `align_opt = Some n`, falling back to the
   existing `apply_struct_align` (the struct type's own registered
   alignment, if any) otherwise -- an explicit local `align(N)` takes
   precedence over the type's own struct-level alignment, mirroring
   `gen_global`'s existing `eff_align` precedence rule for the global case
   exactly (kept as a documented "sync rule" comment at the local site).
5. `examples/align/align.tkb` -- extended with a third check: a local
   `let mut local_buf32: [u8; 32] align(32);`, address-masked and printed
   the same way as the two existing global checks. `examples/align/
   align.expected` gained the corresponding third `0x00000000` line.

**Verification**: `dune test` (479/479 unit tests, after mechanically
fixing every `Ast.Let` pattern match the added field broke), `make check`
(71/71, includes the extended `align` QEMU + `--forbid-trap` STM32 build),
and a real-hardware run of `align (stm32/ram)` all pass. No change was made
to `examples/common_stm32/sdmmc.tkb`'s `disk_read_bounce` (already a
correctly-`align(32)`-annotated GLOBAL, unaffected either way) or to
`examples/sdcard/sdcard.tkb`'s own stack-local `wbuf`/`rbuf` (already made
safe regardless of alignment by `disk_read`'s bounce-buffer copy, per the
entry above) -- this feature closes the general language-level gap, not a
specific remaining call site.

**Files**: `lib/ast.ml`, `lib/parser.mly`, `lib/type_inf.ml`,
`lib/llvm_gen.ml`, `test/test_takibi.ml` (mechanical pattern-match fixes),
`examples/align/align.tkb` + `align.expected` (new local-align check),
`SPEC.md` (removed the "local-variable alignment is not supported" note,
documented the new syntax and its `mut`-only restriction).

## GitHub Issue #99: Hi-Only If-Narrowing for Unsigned Bases

Closes the gap found and documented while enabling `--forbid-trap` across
the fatfs+SD-card milestone (see this file's earlier entry): `if (v < hi)`
alone did not narrow `v`, even when `v`'s own base type (`u8`/`u16`/`u32`/
`u64`/`usize`) already makes `v >= 0` true unconditionally, forcing every
call site to spell out the redundant `v >= 0 &&` conjunct by hand.

**Fix, in both `type_inf.ml` (proof) and `llvm_gen.ml` (codegen -- these
two must always agree per this project's "sync rule" convention)**: the
narrowing fold now looks up the variable's *current* type first, then
computes an effective lower bound before matching on `(lo, hi)`:
- If the condition itself supplied a `lo` (the two-sided or
  `lo`-only form), it wins, unchanged from before.
- Otherwise, if the variable's base is one of the five unsigned primitive
  types, the lower bound implicitly defaults to `0`.
- Otherwise (a signed base, or an unsigned base that's already refined
  and thus already carries its own proven `elo`), the variable's own
  currently-proven lower bound (if any) is reused as the floor -- sound
  unconditionally, since that bound was already established as valid
  before the new condition was even reached. A signed base with no
  incoming range and no explicit lower bound in the condition still gets
  no lower bound at all and is correctly NOT narrowed by a hi-only
  condition (it could still be negative).

This same restructuring (look up current type, compute effective lo, THEN
match) also fixes a smaller pre-existing gap for free: previously, an
already-refined variable narrowed further by a hi-only or lo-only
condition wasn't narrowed at all (the code required both `lo_opt` and
`hi_opt` present from the condition itself); it now correctly intersects
using whichever bound the condition supplies plus the variable's existing
proven range for the other side, mirrored identically across
`type_inf.ml`'s `narrow_from_cond`, `llvm_gen.ml`'s `apply_narrowing`
(immutable locals), and `apply_narrowing_mut` (mutable locals, via
`narrowing_ctx`).

**Verified with two throwaway compile tests** before touching any real
example: an unsigned `usize` parameter narrowed by a bare `if (off <
511) { buf[off] ... }` compiled clean under `--forbid-trap` (both an
immutable and a `let mut` variant); a signed `i32` parameter with the
identical hi-only condition still correctly produced a `--forbid-trap`
error (`array bounds check remains`), confirming the fix is properly
scoped to unsigned bases and did not weaken the existing signed-type
behavior. `examples/refined/refined.tkb` and `examples/narrow/narrow.tkb`
were deliberately left untouched -- both use a genuinely signed `i32` for
their if-narrowing demo specifically to show the two-sided form rejecting
a negative input (`fill_from_unknown(-1, 'X')`), which remains correct
and necessary.

**Every existing unsigned-base site using the old two-sided form was
simplified back to hi-only**, closing the gap the earlier fatfs+SD-card
`--forbid-trap` pass had to work around by hand: `examples/common/
fat12.tkb` (`fat_get_entry`/`fat_set_entry`'s `off: usize`,
`fat_open`'s `next_free_root_entry: u32`, `fat_close`'s `idx: usize`),
`examples/fatfs/fatfs.tkb` (`mem_block_read`/`mem_block_write`'s
`sector: u32`), and `examples/tcp_echo/tcp_echo.tkb` (`build_data_echo`'s
`data_len: u16`). Sites using a genuinely SIGNED type were identified and
deliberately left alone, since `>= 0` is load-bearing there: `fat12.tkb`'s
`fat_open`'s `found: i32` (a `-1` "not found" sentinel),
`http_server.tkb`'s `len`/`wire_len: isize`/`i32` and `payload_len: i32`.

**Verification**: `dune test` (479/479), `make check` (71/71, every
simplified site still compiles trap-free), `make hwcheck` (44/44,
including `fatfs`/`fatfs_sdcard` which exercise the simplified
`fat12.tkb`/`fatfs.tkb` sites), `make hwcheck-net` (6/6, including
`tcp_echo`'s simplified site), and `make langcheck` all pass with no
regressions.

**Files**: `lib/type_inf.ml` (`narrow_from_cond`), `lib/llvm_gen.ml`
(`apply_narrowing`, `apply_narrowing_mut`, new `is_unsigned_ast_ty`
helper), `SPEC.md` (documented the hi-only unsigned case and the signed
negative control), `examples/common/fat12.tkb`, `examples/fatfs/
fatfs.tkb`, `examples/tcp_echo/tcp_echo.tkb` (simplified narrowing sites).

## GitHub Issue #100: Refinement Type on Struct Field -- and a Bigger Soundness Hole Found While Scoping It

The user asked how heavy issue #100 ("Refinement type on struct field")
would be before committing to it. Investigated by direct compilation
tests rather than reading code and guessing: a `struct Foo { idx: {0..<8
as usize}; }` field, read directly, through a pointer, through an array
element, passed to an exact-match refined parameter, or read repeatedly,
**already compiled clean under `--forbid-trap`** -- the core mechanism
needed no new code at all. `struct_fields`'s grammar rule already used
the general `type_expr` production (which includes `TypeRefined`), and
`FieldGet`/`AssignField`'s existing `unify_at` calls already handled a
refined field type correctly for every read/pass-through case tried.

**While probing for the actual gap that must have motivated the issue,
found something far more serious**: an out-of-range integer LITERAL
assigned to (or initialized against, or passed as an argument for) a
refined-type target was **silently accepted with no check and no trap,
even under `--forbid-trap`**. `let v: {0..<8 as usize} = 20;` followed by
an unchecked `buf[v]` compiled with zero trap sites and would genuinely
read/write out of bounds at runtime -- a real violation of
`--forbid-trap`'s core promise ("zero trap sites remain because the type
system already proved safety"), not merely a missing diagnostic. Verified
this was general, not struct-field-specific, by reproducing it identically
across `let` initializers, plain `Assign`, function call arguments,
`AssignField` (struct fields, the issue #100 case), and struct literals.
Also confirmed a DIFFERENT, lower-severity case (`let x: u8 = 300;`, a
non-refined narrow type) was unaffected by design -- silent truncation
there is a usability wart, not a `--forbid-trap` soundness violation,
since no bounds-check elision is involved.

**Root cause**: `IntLit`'s inferred type is `fresh ()`, an unconstrained,
polymorphic type variable (so a bare literal can unify with whichever
concrete integer type context demands) -- `unify`'s `TRefinedInt`
subtyping rules only ever check that the SOURCE TYPE's *shape* fits the
target (e.g. "some already-u8-range-shaped value unifies with u8"), they
have no way to see the literal's actual numeric VALUE, since by the time
`unify` runs, the literal has already degraded to an unbound type
variable carrying no value information at all.

**Rejected fix approach**: making `IntLit`'s inferred type immediately
`TRefinedInt (k, k+1, fresh_base)` (encoding the literal's exact value
into its OWN type, so `unify`'s existing machinery would see it
naturally) was considered and set aside as too invasive for this pass --
several of `unify`'s existing `TRefinedInt`-vs-concrete-type rules (e.g.
`TRefinedInt (lo, hi, _), TU8 when ... -> ()`) explicitly discard the
refined value's base position without binding it, so a `TRefinedInt`
wrapping a still-unresolved inner type variable could leak an unbound
TVar through to codegen with no clear resolution point -- a genuinely
structural change with much wider blast radius than this fix needed.

**Actual fix**: a new `check_literal_fits_refined loc e target` helper in
`type_inf.ml`, called immediately alongside `unify_at` at every site where
an expression flows into an already-declared target type: `Let`,
`Assign`, `AssignDeref`, `AssignIndex`, `AssignField`, `Return`, function
call arguments, and (via `check_expr`'s existing recursive base case, so
nested/array struct literals are covered automatically) `StructLit`
fields. Reuses `Const_env.bound_value` -- already the file's standard
"is this expression a compile-time-known integer" resolver (e.g.
`collect_bounds`'s `range_of`) -- rather than adding a second, parallel
literal-detection mechanism: if `target`'s `repr` is `TRefinedInt (lo, hi,
_)` and the expression resolves to a known constant `k` outside
`[lo, hi)`, this is now a compile-time `TypeError` naming the actual
value and the range it failed to fit. A non-constant expression (a
variable, a computed value) is left entirely alone -- the PRE-EXISTING
anti-subtyping guard (`t1, TRefinedInt (lo, hi, base) when t1 = repr
base -> ...`) already correctly rejects an unproven plain-base value
flowing into a refined target, confirmed still working via its own
negative-control test below.

**A 9th site found on a deliberate follow-up completeness audit, after
the user asked what a "fix every call site by hand" approach actually
guarantees vs. a structural one.** Re-walked every `unify`/`unify_at`
call site in `type_inf.ml` by hand (not just the ones noticed while
writing the fix) to check whether the enumerated-list approach had truly
covered every "value flows into an already-declared refined type"
boundary. Found one real gap: `Cast`'s handling of an EXPLICIT `x as
{lo..<hi as base}` target (as opposed to the *bare*-cast-inference form
issue #72 added) fell through to a final `| _ -> tgt` arm that returned
the written target type with no check against the source at all --
`20 as {0..<8 as usize}` compiled cleanly, same bug, 9th call site.
Fixed the same way as the other 8. Also specifically checked the global-
initializer "reference another global by name" path (`let B: {0..<8 as
usize} = SOME_OTHER_GLOBAL;`) since it has its own separate `unify` call
outside the general expression case -- confirmed this one was already
safe without needing the new check: an unrefined global reference hits
the pre-existing anti-subtyping guard and is correctly rejected already
(with a less precise error message than the new check would give, but
soundly rejected either way), so it was left alone. This 9th find is
itself the concrete answer to "how do you know the enumerated list is
complete": it wasn't, on the first pass -- the fix only reaches the
soundness guarantee for sites someone actually thought to check, not
automatically for the whole class, which is exactly the tradeoff
against the rejected "change IntLit's own type" approach discussed with
the user.

**Verification**: 12 unit tests in `test/test_takibi.ml` (one per call
site including the 9th, plus a positive control confirming the already-
working struct-field mechanism keeps compiling with zero trap sites, plus
a negative control confirming the pre-existing unproven-value rejection
is untouched) -- `dune test` 491/491. A new example,
`examples/struct_refined/struct_refined.tkb`, demonstrates the feature
end to end (a refined struct field written/read directly, through a
pointer, and through an array element, all with zero trap sites) and was
added to both the QEMU suite (`scripts/run_qemutest.sh`) and the STM32
hardware suite (`scripts/run_hwtest_ram.sh`), verified passing on real
hardware. `make check` (72/72), `make hwcheck` (45/45), and
`make langcheck` all pass with no regressions -- no existing example in
the whole codebase had ever accidentally relied on the unsound literal-
acceptance behavior.

**Files**: `lib/type_inf.ml` (new `check_literal_fits_refined`, called
from 9 sites: `Call`, `Return`, `Assign`, `AssignDeref`, `AssignIndex`,
`AssignField`, `Let`, `Cast`'s explicit-refined-target arm, `check_expr`'s
base case, plus the global-initializer scalar path), `test/test_takibi.ml`
(12 new tests), `examples/struct_refined/struct_refined.tkb` + `.expected`
(new example), `Makefile`, `scripts/run_qemutest.sh`,
`scripts/run_hwtest_ram.sh` (wired the new example into both suites),
`SPEC.md` (documented refined struct fields under "Structs").

## GitHub Issue #102: Provable Pointer Alignment -- Filed, Not Started

Follow-up from issue #100's investigation: `examples/common_stm32/
sdmmc.tkb`'s `disk_read` cannot safely call `dma_prepare_rx`/
`dma_finish_rx` (cache-line INVALIDATE operations) directly on the
caller's own `buf: *u8` parameter, because a raw pointer carries no
alignment guarantee the type system can check -- see this file's issue
#101-follow-up entry above for the real HardFault this caused and the
`align(32)` bounce-buffer workaround it needed instead. The user asked
whether this points at a real future language feature: a pointer
analogue of a refined integer's `{lo..<hi as base}` -- i.e. a type that
lets a function REQUIRE "this pointer is provably N-byte aligned" and
have the compiler check it, the same way `{lo..<hi as base}` lets a
function require a provable integer range today.

Discussed but deliberately NOT scoped or started this session (YAGNI --
no concrete driving requirement beyond `disk_read`'s bounce buffer, which
already works without it). Genuinely large in scope if pursued: unlike
integer range tracking (which only needs to reason about arithmetic on
plain values), alignment propagation through pointer arithmetic,
aliasing, struct-embedded pointers, and casts is a different and harder
proof problem -- neither Rust's `#[repr(align(N))]`/`std::ptr::is_aligned`
nor C/C++'s `alignas`/`assume_aligned` attempt to statically PROVE
alignment survives arbitrary pointer arithmetic; they only let a
programmer assert it (checked, if at all, at runtime). Filed as GitHub
issue #102 ("Provable pointer alignment (safe pointers follow-up)") to
record the motivating case and revisit only when a second, real driving
need shows up -- not as a "let's go build it" backlog item.

**Files**: none (issue filed on GitHub only, no code or doc changes this
session beyond this entry).

**Superseded**: see the later "`*align(N) T` -- Provable Pointer
Alignment Implemented" entry near the end of this file for the actual
Stage 1 implementation, once a second driving discussion (with Fable)
made the case for building the type now rather than continuing to wait.

## GitHub Issue #103: `IntLit` Literals Carry No Value Into `unify()` -- Systemic Alternative to Issue #100's Per-Call-Site Fix, Tried and Reverted

Issue #100's actual fix (`check_literal_fits_refined`, see that entry
above) is an ENUMERATED list of 9 call sites, not a structural guarantee
-- a future call site (new syntax, a new AST case) needs someone to
remember to add the check there too. The user asked how hard the
structurally-sound alternative would be: instead of `IntLit _ -> fresh
()` (a literal's inferred type is a plain, unconstrained type variable,
see `type_inf.ml`'s `infer_expr`), give a literal `k` the type
`TRefinedInt (k, k+1, fresh_base)` at the point of inference -- the
value becomes part of the type itself, so `unify`'s EXISTING
`TRefinedInt`-vs-target subtyping rules would validate it automatically,
everywhere `unify` is ever called, with no enumerated list to maintain
or ever fall behind.

**Tried as a one-line, fully-reverted experiment** (`IntLit k -> (match
Ast.int_of_intlit k with Some v -> TRefinedInt (v, v + 1, fresh ()) |
None -> fresh ())`, `dune test` run, then the change reverted in full --
`git diff` on `lib/type_inf.ml` confirmed clean afterward). Result: 27 of
491 unit tests failed, exposing three independent, non-trivial problems,
not one:

1. **`check_undetermined_lets` doesn't see through the wrapper.** It
   tests for a bare unbound type variable to decide whether a `let`
   needs an explicit type annotation; a literal's type is now
   `TRefinedInt (_, _, TVar (Unbound _))`, so the check stops recognizing
   the undetermined case correctly (`let x = 5;` with no other use
   determining `x`'s type wrongly demanded an annotation it didn't need
   before). Fixable in isolation, but its own piece of work.
2. **`TRefinedInt`'s bounds are native OCaml `int` (63-bit), not
   `Int64`.** A full-width 64-bit literal (e.g. `0xFFFFFFFFFFFFFFFF`)
   computing `v + 1` for the new upper bound overflows OCaml's own
   arithmetic, producing nonsense ranges like `{-1..<0}` (confirmed via
   `"cannot unify {-1..<0} with u64"` errors on the existing 64-bit-
   literal test suite). `IntLit`'s own AST payload is already `Int64.t`
   for exactly this reason (see this file's "64-bit Integer Literals"
   entry) -- `TRefinedInt` never had to be, until this experiment.
3. **The most serious: `TRefinedInt`-vs-`TRefinedInt` unification
   requires an EXACT bounds match** (`lo1 = lo2 && hi1 = hi2`), a
   deliberate issue #72 design decision needed so a refined value
   crossing a function-parameter boundary can't silently widen or narrow
   its proof. A literal's own range under this experiment is always a
   singleton `{k..<k+1}`. Assigning it to any WIDER refined target
   (`{0..<8}`, the overwhelmingly common real-world case) now failed
   outright: `f.idx = 3;` where `idx: {0..<8 as usize}` -- ordinary,
   currently-working code, not an edge case -- broke with `"refined int
   range mismatch: {3..<4} vs {0..<8}"`. Making this work would require
   changing `TRefinedInt`-vs-`TRefinedInt` unification from exact-match
   to interval-containment (subtyping) for at least this direction,
   risking a weakening of the exact-match guarantee issue #72
   deliberately put in place for parameter boundaries -- a second,
   independently large redesign question uncovered by the same
   one-line experiment, not a detail to patch around.

**Conclusion**: not a quick follow-up to issue #100. Three separately-
hard sub-problems, each touching a different part of the type system
(undetermined-type detection, `TRefinedInt`'s internal representation,
and the core subtyping rule for refined-to-refined unification), and
problem 3 specifically conflicts with an existing, deliberate design
decision (issue #72's exact-match rule) that would need to be
re-examined, not just patched around. Filed as GitHub issue #103 with
this full writeup so a future session can pick the investigation back up
without re-deriving it from scratch. Decision for now: keep the
enumerated `check_literal_fits_refined` approach from issue #100;
revisit the systemic fix only as its own dedicated, scoped effort.

**Files**: none in the final state (`lib/type_inf.ml`'s `IntLit` case is
back to `IntLit _ -> fresh ()`, unchanged from before this experiment;
issue filed on GitHub only).

## GitHub Issue #97: `http_server_sdcard` -- Real SD Card Content Served Over HTTP, Fully Automated Provisioning

The TCP/IP stack goal (`examples/http_server`) and the FAT12-on-real-SD-card
milestone (issues #61/#62/#98, `examples/fatfs_sdcard`) meet here:
`examples/http_server_sdcard` serves the real content of a file on the
STM32F746G-DISCOVERY board's SD card, over HTTP, to a real browser.

**Milestone choice over Simple RTOS (issue #66)**: the user had been leaning
toward building a Takibi-native RTOS next, motivated by a real incident
(issue #101's UART/SD card interaction bug, which stemmed from a
polling-based wait -- a pattern this project has since eliminated
everywhere). Investigated and recommended `http_server_sdcard` first
instead, on the grounds that: (1) UART, Ethernet, and SD card are all
already interrupt/DMA-driven individually, so combining them needs no
scheduler at all -- verified concretely by reading `interrupt_wait()`'s
actual implementation (a global retained wfe/sev event; each driver sets
its own flag and re-checks it after waking, so spurious cross-device
wakeups are already handled correctly); (2) issue #66 itself already had a
detailed self-analysis on file concluding that the project's existing
preempt/semaphore/condvar/msgqueue/watchdog examples already ARE an RTOS's
core primitives, and that building further RTOS features without a
concrete driving requirement would be premature (YAGNI). `http_server_sdcard`
was judged more likely to surface a *genuine* concrete RTOS requirement (if
any) than building one speculatively first -- confirmed true: the milestone
shipped with a single flat `app_main()` loop, no scheduler needed.

**Original Stage 1 scope (deliberately incremental)**: any GET request
returned the same fixed file's content (`INDEX.TXT`), read fresh from the
card on every request. No path parsing, no directory listing, no multiple
files -- it proved the wiring (HTTP -> FAT12 -> SDMMC1 -> real card bytes
-> HTTP response) end to end first.

**Current scope after the later HTTP+SD follow-ups**: GET `/` maps to
`INDEX.HTM`, simple single-component 8.3 paths such as `/ABOUT.HTM` and
`/ICON.PNG` map to their corresponding FAT12 names, and larger responses
are streamed as multiple TCP segments (one chunk per client ACK, still one
connection at a time and `Connection: close`). Directory listings, long
filenames, nested paths, and richer MIME handling remain out of scope.

**SD card content is mounted, never formatted** (`fat_mount()`, not
`fat_format()`) -- unlike `fatfs_sdcard.tkb`, which formats and writes fixed
demo content on every run. The whole point of this milestone is showing the
card's own, externally-provisioned content. Verified end to end by hand:
loaded real content onto the card, served it over HTTP to a real Firefox
tab, then physically removed the card, mounted it on a PC, and confirmed the
then-served file (`INDEX.TXT` at the original stage, later replaced by
`INDEX.HTM`/`ABOUT.HTM`/`ICON.PNG`) was exactly what a normal file manager
also saw -- real interop with a real filesystem, not just an internal round
trip.

**Fully automated SD card provisioning -- no human ever touches the card**,
for both `make hwcheck-net` and the interactive `make stm32-http-server-sdcard`
demo target. This went through two designs before landing:

1. First idea: have the demo binary itself write the card at boot
   (`fat_format()` + fixed content, matching `fatfs_sdcard.tkb`'s own
   approach). Rejected -- the whole point of this milestone is showing a
   real, externally-provisioned card's content, not manufacturing fake
   content on every boot.
2. Physically swapping the card into a host-side reader and writing it with
   `mformat`/`mcopy` (the same mtools workflow `examples/fatfs`'s own test
   harness already uses) was considered next, and explicitly rejected by the
   user: this project's hardware test suites (`make hwcheck`/`make
   hwcheck-net`) are a hard requirement to run unattended, with zero human
   intervention, matching every other test in this repo.
3. Landed on: `scripts/provision_http_server_sdcard.sh` builds a real FAT12
   image on the host with `mformat`/`mcopy` (same geometry as
   `examples/common/fat12.tkb`'s own `SECTOR_SIZE`/`TOTAL_SECTORS`), then
   runs a small new firmware, `examples/http_server_sdcard_install/
   http_server_sdcard_install.tkb`, via OpenOCD -- the exact same
   RAM-injection technique `scripts/run_hwtest_ram.sh`'s existing
   `ram_load_and_run_seeded` already uses for `examples/fatfs`'s in-memory
   `disk` array (a breakpoint at `app_main`'s own entry, `load_image` the
   host-built FAT image directly into a `staging` global's RAM address,
   remove the breakpoint, resume), except this firmware then *relays* the
   staged bytes onward through the real SDMMC1 driver (`disk_write`,
   sector by sector) instead of just leaving them in RAM for the CPU to
   read directly. A second breakpoint, on a dedicated `install_done()`
   function called only after every `disk_write` has returned, gives the
   harness a hard synchronization point (`wait_halt`) for "the real SD
   card write has genuinely finished" -- no UART-quietness guessing needed.
   `install_result` (a `u32` global: 1 = OK, 2 = `disk_initialize()` failed
   -- most likely no card in the slot, 3 = a `disk_write` genuinely
   failed) is read back at that same halt via OpenOCD's `mrw`, giving the
   harness a precise, deterministic status instead of scraping UART text.
   `scripts/provision_http_server_sdcard.sh` is shared, not duplicated,
   between `make hwcheck-net` (`scripts/run_hwtest_net_ram.sh`) and the
   standalone `make stm32-http-server-sdcard` Makefile target -- the latter
   is fully self-contained (does not depend on `hwcheck-net` having run
   first) and stops with a clear error message (not a silent 404 the user
   would have to debug from a browser tab) if the card is missing or a
   write genuinely fails.

**Latent duplicate-global collision found and fixed**: `examples/common_stm32/
eth.tkb` and `examples/common_stm32/sdmmc.tkb` had never been compiled
into the same program before this milestone (no prior example needed both
Ethernet and SD card). `http_server_sdcard.tkb` is the first to `use` both,
which exposed that both files independently declared `RCC_AHB1ENR`/
`RCC_APB2ENR` (both configure RCC peripheral-enable bits) and `GPIOC_MODER`/
`GPIOC_OSPEEDR` (both configure GPIOC pins -- `eth.tkb` for RMII,
`sdmmc.tkb` for SDMMC1 D0..D3/CLK) at identical addresses -- caught
immediately by the existing GitHub issue #79 duplicate-global-name check.
Fixed the same way `examples/common_qemu/gic_regs.tkb` was split out of
`gic.tkb` for the same reason: extracted the four colliding declarations
into a new shared file, `examples/common_stm32/eth_sdmmc_regs.tkb`, `use`d
by both `eth.tkb` and `sdmmc.tkb`. Confirmed the other 7 existing consumers
of either file (5 real-Ethernet examples, `sdcard`, `fatfs_sdcard`) still
build and pass their hardware tests unchanged.

**`stm32-http-server-sdcard`'s URL display was broken from the start**
(found while building its own version of `stm32-http-server`'s existing
URL-announcing logic, which turned out to already be broken too):
`netconfig.tkb`'s `HTTP_SERVER_IP` had at some point been refactored from a
literal `{192, 168, 10, 2}` initializer to `= OUR_IP` (an alias, to prevent
the two constants drifting apart -- see the STM32 Ethernet section), but
the Makefile's `grep -oP '\{[^}]*\}'` IP-extraction one-liner was never
updated to follow that indirection, so `make stm32-http-server` had been
silently printing `Open http:///` (empty) ever since that refactor landed.
Fixed by resolving one level of `Var` aliasing in the shell extraction
logic before falling back to the literal-array pattern; applied to both
Makefile targets since they share the exact same broken one-liner.
Confirmed fixed by hand (`Open http://192.168.10.2/` now prints correctly
for both).

**--forbid-trap**: written and verified against real hardware without it
first (per this project's established process), then turned on once the
whole milestone (both `http_server_sdcard.tkb` and the installer) worked
end to end. `http_server_sdcard.tkb` itself needed zero fixes (its only new
logic is a fixed-size `fat_read` into a 512-byte buffer matching that
buffer's own declared size; everything else reuses `http_server.tkb`'s
already-proven slice-based logic unchanged). The installer needed one: its
sector-copy loop (`staging[off + i]`, `off = s * SECTOR_SIZE`) used a
plain `while (s < TOTAL_SECTORS as u32)` loop, giving `s` no provable
range. Fixed by converting to `for s: usize in 0..<TOTAL_SECTORS` (matching
`TOTAL_SECTORS`'s own declared `usize` type -- a `for s: u32 in
0..<TOTAL_SECTORS` loop does NOT typecheck, since `TOTAL_SECTORS` is
`usize`-typed from its own declaration and this language has no implicit
int-width coercion; nothing for-loop-specific about that failure, `let s:
u32 = TOTAL_SECTORS;` without a cast fails identically), with a single `as
u32` cast only where `disk_write`'s signature needs it. This is the same
if-narrowed-multiplier-times-for-loop-offset proof shape `examples/common/
fat12.tkb`'s own `mem_block_read`/`mem_block_write` already use for the
identical "byte i of sector s in a flat buffer" pattern -- confirmed the
Mul/Add interval-propagation math is exact here (not the naive lo*c..hi*c
scaling one might assume), matching the `doff * 4` example already
documented elsewhere in this file.

**Files**: `examples/http_server_sdcard/http_server_sdcard.tkb` (new),
`examples/http_server_sdcard_install/http_server_sdcard_install.tkb` (new),
`examples/common_stm32/eth_sdmmc_regs.tkb` (new), `examples/common_stm32/
eth.tkb` / `examples/common_stm32/sdmmc.tkb` (duplicate-global split),
`scripts/provision_http_server_sdcard.sh` (new), `scripts/
eth_http_server_sdcard_test.py` (new), `scripts/run_hwtest_net_ram.sh`
(new test entries, both RAM and Flash variants), `Makefile`
(`STM32_RAM_EXAMPLES`, new `.o`/`.elf`/`.bin` rules, `stm32-http-server-sdcard`
target, IP-extraction fix applied to both HTTP demo targets).

## Bool-Only `if`/`while`/`&&`/`||` Conditions (No C-Style Int-Truthy Coercion)

Found while reviewing `http_server_sdcard`'s design: `check_cond` (the
function gating `if`/`while`/`&&`/`||` operand types) accepted `bool` OR
unified the condition against `TI32` -- not general C-style "any integer is
truthy" (a genuinely non-bool-typed variable like `u32`/`u8`/`u64` was
ALREADY rejected: `cannot unify u32 with i32`), just an inconsistent,
i32-only special case whose only real effect was letting `while (1)`
-style integer literals work as an infinite-loop idiom. Compared against
Rust and Zig (both strictly bool-only, no exception for literals either --
`while true {}` is the only spelling in both) and against this project's
own MMIO-heavy code, which already always writes explicit bit-mask/
comparison checks (`if ((ocr & 0x80000000) != 0)` in `sdmmc.tkb`) rather
than relying on any implicit truthiness -- the hardware-interfacing
argument for keeping C's looser rule didn't hold up. Decision: match
Rust/Zig, bool-only, closing off the classic C `if (x = 5)`
assignment-vs-comparison-typo class of bug at compile time (this project's
explicit "detect errors at compile time" design principle). Migration
scope was small and fully mechanical: exactly 8 `while (1) { ... }` sites
across the whole example suite (all the same "infinite main loop" idiom:
`net_echo`, `arp_reply`, `icmp_echo`, `tcp_echo`, `http_server`,
`http_server_sdcard`, `echo`, `eth.tkb`), all converted to `while (true)`
with no logic changes.

**A genuine soundness gap found while implementing the naive fix.** The
first attempt, `check_cond loc ct = unify_at loc ct TBool` (replacing the
old `TBool -> () | _ -> unify_at loc ct TI32` match), made `while (1)`
"type-check" -- WRONG -- and then crash at codegen instead
(`Fatal error: ... as_cond expected i1 (bool), got i32`). Root cause: a
bare integer literal's inferred type (`IntLit _ -> fresh ()`, "polymorphic:
unifies with any integer type via context") is a genuinely UNCONSTRAINED
type variable at that point, not merely integer-flavored -- `unify_at ct
TBool` happily binds it to `TBool` structurally, same underlying mechanism
already documented for issue #100's refined-range soundness hole
(`check_literal_fits_refined`'s own header comment), just manifesting for a
`bool` target instead of a numeric range. Confirmed via a minimal repro
(`let x: bool = 1;` -- a completely unrelated code path from `check_cond`,
also silently accepted, also pre-existing and unrelated to this session's
changes) that this is a structural gap in how `IntLit`'s `fresh()` type
variable interacts with unification generally, not something specific to
condition-checking.

**Fixed at both the narrow site and the general one.** `check_cond` gained
an explicit branch: `TVar { contents = Unbound _ }` (an expression whose
type was never pinned by anything -- which, empirically, only a bare or
bare-arithmetic literal expression can produce by the time a condition is
checked) is rejected directly with a purpose-written message
("condition must be bool -- a bare integer literal has no boolean value;
use `true`/`false` or an explicit comparison"), never reaching `unify_at`
at all. Separately, and more generally: `check_literal_fits_refined`
(issue #100's existing "does a literal-or-Const_env-constant expression
flowing into an already-known target type actually fit" check, already
wired into 10 call sites -- `Let`, `Assign`, `AssignDeref`, `AssignIndex`,
`AssignField`, `Return`, `Call` arguments, `StructLit` fields) gained a
`TBool` arm alongside its existing `TRefinedInt` one: any integer literal
flowing into a `bool`-typed target is rejected unconditionally (unlike the
`TRefinedInt` case, there's no "does the value fit" question -- ANY
integer literal is invalid for `bool`). Because it reuses `Const_env.
bound_value` (the same "is this expression a compile-time integer"
resolver issue #100 already established) at sites that already existed,
this ONE match arm closes every instance of the gap at once: `let x: bool
= 1;`, `return 1;` from a `-> bool` function, and passing a literal for a
`bool` parameter were all confirmed broken before the fix and fixed after,
with zero changes needed anywhere else. Confirmed the whole example suite
(72 QEMU + 45 hardware + 8 Ethernet-hardware tests, at the time) still
passes unchanged -- neither new check found an actual logic bug anywhere
in existing example code, only the 8 syntactic `while (1)` sites needed
touching.

**A second, unrelated compiler bug found while writing new code for this
session** (not found BY either of the above checks -- found because new
`.tkb` code exercised a code path nothing had ever exercised before):
`lib/llvm_gen.ml`'s `gen_global` has its own separate compile-time-constant
folding function (distinct from the top-level `eval_const_int`, which
already had a working `BoolLit b -> if b then 1L else 0L` case) with no
case for `BoolLit` at all -- so `let mut flag: bool = false;` (or `true`)
as a GLOBAL initializer failed with `"global initializer: unsupported
constant expression"`, regardless of the value. Nobody had ever written a
literal-initialized `bool` global in this codebase before (every existing
`bool` global was either uninitialized/BSS-zeroed, like
`ff_writing`-style flags added later, or assigned via an enum-style
non-literal expression) -- first hit while adding `examples/common/
fat12.tkb`'s `ff_is_open: bool = false;` (see the `FatFile` entry below).
Fixed with one added match arm, `BoolLit b, TypeBool -> const_int
(ltype_of_ast ft) (if b then 1 else 0)`, mirroring `gen_expr`'s own
`BoolLit` case exactly.

**New permanent regression coverage** (this codebase's existing
`run_compile_error_test` convention -- a `.tkb` file paired with a
`.error` file containing an expected error substring, wired into
`scripts/run_qemutest.sh`, e.g. `refined_assign_mismatch`,
`forbid_trap_wrong`): `examples/cond_not_bool` (the `while (1)` case) and
`examples/affine_double_consume` (a first-ever permanent negative test for
the affine-handle double-consume/use-after-release checker itself -- it
had unit-test coverage in `test/test_takibi.ml` since it was built, but no
examples-level end-to-end test until now). Also added 9 new unit tests to
`test/test_takibi.ml` directly covering the bool-only-condition change
(both the `check_cond` and the `check_literal_fits_refined` fixes,
positive and negative cases).

**Files**: `lib/type_inf.ml` (`check_cond`, `check_literal_fits_refined`),
`lib/llvm_gen.ml` (`gen_global`'s `eval_const`, `as_cond` simplified to
assert i1 rather than silently coerce -- its old int-to-i1 `icmp ne 0`
fallback is now genuinely unreachable, since every one of its 4 call sites
corresponds exactly to a `check_cond` site that now guarantees `TBool`),
`test/test_takibi.ml` (9 new tests), the 8 `while (1)` -> `while (true)`
sites listed above, `examples/cond_not_bool/` (new), `examples/
affine_double_consume/` (new), `scripts/run_qemutest.sh` (2 new
registrations), `SPEC.md` (documented the rule, which had never been
written down).

## GitHub Issue #97 Follow-up: `FatFile` as an Affine Opaque Handle, and the Single-Instance Consequence It Surfaced

Prompted by a direct question about whether `examples/common/fat12.tkb`'s
`fat_open`/`fat_close` could get ATS2-style linear-file-handle guarantees:
`fat_close` only reachable on a value `fat_open` actually produced, no
double-close, no use-after-close. `examples/common_stm32/eth.tkb`'s
existing `NetRxCpuOwned` (`affine opaque struct`, built for issue #62-era
RX descriptor ownership) was already exactly this pattern for a different
resource, and needed zero new compiler features to reuse.

**Refactor**: `FatFile` changed from a plain (non-opaque, real-fields)
struct with an output-parameter `fat_open(fp: *FatFile, ...) -> i32` API to
`affine opaque struct FatFile;` with `fat_open(...) -> *FatFile` (a token
pointer, `0 as usize as *FatFile` on failure -- matching `net_rx_acquire`'s
own null-on-unavailable convention exactly), `fat_read`/`fat_write` taking
`borrow *FatFile` (non-consuming, callable any number of times), and
`fat_close(fp: *FatFile) -> i32` consuming it. Confirmed by hand that all
three violations are now compile errors instead of silent bugs: a bare
`let mut fp: FatFile;` ("opaque struct 'FatFile' is incomplete and may
only be used behind a pointer"), `fat_close(fp); fat_close(fp);` a second
time ("affine value 'fp' was already consumed"), and using `fp` in
`fat_read`/`fat_write` after `fat_close(fp)` (same error). All 4 existing
callers (`examples/common/fat12.tkb`'s own `create_demo_file`,
`examples/fatfs/fatfs.tkb` x2, `examples/fatfs_sdcard/fatfs_sdcard.tkb`,
`examples/http_server_sdcard/http_server_sdcard.tkb`) updated to the new
pointer-returning, null-checked call shape.

**Realization, prompted directly by the user, not found independently
while implementing**: `NetRxCpuOwned` has the *identical* structural
limitation `FatFile` was about to gain, and this had gone unremarked
during its own original implementation. Root cause: `affine opaque struct`
is, by grammar, ALWAYS field-less (`AFFINE OPAQUE STRUCT IDENT SEMI` --
there is no syntax to give it a field list, even within the declaring
file), so any real per-instance state has nowhere to live except ordinary
globals, and every `make()`-style constructor built on this pattern
(`net_rx_acquire`, now `fat_open`) hands back the SAME fixed address every
time (`&net_rx_token_storage`, `&fat_file_token_storage`). Consequence:
only one live (acquired-but-unreleased) handle of a given type can exist
system-wide at once. For `NetRxCpuOwned` this happens to match its real
requirement exactly (the RX descriptor ring, not this CPU-ownership token,
is where buffering depth actually lives -- the driver only ever has one
CPU-owned frame in flight by design). For `FatFile`, it matches
`fat12.tkb`'s own pre-existing, already-documented scope ("no multiple
simultaneously-open files" was stated in that file's header comment before
this refactor too) -- nothing regressed, but the limit is now type-enforced
rather than by-convention, and additionally required a new explicit guard
(`ff_is_open: bool`, checked at the start of `fat_open`) since the affine
checker itself has no way to see across two independently-acquired handles
of the same type -- without it, a second `fat_open()` before the first
`fat_close()` would silently corrupt the still-open first handle's state
by overwriting the shared `ff_*` globals.

**Design discussion, deliberately not acted on**: whether to pursue
extending the language to decouple `affine` from `opaque` (letting an
affine type carry real, per-instance fields) so multiple concurrent
instances become possible. A pool-of-N-tokens workaround (encode a slot
index into the token pointer's own numeric value via pointer arithmetic)
was proposed and explicitly rejected as actively counterproductive --
routing real structure through a pointer's bare numeric identity would
have to be torn out again once a real fix exists, not be a step toward
one. The harder, genuinely open question surfaced by that discussion: even
decoupling `affine` from `opaque` only solves "no more than one instance,"
not "was this value actually produced by `fat_open`" -- with real, visible
fields, nothing would stop a caller declaring a garbage/uninitialized
`FatFile` and passing it straight to `fat_read`. Rust solves that
specific problem with a THIRD, independent mechanism (module-private
fields + a smart constructor), not affine-ness itself -- a form of
file-scoped field visibility this language does not have today, entangled
with neither `affine` nor `opaque` as currently implemented. Also
discussed and left open: whether "must eventually be consumed" (the
still-missing linear/drop-check half of issue #89) should be RAII-style
(auto-inserted cleanup at scope exit, unless explicitly moved out --
Rust's `Drop`, requires real move-aware analysis to correctly recognize
"returned, so no cleanup needed on this path," a case a naive
scope-exit-insertion rule would get wrong) versus something closer to
ATS2's at-views (a function's return TYPE explicitly documents which
obligations it hands to the caller, rather than relying on implicit
scope-based insertion or a separate whole-body "was it dropped" proof
pass) -- raised specifically because a legitimate, common embedded-C
pattern (a function that opens a resource and returns it, unclosed, *by
design*, for the caller to close later) needs to keep compiling cleanly,
and the user's own experience was that Rust's default RAII posture reads
as too rigid for that pattern even though a properly move-aware
implementation would in fact handle it correctly. Recorded as a comment on
GitHub issue #89 (by the user directly, not via an automated post) rather
than acted on now -- only two real use cases exist in this codebase so
far, enough to see the *structural* problem (the `affine`/`opaque`
coupling being an implementation shortcut, not a fundamental necessity)
but not enough to responsibly design a general resource-typestate
mechanism around. `fat12.tkb` and `eth.tkb` keep the pragmatic "global
variables + `affine opaque struct`" approach for now.

**A concrete control-flow gap found while restructuring `create_demo_file`
for the new API**, relevant to any future "must consume" design: the
current checker's `If` case unions each branch's consumed-set
unconditionally, with no awareness that a `return`-terminated branch can't
affect code after the `if`. `if (fat_write(fp,...) != 0) { fat_close(fp);
return -1; } return fat_close(fp);` (no `else`) is rejected ("affine value
'fp' was already consumed") even though the two `fat_close(fp)` calls are
on mutually exclusive paths -- confirmed by minimal repro before touching
the real code. Worked around by making the `else` explicit (`if { ... }
else { return fat_close(fp); }`), which the checker handles correctly
(confirmed separately: unioning two branches that EACH independently
consume the value, with nothing after the `if` at all, works fine). This
exact behavior turned out to already be correctly documented in `SPEC.md`'s
Affine Opaque Structs section ("consuming a handle in only one branch is
allowed; ... the moved-sets of every branch/arm are unioned") -- the gap
was in this session's own awareness of that documented rule, not in the
documentation itself.

**Files**: `examples/common/fat12.tkb` (`FatFile` struct removed, replaced
by `ff_*` globals + `affine opaque struct FatFile;` + `fat_file_token_storage`
+ `ff_is_open` guard; `fat_open`/`fat_read`/`fat_write`/`fat_close`/
`create_demo_file` signatures and bodies), `examples/fatfs/fatfs.tkb`,
`examples/fatfs_sdcard/fatfs_sdcard.tkb`, `examples/http_server_sdcard/
http_server_sdcard.tkb` (all 4 call sites updated to the pointer-returning
API), `lib/llvm_gen.ml` (the `BoolLit` global-initializer fix, needed by
`ff_is_open`'s own `= false` initializer -- see the entry above), `SPEC.md`
(documented the field-less-opaque-implies-global-singleton consequence,
which had never been written down despite `NetRxCpuOwned` already
exhibiting it).

## Documentation Audit: Stale `--forbid-trap` Headers, Broken Cross-References, Drifted Counts

Prompted by a direct request to review `README.md`/`SPEC.md`/`CLAUDE.md`/
`HISTORY.md` for staleness following the `http_server_sdcard` milestone.
Found one concrete stale item early (`examples/fatfs_sdcard/fatfs_sdcard.tkb`'s
header still described `--forbid-trap` as a future step, even though the
Makefile already had it enabled before this session started), then commissioned
a systematic audit (a background agent, verifying each candidate claim
against the live repo rather than trusting wording alone) once the pattern
looked likely to recur elsewhere. Confirmed findings, all fixed:

- **Four more files with the identical stale-header pattern**: `examples/fatfs/
  fatfs.tkb`, `examples/sdcard/sdcard.tkb`, `examples/common/fat12.tkb`, and
  `examples/common_stm32/sdmmc.tkb` all still described `--forbid-trap` as
  "not yet turned on" in prose, despite the Makefile having enabled it for
  all of them since the original fatfs+SD-card milestone (issues #61/#62/#98)
  closed. All five headers (including `fatfs_sdcard.tkb`) rewritten to past
  tense, describing what was actually done rather than what was still planned.
- **`CLAUDE.md`'s Directory Layout was missing several files**, some
  pre-dating this session entirely: `lib/type_layout.ml` (struct/enum layout
  table backing `sizeof`/`offsetof`, issue #40) and `lib/use_resolver.ml`
  (`use` dependency resolution, issue #55) were absent from the `lib/`
  listing; `examples/common/fat12.tkb`, `examples/common_qemu/
  semihosting_asm.S`, `examples/common_stm32/sdmmc.tkb`, and `examples/
  common_stm32/semihosting_stub.S` were all absent from their respective
  directory listings. All added, plus today's new `eth_sdmmc_regs.tkb` and
  `scripts/provision_http_server_sdcard.sh` (the new example directories
  themselves, `http_server_sdcard`/`http_server_sdcard_install`, needed no
  new entries -- the existing `<name>/` catch-all line already covers every
  individual example directory generically).
- **A dangling cross-reference**: `CLAUDE.md`'s `sizeof(T)` bullet said "see
  the `sizeof(T)` section above," but that section was moved to `HISTORY.md`
  during the 2026-07-08 CLAUDE.md/HISTORY.md split and the pointer was never
  updated -- fixed to point at HISTORY.md's actual "sizeof(T) Spans 4 Files"
  entry.
- **Two drifted counts**: `STM32_RAM_ELFS`'s "50 as of this writing" is now
  55 (the passage already told readers to verify the variable directly
  rather than trust the number, so this was low-severity, but the literal
  figure was still updated); "all five [STM32 Ethernet] examples" is now six
  (`http_server_sdcard` added today) and a "all 6 `hwcheck-net` tests pass"
  historical claim (accurate at the time it was written, about
  `http_server`'s Flash-boot test addition) is now 8 -- reworded to make
  clear it was a point-in-time count, not a claim about today's total.

Deliberately kept every `CLAUDE.md` addition to a one- or two-line pointer
(net growth: 1347 -> 1373 lines, +26, despite 8 distinct fixes) -- the
substantive narrative for all of today's work lives here in HISTORY.md
instead, per this project's existing 2026-07-08 split rationale (keep
CLAUDE.md inside Claude Code's context budget).

**Files**: `examples/fatfs_sdcard/fatfs_sdcard.tkb`, `examples/fatfs/
fatfs.tkb`, `examples/sdcard/sdcard.tkb`, `examples/common/fat12.tkb`,
`examples/common_stm32/sdmmc.tkb` (header comments), `CLAUDE.md` (Directory
Layout, `sizeof(T)` cross-reference, two count corrections).

## Intermittent DWARF Test Failure: Disabled, Not Retried-Around

`scripts/run_qemutest.sh`'s `run_dwarf_test "fizzbuzz (dwarf)"` (checks that
`llvm-dwarfdump-19 --debug-line` on a `-g` build's `kernel.debug.elf`
contains `fizzbuzz.tkb` in its `file_names` table) turned out to be
intermittently flaky, discovered by chance across several `make check`/
`make qemutest` runs earlier in this session (retried and passed both
times, which is exactly the kind of "it went away, move on" response that
was then explicitly flagged and rejected: retrying without understanding
hides whatever the real timing issue is, rather than fixing or even
confirming it).

**Investigated properly instead of retried around**: reproduced directly
with `make clean && make qemutest` in a loop (2 failures in 3 consecutive
runs -- not a rare one-off). The failure is `"fizzbuzz.tkb missing from
DWARF file_names table"`. Critically, inspecting the exact `kernel.debug.elf`
left on disk by a failing run, by hand, immediately afterward, with no
rebuild, found `fizzbuzz.tkb` correctly present in `file_names[5]` --
**the generated DWARF data is correct**; only the test's read of it,
happening immediately after `ld.lld-19` finishes linking, sometimes doesn't
see it. This rules out a compiler/DWARF-emission bug.

An initial hypothesis (devcontainer/overlayfs-specific filesystem
coherency, given the timing sensitivity and the container's storage
driver) was raised and then corrected by the user with direct
counter-evidence: the identical intermittent failure also reproduces on
`make check` on a bare/native Linux install with no container involved at
all. Whatever the actual mechanism is, it is not specific to this
project's devcontainer.

**Disabled outright** (`run_dwarf_test`'s line commented out in
`scripts/run_qemutest.sh`, not deleted, with the reproduction evidence and
open questions written in place as a comment) rather than retried or
worked around, per explicit instruction: a masking fix would make the
suite green again without anyone finding out whether the underlying
timing issue is real or could affect anything else that reads a
just-produced build artifact soon after another process finishes writing
it. Judged an acceptable, low-cost stopgap specifically because DWARF
debug-info emission (`-g`) is not otherwise relied on by any current
project workflow (no current use of gdb to inspect `.tkb` source-level
variables through it) -- this is different from disabling a check that
guards something actually in use. A GitHub issue write-up (reproduction
steps, the evidence ruling out a DWARF-emission bug, the corrected
not-container-specific finding, and suggested next steps -- `strace` on
both the linker and dwarfdump processes, trying `make -j1` to see if
serialization changes the reproduction rate) was drafted for the user to
file, to give a future investigation a running start instead of
re-deriving all of this from scratch.

**Files**: `scripts/run_qemutest.sh` (`run_dwarf_test "fizzbuzz (dwarf)"`
line commented out with investigation notes in place).

## GitHub Issue #89: "Must Be Consumed" Implemented (Locals and Parameters), via a New `sink` Parameter Kind

Two-session arc closing out the first concrete slice of issue #89 ("affine,
not linear" -- a handle may be silently dropped, never consumed, with no
error). Landed in two increments plus a design pivot found by direct
implementation, not by discussion alone.

**Increment 1: never-consumed LOCALS.** At the end of every block-like
scope (function body, `if`/`else` branch, loop body, `match` arm), an
affine local `let`-declared directly in that scope must appear in the
double-consume checker's existing `moved` set by scope-end, or it is a
compile error ("affine value 'NAME' is never consumed"). The first
implementation used a SEPARATE `must`-consumed set combined with
INTERSECTION at `if`/`match` joins (the textbook "consumed on every path"
definite-assignment dual of `moved`'s union) -- and immediately misfired on
every real affine-using example in the repo (`net_echo`, `arp_reply`,
`icmp_echo`, `tcp_echo`, `http_server`, `fatfs`, `fatfs_sdcard`,
`http_server_sdcard`), which all share this shape:

```
let acquired: *NetRxCpuOwned = net_rx_acquire();
if ((acquired as usize) != 0) { ... use acquired ... }
if ((acquired as usize) != 0) { net_rx_release(acquired); }
```

The release is reachable only behind the same nullness check gating every
other use, but the checker cannot know the two `if` conditions are the same
predicate without real relational reasoning (the same class of gap as the
tcp_echo `data_off + data_len` correlation documented elsewhere in this
file -- VC+SMT territory, not something an interval/same-base checker can
see). Reverted to reusing the plain `moved` set (union at joins) instead --
"consumed on AT LEAST ONE path," not "on every path." This still catches a
value never consumed anywhere in its scope (the actual target), at the
known, accepted cost of not catching a leak on only one branch of a
multi-way conditional release.

**Validated against a real driver rewrite, not just a toy example**:
`examples/common/sync.tkb`'s `mutex_lock`/`mutex_unlock`/`cond_wait` were
rewritten to return/consume a new `affine opaque struct MutexGuard` (a pure
compile-time marker -- the real mutex is still the caller-owned `*i32`
semaphore, passed alongside the guard), and `examples/condvar/condvar.tkb`
+ `examples/msgqueue/msgqueue.tkb` were updated to the guard-passing API,
including `cond_wait`'s drop-and-reacquire pattern
(`g = cond_wait(seq, g, m);` inside a `while` loop). `make check` (73/73 at
the time, including real QEMU execution of `condvar`/`msgqueue` and STM32
cross-build) passed unchanged. A deliberately introduced missing
`mutex_unlock` in `task_producer` was correctly rejected at the
`let mut g = mutex_lock(...)` declaration site; restoring it compiled
clean. The loop-reacquire pattern interacts correctly for what looks like
an accidental but welcome reason: reassigning `g` inside the `while` clears
its "moved" status (pre-existing behavior), which happens to satisfy the
pre-existing "cannot consume a value declared outside a loop inside that
loop" restriction with no changes needed there.

**Attempted next, and immediately reverted: the same check extended to
PARAMETERS ("problem 2").** Requiring a plain (non-`borrow`) affine
PARAMETER to also be consumed somewhere within its own function body, using
the identical mechanism, misfired immediately and fundamentally -- not on
edge cases, but on `mutex_unlock`, `fat_close`, and `net_rx_release`
themselves, plus the very first existing affine unit test. These functions
**are** the consuming operation from their caller's point of view, but
their own body has no *further* affine call to make with the parameter
they just discharged (they call `sem_post`/write a hardware register/etc.,
not another function taking the same affine pointer type). The checker has
no syntactic way to distinguish a genuine terminal "sink" function from an
accidental no-op that silently swallows the handle (`fn
drop_silently(t: *Token) {}`) -- both look identical to a purely syntactic
consumption-graph checker: a plain affine parameter that is simply never
passed onward. Reverted cleanly; the finding was written up as an interim
report (session notes, drafted for GitHub issue #89 -- posted by the user
directly, since this container's token lacked `Issues: write`).

**Design pivot, proposed in a follow-up session (consulted with Fable) and
implemented the same session: a new `sink` parameter kind closes exactly
this gap.** The insight: "this parameter's obligation ends here" is not
information a purely syntactic consumption-graph analysis can recover by
inference -- every mature approach to this problem (Rust's `Drop` bound to
a type, Linear Haskell's multiplicity-annotated arrows, ATS2's
signature-level views) makes it a **declaration**, not a derived fact.
`sink *Name` is that declaration, minimal and parameter-only (mirrors
`borrow`'s own restriction -- valid only on a pointer to an affine opaque
struct parameter, same error wording with "sink" substituted for
"borrow"): it consumes the argument at the call site exactly like a plain
`*Name` parameter, but tells the "must be consumed by the callee" check
that THIS function is the value's designated terminal consumer, so its own
body is exempt from needing to forward it further. With `sink` in place,
the parameter-consumption check from the reverted attempt was reimplemented
unchanged and now works: `net_rx_release` (both backends), `fat_close`, and
`mutex_unlock` were marked `sink` on their consuming parameter; a plain
affine parameter that is never consumed anywhere in its own function body
is now correctly rejected ("affine parameter 'NAME' is never consumed by
this function"). `cond_wait`'s own `g` parameter needed no `sink` marking
at all -- its body already forwards `g` to `mutex_unlock(g, m)`, a
consuming call, which already satisfies the check once `mutex_unlock`
itself is marked `sink`.

**Implementation footprint**: `TypeSink of type_expr` (`lib/ast.ml`,
mirroring `TypeBorrow` exactly), a new `sink` keyword (`lib/lexer.mll`,
`lib/parser.mly`), and every existing `TypeBorrow` match arm across
`lib/types.ml`, `lib/type_layout.ml`, and `lib/llvm_gen.ml` extended to
also match `TypeSink` (both erase to their inner type at the LLVM/
unification level -- `sink`, like `borrow`, is purely a compile-time
parameter annotation with no runtime representation). `lib/type_inf.ml`:
`strip_borrow` strips both wrappers; the parameter-position-only,
affine-opaque-pointer-only validation (`validate_param_type`,
`contains_borrow`) gained a parallel `TypeSink` case with its own error
message; `check_affine_func` gained the parameter-completeness check
described above, gated to skip both `TypeBorrow` and `TypeSink` parameters.

**Test coverage added at both layers**: `test/test_takibi.ml` gained unit
tests for the never-consumed-local check (including the null-check-gated
release pattern and the loop-reacquire pattern, both regression-proofing
the union-vs-intersection finding), the never-consumed-parameter check, and
`sink`'s own parameter-only/affine-opaque-only restriction. Two new
CLI-level compile-error fixtures were added alongside the pre-existing
`examples/affine_double_consume` (same convention: a minimal `Token`-based
`.tkb`/`.error` pair wired into `scripts/run_qemutest.sh`'s
`run_compile_error_test`, no Makefile changes needed): `examples/
affine_never_consumed` (a local acquired and never consumed) and
`examples/affine_param_never_consumed` (a plain-parameter callee that
silently drops the handle it was handed, the exact `drop_silently` shape
that motivated `sink`). `make check` (75/75, including the two new
compile-error tests and every real example touched by the `sink`
retrofit) passes; `make langcheck` passes.

**Deliberately still open**: full "consumed on every path" analysis
(would need real relational reasoning to avoid the null-check-gated-release
false positive found in increment 1 -- likely belongs with issue #13's
Z3/VC work, not a standalone effort); and affine handles escaping a
single function body by being stored into a data structure (a process
table holding open file handles, the literal shape a real Unix-like
kernel's fd table needs) -- the session's discussion favored, when a real
driving example arrives, first trying the classic embedded-C workaround of
storing a refined-type INDEX into a static table rather than the affine
pointer itself (turning the escape problem into an instance of this
project's existing range-proof strength), and treating true affine-field
struct storage (decoupling `affine` from `opaque`) as the fallback only if
that turns out to be insufficient. (The `return`-terminated-branch
union-imprecision noted in earlier issue #89 comments, once on this list
too, is now fixed -- see the follow-up entry immediately below.)

**Files**: `lib/ast.ml`, `lib/lexer.mll`, `lib/parser.mly`, `lib/types.ml`,
`lib/type_layout.ml`, `lib/llvm_gen.ml`, `lib/type_inf.ml` (the `sink`
feature and both consumption checks); `test/test_takibi.ml` (new/updated
unit tests); `examples/common/sync.tkb`, `examples/condvar/condvar.tkb`,
`examples/msgqueue/msgqueue.tkb` (`MutexGuard` retrofit); `examples/
common/fat12.tkb`, `examples/common_stm32/eth.tkb`, `examples/common_qemu/
virtio_mmio.tkb` (`sink` added to `fat_close`/`net_rx_release`);
`examples/affine_double_consume`, `examples/affine_never_consumed`
(`sink` added so these fixtures test what they say they test, not the new
parameter check); `examples/affine_param_never_consumed` (new fixture);
`scripts/run_qemutest.sh` (two new compile-error test registrations);
`SPEC.md` ("Affine Opaque Structs" section rewritten for `sink` and the
"must be consumed" rules).

## GitHub Issue #89 Follow-up: `return`-Terminated Branches No Longer Leak Into the Union

Closed the smaller, self-contained gap left open by the entry above: the
affine checker's `If`/`Match` cases unioned every branch's/arm's own
consumed-set unconditionally, with no awareness that a branch/arm ending in
`return` on every one of ITS OWN paths can never reach the code after the
enclosing `if`/`match` at all. Concretely, this used to force an
`else` where none should have been needed:

```
if (fat_write(fp, ...) != 0) {
    fat_close(fp);
    return -1;
}
return fat_close(fp);   // used to be rejected: "affine value 'fp' was already consumed"
```

Added a purely syntactic `always_terminates : Ast.stmt list -> bool` helper
(a statement list terminates if any statement in it does: `Return`
unconditionally; a nested `If` where BOTH branches terminate; a nested
`Match` where EVERY arm terminates; a `Block` whose body terminates;
anything else, including loops, conservatively `false` -- reasoning about
loop termination is out of scope and false just falls back to today's
existing union behavior, never a new unsoundness). `If`'s combination logic
now unions both branches only when neither (or both) terminate; when
exactly one does, only the non-terminating branch's consumption continues
past the `if`. `Match` got the same treatment across all arms, with the
same "if every arm terminates, union everything anyway" fallback (nothing
continues past the `match` in that case, so it's moot which set is
reported).

Verified both directions, not just the fix: the `fat_close` shape above now
compiles with no `else` at all (confirmed via a scratch probe before
touching real code), and `examples/common/fat12.tkb`'s `create_demo_file`
-- which had carried the `if { ... } else { return fat_close(fp); }`
workaround, with a comment explaining exactly why, since the affine
opaque-struct work that first found this gap -- was simplified back to the
natural early-return form and reverified end-to-end (`make check` 75/75,
including `fatfs`'s real QEMU + `mtools` verification of the file this
function writes). A negative control (`if (cond) { release(t); }
release(t);` -- a branch that does NOT terminate, sharing a value with the
code after it) confirmed the pre-existing double-consume detection is
unaffected: still correctly rejected, since neither branch here returns.

**Files**: `lib/type_inf.ml` (`always_terminates` plus the `If`/`Match`
combination fix); `test/test_takibi.ml` (3 new unit tests: the fixed
pattern, the both-branches-terminate case, and the non-terminating-branch
negative control); `examples/common/fat12.tkb` (`create_demo_file`
simplified, workaround comment removed).

## Bug Found and Fixed While Building the Escape-Idiom Proof-of-Concept: Struct Returned By Value

Found by accident while writing `examples/affine_escape_via_index/
affine_escape_via_index.tkb` (see the follow-up entry right after this one
for that file itself): a function returning a `struct` type BY VALUE (not
`*Struct`) crashed the compiler with an internal-compiler-error, not a
normal `TypeError` -- `Llvm_gen.Error("internal compiler error: invalid
LLVM IR generated for function 'open_two' ... ret ptr %p ...")` from a
function LLVM had declared to return the aggregate `{i32,i32}` itself.

**Root cause 1 (codegen)**: every struct-typed local/parameter is
represented internally as a pointer to its own alloca (`Var`'s `TypeNamed
_ -> (ast_ty, ptr)` case in `lib/llvm_gen.ml` -- this is what makes
`.field` access, passing to `*Struct`-typed parameters, etc. all work).
`coerce` (the function every value-producing boundary funnels through --
`Return`, and a call argument matched against its declared parameter
type) had a `TypeNamed _ -> v` case that passed this pointer straight
through unchanged instead of loading the aggregate value, which is what
both of those two boundaries actually need when the destination type is
the bare struct (not `*Struct`). Fixed by loading whenever the source
value is a pointer but the destination LLVM type is the first-class
aggregate itself -- one fix in `coerce` closes both the `Return` case and
the symmetric struct-by-value call-argument case at once, confirmed with
a probe exercising both (`sum(p: Process)` called with a struct-by-value
argument).

**Root cause 2 (missed type-check), found immediately after by re-running
the same probe**: fixing codegen surfaced a second, deeper bug at the next
line: `let proc: Process = open_two();` (immutable, no `mut`) still
crashed codegen, this time on the FIELD ACCESS (`proc.fd_a`) with an
equally invalid `getelementptr` directly on the raw returned aggregate
SSA value (not a pointer). Cause: an immutable `let` has no alloca at all
(`Let(false, ...)` in `lib/llvm_gen.ml` just stores the raw SSA value under
an `Imm` binding) -- but `type_inf.ml` only rejected this for a struct
LITERAL initializer (`"struct literal requires `let mut ...`"`, existing,
pre-this-session check), not for ANY OTHER struct-typed initializer (a
function-call result, a field read, etc.), so this shape reached codegen
and crashed there instead of being caught as an ordinary compile error.
Extended the same restriction to any immutable `let` whose initializer's
type is a real struct. Had to distinguish real structs from enums
carefully: `Types.ty` represents BOTH as `TStruct sname` (`Types.of_ast`'s
`TypeNamed s -> TStruct s`), so the new check additionally requires
`sname` to be registered in `senv` (populated only from `StructDef`, not
`EnumDef`) -- an enum value is just an integer at the LLVM level and
remains fine immutable. Missing this distinction was caught immediately by
an existing, unrelated unit test ("refined int subtype cast to enum...")
that started failing against the first, too-broad version of the check.

Verified end-to-end after both fixes: a function returning a struct by
value, called from an immutable-let-turned-`let mut` binding, with a
subsequent `.field` read AND the struct passed by value to a second
function (`sum(p: Process) -> i32`), all compile and run correctly under
QEMU (confirmed the actual field values round-trip correctly, not just
"compiles").

**Files**: `lib/llvm_gen.ml` (`coerce`'s `TypeNamed` case); `lib/
type_inf.ml` (`Let`'s non-literal struct-typed-immutable check);
`test/test_takibi.ml` (3 new unit tests: the fixed round-trip via
`expect_codegen_ok`, the immutable-non-literal-struct negative control,
and an enum negative control confirming the `senv` distinction).

## GitHub Issue #89 Follow-up: `examples/affine_escape_via_index` -- a Small, Deliberately Possibly-Throwaway Proof-of-Concept for the "Escape" Problem

Direct follow-up to the "Deliberately still open" list two entries above
(affine handles escaping a single function body by being stored into a
data structure -- the literal shape a real Unix-like kernel's fd table
needs, and something neither `FatFile` nor `NetRxCpuOwned` can do today,
both being global-singleton `affine opaque struct` handles). Discussed
with the user (and, in an earlier round, with Fable) before building
anything: given RTOS work is expected soon and will likely want some kind
of filesystem, is it worth spending time on this NOW, ahead of a concrete
driving example? Landed on yes, specifically because the idiom under
test -- a fixed-size table of real per-slot state, addressed by a plain
refined-type INDEX rather than an affine pointer -- uses ZERO new
compiler features. It is purely a way of using EXISTING machinery
(structs, arrays, refined `{lo..<hi as base}` parameter types) in a new
combination, so the cost of it turning out to be the wrong shape once
RTOS's real requirements are known is just deleting one `.tkb` file, not
unwinding compiler/parser/type-system changes the way `sink` would have
been.

**What it demonstrates**: `examples/affine_escape_via_index/
affine_escape_via_index.tkb` -- a 4-slot table of `Slot { in_use: bool;
value: i32; }`, `slot_open()/slot_read()/slot_write()/slot_close()`
operating on it, and a GLOBAL `Process { fd_a: i32; fd_b: i32; }` filled
by one function (`open_two()`) and read/written/closed from a completely
different one (`app_main()`) -- the plainest possible demonstration that
the identifier has escaped its acquiring function's own stack frame.
Written first without refined types (CLAUDE.md's development process),
verified functionally correct via real QEMU execution, THEN hardened:
`slot_read`/`slot_write`/`slot_close` take `idx: {0..<4 as usize}`
(literal bound -- a named `SLOT_COUNT` global in that position is a
parser-time error, per the const_global.tkb-documented restriction), and
the whole file compiles with zero trap sites under `--forbid-trap`.
`make check` (76/76, real QEMU output verified against `.expected`) is
the actual, current proof this compiles and runs, not just an assertion.

**Two smaller gotchas hit and fixed while writing it, unrelated to the
idiom itself**: no `!` (logical-not) operator exists in this language at
all (`~` is bitwise NOT only) -- `slots[i].in_use == false` instead. And
if-narrowing only tracks a plain LOCAL variable, not a repeated struct
FIELD read (`examples/common/fat12.tkb`'s `fat_close` already carries the
same comment) -- `proc.fd_a` had to be bound to a local (`let a: i32 =
proc.fd_a;`) before `if (a >= 0 && a < 4) { ... a as usize ... }` would
narrow it tightly enough to satisfy `slot_read`'s refined parameter.

**The actual trade being surfaced for later discussion, not resolved
here**: this idiom buys multi-instance + escape, but LOSES the
compile-time double-close/use-after-close guarantee on the escaped
identity itself -- only a runtime `in_use` flag catches that class of bug
now (confirmed by design, not by accident: the third `slot_open(30)` in
the demo, run after both earlier slots are closed, correctly reuses slot
0, proving `in_use` is a real, load-bearing check, not decoration). This
is the concrete question a real RTOS+filesystem milestone will force: is
that trade acceptable for a real driver, or does it call for extending
`affine` itself (decoupling it from `opaque`, letting an affine value
carry real per-instance fields, a bigger and still-undesigned language
change) instead? Left open on purpose -- see the user's own framing: keep
this file as a proof-of-concept and discussion anchor, not a template to
copy into `fat12.tkb`/`eth.tkb` yet.

**Follow-up in the same session: a second, NOMINAL affine layer added on
top, specifically so this file has a concrete two-tier shape to argue
from later, not a purely hypothetical one.** `affine opaque struct
SlotLease;` plus `slot_lease(idx) -> *SlotLease` / `slot_unlease(lease:
sink *SlotLease)` mark "the CPU is currently touching this slot", scoped
to the duration of one read/write/close -- entirely separate from the
long-lived, escaping `idx`. `slot_read`/`slot_write`/`slot_close` now
also take `lease: borrow *SlotLease` as proof-carrying evidence a lease
was taken first. Deliberately does no real synchronization (single-
threaded demo; a real per-slot lock would attach here once genuine
concurrency/preemption exists) -- this is form, not function, by
explicit request. Verified it is not purely decorative, though: a
deliberately introduced missing `slot_unlease(lease)` (scratch probe, not
committed) was correctly rejected by this session's own never-consumed
check ("affine value 'lease' is never consumed"), and restoring it
compiles and runs identically to before (`make check` 76/76 unchanged;
`.expected` output byte-identical). This is the concrete shape meant to
anchor the later RTOS-time discussion: keep this two-tier (escaping index
+ momentary lease) idiom, extend `affine`/`opaque` decoupling instead, or
something else -- see the trade-off paragraph above.

**Files**: `examples/affine_escape_via_index/
affine_escape_via_index.tkb` + `.expected` (new); `Makefile` (added to
`EXAMPLES`, QEMU-only for now -- no STM32 build, since this is validation
work, not a driver being ported); `scripts/run_qemutest.sh` (one new
`run_test` registration).

## GitHub Issue #15 Follow-up: Integer-to-Affine-Pointer Cast Audit Boundary (`unsafe` Required, Narrowly Scoped)

Follow-up to a design discussion (with Fable) about issues #15 ("Safe
pointer") and #102 ("Provable pointer alignment"): rather than tackling
"Safe pointer" as one monolithic feature, break it along its real
dependency lines (range: already solved by slices; alignment: #102,
no dependency, real driving need already hit -- see the sdmmc.tkb HardFault
entry elsewhere in this file; null safety: needs #20 variant enum first;
dangling: impossible without a heap, needs #26 first; forged pointers:
no dependency, cheap). This entry is the "forged pointers" piece, chosen
as the first, cheapest step, and directly motivated by
`examples/affine_escape_via_index/affine_escape_via_index.tkb`'s own
`idx as *SlotLease` (see that file's own entry above) -- a small integer
that was never a real address, cast to a pointer purely to smuggle it
through affine tracking.

**What it does**: casting a non-literal integer to a pointer whose
pointee is an `affine opaque struct` type now requires `unsafe { ... }`,
mirroring the existing "unchecked assertion must be visibly marked"
pattern SliceOf already uses for raw-pointer-to-slice construction. A
cast built entirely from compile-time literals or a real object's address
(`&x`) stays legal without `unsafe` -- this keeps every existing sentinel
pattern in the codebase working unchanged: `0 as usize as *FatFile` /
`*NetRxCpuOwned` / `*MutexGuard` / `*Token` (null-style "nothing
acquired" sentinels) and `&fat_file_token_storage as *FatFile` /
`&net_rx_token_storage as *NetRxCpuOwned` (singleton addresses).

**The scoping decision was found empirically, not assumed.** The first
version applied to ANY integer -> ANY pointer cast, not just affine
targets, on the theory that it would be "nearly free" (per the design
discussion). Measuring it against the actual codebase immediately proved
that wrong: `examples/common_qemu/virtio_mmio.tkb`'s `virtio_net_find()`
discovers a device's MMIO base address at BOOT TIME by scanning slots
(`let mut virtio_base: i32 = 0; ... virtio_base = base;`), and the whole
driver then routinely does `(virtio_base + offset) as *io i32` --  a
completely legitimate, unavoidable hardware-address computation that is
syntactically indistinguishable from a bogus cast (both are "some
non-literal integer cast to a pointer"). The broad version would have
required sprinkling `unsafe` across essentially every MMIO register
access in `virtio_mmio.tkb`/`gic.tkb`/`eth.tkb`, which would have made
`unsafe` too common to carry any audit signal at all -- confirmed
concretely via two existing, correct unit tests that started failing
against the broad version (`usize as pointer type-checks`, and a codegen
test with a genuine `pointer -> usize -> pointer` round-trip through a
named local), both legitimate patterns with no realistic way to
distinguish them syntactically from a forged pointer.

Narrowing to affine-opaque targets only removes this tension entirely,
for a principled reason, not just to dodge the measurement: nothing
legitimate ever needs to fabricate a NEW affine handle from an arbitrary
computed integer -- every real handle in this codebase already comes from
that type's own constructor (`fat_open()`, `net_rx_acquire()`,
`mutex_lock()`), so a cast building one any other way (not literal, not a
real address) is exactly the kind of misuse this check exists to catch,
with none of plain-pointer MMIO access's legitimate-but-syntactically-
identical cases to worry about. Re-measured after narrowing: `make check`
(76/76) -- ONLY `affine_escape_via_index.tkb`'s own `idx as *SlotLease`
was flagged; every other example (`net_echo`/`arp_reply`/`icmp_echo`/
`tcp_echo`/`http_server`/`fatfs` and their real `NetRxCpuOwned`/`FatFile`
sentinel casts, the STM32 build, `virtio_mmio.tkb`'s runtime MMIO
addressing) compiled completely unchanged. Fixed by wrapping that one
cast in `unsafe { ... }` with a comment explaining why it's deliberately
left marked rather than "fixed" -- flagging it clearly is the actual
point of that file.

**Implementation**: a new `is_literal_derived` predicate (`IntLit`, `&x`,
casts/`+`/`-`/`*` of literal-derived values) and a module-level
`affine_opaque_names : StringSet.t ref` (same pattern as `unsafe_depth`/
`resolved_call_targets` -- `infer_expr` is a separate top-level function
with no closure access to `infer_program`'s own locals, so the set,
computed once near the start of `infer_program` before Pass 3 runs, has
to be threaded through a ref rather than a parameter). The actual check
(`check_affine_ptr_cast_needs_unsafe`) had to be called from TWO separate
match arms in `infer_expr`'s `Cast` case, not one: a plain unrefined
integer source and a `TRefinedInt` source (e.g. a for-loop-proven
`{0..<4 as usize}` index, exactly `affine_escape_via_index.tkb`'s own
`idx`) take different branches of the existing `match repr src_ty with`
structure, and the first attempt only wired the check into the plain-
integer branch -- confirmed missed by trying `idx as *SlotLease` again
after the "fix" and seeing it still compile clean, not by inspection alone.

**Test coverage**: 5 new unit tests (a non-literal cast to an affine
handle rejected; `unsafe` accepting the same cast; a literal cast needing
no `unsafe`; an address-of cast needing no `unsafe`; a negative control
confirming a non-literal cast to a NON-affine pointer, the `virtio_base`
shape, stays legal). `make test` (518) and `make check` (76/76) both pass.

**Files**: `lib/type_inf.ml` (`is_literal_derived`,
`affine_opaque_names`, `check_affine_ptr_cast_needs_unsafe`, wired into
both `Cast` match arms); `test/test_takibi.ml` (5 new unit tests);
`examples/affine_escape_via_index/affine_escape_via_index.tkb`
(`slot_lease`'s cast wrapped in `unsafe`, with a comment explaining why
that's the intended end state, not a placeholder).

## GitHub Issue #102: `*align(N) T` -- Provable Pointer Alignment Implemented (Stage 1, Deliberately Staged)

The type this project's design principle has been pointing at since
`examples/common_stm32/sdmmc.tkb`'s bounce-buffer workaround was written
(see this file's earlier "Filed, Not Started" entry): a pointer
analogue of a refined integer's `{lo..<hi as base}`, proving a pointer is
N-byte aligned instead of just asserting it by convention. Picked up
again in a design discussion with Fable (issues #15 and #102 together,
alongside the RTOS-timing question of what to build next) and PLANNED
before implementation (`EnterPlanMode`, given the size -- this session's
prior features, `sink` and the cast-audit-boundary, had already
established both the pattern for how a feature like this should be built
in this codebase and the discipline of measuring blast radius before
trusting a design).

**Explicitly staged, matching the plan's own scope boundary**: Stage 1
(this entry) is the type itself -- parser through codegen, proof rules,
a self-contained demo, verified to have ZERO effect on existing code.
Stage 2 -- retrofitting `dma_prepare_rx`/`dma_finish_rx`/`dma_prepare_tx`
to actually REQUIRE `*align(32)` and removing `sdmmc.tkb`'s
`disk_read_bounce` workaround -- is explicitly NOT part of this pass; the
plan named 15+ existing call sites across `eth.tkb`/`sdmmc.tkb`/
`uart.tkb`/`fatfs.tkb`/`http_server_sdcard_install.tkb` as needing their
own measurement first, the same "looked cheap, measured larger" risk the
issue #15 work hit today.

**Design**: `*align(N) T` (Zig-style spelling, agreed with the user/
Fable in advance), congruence-domain semantics scoped to the actual need
(provably a multiple of N, not a general `x = c mod m` domain). Four
proof sources: `&x`/an array's own bare name when the variable was
declared `align(N)` (issue #27's existing mechanism); a literal address
cast, checked directly against its own value; pointer arithmetic
(`aligned_ptr + offset`) when `offset` is provably a multiple of N;
`unsafe { ... as *align(N) T }` for everything else. Subtyping mirrors
`TRefinedInt`'s existing one-directional pattern in `lib/types.ml`
exactly (widen to plain `*T` always OK; `*align(K) T` OK when `K` divides
`N`; an unproven or insufficiently-aligned pointer flowing the other way
is rejected with a message pointing at the proof sources and `unsafe`).

**Implementation footprint**: `Ast.TypeAlignedPtr`/`Types.TAlignedPtr`,
structurally parallel to `TypePtr`/`TPtr` (not a wrapper like
`TypeBorrow`/`TypeSink`, since `align(N)` modifies the pointer sigil
itself per the agreed syntax) -- integrated into `types.ml`'s `unify`
following `TRefinedInt`'s own template line-for-line. Erases to a plain
`pointer_type context` everywhere `TypePtr` already does in
`type_layout.ml`/`llvm_gen.ml` (size/align, `ltype_of_ast`,
`ditype_of_ast`, `coerce`, `abi_type`) -- no runtime representation, same
treatment `sink`/`borrow` got earlier this session. The proof engine
(`lib/type_inf.ml`): `provable_multiple_of` (a literal or
`Const_env`-resolvable named constant is a multiple of itself; `_ * K` or
`K * _` a multiple of K regardless of the other operand; a sum/difference
of two provable multiples a multiple of their gcd -- deliberately not a
general symbolic solver); a two-tier `var_align_bytes` table (global
baseline populated once in `infer_program`, reseeded at the start of
every `infer_func` call and updated incrementally as that function's own
`align(N)` locals are processed, so a local correctly shadows an aligned
global of the same name and no function's locals leak into the next);
the literal-or-`unsafe` cast check (`check_aligned_ptr_cast_needs_unsafe`,
built as a structural sibling to the issue #15 affine-cast check); and
`BinOp (Add | Sub, ...)` cases threading `provable_multiple_of` through
pointer arithmetic, placed BEFORE the existing plain-`TPtr` cases (an
`*align(N) T` operand needs its own decision -- keep the proof or decay --
that a plain pointer's fixed "always return t1 unchanged" rule doesn't
make).

**Gaps found only by building an actual codegen test, not by reading the
type-checker alone** -- exactly why `expect_codegen_ok` tests (not just
`expect_ok`/`expect_type_error`) were written for this feature from the
start:
- `lib/llvm_gen.ml`'s own `BinOp (Add | Sub, ...)` codegen (distinct from
  type_inf.ml's copy -- this codebase's established "sync rule" duplication
  between the two) pattern-matched `TypePtr` specifically for deciding
  GEP-vs-integer-add. An `*align(N) T` value reaching this code fell
  through to the INTEGER-arithmetic branch instead (LLVM `add` on an
  actual `ptr`-typed SSA value) -- caught by the exact codegen test
  mirroring `eth_rx_bufs + eth_rx_cur * ETH_BUF_SIZE`, not by any of the
  purely-type-level tests, which cannot see codegen-only bugs by
  construction. Fixed by adding `TypeAlignedPtr` alongside every
  `TypePtr` match arm in both the Add and Sub cases, plus a shared
  `ptr_result_ty` helper mirroring `provable_multiple_of` on the codegen
  side (same sync-rule duplication the existing `TypeRefined` arithmetic
  already lives with).
- `Index`/`AssignIndex` (`p[i]`, `p[i] = v`) needed the identical
  `TypeAlignedPtr` treatment in BOTH `type_inf.ml` (the type-checking
  side, "index operator on non-array/pointer type") and `llvm_gen.ml`
  (codegen's own, separate `locals`/`global_vars` pattern matches, "is
  not an array or pointer") -- found the same way, by the codegen test's
  `p[0] = 1;` line failing first at the type-checking layer, then again
  (after that fix) at the codegen layer, confirming both needed
  independent fixes rather than one covering the other.
- **A real regression in ALREADY-WORKING code, found only by running the
  FULL suite (not just the new feature's own tests)**: once `eth_rx_bufs`
  (an `align(32)`-declared global in `examples/common_stm32/eth.tkb`)
  started decaying to `*align(32) u8` instead of plain `*u8`, the
  existing `dma_prepare_rx`/`dma_finish_rx`/`dma_prepare_tx` compiler
  builtins -- whose own argument type-check required exactly `TPtr _` --
  started rejecting `eth.tkb`'s own `dma_finish_rx(eth_rx_bufs +
  eth_rx_cur * ETH_BUF_SIZE, ...)` call, breaking `net_echo`/
  `arp_reply`/`icmp_echo`'s STM32 builds. This is exactly the kind of
  gap `make check`'s full-suite pass count exists to catch (per the
  plan's own verification section) -- found there, not anywhere in the
  new feature's own tests, since none of them happened to route an
  aligned pointer through one of these three builtins. Fixed by widening
  that one check to `TPtr _ | TAlignedPtr _ -> ()`: accepting an aligned
  pointer as a valid "raw pointer" argument requires no alignment
  reasoning on the builtins' own part (Stage 2's job, not this one's) --
  it only needed to stop rejecting a strictly MORE-informative pointer
  type than what it already accepted.

**Verification**: `examples/align_ptr_proof/align_ptr_proof.tkb` --
mirrors `eth_rx_bufs + eth_rx_cur * ETH_BUF_SIZE` exactly (an
`align(32)` buffer array, slots addressed by pointer arithmetic with a
NAMED constant step, `SLOT_SIZE = 32`, resolved through `Const_env`, the
same mechanism the real driver's `ETH_BUF_SIZE` would use), passed to a
function requiring `*align(32) u8`, read and written through it via
`p[0]`. Compiles with ZERO trap sites under `--forbid-trap` and produces
the correct values (`10 11 12 13`) under real QEMU execution --
`make check` (78/78, real output verified against `.expected`) is the
actual, current proof, not just a claim. `examples/align_ptr_unproven/`
(new compile-error fixture, same convention as `examples/
affine_never_consumed` etc.) demonstrates an unproven `*u8` rejected
where `*align(32) u8` is required, with `unsafe` shown as the fix. 12 new
unit tests in `test/test_takibi.ml` cover every proof source, both
subtyping directions, the `unsafe` escape hatch, and the pointer-
arithmetic positive/negative cases. `make test` (529), `make check`
(78/78, confirmed unchanged from before this feature except for the two
new examples -- the DMA-builtin regression above was the one real
exception, caught and fixed), and `make langcheck` all pass.

**Deliberately still open (Stage 2 and beyond)**: retrofitting
`dma_prepare_rx`/`dma_finish_rx`/`dma_prepare_tx` to REQUIRE
`*align(32)` and removing `sdmmc.tkb`'s bounce buffer -- needs its own
measurement pass across every real call site first, per the plan; a
struct field of an `align(N)`-declared struct type is not yet an
automatic proof source (only a variable's own `&`/bare-name is); and
general symbolic congruence reasoning beyond literal/named-constant
multipliers remains out of scope, same YAGNI calibration as
`provable_multiple_of`'s own comment explains.

**Files**: `lib/ast.ml`, `lib/lexer.mll`, `lib/parser.mly`, `lib/types.ml`,
`lib/type_layout.ml`, `lib/llvm_gen.ml`, `lib/type_inf.ml` (the
`*align(N) T` type, its proof engine, and the DMA-builtin regression
fix); `test/test_takibi.ml` (12 new unit tests); `examples/
align_ptr_proof/` (new, `.tkb` + `.expected`); `examples/
align_ptr_unproven/` (new compile-error fixture); `Makefile` (both added
to `EXAMPLES`); `scripts/run_qemutest.sh` (two new test registrations);
`SPEC.md` (new `*align(N) T` subsection).

## GitHub Issue #102 Stage 2: DMA Builtins Retrofitted, `disk_read`'s Bounce Buffer Removed

The payoff Stage 1 was explicitly built toward: `dma_prepare_rx`/
`dma_finish_rx` (cache-line INVALIDATE operations -- the real HardFault
class this whole feature exists to catch at compile time instead of on
real hardware, see this file's issue #101-follow-up and issue #102
"Filed, Not Started" entries) now REQUIRE a proven `*align(32)` pointer,
and `examples/common_stm32/sdmmc.tkb`'s `disk_read` no longer stages
through its own `disk_read_bounce` driver-owned buffer -- it DMAs
directly into the caller's own buffer, exactly the elimination the type
system was supposed to make possible once it could express "this pointer
is provably aligned". `dma_prepare_tx` (a CLEAN/writeback, safe on any
alignment per this file's own established understanding) intentionally
still accepts any raw pointer.

**Measured first, exactly like Stage 1 and the issue #15 cast-audit-
boundary work**: requiring alignment on all THREE builtins uniformly was
tried first and immediately broke every single STM32 example, because
`examples/common_stm32/uart.tkb`'s own TX-DMA `uart_puts` implementation
(included in literally every STM32 build) calls `dma_prepare_tx` on a
ring-buffer byte offset that is never aligned to 32 by construction.
Re-confirmed directly from this file's own already-recorded reasoning
(the sdmmc.tkb comment already explained TX/CLEAN doesn't need it) rather
than re-deriving it from scratch -- scoping the requirement to
`dma_prepare_rx`/`dma_finish_rx` only immediately fixed it.

**Real blast radius, found by iterating `make check` to a fixed point**
(same discipline as every other feature this session): six real call
sites needed fixing, each a genuine instance of a small number of
recurring patterns, not six unrelated bugs:
- **Explicit `: *u8` annotations discarding an already-provable
  alignment** -- `examples/common_stm32/eth.tkb`'s `let buf: *u8 =
  eth_rx_bufs + ptr_i * ETH_BUF_SIZE;` and `sdmmc.tkb`'s own `let bounce:
  *u8 = disk_read_bounce;` both had a RHS that would have inferred
  `*align(32) u8` on its own, truncated right back down by a stale
  annotation -- the exact "explicit type beats inference" trap already
  seen with `affine_escape_via_index.tkb`'s `idx` this session. Fixed by
  writing the annotation as `*align(32) T` (not by removing it, since
  these are explicit `let` bindings elsewhere in the same functions).
- **A function's own declared RETURN type is a boundary** -- `eth.tkb`'s
  `rx_desc_ptr`/`tx_desc_ptr` returned plain `*EthDmaDesc` even though
  their bodies (`eth_rx_descs + i`) already proved alignment internally;
  the proof does not cross a function boundary unless the signature says
  so, same rule as everywhere else in this type system. Fixed by
  declaring `-> *align(32) EthDmaDesc`.
- **An unnecessary `as *u8` cast discarding the proof for no reason** --
  `desc as *u8` (twice in `eth.tkb`) cast a genuinely `*align(32)
  EthDmaDesc` value down to a plain pointer immediately before passing it
  to `dma_finish_rx`, which only needed SOME pointer type, not
  specifically `*u8` -- `dma_prepare_tx`/`dma_prepare_rx`/`dma_finish_rx`
  destructure whatever pointee type they're given. Fixed by passing
  `desc` directly, no cast at all.
- **Genuinely unaligned buffers with no prior driving reason to be
  aligned** -- `examples/fatfs/fatfs.tkb`'s in-memory `disk` array and
  `examples/http_server_sdcard_install/http_server_sdcard_install.tkb`'s
  `staging` array (the harness's OpenOCD-injected image buffer) had never
  needed `align(32)` before (no real DMA touched the former; the latter's
  own `dma_finish_rx` call is what surfaced the need). Fixed by adding
  `align(32)` directly -- both are driver/test-owned globals with no
  caller-supplied-buffer complication.
- **The real cascade**: `examples/common/fat12.tkb`'s `fat_buf`/
  `root_dir_buf` (globals) and three separate local `sector_buf`/
  `zero_buf` declarations all needed `align(32)` -- these are the buffers
  that actually reach `disk_read`/`disk_write` through
  `examples/fatfs_sdcard/fatfs_sdcard.tkb`'s and `examples/
  http_server_sdcard/http_server_sdcard.tkb`'s `mem_block_read`/
  `mem_block_write` adapters, both updated to require `*align(32) u8` on
  their own `buf` parameter (uniformly for both read and write, even
  though `disk_write`'s own `buf` doesn't strictly need it either --
  matching alignment on both keeps the adapter's contract simple, costs
  nothing once the backing buffers are aligned anyway). `examples/
  fatfs/fatfs.tkb`'s OWN in-memory `mem_block_read`/`mem_block_write`
  needed NO signature change: an aligned argument widens into its
  existing plain `*u8` parameters for free. `examples/sdcard/sdcard.tkb`
  (the raw-block test, bypassing fat12.tkb entirely) has its own local
  `rbuf` (fed to `disk_read`) that needed `align(32)` directly; its `wbuf`
  (fed only to `disk_write`) did not.

**Two real bugs found in Stage 1's own implementation, only by trying to
retrofit real code, not by further unit testing of the feature in
isolation**:
- The `desc as *u8` fix above (cast FROM `*align(32) EthDmaDesc`) exposed
  that `infer_expr`'s `Cast` case had no `TAlignedPtr` branch on the
  SOURCE side at all -- it fell through to the catch-all (integer-cast-
  oriented) branch, which happened to produce the right VALUE by
  accident (none of that branch's checks fire for a plain-pointer
  target) but for the wrong reason, and would have mishandled any other
  target. Fixed by extending the existing `TPtr _ ->` cast-source branch
  to `TPtr _ | TAlignedPtr _ ->`, sharing its widening rules exactly.
- That fix's FIRST version called plain `unify src_ty tgt` to check an
  `*align(N) T` source against an `*align(M) T` target -- immediately
  broke `examples/common/fat12.tkb`'s `root_dir_buf as *align(32) u8`
  (`"cannot unify DirEntry with u8"`), because `unify` also enforces the
  POINTEE type stays identical, which is wrong for an explicit cast (a
  REINTERPRET across pointee types, e.g. a `DirEntry` array reinterpreted
  as raw bytes, is exactly what `as *U` is supposed to allow -- same as
  any ordinary `*T as *U`). Fixed by checking only the alignment NUMBER
  directly (source's own N must be a multiple of the target's) instead of
  calling `unify`, leaving the pointee type free to change. This same
  fix pass also caught that its own FIRST draft had silently dropped the
  `unsafe_depth` check entirely (copy-paste from the pointer-source-cast
  logic lost the `if !unsafe_depth > 0 then ...` wrapper) -- caught
  immediately by one of Stage 1's own existing unit tests
  ("unsafe marks an unproven cast to *align(N) T") failing, not by new
  code added for Stage 2, a concrete example of why the existing test
  suite earns its keep across supposedly-unrelated later changes.
- **A second new proof source, not anticipated in the Stage 1 plan**:
  `eth_rx_descs + i` (`eth.tkb`'s `rx_desc_ptr`) needed a genuinely NEW
  rule, not just fixing an existing one -- `EthDmaDesc` is `align(32)`,
  so GEP's own per-element stride (`sizeof(EthDmaDesc)`, itself tail-
  padded to a multiple of 32 by that struct's own `align(32)`) already
  guarantees alignment for ANY integer `i`, not just an `i` provably a
  multiple of 32 in BYTES the way `provable_multiple_of` alone could see.
  Added `elem_stride_aligned` (queries `senv`'s existing struct-align
  bookkeeping in `type_inf.ml`, `struct_alignments` in `llvm_gen.ml`) as
  a second, independent proof source alongside `provable_multiple_of` in
  both `BinOp (Add | Sub, ...)` cases (both files, sync rule).

**Verification**: `make test` (530, 3 new + 1 fixed-in-place from the
DMA-signature change breaking two pre-existing DMA-builtin tests that
predate this whole feature), `make check` (78/78, full STM32 cross-build
of every retrofitted file included), `make langcheck` all pass.
**Explicitly NOT verified on real hardware in this session** -- this
project's own established practice (see the "QEMU (TCG mode)... does not
model caches" principle elsewhere in this file) is that cache-coherency
changes exactly like this one can ONLY be confirmed on real silicon, and
this exact codepath has a documented HISTORY of a real HardFault that
QEMU could never have caught. `examples/sdcard`/`examples/fatfs_sdcard`
are exercised by `make hwcheck`; `examples/http_server_sdcard` by `make
hwcheck-net` -- running these against a real STM32F746G-DISCOVERY board
with a real SD card is the one remaining step before trusting this
change, and was left to the user to run in this environment (no hardware
attached to this container).

**Files**: `lib/type_inf.ml` (Cast's `TAlignedPtr` source handling and
its two bugs above; `elem_stride_aligned`; the `dma_prepare_rx`/
`dma_finish_rx`-only alignment requirement); `lib/llvm_gen.ml`
(`elem_stride_aligned`'s codegen-side mirror); `test/test_takibi.ml`
(2 pre-existing DMA-builtin tests updated for the new signature, 1 new
test for the tx-vs-rx/finish asymmetry); `examples/common/fat12.tkb`
(`fat_buf`/`root_dir_buf`/`sector_buf` x3/`zero_buf` all `align(32)`,
two `root_dir_buf as *align(32) u8` casts); `examples/common_stm32/
eth.tkb` (`rx_desc_ptr`/`tx_desc_ptr` return type, two `desc` locals,
two unnecessary `as *u8` casts removed); `examples/common_stm32/
sdmmc.tkb` (`disk_read`'s signature and body, `disk_read_bounce` removed
entirely); `examples/fatfs_sdcard/fatfs_sdcard.tkb` + `examples/
http_server_sdcard/http_server_sdcard.tkb` (`mem_block_read`/
`mem_block_write` signatures); `examples/fatfs/fatfs.tkb` (`disk`
array `align(32)`); `examples/http_server_sdcard_install/
http_server_sdcard_install.tkb` (`staging` array `align(32)`); `examples/
sdcard/sdcard.tkb` (`rbuf` local `align(32)`); `SPEC.md` (element-stride
proof source documented, Stage 2 scope note updated).

## Simple RTOS (GitHub issue #66) and Multiple Core (issue #6): design discussion, then PoC 1/3 -- `examples/klock_guard`

Following issue #102's completion, discussed (with the Fable persona) how
far to design ahead for a future Simple RTOS given `io`'s existing
single-core assumption, and whether an SMP kernel realistically needs
message-passing (Barrelfish/multikernel-style) or can stay shared-memory
with fine-grained locks -- referencing seL4's "big lock is fine" result
(noted as a CONDITIONAL claim specific to microkernels with short kernel
residency, not a universal one applicable to Takibi's monolithic-Unix-
kernel goal) and CertiKOS (Coq-verified concurrent kernel with per-CPU
locks, counter-evidence that message-passing-only is not the sole path
to verifiability) against Hubris/QNX/RTIC as reference points for a
static-tasks-plus-synchronous-IPC design. Conclusion, recorded in issues
#66 and #6 (filed by the user from this discussion, translated to
English) rather than repeated here: start with a giant kernel lock
(interrupt-disable, single-core-honest) but name the LOCK OBJECT from
day one in the API (`klock(lk: *KLock)`, not a bare Linux-BKL-style
no-argument lock/unlock) specifically so fine-graining later is a body
change, not an API rewrite; defer real SMP/message-passing entirely
until issue #6's actual hardware need (RPi3) exists.

Proposed (and the user accepted) a minimal RTOS task-facing API in
Takibi syntax, to be proven out as a series of small, self-contained
proof-of-concept examples (same convention as `examples/
affine_escape_via_index`) before being combined into one
`examples/common/rtos.tkb`:

```
fn cpu_id() -> {0..<1 as usize};          // today: NCPU=1

struct KLock { word: i32; }
affine opaque struct KGuard;
fn klock(lk: *KLock) -> *KGuard;
fn kunlock(g: sink *KGuard, lk: *KLock);
// accessor idiom: fn <name>(g: borrow *KGuard) -> *<ProtectedData>;

fn rtos_task_add(id: {0..<4 as usize}, sp: usize);
fn rtos_start();
fn task_self() -> {0..<4 as usize};
fn task_yield();

struct Msg { kind: u32; len: u32; body: [u8; 56]; }
fn chan_send(ch: {0..<4 as usize}, m: *Msg);
fn chan_recv(ch: {0..<4 as usize}, out: *Msg);
```

Channels use COPY/rendezvous semantics (synchronous send-blocks-until-
receiver-ready) specifically to sidestep buffer-ownership problems by
construction -- no buffer exists to alias or leak. Zero-copy/lease-style
(Hubris-inspired) is an explicitly deferred v2, blocked on issue #89's
still-open affine-multi-instance problem (the SAME wall `SlotLease` in
`affine_escape_via_index.tkb` was built to explore). `cpu_id()`'s
refined return type today (`{0..<1 as usize}`) is deliberate: it is what
lets a future per-CPU array index (`percpu_state[cpu_id()]`) become
`--forbid-trap`-clean the moment NCPU grows, with no code change at the
call site.

**PoC 1 of 3: `examples/klock_guard`** (this entry's actual deliverable
-- `percpu` and `chan_rendezvous` are follow-on PoCs, not yet started).
`struct KLock { word: i32; }` (word is an unused placeholder for future
per-lock state -- v1's real exclusion is `disable_irq`/`enable_irq`,
already present as raw asm symbols in `examples/common_qemu/startup.S`
but never previously declared as a takibi `extern fn` from any `.tkb`
file), `affine opaque struct KGuard;`, `klock(lk: *KLock) -> *KGuard`,
`kunlock(g: sink *KGuard, lk: *KLock)`, and an accessor pair
(`shared_get`/`shared_add`, each taking `g: borrow *KGuard`) binding a
`Shared { counter: i32; }` global to the lock. Verified via real QEMU
execution (`counter: 15` / `counter: 115` / `done`, matching 5+10 then
+100) -- compiled `--forbid-trap`-clean immediately with no unrefined-
first pass needed, unlike the `fatfs`/SD-card milestone: this PoC has no
array indexing or raw-pointer arithmetic at all, so there was no bounds-
check surface for `--forbid-trap` to ever flag.

Two properties genuinely PROVEN at compile time, verified with real
fixtures: (1) forgetting `kunlock()` is rejected -- new negative fixture
`examples/klock_guard_forgot_unlock` (`affine value 'g' is never
consumed`), reusing issue #89's existing never-consumed check with no
compiler changes; (2) double-unlock is rejected -- the existing double-
consume check, since `kunlock` takes `sink`, also with no compiler
changes needed (not given its own redundant fixture, since that
mechanism already has generic coverage from `affine_double_consume`).
One property explicitly documented as NOT proven, to avoid overclaiming:
the accessor idiom (routing access to `shared` through `shared_get`/
`shared_add`) is a NAMING CONVENTION only -- takibi has no module-private
field visibility (the same gap noted in this file's `FatFile`/issue #97
follow-up entry), so nothing stops `shared.counter = 42;` written
directly, bypassing `klock()` entirely. Closing that gap is exactly the
kind of fine-grained-access-control work deferred to a later, real
multi-instance-affine design, not attempted here.

**Files**: `examples/klock_guard/klock_guard.tkb` + `.expected` (new),
`examples/klock_guard_forgot_unlock/klock_guard_forgot_unlock.tkb` +
`.error` (new), `Makefile` (`EXAMPLES` list), `scripts/run_qemutest.sh`
(2 new registrations). Zero compiler changes -- this PoC, like
`affine_escape_via_index`, is pure application of already-landed
features. `make check` (80/80) and `make langcheck` pass.

**Follow-up: filed as its own issue rather than a footnote here.** The
user asked whether the "accessor idiom is naming convention only, not
enforced" limitation above should be appended to an existing issue or
get a dedicated one. Recommended a dedicated issue: it is a distinct
concern from #89 (#89 tracks *consumption* discipline for a value
already in hand; this is about *reachability* -- whether a value can be
touched at all without going through a designated entry point), and it
had already surfaced once before (the `FatFile`/issue #97 follow-up
entry above, "Rust solves that specific problem with a THIRD,
independent mechanism... a form of file-scoped field visibility this
language does not have today") -- two independent occurrences of the
same gap is a real pattern, not a one-off worth burying in either
feature's own issue. Filed as **issue #108**, "No module-private field
visibility -- accessor idioms (KGuard, FatFile) are naming convention
only, not enforced." Explicitly scoped as evidence-collection, not an
implementation request (YAGNI) -- no concrete feature needs this to ship
yet; becomes relevant once the RTOS work moves past a giant lock into
real fine-grained per-resource locking, or `FatFile`-style
constructor-validity becomes a concrete need.

## Simple RTOS (issue #66), PoC 2/3: `examples/percpu`

Second of the three proposed RTOS-API proof-of-concept examples (see
PoC 1's entry above for the full API and design rationale). Proves that
`cpu_id()`'s refined return type, `{0..<1 as usize}` (NCPU = 1 today),
is what lets `percpu[cpu_id()]` compile clean under `--forbid-trap` with
*zero* runtime bounds check -- the refined range exactly matches
`percpu`'s own declared array size, so the access is proven in range at
every call site with no annotation burden on the caller. Verified via
real QEMU execution (`cpu_id: 0` / `bump: 1` / `bump: 2` / `done`) and
compiled `--forbid-trap`-clean on the first attempt (no unrefined-first
pass needed, same reasoning as PoC 1 -- a single, already-refined array
index, no raw pointer arithmetic).

Also demonstrates why the RTOS design widens `NCPU` (rather than
dropping `cpu_id()`'s refinement) once real multi-core hardware (issue
#6) exists: `{0..<NCPU as usize}` stays `--forbid-trap`-clean for every
existing `percpu[cpu_id()]` call site with no code change there at all
-- only `cpu_id()`'s own body needs to change to read a real per-core ID
register.

**Negative contrast, not just a positive demo**: `examples/
percpu_unrefined_rejected` is the identical `percpu[id]` access, but
with `cpu_id()` declared to return plain `usize` instead of the refined
type. Rejected under `--forbid-trap`
(`array bounds check remains: index type usize cannot prove range
{0..<1}`, same message shape as the pre-existing `forbid_trap_wrong`
fixture) -- concrete evidence that PoC 1's clean compile comes from the
refined return type doing real work, not from `NCPU` merely happening to
be 1 today.

**Files**: `examples/percpu/percpu.tkb` + `.expected` (new), `examples/
percpu_unrefined_rejected/percpu_unrefined_rejected.tkb` + `.error`
(new), `Makefile` (`EXAMPLES` list), `scripts/run_qemutest.sh` (2 new
registrations, the error-fixture one passing `--forbid-trap` through
like `forbid_trap_wrong` does). Zero compiler changes. `make check`
(82/82) and `make langcheck` pass.

## Simple RTOS (issue #66), PoC 3/3: `examples/chan_rendezvous`

Third and final planned PoC (see PoC 1's entry above for the full API
and design rationale). Proves a CSP-style synchronous (rendezvous)
channel -- `chan_send()` does not return until a `chan_recv()` on the
same channel has actually taken the value -- built as a small, generic
`chan_send(ch: *Chan, m: i32)`/`chan_recv(ch: *Chan) -> i32` wrapper
around the exact same primitives `examples/condvar`/`examples/msgqueue`
already use (`examples/common/sync.tkb`'s `MutexGuard`/`mutex_lock`/
`mutex_unlock`, sequence-counter `cond_wait`/`cond_signal`) -- no new
synchronization primitive, no compiler changes. Unlike `msgqueue`'s
bounded ring buffer (capacity 4, producer/consumer can run ahead of each
other), a `Chan` has no buffer at all, only a one-shot `full`-flagged
slot: `chan_send` waits on `slot_taken` twice (once before placing a
value, to wait for the slot to be free; once after, to wait for the
receiver's ack), `chan_recv` waits on `slot_full` and then signals
`slot_taken`. This second wait inside `chan_send` is what makes it a
true rendezvous rather than a fire-and-forget mailbox.

Verified with a genuine two-task ping-pong on the existing preempt
scheduler (`examples/preempt/preempt.tkb`'s round-robin tick switch,
reused byte-for-byte -- same `SchedState`/`irq_dispatch`/
`SysTick_Handler`/`pendsv_dispatch` shape as `msgqueue.tkb`), over TWO
channels (`chan_ab`: ping -> pong, `chan_ba`: pong -> ping), exercising
both directions rather than one producer and one consumer as
`examples/msgqueue` does: `task_ping` sends `0..5`, `task_pong` replies
with each value times 10, `task_ping` prints what comes back. Compiled
`--forbid-trap`-clean on the first attempt (same reasoning as PoC 1/2 --
no raw pointer arithmetic, only literal-range `for` loops and struct
field access through a pointer parameter, an already-established pattern
this session from the `*align(N) T` work). Real QEMU output
(`ping got: 0/10/20/30/40`, `done`) matches expectations and was
confirmed deterministic across 5 repeated runs -- worth checking
explicitly since this is new preemption-plus-synchronization code, not
just new sequential logic.

**Files**: `examples/chan_rendezvous/chan_rendezvous.tkb` + `.expected`
(new), `Makefile` (`SYNC_OBJS`/`SEM_KERNELS`/`EXAMPLES`), `scripts/
run_qemutest.sh` (1 new registration). Zero compiler changes. `make
check` (83/83) and `make langcheck` pass.

All three planned RTOS PoCs (`klock_guard`, `percpu`, `chan_rendezvous`)
are now individually built and verified. Combining them into one
`examples/common/rtos.tkb` (integrating with the existing `scheduler`/
`semaphore`/`msgqueue` examples, per the PoC-to-file mapping table
proposed alongside the original API) is the next step, not yet started
-- to be confirmed with the user before starting, since it is a genuine
consolidation/design step rather than a straightforward continuation of
the same PoC pattern.

## Simple RTOS (issue #66): combining the 3 PoCs into `examples/common/rtos.tkb`

Along the way, discussed with the user (exploratory, not implementation)
why `examples/chan_rendezvous` uses an unbuffered (capacity-0) channel
rather than a bounded queue like FreeRTOS's `xQueueSend`/`xQueueReceive`.
Recorded here since the reasoning wasn't fully spelled out in that PoC's
own entry above: there are genuinely two separate justifications, not
one. (1) Takibi-specific: a buffered queue of pointers, for a future
zero-copy v2, would need per-slot ownership tracking -- exactly issue
#89's still-open affine multi-instance wall. A copy-based rendezvous
channel has no live buffer to own, sidestepping the problem by
construction; this reason doesn't actually bite yet for v1's plain
`i32`-by-value channels. (2) General CSP theory: an unbuffered
send/recv pair is a single atomic joint event, keeping both manual and
model-checked (FDR-style) reasoning tractable -- a bounded queue adds an
extra "how many items queued" state dimension per channel, and splits a
simple safety property (did the handshake happen) from a separate
liveness property (will it eventually drain). Buffering is a real,
legitimate throughput optimization (fewer forced context switches, burst
absorption) -- not added now because nothing currently measures a need
for it; `examples/msgqueue` already demonstrates the buffered end of
this same design space, so both points already exist as PoCs if a
future comparison is needed.

**Integration**: `examples/common/rtos.tkb` combines all three PoCs
verbatim (KLock/KGuard/klock/kunlock from `klock_guard`, `cpu_id()` from
`percpu`, Chan/chan_send/chan_recv from `chan_rendezvous`) plus new
generic task-registration/scheduling glue the PoCs didn't have:
`rtos_task_add(id, sp)` / `rtos_start()` / `task_self()`, generalizing
the fixed-3-task `SchedState`/`irq_dispatch`/`SysTick_Handler`/
`pendsv_dispatch` pattern every prior scheduler-using example (
`preempt`, `msgqueue`, `chan_rendezvous`) had duplicated inline into one
NTASKS=4-sized shared definition (task 0 is always `app_main()` itself,
tasks 1..3 available via `rtos_task_add`).

**`task_yield()` deliberately excluded from this pass**, per an explicit
check-in with the user before starting: no PoC or demo needs voluntary
task switching (every task already blocks correctly via `chan_send`/
`chan_recv`/spin-on-flag, released at the next scheduler tick), and it
would need a genuinely new mechanism (SVC or PendSV-kick-based voluntary
switch) nothing in this codebase has today. User chose to defer it
(matching the recommended option) until a concrete task actually needs
it, rather than build it speculatively alongside the rest of this file.
`task_self()` was kept in this pass (the other half of that same
check-in question) since it is nearly free -- a narrowed getter over
`sched.current_task`, no new mechanism -- and the proposed API already
named it.

**Two real bugs found integrating, neither visible in any individual
PoC**:
1. Raw-pointer indexing requires the index to be `isize` specifically,
   not merely a provably-in-range `usize` -- `rtos_task_add`'s
   `t[id]` (`id: {0..<4 as usize}`, `t: *usize`) was rejected with
   `raw-pointer index/offset must be isize, got '{0..<4}'`. None of the
   three individual PoCs hit this because none of them index a raw
   pointer with a refined-`usize`-typed value from a FUNCTION PARAMETER
   -- `klock_guard`/`percpu`/`chan_rendezvous` only ever index with a
   local `isize` field (`sched.current_task`) or a genuine `[T; N]`
   array (which the array-indexing path, not raw-pointer indexing,
   accepts a `usize`/refined type for). Fixed with an explicit
   `id as isize`. Worth remembering: raw-pointer (`*T`) indexing in this
   language is unchecked C-style pointer arithmetic with a fixed
   required index type (`isize`), a genuinely different code path from
   bounds-checked `[T; N]` array indexing (which is where the refined-
   type/`--forbid-trap` machinery actually applies) -- confirmed by
   noting `examples/preempt/preempt.tkb`'s own equivalent `sp[sched.current_task]`
   already compiles under `--forbid-trap` today specifically because it
   is raw-pointer arithmetic with no bounds check inserted at all, not
   because the index was ever proven in range.
2. A fixed `task_count = 4` (matching the new `NTASKS`-sized `tcb_sp`
   array) hung the demo silently: the round-robin switch in `irq_dispatch`
   /`pendsv_dispatch` visits every slot up to `task_count`, but
   `rtos_demo.tkb` only calls `rtos_task_add` for ids 1 and 2 (a 3-task
   demo, like `preempt`/`msgqueue`/`chan_rendezvous` before it), leaving
   slot 3 permanently zero -- the scheduler eventually switched to a
   task with stack pointer 0 and hung with no further UART output.
   Fixed by starting `sched.task_count` at 1 (just task 0) and having
   `rtos_task_add` raise it to `id + 1` whenever a higher id is
   registered, so `task_count` always tracks exactly how many task slots
   have actually been initialized, matching the original per-PoC
   fixed-3 SchedStates automatically for a 3-task demo with no separate
   task-count argument needed anywhere in the API.

**Verified via real QEMU execution** of `examples/rtos_demo` (two tasks,
ping/pong over two Chans exactly like `chan_rendezvous`, but each also
bumping a `KLock`-protected `Shared.counter` on every iteration to prove
the lock and the channel are independent, composable primitives rather
than accidentally depending on each other; `cpu_id()` printed from
`app_main` and `task_self()` printed after the scheduler stops, the
latter confirming `app_main` is genuinely task 0). Output (`cpu_id: 0`,
`ping got: 0/10/20/30/40`, `shared counter: 10` [5 iterations x 2 tasks
x 1 each], `task_self: 0`, `done`) confirmed deterministic across 3
repeated runs, matching every other value already independently
confirmed by the 3 individual PoCs. Compiled `--forbid-trap`-clean
(after the `isize` cast fix above -- no unrefined-first pass needed,
same reasoning as every RTOS PoC before it: no unproven array indexing
anywhere in the combined file).

**Files**: `examples/common/rtos.tkb` (new), `examples/rtos_demo/
rtos_demo.tkb` + `.expected` (new), `Makefile` (new `COMMON_RTOS`
variable, new `RTOS_OBJS` group with its own compile rule -- kept
separate from `SYNC_OBJS` rather than folded in, since `COMMON_RTOS` is
only a real prerequisite for `rtos_demo.o`, not `condvar.o`/
`msgqueue.o`/`chan_rendezvous.o`; `rtos_demo.o` added to `SEM_KERNELS`
for linking, needing the same `sem_asm.o` as every other `sync.tkb`-
based example; `EXAMPLES` list), `scripts/run_qemutest.sh` (1 new
registration). `make check` (84/84) and `make langcheck` pass.

This closes out the three-PoC RTOS exploration the user asked to see
"one at a time" -- all three are now both independently verified AND
integrated into one reusable file with a working combined demo. Further
RTOS work (task_yield, fine-grained locking beyond the giant lock,
issue #108's module-private visibility gap, real multi-core once issue
#6 has hardware) is left for whenever a concrete next need arises, per
this project's YAGNI principle.

### The `use` Feature's Motivating Incident: A GIC-Specific Helper Placed in a Shared File

**Historical incident that first exposed the gap** (from before the `use` feature existed, kept here for context):
while removing `irq.tkb`'s `IS_QEMU` branch, a new helper function was first placed in `uart.tkb` (concatenated
into literally every example) even though its body called `gic_init()`/`enable_usart1_irq()`, symbols that only
exist in a handful of builds -- this silently broke unrelated examples like `start` with an "Undefined function"
error, not caught until `make stm32build` was re-run over the whole example set. Ended up moving the functions
into `gic.tkb`/`nvic.tkb` instead (already only included where those symbols exist) -- `use` would not have
prevented the underlying design mistake (putting a GIC-specific helper in a file every example shares), only
made the resulting undefined-symbol error appear immediately when `uart.tkb` itself was next compiled, rather
than only when a later, unrelated Makefile target happened to expose it.

### IPv4/ICMP: split into 3 deliberately small steps (examples/inet_checksum, examples/ip_parse, examples/icmp_echo)

The original ask was "an IPv4 echo server" (ICMP ping responder), but that
bundles two genuinely new things at once -- the Internet checksum
algorithm (RFC 1071) and real virtio-net RX/TX of a new protocol -- making
failures hard to attribute to one or the other. Split into three
increasingly-integrated steps instead:

1. **`examples/inet_checksum`** -- the checksum algorithm alone, no
   networking I/O at all, following the exact same pure-compute demo
   pattern as `crc8.tkb`/`djb2.tkb` (operate on a fixed buffer, print a
   hex result, diff against a `.expected` file). Test vector is a real
   20-byte IPv4 header, verified independently in Python before being
   committed: checksumming it with its correct checksum field in place
   yields `0x0000` (how a receiver verifies a packet); checksumming it
   with that field zeroed yields `0xb1e6`, the value that belongs there
   (how a sender computes it). The function itself lives in
   `examples/common/inet_checksum.tkb` so `ip_parse` and `icmp_echo` can
   both reuse it rather than duplicating it.
2. **`examples/ip_parse`** -- IPv4 header field extraction and checksum
   *validation* only, no reply, and deliberately **not** wired to
   virtio-net at all: it parses two canned buffers baked into the binary
   (one valid, one with a corrupted TTL so the checksum no longer
   verifies) and prints the results. The virtqueue/IRQ plumbing was
   already fully proven by `net_echo`/`arp_reply`; re-exercising it here
   would test the same thing twice while adding nothing to what's new in
   this step (the parsing logic itself). Scope is intentionally narrow:
   only headers with no IP options (IHL must be exactly 5/20 bytes).
3. **`examples/icmp_echo`** -- the real thing: live virtio-net RX/TX
   (same pattern as `net_echo`/`arp_reply`) combined with IPv4/ICMP
   parsing and, for the first time, checksum *construction* (not just
   validation) for the reply. Validates the request's IP and ICMP
   checksums independently before replying and silently drops anything
   that fails either check, isn't addressed to `our_ip`, or isn't a
   well-formed echo request -- `scripts/icmp_echo_test.py` explicitly
   tests a corrupted-checksum request is dropped, not just that a valid
   one is answered. Builds the reply in place (swap MACs, swap IPs, fresh
   TTL, ICMP type 8->0, identifier/sequence/payload untouched) and
   recomputes both checksums from scratch with `inet_checksum` rather
   than attempting an incremental update -- simpler and reuses the
   already-verified function instead of a second, subtler algorithm.
- **`run_qemutest.sh` prints a `Failed: name1 name2 ...` line in its final
  summary** (via a `FAILED_TESTS` array appended to on every failure
  branch) rather than stopping at the first failure. Deliberate: QEMU
  boot cost makes fail-fast expensive to iterate against in CI (you'd only
  learn about the next failure after fixing and re-running), so the
  script always runs everything and reports the full failure list at the
  end instead.

### TCP: examples/tcp_parse (parse-only) + examples/tcp_echo (grown incrementally)

TCP is being split differently than IPv4/ICMP was, because TCP itself
splits into two genuinely different kinds of step:

- **`examples/tcp_parse`** is a one-shot separate example, exactly
  mirroring `ip_parse`: canned buffers, no virtio-net, just field
  extraction and checksum validation. This is a clean split because
  header parsing is a self-contained concern independent of connection
  state.
- **`examples/tcp_echo`** (handshake -> data echo -> close) is deliberately
  **one example grown incrementally**, not a separate example per stage:
  unlike ARP/ICMP (stateless, one-frame-in-one-frame-out), TCP's stages
  share a connection, so a standalone "handshake-only" binary wouldn't be
  a real artifact. Regression granularity instead comes from accumulating
  test *functions* in `scripts/tcp_echo_test.py` (mirrors
  `icmp_echo_test.py`'s multi-function structure), one per stage --
  `test_handshake_only`, `test_data_echo`, `test_close`,
  `test_reconnect_after_close`. **These functions are not independent**:
  `tcp_echo.tkb` supports exactly one connection, so
  `test_data_echo()`/`test_close()` continue the *same* connection
  `test_handshake_only()` established (shared module-level constants:
  `HANDSHAKE_CLIENT_PORT`/`HANDSHAKE_CLIENT_ISN`/`SERVER_ISN`) and must run
  in that order (`app_main()`'s `ok4 = ok3 and test_data_echo()` chain). Each
  still prints its own labeled PASS/FAIL line, so per-stage regression
  attribution still works even though execution is a chain, not
  independent calls. `test_reconnect_after_close()` is the one function
  that *is* independent -- a brand new connection after `test_close()` --
  specifically to catch a "close looks right but forgot to reset
  `conn_state`" bug that `test_close()` alone can't see (it only checks
  the reply, not that the server is usable again afterward).

  State cycle: `TCP_LISTEN` -> `TCP_SYN_RCVD` -> `TCP_ESTABLISHED` ->
  `TCP_LAST_ACK` -> back to `TCP_LISTEN`. No separate `CLOSE_WAIT`/
  `FIN_WAIT`: the server never has queued outbound data by the time a
  client FINs, so it ACKs the FIN and sends its own FIN in the same
  segment (`build_fin_ack`) rather than as two events.

**TCP checksum needs a "pseudo-header"** (12 bytes: src IP, dst IP, a
zero byte, protocol, TCP length) that is never actually transmitted but
is included in the checksum computation, prepended to the TCP header+data.
This doesn't fit `inet_checksum`'s single-contiguous-buffer signature, so
`examples/common/inet_checksum.tkb` was split into `checksum_add(data,
len, sum_in)` (accumulates an *unfolded* running sum, chainable across
non-contiguous buffers) and `checksum_fold(sum)` (carries + one's
complement, done once at the end) -- `inet_checksum` itself is now just
`checksum_fold(checksum_add(data, len, 0))`, so `ip_parse`/`icmp_echo`
needed no changes. The two-chunk chaining is valid per RFC 1071 because
the pseudo-header is exactly 12 bytes (a whole number of 16-bit words),
so only the *last* chunk (the actual TCP segment) can be odd-length and
need padding -- see `checksum_add`'s comment.

**`bytes_eq`/`bytes_copy`/`read_u16be`/`write_u16be` were extracted into
`examples/common/netutil.tkb`** at this point too (previously duplicated
verbatim in both `arp_reply.tkb` and `icmp_echo.tkb`) -- three call sites
needing the same four helpers was the threshold where deduplication
clearly paid for itself. Also added `read_u32be`/`write_u32be` for TCP's
32-bit sequence/acknowledgment numbers, same big-endian-byte-by-byte
reasoning as the 16-bit versions. Note `read_u32be` can produce a
"negative" `i32` bit pattern for seq numbers >= `0x80000000` (i32 is
signed) -- harmless for display (print via `uart_print_hex`, which shows
the bit pattern regardless of sign, not decimal `uart_print`) and harmless
for the modular arithmetic TCP sequence
numbers actually need, but worth remembering if a future step adds
seq-number *comparisons* (`<`, `>`) -- those need wraparound-aware
comparison logic, not a plain signed or unsigned `<`.

## HTTP Server (examples/http_server) -- the TCP/IP progression's payoff

Serves a single styled HTML page (inline CSS, dark/monospace theme) with
a live request counter on port 80. Built on `tcp_echo`'s state machine
(same LISTEN/SYN_RCVD/ESTABLISHED/LAST_ACK cycle), but is the first
example that is genuinely usable from a real browser, not just the
`-netdev dgram` synthetic test transport -- and getting that working
surfaced two real bugs/gaps that no earlier example's automated tests had
caught, because those tests only ever talked to *themselves*
(hand-crafted Python packets, never a real TCP/IP stack):

- **QEMU's `-netdev user` (SLIRP) refuses to deliver any IP packet until
  the guest has answered an ARP request for its address.** `net_echo`'s
  and `arp_reply`'s own tests never needed this, because `-netdev dgram`
  is a raw point-to-point pipe where the python script already knows the
  guest's MAC -- there's no link layer to resolve. A real network path
  always has one. Consequence: `http_server.tkb` has to combine ARP
  response (reused from `arp_reply.tkb`) and TCP/HTTP handling in the
  *same* kernel, dispatching on ethertype, since only one kernel can run
  at a time. Discovered by writing a throwaway probe kernel that just
  logged every received frame's ethertype under `-netdev user` -- only
  ARP frames showed up until ARP response was added.
- **Real TCP clients (SLIRP's kernel-grade TCP stack, and any real
  browser) always include a TCP options block on the SYN** (at minimum an
  MSS option, making the header 24 bytes / data offset 6, not the bare
  20-byte / data-offset-5 header `tcp_echo.tkb` and `tcp_parse.tkb`
  originally required). Since `scripts/*_test.py` construct every packet
  by hand and never bothered with options, this was completely invisible
  to `make qemutest` -- it only surfaced once tested against a real
  client. Fixed in both `http_server.tkb` and (for consistency,
  afterward) `tcp_echo.tkb`: compute `tcp_hdr_len` from the segment's
  actual data offset (accepting doff 5..15) and use it to locate where
  data starts, rather than hardcoding the no-options 20-byte assumption;
  options themselves are never parsed, just skipped over.
  `tcp_parse.tkb` turned out not to need this fix at all -- it already
  computed and *displayed* `data_offset` generically, it just never used
  it to locate anything (no reply construction, so nothing was ever
  assumed to start at a fixed offset).

  **The fix is not just "accept a wider range of doff values"; the data
  itself has to move.** `tcp_echo.tkb`'s echo reply always writes a clean
  20-byte header (no options) starting at `tcp+0`, so if the *received*
  segment had a 24-byte header, its payload sits at `tcp+24`, not
  `tcp+20` -- reusing the same buffer in place without shifting the
  payload down would silently prepend 4 bytes of stale option data and
  truncate the last 4 bytes of the real payload. `build_data_echo` now
  takes the actual data pointer and `bytes_copy`s it down to `tcp+20`
  first when they differ; safe even though the ranges can overlap,
  because the destination never leads the source and the copy loop goes
  forward (same direction requirement as `memmove` for this case -- see
  the function's comment). Loosening the acceptance check *without* this
  shift would have silently swapped "reject options-bearing segments" for
  "corrupt them," which is worse. `scripts/tcp_echo_test.py` gained
  `test_syn_with_options_accepted()` (sends a SYN with a real 4-byte MSS
  option, verifies a normal SYN-ACK, then RSTs the half-open connection
  so it doesn't hold the single connection slot for the rest of the
  file's tests) so this doesn't silently regress again.

**our_ip is `10.0.2.15`, not the `192.0.2.1` TEST-NET-1 address every
earlier example uses.** SLIRP's `hostfwd` rule routes to a fixed default
guest address (confirmed empirically, not just from memory -- see the
probe kernel above), and the guest must actually own that address for
the connection to land anywhere. `scripts/http_server_test.py` (still a
`-netdev dgram` test) uses the same `10.0.2.15` for consistency even
though its raw transport doesn't technically require it.

**Response construction needed two new `netutil.tkb` primitives**:
`copy_str(dst, src)` (copies a NUL-terminated string literal into a
buffer, returns length -- same idea as `uart_puts` but targeting memory
instead of streaming to UART) and `write_udec(buf, n)` (writes decimal
digits with no leading zeros, returns digit count -- same recursive
approach as `print.tkb`'s unsigned decimal core, targeting a buffer). Needed
because the response's `Content-Length` and the request counter are both
variable-width at runtime, so the response has to be *built* (body first,
into a staging buffer `html_body`, to learn its length; then headers,
using that now-known length; then the body copied in after) rather than
templated with a fixed size like every earlier fixed-format reply
(SYN-ACK, ICMP echo reply, etc.) was.

**Manual browser access**: `make qemu-http-server` (uses `-netdev
user,hostfwd=tcp::$(HTTP_HOST_PORT)-:80` instead of the automated tests'
`-netdev dgram`; `HTTP_HOST_PORT` defaults to 18080 -- not 8080, which
immediately collided with Syncthing on a real dev machine the first time
this was tried outside the devcontainer; override with e.g.
`make qemu-http-server HTTP_HOST_PORT=8081` if 18080 is also taken), then
open `http://localhost:18080/` in a real browser. Reloading the page
re-runs the whole connect/request/respond/close cycle and the counter
visibly increments -- this is deliberately *not* something
`make qemutest` exercises (see the request-counter determinism note
below), since it depends on a human clicking reload, not a scripted
sequence.

`qemu-http-server` quits on plain **Ctrl-C** (every other `qemu-*` target
needs QEMU's Ctrl-A X escape instead) -- see `HTTP_SERVER_QEMU_FLAGS` in
the Makefile for the full reasoning (raw-mode terminal pass-through vs.
`-serial file:/dev/stdout`, confirmed via `kill -INT` rather than assumed).
The Makefile target also echoes the actual browser URL right before
launching QEMU, since the guest has no way to know the host-side
`HTTP_HOST_PORT`.

**`make stm32-http-server`**: same demo, on the real STM32F746G-DISCOVERY board instead of
QEMU (flashes `examples/http_server/kernel_stm32.bin` via `st-flash`, prints the URL to open,
then streams the board's own UART log lines until Ctrl-C). Unlike `qemu-http-server`'s fixed
`localhost:$(HTTP_HOST_PORT)`, the printed URL is parsed live from `examples/common_stm32/
netconfig.tkb`'s `HTTP_SERVER_IP` constant (`grep`+`tr`, no hardcoded IP in the Makefile), so it
can't silently drift out of sync if that constant is ever changed. The serial reader is
attached (backgrounded) *before* the explicit `st-flash reset`, not after, so the board's
earliest "ready" message isn't lost to a reader that hasn't opened the port yet -- same
ordering reasoning as `read_until_quiet`'s `WAIT_FOR_DATA` case in `scripts/run_hwtest_ram.sh`.
Needs the board connected and its Ethernet port wired directly to this machine's NIC (see the
STM32 hardware bring-up section's devcontainer note for the `/dev-host/ttyACM0` serial path).

**Request counter determinism** (flagged as a concern before
implementation, worth recording why it's actually safe): `make qemutest`
boots a fresh QEMU process per test, so `request_count` always starts at
0. `scripts/http_server_test.py` sends exactly two real, sequential
requests and asserts the counter reads 1 then 2 -- deterministic, not
timing-dependent. The one way this *could* have been flaky is if a
network-level retry (see `send_and_wait`, used for the SYN and the GET in
case a packet is lost before the guest finishes booting) caused the
server to process the same logical request twice; it can't, because the
retry resends the identical frame bytes (same sequence number), and the
server only acts on a segment when its `seq` matches `conn_rcv_nxt`
exactly -- a resent duplicate's `seq` is already stale by the time a
retry would fire, so it's silently ignored. This is the same
duplicate-suppression property `tcp_echo_test.py` already depends on,
just relied on for a new reason here.

## HTTP/SD/RTOS Follow-up: Shared HTTP Core, Multi-Segment SD Content, and TCP Close Regression

The HTTP examples were refactored after `http_server_sdcard_rtos` grew
large enough that the duplicated TCP/IP state machine and SD-card response
code became a maintenance risk.

**Shared code now lives in two common files**:

- `examples/common/http_server_common.tkb`: ARP/IPv4/TCP state machine,
  including SYN/SYN-ACK, request dispatch, ACK-driven multi-segment
  response progress, FIN/ACK close handling, and stale closed-connection
  RST handling.
- `examples/common/http_sdcard_server.tkb`: HTTP path mapping to FAT 8.3
  names, content type selection (`text/html` and `image/png`), response
  header generation, and multi-segment reads through example-supplied
  `http_file_size` / `http_read_chunk` callbacks.

`examples/http_server/http_server.tkb`, `examples/http_server_sdcard/
http_server_sdcard.tkb`, and `examples/http_server_sdcard_rtos/
http_server_sdcard_rtos.tkb` now provide only their response/storage
callbacks and a short `app_main()` loop. The SD-card examples share the
same real SD-card content directory, `examples/sdcard_content`, containing
`INDEX.HTM`, `ABOUT.HTM`, and `ICON.PNG`; the hardware test reads expected
bodies from those files instead of duplicating the contents in Python.

**STM32/RAM debug ELF targets were added for the HTTP examples**:

- `examples/http_server/kernel_stm32_ram.debug.elf`
- `examples/http_server_sdcard/kernel_stm32_ram.debug.elf`
- `examples/http_server_sdcard_rtos/kernel_stm32_ram.debug.elf`

These are intended for OpenOCD + `gdb-multiarch` debugging of RAM-loaded
firmware without changing the normal hardware-test flow. Adding these
targets exposed a compiler/DWARF bug: function pointer parameters were
emitted as bare DWARF subroutine types instead of pointer-to-subroutine
types. `lib/llvm_gen.ml` now wraps `TypeFn` debug types in a pointer type,
and `test/test_takibi.ml` has a regression test for that shape.

**Intermittent `http_server_sdcard_rtos (stm32/ram)` `/ICON.PNG` timeout
debugging**: the failure initially looked like possible RTOS stack
corruption because it appeared only in the RTOS + SD + multi-segment path.
GDB showed otherwise:

- the target was stopped in `net_rx_wait()`, not in a fault handler;
- `CFSR` and `HFSR` were zero;
- the TCP state had returned to `Listen`;
- raw frame inspection and a host-side packet capture showed the client
  eventually sent RST during the PNG transfer.

The root cause was TCP close handling, not stack layout. After the server
sent its response with FIN, a real host TCP stack sent `FIN|ACK` after
reading the response. The common HTTP state machine did not ACK that
client FIN before returning to `Listen`, so the host kept retransmitting
old FINs from closed connections. In the RTOS variant, the HTTP task
performs synchronous SD-card read RPCs through the SD worker task; while
those reads are in progress, the HTTP/TCP state machine cannot promptly
drain noisy stale traffic or answer new connection attempts. Under repeated
tests that delay was enough for `/ICON.PNG` to time out and reset.

Fixes:

- in `LastAck`, ACK a client `FIN|ACK` and then return to `Listen`;
- in `Listen`, answer stale non-RST ACK traffic for closed connections
  with a stateless RST, so the host stops retransmitting old FINs;
- raise `HTTP_SEGMENT_PAYLOAD_MAX` from 1000 to 1400 bytes, reducing the
  number of ACK-driven SD read RPCs needed for the PNG response.

`scripts/http_server_test.py` now explicitly sends a client `FIN|ACK` after
the server's response+FIN and verifies the final pure ACK. That makes the
specific close-handshake regression visible in the QEMU integration suite
instead of relying on a long real-hardware RTOS stress path to surface it.

Validation at the time of the fix:

- 30 consecutive `eth_http_server_sdcard_test.py` runs against the RTOS RAM
  debug build passed;
- `make check` passed;
- `make hwcheck-net` passed: all 9 Ethernet hardware tests passed.

This incident motivated GitHub issue #117: start with a practical
typestate/state-machine checker before attempting full session types. Such
a checker could make missing `(state, event)` cases like `LastAck +
FIN|ACK` visible at compile time. A separate future effect/latency check
could flag latency-sensitive TCP paths that synchronously call blocking SD
or channel operations.

## GitHub Issue #46: DWARF for Practical GDB Use

The DWARF work moved from "metadata exists" to a live QEMU/GDB regression
fixture in `examples/dwarf_debug`. The fixture now checks:

- typed globals, enum names, struct member layout, slice fat-value layout,
  and `set variable` through QEMU's gdbstub;
- scalar locals, immutable locals preserved through debug-only allocas,
  slice locals, mutable aggregate locals, updated aggregate values, fixed
  arrays, and nested aggregates;
- aggregate function arguments after the prologue stores them into
  stack-backed debug locations;
- `step`, `next`, and basic `bt` usability;
- locals declared in `if`, `else`, `while`, `match`, wildcard match arms,
  nested blocks, `for`, and `foreach`.

The live GDB output is normalized and compared against
`examples/dwarf_debug/dwarf_debug.gdb.expected`. This is intentionally more
readable than a pile of independent greps: a failure shows the expected
debugger transcript shape and the diff. The old intermittent
`run_dwarf_test "fizzbuzz (dwarf)"` line-table-only check was deleted
because it exercised a weaker proxy than the live GDB test and had already
proven flaky for reasons outside Takibi DWARF emission.

Several compromises are intentional and tracked separately:

- Takibi shadowing semantics are not decided, so same-name local lexical
  scope behavior is deferred to GitHub issue #122.
- LLVM's OCaml bindings do not expose the APIs Takibi would need for the
  clean implementation: `dbg.value`-style value locations for SSA/register
  values and subrange/subscript metadata construction for natural fixed
  array display. Current workarounds use debug-only allocas, volatile
  debug-preservation stores, prologue stepping for aggregate parameters,
  and GDB artificial array expressions. This is tracked in GitHub issue
  #123.
- Current `-g` prioritizes debugger usability and can change code
  generation compared with an optimized no-debug build. A separate
  "debug the exact optimized binary, even with poorer variable visibility"
  mode is tracked in GitHub issue #124.

The DWARF work also found one compiler bug while adding STM32 RAM debug ELF
targets for HTTP examples: function pointer parameters were emitted as bare
DWARF subroutine types instead of pointer-to-subroutine types. That is fixed
in `lib/llvm_gen.ml`, with a regression in `test/test_takibi.ml`.

## GitHub Issue #118: Explicit `inline fn` and Host-Side Integration Checks

Issue #118 started from a concrete code-generation observation:
`examples/common/http_server_common.tkb`'s small `classify_tcp_event`
helper survived as a standalone call in `http_server_poll_once`
(`R_AARCH64_CALL26 classify_tcp_event`). The first tempting fix was to add
a general LLVM inliner to the custom optimization pipeline, but that was
too broad for Takibi's embedded-first defaults: it would make every helper
subject to optimizer heuristics, and it also disturbed the live DWARF/GDB
fixture when applied to `-g` builds.

The implemented design is explicit instead:

- the language accepts `inline fn name(...) { ... }`;
- the AST records `is_inline`;
- codegen maps only those functions to LLVM's `alwaysinline` attribute;
- the optimizer runs `always-inline`, not the general module inliner;
- `-g` builds skip the inlining pass so debugger stepping and local-variable
  visibility stay stable.

`classify_tcp_event` is now marked `inline fn`, which removes the call
relocation in normal builds while keeping the source-level intent visible.

The regression test deliberately does **not** depend on `http_server`'s
internal helper names. A dedicated `examples/inline_check/inline_check.tkb`
fixture defines both `inline_helper` and `normal_helper`; the host-side
integration harness verifies that only the former loses its call relocation.
That same host-side section also runs the Linux/AMD64 `linux_hello` binary,
so `make qemutest`/`make check` now report these non-QEMU checks through the
same coloured PASS/FAIL stream as compile-error, DWARF, and QEMU tests.

Validation: `make qemutest` and `make check` both passed with 103 total
integration cases after the change.

## 2026-07-15: Takibi Core Slice 1, Indexed Runtime Owners

Implemented the first vertical slice of the four-layer Core described in
`TAKIBI_CORE.md`. The language now accepts integer-indexed first-class
`affine struct` / `linear struct` declarations, indexed types `Name[n]`, and
singleton runtime integers `T @ n`. Static names in signatures are implicit
universals: function bodies check them rigidly, and every call receives a
fresh instantiation. Owner field projection substitutes the actual index, so
runtime data, range facts, and identity constraints remain connected.

`examples/affine_escape_via_index` now uses a private
`linear struct SlotLease[n: usize]` containing the private refined runtime
index. Its read/write/close operations no longer accept an independent
`idx`; no `unsafe`, pointer-bit encoding, invalid-index fallback, or runtime
bounds trap remains. LLVM lowers the owner to `{ usize }`, passes it by value,
extracts the field in accessors, and erases only static identity and ownership
facts.

The slice deliberately rejects owner casts, address-taking, globals, nested
fields, arrays/slices, and pointer storage until place/storage tracking is
generalized. It also rejects moving from `borrow`. Added range- and
identity-negative integration fixtures plus parser, inference, privacy,
fresh-instantiation, borrow, storage, and LLVM-erasure unit regressions.

Final soundness review separated call-site unification metavariables from
generative rigid identities for unknown runtime values, preserved singleton
facts through inferred immutable aliases, and closed uninitialized owner,
live overwrite, borrowed/sink reassignment, discarded owned result, and
borrowed-owned-temporary paths. Singleton values cannot be addressed or put
in ordinary mutable storage, preventing mutation through a widened pointer
from leaving a stale `@ n` proof. Mutable indexed-owner fields lower to real
aggregate stores.

The remaining trust boundary is explicit: a private constructor can still
mint two owners with the same static identity. `linear` checks the lifetime of
each minted value, not uniqueness of constructor authority; a later erased
permission/view slice must enforce the latter.

Validation: all 630 Alcotest cases passed; `make qemutest` and the full
`make check` passed all 105 host, compile-error, DWARF, QEMU, and STM32 build
checks.
