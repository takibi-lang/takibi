(* GitHub issue #55: lightweight `use "path/to/file.tkb";` file
   dependencies, replacing hand-maintained Makefile file lists with a
   compiler-computed closure.

   Deliberately NOT real separate compilation (no per-file .o output, no
   exported "interface" of any kind, no change to type_inf.ml/llvm_gen.ml
   at all): every `.tkb` file this resolves is still concatenated into
   ONE flat AST list and type-checked/codegen'd as a single whole-program
   unit, exactly as `bin/main.ml` already did before this module existed.
   This module's only job is computing WHICH files belong in that list
   and in WHAT ORDER, a job a human previously did by hand in the
   Makefile (see e.g. COMMON_STM32_UART/COMMON_STM32_ETH's file lists).
   Real separate compilation is a much bigger, deliberately separate
   follow-up -- see HISTORY.md's issue #55 entry for the design memo on
   why it's a different scale of problem (this project's whole-program
   refinement-type proof machinery, sizeof(...)/offsetof(...)'s reliance
   on seeing every struct definition, Const_env's cross-file constant
   folding, etc. all currently depend on exactly the whole-program
   visibility this module deliberately preserves).

   Order: a file's `use`d dependencies are fully resolved -- including
   THEIR OWN transitive `use`s -- before the file itself is appended to
   the result. This is a post-order DFS, matching the "dependencies
   first, dependents last" convention every hand-written Makefile file
   list already followed (COMMON_* files first, the example's own file
   last) -- not a style choice, but a genuine correctness requirement:
   Const_env's array-size/for-loop-bound constant resolution happens
   *during parsing* and requires "no forward references" (a name must be
   defined, textually earlier, before anything references it). Getting
   this order right by hand was exactly the toil this feature exists to
   remove; getting it right automatically requires actually preserving
   the same ordering discipline the human convention encoded, not just
   assembling "some list of the right files".

   Cycles are broken, not rejected: a file already being visited (started
   but not yet fully resolved) is treated as already available when
   `use`d again, rather than re-entered or reported as an error. Two
   files whose functions call each other are an ordinary, already-working
   pattern in this compiler's flat-concatenation model (function/struct/
   enum resolution is NOT order-sensitive -- only Const_env-recognized
   constants are), so a strict DAG requirement would reject working code
   for no correctness benefit; the one thing a cycle genuinely cannot
   support -- two files each needing the OTHER's Const_env constant
   defined first -- was already impossible before this feature existed
   (no ordering of a flat concatenation can satisfy it either), so
   nothing already-sound becomes unsound by tolerating the cycle here. *)

exception Use_error of string

(* Lex-only prescan for LEADING `use "path";` declarations, deliberately
   NOT invoking the real parser: parser.mly's grammar actions have
   ordering-sensitive side effects (Const_env.define_if_literal,
   Type_layout.begin_struct/finish_struct/register_enum), so a `use`d
   file's own declarations must be FULLY parsed -- registering all of
   those side effects -- before the file that `use`s it undergoes its
   own real parse. This scan finds just enough to make that recursion
   possible, without triggering any of them itself.

   Deliberately lenient on malformed syntax: on anything unexpected (a
   `use` not followed by a string and a semicolon, or a non-`use` token
   ending the leading run), this simply stops and returns whatever full
   `use` declarations were found before that point. It does not try to
   diagnose the malformed syntax itself -- the real parser, which this
   file will still go through in full via parse_file, is the authoritative
   source of syntax errors and already reports them with an exact
   position; duplicating that here would be redundant and could disagree
   with the real parser's own judgment about what's malformed. *)
let prescan_uses (lexbuf : Lexing.lexbuf) : string list =
  let rec loop acc =
    match Lexer.read lexbuf with
    | Parser.USE ->
        (match Lexer.read lexbuf with
         | Parser.STRING path ->
             (match Lexer.read lexbuf with
              | Parser.SEMI -> loop (path :: acc)
              | _ -> List.rev acc)
         | _ -> List.rev acc)
    | _ -> List.rev acc
    | exception _ -> List.rev acc
  in
  loop []

(* Every UseDef item in a fully-parsed file's AST must be a prefix of the
   item list -- a `use` appearing after any other item would otherwise be
   silently ineffective (prescan_uses only ever looks at LEADING tokens,
   so a later `use` would still parse successfully as an ordinary item
   but never actually be pulled into the resolved file set). Rejecting
   this outright, rather than accepting it as a no-op, is this project's
   usual "detect errors at compile time" discipline applied to this
   feature's one way of failing silently instead of loudly. *)
let check_uses_are_leading filename (items : Ast.toplevel list) =
  let rec go seen_other = function
    | [] -> ()
    | Ast.UseDef _ :: _ when seen_other ->
        raise (Use_error (Printf.sprintf
          "%s: `use` declarations must appear before any other item in the file"
          filename))
    | Ast.UseDef _ :: rest -> go seen_other rest
    | _ :: rest -> go true rest
  in
  go false items

(* resolve ~parse_file ~prescan entry_paths: the full DFS closure
   described above. parse_file/prescan are dependency-injected (rather
   than doing file I/O directly in this module) so the ordering algorithm
   itself is unit-testable against an in-memory fake filesystem, without
   needing real files on disk -- see test_takibi.ml's use_resolver_tests. *)
let resolve
    ~(parse_file : string -> Ast.toplevel list)
    ~(prescan : string -> string list)
    (entry_paths : string list)
    : (string * Ast.toplevel list) list =
  let visited = Hashtbl.create 16 in
  let in_progress = Hashtbl.create 16 in
  let order = ref [] in
  let rec visit path =
    if Hashtbl.mem visited path || Hashtbl.mem in_progress path then ()
    else begin
      Hashtbl.add in_progress path ();
      List.iter visit (prescan path);
      let items = parse_file path in
      check_uses_are_leading path items;
      Hashtbl.remove in_progress path;
      Hashtbl.add visited path ();
      order := (path, items) :: !order
    end
  in
  List.iter visit entry_paths;
  List.rev !order
