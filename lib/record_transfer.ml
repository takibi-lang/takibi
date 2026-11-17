(* Source-derived direct record construction/projection. No allocation,
   ownership, lifetime, or range guarantee is minted by these summaries. *)
module M = Types.StringMap
module I = Types.IntMap
type summary = Construct of string * (string * int) list | Project of string * int * string
let rec record = function
 | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeRef t | Ast.TypeRefMut t -> record t
 | Ast.TypeNamed n | Ast.TypeIndexed (n,_) -> Some n
 | _ -> None
let run ~functions ~key_of ~struct_fields prog =
 let summaries = ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let id e = Local_bindings.id_for_expr info.bindings e in
  let position e = Option.bind (id e) (fun wanted ->
   let rec find n = function [] -> None | x::xs -> if x=wanted then Some n else find (n+1) xs in
   find 0 info.bindings.param_ids) in
  let ty e = Option.bind (id e) (fun i -> I.find_opt i info.binding_types) in
  let summary = match f.body with
   | [({Ast.desc=Ast.Let (_,_,_,Some {desc=Ast.StructLit values;_},_);_} as binding);
      {desc=Ast.Return (Some result);_}] ->
      (match Local_bindings.ids_for_stmt info.bindings binding,id result,Option.bind (ty result) record with
       | [bound],Some returned,Some name when bound=returned ->
        Option.bind (struct_fields name) (fun fields ->
         if List.length fields <> List.length values then None else
         let rec zip fields values = match fields,values with
          | [],[] -> Some []
          | (field,_)::fs,v::vs -> Option.bind (position v) (fun p ->
             Option.map (fun rest -> (field,p)::rest) (zip fs vs))
          | _ -> None in
         Option.map (fun fields -> Construct(name,fields)) (zip fields values))
       | _ -> None)
   | [{Ast.desc=Ast.Return (Some {desc=Ast.FieldGet (value,field);_});_}] ->
      Option.bind (position value) (fun p -> Option.map (fun name -> Project(name,p,field)) (Option.bind (ty value) record))
   | _ -> None in
  Option.iter (fun summary -> summaries:=M.add (key_of f) summary !summaries) summary in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !summaries
