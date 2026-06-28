(* Hindley-Milner type representation with unification variables *)

type ty =
  | TInt
  | TChar
  | TVoid
  | TFun of ty list * ty  (* param types, return type *)
  | TVar of tv ref
  | TPtr of ty            (* *T    — regular pointer, non-volatile *)
  | TIo  of ty            (* io T  — volatile-qualified value type; *io T = TPtr(TIo T) *)
  | TArray of ty * int    (* array type: [T; N] *)
  | TStruct of string     (* named struct type *)
  | TRefinedInt of int * int  (* {lo..<hi} — refined int with known range; lo <= x < hi *)

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
  | TPtr t -> Printf.sprintf "*%s" (to_string t)   (* *io T prints as "*io T" via TPtr(TIo T) *)
  | TIo  t -> Printf.sprintf "io %s" (to_string t)
  | TArray (t, n) -> Printf.sprintf "[%s; %d]" (to_string t) n
  | TFun (ps, r) ->
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map to_string ps)) (to_string r)
  | TStruct s -> s
  | TRefinedInt (lo, hi) -> Printf.sprintf "{%d..<%d}" lo hi
  | TVar { contents = Unbound id } -> Printf.sprintf "'t%d" id
  | TVar { contents = Link _ }     -> assert false

(* ── Unification ─────────────────────────────────────────────────────────── *)

exception Unify_error of string

let rec occurs rv = function
  | TVar { contents = Link t } -> occurs rv t
  | TVar r                     -> r == rv
  | TFun (ps, r)               -> List.exists (occurs rv) ps || occurs rv r
  | TPtr   t                   -> occurs rv t
  | TIo    t                   -> occurs rv t
  | TArray (t, _)              -> occurs rv t
  | TStruct _                  -> false
  | _                          -> false

let rec unify t1 t2 =
  match repr t1, repr t2 with
  | TInt,  TInt  | TChar, TChar | TVoid, TVoid -> ()
  | TPtr t1, TPtr t2 -> unify t1 t2
  | TIo  t1, TIo  t2 -> unify t1 t2
  | TArray (t1, n1), TArray (t2, n2) ->
      if n1 <> n2 then
        raise (Unify_error (Printf.sprintf "array size mismatch: %d vs %d" n1 n2));
      unify t1 t2
  | TFun (ps1, r1), TFun (ps2, r2) ->
      if List.length ps1 <> List.length ps2 then
        raise (Unify_error "argument count mismatch");
      List.iter2 unify ps1 ps2;
      unify r1 r2
  | TRefinedInt (lo1, hi1), TRefinedInt (lo2, hi2) ->
      if lo1 <> lo2 || hi1 <> hi2 then
        raise (Unify_error (Printf.sprintf
          "refined int range mismatch: {%d..<%d} vs {%d..<%d}" lo1 hi1 lo2 hi2))
  (* サブタイピング: TRefinedInt は TInt のサブタイプ（一方向のみ）。
     refined → int: OK（幅広い型への昇格）。
     int → refined: NG（範囲が未証明。if (v >= lo && v < hi) で絞り込んで使う）。 *)
  | TRefinedInt _, TInt -> ()
  | TInt, TRefinedInt (lo, hi) ->
      raise (Unify_error (Printf.sprintf
        "cannot pass unproven int where {%d..<%d} is required; \
         use if (v >= %d && v < %d) { ... } to narrow the range" lo hi lo hi))
  | TStruct s1, TStruct s2 ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "struct type mismatch: %s vs %s" s1 s2))
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

let rec of_ast = function
  | Ast.TypeInt      -> TInt
  | Ast.TypeChar     -> TChar
  | Ast.TypeVoid     -> TVoid
  | Ast.TypePtr   t      -> TPtr   (of_ast t)
  | Ast.TypeIo    t      -> TIo (of_ast t)
  | Ast.TypeArray (t, n) -> TArray (of_ast t, n)
  | Ast.TypeFn (ps, r)   -> TFun (List.map of_ast ps, of_ast r)
  | Ast.TypeNamed s      -> TStruct s
  | Ast.TypeRefined (lo, hi) -> TRefinedInt (lo, hi)

(* None → fresh unification variable *)
let of_ast_opt = function
  | Some t -> of_ast t
  | None   -> fresh ()

(* Return type: None means void; annotation required for non-void returns *)
let ret_of_ast_opt = function
  | Some t -> of_ast t
  | None   -> TVoid

(* After unification, collapse to a concrete Ast type.
   Unbound variables default to int (unconstrained integer) *)
let rec to_ast t =
  match repr t with
  | TInt  -> Ast.TypeInt
  | TChar -> Ast.TypeChar
  | TVoid -> Ast.TypeVoid
  | TPtr   t      -> Ast.TypePtr  (to_ast t)
  | TIo    t      -> Ast.TypeIo   (to_ast t)
  | TArray (t, n) -> Ast.TypeArray (to_ast t, n)
  | TFun (ps, r)  -> Ast.TypeFn (List.map to_ast ps, to_ast r)
  | TStruct s     -> Ast.TypeNamed s
  | TRefinedInt (lo, hi) -> Ast.TypeRefined (lo, hi)
  | TVar { contents = Unbound _ } -> Ast.TypeInt
  | TVar { contents = Link _ }    -> assert false

(* ── Output structs passed to codegen ───────────────────────────────────── *)

module StringMap = Map.Make(String)

type func_info = {
  ret_type    : Ast.type_expr;
  param_types : (string * Ast.type_expr) list;
  local_types : Ast.type_expr StringMap.t;
}

type program_types = {
  globals   : Ast.type_expr StringMap.t;
  functions : func_info StringMap.t;
  structs   : (string * Ast.type_expr) list StringMap.t;
  (* struct name → ordered field list [(field_name, field_type)] *)
}
