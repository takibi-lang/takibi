(* Bounded runtime order contracts. This graph proves only transitive < and
   <= relations between stable local values/extents and normalized statics.
   It evaluates no arithmetic and has no solver or ownership semantics. *)
open Ast

module StringSet = Set.Make (String)

type facet = Value | Length | Count
type static_key = ((int * int) list * int) list
type node = Local of int * string * facet | Static of static_key
type edge = node * bool * node  (* true means strictly less *)
type t = edge list

let empty = []
let add a cmp b facts = (a, cmp = WhereLt, b) :: facts
let equate a b facts = (a, false, b) :: (b, false, a) :: facts

let proves facts a cmp b =
  let rec visit seen = function
    | [] -> false
    | (n, strict) :: rest ->
        if n = b && (cmp = WhereLe || strict) then true
        else if List.mem (n, strict) seen then visit seen rest
        else
          let next = List.filter_map (fun (src, step, dst) ->
            if src = n then Some (dst, strict || step) else None) facts in
          visit ((n, strict) :: seen) (next @ rest)
  in visit [] [a, false]

let local bindings (e : expr) facet = match e.desc with
  | Var name -> Option.map (fun id -> Local (id, name, facet))
      (Local_bindings.Expr_table.find_opt bindings.Local_bindings.expr_ids e)
  | _ -> None

let expr ?(is_region = fun _ -> false) bindings (e : expr) =
  match e.desc with
  | Var _ -> local bindings e Value
  | FieldGet (base, "len") -> local bindings base Length
  | Call ("region_count", [base])
    when is_region base
         && not (Local_bindings.Expr_table.mem bindings.Local_bindings.expr_ids e) ->
      local bindings base Count
  | _ -> None

let condition ~node facts cond =
  let rec go facts (e : expr) = match e.desc with
    | BinOp (And, a, b) -> go (go facts a) b
    | BinOp ((Lt | Le | Gt | Ge as op), a, b) ->
        (match node a, node b with
         | Some a, Some b ->
             (match op with
              | Lt -> add a WhereLt b facts | Le -> add a WhereLe b facts
              | Gt -> add b WhereLt a facts | Ge -> add b WhereLe a facts
              | _ -> assert false)
         | _ -> facts)
    | _ -> facts
  in go facts cond

let without names facts =
  let alive = function Static _ -> true | Local (_, name, _) -> not (List.mem name names) in
  List.filter (fun (a, _, b) -> alive a && alive b) facts

let scanned_names ~addresses_only (stmts : Ast.stmt list) : string list =
  let acc = ref StringSet.empty in
  let add_address n = acc := StringSet.add n !acc in
  let add n = if not addresses_only then add_address n in
  let rec go_expr (e : Ast.expr) = match e.desc with
    | AddrOf { desc = Var n; _ } -> add_address n
    | AddrOf e1 | Bnot e1 | Deref e1 | Cast (_, e1) | FieldGet (e1, _)
    | Unsafe e1 ->
        go_expr e1
    | BinOp (_, a, b) -> go_expr a; go_expr b
    | Call (_, args) | StructLit args | TupleLit args -> List.iter go_expr args
    | VariantCtor (_, _, payload) -> go_expr payload
    | Index (base, idx) -> go_expr base; go_expr idx
    | SliceOf (base, lo, hi) -> go_expr base; go_expr lo; go_expr hi
    | Assign (lhs, rhs) ->
        (match lhs.desc with
         | Var n -> add n
         | Index (base, idx) -> go_expr base; go_expr idx   (* writing n[i] does not rebind n *)
         | Deref p -> go_expr p
         | FieldGet (b, _) -> go_expr b
         | _ -> go_expr lhs);
        go_expr rhs
    | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _ | ViewLit _
    | EnumVariant _ | SizeOf _ | AlignOf _ | ContainsStableOwner _
    | OffsetOf _ | EmbedFile _ ->
        ()
  in
  let rec go_stmt (s : Ast.stmt) = match s.desc with
    | Let (_, n, _, init, _) -> add n; (match init with
                                        | Some e -> go_expr e | None -> ())
    | LetTuple (ns, e)       -> List.iter add ns; go_expr e
    | Expr e | Return (Some e) | Yield e -> go_expr e
    | Return None            -> ()
    | Block ss | UnsafeBlock ss -> List.iter go_stmt ss
    | If (c, t, el)          -> go_expr c;
                                List.iter go_stmt t; List.iter go_stmt el
    | While (c, b)           -> go_expr c; List.iter go_stmt b
    | For (n, _, lo, hi, b)  -> add n; go_expr lo; go_expr hi;
                                List.iter go_stmt b
    | ForEach (n, se, b)     -> add n; go_expr se; List.iter go_stmt b
    | Break | Continue       -> ()
    | StaticAssert (e, _)    -> go_expr e
    | Match (d, arms)        ->
        go_expr d;
        List.iter (function
          | Ast.ArmVariant (_, _, binding, b) ->
              Option.iter (function Ast.PayloadBind (name, _) -> add name
                                    | Ast.PayloadIgnore -> ()) binding;
              List.iter go_stmt b
          | ArmWild b -> List.iter go_stmt b
          | ArmIntLit (_, b) | ArmByteSliceLit (_, b) -> List.iter go_stmt b
        ) arms
    | LetMatch (_, n, _, d, arms) ->
        add n; go_expr d;
        List.iter (function
          | Ast.ArmVariant (_, _, binding, b) ->
              Option.iter (function Ast.PayloadBind (name, _) -> add name
                                    | Ast.PayloadIgnore -> ()) binding;
              List.iter go_stmt b
          | ArmWild b -> List.iter go_stmt b
          | ArmIntLit (_, b) | ArmByteSliceLit (_, b) -> List.iter go_stmt b
        ) arms
  in
  List.iter go_stmt stmts;
  StringSet.elements !acc

let rebind_names stmts = scanned_names ~addresses_only:false stmts
let address_taken_names stmts = scanned_names ~addresses_only:true stmts
