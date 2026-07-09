open Takibi

let version =
  match Build_info.V1.version () with
  | Some v -> Build_info.V1.Version.to_string v
  | None -> "unknown (not installed via dune)"

let report_error pos msg =
  let line = pos.Lexing.pos_lnum in
  let col = pos.Lexing.pos_cnum - pos.Lexing.pos_bol + 1 in
  let file = pos.Lexing.pos_fname in
  Printf.eprintf "File \"%s\", line %d, character %d: %s\n" file line col msg

let parse_file filename =
  let chan = open_in filename in
  let lexbuf = Lexing.from_channel chan in
  Lexing.set_filename lexbuf filename;
  let result =
    match Parser.program Lexer.read lexbuf with
    | prog -> prog
    | exception Parser.Error ->
        let pos = Lexing.lexeme_start_p lexbuf in
        close_in chan;
        report_error pos "Syntax error";
        exit 1
  in
  close_in chan;
  result

let () =
  (* Parse arguments: takibi <input>... [-o <output.o>] [--target <triple>]
     [--cpu <cpu>] [--features <features>] [-g] *)
  let input_files  = ref [] in
  let output_file = ref "" in
  let target_triple = ref "" in
  let target_cpu = ref "" in
  let target_features = ref "" in
  let debug_info = ref false in
  let forbid_trap = ref false in
  let show_version = ref false in
  let i = ref 1 in
  while !i < Array.length Sys.argv do
    (match Sys.argv.(!i) with
     | "--version" ->
         show_version := true
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
     | "--cpu" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --cpu requires an argument\n"; exit 1
         );
         target_cpu := Sys.argv.(!i)
     | "--features" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --features requires an argument\n"; exit 1
         );
         target_features := Sys.argv.(!i)
     | "-g" ->
         debug_info := true
     | "--forbid-trap" ->
         forbid_trap := true
     | arg ->
         input_files := arg :: !input_files);
    incr i
  done;
  let input_files = List.rev !input_files in

  if !show_version then (
    Printf.printf "takibi %s\n" version;
    exit 0
  );

  if input_files = [] then (
    Printf.eprintf
      "Usage: %s <filename>... [-o <output.o>] [--target <triple>] [--cpu <cpu>] [--features <features>] [-g] [--forbid-trap] [--version]\n"
      Sys.argv.(0);
    exit 1
  );

  let machine =
    Llvm_gen.setup_target ~triple:!target_triple ~cpu:!target_cpu
      ~features:!target_features ()
  in
  if !debug_info then Llvm_gen.enable_debug_info (List.hd input_files);

  let prescan_file filename =
    let chan = open_in filename in
    let lexbuf = Lexing.from_channel chan in
    Lexing.set_filename lexbuf filename;
    let result = Use_resolver.prescan_uses lexbuf in
    close_in chan;
    result
  in

  (try
    Const_env.reset ();
    Type_layout.reset ();
    (* GitHub issue #55: every file named on the command line is an entry
       point into Use_resolver's `use "path";` closure -- if none of them
       (or anything they transitively `use`) has a single `use`
       declaration, this resolves to exactly `input_files` in the given
       order, so every existing Makefile invocation keeps working
       byte-for-byte unchanged. See Use_resolver's own header comment for
       the full design (ordering, cycle handling, why this doesn't touch
       type_inf.ml/llvm_gen.ml at all). *)
    let resolved =
      try Use_resolver.resolve ~parse_file ~prescan:prescan_file input_files
      with Use_resolver.Use_error msg ->
        Printf.eprintf "Error: %s\n" msg;
        exit 1
    in
    let prog = List.concat_map snd resolved in

    (* HM type inference -- catches type errors and produces resolved types *)
    let prog_types = Typechecker.infer_program prog in

    Llvm_gen.gen_program ~prog_types prog;

    (* --forbid-trap: reject the program if any runtime trap check remains.
       The judgment is what the type system could prove at IR-generation
       time -- deliberately NOT whether LLVM's optimizer would fold a given
       check away later (see Llvm_gen.trap_sites' comment). Every unproven
       site is reported, not just the first, mirroring run_qemutest.sh's
       report-all-failures philosophy. *)
    if !forbid_trap && !Llvm_gen.trap_sites <> [] then begin
      let sites = List.rev !Llvm_gen.trap_sites in
      List.iter (fun (loc, what) -> report_error loc what) sites;
      Printf.eprintf
        "Error: --forbid-trap: %d runtime trap site(s) remain (listed above)\n"
        (List.length sites);
      exit 1
    end;

    if !output_file <> "" then
      Llvm_gen.emit_object machine !output_file
    else
      Llvm.dump_module Llvm_gen.the_module
  with
  | Typechecker.TypeError (loc, msg) ->
      report_error loc msg;
      exit 1)
