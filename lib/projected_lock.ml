(* Verify a declared lock transition down to a resolved atomic cell. Then
   follow the exclusive obligation through the linear projected owner. *)
module M = Types.StringMap
module I = Types.IntMap
module H = Set.Make (struct
  type t = int * string * string
  let compare = Stdlib.compare
end)

let fail loc message =
  raise (Types.TypeError (loc, "projected lock: " ^ message))

let rec unwrap = function
  | Ast.TypeBorrow ty | Ast.TypeBorrowMut ty | Ast.TypeSink ty
  | Ast.TypeSingleton (ty, _) | Ast.TypeExists (_, _, ty) -> unwrap ty
  | ty -> ty

let nominal ty = match unwrap ty with
  | Ast.TypeNamed name | Ast.TypeIndexed (name, _) -> Some name
  | _ -> None

let referenced ty = match unwrap ty with
  | Ast.TypePtr ty | Ast.TypeRef ty | Ast.TypeRefMut ty -> nominal ty
  | _ -> None

type word = { member : string; free : int64; held : int64 }
type owner = {
  owner_name : string;
  pin_name : string;
  pin_field : string;
  pin_position : int;
  projector : string;
  record : string;
  lock : string;
  word_type : string;
}
let fact (schema : owner) pin = pin, schema.projector, schema.lock
let has_pin held pin = H.exists (fun (id, _, _) -> pin = id) held

type transition = { kind : Projected_lock_decl.operation; position : int; word_type : string }

let literal id (e : Ast.expr) = match e.desc with
  | Ast.IntLit n -> Some n
  | Ast.Var name when id e = None -> Option.map Int64.of_int (Const_env.find name)
  | _ -> None

let compare_bool operator x y =
  match operator with Ast.Eq -> x = y | _ -> x <> y

(* The primitive interpreter has one lock state, not a model of the
   enclosing kernel. Direct forwarding instantiates the actual formal
   paths. A polling load has two possible outcomes and never mints a hold. *)
