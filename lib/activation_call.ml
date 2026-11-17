(* Conditional source composition at the activation call, not an entry-state
   certificate. Unknown intervening statements prevent the match. *)
module M = Types.StringMap
let run ~functions ~key_of ~target ~growth_bodies ~activation_summaries prog =
 let calls=Local_bindings.Expr_table.create 8 in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let id e = Local_bindings.id_for_expr info.bindings e in
  let same a b = match id a,id b with Some a,Some b -> a=b | _ -> false in
  let position ids wanted =
   let rec find n = function [] -> None | x::xs -> if x=wanted then Some n else find (n+1) xs in
   find 0 ids in
  let literal (e:Ast.expr) = match e.desc with Ast.IntLit n -> Some n | _ -> None in
  let rec scan ss =
   (match ss with
    | ({Ast.desc=Ast.Let (false,_,_,Some {desc=Ast.FieldGet (pool,count);_},_);_} as capture)::
      {desc=Ast.If ({desc=Ast.BinOp (Ast.Ge,chunk,limit);_},
        [{desc=Ast.Return (Some {desc=Ast.EnumVariant _;_});_}],[]);_}::
      {desc=Ast.Match (({desc=Ast.Call (_,grow_args);_} as grow),arms);_}::
      {desc=Ast.Expr ({desc=Ast.Call (_,activate_args);_} as activate);_}::_ ->
       let captured = match Local_bindings.ids_for_stmt info.bindings capture with
        | [i] -> id chunk=Some i | _ -> false in
       let success_only = List.length arms=2 &&
        List.exists (function Ast.ArmVariant (_,"Grown",None,[]) -> true | _ -> false) arms &&
        List.exists (function Ast.ArmVariant (_,"OutOfMemory",None,
          [{desc=Ast.Return (Some {desc=Ast.EnumVariant _;_});_}]) -> true | _ -> false) arms in
       let growth = Option.bind (target grow) (fun key ->
        Option.bind (M.find_opt key growth_bodies) (fun (tail,_) ->
         Option.map (fun inf -> tail,inf) (M.find_opt key functions))) in
       (match growth,Option.bind (target activate) (fun k -> M.find_opt k activation_summaries),literal limit with
        | Some (tail,grow_info),Some activation,Some limit when captured && success_only && limit>0L ->
         let arg ids wanted args = Option.bind (position ids wanted) (List.nth_opt args) in
         (match arg grow_info.Types.bindings.param_ids tail.Growth_transfer.pool grow_args,
            arg grow_info.bindings.param_ids tail.index grow_args,
            List.nth_opt activate_args activation.Activation_range.pool_arg,
            List.nth_opt activate_args activation.chunk_arg with
          | Some gp,Some gc,Some ap,Some ac
            when same pool gp && same pool ap && same chunk gc && same chunk ac
              && tail.count=Some count ->
            Local_bindings.Expr_table.replace calls activate (id pool,count,activation);
            ()
          | _ -> ())
        | _ -> ())
    | _ -> ());
   List.iter (fun (s:Ast.stmt) -> match s.desc with
    | Ast.Match (_,arms) -> List.iter (fun arm -> scan (Control_flow.arm_body arm)) arms
    | Ast.If (_,yes,no) -> scan yes; scan no
    | _ -> ()) ss in
  scan f.body in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 calls
