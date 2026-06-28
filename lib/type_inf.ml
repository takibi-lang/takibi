open Types

(* Type environment: immutable map from variable name to (type, is_mutable) *)
type tyenv = (ty * bool) StringMap.t

(* Struct environment: maps struct name to its ordered field list [(name, ast_type)] *)
type senv = (string * Ast.type_expr) list StringMap.t

let lookup_binding loc name env =
  match StringMap.find_opt name env with
  | Some b -> b
  | None   -> raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" name))

let lookup loc name env = fst (lookup_binding loc name env)

(* io T is a storage qualifier; strip it to get the value type for expression checks *)
let strip_io t = match repr t with TIo inner -> inner | _ -> t

let unify_at loc t1 t2 =
  try unify t1 t2
  with Unify_error msg -> raise (TypeError (loc, msg))

(* ── Expression inference ────────────────────────────────────────────────── *)

let rec infer_expr senv tyenv fenv (e : Ast.expr) : ty =
  match e.desc with
  | IntLit _    -> fresh ()  (* polymorphic: unifies with int or char via context *)
  | StringLit _ -> TPtr TChar
  | Var name ->
      (* まずローカル/グローバル変数を探す *)
      (match StringMap.find_opt name tyenv with
       | Some (t, _) ->
           (* 配列型はポインタにデケイ。io T は値型として T を返す（volatileはcodegen担当）*)
           (match repr t with
            | TArray (inner, _) -> TPtr inner
            | TIo    inner      -> inner
            | _                 -> t)
       | None ->
           (* 関数名を値（関数ポインタ）として使う場合 *)
           match StringMap.find_opt name fenv with
           | Some ft -> ft
           | None ->
               raise (TypeError (e.loc,
                 Printf.sprintf "Unbound variable: %s" name)))
  | BinOp (op, e1, e2) ->
      let t1 = infer_expr senv tyenv fenv e1 in
      let t2 = infer_expr senv tyenv fenv e2 in
      (match op with
       | Add ->
           (* ポインタ算術: ptr + int → 同じポインタ型を返す。TIo は値型なので対象外 *)
           (match repr t1, repr t2 with
            | TPtr _, _ -> t1
            | _, TPtr _ -> t2
            | _ ->
                unify_at e1.loc t1 TInt;
                unify_at e2.loc t2 TInt;
                TInt)
       | Sub ->
           (* ポインタ算術: ptr - int → 同じポインタ型を返す。TIo は値型なので対象外 *)
           (match repr t1 with
            | TPtr _ ->
                unify_at e2.loc t2 TInt;
                t1
            | _ ->
                unify_at e1.loc t1 TInt;
                unify_at e2.loc t2 TInt;
                TInt)
       | Mul | Div ->
           unify_at e1.loc t1 TInt;
           unify_at e2.loc t2 TInt;
           TInt
       | Lt | Gt | Le | Ge | Eq | Ne ->
           unify_at e.loc t1 t2;
           TInt
       | Or | Bor | Bxor | Band | Shr | Shl | Mod ->
           unify_at e1.loc t1 TInt;
           unify_at e2.loc t2 TInt;
           TInt)
  | Deref e1 ->
      let t1 = infer_expr senv tyenv fenv e1 in
      (match repr t1 with
       | TPtr inner ->
           (* *io T deref は T を返す（io は記憶域修飾子; volatileはcodegenで処理）*)
           strip_io inner
       | _ ->
           let inner = fresh () in
           unify_at e1.loc t1 (TPtr inner);
           inner)
  | AddrOf inner ->
      (match inner.desc with
       | Var name ->
           let (t, is_mut) = lookup_binding e.loc name tyenv in
           if not is_mut then
             raise (TypeError (e.loc,
               Printf.sprintf "cannot take address of immutable variable '%s'" name));
           TPtr t
       | FieldGet (base_expr, fname) ->
           let bt = infer_expr senv tyenv fenv base_expr in
           let sname = match repr bt with
             | TStruct s | TPtr (TStruct s) | TPtr (TIo (TStruct s)) -> s
             | _ -> raise (TypeError (base_expr.loc,
                 Printf.sprintf "field address '.%s' on non-struct type '%s'"
                   fname (to_string bt)))
           in
           let fields = match StringMap.find_opt sname senv with
             | Some fs -> fs
             | None -> raise (TypeError (e.loc,
                 Printf.sprintf "unknown struct type '%s'" sname))
           in
           (match List.assoc_opt fname fields with
            | Some ft -> TPtr (of_ast ft)
            | None -> raise (TypeError (e.loc,
                Printf.sprintf "no field '%s' in struct '%s'" fname sname)))
       | _ ->
           raise (TypeError (e.loc, "& requires a variable or struct field")))
  | Cast (target_ty, e) ->
      ignore (infer_expr senv tyenv fenv e);
      of_ast target_ty

  | FieldGet (base_expr, fname) ->
      let bt = infer_expr senv tyenv fenv base_expr in
      let sname = match repr bt with
        | TStruct s                      -> s
        | TPtr   (TStruct s)             -> s
        | TPtr   (TIo (TStruct s))       -> s   (* *io Struct のフィールド読み出し *)
        | _ ->
            raise (TypeError (base_expr.loc,
              Printf.sprintf "field access '.%s' on non-struct type '%s'"
                fname (to_string bt)))
      in
      let fields = match StringMap.find_opt sname senv with
        | Some fs -> fs
        | None ->
            raise (TypeError (e.loc,
              Printf.sprintf "unknown struct type '%s'" sname))
      in
      (match List.assoc_opt fname fields with
       | Some ft ->
           (match of_ast ft with
            | TArray (inner, _) -> TPtr inner  (* 配列フィールドは *elem に decay *)
            | TIo    inner      -> inner        (* io フィールドは値型 T を返す（volatile はcodegen）*)
            | t                 -> t)
       | None ->
           raise (TypeError (e.loc,
             Printf.sprintf "no field '%s' in struct '%s'" fname sname)))

  | Index (id, idx) ->
      (* 変数の元の型を取得（Var と違い array decay をしない）*)
      let vt = lookup e.loc id tyenv in
      let it = infer_expr senv tyenv fenv idx in
      unify_at idx.loc it TInt;
      (match repr vt with
       | TArray (elem, n) ->
           (* 定数インデックスはコンパイル時に境界を検査 *)
           (match idx.desc with
            | IntLit k when k >= n ->
                raise (TypeError (idx.loc,
                  Printf.sprintf "index %d is out of bounds for array of size %d" k n))
            | _ -> ());
           elem
       | TPtr   elem      -> strip_io elem     (* *T または *io T → T を返す（境界不明）*)
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt))))

  | StructLit _ ->
      raise (TypeError (e.loc,
        "struct literal requires a type annotation: `let mut x: Name = {...}`"))

  | Call (fname, args) ->
      (* 直接呼び出し（関数名 → fenv）を先に試みる *)
      let ft_opt = match StringMap.find_opt fname fenv with
        | Some ft -> Some ft
        | None ->
            (* 関数ポインタ変数（tyenv）を試みる *)
            match StringMap.find_opt fname tyenv with
            | Some (t, _) -> Some t
            | None -> None
      in
      (match ft_opt with
       | None ->
           raise (TypeError (e.loc,
             Printf.sprintf "Undefined function: %s" fname))
       | Some ft ->
           let (param_tys, ret_ty) = match repr ft with
             | TFun (ps, r) -> (ps, r)
             | _ ->
                 raise (TypeError (e.loc,
                   Printf.sprintf "'%s' is not a function or function pointer" fname))
           in
           if List.length args <> List.length param_tys then
             raise (TypeError (e.loc,
               Printf.sprintf "%s expects %d argument(s), got %d"
                 fname (List.length param_tys) (List.length args)));
           List.iter2 (fun arg pt ->
             let at = infer_expr senv tyenv fenv arg in
             unify_at arg.loc at pt
           ) args param_tys;
           ret_ty)

