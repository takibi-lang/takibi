%{
open Ast
%}

%token <int> INT
%token <string> IDENT
%token <string> STRING
%token FN RETURN LET MUT EXTERN STRUCT
%token LBRACE RBRACE LPAREN RPAREN LBRACKET RBRACKET COMMA SEMI
%token ASSIGN DOT
%token IF ELSE WHILE
%token EOF
%token AMP

%token LT GT LE GE EQ NE
%token PLUS MINUS TIMES DIV PERCENT
%token OR PIPE HAT SHR SHL
%token AS

(* Precedence: low → high.  UNARY is a pseudo-token for %prec. *)
%left OR
%left PIPE        (* bitwise OR: looser than comparison so (a==0)|(b==0) works *)
%left HAT         (* bitwise XOR: between | and comparison *)
%left LT GT LE GE EQ NE
%left AMP         (* bitwise AND — also used as unary AddrOf prefix *)
%nonassoc AS      (* as cast: lower than arithmetic so a+b as T = (a+b) as T *)
%left PLUS MINUS
%left SHR SHL     (* shifts: tighter than +/-, looser than * / % *)
%left TIMES DIV PERCENT  (* multiplicative *)
%nonassoc UNARY   (* unary * (deref), & (addrof), unary - *)
%left DOT         (* highest: field access — postfix, binds tighter than prefix ops *)

%token INT_TYPE CHAR_TYPE VOID_TYPE
%token COLON ARROW

%start <Ast.toplevel list> program

%%

program:
  | items EOF { $1 }

items:
  | item { [$1] }
  | item items { $1 :: $2 }

item:
  | func_def { FuncDef $1 }
  | LET IDENT let_rhs SEMI { LetDef ($2, fst $3, snd $3) }
  | EXTERN FN IDENT LPAREN params RPAREN SEMI
    { ExternFuncDef ($3, $5, None) }
  | EXTERN FN IDENT LPAREN params RPAREN ARROW type_expr SEMI
    { ExternFuncDef ($3, $5, Some $8) }
  | STRUCT IDENT LBRACE struct_fields RBRACE
    { StructDef ($2, $4) }

struct_fields:
  | /* empty */ { [] }
  | IDENT COLON type_expr SEMI struct_fields { ($1, $3) :: $5 }

func_def:
  | FN IDENT LPAREN params RPAREN ret_type_opt LBRACE stmts RBRACE
    {
      Ast.{ name = $2; params = $4; ret_type = $6; body = $8 }
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
  | /* empty */       { None }
  | ARROW type_expr   { Some $2 }   (* fn foo() -> int  推奨: extern fn / fn ptr と統一 *)
  | type_expr         { Some $1 }   (* fn foo() int     後方互換のため残す *)

stmts:
  | /* empty */ { [] }
  | stmt stmts { $1 :: $2 }

stmt:
  | RETURN e = expr SEMI { { desc = Return e; loc = $symbolstartpos } }
  | fname = IDENT LPAREN args = args RPAREN SEMI
    (* 式文は関数呼び出しのみ許容。IDENT LPAREN で確定するため DOT との S/R コンフリクトが消える *)
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
  | id = IDENT ASSIGN e = expr SEMI
    { { desc = Assign (id, e); loc = $symbolstartpos } }
  | id = IDENT LBRACKET idx = expr RBRACKET ASSIGN rhs = expr SEMI
    (* arr[i] = v  desugars to  *(arr + i) = v *)
    { let loc = $symbolstartpos in
      let arr = { desc = Var id; loc } in
      let ptr = { desc = BinOp (Add, arr, idx); loc } in
      { desc = AssignDeref (ptr, rhs); loc } }
  | TIMES id = IDENT ASSIGN rhs = expr SEMI
    (* *p = v  — simple pointer-deref write *)
    { let loc = $symbolstartpos in
      let ptr = { desc = Var id; loc } in
      { desc = AssignDeref (ptr, rhs); loc } }
  | TIMES LPAREN lhs = expr RPAREN ASSIGN rhs = expr SEMI
    (* *(complex_expr) = v  — e.g. *(arr + i) = v *)
    { { desc = AssignDeref (lhs, rhs); loc = $symbolstartpos } }
  | id = IDENT DOT fname = IDENT ASSIGN rhs = expr SEMI
    (* s.field = v  or  ptr.field = v — struct field write *)
    { let loc = $symbolstartpos in
      let base = { desc = Var id; loc } in
      { desc = AssignField (base, fname, rhs); loc } }

else_part:
  | ELSE LBRACE e = stmts RBRACE { e }
  | ELSE IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE p = else_part
    { [{ desc = If(c, t, p); loc = $symbolstartpos }] }
  | (* empty *) { [] }

expr:
  | expr OR      expr  { { desc = BinOp (Or,   $1, $3); loc = $symbolstartpos } }
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
  | MINUS e = expr %prec UNARY
    { { desc = BinOp (Sub, { desc = IntLit 0; loc = $symbolstartpos }, e);
        loc = $symbolstartpos } }
  | INT    { { desc = IntLit $1;    loc = $symbolstartpos } }
  | STRING { { desc = StringLit $1; loc = $symbolstartpos } }
  | IDENT { { desc = Var $1; loc = $symbolstartpos } }
  | IDENT LPAREN args RPAREN { { desc = Call ($1, $3); loc = $symbolstartpos } }
  | LPAREN e = expr RPAREN { e }
  | e = expr AS t = type_expr
    { { desc = Cast (t, e); loc = $symbolstartpos } }
  | id = IDENT LBRACKET idx = expr RBRACKET
    (* arr[i] desugars to *(arr + i) — array decay to pointer happens in codegen *)
    { let loc = $symbolstartpos in
      let arr = { desc = Var id; loc } in
      let add = { desc = BinOp (Add, arr, idx); loc } in
      { desc = Deref add; loc } }
  | e = expr DOT fname = IDENT
    (* e.field — struct field read; works for both Struct and *Struct *)
    { { desc = FieldGet (e, fname); loc = $symbolstartpos } }
  | LBRACE fs = args RBRACE
    (* { e, e, ... } — positional struct literal; requires a type annotation *)
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

type_expr:
  | INT_TYPE  { TypeInt }
  | CHAR_TYPE { TypeChar }
  | VOID_TYPE { TypeVoid }
  | TIMES type_expr { TypePtr $2 }
  | LBRACKET t = type_expr SEMI n = INT RBRACKET { TypeArray (t, n) }
  | FN LPAREN fn_type_params RPAREN ARROW type_expr { TypeFn ($3, $6) }
  | FN LPAREN fn_type_params RPAREN                 { TypeFn ($3, TypeVoid) }
  | IDENT { TypeNamed $1 }   (* named struct type *)

fn_type_params:
  | /* empty */                              { [] }
  | type_expr fn_type_params_rest            { $1 :: $2 }

fn_type_params_rest:
  | /* empty */                              { [] }
  | COMMA type_expr fn_type_params_rest      { $2 :: $3 }
