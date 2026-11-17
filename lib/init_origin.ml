(* Body-derived origins for views of named inline global arrays. This narrow
   domain preserves the backing object, not an index range or an ownership
   claim. Unknown returns and recursive/foreign calls never mint an origin. *)
module StringMap = Types.StringMap
module IntMap = Types.IntMap
module IntSet = Set.Make (Int)

type context = {
  info : Types.func_info;
  aliases : Ast.expr IntMap.t;
  unstable : IntSet.t;
  returns : Ast.expr option list;
}

let infer ~definition ~target ~global_type ~no_writes =
  let contexts = ref StringMap.empty and results = ref StringMap.empty in
  let context info (f : Ast.func) =
    let key = Types.loc_key f.def_loc ^ ":" ^ f.name in
    match StringMap.find_opt key !contexts with
    | Some ctx -> ctx
    | None ->
        let aliases = ref IntMap.empty and unstable = ref IntSet.empty and returns = ref [] in
        let binding e = Local_bindings.id_for_expr info.Types.bindings e in
        let destabilize e = Option.iter (fun id -> unstable := IntSet.add id !unstable) (binding e) in
        let rec expr (e : Ast.expr) = match e.desc with
          | Ast.Assign (({desc = Ast.Var _; _} as a), b) -> destabilize a; expr b
          | Ast.AddrOf ({desc = Ast.Var _; _} as a) -> destabilize a
          | Ast.Call (_, xs) | Ast.StructLit xs | Ast.TupleLit xs -> List.iter expr xs
          | Ast.VariantCtor (_, _, x) | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x
          | Ast.Cast (_, x) | Ast.FieldGet (x, _) | Ast.Unsafe x -> expr x
          | Ast.BinOp (_, a, b) | Ast.Index (a, b) | Ast.Assign (a, b) -> expr a; expr b
          | Ast.SliceOf (a, b, c) -> expr a; expr b; expr c
          | _ -> ()
        and stmt (s : Ast.stmt) =
          let body = List.iter stmt in
          let arms xs = List.iter (fun arm -> body (Control_flow.arm_body arm)) xs in
          match s.desc with
          | Ast.Let (mutable_, _, _, init, _) ->
              (match Local_bindings.ids_for_stmt info.bindings s with
               | [id] -> if mutable_ then unstable := IntSet.add id !unstable
                   else Option.iter (fun e -> aliases := IntMap.add id e !aliases) init
               | _ -> ()); Option.iter expr init
          | Ast.Return value -> returns := value :: !returns; Option.iter expr value
          | Ast.Expr e | Ast.Yield e | Ast.LetTuple (_, e) | Ast.StaticAssert (e, _) -> expr e
          | Ast.Block ss | Ast.UnsafeBlock ss -> body ss
          | Ast.If (c, yes, no) -> expr c; body yes; body no
          | Ast.While (c, ss) | Ast.ForEach (_, c, ss) -> expr c; body ss
          | Ast.For (_, _, lo, hi, ss) -> expr lo; expr hi; body ss
          | Ast.Match (e, xs) | Ast.LetMatch (_, _, _, e, xs) -> expr e; arms xs
          | Ast.Break | Ast.Continue -> () in
        List.iter stmt f.body;
        let ctx = {info; aliases = !aliases; unstable = !unstable; returns = !returns} in
        contexts := StringMap.add key ctx !contexts;
        ctx in
  let rec origin seen ctx (e : Ast.expr) = match e.desc with
    | Ast.Var name -> (match Local_bindings.id_for_expr ctx.info.bindings e with
        | None -> (match Option.map Init_writes.strip (global_type name) with
            | Some (Ast.TypeArray _) -> Some name | _ -> None)
        | Some id when not (IntSet.mem id ctx.unstable) && not (List.mem id seen) ->
            (* An inline array copy has fresh storage; only a slice binding
               keeps the origin of the initializer's backing memory. *)
            (match Option.map Init_writes.strip (IntMap.find_opt id ctx.info.binding_types) with
             | Some (Ast.TypeSlice _) ->
                 Option.bind (IntMap.find_opt id ctx.aliases) (origin (id :: seen) ctx)
             | _ -> None)
        | _ -> None)
    | Ast.SliceOf (base, _, _) | Ast.Unsafe base -> origin seen ctx base
    | Ast.Call _ when no_writes e -> Option.bind (target e) returned
    | _ -> None
  and returned key = match StringMap.find_opt key !results with
    | Some result -> result
    | None ->
        results := StringMap.add key None !results;
        let result = Option.bind (definition key) (fun (f, info) ->
          match Init_writes.strip info.Types.ret_type with
          | Ast.TypeSlice _ ->
              let ctx = context info f in
              let origins = List.map (fun e -> Option.bind e (origin [] ctx)) ctx.returns in
              (match origins with Some name :: rest when List.for_all ((=) (Some name)) rest -> Some name
               | _ -> None)
          | _ -> None) in
        results := StringMap.add key result !results;
        result in
  fun info f e -> origin [] (context info f) e