(* ── Checking mode ───────────────────────────────────────────────────────── *)
(* check_expr pushes the expected type inward (bidirectional checking).
   Handles nested StructLit for both struct and array fields.
   Falls back to infer_expr + unify for all other expressions. *)

let rec check_expr senv tyenv fenv (e : Ast.expr) (expected : ty) : unit =
  match e.desc, repr expected with
  | StructLit exprs, TArray (elem_ty, n) ->
      if List.length exprs <> n then
        raise (TypeError (e.loc, Printf.sprintf
          "array [_; %d] expects %d elements but literal has %d"
          n n (List.length exprs)));
      List.iter (fun ei -> check_expr senv tyenv fenv ei elem_ty) exprs
  | StructLit exprs, TStruct sname ->
      let fields = match StringMap.find_opt sname senv with
        | Some fs -> fs
        | None -> raise (TypeError (e.loc,
            Printf.sprintf "unknown struct type '%s'" sname))
      in
      if List.length fields <> List.length exprs then
        raise (TypeError (e.loc, Printf.sprintf
          "struct '%s' has %d fields but literal has %d values"
          sname (List.length fields) (List.length exprs)));
      List.iter2 (fun (_, ft) ei ->
        check_expr senv tyenv fenv ei (of_ast ft)
      ) fields exprs
  | _ ->
      let te = infer_expr senv tyenv fenv e in
      (* io T が期待型の場合: T との互換性で確認（記憶域修飾子を剥がす）*)
      unify_at e.loc te (strip_io expected)

