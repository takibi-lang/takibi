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
  | TView of string       (* erased affine/linear permission value *)
  | TVariant of string    (* tagged runtime sum; kind is derived from payloads *)
  | TExists of string * Ast.type_expr * static_term * ty
    (* Binder name, integer sort, bound static term, payload schema. The
       binder is erased; the payload retains its ordinary runtime layout. *)
  | TIndexedStruct of string * static_term list
    (* First-class runtime struct carrying erased static indices. *)
  | TSingleton of ty * static_term
    (* Runtime value paired with an erased static name for that value. *)
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
  | TTuple of ty list     (* (T1, T2, ...) -- function-local product value
                             (OWNERSHIP_KERNEL.md 5.9, GitHub issue #120):
                             exists in returns/params/locals/literals only,
                             never in storage (fields/arrays/globals). Kind
                             = join of component kinds -- see type_inf. *)
  | TSlice of ty * int    (* []T / [T; N..] -- fat pointer (ptr + usize len);
                             int = compile-time minimum length (0 = unknown) *)
  | TAlignedPtr of int * ty
    (* *align(N) T -- a pointer PROVABLY a multiple of N bytes (GitHub issue
       #102). The pointer analogue of TRefinedInt: N is a compile-time
       constant, never a unification variable (enforced by construction,
       same discipline as TRefinedInt's own lo/hi/base). Subtyping (see
       unify below) mirrors TRefinedInt's one-directional pattern exactly:
       *align(N) T flows freely into a plain *T (widening) or a
       *align(K) T where K divides N; a plain *T or an insufficiently
       aligned pointer flowing into a *align(N) T position is rejected. *)

and tv =
  | Unbound of int  (* unresolved unification variable *)
  | Link    of ty   (* resolved: points to another type *)

and static_term =
  | SConst of int
  | SParam of int * string
    (* Rigid while checking a universally quantified function body. *)
  | SVar of static_var ref

and static_var =
  | SUnbound of int
  | SLink of static_term

(* -- Unification variables ------------------------------------------------- *)

exception TypeError of Ast.loc * string

let next_id = ref 0
let next_static_id = ref 0

let fresh () =
  incr next_id;
  TVar (ref (Unbound !next_id))

let fresh_static () =
  incr next_static_id;
  SVar (ref (SUnbound !next_static_id))

let rigid_static name =
  incr next_static_id;
  SParam (!next_static_id, name)

let fresh_rigid_static () =
  incr next_static_id;
  SParam (!next_static_id, Printf.sprintf "__value%d" !next_static_id)

type static_scope = (string, static_term) Hashtbl.t

let create_static_scope () : static_scope = Hashtbl.create 8
let bind_static (scope : static_scope) name term = Hashtbl.replace scope name term

let static_in_scope (scope : static_scope) name =
  match Hashtbl.find_opt scope name with
  | Some t -> t
  | None ->
      let t = rigid_static name in
      Hashtbl.add scope name t;
      t

let rec static_repr = function
  | SVar ({ contents = SLink t } as r) ->
      let t' = static_repr t in
      r := SLink t';
      t'
  | t -> t

let static_to_string t =
  match static_repr t with
  | SConst n -> string_of_int n
  | SParam (_, name) -> name
  | SVar { contents = SUnbound id } -> Printf.sprintf "__static%d" id
  | SVar { contents = SLink _ } -> assert false

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
  | TAlignedPtr (n, t) -> Printf.sprintf "*align(%d) %s" n (to_string t)
  | TFun (ps, r) ->
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map to_string ps)) (to_string r)
  | TStruct s -> s
  | TView s -> Printf.sprintf "view %s" s
  | TVariant s -> Printf.sprintf "variant %s" s
  | TExists (name, sort, _, body) ->
      Printf.sprintf "exists %s: %s. %s" name
        (Ast.show_type_expr sort) (to_string body)
  | TIndexedStruct (s, args) ->
      Printf.sprintf "%s[%s]" s
        (String.concat ", " (List.map static_to_string args))
  | TSingleton (base, n) ->
      Printf.sprintf "%s @ %s" (to_string base) (static_to_string n)
  | TTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map to_string ts))
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
  | TAlignedPtr (_, t)         -> occurs rv t
  | TTuple ts                  -> List.exists (occurs rv) ts
  | TExists (_, _, _, t)       -> occurs rv t
  | TIndexedStruct _           -> false
  | TSingleton (t, _)          -> occurs rv t
  | TStruct _ | TView _ | TVariant _ -> false
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
  (* Pointer alignment (GitHub issue #102): same one-directional subtyping
     shape as TRefinedInt just above. *align(N) T* proves the address is a
     multiple of N; a stricter proof (N a multiple of the required K) or a
     widening to a plain, unqualified *T* is always fine. An UNPROVEN plain
     pointer (or one proven to a non-multiple alignment) flowing into an
     *align(N) T* position is rejected with a hint toward this type's three
     proof sources (see infer_expr's Cast/AddrOf/BinOp handling in
     type_inf.ml) rather than the generic "cannot unify" fallback. *)
  | TAlignedPtr (n1, t1), TAlignedPtr (n2, t2) ->
      if n1 mod n2 <> 0 then
        raise (Unify_error (Printf.sprintf
          "cannot pass *align(%d) %s where *align(%d) %s is required \
           (%d is not a multiple of %d)"
          n1 (to_string t1) n2 (to_string t2) n1 n2));
      unify t1 t2
  | TAlignedPtr (_, t1), TPtr t2 -> unify t1 t2  (* widening to a plain pointer is always OK *)
  | TPtr t1, TAlignedPtr (n, t2) when t1 = repr t2 ->
      raise (Unify_error (Printf.sprintf
        "cannot pass unproven %s where *align(%d) %s is required; use `&x` \
         on an align(%d) variable, a literal address, pointer arithmetic by \
         a multiple of %d, or `unsafe { ... as *align(%d) %s }` to mark it"
        (to_string (TPtr t1)) n (to_string t2) n n n (to_string t2)))
  | TTuple ts1, TTuple ts2 ->
      if List.length ts1 <> List.length ts2 then
        raise (Unify_error (Printf.sprintf
          "tuple arity mismatch: %s vs %s"
          (to_string (TTuple ts1)) (to_string (TTuple ts2))));
      List.iter2 unify ts1 ts2
  | TIndexedStruct (s1, args1), TIndexedStruct (s2, args2) ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "struct type mismatch: %s vs %s" s1 s2));
      if List.length args1 <> List.length args2 then
        raise (Unify_error (Printf.sprintf
          "static argument count mismatch for %s: %d vs %d"
          s1 (List.length args1) (List.length args2)));
      List.iter2 unify_static args1 args2
  | TSingleton (base1, n1), TSingleton (base2, n2) ->
      unify base1 base2;
      unify_static n1 n2
  | (TSingleton _ as singleton), TVar rv ->
      (* Preserve a value's static identity when an inferred binding has
         not acquired a type yet.  Letting the widening rule below see the
         unresolved TVar would retain only the runtime base type, so
         `let y = x` could silently forget `x`'s singleton fact. *)
      (match !rv with
       | Link t -> unify singleton t
       | Unbound _ ->
           if occurs rv singleton then
             raise (Unify_error (Printf.sprintf
               "infinite type: %s occurs in %s"
               (to_string (TVar rv)) (to_string singleton)));
           rv := Link singleton)
  | TSingleton (base, _), expected ->
      (* Forgetting a singleton fact is a safe widening. The reverse
         direction is intentionally absent: an arbitrary runtime value
         does not prove a requested static identity. *)
      unify base expected
  | TStruct s1, TStruct s2 ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "struct type mismatch: %s vs %s" s1 s2))
  | TView s1, TView s2 ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "view type mismatch: %s vs %s" s1 s2))
  | TVariant s1, TVariant s2 ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "variant type mismatch: %s vs %s" s1 s2))
  | TExists (_, sort1, binder1, body1),
    TExists (_, sort2, binder2, body2) ->
      if sort1 <> sort2 then
        raise (Unify_error "existential static sort mismatch");
      let rec subst_static_term old replacement term =
        match static_repr old, static_repr term with
        | SParam (old_id, _), SParam (id, _) when old_id = id -> replacement
        | SVar old_r, SVar r when old_r == r -> replacement
        | _, term -> term
      and subst_ty old replacement t =
        match repr t with
        | TFun (ps, r) -> TFun (List.map (subst_ty old replacement) ps,
                                subst_ty old replacement r)
        | TPtr t -> TPtr (subst_ty old replacement t)
        | TIo t -> TIo (subst_ty old replacement t)
        | TArray (t, n) -> TArray (subst_ty old replacement t, n)
        | TRefinedInt (lo, hi, base) ->
            TRefinedInt (lo, hi, subst_ty old replacement base)
        | TTuple ts -> TTuple (List.map (subst_ty old replacement) ts)
        | TSlice (t, n) -> TSlice (subst_ty old replacement t, n)
        | TAlignedPtr (n, t) -> TAlignedPtr (n, subst_ty old replacement t)
        | TIndexedStruct (name, args) ->
            TIndexedStruct (name,
              List.map (subst_static_term old replacement) args)
        | TSingleton (base, n) ->
            TSingleton (subst_ty old replacement base,
                        subst_static_term old replacement n)
        | TExists (name, sort, binder, body) ->
            TExists (name, sort, binder, subst_ty old replacement body)
        | t -> t
      in
      unify body1 (subst_ty binder2 binder1 body2)
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

