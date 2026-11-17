(* Conditional composition of an actual match payload with its finish call.
   This does not establish the covered-chain premise at the pop call. *)
module M = Types.StringMap
let run ~functions ~key_of ~target ~pop_summaries ~finish_summaries prog =
 let calls=Local_bindings.Expr_table.create 8 in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let rec path (e:Ast.expr) = match e.desc with
   | Ast.AddrOf e -> path e
   | Ast.Var _ -> Option.map (fun id -> id,[]) (Local_bindings.id_for_expr info.bindings e)
   | Ast.FieldGet (e,n) -> Option.map (fun (id,ns) -> id,ns@[n]) (path e)
   | _ -> None in
  let rec scan ss = List.iter (fun (s:Ast.stmt) -> match s.desc with
   | Ast.Match (({desc=Ast.Call (_,pop_args);_} as pop_call),arms) ->
     (match Option.bind (target pop_call) (fun k -> M.find_opt k pop_summaries) with
      | Some pop -> List.iteri (fun arm_index arm -> match arm with
       | Ast.ArmVariant (v,c,Some _,[{desc=Ast.Return (Some ({desc=Ast.Call (_,finish_args);_} as call));_}])
          when v=pop.Pop_range.success_variant && c=pop.success_case ->
         (match Option.bind (target call) (fun k -> M.find_opt k finish_summaries),
           Local_bindings.id_for_arm info.bindings s.loc arm_index with
          | Some finish,Some bound when finish.Finish_range.owner_type=pop.owner_type
              && List.mem finish.index_field pop.covered_fields
              && List.length pop_args=1 && List.length finish_args=2 ->
            (match Option.bind (List.nth_opt pop_args pop.core_arg) path,
               Option.bind (List.nth_opt finish_args finish.pool_arg) path,
               Option.bind (List.nth_opt finish_args finish.owner_arg) (Local_bindings.id_for_expr info.bindings) with
             | Some (core_root,core_path),Some (pool_root,pool_path),Some owner
                when core_root=pool_root && owner=bound
                  && List.length core_path=List.length pool_path+1
                  && List.filteri (fun i _ -> i<List.length pool_path) core_path=pool_path ->
               Local_bindings.Expr_table.replace calls call finish;
               ()
             | _ -> ())
          | _ -> ())
       | _ -> ()) arms
      | None -> ());
     List.iter (fun arm -> scan (Control_flow.arm_body arm)) arms
   | Ast.Match (_,arms) | Ast.LetMatch (_,_,_,_,arms) -> List.iter (fun arm -> scan (Control_flow.arm_body arm)) arms
   | Ast.If (_,a,b) -> scan a;scan b
   | Ast.Block ss | Ast.UnsafeBlock ss -> scan ss
   | _ -> ()) ss in
  scan f.body in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 calls
