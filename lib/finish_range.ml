(* Conditional occupancy update and owner forwarding. The owner's field must
   already be covered; merely constructing an owner does not meet that premise. *)
module M = Types.StringMap
module I = Types.IntMap
type summary = { pool_arg:int; owner_arg:int; occupancy:string; owner_type:string;
 index_field:string; success_variant:string; success_case:string }
let run ~functions ~key_of ~target ~struct_fields ~record_transfers prog =
 let summaries=ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let id e = Local_bindings.id_for_expr info.bindings e in
  let same a b = match id a,id b with Some a,Some b -> a=b | _ -> false in
  let position e = Option.bind (id e) (fun wanted ->
   let rec find n = function [] -> None | x::xs -> if x=wanted then Some n else find (n+1) xs in
   find 0 info.bindings.param_ids) in
  let projection (call:Ast.expr) = match call.desc,Option.bind (target call) (fun k -> M.find_opt k record_transfers) with
   | Ast.Call (_,args),Some (Record_transfer.Project (name,p,field)) ->
     Option.map (fun arg -> name,arg,field) (List.nth_opt args p)
   | _ -> None in
  match f.body with
   | [({Ast.desc=Ast.Let (false,_,_,Some index_call,_);_} as capture);
      {desc=Ast.If ({desc=Ast.BinOp (Ast.Lt,index,{desc=Ast.IntLit bound;_});_},[
        {desc=Ast.Expr {desc=Ast.Assign ({desc=Ast.Index ({desc=Ast.FieldGet (pool,occupancy);_},store_index);_},value_call);_};_}],[]);_};
      {desc=Ast.Return (Some {desc=Ast.VariantCtor (success_variant,success_case,returned);_});_}]
     when same index store_index ->
      let captured = match Local_bindings.ids_for_stmt info.bindings capture with [i] -> id index=Some i | _ -> false in
      (match projection index_call,projection value_call,position pool with
       | Some (owner_type,owner,index_field),Some (value_type,value_owner,_),Some pool_arg
          when captured && same owner returned && same owner value_owner && owner_type=value_type ->
         (* Projection summaries are direct returns. Require one simple
            parameter argument, so unused argument effects cannot hide here. *)
         let direct (e:Ast.expr) = match e.desc with Ast.Call (_,[arg]) -> position arg<>None | _ -> false in
         let capacity=Option.bind (id pool) (fun i -> Option.bind (I.find_opt i info.binding_types) (fun ty ->
           Option.bind (Record_transfer.record ty) (fun n -> Option.bind (struct_fields n) (fun fields ->
            match List.assoc_opt occupancy fields with Some (Ast.TypeArray (Ast.TypeUsize,n)) -> Some (Int64.of_int n) | _ -> None)))) in
         (match position owner with Some owner_arg when direct index_call && direct value_call && capacity=Some bound ->
          summaries:=M.add (key_of f) {pool_arg;owner_arg;occupancy;owner_type;index_field;success_variant;success_case} !summaries;
          ()
          | _ -> ())
       | _ -> ())
   | _ -> () in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !summaries