and unify_static s1 s2 =
  match static_repr s1, static_repr s2 with
  | SConst a, SConst b when a = b -> ()
  | SParam (a, _), SParam (b, _) when a = b -> ()
  | SVar r1, SVar r2 when r1 == r2 -> ()
  | SVar r, t | t, SVar r ->
      (match !r with
       | SLink t' -> unify_static t' t
       | SUnbound _ -> r := SLink t)
  | a, b ->
      raise (Unify_error (Printf.sprintf "static value mismatch: %s vs %s"
        (static_to_string a) (static_to_string b)))

(* -- Conversion to/from Ast types ----------------------------------------- *)

let static_of_ast scope = function
  | Ast.StaticName name -> static_in_scope scope name
  | Ast.StaticInt n -> SConst n

let rec of_ast_in_scope scope = function
  | Ast.TypeBool     -> TBool
  | Ast.TypeI8       -> TI8  | Ast.TypeI16 -> TI16 | Ast.TypeI32 -> TI32 | Ast.TypeI64 -> TI64
  | Ast.TypeU8       -> TU8  | Ast.TypeU16 -> TU16 | Ast.TypeU32 -> TU32 | Ast.TypeU64 -> TU64
  | Ast.TypeIsize    -> TIsize
  | Ast.TypeUsize    -> TUsize
  | Ast.TypeVoid     -> TVoid
  | Ast.TypePtr   t      -> TPtr   (of_ast_in_scope scope t)
  | Ast.TypeIo    t      -> TIo (of_ast_in_scope scope t)
  | Ast.TypeArray (t, n) -> TArray (of_ast_in_scope scope t, n)
  | Ast.TypeFn (ps, r)   -> TFun (List.map (of_ast_in_scope scope) ps, of_ast_in_scope scope r)
  | Ast.TypeNamed s      -> TStruct s
  | Ast.TypeView s       -> TView s
  | Ast.TypeVariant s    -> TVariant s
  | Ast.TypeExists (name, sort, body) ->
      let inner_scope = Hashtbl.copy scope in
      let binder = rigid_static name in
      bind_static inner_scope name binder;
      TExists (name, sort, binder, of_ast_in_scope inner_scope body)
  | Ast.TypeIndexed (s, args) ->
      TIndexedStruct (s, List.map (static_of_ast scope) args)
  | Ast.TypeSingleton (base, n) ->
      TSingleton (of_ast_in_scope scope base, static_of_ast scope n)
  | Ast.TypeRefined (lo, hi, base) ->
      TRefinedInt (lo, hi, of_ast_in_scope scope base)
  | Ast.TypeSlice (t, n) -> TSlice (of_ast_in_scope scope t, n)
  | Ast.TypeTuple ts -> TTuple (List.map (of_ast_in_scope scope) ts)
  | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t ->
      of_ast_in_scope scope t
  | Ast.TypeAlignedPtr (n, t) -> TAlignedPtr (n, of_ast_in_scope scope t)

