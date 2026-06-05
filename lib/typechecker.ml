open Ast

exception TypeError of Ast.loc * string

(* Function signature (parameter types and return type) *)
type func_sig = {
  params : (string * type_expr option) list;
  return_type : type_expr option;
}

(* Environment: function name => function signature *)
module FuncEnv = Map.Make(String)

type func_env = func_sig FuncEnv.t

(* Initially empty *)
let empty_env : func_env = FuncEnv.empty

(* Register a function definition in the environment *)
let add_func env (fdef: Ast.func) =
  let fsig = { params = fdef.params; return_type = fdef.ret_type } in
  FuncEnv.add fdef.name fsig env

(* Check expressions for function calls *)
let rec check_expr env (e : expr) =
  match e.desc with
  | IntLit _ -> ()
  | Var _ -> ()
  | BinOp (_, e1, e2) ->
    check_expr env e1;
    check_expr env e2
  | Call (fname, args) ->
    (* Check whether the function exists *)
    if not (FuncEnv.mem fname env) then
      raise (TypeError (e.loc, Printf.sprintf "Undefined function: %s" fname));
    (* Recursively check argument expressions *)
    List.iter (check_expr env) args

(* Check statements *)
let rec check_stmt env (s : stmt) =
  match s.desc with
  | Return e -> check_expr env e
  | Expr e -> check_expr env e
  | Assign (_name, e) -> check_expr env e
  | Let (_name, _ty_opt, expr_opt) ->
     (match expr_opt with
      | None -> ()
      | Some e -> check_expr env e)
  | Block stmts -> List.iter (check_stmt env) stmts
  | If (cond, then_stmts, else_stmts) ->
      check_expr env cond;
      List.iter (check_stmt env) then_stmts;
      List.iter (check_stmt env) else_stmts
  | While (cond, body) ->
      check_expr env cond;
      List.iter (check_stmt env) body

(* Check top-level items (function definitions + Let definitions) *)
let check_toplevels prog =
  (* First pass: register all function definitions in the environment *)
  let env =
    List.fold_left (fun env toplevel ->
      match toplevel with
      | FuncDef fdef -> add_func env fdef
      | LetDef (_name, _ty_opt, _expr_opt) -> env
    ) empty_env prog
  in
  (* Second pass: check function bodies and Let expressions *)
  List.iter (function
    | FuncDef fdef ->
        List.iter (check_stmt env) fdef.body
    | LetDef (_name, _ty_opt, expr_opt) ->
        (match expr_opt with
         | None -> ()
         | Some e -> check_expr env e)
  ) prog
