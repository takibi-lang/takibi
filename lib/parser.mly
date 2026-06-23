%{
open Ast
%}

%token <int> INT
%token <string> IDENT
%token <string> STRING
%token FN RETURN LET MUT
%token LBRACE RBRACE LPAREN RPAREN COMMA SEMI
%token ASSIGN
%token IF ELSE WHILE
%token EOF
%token AMP

%token LT GT LE GE EQ NE
%token PLUS MINUS TIMES DIV
%token OR
%token AS

(* Precedence: low → high.  UNARY is a pseudo-token for %prec. *)
%left OR
%left LT GT LE GE EQ NE
%nonassoc AS      (* as cast: lower than arithmetic so a+b as T = (a+b) as T *)
%left PLUS MINUS
%left TIMES DIV
%nonassoc UNARY   (* highest: unary * (deref), & (addrof), unary - *)

%token INT_TYPE CHAR_TYPE
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
  | type_expr { Some $1 }

stmts:
  | /* empty */ { [] }
  | stmt stmts { $1 :: $2 }

stmt:
  | RETURN e = expr SEMI { { desc = Return e; loc = $symbolstartpos } }
  | e = expr SEMI { { desc = Expr e; loc = $symbolstartpos } }
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
  | TIMES lhs = expr ASSIGN rhs = expr SEMI
    { { desc = AssignDeref (lhs, rhs); loc = $symbolstartpos } }

else_part:
  | ELSE LBRACE e = stmts RBRACE { e }
  | ELSE IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE p = else_part
    { [{ desc = If(c, t, p); loc = $symbolstartpos }] }
  | (* empty *) { [] }

expr:
  | expr OR expr    { { desc = BinOp (Or, $1, $3); loc = $symbolstartpos } }
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
  | TIMES e = expr %prec UNARY { { desc = Deref e;    loc = $symbolstartpos } }
  | AMP   id = IDENT              { { desc = AddrOf id; loc = $symbolstartpos } }
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
  | TIMES type_expr { TypePtr $2 }
