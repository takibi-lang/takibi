(* GitHub issue #732: generic variants after type checking.

   The checker keeps a generic variant's instance structurally, as
   TVariant(name, statics, type args). Code generation lays out ordinary
   variants by name, so after checking every instance becomes one ordinary
   VariantDef, named here. The name is derived from the type arguments'
   runtime representation only: statics are erased, so instances that
   differ only in statics (Place(PageOwner[a]) and Place(PageOwner[b]))
   share a layout and a definition. This name is never a type identity --
   the checker has already compared the instances structurally -- it is
   the codegen symbol of a layout, as in Rust's symbol mangling. `$` is
   outside the identifier alphabet, so it cannot collide with a source
   name. *)

open Ast

let rec erased_key (t : type_expr) : string =
  match t with
  (* A view is spelled as a named or indexed type in source and reaches the
     checker as a view: both spellings name the same instance. A view and
     a struct cannot share a name. *)
  | TypeNamed s | TypeIndexed (s, _) | TypeView (s, _) -> s
  | TypeVariant (s, _, targs) -> instance_name s targs
  | TypePtr t -> "ptr_" ^ erased_key t
  | TypeAlignedPtr (n, t) -> Printf.sprintf "ptr%d_%s" n (erased_key t)
  | TypeIo t -> "io_" ^ erased_key t
  | TypeRef t -> "ref_" ^ erased_key t
  | TypeRefMut t -> "refmut_" ^ erased_key t
  | TypeExists (_, _, body) -> erased_key body
  | TypeSingleton (base, _) | TypeRefined (_, _, base) | TypeMultiple (_, base) ->
      erased_key base
  | TypeBorrow t | TypeBorrowMut t | TypeSink t -> erased_key t
  | TypeSlice (t, _, SliceWritable) -> "slice_" ^ erased_key t
  | TypeSlice (t, _, SliceReadonly) -> "cslice_" ^ erased_key t
  | TypeArray (t, n) -> Printf.sprintf "arr%d_%s" n (erased_key t)
  | TypeTuple ts ->
      Printf.sprintf "tup%d_%s" (List.length ts)
        (String.concat "_" (List.map erased_key ts))
  | TypeFn _ -> "fn"
  | TypeBool -> "bool"
  | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32" | TypeI64 -> "i64"
  | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32" | TypeU64 -> "u64"
  | TypeU16Be -> "u16be" | TypeU32Be -> "u32be"
  | TypeIsize -> "isize" | TypeUsize -> "usize"
  | TypeVoid -> "void"
  | TypeGenericInst _ | TypeKind | TypeIntLit _ | TypeArraySym _
  | TypeSliceSym _ ->
      raise (Types.TypeError (Lexing.dummy_pos,
        "BUG: an unresolved type reached generic variant lowering"))

and instance_name (name : string) (targs : type_expr list) : string =
  match targs with
  | [] -> name
  | ts -> name ^ "$" ^ String.concat "$" (List.map erased_key ts)

