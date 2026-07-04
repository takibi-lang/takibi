%{
open Ast
%}

%token <int> INT
%token <string> IDENT
%token <string> STRING
%token FN RETURN LET MUT EXTERN STRUCT PACKED IO ENUM MATCH ALIGN SIZEOF UNSAFE
%token DARROW COLONCOLON UNDERSCORE
%token LBRACE RBRACE LPAREN RPAREN LBRACKET RBRACKET COMMA SEMI DOTDOTLT DOTDOT
%token ASSIGN DOT
%token IF ELSE WHILE FOR IN BREAK CONTINUE
%token EOF
%token AMP TILDE

%token LT GT LE GE EQ NE
%token PLUS MINUS TIMES DIV PERCENT
%token OR PIPE HAT SHR SHL DAMP
%token AS
%token PLUS_EQ MINUS_EQ PIPE_EQ AMP_EQ HAT_EQ SHL_EQ SHR_EQ

(* Precedence: low -> high.  UNARY is a pseudo-token for %prec. *)
%left OR          (* || -- lowest precedence logical operator *)
%left DAMP        (* && -- higher than ||, lower than comparison operators *)
%left PIPE        (* bitwise OR: looser than comparison so (a==0)|(b==0) works *)
%left HAT         (* bitwise XOR: between | and comparison *)
%left LT GT LE GE EQ NE
%left AMP         (* bitwise AND -- also used as unary AddrOf prefix *)
%nonassoc AS      (* as cast: lower than arithmetic so a+b as T = (a+b) as T *)
%left PLUS MINUS
%left SHR SHL     (* shifts: tighter than +/-, looser than * / % *)
%left TIMES DIV PERCENT  (* multiplicative *)
%nonassoc UNARY   (* unary * (deref), & (addrof), unary - *)
%left DOT         (* highest: field access -- postfix, binds tighter than prefix ops *)

%token VOID_TYPE BOOL_TYPE
%token I8_TYPE I16_TYPE I32_TYPE I64_TYPE
%token U8_TYPE U16_TYPE U32_TYPE U64_TYPE USIZE_TYPE
%token TRUE FALSE
%token COLON ARROW

%start <Ast.toplevel list> program

%%

program:
  | items EOF { $1 }

items:
  | item { [$1] }
  | item items { $1 :: $2 }

%inline mut_flag:
  | /* empty */ { false }
  | MUT         { true }

item:
  | func_def { FuncDef $1 }
  | LET m = mut_flag IDENT let_rhs SEMI
    { Const_env.define_if_literal m $3 (snd $4);
      LetDef ($3, fst $4, snd $4, None, m) }
  | LET m = mut_flag IDENT COLON type_expr ALIGN LPAREN INT RPAREN SEMI
    { LetDef ($3, Some $5, None, Some $8, m) }
  | LET m = mut_flag IDENT COLON type_expr ALIGN LPAREN INT RPAREN ASSIGN expr SEMI
    { LetDef ($3, Some $5, Some $11, Some $8, m) }
  | EXTERN FN IDENT LPAREN params RPAREN SEMI
    { ExternFuncDef ($3, $5, None) }
  | EXTERN FN IDENT LPAREN params RPAREN ARROW type_expr SEMI
    { ExternFuncDef ($3, $5, Some $8) }
  | STRUCT IDENT LBRACE struct_fields RBRACE
    { StructDef ($2, $4, false, None) }
  | STRUCT PACKED IDENT LBRACE struct_fields RBRACE
    { StructDef ($3, $5, true, None) }
  | STRUCT IDENT ALIGN LPAREN INT RPAREN LBRACE struct_fields RBRACE
    { StructDef ($2, $8, false, Some $5) }
  | STRUCT PACKED IDENT ALIGN LPAREN INT RPAREN LBRACE struct_fields RBRACE
    { StructDef ($3, $9, true, Some $6) }
  | ENUM IDENT COLON base_type_expr LBRACE enum_variants RBRACE
    { let (vs, ne) = $6 in EnumDef ($2, Some $4, vs, ne) }
  | ENUM IDENT LBRACE enum_variants RBRACE
    { let (vs, ne) = $4 in EnumDef ($2, None, vs, ne) }

struct_fields:
  | /* empty */ { [] }
  | IDENT COLON type_expr SEMI struct_fields { ($1, $3) :: $5 }

