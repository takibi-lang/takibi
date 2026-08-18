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

(* The TYPE-parameter counterpart of `table`, for array_size's
   `sizeof(...)` case. That case evaluates eagerly at parse time, which
   works for every concrete type but cannot work for a generic's own type
   parameter: `T` has no layout until Monomorphize.run binds it. Knowing
   which names are legally symbolic TYPE parameters is what lets the
   parser tell "defer this one" apart from a genuine typo, and emit
   Ast.ASSizeof instead of failing with "unknown type 'T' in sizeof".

   Same accumulate-forever, whole-program, no-shadowing design as `table`
   above, and for the same reason -- a generic FUNCTION has no parse-time
   scope boundary either. Monomorphize.run's own per-instantiation
   substitution is the real enforcement point: a `T` that does not
   actually belong to the enclosing generic fails there rather than
   silently resolving to something else. *)
let type_table : (string, unit) Hashtbl.t = Hashtbl.create 4

let register_types (names : string list) =
  List.iter (fun n -> Hashtbl.replace type_table n ()) names

let mem_type name = Hashtbl.mem type_table name

(* Does this type mention a generic type parameter anywhere, and so have
   no layout until monomorphization? Deliberately structural rather than
   just checking for a bare `T`, so that `sizeof(Slot(T))` defers too. *)
let rec mentions_type_param (t : Ast.type_expr) : bool =
  match t with
  | Ast.TypeNamed n | Ast.TypeIndexed (n, _) -> mem_type n
  | Ast.TypeGenericInst (n, args) ->
      mem_type n || List.exists mentions_type_param args
  | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeArray (t, _)
  | Ast.TypeSlice (t, _) | Ast.TypeBorrow t | Ast.TypeBorrowMut t
  | Ast.TypeSink t | Ast.TypeRef t | Ast.TypeRefMut t
  | Ast.TypeAlignedPtr (_, t) | Ast.TypeSingleton (t, _)
  | Ast.TypeExists (_, _, t) | Ast.TypeRefined (_, _, t)
  | Ast.TypeArraySym (t, _) | Ast.TypeSliceSym (t, _) ->
      mentions_type_param t
  | Ast.TypeTuple ts -> List.exists mentions_type_param ts
  | Ast.TypeFn (ps, r, _) ->
      List.exists mentions_type_param ps || mentions_type_param r
  | _ -> false
