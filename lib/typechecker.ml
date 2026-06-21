(* Re-export the exception so main.ml can catch Typechecker.TypeError *)
exception TypeError = Types.TypeError

(* Run HM type inference over the whole program.
   Raises TypeError on type errors. *)
let check_toplevels prog =
  ignore (Type_inf.infer_program prog)

let infer_program = Type_inf.infer_program