enum_variants:
  | /* empty */                         { ([], false) }
  | UNDERSCORE SEMI enum_variants       { let (vs, _) = $3 in (vs, true) }
  | IDENT ASSIGN INT SEMI enum_variants { let (vs, ne) = $5 in (($1, Some $3) :: vs, ne) }
  | IDENT SEMI            enum_variants { let (vs, ne) = $3 in (($1, None)    :: vs, ne) }

func_def:
  | FN IDENT LPAREN params RPAREN ret_type_opt LBRACE stmts RBRACE
    {
      Ast.{ name = $2; params = $4; ret_type = $6; body = $8; def_loc = $symbolstartpos }
    }

param:
  | IDENT { ($1, None) }
  | IDENT COLON type_expr { ($1, Some $3) }

params:
  | /* empty */ { [] }
  | param rest_params { $1 :: $2 }

rest_params:
  | /* empty */ { [] }
  | COMMA param rest_params { $2 :: $3 }

ret_type_opt:
  | /* empty */          { None }
  | ARROW type_expr      { Some $2 }   (* fn foo() -> int  preferred form *)
  | base_type_expr       { Some $1 }   (* fn foo() int  backward-compatible; {lo..<hi} cannot be written without -> *)

stmts:
  | /* empty */ { [] }
  | stmt stmts { $1 :: $2 }

stmt:
  | RETURN e = expr SEMI { { desc = Return e; loc = $symbolstartpos } }
  | fname = IDENT LPAREN args = args RPAREN SEMI
    (* Only function calls are allowed as expression statements. IDENT LPAREN disambiguates, eliminating S/R conflicts with DOT *)
    { let loc = $symbolstartpos in
      { desc = Expr { desc = Call (fname, args); loc }; loc } }
  | LET id = IDENT rhs = let_rhs SEMI
    { { desc = Let (false, id, fst rhs, snd rhs); loc = $symbolstartpos } }
  | LET MUT id = IDENT rhs = let_rhs SEMI
    { { desc = Let (true, id, fst rhs, snd rhs); loc = $symbolstartpos } }
  | LBRACE s = stmts RBRACE { { desc = Block s; loc = $symbolstartpos } }
  | IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE p = else_part
    { { desc = If(c, t, p); loc = $symbolstartpos } }
  | WHILE LPAREN c = expr RPAREN LBRACE b = stmts RBRACE
    { { desc = While(c, b); loc = $symbolstartpos } }
  | FOR id = IDENT IN lo = expr DOTDOTLT hi = expr LBRACE body = stmts RBRACE
    { { desc = For (id, lo, hi, body); loc = $symbolstartpos } }
  | BREAK SEMI    { { desc = Break;    loc = $symbolstartpos } }
  | CONTINUE SEMI { { desc = Continue; loc = $symbolstartpos } }
  | MATCH expr LBRACE match_arms RBRACE
    { { desc = Match ($2, $4); loc = $symbolstartpos } }
  | id = IDENT ASSIGN e = expr SEMI
    { { desc = Assign (id, e); loc = $symbolstartpos } }
  | id = IDENT LBRACKET idx = expr RBRACKET ASSIGN rhs = expr SEMI
    (* arr[i] = rhs -- preserves id+size for bounds checking in codegen *)
    { { desc = AssignIndex (id, idx, rhs); loc = $symbolstartpos } }
  | TIMES id = IDENT ASSIGN rhs = expr SEMI
    (* *p = v  -- simple pointer-deref write *)
    { let loc = $symbolstartpos in
      let ptr = { desc = Var id; loc } in
      { desc = AssignDeref (ptr, rhs); loc } }
  | TIMES LPAREN lhs = expr RPAREN ASSIGN rhs = expr SEMI
    (* *(complex_expr) = v  -- e.g. *(arr + i) = v *)
    { { desc = AssignDeref (lhs, rhs); loc = $symbolstartpos } }
  | id = IDENT DOT fname = IDENT ASSIGN rhs = expr SEMI
    (* s.field = v  or  ptr.field = v -- struct field write *)
    { let loc = $symbolstartpos in
      let base = { desc = Var id; loc } in
      { desc = AssignField (base, fname, rhs); loc } }
  | id = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let lhs = { desc = Var id; loc } in
      { desc = Assign (id, { desc = BinOp (op, lhs, rhs); loc }); loc } }
  | id = IDENT LBRACKET idx = expr RBRACKET op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let load = { desc = Index (id, idx); loc } in
      { desc = AssignIndex (id, idx, { desc = BinOp (op, load, rhs); loc }); loc } }
  | TIMES id = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let ptr = { desc = Var id; loc } in
      let load = { desc = Deref ptr; loc } in
      { desc = AssignDeref (ptr, { desc = BinOp (op, load, rhs); loc }); loc } }
  | TIMES LPAREN lhs = expr RPAREN op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let load = { desc = Deref lhs; loc } in
      { desc = AssignDeref (lhs, { desc = BinOp (op, load, rhs); loc }); loc } }
  | id = IDENT DOT fname = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let base = { desc = Var id; loc } in
      let load = { desc = FieldGet (base, fname); loc } in
      { desc = AssignField (base, fname, { desc = BinOp (op, load, rhs); loc }); loc } }

