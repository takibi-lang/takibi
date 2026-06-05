open Llvm
open Ast

exception Error of string

(* LLVMのグローバルな状態 *)
let context = global_context ()
let the_module = create_module context "takibi_module"
let builder = builder context

(* ARM向けの初期化例 *)
let setup_target () =
  (* 全ターゲットを初期化（またはARMのみ） *)
  let _ = Llvm_all_backends.initialize () in
  
  (* triple: arm-none-eabi (ベアメタルARM) *)
  let triple = "arm-none-eabi" in
  set_target_triple triple the_module;
  
  (* ここでDataLayoutの設定なども行うと、
     構造体のサイズ計算などがARMのABIに準拠します *)
  ()

(* 型の変換 *)
let ltype_of_ast = function
  | TypeInt -> i32_type context
  | TypeChar -> i8_type context
  | TypeVoid -> void_type context

(* 式の生成 (今のところ整数と加算のみ) *)
let rec gen_expr env e =
  match e.desc with
  | IntLit i -> const_int (i32_type context) i
  | BinOp (op, e1, e2) ->
      let v1 = gen_expr env e1 in
      let v2 = gen_expr env e2 in
      (match op with
       | Add -> build_add v1 v2 "addtmp" builder
       | Sub -> build_sub v1 v2 "subtmp" builder
       | Mul -> build_mul v1 v2 "multmp" builder
       | _ -> raise (Error "Other operators not implemented"))
  | _ -> raise (Error "Expression not implemented")

(* 関数定義の生成 *)
let gen_func fdef =
  (* 引数の型リストを作成 *)
  let param_types = 
    List.map (fun (_, t_opt) -> 
      match t_opt with 
      | Some t -> ltype_of_ast t 
      | None -> i32_type context (* デフォルトはint *)
    ) fdef.params |> Array.of_list
  in
  (* 戻り値の型 *)
  let ret_type = match fdef.ret_type with 
    | Some t -> ltype_of_ast t 
    | None -> void_type context 
  in
  (* 関数の型を定義 *)
  let ft = function_type ret_type param_types in
  (* 関数をモジュールに追加 *)
  let f = declare_function fdef.name ft the_module in
  
  (* 基本ブロック（関数の開始地点）を作成 *)
  let bb = append_block context "entry" f in
  position_at_end bb builder;

  (* 本来はここでbody(stmt list)を再帰的に生成するが、
     今は単純化のため、最後の式の戻り値だけを扱う例 *)
  (* build_ret_void builder; *) (* 暫定 *)
  f
