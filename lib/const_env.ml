(* Tracks compile-time integer constants declared with
   `const QUEUE_SIZE: usize = 16;`. Const declarations are restricted to
   primitive integer types. Used by the parser to resolve array sizes and
   refined bounds such as [T; QUEUE_SIZE] and {0..<QUEUE_SIZE as usize}.

   Constants must be declared before use: this table is populated
   incrementally as the parser consumes top-level items left to right, so a
   name is only resolvable if its `const` appeared earlier in the (possibly
   multi-file, concatenated) source. No forward references and no constant
   folding: only explicit `const` declarations with bare integer literal
   initializers are recorded. *)

let table : (string, int) Hashtbl.t = Hashtbl.create 8

let reset () =
  Hashtbl.reset table;
  Option.iter (fun n -> Hashtbl.replace table "DMA_CACHE_LINE" n)
    (Target_info.dma_cache_line ())

let is_builtin = Language_words.is_predeclared_name

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

(* Fold the small compile-time integer expressions accepted as comparison
   operands by flow-sensitive narrowing. Keep this separate from
   [bound_value]: for-loop counter inference deliberately distinguishes a
   bare literal/const bound from a compound expression, while a comparison
   such as `offset < IMAGE_LEN - BLOCK_SIZE + 1` only needs the expression's
   value at the point the condition is checked.

   Addition/subtraction are the concrete operations needed by bounds written
   in their natural algebraic form. Refuse host-int overflow rather than
   allowing an OCaml wrap to become an unsound range proof. *)
let checked_add a b =
  if (b > 0 && a > max_int - b) || (b < 0 && a < min_int - b)
  then None else Some (a + b)

let checked_sub a b =
  if (b > 0 && a < min_int + b) || (b < 0 && a > max_int + b)
  then None else Some (a - b)

let checked_mul a b =
  if a = 0 || b = 0 then Some 0
  else if (a = min_int && b = -1) || (b = min_int && a = -1) then None
  else
    let product = a * b in
    if product / b = a then Some product else None

let checked_div a b =
  if b = 0 || (a = min_int && b = -1) then None else Some (a / b)

let rec folded_value (e : Ast.expr) =
  match e.Ast.desc with
  | Ast.IntLit n -> Ast.int_of_intlit n
  | Ast.Var name -> find name
  | Ast.BinOp (Ast.Add, a, b) ->
      (match folded_value a, folded_value b with
       | Some x, Some y -> checked_add x y
       | _ -> None)
  | Ast.BinOp (Ast.Sub, a, b) ->
      (match folded_value a, folded_value b with
       | Some x, Some y -> checked_sub x y
       | _ -> None)
  | Ast.BinOp (Ast.Mul, a, b) ->
      (match folded_value a, folded_value b with
       | Some x, Some y -> checked_mul x y
       | _ -> None)
  | Ast.BinOp (Ast.Div, a, b) ->
      (match folded_value a, folded_value b with
       | Some x, Some y -> checked_div x y
       | _ -> None)
  | _ -> None
