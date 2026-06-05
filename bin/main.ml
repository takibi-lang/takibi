open Takibi

let report_error pos msg =
  let line = pos.Lexing.pos_lnum in
  let col = pos.Lexing.pos_cnum - pos.Lexing.pos_bol + 1 in
  let file = pos.Lexing.pos_fname in
  Printf.eprintf "File \"%s\", line %d, character %d: %s\n" file line col msg

let () =
  if Array.length Sys.argv < 2 then (
    Printf.eprintf "Usage: %s <filename>\n" Sys.argv.(0);
    exit 1
  );

  let filename = Sys.argv.(1) in
  let chan = open_in filename in
  let lexbuf = Lexing.from_channel chan in

  Lexing.set_filename lexbuf filename;

  try
    let prog =
      try Parser.program Lexer.read lexbuf with
      | Parser.Error ->
          let pos = Lexing.lexeme_start_p lexbuf in
          report_error pos "Syntax error";
          exit 1
    in

    Typechecker.check_toplevels prog;

    (* C Code *)
    let c_code = Codegen.string_of_program prog in
    print_endline c_code;

    (* LLVM IR *)
    List.iter (function
        | Ast.FuncDef fdef -> ignore (Llvm_gen.gen_func fdef)
        | _ -> ()
      ) prog;
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
