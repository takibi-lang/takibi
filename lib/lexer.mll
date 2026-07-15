{
open Parser

(* Accumulate an integer literal's digits directly in Int64 space, silently
   wrapping past 64 bits exactly like the eventual const_int/const_of_int64
   embedding at the literal's target width already does (see CLAUDE.md's
   "64-bit Integer Literals" section) -- written by hand instead of via
   Int64.of_string, which range-checks plain decimal digit strings against
   Int64's SIGNED range (rejecting a perfectly valid u64 value like 2^63)
   and raises Failure past 16 hex digits. Neither restriction matches what
   an integer literal here means: a raw bit pattern, not a signed
   magnitude, with wraparound (not a compile error) beyond 64 bits being an
   already-accepted, astronomically unrealistic edge case for this
   language's widest integer type. *)
let int64_of_digits ~(base : int) (s : string) : Int64.t =
  let digit_val c =
    if c >= '0' && c <= '9' then Char.code c - Char.code '0'
    else if c >= 'a' && c <= 'f' then Char.code c - Char.code 'a' + 10
    else Char.code c - Char.code 'A' + 10
  in
  let base64 = Int64.of_int base in
  String.fold_left
    (fun acc c -> Int64.add (Int64.mul acc base64) (Int64.of_int (digit_val c)))
    0L s
}

rule read = parse
  | [' ' '\t'] { read lexbuf }
  | '\n'       { Lexing.new_line lexbuf; read lexbuf }
  | "//" [^ '\n']* { read lexbuf }   (* Line comment: newline is processed in the next iteration *)
  | "/*"           { read_block_comment lexbuf }

  | "fn"      { FN }
  | "inline"  { INLINE }
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
  | "opaque"  { OPAQUE }
  | "affine"  { AFFINE }
  | "linear"  { LINEAR }
  | "view"    { VIEW }
  | "variant" { VARIANT }
  | "exists"  { EXISTS }
  | "borrow"  { BORROW }
  | "sink"    { SINK }
  | "private" { PRIVATE }
  | "packed"  { PACKED }
  | "io"      { IO }
  | "enum"    { ENUM }
  | "match"   { MATCH }
  | "align"   { ALIGN }
  | "sizeof"  { SIZEOF }
  | "use"     { USE }
  | "offsetof" { OFFSETOF }

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
  | "&=" { AMP_EQ }
  | '&' { AMP }
  | '@' { AT }
  | "=>" { DARROW }    (* Match arm separator. Match before '=' *)
  | "::" { COLONCOLON }  (* Enum variant access. Match before ':' *)

  | "+=" { PLUS_EQ }
  | '+' { PLUS }
  | "->" { ARROW }
  | "-=" { MINUS_EQ }
  | '-' { MINUS }
  | '*' { TIMES }
  | '/' { DIV }
  | '%' { PERCENT }

  | "<<=" { SHL_EQ }
  | "<<" { SHL }
  | "<"  { LT }
  | ">>=" { SHR_EQ }
  | ">>" { SHR }
  | ">"  { GT }
  | "<=" { LE }
  | ">=" { GE }
  | "==" { EQ }
  | "!=" { NE }
  | "||" { OR }
  | "|=" { PIPE_EQ }
  | '|'  { PIPE }
  | "^=" { HAT_EQ }
  | '^'  { HAT }
  | '~'  { TILDE }

  | "bool" { BOOL_TYPE }
  | "unsafe" { UNSAFE }
  | "true"  { TRUE }
  | "false" { FALSE }
  | "i8"   { I8_TYPE  } | "i16"  { I16_TYPE } | "i32"  { I32_TYPE } | "i64"  { I64_TYPE }
  | "u8"   { U8_TYPE  } | "u16"  { U16_TYPE } | "u32"  { U32_TYPE } | "u64"  { U64_TYPE }
  | "isize" { ISIZE_TYPE }
  | "usize" { USIZE_TYPE }
  | ':' { COLON }
  | "..<" { DOTDOTLT }   (* Range separator for {lo..<hi}. Match before '.' *)
  | ".."  { DOTDOT }     (* Open-ended range for slice min length: [u8; 54..].
                            ocamllex longest-match keeps "..<" winning when a '<' follows. *)
  | '.' { DOT }

  | "0x" (['0'-'9' 'a'-'f' 'A'-'F']+ as h) { INT (int64_of_digits ~base:16 h) }
  | (['0'-'9']+ as i) { INT (int64_of_digits ~base:10 i) }

  | '\'' '\\' 'n'  '\'' { INT 10L }
  | '\'' '\\' 'r'  '\'' { INT 13L }
  | '\'' '\\' 't'  '\'' { INT  9L }
  | '\'' '\\' '0'  '\'' { INT  0L }
  | '\'' '\\' '\\' '\'' { INT 92L }
  | '\'' ([^ '\'' '\\' '\n'] as c) '\'' { INT (Int64.of_int (Char.code c)) }

  | '_' { UNDERSCORE }  (* wildcard for match. Longest-match: _foo -> IDENT, _ alone -> UNDERSCORE *)
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
