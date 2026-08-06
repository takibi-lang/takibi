(* GitHub issue #207: compile-time monomorphization of `generic struct`
   templates and generic functions (a `fn` with one or more `T: type`
   parameters -- no new grammar needed for those, `type` is just an
   ordinary base_type_expr). Runs as a whole-program AST pass BEFORE
   type_inf.ml/llvm_gen.ml ever see the program, so that 95% of the existing
   checker/codegen pipeline needs zero changes: by the time this pass
   returns, every TypeGenericInst node has either been resolved to an
   ordinary TypeNamed reference to a freshly-generated, fully concrete
   StructDef, or (if its name was never a known generic struct) left
   untouched for type_inf.ml's existing "generics are not implemented yet"
   error to catch, exactly as it does today; and every call to a generic
   function has either been rewritten to call a freshly-generated, fully
   concrete FuncDef under a mangled name, or (if the type argument(s)
   couldn't be inferred) rejected with a clear error right here.

   Approach: a single recursive `transform` walks every type_expr, in one
   pass substituting a template's own type-parameter names (when building a
   concrete instantiation's field/param/body types) and/or resolving
   TypeGenericInst nodes (when rewriting the rest of the program to
   reference a generated struct). The two concerns are combined into one
   traversal rather than duplicated across two, since both need to
   enumerate every type_expr constructor to recurse correctly.

   Generic function calls are resolved by a narrow, deliberately weak
   inference rule (see the approved generics plan): a call's type
   argument(s) are only inferred when every generic-typed value argument is
   a bare `Var name` or `&name`, and `name`'s type is already known from a
   syntactically local, explicit annotation (a parameter or an earlier
   `let`/global with an explicit type) -- a flat symbol-table lookup, not
   real expression-level type inference. This deliberately does not touch
   type_inf.ml's own HM/TVar machinery at all.

   Const generics follow-up: a generic struct/function may also carry plain
   integer VALUE parameters (e.g. `N: usize`), monomorphized (substituted +
   mangled) exactly like a `T: type` parameter is per concrete type --
   `generic_arg` below is the tagged union covering both kinds of concrete
   argument. A generic struct's own field may reference its own not-yet-
   bound value parameter as an array size (`data: [T; N]`), parsed as
   Ast.TypeArraySym (see lib/generic_scope.ml/lib/parser.mly); `transform`'s
   new `~vsubst` resolves this to an ordinary TypeArray once the concrete
   value argument is known, exactly parallel to how `~subst` already
   resolves TypeNamed against a concrete type argument. *)

open Ast

(* One concrete generic argument: a type (`T`) or a plain integer value
   (`N`). *)
type generic_arg = GType of type_expr | GValue of int

(* -- type_expr transformation ---------------------------------------------

   `subst`: template-parameter substitution, e.g. resolving `TypeNamed "T"`
   to a concrete argument type while building one instantiation's
   field/param/return/body types. `None` (the common case, since only a
   template's own body ever contains an unbound parameter name) leaves
   TypeNamed nodes alone.

   `vsubst`: the const-generics counterpart of `subst`, resolving a
   symbolic array-size parameter name (e.g. "N") to its concrete bound int
   while building one instantiation. `None` almost everywhere (only a
   generic struct's own TypeArraySym field, or a generic function's own
   body if it symbolically referenced its value parameter, would ever
   consult this).

   `resolve_inst`: what to do with a (already-recursively-transformed)
   TypeGenericInst node. During collection this just records the request
   and returns the node unchanged; during the final rewrite pass it returns
   TypeNamed of the generated struct's mangled name. *)

let rec transform ~(subst : string -> type_expr option)
                  ~(vsubst : string -> int option)
                  ~(resolve_inst : string -> type_expr list -> type_expr)
                  (t : type_expr) : type_expr =
  let go = transform ~subst ~vsubst ~resolve_inst in
  match t with
  | TypeNamed name ->
      (match subst name with
       | Some t' -> t'
       | None ->
           (* A bare name that isn't a bound TYPE parameter might instead be
              a bound VALUE parameter appearing as a TypeGenericInst
              argument (e.g. the `N` in `*Freelist(T, N)`) -- resolve it to
              a concrete TypeIntLit so args_to_generic/value_arg_of_type_expr
              can read it later, exactly mirroring how `subst` resolves a
              type parameter's name to a concrete type_expr. Const generics
              follow-up to GitHub issue #207. *)
           (match vsubst name with
            | Some v -> TypeIntLit v
            | None -> t))
  | TypeGenericInst (name, args) -> resolve_inst name (List.map go args)
  | TypeIntLit _ -> t
    (* Meaningful only as a TypeGenericInst value-argument; a lone
       TypeIntLit has no sub-structure to transform, so it just passes
       through -- resolve_inst's caller (collect_resolve/apply_resolve, in
       `run` below) is what actually reads its value. *)
  | TypeArraySym (t, sz) ->
      let elem = go t in
      (match eval_size vsubst sz with
       | Some n -> TypeArray (elem, n)
       | None -> raise (Types.TypeError (Lexing.dummy_pos,
           "BUG: an unresolved symbolic array size escaped monomorphization")))
  | TypeSliceSym (t, sz) ->
      let elem = go t in
      (match eval_size vsubst sz with
       | Some n -> TypeSlice (elem, n)
       | None -> raise (Types.TypeError (Lexing.dummy_pos,
           "BUG: an unresolved symbolic slice minimum escaped monomorphization")))
  | TypePtr t -> TypePtr (go t)
  | TypeIo t -> TypeIo (go t)
  | TypeArray (t, n) -> TypeArray (go t, n)
  | TypeSlice (t, n) -> TypeSlice (go t, n)
  | TypeFn (ps, r, eff) -> TypeFn (List.map go ps, go r, eff)
  | TypeTuple ts -> TypeTuple (List.map go ts)
  | TypeBorrow t -> TypeBorrow (go t)
  | TypeBorrowMut t -> TypeBorrowMut (go t)
  | TypeSink t -> TypeSink (go t)
  | TypeAlignedPtr (n, t) -> TypeAlignedPtr (n, go t)
  | TypeSingleton (t, arg) -> TypeSingleton (go t, arg)
  | TypeExists (n, sort, body) -> TypeExists (n, sort, go body)
  | TypeRefined (lo, hi, base) -> TypeRefined (lo, hi, go base)
  (* TypeIndexed's arguments are static_arg (erased values), not types --
     nothing under it can ever be a type parameter or a generic
     instantiation. TypeBool/int primitives/TypeVoid/TypeView/TypeVariant/
     TypeKind have no sub-type_expr at all. *)
  | TypeIndexed _ | TypeBool
  | TypeI8 | TypeI16 | TypeI32 | TypeI64
  | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeU16Be | TypeU32Be
  | TypeIsize | TypeUsize | TypeVoid
  | TypeView _ | TypeVariant _ | TypeKind -> t

(* Evaluate a symbolic array-size expression against a value-parameter
   substitution. Mirrors lib/parser.mly's own array_size arithmetic
   exactly (eager left-to-right evaluation via OCaml's own +/-/*//). *)
and eval_size (vsubst : string -> int option) (sz : array_size_expr) : int option =
  match sz with
  | ASLit n -> Some n
  | ASParam name -> vsubst name
  | ASAdd (a, b) ->
      (match eval_size vsubst a, eval_size vsubst b with
       | Some x, Some y -> Some (x + y) | _ -> None)
  | ASSub (a, b) ->
      (match eval_size vsubst a, eval_size vsubst b with
       | Some x, Some y -> Some (x - y) | _ -> None)
  | ASMul (a, b) ->
      (match eval_size vsubst a, eval_size vsubst b with
       | Some x, Some y -> Some (x * y) | _ -> None)
  | ASDiv (a, b) ->
      (match eval_size vsubst a, eval_size vsubst b with
       | Some x, Some y ->
           if y = 0 then
             raise (Types.TypeError (Lexing.dummy_pos,
               "array size expression: division by zero"))
           else Some (x / y)
       | _ -> None)

let no_subst (_ : string) : type_expr option = None
let no_vsubst (_ : string) : int option = None

(* -- Location relocation ----------------------------------------------------

   Freelist redesign follow-up: a real, confirmed bug, found by
   disassembling an actually-miscompiled binary (the AST itself checked out
   correct at every stage of this file -- only codegen picked the wrong
   target). Every stmt/expr node built while expanding one concrete
   instantiation's body is a structural copy of the TEMPLATE's own nodes
   (transform/walk_stmt/walk_expr preserve `loc` verbatim via `{ e with
   desc }`), so TWO DIFFERENT instantiations of the SAME template (e.g.
   freelist_init$usize$3 and freelist_init$Point$2) end up with IDENTICAL
   Ast.loc values on their corresponding nodes. type_inf.ml's
   resolved_call_targets cache (lib/type_inf.ml:841, populated at Call
   sites, consulted by llvm_gen.ml's own Call codegen in PREFERENCE to the
   AST's own already-correct Call name) is keyed by Types.loc_key, a
   "file:line:col" string -- so a nested generic call inside ONE
   instantiation's body (freelist_core_init(&target.core) inside
   freelist_init$usize$3) can get silently overwritten by a DIFFERENT
   instantiation's resolution at the same source location
   (freelist_init$Point$2's own freelist_core_init$2), and BOTH end up
   codegened calling whichever one was resolved LAST. Fixed by rewriting
   every node's own `loc.pos_fname` to be unique per instantiation (append
   the mangled name) right after a concrete body is built -- keeps
   line/col accurate for diagnostics (a real error still points at the
   actual source line) while making loc_key collision-free. Only
   stmt/expr need this: Ast.type_expr carries no loc field of its own. *)

let relocate_loc (mangled : string) (loc : loc) : loc =
  { loc with Lexing.pos_fname = loc.Lexing.pos_fname ^ "#" ^ mangled }

let rec relocate_expr (mangled : string) (e : expr) : expr =
  let ex = relocate_expr mangled in
  let desc = match e.desc with
    | IntLit _ | BoolLit _ | StringLit _ | Var _ | EnumVariant _ as d -> d
    | ViewLit (name, args) -> ViewLit (name, args)
    | Call (name, args) -> Call (name, List.map ex args)
    | VariantCtor (vname, cname, payload) -> VariantCtor (vname, cname, ex payload)
    | BinOp (op, a, b) -> BinOp (op, ex a, ex b)
    | Bnot a -> Bnot (ex a)
    | Deref a -> Deref (ex a)
    | AddrOf a -> AddrOf (ex a)
    | Cast (t, a) -> Cast (t, ex a)
    | FieldGet (a, f) -> FieldGet (ex a, f)
    | StructLit args -> StructLit (List.map ex args)
    | TupleLit args -> TupleLit (List.map ex args)
    | Index (id, idx) -> Index (id, ex idx)
    | SliceOf (id, lo, hi) -> SliceOf (id, ex lo, ex hi)
    | Unsafe a -> Unsafe (ex a)
    | SizeOf t -> SizeOf t
    | OffsetOf (t, f) -> OffsetOf (t, f)
    | Assign (l, r) -> Assign (ex l, ex r)
  in
  { desc; loc = relocate_loc mangled e.loc }

let rec relocate_stmt (mangled : string) (s : stmt) : stmt =
  let ex = relocate_expr mangled in
  let st = relocate_stmt mangled in
  let sts = List.map st in
  let desc = match s.desc with
    | Return None -> Return None
    | Return (Some e) -> Return (Some (ex e))
    | Expr e -> Expr (ex e)
    | Yield e -> Yield (ex e)
    | Block ss -> Block (sts ss)
    | Let (m, name, ty_opt, e_opt, align_opt) ->
        Let (m, name, ty_opt, Option.map ex e_opt, align_opt)
    | If (c, t, e) -> If (ex c, sts t, sts e)
    | While (c, b) -> While (ex c, sts b)
    | For (name, ty_opt, lo, hi, b) -> For (name, ty_opt, ex lo, ex hi, sts b)
    | ForEach (name, e, b) -> ForEach (name, ex e, sts b)
    | LetTuple (names, e) -> LetTuple (names, ex e)
    | Break -> Break
    | Continue -> Continue
    | Match (e, arms) -> Match (ex e, List.map (relocate_arm mangled) arms)
    | LetMatch (m, name, t_opt, e, arms) ->
        LetMatch (m, name, t_opt, ex e, List.map (relocate_arm mangled) arms)
  in
  { desc; loc = relocate_loc mangled s.loc }

and relocate_arm (mangled : string) (a : match_arm) : match_arm =
  let sts = List.map (relocate_stmt mangled) in
  match a with
  | ArmVariant (v, c, b, ss) -> ArmVariant (v, c, b, sts ss)
  | ArmWild ss -> ArmWild (sts ss)
  | ArmIntLit (ns, ss) -> ArmIntLit (ns, sts ss)

(* -- plain (stateless) expr/stmt/func/toplevel walkers ---------------------

   Only Cast/SizeOf/OffsetOf (expr) and Let/For/LetMatch (stmt) carry a
   type_expr directly; everything else is pure structural recursion so a
   TypeGenericInst buried inside a deeply nested if/while/match still gets
   found and rewritten. Used for the final TypeGenericInst -> TypeNamed
   rewrite pass, where every call site's name has already been fixed up by
   the stateful call-resolving walk below. *)

let rec walk_expr ~subst ~vsubst ~resolve_inst (e : expr) : expr =
  let ty t = transform ~subst ~vsubst ~resolve_inst t in
  let ex e = walk_expr ~subst ~vsubst ~resolve_inst e in
  let desc = match e.desc with
    | IntLit _ | BoolLit _ | StringLit _ | EnumVariant _ as d -> d
    | Var name ->
        (* Freelist redesign follow-up: a generic function's own body may
           reference a bound VALUE parameter as an ordinary runtime
           expression (e.g. `for i: usize in 0..<N { ... }` inside
           freelist_core_init, not just in a type-level array size) --
           resolve it to a concrete IntLit here, mirroring `transform`'s
           own TypeNamed/vsubst resolution exactly. Deliberately NOT
           shadowing-aware (a local variable that happened to be named
           the same as a value-generic-parameter would also get rewritten
           here) -- same class of narrow, documented gap as this file's
           other "deliberately weak inference" limitations; not expected
           to matter in practice since value-generic-parameter names are
           chosen by the struct/function author, not a caller. *)
        (match vsubst name with
         | Some v -> IntLit (Int64.of_int v)
         | None -> Var name)
    | ViewLit (name, args) -> ViewLit (name, args)
    | Call (name, args) -> Call (name, List.map ex args)
    | VariantCtor (vname, cname, payload) -> VariantCtor (vname, cname, ex payload)
    | BinOp (op, a, b) -> BinOp (op, ex a, ex b)
    | Bnot a -> Bnot (ex a)
    | Deref a -> Deref (ex a)
    | AddrOf a -> AddrOf (ex a)
    | Cast (t, a) -> Cast (ty t, ex a)
    | FieldGet (a, f) -> FieldGet (ex a, f)
    | StructLit args -> StructLit (List.map ex args)
    | TupleLit args -> TupleLit (List.map ex args)
    | Index (id, idx) -> Index (id, ex idx)
    | SliceOf (id, lo, hi) -> SliceOf (id, ex lo, ex hi)
    | Unsafe a -> Unsafe (ex a)
    | SizeOf t -> SizeOf (ty t)
    | OffsetOf (t, f) -> OffsetOf (ty t, f)
    | Assign (l, r) -> Assign (ex l, ex r)
  in
  { e with desc }

let rec walk_stmt ~subst ~vsubst ~resolve_inst (s : stmt) : stmt =
  let ty t = transform ~subst ~vsubst ~resolve_inst t in
  let ex e = walk_expr ~subst ~vsubst ~resolve_inst e in
  let st s = walk_stmt ~subst ~vsubst ~resolve_inst s in
  let sts ss = List.map st ss in
  let desc = match s.desc with
    | Return None -> Return None
    | Return (Some e) -> Return (Some (ex e))
    | Expr e -> Expr (ex e)
    | Yield e -> Yield (ex e)
    | Block ss -> Block (sts ss)
    | Let (m, name, ty_opt, e_opt, align_opt) ->
        Let (m, name, Option.map ty ty_opt, Option.map ex e_opt, align_opt)
    | If (c, t, e) -> If (ex c, sts t, sts e)
    | While (c, b) -> While (ex c, sts b)
    | For (name, ty_opt, lo, hi, b) ->
        For (name, Option.map ty ty_opt, ex lo, ex hi, sts b)
    | ForEach (name, e, b) -> ForEach (name, ex e, sts b)
    | LetTuple (names, e) -> LetTuple (names, ex e)
    | Break -> Break
    | Continue -> Continue
    | Match (e, arms) -> Match (ex e, List.map (walk_arm ~subst ~vsubst ~resolve_inst) arms)
    | LetMatch (m, name, t_opt, e, arms) ->
        LetMatch (m, name, Option.map ty t_opt, ex e,
                  List.map (walk_arm ~subst ~vsubst ~resolve_inst) arms)
  in
  { s with desc }

and walk_arm ~subst ~vsubst ~resolve_inst (a : match_arm) : match_arm =
  let sts ss = List.map (walk_stmt ~subst ~vsubst ~resolve_inst) ss in
  match a with
  | ArmVariant (v, c, b, ss) -> ArmVariant (v, c, b, sts ss)
  | ArmWild ss -> ArmWild (sts ss)
  | ArmIntLit (ns, ss) -> ArmIntLit (ns, sts ss)

let walk_func ~subst ~vsubst ~resolve_inst (f : func) : func =
  let ty t = transform ~subst ~vsubst ~resolve_inst t in
  { f with
    params = List.map (fun (n, t) -> (n, Option.map ty t)) f.params;
    ret_type = Option.map ty f.ret_type;
    body = List.map (walk_stmt ~subst ~vsubst ~resolve_inst) f.body }

let walk_toplevel ~subst ~vsubst ~resolve_inst (t : toplevel) : toplevel =
  let ty t = transform ~subst ~vsubst ~resolve_inst t in
  match t with
  | FuncDef f -> FuncDef (walk_func ~subst ~vsubst ~resolve_inst f)
  | ConstDef (n, t, e, l) -> ConstDef (n, ty t, e, l)
  | LetDef (n, t_opt, e_opt, a, m, p, l) ->
      LetDef (n, Option.map ty t_opt, e_opt, a, m, p, l)
  | ExternFuncDef (n, params, r, eff) ->
      ExternFuncDef (n, List.map (fun (pn, pt) -> (pn, Option.map ty pt)) params,
                     Option.map ty r, eff)
  | StructDef (n, fields, packed, align, priv, l) ->
      StructDef (n, List.map (fun (fn, ft) -> (fn, ty ft)) fields, packed, align, priv, l)
  | OwnedStructDef (n, k, sps, fields, packed, align, priv, is_priv, l) ->
      OwnedStructDef (n, k, sps, List.map (fun (fn, ft) -> (fn, ty ft)) fields,
                       packed, align, priv, is_priv, l)
  | ViewDef _ | OpaqueStructDef _ | UseDef _ -> t
  | EnumDef (n, base, vs, ne) -> EnumDef (n, Option.map ty base, vs, ne)
  | VariantDef (n, cases, mu, l) ->
      VariantDef (n, List.map (fun (cn, pt) -> (cn, Option.map ty pt)) cases, mu, l)
  | GenericStructDef _ -> t
  | ExternSymbolDef _ -> t
  | VectorTableDef _ -> t
  | ExceptionEntryDef _ -> t
      (* Handled separately by `run` below (extracted as a template, then
         stripped from the emitted program) -- never walked in place, since
         its own fields reference an unbound type parameter, not a real
         type. *)

(* -- Instantiation naming ----------------------------------------------------

   `mangle_arg`/`mangle`: symbol-safe naming for one concrete instantiation.
   `$` is outside the lexer's IDENT character class (confirmed in
   lib/lexer.mll), so it can never collide with a user-written identifier,
   and LLVM/ARM symbol conventions already permit it (see the approved
   generics plan). V1 only supports primitive/named-struct type arguments;
   anything else is rejected with a clear error rather than silently
   producing a colliding or unreadable mangled name. A value argument (const
   generics follow-up) mangles as its own decimal digits. *)

let rec mangle_arg (t : type_expr) : string =
  match t with
  | TypeNamed s -> s
  | TypeBool -> "bool"
  | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32" | TypeI64 -> "i64"
  | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32" | TypeU64 -> "u64"
  | TypeU16Be -> "u16be" | TypeU32Be -> "u32be"
  | TypeIsize -> "isize" | TypeUsize -> "usize"
  | TypePtr t -> "ptr_" ^ mangle_arg t
  | _ -> raise (Types.TypeError (Lexing.dummy_pos,
      "a generic type argument is not supported yet (only primitive \
       integer types, bool, plain struct names, and plain pointers to \
       those are -- GitHub issue #207)"))

let mangle_generic_arg = function
  | GType t -> mangle_arg t
  | GValue n -> string_of_int n

let mangle (name : string) (args : generic_arg list) : string =
  name ^ String.concat "" (List.map (fun a -> "$" ^ mangle_generic_arg a) args)

(* -- struct templates -------------------------------------------------------- *)

type struct_template = {
  st_params : (string * generic_param_kind) list;
  st_fields : (string * type_expr) list;
  st_is_packed : bool;
  st_align_opt : int option;
  st_private_fields : string list;
}

(* A generic VALUE argument is a bare integer literal (TypeIntLit, from
   e.g. `Freelist(usize, 3)`) or the name of an earlier `const` (from e.g.
   `Freelist(usize, USIZE_POOL_N)`) -- mirrors lib/parser.mly's own
   array_size IDENT-resolution idiom exactly. *)
let value_arg_of_type_expr (t : type_expr) : int =
  match t with
  | TypeIntLit n -> n
  | TypeNamed name ->
      (match Const_env.find name with
       | Some n -> n
       | None -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
           "generic value argument '%s' is not a known compile-time integer \
            constant (declare it earlier as `const %s: T = N;`)" name name)))
  | _ -> raise (Types.TypeError (Lexing.dummy_pos,
      "a generic value argument must be an integer literal or the name of \
       an earlier `const`"))

(* Resolve one already-transformed TypeGenericInst argument list against
   [name]'s own struct template (if known), tagging each position GType or
   GValue per that template's own declared parameter kind. An unknown name
   (not a registered generic struct at all) falls back to treating every
   argument as a type -- exactly today's pre-const-generics behavior,
   preserved so an ordinary (never-generic) name still reaches type_inf.ml's
   own "generics are not implemented yet" error unchanged. An arity
   mismatch is NOT reported here (this runs on every occurrence, including
   speculative ones during collection); it is reported once, with a clear
   message, in expand_pending below. *)
let args_to_generic (struct_templates : (string, struct_template) Hashtbl.t)
    (name : string) (args : type_expr list) : generic_arg list =
  match Hashtbl.find_opt struct_templates name with
  | None -> List.map (fun t -> GType t) args
  | Some tpl ->
      (try
         List.map2 (fun (_, kind) arg -> match kind, arg with
           | GPType, _ -> GType arg
           | GPValue _, (TypeIntLit _ | TypeNamed _) ->
               GValue (value_arg_of_type_expr arg)
           | GPValue _, _ ->
               (* Not even value-argument-SHAPED syntax (e.g. a bare `usize`
                  where a value was expected) -- a genuine kind mismatch,
                  not an unresolved-const error. Keep it tagged GType so
                  expand_pending's own kind-mismatch check reports it with
                  the right message instead of value_arg_of_type_expr's
                  unrelated "not a known compile-time integer constant". *)
               GType arg)
           tpl.st_params args
       with Invalid_argument _ -> List.map (fun t -> GType t) args)

(* -- function templates ------------------------------------------------------

   A generic function is an ordinary `fn` with one or more `T: type`
   parameters, in any position -- no dedicated toplevel grammar was needed
   (unlike `generic struct`) since `type` is just another base_type_expr.
   `fn_type_params` collects the TypeKind-typed parameter names in their own
   relative order; `fn_value_params` is everything else, in ITS relative
   order -- these are the parameters an actual call site supplies (a type
   parameter is never written at a call site, only inferred).

   `fn_value_generic_params` (const generics follow-up): value-parameter
   names this function implicitly generalizes over, discovered structurally
   (not declared) by scanning its own parameter/return types for a
   TypeGenericInst referencing a known generic struct's Value-kinded
   parameter position with a bare, unresolved name -- e.g.
   `freelist_insert(T: type, target: *Freelist(T, N))` discovers `N` from
   `target`'s own type. Bounded, single-pass, purely structural: no HM
   solving, matching this file's own "narrow, deliberately weak inference"
   philosophy. *)

type fn_template = {
  fn_type_params : string list;
  fn_value_generic_params : string list;
  fn_value_params : (string * type_expr) list;
  fn_ret_type : type_expr option;
  fn_effects : ident list option;
  fn_body : stmt list;
  fn_is_inline : bool;
  fn_def_loc : loc;
}

let split_fn_params (params : (ident * type_expr option) list)
    : (string list * (string * type_expr) list) option =
  let is_type_param = List.exists (fun (_, t) -> t = Some TypeKind) params in
  if not is_type_param then None
  else
    let type_params = List.filter_map (fun (n, t) ->
      if t = Some TypeKind then Some n else None) params in
    let value_params = List.filter_map (fun (n, t) ->
      match t with
      | Some TypeKind -> None
      | Some t -> Some (n, t)
      | None -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
          "generic function parameter '%s' needs an explicit type \
           annotation (GitHub issue #207)" n))
    ) params in
    Some (type_params, value_params)

