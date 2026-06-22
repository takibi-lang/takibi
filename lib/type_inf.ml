open Types

(* Type environment: immutable map from variable name to internal type *)
type tyenv = ty StringMap.t

let lookup loc name env =
  match StringMap.find_opt name env with
  | Some t -> t
  | None   -> raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" name))

let unify_at loc t1 t2 =
  try unify t1 t2
  with Unify_error msg -> raise (TypeError (loc, msg))

(* ── Expression inference ────────────────────────────────────────────────── *)

let rec infer_expr tyenv fenv (e : Ast.expr) : ty =
  match e.desc with
  | IntLit _    -> fresh ()  (* polymorphic: unifies with int or char via context *)
  | StringLit _ -> TPtr TChar
  | Var name -> lookup e.loc name tyenv
  | BinOp (op, e1, e2) ->
      let t1 = infer_expr tyenv fenv e1 in
      let t2 = infer_expr tyenv fenv e2 in
      (match op with
       | Add ->
           (* ポインタ算術: ptr + int → 同じポインタ型を返す *)
           (match repr t1, repr t2 with
            | TPtr _, _ -> t1
            | _, TPtr _ -> t2
            | _ ->
                unify_at e1.loc t1 TInt;
                unify_at e2.loc t2 TInt;
                TInt)
       | Sub | Mul | Div ->
           unify_at e1.loc t1 TInt;
           unify_at e2.loc t2 TInt;
           TInt
       | Lt | Gt | Le | Ge | Eq | Ne ->
           unify_at e.loc t1 t2;
           TInt
       | Or ->
           unify_at e1.loc t1 TInt;
           unify_at e2.loc t2 TInt;
           TInt)
  | Deref e1 ->
      let inner = fresh () in
      let t1 = infer_expr tyenv fenv e1 in
      unify_at e1.loc t1 (TPtr inner);
      inner
  | AddrOf name ->
      let t = lookup e.loc name tyenv in
      TPtr t
  | Call (fname, args) ->
      (match StringMap.find_opt fname fenv with
       | None ->
           raise (TypeError (e.loc,
             Printf.sprintf "Undefined function: %s" fname))
       | Some ft ->
           let (param_tys, ret_ty) = match repr ft with
             | TFun (ps, r) -> (ps, r)
             | _ -> assert false
           in
           if List.length args <> List.length param_tys then
             raise (TypeError (e.loc,
               Printf.sprintf "%s expects %d argument(s), got %d"
                 fname (List.length param_tys) (List.length args)));
           List.iter2 (fun arg pt ->
             let at = infer_expr tyenv fenv arg in
             unify_at arg.loc at pt
           ) args param_tys;
           ret_ty)

(* ── Statement inference ─────────────────────────────────────────────────── *)
(* Returns (updated_tyenv, updated_raw_locals).
   tyenv grows with each Let in the current scope.
   raw_locals accumulates every Let type seen (including inside blocks/if/while)
   so that codegen can pre-allocate all locals at function entry. *)

let rec infer_stmt tyenv fenv ret_ty raw_locals (s : Ast.stmt)
    : tyenv * ty StringMap.t =
  match s.desc with
  | Return e ->
      let t = infer_expr tyenv fenv e in
      unify_at e.loc t ret_ty;
      (tyenv, raw_locals)
  | Expr e ->
      ignore (infer_expr tyenv fenv e);
      (tyenv, raw_locals)
  | Assign (name, e) ->
      let vty = lookup s.loc name tyenv in
      let ety = infer_expr tyenv fenv e in
      unify_at e.loc vty ety;
      (tyenv, raw_locals)
  | AssignDeref (ptr_expr, val_expr) ->
      let inner = fresh () in
      let pt = infer_expr tyenv fenv ptr_expr in
      unify_at ptr_expr.loc pt (TPtr inner);
      let vt = infer_expr tyenv fenv val_expr in
      unify_at val_expr.loc vt inner;
      (tyenv, raw_locals)
  | Let (name, ty_opt, expr_opt) ->
      let ty = of_ast_opt ty_opt in
      (match expr_opt with
       | None -> ()
       | Some e ->
           let et = infer_expr tyenv fenv e in
           unify_at e.loc ty et);
      ( StringMap.add name ty tyenv,
        StringMap.add name ty raw_locals )
  | Block stmts ->
      (* Let bindings extend the inner env but do not escape the block *)
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt env fenv ret_ty locs s)
        (tyenv, raw_locals) stmts
      in
      (tyenv, raw_locals')
  | If (cond, then_s, else_s) ->
      let ct = infer_expr tyenv fenv cond in
      unify_at cond.loc ct TInt;
      let (_, rl1) = List.fold_left
        (fun (env, locs) s -> infer_stmt env fenv ret_ty locs s)
        (tyenv, raw_locals) then_s
      in
      let (_, rl2) = List.fold_left
        (fun (env, locs) s -> infer_stmt env fenv ret_ty locs s)
        (tyenv, rl1) else_s
      in
      (tyenv, rl2)
  | While (cond, body) ->
      let ct = infer_expr tyenv fenv cond in
      unify_at cond.loc ct TInt;
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt env fenv ret_ty locs s)
        (tyenv, raw_locals) body
      in
      (tyenv, raw_locals')

(* ── Function inference ──────────────────────────────────────────────────── *)

let infer_func fenv genv (fdef : Ast.func) : func_info =
  let param_tys = List.map (fun (_, ty_opt) -> of_ast_opt ty_opt) fdef.params in
  let ret_ty    = ret_of_ast_opt fdef.ret_type in
  (* Start with globals visible, then shadow them with params *)
  let init_env  = List.fold_left2
    (fun m (name, _) ty -> StringMap.add name ty m)
    genv fdef.params param_tys
  in
  let (_, raw_locals) = List.fold_left
    (fun (env, locs) s -> infer_stmt env fenv ret_ty locs s)
    (init_env, StringMap.empty) fdef.body
  in
  {
    ret_type    = to_ast ret_ty;
    param_types = List.map2 (fun (name, _) ty -> (name, to_ast ty))
                    fdef.params param_tys;
    local_types = StringMap.map to_ast raw_locals;
  }

(* ── Whole-program inference ─────────────────────────────────────────────── *)

let infer_program (prog : Ast.toplevel list) : program_types =
  (* Pass 1: collect function signatures and global variable types *)
  let fenv = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        let pts = List.map (fun (_, t) -> of_ast_opt t) fdef.params in
        let rt  = ret_of_ast_opt fdef.ret_type in
        StringMap.add fdef.name (TFun (pts, rt)) m
    | Ast.LetDef _ -> m
  ) StringMap.empty prog in
  let genv = List.fold_left (fun m -> function
    | Ast.LetDef (name, ty_opt, _) -> StringMap.add name (of_ast_opt ty_opt) m
    | Ast.FuncDef _                -> m
  ) StringMap.empty prog in
  (* Pass 2: check global initializers *)
  List.iter (function
    | Ast.LetDef (name, _, expr_opt) ->
        let ty = StringMap.find name genv in
        (match expr_opt with
         | None -> ()
         | Some e ->
             let et = infer_expr genv fenv e in
             (try unify ty et
              with Unify_error m -> raise (TypeError (e.loc, m))))
    | _ -> ()
  ) prog;
  (* Pass 3: infer function bodies *)
  let functions = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        StringMap.add fdef.name (infer_func fenv genv fdef) m
    | _ -> m
  ) StringMap.empty prog in
  {
    globals   = StringMap.map to_ast genv;
    functions;
  }
