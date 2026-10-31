(* GitHub issue #1010: a source file as the compiler's own lexer sees it,
   with everything the lexer skips kept beside the tokens.

   The AST alone cannot drive a formatter. The parser folds `[u8; N * 2]` to a
   literal, turns `x += e` into an assignment, forgets how a literal was
   spelled, and records `no_copy` or `requires` in a registry rather than in a
   node, so `parse(print(parse f)) = parse f` can hold while all of that is
   erased. The oracle here is the surface instead: two sources are the same
   program text when their token spellings, comments and blank-line groups are
   equal, in order. Equal spellings give equal tokens and the parser reads only
   tokens, so this is stronger than comparing ASTs.

   There is no second lexer: [of_string] drives Lexer.read and treats the bytes
   between two consecutive tokens as trivia. A gap holding anything but blanks,
   newlines and comments is an error, not something to skip. *)

type comment_kind = Line_comment | Block_comment

type comment = {
  kind : comment_kind;
  text : string;  (* with its delimiters, and verbatim *)
}

type trivia =
  | Comment of comment
  | Blank_lines of int  (* this many empty lines, at least one *)

type token = {
  token : Parser.token;
  spelling : string;
  (* Comments and blank lines from the end of the previous token's line to
     this token; a formatter attaches them to whatever this token starts. *)
  leading : trivia list;
  (* Comments on this token's own line, after it. *)
  trailing : comment list;
}

type t = {
  tokens : token list;
  (* What follows the last token's line. *)
  eof_leading : trivia list;
}

(* The lexer takes `borrow init ` as one token including the blank that ends
   it, however many blanks separate its words. Only the words are spelling. *)
let normalized_spelling (token : Parser.token) raw =
  match token with
  | Parser.BORROW_INIT -> "borrow init"
  | Parser.BORROW_UNINIT -> "borrow uninit"
  | _ -> raw

(* Split one gap. Returns the comments on the line the previous token ended
   and the trivia after that line. [at_file_start] is true only for the gap
   before a file's first token, which has no previous line to finish. *)
let classify_gap ~at_file_start gap =
  let len = String.length gap in
  let trailing = ref [] and leading = ref [] in
  let line_ended = ref at_file_start in
  (* Newlines since the last comment or the previous token. At a file's start
     the first newline already closes an empty line, hence the head start. *)
  let newlines = ref (if at_file_start then 1 else 0) in
  let flush_blanks () =
    if !newlines >= 2 then leading := Blank_lines (!newlines - 1) :: !leading;
    newlines := 0
  in
  let add_comment c =
    if !line_ended then begin
      flush_blanks ();
      leading := Comment c :: !leading
    end else begin
      trailing := c :: !trailing;
      newlines := 0
    end
  in
  let rec go i =
    if i >= len then ()
    else match gap.[i] with
      | ' ' | '\t' -> go (i + 1)
      | '\n' ->
          incr newlines;
          line_ended := true;
          go (i + 1)
      | '/' when i + 1 < len && gap.[i + 1] = '/' ->
          let stop = Option.value (String.index_from_opt gap i '\n') ~default:len in
          add_comment { kind = Line_comment; text = String.sub gap i (stop - i) };
          go stop
      | '/' when i + 1 < len && gap.[i + 1] = '*' ->
          let rec close j =
            if j + 1 >= len then failwith "a block comment does not close inside its gap"
            else if gap.[j] = '*' && gap.[j + 1] = '/' then j + 2
            else close (j + 1)
          in
          let stop = close (i + 2) in
          add_comment { kind = Block_comment; text = String.sub gap i (stop - i) };
          go stop
      | c ->
          failwith (Printf.sprintf "byte %C between two tokens is neither blank nor comment" c)
  in
  go 0;
  flush_blanks ();
  (List.rev !trailing, List.rev !leading)

let of_string ?(fname = "<string>") source : (t, string) result =
  let lexbuf = Lexing.from_string source in
  Lexing.set_filename lexbuf fname;
  let position () =
    let p = lexbuf.Lexing.lex_curr_p in
    Printf.sprintf "%s:%d:%d" fname p.Lexing.pos_lnum
      (p.Lexing.pos_cnum - p.Lexing.pos_bol + 1)
  in
  (* Built newest first; [pending] is the newest token, whose trailing comments
     are only known once the next gap has been read. *)
  let rec go acc pending previous_stop =
    let token = Lexer.read lexbuf in
    let start = match token with
      | Parser.STRING _ | Parser.BS_STRING _ -> !Lexer.last_string_start
      | Parser.EOF -> String.length source
      | _ -> Lexing.lexeme_start lexbuf
    in
    let stop = Lexing.lexeme_end lexbuf in
    let gap = String.sub source previous_stop (start - previous_stop) in
    let trailing, leading = classify_gap ~at_file_start:(pending = None) gap in
    let acc = match pending with
      | Some previous -> { previous with trailing } :: acc
      | None -> acc
    in
    match token with
    | Parser.EOF -> { tokens = List.rev acc; eof_leading = leading }
    | _ ->
        let spelling =
          normalized_spelling token (String.sub source start (stop - start)) in
        go acc (Some { token; spelling; leading; trailing = [] }) stop
  in
  match go [] None 0 with
  | t -> Ok t
  | exception Failure message -> Error (position () ^ ": " ^ message)

(* Same program text: the oracle a formatter's output has to meet. Layout is
   the only thing it does not compare. *)
let same_surface a b =
  a.eof_leading = b.eof_leading
  && List.compare_lengths a.tokens b.tokens = 0
  && List.for_all2
       (fun x y ->
          x.spelling = y.spelling && x.leading = y.leading && x.trailing = y.trailing)
       a.tokens b.tokens

(* One token per line. Not a style: the layout furthest from any source, used
   to prove that the classification above loses nothing and that no two tokens
   depend on their adjacency. *)
let one_token_per_line t =
  let b = Buffer.create 4096 in
  let add_trivia = function
    | Blank_lines n -> Buffer.add_string b (String.make n '\n')
    | Comment c -> Buffer.add_string b c.text; Buffer.add_char b '\n'
  in
  List.iter
    (fun tok ->
       List.iter add_trivia tok.leading;
       Buffer.add_string b tok.spelling;
       (* The one adjacency there is: `borrow init` is a token only with a
          blank after it, never a newline, so a formatter must not break there. *)
       (match tok.token with
        | Parser.BORROW_INIT | Parser.BORROW_UNINIT -> Buffer.add_char b ' '
        | _ -> ());
       List.iter (fun c -> Buffer.add_char b ' '; Buffer.add_string b c.text) tok.trailing;
       Buffer.add_char b '\n')
    t.tokens;
  List.iter add_trivia t.eof_leading;
  Buffer.contents b

(* The whole-tree check behind `make fmt-surface-control`: the source survives
   the layout above with its surface equal. *)
let check_round_trip ?fname source =
  match of_string ?fname source with
  | Error _ as e -> e
  | Ok original ->
      (match of_string ?fname (one_token_per_line original) with
       | Error message -> Error ("after relayout: " ^ message)
       | Ok relaid when same_surface original relaid -> Ok original
       | Ok _ -> Error "the surface changed under relayout")

module Counts = Map.Make (String)

let bump key counts =
  Counts.update key (fun n -> Some (Option.value n ~default:0 + 1)) counts

(* Counts of what an AST-only printer would have to recover, for sizing the
   work: every keyword and operator by spelling, literals by how they were
   written, and comments and blank groups. *)
let census counts t =
  let of_comment prefix counts c =
    bump (prefix ^ (match c.kind with Line_comment -> "line" | Block_comment -> "block")) counts
  in
  let of_trivia counts = function
    | Comment c -> of_comment "comment:own-line:" counts c
    | Blank_lines _ -> bump "blank-group" counts
  in
  let token_class tok =
    match tok.token with
    | Parser.IDENT _ -> "ident"
    | Parser.STRING _ -> "literal:string"
    | Parser.BS_STRING _ -> "literal:byte-string"
    | Parser.INT _ ->
        if String.starts_with ~prefix:"0x" tok.spelling then "literal:hex"
        else if tok.spelling.[0] = '\'' then "literal:char"
        else "literal:decimal"
    | _ -> tok.spelling
  in
  let counts =
    List.fold_left
      (fun counts tok ->
         let counts = List.fold_left of_trivia counts tok.leading in
         let counts = List.fold_left (of_comment "comment:trailing:") counts tok.trailing in
         bump (token_class tok) counts)
      counts t.tokens
  in
  List.fold_left of_trivia counts t.eof_leading
