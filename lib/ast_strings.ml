(* Every string a top-level item holds, read off the AST in the order
   Ast.show_toplevel would print it (GitHub issue #995).

   The region planner (lib/region_builtin.ml) used to print every item and
   scan the text for mangled names, calls and their first variable. Printing
   the kernel was a sixth of its compile, so the planner now reads this list
   instead. Each string comes back escaped as the printer's %S writes it
   (String.escaped, which returns the string itself when nothing needs
   escaping), so a scan of one string sees exactly the characters it saw
   between that string's quotes in the printed text. Two facts of the
   printed text are kept as well:

   - [Comma]: the string is a component of a tuple or of a constructor's
     arguments with another component after it, so the printer wrote a
     comma right after its closing quote. A call is the only place the
     planner asks this (Call (name, args)), but every position is
     classified, so the reading matches the text it replaces.
   - [Var]: the string is the name of an Ast.Var expression.

   Locations are printed as <loc> and hold no string here either. The
   matches below have no wildcard case, so a new AST constructor does not
   compile until it says which of its strings are read. *)

type kind = Plain | Comma | Var

type item = (kind * string) array

let item (top : Ast.toplevel) : item =
  let acc = ref [] in
  let add k s = acc := (k, String.escaped s) :: !acc in
  let plain = add Plain and comma = add Comma in
  let opt f = function None -> () | Some x -> f x in
  let list f l = List.iter f l in
  let rec static_arg = function
    | Ast.StaticName s -> plain s
    | Ast.StaticGlobal (s, _) -> comma s
    | Ast.StaticInt _ -> ()
    | Ast.StaticEnum (a, b) -> comma a; plain b
    | Ast.StaticAdd (a, b) | Ast.StaticSub (a, b) | Ast.StaticMul (a, b) ->
        static_arg a; static_arg b in
  let rec ty = function
    | Ast.TypeBool | Ast.TypeI8 | Ast.TypeI16 | Ast.TypeI32 | Ast.TypeI64
    | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU32 | Ast.TypeU64 | Ast.TypeU16Be
    | Ast.TypeU32Be | Ast.TypeIsize | Ast.TypeUsize | Ast.TypeVoid
    | Ast.TypeKind | Ast.TypeIntLit _ -> ()
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeArray (t, _)
    | Ast.TypeRefined (_, _, t) | Ast.TypeMultiple (_, t)
    | Ast.TypeSlice (t, _, _) | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t | Ast.TypeRef t | Ast.TypeRefMut t
    | Ast.TypeAlignedPtr (_, t) -> ty t
    | Ast.TypeFn (ts, r, effs) -> list ty ts; ty r; opt (list plain) effs
    | Ast.TypeNamed s -> plain s
    | Ast.TypeView (s, args) | Ast.TypeIndexed (s, args) ->
        comma s; list static_arg args
    | Ast.TypeVariant (s, args, ts) ->
        comma s; list static_arg args; list ty ts
    | Ast.TypeExists (id, a, b) -> comma id; ty a; ty b
    | Ast.TypeGenericInst (s, ts) -> comma s; list ty ts
    | Ast.TypeSingleton (t, a) -> ty t; static_arg a
    | Ast.TypeTuple ts -> list ty ts
    | Ast.TypeArraySym (t, sz) | Ast.TypeSliceSym (t, sz) -> ty t; size sz
  and size = function
    | Ast.ASLit _ -> ()
    | Ast.ASParam id -> plain id
    | Ast.ASSizeof t -> ty t
    | Ast.ASAdd (a, b) | Ast.ASSub (a, b) | Ast.ASMul (a, b)
    | Ast.ASDiv (a, b) -> size a; size b in
  let rec expr (e : Ast.expr) = match e.desc with
    | Ast.IntLit _ | Ast.BoolLit _ -> ()
    | Ast.StringLit s | Ast.ByteSliceLit s | Ast.EmbedFile s -> plain s
    | Ast.Var id -> add Var id
    | Ast.ViewLit (id, args) -> comma id; list static_arg args
    | Ast.Call (id, es) -> comma id; list expr es
    | Ast.VariantCtor (a, b, e) -> comma a; comma b; expr e
    | Ast.BinOp (_, a, b) | Ast.Index (a, b) | Ast.Assign (a, b) ->
        expr a; expr b
    | Ast.Bnot e | Ast.Deref e | Ast.AddrOf e | Ast.Unsafe e -> expr e
    | Ast.Cast (t, e) -> ty t; expr e
    | Ast.FieldGet (e, s) -> expr e; plain s
    | Ast.StructLit es | Ast.TupleLit es -> list expr es
    | Ast.SliceOf (a, b, c) -> expr a; expr b; expr c
    | Ast.EnumVariant (a, b) -> comma a; plain b
    | Ast.SizeOf t | Ast.ContainsStableOwner t | Ast.AlignOf t -> ty t
    | Ast.OffsetOf (t, s) -> ty t; plain s in
  let rec stmt (s : Ast.stmt) = match s.desc with
    | Ast.Return eo -> opt expr eo
    | Ast.Expr e | Ast.Yield e -> expr e
    | Ast.Block ss | Ast.UnsafeBlock ss -> list stmt ss
    | Ast.Let (_, id, t, eo, _) -> comma id; opt ty t; opt expr eo
    | Ast.If (e, a, b) -> expr e; list stmt a; list stmt b
    | Ast.While (e, ss) -> expr e; list stmt ss
    | Ast.For (id, t, a, b, ss) ->
        comma id; opt ty t; expr a; expr b; list stmt ss
    | Ast.ForEach (id, e, ss) -> comma id; expr e; list stmt ss
    | Ast.LetTuple (ids, e) -> list plain ids; expr e
    | Ast.Break | Ast.Continue -> ()
    | Ast.StaticAssert (e, so) -> expr e; opt plain so
    | Ast.Match (e, arms) -> expr e; list arm arms
    | Ast.LetMatch (_, id, t, e, arms) ->
        comma id; opt ty t; expr e; list arm arms
  and arm = function
    | Ast.ArmVariant (a, b, p, ss) ->
        comma a; comma b;
        opt (function
          | Ast.PayloadBind (id, _) -> comma id
          | Ast.PayloadIgnore -> ()) p;
        list stmt ss
    | Ast.ArmWild ss | Ast.ArmMiss ss | Ast.ArmIntLit (_, ss) -> list stmt ss
    | Ast.ArmByteSliceLit (s, ss) -> comma s; list stmt ss in
  let typed_param (id, t) = comma id; ty t in
  let param (id, t) = comma id; opt ty t in
  let where_clause (a, _, b) = static_arg a; static_arg b in
  let proto_ref (r : Ast.proto_ref) =
    plain r.pr_name; list (fun (s, _) -> comma s) r.pr_args in
  let proto_item = function
    | Ast.PState (r, ss) -> proto_ref r; list plain ss
    | Ast.PInit r -> proto_ref r
    | Ast.PTransition (s, a, b, alts, ss, _) ->
        comma s; proto_ref a; opt proto_ref b;
        list (fun (alt : Ast.proto_alt) ->
          opt plain alt.pa_label; proto_ref alt.pa_state) alts;
        list plain ss
    | Ast.PObserve (s, r, obs, _) ->
        comma s; proto_ref r;
        list (fun (r, ss) -> proto_ref r; list plain ss) obs
    | Ast.PProperty (s, _) | Ast.PModel (s, _, _) -> comma s in
  let fields = list typed_param in
  let cases = list (fun (s, t) -> comma s; opt ty t) in
  (match top with
   | Ast.FuncDef f ->
       plain f.name; list param f.params; opt ty f.ret_type;
       opt (list plain) f.effects; list stmt f.body;
       list where_clause f.where_clauses
   | Ast.ConstDef (id, t, e, _) -> comma id; ty t; expr e
   | Ast.LetDef (id, t, eo, _, _, _, _) -> comma id; opt ty t; opt expr eo
   | Ast.ExternFuncDef (id, ps, r, effs) ->
       comma id; list param ps; opt ty r; opt (list plain) effs
   | Ast.ExternSymbolDef (id, _) -> comma id
   | Ast.VectorTableDef (entries, _) -> list (fun (_, id) -> plain id) entries
   | Ast.ExceptionEntryDef (id, regs, _) | Ast.ExceptionRestoreDef (id, regs, _) ->
       comma id; list (fun (a, b) -> comma a; plain b) regs
   | Ast.StructDef (s, fs, _, _, ss, _) -> comma s; fields fs; list plain ss
   | Ast.OwnedStructDef (s, _, sps, fs, _, _, ss, _, _) ->
       comma s; list typed_param sps; fields fs; list plain ss
   | Ast.GenericStructDef (s, gps, fs, _, _, ss, _) ->
       comma s;
       list (fun (id, k) ->
         comma id;
         match k with Ast.GPType -> () | Ast.GPValue t -> ty t) gps;
       fields fs; list plain ss
   | Ast.ViewDef (s, _, sps, _, _) -> comma s; list typed_param sps
   | Ast.OpaqueStructDef (s, _, _, _) -> comma s
   | Ast.EnumDef (s, t, cs, _) ->
       comma s; opt ty t; list (fun (c, _) -> comma c) cs
   | Ast.VariantDef (s, sps, cs, _, _) ->
       comma s; list typed_param sps; cases cs
   | Ast.GenericVariantDef (s, tps, sps, cs, _, _) ->
       comma s; list plain tps; list typed_param sps; cases cs
   | Ast.ProtocolDef p ->
       plain p.proto_name; list typed_param p.proto_params;
       (let (s, t, ss) = p.proto_region in comma s; ty t; list plain ss);
       opt plain p.proto_direction; list proto_item p.proto_items
   | Ast.UseDef s -> plain s);
  Array.of_list (List.rev !acc)

(* The items of the last program read: every planning scan reads the same
   program, so it is walked once (as the printed texts were, #917). *)
let cache : (Ast.toplevel list * item list) option ref = ref None

let items (prog : Ast.toplevel list) =
  match !cache with
  | Some (p, items) when p == prog -> items
  | _ ->
      let items = List.map item prog in
      cache := Some (prog, items);
      items

let reset () = cache := None