(* Substitute a generic variant's type parameters in a payload schema. *)
let rec substitute (bindings : (string * type_expr) list) (t : type_expr) =
  let go = substitute bindings in
  match t with
  | TypeNamed s -> (match List.assoc_opt s bindings with Some a -> a | None -> t)
  | TypePtr t -> TypePtr (go t)
  | TypeAlignedPtr (n, t) -> TypeAlignedPtr (n, go t)
  | TypeIo t -> TypeIo (go t)
  | TypeRef t -> TypeRef (go t)
  | TypeRefMut t -> TypeRefMut (go t)
  | TypeArray (t, n) -> TypeArray (go t, n)
  | TypeSlice (t, n, a) -> TypeSlice (go t, n, a)
  | TypeTuple ts -> TypeTuple (List.map go ts)
  | TypeExists (n, sort, body) -> TypeExists (n, sort, go body)
  | TypeVariant (s, args, targs) -> TypeVariant (s, args, List.map go targs)
  | t -> t

(* One ordinary VariantDef per distinct instance, for code generation.
   Instances nested in another's arguments are included. *)
let instance_defs (prog : toplevel list)
    (instances : (string * type_expr list) list) : toplevel list =
  let generics = Hashtbl.create 8 in
  List.iter (function
    | GenericVariantDef (name, tparams, _, cases, must_use, loc) ->
        Hashtbl.replace generics name (tparams, cases, must_use, loc)
    | _ -> ()) prog;
  let made = Hashtbl.create 8 in
  let defs = ref [] in
  let rec add (name, targs) =
    List.iter visit targs;
    match Hashtbl.find_opt generics name with
    | None -> ()
    | Some (tparams, cases, must_use, loc) ->
        let iname = instance_name name targs in
        if not (Hashtbl.mem made iname) then begin
          Hashtbl.replace made iname ();
          if List.length tparams <> List.length targs then
            raise (Types.TypeError (loc, Printf.sprintf
              "variant '%s' expects %d type argument(s), got %d"
              name (List.length tparams) (List.length targs)));
          let bindings = List.combine tparams targs in
          let cases = List.map (fun (c, payload) ->
            (c, Option.map (substitute bindings) payload)) cases in
          defs := VariantDef (iname, [], cases, must_use, loc) :: !defs
        end
  and visit = function
    | TypeVariant (s, _, targs) when targs <> [] -> add (s, targs)
    | TypePtr t | TypeAlignedPtr (_, t) | TypeIo t | TypeRef t | TypeRefMut t
    | TypeArray (t, _) | TypeSlice (t, _, _) | TypeExists (_, _, t)
    | TypeBorrow t | TypeBorrowMut t | TypeSink t -> visit t
    | TypeTuple ts -> List.iter visit ts
    | _ -> ()
  in
  List.iter add instances;
  (* A stored place no code exchanges yet (a fixed DMA record's slot whose
     helpers are unused) still needs its layout: the global holds it. *)
  List.iter (function
    | StructDef (_, fields, _, _, _, _) ->
        List.iter (fun (_, t) -> visit t) fields
    | LetDef (_, Some t, _, _, _, _, _) -> visit t
    | _ -> ()) prog;
  List.rev !defs

(* GitHub issue #131 / #732: the built-in place. A stored slot holding
   nothing or one value; place_take and place_put exchange it under the
   slot's lock and answer what it held before. Zero initialization is
   Empty, the first case. *)
let place_name = "Place"

let place_def =
  GenericVariantDef (place_name, ["T"], [],
    [("Empty", None); ("Full", Some (TypeNamed "T"))], false, Lexing.dummy_pos)

(* `let Place::Empty = place_put(...);` (GitHub issue #131, slice 3): a
   put the checker must prove lands in an empty place, so the displaced
   content needs no arm. The statement stays an ordinary place_put call in
   the tree; its location, recorded here by the parser, is what asks for
   the proof. Keyed by position, which is unique per source file. *)
let proven_empty_puts : (Lexing.position, unit) Hashtbl.t = Hashtbl.create 8
let is_proven_empty_put (e : expr) = Hashtbl.mem proven_empty_puts e.loc

(* Always added, so a program's own `Place` is a duplicate definition. *)
let with_builtins (prog : toplevel list) : toplevel list =
  if List.memq place_def prog then prog else place_def :: prog

(* place_take / place_put as the exchange they are: the replacement is
   Place::Empty or Place::Full(value), located at the call so the checker's
   per-location records agree across passes. The exchange is named with a
   leading '%', which no identifier can spell: it exists only here, and the
   source language has no general exchange (GitHub issue #131). *)
let exchange_prefix = "%"
let exchange_name op = exchange_prefix ^ op
let surface_name name =
  let n = String.length exchange_prefix in
  if String.length name > n && String.sub name 0 n = exchange_prefix
  then String.sub name n (String.length name - n) else name

let place_exchange (e : expr) : expr option =
  match e.desc with
  (* GitHub issue #749: an element of an array of places is a place path.
     The borrowed array is the witness, so there is no guard argument. *)
  | Call ("place_take", [ { desc = Index (arr, i); _ } ]) ->
      Some { e with desc = Call ("__places_take", [arr; i]) }
  | Call ("place_put", [ { desc = Index (arr, i); _ }; value ]) ->
      Some { e with desc = Call ("__places_put", [arr; i; value]) }
  | Call ("place_take", [guard; lock; slot]) ->
      Some { e with desc = Call (exchange_name "place_take",
        [guard; lock; slot; { e with desc = EnumVariant (place_name, "Empty") }]) }
  | Call ("place_put", [guard; lock; slot; value]) ->
      Some { e with desc = Call (exchange_name "place_put",
        [guard; lock; slot; { e with desc = VariantCtor (place_name, "Full", value) }]) }
  (* A place serialized by a global lock its field declares (guarded_by):
     the guard alone names the lock. *)
  | Call ("place_take", [guard; slot]) ->
      Some { e with desc = Call (exchange_name "gplace_take",
        [guard; slot; { e with desc = EnumVariant (place_name, "Empty") }]) }
  | Call ("place_put", [guard; slot; value]) ->
      Some { e with desc = Call (exchange_name "gplace_put",
        [guard; slot; { e with desc = VariantCtor (place_name, "Full", value) }]) }
  | _ -> None

(* GitHub issue #744 (#131's "borrow in place"): `place_borrow(guard, ...)`
   lends a place's content for one match arm without emptying the place:

     match place_borrow(g, c.f) {
         Place::Empty => { A }
         Place::Full(x) => { B }
     }

   is the take and the proven-empty put around that arm,

     match place_take(g, c.f) {
         Place::Empty => { A }
         Place::Full(x) => { B; let Place::Empty = place_put(g, c.f, x); }
     }

   so the existing rules give the borrow its meaning: B cannot consume or
   return past x (the put needs it), cannot hand g to another call (the
   put's empty proof would be lost), and nothing derived from x outlives
   the arm (the put consumes it). Only a match statement takes one. *)
(* The inserted put needs a position of its own (proven_empty_puts and the
   checker's per-location records are keyed by position) that no source
   token has. A negative character offset is one: the line and column are
   kept, so a diagnostic still points at the place_borrow. *)
let borrow_put_loc (loc : Lexing.position) =
  (* The column changes too (Types.loc_key is file, line and column), so
     the inserted call is never confused with the place_borrow's own;
     place_borrow_source_loc undoes it for diagnostics. *)
  { loc with Lexing.pos_cnum = - (loc.Lexing.pos_cnum + 1) }
let is_place_borrow_put (e : expr) = e.loc.Lexing.pos_cnum < 0
let place_borrow_source_loc (loc : Lexing.position) =
  if loc.Lexing.pos_cnum >= 0 then loc
  else { loc with Lexing.pos_cnum = - loc.Lexing.pos_cnum - 1 }

(* The lent element's array is out of reach for the arm: any mention of its
   root variable in the arm is refused. *)
let require_array_unmentioned (arr : expr) (st : stmt) =
  let root = match arr.desc with Var name -> Some name | _ -> None in
  match root with
  | None -> raise (Types.TypeError (arr.loc,
      "place_borrow of an array element needs the array as a bare variable"))
  | Some name ->
      let text = show_stmt st in
      let key = "(Ast.Var \"" ^ name ^ "\")" in
      if Text_search.contains text key then raise (Types.TypeError (st.loc, Printf.sprintf
        "place_borrow lends one element of '%s' for its Full arm; the arm \
         cannot use '%s' until the element is back" name name))

let rec desugar_place_borrow_stmts (stmts : stmt list) : stmt list =
  List.map desugar_place_borrow_stmt stmts

and desugar_place_borrow_arm = function
  | ArmVariant (v, c, p, body) -> ArmVariant (v, c, p, desugar_place_borrow_stmts body)
  | ArmWild body -> ArmWild (desugar_place_borrow_stmts body)
  | ArmMiss body -> ArmMiss (desugar_place_borrow_stmts body)
  | ArmIntLit (ns, body) -> ArmIntLit (ns, desugar_place_borrow_stmts body)
  | ArmByteSliceLit (s, body) -> ArmByteSliceLit (s, desugar_place_borrow_stmts body)

and desugar_place_borrow_stmt (s : stmt) : stmt =
  let d = desugar_place_borrow_stmts in
  match s.desc with
  | Match ({ desc = Call ("place_borrow", [ { desc = Index (arr, i); _ } ]); _ } as scrut, arms) ->
      (* An element lent for one arm: taken, then restored after the arm.
         The arm may not mention the array, so the element stays empty
         until the restore. *)
      let arms = List.map desugar_place_borrow_arm arms in
      let arms = List.map (function
        | ArmVariant (v, "Full", (Some (PayloadBind (x, _)) as p), body)
          when v = place_name ->
            List.iter (fun st -> require_array_unmentioned arr st) body;
            let restore = { s with desc = Expr { loc = borrow_put_loc scrut.loc;
                desc = Call ("__places_restore",
                  [arr; i; { loc = borrow_put_loc scrut.loc; desc = Var x }]) } } in
            ArmVariant (v, "Full", p, body @ [ restore ])
        | arm -> arm) arms in
      { s with desc = Match ({ scrut with desc = Call ("__places_take", [arr; i]) }, arms) }
  | Match ({ desc = Call ("place_borrow", args); _ } as scrut, arms) ->
      let arms = List.map desugar_place_borrow_arm arms in
      let put_loc = borrow_put_loc scrut.loc in
      Hashtbl.replace proven_empty_puts put_loc ();
      let arms = List.map (function
        | ArmVariant (v, "Full", (Some (PayloadBind (x, _)) as p), body)
          when v = place_name ->
            let put = { loc = put_loc;
                        desc = Call ("place_put",
                          args @ [ { scrut with desc = Var x } ]) } in
            ArmVariant (v, "Full", p, body @ [ { s with desc = Expr put } ])
        | arm -> arm) arms in
      { s with desc = Match ({ scrut with desc = Call ("place_take", args) }, arms) }
  | Match (e, arms) -> { s with desc = Match (e, List.map desugar_place_borrow_arm arms) }
  | LetMatch (m, id, t, ({ desc = Call ("place_borrow", args); _ } as scrut), arms) ->
      (* A match that yields a value: the arm's final `yield e` is evaluated
         into a temporary before the put, then yielded. *)
      let arms = List.map desugar_place_borrow_arm arms in
      let put_loc = borrow_put_loc scrut.loc in
      Hashtbl.replace proven_empty_puts put_loc ();
      let arms = List.map (function
        | ArmVariant (v, "Full", (Some (PayloadBind (x, _)) as p), body)
          when v = place_name ->
            let put = { s with desc = Expr { loc = put_loc;
                        desc = Call ("place_put",
                          args @ [ { scrut with desc = Var x } ]) } } in
            let temp = "__place_borrow_value_" ^ x in
            let body = match List.rev body with
              | ({ desc = Yield value; _ } as y) :: rest ->
                  List.rev rest
                  @ [ { y with desc = Let (true, temp, None, Some value, None) };
                      put;
                      { y with desc = Yield { value with desc = Var temp } } ]
              | _ -> body @ [ put ] in
            ArmVariant (v, "Full", p, body)
        | arm -> arm) arms in
      { s with desc = LetMatch (m, id, t,
          { scrut with desc = Call ("place_take", args) }, arms) }
  | LetMatch (m, id, t, e, arms) ->
      { s with desc = LetMatch (m, id, t, e, List.map desugar_place_borrow_arm arms) }
  | Block b -> { s with desc = Block (d b) }
  | UnsafeBlock b -> { s with desc = UnsafeBlock (d b) }
  | If (c, a, b) -> { s with desc = If (c, d a, d b) }
  | While (c, b) -> { s with desc = While (c, d b) }
  | For (i, t, lo, hi, b) -> { s with desc = For (i, t, lo, hi, d b) }
  | ForEach (i, e, b) -> { s with desc = ForEach (i, e, d b) }
  | _ -> s

let desugar_place_borrows (prog : toplevel list) : toplevel list =
  List.map (function
    | FuncDef f -> FuncDef { f with body = desugar_place_borrow_stmts f.body }
    | item -> item) prog
