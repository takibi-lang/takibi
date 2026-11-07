(* GitHub issue #1159 rule 2: the file declaring `generic struct Atomic`,
   whose atomic_enum_load read-back of a stored enum code needs no runtime
   variant check (llvm_gen.ml). Set by monomorphize.ml. *)
let file : string option ref = ref None
let reset () = file := None
