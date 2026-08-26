(* Resolve the parser's deliberately ambiguous declared-type spellings once,
   after monomorphization and before type inference/codegen inspect the AST.

   `Name[args]` parses as TypeIndexed because the parser cannot yet know
   whether Name denotes an indexed owner struct, an erased view, or an
   indexed variant. A bare Name has the analogous view/variant ambiguity.
   The complete top-level declaration set makes that distinction mechanical:
   views become TypeView, variants become TypeVariant, and actual indexed
   structs remain TypeIndexed.

   Keeping this as a whole-AST pass is the important invariant: downstream
   predicates never need a second interpretation of TypeIndexed based on a
   side table. The pass is idempotent so public compiler phase entry points
   can apply it defensively without changing an already-normalized program. *)

open Ast

module StringSet = Set.Make (String)

type declared_names = {
  views : StringSet.t;
  variants : StringSet.t;
}

exception Noncanonical_type of string

let noncanonical kind name ast_kind =
  raise (Noncanonical_type (Printf.sprintf
    "BUG: unresolved %s declaration '%s' remains %s after Declared_type_resolver.run"
    kind name ast_kind))

let collect_names prog =
  List.fold_left (fun names -> function
    | ViewDef (name, _, _, _, _) ->
        { names with views = StringSet.add name names.views }
    | VariantDef (name, _, _, _, _) ->
        { names with variants = StringSet.add name names.variants }
    | _ -> names
  ) { views = StringSet.empty; variants = StringSet.empty } prog

let rec resolve_type names = function
  | TypeNamed name when StringSet.mem name names.views -> TypeView (name, [])
  | TypeIndexed (name, args) when StringSet.mem name names.views ->
      TypeView (name, args)
  | TypeNamed name when StringSet.mem name names.variants ->
      TypeVariant (name, [])
  | TypeIndexed (name, args) when StringSet.mem name names.variants ->
      TypeVariant (name, args)
  | TypePtr t -> TypePtr (resolve_type names t)
  | TypeIo t -> TypeIo (resolve_type names t)
  | TypeArray (t, n) -> TypeArray (resolve_type names t, n)
  | TypeSlice (t, n) -> TypeSlice (resolve_type names t, n)
  | TypeFn (args, ret, effects) ->
      TypeFn
        (List.map (resolve_type names) args, resolve_type names ret, effects)
  | TypeRefined (lo, hi, base) ->
      TypeRefined (lo, hi, resolve_type names base)
  | TypeBorrow t -> TypeBorrow (resolve_type names t)
  | TypeBorrowMut t -> TypeBorrowMut (resolve_type names t)
  | TypeSink t -> TypeSink (resolve_type names t)
  | TypeRef t -> TypeRef (resolve_type names t)
  | TypeRefMut t -> TypeRefMut (resolve_type names t)
  | TypeAlignedPtr (n, t) -> TypeAlignedPtr (n, resolve_type names t)
  | TypeTuple ts -> TypeTuple (List.map (resolve_type names) ts)
  | TypeSingleton (t, arg) -> TypeSingleton (resolve_type names t, arg)
  | TypeExists (name, sort, body) ->
      TypeExists
        (name, resolve_type names sort, resolve_type names body)
  | TypeGenericInst (name, args) ->
      TypeGenericInst (name, List.map (resolve_type names) args)
  | TypeArraySym (t, size) ->
      TypeArraySym (resolve_type names t, resolve_array_size names size)
  | TypeSliceSym (t, size) ->
      TypeSliceSym (resolve_type names t, resolve_array_size names size)
  | (TypeBool | TypeI8 | TypeI16 | TypeI32 | TypeI64
    | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeU16Be | TypeU32Be
    | TypeIsize | TypeUsize | TypeVoid | TypeNamed _ | TypeIndexed _
    | TypeView _ | TypeVariant _ | TypeKind | TypeIntLit _) as t -> t

