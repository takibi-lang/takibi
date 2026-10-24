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

(* GitHub issue #954: `requires` / `ensures` initialization contracts at a
   function boundary (docs/VERIFICATION_DESIGN.md, SPEC.md "Initialization
   contracts"). The parser records them here under the function's source
   position, like the borrow qualifiers above; Init_flow checks the body
   against them and applies them at every call. *)
type pred =
  | PInit of Ast.expr          (* init(P), init(P[lo..<hi]) *)
  | PTrue

type arm_pat = {
  case : string option;        (* None: the wildcard `_` *)
  bind : string option;        (* payload binder, `Read(r)` *)
}

type cbody =
  | CPlain of pred
  | CIf of Ast.expr * pred     (* `init(..) if (cond)`, cond over result *)
  | CMatch of (arm_pat * pred) list   (* `match result { ... }` *)

type clause = { requires : bool; body : cbody; cloc : Ast.loc }

let contracts : (string * int * int, clause list) Hashtbl.t = Hashtbl.create 16


let reset () =
  pending := [];
  Hashtbl.reset params;
  Hashtbl.reset scratch;
  Hashtbl.reset contracts

let mark (ty : Ast.type_expr) (q : qual) =
  pending := (ty, q) :: !pending;
  ty

let loc_key (loc : Ast.loc) =
  (Ast.source_file_of_loc loc, loc.Lexing.pos_lnum,
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

(* An unsafe region whose only content is assume_init calls asserts an init
   state, not raw authority: it forges no address, reference or handle. Raw
   authority confinement (Raw_authority_policy) therefore does not count it
   as a local unsafe assertion; TRUSTED_BASE.md lists the assume_init sites
   instead. *)
let assume_init_only_expr (e : Ast.expr) =
  match e.desc with
  | Ast.Call ("assume_init", [_]) -> true
  | _ -> false

let assume_init_only_stmts (ss : Ast.stmt list) =
  ss <> [] && List.for_all (fun (s : Ast.stmt) ->
    match s.desc with
    | Ast.Expr e -> assume_init_only_expr e
    | _ -> false) ss


let set_contracts (def_loc : Ast.loc) (cs : clause list) =
  if cs <> [] then begin
    let (file, line, col) = loc_key def_loc in
    Hashtbl.replace contracts (file, line, col) cs
  end

let contracts_of (def_loc : Ast.loc) : clause list =
  let (file, line, col) = loc_key def_loc in
  match Hashtbl.find_opt contracts (file, line, col) with
  | Some cs -> cs | None -> []
