(* Body-derived write footprints for initialization certificates. Paths name
   storage relative to a reference or slice parameter or a named global.
   Unknown calls, raw addresses and unresolved aliases remain conservative.
   No effect annotation is trusted as a write set, and no runtime
   instrumentation is emitted. *)
module StringMap = Map.Make (String)
type root = Parameter of int | Global of string
module Paths = Set.Make (struct
  type t = root * string list
  let compare = compare
end)
type t = Unknown | Writes of Paths.t
let empty = Writes Paths.empty
let union a b = match a, b with
  | Writes a, Writes b -> Writes (Paths.union a b)
  | _ -> Unknown
let unions xs = List.fold_left union empty xs
let rec collect f = function
  | [] -> empty
  | x :: xs -> match f x with
      | Unknown -> Unknown
      | known -> union known (collect f xs)
let rec strip = function
  | Ast.TypeRefined (_, _, t) | Ast.TypeMultiple (_, t)
  | Ast.TypeSingleton (t, _) | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> strip t
  | t -> t
let scalar ty = match strip ty with
  | Ast.TypeBool | Ast.TypeI8 | Ast.TypeI16 | Ast.TypeI32 | Ast.TypeI64
  | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU32 | Ast.TypeU64
  | Ast.TypeUsize | Ast.TypeIsize -> true
  | _ -> false
(* Read-only here describes the instruction's own memory writes, not the
   stability of shared memory or the effects of evaluating its arguments.
   Keep traps, interrupt restoration and all modifying atomics unknown. *)
let builtin_has_no_writes name =
  let atomic_name = Option.value ~default:name (Atomic_spec.cell_intrinsic name) in
  match Atomic_spec.find atomic_name, Instr_spec.find name with
  | Some { Atomic_spec.operation = Atomic_spec.Load; _ }, _ -> true
  | _, Some { Instr_spec.shape = Instr_spec.Read; _ } -> true
  | _ -> name = "slice_eq"
(* After indexing, retain the whole array or slice rather than a field
   path below its leaf. This deliberately overapproximates element writes. *)
