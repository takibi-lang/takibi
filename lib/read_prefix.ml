(* Caller flow for source-derived stored-address prefixes.
   Covered direct stores retain their named global origin for initialization
   framing. Unknown writes and unsupported control flow discard facts. *)
module I = Types.IntMap
type fact = { through:int64; count:string; schema:Loop_transfer.summary option }
let run ~protected_globals ~functions ~key_of ~write_footprint ~target ~constructors ~loop_summaries ~accessors prog =
  let stores = Local_bindings.Expr_table.create 16 in
  let wrappers = Wrapper_prefix.infer ~functions ~key_of ~target ~loop_summaries prog in
  let inspect (f : Ast.func) (info : Types.func_info) =
    let binding e = Local_bindings.id_for_expr info.bindings e in
    let rec root (e : Ast.expr) = match e.desc with
      | Ast.AddrOf e | Ast.Unsafe e -> root e
      | Ast.Var _ -> binding e
      | _ -> None in
    let inline_local id = not (List.mem id info.bindings.param_ids) &&
      match I.find_opt id info.binding_types with
      | Some (Ast.TypeNamed _ | Ast.TypeIndexed _) -> true
      | _ -> false in
    let literal (e : Ast.expr) = match e.desc with
      | Ast.IntLit n when n >= 0L -> Some n | _ -> None in
    let meet a b = I.merge (fun _ x y -> match x,y with
      | Some x,Some y when x.count=y.count && x.schema=y.schema -> Some {x with through=Int64.min x.through y.through} | _ -> None) a b in
    let apply_success before after args p i (schema:Loop_transfer.summary) =
      match List.nth_opt args p,List.nth_opt args i with
      | Some pool,Some index -> (match root pool,literal index with
          | Some id,Some n when inline_local id && I.mem id before ->
              let old = I.find id before in
              if old.count=schema.count && (old.schema=None || old.schema=Some schema)
              then I.add id {through=Int64.max n old.through; count=schema.count;schema=Some schema} after
              else after
          | _ -> after)
      | _ -> after in
    let from_boolean before after (e : Ast.expr) =
      match e.desc,target e with
      | Ast.Call (_,args),Some key ->
          (match Types.StringMap.find_opt key wrappers with
           | Some (p,i,schema) -> apply_success before after args p i schema | None -> after)
      | _ -> after in
    let branch_facts before after (e : Ast.expr) = match e.desc with
      | Ast.BinOp (Ast.Eq,call,{desc=Ast.BoolLit false;_})
      | Ast.BinOp (Ast.Ne,call,{desc=Ast.BoolLit true;_}) -> after,from_boolean before after call
      | Ast.BinOp (Ast.Eq,call,{desc=Ast.BoolLit true;_})
      | Ast.BinOp (Ast.Ne,call,{desc=Ast.BoolLit false;_}) -> from_boolean before after call,after
      | _ -> from_boolean before after e,after in
    let covered facts (e:Ast.expr) = match e.desc,
        Option.bind (target e) (fun key -> Types.StringMap.find_opt key accessors) with
      | Ast.Call (_,args),Some (p,i,schema) ->
          (match Option.bind (List.nth_opt args p) root, Option.bind (List.nth_opt args i) literal with
           | Some id,Some n when inline_local id ->
               Option.fold ~none:false ~some:(fun fact -> n<=fact.through && fact.schema=Some schema)
                 (I.find_opt id facts)
           | _ -> false)
      | _ -> false in
    let payload_store facts (lhs:Ast.expr) = match lhs.desc with
      | Ast.Deref e -> covered facts e | _ -> false in
    let rec expr facts (e : Ast.expr) = match e.desc with
      | Ast.Call (_, args) ->
          let facts = List.fold_left expr facts args in
          let after = (match write_footprint e with
           | Init_writes.Writes paths when Init_writes.Paths.for_all (fun (root,_) -> match root with Init_writes.Global name -> not (Growth_body.S.mem name protected_globals) | Init_writes.Parameter _ -> false) paths -> facts
           | _ ->
               I.empty) in
          (match Option.bind (target e) (fun key -> Types.StringMap.find_opt key constructors) with
           | Some (p,count) -> (match Option.bind (List.nth_opt args p) root with
               | Some id when inline_local id -> I.add id {through=(-1L);count;schema=None} after
               | _ -> after)
           | None -> after)
      | Ast.Assign (lhs, rhs) ->
          let facts = expr (expr facts rhs) lhs in
          if payload_store facts lhs then begin
            (match lhs.desc with
             | Ast.Deref pointer -> (match Option.bind (target pointer) (fun k -> Types.StringMap.find_opt k accessors) with
                 | Some (_,_,{Loop_transfer.origin=Address_extent.Address (name,_,_,_,_);_}) ->
                     Local_bindings.Expr_table.replace stores e name
                 | _ -> ())
             | _ -> ());
            I.filter (fun id _ -> inline_local id) facts
          end else (match lhs.desc, binding lhs with
           | Ast.Var _, Some id ->
               (match I.find_opt id info.binding_types with
                | Some ty when Init_writes.scalar ty -> facts
                | _ -> I.empty)
           | _ ->
               I.empty)
      | Ast.BinOp (_, a, b) | Ast.Index (a, b) -> expr (expr facts a) b
      | Ast.SliceOf (a, b, c) -> expr (expr (expr facts a) b) c
      | Ast.VariantCtor (_, _, x) | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x
      | Ast.Cast (_, x) | Ast.FieldGet (x, _) | Ast.Unsafe x -> expr facts x
      | Ast.StructLit xs | Ast.TupleLit xs -> List.fold_left expr facts xs
      | _ -> facts
    and body facts ss = List.fold_left (fun (facts,dead) s ->
      if dead then facts,true else stmt facts s) (facts,false) ss
    and stmt facts (s : Ast.stmt) = match s.desc with
      | Ast.Return e -> Option.fold ~none:facts ~some:(expr facts) e, true
      | Ast.Expr e | Ast.Yield e | Ast.LetTuple (_,e) | Ast.StaticAssert (e,_)
      | Ast.Let (_,_,_,Some e,_) -> expr facts e,false
      | Ast.Block ss | Ast.UnsafeBlock ss -> body facts ss
      | Ast.If (c,yes,no) ->
          let before = facts in
          let facts = expr facts c in
          let yes_facts,no_facts = branch_facts before facts c in
          join [body yes_facts yes; body no_facts no]
      | Ast.Match (e,arms) | Ast.LetMatch (_,_,_,e,arms) ->
          let after = expr facts e in
          let candidate = match e.desc,target e with
            | Ast.Call (_,args),Some key ->
                Option.map (fun summary -> (args,summary))
                  (Types.StringMap.find_opt key loop_summaries)
            | _ -> None in
          join (List.map (fun arm ->
            let facts = match arm,candidate with
              | Ast.ArmVariant (v,c,_,_),Some (args,schema)
                  when v=schema.Loop_transfer.success_variant && c=schema.success_case ->
                    apply_success facts after args schema.pool_arg schema.index_arg schema
              | _ -> after in
            body facts (Control_flow.arm_body arm)) arms)
      | Ast.While (c,ss) | Ast.ForEach (_,c,ss) ->
          ignore (expr facts c); ignore (body I.empty ss); I.empty,false
      | Ast.For (_,_,lo,hi,ss) ->
          ignore (expr (expr facts lo) hi); ignore (body I.empty ss); I.empty,false
      | Ast.Break | Ast.Continue -> facts,true
      | _ -> facts,false
    and join paths = match List.filter_map (fun (s,dead) -> if dead then None else Some s) paths with
      | [] -> I.empty,true | a::rest -> List.fold_left meet a rest,false in
    ignore (body I.empty f.body) in
  List.iter (function Ast.FuncDef f ->
    Option.iter (inspect f) (Types.StringMap.find_opt (key_of f) functions)
    | _ -> ()) prog;
  stores
