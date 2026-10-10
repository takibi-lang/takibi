(* Confine raw dereferences, reference mints and unsafe assertions to mint files.
   This is a file boundary, not a proof that a mint's physical claim is true. *)
module Paths = Set.Make (String)

let normalize file =
  if file = Ast.builtin_region_file then file else
  let file = if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file else file in
  let components = String.split_on_char '/' file in
  let reversed = List.fold_left (fun parts -> function
    | "" | "." -> parts
    | ".." -> (match parts with [] -> [] | _ :: rest -> rest)
    | part -> part :: parts) [] components in
  "/" ^ String.concat "/" (List.rev reversed)

(* Inspect parsed source before monomorphization drops dormant templates. *)
let source_assertions program =
  let sites = ref [] in
  let add name loc = sites := (loc, name) :: !sites in
  let rec expr name (e : Ast.expr) =
    let open Ast in
    match e.desc with
    | Unsafe inner -> add name e.loc; expr name inner
    | Call (_, xs) | StructLit xs | TupleLit xs -> List.iter (expr name) xs
    | VariantCtor (_, _, x) | Bnot x | Deref x | AddrOf x
    | Cast (_, x) | FieldGet (x, _) -> expr name x
    | BinOp (_, a, b) | Index (a, b) | Assign (a, b) -> expr name a; expr name b
    | SliceOf (a, b, c) -> expr name a; expr name b; expr name c
    | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _
    | ViewLit _ | EnumVariant _ | SizeOf _ | ContainsStableOwner _
    | AlignOf _ | OffsetOf _ | EmbedFile _ -> ()
  and stmt name (s : Ast.stmt) =
    let open Ast in
    match s.desc with
    | UnsafeBlock body -> add name s.loc; List.iter (stmt name) body
    | Block body -> List.iter (stmt name) body
    | Return x | Let (_, _, _, x, _) -> Option.iter (expr name) x
    | Expr x | Yield x | LetTuple (_, x) | StaticAssert (x, _) -> expr name x
    | If (x, a, b) -> expr name x; List.iter (stmt name) a; List.iter (stmt name) b
    | While (x, body) | ForEach (_, x, body) -> expr name x; List.iter (stmt name) body
    | For (_, _, a, b, body) -> expr name a; expr name b; List.iter (stmt name) body
    | Match (x, arms) | LetMatch (_, _, _, x, arms) -> expr name x; List.iter (arm name) arms
    | Break | Continue -> ()
  and arm name = function
    | Ast.ArmVariant (_, _, _, body) | Ast.ArmWild body
    | Ast.ArmIntLit (_, body) | Ast.ArmByteSliceLit (_, body) -> List.iter (stmt name) body in
  List.iter (function
    | Ast.FuncDef f -> List.iter (stmt f.name) f.body
    | Ast.ConstDef (name, _, x, _) -> expr name x
    | Ast.LetDef (name, _, x, _, _, _, _) -> Option.iter (expr name) x
    | _ -> ()) program;
  !sites

(* GitHub issue #637 stage 3: the built-in that turns an address into a
   byte region is a mint wherever it is called. Its `unsafe` effect makes a
   caller declare it, but a call is not a local unsafe assertion, so it is
   counted here by name. *)
let address_mint_builtins = [ "region_bytes_assume" ]

let address_mint_sites program =
  let sites = ref [] in
  let rec expr name (e : Ast.expr) =
    let open Ast in
    (match e.desc with
     | Call (callee, _) when List.mem callee address_mint_builtins ->
         sites := (e.loc, name) :: !sites
     | _ -> ());
    match e.desc with
    | Unsafe inner -> expr name inner
    | Call (_, xs) | StructLit xs | TupleLit xs -> List.iter (expr name) xs
    | VariantCtor (_, _, x) | Bnot x | Deref x | AddrOf x
    | Cast (_, x) | FieldGet (x, _) -> expr name x
    | BinOp (_, a, b) | Index (a, b) | Assign (a, b) -> expr name a; expr name b
    | SliceOf (a, b, c) -> expr name a; expr name b; expr name c
    | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _
    | ViewLit _ | EnumVariant _ | SizeOf _ | ContainsStableOwner _
    | AlignOf _ | OffsetOf _ | EmbedFile _ -> ()
  and stmt name (s : Ast.stmt) =
    let open Ast in
    match s.desc with
    | UnsafeBlock body | Block body -> List.iter (stmt name) body
    | Return x | Let (_, _, _, x, _) -> Option.iter (expr name) x
    | Expr x | Yield x | LetTuple (_, x) | StaticAssert (x, _) -> expr name x
    | If (x, a, b) -> expr name x; List.iter (stmt name) a; List.iter (stmt name) b
    | While (x, body) | ForEach (_, x, body) -> expr name x; List.iter (stmt name) body
    | For (_, _, a, b, body) -> expr name a; expr name b; List.iter (stmt name) body
    | Match (x, arms) | LetMatch (_, _, _, x, arms) -> expr name x; List.iter (arm name) arms
    | Break | Continue -> ()
  and arm name = function
    | Ast.ArmVariant (_, _, _, body) | Ast.ArmWild body
    | Ast.ArmIntLit (_, body) | Ast.ArmByteSliceLit (_, body) -> List.iter (stmt name) body in
  List.iter (function
    | Ast.FuncDef f -> List.iter (stmt f.name) f.body
    | _ -> ()) program;
  !sites

module Sites = Map.Make (struct
  type t = string * int * int
  let compare = compare
end)

let check ?(source_program = []) ~mint_files () =
  let allowed = List.fold_left (fun paths file -> Paths.add (normalize file) paths)
      Paths.empty mint_files in
  (* Compiler-generated region operations belong to the compiler's explicit
     trusted boundary; their virtual source is not an application mint. *)
  let declared file = file = Ast.builtin_region_file ||
      Paths.mem (normalize file) allowed in
  let raw = Type_inf.raw_deref_sites () |> List.filter_map (fun site ->
    if declared site.Type_inf.raw_file then None else
      Some (Ast.source_loc site.raw_loc, Printf.sprintf
        "raw-authority confinement: raw %s %s in '%s' is outside a declared mint file"
        site.raw_pointer site.raw_form site.raw_function)) in
  let assertions = List.fold_left (fun sites (loc, name) ->
    Sites.add (Ast.source_file_of_loc loc, loc.Lexing.pos_lnum, loc.pos_cnum)
      (loc, name) sites) Sites.empty
      (Type_inf.unsafe_authority_sites () @ source_assertions source_program) in
  let unsafe = Sites.bindings assertions |> List.map snd |> List.filter_map (fun (loc, name) ->
    if declared (Ast.source_file_of_loc loc) then None else
      Some (Ast.source_loc loc, Printf.sprintf
        "raw-authority confinement: local unsafe assertion in '%s' is outside a declared mint file"
        name)) in
  let references = Type_inf.raw_reference_mint_sites () |> List.filter_map (fun (loc, name) ->
    if declared (Ast.source_file_of_loc loc) then None else
      Some (Ast.source_loc loc, Printf.sprintf
        "raw-authority confinement: raw reference mint in '%s' is outside a declared mint file"
        name)) in
  let address_mints = address_mint_sites source_program |> List.filter_map (fun (loc, name) ->
    if declared (Ast.source_file_of_loc loc) then None else
      Some (Ast.source_loc loc, Printf.sprintf
        "raw-authority confinement: an address becomes a region in '%s' outside a declared mint file"
        name)) in
  List.sort_uniq (fun (left, a) (right, b) ->
    compare (Ast.source_file_of_loc left, left.pos_lnum, left.pos_cnum, a)
      (Ast.source_file_of_loc right, right.pos_lnum, right.pos_cnum, b))
      (raw @ unsafe @ references @ address_mints)
