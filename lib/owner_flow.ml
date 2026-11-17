(* Caller flow for source-derived pool and owner coverage.
   Facts are erased; unknown writes discard them. Covered payload stores
   supply a named global origin to the initialization checker. *)
module M=Types.StringMap
module I=Types.IntMap
type state={ pools:Insert_body.summary I.t; owners:(int * Insert_body.summary) I.t }
let empty={pools=I.empty;owners=I.empty}
let run ~protected_globals ~functions ~key_of ~target ~write_footprint ~owner_constructors ~insert_summaries ~owner_accessors prog =
 let stores=Local_bindings.Expr_table.create 16 in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let id e=Local_bindings.id_for_expr info.bindings e in
  let rec root (e:Ast.expr)=match e.desc with Ast.AddrOf e -> root e | Ast.Var _ -> id e | _ -> None in
  let local i=not (List.mem i info.bindings.param_ids) && match I.find_opt i info.binding_types with
   | Some (Ast.TypeNamed _ | Ast.TypeIndexed _) -> true | _ -> false in
  let meet_map a b=I.merge (fun _ a b -> match a,b with Some a,Some b when a=b -> Some a | _ -> None) a b in
  let meet a b={pools=meet_map a.pools b.pools;owners=meet_map a.owners b.owners} in
  let insert state (e:Ast.expr)=match e.desc,Option.bind (target e) (fun k -> M.find_opt k insert_summaries) with
   | Ast.Call (_,args),Some schema when List.length args=1 ->
     (match Option.bind (List.nth_opt args schema.Insert_body.pool_arg) root with
      | Some pool when local pool && I.find_opt pool state.pools=Some schema -> Some(pool,schema)
      | _ -> None)
   | _ -> None in
  let covered state (e:Ast.expr)=match e.desc,Option.bind (target e) (fun k -> M.find_opt k owner_accessors) with
   | Ast.Call (_,args),Some(p,o,schema) when List.length args=2 ->
    (match Option.bind (List.nth_opt args p) root,
      Option.bind (Option.bind (List.nth_opt args o) id) (fun i -> I.find_opt i state.owners) with
     | Some pool,Some(origin,owner_schema) when pool=origin && local pool && owner_schema=schema
         && I.find_opt pool state.pools=Some schema -> Some schema
     | _ -> None)
   | _ -> None in
  let rec expr state (e:Ast.expr)=match e.desc with
   | Ast.Call (_,args) ->
     let state=List.fold_left expr state args in
     (match insert state e with
      | Some(pool,schema) -> {pools=I.singleton pool schema;owners=I.filter (fun _ (p,s) -> p=pool && s=schema) state.owners}
      | None ->
       let after=match write_footprint e with Init_writes.Writes p when Init_writes.Paths.for_all (fun (root,_) -> match root with Init_writes.Global name -> not (Growth_body.S.mem name protected_globals) | Init_writes.Parameter _ -> false) p -> state | _ -> empty in
       (match Option.bind (target e) (fun k -> M.find_opt k owner_constructors) with
        | Some [(p,schema)] -> (match Option.bind (List.nth_opt args p) root with
          | Some pool when local pool -> {pools=I.add pool schema state.pools;owners=I.filter (fun _ (p,_) -> p<>pool) state.owners}
          | _ -> after)
        | _ -> after))
   | Ast.Assign (lhs,rhs) ->
     let state=expr (expr state rhs) lhs in
     (match lhs.desc with
      | Ast.Deref pointer -> (match covered state pointer with
        | Some {Insert_body.origin=Address_extent.Address(name,_,_,_,_);_} ->
          Local_bindings.Expr_table.replace stores e name;
          ();
          state
        | _ -> empty)
      | _ -> empty)
   | Ast.BinOp (_,a,b) | Ast.Index (a,b) -> expr (expr state a) b
   | Ast.SliceOf (a,b,c) -> expr (expr (expr state a) b) c
   | Ast.VariantCtor (_,_,e) | Ast.Bnot e | Ast.Deref e | Ast.AddrOf e
   | Ast.Cast (_,e) | Ast.FieldGet (e,_) | Ast.Unsafe e -> expr state e
   | Ast.StructLit es | Ast.TupleLit es -> List.fold_left expr state es
   | _ -> state
  and body state ss=List.fold_left (fun (state,dead) s -> if dead then state,true else stmt state s) (state,false) ss
  and stmt state (s:Ast.stmt)=match s.desc with
   | Ast.Return e -> Option.fold ~none:state ~some:(expr state) e,true
   | Ast.Expr e | Ast.Yield e | Ast.LetTuple (_,e) | Ast.StaticAssert (e,_) | Ast.Let (_,_,_,Some e,_) -> expr state e,false
   | Ast.Block ss | Ast.UnsafeBlock ss -> body state ss
   | Ast.If (condition,a,b) -> let state=expr state condition in join [body state a;body state b]
   | Ast.Match (call,arms) | Ast.LetMatch (_,_,_,call,arms) ->
     let candidate=insert state call in
     let after=expr state call in
     let result=match s.desc,Local_bindings.ids_for_stmt info.bindings s with Ast.LetMatch _,[i] -> Some i | _ -> None in
     let paths=List.mapi (fun arm_index arm ->
      let state=match arm,candidate,Local_bindings.id_for_arm info.bindings s.loc arm_index with
       | Ast.ArmVariant(v,c,_,_),Some(pool,schema),Some bound
         when v=schema.success_variant && c=schema.success_case -> {after with owners=I.add bound (pool,schema) after.owners}
       | _ -> after in
      let ss=Control_flow.arm_body arm in
      let state,dead=body state ss in
      let state=match result,List.rev ss with
       | Some result,{Ast.desc=Ast.Yield value;_}::_ ->
         (match Option.bind (id value) (fun i -> I.find_opt i state.owners) with
          | Some owner -> {state with owners=I.add result owner state.owners} | _ -> state)
       | _ -> state in state,dead) arms in
     let state,dead=join paths in
     state,dead
   | Ast.While (e,ss) | Ast.ForEach (_,e,ss) -> ignore(expr state e);ignore(body empty ss);empty,false
   | Ast.For (_,_,a,b,ss) -> ignore(expr (expr state a) b);ignore(body empty ss);empty,false
   | Ast.Break | Ast.Continue -> state,true
   | _ -> state,false
  and join paths=match List.filter_map (fun (s,dead) -> if dead then None else Some s) paths with
   | [] -> empty,true | s::ss -> List.fold_left meet s ss,false in
  ignore(body empty f.body) in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 stores
