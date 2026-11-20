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
   - a local declared without an initializer, including fixed-size arrays;
   - a `borrow uninit` parameter, whose checked output contract describes
     the initialized fields or ranges at return;
   - a `scratch` global, uninitialized at function entry. Array elements
     have separate roots selected by a local binding/field chain or constant.
     Selector writes, owner consumption and rebinding invalidate dependent
     facts; different bindings are conservatively distinct.

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
   - an array element store adds its singleton interval; counted-loop
     coverage and checked API contracts can establish larger intervals;
   - zero_fill(p) and unsafe assume_init(p) establish byte initialization
     for the specified footprint. A `borrow uninit` call transfers only its
     checked output contract. Ordinary `&mut T` arguments require initialized
     fields and add no initialization fact. `init_fields` transfers fields
     without asserting padding.

   A loop body may run no times, so the state after a loop is the state
   before it; the body is checked against that same state, which is a
   superset of what any later iteration sees. *)

module StringMap = Map.Make (String)
module StringSet = Set.Make (String)

type leaf = string * string list   (* root key, field path *)

module Leaves = Set.Make (struct
  type t = leaf
  let compare = compare
end)

let pad = "#pad"

(* GitHub issue #976: --internal-trace-init-flow FUNC. When [trace_func] names the
   function being checked, the state after each top-level-or-nested
   statement is written to [trace_out] as lines of the stable form

     init-trace FUNC LINE:COL KIND LEAF: init
     init-trace FUNC LINE:COL KIND LEAF: uninit; known [lo, hi), ...; FACTS

   one per tracked leaf, in leaf order. Off (None) by default; the flag-off
   path is one comparison per statement and allocates nothing. *)
let trace_func : string option ref = ref None
let trace_out : (string -> unit) ref = ref prerr_string

