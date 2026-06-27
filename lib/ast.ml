type loc = Lexing.position

let pp_loc fmt _ = Format.fprintf fmt "<loc>"

type 'a located = {
  desc: 'a;
  loc: loc [@printer pp_loc];
} [@@deriving show]

type ident = string
[@@deriving show]

type binop =
  | Add | Sub | Mul | Div | Mod
  | Lt | Gt | Le | Ge | Eq | Ne
  | Or | Bor | Bxor | Band | Shr | Shl
[@@deriving show]

type type_expr =
  | TypeInt
  | TypeChar
  | TypeVoid
  | TypePtr of type_expr           (* *T *)
  | TypeArray of type_expr * int   (* [T; N] *)
  | TypeFn of type_expr list * type_expr  (* fn(T...) -> R *)
  | TypeNamed of string            (* struct type by name *)
[@@deriving show]

type expr = expr_desc located
and expr_desc =
  | IntLit of int
  | StringLit of string     (* "..."  — null-terminated *char constant *)
  | Var of ident
  | Call of ident * expr list
  | BinOp of binop * expr * expr
  | Deref of expr           (* *expr  — read through pointer *)
  | AddrOf of expr          (* &lvalue — variable or struct field address *)
  | Cast of type_expr * expr  (* expr as T — explicit type cast *)
  | FieldGet of expr * string  (* expr.field — read a struct field *)
[@@deriving show]

type stmt = stmt_desc located
and stmt_desc =
  | Return of expr
  | Expr of expr
  | Assign of ident * expr
  | AssignDeref of expr * expr   (* *lhs = rhs — write through pointer *)
  | AssignField of expr * string * expr  (* base.field = rhs — write a struct field *)
  | Block of stmt list
  | Let of bool * ident * type_expr option * expr option  (* is_mutable, name, type, init *)
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
  | ExternFuncDef of ident * (ident * type_expr option) list * type_expr option
  (* extern fn name(params) -> ret; — body は外部アセンブリが提供する *)
  | StructDef of string * (string * type_expr) list
  (* struct Name { field: type; ... } — named struct type definition *)
[@@deriving show]

let show_toplevel_list lst =
  String.concat "\n" (List.map show_toplevel lst)
