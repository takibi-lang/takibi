open Types

(* Type environment: immutable map from variable name to (type, is_mutable) *)
type tyenv = (ty * bool) StringMap.t

(* Struct environment: maps struct name to its ordered field list [(name, ast_type)] *)
type senv = (string * Ast.type_expr) list StringMap.t

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

(* Require an integer type, defaulting a genuinely-unconstrained type
   variable to i32 (this language's existing "unconstrained integer
   literal defaults to i32" convention -- see Types.to_ast's `TVar
   (Unbound _) -> TypeI32` case) rather than rejecting it outright. Used
   everywhere an index/loop-bound-shaped value is required (Index,
   AssignIndex, SliceOf, For): unlike TRefinedInt (which enjoys
   unconditional leniency into TI32 via its own subtyping rule), a BARE
   concrete type like TU8/TUsize/TI64 has no such rule, so a plain
   `unify_at loc t TI32` alone wrongly rejects, e.g., a for-loop counter
   over `s.len` (TUsize, not wrapped in TRefinedInt when the length isn't
   a compile-time constant) used as an array index -- a real gap found
   while generalizing For's loop-counter base (see CLAUDE.md's
   "Refinement Numerical Type" section). Only defaults the TVar when
   nothing else has pinned a concrete type yet; it does not override one
   that something else (e.g. `s.len`'s own TUsize) already determined. *)
let require_integer loc t =
  let base = canon_ty t in
  (match repr base with
   | TVar { contents = Unbound _ } -> unify_at loc base TI32
   | _ -> ());
  (match repr base with
   | TI8 | TI16 | TI32 | TI64 | TU8 | TU16 | TU32 | TU64 | TUsize -> ()
   | _ -> raise (TypeError (loc,
       Printf.sprintf "expected an integer type, got '%s'" (to_string t))))

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
           | Some ft -> ft
           | None ->
               raise (TypeError (e.loc,
                 Printf.sprintf "Unbound variable: %s" name)))
  | BinOp (op, e1, e2) ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      let t2 = infer_expr senv eenv tyenv fenv e2 in
      (match op with
       | Add ->
           (* Pointer arithmetic: ptr + int -> returns the same pointer type. TIo is a value type, excluded.
              Range propagation (interval arithmetic; sync rule: llvm_gen's
              BinOp typing mirrors every case below, change together):
                {a..<b} + {c..<d} -> {a+c..<b+d-1}
                {a..<b} + k       -> {a+k..<b+k}   (and symmetric) *)
           (match repr t1, repr t2 with
            | TPtr _, _ -> t1
            | _, TPtr _ -> t2
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
           (* Pointer arithmetic: ptr - int -> returns the same pointer type. TIo is a value type, excluded.
              Range propagation (sync rule with llvm_gen, as for Add):
                {a..<b} - {c..<d} -> {a-d+1..<b-c}
                {a..<b} - k       -> {a-k..<b-k}
                k - {c..<d}       -> {k-d+1..<k-c+1}  (k a literal; symmetric
                                      with Add's both-directions handling --
                                      what makes `40 - ihl` carry ihl's
                                      Band/min-derived range through to
                                      "remaining room" for a chained clamp,
                                      see CLAUDE.md's P4c section) *)
           (match repr t1 with
            | TPtr _ ->
                unify_at e2.loc t2 TI32;
                t1
            | TRefinedInt (a, b, base) ->
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
            | _ ->
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
             | Some fs -> fs
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
            | _ -> tgt)))

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
        | Some fs -> fs
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
      require_integer idx.loc it;
      (match repr vt with
       | TArray (elem, n) ->
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
       | TSlice (elem, _) -> elem  (* runtime length; codegen elides the check
                                      only when idx's range fits the MINIMUM *)
       | TPtr   elem      -> strip_io elem     (* *T or *io T -> returns T (bounds unknown) *)
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt))))

  | SliceOf (id, lo_e, hi_e) ->
      let vt = lookup e.loc id tyenv in
      let lo_t = infer_expr senv eenv tyenv fenv lo_e in
      let hi_t = infer_expr senv eenv tyenv fenv hi_e in
      (* require_integer accepts a bound of ANY integer type, refined or
         bare: a TRefinedInt bound (e.g. `ihl: {20..<21 as u8}`) passes via
         its own base-agnostic subtyping into TI32; a bare non-i32 type
         (e.g. a for-loop counter over `s.len`, itself TUsize) passes
         because require_integer checks "is this some integer type", not
         "does this unify with TI32 specifically" -- a plain
         `unify_at lo_e.loc lo_t TI32` would reject the bare case outright
         (only TRefinedInt has a leniency rule into TI32; a bare TUsize/
         TU8/etc. has none). Found via two real regressions: a u8-based
         refined bound (canon_ty'd first, which strips the leniency) and,
         later, a bare usize bound from a generalized for-loop counter --
         see CLAUDE.md's "Refinement Numerical Type" section. *)
      require_integer lo_e.loc lo_t;
      require_integer hi_e.loc hi_t;
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
      TUsize

  | StructLit _ ->
      raise (TypeError (e.loc,
        "struct literal requires a type annotation: `let mut x: Name = {...}`"))

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
      (* Try direct call (function name -> fenv) first *)
      let ft_opt = match StringMap.find_opt fname fenv with
        | Some ft -> Some ft
        | None ->
            (* Try function pointer variable (tyenv) *)
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
             unify_at arg.loc at pt
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
        | Some fs -> fs
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
      unify_at e.loc te (strip_io expected)

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
      match lo_opt, hi_opt with
      | Some lo, Some hi when not (List.mem name killed) ->
          (match StringMap.find_opt name env with
           (* Already refined (e.g. an immutable let whose initializer was
              itself refined, kept via the "proofs survive weaker
              annotations" rule -- see check_bound_shadowing/B-plan) --
              INTERSECT rather than no-op. Without this, a variable that
              arrives at the if already-refined (very common once P4a's
              interval propagation is in play) would silently keep its
              WIDER pre-existing range instead of the tighter one the
              condition just proved, e.g. `icmp_len: {0..<1481}` at entry
              plus `if (icmp_len >= 8 && icmp_len <= 1480)` must become
              {8..<1481}, not stay {0..<1481}. *)
           | Some (TRefinedInt (elo, ehi, base), is_mut) ->
               StringMap.add name (TRefinedInt (max lo elo, min hi ehi, base), is_mut) env
           (* Any plain primitive integer type can be narrowed, not just
              TI32 -- a u8/u16/u32/u64/usize/i8/i16/i64-typed variable
              narrowed by an if-condition keeps ITS OWN type as the
              refined range's base (see types.ml's TRefinedInt comment). *)
           | Some ((TI8|TI16|TI32|TI64|TU8|TU16|TU32|TU64|TUsize) as base, is_mut) ->
               StringMap.add name (TRefinedInt (lo, hi, base), is_mut) env
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
      (tyenv, raw_locals)
  | AssignIndex (id, idx, rhs) ->
      (* Dispatch on the variable's original type ([T; N] vs *T). tyenv holds the pre-decay type *)
      let vt = lookup s.loc id tyenv in
      let it = infer_expr senv eenv tyenv fenv idx in
      let rt = infer_expr senv eenv tyenv fenv rhs in
      require_integer idx.loc it;
      let elem_ty = match repr vt with
        | TArray (elem, n) ->
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
        | TSlice (elem, _) -> elem
        | TPtr   elem      -> strip_io elem
        | _ -> raise (TypeError (s.loc,
            Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt)))
      in
      unify_at rhs.loc rt elem_ty;
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
        | Some fs -> fs
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
      (tyenv, raw_locals)
  | Let (is_mut, name, ty_opt, expr_opt) ->
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
  | For (name, lo_expr, hi_expr, body) ->
      let lo_ty = infer_expr senv eenv tyenv fenv lo_expr in
      let hi_ty = infer_expr senv eenv tyenv fenv hi_expr in
      (* The loop counter's base now follows the BOUNDS' own type, instead
         of hardcoding TI32 (the same generalization already applied to
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
      (* require_integer both validates base_raw is an integer type and,
         if neither bound pinned a concrete type at all (both bare,
         otherwise-unconstrained literals, e.g. `for i in 0..<8`), defaults
         it to i32 -- this language's existing "unconstrained integer
         literal defaults to i32" convention, not a NEW fallback. It does
         NOT override a type something else (e.g. `s.len`) already pinned. *)
      require_integer lo_expr.loc base_raw;
      let base = repr base_raw in
      (* Refine to TRefinedInt when both bounds are compile-time integers:
         a literal, or the name of a Const_env global constant (sound because
         check_const_shadowing rejects any local reusing a constant name).
         For runtime variables, conservatively use the bounds' own base.
         Sync rule: llvm_gen.ml's For case makes the same decision through
         the same Const_env.bound_value helper; keep them identical. *)
      let idx_ty = match Const_env.bound_value lo_expr, Const_env.bound_value hi_expr with
        | Some lo_v, Some hi_v -> TRefinedInt (lo_v, hi_v, base)
        | _ -> base
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
    | Ast.Let (_, name, _, _) ->
        if Const_env.find name <> None then reject s.loc name
    | Ast.Block ss | Ast.While (_, ss) -> List.iter go_stmt ss
    | Ast.If (_, t, e) -> List.iter go_stmt t; List.iter go_stmt e
    | Ast.For (name, _, _, body) ->
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
  {
    ret_type    = to_ast ret_ty;
    param_types = List.map2 (fun (name, _) ty -> (name, to_ast ty))
                    fdef.params param_tys;
    local_types = StringMap.map to_ast raw_locals;
  }

(* -- Whole-program inference ----------------------------------------------- *)

let infer_program (prog : Ast.toplevel list) : program_types =
  unsafe_depth := 0;  (* see its comment: fresh per compilation / per unit test *)
  (* Pass 0: collect struct and enum definitions *)
  let senv = List.fold_left (fun m -> function
    | Ast.StructDef (name, fields, _, _) -> StringMap.add name fields m
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
    if name = "slice_copy" || name = "slice_eq" || name = "min" || name = "max" then
      raise (TypeError (loc,
        Printf.sprintf "'%s' is a compiler builtin and cannot be redefined" name))
  in
  let fenv = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        check_reserved_fn fdef.def_loc fdef.name;
        let pts = List.map (fun (_, t) -> of_ast_opt t) fdef.params in
        let rt  = ret_of_ast_opt fdef.ret_type in
        StringMap.add fdef.name (TFun (pts, rt)) m
    | Ast.ExternFuncDef (name, params, ret_ty) ->
        check_reserved_fn Lexing.dummy_pos name;
        let pts = List.map (fun (_, t) -> of_ast_opt t) params in
        let rt  = ret_of_ast_opt ret_ty in
        StringMap.add name (TFun (pts, rt)) m
    | Ast.LetDef _    -> m
    | Ast.StructDef _ -> m
    | Ast.EnumDef _   -> m
  ) StringMap.empty prog in
  (* Global mutability: plain `let` = immutable compile-time constant, `let mut` = variable.
     Reuses the same tyenv-based mutability check as local variables (Assign/AddrOf). *)
  let genv = List.fold_left (fun m -> function
    | Ast.LetDef (name, ty_opt, _, _, is_mutable) -> StringMap.add name (of_ast_opt ty_opt, is_mutable) m
    | Ast.FuncDef _                -> m
    | Ast.ExternFuncDef _          -> m
    | Ast.StructDef _              -> m
    | Ast.EnumDef _                -> m
  ) StringMap.empty prog in
  (* Pass 2: check global initializers *)
  List.iter (function
    | Ast.LetDef (name, _, expr_opt, _, is_mutable) ->
        let (ty, _) = StringMap.find name genv in
        (match expr_opt with
         | None ->
             if not is_mutable then
               raise (TypeError (Lexing.dummy_pos,
                 Printf.sprintf "immutable global '%s' must have an initializer; use 'let mut' for uninitialized globals" name))
         | Some { desc = Ast.StructLit exprs; loc } ->
             (match repr ty with
              | (TStruct _ | TArray _) as expected ->
                  check_expr senv eenv genv fenv { desc = Ast.StructLit exprs; loc } expected
              | _ -> raise (TypeError (loc,
                  "literal { ... } requires a struct or array type annotation")))
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
                  (try unify (strip_io ty) (strip_io vty)
                   with Unify_error m -> raise (TypeError (loc, m)))
              | None ->
                  raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" vname)))
         | Some e ->
             let et = infer_expr senv eenv genv fenv e in
             (try unify (strip_io ty) et
              with Unify_error m -> raise (TypeError (e.loc, m))))
    | _ -> ()
  ) prog;
  (* Pass 3: infer function bodies *)
  let functions = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        StringMap.add fdef.name (infer_func senv eenv fenv genv fdef) m
    | _ -> m
  ) StringMap.empty prog in
  let enums = StringMap.map (fun (underlying, variants, _) ->
    { underlying; variants }
  ) eenv in
  {
    globals   = StringMap.map (fun (ty, _) -> to_ast ty) genv;
    functions;
    structs   = senv;
    enums;
  }
