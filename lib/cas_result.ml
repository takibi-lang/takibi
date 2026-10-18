(* GitHub issue #613: the compiler-declared result of a compare-and-swap,
   `must_use variant CasResult { Swapped; Observed(usize); }`. Observed
   carries the value the failing instruction itself read, so a caller never
   needs a second load to learn why the swap failed. must_use and variant
   exhaustiveness make the caller handle both cases. Declared once by the
   compiler, so a source declaration of the same name is a duplicate
   top-level name error. *)

open Ast

let loc = Ast.compiler_loc "cas_result"

let cases = [
  Atomic_spec.cas_swapped, None;
  Atomic_spec.cas_observed, Some TypeUsize;
]

let run (prog : toplevel list) : toplevel list =
  Type_layout.register_variant Atomic_spec.cas_result_type cases;
  prog @ [VariantDef (Atomic_spec.cas_result_type, [], cases, true, loc)]
