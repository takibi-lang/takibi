type loc = Lexing.position

let pp_loc fmt _ = Format.fprintf fmt "<loc>"

type 'a located = {
  desc: 'a;
  loc: loc [@printer pp_loc];
} [@@deriving show]

type ident = string
[@@deriving show]

type binop =
  | Add | Sub | Mul | Div
  | Lt | Gt | Le | Ge | Eq | Ne
[@@deriving show]

type expr = expr_desc located
and expr_desc =
  | IntLit of int
  | Var of ident
  | Call of ident * expr list
  | BinOp of binop * expr * expr
[@@deriving show]

type type_expr =
  | TypeInt
  | TypeChar
  | TypeVoid
[@@deriving show]

type stmt = stmt_desc located
and stmt_desc =
  | Return of expr
  | Expr of expr
  | Assign of ident * expr
  | Block of stmt list
  | Let of ident * type_expr option * expr option
  | If of expr * stmt list * stmt list
  | While of expr * stmt list
[@@deriving show]

type func = {
  name : ident;
  params: (ident * type_expr option) list;
  ret_type : type_expr option;
  body : stmt list;
}
[@@deriving show]

type toplevel =
  | FuncDef of func
  | LetDef of ident * type_expr option * expr option
[@@deriving show]

let show_toplevel_list lst =
  String.concat "\n" (List.map show_toplevel lst)