(* Structural scan discovering a generic function's own implicit value
   parameters -- see fn_value_generic_params' own comment above. Must run
   AFTER struct_templates is fully populated (a function may reference a
   generic struct defined later in the same file, per this language's
   otherwise-forward-declaration-free style). *)
let discover_value_generic_params
    (struct_templates : (string, struct_template) Hashtbl.t)
    (type_params : string list)
    (params : (ident * type_expr option) list)
    (ret_type : type_expr option) : string list =
  let found : (string, unit) Hashtbl.t = Hashtbl.create 2 in
  let order = ref [] in
  let record n =
    if (not (List.mem n type_params)) && (not (Hashtbl.mem found n))
       && Const_env.find n = None
    then begin Hashtbl.replace found n (); order := n :: !order end
  in
  let rec scan_ty (t : type_expr) = match t with
    | TypeGenericInst (sname, args) ->
        (match Hashtbl.find_opt struct_templates sname with
         | Some tpl ->
             (try
                List.iter2 (fun (_, kind) arg -> match kind, arg with
                  | GPValue _, TypeNamed vname -> record vname
                  | GPValue _, _ -> ()
                  | GPType, _ -> scan_ty arg)
                  tpl.st_params args
              with Invalid_argument _ -> List.iter scan_ty args)
         | None -> List.iter scan_ty args)
    | TypePtr t | TypeIo t | TypeBorrow t | TypeBorrowMut t | TypeSink t
    | TypeAlignedPtr (_, t) -> scan_ty t
    | TypeArray (t, _) | TypeSlice (t, _)
    | TypeArraySym (t, _) | TypeSliceSym (t, _) -> scan_ty t
    | TypeFn (ps, r, _) -> List.iter scan_ty ps; scan_ty r
    | TypeTuple ts -> List.iter scan_ty ts
    | TypeSingleton (t, _) -> scan_ty t
    | TypeExists (_, _, body) -> scan_ty body
    | TypeRefined (_, _, base) -> scan_ty base
    | TypeNamed _ | TypeIndexed _ | TypeBool | TypeIntLit _
    | TypeI8 | TypeI16 | TypeI32 | TypeI64
    | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeU16Be | TypeU32Be
    | TypeIsize | TypeUsize | TypeVoid
    | TypeView _ | TypeVariant _ | TypeKind -> ()
  in
  List.iter (fun (_, t_opt) -> Option.iter scan_ty t_opt) params;
  Option.iter scan_ty ret_type;
  List.rev !order