and resolve_array_size names = function
  | ASLit _ as size -> size
  | ASParam _ as size -> size
  | ASSizeof t -> ASSizeof (resolve_type names t)
  | ASAdd (a, b) ->
      ASAdd (resolve_array_size names a, resolve_array_size names b)
  | ASSub (a, b) ->
      ASSub (resolve_array_size names a, resolve_array_size names b)
  | ASMul (a, b) ->
      ASMul (resolve_array_size names a, resolve_array_size names b)
  | ASDiv (a, b) ->
      ASDiv (resolve_array_size names a, resolve_array_size names b)

let rec resolve_expr names expr =
  let ex = resolve_expr names in
  let ty = resolve_type names in
  let desc = match expr.desc with
    | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _ | EnumVariant _
    | EmbedFile _ | ViewLit _ as desc -> desc
    | Call (name, args) -> Call (name, List.map ex args)
    | VariantCtor (variant, case, payload) ->
        VariantCtor (variant, case, ex payload)
    | BinOp (op, left, right) -> BinOp (op, ex left, ex right)
    | Bnot e -> Bnot (ex e)
    | Deref e -> Deref (ex e)
    | AddrOf e -> AddrOf (ex e)
    | Cast (t, e) -> Cast (ty t, ex e)
    | FieldGet (e, field) -> FieldGet (ex e, field)
    | StructLit fields -> StructLit (List.map ex fields)
    | TupleLit fields -> TupleLit (List.map ex fields)
    | Index (name, index) -> Index (name, ex index)
    | SliceOf (name, lo, hi) -> SliceOf (name, ex lo, ex hi)
    | Unsafe e -> Unsafe (ex e)
    | SizeOf t -> SizeOf (ty t)
    | AlignOf t -> AlignOf (ty t)
    | ContainsStableOwner t -> ContainsStableOwner (ty t)
    | OffsetOf (t, field) -> OffsetOf (ty t, field)
    | Assign (left, right) -> Assign (ex left, ex right)
  in
  { expr with desc }

let rec resolve_stmt names stmt =
  let ex = resolve_expr names in
  let st = resolve_stmt names in
  let sts = List.map st in
  let ty = resolve_type names in
  let desc = match stmt.desc with
    | Return value -> Return (Option.map ex value)
    | Expr e -> Expr (ex e)
    | Yield e -> Yield (ex e)
    | Block body -> Block (sts body)
    | UnsafeBlock body -> UnsafeBlock (sts body)
    | Let (mut, name, declared, init, align) ->
        Let (mut, name, Option.map ty declared, Option.map ex init, align)
    | If (condition, yes, no) -> If (ex condition, sts yes, sts no)
    | While (condition, body) -> While (ex condition, sts body)
    | For (name, declared, lo, hi, body) ->
        For (name, Option.map ty declared, ex lo, ex hi, sts body)
    | ForEach (name, value, body) -> ForEach (name, ex value, sts body)
    | LetTuple (names, value) -> LetTuple (names, ex value)
    | Break -> Break
    | Continue -> Continue
    | StaticAssert (condition, message) -> StaticAssert (ex condition, message)
    | Match (value, arms) ->
        Match (ex value, List.map (resolve_arm names) arms)
    | LetMatch (mut, name, declared, value, arms) ->
        LetMatch
          (mut, name, Option.map ty declared, ex value,
           List.map (resolve_arm names) arms)
  in
  { stmt with desc }

and resolve_arm names = function
  | ArmVariant (variant, case, binding, body) ->
      ArmVariant
        (variant, case, binding, List.map (resolve_stmt names) body)
  | ArmWild body -> ArmWild (List.map (resolve_stmt names) body)
  | ArmIntLit (values, body) ->
      ArmIntLit (values, List.map (resolve_stmt names) body)
  | ArmByteSliceLit (bytes, body) ->
      ArmByteSliceLit (bytes, List.map (resolve_stmt names) body)

let resolve_static_params names params =
  List.map (fun (name, sort) -> (name, resolve_type names sort)) params

let resolve_func names func =
  let ty = resolve_type names in
  { func with
    params = List.map (fun (name, declared) ->
      (name, Option.map ty declared)) func.params;
    ret_type = Option.map ty func.ret_type;
    body = List.map (resolve_stmt names) func.body }

