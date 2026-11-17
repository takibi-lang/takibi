(* Literal field-state inference for straight-line constructors. Unknown
   statements reject the whole summary. This records values, not ownership. *)
module M = Types.StringMap
module I = Types.IntMap
module P = Map.Make(struct type t = int * string list let compare = compare end)
type value = Scalar of int64 | Uniform of int64 * int64
let run ~functions ~key_of ~struct_fields prog =
 let summaries = ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let rec path (e:Ast.expr) = match e.desc with
   | Ast.Var _ -> Option.map (fun id -> id,[]) (Local_bindings.id_for_expr info.bindings e)
   | Ast.FieldGet (e,n) -> Option.map (fun (id,ns) -> id,ns@[n]) (path e)
   | _ -> None in
  let rec field_type ty = function [] -> Some ty | n::ns ->
   Option.bind (match ty with Ast.TypeNamed n | Ast.TypeIndexed (n,_) -> Some n | _ -> None) (fun name ->
    Option.bind (struct_fields name) (fun fields ->
     Option.bind (List.assoc_opt n fields) (fun ty -> field_type (Loop_transfer.object_type ty) ns))) in
  let capacity (id,ns) = Option.bind (I.find_opt id info.binding_types) (fun ty ->
   match field_type (Loop_transfer.object_type ty) ns with Some (Ast.TypeArray (Ast.TypeUsize,n)) -> Some (Int64.of_int n) | _ -> None) in
  let parameter_path lhs = Option.bind (path lhs) (fun ((id,ns) as p) ->
   if List.mem id info.bindings.param_ids && ns<>[] then Some p else None) in
  let step facts (s:Ast.stmt) = match s.desc with
   | Ast.Expr {desc=Ast.Assign (lhs,{desc=Ast.IntLit n;_});_} ->
      Option.bind (parameter_path lhs) (fun ((id,ns) as p) ->
       match Option.bind (I.find_opt id info.binding_types) (fun ty -> field_type (Loop_transfer.object_type ty) ns) with
        | Some Ast.TypeUsize -> Some (P.add p (Scalar n) facts) | _ -> None)
   | Ast.For (_,_,{desc=Ast.IntLit 0L;_},{desc=Ast.IntLit bound;_},body) ->
      (match Local_bindings.ids_for_stmt info.bindings s with
       | [_;counter] ->
        List.fold_left (fun facts (s:Ast.stmt) -> Option.bind facts (fun facts -> match s.desc with
         | Ast.Expr {desc=Ast.Assign ({desc=Ast.Index (array,index);_},{desc=Ast.IntLit n;_});_}
           when Local_bindings.id_for_expr info.bindings index=Some counter ->
            Option.bind (parameter_path array) (fun p ->
             if capacity p=Some bound && bound>=0L then Some (P.add p (Uniform(bound,n)) facts) else None)
         | _ -> None)) (Some facts) body
       | _ -> None)
   | Ast.StaticAssert _ -> Some facts
   | _ -> None in
  let facts=List.fold_left (fun facts s -> Option.bind facts (fun facts -> step facts s)) (Some P.empty) f.body in
  Option.iter (fun facts -> if not (P.is_empty facts) &&
    List.length (List.sort_uniq compare (List.map (fun ((id,_),_) -> id) (P.bindings facts)))=1 then begin
    summaries := M.add (key_of f) facts !summaries;
   end) facts in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !summaries