let of_ast t = of_ast_in_scope (create_static_scope ()) t

(* None -> fresh unification variable *)
let of_ast_opt = function
  | Some t -> of_ast t
  | None   -> fresh ()

(* Return type: None means void; annotation required for non-void returns *)
let ret_of_ast_opt = function
  | Some t -> of_ast t
  | None   -> TVoid

let of_ast_opt_in_scope scope = function
  | Some t -> of_ast_in_scope scope t
  | None -> fresh ()

let ret_of_ast_opt_in_scope scope = function
  | Some t -> of_ast_in_scope scope t
  | None -> TVoid

let instantiate_static_params ty =
  let subst : (int, static_term) Hashtbl.t = Hashtbl.create 8 in
  let rec inst_static t =
    match static_repr t with
    | SConst _ as t -> t
    | SVar _ as t -> t
    | SParam (id, _) ->
        (match Hashtbl.find_opt subst id with
         | Some t -> t
         | None ->
             let t = fresh_static () in
             Hashtbl.add subst id t;
             t)
  and inst t =
    match repr t with
    | TFun (ps, r) -> TFun (List.map inst ps, inst r)
    | TPtr t -> TPtr (inst t)
    | TIo t -> TIo (inst t)
    | TArray (t, n) -> TArray (inst t, n)
    | TRefinedInt (lo, hi, base) -> TRefinedInt (lo, hi, inst base)
    | TTuple ts -> TTuple (List.map inst ts)
    | TSlice (t, n) -> TSlice (inst t, n)
    | TAlignedPtr (n, t) -> TAlignedPtr (n, inst t)
    | TIndexedStruct (name, args) ->
        TIndexedStruct (name, List.map inst_static args)
    | TSingleton (base, n) -> TSingleton (inst base, inst_static n)
    | TExists _ as t -> t
    | t -> t
  in
  inst ty

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
  | TView s       -> Ast.TypeView s
  | TVariant s    -> Ast.TypeVariant s
  | TExists (name, sort, _, body) ->
      Ast.TypeExists (name, sort, to_ast body)
  | TIndexedStruct (s, args) ->
      Ast.TypeIndexed (s, List.map static_to_ast args)
  | TSingleton (base, n) -> Ast.TypeSingleton (to_ast base, static_to_ast n)
  | TRefinedInt (lo, hi, base) -> Ast.TypeRefined (lo, hi, to_ast base)
  | TSlice (t, n) -> Ast.TypeSlice (to_ast t, n)
  | TAlignedPtr (n, t) -> Ast.TypeAlignedPtr (n, to_ast t)
  | TTuple ts -> Ast.TypeTuple (List.map to_ast ts)
  | TVar { contents = Unbound _ } -> Ast.TypeI32
  | TVar { contents = Link _ }    -> assert false