let resolve_toplevel names = function
  | FuncDef func -> FuncDef (resolve_func names func)
  | ConstDef (name, declared, init, loc) ->
      ConstDef
        (name, resolve_type names declared, resolve_expr names init, loc)
  | LetDef (name, declared, init, align, mut, private_, loc) ->
      LetDef
        (name, Option.map (resolve_type names) declared,
         Option.map (resolve_expr names) init, align, mut, private_, loc)
  | ExternFuncDef (name, params, ret, effects) ->
      ExternFuncDef
        (name,
         List.map (fun (param, declared) ->
           (param, Option.map (resolve_type names) declared)) params,
         Option.map (resolve_type names) ret, effects)
  | StructDef (name, fields, packed, align, private_fields, loc) ->
      StructDef
        (name,
         List.map (fun (field, declared) ->
           (field, resolve_type names declared)) fields,
         packed, align, private_fields, loc)
  | OwnedStructDef
      (name, kind, params, fields, packed, align, private_fields,
       private_, loc) ->
      OwnedStructDef
        (name, kind, resolve_static_params names params,
         List.map (fun (field, declared) ->
           (field, resolve_type names declared)) fields,
         packed, align, private_fields, private_, loc)
  | GenericStructDef
      (name, params, fields, packed, align, private_fields, loc) ->
      let params = List.map (fun (param, kind) -> match kind with
        | GPType -> (param, GPType)
        | GPValue sort -> (param, GPValue (resolve_type names sort))) params in
      GenericStructDef
        (name, params,
         List.map (fun (field, declared) ->
           (field, resolve_type names declared)) fields,
         packed, align, private_fields, loc)
  | ViewDef (name, kind, params, private_, loc) ->
      ViewDef
        (name, kind, resolve_static_params names params, private_, loc)
  | EnumDef (name, base, cases, nonexhaustive) ->
      EnumDef
        (name, Option.map (resolve_type names) base, cases, nonexhaustive)
  | VariantDef (name, params, cases, must_use, loc) ->
      VariantDef
        (name, resolve_static_params names params,
         List.map (fun (case, payload) ->
           (case, Option.map (resolve_type names) payload)) cases,
         must_use, loc)
  | (ExternSymbolDef _ | VectorTableDef _ | ExceptionEntryDef _
    | ExceptionRestoreDef _ | OpaqueStructDef _ | UseDef _) as item -> item

let run prog =
  let names = collect_names prog in
  List.map (resolve_toplevel names) prog