(* -- narrow type-argument inference ------------------------------------------

   Deliberately weak by design (see this file's header comment and the
   approved generics plan): only a bare `Var name` or `&name` argument
   participates, and only when `name`'s type is already known from a
   syntactically local, explicit annotation. Unifying the derived concrete
   type against the template's declared (possibly type-parameter-
   referencing) parameter type is a structural walk that binds a type
   parameter wherever it appears and simply contributes nothing on a
   structural mismatch (a real type mismatch is type_inf.ml's job to catch
   on the resolved call, not this pass's).

   Const generics follow-up: the same walk also binds a VALUE parameter
   (e.g. `N` in `*Freelist(T, N)`) wherever it appears as a bare name in
   the template's own declared type, resolving the caller's corresponding
   occurrence via value_arg_of_type_expr (an int literal or `const`
   name) -- reached automatically through the pre-existing
   TypeGenericInst/TypeGenericInst case below, which needed no change at
   all: recursing into nested args lands on this new case by itself. *)

let rec unify_arg (type_params : string list) (value_params : string list)
                  (bindings : (string, type_expr) Hashtbl.t)
                  (value_bindings : (string, int) Hashtbl.t)
                  (template_ty : type_expr) (concrete_ty : type_expr) : unit =
  let u = unify_arg type_params value_params bindings value_bindings in
  match template_ty, concrete_ty with
  | TypeNamed n, _ when List.mem n type_params ->
      (match Hashtbl.find_opt bindings n with
       | Some existing when existing <> concrete_ty ->
           raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
             "conflicting inference for generic type parameter '%s'" n))
       | _ -> Hashtbl.replace bindings n concrete_ty)
  | TypeNamed n, _ when List.mem n value_params ->
      (match (try Some (value_arg_of_type_expr concrete_ty) with Types.TypeError _ -> None) with
       | None -> () (* not a resolvable value in this position; contributes nothing here *)
       | Some v ->
           (match Hashtbl.find_opt value_bindings n with
            | Some existing when existing <> v ->
                raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                  "conflicting inference for generic value parameter '%s'" n))
            | _ -> Hashtbl.replace value_bindings n v))
  | TypePtr a, TypePtr b -> u a b
  | TypeIo a, TypeIo b -> u a b
  | TypeBorrow a, b | TypeBorrowMut a, b | TypeSink a, b -> u a b
  | a, TypeBorrow b | a, TypeBorrowMut b | a, TypeSink b -> u a b
  | TypeArray (a, _), TypeArray (b, _) -> u a b
  | TypeSlice (a, _), TypeSlice (b, _) -> u a b
  | TypeAlignedPtr (_, a), TypeAlignedPtr (_, b) -> u a b
  | TypeGenericInst (n1, args1), TypeGenericInst (n2, args2)
    when n1 = n2 && List.length args1 = List.length args2 ->
      List.iter2 u args1 args2
  | _ -> () (* structural mismatch: contributes nothing, not an error here *)

