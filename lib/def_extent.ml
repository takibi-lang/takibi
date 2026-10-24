(* Where each function definition ends in its source file (GitHub issue
   #987). Ast.func carries only the definition's start (def_loc); the
   call-graph table behind --emit-call-graph also needs the end, to hash the
   definition's tokens and report its last line. The parser records the end
   here, keyed by the start, and only while [enabled] is set -- so a compile
   without the flag allocates nothing for it.

   A generic function's instances share their template's def_loc (see
   lib/monomorphize.ml), so they share one extent, which is what "a generic
   instance counts once, by definition" needs. *)

let enabled = ref false

let ends : (string * int, Lexing.position) Hashtbl.t = Hashtbl.create 0

let key (pos : Lexing.position) = (Ast.source_file_of_loc pos, pos.Lexing.pos_cnum)

let record (start : Lexing.position) (stop : Lexing.position) =
  if !enabled then Hashtbl.replace ends (key start) stop

let find (start : Lexing.position) = Hashtbl.find_opt ends (key start)