%inline compound_op:
  | PLUS_EQ  { Add }
  | MINUS_EQ { Sub }
  | PIPE_EQ  { Bor }
  | AMP_EQ   { Band }
  | HAT_EQ   { Bxor }
  | SHL_EQ   { Shl }
  | SHR_EQ   { Shr }

else_part:
  | ELSE LBRACE e = stmts RBRACE { e }
  | ELSE IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE p = else_part
    { [{ desc = If(c, t, p); loc = $symbolstartpos }] }
  | (* empty *) { [] }

match_arms:
  | /* empty */ { [] }
  | match_arm match_arms { $1 :: $2 }

match_arm:
  | IDENT COLONCOLON IDENT DARROW LBRACE stmts RBRACE
    { ArmVariant ($1, $3, $6) }
  | UNDERSCORE DARROW LBRACE stmts RBRACE
    { ArmWild $4 }

expr:
  | expr OR      expr  { { desc = BinOp (Or,   $1, $3); loc = $symbolstartpos } }
  | expr DAMP    expr  { { desc = BinOp (And,  $1, $3); loc = $symbolstartpos } }
  | expr PIPE    expr  { { desc = BinOp (Bor,  $1, $3); loc = $symbolstartpos } }
  | expr HAT     expr  { { desc = BinOp (Bxor, $1, $3); loc = $symbolstartpos } }
  | expr AMP     expr  { { desc = BinOp (Band, $1, $3); loc = $symbolstartpos } }
  | expr SHR     expr  { { desc = BinOp (Shr,  $1, $3); loc = $symbolstartpos } }
  | expr SHL     expr  { { desc = BinOp (Shl,  $1, $3); loc = $symbolstartpos } }
  | expr PLUS    expr  { { desc = BinOp (Add,  $1, $3); loc = $symbolstartpos } }
  | expr MINUS   expr  { { desc = BinOp (Sub,  $1, $3); loc = $symbolstartpos } }
  | expr TIMES   expr  { { desc = BinOp (Mul,  $1, $3); loc = $symbolstartpos } }
  | expr DIV     expr  { { desc = BinOp (Div,  $1, $3); loc = $symbolstartpos } }
  | expr PERCENT expr  { { desc = BinOp (Mod,  $1, $3); loc = $symbolstartpos } }
  | expr LT expr   { { desc = BinOp (Lt, $1, $3); loc = $symbolstartpos } }
  | expr GT expr   { { desc = BinOp (Gt, $1, $3); loc = $symbolstartpos } }
  | expr LE expr   { { desc = BinOp (Le, $1, $3); loc = $symbolstartpos } }
  | expr GE expr   { { desc = BinOp (Ge, $1, $3); loc = $symbolstartpos } }
  | expr EQ expr   { { desc = BinOp (Eq, $1, $3); loc = $symbolstartpos } }
  | expr NE expr   { { desc = BinOp (Ne, $1, $3); loc = $symbolstartpos } }
  | TIMES e = expr %prec UNARY { { desc = Deref e;    loc = $symbolstartpos } }
  | AMP e = expr %prec UNARY { { desc = AddrOf e; loc = $symbolstartpos } }
  | TILDE e = expr %prec UNARY { { desc = Bnot e; loc = $symbolstartpos } }
  | MINUS e = expr %prec UNARY
    { { desc = BinOp (Sub, { desc = IntLit 0; loc = $symbolstartpos }, e);
        loc = $symbolstartpos } }
  | INT    { { desc = IntLit $1;       loc = $symbolstartpos } }
  | TRUE   { { desc = BoolLit true;   loc = $symbolstartpos } }
  | FALSE  { { desc = BoolLit false;  loc = $symbolstartpos } }
  | STRING { { desc = StringLit $1;   loc = $symbolstartpos } }
  | IDENT { { desc = Var $1; loc = $symbolstartpos } }
  | IDENT LPAREN args RPAREN { { desc = Call ($1, $3); loc = $symbolstartpos } }
  | IDENT COLONCOLON IDENT
    { { desc = EnumVariant ($1, $3); loc = $symbolstartpos } }
  | SIZEOF LPAREN t = type_expr RPAREN
    { { desc = SizeOf t; loc = $symbolstartpos } }
  | LPAREN e = expr RPAREN { e }
  | e = expr AS t = type_expr
    { { desc = Cast (t, e); loc = $symbolstartpos } }
  | id = IDENT LBRACKET idx = expr RBRACKET
    (* arr[i] -- preserved as Index node; codegen emits bounds check for [T;N] arrays *)
    { { desc = Index (id, idx); loc = $symbolstartpos } }
  | id = IDENT LBRACKET lo = expr DOTDOTLT hi = expr RBRACKET
    (* s[lo..<hi] -- subslice (constant bounds, proven) or slice-from-pointer (unchecked) *)
    { { desc = SliceOf (id, lo, hi); loc = $symbolstartpos } }
  | UNSAFE LBRACE e = expr RBRACE
    (* unsafe { e } -- visibility marker permitting unchecked-assertion constructs in e *)
    { { desc = Unsafe e; loc = $symbolstartpos } }
  | e = expr DOT fname = IDENT
    (* e.field -- struct field read; works for both Struct and *Struct *)
    { { desc = FieldGet (e, fname); loc = $symbolstartpos } }
  | LBRACE fs = args RBRACE
    (* { e, e, ... } -- positional struct literal; requires a type annotation *)
    { { desc = StructLit fs; loc = $symbolstartpos } }

