(* Hindley-Milner type representation with unification variables *)

type ty =
  | TBool
  | TI8  | TI16 | TI32 | TI64
  | TU8  | TU16 | TU32 | TU64
  | TIsize  (* pointer-sized signed integer *)
  | TUsize  (* pointer-sized unsigned integer; maps to i64 on 64-bit targets *)
  | TVoid
  | TFun of ty list * ty  (* param types, return type *)
  | TVar of tv ref
  | TPtr of ty            (* *T    -- regular pointer, non-volatile *)
  | TIo  of ty            (* io T  -- volatile-qualified value type; *io T = TPtr(TIo T) *)
  | TArray of ty * int    (* array type: [T; N] *)
  | TStruct of string     (* named struct type *)
  | TRefinedInt of int * int * ty
    (* {lo..<hi} -- refined int with known range; lo <= x < hi. Third field
       is the underlying primitive type this range is tied to (always one
       of TI8/TI16/TI32/TI64/TU8/TU16/TU32/TU64/TIsize/TUsize -- enforced by
       construction discipline, not the type system, same as this
       project's other "shape guaranteed by construction site, not by a
       dedicated variant" conventions, e.g. Const_env's bare-IntLit-only
       recording). Determines both the LLVM representation width (was
       unconditionally i32 before this field existed; see CLAUDE.md's
       "Refinement Numerical Type: Width/Signedness-Aware TRefinedInt"
       section) and signedness (is_unsigned reads it directly) for
       operations -- comparisons, shifts, extension direction -- performed
       on a refined value. Source annotations require the explicit
       `{lo..<hi as base}` syntax; bare `{lo..<hi}` is currently rejected.
       Range propagation preserves an already-typed operand's base (e.g.
       `u64_var & 0xff` produces a TU64-based {0..<256}), and a for-loop
       counter follows its bounds/annotation base. Array and slice indices
       therefore use TUsize-based refinements, while raw-pointer offsets use
       TIsize-based refinements. *)
  | TSlice of ty * int    (* []T / [T; N..] -- fat pointer (ptr + usize len);
                             int = compile-time minimum length (0 = unknown) *)

and tv =
  | Unbound of int  (* unresolved unification variable *)
  | Link    of ty   (* resolved: points to another type *)

(* -- Unification variables ------------------------------------------------- *)

exception TypeError of Ast.loc * string

let next_id = ref 0

let fresh () =
  incr next_id;
  TVar (ref (Unbound !next_id))

(* Follow Link chains, applying path compression *)
let rec repr = function
  | TVar ({ contents = Link t } as r) ->
      let t' = repr t in r := Link t'; t'
  | t -> t

let rec to_string t =
  match repr t with
  | TBool -> "bool"
  | TI8   -> "i8"  | TI16 -> "i16" | TI32 -> "i32" | TI64 -> "i64"
  | TU8   -> "u8"  | TU16 -> "u16" | TU32 -> "u32" | TU64 -> "u64"
  | TIsize -> "isize"
  | TUsize -> "usize"
  | TVoid -> "void"
  | TPtr t -> Printf.sprintf "*%s" (to_string t)   (* *io T prints as "*io T" via TPtr(TIo T) *)
  | TIo  t -> Printf.sprintf "io %s" (to_string t)
  | TArray (t, n) -> Printf.sprintf "[%s; %d]" (to_string t) n
  | TSlice (t, 0) -> Printf.sprintf "[]%s" (to_string t)
  | TSlice (t, n) -> Printf.sprintf "[%s; %d..]" (to_string t) n
  | TFun (ps, r) ->
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map to_string ps)) (to_string r)
  | TStruct s -> s
  | TRefinedInt (lo, hi, _) -> Printf.sprintf "{%d..<%d}" lo hi
  | TVar { contents = Unbound id } -> Printf.sprintf "'t%d" id
  | TVar { contents = Link _ }     -> assert false

(* -- Unification ----------------------------------------------------------- *)

exception Unify_error of string

let rec occurs rv = function
  | TVar { contents = Link t } -> occurs rv t
  | TVar r                     -> r == rv
  | TFun (ps, r)               -> List.exists (occurs rv) ps || occurs rv r
  | TPtr   t                   -> occurs rv t
  | TIo    t                   -> occurs rv t
  | TArray (t, _)              -> occurs rv t
  | TSlice (t, _)              -> occurs rv t
  | TStruct _                  -> false
  | _                          -> false

