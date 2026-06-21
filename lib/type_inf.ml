open Types

(* Type environment: association list, innermost binding first *)
type tyenv = (string * ty) list

let lookup loc name env =
  match List.assoc_opt name env with
  | Some t -> t
  | None   -> raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" name))

let unify_at loc t1 t2 =
  try unify t1 t2
  with Unify_error msg -> raise (TypeError (loc, msg))

(* ── Expression inference ────────────────────────────────────────────────── *)

let rec infer_expr tyenv fenv (e : Ast.expr) : ty =
  match e.desc with
  | IntLit _ -> fresh ()  (* polymorphic: unifies with int or char via context *)
  | Var name -> lookup e.loc name tyenv
  | BinOp (op, e1, e2) ->
      let t1 = infer_expr tyenv fenv e1 in
      let t2 = infer_expr tyenv fenv e2 in
      (match op with
       | Add | Sub | Mul | Div ->
           unify_at e1.loc t1 TInt;
           unify_at e2.loc t2 TInt;
           TInt
       | Lt | Gt | Le | Ge | Eq | Ne ->
           (* both operands must have the same type *)
           unify_at e.loc t1 t2;
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
      (match List.assoc_opt fname fenv with
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
(* Returns the updated type environment (extended by Let bindings).
   local_types accumulates the resolved types of Let bindings for codegen. *)

let rec infer_stmt tyenv fenv ret_ty local_types (s : Ast.stmt) : tyenv =
  match s.desc with
  | Return e ->
      let t = infer_expr tyenv fenv e in
      unify_at e.loc t ret_ty;
      tyenv
  | Expr e ->
      ignore (infer_expr tyenv fenv e);
      tyenv
  | Assign (name, e) ->
      let vty = lookup s.loc name tyenv in
      let ety = infer_expr tyenv fenv e in
      unify_at e.loc vty ety;
      tyenv
  | AssignDeref (ptr_expr, val_expr) ->
      let inner = fresh () in
      let pt = infer_expr tyenv fenv ptr_expr in
      unify_at ptr_expr.loc pt (TPtr inner);
      let vt = infer_expr tyenv fenv val_expr in
      unify_at val_expr.loc vt inner;
      tyenv
  | Let (name, ty_opt, expr_opt) ->
      let ty = of_ast_opt ty_opt in
      (match expr_opt with
       | None -> ()
       | Some e ->
           let et = infer_expr tyenv fenv e in
           unify_at e.loc ty et);
      Hashtbl.replace local_types name ty;
      (name, ty) :: tyenv
  | Block stmts ->
      (* Inner block: bindings do not escape, but types are recorded *)
      ignore (List.fold_left
        (fun env s -> infer_stmt env fenv ret_ty local_types s) tyenv stmts);
      tyenv
  | If (cond, then_s, else_s) ->
      let ct = infer_expr tyenv fenv cond in
      unify_at cond.loc ct TInt;
      ignore (List.fold_left
        (fun env s -> infer_stmt env fenv ret_ty local_types s) tyenv then_s);
      ignore (List.fold_left
        (fun env s -> infer_stmt env fenv ret_ty local_types s) tyenv else_s);
      tyenv
  | While (cond, body) ->
      let ct = infer_expr tyenv fenv cond in
      unify_at cond.loc ct TInt;
      ignore (List.fold_left
        (fun env s -> infer_stmt env fenv ret_ty local_types s) tyenv body);
      tyenv

(* ── Function inference ──────────────────────────────────────────────────── *)

let infer_func fenv genv (fdef : Ast.func) : func_info =
  let param_tys = List.map (fun (_, ty_opt) -> of_ast_opt ty_opt) fdef.params in
  let ret_ty    = ret_of_ast_opt fdef.ret_type in
  let param_env = List.map2 (fun (name, _) ty -> (name, ty)) fdef.params param_tys in
  let init_env  = param_env @ genv in
  (* local_types collects the ty for each Let binding (resolved after inference) *)
  let raw_locals : (string, ty) Hashtbl.t = Hashtbl.create 8 in
  ignore (List.fold_left
    (fun env s -> infer_stmt env fenv ret_ty raw_locals s)
    init_env fdef.body);
  (* Resolve all types now that unification is complete *)
  let local_types = Hashtbl.create 8 in
  Hashtbl.iter (fun k v -> Hashtbl.replace local_types k (to_ast v)) raw_locals;
  {
    ret_type    = to_ast ret_ty;
    param_types = List.map2 (fun (name, _) ty -> (name, to_ast ty))
                    fdef.params param_tys;
    local_types;
  }

(* ── Whole-program inference ─────────────────────────────────────────────── *)

let infer_program (prog : Ast.toplevel list) : program_types =
  (* Pass 1: build function-type env and global-variable env *)
  let func_tbl : (string, ty) Hashtbl.t = Hashtbl.create 8 in
  let glob_tbl : (string, ty) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | Ast.FuncDef fdef ->
        let pts = List.map (fun (_, t) -> of_ast_opt t) fdef.params in
        let rt  = ret_of_ast_opt fdef.ret_type in
        Hashtbl.replace func_tbl fdef.name (TFun (pts, rt))
    | Ast.LetDef (name, ty_opt, _) ->
        Hashtbl.replace glob_tbl name (of_ast_opt ty_opt)
  ) prog;
  let fenv = Hashtbl.fold (fun k v a -> (k, v) :: a) func_tbl [] in
  let genv = Hashtbl.fold (fun k v a -> (k, v) :: a) glob_tbl [] in
  (* Pass 2: infer global initializers *)
  List.iter (function
    | Ast.LetDef (name, _, expr_opt) ->
        let ty = Hashtbl.find glob_tbl name in
        (match expr_opt with
         | None -> ()
         | Some e ->
             let et = infer_expr genv fenv e in
             (try unify ty et
              with Unify_error m -> raise (TypeError (e.loc, m))))
    | _ -> ()
  ) prog;
  (* Pass 3: infer function bodies *)
  let functions = Hashtbl.create 8 in
  List.iter (function
    | Ast.FuncDef fdef ->
        Hashtbl.replace functions fdef.name (infer_func fenv genv fdef)
    | _ -> ()
  ) prog;
  (* Resolve global types *)
  let globals = Hashtbl.create 8 in
  Hashtbl.iter (fun k v -> Hashtbl.replace globals k (to_ast v)) glob_tbl;
  { globals; functions }
