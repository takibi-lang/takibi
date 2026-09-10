(* Narrow project-local bindings for LLVM C APIs absent from LLVM 19's OCaml
   package. Keep this surface caller-driven rather than mirroring Core.h. *)

external build_atomic_cmpxchg :
  Llvm.llvalue -> Llvm.llvalue -> Llvm.llvalue ->
  Llvm.AtomicOrdering.t -> Llvm.AtomicOrdering.t -> bool -> string ->
  Llvm.llbuilder -> Llvm.llvalue
  = "takibi_llvm_build_atomic_cmpxchg_bytecode"
    "takibi_llvm_build_atomic_cmpxchg_native"
