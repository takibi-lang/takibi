(* GitHub issue #207: compile-time monomorphization of `generic struct`
   templates and generic functions (a `fn` with one or more `T: type`
   parameters -- no new grammar needed for those, `type` is just an
   ordinary base_type_expr). Runs as a whole-program AST pass BEFORE
   type_inf.ml/llvm_gen.ml ever see the program, so that 95% of the existing
   checker/codegen pipeline needs zero changes: by the time this pass
   returns, every TypeGenericInst node has either been resolved to an
   ordinary TypeNamed reference to a freshly-generated, fully concrete
   StructDef, or (if its name was never a known generic struct) left
   untouched for type_inf.ml's existing "generics are not implemented yet"
   error to catch, exactly as it does today; and every call to a generic
   function has either been rewritten to call a freshly-generated, fully
   concrete FuncDef under a mangled name, or (if the type argument(s)
   couldn't be inferred) rejected with a clear error right here.

   Approach: a single recursive `transform` walks every type_expr, in one
   pass substituting a template's own type-parameter names (when building a
   concrete instantiation's field/param/body types) and/or resolving
   TypeGenericInst nodes (when rewriting the rest of the program to
   reference a generated struct). The two concerns are combined into one
   traversal rather than duplicated across two, since both need to
   enumerate every type_expr constructor to recurse correctly.

   Generic function calls are resolved by a narrow, deliberately weak
   inference rule (see the approved generics plan): a call's type
   argument(s) are only inferred when every generic-typed value argument is
   a bare `Var name` or `&name`, and `name`'s type is already known from a
   syntactically local, explicit annotation (a parameter or an earlier
   `let`/global with an explicit type) -- a flat symbol-table lookup, not
   real expression-level type inference. This deliberately does not touch
   type_inf.ml's own HM/TVar machinery at all. *)

open Ast

(* -- type_expr transformation ---------------------------------------------

   `subst`: template-parameter substitution, e.g. resolving `TypeNamed "T"`
   to a concrete argument type while building one instantiation's
   field/param/return/body types. `None` (the common case, since only a
   template's own body ever contains an unbound parameter name) leaves
   TypeNamed nodes alone.

   `resolve_inst`: what to do with a (already-recursively-transformed)
   TypeGenericInst node. During collection this just records the request
   and returns the node unchanged; during the final rewrite pass it returns
   TypeNamed of the generated struct's mangled name. *)

let rec transform ~(subst : string -> type_expr option)
                  ~(resolve_inst : string -> type_expr list -> type_expr)
                  (t : type_expr) : type_expr =
  let go = transform ~subst ~resolve_inst in
  match t with
  | TypeNamed name -> (match subst name with Some t' -> t' | None -> t)
  | TypeGenericInst (name, args) -> resolve_inst name (List.map go args)
  | TypePtr t -> TypePtr (go t)
  | TypeIo t -> TypeIo (go t)
  | TypeArray (t, n) -> TypeArray (go t, n)
  | TypeSlice (t, n) -> TypeSlice (go t, n)
  | TypeFn (ps, r, eff) -> TypeFn (List.map go ps, go r, eff)
  | TypeTuple ts -> TypeTuple (List.map go ts)
  | TypeBorrow t -> TypeBorrow (go t)
  | TypeBorrowMut t -> TypeBorrowMut (go t)
  | TypeSink t -> TypeSink (go t)
  | TypeAlignedPtr (n, t) -> TypeAlignedPtr (n, go t)
  | TypeSingleton (t, arg) -> TypeSingleton (go t, arg)
  | TypeExists (n, sort, body) -> TypeExists (n, sort, go body)
  | TypeRefined (lo, hi, base) -> TypeRefined (lo, hi, go base)
  (* TypeIndexed's arguments are static_arg (erased values), not types --
     nothing under it can ever be a type parameter or a generic
     instantiation. TypeBool/int primitives/TypeVoid/TypeView/TypeVariant/
     TypeKind have no sub-type_expr at all. *)
  | TypeIndexed _ | TypeBool
  | TypeI8 | TypeI16 | TypeI32 | TypeI64
  | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeU16Be | TypeU32Be
  | TypeIsize | TypeUsize | TypeVoid
  | TypeView _ | TypeVariant _ | TypeKind -> t

let no_subst (_ : string) : type_expr option = None

(* -- plain (stateless) expr/stmt/func/toplevel walkers ---------------------

   Only Cast/SizeOf/OffsetOf (expr) and Let/For/LetMatch (stmt) carry a
   type_expr directly; everything else is pure structural recursion so a
   TypeGenericInst buried inside a deeply nested if/while/match still gets
   found and rewritten. Used for the final TypeGenericInst -> TypeNamed
   rewrite pass, where every call site's name has already been fixed up by
   the stateful call-resolving walk below. *)

let rec walk_expr ~subst ~resolve_inst (e : expr) : expr =
  let ty t = transform ~subst ~resolve_inst t in
  let ex e = walk_expr ~subst ~resolve_inst e in
  let desc = match e.desc with
    | IntLit _ | BoolLit _ | StringLit _ | Var _ | EnumVariant _ as d -> d
    | ViewLit (name, args) -> ViewLit (name, args)
    | Call (name, args) -> Call (name, List.map ex args)
    | VariantCtor (vname, cname, payload) -> VariantCtor (vname, cname, ex payload)
    | BinOp (op, a, b) -> BinOp (op, ex a, ex b)
    | Bnot a -> Bnot (ex a)
    | Deref a -> Deref (ex a)
    | AddrOf a -> AddrOf (ex a)
    | Cast (t, a) -> Cast (ty t, ex a)
    | FieldGet (a, f) -> FieldGet (ex a, f)
    | StructLit args -> StructLit (List.map ex args)
    | TupleLit args -> TupleLit (List.map ex args)
    | Index (id, idx) -> Index (id, ex idx)
    | SliceOf (id, lo, hi) -> SliceOf (id, ex lo, ex hi)
    | Unsafe a -> Unsafe (ex a)
    | SizeOf t -> SizeOf (ty t)
    | OffsetOf (t, f) -> OffsetOf (ty t, f)
    | Assign (l, r) -> Assign (ex l, ex r)
  in
  { e with desc }

let rec walk_stmt ~subst ~resolve_inst (s : stmt) : stmt =
  let ty t = transform ~subst ~resolve_inst t in
  let ex e = walk_expr ~subst ~resolve_inst e in
  let st s = walk_stmt ~subst ~resolve_inst s in
  let sts ss = List.map st ss in
  let desc = match s.desc with
    | Return None -> Return None
    | Return (Some e) -> Return (Some (ex e))
    | Expr e -> Expr (ex e)
    | Yield e -> Yield (ex e)
    | Block ss -> Block (sts ss)
    | Let (m, name, ty_opt, e_opt, align_opt) ->
        Let (m, name, Option.map ty ty_opt, Option.map ex e_opt, align_opt)
    | If (c, t, e) -> If (ex c, sts t, sts e)
    | While (c, b) -> While (ex c, sts b)
    | For (name, ty_opt, lo, hi, b) ->
        For (name, Option.map ty ty_opt, ex lo, ex hi, sts b)
    | ForEach (name, e, b) -> ForEach (name, ex e, sts b)
    | LetTuple (names, e) -> LetTuple (names, ex e)
    | Break -> Break
    | Continue -> Continue
    | Match (e, arms) -> Match (ex e, List.map (walk_arm ~subst ~resolve_inst) arms)
    | LetMatch (m, name, t_opt, e, arms) ->
        LetMatch (m, name, Option.map ty t_opt, ex e, List.map (walk_arm ~subst ~resolve_inst) arms)
  in
  { s with desc }

and walk_arm ~subst ~resolve_inst (a : match_arm) : match_arm =
  let sts ss = List.map (walk_stmt ~subst ~resolve_inst) ss in
  match a with
  | ArmVariant (v, c, b, ss) -> ArmVariant (v, c, b, sts ss)
  | ArmWild ss -> ArmWild (sts ss)
  | ArmIntLit (ns, ss) -> ArmIntLit (ns, sts ss)

let walk_func ~subst ~resolve_inst (f : func) : func =
  let ty t = transform ~subst ~resolve_inst t in
  { f with
    params = List.map (fun (n, t) -> (n, Option.map ty t)) f.params;
    ret_type = Option.map ty f.ret_type;
    body = List.map (walk_stmt ~subst ~resolve_inst) f.body }

let walk_toplevel ~subst ~resolve_inst (t : toplevel) : toplevel =
  let ty t = transform ~subst ~resolve_inst t in
  match t with
  | FuncDef f -> FuncDef (walk_func ~subst ~resolve_inst f)
  | ConstDef (n, t, e, l) -> ConstDef (n, ty t, e, l)
  | LetDef (n, t_opt, e_opt, a, m, p, l) ->
      LetDef (n, Option.map ty t_opt, e_opt, a, m, p, l)
  | ExternFuncDef (n, params, r, eff) ->
      ExternFuncDef (n, List.map (fun (pn, pt) -> (pn, Option.map ty pt)) params,
                     Option.map ty r, eff)
  | StructDef (n, fields, packed, align, priv, l) ->
      StructDef (n, List.map (fun (fn, ft) -> (fn, ty ft)) fields, packed, align, priv, l)
  | OwnedStructDef (n, k, sps, fields, packed, align, priv, is_priv, l) ->
      OwnedStructDef (n, k, sps, List.map (fun (fn, ft) -> (fn, ty ft)) fields,
                       packed, align, priv, is_priv, l)
  | ViewDef _ | OpaqueStructDef _ | UseDef _ -> t
  | EnumDef (n, base, vs, ne) -> EnumDef (n, Option.map ty base, vs, ne)
  | VariantDef (n, cases, mu, l) ->
      VariantDef (n, List.map (fun (cn, pt) -> (cn, Option.map ty pt)) cases, mu, l)
  | GenericStructDef _ -> t
      (* Handled separately by `run` below (extracted as a template, then
         stripped from the emitted program) -- never walked in place, since
         its own fields reference an unbound type parameter, not a real
         type. *)

(* -- Instantiation naming ----------------------------------------------------

   `mangle_arg`/`mangle`: symbol-safe naming for one concrete instantiation.
   `$` is outside the lexer's IDENT character class (confirmed in
   lib/lexer.mll), so it can never collide with a user-written identifier,
   and LLVM/ARM symbol conventions already permit it (see the approved
   generics plan). V1 only supports primitive/named-struct type arguments;
   anything else is rejected with a clear error rather than silently
   producing a colliding or unreadable mangled name. *)

let rec mangle_arg (t : type_expr) : string =
  match t with
  | TypeNamed s -> s
  | TypeBool -> "bool"
  | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32" | TypeI64 -> "i64"
  | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32" | TypeU64 -> "u64"
  | TypeU16Be -> "u16be" | TypeU32Be -> "u32be"
  | TypeIsize -> "isize" | TypeUsize -> "usize"
  | TypePtr t -> "ptr_" ^ mangle_arg t
  | _ -> raise (Types.TypeError (Lexing.dummy_pos,
      "a generic type argument is not supported yet (only primitive \
       integer types, bool, plain struct names, and plain pointers to \
       those are -- GitHub issue #207)"))

let mangle (name : string) (args : type_expr list) : string =
  name ^ String.concat "" (List.map (fun a -> "$" ^ mangle_arg a) args)

(* -- struct templates -------------------------------------------------------- *)

type struct_template = {
  st_type_params : string list;
  st_fields : (string * type_expr) list;
  st_is_packed : bool;
  st_align_opt : int option;
  st_private_fields : string list;
}

(* -- function templates ------------------------------------------------------

   A generic function is an ordinary `fn` with one or more `T: type`
   parameters, in any position -- no dedicated toplevel grammar was needed
   (unlike `generic struct`) since `type` is just another base_type_expr.
   `fn_type_params` collects the TypeKind-typed parameter names in their own
   relative order; `fn_value_params` is everything else, in ITS relative
   order -- these are the parameters an actual call site supplies (a type
   parameter is never written at a call site, only inferred). *)

type fn_template = {
  fn_type_params : string list;
  fn_value_params : (string * type_expr) list;
  fn_ret_type : type_expr option;
  fn_effects : ident list option;
  fn_body : stmt list;
  fn_is_inline : bool;
  fn_def_loc : loc;
}

let split_fn_params (params : (ident * type_expr option) list)
    : (string list * (string * type_expr) list) option =
  let is_type_param = List.exists (fun (_, t) -> t = Some TypeKind) params in
  if not is_type_param then None
  else
    let type_params = List.filter_map (fun (n, t) ->
      if t = Some TypeKind then Some n else None) params in
    let value_params = List.filter_map (fun (n, t) ->
      match t with
      | Some TypeKind -> None
      | Some t -> Some (n, t)
      | None -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
          "generic function parameter '%s' needs an explicit type \
           annotation (GitHub issue #207)" n))
    ) params in
    Some (type_params, value_params)

(* -- narrow type-argument inference ------------------------------------------

   Deliberately weak by design (see this file's header comment and the
   approved generics plan): only a bare `Var name` or `&name` argument
   participates, and only when `name`'s type is already known from a
   syntactically local, explicit annotation. Unifying the derived concrete
   type against the template's declared (possibly type-parameter-
   referencing) parameter type is a structural walk that binds a type
   parameter wherever it appears and simply contributes nothing on a
   structural mismatch (a real type mismatch is type_inf.ml's job to catch
   on the resolved call, not this pass's). *)

let derive_arg_type (local_types : (string, type_expr) Hashtbl.t) (e : expr)
    : type_expr option =
  match e.desc with
  | Var name -> Hashtbl.find_opt local_types name
  | AddrOf { desc = Var name; _ } ->
      Option.map (fun t -> TypePtr t) (Hashtbl.find_opt local_types name)
  | _ -> None

let rec unify_arg (type_params : string list)
                  (bindings : (string, type_expr) Hashtbl.t)
                  (template_ty : type_expr) (concrete_ty : type_expr) : unit =
  let u = unify_arg type_params bindings in
  match template_ty, concrete_ty with
  | TypeNamed n, _ when List.mem n type_params ->
      (match Hashtbl.find_opt bindings n with
       | Some existing when existing <> concrete_ty ->
           raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
             "conflicting inference for generic type parameter '%s'" n))
       | _ -> Hashtbl.replace bindings n concrete_ty)
  | TypePtr a, TypePtr b -> u a b
  | TypeIo a, TypeIo b -> u a b
  | TypeBorrow a, b | TypeBorrowMut a, b | TypeSink a, b -> u a b
  | a, TypeBorrow b | a, TypeBorrowMut b | a, TypeSink b -> u a b
  | TypeArray (a, _), TypeArray (b, _) -> u a b
  | TypeSlice (a, _), TypeSlice (b, _) -> u a b
  | TypeAlignedPtr (_, a), TypeAlignedPtr (_, b) -> u a b
  | TypeGenericInst (n1, args1), TypeGenericInst (n2, args2)
    when n1 = n2 && List.length args1 = List.length args2 ->
      List.iter2 u args1 args2
  | _ -> () (* structural mismatch: contributes nothing, not an error here *)

