(* Source-visible target contracts shared by parsing, type checking, and
   lowering.  This module deliberately has no LLVM dependency. *)

type dma_cache_contract =
  | Cache_line of int
  | Coherent
  | Unsupported

(* GitHub issue #227 item 2: how many hardware exception vector slots a
   `vector_table { N => target; ... }` declaration must list, exhaustively,
   for the selected target -- an architecture fact (AArch64's VBAR_ELn
   covers exactly 16: 4 exception classes x 4 sources), not a language one.
   `Unsupported` targets reject `vector_table` at type-check time, same
   shape as `dma_cache_contract`'s `Unsupported` case just below -- neither
   AMD64 nor RISC-V has this declared yet (issue #227's own Non-goal: other
   ports are free to declare their own when they need one). *)
type vector_table_contract =
  | Fixed_slots of int
  | Unsupported

(* Inference-only unit tests do not construct an LLVM target and retain the
   historical Cortex-M contract.  The CLI always calls [configure] first. *)
let dma_cache = ref (Cache_line 32)
let vector_table = ref Unsupported

let reset () =
  dma_cache := Cache_line 32;
  vector_table := Unsupported

let starts_with s prefix =
  let n = String.length prefix in
  String.length s >= n && String.sub s 0 n = prefix

let configure triple =
  dma_cache :=
    if starts_with triple "aarch64" then Cache_line 64
    else if starts_with triple "arm" || starts_with triple "thumb" then
      Cache_line 32
    else if starts_with triple "x86_64" || starts_with triple "i386"
         || starts_with triple "i486" || starts_with triple "i586"
         || starts_with triple "i686" then Coherent
    else Unsupported;
  vector_table :=
    if starts_with triple "aarch64" then Fixed_slots 16
    else Unsupported

let dma_cache_contract () = !dma_cache
let vector_table_contract () = !vector_table

let dma_cache_line () =
  match !dma_cache with
  | Cache_line n -> Some n
  | Coherent -> Some 1
  | Unsupported -> None