args:
  | /* empty */ { [] }
  | expr rest_args { $1 :: $2 }

rest_args:
  | /* empty */ { [] }
  | COMMA expr rest_args { $2 :: $3 }

let_rhs:
  | /* empty */ { (None, None) }
  | COLON type_expr { (Some $2, None) }
  | COLON type_expr ASSIGN expr { (Some $2, Some $4) }
  | ASSIGN expr { (None, Some $2) }

(* base_type_expr: type expression that does not start with {. Used for the legacy ret_type_opt form (`fn f() int`).
   TypeRefined is excluded here because { would conflict with the function body's LBRACE. *)
base_type_expr:
  | VOID_TYPE { TypeVoid }
  | BOOL_TYPE { TypeBool }
  | I8_TYPE   { TypeI8  } | I16_TYPE { TypeI16 } | I32_TYPE { TypeI32 } | I64_TYPE { TypeI64 }
  | U8_TYPE   { TypeU8  } | U16_TYPE { TypeU16 } | U32_TYPE { TypeU32 } | U64_TYPE { TypeU64 }
  | USIZE_TYPE { TypeUsize }
  | IO         type_expr { TypeIo  $2 }
  | TIMES      type_expr { TypePtr $2 }
  | LBRACKET t = type_expr SEMI n = array_size RBRACKET { TypeArray (t, n) }
  | LBRACKET RBRACKET t = type_expr { TypeSlice (t, 0) }
    (* []T -- slice with no compile-time minimum length *)
  | LBRACKET t = type_expr SEMI n = array_size DOTDOT RBRACKET { TypeSlice (t, n) }
    (* [T; N..] -- slice whose runtime length is at least N *)
  | FN LPAREN fn_type_params RPAREN ARROW type_expr { TypeFn ($3, $6) }
  | FN LPAREN fn_type_params RPAREN                 { TypeFn ($3, TypeVoid) }
  | IDENT { TypeNamed $1 }

(* Array size: a literal integer, or the name of a compile-time integer
   constant declared earlier as an immutable global `let NAME: T = N;`. *)
array_size:
  | n = INT   { n }
  | name = IDENT
    { match Const_env.find name with
      | Some n -> n
      | None ->
          raise (Types.TypeError ($symbolstartpos,
            Printf.sprintf
              "array size '%s' is not a known compile-time integer constant \
               (declare it earlier as an immutable global `let %s: T = N;`)"
              name name)) }

(* type_expr: base_type_expr + TypeRefined. Used in unambiguous positions such as after : or -> *)
type_expr:
  | base_type_expr { $1 }
  | LBRACE lo = INT DOTDOTLT hi = INT RBRACE { TypeRefined (lo, hi) }

fn_type_params:
  | /* empty */                              { [] }
  | type_expr fn_type_params_rest            { $1 :: $2 }

fn_type_params_rest:
  | /* empty */                              { [] }
  | COMMA type_expr fn_type_params_rest      { $2 :: $3 }