let rec unify t1 t2 =
  match repr t1, repr t2 with
  | TBool, TBool | TVoid, TVoid -> ()
  | TI8,  TI8  | TI16, TI16 | TI32, TI32 | TI64, TI64 -> ()
  | TU8,  TU8  | TU16, TU16 | TU32, TU32 | TU64, TU64 -> ()
  | TIsize, TIsize -> ()
  | TUsize, TUsize -> ()
  | TPtr t1, TPtr t2 -> unify t1 t2
  | TIo  t1, TIo  t2 -> unify t1 t2
  | TArray (t1, n1), TArray (t2, n2) ->
      if n1 <> n2 then
        raise (Unify_error (Printf.sprintf "array size mismatch: %d vs %d" n1 n2));
      unify t1 t2
  | TFun (ps1, r1), TFun (ps2, r2) ->
      if List.length ps1 <> List.length ps2 then
        raise (Unify_error "argument count mismatch");
      List.iter2 unify ps1 ps2;
      unify r1 r2
  | TRefinedInt (lo1, hi1, base1), TRefinedInt (lo2, hi2, base2) ->
      if lo1 <> lo2 || hi1 <> hi2 then
        raise (Unify_error (Printf.sprintf
          "refined int range mismatch: {%d..<%d} vs {%d..<%d}" lo1 hi1 lo2 hi2));
      unify base1 base2
  (* Slice subtyping mirrors TRefinedInt's: a slice whose proven minimum
     length is LARGER can be used where a smaller minimum is expected
     (actual guarantee is stronger). unify's call sites pass (actual,
     expected) -- Call args, Assign, Return all follow that order. The
     reverse direction is the anti-subtyping guard: an unproven/shorter
     slice cannot flow into a position demanding a longer minimum. *)
  | TSlice (e1, m1), TSlice (e2, m2) ->
      if m1 < m2 then
        raise (Unify_error (Printf.sprintf
          "cannot pass %s where %s is required; \
           narrow with if (s.len >= %d) { ... } or a constant subslice"
          (to_string (TSlice (e1, m1))) (to_string (TSlice (e2, m2))) m2));
      unify e1 e2
  (* Subtyping: TRefinedInt(lo, hi, base) is a subtype of any integer type
     where the range fits, REGARDLESS of its own base -- this check is
     purely about whether the VALUE range fits the target's representable
     range; coerce (llvm_gen.ml) already handles any width/sign mismatch
     between base and the target via ordinary narrow/widen. One direction
     only: refined -> wider type is OK; unproven wider type -> refined is NG. *)
  | TRefinedInt _, TI32 -> ()                           (* i32: always fits (i32 range) *)
  | TRefinedInt _, TI64  -> ()                          (* i64: i32 range always fits *)
  | TRefinedInt _, TIsize -> ()                         (* surface ranges fit signed 32-bit *)
  | TRefinedInt (lo, hi, _), TU8  when lo >= 0 && hi <= 256     -> ()
  | TRefinedInt (lo, hi, _), TU16 when lo >= 0 && hi <= 65536   -> ()
  | TRefinedInt (lo, _, _),  TU32 when lo >= 0                  -> ()   (* practical: hi < 2^31 *)
  | TRefinedInt (lo, _, _),  TU64 when lo >= 0                  -> ()
  | TRefinedInt (lo, _, _),  TUsize when lo >= 0                -> ()
  | TRefinedInt (lo, hi, _), TI8  when lo >= -128  && hi <= 128 -> ()
  | TRefinedInt (lo, hi, _), TI16 when lo >= -32768 && hi <= 32768 -> ()
  | t1, TRefinedInt (lo, hi, base) when t1 = repr base ->
      (* Anti-subtyping guard, generalized from the old TI32-only case: an
         UNPROVEN value of exactly the refined type's own base cannot flow
         into a position demanding a proven range. A value of a genuinely
         DIFFERENT type falls through to the generic "cannot unify"
         mismatch below instead. `base` is a NESTED field inside the
         already-repr'd t2, so it is not itself guaranteed dereferenced --
         must repr it again before comparing (t1 is already repr'd, via
         the outer `match repr t1, repr t2 with`). *)
      raise (Unify_error (Printf.sprintf
        "cannot pass unproven %s where {%d..<%d} is required; \
         use if (v >= %d && v < %d) { ... } to narrow the range"
        (to_string t1) lo hi lo hi))
  | TStruct s1, TStruct s2 ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "struct type mismatch: %s vs %s" s1 s2))
  | TVar rv, t | t, TVar rv ->
      (match !rv with
       | Link t' -> unify t' t
       | Unbound _ ->
           if occurs rv t then
             raise (Unify_error (Printf.sprintf
               "infinite type: %s occurs in %s"
               (to_string (TVar rv)) (to_string t)));
           rv := Link t)
  | t1, t2 ->
      raise (Unify_error (Printf.sprintf "cannot unify %s with %s"
        (to_string t1) (to_string t2)))

