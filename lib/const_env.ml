(* Tracks compile-time integer constants declared with
   `const QUEUE_SIZE: usize = 16;`. Used by the parser to resolve array
   sizes and refined bounds such as [T; QUEUE_SIZE] and
   {0..<QUEUE_SIZE as usize}.

   Constants must be declared before use: this table is populated
   incrementally as the parser consumes top-level items left to right, so a
   name is only resolvable if its `const` appeared earlier in the (possibly
   multi-file, concatenated) source. No forward references and no constant
   folding: only explicit `const` declarations with bare integer literal
   initializers are recorded. *)

let table : (string, int) Hashtbl.t = Hashtbl.create 8

let reset () =
  Hashtbl.reset table

let define name n = Hashtbl.replace table name n

let find name = Hashtbl.find_opt table name

(* Record [name] as a compile-time constant iff its initializer is a bare
   integer literal. Called only from the parser action for `const`. *)
let define_if_literal name (init_opt : Ast.expr option) =
  match init_opt with
  | Some { Ast.desc = Ast.IntLit n; _ } ->
      (* IntLit's Int64.t payload can hold a genuinely 64-bit value, but
         this table only ever backs small-number proof sites. A value too
         large to narrow safely (see Ast.int_of_intlit) is simply not
         recorded, exactly as if it were never a valid small constant. *)
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
