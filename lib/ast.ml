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
  | Or | And | Bor | Bxor | Band | Shr | Shl
[@@deriving show]

type type_expr =
  | TypeBool
  | TypeI8  | TypeI16 | TypeI32 | TypeI64
  | TypeU8  | TypeU16 | TypeU32 | TypeU64
  | TypeUsize                              (* pointer-sized unsigned integer *)
  | TypeVoid
  | TypePtr of type_expr           (* *T     -- regular pointer, non-volatile *)
  | TypeIo  of type_expr           (* io T   -- volatile-qualified value type; *io T = TypePtr(TypeIo T) *)
  | TypeArray of type_expr * int   (* [T; N] *)
  | TypeFn of type_expr list * type_expr  (* fn(T...) -> R *)
  | TypeNamed of string            (* struct type by name *)
  | TypeRefined of int * int       (* {lo..<hi} -- refined int: lo <= x < hi *)
[@@deriving show]

type expr = expr_desc located
and expr_desc =
  | IntLit of int
  | BoolLit of bool
  | StringLit of string     (* "..."  -- null-terminated *char constant *)
  | Var of ident
  | Call of ident * expr list
  | BinOp of binop * expr * expr
  | Bnot of expr               (* ~expr -- bitwise NOT *)
  | Deref of expr           (* *expr  -- read through pointer *)
  | AddrOf of expr          (* &lvalue -- variable or struct field address *)
  | Cast of type_expr * expr  (* expr as T -- explicit type cast *)
  | FieldGet of expr * string  (* expr.field -- read a struct field *)
  | StructLit of expr list     (* { e, e, ... } -- positional struct literal *)
  | Index of ident * expr      (* arr[idx] -- preserves array/pointer type for bounds checking *)
  | EnumVariant of string * string  (* EtherType::IPv4 -- enum name, variant name *)
[@@deriving show]

type stmt = stmt_desc located
and stmt_desc =
  | Return of expr
  | Expr of expr
  | Assign of ident * expr
  | AssignDeref of expr * expr   (* *lhs = rhs -- write through pointer *)
  | AssignField of expr * string * expr  (* base.field = rhs -- write a struct field *)
  | AssignIndex of ident * expr * expr  (* arr[idx] = rhs -- indexed write with bounds check *)
  | Block of stmt list
  | Let of bool * ident * type_expr option * expr option  (* is_mutable, name, type, init *)
  | If of expr * stmt list * stmt list
  | While of expr * stmt list
  | For of ident * expr * expr * stmt list  (* for i in lo..<hi { body } *)
  | Break
  | Continue
  | Match of expr * match_arm list  (* match expr { EName::V => {...} _ => {...} } *)
and match_arm =
  | ArmVariant of string * string * stmt list  (* EnumName::Variant => { stmts } *)
  | ArmWild    of stmt list                    (* _ => { stmts } *)
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
  | LetDef of ident * type_expr option * expr option * int option
  (* name, type, init, align_bytes -- align_bytes = Some N means global align(N) *)
  | ExternFuncDef of ident * (ident * type_expr option) list * type_expr option
  (* extern fn name(params) -> ret; -- body is provided by external assembly *)
  | StructDef of string * (string * type_expr) list
  (* struct Name { field: type; ... } -- named struct type definition *)
  | EnumDef of string * type_expr option * (string * int option) list * bool
  (* enum Name: u16 { Variant = val; _; } -- last bool = is_nonexhaustive *)
[@@deriving show]

let show_toplevel_list lst =
  String.concat "\n" (List.map show_toplevel lst)
