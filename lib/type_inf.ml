open Types

module StringSet = Set.Make (String)

(* Type environment: immutable map from variable name to (type, is_mutable) *)
type tyenv = (ty * bool) StringMap.t

(* Struct environment: maps struct name to (ordered field list, is_packed,
   align_bytes) -- is_packed/align_bytes are needed by const_type_size/
   const_field_offset below (see their comment for why). *)
type senv = ((string * Ast.type_expr) list * bool * int option) StringMap.t

(* sizeof(T)/offsetof(T, field) are only ever a genuine OCaml-computable
   compile-time constant here when the layout cannot depend on
   target-specific DataLayout: fixed-width primitive integers/bool, fixed
   -size arrays of such, and PACKED structs (with no align(N) -- tail
   padding is a deliberately deferred extension, not a hard limit; see
   the GitHub issue #77 fix this was added for) composed entirely of such
   fields, recursively. Every other type (pointers, usize/isize, enums,
   non-packed structs, aligned structs) keeps sizeof/offsetof's existing
   plain TUsize type, unrefined -- exactly the pre-existing behavior,
   deferring the actual value to codegen's DataLayout lookup as before.
   This computation is later re-verified against the real DataLayout in
   lib/llvm_gen.ml (sync rule, like every other type_inf/llvm_gen pair in
   this project) rather than trusted silently. *)
let rec const_type_size (senv : senv) (ty : Ast.type_expr) : int option =
  match ty with
  | Ast.TypeBool | Ast.TypeU8 | Ast.TypeI8 -> Some 1
  | Ast.TypeU16 | Ast.TypeI16 -> Some 2
  | Ast.TypeU32 | Ast.TypeI32 -> Some 4
  | Ast.TypeU64 | Ast.TypeI64 -> Some 8
  | Ast.TypeArray (elem, n) ->
      (match const_type_size senv elem with
       | Some sz -> Some (sz * n)
       | None -> None)
  | Ast.TypeNamed name ->
      (match StringMap.find_opt name senv with
       | Some (fields, true, None) ->
           List.fold_left (fun acc (_, fty) ->
             match acc, const_type_size senv fty with
             | Some a, Some b -> Some (a + b)
             | _ -> None
           ) (Some 0) fields
       | _ -> None)
  | _ -> None

(* Cumulative byte offset of `field` within packed struct `sname`, i.e.
   const_type_size of every field strictly before it. Tail padding from
   align(N) is irrelevant here even in principle (it is only ever
   appended AFTER the last real field -- see lib/llvm_gen.ml's Pass 0
   comment), but this still requires align_opt = None, matching
   const_type_size's scope exactly so the two never disagree about which
   structs are "safe". *)
let const_field_offset (senv : senv) (sname : string) (field : string) : int option =
  match StringMap.find_opt sname senv with
  | Some (fields, true, None) ->
      let rec go = function
        | [] -> None
        | (fname, _) :: _ when fname = field -> Some 0
        | (_, fty) :: rest ->
            (match const_type_size senv fty, go rest with
             | Some a, Some b -> Some (a + b)
             | _ -> None)
      in go fields
  | _ -> None

(* Enum environment: maps enum name to (underlying_ast_type, [(variant_name, value)]) *)
type eenv = (Ast.type_expr * (string * int) list) StringMap.t

let lookup_binding loc name env =
  match StringMap.find_opt name env with
  | Some b -> b
  | None   -> raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" name))

let lookup loc name env = fst (lookup_binding loc name env)

(* io T is a storage qualifier; strip it to get the value type for expression checks *)
let strip_io t = match repr t with TIo inner -> inner | _ -> t

let unify_at loc t1 t2 =
  try unify t1 t2
  with Unify_error msg -> raise (TypeError (loc, msg))

(* GitHub issue #100 follow-up: a bare integer literal's inferred type is a
   polymorphic, unbound type variable (see IntLit's own case below,
   `fresh ()`), so `unify_at` alone lets it bind STRUCTURALLY against any
   refined target -- e.g. `let v: {0..<8 as usize} = 20;` -- without ever
   checking whether the literal's actual VALUE fits {lo..<hi}. That is a
   genuine soundness hole, not just a missing diagnostic: downstream code
   (an array index, a narrowed subslice, ...) trusts `v`'s declared
   {0..<8} range to elide its own bounds check, so an out-of-range literal
   silently "proving" a range it doesn't satisfy lets --forbid-trap accept
   code with a real, unchecked out-of-bounds access at runtime. Checked
   here at every site where a literal-or-Const_env-constant expression
   flows into an already-known target type (Let, Assign, AssignDeref,
   AssignIndex, AssignField, Return, Call arguments, StructLit fields) --
   reuses Const_env.bound_value, the same "is this expression a
   compile-time-known integer" resolver already used throughout this file
   (e.g. collect_bounds's range_of), so bare literals and named constants
   are both covered identically. A non-constant expression (a variable, a
   computed value) is left alone: unify's existing anti-subtyping guard
   (`t1, TRefinedInt (lo, hi, base) when t1 = repr base -> ...`) already
   correctly rejects an unproven plain-base value flowing into a refined
   target, so there is nothing extra to check there. *)
let check_literal_fits_refined loc (e : Ast.expr) (target : ty) =
  match repr target with
  | TRefinedInt (lo, hi, _) ->
      (match Const_env.bound_value e with
       | Some k when k < lo || k >= hi ->
           raise (TypeError (loc, Printf.sprintf
             "constant value %d does not fit the refined type {%d..<%d}"
             k lo hi))
       | _ -> ())
  | _ -> ()

(* -- Expression inference -------------------------------------------------- *)

(* True for all unsigned integer types (including usize) *)
let is_unsigned_ty = function
  | TU8 | TU16 | TU32 | TU64 | TUsize -> true
  | _ -> false

(* min/max's "unknown bound" placeholder (see the Call case below) must
   itself be a legal value of whichever base type the result unifies
   against, or a fully-unconstrained call fails to type-check for no real
   reason: types.ml's TRefinedInt subtyping rules reject bounds wider than
   a narrow type's own representable range (u8 needs hi <= 256, u16 needs
   hi <= 65536, i8/i16 need |lo|/hi within their own range), so one fixed
   magic constant everywhere is only safe for i32/i64/u32/u64/usize, not
   u8/u16/i8/i16. Clamp per base instead. Sync rule: lib/llvm_gen.ml's
   min/max codegen mirrors this exactly (base must be repr'd first --
   see the Call case's own comment on why). *)
let min_max_sentinel base =
  match base with
  | TI8  -> (-128, 128)
  | TI16 -> (-32768, 32768)
  | TU8  -> (0, 256)
  | TU16 -> (0, 65536)
  | t when is_unsigned_ty t -> (0, 1_000_000_000)
  | _ -> (-1_000_000_000, 1_000_000_000)

(* Accept bool or any integer type as a condition (for if/while) *)
let check_cond loc ct =
  match repr ct with
  | TBool -> ()
  | _ -> unify_at loc ct TI32

(* Widen TRefinedInt to its OWN base type; leave explicit-width types
   unchanged. Used by arithmetic ops that do not propagate range
   information (Mul, Div, shifts, bitwise). Without this, `i: {0..<8}` in
   `i * 4` would produce TRefinedInt(0,8,base) and later cause
   `base >> TRefinedInt` to fail the unification anti-subtyping guard.
   Widening to the refined value's OWN base (not unconditionally TI32) is
   what makes this correct now that a refined range can be tied to any
   primitive type: `u64_i: {0..<8}:u64` in `u64_i * 4` must widen to TU64,
   not TI32 -- widening to the wrong (narrower or differently-signed) type
   would either lose information or produce a bogus unify error against
   the other, genuinely-u64-typed operand. *)
let canon_ty t = match repr t with TRefinedInt (_, _, base) -> base | t -> t

(* Require an integer type, WITHOUT defaulting a genuinely-unconstrained
   type variable -- only reject it if it's already resolved to something
   CONCRETE and non-integer (e.g. `buf[some_bool_var]`); an unresolved
   TVar is left alone, deferring to whatever resolves it later (more body
   usage, e.g. a for-loop counter passed to a function elsewhere in the
   loop) or, failing that, to Types.to_ast's `TVar (Unbound _) ->
   TypeI32` end-of-pipeline default. Used everywhere an index/loop-bound
   -shaped value is required (Index, AssignIndex, SliceOf, For): unlike
   TRefinedInt (which enjoys unconditional leniency into TI32 via its own
   subtyping rule), a BARE concrete type like TU8/TUsize/TI64 has no such
   rule, so a plain `unify_at loc t TI32` alone wrongly rejects, e.g., a
   for-loop counter over `s.len` (TUsize, not wrapped in TRefinedInt when
   the length isn't a compile-time constant) used as an array index -- a
   real gap found while generalizing For's loop-counter base (see
   CLAUDE.md's "Refinement Numerical Type" section).

   Originally this ALSO defaulted an unresolved TVar to i32 immediately,
   right here -- but that defeated deferred, usage-driven inference for a
   for-loop counter the MOMENT the body indexed anything with it
   (`buf[i]`), since Index calls this same function: the counter's shared
   type variable would get defaulted right there, before any LATER
   body statement (e.g. `foo(i)` with a concrete-typed parameter) ever
   got a chance to pin it. Removing the eager default here is safe for
   Index/AssignIndex/SliceOf too: none of their own downstream logic
   actually depends on an index's type being concrete (Index/AssignIndex
   only care about the CONTAINER's type; SliceOf's bound_range already
   has a graceful "unknown range" fallback for exactly this case) -- see
   CLAUDE.md's "For-Loop Counters..." follow-up section for the full
   story and its one honest limitation. *)
let require_integer loc t =
  let base = canon_ty t in
  match repr base with
  | TVar { contents = Unbound _ } -> ()
  | TI8 | TI16 | TI32 | TI64 | TU8 | TU16 | TU32 | TU64 | TIsize | TUsize -> ()
  | _ -> raise (TypeError (loc,
      Printf.sprintf "expected an integer type, got '%s'" (to_string t)))

(* Require an [T; N]/slice INDEX be usize specifically -- narrower than
   require_integer.
   Mirrors Rust/Zig, where array/slice Index is only ever implemented for
   usize: a value proven safe in some OTHER base (u8, i32, ...) must be
   re-typed or explicitly cast, even though the compiler can see it fits.

   Deliberately NOT implemented as a plain `unify_at loc t TUsize`: a bare
   `unify_at` would go through TRefinedInt's existing subtyping-into-TUsize
   leniency (types.ml's `TRefinedInt (lo, _), TUsize when lo >= 0 -> ()`),
   which ignores the refined value's own base entirely -- exactly the
   escape hatch that makes this check TOOTHLESS for the common case, since
   nearly every for-loop counter is Const_env-const-bounded (wrapped in
   TRefinedInt) and would sail through unchanged regardless of its base.
   This function checks the base directly instead.

   Unlike require_integer, this ACTIVELY resolves (not just tolerates) an
   unresolved TVar: both a bare literal index and a for-loop counter's
   still-open base get pinned to TUsize immediately. This is safe (unlike
   require_integer's old eager-i32-default mistake, see its own comment)
   because pinning to usize is exactly the type indexing already demands
   -- there is no "wait for a later, more informative use" concern the way
   there was for a bare loop counter with no fixed role yet. *)
let require_usize_index loc t =
  let reject () =
    raise (TypeError (loc, Printf.sprintf
      "array/slice index must be usize, got '%s' -- prefer declaring the \
       value as usize directly (e.g. `for i: usize in ...`), which keeps \
       any proven range; a plain `as usize` cast also works but discards \
       the proven range (reopening a runtime bounds check) -- use an \
       explicit `as {lo..<hi as usize}` cast instead to carry a proven \
       range across the base change"
      (to_string t)))
  in
  match repr t with
  | TUsize -> ()
  | TVar { contents = Unbound _ } -> unify_at loc t TUsize
  | TRefinedInt (_, _, base) ->
      (match repr base with
       | TUsize -> ()
       | TVar { contents = Unbound _ } -> unify_at loc base TUsize
       | _ -> reject ())
  | _ -> reject ()

(* Raw-pointer indexing is signed pointer displacement, matching ptr +/-
   offset and Rust's offset(isize): negative indices are meaningful and the
   operand must have the target's pointer width. Bare literals are pinned to
   isize; values in another integer base require an explicit cast. *)
let require_isize_offset loc t =
  let reject () =
    raise (TypeError (loc, Printf.sprintf
      "raw-pointer index/offset must be isize, got '%s' -- declare the value \
       as isize or cast it explicitly with `as isize`"
      (to_string t)))
  in
  match repr t with
  | TIsize -> ()
  | TVar { contents = Unbound _ } -> unify_at loc t TIsize
  | TRefinedInt (_, _, base) ->
      (match repr base with
       | TIsize -> ()
       | TVar { contents = Unbound _ } -> unify_at loc base TIsize
       | _ -> reject ())
  | _ -> reject ()

(* True if a type is not yet fully determined: a bare unresolved
   unification variable, or a TRefinedInt whose own base still is (e.g.
   `let x = min(5, 10);` with no annotation -- min/max's Call case can
   itself leave the base an open TVar when NEITHER argument pins one).
   Nested TVars are otherwise unreachable in this language: no written
   type-expression position ever embeds an inference placeholder, so a
   compound type (TArray/TPtr/TSlice/TStruct) can only ever have a
   concrete element/pointee/field type once its OWN top-level shape is
   concrete. Used by Let/LetDef to require an explicit annotation instead
   of silently deferring to Types.to_ast's i32 default -- see the Let
   case's own comment for why. *)
let rec is_undetermined t =
  match repr t with
  | TVar { contents = Unbound _ } -> true
  | TRefinedInt (_, _, base) -> is_undetermined base
  | _ -> false

(* Mirrors lib/parser.mly's base_bound_range/check_refined_base_range
   (sync rule, same reasoning, different representation): that check
   validates an Int64.t bound against an Ast.type_expr base at PARSE time
   for the literal `{lo..<hi as base}` surface syntax; this validates a
   plain OCaml int bound (already narrowed via Const_env.bound_value)
   against a Types.ty base at TYPE-CHECK time for `for i: base in
   lo..<hi`'s explicit annotation. Needed for the same reason: a bare
   -literal for-loop bound has no inherent width of its own, so the
   annotation is the ONLY source of width information, and a too-wide
   bound (e.g. `for i: u8 in 0..<300`) would otherwise silently wrap at
   codegen time via `const_int i8_type 300`. *)
let for_annotation_bound_range = function
  | TI8    -> (-128, Some 128)
  | TI16   -> (-32768, Some 32768)
  | TI32   -> (-2147483648, Some 2147483647)
  | TI64   -> (min_int, None)
  | TU8    -> (0, Some 256)
  | TU16   -> (0, Some 65536)
  | TU32   -> (0, Some 4294967296)
  | TU64   -> (0, None)
  | TIsize -> (-2147483648, Some 2147483647)
  | TUsize -> (0, Some 4294967296)
  | _ -> (min_int, None) (* unreachable: only reached via int_base_type_expr's 10 bases *)

let check_for_annotation_range loc lo hi base =
  let (blo, bhi_opt) = for_annotation_bound_range base in
  let out_of_range = lo < blo || (match bhi_opt with Some bhi -> hi > bhi | None -> false) in
  if out_of_range then
    raise (TypeError (loc, Printf.sprintf
      "for-loop bound {%d..<%d} does not fit the annotated type '%s'"
      lo hi (to_string base)))

(* Extract a small-number-scoped compile-time integer from an expression,
   iff it is exactly an integer literal that fits natively (see
   Ast.int_of_intlit's comment for why IntLit's Int64.t payload cannot
   always be narrowed to `int`). Used throughout range propagation below,
   which only ever needs to reason about realistic mask/comparison/
   multiplier constants, never a genuinely 64-bit-wide value. None
   uniformly covers both "not a literal at all" and "a literal, but too
   large to reason about here" -- both fall back to the conservative
   (unrefined) case, the same as any other non-constant expression would. *)
let intlit_opt (e : Ast.expr) : int option =
  match e.desc with
  | IntLit k -> Ast.int_of_intlit k
  | _ -> None

(* Nesting depth of `unsafe { ... }` expressions around the expression
   currently being inferred. Compilation is single-threaded, so a module
   -level counter is safe (same pattern as llvm_gen's narrowing_ctx).
   Reset at the start of infer_program: a TypeError raised inside an
   unsafe block aborts that compilation with the counter left non-zero,
   and unit tests run many compilations in one process. *)
let unsafe_depth = ref 0

(* Direct calls are resolved during inference.  Codegen must consume this
   exact decision rather than attempting a second overload resolution. *)
let resolved_call_targets = ref StringMap.empty

let rec infer_expr senv eenv tyenv fenv (e : Ast.expr) : ty =
  match e.desc with
  | IntLit _    -> fresh ()  (* polymorphic: unifies with any integer type via context *)
  | BoolLit _   -> TBool
  | StringLit _ -> TPtr TU8
  | Var name ->
      (* Check local/global variables first *)
      (match StringMap.find_opt name tyenv with
       | Some (t, _) ->
           (* Array types decay to pointer. io T is a value type: return T (volatile handled in codegen) *)
           (match repr t with
            | TArray (inner, _) -> TPtr inner
            | TIo    inner      -> inner
            | _                 -> t)
       | None ->
           (* Function name used as a value (function pointer) *)
           match StringMap.find_opt name fenv with
           | Some [(_, ft)] -> ft
           | Some _ ->
               raise (TypeError (e.loc, Printf.sprintf
                 "overloaded function '%s' needs an expected function type; use an explicit wrapper" name))
           | None ->
               raise (TypeError (e.loc,
                 Printf.sprintf "Unbound variable: %s" name)))
  | BinOp (op, e1, e2) ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      let t2 = infer_expr senv eenv tyenv fenv e2 in
      (match op with
       | Add ->
           (* Pointer arithmetic: ptr + isize -> returns the same pointer type. TIo is a value type, excluded.
              Range propagation (interval arithmetic; sync rule: llvm_gen's
              BinOp typing mirrors every case below, change together):
                {a..<b} + {c..<d} -> {a+c..<b+d-1}
                {a..<b} + k       -> {a+k..<b+k}   (and symmetric) *)
           (match repr t1, repr t2 with
            | TPtr _, TPtr _ ->
                raise (TypeError (e.loc, "cannot add two pointers"))
            | TPtr _, _ ->
                unify_at e2.loc t2 TIsize;
                t1
            | _, TPtr _ ->
                unify_at e1.loc t1 TIsize;
                t2
            | TRefinedInt (a, b, base1), TRefinedInt (c, d, base2) ->
                unify_at e.loc base1 base2;
                TRefinedInt (a + c, b + d - 1, base1)
            | TRefinedInt (a, b, base), _ ->
                (match intlit_opt e2 with
                 | Some k ->
                     unify_at e2.loc t2 base;
                     TRefinedInt (a + k, b + k, base)
                 | None ->
                     unify_at e2.loc (canon_ty t2) base;
                     base)
            | _, TRefinedInt (c, d, base) ->
                (match intlit_opt e1 with
                 | Some k ->
                     unify_at e1.loc t1 base;
                     TRefinedInt (c + k, d + k, base)
                 | None ->
                     unify_at e1.loc (canon_ty t1) base;
                     base)
            | _ ->
                let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                unify_at e.loc ct1 ct2;
                ct1)
       | Sub ->
           (* Pointer arithmetic: ptr - isize -> returns the same pointer type; ptr - ptr -> isize.
              Range propagation (sync rule with llvm_gen, as for Add):
                {a..<b} - {c..<d} -> {a-d+1..<b-c}
                {a..<b} - k       -> {a-k..<b-k}
                k - {c..<d}       -> {k-d+1..<k-c+1}  (k a literal; symmetric
                                      with Add's both-directions handling --
                                      what makes `40 - ihl` carry ihl's
                                      Band/min-derived range through to
                                      "remaining room" for a chained clamp,
                                      see CLAUDE.md's P4c section) *)
           (match repr t1, repr t2 with
            | TPtr inner1, TPtr inner2 ->
                unify_at e.loc inner1 inner2;
                TIsize
            | TPtr _, _ ->
                unify_at e2.loc t2 TIsize;
                t1
            | TRefinedInt (a, b, base), _ ->
                (match repr t2 with
                 | TRefinedInt (c, d, base2) ->
                     unify_at e.loc base base2;
                     TRefinedInt (a - d + 1, b - c, base)
                 | _ ->
                     (match intlit_opt e2 with
                      | Some k ->
                          unify_at e2.loc t2 base;
                          TRefinedInt (a - k, b - k, base)
                      | None ->
                          unify_at e2.loc (canon_ty t2) base;
                          base))
            | _, _ ->
                (match intlit_opt e1, repr t2 with
                 | Some k, TRefinedInt (c, d, base) ->
                     unify_at e1.loc t1 base;
                     TRefinedInt (k - d + 1, k - c + 1, base)
                 | _ ->
                     let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                     unify_at e.loc ct1 ct2;
                     ct1))
       | Mul ->
           (* Range propagation: {a..<b} * k (k a positive literal OR a
              Const_env-resolvable named constant, e.g. `idx * RX_BUF_SIZE`
              -- see CLAUDE.md's P4c section for where using e2.desc's bare
              IntLit check alone missed this) -> {a*k..<(b-1)*k+1} -- what
              makes `tcp_hdr_len = doff * 4` carry doff's narrowed {5..<16}
              into {20..<61}. Sync rule with llvm_gen as for Add/Sub.
              Non-constant or non-positive multipliers fall back to i32. *)
           let k2 = Const_env.bound_value e2 and k1 = Const_env.bound_value e1 in
           (match repr t1, k2, repr t2, k1 with
            | TRefinedInt (a, b, base), Some k, _, _ when k > 0 ->
                unify_at e2.loc t2 base;
                TRefinedInt (a * k, (b - 1) * k + 1, base)
            | _, _, TRefinedInt (a, b, base), Some k when k > 0 ->
                unify_at e1.loc t1 base;
                TRefinedInt (a * k, (b - 1) * k + 1, base)
            | _ ->
                let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                unify_at e.loc ct1 ct2;
                ct1)
       | Div ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           ct1
       | Lt | Gt | Le | Ge | Eq | Ne ->
           unify_at e.loc (canon_ty t1) (canon_ty t2);
           TBool
       (* Range propagation: n % m where m is a positive constant -> {0..<m}.
          Soundness condition: propagate only when n is guaranteed non-negative.
          TRefinedInt with lo>=0 or unsigned types ({lo..<_}, lo>=0) satisfy this.
          When n is int (can be negative), srem returns a negative remainder, so return same type.
          Example: (-5) % 8 = -5 (not 3) -- returning {0..<m} without non-negativity is unsound. *)
       | Mod ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           (match intlit_opt e2 with
            | Some m when m > 0 ->
                (match repr t1 with
                 | TRefinedInt (lo, _, _) when lo >= 0 -> TRefinedInt (0, m, ct1)
                 | t when is_unsigned_ty t -> TRefinedInt (0, m, ct1)
                 | _ -> ct1)
            | _ -> ct1)
       | Or | And ->
           check_cond e1.loc t1;
           check_cond e2.loc t2;
           TBool
       (* Range propagation: x & k -> {0..<k+1} when k is a non-negative
          literal mask. Sound regardless of x's own sign or range: bitwise
          AND with a non-negative value can only clear bits, so the result
          is always in [0, k] in two's complement, for ANY x (a negative x
          like -1 = all-ones still yields x & k <= k). Symmetric (k may be
          either operand). Sync rule: llvm_gen.ml's BinOp Band case must
          compute the same thing -- change together. *)
       | Band ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           (match intlit_opt e2 with
            | Some k when k >= 0 -> TRefinedInt (0, k + 1, ct1)
            | _ -> (match intlit_opt e1 with
                    | Some k when k >= 0 -> TRefinedInt (0, k + 1, ct1)
                    | _ -> ct1))
       | Bor | Bxor | Shr | Shl ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           ct1)
  | Bnot e1 ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      canon_ty t1
  | Deref e1 ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      (match repr t1 with
       | TPtr inner ->
           (* *io T deref returns T (io is a storage qualifier; volatile handled in codegen) *)
           strip_io inner
       | _ ->
           let inner = fresh () in
           unify_at e1.loc t1 (TPtr inner);
           inner)
  | AddrOf inner ->
      (match inner.desc with
       | Var name ->
           let (t, is_mut) = lookup_binding e.loc name tyenv in
           if not is_mut then
             raise (TypeError (e.loc,
               Printf.sprintf "cannot take address of immutable variable '%s'" name));
           TPtr t
       | FieldGet (base_expr, fname) ->
           let bt = infer_expr senv eenv tyenv fenv base_expr in
           let sname = match repr bt with
             | TStruct s | TPtr (TStruct s) | TPtr (TIo (TStruct s)) -> s
             | _ -> raise (TypeError (base_expr.loc,
                 Printf.sprintf "field address '.%s' on non-struct type '%s'"
                   fname (to_string bt)))
           in
           let fields = match StringMap.find_opt sname senv with
             | Some (fs, _, _) -> fs
             | None -> raise (TypeError (e.loc,
                 Printf.sprintf "unknown struct type '%s'" sname))
           in
           (match List.assoc_opt fname fields with
            | Some ft -> TPtr (of_ast ft)
            | None -> raise (TypeError (e.loc,
                Printf.sprintf "no field '%s' in struct '%s'" fname sname)))
       | _ ->
           raise (TypeError (e.loc, "& requires a variable or struct field")))
  | Cast (target_ty, e) ->
      let src_ty = infer_expr senv eenv tyenv fenv e in
      let src_enum = match repr src_ty with
        | TStruct sn when StringMap.mem sn eenv -> Some sn
        | _ -> None
      in
      let tgt_enum = match target_ty with
        | Ast.TypeNamed tn when StringMap.mem tn eenv -> Some tn
        | _ -> None
      in
      (match src_enum, tgt_enum with
       | Some ename, _ ->
           (* Enum -> T: T must be exactly the underlying type.
              Use (et as underlying) as T for any other conversion. *)
           let (underlying, _, _) = StringMap.find ename eenv in
           let expected = of_ast underlying in
           let got      = of_ast target_ty in
           if repr got <> repr expected then
             raise (TypeError (e.loc,
               Printf.sprintf
                 "cannot cast enum '%s' (underlying %s) to '%s': cast to '%s' first"
                 ename (to_string expected) (to_string got) (to_string expected)));
           of_ast target_ty
       | None, Some ename ->
           (* T -> Enum: T must be assignable to the underlying type.
              TRefinedInt subtyping is allowed (e.g. {0..<3} as Color where Color: u8). *)
           let (underlying, _, _) = StringMap.find ename eenv in
           let expected = of_ast underlying in
           (try unify src_ty expected
            with Unify_error _ ->
              raise (TypeError (e.loc,
                Printf.sprintf
                  "cannot cast '%s' to enum '%s' (underlying %s): cast to '%s' first"
                  (to_string src_ty) ename (to_string expected) (to_string expected))));
           of_ast target_ty
       | None, None ->
           let tgt = of_ast target_ty in
           (match target_ty with
            | Ast.TypeSlice (el_ast, want_min) ->
                (* Slice creation cast. Sources:
                   - an array VARIABLE (its declared [T; N] carries the static
                     length; note infer_expr's Var case decays arrays to *T,
                     so the length must be recovered from the binding, not
                     from src_ty -- llvm_gen's Cast case does the same)
                   - another slice (min-length may only be relaxed) *)
                let el_want = of_ast el_ast in
                (match repr src_ty with
                 | TSlice (el_s, m) ->
                     unify_at e.loc el_s el_want;
                     if m < want_min then
                       raise (TypeError (e.loc, Printf.sprintf
                         "cannot cast %s to %s: minimum length %d is not proven"
                         (to_string src_ty) (to_string tgt) want_min));
                     TSlice (el_want, m)
                 | _ ->
                     (match e.desc with
                      | Ast.Var name ->
                          (match StringMap.find_opt name tyenv with
                           | Some (t, _) ->
                               (match repr t with
                                | TArray (el_a, n) ->
                                    unify_at e.loc el_a el_want;
                                    if n < want_min then
                                      raise (TypeError (e.loc, Printf.sprintf
                                        "cannot cast [_; %d] to %s: array is shorter \
                                         than the required minimum %d" n (to_string tgt) want_min));
                                    TSlice (el_want, n)
                                | t' -> raise (TypeError (e.loc, Printf.sprintf
                                    "cannot cast '%s' to a slice" (to_string t'))))
                           | None -> raise (TypeError (e.loc,
                               Printf.sprintf "Unbound variable: %s" name)))
                      | Ast.StringLit str ->
                          (* String literal as a slice: the compile-time
                             byte length (NUL excluded) becomes the minimum,
                             so `slice_copy(dst, "..." as []u8)` copies the
                             literal and returns its length -- no NUL scan,
                             no unbounded write. *)
                          unify_at e.loc TU8 el_want;
                          let n = String.length str in
                          if n < want_min then
                            raise (TypeError (e.loc, Printf.sprintf
                              "cannot cast a %d-byte string literal to %s"
                              n (to_string tgt)));
                          TSlice (el_want, n)
                      | _ -> raise (TypeError (e.loc,
                          "slice cast requires an array variable, string \
                           literal, or slice source"))))
            | _ ->
           (match repr src_ty with
            | TPtr _ ->
                (match tgt with
                 | TUsize | TPtr _ -> tgt
                 | _ ->
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "cannot cast pointer to %s; \
                          use `(ptr as usize) as %s` to make the truncation explicit"
                         (to_string tgt) (to_string tgt))))
            | TSlice _ ->
                (match tgt with
                 | TPtr _ ->
                     (* Explicit bridge from the slice world back into the
                        pointer world (`frame as *u8`) -- used where an API
                        still takes pointer+length (checksums, net_transmit,
                        response building). As free as *T as *U, and equally
                        visible: the reader sees exactly where bounds
                        governance ends. *)
                     tgt
                 | _ ->
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "cannot cast a slice to %s (only `as *T` is allowed)"
                         (to_string tgt))))
            | TRefinedInt (lo, hi, _) ->
                (* GitHub issue #72: a BARE cast target (`x as usize`, not the
                   explicit `x as {lo..<hi as usize}` form) still infers the
                   tightest possible refined type when x's own range is
                   already known and fits the target base -- e.g. `ihl as
                   usize` when ihl: {20..<21 as u16} now behaves exactly like
                   the old `ihl as {20..<21 as usize}` did, with no explicit
                   range restated by hand. This only ever WIDENS what the
                   cast proves (never narrows/weakens): `tgt` is one of the
                   plain integer base variants here (an explicit TypeRefined
                   target_ty already produced a TRefinedInt tgt above, so it
                   never reaches this arm), and unify's existing TRefinedInt
                   subtyping rule is reused as the single source of truth
                   for "does this range fit the target base", so this can
                   never drift from the manual-annotation path's own rules.
                   A range that does NOT fit (a genuine narrowing/truncating
                   cast, e.g. a {0..<1481}-typed value cast to u8) falls
                   through unchanged to today's behavior: a plain unrefined
                   `tgt`, silently truncating, exactly as before this
                   feature existed. *)
                (match tgt with
                 | TI8 | TI16 | TI32 | TI64
                 | TU8 | TU16 | TU32 | TU64
                 | TIsize | TUsize ->
                     (try unify src_ty tgt; TRefinedInt (lo, hi, tgt)
                      with Unify_error _ -> tgt)
                 | _ -> tgt)
            | _ ->
                (* GitHub issue #100 follow-up: an EXPLICIT `x as {lo..<hi
                   as base}` cast target reaches here for any source that
                   isn't itself a pointer/slice/already-refined value (in
                   particular, a bare integer literal) -- same gap as
                   Let/Assign/etc: `tgt` was already computed from the
                   written syntax with no check against a literal source's
                   actual value. *)
                check_literal_fits_refined e.loc e tgt;
                tgt)))

  | FieldGet (base_expr, fname) ->
      let bt = infer_expr senv eenv tyenv fenv base_expr in
      (match repr bt, fname with
       | TSlice _, "len" -> TUsize  (* s.len -- the slice's runtime length *)
       | _ ->
      let sname = match repr bt with
        | TStruct s                      -> s
        | TPtr   (TStruct s)             -> s
        | TPtr   (TIo (TStruct s))       -> s   (* field read through *io Struct *)
        | _ ->
            raise (TypeError (base_expr.loc,
              Printf.sprintf "field access '.%s' on non-struct type '%s'"
                fname (to_string bt)))
      in
      let fields = match StringMap.find_opt sname senv with
        | Some (fs, _, _) -> fs
        | None ->
            raise (TypeError (e.loc,
              Printf.sprintf "unknown struct type '%s'" sname))
      in
      (match List.assoc_opt fname fields with
       | Some ft ->
           (match of_ast ft with
            | TArray (inner, _) -> TPtr inner  (* array field decays to *elem *)
            | TIo    inner      -> inner        (* io field returns value type T (volatile handled in codegen) *)
            | t                 -> t)
       | None ->
           raise (TypeError (e.loc,
             Printf.sprintf "no field '%s' in struct '%s'" fname sname))))

  | Index (id, idx) ->
      (* Get the variable's original type (no array decay, unlike Var) *)
      let vt = lookup e.loc id tyenv in
      let it = infer_expr senv eenv tyenv fenv idx in
      (match repr vt with
       | TArray (elem, n) ->
           require_usize_index idx.loc it;
           (* Constant index: check bounds at compile time. A literal too
              large to narrow natively (see Ast.int_of_intlit) is certainly
              out of bounds for any real array, so it is reported the same
              way rather than silently passing through unchecked. *)
           (match idx.desc with
            | IntLit k64 ->
                (match Ast.int_of_intlit k64 with
                 | Some k when k >= n ->
                     raise (TypeError (idx.loc,
                       Printf.sprintf "index %d is out of bounds for array of size %d" k n))
                 | Some _ -> ()
                 | None ->
                     raise (TypeError (idx.loc,
                       Printf.sprintf "index %Ld is out of bounds for array of size %d" k64 n)))
            | _ -> ());
           elem
       | TSlice (elem, _) ->
           require_usize_index idx.loc it;
           elem  (* runtime length; codegen elides the check
                    only when idx's range fits the MINIMUM *)
       | TPtr   elem      ->
           require_isize_offset idx.loc it;
           strip_io elem     (* *T or *io T -> returns T (bounds unknown) *)
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt))))

  | SliceOf (id, lo_e, hi_e) ->
      let vt = lookup e.loc id tyenv in
      let lo_t = infer_expr senv eenv tyenv fenv lo_e in
      let hi_t = infer_expr senv eenv tyenv fenv hi_e in
      (* A subslice range is indexing too: array/slice bounds use usize,
         matching single-element Index/AssignIndex and the runtime length's
         own type. Raw-pointer slice construction uses signed pointer-sized
         displacements, matching pointer arithmetic and pointer indexing. *)
      (match repr vt with
       | TArray _ | TSlice _ ->
           require_usize_index lo_e.loc lo_t;
           require_usize_index hi_e.loc hi_t
       | TPtr _ ->
           require_isize_offset lo_e.loc lo_t;
           require_isize_offset hi_e.loc hi_t
       | _ -> ());
      let const_bounds = (Const_env.bound_value lo_e, Const_env.bound_value hi_e) in
      (* Static value range of a bound: a compile-time constant k is {k..<k+1};
         a refined-typed expression contributes its own range. Sync rule:
         llvm_gen.ml's SliceOf makes the same proven/checked decision through
         the same formula (see its bound_range helper) -- change together. *)
      let bound_range be bt =
        match Const_env.bound_value be with
        | Some k -> Some (k, k + 1)
        | None -> (match repr bt with TRefinedInt (a, b, _) -> Some (a, b) | _ -> None)
      in
      (* Same-base rule: s[v ..< v + w] (same variable v as the lo bound,
         reused inside the hi bound) has lo <= hi and a guaranteed length
         >= lower(w) -- for ANY w with a known non-negative lower bound,
         not just a compile-time constant. This discharges the
         correlated-bounds pattern plain interval reasoning cannot (which
         treats the two occurrences of v as independent, so v's own
         WORST-CASE upper bound looks like it could exceed v+w's
         BEST-CASE lower bound, even though they can't actually both
         happen at once since it's the same v): both
         `frame[data_off ..< data_off + 3]` (w = a literal, wlo = 3
         exactly) and `ip[ihl ..< ihl + tcp_len]` (w = another refined
         variable, e.g. the result of a min()-clamp -- see CLAUDE.md's
         P4c section) are this same shape; only the SOURCE of w's lower
         bound differs. io-qualified v is excluded: its two loads are
         volatile and could disagree. Sync rule: llvm_gen's SliceOf must
         decompose hi_e identically. *)
      (* w is restricted to a bare literal or a bare variable (not an
         arbitrary expression): llvm_gen's mirror of this check must look
         up w's range WITHOUT re-running codegen on it a second time (w
         has already been evaluated once as part of hi_e itself), so it
         can only use a direct table lookup, not a general re-inference --
         keeping both sides to the same restriction is the sync rule. *)
      let same_base_len =
        match lo_e.desc with
        | Var v1 ->
            let w_opt = match hi_e.desc with
              | BinOp (Add, { desc = Var v2; _ }, w) when v2 = v1 -> Some w
              | BinOp (Add, w, { desc = Var v2; _ }) when v2 = v1 -> Some w
              | _ -> None
            in
            (match w_opt with
             | None -> None
             | Some w ->
                 let is_io = match StringMap.find_opt v1 tyenv with
                   | Some (t, _) -> (match repr t with TIo _ -> true | _ -> false)
                   | None -> false
                 in
                 if is_io then None
                 else
                   match w.desc with
                   | IntLit _ ->
                       (match intlit_opt w with
                        | Some k when k >= 0 -> Some k
                        | _ -> None)
                   | Var w_name ->
                       (match StringMap.find_opt w_name tyenv with
                        | Some (t, _) ->
                            (match repr t with
                             | TRefinedInt (wlo, _, _) when wlo >= 0 -> Some wlo
                             | _ -> None)
                        | None -> None)
                   | _ -> None)
        | _ -> None
      in
      (match repr vt with
       | TSlice (elem, m) ->
           (* Proven subslice: 0 <= lo, lo <= hi, hi <= m must all follow
              from the bounds' STATIC ranges (m is a lower bound of the
              runtime length, so hi <= m implies hi <= len), except that
              lo <= hi may also come from the same-base rule. The result's
              minimum is the guaranteed length: exact k - j for same-base,
              min(hi) - max(lo) otherwise. This is how `frame[0..<len]`
              after `if (len >= 54 && len <= 1514)` narrowing yields
              [u8; 54..] with no runtime check at all. *)
           (match bound_range lo_e lo_t, bound_range hi_e hi_t with
            | Some (la, lb), Some (ha, hb)
              when la >= 0 && (lb - 1 <= ha || same_base_len <> None)
                   && hb - 1 <= m ->
                (match same_base_len with
                 | Some l -> TSlice (elem, l)
                 | None   -> TSlice (elem, ha - (lb - 1)))
            | lo_r, hi_r ->
                (match const_bounds with
                 | Some a, Some b when a < 0 || a > b ->
                     (* Definitely-malformed constants: reject rather than
                        emit a check that always traps. (b > m is NOT
                        definitely wrong for a slice -- the runtime length
                        may exceed the minimum -- so that becomes a check.) *)
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "subslice [%d..<%d] is malformed (lo must satisfy \
                          0 <= lo <= hi)" a b))
                 | _ ->
                     (* Runtime-checked subslice (gradual form): codegen
                        emits 0 <= lo && lo <= hi && hi <= s.len -> trap,
                        recorded as a --forbid-trap site. The result minimum
                        keeps whatever the static ranges still guarantee
                        once the check has passed: len = hi - lo >=
                        min(hi) - max(lo). *)
                     let min_after = match same_base_len with
                       | Some l -> l  (* exact once the check has passed *)
                       | None ->
                           (match lo_r, hi_r with
                            | Some (_, lb), Some (ha, _) when ha - (lb - 1) > 0 ->
                                ha - (lb - 1)
                            | _ -> 0)
                     in
                     TSlice (elem, min_after)))
       | TArray (elem, n) ->
           (* Arrays have an EXACT static length, so bounds must be provable
              outright; out-of-range constants are definite errors, and
              runtime bounds have no checked form here (cast to a slice
              first if a runtime-checked subslice is really wanted). *)
           (match bound_range lo_e lo_t, bound_range hi_e hi_t with
            | Some (la, lb), Some (ha, hb)
              when la >= 0 && (lb - 1 <= ha || same_base_len <> None)
                   && hb - 1 <= n ->
                (match same_base_len with
                 | Some l -> TSlice (elem, l)
                 | None   -> TSlice (elem, ha - (lb - 1)))
            | _ ->
                (match const_bounds with
                 | Some a, Some b ->
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "subslice [%d..<%d] is outside the proven range of \
                          '%s' (minimum length %d)" a b (to_string vt) n))
                 | _ ->
                     raise (TypeError (e.loc,
                       "subslice bounds on an array must be provable at \
                        compile time; cast to a slice first (`arr as []T`) \
                        for a runtime-checked subslice"))))
       | TPtr elem ->
           (* Slice construction from a raw pointer: an unchecked length
              ASSERTION with no evidence, so it must be visibly marked --
              only allowed inside unsafe { ... }. A false assertion here
              poisons every downstream "proof", which is categorically
              worse than a local pointer bug; the unsafe keyword is what
              makes that visible when writing and when reading. *)
           (match repr elem with
            | TIo _ ->
                raise (TypeError (e.loc,
                  "cannot make a slice from a volatile (*io) pointer: slice \
                   accesses are non-volatile and would silently drop io"))
            | _ ->
                if !unsafe_depth = 0 then
                  raise (TypeError (e.loc,
                    Printf.sprintf
                      "slice construction from a raw pointer asserts a length \
                       without evidence; write `unsafe { %s[..] }` to mark it" id));
                (* Claimed minimum from the bounds' static ranges (sync
                   rule: same formula as llvm_gen's sub_of_ptr). *)
                (match bound_range lo_e lo_t, bound_range hi_e hi_t with
                 | Some (la, lb), Some (ha, _) when la >= 0 && lb - 1 <= ha ->
                     TSlice (elem, ha - (lb - 1))
                 | _ -> TSlice (elem, 0)))
       | t -> raise (TypeError (e.loc,
           Printf.sprintf "subslice on non-slice/array/pointer type '%s'" (to_string t))))

  | Unsafe e1 ->
      (* Transparent to typing except for permitting unchecked-assertion
         constructs inside. No exception-safe decrement needed: a TypeError
         aborts this compilation, and infer_program resets the counter. *)
      incr unsafe_depth;
      let t = infer_expr senv eenv tyenv fenv e1 in
      decr unsafe_depth;
      t

  | EnumVariant (ename, vname) ->
      (match StringMap.find_opt ename eenv with
       | None ->
           raise (TypeError (e.loc, Printf.sprintf "Unknown enum: %s" ename))
       | Some (_, variants, _) ->
           if not (List.mem_assoc vname variants) then
             raise (TypeError (e.loc,
               Printf.sprintf "Unknown variant '%s' of enum '%s'" vname ename));
           TStruct ename)

  | SizeOf ty ->
      (* sizeof(T) is a compile-time constant of type usize. Validate named
         struct/enum types exist so unknown names are caught here rather than
         surfacing as an internal error during codegen. *)
      (match ty with
       | Ast.TypeNamed name when not (StringMap.mem name senv) && not (StringMap.mem name eenv) ->
           raise (TypeError (e.loc, Printf.sprintf "unknown type '%s' in sizeof" name))
       | _ -> ());
      (* GitHub issue #77: when the size is genuinely target-independent
         (see const_type_size's comment), carry the actual value as a
         refined singleton range instead of a bare TUsize -- this is what
         lets it survive being threaded through a `let`/global and still
         be usable to prove a subslice bound, exactly like any other
         refined constant already does. Falls back to the original plain
         TUsize (unrefined, value deferred to codegen) whenever the value
         isn't computable here, e.g. non-packed or align(N) structs,
         pointers, usize/isize fields -- no behavior change for those. *)
      (match const_type_size senv ty with
       | Some v -> TRefinedInt (v, v + 1, TUsize)
       | None -> TUsize)

  | OffsetOf (ty, field) ->
      (* offsetof is meaningful only for a named struct. Validate both the
         type and field here so source errors do not become codegen errors. *)
      let sname = (match ty with
       | Ast.TypeNamed name ->
           (match StringMap.find_opt name senv with
            | None ->
                raise (TypeError (e.loc,
                  Printf.sprintf "unknown struct '%s' in offsetof" name))
            | Some (fields, _, _) when not (List.mem_assoc field fields) ->
                raise (TypeError (e.loc,
                  Printf.sprintf "unknown field '%s' in struct '%s'" field name))
            | Some _ -> name)
       | _ ->
           raise (TypeError (e.loc, "offsetof requires a named struct type")))
      in
      (* Same GitHub issue #77 fix as SizeOf above -- see const_field_offset's
         comment for the exact scope (packed, no align(N)). *)
      (match const_field_offset senv sname field with
       | Some v -> TRefinedInt (v, v + 1, TUsize)
       | None -> TUsize)

  | StructLit _ ->
      raise (TypeError (e.loc,
        "struct literal requires a type annotation: `let mut x: Name = {...}`"))

  | Call (("dma_publish" | "dma_consume" | "device_fence" | "signal_fence"
          | "interrupt_wait" | "interrupt_notify") as fname, args) ->
      (* Target-independent DMA/device ordering builtins. Their hardware
         lowering is selected in llvm_gen.ml; keeping them zero-argument
         makes the synchronization boundary explicit and prevents a runtime
         value from accidentally selecting barrier semantics. *)
      (match args with
       | [] -> TVoid
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects no arguments: %s()" fname fname)))

  | Call (("dma_prepare_tx" | "dma_prepare_rx" | "dma_finish_rx") as fname, args) ->
      (match args with
       | [ptr; len] ->
           let pt = infer_expr senv eenv tyenv fenv ptr in
           let lt = infer_expr senv eenv tyenv fenv len in
           (match repr pt with
            | TPtr _ -> ()
            | _ -> raise (TypeError (ptr.loc, Printf.sprintf
                "%s expects a raw pointer as its first argument" fname)));
           unify_at len.loc lt TUsize;
           TVoid
       | _ -> raise (TypeError (e.loc, Printf.sprintf
           "%s expects two arguments: %s(ptr, len)" fname fname)))

  | Call ("slice_copy", args) ->
      (* Builtin (reserved name, see check_reserved_fn): copies
         min(dst.len, src.len) elements FORWARD from src to dst and returns
         the count as usize. Total function -- no trap, no check; a length
         mismatch shows up in the return value, never as a runtime error.
         The forward loop makes overlapping ranges safe when dst does not
         lead src (same guarantee bytes_copy's callers already rely on,
         e.g. the payload shift in tcp_echo -- see CLAUDE.md). The compiler
         emits the loop itself, so no takibi-level index proof is needed:
         this is how variable-length buffer code stays inside the
         non-relational interval world. *)
      (match args with
       | [d; s] ->
           let dt = infer_expr senv eenv tyenv fenv d in
           let st = infer_expr senv eenv tyenv fenv s in
           let ev = fresh () in
           unify_at d.loc dt (TSlice (ev, 0));
           unify_at s.loc st (TSlice (ev, 0));
           TUsize
       | _ -> raise (TypeError (e.loc,
           "slice_copy expects 2 arguments: slice_copy(dst, src)")))

  | Call ("slice_eq", args) ->
      (* Builtin: true iff the lengths are equal AND all elements match.
         Total function -- length mismatch is false, not an error. *)
      (match args with
       | [a; b] ->
           let at = infer_expr senv eenv tyenv fenv a in
           let bt = infer_expr senv eenv tyenv fenv b in
           let ev = fresh () in
           unify_at a.loc at (TSlice (ev, 0));
           unify_at b.loc bt (TSlice (ev, 0));
           TBool
       | _ -> raise (TypeError (e.loc,
           "slice_eq expects 2 arguments: slice_eq(a, b)")))

  | Call (("min" | "max") as fname, args) ->
      (* Builtins (P4c-2): min(a,b)/max(a,b) on i32. Purely interval-domain
         range propagation -- no relational reasoning. This is the tool for
         clamping a wire-derived value against a compile-time buffer
         capacity: `min(ihl, 20)` is provably <= 20 no matter what ihl
         turns out to be at runtime, closing a gap a plain runtime bounds
         check used to be the only answer for (see CLAUDE.md's P4c
         section). Sync rule: llvm_gen.ml's Call case must compute the
         identical range.

         Each bound is derived independently, and each needs a DIFFERENT
         amount of information -- this asymmetry is the actual content of
         the rule, not a simplification:
           min(a,b) <= a and <= b ALWAYS (definition of min), so if EITHER
             operand's upper bound is known, that alone bounds the
             result's upper side -- the OTHER operand may be totally
             unconstrained. But min(a,b) could equal WHICHEVER operand is
             smaller, so a LOWER bound requires BOTH operands' lower
             bounds to be known (an unconstrained operand could always be
             the one that's smaller, dragging the result down with it).
           max is the mirror image: a lower bound needs only one operand
             known (`max(tcp_len, 0)` proves >= 0 even though tcp_len
             itself is a bare, unconstrained i32 parameter); an upper
             bound needs both.
         "Unknown" is represented with a wide sentinel range rather than
         a genuine option type, so the result is always a plain
         TRefinedInt: a subslice/index proof against any REAL buffer
         capacity will correctly fail to close against a sentinel bound
         (never falsely succeed), so this is a representational
         convenience, not a soundness-relevant choice. *)
      (match args with
       | [a; b] ->
           let at = infer_expr senv eenv tyenv fenv a in
           let bt = infer_expr senv eenv tyenv fenv b in
           (* Both arguments must agree on a base type, same as any other
              binary numeric operation (Add/Sub/etc.) -- previously
              hardcoded TI32 for both, independently, which meant
              min/max simply could not be used on u32/u64/usize-typed
              values at all. Unifying them against EACH OTHER instead
              (and tagging the result TRefinedInt with that base) is what
              lets `min(some_u64_val, 20)` type-check and stay refined. *)
           let base_raw = canon_ty at in
           unify_at e.loc base_raw (canon_ty bt);
           (* repr again AFTER unify_at: unify_at may have just resolved
              base_raw in place (e.g. a or b was a fresh, not-yet-bound
              IntLit type variable) -- base must be the FULLY resolved
              type before is_unsigned_ty inspects its concrete shape below,
              or an unresolved TVar would silently (and wrongly) read as
              "not unsigned" regardless of what it actually resolves to
              (found via a real regression: min/max on two u64 arguments
              raised a spurious "cannot unify" error because the sentinel
              range's negative lower bound doesn't fit an unsigned
              destination -- see sentinel_lo below). *)
           let base = repr base_raw in
           let range_of (ae : Ast.expr) (aty : ty) =
             match Const_env.bound_value ae with
             | Some k -> Some (k, k + 1)
             | None -> (match repr aty with TRefinedInt (x, y, _) -> Some (x, y) | _ -> None)
           in
           let (sentinel_lo, sentinel_hi) = min_max_sentinel base in
           let ra = range_of a at and rb = range_of b bt in
           let lo =
             match ra, rb with
             | Some (la, _), Some (lb, _) ->
                 if fname = "min" then min la lb else max la lb
             | _ -> if fname = "max" then
                      (match ra, rb with
                       | Some (la, _), None | None, Some (la, _) -> la
                       | _ -> sentinel_lo)
                    else sentinel_lo
           in
           let hi =
             match ra, rb with
             | Some (_, ha), Some (_, hb) ->
                 if fname = "min" then min ha hb else max ha hb
             | _ -> if fname = "min" then
                      (match ra, rb with
                       | Some (_, ha), None | None, Some (_, ha) -> ha
                       | _ -> sentinel_hi)
                    else sentinel_hi
           in
           TRefinedInt (lo, hi, base)
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects 2 arguments: %s(a, b)" fname fname)))

  | Call (fname, args) ->
      let direct = StringMap.find_opt fname fenv in
      let ft_opt = match direct with
        | Some [(target, ft)] ->
            resolved_call_targets := StringMap.add (loc_key e.loc) target !resolved_call_targets;
            Some ft
        | Some candidates ->
            let arg_tys = List.map (infer_expr senv eenv tyenv fenv) args in
            let exact (_, ft) = match repr ft with
              | TFun (ps, _) when List.length ps = List.length arg_tys ->
                  List.for_all2 (fun at pt ->
                    match repr at with
                    | TVar { contents = Unbound _ } -> false
                    | TRefinedInt (_, _, base) -> repr base = repr pt
                    | actual -> actual = repr pt
                  ) arg_tys ps
              | _ -> false
            in
            (match List.filter exact candidates with
             | [(target, ft)] ->
                 resolved_call_targets := StringMap.add (loc_key e.loc) target !resolved_call_targets;
                 Some ft
             | [] ->
                 let unresolved = List.exists (fun t -> match repr t with
                   | TVar { contents = Unbound _ } -> true | _ -> false) arg_tys in
                 let why = if unresolved then
                   "argument type is not determined; add an explicit type annotation or 'as' cast"
                 else "no overload has exactly matching parameter types" in
                 raise (TypeError (e.loc, Printf.sprintf "cannot resolve overload '%s': %s" fname why))
             | _ -> raise (TypeError (e.loc, Printf.sprintf "ambiguous overload call '%s'" fname)))
        | None ->
            match StringMap.find_opt fname tyenv with
            | Some (t, _) -> Some t
            | None -> None
      in
      (match ft_opt with
       | None ->
           raise (TypeError (e.loc,
             Printf.sprintf "Undefined function: %s" fname))
       | Some ft ->
           let (param_tys, ret_ty) = match repr ft with
             | TFun (ps, r) -> (ps, r)
             | _ ->
                 raise (TypeError (e.loc,
                   Printf.sprintf "'%s' is not a function or function pointer" fname))
           in
           if List.length args <> List.length param_tys then
             raise (TypeError (e.loc,
               Printf.sprintf "%s expects %d argument(s), got %d"
                 fname (List.length param_tys) (List.length args)));
           List.iter2 (fun arg pt ->
             let at = infer_expr senv eenv tyenv fenv arg in
             unify_at arg.loc at pt;
             check_literal_fits_refined arg.loc arg pt
           ) args param_tys;
           ret_ty)

(* -- Checking mode --------------------------------------------------------- *)
(* check_expr pushes the expected type inward (bidirectional checking).
   Handles nested StructLit for both struct and array fields.
   Falls back to infer_expr + unify for all other expressions. *)

let rec check_expr senv eenv tyenv fenv (e : Ast.expr) (expected : ty) : unit =
  match e.desc, repr expected with
  | StructLit exprs, TArray (elem_ty, n) ->
      if List.length exprs <> n then
        raise (TypeError (e.loc, Printf.sprintf
          "array [_; %d] expects %d elements but literal has %d"
          n n (List.length exprs)));
      List.iter (fun ei -> check_expr senv eenv tyenv fenv ei elem_ty) exprs
  | StructLit exprs, TStruct sname ->
      let fields = match StringMap.find_opt sname senv with
        | Some (fs, _, _) -> fs
        | None -> raise (TypeError (e.loc,
            Printf.sprintf "unknown struct type '%s'" sname))
      in
      if List.length fields <> List.length exprs then
        raise (TypeError (e.loc, Printf.sprintf
          "struct '%s' has %d fields but literal has %d values"
          sname (List.length fields) (List.length exprs)));
      List.iter2 (fun (_, ft) ei ->
        check_expr senv eenv tyenv fenv ei (of_ast ft)
      ) fields exprs
  | _ ->
      let te = infer_expr senv eenv tyenv fenv e in
      (* If expected type is io T: check compatibility with T (strip the storage qualifier) *)
      unify_at e.loc te (strip_io expected);
      check_literal_fits_refined e.loc e (strip_io expected)

(* -- Flow-sensitive type narrowing ----------------------------------------- *)

(* Collect per-variable bounds from a condition: v >= lo / v < hi / && chains.
   Returns name -> (lo_opt, hi_opt). Commutative forms (lo < v) are also handled. *)
(* Collect per-variable bounds from an if condition. A comparison
   constrains `Var n` whenever the OTHER operand's static value range is
   known: an integer literal k is {k..<k+1}, a Const_env constant likewise,
   and a variable whose binding is refined contributes its own range
   (`total_len <= ip_len_in_frame` narrows total_len's upper bound to
   ip_len_in_frame's static maximum -- the fact collapses to a CONSTANT at
   collection time, so this is still interval reasoning, not a relational
   domain, and no new kill obligations arise: the constant was true when
   the condition executed and n's own kill is governed by written_names as
   before). Equality (`ihl == 20`) narrows to the operand's exact range.
   Sync rule: llvm_gen.ml's collect_bounds_cond is the same algorithm over
   its own binding tables; change the two together. *)
let collect_bounds tyenv (cond : Ast.expr) : (int option * int option) StringMap.t =
  let take_lo a b = match a, b with
    | Some x, Some y -> Some (max x y)
    | Some _, None -> a | None, _ -> b in
  let take_hi a b = match a, b with
    | Some x, Some y -> Some (min x y)
    | Some _, None -> a | None, _ -> b in
  let update name lo_opt hi_opt acc =
    let (pl, ph) = match StringMap.find_opt name acc with
      | Some p -> p | None -> (None, None) in
    StringMap.add name (take_lo lo_opt pl, take_hi hi_opt ph) acc
  in
  (* Static value range of a comparison operand, when known. *)
  let range_of (e : Ast.expr) =
    match Const_env.bound_value e with
    | Some k -> Some (k, k + 1)
    | None ->
        (match e.desc with
         | Var m ->
             (match StringMap.find_opt m tyenv with
              | Some (t, _) ->
                  (match repr t with
                   | TRefinedInt (a, b, _) -> Some (a, b)
                   | _ -> None)
              | None -> None)
         | _ -> None)
  in
  (* n <op> rhs where rhs's range is {c..<d} (so c <= rhs <= d-1). *)
  let constrain_left op n (c, d) acc =
    match op with
    | Ast.Ge -> update n (Some c)       None           acc
    | Ast.Gt -> update n (Some (c + 1)) None           acc
    | Ast.Le -> update n None           (Some d)       acc
    | Ast.Lt -> update n None           (Some (d - 1)) acc
    | Ast.Eq -> update n (Some c)       (Some d)       acc
    | _ -> acc
  in
  (* lhs <op> n where lhs's range is {c..<d} -- the mirrored constraints. *)
  let constrain_right op n (c, d) acc =
    match op with
    | Ast.Ge -> update n None           (Some d)       acc  (* n <= lhs *)
    | Ast.Gt -> update n None           (Some (d - 1)) acc  (* n <  lhs *)
    | Ast.Le -> update n (Some c)       None           acc  (* n >= lhs *)
    | Ast.Lt -> update n (Some (c + 1)) None           acc  (* n >  lhs *)
    | Ast.Eq -> update n (Some c)       (Some d)       acc
    | _ -> acc
  in
  let rec go (e : Ast.expr) acc = match e.desc with
    | BinOp (And, e1, e2) -> go e2 (go e1 acc)
    | BinOp ((Ge | Gt | Le | Lt | Eq) as op, l, r) ->
        let acc = match l.desc, range_of r with
          | Var n, Some rng -> constrain_left op n rng acc
          | _ -> acc
        in
        (match r.desc, range_of l with
         | Var n, Some rng -> constrain_right op n rng acc
         | _ -> acc)
    | _ -> acc
  in
  go cond StringMap.empty

(* Narrow the type environment for the then-branch of an if statement.
   Narrows int bindings (both mutable and immutable) when both lo and hi bounds are proven
   by the condition. Mutability is preserved so that assignment inside the branch still works.
   Codegen-side narrowing for bounds-check elision goes through the same kill rule.

   Invalidation (kill) rule: a variable the branch body may write to, alias
   (&x), or rebind is NOT narrowed at all -- the condition only proves the
   range at the moment it was evaluated, and any later write invalidates
   that proof (`if (v >= 0 && v < 8) { v = 100; use(v); }`). The kill set
   comes from Ast.written_names; llvm_gen.ml's apply_narrowing/_mut use the
   same function on the same body (sync rule -- see written_names' comment). *)
let narrow_from_cond tyenv (cond : Ast.expr) (then_body : Ast.stmt list) =
  let killed = Ast.written_names then_body in
  let bounds = collect_bounds tyenv cond in
  let env =
    StringMap.fold (fun name (lo_opt, hi_opt) env ->
      if List.mem name killed then env
      else match StringMap.find_opt name env with
      (* Already refined (e.g. an immutable let whose initializer was
         itself refined, kept via the "proofs survive weaker
         annotations" rule -- see check_bound_shadowing/B-plan) --
         INTERSECT rather than no-op. Without this, a variable that
         arrives at the if already-refined (very common once P4a's
         interval propagation is in play) would silently keep its
         WIDER pre-existing range instead of the tighter one the
         condition just proved, e.g. `icmp_len: {0..<1481}` at entry
         plus `if (icmp_len >= 8 && icmp_len <= 1480)` must become
         {8..<1481}, not stay {0..<1481}.
         GitHub issue #99: a single-sided `hi`-only condition (lo_opt =
         None) still narrows here, falling back to the variable's OWN
         already-proven `elo` as the effective lower bound -- sound
         unconditionally, since `elo` was already established as a valid
         lower bound before this condition was even reached. *)
      | Some (TRefinedInt (elo, ehi, base), is_mut) ->
          (match lo_opt, hi_opt with
           | Some lo, Some hi -> StringMap.add name (TRefinedInt (max lo elo, min hi ehi, base), is_mut) env
           | None, Some hi    -> StringMap.add name (TRefinedInt (elo, min hi ehi, base), is_mut) env
           | Some lo, None    -> StringMap.add name (TRefinedInt (max lo elo, ehi, base), is_mut) env
           | None, None       -> env)
      (* Any plain primitive integer type can be narrowed, not just
         TI32 -- a u8/u16/u32/u64/usize/i8/i16/i64-typed variable
         narrowed by an if-condition keeps ITS OWN type as the
         refined range's base (see types.ml's TRefinedInt comment).
         GitHub issue #99: for an UNSIGNED base with no lo_opt from the
         condition (e.g. `if (off < 511)`, not `if (off >= 0 && off <
         511)`), 0 is already a sound lower bound regardless of the
         condition -- every unsigned value is trivially >= 0 -- so the
         redundant explicit `>= 0` check is no longer required to trigger
         narrowing. Signed bases still require an explicit lo (no implicit
         floor exists for them). *)
      | Some ((TI8|TI16|TI32|TI64|TU8|TU16|TU32|TU64|TIsize|TUsize) as base, is_mut) ->
          let lo_opt = match lo_opt with
            | Some _ -> lo_opt
            | None -> if is_unsigned_ty base then Some 0 else None
          in
          (match lo_opt, hi_opt with
           | Some lo, Some hi -> StringMap.add name (TRefinedInt (lo, hi, base), is_mut) env
           | _ -> env)
      | _ -> env
    ) bounds tyenv
  in
  (* Slice minimum-length narrowing: `if (s.len >= K)` upgrades s's proven
     minimum for the branch. Same kill rule; llvm_gen's apply_narrowing/_mut
     consume the same Ast.slice_len_mins (sync rule). *)
  List.fold_left (fun env (name, k) ->
    if List.mem name killed then env
    else match StringMap.find_opt name env with
      | Some (t, is_mut) ->
          (match repr t with
           | TSlice (el, m) when k > m ->
               StringMap.add name (TSlice (el, k), is_mut) env
           | _ -> env)
      | None -> env
  ) env (Ast.slice_len_mins cond)

(* -- Statement inference --------------------------------------------------- *)
(* Returns (updated_tyenv, updated_raw_locals).
   tyenv grows with each Let in the current scope.
   raw_locals accumulates every Let type seen (including inside blocks/if/while)
   so that codegen can pre-allocate mutable locals at function entry. *)

let rec infer_stmt senv eenv tyenv fenv ret_ty raw_locals in_loop (s : Ast.stmt)
    : tyenv * ty StringMap.t =
  match s.desc with
  | Break | Continue ->
      if not in_loop then
        raise (TypeError (s.loc, "break/continue outside of a loop"));
      (tyenv, raw_locals)
  | Return e ->
      let t = infer_expr senv eenv tyenv fenv e in
      unify_at e.loc t ret_ty;
      check_literal_fits_refined e.loc e ret_ty;
      (tyenv, raw_locals)
  | Expr e ->
      ignore (infer_expr senv eenv tyenv fenv e);
      (tyenv, raw_locals)
  | Assign (name, e) ->
      let (vty, is_mut) = lookup_binding s.loc name tyenv in
      if not is_mut then
        raise (TypeError (s.loc,
          Printf.sprintf "cannot assign to immutable variable '%s'; use 'let mut'" name));
      let ety = infer_expr senv eenv tyenv fenv e in
      (* Assignment: match as "actual(rhs) is a subtype of expected(lhs)".
         TRefinedInt -> TI32 is OK (assigning with loss of precision). Reverse is NG. *)
      unify_at e.loc ety (strip_io vty);
      check_literal_fits_refined e.loc e (strip_io vty);
      (tyenv, raw_locals)
  | AssignDeref (ptr_expr, val_expr) ->
      let pt = infer_expr senv eenv tyenv fenv ptr_expr in
      let inner = match repr pt with
        | TPtr i ->
            (* Write through *io T pointer: inner is TIo T, strip it and check against T *)
            strip_io i
        | _ ->
            let inner = fresh () in
            unify_at ptr_expr.loc pt (TPtr inner);
            inner
      in
      let vt = infer_expr senv eenv tyenv fenv val_expr in
      unify_at val_expr.loc vt inner;
      check_literal_fits_refined val_expr.loc val_expr inner;
      (tyenv, raw_locals)
  | AssignIndex (id, idx, rhs) ->
      (* Dispatch on the variable's original type ([T; N] vs *T). tyenv holds the pre-decay type *)
      let vt = lookup s.loc id tyenv in
      let it = infer_expr senv eenv tyenv fenv idx in
      let rt = infer_expr senv eenv tyenv fenv rhs in
      let elem_ty = match repr vt with
        | TArray (elem, n) ->
            require_usize_index idx.loc it;
            (match idx.desc with
             | IntLit k64 ->
                 (match Ast.int_of_intlit k64 with
                  | Some k when k >= n ->
                      raise (TypeError (idx.loc,
                        Printf.sprintf "index %d is out of bounds for array of size %d" k n))
                  | Some _ -> ()
                  | None ->
                      raise (TypeError (idx.loc,
                        Printf.sprintf "index %Ld is out of bounds for array of size %d" k64 n)))
             | _ -> ());
            elem
        | TSlice (elem, _) -> require_usize_index idx.loc it; elem
        | TPtr   elem      -> require_isize_offset idx.loc it; strip_io elem
        | _ -> raise (TypeError (s.loc,
            Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt)))
      in
      unify_at rhs.loc rt elem_ty;
      check_literal_fits_refined rhs.loc rhs elem_ty;
      (tyenv, raw_locals)

  | AssignField (base_expr, fname, val_expr) ->
      let bt = infer_expr senv eenv tyenv fenv base_expr in
      let sname = match repr bt with
        | TStruct s                      -> s
        | TPtr   (TStruct s)             -> s
        | TPtr   (TIo (TStruct s))       -> s
        | _ ->
            raise (TypeError (base_expr.loc,
              Printf.sprintf "field assignment '.%s' on non-struct type '%s'"
                fname (to_string bt)))
      in
      let fields = match StringMap.find_opt sname senv with
        | Some (fs, _, _) -> fs
        | None ->
            raise (TypeError (s.loc,
              Printf.sprintf "unknown struct type '%s'" sname))
      in
      let field_ty = match List.assoc_opt fname fields with
        | Some ft -> of_ast ft
        | None ->
            raise (TypeError (s.loc,
              Printf.sprintf "no field '%s' in struct '%s'" fname sname))
      in
      let vt = infer_expr senv eenv tyenv fenv val_expr in
      (* Assignment to io field: check compatibility with T (io is a storage qualifier, strip it) *)
      unify_at val_expr.loc vt (strip_io field_ty);
      check_literal_fits_refined val_expr.loc val_expr (strip_io field_ty);
      (tyenv, raw_locals)
  | Let (is_mut, name, ty_opt, expr_opt, _align_opt) ->
      let ty = of_ast_opt ty_opt in
      let init_ty_opt =
        match expr_opt with
        | None ->
            if not is_mut then
              raise (TypeError (s.loc,
                Printf.sprintf "immutable variable '%s' must have an initializer" name));
            None
        | Some { desc = StructLit exprs; loc } ->
            (* Struct literal: look up struct name from the type annotation and check each field *)
            if not is_mut then
              raise (TypeError (loc,
                Printf.sprintf "struct literal requires `let mut %s: Name = {...}`" name));
            (match repr ty with
             | (TStruct _ | TArray _) as expected ->
                 check_expr senv eenv tyenv fenv { desc = StructLit exprs; loc } expected
             | _ -> raise (TypeError (loc,
                 "literal { ... } requires a struct or array type annotation")));
            None
        | Some e ->
            let et = infer_expr senv eenv tyenv fenv e in
            (* Initialization: match actual(expr) as a subtype of expected(type annotation) *)
            unify_at e.loc et (strip_io ty);
            check_literal_fits_refined e.loc e (strip_io ty);
            Some et
      in
      (* Proofs are only lost at mutation points, never at annotation
         (gradual-trap-elimination invariant): for an IMMUTABLE binding, a
         weaker annotation must not discard what the initializer proved --
         the value can never change, so keeping the stronger type is sound,
         and no runtime check (trap site) is manufactured out of
         already-proven code. Applies to the two proof-carrying types:
         slice minimum lengths, and refined int ranges -- the latter only
         when the annotation's own type MATCHES the refined value's base
         (generalized from the old i32-only check: a refined int's base
         now determines its storage representation, so an annotation
         naming a DIFFERENT primitive type would change that
         representation, and there the declared type must win, same
         reasoning as before just no longer hardcoded to i32). `let mut`
         keeps the declared type: reassignment can genuinely bring weaker
         values, so the weak type is honest. *)
      let bind_ty =
        if is_mut then ty
        else match init_ty_opt with
          | None -> ty
          | Some et ->
              (match repr ty, repr et with
               | TSlice (el, m1), TSlice (_, m2) when m2 > m1 -> TSlice (el, m2)
               (* `base` is a NESTED field inside the already-repr'd `et`,
                  so it is not itself guaranteed dereferenced (repr only
                  resolves the top-level TVar chain, not fields nested
                  inside a matched constructor) -- must repr it again
                  before comparing, or a base that's still a live
                  TVar(ref(Link TI32)) would structurally disagree with
                  the plain TI32 annotation despite meaning the same type
                  after resolution. Found via a real test regression
                  (Mul/Band chain producing a refined result whose base
                  came from a freshly-unified IntLit type variable). *)
               | t_ann, (TRefinedInt (_, _, base) as r) when t_ann = repr base -> r
               | _ -> ty)
      in
      (* Deliberately NOT checked here for is_undetermined: `let x = 1;
         return x;` is entirely ordinary, and the function's OWN return
         type (processed by a LATER statement) is what determines x's
         type -- checking immediately at this Let would reject it as a
         false positive, since later statements haven't run yet. The
         check instead runs once, in infer_func, after the WHOLE body has
         been processed and every constraint has had a chance to fire --
         see check_undetermined_lets. *)
      ( StringMap.add name (bind_ty, is_mut) tyenv,
        StringMap.add name bind_ty raw_locals )
  | Block stmts ->
      (* Let bindings extend the inner env but do not escape the block *)
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (tyenv, raw_locals) stmts
      in
      (tyenv, raw_locals')
  | If (cond, then_s, else_s) ->
      let ct = infer_expr senv eenv tyenv fenv cond in
      check_cond cond.loc ct;
      let then_tyenv = narrow_from_cond tyenv cond then_s in
      let (_, rl1) = List.fold_left
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (then_tyenv, raw_locals) then_s
      in
      let (_, rl2) = List.fold_left
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (tyenv, rl1) else_s
      in
      (tyenv, rl2)
  | While (cond, body) ->
      let ct = infer_expr senv eenv tyenv fenv cond in
      check_cond cond.loc ct;
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
        (tyenv, raw_locals) body
      in
      (tyenv, raw_locals')
  | For (name, ty_opt, lo_expr, hi_expr, body) ->
      let lo_ty = infer_expr senv eenv tyenv fenv lo_expr in
      let hi_ty = infer_expr senv eenv tyenv fenv hi_expr in
      (* The loop counter's base follows the BOUNDS' own type, instead of
         hardcoding TI32 (the same generalization already applied to
         min/max/Band/Mod/narrowing) -- unify lo/hi against EACH OTHER via
         canon_ty, mirroring min/max's Call case exactly. This was a real,
         found gap, not just a style choice: `for i in 0..<s.len` (s.len:
         TUsize) previously failed outright with "cannot unify usize with
         i32", because the OLD unconditional `unify_at ... TI32` forced
         both bounds to already be i32-compatible before any of
         TRefinedInt's leniency into TI32 could apply -- a bare (non
         -refined) TUsize has no such leniency rule. Fixed by unifying the
         bounds against each other instead, exactly like every other
         refinement-producing site in this file. *)
      let base_raw = canon_ty lo_ty in
      unify_at hi_expr.loc base_raw (canon_ty hi_ty);
      (* Explicit annotation (`for i: u8 in ...`): pins base_raw
         IMMEDIATELY, same as any other concrete-type unification --
         after this, base_raw is no longer a candidate for the deferred
         "still unresolved" path below at all. A conflicting bound (e.g.
         `for i: u8 in 0..<n` where n: u16) surfaces as an ordinary
         "cannot unify" error here, same as anywhere else a concrete type
         mismatch is caught. *)
      (match ty_opt with
       | Some ann_ty -> unify_at lo_expr.loc base_raw (of_ast ann_ty)
       | None -> ());
      (* Deliberately NOT validated/defaulted yet when there's no
         annotation: base_raw may still be resolved by how `name` is used
         INSIDE the body below (e.g. passed to a function with a
         concrete-typed parameter), exactly like ordinary HM inference
         lets a shared unification variable be pinned by any later
         constraint. Deferred to the check after the body, mirroring
         check_undetermined_lets's identical "let later constraints run
         first" reasoning. NOTE (see CLAUDE.md): for the single most
         common shape, `for i in 0..<4` with both bounds bare literals,
         this deferral has NO effect in practice, because such bounds get
         wrapped in TRefinedInt below, whose subtyping into a concrete
         type ignores the base field entirely -- the annotation syntax
         (`ty_opt`) is precisely the fix for that residual gap. *)
      (* Refine to TRefinedInt when both bounds are compile-time integers:
         a literal, or the name of a Const_env global constant (sound because
         check_const_shadowing rejects any local reusing a constant name).
         For runtime variables, conservatively use the bounds' own base.
         Sync rule: llvm_gen.ml's For case makes the same decision through
         the same Const_env.bound_value helper; keep them identical. *)
      let const_bounds = (Const_env.bound_value lo_expr, Const_env.bound_value hi_expr) in
      (* If both bounds are compile-time constants AND an explicit
         annotation was given, validate the bounds actually fit the
         annotated base -- a bare-literal bound has no inherent width of
         its own, so without this check `for i: u8 in 0..<300` would
         silently construct TRefinedInt(0, 300, TU8), wrapping around at
         codegen time exactly like the {lo..<hi as base} surface syntax's
         own bound check exists to prevent (see check_refined_base_range
         in parser.mly, sync rule -- same reasoning, different
         representation and call site). *)
      (match ty_opt, const_bounds with
       | Some _, (Some lo_v, Some hi_v) ->
           check_for_annotation_range lo_expr.loc lo_v hi_v (repr base_raw)
       | _ -> ());
      let idx_ty = match const_bounds with
        | Some lo_v, Some hi_v -> TRefinedInt (lo_v, hi_v, base_raw)
        | _ -> base_raw
      in
      (* Loop variable is immutable (Imm binding, no reassignment). Does not escape the loop.
         Also register under the mangled "__for_<name>" key: llvm_gen.ml's
         collect_lets pre-allocates the counter's own storage under that
         name, and resolve_local_ast looks types up by exactly this key --
         without this second binding, the counter's alloca would silently
         fall back to i32 regardless of what idx_ty says here. *)
      let body_env = StringMap.add name (idx_ty, false) tyenv in
      let raw_locals = StringMap.add ("__for_" ^ name) idx_ty raw_locals in
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
        (body_env, raw_locals) body
      in
      (* NOW validate base_raw: the body has had its full chance to pin it
         (via a shared TVar reference nested inside idx_ty/raw_locals' --
         mutating the ref cell in place propagates to the already-stored
         value, same reasoning as check_undetermined_lets). If STILL
         unresolved, this is a HARD ERROR, not a silent i32 default: now
         that `for i: T in ...` exists as an explicit escape hatch, there
         is no reason left to guess -- exactly the same reasoning as
         let/let mut's own "Undetermined ... Types Are a Compile Error"
         rule, applied here now that the annotation syntax closes the gap
         that rule used to leave open for loop counters specifically. If
         resolved to something CONCRETE but non-integer (e.g. `for i in
         0..<true`), raise a different, more specific error instead. *)
      (match repr base_raw with
       | TVar { contents = Unbound _ } ->
           raise (TypeError (lo_expr.loc, Printf.sprintf
             "cannot determine a concrete type for for-loop counter '%s': \
              add an explicit type annotation (e.g. `for %s: i32 in ...`) \
              -- this language does not default an undetermined integer type"
             name name))
       | _ -> ());
      (match repr base_raw with
       | TI8 | TI16 | TI32 | TI64 | TU8 | TU16 | TU32 | TU64 | TIsize | TUsize -> ()
       | _ -> raise (TypeError (lo_expr.loc,
           Printf.sprintf "for-loop bounds must be an integer type, got '%s'"
             (to_string base_raw))));
      (tyenv, raw_locals')

  | ForEach (name, se, body) ->
      let st = infer_expr senv eenv tyenv fenv se in
      (match repr st with
       | TSlice (el, _) ->
           (* Element is an immutable per-iteration value of the element type. *)
           let body_env = StringMap.add name (el, false) tyenv in
           let (_, raw_locals') = List.fold_left
             (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
             (body_env, raw_locals) body
           in
           (tyenv, raw_locals')
       | t ->
           raise (TypeError (se.loc,
             Printf.sprintf
               "for-in iterates over a slice, got '%s' (write `arr as []T` \
                to iterate an array)" (to_string t))))

  | Match (disc, arms) ->
      let dt = infer_expr senv eenv tyenv fenv disc in
      let ename = match repr dt with
        | TStruct sn when StringMap.mem sn eenv -> sn
        | t -> raise (TypeError (disc.loc,
            Printf.sprintf "match requires an enum type, got '%s'" (to_string t)))
      in
      let (_, enum_variants, is_ne) = StringMap.find ename eenv in
      let has_wild = ref false in
      let covered  = Hashtbl.create 4 in
      let raw_locals' = List.fold_left (fun rl arm ->
        match arm with
        | Ast.ArmVariant (aname, vname, body) ->
            if aname <> ename then
              raise (TypeError (s.loc,
                Printf.sprintf "arm type '%s' does not match discriminant '%s'" aname ename));
            (match List.assoc_opt vname enum_variants with
             | None -> raise (TypeError (s.loc,
                 Printf.sprintf "unknown variant '%s::%s'" ename vname))
             | Some _ -> ());
            Hashtbl.replace covered vname ();
            let (_, rl') = List.fold_left
              (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
              (tyenv, rl) body
            in rl'
        | Ast.ArmWild body ->
            has_wild := true;
            let (_, rl') = List.fold_left
              (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
              (tyenv, rl) body
            in rl'
      ) raw_locals arms in
      if is_ne then begin
        (* non-exhaustive enum: _ wildcard is required because unknown values can arrive *)
        if not !has_wild then
          raise (TypeError (s.loc,
            Printf.sprintf "non-exhaustive enum '%s' requires a '_' wildcard arm" ename))
      end else begin
        (* exhaustive enum: every variant must be covered (or _ present) *)
        if not !has_wild then
          List.iter (fun (vname, _) ->
            if not (Hashtbl.mem covered vname) then
              raise (TypeError (s.loc,
                Printf.sprintf "non-exhaustive match: '%s::%s' not covered" ename vname))
          ) enum_variants
      end;
      (tyenv, raw_locals')

(* -- Function inference ---------------------------------------------------- *)

(* Reject a local let / parameter / for-counter that reuses the name of a
   global compile-time constant (Const_env). Array sizes and for-loop bounds
   resolve such names through Const_env by name alone, with no scope
   information, so a shadowing local would silently make a refinement be
   computed from the global's value while the runtime value is the local's
   -- an unsound bounds-check elision. Checked after parsing (the Const_env
   table is complete by then), so declaration order cannot smuggle a shadow
   in: a function defined before the constant is checked all the same. *)
let check_const_shadowing (fdef : Ast.func) =
  let reject loc name =
    raise (TypeError (loc, Printf.sprintf
      "'%s' shadows a global constant of the same name (constant names are \
       resolved at compile time in array sizes and for-loop bounds); rename \
       the local" name))
  in
  List.iter (fun (pname, _) ->
    if Const_env.find pname <> None then reject fdef.def_loc pname
  ) fdef.params;
  let rec go_stmt (s : Ast.stmt) = match s.desc with
    | Ast.Let (_, name, _, _, _) ->
        if Const_env.find name <> None then reject s.loc name
    | Ast.Block ss | Ast.While (_, ss) -> List.iter go_stmt ss
    | Ast.If (_, t, e) -> List.iter go_stmt t; List.iter go_stmt e
    | Ast.For (name, _, _, _, body) ->
        if Const_env.find name <> None then reject s.loc name;
        List.iter go_stmt body
    | Ast.ForEach (name, _, body) ->
        if Const_env.find name <> None then reject s.loc name;
        List.iter go_stmt body
    | Ast.Match (_, arms) ->
        List.iter (function
          | Ast.ArmVariant (_, _, b) -> List.iter go_stmt b
          | Ast.ArmWild b            -> List.iter go_stmt b
        ) arms
    | _ -> ()
  in
  List.iter go_stmt fdef.body

(* Require an explicit type annotation on any `let`/`let mut` whose type is
   STILL undetermined after the whole function body has been processed
   (raw_locals reflects every constraint the ENTIRE function ever placed
   on it, not just what was known at the Let statement's own textual
   position -- see the Let case's own comment for why checking eagerly,
   right there, produces a false positive on the entirely ordinary
   `let x = 1; return x;` pattern). This is a plain syntactic re-walk
   (mirroring check_const_shadowing's go_stmt exactly) rather than
   threading a location map through infer_stmt's signature everywhere:
   raw_locals only holds name -> ty, with no location, so the AST is
   walked a second time purely to recover a `Let`'s source position for
   the error message. *)
let check_undetermined_lets (fdef : Ast.func) (raw_locals : ty StringMap.t) =
  let check loc name =
    match StringMap.find_opt name raw_locals with
    | Some ty when is_undetermined ty ->
        raise (TypeError (loc, Printf.sprintf
          "cannot determine a concrete type for '%s': add an explicit \
           type annotation (e.g. `: i32`) -- this language does not \
           default an undetermined integer type" name))
    | _ -> ()
  in
  let rec go_stmt (s : Ast.stmt) = match s.desc with
    | Ast.Let (_, name, None, _, _) -> check s.loc name
    | Ast.Let (_, _, Some _, _, _) -> ()
    | Ast.Block ss | Ast.While (_, ss) -> List.iter go_stmt ss
    | Ast.If (_, t, e) -> List.iter go_stmt t; List.iter go_stmt e
    | Ast.For (_, _, _, _, body) | Ast.ForEach (_, _, body) -> List.iter go_stmt body
    | Ast.Match (_, arms) ->
        List.iter (function
          | Ast.ArmVariant (_, _, b) -> List.iter go_stmt b
          | Ast.ArmWild b            -> List.iter go_stmt b
        ) arms
    | _ -> ()
  in
  List.iter go_stmt fdef.body

let infer_func senv eenv fenv genv (fdef : Ast.func) : func_info =
  check_const_shadowing fdef;
  let param_tys = List.map (fun (_, ty_opt) -> of_ast_opt ty_opt) fdef.params in
  let ret_ty    = ret_of_ast_opt fdef.ret_type in
  (* Start with globals visible, then shadow them with params (params are mutable) *)
  let init_env  = List.fold_left2
    (fun m (name, _) ty -> StringMap.add name (ty, true) m)
    genv fdef.params param_tys
  in
  let (_, raw_locals) = List.fold_left
    (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs false s)
    (init_env, StringMap.empty) fdef.body
  in
  check_undetermined_lets fdef raw_locals;
  {
    ret_type    = to_ast ret_ty;
    param_types = List.map2 (fun (name, _) ty -> (name, to_ast ty))
                    fdef.params param_tys;
    local_types = StringMap.map to_ast raw_locals;
  }

(* -- Whole-program inference ----------------------------------------------- *)

let infer_program (prog : Ast.toplevel list) : program_types =
  unsafe_depth := 0;  (* see its comment: fresh per compilation / per unit test *)
  resolved_call_targets := StringMap.empty;
  (* GitHub issue #79 follow-up: ONE flat namespace for every top-level
     name, not just functions and globals (the two kinds fixed earlier in
     this same follow-up) -- struct, opaque struct, and enum names now
     collide the same way. A single self-contained pass over the whole
     program, run before senv/eenv/fenv/genv exist, rather than one
     more scattered ad-hoc Hashtbl bolted onto each of those folds
     individually: the earlier two fixes each needed their own separate
     check (a same-file-only guard for functions, a StringMap.mem check
     against fenv for globals), and finding the struct/enum gap
     immediately after landing those two was the concrete signal that
     one shared, exhaustive mechanism is less error-prone than adding a
     fourth and fifth one-off check the same way. Functions are the one
     special case: two functions sharing a name is fine on ITS OWN (a
     valid overload, or a genuine duplicate signature -- both already
     handled by register_definition/fenv's own signature-aware logic
     further down); this registry only rejects a function name colliding
     with a NON-function kind, or two non-function kinds (struct, enum,
     global) colliding with each other or themselves. `Lexing.dummy_pos`
     for the same reason noted on the two earlier checks: `Ast.toplevel`
     carries no location except via `FuncDef`'s own `func.def_loc`. *)
  let toplevel_names : (string, string) Hashtbl.t = Hashtbl.create 32 in
  let article_for kind = if kind = "enum" then "an" else "a" in
  let claim_toplevel_name name kind =
    match Hashtbl.find_opt toplevel_names name with
    | Some "function" when kind = "function" -> ()
    | Some existing ->
        raise (TypeError (Lexing.dummy_pos,
          Printf.sprintf "'%s' is already defined as %s %s"
            name (article_for existing) existing))
    | None -> Hashtbl.add toplevel_names name kind
  in
  List.iter (function
    | Ast.FuncDef fdef          -> claim_toplevel_name fdef.name "function"
    | Ast.ExternFuncDef (n, _, _) -> claim_toplevel_name n "function"
    | Ast.LetDef (n, _, _, _, _)  -> claim_toplevel_name n "global"
    | Ast.StructDef (n, _, _, _)  -> claim_toplevel_name n "struct"
    | Ast.OpaqueStructDef (n, _)  -> claim_toplevel_name n "struct"
    | Ast.EnumDef (n, _, _, _)    -> claim_toplevel_name n "enum"
    | Ast.UseDef _              -> ()
  ) prog;
  let opaque_names = List.fold_left (fun names -> function
    | Ast.OpaqueStructDef (name, _) -> StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  let affine_names = List.fold_left (fun names -> function
    | Ast.OpaqueStructDef (name, true) -> StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  let rec validate_complete_type loc behind_ptr = function
    | Ast.TypeNamed name when StringSet.mem name opaque_names && not behind_ptr ->
        raise (TypeError (loc, Printf.sprintf
          "opaque struct '%s' is incomplete and may only be used behind a pointer" name))
    | Ast.TypePtr inner -> validate_complete_type loc true inner
    | Ast.TypeIo inner -> validate_complete_type loc behind_ptr inner
    | Ast.TypeArray (inner, _) | Ast.TypeSlice (inner, _) ->
        validate_complete_type loc false inner
    | Ast.TypeFn (args, ret) ->
        List.iter (validate_complete_type loc false) args;
        validate_complete_type loc false ret
    | Ast.TypeRefined (_, _, base) -> validate_complete_type loc false base
    | Ast.TypeBorrow inner -> validate_complete_type loc behind_ptr inner
    | _ -> ()
  in
  let rec contains_borrow = function
    | Ast.TypeBorrow _ -> true
    | Ast.TypePtr t | Ast.TypeIo t -> contains_borrow t
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> contains_borrow t
    | Ast.TypeFn (args, ret) -> List.exists contains_borrow args || contains_borrow ret
    | Ast.TypeRefined (_, _, base) -> contains_borrow base
    | _ -> false
  in
  let validate_param_type loc = function
    | Ast.TypeBorrow (Ast.TypePtr (Ast.TypeNamed name) as inner)
      when StringSet.mem name affine_names -> validate_complete_type loc false inner
    | Ast.TypeBorrow _ ->
        raise (TypeError (loc,
          "borrow is only valid on a pointer to an affine opaque struct parameter"))
    | ty -> validate_complete_type loc false ty
  in
  let validate_nonparam_type loc ty =
    if contains_borrow ty then
      raise (TypeError (loc, "borrow is only valid in function parameter types"));
    validate_complete_type loc false ty
  in
  let rec validate_expr_types (e : Ast.expr) =
    (match e.desc with
     | Ast.Cast (ty, x) -> validate_nonparam_type e.loc ty; validate_expr_types x
     | Ast.SizeOf ty | Ast.OffsetOf (ty, _) -> validate_nonparam_type e.loc ty
     | Ast.BinOp (_, a, b) -> validate_expr_types a; validate_expr_types b
     | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x | Ast.FieldGet (x, _)
     | Ast.Unsafe x -> validate_expr_types x
     | Ast.Call (_, xs) | Ast.StructLit xs -> List.iter validate_expr_types xs
     | Ast.Index (_, i) -> validate_expr_types i
     | Ast.SliceOf (_, lo, hi) -> validate_expr_types lo; validate_expr_types hi
     | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.Var _
     | Ast.EnumVariant _ -> ())
  and validate_stmt_types (s : Ast.stmt) =
    (match s.desc with
     | Ast.Let (_, _, ty, init, _) ->
         Option.iter (validate_nonparam_type s.loc) ty;
         Option.iter validate_expr_types init
     | Ast.For (_, ty, lo, hi, body) ->
         Option.iter (validate_nonparam_type s.loc) ty;
         validate_expr_types lo; validate_expr_types hi;
         List.iter validate_stmt_types body
     | Ast.Return e | Ast.Expr e -> validate_expr_types e
     | Ast.Assign (_, e) -> validate_expr_types e
     | Ast.AssignDeref (a, b) | Ast.AssignField (a, _, b)
     | Ast.AssignIndex (_, a, b) -> validate_expr_types a; validate_expr_types b
     | Ast.Block body -> List.iter validate_stmt_types body
     | Ast.While (c, body) ->
         validate_expr_types c; List.iter validate_stmt_types body
     | Ast.If (c, yes, no) ->
         validate_expr_types c; List.iter validate_stmt_types yes;
         List.iter validate_stmt_types no
     | Ast.ForEach (_, e, body) ->
         validate_expr_types e; List.iter validate_stmt_types body
     | Ast.Match (e, arms) ->
         validate_expr_types e;
         List.iter (function Ast.ArmVariant (_, _, b) | Ast.ArmWild b ->
           List.iter validate_stmt_types b) arms
     | Ast.Break | Ast.Continue -> ())
  in
  List.iter (function
    | Ast.FuncDef f ->
        List.iter (fun (_, ty) -> Option.iter (validate_param_type f.def_loc) ty) f.params;
        Option.iter (validate_nonparam_type f.def_loc) f.ret_type;
        List.iter validate_stmt_types f.body
    | Ast.ExternFuncDef (name, params, ret) ->
        List.iter (fun (pname, ty) -> match ty with
          | Some t -> validate_param_type Lexing.dummy_pos t
          | None -> raise (TypeError (Lexing.dummy_pos, Printf.sprintf
              "extern fn '%s' parameter '%s' has no type annotation; extern fn \
               parameters must be explicitly typed (there is no function body \
               to infer them from)" name pname))
        ) params;
        Option.iter (validate_nonparam_type Lexing.dummy_pos) ret
    | Ast.LetDef (_, ty, init, _, _) ->
        Option.iter (validate_nonparam_type Lexing.dummy_pos) ty;
        Option.iter validate_expr_types init
    | Ast.StructDef (_, fields, _, _) ->
        List.iter (fun (_, ty) -> validate_nonparam_type Lexing.dummy_pos ty) fields
    | Ast.OpaqueStructDef _ | Ast.EnumDef _ | Ast.UseDef _ -> ()) prog;
  (* Pass 0: collect struct and enum definitions *)
  let senv = List.fold_left (fun m -> function
    | Ast.StructDef (name, fields, is_packed, align_opt) ->
        StringMap.add name (fields, is_packed, align_opt) m
    | _ -> m
  ) StringMap.empty prog in
  let eenv = List.fold_left (fun m -> function
    | Ast.EnumDef (name, ty_opt, variants, is_ne) ->
        let underlying = match ty_opt with Some t -> t | None -> Ast.TypeU32 in
        let (_, resolved) = List.fold_left (fun (next, acc) (vname, vopt) ->
          let v = match vopt with Some v -> v | None -> next in
          (v + 1, acc @ [(vname, v)])
        ) (0, []) variants in
        StringMap.add name (underlying, resolved, is_ne) m
    | _ -> m
  ) StringMap.empty prog in
  (* Pass 1: collect function signatures *)
  (* Builtin names are reserved: infer_expr's Call case dispatches on them
     BEFORE consulting fenv, so a same-named user/extern function would be
     silently unreachable -- reject the definition instead. *)
  let check_reserved_fn loc name =
    if name = "slice_copy" || name = "slice_eq" || name = "min" || name = "max"
       || name = "dma_publish" || name = "dma_consume" || name = "device_fence"
       || name = "signal_fence" || name = "interrupt_wait" || name = "interrupt_notify"
       || name = "dma_prepare_tx" || name = "dma_prepare_rx" || name = "dma_finish_rx" then
      raise (TypeError (loc,
        Printf.sprintf "'%s' is a compiler builtin and cannot be redefined" name))
  in
  let type_code t =
    match t with
    | Ast.TypeBool -> "bool"
    | Ast.TypeI8 -> "i8" | Ast.TypeI16 -> "i16" | Ast.TypeI32 -> "i32" | Ast.TypeI64 -> "i64"
    | Ast.TypeU8 -> "u8" | Ast.TypeU16 -> "u16" | Ast.TypeU32 -> "u32" | Ast.TypeU64 -> "u64"
    | Ast.TypeIsize -> "isize" | Ast.TypeUsize -> "usize" | Ast.TypeVoid -> "void"
    | _ ->
        let source = Types.to_string (Types.of_ast t) in
        let b = Buffer.create (1 + String.length source * 2) in
        Buffer.add_char b 'x';
        String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) source;
        Buffer.contents b
  in
  let add_signature m name params =
        let signature = String.concat "_" (List.map (fun (_, t) ->
          match t with Some t -> type_code t | None -> "?") params) in
        let old = Option.value (StringMap.find_opt name m) ~default:StringSet.empty in
        StringMap.add name (StringSet.add signature old) m
  in
  let signatures = List.fold_left (fun m -> function
    | Ast.FuncDef f -> add_signature m f.name f.params
    | Ast.ExternFuncDef (name, params, _) -> add_signature m name params
    | _ -> m
  ) StringMap.empty prog in
  let fn_counts = StringMap.map StringSet.cardinal signatures in
  let fn_occurrences = List.fold_left (fun m -> function
    | Ast.FuncDef f ->
        StringMap.add f.name (1 + Option.value (StringMap.find_opt f.name m) ~default:0) m
    | Ast.ExternFuncDef (name, _, _) ->
        StringMap.add name (1 + Option.value (StringMap.find_opt name m) ~default:0) m
    | _ -> m
  ) StringMap.empty prog in
  let overload_key name params =
    if Option.value (StringMap.find_opt name fn_counts) ~default:0 <= 1 then name
    else begin
      if List.exists (fun (_, t) -> t = None) params then
        raise (TypeError (Lexing.dummy_pos, Printf.sprintf
          "overloaded function '%s' requires explicit parameter types" name));
      "_TK_" ^ name ^ "__" ^ String.concat "_" (List.map (fun (_, t) ->
        type_code (Option.get t)) params)
    end
  in
  let definition_files : (string, string) Hashtbl.t = Hashtbl.create 32 in
  let register_definition loc key name =
    let file = loc.Lexing.pos_fname in
    match Hashtbl.find_opt definition_files key with
    | Some previous ->
        (* Cross-file duplicates are rejected too, not just same-file ones
           (GitHub issue #79 follow-up): two `.tkb` files defining the exact
           same signature under the same overload key used to compile
           silently, with llvm_gen.ml's declare_func/gen_func pair (Pass 1
           registers only the FIRST FuncDef's llvalue per key; Pass 2 then
           calls gen_func on EVERY FuncDef with that key, appending a second,
           unreachable "entry" block onto the SAME llvalue) making whichever
           definition happened to come first in file-concatenation order the
           one that silently wins, with the other's body silently dead-coded
           -- no verifier error, no warning, correct only by accident of
           `use`/Makefile ordering. Found via examples/irq/irq.tkb's shared
           dispatch pattern: examples/common_qemu/gic.tkb and
           examples/common_stm32/nvic.tkb both had to be present in the same
           STM32 build (the former only for a dead-on-STM32 type reference,
           see gic.tkb's own header comment) and both defined
           irq_uart_rx_setup/irq_uart_rx_unmask with the identical
           signature -- previously silent, now a compile error pointing at
           both locations. *)
        if previous = file then
          raise (TypeError (loc, Printf.sprintf "duplicate overload '%s'" name))
        else
          raise (TypeError (loc, Printf.sprintf
            "duplicate definition of '%s': already defined in %s" name previous))
    | None -> Hashtbl.replace definition_files key file
  in
  let fenv = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        check_reserved_fn fdef.def_loc fdef.name;
        let pts = List.map (fun (_, t) -> of_ast_opt t) fdef.params in
        let rt  = ret_of_ast_opt fdef.ret_type in
        let key = overload_key fdef.name fdef.params in
        register_definition fdef.def_loc key fdef.name;
        let old = Option.value (StringMap.find_opt fdef.name m) ~default:[] in
        let old = List.filter (fun (k, _) -> k <> key) old in
        StringMap.add fdef.name ((key, TFun (pts, rt)) :: old) m
    | Ast.ExternFuncDef (name, params, ret_ty) ->
        check_reserved_fn Lexing.dummy_pos name;
        if Option.value (StringMap.find_opt name fn_occurrences) ~default:0 > 1 then
          raise (TypeError (Lexing.dummy_pos, Printf.sprintf
            "extern function '%s' cannot be overloaded" name));
        let pts = List.map (fun (_, t) -> of_ast_opt t) params in
        let rt  = ret_of_ast_opt ret_ty in
        let key = overload_key name params in
        register_definition Lexing.dummy_pos key name;
        let old = Option.value (StringMap.find_opt name m) ~default:[] in
        let old = List.filter (fun (k, _) -> k <> key) old in
        StringMap.add name ((key, TFun (pts, rt)) :: old) m
    | Ast.LetDef _    -> m
    | Ast.StructDef _ -> m
    | Ast.OpaqueStructDef _ -> m
    | Ast.EnumDef _   -> m
    | Ast.UseDef _    -> m
  ) StringMap.empty prog in
  (* Global mutability: plain `let` = immutable compile-time constant, `let mut` = variable.
     Reuses the same tyenv-based mutability check as local variables (Assign/AddrOf).
     GitHub issue #79 follow-up: duplicate/cross-kind global names are
     already rejected by claim_toplevel_name above (a single pass over
     the whole program, run before this fold), so this fold itself no
     longer needs its own duplicate guard -- by the time it runs, every
     name reaching here is already known unique across the whole
     program. *)
  let genv = List.fold_left (fun m -> function
    | Ast.LetDef (name, ty_opt, _, _, is_mutable) ->
        StringMap.add name (of_ast_opt ty_opt, is_mutable) m
    | Ast.FuncDef _                -> m
    | Ast.ExternFuncDef _          -> m
    | Ast.StructDef _              -> m
    | Ast.OpaqueStructDef _        -> m
    | Ast.EnumDef _                -> m
    | Ast.UseDef _                 -> m
  ) StringMap.empty prog in
  (* Pass 2: check global initializers.
     GitHub issue #77: a plain List.iter used to be enough here, since no
     global initializer had ever needed to change genv's own STORED type
     for that global -- but sizeof/offsetof's new refined-singleton types
     (see the SizeOf/OffsetOf cases above) mean an immutable global's
     initializer can now be genuinely MORE REFINED than its own bare
     annotation (e.g. `let ETH_DST: usize = offsetof(EthHdr, dst);`).
     Mirroring local lets' `bind_ty` ("proofs are only lost at mutation
     points, never at annotation" -- see that comment), this global's
     entry in genv is upgraded to the refined type when the annotation's
     type exactly matches the refined value's own base, so every LATER
     consumer of genv sees it -- Pass 3 function bodies referencing this
     global by name (this is what actually lets e.g. arp_reply.tkb's
     `ip[IP_SRC..<IP_DST]` prove statically), and program_types.globals
     below. Now a List.fold_left threading an updated genv forward
     (instead of a plain List.iter) for exactly this reason. *)
  let genv = List.fold_left (fun genv item -> match item with
    | Ast.LetDef (name, _, expr_opt, _, is_mutable) ->
        let (ty, _) = StringMap.find name genv in
        (match expr_opt with
         | None ->
             if not is_mutable then
               raise (TypeError (Lexing.dummy_pos,
                 Printf.sprintf "immutable global '%s' must have an initializer; use 'let mut' for uninitialized globals" name));
             genv
         | Some { desc = Ast.StructLit exprs; loc } ->
             (match repr ty with
              | (TStruct _ | TArray _) as expected ->
                  check_expr senv eenv genv fenv { desc = Ast.StructLit exprs; loc } expected
              | _ -> raise (TypeError (loc,
                  "literal { ... } requires a struct or array type annotation")));
             genv
         | Some { desc = Ast.Var vname; loc } ->
             (* Bypass infer_expr's ordinary Var case here: it decays array
                types to a pointer (the right behavior for array VALUES used
                as ordinary expressions, e.g. passed to a function), but a
                global referencing another global by name means "copy that
                global's value" -- unifying against the decayed pointer type
                would reject `let B: [u8;4] = A;` even though it is exactly
                what array-typed global aliasing should allow. Looking the
                name up in genv directly (raw, undecayed type) and unifying
                against that instead fixes arrays/structs while leaving
                scalar references (which never decayed anyway) unaffected. *)
             (match StringMap.find_opt vname genv with
              | Some (vty, _) ->
                  (* GitHub issue #77: actual (referenced global's own
                     type) first, declared annotation second -- see the
                     comment on the plain-expression case just below for
                     why argument order matters here, not just style. *)
                  (try unify (strip_io vty) (strip_io ty)
                   with Unify_error m -> raise (TypeError (loc, m)));
                  (* Same bind_ty upgrade as the plain-expression case:
                     `let B: usize = A;` where A is itself refined should
                     let B inherit that range too. *)
                  let bind_ty =
                    if is_mutable then ty
                    else match repr ty, repr (strip_io vty) with
                      | t_ann, (TRefinedInt (_, _, base) as r) when t_ann = repr base -> r
                      | _ -> ty
                  in
                  if bind_ty == ty then genv
                  else StringMap.add name (bind_ty, is_mutable) genv
              | None ->
                  raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" vname)))
         | Some e ->
             let et = infer_expr senv eenv genv fenv e in
             (* GitHub issue #77: `unify et (strip_io ty)` -- actual
                (initializer) type first, declared annotation second --
                matching the "actual, expected" convention every other
                unify/unify_at call site in this file already uses (e.g.
                unify_at e2.loc t2 TIsize). This file's global-initializer
                check previously called `unify (strip_io ty) et` (backwards:
                declared FIRST), which was never noticed because no global
                initializer had ever produced a genuinely MORE REFINED type
                than its own bare annotation before now: `unify TUsize
                (TRefinedInt (v, v+1, TUsize))` hits unify's anti-subtyping
                guard (`t1, TRefinedInt (lo, hi, base) when t1 = repr
                base`), which exists to reject an UNPROVEN base-typed value
                flowing into a position that demands the refined type --
                backwards from what is actually happening here (a PROVEN
                refined value flowing into a weaker plain-type annotation,
                which every TRefinedInt-into-base-type subtyping rule
                already allows once the arguments are the right way
                round). *)
             (try unify et (strip_io ty)
              with Unify_error m -> raise (TypeError (e.loc, m)));
             check_literal_fits_refined e.loc e (strip_io ty);
             (* Mirrors local lets' bind_ty exactly (see that comment) --
                this is the piece that actually matters for issue #77: not
                just "does this type-check" but "does the global keep the
                proof for later use". *)
             let bind_ty =
               if is_mutable then ty
               else match repr ty, repr et with
                 | t_ann, (TRefinedInt (_, _, base) as r) when t_ann = repr base -> r
                 | _ -> ty
             in
             if bind_ty == ty then genv
             else StringMap.add name (bind_ty, is_mutable) genv)
    | _ -> genv
  ) genv prog in
  (* Pass 3: infer function bodies *)
  let functions = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        let key = overload_key fdef.name fdef.params in
        StringMap.add key (infer_func senv eenv fenv genv fdef) m
    | _ -> m
  ) StringMap.empty prog in
  (* Restricted affine checking for pointers to `affine opaque struct`.
     This deliberately stops short of a general ownership system: affine
     values may be dropped, but a consuming call/return/assignment moves a
     named local and any later use is rejected. `borrow T` is parameter-only
     and makes calls through that parameter non-consuming. *)
  let rec strip_borrow = function
    | Ast.TypeBorrow t -> strip_borrow t
    | t -> t
  in
  let is_affine_type ty = match strip_borrow ty with
    | Ast.TypePtr (Ast.TypeNamed name) -> StringSet.mem name affine_names
    | _ -> false
  in
  let call_params = List.fold_left (fun m -> function
    | Ast.FuncDef f ->
        StringMap.add (overload_key f.name f.params) (List.map snd f.params) m
    | Ast.ExternFuncDef (name, params, _) -> StringMap.add name (List.map snd params) m
    | _ -> m
  ) StringMap.empty prog in
  let check_affine_func fdef =
    let finfo = StringMap.find (overload_key fdef.Ast.name fdef.params) functions in
    let var_types = ref finfo.local_types in
    List.iter2 (fun (name, _) (_, ty) ->
      var_types := StringMap.add name ty !var_types
    ) fdef.params finfo.param_types;
    let is_affine_var name = match StringMap.find_opt name !var_types with
      | Some ty -> is_affine_type ty
      | None -> false
    in
    let require_available loc moved name =
      if is_affine_var name && StringSet.mem name moved then
        raise (TypeError (loc, Printf.sprintf
          "affine value '%s' was already consumed" name))
    in
    let rec check_expr moved consume (e : Ast.expr) =
      match e.desc with
      | Ast.Var name ->
          require_available e.loc moved name;
          if consume && is_affine_var name then StringSet.add name moved else moved
      | Ast.Call (name, args) ->
          let target = Option.value
            (StringMap.find_opt (loc_key e.loc) !resolved_call_targets) ~default:name in
          let params = Option.value (StringMap.find_opt target call_params) ~default:[] in
          let rec check_args moved args params = match args with
            | [] -> moved
            | arg :: rest ->
            let consume_arg = match params with
              | Some ty :: _ when is_affine_type ty ->
                  (match ty with Ast.TypeBorrow _ -> false | _ -> true)
              | _ -> false
            in
            let moved = check_expr moved consume_arg arg in
            check_args moved rest (match params with _ :: ps -> ps | [] -> [])
          in
          check_args moved args params
      | Ast.BinOp (_, a, b) -> check_expr (check_expr moved false a) false b
      | Ast.Bnot a | Ast.Deref a | Ast.AddrOf a | Ast.Cast (_, a)
      | Ast.FieldGet (a, _) | Ast.Unsafe a -> check_expr moved false a
      | Ast.StructLit xs -> List.fold_left (fun m x -> check_expr m false x) moved xs
      | Ast.Index (_, i) -> check_expr moved false i
      | Ast.SliceOf (_, lo, hi) -> check_expr (check_expr moved false lo) false hi
      | Ast.SizeOf _ | Ast.OffsetOf _ | Ast.IntLit _ | Ast.BoolLit _
      | Ast.StringLit _ | Ast.EnumVariant _ -> moved
    in
    let rec check_stmts moved declared stmts =
      List.fold_left (fun (moved, declared) s -> check_stmt moved declared s)
        (moved, declared) stmts
    and check_stmt moved declared (s : Ast.stmt) =
      match s.desc with
      | Ast.Return e ->
          let consumes = match fdef.ret_type with
            | Some ty -> is_affine_type ty
            | None -> false
          in
          (check_expr moved consumes e, declared)
      | Ast.Expr e -> (check_expr moved false e, declared)
      | Ast.Assign (name, e) ->
          require_available s.loc moved name;
          let moved = check_expr moved (is_affine_var name) e in
          (StringSet.remove name moved, StringSet.add name declared)
      | Ast.AssignDeref (a, b) ->
          (check_expr (check_expr moved false a) false b, declared)
      | Ast.AssignField (a, _, b) ->
          (check_expr (check_expr moved false a) false b, declared)
      | Ast.AssignIndex (_, i, v) ->
          (check_expr (check_expr moved false i) false v, declared)
      | Ast.Let (_, name, _, init, _) ->
          let moved = match init with
            | Some e -> check_expr moved (is_affine_var name) e
            | None -> moved
          in
          (StringSet.remove name moved, StringSet.add name declared)
      | Ast.Block body ->
          let (out, _) = check_stmts moved declared body in
          (out, declared)
      | Ast.If (cond, yes, no) ->
          let moved = check_expr moved false cond in
          let (ym, _) = check_stmts moved declared yes in
          let (nm, _) = check_stmts moved declared no in
          (StringSet.union ym nm, declared)
      | Ast.While (cond, body) ->
          let moved = check_expr moved false cond in
          let (body_moved, _) = check_stmts moved declared body in
          let newly_moved_outer = StringSet.inter declared (StringSet.diff body_moved moved) in
          if not (StringSet.is_empty newly_moved_outer) then
            raise (TypeError (s.loc,
              "cannot consume an affine value declared outside a loop inside that loop"));
          (moved, declared)
      | Ast.For (name, _, lo, hi, body) ->
          let moved = check_expr (check_expr moved false lo) false hi in
          let declared_body = StringSet.add name declared in
          let (body_moved, _) = check_stmts moved declared_body body in
          let newly_moved_outer = StringSet.inter declared (StringSet.diff body_moved moved) in
          if not (StringSet.is_empty newly_moved_outer) then
            raise (TypeError (s.loc,
              "cannot consume an affine value declared outside a loop inside that loop"));
          (moved, declared)
      | Ast.ForEach (name, collection, body) ->
          let moved = check_expr moved false collection in
          let (body_moved, _) = check_stmts moved (StringSet.add name declared) body in
          let newly_moved_outer = StringSet.inter declared (StringSet.diff body_moved moved) in
          if not (StringSet.is_empty newly_moved_outer) then
            raise (TypeError (s.loc,
              "cannot consume an affine value declared outside a loop inside that loop"));
          (moved, declared)
      | Ast.Match (e, arms) ->
          let moved = check_expr moved false e in
          let arm_moved = List.fold_left (fun acc arm ->
            let body = match arm with
              | Ast.ArmVariant (_, _, b) | Ast.ArmWild b -> b
            in
            let (am, _) = check_stmts moved declared body in
            StringSet.union acc am
          ) moved arms in
          (arm_moved, declared)
      | Ast.Break | Ast.Continue -> (moved, declared)
    in
    ignore (check_stmts StringSet.empty
      (List.fold_left (fun d (name, _) -> StringSet.add name d)
         StringSet.empty fdef.params) fdef.body)
  in
  List.iter (function Ast.FuncDef f -> check_affine_func f | _ -> ()) prog;
  (* Deferred until AFTER Pass 3, same reasoning as check_undetermined_lets
     for locals: a global's type can be pinned not only by another global
     (the `Var vname` cross-reference case above) but also by a FUNCTION
     BODY'S usage (`let g = 1; fn f() i32 { return g; }` -- g's type is
     only ever determined by f's own return-type unification, which Pass
     3 performs). Checking right after Pass 2 (as first attempted)
     rejected that as a false positive; checking here, after everything
     that could ever constrain a global has run, does not. LetDef/genv
     carry no source location (see the Lexing.dummy_pos precedent in Pass
     2, for the same underlying reason), so this reports the same
     placeholder position other whole-program global checks already do. *)
  List.iter (function
    | Ast.LetDef (name, None, _, _, _) ->
        (match StringMap.find_opt name genv with
         | Some (ty, _) when is_undetermined ty ->
             raise (TypeError (Lexing.dummy_pos, Printf.sprintf
               "cannot determine a concrete type for global '%s': add an \
                explicit type annotation (e.g. `: i32`) -- this language \
                does not default an undetermined integer type" name))
         | _ -> ())
    | _ -> ()
  ) prog;
  let enums = StringMap.map (fun (underlying, variants, _) ->
    { underlying; variants }
  ) eenv in
  {
    globals   = StringMap.map (fun (ty, _) -> to_ast ty) genv;
    functions;
    structs   = senv;
    enums;
    call_targets = !resolved_call_targets;
  }