type place = { root : root; path : string list; ty : Ast.type_expr; indexed : bool }
type context = { info : Types.func_info; fdef : Ast.func; aliases : Ast.expr Types.IntMap.t ref }
let infer ?(global_view_origin = fun _ _ _ -> None) ~definition ~target ~struct_fields ~global_type () =
  let cache = ref StringMap.empty in
  let binding info e =
    Local_bindings.Expr_table.find_opt info.Types.bindings.expr_ids e in
  let rec place ?(seen = []) ctx (e : Ast.expr) =
    let info = ctx.info in
    match e.desc with
    | Ast.Var name ->
        (match binding info e with
        | None -> (match Option.map strip (global_type name) with
            | Some (Ast.TypePtr _ | Ast.TypeRef _ | Ast.TypeRefMut _) | None -> None
            | Some ty -> Some {root = Global name; path = []; ty; indexed = false})
        | Some id ->
          let rec position i = function
            | [] -> None
            | x :: xs -> if x = id then Some i else position (i + 1) xs in
          match position 0 info.Types.bindings.param_ids with
          | Some param ->
              (match Option.map strip (Types.IntMap.find_opt id info.binding_types) with
               | Some (Ast.TypeRef ty | Ast.TypeRefMut ty) ->
                   Some {root = Parameter param; path = []; ty; indexed = false}
               | Some (Ast.TypeSlice _ as ty) ->
                   Some {root = Parameter param; path = []; ty; indexed = false}
               | _ -> None)
          | None when not (List.mem id seen) ->
              (match Option.map strip (Types.IntMap.find_opt id info.binding_types) with
               | Some (Ast.TypeRef _ | Ast.TypeRefMut _ | Ast.TypePtr _) ->
                   Option.bind (Types.IntMap.find_opt id !(ctx.aliases))
                     (place ~seen:(id :: seen) ctx)
               | _ -> None)
          | None -> None)
    | Ast.FieldGet (base, field) ->
        Option.bind (place ~seen ctx base) (fun p ->
          match strip p.ty with
          | Ast.TypeNamed n | Ast.TypeIndexed (n, _) ->
              Option.bind (struct_fields n) (fun fields ->
                Option.map (fun ty -> {p with ty;
                  path = if p.indexed then p.path else p.path @ [field]})
                  (List.assoc_opt field fields))
          | _ -> None)
    | Ast.Index (base, _) ->
        Option.bind (place ~seen ctx base) (fun p -> match strip p.ty with
          | Ast.TypeArray (ty, _) | Ast.TypeSlice (ty, _, _) ->
              Some {p with ty; indexed = true}
          | _ -> None)
    (* &p addresses the local reference slot, not the object p refers to.
       Treating it as p would miss mutations after rebinding that slot. *)
    | Ast.AddrOf {desc = Ast.Var _; _} -> None
    | Ast.AddrOf e | Ast.Unsafe e -> place ~seen ctx e
    | Ast.Deref ({desc = Ast.Var _; _} as e) -> place ~seen ctx e
    | _ -> None in
  let rec function_writes key =
    match StringMap.find_opt key !cache with
    | Some result -> result
    | None ->
        (* Recursion cannot assume the frame property being proved. *)
        cache := StringMap.add key Unknown !cache;
        let result = match definition key with
          | None -> Unknown
          | Some (f, info) -> statements {info; fdef = f; aliases = ref Types.IntMap.empty} f.Ast.body in
        cache := StringMap.add key result !cache;
        result
  and call e = match target e with
    | Some key -> function_writes key
    | None -> (match e.Ast.desc with
        | Ast.Call (name, _) when builtin_has_no_writes name -> empty
        | _ -> Unknown)
  and expression ctx (e : Ast.expr) =
    let info = ctx.info in
    let expr = expression ctx in
    match e.desc with
    | Ast.Call (_, args) ->
        let writes = match call e with
          | Unknown -> Unknown
          | Writes paths -> Paths.fold (fun (root, suffix) acc ->
              match root with
              | Global _ -> union acc (Writes (Paths.singleton (root, suffix)))
              | Parameter i ->
                  match Option.bind (List.nth_opt args i) (place ctx) with
                  | None -> Unknown
                  | Some p -> union acc (Writes (Paths.singleton
                      (p.root, if p.indexed then p.path else p.path @ suffix)))) paths empty in
        union writes (collect expr args)
    | Ast.Assign (lhs, rhs) ->
        let writes = match lhs.desc with
          | Ast.Var _ when Option.is_some (binding info lhs) ->
              (match Option.bind (binding info lhs) (fun id ->
                 Types.IntMap.find_opt id info.Types.binding_types) with
               | Some ty when scalar ty -> empty
               | _ -> Unknown)
          | _ -> (match place ctx lhs with
              | Some p -> Writes (Paths.singleton (p.root, p.path))
              | None -> (match lhs.desc with
                  | Ast.Index (base, _) -> (match global_view_origin info ctx.fdef base with
                      | Some name -> Writes (Paths.singleton (Global name, []))
                      | None -> Unknown)
                  | _ -> Unknown)) in
        unions [writes; expr lhs; expr rhs]
    | Ast.VariantCtor (_, _, x) | Ast.Bnot x | Ast.Deref x
    | Ast.AddrOf x | Ast.Cast (_, x) | Ast.FieldGet (x, _) | Ast.Unsafe x -> expr x
    | Ast.BinOp (_, a, b) | Ast.Index (a, b) -> union (expr a) (expr b)
    | Ast.SliceOf (a, b, c) -> unions [expr a; expr b; expr c]
    | Ast.StructLit xs | Ast.TupleLit xs -> collect expr xs
    | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.ByteSliceLit _
    | Ast.Var _ | Ast.ViewLit _ | Ast.EnumVariant _ | Ast.SizeOf _
    | Ast.ContainsStableOwner _ | Ast.AlignOf _ | Ast.OffsetOf _ | Ast.EmbedFile _ -> empty
  and statements ctx body = collect (statement ctx) body
  and statement ctx (s : Ast.stmt) =
    let expr = expression ctx and body = statements ctx in
    let arms xs = collect (fun arm -> body (Control_flow.arm_body arm)) xs in
    match s.desc with
    | Ast.Let (false, _, _, Some init, _) ->
        let writes = expr init in
        (* An immutable reference alias keeps the address it captured. Do
           not mistake loading a pointer field for taking its address. *)
        let rec address_alias (e : Ast.expr) = match e.desc with
          | Ast.Var _ | Ast.AddrOf _ -> true
          | Ast.Unsafe e -> address_alias e
          | _ -> false in
        if address_alias init then
          (match Local_bindings.ids_for_stmt ctx.info.bindings s with
           | [id] -> ctx.aliases := Types.IntMap.add id init !(ctx.aliases)
           | _ -> ());
        writes
    | Ast.Return e | Ast.Let (_, _, _, e, _) -> Option.fold ~none:empty ~some:expr e
    | Ast.Expr e | Ast.Yield e | Ast.LetTuple (_, e) | Ast.StaticAssert (e, _) -> expr e
    | Ast.Block ss | Ast.UnsafeBlock ss -> body ss
    | Ast.If (c, yes, no) -> unions [expr c; body yes; body no]
    | Ast.While (c, ss) | Ast.ForEach (_, c, ss) -> union (expr c) (body ss)
    | Ast.For (_, _, lo, hi, ss) -> unions [expr lo; expr hi; body ss]
    | Ast.Match (e, xs) | Ast.LetMatch (_, _, _, e, xs) -> union (expr e) (arms xs)
    | Ast.Break | Ast.Continue -> empty
  in
  call