type root = {
  display : string;
  leaves : (string list * Ast.type_expr) list;
  array_root : bool;     (* scratch array whose elements need selected roots *)
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
(* Rare scratch identities and linked certificates share one cold field.
   Ordinary interval-state copies keep the original record size. *)
type extras = {
  links : Init_link.t;
  touched : StringSet.t;
  owners : string Types.IntMap.t;
  owner_guards : StringSet.t Types.IntMap.t;
}
let empty_extras = {
  links = Init_link.empty; touched = StringSet.empty; owners = Types.IntMap.empty;
  owner_guards = Types.IntMap.empty;
}
type state = {
  extras : extras;
  u : Leaves.t;
  iv : (leaf * Init_pred.interval) list;
  eqs : Init_pred.eqs;
  facts : Init_pred.facts;   (* GitHub issue #975: linear path facts *)
  vers : int Types.IntMap.t;
    (* GitHub issue #978: the current version of each versioned mutable
       local (binding id -> version). Atom `v<id>@<k>` is the value the
       local held at version k; an assignment starts a new version, so a
       fact about an older version stays true and simply stops being about
       the local. *)
}

let set_links st links =
  if links == st.extras.links then st
  else {st with extras = {st.extras with links}}

(* A tracked view of an array or slice leaf: elements [off, off + len) of
   the leaf at [vp]. *)
type view = { vp : place; off : Init_pred.lin; len : Init_pred.lin option }

type link_argument = [ `Whole of place | `View of view | `Untracked ] option
type link_ops = {
  assign_value : state -> string -> Ast.expr -> state;
  value_key : Ast.expr -> string option;
  view_ready : state -> view -> Ast.expr -> bool;
  check_pred : state -> arg_view:(string -> link_argument) -> Init_state.pred -> Ast.loc -> state;
  apply_pred : state -> arg_view:(string -> link_argument) -> Init_state.pred -> Ast.loc -> state;
  invalidate_aliases : Init_link.t -> string -> Init_link.t;
}

(* A fact a call establishes: elements [lo, hi) (callee terms already mapped
   into the caller, except the atoms "result" and binder names) of a leaf. *)
type fact = place * Init_pred.interval

type contract_value = [ `Val of Init_pred.lin option | `Len of Init_pred.lin option | `Field of string ]

type guarded =
  | GBool of bool * (view * Init_pred.interval) list
      (* holds when result = the bool *)
  | GPositive of Init_pred.lin * (view * Init_pred.interval) list
      (* a publish_copy result is nonzero only after all fields were copied *)
  | GCase of string option * string option * (view * Init_pred.interval) list
      (* case (None: any other case), payload binder atom, facts *)

type owner_storage = OwnerBytes of int | SlotFields

let owner_leaf_type = function
  | OwnerBytes size -> Ast.TypeArray (Ast.TypeU8, size)
  | SlotFields -> Ast.TypeBool

let check
    ~(struct_fields : string -> (string * Ast.type_expr) list option)
    ~(callee : string -> Ast.expr -> ((Ast.ident * Ast.type_expr option) list * Ast.loc) option)
    ~(scratch : (string * Ast.type_expr) list)
    ?(variant_cases : string -> (string * bool) list option = fun _ -> None)
    ?(linear_owner : string -> bool = fun _ -> false)
    ?(variant_payload : string -> string -> Ast.type_expr option = fun _ _ -> None)
    ?(callee_ret : string -> Ast.type_expr option = fun _ -> None)
    ?(global_singleton : string -> int option = fun _ -> None)
    ?(global_byte_array_length : string -> int option = fun _ -> None)
    ?(noreturn : Ast.expr -> bool = fun _ -> false)
    ?(write_footprint : Ast.expr -> Init_writes.t = fun _ -> Init_writes.Unknown)
    ?(pointer_store_origin : Ast.expr -> string option = fun _ -> None)
    ?(owner_view_call : Ast.expr -> int option = fun _ -> None)
    ?(owner_type : Ast.type_expr -> owner_storage option = fun _ -> None)
    ?(inferred_owner_requirement : Ast.expr -> int option option = fun _ -> None)
    ?(projected_contract_owner : Ast.expr -> string option = fun _ -> None)
    ?(slot_contract_owner : Ast.expr -> string option = fun _ -> None)
    ?(slot_record_call : Ast.expr -> int option = fun _ -> None)
    ?(owner_call_facts : Ast.expr -> (int * string) list = fun _ -> [])
    ?(owner_parameters = [])
    ?(initialized_owner_parameters = [])
    ?(note_owner_return : string -> string -> Ast.loc -> bool -> unit = fun _ _ _ _ -> ())
    ?(global_view_origin : Ast.expr -> string option = fun _ -> None)
    ?(separated : string -> string -> bool = fun _ _ -> false)
    ?(note_unsafe : Ast.loc -> unit = fun _ -> ())
    ?(decide_index : Ast.loc -> string option -> unit = fun _ _ -> ())
    ?(decide_array_index : Ast.loc -> string option -> unit = fun _ _ -> ())
    (finfo : Types.func_info) (fdef : Ast.func) =
  let bindings = finfo.Types.bindings in
  (* GitHub issue #763: every independent error is recorded, in traversal
     order; a read that reports marks its offending leaves initialized
     afterwards, so reads derived from it do not cascade. Recording never
     changes a verdict: any recorded error rejects the function. *)
  let errors = ref [] in
  let in_trial = ref false in
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
    | (Ast.TypeArray (element, _) | Ast.TypeSlice (element, _, _)) as t ->
        let element_leaves = leaves_of [] seen element in
        (prefix, t) :: (if List.exists (fun (path, _) -> is_pad path) element_leaves
          then [(prefix @ [pad], t)] else [])
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
  let param_ids = List.map2 (fun (name, _) id -> name, id)
      fdef.Ast.params bindings.Local_bindings.param_ids in
  let rec typed_params = function
    | [] -> []
    | (name, Some ty) :: rest -> (name, ty) :: typed_params rest
    | (_, None) :: rest -> typed_params rest in
  let param_types = typed_params fdef.Ast.params in
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
  (* Initialization clauses name tracked output parameters. In particular,
     a plain &mut input promises fields, not padding: an unchecked ensures
     on that input must not manufacture a whole-byte guarantee. *)
  (* ---- immutable bindings: the atoms of linear terms ------------------- *)
  let mutable_ids = Hashtbl.create 16 in
  let let_mut_ids = Hashtbl.create 16 in
  let binding_names = Hashtbl.create 16 in
  let rec scan_stmts ss = List.iter scan_stmt ss
  and scan_stmt (s : Ast.stmt) =
    (match s.desc, Local_bindings.ids_for_stmt bindings s with
     | (Ast.Let (_, n, _, _, _) | Ast.LetMatch (_, n, _, _, _)), id :: _
     | Ast.For (n, _, _, _, _), [_; id] -> Hashtbl.replace binding_names id n
     | _ -> ());
    (match s.desc, Local_bindings.ids_for_stmt bindings s with
     | Ast.Let (true, _, _, _, _), id :: _ -> Hashtbl.replace let_mut_ids id ()
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
  let addr_taken = Hashtbl.create 8 in
  let changed_records = Hashtbl.create 8 in
  let written =
    let acc = Hashtbl.create 8 in
    let note (v : Ast.expr) n =
      match Local_bindings.id_for_expr bindings v with
      | Some id -> Hashtbl.replace acc ("#" ^ string_of_int id) ()
      | None -> Hashtbl.replace acc n () in
    let rec record_root (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Option.iter (fun id -> Hashtbl.replace changed_records id ())
          (Local_bindings.id_for_expr bindings e)
      | Ast.FieldGet (b, _) -> record_root b
      | _ -> () in
    let rec go (e : Ast.expr) = match e.desc with
      | Ast.AddrOf ({ desc = Ast.Var n; _ } as v) ->
          note v n; record_root v;
          (match Local_bindings.id_for_expr bindings v with
           | Some id -> Hashtbl.replace addr_taken id ()
           (* Name resolution found no local: taking a global's address
              does not expose unrelated local loop cursors. *)
           | None -> ())
      | Ast.Assign (({ desc = Ast.Var n; _ } as v), rhs) -> note v n; record_root v; go rhs
      | Ast.Assign (l, r) -> record_root l; go l; go r
      | Ast.AddrOf x -> record_root x; go x
      | Ast.Call (name, xs) ->
          let ps = match callee name e with Some (ps, _) -> ps | None -> [] in
          List.iteri (fun i x ->
            let shared = match List.nth_opt ps i with
              | Some (_, Some (Ast.TypeBorrow _)) -> true | _ -> false in
            if not shared then (match x.Ast.desc with
              | Ast.Var _ -> record_root x
              | _ -> ());
            go x) xs
      | Ast.Bnot x | Ast.Deref x | Ast.Cast (_, x)
      | Ast.FieldGet (x, _) | Ast.Unsafe x | Ast.VariantCtor (_, _, x) -> go x
      | Ast.BinOp (_, a, b) | Ast.Index (a, b) -> go a; go b
      | Ast.SliceOf (a, b, c) -> go a; go b; go c
      | Ast.StructLit xs | Ast.TupleLit xs -> List.iter go xs
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
      (match String.index_opt a '@' with
       | Some i -> name_of (String.sub a 1 (i - 1)) ^ "@" ^ String.sub a (i + 1) (String.length a - i - 1)
       | None -> name_of (String.sub a 1 (String.length a - 1)))
    else a in
  let show l = Init_pred.to_string ~name:atom_name l in
  (* Scratch facts name an element selected by a particular local authority,
     not every element of the backing array. An unsupported selector is an
     error: source position is not an identity across calls or iterations. *)
  let selected_roots = Hashtbl.create 8 in
  let binding_id (e : Ast.expr) name =
    match Local_bindings.id_for_expr bindings e with
    | Some id -> Some id
    | None -> List.assoc_opt name param_ids in
  let rec selector (e : Ast.expr) = match e.desc with
    | Ast.Var x -> (match binding_id e x with
        | Some id -> ("v" ^ string_of_int id, Some id)
        (* fold-not-proof: selector identity only; no range/width claim. *)
        | None -> (match Const_env.find x with
            | Some n -> ("literal:" ^ string_of_int n, None)
            | None ->
                error e.loc "scratch initialization needs a local selector or constant index";
                ("unsupported:" ^ x, None)))
    | Ast.FieldGet (b, f) -> let k, id = selector b in (k ^ "." ^ f, id)
    | Ast.IntLit n -> ("literal:" ^ Int64.to_string n, None)
    | _ ->
        error e.loc "scratch initialization needs a local selector or constant index";
        (Printf.sprintf "unsupported:%d:%d" e.loc.pos_lnum e.loc.pos_cnum, None) in
  let scratch_element global idx =
    let base = "G" ^ global in
    match Hashtbl.find_opt roots base with
    | Some r when r.array_root ->
        let selected, owner = selector idx in
        let key = base ^ "[" ^ selected ^ "]" in
        if not (Hashtbl.mem roots key) then begin
          Hashtbl.add roots key { r with display = global ^ "[" ^ selected ^ "]";
                                       array_root = false };
          Hashtbl.add selected_roots key (base, owner)
        end;
        { root = key; path = []; inside = false }
    | _ -> { root = base; path = []; inside = false } in
  let touch_root st key =
    if StringSet.mem key st.extras.touched then st else
    match Hashtbl.find_opt selected_roots key with
    | None -> st
    | Some (base, _) ->
        let u = List.fold_left (fun u (r, path) ->
          if Leaves.mem (base, path) st.u then Leaves.add (r, path) u else u)
          st.u (all_leaves key) in
        { st with u; extras = {st.extras with touched = StringSet.add key st.extras.touched} } in
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
    | Ast.Index (({ desc = Ast.Var g; _ } as base), idx)
      when StringMap.mem g scratch_names && Local_bindings.id_for_expr bindings base = None ->
        Some (scratch_element g idx)
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
  (* GitHub issue #978: a mutable unsigned local whose address is never
     taken is a versioned atom. [cur_vers] is the version map of the state
     being walked; every walk entry point sets it from its state. *)
  let versionable x id =
    not (immutable_var x id) && Hashtbl.mem let_mut_ids id && unsigned_id id
    && not (Hashtbl.mem addr_taken id) in
  let cur_vers = ref Types.IntMap.empty in
  let next_ver = ref 0 in
  let fresh_ver () = incr next_ver; !next_ver in
  let ver_name id k = Printf.sprintf "v%d@%d" id k in
  let ver_of vers id = match Types.IntMap.find_opt id vers with Some k -> k | None -> 0 in
  let ver_atom id = Init_pred.atom (ver_name id (ver_of !cur_vers id)) in
  let record_fields ty = match strip ty with
    | Ast.TypeNamed n | Ast.TypeIndexed (n, _) -> struct_fields n
    | _ -> None in
  let numeric_field ty field = match record_fields ty with
    | Some fields -> (match List.assoc_opt field fields with
        | Some ty -> unsigned_ty ty | None -> false)
    | None -> false in
  let field_name st id field =
    "field:" ^ ver_name id (ver_of st.vers id) ^ "." ^ field in
  let field_term st id field =
    if Hashtbl.mem changed_records id then None else
    match id_type id with
    | Some ty when numeric_field ty field -> Some (Init_pred.atom (field_name st id field))
    | _ -> None in
  let aliases : (int, view) Hashtbl.t = Hashtbl.create 8 in
  let entry_owners = List.fold_left (fun owners (name, storage) ->
    match List.assoc_opt name param_ids with
    | None -> owners
    | Some id ->
        let root = "owner-param:" ^ string_of_int id in
        Hashtbl.replace roots root
          { display = name; leaves = [[], owner_leaf_type storage];
            array_root = false; out_param = false };
        Types.IntMap.add id root owners) Types.IntMap.empty owner_parameters in
  let with_owners st owners = { st with extras = { st.extras with owners } } in
  let projected_root root =
    String.starts_with ~prefix:"owner-local:" root ||
    String.starts_with ~prefix:"owner-param:" root in
  let forget_owner_guards st root =
    let owner_guards = Types.IntMap.filter_map (fun _ roots ->
      let roots = StringSet.remove root roots in
      if StringSet.is_empty roots then None else Some roots) st.extras.owner_guards in
    { st with extras = { st.extras with owner_guards } } in
  let note_owner_invalidation = ref (fun (_ : string) -> ()) in
  let invalidate_owner st root =
    !note_owner_invalidation root;
    let st = forget_owner_guards st root in
    let leaf = root, [] in
    { st with u = Leaves.add leaf st.u;
      iv = List.filter (fun (location, _) -> location <> leaf) st.iv } in
  let projected_view st id = Option.map (fun root ->
    { vp = { root; path = []; inside = false };
      off = Init_pred.const 0; len = leaf_len {root; path = []; inside = false} })
    (Types.IntMap.find_opt id st.extras.owners) in
  (* Keep possible record aliases for the opaque-write check. A rebind
     adds a possibility, so a branch or loop cannot erase an older alias. *)
  let slot_aliases = Hashtbl.create 8 in
  let rec slot_alias_roots st (e : Ast.expr) =
    match slot_record_call e with
    | Some id ->
        (match Types.IntMap.find_opt id st.extras.owners with
         | Some root -> StringSet.singleton root
         | None -> StringSet.empty)
    | None ->
        match e.desc with
        | Ast.Var _ ->
            Option.fold ~none:StringSet.empty ~some:(fun id ->
              let aliases = Option.value ~default:StringSet.empty
                (Hashtbl.find_opt slot_aliases id) in
              match Types.IntMap.find_opt id st.extras.owners with
              | Some root when (Hashtbl.find roots root).leaves = [[], Ast.TypeBool] ->
                  StringSet.add root aliases
              | _ -> aliases) (Local_bindings.id_for_expr bindings e)
        | Ast.Call (_, args) | Ast.StructLit args | Ast.TupleLit args ->
            List.fold_left (fun roots arg -> StringSet.union roots (slot_alias_roots st arg))
              StringSet.empty args
        | Ast.VariantCtor (_, _, inner) -> slot_alias_roots st inner
        | Ast.AddrOf inner | Ast.Deref inner | Ast.Cast (_, inner)
        | Ast.Unsafe inner | Ast.Index (inner, _) | Ast.SliceOf (inner, _, _)
        | Ast.FieldGet (inner, _) -> slot_alias_roots st inner
        | _ -> StringSet.empty in
  let note_slot_alias st id rhs =
    let roots = slot_alias_roots st rhs in
    if not (StringSet.is_empty roots) then
      Hashtbl.replace slot_aliases id
        (StringSet.union roots (Option.value ~default:StringSet.empty
          (Hashtbl.find_opt slot_aliases id))) in
  let observe_param_return st tag loc =
    if not !in_trial then
      Types.IntMap.iter (fun _ root ->
        let parameter = (Hashtbl.find roots root).display in
        note_owner_return parameter tag loc
          (not (Leaves.mem (root, []) st.u))) entry_owners in

  (* Linear integer terms of the body, under the path facts [f].

     GitHub issue #983: a term is the MACHINE value of its expression, so
     coverage decided over mathematical integers is coverage of the
     program's elements. Every operand is a usize; a leaf reads at that
     width: a literal or constant is a value in [0, 2^64), so a negative
     native reading (0xFFFFFFFFFFFFFFFF reads as -1) is refused, and so is
     one at or past Init_pred.limit. A step must not wrap: `a - b` needs
     the facts to show a - b >= 0, and `a + b` or `k * a` needs them to show
     the result at most a constant below 2^64 or at most some atom (every
     atom is a usize, so below 2^64). Without these, `0xFFFF_FFFF_FFFF_FFFF`
     passed as an offset or `m - 1` under m == 0 read as -1, and a callee's
     [n, 8) covered [0, 8) in the caller. *)
  let leaf_const ?src v =
    let ok = match v with
      | Some c -> (c >= 0 || !Range_obligation.fault_native_init_leaf)
                  && c <= Init_pred.limit
      | None -> false in
    match v with
    | Some c when ok ->
        (* GitHub issue #960: z3 re-reads the literal from its source
           pattern at usize and compares it with the checker's reading,
           so a native misreading (#983) is a counterexample. *)
        (match src with
         | Some (loc, pattern) ->
             Range_obligation.record_text loc
               (Init_pred.leaf_obligation ~read:c ~pattern
                  ~bits:(Target_info.pointer_bit_width ()))
         | None -> ());
        Some (Init_pred.const c)
    | _ -> None in
  let const_src (e : Ast.expr) x =
    Option.map (fun n -> (e.Ast.loc, n)) (Const_env.raw_literal x) in
  (* Does [t] >= 0 (nonneg) or t <= some value below 2^64 (fits_above)
     follow from the path's equalities and facts? *)
  (* GitHub issue #990: each no-wrap judgement below is also written as an
     obligation stating the machine property (the term is a usize) under
     the same path facts, so z3 re-checks the checker's search. *)
  let nowrap_ob (st : state) loc kind (t : Init_pred.lin) =
    Range_obligation.record_text loc
      (Init_pred.nowrap_obligation ~claim:(show t) ~facts:st.facts st.eqs
         ~bits:(Target_info.pointer_bit_width ()) kind t) in
  let nonneg (st : state) (t : Init_pred.lin) =
    !Range_obligation.fault_init_nowrap
    || Init_pred.entails (Init_pred.normalize_facts st.eqs st.facts)
         (Init_pred.normalize st.eqs t) in
  let fits_above (st : state) (t : Init_pred.lin) =
    let f = Init_pred.normalize_facts st.eqs st.facts in
    let t = Init_pred.normalize st.eqs t in
    Init_pred.entails f (Init_pred.sub (Init_pred.const Init_pred.limit) t)
    || List.exists (fun a -> Init_pred.entails f (Init_pred.sub (Init_pred.atom a) t))
         (List.sort_uniq compare
            (Init_pred.atoms t
             @ List.concat_map Init_pred.atoms f.Init_pred.ge
             @ List.concat_map (fun (x, _, _) -> [x]) f.Init_pred.mins)) in
  let checked k = try k () with Init_pred.Overflow -> None in
  let rec lin (f : state) (e : Ast.expr) : Init_pred.lin option =
    match e.desc with
    | Ast.IntLit n -> leaf_const (Ast.int_of_intlit n) ~src:(e.loc, n)
    | Ast.Var x ->
        (match Local_bindings.id_for_expr bindings e with
         | Some id when immutable_var x id -> Some (v_atom id)
         | Some id when versionable x id -> Some (ver_atom id)
         | Some _ -> None
         | None -> (match leaf_const (Const_env.find x) ?src:(const_src e x) with
           | Some _ as term -> term
           | None -> leaf_const (global_singleton x)))
    | Ast.SizeOf t -> leaf_const (size_of t)
    | Ast.BinOp (Ast.Add, a, b) ->
        (match lin f a, lin f b with
         | Some x, Some y ->
             checked (fun () ->
               let t = Init_pred.add x y in
               if fits_above f t then (nowrap_ob f e.loc Init_pred.Below t; Some t)
               else None)
         | _ -> None)
    | Ast.BinOp (Ast.Sub, a, b) ->
        (match lin f a, lin f b with
         | Some x, Some y ->
             checked (fun () ->
               let t = Init_pred.sub x y in
               if nonneg f t then (nowrap_ob f e.loc Init_pred.Nonneg t; Some t)
               else None)
         | _ -> None)
    | Ast.BinOp (Ast.Mul, a, b) ->
        let prod k y = checked (fun () ->
          let t = Init_pred.scale k y in
          if fits_above f t then (nowrap_ob f e.loc Init_pred.Below t; Some t)
          else None) in
        (match lin f a, lin f b with
         | Some x, Some y when Init_pred.SMap.is_empty x.m -> prod x.c y
         | Some x, Some y when Init_pred.SMap.is_empty y.m -> prod y.c x
         | _ -> None)
    | Ast.FieldGet (b, "len") ->
        (match view_of f b with
         | Some v -> v.len
         | None ->
             (match b.desc, Local_bindings.id_for_expr bindings b with
              | Ast.Cast (Ast.TypeSlice (Ast.TypeU8, _, _),
                  ({ desc = Ast.Var name; _ } as source)), _
                  when Local_bindings.id_for_expr bindings source = None ->
                  leaf_const (global_byte_array_length name)
              | Ast.Var x, Some id when immutable_var x id -> Some (len_atom id)
              | _ -> None))
    | Ast.FieldGet (({ desc = Ast.Var _; _ } as b), field) ->
        Option.bind (Local_bindings.id_for_expr bindings b) (fun id -> field_term f id field)
    | _ -> None
  (* A tracked view: an array or slice leaf, an alias of one, a sub-slice
     of a view with linear bounds, or a same-element `as` slice cast. The
     bounds are machine values (lin); the sub-slice's bounds check then
     keeps off + lo and hi - lo inside the leaf. *)
  and view_of (f : state) (e : Ast.expr) : view option =
    let projected =
      if Types.IntMap.is_empty f.extras.owners then None
      else Option.bind (owner_view_call e) (projected_view f) in
    match projected with
    | Some _ as view -> view
    | None -> match e.desc with
    | Ast.Var _ when (match Local_bindings.id_for_expr bindings e with
                      | Some id -> Hashtbl.mem aliases id | None -> false) ->
        Option.bind (Hashtbl.find_opt aliases (Option.get (Local_bindings.id_for_expr bindings e)))
          (fun v ->
            let root = v.vp.root in
            if projected_root root &&
               not (Types.IntMap.exists (fun _ live -> live = root) f.extras.owners)
            then None else Some v)
    | Ast.SliceOf (b, lo, hi) ->
        (match view_of f b, lin f lo, lin f hi with
         | Some v, Some lo, Some hi ->
             checked (fun () ->
               Some { v with off = Init_pred.add v.off lo; len = Some (Init_pred.sub hi lo) })
         | _ -> None)
    | Ast.Cast (t, inner) ->
        (match strip t, view_of f inner with
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
  (* A comparison side whose mathematical value is its machine value, so a
     fact about it is a fact about the program: a nonnegative constant, an
     immutable unsigned binding, a view's length, or a - b of such sides
     when the facts already show b <= a (no wraparound). Anything else,
     such as a + b, gives no fact. *)
  let rec side (st : state) (e : Ast.expr) : Init_pred.lin option =
    let nonneg_const = function
      | Some (l : Init_pred.lin) when Init_pred.SMap.is_empty l.m && l.c >= 0 -> Some l
      | _ -> None in
    match e.desc with
    | Ast.IntLit _ | Ast.SizeOf _ -> nonneg_const (lin st e)
    | Ast.Var x ->
        (match Local_bindings.id_for_expr bindings e with
         | Some id when immutable_var x id && unsigned_id id -> Some (v_atom id)
         | Some id when versionable x id -> Some (ver_atom id)
         | Some _ -> None
         | None -> nonneg_const (lin st e))
    | Ast.FieldGet (b, "len") when view_of st b <> None -> lin st e
    | Ast.FieldGet ({ desc = Ast.Var x; _ } as b, "len") ->
        (match Local_bindings.id_for_expr bindings b with
         | Some id when immutable_var x id
                        && (match Option.map strip (id_type id) with
                            | Some (Ast.TypeSlice _) -> true | _ -> false) ->
             Some (len_atom id)
         | _ -> None)
    | Ast.FieldGet ({ desc = Ast.Var _; _ }, _) -> lin st e
    | Ast.BinOp ((Ast.Add | Ast.Mul), a, b) ->
        (match side st a, side st b with
         | Some _, Some _ -> lin st e
         | _ -> None)
    | Ast.BinOp (Ast.Sub, a, b) ->
        (match side st a, side st b with
         | Some x, Some y when Init_pred.entails st.facts (Init_pred.sub x y) ->
             (* #990: the same no-wrap judgement, re-checked by z3. *)
             nowrap_ob st e.loc Init_pred.Nonneg (Init_pred.sub x y);
             Some (Init_pred.sub x y)
         | _ -> None)
    | _ -> None
  in
  let add_fact (st : state) t =
    if List.exists (Init_pred.equal t) st.facts.Init_pred.ge then st
    else { st with facts = { st.facts with Init_pred.ge = t :: st.facts.Init_pred.ge } } in
  let add_declared_bounds st id atom =
    match id_type id with
    | Some (Ast.TypeRefined (lo, hi, base)) when unsigned_ty base
        && lo >= 0 && hi > lo && hi <= Init_pred.limit ->
        add_fact (add_fact st (Init_pred.sub atom (Init_pred.const lo)))
          (Init_pred.sub (Init_pred.const (hi - 1)) atom)
    | _ -> st in
  (* The state on the path where condition [c] evaluated to [b]. Operands
     of `&&` (true) and `||` (false) are assumed left to right, so a later
     operand's subtraction may rely on an earlier operand. *)
  let rec assume (st : state) (c : Ast.expr) (b : bool) : state =
    match c.desc, b with
    | Ast.BinOp (Ast.And, l, r), true | Ast.BinOp (Ast.Or, l, r), false ->
        assume (assume st l b) r b
    | Ast.BinOp ((Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge | Ast.Eq | Ast.Ne) as op, l, r), _ ->
        (match side st l, side st r with
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
    let st = touch_root st p.root in
    let l = (p.root, p.path) in
    if not (Leaves.mem l st.u) || Init_pred.is_empty iv then st
    else
      let st = { st with iv = (l, iv) :: st.iv } in
      match leaf_len p with
      | Some n when Init_pred.uncovered ~need_gap:false ~eqs:st.eqs ~facts:st.facts (ivs_of st l)
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
  let padding_place p =
    let q = { p with path = p.path @ [pad] } in
    if leaf_type q.root q.path <> None then Some q else None in
  let forget_array_padding st p = match padding_place p with
    | None -> st
    | Some q ->
        let leaf = (q.root, q.path) in
        { st with u = Leaves.add leaf st.u;
                  iv = List.filter (fun (l, _) -> l <> leaf) st.iv } in
  let forget_padding st p =
    let st = touch_root st p.root in
    let pads = List.filter (fun (r, path) ->
      r = p.root && is_prefix p.path path && is_pad path) (all_leaves p.root) in
    { st with u = List.fold_left (fun u leaf -> Leaves.add leaf u) st.u pads;
              iv = List.filter (fun (leaf, _) -> not (List.mem leaf pads)) st.iv } in
  let add_bytes_iv st p iv =
    let st = add_iv st p iv in
    match padding_place p with Some q -> add_iv st q iv | None -> st in
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
  let record_leaf_coverage st p ~bytes loc what =
    if !Range_obligation.enabled then
      let leaves = List.map (fun ((_, path) as leaf) ->
        (String.concat "." (root_display p :: path),
         not (Leaves.mem leaf st.u),
         (is_prefix p.path path || is_prefix path p.path)
           && (bytes || not (is_pad path)))) (all_leaves p.root) in
      Init_obligation.record loc
        ~claim:(fdef.Ast.name ^ ": " ^ what ^ ": " ^ path_to_string (root_display p) p.path) leaves
  in
  let need st (v : view) ((a, b) : Init_pred.interval) loc what =
    let st = touch_root st v.vp.root in
    let l = leaf_of_view v in
    if not (Leaves.mem l st.u) then begin
      record_leaf_coverage st v.vp ~bytes:true loc what; st
    end else
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
    let st = touch_root st v.vp.root in
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
    let st = touch_root st p.root in
    record_leaf_coverage st p ~bytes loc (if bytes then "byte read" else "field read");
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
  let is_len_of f (e : Ast.expr) = match e.desc with
    | Ast.FieldGet (base, "len") ->
        view_of f base <> None ||
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
    let st = touch_root st p.root in
    if p.inside then st
    else
      let u = Leaves.filter (fun (r, l) -> not (r = p.root && is_prefix p.path l)) st.u in
      { st with u; iv = drop_root_ivs u st.iv }
  in
  (* A field-only contract never asserts that padding was written. *)
  let fill_fields st p =
    let st = touch_root st p.root in
    if p.inside then st
    else
      let u = Leaves.filter (fun (r, l) ->
        not (r = p.root && is_prefix p.path l && not (is_pad l))) st.u in
      { st with u; iv = drop_root_ivs u st.iv }
  in
  (* ---- contracts -------------------------------------------------------- *)
  (* A contract term over the callee's parameter names, `result` and an arm
     binder, mapped by [env]. *)
  let rec clin (env : string -> contract_value -> Init_pred.lin option) (e : Ast.expr) =
    match e.desc with
    (* GitHub issue #983: a contract term is mathematical over its atoms
       (the callee proves exactly that interval, and the caller maps each
       atom to a machine value through [lin]), but its leaves read at the
       usize width as [lin]'s do. *)
    | Ast.IntLit n -> leaf_const (Ast.int_of_intlit n) ~src:(e.loc, n)
    | Ast.Var x ->
        (match env x (`Val None) with
         | Some t -> Some t
         | None -> (match leaf_const (Const_env.find x) ?src:(const_src e x) with
           | Some _ as term -> term
           | None -> leaf_const (global_singleton x)))
    | Ast.SizeOf t -> leaf_const (size_of t)
    | Ast.FieldGet ({ desc = Ast.Var x; _ }, "len") -> env x (`Len None)
    | Ast.FieldGet ({ desc = Ast.Var x; _ }, field) -> env x (`Field field)
    | Ast.BinOp (Ast.Add, a, b) ->
        (match clin env a, clin env b with
         | Some x, Some y -> checked (fun () -> Some (Init_pred.add x y)) | _ -> None)
    | Ast.BinOp (Ast.Sub, a, b) ->
        (match clin env a, clin env b with
         | Some x, Some y -> checked (fun () -> Some (Init_pred.sub x y)) | _ -> None)
    | Ast.BinOp (Ast.Mul, a, b) ->
        (match clin env a, clin env b with
         | Some x, Some y when Init_pred.SMap.is_empty x.m ->
             checked (fun () -> Some (Init_pred.scale x.c y))
         | Some x, Some y when Init_pred.SMap.is_empty y.m ->
             checked (fun () -> Some (Init_pred.scale y.c x))
         | _ -> None)
    | _ -> None
  in
  (* The place a contract names, split into its root and optional bounds:
     `x`, `x[lo..<hi]`, `G[s.index].f`, `G[s.index].f[lo..<hi]`. *)
  let rec split_target ?(fields = false) (e : Ast.expr) =
    match (if fields then slot_contract_owner e else projected_contract_owner e) with
    | Some owner -> Some (`OwnerProjection owner, None)
    | None -> match e.desc with
    | Ast.SliceOf (b, lo, hi) ->
        (match split_target b with
         | Some ((`Param _ | `Global _) as r, None) -> Some (r, Some (lo, hi))
         | _ -> None)
    | Ast.Var x -> Some (`Param (x, []), None)
    | Ast.FieldGet _ ->
        let rec chain (e : Ast.expr) acc = match e.desc with
          | Ast.FieldGet (b, f) -> chain b (f :: acc)
          | Ast.Index ({ desc = Ast.Var g; _ }, idx) -> Some (`Global (g, idx, acc))
          | Ast.Var x -> Some (`Param (x, acc))
          | _ -> None in
        (match chain e [] with
         | Some target -> Some (target, None)
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
  let validate_target ?(fields = false) loc (e : Ast.expr) ~binders =
    let env x kind =
      let ty = if x = "result" then fdef.Ast.ret_type else
        match List.assoc_opt x binders with
        | Some ty -> ty
        | None -> List.assoc_opt x param_types in
      match kind with
      | `Field field -> (match ty with
          | Some ty when numeric_field ty field -> Some (Init_pred.atom (x ^ "." ^ field))
          | _ -> None)
      | _ -> if x = "result" || List.mem_assoc x binders || List.mem_assoc x param_ids
             then Some (Init_pred.atom x) else None in
    match split_target ~fields e with
    | None ->
        error loc "init(...) names a parameter, `p[lo..<hi]`, or a scratch \
                   slot `G[s.index].f`"
    | Some (target, bounds) ->
        (match target with
         | `Param (x, _) when not (List.mem_assoc x param_ids) ->
             error loc (Printf.sprintf "init(%s): '%s' is not a parameter of '%s'"
                          x x fdef.Ast.name)
         | `Param (x, path) ->
             (if path <> [] then begin
               let key = "L" ^ string_of_int (List.assoc x param_ids) in
               match Hashtbl.find_opt roots key with
               | Some r when List.exists (fun (leaf, _) -> is_prefix path leaf) r.leaves ->
                   if bounds <> None then
                     (match Option.map strip (leaf_type key path) with
                      | Some (Ast.TypeArray _) -> ()
                      | _ -> error loc "an init field range needs an inline fixed array")
               | _ -> error loc "init field contract needs an inline tracked field"
             end);
             if Init_state.param_qual fdef.Ast.def_loc x <> Some Init_state.Uninit then
               error loc (Printf.sprintf
                 "initialization contract: '%s' is not `borrow uninit`; use a tracked output parameter to check its initialization clauses" x)
         | `OwnerProjection x ->
             if not (match List.assoc_opt x owner_parameters with
               | Some SlotFields -> fields
               | Some (OwnerBytes _) -> not fields
               | None -> false) then
               error loc "initialization projection needs a matching tracked owner parameter"
         | `Global (g, idx, _) ->
             let rec owner_name t = match strip t with
               | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> owner_name t
               | Ast.TypeIndexed (n, _) | Ast.TypeNamed n when linear_owner n -> Some n
               | _ -> None in
             let declaration = Owned_by_registry.find g in
             let ok_idx = match idx.desc with
               | Ast.FieldGet ({ desc = Ast.Var s; _ }, field) ->
                   (match List.assoc_opt s param_types, declaration with
                    | Some t, None -> owner_name t <> None
                    | Some t, Some d ->
                        field = d.field &&
                        (match strip t with
                         | Ast.TypeBorrow t -> owner_name t = Some d.token
                         | _ -> false)
                    | None, _ -> false)
               | _ -> false in
             if not (StringMap.mem g scratch_names) then
               error loc slot_capability_rule
             else if not ok_idx then
               match declaration with
               | None -> error loc slot_capability_rule
               | Some d -> error loc (Printf.sprintf
                   "slot-owned scratch initialization must select with a borrowed %s parameter's .%s"
                   d.token d.field));
        (match bounds with
         | Some (lo, hi) ->
             List.iter (fun b ->
               if clin env b = None then
                 error loc "an init(...) bound must be a linear integer term \
                            over parameters, their .len, unsigned record fields, constants and result")
               [lo; hi]
         | None -> ())
  in
  List.iter (fun (c : Init_state.clause) ->
    let preds_of = function
      | Init_state.CPlain p | Init_state.CIf (_, p) -> [(p, [])]
      | Init_state.CMatch arms ->
          List.map (fun (pat, p) ->
            let payload = match Option.map strip fdef.Ast.ret_type, pat.Init_state.case with
              | Some (Ast.TypeNamed n | Ast.TypeIndexed (n, _) | Ast.TypeVariant (n, _, _)), Some k ->
                  variant_payload n k
              | _ -> None in
            (p, match pat.Init_state.bind with Some b -> [(b, payload)] | None -> [])) arms in
    List.iter (fun (p, binders) -> match p with
      | Init_state.PInit e when not c.requires && projected_contract_owner e <> None ->
          error c.cloc "owner storage projections are supported in requires init clauses"
      | Init_state.PInit e -> validate_target c.cloc e ~binders
      | Init_state.PFields e when slot_contract_owner e <> None ->
          (match c.requires, c.body with
           | true, Init_state.CPlain _ -> validate_target ~fields:true c.cloc e ~binders
           | _ -> error c.cloc "slot field projections are supported in plain requires init_fields clauses")
      | Init_state.PFields e ->
          let rec record_reference t = match strip t with
            | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> record_reference t
            | Ast.TypeRefMut t ->
                (match strip t with
                 | Ast.TypeNamed n | Ast.TypeIndexed (n, _) ->
                     Option.is_some (struct_fields n)
                 | _ -> false)
            | _ -> false in
          let record_array t =
            let rec element = function
              | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> element (strip t)
              | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _, _) -> record_fields t <> None
              | _ -> false in
            element (strip t) in
          (match e.desc with
           | Ast.Var x when (match List.assoc_opt x param_types with
               | Some t -> record_reference t || record_array t | None -> false) ->
               validate_target c.cloc e ~binders
           | Ast.SliceOf ({ desc = Ast.Var x; _ }, _, _)
             when (match List.assoc_opt x param_types with
               | Some t -> record_array t | None -> false) ->
               validate_target c.cloc e ~binders
           | _ -> error c.cloc
               "init_fields needs a whole mutable-reference record parameter or a record-array range")
      | Init_state.PLinked (array, head) ->
          validate_target c.cloc array ~binders;
          validate_target c.cloc head ~binders;
          (match c.body, split_target array, split_target head with
           | Init_state.CPlain _, Some (`Param (a, ap), None), Some (`Param (h, hp), None)
             when a = h && ap <> [] && hp <> [] ->
               let root = "L" ^ string_of_int (List.assoc a param_ids) in
               (match Option.map strip (leaf_type root ap), Option.map strip (leaf_type root hp) with
                | Some (Ast.TypeArray (Ast.TypeUsize, _)), Some Ast.TypeUsize -> ()
                | _ -> error c.cloc "init_links needs an inline usize array and a usize head field")
           | _ -> error c.cloc "init_links needs an unconditional contract on two fields of one output parameter")
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
  (* Parameters a contract names: their whole-init default at return (and,
     at a call, the whole-argument read) is replaced by the clauses. A
     requires-only `borrow uninit` parameter is read where the requires
     says and owes nothing at return (#975). *)
  let named_params cs =
    List.concat_map (fun (c : Init_state.clause) ->
      let preds = match c.body with
        | Init_state.CPlain p | Init_state.CIf (_, p) -> [p]
        | Init_state.CMatch arms -> List.map snd arms in
      List.filter_map (function
        | Init_state.PInit e | Init_state.PFields e | Init_state.PLinked (e, _) ->
            (match split_target e with Some (`Param (x, _), _) -> Some x | _ -> None)
        | Init_state.PTrue -> None) preds) cs in
  let own_named = named_params contracts in
  let out_keys = Hashtbl.fold (fun k r acc ->
    if r.out_param && not (List.mem r.display own_named) then k :: acc else acc)
      roots [] in
  (* Resolve a contract predicate to facts in the CURRENT function's terms.
     [arg_view x] gives the view the caller passes for parameter x (or the
     callee's own root, when checking a body); [env] maps names to terms. *)
  let rec resolve_pred ?(strengthen = false) ?(owner_view = fun _ -> None)
      ~arg_view ~index_expr ~env (p : Init_state.pred)
      : (view * Init_pred.interval) option list =
    match p with
    | Init_state.PTrue -> []
    | Init_state.PLinked (_, head) ->
        resolve_pred ~strengthen ~owner_view ~arg_view ~index_expr ~env (Init_state.PInit head)
    | Init_state.PInit e | Init_state.PFields e ->
        let endpoint = match p with Init_state.PFields _ -> -2 | _ -> -1 in
        (match split_target ~fields:(endpoint = -2) e with
         | None -> [None]
         | Some (target, bounds) ->
             let v = match target with
               | `Param (x, path) ->
                   (match arg_view x with
                    | Some (`Whole p) when path <> [] ->
                        let p = { p with path = p.path @ path } in
                        (match Option.map strip (leaf_type p.root p.path) with
                         | Some (Ast.TypeArray _) ->
                             Some (`View { vp = p; off = Init_pred.const 0; len = leaf_len p })
                         | _ -> Some (`Whole p))
                    | v when path = [] -> v
                    | Some `Untracked -> Some `Untracked
                    | _ -> None)
               | `OwnerProjection name ->
                   Option.bind (owner_view name) (fun v ->
                     match endpoint, v.len with
                     | -2, None -> Some (`Whole v.vp)
                     | -1, Some _ -> Some (`View v)
                     | _ -> None)
               | `Global (g, idx, path) ->
                   if StringMap.mem g scratch_names then
                     let p = scratch_element g (index_expr idx) in
                     let p = { p with path } in
                     if leaf_elem p <> None then
                       Some (`View { vp = p; off = Init_pred.const 0; len = leaf_len p })
                     else Some (`Whole p)
                   else None in
             (match v with
              | None -> [None]
              | Some `Untracked -> []
              | Some (`Whole p) ->
                  [Some ({ vp = p; off = Init_pred.const 0; len = None },
                         (Init_pred.const 0, Init_pred.const endpoint))]
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
                   | Some iv ->
                       Some (v, iv) :: (match p, padding_place v.vp with
                         | Init_state.PInit _, Some padding -> [Some ({ v with vp = padding }, iv)]
                         | _ -> [])
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
  (* Negative endpoints cannot be element ranges: -1 is whole storage,
     -2 is a record's fields only. Guarded substitution leaves both fixed. *)
  let whole_kind (v, (lo, hi)) =
    if v.len <> None || not (Init_pred.equal lo (Init_pred.const 0)) then None
    else if Init_pred.equal hi (Init_pred.const (-1)) then Some true
    else if Init_pred.equal hi (Init_pred.const (-2)) then Some false
    else None in
  let apply_fact st ((v, iv) as fact) =
    match whole_kind fact with
    | Some true -> fill st v.vp
    | Some false -> fill_fields st v.vp
    | None -> add_iv st v.vp iv in
  let need_fact st ((v, iv) as fact) loc what =
    let st = touch_root st v.vp.root in
    match whole_kind fact with
    | Some bytes ->
        record_leaf_coverage st v.vp ~bytes loc what;
        (if Leaves.exists (fun (r, l) -> r = v.vp.root && is_prefix v.vp.path l
                 && ((bytes && not !Range_obligation.fault_init_padding) || not (is_pad l))) st.u
         then begin
           error loc (Printf.sprintf "%s: '%s' may be uninitialized here%s" what
                        (path_to_string (root_display v.vp) v.vp.path)
                        (if bytes then " (including padding)" else ""));
           fill st v.vp
         end else st)
    | None -> need st v iv loc what
  in
  let subst_atom a by (lo, hi) =
    (Init_pred.subst a by lo, Init_pred.subst a by hi) in
  (* Linked facts are separate from contiguous initialization intervals.
     They never turn a partial array into a fully initialized byte view. *)
  let link_storage p = (p.root, p.path) in
  let linked_contract = List.exists (fun (c : Init_state.clause) ->
    match c.body with Init_state.CPlain (Init_state.PLinked _) -> true | _ -> false) contracts in
  (* Most functions never use a linked fact. Allocate their helper closures
     only when such a fact or contract is actually encountered. *)
  let link_ops = lazy (
  let rec link_value_key (e : Ast.expr) = match e.desc with
    | Ast.Var n -> (match binding_id e n with
        | Some id -> Some ("L" ^ string_of_int id ^ ":")
        | None -> Option.map (fun (n : Init_pred.lin) -> "literal:" ^ string_of_int n.c)
            (leaf_const (Const_env.find n) ?src:(const_src e n)))
    | Ast.IntLit n -> Some ("literal:" ^ Int64.to_string n)
    | Ast.FieldGet (base, field) ->
        Option.map (fun key -> key ^ "." ^ field) (link_value_key base)
    | _ -> None in
  let link_key p = p.root ^ ":" ^
      (if p.path = [] then "" else "." ^ String.concat "." p.path) in
  (* This helper is also called after an assignment has advanced scalar
     versions. Only source-constant terms can be read then; re-evaluating
     x + 1 in the post-state would describe the next increment instead. *)
  let rec link_constant (e : Ast.expr) = match e.desc with
    | Ast.IntLit _ | Ast.SizeOf _ -> true
    (* fold-not-proof: only tests whether this syntax names a constant;
       link_terminal reads its value through lin/leaf_const below. *)
    | Ast.Var n -> binding_id e n = None && Const_env.find n <> None
    | Ast.BinOp ((Ast.Add | Ast.Sub | Ast.Mul), a, b) -> link_constant a && link_constant b
    | _ -> false in
  let link_terminal st p e = if not (link_constant e) then false else
    match leaf_len p, checked (fun () -> lin st e) with
    | Some n, Some term ->
        (match checked (fun () -> Some (Init_pred.normalize st.eqs (Init_pred.sub term n))) with
         | Some diff -> Init_pred.SMap.is_empty diff.m && diff.c >= 0
         | None -> false)
    | _ -> false in
  let link_ready st p e =
    let storage = link_storage p in
    not (Leaves.mem storage st.u) || link_terminal st p e ||
    (match link_value_key e with
     | Some value -> Init_link.ready st.extras.links ~full:false storage value
     | None -> false) in
  let link_view_ready st v e =
    leaf_elem v.vp = Some Ast.TypeUsize &&
    Init_pred.equal v.off (Init_pred.const 0) && link_ready st v.vp e in
  let link_assign st target rhs =
    if not linked_contract && Init_link.Values.is_empty st.extras.links then st else
    let links = match link_value_key rhs with
      | Some source -> Init_link.copy st.extras.links ~target ~source
      | None -> Init_link.forget_value st.extras.links target in
    let links = Hashtbl.fold (fun root r links ->
      List.fold_left (fun links (path, ty) -> match strip ty with
        | Ast.TypeArray (Ast.TypeUsize, _) ->
            let p = {root; path; inside = false} in
            let ready = link_terminal st p rhs || (match rhs.Ast.desc with
              | Ast.Index (array, index) -> (match view_of st array with
                  | Some v when link_storage v.vp = (root, path) -> link_view_ready st v index
                  | _ -> false)
              | _ -> false) in
            if ready then Init_link.establish links (root, path) target else links
        | _ -> links) links r.leaves) roots links in
    set_links st links in
  let resolve_link ~arg_view array head =
    match split_target array, split_target head with
    | Some (`Param (a, ap), None), Some (`Param (h, hp), None) when a = h ->
        (match arg_view a with
         | Some (`Whole p) when not p.inside ->
             let array = {p with path = p.path @ ap} and head = {p with path = p.path @ hp} in
             (match leaf_elem array, leaf_type head.root head.path with
              | Some Ast.TypeUsize, Some Ast.TypeUsize -> Some (`Tracked (array, head))
              | _ -> None)
         | Some `Untracked -> Some `Full
         | _ -> None)
    | _ -> None in
  let require_link st ~arg_view pred loc = match pred with
    | Init_state.PLinked (array, head) ->
        (match resolve_link ~arg_view array head with
         | Some `Full -> ()
         | Some (`Tracked (array, head)) ->
             let full = not (Leaves.mem (link_storage array) st.u) in
             if not (Init_link.ready st.extras.links ~full (link_storage array) (link_key head)) then
               error loc "init_links cannot prove initialized traversal from this head in this storage"
         | None -> error loc "init_links storage identity is not expressible at this boundary");
        st
    | _ -> st in
  let establish_link st ~arg_view pred loc = match pred with
    | Init_state.PLinked (array, head) ->
        (match resolve_link ~arg_view array head with
         | Some `Full -> st
         | Some (`Tracked (array, head)) ->
             set_links st (Init_link.establish st.extras.links (link_storage array) (link_key head))
         | None -> error loc "init_links storage identity is not expressible at this boundary"; st)
    | _ -> st in
  let shared_root key = String.starts_with ~prefix:"G" key ||
    match Hashtbl.find_opt roots key with Some r -> r.out_param | None -> false in
  let invalidate_aliases links root =
    if not (shared_root root) then links else
      Hashtbl.fold (fun other _ links ->
        if other <> root && shared_root other then
          let invalidated = Init_link.invalidate_path links (other, []) in
          if invalidated = links || separated root other then links else invalidated
        else links) roots links in
    { assign_value = link_assign; value_key = link_value_key;
      view_ready = link_view_ready; check_pred = require_link;
      apply_pred = establish_link; invalidate_aliases }) in
  let unsafe_depth = ref 0 in
  let unsafe_uses = ref 0 in
  let bound_gs : (int, guarded list) Hashtbl.t = Hashtbl.create 8 in
  let invalidate_selector st id =
    let keys = Hashtbl.fold (fun key (_, owner) acc ->
      if owner = Some id then key :: acc else acc) selected_roots [] in
    if keys = [] then st else begin
      let affected (v, _) = List.mem v.vp.root keys in
      Hashtbl.filter_map_inplace (fun _ gs ->
        let gs = List.filter (function GBool (_, fs) | GPositive (_, fs) | GCase (_, _, fs) ->
          not (List.exists affected fs)) gs in
        if gs = [] then None else Some gs) bound_gs;
      let u = List.fold_left (fun u key ->
        List.fold_left (fun u l -> Leaves.add l u) u (all_leaves key)) st.u keys in
      { st with u; iv = List.filter (fun ((r, _), _) -> not (List.mem r keys)) st.iv;
                extras = {st.extras with touched = List.fold_left (fun seen key -> StringSet.add key seen) st.extras.touched keys} }
    end in
  let live_guard_fact st id (view, _) =
    let root = view.vp.root in
    not (projected_root root) ||
    Option.fold ~none:false ~some:(StringSet.mem root)
      (Types.IntMap.find_opt id st.extras.owner_guards) in
  let apply_positive st =
    Hashtbl.fold (fun id gs st -> List.fold_left (fun st -> function
      | GPositive (result, facts)
        when Init_pred.entails (Init_pred.normalize_facts st.eqs st.facts)
          (Init_pred.normalize st.eqs (Init_pred.sub result (Init_pred.const 1))) ->
          List.fold_left apply_fact st (List.filter (live_guard_fact st id) facts)
      | _ -> st) st gs) bound_gs st in
  let rec selector_binding (e : Ast.expr) = match e.desc with
    | Ast.Var x -> binding_id e x
    | Ast.FieldGet (b, _) -> selector_binding b
    | _ -> None in
  let invalidate_place st e = match selector_binding e with
    | Some id -> invalidate_selector st id | None -> st in
  let guard_facts = function
    | GBool (_, facts) | GPositive (_, facts) | GCase (_, _, facts) -> facts in
  let bound_guarded st (e : Ast.expr) =
    Option.bind (Local_bindings.id_for_expr bindings e) (fun id ->
      Option.map (List.map (fun guard ->
        let facts = List.filter (live_guard_fact st id) (guard_facts guard) in
        match guard with
        | GBool (pol, _) -> GBool (pol, facts)
        | GPositive (value, _) -> GPositive (value, facts)
        | GCase (tag, binder, _) -> GCase (tag, binder, facts)))
        (Hashtbl.find_opt bound_gs id)) in
  (* GitHub issue #978: the versioned locals a statement or expression may
     assign (or rebind with a `let`), syntactically. *)
  let var_id (v : Ast.expr) x = match Local_bindings.id_for_expr bindings v with
    | Some id when versionable x id -> Some id
    | _ -> None in
  let rec assigned_e acc (e : Ast.expr) = match e.desc with
    | Ast.Assign (({ desc = Ast.Var x; _ } as v), r) ->
        let acc = match var_id v x with Some id -> id :: acc | None -> acc in
        assigned_e acc r
    | Ast.Assign (l, r) | Ast.BinOp (_, l, r) | Ast.Index (l, r) ->
        assigned_e (assigned_e acc l) r
    | Ast.AddrOf x | Ast.Bnot x | Ast.Deref x | Ast.Cast (_, x)
    | Ast.FieldGet (x, _) | Ast.Unsafe x | Ast.VariantCtor (_, _, x) -> assigned_e acc x
    | Ast.SliceOf (a, b, c) -> assigned_e (assigned_e (assigned_e acc a) b) c
    | Ast.Call (_, xs) | Ast.StructLit xs | Ast.TupleLit xs -> List.fold_left assigned_e acc xs
    | _ -> acc
  and assigned_s acc (s : Ast.stmt) =
    let acc = match s.desc, Local_bindings.ids_for_stmt bindings s with
      | (Ast.Let (true, n, _, _, _)), id :: _ when versionable n id -> id :: acc
      | _ -> acc in
    match s.desc with
    | Ast.Let (_, _, _, Some e, _) | Ast.LetTuple (_, e) | Ast.Expr e
    | Ast.Return (Some e) | Ast.Yield e -> assigned_e acc e
    | Ast.Block b | Ast.UnsafeBlock b -> List.fold_left assigned_s acc b
    | Ast.If (c, a, b) ->
        List.fold_left assigned_s (List.fold_left assigned_s (assigned_e acc c) a) b
    | Ast.While (c, b) -> List.fold_left assigned_s (assigned_e acc c) b
    | Ast.For (_, _, lo, hi, b) ->
        List.fold_left assigned_s (assigned_e (assigned_e acc lo) hi) b
    | Ast.ForEach (_, e, b) -> List.fold_left assigned_s (assigned_e acc e) b
    | Ast.Match (d, arms) | Ast.LetMatch (_, _, _, d, arms) ->
        List.fold_left (fun acc a -> match a with
          | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmMiss b
          | Ast.ArmIntLit (_, b) | Ast.ArmByteSliceLit (_, b) ->
              List.fold_left assigned_s acc b) (assigned_e acc d) arms
    | _ -> acc in
  (* A fresh version for each of [ids]: nothing is known of the new values. *)
  let bump st ids =
    let vers = List.fold_left (fun m id -> Types.IntMap.add id (fresh_ver ()) m)
        st.vers ids in
    cur_vers := vers; { st with vers } in
  (* Assign versioned local [id] the value of [rhs]: a call's result is
     named by the new version, so the callee's ensures over `result` is
     about it; a fact side (a constant, another atom) is recorded as an
     equality. Any other value gives no fact. *)
  let assign_versioned (expr : state -> Ast.expr -> state)
      (call : state -> Ast.expr -> result:Init_pred.lin option -> state * guarded list)
      st id (rhs : Ast.expr) =
    cur_vers := st.vers;
    let k = fresh_ver () in
    let name = ver_name id k in
    let finish st eq =
      let vers = Types.IntMap.add id k st.vers in
      cur_vers := vers;
      let st = add_declared_bounds { st with vers } id (Init_pred.atom name) in
      match eq with
      | Some t ->
          let t = Init_pred.normalize st.eqs t in
          { st with eqs = st.eqs @ [(name, t)] }
      | None -> st in
    match rhs.desc with
    | Ast.Call (f, _) when f <> "min" && f <> "zero_fill" && f <> "assume_init" ->
        let (st, _) = call st rhs ~result:(Some (Init_pred.atom name)) in
        finish st None
    | _ ->
        let st = expr st rhs in
        cur_vers := st.vers;
        finish st (side st rhs) in
  (* ---- expressions ------------------------------------------------------ *)
  (* GitHub issues #798, #1007: an index into an immutable slice binding,
     with [j] a machine-value term (lin: no step wraps), is decided here and
     only here: proven when the path facts entail `j < b.len`. The runtime
     order graph (type_inf, lib/runtime_bounds.ml) no longer decides this
     shape; it keeps the shapes this checker does not read. Only the real
     check decides; a loop's trial runs (in_trial) never do, since their
     head state is a candidate. A site visited more than once is proven
     only when every visit entails it. Each proof writes an index
     obligation z3 re-checks. *)
  (* GitHub issue #1011: a site's decision is None (proven) or the reason
     it is not, worded like --internal-trace-init-flow (#976): the claim that failed
     and the path facts at the first visit that failed. *)
  let index_decisions : (Ast.loc, string option) Hashtbl.t = Hashtbl.create 8 in
  let slice_index (st : state) (b : Ast.expr) (j : Ast.expr) =
    if not !in_trial then
      match b.desc, Local_bindings.id_for_expr bindings b with
      | Ast.Var x, Some id
        when immutable_var x id
             && (match Option.map strip (id_type id) with
                 | Some (Ast.TypeSlice _) -> true | _ -> false) ->
          (match checked (fun () -> lin st j) with
           | Some t ->
               let len = match view_of st b with
                 | Some { vp = { root; _ }; len = Some n; _ }
                   when String.starts_with ~prefix:"owner-param:" root -> n
                 | _ -> len_atom id in
               let f = Init_pred.normalize_facts st.eqs st.facts in
               let goal = Init_pred.normalize st.eqs
                   (Init_pred.sub (Init_pred.sub len t) (Init_pred.const 1)) in
               let ok = !Range_obligation.fault_index || Init_pred.entails f goal in
               (* Import declared bounds only when ordinary path facts do not
                  suffice. Keep the common whole-kernel path allocation-free. *)
               let before_declared = st in
               let st = if ok || not (List.exists (function
                   | _, Ast.TypeRefined _ -> true | _ -> false) param_types) then st else
                 let st = List.fold_left (fun st (name, ty) -> match ty with
                   | Ast.TypeRefined _ -> (match List.assoc_opt name param_ids with
                       | Some id when immutable_var name id && not (Hashtbl.mem addr_taken id) ->
                           add_declared_bounds st id (v_atom id)
                       | _ -> st)
                   | _ -> st) st param_types in
                 match Option.map strip (id_type id) with
                 | Some (Ast.TypeSlice (_, minimum, _)) when minimum > 0 ->
                     add_fact st (Init_pred.sub len (Init_pred.const minimum))
                 | _ -> st in
               let ok = ok || (st != before_declared &&
                 Init_pred.entails (Init_pred.normalize_facts st.eqs st.facts) goal) in
               let loc = j.Ast.loc in
               let claim = Printf.sprintf "%s < %s.len" (show t) x in
               (match Hashtbl.find_opt index_decisions loc with
                | Some (Some _) -> ()
                | _ ->
                    Hashtbl.replace index_decisions loc
                      (if ok then None
                       else Some (Printf.sprintf
                                    "init-flow cannot show %s%s" claim
                                    (path_facts st))));
               if ok then
                 Range_obligation.record_text loc
                   (Init_pred.index_obligation
                      ~claim
                      ~facts:st.facts st.eqs ~index:t ~len)
           | None -> ())
      | _ -> ()
  in
  (* Fixed-array arithmetic is initially enabled at explicit where boundaries.
     Recover only declared inline array places, never a raw-pointer extent. *)
  let array_decisions = if fdef.Ast.where_clauses = [] then None else Some (Hashtbl.create 4) in
  let rec place_ty (e : Ast.expr) = match e.desc with
    | Ast.Var _ -> Option.bind (Local_bindings.id_for_expr bindings e) id_type
    | Ast.FieldGet (b, field) ->
        let rec fields ty = match strip ty with
          | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeRef t | Ast.TypeRefMut t -> fields t
          | Ast.TypeNamed n | Ast.TypeIndexed (n, _) -> struct_fields n
          | _ -> None in
        Option.bind (Option.bind (place_ty b) fields) (List.assoc_opt field)
    | _ -> None in
  let array_index st b j =
    if fdef.Ast.where_clauses <> [] && not !in_trial then begin
      cur_vers := st.vers;
      let decisions = Option.get array_decisions in
      match Option.map strip (place_ty b) with
      | Some (Ast.TypeArray (_, n)) ->
          let term = checked (fun () -> lin st j) in
          let len = Init_pred.const n in
          let ok = match term with
            | Some t -> !Range_obligation.fault_index || (nonneg st t && Init_pred.entails
                (Init_pred.normalize_facts st.eqs st.facts)
                (Init_pred.normalize st.eqs (Init_pred.sub (Init_pred.sub len t) (Init_pred.const 1))))
            | None -> false in
          let reason = if ok then None else Some (Printf.sprintf
            "arithmetic index needs 0 <= %s < %d%s; check the input where contract and capacity constants; \
             if an intended compile-time capacity relation is missing, express it with static_assert \
             (a false assertion or an assertion about an unproved runtime value cannot supply the proof)"
            (match term with Some t -> show t ^ " (= " ^ show (Init_pred.normalize st.eqs t) ^ ")"
             | None -> "index (machine arithmetic not proved non-wrapping)")
            n (path_facts st)) in
          (match Hashtbl.find_opt decisions j.Ast.loc with
           | Some (Some _) -> () | _ -> Hashtbl.replace decisions j.loc reason);
          (match term with Some t when ok ->
            Range_obligation.record_text j.loc (Init_pred.index_obligation
              ~claim:(Printf.sprintf "%s < %d" (show t) n)
              ~facts:st.facts st.eqs ~index:t ~len)
           | _ -> ())
      | _ -> () end in
  let rec expr st (e : Ast.expr) : state =
    let result = expr_inner st e in
    if not linked_contract && Init_link.Values.is_empty result.extras.links then result else
    match e.desc with
    | Ast.Assign ({desc = Ast.Index (array, index); _}, rhs) ->
        (match view_of result array with
         | Some v when Init_pred.equal v.off (Init_pred.const 0) ->
             let result = set_links result
               ((Lazy.force link_ops).invalidate_aliases result.extras.links v.vp.root) in
             let written = (Lazy.force link_ops).assign_value result "$link-store" rhs in
             let storage = link_storage v.vp in
             let links = match (Lazy.force link_ops).value_key index with
               | Some index -> Init_link.store written.extras.links
                   ~full:(not (Leaves.mem storage result.u)) storage
                   ~index ~successor:"$link-store"
               | None -> Init_link.invalidate written.extras.links storage in
             set_links result (Init_link.forget_value links "$link-store")
         | Some v -> set_links result (Init_link.invalidate_path
             ((Lazy.force link_ops).invalidate_aliases result.extras.links v.vp.root)
             (link_storage v.vp))
         | None -> (match global_view_origin array with
             | Some name ->
                 let root = "G" ^ name in
                 set_links result (Init_link.invalidate_path
                   ((Lazy.force link_ops).invalidate_aliases result.extras.links root) (root, []))
             | None -> set_links result Init_link.empty))
    | Ast.Assign (lhs, rhs) ->
        (match place lhs, (Lazy.force link_ops).value_key lhs with
         | Some p, Some target when not p.inside ->
             let written = (Lazy.force link_ops).assign_value result "$link-write" rhs in
             let links = (Lazy.force link_ops).invalidate_aliases written.extras.links p.root in
             let links = Init_link.invalidate_path links (p.root, p.path) in
             let links = Init_link.copy links ~target ~source:"$link-write" in
             set_links result (Init_link.forget_value links "$link-write")
         | None, Some target -> (Lazy.force link_ops).assign_value result target rhs
         | _ -> (match pointer_store_origin e with
             | Some name ->
                 let root = "G" ^ name in
                 set_links result (Init_link.invalidate_path
                   ((Lazy.force link_ops).invalidate_aliases result.extras.links root) (root, []))
             | None -> set_links result Init_link.empty))
    | _ -> result
  and expr_inner st (e : Ast.expr) : state =
    let st = match e.desc with
      | Ast.Assign (lhs, rhs) ->
          Option.iter (fun id -> note_slot_alias st id rhs)
            (Local_bindings.id_for_expr bindings lhs);
          invalidate_place st lhs
      | _ -> st in
    cur_vers := st.vers;
    (match e.desc with
     | Ast.Index (b, j) | Ast.Assign ({ desc = Ast.Index (b, j); _ }, _) ->
         slice_index st b j; array_index st b j
     | _ -> ());
    if is_len_of st e then st else
    match e.desc with
    | Ast.Assign (({ desc = Ast.Var x; _ } as v), rhs) when var_id v x <> None ->
        assign_versioned expr call st (Option.get (var_id v x)) rhs
    | Ast.FieldGet (({ desc = Ast.Index (b, _); _ } as element), _)
      when view_of st b <> None -> expr st element
    | Ast.Index (b, j) when view_of st b <> None ->
        let v = Option.get (view_of st b) in
        let st = expr st j in
        let st = place_subexprs_view st b in
        if (linked_contract || not (Init_link.Values.is_empty st.extras.links)) &&
           Leaves.mem (link_storage v.vp) st.u && (Lazy.force link_ops).view_ready st v j then st else
        (match lin st j with
         | Some j ->
             let k = Init_pred.add v.off j in
             need st v (k, Init_pred.add k (Init_pred.const 1)) e.loc "read"
         | None -> need_view st v e.loc "read")
    | _ when view_of st e <> None && not (is_plain_place e) ->
        let v = Option.get (view_of st e) in
        let st = view_subexprs st e in
        need_view st v e.loc "viewed as memory"
    | _ ->
    match place e with
    | Some p ->
        let st = place_subexprs st e in
        check_read st { p with inside = false } ~bytes:false e.loc
    | None ->
    match e.desc with
    | Ast.Cast (target, ({ desc = Ast.Index _; _ } as element))
      when unsigned_ty target || strip target = Ast.TypeI32 || strip target = Ast.TypeIsize ->
        (* Numeric conversion reads the indexed scalar, not every byte of
           its backing array. Address/byte reinterpretations stay below. *)
        expr st element
    | Ast.Cast ((Ast.TypePtr _ | Ast.TypeAlignedPtr _),
                { desc = Ast.AddrOf inner; _ })
      when !unsafe_depth > 0 && (match place inner with
        | Some p when not p.inside ->
            (match Hashtbl.find_opt roots p.root with
             | Some r -> r.out_param | None -> false)
        | _ -> false) ->
        (* An explicit raw mint may name uninitialized output storage. It
           reads no pointee and establishes no init fact. A raw writer must
           discharge its output via a checked store or an audited assume_init.
           Do not extend this to traversal through an uninitialized pointer
           field (inside), or to a checked reference/slice view. *)
        incr unsafe_uses;
        place_subexprs st inner
    | Ast.Cast ((Ast.TypePtr _ | Ast.TypeAlignedPtr _), inner)
      when !unsafe_depth > 0 && (match view_of st inner with
        | Some v when not v.vp.inside ->
            (match Hashtbl.find_opt roots v.vp.root with
             | Some r -> r.out_param | None -> false)
        | _ -> false) ->
        (* A borrowed output slice already carries a valid address/length.
           Exporting its address to an audited external writer reads no
           element and establishes no initialization fact. *)
        incr unsafe_uses;
        place_subexprs_view st inner
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
    | Ast.Call ("io_read_span", [a]) -> place_subexprs_view st a
    | Ast.Call ("zero_fill", [a]) ->
        let st = if Init_link.Values.is_empty st.extras.links then st else set_links st Init_link.empty in
        fill_arg st a
    | Ast.Call ("assume_init", [a]) -> fill_arg st a
    | Ast.Call _ -> fst (call st e ~result:None)
    | Ast.BinOp ((Ast.And | Ast.Or) as op, l, r) ->
        let st = expr st l in
        (* The right operand runs only when the left one did not decide. *)
        ignore (expr (assume st l (op = Ast.And)) r);
        bump st (assigned_e [] r)
    | Ast.BinOp (_, l, r) -> expr (expr st l) r
    | Ast.Index (l, r) -> expr (expr st l) r
    | Ast.Assign ({ desc = Ast.Index (b, j); _ }, rhs) when view_of st b <> None ->
        (* An element store writes element j of the view. *)
        let v = Option.get (view_of st b) in
        let st = expr st rhs in
        (* Aggregate stores may copy undefined padding from the source.
           A prior clear of the destination cannot justify those bytes. *)
        let st = forget_array_padding st v.vp in
        let st = expr st j in
        let st = place_subexprs_view st b in
        (match lin st j with
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
        let before = !unsafe_uses in
        let st = expr st x in
        if not !in_trial && !unsafe_uses <> before then note_unsafe e.loc;
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
    | Ast.Index (b, i) -> array_index st b i; place_subexprs (expr st i) b
    | _ -> st
  and place_subexprs_view st (e : Ast.expr) = match e.desc with
    | Ast.SliceOf (b, lo, hi) -> place_subexprs_view (expr (expr st lo) hi) b
    | Ast.Cast (_, b) -> place_subexprs_view st b
    | _ -> place_subexprs st e
  and view_subexprs st e = place_subexprs_view st e
  (* An out argument cut from a view with bounds that are not linear: it
     writes an unknown range, so it neither reads nor initializes. *)
  and has_view_base f (a : Ast.expr) = match a.desc with
    | Ast.SliceOf (b, _, _) | Ast.Cast (_, b) -> view_of f b <> None || has_view_base f b
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
        (match view_of st a with
         | Some ({ len = Some n; _ } as v) ->
             add_bytes_iv (place_subexprs_view st a) v.vp (v.off, Init_pred.add v.off n)
         | _ -> place_subexprs_any st inner)
    | `Other ->
        (match view_of st a with
         | Some ({ len = Some n; _ } as v) ->
             add_bytes_iv (place_subexprs_view st a) v.vp (v.off, Init_pred.add v.off n)
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
    let st = match e.desc with
      | Ast.Call (("slice_copy" | "publish_copy"), _) when not (Init_link.Values.is_empty st.extras.links) ->
          set_links st Init_link.empty
      | _ -> st in
    match e.desc with
    | Ast.Call ("io_read_span", [a]) -> (place_subexprs_view st a, [])
    | Ast.Call ("publish_copy", [src; { desc = Ast.AddrOf dst; _ }]) ->
        let st = expr st src in
        let st = place_subexprs_any st dst in
        let fact = match dst.desc with
          | Ast.Index (base, index) -> (match view_of st base, lin st index with
              | Some v, Some index ->
                  let at = Init_pred.add v.off index in
                  Some (v, (at, Init_pred.add at (Init_pred.const 1)))
              | _ -> None)
          | _ -> (match place dst with
              | Some p when not p.inside -> Some ({ vp = p; off = Init_pred.const 0; len = None },
                  (Init_pred.const 0, Init_pred.const (-2)))
              | _ -> None) in
        (st, match result, fact with
          | Some result, Some fact -> [GPositive (result, [fact])]
          | _ -> [])
    | Ast.Call ("slice_copy", [d; s]) when view_of st d <> None ->
        (* Builtin contract: init(dst[0..<result]). *)
        let v = Option.get (view_of st d) in
        let st = expr st s in
        let st = place_subexprs_view st d in
        let st = forget_array_padding st v.vp in
        let source_len = match s.desc with
          | Ast.SliceOf (_, lo, hi) -> (match lin st lo, lin st hi with
              | Some lo, Some hi -> checked (fun () -> Some (Init_pred.sub hi lo))
              | _ -> None)
          | _ -> lin st { s with desc = Ast.FieldGet (s, "len") } in
        let known = match v.len, source_len with
          | Some d, Some s ->
              let le a b = Init_pred.entails (Init_pred.normalize_facts st.eqs st.facts)
                  (Init_pred.normalize st.eqs (Init_pred.sub b a)) in
              if le d s then Some d else if le s d then Some s else None
          | _ -> None in
        let st = match known with
          | Some n -> add_iv st v.vp (v.off, Init_pred.add v.off n)
          | None -> st in
        (match result with
         | Some r -> (add_iv st v.vp (v.off, Init_pred.add v.off r), [])
         | None -> (st, []))
    | Ast.Call (name, args) ->
        let params = match callee name e with
          | Some (ps, loc) when List.length ps = List.length args -> Some (ps, loc)
          | _ -> None in
        let cs = match params with
          | Some (_, loc) -> Init_state.contracts_of loc | None -> [] in
        let named = named_params cs in
        let (st, fills) = List.fold_left (fun (st, fills) (i, a) ->
          let out = match params with
            | Some (ps, loc) ->
                let (pname, _) = List.nth ps i in
                (match Init_state.param_qual loc pname with
                 | Some Init_state.Uninit when List.mem pname named -> `Contract
                 | Some Init_state.Uninit -> `Out
                 | _ -> `No)
            | None -> `No in
          match out with
          | `Contract ->
              (match view_of st a with
               | Some _ -> (place_subexprs_view st a, fills)
               | None ->
                   (match fill_target a with
                    | `Whole (_, inner) -> (place_subexprs st inner, fills)
                    | `Partial inner -> (place_subexprs_any st inner, fills)
                    | `Other when has_view_base st a -> (place_subexprs_view st a, fills)
                    | `Other -> (expr st a, fills)))
          | `Out ->
              (match fill_target a with
               | `Whole (p, inner) -> (place_subexprs st inner, (`P p) :: fills)
               | `Partial inner ->
                   (match view_of st a with
                    | Some ({ len = Some n; _ } as v) when out = `Out ->
                        (place_subexprs_view st a,
                         (`V (v, (v.off, Init_pred.add v.off n))) :: fills)
                    | _ -> (place_subexprs_any st inner, fills))
               | `Other ->
                   (match view_of st a with
                    | Some ({ len = Some n; _ } as v) when out = `Out ->
                        (place_subexprs_view st a,
                         (`V (v, (v.off, Init_pred.add v.off n))) :: fills)
                    | _ when has_view_base st a -> (place_subexprs_view st a, fills)
                    | _ -> (expr st a, fills)))
          | `No -> (expr st a, fills))
          (st, []) (List.mapi (fun i a -> (i, a)) args) in
        if not !in_trial then
          Option.iter (fun binding ->
            match Option.bind binding (fun id -> Types.IntMap.find_opt id st.extras.owners) with
            | Some root when not (Leaves.mem (root, []) st.u) -> ()
            | Some _ -> error e.loc "publication requires initialization of all bytes of the live owner"
            | None -> error e.loc "publication cannot establish the current owner")
            (inferred_owner_requirement e);
        (* Requires: checked against the state before the out fills. *)
        let pnames = match params with Some (ps, _) -> List.map fst ps | None -> [] in
        let arg_of x = match List.find_index (( = ) x) pnames with
          | Some i -> Some (List.nth args i) | None -> None in
        let rec index_expr (idx : Ast.expr) = match idx.desc with
          | Ast.Var x -> (match arg_of x with Some a -> a | None -> idx)
          | Ast.FieldGet (b, f) -> { idx with desc = Ast.FieldGet (index_expr b, f) }
          | _ -> idx in
        let arg_view x = match arg_of x with
          | Some a ->
              (match view_of st a with
               | Some v -> Some (`View v)
               | None ->
                   (match fill_target a with
                    | `Whole (p, _) -> Some (`Whole p)
                    | _ -> Some `Untracked))
          | None -> None in
        let env ~binder x kind =
          if x = "result" then (match kind, result with
            | `Field field, Some term when term.Init_pred.c = 0 ->
                (match Init_pred.SMap.bindings term.Init_pred.m with
                 | [(name, 1)] when String.starts_with ~prefix:"v" name ->
                     (match int_of_string_opt (String.sub name 1 (String.length name - 1)) with
                      | Some id -> field_term st id field | None -> None)
                 | _ -> None)
            | `Field _, _ -> None
            | _ -> result)
          else match binder with
            | Some (b, value) when b = x -> value kind
            | _ ->
                match arg_of x, kind with
                | Some a, `Val _ -> lin st a
                | Some a, `Field field -> lin st { a with desc = Ast.FieldGet (a, field) }
                | Some a, `Len _ ->
                    (match view_of st a with
                     | Some v -> v.len
                     | None -> lin st { a with desc = Ast.FieldGet (a, "len") })
                | None, _ -> None in
        let st = List.fold_left (fun st (c : Init_state.clause) ->
          if not c.requires then st else
          match c.body with
          | Init_state.CPlain p ->
              let st = match p with Init_state.PLinked _ ->
                (Lazy.force link_ops).check_pred st ~arg_view p e.loc | _ -> st in
              List.fold_left (fun st r -> match r with
                | Some f -> need_fact st f e.loc
                              (Printf.sprintf "required initialized by '%s'" name)
                | None ->
                    error e.loc (Printf.sprintf
                      "cannot show the requires clause of '%s' at this call: \
                       its place or bounds are not expressible here" name);
                    st) st (resolve_pred ~strengthen:true
                      ~owner_view:(fun name -> Option.bind (arg_of name) (fun arg ->
                        Option.bind (Local_bindings.id_for_expr bindings arg) (projected_view st)))
                      ~arg_view ~index_expr ~env:(env ~binder:None) p)
          | _ -> st) st cs in
        (* Mutable aggregate calls may replace fields with a value whose
           padding is undefined. Pre-call byte initialization is not a
           frame guarantee. Explicit whole-byte outputs below restore it. *)
        let rec mutable_storage ty = match strip ty with
          | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t -> mutable_storage t
          | Ast.TypeRefMut _ | Ast.TypeSlice (_, _, Ast.SliceWritable) -> true
          | _ -> false in
        let st = match params with
          | None -> st
          | Some (ps, _) -> List.fold_left2 (fun st (_, ty) arg ->
              if not (Option.fold ~none:false ~some:mutable_storage ty) then st
              else match view_of st arg with
                | Some v -> forget_padding st v.vp
                | None -> (match fill_target arg with
                    | `Whole (p, _) -> forget_padding st p
                    | _ -> st)) st ps args in
        let st = List.fold_left (fun st f -> match f with
          | `P p -> fill st p
          | `V (v, iv) -> add_bytes_iv st v.vp iv) st fills in
        (* Distinct reference bindings are not proof of disjoint memory.
           A scalar-only call can also mutate globals that alias a parameter.
           Preserve facts only from a checked body footprint or postcondition. *)
        let st = if Init_link.Values.is_empty st.extras.links then st else
          match write_footprint e with
          | Init_writes.Unknown -> set_links st Init_link.empty
          | Init_writes.Writes paths ->
              let links = Init_writes.Paths.fold (fun (root, suffix) links ->
                match root with
                | Init_writes.Global name ->
                    let key = "G" ^ name in
                    Init_link.invalidate_path
                      ((Lazy.force link_ops).invalidate_aliases links key) (key, suffix)
                | Init_writes.Parameter i -> match List.nth_opt args i with
                | None -> Init_link.empty
                | Some arg ->
                    let destination = match fill_target arg with
                      | `Whole (p, _) when not p.inside -> Some (p, suffix)
                      | _ -> (match view_of st arg with
                          | Some v -> Some (v.vp, [])
                          | None -> None) in
                    match destination with
                    | Some (p, suffix) -> Init_link.invalidate_path
                        ((Lazy.force link_ops).invalidate_aliases links p.root)
                        (p.root, p.path @ suffix)
                    | None -> Init_link.empty) paths st.extras.links in
              set_links st links in
        (* Ensures. *)
        let facts ~binder p =
          List.filter_map (fun x -> x)
            (resolve_pred ~arg_view ~index_expr ~env:(env ~binder) p) in
        let bind_atom b = "arm:" ^ b in
        let st, gs = List.fold_left (fun (st, gs) (c : Init_state.clause) ->
          if c.requires then (st, gs) else
          match c.body with
          | Init_state.CPlain p ->
              let st = List.fold_left apply_fact st (facts ~binder:None p) in
              let st = match p with Init_state.PLinked _ ->
                (Lazy.force link_ops).apply_pred st ~arg_view p e.loc | _ -> st in
              (st, gs)
          | Init_state.CIf (cond, p) ->
              let pol = match cond.desc with
                | Ast.BinOp (Ast.Eq, _, { desc = Ast.BoolLit b; _ }) -> b
                | _ -> true in
              (st, GBool (pol, facts ~binder:None p) :: gs)
          | Init_state.CMatch arms ->
              (st, List.map (fun ((pat : Init_state.arm_pat), p) ->
                 let binder = Option.map (fun b ->
                   (b, (function
                     | `Val _ -> Some (Init_pred.atom (bind_atom b))
                     | `Field field -> Some (Init_pred.atom (bind_atom b ^ "." ^ field))
                     | `Len _ -> None))) pat.bind in
                 GCase (pat.case, Option.map bind_atom pat.bind,
                        facts ~binder p)) arms @ gs))
          (st, []) cs in
        let st =
          if Types.IntMap.is_empty st.extras.owners then st else
          match write_footprint e with
          | Init_writes.Writes _ -> st
          | Init_writes.Unknown ->
              let rec owner_of_arg arg =
                match Option.bind (Local_bindings.id_for_expr bindings arg)
                        (fun id -> Types.IntMap.find_opt id st.extras.owners) with
                | Some _ as root -> root
                | None ->
                    (match view_of st arg with
                     | Some view when Types.IntMap.exists
                         (fun _ owner -> owner = view.vp.root) st.extras.owners ->
                         Some view.vp.root
                     | _ ->
                         match arg.Ast.desc with
                         | Ast.AddrOf inner | Ast.Deref inner | Ast.Cast (_, inner)
                         | Ast.Unsafe inner | Ast.Index (inner, _)
                         | Ast.SliceOf (inner, _, _) | Ast.FieldGet (inner, _) -> owner_of_arg inner
                         | _ -> None) in
              let affected = List.fold_left (fun roots arg ->
                let roots = StringSet.union roots (slot_alias_roots st arg) in
                Option.fold ~none:roots ~some:(fun root -> StringSet.add root roots)
                  (owner_of_arg arg)) StringSet.empty args in
              StringSet.fold (fun root st -> invalidate_owner st root) affected st in
        let st = List.fold_left (fun st (i, arg) ->
          match arg.Ast.desc with
          | Ast.AddrOf target -> invalidate_place st target
          | Ast.Var x ->
              (match binding_id arg x with
               | Some id ->
                   let is_owner = match Types.IntMap.find_opt id finfo.Types.binding_types with
                     | Some ty ->
                         let rec owner = function
                           | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t -> owner t
                           | Ast.TypeIndexed (n, _) | Ast.TypeNamed n -> linear_owner n
                           | _ -> false in owner (strip ty)
                     | None -> false in
                   let shared = match params with
                     | Some (ps, _) -> (match snd (List.nth ps i) with
                         | Some (Ast.TypeBorrow _) -> true | _ -> false)
                     | None -> false in
                   let st = if is_owner && not shared then invalidate_selector st id else st in
                   let consumed = match params with
                     | Some (ps, _) ->
                         (match snd (List.nth ps i) with
                          | Some (Ast.TypeBorrow _ | Ast.TypeBorrowMut _) -> false
                          | _ -> true)
                     | None -> true in
                   (match Types.IntMap.find_opt id st.extras.owners with
                    | Some root when consumed ->
                        with_owners (invalidate_owner st root)
                          (Types.IntMap.remove id st.extras.owners)
                    | _ -> st)
               | None -> st)
          | _ -> st) st (List.mapi (fun i a -> i, a) args) in
        List.fold_left (fun (st, gs) (id, outcome) ->
          match projected_view st id with
          | None -> (st, gs)
          | Some view ->
              let high = Option.value ~default:(Init_pred.const (-2)) view.len in
              let fact = (view, (Init_pred.const 0, high)) in
              match outcome with
              | "always" -> (apply_fact st fact, gs)
              | "true" | "false" -> (st, GBool (outcome = "true", [fact]) :: gs)
              | _ -> (st, GCase (Some outcome, None, [fact]) :: gs))
          (st, gs) (owner_call_facts e)
    | _ -> (expr st e, [])
  in
  ignore callee_ret;
  (* Facts under one outcome of a call. *)
  let apply_bool st gs b =
    List.fold_left (fun st g -> match g with
      | GBool (pol, fs) when pol = b ->
          List.fold_left apply_fact st fs
      | _ -> st) st gs in
  let apply_case st gs case binder_value =
    let exact = List.exists (function GCase (Some k, _, _) -> k = case | _ -> false) gs in
    List.fold_left (fun st g -> match g with
      | GCase (k, b, fs) when (if exact then k = Some case else k = None) ->
          List.fold_left (fun st (v, iv) ->
            let placeholders = match b with
              | None -> []
              | Some b -> List.filter (fun a -> a = b || String.starts_with ~prefix:(b ^ ".") a)
                  (List.sort_uniq compare (Init_pred.atoms (fst iv) @ Init_pred.atoms (snd iv))) in
            let iv, unresolved = List.fold_left (fun (iv, unresolved) a ->
              let kind = match b with
                | Some b when a <> b -> `Field (String.sub a (String.length b + 1)
                    (String.length a - String.length b - 1))
                | _ -> `Val None in
              match binder_value kind with
              | Some t -> (subst_atom a t iv, unresolved)
              | None -> (iv, true)) (iv, false) placeholders in
            if unresolved then st else apply_fact st (v, iv)) st fs
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
  let own_env ?(result_field = fun _ -> None) ~result ~binder x kind =
    if x = "result" then (match kind with `Field field -> result_field field | _ -> result)
    else match binder with
      | Some (b, value) when b = x -> value kind
      | _ ->
          match List.assoc_opt x param_ids, kind with
          | Some id, `Val _ when not (is_written x id) -> Some (v_atom id)
          | Some id, `Len _ -> Some (len_atom id)
          | _ -> None in
  let check_ensures ?ret st (eo : Ast.expr option) (gs : guarded list) loc =
    let result = match ret, eo with
      | Some t, _ -> Some t
      | None, Some e -> lin st e
      | None, None -> None in
    let need_pred st ~binder p =
      let st = match p with Init_state.PLinked _ ->
        (Lazy.force link_ops).check_pred st ~arg_view:own_arg_view p loc | _ -> st in
      List.fold_left (fun st r -> match r with
        | Some f -> need_fact st f loc "the ensures clause needs it initialized"
        | None ->
            error loc "cannot show this ensures clause here: its bounds are \
                       not expressible at this return";
            st) st (resolve_pred ~index_expr:Fun.id ~arg_view:own_arg_view
                      ~env:(own_env ~result ~binder ~result_field:(fun field ->
                        Option.bind eo (fun e -> lin st { e with desc = Ast.FieldGet (e, field) }))) p) in
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
               let st = match lin st x, lin st y with
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
                    let binder = Option.map (fun b -> (b, function
                      | `Val _ -> lin st payload
                      | `Field field -> lin st { payload with desc = Ast.FieldGet (payload, field) }
                      | `Len _ -> None)) pat.bind in
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
                   let value kind = Option.bind pat.bind (fun b -> match kind with
                     | `Val _ -> Some (Init_pred.atom ("ret:" ^ b))
                     | `Field field -> Some (Init_pred.atom ("ret:" ^ b ^ "." ^ field))
                     | `Len _ -> None) in
                   let st = apply_case st gs k value in
                   let binder = Option.map (fun b -> (b, value)) pat.bind in
                   ignore (need_pred st ~binder p)) mine) arms
           | _ ->
               List.iter (fun ((pat : Init_state.arm_pat), p) ->
                 let binder = Option.map (fun b -> (b, fun _ -> None)) pat.bind in
                 ignore (need_pred st ~binder p)) arms)) contracts
  in
  let check_outs st loc =
    List.iter (fun key ->
      record_leaf_coverage st { root = key; path = []; inside = false }
        ~bytes:true loc "output return";
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
  (* GitHub issue #978: restate a state's facts about atom [a] for atom
     [b]. *)
  let rename_state st a b =
    let t = Init_pred.atom b in
    let r = Init_pred.subst a t in
    { st with
      iv = List.map (fun (l, (lo, hi)) -> (l, (r lo, r hi))) st.iv;
      eqs = List.map (fun (x, e) -> ((if x = a then b else x), r e)) st.eqs;
      facts = { Init_pred.ge = List.map r st.facts.Init_pred.ge;
                mins = List.map (fun (x, l, h) ->
                  ((if x = a then b else x), r l, r h)) st.facts.Init_pred.mins } } in
  (* A merge keeps an interval only if every live arm has it, or has the
     leaf fully initialized. *)
  let merge results =
    match List.filter (fun (_, dead) -> not dead) results with
    | [] -> ({ extras = empty_extras; u = Leaves.empty; iv = []; eqs = []; facts = Init_pred.no_facts;
                vers = Types.IntMap.empty }, true)
    | live ->
        (* GitHub issue #978: a local whose version differs between arms
           gets a fresh version, and each arm's facts about its own version
           are restated for the fresh one (a phi). *)
        let states = List.map fst live in
        let touched = List.fold_left (fun acc st -> StringSet.union acc st.extras.touched)
          StringSet.empty states in
        let states = List.map (fun st -> StringSet.fold
          (fun key st -> touch_root st key) touched st) states in
        let ids = List.sort_uniq compare (List.concat_map (fun s ->
          List.map fst (Types.IntMap.bindings s.vers)) states) in
        let (vers, states) = List.fold_left (fun (vers, states) id ->
          let vs = List.map (fun s -> Types.IntMap.find_opt id s.vers) states in
          match vs with
          | Some k :: rest when List.for_all (( = ) (Some k)) rest ->
              (Types.IntMap.add id k vers, states)
          | _ ->
              let k = fresh_ver () in
              (Types.IntMap.add id k vers,
               List.map (fun s -> match Types.IntMap.find_opt id s.vers with
                 | Some old -> rename_state s (ver_name id old) (ver_name id k)
                 | None -> s) states))
          (Types.IntMap.empty, states) ids in
        let first = List.hd states and rest = List.map (fun s -> (s, false)) (List.tl states) in
        let all = states in
        let u = List.fold_left (fun acc s -> Leaves.union acc s.u) first.u
            (List.map fst rest) in
        let existing = List.concat_map (fun s ->
          List.filter (fun (leaf, _) -> Leaves.mem leaf u) s.iv) all in
        let leaves = List.sort_uniq compare (List.map fst existing) in
        let counters = if leaves = [] then [] else List.filter_map (fun (id, k) ->
          if not (unsigned_id id) then None else
          let bound = Init_pred.atom (ver_name id k) in
          Some (bound, List.map (fun s -> Init_pred.normalize s.eqs bound) all))
          (Types.IntMap.bindings vers) in
        let prefixes = List.concat_map (fun leaf ->
          (* Guess aliases of observed endpoints, not arbitrary expressions
             that merely share one atom. Normalize once per predecessor.
             These are only search candidates;
             every retained interval still needs all-predecessor coverage. *)
          let endpoints = List.concat_map (fun s ->
            List.concat_map (fun (lo, hi) ->
              [Init_pred.normalize s.eqs lo; Init_pred.normalize s.eqs hi])
              (ivs_of s leaf)) all in
          List.filter_map (fun (bound, normalized) ->
            let related = List.exists (fun normalized ->
              List.exists (fun endpoint ->
                not (Init_pred.equal normalized (Init_pred.const 0)) &&
                Init_pred.equal normalized endpoint) endpoints) normalized in
            if related then Some (leaf, (Init_pred.const 0, bound)) else None)
            counters) leaves in
        let cands = List.sort_uniq compare (existing @ prefixes) in
        let iv = List.filter (fun (l, i) ->
          Leaves.mem l u &&
          List.for_all (fun s ->
            if not (Leaves.mem l s.u) then true
            else if List.exists (fun (l', i') -> l' = l && Init_pred.interval_equal i i') s.iv then true
            else Init_pred.uncovered ~need_gap:false ~eqs:s.eqs ~facts:s.facts (ivs_of s l) i = None)
            all) cands in
        (* Only retained facts need certificates. A candidate that fails in
           another arm never contributes to the merged state. *)
        List.iter (fun (l, i) -> List.iter (fun s ->
          if Leaves.mem l s.u && not (List.exists (fun (l', i') ->
              l' = l && Init_pred.interval_equal i i') s.iv) then
            Range_obligation.record_text !cur_loc
              (Init_pred.obligation ~claim:"branch join initialization coverage"
                ~facts:s.facts s.eqs (ivs_of s l) i)) all) iv;
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
        let links = List.fold_left (fun acc st -> Init_link.join acc st.extras.links)
             (List.hd states).extras.links (List.tl states) in
        let owners = Types.IntMap.filter (fun id root ->
          in_all (fun st -> Types.IntMap.find_opt id st.extras.owners = Some root))
          first.extras.owners in
        let owner_guards = Types.IntMap.filter_map (fun id roots ->
          let roots = StringSet.filter (fun root ->
            in_all (fun st -> Option.fold ~none:false ~some:(StringSet.mem root)
              (Types.IntMap.find_opt id st.extras.owner_guards))) roots in
          if StringSet.is_empty roots then None else Some roots)
          first.extras.owner_guards in
        let extras =
          if links == first.extras.links && touched == first.extras.touched &&
             owners == first.extras.owners && owner_guards == first.extras.owner_guards
          then first.extras else {links; touched; owners; owner_guards} in
        ({ extras; u; iv; eqs; facts = { Init_pred.ge; mins }; vers }, false)
  in
  let trackable _ty = true in
  (* GitHub issue #888, generalized by #954: a counted loop that stores
     element i of a view on every iteration,

       for i in lo ..< hi { ...; P[i] = e; ... }

     where P is a stable variable/field-chain view and i is the loop's
     own counter. Intersect stores on normally completing branch paths;
     a function return cannot reach the post-loop consumer. An outer break
     or continue prevents this summary. Nested loops do not contribute
     stores. The body may use the preceding prefix [off + lo, off + i),
     never its current element merely because a later store will fill it.
     The completed loop establishes [off + lo, off + hi). *)
  let rec leaves_iteration depth ss = List.exists (fun (s : Ast.stmt) ->
    match s.desc with
    | Ast.Return _ -> false
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
  let filled_by_loop f (s : Ast.stmt) lo hi body =
    let counter = match Local_bindings.ids_for_stmt bindings s with
      | [_; binder] -> Some binder | _ -> None in
    let rec body_ids ss = List.concat_map (fun (s : Ast.stmt) ->
      Local_bindings.ids_for_stmt bindings s @
      (match s.desc with
       | Ast.Block b | Ast.UnsafeBlock b | Ast.While (_, b)
       | Ast.For (_, _, _, _, b) | Ast.ForEach (_, _, b) -> body_ids b
       | Ast.If (_, a, b) -> body_ids a @ body_ids b
       | Ast.Match (_, arms) | Ast.LetMatch (_, _, _, _, arms) ->
           List.concat_map (fun arm -> body_ids (arm_body arm)) arms
       | _ -> [])) ss in
    let declared_inside = body_ids body in
    let rec plain_chain (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> (match Local_bindings.id_for_expr bindings e with
          | Some id -> not (List.mem id declared_inside)
          | None -> true)
      | Ast.FieldGet (b, _) -> plain_chain b
      | _ -> false in
    let equal (p, i) (q, j) = p = q && Init_pred.interval_equal i j in
    let union a b = a @ List.filter (fun x -> not (List.exists (equal x) a)) b in
    let merge_paths paths =
      match List.filter_map Fun.id paths with
      | [] -> None
      | first :: rest -> Some (List.filter (fun x ->
          List.for_all (List.exists (equal x)) rest) first) in
    let rec normal_stores ss =
      List.fold_left (fun acc (st : Ast.stmt) -> match acc with
        | None -> None
        | Some before ->
            let after = match st.desc with
              | Ast.Return _ -> None
              | Ast.Block b | Ast.UnsafeBlock b -> normal_stores b
              | Ast.If (_, a, b) -> merge_paths [normal_stores a; normal_stores b]
              | Ast.Match (_, arms) | Ast.LetMatch (_, _, _, _, arms) ->
                  merge_paths (List.map (fun arm -> normal_stores (arm_body arm)) arms)
              | Ast.Expr { desc = Ast.Assign (
                  { desc = Ast.Index (base, ({ desc = Ast.Var _; _ } as iv)); _ }, _); _ }
                when plain_chain base && counter <> None
                     && Local_bindings.id_for_expr bindings iv = counter ->
                  (match view_of f base, lin f lo, lin f hi with
                   | Some v, Some lo, Some hi ->
                       Some [(v.vp, (Init_pred.add v.off lo, Init_pred.add v.off hi))]
                   | _ -> Some [])
              | _ -> Some [] in
            Option.map (union before) after) (Some []) ss in
    let rec skips depth ss = List.exists (fun (s : Ast.stmt) -> match s.desc with
      | Ast.Break | Ast.Continue -> depth = 0
      | Ast.Block b | Ast.UnsafeBlock b -> skips depth b
      | Ast.If (_, a, b) -> skips depth a || skips depth b
      | Ast.Match (_, arms) | Ast.LetMatch (_, _, _, _, arms) ->
          List.exists (fun arm -> skips depth (arm_body arm)) arms
      | Ast.While (_, b) | Ast.For (_, _, _, _, b) | Ast.ForEach (_, _, b) -> skips (depth + 1) b
      | _ -> false) ss in
    if skips 0 body then [] else Option.value ~default:[] (normal_stores body)
  in
  let bind_result (s : Ast.stmt) =
    match Local_bindings.ids_for_stmt bindings s with
    | id :: _ when immutable id || (match id_type id with
          | Some ty -> record_fields ty <> None && not (Hashtbl.mem changed_records id)
          | None -> false) -> Some (v_atom id)
    | _ -> None in
  let trace_state (s : Ast.stmt) st =
    let kind = match s.desc with
      | Ast.Let _ | Ast.LetTuple _ -> "let" | Ast.LetMatch _ -> "let-match"
      | Ast.Expr _ -> "expr" | Ast.Yield _ -> "yield" | Ast.Return _ -> "return"
      | Ast.Block _ -> "block" | Ast.UnsafeBlock _ -> "unsafe"
      | Ast.If _ -> "if" | Ast.While _ -> "while" | Ast.For _ -> "for"
      | Ast.ForEach _ -> "foreach" | Ast.Match _ -> "match"
      | Ast.Break -> "break" | Ast.Continue -> "continue"
      | Ast.StaticAssert _ -> "static_assert" in
    let pos = s.loc in
    let head = Printf.sprintf "init-trace %s %d:%d %s " fdef.Ast.name
        pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol + 1) kind in
    let keys = List.sort compare
        (Hashtbl.fold (fun k _ acc -> k :: acc) roots []) in
    List.iter (fun key ->
      let st = touch_root st key in
      let r = Hashtbl.find roots key in
      List.iter (fun (path, _) ->
        let l = (key, path) in
        let name = path_to_string r.display path
                   ^ (if is_pad path then ".#pad" else "") in
        let body =
          if not (Leaves.mem l st.u) then "init"
          else match ivs_of st l with
            | [] -> "uninit; known none" ^ path_facts st
            | ivs -> "uninit; known " ^ String.concat ", " (List.map (fun (lo, hi) ->
                Printf.sprintf "[%s, %s)" (show lo) (show hi)) (List.rev ivs))
                ^ path_facts st in
        !trace_out (head ^ name ^ ": " ^ body ^ "\n")) r.leaves) keys
  in
  let rec stmts st ss =
    List.fold_left (fun (st, dead) s ->
      if dead then (st, dead) else stmt st s) (st, false) ss
  and stmt st (s : Ast.stmt) =
    let st = apply_positive st in
    let st = match s.desc with
      | Ast.Let _ | Ast.LetTuple _ | Ast.LetMatch _ ->
          List.fold_left invalidate_selector st (Local_bindings.ids_for_stmt bindings s)
      | _ -> st in
    (match s.desc, Local_bindings.ids_for_stmt bindings s with
     | Ast.Let (_, _, _, Some rhs, _), [id] -> note_slot_alias st id rhs
     | _ -> ());
    let before = !unsafe_uses in
    let r = stmt_inner st s in
    let r = if not linked_contract && Init_link.Values.is_empty (fst r).extras.links then r
      else match s.desc, Local_bindings.ids_for_stmt bindings s with
      | Ast.Let (_, _, _, Some rhs, _), id :: _ ->
          ((Lazy.force link_ops).assign_value (fst r) ("L" ^ string_of_int id ^ ":") rhs, snd r)
      | Ast.Let (_, _, _, None, _), id :: _ ->
          (set_links (fst r) (Init_link.forget_value (fst r).extras.links
              ("L" ^ string_of_int id ^ ":")), snd r)
      | _ -> r in
    if not !in_trial && !unsafe_uses <> before then note_unsafe s.loc;
    (match !trace_func with
     | Some f when f = fdef.Ast.name -> trace_state s (fst r)
     | _ -> ());
    r
  and stmt_inner st (s : Ast.stmt) =
    cur_loc := s.loc;
    cur_vers := st.vers;
    match s.desc with
    | Ast.Let (true, name, _, Some e, _)
      when (match Local_bindings.ids_for_stmt bindings s with
            | id :: _ -> versionable name id | [] -> false) ->
        (* GitHub issue #978: `let mut x = e` starts a version of x. *)
        let id = List.hd (Local_bindings.ids_for_stmt bindings s) in
        (assign_versioned expr call st id e, false)
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
    | Ast.Let (_, name, _, Some ({ desc = Ast.StructLit values; _ } as e), _) ->
        (* A struct literal writes every field and no padding. *)
        let st = expr st e in
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ ->
             (match Types.IntMap.find_opt id finfo.Types.binding_types with
              | Some ty ->
                  let equations = match record_fields ty with
                    | Some fields when List.length fields = List.length values ->
                        List.filter_map (fun ((field, ty), value) ->
                          if unsigned_ty ty then Option.map (fun term -> field, Init_pred.normalize st.eqs term)
                            (lin st value) else None) (List.combine fields values)
                    | _ -> [] in
                  let st = bump st [id] in
                  let st = { st with eqs = st.eqs @ List.map (fun (field, term) ->
                    field_name st id field, term) equations } in
                  let key = "L" ^ string_of_int id in
                  let leaves = leaves_of [] [] ty in
                  Hashtbl.replace roots key
                    { display = name; leaves; array_root = false; out_param = false };
                  ({ st with u = List.fold_left (fun s (p, _) ->
                       if is_pad p then Leaves.add (key, p) s else s) st.u leaves }, false)
              | None -> (st, false))
         | [] -> (st, false))
    | Ast.Let (false, _, _, Some e, _)
      when view_of st e <> None
           && (match Local_bindings.ids_for_stmt bindings s with
               | id :: _ ->
                   (match Option.map strip
                            (Types.IntMap.find_opt id finfo.Types.binding_types) with
                    | Some (Ast.TypeSlice _) -> true
                    | _ -> false)
               | [] -> false) ->
        (* GitHub issue #954: an immutable view binding is an alias; it
           reads nothing until it is used. *)
        let v = Option.get (view_of st e) in
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
             (match side st a, side st b with
              | Some l, Some r ->
                  ({ st with facts = { st.facts with
                       Init_pred.mins = (xa, l, r) :: st.facts.Init_pred.mins } }, false)
              | Some l, None | None, Some l -> (add_fact st (Init_pred.sub l x), false)
              | None, None -> (st, false))
         | _ -> (st, false))
    | Ast.Let (_, _, _, Some ({ desc = Ast.Call _; _ } as e), _) ->
        let st = match Local_bindings.ids_for_stmt bindings s with
          | id :: _ when (match id_type id with Some ty -> record_fields ty <> None | None -> false) ->
              bump st [id]
          | _ -> st in
        let (st, gs) = call st e ~result:(bind_result s) in
        (* GitHub issue #975: an immutable binding of a call's result keeps
           the facts that depend on it, for a later `match` or `return`. *)
        let st = match Local_bindings.ids_for_stmt bindings s with
          | id :: _ when immutable id ->
              if gs = [] then Hashtbl.remove bound_gs id
              else Hashtbl.replace bound_gs id gs;
              let roots = List.fold_left (fun roots guard ->
                List.fold_left (fun roots (v, _) ->
                  let root = v.vp.root in
                  if projected_root root then StringSet.add root roots else roots)
                roots (guard_facts guard)) StringSet.empty gs in
              let owner_guards = if StringSet.is_empty roots then
                  Types.IntMap.remove id st.extras.owner_guards
                else Types.IntMap.add id roots st.extras.owner_guards in
              { st with extras = { st.extras with owner_guards } }
          | _ -> st in
        (st, false)
    | Ast.Let (false, _, _, Some ({ desc = Ast.SliceOf (b, lo, _); _ } as e), _)
      when view_of st e = None && view_of st b <> None && lin st lo <> None
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
        let v = Option.get (view_of st b) in
        let id = List.hd (Local_bindings.ids_for_stmt bindings s) in
        let st = place_subexprs_view st e in
        Hashtbl.replace aliases id
          { v with off = Init_pred.add v.off (Option.get (lin st lo));
                   len = Some (len_atom id) };
        (st, false)
    | Ast.Let (false, _, _, Some e, _)
      when (match Local_bindings.ids_for_stmt bindings s with
            | id :: _ -> immutable id && unsigned_id id
            | [] -> false) ->
        (* GitHub issue #1007: an immutable unsigned `let x = e` whose value
           is a fact side (a constant, another immutable binding, a slice
           length, a non-wrapping difference) is that term, as the runtime
           order graph equated it: `let n = s.len; for i in 0..<n { s[i] }`. *)
        let st = expr st e in
        let id = List.hd (Local_bindings.ids_for_stmt bindings s) in
        (match side st e with
         | Some t ->
             let t = Init_pred.normalize st.eqs t in
             ({ st with eqs = st.eqs @ [("v" ^ string_of_int id, t)] }, false)
         | None -> (st, false))
    | Ast.Let (false, _, _, Some ({ desc = Ast.Var _; _ } as e), _)
      when (match Local_bindings.id_for_expr bindings e with
            | Some id -> Types.IntMap.mem id st.extras.owners
            | None -> false) ->
        let st = expr st e in
        let st = match Local_bindings.id_for_expr bindings e, Local_bindings.ids_for_stmt bindings s with
          | Some source, [destination] ->
              let root = Types.IntMap.find source st.extras.owners in
              with_owners st (Types.IntMap.add destination root
                (Types.IntMap.remove source st.extras.owners))
          | _ -> st in
        (st, false)
    | Ast.Let (_, _, _, Some e, _) | Ast.LetTuple (_, e) | Ast.Expr e
    | Ast.Yield e -> (expr st e, noreturn e)
    | Ast.Return eo ->
        (* GitHub issue #977: `return g(...)` names g's result by an atom
           of its own, so g's ensures over `result` meets this function's
           ensures over `result`, as `let r = g(...); return r;` would. *)
        let ret = match eo with
          | Some { desc = Ast.Call (name, _); _ }
            when name <> "min"
                 && (match fdef.Ast.ret_type with
                     | Some t -> unsigned_ty t | None -> false) ->
              Some (Init_pred.atom "ret:call")
          | _ -> None in
        let (st, gs) = match eo with
          | Some ({ desc = Ast.Call _; _ } as e) -> call st e ~result:ret
          | Some ({ desc = Ast.Var _; _ } as e) ->
              (expr st e, Option.value ~default:[] (bound_guarded st e))
          | Some e -> (expr st e, [])
          | None -> (st, []) in
        (match eo, ret_variant, ret_is_bool with
         | Some { desc = Ast.EnumVariant (_, tag) | Ast.VariantCtor (_, tag, _); _ }, _, _ ->
             observe_param_return st tag s.loc
         | Some { desc = Ast.BoolLit b; _ }, _, _ ->
             observe_param_return st (string_of_bool b) s.loc
         | _, Some cases, _ ->
             List.iter (fun (tag, _) ->
               observe_param_return (apply_case st gs tag (fun _ -> None)) tag s.loc) cases
         | _, _, true ->
             List.iter (fun b ->
               observe_param_return (apply_bool st gs b) (string_of_bool b) s.loc) [true; false]
         | _ -> observe_param_return st "always" s.loc);
        check_outs st s.loc; check_ensures ?ret st eo gs s.loc; (st, true)
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
        let head = loop_head st body (fun h ->
          let h = expr h c in (assume h c true, h)) in
        (assume (expr head c) c false,
         Control_flow.never_returns ~noreturn [s])
    | Ast.For (_, _, lo, hi, body) ->
        let st = expr (expr st lo) hi in
        (* GitHub issue #975: the counter lies in [lo, hi) in the body. *)
        let in_body = match Local_bindings.ids_for_stmt bindings s with
          | [_; id] when unsigned_id id ->
              let i = v_atom id in
              let st = match side st lo with
                | Some l -> add_fact st (Init_pred.sub i l) | None -> st in
              (match side st hi with
               | Some h -> add_fact st (Init_pred.sub (Init_pred.sub h i) (Init_pred.const 1))
               | None -> st)
          | _ -> st in
        let head = loop_head st body (fun h ->
          (* the head state plus the counter's range facts, which are
             about the immutable counter and bounds fixed before the loop *)
          let entered = { h with facts = { h.facts with Init_pred.ge =
               List.filter (fun t -> not (List.exists (Init_pred.equal t) st.facts.Init_pred.ge))
                 in_body.facts.Init_pred.ge @ h.facts.Init_pred.ge } } in
          let entered = match Local_bindings.ids_for_stmt bindings s with
            | [_; id] -> (match lin st lo with
                | Some start -> List.fold_left (fun acc (p, (lower, _)) ->
                    let offset = Init_pred.sub lower start in
                    add_iv acc p (lower, Init_pred.add offset (v_atom id)))
                    entered (filled_by_loop st s lo hi body)
                | None -> entered)
            | _ -> entered in
          (entered, h)) in
        (List.fold_left (fun st (p, iv) -> add_iv st p iv) head
           (filled_by_loop st s lo hi body), false)
    | Ast.ForEach (_, seq, body) ->
        let st = expr st seq in
        (loop_head st body (fun h -> (h, h)), false)
    | Ast.Match (d, arms) | Ast.LetMatch (_, _, _, d, arms) ->
        let (st, gs) = match d.desc with
          | Ast.Call _ -> call st d ~result:None
          | Ast.Var _ -> (expr st d, Option.value ~default:[] (bound_guarded st d))
          | _ -> (expr st d, []) in
        merge (List.mapi (fun i a ->
          (* GitHub issue #975: the binder's payload type, for its facts. *)
          (match a, Local_bindings.id_for_arm bindings s.loc i with
           | Ast.ArmVariant (vname, case, Some (Ast.PayloadBind (_, false)), _), Some id ->
               Option.iter (Hashtbl.replace arm_types id) (variant_payload vname case)
           | _ -> ());
          let st = match a with
            | Ast.ArmVariant (_, case, payload, _) when gs <> [] ->
                let st = match Local_bindings.id_for_arm bindings s.loc i with
                  | Some id -> bump st [id] | None -> st in
                let value kind = match payload with
                  | Some (Ast.PayloadBind (_, false)) ->
                      (match Local_bindings.id_for_arm bindings s.loc i with
                       | Some id when immutable id -> (match kind with
                           | `Val _ -> Some (v_atom id)
                           | `Field field -> field_term st id field
                           | `Len _ -> None)
                       | _ -> None)
                  | _ -> None in
                apply_case st gs case value
            | _ -> st in
          let run () = stmts st (arm_body a) in
          let storage = match a with
            | Ast.ArmVariant (vname, case, Some (Ast.PayloadBind (name, false)), _) ->
                Option.map (fun storage -> name, storage)
                  (Option.bind (variant_payload vname case) owner_type)
            | _ -> None in
          match storage, Local_bindings.id_for_arm bindings s.loc i with
          | Some (name, storage), Some id ->
              let root = "owner-local:" ^ string_of_int id in
              Hashtbl.replace roots root
                { display = name; leaves = [[], owner_leaf_type storage];
                  array_root = false; out_param = false };
              let st = with_owners (forget_owner_guards st root)
                (Types.IntMap.add id root st.extras.owners) in
              let leaf = root, [] in
              let clear st = { st with iv = List.filter (fun (k, _) -> k <> leaf) st.iv } in
              let initial = clear { st with u = Leaves.add leaf st.u } in
              let result, dead = Fun.protect
                ~finally:(fun () ->
                  Hashtbl.filter_map_inplace (fun _ v ->
                    if v.vp.root = root then None else Some v) aliases)
                (fun () -> stmts initial (arm_body a)) in
              let result = with_owners result (Types.IntMap.filter
                (fun _ owned_root -> owned_root <> root) result.extras.owners) in
              (clear { result with u = Leaves.remove leaf result.u }, dead)
          | _ -> run ()) arms)
    | Ast.Break | Ast.Continue -> (st, true)
    | Ast.StaticAssert _ -> (st, false)
  (* GitHub issue #978: the state at a loop's head. The versioned locals
     the body assigns get one fresh version each, the head version, and
     the head keeps the candidate intervals that hold on entry (with the
     head version equal to the entry version) and that each iteration
     re-establishes (with the end-of-body version renamed to the head's):
     a quantifier-free inductive invariant, found by shrinking the
     candidate set to a fixpoint. Both checks of a kept candidate become
     z3 obligations. A body that leaves an iteration by `break` or
     `continue` keeps no candidate. [enter h] gives the state the body
     starts from and the head state itself (a `while` evaluates its
     condition first). The body is checked once, for real, from the
     fixpoint. *)
  and loop_head st body enter =
    let link_head = ref st.extras.links in
    let owner_head = ref st in
    let ids = List.sort_uniq compare (List.fold_left assigned_s [] body) in
    let hv = List.map (fun id -> (id, fresh_ver ())) ids in
    let to_head (s : state) =
      let s = List.fold_left (fun s (id, k) ->
        match Types.IntMap.find_opt id s.vers with
        | Some old when old <> k ->
            (* the head version's atom still names the value at the
               iteration's start; move it aside before the end version
               takes its name *)
            let s = rename_state s (ver_name id k) (ver_name id (fresh_ver ())) in
            rename_state s (ver_name id old) (ver_name id k)
        | _ -> s) s hv in
      { s with vers = List.fold_left (fun m (id, k) -> Types.IntMap.add id k m) s.vers hv } in
    let head_of cands =
      let st = List.fold_left (fun st ((root, _), _) -> touch_root st root) !owner_head cands in
      let st = set_links st !link_head in
      let h = { st with vers = List.fold_left (fun m (id, k) -> Types.IntMap.add id k m)
                                 st.vers hv } in
      let h = List.fold_left (fun h (id, k) ->
        add_declared_bounds h id (Init_pred.atom (ver_name id k))) h hv in
      { h with iv = h.iv @ List.filter (fun (l, _) -> Leaves.mem l h.u) cands } in
    (* entry: the head versions equal the entry ones *)
    let entry_eqs = List.filter_map (fun (id, k) ->
      match Types.IntMap.find_opt id st.vers with
      | Some old -> Some (ver_name id k, Init_pred.atom (ver_name id old))
      | None -> None) hv in
    let holds (s : state) eqs ((root, _) as l, iv) =
      let s = touch_root s root in
      not (Leaves.mem l s.u)
      || Init_pred.uncovered ~need_gap:false ~eqs:(eqs @ s.eqs) ~facts:s.facts (ivs_of s l) iv = None in
    let record (s : state) eqs ((root, _) as l, iv) what =
      let s = touch_root s root in
      if Leaves.mem l s.u then
        Range_obligation.record_text !cur_loc
          (Init_pred.obligation
             ~claim:(Printf.sprintf "loop invariant %s: [%s, %s)" what
                       (show (fst iv)) (show (snd iv)))
             ~facts:s.facts (eqs @ s.eqs) (ivs_of s l) iv) in
    let run h =
      let (start, _) = enter h in
      let (fin, dead) = stmts start body in
      if dead then None else Some (to_head fin) in
    let mentions_head (_, (lo, hi)) =
      List.exists (fun (id, k) ->
        let a = ver_name id k in
        Init_pred.SMap.mem a lo.Init_pred.m || Init_pred.SMap.mem a hi.Init_pred.m) hv in
    let quiet f =
      let saved_errors = !errors and saved_obl = !Range_obligation.enabled
      and saved_trace = !trace_func in
      let saved_trial = !in_trial in
      Range_obligation.enabled := false; trace_func := None; in_trial := true;
      let r = f () in
      in_trial := saved_trial;
      errors := saved_errors; Range_obligation.enabled := saved_obl;
      trace_func := saved_trace; r in
    (* A loop can revisit its header or exit abruptly after an opaque write.
       Collect invalidations even from paths that do not reach the backedge. *)
    if not (Types.IntMap.is_empty st.extras.owners) then begin
      let invalidated = ref StringSet.empty in
      let outer = !note_owner_invalidation in
      note_owner_invalidation := (fun root ->
        invalidated := StringSet.add root !invalidated; outer root);
      Fun.protect ~finally:(fun () -> note_owner_invalidation := outer)
        (fun () -> quiet (fun () -> ignore (run (head_of []))));
      owner_head := Types.IntMap.fold (fun _ root head ->
        if StringSet.mem root !invalidated then invalidate_owner head root else head)
        st.extras.owners st
    end;
    (* Linked candidates are the entry certificates, intersected with every
       backedge. Mutable binding keys denote their current values here; the
       scalar assignments above replace, rather than accumulate, certificates.
       Abrupt loop exits retain no candidate in this restricted connection. *)
    if not (Init_link.Values.is_empty !link_head) then
      quiet (fun () ->
        let rec shrink fuel =
          if fuel = 0 || leaves_iteration 0 body then link_head := Init_link.empty
          else match run (head_of []) with
          | None -> link_head := Init_link.empty
          | Some fin ->
              let kept = Init_link.join !link_head fin.extras.links in
              if not (Init_link.Values.equal Init_link.Storages.equal kept !link_head) then
                (link_head := kept; shrink (fuel - 1)) in
        shrink 32);
    let cands =
      if ids = [] || leaves_iteration 0 body then []
      else
        quiet (fun () ->
          (* candidates: what one iteration from the bare head ends with *)
          let first = match run (head_of []) with
            | Some fin -> List.filter mentions_head fin.iv
            | None -> [] in
          let starts l = Init_pred.const 0 :: List.map fst (ivs_of st l) in
          let shaped = List.concat_map (fun l ->
            List.concat_map (fun lo ->
              List.map (fun (id, k) -> (l, (lo, Init_pred.atom (ver_name id k)))) hv)
              (starts l)) (Leaves.elements st.u) in
          let first = List.sort_uniq compare (first @ shaped) in
          let first = List.filter (holds st entry_eqs) first in
          let rec fix cands n =
            if cands = [] || n = 0 then [] else
            match run (head_of cands) with
            | None -> cands
            | Some fin ->
                let kept = List.filter (holds fin []) cands in
                if List.length kept = List.length cands then cands
                else fix kept (n - 1) in
          fix first 6) in
    let head = head_of cands in
    (* the real check, and the invariant's obligations *)
    let (start, at_head) = enter head in
    let (fin, dead) = stmts start body in
    if not dead then begin
      let fin = to_head fin in
      List.iter (fun c ->
        record st entry_eqs c "on entry";
        record fin [] c "preserved") cands
    end;
    cur_vers := at_head.vers;
    at_head
  in
  (* Requires: assumed at entry. *)
  ignore assigned_s;
  let entry_u = Types.IntMap.fold (fun id root uninit ->
    if List.exists (fun name -> List.assoc_opt name param_ids = Some id) initialized_owner_parameters
    then uninit
    else Leaves.add (root, []) uninit) entry_owners entry_u in
  let entry = { extras = {empty_extras with owners = entry_owners}; u = entry_u; iv = []; eqs = []; facts = Init_pred.no_facts;
                vers = Types.IntMap.empty } in
  (* A where clause is already checked at every call. Import only scalar
     unsigned singleton parameters whose bindings cannot be changed by alias. *)
  let static_params = if fdef.Ast.where_clauses = [] then [] else List.filter_map (fun (name, ty) ->
    match ty, List.assoc_opt name param_ids with
    | Ast.TypeSingleton (base, Ast.StaticName k), Some id
      when unsigned_ty base && not (Hashtbl.mem addr_taken id)
           && immutable_var name id -> Some (k, v_atom id)
    | _ -> None) param_types in
  let rec static_term = function
    | Ast.StaticInt n -> leaf_const (Some n)
    | Ast.StaticName n -> List.assoc_opt n static_params
    | Ast.StaticAdd (a, b) -> Option.bind (static_term a) (fun a ->
        Option.map (Init_pred.add a) (static_term b))
    | Ast.StaticSub (a, b) -> Option.bind (static_term a) (fun a ->
        Option.map (Init_pred.sub a) (static_term b))
    | Ast.StaticMul (a, b) -> (match static_term a, static_term b with
        | Some a, Some b when Init_pred.SMap.is_empty a.m -> Some (Init_pred.scale a.c b)
        | Some a, Some b when Init_pred.SMap.is_empty b.m -> Some (Init_pred.scale b.c a)
        | _ -> None)
    | _ -> None in
  let entry = List.fold_left (fun st (a, cmp, b) ->
    match checked (fun () -> match static_term a, static_term b with
      | Some a, Some b -> Some (Init_pred.sub (Init_pred.sub b a)
          (Init_pred.const (if cmp = Ast.WhereLt then 1 else 0)))
      | _ -> None) with
    | Some fact -> add_fact st fact | None -> st) entry fdef.Ast.where_clauses in
  let entry = List.fold_left (fun st (c : Init_state.clause) ->
    match c.body with
    | Init_state.CPlain p when c.requires ->
        let st = match p with Init_state.PLinked _ ->
          (Lazy.force link_ops).apply_pred st ~arg_view:own_arg_view p c.cloc | _ -> st in
        List.fold_left (fun st r -> match r with
          | Some f -> apply_fact st f
          | None -> st) st
          (resolve_pred ~index_expr:Fun.id ~arg_view:own_arg_view
             ~owner_view:(fun name -> Option.bind (List.assoc_opt name param_ids) (projected_view st))
             ~env:(own_env ~result:None ~binder:None) p)
    | _ -> st) entry contracts in
  (* GitHub issue #983: a term step past the checker's native range is
     refused where a term is read; one that still escapes from combining
     stored terms rejects the function rather than deciding on a wrapped
     native value. *)
  (try
     let (st, dead) = stmts entry fdef.Ast.body in
     if not dead then begin
       observe_param_return st "always" fdef.Ast.def_loc;
       check_outs st fdef.Ast.def_loc;
       check_ensures st None [] fdef.Ast.def_loc
     end
   with Init_pred.Overflow ->
     error fdef.Ast.def_loc
       "an initialization interval bound leaves the checker's integer range \
        (2^62); bound it with a smaller constant");
  Hashtbl.iter decide_index index_decisions;
  Option.iter (Hashtbl.iter decide_array_index) array_decisions;
  match List.rev !errors with
  | [] -> ()
  | [(loc, msg)] -> raise (Types.TypeError (loc, msg))
  | errs -> raise (Types.MultiTypeError errs)
