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

let ltype_of_ast = function
  | TypeInt      -> i32_type context
  | TypeChar     -> i8_type  context
  | TypeVoid     -> void_type context
  | TypePtr _    -> pointer_type context   (* LLVM 19: all pointers are opaque ptr *)

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
      build_zext v dst_ll "zext" builder
  | TypeVoid -> v

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

(* Pre-scan all Let bindings so we can alloca them up-front in the entry block *)
let rec collect_lets stmts =
  List.concat_map (fun s ->
    match s.desc with
    | Let (name, ty_opt, _) -> [(name, ty_opt)]
    | Block ss              -> collect_lets ss
    | If (_, t, e)          -> collect_lets t @ collect_lets e
    | While (_, b)          -> collect_lets b
    | _                     -> []
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
      let (ast_ty, ptr) =
        match Hashtbl.find_opt locals name with
        | Some x -> x
        | None ->
            match Hashtbl.find_opt global_vars name with
            | Some x -> x
            | None -> raise (Error (Printf.sprintf "Undefined variable: %s" name))
      in
      let v = build_load (ltype_of_ast ast_ty) ptr name builder in
      (* widen int/char to i32; leave pointers as-is *)
      let v' = match ast_ty with
        | TypeInt | TypeChar -> to_i32 v
        | _                  -> v
      in
      (ast_ty, v')

  | Deref e1 ->
      let (ty1, v1) = gen_expr locals e1 in
      (match ty1 with
       | TypePtr inner_ty ->
           let inst = build_load (ltype_of_ast inner_ty) v1 "deref" builder in
           set_volatile true inst;
           (* Var と同様に i8/i32 を i32 に揃える（比較・演算で型が合うように） *)
           let v' = match inner_ty with
             | TypeInt | TypeChar -> to_i32 inst
             | _                  -> inst
           in
           (inner_ty, v')
       | _ -> raise (Error "dereference of non-pointer type"))

  | AddrOf name ->
      (match Hashtbl.find_opt locals name with
       | Some (ast_ty, alloca) -> (TypePtr ast_ty, alloca)
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
       | Or  -> (TypeInt, build_or  (to_i32 v1) (to_i32 v2) "ortmp" builder))

  | Call (fname, args) ->
      (match Hashtbl.find_opt functions fname with
       | None -> raise (Error (Printf.sprintf "Undefined function: %s" fname))
       | Some (ft, callee) ->
           let param_lltys = Array.to_list (param_types ft) in
           let arg_vals =
             List.map2 (fun a lty ->
               let v   = snd (gen_expr locals a) in
               let src = type_of v in
               (* i32↔i8 の変換: Var/Deref が i32 に揃えるため関数引数で戻す *)
               if src = lty then v
               else if lty = i8_type  context && src = i32_type context then
                 build_trunc v lty "arg_trunc" builder
               else if lty = i32_type context && src = i8_type  context then
                 build_zext  v lty "arg_ext"   builder
               else v
             ) args param_lltys |> Array.of_list
           in
           let ret_lty = return_type ft in
           let name    = if ret_lty = void_type context then "" else "calltmp" in
           let v       = build_call ft callee arg_vals name builder in
           let ast_ret = match Hashtbl.find_opt func_ret_ast_types fname with
             | Some t -> t
             | None   -> TypeInt
           in
           (ast_ret, v))

(* ── Statement codegen ─────────────────────────────────────────────────── *)

let rec gen_stmt locals func ret_ast_ty (s : Ast.stmt) =
  (* Skip dead code after a terminator *)
  if block_terminator (insertion_block builder) <> None then ()
  else
  match s.desc with
  | Return e ->
      let (_, v) = gen_expr locals e in
      ignore (build_ret (coerce v ret_ast_ty) builder)

  | Expr e ->
      ignore (gen_expr locals e)

  | Assign (name, e) ->
      let (_, v) = gen_expr locals e in
      (match Hashtbl.find_opt locals name with
       | Some (ast_ty, ptr) ->
           ignore (build_store (coerce v ast_ty) ptr builder)
       | None ->
           match Hashtbl.find_opt global_vars name with
           | Some (ast_ty, gvar) ->
               ignore (build_store (coerce v ast_ty) gvar builder)
           | None -> raise (Error (Printf.sprintf "Undefined variable: %s" name)))

  | AssignDeref (ptr_expr, val_expr) ->
      let (_, ptr_v) = gen_expr locals ptr_expr in
      let (_, val_v) = gen_expr locals val_expr in
      (* volatile: MMIO writes must not be optimised away *)
      let inst = build_store val_v ptr_v builder in
      set_volatile true inst

  | Let (name, _, expr_opt) ->
      (match Hashtbl.find_opt locals name with
       | None -> raise (Error (Printf.sprintf "BUG: no alloca for %s" name))
       | Some (ast_ty, ptr) ->
           match expr_opt with
           | None -> ()
           | Some e ->
               let (_, v) = gen_expr locals e in
               ignore (build_store (coerce v ast_ty) ptr builder))

  | Block stmts ->
      List.iter (gen_stmt locals func ret_ast_ty) stmts

  | If (cond, then_stmts, else_stmts) ->
      let cond_v   = as_cond (snd (gen_expr locals cond)) in
      let then_bb  = append_block context "then"  func in
      let else_bb  = append_block context "else"  func in
      let merge_bb = append_block context "merge" func in
      ignore (build_cond_br cond_v then_bb else_bb builder);

      position_at_end then_bb builder;
      List.iter (gen_stmt locals func ret_ast_ty) then_stmts;
      if block_terminator (insertion_block builder) = None then
        ignore (build_br merge_bb builder);

      position_at_end else_bb builder;
      List.iter (gen_stmt locals func ret_ast_ty) else_stmts;
      if block_terminator (insertion_block builder) = None then
        ignore (build_br merge_bb builder);

      position_at_end merge_bb builder

  | While (cond, body) ->
      let cond_bb  = append_block context "while_cond"  func in
      let body_bb  = append_block context "while_body"  func in
      let after_bb = append_block context "while_after" func in
      ignore (build_br cond_bb builder);

      position_at_end cond_bb builder;
      let cond_v = as_cond (snd (gen_expr locals cond)) in
      ignore (build_cond_br cond_v body_bb after_bb builder);

      position_at_end body_bb builder;
      List.iter (gen_stmt locals func ret_ast_ty) body;
      if block_terminator (insertion_block builder) = None then
        ignore (build_br cond_bb builder);

      position_at_end after_bb builder

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

  (* locals maps name → (ast_type, alloca_ptr) *)
  let locals : (string, Ast.type_expr * llvalue) Hashtbl.t = Hashtbl.create 16 in

  (* Alloca + store for every parameter *)
  List.iteri (fun i (name, ty_opt) ->
    let ast_ty = res name ty_opt in
    let ptr    = build_alloca (ltype_of_ast ast_ty) name builder in
    ignore (build_store (param f i) ptr builder);
    Hashtbl.add locals name (ast_ty, ptr)
  ) fdef.params;

  (* Pre-alloca every local Let declared in the body *)
  List.iter (fun (name, ty_opt) ->
    if not (Hashtbl.mem locals name) then begin
      let ast_ty = res name ty_opt in
      let ptr    = build_alloca (ltype_of_ast ast_ty) name builder in
      Hashtbl.add locals name (ast_ty, ptr)
    end
  ) (collect_lets fdef.body);

  List.iter (gen_stmt locals f ret_ast) fdef.body;

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
    | None ->
        (match ast_ty with
         | TypePtr _ -> const_null (pointer_type context)
         | _         -> const_int llty 0)
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
    Hashtbl.add func_ret_ast_types fdef.name ret_ast
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
