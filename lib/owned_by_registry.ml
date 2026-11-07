(* GitHub issue #1159 (option B1): slot-indexed globals.

   `let mut g: [E; N] owned_by(T.f, S);` declares that g's elements are
   split into sets of S consecutive elements, one set per value of the
   field f of the linear token T. The parser records the declaration
   here. Every use of g must be an element access `g[t.f * S + k]` (or
   `g[t.f]` when S is 1), with t a variable whose type is T (owned or
   borrowed) and k proven below S, so a holder of t reaches only its own
   set. That two live tokens never carry the same f is the token's own
   premise (its mint), stated once. The checker (type_inf.ml) enforces the
   rule; Global_protection reports such a global as `slot_owned`. *)

type decl = {
  token : string;          (* T *)
  field : string;          (* f *)
  stride_expr : Ast.expr;  (* S as written: a literal or a const name *)
  decl_loc : Ast.loc;
}

let decls : (string, decl) Hashtbl.t = Hashtbl.create 8

(* The selects `t.f` in an accepted index, by location: the privacy check
   lets exactly these reads of a private f through. *)
let selects : (string * int, unit) Hashtbl.t = Hashtbl.create 32

let reset () =
  Hashtbl.reset decls;
  Hashtbl.reset selects

let note name token field stride_expr decl_loc =
  Hashtbl.replace decls name { token; field; stride_expr; decl_loc }

let find name = Hashtbl.find_opt decls name
let mem name = Hashtbl.mem decls name

let loc_key (loc : Ast.loc) = (Ast.source_file_of_loc loc, loc.Lexing.pos_cnum)
let mark_select loc = Hashtbl.replace selects (loc_key loc) ()
let is_select loc = Hashtbl.mem selects (loc_key loc)

(* The stride's value: an integer literal or a const name. *)
let stride d =
  match d.stride_expr.desc with
  | Ast.IntLit n -> Some (Int64.to_int n)
  | Ast.Var c -> Const_env.find c
  | _ -> None
