(* GitHub issue #203, stages 1 and 2: definite initialization of field
   paths, checked per function after type inference.

   The model is a static, erased init state on storage, the compile-time
   counterpart of Place(T)'s runtime Empty/Full. A tracked place is split
   into LEAVES: a scalar, pointer, slice or array is one leaf; a struct is
   the leaves of its fields plus one padding leaf `#pad` when its layout has
   bytes between or after its fields. The state at a program point is the
   set of leaves that may be uninitialized there ("maybe uninit"), so a
   merge of two paths is a union, the dual of C#/Swift definite assignment.

   Tracked roots:
   - a local declared without an initializer whose type is not an array
     (stage 1 tracks arrays only inside scratch globals; uninitialized local
     arrays remain unchecked, as SPEC.md records);
   - a `borrow uninit` parameter, which starts uninit and must be fully
     initialized at every return (an out parameter, C# `out`);
   - a `scratch` global, all of whose leaves are uninit at function entry,
     whatever an earlier call left there. Any index of a scratch array
     global is the same path: the per-CPU exclusivity of its element is a
     trusted premise (TRUSTED_BASE.md).

   Events:
   - reading a place needs every leaf under it initialized, padding
     excepted (a whole struct value copies fields), and so does taking its
     typed address `&p`; reinterpreting it with `as` (`p as []u8`,
     `&p as *u8`, `&p as usize`) or sub-slicing it needs padding too;
   - assigning a place initializes every field leaf under it; padding
     takes the source's padding state (a tracked place) or stays as it was
     marked: a struct literal (only ever a `let` initializer) leaves
     padding uninit, an untracked value
     (a call result, a parameter) counts as initialized;
   - a store into an element of an array leaf changes nothing (stage 1
     has no ranges) and reads nothing, except the whole-length counted
     loop of `filled_by_loop` (#888);
   - zero_fill(p), unsafe assume_init(p), passing p (or `p as []T`, `&p`)
     to a `borrow uninit` parameter initialize everything under p, padding
     included. Passing `&p` to a `&mut T` parameter initializes its field
     leaves but not its padding: the callee is trusted to store every
     field, until stage 3 contracts replace that trust (TRUSTED_BASE.md).

   A loop body may run no times, so the state after a loop is the state
   before it; the body is checked against that same state, which is a
   superset of what any later iteration sees. *)

module StringMap = Map.Make (String)

type leaf = string * string list   (* root key, field path *)

module Leaves = Set.Make (struct
  type t = leaf
  let compare = compare
end)

let pad = "#pad"

type root = {
  display : string;
  leaves : (string list * Ast.type_expr) list;
  array_root : bool;     (* `g[i]` names the same path as `g` *)
  out_param : bool;      (* borrow uninit: must be init at return *)
}

type place = { root : string; path : string list; inside : bool }
(* `inside`: the place is within a leaf (an element of an array leaf, or a
   field reached through a pointer leaf), not a whole leaf or more. *)

let rec strip (t : Ast.type_expr) = match t with
  | Ast.TypeRefined (_, _, b) | Ast.TypeMultiple (_, b)
  | Ast.TypeSingleton (b, _) | Ast.TypeExists (_, _, b) -> strip b
  | t -> t

let rec is_prefix a b = match a, b with
  | [], _ -> true
  | x :: a', y :: b' -> x = y && is_prefix a' b'
  | _ :: _, [] -> false

let rec drop n l = if n = 0 then l else match l with
  | [] -> [] | _ :: t -> drop (n - 1) t

let is_pad path = match List.rev path with p :: _ -> p = pad | [] -> false

let path_to_string display path =
  String.concat "." (display :: List.filter (fun f -> f <> pad) path)

(* Struct layout lives in Type_layout, which depends on LLVM generation and
   so cannot be called from here (Type_inf calls this module). Type_layout
   installs its size function at load time. *)
let layout_size : (Ast.type_expr -> int option) ref = ref (fun _ -> None)

(* GitHub issue #954: the flow state. [u] is the set of leaves that may be
   uninitialized (as before); [iv] holds, for a leaf in [u] that is an array
   or slice, intervals of its elements known initialized (Init_pred); [eqs]
   are linear equalities known on the path. *)
type state = {
  u : Leaves.t;
  iv : (leaf * Init_pred.interval) list;
  eqs : Init_pred.eqs;
  facts : Init_pred.facts;   (* GitHub issue #975: linear path facts *)
}

(* A tracked view of an array or slice leaf: elements [off, off + len) of
   the leaf at [vp]. *)
type view = { vp : place; off : Init_pred.lin; len : Init_pred.lin option }

(* A fact a call establishes: elements [lo, hi) (callee terms already mapped
   into the caller, except the atoms "result" and binder names) of a leaf. *)
type fact = place * Init_pred.interval

type guarded =
  | GBool of bool * (view * Init_pred.interval) list
      (* holds when result = the bool *)
  | GCase of string option * string option * (view * Init_pred.interval) list
      (* case (None: any other case), payload binder atom, facts *)

let check
    ~(struct_fields : string -> (string * Ast.type_expr) list option)
    ~(callee : string -> ((Ast.ident * Ast.type_expr option) list * Ast.loc) option)
    ~(scratch : (string * Ast.type_expr) list)
    ?(variant_cases : string -> (string * bool) list option = fun _ -> None)
    ?(linear_owner : string -> bool = fun _ -> false)
    ?(variant_payload : string -> string -> Ast.type_expr option = fun _ _ -> None)
    ?(callee_ret : string -> Ast.type_expr option = fun _ -> None)
    (finfo : Types.func_info) (fdef : Ast.func) =
  let bindings = finfo.Types.bindings in
  (* GitHub issue #763: every independent error is recorded, in traversal
     order; a read that reports marks its offending leaves initialized
     afterwards, so reads derived from it do not cascade. Recording never
     changes a verdict: any recorded error rejects the function. *)
  let errors = ref [] in
  let error loc msg = errors := (loc, msg) :: !errors in
  let size_of t = !layout_size t in
  (* Unknown layout counts as padded: viewing it as bytes then needs a
     zero fill, which is the sound direction. *)
  let has_padding name fields =
    let sizes = List.map (fun (_, t) -> size_of t) fields in
    match size_of (Ast.TypeNamed name) with
    | Some total when List.for_all Option.is_some sizes ->
        List.fold_left (fun acc s -> acc + Option.get s) 0 sizes < total
    | _ -> true
  in
  let rec leaves_of prefix seen ty =
    match strip ty with
    | (Ast.TypeNamed n | Ast.TypeIndexed (n, _)) when not (List.mem n seen) ->
        (match struct_fields n with
         | Some fields ->
             List.concat_map (fun (f, fty) ->
               leaves_of (prefix @ [f]) (n :: seen) fty) fields
             @ (if has_padding n fields then [(prefix @ [pad], Ast.TypeVoid)]
                else [])
         | None -> [(prefix, ty)])
    | t -> [(prefix, t)]
  in
  let roots : (string, root) Hashtbl.t = Hashtbl.create 8 in
  let all_leaves key =
    match Hashtbl.find_opt roots key with
    | Some r -> List.map (fun (p, _) -> (key, p)) r.leaves
    | None -> []
  in
  let leaf_type key path =
    match Hashtbl.find_opt roots key with
    | Some r -> List.assoc_opt path r.leaves
    | None -> None
  in
  (* Scratch globals: every leaf uninit at entry. *)
  let scratch_names = List.fold_left (fun m (n, t) -> StringMap.add n t m)
      StringMap.empty scratch in
  StringMap.iter (fun name ty ->
    let (elem, array_root) = match strip ty with
      | Ast.TypeArray (e, _) -> (e, true)
      | t -> (t, false) in
    Hashtbl.replace roots ("G" ^ name)
      { display = (if array_root then name ^ "[_]" else name);
        leaves = leaves_of [] [] elem; array_root; out_param = false })
    scratch_names;
  let entry_u = Hashtbl.fold (fun key _ acc ->
    List.fold_left (fun s l -> Leaves.add l s) acc (all_leaves key))
    roots Leaves.empty in
  (* Parameter ids by name, and the pointee of each `borrow uninit`. *)
  let param_ids = List.combine (List.map fst fdef.Ast.params)
      bindings.Local_bindings.param_ids in
  let param_types = List.filter_map (fun (n, t) ->
    Option.map (fun t -> (n, t)) t) fdef.Ast.params in
  (* borrow uninit parameters. *)
  let entry_u = List.fold_left2 (fun st (name, ty) id ->
    match ty, Init_state.param_qual fdef.Ast.def_loc name with
    | Some ty, Some Init_state.Uninit ->
        let pointee = match strip ty with
          | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> strip t
          | t -> t in
        let pointee = match pointee with
          | Ast.TypeRefMut t | Ast.TypePtr t | Ast.TypeRef t -> t
          | t -> t in
        let key = "L" ^ string_of_int id in
        Hashtbl.replace roots key
          { display = name; leaves = leaves_of [] [] pointee;
            array_root = false; out_param = true };
        List.fold_left (fun s l -> Leaves.add l s) st (all_leaves key)
    | _ -> st) entry_u fdef.Ast.params bindings.Local_bindings.param_ids in
  let contracts = Init_state.contracts_of fdef.Ast.def_loc in
  (* GitHub issue #975: parameters a requires clause names. Such a
     parameter that is not `borrow uninit` is tracked too, initialized at
     entry exactly where the clause says, so the body is checked against
     the clause rather than against a whole-init default. *)
  let required_params cs =
    List.concat_map (fun (c : Init_state.clause) ->
      match c.body with
      | Init_state.CPlain (Init_state.PInit e) when c.requires ->
          let rec base (e : Ast.expr) = match e.desc with
            | Ast.SliceOf (b, _, _) -> base b
            | Ast.Var x -> [x]
            | _ -> [] in
          base e
      | _ -> []) cs in
  let own_required = required_params contracts in
  let entry_u = List.fold_left2 (fun st (name, ty) id ->
    let key = "L" ^ string_of_int id in
    match ty with
    | Some ty when List.mem name own_required && not (Hashtbl.mem roots key) ->
        let pointee = match strip ty with
          | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> strip t
          | t -> t in
        let pointee = match pointee with
          | Ast.TypeRefMut t | Ast.TypePtr t | Ast.TypeRef t -> t
          | t -> t in
        Hashtbl.replace roots key
          { display = name; leaves = leaves_of [] [] pointee;
            array_root = false; out_param = false };
        List.fold_left (fun s l -> Leaves.add l s) st (all_leaves key)
    | _ -> st) entry_u fdef.Ast.params bindings.Local_bindings.param_ids in
  (* ---- immutable bindings: the atoms of linear terms ------------------- *)
  let mutable_ids = Hashtbl.create 16 in
  let binding_names = Hashtbl.create 16 in
  let rec scan_stmts ss = List.iter scan_stmt ss
  and scan_stmt (s : Ast.stmt) =
    (match s.desc, Local_bindings.ids_for_stmt bindings s with
     | (Ast.Let (_, n, _, _, _) | Ast.LetMatch (_, n, _, _, _)), id :: _
     | Ast.For (n, _, _, _, _), [_; id] -> Hashtbl.replace binding_names id n
     | _ -> ());
    (match s.desc with
     | Ast.Let (true, _, _, _, _) | Ast.LetTuple _ | Ast.LetMatch (true, _, _, _, _) ->
         List.iter (fun id -> Hashtbl.replace mutable_ids id ())
           (Local_bindings.ids_for_stmt bindings s)
     | _ -> ());
    (match s.desc with
     | Ast.Let (_, _, _, Some e, _) | Ast.LetTuple (_, e) | Ast.Expr e
     | Ast.Yield e | Ast.Return (Some e) -> scan_expr e
     | Ast.Block b | Ast.UnsafeBlock b -> scan_stmts b
     | Ast.If (c, a, b) -> scan_expr c; scan_stmts a; scan_stmts b
     | Ast.While (c, b) -> scan_expr c; scan_stmts b
     | Ast.For (_, _, lo, hi, b) -> scan_expr lo; scan_expr hi; scan_stmts b
     | Ast.ForEach (_, e, b) -> scan_expr e; scan_stmts b
     | Ast.Match (d, arms) | Ast.LetMatch (_, _, _, d, arms) ->
         scan_expr d;
         List.iteri (fun i a ->
           (match a, Local_bindings.id_for_arm bindings s.loc i with
            | Ast.ArmVariant (_, _, Some (Ast.PayloadBind (n, _)), _), Some id ->
                Hashtbl.replace binding_names id n
            | _ -> ());
           (match a with
            | Ast.ArmVariant (_, _, Some (Ast.PayloadBind (_, true)), _) ->
                (match Local_bindings.id_for_arm bindings s.loc i with
                 | Some id -> Hashtbl.replace mutable_ids id ()
                 | None -> ())
            | _ -> ());
           match a with
           | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmMiss b
           | Ast.ArmIntLit (_, b) | Ast.ArmByteSliceLit (_, b) -> scan_stmts b) arms
     | _ -> ())
  and scan_expr (_ : Ast.expr) = ()
  in
  scan_stmts fdef.Ast.body;
  (* Bindings assigned as a whole (`x = e`) or address-taken (`&x`) are not
     atoms. By binding id where the name resolves (GitHub issue #975: a
     same-named binding elsewhere in the function stays an atom), else by
     name, conservatively. *)
  let written =
    let acc = Hashtbl.create 8 in
    let note (v : Ast.expr) n =
      match Local_bindings.id_for_expr bindings v with
      | Some id -> Hashtbl.replace acc ("#" ^ string_of_int id) ()
      | None -> Hashtbl.replace acc n () in
    let rec go (e : Ast.expr) = match e.desc with
      | Ast.AddrOf ({ desc = Ast.Var n; _ } as v) -> note v n
      | Ast.Assign (({ desc = Ast.Var n; _ } as v), rhs) -> note v n; go rhs
      | Ast.Assign (l, r) -> go l; go r
      | Ast.AddrOf x | Ast.Bnot x | Ast.Deref x | Ast.Cast (_, x)
      | Ast.FieldGet (x, _) | Ast.Unsafe x | Ast.VariantCtor (_, _, x) -> go x
      | Ast.BinOp (_, a, b) | Ast.Index (a, b) -> go a; go b
      | Ast.SliceOf (a, b, c) -> go a; go b; go c
      | Ast.Call (_, xs) | Ast.StructLit xs | Ast.TupleLit xs -> List.iter go xs
      | _ -> () in
    let rec st (s : Ast.stmt) = match s.desc with
      | Ast.Let (_, _, _, Some e, _) | Ast.LetTuple (_, e) | Ast.Expr e
      | Ast.Return (Some e) | Ast.Yield e -> go e
      | Ast.Block b | Ast.UnsafeBlock b -> List.iter st b
      | Ast.If (c, a, b) -> go c; List.iter st a; List.iter st b
      | Ast.While (c, b) -> go c; List.iter st b
      | Ast.For (_, _, lo, hi, b) -> go lo; go hi; List.iter st b
      | Ast.ForEach (_, e, b) -> go e; List.iter st b
      | Ast.Match (d, arms) | Ast.LetMatch (_, _, _, d, arms) ->
          go d;
          List.iter (function
            | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmMiss b
            | Ast.ArmIntLit (_, b) | Ast.ArmByteSliceLit (_, b) -> List.iter st b) arms
      | _ -> () in
    List.iter st fdef.Ast.body;
    Hashtbl.fold (fun n () l -> n :: l) acc [] in
  let immutable id = not (Hashtbl.mem mutable_ids id) in
  let is_written x id = List.mem x written || List.mem ("#" ^ string_of_int id) written in
  let immutable_var x id = immutable id && not (is_written x id) in
  let v_atom id = Init_pred.atom ("v" ^ string_of_int id) in
  let len_atom id = Init_pred.atom ("len" ^ string_of_int id) in
  let atom_name a =
    let name_of id =
      match List.find_opt (fun (_, i) -> string_of_int i = id) param_ids with
      | Some (n, _) -> n
      | None ->
          (match Hashtbl.find_opt binding_names (int_of_string id) with
           | Some n -> n
           | None -> "#" ^ id) in
    if String.length a > 3 && String.sub a 0 3 = "len" then
      name_of (String.sub a 3 (String.length a - 3)) ^ ".len"
    else if String.length a > 1 && a.[0] = 'v' then
      name_of (String.sub a 1 (String.length a - 1))
    else a in
  let show l = Init_pred.to_string ~name:atom_name l in
  (* ---- places ---------------------------------------------------------- *)
  let rec place (e : Ast.expr) : place option =
    match e.desc with
    | Ast.Var x ->
        (match Local_bindings.id_for_expr bindings e with
         | Some id ->
             let key = "L" ^ string_of_int id in
             if Hashtbl.mem roots key then Some { root = key; path = []; inside = false }
             else None
         | None ->
             if StringMap.mem x scratch_names then
               Some { root = "G" ^ x; path = []; inside = false }
             else None)
    | Ast.FieldGet (base, f) ->
        (match place base with
         | Some p when p.inside -> Some p
         | Some p ->
             (match leaf_type p.root p.path with
              | Some _ -> Some { p with inside = true }   (* through a leaf *)
              | None -> Some { p with path = p.path @ [f] })
         | None -> None)
    | Ast.Index (base, _) ->
        (match place base with
         | Some p when p.path = [] && not p.inside
                       && (match Hashtbl.find_opt roots p.root with
                           | Some r -> r.array_root | None -> false) -> Some p
         | Some p -> Some { p with inside = true }
         | None -> None)
    | Ast.Deref base ->
        (match place base with
         | Some p when p.path = [] && not p.inside
                       && (match Hashtbl.find_opt roots p.root with
                           | Some r -> r.out_param | None -> false) -> Some p
         | Some p -> Some { p with inside = true }
         | None -> None)
    | _ -> None
  in
  let root_display p = match Hashtbl.find_opt roots p.root with
    | Some r -> r.display | None -> p.root in
  let leaf_elem p = match Option.map strip (leaf_type p.root p.path) with
    | Some (Ast.TypeArray (t, _)) | Some (Ast.TypeSlice (t, _, _)) -> Some (strip t)
    | _ -> None in
  (* The length of an array or slice leaf as a term. *)
  let leaf_len p = match Option.map strip (leaf_type p.root p.path) with
    | Some (Ast.TypeArray (_, n)) -> Some (Init_pred.const n)
    | Some (Ast.TypeSlice _) when p.path = [] && String.length p.root > 1
                                 && p.root.[0] = 'L' ->
        Some (len_atom (int_of_string (String.sub p.root 1 (String.length p.root - 1))))
    | _ -> None in
  let aliases : (int, view) Hashtbl.t = Hashtbl.create 8 in
  (* Linear integer terms of the body. *)
  let rec lin (e : Ast.expr) : Init_pred.lin option =
    match e.desc with
    | Ast.IntLit n -> Option.map Init_pred.const (Ast.int_of_intlit n)
    | Ast.Var x ->
        (match Local_bindings.id_for_expr bindings e with
         | Some id when immutable_var x id -> Some (v_atom id)
         | Some _ -> None
         | None -> Option.map Init_pred.const (Const_env.find x))
    | Ast.SizeOf t -> Option.map Init_pred.const (size_of t)
    | Ast.BinOp (Ast.Add, a, b) ->
        (match lin a, lin b with Some x, Some y -> Some (Init_pred.add x y) | _ -> None)
    | Ast.BinOp (Ast.Sub, a, b) ->
        (match lin a, lin b with Some x, Some y -> Some (Init_pred.sub x y) | _ -> None)
    | Ast.BinOp (Ast.Mul, a, b) ->
        (match lin a, lin b with
         | Some x, Some y when Init_pred.SMap.is_empty x.m -> Some (Init_pred.scale x.c y)
         | Some x, Some y when Init_pred.SMap.is_empty y.m -> Some (Init_pred.scale y.c x)
         | _ -> None)
    | Ast.FieldGet (b, "len") ->
        (match view_of b with
         | Some v -> v.len
         | None ->
             (match b.desc, Local_bindings.id_for_expr bindings b with
              | Ast.Var x, Some id when immutable_var x id -> Some (len_atom id)
              | _ -> None))
    | _ -> None
  (* A tracked view: an array or slice leaf, an alias of one, a sub-slice
     of a view with linear bounds, or a same-element `as` slice cast. *)
  and view_of (e : Ast.expr) : view option =
    match e.desc with
    | Ast.Var _ when (match Local_bindings.id_for_expr bindings e with
                      | Some id -> Hashtbl.mem aliases id | None -> false) ->
        Hashtbl.find_opt aliases (Option.get (Local_bindings.id_for_expr bindings e))
    | Ast.SliceOf (b, lo, hi) ->
        (match view_of b, lin lo, lin hi with
         | Some v, Some lo, Some hi ->
             Some { v with off = Init_pred.add v.off lo; len = Some (Init_pred.sub hi lo) }
         | _ -> None)
    | Ast.Cast (t, inner) ->
        (match strip t, view_of inner with
         | (Ast.TypeSlice (el, _, _) | Ast.TypeArray (el, _)), Some v
           when leaf_elem v.vp = Some (strip el) -> Some v
         | _ -> None)
    | _ ->
        (match place e with
         | Some p when not p.inside && leaf_elem p <> None ->
             Some { vp = p; off = Init_pred.const 0; len = leaf_len p }
         | _ -> None)
  in
  (* ---- path facts (GitHub issue #975) ---------------------------------- *)
  let unsigned_ty t = match strip t with
    | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU32 | Ast.TypeU64 | Ast.TypeUsize -> true
    | _ -> false in
  let arm_types : (int, Ast.type_expr) Hashtbl.t = Hashtbl.create 8 in
  let id_type id = match Types.IntMap.find_opt id finfo.Types.binding_types with
    | Some t -> Some t
    | None when Hashtbl.mem arm_types id -> Hashtbl.find_opt arm_types id
    | None ->
        (match List.find_opt (fun (_, i) -> i = id) param_ids with
         | Some (n, _) -> List.assoc_opt n param_types
         | None -> None) in
  let unsigned_id id = match id_type id with Some t -> unsigned_ty t | None -> false in
  (* A comparison side whose mathematical value is its machine value, so a
     fact about it is a fact about the program: a nonnegative constant, an
     immutable unsigned binding, a view's length, or a - b of such sides
     when the facts already show b <= a (no wraparound). Anything else,
     such as a + b, gives no fact. *)
  let rec side (facts : Init_pred.facts) (e : Ast.expr) : Init_pred.lin option =
    let nonneg_const = function
      | Some (l : Init_pred.lin) when Init_pred.SMap.is_empty l.m && l.c >= 0 -> Some l
      | _ -> None in
    match e.desc with
    | Ast.IntLit _ | Ast.SizeOf _ -> nonneg_const (lin e)
    | Ast.Var x ->
        (match Local_bindings.id_for_expr bindings e with
         | Some id when immutable_var x id && unsigned_id id -> Some (v_atom id)
         | Some _ -> None
         | None -> nonneg_const (lin e))
    | Ast.FieldGet (b, "len") when view_of b <> None -> lin e
    | Ast.FieldGet ({ desc = Ast.Var x; _ } as b, "len") ->
        (match Local_bindings.id_for_expr bindings b with
         | Some id when immutable_var x id
                        && (match Option.map strip (id_type id) with
                            | Some (Ast.TypeSlice _) -> true | _ -> false) ->
             Some (len_atom id)
         | _ -> None)
    | Ast.BinOp (Ast.Sub, a, b) ->
        (match side facts a, side facts b with
         | Some x, Some y when Init_pred.entails facts (Init_pred.sub x y) ->
             Some (Init_pred.sub x y)
         | _ -> None)
    | _ -> None
  in
  let add_fact (st : state) t =
    if List.exists (Init_pred.equal t) st.facts.Init_pred.ge then st
    else { st with facts = { st.facts with Init_pred.ge = t :: st.facts.Init_pred.ge } } in
  (* The state on the path where condition [c] evaluated to [b]. Operands
     of `&&` (true) and `||` (false) are assumed left to right, so a later
     operand's subtraction may rely on an earlier operand. *)
  let rec assume (st : state) (c : Ast.expr) (b : bool) : state =
    match c.desc, b with
    | Ast.BinOp (Ast.And, l, r), true | Ast.BinOp (Ast.Or, l, r), false ->
        assume (assume st l b) r b
    | Ast.BinOp ((Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge | Ast.Eq | Ast.Ne) as op, l, r), _ ->
        (match side st.facts l, side st.facts r with
         | Some x, Some y ->
             let one = Init_pred.const 1 in
             let sub = Init_pred.sub in
             let ts = match op, b with
               | Ast.Lt, true | Ast.Ge, false -> [sub (sub y x) one]
               | Ast.Lt, false | Ast.Ge, true -> [sub x y]
               | Ast.Le, true | Ast.Gt, false -> [sub y x]
               | Ast.Le, false | Ast.Gt, true -> [sub (sub x y) one]
               | Ast.Eq, true | Ast.Ne, false -> [sub x y; sub y x]
               | _ -> [] in
             List.fold_left add_fact st ts
         | _ -> st)
    | _ -> st
  in
  (* ---- the state ------------------------------------------------------- *)
  let leaf_of_view v = (v.vp.root, v.vp.path) in
  let ivs_of st l = List.filter_map (fun (l', iv) -> if l' = l then Some iv else None) st.iv in
  (* Record that elements [lo, hi) of the view's leaf are initialized; a
     leaf whose whole length is covered leaves [u]. *)
  let cur_loc = ref fdef.Ast.def_loc in
  let add_iv st (p : place) (iv : Init_pred.interval) =
    let l = (p.root, p.path) in
    if not (Leaves.mem l st.u) || Init_pred.is_empty iv then st
    else
      let st = { st with iv = (l, iv) :: st.iv } in
      match leaf_len p with
      | Some n when Init_pred.uncovered ~eqs:st.eqs ~facts:st.facts (ivs_of st l)
                      (Init_pred.const 0, n) = None ->
          (* The whole leaf is covered: a conclusion z3 re-checks too. *)
          let whole = path_to_string (root_display p) p.path in
          Range_obligation.record_text !cur_loc
            (Init_pred.obligation
               ~claim:(Printf.sprintf "init(%s[0..<%s])" whole (show n))
               ~facts:st.facts st.eqs (ivs_of st l) (Init_pred.const 0, n));
          { st with u = Leaves.remove l st.u;
                    iv = List.filter (fun (l', _) -> l' <> l) st.iv }
      | _ -> st
  in
  (* GitHub issue #975: the linear facts the walk had, for the message. *)
  let path_facts st =
    let f = st.facts in
    let ge = List.rev_map (fun t -> show t ^ " >= 0") f.Init_pred.ge in
    let mins = List.rev_map (fun (x, l, r) ->
      Printf.sprintf "%s = min(%s, %s)" (show (Init_pred.atom x)) (show l) (show r))
      f.Init_pred.mins in
    match ge @ mins with
    | [] -> "; no path facts"
    | fs -> "; path facts: " ^ String.concat ", " fs in
  let need st (v : view) ((a, b) : Init_pred.interval) loc what =
    let l = leaf_of_view v in
    if not (Leaves.mem l st.u) then st
    else
      let ivs = ivs_of st l in
      let whole = path_to_string (root_display v.vp) v.vp.path in
      match Init_pred.uncovered ~eqs:st.eqs ~facts:st.facts ivs (a, b) with
      | None ->
          let claim = Printf.sprintf "init(%s[%s..<%s])" whole (show a) (show b) in
          Range_obligation.record_text loc
            (Init_pred.obligation ~claim ~facts:st.facts st.eqs ivs (a, b));
          st
      | Some _ when ivs = [] ->
          error loc (Printf.sprintf
            "'%s' is %s here, but '%s' is uninitialized on some path to \
             this point" whole what whole);
          { st with u = Leaves.remove l st.u;
                    iv = List.filter (fun (l', _) -> l' <> l) st.iv }
      | Some cur ->
          let known = match ivs with
            | [] -> "none"
            | ivs -> String.concat ", " (List.map (fun (lo, hi) ->
                Printf.sprintf "[%s, %s)" (show lo) (show hi)) (List.rev ivs)) in
          error loc (Printf.sprintf
            "'%s' is %s here, but element %s of it (in [%s, %s)) is not \
             shown initialized on some path to this point; known \
             initialized: %s%s" whole what (show cur) (show a) (show b) known
            (path_facts st));
          { st with u = Leaves.remove l st.u;
                    iv = List.filter (fun (l', _) -> l' <> l) st.iv }
  in
  let need_view st v loc what =
    match v.len with
    | Some n -> need st v (v.off, Init_pred.add v.off n) loc what
    | None ->
        (match leaf_len v.vp with
         | Some n -> need st v (Init_pred.const 0, n) loc what
         | None ->
             (* length unknown: the whole leaf, as before *)
             let l = leaf_of_view v in
             if Leaves.mem l st.u then begin
               let whole = path_to_string (root_display v.vp) v.vp.path in
               error loc (Printf.sprintf
                 "'%s' is %s here, but '%s' is uninitialized on some path to \
                  this point" whole what whole);
               { st with u = Leaves.remove l st.u;
                         iv = List.filter (fun (l', _) -> l' <> l) st.iv }
             end else st)
  in
  let check_read st p ~bytes loc =
    let bad = Leaves.filter (fun (r, l) ->
      r = p.root && (is_prefix p.path l || is_prefix l p.path)
      && (bytes || not (is_pad l))) st.u in
    match Leaves.min_elt_opt bad with
    | None -> st
    | Some (_, l) ->
        let whole = path_to_string (root_display p) p.path in
        if is_pad l then
          error loc (Printf.sprintf
            "'%s' is used as bytes here, but the padding of '%s' is \
             uninitialized; zero_fill it first (a field store never writes \
             padding)" whole (path_to_string (root_display p) (List.rev (List.tl (List.rev l)))))
        else
          error loc (Printf.sprintf
            "'%s' is %s here, but '%s' is uninitialized on some path to \
             this point" whole (if bytes then "viewed as memory" else "read")
            (path_to_string (root_display p) l));
        { st with u = Leaves.diff st.u bad;
                  iv = List.filter (fun (l', _) -> not (Leaves.mem l' bad)) st.iv }
  in
  (* `.len` of a slice or array place reads metadata, not the elements. *)
  let is_len_of (e : Ast.expr) = match e.desc with
    | Ast.FieldGet (base, "len") ->
        view_of base <> None ||
        (match place base with
         | Some p ->
             (match leaf_type p.root p.path with
              | Some t -> (match strip t with
                  | Ast.TypeSlice _ | Ast.TypeArray _ -> true | _ -> false)
              | None -> false)
         | None -> false)
    | _ -> false
  in
  let drop_root_ivs u iv = List.filter (fun (l, _) -> Leaves.mem l u) iv in
  let fill st p =
    if p.inside then st
    else
      let u = Leaves.filter (fun (r, l) -> not (r = p.root && is_prefix p.path l)) st.u in
      { st with u; iv = drop_root_ivs u st.iv }
  in
  (* A `&mut` callee is trusted to store every field; a field store never
     writes padding, so padding keeps its state. *)
  let fill_fields st p =
    if p.inside then st
    else
      let u = Leaves.filter (fun (r, l) ->
        not (r = p.root && is_prefix p.path l && not (is_pad l))) st.u in
      { st with u; iv = drop_root_ivs u st.iv }
  in
  (* ---- contracts -------------------------------------------------------- *)
  (* A contract term over the callee's parameter names, `result` and an arm
     binder, mapped by [env]. *)
  let rec clin (env : string -> [`Val of Init_pred.lin option | `Len of Init_pred.lin option]
                      -> Init_pred.lin option) (e : Ast.expr) =
    match e.desc with
    | Ast.IntLit n -> Option.map Init_pred.const (Ast.int_of_intlit n)
    | Ast.Var x ->
        (match env x (`Val None) with
         | Some t -> Some t
         | None -> Option.map Init_pred.const (Const_env.find x))
    | Ast.SizeOf t -> Option.map Init_pred.const (size_of t)
    | Ast.FieldGet ({ desc = Ast.Var x; _ }, "len") -> env x (`Len None)
    | Ast.BinOp (Ast.Add, a, b) ->
        (match clin env a, clin env b with Some x, Some y -> Some (Init_pred.add x y) | _ -> None)
    | Ast.BinOp (Ast.Sub, a, b) ->
        (match clin env a, clin env b with Some x, Some y -> Some (Init_pred.sub x y) | _ -> None)
    | Ast.BinOp (Ast.Mul, a, b) ->
        (match clin env a, clin env b with
         | Some x, Some y when Init_pred.SMap.is_empty x.m -> Some (Init_pred.scale x.c y)
         | Some x, Some y when Init_pred.SMap.is_empty y.m -> Some (Init_pred.scale y.c x)
         | _ -> None)
    | _ -> None
  in
  (* The place a contract names, split into its root and optional bounds:
     `x`, `x[lo..<hi]`, `G[s.index].f`, `G[s.index].f[lo..<hi]`. *)
  let rec split_target (e : Ast.expr) = match e.desc with
    | Ast.SliceOf (b, lo, hi) ->
        (match split_target b with
         | Some (r, None) -> Some (r, Some (lo, hi))
         | _ -> None)
    | Ast.Var x -> Some (`Param x, None)
    | Ast.FieldGet _ ->
        let rec chain (e : Ast.expr) acc = match e.desc with
          | Ast.FieldGet (b, f) -> chain b (f :: acc)
          | Ast.Index ({ desc = Ast.Var g; _ }, idx) -> Some (g, idx, acc)
          | _ -> None in
        (match chain e [] with
         | Some (g, idx, path) -> Some (`Global (g, idx, path), None)
         | None -> None)
    | _ -> None
  in
  let slot_capability_rule =
    "a contract may name a global only as a scratch slot reached through a \
     held slot capability, as in syscall_scratch[slot.index].buffer \
     (docs/VERIFICATION_DESIGN.md)" in
  (* Validate a function's own contracts (GitHub issue #954). *)
  let ret_variant = match Option.map strip fdef.Ast.ret_type with
    | Some (Ast.TypeNamed n | Ast.TypeIndexed (n, _) | Ast.TypeVariant (n, _, _)) ->
        variant_cases n
    | _ -> None in
  let ret_is_bool = match Option.map strip fdef.Ast.ret_type with
    | Some Ast.TypeBool -> true | _ -> false in
  let validate_target loc (e : Ast.expr) ~binders =
    let env x _ =
      if x = "result" || List.mem x binders || List.mem_assoc x param_ids
      then Some (Init_pred.atom x) else None in
    match split_target e with
    | None ->
        error loc "init(...) names a parameter, `p[lo..<hi]`, or a scratch \
                   slot `G[s.index].f`"
    | Some (target, bounds) ->
        (match target with
         | `Param x when not (List.mem_assoc x param_ids) ->
             error loc (Printf.sprintf "init(%s): '%s' is not a parameter of '%s'"
                          x x fdef.Ast.name)
         | `Param _ -> ()
         | `Global (g, idx, _) ->
             let ok_idx = match idx.desc with
               | Ast.FieldGet ({ desc = Ast.Var s; _ }, _) ->
                   (match List.assoc_opt s param_types with
                    | Some t ->
                        let rec owner t = match strip t with
                          | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> owner t
                          | Ast.TypeIndexed (n, _) | Ast.TypeNamed n -> linear_owner n
                          | _ -> false in
                        owner t
                    | None -> false)
               | _ -> false in
             if not (StringMap.mem g scratch_names) || not ok_idx then
               error loc slot_capability_rule);
        (match bounds with
         | Some (lo, hi) ->
             List.iter (fun b ->
               if clin env b = None then
                 error loc "an init(...) bound must be a linear integer term \
                            over parameters, their .len, constants and result")
               [lo; hi]
         | None -> ())
  in
  List.iter (fun (c : Init_state.clause) ->
    let preds_of = function
      | Init_state.CPlain p | Init_state.CIf (_, p) -> [(p, [])]
      | Init_state.CMatch arms ->
          List.map (fun (pat, p) ->
            (p, match pat.Init_state.bind with Some b -> [b] | None -> [])) arms in
    List.iter (fun (p, binders) -> match p with
      | Init_state.PInit e -> validate_target c.cloc e ~binders
      | Init_state.PTrue -> ()) (preds_of c.body);
    (match c.body with
     | (Init_state.CIf _ | Init_state.CMatch _) when c.requires ->
         error c.cloc "a requires clause is unconditional in this slice"
     | Init_state.CIf (cond, _) ->
         let ok = match cond.desc with
           | Ast.Var "result" -> true
           | Ast.BinOp (Ast.Eq, { desc = Ast.Var "result"; _ }, { desc = Ast.BoolLit _; _ }) -> true
           | _ -> false in
         if not ok || not ret_is_bool then
           error c.cloc "an `if` contract condition is `result` or \
                         `result == true/false` of a bool function"
     | Init_state.CMatch arms ->
         (match ret_variant with
          | None -> error c.cloc "`ensures match result` needs a variant result type"
          | Some cases ->
              let seen = Hashtbl.create 8 in
              List.iter (fun ((pat : Init_state.arm_pat), _) ->
                match pat.case with
                | Some k ->
                    if Hashtbl.mem seen k then
                      error c.cloc (Printf.sprintf "case '%s' appears twice" k);
                    Hashtbl.replace seen k ();
                    (match List.assoc_opt k cases with
                     | None -> error c.cloc (Printf.sprintf
                         "'%s' is not a case of the result type" k)
                     | Some has_payload ->
                         if pat.bind <> None && not has_payload then
                           error c.cloc (Printf.sprintf
                             "case '%s' has no payload to bind" k))
                | None -> Hashtbl.replace seen "_" ()) arms;
              if not (Hashtbl.mem seen "_") then
                (match List.filter (fun (k, _) -> not (Hashtbl.mem seen k)) cases with
                 | [] -> ()
                 | missing -> error c.cloc (Printf.sprintf
                     "the contract match is not exhaustive: missing %s"
                     (String.concat ", " (List.map fst missing)))))
     | Init_state.CPlain _ -> ())) contracts;
  (* Parameters an ensures clause names: their whole-init default at return
     is replaced by the clauses. *)
  let named_params cs =
    List.concat_map (fun (c : Init_state.clause) ->
      if c.requires then [] else
      let preds = match c.body with
        | Init_state.CPlain p | Init_state.CIf (_, p) -> [p]
        | Init_state.CMatch arms -> List.map snd arms in
      List.filter_map (function
        | Init_state.PInit e ->
            (match split_target e with Some (`Param x, _) -> Some x | _ -> None)
        | Init_state.PTrue -> None) preds) cs in
  let own_named = named_params contracts in
  let out_keys = Hashtbl.fold (fun k r acc ->
    if r.out_param && not (List.mem r.display own_named) then k :: acc else acc)
      roots [] in
  (* Resolve a contract predicate to facts in the CURRENT function's terms.
     [arg_view x] gives the view the caller passes for parameter x (or the
     callee's own root, when checking a body); [env] maps names to terms. *)
  let resolve_pred ?(strengthen = false) ~arg_view ~env (p : Init_state.pred)
      : (view * Init_pred.interval) option list =
    match p with
    | Init_state.PTrue -> []
    | Init_state.PInit e ->
        (match split_target e with
         | None -> [None]
         | Some (target, bounds) ->
             let v = match target with
               | `Param x -> arg_view x
               | `Global (g, _, path) ->
                   if StringMap.mem g scratch_names then
                     let p = { root = "G" ^ g; path; inside = false } in
                     if leaf_elem p <> None then
                       Some (`View { vp = p; off = Init_pred.const 0; len = leaf_len p })
                     else Some (`Whole p)
                   else None in
             (match v with
              | None -> [None]
              | Some `Untracked -> []
              | Some (`Whole p) ->
                  [Some ({ vp = p; off = Init_pred.const 0; len = None },
                         (Init_pred.const 0, Init_pred.const (-1)))]
              | Some (`View v) ->
                  let iv = match bounds with
                    | None -> (match v.len with
                        | Some n -> Some (v.off, Init_pred.add v.off n)
                        | None -> None)
                    | Some (lo, hi) ->
                        (match clin env lo, clin env hi with
                         | Some lo, Some hi ->
                             Some (Init_pred.add v.off lo, Init_pred.add v.off hi)
                         | _ -> None) in
                  (match iv with
                   | Some iv -> [Some (v, iv)]
                   | None ->
                       (* A requires shown at a call (strengthen) may ask
                          for the whole leaf when its bounds are not
                          terms here: a stronger need, never a weaker
                          fact. *)
                       if bounds = None || strengthen then
                         [Some ({ v with len = None },
                                (Init_pred.const 0, Init_pred.const (-1)))]
                       else [None])))
  in
  (* A (view, interval) whose interval is the marker [0, -1) with len = None
     means "the whole leaf". *)
  let is_whole_marker (v, (lo, hi)) =
    v.len = None && Init_pred.equal lo (Init_pred.const 0)
    && Init_pred.equal hi (Init_pred.const (-1)) in
  let apply_fact st (v, iv) =
    if is_whole_marker (v, iv) then fill st v.vp else add_iv st v.vp iv in
  let need_fact st (v, iv) loc what =
    if is_whole_marker (v, iv) then
      (if Leaves.exists (fun (r, l) -> r = v.vp.root && is_prefix v.vp.path l
                                       && not (is_pad l)) st.u
       then begin
         error loc (Printf.sprintf "%s: '%s' may be uninitialized here" what
                      (path_to_string (root_display v.vp) v.vp.path));
         fill st v.vp
       end else st)
    else need st v iv loc what
  in
  let subst_atom a by (lo, hi) =
    (Init_pred.subst a by lo, Init_pred.subst a by hi) in
  let mentions_atom a (v, (lo, hi)) =
    Init_pred.SMap.mem a lo.Init_pred.m || Init_pred.SMap.mem a hi.Init_pred.m
    || (match v.len with Some l -> Init_pred.SMap.mem a l.Init_pred.m | None -> false) in
  let unsafe_depth = ref 0 in
  let bound_gs : (int, guarded list) Hashtbl.t = Hashtbl.create 8 in
  let bound_guarded (e : Ast.expr) = match Local_bindings.id_for_expr bindings e with
    | Some id -> Hashtbl.find_opt bound_gs id
    | None -> None in
  (* ---- expressions ------------------------------------------------------ *)
  let rec expr st (e : Ast.expr) : state =
    if is_len_of e then st else
    match e.desc with
    | Ast.Index (b, j) when view_of b <> None ->
        let v = Option.get (view_of b) in
        let st = expr st j in
        let st = place_subexprs_view st b in
        (match lin j with
         | Some j ->
             let k = Init_pred.add v.off j in
             need st v (k, Init_pred.add k (Init_pred.const 1)) e.loc "read"
         | None -> need_view st v e.loc "read")
    | _ when view_of e <> None && not (is_plain_place e) ->
        let v = Option.get (view_of e) in
        let st = view_subexprs st e in
        need_view st v e.loc "viewed as memory"
    | _ ->
    match place e with
    | Some p ->
        let st = place_subexprs st e in
        check_read st { p with inside = false } ~bytes:false e.loc
    | None ->
    match e.desc with
    | Ast.Cast (_, { desc = Ast.AddrOf inner; _ }) | Ast.Cast (_, inner) ->
        (* Reinterpreting a place (or its address) with `as` exposes its
           bytes, padding included. *)
        (match place inner with
         | Some p ->
             let st = place_subexprs st inner in
             check_read st { p with inside = false } ~bytes:true e.loc
         | None -> expr st inner)
    | Ast.AddrOf inner ->
        (* A typed address escapes the fields; reinterpreting it is the
           byte view above. *)
        (match place inner with
         | Some p ->
             let st = place_subexprs st inner in
             check_read st { p with inside = false } ~bytes:false e.loc
         | None -> expr st inner)
    | Ast.SliceOf (base, lo, hi) ->
        let st = expr st lo in
        let st = expr st hi in
        (match place base with
         | Some p ->
             let st = place_subexprs st base in
             check_read st { p with inside = false } ~bytes:true e.loc
         | None -> expr st base)
    | Ast.Call ("zero_fill", [a]) -> fill_arg st a
    | Ast.Call ("assume_init", [a]) -> fill_arg st a
    | Ast.Call _ -> fst (call st e ~result:None)
    | Ast.BinOp ((Ast.And | Ast.Or) as op, l, r) ->
        let st = expr st l in
        (* The right operand runs only when the left one did not decide. *)
        ignore (expr (assume st l (op = Ast.And)) r); st
    | Ast.BinOp (_, l, r) -> expr (expr st l) r
    | Ast.Index (l, r) -> expr (expr st l) r
    | Ast.Assign ({ desc = Ast.Index (b, j); _ }, rhs) when view_of b <> None ->
        (* An element store writes element j of the view. *)
        let v = Option.get (view_of b) in
        let st = expr st rhs in
        let st = expr st j in
        let st = place_subexprs_view st b in
        (match lin j with
         | Some j ->
             let k = Init_pred.add v.off j in
             add_iv st v.vp (k, Init_pred.add k (Init_pred.const 1))
         | None -> st)
    | Ast.Assign (lhs, rhs) ->
        let st = expr st rhs in
        (match place lhs with
         | Some p ->
             let st = place_subexprs st lhs in
             if p.inside then begin
               (* An element store into an array or slice leaf writes
                  without reading; through any other leaf (a pointer) it
                  reads the leaf. *)
               (match leaf_type p.root p.path with
                | Some t when (match strip t with
                    | Ast.TypeArray _ | Ast.TypeSlice _ -> true | _ -> false) -> st
                | _ -> check_read st { p with inside = false } ~bytes:false lhs.loc)
             end else assign st p rhs
         | None -> expr st lhs)
    | Ast.VariantCtor (_, _, x) | Ast.Bnot x | Ast.Deref x | Ast.FieldGet (x, _) ->
        expr st x
    | Ast.Unsafe x ->
        incr unsafe_depth;
        let st = expr st x in
        decr unsafe_depth; st
    | Ast.StructLit xs | Ast.TupleLit xs -> List.fold_left expr st xs
    | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.ByteSliceLit _
    | Ast.Var _ | Ast.ViewLit _ | Ast.EnumVariant _ | Ast.SizeOf _
    | Ast.ContainsStableOwner _ | Ast.AlignOf _ | Ast.OffsetOf _
    | Ast.EmbedFile _ -> st
  (* A whole array or slice leaf read as a value keeps the old leaf rule
     (with its padding semantics); views only refine element ranges. *)
  and is_plain_place (e : Ast.expr) =
    match place e with Some p -> not p.inside | None -> false
  (* The index expressions inside a place chain are ordinary reads. *)
  and place_subexprs st (e : Ast.expr) = match e.desc with
    | Ast.FieldGet (b, _) | Ast.Deref b -> place_subexprs st b
    | Ast.Index (b, i) -> place_subexprs (expr st i) b
    | _ -> st
  and place_subexprs_view st (e : Ast.expr) = match e.desc with
    | Ast.SliceOf (b, lo, hi) -> place_subexprs_view (expr (expr st lo) hi) b
    | Ast.Cast (_, b) -> place_subexprs_view st b
    | _ -> place_subexprs st e
  and view_subexprs st e = place_subexprs_view st e
  (* An out argument cut from a view with bounds that are not linear: it
     writes an unknown range, so it neither reads nor initializes. *)
  and has_view_base (a : Ast.expr) = match a.desc with
    | Ast.SliceOf (b, _, _) | Ast.Cast (_, b) -> view_of b <> None || has_view_base b
    | _ -> false
  and place_subexprs_any st (e : Ast.expr) = match e.desc with
    | Ast.SliceOf (b, lo, hi) -> place_subexprs (expr (expr st lo) hi) b
    | Ast.AddrOf b | Ast.Cast (_, b) -> place_subexprs_any st b
    | _ -> place_subexprs st e
  and fill_target (a : Ast.expr) =
    match a.desc with
    | Ast.AddrOf inner | Ast.Cast (_, inner) ->
        (match place inner with
         | Some p when not p.inside -> `Whole (p, inner)
         | Some _ -> `Partial inner
         | None -> (match inner.desc with
             | Ast.Cast _ | Ast.AddrOf _ -> fill_target inner
             | Ast.SliceOf (b, _, _) when place b <> None -> `Partial inner
             | _ -> `Other))
    | Ast.SliceOf (b, _, _) when place b <> None -> `Partial a
    | _ ->
        (match place a with
         | Some p when not p.inside -> `Whole (p, a)
         | Some _ -> `Partial a
         | None -> `Other)
  and fill_arg st a =
    match fill_target a with
    | `Whole (p, inner) -> fill (place_subexprs st inner) p
    | `Partial inner ->
        (match view_of a with
         | Some ({ len = Some n; _ } as v) ->
             add_iv (place_subexprs_view st a) v.vp (v.off, Init_pred.add v.off n)
         | _ -> place_subexprs_any st inner)
    | `Other ->
        (match view_of a with
         | Some ({ len = Some n; _ } as v) ->
             add_iv (place_subexprs_view st a) v.vp (v.off, Init_pred.add v.off n)
         | _ -> expr st a)
  and assign st p (rhs : Ast.expr) =
    let src = match rhs.desc with
      | Ast.StructLit _ -> `Literal
      | _ -> (match place rhs with
          | Some q when not q.inside -> `Place q
          | _ -> `Untracked) in
    let pads = List.filter (fun (r, l) -> r = p.root && is_prefix p.path l && is_pad l)
        (all_leaves p.root) in
    let st0 = st in
    let st = fill st p in
    List.fold_left (fun st (r, l) ->
      let suffix = drop (List.length p.path) l in
      let uninit = match src with
        | `Literal -> true
        | `Untracked -> false
        | `Place q -> Leaves.mem (q.root, q.path @ suffix) st0.u in
      if uninit then { st with u = Leaves.add (r, l) st.u } else st) st pads
  (* A call: arguments, then the callee's contract. Returns the state after
     the call and the facts that hold only for some results. [result] is
     the term the caller binds the result to, if any. *)
  and call st (e : Ast.expr) ~result : state * guarded list =
    match e.desc with
    | Ast.Call ("slice_copy", [d; s]) when view_of d <> None ->
        (* Builtin contract: init(dst[0..<result]). *)
        let v = Option.get (view_of d) in
        let st = expr st s in
        let st = place_subexprs_view st d in
        (match result with
         | Some r -> (add_iv st v.vp (v.off, Init_pred.add v.off r), [])
         | None -> (st, []))
    | Ast.Call (name, args) ->
        let params = match callee name with
          | Some (ps, loc) when List.length ps = List.length args -> Some (ps, loc)
          | _ -> None in
        let cs = match params with
          | Some (_, loc) -> Init_state.contracts_of loc | None -> [] in
        let named = named_params cs in
        let required = required_params cs in
        let (st, fills) = List.fold_left (fun (st, fills) (i, a) ->
          let out = match params with
            | Some (ps, loc) ->
                let (pname, pty) = List.nth ps i in
                (match Init_state.param_qual loc pname with
                 | Some Init_state.Uninit when List.mem pname named -> `Contract
                 | Some Init_state.Uninit -> `Out
                 | _ when List.mem pname required -> `Contract
                 | _ ->
                     let rec is_ref_mut t = match strip t with
                       | Ast.TypeBorrow t -> is_ref_mut t
                       | Ast.TypeRefMut _ -> true
                       | _ -> false in
                     (match pty, a.Ast.desc with
                      | Some t, Ast.AddrOf _ when is_ref_mut t -> `Fields
                      | _ -> `No))
            | None -> `No in
          match out with
          | `Contract ->
              (match view_of a with
               | Some _ -> (place_subexprs_view st a, fills)
               | None ->
                   (match fill_target a with
                    | `Whole (_, inner) -> (place_subexprs st inner, fills)
                    | `Partial inner -> (place_subexprs_any st inner, fills)
                    | `Other when has_view_base a -> (place_subexprs_view st a, fills)
                    | `Other -> (expr st a, fills)))
          | `Out | `Fields ->
              (match fill_target a with
               | `Whole (p, inner) -> (place_subexprs st inner, (`P (p, out)) :: fills)
               | `Partial inner ->
                   (match view_of a with
                    | Some ({ len = Some n; _ } as v) when out = `Out ->
                        (place_subexprs_view st a,
                         (`V (v, (v.off, Init_pred.add v.off n))) :: fills)
                    | _ -> (place_subexprs_any st inner, fills))
               | `Other ->
                   (match view_of a with
                    | Some ({ len = Some n; _ } as v) when out = `Out ->
                        (place_subexprs_view st a,
                         (`V (v, (v.off, Init_pred.add v.off n))) :: fills)
                    | _ when has_view_base a -> (place_subexprs_view st a, fills)
                    | _ -> (expr st a, fills)))
          | `No -> (expr st a, fills))
          (st, []) (List.mapi (fun i a -> (i, a)) args) in
        (* Requires: checked against the state before the out fills. *)
        let pnames = match params with Some (ps, _) -> List.map fst ps | None -> [] in
        let arg_of x = match List.find_index (( = ) x) pnames with
          | Some i -> Some (List.nth args i) | None -> None in
        let arg_view x = match arg_of x with
          | Some a ->
              (match view_of a with
               | Some v -> Some (`View v)
               | None ->
                   (match fill_target a with
                    | `Whole (p, _) -> Some (`Whole p)
                    | _ -> Some `Untracked))
          | None -> None in
        let env ~binder x kind =
          if x = "result" then result
          else match binder with
            | Some (b, t) when b = x -> t
            | _ ->
                match arg_of x, kind with
                | Some a, `Val _ -> lin a
                | Some a, `Len _ ->
                    (match view_of a with
                     | Some v -> v.len
                     | None -> lin { a with desc = Ast.FieldGet (a, "len") })
                | None, _ -> None in
        let st = List.fold_left (fun st (c : Init_state.clause) ->
          if not c.requires then st else
          match c.body with
          | Init_state.CPlain p ->
              List.fold_left (fun st r -> match r with
                | Some f -> need_fact st f e.loc
                              (Printf.sprintf "'%s' requires it initialized" name)
                | None ->
                    error e.loc (Printf.sprintf
                      "cannot show the requires clause of '%s' at this call: \
                       its place or bounds are not expressible here" name);
                    st) st (resolve_pred ~strengthen:true ~arg_view ~env:(env ~binder:None) p)
          | _ -> st) st cs in
        let st = List.fold_left (fun st f -> match f with
          | `P (p, `Fields) -> fill_fields st p
          | `P (p, _) -> fill st p
          | `V (v, iv) -> add_iv st v.vp iv) st fills in
        (* Ensures. *)
        let facts ~binder p =
          List.filter_map (fun x -> x)
            (resolve_pred ~arg_view ~env:(env ~binder) p) in
        let bind_atom b = "arm:" ^ b in
        List.fold_left (fun (st, gs) (c : Init_state.clause) ->
          if c.requires then (st, gs) else
          match c.body with
          | Init_state.CPlain p ->
              (List.fold_left apply_fact st (facts ~binder:None p), gs)
          | Init_state.CIf (cond, p) ->
              let pol = match cond.desc with
                | Ast.BinOp (Ast.Eq, _, { desc = Ast.BoolLit b; _ }) -> b
                | _ -> true in
              (st, GBool (pol, facts ~binder:None p) :: gs)
          | Init_state.CMatch arms ->
              (st, List.map (fun ((pat : Init_state.arm_pat), p) ->
                 let binder = Option.map (fun b ->
                   (b, Some (Init_pred.atom (bind_atom b)))) pat.bind in
                 GCase (pat.case, Option.map bind_atom pat.bind,
                        facts ~binder p)) arms @ gs))
          (st, []) cs
    | _ -> (expr st e, [])
  in
  ignore callee_ret;
  (* Facts under one outcome of a call. *)
  let apply_bool st gs b =
    List.fold_left (fun st g -> match g with
      | GBool (pol, fs) when pol = b ->
          List.fold_left apply_fact st fs
      | _ -> st) st gs in
  let apply_case st gs case binder_term =
    (* The arm for [case], else the wildcard. *)
    let exact = List.exists (function GCase (Some k, _, _) -> k = case | _ -> false) gs in
    List.fold_left (fun st g -> match g with
      | GCase (k, b, fs) when (if exact then k = Some case else k = None) ->
          List.fold_left (fun st (v, iv) ->
            let iv = match b, binder_term with
              | Some a, Some t -> subst_atom a t iv
              | _ -> iv in
            let still_bound = match b with
              | Some a -> mentions_atom a (v, iv)
              | None -> false in
            if still_bound then st else apply_fact st (v, iv)) st fs
      | _ -> st) st gs in
  (* The call an `if` condition tests, and the outcome its true branch sees. *)
  let cond_call (c : Ast.expr) = match c.desc with
    | Ast.Call _ -> Some (c, true)
    | Ast.BinOp (Ast.Eq, ({ desc = Ast.Call _; _ } as k), { desc = Ast.BoolLit b; _ }) -> Some (k, b)
    | Ast.BinOp (Ast.Ne, ({ desc = Ast.Call _; _ } as k), { desc = Ast.BoolLit b; _ }) -> Some (k, not b)
    | _ -> None in
  (* ---- returns ------------------------------------------------------------- *)
  let own_arg_view x =
    match List.assoc_opt x param_ids with
    | Some id ->
        let key = "L" ^ string_of_int id in
        let p = { root = key; path = []; inside = false } in
        if Hashtbl.mem roots key then
          (if leaf_elem p <> None then
             Some (`View { vp = p; off = Init_pred.const 0; len = leaf_len p })
           else Some (`Whole p))
        else Some `Untracked
    | None -> None in
  let own_env ~result ~binder x kind =
    if x = "result" then result
    else match binder with
      | Some (b, t) when b = x -> t
      | _ ->
          match List.assoc_opt x param_ids, kind with
          | Some id, `Val _ when not (is_written x id) -> Some (v_atom id)
          | Some id, `Len _ -> Some (len_atom id)
          | _ -> None in
  let check_ensures st (eo : Ast.expr option) (gs : guarded list) loc =
    let result = match eo with Some e -> lin e | None -> None in
    let need_pred st ~binder p =
      List.fold_left (fun st r -> match r with
        | Some f -> need_fact st f loc "the ensures clause needs it initialized"
        | None ->
            error loc "cannot show this ensures clause here: its bounds are \
                       not expressible at this return";
            st) st (resolve_pred ~arg_view:own_arg_view
                      ~env:(own_env ~result ~binder) p) in
    List.iter (fun (c : Init_state.clause) ->
      if c.requires then () else
      match c.body with
      | Init_state.CPlain p -> ignore (need_pred st ~binder:None p)
      | Init_state.CIf (cond, p) ->
          let pol = match cond.desc with
            | Ast.BinOp (Ast.Eq, _, { desc = Ast.BoolLit b; _ }) -> b
            | _ -> true in
          (match eo with
           | Some { desc = Ast.BoolLit b; _ } when b <> pol -> ()
           | Some ({ desc = Ast.BinOp (Ast.Eq, x, y); _ }) when pol ->
               let st = match lin x, lin y with
                 | Some x, Some y ->
                     let d = Init_pred.sub x y in
                     (match Init_pred.SMap.min_binding_opt d.m with
                      | Some (a, k) when k = 1 || k = -1 ->
                          (* a = -(d - k*a)/k *)
                          let rest = Init_pred.sub d (Init_pred.scale k (Init_pred.atom a)) in
                          let t = Init_pred.scale (-k) rest in
                          { st with eqs = st.eqs @ [(a, t)] }
                      | _ -> st)
                 | _ -> st in
               ignore (need_pred st ~binder:None p)
           | _ ->
               ignore (need_pred (apply_bool st gs pol) ~binder:None p))
      | Init_state.CMatch arms ->
          let arm_for case =
            match List.find_opt (fun ((pat : Init_state.arm_pat), _) -> pat.case = Some case) arms with
            | Some a -> Some a
            | None -> List.find_opt (fun ((pat : Init_state.arm_pat), _) -> pat.case = None) arms in
          (match eo with
           | Some { desc = Ast.VariantCtor (_, case, payload); _ } ->
               (match arm_for case with
                | Some (pat, p) ->
                    let binder = Option.map (fun b -> (b, lin payload)) pat.bind in
                    ignore (need_pred st ~binder p)
                | None -> ())
           | Some { desc = Ast.EnumVariant (_, case); _ } ->
               (match arm_for case with
                | Some (_, p) -> ignore (need_pred st ~binder:None p)
                | None -> ())
           | Some { desc = Ast.Var _; _ } when gs <> [] ->
               (* GitHub issue #975: a bound call result: each arm under
                  the facts the call gave that case. *)
               let cases = match ret_variant with Some cs -> List.map fst cs | None -> [] in
               List.iter (fun ((pat : Init_state.arm_pat), p) ->
                 let mine = match pat.case with
                   | Some k -> [k]
                   | None -> List.filter (fun k -> not (List.exists
                       (fun ((q : Init_state.arm_pat), _) -> q.case = Some k) arms)) cases in
                 List.iter (fun k ->
                   let t = Option.map (fun b -> Init_pred.atom ("ret:" ^ b)) pat.bind in
                   let st = apply_case st gs k t in
                   let binder = Option.map (fun b -> (b, t)) pat.bind in
                   ignore (need_pred st ~binder p)) mine) arms
           | _ ->
               List.iter (fun ((pat : Init_state.arm_pat), p) ->
                 let binder = Option.map (fun b -> (b, None)) pat.bind in
                 ignore (need_pred st ~binder p)) arms)) contracts
  in
  let check_outs st loc =
    List.iter (fun key ->
      let bad = Leaves.filter (fun (r, _) -> r = key) st.u in
      match Leaves.min_elt_opt bad with
      | None -> ()
      | Some (_, l) ->
          let r = Hashtbl.find roots key in
          error loc (Printf.sprintf
            "borrow uninit parameter '%s' must be initialized on every \
             return, but '%s' may still be uninitialized here"
            r.display (path_to_string r.display l))) out_keys
  in
  let arm_body = function
    | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmMiss b
    | Ast.ArmIntLit (_, b) | Ast.ArmByteSliceLit (_, b) -> b
  in
  (* A merge keeps an interval only if every live arm has it, or has the
     leaf fully initialized. *)
  let merge results =
    match List.filter (fun (_, dead) -> not dead) results with
    | [] -> ({ u = Leaves.empty; iv = []; eqs = []; facts = Init_pred.no_facts }, true)
    | (first, _) :: rest ->
        let all = List.map fst ((first, false) :: rest) in
        let u = List.fold_left (fun acc s -> Leaves.union acc s.u) first.u
            (List.map fst rest) in
        let cands = List.sort_uniq compare
            (List.concat_map (fun s -> s.iv) all) in
        let iv = List.filter (fun (l, i) ->
          Leaves.mem l u &&
          List.for_all (fun s ->
            not (Leaves.mem l s.u)
            || List.exists (fun (l', i') -> l' = l && Init_pred.interval_equal i i') s.iv)
            all) cands in
        let eqs = List.filter (fun (a, t) ->
          List.for_all (fun s ->
            List.exists (fun (a', t') -> a = a' && Init_pred.equal t t') s.eqs) all)
            first.eqs in
        (* GitHub issue #975: a path fact survives a merge when every live
           arm knows it. *)
        let in_all f = List.for_all f all in
        let ge = List.filter (fun t ->
          in_all (fun s -> List.exists (Init_pred.equal t) s.facts.Init_pred.ge))
          first.facts.Init_pred.ge in
        let mins = List.filter (fun (x, a, b) ->
          in_all (fun s -> List.exists (fun (x', a', b') ->
            x = x' && Init_pred.equal a a' && Init_pred.equal b b') s.facts.Init_pred.mins))
          first.facts.Init_pred.mins in
        ({ u; iv; eqs; facts = { Init_pred.ge; mins } }, false)
  in
  let trackable ty = match strip ty with
    | Ast.TypeArray _ -> false
    | _ -> true
  in
  (* GitHub issue #888, generalized by #954: a counted loop that stores
     element i of a view on every iteration,

       for i in lo ..< hi { ...; P[i] = e; ... }

     where P is a view named by a variable and field chain or an alias (the
     same place on every iteration), the store is a statement at the top
     level of the body (inside plain or unsafe blocks only, never under an
     if, match or inner loop), its index is the loop's own counter, and
     nothing in the body leaves the iteration early: no `return` anywhere,
     no `break` or `continue` outside an inner loop. Every iteration then
     runs that store, so elements [off + lo, off + hi) are initialized once
     the loop ends: one instance of the interval predicate. With lo = 0 and
     hi = the array's length the whole leaf is initialized, #888's rule.
     The body itself is still checked with P as before the loop. *)
  let rec leaves_iteration depth ss = List.exists (fun (s : Ast.stmt) ->
    match s.desc with
    | Ast.Return _ -> true
    | Ast.Break | Ast.Continue -> depth = 0
    | Ast.Block b | Ast.UnsafeBlock b -> leaves_iteration depth b
    | Ast.If (_, a, b) -> leaves_iteration depth a || leaves_iteration depth b
    | Ast.While (_, b) | Ast.For (_, _, _, _, b) | Ast.ForEach (_, _, b) ->
        leaves_iteration (depth + 1) b
    | Ast.Match (_, arms) | Ast.LetMatch (_, _, _, _, arms) ->
        List.exists (fun a -> leaves_iteration depth (arm_body a)) arms
    | Ast.Let _ | Ast.LetTuple _ | Ast.Expr _ | Ast.Yield _
    | Ast.StaticAssert _ -> false) ss
  in
  let filled_by_loop (s : Ast.stmt) lo hi body =
    let counter = match Local_bindings.ids_for_stmt bindings s with
      | [_; binder] -> Some binder | _ -> None in
    let rec plain_chain (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> true
      | Ast.FieldGet (b, _) -> plain_chain b
      | _ -> false in
    let rec top_stores ss = List.concat_map (fun (st : Ast.stmt) ->
      match st.desc with
      | Ast.Block b | Ast.UnsafeBlock b -> top_stores b
      | Ast.Expr { desc = Ast.Assign (
          { desc = Ast.Index (base, ({ desc = Ast.Var _; _ } as iv)); _ }, _); _ }
        when plain_chain base
             && counter <> None
             && Local_bindings.id_for_expr bindings iv = counter ->
          (match view_of base, lin lo, lin hi with
           | Some v, Some lo, Some hi ->
               [(v.vp, (Init_pred.add v.off lo, Init_pred.add v.off hi))]
           | _ -> [])
      | _ -> []) ss in
    if leaves_iteration 0 body then [] else top_stores body
  in
  let bind_result (s : Ast.stmt) =
    match Local_bindings.ids_for_stmt bindings s with
    | id :: _ when immutable id -> Some (v_atom id)
    | _ -> None in
  let rec stmts st ss =
    List.fold_left (fun (st, dead) s ->
      if dead then (st, dead) else stmt st s) (st, false) ss
  and stmt st (s : Ast.stmt) =
    cur_loc := s.loc;
    match s.desc with
    | Ast.Let (_, name, _, None, _) ->
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ ->
             (match Types.IntMap.find_opt id finfo.Types.binding_types with
              | Some ty when trackable ty ->
                  let key = "L" ^ string_of_int id in
                  Hashtbl.replace roots key
                    { display = name; leaves = leaves_of [] [] ty;
                      array_root = false; out_param = false };
                  ({ st with u = List.fold_left (fun s l -> Leaves.add l s) st.u
                                   (all_leaves key) }, false)
              | _ -> (st, false))
         | [] -> (st, false))
    | Ast.Let (_, name, _, Some ({ desc = Ast.StructLit _; _ } as e), _) ->
        (* A struct literal writes every field and no padding. *)
        let st = expr st e in
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ ->
             (match Types.IntMap.find_opt id finfo.Types.binding_types with
              | Some ty ->
                  let key = "L" ^ string_of_int id in
                  let leaves = leaves_of [] [] ty in
                  Hashtbl.replace roots key
                    { display = name; leaves; array_root = false; out_param = false };
                  ({ st with u = List.fold_left (fun s (p, _) ->
                       if is_pad p then Leaves.add (key, p) s else s) st.u leaves }, false)
              | None -> (st, false))
         | [] -> (st, false))
    | Ast.Let (false, _, _, Some e, _)
      when view_of e <> None
           && (match Local_bindings.ids_for_stmt bindings s with
               | id :: _ ->
                   (match Option.map strip
                            (Types.IntMap.find_opt id finfo.Types.binding_types) with
                    | Some (Ast.TypeSlice _) -> true
                    | _ -> false)
               | [] -> false) ->
        (* GitHub issue #954: an immutable view binding is an alias; it
           reads nothing until it is used. *)
        let v = Option.get (view_of e) in
        let st = place_subexprs_view st e in
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ when immutable id -> Hashtbl.replace aliases id v; (st, false)
         | _ -> (need_view st v e.loc "viewed as memory", false))
    | Ast.Let (false, _, _, Some ({ desc = Ast.Call ("min", [a; b]); _ } as e), _) ->
        (* GitHub issue #975: x = min(a, b) as a fact; with one side not a
           fact side, only x <= the other. *)
        let st = fst (call st e ~result:None) in
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ when immutable id && unsigned_id id ->
             let x = v_atom id in
             let xa = "v" ^ string_of_int id in
             (match side st.facts a, side st.facts b with
              | Some l, Some r ->
                  ({ st with facts = { st.facts with
                       Init_pred.mins = (xa, l, r) :: st.facts.Init_pred.mins } }, false)
              | Some l, None | None, Some l -> (add_fact st (Init_pred.sub l x), false)
              | None, None -> (st, false))
         | _ -> (st, false))
    | Ast.Let (_, _, _, Some ({ desc = Ast.Call _; _ } as e), _) ->
        let (st, gs) = call st e ~result:(bind_result s) in
        (* GitHub issue #975: an immutable binding of a call's result keeps
           the facts that depend on it, for a later `match` or `return`. *)
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ when immutable id && gs <> [] -> Hashtbl.replace bound_gs id gs
         | _ -> ());
        (st, false)
    | Ast.Let (false, _, _, Some ({ desc = Ast.SliceOf (b, lo, _); _ } as e), _)
      when view_of e = None && view_of b <> None && lin lo <> None
           && (match Local_bindings.ids_for_stmt bindings s with
               | id :: _ ->
                   immutable id
                   && (match Option.map strip
                               (Types.IntMap.find_opt id finfo.Types.binding_types) with
                       | Some (Ast.TypeSlice _) -> true
                       | _ -> false)
               | [] -> false) ->
        (* GitHub issue #975: a sub-slice whose end is not a linear term
           (a mutable bound, say) is still an alias; its length is fixed
           once bound, so it is the binding's own `.len` atom. *)
        let v = Option.get (view_of b) in
        let id = List.hd (Local_bindings.ids_for_stmt bindings s) in
        let st = place_subexprs_view st e in
        Hashtbl.replace aliases id
          { v with off = Init_pred.add v.off (Option.get (lin lo));
                   len = Some (len_atom id) };
        (st, false)
    | Ast.Let (_, _, _, Some e, _) | Ast.LetTuple (_, e) | Ast.Expr e
    | Ast.Yield e -> (expr st e, false)
    | Ast.Return eo ->
        let (st, gs) = match eo with
          | Some ({ desc = Ast.Call _; _ } as e) -> call st e ~result:None
          | Some ({ desc = Ast.Var _; _ } as e) when bound_guarded e <> None ->
              (expr st e, Option.get (bound_guarded e))
          | Some e -> (expr st e, [])
          | None -> (st, []) in
        check_outs st s.loc; check_ensures st eo gs s.loc; (st, true)
    | Ast.Block b -> stmts st b
    | Ast.UnsafeBlock b ->
        incr unsafe_depth;
        let r = stmts st b in
        decr unsafe_depth; r
    | Ast.If (c, yes, no) ->
        (match cond_call c with
         | Some (k, b) ->
             let (st, gs) = call st k ~result:None in
             merge [stmts (apply_bool st gs b) yes; stmts (apply_bool st gs (not b)) no]
         | None ->
             let st = expr st c in
             merge [stmts (assume st c true) yes; stmts (assume st c false) no])
    | Ast.While (c, body) ->
        let st = expr st c in
        ignore (stmts (assume st c true) body); (st, false)
    | Ast.For (_, _, lo, hi, body) ->
        let st = expr (expr st lo) hi in
        (* GitHub issue #975: the counter lies in [lo, hi) in the body. *)
        let in_body = match Local_bindings.ids_for_stmt bindings s with
          | [_; id] when unsigned_id id ->
              let i = v_atom id in
              let st = match side st.facts lo with
                | Some l -> add_fact st (Init_pred.sub i l) | None -> st in
              (match side st.facts hi with
               | Some h -> add_fact st (Init_pred.sub (Init_pred.sub h i) (Init_pred.const 1))
               | None -> st)
          | _ -> st in
        ignore (stmts in_body body);
        (List.fold_left (fun st (p, iv) -> add_iv st p iv) st
           (filled_by_loop s lo hi body), false)
    | Ast.ForEach (_, seq, body) ->
        let st = expr st seq in
        ignore (stmts st body); (st, false)
    | Ast.Match (d, arms) | Ast.LetMatch (_, _, _, d, arms) ->
        let (st, gs) = match d.desc with
          | Ast.Call _ -> call st d ~result:None
          | Ast.Var _ when bound_guarded d <> None -> (expr st d, Option.get (bound_guarded d))
          | _ -> (expr st d, []) in
        merge (List.mapi (fun i a ->
          (* GitHub issue #975: the binder's payload type, for its facts. *)
          (match a, Local_bindings.id_for_arm bindings s.loc i with
           | Ast.ArmVariant (vname, case, Some (Ast.PayloadBind (_, false)), _), Some id ->
               Option.iter (Hashtbl.replace arm_types id) (variant_payload vname case)
           | _ -> ());
          let st = match a with
            | Ast.ArmVariant (_, case, payload, _) when gs <> [] ->
                let term = match payload with
                  | Some (Ast.PayloadBind (_, false)) ->
                      (match Local_bindings.id_for_arm bindings s.loc i with
                       | Some id when immutable id -> Some (v_atom id)
                       | _ -> None)
                  | _ -> None in
                apply_case st gs case term
            | _ -> st in
          stmts st (arm_body a)) arms)
    | Ast.Break | Ast.Continue -> (st, true)
    | Ast.StaticAssert _ -> (st, false)
  in
  (* Requires: assumed at entry. *)
  let entry = { u = entry_u; iv = []; eqs = []; facts = Init_pred.no_facts } in
  let entry = List.fold_left (fun st (c : Init_state.clause) ->
    match c.body with
    | Init_state.CPlain p when c.requires ->
        List.fold_left (fun st r -> match r with
          | Some f -> apply_fact st f
          | None -> st) st
          (resolve_pred ~arg_view:own_arg_view
             ~env:(own_env ~result:None ~binder:None) p)
    | _ -> st) entry contracts in
  let (st, dead) = stmts entry fdef.Ast.body in
  if not dead then begin
    check_outs st fdef.Ast.def_loc;
    check_ensures st None [] fdef.Ast.def_loc
  end;
  match List.rev !errors with
  | [] -> ()
  | [(loc, msg)] -> raise (Types.TypeError (loc, msg))
  | errs -> raise (Types.MultiTypeError errs)
