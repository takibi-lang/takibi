(* GitHub issue #720 / #637: region backing globals.

   `region let mut g: [T; N];` declares g as the backing storage of a
   region. Recorded while parsing (as Init_state records `scratch`
   globals). Only such a global may be passed to region_of,
   region_table_of or region_table_lock, and its name has no other use in
   the whole program: no read, write, index, slice, address or cast. The
   claim is then the only way to reach the storage, so a claimed region is
   exclusive -- a direct `g[0] = 9` after the claim is rejected. The check
   runs on the whole program (every file), before the claims are lowered
   (Region_builtin.lower); SPEC.md "Region backing globals". *)

let marked : (string, Ast.loc) Hashtbl.t = Hashtbl.create 8

let reset () = Hashtbl.reset marked
let mark name loc = Hashtbl.replace marked name loc
let is_marked name = Hashtbl.mem marked name
let any () = Hashtbl.length marked > 0

let claim_calls = [ "region_of"; "region_table_of"; "region_table_lock" ]

let err loc msg = raise (Types.TypeError (loc, msg))

let use_error loc name =
  err loc (Printf.sprintf
    "'%s' is a region backing global: its storage is reached only through \
     the region its claim returns, so the name has no use besides \
     region_of(%s), region_table_of(%s) or region_table_lock(%s)"
    name name name name)

let rec expr (e : Ast.expr) =
  let open Ast in
  match e.desc with
  | Call (f, [ { desc = Var name; loc } ]) when List.mem f claim_calls ->
      if not (is_marked name) then
        err loc (Printf.sprintf
          "%s needs a region backing global, declared `region let mut %s: \
           [T; N];`; '%s' is not one" f name name)
  | Call (f, _) when List.mem f claim_calls ->
      err e.loc (Printf.sprintf "%s takes the name of a region backing global" f)
  | Var name -> if is_marked name then use_error e.loc name
  | Index (a, i) -> expr a; expr i
  | SliceOf (a, lo, hi) -> expr a; expr lo; expr hi
  | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | EnumVariant _
  | EmbedFile _ | ViewLit _ | SizeOf _ | AlignOf _ | ContainsStableOwner _
  | OffsetOf _ -> ()
  | Call (_, args) | StructLit args | TupleLit args -> List.iter expr args
  | VariantCtor (_, _, a) | Bnot a | Deref a | AddrOf a | Cast (_, a)
  | FieldGet (a, _) | Unsafe a -> expr a
  | BinOp (_, a, b) | Assign (a, b) -> expr a; expr b

and stmt (s : Ast.stmt) =
  let open Ast in
  let local name = if is_marked name then use_error s.loc name in
  match s.desc with
  | Return None | Break | Continue -> ()
  | Return (Some e) | Expr e | Yield e -> expr e
  | StaticAssert (c, _) -> expr c
  | Block ss | UnsafeBlock ss -> stmts ss
  | Let (_, name, _, e, _) -> local name; Option.iter expr e
  | If (c, t, f) -> expr c; stmts t; stmts f
  | While (c, b) -> expr c; stmts b
  | For (name, _, lo, hi, b) -> local name; expr lo; expr hi; stmts b
  | ForEach (name, e, b) -> local name; expr e; stmts b
  | LetTuple (names, e) -> List.iter local names; expr e
  | Match (e, arms) -> expr e; List.iter arm arms
  | LetMatch (_, name, _, e, arms) -> local name; expr e; List.iter arm arms

and stmts ss = List.iter stmt ss

and arm (a : Ast.match_arm) =
  match a with
  | Ast.ArmVariant (_, _, _, ss) | Ast.ArmWild ss | Ast.ArmMiss ss
  | Ast.ArmIntLit (_, ss) | Ast.ArmByteSliceLit (_, ss) -> stmts ss

(* Every marked global is a mutable array of a named or u8 element type
   with no initializer, and every use of its name is a claim. *)
let check (prog : Ast.toplevel list) =
  List.iter (function
    | Ast.LetDef (name, t, init, _, m, _, loc) when is_marked name ->
        (match t, init, m with
         | Some (Ast.TypeArray ((Ast.TypeNamed _ | Ast.TypeU8), _)), None, true -> ()
         | _ -> err loc (Printf.sprintf
             "region backing global '%s' must be `region let mut %s: [T; N];` \
              with a named or u8 element type and no initializer" name name))
    | _ -> ()) prog;
  List.iter (function
    | Ast.FuncDef f
      when Ast.source_file_of_loc f.Ast.def_loc <> Ast.builtin_region_file ->
        (* The compiler's own region definitions name no program global;
           their parameters may share a program global's name. A program
           function may not: a local of that name would hide the global
           from this name-based check. *)
        List.iter (fun (p, _) ->
          if is_marked p then use_error f.Ast.def_loc p) f.Ast.params;
        stmts f.Ast.body
    | Ast.LetDef (_, _, Some e, _, _, _, _) | Ast.ConstDef (_, _, e, _) -> expr e
    | Ast.ExternSymbolDef (name, loc) when is_marked name ->
        use_error loc name
    | Ast.VectorTableDef (entries, loc) ->
        List.iter (fun (_, name) -> if is_marked name then use_error loc name)
          entries
    | _ -> ()) prog
