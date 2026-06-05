%{
open Ast
%}

%token <int> INT
%token <string> IDENT
%token FN RETURN LET
%token LBRACE RBRACE LPAREN RPAREN COMMA SEMI
%token ASSIGN
%token IF ELSE WHILE
%token EOF

%token LT GT LE GE EQ NE
%token PLUS MINUS TIMES DIV

%left LT GT LE GE EQ NE
%left PLUS MINUS
%left TIMES DIV

%token INT_TYPE CHAR_TYPE VOID_TYPE
%token COLON

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
  | /* empty */ { None }
  | COLON type_expr { Some $2 }

stmts:
  | /* empty */ { [] }
  | stmt stmts { $1 :: $2 }

stmt:
  | RETURN e = expr SEMI { { desc = Return e; loc = $symbolstartpos } }
  | e = expr SEMI { { desc = Expr e; loc = $symbolstartpos } }
  | LET id = IDENT rhs = let_rhs SEMI
    { { desc = Let (id, fst rhs, snd rhs); loc = $symbolstartpos } }
  | LBRACE s = stmts RBRACE { { desc = Block s; loc = $symbolstartpos } }
  | IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE ELSE LBRACE e = stmts RBRACE
    { { desc = If(c, t, e); loc = $symbolstartpos } }
  | WHILE LPAREN c = expr RPAREN LBRACE b = stmts RBRACE
    { { desc = While(c, b); loc = $symbolstartpos } }
  | id = IDENT ASSIGN e = expr SEMI
    { { desc = Assign (id, e); loc = $symbolstartpos } }

expr:
  | expr PLUS expr  { { desc = BinOp (Add, $1, $3); loc = $symbolstartpos } }
  | expr MINUS expr { { desc = BinOp (Sub, $1, $3); loc = $symbolstartpos } }
  | expr TIMES expr { { desc = BinOp (Mul, $1, $3); loc = $symbolstartpos } }
  | expr DIV expr   { { desc = BinOp (Div, $1, $3); loc = $symbolstartpos } }
  | expr LT expr   { { desc = BinOp (Lt, $1, $3); loc = $symbolstartpos } }
  | expr GT expr   { { desc = BinOp (Gt, $1, $3); loc = $symbolstartpos } }
  | expr LE expr   { { desc = BinOp (Le, $1, $3); loc = $symbolstartpos } }
  | expr GE expr   { { desc = BinOp (Ge, $1, $3); loc = $symbolstartpos } }
  | expr EQ expr   { { desc = BinOp (Eq, $1, $3); loc = $symbolstartpos } }
  | expr NE expr   { { desc = BinOp (Ne, $1, $3); loc = $symbolstartpos } }
  | INT { { desc = IntLit $1; loc = $symbolstartpos } }
  | IDENT { { desc = Var $1; loc = $symbolstartpos } }
  | IDENT LPAREN args RPAREN { { desc = Call ($1, $3); loc = $symbolstartpos } }

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
