open Llvm
open Ast

exception Error of string

let context = global_context ()
let the_module = create_module context "takibi_module"
let builder = builder context

(* Counter for unique string literal global names *)
let str_counter = ref 0

(* Global tables — populated during gen_program *)
(* Stores (ast_type, llvalue) for global variables *)
let global_vars : (string, Ast.type_expr * llvalue) Hashtbl.t = Hashtbl.create 16
(* Stores (function_lltype, llvalue) for declared functions *)
let functions   : (string, lltype * llvalue) Hashtbl.t = Hashtbl.create 16
(* Stores the return AST type for each function (needed when typing Call results) *)
let func_ret_ast_types : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 16
(* Stores the parameter AST types for each function (needed for function-as-value) *)
let func_param_ast_types : (string, Ast.type_expr list) Hashtbl.t = Hashtbl.create 16

(* Locals are either immutable SSA values or mutable alloca pointers *)
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* direct SSA value — no alloca *)
  | Mut of Ast.type_expr * llvalue  (* alloca pointer — load/store *)

let setup_target ?(triple = "") () =
  let _ = Llvm_all_backends.initialize () in
  let triple = if triple = "" then Llvm_target.Target.default_triple () else triple in
  set_target_triple triple the_module;
  let target  = Llvm_target.Target.by_triple triple in
  let machine = Llvm_target.TargetMachine.create ~triple target in
  let layout  = Llvm_target.TargetMachine.data_layout machine in
  set_data_layout (Llvm_target.DataLayout.as_string layout) the_module;
  machine

let emit_object machine output_path =
  Llvm_target.TargetMachine.emit_to_file
    the_module
    Llvm_target.CodeGenFileType.ObjectFile
    output_path
    machine

(* ── Type helpers ──────────────────────────────────────────────────────── *)

let rec ltype_of_ast = function
  | TypeInt         -> i32_type context
  | TypeChar        -> i8_type  context
  | TypeVoid        -> void_type context
  | TypePtr _       -> pointer_type context   (* LLVM 19: all pointers are opaque ptr *)
  | TypeArray (t, n) -> array_type (ltype_of_ast t) n
  | TypeFn _        -> pointer_type context   (* 関数ポインタも opaque ptr *)

let ltype_of_ret_ast = function
  | TypeVoid -> void_type context
  | t        -> ltype_of_ast t

(* Coerce an llvalue to match a destination AST type.
   Handles: i1/i8 → i32 widening, i32 → i8 truncation,
            and integer → pointer conversion (inttoptr) for MMIO addresses. *)
let coerce v (dst : Ast.type_expr) =
  let vty    = type_of v in
  let dst_ll = ltype_of_ast dst in
  if vty = dst_ll then v
  else match dst with
  | TypePtr _ ->
      (* integer literal used as a memory-mapped address *)
      let v64 =
        if   vty = i64_type context then v
        else build_zext v (i64_type context) "zext64" builder
      in
      build_inttoptr v64 (pointer_type context) "inttoptr" builder
  | TypeChar ->
      if vty = i32_type context then build_trunc v dst_ll "trunc" builder else v
  | TypeInt ->
      if vty = pointer_type context then
        (* pointer as int: ptrtoint → i64, then trunc to i32 (AArch64 RAM fits in 32 bits) *)
        let i64v = build_ptrtoint v (i64_type context) "ptrtoint" builder in
        build_trunc i64v (i32_type context) "trunc" builder
      else
        build_zext v dst_ll "zext" builder
  | TypeVoid    -> v
  | TypeArray _ -> v
  | TypeFn _    -> v   (* 関数ポインタは ptr のまま変換不要 *)

(* Widen an integer value to i32 so arithmetic stays uniform.
   Does NOT touch pointer values. *)
let to_i32 v =
  let ty = type_of v in
  if ty = i32_type context || ty = pointer_type context then v
  else build_zext v (i32_type context) "zext" builder

