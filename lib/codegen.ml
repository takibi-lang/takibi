open Ast

let indent = "  "

let string_of_type_opt = function
  | None -> "int"  (* デフォルトは int *)
  | Some TypeInt -> "int"
  | Some TypeChar -> "char"
  | Some TypeVoid -> "void"

let rec string_of_expr (e : expr) =
  match e.desc with
  | IntLit n -> string_of_int n
  | Var name -> name
  | BinOp (op, e1, e2) ->
    let op = match op with
      | Add -> "+"
      | Sub -> "-"
      | Mul -> "*"
      | Div -> "/"
      | Lt -> "<"
      | Gt -> ">"
      | Le -> "<="
      | Ge -> ">="
      | Eq -> "=="
      | Ne -> "!="
    in Printf.sprintf "(%s %s %s)" (string_of_expr e1) op (string_of_expr e2)
  | Call (fname, args) ->
      Printf.sprintf "%s(%s)"
        fname
        (String.concat ", " (List.map string_of_expr args))

let rec string_of_stmt ?(level=1) (stmt : stmt) =
  let ind = String.make (level * 2) ' ' in
  match stmt.desc with
  | Return e ->
      Printf.sprintf "%sreturn %s;\n" ind (string_of_expr e)
  | Expr e ->
      Printf.sprintf "%s%s;\n" ind (string_of_expr e)
  | Assign (name, e) ->
      Printf.sprintf "%s%s = %s;\n" ind name (string_of_expr e)
  | Let (name, ty_opt, expr_opt) ->
      let ty_str = string_of_type_opt ty_opt in
      let init = match expr_opt with
        | None -> ""
        | Some e -> Printf.sprintf " = %s" (string_of_expr e)
      in
      Printf.sprintf "%s%s %s%s;\n" ind ty_str name init
  | Block stmts ->
      let body = List.map (string_of_stmt ~level:(level + 1)) stmts |> String.concat "" in
      Printf.sprintf "%s{\n%s%s}\n" ind body ind
  | If (cond, then_s, else_s) ->
      let then_body = List.map (string_of_stmt ~level:(level + 1)) then_s |> String.concat "" in
      let else_body = List.map (string_of_stmt ~level:(level + 1)) else_s |> String.concat "" in
      Printf.sprintf "%sif (%s) {\n%s%s} else {\n%s%s}\n"
        ind (string_of_expr cond)
        then_body ind else_body ind
  | While (cond, body) ->
      let body_str = List.map (string_of_stmt ~level:(level + 1)) body |> String.concat "" in
      Printf.sprintf "%swhile (%s) {\n%s%s}\n" ind (string_of_expr cond) body_str ind

let string_of_func f =
  let ret_ty = string_of_type_opt f.ret_type in
  let params =
    f.params
    |> List.map (fun (name, ty_opt) ->
           Printf.sprintf "%s %s" (string_of_type_opt ty_opt) name)
    |> String.concat ", "
  in
  let body = List.map (string_of_stmt ~level:1) f.body |> String.concat "" in
  Printf.sprintf "%s %s(%s) {\n%s}\n" ret_ty f.name params body

let string_of_toplevel = function
  | FuncDef f -> string_of_func f
  | LetDef (name, ty_opt, expr_opt) ->
      let ty_str = string_of_type_opt ty_opt in
      let init = match expr_opt with
        | None -> ""
        | Some e -> Printf.sprintf " = %s" (string_of_expr e)
      in
      Printf.sprintf "%s %s%s;\n" ty_str name init

let string_of_program (prog : toplevel list) : string =
  List.map string_of_toplevel prog |> String.concat "\n"
