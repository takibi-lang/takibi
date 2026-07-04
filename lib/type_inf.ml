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

(* Accept bool or any integer type as a condition (for if/while) *)
let check_cond loc ct =
  match repr ct with
  | TBool -> ()
  | _ -> unify_at loc ct TI32

(* Widen TRefinedInt to TI32; leave explicit-width types unchanged.
   Used by arithmetic ops that do not propagate range information (Mul, Div, shifts, bitwise).
   Without this, `i: {0..<8}` in `i * 4` would produce TRefinedInt(0,8) and later cause
   `TI32 >> TRefinedInt` to fail the unification anti-subtyping guard. *)
let canon_ty t = match repr t with TRefinedInt _ -> TI32 | t -> t

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
           (* Pointer arithmetic: ptr + int -> returns the same pointer type. TIo is a value type, excluded *)
           (match repr t1, repr t2 with
            | TPtr _, _ -> t1
            | _, TPtr _ -> t2
            (* Range propagation: {a..<b} + k -> {a+k..<b+k}. Precision preserved only when other operand is IntLit *)
            | TRefinedInt (a, b), _ ->
                (match e2.desc with
                 | IntLit k ->
                     unify_at e2.loc t2 TI32;
                     TRefinedInt (a + k, b + k)
                 | _ ->
                     unify_at e2.loc (canon_ty t2) TI32;
                     TI32)
            | _, TRefinedInt (c, d) ->
                (match e1.desc with
                 | IntLit k ->
                     unify_at e1.loc t1 TI32;
                     TRefinedInt (c + k, d + k)
                 | _ ->
                     unify_at e1.loc (canon_ty t1) TI32;
                     TI32)
            | _ ->
                let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                unify_at e.loc ct1 ct2;
                ct1)
       | Sub ->
           (* Pointer arithmetic: ptr - int -> returns the same pointer type. TIo is a value type, excluded *)
           (match repr t1 with
            | TPtr _ ->
                unify_at e2.loc t2 TI32;
                t1
            (* Range propagation: {a..<b} - k -> {a-k..<b-k}. Precision preserved only when RHS is IntLit *)
            | TRefinedInt (a, b) ->
                (match e2.desc with
                 | IntLit k ->
                     unify_at e2.loc t2 TI32;
                     TRefinedInt (a - k, b - k)
                 | _ ->
                     unify_at e2.loc (canon_ty t2) TI32;
                     TI32)
            | _ ->
                let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                unify_at e.loc ct1 ct2;
                ct1)
       | Mul | Div ->
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
           (match e2.desc with
            | IntLit m when m > 0 ->
                (match repr t1 with
                 | TRefinedInt (lo, _) when lo >= 0 -> TRefinedInt (0, m)
                 | t when is_unsigned_ty t -> TRefinedInt (0, m)
                 | _ -> ct1)
            | _ -> ct1)
       | Or | And ->
           check_cond e1.loc t1;
           check_cond e2.loc t2;
           TBool
       | Bor | Bxor | Band | Shr | Shl ->
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
            | _ -> tgt))

  | FieldGet (base_expr, fname) ->
      let bt = infer_expr senv eenv tyenv fenv base_expr in
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
             Printf.sprintf "no field '%s' in struct '%s'" fname sname)))

  | Index (id, idx) ->
      (* Get the variable's original type (no array decay, unlike Var) *)
      let vt = lookup e.loc id tyenv in
      let it = infer_expr senv eenv tyenv fenv idx in
      unify_at idx.loc it TI32;
      (match repr vt with
       | TArray (elem, n) ->
           (* Constant index: check bounds at compile time *)
           (match idx.desc with
            | IntLit k when k >= n ->
                raise (TypeError (idx.loc,
                  Printf.sprintf "index %d is out of bounds for array of size %d" k n))
            | _ -> ());
           elem
       | TPtr   elem      -> strip_io elem     (* *T or *io T -> returns T (bounds unknown) *)
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt))))

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
let collect_bounds (cond : Ast.expr) : (int option * int option) StringMap.t =
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
  let rec go (e : Ast.expr) acc = match e.desc with
    | BinOp (And, e1, e2)                                          -> go e2 (go e1 acc)
    | BinOp (Ge, {desc=Var n;_}, {desc=IntLit lo;_})              -> update n (Some lo)     None          acc
    | BinOp (Gt, {desc=Var n;_}, {desc=IntLit lo;_})              -> update n (Some (lo+1)) None          acc
    | BinOp (Lt, {desc=Var n;_}, {desc=IntLit hi;_})              -> update n None          (Some hi)     acc
    | BinOp (Le, {desc=Var n;_}, {desc=IntLit hi;_})              -> update n None          (Some (hi+1)) acc
    | BinOp (Le, {desc=IntLit lo;_}, {desc=Var n;_})              -> update n (Some lo)     None          acc
    | BinOp (Lt, {desc=IntLit lo;_}, {desc=Var n;_})              -> update n (Some (lo+1)) None          acc
    | BinOp (Ge, {desc=IntLit hi;_}, {desc=Var n;_})              -> update n None          (Some (hi+1)) acc
    | BinOp (Gt, {desc=IntLit hi;_}, {desc=Var n;_})              -> update n None          (Some hi)     acc
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
  let bounds = collect_bounds cond in
  StringMap.fold (fun name (lo_opt, hi_opt) env ->
    match lo_opt, hi_opt with
    | Some lo, Some hi when not (List.mem name killed) ->
        (match StringMap.find_opt name env with
         | Some (TI32, is_mut) ->
             StringMap.add name (TRefinedInt (lo, hi), is_mut) env
         | _ -> env)
    | _ -> env
  ) bounds tyenv

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
      unify_at idx.loc it TI32;
      let elem_ty = match repr vt with
        | TArray (elem, n) ->
            (match idx.desc with
             | IntLit k when k >= n ->
                 raise (TypeError (idx.loc,
                   Printf.sprintf "index %d is out of bounds for array of size %d" k n))
             | _ -> ());
            elem
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
      (match expr_opt with
       | None ->
           if not is_mut then
             raise (TypeError (s.loc,
               Printf.sprintf "immutable variable '%s' must have an initializer" name))
       | Some { desc = StructLit exprs; loc } ->
           (* Struct literal: look up struct name from the type annotation and check each field *)
           if not is_mut then
             raise (TypeError (loc,
               Printf.sprintf "struct literal requires `let mut %s: Name = {...}`" name));
           (match repr ty with
            | (TStruct _ | TArray _) as expected ->
                check_expr senv eenv tyenv fenv { desc = StructLit exprs; loc } expected
            | _ -> raise (TypeError (loc,
                "literal { ... } requires a struct or array type annotation")))
       | Some e ->
           let et = infer_expr senv eenv tyenv fenv e in
           (* Initialization: match actual(expr) as a subtype of expected(type annotation) *)
           unify_at e.loc et (strip_io ty));
      ( StringMap.add name (ty, is_mut) tyenv,
        StringMap.add name ty raw_locals )
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
      unify_at lo_expr.loc lo_ty TI32;
      unify_at hi_expr.loc hi_ty TI32;
      (* Refine to TRefinedInt when both bounds are compile-time integers:
         a literal, or the name of a Const_env global constant (sound because
         check_const_shadowing rejects any local reusing a constant name).
         For runtime variables, conservatively use TI32.
         Sync rule: llvm_gen.ml's For case makes the same decision through
         the same Const_env.bound_value helper; keep them identical. *)
      let idx_ty = match Const_env.bound_value lo_expr, Const_env.bound_value hi_expr with
        | Some lo_v, Some hi_v -> TRefinedInt (lo_v, hi_v)
        | _ -> TI32
      in
      (* Loop variable is immutable (Imm binding, no reassignment). Does not escape the loop. *)
      let body_env = StringMap.add name (idx_ty, false) tyenv in
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
        (body_env, raw_locals) body
      in
      (tyenv, raw_locals')

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
  let fenv = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        let pts = List.map (fun (_, t) -> of_ast_opt t) fdef.params in
        let rt  = ret_of_ast_opt fdef.ret_type in
        StringMap.add fdef.name (TFun (pts, rt)) m
    | Ast.ExternFuncDef (name, params, ret_ty) ->
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
