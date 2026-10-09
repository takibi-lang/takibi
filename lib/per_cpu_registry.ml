(* GitHub issue #704: per-CPU storage. `struct cpu_authority Name { private
   f: {0..<N as usize}; }` is the one current-CPU authority: its field is
   private, so only its declaring file mints one. `struct per_cpu Store
   {...}` is a store type that exists only as a per-CPU global,
   `private let mut g: [Store; N];`, and `g[a]` is the one way to reach an
   element, with `a` an authority value. Declared_type_resolver rewrites
   `g[a]` to `g[a.f]` and records the read here, so the privacy check lets
   that one read through and the checker can insist `a` is the authority. *)

let stores : (string, unit) Hashtbl.t = Hashtbl.create 4
let authority : (string * (string * Ast.type_expr) list) option ref = ref None
let pending_authority : string option ref = ref None
let globals : (string, string) Hashtbl.t = Hashtbl.create 4
let rewritten : (string * int, string) Hashtbl.t = Hashtbl.create 8

let reset () =
  Hashtbl.reset stores;
  authority := None;
  pending_authority := None;
  Hashtbl.reset globals;
  Hashtbl.reset rewritten

let mark_store name = Hashtbl.replace stores name ()
let is_store name = Hashtbl.mem stores name
let mark_authority name = pending_authority := Some name

let finish name fields =
  if !pending_authority = Some name then begin
    pending_authority := None;
    authority := Some (name, fields)
  end

let authority_name () = Option.map fst !authority

(* The authority's one field: its name and the exclusive bound N of its
   `{0..<N as usize}` type, once the checker has validated the shape. *)
let authority_field () =
  match !authority with
  | Some (_, [(field, _)]) -> Some field
  | _ -> None

let loc_key (loc : Ast.loc) = (Ast.source_file_of_loc loc, loc.Lexing.pos_cnum)
let mark_rewritten loc global = Hashtbl.replace rewritten (loc_key loc) global
let rewritten_global loc = Hashtbl.find_opt rewritten (loc_key loc)
