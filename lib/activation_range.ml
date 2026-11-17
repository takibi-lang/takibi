(* Isolated source-shape evidence only. Does not grant compiler facts.
   A recognized push loop requires prior reachable-node coverage and
   chunk < acquired_chunks, plus nonwrapping geometry. *)
module M = Types.StringMap
type summary = { pool_arg:int; chunk_arg:int; slots:int64; links:string list; head:string list }
let run ~functions ~key_of prog =
 let summaries = ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let id e = Local_bindings.id_for_expr info.bindings e in
  let same a b = match id a,id b with Some a,Some b -> a=b | _ -> false in
  let defines s e = match Local_bindings.ids_for_stmt info.bindings s with
   | [i] -> id e=Some i | _ -> false in
  let rec path (e:Ast.expr) = match e.desc with
   | Ast.FieldGet (base,field) -> Option.map (fun (i,fs) -> i,fs@[field]) (path base)
   | Ast.Var _ -> Option.map (fun i -> i,[]) (id e)
   | _ -> None in
  match f.body with
  | [({desc=Ast.Let (false,_,_,Some {desc=Ast.BinOp (Ast.Mul,chunk,{desc=Ast.IntLit slots;_});_},_);_} as base);
     ({desc=Ast.For (_,_,{desc=Ast.IntLit 0L;_},{desc=Ast.IntLit bound;_},
       [({desc=Ast.Let (false,_,_,Some {desc=Ast.BinOp (Ast.Add,base_use,offset);_},_);_} as slot);
        {desc=Ast.Expr {desc=Ast.Assign ({desc=Ast.Index (table,index);_},old_head);_};_};
        {desc=Ast.Expr {desc=Ast.Assign (new_head,new_index);_};_}]);_} as loop)]
    when slots>0L && slots=bound && defines base base_use && (match Local_bindings.ids_for_stmt info.bindings loop with [_;i] -> id offset=Some i | _ -> false)
      && defines slot index && same index new_index ->
      (match id chunk,path table,path old_head,path new_head with
       | Some chunk_id,Some (pool,table),Some (pool2,head),Some (pool3,head2)
          when List.mem chunk_id info.bindings.param_ids
            && List.mem pool info.bindings.param_ids && pool=pool2 && pool=pool3
            && head=head2 && table<>head ->
          let position id =
            let rec find n = function
             | [] -> assert false | x::xs -> if x=id then n else find (n+1) xs in
            find 0 info.bindings.param_ids in
          summaries := M.add (key_of f)
            {pool_arg=position pool; chunk_arg=position chunk_id; slots;links=table;head} !summaries;
          ()
       | _ -> ())
  | _ -> () in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !summaries
