/* Project-local bridge to LLVMBuildAtomicCmpXchg, which LLVM 19 exposes in
   llvm-c/Core.h but omits from its OCaml bindings. */
#include <caml/custom.h>
#include <caml/mlvalues.h>
#include <llvm-c/Core.h>

extern value to_val(void *ptr);
extern void *from_val(value v);

#define Value_val(v) ((LLVMValueRef)from_val(v))
#define Builder_val(v) (*(LLVMBuilderRef *)(Data_custom_val(v)))

CAMLprim value takibi_llvm_build_atomic_cmpxchg_native(
    value ptr, value expected, value desired, value success_order,
    value failure_order, value single_thread, value name, value builder) {
  LLVMValueRef instruction = LLVMBuildAtomicCmpXchg(
      Builder_val(builder), Value_val(ptr), Value_val(expected),
      Value_val(desired), Int_val(success_order), Int_val(failure_order),
      Bool_val(single_thread));
  LLVMSetValueName(instruction, String_val(name));
  return to_val(instruction);
}

CAMLprim value takibi_llvm_build_atomic_cmpxchg_bytecode(value *argv,
                                                          int argn) {
  (void)argn;
  return takibi_llvm_build_atomic_cmpxchg_native(
      argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], argv[7]);
}
