module StringMap = Map.Make (String)

type id = int

module Expr_table = Hashtbl.Make (struct
  type t = Ast.expr
  let equal a b = a == b
  let hash = Hashtbl.hash
end)

module Stmt_table = Hashtbl.Make (struct
  type t = Ast.stmt
  let equal a b = a == b
  let hash = Hashtbl.hash
end)

type resolution = {
  param_ids : id list;
  stmt_ids : id list Stmt_table.t;
  arm_ids : ((Ast.loc * int), id) Hashtbl.t;
  expr_ids : id Expr_table.t;
}

let resolve_func (fdef : Ast.func) : resolution =
  let next = ref 0 in
  let fresh () = let id = !next in incr next; id in
  let stmt_ids = Stmt_table.create 32 in
  let arm_ids = Hashtbl.create 16 in
  let expr_ids = Expr_table.create 64 in
  let bind env name id = StringMap.add name id env in
  let record_ref env (e : Ast.expr) name =
    match StringMap.find_opt name env with
    | Some id -> Expr_table.replace expr_ids e id
    | None -> ()
  in
  let rec expr env (e : Ast.expr) =
    match e.desc with
    | Ast.Var name -> record_ref env e name
    | Ast.Call (name, args) ->
        record_ref env e name;
        List.iter (expr env) args
    | Ast.VariantCtor (_, _, payload) | Ast.Bnot payload | Ast.Deref payload
    | Ast.AddrOf payload | Ast.Cast (_, payload) | Ast.FieldGet (payload, _)
    | Ast.Unsafe payload -> expr env payload
    | Ast.BinOp (_, left, right) | Ast.Index (left, right)
    | Ast.Assign (left, right) -> expr env left; expr env right
    | Ast.SliceOf (base, lo, hi) ->
        expr env base; expr env lo; expr env hi
    | Ast.StructLit fields | Ast.TupleLit fields -> List.iter (expr env) fields
    | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.ByteSliceLit _
    | Ast.ViewLit _
    | Ast.EnumVariant _ | Ast.SizeOf _ | Ast.ContainsStableOwner _
    | Ast.AlignOf _ | Ast.OffsetOf _ | Ast.EmbedFile _ -> ()
  in
  let rec stmt_list env stmts = List.fold_left stmt env stmts
  and scoped env stmts = ignore (stmt_list env stmts)
  and arms env match_loc arms =
    List.iteri (fun index arm ->
      match arm with
      | Ast.ArmVariant (_, _, binding, body) ->
          let arm_env = match binding with
            | None -> env
            | Some (name, _) ->
                let id = fresh () in
                Hashtbl.add arm_ids (match_loc, index) id;
                bind env name id
          in
          scoped arm_env body
      | Ast.ArmWild body | Ast.ArmIntLit (_, body)
      | Ast.ArmByteSliceLit (_, body) -> scoped env body
    ) arms
  and stmt env (s : Ast.stmt) =
    match s.desc with
    | Ast.Return value -> Option.iter (expr env) value; env
    | Ast.Expr value | Ast.Yield value -> expr env value; env
    | Ast.Block body | Ast.UnsafeBlock body -> scoped env body; env
    | Ast.Let (_, name, _, init, _) ->
        Option.iter (expr env) init;
        let id = fresh () in
        Stmt_table.add stmt_ids s [id];
        bind env name id
    | Ast.LetTuple (names, rhs) ->
        expr env rhs;
        let ids = List.map (fun _ -> fresh ()) names in
        Stmt_table.add stmt_ids s ids;
        List.fold_left2 bind env names ids
    | Ast.If (cond, yes, no) ->
        expr env cond; scoped env yes; scoped env no; env
    | Ast.While (cond, body) -> expr env cond; scoped env body; env
    | Ast.For (name, _, lo, hi, body) ->
        expr env lo; expr env hi;
        let counter_id = fresh () in
        let binder_id = fresh () in
        Stmt_table.add stmt_ids s [counter_id; binder_id];
        scoped (bind env name binder_id) body;
        env
    | Ast.ForEach (name, sequence, body) ->
        expr env sequence;
        let counter_id = fresh () in
        let binder_id = fresh () in
        Stmt_table.add stmt_ids s [counter_id; binder_id];
        scoped (bind env name binder_id) body;
        env
    | Ast.Match (disc, match_arms) ->
        expr env disc; arms env s.loc match_arms; env
    | Ast.LetMatch (_, name, _, disc, match_arms) ->
        expr env disc;
        let id = fresh () in
        Stmt_table.add stmt_ids s [id];
        let env = bind env name id in
        arms env s.loc match_arms;
        env
    | Ast.Break | Ast.Continue -> env
    | Ast.StaticAssert (cond, _) -> expr env cond; env
  in
  let param_ids = List.map (fun _ -> fresh ()) fdef.params in
  let initial = List.fold_left2 (fun env (name, _) id -> bind env name id)
      StringMap.empty fdef.params param_ids in
  ignore (stmt_list initial fdef.body);
  { param_ids; stmt_ids; arm_ids; expr_ids }

let ids_for_stmt resolution stmt =
  match Stmt_table.find_opt resolution.stmt_ids stmt with
  | Some ids -> ids
  | None -> []

let id_for_arm resolution loc index =
  Hashtbl.find_opt resolution.arm_ids (loc, index)

let id_for_expr resolution expr =
  Expr_table.find_opt resolution.expr_ids expr
