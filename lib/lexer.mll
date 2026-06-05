{
open Parser
}

rule read = parse
  | [' ' '\t'] { read lexbuf }
  | '\n'       { Lexing.new_line lexbuf; read lexbuf }

  | "fn"      { FN }
  | "return"  { RETURN }
  | "let"     { LET }
  | "if"      { IF }
  | "else"    { ELSE }
  | "while"   { WHILE }

  | '{' { LBRACE }
  | '}' { RBRACE }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | ',' { COMMA }
  | ';' { SEMI }
  | '=' { ASSIGN }

  | '+' { PLUS }
  | '-' { MINUS }
  | '*' { TIMES }
  | '/' { DIV }

  | "<"  { LT }
  | ">"  { GT }
  | "<=" { LE }
  | ">=" { GE }
  | "==" { EQ }
  | "!=" { NE }

  | "int"  { INT_TYPE }
  | "char" { CHAR_TYPE }
  | "void" { VOID_TYPE }
  | ':' { COLON }

  | ['0'-'9']+ as i { INT (int_of_string i) }

  | ['a'-'z' 'A'-'Z' '_' ] ['a'-'z' 'A'-'Z' '0'-'9' '_' ]* as id
    { IDENT id }

  | eof { EOF }
