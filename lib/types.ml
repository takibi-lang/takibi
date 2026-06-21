(* Hindley-Milner type representation with unification variables *)

type ty =
  | TInt
  | TChar
  | TVoid
  | TFun of ty list * ty  (* param types, return type *)
  | TVar of tv ref

and tv =
  | Unbound of int  (* unresolved unification variable *)
  | Link    of ty   (* resolved: points to another type *)

(* ── Unification variables ───────────────────────────────────────────────── *)

exception TypeError of Ast.loc * string

let next_id = ref 0

let fresh () =
  incr next_id;
  TVar (ref (Unbound !next_id))

(* Follow Link chains, applying path compression *)
let rec repr = function
  | TVar ({ contents = Link t } as r) ->
      let t' = repr t in r := Link t'; t'
  | t -> t

let rec to_string t =
  match repr t with
  | TInt  -> "int"
  | TChar -> "char"
  | TVoid -> "void"
  | TFun (ps, r) ->
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map to_string ps)) (to_string r)
  | TVar { contents = Unbound id } -> Printf.sprintf "'t%d" id
  | TVar { contents = Link _ }     -> assert false

(* ── Unification ─────────────────────────────────────────────────────────── *)

exception Unify_error of string

let rec occurs rv = function
  | TVar { contents = Link t } -> occurs rv t
  | TVar r                     -> r == rv
  | TFun (ps, r)               -> List.exists (occurs rv) ps || occurs rv r
  | _                          -> false

let rec unify t1 t2 =
  match repr t1, repr t2 with
  | TInt,  TInt  | TChar, TChar | TVoid, TVoid -> ()
  | TFun (ps1, r1), TFun (ps2, r2) ->
      if List.length ps1 <> List.length ps2 then
        raise (Unify_error "argument count mismatch");
      List.iter2 unify ps1 ps2;
      unify r1 r2
  | TVar rv, t | t, TVar rv ->
      (match !rv with
       | Link t' -> unify t' t
       | Unbound _ ->
           if occurs rv t then
             raise (Unify_error (Printf.sprintf
               "infinite type: %s occurs in %s"
               (to_string (TVar rv)) (to_string t)));
           rv := Link t)
  | t1, t2 ->
      raise (Unify_error (Printf.sprintf "cannot unify %s with %s"
        (to_string t1) (to_string t2)))

(* ── Conversion to/from Ast types ───────────────────────────────────────── *)

let of_ast = function
  | Ast.TypeInt  -> TInt
  | Ast.TypeChar -> TChar
  | Ast.TypeVoid -> TVoid

(* None → fresh unification variable *)
let of_ast_opt = function
  | Some t -> of_ast t
  | None   -> fresh ()

(* Return type: None defaults to fresh var (not void) *)
let ret_of_ast_opt = function
  | Some Ast.TypeVoid -> TVoid
  | Some t            -> of_ast t
  | None              -> fresh ()

(* After unification, collapse to a concrete Ast type.
   Unbound variables default to int (unconstrained integer) *)
let to_ast t =
  match repr t with
  | TInt  -> Ast.TypeInt
  | TChar -> Ast.TypeChar
  | TVoid -> Ast.TypeVoid
  | TFun _                        -> Ast.TypeVoid
  | TVar { contents = Unbound _ } -> Ast.TypeInt
  | TVar { contents = Link _ }    -> assert false

(* ── Output structs passed to codegen ───────────────────────────────────── *)

type func_info = {
  ret_type    : Ast.type_expr;
  param_types : (string * Ast.type_expr) list;
  local_types : (string, Ast.type_expr) Hashtbl.t;
}

type program_types = {
  globals   : (string, Ast.type_expr) Hashtbl.t;
  functions : (string, func_info) Hashtbl.t;
}
