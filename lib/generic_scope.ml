(* Tracks which value-parameter names (e.g. `N` in
   `generic struct Freelist(T: type, N: usize)`) are legally SYMBOLIC in
   array_size's IDENT fallback -- name-only (no type/value stored), since
   that fallback only needs "is this name legally symbolic somewhere",
   not what it resolves to (resolution happens later, at monomorphization,
   once a concrete value argument is known).

   Mirrors const_env.ml's own accumulate-forever design (populated
   incrementally as the parser consumes items left to right, never reset
   mid-file): registered once, when a `generic struct(...)`'s own value
   parameters are parsed, and never un-registered. This is deliberately
   NOT scoped to one struct's own field list -- a generic FUNCTION's
   parameter list may also need to spell a value parameter symbolically
   in array-size position (e.g. `fn freelist_init(T: type, target:
   *Freelist(T, N), data_backing: [T; N..])`, Freelist redesign follow-
   up), but a plain `fn` has no dedicated grammar marking it "generic" at
   parse time at all (genericity is discovered structurally, later, by
   Monomorphize.run) -- there is no per-function scope boundary the
   parser could reliably enter/exit around. Whole-program registration
   sidesteps that: once `N` is known to be SOME generic struct's value
   parameter name anywhere in the file, it is accepted as symbolic
   syntax everywhere, and Monomorphize.run's own per-instantiation
   `vsubst` is the real enforcement point (an `N` that doesn't actually
   belong to the enclosing struct/function's own value parameters fails
   there with "unresolved symbolic ... escaped monomorphization", not
   silently). Same accepted-imprecision tradeoff as Const_env's own
   flat, no-shadowing-awareness design. *)

let table : (string, unit) Hashtbl.t = Hashtbl.create 4

let register (names : string list) =
  List.iter (fun n -> Hashtbl.replace table n ()) names

let mem name = Hashtbl.mem table name
