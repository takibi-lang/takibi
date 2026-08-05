(* Tracks which value-parameter names (e.g. `N` in
   `generic struct Freelist(T: type, N: usize)`) are currently in scope
   while the parser is inside ONE generic struct's own field list --
   mirrors const_env.ml's shape, but deliberately name-only (no type/
   value stored) since array_size's IDENT fallback only needs "is this
   name legally symbolic here", not what it resolves to (resolution
   happens later, at monomorphization, once a concrete value argument is
   known). Entered/exited around a single generic_struct_intro's body;
   never nested (generic struct definitions cannot nest), so a flat
   reset-on-enter table is sufficient -- no save/restore stack needed. *)

let table : (string, unit) Hashtbl.t = Hashtbl.create 4

let enter (names : string list) =
  Hashtbl.reset table;
  List.iter (fun n -> Hashtbl.replace table n ()) names

let exit_scope () = Hashtbl.reset table

let mem name = Hashtbl.mem table name
