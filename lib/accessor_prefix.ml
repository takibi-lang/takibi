(* Match a direct table accessor to source-derived chunk geometry.
   Check relative byte extent and alignment; valid static object placement
   remains a backend memory-model premise. *)
module M = Types.StringMap
let run ~functions ~key_of ~target ~loop_summaries prog =
  let found = ref M.empty in
  let inspect (f:Ast.func) (info:Types.func_info) =
    let id e = Local_bindings.id_for_expr info.bindings e in
    let same a b = match id a,id b with Some a,Some b -> a=b | _ -> false in
    let bound s e = match Local_bindings.ids_for_stmt info.bindings s with
      | [x] -> id e=Some x | _ -> false in
    let param e =
      let rec go n = function [] -> None | x::xs -> if id e=Some x then Some n else go (n+1) xs in
      go 0 info.bindings.param_ids in
    let literal (e:Ast.expr) = match e.desc with Ast.IntLit n -> Some n | _ -> None in
    match f.body,f.ret_type with
    | [({desc=Ast.Let (false,_,_,Some {desc=Ast.BinOp (Ast.Div,index,divisor);_},_);_} as chunk_def);
       ({desc=Ast.Let (false,_,_,Some {desc=Ast.BinOp (Ast.Mod,index2,modulus);_},_);_} as local_def);
       {desc=Ast.If ({desc=Ast.BinOp (Ast.Lt,chunk,ceiling);_},
          [({desc=Ast.Let (false,_,_,Some {desc=Ast.Index
             ({desc=Ast.FieldGet (pool,table);_},slot);_},_);_} as base_def);
           {desc=Ast.Return (Some {desc=Ast.Unsafe {desc=Ast.BinOp (Ast.Add,
             {desc=Ast.Cast (Ast.TypePtr Ast.TypeUsize,base);_},
             {desc=Ast.Cast (Ast.TypeIsize,local);_});_};_});_}],[]);_};
       _fallback_load; _fallback_return],Some (Ast.TypePtr Ast.TypeUsize)
       when same index index2 && bound chunk_def chunk && bound chunk_def slot
         && bound local_def local && bound base_def base ->
        let pool_type = Option.map Loop_transfer.object_type
          (Option.bind (id pool) (fun id -> Types.IntMap.find_opt id info.binding_types)) in
        M.iter (fun _ (schema:Loop_transfer.summary) ->
          let extent_ok = match schema.origin with
            | Address_extent.Address (_,extent,_,hi,alignment) ->
                alignment>=8L && Int64.rem alignment 8L=0L && schema.slots>0L && schema.slots <= Int64.div (Int64.sub extent hi) 8L
            | _ -> false in
          if pool_type=Some schema.pool_type && table=schema.table
            && literal divisor=Some schema.slots && literal modulus=Some schema.slots
            && literal ceiling=Some schema.capacity && extent_ok then
            match param pool,param index with
            | Some p,Some i ->
                found := M.add (key_of f) (p,i,schema) !found;
                ()
            | _ -> ()) loop_summaries
    | _ -> () in
  List.iter (function Ast.FuncDef f ->
    Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
  (* One direct wrapper, with only forwarding parameter arguments. *)
  let direct = !found in
  List.iter (function Ast.FuncDef f ->
    (match M.find_opt (key_of f) functions,f.Ast.body with
     | Some info,[{Ast.desc=Ast.Return (Some ({desc=Ast.Call (_,args);_} as call));_}] ->
         (match Option.bind (target call) (fun key -> M.find_opt key direct) with
          | Some (p,i,schema) ->
              let position arg =
                match arg.Ast.desc with Ast.Var _ ->
                  let rec go n = function [] -> None | id::xs ->
                    if Local_bindings.id_for_expr info.bindings arg=Some id then Some n else go (n+1) xs in
                  go 0 info.bindings.param_ids
                | _ -> None in
              (match Option.bind (List.nth_opt args p) position,Option.bind (List.nth_opt args i) position with
               | Some p,Some i -> found:=M.add (key_of f) (p,i,schema) !found;
                   ()
               | _ -> ())
          | None -> ())
     | _ -> ()) | _ -> ()) prog;
  !found