let validate prog =
  let names = collect_names prog in
  let rec check_type = function
    | TypeNamed name when StringSet.mem name names.views ->
        noncanonical "view" name "TypeNamed"
    | TypeIndexed (name, _) when StringSet.mem name names.views ->
        noncanonical "view" name "TypeIndexed"
    | TypeNamed name when StringSet.mem name names.variants ->
        noncanonical "variant" name "TypeNamed"
    | TypeIndexed (name, _) when StringSet.mem name names.variants ->
        noncanonical "variant" name "TypeIndexed"
    | TypePtr t | TypeIo t | TypeArray (t, _) | TypeSlice (t, _)
    | TypeBorrow t | TypeBorrowMut t | TypeSink t | TypeRef t | TypeRefMut t
    | TypeRefined (_, _, t) | TypeAlignedPtr (_, t) | TypeSingleton (t, _) ->
        check_type t
    | TypeFn (args, ret, _) -> List.iter check_type args; check_type ret
    | TypeTuple ts | TypeGenericInst (_, ts) -> List.iter check_type ts
    | TypeExists (_, sort, body) -> check_type sort; check_type body
    | TypeArraySym (t, size) | TypeSliceSym (t, size) ->
        check_type t; check_array_size size
    | TypeBool | TypeI8 | TypeI16 | TypeI32 | TypeI64
    | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeU16Be | TypeU32Be
    | TypeIsize | TypeUsize | TypeVoid | TypeNamed _ | TypeIndexed _
    | TypeView _ | TypeVariant _ | TypeKind | TypeIntLit _ -> ()
  and check_array_size = function
    | ASLit _ | ASParam _ -> ()
    | ASSizeof t -> check_type t
    | ASAdd (a, b) | ASSub (a, b) | ASMul (a, b) | ASDiv (a, b) ->
        check_array_size a; check_array_size b
  in
  let rec check_expr expr =
    match expr.desc with
    | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _ | EnumVariant _
    | EmbedFile _ | ViewLit _ -> ()
    | Call (_, args) | StructLit args | TupleLit args -> List.iter check_expr args
    | VariantCtor (_, _, payload) | Bnot payload | Deref payload
    | AddrOf payload | Unsafe payload -> check_expr payload
    | BinOp (_, left, right) | Assign (left, right) ->
        check_expr left; check_expr right
    | Cast (ty, value) -> check_type ty; check_expr value
    | FieldGet (value, _) -> check_expr value
    | Index (_, index) -> check_expr index
    | SliceOf (_, lo, hi) -> check_expr lo; check_expr hi
    | SizeOf ty | AlignOf ty | ContainsStableOwner ty -> check_type ty
    | OffsetOf (ty, _) -> check_type ty
  in
  let rec check_stmt stmt =
    let check_stmts = List.iter check_stmt in
    match stmt.desc with
    | Return value -> Option.iter check_expr value
    | Expr value | Yield value -> check_expr value
    | Block body | UnsafeBlock body -> check_stmts body
    | Let (_, _, declared, init, _) ->
        Option.iter check_type declared; Option.iter check_expr init
    | If (condition, yes, no) ->
        check_expr condition; check_stmts yes; check_stmts no
    | While (condition, body) -> check_expr condition; check_stmts body
    | For (_, declared, lo, hi, body) ->
        Option.iter check_type declared; check_expr lo; check_expr hi;
        check_stmts body
    | ForEach (_, value, body) -> check_expr value; check_stmts body
    | LetTuple (_, value) -> check_expr value
    | Break | Continue -> ()
    | StaticAssert (condition, _) -> check_expr condition
    | Match (value, arms) -> check_expr value; List.iter check_arm arms
    | LetMatch (_, _, declared, value, arms) ->
        Option.iter check_type declared; check_expr value; List.iter check_arm arms
  and check_arm = function
    | ArmVariant (_, _, _, body) | ArmWild body | ArmIntLit (_, body)
    | ArmByteSliceLit (_, body) ->
        List.iter check_stmt body
  in
  let check_static_params params =
    List.iter (fun (_, sort) -> check_type sort) params in
  let check_func func =
    List.iter (fun (_, ty) -> Option.iter check_type ty) func.params;
    Option.iter check_type func.ret_type;
    List.iter check_stmt func.body
  in
  List.iter (function
    | FuncDef func -> check_func func
    | ConstDef (_, ty, init, _) -> check_type ty; check_expr init
    | LetDef (_, ty, init, _, _, _, _) ->
        Option.iter check_type ty; Option.iter check_expr init
    | ExternFuncDef (_, params, ret, _) ->
        List.iter (fun (_, ty) -> Option.iter check_type ty) params;
        Option.iter check_type ret
    | StructDef (_, fields, _, _, _, _) ->
        List.iter (fun (_, ty) -> check_type ty) fields
    | OwnedStructDef (_, _, params, fields, _, _, _, _, _) ->
        check_static_params params;
        List.iter (fun (_, ty) -> check_type ty) fields
    | GenericStructDef (_, params, fields, _, _, _, _) ->
        List.iter (fun (_, kind) -> match kind with
          | GPType -> () | GPValue sort -> check_type sort) params;
        List.iter (fun (_, ty) -> check_type ty) fields
    | ViewDef (_, _, params, _, _) -> check_static_params params
    | EnumDef (_, base, _, _) -> Option.iter check_type base
    | VariantDef (_, params, cases, _, _) ->
        check_static_params params;
        List.iter (fun (_, payload) -> Option.iter check_type payload) cases
    | ExternSymbolDef _ | VectorTableDef _ | ExceptionEntryDef _
    | ExceptionRestoreDef _ | OpaqueStructDef _ | UseDef _ -> ()) prog
