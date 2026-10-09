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
  | TypeNamed s | TypeIndexed (s, _) -> s
  | TypeVariant (s, _, targs) -> instance_name s targs
  | TypeView (s, _) -> "view_" ^ s
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
  List.rev !defs