(* Build an i1 condition from an integer or comparison result *)
let as_cond v =
  if type_of v = i1_type context then v
  else build_icmp Icmp.Ne v (const_int (i32_type context) 0) "tobool" builder

(* Pre-scan only mutable Let bindings — immutable ones need no alloca *)
let rec collect_lets stmts =
  List.concat_map (fun s ->
    match s.desc with
    | Let (true, name, ty_opt, _) -> [(name, ty_opt)]
    | Block ss                    -> collect_lets ss
    | If (_, t, e)                -> collect_lets t @ collect_lets e
    | While (_, b)                -> collect_lets b
    | _                           -> []
  ) stmts

(* ── resolve helpers: map AST annotation → Ast.type_expr using HM results ── *)

let resolve_local_ast (pt : Types.program_types option) fname name ty_opt =
  let fallback = match ty_opt with Some t -> t | None -> TypeInt in
  match pt with
  | None -> fallback
  | Some pt ->
      match Types.StringMap.find_opt fname pt.Types.functions with
      | None -> fallback
      | Some fi ->
          (match List.assoc_opt name fi.Types.param_types with
           | Some t -> t
           | None ->
               match Types.StringMap.find_opt name fi.Types.local_types with
               | Some t -> t
               | None   -> fallback)

let resolve_ret_ast (pt : Types.program_types option) fname ty_opt =
  let fallback = match ty_opt with Some t -> t | None -> TypeVoid in
  match pt with
  | None -> fallback
  | Some pt ->
      match Types.StringMap.find_opt fname pt.Types.functions with
      | None    -> fallback
      | Some fi -> fi.Types.ret_type

(* ── Expression codegen ─────────────────────────────────────────────────── *)
(* Returns (ast_type, llvalue).  ast_type is needed for Deref to know
   the element type when emitting a load instruction (LLVM 19 opaque ptrs). *)

