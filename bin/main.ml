open Takibi

let report_error pos msg =
  let line = pos.Lexing.pos_lnum in
  let col = pos.Lexing.pos_cnum - pos.Lexing.pos_bol + 1 in
  let file = pos.Lexing.pos_fname in
  Printf.eprintf "File \"%s\", line %d, character %d: %s\n" file line col msg

let () =
  (* Parse arguments: takibi <input> [-o <output.o>] [--target <triple>] *)
  let input_file  = ref "" in
  let output_file = ref "" in
  let target_triple = ref "" in
  let i = ref 1 in
  while !i < Array.length Sys.argv do
    (match Sys.argv.(!i) with
     | "-o" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: -o requires an argument\n"; exit 1
         );
         output_file := Sys.argv.(!i)
     | "--target" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --target requires an argument\n"; exit 1
         );
         target_triple := Sys.argv.(!i)
     | arg ->
         if !input_file = "" then input_file := arg
         else (Printf.eprintf "Unexpected argument: %s\n" arg; exit 1));
    incr i
  done;

  if !input_file = "" then (
    Printf.eprintf "Usage: %s <filename> [-o <output.o>] [--target <triple>]\n"
      Sys.argv.(0);
    exit 1
  );

  let machine = Llvm_gen.setup_target ~triple:!target_triple () in

  let chan   = open_in !input_file in
  let lexbuf = Lexing.from_channel chan in
  Lexing.set_filename lexbuf !input_file;

  try
    let prog =
      try Parser.program Lexer.read lexbuf with
      | Parser.Error ->
          let pos = Lexing.lexeme_start_p lexbuf in
          report_error pos "Syntax error";
          exit 1
    in

    (* HM type inference -- catches type errors and produces resolved types *)
    let prog_types = Typechecker.infer_program prog in

    Llvm_gen.gen_program ~prog_types prog;

    if !output_file <> "" then
      Llvm_gen.emit_object machine !output_file
    else
      Llvm.dump_module Llvm_gen.the_module;

    close_in chan
  with
  | Typechecker.TypeError (loc, msg) ->
      report_error loc msg;
      close_in chan;
      exit 1
  | e ->
      close_in chan;
      raise e
