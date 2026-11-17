(* Finite, monotone argument/result and retention proposals. The ordinary
   provenance checker validates proposed non-retaining contracts afterwards.
   Unknown calls retain their arguments; no solver or search is involved. *)
module Names = Map.Make (String)
module Bits = Set.Make (Int)
module Keys = Set.Make (String)

type summary = { returned : Bits.t; retained : Bits.t }
let empty = { returned = Bits.empty; retained = Bits.empty }
let union a b = { returned = Bits.union a.returned b.returned;
                  retained = Bits.union a.retained b.retained }
let equal a b = Bits.equal a.returned b.returned && Bits.equal a.retained b.retained
let indices xs = Bits.of_list xs

let infer ~key ~target ~info ~field_type ~call_type ~alias_type ~explicit ~legacy_return prog =
  let bodies = List.filter_map (function Ast.FuncDef f -> Some f | _ -> None) prog in
  let summaries = ref (List.fold_left (fun rows f ->
    let initial = match explicit (key f) with
      | None -> empty
      | Some (inputs, outputs) ->
          { returned = indices outputs;
            retained = indices (List.filter (fun i -> not (List.mem i inputs))
              (List.init (List.length f.Ast.params) Fun.id)) } in
    Names.add (key f) initial rows) Names.empty bodies) in
  let reverse_calls = ref Names.empty in
  let analyze (f : Ast.func) =
    let fi : Types.func_info = info (key f) in
    let bindings = fi.bindings in
    let env = ref Types.IntMap.empty in
    List.iteri (fun i id -> env := Types.IntMap.add id (Bits.singleton i) !env)
      bindings.param_ids;
    let returned = ref Bits.empty and retained = ref Bits.empty in
    let changed = ref false in
    let add id origins =
      let old = Option.value (Types.IntMap.find_opt id !env) ~default:Bits.empty in
      let next = Bits.union old origins in
      if not (Bits.equal old next) then (changed := true;
        env := Types.IntMap.add id next !env) in
    let get e = Option.bind (Local_bindings.id_for_expr bindings e)
      (fun id -> Types.IntMap.find_opt id !env)
      |> Option.value ~default:Bits.empty in
    let retain origins = retained := Bits.union !retained origins in
    let rec peel = function
      | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t
      | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _) -> peel t
      | t -> t in
    let rec ty (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Option.bind (Local_bindings.id_for_expr bindings e)
          (fun id -> Types.IntMap.find_opt id fi.binding_types)
      | Ast.Cast (t, _) -> Some t
      | Ast.Call (name, _) -> call_type (target e name)
      | Ast.FieldGet (base, name) -> Option.bind (ty base) (fun t ->
          match peel t with
          | Ast.TypeSlice _ when name = "len" -> Some Ast.TypeUsize
          | Ast.TypePtr t | Ast.TypeAlignedPtr (_, t) | Ast.TypeRef t
          | Ast.TypeRefMut t -> field_type (peel t) name
          | t -> field_type t name)
      | Ast.Deref base -> Option.bind (ty base) (fun t -> match peel t with
          | Ast.TypePtr t | Ast.TypeAlignedPtr (_, t) | Ast.TypeRef t
          | Ast.TypeRefMut t -> Some t | _ -> None)
      | Ast.Index (base, _) -> Option.bind (ty base) (fun t -> match peel t with
          | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _, _)
          | Ast.TypePtr t | Ast.TypeAlignedPtr (_, t) -> Some t | _ -> None)
      | Ast.Unsafe x -> ty x
      | _ -> None in
    let alias_result e = Option.fold ~none:true ~some:(function
      | Ast.TypeArray _ -> true
      | ty -> alias_type ty) (ty e) in
    let rec root (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Some e
      | Ast.FieldGet (base, _) | Ast.Index (base, _) -> root base
      | _ -> None in
    let local_storage e = match root e with
      | None -> None
      | Some base ->
          Option.bind (Local_bindings.id_for_expr bindings base) (fun id ->
            match Option.map peel (ty base) with
            | Some (Ast.TypePtr _ | Ast.TypeAlignedPtr _ | Ast.TypeRef _
                   | Ast.TypeRefMut _ | Ast.TypeSlice _) -> None
            | _ -> Some id) in
    let union_values xs = List.fold_left Bits.union Bits.empty xs in
    let rec place (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> get e
      | Ast.FieldGet (base, _) -> place base
      | Ast.Index (base, index) -> ignore (expr index); place base
      | Ast.Deref base -> expr base
      | _ -> expr e
    and expr (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> get e
      | Ast.AddrOf x -> place x
      | Ast.Cast (Ast.TypeSlice _, x) -> place x
      | Ast.Cast (_, x) | Ast.Unsafe x | Ast.Bnot x -> expr x
      | Ast.FieldGet (base, _) | Ast.Deref base ->
          let origins = expr base in if alias_result e then origins else Bits.empty
      | Ast.Index (base, index) ->
          let origins = expr base in ignore (expr index);
          if alias_result e then origins else Bits.empty
      | Ast.SliceOf (base, lo, hi) ->
          let origins = place base in ignore (expr lo); ignore (expr hi); origins
      | Ast.StructLit xs | Ast.TupleLit xs -> union_values (List.map expr xs)
      | Ast.VariantCtor (_, _, x) -> expr x
      | Ast.BinOp (op, a, b) ->
          let origins = Bits.union (expr a) (expr b) in
          (match op with
           | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod
           | Ast.Bor | Ast.Bxor | Ast.Band | Ast.Shr | Ast.Shl -> origins
           | _ -> Bits.empty)
      | Ast.Assign (lhs, rhs) ->
          let origins = expr rhs in
          ignore (place lhs);
          (match local_storage lhs with Some id -> add id origins | None -> retain origins);
          origins
      | Ast.Call (name, args) ->
          let values = List.map expr args in
          let select bits = Bits.fold (fun i origins ->
            match List.nth_opt values i with
            | None -> origins | Some value -> Bits.union origins value) bits Bits.empty in
          let callee = target e name in
          if Names.mem callee !summaries then begin
            let callers = Option.value (Names.find_opt callee !reverse_calls)
              ~default:Keys.empty in
            reverse_calls := Names.add callee (Keys.add (key f) callers) !reverse_calls
          end;
          (match explicit callee with
           | Some (inputs, outputs) ->
               List.iteri (fun i origins -> if not (List.mem i inputs) then retain origins) values;
               select (indices outputs)
           | None ->
               match Names.find_opt callee !summaries with
               | Some summary ->
                   let escaping = if legacy_return callee
                     then Bits.union summary.retained summary.returned
                     else summary.retained in
                   retain (select escaping); select summary.returned
               | None when List.mem callee ["zero_fill"; "slice_eq"; "min"; "max"] ->
                   if callee = "min" || callee = "max" then union_values values else Bits.empty
               | None when Atomic_spec.is_cell_op callee ->
                   List.iteri (fun i value -> if i > 0 then retain value) values; Bits.empty
               | None -> let origins = union_values values in retain origins; origins)
      | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.ByteSliceLit _
      | Ast.ViewLit _ | Ast.EnumVariant _ | Ast.SizeOf _ | Ast.AlignOf _
      | Ast.ContainsStableOwner _ | Ast.OffsetOf _ | Ast.EmbedFile _ -> Bits.empty
    and arm value loc index = function
      | Ast.ArmVariant (_, _, pattern, body) ->
          (match pattern with
           | Some (Ast.PayloadBind _) ->
               Option.iter (fun id -> add id value)
                 (Local_bindings.id_for_arm bindings loc index)
           | _ -> ()); stmts body
      | Ast.ArmWild body | Ast.ArmMiss body | Ast.ArmIntLit (_, body)
      | Ast.ArmByteSliceLit (_, body) -> stmts body
    and stmt (s : Ast.stmt) = match s.desc with
      | Ast.Let (_, _, _, init, _) ->
          let origins = Option.fold ~none:Bits.empty ~some:expr init in
          List.iter (fun id -> add id origins) (Local_bindings.ids_for_stmt bindings s); Bits.empty
      | Ast.LetTuple (_, rhs) ->
          let origins = expr rhs in
          List.iter (fun id -> add id origins) (Local_bindings.ids_for_stmt bindings s); Bits.empty
      | Ast.Return value ->
          Option.iter (fun e -> returned := Bits.union !returned (expr e)) value; Bits.empty
      | Ast.Yield value -> expr value
      | Ast.Expr value | Ast.StaticAssert (value, _) -> ignore (expr value); Bits.empty
      | Ast.Block body | Ast.UnsafeBlock body -> stmts body
      | Ast.If (cond, yes, no) -> ignore (expr cond); Bits.union (stmts yes) (stmts no)
      | Ast.While (cond, body) -> ignore (expr cond); ignore (stmts body); Bits.empty
      | Ast.For (_, _, lo, hi, body) ->
          ignore (expr lo); ignore (expr hi); ignore (stmts body); Bits.empty
      | Ast.ForEach (_, collection, body) ->
          let origins = expr collection in
          List.iter (fun id ->
            if Option.fold ~none:true ~some:alias_type
                (Types.IntMap.find_opt id fi.binding_types) then add id origins)
            (Local_bindings.ids_for_stmt bindings s);
          ignore (stmts body); Bits.empty
      | Ast.Match (disc, arms) ->
          let value = expr disc in
          union_values (List.mapi (arm value s.loc) arms)
      | Ast.LetMatch (_, _, _, disc, arms) ->
          let value = expr disc in
          let origins = union_values (List.mapi (arm value s.loc) arms) in
          List.iter (fun id -> add id origins) (Local_bindings.ids_for_stmt bindings s); Bits.empty
      | Ast.Break | Ast.Continue -> Bits.empty
    and stmts body = union_values (List.map stmt body) in
    (* Each pass only adds parameter bits to a finite set of binding IDs. *)
    changed := true;
    while !changed do changed := false; ignore (stmts f.body) done;
    { returned = !returned; retained = !retained }
  in
  let definitions = List.fold_left (fun rows f -> Names.add (key f) f rows)
    Names.empty bodies in
  let pending = ref Keys.empty and queue = Queue.create () in
  let enqueue name =
    if explicit name = None && not (Keys.mem name !pending) then begin
      pending := Keys.add name !pending; Queue.add name queue
    end in
  List.iter (fun f -> enqueue (key f)) bodies;
  let visits = ref 0 in
  while not (Queue.is_empty queue) do
    let name = Queue.take queue in
    pending := Keys.remove name !pending;
    incr visits;
    let old = Names.find name !summaries in
    let next = union old (analyze (Names.find name definitions)) in
    if not (equal old next) then begin
      summaries := Names.add name next !summaries;
      Keys.iter enqueue (Option.value (Names.find_opt name !reverse_calls)
        ~default:Keys.empty)
    end
  done;
  (!summaries, !visits)