(* ── Statement inference ─────────────────────────────────────────────────── *)
(* Returns (updated_tyenv, updated_raw_locals).
   tyenv grows with each Let in the current scope.
   raw_locals accumulates every Let type seen (including inside blocks/if/while)
   so that codegen can pre-allocate mutable locals at function entry. *)

let rec infer_stmt senv tyenv fenv ret_ty raw_locals (s : Ast.stmt)
    : tyenv * ty StringMap.t =
  match s.desc with
  | Return e ->
      let t = infer_expr senv tyenv fenv e in
      unify_at e.loc t ret_ty;
      (tyenv, raw_locals)
  | Expr e ->
      ignore (infer_expr senv tyenv fenv e);
      (tyenv, raw_locals)
  | Assign (name, e) ->
      let (vty, is_mut) = lookup_binding s.loc name tyenv in
      if not is_mut then
        raise (TypeError (s.loc,
          Printf.sprintf "cannot assign to immutable variable '%s'; use 'let mut'" name));
      let ety = infer_expr senv tyenv fenv e in
      (* io T 変数への代入: T との互換性で確認（io は記憶域修飾子なので剥がす）*)
      unify_at e.loc (strip_io vty) ety;
      (tyenv, raw_locals)
  | AssignDeref (ptr_expr, val_expr) ->
      let pt = infer_expr senv tyenv fenv ptr_expr in
      let inner = match repr pt with
        | TPtr i ->
            (* *io T ポインタ経由の書き込み: inner は TIo T なので剥がして T で確認 *)
            strip_io i
        | _ ->
            let inner = fresh () in
            unify_at ptr_expr.loc pt (TPtr inner);
            inner
      in
      let vt = infer_expr senv tyenv fenv val_expr in
      unify_at val_expr.loc vt inner;
      (tyenv, raw_locals)
  | AssignIndex (id, idx, rhs) ->
      (* 変数の元の型で判別（[T; N] vs *T）。tyenv には decay 前の型が入っている *)
      let vt = lookup s.loc id tyenv in
      let it = infer_expr senv tyenv fenv idx in
      let rt = infer_expr senv tyenv fenv rhs in
      unify_at idx.loc it TInt;
      let elem_ty = match repr vt with
        | TArray (elem, n) ->
            (match idx.desc with
             | IntLit k when k >= n ->
                 raise (TypeError (idx.loc,
                   Printf.sprintf "index %d is out of bounds for array of size %d" k n))
             | _ -> ());
            elem
        | TPtr   elem      -> strip_io elem
        | _ -> raise (TypeError (s.loc,
            Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt)))
      in
      unify_at rhs.loc rt elem_ty;
      (tyenv, raw_locals)

  | AssignField (base_expr, fname, val_expr) ->
      let bt = infer_expr senv tyenv fenv base_expr in
      let sname = match repr bt with
        | TStruct s                      -> s
        | TPtr   (TStruct s)             -> s
        | TPtr   (TIo (TStruct s))       -> s
        | _ ->
            raise (TypeError (base_expr.loc,
              Printf.sprintf "field assignment '.%s' on non-struct type '%s'"
                fname (to_string bt)))
      in
      let fields = match StringMap.find_opt sname senv with
        | Some fs -> fs
        | None ->
            raise (TypeError (s.loc,
              Printf.sprintf "unknown struct type '%s'" sname))
      in
      let field_ty = match List.assoc_opt fname fields with
        | Some ft -> of_ast ft
        | None ->
            raise (TypeError (s.loc,
              Printf.sprintf "no field '%s' in struct '%s'" fname sname))
      in
      let vt = infer_expr senv tyenv fenv val_expr in
      (* io フィールドへの代入: T との互換性で確認（io は記憶域修飾子なので剥がす）*)
      unify_at val_expr.loc vt (strip_io field_ty);
      (tyenv, raw_locals)
  | Let (is_mut, name, ty_opt, expr_opt) ->
      let ty = of_ast_opt ty_opt in
      (match expr_opt with
       | None ->
           if not is_mut then
             raise (TypeError (s.loc,
               Printf.sprintf "immutable variable '%s' must have an initializer" name))
       | Some { desc = StructLit exprs; loc } ->
           (* 構造体リテラル: 型アノテーションから struct 名を取り、フィールドごとに型チェック *)
           if not is_mut then
             raise (TypeError (loc,
               Printf.sprintf "struct literal requires `let mut %s: Name = {...}`" name));
           (match repr ty with
            | (TStruct _ | TArray _) as expected ->
                check_expr senv tyenv fenv { desc = StructLit exprs; loc } expected
            | _ -> raise (TypeError (loc,
                "literal { ... } requires a struct or array type annotation")))
       | Some e ->
           let et = infer_expr senv tyenv fenv e in
           (* io T アノテーション付き変数の初期化: T との互換性で確認 *)
           unify_at e.loc (strip_io ty) et);
      ( StringMap.add name (ty, is_mut) tyenv,
        StringMap.add name ty raw_locals )
  | Block stmts ->
      (* Let bindings extend the inner env but do not escape the block *)
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt senv env fenv ret_ty locs s)
        (tyenv, raw_locals) stmts
      in
      (tyenv, raw_locals')
  | If (cond, then_s, else_s) ->
      let ct = infer_expr senv tyenv fenv cond in
      unify_at cond.loc ct TInt;
      let (_, rl1) = List.fold_left
        (fun (env, locs) s -> infer_stmt senv env fenv ret_ty locs s)
        (tyenv, raw_locals) then_s
      in
      let (_, rl2) = List.fold_left
        (fun (env, locs) s -> infer_stmt senv env fenv ret_ty locs s)
        (tyenv, rl1) else_s
      in
      (tyenv, rl2)
  | While (cond, body) ->
      let ct = infer_expr senv tyenv fenv cond in
      unify_at cond.loc ct TInt;
      let (_, raw_locals') = List.fold_left
        (fun (env, locs) s -> infer_stmt senv env fenv ret_ty locs s)
        (tyenv, raw_locals) body
      in
      (tyenv, raw_locals')

(* ── Function inference ──────────────────────────────────────────────────── *)

let infer_func senv fenv genv (fdef : Ast.func) : func_info =
  let param_tys = List.map (fun (_, ty_opt) -> of_ast_opt ty_opt) fdef.params in
  let ret_ty    = ret_of_ast_opt fdef.ret_type in
  (* Start with globals visible, then shadow them with params (params are mutable) *)
  let init_env  = List.fold_left2
    (fun m (name, _) ty -> StringMap.add name (ty, true) m)
    genv fdef.params param_tys
  in
  let (_, raw_locals) = List.fold_left
    (fun (env, locs) s -> infer_stmt senv env fenv ret_ty locs s)
    (init_env, StringMap.empty) fdef.body
  in
  {
    ret_type    = to_ast ret_ty;
    param_types = List.map2 (fun (name, _) ty -> (name, to_ast ty))
                    fdef.params param_tys;
    local_types = StringMap.map to_ast raw_locals;
  }

(* ── Whole-program inference ─────────────────────────────────────────────── *)

let infer_program (prog : Ast.toplevel list) : program_types =
  (* Pass 0: collect struct definitions *)
  let senv = List.fold_left (fun m -> function
    | Ast.StructDef (name, fields) -> StringMap.add name fields m
    | _ -> m
  ) StringMap.empty prog in
  (* Pass 1: collect function signatures and global variable types *)
  let fenv = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        let pts = List.map (fun (_, t) -> of_ast_opt t) fdef.params in
        let rt  = ret_of_ast_opt fdef.ret_type in
        StringMap.add fdef.name (TFun (pts, rt)) m
    | Ast.ExternFuncDef (name, params, ret_ty) ->
        let pts = List.map (fun (_, t) -> of_ast_opt t) params in
        let rt  = ret_of_ast_opt ret_ty in
        StringMap.add name (TFun (pts, rt)) m
    | Ast.LetDef _    -> m
    | Ast.StructDef _ -> m
  ) StringMap.empty prog in
  (* Global variables are always mutable (true) *)
  let genv = List.fold_left (fun m -> function
    | Ast.LetDef (name, ty_opt, _) -> StringMap.add name (of_ast_opt ty_opt, true) m
    | Ast.FuncDef _                -> m
    | Ast.ExternFuncDef _          -> m
    | Ast.StructDef _              -> m
  ) StringMap.empty prog in
  (* Pass 2: check global initializers *)
  List.iter (function
    | Ast.LetDef (name, _, expr_opt) ->
        let (ty, _) = StringMap.find name genv in
        (match expr_opt with
         | None -> ()
         | Some { desc = Ast.StructLit exprs; loc } ->
             (* 構造体リテラル: 宣言型から struct 名を取り、フィールドごとに型チェック *)
             (match repr ty with
              | (TStruct _ | TArray _) as expected ->
                  check_expr senv genv fenv { desc = Ast.StructLit exprs; loc } expected
              | _ -> raise (TypeError (loc,
                  "literal { ... } requires a struct or array type annotation")))
         | Some e ->
             let et = infer_expr senv genv fenv e in
             (* グローバル io T 変数の初期値: T との互換性で確認 *)
             (try unify (strip_io ty) et
              with Unify_error m -> raise (TypeError (e.loc, m))))
    | _ -> ()
  ) prog;
  (* Pass 3: infer function bodies *)
  let functions = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        StringMap.add fdef.name (infer_func senv fenv genv fdef) m
    | _ -> m
  ) StringMap.empty prog in
  {
    globals   = StringMap.map (fun (ty, _) -> to_ast ty) genv;
    functions;
    structs   = senv;
  }