(* -- run ---------------------------------------------------------------------

   Order of operations:
   1. Collect struct templates, then (now that every struct template is
      known) function templates, including each function's implicit value-
      generic-parameter discovery.
   2. Discover struct-instantiation requests from the non-template part of
      the program (TypeGenericInst occurrences).
   3. Discover and resolve generic-function calls in the SAME non-template
      code, tracking local types per function as it walks statement order;
      each resolved call is rewritten to its mangled name immediately
      (inference completes synchronously per call site), and substituting
      the template's own params/ret/body can introduce NEW struct requests,
      fed back into the same request table.
   4. Fixpoint-expand every struct request (a generated struct's fields can
      themselves introduce further nested requests).
   5. Finalize: register every generated struct with Type_layout and fully
      resolve every generated function's substituted types against the now-
      complete request table.
   6. Rewrite the remaining (non-template) program's own TypeGenericInst
      occurrences (call names were already fixed in step 3). *)

let run (prog : toplevel list) : toplevel list =
  let struct_templates : (string, struct_template) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | GenericStructDef (name, tps, fields, packed, align, priv, _loc) ->
        if Hashtbl.mem struct_templates name then
          raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
            "'%s' is already defined as a generic struct" name));
        Hashtbl.replace struct_templates name
          { st_params = tps; st_fields = fields; st_is_packed = packed;
            st_align_opt = align; st_private_fields = priv }
    | _ -> ()
  ) prog;

  let fn_templates : (string, fn_template) Hashtbl.t = Hashtbl.create 8 in
  let register_fn_template f type_params value_params =
    if Hashtbl.mem fn_templates f.name then
      raise (Types.TypeError (f.def_loc, Printf.sprintf
        "'%s' is already defined as a generic function" f.name));
    let value_generic_params =
      discover_value_generic_params struct_templates type_params
        f.params f.ret_type
    in
    Hashtbl.replace fn_templates f.name
      { fn_type_params = type_params;
        fn_value_generic_params = value_generic_params;
        fn_value_params = value_params;
        fn_ret_type = f.ret_type; fn_effects = f.effects;
        fn_body = f.body; fn_is_inline = f.is_inline;
        fn_def_loc = f.def_loc }
  in
  List.iter (function
    | FuncDef f ->
        (match split_fn_params f.params with
         | Some (type_params, value_params) -> register_fn_template f type_params value_params
         | None ->
             (* No `T: type` parameter -- but the function may still be
                generic purely over a value parameter, discovered
                structurally from its own params/ret_type (e.g.
                freelist_core_init(core: *FreelistCore(N)), Freelist
                redesign follow-up). Registering here needs its own
                value_params derivation (split_fn_params's own, which
                requires an explicit type annotation on every non-type
                param, is skipped entirely in this branch since it never
                got past its own `is_type_param` gate). *)
             let value_generic_params =
               discover_value_generic_params struct_templates [] f.params f.ret_type
             in
             if value_generic_params <> [] then
               let value_params = List.map (fun (n, t) -> match t with
                 | Some t -> (n, t)
                 | None -> raise (Types.TypeError (f.def_loc, Printf.sprintf
                     "generic function parameter '%s' needs an explicit \
                      type annotation (GitHub issue #207)" n))
               ) f.params in
               register_fn_template f [] value_params)
    | _ -> ()
  ) prog;

  if Hashtbl.length struct_templates = 0 && Hashtbl.length fn_templates = 0
  then prog else begin
    (* struct_requests: mangled name -> (template name, concrete args),
       every distinct struct instantiation actually referenced anywhere
       (including inside a generated struct's or function's own body). *)
    let struct_requests : (string, string * generic_arg list) Hashtbl.t = Hashtbl.create 8 in
    let collect_resolve name args =
      let gargs = args_to_generic struct_templates name args in
      let mangled = mangle name gargs in
      if not (Hashtbl.mem struct_requests mangled) then
        Hashtbl.replace struct_requests mangled (name, gargs);
      TypeGenericInst (name, args)
    in

    (* `Var name` / `&name` (unchanged from the original narrow-inference
       design), PLUS `&x.field` (Freelist redesign follow-up): needed for
       a generic function's own body calling ANOTHER generic function via
       a field address, e.g. freelist_core_insert(&target.core) inside
       freelist_insert's own body. Resolves x's own (already-substituted,
       possibly TypeGenericInst-shaped) type via recursion, looks up
       "core"'s DECLARED field type in x's struct TEMPLATE, and
       substitutes that template's own parameter names for x's ACTUAL
       (concrete) type arguments -- one combined `subst` table covers both
       kinds uniformly, since a value argument's binding is already a
       concrete type_expr (TypeIntLit) by this point, exactly like a type
       argument's binding is (TypeNamed "usize"), so transform's existing
       TypeNamed/subst path resolves either without needing vsubst here at
       all. Deliberately narrow (only ONE field-access level; does not
       recurse into `&x.a.b`) -- matches this whole mechanism's own
       "deliberately weak inference" philosophy. *)
    let derive_arg_type (local_types : (string, type_expr) Hashtbl.t) (e : expr)
        : type_expr option =
      match e.desc with
      | Var name -> Hashtbl.find_opt local_types name
      | AddrOf { desc = Var name; _ } ->
          Option.map (fun t -> TypePtr t) (Hashtbl.find_opt local_types name)
      | AddrOf { desc = FieldGet ({ desc = Var name; _ }, fname); _ } ->
          (match Hashtbl.find_opt local_types name with
           | Some (TypePtr (TypeGenericInst (sname, args)))
           | Some (TypeGenericInst (sname, args)) ->
               (match Hashtbl.find_opt struct_templates sname with
                | Some tpl ->
                    (match List.assoc_opt fname tpl.st_fields with
                     | Some field_ty ->
                         let mapping =
                           List.combine (List.map fst tpl.st_params) args in
                         let subst n = List.assoc_opt n mapping in
                         Some (TypePtr (transform ~subst ~vsubst:no_vsubst
                                          ~resolve_inst:collect_resolve field_ty))
                     | None -> None)
                | None -> None)
           | _ -> None)
      | _ -> None
    in

    (* Global symbol table for narrow inference: explicit-type globals and
       consts only (an inferred-from-initializer global is out of scope for
       this deliberately weak V1 rule). *)
    let global_types : (string, type_expr) Hashtbl.t = Hashtbl.create 16 in
    List.iter (function
      | ConstDef (n, t, _, _) -> Hashtbl.replace global_types n t
      | LetDef (n, Some t, _, _, _, _, _) -> Hashtbl.replace global_types n t
      | _ -> ()
    ) prog;

    (* fn_requests: mangled name -> (template name, concrete generic args,
       TYPE args first then VALUE args -- a fixed convention internal to
       this pass, since (unlike a struct instantiation) a function call
       site never spells these positionally; resolve_call below and the
       raw_fns expansion further down both follow this same convention). *)
    let fn_requests : (string, string * generic_arg list) Hashtbl.t = Hashtbl.create 8 in

    let resolve_call (local_types : (string, type_expr) Hashtbl.t)
        (name : string) (args : expr list) : string option =
      match Hashtbl.find_opt fn_templates name with
      | None -> None
      | Some tpl when List.length tpl.fn_value_params <> List.length args -> None
      | Some tpl ->
          let bindings = Hashtbl.create 4 in
          let value_bindings = Hashtbl.create 4 in
          List.iter2 (fun (_, template_ty) arg ->
            match derive_arg_type local_types arg with
            | Some concrete_ty ->
                unify_arg tpl.fn_type_params tpl.fn_value_generic_params
                  bindings value_bindings template_ty concrete_ty
            | None -> ()
          ) tpl.fn_value_params args;
          let concrete_type_args = List.map (fun tp ->
            match Hashtbl.find_opt bindings tp with
            | Some t -> GType t
            | None -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                "cannot infer type parameter '%s' for call to '%s' -- every \
                 argument whose declared type would determine it must be a \
                 plain local variable or global (or its address) with an \
                 explicit type already known at this point in the program \
                 (GitHub issue #207)" tp name))
          ) tpl.fn_type_params in
          let concrete_value_args = List.map (fun vp ->
            match Hashtbl.find_opt value_bindings vp with
            | Some v -> GValue v
            | None -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                "cannot infer generic value parameter '%s' for call to '%s' \
                 -- every argument whose declared type would determine it \
                 must be a plain local variable or global (or its address) \
                 with an explicit type already known at this point in the \
                 program" vp name))
          ) tpl.fn_value_generic_params in
          let concrete_args = concrete_type_args @ concrete_value_args in
          let mangled = mangle name concrete_args in
          if not (Hashtbl.mem fn_requests mangled) then
            Hashtbl.replace fn_requests mangled (name, concrete_args);
          Some mangled
    in

    (* Stateful walk: identical shape to walk_expr/walk_stmt above, except
       it also resolves generic-function calls (mutating local_types as it
       crosses each Let/For in program order) and feeds struct-instantiation
       discovery through collect_resolve for every type_expr it touches. *)
    let rec walk_expr_calls ~subst ~vsubst local_types (e : expr) : expr =
      let ty t = transform ~subst ~vsubst ~resolve_inst:collect_resolve t in
      let ex e = walk_expr_calls ~subst ~vsubst local_types e in
      let desc = match e.desc with
        | IntLit _ | BoolLit _ | StringLit _ | EnumVariant _ as d -> d
        | Var name ->
            (* Same value-generic-parameter substitution as the stateless
               walk_expr (see its own comment) -- needed here too since a
               generic function template's body can reference ITS OWN
               value parameter as an ordinary runtime expression while
               ALSO containing calls to other generic functions (the
               reason this stateful walker variant exists at all). *)
            (match vsubst name with
             | Some v -> IntLit (Int64.of_int v)
             | None -> Var name)
        | ViewLit (name, args) -> ViewLit (name, args)
        | Call (name, args) ->
            let args = List.map ex args in
            (match resolve_call local_types name args with
             | Some mangled -> Call (mangled, args)
             | None -> Call (name, args))
        | VariantCtor (vname, cname, payload) -> VariantCtor (vname, cname, ex payload)
        | BinOp (op, a, b) -> BinOp (op, ex a, ex b)
        | Bnot a -> Bnot (ex a)
        | Deref a -> Deref (ex a)
        | AddrOf a -> AddrOf (ex a)
        | Cast (t, a) -> Cast (ty t, ex a)
        | FieldGet (a, f) -> FieldGet (ex a, f)
        | StructLit args -> StructLit (List.map ex args)
        | TupleLit args -> TupleLit (List.map ex args)
        | Index (id, idx) -> Index (id, ex idx)
        | SliceOf (id, lo, hi) -> SliceOf (id, ex lo, ex hi)
        | Unsafe a -> Unsafe (ex a)
        | SizeOf t -> SizeOf (ty t)
        | OffsetOf (t, f) -> OffsetOf (ty t, f)
        | Assign (l, r) -> Assign (ex l, ex r)
      in
      { e with desc }
    in
    let rec walk_stmt_calls ~subst ~vsubst local_types (s : stmt) : stmt =
      let ty t = transform ~subst ~vsubst ~resolve_inst:collect_resolve t in
      let ex e = walk_expr_calls ~subst ~vsubst local_types e in
      let st s = walk_stmt_calls ~subst ~vsubst local_types s in
      let sts ss = List.map st ss in
      let desc = match s.desc with
        | Return None -> Return None
        | Return (Some e) -> Return (Some (ex e))
        | Expr e -> Expr (ex e)
        | Yield e -> Yield (ex e)
        | Block ss -> Block (sts ss)
        | Let (m, name, ty_opt, e_opt, align_opt) ->
            let ty_opt = Option.map ty ty_opt in
            let e_opt = Option.map ex e_opt in
            (match ty_opt with
             | Some t -> Hashtbl.replace local_types name t
             | None -> Hashtbl.remove local_types name);
            Let (m, name, ty_opt, e_opt, align_opt)
        | If (c, t, e) -> If (ex c, sts t, sts e)
        | While (c, b) -> While (ex c, sts b)
        | For (name, ty_opt, lo, hi, b) ->
            let ty_opt = Option.map ty ty_opt in
            For (name, ty_opt, ex lo, ex hi, sts b)
        | ForEach (name, e, b) -> ForEach (name, ex e, sts b)
        | LetTuple (names, e) -> LetTuple (names, ex e)
        | Break -> Break
        | Continue -> Continue
        | Match (e, arms) -> Match (ex e, List.map (walk_arm_calls ~subst ~vsubst local_types) arms)
        | LetMatch (m, name, t_opt, e, arms) ->
            (* GitHub issue #207: when the annotation is omitted, this
               narrow (non-HM) forward tracker has no way to know the
               type type_inf.ml will later infer from the arms' Yield
               expressions, so -- exactly like an unannotated plain Let
               just above -- it stops tracking `name` here. If a LATER
               generic call in this same body needs `name` specifically
               to determine a type parameter, resolve_call's own existing
               "cannot infer type parameter" error fires (a clear compile
               error, not silent misresolution); it just cannot happen to
               be THIS mechanism that supplies it anymore. *)
            let t_opt = Option.map ty t_opt in
            (match t_opt with
             | Some t -> Hashtbl.replace local_types name t
             | None -> Hashtbl.remove local_types name);
            LetMatch (m, name, t_opt, ex e, List.map (walk_arm_calls ~subst ~vsubst local_types) arms)
      in
      { s with desc }
    and walk_arm_calls ~subst ~vsubst local_types (a : match_arm) : match_arm =
      let sts ss = List.map (walk_stmt_calls ~subst ~vsubst local_types) ss in
      match a with
      | ArmVariant (v, c, b, ss) -> ArmVariant (v, c, b, sts ss)
      | ArmWild ss -> ArmWild (sts ss)
      | ArmIntLit (ns, ss) -> ArmIntLit (ns, sts ss)
    in
    let walk_func_calls (f : func) : func =
      let ty t = transform ~subst:no_subst ~vsubst:no_vsubst ~resolve_inst:collect_resolve t in
      let local_types = Hashtbl.copy global_types in
      List.iter (fun (n, t) -> match t with
        | Some t -> Hashtbl.replace local_types n t
        | None -> ()) f.params;
      { f with
        params = List.map (fun (n, t) -> (n, Option.map ty t)) f.params;
        ret_type = Option.map ty f.ret_type;
        body = List.map (walk_stmt_calls ~subst:no_subst ~vsubst:no_vsubst local_types) f.body }
    in
    let walk_toplevel_calls (t : toplevel) : toplevel =
      let ty t = transform ~subst:no_subst ~vsubst:no_vsubst ~resolve_inst:collect_resolve t in
      match t with
      | FuncDef f -> FuncDef (walk_func_calls f)
      | ConstDef (n, t, e, l) -> ConstDef (n, ty t, e, l)
      | LetDef (n, t_opt, e_opt, a, m, p, l) ->
          LetDef (n, Option.map ty t_opt, e_opt, a, m, p, l)
      | ExternFuncDef (n, params, r, eff) ->
          ExternFuncDef (n, List.map (fun (pn, pt) -> (pn, Option.map ty pt)) params,
                         Option.map ty r, eff)
      | StructDef (n, fields, packed, align, priv, l) ->
          StructDef (n, List.map (fun (fn, ft) -> (fn, ty ft)) fields, packed, align, priv, l)
      | OwnedStructDef (n, k, sps, fields, packed, align, priv, is_priv, l) ->
          OwnedStructDef (n, k, sps, List.map (fun (fn, ft) -> (fn, ty ft)) fields,
                           packed, align, priv, is_priv, l)
      | ViewDef _ | OpaqueStructDef _ | UseDef _ -> t
      | EnumDef (n, base, vs, ne) -> EnumDef (n, Option.map ty base, vs, ne)
      | VariantDef (n, cases, mu, l) ->
          VariantDef (n, List.map (fun (cn, pt) -> (cn, Option.map ty pt)) cases, mu, l)
      | GenericStructDef _ -> t
      | ExternSymbolDef _ -> t
      | VectorTableDef _ -> t
  | ExceptionEntryDef _ -> t
    in

    (* Walk every ordinary (non-template) toplevel for calls, positionally
       aligned with `prog` (None for a template item, which is never
       walked directly -- V1 scope does not follow a generic function
       template's OWN body for calls to further generic functions, see
       this file's header). This also performs struct-request discovery
       simultaneously (every type_expr it touches goes through
       collect_resolve). Positional alignment (rather than filtering
       templates out first) is what lets the final assembly below insert
       each template's generated instantiations at the template's OWN
       original position instead of an arbitrary fixed spot -- see that
       comment for why position matters. *)
    let is_template = function
      | GenericStructDef _ -> true
      | FuncDef f -> Hashtbl.mem fn_templates f.name
          (* Not split_fn_params f.params <> None: that only detects a
             `T: type` parameter, missing a function generic purely over a
             value parameter (e.g. freelist_core_init(core:
             *FreelistCore(N))) -- fn_templates (built above, covering
             both cases) is the single source of truth. *)
      | _ -> false
    in
    let item_calls_processed = List.map (fun item ->
      if is_template item then None else Some (walk_toplevel_calls item)
    ) prog in

    (* Expand every pending function-instantiation request into a
       substituted (but not yet fully TypeGenericInst-free) FuncDef,
       feeding any struct requests the substitution introduces back into
       struct_requests via collect_resolve. New fn_requests cannot appear
       from this step in V1 scope (see header), so one pass suffices.
       Keeps the originating template name alongside each entry so the
       final assembly can group generated functions by which template
       produced them. concrete_args follows fn_requests' own fixed
       convention (type args first, then value args -- see resolve_call). *)
    (* Fixpoint, not a single Hashtbl.iter: a generic function's own body
       may itself call ANOTHER generic function (e.g. freelist_init(T:
       type, target: *Freelist(T, N), ...) calling freelist_core_init
       (core: *FreelistCore(N)), Freelist redesign follow-up -- V1 scope
       previously never followed a template's own body for further
       generic calls at all, see this file's header comment; that gap is
       closed here). walk_stmt_calls/resolve_call (the STATEFUL, call-
       resolving walker, previously only used for the top-level non-
       template walk) discovers such a nested call and adds a NEW
       fn_requests entry -- mutating the very table Hashtbl.iter would be
       iterating, which is unsafe/unspecified in OCaml. A pending-work
       fixpoint (mirroring expand_pending's own shape for struct_requests
       just below) sidesteps that entirely. local_types is seeded from
       global_types plus this ONE instantiation's own already-substituted
       parameter types, exactly like walk_func_calls seeds it for
       ordinary top-level functions. *)
    let raw_fns : (string, string * fn_template * (ident * type_expr) list * type_expr option * stmt list) Hashtbl.t
      = Hashtbl.create 8 in
    let rec expand_pending_fns () =
      let pending = Hashtbl.fold (fun mangled req acc ->
        if Hashtbl.mem raw_fns mangled then acc else (mangled, req) :: acc)
        fn_requests [] in
      if pending <> [] then begin
        List.iter (fun (mangled, (name, gargs)) ->
          match Hashtbl.find_opt fn_templates name with
          | None -> () (* not a known generic function; left for type_inf.ml *)
          | Some tpl ->
              let n_type = List.length tpl.fn_type_params in
              let n_value = List.length tpl.fn_value_generic_params in
              if n_type + n_value <> List.length gargs then
                raise (Types.TypeError (tpl.fn_def_loc, Printf.sprintf
                  "generic function '%s' expects %d argument(s), got %d"
                  name (n_type + n_value) (List.length gargs)));
              let type_gargs = List.filteri (fun i _ -> i < n_type) gargs in
              let value_gargs = List.filteri (fun i _ -> i >= n_type) gargs in
              let type_args = List.map (function
                | GType t -> t
                | GValue _ -> raise (Types.TypeError (tpl.fn_def_loc, Printf.sprintf
                    "generic function '%s': expected a type argument in a type \
                     parameter position" name))) type_gargs in
              let value_args = List.map (function
                | GValue v -> v
                | GType _ -> raise (Types.TypeError (tpl.fn_def_loc, Printf.sprintf
                    "generic function '%s': expected a value argument in a value \
                     parameter position" name))) value_gargs in
              let mapping = List.combine tpl.fn_type_params type_args in
              let vmapping = List.combine tpl.fn_value_generic_params value_args in
              let subst n = List.assoc_opt n mapping in
              let vsubst n = List.assoc_opt n vmapping in
              let ty t = transform ~subst ~vsubst ~resolve_inst:collect_resolve t in
              let params = List.map (fun (n, t) -> (n, ty t)) tpl.fn_value_params in
              let ret_type = Option.map ty tpl.fn_ret_type in
              let local_types = Hashtbl.copy global_types in
              List.iter (fun (n, t) -> Hashtbl.replace local_types n t) params;
              let body = List.map (walk_stmt_calls ~subst ~vsubst local_types) tpl.fn_body in
              (* Relocate every stmt/expr node's own loc to be unique to
                 THIS instantiation (see relocate_stmt's own comment) --
                 without this, two different instantiations of the same
                 template body share identical Ast.loc values (Monomorphize
                 preserves the original template's loc verbatim), which
                 collides in type_inf.ml's loc-keyed resolved_call_targets
                 cache: a nested generic call inside one instantiation's
                 body (e.g. freelist_core_init(&target.core) inside
                 freelist_init$usize$3) got silently overwritten by a
                 DIFFERENT instantiation's resolution at the SAME source
                 location (freelist_init$Point$2's own call to
                 freelist_core_init$2) -- a real, confirmed bug (found by
                 disassembling the actual miscompiled binary, not by
                 inspection: the AST itself was correct at every stage
                 through Monomorphize.run; only llvm_gen.ml's Call codegen,
                 which trusts call_targets over the AST's own already-
                 correct Call name, used the wrong target). *)
              let body = List.map (relocate_stmt mangled) body in
              Hashtbl.replace raw_fns mangled (name, tpl, params, ret_type, body)
        ) pending;
        expand_pending_fns ()
      end
    in
    expand_pending_fns ();

    (* Fixpoint: expanding one struct's field list (or, above, a function's
       params/ret/body) can introduce new TypeGenericInst occurrences (a
       nested instantiation), which must themselves be discovered before
       this pass can finish. raw_fields holds each struct instantiation's
       substituted-but-not-yet-fully-resolved field list until every
       request is known, since Type_layout needs fully concrete field
       types, not a half-resolved intermediate. Also keeps the originating
       template name, same reason as raw_fns above. *)
    let raw_fields : (string, string * struct_template * type_expr list) Hashtbl.t = Hashtbl.create 8 in
    let rec expand_pending () =
      let pending = Hashtbl.fold (fun mangled req acc ->
        if Hashtbl.mem raw_fields mangled then acc else (mangled, req) :: acc)
        struct_requests [] in
      if pending <> [] then begin
        List.iter (fun (mangled, (name, gargs)) ->
          match Hashtbl.find_opt struct_templates name with
          | None -> () (* not a known generic struct; left for type_inf.ml *)
          | Some tpl ->
              if List.length tpl.st_params <> List.length gargs then
                raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                  "generic struct '%s' expects %d argument(s), got %d"
                  name (List.length tpl.st_params) (List.length gargs)));
              let mapping = List.combine tpl.st_params gargs in
              List.iter (fun ((pname, kind), arg) -> match kind, arg with
                | GPType, GValue _ -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                    "generic struct '%s': parameter '%s' expects a type, \
                     got a value" name pname))
                | GPValue _, GType _ -> raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                    "generic struct '%s': parameter '%s' expects a value, \
                     got a type" name pname))
                | _ -> ()
              ) mapping;
              let type_mapping = List.filter_map (fun ((n, kind), arg) ->
                match kind, arg with
                | GPType, GType t -> Some (n, t) | _ -> None) mapping in
              let value_mapping = List.filter_map (fun ((n, kind), arg) ->
                match kind, arg with
                | GPValue _, GValue v -> Some (n, v) | _ -> None) mapping in
              let subst n = List.assoc_opt n type_mapping in
              let vsubst n = List.assoc_opt n value_mapping in
              let substituted = List.map (fun (_, fty) ->
                transform ~subst ~vsubst ~resolve_inst:collect_resolve fty) tpl.st_fields in
              Hashtbl.replace raw_fields mangled (name, tpl, substituted)
        ) pending;
        expand_pending ()
      end
    in
    expand_pending ();

    (* Every request (struct and function) is now known, so TypeGenericInst
       -> TypeNamed resolution is total and stable. Register every
       generated struct with Type_layout (order-independent -- finish_struct
       only stores the field list for later lookup, per lib/type_layout.ml,
       it does not eagerly compute a size) and finish resolving every
       generated function's substituted types. Grouped by originating
       template name (rather than one flat list) so the final assembly can
       insert each template's instantiations at a position at least as late
       as that template's own original position -- llvm_gen.ml's struct
       registration (`register_struct`/`register_struct_if`,
       lib/llvm_gen.ml ~5041-5109) walks `prog` in a SINGLE LINEAR PASS,
       SEPARATELY from and strictly before any global/function codegen,
       calling `ltype_of_ast` on every field immediately: a struct embedding
       another struct BY VALUE must have that other struct's LLVM type
       already registered, so a generated struct placed before an ordinary
       struct it depends on (e.g. `Freelist(T, N)`'s `core: FreelistCore`
       field, with FreelistCore defined earlier in ordinary code) would
       fail with "Unknown named type" -- confirmed by hitting exactly that
       error before this positional-insertion design.

       Const generics follow-up: embedding `data: [T; N]` (a genuine
       by-value array, unlike the original design's `data: []T` fat-
       pointer slice, which never needed T's own layout registered ahead of
       time) introduced a NEW way this can fail: T itself may be an
       ordinary struct defined LATER than the generic template (e.g.
       `Freelist(Point, 2)` where `Point` is declared after `use`-ing the
       file the template lives in) -- the template's own textual position
       is no longer always a safe insertion point. Fixed by computing, per
       template, the LATEST position among (the template's own position)
       and (every by-value-embedded ordinary struct name across ALL of its
       generated instantiations' field types) and inserting there instead
       -- struct registration doesn't care about position relative to
       globals/functions (a separate, later pass), only position relative
       to OTHER structs, so moving a generated struct's slot later within
       `prog` is always safe as long as it's still before anything that
       embeds IT by value in turn (the same discipline ordinary,
       non-generic struct definitions already require today). *)
    let apply_resolve name args =
      let gargs = args_to_generic struct_templates name args in
      TypeNamed (mangle name gargs)
    in
    let resolve_ty t = transform ~subst:no_subst ~vsubst:no_vsubst ~resolve_inst:apply_resolve t in

    let struct_by_template_name : (string, toplevel list) Hashtbl.t = Hashtbl.create 8 in
    Hashtbl.iter (fun mangled (name, tpl, raw) ->
      let field_names = List.map fst tpl.st_fields in
      let fields = List.combine field_names (List.map resolve_ty raw) in
      Type_layout.finish_struct mangled fields tpl.st_is_packed tpl.st_align_opt;
      let def = StructDef (mangled, fields, tpl.st_is_packed, tpl.st_align_opt,
                            tpl.st_private_fields, Lexing.dummy_pos) in
      let prev = Option.value (Hashtbl.find_opt struct_by_template_name name) ~default:[] in
      Hashtbl.replace struct_by_template_name name (def :: prev)
    ) raw_fields;

    let fn_by_template_name : (string, toplevel list) Hashtbl.t = Hashtbl.create 8 in
    Hashtbl.iter (fun mangled (name, tpl, params, ret_type, body) ->
      let params = List.map (fun (n, t) -> (n, Some (resolve_ty t))) params in
      let ret_type = Option.map resolve_ty ret_type in
      let body = List.map (walk_stmt ~subst:no_subst ~vsubst:no_vsubst ~resolve_inst:apply_resolve) body in
      let def = FuncDef { name = mangled; params; ret_type; effects = tpl.fn_effects;
                          body; is_inline = tpl.fn_is_inline; def_loc = tpl.fn_def_loc } in
      let prev = Option.value (Hashtbl.find_opt fn_by_template_name name) ~default:[] in
      Hashtbl.replace fn_by_template_name name (def :: prev)
    ) raw_fns;

    (* Names of ordinary (non-generic) struct-like types a field's type
       embeds BY VALUE -- pointers/slices/borrow/sink don't need the
       pointee's LLVM type registered ahead of time, so they're excluded. *)
    let rec value_deps (t : type_expr) : string list = match t with
      | TypeNamed s -> [s]
      | TypeArray (t, _) -> value_deps t
      | TypeTuple ts -> List.concat_map value_deps ts
      | TypeSingleton (t, _) -> value_deps t
      | _ -> []
    in
    let prog_arr = Array.of_list prog in
    let n = Array.length prog_arr in
    let template_own_index : (string, int) Hashtbl.t = Hashtbl.create 8 in
    let struct_name_index : (string, int) Hashtbl.t = Hashtbl.create 8 in
    Array.iteri (fun i item -> match item with
      | GenericStructDef (name, _, _, _, _, _, _) -> Hashtbl.replace template_own_index name i
      | StructDef (name, _, _, _, _, _)
      | OwnedStructDef (name, _, _, _, _, _, _, _, _) -> Hashtbl.replace struct_name_index name i
      | _ -> ()
    ) prog_arr;
    let struct_insertion_index : (string, int) Hashtbl.t = Hashtbl.create 8 in
    Hashtbl.iter (fun template_name generated_items ->
      let own_idx = Option.value (Hashtbl.find_opt template_own_index template_name) ~default:0 in
      let dep_names = List.concat_map (function
        | StructDef (_, fields, _, _, _, _) ->
            List.concat_map (fun (_, t) -> value_deps t) fields
        | _ -> []
      ) generated_items in
      let idx = List.fold_left (fun best dep -> match Hashtbl.find_opt struct_name_index dep with
        | Some i -> max best i | None -> best) own_idx dep_names in
      Hashtbl.replace struct_insertion_index template_name idx
    ) struct_by_template_name;

    let processed_arr = Array.of_list item_calls_processed in
    let out = Array.make n [] in
    Array.iteri (fun i item ->
      out.(i) <- (match item with
        | GenericStructDef _ -> []
            (* Moved to struct_insertion_index's own computed slot below. *)
        | FuncDef f when is_template item ->
            Option.value (Hashtbl.find_opt fn_by_template_name f.name) ~default:[]
        | _ ->
            [walk_toplevel ~subst:no_subst ~vsubst:no_vsubst ~resolve_inst:apply_resolve
               (Option.get processed_arr.(i))])
    ) prog_arr;
    Hashtbl.iter (fun template_name generated_items ->
      let idx = Option.value (Hashtbl.find_opt struct_insertion_index template_name) ~default:0 in
      out.(idx) <- out.(idx) @ generated_items
    ) struct_by_template_name;
    List.concat (Array.to_list out)
  end
