open Llvm
open Ast

exception Error of string

let context = global_context ()
let the_module = create_module context "takibi_module"
let builder = builder context

(* Global tables — populated during gen_program *)
let global_vars : (string, lltype * llvalue) Hashtbl.t = Hashtbl.create 16
let functions   : (string, lltype * llvalue) Hashtbl.t = Hashtbl.create 16

let setup_target () =
  let _ = Llvm_all_backends.initialize () in
  let triple = "arm-none-eabi" in
  set_target_triple triple the_module;
  ()

let ltype_of_ast = function
  | TypeInt  -> i32_type context
  | TypeChar -> i8_type  context
  | TypeVoid -> void_type context

(* Variable / parameter types: unspecified defaults to i32 *)
let ltype_of_ast_opt = function
  | Some t -> ltype_of_ast t
  | None   -> i32_type context

(* Return types: unspecified defaults to i32, matching codegen.ml behaviour *)
let ret_ltype_of_ast_opt = function
  | Some TypeVoid -> void_type context
  | Some t        -> ltype_of_ast t
  | None          -> i32_type context

(* Widen an integer value to i32 so arithmetic is uniform *)
let to_i32 v =
  let ty = type_of v in
  if ty = i32_type context then v
  else build_zext v (i32_type context) "zext" builder

(* Make a branch condition: comparisons already yield i1; integers are != 0 *)
let as_cond v =
  if type_of v = i1_type context then v
  else build_icmp Icmp.Ne v (const_int (i32_type context) 0) "tobool" builder

(* Truncate/extend v so it matches the target alloca type ty *)
let coerce v ty =
  let vty = type_of v in
  if vty = ty then v
  else if ty = i8_type context  && vty = i32_type context then build_trunc v ty "trunc" builder
  else if ty = i32_type context && vty = i1_type  context then build_zext  v ty "zext"  builder
  else if ty = i32_type context && vty = i8_type  context then build_zext  v ty "zext"  builder
  else v

(* Pre-scan all Let bindings in a statement list so we can alloca them upfront *)
let rec collect_lets stmts =
  List.concat_map (fun s ->
    match s.desc with
    | Let (name, ty_opt, _) -> [(name, ty_opt)]
    | Block ss              -> collect_lets ss
    | If (_, t, e)          -> collect_lets t @ collect_lets e
    | While (_, b)          -> collect_lets b
    | _                     -> []
  ) stmts

(* ── Expression codegen ────────────────────────────────────────────────── *)

let rec gen_expr locals e =
  match e.desc with
  | IntLit i -> const_int (i32_type context) i
  | Var name ->
      (match Hashtbl.find_opt locals name with
       | Some (ty, ptr) -> to_i32 (build_load ty ptr name builder)
       | None ->
           match Hashtbl.find_opt global_vars name with
           | Some (ty, gvar) -> to_i32 (build_load ty gvar name builder)
           | None -> raise (Error (Printf.sprintf "Undefined variable: %s" name)))
  | BinOp (op, e1, e2) ->
      let v1 = gen_expr locals e1 in
      let v2 = gen_expr locals e2 in
      (match op with
       | Add -> build_add  v1 v2 "addtmp" builder
       | Sub -> build_sub  v1 v2 "subtmp" builder
       | Mul -> build_mul  v1 v2 "multmp" builder
       | Div -> build_sdiv v1 v2 "divtmp" builder
       | Lt  -> build_icmp Icmp.Slt v1 v2 "lttmp" builder
       | Gt  -> build_icmp Icmp.Sgt v1 v2 "gttmp" builder
       | Le  -> build_icmp Icmp.Sle v1 v2 "letmp" builder
       | Ge  -> build_icmp Icmp.Sge v1 v2 "getmp" builder
       | Eq  -> build_icmp Icmp.Eq  v1 v2 "eqtmp" builder
       | Ne  -> build_icmp Icmp.Ne  v1 v2 "netmp" builder)
  | Call (fname, args) ->
      (match Hashtbl.find_opt functions fname with
       | None -> raise (Error (Printf.sprintf "Undefined function: %s" fname))
       | Some (ft, callee) ->
           let arg_vals = List.map (gen_expr locals) args |> Array.of_list in
           let ret_ty   = return_type ft in
           let name     = if ret_ty = void_type context then "" else "calltmp" in
           build_call ft callee arg_vals name builder)

(* ── Statement codegen ─────────────────────────────────────────────────── *)

