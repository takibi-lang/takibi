(* GitHub issue #203 (stages 1 and 2): the declarations the definite
   initialization check reads, recorded while parsing.

   - `borrow init T` and `borrow uninit T` parameters. The parser builds an
     ordinary `TypeBorrow T` node and marks it here; when the enclosing
     `fn` is reduced, each marked parameter is recorded under the
     function's source position and parameter name. Keying by source
     position (not by name) survives monomorphization, which renames a
     generic function but keeps its `fn` position in the file part of the
     location (Ast.source_loc removes the instantiation suffix).
   - `scratch let mut g: T;` globals: per-call scratch storage whose
     contents count as uninitialized at the entry of every function.

   The check itself is Type_inf.check_init_flow; SPEC.md "Definite
   initialization" states the rules. *)

type qual = Init | Uninit

let pending : (Ast.type_expr * qual) list ref = ref []
let params : (string * int * int * string, qual) Hashtbl.t = Hashtbl.create 16
let scratch : (string, unit) Hashtbl.t = Hashtbl.create 4

let reset () =
  pending := [];
  Hashtbl.reset params;
  Hashtbl.reset scratch

let mark (ty : Ast.type_expr) (q : qual) =
  pending := (ty, q) :: !pending;
  ty

let loc_key (loc : Ast.loc) =
  let loc = Ast.source_loc loc in
  (loc.Lexing.pos_fname, loc.Lexing.pos_lnum,
   loc.Lexing.pos_cnum - loc.Lexing.pos_bol)

(* Called by the parser when a function definition is reduced: every
   parameter whose type node is one the parser marked gets its qualifier.
   A marked node that is not a parameter's type stays unmatched; `borrow`
   is parameter-only, so the type checker already rejects that position. *)
let finish_func (def_loc : Ast.loc)
    (ps : (Ast.ident * Ast.type_expr option) list) =
  let (file, line, col) = loc_key def_loc in
  List.iter (fun (name, ty) ->
    match ty with
    | Some ty ->
        (match List.find_opt (fun (marked, _) -> marked == ty) !pending with
         | Some (_, q) -> Hashtbl.replace params (file, line, col, name) q
         | None -> ())
    | None -> ()) ps;
  pending := []

let param_qual (def_loc : Ast.loc) (name : string) : qual option =
  let (file, line, col) = loc_key def_loc in
  Hashtbl.find_opt params (file, line, col, name)

let mark_scratch name = Hashtbl.replace scratch name ()
let is_scratch name = Hashtbl.mem scratch name
