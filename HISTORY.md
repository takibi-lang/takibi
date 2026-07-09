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
