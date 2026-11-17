(* Conditional pop summary: a covered input chain implies covered returned
   head fields. No caller entry certificate is supplied by this module. *)
module M = Types.StringMap
module I = Types.IntMap
type summary = { core_arg:int; owner_type:string; covered_fields:string list; success_variant:string; success_case:string; empty_case:string; exhausted_case:string; links:string; head:string; capacity:int64 }
let run ~functions ~key_of ~target ~write_footprint ~struct_fields ~record_transfers prog =
 let summaries=ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let id e = Local_bindings.id_for_expr info.bindings e in
  let same a b = match id a,id b with Some a,Some b -> a=b | _ -> false in
  let defines s e = match Local_bindings.ids_for_stmt info.bindings s with [i] -> id e=Some i | _ -> false in
  let field (e:Ast.expr) = match e.desc with
   | Ast.FieldGet (base,name) -> Option.map (fun i -> i,name) (id base) | _ -> None in
  let same_field a b = match field a,field b with Some a,Some b -> a=b | _ -> false in
  let pure_call (e:Ast.expr) = match write_footprint e with
   | Init_writes.Writes paths -> Init_writes.Paths.is_empty paths | _ -> false in
  match f.body with
  | [({Ast.desc=Ast.Let (false,_,_,Some old_head,_);_} as capture);
     {desc=Ast.If ({desc=Ast.BinOp (Ast.Lt,head,{desc=Ast.IntLit limit;_});_},[
       {desc=Ast.If ({desc=Ast.BinOp (Ast.Eq,old_generation,{desc=Ast.IntLit 0L;_});_},
         [{desc=Ast.Return (Some {desc=Ast.EnumVariant (exhaust_v,exhaust_c);_});_}],[]);_};
       {desc=Ast.Expr {desc=Ast.Assign (new_head,{desc=Ast.Index (links,read_index);_});_};_};
       ({desc=Ast.Let (false,_,_,Some generation_read,_);_} as gen_capture);
       {desc=Ast.Expr {desc=Ast.Assign (generation_write,({desc=Ast.Call (_,[gen_arg]);_} as next_gen));_};_};
       {desc=Ast.Return (Some {desc=Ast.VariantCtor (success_v,success_c,({desc=Ast.Call (_,owner_args);_} as owner));_});_}
      ],[]);_};
     {desc=Ast.Return (Some {desc=Ast.EnumVariant (empty_v,empty_c);_});_}]
    when defines capture head && same head read_index && same_field old_head new_head
      && same_field old_generation generation_read && same_field old_generation generation_write
      && defines gen_capture gen_arg && pure_call next_gen
      && success_v=exhaust_v && success_v=empty_v && success_c<>exhaust_c && success_c<>empty_c ->
     (match field old_head,field links,field old_generation,
       Option.bind (target owner) (fun k -> M.find_opt k record_transfers) with
      | Some (core,head_field),Some (links_core,link_field),Some (gen_core,gen_field),
        Some (Record_transfer.Construct (owner_type,mapping))
        when core=links_core && core=gen_core && List.mem core info.bindings.param_ids
          && head_field<>link_field && gen_field<>head_field && gen_field<>link_field
          && List.for_all (fun arg -> same arg head || same arg gen_arg) owner_args ->
        let capacity = Option.bind (I.find_opt core info.binding_types) (fun ty ->
          Option.bind (Record_transfer.record ty) (fun name ->
            Option.bind (struct_fields name) (fun fields -> match List.assoc_opt link_field fields with
             | Some (Ast.TypeArray (Ast.TypeUsize,n)) -> Some (Int64.of_int n) | _ -> None))) in
        let covered_fields = List.filter_map (fun (name,p) ->
          match List.nth_opt owner_args p with Some arg when same arg head -> Some name | _ -> None) mapping in
        if capacity=Some limit && covered_fields<>[] then begin
         let rec position n = function [] -> assert false | x::xs -> if x=core then n else position (n+1) xs in
         summaries:=M.add (key_of f) {core_arg=position 0 info.bindings.param_ids;owner_type;covered_fields;success_variant=success_v;success_case=success_c;empty_case=empty_c;exhausted_case=exhaust_c;links=link_field;head=head_field;capacity=limit} !summaries;
         ()
        end
      | _ -> ())
  | _ -> () in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !summaries
