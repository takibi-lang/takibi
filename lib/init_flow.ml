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
     has no ranges) and reads nothing;
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

let check
    ~(struct_fields : string -> (string * Ast.type_expr) list option)
    ~(callee : string -> ((Ast.ident * Ast.type_expr option) list * Ast.loc) option)
    ~(scratch : (string * Ast.type_expr) list)
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
  let entry = Hashtbl.fold (fun key _ acc ->
    List.fold_left (fun s l -> Leaves.add l s) acc (all_leaves key))
    roots Leaves.empty in
  (* borrow uninit parameters. *)
  let entry = List.fold_left2 (fun st (name, ty) id ->
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
    | _ -> st) entry fdef.Ast.params bindings.Local_bindings.param_ids in
  let out_keys = Hashtbl.fold (fun k r acc -> if r.out_param then k :: acc else acc)
      roots [] in
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
  let check_read st p ~bytes loc =
    let bad = Leaves.filter (fun (r, l) ->
      r = p.root && (is_prefix p.path l || is_prefix l p.path)
      && (bytes || not (is_pad l))) st in
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
        Leaves.diff st bad
  in
  (* `.len` of a slice or array place reads metadata, not the elements. *)
  let is_len_of (e : Ast.expr) = match e.desc with
    | Ast.FieldGet (base, "len") ->
        (match place base with
         | Some p ->
             (match leaf_type p.root p.path with
              | Some t -> (match strip t with
                  | Ast.TypeSlice _ | Ast.TypeArray _ -> true | _ -> false)
              | None -> false)
         | None -> false)
    | _ -> false
  in
  let fill st p =
    if p.inside then st
    else Leaves.filter (fun (r, l) -> not (r = p.root && is_prefix p.path l)) st
  in
  (* A `&mut` callee is trusted to store every field; a field store never
     writes padding, so padding keeps its state. *)
  let fill_fields st p =
    if p.inside then st
    else Leaves.filter (fun (r, l) ->
      not (r = p.root && is_prefix p.path l && not (is_pad l))) st
  in
  let unsafe_depth = ref 0 in
  let rec expr st (e : Ast.expr) : Leaves.t =
    if is_len_of e then st else
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
    | Ast.Call (name, args) ->
        let params = match callee name with
          | Some (ps, loc) when List.length ps = List.length args -> Some (ps, loc)
          | _ -> None in
        let (st, fills) = List.fold_left (fun (st, fills) (i, a) ->
          let out = match params with
            | Some (ps, loc) ->
                let (pname, pty) = List.nth ps i in
                (match Init_state.param_qual loc pname with
                 | Some Init_state.Uninit -> `Out
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
          | `Out | `Fields ->
              (match fill_target a with
               | `Whole (p, inner) -> (place_subexprs st inner, (p, out) :: fills)
               | `Partial inner -> (place_subexprs_any st inner, fills)
               | `Other -> (expr st a, fills))
          | `No -> (expr st a, fills))
          (st, []) (List.mapi (fun i a -> (i, a)) args) in
        List.fold_left (fun st (p, how) ->
          match how with
          | `Fields -> fill_fields st p
          | _ -> fill st p) st fills
    | Ast.BinOp ((Ast.And | Ast.Or), l, r) ->
        let st = expr st l in
        ignore (expr st r); st
    | Ast.BinOp (_, l, r) -> expr (expr st l) r
    | Ast.Index (l, r) -> expr (expr st l) r
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
  (* The index expressions inside a place chain are ordinary reads. *)
  and place_subexprs st (e : Ast.expr) = match e.desc with
    | Ast.FieldGet (b, _) | Ast.Deref b -> place_subexprs st b
    | Ast.Index (b, i) -> place_subexprs (expr st i) b
    | _ -> st
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
    | `Partial inner -> place_subexprs_any st inner
    | `Other -> expr st a
  and assign st p (rhs : Ast.expr) =
    let src = match rhs.desc with
      | Ast.StructLit _ -> `Literal
      | _ -> (match place rhs with
          | Some q when not q.inside -> `Place q
          | _ -> `Untracked) in
    let pads = List.filter (fun (r, l) -> r = p.root && is_prefix p.path l && is_pad l)
        (all_leaves p.root) in
    let st = fill st p in
    List.fold_left (fun st (r, l) ->
      let suffix = drop (List.length p.path) l in
      let uninit = match src with
        | `Literal -> true
        | `Untracked -> false
        | `Place q -> Leaves.mem (q.root, q.path @ suffix) st in
      if uninit then Leaves.add (r, l) st else st) st pads
  in
  let check_outs st loc =
    List.iter (fun key ->
      let bad = Leaves.filter (fun (r, _) -> r = key) st in
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
  let merge results =
    match List.filter (fun (_, dead) -> not dead) results with
    | [] -> (Leaves.empty, true)
    | (first, _) :: rest ->
        (List.fold_left (fun acc (s, _) -> Leaves.union acc s) first rest, false)
  in
  let trackable ty = match strip ty with
    | Ast.TypeArray _ -> false
    | _ -> true
  in
  let rec stmts st ss =
    List.fold_left (fun (st, dead) s ->
      if dead then (st, dead) else stmt st s) (st, false) ss
  and stmt st (s : Ast.stmt) = match s.desc with
    | Ast.Let (_, name, _, None, _) ->
        (match Local_bindings.ids_for_stmt bindings s with
         | id :: _ ->
             (match Types.IntMap.find_opt id finfo.Types.binding_types with
              | Some ty when trackable ty ->
                  let key = "L" ^ string_of_int id in
                  Hashtbl.replace roots key
                    { display = name; leaves = leaves_of [] [] ty;
                      array_root = false; out_param = false };
                  (List.fold_left (fun s l -> Leaves.add l s) st (all_leaves key), false)
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
                  (List.fold_left (fun s (p, _) ->
                     if is_pad p then Leaves.add (key, p) s else s) st leaves, false)
              | None -> (st, false))
         | [] -> (st, false))
    | Ast.Let (_, _, _, Some e, _) | Ast.LetTuple (_, e) | Ast.Expr e
    | Ast.Yield e -> (expr st e, false)
    | Ast.Return eo ->
        let st = match eo with Some e -> expr st e | None -> st in
        check_outs st s.loc; (st, true)
    | Ast.Block b -> stmts st b
    | Ast.UnsafeBlock b ->
        incr unsafe_depth;
        let r = stmts st b in
        decr unsafe_depth; r
    | Ast.If (c, yes, no) ->
        let st = expr st c in
        merge [stmts st yes; stmts st no]
    | Ast.While (c, body) ->
        let st = expr st c in
        ignore (stmts st body); (st, false)
    | Ast.For (_, _, lo, hi, body) ->
        let st = expr (expr st lo) hi in
        ignore (stmts st body); (st, false)
    | Ast.ForEach (_, seq, body) ->
        let st = expr st seq in
        ignore (stmts st body); (st, false)
    | Ast.Match (d, arms) | Ast.LetMatch (_, _, _, d, arms) ->
        let st = expr st d in
        merge (List.map (fun a -> stmts st (arm_body a)) arms)
    | Ast.Break | Ast.Continue -> (st, true)
    | Ast.StaticAssert _ -> (st, false)
  in
  let (st, dead) = stmts entry fdef.Ast.body in
  if not dead then check_outs st fdef.Ast.def_loc;
  match List.rev !errors with
  | [] -> ()
  | [(loc, msg)] -> raise (Types.TypeError (loc, msg))
  | errs -> raise (Types.MultiTypeError errs)
