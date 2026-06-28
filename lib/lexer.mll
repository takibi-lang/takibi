{
open Parser
}

rule read = parse
  | [' ' '\t'] { read lexbuf }
  | '\n'       { Lexing.new_line lexbuf; read lexbuf }
  | "//" [^ '\n']* { read lexbuf }   (* Line comment: newline is processed in the next iteration *)
  | "/*"           { read_block_comment lexbuf }

  | "fn"      { FN }
  | "return"  { RETURN }
  | "let"     { LET }
  | "mut"     { MUT }
  | "if"      { IF }
  | "else"    { ELSE }
  | "while"    { WHILE }
  | "for"      { FOR }
  | "in"       { IN }
  | "break"    { BREAK }
  | "continue" { CONTINUE }
  | "as"      { AS }
  | "void"    { VOID_TYPE }
  | "extern"  { EXTERN }
  | "struct"  { STRUCT }
  | "io"      { IO }

  | '{' { LBRACE }
  | '}' { RBRACE }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | '[' { LBRACKET }
  | ']' { RBRACKET }
  | ',' { COMMA }
  | ';' { SEMI }
  | '=' { ASSIGN }
  | "&&" { DAMP }   (* Logical AND. Match before '&' *)
  | '&' { AMP }

  | '+' { PLUS }
  | "->" { ARROW }
  | '-' { MINUS }
  | '*' { TIMES }
  | '/' { DIV }
  | '%' { PERCENT }

  | "<<" { SHL }
  | "<"  { LT }
  | ">>" { SHR }
  | ">"  { GT }
  | "<=" { LE }
  | ">=" { GE }
  | "==" { EQ }
  | "!=" { NE }
  | "||" { OR }
  | '|'  { PIPE }
  | '^'  { HAT }

  | "int"  { INT_TYPE }
  | "char" { CHAR_TYPE }
  | ':' { COLON }
  | "..<" { DOTDOTLT }   (* Range separator for {lo..<hi}. Match before '.' *)
  | '.' { DOT }

  | "0x" ['0'-'9' 'a'-'f' 'A'-'F']+ as h { INT (int_of_string h) }
  | ['0'-'9']+ as i { INT (int_of_string i) }

  | '\'' '\\' 'n'  '\'' { INT 10 }
  | '\'' '\\' 'r'  '\'' { INT 13 }
  | '\'' '\\' 't'  '\'' { INT  9 }
  | '\'' '\\' '0'  '\'' { INT  0 }
  | '\'' '\\' '\\' '\'' { INT 92 }
  | '\'' ([^ '\'' '\\' '\n'] as c) '\'' { INT (Char.code c) }

  | ['a'-'z' 'A'-'Z' '_' ] ['a'-'z' 'A'-'Z' '0'-'9' '_' ]* as id
    { IDENT id }

  | '"' { read_string (Buffer.create 32) lexbuf }

  | eof { EOF }

and read_block_comment = parse
  | "*/"   { read lexbuf }
  | '\n'   { Lexing.new_line lexbuf; read_block_comment lexbuf }
  | _      { read_block_comment lexbuf }
  | eof    { failwith "unterminated block comment" }

and read_string buf = parse
  | '"'        { STRING (Buffer.contents buf) }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_string buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_string buf lexbuf }
  | '\\' '"'  { Buffer.add_char buf '"';  read_string buf lexbuf }
  | _ as c    { Buffer.add_char buf c;    read_string buf lexbuf }
  | eof       { failwith "unterminated string literal" }
