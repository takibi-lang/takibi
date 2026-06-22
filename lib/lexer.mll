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
  | '&' { AMP }

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
  | ':' { COLON }

  | "0x" ['0'-'9' 'a'-'f' 'A'-'F']+ as h { INT (int_of_string h) }
  | ['0'-'9']+ as i { INT (int_of_string i) }

  | ['a'-'z' 'A'-'Z' '_' ] ['a'-'z' 'A'-'Z' '0'-'9' '_' ]* as id
    { IDENT id }

  | '"' { read_string (Buffer.create 32) lexbuf }

  | eof { EOF }

and read_string buf = parse
  | '"'        { STRING (Buffer.contents buf) }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_string buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_string buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"';  read_string buf lexbuf }
  | _ as c    { Buffer.add_char buf c;    read_string buf lexbuf }
  | eof       { failwith "unterminated string literal" }
