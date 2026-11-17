(* Compiler-owned synchronous byte-I/O descriptors. The two words are private
   to the compiler; source cannot forge or mutate an address/extent pair. *)
open Ast

let read_type = "IoReadSpan"
let write_type = "IoWriteSpan"
let is_type n = n = read_type || n = write_type
let loc = Ast.compiler_loc "io_span"
let names = ["io_read_span"; "io_write_span"; "io_span_length";
             "io_span_end"; "io_readv"; "io_writev"]
let constructor = function
  | "io_read_span" -> Some read_type
  | "io_write_span" -> Some write_type
  | _ -> None

let run prog =
  prog @ List.map (fun name ->
    OwnedStructDef (name, KindLinear, ["loan", TypeUsize],
      ["address", TypeUsize; "length", TypeUsize], false, None,
      ["address"; "length"], false, loc)) [read_type; write_type]
