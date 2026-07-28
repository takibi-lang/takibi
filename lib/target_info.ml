(* Source-visible target contracts shared by parsing, type checking, and
   lowering.  This module deliberately has no LLVM dependency. *)

type dma_cache_contract =
  | Cache_line of int
  | Coherent
  | Unsupported

(* Inference-only unit tests do not construct an LLVM target and retain the
   historical Cortex-M contract.  The CLI always calls [configure] first. *)
let dma_cache = ref (Cache_line 32)

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
    else Unsupported

let dma_cache_contract () = !dma_cache

let dma_cache_line () =
  match !dma_cache with
  | Cache_line n -> Some n
  | Coherent -> Some 1
  | Unsupported -> None
