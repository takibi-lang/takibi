(* Compose a source-checked pointer accessor with an owner-field projection.
   Reuse the direct accessor's geometry/alignment/extent checks. *)
module M=Types.StringMap
let run ~functions ~key_of ~target ~insert_summaries ~record_transfers prog =
 let geometry=M.map (fun (s:Insert_body.summary) ->
  {Loop_transfer.pool_arg=s.pool_arg;index_arg=0;success_variant=s.success_variant;success_case=s.success_case;
   pool_type=s.pool_type;slots=s.slots;capacity=s.capacity;table=s.table;count=s.count;origin=s.origin}) insert_summaries in
 let direct=Accessor_prefix.run ~functions ~key_of ~target ~loop_summaries:geometry prog in
 let accessors=ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let position e=Option.bind (Local_bindings.id_for_expr info.bindings e) (fun wanted ->
   let rec find n=function [] -> None | x::xs -> if x=wanted then Some n else find (n+1) xs in
   find 0 info.bindings.param_ids) in
  match f.body with
  | [{Ast.desc=Ast.Return (Some ({desc=Ast.Call (_,args);_} as call));_}] when List.length args=2 ->
   (match Option.bind (target call) (fun k -> M.find_opt k direct) with
    | Some(p,i,shape) ->
     (match List.nth_opt args p,List.nth_opt args i with
      | Some pool,Some ({desc=Ast.Call (_,[owner]);_} as projection) ->
       (match position pool,position owner,Option.bind (target projection) (fun k -> M.find_opt k record_transfers) with
        | Some pool_arg,Some owner_arg,Some(Record_transfer.Project(owner_type,0,index_field)) ->
         M.iter (fun key (schema:Insert_body.summary) ->
          if M.find_opt key geometry=Some shape && schema.owner_type=owner_type && schema.index_field=index_field then begin
           accessors:=M.add (key_of f) (pool_arg,owner_arg,schema) !accessors;
           ()
          end) insert_summaries
        | _ -> ())
      | _ -> ())
    | _ -> ())
  | _ -> () in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !accessors
