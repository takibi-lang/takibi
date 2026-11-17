(* Empty-prefix normal-return evidence. A final count=0 needs no initialized
   entries, but an earlier return must not bypass it. No origin is minted. *)
module M = Types.StringMap
let run ~functions ~key_of ~growth_transfers prog =
  let summaries = ref M.empty in
  let counts = M.fold (fun _ summary xs -> match summary.Growth_transfer.count with
    | Some n -> n::xs | None -> xs) growth_transfers [] in
  let rec no_return (s : Ast.stmt) = match s.desc with
    | Ast.Return _ -> false
    | Ast.Block ss | Ast.UnsafeBlock ss | Ast.For (_,_,_,_,ss)
    | Ast.While (_,ss) | Ast.ForEach (_,_,ss) -> List.for_all no_return ss
    | Ast.If (_,a,b) -> List.for_all no_return a && List.for_all no_return b
    | Ast.Match (_,arms) | Ast.LetMatch (_,_,_,_,arms) ->
        List.for_all (fun arm -> List.for_all no_return (Control_flow.arm_body arm)) arms
    | _ -> true in
  List.iter (function Ast.FuncDef f ->
    (match M.find_opt (key_of f) functions,List.rev f.Ast.body with
     | Some info, {Ast.desc=Ast.Expr {desc=Ast.Assign
         ({desc=Ast.FieldGet (pool,count);_},{desc=Ast.IntLit 0L;_});_};_}::prefix
         when List.mem count counts && List.for_all no_return prefix ->
         (match pool.desc,Local_bindings.id_for_expr info.Types.bindings pool with
          | Ast.Var _,Some id when List.mem id info.bindings.param_ids ->
              let rec position n = function
                | [] -> assert false | x::xs -> if x=id then n else position (n+1) xs in
              summaries := M.add (key_of f) (position 0 info.bindings.param_ids,count) !summaries;
              ()
          | _ -> ())
     | _ -> ())
    | _ -> ()) prog;
  !summaries