let verify_transition ~definition ~target ~word ~transition (f : Ast.func) info =
  let rec function_body ancestors key (f : Ast.func) info formal initial =
    if List.mem key ancestors then fail f.def_loc "recursive lock primitive";
    let id = Local_bindings.id_for_expr info.Types.bindings in
    let rec place (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Option.bind (id e) (fun id -> I.find_opt id formal)
      | Ast.AddrOf child -> place child
      | Ast.FieldGet (base, field) -> Option.map (fun path -> path @ [field]) (place base)
      | _ -> None in
    let exact e = place e = Some [word.member] in
    let possible held = [held, Some false; held, Some true] in
    let rec evaluate held (e : Ast.expr) =
      match e.desc with
      | Ast.BoolLit result -> [held, Some result]
      | Ast.IntLit _ | Ast.Var _ -> [held, None]
      | Ast.Bnot inner ->
          List.map (fun (held, result) -> held, Option.map not result) (evaluate held inner)
      | Ast.BinOp ((Ast.Eq | Ast.Ne as op), inner, {desc = Ast.BoolLit value; _}) ->
          List.map (fun (held, result) -> held, Option.map (fun result ->
            compare_bool op result value) result) (evaluate held inner)
      | Ast.BinOp ((Ast.Eq | Ast.Ne), inner, rhs) ->
          List.concat_map (fun (state, _) ->
            List.concat_map (fun (state, _) -> possible state) (evaluate state rhs))
            (evaluate held inner)
      | Ast.Call (name, args) ->
          let atomic_name = Option.value ~default:name (Atomic_spec.cell_intrinsic name) in
          (match Atomic_spec.find atomic_name, args with
           | Some operation, (cell :: values) when exact cell ->
               (match operation.operation, operation.ordering, values with
                | Atomic_spec.Compare_exchange, (Acquire | Acq_rel), [free; next]
                    when literal id free = Some word.free && literal id next = Some word.held && not held ->
                    [false, Some false; true, Some true]
                | Atomic_spec.Store, Release, [free] when held && literal id free = Some word.free ->
                    [false, None]
                | Atomic_spec.Load, _, [] -> [held, None]
                | _ -> fail e.loc "invalid atomic operation on the declared lock cell")
           | Some _, _ -> fail e.loc "operation uses another lock cell"
           | None, _ ->
               (match Option.bind (target e) (fun key ->
                        Option.map (fun (definition, info) -> key, definition, info) (definition key)) with
                | Some (callee, callee_def, callee_info) ->
                    let ids = callee_info.Types.bindings.param_ids in
                    let stable (arg : Ast.expr) =
                      match arg.desc with
                      | Ast.IntLit _ | Ast.BoolLit _ | Ast.Var _ -> true
                      | _ -> place arg <> None in
                    if List.length ids <> List.length args || not (List.for_all stable args) then
                      fail e.loc "unresolved lock forwarding";
                    let actual = List.fold_left2 (fun actual id arg ->
                      match place arg with None -> actual | Some path -> I.add id path actual)
                      I.empty ids args in
                    if I.is_empty actual then fail e.loc "lock primitive loses the declared cell";
                    function_body (key :: ancestors) callee callee_def callee_info actual held
                | None -> fail e.loc "call in a lock primitive needs a checked direct body"))
      | _ -> fail e.loc "expression is outside the projected lock primitive rule"
    and test held e =
      List.concat_map (function
        | held, Some value -> [held, value]
        | held, None -> [held, false; held, true]) (evaluate held e)
    and block active statements =
      match statements, active with
      | [], _ | _, [] -> active, []
      | stmt :: rest, _ ->
          let next, returns = List.fold_left (fun (states, returns) held ->
            let current, exits = statement held stmt in
            current @ states, exits @ returns) ([], []) active in
          let after, later = block (List.sort_uniq Bool.compare next) rest in
          after, List.sort_uniq Stdlib.compare (returns @ later)
    and statement held (s : Ast.stmt) = match s.desc with
      | Ast.Expr e -> List.map fst (evaluate held e), []
      | Ast.Return None -> [], [held, None]
      | Ast.Return (Some e) -> [], evaluate held e
      | Ast.If (e, yes, no) ->
          List.fold_left (fun (next, returns) (held, success) ->
            let out, exit = block [held] (if success then yes else no) in
            out @ next, exit @ returns) ([], []) (test held e)
      | Ast.While (condition, body) ->
          let rec visit pending seen exits returns = match pending with
            | [] -> exits, returns
            | held :: rest when List.mem held seen -> visit rest seen exits returns
            | held :: rest ->
                let pending, exits, returns =
                  List.fold_left (fun (pending, exits, returns) (held, success) ->
                    if success then
                      let next, out = block [held] body in
                      next @ pending, exits, out @ returns
                    else pending, held :: exits, returns)
                    (rest, exits, returns) (test held condition) in
                visit pending (held :: seen) exits returns in
          visit [held] [] [] []
      | Ast.Block body -> block [held] body
      | _ -> fail s.loc "statement is outside the projected lock primitive rule"
    in
    let fallthrough, returns = block [initial] f.body in
    List.map (fun held -> held, None) fallthrough @ returns
  in
  let parameter = List.nth info.Types.bindings.param_ids transition.position in
  let start, finish =
    match transition.kind with Projected_lock_decl.Acquire -> false, true | Release -> true, false in
  let results = function_body [] (Types.loc_key f.def_loc) f info (I.singleton parameter []) start in
  if results = [] || not (List.for_all (fun (held, _) -> held = finish) results) then
    fail f.def_loc "primitive does not make the declared transition on every returning path"

let check ~program ~functions ~definition ~target ~function_values ~fields ~variants ~constructors ~addresses =
  let declarations = Projected_lock_decl.fields () in
  let field record name = Option.bind (fields record) (List.assoc_opt name) in
  let words = List.fold_left (fun words (record, decl, loc) ->
    match decl with
    | Projected_lock_decl.Word {field = member; free; held} ->
        if free = held || field record member <> Some (Ast.TypeNamed "AtomicWord") ||
           not (No_copy_registry.is_no_copy record) then
          fail loc "lockword needs a distinct free and held value on an AtomicWord of a no_copy struct";
        M.add record {member; free; held} words
    | _ -> words) M.empty declarations in
  let owners = List.filter_map (fun (owner_name, decl, loc) ->
    match decl with
    | Projected_lock_decl.Owner {field = pin_field; projector; lock} ->
        let members = Option.value ~default:[] (fields owner_name) in
        let pin_position, pin_name =
          match List.find_index (fun (name, _) -> name = pin_field) members,
                Option.bind (List.assoc_opt pin_field members) nominal with
          | Some position, Some name -> position, name
          | _ -> fail loc "owns_lock needs an indexed pin field" in
        let projections = M.fold (fun key _ all -> match definition key with
          | Some (f, info) when f.Ast.name = projector && projector = "region_pin_record" &&
                                  f.def_loc.pos_fname = Ast.builtin_region_file ->
              (match info.Types.param_types, referenced info.ret_type with
               | [_, ty], Some record when nominal ty = Some pin_name -> (key, record) :: all
               | _ -> all)
          | _ -> all) functions [] in
        (match projections with
         | [projector, record] ->
             (match Option.bind (field record lock) nominal with
              | Some word_type when M.mem word_type words ->
                  Some {owner_name; pin_name; pin_field; pin_position; projector; record; lock; word_type}
              | _ -> fail loc "owns_lock projection needs a field with a declared lockword")
         | _ -> fail loc "owns_lock needs an exact generated region pin projection")
    | _ -> None) declarations in
  let owner_type ty =
    Option.bind (nominal ty) (fun name -> List.find_opt (fun owner -> owner.owner_name = name) owners) in
  let rec contains_protected seen ty =
    match unwrap ty with
    | Ast.TypeNamed name | Ast.TypeIndexed (name, _) | Ast.TypeVariant (name, _, _) ->
        if List.mem name seen then false else
        (match List.find_opt (fun owner ->
           owner.owner_name = name || owner.record = name || owner.pin_name = name) owners with
         | Some _ -> true
         | None ->
             let recurse = contains_protected (name :: seen) in
             Option.fold ~none:false ~some:(List.exists (fun (_, ty) -> recurse ty)) (fields name) ||
             Option.fold ~none:false
               ~some:(List.exists (fun (_, ty) -> Option.fold ~none:false ~some:recurse ty))
               (variants name))
    | Ast.TypeTuple types -> List.exists (contains_protected seen) types
    | Ast.TypeFn (params, ret, _) -> List.exists (contains_protected seen) (ret :: params)
    | Ast.TypeArray (ty, _) | Ast.TypeSlice (ty, _, _) | Ast.TypePtr ty
    | Ast.TypeAlignedPtr (_, ty) | Ast.TypeIo ty | Ast.TypeRef ty | Ast.TypeRefMut ty ->
        contains_protected seen ty
    | _ -> false in
  List.iter (function
    | Ast.ExternFuncDef (_, params, ret, _, loc)
      when List.exists (Option.fold ~none:false ~some:(contains_protected []))
        (ret :: List.map snd params) ->
        fail loc "an external declaration cannot carry a protected owner, pin, or record"
    | _ -> ()) program;
  let transitions = M.fold (fun key _ transitions ->
    match definition key with
    | None -> transitions
    | Some (f, info) ->
        match Projected_lock_decl.contract f.Ast.def_loc with
        | None -> transitions
        | Some {operation = kind; parameter} ->
            if not (Option.fold ~none:false ~some:(List.mem "locks") f.effects) then
              fail f.def_loc "checked lock transition requires the locks effect";
            if List.length f.params <> 1 || info.Types.ret_type <> Ast.TypeVoid then
              fail f.def_loc "lock transition needs one pointer argument and no value result";
            let position = match List.find_index (fun (name, _) -> name = parameter) info.Types.param_types with
              | Some position -> position
              | None -> fail f.def_loc "lock transition parameter does not exist" in
            let word_type, word =
              match Option.bind (referenced (snd (List.nth info.param_types position)))
                      (fun name -> Option.map (fun word -> name, word) (M.find_opt name words)) with
              | Some entry -> entry
              | None -> fail f.def_loc "lock transition parameter needs a declared lockword" in
            let transition = {kind; position; word_type} in
            verify_transition ~definition ~target ~word ~transition f info;
            M.add key transition transitions) functions M.empty in
  (* Infer the input obligation for a direct owner factory. Its whole body
     is checked again below with that obligation supplied at entry. *)
  let factories = M.fold (fun key _ factories ->
    match definition key with
    | Some (f, info) ->
        (match owner_type info.Types.ret_type, f.Ast.body with
         | Some schema, [
             ({desc = Ast.Let (_, _, _, Some ({desc = Ast.StructLit values; _} as ctor), _); _} as assignment);
             {desc = Ast.Return (Some result); _}]
             when List.length f.params = 1 &&
                  Hashtbl.find_opt constructors ctor.loc = Some schema.owner_name ->
             let id = Local_bindings.id_for_expr info.bindings in
             let pin = Option.bind (List.nth_opt values schema.pin_position) id in
             let position = Option.bind pin (fun pin ->
               List.find_index ((=) pin) info.bindings.param_ids) in
             (match position, id result, Local_bindings.ids_for_stmt info.bindings assignment with
              | Some position, Some returned, [created] when returned = created ->
                  (match snd (List.nth f.params position) with
                   | Some (Ast.TypeSink ty) when nominal ty = Some schema.pin_name ->
                       M.add key (position, schema) factories
                   | _ -> factories)
              | _ -> factories)
         | _ -> factories)
    | _ -> factories) functions M.empty in
  M.iter (fun _ callee ->
    match definition callee with
    | Some (f, info) when M.mem callee transitions || M.mem callee factories ||
                            List.exists (contains_protected [])
                              (info.Types.ret_type :: List.map snd info.param_types) ->
        fail f.def_loc "a projected lock operation cannot escape as a function value"
    | _ -> ()) function_values;
  let checked_addresses = Hashtbl.create 8 and checked_constructors = Hashtbl.create 4 in
  M.iter (fun key _ ->
    Option.iter (fun ((f : Ast.func), (info : Types.func_info)) ->
      let id = Local_bindings.id_for_expr info.bindings in
      let arm_types = Hashtbl.create 4 in
      let owner_of e = Option.bind (id e) (fun id ->
        let ty = match I.find_opt id info.binding_types with
          | Some _ as ty -> ty
          | None -> Hashtbl.find_opt arm_types id in
        Option.bind ty owner_type) in
      let select_pin (e : Ast.expr) = match e.desc with
        | Ast.FieldGet (source, name) ->
            (match owner_of source with
             | Some schema when schema.pin_field = name -> Some schema
             | _ -> None)
        | _ -> None in
      let as_lock (e : Ast.expr) = match e.desc with
        | Ast.AddrOf {desc = Ast.FieldGet (({desc = Ast.Call (_, [pin]); _} as project), name); _} ->
            Option.bind (id pin) (fun pin ->
              Option.map (fun schema -> pin, schema)
                (List.find_opt (fun schema ->
                  target project = Some schema.projector && schema.lock = name) owners))
        | _ -> None in
      let require_empty loc held =
        if not (H.is_empty held) then fail loc "projected lock obligation escapes or reaches an unmatched exit" in
      let rec expression held (e : Ast.expr) = match e.desc with
        | Ast.Call (_, args) ->
            let callee = target e in
            (match Option.bind callee (fun key -> M.find_opt key transitions) with
             | Some transition ->
                 (match List.nth_opt args transition.position with
                  | Some address ->
                      (match as_lock address with
                       | Some (pin, schema) when schema.word_type = transition.word_type ->
                           Hashtbl.replace checked_addresses address.loc ();
                           let lock = fact schema pin in
                           (match transition.kind with
                            | Projected_lock_decl.Acquire ->
                                if H.mem lock held then fail e.loc "lock already held for this pin";
                                H.add lock held
                            | Release ->
                                if not (H.mem lock held) then fail e.loc "release needs the same live pin's held lock";
                                H.remove lock held)
                       | _ -> fail e.loc "transition requires the current pin's declared lock projection")
                  | _ -> fail e.loc "lock argument is missing")
             | None ->
                 (match Option.bind callee (fun key -> M.find_opt key factories) with
                  | Some (position, schema) ->
                      (match Option.bind (List.nth_opt args position) id with
                       | Some pin when H.mem (fact schema pin) held -> H.remove (fact schema pin) held
                       | _ -> fail e.loc "owner factory needs the same live pin's held lock")
                  | None ->
                      let formals = match Option.bind callee definition with
                        | Some (definition, _) -> List.map snd definition.Ast.params
                        | None -> [] in
                      List.fold_left (fun held (position, arg) ->
                        let borrowed = match List.nth_opt formals position with
                          | Some (Some (Ast.TypeBorrow _)) -> true
                          | _ -> false in
                        if borrowed && (select_pin arg <> None ||
                          Option.fold ~none:false ~some:(has_pin held) (id arg))
                        then held
                        else expression held arg) held (List.mapi (fun position arg -> position, arg) args)))
        | Ast.StructLit values ->
            let schema = Option.bind (Hashtbl.find_opt constructors e.loc) (fun record ->
              List.find_opt (fun owner -> owner.owner_name = record) owners) in
            List.fold_left (fun held (position, (value : Ast.expr)) ->
              match schema with
              | Some schema when schema.pin_position = position ->
                  (match id value with
                   | Some pin when H.mem (fact schema pin) held ->
                       Hashtbl.replace checked_constructors e.loc ();
                       H.remove (fact schema pin) held
                   | _ -> fail value.loc "owner construction needs the same live pin's held lock")
              | _ -> expression held value) held (List.mapi (fun i value -> i, value) values)
        | Ast.Var _ when Option.fold ~none:false ~some:(has_pin held) (id e) ->
            fail e.loc "a bare held pin must be released or moved into its checked owner"
        | Ast.FieldGet _ when select_pin e <> None ->
            fail e.loc "a projected owner pin must be borrowed or moved into a local obligation"
        | Ast.BinOp ((Ast.And | Ast.Or), a, b) ->
            let left = expression held a in
            let right = expression left b in
            if not (H.equal left right) then fail e.loc "a short-circuit path changes the lock obligation";
            left
        | Ast.Assign (a, b) | Ast.BinOp (_, a, b) | Ast.Index (a, b) ->
            expression (expression held a) b
        | Ast.SliceOf (base, lo, hi) -> expression (expression (expression held base) lo) hi
        | Ast.FieldGet (base, _) | Ast.Bnot base | Ast.Deref base | Ast.AddrOf base
        | Ast.Cast (_, base) | Ast.Unsafe base | Ast.VariantCtor (_, _, base) -> expression held base
        | Ast.TupleLit values -> List.fold_left expression held values
        | _ -> held
      and body held statements = match statements with
        | [] -> Some held
        | statement :: rest ->
            Option.bind (one held statement) (fun held -> body held rest)
      and join loc paths =
        match List.filter_map Fun.id paths with
        | [] -> None
        | first :: rest ->
            if not (List.for_all (H.equal first) rest) then fail loc "branches disagree on the projected lock obligation";
            Some first
      and one held (s : Ast.stmt) = match s.desc with
        | Ast.Let (_, _, _, Some value, _) when select_pin value <> None ->
            (match Local_bindings.ids_for_stmt info.bindings s, select_pin value with
             | [pin], Some schema -> Some (H.add (fact schema pin) held)
             | _ -> fail s.loc "owner field move needs a named pin")
        | Ast.Return result ->
            let held = Option.fold ~none:held ~some:(expression held) result in
            require_empty s.loc held;
            None
        | Ast.If (condition, yes, no) ->
            let held = expression held condition in
            join s.loc [body held yes; body held no]
        | Ast.Match (value, arms) | Ast.LetMatch (_, _, _, value, arms) ->
            let held = expression held value in
            join s.loc (List.mapi (fun index arm ->
              (match arm, Local_bindings.id_for_arm info.bindings s.loc index with
               | Ast.ArmVariant (variant, case, Some (Ast.PayloadBind _), _), Some binding ->
                   Option.iter (Hashtbl.replace arm_types binding)
                     (Option.bind (variants variant) (fun cases ->
                       Option.join (List.assoc_opt case cases)))
               | _ -> ());
              body held (Control_flow.arm_body arm)) arms)
        | Ast.While (e, loop) | Ast.ForEach (_, e, loop) ->
            require_empty s.loc held;
            require_empty s.loc (expression held e);
            Option.iter (require_empty s.loc) (body held loop);
            Some held
        | Ast.For (_, _, lo, hi, loop) ->
            require_empty s.loc (expression (expression held lo) hi);
            Option.iter (require_empty s.loc) (body held loop);
            Some held
        | Ast.Block statements | Ast.UnsafeBlock statements -> body held statements
        | Ast.Break | Ast.Continue -> require_empty s.loc held; None
        | Ast.Let (_, _, _, Some value, _) | Ast.Expr value | Ast.Yield value
        | Ast.LetTuple (_, value) | Ast.StaticAssert (value, _) -> Some (expression held value)
        | _ -> Some held in
      let held = match M.find_opt key factories with
        | Some (position, schema) -> H.singleton (fact schema (List.nth info.bindings.param_ids position))
        | None -> H.empty in
      Option.iter (require_empty f.def_loc) (body held f.body))
      (definition key)) functions;
  Hashtbl.iter (fun loc _ ->
    if not (Hashtbl.mem checked_constructors loc) then
      fail loc "owner construction is outside checked control flow") constructors;
  Hashtbl.iter (fun loc (record, field) ->
    if List.exists (fun owner -> owner.record = record && owner.lock = field) owners &&
       not (Hashtbl.mem checked_addresses loc) then
      fail loc "projected lock address escapes a checked transition") addresses