let rec gen_expr locals (e : Ast.expr) : Ast.type_expr * llvalue =
  match e.desc with
  | IntLit i ->
      (TypeInt, const_int (i32_type context) i)

  | StringLit s ->
      (* ヌル終端バイト列をグローバル定数配列として配置し、先頭へのポインタを返す *)
      incr str_counter;
      let name   = Printf.sprintf ".str%d" !str_counter in
      let len    = String.length s in
      let arr_ty = array_type (i8_type context) (len + 1) in
      let bytes  = Array.init (len + 1) (fun i ->
        if i < len then const_int (i8_type context) (Char.code s.[i])
        else             const_int (i8_type context) 0)
      in
      let arr    = const_array (i8_type context) bytes in
      let g      = define_global name arr the_module in
      set_global_constant true g;
      set_linkage Linkage.Private g;
      let zero   = const_int (i32_type context) 0 in
      let ptr    = build_in_bounds_gep arr_ty g [|zero; zero|] "strptr" builder in
      (TypePtr TypeChar, ptr)

  | Var name ->
      (match Hashtbl.find_opt locals name with
       | Some (Imm (ast_ty, v)) ->
           let v' = match ast_ty with
             | TypeInt | TypeChar -> to_i32 v
             | _                  -> v
           in
           (ast_ty, v')
       | Some (Mut (ast_ty, ptr)) ->
           (match ast_ty with
            | TypeArray (elem_ty, n) ->
                (* 配列変数は先頭要素へのポインタにデケイ（C と同じ）*)
                let arr_ll = array_type (ltype_of_ast elem_ty) n in
                let zero   = const_int (i32_type context) 0 in
                let ep = build_in_bounds_gep arr_ll ptr [|zero; zero|] (name ^ "_ptr") builder in
                (TypePtr elem_ty, ep)
            | _ ->
                let v  = build_load (ltype_of_ast ast_ty) ptr name builder in
                let v' = match ast_ty with
                  | TypeInt | TypeChar -> to_i32 v
                  | _                  -> v
                in
                (ast_ty, v'))
       | None ->
           (match Hashtbl.find_opt global_vars name with
            | Some (TypeArray (elem_ty, n), ptr) ->
                let arr_ll = array_type (ltype_of_ast elem_ty) n in
                let zero   = const_int (i32_type context) 0 in
                let ep = build_in_bounds_gep arr_ll ptr [|zero; zero|] (name ^ "_ptr") builder in
                (TypePtr elem_ty, ep)
            | Some (ast_ty, ptr) ->
                let v  = build_load (ltype_of_ast ast_ty) ptr name builder in
                let v' = match ast_ty with
                  | TypeInt | TypeChar -> to_i32 v
                  | _                  -> v
                in
                (ast_ty, v')
            | None ->
                (* 関数名を関数ポインタ値として使う *)
                match Hashtbl.find_opt functions name with
                | Some (_, f) ->
                    let param_asts = match Hashtbl.find_opt func_param_ast_types name with
                      | Some ps -> ps | None -> []
                    in
                    let ret_ast = match Hashtbl.find_opt func_ret_ast_types name with
                      | Some r -> r | None -> TypeVoid
                    in
                    (TypeFn (param_asts, ret_ast), f)
                | None ->
                    raise (Error (Printf.sprintf "Undefined variable: %s" name))))

  | Deref e1 ->
      let (ty1, v1) = gen_expr locals e1 in
      (match ty1 with
       | TypePtr inner_ty ->
           let inst = build_load (ltype_of_ast inner_ty) v1 "deref" builder in
           set_volatile true inst;
           let v' = match inner_ty with
             | TypeInt | TypeChar -> to_i32 inst
             | _                  -> inst
           in
           (inner_ty, v')
       | _ -> raise (Error "dereference of non-pointer type"))

  | AddrOf name ->
      (match Hashtbl.find_opt locals name with
       | Some (Mut (ast_ty, alloca)) -> (TypePtr ast_ty, alloca)
       | Some (Imm _) ->
           raise (Error (Printf.sprintf "BUG: addrof immutable '%s' (should be caught by type_inf)" name))
       | None -> raise (Error (Printf.sprintf "cannot take address of '%s'" name)))

  | BinOp (op, e1, e2) ->
      let (ty1, v1) = gen_expr locals e1 in
      let (ty2, v2) = gen_expr locals e2 in
      (match op with
       | Add ->
           (* ポインタ算術: ptr + int → GEP。整数同士は通常の加算 *)
           (match ty1 with
            | TypePtr inner ->
                (ty1, build_gep (ltype_of_ast inner) v1 [|v2|] "ptradd" builder)
            | _ ->
                (match ty2 with
                 | TypePtr inner ->
                     (ty2, build_gep (ltype_of_ast inner) v2 [|v1|] "ptradd" builder)
                 | _ ->
                     (TypeInt, build_add v1 v2 "addtmp" builder)))
       | Sub -> (TypeInt, build_sub  v1 v2 "subtmp" builder)
       | Mul -> (TypeInt, build_mul  v1 v2 "multmp" builder)
       | Div -> (TypeInt, build_sdiv v1 v2 "divtmp" builder)
       | Lt  -> (TypeInt, build_icmp Icmp.Slt v1 v2 "lttmp" builder)
       | Gt  -> (TypeInt, build_icmp Icmp.Sgt v1 v2 "gttmp" builder)
       | Le  -> (TypeInt, build_icmp Icmp.Sle v1 v2 "letmp" builder)
       | Ge  -> (TypeInt, build_icmp Icmp.Sge v1 v2 "getmp" builder)
       | Eq  -> (TypeInt, build_icmp Icmp.Eq  v1 v2 "eqtmp" builder)
       | Ne  -> (TypeInt, build_icmp Icmp.Ne  v1 v2 "netmp" builder)
       | Or   -> (TypeInt, build_or   (to_i32 v1) (to_i32 v2) "ortmp"  builder)
       | Bor  -> (TypeInt, build_or   (to_i32 v1) (to_i32 v2) "bortmp" builder)
       | Bxor -> (TypeInt, build_xor  (to_i32 v1) (to_i32 v2) "xortmp" builder)
       | Band -> (TypeInt, build_and  (to_i32 v1) (to_i32 v2) "andtmp" builder)
       | Shr  -> (TypeInt, build_lshr (to_i32 v1) (to_i32 v2) "shrtmp" builder)
       | Shl  -> (TypeInt, build_shl  (to_i32 v1) (to_i32 v2) "shltmp" builder)
       | Mod  -> (TypeInt, build_srem (to_i32 v1) (to_i32 v2) "modtmp" builder))

  | Cast (target_ty, e) ->
      let (_, v) = gen_expr locals e in
      (target_ty, coerce v target_ty)

  | Call (fname, args) ->
      let coerce_arg v lty =
        let src = type_of v in
        if src = lty then v
        else if lty = i8_type  context && src = i32_type context then
          build_trunc v lty "arg_trunc" builder
        else if lty = i32_type context && src = i8_type  context then
          build_zext  v lty "arg_ext"   builder
        else v
      in
      (match Hashtbl.find_opt functions fname with
       | Some (ft, callee) ->
           (* 直接呼び出し（関数名で解決） *)
           let param_lltys = Array.to_list (param_types ft) in
           let arg_vals =
             List.map2 (fun a lty ->
               coerce_arg (snd (gen_expr locals a)) lty
             ) args param_lltys |> Array.of_list
           in
           let ret_lty = return_type ft in
           let call_name = if ret_lty = void_type context then "" else "calltmp" in
           let v = build_call ft callee arg_vals call_name builder in
           let ast_ret = match Hashtbl.find_opt func_ret_ast_types fname with
             | Some t -> t | None -> TypeInt
           in
           (ast_ret, v)
       | None ->
           (* 間接呼び出し: ローカル/グローバルの関数ポインタ変数 *)
           let (fn_ast_ty, fn_ptr) =
             match Hashtbl.find_opt locals fname with
             | Some (Imm (ast_ty, v)) -> (ast_ty, v)
             | Some (Mut (ast_ty, ptr)) ->
                 (ast_ty, build_load (ltype_of_ast ast_ty) ptr fname builder)
             | None ->
                 match Hashtbl.find_opt global_vars fname with
                 | Some (ast_ty, ptr) ->
                     (ast_ty, build_load (ltype_of_ast ast_ty) ptr fname builder)
                 | None ->
                     raise (Error (Printf.sprintf "Undefined function: %s" fname))
           in
           (match fn_ast_ty with
            | TypeFn (param_asts, ret_ast) ->
                let param_lls = List.map ltype_of_ast param_asts |> Array.of_list in
                let ret_ll    = ltype_of_ret_ast ret_ast in
                let ft        = function_type ret_ll param_lls in
                let arg_vals  =
                  List.map2 (fun a lty ->
                    coerce_arg (snd (gen_expr locals a)) lty
                  ) args (Array.to_list param_lls) |> Array.of_list
                in
                let call_name = if ret_ll = void_type context then "" else "calltmp" in
                let v = build_call ft fn_ptr arg_vals call_name builder in
                (ret_ast, v)
            | _ ->
                raise (Error (Printf.sprintf
                  "'%s' is not a function or function pointer" fname))))

(* ── Function codegen ──────────────────────────────────────────────────── *)

let gen_func ?prog_types fdef =
  let res name ty_opt = resolve_local_ast prog_types fdef.name name ty_opt in

  let (_, f) =
    match Hashtbl.find_opt functions fdef.name with
    | Some x -> x
    | None ->
        let param_ast = List.map (fun (n, t) -> res n t) fdef.params in
        let param_lls = List.map ltype_of_ast param_ast |> Array.of_list in
        let ret_ast   = resolve_ret_ast prog_types fdef.name fdef.ret_type in
        let ret_ll    = ltype_of_ret_ast ret_ast in
        let ft        = function_type ret_ll param_lls in
        let f         = declare_function fdef.name ft the_module in
        Hashtbl.add functions fdef.name (ft, f);
        Hashtbl.add func_ret_ast_types fdef.name ret_ast;
        (ft, f)
  in

  let ret_ast = match Hashtbl.find_opt func_ret_ast_types fdef.name with
    | Some t -> t
    | None   -> TypeInt
  in

  let entry_bb = append_block context "entry" f in
  position_at_end entry_bb builder;

  (* locals maps name → local_binding *)
  let locals : (string, local_binding) Hashtbl.t = Hashtbl.create 16 in

  (* Alloca + store for every parameter (params are always mutable) *)
  List.iteri (fun i (name, ty_opt) ->
    let ast_ty = res name ty_opt in
    let ptr    = build_alloca (ltype_of_ast ast_ty) name builder in
    ignore (build_store (param f i) ptr builder);
    Hashtbl.add locals name (Mut (ast_ty, ptr))
  ) fdef.params;

  (* Pre-alloca every mutable Let declared in the body *)
  List.iter (fun (name, ty_opt) ->
    if not (Hashtbl.mem locals name) then begin
      let ast_ty = res name ty_opt in
      let ptr    = build_alloca (ltype_of_ast ast_ty) name builder in
      Hashtbl.add locals name (Mut (ast_ty, ptr))
    end
  ) (collect_lets fdef.body);

  (* ── Statement codegen (defined here to access `res` for immutable lets) ── *)
  let rec gen_stmt (s : Ast.stmt) =
    (* Skip dead code after a terminator *)
    if block_terminator (insertion_block builder) <> None then ()
    else
    match s.desc with
    | Return e ->
        let (_, v) = gen_expr locals e in
        ignore (build_ret (coerce v ret_ast) builder)

    | Expr e ->
        ignore (gen_expr locals e)

    | Assign (name, e) ->
        let (_, v) = gen_expr locals e in
        (match Hashtbl.find_opt locals name with
         | Some (Mut (ast_ty, ptr)) ->
             ignore (build_store (coerce v ast_ty) ptr builder)
         | Some (Imm _) ->
             raise (Error (Printf.sprintf "BUG: assign to immutable '%s'" name))
         | None ->
             match Hashtbl.find_opt global_vars name with
             | Some (ast_ty, gvar) ->
                 ignore (build_store (coerce v ast_ty) gvar builder)
             | None -> raise (Error (Printf.sprintf "Undefined variable: %s" name)))

    | AssignDeref (ptr_expr, val_expr) ->
        let (ptr_ty, ptr_v) = gen_expr locals ptr_expr in
        let (_, val_v)      = gen_expr locals val_expr in
        (* ポインタの要素型に合わせて coerce（i32→i8 など）してから store *)
        let coerced = (match ptr_ty with
          | TypePtr inner -> coerce val_v inner
          | _             -> val_v) in
        let inst = build_store coerced ptr_v builder in
        set_volatile true inst

    | Let (true, name, _, expr_opt) ->
        (* Mutable: alloca was pre-allocated; just store the initial value *)
        (match Hashtbl.find_opt locals name with
         | None -> raise (Error (Printf.sprintf "BUG: no alloca for %s" name))
         | Some (Mut (ast_ty, ptr)) ->
             (match expr_opt with
              | None -> ()
              | Some e ->
                  let (_, v) = gen_expr locals e in
                  ignore (build_store (coerce v ast_ty) ptr builder))
         | Some (Imm _) ->
             raise (Error (Printf.sprintf "BUG: %s marked mutable but stored as Imm" name)))

    | Let (false, name, ty_opt, expr_opt) ->
        (* Immutable: evaluate the init expr and store the SSA value directly *)
        (match expr_opt with
         | None ->
             raise (Error (Printf.sprintf "BUG: immutable '%s' has no initializer" name))
         | Some e ->
             let ast_ty = res name ty_opt in
             let (_, v) = gen_expr locals e in
             Hashtbl.add locals name (Imm (ast_ty, coerce v ast_ty)))

    | Block stmts ->
        List.iter gen_stmt stmts

    | If (cond, then_stmts, else_stmts) ->
        let cond_v   = as_cond (snd (gen_expr locals cond)) in
        let then_bb  = append_block context "then"  f in
        let else_bb  = append_block context "else"  f in
        let merge_bb = append_block context "merge" f in
        ignore (build_cond_br cond_v then_bb else_bb builder);

        position_at_end then_bb builder;
        List.iter gen_stmt then_stmts;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br merge_bb builder);

        position_at_end else_bb builder;
        List.iter gen_stmt else_stmts;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br merge_bb builder);

        position_at_end merge_bb builder

    | While (cond, body) ->
        let cond_bb  = append_block context "while_cond"  f in
        let body_bb  = append_block context "while_body"  f in
        let after_bb = append_block context "while_after" f in
        ignore (build_br cond_bb builder);

        position_at_end cond_bb builder;
        let cond_v = as_cond (snd (gen_expr locals cond)) in
        ignore (build_cond_br cond_v body_bb after_bb builder);

        position_at_end body_bb builder;
        List.iter gen_stmt body;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br cond_bb builder);

        position_at_end after_bb builder
  in

  List.iter gen_stmt fdef.body;

  (* Ensure the exit block has a terminator *)
  if block_terminator (insertion_block builder) = None then begin
    if ret_ast = TypeVoid then ignore (build_ret_void builder)
    else ignore (build_ret (const_int (ltype_of_ast ret_ast) 0) builder)
  end;

  Llvm_analysis.assert_valid_function f;
  f

(* ── Top-level codegen ─────────────────────────────────────────────────── *)

let gen_global ?prog_types name ty_opt expr_opt =
  let ast_ty = match prog_types with
    | None -> (match ty_opt with Some t -> t | None -> TypeInt)
    | Some (pt : Types.program_types) ->
        match Types.StringMap.find_opt name pt.Types.globals with
        | Some t -> t
        | None   -> (match ty_opt with Some t -> t | None -> TypeInt)
  in
  let llty = ltype_of_ast ast_ty in
  let init = match expr_opt with
    | Some { desc = IntLit i; _ } ->
        (match ast_ty with
         | TypePtr _ ->
             let i64v = const_int (i64_type context) i in
             const_inttoptr i64v (pointer_type context)
         | _ -> const_int llty i)
    | None -> undef llty  (* no initializer → LLVM undef; runtime value depends on startup *)
    | _ -> raise (Error "Global initializer must be a constant integer")
  in
  let gvar = define_global name init the_module in
  Hashtbl.add global_vars name (ast_ty, gvar)

let declare_func ?prog_types fdef =
  if not (Hashtbl.mem functions fdef.name) then begin
    let res name ty_opt = resolve_local_ast prog_types fdef.name name ty_opt in
    let param_ast = List.map (fun (n, t) -> res n t) fdef.params in
    let param_lls = List.map ltype_of_ast param_ast |> Array.of_list in
    let ret_ast   = resolve_ret_ast prog_types fdef.name fdef.ret_type in
    let ret_ll    = ltype_of_ret_ast ret_ast in
    let ft        = function_type ret_ll param_lls in
    let f         = declare_function fdef.name ft the_module in
    Hashtbl.add functions fdef.name (ft, f);
    Hashtbl.add func_ret_ast_types fdef.name ret_ast;
    Hashtbl.add func_param_ast_types fdef.name param_ast
  end

let gen_program ?prog_types prog =
  (* Pass 1: register all globals and function signatures *)
  List.iter (function
    | FuncDef fdef                    -> declare_func ?prog_types fdef
    | LetDef (name, ty_opt, expr_opt) -> gen_global ?prog_types name ty_opt expr_opt
  ) prog;
  (* Pass 2: generate function bodies *)
  List.iter (function
    | FuncDef fdef -> ignore (gen_func ?prog_types fdef)
    | LetDef _     -> ()
  ) prog
