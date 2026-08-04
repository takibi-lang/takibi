(* GitHub issue #207: compile-time monomorphization of `generic struct`
   templates (Stage 1, struct instantiation only -- generic functions are a
   later build-order step). Runs as a whole-program AST pass BEFORE
   type_inf.ml/llvm_gen.ml ever see the program, so that 95% of the existing
   checker/codegen pipeline needs zero changes: by the time this pass
   returns, every TypeGenericInst node has either been resolved to an
   ordinary TypeNamed reference to a freshly-generated, fully concrete
   StructDef, or (if its name was never a known generic struct) left
   untouched for type_inf.ml's existing "generics are not implemented yet"
   error to catch, exactly as it does today.

   Approach: a single recursive `transform` walks every type_expr, in one
   pass substituting a template's own type-parameter names (when building a
   concrete instantiation's field list) and/or resolving TypeGenericInst
   nodes (when rewriting the rest of the program to reference the generated
   struct). The two concerns are combined into one traversal rather than
   duplicated across two, since both need to enumerate every type_expr
   constructor to recurse correctly, and keeping that enumeration in one
   place is less error-prone than keeping two in sync. *)

open Ast

(* -- type_expr transformation ---------------------------------------------

   `subst`: template-parameter substitution, e.g. resolving `TypeNamed "T"`
   to a concrete argument type while building one instantiation's field
   list. `None` (the common case, since only a template's own body ever
   contains an unbound parameter name) leaves TypeNamed nodes alone.

   `resolve_inst`: what to do with a (already-recursively-transformed)
   TypeGenericInst node. During collection this just records the request
   and returns the node unchanged; during the final rewrite pass it returns
   TypeNamed of the generated struct's mangled name. *)

let rec transform ~(subst : string -> type_expr option)
                  ~(resolve_inst : string -> type_expr list -> type_expr)
                  (t : type_expr) : type_expr =
  let go = transform ~subst ~resolve_inst in
  match t with
  | TypeNamed name -> (match subst name with Some t' -> t' | None -> t)
  | TypeGenericInst (name, args) -> resolve_inst name (List.map go args)
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

let no_subst (_ : string) : type_expr option = None

(* -- expr/stmt/func/toplevel walkers ---------------------------------------

   Only Cast/SizeOf/OffsetOf (expr) and Let/For/LetMatch (stmt) carry a
   type_expr directly; everything else is pure structural recursion so a
   TypeGenericInst buried inside a deeply nested if/while/match still gets
   found and rewritten. This mirrors the small, enumerable set of
   type_expr-bearing AST positions (confirmed by grep across ast.ml) rather
   than threading a generic "traverse everything" library through the
   codebase for a single, narrow use. *)

let rec walk_expr ~subst ~resolve_inst (e : expr) : expr =
  let ty t = transform ~subst ~resolve_inst t in
  let ex e = walk_expr ~subst ~resolve_inst e in
  let desc = match e.desc with
    | IntLit _ | BoolLit _ | StringLit _ | Var _ | EnumVariant _ as d -> d
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

let rec walk_stmt ~subst ~resolve_inst (s : stmt) : stmt =
  let ty t = transform ~subst ~resolve_inst t in
  let ex e = walk_expr ~subst ~resolve_inst e in
  let st s = walk_stmt ~subst ~resolve_inst s in
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
    | Match (e, arms) -> Match (ex e, List.map (walk_arm ~subst ~resolve_inst) arms)
    | LetMatch (m, name, t, e, arms) ->
        LetMatch (m, name, ty t, ex e, List.map (walk_arm ~subst ~resolve_inst) arms)
  in
  { s with desc }

and walk_arm ~subst ~resolve_inst (a : match_arm) : match_arm =
  let sts ss = List.map (walk_stmt ~subst ~resolve_inst) ss in
  match a with
  | ArmVariant (v, c, b, ss) -> ArmVariant (v, c, b, sts ss)
  | ArmWild ss -> ArmWild (sts ss)
  | ArmIntLit (ns, ss) -> ArmIntLit (ns, sts ss)

let walk_func ~subst ~resolve_inst (f : func) : func =
  let ty t = transform ~subst ~resolve_inst t in
  { f with
    params = List.map (fun (n, t) -> (n, Option.map ty t)) f.params;
    ret_type = Option.map ty f.ret_type;
    body = List.map (walk_stmt ~subst ~resolve_inst) f.body }

let walk_toplevel ~subst ~resolve_inst (t : toplevel) : toplevel =
  let ty t = transform ~subst ~resolve_inst t in
  match t with
  | FuncDef f -> FuncDef (walk_func ~subst ~resolve_inst f)
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
      (* Handled separately by `run` below (extracted as a template, then
         stripped from the emitted program) -- never walked in place, since
         its own fields reference an unbound type parameter, not a real
         type. A template referencing ANOTHER generic in its own body
         (e.g. `data: Other(T)`) is not supported in this first build-order
         step. *)

(* -- Instantiation ----------------------------------------------------------

   `mangle_arg`/`mangle`: symbol-safe naming for one concrete instantiation.
   `$` is outside the lexer's IDENT character class (confirmed in
   lib/lexer.mll), so it can never collide with a user-written identifier,
   and LLVM/ARM symbol conventions already permit it (see the approved
   generics plan). V1 only supports primitive/named-struct type arguments;
   anything else is rejected with a clear error rather than silently
   producing a colliding or unreadable mangled name. *)

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

