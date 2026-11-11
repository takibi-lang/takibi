// Enable the frame metadata option missing from LLVM 19's public C API.
#include <llvm-c/TargetMachine.h>
#include <llvm/Config/llvm-config.h>
#include <llvm/Target/TargetMachine.h>

#include <caml/custom.h>
#include <caml/mlvalues.h>

static_assert(LLVM_VERSION_MAJOR == 19, "review the LLVM TargetMachine ABI");

// LLVM 19's OCaml target binding stores LLVMTargetMachineRef in a custom
// block. The C target binding wraps llvm::TargetMachine* as that opaque ref.
extern "C" CAMLprim value takibi_llvm_enable_stack_size_section(value machine) {
  auto ref = *static_cast<LLVMTargetMachineRef *>(Data_custom_val(machine));
  reinterpret_cast<llvm::TargetMachine *>(ref)->Options.EmitStackSizeSection = true;
  return Val_unit;
}
