(* Tracks compile-time integer constants declared as immutable globals with a
   literal integer initializer, e.g. `let QUEUE_SIZE: i32 = 16;`.
   Used by the parser to resolve array sizes such as [T; QUEUE_SIZE].

   Constants must be declared before use: this table is populated
   incrementally as the parser consumes top-level items left to right, so a
   name is only resolvable if its `let` appeared earlier in the (possibly
   multi-file, concatenated) source. No forward references, no constant
   folding -- only bare literal initializers are recorded. *)

let table : (string, int) Hashtbl.t = Hashtbl.create 8

let reset () =
  Hashtbl.reset table

let define name n = Hashtbl.replace table name n

let find name = Hashtbl.find_opt table name

(* Record [name] as a compile-time constant iff it is immutable and its
   initializer is a bare integer literal. Called from the parser action for
   the plain (non-align) global `let` item. *)
let define_if_literal is_mutable name (init_opt : Ast.expr option) =
  if not is_mutable then
    match init_opt with
    | Some { Ast.desc = Ast.IntLit n; _ } ->
        (* IntLit's Int64.t payload can hold a genuinely 64-bit value, but
           this table only ever backs array sizes and for-loop bounds
           (always small); a value too large to narrow safely (see
           Ast.int_of_intlit) is simply not recorded, exactly as if it were
           never a bare-literal-initialized constant at all -- each
           consumer already has a sound fallback for that (array_size's
           "not a known compile-time integer constant" error, or
           bound_value's conservative unrefined case). *)
        (match Ast.int_of_intlit n with
         | Some i -> define name i
         | None -> ())
    | _ -> ()

(* Resolve a for-loop bound to a compile-time integer when possible: a bare
   literal, or the name of a recorded constant. Shared by type_inf.ml (For's
   TRefinedInt decision) and llvm_gen.ml (For's TypeRefined decision) so the
   two sides can never drift apart -- same sync concern as the Mod range
   rule's lo >= 0 guard documented in CLAUDE.md.
   Soundness precondition: a `Var` here must actually denote the global
   constant, not a local shadowing it. That is guaranteed by
   Type_inf.check_const_shadowing, which rejects any local let / parameter /
   for-counter reusing a recorded constant name (this table is name-only,
   with no scope information, so shadowing would silently refine against the
   global's value while the loop runs to the local's -- an unsound
   bounds-check elision). *)
let bound_value (e : Ast.expr) =
  match e.Ast.desc with
  | Ast.IntLit n -> Ast.int_of_intlit n
  | Ast.Var name -> find name
  | _ -> None