(* -- run ---------------------------------------------------------------------

   Order of operations:
   1. Collect struct and function templates; seed a global symbol table
      (explicit-type globals/consts only) for narrow inference to consult.
   2. Discover struct-instantiation requests from the non-template part of
      the program (TypeGenericInst occurrences).
   3. Discover and resolve generic-function calls in the SAME non-template
      code, tracking local types per function as it walks statement order;
      each resolved call is rewritten to its mangled name immediately
      (inference completes synchronously per call site), and substituting
      the template's own params/ret/body can introduce NEW struct requests,
      fed back into the same request table.
   4. Fixpoint-expand every struct request (a generated struct's fields can
      themselves introduce further nested requests).
   5. Finalize: register every generated struct with Type_layout and fully
      resolve every generated function's substituted types against the now-
      complete request table.
   6. Rewrite the remaining (non-template) program's own TypeGenericInst
      occurrences (call names were already fixed in step 3). *)

let run (prog : toplevel list) : toplevel list =
  let struct_templates : (string, struct_template) Hashtbl.t = Hashtbl.create 8 in
  let fn_templates : (string, fn_template) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | GenericStructDef (name, tps, fields, packed, align, priv, _loc) ->
        if Hashtbl.mem struct_templates name then
          raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
            "'%s' is already defined as a generic struct" name));
        Hashtbl.replace struct_templates name
          { st_type_params = tps; st_fields = fields; st_is_packed = packed;
            st_align_opt = align; st_private_fields = priv }
    | FuncDef f ->
        (match split_fn_params f.params with
         | None -> ()
         | Some (type_params, value_params) ->
             if Hashtbl.mem fn_templates f.name then
               raise (Types.TypeError (f.def_loc, Printf.sprintf
                 "'%s' is already defined as a generic function" f.name));
             Hashtbl.replace fn_templates f.name
               { fn_type_params = type_params; fn_value_params = value_params;
                 fn_ret_type = f.ret_type; fn_effects = f.effects;
                 fn_body = f.body; fn_is_inline = f.is_inline;
                 fn_def_loc = f.def_loc })
    | _ -> ()
  ) prog;
  if Hashtbl.length struct_templates = 0 && Hashtbl.length fn_templates = 0
  then prog else begin
    (* struct_requests: mangled name -> (template name, concrete args),
       every distinct struct instantiation actually referenced anywhere
       (including inside a generated struct's or function's own body). *)
    let struct_requests : (string, string * type_expr list) Hashtbl.t = Hashtbl.create 8 in
    let collect_resolve name args =
      let mangled = mangle name args in
      if not (Hashtbl.mem struct_requests mangled) then
        Hashtbl.replace struct_requests mangled (name, args);
      TypeGenericInst (name, args)
    in

    (* Global symbol table for narrow inference: explicit-type globals and
       consts only (an inferred-from-initializer global is out of scope for
       this deliberately weak V1 rule). *)
    let global_types : (string, type_expr) Hashtbl.t = Hashtbl.create 16 in
    List.iter (function
      | ConstDef (n, t, _, _) -> Hashtbl.replace global_types n t
      | LetDef (n, Some t, _, _, _, _, _) -> Hashtbl.replace global_types n t
      | _ -> ()
    ) prog;

    (* fn_requests: mangled name -> (template name, concrete type args). *)
    let fn_requests : (string, string * type_expr list) Hashtbl.t = Hashtbl.create 8 in

    let resolve_call (local_types : (string, type_expr) Hashtbl.t)
        (name : string) (args : expr list) : string option =
      match Hashtbl.find_opt fn_templates name with
      | None -> None
      | Some tpl when List.length tpl.fn_value_params <> List.length args -> None
      | Some tpl ->
          let bindings = Hashtbl.create 4 in
          List.iter2 (fun (_, template_ty) arg ->
            match derive_arg_type local_types arg with
            | Some concrete_ty -> unify_arg tpl.fn_type_params bindings template_ty concrete_ty
            | None -> ()
          ) tpl.fn_value_params args;
          let concrete_args = List.map (fun tp ->
            match Hashtbl.find_opt bindings tp with
            | Some t -> t
            | None -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                "cannot infer type parameter '%s' for call to '%s' -- every \
                 argument whose declared type would determine it must be a \
                 plain local variable or global (or its address) with an \
                 explicit type already known at this point in the program \
                 (GitHub issue #207)" tp name))
          ) tpl.fn_type_params in
          let mangled = mangle name concrete_args in
          if not (Hashtbl.mem fn_requests mangled) then
            Hashtbl.replace fn_requests mangled (name, concrete_args);
          Some mangled
    in

    (* Stateful walk: identical shape to walk_expr/walk_stmt above, except
       it also resolves generic-function calls (mutating local_types as it
       crosses each Let/For in program order) and feeds struct-instantiation
       discovery through collect_resolve for every type_expr it touches. *)
    let rec walk_expr_calls local_types (e : expr) : expr =
      let ty t = transform ~subst:no_subst ~resolve_inst:collect_resolve t in
      let ex e = walk_expr_calls local_types e in
      let desc = match e.desc with
        | IntLit _ | BoolLit _ | StringLit _ | Var _ | EnumVariant _ as d -> d
        | ViewLit (name, args) -> ViewLit (name, args)
        | Call (name, args) ->
            let args = List.map ex args in
            (match resolve_call local_types name args with
             | Some mangled -> Call (mangled, args)
             | None -> Call (name, args))
        | VariantCtor (vname, cname, payload) -> VariantCtor (vname, cname, ex payload)
        | BinOp (op, a, b) -> BinOp (op, ex a, ex b)
        | Bnot a -> Bnot (ex a)
        | Deref a -> Deref (ex a)
        | AddrOf a -> AddrOf (ex a)
        | Cast (t, a) -> Cast (ty t, ex a)
        | FieldGet (a, f) -> FieldGet (ex a, f)
        | StructLit args -> StructLit (List.map ex args)
        | TupleLit args -> TupleLit (List.map ex args)
        | Index (id, idx) -> Index (id, ex idx)
        | SliceOf (id, lo, hi) -> SliceOf (id, ex lo, ex hi)
        | Unsafe a -> Unsafe (ex a)
        | SizeOf t -> SizeOf (ty t)
        | OffsetOf (t, f) -> OffsetOf (ty t, f)
        | Assign (l, r) -> Assign (ex l, ex r)
      in
      { e with desc }
    in
    let rec walk_stmt_calls local_types (s : stmt) : stmt =
      let ty t = transform ~subst:no_subst ~resolve_inst:collect_resolve t in
      let ex e = walk_expr_calls local_types e in
      let st s = walk_stmt_calls local_types s in
      let sts ss = List.map st ss in
      let desc = match s.desc with
        | Return None -> Return None
        | Return (Some e) -> Return (Some (ex e))
        | Expr e -> Expr (ex e)
        | Yield e -> Yield (ex e)
        | Block ss -> Block (sts ss)
        | Let (m, name, ty_opt, e_opt, align_opt) ->
            let ty_opt = Option.map ty ty_opt in
            let e_opt = Option.map ex e_opt in
            (match ty_opt with
             | Some t -> Hashtbl.replace local_types name t
             | None -> Hashtbl.remove local_types name);
            Let (m, name, ty_opt, e_opt, align_opt)
        | If (c, t, e) -> If (ex c, sts t, sts e)
        | While (c, b) -> While (ex c, sts b)
        | For (name, ty_opt, lo, hi, b) ->
            let ty_opt = Option.map ty ty_opt in
            For (name, ty_opt, ex lo, ex hi, sts b)
        | ForEach (name, e, b) -> ForEach (name, ex e, sts b)
        | LetTuple (names, e) -> LetTuple (names, ex e)
        | Break -> Break
        | Continue -> Continue
        | Match (e, arms) -> Match (ex e, List.map (walk_arm_calls local_types) arms)
        | LetMatch (m, name, t_opt, e, arms) ->
            (* GitHub issue #207: when the annotation is omitted, this
               narrow (non-HM) forward tracker has no way to know the
               type type_inf.ml will later infer from the arms' Yield
               expressions, so -- exactly like an unannotated plain Let
               just above -- it stops tracking `name` here. If a LATER
               generic call in this same body needs `name` specifically
               to determine a type parameter, resolve_call's own existing
               "cannot infer type parameter" error fires (a clear compile
               error, not silent misresolution); it just cannot happen to
               be THIS mechanism that supplies it anymore. *)
            let t_opt = Option.map ty t_opt in
            (match t_opt with
             | Some t -> Hashtbl.replace local_types name t
             | None -> Hashtbl.remove local_types name);
            LetMatch (m, name, t_opt, ex e, List.map (walk_arm_calls local_types) arms)
      in
      { s with desc }
    and walk_arm_calls local_types (a : match_arm) : match_arm =
      let sts ss = List.map (walk_stmt_calls local_types) ss in
      match a with
      | ArmVariant (v, c, b, ss) -> ArmVariant (v, c, b, sts ss)
      | ArmWild ss -> ArmWild (sts ss)
      | ArmIntLit (ns, ss) -> ArmIntLit (ns, sts ss)
    in
    let walk_func_calls (f : func) : func =
      let ty t = transform ~subst:no_subst ~resolve_inst:collect_resolve t in
      let local_types = Hashtbl.copy global_types in
      List.iter (fun (n, t) -> match t with
        | Some t -> Hashtbl.replace local_types n t
        | None -> ()) f.params;
      { f with
        params = List.map (fun (n, t) -> (n, Option.map ty t)) f.params;
        ret_type = Option.map ty f.ret_type;
        body = List.map (walk_stmt_calls local_types) f.body }
    in
    let walk_toplevel_calls (t : toplevel) : toplevel =
      let ty t = transform ~subst:no_subst ~resolve_inst:collect_resolve t in
      match t with
      | FuncDef f -> FuncDef (walk_func_calls f)
      | ConstDef (n, t, e, l) -> ConstDef (n, ty t, e, l)
      | LetDef (n, t_opt, e_opt, a, m, p, l) ->
          LetDef (n, Option.map ty t_opt, e_opt, a, m, p, l)
      | ExternFuncDef (n, params, r, eff) ->
          ExternFuncDef (n, List.map (fun (pn, pt) -> (pn, Option.map ty pt)) params,
                         Option.map ty r, eff)
      | StructDef (n, fields, packed, align, priv, l) ->
          StructDef (n, List.map (fun (fn, ft) -> (fn, ty ft)) fields, packed, align, priv, l)
      | OwnedStructDef (n, k, sps, fields, packed, align, priv, is_priv, l) ->
          OwnedStructDef (n, k, sps, List.map (fun (fn, ft) -> (fn, ty ft)) fields,
                           packed, align, priv, is_priv, l)
      | ViewDef _ | OpaqueStructDef _ | UseDef _ -> t
      | EnumDef (n, base, vs, ne) -> EnumDef (n, Option.map ty base, vs, ne)
      | VariantDef (n, cases, mu, l) ->
          VariantDef (n, List.map (fun (cn, pt) -> (cn, Option.map ty pt)) cases, mu, l)
      | GenericStructDef _ -> t
    in

    (* Walk every ordinary (non-template) toplevel for calls, positionally
       aligned with `prog` (None for a template item, which is never
       walked directly -- V1 scope does not follow a generic function
       template's OWN body for calls to further generic functions, see
       this file's header). This also performs struct-request discovery
       simultaneously (every type_expr it touches goes through
       collect_resolve). Positional alignment (rather than filtering
       templates out first) is what lets the final assembly below insert
       each template's generated instantiations at the template's OWN
       original position instead of an arbitrary fixed spot -- see that
       comment for why position matters. *)
    let is_template = function
      | GenericStructDef _ -> true
      | FuncDef f -> split_fn_params f.params <> None
      | _ -> false
    in
    let item_calls_processed = List.map (fun item ->
      if is_template item then None else Some (walk_toplevel_calls item)
    ) prog in

    (* Expand every pending function-instantiation request into a
       substituted (but not yet fully TypeGenericInst-free) FuncDef,
       feeding any struct requests the substitution introduces back into
       struct_requests via collect_resolve. New fn_requests cannot appear
       from this step in V1 scope (see header), so one pass suffices.
       Keeps the originating template name alongside each entry so the
       final assembly can group generated functions by which template
       produced them. *)
    let raw_fns : (string, string * fn_template * (ident * type_expr) list * type_expr option * stmt list) Hashtbl.t
      = Hashtbl.create 8 in
    Hashtbl.iter (fun mangled (name, args) ->
      match Hashtbl.find_opt fn_templates name with
      | None -> () (* not a known generic function; left for type_inf.ml *)
      | Some tpl ->
          if List.length tpl.fn_type_params <> List.length args then
            raise (Types.TypeError (tpl.fn_def_loc, Printf.sprintf
              "generic function '%s' expects %d type argument(s), got %d"
              name (List.length tpl.fn_type_params) (List.length args)));
          let mapping = List.combine tpl.fn_type_params args in
          let subst n = List.assoc_opt n mapping in
          let ty t = transform ~subst ~resolve_inst:collect_resolve t in
          let params = List.map (fun (n, t) -> (n, ty t)) tpl.fn_value_params in
          let ret_type = Option.map ty tpl.fn_ret_type in
          let body = List.map (walk_stmt ~subst ~resolve_inst:collect_resolve) tpl.fn_body in
          Hashtbl.replace raw_fns mangled (name, tpl, params, ret_type, body)
    ) fn_requests;

    (* Fixpoint: expanding one struct's field list (or, above, a function's
       params/ret/body) can introduce new TypeGenericInst occurrences (a
       nested instantiation), which must themselves be discovered before
       this pass can finish. raw_fields holds each struct instantiation's
       substituted-but-not-yet-fully-resolved field list until every
       request is known, since Type_layout needs fully concrete field
       types, not a half-resolved intermediate. Also keeps the originating
       template name, same reason as raw_fns above. *)
    let raw_fields : (string, string * struct_template * type_expr list) Hashtbl.t = Hashtbl.create 8 in
    let rec expand_pending () =
      let pending = Hashtbl.fold (fun mangled req acc ->
        if Hashtbl.mem raw_fields mangled then acc else (mangled, req) :: acc)
        struct_requests [] in
      if pending <> [] then begin
        List.iter (fun (mangled, (name, args)) ->
          match Hashtbl.find_opt struct_templates name with
          | None -> () (* not a known generic struct; left for type_inf.ml *)
          | Some tpl ->
              if List.length tpl.st_type_params <> List.length args then
                raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                  "generic struct '%s' expects %d type argument(s), got %d"
                  name (List.length tpl.st_type_params) (List.length args)));
              let mapping = List.combine tpl.st_type_params args in
              let subst n = List.assoc_opt n mapping in
              let substituted = List.map (fun (_, fty) ->
                transform ~subst ~resolve_inst:collect_resolve fty) tpl.st_fields in
              Hashtbl.replace raw_fields mangled (name, tpl, substituted)
        ) pending;
        expand_pending ()
      end
    in
    expand_pending ();

    (* Every request (struct and function) is now known, so TypeGenericInst
       -> TypeNamed resolution is total and stable. Register every
       generated struct with Type_layout (order-independent -- finish_struct
       only stores the field list for later lookup, per lib/type_layout.ml,
       it does not eagerly compute a size) and finish resolving every
       generated function's substituted types. Grouped by originating
       template name (rather than one flat list) so the final assembly can
       insert each template's instantiations at that template's own
       original position -- llvm_gen.ml's struct registration (`register_
       struct`/`register_struct_if`, lib/llvm_gen.ml ~4844-4877) walks
       `prog` in a SINGLE LINEAR PASS with no topological sort, calling
       `ltype_of_ast` on every field immediately: a struct embedding
       another struct by value must have that other struct's LLVM type
       already registered, so a generated struct placed before an ordinary
       struct it depends on (e.g. `Freelist(T)`'s `core: FreelistCore`
       field, with FreelistCore defined earlier in ordinary code) would
       fail with "Unknown named type" -- confirmed by hitting exactly that
       error before this positional-insertion design. Preserving each
       template's own textual position relies on the user already having
       written it in a sound dependency order relative to the ordinary
       structs it references, the same discipline ordinary (non-generic)
       struct definitions already require today. *)
    let apply_resolve name args = TypeNamed (mangle name args) in
    let resolve_ty t = transform ~subst:no_subst ~resolve_inst:apply_resolve t in

    let struct_by_template_name : (string, toplevel list) Hashtbl.t = Hashtbl.create 8 in
    Hashtbl.iter (fun mangled (name, tpl, raw) ->
      let field_names = List.map fst tpl.st_fields in
      let fields = List.combine field_names (List.map resolve_ty raw) in
      Type_layout.finish_struct mangled fields tpl.st_is_packed tpl.st_align_opt;
      let def = StructDef (mangled, fields, tpl.st_is_packed, tpl.st_align_opt,
                            tpl.st_private_fields, Lexing.dummy_pos) in
      let prev = Option.value (Hashtbl.find_opt struct_by_template_name name) ~default:[] in
      Hashtbl.replace struct_by_template_name name (def :: prev)
    ) raw_fields;

    let fn_by_template_name : (string, toplevel list) Hashtbl.t = Hashtbl.create 8 in
    Hashtbl.iter (fun mangled (name, tpl, params, ret_type, body) ->
      let params = List.map (fun (n, t) -> (n, Some (resolve_ty t))) params in
      let ret_type = Option.map resolve_ty ret_type in
      let body = List.map (walk_stmt ~subst:no_subst ~resolve_inst:apply_resolve) body in
      let def = FuncDef { name = mangled; params; ret_type; effects = tpl.fn_effects;
                          body; is_inline = tpl.fn_is_inline; def_loc = tpl.fn_def_loc } in
      let prev = Option.value (Hashtbl.find_opt fn_by_template_name name) ~default:[] in
      Hashtbl.replace fn_by_template_name name (def :: prev)
    ) raw_fns;

    List.concat (List.map2 (fun item processed -> match item with
      | GenericStructDef (name, _, _, _, _, _, _) ->
          Option.value (Hashtbl.find_opt struct_by_template_name name) ~default:[]
      | FuncDef f when is_template item ->
          Option.value (Hashtbl.find_opt fn_by_template_name f.name) ~default:[]
      | _ ->
          [walk_toplevel ~subst:no_subst ~resolve_inst:apply_resolve (Option.get processed)]
    ) prog item_calls_processed)
  end