let mangle (name : string) (args : type_expr list) : string =
  name ^ String.concat "" (List.map (fun a -> "$" ^ mangle_arg a) args)

type template = {
  type_params : string list;
  fields : (string * type_expr) list;
  is_packed : bool;
  align_opt : int option;
  private_fields : string list;
}

let run (prog : toplevel list) : toplevel list =
  let templates : (string, template) Hashtbl.t = Hashtbl.create 8 in
  List.iter (function
    | GenericStructDef (name, tps, fields, packed, align, priv, _loc) ->
        if Hashtbl.mem templates name then
          raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
            "'%s' is already defined as a generic struct" name));
        Hashtbl.replace templates name
          { type_params = tps; fields; is_packed = packed;
            align_opt = align; private_fields = priv }
    | _ -> ()
  ) prog;
  if Hashtbl.length templates = 0 then prog else begin
    (* requests: mangled name -> (template name, concrete args), every
       distinct instantiation actually referenced anywhere in the program
       (including, after the first expansion round, inside a generated
       struct's own fields -- e.g. Freelist(Freelist(usize))). Discovered
       by a "collect" pass whose resolve_inst just records what it sees and
       returns the node unchanged (so this pass makes no other change). *)
    let requests : (string, string * type_expr list) Hashtbl.t = Hashtbl.create 8 in
    let collect_resolve name args =
      let mangled = mangle name args in
      if not (Hashtbl.mem requests mangled) then
        Hashtbl.replace requests mangled (name, args);
      TypeGenericInst (name, args)
    in
    let collect_in t = ignore (walk_toplevel ~subst:no_subst ~resolve_inst:collect_resolve t) in
    List.iter collect_in prog;

    (* Fixpoint: expanding one template's field list can introduce new
       TypeGenericInst occurrences (a nested instantiation), which must
       themselves be discovered before this pass can finish. raw_fields
       holds each instantiation's substituted-but-not-yet-fully-resolved
       field list (still possibly containing TypeGenericInst nodes from a
       nested case) until every request is known, since Type_layout needs
       fully concrete field types, not a half-resolved intermediate. *)
    let raw_fields : (string, template * type_expr list list) Hashtbl.t = Hashtbl.create 8 in
    let rec expand_pending () =
      let pending = Hashtbl.fold (fun mangled req acc ->
        if Hashtbl.mem raw_fields mangled then acc else (mangled, req) :: acc)
        requests [] in
      if pending <> [] then begin
        List.iter (fun (mangled, (name, args)) ->
          let tpl = match Hashtbl.find_opt templates name with
            | Some t -> t
            | None ->
                (* Not a known generic struct -- leave unresolved for
                   type_inf.ml's existing "generics are not implemented
                   yet"/undefined-name error to catch downstream; do not
                   fail this pass over a name that may simply be a typo or
                   an ordinary (non-generic) reference. *)
                { type_params = []; fields = []; is_packed = false;
                  align_opt = None; private_fields = [] }
          in
          if tpl.fields <> [] || tpl.type_params <> [] then begin
            if List.length tpl.type_params <> List.length args then
              raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
                "generic struct '%s' expects %d type argument(s), got %d"
                name (List.length tpl.type_params) (List.length args)));
            let mapping = List.combine tpl.type_params args in
            let subst n = List.assoc_opt n mapping in
            let substituted = List.map (fun (_, fty) ->
              transform ~subst ~resolve_inst:collect_resolve fty) tpl.fields in
            Hashtbl.replace raw_fields mangled (tpl, [substituted])
          end
        ) pending;
        expand_pending ()
      end
    in
    expand_pending ();

    (* Every request is now known, so TypeGenericInst -> TypeNamed
       resolution is total and stable: resolve each generated struct's own
       (still possibly nested-generic-bearing) field list against it, then
       register it with Type_layout (order-independent -- finish_struct
       only stores the field list for later lookup, per lib/type_layout.ml,
       it does not eagerly compute a size). *)
    let apply_resolve name args = TypeNamed (mangle name args) in
    let generated = Hashtbl.fold (fun mangled (tpl, fields_rev) acc ->
      let raw_fields = match fields_rev with [f] -> f | _ -> assert false in
      let field_names = List.map fst tpl.fields in
      let resolved_types = List.map
        (transform ~subst:no_subst ~resolve_inst:apply_resolve) raw_fields in
      let fields = List.combine field_names resolved_types in
      Type_layout.finish_struct mangled fields tpl.is_packed tpl.align_opt;
      StructDef (mangled, fields, tpl.is_packed, tpl.align_opt,
                 tpl.private_fields, Lexing.dummy_pos) :: acc
    ) raw_fields [] in

    let rewritten = List.filter_map (function
      | GenericStructDef _ -> None
      | t -> Some (walk_toplevel ~subst:no_subst ~resolve_inst:apply_resolve t)
    ) prog in
    generated @ rewritten
  end