let rec gen_stmt locals func s =
  (* Skip dead code that follows a terminator in the current block *)
  if block_terminator (insertion_block builder) <> None then ()
  else
  match s.desc with
  | Return e ->
      let v = gen_expr locals e in
      ignore (build_ret v builder)
  | Expr e ->
      ignore (gen_expr locals e)
  | Assign (name, e) ->
      let v = gen_expr locals e in
      (match Hashtbl.find_opt locals name with
       | Some (ty, ptr)  -> ignore (build_store (coerce v ty) ptr   builder)
       | None ->
           match Hashtbl.find_opt global_vars name with
           | Some (ty, gvar) -> ignore (build_store (coerce v ty) gvar builder)
           | None -> raise (Error (Printf.sprintf "Undefined variable: %s" name)))
  | Let (name, _, expr_opt) ->
      (match Hashtbl.find_opt locals name with
       | None -> raise (Error (Printf.sprintf "BUG: no alloca for %s" name))
       | Some (ty, ptr) ->
           (match expr_opt with
            | None -> ()
            | Some e ->
                let v = gen_expr locals e in
                ignore (build_store (coerce v ty) ptr builder)))
  | Block stmts ->
      List.iter (gen_stmt locals func) stmts
  | If (cond, then_stmts, else_stmts) ->
      let cond_v   = as_cond (gen_expr locals cond) in
      let then_bb  = append_block context "then"  func in
      let else_bb  = append_block context "else"  func in
      let merge_bb = append_block context "merge" func in
      ignore (build_cond_br cond_v then_bb else_bb builder);

      position_at_end then_bb builder;
      List.iter (gen_stmt locals func) then_stmts;
      if block_terminator (insertion_block builder) = None then
        ignore (build_br merge_bb builder);

      position_at_end else_bb builder;
      List.iter (gen_stmt locals func) else_stmts;
      if block_terminator (insertion_block builder) = None then
        ignore (build_br merge_bb builder);

      position_at_end merge_bb builder
  | While (cond, body) ->
      let cond_bb  = append_block context "while_cond"  func in
      let body_bb  = append_block context "while_body"  func in
      let after_bb = append_block context "while_after" func in
      ignore (build_br cond_bb builder);

      position_at_end cond_bb builder;
      let cond_v = as_cond (gen_expr locals cond) in
      ignore (build_cond_br cond_v body_bb after_bb builder);

      position_at_end body_bb builder;
      List.iter (gen_stmt locals func) body;
      if block_terminator (insertion_block builder) = None then
        ignore (build_br cond_bb builder);

      position_at_end after_bb builder

(* ── Function codegen ──────────────────────────────────────────────────── *)

let gen_func fdef =
  let (ft, f) =
    match Hashtbl.find_opt functions fdef.name with
    | Some x -> x
    | None ->
        let param_types =
          List.map (fun (_, t_opt) -> ltype_of_ast_opt t_opt) fdef.params
          |> Array.of_list
        in
        let ret_ty = ret_ltype_of_ast_opt fdef.ret_type in
        let ft     = function_type ret_ty param_types in
        let f      = declare_function fdef.name ft the_module in
        Hashtbl.add functions fdef.name (ft, f);
        (ft, f)
  in

  let entry_bb = append_block context "entry" f in
  position_at_end entry_bb builder;

  let locals : (string, lltype * llvalue) Hashtbl.t = Hashtbl.create 16 in

  (* Alloca + store for every parameter *)
  List.iteri (fun i (name, ty_opt) ->
    let ty  = ltype_of_ast_opt ty_opt in
    let ptr = build_alloca ty name builder in
    ignore (build_store (param f i) ptr builder);
    Hashtbl.add locals name (ty, ptr)
  ) fdef.params;

  (* Pre-alloca every local variable declared in the body *)
  List.iter (fun (name, ty_opt) ->
    if not (Hashtbl.mem locals name) then begin
      let ty  = ltype_of_ast_opt ty_opt in
      let ptr = build_alloca ty name builder in
      Hashtbl.add locals name (ty, ptr)
    end
  ) (collect_lets fdef.body);

  List.iter (gen_stmt locals f) fdef.body;

  (* Ensure every exit block has a terminator *)
  if block_terminator (insertion_block builder) = None then begin
    let ret_ty = return_type ft in
    if ret_ty = void_type context then ignore (build_ret_void builder)
    else ignore (build_ret (const_int ret_ty 0) builder)
  end;

  Llvm_analysis.assert_valid_function f;
  f

(* ── Top-level codegen ─────────────────────────────────────────────────── *)

let gen_global name ty_opt expr_opt =
  let ty   = ltype_of_ast_opt ty_opt in
  let init = match expr_opt with
    | Some { desc = IntLit i; _ } -> const_int ty i
    | None                        -> const_int ty 0
    | _ -> raise (Error "Global initializer must be a constant integer")
  in
  let gvar = define_global name init the_module in
  Hashtbl.add global_vars name (ty, gvar)

let declare_func fdef =
  if not (Hashtbl.mem functions fdef.name) then begin
    let param_types =
      List.map (fun (_, t_opt) -> ltype_of_ast_opt t_opt) fdef.params
      |> Array.of_list
    in
    let ret_ty = ret_ltype_of_ast_opt fdef.ret_type in
    let ft     = function_type ret_ty param_types in
    let f      = declare_function fdef.name ft the_module in
    Hashtbl.add functions fdef.name (ft, f)
  end

let gen_program prog =
  (* Pass 1: register all globals and function signatures *)
  List.iter (function
    | FuncDef fdef                    -> declare_func fdef
    | LetDef (name, ty_opt, expr_opt) -> gen_global name ty_opt expr_opt
  ) prog;
  (* Pass 2: generate function bodies *)
  List.iter (function
    | FuncDef fdef -> ignore (gen_func fdef)
    | LetDef _     -> ()
  ) prog
