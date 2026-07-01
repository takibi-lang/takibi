(* Tracks compile-time integer constants declared as immutable globals with a
   literal integer initializer, e.g. `let QUEUE_SIZE: i32 = 16;`.
   Used by the parser to resolve array sizes such as [T; QUEUE_SIZE].

   Constants must be declared before use: this table is populated
   incrementally as the parser consumes top-level items left to right, so a
   name is only resolvable if its `let` appeared earlier in the (possibly
   multi-file, concatenated) source. No forward references, no constant
   folding -- only bare literal initializers are recorded. *)

let table : (string, int) Hashtbl.t = Hashtbl.create 8

let reset () = Hashtbl.reset table

let define name n = Hashtbl.replace table name n

let find name = Hashtbl.find_opt table name

(* Record [name] as a compile-time constant iff it is immutable and its
   initializer is a bare integer literal. Called from the parser action for
   the plain (non-align) global `let` item. *)
let define_if_literal is_mutable name (init_opt : Ast.expr option) =
  if not is_mutable then
    match init_opt with
    | Some { Ast.desc = Ast.IntLit n; _ } -> define name n
    | _ -> ()