and static_to_ast t =
  match static_repr t with
  | SConst n -> Ast.StaticInt n
  | SParam (_, name) -> Ast.StaticName name
  | SVar { contents = SUnbound id } -> Ast.StaticName (Printf.sprintf "__static%d" id)
  | SVar { contents = SLink _ } -> assert false

(* -- Output structs passed to codegen ------------------------------------- *)

module StringMap = Map.Make(String)

type func_info = {
  ret_type    : Ast.type_expr;
  param_types : (string * Ast.type_expr) list;
  local_types : Ast.type_expr StringMap.t;
  effects     : string list;
  (* Inferred checker effects. These have no runtime representation. *)
}

type enum_info = {
  underlying : Ast.type_expr;         (* u8 / u16 / u32 / u64 *)
  variants   : (string * int) list;   (* [(variant_name, discriminant_value); ...] *)
}

type program_types = {
  globals   : Ast.type_expr StringMap.t;
  functions : func_info StringMap.t;
  structs   : ((string * Ast.type_expr) list * bool * int option) StringMap.t;
    (* fields, is_packed, align_bytes -- see lib/type_inf.ml's senv, which
       this is a direct passthrough of. *)
  enums     : enum_info StringMap.t;
  call_targets : string StringMap.t;
  (* struct name -> ordered field list [(field_name, field_type)] *)
  (* enum name  -> underlying type + variant list                 *)
}

let loc_key (loc : Ast.loc) =
  Printf.sprintf "%s:%d:%d" loc.Lexing.pos_fname loc.Lexing.pos_lnum
    (loc.Lexing.pos_cnum - loc.Lexing.pos_bol)