(* -- Conversion to/from Ast types ----------------------------------------- *)

let rec of_ast = function
  | Ast.TypeBool     -> TBool
  | Ast.TypeI8       -> TI8  | Ast.TypeI16 -> TI16 | Ast.TypeI32 -> TI32 | Ast.TypeI64 -> TI64
  | Ast.TypeU8       -> TU8  | Ast.TypeU16 -> TU16 | Ast.TypeU32 -> TU32 | Ast.TypeU64 -> TU64
  | Ast.TypeIsize    -> TIsize
  | Ast.TypeUsize    -> TUsize
  | Ast.TypeVoid     -> TVoid
  | Ast.TypePtr   t      -> TPtr   (of_ast t)
  | Ast.TypeIo    t      -> TIo (of_ast t)
  | Ast.TypeArray (t, n) -> TArray (of_ast t, n)
  | Ast.TypeFn (ps, r)   -> TFun (List.map of_ast ps, of_ast r)
  | Ast.TypeNamed s      -> TStruct s
  | Ast.TypeRefined (lo, hi, base) -> TRefinedInt (lo, hi, of_ast base)
  | Ast.TypeSlice (t, n) -> TSlice (of_ast t, n)

(* None -> fresh unification variable *)
let of_ast_opt = function
  | Some t -> of_ast t
  | None   -> fresh ()

(* Return type: None means void; annotation required for non-void returns *)
let ret_of_ast_opt = function
  | Some t -> of_ast t
  | None   -> TVoid

(* After unification, collapse to a concrete Ast type.
   Unbound variables default to int (unconstrained integer) *)
let rec to_ast t =
  match repr t with
  | TBool -> Ast.TypeBool
  | TI8   -> Ast.TypeI8  | TI16 -> Ast.TypeI16 | TI32 -> Ast.TypeI32 | TI64 -> Ast.TypeI64
  | TU8   -> Ast.TypeU8  | TU16 -> Ast.TypeU16 | TU32 -> Ast.TypeU32 | TU64 -> Ast.TypeU64
  | TIsize -> Ast.TypeIsize
  | TUsize -> Ast.TypeUsize
  | TVoid -> Ast.TypeVoid
  | TPtr   t      -> Ast.TypePtr  (to_ast t)
  | TIo    t      -> Ast.TypeIo   (to_ast t)
  | TArray (t, n) -> Ast.TypeArray (to_ast t, n)
  | TFun (ps, r)  -> Ast.TypeFn (List.map to_ast ps, to_ast r)
  | TStruct s     -> Ast.TypeNamed s
  | TRefinedInt (lo, hi, base) -> Ast.TypeRefined (lo, hi, to_ast base)
  | TSlice (t, n) -> Ast.TypeSlice (to_ast t, n)
  | TVar { contents = Unbound _ } -> Ast.TypeI32
  | TVar { contents = Link _ }    -> assert false

(* -- Output structs passed to codegen ------------------------------------- *)

module StringMap = Map.Make(String)

type func_info = {
  ret_type    : Ast.type_expr;
  param_types : (string * Ast.type_expr) list;
  local_types : Ast.type_expr StringMap.t;
}

type enum_info = {
  underlying : Ast.type_expr;         (* u8 / u16 / u32 / u64 *)
  variants   : (string * int) list;   (* [(variant_name, discriminant_value); ...] *)
}

type program_types = {
  globals   : Ast.type_expr StringMap.t;
  functions : func_info StringMap.t;
  structs   : (string * Ast.type_expr) list StringMap.t;
  enums     : enum_info StringMap.t;
  (* struct name -> ordered field list [(field_name, field_type)] *)
  (* enum name  -> underlying type + variant list                 *)
}
