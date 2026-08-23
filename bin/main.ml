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
     [--cpu <cpu>] [--features <features>] [-g] [--profile-functions] *)
  let input_files  = ref [] in
  let output_file = ref "" in
  let target_triple = ref "" in
  let target_cpu = ref "" in
  let target_features = ref "" in
  let debug_info = ref false in
  let forbid_trap = ref false in
  let forbid_unsafe = ref false in
  let profile_functions = ref false in
  let show_version = ref false in
  let emit_exception_frame_offsets = ref "" in
  let emit_struct_layout = ref "" in
  let emit_depfile = ref "" in
  let i = ref 1 in
  while !i < Array.length Sys.argv do
    (match Sys.argv.(!i) with
     | "--version" ->
         show_version := true
     | "--emit-exception-frame-offsets" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-exception-frame-offsets requires a struct name\n";
           exit 1
         );
         emit_exception_frame_offsets := Sys.argv.(!i)
     | "--emit-struct-layout" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-struct-layout requires a struct name\n";
           exit 1
         );
         emit_struct_layout := Sys.argv.(!i)
     | "--emit-depfile" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-depfile requires a path\n";
           exit 1
         );
         emit_depfile := Sys.argv.(!i)
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
     | "--forbid-unsafe" ->
         forbid_unsafe := true
     | "--profile-functions" ->
         profile_functions := true
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
      "Usage: %s <filename>... [-o <output.o>] [--target <triple>] [--cpu <cpu>] [--features <features>] [-g] [--profile-functions] [--forbid-trap] [--forbid-unsafe] [--emit-exception-frame-offsets <StructName>] [--emit-struct-layout <StructName>] [--emit-depfile <path>] [--version]\n"
      Sys.argv.(0);
    exit 1
  );

  let machine =
    Llvm_gen.setup_target ~triple:!target_triple ~cpu:!target_cpu
      ~features:!target_features ()
  in
  if !debug_info then Llvm_gen.enable_debug_info (List.hd input_files);
  Llvm_gen.set_function_profiling !profile_functions;

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
    Generic_scope.reset ();
    Ast.reset_precedence_errors ();
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
    (* GitHub issue #306: Use_resolver.resolve already computed the exact,
       correctly-ordered `use` closure above -- the only thing missing for
       Make's own staleness tracking to be as accurate as the compiler's is
       surfacing that closure to a file. Written before any later stage can
       fail, so a compile error still leaves a depfile behind reflecting
       what was actually read -- Make should still treat a target as
       depending on a file that caused a real compile error the next time
       that file changes. *)
    if !emit_depfile <> "" then
      Use_resolver.write_depfile !emit_depfile !output_file
        (List.map fst resolved);

    let prog = List.concat_map snd resolved in

    if !Ast.precedence_error_sites <> [] then begin
      let sites = List.rev !Ast.precedence_error_sites in
      List.iter (fun (loc, what) -> report_error loc what) sites;
      Printf.eprintf
        "Error: %d ambiguous bitwise/comparison expression(s) require explicit parentheses\n"
        (List.length sites);
      exit 1
    end;

    (* GitHub issue #207: compile-time generics. Expands every
       `generic struct` template actually instantiated into an ordinary,
       fully concrete StructDef under a mangled name, before type
       inference/codegen ever run -- so everything downstream keeps seeing
       only plain, already-monomorphic code, exactly like today. A no-op
       (returns prog unchanged) for any program with no generic struct
       templates at all. *)
    let prog = Monomorphize.run prog in

    (* HM type inference -- catches type errors and produces resolved types *)
    let prog_types = Typechecker.infer_program prog in

    if !forbid_unsafe then begin
      let unsafe_functions = Types.StringMap.bindings prog_types.functions
        |> List.filter_map (fun (name, info) ->
          if List.mem "unsafe" info.Types.effects then Some name else None)
      in
      if unsafe_functions <> [] then begin
        List.iter (fun name ->
          let message = Printf.sprintf
            "--forbid-unsafe: function '%s' has a reachable unsafe effect" name in
          match Type_inf.inferred_effect_location name with
          | Some loc -> report_error loc message
          | None -> Printf.eprintf "Error: %s\n" message) unsafe_functions;
        exit 1
      end
    end;

    Llvm_gen.gen_program ~prog_types prog;

    (* GitHub issue #362: the three layout implementations must still
       agree. llvm_gen already checks its own OCaml formula against the
       DataLayout at every sizeof; this checks the third one, which array
       sizes use at parse time and which nothing had been comparing. See
       Type_layout.check_against_codegen for what drifted and for how
       long. *)
    Type_layout.check_against_codegen ();

    (* GitHub issue #286 follow-up (2026-08-13): dump a struct's field
       offsets as GAS `.equ` constants instead of emitting an object file.
       This exists so a hand-written assembly consumer (kernel/arch/arm64/
       kernel/exception_context.inc's `.include`d exception_context_offsets.
       inc, generated by scripts/gen_exception_frame.py) reads offsets
       computed by THIS function -- the same one exception_entry/
       exception_restore codegen already calls -- instead of a second,
       independently-maintained Python reimplementation of the same
       packed-struct layout algorithm (and of parsing the struct's `.tkb`
       syntax in the first place, via regex). gen_program has already run
       by this point, so struct_fields/exception_frame_offsets reflect the
       real, type-checked struct -- not a fresh, potentially-diverging
       recomputation. Placed before --forbid-trap/object emission: this is
       an alternate, terminal output mode, not a compile pass. *)
    if !emit_exception_frame_offsets <> "" then begin
      let struct_name = !emit_exception_frame_offsets in
      let fields = match Hashtbl.find_opt Llvm_gen.struct_fields struct_name with
        | Some fs -> fs
        | None ->
            Printf.eprintf "Error: --emit-exception-frame-offsets: no struct named '%s'\n"
              struct_name;
            exit 1
      in
      let (off, total) =
        Llvm_gen.exception_frame_offsets "cli" "--emit-exception-frame-offsets" struct_name
      in
      let buf = Buffer.create 4096 in
      Printf.ksprintf (Buffer.add_string buf)
        "/* GENERATED by `%s --emit-exception-frame-offsets %s ...` from the\n"
        Sys.argv.(0) struct_name;
      Printf.ksprintf (Buffer.add_string buf)
        " * '%s' struct's own declared field order and type_inf.ml-validated\n"
        struct_name;
      Buffer.add_string buf
        " * layout -- the same computation exception_entry/exception_restore\n";
      Buffer.add_string buf
        " * codegen uses internally. Do not edit by hand.\n */\n";
      Printf.ksprintf (Buffer.add_string buf) "    .equ EXC_CONTEXT_SIZE,          0x%x\n" total;
      List.iter (fun (fname, _fty) ->
        Printf.ksprintf (Buffer.add_string buf) "    .equ EXC_CONTEXT_%s,          0x%03x\n"
          (String.uppercase_ascii fname) (off fname)
      ) fields;
      if !output_file <> "" then begin
        let oc = open_out !output_file in
        output_string oc (Buffer.contents buf);
        close_out oc
      end else
        print_string (Buffer.contents buf);
      exit 0
    end;

    (* Emit GDB convenience variables from LLVM's own target-aware layout
       query. Consumers source this small file before their helper command,
       so changing a struct's field order or padding cannot leave a second
       hand-maintained offset table behind. *)
    if !emit_struct_layout <> "" then begin
      let struct_name = !emit_struct_layout in
      let (offsets, total) =
        try Llvm_gen.struct_layout struct_name with
        | Llvm_gen.Error _ ->
            Printf.eprintf "Error: --emit-struct-layout: no struct named '%s'\n"
              struct_name;
            exit 1
      in
      let prefix = "takibi_" ^ String.lowercase_ascii struct_name ^ "_" in
      let buf = Buffer.create 4096 in
      Printf.ksprintf (Buffer.add_string buf)
        "# GENERATED by %s --emit-struct-layout %s\n"
        Sys.argv.(0) struct_name;
      Printf.ksprintf (Buffer.add_string buf)
        "# LLVM target layout; source this file from gdb before its reader.\n";
      List.iter (fun (field, offset) ->
        Printf.ksprintf (Buffer.add_string buf) "set $%s%s = %Ld\n"
          prefix field offset
      ) offsets;
      Printf.ksprintf (Buffer.add_string buf) "set $%ssize = %Ld\n" prefix total;
      Printf.ksprintf (Buffer.add_string buf) "set $%smembers = %d\n"
        prefix (Llvm_gen.struct_member_count struct_name);
      if !output_file <> "" then begin
        let oc = open_out !output_file in
        output_string oc (Buffer.contents buf);
        close_out oc
      end else
        print_string (Buffer.contents buf);
      exit 0
    end;

    (* GitHub issue #315/#328 follow-up: an unnecessary unsafe scope is a
       compile error. Both codegen and type inference contribute evidence
       that the scope was genuinely needed (see Llvm_gen.unsafe_use_marker),
       so this is no longer the incomplete codegen-only heuristic whose
       historical false positives required warning-only treatment. Always
       on: unsafe marks an explicit trust decision, and a redundant trust
       boundary has a one-line local fix rather than a compatibility cost. *)
    if !Llvm_gen.unnecessary_unsafe_sites <> [] then begin
      let sites = List.rev !Llvm_gen.unnecessary_unsafe_sites in
      List.iter (fun (loc, what) -> report_error loc what) sites;
      Printf.eprintf "Error: %d unnecessary unsafe site(s)\n"
        (List.length sites);
      exit 1
    end;

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
      Llvm.dump_module !Llvm_gen.the_module
  with
  | Typechecker.TypeError (loc, msg) ->
      report_error loc msg;
      exit 1
  | Llvm_gen.Error msg ->
      (* GitHub issue #344: static_assert reports through this exception
         (it is settled during codegen, after monomorphization -- see
         Llvm_gen.check_static_asserts_stmts). Catching it here makes that
         a normal compile-time diagnostic and a nonzero exit status,
         instead of an uncaught OCaml exception trace. Every other
         Llvm_gen.Error is an internal-consistency failure and reads
         better this way too. *)
      Printf.eprintf "Error: %s\n" msg;
      exit 1
  | Typechecker.MultiTypeError errors ->
      (* GitHub issue #327 Stage 1: Type_inf.infer_program's Pass 3 keeps
         checking every function body even after one fails, so this can
         carry more than one error -- report every one of them (mirroring
         --forbid-trap's own "report every site, not just the first"
         pattern just below) instead of only the first. *)
      List.iter (fun (loc, msg) -> report_error loc msg) errors;
      Printf.eprintf "Error: %d function(s) failed to type-check (listed above)\n"
        (List.length errors);
      exit 1)
