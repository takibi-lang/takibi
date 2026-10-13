(* Device protocols (GitHub issue #720 option a): a protocol whose retained
   region carries a direction, `retains region(T)[b, N] tx` or `rx`.

   Protocol_decl registers each one while generating its sealed code. The
   generated wrappers call four compiler builtins that only a generated
   protocol file (`<protocol Name>`) may call: the cache work on publishing
   and finishing edges, the device span, and the line-ownership check made
   once in P_init. Type checking and code generation look the protocol up
   here by that file name to learn the element type and the fixed count,
   which together give the region's byte extent. *)

type direction = Tx | Rx

type entry = {
  elem : Ast.type_expr;
  count : int;
  direction : direction;
  loc : Ast.loc;
}

let table : (string, entry) Hashtbl.t = Hashtbl.create 4

(* The generated span functions; a span they return is tied to the borrowed
   owner in their first argument, as dma_device_span's is to its token. *)
let span_functions : (string, unit) Hashtbl.t = Hashtbl.create 8

let reset () =
  Hashtbl.reset table;
  Hashtbl.reset span_functions

let register name entry = Hashtbl.replace table name entry
let register_span_function name = Hashtbl.replace span_functions name ()
let is_span_function name = Hashtbl.mem span_functions name
let any () = Hashtbl.length table > 0

let prefix = "<protocol "

(* The device protocol whose generated file a location is in, if any. *)
let of_loc (loc : Ast.loc) =
  let file = Ast.source_file_of_loc loc in
  let n = String.length prefix in
  if String.length file > n + 1 && String.sub file 0 n = prefix
     && file.[String.length file - 1] = '>' then
    Hashtbl.find_opt table (String.sub file n (String.length file - n - 1))
  else None

(* The builtins the generated wrappers call. *)
let clean = "__protocol_dma_clean"
let prepare_rx = "__protocol_dma_prepare_rx"
let finish_rx = "__protocol_dma_finish_rx"
let span = "__protocol_dma_span"
let own_lines = "__protocol_dma_own_lines"
let builtins = [ clean; prepare_rx; finish_rx; span; own_lines ]
