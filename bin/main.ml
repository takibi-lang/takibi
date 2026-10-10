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
        let lexeme = Lexing.lexeme lexbuf in
        let message =
          if Language_words.is_hard_keyword lexeme then
            Printf.sprintf "Unexpected hard keyword '%s'" lexeme
          else if Language_words.is_contextual_keyword lexeme then
            Printf.sprintf "Unexpected contextual keyword '%s' in this position" lexeme
          else "Syntax error"
        in
        close_in chan;
        report_error pos message;
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
  let confine_raw_authority = ref false in
  let raw_mint_files = ref [] in
  let regions = ref false in
  let reject_unused_functions = ref false in
  let external_entries = ref [] in
  let check_unused_files = ref [] in
  let explain_inference = ref false in
  let profile_functions = ref false in
  let frame_pointers = ref false in
  let show_version = ref false in
  let emit_exception_frame_offsets = ref "" in
  let emit_struct_layout = ref "" in
  let emit_debug_metadata = ref "" in
  let emit_depfile = ref "" in
  let emit_overflow_audit = ref "" in
  let emit_raw_deref_audit = ref "" in
  let emit_held_guards = ref "" in
  let emit_effect_matrix = ref false in
  let i = ref 1 in
  while !i < Array.length Sys.argv do
    (match Sys.argv.(!i) with
     | "--confine-raw-authority" -> confine_raw_authority := true
     | "--raw-mint-file" ->
         incr i;
         if !i >= Array.length Sys.argv then begin
           Printf.eprintf "Error: --raw-mint-file requires a path\n";
           exit 1
         end;
         raw_mint_files := Sys.argv.(!i) :: !raw_mint_files
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
     | "--emit-debug-metadata" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-debug-metadata requires a path\n";
           exit 1
         );
         emit_debug_metadata := Sys.argv.(!i)
     | "--emit-depfile" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-depfile requires a path\n";
           exit 1
         );
         emit_depfile := Sys.argv.(!i)
     | "--emit-overflow-audit" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-overflow-audit requires a path\n";
           exit 1
         );
         emit_overflow_audit := Sys.argv.(!i)
     | "--emit-raw-deref-audit" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-raw-deref-audit requires a path\n";
           exit 1
         );
         emit_raw_deref_audit := Sys.argv.(!i)
     | "--emit-effect-matrix" ->
         emit_effect_matrix := true
     | "--emit-held-guards" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --emit-held-guards requires a path\n";
           exit 1
         );
         emit_held_guards := Sys.argv.(!i)
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
     | "--regions" ->
         regions := true
     | "--reject-unused-functions" ->
         reject_unused_functions := true
     | "--external-entry" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --external-entry requires a function name\n"; exit 1
         );
         external_entries := Sys.argv.(!i) :: !external_entries
     | "--check-unused-file" ->
         incr i;
         if !i >= Array.length Sys.argv then (
           Printf.eprintf "Error: --check-unused-file requires a source path\n"; exit 1
         );
         check_unused_files := Sys.argv.(!i) :: !check_unused_files
     | "--explain-inference" ->
         explain_inference := true
     | "--profile-functions" ->
         profile_functions := true
     | "--frame-pointers" ->
         frame_pointers := true
     | arg ->
         input_files := arg :: !input_files);
    incr i
  done;
  let input_files = List.rev !input_files in

  if !show_version then (
    Printf.printf "takibi %s\n" version;
    exit 0
  );

  if !emit_effect_matrix then (
    print_string (Effect_rules.markdown ());
    exit 0
  );

  if input_files = [] then (
    Printf.eprintf
      "Usage: %s <filename>... [-o <output.o>] [--target <triple>] [--cpu <cpu>] [--features <features>] [-g] [--profile-functions] [--frame-pointers] [--forbid-trap] [--forbid-unsafe] [--confine-raw-authority] [--raw-mint-file <path>] [--regions] [--reject-unused-functions] [--external-entry <function>] [--check-unused-file <path>] [--explain-inference] [--emit-effect-matrix] [--emit-exception-frame-offsets <StructName>] [--emit-struct-layout <StructName>] [--emit-debug-metadata <path>] [--emit-depfile <path>] [--emit-overflow-audit <path>] [--emit-raw-deref-audit <path>] [--emit-held-guards <path>] [--version]\n"
      Sys.argv.(0);
    exit 1
  );

  let machine =
    Llvm_gen.setup_target ~triple:!target_triple ~cpu:!target_cpu
      ~features:!target_features ()
  in
  if !debug_info then Llvm_gen.enable_debug_info (List.hd input_files);
  Llvm_gen.set_function_profiling !profile_functions;
  Llvm_gen.set_frame_pointers !frame_pointers;

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
    Publish_registry.reset ();
    No_copy_registry.reset ();
    Per_cpu_registry.reset ();
    Guarded_registry.reset ();
    Io_struct_registry.reset ();
    Hashtbl.reset Generic_variant.proven_empty_puts;
    Dma_fixed_registry.reset ();
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
    (* GitHub issue #672: under --regions, the built-in definitions are
       planned from this first parse, then parsed before the program's own
       files, which are parsed again (Region_builtin.plan). *)
    let prog =
      if not !regions then prog
      else begin
        let sources = Region_builtin.plan prog in
        Const_env.reset ();
        Type_layout.reset ();
        Publish_registry.reset ();
        No_copy_registry.reset ();
        Per_cpu_registry.reset ();
        Guarded_registry.reset ();
        Io_struct_registry.reset ();
        Hashtbl.reset Generic_variant.proven_empty_puts;
        Dma_fixed_registry.reset ();
        Generic_scope.reset ();
        Ast.reset_precedence_errors ();
        let defs = Region_builtin.parse_planned sources in
        let again =
          try Use_resolver.resolve ~parse_file ~prescan:prescan_file input_files
          with Use_resolver.Use_error msg ->
            Printf.eprintf "Error: %s\n" msg;
            exit 1
        in
        defs @ List.concat_map snd again
      end
    in

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
    (* GitHub issue #299: validate every `struct publish` declaration and
       synthesise the linear write token that gates its payload stores.
       Before monomorphization so that everything downstream sees only
       ordinary StructDef/OpaqueStructDef declarations. *)
    let source_prog = prog in
    let prog = Publish_record.run prog in
    let prog = Dma_fixed_record.run prog in

    let prog = Monomorphize.run ~explain_inference:!explain_inference prog in
    (* After monomorphization: lowering region_of and friends walks every
       function, and a generic template's symbolic sizes are only resolved
       here (#672). *)
    let prog = if !regions then Region_builtin.lower prog else prog in

    (* GitHub issue #358: the parser cannot disambiguate `Name[args]`
       between an indexed struct, view, and variant. Resolve that spelling
       once from the complete declaration set before either downstream
       phase sees it. *)
    let prog = Declared_type_resolver.run prog in

    (* HM type inference -- catches type errors and produces resolved types *)
    Type_inf.set_held_guard_audit_enabled (!emit_held_guards <> "");
    let prog_types = Typechecker.infer_program prog in

    if !raw_mint_files <> [] && not !confine_raw_authority then begin
      Printf.eprintf "Error: --raw-mint-file requires --confine-raw-authority\n";
      exit 1
    end;
    if !confine_raw_authority then begin
      let errors = Raw_authority_policy.check ~source_program:source_prog ~mint_files:!raw_mint_files () in
      List.iter (fun (loc, message) -> report_error loc message) errors;
      if errors <> [] then exit 1
    end;

    if !reject_unused_functions then begin
      let errors = Unused_functions.check
        ~external_entries:(List.rev !external_entries)
        ~check_files:(List.rev !check_unused_files) prog prog_types in
      List.iter (function
        | Unused_functions.Unknown_entry name ->
            Printf.eprintf "Error: --external-entry names unknown Takibi function '%s'\n" name
        | Unused_functions.Unknown_check_file file ->
            Printf.eprintf "Error: --check-unused-file contains no Takibi functions: '%s'\n" file
        | Unused_functions.Unused f ->
            report_error f.Ast.def_loc (Printf.sprintf
              "unused function '%s': no reachable caller or declared entry point"
              f.Ast.name)) errors;
      if errors <> [] then exit 1
    end;

    if !emit_overflow_audit <> "" then begin
      let op_name = function
        | Ast.Add -> "add" | Ast.Sub -> "sub" | Ast.Mul -> "mul"
        | Ast.Div -> "div" | Ast.Mod -> "mod" | Ast.Shl -> "shl"
        | _ -> assert false
      in
      let describe expr ty facts =
        let rec runtime_base ty = match Types.repr ty with
          | Types.TRefinedInt (_, _, base) | Types.TSingleton (base, _) ->
              runtime_base base
          | base -> base
        in
        match facts with
        | Some facts ->
            let open Value_facts in
            let base = Types.to_string (runtime_base ty) in
            let fact = match facts.exact with
              | Some value -> Printf.sprintf "constant:%s" (to_string value)
              | None -> Printf.sprintf "interval-inclusive:%s..%s"
                  (to_string facts.interval.lo) (to_string facts.interval.hi)
            in
            let excluded = facts.excluded
              |> List.sort_uniq compare_integer
              |> List.map to_string
              |> function [] -> "-" | values -> String.concat "," values
            in
            base, fact, excluded
        | None -> match Types.repr ty with
        | Types.TRefinedInt (lo, hi, base) ->
            Types.to_string base, Printf.sprintf "range:%d..<%d" lo hi, "-"
        | Types.TSingleton (base, n) ->
            Types.to_string base,
            Printf.sprintf "singleton:%s" (Types.static_to_string n), "-"
        | base ->
            let fact = match Const_env.folded_value expr with
              | Some n -> Printf.sprintf "constant:%d" n
              | None -> "unknown"
            in
            Types.to_string base, fact, "-"
      in
      let sites = Type_inf.overflow_audit_sites () |> List.sort (fun a b ->
        let la = a.Type_inf.overflow_loc and lb = b.Type_inf.overflow_loc in
        compare (la.pos_fname, la.pos_lnum, la.pos_cnum, op_name a.overflow_op)
                (lb.pos_fname, lb.pos_lnum, lb.pos_cnum, op_name b.overflow_op))
      in
      let out = open_out !emit_overflow_audit in
      Printf.fprintf out
        "file\tline\tcolumn\toperator\tlhs_type\tlhs_fact\tlhs_excluded\trhs_type\trhs_fact\trhs_excluded\n";
      List.iter (fun site ->
        let loc = site.Type_inf.overflow_loc in
        let lhs_ty, lhs_fact, lhs_excluded =
          describe site.overflow_lhs site.overflow_lhs_ty
          site.overflow_lhs_facts in
        let rhs_ty, rhs_fact, rhs_excluded =
          describe site.overflow_rhs site.overflow_rhs_ty
          site.overflow_rhs_facts in
        Printf.fprintf out "%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"
          loc.pos_fname loc.pos_lnum (loc.pos_cnum - loc.pos_bol + 1)
          (op_name site.overflow_op) lhs_ty lhs_fact lhs_excluded
          rhs_ty rhs_fact rhs_excluded
      ) sites;
      close_out out
    end;

    if !emit_raw_deref_audit <> "" then begin
      (* GitHub issue #639: one line per raw-pointer dereference the type
         checker recorded (Type_inf.raw_deref_site), sorted by position. *)
      let sites = Type_inf.raw_deref_sites () |> List.sort (fun a b ->
        let la = a.Type_inf.raw_loc and lb = b.Type_inf.raw_loc in
        compare (a.Type_inf.raw_file, la.pos_lnum, la.pos_cnum, a.raw_form)
                (b.Type_inf.raw_file, lb.pos_lnum, lb.pos_cnum, b.raw_form))
      in
      let out = open_out !emit_raw_deref_audit in
      Printf.fprintf out "file\tline\tcolumn\tfunction\tform\tpointer\n";
      List.iter (fun site ->
        let loc = site.Type_inf.raw_loc in
        Printf.fprintf out "%s\t%d\t%d\t%s\t%s\t%s\n"
          site.raw_file loc.pos_lnum (loc.pos_cnum - loc.pos_bol + 1)
          site.raw_function site.raw_form site.raw_pointer
      ) sites;
      close_out out
    end;

    if !emit_held_guards <> "" then begin
      let out = open_out !emit_held_guards in
      Printf.fprintf out "file\tline\tcolumn\tcaller\tcallee\tguard\tbinding_id\tguard_type\trank\tlock\tstate\n";
      List.iter (fun site ->
        let loc = site.Type_inf.held_loc in
        let prefix () = Printf.fprintf out "%s\t%d\t%d\t%s\t%s\t"
          (Ast.source_file_of_loc loc) loc.pos_lnum (loc.pos_cnum - loc.pos_bol + 1)
          site.held_caller site.held_callee in
        match List.sort compare site.held_guards with
        | [] -> prefix (); Printf.fprintf out "\t\t\t\t\tnone\n"
        | guards -> List.iter (fun guard ->
            prefix ();
            Printf.fprintf out "%s\t%d\t%s\t%d\t%s\t%s\n"
              guard.Type_inf.held_binding guard.held_binding_id guard.held_type guard.held_rank
              guard.held_lock (if guard.held_definite then "held" else "maybe-held")
          ) guards
      ) (Type_inf.held_guard_sites ());
      close_out out
    end;

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

    (* GitHub issue #732: one ordinary variant per generic instance. *)
    (* GitHub issue #732: Llvm_gen adds the instances' definitions itself;
       their sizes are registered here, where Type_layout is reachable. *)
    List.iter (function
      | Ast.VariantDef (name, _, cases, _, _) ->
          Type_layout.register_variant name cases
      | _ -> ()) (Generic_variant.instance_defs prog
                    (Type_inf.generic_variant_site_instances ()));
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

    if !emit_debug_metadata <> "" then begin
      let oc = open_out !emit_debug_metadata in
      output_string oc (Llvm_gen.debug_type_metadata ());
      close_out oc;
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
      let groups = Trap_diagnostics.group sites in
      List.iter (fun group ->
        report_error group.Trap_diagnostics.loc group.message;
        Option.iter (fun note -> Printf.eprintf "Note: %s\n" note)
          (Trap_diagnostics.instantiation_note group)
      ) groups;
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
