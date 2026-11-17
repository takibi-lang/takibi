(* Validate all paths of the concrete append shape, under explicit entry
   prefix/index and pool/global separation obligations. No callee-name trust. *)
module M = Types.StringMap
module S = Set.Make(String)
(* No other shape can produce a checked growth summary below. Keep this
   cheap structural preflight ahead of the dependent provenance passes. *)
let is_candidate (f : Ast.func) =
  let rec success = function
    | [{Ast.desc = Ast.Return (Some {desc = Ast.EnumVariant (_, "Grown"); _}); _}] -> true
    | _ :: rest -> success rest
    | [] -> false in
  let rec assertions_only = function
    | [] -> true
    | {Ast.desc = Ast.StaticAssert _; _} :: rest -> assertions_only rest
    | _ -> false in
  let rec body = function
    | {Ast.desc = Ast.StaticAssert _; _} :: rest -> body rest
    | {Ast.desc = Ast.Match (_, [a; b]); _} :: rest when assertions_only rest ->
        let allocated = function
          | Ast.ArmVariant (_, "Allocated", Some _, ss) -> success ss
          | _ -> false in
        allocated a || allocated b
    | _ -> false in
  body f.body

let run ~functions ~key_of ~write_footprint ~view_origin ~growth_transfers prog =
  let checked = ref M.empty in
  let inspect (f : Ast.func) (info : Types.func_info) tail =
    let globals = ref S.empty in
    let same id e = Local_bindings.id_for_expr info.bindings e = Some id in
    let rec expr (e : Ast.expr) = match e.desc with
      | Ast.Call (_,args) -> List.for_all expr args &&
          (match write_footprint e with
           | Init_writes.Unknown -> false
           | Init_writes.Writes paths -> Init_writes.Paths.for_all (fun (root,_) ->
               match root with Init_writes.Global n -> globals:=S.add n !globals; true
               | Init_writes.Parameter _ -> false) paths)
      | Ast.Assign ({desc=Ast.Index (base,index);_},rhs) ->
          (match view_origin info f base with
           | Some n -> globals:=S.add n !globals; expr base && expr index && expr rhs
           | None -> false)
      | Ast.Assign _ -> false
      | Ast.VariantCtor (_,_,x) | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x
      | Ast.Cast (_,x) | Ast.FieldGet (x,_) | Ast.Unsafe x -> expr x
      | Ast.BinOp (_,a,b) | Ast.Index (a,b) -> expr a && expr b
      | Ast.SliceOf (a,b,c) -> expr a && expr b && expr c
      | Ast.StructLit xs | Ast.TupleLit xs -> List.for_all expr xs
      | _ -> true in
    let rec before (s : Ast.stmt) = match s.desc with
      | Ast.Let (false,_,_,Some e,_) -> expr e
      | Ast.Expr e -> expr e
      | Ast.For (_,_,lo,hi,ss) -> expr lo && expr hi && List.for_all before ss
      | _ -> false in
    let success ss = match List.rev ss with
      | {Ast.desc=Ast.Return (Some {desc=Ast.EnumVariant (_,"Grown");_});_} ::
        {desc=Ast.Expr {desc=Ast.Assign ({desc=Ast.FieldGet (p,count);_},
          {desc=Ast.BinOp (Ast.Add,i,{desc=Ast.IntLit 1L;_});_});_};_} ::
        {desc=Ast.Expr {desc=Ast.Assign ({desc=Ast.Index
          ({desc=Ast.FieldGet (mp,metadata);_},mi);_},mrhs);_};_} ::
        {desc=Ast.Expr {desc=Ast.Assign ({desc=Ast.Index
          ({desc=Ast.FieldGet (sp,table);_},si);_},srhs);_};_} :: earlier ->
          same tail.Growth_transfer.pool p && same tail.pool mp && same tail.pool sp
          && same tail.index i && same tail.index mi && same tail.index si
          && tail.count=Some count && table=tail.table && metadata<>table && metadata<>count
          && expr mrhs && expr srhs && List.for_all before (List.rev earlier)
      | _ -> false in
    let statements = List.filter (fun (s:Ast.stmt) -> match s.desc with
      | Ast.StaticAssert _ -> false | _ -> true) f.body in
    let valid = match statements with
      | [{desc=Ast.Match (call,arms);_}] when List.length arms=2 ->
          expr call &&
          List.exists (function Ast.ArmVariant (_,"OutOfMemory",None,
            [{desc=Ast.Return (Some {desc=Ast.EnumVariant (_,"OutOfMemory");_});_}]) -> true | _ -> false) arms &&
          List.exists (function Ast.ArmVariant (_,"Allocated",Some _,ss) -> success ss | _ -> false) arms
      | _ -> false in
    if valid then begin
      checked := M.add (key_of f) (tail,!globals) !checked;
      ()
    end in
  List.iter (function Ast.FuncDef f ->
    (match M.find_opt (key_of f) functions,M.find_opt (key_of f) growth_transfers with
     | Some info,Some tail -> inspect f info tail | _ -> ()) | _ -> ()) prog;
  !checked
