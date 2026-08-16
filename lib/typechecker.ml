(* Re-export the exceptions so main.ml can catch Typechecker.TypeError /
   Typechecker.MultiTypeError *)
exception TypeError = Types.TypeError
exception MultiTypeError = Types.MultiTypeError

(* Run HM type inference over the whole program.
   Raises TypeError on type errors. *)
let check_toplevels prog =
  ignore (Type_inf.infer_program prog)

let infer_program = Type_inf.infer_program
