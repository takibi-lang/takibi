(* Source-backed tail-transfer candidates, not whole-function proofs.
   A reported transfer still requires the old prefix, chunk<=old count,
   non-wrap, and preservation across the earlier allocation/zeroing path. *)
module I = Types.IntMap
module M = Types.StringMap
type stored = { pool : int; table : string; index : int;
  origin : Address_extent.value; count : string option }
let run ~functions ~key_of ~target ~write_footprint ~address_extents prog =
  let summaries = ref M.empty in
  let inspect (f : Ast.func) (info : Types.func_info) =
    let bind e = Local_bindings.id_for_expr info.bindings e in
    let parameter e = Option.bind (bind e) (fun id ->
      if List.mem id info.bindings.param_ids then Some id else None) in
    let rec value locals (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Option.fold ~none:Address_extent.Unknown
          ~some:(fun id -> Option.value ~default:Address_extent.Unknown (I.find_opt id locals)) (bind e)
      | Ast.Call _ -> Option.fold ~none:Address_extent.Unknown
          ~some:(fun key -> Option.value ~default:Address_extent.Unknown (M.find_opt key address_extents)) (target e)
      | Ast.Unsafe e -> value locals e
      | _ -> Address_extent.Unknown in
    let rec pure (e : Ast.expr) = match e.desc with
      | Ast.Var _ | Ast.IntLit _ | Ast.BoolLit _ | Ast.EnumVariant _ -> true
      | Ast.FieldGet (e,_) | Ast.Unsafe e | Ast.Cast (_,e) -> pure e
      | Ast.BinOp (_,a,b) | Ast.Index (a,b) -> pure a && pure b
      | Ast.Call (_,args) -> List.for_all pure args &&
          (match write_footprint e with
           | Init_writes.Writes paths -> Init_writes.Paths.is_empty paths
           | _ -> false)
      | _ -> false in
    let rec body locals stored = function
      | [] -> ()
      | s::rest -> (match s.Ast.desc with
          | Ast.Let (false,_,_,Some e,_) ->
              let locals = match Local_bindings.ids_for_stmt info.bindings s with
                | [id] -> I.add id (value locals e) locals | _ -> locals in
              body locals (if pure e then stored else None) rest
          | Ast.Expr {desc = Ast.Assign (lhs,rhs); _} ->
              let next = match lhs.desc,rhs.desc with
                | Ast.Index ({desc = Ast.FieldGet (pool,table); _},index), _ ->
                    (match parameter pool, parameter index, value locals rhs with
                     | Some pool,Some index,(Address_extent.Address _ as origin) when pure rhs ->
                         Some {pool;table;index;origin;count=None}
                     | _,_,_ -> (match stored,parameter pool with
                         | Some prior,Some pool when pool=prior.pool && table<>prior.table && pure rhs -> stored
                         | _ -> None))
                | Ast.FieldGet (pool,count), Ast.BinOp (Ast.Add,index,{desc=Ast.IntLit 1L;_}) ->
                    (match stored,parameter pool,parameter index with
                     | Some prior,Some pool,Some index when prior.pool=pool && prior.index=index
                         && count<>prior.table -> Some {prior with count=Some count}
                     | _ -> None)
                | _ -> None in
              body locals next rest
          | Ast.Return (Some {desc=Ast.EnumVariant _;_}) ->
              (match stored with
               | Some ({origin=Address_extent.Address _;count=Some _;_} as summary) ->
                   summaries := M.add (key_of f) summary !summaries;
                   ()
               | _ -> ())
          | Ast.Match (_,arms) ->
              List.iter (fun arm -> body locals None (Control_flow.arm_body arm)) arms
          | Ast.StaticAssert _ -> body locals stored rest
          | Ast.For _ | Ast.While _ -> body I.empty None rest
          | Ast.Return _ -> ()
          | _ -> body I.empty None rest) in
    body I.empty None f.body in
  List.iter (function Ast.FuncDef f ->
    Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
  !summaries
