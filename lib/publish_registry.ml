(* GitHub issue #299: which struct names were declared `struct publish`,
   and what their fields are.

   This is a leaf module on purpose. It depends on Ast and nothing else,
   because BOTH the type checker and the code generator have to ask these
   questions, and lib/type_inf.ml cannot reach lib/type_layout.ml -- there
   is a real module cycle there (Type_inf -> Type_layout -> Llvm_gen ->
   Type_inf) that lib/type_inf.ml's exception-frame validation already
   works around by re-deriving what it needs from the program instead.
   Re-deriving it a second time here would be two answers to one question,
   so the fact lives somewhere both callers can see it.

   What a publish record MEANS -- the declaration rules, the synthesised
   write token -- is lib/publish_record.ml's, which is free to depend on
   whatever it likes because only the driver calls it. *)

(* Marked when `struct publish Name` is reduced, which happens before the
   field list has been parsed. *)
let pending : (string, unit) Hashtbl.t = Hashtbl.create 8

(* name -> declared fields, in declaration order. *)
let publish_structs : (string, (string * Ast.type_expr) list) Hashtbl.t =
  Hashtbl.create 8

let reset () =
  Hashtbl.reset pending;
  Hashtbl.reset publish_structs

let mark name = Hashtbl.replace pending name ()

(* Called for EVERY struct, from the same parser action that hands the
   fields to Type_layout, so the two tables cannot disagree about what a
   struct's fields are. *)
let finish name fields =
  if Hashtbl.mem pending name then begin
    Hashtbl.replace publish_structs name fields;
    Hashtbl.remove pending name
  end

let is_publish name = Hashtbl.mem publish_structs name

let fields_of name = Hashtbl.find_opt publish_structs name

(* The publication field is the FIRST field, positionally. It is also the
   field at offset 0, which is the address the atomic takes -- a separate
   marker would let those two drift apart and then need a check that they
   had not. lib/publish_record.ml rejects a declaration whose first field
   is not a `usize`, so every caller here can rely on the type. *)
let publication_field name =
  match Hashtbl.find_opt publish_structs name with
  | Some ((fname, _) :: _) -> Some fname
  | _ -> None

let payload_fields name =
  match Hashtbl.find_opt publish_structs name with
  | Some (_ :: rest) -> rest
  | _ -> []

(* `PublishWrite$Record`. The `$` matches lib/monomorphize.ml's mangling
   separator and is unlexable, so a synthesised name can never collide
   with one a program could write, and an error message naming it is
   recognisably compiler-made. *)
let token_prefix = "PublishWrite$"

let token_name record = token_prefix ^ record

let record_of_token name =
  let n = String.length token_prefix in
  if String.length name > n && String.sub name 0 n = token_prefix
  then Some (String.sub name n (String.length name - n))
  else None

let is_token name = record_of_token name <> None
