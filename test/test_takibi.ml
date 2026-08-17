open Takibi

(* -- Helpers --------------------------------------------------------------- *)

let parse src =
  Const_env.reset ();
  Type_layout.reset ();
  let lexbuf = Lexing.from_string src in
  Parser.program Lexer.read lexbuf

(* GitHub issue #207: mirrors bin/main.ml's own pipeline order (parse ->
   Monomorphize.run -> Type_inf.infer_program). A no-op for any program
   with no `generic struct` template at all, so this is safe to run
   unconditionally ahead of every existing (non-generic) test too. *)
let infer src =
  Type_inf.infer_program (Monomorphize.run (parse src))

(* Parses each (filename, src) pair as if it were a distinct source file
   (Lexing.set_filename, matching bin/main.ml's own parse_file) and
   concatenates the results, mirroring how multiple .tkb files given to
   takibi on the command line -- or resolved transitively via `use` --
   become one flat AST. Const_env/Type_layout are reset once for the
   whole group, not per file, matching bin/main.ml's own reset-once
   discipline (cross-file constant/layout state is meant to accumulate). *)
let infer_files files =
  Const_env.reset ();
  Type_layout.reset ();
  let prog = List.concat_map (fun (filename, src) ->
    let lexbuf = Lexing.from_string src in
    Lexing.set_filename lexbuf filename;
    Parser.program Lexer.read lexbuf
  ) files in
  Type_inf.infer_program (Monomorphize.run prog)

(* Runs the full pipeline through LLVM codegen (no target machine, no
   object-file emission -- gen_program works without setup_target, see its
   align_opt handling). GitHub issue #326: Llvm_gen.gen_program disposes and
   recreates Llvm_gen.the_module at the start of every call, so distinct test
   cases are free to reuse the same function/global names -- each gen_codegen
   call starts from a genuinely empty module, matching bin/main.exe's own
   single-compilation-per-process behavior. *)
let gen_codegen src =
  let prog = Monomorphize.run (parse src) in
  let prog_types = Type_inf.infer_program prog in
  Llvm_gen.gen_program ~prog_types prog

(* Expect the full pipeline (parse -> infer -> codegen) to succeed,
   including LLVM's own IR verifier (gen_func calls
   Llvm_analysis.verify_function and raises Llvm_gen.Error on failure --
   see the comment at that call site for why it's not the aborting
   Llvm_analysis.assert_valid_function). *)
let expect_codegen_ok src () =
  match gen_codegen src with
  | _ -> ()
  | exception Llvm_gen.Error msg -> Alcotest.failf "unexpected codegen Error: %s" msg

(* Expect codegen to succeed AND to have recorded exactly [expected] runtime
   trap sites (Llvm_gen.trap_sites -- the --forbid-trap accounting).
   gen_program resets the list at the start of each run, so this reads the
   sites of exactly this test's program, not accumulated state. *)
let expect_trap_sites expected src () =
  (match gen_codegen src with
   | _ -> ()
   | exception Llvm_gen.Error msg -> Alcotest.failf "unexpected codegen Error: %s" msg);
  Alcotest.(check int) "recorded trap sites"
    expected (List.length !Llvm_gen.trap_sites)

(* GitHub issue #315 follow-up: expect codegen to succeed AND to have
   recorded exactly [expected] "unnecessary unsafe" sites
   (Llvm_gen.unnecessary_unsafe_sites -- a statement/expr inside `unsafe`
   that never actually elided a check). Mirrors expect_trap_sites exactly;
   gen_program resets the list at the start of each run. *)
let expect_unnecessary_unsafe expected src () =
  (match gen_codegen src with
   | _ -> ()
   | exception Llvm_gen.Error msg -> Alcotest.failf "unexpected codegen Error: %s" msg);
  Alcotest.(check int) "recorded unnecessary-unsafe sites"
    expected (List.length !Llvm_gen.unnecessary_unsafe_sites)

(* GitHub issue #218: expect type inference to succeed AND to have recorded
   exactly [expected] non-literal-pointer-cast audit warnings. *)
let expect_nonliteral_ptr_cast_warnings expected src () =
  (match infer src with
   | _ -> ()
   | exception Types.TypeError (_, msg) -> Alcotest.failf "unexpected TypeError: %s" msg);
  Alcotest.(check int) "recorded nonliteral-ptr-cast warnings"
    expected (List.length !Type_inf.nonliteral_ptr_cast_warnings)

(* Expect codegen to raise Llvm_gen.Error with a message containing [fragment]. *)
let expect_codegen_error fragment src () =
  match gen_codegen src with
  | _ ->
      Alcotest.failf "expected Llvm_gen.Error containing %S, but codegen succeeded"
        fragment
  | exception Llvm_gen.Error msg ->
      if not (let n = String.length fragment in
              let m = String.length msg in
              let rec scan i = i + n <= m &&
                (String.sub msg i n = fragment || scan (i + 1))
              in scan 0)
      then Alcotest.failf "Llvm_gen.Error %S does not contain %S" msg fragment

(* Plain substring test, shared by expect_codegen_error/expect_type_error's
   inline scans above and any test that needs to check LLVM IR text. *)
let contains_substring haystack needle =
  let n = String.length needle and m = String.length haystack in
  let rec scan i = i + n <= m && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let read_all ic =
  let buf = Buffer.create 1024 in
  (try while true do Buffer.add_channel buf ic 1024 done with End_of_file -> ());
  Buffer.contents buf

(* Keep native LLVM backend failures outside this test process.  The compiler
   executable sits beside the test executable under Dune's build root. *)
let takibi_cli_path () =
  let test_exe = Unix.realpath Sys.executable_name in
  Filename.concat (Filename.dirname (Filename.dirname test_exe)) "bin/main.exe"

let expect_aarch64_debug_object src () =
  let source = Filename.temp_file "takibi-dwarf-object-" ".tkb" in
  let object_file = Filename.temp_file "takibi-dwarf-object-" ".o" in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.unlink source with Unix.Unix_error _ -> ());
      (try Unix.unlink object_file with Unix.Unix_error _ -> ()))
    (fun () ->
      let oc = open_out source in
      output_string oc src;
      close_out oc;
      let compiler = takibi_cli_path () in
      if not (Sys.file_exists compiler) then
        Alcotest.failf "cannot find test compiler at %s" compiler;
      let args = [| compiler; source; "-g"; "--target"; "aarch64-none-elf";
                     "-o"; object_file |] in
      let (stdout, stdin, stderr) =
        Unix.open_process_args_full compiler args (Unix.environment ())
      in
      close_out_noerr stdin;
      let out = read_all stdout in
      let err = read_all stderr in
      match Unix.close_process_full (stdout, stdin, stderr) with
      | Unix.WEXITED 0 ->
          if (Unix.stat object_file).Unix.st_size = 0 then
            Alcotest.fail "compiler reported success but emitted an empty object"
      | Unix.WEXITED status ->
          Alcotest.failf
            "AArch64 DWARF object-emission compiler exited %d\nstdout:\n%s\nstderr:\n%s"
            status out err
      | Unix.WSIGNALED signal ->
          Alcotest.failf
            "AArch64 DWARF object-emission compiler terminated by signal %d\nstdout:\n%s\nstderr:\n%s"
            signal out err
      | Unix.WSTOPPED signal ->
          Alcotest.failf
            "AArch64 DWARF object-emission compiler stopped by signal %d\nstdout:\n%s\nstderr:\n%s"
            signal out err)

let count_substring haystack needle =
  let n = String.length needle and m = String.length haystack in
  let rec count i acc =
    if i + n > m then acc
    else if String.sub haystack i n = needle then count (i + n) (acc + 1)
    else count (i + 1) acc
  in
  if n = 0 then 0 else count 0 0

(* gen_expr's ?expected_ty hint (CLAUDE.md's "64-bit Integer Literals"
   follow-up): a bare literal in an already-typed position must embed
   DIRECTLY at that type in the generated LLVM IR, with no intermediate
   i32 (or i64) representation to widen/truncate away -- not merely a
   value that happens to come out correct because LLVM's own constant
   folding erased the intermediate step. Checked here by inspecting the
   actual generated function body text for the absence of any zext/trunc
   instruction, which is what an i32-first-then-coerce design would have
   needed to reach a 64-bit destination. *)
let assert_direct_i64_literal fname src () =
  match gen_codegen src with
  | _ ->
      (match Hashtbl.find_opt Llvm_gen.functions fname with
       | Some (_, f) ->
           let ir = Llvm.string_of_llvalue f in
           Alcotest.(check bool) "no zext instruction" false (contains_substring ir "zext");
           Alcotest.(check bool) "no trunc instruction" false (contains_substring ir "trunc");
           Alcotest.(check bool) "the literal's exact bit pattern appears" true
             (contains_substring ir "-1")  (* 0xFFFFFFFFFFFFFFFF as i64 prints as -1 *)
       | None -> Alcotest.failf "function '%s' not found" fname)
  | exception Llvm_gen.Error msg -> Alcotest.failf "unexpected codegen Error: %s" msg

(* Custom Alcotest testables *)

let rec show_type = function
  | Ast.TypeBool        -> "bool"
  | Ast.TypeI8          -> "i8"  | Ast.TypeI16 -> "i16" | Ast.TypeI32 -> "i32" | Ast.TypeI64 -> "i64"
  | Ast.TypeU8          -> "u8"  | Ast.TypeU16 -> "u16" | Ast.TypeU32 -> "u32" | Ast.TypeU64 -> "u64"
  | Ast.TypeU16Be       -> "u16be"
  | Ast.TypeU32Be       -> "u32be"
  | Ast.TypeIsize       -> "isize"
  | Ast.TypeUsize       -> "usize"
  | Ast.TypeVoid        -> "void"
  | Ast.TypePtr t       -> "*" ^ show_type t
  | Ast.TypeIo  t       -> "io " ^ show_type t
  | Ast.TypeArray (t,n) -> Printf.sprintf "[%s; %d]" (show_type t) n
  | Ast.TypeFn (ps, r, effects) ->
      let suffix = match effects with
        | None -> ""
        | Some es -> Printf.sprintf " !{%s}" (String.concat ", " es)
      in
      Printf.sprintf "fn(%s) -> %s%s"
        (String.concat ", " (List.map show_type ps)) (show_type r) suffix
  | Ast.TypeNamed s     -> s
  | Ast.TypeView (s, []) -> "view " ^ s
  | Ast.TypeView (s, args) ->
      let arg = function
        | Ast.StaticName n -> n
        | Ast.StaticInt n -> string_of_int n
        | Ast.StaticEnum (name, case) -> name ^ "::" ^ case
      in
      Printf.sprintf "view %s[%s]" s
        (String.concat ", " (List.map arg args))
  | Ast.TypeVariant s   -> s
  | Ast.TypeExists (name, sort, body) ->
      Printf.sprintf "exists %s: %s. %s" name (show_type sort) (show_type body)
  | Ast.TypeIndexed (s, args) ->
      let arg = function
        | Ast.StaticName n -> n
        | Ast.StaticInt n -> string_of_int n
        | Ast.StaticEnum (name, case) -> name ^ "::" ^ case
      in
      Printf.sprintf "%s[%s]" s (String.concat ", " (List.map arg args))
  | Ast.TypeSingleton (t, n) ->
      let n = match n with
        | Ast.StaticName n -> n
        | Ast.StaticInt n -> string_of_int n
        | Ast.StaticEnum (name, case) -> name ^ "::" ^ case
      in
      Printf.sprintf "%s @ %s" (show_type t) n
  | Ast.TypeRefined (lo, hi, _) -> Printf.sprintf "{%d..<%d}" lo hi
  | Ast.TypeSlice (t, 0) -> Printf.sprintf "[]%s" (show_type t)
  | Ast.TypeSlice (t, n) -> Printf.sprintf "[%s; %d..]" (show_type t) n
  | Ast.TypeBorrow t -> "borrow " ^ show_type t
  | Ast.TypeBorrowMut t -> "borrow mut " ^ show_type t
  | Ast.TypeSink t -> "sink " ^ show_type t
  | Ast.TypeRef t -> "&" ^ show_type t
  | Ast.TypeRefMut t -> "&mut " ^ show_type t
  | Ast.TypeAlignedPtr (n, t) -> Printf.sprintf "*align(%d) %s" n (show_type t)
  | Ast.TypeTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map show_type ts))
  | Ast.TypeKind -> "type"
  | Ast.TypeGenericInst (name, args) ->
      Printf.sprintf "%s(%s)" name (String.concat ", " (List.map show_type args))
  | Ast.TypeIntLit n -> string_of_int n
  | Ast.TypeArraySym (t, _) -> Printf.sprintf "[%s; <sym>]" (show_type t)
  | Ast.TypeSliceSym (t, _) -> Printf.sprintf "[%s; <sym>..]" (show_type t)

let type_t : Ast.type_expr Alcotest.testable =
  Alcotest.testable (fun fmt t -> Format.pp_print_string fmt (show_type t)) (=)

let binop_t : Ast.binop Alcotest.testable =
  Alcotest.testable
    (fun fmt op -> Format.pp_print_string fmt (Ast.show_binop op))
    (=)

(* Expect a TypeError whose message contains [fragment] *)
let expect_type_error fragment src () =
  match infer src with
  | _ ->
      Alcotest.failf "expected TypeError containing %S, but inference succeeded"
        fragment
  | exception Types.TypeError (_, msg) ->
      if not (let n = String.length fragment in
              let m = String.length msg in
              let rec scan i = i + n <= m &&
                (String.sub msg i n = fragment || scan (i + 1))
              in scan 0)
      then Alcotest.failf "TypeError %S does not contain %S" msg fragment

let expect_type_error_at ?filename line column fragment src () =
  match infer src with
  | _ ->
      Alcotest.failf "expected TypeError containing %S at %d:%d, but inference succeeded"
        fragment line column
  | exception Types.TypeError (loc, msg) ->
      (match filename with
       | Some expected ->
           Alcotest.(check string) "error filename" expected loc.Lexing.pos_fname
       | None -> ());
      Alcotest.(check int) "error line" line loc.Lexing.pos_lnum;
      Alcotest.(check int) "error column" column
        (loc.Lexing.pos_cnum - loc.Lexing.pos_bol + 1);
      if not (contains_substring msg fragment)
      then Alcotest.failf "TypeError %S does not contain %S" msg fragment

(* GitHub issue #327 Stage 1: expect a MultiTypeError with exactly
   List.length fragments entries, each fragment matched against some
   entry's message (order-independent -- Pass 3 folds over the whole
   program, so encounter order tracks declaration order, not anything a
   test should need to pin down). A single broken function still raises a
   plain Types.TypeError, not MultiTypeError (see infer_program's own
   comment) -- exercised as a negative control by expect_type_error
   elsewhere in this file, not duplicated here. *)
let expect_multi_type_error fragments src () =
  match infer src with
  | _ ->
      Alcotest.failf "expected MultiTypeError, but inference succeeded"
  | exception Types.MultiTypeError errors ->
      Alcotest.(check int) "error count" (List.length fragments) (List.length errors);
      List.iter (fun fragment ->
        if not (List.exists (fun (_, msg) -> contains_substring msg fragment) errors)
        then Alcotest.failf "no MultiTypeError entry contains %S (errors: %s)"
          fragment (String.concat " | " (List.map snd errors))
      ) fragments
  | exception Types.TypeError (_, msg) ->
      Alcotest.failf
        "expected MultiTypeError with %d entries, got a single TypeError instead: %s"
        (List.length fragments) msg

(* Expect inference to succeed *)
let expect_ok src () =
  match infer src with
  | _ -> ()
  | exception Types.TypeError (_, msg) ->
      Alcotest.failf "unexpected TypeError: %s" msg

(* -- Parser tests ---------------------------------------------------------- *)

let parser_tests = [
  Alcotest.test_case "erased view declaration and mint expression parse" `Quick
    (fun () ->
      match parse
        "private linear view ParsedPending;
         fn parsed_mint() -> ParsedPending { return view ParsedPending; }" with
      | [Ast.ViewDef ("ParsedPending", Ast.KindLinear, [], true, _);
         Ast.FuncDef { ret_type = Some (Ast.TypeNamed "ParsedPending");
                       body = [{ desc = Ast.Return (Some
                         { desc = Ast.ViewLit ("ParsedPending", []); _ }); _ }]; _ }] -> ()
      | _ -> Alcotest.fail "expected a private linear ViewDef and ViewLit");

  Alcotest.test_case "Slice 6 indexed view declaration and mint expression parse" `Quick
    (fun () ->
      match parse
        "linear view ParsedPhase[id: usize, state: u8];
         fn parsed_step(p: sink ParsedPhase[id, 0]) -> ParsedPhase[id, 1] {
           return view ParsedPhase[id, 1];
         }" with
      | [Ast.ViewDef
           ("ParsedPhase", Ast.KindLinear,
            [("id", Ast.TypeUsize); ("state", Ast.TypeU8)], false, _);
         Ast.FuncDef
           { params = [("p", Some (Ast.TypeSink
               (Ast.TypeIndexed ("ParsedPhase",
                 [Ast.StaticName "id"; Ast.StaticInt 0]))))];
             ret_type = Some (Ast.TypeIndexed
               ("ParsedPhase", [Ast.StaticName "id"; Ast.StaticInt 1]));
             body = [{ desc = Ast.Return (Some
               { desc = Ast.ViewLit
                   ("ParsedPhase", [Ast.StaticName "id"; Ast.StaticInt 1]); _ });
               _ }]; _ }] -> ()
      | _ -> Alcotest.fail "expected indexed ViewDef, type, and ViewLit nodes");

  Alcotest.test_case "finite enum static sort and qualified state argument parse" `Quick
    (fun () ->
      match parse
        "enum ParsedTcpState: u8 { Listen; SynRcvd; }
         linear view ParsedTcpConn[conn: usize, state: ParsedTcpState];
         variant ParsedTcpDispatch {
           Listen(exists conn: usize.
             ParsedTcpConn[conn, ParsedTcpState::Listen]);
         }" with
      | [Ast.EnumDef ("ParsedTcpState", _, _, false);
         Ast.ViewDef
           ("ParsedTcpConn", Ast.KindLinear,
            [("conn", Ast.TypeUsize);
             ("state", Ast.TypeNamed "ParsedTcpState")], false, _);
         Ast.VariantDef
           ("ParsedTcpDispatch",
            [("Listen", Some (Ast.TypeExists
              ("conn", Ast.TypeUsize,
               Ast.TypeIndexed
                 ("ParsedTcpConn",
                   [Ast.StaticName "conn";
                    Ast.StaticEnum ("ParsedTcpState", "Listen")]))))], false, _)] -> ()
      | _ -> Alcotest.fail "expected finite enum static-state AST nodes");

  Alcotest.test_case "addr-indexed pointer keeps singleton outside pointer" `Quick
    (fun () ->
      match parse
        "linear view ParseAddrGuard[lock: addr];
         fn parse_addr_lock(m: *io i32 @ lock) -> ParseAddrGuard[lock] {}"
      with
      | [Ast.ViewDef _;
         Ast.FuncDef { params = [(_, Some ty)]; _ }] ->
          Alcotest.check type_t "pointer identity is outermost"
            (Ast.TypeSingleton
               (Ast.TypePtr (Ast.TypeIo Ast.TypeI32), Ast.StaticName "lock"))
            ty
      | _ -> Alcotest.fail "expected an addr-indexed pointer parameter");

  Alcotest.test_case "indexed linear struct and singleton syntax parse" `Quick (fun () ->
    match parse
      "private linear struct PLease[n: usize] { private idx: {0..<4 as usize} @ n; }
       fn p_use(x: borrow PLease[n]) {}" with
    | [Ast.OwnedStructDef
         ("PLease", Ast.KindLinear, [("n", Ast.TypeUsize)],
          [("idx", Ast.TypeSingleton
             (Ast.TypeRefined (0, 4, Ast.TypeUsize), Ast.StaticName "n"))],
          false, None, ["idx"], true, _);
       Ast.FuncDef
         { params = [("x", Some (Ast.TypeBorrow
             (Ast.TypeIndexed ("PLease", [Ast.StaticName "n"]))))]; _ }] -> ()
    | _ -> Alcotest.fail "expected indexed linear struct and borrow PLease[n]");

  Alcotest.test_case "Slice 3 variant, existential payload, constructor, and binder parse" `Quick
    (fun () ->
      match parse
        "linear struct ParsedOwner[n: usize] { idx: usize @ n; }
         variant ParsedMaybe {
           None;
           Some(exists n: usize. ParsedOwner[n]);
         }
         fn parsed_wrap(x: ParsedOwner[n]) -> ParsedMaybe {
           return ParsedMaybe::Some(x);
         }
         fn parsed_match(x: ParsedMaybe) {
           match x {
             ParsedMaybe::None => {}
             ParsedMaybe::Some(owner) => {}
           }
         }" with
      | [Ast.OwnedStructDef _;
         Ast.VariantDef
           ("ParsedMaybe",
            [("None", None);
             ("Some", Some (Ast.TypeExists
               ("n", Ast.TypeUsize,
                Ast.TypeIndexed ("ParsedOwner", [Ast.StaticName "n"]))))], false, _);
         Ast.FuncDef { body = [{ desc = Ast.Return (Some
           { desc = Ast.VariantCtor ("ParsedMaybe", "Some", _); _ }); _ }]; _ };
         Ast.FuncDef { body = [{ desc = Ast.Match (_,
           [Ast.ArmVariant ("ParsedMaybe", "None", None, []);
            Ast.ArmVariant ("ParsedMaybe", "Some", Some ("owner", false), [])]); _ }]; _ }] -> ()
      | _ -> Alcotest.fail "expected Slice 3 variant AST nodes");

  Alcotest.test_case "must_use variant declaration parses its checker policy" `Quick
    (fun () ->
      match parse "must_use variant ParsedStatus { Ok; Err(i32); }" with
      | [Ast.VariantDef
           ("ParsedStatus", [("Ok", None); ("Err", Some Ast.TypeI32)],
            true, _)] -> ()
      | _ -> Alcotest.fail "expected must_use VariantDef policy");

  Alcotest.test_case "Slice 4 mutable borrow and mutable payload binder parse" `Quick
    (fun () ->
      match parse
        "linear struct ParsedMutable[n: usize] { value: i32; }
         variant ParsedMutableResult {
           Value(exists n: usize. ParsedMutable[n]);
         }
         fn parsed_change(x: borrow mut ParsedMutable[n]) {}
         fn parsed_open(x: ParsedMutableResult) {
           match x { ParsedMutableResult::Value(mut owner) => {} }
         }" with
      | [Ast.OwnedStructDef _; Ast.VariantDef _;
         Ast.FuncDef { params = [("x", Some (Ast.TypeBorrowMut
           (Ast.TypeIndexed ("ParsedMutable", [Ast.StaticName "n"]))))]; _ };
         Ast.FuncDef { body = [{ desc = Ast.Match (_,
           [Ast.ArmVariant ("ParsedMutableResult", "Value",
             Some ("owner", true), [])]); _ }]; _ }] -> ()
      | _ -> Alcotest.fail "expected borrow mut and Case(mut payload) AST nodes");

  Alcotest.test_case "Slice 4 checker effects parse on functions and externs" `Quick
    (fun () ->
      match parse
        "extern fn parsed_wait() !{may_block};
         fn parsed_irq() !{interrupt} {}
         fn parsed_sync() !{exception} {}
         fn parsed_nonblocking() !{} {}" with
      | [Ast.ExternFuncDef ("parsed_wait", [], None, Some ["may_block"]);
         Ast.FuncDef { name = "parsed_irq"; effects = Some ["interrupt"]; _ };
         Ast.FuncDef { name = "parsed_sync"; effects = Some ["exception"]; _ };
         Ast.FuncDef { name = "parsed_nonblocking"; effects = Some []; _ }] -> ()
      | _ -> Alcotest.fail "expected checker effect annotations");


  Alcotest.test_case "empty function body" `Quick (fun () ->
    match parse "fn foo() {}" with
    | [Ast.FuncDef f] ->
        Alcotest.(check string)   "name"        "foo" f.name;
        Alcotest.(check int)      "param count" 0 (List.length f.params);
        Alcotest.(check (option type_t)) "ret type" None f.ret_type;
        Alcotest.(check int)      "body length" 0 (List.length f.body)
    | _ -> Alcotest.fail "expected single FuncDef"
  );

  Alcotest.test_case "function with typed params and return" `Quick (fun () ->
    match parse "fn add(a: i32, b: i32) i32 { return a; }" with
    | [Ast.FuncDef f] ->
        Alcotest.(check string) "name" "add" f.name;
        Alcotest.(check int)    "param count" 2 (List.length f.params);
        let (n0, t0) = List.nth f.params 0 in
        let (n1, t1) = List.nth f.params 1 in
        Alcotest.(check string)        "param0 name" "a"   n0;
        Alcotest.(check (option type_t)) "param0 type" (Some Ast.TypeI32) t0;
        Alcotest.(check string)        "param1 name" "b"   n1;
        Alcotest.(check (option type_t)) "param1 type" (Some Ast.TypeI32) t1;
        Alcotest.(check (option type_t)) "ret type" (Some Ast.TypeI32) f.ret_type;
        Alcotest.(check int)    "body length" 1 (List.length f.body)
    | _ -> Alcotest.fail "expected single FuncDef"
  );

  Alcotest.test_case "inline function parses" `Quick (fun () ->
    match parse "inline fn add1(a: i32) i32 { return a + 1; }" with
    | [Ast.FuncDef { name = "add1"; is_inline = true; is_noinline = false; _ }] -> ()
    | _ -> Alcotest.fail "expected inline FuncDef"
  );

  Alcotest.test_case "noinline function parses" `Quick (fun () ->
    match parse "noinline fn add1(a: i32) i32 { return a + 1; }" with
    | [Ast.FuncDef { name = "add1"; is_inline = false; is_noinline = true; _ }] -> ()
    | _ -> Alcotest.fail "expected noinline FuncDef"
  );

  Alcotest.test_case "global let without type" `Quick (fun () ->
    match parse "let x = 1;" with
    | [Ast.LetDef (name, ty, init, _, _, _, _)] ->
        Alcotest.(check string)        "name"    "x"   name;
        Alcotest.(check (option type_t)) "type"    None  ty;
        (match init with
         | Some { Ast.desc = Ast.IntLit 1L; _ } -> ()
         | _ -> Alcotest.fail "expected IntLit 1")
    | _ -> Alcotest.fail "expected single LetDef"
  );

  Alcotest.test_case "global let with type annotation" `Quick (fun () ->
    match parse "let g: u8 = 0;" with
    | [Ast.LetDef (name, ty, _, _, _, _, _)] ->
        Alcotest.(check string)        "name" "g" name;
        Alcotest.(check (option type_t)) "type" (Some Ast.TypeU8) ty
    | _ -> Alcotest.fail "expected single LetDef"
  );

  Alcotest.test_case "global let with align(N) no init parses" `Quick (fun () ->
    match parse "let buf: [u8; 16] align(64);" with
    | [Ast.LetDef ("buf", Some (Ast.TypeArray (Ast.TypeU8, 16)), None, Some 64, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected LetDef with align 64"
  );

  Alcotest.test_case "global let with align(N) and init parses" `Quick (fun () ->
    match parse "let x: i32 align(16) = 0;" with
    | [Ast.LetDef ("x", Some Ast.TypeI32, Some _, Some 16, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected LetDef with align 16 and init"
  );

  Alcotest.test_case "usize type parses" `Quick (fun () ->
    match parse "let addr: usize;" with
    | [Ast.LetDef ("addr", Some Ast.TypeUsize, None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected LetDef with TypeUsize"
  );

  Alcotest.test_case "isize type parses" `Quick (fun () ->
    match parse "let offset: isize;" with
    | [Ast.LetDef ("offset", Some Ast.TypeIsize, None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected LetDef with TypeIsize"
  );

  Alcotest.test_case "bare global let parses as immutable (is_mutable=false)" `Quick (fun () ->
    match parse "let N: i32 = 16;" with
    | [Ast.LetDef ("N", Some Ast.TypeI32, Some _, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected is_mutable=false"
  );

  Alcotest.test_case "global let mut parses as mutable (is_mutable=true)" `Quick (fun () ->
    match parse "let mut g: i32 = 0;" with
    | [Ast.LetDef ("g", Some Ast.TypeI32, Some _, None, true, _, _)] -> ()
    | _ -> Alcotest.fail "expected is_mutable=true"
  );

  Alcotest.test_case "global let mut with align(N) parses" `Quick (fun () ->
    match parse "let mut buf: [u8; 16] align(64);" with
    | [Ast.LetDef ("buf", Some (Ast.TypeArray (Ast.TypeU8, 16)), None, Some 64, true, _, _)] -> ()
    | _ -> Alcotest.fail "expected LetDef with is_mutable=true and align 64"
  );

  Alcotest.test_case "const with type annotation parses" `Quick (fun () ->
    match parse "const N: usize = 4;" with
    | [Ast.ConstDef ("N", Ast.TypeUsize, { desc = Ast.IntLit 4L; _ }, _)] -> ()
    | _ -> Alcotest.fail "expected ConstDef"
  );

  (* GitHub issue #295 follow-up: a const initializer now reuses
     array_size's own IDENT/+/-/*// grammar instead of accepting only a
     bare INT literal, so a duplicated-literal-kept-in-sync-by-hand const
     (exactly the KERNEL_SOCKET_FD_MAX/PROCESS_FD_MAX drift issue #295's
     audit found) can instead be a real reference. Both forms still fully
     resolve to a plain IntLit at parse time -- Const_env has no notion of
     a "symbolic" const, only ever a concrete recorded int -- so a later
     const referencing this one, or an array size, sees an ordinary
     literal either way. *)
  Alcotest.test_case "const initializer may reference an earlier const \
                       by name" `Quick (fun () ->
    match parse "const N: usize = 4; const M: usize = N;" with
    | [Ast.ConstDef ("N", _, { desc = Ast.IntLit 4L; _ }, _);
       Ast.ConstDef ("M", _, { desc = Ast.IntLit 4L; _ }, _)] -> ()
    | _ -> Alcotest.fail "expected M's ConstDef to resolve to IntLit 4L"
  );

  Alcotest.test_case "const initializer supports +/-/*// between earlier \
                       consts, matching array_size's own arithmetic" `Quick
    (fun () ->
      match parse "const A: usize = 4; const B: usize = 16; \
                    const P: usize = A * B; const S: usize = A + B; \
                    const D: usize = B / A; const M: usize = B - A;" with
      | [Ast.ConstDef _; Ast.ConstDef _;
         Ast.ConstDef ("P", _, { desc = Ast.IntLit 64L; _ }, _);
         Ast.ConstDef ("S", _, { desc = Ast.IntLit 20L; _ }, _);
         Ast.ConstDef ("D", _, { desc = Ast.IntLit 4L; _ }, _);
         Ast.ConstDef ("M", _, { desc = Ast.IntLit 12L; _ }, _)] -> ()
      | _ -> Alcotest.fail "expected P/S/D/M resolved to 64/20/4/12"
  );

  Alcotest.test_case "const initializer referencing an undefined name is \
                       a compile error (same message shape as an array \
                       size referencing one)" `Quick (fun () ->
    match parse "const N: usize = UNDEFINED_CONST;" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions the unknown name" true
          (contains_substring msg "UNDEFINED_CONST")
  );

  Alcotest.test_case "const initializer referencing a mutable global (not \
                       a const) is a compile error, same as array_size" `Quick
    (fun () ->
      match parse "let mut N: i32 = 4; const M: usize = N;" with
      | _ -> Alcotest.fail "expected an error, but parsing succeeded"
      | exception Types.TypeError (_, _) -> ()
  );

  Alcotest.test_case "const rejects non-integer types" `Quick (fun () ->
    List.iter (fun src ->
      match parse src with
      | _ -> Alcotest.fail ("expected an error, but parsing succeeded: " ^ src)
      | exception Types.TypeError (_, msg) ->
          Alcotest.(check bool) "mentions primitive integer" true
            (contains_substring msg "primitive integer"))
      [ "const MMIO: *io u32 = 0x40000000;";
        "const BUF: [u8; 4] = 0;";
        "struct ConstStructBad { x: i32; } const C: ConstStructBad = 0;" ]
  );

  Alcotest.test_case "array size via named compile-time constant resolves" `Quick (fun () ->
    match parse "const N: i32 = 4; let ring: [u8; N];" with
    | [Ast.ConstDef _; Ast.LetDef ("ring", Some (Ast.TypeArray (Ast.TypeU8, 4)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 4"
  );

  Alcotest.test_case "array size via sizeof(Struct) resolves" `Quick (fun () ->
    match parse "struct Foo { a: u32; b: u32; } let buf: [u8; sizeof(Foo)];" with
    | [Ast.StructDef _; Ast.LetDef ("buf", Some (Ast.TypeArray (Ast.TypeU8, 8)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 8"
  );

  Alcotest.test_case "array size via sizeof(Variant) resolves its Slice 3 ABI" `Quick
    (fun () ->
      match parse
        "variant SizedVariant { None; Value(u32); }
         let buf: [u8; sizeof(SizedVariant)];"
      with
      | [Ast.VariantDef _;
         Ast.LetDef ("buf", Some (Ast.TypeArray (Ast.TypeU8, 8)),
                     None, None, false, _, _)] -> ()
      | _ -> Alcotest.fail "expected variant tag plus u32 payload field size 8");

  Alcotest.test_case "array size referencing unknown identifier is a syntax error" `Quick (fun () ->
    match parse "let ring: [u8; UNDEFINED];" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions the unknown name" true
          (let n = String.length "UNDEFINED" and m = String.length msg in
           let rec scan i = i + n <= m && (String.sub msg i n = "UNDEFINED" || scan (i + 1)) in
           scan 0)
  );

  Alcotest.test_case "array size referencing a mutable global is a syntax error" `Quick (fun () ->
    match parse "let mut N: i32 = 4; let ring: [u8; N];" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError _ -> ()
  );

  Alcotest.test_case "array size formula: product of two named constants" `Quick (fun () ->
    match parse "const QNUM: i32 = 8; const RX_BUF_SIZE: i32 = 1536; \
                 let bufs: [u8; QNUM * RX_BUF_SIZE];" with
    | [_; _; Ast.LetDef ("bufs", Some (Ast.TypeArray (Ast.TypeU8, 12288)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 12288"
  );

  Alcotest.test_case "array size formula: difference of a named constant and a literal" `Quick (fun () ->
    match parse "const COUNT: i32 = 4; let ring: [u8; COUNT - 1];" with
    | [_; Ast.LetDef ("ring", Some (Ast.TypeArray (Ast.TypeU8, 3)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 3"
  );

  Alcotest.test_case "array size formula: parentheses and operator precedence \
                       (a + b * c, not (a + b) * c)" `Quick (fun () ->
    match parse "let ring: [u8; 2 + 3 * 4];" with
    | [Ast.LetDef ("ring", Some (Ast.TypeArray (Ast.TypeU8, 14)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 14 (2 + 12), not 20"
  );

  Alcotest.test_case "array size formula: explicit parentheses override precedence" `Quick (fun () ->
    match parse "let ring: [u8; (2 + 3) * 4];" with
    | [Ast.LetDef ("ring", Some (Ast.TypeArray (Ast.TypeU8, 20)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 20"
  );

  Alcotest.test_case "array size formula: division by a named constant" `Quick (fun () ->
    match parse "const PAGE_SIZE: i32 = 4096; let bufs: [u8; (2 * PAGE_SIZE) / 2];" with
    | [_; Ast.LetDef ("bufs", Some (Ast.TypeArray (Ast.TypeU8, 4096)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 4096"
  );

  Alcotest.test_case "array size formula: division by zero is a compile error, \
                       not a crash" `Quick (fun () ->
    match parse "const Z: i32 = 0; let ring: [u8; 4 / Z];" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions division by zero" true
          (let n = String.length "division by zero" and m = String.length msg in
           let rec scan i = i + n <= m && (String.sub msg i n = "division by zero" || scan (i + 1)) in
           scan 0)
  );

  Alcotest.test_case "array size formula: an undefined name inside a formula \
                       is still a syntax error (same as a bare undefined name)" `Quick (fun () ->
    match parse "let ring: [u8; UNDEFINED * 2];" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions the unknown name" true
          (let n = String.length "UNDEFINED" and m = String.length msg in
           let rec scan i = i + n <= m && (String.sub msg i n = "UNDEFINED" || scan (i + 1)) in
           scan 0)
  );

  Alcotest.test_case "explicit i32 refined type parses" `Quick (fun () ->
    match parse "fn f(x: {0..<2147483647 as i32}) i32 { return 0; }" with
    | [Ast.FuncDef _] -> ()
    | _ -> Alcotest.fail "expected single FuncDef"
  );

  Alcotest.test_case "bare refined type requires an explicit base" `Quick
    (fun () ->
    match parse "fn f(x: {0..<8}) i32 { return x; }" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions explicit base" true
          (contains_substring msg "requires an explicit base")
  );

  Alcotest.test_case
    "explicit i32 refined type rejects a bound outside i32 range"
    `Quick (fun () ->
    match parse "fn f(x: {0..<5000000000 as i32}) i32 { return 0; }" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions i32" true
          (let n = String.length "i32" and m = String.length msg in
           let rec scan i = i + n <= m &&
             (String.sub msg i n = "i32" || scan (i + 1)) in
           scan 0)
  );

  (* -- Explicit-base {lo..<hi as base} surface syntax -------------------- *)
  (* Source refinements always name their representation base explicitly.
     This lets a refined FUNCTION PARAMETER unify against a genuinely
     narrow-based local; bare syntax is reserved for future inference. *)
  Alcotest.test_case "{lo..<hi as u8} parses as a u8-based TypeRefined" `Quick (fun () ->
    Alcotest.(check bool) "parses"
      true
      (match parse "fn f(x: {0..<20 as u8}) u8 { return x; }" with
       | [Ast.FuncDef { params = [(_, Some (Ast.TypeRefined (0, 20, Ast.TypeU8)))]; _ }] -> true
       | _ -> false)
  );

  Alcotest.test_case "{lo..<CONST as usize} resolves a const bound" `Quick (fun () ->
    match parse "const N: usize = 4; fn f(x: {0..<N as usize}) usize { return x; }" with
    | [Ast.ConstDef _;
       Ast.FuncDef { params = [(_, Some (Ast.TypeRefined (0, 4, Ast.TypeUsize)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected const-refined bound to resolve to 4"
  );

  Alcotest.test_case "{lo..<LET as usize} rejects an ordinary global let bound" `Quick (fun () ->
    match parse "let N: usize = 4; fn f(x: {0..<N as usize}) usize { return x; }" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions const" true
          (contains_substring msg "const N")
  );

  Alcotest.test_case "{lo..<hi as base} accepts every primitive integer base" `Quick (fun () ->
    List.iter (fun (base_name, expect) ->
      match parse (Printf.sprintf "fn f(x: {0..<8 as %s}) i32 { return 0; }" base_name) with
      | [Ast.FuncDef { params = [(_, Some (Ast.TypeRefined (0, 8, actual)))]; _ }] ->
          Alcotest.(check bool) (base_name ^ " base") true (actual = expect)
      | _ -> Alcotest.fail (base_name ^ ": expected single FuncDef with a refined param"))
      [ ("i8", Ast.TypeI8); ("i16", Ast.TypeI16); ("i32", Ast.TypeI32); ("i64", Ast.TypeI64);
        ("u8", Ast.TypeU8); ("u16", Ast.TypeU16); ("u32", Ast.TypeU32); ("u64", Ast.TypeU64);
        ("isize", Ast.TypeIsize);
        ("usize", Ast.TypeUsize) ]
  );

  Alcotest.test_case
    "{lo..<hi as u8} rejects a bound outside u8's representable range \
     (same soundness reasoning as the bare-{lo..<hi}-vs-i32 check above, \
     generalized per base -- a bound of 300 would silently wrap at codegen \
     time via `const_int i8_type 300` with no warning if left unchecked)"
    `Quick (fun () ->
    match parse "fn f(x: {0..<300 as u8}) u8 { return x; }" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions the base name" true
          (let n = String.length "u8" and m = String.length msg in
           let rec scan i = i + n <= m &&
             (String.sub msg i n = "u8" || scan (i + 1)) in
           scan 0)
  );

  Alcotest.test_case
    "{lo..<hi as i64}/{lo..<hi as u64} impose no upper-bound check (matches \
     types.ml's own TRefinedInt subtyping rules for those bases, which \
     likewise never restrict hi)" `Quick (fun () ->
    match parse "fn f(x: {0..<9000000000 as i64}) i64 { return x; }" with
    | [Ast.FuncDef _] -> ()
    | _ -> Alcotest.fail "expected single FuncDef"
  );

  Alcotest.test_case "return statement" `Quick (fun () ->
    match parse "fn f() i32 { return 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit 42L; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "let statement (immutable) with initializer" `Quick (fun () ->
    match parse "fn f() { let x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (false, "x", None, Some { desc = Ast.IntLit 5L; _ }, None) -> ()
         | _ -> Alcotest.fail "expected Let(false, x, None, IntLit 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "let mut statement (mutable) with initializer" `Quick (fun () ->
    match parse "fn f() { let mut x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "x", None, Some { desc = Ast.IntLit 5L; _ }, None) -> ()
         | _ -> Alcotest.fail "expected Let(true, x, None, IntLit 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "assign statement" `Quick (fun () ->
    match parse "fn f() { x = 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Var "x"; _ }, { desc = Ast.IntLit 3L; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(Var x, IntLit 3))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "if/else statement" `Quick (fun () ->
    match parse "fn f() { if (1) { return 0; } else { return 1; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.If (_, [_], [_]) -> ()
         | _ -> Alcotest.fail "expected If with 1 branch each")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "while statement" `Quick (fun () ->
    match parse "fn f() { while (1) { x = 0; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.While (_, [_]) -> ()
         | _ -> Alcotest.fail "expected While with 1 body stmt")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "break statement parses to Break" `Quick (fun () ->
    match parse "fn f() { while (1) { break; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.While (_, [{ desc = Ast.Break; _ }]) -> ()
         | _ -> Alcotest.fail "expected While containing Break")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "continue statement parses to Continue" `Quick (fun () ->
    match parse "fn f() { while (1) { continue; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.While (_, [{ desc = Ast.Continue; _ }]) -> ()
         | _ -> Alcotest.fail "expected While containing Continue")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "arithmetic BinOp" `Quick (fun () ->
    match parse "fn f() i32 { return 1 + 2 * 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "outer op is Add" Ast.Add op
         | _ -> Alcotest.fail "expected Return(BinOp)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "comparison BinOp" `Quick (fun () ->
    match parse "fn f() i32 { return 1 != 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Ne" Ast.Ne op
         | _ -> Alcotest.fail "expected Return(BinOp)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "function call expression" `Quick (fun () ->
    match parse "fn f() i32 { return g(1, 2); }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Call ("g", args); _ }) ->
             Alcotest.(check int) "arg count" 2 (List.length args)
         | _ -> Alcotest.fail "expected Return(Call)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "multiple top-level items" `Quick (fun () ->
    let prog = parse "let x = 0; fn f() {} fn g() i32 { return 1; }" in
    Alcotest.(check int) "item count" 3 (List.length prog);
    (match List.nth prog 0 with
     | Ast.LetDef ("x", _, _, _, _, _, _) -> ()
     | _ -> Alcotest.fail "first item should be LetDef x");
    (match List.nth prog 1 with
     | Ast.FuncDef { name = "f"; _ } -> ()
     | _ -> Alcotest.fail "second item should be FuncDef f")
  );

  (* -- Pointer / address-of tests ------------------------------ *)

  Alcotest.test_case "pointer type in function param" `Quick (fun () ->
    match parse "fn f(p: *i32) {}" with
    | [Ast.FuncDef { params = [(_, Some t)]; _ }] ->
        Alcotest.check type_t "param type is *i32" (Ast.TypePtr Ast.TypeI32) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "pointer-to-pointer type" `Quick (fun () ->
    match parse "fn f(p: **i32) {}" with
    | [Ast.FuncDef { params = [(_, Some t)]; _ }] ->
        Alcotest.check type_t "param type is **i32"
          (Ast.TypePtr (Ast.TypePtr Ast.TypeI32)) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "*io i32 param type parses" `Quick (fun () ->
    match parse "fn f(p: *io i32) {}" with
    | [Ast.FuncDef { params = [(_, Some t)]; _ }] ->
        Alcotest.check type_t "param type is *io i32"
          (Ast.TypePtr (Ast.TypeIo Ast.TypeI32)) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bare io type in global let parses" `Quick (fun () ->
    match parse "let flag: io i32;" with
    | [Ast.LetDef (_, Some t, None, _, _, _, _)] ->
        Alcotest.check type_t "type is io i32" (Ast.TypeIo Ast.TypeI32) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "io type in struct field parses" `Quick (fun () ->
    match parse "struct S { done: io i32; }" with
    | [Ast.StructDef (_, [(_, t)], _, _, _, _)] ->
        Alcotest.check type_t "field type is io i32" (Ast.TypeIo Ast.TypeI32) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "deref expression" `Quick (fun () ->
    match parse "fn f(p: *i32) i32 { return *p; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Deref { desc = Ast.Var "p"; _ }; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(Deref(Var p))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "addrof expression (let mut required)" `Quick (fun () ->
    match parse "fn f() { let mut x = 0; let p = &x; }" with
    | [Ast.FuncDef { body = [_; s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.AddrOf { desc = Ast.Var "x"; _ }; _ }, _) -> ()
         | _ -> Alcotest.fail "expected Let(_, AddrOf x)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "assign through pointer" `Quick (fun () ->
    match parse "fn f(p: *i32) { *p = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Deref { desc = Ast.Var "p"; _ }; _ },
             { desc = Ast.IntLit 42L; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(Deref(Var p), IntLit 42))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "hex integer literal" `Quick (fun () ->
    match parse "fn f() i32 { return 0xff; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit 255L; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 255)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "full 64-bit hex literal parses to the exact Int64 \
                       value with no truncation (IntLit's payload is \
                       Int64.t, not OCaml's native 63-bit int -- see \
                       CLAUDE.md's '64-bit Integer Literals' section)" `Quick (fun () ->
    match parse "fn f() u64 { return 0xFFFFFFFFFFFFFFFF; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit (-1L); _ }) -> ()
             (* 0xFFFFFFFFFFFFFFFF as a signed Int64 bit pattern is -1L;
                the important thing is EVERY bit survives parsing, not
                which OCaml literal happens to print it. *)
         | _ -> Alcotest.fail "expected Return(IntLit -1L)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "a decimal literal past i64::MAX (but within u64's \
                       range) parses via the hand-written digit \
                       accumulator, not Int64.of_string (which rejects it \
                       -- see lib/lexer.mll)" `Quick (fun () ->
    match parse "fn f() u64 { return 18446744073709551615; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit (-1L); _ }) -> ()  (* u64::MAX's bit pattern *)
         | _ -> Alcotest.fail "expected Return(IntLit -1L)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "u8 literal becomes IntLit" `Quick (fun () ->
    match parse "fn f() i32 { return 'A'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit 65L; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 65)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "u8 escape literals" `Quick (fun () ->
    match parse "fn f() { let a = '\\n'; let b = '\\r'; let c = '\\0'; }" with
    | [Ast.FuncDef { body = [s1; s2; s3]; _ }] ->
        let check name expected s =
          match s.Ast.desc with
          | Ast.Let (_, _, _, Some { desc = Ast.IntLit n; _ }, _) ->
              Alcotest.(check int) name expected (Int64.to_int n)
          | _ -> Alcotest.failf "%s: expected Let with IntLit" name
        in
        check "\\n" 10 s1; check "\\r" 13 s2; check "\\0" 0 s3
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "logical OR expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a == 1 || b == 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "outer op is Or" Ast.Or op
         | _ -> Alcotest.fail "expected Return(BinOp Or)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "logical AND expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a >= 0 && b < 8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "outer op is And" Ast.And op
         | _ -> Alcotest.fail "expected Return(BinOp And)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "&& has lower prec than comparisons" `Quick (fun () ->
    (* a >= 0 && b < 8  ->  (a >= 0) && (b < 8): outer is And, both children are comparisons *)
    match parse "fn f(a: i32, b: i32) i32 { return a >= 0 && b < 8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.And,
             { desc = Ast.BinOp (Ast.Ge, _, _); _ },
             { desc = Ast.BinOp (Ast.Lt, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected And(Ge, Lt)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "&& has higher prec than ||" `Quick (fun () ->
    (* a || b && c  ->  a || (b && c): outer is Or *)
    match parse "fn f(a: i32, b: i32, c: i32) i32 { return a || b && c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Or, _,
             { desc = Ast.BinOp (Ast.And, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Or(_, And(_, _))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "if without else" `Quick (fun () ->
    match parse "fn f(x: i32) { if (x == 0) { x = 1; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.If (_, [_], []) -> ()
         | _ -> Alcotest.fail "expected If with empty else")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "else if chain" `Quick (fun () ->
    match parse "fn f(x: i32) i32 {
      if (x == 1) { return 1; }
      else if (x == 2) { return 2; }
      else { return 0; }
    }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.If (_, [_], [inner]) ->
             (match inner.desc with
              | Ast.If (_, [_], [_]) -> ()
              | _ -> Alcotest.fail "else branch should be If")
         | _ -> Alcotest.fail "expected If with else-if")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Unary minus --------------------------------------------- *)

  Alcotest.test_case "unary minus desugars to Sub from zero" `Quick (fun () ->
    match parse "fn f() i32 { return -42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Sub,
                                 { desc = Ast.IntLit 0L; _ },
                                 { desc = Ast.IntLit 42L; _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(BinOp(Sub, IntLit 0, IntLit 42))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- sizeof -------------------------------------------------- *)

  Alcotest.test_case "sizeof(T) parses to SizeOf" `Quick (fun () ->
    match parse "fn f() usize { return sizeof(i32); }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.SizeOf Ast.TypeI32; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(SizeOf TypeI32)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "sizeof(StructName) parses to SizeOf TypeNamed" `Quick (fun () ->
    match parse "struct P { x: i32; } fn f() usize { return sizeof(P); }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.SizeOf (Ast.TypeNamed "P"); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(SizeOf (TypeNamed P))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "offsetof(T, field) parses to OffsetOf" `Quick (fun () ->
    match parse "struct P { x: u8; y: i32; } fn f() usize { return offsetof(P, y); }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.OffsetOf (Ast.TypeNamed "P", "y"); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(OffsetOf(TypeNamed P, y))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- use "path"; (GitHub issue #55) ------------------------- *)

  Alcotest.test_case "use \"path\"; parses to UseDef" `Quick (fun () ->
    match parse "use \"examples/common/netutil.tkb\";
                  fn f() {}" with
    | [Ast.UseDef "examples/common/netutil.tkb"; Ast.FuncDef _] -> ()
    | _ -> Alcotest.fail "expected [UseDef; FuncDef]"
  );

  Alcotest.test_case "use as a bare identifier is now a syntax error (reserved keyword)" `Quick
    (fun () ->
       match parse "fn use() {}" with
       | _ -> Alcotest.fail "expected a syntax error"
       | exception Parser.Error -> ()
  );

  (* -- as cast ----------------------------------------------- *)

  Alcotest.test_case "as cast to u8" `Quick (fun () ->
    match parse "fn f(n: i32) u8 { return n as u8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Cast (Ast.TypeU8,
                                 { desc = Ast.Var "n"; _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(Cast(TypeChar, Var n))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "as cast to i32" `Quick (fun () ->
    match parse "fn f(c: u8) i32 { return c as i32; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Cast (Ast.TypeI32,
                                 { desc = Ast.Var "c"; _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(Cast(TypeInt, Var c))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "as has lower precedence than arithmetic" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) u8 { return a + b as u8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Cast (Ast.TypeU8,
                                 { desc = Ast.BinOp (Ast.Add, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Cast(TypeChar, BinOp(Add, ...)) -- as must bind looser than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Bitwise operations ------------------------------------------------ *)

  Alcotest.test_case "bitwise AND expression" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n & 15; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Band" Ast.Band op
         | _ -> Alcotest.fail "expected Return(BinOp Band)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "right shift expression" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n >> 4; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Shr" Ast.Shr op
         | _ -> Alcotest.fail "expected Return(BinOp Shr)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case ">> binds tighter than &" `Quick (fun () ->
    (* n >> 4 & 0xf  should parse as  (n >> 4) & 0xf *)
    match parse "fn f(n: i32) i32 { return n >> 4 & 15; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Band,
                                 { desc = Ast.BinOp (Ast.Shr, _, _); _ }, _); _ }) -> ()
         | _ -> Alcotest.fail "expected Band(Shr(...), 15) -- >> must bind tighter than &")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "& binds tighter than comparison" `Quick (fun () ->
    (* n & 15 == 0  should parse as  (n & 15) == 0 *)
    match parse "fn f(n: i32) i32 { return n & 15 == 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Eq,
                                 { desc = Ast.BinOp (Ast.Band, _, _); _ }, _); _ }) -> ()
         | _ -> Alcotest.fail "expected Eq(Band(...), 0) -- & must bind tighter than ==")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "modulo BinOp" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n % 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Mod" Ast.Mod op
         | _ -> Alcotest.fail "expected Return(BinOp Mod)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "% binds tighter than +" `Quick (fun () ->
    (* a + b % 3  should parse as  a + (b % 3) *)
    match parse "fn f(a: i32, b: i32) i32 { return a + b % 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Add, _,
                                 { desc = Ast.BinOp (Ast.Mod, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Add(a, Mod(b,3)) -- % must bind tighter than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bitwise OR expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a | b; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Bor" Ast.Bor op
         | _ -> Alcotest.fail "expected Return(BinOp Bor)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "| binds looser than ==" `Quick (fun () ->
    (* a == 0 | b == 0  should parse as  (a == 0) | (b == 0) *)
    match parse "fn f(a: i32, b: i32) i32 { return a == 0 | b == 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Bor,
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ },
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Bor(Eq(...),Eq(...)) -- | must bind looser than ==")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "left shift expression" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n << 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Shl" Ast.Shl op
         | _ -> Alcotest.fail "expected Return(BinOp Shl)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bitwise XOR expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a ^ b; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (op, _, _); _ }) ->
             Alcotest.check binop_t "op is Bxor" Ast.Bxor op
         | _ -> Alcotest.fail "expected Return(BinOp Bxor)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "^ binds tighter than |" `Quick (fun () ->
    (* a | b ^ c  should parse as  a | (b ^ c) *)
    match parse "fn f(a: i32, b: i32, c: i32) i32 { return a | b ^ c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Bor, _,
                                 { desc = Ast.BinOp (Ast.Bxor, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Bor(a, Bxor(b,c)) -- ^ must bind tighter than |")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "== binds tighter than ^" `Quick (fun () ->
    (* a ^ b == c  should parse as  a ^ (b == c)  -- same as C *)
    match parse "fn f(a: i32, b: i32, c: i32) i32 { return a ^ b == c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Bxor, _,
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Bxor(a, Eq(b,c)) -- == must bind tighter than ^")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "array write arr[i]=v produces Assign(Index(...))" `Quick (fun () ->
    match parse "fn f(arr: *u8, i: i32) { arr[i] = 'X'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Index ({ desc = Ast.Var "arr"; _ }, { desc = Ast.Var "i"; _ }); _ },
             { desc = Ast.IntLit 88L; _ }); _ } -> ()   (* 'X' = 88 *)
         | _ -> Alcotest.fail "expected Expr(Assign(Index(arr, Var i), IntLit 88))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Arrays ------------------------------------------------------ *)

  Alcotest.test_case "array type annotation parses" `Quick (fun () ->
    match parse "fn f() { let mut buf: [u8; 8]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "buf", Some (Ast.TypeArray (Ast.TypeU8, 8)), None, None) -> ()
         | _ -> Alcotest.fail "expected Let(mut, buf, TypeArray(u8,8), None)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "array indexing arr[i] produces Index node" `Quick (fun () ->
    match parse "fn f(arr: *u8, i: i32) u8 { return arr[i]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Index ({ desc = Ast.Var "arr"; _ }, { desc = Ast.Var "i"; _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(Index(arr, Var i))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "arr[i] binds tighter than addition" `Quick (fun () ->
    (* a + arr[i]  should parse as  a + Index(arr,i), not Index(a+arr,i) *)
    match parse "fn f(a: i32, arr: *u8, i: i32) i32 { return a + arr[i]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Add, { desc = Ast.Var "a"; _ },
                                 { desc = Ast.Index ({ desc = Ast.Var "arr"; _ }, _); _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Add(a, Index(arr,...)) -- [] must bind tighter than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Function pointer types -------------------------------------------- *)

  Alcotest.test_case "fn pointer type with no args parses" `Quick (fun () ->
    match parse "fn f(h: fn() -> void) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([], Ast.TypeVoid, None)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn() -> void"
  );

  Alcotest.test_case "fn pointer type with one arg parses" `Quick (fun () ->
    match parse "fn f(h: fn(i32) -> u8) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([Ast.TypeI32], Ast.TypeU8, None)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn(i32) -> u8"
  );

  Alcotest.test_case "fn pointer type with multiple args parses" `Quick (fun () ->
    match parse "fn f(h: fn(i32, u8) -> i32) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([Ast.TypeI32; Ast.TypeU8], Ast.TypeI32, None)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn(i32, u8) -> i32"
  );

  Alcotest.test_case "let variable with fn pointer type annotation parses" `Quick (fun () ->
    match parse "fn foo() {} fn f() { let h: fn() -> void = foo; }" with
    | [Ast.FuncDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (false, "h", Some (Ast.TypeFn ([], Ast.TypeVoid, None)), Some _, None) -> ()
         | _ -> Alcotest.fail "expected Let(h, TypeFn([], void), Some(foo))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "Slice 5 function pointer effect contracts parse" `Quick (fun () ->
    match parse
      "fn f(safe: fn !{}() -> void,
            blocking: fn !{may_block}(i32) -> i32) {}" with
    | [Ast.FuncDef { params =
          [("safe", Some (Ast.TypeFn ([], Ast.TypeVoid, Some [])));
           ("blocking", Some (Ast.TypeFn
             ([Ast.TypeI32], Ast.TypeI32, Some ["may_block"])))]; _ }] -> ()
    | _ -> Alcotest.fail "expected explicit function-pointer effect rows"
  );

  (* -- Struct syntax ------------------------------------------------ *)

  Alcotest.test_case "struct definition parses" `Quick (fun () ->
    match parse "struct Point { x: i32; y: i32; }" with
    | [Ast.StructDef ("Point", fields, false, None, _, _)] ->
        Alcotest.(check int) "field count" 2 (List.length fields);
        let (n0, t0) = List.nth fields 0 in
        let (n1, t1) = List.nth fields 1 in
        Alcotest.(check string) "field0 name" "x" n0;
        Alcotest.(check type_t) "field0 type" Ast.TypeI32 t0;
        Alcotest.(check string) "field1 name" "y" n1;
        Alcotest.(check type_t) "field1 type" Ast.TypeI32 t1
    | _ -> Alcotest.fail "expected StructDef(Point, [x:i32; y:i32])"
  );

  Alcotest.test_case "struct type in function param parses" `Quick (fun () ->
    match parse "struct P { x: i32; } fn f(p: *P) -> i32 { return p.x; }" with
    | [Ast.StructDef _; Ast.FuncDef { params = [("p", Some (Ast.TypePtr (Ast.TypeNamed "P")))]; _ }] -> ()
    | _ -> Alcotest.fail "expected *P param type"
  );

  Alcotest.test_case "field access expression parses to FieldGet" `Quick (fun () ->
    match parse "struct P { x: i32; } fn f(p: *P) -> i32 { return p.x; }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.FieldGet ({ desc = Ast.Var "p"; _ }, "x"); _ }) -> ()
         | _ -> Alcotest.fail "expected Return(FieldGet(p, x))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "field assignment statement parses to Assign(FieldGet(...))" `Quick (fun () ->
    match parse "fn f() { p.x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.FieldGet ({ desc = Ast.Var "p"; _ }, "x"); _ },
             { desc = Ast.IntLit 5L; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(FieldGet(p, x), 5))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "indexed field assignment parses to Assign(FieldGet(Index(...)))" `Quick (fun () ->
    match parse "fn f(i: i32) { descs[i].value = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.FieldGet (
                 { desc = Ast.Index ({ desc = Ast.Var "descs"; _ }, { desc = Ast.Var "i"; _ }); _ },
                 "value"); _ },
             { desc = Ast.IntLit 5L; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(FieldGet(Index(descs, i), value), 5))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "indexed compound field assignment parses" `Quick (fun () ->
    match parse "fn f(i: i32) { descs[i].value += 1; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             ({ desc = Ast.FieldGet ({ desc = Ast.Index ({ desc = Ast.Var "descs"; _ }, _); _ }, "value"); _ } as lhs),
             { desc = Ast.BinOp (Ast.Add, load, { desc = Ast.IntLit 1L; _ }); _ }); _ }
           when lhs == load -> ()
         | _ -> Alcotest.fail "expected indexed Assign(FieldGet, BinOp) compound desugaring")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "field access binds tighter than addition" `Quick (fun () ->
    (* p.x + p.y should parse as (p.x) + (p.y), not p.(x + p).y *)
    match parse "struct P { x: i32; } fn f(p: *P) -> i32 { return p.x + p.x; }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.BinOp (Ast.Add,
               { desc = Ast.FieldGet _; _ },
               { desc = Ast.FieldGet _; _ }); _ }) -> ()
         | _ -> Alcotest.fail "expected Add(FieldGet, FieldGet)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* GitHub issue #217: s.field[i] parses directly, with no manual `let`
     workaround needed to spell an array-typed struct field's indexing. *)
  Alcotest.test_case
    "struct-field array indexing s.field[i] parses to Index(FieldGet(...))" `Quick
    (fun () ->
      match parse
        "struct Core { next_free: [usize; 8]; } \
         fn f(c: *Core, i: usize) -> usize { return c.next_free[i]; }" with
      | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
          (match s.desc with
           | Ast.Return (Some { desc = Ast.Index (
               { desc = Ast.FieldGet ({ desc = Ast.Var "c"; _ }, "next_free"); _ },
               { desc = Ast.Var "i"; _ }); _ }) -> ()
           | _ -> Alcotest.fail "expected Return(Index(FieldGet(c, next_free), Var i))")
      | _ -> Alcotest.fail "unexpected structure"
    );

  Alcotest.test_case "packed struct definition parses with is_packed=true" `Quick (fun () ->
    match parse "struct packed Hdr { a: u8; b: u16; }" with
    | [Ast.StructDef ("Hdr", fields, true, None, _, _)] ->
        Alcotest.(check int) "field count" 2 (List.length fields)
    | _ -> Alcotest.fail "expected StructDef(Hdr, [...], true)"
  );

  Alcotest.test_case "normal struct definition parses with is_packed=false" `Quick (fun () ->
    match parse "struct Hdr { a: u8; b: u16; }" with
    | [Ast.StructDef ("Hdr", _, false, None, _, _)] -> ()
    | _ -> Alcotest.fail "expected is_packed=false"
  );

  Alcotest.test_case "struct align(N) parses with align_bytes=Some N" `Quick (fun () ->
    match parse "struct Vec4 align(16) { x: i32; y: i32; z: i32; w: i32; }" with
    | [Ast.StructDef ("Vec4", fields, false, Some 16, _, _)] ->
        Alcotest.(check int) "field count" 4 (List.length fields)
    | _ -> Alcotest.fail "expected StructDef(Vec4, [...], false, Some 16)"
  );

  Alcotest.test_case "struct packed align(N) parses with both flags" `Quick (fun () ->
    match parse "struct packed Hdr align(4) { a: u8; b: u16; }" with
    | [Ast.StructDef ("Hdr", _, true, Some 4, _, _)] -> ()
    | _ -> Alcotest.fail "expected is_packed=true, align_bytes=Some 4"
  );

  (* GitHub issue #186 follow-up: `struct packed be Name { ... }` sugar
     auto-promotes eligible multi-byte integer fields to their `*be` type
     (u16->u16be, u32->u32be, refined-over-either preserves the range) --
     u8 and other field kinds are left exactly as written. *)
  Alcotest.test_case "struct packed be: u16/u32 fields promoted, u8 untouched" `Quick
    (fun () ->
      match parse
        "struct packed be WireHdr { magic: u16; ttl: u8; seq: u32; }"
      with
      | [Ast.StructDef ("WireHdr",
          [("magic", Ast.TypeU16Be); ("ttl", Ast.TypeU8); ("seq", Ast.TypeU32Be)],
          true, None, _, _)] -> ()
      | _ -> Alcotest.fail
          "expected magic:u16be, ttl:u8 (unchanged), seq:u32be");

  Alcotest.test_case "struct packed be: a refined u16 field keeps its range" `Quick
    (fun () ->
      match parse
        "struct packed be WireHdr { len: {20..<1501 as u16}; }"
      with
      | [Ast.StructDef ("WireHdr",
          [("len", Ast.TypeRefined (20, 1501, Ast.TypeU16Be))],
          true, None, _, _)] -> ()
      | _ -> Alcotest.fail "expected len: {20..<1501 as u16be}");

  Alcotest.test_case "struct packed be align(N) parses with all three flags" `Quick
    (fun () ->
      match parse "struct packed be Hdr align(4) { a: u16; }" with
      | [Ast.StructDef ("Hdr", [("a", Ast.TypeU16Be)], true, Some 4, _, _)] -> ()
      | _ -> Alcotest.fail
          "expected is_packed=true, align_bytes=Some 4, a promoted to u16be");

  (* -- Enum syntax ------------------------------------------------- *)

  Alcotest.test_case "exhaustive enum definition parses to EnumDef" `Quick (fun () ->
    match parse "enum Color: u8 { Red = 0; Green = 1; Blue = 2; }" with
    | [Ast.EnumDef ("Color", Some Ast.TypeU8, variants, false)] ->
        Alcotest.(check int) "3 variants" 3 (List.length variants);
        Alcotest.(check string) "variant0 name" "Red"   (fst (List.nth variants 0));
        Alcotest.(check string) "variant1 name" "Green" (fst (List.nth variants 1));
        Alcotest.(check (option int)) "variant0 value" (Some 0) (snd (List.nth variants 0))
    | _ -> Alcotest.fail "expected EnumDef(Color, u8, 3 variants, false)"
  );

  Alcotest.test_case "non-exhaustive enum with _ marker parses (is_ne = true)" `Quick (fun () ->
    match parse "enum EtherType: u16 { IPv4 = 0x0800; _; }" with
    | [Ast.EnumDef ("EtherType", Some Ast.TypeU16, variants, true)] ->
        Alcotest.(check int) "1 named variant" 1 (List.length variants)
    | _ -> Alcotest.fail "expected EnumDef(EtherType, u16, 1 variant, true)"
  );

  Alcotest.test_case "enum default underlying type is u32" `Quick (fun () ->
    match parse "enum Dir { North; South; }" with
    | [Ast.EnumDef ("Dir", None, variants, false)] ->
        Alcotest.(check int) "2 variants" 2 (List.length variants)
    | _ -> Alcotest.fail "expected EnumDef(Dir, None, 2 variants, false)"
  );

  Alcotest.test_case "enum variant expression parses to EnumVariant" `Quick (fun () ->
    match parse "enum Color: u8 { Red = 0; } fn f() { let c = Color::Red; }" with
    | [Ast.EnumDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.EnumVariant ("Color", "Red"); _ }, _) -> ()
         | _ -> Alcotest.fail "expected Let(_, EnumVariant(Color, Red))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "match with variant arm parses to Match/ArmVariant" `Quick (fun () ->
    match parse "enum Color: u8 { Red = 0; }
                 fn f(c: Color) { match c { Color::Red => { let x = 0; } } }" with
    | [Ast.EnumDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Match (_, [Ast.ArmVariant ("Color", "Red", None, [_])]) -> ()
         | _ -> Alcotest.fail "expected Match(_, [ArmVariant(Color,Red,[_])])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "match wildcard arm parses to ArmWild" `Quick (fun () ->
    match parse "enum Color: u8 { Red = 0; }
                 fn f(c: Color) { match c {
                   Color::Red => { let x = 0; }
                   _ => { let y = 1; } } }" with
    | [Ast.EnumDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Match (_, [Ast.ArmVariant _; Ast.ArmWild [_]]) -> ()
         | _ -> Alcotest.fail "expected Match(_, [ArmVariant, ArmWild])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- match on primitive types (GitHub issue #151) ----------------- *)

  Alcotest.test_case "match with literal-integer arm parses to ArmIntLit" `Quick (fun () ->
    match parse "fn f(v: i32) { match v { 0 => { let x = 0; } _ => { let y = 1; } } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Match (_, [Ast.ArmIntLit ([0], [_]); Ast.ArmWild [_]]) -> ()
         | _ -> Alcotest.fail "expected Match(_, [ArmIntLit([0],_), ArmWild])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "match with negative literal-integer arm parses to ArmIntLit" `Quick (fun () ->
    match parse "fn f(v: i32) { match v { -1 => { let x = 0; } _ => { let y = 1; } } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Match (_, [Ast.ArmIntLit ([-1], [_]); Ast.ArmWild [_]]) -> ()
         | _ -> Alcotest.fail "expected Match(_, [ArmIntLit([-1],_), ArmWild])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "match with pipe-separated OR-pattern literal arm parses to one ArmIntLit" `Quick (fun () ->
    (* GitHub issue #156: N1 | N2 | ... => { ... } shares one body across
       several literals, mirroring OCaml's/Rust's own pattern
       alternation -- one ArmIntLit with a multi-element literal list,
       not several arms. *)
    match parse "fn f(v: i32) { match v { 1 | 2 | -3 => { let x = 0; } _ => { let y = 1; } } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Match (_, [Ast.ArmIntLit ([1; 2; -3], [_]); Ast.ArmWild [_]]) -> ()
         | _ -> Alcotest.fail "expected Match(_, [ArmIntLit([1;2;-3],_), ArmWild])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- extern fn --------------------------------------------------- *)

  Alcotest.test_case "extern fn without return type parses" `Quick (fun () ->
    match parse "extern fn uart_putc(c: u8);" with
    | [Ast.ExternFuncDef ("uart_putc", [("c", Some Ast.TypeU8)], None, None)] -> ()
    | _ -> Alcotest.fail "expected ExternFuncDef(uart_putc, [c:u8], None)"
  );

  Alcotest.test_case "extern fn with return type parses" `Quick (fun () ->
    match parse "extern fn uart_getc() -> u8;" with
    | [Ast.ExternFuncDef ("uart_getc", [], Some Ast.TypeU8, None)] -> ()
    | _ -> Alcotest.fail "expected ExternFuncDef(uart_getc, [], Some u8)"
  );

  (* -- String literals -------------------------------------------- *)

  Alcotest.test_case "string literal parses to StringLit" `Quick (fun () ->
    match parse "fn f() { let s = \"hello\"; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.StringLit "hello"; _ }, _) -> ()
         | _ -> Alcotest.fail "expected Let(_, StringLit \"hello\")")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "string literal NUL escape is one zero byte" `Quick (fun () ->
    match parse "fn f() { let s = \"a\\0b\"; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.StringLit value; _ }, _) ->
             Alcotest.(check int) "byte length" 3 (String.length value);
             Alcotest.(check int) "prefix" 97 (Char.code value.[0]);
             Alcotest.(check int) "embedded NUL" 0 (Char.code value.[1]);
             Alcotest.(check int) "suffix" 98 (Char.code value.[2])
         | _ -> Alcotest.fail "expected Let(_, StringLit with embedded NUL)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- -> return type syntax ------------------------------------------- *)

  Alcotest.test_case "arrow return type syntax -> i32 parses" `Quick (fun () ->
    match parse "fn f() -> i32 { return 0; }" with
    | [Ast.FuncDef { ret_type = Some Ast.TypeI32; _ }] -> ()
    | _ -> Alcotest.fail "expected ret_type = Some TypeInt"
  );

  (* -- Struct literals -------------------------------------------- *)

  Alcotest.test_case "struct literal { e, e } parses to StructLit" `Quick (fun () ->
    match parse "fn f() { let mut p: P = {1, 2}; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "p", Some (Ast.TypeNamed "P"),
                    Some { desc = Ast.StructLit [_; _]; _ }, None) -> ()
         | _ -> Alcotest.fail "expected Let(mut, p, TypeNamed P, StructLit [_, _])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "opaque struct declaration parses" `Quick (fun () ->
    match parse "opaque struct Token;" with
    | [Ast.OpaqueStructDef ("Token", Ast.KindPlain, _, _)] -> ()
    | _ -> Alcotest.fail "expected OpaqueStructDef(Token)"
  );

  Alcotest.test_case "affine opaque struct and borrow parameter parse" `Quick (fun () ->
    match parse "affine opaque struct Token; fn inspect(t: borrow *Token) {}" with
    | [Ast.OpaqueStructDef ("Token", Ast.KindAffine, _, _);
       Ast.FuncDef { params = [("t", Some (Ast.TypeBorrow (Ast.TypePtr
         (Ast.TypeNamed "Token"))))]; _ }] -> ()
    | _ -> Alcotest.fail "expected affine opaque Token and borrowed pointer"
  );

  (* -- Compound pointer assignment ------------------------------------------ *)

  Alcotest.test_case "complex pointer assign *(expr) = v parses to Assign(Deref(...))" `Quick (fun () ->
    match parse "fn f(arr: *i32, i: i32) { *(arr + i) = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Deref { desc = Ast.BinOp (Ast.Add, _, _); _ }; _ },
             { desc = Ast.IntLit 42L; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(Deref(BinOp(Add,...)), 42))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Taking address of struct fields --------------------------- *)

  Alcotest.test_case "addrof struct field parses to AddrOf(FieldGet)" `Quick (fun () ->
    match parse "fn f() { let q = &p.x; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.AddrOf
             { desc = Ast.FieldGet _; _ }; _ }, _) -> ()
         | _ -> Alcotest.fail "expected Let(_, AddrOf(FieldGet(...)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Remaining escape characters ---------------------------------------- *)

  Alcotest.test_case "tab escape u8 literal '\\t'" `Quick (fun () ->
    match parse "fn f() { let t = '\\t'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.IntLit 9L; _ }, _) -> ()
         | _ -> Alcotest.fail "expected IntLit 9 (tab = ASCII 9)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "backslash escape u8 literal '\\\\'" `Quick (fun () ->
    match parse "fn f() { let bs = '\\\\'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.IntLit 92L; _ }, _) -> ()
         | _ -> Alcotest.fail "expected IntLit 92 (backslash = ASCII 92)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Block statements ------------------------------------------------ *)

  Alcotest.test_case "block statement parses to Block" `Quick (fun () ->
    match parse "fn f() { { let x = 1; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Block [_] -> ()
         | _ -> Alcotest.fail "expected Block([Let ...])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Comments -------------------------------------------------- *)

  Alcotest.test_case "line comment // is ignored" `Quick (fun () ->
    match parse "// this is a comment\nfn f() i32 { return 1; }" with
    | [Ast.FuncDef { name = "f"; _ }] -> ()
    | _ -> Alcotest.fail "expected single FuncDef f"
  );

  Alcotest.test_case "inline line comment after code" `Quick (fun () ->
    match parse "fn f() i32 { return 42; // answer\n}" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit 42L; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "block comment /* */ is ignored" `Quick (fun () ->
    match parse "fn f() i32 { /* skip this */ return 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit 0L; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 0)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "multi-line block comment is ignored" `Quick (fun () ->
    match parse "fn f() i32 {\n  /*\n   * multi\n   * line\n   */\n  return 7;\n}" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.IntLit 7L; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 7)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Bitwise NOT and compound assignment tests ---------------------- *)

  Alcotest.test_case "bitwise NOT parses to Bnot" `Quick (fun () ->
    match parse "fn f(x: i32) i32 { return ~x; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return (Some { desc = Ast.Bnot { desc = Ast.Var "x"; _ }; _ }) -> ()
         | _ -> Alcotest.fail "expected Return(Bnot(Var x))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "compound += desugars to Assign(BinOp(Add))" `Quick (fun () ->
    match parse "fn f() { let mut x = 0; x += 1; }" with
    | [Ast.FuncDef { body = [_let; s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Var "x"; _ },
             { desc = Ast.BinOp (Ast.Add, { desc = Ast.Var "x"; _ }, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(Var x, BinOp(Add, Var x, _)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "compound |= desugars to Assign(BinOp(Bor))" `Quick (fun () ->
    match parse "fn f() { let mut x = 0; x |= 2; }" with
    | [Ast.FuncDef { body = [_let; s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Var "x"; _ },
             { desc = Ast.BinOp (Ast.Bor, { desc = Ast.Var "x"; _ }, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(Var x, BinOp(Bor, Var x, _)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "compound &= on deref desugars to Assign(Deref, BinOp(Band))" `Quick (fun () ->
    match parse "fn f(p: *i32) { *p &= 0xff; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Expr { desc = Ast.Assign (
             { desc = Ast.Deref _; _ },
             { desc = Ast.BinOp (Ast.Band, { desc = Ast.Deref _; _ }, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Expr(Assign(Deref _, BinOp(Band, Deref _, _)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

]

(* -- Type inference tests -------------------------------------------------- *)

(* Shared mini fixture for owner-derived region slice tests (issue #106,
   TAKIBI_CORE.md post-Slice-6 order item 1): a linear indexed owner, a
   region-annotated frame accessor returning a slice of a global buffer,
   and a sink release. Mirrors net_rx_frame/net_rx_release's real shape. *)
let region_fixture =
  "private linear struct RegOwn[d: usize] {
     private idx: {0..<4 as usize} @ d;
   }
   let mut reg_bufs: [u8; 8192];
   fn reg_make(idx: {0..<4 as usize} @ d) -> RegOwn[d] {
     let mut own: RegOwn[d] = { idx };
     return own;
   }
   fn reg_frame(o: borrow RegOwn[d]) -> [u8; 2048..] @ d {
     let idx: {0..<4 as usize} = o.idx;
     let off: usize = idx * 2048;
     return reg_bufs[off..<off + 2048];
   }
   fn reg_release(o: sink RegOwn[d]) {}
   "

(* Issue #128: a pointer returned by an accessor can be tied to the static
   identity carried by a borrowed lock guard. The pointer stays ordinary
   runtime data, but its local binding cannot outlive that authority. *)
let authority_pointer_fixture =
  "linear view AuthorityGuard[lock: addr];
   struct AuthorityData { value: i32; }
   let mut authority_lock_word: i32;
   let mut authority_data: AuthorityData;
   let mut authority_stash: *AuthorityData;
   fn authority_lock(m: *i32 @ lock) -> AuthorityGuard[lock] {
     return view AuthorityGuard[lock];
   }
   fn authority_unlock(g: sink AuthorityGuard[lock], m: *i32 @ lock) {}
   fn authority_access(g: borrow AuthorityGuard[lock])
       -> *AuthorityData @ lock {
     return &authority_data;
   }
   "

(* The real network backends use this shape for asynchronous in-place TX:
   starting DMA consumes the RX owner and returns a distinct linear owner.
   Only the completion transition restores the erased acquisition permit. *)
let async_tx_fixture =
  "linear struct AsyncRx[d: usize] {
     index: {0..<4 as usize} @ d;
     len: i32;
   }
   linear struct AsyncTx[d: usize] {
     index: {0..<4 as usize} @ d;
     tx_index: isize;
   }
   affine view AsyncReady;
   fn async_rx_make(index: {0..<4 as usize} @ d, len: i32) -> AsyncRx[d] {
     let mut frame: AsyncRx[d] = { index, len };
     return frame;
   }
   fn async_tx_start(frame: sink AsyncRx[d], tx_index: isize) -> AsyncTx[d] {
     let mut in_flight: AsyncTx[d] = { frame.index, tx_index };
     return in_flight;
   }
   fn async_tx_complete(in_flight: sink AsyncTx[d]) -> AsyncReady {
     return view AsyncReady;
   }
   fn async_rx_release(frame: sink AsyncRx[d]) -> AsyncReady {
     return view AsyncReady;
   }
   "

let infer_tests = [
  (* GitHub issue #327 Stage 1: two independently-broken functions in one
     program both get reported, instead of the second's error being
     hidden by the first aborting the whole compilation. *)
  Alcotest.test_case
    "two independently-broken functions both surface as one MultiTypeError"
    `Quick
    (expect_multi_type_error ["issue327_unbound_one"; "issue327_unbound_two"]
       "fn issue327_broken_one() -> i32 { return issue327_unbound_one; }
        fn issue327_ok() -> i32 { return 1; }
        fn issue327_broken_two() -> i32 { return issue327_unbound_two; }");

  Alcotest.test_case
    "three independently-broken functions all surface, not just the first two"
    `Quick
    (expect_multi_type_error
       ["issue327_unbound_a"; "issue327_unbound_b"; "issue327_unbound_c"]
       "fn issue327_broken_a() -> i32 { return issue327_unbound_a; }
        fn issue327_broken_b() -> i32 { return issue327_unbound_b; }
        fn issue327_broken_c() -> i32 { return issue327_unbound_c; }");

  (* Negative control: exactly one broken function among otherwise-correct
     ones still raises a plain Types.TypeError, not MultiTypeError -- every
     other expect_type_error test in this file already depends on this,
     but this one names it explicitly as issue #327's own compatibility
     requirement. *)
  Alcotest.test_case
    "a single broken function still raises a plain TypeError, not MultiTypeError"
    `Quick
    (expect_type_error "issue327_unbound_solo"
       "fn issue327_ok_a() -> i32 { return 1; }
        fn issue327_broken_solo() -> i32 { return issue327_unbound_solo; }
        fn issue327_ok_b() -> i32 { return 2; }");

  (* GitHub issue #327 Stage 1 follow-up: unsafe_depth is deliberately not
     exception-safe within a single infer_func call (see the
     Unsafe/UnsafeBlock case comments in infer_expr/infer_stmt). Before
     Pass 3 could catch-and-continue past one function's TypeError, that
     was harmless -- the whole infer_program call aborted immediately, so
     no later function could ever observe a leftover non-zero depth. Once
     Pass 3 keeps going, a function that raises WHILE unsafe_depth > 0
     could leak that depth into every function checked after it, silently
     authorizing their own unrelated unsafe-gated casts. This function
     order is the repro: the first function raises from inside `unsafe {
     }` (so unsafe_depth is 1 when the exception escapes), and the second
     function has an unsafe-gated `*io` literal assignment with NO unsafe
     wrapping at all -- it must still be rejected, not silently let
     through by a leaked depth from the first function's failure. *)
  Alcotest.test_case
    "unsafe_depth does not leak across functions when an earlier one \
     raises from inside `unsafe { }`"
    `Quick
    (expect_multi_type_error
       ["issue327_unbound_in_unsafe"; "assigning an integer literal directly"]
       "fn issue327_leak_one() -> u32 {
          unsafe {
            return issue327_unbound_in_unsafe;
          }
        }
        fn issue327_leak_two() -> u32 {
          let p: *io u32 = 0x1000;
          return *p;
        }");

  Alcotest.test_case
    "authority pointer: access before guard consumption is accepted" `Quick
    (fun () ->
      ignore (infer (authority_pointer_fixture ^
        "fn authority_pointer_ok() -> i32 {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           data.value = 7;
           let result: i32 = data.value;
           authority_unlock(guard, &authority_lock_word);
           return result;
         }")));

  Alcotest.test_case
    "authority pointer: field access after unlock is rejected" `Quick
    (expect_type_error
      "pointer 'data' is derived from linear value 'guard' and cannot be used after 'guard' is consumed"
      (authority_pointer_fixture ^
        "fn authority_pointer_after_unlock_bad() -> i32 {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           authority_unlock(guard, &authority_lock_word);
           return data.value;
         }"));

  Alcotest.test_case
    "authority pointer: an immutable alias carries the authority tie" `Quick
    (expect_type_error
      "pointer 'alias' is derived from linear value 'guard' and cannot be used after 'guard' is consumed"
      (authority_pointer_fixture ^
        "fn authority_pointer_alias_bad() -> i32 {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           let alias = data;
           authority_unlock(guard, &authority_lock_word);
           return alias.value;
         }"));

  Alcotest.test_case
    "authority pointer: all matching borrowed authorities constrain lifetime"
    `Quick
    (expect_type_error
      "pointer 'data' is derived from linear value 'first' and cannot be used after 'first' is consumed"
      (authority_pointer_fixture ^
        "fn authority_access_pair(first: borrow AuthorityGuard[lock],
                                  second: borrow AuthorityGuard[lock])
             -> *AuthorityData @ lock {
           return &authority_data;
         }
         fn authority_pointer_pair_bad() -> i32 {
           let first = authority_lock(&authority_lock_word);
           let second = authority_lock(&authority_lock_word);
           let data = authority_access_pair(first, second);
           authority_unlock(first, &authority_lock_word);
           return data.value;
         }"));

  Alcotest.test_case
    "authority pointer: a tied pointer cannot be returned" `Quick
    (expect_type_error "authority-derived pointer 'data' cannot be returned"
      (authority_pointer_fixture ^
        "fn authority_pointer_return_bad() -> *AuthorityData {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           authority_unlock(guard, &authority_lock_word);
           return data;
         }"));

  Alcotest.test_case
    "authority pointer: a tied pointer cannot be stored globally" `Quick
    (expect_type_error
      "authority-derived pointer 'data' cannot be stored into a global"
      (authority_pointer_fixture ^
        "fn authority_pointer_store_bad() {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           authority_stash = data;
           authority_unlock(guard, &authority_lock_word);
         }"));

  Alcotest.test_case
    "authority pointer: the annotation must name a borrowed indexed authority"
    `Quick
    (expect_type_error
      "does not name a static index of any borrow or borrow mut indexed-owner or indexed-view parameter"
      (authority_pointer_fixture ^
        "fn authority_pointer_decl_bad(g: borrow AuthorityGuard[lock])
             -> *AuthorityData @ other {
           return &authority_data;
         }"));

  Alcotest.test_case
    "authority pointer: an integer cannot be a return-region authority" `Quick
    (expect_type_error
      "pointer return annotation '@ 0': a region annotation must name a static parameter"
      (authority_pointer_fixture ^
        "fn authority_pointer_integer_bad(g: borrow AuthorityGuard[lock])
             -> *AuthorityData @ 0 {
           return &authority_data;
         }"));

  Alcotest.test_case
    "async TX: RX owner becomes an indexed in-flight owner until completion" `Quick
    (fun () ->
      ignore (infer (async_tx_fixture ^
        "fn async_tx_ok(index: {0..<4 as usize}, len: i32,
                        tx_index: isize) -> AsyncReady {
           let frame = async_rx_make(index, len);
           let in_flight = async_tx_start(frame, tx_index);
           return async_tx_complete(in_flight);
         }")));

  Alcotest.test_case
    "async TX: RX owner cannot be released while TX is in flight" `Quick
    (expect_type_error "linear value 'frame' was already consumed"
      (async_tx_fixture ^
        "fn async_tx_release_early(index: {0..<4 as usize}, len: i32,
                                   tx_index: isize) {
           let frame = async_rx_make(index, len);
           let in_flight = async_tx_start(frame, tx_index);
           async_rx_release(frame);
           async_tx_complete(in_flight);
         }"));

  Alcotest.test_case
    "region slice: use-then-release lifecycle is accepted" `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "fn reg_ok() -> i32 {
           let idx: {0..<4 as usize} = 1;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let x: u8 = f[0];
           let sub = f[4..<8];
           let y: u8 = sub[0];
           reg_release(o);
           return (x + y) as i32;
         }")));

  Alcotest.test_case
    "region slice: reading the slice after the owner is released is rejected" `Quick
    (expect_type_error
      "slice 'f' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_bad() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           reg_release(o);
           return f[0] as i32;
         }"));

  Alcotest.test_case
    "region slice: an immutable alias carries the taint" `Quick
    (expect_type_error
      "slice 'g' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_alias_bad() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let g = f;
           reg_release(o);
           return g[0] as i32;
         }"));

  Alcotest.test_case
    "region slice: a subslice carries the taint" `Quick
    (expect_type_error
      "slice 'sub' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_sub_bad() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let sub = f[4..<8];
           reg_release(o);
           return sub[0] as i32;
         }"));

  Alcotest.test_case
    "region slice: writing through the slice after release is rejected" `Quick
    (expect_type_error
      "slice 'f' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_write_bad() {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           reg_release(o);
           f[0] = 1;
         }"));

  Alcotest.test_case
    "region slice: release on only one branch still kills later use" `Quick
    (expect_type_error
      "slice 'f' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_branch_bad(c: bool) -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           if (c) {
             reg_release(o);
           } else {
             reg_release(o);
           }
           return f[0] as i32;
         }"));

  Alcotest.test_case
    "region slice: reassigning the binding clears its taint" `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "fn reg_reassign_ok() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let mut f: []u8 = reg_frame(o);
           f = reg_bufs as []u8;
           reg_release(o);
           return f[0] as i32;
         }")));

  Alcotest.test_case
    "region slice: an authority cannot be rebound while a derived slice is live"
    `Quick
    (expect_type_error
      "cannot rebind authority 'o' while derived value 'f' still depends on its current lifetime"
      (region_fixture ^
        "fn reg_authority_rebind_bad() {
           let idx: {0..<4 as usize} = 0;
           let mut o = reg_make(idx);
           let f = reg_frame(o);
           reg_release(o);
           o = reg_make(idx);
           let x: u8 = f[0];
           reg_release(o);
         }"));

  Alcotest.test_case
    "region slice: a local binder cannot shadow a live authority" `Quick
    (expect_type_error
      "cannot rebind authority 'o' while derived value 'f' still depends on its current lifetime"
      (region_fixture ^
        "fn reg_authority_shadow_bad() {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let o = reg_make(idx);
         }"));

  Alcotest.test_case
    "region slice: clearing the derived binding permits authority reuse" `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "fn reg_authority_rebind_after_clear_ok() {
           let idx: {0..<4 as usize} = 0;
           let mut o = reg_make(idx);
           let mut f: []u8 = reg_frame(o);
           reg_release(o);
           f = reg_bufs as []u8;
           o = reg_make(idx);
           let x: u8 = f[0];
           reg_release(o);
         }")));

  Alcotest.test_case
    "region slice: an ended derived scope permits authority reuse" `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "fn reg_authority_rebind_after_scope_ok() {
           let idx: {0..<4 as usize} = 0;
           let mut o = reg_make(idx);
           {
             let f = reg_frame(o);
             let x: u8 = f[0];
           }
           reg_release(o);
           o = reg_make(idx);
           reg_release(o);
         }")));

  Alcotest.test_case
    "authority pointer: a guard cannot be rebound while a derived pointer is live"
    `Quick
    (expect_type_error
      "cannot rebind authority 'guard' while derived value 'data' still depends on its current lifetime"
      (authority_pointer_fixture ^
        "fn authority_guard_rebind_bad() {
           let mut guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           authority_unlock(guard, &authority_lock_word);
           guard = authority_lock(&authority_lock_word);
           data.value = 1;
           authority_unlock(guard, &authority_lock_word);
         }"));

  Alcotest.test_case
    "region slice: a tied slice cannot be laundered through a tuple" `Quick
    (expect_type_error
      "owner-derived slice 'f' cannot be stored in a tuple"
      (region_fixture ^
        "fn reg_tuple_launder_bad() {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let pair: ([]u8, i32) = (f, 1);
           reg_release(o);
           let (again, n) = pair;
           let x: u8 = again[0];
         }"));

  Alcotest.test_case
    "authority pointer: a tied pointer cannot be laundered through a variant"
    `Quick
    (expect_type_error
      "authority-derived pointer 'data' cannot be stored in a variant payload"
      (authority_pointer_fixture ^
        "variant AuthorityPointerBox { Empty; Data(*AuthorityData); }
         fn authority_variant_launder_bad() {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           let boxed: AuthorityPointerBox = AuthorityPointerBox::Data(data);
           authority_unlock(guard, &authority_lock_word);
           match boxed {
             AuthorityPointerBox::Empty => {}
             AuthorityPointerBox::Data(again) => { again.value = 1; }
           }
         }"));

  Alcotest.test_case
    "region slice: a tied slice cannot be laundered through a struct literal"
    `Quick
    (expect_type_error
      "owner-derived slice 'f' cannot be stored in a struct value"
      (region_fixture ^
        "struct RegionHolder { frame: []u8; }
         fn reg_struct_launder_bad() {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let mut holder: RegionHolder = { f };
           reg_release(o);
         }"));

  Alcotest.test_case
    "region slice: the annotation must name a borrow owner's static index" `Quick
    (expect_type_error
      "does not name a static index of any borrow or borrow mut indexed-owner parameter"
      (region_fixture ^
        "fn reg_decl_bad(o: borrow RegOwn[d]) -> [u8; 8..] @ nosuch {
           return reg_bufs[0..<8];
         }"));

  Alcotest.test_case
    "region slice: the annotation cannot be a static integer" `Quick
    (expect_type_error
      "a region annotation must name a static parameter, not an integer"
      (region_fixture ^
        "fn reg_decl_int_bad(o: borrow RegOwn[d]) -> [u8; 8..] @ 3 {
           return reg_bufs[0..<8];
         }"));

  Alcotest.test_case
    "region slice: an owner-derived slice cannot be returned" `Quick
    (expect_type_error
      "owner-derived slice 'f' cannot be returned from this function"
      (region_fixture ^
        "fn reg_leak(o: borrow RegOwn[d]) -> []u8 {
           let f = reg_frame(o);
           return f;
         }"));

  Alcotest.test_case
    "region slice: a stack-array subslice cannot be returned" `Quick
    (expect_type_error
      "stack-derived slice 'buf' cannot be returned from this function"
      "fn stack_slice_leak() -> [u8; 4..] {
         let mut buf: [u8; 4] = { 1, 2, 3, 4 };
         return buf[0..<4];
       }");

  Alcotest.test_case
    "region slice: stack storage may cross a verified borrow call" `Quick
    (fun () ->
      ignore (infer
        "fn stack_slice_peek(s: borrow [u8; 4..]) -> u8 { return s[0]; }
         fn stack_slice_borrow_ok() -> u8 {
           let mut buf: [u8; 4] = { 1, 2, 3, 4 };
           return stack_slice_peek(buf[0..<4]);
         }"));

  Alcotest.test_case
    "region slice: an array-to-slice cast cannot escape through a retaining call"
    `Quick
    (expect_type_error
      "slice 'buf' is stack-derived and cannot be passed to retaining parameter of 'stack_slice_retain'"
      "fn stack_slice_retain(s: []u8) {}
       fn stack_slice_call_bad() {
         let mut buf: [u8; 4] = { 1, 2, 3, 4 };
         stack_slice_retain(buf as []u8);
       }");

  Alcotest.test_case
    "region slice: an owner-derived slice cannot be stored into a global" `Quick
    (expect_type_error
      "owner-derived slice 'f' cannot be stored into a global"
      (region_fixture ^
        "let mut reg_stash: []u8;
         fn reg_stash_bad(o: borrow RegOwn[d]) {
           let f = reg_frame(o);
           reg_stash = f;
         }"));

  Alcotest.test_case
    "region slice: casting to a raw pointer retains the authority tie" `Quick
    (expect_type_error
      "pointer 'p' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_ptr_hole() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let p: *u8 = reg_frame(o) as *u8;
           reg_release(o);
           return p[0] as i32;
         }"));

  Alcotest.test_case
    "region pointer: pointer arithmetic retains the authority tie" `Quick
    (expect_type_error
      "pointer 'q' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_ptr_arithmetic_bad() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let p: *u8 = reg_frame(o) as *u8;
           let q: *u8 = p + 1;
           reg_release(o);
           return q[0] as i32;
         }"));

  Alcotest.test_case
    "region pointer: pointer-integer-pointer roundtrip retains the tie" `Quick
    (expect_type_error
      "value 'raw' is derived from linear value 'o' and cannot be used after 'o' is consumed"
      (region_fixture ^
        "fn reg_ptr_integer_roundtrip_bad() -> i32 !{unsafe} {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let raw: usize = (reg_frame(o) as *u8) as usize;
           reg_release(o);
           let p: *u8 = unsafe { raw as *u8 };
           return p[0] as i32;
         }"));

  Alcotest.test_case
    "authority pointer: pointer reinterpretation retains the guard tie" `Quick
    (expect_type_error
      "pointer 'bytes' is derived from linear value 'guard' and cannot be used after 'guard' is consumed"
      (authority_pointer_fixture ^
        "fn authority_pointer_cast_bad() -> i32 {
           let guard = authority_lock(&authority_lock_word);
           let data = authority_access(guard);
           let bytes: *u8 = data as *u8;
           authority_unlock(guard, &authority_lock_word);
           return bytes[0] as i32;
         }"));

  Alcotest.test_case
    "region pointer: cast and arithmetic before release remain accepted" `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "fn reg_ptr_before_release_ok() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let p: *u8 = reg_frame(o) as *u8;
           let q: *u8 = p + 1;
           let x: u8 = q[0];
           reg_release(o);
           return x as i32;
         }")));

  (* Before GitHub issue #239, this scenario was caught by the
     authority-tracking pass ("cannot take the address of
     authority-derived pointer... indirect local region tracking is not
     implemented"). #239 now rejects &p's **u8 result type unconditionally,
     for ANY *T local regardless of taint, so this specific laundering
     route is now caught earlier, during ordinary type inference, by a
     strictly more general check. *)
  Alcotest.test_case
    "region pointer: address-of cannot launder the authority tie" `Quick
    (expect_type_error
      "nested pointer indirection"
      (region_fixture ^
        "fn reg_ptr_address_bad() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let mut p: *u8 = reg_frame(o) as *u8;
           let pp: **u8 = &p;
           reg_release(o);
           return 0;
         }"));

  Alcotest.test_case
    "region call: a borrow slice parameter is a verified non-retaining boundary"
    `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "fn reg_peek(f: borrow []u8) -> u8 { return f[0]; }
         fn reg_borrow_call_ok() -> i32 {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           let x: u8 = reg_peek(f);
           reg_release(o);
           return x as i32;
         }")));

  Alcotest.test_case
    "region call: a tied slice cannot enter a retaining parameter" `Quick
    (expect_type_error
      "slice 'f' is authority-derived and cannot be passed to retaining parameter of 'reg_retain'"
      (region_fixture ^
        "fn reg_retain(f: []u8) {}
         fn reg_retaining_call_bad() {
           let idx: {0..<4 as usize} = 0;
           let o = reg_make(idx);
           let f = reg_frame(o);
           reg_retain(f);
           reg_release(o);
         }"));

  Alcotest.test_case
    "region call: a borrow parameter implementation cannot retain its value"
    `Quick
    (expect_type_error
      "owner-derived slice 'f' cannot be stored into a global"
      (region_fixture ^
        "let mut reg_borrow_stash: []u8;
         fn reg_borrow_lie(f: borrow []u8) {
           reg_borrow_stash = f;
         }"));

  (* Before GitHub issue #239, this scenario was caught by the
     authority-tracking pass at `return *p` ("authority-derived pointer
     '<value>' cannot be returned"). #239 now rejects the `borrow **u8`
     parameter type itself, unconditionally, before the function body is
     even analyzed -- a Deref can no longer yield a pointer-typed value at
     all, since nothing can be typed **u8 in the first place. The
     protection this test originally demonstrated (a pointer read out of
     borrowed/authority-tied storage cannot leak by being returned) is
     still covered by the next test below via a struct field instead of a
     dereference. *)
  Alcotest.test_case
    "region call: borrow pointer dereference cannot return a pointer alias"
    `Quick
    (expect_type_error
      "nested pointer indirection"
      "fn borrow_deref_leak(p: borrow **u8) -> *u8 { return *p; }");

  (* Before GitHub issue #240, this scenario was caught by the
     authority-tracking pass at `return h.ptr` ("authority-derived
     pointer '<value>' cannot be returned"). #240 now rejects
     BorrowHolder's own `ptr: *u8` field declaration, unconditionally,
     before the function is even analyzed -- an ordinary struct can no
     longer hold a raw pointer field at all, so the specific danger this
     test demonstrated (a pointer read out of borrowed storage leaking
     by return) is now structurally unreachable, not merely rejected at
     the return site. *)
  Alcotest.test_case
    "region call: borrow pointer field cannot return a pointer alias" `Quick
    (expect_type_error
      "cannot hold pointer type"
      "struct BorrowHolder { ptr: *u8; value: i32; }
       fn borrow_field_leak(h: borrow *BorrowHolder) -> *u8 { return h.ptr; }");

  Alcotest.test_case
    "region call: borrow pointer field may return copied scalar data" `Quick
    (fun () ->
      ignore (infer
        "struct BorrowScalarHolder { value: i32; }
         fn borrow_scalar_copy(h: borrow *BorrowScalarHolder) -> i32 {
           return h.value;
         }"));

  (* Before GitHub issue #240, this scenario was caught by the
     authority-tracking pass's aggregate-copy check. #240 now rejects
     BorrowInner's own `ptr: *u8` field declaration first, for the same
     reason as the test just above -- structurally unreachable, not
     merely rejected once copied. *)
  Alcotest.test_case
    "region call: borrowed nested aggregate cannot launder a pointer field"
    `Quick
    (expect_type_error
      "cannot hold pointer type"
      "struct BorrowInner { ptr: *u8; value: i32; }
       struct BorrowOuter { inner: BorrowInner; }
       fn borrow_nested_leak(h: borrow *BorrowOuter) -> *u8 {
         let mut inner: BorrowInner = h.inner;
         return inner.ptr;
       }");

  Alcotest.test_case
    "region call: indexed owner transition may retain under returned authority"
    `Quick
    (fun () ->
      ignore (infer (region_fixture ^
        "linear struct RegTx[d: usize] {
           idx: {0..<4 as usize} @ d;
         }
         let mut reg_dma_addr: usize;
         fn reg_handoff(o: sink RegOwn[d]) -> RegTx[d] {
           let p: *u8 = reg_frame(o) as *u8;
           reg_dma_addr = p as usize;
           let mut tx: RegTx[d] = { o.idx };
           return tx;
         }")));

  Alcotest.test_case
    "region slice: '@' on a slice parameter stays rejected" `Quick
    (expect_type_error
      "a singleton value cannot live behind a pointer or inside array/slice storage"
      "fn reg_param_bad(s: []u8 @ d) -> i32 { return 0; }");

  Alcotest.test_case
    "Slice 1: indexed linear owner carries the range-proven runtime index" `Quick
    (fun () ->
      ignore (infer
        "private linear struct InfLease[n: usize] {
           private idx: {0..<4 as usize} @ n;
         }
         let mut inf_slots: [i32; 4];
         fn inf_make(idx: {0..<4 as usize} @ n) -> InfLease[n] {
           let mut lease: InfLease[n] = { idx };
           return lease;
         }
         fn inf_read(lease: borrow InfLease[n]) -> i32 {
           return inf_slots[lease.idx];
         }
         fn inf_drop(lease: sink InfLease[n]) {}
         fn inf_ok() -> i32 {
           let lease = inf_make(2);
           let value = inf_read(lease);
           inf_drop(lease);
           return value;
         }"));

  Alcotest.test_case
    "Slice 1: two independently indexed owners cannot satisfy one static identity" `Quick
    (expect_type_error "static value mismatch: 1 vs 0"
      "linear struct InfIdentity[n: usize] { idx: {0..<4 as usize} @ n; }
       fn ii_make(idx: {0..<4 as usize} @ n) -> InfIdentity[n] {
         let mut x: InfIdentity[n] = { idx }; return x;
       }
       fn ii_same(a: borrow InfIdentity[n], b: borrow InfIdentity[n]) {}
       fn ii_drop(x: sink InfIdentity[n]) {}
       fn ii_bad() {
         let a = ii_make(0); let b = ii_make(1); ii_same(a, b);
         ii_drop(a); ii_drop(b);
       }");

  (* GitHub issue #266: an intermediate `let` re-annotation strips a
     singleton-typed value's own static identity (here, `idx`'s tie to
     `n` is lost the moment it flows through `let plain: {0..<4 as usize}
     = idx;`, a bare, un-tied annotation). The struct literal `{ plain }`
     then needs a fresh identity for `plain`, which cannot equal `n`
     (already fixed by the OTHER construction site elsewhere in a real
     program, mirrored here by requiring both fields to share `n`) --
     before this issue's fix, the resulting message named the fresh
     identity as a raw internal counter ("__value136"), not anything
     traceable to source. Mirrors the exact shape found porting
     kernel/drivers/net/virtio_net.tkb (issue #237 M4): `let idx: {0..<8
     as usize} = reply.index;` losing reply.index's own `@ desc` tie. *)
  Alcotest.test_case
    "an intermediate let binding that loses a static identity names the \
     source variable, not an internal counter (issue #266)" `Quick
    (expect_type_error "an anonymous compile-time value (from 'plain'"
      "linear struct Field266Owner[n: usize] { idx: {0..<4 as usize} @ n; }
       fn f266_make(idx: {0..<4 as usize} @ n) -> Field266Owner[n] {
         let plain: {0..<4 as usize} = idx;
         let mut x: Field266Owner[n] = { plain };
         return x;
       }");

  Alcotest.test_case "Slice 1: range is checked before an indexed owner is minted" `Quick
    (expect_type_error "constant value 4 does not fit the refined type {0..<4}"
      "linear struct InfRange[n: usize] { idx: {0..<4 as usize} @ n; }
       fn ir_make(idx: {0..<4 as usize} @ n) -> InfRange[n] {
         let mut x: InfRange[n] = { idx }; return x;
       }
       fn ir_bad() { let x = ir_make(4); }");

  Alcotest.test_case "Slice 1: an indexed struct cannot silently lose its static argument" `Quick
    (expect_type_error "requires 1 static argument"
      "linear struct InfMissing[n: usize] { idx: usize @ n; }
       fn im_bad(x: borrow InfMissing) {} ");

  Alcotest.test_case "Slice 1: implicit universals are fresh at each call" `Quick
    (fun () ->
      ignore (infer
        "linear struct InfFresh[n: usize] { idx: {0..<4 as usize} @ n; }
         fn if_make(idx: {0..<4 as usize} @ n) -> InfFresh[n] {
           let mut x: InfFresh[n] = { idx }; return x;
         }
         fn if_drop(x: sink InfFresh[n]) {}
         fn if_ok() {
           let a = if_make(0); if_drop(a);
           let b = if_make(1); if_drop(b);
         }"));

  Alcotest.test_case "Slice 1: one immutable runtime value keeps one static identity" `Quick
    (fun () ->
      ignore (infer
        "linear struct InfStable[n: usize] { idx: {0..<4 as usize} @ n; }
         fn is_make(idx: {0..<4 as usize} @ n) -> InfStable[n] {
           let mut x: InfStable[n] = { idx }; return x;
         }
         fn is_same(a: borrow InfStable[n], b: borrow InfStable[n]) {}
         fn is_drop(x: sink InfStable[n]) {}
         fn is_ok() {
           let idx: {0..<4 as usize} = 2;
           let a = is_make(idx); let b = is_make(idx); is_same(a, b);
           is_drop(a); is_drop(b);
         }"));

  Alcotest.test_case "Slice 1: an inferred immutable alias preserves singleton identity" `Quick
    (fun () ->
      ignore (infer
        "linear struct InfAlias[n: usize] { idx: {0..<4 as usize} @ n; }
         fn ia_make(idx: {0..<4 as usize} @ n) -> InfAlias[n] {
           let mut x: InfAlias[n] = { idx }; return x;
         }
         fn ia_forward(idx: {0..<4 as usize} @ n) -> InfAlias[n] {
           let alias = idx;
           return ia_make(alias);
         }
         fn ia_drop(x: sink InfAlias[n]) {}
         fn ia_ok() { let x = ia_forward(2); ia_drop(x); }"));

  Alcotest.test_case
    "Slice 1: independent unknown runtime values are generative, not unifiable proofs" `Quick
    (expect_type_error "static value mismatch"
      "linear struct InfGenerative[n: usize] { idx: {0..<4 as usize} @ n; }
       fn ig_make(idx: {0..<4 as usize} @ n) -> InfGenerative[n] {
         let mut x: InfGenerative[n] = { idx }; return x;
       }
       fn ig_same(a: borrow InfGenerative[n], b: borrow InfGenerative[n]) {}
       fn ig_drop(x: sink InfGenerative[n]) {}
       fn ig_bad(x: {0..<4 as usize}, y: {0..<4 as usize}) {
         let a = ig_make(x); let b = ig_make(y); ig_same(a, b);
         ig_drop(a); ig_drop(b);
       }");

  Alcotest.test_case "Slice 1: borrow cannot be returned as a second owner" `Quick
    (expect_type_error "cannot move borrowed value"
      "linear struct InfBorrow[n: usize] { idx: usize @ n; }
       fn ib_clone(x: borrow InfBorrow[n]) -> InfBorrow[n] { return x; }");

  Alcotest.test_case "Slice 3: an affine indexed owner may be left uninitialized" `Quick
    (expect_ok
      "affine struct InfUninit[n: usize] { idx: usize @ n; }
       fn iu_bad() { let mut x: InfUninit[0]; }");

  Alcotest.test_case "Slice 3: assigning over a live affine indexed owner weakens it" `Quick
    (expect_ok
      "affine struct InfOverwrite[n: usize] { idx: usize @ n; }
       fn io_make(idx: usize @ n) -> InfOverwrite[n] {
         let mut x: InfOverwrite[n] = { idx }; return x;
       }
       fn io_drop(x: sink InfOverwrite[n]) {}
       fn io_bad() {
         let mut x = io_make(0); x = io_make(0); io_drop(x);
       }");

  Alcotest.test_case "Slice 1: a borrowed indexed owner cannot be reassigned" `Quick
    (expect_type_error "cannot assign to borrowed value 'x'"
      "linear struct InfBorrowAssign[n: usize] { idx: usize @ n; }
       fn iba_bad(x: borrow InfBorrowAssign[n]) { x = x; }");

  Alcotest.test_case "Slice 1: borrow cannot hide inside a tuple parameter" `Quick
    (expect_type_error "borrow/sink must wrap the entire function parameter type"
      "linear struct InfNestedBorrow[n: usize] { idx: usize @ n; }
       fn inb_bad(x: (borrow InfNestedBorrow[n], i32)) {}");

  Alcotest.test_case "Slice 1: a sink parameter cannot be overwritten" `Quick
    (expect_type_error "cannot assign to sink value 'x'"
      "linear struct InfSinkAssign[n: usize] { idx: usize @ n; }
       fn isa_bad(x: sink InfSinkAssign[n]) { x = x; }");

  Alcotest.test_case "Slice 1: an indexed owner temporary cannot be borrowed and lost" `Quick
    (expect_type_error "linear result of 'it_make' must be moved"
      "linear struct InfTemporary[n: usize] { idx: usize @ n; }
       fn it_make(idx: usize @ n) -> InfTemporary[n] {
         let mut x: InfTemporary[n] = { idx }; return x;
       }
       fn it_read(x: borrow InfTemporary[n]) {}
       fn it_bad() { it_read(it_make(0)); }");

  Alcotest.test_case "Slice 1: an indexed owner result cannot be discarded" `Quick
    (expect_type_error "linear result of 'id_make' must be moved"
      "linear struct InfDiscard[n: usize] { idx: usize @ n; }
       fn id_make(idx: usize @ n) -> InfDiscard[n] {
         let mut x: InfDiscard[n] = { idx }; return x;
       }
       fn id_bad() { id_make(0); }");

  Alcotest.test_case "Slice 1: singleton identity cannot be invalidated through a pointer" `Quick
    (expect_type_error "cannot take the address of singleton value 'idx'"
      "fn sip_write(p: *usize) { *p = 3; }
       fn sip_bad(idx: {0..<4 as usize} @ n) { sip_write(&idx); }");

  Alcotest.test_case "Slice 1: ordinary struct storage cannot retain singleton facts" `Quick
    (expect_type_error "ordinary struct field 'InfSingletonStorage.idx' cannot hold a singleton"
      "struct InfSingletonStorage { idx: usize @ 0; }");

  Alcotest.test_case "Slice 1: arrays cannot contain singleton values" `Quick
    (expect_type_error "singleton value cannot live behind a pointer or inside array/slice storage"
      "fn isa_bad() { let mut xs: [usize @ 0; 2]; }");

  Alcotest.test_case "Slice 1: immutable indexed owner fields cannot be assigned" `Quick
    (expect_type_error "cannot assign a field of immutable indexed owner 'x'"
      "linear struct InfImmutableField[n: usize] { idx: usize @ n; value: i32; }
       fn iif_make(idx: usize @ n) -> InfImmutableField[n] {
         let mut x: InfImmutableField[n] = { idx, 0 }; return x;
       }
       fn iif_drop(x: sink InfImmutableField[n]) {}
       fn iif_bad() {
         let x = iif_make(0); x.value = 1; iif_drop(x);
       }");

  Alcotest.test_case "Slice 1: indexed owners cannot be placed behind pointers" `Quick
    (expect_type_error "indexed owner cannot live behind a pointer"
      "linear struct InfPtr[n: usize] { idx: usize @ n; }
       fn ip_bad(x: *InfPtr[0]) {}");

  Alcotest.test_case "Slice 1: casts cannot mint indexed owners" `Quick
    (expect_type_error "cannot construct indexed owner 'InfCast' with a cast"
      "linear struct InfCast[n: usize] { idx: usize @ n; }
       fn ic_bad(x: usize) -> InfCast[0] { return x as InfCast[0]; }");

  Alcotest.test_case "Slice 1: a private indexed owner cannot be forged cross-file" `Quick
    (fun () ->
      match infer_files [
        ("owner.tkb",
         "private linear struct InfPrivate[n: usize] {
            private idx: {0..<4 as usize} @ n;
          }");
        ("attacker.tkb",
         "fn priv_forge(idx: {0..<4 as usize} @ n) -> InfPrivate[n] {
            let mut x: InfPrivate[n] = { idx }; return x;
          }")
      ] with
      | _ -> Alcotest.fail "expected cross-file private constructor rejection"
      | exception Types.TypeError (_, msg) ->
          Alcotest.(check bool) "private constructor diagnostic" true
            (contains_substring msg "cannot construct struct 'InfPrivate'"));


  (* -- Success cases ----------------------------------------------- *)

  Alcotest.test_case "fully annotated function passes" `Quick
    (expect_ok "fn add(a: i32, b: i32) i32 { return a; }");

  Alcotest.test_case "infer local let from literal" `Quick (fun () ->
    let pt = infer "fn f() i32 { let x = 1; return x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "x inferred as i32" Ast.TypeI32
      (Types.StringMap.find "x" fi.Types.local_types)
  );

  Alcotest.test_case "u8 annotation on global let" `Quick (fun () ->
    let pt = infer "let g: u8 = 0;" in
    Alcotest.check type_t "g is u8" Ast.TypeU8
      (Types.StringMap.find "g" pt.Types.globals)
  );

  Alcotest.test_case "annotated return type preserved" `Quick (fun () ->
    let pt = infer "fn f() i32 { return 1; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is i32" Ast.TypeI32 fi.Types.ret_type
  );

  Alcotest.test_case "infer param type used in arithmetic" `Quick (fun () ->
    let pt = infer "fn f(a: i32, b: i32) i32 { return a + b; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "a: i32" Ast.TypeI32
      (List.assoc "a" fi.Types.param_types);
    Alcotest.check type_t "b: i32" Ast.TypeI32
      (List.assoc "b" fi.Types.param_types)
  );

  Alcotest.test_case "cross-function call type-checks" `Quick
    (expect_ok "fn id(x: i32) i32 { return x; }
                fn caller() i32 { return id(5); }");

  Alcotest.test_case "global let used inside function" `Quick
    (expect_ok "let g = 1; fn f() i32 { return g; }");

  Alcotest.test_case "let mut in while loop" `Quick
    (expect_ok "fn f() i32 { let mut r = 0;
                              while (r != 0) { r = 1; }
                              return r; }");

  Alcotest.test_case "logical OR of two comparisons" `Quick
    (expect_ok "fn f(x: i32) -> bool { return x == 1 || x == 2; }");

  Alcotest.test_case "logical OR type error: u8 operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(a: i32, b: u8) -> bool { return a == 1 || b; }");

  Alcotest.test_case "logical AND of two comparisons" `Quick
    (expect_ok "fn f(x: i32) -> bool { return x >= 0 && x < 8; }");

  Alcotest.test_case "logical AND in if condition" `Quick
    (expect_ok "fn f(v: i32) i32 { if (v >= 0 && v < 8) { return v; } return 0; }");

  Alcotest.test_case "logical AND type error: u8 operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(a: i32, b: u8) -> bool { return a == 1 && b; }");

  (* -- Bool-only conditions: no C-style int-truthy coercion ------------- *)
  (* while (1)/if (1) used to silently "type-check" (a bare integer
     literal's inferred type is an unconstrained type variable that
     unifies STRUCTURALLY with TBool) and then crash at codegen instead --
     see check_cond's own comment. Fixed by rejecting an unresolved
     condition type outright rather than unifying it away. *)

  Alcotest.test_case "while (1) is a type error, not a silent i32 coercion" `Quick
    (expect_type_error "condition must be bool"
       "fn f() { while (1) { } }");

  Alcotest.test_case "condition TypeError location points at condition expression" `Quick
    (expect_type_error_at 2 18 "condition must be bool"
       "fn f() {
          while (1) { }
        }");

  Alcotest.test_case "if (1) is a type error" `Quick
    (expect_type_error "condition must be bool"
       "fn f() { if (1) { } }");

  Alcotest.test_case "while (true) still works" `Quick
    (expect_ok "fn f() { while (true) { break; } }");

  (* GitHub issue #313 (fixed 2026-08-16): while's own condition now
     narrows the loop body the same way if's own condition already does,
     as long as the narrowed binding is never reassigned anywhere in the
     body (the narrower first version this issue's own text scoped to --
     reuses narrow_from_cond's existing kill-set soundness check verbatim,
     no new analysis needed). Previously (found migrating kernel/kernel/
     fd_table.tkb off array-decay-avoidance indexing, 2026-08-15) the body
     was processed with the same tyenv the loop was entered with, even
     though this exact two-sided condition would have narrowed an `if`. *)
  Alcotest.test_case
    "while's own condition narrows the loop body when the narrowed \
     binding is never reassigned there (issue #313)" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) { \
         while (v >= 0 && v < 4) { \
           foo(v); \
           return; \
         } \
       }");

  (* Negative control: `v` IS reassigned inside the body before its
     narrowed use, so narrow_from_cond's kill set correctly excludes it --
     stays unrefined/rejected, matching this issue's own acceptance
     criteria for the case deliberately left unsound otherwise. *)
  Alcotest.test_case
    "while's own condition does NOT narrow a binding reassigned inside \
     the loop body before its narrowed use (issue #313 negative control)"
    `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) { \
         while (v >= 0 && v < 4) { \
           v = v + 1; \
           foo(v); \
           return; \
         } \
       }");

  Alcotest.test_case "if condition: a concretely-typed i32 variable is still rejected" `Quick
    (expect_type_error "cannot unify"
       "fn f(x: i32) { if (x) { } }");

  (* -- check_literal_fits_refined's TBool arm: the same unbound-type
     -variable hole, but for any literal-flows-into-a-known-type site, not
     just if/while conditions (Let, Return, Call arguments, ...). *)

  Alcotest.test_case "let x: bool = 1 is a type error, not a silent coercion" `Quick
    (expect_type_error "cannot use integer literal"
       "fn f() { let x: bool = 1; }");

  Alcotest.test_case "let x: bool = true still works" `Quick
    (expect_ok "fn f() { let x: bool = true; }");

  Alcotest.test_case "return 1 from a -> bool function is a type error" `Quick
    (expect_type_error "cannot use integer literal"
       "fn f() -> bool { return 1; }");

  Alcotest.test_case "passing an integer literal for a bool parameter is a type error" `Quick
    (expect_type_error "cannot use integer literal"
       "fn f(b: bool) { } fn g() { f(1); }");

  Alcotest.test_case "passing a genuine bool expression for a bool parameter still works" `Quick
    (expect_ok "fn f(b: bool) { } fn g(x: i32) { f(x == 0); }");

  Alcotest.test_case "if/else branches both valid" `Quick
    (expect_ok "fn abs(x: i32) i32 {
                  if (x > 0) { return x; } else { return 0; } }");

  (* -- Immutability checks ------------------------------------------- *)

  Alcotest.test_case "assign to immutable variable is a type error" `Quick
    (expect_type_error "cannot assign to immutable"
       "fn f() { let x = 0; x = 1; }");

  Alcotest.test_case "let mut allows reassignment" `Quick
    (expect_ok "fn f() { let mut x: i32 = 0; x = 1; }");

  Alcotest.test_case "addrof immutable variable is a type error" `Quick
    (expect_type_error "cannot take address of immutable"
       "fn f() { let x = 0; let p = &x; }");

  Alcotest.test_case "addrof mutable variable succeeds" `Quick
    (expect_ok "fn f() { let mut x: i32 = 0; let p = &x; }");

  Alcotest.test_case "immutable let without initializer is a type error" `Quick
    (expect_type_error "must have an initializer"
       "fn f() { let x: i32; }");

  (* -- Undetermined integer types require an explicit annotation ------
     (this language does not silently default to i32 the way a for-loop
     bound's residual "nothing else determines it" case still does -- a
     `let`/`let mut` binding is a stable, potentially debugger-visible
     memory location whose bit width the programmer should always have
     chosen deliberately, unlike a purely ephemeral loop counter). *)

  Alcotest.test_case
    "a bare, never-otherwise-constrained local let is a type error \
     (regression: this used to silently default to i32 via Types.to_ast's \
     TVar-Unbound fallback)" `Quick
    (expect_type_error "cannot determine a concrete type"
       "fn f() { let x = 5; }");

  Alcotest.test_case
    "a bare, never-otherwise-constrained global let is a type error" `Quick
    (expect_type_error "cannot determine a concrete type"
       "let g = 5;");

  Alcotest.test_case
    "a local let determined by a LATER statement (not the Let itself) is \
     NOT a false positive -- `let x = 1; return x;` is the entirely \
     ordinary case where the function's own return type (processed after \
     the Let) is what pins x's type; checking eagerly at the Let site \
     itself (first attempted) rejected this" `Quick
    (expect_ok "fn f() i32 { let x = 1; return x; }");

  Alcotest.test_case
    "a global let determined by a LATER global's reference is NOT a \
     false positive -- `let g = 5; let h: i32 = g;` pins g's type through \
     h's own annotation, processed after g's own initializer" `Quick
    (expect_ok "let g = 5; let h: i32 = g;");

  Alcotest.test_case
    "a global let determined only by a function body's usage is NOT a \
     false positive -- the check must run after Pass 3 (function \
     bodies), not just after Pass 2 (global initializers)" `Quick
    (expect_ok "let g = 1; fn f() i32 { return g; }");

  (* -- Error cases --------------------------------------------- *)

  Alcotest.test_case "undefined variable" `Quick
    (expect_type_error "Unbound variable"
       "fn f() i32 { return z; }");

  Alcotest.test_case "undefined function" `Quick
    (expect_type_error "Undefined function"
       "fn f() i32 { return noexist(1); }");

  Alcotest.test_case "too many arguments" `Quick
    (expect_type_error "expects 1 argument"
       "fn id(x: i32) i32 { return x; }
        fn f() i32 { return id(1, 2); }");

  Alcotest.test_case "too few arguments" `Quick
    (expect_type_error "expects 2 argument"
       "fn add(a: i32, b: i32) i32 { return a; }
        fn f() i32 { return add(1); }");

  Alcotest.test_case "arithmetic operand type mismatch" `Quick
    (expect_type_error "cannot unify"
       "fn f(a: i32, b: u8) i32 { return a + b; }");

  (* -- Pointer type inference ---------------------------------------- *)

  Alcotest.test_case "local pointer annotation type-checks" `Quick
    (expect_ok "fn f() { let p: *i32 = 0x09000000; *p = 1; }");

  Alcotest.test_case "deref yields element type" `Quick (fun () ->
    let pt = infer "fn f(p: *i32) i32 { return *p; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is i32" Ast.TypeI32 fi.Types.ret_type
  );

  Alcotest.test_case "addrof yields pointer type" `Quick (fun () ->
    let pt = infer "fn f() { let mut x: i32 = 0; let p = &x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "p has type *i32"
      (Ast.TypePtr Ast.TypeI32)
      (Types.StringMap.find "p" fi.Types.local_types)
  );

  (* -- Type inference for io-qualified types -------------------------------------------- *)

  Alcotest.test_case "deref *io i32 param yields i32" `Quick (fun () ->
    let pt = infer "fn f(p: *io i32) i32 { return *p; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is i32" Ast.TypeI32 fi.Types.ret_type
  );

  Alcotest.test_case "addrof io i32 global yields *io i32" `Quick (fun () ->
    let pt = infer "let mut flag: io i32;\nfn f() { let p: *io i32 = &flag; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "p has type *io i32"
      (Ast.TypePtr (Ast.TypeIo Ast.TypeI32))
      (Types.StringMap.find "p" fi.Types.local_types)
  );

  Alcotest.test_case "assign i32 to io i32 global type-checks" `Quick
    (expect_ok "let mut flag: io i32;\nfn f() { flag = 1; }");

  Alcotest.test_case "io i32 global in comparison type-checks" `Quick
    (expect_ok "let mut flag: io i32;\nfn f() i32 { if (flag == 0) { return 1; } return 0; }");

  Alcotest.test_case "io i32 struct field type-checks" `Quick
    (expect_ok "struct S { done: io i32; }\nlet mut s: S;\nfn f() { s.done = 1; }");

  Alcotest.test_case "deref non-pointer is a type error" `Quick
    (expect_type_error "cannot unify"
       "fn f(x: i32) { *x = 1; }");

  Alcotest.test_case "write through immutable pointer variable is allowed" `Quick
    (expect_ok "fn f() { let p: *i32 = 0x09000000; *p = 1; }");

  (* -- Unary minus --------------------------------------------- *)

  Alcotest.test_case "unary minus type-checks" `Quick
    (expect_ok "fn f(n: i32) i32 { return -n; }");

  (* -- as cast ----------------------------------------------- *)

  Alcotest.test_case "as cast i32 to u8 passes" `Quick
    (expect_ok "fn f(n: i32) u8 { return n as u8; }");

  Alcotest.test_case "as cast u8 to i32 passes" `Quick
    (expect_ok "fn f(c: u8) i32 { return c as i32; }");

  Alcotest.test_case "as cast result type is the target type" `Quick (fun () ->
    let pt = infer "fn f(n: i32) u8 { return n as u8; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is u8" Ast.TypeU8 fi.Types.ret_type
  );

  Alcotest.test_case "as cast pointer to i32 is a type error" `Quick
    (expect_type_error "cannot cast pointer"
       "fn f(p: *i32) i32 { return p as i32; }");

  Alcotest.test_case "as cast pointer to pointer passes" `Quick
    (expect_ok "fn f(p: *u8) i32 { let q: *i32 = p as *i32; return 0; }");

  (* -- Bitwise operations ------------------------------------------------ *)

  Alcotest.test_case "bitwise AND type-checks" `Quick
    (expect_ok "fn f(n: i32) i32 { return n & 15; }");

  Alcotest.test_case "right shift type-checks" `Quick
    (expect_ok "fn f(n: i32) i32 { return n >> 4; }");

  Alcotest.test_case "bitwise AND type error: non-i32 operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(n: i32, p: *i32) i32 { return n & p; }");

  Alcotest.test_case "bitwise XOR type-checks" `Quick
    (expect_ok "fn f(a: i32, b: i32) i32 { return a ^ b; }");

  Alcotest.test_case "bitwise XOR type error: non-i32 operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(n: i32, p: *i32) i32 { return n ^ p; }");

  (* -- Arrays ------------------------------------------------------ *)

  Alcotest.test_case "array declaration type-checks" `Quick
    (expect_ok "fn f() { let mut buf: [u8; 8]; }");

  Alcotest.test_case "array write via pointer arith type-checks" `Quick
    (expect_ok "fn f() { let mut buf: [u8; 8]; *(buf + 0) = 'A'; }");

  Alcotest.test_case "pointer minus isize returns a pointer" `Quick
    (expect_ok "fn f(p: *u8, offset: isize) *u8 { return p - offset; }");

  Alcotest.test_case "pointer plus i32 variable is rejected" `Quick
    (expect_type_error "cannot unify i32 with isize"
       "fn f(p: *u8, offset: i32) *u8 { return p + offset; }");

  Alcotest.test_case "pointer minus i32 variable is rejected" `Quick
    (expect_type_error "cannot unify i32 with isize"
       "fn f(p: *u8, offset: i32) *u8 { return p - offset; }");

  Alcotest.test_case "pointer difference has type isize" `Quick (fun () ->
    let pt = infer "fn distance(a: *u32, b: *u32) isize { return b - a; }" in
    let fi = Types.StringMap.find "distance" pt.Types.functions in
    Alcotest.check type_t "return type is isize" Ast.TypeIsize fi.Types.ret_type
  );

  Alcotest.test_case "pointer difference requires matching pointee types" `Quick
    (expect_type_error "cannot unify"
       "fn distance(a: *u8, b: *u32) isize { return b - a; }");

  Alcotest.test_case "array read via indexing type-checks" `Quick
    (expect_ok "fn putc(c: u8) {} fn f() { let mut buf: [u8; 4]; putc(buf[0]); }");

  Alcotest.test_case "array decays to *u8 when passed to pointer param" `Quick
    (expect_ok "fn fill(p: *u8, n: i32) {}
                fn f() { let mut buf: [u8; 4]; fill(buf, 4); }");

  Alcotest.test_case "array write arr[i]=v type-checks" `Quick
    (expect_ok "fn f(arr: *u8) { arr[0] = 'A'; }");

  Alcotest.test_case "array write to non-pointer is a type error" `Quick
    (expect_type_error "non-array/pointer"
       "fn f(n: i32) { n[0] = 1; }");

  Alcotest.test_case "array write with deref index buf[*ptr]=val type-checks" `Quick
    (expect_ok "fn f(buf: *i32, tail: *isize) { buf[*tail] = 42; }");

  Alcotest.test_case "addrof mut var as function argument type-checks" `Quick
    (expect_ok "fn push(tail: *i32) {}
                fn f() { let mut t: i32 = 0; push(&t); }");

  (* -- Function pointer types -------------------------------------------- *)

  Alcotest.test_case "fn pointer param can be called indirectly" `Quick
    (expect_ok "fn foo() {}
                fn f(h: fn() -> void) { h(); }");

  Alcotest.test_case "fn pointer let binding and indirect call type-checks" `Quick
    (expect_ok "fn foo() {}
                fn f() { let h: fn() -> void = foo; h(); }");

  Alcotest.test_case "fn pointer stored in global array type-checks" `Quick
    (expect_ok "let mut handlers: [fn() -> void; 4];
                fn f(h: fn() -> void) { handlers[0] = h; }");

  Alcotest.test_case "fn pointer argument count mismatch is a type error" `Quick
    (expect_type_error "argument count mismatch"
       "fn foo(x: i32) {}
        fn f(h: fn() -> void) { h = foo; }");

  (* -- Structs ------------------------------------------------------ *)

  Alcotest.test_case "struct field access type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn sum(p: *Point) -> i32 { return p.x + p.y; }");

  Alcotest.test_case "struct field write type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn f() { let mut p: Point; p.x = 3; p.y = 4; }");

  Alcotest.test_case "indexed struct field write type-checks" `Quick
    (expect_ok "struct IndexedPoint { x: i32; y: i32; }
                let mut indexed_points: [IndexedPoint; 4];
                fn indexed_write(i: {0..<4 as usize}) {
                  indexed_points[i].x = 3;
                  indexed_points[i].y += 4;
                }");

  Alcotest.test_case "pointer-indexed struct field write type-checks" `Quick
    (expect_ok "struct PointerPoint { x: i32; }
                fn pointer_indexed_write(p: *PointerPoint, i: isize) {
                  p[i].x = 3;
                }");

  Alcotest.test_case "struct passed by pointer type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn sum(p: *Point) -> i32 { return p.x + p.y; }
                fn f() { let mut s: Point; s.x = 1; s.y = 2; sum(&s); }");

  Alcotest.test_case "global struct variable type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                let mut g: Point;
                fn f() { g.x = 10; g.y = 20; }");

  Alcotest.test_case "struct field u8 type type-checks" `Quick
    (expect_ok "struct Pair { a: i32; b: u8; }
                fn f() { let mut p: Pair; p.a = 1; p.b = 'X'; }");

  Alcotest.test_case "unknown field name is a type error" `Quick
    (expect_type_error "no field"
       "struct Point { x: i32; y: i32; }
        fn f(p: *Point) -> i32 { return p.z; }");

  Alcotest.test_case "field access on non-struct is a type error" `Quick
    (expect_type_error "non-struct"
       "fn f(n: i32) -> i32 { return n.x; }");

  Alcotest.test_case "struct type mismatch: passing *B where *A expected" `Quick
    (expect_type_error "struct type mismatch"
       "struct A { x: i32; }
        struct B { x: i32; }
        fn use_a(a: *A) {}
        fn f(b: *B) { use_a(b); }");

  Alcotest.test_case "opaque struct is usable through pointers" `Quick
    (expect_ok "opaque struct Token;
                let mut storage: u8;
                fn get() -> *Token { return &storage as *Token; }
                fn consume(t: *Token) {}");

  Alcotest.test_case "opaque struct cannot be used by value" `Quick
    (expect_type_error "incomplete"
       "opaque struct Token; fn consume(t: Token) {}");

  Alcotest.test_case "distinct opaque handle states do not unify" `Quick
    (expect_type_error "struct type mismatch"
       "opaque struct DmaOwned; opaque struct CpuOwned;
        fn release(t: *CpuOwned) {}
        fn bad(t: *DmaOwned) { release(t); }");

  Alcotest.test_case "affine handle may be borrowed repeatedly then consumed" `Quick
    (expect_ok "affine opaque struct Token;
                let mut byte: u8;
                fn make() -> *Token { return &byte as *Token; }
                fn inspect(t: borrow *Token) {}
                fn release(t: sink *Token) {}
                fn good() { let t: *Token = make(); inspect(t); inspect(t); release(t); }");

  Alcotest.test_case "affine handle cannot be consumed twice" `Quick
    (expect_type_error "affine value 't' was already consumed"
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn release(t: sink *Token) {}
        fn bad() { let t: *Token = make(); release(t); release(t); }");

  Alcotest.test_case "affine handle cannot be used after consumption" `Quick
    (expect_type_error "affine value 't' was already consumed"
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn inspect(t: borrow *Token) {}
        fn release(t: sink *Token) {}
        fn bad() { let t: *Token = make(); release(t); inspect(t); }");

  (* Slice 3 adopts the standard affine meaning: weakening is legal, while
     using the same resource twice remains illegal. Mandatory release is
     expressed with `linear`, not by strengthening every affine value. *)
  Alcotest.test_case "affine local may be dropped without consumption" `Quick
    (expect_ok
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn bad() { let t: *Token = make(); }");

  Alcotest.test_case "a consumed affine binding may be reinitialized" `Quick
    (expect_ok
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn release(t: sink *Token) {}
        fn good() {
          let mut t: *Token = make();
          release(t);
          t = make();
          release(t);
        }");

  Alcotest.test_case "affine local returned directly counts as consumed" `Quick
    (expect_ok "affine opaque struct Token;
                let mut byte: u8;
                fn make() -> *Token { return &byte as *Token; }
                fn forward() -> *Token { let t: *Token = make(); return t; }");

  Alcotest.test_case "an affine handle cannot be cast to an integer for a null check" `Quick
    (expect_type_error "cannot cast an affine/linear value"
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn bad() {
          let t: *Token = make();
          let raw: usize = t as usize;
        }");

  (* examples/common/sync.tkb's cond_wait-style pattern: a loop reassigns
     a `let mut` affine local to a fresh value on every iteration
     (dropping the mutex and reacquiring it), then the local is consumed
     once after the loop. Exercises the never-consumed check together
     with the pre-existing "declared outside a loop, consumed inside"
     restriction, which reassignment resets around (see that restriction's
     own tests below). *)
  Alcotest.test_case "affine local reassigned across loop iterations then consumed is allowed" `Quick
    (expect_ok "affine opaque struct Token;
                let mut byte: u8;
                fn make() -> *Token { return &byte as *Token; }
                fn reacquire(t: sink *Token) -> *Token { return make(); }
                fn release(t: sink *Token) {}
                fn good(cond: bool) {
                    let mut g: *Token = make();
                    while (cond) {
                        g = reacquire(g);
                    }
                    release(g);
                }");

  (* GitHub issue #89 comment thread's "return-terminated branch" gap:
     an `if` branch that always `return`s never reaches the code after
     the `if`, so whatever it consumed must not be unioned into what
     continues -- otherwise this exact shape (examples/common/fat12.tkb's
     create_demo_file, before this fix) falsely reports "already
     consumed" even though the two `release(t)` calls are on mutually
     exclusive paths. *)
  Alcotest.test_case "consuming in a branch that always returns does not leak into the continuation" `Quick
    (expect_ok "affine opaque struct Token;
                let mut byte: u8;
                fn make() -> *Token { return &byte as *Token; }
                fn release(t: sink *Token) -> i32 { return 0; }
                fn f(cond: bool) -> i32 {
                    let t: *Token = make();
                    if (cond) {
                        release(t);
                        return -1;
                    }
                    return release(t);
                }");

  Alcotest.test_case "both branches always returning is still accepted (nothing continues)" `Quick
    (expect_ok "affine opaque struct Token;
                let mut byte: u8;
                fn make() -> *Token { return &byte as *Token; }
                fn release(t: sink *Token) -> i32 { return 0; }
                fn f(cond: bool) -> i32 {
                    let t: *Token = make();
                    if (cond) {
                        return release(t);
                    } else {
                        return release(t);
                    }
                }");

  Alcotest.test_case "a non-terminating branch still shares consumption with what follows" `Quick
    (expect_type_error "affine value 't' was already consumed"
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn release(t: sink *Token) {}
        fn f(cond: bool) {
            let t: *Token = make();
            if (cond) {
                release(t);
            }
            release(t);
        }");

  Alcotest.test_case "affine parameter may be dropped by the callee" `Quick
    (expect_ok
       "affine opaque struct Token;
        let mut byte: u8;
        fn make() -> *Token { return &byte as *Token; }
        fn drop_silently(t: *Token) {}
        fn caller() { let x: *Token = make(); drop_silently(x); }");

  Alcotest.test_case "sink parameter is not required to be forwarded further" `Quick
    (expect_ok "affine opaque struct Token;
                let mut byte: u8;
                fn make() -> *Token { return &byte as *Token; }
                fn release(t: sink *Token) {}
                fn caller() { let x: *Token = make(); release(x); }");

  Alcotest.test_case "sink is rejected on a type that is not an affine opaque pointer" `Quick
    (expect_type_error "sink is only valid"
       "fn bad(x: sink *u8) {}");

  (* GitHub issue #15 follow-up: casting a non-literal integer to an
     AFFINE OPAQUE pointer type requires `unsafe` -- scoped narrowly to
     affine targets after a broader "any pointer" version was measured
     against the whole example suite and found to falsely flag legitimate
     runtime-computed MMIO addresses (see lib/type_inf.ml's Cast case
     comment and HISTORY.md's issue #15 entry). *)
  Alcotest.test_case "casting a non-literal integer to an affine handle requires unsafe" `Quick
    (expect_type_error "casting a non-literal integer to an affine/linear handle"
       "affine opaque struct Token;
        fn f(idx: usize) { let t: *Token = idx as *Token; }");

  Alcotest.test_case "unsafe marks a computed cast to an affine handle" `Quick
    (expect_ok "affine opaque struct Token;
                fn release(t: sink *Token) {}
                fn f(idx: usize) !{unsafe} {
                    let t: *Token = unsafe { idx as *Token };
                    release(t);
                }");

  Alcotest.test_case "a literal cast to an affine handle needs no unsafe" `Quick
    (expect_ok "affine opaque struct Token;
                fn release(t: sink *Token) {}
                fn f() {
                    let t: *Token = 0 as usize as *Token;
                    release(t);
                }");

  Alcotest.test_case "an address-of cast to an affine handle needs no unsafe" `Quick
    (expect_ok "affine opaque struct Token;
                let mut storage: u8;
                fn release(t: sink *Token) {}
                fn f() {
                    let t: *Token = &storage as *Token;
                    release(t);
                }");

  Alcotest.test_case "casting a non-literal integer to a non-affine, non-io pointer warns" `Quick
    (expect_nonliteral_ptr_cast_warnings 1
       "fn f(base: usize, offset: usize) { let p: *u32 = (base + offset) as *u32; }");

  Alcotest.test_case "unsafe marks a calculated ordinary-pointer cast as audited (issue #218)" `Quick
    (expect_nonliteral_ptr_cast_warnings 0
       "fn f(base: usize, offset: usize) !{unsafe} {
          let p: *u32 = unsafe { (base + offset) as *u32 };
        }");

  Alcotest.test_case "an audited calculated ordinary-pointer cast is not unnecessary unsafe (issue #218)" `Quick
    (expect_unnecessary_unsafe 0
       "fn f(base: usize, offset: usize) !{unsafe} {
          let p: *u32 = unsafe { (base + offset) as *u32 };
        }");

  (* GitHub issue #316's decision: *io construction gets NO literal
     exemption, unlike the affine/linear case above -- a hardcoded MMIO
     address is exactly as unprovable to the compiler as a runtime-
     discovered one (see check_io_ptr_cast_needs_unsafe's comment in
     lib/type_inf.ml). This reverses the earlier "io stays fully exempt"
     behavior the two tests just above this block used to assert. *)
  Alcotest.test_case "casting a non-literal integer to *io requires unsafe (issue #316)" `Quick
    (expect_type_error "asserts it denotes a real, correctly-sized hardware register"
       "fn f(base: usize, offset: usize) { let p: *io u32 = (base + offset) as *io u32; }");

  Alcotest.test_case "unsafe marks a non-literal cast to *io (issue #316)" `Quick
    (expect_ok "fn f(base: usize, offset: usize) !{unsafe} {
                    let p: *io u32 = unsafe { (base + offset) as *io u32 };
                }");

  Alcotest.test_case "a LITERAL cast to *io also requires unsafe (issue #316, no literal exemption)" `Quick
    (expect_type_error "asserts it denotes a real, correctly-sized hardware register"
       "fn f() { let p: *io u32 = 0x107FFF9000 as *io u32; }");

  Alcotest.test_case "unsafe marks a literal cast to *io (issue #316)" `Quick
    (expect_ok "fn f() !{unsafe} { let p: *io u32 = unsafe { 0x107FFF9000 as *io u32 }; }");

  (* SPEC.md's "MMIO / Volatile" sugar ("An integer literal can be assigned
     directly to an MMIO pointer type") bypasses the Cast AST node entirely
     -- IntLit's inferred type is a fresh unification variable that unifies
     with *io T directly at the Let site, so it needs its own check
     (check_io_ptr_literal_needs_unsafe), not just the `as` cast check
     tested above. *)
  Alcotest.test_case "a bare integer literal assigned directly to *io requires unsafe (issue #316)" `Quick
    (expect_type_error "asserts it denotes a real, correctly-sized hardware register"
       "fn f() { let dr: *io u8 = 0x09000000; }");

  Alcotest.test_case "unsafe { stmt* } marks the direct-literal *io sugar too (issue #316)" `Quick
    (expect_ok "fn f() !{unsafe} { unsafe { let dr: *io u8 = 0x09000000; } }");

  (* Regression coverage for two real "unnecessary unsafe" false positives
     found and fixed the same session (both genuinely required `unsafe`,
     both got flagged as not needing it): a bare-literal *io construction
     via coerce's implicit inttoptr path (found in kernel/platform/qemu/
     uart.tkb), and a cast reinterpreting an ALREADY-pointer-typed source
     as *io Struct (found in kernel/drivers/net/virtio_net.tkb's
     used_idx_get) -- the latter never reached coerce's inttoptr branch at
     all, since LLVM's opaque `ptr` type makes source and destination
     identical at coerce's own entry short-circuit for a pointer-to-
     pointer reinterpretation, which is why gen_expr's Cast case now calls
     note_unsafe_use() directly instead of relying on coerce alone. *)
  (* GitHub issue #326 (fixed): this test used to be named
     `io_literal_sugar_probe` instead of the file's usual placeholder `f`,
     because a bare `fn f()` here -- immediately ahead of a LATER
     `fn f(param) -> T` test elsewhere in this file -- corrupted that
     unrelated later test with a stale, wrong-arity `func_param_ast_types`
     entry (Invalid_argument "List.iter2" in gen_func). Root cause was
     gen_program reusing the same Llvm_gen.the_module (and its
     `functions` "already declared" guard) across every gen_codegen call
     in this process; gen_program now disposes and recreates the module
     per call, so `fn f()`/`fn f(x)`/etc. across unrelated tests no longer
     interact. Renamed back to the placeholder name as living regression
     coverage: keep this named `f`. *)
  Alcotest.test_case "the direct-literal *io sugar records zero unnecessary-unsafe sites (issue #316 lint fix)" `Quick
    (expect_unnecessary_unsafe 0
       "fn f() !{unsafe} { unsafe { let dr: *io u8 = 0x09000000; } }");

  Alcotest.test_case "a cast reinterpreting an existing pointer as *io Struct records zero unnecessary-unsafe sites" `Quick
    (expect_unnecessary_unsafe 0
       "struct packed Used { idx: u16; }
        fn used_idx_get(queue_mem: *u8) -> u16 !{unsafe} {
            let used: *io Used = unsafe { (queue_mem + 4096) as *io Used };
            return used.idx;
        }");

  (* GitHub issue #328: check_kinded_ptr_cast_needs_unsafe (affine/linear
     opaque handle casts) is a PURE type-checker-level gate with no
     codegen footprint of its own -- before #328, a site whose ONLY
     justification was this category was wrongly flagged unnecessary here,
     the documented gap SPEC.md's "Unnecessary-unsafe warning" section
     used to call out explicitly ("No kernel/ site uses that category
     inside unsafe as of this writing"). A computed (non-literal-derived)
     integer cast to an affine handle is exactly that category: nothing in
     llvm_gen.ml's own codegen elides a runtime check for it (a plain
     inttoptr), so llvm_gen.ml's OWN marker never moves here -- this only
     stays at 0 because type_inf.ml's new type_checker_consumed_unsafe_at
     is OR'd in (see llvm_gen.ml's Unsafe-expr case). *)
  Alcotest.test_case
    "a computed cast to an affine opaque handle records zero \
     unnecessary-unsafe sites (issue #328 gap fix)"
    `Quick
    (expect_unnecessary_unsafe 0
       "affine opaque struct Token;
        fn make_from_index(idx: usize) -> *Token !{unsafe} {
          return unsafe { idx as *Token };
        }");

  (* Negative control: an affine handle cast built from a LITERAL is
     already exempt from needing unsafe at all (check_kinded_ptr_cast_
     needs_unsafe's own literal exemption, GitHub issue #15) -- so
     type_inf.ml's note_type_checker_unsafe_use() never fires for it, and
     wrapping it in `unsafe { }` anyway must still be reported as
     unnecessary. This is the "genuinely superfluous unsafe stays flagged"
     counterpart to the positive control just above -- proves issue #328's
     fix does not just silence the warning wholesale. *)
  Alcotest.test_case
    "a literal-derived cast to an affine opaque handle wrapped in \
     unsafe still records one unnecessary-unsafe site"
    `Quick
    (expect_unnecessary_unsafe 1
       "affine opaque struct Token;
        fn make_from_literal() -> *Token !{unsafe} {
          return unsafe { 0 as usize as *Token };
        }");

  Alcotest.test_case "a non-literal cast to *io inside unsafe records zero #218 warnings" `Quick
    (expect_nonliteral_ptr_cast_warnings 0
       "fn f(base: usize, offset: usize) !{unsafe} {
            let p: *io u32 = unsafe { (base + offset) as *io u32 };
        }");

  Alcotest.test_case "a literal cast to an ordinary pointer records no #218 warning" `Quick
    (expect_nonliteral_ptr_cast_warnings 0
       "fn f() { let p: *u32 = 0 as usize as *u32; }");

  (* -- GitHub issue #218 follow-up: checked slice-to-struct-pointer casts - *)

  Alcotest.test_case "slice-to-struct cast with a provably-sufficient minimum length needs no unsafe" `Quick
    (expect_ok
       "struct packed P4 { a: u32; }
        fn f(s: [u8; 4..]) -> u32 { let p: *P4 = s as *P4; return p.a; }");

  Alcotest.test_case "slice-to-struct cast with a provably-INSUFFICIENT minimum length is rejected" `Quick
    (expect_type_error "proven minimum length 2 is smaller than sizeof(P4) = 4 bytes"
       "struct packed P4 { a: u32; }
        fn f(s: [u8; 2..]) -> u32 { let p: *P4 = s as *P4; return p.a; }");

  Alcotest.test_case "slice-to-struct cast from a dynamic-length ([]T) slice is rejected" `Quick
    (expect_type_error "this slice's length is not compile-time-provable"
       "struct packed P4 { a: u32; }
        fn f(s: []u8) -> u32 { let p: *P4 = s as *P4; return p.a; }");

  Alcotest.test_case "slice-to-struct cast whose target size is not target-independent-provable is rejected" `Quick
    (expect_type_error "sizeof(HasUsize) is not provable at compile time here"
       "struct packed HasUsize { a: usize; }
        fn f(s: [u8; 64..]) -> usize { let p: *HasUsize = s as *HasUsize; return p.a; }");

  Alcotest.test_case "unsafe marks an otherwise-unprovable slice-to-struct cast" `Quick
    (expect_ok
       "struct packed P4 { a: u32; }
        fn f(s: []u8) -> u32 !{unsafe} {
          let p: *P4 = unsafe { s as *P4 };
          return p.a;
        }");

  Alcotest.test_case "slice-to-*u8 stays free regardless of provable length (byte pointer's own size is 1)" `Quick
    (expect_ok "fn f(s: []u8) -> *u8 { return s as *u8; }");

  (* Regression test for a `make allcheck` failure found by the user
     right after this feature landed: kernel/lib/freelist.tkb's generic
     freelist_ref instantiated for `usize` compiled `[usize; 3..] as
     *usize` -- a slice cast to its OWN element type, which is not a
     reinterpretation and needs no sizeof proof, but the original
     implementation only special-cased *u8, not "target equals the
     slice's own element type" in general. usize is target-dependent
     (const_type_size cannot compute it), so the missing exemption
     turned into a hard, unconditional compile failure rather than a
     merely-unnecessary unsafe requirement. *)
  Alcotest.test_case "slice-to-its-own-element-type stays free even when that type's size is not const_type_size-provable (usize)" `Quick
    (expect_ok "fn f(s: [usize; 3..]) -> *usize { return s as *usize; }");

  Alcotest.test_case "slice-to-its-own-element-type stays free even for a dynamic-length ([]T) slice" `Quick
    (expect_ok "fn f(s: []usize) -> *usize { return s as *usize; }");

  Alcotest.test_case "slice-to-its-own-element-type stays free for an ordinary (const_type_size-provable) element type too" `Quick
    (expect_ok "fn f(s: []u32) -> *u32 { return s as *u32; }");

  Alcotest.test_case "slice-to-a-DIFFERENT-type still needs proof (same-element-type exemption is not a general escape hatch)" `Quick
    (expect_type_error "casting"
       "struct packed P4 { a: u32; }
        fn f(s: []usize) -> *P4 { return s as *P4; }");

  (* Codegen-level check for the same fix, lib/llvm_gen.ml's own sync-rule
     re-derivation (not just type_inf.ml's) -- confirms the codegen path
     also recognizes the same-element-type exemption and does not
     attempt (and fail on, pre-fix) a target-dependent sizeof lookup for
     it. Needs no setup_target: this exemption skips the DataLayout
     lookup entirely, unlike the genuinely-unsafe case tested further
     below in the post-setup_target group. *)
  Alcotest.test_case "slice-to-its-own-element-type (usize) codegens without needing a real target machine" `Quick
    (expect_codegen_ok "fn f(s: [usize; 3..]) -> *usize { return s as *usize; }");

  (* -- GitHub issue #239: reject pointer-to-pointer types such as **T --- *)

  Alcotest.test_case "a direct **T let annotation is rejected" `Quick
    (expect_type_error "nested pointer indirection"
       "fn f() { let pp: **u8 = 0 as usize as **u8; }");

  Alcotest.test_case "**T as a function parameter is rejected" `Quick
    (expect_type_error "nested pointer indirection"
       "fn f(pp: **u8) {}");

  Alcotest.test_case "**T as a function return type is rejected" `Quick
    (expect_type_error "nested pointer indirection"
       "fn f() -> **u8 { return 0 as usize as **u8; }");

  Alcotest.test_case "*align(N) *T is rejected" `Quick
    (expect_type_error "nested pointer indirection"
       "fn f(p: *align(8) *u8) {}");

  Alcotest.test_case "*io *T is rejected" `Quick
    (expect_type_error "nested pointer indirection"
       "fn f(p: *io *u8) {}");

  Alcotest.test_case "*T where T is a struct field's pointer type is rejected" `Quick
    (expect_type_error "nested pointer indirection"
       "struct Holder { p: u8; } fn f(pp: **Holder) {}");

  Alcotest.test_case
    "taking the address of a *T local (inferred **T) is rejected without an annotation"
    `Quick
    (expect_type_error "nested pointer indirection"
       "fn f() { let mut p: *u8 = 0 as usize as *u8; let pp = &p; }");

  (* Before GitHub issue #240, this specifically exercised issue #239's
     mint-site guard on address-of a POINTER-typed field (h.p: *u8,
     &h.p: **u8). #240 now rejects Holder's own `p: *u8` field
     declaration first -- an ordinary struct can no longer hold a raw
     pointer field at all, so this exact scenario (address-of a pointer
     field) is now structurally unreachable; the sibling "address-of a
     *T local" test above still covers #239's own mint-site logic via a
     still-legal shape. *)
  Alcotest.test_case
    "taking the address of a *T struct field (inferred **T) is rejected"
    `Quick
    (expect_type_error "cannot hold pointer type"
       "struct Holder { p: *u8; }
        fn f(h: &mut Holder) { let pp = &h.p; }");

  Alcotest.test_case
    "a bare array-of-pointers variable decaying to **T is rejected"
    `Quick
    (expect_type_error "nested pointer indirection"
       "fn f() { let mut arr: [*u8; 4]; let pp = arr; }");

  Alcotest.test_case "a single-level *T annotation stays legal (positive control)" `Quick
    (expect_ok "fn f(p: *u8) {}");

  Alcotest.test_case "*align(N) T stays legal (positive control)" `Quick
    (expect_ok "fn f(p: *align(8) u8) {}");

  Alcotest.test_case "*io T stays legal (positive control)" `Quick
    (expect_ok "fn f(p: *io u8) {}");

  (* -- GitHub issue #240: reject pointer fields in structs (capability- --
     based reformulation, see that issue's comment thread: keyed off
     whether the field's pointer type still supports arithmetic/
     indexing/dereference, not off its spelling) ------------------------ *)

  Alcotest.test_case "an ordinary pointer struct field is rejected" `Quick
    (expect_type_error "cannot hold pointer type"
       "struct Holder { p: *u8; }");

  Alcotest.test_case "an *align(N) T struct field is rejected too" `Quick
    (expect_type_error "cannot hold pointer type"
       "struct Holder { p: *align(8) u8; }");

  Alcotest.test_case "an ordinary (non-opaque) struct-pointer struct field is rejected" `Quick
    (expect_type_error "cannot hold pointer type"
       "struct Inner { x: i32; }
        struct Holder { p: *Inner; }");

  Alcotest.test_case "an affine opaque handle struct field stays legal (already structurally inert)" `Quick
    (expect_ok
       "affine opaque struct Lease;
        struct Holder { t: *Lease; }");

  (* A linear (not affine) opaque handle struct field is already rejected
     for a separate, pre-existing reason unrelated to #240 -- linear
     values cannot live in struct fields at all yet, full stop
     (OWNERSHIP_KERNEL.md Stage 3 still pending), so #240's own
     capability exemption for it is moot; no test needed here since
     #240 is not what's doing the rejecting. *)

  Alcotest.test_case "an *io T struct field is rejected too (issue #316's resolution extends #240 to *io)" `Quick
    (expect_type_error "cannot hold pointer type"
       "struct Holder { p: *io u32; }");

  Alcotest.test_case "a plain (non-pointer) struct field stays legal (positive control)" `Quick
    (expect_ok "struct Holder { p: u8; }");

  (* -- GitHub issue #102: provable pointer alignment, *align(N) T ---- *)

  Alcotest.test_case "&x on an align(N) global proves *align(N) T" `Quick
    (expect_ok "let mut buf: u8 align(32);
                fn f() { let p: *align(32) u8 = &buf; }");

  Alcotest.test_case "&x on an align(N) local proves *align(N) T" `Quick
    (expect_ok "fn f() { let mut x: u8 align(16); let p: *align(16) u8 = &x; }");

  Alcotest.test_case "an align(N) array's own name decays to *align(N) T" `Quick
    (expect_ok "let mut bufs: [u8; 64] align(32);
                fn f() { let p: *align(32) u8 = bufs; }");

  Alcotest.test_case "a literal address cast proves *align(N) T from its own value" `Quick
    (expect_ok "fn f() { let p: *align(4) u32 = 0x1000 as *align(4) u32; }");

  Alcotest.test_case "aligned_ptr + (i * literal-multiple-of-N) stays *align(N) T" `Quick
    (expect_ok "let mut bufs: [u8; 1536] align(32);
                fn f(i: isize) { let p: *align(32) u8 = bufs + i * 32; }");

  Alcotest.test_case "aligned_ptr + an unproven offset decays to plain *T" `Quick
    (expect_type_error "cannot pass unproven"
       "let mut bufs: [u8; 64] align(32);
        fn f(i: isize) { let p: *align(32) u8 = bufs + i; }");

  Alcotest.test_case "*align(N) T widens to a plain *T with no unsafe" `Quick
    (expect_ok "let mut buf: [u8; 64] align(32);
                fn f() { let p: *u8 = buf; }");

  Alcotest.test_case "*align(N) T subtypes into *align(K) T when K divides N" `Quick
    (expect_ok "let mut buf: [u8; 64] align(32);
                fn f() { let p: *align(16) u8 = buf; }");

  Alcotest.test_case "a plain *T is rejected where *align(N) T is required" `Quick
    (expect_type_error "cannot pass unproven"
       "fn f(p: *u8) { let q: *align(32) u8 = p; }");

  Alcotest.test_case "unsafe marks an unproven cast to *align(N) T" `Quick
    (expect_ok "fn f(p: *u8) -> *align(32) u8 !{unsafe} { return unsafe { p as *align(32) u8 }; }");

  (* Real end-to-end codegen: array decay + pointer arithmetic by a
     literal multiple of N (the examples/common_stm32/eth.tkb `eth_rx_bufs
     + eth_rx_cur * ETH_BUF_SIZE` shape) + passing the result as a
     function argument + indexed read/write through the parameter. *)
  Alcotest.test_case "aligned pointer arithmetic and indexing codegens correctly" `Quick
    (expect_codegen_ok
       "let mut bufs: [u8; 1536] align(32);
        fn touch(p: *align(32) u8) {
            p[0] = 1;
        }
        fn app_main_align_codegen(i: isize) {
            touch(bufs + i * 32);
        }");

  Alcotest.test_case "borrow is accepted for non-retaining raw pointer parameters" `Quick
    (fun () -> ignore (infer "fn inspect(x: borrow *u8) { let b: u8 = x[0]; }"));

  (* -- extern fn --------------------------------------------------- *)

  Alcotest.test_case "extern fn void can be called" `Quick
    (expect_ok "extern fn uart_putc(c: u8);
                fn f() { uart_putc('A'); }");

  Alcotest.test_case "extern fn with return type propagates" `Quick
    (expect_ok "extern fn uart_getc() -> u8;
                fn f() u8 { return uart_getc(); }");

  (* -- String literals -------------------------------------------- *)

  Alcotest.test_case "string literal infers as *u8" `Quick (fun () ->
    let pt = infer "fn f() { let s = \"hello\"; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "s has type *u8" (Ast.TypePtr Ast.TypeU8)
      (Types.StringMap.find "s" fi.Types.local_types)
  );

  (* -- Struct literals -------------------------------------------- *)

  Alcotest.test_case "struct literal initializer type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn f() { let mut p: Point = {1, 2}; }");

  Alcotest.test_case "array literal initializer type-checks" `Quick
    (expect_ok "fn f() { let mut arr: [u8; 3] = {'a', 'b', 'c'}; }");

  Alcotest.test_case "struct literal wrong field count is a type error" `Quick
    (expect_type_error "has"
       "struct Point { x: i32; y: i32; }
        fn f() { let mut p: Point = {1, 2, 3}; }");

  Alcotest.test_case "struct literal field type mismatch is a type error" `Quick
    (expect_type_error "cannot unify"
       "struct S { x: i32; }
        fn f(p: *i32) { let mut s: S = {p}; }");

  (* Found while building examples/affine_escape_via_index (GitHub issue
     #89's escape idiom): a struct returned BY VALUE from a function used
     to produce invalid LLVM IR (`ret ptr %p` from a function declared to
     return the aggregate `{i32,i32}` itself) -- coerce's TypeNamed case
     passed the struct's pointer representation straight through instead
     of loading the aggregate value at this boundary. Fixed in coerce
     (lib/llvm_gen.ml), which also fixed the symmetric case (a struct
     passed BY VALUE as a call argument, `sum(p)` below). *)
  Alcotest.test_case "struct returned by value from a function codegens correctly" `Quick
    (expect_codegen_ok
       "struct Process { fd_a: i32; fd_b: i32; }
        fn open_two() -> Process {
            let mut p: Process = {10, 20};
            return p;
        }
        fn sum(p: Process) -> i32 { return p.fd_a + p.fd_b; }
        fn app_main() -> i32 {
            let mut proc: Process = open_two();
            return sum(proc);
        }");

  (* The second half of the same bug: an IMMUTABLE `let` has no alloca
     (see llvm_gen.ml's Let(false, ...) case), so a struct-typed
     immutable binding has no address for later field access to GEP into
     -- this was already rejected for a struct LITERAL initializer
     (`struct literal requires let mut` above) but not for any OTHER
     struct-typed initializer, such as this function-call result, which
     used to reach codegen and crash there instead of being caught here. *)
  Alcotest.test_case "immutable let of a non-literal struct-typed value is a type error" `Quick
    (expect_type_error "requires `let mut proc: Name"
       "struct Process { fd_a: i32; fd_b: i32; }
        fn open_two() -> Process {
            let mut p: Process = {10, 20};
            return p;
        }
        fn f() { let proc: Process = open_two(); }");

  (* Negative control: an enum-typed value shares `Types.ty`'s TStruct
     representation with real structs (Types.of_ast's `TypeNamed s ->
     TStruct s`) but is just an integer at the LLVM level (no field
     access, no address needed) -- must NOT be caught by the check above. *)
  Alcotest.test_case "immutable let of an enum-typed value is still fine" `Quick
    (expect_ok "enum Color: u8 { Red = 0; Green = 1; Blue = 2; }
                fn make() -> Color { return Color::Red; }
                fn f() { let c: Color = make(); }");

  (* -- Commutative pointer arithmetic: isize + ptr --------------------------- *)

  Alcotest.test_case "isize + ptr commutative pointer arithmetic type-checks" `Quick
    (expect_ok "fn f(p: *u8, offset: isize) *u8 { return offset + p; }");

  Alcotest.test_case "i32 + ptr commutative pointer arithmetic is rejected" `Quick
    (expect_type_error "cannot unify i32 with isize"
       "fn f(p: *u8, offset: i32) *u8 { return offset + p; }");

  (* -- &s.field -------------------------------------------------- *)

  Alcotest.test_case "&s.field yields pointer-to-field-type" `Quick (fun () ->
    let pt = infer "struct P { x: i32; }
                    fn f() { let mut s: P; let q = &s.x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "q has type *i32" (Ast.TypePtr Ast.TypeI32)
      (Types.StringMap.find "q" fi.Types.local_types)
  );

  (* -- Field assignment through pointer receiver ------------------------- *)

  Alcotest.test_case "field assign via pointer receiver type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn f(p: *Point) { p.x = 1; p.y = 2; }");

  (* -- let mut local variable (uninitialized) ----------------------- *)

  Alcotest.test_case "let mut local without initializer type-checks" `Quick
    (expect_ok "fn f() { let mut x: i32; x = 0; }");

  (* -- Left shift and bitwise OR --------------------------------------- *)

  Alcotest.test_case "left shift Shl type-checks" `Quick
    (expect_ok "fn f(n: i32) i32 { return n << 3; }");

  Alcotest.test_case "bitwise OR Bor type-checks" `Quick
    (expect_ok "fn f(a: i32, b: i32) i32 { return a | b; }");

  (* -- Compile-time bounds check for constant indices --------------- *)

  Alcotest.test_case "constant in-bounds read type-checks" `Quick
    (expect_ok "fn f() i32 { let mut arr: [i32; 4]; return arr[3]; }");

  Alcotest.test_case "constant in-bounds write type-checks" `Quick
    (expect_ok "fn f() { let mut arr: [i32; 4]; arr[3] = 1; }");

  Alcotest.test_case "constant OOB read is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() i32 { let mut arr: [i32; 4]; return arr[4]; }");

  Alcotest.test_case "constant OOB write is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() { let mut arr: [i32; 4]; arr[4] = 1; }");

  Alcotest.test_case "exact boundary OOB read is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() i32 { let mut arr: [i32; 8]; return arr[8]; }");

  Alcotest.test_case "large OOB index is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() i32 { let mut arr: [i32; 4]; return arr[100]; }");

  Alcotest.test_case "dynamic index on array still type-checks (usize)" `Quick
    (expect_ok "fn f(i: usize) i32 { let mut arr: [i32; 4]; return arr[i]; }");

  Alcotest.test_case "dynamic i32 index on array is a compile error (must be usize)" `Quick
    (expect_type_error "must be usize"
       "fn f(i: i32) i32 { let mut arr: [i32; 4]; return arr[i]; }");

  Alcotest.test_case "dynamic i32 array assignment index is a compile error" `Quick
    (expect_type_error "must be usize"
       "fn f(i: i32) { let mut arr: [i32; 4]; arr[i] = 1; }");

  Alcotest.test_case "dynamic i32 subslice bound is a compile error (must be usize)" `Quick
    (expect_type_error "must be usize"
       "fn f(s: []u8, lo: i32, hi: i32) -> []u8 { return s[lo..<hi]; }");

  Alcotest.test_case "raw-pointer slice bounds use isize offsets" `Quick
    (expect_ok
       "fn f(p: *u8, lo: isize, hi: isize) -> []u8 !{unsafe} {
          return unsafe { p[lo..<hi] };
        }");

  Alcotest.test_case "raw-pointer index rejects i32 offsets" `Quick
    (expect_type_error "must be isize"
       "fn f(p: *u8, i: i32) -> u8 { return p[i]; }");

  Alcotest.test_case "raw-pointer index rejects usize offsets" `Quick
    (expect_type_error "must be isize"
       "fn f(p: *u8, i: usize) -> u8 { return p[i]; }");

  Alcotest.test_case "raw-pointer assignment rejects i32 offsets" `Quick
    (expect_type_error "must be isize"
       "fn f(p: *u8, i: i32) { p[i] = 1 as u8; }");

  Alcotest.test_case "raw-pointer negative index infers as isize" `Quick
    (expect_ok "fn f(p: *u8) -> u8 { return p[-1]; }");

  Alcotest.test_case "raw-pointer slice rejects non-isize bounds" `Quick
    (expect_type_error "must be isize"
       "fn f(p: *u8, lo: usize, hi: usize) -> []u8 {
          return unsafe { p[lo..<hi] };
        }");

  Alcotest.test_case "constant OOB on global array is a compile error" `Quick
    (expect_type_error "out of bounds"
       "let mut buf: [u8; 8]; fn f() u8 { return buf[8]; }");

  (* -- Bounds check for char arrays ----------------------------------- *)

  Alcotest.test_case "constant OOB read on u8 array is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() u8 { let mut arr: [u8; 4]; return arr[4]; }");

  Alcotest.test_case "constant OOB write on u8 array is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() { let mut arr: [u8; 4]; arr[4] = 'A'; }");

  (* -- Bounds check for size-1 arrays ------------------------------- *)

  Alcotest.test_case "size-1 array: index 0 is in-bounds" `Quick
    (expect_ok "fn f() i32 { let mut arr: [i32; 1]; return arr[0]; }");

  Alcotest.test_case "size-1 array: index 1 is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() i32 { let mut arr: [i32; 1]; return arr[1]; }");

  (* -- Write to global array -------------------------------- *)

  Alcotest.test_case "constant OOB write on global i32 array is a compile error" `Quick
    (expect_type_error "out of bounds"
       "let mut buf: [i32; 4]; fn f() { buf[4] = 0; }");

  (* -- OOB in expression context ----------------------------------------- *)

  Alcotest.test_case "constant OOB in function call argument is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn g(x: i32) {} fn f() { let mut arr: [i32; 4]; g(arr[4]); }");

  Alcotest.test_case "constant OOB in binary expression is a compile error" `Quick
    (expect_type_error "out of bounds"
       "fn f() i32 { let mut arr: [i32; 4]; return arr[4] + 1; }");

  (* -- Verify error message format ------------------------------- *)

  Alcotest.test_case "OOB error message includes index and array size" `Quick
    (expect_type_error "index 5 is out of bounds for array of size 4"
       "fn f() i32 { let mut arr: [i32; 4]; return arr[5]; }");

  Alcotest.test_case "TypeError location points at the bad expression" `Quick
    (expect_type_error_at 3 22 "out of bounds"
       "fn f() i32 {
          let mut arr: [i32; 4];
          return arr[5];
        }");

  (* -- TypeRefined syntax (Step 3.1 / 3.2) ----------------------- *)

  Alcotest.test_case "TypeRefined parses as param annotation" `Quick (fun () ->
    let pt = infer "fn f(i: {0..<8 as i32}) i32 { return i; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "i has type {0..<8 as i32}"
      (Ast.TypeRefined (0, 8, Ast.TypeI32))
      (snd (List.hd fi.Types.param_types)));

  Alcotest.test_case "TypeRefined after -> parses as return type" `Quick (fun () ->
    let pt = infer "fn f() -> {0..<8 as i32} { return 0; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {0..<8 as i32}"
      (Ast.TypeRefined (0, 8, Ast.TypeI32))
      fi.Types.ret_type);

  Alcotest.test_case "TypeRefined in let annotation type-checks" `Quick
    (expect_ok "fn f() { let x: {0..<8 as i32} = 3; }");

  Alcotest.test_case "TypeRefined as param unifies with i32 body" `Quick
    (expect_ok "fn f(i: {0..<8 as i32}) i32 { return i; }");

  Alcotest.test_case "TypeRefined can be used as array index" `Quick
    (expect_ok "fn f(i: {0..<8 as isize}, p: *u8) { p[i] = 'A'; }");

  (* -- Step 3.3c: Range propagation ------------------------------------ *)

  Alcotest.test_case "Add propagates TRefinedInt: {0..<7 as i32}+1 is {1..<8 as i32}" `Quick (fun () ->
    let pt = infer "fn f(i: {0..<7 as i32}) -> {1..<8 as i32} { return i + 1; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {1..<8 as i32}"
      (Ast.TypeRefined (1, 8, Ast.TypeI32))
      fi.Types.ret_type);

  Alcotest.test_case "Sub propagates TRefinedInt: {1..<8 as i32}-1 is {0..<7 as i32}" `Quick (fun () ->
    let pt = infer "fn f(i: {1..<8 as i32}) -> {0..<7 as i32} { return i - 1; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {0..<7 as i32}"
      (Ast.TypeRefined (0, 7, Ast.TypeI32))
      fi.Types.ret_type);

  Alcotest.test_case "Add propagation: k+{c..<d} commutative" `Quick (fun () ->
    let pt = infer "fn f(i: {0..<4 as i32}) -> {3..<7 as i32} { return 3 + i; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {3..<7 as i32}"
      (Ast.TypeRefined (3, 7, Ast.TypeI32))
      fi.Types.ret_type);

  Alcotest.test_case "range propagation folds a const quotient used as an array stride" `Quick
    (expect_trap_sites 0
      "const BYTES: usize = 64;
       let mut words: [u32; 528];
       fn f(endpoint: {1..<16 as usize}) {
         let endpoint_index: usize = endpoint * 2;
         let context_word: usize = (endpoint_index + 2) * (BYTES / 4);
         words[context_word + 3] = 0;
       }");

  Alcotest.test_case "TRefinedInt result is subtype of i32 return" `Quick
    (expect_ok "fn f(i: {0..<7 as i32}) -> i32 { return i + 1; }");

  Alcotest.test_case "narrower TRefinedInt range is a subtype of a wider refined range" `Quick
    (expect_ok
      "fn wider(i: {0..<513 as usize}) {}
       fn f(i: {129..<513 as usize}) { wider(i); }");

  Alcotest.test_case "Mismatched refined return is a type error" `Quick
    (expect_type_error "range mismatch"
      "fn f(i: {0..<8 as i32}) -> {0..<8 as i32} { return i + 1; }");

  (* -- Step 3.3c: soundness condition for % range propagation ---------------------------- *)
  (* When the left operand is int (possibly negative), do not return {0..<m}.
     LLVM's srem returns a negative remainder when the dividend is negative, making this unsound.
     Example: (-5) % 8 = -5 (not 3) -- returning {0..<8 as i32} without a non-negative guarantee is wrong. *)

  Alcotest.test_case "i32%m stays TInt -- negative left operand possible" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(n: i32) { foo(n % 4); }");

  Alcotest.test_case "{0..<8 as i32}%4 propagates to {0..<4 as i32}" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(i: {0..<8 as i32}) { foo(i % 4); }");

  Alcotest.test_case "{0..<8 as i32}%8 can index [u8;8] without bounds check" `Quick
    (expect_ok
      "let mut buf: [u8; 8]; \
       fn f(i: {0..<8 as usize}) { buf[i % 8] = 'X'; }");

  (* GitHub issue #217: struct_ptr.array_field[i] type-checks directly
     (no manual `let` workaround) for both read and write, and the
     restricted-shape rule around it fires clear errors rather than
     silently accepting (and later crashing codegen on) an unsupported
     base shape. *)
  Alcotest.test_case
    "struct-field array READ struct_ptr.field[i] type-checks with no \
     manual let-binding workaround (issue #217 Gap 1)" `Quick
    (expect_ok
      "struct Core217T { next_free: [usize; 8]; } \
       fn f(core: *Core217T, i: usize) -> usize { return core.next_free[i]; }");

  Alcotest.test_case
    "struct-field array WRITE struct_ptr.field[i] = v type-checks with no \
     manual let-binding workaround (issue #217 Gap 1)" `Quick
    (expect_ok
      "struct Core217T2 { next_free: [usize; 8]; } \
       fn f(core: *Core217T2, i: usize, v: usize) { core.next_free[i] = v; }");

  Alcotest.test_case
    "indexing another Index's result directly (a[i][j]) is a clear, \
     not-yet-supported type error rather than an accepted-then-crashing \
     shape (issue #217 explicitly scopes this out; codegen has no \
     address-preserving Index-as-base variant)" `Quick
    (expect_type_error "not yet supported"
      "fn f(a: *[usize; 4], i: usize, j: usize) -> usize {
         return (*a)[i][j];
       }");

  Alcotest.test_case
    "indexing a non-place expr (a function call's result) is rejected \
     rather than silently accepted (issue #217's restricted-shape rule: \
     Var/FieldGet-chain only, matching static_place_key)" `Quick
    (expect_type_error "must be a variable or a chain of struct field"
      "fn mk217() -> *usize { return 0 as usize as *usize; }
       fn f(i: usize) -> usize { return mk217()[i]; }");

  (* -- Step 3.4: Bounds check elision (global array + TypeRefined index) -- *)

  Alcotest.test_case "refined index on global array compiles" `Quick
    (expect_ok
      "let mut buf: [u8; 8]; \
       fn f(i: {0..<8 as usize}) { buf[i] = 'X'; }");

  Alcotest.test_case "refined pair write (i and i+1) compiles" `Quick
    (expect_ok
      "let mut buf: [u8; 8]; \
       fn f(i: {0..<7 as usize}) { buf[i] = 'A'; buf[i+1] = 'B'; }");

  Alcotest.test_case "refined arithmetic range mismatch caught at return" `Quick
    (expect_type_error "range mismatch"
      "fn f(i: {0..<8 as i32}) -> {0..<8 as i32} { return i + 1; }");

  Alcotest.test_case "non-proven index (overflow range) still compiles" `Quick
    (expect_ok
      "let mut buf: [u8; 8]; \
       fn f(i: {0..<8 as usize}) { buf[i+1] = 'Z'; }");

  (* -- Step 3.5: Type narrowing via if-condition ------------------------------- *)

  Alcotest.test_case "if (v>=0 && v<8) narrows v to {0..<8 as i32}" `Quick
    (expect_ok
      "let mut buf: [u8; 8]; \
       fn foo(i: {0..<8 as i32}) {} \
       fn f(v: i32) { if (v >= 0 && v < 8) { foo(v); } }");

  Alcotest.test_case "if (v>=0 && v<8) allows buf[v] write (cast to usize \
                       carries the narrowed range across the base change)" `Quick
    (expect_ok
      "let mut buf: [u8; 8]; \
       fn f(v: i32) { if (v >= 0 && v < 8) { buf[v as {0..<8 as usize}] = 'X'; } }");

  Alcotest.test_case "outside if block v remains i32 (no escape)" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<8 as i32}) {} \
       fn f(v: i32) { if (v >= 0 && v < 8) {} foo(v); }");

  Alcotest.test_case "single bound (only v<8) does not narrow" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<8 as i32}) {} \
       fn f(v: i32) { if (v < 8) { foo(v); } }");

  Alcotest.test_case "let mut variable is also narrowed in then-branch" `Quick
    (expect_ok
      "fn foo(i: {0..<8 as i32}) {} \
       fn f() { let mut v: i32 = 3; if (v >= 0 && v < 8) { foo(v); } }");

  Alcotest.test_case "else branch does not get narrowing" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<8 as i32}) {} \
       fn f(v: i32) { if (v >= 0 && v < 8) {} else { foo(v); } }");

  Alcotest.test_case "commutative form (0<=v && v<8) also narrows" `Quick
    (expect_ok
      "fn foo(i: {0..<8 as i32}) {} \
       fn f(v: i32) { if (0 <= v && v < 8) { foo(v); } }");

  Alcotest.test_case
    "if upper bound folds const addition/subtraction instead of requiring a magic-number literal" `Quick
    (expect_ok
      "const IMAGE_LEN: usize = 4096;
       const BLOCK_SIZE: usize = 1024;
       fn take(i: {0..<IMAGE_LEN - BLOCK_SIZE + 1 as usize}) {}
       fn f(offset: usize) {
         if (offset < IMAGE_LEN - BLOCK_SIZE + 1) { take(offset); }
       }");

  (* GitHub issue #295 follow-up (extended by #296, see below): an
     early-return guard narrows the FALLTHROUGH path (code after the if,
     not a `then`/`else` body) via the condition's own logical negation,
     when the guarded branch always returns and there is no else. Found
     while writing kernel/net/tcp.tkb's pending_tcp_record: `if (found <
     0 || found >= 4) { return -1; }` followed by code needing found:
     {0..<4} previously had no way to prove that range short of
     restructuring into the already-supported wrapping-if form.

     GitHub issue #296: originally restricted to immutable `let` bindings
     only (found the hard way against real kernel code --
     kernel/drivers/net/virtio_net.tkb's `if (initialized != 0) { return
     Failed; } initialized = 1;` init-guard idiom broke on the first
     whole-kernel build after an unrestricted version of this feature was
     first added, since the narrowed {0..<1} type for `initialized`
     survived into the very next statement, an ordinary assignment of 1
     to it, and rejected a plainly valid write). Now extended to mutable
     bindings AND ordinary (non-`mut`) function parameters -- both
     assignable in this language -- via enclosing_future_writes: a
     mutable/parameter binding keeps its narrowing into the continuation
     exactly when NO statement anywhere in the same enclosing list writes
     to it afterward (see that ref's own comment in lib/type_inf.ml). The
     virtio_net.tkb shape is exactly the case this excludes: `initialized`
     IS written later (by `initialized = 1;`), so its narrowing is
     correctly dropped and the assignment is checked against its ordinary
     declared type, not a stale narrowed one -- see the dedicated
     regression test below. *)
  Alcotest.test_case "early-return guard (De Morgan of ||) narrows the \
                       fallthrough path for an immutable local" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         let n: i32 = v; \
         if (n < 0 || n >= 4) { return -1; } \
         foo(n); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard (issue #296) narrows a mutable \
                       function parameter that is never reassigned \
                       afterward" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         if (v < 0 || v >= 4) { return -1; } \
         foo(v); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard (issue #296 regression: the \
                       virtio_net.tkb shape) drops narrowing for a \
                       variable reassigned later in the same enclosing \
                       list, so the later assignment is checked against \
                       its declared type, not a stale narrowed one" `Quick
    (expect_ok
      "fn f(v: i32) -> i32 { \
         if (v != 0) { return -1; } \
         v = 5; \
         return v; \
       }");

  Alcotest.test_case "early-return guard (issue #296): a variable \
                       reassigned later still cannot be passed where the \
                       narrowed range would have been required (the \
                       dropped narrowing is not silently kept for reads \
                       either)" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<1 as i32}) {} \
       fn f(v: i32) -> i32 { \
         if (v != 0) { return -1; } \
         v = 5; \
         foo(v); \
         return 0; \
       }");

  (* GitHub issue #296 (see kernel/arch/arm64/mm/asid.tkb's
     asid_transferred_release, the real function that hit this): a guard
     written with `!=` narrows the fallthrough (negates to `==`, a single
     point), but the SAME comparison written the other way, with `==`,
     does NOT (negates to `!=`, not representable as a contiguous
     range) -- an easy-to-miss asymmetry when picking which side of a
     `==`/`!=` pair to write a guard with. *)
  Alcotest.test_case "early-return guard (issue #296): `!=` in the guard \
                       narrows the fallthrough (negates to `==`, a \
                       single point)" `Quick
    (expect_ok
      "fn foo(i: {0..<1 as i32}) {} \
       fn f(v: i32) -> i32 { \
         if (v != 0) { return -1; } \
         foo(v); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard (issue #296): the SAME \
                       comparison written with `==` instead does NOT \
                       narrow the fallthrough (negates to `!=`, not a \
                       contiguous range) -- write the equivalent `<`/`>=` \
                       form if a proof is needed" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<1 as i32}) {} \
       fn f(v: i32) -> i32 { \
         if (v == 1) { return -1; } \
         foo(v); \
         return 0; \
       }");

  (* An And-conjunction guard negates to an Or via De Morgan
     (negate_cond (And a b) = Or (negate a) (negate b)), and
     collect_bounds only ever recurses into And, not Or (same
     conservative scope the positive wrapping-if form already has) --
     so an And-shaped guard's fallthrough is deliberately NOT narrowed,
     unlike this file's Or-shaped guard above whose negation lands back
     on the supported And shape. Documents the boundary, not a defect. *)
  Alcotest.test_case "early-return guard (And form) does NOT narrow the \
                       fallthrough path (negates to an unsupported Or)" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         let n: i32 = v; \
         if (n >= 4 && n < 0) { return -1; } \
         foo(n); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard: a single-sided bound still \
                       does not narrow (matches the wrapping-if form's \
                       own same limitation)" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         let n: i32 = v; \
         if (n < 0) { return -1; } \
         foo(n); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard: an empty (or absent) else \
                       branch narrows the fallthrough identically -- \
                       the two are indistinguishable, both at the AST \
                       level and semantically" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         let n: i32 = v; \
         if (n < 0 || n >= 4) { return -1; } else {} \
         foo(n); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard: a non-empty else branch that \
                       does not write n still narrows the fallthrough" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn bar() {} \
       fn f(v: i32) -> i32 { \
         let n: i32 = v; \
         if (n < 0 || n >= 4) { return -1; } else { bar(); } \
         foo(n); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard: a branch that does not always \
                       return disables the fallthrough narrowing" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         if (v < 0 || v >= 4) {} \
         foo(v); \
         return 0; \
       }");

  Alcotest.test_case "early-return guard: an unrecognized condition \
                       shape (function call) does not narrow (negate_cond \
                       returns None, falls back to today's behavior)" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4 as i32}) {} \
       fn cond(v: i32) -> bool { return v < 0; } \
       fn f(v: i32) -> i32 { \
         if (cond(v)) { return -1; } \
         foo(v); \
         return 0; \
       }");

  (* GitHub issue #310: two real-kernel shapes named in the issue's own
     Motivation, each now getting an explanatory hint instead of a bare
     "unproven" message. `cond(v)` above deliberately keeps its PLAIN
     message unchanged (v never appears as a BinOp comparison operand in
     a bare function-call condition, so record_guard_narrow_hints records
     nothing for it) -- the issue's own "should keep today's plain
     'unproven' message rather than guessing" scoping, confirmed by that
     existing test still passing unmodified. *)
  Alcotest.test_case
    "early-return guard: a guard using '==' gets a hint explaining its \
     negation ('!=') can't narrow, mirroring kernel/arch/arm64/mm/ \
     asid.tkb's asid_transferred_release (issue #310)" `Quick
    (expect_type_error
       "was the subject of an early-return guard above using '=='"
       "fn foo(i: {1..<8 as usize}) {} \
        fn f(asid: usize) { \
          if (asid == 0) { return; } \
          foo(asid); \
        }");

  Alcotest.test_case
    "early-return guard: an And-shaped guard whose negation lands on an \
     unsupported Or gets a hint, mirroring the kernel/lib/slotmap.tkb \
     -shaped restructuring this issue's own Motivation names (issue \
     #310)" `Quick
    (expect_type_error
       "whose negation is not a condition shape this compiler's \
        narrowing recognizes"
       "fn foo(i: {0..<4 as i32}) {} \
        fn f(v: i32) -> i32 { \
          if (v >= 0 && v < 4) { return -1; } \
          foo(v); \
          return 0; \
        }");

  (* Positive control (issue #310's own acceptance criteria): a guard \
     shape that DOES narrow continues to produce no error at all -- no \
     hint machinery involved since unify_at never fails here. *)
  Alcotest.test_case
    "early-return guard: an Or-shaped guard whose negation is a \
     supported And still narrows with no error (issue #310 positive \
     control)" `Quick
    (expect_ok
      "fn foo(i: {0..<4 as i32}) {} \
       fn f(v: i32) -> i32 { \
         if (v < 0 || v >= 4) { return -1; } \
         foo(v); \
         return 0; \
       }");

  (* -- Step 3.5 for loop: for i in lo..<hi ----------------------------------- *)

  Alcotest.test_case "for loop parses and type-checks" `Quick
    (expect_ok "fn f() { for i: i32 in 0..<8 {} }");

  (* -- for i: T in lo..<hi -- explicit base annotation on the loop counter -- *)

  Alcotest.test_case "for i: u8 in lo..<hi gives i type {lo..<hi as u8}" `Quick
    (fun () ->
      let pt = infer "fn f() { for i: u8 in 0..<4 {} }" in
      let fi = Types.StringMap.find "f" pt.Types.functions in
      Alcotest.check type_t "i is {0..<4 as u8}"
        (Ast.TypeRefined (0, 4, Ast.TypeU8))
        (Types.StringMap.find "__for_i" fi.Types.local_types));

  Alcotest.test_case "for i: usize in lo..<hi parses (all 9 int_base_type_expr bases accepted)" `Quick
    (expect_ok "fn f() { for i: usize in 0..<4 {} }");

  Alcotest.test_case "for loop variable has refined type (literal bounds)" `Quick
    (fun () ->
      let pt = infer "let mut buf: [u8; 8]; \
                      fn f() { for i: usize in 0..<8 { buf[i] = 'X'; } }" in
      (* buf[i] should compile without error: i:{0..<8 as usize} covers [u8;8] *)
      ignore pt);

  Alcotest.test_case "for loop body accesses refined-param function" `Quick
    (expect_ok
      "fn foo(i: {0..<8 as i32}) {} \
       fn f() { for i in 0..<8 { foo(i); } }");

  Alcotest.test_case "for loop variable does not escape" `Quick
    (expect_type_error "Unbound variable"
      "fn f() { for i: i32 in 0..<8 {} let x: i32 = i; }");

  Alcotest.test_case "for with variable bounds gives plain i32" `Quick
    (expect_ok
      "fn f(n: i32) { let mut s: i32 = 0; for i in 0..<n { s = s + i; } }");

  Alcotest.test_case "nested for loops compile" `Quick
    (expect_ok
      "let mut buf: [u8; 4]; \
       fn f() { for i: usize in 0..<4 { buf[i] = 'A'; } \
                for i: usize in 0..<4 { buf[i] = 'B'; } }");

  (* -- For-loop counter follows the bounds' own base type, not a hardcoded
     TI32 (regression -- `for i in 0..<s.len` (s.len: TUsize) used to fail
     outright with "cannot unify usize with i32", because the old
     unconditional `unify_at ... TI32` forced both bounds to already be
     i32-compatible before TRefinedInt's leniency into TI32 could ever
     apply -- a bare (non-refined) TUsize has no such leniency rule) -- *)

  Alcotest.test_case
    "for loop over a slice's own .len (usize) type-checks -- previously \
     failed with 'cannot unify usize with i32'" `Quick
    (expect_ok
      "fn f(s: []u8) -> i32 { \
         let mut total: i32 = 0; \
         for i in 0..<s.len { total = total + (s[i] as i32); } \
         return total; \
       }");

  Alcotest.test_case
    "for loop bound typed u8 gives the counter a u8-based type (usable as \
     an array index directly, via Index's own require_integer \
     generalization)" `Quick
    (expect_ok
      "fn f(n: u8) -> i32 { \
         let mut total: i32 = 0; \
         for i in 0..<n { total = total + 1; } \
         return total; \
       }");

  Alcotest.test_case
    "for loop bounds must be an integer type -- a bool bound is rejected \
     with a clear error, not silently accepted as some nonsense counter \
     type" `Quick
    (fun () ->
      match infer "fn f() { for i in 0..<true {} }" with
      | _ -> Alcotest.fail "expected an error, but type-checking succeeded"
      | exception Types.TypeError (_, msg) ->
          Alcotest.(check bool) "mentions integer type" true
            (let n = String.length "integer type" and m = String.length msg in
             let rec scan i = i + n <= m &&
               (String.sub msg i n = "integer type" || scan (i + 1)) in
             scan 0));

  (* -- break and continue ---------------------------------------------------- *)

  Alcotest.test_case "break in while parses and type-checks" `Quick
    (expect_ok "fn f() { while (true) { break; } }");

  Alcotest.test_case "continue in while parses and type-checks" `Quick
    (expect_ok "fn f() { while (true) { continue; } }");

  Alcotest.test_case "break in for parses and type-checks" `Quick
    (expect_ok "fn f() { for i: i32 in 0..<10 { break; } }");

  Alcotest.test_case "continue in for parses and type-checks" `Quick
    (expect_ok "fn f() { for i: i32 in 0..<10 { continue; } }");

  Alcotest.test_case "break inside if inside while type-checks" `Quick
    (expect_ok "fn f(x: i32) { while (true) { if (x == 0) { break; } } }");

  Alcotest.test_case "continue inside if inside for type-checks" `Quick
    (expect_ok "fn f(x: i32) { for i: i32 in 0..<10 { if (x == 0) { continue; } } }");

  Alcotest.test_case "break outside loop is a type error" `Quick
    (expect_type_error "break/continue outside of a loop"
      "fn f() { break; }");

  Alcotest.test_case "continue outside loop is a type error" `Quick
    (expect_type_error "break/continue outside of a loop"
      "fn f() { continue; }");

  Alcotest.test_case "break after if outside loop is a type error" `Quick
    (expect_type_error "break/continue outside of a loop"
      "fn f(x: i32) { if (x == 0) { break; } }");

  (* -- Enum type inference ------------------------------------------- *)

  Alcotest.test_case "exhaustive enum match all variants type-checks" `Quick
    (expect_ok
      "enum Color: u8 { Red = 0; Green = 1; }
       fn f(c: Color) { match c {
         Color::Red   => { let x: i32 = 0; }
         Color::Green => { let y: i32 = 1; } } }");

  Alcotest.test_case "exhaustive enum match missing variant is a type error" `Quick
    (expect_type_error "non-exhaustive match: 'Color::Green' not covered"
      "enum Color: u8 { Red = 0; Green = 1; }
       fn f(c: Color) { match c { Color::Red => { let x = 0; } } }");

  Alcotest.test_case "exhaustive enum match with wildcard type-checks" `Quick
    (expect_ok
      "enum Color: u8 { Red = 0; Green = 1; }
       fn f(c: Color) { match c {
         Color::Red => { let x: i32 = 0; }
         _ => { let y: i32 = 1; } } }");

  Alcotest.test_case "non-exhaustive enum match with _ type-checks" `Quick
    (expect_ok
      "enum EtherType: u16 { IPv4 = 0x0800; _; }
       fn f(et: EtherType) { match et {
         EtherType::IPv4 => { let x: i32 = 0; }
         _ => { let y: i32 = 1; } } }");

  Alcotest.test_case "non-exhaustive enum match without _ is a type error" `Quick
    (expect_type_error "non-exhaustive enum 'EtherType' requires a '_' wildcard arm"
      "enum EtherType: u16 { IPv4 = 0x0800; _; }
       fn f(et: EtherType) { match et { EtherType::IPv4 => { let x = 0; } } }");

  Alcotest.test_case "enum cast to underlying type type-checks" `Quick
    (expect_ok
      "enum Color: u8 { Red = 0; }
       fn f(c: Color) u8 { return c as u8; }");

  Alcotest.test_case "enum cast to wrong type is a type error" `Quick
    (expect_type_error "cannot cast enum 'Color' (underlying u8) to 'i32'"
      "enum Color: u8 { Red = 0; }
       fn f(c: Color) i32 { return c as i32; }");

  Alcotest.test_case "underlying type cast to enum type-checks" `Quick
    (expect_ok
      "enum Color: u8 { Red = 0; }
       fn f(n: u8) Color { return n as Color; }");

  Alcotest.test_case "wrong source type to enum cast is a type error" `Quick
    (expect_type_error "cannot cast 'i32' to enum 'Color' (underlying u8)"
      "enum Color: u8 { Red = 0; }
       fn f(n: i32) Color { return n as Color; }");

  Alcotest.test_case "refined int subtype cast to enum type-checks" `Quick
    (expect_ok
      "enum Color: u8 { Red = 0; Green = 1; Blue = 2; }
       fn f() { for i: i32 in 0..<3 { let c: Color = i as Color; } }");

  Alcotest.test_case "packed struct field access type-checks" `Quick
    (expect_ok "struct packed Hdr { a: u8; b: u16; }
     fn f(h: *Hdr) -> u8 { return h.a; }");

  Alcotest.test_case "struct align(N) field access type-checks" `Quick
    (expect_ok "struct Vec4 align(16) { x: i32; y: i32; }
     fn f(v: *Vec4) -> i32 { return v.x; }");

  Alcotest.test_case "struct packed align(N) field access type-checks" `Quick
    (expect_ok "struct packed Hdr align(4) { a: u8; b: u16; }
     fn f(h: *Hdr) -> u8 { return h.a; }");

  Alcotest.test_case "usize annotation type-checks" `Quick
    (expect_ok "let mut g: u8; fn f() { let x: usize = 0; }");

  Alcotest.test_case "pointer as usize type-checks" `Quick
    (expect_ok "let mut g: u8; fn f() { let p: *u8 = &g; let x: usize = p as usize; }");

  Alcotest.test_case "usize as pointer type-checks" `Quick
    (expect_ok "let mut g: u8; fn f() { let a: usize = 0x09000000; let p: *u8 = a as *u8; }");

  Alcotest.test_case "usize arithmetic type-checks" `Quick
    (expect_ok "let mut g: u8;
     fn f() { let a: usize = (&g) as usize; let b: usize = a & 63; let c: usize = b + 1; }");

  Alcotest.test_case "pointer as i32 is a type error" `Quick
    (expect_type_error "cannot cast pointer"
       "let mut g: u8; fn f() { let p: *u8 = &g; let x: i32 = p as i32; }");

  Alcotest.test_case "pointer as u64 is a type error" `Quick
    (expect_type_error "cannot cast pointer"
       "let mut g: u8; fn f() { let p: *u8 = &g; let x: u64 = p as u64; }");

  Alcotest.test_case "pointer as usize then i32 is ok" `Quick
    (expect_ok "let mut g: u8; fn f() { let p: *u8 = &g; let x: i32 = (p as usize) as i32; }");

  (* -- match on primitive types (GitHub issue #151) ------------------- *)

  Alcotest.test_case "int match with literals and wildcard type-checks" `Quick
    (expect_ok
      "fn f(v: i32) { match v {
         0 => { let x: i32 = 0; }
         1 => { let y: i32 = 1; }
         -1 => { let z: i32 = 2; }
         _ => { let w: i32 = 3; } } }");

  Alcotest.test_case "int match without wildcard is a type error" `Quick
    (expect_type_error "match on a primitive integer type requires a '_' wildcard arm"
      "fn f(v: i32) { match v { 0 => { let x = 0; } } }");

  Alcotest.test_case "int match with duplicate literal is a type error" `Quick
    (expect_type_error "duplicate match arm literal '0'"
      "fn f(v: i32) { match v {
         0 => { let x = 0; }
         0 => { let y = 1; }
         _ => { let z = 2; } } }");

  Alcotest.test_case "int match literal out of range for u8 is a type error" `Quick
    (expect_type_error "match arm literal 300 does not fit type 'u8'"
      "fn f(v: u8) { match v { 300 => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "int match literal within refined base but outside proven range type-checks" `Quick
    (expect_ok
      (* {0..<4 as u8}'s base is u8 (0..255): a literal outside the proven
         {0..<4} range but inside u8's own width is accepted -- the
         mandatory `_` arm is exactly what covers it, not a narrower
         per-refinement literal-range check. *)
      "fn f(v: {0..<4 as u8}) { match v {
         0 => { let x: i32 = 0; }
         200 => { let y: i32 = 1; }
         _ => { let z: i32 = 2; } } }");

  Alcotest.test_case "int match literal out of range for refined u8 base is a type error" `Quick
    (expect_type_error "match arm literal 300 does not fit type 'u8'"
      "fn f(v: {0..<4 as u8}) { match v { 300 => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "variant-arm syntax against a primitive int discriminant is a type error" `Quick
    (expect_type_error "cannot be used against a primitive integer discriminant"
      "variant Foo { Bar; }
       fn f(v: i32) { match v { Foo::Bar => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "literal arm against an enum discriminant is a type error" `Quick
    (expect_type_error "cannot be used against enum discriminant"
      "enum Color: u8 { Red = 0; }
       fn f(c: Color) { match c { 0 => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "literal arm against a variant discriminant is a type error" `Quick
    (expect_type_error "cannot be used against variant discriminant"
      "variant Foo { Bar; }
       fn f() { match (Foo::Bar) { 0 => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "int match codegen produces valid IR" `Quick
    (expect_codegen_ok
      "fn match_int_lit_codegen_test(v: i32) i32 {
         match v {
           0 => { return 100; }
           1 => { return 101; }
           -1 => { return 102; }
           _ => { return 999; }
         }
       }");

  (* GitHub issue #209: an enum-typed STRUCT FIELD reached through a
     pointer to that struct (an array element here) used to yield the
     field POINTER typed as the enum itself, so `match` emitted
     `switch ptr` and `== Enum::Variant` emitted a pointer-vs-integer
     icmp -- both rejected by LLVM's verifier, crashing the compiler.
     A plain `return` of the same field always worked (the return path
     loads through the pointer), which is what kept this hidden. *)
  Alcotest.test_case "enum struct field read through an array element codegens as a load" `Quick
    (expect_codegen_ok
      "enum Color: u8 { Red; Green; Blue; }
       struct Item { tag: Color; value: usize; }
       const ITEM_MAX: usize = 4;
       let mut enum_field_items: [Item; ITEM_MAX];
       fn enum_field_match(slot: {0..<ITEM_MAX as usize}) -> usize {
         match enum_field_items[slot].tag {
           Color::Red => { return 0; }
           Color::Green => { return 1; }
           Color::Blue => { return 2; }
         }
       }
       fn enum_field_compare(slot: {0..<ITEM_MAX as usize}) -> bool {
         return enum_field_items[slot].tag == Color::Red;
       }");

  (* -- OR-pattern match arms (GitHub issue #156) ---------------------- *)

  Alcotest.test_case "int match OR-pattern arm type-checks, positive and negative mixed" `Quick
    (expect_ok
      "fn f(v: i32) { match v {
         1 | 2 | 3 => { let x: i32 = 0; }
         10 | -1 => { let y: i32 = 1; }
         _ => { let z: i32 = 2; } } }");

  Alcotest.test_case "int match OR-pattern arm with a literal repeated within itself is a type error" `Quick
    (expect_type_error "duplicate match arm literal '2'"
      "fn f(v: i32) { match v { 1 | 2 | 2 => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "int match OR-pattern arm sharing a literal with a later arm is a type error" `Quick
    (expect_type_error "duplicate match arm literal '3'"
      "fn f(v: i32) { match v {
         1 | 2 | 3 => { let x = 0; }
         3 => { let y = 1; }
         _ => { let z = 2; } } }");

  Alcotest.test_case "int match OR-pattern literal out of range for u8 is a type error" `Quick
    (expect_type_error "match arm literal 300 does not fit type 'u8'"
      "fn f(v: u8) { match v { 1 | 300 => { let x = 0; } _ => { let y = 1; } } }");

  Alcotest.test_case "int match OR-pattern codegen produces valid IR" `Quick
    (expect_codegen_ok
      "fn match_int_lit_or_codegen_test(v: i32) i32 {
         match v {
           1 | 2 | 3 => { return 100; }
           10 | -1 => { return 200; }
           _ => { return 999; }
         }
       }");

  (* -- Global let/let mut mutability ------------------------------------- *)

  Alcotest.test_case "reassigning an immutable global is a type error" `Quick
    (expect_type_error "cannot assign to immutable variable"
       "let N: i32 = 4; fn f() { N = 5; }");

  Alcotest.test_case "taking the address of an immutable global is a type error" `Quick
    (expect_type_error "cannot take address of immutable variable"
       "let N: i32 = 4; fn f() { let p: *i32 = &N; }");

  Alcotest.test_case "immutable global without an initializer is a type error" `Quick
    (expect_type_error "must have an initializer"
       "let N: i32;");

  Alcotest.test_case "mutable global can be reassigned" `Quick
    (expect_ok "let mut g: i32 = 0; fn f() { g = 5; }");

  Alcotest.test_case "mutable global can have its address taken" `Quick
    (expect_ok "let mut g: i32 = 0; fn f() { let p: *i32 = &g; }");

  Alcotest.test_case "array size via named constant type-checks like a literal" `Quick
    (expect_ok "const QUEUE_SIZE: i32 = 4;
                let mut ring: [u8; QUEUE_SIZE];
                fn f() { ring[3] = 1; }");

  Alcotest.test_case "array size via named constant still bounds-checks" `Quick
    (expect_type_error "out of bounds"
       "const QUEUE_SIZE: i32 = 4;
        let mut ring: [u8; QUEUE_SIZE];
        fn f() { ring[4] = 1; }");

  (* -- sizeof ------------------------------------------------------------ *)

  (* GitHub issue #77: sizeof(T) is genuinely target-independent for a
     primitive fixed-width type (i32 is always 4 bytes on every target
     this compiler supports), so it now carries that value as a refined
     singleton range rather than a bare usize -- this is what lets it
     survive being threaded through a let/global and still prove a
     subslice bound later, instead of the compiler forgetting it was ever
     a compile-time constant. See "sizeof(non-packed struct) still has
     type usize" below for the case that deliberately keeps the old,
     unrefined behavior (the value there genuinely depends on target
     DataLayout). *)
  Alcotest.test_case "sizeof(T) of a primitive type is a refined usize singleton" `Quick (fun () ->
    let pt = infer "fn f() { let n: usize = sizeof(i32); }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "n has type {4..<5} (usize-based)"
      (Ast.TypeRefined (4, 5, Ast.TypeUsize))
      (Types.StringMap.find "n" fi.Types.local_types)
  );

  Alcotest.test_case "sizeof(non-packed struct) still has type usize" `Quick (fun () ->
    (* Ordinary (non-packed) struct layout depends on target-specific
       alignment/padding, which type inference cannot know (no target is
       set up yet at this stage) -- so this deliberately stays unrefined,
       matching the pre-#77 behavior exactly for this case. *)
    let pt = infer "struct Hdr { a: i32; b: i16; }
                    fn f() { let n: usize = sizeof(Hdr); }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "n has type usize"
      Ast.TypeUsize
      (Types.StringMap.find "n" fi.Types.local_types)
  );

  Alcotest.test_case "sizeof(packed struct) is a refined usize singleton" `Quick (fun () ->
    let pt = infer "struct packed Hdr { a: u8; b: u8; c: u16; }
                    fn f() { let n: usize = sizeof(Hdr); }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "n has type {4..<5} (usize-based)"
      (Ast.TypeRefined (4, 5, Ast.TypeUsize))
      (Types.StringMap.find "n" fi.Types.local_types)
  );

  Alcotest.test_case "sizeof(packed struct align(N)) still has type usize" `Quick (fun () ->
    (* align(N) tail padding is deliberately out of scope for this fix
       (see const_type_size's comment in lib/type_inf.ml) -- stays
       unrefined even though the struct itself is packed. *)
    let pt = infer "struct packed Hdr align(16) { a: u8; b: u8; }
                    fn f() { let n: usize = sizeof(Hdr); }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "n has type usize"
      Ast.TypeUsize
      (Types.StringMap.find "n" fi.Types.local_types)
  );

  Alcotest.test_case "offsetof(packed struct, field) is a refined usize singleton" `Quick (fun () ->
    let pt = infer "struct packed Hdr { tag: u8; value: i32; }
                    fn f() { let n: usize = offsetof(Hdr, value); }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "n has type {1..<2} (usize-based)"
      (Ast.TypeRefined (1, 2, Ast.TypeUsize))
      (Types.StringMap.find "n" fi.Types.local_types)
  );

  Alcotest.test_case "sizeof(StructName) type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn f() { let n: usize = sizeof(Point); }");

  Alcotest.test_case "sizeof of an unknown struct name is a type error" `Quick
    (expect_type_error "unknown type"
       "fn f() { let n: usize = sizeof(Bogus); }");

  Alcotest.test_case "sizeof(T) compared directly against an i32 is a type error" `Quick
    (expect_type_error "cannot unify"
       "struct Hdr { a: i32; b: i32; }
        fn f(len: i32) i32 { if (len >= sizeof(Hdr)) { return 1; } return 0; }");

  Alcotest.test_case "sizeof(T) compared against an explicitly-cast i32 length type-checks" `Quick
    (expect_ok "struct Hdr { a: i32; b: i32; }
                fn f(len: i32) i32 { if ((len as usize) >= sizeof(Hdr)) { return 1; } return 0; }");

  Alcotest.test_case "sizeof(T) compared against a usize length type-checks" `Quick
    (expect_ok "struct Hdr { a: i32; b: i32; }
                fn f(len: usize) i32 { if (len >= sizeof(Hdr)) { return 1; } return 0; }");

  Alcotest.test_case "offsetof(T, field) has type usize" `Quick
    (expect_ok "struct OffsetPoint { x: u8; y: i32; }
                fn offset_type() { let n: usize = offsetof(OffsetPoint, y); }");

  Alcotest.test_case "offsetof rejects an unknown struct" `Quick
    (expect_type_error "unknown struct"
       "fn offset_unknown_struct() { let n: usize = offsetof(Bogus, x); }");

  Alcotest.test_case "offsetof rejects an unknown field" `Quick
    (expect_type_error "unknown field"
       "struct OffsetKnown { x: i32; }
        fn offset_unknown_field() { let n: usize = offsetof(OffsetKnown, y); }");

  Alcotest.test_case "offsetof rejects a non-struct type" `Quick
    (expect_type_error "requires a named struct"
       "fn offset_non_struct() { let n: usize = offsetof(i32, x); }");

  Alcotest.test_case "overload resolution requires an exact inferred argument type" `Quick
    (expect_ok
       "fn overload_exact(v: i32) -> i32 { return v; }
        fn overload_exact(v: u32) -> u32 { return v; }
        fn overload_exact_use(a: i32, b: u32) -> i32 {
          return overload_exact(a) + (overload_exact(b) as i32);
        }");

  Alcotest.test_case "an unconstrained literal does not acquire a default type during overload resolution" `Quick
    (expect_type_error "argument type is not determined"
       "fn overload_no_default(v: i32) -> i32 { return v; }
        fn overload_no_default(v: u32) -> u32 { return v; }
        fn overload_no_default_use() -> i32 { return overload_no_default(0); }");

  Alcotest.test_case "duplicate overload signatures are rejected" `Quick
    (expect_type_error "duplicate overload"
       "fn overload_duplicate(v: i32) {}
        fn overload_duplicate(v: i32) {}");

  (* GitHub issue #79 follow-up: two DIFFERENT files defining the exact
     same signature under the same name used to compile silently (the
     first one in concatenation order silently won, the second was
     dead-coded with no verifier error -- see HISTORY.md's issue #79
     follow-up entry for the real bug this let slip through, found in
     examples/common_qemu/gic.tkb vs examples/common_stm32/nvic.tkb both
     defining irq_uart_rx_setup/irq_uart_rx_unmask). register_definition's
     same-file-only guard is what let this through; the fix widens it to
     any two files. *)
  Alcotest.test_case
    "duplicate function definitions across TWO DIFFERENT files are \
     rejected too, not just within the same file (regression for the \
     real gic.tkb/nvic.tkb collision -- see HISTORY.md's issue #79 \
     follow-up)" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "fn cross_file_dup(v: i32) {}";
         "b.tkb", "fn cross_file_dup(v: i32) {}";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions the FIRST file" true
             (contains_substring msg "a.tkb");
           Alcotest.(check bool) "mentions 'duplicate definition'" true
             (contains_substring msg "duplicate definition"));

  Alcotest.test_case
    "genuinely different signatures across two files are still a valid \
     overload set, not a false-positive duplicate (negative control for \
     the cross-file duplicate check above)" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "fn cross_file_overload(v: i32) -> i32 { return v; }";
         "b.tkb", "fn cross_file_overload(v: u32) -> u32 { return v; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf "expected this to type-check as two overloads, got: %s" msg);

  (* GitHub issue #79 follow-up, same session, reported and fixed right
     after the function case above: two global `let`s sharing a name used
     to compile silently too, and broke differently from the function
     case -- LLVM's define_global doesn't silently reuse the existing
     global the way declare_func's Hashtbl guard did, it auto-renames the
     second one ("name.1" at the IR level), so the two initializers ended
     up in genuinely separate storage, with the FIRST one's silently
     orphaned (never read from) and only the SECOND live under a mangled
     name -- confirmed by disassembling a throwaway two-`let` example
     before writing this fix, not assumed. Found examples/tcp_echo/
     tcp_echo.tkb and examples/http_server/http_server.tkb had exactly
     this: hand-maintained IP_TOTAL_LEN/TCP_*/ARP_* offset constants that
     had been silently redundant with examples/common/netutil.tkb's own
     offsetof-based versions of the same names ever since GitHub issue
     #77's refactor added them there -- removed as dead duplication once
     this check caught it. *)
  Alcotest.test_case
    "duplicate global `let` declarations are rejected (regression for \
     the real tcp_echo.tkb/http_server.tkb redundant-offset-constant bug \
     this check caught -- see HISTORY.md's issue #79 follow-up)" `Quick
    (expect_type_error "already defined as a global"
       "let mut global_dup_counter: i32 = 1;
        let mut global_dup_counter: i32 = 2;
        fn use_global_dup_counter() { global_dup_counter = global_dup_counter + 1; }");

  Alcotest.test_case
    "two DIFFERENTLY-named globals are unaffected by the duplicate-global \
     check (negative control)" `Quick
    (fun () ->
       match infer
         "let mut global_a: i32 = 1;
          let mut global_b: i32 = 2;
          fn use_globals() { global_a = global_b; }"
       with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf "expected this to type-check cleanly, got: %s" msg);

  (* Session follow-up to the two checks above: Takibi deliberately has
     ONE flat namespace for every top-level name (functions and globals
     alike), matching how C has no separate namespace for them either --
     a `let` global and a `fn` sharing a name is rejected regardless of
     which one appears first in source order. The reported "already
     defined as a <kind>" names whichever kind was seen FIRST in program
     order (claim_toplevel_name's single linear pass), so which exact
     message appears depends on ordering even though both orderings are
     equally rejected. See HISTORY.md's issue #79 follow-up. *)
  Alcotest.test_case
    "a global `let` sharing a name with an already-defined `fn` is \
     rejected (let AFTER fn)" `Quick
    (expect_type_error "already defined as a function"
       "fn ns_collide_a() {}
        let mut ns_collide_a: i32 = 1;
        fn use_ns_collide_a() { ns_collide_a = 2; }");

  Alcotest.test_case
    "a `fn` sharing a name with an already-defined global `let` is \
     rejected too (fn AFTER let -- the other ordering)" `Quick
    (expect_type_error "already defined as a global"
       "let mut ns_collide_b: i32 = 1;
        fn ns_collide_b() {}
        fn use_ns_collide_b() { ns_collide_b = 2; }");

  (* GitHub issue #79 follow-up, same session: the struct/enum gap found
     immediately after the two fixes above, closed by the SAME
     claim_toplevel_name mechanism rather than two more one-off checks
     (see infer_program's own header comment for why a shared mechanism
     was chosen at this point instead). Confirmed with a throwaway
     example per combination before writing these, not assumed:
     struct/struct, enum/enum, struct/fn, struct/enum, struct/global,
     opaque-struct/struct, opaque-struct/fn, enum/fn, enum/global all
     rejected; a valid function overload and two differently-named
     structs both still compile clean (not tested standalone here --
     already covered by existing overload/struct tests elsewhere in this
     file; these tests only cover the NEW cross-kind combinations). *)
  Alcotest.test_case "duplicate struct definitions are rejected" `Quick
    (expect_type_error "already defined as a struct"
       "struct NsStructDup { x: i32; }
        struct NsStructDup { y: i32; }
        fn use_ns_struct_dup() {}");

  Alcotest.test_case "duplicate enum definitions are rejected" `Quick
    (expect_type_error "already defined as an enum"
       "enum NsEnumDup: u8 { A; }
        enum NsEnumDup: u8 { B; }
        fn use_ns_enum_dup() {}");

  Alcotest.test_case
    "a struct and a function sharing a name are rejected (cross-kind, \
     not just same-kind duplicates)" `Quick
    (expect_type_error "already defined as a struct"
       "struct NsStructFn { x: i32; }
        fn NsStructFn() {}
        fn use_ns_struct_fn() {}");

  Alcotest.test_case
    "a struct and an enum sharing a name are rejected (cross-kind)" `Quick
    (expect_type_error "already defined as a struct"
       "struct NsStructEnum { x: i32; }
        enum NsStructEnum: u8 { A; }
        fn use_ns_struct_enum() {}");

  Alcotest.test_case
    "an opaque struct and a concrete struct sharing a name are rejected \
     (opaque structs share the struct namespace, not a separate one)" `Quick
    (expect_type_error "already defined as a struct"
       "opaque struct NsOpaqueStruct;
        struct NsOpaqueStruct { x: i32; }
        fn use_ns_opaque_struct(p: *NsOpaqueStruct) {}");

  (* GitHub issue #108: `private let` restricts a global to references from
     its own declaring file. Discovered via examples/common/http_server_common.tkb's
     conn_state et al -- see HISTORY.md's issue #117 follow-up entry. *)
  Alcotest.test_case
    "private global: read from the SAME file it was declared in is fine" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "private let mut priv_g: i32 = 0;
                   fn a_reads() -> i32 { return priv_g; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf "expected same-file read to type-check, got: %s" msg);

  Alcotest.test_case
    "private global: write from the SAME file it was declared in is fine" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "private let mut priv_g: i32 = 0;
                   fn a_writes() { priv_g = 5; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf "expected same-file write to type-check, got: %s" msg);

  Alcotest.test_case
    "private global: reading it (Var) from a DIFFERENT file is a compile error" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "private let mut priv_g: i32 = 0;";
         "b.tkb", "fn b_reads() -> i32 { return priv_g; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions the global's name" true
             (contains_substring msg "priv_g");
           Alcotest.(check bool) "mentions the declaring file" true
             (contains_substring msg "a.tkb"));

  Alcotest.test_case
    "private global: writing it (Assign) from a DIFFERENT file is a compile error" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "private let mut priv_g: i32 = 0;";
         "b.tkb", "fn b_writes() { priv_g = 1; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions the global's name" true
             (contains_substring msg "priv_g"));

  Alcotest.test_case
    "private global: indexing it (arr[i]) from a DIFFERENT file is a compile error" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "private let mut priv_arr: [u8; 4];";
         "b.tkb", "fn b_indexes() -> u8 { return priv_arr[0]; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions the global's name" true
             (contains_substring msg "priv_arr"));

  Alcotest.test_case
    "private global: taking its address (&x) from a DIFFERENT file is a compile error" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "private let mut priv_g: i32 = 0;";
         "b.tkb", "fn b_addr() -> *i32 { return &priv_g; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions the global's name" true
             (contains_substring msg "priv_g"));

  Alcotest.test_case
    "negative control: a NON-private global is still freely readable/writable \
     across files (private is opt-in, not a default restriction)" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "let mut plain_g: i32 = 0;";
         "b.tkb", "fn b_touches() { plain_g = plain_g + 1; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf "expected a non-private global to stay unrestricted, got: %s" msg);

  (* GitHub issue #214: a same-named parameter in a different file must
     shadow a private global, not be misidentified as a reference to it.
     Minimal repro is the linux_user/freelist_generic/ case that hit this
     twice (a `backing` and a `core` parameter each colliding with an
     unrelated file's `private let` of the same name). *)
  Alcotest.test_case
    "private global: a same-named PARAMETER in a different file shadows it \
     rather than triggering the privacy check (issue #214)" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "fn a_takes(backing: i32) -> i32 { return backing; }";
         "b.tkb", "private let mut backing: i32 = 7;
                   fn b_calls() -> i32 { return a_takes(backing); }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf
             "expected the parameter to shadow the unrelated private global, got: %s" msg);

  Alcotest.test_case
    "private global: a same-named LOCAL LET in a different file shadows it \
     rather than triggering the privacy check (issue #214)" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "fn a_shadows() -> i32 { let backing: i32 = 9; return backing; }";
         "b.tkb", "private let mut backing: i32 = 7;
                   fn b_unrelated() -> i32 { return backing; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) ->
           Alcotest.failf
             "expected the local let to shadow the unrelated private global, got: %s" msg);

  Alcotest.test_case
    "private global: a same-named parameter in the SAME file as the \
     declaration does not mask a genuine cross-file violation elsewhere \
     (issue #214 does not weaken the original check)" `Quick
    (fun () ->
       match infer_files [
         "a.tkb", "fn a_shadows(backing: i32) -> i32 { return backing; }";
         "b.tkb", "private let mut backing: i32 = 7;
                   fn b_reads_directly() -> i32 { return backing; }";
         "c.tkb", "fn c_reads() -> i32 { return backing; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions the global's name" true
             (contains_substring msg "backing"));

  (* -- Linear kind (OWNERSHIP_KERNEL.md Stage 1, GitHub issue #117) -------
     `linear opaque struct` = exactly-once-on-every-path obligations.
     Prelude shared by most cases below: a token type, a mint, a sink. *)

  Alcotest.test_case "linear: create + sink on the straight-line path is fine" `Quick
    (fun () ->
       match infer "linear opaque struct LinTok;
                    fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
                    fn lsink(t: sink *LinTok) {}
                    fn lin_ok() { let t: *LinTok = lmint(); lsink(t); }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "linear: consuming on BOTH branches of an if/else is fine \
                      (branching around a linear value is legal)" `Quick
    (fun () ->
       match infer "linear opaque struct LinTok;
                    fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
                    fn lsink_a(t: sink *LinTok) {}
                    fn lsink_b(t: sink *LinTok) {}
                    fn lin_both(c: bool) {
                      let t: *LinTok = lmint();
                      if (c) { lsink_a(t); } else { lsink_b(t); }
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "linear: never consumed is a compile error" `Quick
    (expect_type_error "linear value 't' is never consumed"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lin_leak() { let t: *LinTok = lmint(); }");

  Alcotest.test_case "linear: consumed in only ONE branch is a compile error \
                      (linear forbids weakening)" `Quick
    (expect_type_error "consumed on some paths but not on every path"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_missed(c: bool) {
          let t: *LinTok = lmint();
          if (c) { lsink(t); }
        }");

  Alcotest.test_case "negative control: one-branch affine consumption compiles \
                      because affine permits weakening" `Quick
    (fun () ->
       match infer "affine opaque struct AffTok2;
                    fn amint2() -> *AffTok2 { return 0 as usize as *AffTok2; }
                    fn asink2(t: sink *AffTok2) {}
                    fn aff_missed(c: bool) {
                      let t: *AffTok2 = amint2();
                      if (c) { asink2(t); }
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "linear: casting a linear value away is a compile error" `Quick
    (expect_type_error "cannot cast an affine/linear value"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lin_cast() { let t: *LinTok = lmint(); let x: usize = t as usize; }");

  Alcotest.test_case "linear: assigning over an undischarged obligation is a \
                      compile error" `Quick
    (expect_type_error "would discard its obligation"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_overwrite() {
          let mut t: *LinTok = lmint();
          t = lmint();
          lsink(t);
        }");

  Alcotest.test_case "linear: a discharged binding may be reinitialized" `Quick
    (expect_ok
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_reinit() {
          let mut t: *LinTok = lmint();
          lsink(t);
          t = lmint();
          lsink(t);
        }");

  Alcotest.test_case "linear: the self-transform idiom `t = transform(t)` is \
                      fine (RHS consumes the old obligation first)" `Quick
    (fun () ->
       match infer "linear opaque struct LinTok;
                    fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
                    fn ltransform(t: *LinTok) -> *LinTok { return t; }
                    fn lsink(t: sink *LinTok) {}
                    fn lin_transform() {
                      let mut t: *LinTok = lmint();
                      t = ltransform(t);
                      lsink(t);
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "linear: an uninitialized linear let is a compile error" `Quick
    (expect_type_error "must be initialized at its declaration"
       "linear opaque struct LinTok;
        fn lin_uninit() { let mut t: *LinTok; }");

  Alcotest.test_case "linear: a pending obligation at an early return is a \
                      compile error" `Quick
    (expect_type_error "still pending at this return"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_early(c: bool) -> i32 {
          let t: *LinTok = lmint();
          if (c) { return -1; }
          lsink(t);
          return 0;
        }");

  Alcotest.test_case "linear: a pending obligation at a break is a compile error" `Quick
    (expect_type_error "still pending at this break"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_break() {
          while (true) {
            let t: *LinTok = lmint();
            break;
          }
        }");

  Alcotest.test_case "linear: returning the obligation itself IS consumption \
                      (return-forward compiles)" `Quick
    (fun () ->
       match infer "linear opaque struct LinTok;
                    fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
                    fn lin_forward() -> *LinTok {
                      let t: *LinTok = lmint();
                      return t;
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "linear: a plain linear parameter consumed on only some \
                      paths is a compile error" `Quick
    (expect_type_error "still pending at this return"
       "linear opaque struct LinTok;
        fn lsink(t: sink *LinTok) {}
        fn lin_param(c: bool, t: *LinTok) -> i32 {
          if (c) { return -1; }
          lsink(t);
          return 0;
        }");

  Alcotest.test_case "linear: a plain linear parameter never consumed at all is \
                      a compile error (fall-through path)" `Quick
    (expect_type_error "linear parameter 't' is not consumed on every path"
       "linear opaque struct LinTok;
        fn lin_swallow(t: *LinTok) {}");

  Alcotest.test_case "linear: a sink parameter needs no further forwarding \
                      (terminal consumer compiles)" `Quick
    (fun () ->
       match infer "linear opaque struct LinTok;
                    fn lin_terminal(t: sink *LinTok) {}" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "linear: double consume is a compile error" `Quick
    (expect_type_error "linear value 't' was already consumed"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_double() {
          let t: *LinTok = lmint();
          lsink(t);
          lsink(t);
        }");

  Alcotest.test_case "linear: taking the address of a linear value is a \
                      compile error" `Quick
    (expect_type_error "cannot take the address of linear value"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lsink(t: sink *LinTok) {}
        fn lin_addr() {
          let mut t: *LinTok = lmint();
          let p: usize = (&t) as usize;
          lsink(t);
        }");

  Alcotest.test_case "linear: storing into a struct field is rejected at the \
                      field declaration" `Quick
    (expect_type_error "cannot hold a linear value"
       "linear opaque struct LinTok;
        struct LinHolder { tok: *LinTok; }");

  Alcotest.test_case "linear: an array of linear values is rejected" `Quick
    (expect_type_error "cannot live inside an array/slice"
       "linear opaque struct LinTok;
        fn lin_arr() { let mut a: [*LinTok; 2]; }");

  Alcotest.test_case "linear: a linear-typed global is rejected" `Quick
    (expect_type_error "cannot hold a linear value"
       "linear opaque struct LinTok;
        let mut g_tok: *LinTok = 0 as usize as *LinTok;");

  (* A linear value's own runtime representation IS a pointer, *LinTok, so
     "a pointer to a slot holding a linear value" is inherently **LinTok --
     there is no other way to express this scenario. Before GitHub issue
     #239, this was caught by the linear-value-through-a-pointer check
     ("cannot store a linear value through a pointer"). #239 now rejects
     the `pp: **LinTok` parameter type itself, unconditionally, before the
     function body is analyzed, which also means the underlying danger
     (aliasing/overwriting a linear value through an indirect pointer) is
     now structurally unreachable, not merely rejected at the store site. *)
  Alcotest.test_case "linear: storing through a pointer is a compile error" `Quick
    (expect_type_error "nested pointer indirection"
       "linear opaque struct LinTok;
        fn lmint() -> *LinTok { return 0 as usize as *LinTok; }
        fn lin_store(pp: **LinTok) {
          let t: *LinTok = lmint();
          *pp = t;
        }");

  (* -- Stage 2 (OWNERSHIP_KERNEL.md, GitHub issues #108/#15) --------------
     private opaque types (construction is declaring-file-only), private
     struct fields, opaque pointer arithmetic ban, affine ptr-laundering
     unsafe gate. *)

  Alcotest.test_case "private type: minting in the declaring file is fine" `Quick
    (fun () ->
       match infer_files [
         "seal.tkb", "private affine opaque struct SealTok;
                      fn seal_mint() -> *SealTok { return 0 as usize as *SealTok; }
                      fn seal_sink(t: sink *SealTok) {}";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "private type: minting from ANOTHER file is a compile error" `Quick
    (fun () ->
       match infer_files [
         "seal.tkb", "private affine opaque struct SealTok;
                      fn seal_sink(t: sink *SealTok) {}";
         "b.tkb", "fn forge() { let t: *SealTok = 0 as usize as *SealTok; seal_sink(t); }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "names the type" true
             (contains_substring msg "private type 'SealTok'"));

  Alcotest.test_case "private type: NAMING it from another file stays legal \
                      (annotations/pass-through -- only construction is gated)" `Quick
    (fun () ->
       match infer_files [
         "seal.tkb", "private affine opaque struct SealTok;
                      fn seal_mint() -> *SealTok { return 0 as usize as *SealTok; }
                      fn seal_sink(t: sink *SealTok) {}";
         "b.tkb", "fn relay() { let t: *SealTok = seal_mint(); seal_sink(t); }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "private field: same-file access is fine" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }
                        let mut sealed_box: Sealed;
                        fn sealed_get() -> i32 { return sealed_box.inner; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "private field: cross-file READ is a compile error" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }
                        let mut sealed_box: Sealed;";
         "b.tkb", "fn peek() -> i32 { return sealed_box.inner; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "names the field" true
             (contains_substring msg "'Sealed.inner' is private"));

  Alcotest.test_case "private field: cross-file WRITE is a compile error" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }
                        let mut sealed_box: Sealed;";
         "b.tkb", "fn poke() { sealed_box.inner = 42; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "names the field" true
             (contains_substring msg "'Sealed.inner' is private"));

  Alcotest.test_case "private field: cross-file &s.f is a compile error" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }
                        let mut sealed_box: Sealed;";
         "b.tkb", "fn alias() -> *i32 { return &sealed_box.inner; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "names the field" true
             (contains_substring msg "'Sealed.inner' is private"));

  Alcotest.test_case "private field: cross-file offsetof is a compile error" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }";
         "b.tkb", "fn off() -> usize { return offsetof(Sealed, inner); }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "names the field" true
             (contains_substring msg "'Sealed.inner' is private"));

  Alcotest.test_case "private field: cross-file struct LITERAL is a compile error \
                      (smart constructors become real)" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }";
         "b.tkb", "fn forge() { let mut s: Sealed = { 1, 2 }; s.pub_tag = 3; }";
       ] with
       | _ -> Alcotest.fail "expected TypeError, but inference succeeded"
       | exception Types.TypeError (_, msg) ->
           Alcotest.(check bool) "mentions private fields" true
             (contains_substring msg "it has private fields"));

  Alcotest.test_case "private field: a NON-private field of the same struct \
                      stays freely accessible cross-file" `Quick
    (fun () ->
       match infer_files [
         "holder.tkb", "struct Sealed { private inner: i32; pub_tag: i32; }
                        let mut sealed_box: Sealed;";
         "b.tkb", "fn tag() -> i32 { sealed_box.pub_tag = 7; return sealed_box.pub_tag; }";
       ] with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "opaque ptr arithmetic: `t + 1` on an affine handle is a \
                      compile error (kind-duplication hole, user-review probe)" `Quick
    (expect_type_error "pointer arithmetic/indexing on '*ArithTok'"
       "affine opaque struct ArithTok;
        fn amk() -> *ArithTok { return 0 as usize as *ArithTok; }
        fn asnk(t: sink *ArithTok) {}
        fn dup() {
          let t: *ArithTok = amk();
          let q: *ArithTok = t + 1;
          asnk(t);
          asnk(q);
        }");

  Alcotest.test_case "opaque ptr arithmetic: indexing a PLAIN opaque pointer is \
                      a compile error too (was an internal compiler error)" `Quick
    (expect_type_error "pointer arithmetic/indexing on '*Blob'"
       "opaque struct Blob;
        fn blob_peek(p: *Blob) -> i32 { return 0; }
        fn walk(p: *Blob) -> i32 { return blob_peek(p[1]); }");

  Alcotest.test_case "opaque ptr deref: reading through an affine handle is a \
                      compile error (was an internal compiler error, invalid \
                      LLVM IR load of an opaque type)" `Quick
    (expect_type_error "cannot dereference '*Lease'"
       "affine opaque struct Lease;
        fn acquire() -> *Lease { return 0 as usize as *Lease; }
        fn f() { let t: *Lease = acquire(); let x = *t; }");

  Alcotest.test_case "opaque ptr deref: writing through an affine handle is a \
                      compile error too (was also an internal compiler error)" `Quick
    (expect_type_error "cannot dereference '*Lease'"
       "affine opaque struct Lease;
        fn acquire() -> *Lease { return 0 as usize as *Lease; }
        fn f() { let t: *Lease = acquire(); *t = *t; }");

  Alcotest.test_case "opaque ptr deref: reading through a PLAIN opaque pointer \
                      is a compile error too" `Quick
    (expect_type_error "cannot dereference '*Blob'"
       "opaque struct Blob;
        fn peek(p: *Blob) -> i32 { let x = *p; return 0; }");

  Alcotest.test_case "affine ptr laundering: `t as *Other` without unsafe is a \
                      compile error" `Quick
    (expect_type_error "cannot cast an affine/linear value"
       "affine opaque struct LaunTok;
        opaque struct OtherBlob;
        fn lmk() -> *LaunTok { return 0 as usize as *LaunTok; }
        fn lsnk(t: sink *LaunTok) {}
        fn launder() {
          let t: *LaunTok = lmk();
          let o: *OtherBlob = t as *OtherBlob;
          lsnk(t);
        }");

  Alcotest.test_case "affine ptr laundering remains illegal inside unsafe" `Quick
    (expect_type_error "cannot cast an affine/linear value"
       "affine opaque struct LaunTok2;
        opaque struct OtherBlob2;
        fn lmk2() -> *LaunTok2 { return 0 as usize as *LaunTok2; }
        fn launder2() {
          let t: *LaunTok2 = lmk2();
          let o: *OtherBlob2 = unsafe { t as *OtherBlob2 };
        }");

  Alcotest.test_case "an affine handle cannot be cast to usize" `Quick
    (expect_type_error "cannot cast an affine/linear value"
       "affine opaque struct NullTok;
        fn nmk() -> *NullTok { return 0 as usize as *NullTok; }
        fn nullcheck() {
          let t: *NullTok = nmk();
          let raw: usize = t as usize;
        }");

  (* -- Tuples (OWNERSHIP_KERNEL.md 5.9, GitHub issue #120) ----------------
     Function-local product values; join-kind semantics; destructuring is
     the only elimination; banned from all storage and casts. *)

  Alcotest.test_case "tuple: a plain (unrestricted) tuple return + destructure \
                      compiles and needs no consumption" `Quick
    (fun () ->
       match infer "fn make_pair() -> (i32, i32) { return (1, 2); }
                    fn use_pair() -> i32 {
                      let (a, b) = make_pair();
                      return a + b;
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "tuple: (data, linear-obligation) pair returned, \
                      destructured, and the obligation consumed -- the \
                      motivating shape for this issue" `Quick
    (fun () ->
       match infer "linear opaque struct TupOb;
                    fn tmint() -> *TupOb { return 0 as usize as *TupOb; }
                    fn tsnk(t: sink *TupOb) {}
                    fn make_pair() -> (i32, *TupOb) { return (42, tmint()); }
                    fn use_pair() {
                      let (n, t) = make_pair();
                      tsnk(t);
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "tuple join-kind: a tuple containing a linear component \
                      IS linear -- never consuming it is a compile error" `Quick
    (expect_type_error "linear value 'p' is still pending"
       "linear opaque struct TupOb2;
        fn tmint2() -> *TupOb2 { return 0 as usize as *TupOb2; }
        fn leak() -> i32 {
          let p: (i32, *TupOb2) = (1, tmint2());
        return 0;
        }");

  Alcotest.test_case "tuple: direct linear variant and owner may return together" `Quick
    (expect_ok
       "linear struct TupleVacancy2a[n: usize] { value: usize @ n; }
        variant TupleState2a { Empty; Full(i32); }
        fn tuple_take2a(tag: usize @ n)
            -> (TupleState2a, TupleVacancy2a[n]) {
          let mut vacancy: TupleVacancy2a[n] = { tag };
          return (TupleState2a::Empty, vacancy);
        }
        fn tuple_vacancy_done2a(v: sink TupleVacancy2a[n]) {}
        fn tuple_use2a(tag: usize @ n) {
          let (state, vacancy) = tuple_take2a(tag);
          match state {
            TupleState2a::Empty => {}
            TupleState2a::Full(value) => {}
          }
          tuple_vacancy_done2a(vacancy);
        }");

  Alcotest.test_case "tuple join-kind: consuming the tuple on only ONE branch \
                      is a compile error (inherits linear's all-paths rule)" `Quick
    (expect_type_error "consumed on some paths but not on every path"
       "linear opaque struct TupOb3;
        fn tmint3() -> *TupOb3 { return 0 as usize as *TupOb3; }
        fn tsnk3(t: sink *TupOb3) {}
        fn use_pair(c: bool, x: i32) {
          let p: (i32, *TupOb3) = (x, tmint3());
          if (c) {
            let (n, t) = p;
            tsnk3(t);
          }
        }");

  Alcotest.test_case "tuple join-kind: a discarded tuple literal consumes \
                      nothing that flows past it -- an unconsumed component \
                      is still caught at the LOCAL that captured it" `Quick
    (expect_type_error "linear value 'p' is still pending"
       "linear opaque struct TupOb4;
        fn tmint4() -> *TupOb4 { return 0 as usize as *TupOb4; }
        fn make_pair4() -> (i32, *TupOb4) { return (1, tmint4()); }
        fn leak4() -> i32 {
          let p: (i32, *TupOb4) = make_pair4();
          return 0;
        }");

  Alcotest.test_case "tuple: a plain (i32, i32) tuple type cannot be cast" `Quick
    (expect_type_error "cannot cast a tuple to anything"
       "fn make_pair5() -> (i32, i32) { return (1, 2); }
        fn app_main() -> i32 {
          let p: (i32, i32) = make_pair5();
          let x: usize = p as usize;
          return 0;
        }");

  Alcotest.test_case "tuple: casting TO a tuple type is a compile error" `Quick
    (expect_type_error "cannot cast to a tuple type"
       "fn app_main() -> i32 {
          let x: i32 = 0;
          let p: (i32, i32) = x as (i32, i32);
          return 0;
        }");

  Alcotest.test_case "tuple: a struct field of tuple type is a compile error" `Quick
    (expect_type_error "cannot hold a tuple"
       "struct BadHolder { pair: (i32, i32); }
        fn app_main() -> i32 { return 0; }");

  Alcotest.test_case "tuple: a global of tuple type is a compile error" `Quick
    (expect_type_error "cannot hold a tuple"
       "let mut g_pair: (i32, i32) = (1, 2);
        fn app_main() -> i32 { return 0; }");

  Alcotest.test_case "tuple: an array of tuples is a compile error \
                      (tuple cannot live behind indirection)" `Quick
    (expect_type_error "tuple cannot live behind a pointer or inside an array/slice"
       "fn app_main() -> i32 {
          let mut a: [(i32, i32); 2];
          return 0;
        }");

  Alcotest.test_case "tuple: a pointer-to-tuple type annotation is a compile \
                      error (tuples cannot live behind indirection)" `Quick
    (expect_type_error "tuple cannot live behind a pointer or inside an array/slice"
       "fn make_pair6() -> (i32, i32) { return (1, 2); }
        fn app_main() -> i32 {
          let mut p: (i32, i32) = make_pair6();
          let pp: *(i32, i32) = &p;
          return 0;
        }");

  Alcotest.test_case "tuple: destructuring arity mismatch is a compile error" `Quick
    (expect_type_error "tuple has 2 components but the pattern binds 3 names"
       "fn make_pair7() -> (i32, i32) { return (1, 2); }
        fn app_main() -> i32 {
          let (a, b, c) = make_pair7();
          return 0;
        }");

  Alcotest.test_case "tuple: destructuring a non-tuple expression is a compile error" `Quick
    (expect_type_error "destructuring `let (...) = ...` needs a tuple right-hand side"
       "fn app_main() -> i32 {
          let (a, b) = 5;
          return 0;
        }");

  Alcotest.test_case "tuple: duplicate names in a destructuring pattern are \
                      a compile error" `Quick
    (expect_type_error "duplicate name 'a' in tuple pattern"
       "fn make_pair8() -> (i32, i32) { return (1, 2); }
        fn app_main() -> i32 {
          let (a, a) = make_pair8();
          return 0;
        }");

  Alcotest.test_case "negative control: `(5)` stays plain parenthesized \
                      grouping, not a 1-tuple (no comma = no tuple)" `Quick
    (fun () ->
       match infer "fn app_main() -> i32 {
                      let x: i32 = (5);
                      return x;
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "tuple: nesting is allowed (uniform recursion)" `Quick
    (fun () ->
       match infer "fn make_nested() -> (i32, (i32, i32)) { return (1, (2, 3)); }
                    fn use_nested() -> i32 {
                      let (a, inner) = make_nested();
                      let (b, c) = inner;
                      return a + b + c;
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  (* -- Stage 3a: path tracking through one-level struct fields
     (OWNERSHIP_KERNEL.md, GitHub issue #89 Hurdle 3) ----------------------
     Before this stage, an affine value stored in a struct field (already
     legal syntax) was completely untracked -- double-consume and
     never-consumed through a field silently compiled. `h.t` is now
     tracked the same way a bare variable `t` is, but ONLY when `h` is a
     bare local/parameter name (no `f().t`, no `arr[i].t` -- those have no
     stable syntactic identity without relational reasoning). *)

  Alcotest.test_case "field path: consuming a field once via a sink call \
                      compiles" `Quick
    (fun () ->
       match infer "affine opaque struct FTok;
                    fn fmk() -> *FTok { return 0 as usize as *FTok; }
                    fn fsnk(t: sink *FTok) {}
                    struct FHolder { t: *FTok; }
                    fn use_field() {
                      let mut h: FHolder;
                      h.t = fmk();
                      fsnk(h.t);
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "field path: double-consuming the SAME field is now a \
                      compile error (the concrete hole this stage closes)" `Quick
    (expect_type_error "affine value 'h.t' was already consumed"
       "affine opaque struct FTok2;
        fn fmk2() -> *FTok2 { return 0 as usize as *FTok2; }
        fn fsnk2(t: sink *FTok2) {}
        struct FHolder2 { t: *FTok2; }
        fn double_consume() {
          let mut h: FHolder2;
          h.t = fmk2();
          fsnk2(h.t);
          fsnk2(h.t);
        }");

  Alcotest.test_case "field path: an affine field may be dropped" `Quick
    (expect_ok
       "affine opaque struct FTok3;
        fn fmk3() -> *FTok3 { return 0 as usize as *FTok3; }
        struct FHolder3 { t: *FTok3; }
        fn leak_field() {
          let mut h: FHolder3;
          h.t = fmk3();
        }");

  Alcotest.test_case "field path: consuming on only ONE branch is fine \
                      (affine keeps its union/at-least-one-path semantics \
                      through fields too)" `Quick
    (fun () ->
       match infer "affine opaque struct FTok4;
                    fn fmk4() -> *FTok4 { return 0 as usize as *FTok4; }
                    fn fsnk4(t: sink *FTok4) {}
                    struct FHolder4 { t: *FTok4; }
                    fn maybe_consume(c: bool) {
                      let mut h: FHolder4;
                      h.t = fmk4();
                      if (c) { fsnk4(h.t); }
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "field path: TWO DIFFERENT struct locals of the same \
                      type are independent paths (no false cross-aliasing)" `Quick
    (fun () ->
       match infer "affine opaque struct FTok5;
                    fn fmk5() -> *FTok5 { return 0 as usize as *FTok5; }
                    fn fsnk5(t: sink *FTok5) {}
                    struct FHolder5 { t: *FTok5; }
                    fn two_holders() {
                      let mut h1: FHolder5;
                      let mut h2: FHolder5;
                      h1.t = fmk5();
                      h2.t = fmk5();
                      fsnk5(h1.t);
                      fsnk5(h2.t);
                    }" with
       | _ -> ()
       | exception Types.TypeError (_, msg) -> Alcotest.failf "expected OK, got: %s" msg);

  Alcotest.test_case "field path: reassigning a field's RHS through another \
                      tracked variable consumes that variable too" `Quick
    (expect_type_error "affine value 'src' was already consumed"
       "affine opaque struct FTok6;
        fn fmk6() -> *FTok6 { return 0 as usize as *FTok6; }
        fn fsnk6(t: sink *FTok6) {}
        struct FHolder6 { t: *FTok6; }
        fn move_into_field() {
          let src: *FTok6 = fmk6();
          let mut h: FHolder6;
          h.t = src;
          fsnk6(src);
          fsnk6(h.t);
        }");

  Alcotest.test_case "field path: returning a plain struct may weaken its affine field" `Quick
    (expect_ok
       "affine opaque struct FTok7;
        fn fmk7() -> *FTok7 { return 0 as usize as *FTok7; }
        struct FHolder7 { t: *FTok7; }
        fn make_holder() -> FHolder7 {
          let mut h: FHolder7;
          h.t = fmk7();
          return h;
        }");

  Alcotest.test_case "negative control: struct fields of LINEAR type stay \
                      banned at declaration (Stage 3a scoped to affine \
                      only -- see OWNERSHIP_KERNEL.md section 6)" `Quick
    (expect_type_error "cannot hold a linear value"
       "linear opaque struct FTok8;
        struct FHolder8 { t: *FTok8; }
        fn app_main() -> i32 { return 0; }");

  (* -- Takibi Core Slice 2: erased affine/linear views -------------------- *)

  Alcotest.test_case "erased view: mint, borrow, and sink compile" `Quick
    (expect_ok
       "private linear view ViewPending1;
        fn view_mint1() -> ViewPending1 { return view ViewPending1; }
        fn view_peek1(p: borrow ViewPending1) {}
        fn view_sink1(p: sink ViewPending1) {}
        fn view_use1() {
          let p: ViewPending1 = view_mint1();
          view_peek1(p);
          view_sink1(p);
        }");

  Alcotest.test_case "erased linear view: both branches may choose different sinks" `Quick
    (expect_ok
       "linear view ViewPending2;
        fn view_mint2() -> ViewPending2 { return view ViewPending2; }
        fn view_sink2a(p: sink ViewPending2) {}
        fn view_sink2b(p: sink ViewPending2) {}
        fn view_use2(c: bool) {
          let p: ViewPending2 = view_mint2();
          if (c) { view_sink2a(p); } else { view_sink2b(p); }
        }");

  Alcotest.test_case "erased linear view: one branch may not forget the obligation" `Quick
    (expect_type_error "consumed on some paths but not on every path"
       "linear view ViewPending3;
        fn view_mint3() -> ViewPending3 { return view ViewPending3; }
        fn view_sink3(p: sink ViewPending3) {}
        fn view_use3(c: bool) {
          let p: ViewPending3 = view_mint3();
          if (c) { view_sink3(p); }
        }");

  Alcotest.test_case "erased view: a producing call result cannot be discarded" `Quick
    (expect_type_error "must be moved into an owning binding or consumer"
       "linear view ViewPending4;
        fn view_mint4() -> ViewPending4 { return view ViewPending4; }
        fn view_discard4() { view_mint4(); }");

  Alcotest.test_case "erased view: casting cannot mint a permission" `Quick
    (expect_type_error "cannot construct erased view 'ViewPending5' with a cast"
       "linear view ViewPending5;
        fn view_sink5(p: sink ViewPending5) {}
        fn view_cast5() {
          let p: ViewPending5 = 0 as ViewPending5;
          view_sink5(p);
        }");

  Alcotest.test_case "erased view: address-of is rejected because there is no storage" `Quick
    (expect_type_error "cannot take the address of erased view"
       "linear view ViewPending6;
        fn view_mint6() -> ViewPending6 { return view ViewPending6; }
        fn view_sink6(p: sink ViewPending6) {}
        fn view_addr6() {
          let mut p: ViewPending6 = view_mint6();
          let raw: usize = (&p) as usize;
          view_sink6(p);
        }");

  Alcotest.test_case "erased view: globals and struct fields cannot store it" `Quick
    (fun () ->
      expect_type_error "global 'view_global7' cannot hold an erased view"
        "linear view ViewPending7;
         let mut view_global7: ViewPending7;" ();
      expect_type_error "struct field 'ViewHolder7.p' cannot hold an erased view"
        "linear view ViewPending7b;
         struct ViewHolder7 { p: ViewPending7b; }" ());

  Alcotest.test_case "erased view: runtime containers and sizeof are rejected" `Quick
    (fun () ->
      expect_type_error "cannot live inside a runtime container"
        "linear view ViewPending8;
         fn view_array8(a: [ViewPending8; 2]) {}" ();
      expect_type_error "has no runtime size or layout"
        "linear view ViewPending8b;
         fn view_size8() -> usize { return sizeof(ViewPending8b); }" ());

  Alcotest.test_case "erased view: runtime comparison is rejected" `Quick
    (expect_type_error "cannot be operands of runtime operators"
       "linear view ViewPending8c;
        fn view_mint8c() -> ViewPending8c { return view ViewPending8c; }
        fn view_sink8c(p: sink ViewPending8c) {}
        fn view_compare8c() -> bool {
          let p: ViewPending8c = view_mint8c();
          let same: bool = p == p;
          view_sink8c(p);
          return same;
        }");

  Alcotest.test_case "erased view: runtime min/max is rejected" `Quick
    (expect_type_error "cannot be operands of runtime min/max"
       "linear view ViewPending8e;
        fn view_mint8e() -> ViewPending8e { return view ViewPending8e; }
        fn view_min8e() {
          let p: ViewPending8e = view_mint8e();
          // Views carry static obligations only, so min cannot inspect one.
          let q = min(p, p);
        }");

  Alcotest.test_case "erased view: a view-taking function is not a runtime function pointer" `Quick
    (expect_type_error "cannot be used as a runtime function pointer"
       "linear view ViewPending8d;
        fn view_sink8d(p: sink ViewPending8d) {}
        fn view_fnptr8d() {
          let f = view_sink8d;
        }");

  Alcotest.test_case "erased view: a local must be initialized" `Quick
    (expect_type_error "must be initialized at its declaration"
       "linear view ViewPending9;
        fn view_uninit9() { let mut p: ViewPending9; }");

  Alcotest.test_case "erased view: a producing function cannot fall through" `Quick
    (expect_type_error "must return explicitly on every path"
       "linear view ViewPending10;
        fn view_missing_return10() -> ViewPending10 {}");

  Alcotest.test_case "private erased view: only its declaring file may mint it" `Quick
    (fun () ->
      match infer_files [
        "view_owner.tkb",
          "private linear view PrivatePending11;
           fn private_sink11(p: sink PrivatePending11) {}";
        "view_forge.tkb",
          "fn private_forge11() {
             let p: PrivatePending11 = view PrivatePending11;
             private_sink11(p);
           }";
      ] with
      | _ -> Alcotest.fail "expected cross-file view minting to fail"
      | exception Types.TypeError (_, msg) ->
          Alcotest.(check bool) "diagnostic names private view" true
            (contains_substring msg "cannot mint private view 'PrivatePending11'"));

  (* -- Takibi Core Slice 3: closed variants and existential opening ------- *)

  Alcotest.test_case "must_use variant: a discarded call result is rejected" `Quick
    (expect_type_error "must-use result of 'must_use_make1' must be handled"
       "must_use variant MustUseStatus1 { Ok; Err(i32); }
        fn must_use_make1() -> MustUseStatus1 {
          return MustUseStatus1::Ok;
        }
        fn must_use_bad1() { must_use_make1(); }");

  Alcotest.test_case "must_use variant: an ignored binding is rejected" `Quick
    (expect_type_error "must-use value 'status' is never handled"
       "must_use variant MustUseStatus2 { Ok; Err(i32); }
        fn must_use_make2() -> MustUseStatus2 {
          return MustUseStatus2::Ok;
        }
        fn must_use_bad2() {
          let status: MustUseStatus2 = must_use_make2();
        }");

  Alcotest.test_case "must_use variant: match handles every result path" `Quick
    (expect_ok
       "must_use variant MustUseStatus3 { Ok; Err(i32); }
        fn must_use_make3() -> MustUseStatus3 {
          return MustUseStatus3::Ok;
        }
        fn must_use_ok3() -> i32 {
          match must_use_make3() {
            MustUseStatus3::Ok => { return 0; }
            MustUseStatus3::Err(err) => { return err; }
          }
        }");

  Alcotest.test_case "must_use variant: handling on only one branch is rejected" `Quick
    (expect_type_error
       "must-use value 'status' is handled on some paths but not on every path"
       "must_use variant MustUseStatus4 { Ok; Err(i32); }
        fn must_use_make4() -> MustUseStatus4 {
          return MustUseStatus4::Ok;
        }
        fn must_use_bad4(c: bool) {
          let status: MustUseStatus4 = must_use_make4();
          if (c) {
            match status {
              MustUseStatus4::Ok => {}
              MustUseStatus4::Err(err) => {}
            }
          }
        }");

  Alcotest.test_case
    "must_use variant: a same-named plain local in another lexical arm is not tracked" `Quick
    (expect_ok
       "must_use variant MustUseStatus5 { Ok; Err(i32); }
        fn must_use_make5() -> MustUseStatus5 {
          return MustUseStatus5::Ok;
        }
        fn must_use_scoped5(tag: i32) -> usize {
          match tag {
            0 => {
              let result: MustUseStatus5 = must_use_make5();
              match result {
                MustUseStatus5::Ok => { return 0; }
                MustUseStatus5::Err(err) => { return 1; }
              }
            }
            _ => {
              let result: usize = 2;
              return result;
            }
          }
        }");

  Alcotest.test_case "Slice 3: an existential indexed owner packs and opens through match" `Quick
    (expect_ok
       "linear struct VariantOwner1[n: usize] {
          idx: {0..<4 as usize} @ n;
        }
        variant VariantMaybe1 {
          None;
          Some(exists n: usize. VariantOwner1[n]);
        }
        fn variant_owner_make1(idx: {0..<4 as usize} @ n) -> VariantOwner1[n] {
          let mut owner: VariantOwner1[n] = { idx };
          return owner;
        }
        fn variant_owner_drop1(owner: sink VariantOwner1[n]) {}
        fn variant_some1(idx: {0..<4 as usize}) -> VariantMaybe1 {
          return VariantMaybe1::Some(variant_owner_make1(idx));
        }
        fn variant_none1() -> VariantMaybe1 { return VariantMaybe1::None; }
        fn variant_use1(value: VariantMaybe1) {
          match value {
            VariantMaybe1::None => {}
            VariantMaybe1::Some(owner) => { variant_owner_drop1(owner); }
          }
        }");

  Alcotest.test_case
    "owner aggregate: a linear tuple with multiple existential owners packs and opens" `Quick
    (expect_ok
       "linear struct AggregateOwner1[n: usize] { id: usize @ n; }
        variant AggregatePair1 {
          Empty;
          Both(exists a: usize. exists b: usize.
               (AggregateOwner1[a], AggregateOwner1[b]));
        }
        fn aggregate_new1(id: usize @ n) -> AggregateOwner1[n] {
          let mut owner: AggregateOwner1[n] = { id };
          return owner;
        }
        fn aggregate_drop1(owner: sink AggregateOwner1[n]) {}
        fn aggregate_pair1(a: usize, b: usize) -> AggregatePair1 {
          return AggregatePair1::Both((aggregate_new1(a), aggregate_new1(b)));
        }
        fn aggregate_use1(pair: AggregatePair1) {
          match pair {
            AggregatePair1::Empty => {}
            AggregatePair1::Both(owners) => {
              let (left, right) = owners;
              aggregate_drop1(left);
              aggregate_drop1(right);
            }
          }
        }");

  Alcotest.test_case
    "owner aggregate: every linear tuple component remains an obligation after match" `Quick
    (expect_type_error "linear value 'right' is never consumed"
       "linear struct AggregateOwner2[n: usize] { id: usize @ n; }
        variant AggregatePair2 {
          Empty;
          Both(exists a: usize. exists b: usize.
               (AggregateOwner2[a], AggregateOwner2[b]));
        }
        fn aggregate_drop2(owner: sink AggregateOwner2[n]) {}
        fn aggregate_bad2(pair: AggregatePair2) {
          match pair {
            AggregatePair2::Empty => {}
            AggregatePair2::Both(owners) => {
              let (left, right) = owners;
              aggregate_drop2(left);
            }
          }
        }");

  Alcotest.test_case "Slice 3: a linear variant payload must be consumed" `Quick
    (expect_type_error "linear variant payload 'permit' is never consumed"
       "linear view VariantPermit2;
        variant VariantMaybe2 { Empty; Held(VariantPermit2); }
        fn variant_bad2(value: VariantMaybe2) {
          match value {
            VariantMaybe2::Empty => {}
            VariantMaybe2::Held(permit) => {}
          }
        }");

  Alcotest.test_case
    "Slice 3: reused arm-local binder names retain each case's payload kind" `Quick
    (expect_type_error "linear variant payload 'item' is never consumed"
       "linear view VariantPermit2b;
        variant VariantMixed2b {
          Held(VariantPermit2b);
          Plain(i32);
        }
        fn variant_bad2b(value: VariantMixed2b) {
          match value {
            VariantMixed2b::Held(item) => {}
            VariantMixed2b::Plain(item) => {}
          }
        }");

  Alcotest.test_case "Slice 3: independently opened existentials have distinct identities" `Quick
    (expect_type_error "static value mismatch"
       "linear struct VariantOwner3[n: usize] { idx: usize @ n; }
        variant VariantMaybe3 {
          None;
          Some(exists n: usize. VariantOwner3[n]);
        }
        fn variant_same3(a: borrow VariantOwner3[n], b: borrow VariantOwner3[n]) {}
        fn variant_drop3(x: sink VariantOwner3[n]) {}
        fn variant_bad3(a: VariantMaybe3, b: VariantMaybe3) {
          match a {
            VariantMaybe3::None => {
              match b {
                VariantMaybe3::None => {}
                VariantMaybe3::Some(y0) => { variant_drop3(y0); }
              }
            }
            VariantMaybe3::Some(x) => {
              match b {
                VariantMaybe3::None => { variant_drop3(x); }
                VariantMaybe3::Some(y) => {
                  variant_same3(x, y);
                  variant_drop3(x);
                  variant_drop3(y);
                }
              }
            }
          }
        }");

  Alcotest.test_case "Slice 3: a closed variant match must be exhaustive" `Quick
    (expect_type_error "non-exhaustive match"
       "variant VariantPlain4 { Left; Right; }
        fn variant_bad4(value: VariantPlain4) {
          match value { VariantPlain4::Left => {} }
        }");

  Alcotest.test_case "Slice 3: a variant-producing function must return on every path" `Quick
    (expect_type_error "returns a variant and must return explicitly on every path"
       "variant VariantReturn4 { None; Some(i32); }
        fn variant_bad_return4(c: bool) -> VariantReturn4 {
          if (c) { return VariantReturn4::Some(1); }
        }");

  Alcotest.test_case "Slice 3: a linear variant cannot hide a payload behind wildcard" `Quick
    (expect_type_error "linear variant 'VariantMaybe5' cannot use a wildcard arm"
       "linear view VariantPermit5;
        variant VariantMaybe5 { Empty; Held(VariantPermit5); }
        fn variant_bad5(value: VariantMaybe5) { match value { _ => {} } }");

  Alcotest.test_case "Slice 3: a payload binder cannot shadow an existing value" `Quick
    (expect_type_error "variant payload binding 'owner' shadows an existing value"
       "linear view VariantPermit6;
        variant VariantMaybe6 { Empty; Held(VariantPermit6); }
        fn variant_bad6(value: VariantMaybe6, owner: i32) {
          match value {
            VariantMaybe6::Empty => {}
            VariantMaybe6::Held(owner) => {}
          }
        }");

  Alcotest.test_case "Slice 3: exists is restricted to a variant payload schema" `Quick
    (expect_type_error "exists is only valid as the outermost payload type"
       "linear struct VariantOwner7[n: usize] { idx: usize @ n; }
        fn variant_bad7(x: exists n: usize. VariantOwner7[n]) {}");

  Alcotest.test_case "plain variant storage accepts a concrete struct payload" `Quick
    (expect_ok
       "struct VariantPair7b { left: i32; right: i32; }
        variant VariantStruct7b { None; Pair(VariantPair7b); }
        struct VariantSlot7b { value: VariantStruct7b; }
        fn variant_slot_put7b(slot: *VariantSlot7b, value: VariantStruct7b) {
          slot.value = value;
        }
        fn variant_pair_sum7b(value: VariantStruct7b) -> i32 {
          match value {
            VariantStruct7b::None => { return 0; }
            VariantStruct7b::Pair(pair) => { return pair.left + pair.right; }
          }
        }");

  Alcotest.test_case "linear variant storage remains forbidden" `Quick
    (expect_type_error "cannot hold an affine/linear variant"
       "linear view VariantPermit7c;
        variant VariantLinear7c { Held(VariantPermit7c); }
        struct VariantSlot7c { value: VariantLinear7c; }");

  Alcotest.test_case "struct variant payload cannot hide affine ownership" `Quick
    (expect_type_error "concrete struct must be unrestricted"
       "affine opaque struct VariantToken7d;
        struct VariantEnvelope7d { token: *VariantToken7d; }
        variant VariantHidden7d { Held(VariantEnvelope7d); }");

  Alcotest.test_case "stable owner slot exchanges one existential linear owner under a guard" `Quick
    (expect_ok
       "linear view StableGuard7e[lock: addr];
        linear struct StableOwner7e[n: usize] {
          id: usize @ n;
          value: i32;
        }
        variant StableValue7e {
          Empty;
          Full(exists n: usize. StableOwner7e[n]);
        }
        struct StableSlot7e {
          private mutex: i32;
          private value: StableValue7e;
        }
        private let mut stable_slot7e: StableSlot7e;
        fn stable_lock7e(m: *i32 @ lock) -> StableGuard7e[lock] {
          return view StableGuard7e[lock];
        }
        fn stable_unlock7e(g: sink StableGuard7e[lock], m: *i32 @ lock) {}
        fn stable_new7e(value: i32) -> StableOwner7e[0] {
          let mut owner: StableOwner7e[0] = { 0, value };
          return owner;
        }
        fn stable_drop7e(owner: sink StableOwner7e[n]) {}
        fn stable_use7e() {
          let guard = stable_lock7e(&stable_slot7e.mutex);
          let previous: StableValue7e = stable_replace(
            guard, &stable_slot7e.mutex, stable_slot7e.value,
            StableValue7e::Full(stable_new7e(7)));
          match previous {
            StableValue7e::Empty => {}
            StableValue7e::Full(stale) => { stable_drop7e(stale); }
          }
          let current: StableValue7e = stable_replace(
            guard, &stable_slot7e.mutex, stable_slot7e.value,
            StableValue7e::Empty);
          match current {
            StableValue7e::Empty => {}
            StableValue7e::Full(owner) => { stable_drop7e(owner); }
          }
          stable_unlock7e(guard, &stable_slot7e.mutex);
        }");

  Alcotest.test_case "stable_replace rejects a guard for another mutex" `Quick
    (expect_type_error "stable_replace mutex does not match guard identity"
       "linear view StableGuard7ea[lock: addr];
        linear view StablePermit7ea;
        variant StableValue7ea { Empty; Full(StablePermit7ea); }
        struct StableSlot7ea {
          private mutex: i32;
          private value: StableValue7ea;
        }
        private let mut stable_slot7ea: StableSlot7ea;
        private let mut stable_slot7eb: StableSlot7ea;
        fn stable_lock7ea(m: *i32 @ lock) -> StableGuard7ea[lock] {
          return view StableGuard7ea[lock];
        }
        fn stable_wrong_lock7ea() -> StableValue7ea {
          let guard = stable_lock7ea(&stable_slot7ea.mutex);
          return stable_replace(guard, &stable_slot7eb.mutex,
            stable_slot7eb.value, StableValue7ea::Empty);
        }");

  Alcotest.test_case "stable_replace mutex and owner must share a container" `Quick
    (expect_type_error
       "stable_replace mutex and owner field must belong to the same syntactic container"
       "linear view StableGuard7ec[lock: addr];
        linear view StablePermit7ec;
        variant StableValue7ec { Empty; Full(StablePermit7ec); }
        struct StableSlot7ec {
          private mutex: i32;
          private value: StableValue7ec;
        }
        private let mut stable_slot7ec: StableSlot7ec;
        private let mut stable_slot7ed: StableSlot7ec;
        fn stable_lock7ec(m: *i32 @ lock) -> StableGuard7ec[lock] {
          return view StableGuard7ec[lock];
        }
        fn stable_wrong_container7ec() -> StableValue7ec {
          let guard = stable_lock7ec(&stable_slot7ec.mutex);
          return stable_replace(guard, &stable_slot7ec.mutex,
            stable_slot7ed.value, StableValue7ec::Empty);
        }");

  Alcotest.test_case "stable_replace guard requires one addr identity" `Quick
    (expect_type_error "stable_replace guard must carry exactly one addr index"
       "linear view StableGuard7ee;
        linear view StablePermit7ee;
        variant StableValue7ee { Empty; Full(StablePermit7ee); }
        struct StableSlot7ee {
          private mutex: i32;
          private value: StableValue7ee;
        }
        private let mut stable_slot7ee: StableSlot7ee;
        fn stable_unindexed7ee(guard: borrow StableGuard7ee)
             -> StableValue7ee {
          return stable_replace(guard, &stable_slot7ee.mutex,
            stable_slot7ee.value, StableValue7ee::Empty);
        }");

  Alcotest.test_case "stable owner field must be private" `Quick
    (expect_type_error "stable owner storage requires a private linear variant field"
       "linear view StablePermit7f;
        variant StableValue7f { Empty; Full(StablePermit7f); }
        struct StableSlot7f { value: StableValue7f; }");

  Alcotest.test_case "stable owner field requires an empty zero case first" `Quick
    (expect_type_error "must declare a payload-free empty case first"
       "linear view StablePermit7g;
        variant StableValue7g { Full(StablePermit7g); Empty; }
        struct StableSlot7g { private value: StableValue7g; }");

  Alcotest.test_case "stable owner container must be a private global" `Quick
    (expect_type_error "must be private"
       "linear view StablePermit7h;
        variant StableValue7h { Empty; Full(StablePermit7h); }
        struct StableSlot7h { private value: StableValue7h; }
        let mut stable_slot7h: StableSlot7h;");

  Alcotest.test_case "stable owner field rejects direct reads" `Quick
    (expect_type_error "cannot be read directly"
       "linear view StablePermit7i;
        variant StableValue7i { Empty; Full(StablePermit7i); }
        struct StableSlot7i { private value: StableValue7i; }
        private let mut stable_slot7i: StableSlot7i;
        fn stable_read7i() -> StableValue7i { return stable_slot7i.value; }");

  Alcotest.test_case "stable_replace requires a linear view guard" `Quick
    (expect_type_error "requires a linear erased-view guard"
       "linear view StablePermit7j;
        variant StableValue7j { Empty; Full(StablePermit7j); }
        struct StableSlot7j { private mutex: i32; private value: StableValue7j; }
        private let mut stable_slot7j: StableSlot7j;
        fn stable_bad_guard7j(x: i32) -> StableValue7j {
          return stable_replace(x, &stable_slot7j.mutex,
            stable_slot7j.value, StableValue7j::Empty);
        }");

  Alcotest.test_case "stable_replace result cannot be discarded" `Quick
    (expect_type_error "linear result of 'stable_replace' must be moved"
       "linear view StableGuard7k[lock: addr];
        linear view StablePermit7k;
        variant StableValue7k { Empty; Full(StablePermit7k); }
        struct StableSlot7k { private mutex: i32; private value: StableValue7k; }
        private let mut stable_slot7k: StableSlot7k;
        fn stable_lock7k(m: *i32 @ lock) -> StableGuard7k[lock] {
          return view StableGuard7k[lock];
        }
        fn stable_drop_result7k() {
          let guard = stable_lock7k(&stable_slot7k.mutex);
          stable_replace(guard, &stable_slot7k.mutex,
            stable_slot7k.value, StableValue7k::Empty);
        }");

  Alcotest.test_case "stable owner containers cannot be local copies" `Quick
    (expect_type_error "not a local value"
       "linear view StablePermit7l;
        variant StableValue7l { Empty; Full(StablePermit7l); }
        struct StableSlot7l { private value: StableValue7l; }
        fn stable_local7l() { let mut slot: StableSlot7l; }");

  Alcotest.test_case "stable owner containers cannot hide inside local arrays" `Quick
    (expect_type_error "not a local value"
       "linear view StablePermit7m;
        variant StableValue7m { Empty; Full(StablePermit7m); }
        struct StableSlot7m { private value: StableValue7m; }
        fn stable_array7m() { let mut slots: [StableSlot7m; 2]; }");

  Alcotest.test_case "stable owner containers cannot be copied through dereference" `Quick
    (expect_type_error "cannot be dereferenced or copied as a whole"
       "linear view StablePermit7n;
        variant StableValue7n { Empty; Full(StablePermit7n); }
        struct StableSlot7n { private value: StableValue7n; }
        private let mut stable_slot7n: StableSlot7n;
        fn stable_copy7n(slot: *StableSlot7n) {
          if (*slot == *slot) {}
        }");

  (* GitHub issue #158 (OWNERSHIP_KERNEL.md #131/#132: "indexed owners
     stored in arbitrary fields, arrays, globals, or other stable
     places"): a fixed-size array of a stable owner struct, as a
     top-level private mutable global, each array element its own
     independent stable_replace-able slot addressed by a runtime index.
     Full LLVM codegen (expect_codegen_ok, not just expect_ok) since a
     real bug was found this same session where array-indexed
     stable_replace type-checked fine but crashed LLVM's own IR
     verifier. *)
  Alcotest.test_case "stable owner slot array: each element is independently stable_replace-able by runtime index" `Quick
    (expect_codegen_ok
       "linear view StableArrGuard158[lock: addr];
        linear struct StableArrOwner158[n: usize] {
          id: usize @ n;
          value: i32;
        }
        variant StableArrValue158 {
          Empty;
          Full(exists n: usize. StableArrOwner158[n]);
        }
        struct StableArrSlot158 {
          private mutex: i32;
          private value: StableArrValue158;
        }
        private let mut stable_arr158: [StableArrSlot158; 4];
        fn stable_arr_lock158(m: *i32 @ lock) -> StableArrGuard158[lock] {
          return view StableArrGuard158[lock];
        }
        fn stable_arr_unlock158(g: sink StableArrGuard158[lock], m: *i32 @ lock) {}
        fn stable_arr_new158(value: i32) -> StableArrOwner158[0] {
          let mut owner: StableArrOwner158[0] = { 0, value };
          return owner;
        }
        fn stable_arr_drop158(owner: sink StableArrOwner158[n]) {}
        fn stable_arr_use158(slot: {0..<4 as usize}) {
          let guard = stable_arr_lock158(&stable_arr158[slot].mutex);
          let previous: StableArrValue158 = stable_replace(
            guard, &stable_arr158[slot].mutex, stable_arr158[slot].value,
            StableArrValue158::Full(stable_arr_new158(7)));
          match previous {
            StableArrValue158::Empty => {}
            StableArrValue158::Full(stale) => { stable_arr_drop158(stale); }
          }
          let current: StableArrValue158 = stable_replace(
            guard, &stable_arr158[slot].mutex, stable_arr158[slot].value,
            StableArrValue158::Empty);
          match current {
            StableArrValue158::Empty => {}
            StableArrValue158::Full(owner) => { stable_arr_drop158(owner); }
          }
          stable_arr_unlock158(guard, &stable_arr158[slot].mutex);
        }");

  Alcotest.test_case "stable owner slot array: mismatched runtime indices are not the same container" `Quick
    (expect_type_error
       "stable_replace mutex and owner field must belong to the same syntactic container"
       "linear view StableArrGuard158b[lock: addr];
        variant StableArrValue158b { Empty; Full(exists lock: addr. StableArrGuard158b[lock]); }
        struct StableArrSlot158b {
          private mutex: i32;
          private value: StableArrValue158b;
        }
        private let mut stable_arr158b: [StableArrSlot158b; 4];
        fn stable_arr_lock158b(m: *i32 @ lock) -> StableArrGuard158b[lock] {
          return view StableArrGuard158b[lock];
        }
        fn stable_arr_wrong158b(a: {0..<4 as usize}, b: {0..<4 as usize}) {
          let guard = stable_arr_lock158b(&stable_arr158b[a].mutex);
          let previous: StableArrValue158b = stable_replace(
            guard, &stable_arr158b[a].mutex, stable_arr158b[b].value,
            StableArrValue158b::Empty);
        }");

  Alcotest.test_case "stable owner slot array: reassigning the index invalidates the cached place identity" `Quick
    (expect_type_error
       "stable_replace mutex does not match guard identity"
       "linear view StableArrGuard158c[lock: addr];
        variant StableArrValue158c { Empty; Full(exists lock: addr. StableArrGuard158c[lock]); }
        struct StableArrSlot158c {
          private mutex: i32;
          private value: StableArrValue158c;
        }
        private let mut stable_arr158c: [StableArrSlot158c; 4];
        fn stable_arr_lock158c(m: *i32 @ lock) -> StableArrGuard158c[lock] {
          return view StableArrGuard158c[lock];
        }
        fn stable_arr_stale158c() {
          let mut slot: {0..<4 as usize} = 1;
          let guard = stable_arr_lock158c(&stable_arr158c[slot].mutex);
          slot = 0;
          let previous: StableArrValue158c = stable_replace(
            guard, &stable_arr158c[slot].mutex, stable_arr158c[slot].value,
            StableArrValue158c::Empty);
        }");

  Alcotest.test_case "stable owner slot array cannot be a local (not just a global)" `Quick
    (expect_type_error "not a local value"
       "linear view StableArrGuard158d[lock: addr];
        variant StableArrValue158d { Empty; Full(exists lock: addr. StableArrGuard158d[lock]); }
        struct StableArrSlot158d {
          private mutex: i32;
          private value: StableArrValue158d;
        }
        fn stable_arr_local158d() {
          let mut slots: [StableArrSlot158d; 4];
        }");

  Alcotest.test_case "stable owner slot array cannot be nested in a struct field" `Quick
    (expect_type_error "cannot contain stable owner storage"
       "linear view StableArrGuard158e[lock: addr];
        variant StableArrValue158e { Empty; Full(exists lock: addr. StableArrGuard158e[lock]); }
        struct StableArrSlot158e {
          private mutex: i32;
          private value: StableArrValue158e;
        }
        struct StableArrWrapper158e {
          slots: [StableArrSlot158e; 4];
        }");

  Alcotest.test_case "Slice 3: a view payload affects kind but has no runtime data requirement" `Quick
    (expect_ok
       "linear view VariantPermit8;
        variant VariantMaybe8 { Empty; Held(VariantPermit8); }
        fn variant_mint8() -> VariantMaybe8 {
          return VariantMaybe8::Held(view VariantPermit8);
        }
        fn variant_sink8(p: sink VariantPermit8) {}
        fn variant_use8(value: VariantMaybe8) {
          match value {
            VariantMaybe8::Empty => {}
            VariantMaybe8::Held(p) => { variant_sink8(p); }
          }
        }");

  Alcotest.test_case "Slice 3: an affine payload makes an affine, droppable variant" `Quick
    (expect_ok
       "affine view VariantPermit9;
        variant VariantMaybe9 { Empty; Held(VariantPermit9); }
        fn variant_mint9() -> VariantMaybe9 {
          return VariantMaybe9::Held(view VariantPermit9);
        }
        fn variant_drop9() { let value: VariantMaybe9 = variant_mint9(); }");

  (* -- Takibi Core Slice 4: scoped mutable owner borrows ----------------- *)

  Alcotest.test_case "Slice 4: a mutable existential owner can be changed and then consumed" `Quick
    (expect_ok
       "linear struct MutableOwner10[n: usize] {
          idx: usize @ n;
          value: i32;
        }
        variant MutableResult10 {
          None;
          Opened(exists n: usize. MutableOwner10[n]);
        }
        fn mutable_make10(idx: usize @ n) -> MutableOwner10[n] {
          let mut owner: MutableOwner10[n] = { idx, 0 };
          return owner;
        }
        fn mutable_set10(owner: borrow mut MutableOwner10[n], value: i32) {
          owner.value = value;
        }
        fn mutable_drop10(owner: sink MutableOwner10[n]) {}
        fn mutable_use10(idx: usize) {
          let result: MutableResult10 = MutableResult10::Opened(mutable_make10(idx));
          match result {
            MutableResult10::None => {}
            MutableResult10::Opened(mut owner) => {
              mutable_set10(owner, 7);
              mutable_drop10(owner);
            }
          }
        }");

  Alcotest.test_case "Slice 4: shared borrow cannot mutate an owner" `Quick
    (expect_type_error "cannot mutate shared-borrow parameter 'owner'"
       "linear struct MutableOwner11[n: usize] { value: i32; }
        fn mutable_bad11(owner: borrow MutableOwner11[n]) {
          owner.value = 1;
        }");

  Alcotest.test_case "Slice 4: mutable borrow requires a mutable place" `Quick
    (expect_type_error "cannot mutably borrow immutable value 'owner'"
       "linear struct MutableOwner12[n: usize] { idx: usize @ n; value: i32; }
        variant MutableResult12 {
          Opened(exists n: usize. MutableOwner12[n]);
        }
        fn mutable_set12(owner: borrow mut MutableOwner12[n]) {}
        fn mutable_drop12(owner: sink MutableOwner12[n]) {}
        fn mutable_bad12(result: MutableResult12) {
          match result {
            MutableResult12::Opened(owner) => {
              mutable_set12(owner);
              mutable_drop12(owner);
            }
          }
        }");

  Alcotest.test_case "Slice 4: mutable borrow cannot overlap another call argument" `Quick
    (expect_type_error "mutable borrow of 'owner' overlaps another argument"
       "linear struct MutableOwner13[n: usize] { value: i32; }
        fn mutable_alias13(a: borrow mut MutableOwner13[n],
                           b: borrow MutableOwner13[n]) {}
        fn mutable_drop13(owner: sink MutableOwner13[n]) {}
        fn mutable_bad13(owner: MutableOwner13[n]) {
          mutable_alias13(owner, owner);
          mutable_drop13(owner);
        }");

  Alcotest.test_case "Slice 4: mutable borrow overlap includes owner projections" `Quick
    (expect_type_error "mutable borrow of 'owner' overlaps another argument"
       "linear struct MutableOwner13b[n: usize] { value: i32; }
        fn mutable_alias13b(a: borrow mut MutableOwner13b[n], value: i32) {}
        fn mutable_drop13b(owner: sink MutableOwner13b[n]) {}
        fn mutable_bad13b(owner: MutableOwner13b[n]) {
          mutable_alias13b(owner, owner.value);
          mutable_drop13b(owner);
        }");

  Alcotest.test_case "Slice 4: may_block is inferred through direct calls" `Quick
    (fun () ->
      let types = infer
        "extern fn effect_wait14() !{may_block};
         fn effect_leaf14() { effect_wait14(); }
         fn effect_top14() { effect_leaf14(); }" in
      let leaf = Types.StringMap.find "effect_leaf14" types.functions in
      let top = Types.StringMap.find "effect_top14" types.functions in
      Alcotest.(check (list string)) "leaf effects" ["may_block"] leaf.effects;
      Alcotest.(check (list string)) "caller effects" ["may_block"] top.effects);

  Alcotest.test_case "unsafe effect requires a direct declaration and propagates" `Quick
    (fun () ->
      expect_type_error "does not declare !{unsafe}"
        "fn unsafe_missing_decl(p: *u8) { let s = unsafe { p[0..<1] }; }" ();
      let inferred = infer
        "fn unsafe_leaf(p: *u8) !{unsafe} { let s = unsafe { p[0..<1] }; }
         fn unsafe_caller(p: *u8) { unsafe_leaf(p); }" in
      let leaf = Types.StringMap.find "unsafe_leaf" inferred.functions in
      let caller = Types.StringMap.find "unsafe_caller" inferred.functions in
      Alcotest.(check (list string)) "leaf effects" ["unsafe"] leaf.effects;
      Alcotest.(check (list string)) "caller effects" ["unsafe"] caller.effects);

  (* GitHub issue #315: unsafe { stmt* } -- block-granularity sibling of
     unsafe { expr }, added so a stretch of statements sharing one trust
     justification (the motivating case: kernel/kernel/fd_table.tkb's
     unified_fd_clone_rollback, 4 separate unsafe{expr} wraps around 4
     unproven ops inside one loop body) needs one wrap instead of one per
     operation. Same grant mechanism (unsafe_depth), just walking a stmt
     list instead of a single expr -- these tests exercise the block form
     through the same positive/negative-control pairing already used for
     the expr form above. *)
  Alcotest.test_case
    "unsafe { stmt* } requires !{unsafe} on its enclosing function, same \
     as unsafe { expr }" `Quick
    (expect_type_error "does not declare !{unsafe}"
       "fn block315_missing_decl(p: *u8) { unsafe { let s = p[0..<4]; } }");

  Alcotest.test_case
    "unsafe { stmt* } covers MULTIPLE unproven ops with one wrap (the \
     fd_table.tkb motivating case)" `Quick
    (expect_ok
       "fn block315_two_ops(p: *u8, q: *u8) !{unsafe} {
          unsafe {
            let a = p[0..<4];
            let b = q[0..<8];
          }
        }");

  Alcotest.test_case
    "unsafe { stmt* } wrapping an entire loop body covers every unproven \
     op inside it with one wrap" `Quick
    (expect_ok
       "fn block315_loop(p: *u8, n: usize) !{unsafe} {
          unsafe {
            for i: usize in 0..<n {
              let a = p[0..<4];
            }
          }
        }");

  Alcotest.test_case
    "unsafe { stmt* } does not leak past its own closing brace -- a \
     sibling statement right after the block still needs its own unsafe" `Quick
    (expect_type_error "asserts a length without evidence"
       "fn block315_scope_leak(p: *u8, q: *u8) !{unsafe} {
          unsafe { let a = p[0..<4]; }
          let b = q[0..<8];
        }");

  Alcotest.test_case
    "unsafe { stmt* } scopes its own `let` bindings the same as a plain \
     { } block -- a name declared inside is unbound after the closing brace" `Quick
    (expect_type_error "Unbound variable: a"
       "fn block315_let_scope(p: *u8) !{unsafe} {
          unsafe { let a = p[0..<4]; }
          let b = a;
        }");

  Alcotest.test_case
    "unsafe { stmt* } nests: a block-form unsafe directly inside another \
     still grants (unsafe_depth survives a doubled increment/decrement)" `Quick
    (expect_ok
       "fn block315_nested(p: *u8) !{unsafe} {
          unsafe {
            unsafe {
              let a = p[0..<4];
            }
          }
        }");

  (* Reversed (see HISTORY.md): unlike may_block/interrupt/exception, which
     are real control-flow/concurrency hazards a caller's own effect
     reasoning must compose with, unsafe here means only "one bounded,
     local proof was done by hand" -- mandating it propagate through every
     explicitly-effect-declared caller turned a single accepted-risk line
     into a forced rewrite of every explicit-contract function transitively
     above it in a real kernel (confirmed concretely via kernel/lib/
     freelist.tkb's freelist_core_remove, whose !{unsafe} marking required
     touching 9 files before this reversal). --forbid-unsafe (unchanged,
     opt-in, checked below) remains available for a subtree that wants a
     whole-program "zero unsafe" guarantee. *)
  Alcotest.test_case
    "an explicit safe effect contract no longer rejects transitive unsafe \
     (unsafe is not required in the declared effect set of a caller that \
     merely reaches it)" `Quick
    (expect_ok
       "fn unsafe_leaf_contract(p: *u8) !{unsafe} {
          let s = unsafe { p[0..<1] };
        }
        fn safe_caller_contract(p: *u8) !{} { unsafe_leaf_contract(p); }");

  Alcotest.test_case "unsafe function-pointer effects are checked" `Quick
    (fun () ->
      expect_ok
        "fn unsafe_callback(p: *u8) !{unsafe} { let s = unsafe { p[0..<1] }; }
         fn install_unsafe(cb: fn !{unsafe}(*u8) -> void) {}
         fn use_unsafe_callback() { install_unsafe(unsafe_callback); }" ();
      expect_type_error "destination contract does not allow"
        "fn unsafe_callback_bad(p: *u8) !{unsafe} { let s = unsafe { p[0..<1] }; }
         fn install_safe(cb: fn !{}(*u8) -> void) {}
         fn reject_unsafe_callback() { install_safe(unsafe_callback_bad); }" ());

  Alcotest.test_case "Slice 4: interrupt root rejects a transitive blocking call" `Quick
    (expect_type_error
       "effect_irq15 -> effect_helper15 -> effect_wait15"
       "extern fn effect_wait15() !{may_block};
        fn effect_helper15() { effect_wait15(); }
        fn effect_irq15() !{interrupt} { effect_helper15(); }");

  Alcotest.test_case "Slice 4: interrupt_wait is intrinsically blocking" `Quick
    (expect_type_error "effect_irq16 -> interrupt_wait"
       "fn effect_irq16() !{interrupt} { interrupt_wait(); }");

  Alcotest.test_case "Slice 4: a non-blocking interrupt call graph is accepted" `Quick
    (expect_ok
       "fn effect_leaf17() { interrupt_notify(); }
        fn effect_irq17() !{interrupt} { effect_leaf17(); }");

  Alcotest.test_case "Slice 4: an unknown effect is rejected" `Quick
    (expect_type_error "unknown effect 'does_io'"
       "fn effect_bad18() !{does_io} {}");

  Alcotest.test_case "Slice 4: duplicate effects are rejected" `Quick
    (expect_type_error "duplicate effect 'may_block'"
       "fn effect_bad19() !{may_block, may_block} {}");

  Alcotest.test_case "Slice 4: interrupt rejects effect-unknown indirect calls" `Quick
    (expect_type_error "<indirect call>"
       "fn effect_bad20(callback: fn() -> i32) -> i32 !{interrupt} {
          return callback();
        }");

  Alcotest.test_case "Slice 4: recursive non-blocking interrupt graph terminates" `Quick
    (expect_ok
       "fn effect_recur21(n: i32) !{interrupt} {
          if (n > 0) { effect_recur21(n - 1); }
        }");

  Alcotest.test_case "Slice 5: interrupt accepts a contracted non-blocking callback" `Quick
    (expect_ok
       "fn effect_callback22() !{} { interrupt_notify(); }
        fn effect_irq22(callback: fn !{}() -> void) !{interrupt} {
          callback();
        }
        fn effect_install22() { effect_irq22(effect_callback22); }");

  Alcotest.test_case "Slice 5: interrupt rejects a may-block callback contract" `Quick
    (expect_type_error "<indirect call !{may_block}>"
       "fn effect_irq23(callback: fn !{may_block}() -> void) !{interrupt} {
          callback();
        }");

  Alcotest.test_case "Slice 5: blocking function cannot enter a non-blocking slot" `Quick
    (expect_type_error "destination contract does not allow"
       "fn effect_blocking24() !{may_block} {}
        fn effect_register24(callback: fn !{}() -> void) {}
        fn effect_bad24() { effect_register24(effect_blocking24); }");

  Alcotest.test_case "Slice 5: unknown function effect cannot enter a non-blocking slot" `Quick
    (expect_type_error "function pointer has unknown effects"
       "fn effect_unknown25() {}
        fn effect_register25(callback: fn !{}() -> void) {}
        fn effect_bad25() { effect_register25(effect_unknown25); }");

  Alcotest.test_case "Slice 5: non-blocking callback widens to a may-block slot" `Quick
    (fun () ->
      let types = infer
        "fn effect_safe26() !{} {}
         fn effect_run26(callback: fn !{may_block}() -> void) {
           callback();
         }
         fn effect_use26() { effect_run26(effect_safe26); }" in
      let run = Types.StringMap.find "effect_run26" types.functions in
      let use = Types.StringMap.find "effect_use26" types.functions in
      Alcotest.(check (list string)) "indirect caller effects"
        ["may_block"] run.effects;
      Alcotest.(check (list string)) "transitive caller effects"
        ["may_block"] use.effects);

  Alcotest.test_case "Slice 5: explicit non-blocking function contract is checked" `Quick
    (expect_type_error "violates its explicit !{} non-blocking contract"
       "extern fn effect_wait27() !{may_block};
        fn effect_helper27() { effect_wait27(); }
        fn effect_bad27() !{} { effect_helper27(); }");

  Alcotest.test_case "Slice 5: explicit non-blocking contract rejects unknown indirect effects" `Quick
    (expect_type_error "cannot verify its explicit !{} non-blocking contract"
       "fn effect_bad28(callback: fn() -> void) !{} { callback(); }");

  Alcotest.test_case "Slice 5: interrupt is not a function-pointer call effect" `Quick
    (expect_type_error "not a function-pointer call effect"
       "fn effect_bad29(callback: fn !{interrupt}() -> void) {}");

  Alcotest.test_case "Exception: declaration role is accepted" `Quick
    (fun () ->
      let types = infer "fn sync_handler29a() !{exception} {}" in
      let handler = Types.StringMap.find "sync_handler29a" types.functions in
      Alcotest.(check (list string)) "handler effects"
        ["exception"] handler.effects);

  Alcotest.test_case "Exception: role is not a function-pointer call effect" `Quick
    (expect_type_error "not a function-pointer call effect"
       "fn effect_bad29b(callback: fn !{exception}() -> void) {}");

  Alcotest.test_case "Exception: extern cannot claim a checked root" `Quick
    (expect_type_error "cannot be an interrupt or exception root"
       "extern fn effect_bad29c() !{exception};");

  Alcotest.test_case "Exception: root roles are mutually exclusive" `Quick
    (expect_type_error "cannot be both interrupt and exception"
       "fn effect_bad29d() !{interrupt, exception} {}");

  Alcotest.test_case "Exception: root rejects a transitive blocking call" `Quick
    (expect_type_error "sync_handler29e -> sync_helper29e -> sync_wait29e"
       "extern fn sync_wait29e() !{may_block};
        fn sync_helper29e() { sync_wait29e(); }
        fn sync_handler29e() !{exception} { sync_helper29e(); }");

  Alcotest.test_case "Exception: root rejects unknown indirect effects" `Quick
    (expect_type_error "exception function 'sync_handler29f' reaches a call with unknown effects"
       "fn sync_handler29f(callback: fn() -> void) !{exception} {
          callback();
        }");

  Alcotest.test_case "Exception: direct recursion is rejected as reentry" `Quick
    (expect_type_error "sync_handler29g -> sync_handler29g"
       "fn sync_handler29g() !{exception} { sync_handler29g(); }");

  Alcotest.test_case "Exception: transitive reentry is rejected" `Quick
    (expect_type_error "sync_handler29h -> sync_helper29h -> sync_handler29h"
       "fn sync_helper29h() { sync_handler29h(); }
        fn sync_handler29h() !{exception} { sync_helper29h(); }");

  Alcotest.test_case "Exception: non-blocking non-reentrant graph is accepted" `Quick
    (expect_ok
       "fn sync_helper29i() { interrupt_notify(); }
        fn sync_handler29i() !{exception} { sync_helper29i(); }");

  Alcotest.test_case "Exception: handler cannot abandon a linear cell vacancy" `Quick
    (expect_type_error "linear parameter 'vacant' is not consumed"
       "private linear struct HandlerVacancy29j[core: usize] {
          private core_tag: usize @ core;
        }
        fn sync_handler29j(vacant: HandlerVacancy29j[core]) !{exception} {}");

  Alcotest.test_case "Exception: trusted noreturn extern terminates a producing path" `Quick
    (expect_ok
       "linear struct Resume29k[elr: usize] { value: usize @ elr; }
        extern fn fail_stop29k() !{noreturn};
        fn sync_handler29k(elr: usize @ saved) -> Resume29k[saved]
            !{exception} {
          fail_stop29k();
        }");

  Alcotest.test_case "Exception: Takibi body cannot claim noreturn" `Quick
    (expect_type_error "restricted to trusted extern function declarations"
       "fn false_noreturn29l() !{noreturn} {}");

  Alcotest.test_case "Slice 5: a cast cannot invent a non-blocking contract" `Quick
    (expect_type_error "cannot cast through an explicit function-pointer effect contract"
       "fn effect_unknown30() {}
        fn effect_bad30() {
          let callback: fn !{}() -> void =
            effect_unknown30 as fn !{}() -> void;
        }");

  Alcotest.test_case "Slice 5: callback effects are invariant behind writable pointers" `Quick
    (expect_type_error "invariant behind writable pointers"
       "fn effect_bad31(slot: *fn !{}() -> void) {
          let widened: *fn() -> void = slot;
        }");

  (* -- Takibi Core Slice 6: indexed erased views ------------------------- *)

  Alcotest.test_case
    "Slice 6: a universally indexed view changes phase without proof arguments" `Quick
    (expect_ok
       "private linear view IndexedPhase6[slot: usize, state: u8];
        fn iv_begin6(index: {0..<2 as usize} @ slot)
            -> IndexedPhase6[slot, 0] {
          return view IndexedPhase6[slot, 0];
        }
        fn iv_write6(p: sink IndexedPhase6[slot, 0],
                     index: {0..<2 as usize} @ slot)
            -> IndexedPhase6[slot, 1] {
          return view IndexedPhase6[slot, 1];
        }
        fn iv_finish6(p: sink IndexedPhase6[slot, 1],
                      index: {0..<2 as usize} @ slot) {}
        fn iv_use6() {
          let p = iv_begin6(1);
          let ready = iv_write6(p, 1);
          iv_finish6(ready, 1);
        }");

  Alcotest.test_case
    "Slice 6: two indexed views cannot satisfy one static identity" `Quick
    (expect_type_error "static value mismatch: 1 vs 0"
       "linear view IndexedIdentity6[slot: usize, state: u8];
        fn iv_same6(a: borrow IndexedIdentity6[slot, 0],
                    b: borrow IndexedIdentity6[slot, 0]) {}
        fn iv_drop_identity6(p: sink IndexedIdentity6[slot, 0]) {}
        fn iv_bad_identity6() {
          let a: IndexedIdentity6[0, 0] = view IndexedIdentity6[0, 0];
          let b: IndexedIdentity6[1, 0] = view IndexedIdentity6[1, 0];
          iv_same6(a, b);
          iv_drop_identity6(a);
          iv_drop_identity6(b);
        }");

  Alcotest.test_case "Slice 6: a later phase cannot enter an earlier transition" `Quick
    (expect_type_error "static value mismatch: 1 vs 0"
       "linear view IndexedState6[slot: usize, state: u8];
        fn iv_expect_open6(p: sink IndexedState6[slot, 0]) {}
        fn iv_bad_state6() {
          let p: IndexedState6[0, 1] = view IndexedState6[0, 1];
          iv_expect_open6(p);
        }");

  Alcotest.test_case "Slice 6: indexed view arity is checked" `Quick
    (expect_type_error "view 'IndexedArity6' expects 2 static argument(s), got 1"
       "linear view IndexedArity6[slot: usize, state: u8];
        fn iv_bad_arity6(p: sink IndexedArity6[slot]) {}");

  Alcotest.test_case "Slice 6: indexed view literal arguments respect their sorts" `Quick
    (expect_type_error "static integer 256 does not fit its declared sort"
       "linear view IndexedSort6[state: u8];
        fn iv_bad_sort6() -> IndexedSort6[256] {
          return view IndexedSort6[256];
        }");

  Alcotest.test_case "Slice 6: an indexed view cannot omit its static arguments" `Quick
    (expect_type_error "indexed view 'IndexedBare6' requires 1 static argument(s)"
       "linear view IndexedBare6[slot: usize];
        fn iv_bad_bare6(p: sink IndexedBare6) {}");

  Alcotest.test_case "Slice 6: indexing does not open a cast-based mint path" `Quick
    (expect_type_error "cannot construct erased view 'IndexedCast6' with a cast"
       "linear view IndexedCast6[slot: usize];
        fn iv_drop_cast6(p: sink IndexedCast6[slot]) {}
        fn iv_bad_cast6() {
          let p: IndexedCast6[0] = 0 as IndexedCast6[0];
          iv_drop_cast6(p);
        }");

  Alcotest.test_case "Slice 6: indexed views remain excluded from runtime storage" `Quick
    (expect_type_error "global 'iv_stored6' cannot hold an erased view"
       "affine view IndexedStored6[slot: usize];
        let mut iv_stored6: IndexedStored6[0];");

  Alcotest.test_case "Slice 6: view static parameter names are unique" `Quick
    (expect_type_error "duplicate static parameter 'slot' on view 'IndexedDuplicate6'"
       "linear view IndexedDuplicate6[slot: usize, slot: usize];");

  (* -- Post-Slice 6: static address/place identities -------------------- *)

  Alcotest.test_case "addr identity: one global lock place balances" `Quick
    (expect_ok
       "private linear view AddrGuard7[lock: addr];
        fn addr_lock7(m: *i32 @ lock) -> AddrGuard7[lock] {
          return view AddrGuard7[lock];
        }
        fn addr_unlock7(g: sink AddrGuard7[lock], m: *i32 @ lock) {}
        let mut addr_lock_word7: i32;
        fn addr_use7() {
          let g = addr_lock7(&addr_lock_word7);
          addr_unlock7(g, &addr_lock_word7);
        }");

  Alcotest.test_case "addr identity: one immutable pointer binding balances" `Quick
    (expect_ok
       "linear view AddrPointerGuard7[lock: addr];
        fn addr_pointer_lock7(m: *i32 @ lock) -> AddrPointerGuard7[lock] {
          return view AddrPointerGuard7[lock];
        }
        fn addr_pointer_unlock7(g: sink AddrPointerGuard7[lock],
                                m: *i32 @ lock) {}
        let mut addr_pointer_word7: i32;
        fn addr_pointer_use7() {
          let pointer = &addr_pointer_word7;
          let g = addr_pointer_lock7(pointer);
          addr_pointer_unlock7(g, pointer);
        }");

  Alcotest.test_case "addr identity: a guard rejects a different global lock" `Quick
    (expect_type_error "static value mismatch: &addr_lock_b7 vs &addr_lock_a7"
       "linear view AddrWrongGuard7[lock: addr];
        fn addr_wrong_lock7(m: *i32 @ lock) -> AddrWrongGuard7[lock] {
          return view AddrWrongGuard7[lock];
        }
        fn addr_wrong_unlock7(g: sink AddrWrongGuard7[lock], m: *i32 @ lock) {}
        let mut addr_lock_a7: i32;
        let mut addr_lock_b7: i32;
        fn addr_wrong_use7() {
          let g = addr_wrong_lock7(&addr_lock_a7);
          addr_wrong_unlock7(g, &addr_lock_b7);
        }");

  Alcotest.test_case "addr identity: one field place survives a guard transition" `Quick
    (expect_ok
       "linear view AddrFieldGuard7[lock: addr];
        struct AddrFieldBox7 { mutex: i32; sequence: io i32; }
        fn addr_field_lock7(m: *i32 @ lock) -> AddrFieldGuard7[lock] {
          return view AddrFieldGuard7[lock];
        }
        fn addr_field_wait7(seq: *io i32, g: sink AddrFieldGuard7[lock],
                            m: *i32 @ lock) -> AddrFieldGuard7[lock] {
          return view AddrFieldGuard7[lock];
        }
        fn addr_field_unlock7(g: sink AddrFieldGuard7[lock], m: *i32 @ lock) {}
        let mut addr_field_box7: AddrFieldBox7;
        fn addr_field_use7() {
          let mut g = addr_field_lock7(&addr_field_box7.mutex);
          g = addr_field_wait7(&addr_field_box7.sequence, g,
                               &addr_field_box7.mutex);
          addr_field_unlock7(g, &addr_field_box7.mutex);
        }");

  Alcotest.test_case "addr sort rejects an integer static argument" `Quick
    (expect_type_error "cannot be used where addr"
       "linear view AddrLiteralGuard7[lock: addr];
        fn addr_literal_bad7(g: sink AddrLiteralGuard7[0]) {}");

  Alcotest.test_case "addr is not a runtime value type" `Quick
    (expect_type_error "addr is a checker-only static sort"
       "fn addr_runtime_bad7(value: addr) {}");

  Alcotest.test_case "addr is reserved from runtime declarations" `Quick
    (expect_type_error "'addr' is reserved for the checker-only static address sort"
       "struct addr { value: i32; }");

  Alcotest.test_case "addr identity: rebinding a pointer invalidates field places" `Quick
    (expect_type_error "static value mismatch"
       "linear view AddrRebindGuard7[lock: addr];
        struct AddrRebindBox7 { mutex: i32; }
        fn addr_rebind_lock7(m: *i32 @ lock) -> AddrRebindGuard7[lock] {
          return view AddrRebindGuard7[lock];
        }
        fn addr_rebind_unlock7(g: sink AddrRebindGuard7[lock],
                               m: *i32 @ lock) {}
        let mut addr_rebind_a7: AddrRebindBox7;
        let mut addr_rebind_b7: AddrRebindBox7;
        fn addr_rebind_bad7() {
          let mut box = &addr_rebind_a7;
          let g = addr_rebind_lock7(&box.mutex);
          box = &addr_rebind_b7;
          addr_rebind_unlock7(g, &box.mutex);
        }");

  (* -- Post-Slice 6: finite-state existential view dispatch -------------- *)

  Alcotest.test_case
    "finite-state dispatch: existential indexed views preserve identity across transitions"
    `Quick
    (expect_ok
       "enum TcpState7: u8 { Listen; SynRcvd; Established; }
        private linear view TcpConn7[conn: usize, state: TcpState7];
        variant TcpDispatch7 {
          Listen(exists conn: usize. TcpConn7[conn, TcpState7::Listen]);
          SynRcvd(exists conn: usize. TcpConn7[conn, TcpState7::SynRcvd]);
          Established(exists conn: usize. TcpConn7[conn, TcpState7::Established]);
        }
        fn tcp_syn7(c: sink TcpConn7[conn, TcpState7::Listen])
            -> TcpConn7[conn, TcpState7::SynRcvd] {
          return view TcpConn7[conn, TcpState7::SynRcvd];
        }
        fn tcp_establish7(c: sink TcpConn7[conn, TcpState7::SynRcvd])
            -> TcpConn7[conn, TcpState7::Established] {
          return view TcpConn7[conn, TcpState7::Established];
        }
        fn tcp_dispatch_new7() -> TcpDispatch7 {
          return TcpDispatch7::Listen(view TcpConn7[0, TcpState7::Listen]);
        }
        fn tcp_dispatch_step7(value: TcpDispatch7) -> TcpDispatch7 {
          match value {
            TcpDispatch7::Listen(c) => {
              return TcpDispatch7::SynRcvd(tcp_syn7(c));
            }
            TcpDispatch7::SynRcvd(c) => {
              return TcpDispatch7::Established(tcp_establish7(c));
            }
            TcpDispatch7::Established(c) => {
              return TcpDispatch7::Established(c);
            }
          }
        }");

  Alcotest.test_case
    "finite-state dispatch: a state-specific transition rejects the wrong enum state"
    `Quick
    (expect_type_error "static value mismatch"
       "enum TcpStateWrong7: u8 { Listen; SynRcvd; }
        linear view TcpConnWrong7[conn: usize, state: TcpStateWrong7];
        fn tcp_expect_listen7(c: sink TcpConnWrong7[conn, TcpStateWrong7::Listen]) {}
        fn tcp_wrong_state7() {
          let c = view TcpConnWrong7[0, TcpStateWrong7::SynRcvd];
          tcp_expect_listen7(c);
        }");

  Alcotest.test_case
    "finite-state dispatch: existential view payload remains a linear obligation"
    `Quick
    (expect_type_error "linear variant payload 'c' is never consumed"
       "enum TcpStatePending7: u8 { Listen; }
        linear view TcpConnPending7[conn: usize, state: TcpStatePending7];
        variant TcpDispatchPending7 {
          Listen(exists conn: usize.
            TcpConnPending7[conn, TcpStatePending7::Listen]);
        }
        fn tcp_pending_new7() -> TcpDispatchPending7 {
          return TcpDispatchPending7::Listen(
            view TcpConnPending7[0, TcpStatePending7::Listen]);
        }
        fn tcp_pending_bad7(value: TcpDispatchPending7) {
          match value { TcpDispatchPending7::Listen(c) => {} }
        }");

  Alcotest.test_case
    "finite-state dispatch: enum states are nominal across static sorts" `Quick
    (expect_type_error "has sort TcpStateNominalB7, but TcpStateNominalA7 is required"
       "enum TcpStateNominalA7: u8 { Ready; }
        enum TcpStateNominalB7: u8 { Ready; }
        linear view TcpNominal7[state: TcpStateNominalA7];
        fn tcp_nominal_bad7() {
          let p = view TcpNominal7[TcpStateNominalB7::Ready];
        }");

  Alcotest.test_case
    "finite-state dispatch: an open enum is not a finite static sort" `Quick
    (expect_type_error "non-exhaustive enum 'TcpOpenState7' cannot be used"
       "enum TcpOpenState7: u8 { Known; _; }
        linear view TcpOpenView7[state: TcpOpenState7];");

  (* Bare `return;` (GitHub issue #153-adjacent fix): early exit from a
     void function without a value, previously a syntax error. *)
  Alcotest.test_case
    "bare return: early exit from a void function is accepted" `Quick
    (expect_ok
       "fn early_exit_void(bad: bool) {
          if (bad) {
            return;
          }
          return;
        }");

  Alcotest.test_case
    "bare return: rejected inside a value-returning function" `Quick
    (expect_type_error
       "bare `return;` requires a void return type"
       "fn early_exit_value(bad: bool) -> i32 {
          if (bad) {
            return;
          }
          return 1;
        }");

  Alcotest.test_case
    "bare return: still requires every linear value consumed on that path" `Quick
    (expect_type_error
       "linear value 'token' is still pending at this return"
       "linear struct EarlyExitToken[n: usize] { idx: usize @ n; }
        fn early_exit_token_new(idx: usize @ n) -> EarlyExitToken[n] {
          let mut t: EarlyExitToken[n] = { idx }; return t;
        }
        fn early_exit_token_drop(t: sink EarlyExitToken[n]) {}
        fn early_exit_leaks_linear(bad: bool, idx: usize @ n) {
          let token = early_exit_token_new(idx);
          if (bad) {
            return;
          }
          early_exit_token_drop(token);
        }");

  (* GitHub issue #186: u16be/u32be are distinct types from u16/u32 that do
     not unify with them -- arithmetic, ordering comparisons, and casts to
     any integer type other than their own host type must all be rejected,
     forcing an explicit `as u16`/`as u32` conversion first. ==/!=/bitwise
     ops are allowed directly (see the linux_user/wire_endian/ example for
     the positive/runtime-value side of this same feature). *)
  Alcotest.test_case "u16be: arithmetic is rejected without a cast" `Quick
    (expect_type_error
       "convert with `as u16`"
       "struct packed WireHdr { magic: u16be; flags: u16be; }
        fn bad_add(h: *WireHdr) -> u16be { return h.magic + 1; }");

  Alcotest.test_case "u16be: ordering comparison is rejected without a cast" `Quick
    (expect_type_error
       "convert with `as u16`"
       "struct packed WireHdr { magic: u16be; flags: u16be; }
        fn bad_cmp(h: *WireHdr) -> bool { return h.magic < h.flags; }");

  Alcotest.test_case "u16be: cast to a type other than u16 is rejected" `Quick
    (expect_type_error
       "only u16be <-> u16 or u32be <-> u32 is a legal conversion"
       "struct packed WireHdr { magic: u16be; }
        fn bad_cast(h: *WireHdr) -> u32 { return h.magic as u32; }");

  Alcotest.test_case "u32be: arithmetic is rejected without a cast" `Quick
    (expect_type_error
       "convert with `as u16`"
       "struct packed WireHdr { seq: u32be; ack: u32be; }
        fn bad_add32(h: *WireHdr) -> u32be { return h.seq + 1; }");

  Alcotest.test_case "u32be: ordering comparison is rejected without a cast" `Quick
    (expect_type_error
       "convert with `as u16`"
       "struct packed WireHdr { seq: u32be; ack: u32be; }
        fn bad_cmp32(h: *WireHdr) -> bool { return h.seq < h.ack; }");

  Alcotest.test_case "u32be: cast to a type other than u32 is rejected" `Quick
    (expect_type_error
       "only u16be <-> u16 or u32be <-> u32 is a legal conversion"
       "struct packed WireHdr { seq: u32be; }
        fn bad_cast32(h: *WireHdr) -> u16 { return h.seq as u16; }");

  Alcotest.test_case "u16be and u32be cannot cast to each other" `Quick
    (expect_type_error
       "only u16be <-> u16 or u32be <-> u32 is a legal conversion"
       "struct packed WireHdr { magic: u16be; seq: u32be; }
        fn bad_cross(h: *WireHdr) -> u32be { return h.magic as u32be; }");

  (* GitHub issue #207: the `type` keyword and `Name(T)` instantiation
     syntax parse. A call to a generic function whose type argument cannot
     be inferred (here: a bare integer literal, not a Var/&Var with a
     locally-known type -- Monomorphize.run's narrow inference rule) is
     rejected with a clear, specific error rather than crashing or
     silently mis-elaborating. This test's expectation was updated once
     generic function instantiation (build order step 5) actually landed;
     it previously exercised the older, more generic "not implemented yet"
     fallback that fired before any function-instantiation logic existed
     to even attempt inference. *)
  Alcotest.test_case "a generic function call whose type argument cannot \
                       be inferred is rejected with a specific error \
                       (issue #207)" `Quick
    (expect_type_error
       "cannot infer type parameter 'T'"
       "fn identity(T: type, x: usize) -> usize { return x; }
        fn use_identity() -> usize { return identity(5); }");

  Alcotest.test_case "Name(T) generic instantiation parses but is rejected \
                       (generics not implemented yet, issue #207)" `Quick
    (expect_type_error
       "is a generic instantiation, which is not implemented yet"
       "struct Widget { value: usize; }
        fn use_widget() -> usize {
          let mut w: Widget(usize);
          return w.value;
        }");

  Alcotest.test_case "generic struct Name(T: type) { ... } parses and \
                       registers a template without breaking the rest of \
                       the program (issue #207 build order step 3 -- \
                       parser-only, nothing consumes it yet)" `Quick
    (expect_codegen_ok
       "generic struct Freelist(T: type) {
          count: usize;
          data: []T;
        }
        fn generic_struct_unused_template() -> usize {
          let n: usize = 42;
          return n;
        }");

  Alcotest.test_case "two generic structs with the same name are rejected \
                       as duplicates (issue #207)" `Quick
    (expect_type_error
       "already defined as a generic struct"
       "generic struct Freelist(T: type) { count: usize; }
        generic struct Freelist(U: type) { other: usize; }");

  (* -- &T/&mut T reference type (GitHub issue #314/#319) -------------- *)

  Alcotest.test_case "&mut T parameter reads and writes fields" `Quick
    (expect_ok
       "struct Pool { count: usize; }
        fn bump(p: &mut Pool) { p.count = p.count + 1; }
        fn f() { let mut pool: Pool = {0}; bump(&pool); }");

  Alcotest.test_case "&T parameter reads fields" `Quick
    (expect_ok
       "struct Pool { count: usize; }
        fn peek(p: &Pool) -> usize { return p.count; }
        fn f() { let mut pool: Pool = {0}; let n = peek(&pool); }");

  Alcotest.test_case "&T parameter cannot write a field" `Quick
    (expect_type_error
       "cannot write field"
       "struct Pool { count: usize; }
        fn bump(p: &Pool) { p.count = p.count + 1; }
        fn f() { let mut pool: Pool = {0}; bump(&pool); }");

  Alcotest.test_case "&/&mut supports no arithmetic" `Quick
    (expect_type_error
       "does not support operators"
       "struct Pool { count: usize; }
        fn bad(p: &mut Pool) { let q = p + 1; }
        fn f() { let mut pool: Pool = {0}; bad(&pool); }");

  Alcotest.test_case "&/&mut supports no indexing" `Quick
    (expect_type_error
       "index operator on non-array/pointer type"
       "struct Pool { count: usize; }
        fn bad(p: &mut Pool) -> usize { return p[0]; }
        fn f() { let mut pool: Pool = {0}; let n = bad(&pool); }");

  Alcotest.test_case "&T cannot be forged from an integer, not even under unsafe" `Quick
    (expect_type_error
       "can only be minted with"
       "struct Pool { count: usize; }
        fn bad() {
          let n: usize = 4096;
          let p: &Pool = unsafe { n as &Pool };
        }");

  Alcotest.test_case "*T -> &T cast requires unsafe" `Quick
    (expect_type_error
       "asserts it is a live"
       "struct Pool { count: usize; }
        fn take(p: &Pool) -> usize { return p.count; }
        fn f(raw: *Pool) -> usize { return take(raw as &Pool); }");

  Alcotest.test_case "*T -> &T cast is legal under unsafe" `Quick
    (expect_ok
       "struct Pool { count: usize; }
        fn take(p: &Pool) -> usize { return p.count; }
        fn f(raw: *Pool) -> usize !{unsafe} { return take(unsafe { raw as &Pool }); }");

  Alcotest.test_case "&T widens to *T with no unsafe (existing, un-migrated callee keeps working)" `Quick
    (expect_ok
       "struct Pool { count: usize; }
        fn legacy_peek(p: *Pool) -> usize { return p.count; }
        fn f() { let mut pool: Pool = {0}; let n = legacy_peek(&pool); }");

  Alcotest.test_case "&mut T widens to &T (reborrow as shared)" `Quick
    (expect_ok
       "struct Pool { count: usize; }
        fn peek(p: &Pool) -> usize { return p.count; }
        fn bump_then_peek(p: &mut Pool) -> usize { return peek(p); }
        fn f() { let mut pool: Pool = {0}; let n = bump_then_peek(&pool); }");

  Alcotest.test_case "&T does not widen to &mut T" `Quick
    (expect_type_error
       "cannot unify"
       "struct Pool { count: usize; }
        fn bump(p: &mut Pool) { p.count = p.count + 1; }
        fn peek_then_bump(p: &Pool) { bump(p); }
        fn f() { let mut pool: Pool = {0}; peek_then_bump(&pool); }");

  Alcotest.test_case "let with &T annotation resolves &expr against it (growable_pool.tkb shape)" `Quick
    (expect_ok
       "struct Core { n: usize; }
        struct Pool { core: Core; }
        fn use_core(c: &Core) -> usize { return c.n; }
        fn f(pool: &mut Pool) -> usize {
          let core: &Core = &pool.core;
          return use_core(core);
        }");

  Alcotest.test_case "&T is rejected as a struct field type" `Quick
    (expect_type_error
       "is only valid in a function parameter type or a local"
       "struct Core { n: usize; }
        struct Holder { c: &Core; }");

  Alcotest.test_case "&T is rejected as a global type" `Quick
    (expect_type_error
       "is only valid in a function parameter type or a local"
       "struct Core { n: usize; }
        let mut g: &Core;");

  Alcotest.test_case "&T is rejected as a return type" `Quick
    (expect_type_error
       "is only valid in a function parameter type or a local"
       "struct Core { n: usize; }
        fn f(c: &Core) -> &Core { return c; }");

  Alcotest.test_case "&T may only wrap a plain struct type" `Quick
    (expect_type_error
       "may only wrap a plain struct type"
       "fn f(x: &usize) { }");

  (* GitHub issue #314/#319 follow-up: index-assignment through an array
     field reached via a shared &T was not gated the way a direct
     `.field = v`/`*r = v` write already is -- see
     check_no_write_through_shared_ref. *)
  Alcotest.test_case "&T cannot write an array field via index assignment" `Quick
    (expect_type_error
       "cannot write through a shared reference"
       "struct RefArrPool { slots: [usize; 4]; }
        fn bad(p: &RefArrPool) { p.slots[0] = 1; }
        fn f() { let mut pool: RefArrPool = {{0, 0, 0, 0}}; bad(&pool); }");

  Alcotest.test_case "&mut T can write an array field via index assignment" `Quick
    (expect_ok
       "struct RefArrPool { slots: [usize; 4]; }
        fn ok(p: &mut RefArrPool) { p.slots[0] = 1; }
        fn f() { let mut pool: RefArrPool = {{0, 0, 0, 0}}; ok(&pool); }");

]

(* -- Codegen tests ----------------------------------------------------------
   parser/type_inf tests check the AST/type layer; these additionally run
   real LLVM codegen and its verifier, catching bugs that only manifest as
   invalid IR (mismatched operand types, missing terminators, etc.) rather
   than a type error. Kept small and targeted rather than broad: this is a
   regression suite for specific past codegen bugs, not a general codegen
   test bed (that role is filled by examples/ + make qemutest, which also
   checks runtime behavior, not just "the IR verifies"). *)

(* GitHub issue #227 item 1 (prototype slice): the one closed AArch64
   exception-frame register-name field set (x0..x30/sp_el0/elr_el1/
   spsr_el1/tpidr_el0/q0..q31/fpsr/fpcr) `exception_entry`'s tests below share --
   factored out as a top-level `let` (not one inside codegen_tests' own
   list literal) because `let ... in` immediately followed by `;`-separated
   list elements greedily swallows the rest of the list as a sequence
   instead of terminating at the next list element, found the hard way as
   a "this expression has type unit Alcotest.test_case but... left-hand
   side of a sequence" error while first adding these tests. *)
let exc_frame_src =
  "struct packed ExcFrame {
     x0: usize; x1: usize; x2: usize; x3: usize; x4: usize; x5: usize;
     x6: usize; x7: usize; x8: usize; x9: usize; x10: usize; x11: usize;
     x12: usize; x13: usize; x14: usize; x15: usize; x16: usize; x17: usize;
     x18: usize; x19: usize; x20: usize; x21: usize; x22: usize; x23: usize;
     x24: usize; x25: usize; x26: usize; x27: usize; x28: usize; x29: usize;
     x30: usize;
     sp_el0: usize; elr_el1: usize; spsr_el1: usize;
     q0: [u8;16]; q1: [u8;16]; q2: [u8;16]; q3: [u8;16]; q4: [u8;16];
     q5: [u8;16]; q6: [u8;16]; q7: [u8;16]; q8: [u8;16]; q9: [u8;16];
     q10: [u8;16]; q11: [u8;16]; q12: [u8;16]; q13: [u8;16]; q14: [u8;16];
     q15: [u8;16]; q16: [u8;16]; q17: [u8;16]; q18: [u8;16]; q19: [u8;16];
     q20: [u8;16]; q21: [u8;16]; q22: [u8;16]; q23: [u8;16]; q24: [u8;16];
     q25: [u8;16]; q26: [u8;16]; q27: [u8;16]; q28: [u8;16]; q29: [u8;16];
     q30: [u8;16]; q31: [u8;16];
     fpsr: usize; fpcr: usize; tpidr_el0: usize;
   }\n"

(* GitHub issue #230: writes [contents] to a real temp file, runs [f] with
   its path, and always removes it afterward -- embed_file needs a real
   file on disk, and dune's test runner's own CWD is not the repo root
   the compiler's other `path resolved like use "..."` conventions assume,
   so a path relative to anything assumed here would be fragile. *)
let with_embed_fixture contents f =
  let path = Filename.temp_file "takibi_embed_test" ".bin" in
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)

let codegen_tests = [
  Alcotest.test_case
    "mutable local restores its declaration-specific alloca after a disjoint immutable local" `Quick
    (expect_codegen_ok
      "fn cg_mutable_after_disjoint_immutable(flag: bool) {
         if (flag) {
           let copied: usize = 1;
         }
         let mut copied: usize = 0;
         copied = copied + 1;
       }");

  Alcotest.test_case
    "disjoint same-name annotated locals retain their own pointer widths" `Quick
    (fun () ->
      let src =
        "fn cg_scoped_local_width(flag: bool, byte_out: *u8, word_out: *u64)
             !{unsafe} {
           if (flag) {
             let previous: *u8 = byte_out;
             previous[0 as isize] = 0;
           }
           if (flag) {
             let previous: *u64 = word_out;
             previous[0 as isize] = 0;
           }
         }" in
      ignore (gen_codegen src);
      let fn = match Hashtbl.find_opt Llvm_gen.functions "cg_scoped_local_width" with
        | Some (_, fn) -> fn
        | None -> Alcotest.fail "cg_scoped_local_width not found"
      in
      let ir = Llvm.string_of_llvalue fn in
      Alcotest.(check bool) "byte branch stores one byte" true
        (contains_substring ir "store i8 0");
      Alcotest.(check bool) "word branch stores one word" true
        (contains_substring ir "store i64 0"));

  Alcotest.test_case
    "all-return nested if/else terminates its unreachable merge blocks" `Quick
    (expect_codegen_ok
      "variant CgAllReturnResult { First(i32); Second(i32); Third(i32); }
       fn cg_all_return_nested(x: i32) -> CgAllReturnResult {
         if (x == 0) {
           return CgAllReturnResult::First(x);
         } else if (x == 1) {
           return CgAllReturnResult::Second(x);
         } else {
           return CgAllReturnResult::Third(x);
         }
       }");

  Alcotest.test_case
    "small two-field aggregate stays by-value at a deeply nested call" `Quick
    (expect_codegen_ok
      "struct CgSmallArg { status: i32; detail: i32; }
       variant CgSmallState { Empty; Open(i32); }
       fn cg_small_arg_ok(r: CgSmallArg) -> bool { return r.status == 0; }
       fn cg_small_arg_deep(fd: usize, value: i32) -> usize {
         if (fd >= 3) {
           let slot: usize = fd - 3;
           if (slot < 4) {
             let state: CgSmallState = CgSmallState::Open(value);
             match state {
               CgSmallState::Empty => { return 9; }
               CgSmallState::Open(v) => {
                 let mut result: CgSmallArg = {v, 0};
                 if (cg_small_arg_ok(result) == true) { return 1; }
                 return 2;
               }
             }
           }
         }
         return 3;
       }");

  Alcotest.test_case
    "nested distinct-variant match after existential binding codegens" `Quick
    (expect_codegen_ok
      "linear struct CgNestedOwner[n: usize] { value: usize @ n; }
       variant CgNestedOuter {
         None;
         Some(exists n: usize. CgNestedOwner[n]);
       }
       variant CgNestedInner { Value(usize); Error(usize); }
       fn cg_nested_drop(owner: sink CgNestedOwner[n]) {}
       fn cg_nested_store(owner: sink CgNestedOwner[n]) -> CgNestedInner {
         let value: usize = owner.value;
         cg_nested_drop(owner);
         return CgNestedInner::Value(value);
       }
       fn cg_nested_match(value: CgNestedOuter) -> usize {
         match value {
           CgNestedOuter::None => { return 0; }
           CgNestedOuter::Some(owner) => {
             match cg_nested_store(owner) {
               CgNestedInner::Value(v) => { return v; }
               CgNestedInner::Error(e) => { return e; }
             }
           }
         }
       }");

  Alcotest.test_case
    "authority pointer ABI erases the guard tie and returns a plain pointer" `Quick
    (fun () ->
      let src =
        "linear view CgAuthorityGuard[lock: addr];
         struct CgAuthorityData { value: i32; }
         let mut cg_authority_data: CgAuthorityData;
         fn cg_authority_access(g: borrow CgAuthorityGuard[lock])
             -> *CgAuthorityData @ lock {
           return &cg_authority_data;
         }" in
      ignore (gen_codegen src);
      let access = match Hashtbl.find_opt Llvm_gen.functions
          "cg_authority_access" with
        | Some (_, fn) -> fn
        | None -> Alcotest.fail "cg_authority_access not found"
      in
      let ir = Llvm.string_of_llvalue access in
      Alcotest.(check int) "erased guard leaves no runtime parameter"
        0 (Array.length (Llvm.params access));
      Alcotest.(check bool) "accessor returns an ordinary pointer" true
        (contains_substring ir "define ptr @cg_authority_access()");
      Alcotest.(check bool) "authority is not encoded in pointer bits" false
        (contains_substring ir "inttoptr" || contains_substring ir "ptrtoint"));

  Alcotest.test_case
    "async TX ABI keeps runtime descriptor state and erases completion permit" `Quick
    (fun () ->
      let src =
        "linear struct CgAsyncRx[d: usize] {
           index: {0..<4 as usize} @ d;
           len: i32;
         }
         linear struct CgAsyncTx[d: usize] {
           index: {0..<4 as usize} @ d;
           tx_index: isize;
         }
         affine view CgAsyncReady;
         fn cg_async_tx_start(frame: sink CgAsyncRx[d], tx_index: isize)
             -> CgAsyncTx[d] {
           let mut in_flight: CgAsyncTx[d] = {
             frame.index, tx_index
           };
           return in_flight;
         }
         fn cg_async_tx_complete(in_flight: sink CgAsyncTx[d])
             -> CgAsyncReady {
           return view CgAsyncReady;
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, fn) -> fn
        | None -> Alcotest.failf "%s not found" name
      in
      let start = find "cg_async_tx_start" in
      let complete = find "cg_async_tx_complete" in
      let start_ir = Llvm.string_of_llvalue start in
      let complete_ir = Llvm.string_of_llvalue complete in
      let tx_layout = match Hashtbl.find_opt Llvm_gen.struct_lltypes "CgAsyncTx" with
        | Some llty -> llty
        | None -> Alcotest.fail "CgAsyncTx layout not found"
      in
      Alcotest.(check int) "RX aggregate plus TX descriptor index parameters"
        2 (Array.length (Llvm.params start));
      Alcotest.(check int) "completion receives the in-flight aggregate"
        1 (Array.length (Llvm.params complete));
      Alcotest.(check int) "in-flight owner keeps RX index and TX slot"
        2 (Array.length (Llvm.struct_element_types tx_layout));
      Alcotest.(check bool) "start reads RX runtime fields" true
        (contains_substring start_ir "extractvalue");
      Alcotest.(check bool) "completion permit erases to void" true
        (contains_substring complete_ir "define void @cg_async_tx_complete"));

  Alcotest.test_case
    "addr identity ABI: pointer remains runtime and indexed guard erases"
    `Quick
    (fun () ->
      let src =
        "linear view CgAddrGuard7[lock: addr];
         fn cg_addr_lock7(m: *i32 @ lock) -> CgAddrGuard7[lock] {
           return view CgAddrGuard7[lock];
         }
         fn cg_addr_unlock7(g: sink CgAddrGuard7[lock], m: *i32 @ lock) {}
         let mut cg_addr_word7: i32;
         fn cg_addr_use7() {
           let g = cg_addr_lock7(&cg_addr_word7);
           cg_addr_unlock7(g, &cg_addr_word7);
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, f) -> f
        | None -> Alcotest.failf "%s not found" name
      in
      let lock = find "cg_addr_lock7" in
      let unlock = find "cg_addr_unlock7" in
      let use = find "cg_addr_use7" in
      Alcotest.(check int) "lock keeps only its runtime pointer"
        1 (Array.length (Llvm.params lock));
      Alcotest.(check int) "unlock erases its guard and keeps its pointer"
        1 (Array.length (Llvm.params unlock));
      let lock_ir = Llvm.string_of_llvalue lock in
      let use_ir = Llvm.string_of_llvalue use in
      Alcotest.(check bool) "guard result lowers to void" true
        (contains_substring lock_ir "define void @cg_addr_lock7(ptr");
      Alcotest.(check bool) "no address-to-integer proof encoding" false
        (contains_substring use_ir "ptrtoint");
      Alcotest.(check bool) "no integer-to-address proof encoding" false
        (contains_substring use_ir "inttoptr"));

  Alcotest.test_case
    "finite-state dispatch ABI: existential view payloads erase to the runtime tag"
    `Quick
    (fun () ->
      let src =
        "enum CgTcpState7: u8 { Listen; SynRcvd; }
         linear view CgTcpConn7[conn: usize, state: CgTcpState7];
         variant CgTcpDispatch7 {
           Listen(exists conn: usize.
             CgTcpConn7[conn, CgTcpState7::Listen]);
           SynRcvd(exists conn: usize.
             CgTcpConn7[conn, CgTcpState7::SynRcvd]);
         }
         fn cg_tcp_syn7(c: sink CgTcpConn7[conn, CgTcpState7::Listen])
             -> CgTcpConn7[conn, CgTcpState7::SynRcvd] {
           return view CgTcpConn7[conn, CgTcpState7::SynRcvd];
         }
         fn cg_tcp_step7(value: CgTcpDispatch7) -> CgTcpDispatch7 {
           match value {
             CgTcpDispatch7::Listen(c) => {
               return CgTcpDispatch7::SynRcvd(cg_tcp_syn7(c));
             }
             CgTcpDispatch7::SynRcvd(c) => {
               return CgTcpDispatch7::SynRcvd(c);
             }
           }
         }" in
      ignore (gen_codegen src);
      let layout = match Hashtbl.find_opt Llvm_gen.variant_lltypes "CgTcpDispatch7" with
        | Some llty -> llty
        | None -> Alcotest.fail "CgTcpDispatch7 layout not found" in
      Alcotest.(check int) "only the i32 runtime state tag remains" 1
        (Array.length (Llvm.struct_element_types layout));
      let step = match Hashtbl.find_opt Llvm_gen.functions "cg_tcp_step7" with
        | Some (_, f) -> f
        | None -> Alcotest.fail "cg_tcp_step7 not found" in
      let transition = match Hashtbl.find_opt Llvm_gen.functions "cg_tcp_syn7" with
        | Some (_, f) -> f
        | None -> Alcotest.fail "cg_tcp_syn7 not found" in
      Alcotest.(check int) "state transition has no runtime view parameter"
        0 (Array.length (Llvm.params transition));
      let ir = Llvm.string_of_llvalue step in
      Alcotest.(check bool) "dispatch switches on the retained runtime tag" true
        (contains_substring ir "switch i32");
      Alcotest.(check bool) "no erased view payload is extracted" false
        (contains_substring ir "variant.c"));

  Alcotest.test_case
    "Slice 6 ABI: indexed view transitions erase every static and Delta operand" `Quick
    (fun () ->
      let src =
        "linear view CgIndexedPhase6[slot: usize, state: u8];
         fn cgiv6_begin(index: usize @ slot) -> CgIndexedPhase6[slot, 0] {
           return view CgIndexedPhase6[slot, 0];
         }
         fn cgiv6_advance(p: sink CgIndexedPhase6[slot, 0])
             -> CgIndexedPhase6[slot, 1] {
           return view CgIndexedPhase6[slot, 1];
         }
         fn cgiv6_finish(p: sink CgIndexedPhase6[slot, 1]) {}
         fn cgiv6_use(index: usize) {
           let open = cgiv6_begin(index);
           let ready = cgiv6_advance(open);
           cgiv6_finish(ready);
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, f) -> f
        | None -> Alcotest.failf "%s not found" name
      in
      let begin_fn = find "cgiv6_begin" in
      let advance = find "cgiv6_advance" in
      let finish = find "cgiv6_finish" in
      let use = find "cgiv6_use" in
      Alcotest.(check int) "begin keeps only its runtime index"
        1 (Array.length (Llvm.params begin_fn));
      Alcotest.(check int) "transition has no runtime view parameter"
        0 (Array.length (Llvm.params advance));
      Alcotest.(check int) "sink has no runtime view parameter"
        0 (Array.length (Llvm.params finish));
      let advance_ir = Llvm.string_of_llvalue advance in
      let use_ir = Llvm.string_of_llvalue use in
      Alcotest.(check bool) "transition lowers to void" true
        (contains_substring advance_ir "define void @cgiv6_advance()");
      Alcotest.(check bool) "use calls the erased transition with no operands" true
        (contains_substring use_ir "call void @cgiv6_advance()");
      Alcotest.(check bool) "use calls the erased sink with no operands" true
        (contains_substring use_ir "call void @cgiv6_finish()"));

  Alcotest.test_case
    "Slice 6 ABI: a singleton preserves its refined range for array bounds" `Quick
    (expect_trap_sites 0
       "let mut cgiv6_slots: [u8; 2];
        fn cgiv6_index(index: {0..<2 as usize} @ slot) -> u8 {
          cgiv6_slots[index] = 'X';
          return cgiv6_slots[index];
        }");

  Alcotest.test_case
    "Slice 6 ABI: a fixed-index view variant payload still contributes only its tag" `Quick
    (fun () ->
      let src =
        "linear view CgIndexedPermit6[slot: usize];
         variant CgIndexedMaybe6 {
           Empty;
           Held(CgIndexedPermit6[0]);
         }
         fn cgiv6_wrap() -> CgIndexedMaybe6 {
           return CgIndexedMaybe6::Held(view CgIndexedPermit6[0]);
         }
         fn cgiv6_drop(p: sink CgIndexedPermit6[0]) {}
         fn cgiv6_open(value: CgIndexedMaybe6) {
           match value {
             CgIndexedMaybe6::Empty => {}
             CgIndexedMaybe6::Held(p) => { cgiv6_drop(p); }
           }
         }" in
      ignore (gen_codegen src);
      let layout = match Hashtbl.find_opt Llvm_gen.variant_lltypes "CgIndexedMaybe6" with
        | Some llty -> llty
        | None -> Alcotest.fail "CgIndexedMaybe6 layout not found" in
      Alcotest.(check int) "only the runtime tag remains" 1
        (Array.length (Llvm.struct_element_types layout)));

  Alcotest.test_case
    "Slice 5 ABI: function pointer effect contracts erase" `Quick
    (fun () ->
      ignore (gen_codegen
        "fn cgeffect_target5() !{} {}
         fn cgeffect_indirect5(callback: fn !{}() -> void) !{} {
           callback();
         }");
      match Hashtbl.find_opt Llvm_gen.functions "cgeffect_indirect5" with
      | Some (_, f) ->
          Alcotest.(check int) "only the runtime callback parameter remains"
            1 (Array.length (Llvm.params f));
          Alcotest.(check bool) "callback parameter is an opaque pointer"
            true
            (Llvm.classify_type (Llvm.type_of (Llvm.param f 0)) =
             Llvm.TypeKind.Pointer)
      | None -> Alcotest.fail "function 'cgeffect_indirect5' not found");

  Alcotest.test_case "Exception ABI: extern noreturn reaches LLVM" `Quick
    (fun () ->
      ignore (gen_codegen
        "extern fn cg_exception_stop5() !{noreturn};
         fn cg_exception_call5() { cg_exception_stop5(); }");
      let ir = Llvm.string_of_llmodule !Llvm_gen.the_module in
      Alcotest.(check bool) "noreturn attribute" true
        (contains_substring ir "noreturn"));

  Alcotest.test_case "noinline fn reaches LLVM as a real function attribute" `Quick
    (fun () ->
      ignore (gen_codegen
        "noinline fn cg_noinline_target6() -> i32 { return 1; }
         fn cg_noinline_call6() -> i32 { return cg_noinline_target6(); }");
      let ir = Llvm.string_of_llmodule !Llvm_gen.the_module in
      Alcotest.(check bool) "noinline attribute" true
        (contains_substring ir "noinline"));

  Alcotest.test_case
    "Slice 4 ABI: checker effects add no runtime parameters" `Quick
    (fun () ->
      ignore (gen_codegen "fn cgeffect4() !{may_block} {}");
      match Hashtbl.find_opt Llvm_gen.functions "cgeffect4" with
      | Some (_, f) ->
          Alcotest.(check int) "runtime parameter count" 0
            (Array.length (Llvm.params f))
      | None -> Alcotest.fail "function 'cgeffect4' not found");

  Alcotest.test_case
    "Slice 4 ABI: borrow mut passes the caller's owner storage by pointer" `Quick
    (fun () ->
      let src =
        "linear struct CgMutableOwner4[n: usize] { idx: usize @ n; value: i32; }
         variant CgMutableResult4 {
           Opened(exists n: usize. CgMutableOwner4[n]);
         }
         fn cgm4_make(idx: usize @ n) -> CgMutableOwner4[n] {
           let mut owner: CgMutableOwner4[n] = { idx, 0 };
           return owner;
         }
         fn cgm4_set(owner: borrow mut CgMutableOwner4[n], value: i32) {
           owner.value = value;
         }
         fn cgm4_drop(owner: sink CgMutableOwner4[n]) {}
         fn cgm4_use(idx: usize) {
           let result: CgMutableResult4 = CgMutableResult4::Opened(cgm4_make(idx));
           match result {
             CgMutableResult4::Opened(mut owner) => {
               cgm4_set(owner, 9);
               cgm4_drop(owner);
             }
           }
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, f) -> f
        | None -> Alcotest.failf "%s not found" name
      in
      let set = find "cgm4_set" in
      let use = find "cgm4_use" in
      Alcotest.(check int) "mutable borrow plus value parameters"
        2 (Array.length (Llvm.params set));
      Alcotest.(check bool) "first parameter is an opaque pointer"
        true (Llvm.classify_type (Llvm.type_of (Llvm.param set 0)) = Llvm.TypeKind.Pointer);
      let set_ir = Llvm.string_of_llvalue set in
      let use_ir = Llvm.string_of_llvalue use in
      Alcotest.(check bool) "callee writes through borrowed storage" true
        (contains_substring set_ir "getelementptr" && contains_substring set_ir "store i32");
      Alcotest.(check bool) "caller passes a pointer, not an aggregate copy" true
        (contains_substring use_ir "call void @cgm4_set(ptr"));

  Alcotest.test_case
    "region borrow ABI: pointer and slice parameters keep their runtime ABI"
    `Quick
    (fun () ->
      ignore (gen_codegen
        "fn cg_region_ptr(p: borrow *u8) -> u8 { return p[0]; }
         fn cg_region_slice(s: borrow [u8; 4..]) -> u8 { return s[0]; }");
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, f) -> f
        | None -> Alcotest.failf "%s not found" name
      in
      let ptr = find "cg_region_ptr" in
      let slice = find "cg_region_slice" in
      Alcotest.check Alcotest.int "raw pointer stays one pointer" 1
        (Array.length (Llvm.params ptr));
      Alcotest.check Alcotest.bool "raw pointer parameter ABI" true
        (Llvm.classify_type (Llvm.type_of (Llvm.param ptr 0)) =
         Llvm.TypeKind.Pointer);
      Alcotest.check Alcotest.int "slice stays one fat-value parameter" 1
        (Array.length (Llvm.params slice));
      Alcotest.check Alcotest.bool "slice aggregate ABI" true
        (Llvm.classify_type (Llvm.type_of (Llvm.param slice 0)) =
         Llvm.TypeKind.Struct))
  ;

  Alcotest.test_case
    "Slice 1 ABI: static indices erase while the runtime index stays in the aggregate" `Quick
    (fun () ->
      let src =
        "linear struct CgLease[n: usize] { idx: {0..<4 as usize} @ n; }
         let mut cg_slots: [i32; 4];
         fn cg_make(idx: {0..<4 as usize} @ n) -> CgLease[n] {
           let mut x: CgLease[n] = { idx }; return x;
         }
         fn cg_read(x: borrow CgLease[n]) -> i32 { return cg_slots[x.idx]; }
         fn cg_drop(x: sink CgLease[n]) {}
         fn cg_use() -> i32 {
           let x = cg_make(2); let v = cg_read(x); cg_drop(x); return v;
         }" in
      ignore (gen_codegen src);
      Alcotest.(check int) "no bounds trap remains" 0
        (List.length !Llvm_gen.trap_sites);
      match Hashtbl.find_opt Llvm_gen.functions "cg_read" with
      | None -> Alcotest.fail "cg_read not found"
      | Some (_, f) ->
          let ir = Llvm.string_of_llvalue f in
          Alcotest.(check bool) "runtime field is extracted" true
            (contains_substring ir "extractvalue");
          Alcotest.(check bool) "no pointer-bit encoding" false
            (contains_substring ir "inttoptr" || contains_substring ir "ptrtoint"));

  Alcotest.test_case
    "Slice 1 ABI: a mutable indexed owner field is real writable storage" `Quick
    (fun () ->
      let src =
        "linear struct CgMutable[n: usize] { idx: usize @ n; value: i32; }
         fn cgm_make(idx: usize @ n) -> CgMutable[n] {
           let mut x: CgMutable[n] = { idx, 0 }; return x;
         }
         fn cgm_set(x: CgMutable[n], value: i32) -> CgMutable[n] {
           x.value = value; return x;
         }
         fn cgm_drop(x: sink CgMutable[n]) {}
         fn cgm_use() {
           let x = cgm_make(2); let x = cgm_set(x, 7); cgm_drop(x);
         }" in
      ignore (gen_codegen src);
      match Hashtbl.find_opt Llvm_gen.functions "cgm_set" with
      | None -> Alcotest.fail "cgm_set not found"
      | Some (_, f) ->
          let ir = Llvm.string_of_llvalue f in
          Alcotest.(check bool) "field store uses aggregate storage" true
            (contains_substring ir "getelementptr" && contains_substring ir "store i32"));

  Alcotest.test_case
    "Slice 2 ABI: erased views occupy no parameter, return, alloca, or call operand" `Quick
    (fun () ->
      let src =
        "private linear view CgPendingView;
         fn cgv_mint() -> CgPendingView { return view CgPendingView; }
         fn cgv_consume(p: sink CgPendingView, value: i32) -> i32 {
           return value;
         }
         fn cgv_use(value: i32) -> i32 {
           let p: CgPendingView = cgv_mint();
           return cgv_consume(p, value);
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, f) -> f
        | None -> Alcotest.failf "%s not found" name
      in
      let mint = find "cgv_mint" in
      let consume = find "cgv_consume" in
      let use = find "cgv_use" in
      Alcotest.(check int) "mint has zero runtime parameters"
        0 (Array.length (Llvm.params mint));
      Alcotest.(check int) "consume keeps only its i32 parameter"
        1 (Array.length (Llvm.params consume));
      let mint_ir = Llvm.string_of_llvalue mint in
      let consume_ir = Llvm.string_of_llvalue consume in
      let use_ir = Llvm.string_of_llvalue use in
      Alcotest.(check bool) "mint lowers to void" true
        (contains_substring mint_ir "define void @cgv_mint()");
      Alcotest.(check bool) "mint has no token alloca" false
        (contains_substring mint_ir "alloca" || contains_substring mint_ir "i1");
      Alcotest.(check bool) "consumer signature has no token" false
        (contains_substring consume_ir "i1");
      Alcotest.(check bool) "use calls zero-ABI mint" true
        (contains_substring use_ir "call void @cgv_mint()");
      Alcotest.(check bool) "use passes only the runtime i32" true
        (contains_substring use_ir "call i32 @cgv_consume(i32"));

  Alcotest.test_case
    "Slice 2 ABI: mutable view self-transforms remain storage-free" `Quick
    (fun () ->
      let src =
        "linear view CgMutableView;
         fn cgvm_mint() -> CgMutableView { return view CgMutableView; }
         fn cgvm_transform(p: CgMutableView) -> CgMutableView { return p; }
         fn cgvm_consume(p: sink CgMutableView) {}
         fn cgvm_use() {
           let mut p: CgMutableView = cgvm_mint();
           p = cgvm_transform(p);
           cgvm_consume(p);
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, f) -> f
        | None -> Alcotest.failf "%s not found" name
      in
      let transform = find "cgvm_transform" in
      let use = find "cgvm_use" in
      Alcotest.(check int) "transform has no runtime parameters"
        0 (Array.length (Llvm.params transform));
      let transform_ir = Llvm.string_of_llvalue transform in
      let use_ir = Llvm.string_of_llvalue use in
      Alcotest.(check bool) "transform lowers to void" true
        (contains_substring transform_ir "define void @cgvm_transform()");
      Alcotest.(check bool) "mutable view has no runtime slot" false
        (contains_substring use_ir "alloca" || contains_substring use_ir "i1");
      Alcotest.(check bool) "self-transform is still emitted as a call" true
        (contains_substring use_ir "call void @cgvm_transform()"));

  Alcotest.test_case
    "Slice 3 ABI: variant keeps its tag and existential owner's runtime payload" `Quick
    (fun () ->
      let src =
        "linear struct CgVariantOwner3[n: usize] {
           idx: {0..<4 as usize} @ n;
           len: i32;
         }
         variant CgVariantMaybe3 {
           None;
           Some(exists n: usize. CgVariantOwner3[n]);
         }
         fn cgv3_make(idx: {0..<4 as usize} @ n, len: i32)
             -> CgVariantOwner3[n] {
           let mut owner: CgVariantOwner3[n] = { idx, len };
           return owner;
         }
         fn cgv3_wrap(idx: {0..<4 as usize}, len: i32) -> CgVariantMaybe3 {
           return CgVariantMaybe3::Some(cgv3_make(idx, len));
         }
         fn cgv3_drop(owner: sink CgVariantOwner3[n]) {}
         fn cgv3_use(value: CgVariantMaybe3) -> i32 {
           match value {
             CgVariantMaybe3::None => { return -1; }
             CgVariantMaybe3::Some(owner) => {
               let len: i32 = owner.len;
               cgv3_drop(owner);
               return len;
             }
           }
         }" in
      ignore (gen_codegen src);
      let layout = match Hashtbl.find_opt Llvm_gen.variant_lltypes "CgVariantMaybe3" with
        | Some llty -> llty
        | None -> Alcotest.fail "CgVariantMaybe3 layout not found" in
      Alcotest.(check int) "tag plus one runtime payload field" 2
        (Array.length (Llvm.struct_element_types layout));
      let use = match Hashtbl.find_opt Llvm_gen.functions "cgv3_use" with
        | Some (_, f) -> f
        | None -> Alcotest.fail "cgv3_use not found" in
      let ir = Llvm.string_of_llvalue use in
      Alcotest.(check bool) "match switches on the runtime tag" true
        (contains_substring ir "switch i32");
      Alcotest.(check bool) "Some opens the owner aggregate" true
        (contains_substring ir "extractvalue");
      Alcotest.(check bool) "no static identity is pointer-bit encoded" false
        (contains_substring ir "inttoptr" || contains_substring ir "ptrtoint"));

  Alcotest.test_case
    "Slice 3 ABI: a view payload contributes kind but only the tag survives" `Quick
    (fun () ->
      let src =
        "linear view CgVariantPermit3;
         variant CgVariantViewMaybe3 {
           Empty;
           Held(CgVariantPermit3);
         }
         fn cgv_view3_wrap(c: bool) -> CgVariantViewMaybe3 {
           if (c) { return CgVariantViewMaybe3::Empty; }
           return CgVariantViewMaybe3::Held(view CgVariantPermit3);
         }
         fn cgv_view3_sink(p: sink CgVariantPermit3) {}
         fn cgv_view3_use(value: CgVariantViewMaybe3) {
           match value {
             CgVariantViewMaybe3::Empty => {}
             CgVariantViewMaybe3::Held(p) => { cgv_view3_sink(p); }
           }
         }" in
      ignore (gen_codegen src);
      let layout = match Hashtbl.find_opt Llvm_gen.variant_lltypes "CgVariantViewMaybe3" with
        | Some llty -> llty
        | None -> Alcotest.fail "CgVariantViewMaybe3 layout not found" in
      Alcotest.(check int) "only the i32 tag remains" 1
        (Array.length (Llvm.struct_element_types layout));
      let wrap = match Hashtbl.find_opt Llvm_gen.functions "cgv_view3_wrap" with
        | Some (_, f) -> f
        | None -> Alcotest.fail "cgv_view3_wrap not found" in
      let ir = Llvm.string_of_llvalue wrap in
      Alcotest.(check bool) "runtime return is the one-field tagged aggregate" true
        (contains_substring ir "{ i32 }");
      Alcotest.(check bool) "no erased payload slot is emitted" false
        (contains_substring ir "{ i32, i1 }"));

  Alcotest.test_case
    "plain variant storage copies a typed struct payload without pointer encoding" `Quick
    (fun () ->
      let src =
        "struct CgRequestArgs3b { left: i32; right: i32; }
         variant CgRequest3b { Stop; Add(CgRequestArgs3b); }
         struct CgRequestSlot3b { value: CgRequest3b; }
         fn cgr3b_make(left: i32, right: i32) -> CgRequest3b {
           let mut args: CgRequestArgs3b = { left, right };
           return CgRequest3b::Add(args);
         }
         fn cgr3b_put(slot: *CgRequestSlot3b, value: CgRequest3b) {
           slot.value = value;
         }
         fn cgr3b_take(slot: *CgRequestSlot3b) -> CgRequest3b {
           return slot.value;
         }
         fn cgr3b_sum(value: CgRequest3b) -> i32 {
           match value {
             CgRequest3b::Stop => { return 0; }
             CgRequest3b::Add(args) => { return args.left + args.right; }
           }
         }" in
      ignore (gen_codegen src);
      let find name = match Hashtbl.find_opt Llvm_gen.functions name with
        | Some (_, fn) -> fn
        | None -> Alcotest.failf "%s not found" name
      in
      let put_ir = Llvm.string_of_llvalue (find "cgr3b_put") in
      let take_ir = Llvm.string_of_llvalue (find "cgr3b_take") in
      let sum_ir = Llvm.string_of_llvalue (find "cgr3b_sum") in
      Alcotest.(check bool) "slot stores the tagged aggregate" true
        (contains_substring put_ir "store {");
      Alcotest.(check bool) "slot loads the tagged aggregate" true
        (contains_substring take_ir "load {");
      Alcotest.(check bool) "payload fields are read from the copied value" true
        (contains_substring sum_ir "extractvalue");
      Alcotest.(check bool) "request transport uses no integer-pointer bridge" false
        (contains_substring put_ir "inttoptr"
         || contains_substring put_ir "ptrtoint"));

  Alcotest.test_case
    "stable owner exchange lowers to one typed load and store under an erased guard" `Quick
    (fun () ->
      let src =
        "linear view CgStableGuard3c[lock: addr];
         linear struct CgStableOwner3c[n: usize] {
           id: usize @ n;
           value: i32;
         }
         variant CgStableValue3c {
           Empty;
           Full(exists n: usize. CgStableOwner3c[n]);
         }
         struct CgStableSlot3c {
           private mutex: i32;
           private value: CgStableValue3c;
         }
         private let mut cg_stable_slot3c: CgStableSlot3c;
         fn cg_stable_lock3c(m: *i32 @ lock) -> CgStableGuard3c[lock] {
           return view CgStableGuard3c[lock];
         }
         fn cg_stable_unlock3c(g: sink CgStableGuard3c[lock],
                               m: *i32 @ lock) {}
         fn cg_stable_exchange3c(replacement: CgStableValue3c)
             -> CgStableValue3c {
           let guard = cg_stable_lock3c(&cg_stable_slot3c.mutex);
           let previous: CgStableValue3c = stable_replace(
             guard, &cg_stable_slot3c.mutex, cg_stable_slot3c.value,
             replacement);
           cg_stable_unlock3c(guard, &cg_stable_slot3c.mutex);
           return previous;
         }" in
      ignore (gen_codegen src);
      let exchange = match Hashtbl.find_opt Llvm_gen.functions
          "cg_stable_exchange3c" with
        | Some (_, fn) -> fn
        | None -> Alcotest.fail "cg_stable_exchange3c not found"
      in
      let ir = Llvm.string_of_llvalue exchange in
      Alcotest.(check int) "erased guard leaves only the replacement parameter"
        1 (Array.length (Llvm.params exchange));
      Alcotest.(check bool) "stable slot loads the old owner package" true
        (contains_substring ir "stable_old = load");
      Alcotest.(check bool) "stable slot stores the replacement package" true
        (contains_substring ir "store {");
      Alcotest.(check bool) "stable exchange does not encode ownership in pointer bits" false
        (contains_substring ir "inttoptr" || contains_substring ir "ptrtoint"));


  Alcotest.test_case "overloads emit mangled symbols and direct calls use the selected symbol" `Quick
    (fun () ->
       gen_codegen
         "fn codegen_overload(v: i32) -> i32 { return v; }
          fn codegen_overload(v: u32) -> u32 { return v; }
          fn codegen_overload_use(a: i32, b: u32) -> i32 {
            return codegen_overload(a) + (codegen_overload(b) as i32);
          }";
       Alcotest.(check bool) "i32 symbol" true
         (Hashtbl.mem Llvm_gen.functions "_TK_codegen_overload__i32");
       Alcotest.(check bool) "u32 symbol" true
         (Hashtbl.mem Llvm_gen.functions "_TK_codegen_overload__u32");
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_overload_use" with
         | Some (_, fn) -> fn | None -> Alcotest.fail "caller was not emitted" in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "calls i32 overload" true
         (contains_substring ir "@_TK_codegen_overload__i32");
       Alcotest.(check bool) "calls u32 overload" true
         (contains_substring ir "@_TK_codegen_overload__u32"));

  Alcotest.test_case
    "offsetof uses the target DataLayout for normal and packed structs"
    `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"aarch64-none-elf" ()
       in
       let _ = gen_codegen
         "struct OffsetNormal { tag: u8; value: i32; }
          struct packed OffsetPacked { tag: u8; value: i32; }
          fn offset_normal_value() usize { return offsetof(OffsetNormal, value); }
          fn offset_packed_value() usize { return offsetof(OffsetPacked, value); }"
       in
       let function_ir name =
         match Hashtbl.find_opt Llvm_gen.functions name with
         | Some (_, fn) -> Llvm.string_of_llvalue fn
         | None -> Alcotest.failf "function '%s' not found" name
       in
       Alcotest.(check bool) "normal field offset includes padding" true
         (contains_substring (function_ir "offset_normal_value") "ret i64 4");
       Alcotest.(check bool) "packed field offset has no padding" true
         (contains_substring (function_ir "offset_packed_value") "ret i64 1"));

  (* GitHub issue #77: sizeof(...)/offsetof(...) from a packed struct must
     prove a subslice bound with zero trap sites, whether used directly or
     threaded through a local `let` -- reproduces the exact shapes reported
     as failing (direct use, sizeof via a let, offsetof via a let). *)
  Alcotest.test_case
    "issue #77: sizeof/offsetof from a packed struct prove subslice bounds \
     (direct, via let, offsetof via let)"
    `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"aarch64-none-elf" ()
       in
       expect_trap_sites 0
         "struct packed Issue77Hdr { a: u8; b: u8; c: u16; }
          let mut issue77_buf: [u8; 64];
          fn issue77_direct() {
            let s: []u8 = issue77_buf as []u8;
            let sub = s[0..<sizeof(Issue77Hdr)];
          }
          fn issue77_sizeof_via_let() {
            let s: []u8 = issue77_buf as []u8;
            let n: usize = sizeof(Issue77Hdr);
            let sub = s[0..<n];
          }
          fn issue77_offsetof_via_let() {
            let s: []u8 = issue77_buf as []u8;
            let off: usize = offsetof(Issue77Hdr, c);
            let sub = s[off..<off + 2];
          }" ());

  (* Negative control: a NON-packed struct's sizeof (target-dependent
     layout) must still require a runtime check -- confirms the #77 fix
     does not over-claim provability for cases it cannot actually know. *)
  Alcotest.test_case
    "issue #77 negative control: sizeof of a non-packed struct still traps"
    `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"aarch64-none-elf" ()
       in
       expect_trap_sites 1
         "struct Issue77NonPacked { a: i32; b: i16; }
          let mut issue77_np_buf: [u8; 64];
          fn issue77_non_packed() {
            let s: []u8 = issue77_np_buf as []u8;
            let sub = s[0..<sizeof(Issue77NonPacked)];
          }" ());

  Alcotest.test_case
    "DMA/device barriers lower to AArch64 DSB intrinsics" `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_barriers_aarch64() {
            dma_publish();
            dma_consume();
            device_fence();
            signal_fence();
            interrupt_wait();
            interrupt_notify();
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_barriers_aarch64" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_barriers_aarch64 was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check int) "three dsb calls" 3
         (count_substring ir "llvm.aarch64.dsb");
       Alcotest.(check bool) "event wait" true (contains_substring ir "wfe");
       Alcotest.(check bool) "event notify" true (contains_substring ir "sev"));

  Alcotest.test_case
    "checked usize arithmetic lowers to LLVM overflow intrinsics without traps"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "variant CheckedUsize { Value(usize); Overflow; }
          fn checked_ops(a: usize, b: usize) -> usize {
            let mut total: usize = 0;
            match checked_add_usize(a, b) {
              CheckedUsize::Value(value) => { total = value; }
              CheckedUsize::Overflow => { total = 1; }
            }
            match checked_mul_usize(a, b) {
              CheckedUsize::Value(value) => { total = value; }
              CheckedUsize::Overflow => { total = 2; }
            }
            return total;
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "checked_ops" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "checked_ops was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "checked add" true
         (contains_substring ir "llvm.uadd.with.overflow.i64");
       Alcotest.(check bool) "checked multiply" true
         (contains_substring ir "llvm.umul.with.overflow.i64");
       Alcotest.(check bool) "no trap" false
         (contains_substring ir "llvm.trap"));

  Alcotest.test_case
    "indexed struct field assignment codegens through the element address"
    `Quick
    (expect_trap_sites 0
       "struct CodegenIndexedDesc { status: u32; length: u32; }
        let mut codegen_indexed_descs: [CodegenIndexedDesc; 4];
        fn codegen_indexed_store(i: {0..<4 as usize}) {
          codegen_indexed_descs[i].status = 1 as u32;
          codegen_indexed_descs[i].length += 16 as u32;
        }");

  Alcotest.test_case
    "dynamic indexed struct field assignment retains the array bounds trap"
    `Quick
    (expect_trap_sites 1
       "struct CodegenCheckedDesc { status: u32; }
        let mut codegen_checked_descs: [CodegenCheckedDesc; 4];
        fn codegen_checked_store(i: usize) {
          codegen_checked_descs[i].status = 1 as u32;
        }");

  Alcotest.test_case
    "pointer-indexed io struct field assignment emits a volatile store"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "struct CodegenIoReg { value: u32; }
          fn codegen_io_indexed_store(p: *io CodegenIoReg, i: isize) {
            p[i].value = 1 as u32;
          }"
       in
       match Hashtbl.find_opt Llvm_gen.functions "codegen_io_indexed_store" with
       | Some (_, fn) ->
           Alcotest.(check bool) "volatile store" true
             (contains_substring (Llvm.string_of_llvalue fn) "store volatile")
       | None -> Alcotest.fail "function 'codegen_io_indexed_store' not found");

  Alcotest.test_case
    "assigning to a field through a dereferenced struct pointer codegens \
     a GEP on the pointer, not on a loaded struct value \
     (regression: GitHub issue #211 -- gen_expr's Deref case loads the \
     whole struct for a read, and the old Assign/FieldGet codegen called \
     it unconditionally, so getelementptr ran on that loaded aggregate \
     value instead of the pointer, which LLVM's IR verifier rejects)"
    `Quick
    (expect_codegen_ok
       "struct CodegenPair { a: usize; b: usize; }
        fn codegen_deref_field_store(p: *CodegenPair) -> usize {
          (*p).a = 1;
          return (*p).a;
        }");

  Alcotest.test_case
    "assigning to an array field through a dereferenced struct pointer \
     codegens without crashing (same regression as the scalar-field case \
     above, GitHub issue #211, confirmed to hit the same codegen path \
     with an aggregate array-typed field instead of a scalar one)"
    `Quick
    (expect_codegen_ok
       "struct CodegenPoolState { data: [usize; 4]; head: usize; }
        fn codegen_deref_array_field_store(p: *CodegenPoolState) -> usize {
          (*p).head = 1;
          return (*p).head;
        }");

  Alcotest.test_case
    "u8 loaded via array indexing compares against a u8 cast literal \
     (regression: both must be i32-widened in-flight, or LLVM's verifier \
     rejects the mismatched icmp operand widths)" `Quick
    (expect_codegen_ok
       "fn codegen_u8_index_cmp_array(p: *u8) -> i32 {
          let mut a: [u8; 4];
          a[0] = 6 as u8;
          if (a[0] == 6 as u8) { return 1; }
          return 0;
        }");

  (* GitHub issue #217: struct_ptr.array_field[i] -- no manual `let`
     workaround -- now goes through the SAME checked TArray/
     emit_bounds_check codegen path a local array's own indexing already
     gets, instead of silently decaying to unchecked raw-pointer
     arithmetic with no trap site at all. An unproven index records a
     real trap site (the acceptance bar this issue's own text names);
     a provably-in-range index still elides it, matching ordinary local
     array indexing's existing elision behavior. *)
  Alcotest.test_case
    "struct-field array WRITE with an unproven index records a real \
     trap site (issue #217 Gap 2: was silently zero before this fix)" `Quick
    (expect_trap_sites 1
       "struct Core217 { next_free: [usize; 8]; free_head: usize; }
        fn core217_push(core: *Core217, i: usize) {
          core.next_free[i] = core.free_head;
        }");

  Alcotest.test_case
    "struct-field array READ with an unproven index records a real \
     trap site (issue #217 Gap 2, read side)" `Quick
    (expect_trap_sites 1
       "struct Core217R { next_free: [usize; 8]; }
        fn core217_get(core: *Core217R, i: usize) -> usize {
          return core.next_free[i];
        }");

  Alcotest.test_case
    "struct-field array indexing with a PROVEN {0..<8} index still elides \
     the bounds check (issue #217 does not regress existing elision)" `Quick
    (expect_trap_sites 0
       "struct Core217P { next_free: [usize; 8]; free_head: usize; }
        fn core217_proven(core: *Core217P, i: {0..<8 as usize}) {
          core.next_free[i] = core.free_head;
        }");

  (* GitHub issue #296 codegen-sync regression: type_inf.ml's fallthrough
     narrowing after an early-return guard proved sound (a function CALL
     requiring the narrowed type compiled fine, per this file's own
     type_inf-level #296 tests), but llvm_gen.ml's OWN, separate
     re-derivation of narrowing (narrowing_ctx/locals -- gen_expr cannot
     see type_inf's resolved tyenv) was never extended to match, so an
     Index consuming the SAME narrowed variable right after the guard
     kept an unnecessary residual bounds check under --forbid-trap. Found
     while migrating kernel/lib/growable_pool.tkb off its #217 decay
     workaround -- the exact `if (index >= N) { return; } ...
     pool.field[index] ...` shape used throughout that file. Both
     immutable and mutable/parameter cases, since #296 covers both. *)
  Alcotest.test_case
    "early-return guard narrowing elides the bounds check for an Index \
     consumer, not just a function-call consumer (issue #296 codegen \
     sync)" `Quick
    (expect_trap_sites 0
       "fn f296a(idx: usize) -> usize {
          let mut buf: [usize; 6];
          if (idx >= 6) { return 0; }
          return buf[idx];
        }");

  Alcotest.test_case
    "const-expression if narrowing and codegen agree for a same-base subslice" `Quick
    (expect_trap_sites 0
       "const CAPACITY: usize = 4096;
        const WIDTH: usize = 1024;
        fn f(storage: [u8; CAPACITY..], offset: usize) -> usize {
          if (offset < CAPACITY - WIDTH + 1) {
            let bounded: {0..<CAPACITY - WIDTH + 1 as usize} = offset;
            return storage[bounded..<bounded + WIDTH].len;
          }
          return 0;
        }");

  Alcotest.test_case
    "early-return guard narrowing elides the bounds check for an Index \
     consumer through a struct field, matching the real \
     kernel/lib/growable_pool.tkb shape (issue #296 codegen sync)" `Quick
    (expect_trap_sites 0
       "struct Pool296 { occ: [usize; 6]; }
        fn f296b(pool: *Pool296, idx: usize) {
          let index: usize = idx;
          if (index >= 6) { return; }
          if (pool.occ[index] == 0) { return; }
          pool.occ[index] = 0;
        }");

  Alcotest.test_case
    "early-return guard narrowing elides the bounds check for an \
     AssignIndex (write) consumer too (issue #296 codegen sync)" `Quick
    (expect_trap_sites 0
       "fn f296c(idx: usize) {
          let mut buf: [usize; 6];
          if (idx >= 6) { return; }
          buf[idx] = 1;
        }");

  (* GitHub issue #311: type_inf.ml's tyenv-based narrowing and
     llvm_gen.ml's own separate narrowing_ctx re-derivation are two
     independently-maintained implementations of the same rules, kept in
     sync only by a hand-followed "Sync rule" convention -- #296's own
     history (just above) shows this drifting silently once already. The
     three #296 tests above cover early-return-guard narrowing
     specifically; these two extend the same "prove it stays synced"
     coverage to the OTHER two narrowing constructs type_inf.ml supports
     today (plain two-sided If narrowing, and for-loop counter narrowing
     over a constant bound) so a regression in either file's handling of
     THESE ALREADY-SUPPORTED shapes fails a test immediately, not silently
     as a residual trap site discovered later by chance. This does not
     cover a genuinely NEW narrowing construct (e.g. #312's non-constant
     for-loop bound, or #313's while-condition narrowing, neither
     implemented yet) -- that gap is why issue #311 remains open as a
     design question rather than closed by this stopgap alone. *)
  Alcotest.test_case
    "plain if-condition narrowing (not just early-return-guard) elides \
     the Index bounds check (issue #311 sync coverage)" `Quick
    (expect_trap_sites 0
       "fn f311_if(idx: usize) -> usize {
          let mut buf: [usize; 6];
          if (idx < 6) { return buf[idx]; } else { return 0; }
        }");

  Alcotest.test_case
    "for-loop counter narrowing over a constant bound elides the Index \
     bounds check (issue #311 sync coverage)" `Quick
    (expect_trap_sites 0
       "fn f311_for() -> usize {
          let mut buf: [usize; 6];
          let mut total: usize = 0;
          for i: usize in 0..<6 {
            total = total + buf[i];
          }
          return total;
        }");

  (* GitHub issue #312: the unified_fd_clone_rollback-shaped case
     (kernel/kernel/fd_table.tkb, 2026-08-15) -- a for-loop's hi_expr is a
     RUNTIME parameter with its own already-proven TRefinedInt, not a
     Const_env-recognized constant. Locks in the paired type_inf.ml/
     llvm_gen.ml fix at the codegen/--forbid-trap level, matching how the
     #311 sync tests just above lock in the constant-bound case. *)
  Alcotest.test_case
    "for-loop counter over 0..<limit, where limit has its own proven \
     upper bound, elides the Index bounds check (issue #312)" `Quick
    (expect_trap_sites 0
       "fn f312_for(limit: {0..<6 as usize}) -> usize {
          let mut buf: [usize; 6];
          let mut total: usize = 0;
          for i: usize in 0..<limit {
            total = total + buf[i];
          }
          return total;
        }");

  (* GitHub issue #313: locks in the paired type_inf.ml/llvm_gen.ml fix
     (narrow_from_cond reused for While, apply_narrowing/apply_narrowing_
     mut mirrored in codegen) at the codegen/--forbid-trap level, matching
     the #311/#312 sync tests just above. `v` is never reassigned in the
     body, so the Index bounds check is elided both at the type level and
     in the generated IR. *)
  Alcotest.test_case
    "while's own condition narrows a never-reassigned binding, eliding \
     the Index bounds check (issue #313)" `Quick
    (expect_trap_sites 0
       "fn f313_while(v: usize) -> i32 {
          let mut buf: [i32; 4];
          while (v < 4) {
            return buf[v];
          }
          return 0;
        }");

  Alcotest.test_case
    "multi-level struct field chain a.b.c[i] indexes the innermost \
     array field directly (issue #217: only the OUTERMOST field needs \
     un-decayed treatment, intermediate struct fields work unmodified)"
    `Quick
    (expect_codegen_ok
       "struct Core217Inner { next_free: [usize; 4]; }
        struct Core217Outer { inner: Core217Inner; }
        fn core217_nested(o: *Core217Outer, i: {0..<4 as usize}) -> usize {
          return o.inner.next_free[i];
        }");

  Alcotest.test_case
    "u8 loaded via pointer indexing compares against a u8 cast literal \
     (same regression as above, through a *u8 parameter instead of an \
     array)" `Quick
    (expect_codegen_ok
       "fn codegen_u8_index_cmp_ptr(p: *u8) -> i32 {
          if (p[0] == 6 as u8) { return 1; }
          return 0;
        }");

  Alcotest.test_case
    "u8 as u8 cast result composes with itself across a chain of && \
     comparisons (the exact shape used in examples/arp_reply/arp_reply.tkb \
     for ARP header validation)" `Quick
    (expect_codegen_ok
       "fn codegen_u8_cast_chain(p: *u8) -> i32 {
          if (p[0] == 6 as u8 && p[1] == 4 as u8) { return 1; }
          return 0;
        }");

  (* -- --forbid-trap accounting (Llvm_gen.trap_sites) -------------------- *)

  Alcotest.test_case
    "unproven i32 array index is a compile error: array/slice indices must \
     be usize now (see require_usize_index), not just any integer type" `Quick
    (expect_type_error "must be usize"
       "let mut ftrap_buf_a0: [u8; 8];
        fn ftrap_i32_index(v: i32) -> u8 {
          return ftrap_buf_a0[v];
        }");

  Alcotest.test_case
    "unproven usize array index records exactly one trap site (the \
     residual bounds check --forbid-trap would reject)" `Quick
    (expect_trap_sites 1
       "let mut ftrap_buf_a: [u8; 8];
        fn ftrap_usize_index(v: usize) -> u8 {
          return ftrap_buf_a[v];
        }");

  Alcotest.test_case
    "refined-typed index records zero trap sites (bounds check elided by \
     the type, so the program is --forbid-trap clean)" `Quick
    (expect_trap_sites 0
       "let mut ftrap_buf_b: [u8; 8];
        fn ftrap_refined_index(v: {0..<8 as usize}) -> u8 {
          return ftrap_buf_b[v];
        }");

  Alcotest.test_case
    "i32 as {lo..<hi as usize} is a CHECKED cast: exactly one trap site \
     (the range check), and the subsequent index is elided. Regression for \
     the soundness hole where this cast was silently unchecked and \
     arr[v as {0..<8 as i32}] became an unchecked OOB access (zero sites, zero \
     traps, wrong)" `Quick
    (expect_trap_sites 1
       "let mut ftrap_buf_c: [u8; 8];
        fn ftrap_checked_cast(v: i32) -> u8 {
          return ftrap_buf_c[v as {0..<8 as usize}];
        }");

  Alcotest.test_case
    "refined-to-wider-refined cast (across a base change too) is a provable \
     subtype coercion: zero trap sites, stays legal under --forbid-trap" `Quick
    (expect_trap_sites 0
       "let mut ftrap_buf_d: [u8; 8];
        fn ftrap_subtype_cast(v: {2..<5 as i32}) -> u8 {
          return ftrap_buf_d[v as {0..<8 as usize}];
        }");

  Alcotest.test_case
    "int as exhaustive enum records one trap site (runtime variant check); \
     the same cast to a non-exhaustive enum records none (any integer is \
     valid, no check emitted)" `Quick
    (fun () ->
       expect_trap_sites 1
         "enum FtrapColor: u8 { R = 1; G = 2; }
          fn ftrap_enum_closed(n: i32) -> u8 {
            let c: FtrapColor = n as u8 as FtrapColor;
            return c as u8;
          }" ();
       expect_trap_sites 0
         "enum FtrapEther: u16 { IPv4 = 0x0800; ARP = 0x0806; _; }
          fn ftrap_enum_open(n: i32) -> u16 {
            let t: FtrapEther = n as u16 as FtrapEther;
            return t as u16;
          }" ());

  (* -- narrowing invalidation (kill) rule: Ast.written_names ------------- *)
  (* Soundness regressions: before the kill rule, all three "killed" cases
     below elided the bounds check entirely (zero trap sites AND zero traps
     in the IR) -- a silent unchecked OOB access. *)

  Alcotest.test_case
    "if-narrowing is killed by assignment inside the branch: \
     `if (0 <= v < 8) { v = 100; buf[v] }` keeps its bounds check" `Quick
    (expect_trap_sites 1
       "let mut fkill_buf_a: [u8; 8];
        fn fkill_assign(v: usize) -> u8 {
          if (v >= 0 && v < 8) {
            v = 100;
            return fkill_buf_a[v];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "if-narrowing is killed by aliasing (&v) inside the branch: a write \
     through the pointer can change v after the condition was checked" `Quick
    (expect_trap_sites 1
       "let mut fkill_buf_b: [u8; 8];
        fn fkill_alias(v: usize) -> u8 {
          if (v >= 0 && v < 8) {
            let p: *usize = &v;
            *p = 100;
            return fkill_buf_b[v];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "if-narrowing is killed by a for-counter rebinding the narrowed name: \
     the fresh {0..<100 as i32} counter must not inherit the outer {0..<8 as i32} proof \
     (2 sites: the in-loop store against size 8, and the read after)" `Quick
    (expect_trap_sites 2
       "let mut fkill_buf_c: [u8; 8];
        fn fkill_rebind(v: usize) -> u8 {
          if (v >= 0 && v < 8) {
            for v: usize in 0..<100 {
              fkill_buf_c[v] = 1 as u8;
            }
            return fkill_buf_c[v];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "if-narrowing still elides the check when the branch only reads the \
     narrowed variable (the kill rule must not over-kill)" `Quick
    (expect_trap_sites 0
       "let mut fkill_buf_d: [u8; 8];
        fn fkill_readonly(v: usize) -> u8 {
          if (v >= 0 && v < 8) {
            return fkill_buf_d[v];
          }
          return 0 as u8;
        }");

  (* -- Const_env-driven refinement ---------------------------------------- *)

  Alcotest.test_case
    "for-loop bound naming a global constant refines the counter: \
     `for i in 0..<SIZE` elides the check against [T; SIZE] \
     (examples/const_global's residual sites under --forbid-trap)" `Quick
    (expect_trap_sites 0
       "const FTRAP_SIZE: usize = 4;
        let mut ftrap_ring: [i32; FTRAP_SIZE];
        fn ftrap_const_bound() -> i32 {
          for i: usize in 0..<FTRAP_SIZE {
            ftrap_ring[i] = i as i32;
          }
          return ftrap_ring[0 as {0..<1 as usize}];
        }");

  Alcotest.test_case
    "refined source covering only variant values proves an exhaustive-enum \
     cast: {1..<3 as i32} as a {1,2}-valued enum emits no switch/trap; {0..<3 as i32} \
     (0 is not a variant) keeps the runtime check" `Quick
    (fun () ->
       expect_trap_sites 0
         "enum FtrapTone: u8 { Lo = 1; Hi = 2; }
          fn ftrap_enum_proven(v: {1..<3 as i32}) -> u8 {
            let t: FtrapTone = v as FtrapTone;
            return t as u8;
          }" ();
       expect_trap_sites 1
         "enum FtrapTone2: u8 { Lo = 1; Hi = 2; }
          fn ftrap_enum_unproven(v: {0..<3 as i32}) -> u8 {
            let t: FtrapTone2 = v as FtrapTone2;
            return t as u8;
          }" ());

  Alcotest.test_case
    "a local shadowing a global constant is rejected (Const_env resolves \
     names with no scope info, so shadowing would let `for i in 0..<N` \
     refine against the global's value while looping to the local's)" `Quick
    (expect_type_error "shadows a global constant"
       "const FTRAP_N: i32 = 4;
        let mut ftrap_arr: [i32; FTRAP_N];
        fn ftrap_shadow() -> i32 {
          let FTRAP_N: i32 = 100;
          return FTRAP_N;
        }");

  (* -- Slice type (P1): fat value {ptr, usize len} + minimum-length proofs -- *)

  Alcotest.test_case
    "slice with static minimum: constant index below the minimum is proven, \
     zero trap sites" `Quick
    (expect_trap_sites 0
       "fn ftsl_static_min(s: [u8; 8..]) -> u8 {
          return s[3];
        }");

  Alcotest.test_case
    "slice with unknown length: unproven usize index gets a runtime check \
     against the RUNTIME length (one trap site)" `Quick
    (expect_trap_sites 1
       "fn ftsl_dyn_index(s: []u8, i: usize) -> u8 {
          return s[i];
        }");

  Alcotest.test_case
    "length narrowing: `if (s.len >= 4)` upgrades the slice's minimum for \
     the branch, proving the constant index (zero sites)" `Quick
    (expect_trap_sites 0
       "fn ftsl_len_narrow(s: []u8) -> u8 {
          if (s.len >= 4) {
            return s[3];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "length narrowing is killed by reassigning the slice inside the branch \
     (written_names kill rule applies to slices too)" `Quick
    (expect_trap_sites 1
       "fn ftsl_len_kill(s: []u8, t: []u8) -> u8 {
          let mut u: []u8 = s;
          if (u.len >= 8) {
            u = t;
            return u[7];
          }
          return 0 as u8;
        }");

  (* -- GitHub issue #213: relational slice-length bounds narrowing
     (`v < s.len`) -------------------------------------------------------- *)
  (* Motivating real-world shape: linux_user/freelist_generic/freelist_core.tkb's
     freelist_core_pop hit this exact pattern -- `if (head < next_free.len)
     { ... next_free[head] ... }` still required a runtime check because no
     existing mechanism relates a variable to ANOTHER value's runtime .len. *)

  Alcotest.test_case
    "relational narrowing: `if (v < s.len) { s[v] }` proves the index \
     against s's RUNTIME length (zero trap sites) -- the freelist_core_pop shape" `Quick
    (expect_trap_sites 0
       "fn f213_pop_shape(s: []usize, v: usize) -> usize {
          if (v < s.len) {
            return s[v];
          }
          return 0;
        }");

  Alcotest.test_case
    "relational narrowing is killed by writing the index variable inside \
     the branch (same kill rule as other narrowing mechanisms)" `Quick
    (expect_trap_sites 1
       "fn f213_kill_v(s: []usize, v: usize) -> usize {
          if (v < s.len) {
            v = 0;
            return s[v];
          }
          return 0;
        }");

  Alcotest.test_case
    "relational narrowing is killed by reassigning the SLICE inside the \
     branch (the two-name kill rule issue #213 specifically calls out: a \
     write to s can point it at different memory, invalidating `v < s.len` \
     just as surely as writing v itself)" `Quick
    (expect_trap_sites 1
       "fn f213_kill_s(s: []usize, t: []usize, v: usize) -> usize {
          if (v < s.len) {
            s = t;
            return s[v];
          }
          return 0;
        }");

  Alcotest.test_case
    "relational narrowing recognizes the mirrored spelling `s.len > v`" `Quick
    (expect_trap_sites 0
       "fn f213_mirrored(s: []usize, v: usize) -> usize {
          if (s.len > v) {
            return s[v];
          }
          return 0;
        }");

  Alcotest.test_case
    "relational narrowing proves a WRITE into the same slice the guard \
     compared against (regression test: writing s[v] inside the branch \
     used to poison its own guard's kill set via Ast.written_names' \
     conservative Index-write-counts-as-a-write-to-s rule -- found while \
     implementing issue #215's write-form test, fixed by the narrower \
     slice_rebind_names kill scan)" `Quick
    (expect_trap_sites 0
       "fn f213_write_self_guard(s: []usize, v: usize) {
          if (v < s.len) {
            s[v] = 1;
          }
        }");

  Alcotest.test_case
    "negative control: `v <= s.len` does NOT prove v is a valid index \
     (v = s.len is out of bounds) -- must keep the trap" `Quick
    (expect_trap_sites 1
       "fn f213_le_not_proven(s: []usize, v: usize) -> usize {
          if (v <= s.len) {
            return s[v];
          }
          return 0;
        }");

  Alcotest.test_case
    "runtime endpoint guard proves a prefix subslice without a second trap" `Quick
    (expect_trap_sites 0
       "fn f218_guarded_prefix(s: []u8, end: usize) -> usize {
          if (end <= s.len) {
            let prefix = s[0..<end];
            return prefix.len;
          }
          return 0;
        }");

  Alcotest.test_case
    "runtime endpoint guard proves a suffix ending at the same slice length" `Quick
    (expect_trap_sites 0
       "fn f218_guarded_suffix(s: []u8, start: usize) -> usize {
          if (start <= s.len) {
            let suffix = s[start..<s.len];
            return suffix.len;
          }
          return 0;
        }");

  Alcotest.test_case
    "constant suffix start within the slice minimum proves ordering against runtime .len" `Quick
    (expect_trap_sites 0
       "fn f218_static_suffix(s: [u8; 2..]) -> usize {
          let suffix = s[1..<s.len];
          return suffix.len;
        }");

  Alcotest.test_case
    "constant suffix start beyond the slice minimum keeps its runtime check" `Quick
    (expect_trap_sites 1
       "fn f218_static_suffix_unproven(s: []u8) -> usize {
          let suffix = s[1..<s.len];
          return suffix.len;
        }");

  Alcotest.test_case
    "early-return endpoint guard proves the fallthrough subslice" `Quick
    (expect_trap_sites 0
       "fn f218_guarded_fallthrough(s: []u8, end: usize) -> usize {
          if (end > s.len) { return 0; }
          let prefix = s[0..<end];
          return prefix.len;
        }");

  Alcotest.test_case
    "a later element write does not kill fallthrough endpoint evidence" `Quick
    (expect_trap_sites 0
       "fn f218_endpoint_then_element_write(s: [u8; 1..], end: usize) -> usize {
          if (end > s.len) { return 0; }
          let prefix = s[0..<end];
          s[0] = 1;
          return prefix.len;
        }");

  Alcotest.test_case
    "slice-length fallthrough narrowing accepts sizeof(packed struct) as \
     the natural bound" `Quick
    (expect_trap_sites 0
       "struct packed F218ElfHeader { tag: u32; address: u64; }
        fn f218_sizeof_fallthrough(s: []u8) -> usize {
          if (s.len < sizeof(F218ElfHeader)) { return 0; }
          let header = s[0..<sizeof(F218ElfHeader)];
          return header.len;
        }");

  Alcotest.test_case
    "slice-length equality narrows the branch minimum in either order" `Quick
    (expect_trap_sites 0
       "fn f218_len_equality(s: []u8) -> u8 {
          if (s.len == 2) { return s[1]; }
          if (1 == s.len) { return s[0]; }
          return 0;
        }");

  Alcotest.test_case
    "target-dependent sizeof does not become an unsound slice-length proof" `Quick
    (expect_trap_sites 1
       "struct F218NativeHeader { tag: u8; address: usize; }
        fn f218_native_sizeof(s: []u8) -> usize {
          if (s.len < sizeof(F218NativeHeader)) { return 0; }
          let header = s[0..<sizeof(F218NativeHeader)];
          return header.len;
        }");

  Alcotest.test_case
    "runtime endpoint evidence is tied to the compared slice" `Quick
    (expect_trap_sites 1
       "fn f218_endpoint_wrong_slice(s: []u8, t: []u8, end: usize) -> usize {
          if (end <= s.len) {
            let prefix = t[0..<end];
            return prefix.len;
          }
          return 0;
        }");

  Alcotest.test_case
    "runtime endpoint evidence is killed when the endpoint is reassigned" `Quick
    (expect_trap_sites 1
       "fn f218_endpoint_reassigned(s: []u8, end: usize) -> usize {
          if (end <= s.len) {
            end = end + 1;
            let prefix = s[0..<end];
            return prefix.len;
          }
          return 0;
        }");

  Alcotest.test_case
    "runtime endpoint evidence is killed when the slice is rebound" `Quick
    (expect_trap_sites 1
       "fn f218_endpoint_slice_rebound(s: []u8, t: []u8, end: usize) -> usize {
          if (end <= s.len) {
            s = t;
            let prefix = s[0..<end];
            return prefix.len;
          }
          return 0;
        }");

  (* -- GitHub issue #215: for-loop counter bounded by a slice's own
     runtime .len -------------------------------------------------------- *)
  (* Sibling of #213 but structural rather than condition-based: a
     for-loop's own upper bound IS the proof when it's textually `s.len`,
     no if-condition involved. Motivating real-world shape:
     linux_user/freelist_generic/freelist.tkb's freelist_core_init loops
     `for i in 0..<next_free.len { next_free[i] = i + 1; }`. *)

  Alcotest.test_case
    "relational for-loop narrowing: `for i in 0..<s.len { s[i] }` (read) \
     proves the index against s's RUNTIME length (zero trap sites)" `Quick
    (expect_trap_sites 0
       "fn f215_read(s: []usize) -> usize {
          let mut total: usize = 0;
          for i: usize in 0..<s.len {
            total = total + s[i];
          }
          return total;
        }");

  Alcotest.test_case
    "relational for-loop narrowing also proves the WRITE form (matches \
     freelist_core_init's actual shape, zero trap sites)" `Quick
    (expect_trap_sites 0
       "fn f215_write(s: []usize) {
          for i: usize in 0..<s.len {
            s[i] = i;
          }
        }");

  Alcotest.test_case
    "relational for-loop narrowing is killed by reassigning the SLICE \
     inside the body (same two-name kill rule as #213 -- the counter \
     itself needs no kill-check since it is an immutable, non-aliasable \
     for-loop binding)" `Quick
    (expect_trap_sites 1
       "fn f215_kill_s(s: []usize, t: []usize) -> usize {
          let mut total: usize = 0;
          for i: usize in 0..<s.len {
            s = t;
            total = total + s[i];
          }
          return total;
        }");

  Alcotest.test_case
    "negative regression guard: a SEPARATE variable merely equal in value \
     to s.len (not textually s.len) is NOT recognized -- proves the fix \
     does not over-reach into alias/equality reasoning (this is \
     freelist_core_init's shape before its own rewrite)" `Quick
    (expect_trap_sites 1
       "fn f215_alias_not_proven(s: []usize) -> usize {
          let n: usize = s.len;
          let mut total: usize = 0;
          for i: usize in 0..<n {
            total = total + s[i];
          }
          return total;
        }");

  Alcotest.test_case
    "constant subslice: s[2..<6] of [u8; 8..] yields [u8; 4..]; index 3 \
     within it is proven (zero sites)" `Quick
    (expect_trap_sites 0
       "fn ftsl_subslice(s: [u8; 8..]) -> u8 {
          let m = s[2..<6];
          return m[3];
        }");

  Alcotest.test_case
    "constant-expression subslice bounds retain their proven minimum" `Quick
    (expect_trap_sites 0
       "const FTSL_PAGE: usize = 4096;
        const FTSL_LAYOUT: usize = 512;
        fn ftsl_const_expr(s: [u8; FTSL_PAGE..]) -> u8 {
          let tail = s[FTSL_PAGE - FTSL_LAYOUT..<FTSL_PAGE];
          return tail[FTSL_LAYOUT - 1];
        }");

  Alcotest.test_case
    "constant subslice beyond the proven minimum becomes a RUNTIME-CHECKED \
     subslice (P3 gradual form: the runtime length may exceed the minimum, \
     so this is one recorded trap site, not an error); after the check the \
     guaranteed length still proves inner indexing" `Quick
    (expect_trap_sites 1
       "fn ftsl_subslice_oob(s: [u8; 8..]) -> u8 {
          let m = s[2..<10];
          return m[7];
        }");

  Alcotest.test_case
    "malformed constant subslice (lo > hi) is still a compile error, and \
     an array subslice out of the exact static size is too" `Quick
    (fun () ->
       expect_type_error "malformed"
         "fn ftsl_subslice_bad(s: [u8; 8..]) -> u8 {
            let m = s[6..<2];
            return m[0];
          }" ();
       expect_type_error "outside the proven range"
         "let mut ftsl_arr_oob: [u8; 8];
          fn ftsl_arr_sub() -> u8 {
            let m = ftsl_arr_oob[2..<10];
            return m[0];
          }" ());

  Alcotest.test_case
    "array-to-slice cast carries the static length as the minimum: \
     [u8; 16] as []u8 proves index 15 (zero sites)" `Quick
    (expect_trap_sites 0
       "let mut ftsl_buf: [u8; 16];
        fn ftsl_array_cast() -> u8 {
          let s = ftsl_buf as []u8;
          return s[15];
        }");

  Alcotest.test_case
    "slice subtyping: a larger minimum passes where a smaller one is \
     required; the reverse is the anti-subtyping compile error" `Quick
    (fun () ->
       expect_codegen_ok
         "fn ftsl_sub_callee(s: [u8; 20..]) -> u8 { return s[19]; }
          fn ftsl_sub_caller(s: [u8; 54..]) -> u8 { return ftsl_sub_callee(s); }" ();
       expect_type_error "narrow with if (s.len"
         "fn ftsl_sub_callee2(s: [u8; 54..]) -> u8 { return s[53]; }
          fn ftsl_sub_caller2(s: [u8; 20..]) -> u8 { return ftsl_sub_callee2(s); }" ());

  Alcotest.test_case
    "s.len has type usize: assigning it to i32 without a cast is a compile \
     error; with `as i32` it compiles" `Quick
    (fun () ->
       expect_type_error "cannot unify"
         "fn ftsl_len_i32(s: []u8) -> i32 {
            let n: i32 = s.len;
            return n;
          }" ();
       expect_codegen_ok
         "fn ftsl_len_cast(s: []u8) -> i32 {
            return s.len as i32;
          }" ());

  Alcotest.test_case
    "slice construction from a raw pointer requires unsafe { ... }: inside \
     it, constant bounds become the minimum, proving later indexing (zero \
     sites); without the marker it is a compile error" `Quick
    (fun () ->
       expect_trap_sites 0
         "fn ftsl_from_ptr(p: *u8) -> u8 !{unsafe} {
            let s = unsafe { p[0..<8] };
            return s[7];
          }" ();
       expect_type_error "unsafe"
         "fn ftsl_from_ptr_bare(p: *u8) -> u8 {
            let s = p[0..<8];
            return s[0];
          }" ());

  Alcotest.test_case
    "slice construction from a volatile (*io) pointer is rejected: slice \
     accesses are non-volatile and would silently drop io semantics" `Quick
    (expect_type_error "volatile"
       "fn ftsl_from_io(p: *io u8) -> u8 {
          let s = p[0..<8];
          return s[0];
        }");

  (* -- proofs survive weaker annotations on immutable bindings (B-plan) --- *)
  (* "Proofs are only lost at mutation points, never at annotation": in the
     gradual-trap-elimination workflow, a weaker annotation on an IMMUTABLE
     let must not manufacture trap sites out of already-proven code (they
     would resurface as --forbid-trap rejections at ship time with no real
     proof gap behind them). `let mut` keeps the declared (honestly weak)
     type, because reassignment can bring weaker values. *)

  Alcotest.test_case
    "immutable let with a weaker slice annotation keeps the initializer's \
     proven minimum: `let m: []u8 = s[2..<6]` still proves m[3] (zero sites)" `Quick
    (expect_trap_sites 0
       "fn ftbp_imm_slice(s: [u8; 8..]) -> u8 {
          let m: []u8 = s[2..<6];
          return m[3];
        }");

  Alcotest.test_case
    "let mut with the same weak slice annotation honestly weakens: \
     reassignment is possible, so the check stays (one site)" `Quick
    (expect_trap_sites 1
       "fn ftbp_mut_slice(s: [u8; 8..]) -> u8 {
          let mut m: []u8 = s[2..<6];
          return m[3];
        }");

  Alcotest.test_case
    "immutable let with a same-base annotation keeps a refined initializer's \
     range: `let x: usize = v` where v: {2..<5 as usize} still elides \
     buf[x] (zero sites); let mut keeps the declared usize (one site)" `Quick
    (fun () ->
       expect_trap_sites 0
         "let mut ftbp_buf_a: [u8; 8];
          fn ftbp_imm_int(v: {2..<5 as usize}) -> u8 {
            let x: usize = v;
            return ftbp_buf_a[x];
          }" ();
       expect_trap_sites 1
         "let mut ftbp_buf_b: [u8; 8];
          fn ftbp_mut_int(v: {2..<5 as usize}) -> u8 {
            let mut x: usize = v;
            return ftbp_buf_b[x];
          }" ());

  (* -- for-in element iteration + slice builtins (P2) -------------------- *)

  Alcotest.test_case
    "for-in over a slice is safe by construction: zero trap sites, and the \
     element value composes with arithmetic (widened per the invariant)" `Quick
    (expect_trap_sites 0
       "fn ftfe_sum(s: []u8) -> i32 {
          let mut total: i32 = 0;
          for x in s {
            total = total + (x as i32);
          }
          return total;
        }");

  Alcotest.test_case
    "for-in with break and continue targets the compiler-generated \
     increment/exit blocks (same layout as For)" `Quick
    (expect_trap_sites 0
       "fn ftfe_scan(s: []u8) -> i32 {
          let mut t: i32 = 0;
          for x in s {
            if (x == 0 as u8) { break; }
            if (x == 32 as u8) { continue; }
            t = t + 1;
          }
          return t;
        }");

  Alcotest.test_case
    "for-in over a non-slice is a compile error suggesting `arr as []T`" `Quick
    (expect_type_error "for-in iterates over a slice"
       "fn ftfe_bad(n: i32) -> i32 {
          for x in n { }
          return 0;
        }");

  Alcotest.test_case
    "for-in rebinding a narrowed name kills the narrowing (written_names \
     covers ForEach): the read after the loop keeps its bounds check" `Quick
    (expect_trap_sites 1
       "let mut ftfe_buf: [u8; 8];
        fn ftfe_kill(v: usize, s: []u8) -> u8 {
          if (v >= 0 && v < 8) {
            for v in s { }
            return ftfe_buf[v];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "slice_copy builtin: returns usize, total (zero trap sites); arity and \
     element-type mismatches are compile errors" `Quick
    (fun () ->
       expect_trap_sites 0
         "fn ftsc_ok(d: []u8, s: []u8) -> usize {
            return slice_copy(d, s);
          }" ();
       expect_type_error "slice_copy expects 2 arguments"
         "fn ftsc_arity(d: []u8) -> usize {
            return slice_copy(d);
          }" ();
       expect_type_error "cannot unify"
         "let mut ftsc_ints: [i32; 4];
          fn ftsc_elem(d: []u8) -> usize {
            return slice_copy(d, ftsc_ints as []i32);
          }" ());

  Alcotest.test_case
    "slice_eq builtin: returns bool usable directly in if, zero trap sites" `Quick
    (expect_trap_sites 0
       "fn ftse_ok(a: []u8, b: []u8) -> i32 {
          if (slice_eq(a, b)) { return 1; }
          return 0;
        }");

  Alcotest.test_case
    "builtin names are reserved: defining fn slice_copy / extern fn \
     slice_eq is a compile error" `Quick
    (fun () ->
       expect_type_error "compiler builtin"
         "fn slice_copy(a: i32) -> i32 { return a; }" ();
       expect_type_error "compiler builtin"
         "extern fn slice_eq(a: i32) -> i32;" ());

  (* -- P3: refined-bound subslice proof, checked subslice, lit/ptr casts -- *)

  Alcotest.test_case
    "refined-bound subslice is proven by intervals alone: frame[0..<len] \
     after `if (len >= 54 && len <= 1514)` on a [u8; 1514..] frame yields \
     [u8; 54..] with zero checks -- the driver-boundary pattern" `Quick
    (expect_trap_sites 0
       "fn ftp3_rx(frame: [u8; 1514..], len: i32) -> i32 {
          if (len >= 54 && len <= 1514) {
            let rx = frame[0..<len as {54..<1515 as usize}];
            return read_ftp3(rx);
          }
          return 0;
        }
        fn read_ftp3(rx: [u8; 54..]) -> i32 {
          return rx[12] as i32;
        }");

  Alcotest.test_case
    "runtime-bound subslice on a slice is the gradual checked form: one \
     recorded trap site, result minimum 0" `Quick
    (expect_trap_sites 2
       "fn ftp3_checked(s: []u8, a: i32, b: i32) -> u8 {
          let m = s[a as usize..<b as usize];
          return m[0];
        }");

  Alcotest.test_case
    "string literal as []u8 carries its compile-time byte length as the \
     minimum (NUL excluded): slice_copy of a literal is bounded and \
     returns min(dst.len, lit.len) -- zero trap sites" `Quick
    (expect_trap_sites 0
       "fn ftp3_lit(dst: []u8) -> usize {
          return slice_copy(dst, \"HTTP/1.1 200 OK\" as []u8);
        }");

  Alcotest.test_case
    "slice as *T is the explicit bridge back to the pointer world; other \
     slice casts remain errors" `Quick
    (fun () ->
       expect_codegen_ok
         "fn ftp3_takes_ptr(p: *u8) -> u8 { return p[0]; }
          fn ftp3_bridge(s: [u8; 4..]) -> u8 {
            return ftp3_takes_ptr(s as *u8);
          }" ();
       expect_type_error "cannot cast a slice"
         "fn ftp3_bad(s: []u8) -> i32 {
            return s as i32;
          }" ());

  (* -- P4a: interval extensions + same-base subslice rule ---------------- *)

  Alcotest.test_case
    "equality narrowing: `if (ihl == 20)` gives ihl the exact range \
     {20..<21 as i32}, proving the index (zero sites)" `Quick
    (expect_trap_sites 0
       "let mut ftp4_buf_a: [u8; 32];
        fn ftp4_eq(ihl: usize) -> u8 {
          if (ihl == 20) {
            return ftp4_buf_a[ihl];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "comparison against a range-known VARIABLE narrows (the fact collapses \
     to a constant -- still intervals): total <= bounded proves the index" `Quick
    (expect_trap_sites 0
       "let mut ftp4_buf_b: [u8; 40];
        fn ftp4_var_cmp(total: usize, cap: {10..<40 as usize}) -> u8 {
          if (total >= 0 && total <= cap) {
            return ftp4_buf_b[total];
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "interval arithmetic propagation: refined+refined, refined-refined, \
     refined*positive-literal all carry ranges through immutable lets" `Quick
    (expect_trap_sites 0
       "let mut ftp4_buf_c: [u8; 128];
        fn ftp4_arith(a: {5..<16 as usize}, b: {0..<8 as usize}) -> u8 {
          let m: usize = a * 4;       // {20..<61 as i32}
          let s: usize = a + b;       // {5..<23 as i32}
          let d: usize = m - a;       // {5..<56 as i32}
          return ftp4_buf_c[m] + ftp4_buf_c[s] + ftp4_buf_c[d];
        }");

  Alcotest.test_case
    "same-base subslice: s[off..<off+3] is proven when off's range fits \
     (lo <= hi holds syntactically regardless of off's value) and yields \
     exact length 3" `Quick
    (expect_trap_sites 0
       "fn ftp4_same_base(frame: [u8; 1514..], off: {54..<95 as usize}) -> u8 {
          let d = frame[off..<off + 3];
          return d[2];
        }");

  Alcotest.test_case
    "same-base subslice without a range on the base is still the checked \
     form (memory safety needs off's range), but the exact length 3 \
     survives the check and proves the inner index (exactly one site)" `Quick
    (expect_trap_sites 1
       "fn ftp4_same_base_dyn(frame: [u8; 1514..], off: usize) -> u8 {
          let d = frame[off..<off + 3];
          return d[2];
        }");

  Alcotest.test_case
    "constant-stride batch subslices stay trap-free under a runtime batch guard: \
     the loop proves offset, the constant stride proves the end bound, and \
     the guard only controls how many entries are copied" `Quick
    (expect_trap_sites 0
       "const FTRAP_BATCH: usize = 8;
        const FTRAP_STRIDE: usize = 4;
        let mut ftrap_batch_dst: [u8; FTRAP_BATCH * FTRAP_STRIDE];
        let mut ftrap_batch_src: [u8; FTRAP_STRIDE];
        fn ftrap_batch_copy(count: usize) {
          for offset: usize in 0..<FTRAP_BATCH {
            if (offset < count) {
              let base: usize = offset * FTRAP_STRIDE;
              slice_copy(
                  ftrap_batch_dst[base..<base + FTRAP_STRIDE],
                  ftrap_batch_src as []u8);
            }
          }
        }");

  Alcotest.test_case
    "the P4 probe: http_server's full guard chain -- device-length clamp, \
     ihl equality, total_len vs frame room, segment view of runtime \
     length, options skip at runtime offset -- proven end to end with \
     zero trap sites (the 'depth-1 difference constraint suffices' \
     hypothesis)" `Quick
    (expect_trap_sites 0
       "fn ftp4_read16(s: [u8; 2..]) -> i32 {
          return (s[0] as i32) * 256 + (s[1] as i32);
        }
        fn ftp4_sum(s: []u8) -> i32 {
          let mut t: i32 = 0;
          for x in s { t = t + (x as i32); }
          return t;
        }
        fn ftp4_probe(frame: [u8; 1514..], len: usize) -> i32 {
          if (len >= 54 && len <= 1514) {
            let ip = frame[14..<34];
            let ihl: usize = ((ip[0] as usize) & 0x0f) * 4;
            if (ihl == 20) {
              let total_len: usize = ftp4_read16(ip[2..<4]) as usize;
              let ip_len_in_frame: usize = len - 14;
              if (total_len <= ip_len_in_frame && total_len >= ihl) {
                let tcp_len: usize = total_len - ihl;
                let seg = frame[34..<34 + tcp_len];
                let tcp = frame[34..<54];
                let doff: usize = (tcp[12] as usize) >> 4;
                if (tcp_len >= 20 && doff >= 5 && doff <= 15) {
                  let tcp_hdr_len: usize = doff * 4;
                  let data_off: usize = 34 + tcp_hdr_len;
                  let d3 = frame[data_off..<data_off + 3];
                  if (d3[0] == 'G' as u8) {
                    return ftp4_sum(seg);
                  }
                }
              }
            }
          }
          return 0;
        }");

  (* -- P4b: intersect-narrowing fix (found migrating icmp_echo) ---------- *)

  Alcotest.test_case
    "if-narrowing INTERSECTS with an ALREADY-refined immutable let, rather \
     than no-oping (the pre-fix bug): icmp_len arrives at the if with \
     {0..<1481 as i32} (Sub-propagated from two refined operands), and \
     `if (icmp_len >= 8 && icmp_len <= 1480)` must tighten it to \
     {8..<1481 as i32} so the resulting subslice's minimum (8) satisfies the \
     callee's [u8; 8..] parameter -- zero trap sites end to end" `Quick
    (expect_trap_sites 0
       "fn ftp4b_use(s: [u8; 8..]) -> u8 { return s[0]; }
        fn ftp4b_intersect(frame: [u8; 1514..], a: {20..<1501 as usize}, ihl: {20..<21 as usize}) -> u8 {
          let icmp_len: usize = a - ihl;         // Sub(refined,refined) -> {0..<1481 as i32}
          if (icmp_len >= 8 && icmp_len <= 1480) {
            let seg = frame[34..<34 + icmp_len];  // must get minimum >= 8
            return ftp4b_use(seg);
          }
          return 0 as u8;
        }");

  Alcotest.test_case
    "the intersect also applies to a MUT variable narrowed by a nested if \
     on top of an outer if's narrowing (llvm_gen's narrowing_ctx must \
     intersect with its own prior entry, not overwrite it)" `Quick
    (expect_trap_sites 0
       "let mut ftp4b_buf: [u8; 100];
        fn ftp4b_nested_mut(v: usize) -> u8 {
          let mut x: usize = v;
          if (x >= 0 && x <= 99) {
            if (x >= 10 && x <= 50) {
              return ftp4b_buf[x];
            }
          }
          return 0 as u8;
        }");

  (* -- P4c-2: Band mask propagation + min/max builtins -------------------- *)

  Alcotest.test_case
    "x & k (non-negative literal mask) propagates to {0..<k+1} regardless \
     of x's own sign or range -- proves an index with no prior narrowing \
     at all (zero trap sites)" `Quick
    (expect_trap_sites 0
       "let mut ftp4c_buf_a: [u8; 16];
        fn ftp4c_mask(v: usize) -> u8 {
          return ftp4c_buf_a[v & 0x0f];
        }");

  Alcotest.test_case
    "mask propagation is symmetric (literal & x) and composes with Mul \
     (P4a): (v & 0x0f) * 4 carries {0..<16 as i32} to {0..<61 as i32}" `Quick
    (expect_trap_sites 0
       "let mut ftp4c_buf_b: [u8; 61];
        fn ftp4c_mask_mul(v: usize) -> u8 {
          let ihl: usize = (0x0f & v) * 4;
          return ftp4c_buf_b[ihl];
        }");

  Alcotest.test_case
    "Mul's constant-multiplier detection resolves a Const_env-named global \
     (`idx * RX_BUF_SIZE`), not just a bare IntLit token -- found while \
     removing net_rx_frame's unsafe (see CLAUDE.md's P4c section): the \
     literal-vs-named-constant distinction is invisible in ordinary code, \
     so this gap silently blocked the exact same idiom Mul already \
     supported for a literal multiplier" `Quick
    (expect_trap_sites 0
       "const RX_BUF_SIZE: usize = 1536;
        let mut ftp4c_buf_f: [u8; 12288];
        fn ftp4c_mul_const(raw_idx: usize) -> u8 {
          let idx: usize = max(min(raw_idx, 7), 0);   // {0..<8 as i32}
          let offset: usize = idx * RX_BUF_SIZE;       // {0..<10753 as i32} via Const_env-resolved k
          return ftp4c_buf_f[offset];
        }");

  Alcotest.test_case
    "min(a, LITERAL) clamps the upper bound to the literal regardless of \
     a's own range, proving a subslice against a smaller buffer than a's \
     own {0..<64 as i32} range would otherwise allow (zero trap sites) -- the \
     idiom that makes examples/ip_parse's ihl clamp provable" `Quick
    (expect_trap_sites 0
       "let mut ftp4c_buf_c: [u8; 20];
        fn ftp4c_min_clamp(raw: usize) -> u8 {
          let ihl: usize = raw & 0x3f;      // {0..<64 as i32}
          let capped: usize = min(ihl, 19); // {0..<20 as i32}
          return ftp4c_buf_c[capped];
        }");

  Alcotest.test_case
    "HONEST NEGATIVE RESULT: chaining two CORRELATED clamps (cap ihl, then \
     cap tcp_len against the room DERIVED from that same ihl) does NOT \
     reach zero trap sites, unlike the single-clamp case above -- the \
     tcp_parse/tcp_echo pattern. `tlc <= room = 40 - ihl` is a genuine \
     RELATIONAL fact (tlc's value is tied to ihl's), and it is lost the \
     moment tlc becomes its own named variable with just an independent \
     {0..<41 as i32} range: `ihl + tlc`'s ordinary interval combination (using \
     ihl's OWN worst case together with tlc's OWN worst case, a \
     combination that cannot actually co-occur) overshoots the true bound \
     (40) even though the same-base rule above already closes the lo<=hi \
     side of the proof. This is the precise boundary P4c-2's tools don't \
     cross; CLAUDE.md's P4c section recommends the unsafe-extension \
     (P4c-1) or a genuine relational/difference-constraint domain to \
     close it, not a bigger interval hack" `Quick
    (expect_trap_sites 1
       "fn ftp4c_checksum(s: []u8, sum_in: i32) -> i32 {
          let mut sum: i32 = sum_in;
          for b in s { sum = sum + (b as i32); }
          return sum;
        }
        fn ftp4c_chained(pkt: [u8; 40..], raw_ihl: usize, tcp_len: usize) -> i32 {
          let ihl: usize = min(raw_ihl & 0x3f, 20);   // {0..<21 as i32}
          let room: usize = 40 - ihl;                  // {20..<41 as i32} via Sub
          let tl: usize = max(tcp_len, 0);              // >= 0, upper unknown
          let tlc: usize = min(tl, room);                // {0..<41 as i32}
          return ftp4c_checksum(pkt[ihl..<ihl + tlc], 0);
        }");

  Alcotest.test_case
    "max(a, LITERAL) clamps the lower bound; min/max with an unconstrained \
     other operand falls back to plain i32 (conservative, not unsound)" `Quick
    (fun () ->
       expect_trap_sites 0
         "let mut ftp4c_buf_d: [u8; 50];
          fn ftp4c_max_clamp(v: usize) -> u8 {
            let x: usize = max(v & 0x1f, 0);  // {0..<32 as i32}, lower clamp is a no-op here but exercises max
            return ftp4c_buf_d[x];
          }" ();
       expect_trap_sites 1
         "fn ftp4c_unconstrained(a: usize, b: usize) -> usize {
            return min(a, b);
          }
          let mut ftp4c_buf_e: [u8; 10];
          fn ftp4c_use_it(a: usize, b: usize) -> u8 {
            let m: usize = ftp4c_unconstrained(a, b);
            return ftp4c_buf_e[m];
          }" ());

  Alcotest.test_case
    "min/max names are reserved compiler builtins and cannot be redefined" `Quick
    (fun () ->
       expect_type_error "compiler builtin"
         "fn min(a: i32, b: i32) -> i32 { return a; }" ();
       expect_type_error "compiler builtin"
         "fn max(a: i32, b: i32) -> i32 { return a; }" ());

  Alcotest.test_case
    "DMA/device barrier builtins are zero-argument void operations" `Quick
    (fun () ->
       expect_ok
         "fn barrier_calls() {
            dma_publish();
            dma_consume();
            device_fence();
          }" ();
       expect_type_error "expects no arguments"
         "fn bad_barrier_call() { dma_publish(1); }" ();
       expect_type_error "expects no arguments"
         "fn bad_wait_call() { interrupt_wait(1); }" ());

  Alcotest.test_case
    "DMA/device barrier builtin names cannot be redefined" `Quick
    (fun () ->
       expect_type_error "compiler builtin" "fn dma_publish() {}" ();
       expect_type_error "compiler builtin" "extern fn device_fence();" ();
       expect_type_error "compiler builtin" "fn signal_fence() {}" ();
       expect_type_error "compiler builtin" "fn interrupt_wait() {}" ();
       expect_type_error "compiler builtin" "extern fn interrupt_notify();" ());

  Alcotest.test_case "DMA cache builtins require pointer and usize length" `Quick
    (fun () ->
       (* GitHub issue #102 Stage 2: dma_prepare_rx/dma_finish_rx are
          cache-line INVALIDATE operations and now require a PROVEN
          *align(32) pointer (examples/common_stm32/sdmmc.tkb's disk_read
          no longer needs its own bounce buffer as a result); an aligned
          pointer still widens into dma_prepare_tx's plain *u8 -- a CLEAN
          (writeback), which stays safe on any alignment and does not
          require one. See the dedicated test group below for the
          negative/positive alignment cases in isolation. *)
       expect_ok
         "fn cache_ops(p: *align(DMA_CACHE_LINE) u8, n: usize) {
            dma_prepare_tx(p, n);
            dma_prepare_rx(p, n);
            dma_finish_rx(p, n);
          }" ();
       expect_type_error "raw pointer"
         "fn bad_cache_ptr(n: usize) { dma_prepare_tx(n, n); }" ();
       expect_type_error "cannot unify"
         "fn bad_cache_len(p: *align(DMA_CACHE_LINE) u8, n: i32) { dma_finish_rx(p, n); }" ());

  Alcotest.test_case
    "DMA RX alignment follows the target and exposes DMA_CACHE_LINE" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "*align(64)"
         "fn f(p: *align(32) u8) { dma_prepare_rx(p, 64); }" ();
       expect_ok
         "let mut buf: [u8; 64] align(DMA_CACHE_LINE);
          fn f(p: *align(DMA_CACHE_LINE) u8) {
            dma_prepare_rx(p, 64);
            dma_finish_rx(p, 64);
          }
          fn g() { f(buf); }" ();
       expect_type_error "cannot be redefined"
         "const DMA_CACHE_LINE: usize = 32; fn f() {}" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "dma_finish_rx rejects an unproven pointer, dma_prepare_tx accepts it" `Quick
    (fun () ->
       expect_type_error "cannot pass unproven"
         "fn f(p: *u8) { dma_finish_rx(p, 512); }" ();
       expect_ok "fn f(p: *u8) { dma_prepare_tx(p, 512); }" ());

  (* GitHub issue #227 item 2: `vector_table { N => target; ... }` declares
     the target's hardware exception vector table -- checked exhaustively
     (every architectural slot listed exactly once) instead of the
     eyeballed 16-line hand-written table this replaces in
     kernel/arch/arm64/boot/entry.S. AArch64 defines exactly 16 slots
     (Target_info.vector_table_contract), so these tests configure that
     target explicitly and restore the ambient thumbv7em default afterward,
     matching the DMA alignment test's own Target_info save/restore
     discipline just above -- Target_info is process-global state shared
     across this whole test binary. Codegen itself (the actual generated
     `mov x0, #N; b target` sequence, and specifically that a target used by
     only one slot gets NO `mov` -- the exact register-clobber bug issue
     #227 item 3 found in hand-written form) is deliberately NOT re-verified
     here: it was verified directly via the CLI against real
     disassembly/relocations (llvm-objdump -d/-r) during development, the
     same depth of coverage dma_prepare_tx's own AArch64-specific lowering
     already has in this suite (type-checked here, verified for real via
     kernelbuild-rpi5/hardware, never re-asserted at the IR-text level) --
     see HISTORY.md's issue #227 item 2 entry. *)
  Alcotest.test_case "vector_table requires every architectural slot listed exactly once" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "missing slot 2"
         "fn h() { while (true) { interrupt_wait(); } }
          vector_table { 0 => h; 1 => h; }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "vector_table rejects a slot listed twice" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "listed more than once"
         "fn h() { while (true) { interrupt_wait(); } }
          vector_table {
            0=>h;1=>h;2=>h;3=>h;4=>h;5=>h;6=>h;7=>h;
            8=>h;9=>h;10=>h;11=>h;12=>h;13=>h;14=>h;14=>h;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "vector_table rejects a slot number out of range" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "out of range"
         "fn h() { while (true) { interrupt_wait(); } }
          vector_table {
            0=>h;1=>h;2=>h;3=>h;4=>h;5=>h;6=>h;7=>h;
            8=>h;9=>h;10=>h;11=>h;12=>h;13=>h;14=>h;16=>h;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "vector_table rejects an undefined target name" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "not defined"
         "vector_table {
            0=>ghost;1=>ghost;2=>ghost;3=>ghost;4=>ghost;5=>ghost;6=>ghost;7=>ghost;
            8=>ghost;9=>ghost;10=>ghost;11=>ghost;12=>ghost;13=>ghost;14=>ghost;15=>ghost;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "vector_table rejects a second declaration in the same program" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "at most one vector_table"
         "fn h() { while (true) { interrupt_wait(); } }
          vector_table {
            0=>h;1=>h;2=>h;3=>h;4=>h;5=>h;6=>h;7=>h;
            8=>h;9=>h;10=>h;11=>h;12=>h;13=>h;14=>h;15=>h;
          }
          vector_table {
            0=>h;1=>h;2=>h;3=>h;4=>h;5=>h;6=>h;7=>h;
            8=>h;9=>h;10=>h;11=>h;12=>h;13=>h;14=>h;15=>h;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "vector_table is unavailable on a target with no exception vector table contract" `Quick
    (fun () ->
       Target_info.configure "x86_64-pc-linux-gnu";
       expect_type_error "no exception vector table contract"
         "fn h() { while (true) { interrupt_wait(); } }
          vector_table { 0 => h; }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "vector_table accepts an exhaustive, unique AArch64 declaration mixing fn and extern symbol targets" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_ok
         "extern symbol asm_handler;
          fn tkb_handler() { while (true) { interrupt_wait(); } }
          vector_table {
            0=>tkb_handler;1=>tkb_handler;2=>tkb_handler;3=>tkb_handler;
            4=>tkb_handler;5=>asm_handler;6=>tkb_handler;7=>tkb_handler;
            8=>asm_handler;9=>asm_handler;10=>tkb_handler;11=>tkb_handler;
            12=>tkb_handler;13=>tkb_handler;14=>tkb_handler;15=>tkb_handler;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  (* GitHub issue #227 item 1 (prototype slice): `exception_entry name {
     frame: ...; dispatch: ...; before: ...; }` generates a save/[before]/
     dispatch/restore/eret sequence from a `struct packed` frame
     declaration. exc_frame_src (defined above codegen_tests) is the one
     closed AArch64 register-name field set every test below shares. *)
  Alcotest.test_case "exception_entry accepts a well-formed frame/dispatch/before declaration" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       ignore (gen_codegen
         (exc_frame_src ^
          "fn my_dispatch(frame_sp: usize) -> usize { return frame_sp; }
           fn my_before() {}
           exception_entry el1_current_irq_entry {
             frame: ExcFrame;
             before: my_before;
             dispatch: my_dispatch;
           }"));
       let asm = Buffer.contents Llvm_gen.raw_asm_buf in
       Alcotest.(check bool) "thread pointer saved" true
         (contains_substring asm "mrs\tx9, tpidr_el0");
       Alcotest.(check bool) "thread pointer restored" true
         (contains_substring asm "msr\ttpidr_el0, x9");
       Alcotest.(check bool) "frame remains stack aligned" true
         (contains_substring asm "sub\tsp, sp, #816");
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_entry rejects a dispatch target with the wrong signature" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "wrong signature"
         (exc_frame_src ^
          "fn bad_dispatch(a: usize, b: usize) -> usize { return a; }
           exception_entry el1_current_irq_entry {
             frame: ExcFrame;
             dispatch: bad_dispatch;
           }") ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_entry rejects a before target with the wrong signature" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "wrong signature"
         (exc_frame_src ^
          "fn my_dispatch(frame_sp: usize) -> usize { return frame_sp; }
           fn bad_before() -> usize { return 0; }
           exception_entry el1_current_irq_entry {
             frame: ExcFrame;
             before: bad_before;
             dispatch: my_dispatch;
           }") ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_entry rejects a frame struct missing a register field" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "missing register field"
         "struct packed IncompleteFrame { x0: usize; }
          fn my_dispatch(frame_sp: usize) -> usize { return frame_sp; }
          exception_entry el1_current_irq_entry {
            frame: IncompleteFrame;
            dispatch: my_dispatch;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_entry rejects a frame struct with a non-register-name field" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "not an AArch64 exception-frame register name"
         (exc_frame_src ^
          "struct packed BadFrame { x0: usize; extra: usize; }
           fn my_dispatch(frame_sp: usize) -> usize { return frame_sp; }
           exception_entry el1_current_irq_entry {
             frame: BadFrame;
             dispatch: my_dispatch;
           }") ();
       Target_info.configure "thumbv7em-none-eabi");

  (* GitHub issue #227 item 1 follow-up: `exception_restore name { frame:
     ...; }` generates just the restore-frame/eret half, for a standalone
     resume entry point reached via an ordinary call with the frame's own
     address already in x0 -- exactly el0_context_resume's shape. Reuses
     exception_entry's own frame validation, so only the key handling
     (exactly one required key, "frame") gets its own tests here. *)
  Alcotest.test_case "exception_restore accepts a well-formed frame declaration" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_ok
         (exc_frame_src ^
          "exception_restore el0_context_resume {
             frame: ExcFrame;
           }") ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_restore emits a restore of the thread pointer" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       ignore (gen_codegen
         (exc_frame_src ^
          "exception_restore el0_context_resume {
             frame: ExcFrame;
           }"));
       let asm = Buffer.contents Llvm_gen.raw_asm_buf in
       Alcotest.(check bool) "thread pointer restored" true
         (contains_substring asm "msr\ttpidr_el0, x9");
       Target_info.configure "thumbv7em-none-eabi");

  (* 2026-08-13 post-mortem on issue #286: exception_frame_offsets (this
     function's own generator, lib/llvm_gen.ml) computes each field's byte
     offset by summing field sizes strictly in the struct's own declared
     order, with NO realignment before q0 -- only the frame's FINAL total is
     rounded up to 16 bytes for SP alignment. This is deliberate (AArch64
     `ldr`/`str` on a Q register has no natural-alignment requirement), but
     it was found to have silently diverged from scripts/gen_exception_frame.py's
     independent Python reimplementation of this same algorithm, which added
     an unnecessary q0-specific 16-byte-alignment step. Both sides now agree
     (see that script's own history), but nothing previously pinned this
     compiler function's actual behavior against a future accidental change
     (e.g., someone "helpfully" adding q0 alignment back here) reopening the
     exact same divergence.
     validate_exception_frame is explicitly field-order-independent (any
     permutation of the closed 69-field set is accepted), so moving
     tpidr_el0 to right after spsr_el1 (instead of its usual place after
     fpcr) is a legal frame that pushes the GPR/system-register prefix to
     35 fields * 8 bytes = 280 (0x118) before q0 -- NOT a multiple of 16,
     unlike the field order exc_frame_src normally uses (where the prefix
     happens to total exactly 0x110, 16-aligned, so it could never exercise
     this branch). A realignment regression would move q0 to 0x120 (288)
     instead of the correct, unaligned 0x118 (280); this test pins the
     latter. *)
  Alcotest.test_case
    "exception_restore does not 16-byte-align q0 when a struct field reorder \
     leaves its prefix unaligned" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       let reordered_frame_src =
         "struct packed ExcFrameReordered {
            x0: usize; x1: usize; x2: usize; x3: usize; x4: usize; x5: usize;
            x6: usize; x7: usize; x8: usize; x9: usize; x10: usize; x11: usize;
            x12: usize; x13: usize; x14: usize; x15: usize; x16: usize; x17: usize;
            x18: usize; x19: usize; x20: usize; x21: usize; x22: usize; x23: usize;
            x24: usize; x25: usize; x26: usize; x27: usize; x28: usize; x29: usize;
            x30: usize;
            sp_el0: usize; elr_el1: usize; spsr_el1: usize; tpidr_el0: usize;
            q0: [u8;16]; q1: [u8;16]; q2: [u8;16]; q3: [u8;16]; q4: [u8;16];
            q5: [u8;16]; q6: [u8;16]; q7: [u8;16]; q8: [u8;16]; q9: [u8;16];
            q10: [u8;16]; q11: [u8;16]; q12: [u8;16]; q13: [u8;16]; q14: [u8;16];
            q15: [u8;16]; q16: [u8;16]; q17: [u8;16]; q18: [u8;16]; q19: [u8;16];
            q20: [u8;16]; q21: [u8;16]; q22: [u8;16]; q23: [u8;16]; q24: [u8;16];
            q25: [u8;16]; q26: [u8;16]; q27: [u8;16]; q28: [u8;16]; q29: [u8;16];
            q30: [u8;16]; q31: [u8;16];
            fpsr: usize; fpcr: usize;
          }\n"
       in
       ignore (gen_codegen
         (reordered_frame_src ^
          "exception_restore el0_context_resume {
             frame: ExcFrameReordered;
           }"));
       let asm = Buffer.contents Llvm_gen.raw_asm_buf in
       Alcotest.(check bool) "q0 restored at the unaligned offset 280 (0x118)" true
         (contains_substring asm "ldr\tq0, [sp, #280]");
       Alcotest.(check bool)
         "q0 is NOT restored at the wrongly-realigned offset 288 (0x120)" false
         (contains_substring asm "ldr\tq0, [sp, #288]");
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_restore rejects an unknown key" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "unknown key"
         (exc_frame_src ^
          "exception_restore el0_context_resume {
             frame: ExcFrame;
             dispatch: ExcFrame;
           }") ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_restore rejects a missing frame key" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "missing required key 'frame'"
         "exception_restore el0_context_resume { }" ();
       Target_info.configure "thumbv7em-none-eabi");

  Alcotest.test_case "exception_restore rejects a frame missing a register field, same as exception_entry" `Quick
    (fun () ->
       Target_info.configure "aarch64-none-elf";
       expect_type_error "missing register field"
         "struct packed IncompleteFrame { x0: usize; }
          exception_restore el0_context_resume {
            frame: IncompleteFrame;
          }" ();
       Target_info.configure "thumbv7em-none-eabi");

  (* GitHub issue #230: `embed_file("path")` reads a real file at compile
     time and becomes a `[u8; N]` array constant, N the file's real byte
     size -- replacing a hand-written `.S` file's `.incbin` blob (and the
     `extern symbol start`/`end` pair + runtime `end - start` subtraction
     that used to be needed alongside it) with no second, human-authored
     side to keep in sync. with_embed_fixture (defined above codegen_tests,
     alongside exc_frame_src, for the same `let ... in` list-swallowing
     reason -- see that binding's own comment) uses a real temp file
     rather than a path relative to some assumed CWD, since dune's test
     runner's own working directory is not the repo root the compiler's
     other `path resolved like use "..."` conventions assume. *)
  Alcotest.test_case "embed_file accepts an unannotated global initializer and embeds the real bytes" `Quick
    (fun () ->
       with_embed_fixture "hello embed" (fun path ->
         let _ = gen_codegen (Printf.sprintf
           "let codegen_embed_unannotated = embed_file(\"%s\");
            fn codegen_embed_use_unannotated() -> usize {
              return codegen_embed_unannotated[0] as usize;
            }" path)
         in
         match Hashtbl.find_opt Llvm_gen.global_vars "codegen_embed_unannotated" with
         | None -> Alcotest.fail "codegen_embed_unannotated was not emitted"
         | Some (_, g) ->
             let ir = Llvm.string_of_llvalue g in
             (* "hello embed" is exactly 11 bytes; confirms both the real
                file content AND the inferred array length (not just that
                *some* global was emitted). *)
             Alcotest.(check bool) "embeds the real 11-byte file content" true
               (contains_substring ir "[11 x i8] c\"hello embed\"")));

  Alcotest.test_case "embed_file accepts a correct explicit array-size annotation" `Quick
    (fun () ->
       with_embed_fixture "12 bytes!!!!" (fun path ->
         (* "12 bytes!!!!" is exactly 12 bytes. *)
         expect_codegen_ok (Printf.sprintf
           "let codegen_embed_annotated: [u8; 12] = embed_file(\"%s\");" path) ()));

  Alcotest.test_case "embed_file rejects a wrong explicit array-size annotation" `Quick
    (fun () ->
       with_embed_fixture "12 bytes!!!!" (fun path ->
         expect_type_error "array size mismatch" (Printf.sprintf
           "let embedded: [u8; 5] = embed_file(\"%s\");" path) ()));

  Alcotest.test_case "embed_file rejects a missing file with a clear error" `Quick
    (fun () ->
       expect_type_error "embed_file"
         "let embedded = embed_file(\"/nonexistent/takibi_embed_test_missing.bin\");" ());

  Alcotest.test_case "embed_file rejects use inside a function body" `Quick
    (fun () ->
       with_embed_fixture "x" (fun path ->
         expect_type_error "top-level" (Printf.sprintf
           "fn f() -> usize {
              let x = embed_file(\"%s\");
              return 0;
            }" path) ()));

  Alcotest.test_case "embed_file rejects use nested inside another expression" `Quick
    (fun () ->
       with_embed_fixture "x" (fun path ->
         (* A bare `IDENT[expr]` is the only shape `Index` accepts
            syntactically (see parser.mly), so a directly-indexed
            `embed_file(...)[0]` is a parse error, not a case that reaches
            this rejection -- pass it as an ordinary call argument instead,
            which does parse and genuinely exercises the "not a global
            let initializer" check. *)
         expect_type_error "top-level" (Printf.sprintf
           "fn consume(x: usize) { return; }
            fn f() { consume(embed_file(\"%s\")); }" path) ()));

  Alcotest.test_case "embed_file supports let mut for a writable embedded array" `Quick
    (fun () ->
       with_embed_fixture "mutable" (fun path ->
         expect_ok (Printf.sprintf
           "let mut embedded = embed_file(\"%s\");
            fn f() { embedded[0] = 65; }" path) ()));

  (* GitHub issue #226: closed system-register/barrier/TLBI intrinsics, to
     lift kernel/arch/arm64/kernel/timer.S and most of
     kernel/arch/arm64/mm/mmu.S into .tkb. Same coverage shape as the DMA/
     device barrier builtins above: arity, cannot-be-redefined, and
     IR-shape checks. *)
  Alcotest.test_case
    "issue #226: zero-argument register/barrier intrinsics take no arguments"
    `Quick
    (fun () ->
       expect_ok
         "fn issue226_zero_arg_calls() {
            let f: usize = mrs_cntfrq_el0();
            let p: usize = mrs_cntpct_el0();
            let s: usize = mrs_sctlr_el1();
            msr_daifclr_irq();
            msr_daifset_irq();
            tlbi_vmalle1();
            dsb_ish();
            dsb_ishst();
            isb();
          }" ();
       expect_type_error "expects no arguments"
         "fn bad_mrs_call() { let f: usize = mrs_cntfrq_el0(1); }" ();
       expect_type_error "expects no arguments"
         "fn bad_isb_call() { isb(1); }" ());

  Alcotest.test_case
    "issue #226: one-argument register-write/TLBI intrinsics require a usize"
    `Quick
    (fun () ->
       expect_ok
         "fn issue226_one_arg_calls(v: usize) {
            msr_cntp_tval_el0(v);
            msr_cntp_ctl_el0(v);
            msr_sctlr_el1(v);
            msr_mair_el1(v);
            msr_tcr_el1(v);
            msr_ttbr0_el1(v);
            tlbi_vaae1is(v);
            tlbi_vae1is(v);
            tlbi_aside1is(v);
          }" ();
       expect_type_error "expects one argument"
         "fn bad_msr_call() { msr_ttbr0_el1(); }" ();
       expect_type_error "expects one argument"
         "fn bad_tlbi_call(a: usize, b: usize) { tlbi_vae1is(a, b); }" ();
       expect_type_error "cannot unify"
         "fn bad_msr_type(v: i32) { msr_ttbr0_el1(v); }" ());

  Alcotest.test_case "issue #226: smc4 takes four usize and returns usize"
    `Quick
    (fun () ->
       expect_ok
         "fn issue226_smc4(a: usize, b: usize, c: usize, d: usize) -> usize {
            return smc4(a, b, c, d);
          }" ();
       expect_type_error "expects four arguments"
         "fn bad_smc4(a: usize) { let r: usize = smc4(a, a, a); }" ();
       expect_type_error "cannot unify"
         "fn bad_smc4_type(a: i32) { let r: usize = smc4(a, a, a, a); }" ());

  Alcotest.test_case "issue #237: hvc4 takes four usize and returns usize"
    `Quick
    (fun () ->
       expect_ok
         "fn issue237_hvc4(a: usize, b: usize, c: usize, d: usize) -> usize {
            return hvc4(a, b, c, d);
          }" ();
       expect_type_error "expects four arguments"
         "fn bad_hvc4(a: usize) { let r: usize = hvc4(a, a, a); }" ();
       expect_type_error "cannot unify"
         "fn bad_hvc4_type(a: i32) { let r: usize = hvc4(a, a, a, a); }" ());

  Alcotest.test_case
    "issue #226: system-register/barrier/TLBI builtin names cannot be redefined"
    `Quick
    (fun () ->
       List.iter (fun name ->
         expect_type_error "compiler builtin"
           (Printf.sprintf "fn %s() {}" name) ())
         ["mrs_cntfrq_el0"; "mrs_cntpct_el0"; "mrs_sctlr_el1";
          "msr_daifclr_irq"; "msr_daifset_irq"; "tlbi_vmalle1";
          "dsb_ish"; "dsb_ishst"; "isb"];
       List.iter (fun name ->
         expect_type_error "compiler builtin"
           (Printf.sprintf "extern fn %s(v: usize);" name) ())
         ["msr_cntp_tval_el0"; "msr_cntp_ctl_el0"; "msr_sctlr_el1";
          "msr_mair_el1"; "msr_tcr_el1"; "msr_ttbr0_el1";
          "tlbi_vaae1is"; "tlbi_vae1is"; "tlbi_aside1is"];
       expect_type_error "compiler builtin"
         "extern fn smc4(a: usize, b: usize, c: usize, d: usize) -> usize;" ();
       expect_type_error "compiler builtin"
         "extern fn hvc4(a: usize, b: usize, c: usize, d: usize) -> usize;" ());

  Alcotest.test_case
    "issue #226: register/barrier/TLBI intrinsics lower to the named AArch64 instruction"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_issue226_regs(v: usize) -> usize {
            msr_ttbr0_el1(v);
            tlbi_vaae1is(v);
            dsb_ish();
            isb();
            msr_daifset_irq();
            return mrs_sctlr_el1();
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_issue226_regs" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_issue226_regs was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "msr ttbr0_el1" true
         (contains_substring ir "msr ttbr0_el1, $0");
       Alcotest.(check bool) "tlbi vaae1is" true
         (contains_substring ir "tlbi vaae1is, $0");
       Alcotest.(check bool) "dsb ish" true (contains_substring ir "dsb ish");
       Alcotest.(check bool) "isb" true (contains_substring ir "isb");
       Alcotest.(check bool) "daifset" true
         (contains_substring ir "msr DAIFSet, #0x2");
       Alcotest.(check bool) "mrs sctlr_el1 with register output" true
         (contains_substring ir "mrs $0, sctlr_el1"));

  Alcotest.test_case "issue #226: smc4 pins the real SMCCC x0-x3/x0 ABI"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_issue226_smc4(a: usize, b: usize, c: usize, d: usize)
               -> usize {
            return smc4(a, b, c, d);
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_issue226_smc4" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_issue226_smc4 was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "smc instruction" true
         (contains_substring ir "smc #0");
       Alcotest.(check bool) "output pinned to x0" true
         (contains_substring ir "={x0}");
       Alcotest.(check bool) "inputs pinned to x0-x3" true
         (contains_substring ir "{x0},{x1},{x2},{x3}"));

  Alcotest.test_case "issue #237: hvc4 pins the real SMCCC x0-x3/x0 ABI over hvc"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_issue237_hvc4(a: usize, b: usize, c: usize, d: usize)
               -> usize {
            return hvc4(a, b, c, d);
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_issue237_hvc4" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_issue237_hvc4 was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "hvc instruction" true
         (contains_substring ir "hvc #0");
       Alcotest.(check bool) "output pinned to x0" true
         (contains_substring ir "={x0}");
       Alcotest.(check bool) "inputs pinned to x0-x3" true
         (contains_substring ir "{x0},{x1},{x2},{x3}"));

  Alcotest.test_case "issue #228: svc5 takes six usize and returns usize"
    `Quick
    (fun () ->
       expect_ok
         "fn issue228_svc5(nr: usize, a: usize, b: usize, c: usize, d: usize, e: usize) -> usize {
            return svc5(nr, a, b, c, d, e);
          }" ();
       expect_type_error "expects six arguments"
         "fn bad_svc5(a: usize) { let r: usize = svc5(a, a, a, a, a); }" ();
       expect_type_error "cannot unify"
         "fn bad_svc5_type(a: i32) { let r: usize = svc5(a, a, a, a, a, a); }" ());

  Alcotest.test_case "issue #228: svc5 cannot be redefined" `Quick
    (fun () ->
       expect_type_error "compiler builtin"
         "fn svc5(nr: usize, a: usize, b: usize, c: usize, d: usize, e: usize) -> usize { return 0; }" ());

  Alcotest.test_case "issue #228: svc5 pins the real Linux/AArch64 syscall x8/x0-x4/x0 ABI"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_issue228_svc5(nr: usize, a: usize, b: usize, c: usize, d: usize, e: usize)
               -> usize {
            return svc5(nr, a, b, c, d, e);
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_issue228_svc5" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_issue228_svc5 was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "svc instruction" true
         (contains_substring ir "svc #0");
       Alcotest.(check bool) "output pinned to x0" true
         (contains_substring ir "={x0}");
       Alcotest.(check bool) "syscall number pinned to x8, arguments to x0-x4" true
         (contains_substring ir "{x8},{x0},{x1},{x2},{x3},{x4}"));

  (* GitHub issue #232: `LITERAL << N` for N >= 32, with both the shift's
     base and amount being bare integer literals, used to compute at 32-bit
     width (IntLit's own codegen defaults to i32 absent a hint, and BinOp's
     operand recursion used to drop the current node's own ?expected_ty
     instead of forwarding it) -- an LLVM-undefined shift-amount->=-width
     operation, silently `poison`. Found while writing kernel/arch/arm64/mm/
     mmu.tkb's kernel_mmu_activate() (issue #226): TCR_EL1 and TTBR0_EL1
     were both silently written with an unrelated leftover register value
     instead of their own intended values. Fixed by forwarding a concrete
     scalar-integer ?expected_ty hint into BinOp's own operand recursion,
     so a literal buried inside nested Bor/Shl nodes gets the same
     directly-correct-width treatment a bare `let x: usize = <literal>;`
     already got. *)
  Alcotest.test_case
    "issue #232: a usize-typed literal shift by >= 32 folds to the correct value"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_issue232_wide_literal_shift() -> usize {
            let tcr: usize = 0x351b | (1 << 23) | (2 << 32);
            return tcr;
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions
                        "codegen_issue232_wide_literal_shift" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail
             "codegen_issue232_wide_literal_shift was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       (* 0x351b | (1 << 23) | (2 << 32) = 0x20080351b = 8598336795,
          verified with `python3 -c`, not by hand. LLVM's own constant
          folder collapses the whole expression to this one i64 constant
          when (and only when) every operand is correctly i64 from the
          start -- if any sub-expression were still computed at i32, this
          exact decimal value would not appear (either a different,
          wrapped/poisoned value would, or the IR would still show
          separate `shl`/`or` instructions instead of one folded return). *)
       Alcotest.(check bool) "folds to the correct 64-bit constant" true
         (contains_substring ir "ret i64 8598336795"));

  (* GitHub issue #234: a literal Shl/Shr amount >= the operand's own ACTUAL
     LLVM bit width is undefined behavior (LLVM `poison`) even after #232's
     codegen fix -- #232 only fixed one path that produced a WRONG width,
     it never taught the compiler to reject an amount that is out of range
     for whatever width is actually used. Checked at codegen time (after
     the same widening/hint logic #232 relies on has already resolved v1's
     real width), using the actual LLVM type rather than the AST-level
     nominal type -- see llvm_gen.ml's BinOp comment for why. *)
  Alcotest.test_case
    "issue #234: a shift amount equal to the 32-bit operand width is a compile error"
    `Quick
    (expect_codegen_error "shift amount"
       "fn codegen_issue234_shl_oob(x: i32) -> i32 {
          return x << 32;
        }");

  Alcotest.test_case
    "issue #234: a shift amount equal to the 64-bit operand width is a compile error"
    `Quick
    (expect_codegen_error "shift amount"
       "fn codegen_issue234_shr_oob(x: usize) -> usize {
          return x >> 64;
        }");

  Alcotest.test_case
    "issue #234: a shift amount one less than the operand width is accepted"
    `Quick
    (expect_codegen_ok
       "fn codegen_issue234_shl_max_valid(x: i32) -> i32 {
          return x << 31;
        }");

  (* AGENTS.md's documented residual gap from #232: a literal-only shift
     feeding a narrow (u16) context still materializes its base at i32
     (narrow types are deliberately excluded from BinOp's hint-forwarding),
     so an amount >= 32 is undefined at that ACTUAL i32 width even though
     it looks in-range for the nominal u16 type. This closes that gap: it
     is now a compile error instead of silent poison. *)
  Alcotest.test_case
    "issue #234: closes the narrow-context residual gap from issue #232"
    `Quick
    (expect_codegen_error "shift amount"
       "fn codegen_issue234_narrow_gap() -> u16 {
          let x: u16 = 1 << 40;
          return x;
        }");

  Alcotest.test_case
    "checked usize builtins return an exhaustive closed variant" `Quick
    (expect_ok
       "variant CheckedUsize { Value(usize); Overflow; }
        fn checked(a: usize, b: usize) -> usize {
          match checked_add_usize(a, b) {
            CheckedUsize::Value(value) => { return value; }
            CheckedUsize::Overflow => { return 0; }
          }
        }");

  Alcotest.test_case
    "checked usize builtins require the standard result declaration" `Quick
    (expect_type_error "require `variant CheckedUsize"
       "fn checked(a: usize, b: usize) {
          let result = checked_add_usize(a, b);
        }");

  Alcotest.test_case
    "checked usize match must handle overflow" `Quick
    (expect_type_error "non-exhaustive match: 'CheckedUsize::Overflow' not covered"
       "variant CheckedUsize { Value(usize); Overflow; }
        fn checked(a: usize, b: usize) -> usize {
          match checked_mul_usize(a, b) {
            CheckedUsize::Value(value) => { return value; }
          }
        }");

  Alcotest.test_case
    "checked usize builtin names are reserved and operands are usize" `Quick
    (fun () ->
       expect_type_error "compiler builtin"
         "fn checked_add_usize(a: usize, b: usize) -> usize { return a + b; }" ();
       expect_type_error "cannot unify"
         "variant CheckedUsize { Value(usize); Overflow; }
          fn bad(a: u32, b: usize) {
            let result = checked_mul_usize(a, b);
          }" ());

  Alcotest.test_case "signal_fence emits a compiler memory clobber only" `Quick
    (fun () ->
       let _ = gen_codegen "fn codegen_signal_fence() { signal_fence(); }" in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_signal_fence" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_signal_fence was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "memory clobber" true
         (contains_substring ir "~{memory}");
       Alcotest.(check bool) "no hardware fence intrinsic" false
         (contains_substring ir "llvm.arm.dsb"));

  (* -- P4c-1: unsafe extended to slice/array-BASE subslice construction -- *)
  (* Previously unsafe only gated pointer->slice construction (a length
     assertion with NO evidence at all). This extends the SAME gate to a
     slice/array-base subslice whose bounds fail the interval/same-base
     proof (a correlated-bounds case like tcp_echo's data-echo path or
     tcp_parse's checksum span, e.g. ftp4c_chained above) -- letting the
     programmer choose, per call site, between the DEFAULT (checked,
     traps on violation, --forbid-trap rejects it) and an explicit,
     visible unchecked assertion that --forbid-trap accepts. The type
     computed is UNCHANGED either way (unsafe doesn't grant new static
     information, only skips verifying it) -- only whether llvm_gen emits
     the runtime check differs. *)

  Alcotest.test_case
    "unsafe on a SLICE-base subslice (not just a raw pointer) skips the \
     runtime check entirely: the same correlated-bounds construction that \
     recorded 1 trap site unwrapped now records zero, and --forbid-trap \
     accepts it" `Quick
    (expect_trap_sites 0
       "fn ftp4c1_checksum(s: []u8, sum_in: i32) -> i32 {
          let mut sum: i32 = sum_in;
          for b in s { sum = sum + (b as i32); }
          return sum;
        }
        fn ftp4c1_unsafe_slice(pkt: [u8; 40..], raw_ihl: usize, tcp_len: usize) -> i32 !{unsafe} {
          let ihl: usize = min(raw_ihl & 0x3f, 20);
          let room: usize = 40 - ihl;
          let tl: usize = max(tcp_len, 0);
          let tlc: usize = min(tl, room);
          return ftp4c1_checksum(unsafe { pkt[ihl..<ihl + tlc] }, 0);
        }");

  Alcotest.test_case
    "the SAME construction WITHOUT unsafe still records exactly the one \
     trap site it did before this extension existed (the extension is \
     opt-in, not a change to default behavior)" `Quick
    (expect_trap_sites 1
       "fn ftp4c1_checksum2(s: []u8, sum_in: i32) -> i32 {
          let mut sum: i32 = sum_in;
          for b in s { sum = sum + (b as i32); }
          return sum;
        }
        fn ftp4c1_checked_slice(pkt: [u8; 40..], raw_ihl: usize, tcp_len: usize) -> i32 {
          let ihl: usize = min(raw_ihl & 0x3f, 20);
          let room: usize = 40 - ihl;
          let tl: usize = max(tcp_len, 0);
          let tlc: usize = min(tl, room);
          return ftp4c1_checksum2(pkt[ihl..<ihl + tlc], 0);
        }");

  Alcotest.test_case
    "max(a - b, 0) clamps a Sub result whose OWN range has a spuriously \
     negative lower bound (Sub-refined-refined's formula assumes the \
     worst-case combination of a's minimum with b's maximum, which the \
     type system cannot rule out even though the raw subtraction is never \
     actually negative for these bounds) up to a genuinely non-negative \
     range -- proven here by feeding the clamped result into the \
     same-base rule's `wlo >= 0` guard directly, closing a subslice proof \
     that the raw (unclamped) subtraction cannot close on its own. Same \
     mechanism as the tcp_echo.tkb data_len fix in this session, though \
     that site's capacity margin is too tight for the clamp alone to \
     close the proof there (it remains behind `unsafe`) -- this test uses \
     more forgiving bounds specifically to isolate and confirm the clamp \
     mechanism itself" `Quick
    (fun () ->
       expect_trap_sites 0
         "fn ftp4c1_clamp_sub(base: [u8; 1514..], a: {0..<100 as usize}, b: {20..<61 as usize}) -> []u8 {
            let clamped: usize = max(a - b, 0);   // now honestly {0..<80 as i32}
            return base[b..<b + clamped];
          }" ();
       expect_trap_sites 1
         "fn ftp4c1_no_clamp(base: [u8; 1514..], a: {0..<100 as usize}, b: {20..<61 as usize}) -> []u8 {
            let raw = a - b;                      // spuriously negative lower bound
            return base[b..<b + raw];
          }" ());

  (* -- P4c-1 follow-up (issue #249): unsafe extended to SINGLE-ELEMENT ---- *)
  (* array/slice indexing, not just subslice range construction. Before
     this, sub_of_slice (above) was the only load-bearing site checking
     unsafe_depth; load_from_array/load_from_slice/store_to_array/
     store_to_slice always recorded a trap site regardless of unsafe,
     forcing callers who genuinely needed a single-byte access under
     unsafe into an indirect 1-element-slice + slice_eq workaround. Same
     shape as the subslice tests above: one positive (unsafe, zero trap
     sites) paired with a negative control (same code without unsafe,
     unchanged trap-site count -- confirming this is opt-in, not a
     silent widening of default-mode behavior) for each of the four
     changed call sites. *)

  Alcotest.test_case
    "unsafe on a single-element SLICE load skips the runtime check \
     entirely (zero trap sites)" `Quick
    (expect_trap_sites 0
       "fn funsafe249_slice_load(s: []u8, i: usize) -> u8 !{unsafe} {
          return unsafe { s[i] };
        }");

  Alcotest.test_case
    "the SAME single-element slice load WITHOUT unsafe still records the \
     one trap site it always did (opt-in, not a default-mode change)" `Quick
    (expect_trap_sites 1
       "fn funsafe249_slice_load_checked(s: []u8, i: usize) -> u8 {
          return s[i];
        }");

  Alcotest.test_case
    "unsafe on a single-element ARRAY load skips the runtime check \
     entirely (zero trap sites)" `Quick
    (expect_trap_sites 0
       "let mut funsafe249_arr_a: [u8; 8];
        fn funsafe249_array_load(i: usize) -> u8 !{unsafe} {
          return unsafe { funsafe249_arr_a[i] };
        }");

  Alcotest.test_case
    "the SAME single-element array load WITHOUT unsafe still records the \
     one trap site it always did" `Quick
    (expect_trap_sites 1
       "let mut funsafe249_arr_b: [u8; 8];
        fn funsafe249_array_load_checked(i: usize) -> u8 {
          return funsafe249_arr_b[i];
        }");

  Alcotest.test_case
    "unsafe on a single-element SLICE store skips the runtime check \
     entirely (zero trap sites)" `Quick
    (expect_trap_sites 0
       "fn funsafe249_slice_store(s: []u8, i: usize) !{unsafe} {
          unsafe { s[i] = 7 };
        }");

  Alcotest.test_case
    "the SAME single-element slice store WITHOUT unsafe still records the \
     one trap site it always did" `Quick
    (expect_trap_sites 1
       "fn funsafe249_slice_store_checked(s: []u8, i: usize) {
          s[i] = 7;
        }");

  Alcotest.test_case
    "unsafe on a single-element ARRAY store skips the runtime check \
     entirely (zero trap sites)" `Quick
    (expect_trap_sites 0
       "let mut funsafe249_arr_c: [u8; 8];
        fn funsafe249_array_store(i: usize) !{unsafe} {
          unsafe { funsafe249_arr_c[i] = 7 };
        }");

  Alcotest.test_case
    "the SAME single-element array store WITHOUT unsafe still records the \
     one trap site it always did" `Quick
    (expect_trap_sites 1
       "let mut funsafe249_arr_d: [u8; 8];
        fn funsafe249_array_store_checked(i: usize) {
          funsafe249_arr_d[i] = 7;
        }");

  (* GitHub issue #315: unsafe { stmt* } block form -- same escape hatch as
     the funsafe249 group just above, but ONE wrap now needs to skip the
     runtime check at MULTIPLE unproven sites inside it, and must NOT skip
     the check for a sibling statement outside its own closing brace. *)
  Alcotest.test_case
    "unsafe { stmt* } skips the runtime check at every unproven op it \
     wraps (zero trap sites for two ops under one wrap)" `Quick
    (expect_trap_sites 0
       "let mut funsafe315_g1: [u8; 8];
        fn funsafe315_block_two_ops(s: []u8, i: usize, j: usize) !{unsafe} {
          unsafe {
            let a: u8 = s[i];
            funsafe315_g1[j] = a;
          }
        }");

  Alcotest.test_case
    "the SAME two ops WITHOUT the unsafe block still record both trap \
     sites (opt-in, not a default-mode change)" `Quick
    (expect_trap_sites 2
       "let mut funsafe315_g2: [u8; 8];
        fn funsafe315_block_two_ops_checked(s: []u8, i: usize, j: usize) {
          let a: u8 = s[i];
          funsafe315_g2[j] = a;
        }");

  Alcotest.test_case
    "unsafe { stmt* } does not leak past its closing brace: a sibling \
     statement right after the block still gets its trap check" `Quick
    (expect_trap_sites 1
       "let mut funsafe315_g3: [u8; 8];
        fn funsafe315_block_scope_leak(s: []u8, i: usize, j: usize) !{unsafe} {
          unsafe {
            let a: u8 = s[i];
          }
          funsafe315_g3[j] = 1;
        }");

  Alcotest.test_case
    "unsafe { stmt* } wrapping a whole loop body skips the check at every \
     unproven op inside every iteration's (statically single) codegen \
     site (the fd_table.tkb unified_fd_clone_rollback shape: N wraps \
     collapsed into 1 covering the whole loop body)" `Quick
    (expect_trap_sites 0
       "let mut funsafe315_g4: [u8; 8];
        fn funsafe315_loop_wrap(s: []u8, n: usize) !{unsafe} {
          unsafe {
            for i: usize in 0..<n {
              let a: u8 = s[i];
              funsafe315_g4[i] = a;
            }
          }
        }");

  Alcotest.test_case
    "the SAME loop body WITHOUT the unsafe block still records both trap \
     sites" `Quick
    (expect_trap_sites 2
       "let mut funsafe315_g5: [u8; 8];
        fn funsafe315_loop_wrap_checked(s: []u8, n: usize) {
          for i: usize in 0..<n {
            let a: u8 = s[i];
            funsafe315_g5[i] = a;
          }
        }");

  Alcotest.test_case
    "unsafe { stmt* } nested inside another still skips the runtime check \
     (unsafe_depth's doubled increment/decrement doesn't leave it stuck \
     above zero) -- codegen-level cross-check of the type_inf.ml-level \
     nesting test above, since llvm_gen.ml keeps its own separate \
     unsafe_depth counter (sync rule)" `Quick
    (expect_trap_sites 0
       "fn funsafe315_nested(s: []u8, i: usize) -> u8 !{unsafe} {
          unsafe {
            unsafe {
              return s[i];
            }
          }
        }");

  (* GitHub issue #315 follow-up: "unnecessary unsafe" lint, found and
     validated against a reconstruction of this same session's own
     unified_fd_clone_rollback over-wrap mistake (see HISTORY.md and
     feedback_unsafe_block_scoping_discipline memory) -- a proven-safe
     array store nested inside an unsafe { for ... { if ... { ... } } }
     is flagged individually, even though the enclosing scope also
     contains genuinely-needed unsafe operations elsewhere. *)
  Alcotest.test_case
    "unnecessary-unsafe lint: a proven-safe statement nested deep inside \
     an unsafe { } scope is flagged even though sibling statements in the \
     same scope genuinely need it" `Quick
    (expect_unnecessary_unsafe 1
       "let mut funsafe315_lint_a: [u8; 4];
        let mut funsafe315_lint_b: [u8; 4];
        fn funsafe315_lint_nested(s: []u8, n: usize, proven: {0..<4 as usize}) !{unsafe} {
          unsafe {
            for i: usize in 0..<n {
              if (s[i] != 0) {
                funsafe315_lint_a[proven] = 1;
              }
            }
          }
        }");

  Alcotest.test_case
    "unnecessary-unsafe lint: every statement in the scope genuinely \
     needing an elided check records zero unnecessary-unsafe sites" `Quick
    (expect_unnecessary_unsafe 0
       "fn funsafe315_lint_clean(s: []u8, i: usize, j: usize) !{unsafe} {
          unsafe {
            let a: u8 = s[i];
            let b: u8 = s[j];
          }
        }");

  Alcotest.test_case
    "unnecessary-unsafe lint: the expr form (`unsafe { expr }`) is also \
     covered, not just the block form" `Quick
    (expect_unnecessary_unsafe 1
       "fn funsafe315_lint_expr_form(proven: {0..<4 as usize}) -> u8 !{unsafe} {
          let mut arr: [u8; 4];
          return unsafe { arr[proven] };
        }");

  (* Kept last in this group deliberately: Llvm_gen.enable_debug_info flips a
     process-global ref with no way back off (same one-way-switch pattern
     Llvm_gen.setup_target's target_data already uses), so every codegen test
     registered after this one would also get DISubprogram/DILocation
     metadata attached. That's harmless (extra metadata, not a behavior
     change), but keeping this test last avoids it being a surprise to
     earlier, unrelated test cases. *)
  Alcotest.test_case
    "DWARF debug info (-g): attaching a DISubprogram plus a per-statement \
     DILocation still produces IR that LLVM's verifier accepts, across \
     nested If/While bodies (regression coverage for the -g flag)" `Quick
    (fun () ->
       Llvm_gen.enable_debug_info "test.tkb";
       expect_codegen_ok
         "enum DwarfState: u8 {
            Idle = 0;
            Busy = 3;
          }

          struct DwarfPair {
            state: DwarfState;
            count: u32;
          }

          let mut dwarf_global_state: DwarfState = DwarfState::Busy;
          let mut dwarf_global_pair: DwarfPair = { DwarfState::Idle, 42 };
          let mut dwarf_global_slice: [u8; 4..];

          fn codegen_debug_info(n: i32) -> i32 {
            let mut total: i32 = 0;
            let mut i: i32 = 0;
            while (i < n) {
              if (i % 2 == 0) {
                total = total + i;
              }
              i = i + 1;
            }
            return total;
          }" ();
       let ir = Llvm.string_of_llmodule !Llvm_gen.the_module in
       Alcotest.(check bool) "DIGlobalVariableExpression exists"
         true (contains_substring ir "!DIGlobalVariableExpression");
       Alcotest.(check bool) "enum DIType is named"
         true (contains_substring ir "!DICompositeType(tag: DW_TAG_enumeration_type, name: \"DwarfState\"");
       Alcotest.(check bool) "enum variants are symbolic"
         true (contains_substring ir "!DIEnumerator(name: \"DwarfState::Busy\", value: 3");
       Alcotest.(check bool) "struct DIType is named"
         true (contains_substring ir "!DICompositeType(tag: DW_TAG_structure_type, name: \"DwarfPair\"");
       Alcotest.(check bool) "struct member state is present"
         true (contains_substring ir "!DIDerivedType(tag: DW_TAG_member, name: \"state\"");
       Alcotest.(check bool) "slice fat-value members are present"
         true (contains_substring ir "!DIDerivedType(tag: DW_TAG_member, name: \"len\""));

  Alcotest.test_case
    "struct_layout reports LLVM target offsets and tail padding for arbitrary structs" `Quick
    (fun () ->
       ignore (gen_codegen
         "struct LayoutProbe {
            first: u8;
            second: usize;
            third: u16;
          }");
       let (fields, total) = Llvm_gen.struct_layout "LayoutProbe" in
       let offset field = List.assoc field fields in
       Alcotest.(check int64) "first offset" 0L (offset "first");
       Alcotest.(check int64) "usize alignment" 8L (offset "second");
       Alcotest.(check int64) "third offset" 16L (offset "third");
       Alcotest.(check int64) "tail padding" 24L total);

  (* Companion to the test above, covering the parts of ditype_of_ast
     (lib/llvm_gen.ml) that one only exercises with a pointer-to-struct
     parameter, a struct-typed local, and an array-typed local: the i32
     params/locals in the previous test never touch the TypePtr / TypeNamed
     / TypeArray branches at all. Also exercises the di_struct_placeholders
     cache: DwarfNode is named twice (once via the pointer parameter, once
     via the direct local), which must resolve to the same cached
     forward-decl rather than create a duplicate metadata node each time.
     GitHub issue #240 note: this test originally also covered a SELF-
     referential struct (`next: *DwarfNode` as a field of DwarfNode
     itself) as a regression guard for ditype_of_ast's "must not hang/
     crash on self-reference" forward-declaration design. #240 now
     rejects any ordinary struct-typed pointer field, including a
     self-referential one, at declaration time -- so that specific shape
     can no longer be constructed in Takibi source at all, and
     ditype_of_ast's own self-reference guard is unreachable from any
     valid program (harmless dead code, not a regression; see the
     dedicated #240 rejection test just below for that shape). *)
  Alcotest.test_case
    "DWARF debug info (-g): pointer-to-struct parameter, struct-typed local, \
     and array-typed local all produce verifier-accepted IR \
     (regression coverage for ditype_of_ast's struct-as-forward-declaration design)" `Quick
    (expect_codegen_ok
       "struct DwarfNode {
          value: i32;
        }

        fn codegen_debug_info_struct_ptr(n: *DwarfNode) -> i32 {
          let mut node: DwarfNode;
          let mut arr: [i32; 4];
          node.value = n.value;
          arr[0] = node.value;
          return arr[0];
        }");

  Alcotest.test_case
    "GitHub issue #240: a self-referential struct pointer field is rejected \
     (the exact shape the DWARF test above used to cover before #240)" `Quick
    (expect_type_error "cannot hold pointer type"
       "struct DwarfNodeSelfRef {
          value: i32;
          next: *DwarfNodeSelfRef;
        }");

  Alcotest.test_case
    "DWARF debug info (-g): function pointer parameters are described as \
     pointer-to-subroutine types, not bare subroutine types"
    `Quick
    (expect_codegen_ok
       "fn codegen_debug_info_fnptr_target() {
        }

        fn codegen_debug_info_fnptr_param(handler: fn() -> void) {
          handler();
        }

        fn codegen_debug_info_fnptr_call() {
          codegen_debug_info_fnptr_param(codegen_debug_info_fnptr_target);
        }");

  Alcotest.test_case
    "DWARF debug info (-g): a variant parameter and immutable local with a \
     payload-binding match produce verifier-accepted IR without emitting \
     malformed typeless local-variable metadata"
    `Quick
    (fun () ->
       expect_codegen_ok
         "variant DwarfVariantResult {
          Empty;
          Value(i32);
        }

        fn codegen_debug_info_variant(input: DwarfVariantResult) -> i32 {
          let dwarf_variant_unrepresented: DwarfVariantResult = input;
          match dwarf_variant_unrepresented {
            DwarfVariantResult::Empty => { return 0; }
            DwarfVariantResult::Value(value) => { return value; }
          }
        }" ();
       let ir = Llvm.string_of_llmodule !Llvm_gen.the_module in
       Alcotest.(check bool) "variant local has no typeless DILocalVariable"
         false (contains_substring ir
           "DILocalVariable(name: \"dwarf_variant_unrepresented\""));

  (* Distinct from the plain-parameter variant test just above: a
     stable_replace() result's inferred type reaches ditype_of_ast as a
     raw, unresolved TypeNamed (this compiler-builtin call's return type is
     produced directly by type_inf.ml's own special-cased inference, not
     via the ordinary resolve_special_type normalization other `let`
     annotations go through), not the already-normalized TypeVariant the
     parameter case above exercises. Before ditype_of_ast's TypeNamed case
     also checked variant_lltypes (see that fix's comment), this crashed
     with "Unknown named type" the first time a real -g build reached a
     `let x: SomeVariant = stable_replace(...)` -- found building
     kernel/build/qemu/kernel-debug.elf, where kernel/kernel/process.tkb's
     `let previous: ScheduledProcessValue = stable_replace(...)` hit
     exactly this. *)
  Alcotest.test_case
    "DWARF debug info (-g): a stable_replace() result's un-normalized \
     variant-named local type produces no typeless local-variable metadata"
    `Quick
    (fun () ->
       expect_codegen_ok
         "linear view DwarfStableGuard[lock: addr];
        linear struct DwarfStableOwner[n: usize] {
          id: usize @ n;
          value: i32;
        }
        variant DwarfStableValue {
          Empty;
          Full(exists n: usize. DwarfStableOwner[n]);
        }
        struct DwarfStableSlot {
          private mutex: i32;
          private value: DwarfStableValue;
        }
        private let mut dwarf_stable_slot: DwarfStableSlot;
        fn dwarf_stable_lock(m: *i32 @ lock) -> DwarfStableGuard[lock] {
          return view DwarfStableGuard[lock];
        }
        fn dwarf_stable_unlock(g: sink DwarfStableGuard[lock], m: *i32 @ lock) {}
        fn dwarf_stable_drop(owner: sink DwarfStableOwner[n]) {}
        fn dwarf_stable_use() {
          let guard = dwarf_stable_lock(&dwarf_stable_slot.mutex);
          let dwarf_stable_previous: DwarfStableValue = stable_replace(
            guard, &dwarf_stable_slot.mutex, dwarf_stable_slot.value,
            DwarfStableValue::Empty);
          match dwarf_stable_previous {
            DwarfStableValue::Empty => {}
            DwarfStableValue::Full(owner) => { dwarf_stable_drop(owner); }
          }
          dwarf_stable_unlock(guard, &dwarf_stable_slot.mutex);
        }" ();
       let ir = Llvm.string_of_llmodule !Llvm_gen.the_module in
       Alcotest.(check bool) "stable_replace variant local has no typeless DILocalVariable"
         false (contains_substring ir
           "DILocalVariable(name: \"dwarf_stable_previous\""));

  Alcotest.test_case
    "DWARF debug info (-g): unsupported variant, tuple, and view locals are \
     omitted from local DIEs by policy" `Quick
    (fun () ->
       expect_codegen_ok
         "linear view DwarfUnsupportedView;
          variant DwarfUnsupportedVariant {
            Empty;
            Value(i32);
          }
          fn dwarf_unsupported_consume(g: sink DwarfUnsupportedView) {}
          fn dwarf_unsupported_locals(input: DwarfUnsupportedVariant) -> i32 {
            let dwarf_unsupported_variant: DwarfUnsupportedVariant = input;
            let dwarf_unsupported_tuple: (i32, i32) = (1, 2);
            let dwarf_unsupported_view: DwarfUnsupportedView = view DwarfUnsupportedView;
            dwarf_unsupported_consume(dwarf_unsupported_view);
            match dwarf_unsupported_variant {
              DwarfUnsupportedVariant::Empty => { return 0; }
              DwarfUnsupportedVariant::Value(value) => { return value; }
            }
          }" ();
       let ir = Llvm.string_of_llmodule !Llvm_gen.the_module in
       List.iter (fun name ->
         Alcotest.(check bool) (name ^ " has no DILocalVariable") false
           (contains_substring ir ("DILocalVariable(name: \"" ^ name ^ "\""))
       ) [ "dwarf_unsupported_variant"; "dwarf_unsupported_tuple";
           "dwarf_unsupported_view" ]);

  Alcotest.test_case
    "DWARF debug info (-g): variant, tuple, and view locals survive isolated \
     AArch64 object emission" `Quick
    (expect_aarch64_debug_object
       "linear view DwarfObjectView;
        variant DwarfObjectVariant {
          Empty;
          Value(i32);
        }
        fn dwarf_object_consume(g: sink DwarfObjectView) {}
        fn dwarf_object_locals(input: DwarfObjectVariant) -> i32 {
          let object_variant: DwarfObjectVariant = input;
          let object_tuple: (i32, i32) = (1, 2);
          let object_view: DwarfObjectView = view DwarfObjectView;
          dwarf_object_consume(object_view);
          match object_variant {
            DwarfObjectVariant::Empty => { return 0; }
            DwarfObjectVariant::Value(value) => { return value; }
          }
        }");

  Alcotest.test_case
    "pointer difference codegens as an isize element count"
    `Quick
    (expect_codegen_ok
       "fn codegen_ptrdiff(a: *u32, b: *u32) -> isize {
          return b - a;
        }");

  Alcotest.test_case
    "isize range arithmetic can bridge to a proven usize subslice bound"
    `Quick
    (expect_codegen_ok
       "let mut codegen_isize_slice_buf: [u8; 8 * 1536];
        let mut codegen_isize_slice_idx: isize = 0;
        fn codegen_isize_slice() -> [u8; 1514..] {
          let idx: usize = max(min(codegen_isize_slice_idx, 7), 0)
            as {0..<8 as usize};
          let offset: usize = idx * 1536 + 10;
          return codegen_isize_slice_buf[offset..<offset + 1514];
        }");

  (* Kept last, in this exact order, for the same one-way-switch reason as
     the DWARF tests above: Llvm_gen.setup_target permanently overwrites
     Llvm_gen.target_data for the rest of this test process -- there is no
     way to reset back to "no target machine" (GitHub issue #326:
     Llvm_gen.the_module itself is recreated fresh per gen_program call, but
     target_data and the configured triple/datalayout it implies are
     deliberately reapplied to each new module, not reset). Every codegen
     test registered above this point
     relies on that state staying None (usize/pointer-int conversions
     falling back to i64 -- see Llvm_gen.usize_lltype), so nothing may be
     added after this group without re-checking that assumption.
     Regression coverage for the Cortex-M7/STM32 bring-up's usize-width fix
     (usize must be 32-bit on a 32-bit-pointer target, not hardcoded i64). *)
  Alcotest.test_case
    "usize is i64-wide when no target machine has been configured \
     (the fallback every earlier codegen test above implicitly relies on)"
    `Quick
    (fun () ->
       Alcotest.(check int) "usize_bitwidth" 64 (Llvm_gen.usize_bitwidth ());
       Alcotest.(check int) "isize_bitwidth" 64 (Llvm_gen.isize_bitwidth ()));

  Alcotest.test_case
    "usize is 64-bit on a real 64-bit-pointer target (aarch64-none-elf), \
     confirming the DataLayout-driven path agrees with the no-target \
     fallback for the target this project has shipped on so far" `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"aarch64-none-elf" ()
       in
       Alcotest.(check int) "usize_bitwidth" 64 (Llvm_gen.usize_bitwidth ());
       Alcotest.(check int) "isize_bitwidth" 64 (Llvm_gen.isize_bitwidth ()));

  (* GitHub issue #218 follow-up (checked slice-to-struct-pointer casts):
     needs a real target machine, since the codegen-side re-check (sync
     rule with type_inf.ml's own TSlice Cast case) reads the DataLayout's
     actual abi_size, unlike type_inf.ml's own const_type_size fast path
     -- so this belongs in this post-setup_target group, not with the
     type-check-only tests above. *)
  Alcotest.test_case "the unsafe wrapping an unprovable slice-to-struct cast is NOT flagged as unnecessary" `Quick
    (expect_unnecessary_unsafe 0
       "struct packed P4 { a: u32; }
        fn f(s: []u8) -> u32 !{unsafe} {
          let p: *P4 = unsafe { s as *P4 };
          return p.a;
        }");

  Alcotest.test_case
    "array GEP preserves a usize index at i64 width on AArch64"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "let mut codegen_wide_index_buf: [u8; 4];
          fn codegen_wide_index(i: usize) -> u8 {
            return codegen_wide_index_buf[i];
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_wide_index" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_wide_index was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "no narrowing truncation" false
         (contains_substring ir "trunc i64");
       Alcotest.(check bool) "GEP uses i64 index" true
         (contains_substring ir "getelementptr" && contains_substring ir "i64"));

  Alcotest.test_case
    "usize is 32-bit on a 32-bit-pointer target (thumbv7em-none-eabi / \
     cortex-m7, i.e. STM32F746): the regression this group exists to catch \
     is usize silently staying i64-wide on a target where pointers are 32 \
     bits" `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"thumbv7em-none-eabi" ~cpu:"cortex-m7" ()
       in
       Alcotest.(check int) "usize_bitwidth" 32 (Llvm_gen.usize_bitwidth ());
       Alcotest.(check int) "isize_bitwidth" 32 (Llvm_gen.isize_bitwidth ()));

  Alcotest.test_case
    "DMA/device barriers lower to ARM DSB intrinsics on Cortex-M" `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_barriers_cortexm() {
            dma_publish();
            dma_consume();
            device_fence();
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_barriers_cortexm" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_barriers_cortexm was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check int) "three dsb calls" 3
         (count_substring ir "llvm.arm.dsb"));

  Alcotest.test_case
    "DMA cache builtins lower to Cortex-M7 SCB line maintenance loops" `Quick
    (fun () ->
       let _ = gen_codegen
         "fn codegen_dma_cache(p: *align(32) u8, n: usize) {
            dma_prepare_tx(p, n);
            dma_prepare_rx(p, n);
            dma_finish_rx(p, n);
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_dma_cache" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_dma_cache was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "cache-line loop" true
         (contains_substring ir "dma.cache.cond");
       Alcotest.(check int) "three volatile SCB writes" 3
         (count_substring ir "store volatile i32");
       Alcotest.(check int) "cache operations are fenced" 4
         (count_substring ir "llvm.arm.dsb"));

  Alcotest.test_case
    "full pipeline still verifies under the 32-bit target for the coerce \
     paths usize touches: pointer -> usize -> pointer round-trip (ptrtoint/ \
     inttoptr auto-adjusting to the 32-bit width) and an explicit i64 -> \
     usize narrowing cast (exercises the trunc, not zext, branch added to \
     coerce's TypeUsize case -- on a 64-bit target this same source would \
     have needed zext instead, so this specifically catches a \
     wrong-direction trunc/zext bug)" `Quick
    (expect_codegen_ok
       "fn codegen_usize_ptr_roundtrip_cortexm(p: *i32) -> *i32 {
          let addr: usize = p as usize;
          return addr as *i32;
        }

        fn codegen_usize_narrowing_cast_cortexm(n: i64) -> usize {
          return n as usize;
        }

        fn codegen_ptrdiff_cortexm(a: *u32, b: *u32) -> isize {
          return b - a;
        }");

  (* Global initializer constant folding: `as` casts and references to
     earlier immutable global constants. Previously eval_const only
     recognized bare IntLit/StructLit initializers, so any of these forms
     raised "unsupported constant expression" -- see CLAUDE.md's "Global
     let / let mut and Array-Size Constants" follow-up notes for the two
     real-world cases (an `as i32` cast on an MMIO bit-pattern constant, and
     HTTP_SERVER_IP duplicating OUR_IP's array literal) that motivated this. *)
  Alcotest.test_case
    "global let initializer: `as` cast on a literal folds (the ETH_RDES0_OWN \
     case -- previously had to be written as a bare literal with no cast)"
    `Quick
    (expect_codegen_ok
       "let GLOBALCONST_ETH_RDES0_OWN: i32 = 0x80000000 as i32;
        fn codegen_globalconst_cast_use() -> i32 { return GLOBALCONST_ETH_RDES0_OWN; }");

  Alcotest.test_case
    "global let initializer: unary minus (desugared to BinOp(Sub, IntLit 0, _)) \
     folds to a negative constant" `Quick
    (expect_codegen_ok
       "let GLOBALCONST_NEG: i32 = -5;
        fn codegen_globalconst_neg_use() -> i32 { return GLOBALCONST_NEG; }");

  Alcotest.test_case
    "global let initializer: a chained truncating cast folds correctly at \
     each layer, not just the outermost one -- (300 as u8) as i32 must yield \
     44 (300 mod 256), not 300, confirming the intermediate u8 truncation \
     actually happens before the final widen" `Quick
    (expect_codegen_ok
       "let GLOBALCONST_CHAINED_CAST: i32 = (300 as u8) as i32;
        fn codegen_globalconst_chained_cast_use() -> i32 { return GLOBALCONST_CHAINED_CAST; }");

  Alcotest.test_case
    "global let initializer: a scalar reference to an earlier immutable \
     global constant folds" `Quick
    (expect_codegen_ok
       "let GLOBALCONST_A: i32 = 1;
        let GLOBALCONST_B: i32 = GLOBALCONST_A;
        fn codegen_globalconst_scalar_ref_use() -> i32 { return GLOBALCONST_B; }");

  Alcotest.test_case
    "global enum initializer: an enum variant folds to its underlying value"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "enum GlobalInitState: u8 { Idle; Running; }
          let mut GLOBAL_ENUM_STATE: GlobalInitState = GlobalInitState::Running;
          fn codegen_global_enum_use() -> GlobalInitState { return GLOBAL_ENUM_STATE; }"
       in
       let gv = match Llvm.lookup_global "GLOBAL_ENUM_STATE" !Llvm_gen.the_module with
         | Some gv -> gv
         | None -> Alcotest.fail "GLOBAL_ENUM_STATE was not emitted"
       in
       let init = match Llvm.global_initializer gv with
         | Some init -> Llvm.string_of_llvalue init
         | None -> Alcotest.fail "GLOBAL_ENUM_STATE has no initializer"
       in
       Alcotest.(check string) "Running discriminant" "i8 1" init);

  Alcotest.test_case
    "global enum initializer: an enum variant can be cast to its underlying type"
    `Quick
    (fun () ->
       let _ = gen_codegen
         "enum GlobalInitCode: u16 { First = 7; Second = 11; }
          let GLOBAL_ENUM_CODE: u16 = GlobalInitCode::Second as u16;
          fn codegen_global_enum_code_use() -> u16 { return GLOBAL_ENUM_CODE; }"
       in
       let gv = match Llvm.lookup_global "GLOBAL_ENUM_CODE" !Llvm_gen.the_module with
         | Some gv -> gv
         | None -> Alcotest.fail "GLOBAL_ENUM_CODE was not emitted"
       in
       let init = match Llvm.global_initializer gv with
         | Some init -> Llvm.string_of_llvalue init
         | None -> Alcotest.fail "GLOBAL_ENUM_CODE has no initializer"
       in
       Alcotest.(check string) "Second discriminant" "i16 11" init);

  Alcotest.test_case
    "global let initializer: an array-typed reference to an earlier \
     immutable global constant folds (the HTTP_SERVER_IP = OUR_IP case -- \
     previously rejected at the type-check stage because Var's ordinary \
     array-decay-to-pointer rule doesn't match an array-typed annotation)"
    `Quick
    (expect_codegen_ok
       "let GLOBALCONST_OUR_IP: [u8; 4] = {192, 0, 2, 1};
        let GLOBALCONST_SERVER_IP: [u8; 4] = GLOBALCONST_OUR_IP;
        fn codegen_globalconst_array_ref_use() -> u8 { return GLOBALCONST_SERVER_IP[0]; }");

  (* Found while extending kernel/net/tcp.tkb for GitHub issue #180 (a
     [PendingTcpKind; N] queue-slot array): reading an element out of an
     array-of-enum and comparing it inline to an enum literal
     (`arr[i] == Variant`) used to make load_from_array/load_through_ptr
     return the element's raw GEP pointer instead of loading it (the
     TypeNamed _ branch didn't distinguish enum from struct the way the
     plain-variable Var case already did), so the Eq codegen fed a
     pointer and an i8 literal straight into build_icmp -- LLVM's
     verifier then rejected it as invalid IR, an internal compiler error
     rather than either a correct compile or a normal diagnostic. GitHub
     issue #183. Both a compile-time-constant index and a runtime
     (loop-variable) index reproduced it; both are covered here. *)
  Alcotest.test_case
    "issue #183: reading an array-of-enum element by a CONSTANT index and \
     comparing it inline to an enum literal codegens (used to crash with \
     invalid LLVM IR: a pointer compared to an i8 literal, no load \
     inserted)"
    `Quick
    (expect_codegen_ok
       "enum Issue183Kind: u8 { None; Data; Fin; }
        let mut ISSUE183_KINDS: [Issue183Kind; 4];
        fn codegen_issue183_const_index() -> bool {
            return ISSUE183_KINDS[0] == Issue183Kind::None;
        }");

  Alcotest.test_case
    "issue #183: reading an array-of-enum element by a RUNTIME (loop \
     counter) index and comparing it inline to an enum literal codegens"
    `Quick
    (expect_codegen_ok
       "enum Issue183Kind: u8 { None; Data; Fin; }
        let mut ISSUE183_KINDS2: [Issue183Kind; 4];
        fn codegen_issue183_runtime_index() -> usize {
            let mut i: usize = 0;
            while (i < 4) {
                if (i < 4) {
                    if (ISSUE183_KINDS2[i] == Issue183Kind::None) {
                        return i;
                    }
                }
                i = i + 1;
            }
            return 0;
        }");

  (* GitHub issue #183 follow-up ("Layer 1"): `let mut id: ty = match
     disc { arms };` -- lets a chain of fallible steps (each its own
     `match`) read as flat statements instead of nesting one match per
     step. Exhaustiveness and payload-binder scoping are the SAME
     existing Match machinery, reused unchanged (see lib/ast.ml's
     LetMatch comment for why). The one new rule this construct enforces
     itself: every arm's last statement must be a bare tail expression
     (GitHub issue #184's `Yield` sugar -- `Pattern => e;`, this arm's
     value) or return/break/continue (diverges). *)
  Alcotest.test_case
    "issue #183 layer 1: let-match flattens a chain of fallible steps \
     (each arm's value is its bare tail expr, GitHub issue #184's Yield \
     sugar)"
    `Quick
    (expect_codegen_ok
       "must_use variant LmAllocResult { OutOfMemory; Allocated(usize); }
        must_use variant LmCreateResult { OutOfMemory; Created(usize); }
        fn lm_alloc() -> LmAllocResult { return LmAllocResult::Allocated(42); }
        fn lm_free(p: usize) { }
        fn lm_create() -> LmCreateResult {
            let mut text: usize = match lm_alloc() {
                LmAllocResult::OutOfMemory => { return LmCreateResult::OutOfMemory; }
                LmAllocResult::Allocated(p) => { p }
            };
            let mut data: usize = match lm_alloc() {
                LmAllocResult::OutOfMemory => { lm_free(text); return LmCreateResult::OutOfMemory; }
                LmAllocResult::Allocated(p) => { p }
            };
            return LmCreateResult::Created(text + data);
        }");

  Alcotest.test_case
    "issue #183 layer 1: let-match still requires exhaustiveness -- a \
     missing variant arm is the same error a plain match would give"
    `Quick
    (expect_type_error "non-exhaustive match"
       "must_use variant LmAllocResult2 { OutOfMemory; Allocated(usize); }
        fn lm_alloc2() -> LmAllocResult2 { return LmAllocResult2::Allocated(42); }
        fn lm_missing_arm() -> usize {
            let mut text: usize = match lm_alloc2() {
                LmAllocResult2::Allocated(p) => { p }
            };
            return text;
        }");

  Alcotest.test_case
    "issue #183 layer 1: an arm that neither yields a value nor diverges \
     is rejected -- this is the safety check hand-writing `let mut x: T;` \
     then a plain `match` does not get for free (that pattern has no \
     definite-assignment checking at all)"
    `Quick
    (expect_type_error "must end in"
       "must_use variant LmAllocResult3 { OutOfMemory; Allocated(usize); }
        fn lm_alloc3() -> LmAllocResult3 { return LmAllocResult3::Allocated(42); }
        fn lm_forgot_assign() -> usize {
            let mut text: usize = match lm_alloc3() {
                LmAllocResult3::OutOfMemory => { }
                LmAllocResult3::Allocated(p) => { p }
            };
            return text;
        }");

  Alcotest.test_case
    "issue #183 layer 1 (GitHub issue #184 follow-up): an arm ending in \
     an ordinary assignment statement, not a bare tail expression, does \
     not count as this arm's value -- `other = p;` is `Expr(Assign(...))`, \
     not `Yield`, so it is rejected the same way an empty body is" `Quick
    (expect_type_error "must end in"
       "must_use variant LmAllocResult4 { OutOfMemory; Allocated(usize); }
        fn lm_alloc4() -> LmAllocResult4 { return LmAllocResult4::Allocated(42); }
        fn lm_wrong_target() -> usize {
            let mut other: usize = 0;
            let mut text: usize = match lm_alloc4() {
                LmAllocResult4::OutOfMemory => { return 0; }
                LmAllocResult4::Allocated(p) => { other = p; }
            };
            return text;
        }");

  Alcotest.test_case
    "issue #183 layer 1: let-match with a linear `view` payload -- the \
     diverging arm never produces the bound name (nothing pending to \
     consume there), the continuing arm's bare-tail Yield produces it \
     fresh, and the erased view type (no runtime storage, no pre-allocated \
     alloca) still codegens since the rewritten Assign needs a locals \
     entry to exist before it can overwrite one" `Quick
    (expect_codegen_ok
       "linear view LmToken;
        must_use variant LmTakeResult { Empty; Ready(LmToken); }
        fn lm_take() -> LmTakeResult { return LmTakeResult::Ready(view LmToken); }
        fn lm_consume(t: sink LmToken) -> usize { return 1; }
        fn lm_use_token() -> usize {
            let mut tok: LmToken = match lm_take() {
                LmTakeResult::Empty => { return 0; }
                LmTakeResult::Ready(t) => { t }
            };
            return lm_consume(tok);
        }");

  (* GitHub issue #183's existential follow-up: a `let`/LetMatch annotation
     may now be a bare `exists idx: T. Owner[idx]`, packaging an indexed
     runtime owner/erased view/tuple exactly like a variant payload already
     could. This is what actually lets initial_process_create's own three
     sequential page_alloc() calls (the ORIGINAL motivating example for
     LetMatch, kernel/kernel/process.tkb) flatten: page_alloc()'s success
     case returns `exists page: usize. PageOwner[page]`, a fresh index per
     call that cannot be written as a single, static, non-existential type. *)
  Alcotest.test_case
    "issue #183 existential follow-up: let-match may bind an existential \
     indexed owner, flattening the exact initial_process_create shape -- \
     each step's success arm re-packs its match-arm-opened (rigid) witness \
     into the let's existential annotation, and the final variant \
     construction re-packs all three (through a tuple) into its own \
     triple-nested existential payload" `Quick
    (expect_codegen_ok
       "linear struct ExPageOwner[page: usize] { private index: usize; }
        must_use variant ExPageAllocResult {
            OutOfMemory; Allocated(exists page: usize. ExPageOwner[page]);
        }
        fn ex_page_alloc() -> ExPageAllocResult {
            let mut owner: ExPageOwner[1] = { 0 };
            return ExPageAllocResult::Allocated(owner);
        }
        fn ex_page_free(owner: sink ExPageOwner[page]) { }
        must_use variant ExCreateResult {
            OutOfMemory;
            Created(exists text_page: usize. exists data_page: usize.
                    (ExPageOwner[text_page], ExPageOwner[data_page]));
        }
        fn ex_create() -> ExCreateResult {
            let mut text: exists text_page: usize. ExPageOwner[text_page] =
                match ex_page_alloc() {
                    ExPageAllocResult::OutOfMemory => {
                        return ExCreateResult::OutOfMemory;
                    }
                    ExPageAllocResult::Allocated(p) => { p }
                };
            let mut data: exists data_page: usize. ExPageOwner[data_page] =
                match ex_page_alloc() {
                    ExPageAllocResult::OutOfMemory => {
                        ex_page_free(text);
                        return ExCreateResult::OutOfMemory;
                    }
                    ExPageAllocResult::Allocated(p) => { p }
                };
            return ExCreateResult::Created((text, data));
        }");

  Alcotest.test_case
    "issue #183 existential follow-up: the affine/linear checker still sees \
     through the existential wrapper -- forgetting to free an existentially \
     bound owner on a cleanup path is still rejected, the same all-paths \
     guarantee ordinary (non-existential) LetMatch already enforced" `Quick
    (expect_type_error "still pending"
       "linear struct ExLeakOwner[page: usize] { private index: usize; }
        must_use variant ExLeakAllocResult {
            OutOfMemory; Allocated(exists page: usize. ExLeakOwner[page]);
        }
        fn ex_leak_alloc() -> ExLeakAllocResult {
            let mut owner: ExLeakOwner[1] = { 0 };
            return ExLeakAllocResult::Allocated(owner);
        }
        fn ex_leak_free(owner: sink ExLeakOwner[page]) { }
        must_use variant ExLeakResult { OutOfMemory; Ready; }
        fn ex_leaky() -> ExLeakResult {
            let mut text: exists page: usize. ExLeakOwner[page] =
                match ex_leak_alloc() {
                    ExLeakAllocResult::OutOfMemory => {
                        return ExLeakResult::OutOfMemory;
                    }
                    ExLeakAllocResult::Allocated(p) => { p }
                };
            let mut data: exists page: usize. ExLeakOwner[page] =
                match ex_leak_alloc() {
                    ExLeakAllocResult::OutOfMemory => {
                        return ExLeakResult::OutOfMemory;
                    }
                    ExLeakAllocResult::Allocated(p) => { p }
                };
            ex_leak_free(text);
            ex_leak_free(data);
            return ExLeakResult::Ready;
        }");

  (* GitHub issue #183's non-mut follow-up: `let id: ty = match ...;` (no
     `mut`) reads as "this value is fixed after this statement", matching
     Kotlin/Swift's own "definitely-assigned val across branches" pattern.
     `id` is still alloca-based internally (an arm's own `id = e;` needs a
     memory location no matter what -- see llvm_gen.ml's LetMatch case),
     but type_inf.ml downgrades it back to immutable in the tyenv that
     continues past the whole statement, so ordinary Assign's own
     "cannot assign to immutable variable" check catches any later
     `id = ...;` outside the arms, exactly like a plain non-mut `let`. *)
  Alcotest.test_case
    "issue #183 non-mut follow-up: `let id: ty = match ...;` (no `mut`) \
     still compiles and reads back correctly -- the arms' own internal \
     assignment is exempt, only code AFTER the statement is restricted" `Quick
    (expect_codegen_ok
       "must_use variant LmNoMutResult { OutOfMemory; Allocated(usize); }
        fn lm_nomut_alloc() -> LmNoMutResult { return LmNoMutResult::Allocated(42); }
        fn lm_nomut_use() -> usize {
            let text: usize = match lm_nomut_alloc() {
                LmNoMutResult::OutOfMemory => { return 0; }
                LmNoMutResult::Allocated(p) => { p }
            };
            return text;
        }");

  Alcotest.test_case
    "issue #183 non-mut follow-up: assigning to a non-mut let-match \
     binding OUTSIDE its own arms is rejected, the same \"use let mut\" \
     error a plain non-mut `let` already gives" `Quick
    (expect_type_error "cannot assign to immutable variable"
       "must_use variant LmNoMutReassignResult { OutOfMemory; Allocated(usize); }
        fn lm_nomut_reassign_alloc() -> LmNoMutReassignResult {
            return LmNoMutReassignResult::Allocated(42);
        }
        fn lm_nomut_reassign() -> usize {
            let text: usize = match lm_nomut_reassign_alloc() {
                LmNoMutReassignResult::OutOfMemory => { return 0; }
                LmNoMutReassignResult::Allocated(p) => { p }
            };
            text = 5;
            return text;
        }");

  (* GitHub issue #207 follow-up: `let [mut] id = match disc { arms };`
     (the type annotation itself omitted, not just its content) infers
     id's type from what the arms' Yield expressions produce, via the
     same TVar/of_ast_opt machinery an ordinary untyped `let` already
     uses -- reuses lm_nomut-style variants above rather than introducing
     new ones. Deliberately narrower than the still-paused GitHub issue
     #212 "let-else" idea: every arm below stays fully, explicitly named,
     so no wildcard is ever introduced. *)
  Alcotest.test_case
    "issue #207: `let id = match disc { arms };` with the type annotation \
     itself omitted infers id's type from the arms' Yield expressions" `Quick
    (expect_codegen_ok
       "must_use variant Lm207Result { OutOfMemory; Allocated(usize); }
        fn lm207_alloc() -> Lm207Result { return Lm207Result::Allocated(42); }
        fn lm207_use() -> usize {
            let text = match lm207_alloc() {
                Lm207Result::OutOfMemory => { return 0; }
                Lm207Result::Allocated(p) => { p }
            };
            return text;
        }");

  Alcotest.test_case
    "issue #207: `let mut id = match disc { arms };` (omitted annotation, \
     with `mut`) also infers id's type correctly" `Quick
    (expect_codegen_ok
       "must_use variant Lm207MutResult { OutOfMemory; Allocated(usize); }
        fn lm207mut_alloc() -> Lm207MutResult { return Lm207MutResult::Allocated(1); }
        fn lm207mut_use() -> usize {
            let mut text = match lm207mut_alloc() {
                Lm207MutResult::OutOfMemory => { return 0; }
                Lm207MutResult::Allocated(p) => { p }
            };
            text = text + 1;
            return text;
        }");

  Alcotest.test_case
    "issue #207: an omitted-annotation LetMatch whose arms never pin down \
     a concrete type is rejected (would otherwise silently default to \
     i32) -- the load-bearing check_undetermined_lets extension this \
     feature needed, not something that came for free" `Quick
    (expect_type_error "cannot determine a concrete type"
       "must_use variant Lm207UndetResult { A; B; }
        fn lm207undet_pick() -> Lm207UndetResult { return Lm207UndetResult::A; }
        fn lm207undet_use() {
            let v = match lm207undet_pick() {
                Lm207UndetResult::A => { return; }
                Lm207UndetResult::B => { return; }
            };
        }");

  Alcotest.test_case
    "issue #207: an omitted-annotation LetMatch whose arms yield genuinely \
     incompatible types is still rejected with a clear unification error" `Quick
    (expect_type_error "cannot unify"
       "variant Lm207ConflictResult { A(usize); B(bool); }
        fn lm207conflict_pick() -> Lm207ConflictResult { return Lm207ConflictResult::A(1); }
        fn lm207conflict_use() {
            let v = match lm207conflict_pick() {
                Lm207ConflictResult::A(x) => { x }
                Lm207ConflictResult::B(y) => { y }
            };
        }");

  (* Found while cleaning up kernel/mm/page.tkb's magic numbers: a refined
     type's bound could only be a bare integer literal or a single const
     name, unlike array_size (used for `[T; N]`), which already supports
     +/-/*//, parens, and sizeof. refined_bound now mirrors array_size's
     grammar exactly, so a refinement can spell out how its own bound was
     derived (e.g. `(BOOT_PAGE_COUNT - 1) * PAGE_SIZE + 1`) instead of
     requiring the programmer to precompute it into a bare magic number
     with an explanatory comment. TypeRefined's lo/hi are already plain
     OCaml ints computed at parse time (not stored as an expr AST node),
     so this is purely a grammar extension -- no type_inf.ml/llvm_gen.ml
     changes were needed. *)
  Alcotest.test_case
    "refined type bounds accept simple constant arithmetic (+/-/*//,\
     parens, sizeof), mirroring array_size's existing grammar" `Quick
    (expect_codegen_ok
       "const RTB_PAGE_SIZE: usize = 4096;
        const RTB_COUNT: usize = 512;
        fn rtb_use() -> usize {
            let offset: {0..<(RTB_COUNT - 1) * RTB_PAGE_SIZE + 1 as usize} = 5;
            return offset;
        }");

  (* GitHub issue #185: two --forbid-trap proof mechanisms recognized a
     bare integer literal but not a const reference, even though the
     const's value is exactly as statically known. Root cause traced to
     intlit_opt (type_inf.ml's central range-propagation helper, mirrored
     in llvm_gen.ml) only matching IntLit, not a Var naming a registered
     const; same_base_len (the subslice same-base rule) and
     Ast.slice_len_mins (slice-length if-narrowing) had their own,
     narrower copies of the same gap. All three now resolve a const
     reference via Const_env, exactly like a literal. *)
  Alcotest.test_case
    "issue #185: the same-base subslice rule proves a const-sized \
     subslice (`pool[offset..<offset + PAGE_SIZE]`), not just a literal \
     one -- exercises intlit_opt's Add range propagation feeding the \
     same-base rule's own const check" `Quick
    (expect_codegen_ok
       "const I185_PAGE_SIZE: usize = 4096;
        const I185_COUNT: usize = 512;
        fn i185_subslice(
                offset: {0..<(I185_COUNT - 1) * I185_PAGE_SIZE + 1 as usize},
                pool: [u8; I185_PAGE_SIZE * I185_COUNT..]) -> []u8 {
            return pool[offset..<offset + I185_PAGE_SIZE];
        }");

  Alcotest.test_case
    "issue #185: slice-length narrowing (`if (s.len >= K)`) accepts a \
     const K, not just a literal one" `Quick
    (expect_codegen_ok
       "const I185N_PAGE_SIZE: usize = 4096;
        must_use variant I185NResult { TooShort; Ok([u8; I185N_PAGE_SIZE..]); }
        fn i185n_narrow(bytes: []u8) -> I185NResult {
            if (bytes.len >= I185N_PAGE_SIZE) {
                return I185NResult::Ok(bytes);
            }
            return I185NResult::TooShort;
        }");

  (* GitHub issue #184: unifying assignment into `expr` (a single general
     `Assign(lhs, rhs)`, dispatched by lhs shape, replacing 4 separate
     dedicated `stmt`-only constructors) is what let match/let-match arm
     bodies gain a bare-tail-expr sugar (`Pattern => { e }`, no trailing
     `;`, desugars to `Yield e`) without hitting the Menhir conflicts an
     earlier, narrower attempt did -- see the extensive comments in
     lib/ast.ml/lib/parser.mly/lib/type_inf.ml/lib/llvm_gen.ml for the
     full design. These tests cover the genuinely new surface: a plain
     `match` (not let-match) using the same sugar, ordinary statements
     (including field/index assignment) mixed with a Yield tail in one
     arm, assignment rejected as a general sub-expression in a
     nonsensical position, and assigning to a non-lvalue. *)
  Alcotest.test_case
    "issue #184: a plain `match` statement's arm can also use the \
     bare-tail Yield sugar -- the value is simply evaluated and \
     discarded (same as an ordinary `Expr` statement), no LetMatch \
     capture involved" `Quick
    (expect_codegen_ok
       "must_use variant I184MatchResult { A; B(usize); }
        fn i184_plain_match(r: I184MatchResult) -> usize {
            match r {
                I184MatchResult::A => { return 0; }
                I184MatchResult::B(n) => { n }
            }
            return 1;
        }");

  Alcotest.test_case
    "issue #184: an arm mixes ordinary statements -- including field and \
     index assignment, both of which used to be separate dedicated `stmt` \
     productions before this issue folded them into `expr` -- with a \
     bare-tail Yield, the exact shape this feature exists to unblock \
     (e.g. `page_free(text); page_free(data); return ...;` alongside a \
     value-producing arm elsewhere in the same match)" `Quick
    (expect_codegen_ok
       "struct I184Counter { n: usize; }
        must_use variant I184MixedResult { Cleanup; Value(usize); }
        fn i184_mixed_arm(r: I184MixedResult, c: *I184Counter,
                          arr: [usize; 4], i: {0..<4 as usize}) -> usize {
            let mut text: usize = match r {
                I184MixedResult::Cleanup => {
                    c.n = 0;
                    arr[i] = 0;
                    return 0;
                }
                I184MixedResult::Value(v) => {
                    c.n = v;
                    arr[i] = v;
                    v
                }
            };
            return text;
        }");

  Alcotest.test_case
    "issue #184: assignment is syntactically valid as a general \
     sub-expression but rejected by ordinary type-checking in a \
     nonsensical position -- Assign's TVoid result cannot unify against \
     the bool an `if` condition requires, confirming no special-casing \
     was needed to reject this beyond ordinary unification" `Quick
    (expect_type_error "cannot unify"
       "fn i184_assign_in_condition() -> usize {
            let mut x: usize = 0;
            if (x = 5) { return 1; }
            return 0;
        }");

  Alcotest.test_case
    "issue #184: assigning to a non-lvalue expression is a clear type \
     error, not a parser crash -- the grammar accepts any expr as \
     Assign's LHS (matching Rust's own `f() = x` parses-then-rejects \
     split), so this is caught by infer_expr's LHS-shape dispatch" `Quick
    (expect_type_error "not an assignable expression"
       "fn i184_helper() -> usize { return 1; }
        fn i184_assign_non_lvalue() -> usize {
            i184_helper() = 5;
            return 0;
        }");

  Alcotest.test_case
    "global let initializer: referencing a `let mut` global is rejected -- \
     a mutable global's value can change at runtime, so it is never a \
     compile-time constant" `Quick
    (expect_codegen_error "not a compile-time constant"
       "let mut GLOBALCONST_MUT_A: i32 = 1;
        let GLOBALCONST_MUT_B: i32 = GLOBALCONST_MUT_A;
        fn codegen_globalconst_mut_ref_use() -> i32 { return GLOBALCONST_MUT_B; }");

  Alcotest.test_case
    "global let initializer: referencing a global declared LATER in the \
     source is rejected (no forward references, same convention as \
     Const_env's array-size constants)" `Quick
    (expect_codegen_error "not a compile-time constant"
       "let GLOBALCONST_FWD_B: i32 = GLOBALCONST_FWD_A;
        let GLOBALCONST_FWD_A: i32 = 1;
        fn codegen_globalconst_fwd_ref_use() -> i32 { return GLOBALCONST_FWD_B; }");

  (* 64-bit integer literals (CLAUDE.md's "64-bit Integer Literals" section):
     IntLit's payload widened from OCaml's native (63-bit) int to Int64.t,
     touching the lexer, parser, ast, type_inf, and llvm_gen. These are
     regression tests for the representation itself; runtime VALUE
     correctness for a local variable and a bare function argument (the
     two forms that go through gen_expr's IntLit case, not eval_const) is
     additionally verified end-to-end under QEMU by examples/int64. *)
  Alcotest.test_case
    "global u64 initializer with a full 64-bit hex literal embeds the \
     exact bit pattern -- regression for the pre-Int64-IntLit bug where \
     eval_const's `const_int (ltype_of_ast ft) i` truncated any literal \
     outside OCaml's native int to i32 before ever reaching u64" `Quick
    (fun () ->
       let src =
         "let GLOBALCONST_U64_FULL: u64 = 0xFFFFFFFFFFFFFFFF;
          fn codegen_globalconst_u64_full_use() -> u64 { return GLOBALCONST_U64_FULL; }"
       in
       match gen_codegen src with
       | _ ->
           (match Hashtbl.find_opt Llvm_gen.global_vars "GLOBALCONST_U64_FULL" with
            | Some (_, gv) ->
                (match Llvm.global_initializer gv with
                 | Some init ->
                     (match Llvm.int64_of_const init with
                      | Some v -> Alcotest.(check bool) "bit pattern is all-ones" true (v = -1L)
                      | None -> Alcotest.fail "expected an integer constant")
                 | None -> Alcotest.fail "expected an initializer")
            | None -> Alcotest.fail "GLOBALCONST_U64_FULL not found in global_vars")
       | exception Llvm_gen.Error msg -> Alcotest.failf "unexpected codegen Error: %s" msg);

  Alcotest.test_case
    "local u64 variable initialized with a value beyond i32's range \
     compiles cleanly (gen_expr's IntLit case must route this through the \
     i64-native path, not silently truncate to i32 first)" `Quick
    (expect_codegen_ok
       "fn codegen_intlit_local_u64() -> u64 {
          let x: u64 = 5000000000;
          return x;
        }");

  Alcotest.test_case
    "a bare wide hex literal passed directly as a u64 function argument \
     compiles cleanly (the specific case that needs the non-negative-only \
     i32 fast path, not the full signed i32 range: 0xFFFFFFFFFFFFFFFF's \
     Int64 value is -1, which fits the signed i32 range but must NOT take \
     the i32-then-widen shortcut, since zero- vs sign-extending -1 gives \
     different 64-bit results)" `Quick
    (expect_codegen_ok
       "fn codegen_intlit_wide_arg_callee(v: u64) -> u64 { return v; }
        fn codegen_intlit_wide_arg_caller() -> u64 {
          return codegen_intlit_wide_arg_callee(0xFFFFFFFFFFFFFFFF);
        }");

  Alcotest.test_case
    "array size formula overflowing native int is a compile error, not a \
     silent wraparound (narrow_int64 in parser.mly). Uses 0x8000000000000000
     (Int64.min_int) specifically: it is the cleanest value guaranteed not
     to round-trip through OCaml's 63-bit native int, unlike an arbitrary
     huge decimal string, whose 64-bit wraparound could coincidentally land
     back inside the 63-bit range" `Quick (fun () ->
    match parse "let ring: [u8; 0x8000000000000000];" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions array size" true
          (let n = String.length "array size" and m = String.length msg in
           let rec scan i = i + n <= m && (String.sub msg i n = "array size" || scan (i + 1)) in
           scan 0));

  Alcotest.test_case
    "align(N) overflowing native int is a compile error, not a silent \
     wraparound (narrow_int64 in parser.mly; same 0x8000000000000000 \
     choice as the array-size test above)" `Quick (fun () ->
    match parse "let mut buf: [u8; 4] align(0x8000000000000000);" with
    | _ -> Alcotest.fail "expected an error, but parsing succeeded"
    | exception Types.TypeError (_, msg) ->
        Alcotest.(check bool) "mentions alignment" true
          (let n = String.length "alignment" and m = String.length msg in
           let rec scan i = i + n <= m && (String.sub msg i n = "alignment" || scan (i + 1)) in
           scan 0));

  Alcotest.test_case
    "a local u64 variable initialized with a full 64-bit literal embeds it \
     as a direct i64 constant (Let's resolved type threaded into gen_expr \
     via ?expected_ty)" `Quick
    (assert_direct_i64_literal "codegen_intlit_direct_local"
       "fn codegen_intlit_direct_local() -> u64 {
          let w: u64 = 0xFFFFFFFFFFFFFFFF;
          return w;
        }");

  Alcotest.test_case
    "a bare full 64-bit literal in a return statement embeds directly, \
     hinted by the function's own return type" `Quick
    (assert_direct_i64_literal "codegen_intlit_direct_return"
       "fn codegen_intlit_direct_return() -> u64 {
          return 0xFFFFFFFFFFFFFFFF;
        }");

  Alcotest.test_case
    "a bare full 64-bit literal passed as a function call argument embeds \
     directly, hinted by the callee's declared parameter type" `Quick
    (assert_direct_i64_literal "codegen_intlit_direct_caller"
       "fn codegen_intlit_direct_callee(x: u64) -> u64 { return x; }
        fn codegen_intlit_direct_caller() -> u64 {
          return codegen_intlit_direct_callee(0xFFFFFFFFFFFFFFFF);
        }");

  Alcotest.test_case
    "assigning a full 64-bit literal to an already-declared u64 variable \
     embeds directly, hinted by the variable's stored type" `Quick
    (assert_direct_i64_literal "codegen_intlit_direct_assign"
       "fn codegen_intlit_direct_assign() -> u64 {
          let mut w: u64 = 0;
          w = 0xFFFFFFFFFFFFFFFF;
          return w;
        }");

  Alcotest.test_case
    "Refinement Numerical Type: min/max on two UNCONSTRAINED u64 arguments \
     type-checks and codegens (regression -- min/max's \"unknown\" sentinel \
     range used a hardcoded negative lower bound, which is illegal for an \
     unsigned destination type once min/max started unifying its arguments \
     against each other instead of always TI32; this used to raise \
     'cannot unify {-1000000000..<1000000000} with u64')" `Quick
    (expect_codegen_ok
       "fn refnum_min_u64(a: u64, b: u64) -> u64 {
          return min(a, b);
        }
        fn refnum_max_u64(a: u64, b: u64) -> u64 {
          return max(a, b);
        }");

  Alcotest.test_case
    "Refinement Numerical Type: min(u64_val, LITERAL) still proves an array \
     index against a smaller buffer than u64's own range would otherwise \
     allow, i.e. the base-type generalization didn't regress min/max's \
     clamping proof itself, just widened which base types it accepts" `Quick
    (expect_trap_sites 0
       "let mut refnum_buf_u64: [u8; 20];
        fn refnum_min_clamp_u64(raw: u64) -> u8 {
          let capped: u64 = min(raw, 19);
          return refnum_buf_u64[capped as {0..<20 as usize}];
        }");

  Alcotest.test_case
    "Refinement Numerical Type: an if-narrowed u64 variable proves an array \
     index with zero trap sites (regression for is_unsigned/canon_ty/\
     narrowing all correctly recursing into a refined type's own base \
     instead of assuming i32)" `Quick
    (expect_trap_sites 0
       "let mut refnum_buf_u64b: [u8; 100];
        fn refnum_narrow_u64(n: u64) -> u8 {
          if (n >= 0 && n <= 50) {
            return refnum_buf_u64b[n as {0..<51 as usize}];
          }
          return 0;
        }");

  Alcotest.test_case
    "Refinement Numerical Type: min/max's unknown-bound sentinel is clamped \
     to each base's own representable range (min_max_sentinel), not one \
     fixed +-1 billion constant everywhere -- u32/u64/usize/i32/i64 are wide \
     enough to absorb +-1 billion so those were never affected, but u8 \
     (hi <= 256), u16 (hi <= 65536), i8 (+-128), and i16 (+-32768) are not: \
     a fully-unconstrained min/max call on two such values used to fail to \
     unify against the result's own narrow destination type, even though \
     every individual clamp involved is trivially sound" `Quick
    (expect_codegen_ok
       "fn refnum_min_u8_unconstrained(a: u8, b: u8) -> u8 {
          return min(a, b);
        }
        fn refnum_max_u16_unconstrained(a: u16, b: u16) -> u16 {
          return max(a, b);
        }
        fn refnum_min_i8_unconstrained(a: i8, b: i8) -> i8 {
          return min(a, b);
        }
        fn refnum_max_i16_unconstrained(a: i16, b: i16) -> i16 {
          return max(a, b);
        }");

  Alcotest.test_case
    "Refinement Numerical Type: widen_load recurses into TypeRefined's own \
     base before widening (regression -- an Imm (immutable let) binding \
     holding a narrow-based refined value, e.g. `let x: u8 = a & mask;`, \
     used again in later arithmetic, e.g. `x * 4`, used to emit `mul i8 \
     %x, i32 4` (an LLVM verifier failure caught by gen_func's own \
     Llvm_analysis.verify_function): widen_load's fallthrough case was \
     never updated to unwrap TypeRefined when TRefinedInt/TypeRefined was \
     generalized to carry a non-i32 base -- before that generalization \
     every TypeRefined value WAS i32-shaped in memory, so the same \
     fallthrough happened to be a harmless no-op. First found via the new \
     explicit-base {lo..<hi as base} surface syntax, the first construct \
     to exercise an Imm binding holding a genuinely narrow-based refined \
     value used again in later arithmetic -- but the underlying bug is in \
     widen_load itself, reachable for any u8/u16/i8/i16-based refined Imm \
     binding regardless of how its base became narrow" `Quick
    (expect_codegen_ok
       "fn refnum_widen_mul(raw: u8) -> u8 {
          let masked: u8 = raw & 0x0f;
          let quadrupled: u8 = masked * 4;
          return quadrupled;
        }
        fn refnum_widen_add(raw: u16) -> u16 {
          let masked: u16 = raw & 0x00ff;
          let plus_one: u16 = masked + 1;
          return plus_one;
        }
        fn refnum_widen_into_param(x: {20..<21 as u8}) -> u8 {
          return x;
        }
        fn refnum_widen_call_site(raw: u8) -> u8 {
          let ihl: u8 = (raw & 0x0f) * 4;
          if (ihl == 20) {
            return refnum_widen_into_param(ihl);
          }
          return 0;
        }");

  Alcotest.test_case
    "Refinement Numerical Type: a u8-based refined slice bound (the \
     ip_parse.tkb `pkt[0..<ihl]` idiom, ihl: u8 = min(...)) proves the \
     subslice with zero trap sites (regression -- SliceOf's bound check \
     used to `canon_ty` the bound's type before unifying against TI32, \
     which widens a refined bound to its BARE base first (e.g. plain u8) \
     -- a bare u8 has no unification rule against i32 at all, so this \
     raised 'cannot unify u8 with i32' the first time a non-i32-based \
     slice bound was tried. Index's parallel check (`unify_at idx.loc it \
     TI32`) never had this bug because it unifies the RAW refined type \
     directly, relying on TRefinedInt's existing base-agnostic subtyping \
     into TI32 -- SliceOf's canon_ty call was pure surplus that only \
     happened to be harmless while every refined bound was i32-based \
     anyway" `Quick
    (expect_trap_sites 0
       "fn refnum_slice_bound_u8(pkt: [u8; 20..]) -> []u8 {
          let ihl: u8 = min((pkt[0] & 0x0f) * 4, 20);
          return pkt[0..<ihl as {0..<21 as usize}];
        }");

  Alcotest.test_case
    "Refinement Numerical Type: for-loop counter follows the bounds' own \
     base type instead of a hardcoded i32 (regression -- generalizing \
     type_inf.ml's For case to unify lo/hi against each other, instead of \
     forcing both into TI32, surfaced a SEPARATE codegen bug: looking up \
     the counter's resolved type via `res name None` (the user's bare \
     loop-variable name, e.g. \"i\") instead of the mangled \
     \"__for_<name>\" key type_inf.ml actually stores it under -- the \
     lookup silently fell back to i32 regardless of the real base, so a \
     usize-based loop counter's alloca (correctly i64-wide, since
     collect_lets's OWN alloca-type resolution used the right key) was \
     STORED INTO with an i32-shaped 0, an LLVM verifier failure caught by \
     gen_func's own Llvm_analysis.verify_function. This test exercises \
     u8 (narrow, needs widen-for-compare/narrow-for-store at every \
     boundary) and usize (wide, needs unsigned `icmp ult` not signed \
     `icmp slt`) loop bounds together with a `for i in 0..<s.len` slice \
     bound (previously a type error, now also a codegen regression \
     surface)" `Quick
    (expect_codegen_ok
       "fn refnum_for_u8(n: u8) -> i32 {
          let mut total: i32 = 0;
          for i in 0..<n { total = total + 1; }
          return total;
        }
        fn refnum_for_usize(s: []u8) -> i32 {
          let mut total: i32 = 0;
          for i in 0..<s.len { total = total + (s[i] as i32); }
          return total;
        }");

  (* -- Deferred, usage-driven for-loop counter typing (follow-up to the
     above): the counter's type defaults to i32 only AFTER the whole body
     has had a chance to pin it via ordinary usage, not eagerly the
     moment the bounds are seen -- mirrors check_undetermined_lets's
     "let later constraints run first" reasoning exactly. require_integer
     no longer defaults an unresolved TVar itself (only validates an
     ALREADY-concrete type); Index/AssignIndex/SliceOf calling it no
     longer forces the counter's shared type variable to i32 the moment
     the body indexes anything with it. *)

  Alcotest.test_case
    "for-loop counter over a NON-const-recognized compound bound \
     (`0 + 4`, which Const_env.bound_value does not recognize as a \
     literal the way a bare `4` is) is pinned by the body's OWN usage \
     (passing it to a u8-typed function parameter), not defaulted to i32 \
     -- this is the case where deferred inference actually changes the \
     outcome" `Quick
    (fun () ->
      let pt = infer
        "fn foo(x: u8) {}
         fn f() { for i in 0..<(0 + 4) { foo(i); } }" in
      let fi = Types.StringMap.find "f" pt.Types.functions in
      Alcotest.check type_t "i inferred as u8, pinned by foo(x: u8)" Ast.TypeU8
        (Types.StringMap.find "__for_i" fi.Types.local_types));

  Alcotest.test_case
    "explicitly typed for-loop folds a const product into its counter proof" `Quick
    (expect_trap_sites 0
      "const ROWS: usize = 4;
       const COLS: usize = 8;
       let mut data: [u8; ROWS * COLS];
       fn f() { for i: usize in 0..<ROWS * COLS { data[i] = 0; } }");

  Alcotest.test_case
    "for-loop counter over ORDINARY literal bounds (`0..<4`, which
     Const_env.bound_value DOES recognize) is now a COMPILE ERROR when the
     body's only usage can't pin a concrete type -- deferred, usage-driven
     inference does not help THIS common shape, because a bare-literal
     -bounded counter is wrapped in TRefinedInt(0, 4, base), and
     TRefinedInt's subtyping into a concrete destination type (`TRefinedInt
     _, TU8 when lo>=0 && hi<=256 -> ()` in types.ml) deliberately ignores
     the refined value's OWN base field entirely -- passing it to foo(x:
     u8) proves the BOUNDS fit u8, but never touches/pins `base` itself
     (confirmed empirically, not just argued, via a scratch IR dump before
     this section existed). This USED to silently default to i32; now
     that `for i: T in ...` exists as an explicit escape hatch, requiring
     it instead (same reasoning as let/let mut's own hard error) closes
     the gap for this exact case -- the fix is an explicit annotation
     (`for i: u8 in 0..<4 { foo(i); }`), not smarter inference" `Quick
    (expect_type_error
       "cannot determine a concrete type for for-loop counter 'i'"
       "fn foo(x: u8) {}
        fn f() { for i in 0..<4 { foo(i); } }");

  (* GitHub issue #312: `for i in 0..<limit` where `limit` is a RUNTIME
     parameter with its OWN already-proven TRefinedInt (not a
     Const_env-recognized syntactic constant) previously gave the counter
     the unrefined base type only -- this is the unified_fd_clone_rollback
     -shaped gap found migrating kernel/kernel/fd_table.tkb (2026-08-15):
     `for undo: usize in 0..<limit { ... }` needed `!{unsafe}` plus a
     per-index unsafe wrap before this fix, purely because limit's own
     proof (limit: {0..<PROCESS_FD_MAX as usize}) was never reused. *)
  Alcotest.test_case
    "for-loop counter over 0..<limit, where limit has its own already- \
     proven TRefinedInt upper bound (not a Const_env constant), inherits \
     that bound (issue #312)" `Quick
    (fun () ->
      let pt = infer
        "fn f312(limit: {0..<8 as usize}) {
           for undo: usize in 0..<limit { }
         }" in
      let fi = Types.StringMap.find "f312" pt.Types.functions in
      Alcotest.check type_t "undo inherits {0..<8}"
        (Ast.TypeRefined (0, 8, Ast.TypeUsize))
        (Types.StringMap.find "__for_undo" fi.Types.local_types));

  Alcotest.test_case
    "for i: u8 in 0..<4 gives the counter EXACTLY TRefinedInt(0, 4, u8) --
     the explicit-annotation escape hatch for the case above, and the
     syntax's most basic use" `Quick
    (fun () ->
      let pt = infer
        "fn foo(x: u8) {}
         fn f() { for i: u8 in 0..<4 { foo(i); } }" in
      let fi = Types.StringMap.find "f" pt.Types.functions in
      Alcotest.check type_t
        "i is {0..<4 as u8}"
        (Ast.TypeRefined (0, 4, Ast.TypeU8))
        (Types.StringMap.find "__for_i" fi.Types.local_types));

  Alcotest.test_case
    "for i: u8 in 0..<300 is a compile error (300 doesn't fit u8) -- a
     bare-literal for-loop bound has no inherent width of its own, so
     without this check the annotation would silently let a too-wide
     bound wrap around at codegen time (`const_int i8_type 300`), exactly
     the soundness hole the {lo..<hi as base} surface syntax's own bound
     check exists to prevent" `Quick
    (expect_type_error
       "for-loop bound {0..<300} does not fit the annotated type"
       "fn f() { for i: u8 in 0..<300 {} }");

  Alcotest.test_case
    "for i: u8 in 0..<n (n: u16) is an ordinary 'cannot unify' error --
     a conflicting bound and annotation are caught the same way any other
     concrete type mismatch is" `Quick
    (expect_type_error "cannot unify"
       "fn f(n: u16) { for i: u8 in 0..<n {} }");

  Alcotest.test_case
    "for i: u8 in 0..<4 codegens a genuinely i8-wide counter and proves
     the array access with zero trap sites -- annotate once for the
     register width, then bridge to usize with an explicit `as {lo..<hi as
     usize}` cast at the index site (array/slice indexing is usize-only
     now, see require_usize_index): a FREE coercion since the bounds
     already match exactly, unlike the `for i in 0..<(4 as u8)` cast-based
     workaround, which gets the width but loses the elision entirely since
     a cast to a non-refined-syntax target always discards the source's
     proven range" `Quick
    (expect_trap_sites 0
       "let mut refnum_for_buf: [u8; 4];
        fn refnum_for_annotated() {
          for i: u8 in 0..<4 {
            refnum_for_buf[i as {0..<4 as usize}] = ('A' + i) as u8;
          }
        }");

  Alcotest.test_case
    "for i: usize in 0..<s.len parses and codegens: the annotation syntax
     accepts all 10 primitive integer bases (int_base_type_expr), same as
     {lo..<hi as base}" `Quick
    (expect_codegen_ok
       "fn refnum_for_usize_ann(s: []u8) -> i32 {
          let mut total: i32 = 0;
          for i: usize in 0..<s.len {
            total = total + (s[i] as i32);
          }
          return total;
        }");

  Alcotest.test_case
    "DMA/device barriers lower to MFENCE on AMD64" `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"x86_64-none-elf" ()
       in
       let _ = gen_codegen
         "fn codegen_barriers_x86() {
            dma_publish(); dma_consume(); device_fence();
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_barriers_x86" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_barriers_x86 was not emitted"
       in
       Alcotest.(check int) "three mfence calls" 3
         (count_substring (Llvm.string_of_llvalue fn) "llvm.x86.sse2.mfence"));

  Alcotest.test_case "opaque handle pointers codegen without a concrete layout" `Quick
    (expect_codegen_ok
       "opaque struct DmaOwned;
        opaque struct CpuOwned;
        let mut token_byte: u8;
        fn initial() -> *DmaOwned { return &token_byte as *DmaOwned; }
        fn acquire(t: *DmaOwned) -> *CpuOwned { return t as *CpuOwned; }");

  Alcotest.test_case
    "DMA/device barriers preserve RISC-V memory/I/O fence directions" `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"riscv64-none-elf" ()
       in
       let _ = gen_codegen
         "fn codegen_barriers_riscv() {
            dma_publish(); dma_consume(); device_fence();
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_barriers_riscv" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_barriers_riscv was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "publish fence w,o" true (contains_substring ir "fence w, o");
       Alcotest.(check bool) "consume fence i,r" true (contains_substring ir "fence i, r");
       Alcotest.(check bool) "full fence iorw" true
         (contains_substring ir "fence iorw, iorw");
       expect_codegen_error "interrupt event wait/notify is not implemented"
         "fn riscv_event_wait_is_rejected() { interrupt_wait(); }" ());

  Alcotest.test_case
    "DMA cache builtins lower to real dc cvac/dc ivac range loops on \
     AArch64 (issue #146: previously only a bare dsb was emitted here, \
     silently reproducing the same stale-cache-line gap that bit \
     Raspberry Pi 3B's mailbox and USB DMA once its D-cache was genuinely \
     enabled)" `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"aarch64-none-elf" ()
       in
       let _ = gen_codegen
         "fn codegen_dma_cache_aarch64(p: *align(64) u8, n: usize) {
            dma_prepare_tx(p, n);
            dma_prepare_rx(p, n);
            dma_finish_rx(p, n);
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_dma_cache_aarch64" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_dma_cache_aarch64 was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check int) "one clean (dma_prepare_tx)" 1
         (count_substring ir "dc cvac, x13");
       Alcotest.(check int) "two invalidates (dma_prepare_rx + dma_finish_rx)" 2
         (count_substring ir "dc ivac, x13");
       Alcotest.(check int) "line size read from CTR_EL0 each call" 3
         (count_substring ir "mrs x9, ctr_el0");
       Alcotest.(check int) "surrounding barriers" 4
         (count_substring ir "llvm.aarch64.dsb"));

  Alcotest.test_case
    "DMA cache builtins are a verified no-op fence on x86-64, not a gap \
     (issue #146: PC-class DMA is chipset/IOMMU-coherent by hardware, \
     unlike the AArch64 case above)" `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"x86_64-none-elf" ()
       in
       let _ = gen_codegen
         "fn codegen_dma_cache_x86(p: *align(32) u8, n: usize) {
            dma_prepare_tx(p, n);
            dma_prepare_rx(p, n);
            dma_finish_rx(p, n);
          }"
       in
       let fn = match Hashtbl.find_opt Llvm_gen.functions "codegen_dma_cache_x86" with
         | Some (_, fn) -> fn
         | None -> Alcotest.fail "codegen_dma_cache_x86 was not emitted"
       in
       let ir = Llvm.string_of_llvalue fn in
       Alcotest.(check bool) "no dc cvac" false (contains_substring ir "dc cvac");
       Alcotest.(check bool) "no dc ivac" false (contains_substring ir "dc ivac");
       Alcotest.(check int) "three mfence calls" 3
         (count_substring ir "llvm.x86.sse2.mfence"));

  Alcotest.test_case
    "DMA cache builtins reject RISC-V rather than silently falling back to \
     a bare fence (issue #146: no Zicbom cbo.clean/cbo.flush/cbo.inval \
     lowering exists yet, and no RISC-V target exists anywhere in this \
     project to verify one against, so a silent barrier-only fallback \
     would reproduce the same stale-cache-line hazard found on AArch64)"
    `Quick
    (fun () ->
       let (_ : Llvm_target.TargetMachine.t) =
         Llvm_gen.setup_target ~triple:"riscv64-none-elf" ()
       in
       expect_type_error
         "no DMA cache-maintenance contract"
         "fn f(p: *align(32) u8, n: usize) { dma_prepare_tx(p, n); }" ());

  Alcotest.test_case
    "GitHub issue #79: a refined `io` global (the common_stm32/uart.tkb \
     ring-buffer idiom, `let mut head: io {0..<128 as usize};`) keeps its \
     proven range across a read into a local, so `buf[head]` proves clean \
     with zero trap sites -- regression for the real bug found while \
     applying --forbid-trap to every example: an UNREFINED `io usize` \
     global has every WRITE site going through `% 128` (so the value is \
     always in range at runtime) but loses that invariant at every READ \
     site, since a bare usize global carries no memory of the range its \
     writers respect. Fixed in the application code by refining the \
     global's own declared type, not by changing the compiler -- this \
     test exists so the underlying mechanism (a refined io global's read \
     upgrading a local let's range, the same rule issue #77's Pass 2 fix \
     relies on for plain globals) has its own regression coverage, \
     independent of any example rebuild finding it by accident" `Quick
    (expect_trap_sites 0
       "let mut ring_head: io {0..<128 as usize};
        fn refnum79_ring_read() -> u8 {
          let mut buf: [u8; 128];
          let head: usize = ring_head;
          return buf[head];
        }");

  (* GitHub issue #72: a BARE cast (`x as usize`, not the explicit
     `x as {lo..<hi as usize}` form) now infers the tightest refined type
     on its own whenever the source's range is already known and fits the
     target base -- see type_inf.ml's Cast case (issue #72 comment) and
     llvm_gen.ml's matching target_ty rewrite just before its own Cast
     dispatch. These lock in the examples/ rewrite done alongside this
     feature (icmp_echo.tkb/tcp_echo.tkb/http_server.tkb/tcp_parse.tkb/
     ip_parse.tkb/narrow.tkb/refined.tkb/eth.tkb/virtio_mmio.tkb all
     dropped their explicit ranges in favor of this inference). *)
  Alcotest.test_case
    "issue #72: a bare cast from an exact-match refined PARAMETER (the \
     `ihl: {20..<21 as u16}` idiom) infers {20..<21 as usize} on its own, \
     proving a subslice with zero trap sites -- same as if `ihl as \
     {20..<21 as usize}` had been spelled out by hand" `Quick
    (expect_trap_sites 0
       "fn refnum72_param_bridge(ip: [u8; 20..], ihl: {20..<21 as u16}) -> []u8 {
          return ip[0..<ihl as usize];
        }");

  Alcotest.test_case
    "issue #72: a bare cast from an if-narrowed i32 (the narrow.tkb/\
     refined.tkb idiom) infers {0..<8 as usize} on its own, proving an \
     array index with zero trap sites -- same as if `v as {0..<8 as \
     usize}` had been spelled out by hand" `Quick
    (expect_trap_sites 0
       "fn refnum72_narrow_bridge(v: i32, c: u8) {
          let mut buf: [u8; 8];
          if (v >= 0 && v < 8) {
            buf[v as usize] = c;
          }
        }");

  Alcotest.test_case
    "issue #72: a bare cast from a Mul-derived, narrower-than-native-Mul-\
     bound refined value (the tcp_echo.tkb/http_server.tkb `(doff * 4) as \
     u16` idiom, doff: {5..<16 as u8} so doff*4 already proves {20..<61 \
     as u8}, tighter than doff's own native u8 range) carries that exact \
     range across the width change with zero trap sites" `Quick
    (expect_trap_sites 0
       "fn refnum72_mul_bridge(doff: u8) -> u16 {
          if (doff >= 5 && doff <= 15) {
            let tcp_hdr_len: u16 = (doff * 4) as u16;
            return tcp_hdr_len;
          }
          return 0;
        }");

  Alcotest.test_case
    "issue #72 negative control: a bare cast whose source range does NOT \
     fit the target base (here {0..<1481} into u8) is left exactly as \
     before this feature -- a plain unrefined target, no false claim of \
     safety, no runtime check added or removed by this feature either \
     way" `Quick
    (expect_codegen_ok
       "fn refnum72_no_fit(v: i32) -> u8 {
          if (v >= 0 && v < 1481) {
            return v as u8;
          }
          return 0;
        }");

  Alcotest.test_case
    "issue #72 negative control: a bare cast from an UNPROVEN i32 (no \
     if-narrowing in scope) still requires the same runtime bounds check \
     it always did -- this feature only widens what an ALREADY-proven \
     cast can skip restating, it never invents a proof from nothing" `Quick
    (expect_trap_sites 1
       "fn refnum72_unproven(v: i32) -> u8 {
          let mut buf: [u8; 8];
          buf[v as usize] = 1;
          return buf[0];
        }");

  (* GitHub issue #100 follow-up: an out-of-range integer literal used to
     unify SILENTLY against a refined target -- IntLit's own inferred type
     is a polymorphic, unbound type variable (see type_inf.ml's `IntLit _
     -> fresh ()`), which unify() lets bind structurally to ANY target,
     including TRefinedInt, with no check on the literal's actual VALUE.
     A genuinely out-of-range literal therefore "proved" a range it did
     not satisfy, and --forbid-trap then elided a real bounds check
     downstream -- a true soundness hole (found while investigating issue
     #100, "Refinement type on struct field": struct field reads/writes
     already worked correctly, but this literal-value gap affected EVERY
     refined-type target, not just struct fields). Fixed by
     check_literal_fits_refined, called alongside unify_at at every site
     where a literal-or-Const_env-constant expression flows into an
     already-declared target type. One test per call site below. *)
  Alcotest.test_case
    "issue #100: an out-of-range literal `let` initializer against a \
     refined target is now a compile error, not a silently-accepted false \
     proof" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_let() {
          let v: {0..<8 as usize} = 20;
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal `Assign` (not just the \
     initializer) to an already-refined mutable local is now a compile \
     error" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_assign() {
          let mut v: {0..<8 as usize} = 3;
          v = 20;
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal function-call argument against a \
     refined parameter is now a compile error" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_callee(i: {0..<8 as usize}) {}
        fn refnum100_call() {
          refnum100_callee(20);
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal `return` value against a refined \
     return type is now a compile error" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_ret() -> {0..<8 as usize} {
          return 20;
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal array-element assignment against \
     a refined element type is now a compile error" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_arr() {
          let mut arr: [{0..<8 as usize}; 4];
          arr[0] = 20;
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal write through a pointer to a \
     refined type is now a compile error" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_deref(p: *{0..<8 as usize}) {
          *p = 20;
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal cast to an EXPLICIT refined \
     target (`x as {lo..<hi as base}`, a 9th call site found only after \
     the first 8 were already fixed and reported) is now a compile \
     error too" `Quick
    (expect_type_error "does not fit the refined type"
       "fn refnum100_cast() -> usize {
          return 20 as {0..<8 as usize};
        }");

  Alcotest.test_case
    "issue #100 positive control: an in-range literal cast to an explicit \
     refined target still compiles with zero trap sites" `Quick
    (expect_trap_sites 0
       "fn refnum100_cast_ok() -> usize {
          return 3 as {0..<8 as usize};
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal struct-field ASSIGNMENT (the \
     motivating case -- a refined struct field, e.g. `struct Foo { idx: \
     {0..<8 as usize}; }`) is now a compile error" `Quick
    (expect_type_error "does not fit the refined type"
       "struct Refnum100Foo { idx: {0..<8 as usize}; }
        fn refnum100_field_assign() {
          let mut f: Refnum100Foo;
          f.idx = 20;
        }");

  Alcotest.test_case
    "issue #100: an out-of-range literal in a STRUCT LITERAL field is now \
     a compile error, including through check_expr's recursive handling \
     (not just the top-level scalar case)" `Quick
    (expect_type_error "does not fit the refined type"
       "struct Refnum100Foo { idx: {0..<8 as usize}; }
        fn refnum100_struct_lit() {
          let mut f: Refnum100Foo = {20};
        }");

  Alcotest.test_case
    "issue #100 positive control: an IN-RANGE literal struct field \
     (declare, assign, read as an array index, pass to a refined \
     parameter, read through a pointer) compiles with zero trap sites -- \
     this basic mechanism already worked before the literal-value fix; \
     this regression-covers it staying that way" `Quick
    (expect_trap_sites 0
       "struct Refnum100Foo { idx: {0..<8 as usize}; }
        let mut refnum100_buf: [u8; 8];
        fn refnum100_takes_refined(i: {0..<8 as usize}) -> u8 {
          return refnum100_buf[i];
        }
        fn refnum100_via_ptr(p: *Refnum100Foo) -> u8 {
          return refnum100_buf[p.idx];
        }
        fn refnum100_ok() -> u8 {
          let mut f: Refnum100Foo;
          f.idx = 3;
          refnum100_buf[f.idx] = 'A';
          let x: u8 = refnum100_takes_refined(f.idx);
          let y: u8 = refnum100_via_ptr(&f);
          return refnum100_buf[f.idx];
        }");

  Alcotest.test_case
    "issue #100 negative control: an UNPROVEN runtime (non-constant) \
     value assigned to a refined struct field is still rejected by the \
     PRE-EXISTING anti-subtyping guard -- check_literal_fits_refined only \
     ever adds a NEW rejection for compile-time-known values, it must not \
     weaken this existing, unrelated check" `Quick
    (expect_type_error "cannot pass unproven"
       "struct Refnum100Foo { idx: {0..<8 as usize}; }
        fn refnum100_unproven(f: *Refnum100Foo, n: usize) {
          f.idx = n;
        }");

  (* GitHub issue #207: two instantiations of the same generic struct with
     different type arguments must each get their own, independently
     registered, mangled-name LLVM struct type -- not share one
     definition, and not clobber each other in Llvm_gen.struct_lltypes. *)
  Alcotest.test_case
    "two instantiations of a generic struct register two distinct \
     mangled-name struct types (issue #207)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct Boxg207(T: type) {
            value: T;
          }
          fn boxg207_usize() -> usize {
            let mut a: Boxg207(usize);
            a.value = 1;
            return a.value;
          }
          fn boxg207_u8() -> u8 {
            let mut b: Boxg207(u8);
            b.value = 2 as u8;
            return b.value;
          }"
       in
       let find name = match Hashtbl.find_opt Llvm_gen.struct_lltypes name with
         | Some llty -> llty
         | None -> Alcotest.failf "%s not registered in struct_lltypes" name
       in
       let usize_ty = find "Boxg207$usize" in
       let u8_ty = find "Boxg207$u8" in
       Alcotest.(check int) "Boxg207$usize has 1 field"
         1 (Array.length (Llvm.struct_element_types usize_ty));
       Alcotest.(check int) "Boxg207$u8 has 1 field"
         1 (Array.length (Llvm.struct_element_types u8_ty));
       Alcotest.(check bool) "the two instantiations are genuinely distinct LLVM types"
         true (usize_ty <> u8_ty));

  Alcotest.test_case
    "a generic struct instantiated with the wrong number of type \
     arguments is rejected (issue #207)" `Quick
    (expect_type_error
       "expects 1 argument(s), got 2"
       "generic struct Boxg207wrong(T: type) { value: T; }
        fn boxg207wrong_use() {
          let mut b: Boxg207wrong(usize, u8);
        }");

  Alcotest.test_case
    "a generic struct instantiated with an unsupported type argument \
     (a slice) is rejected with a clear error, not a crash (issue #207)" `Quick
    (expect_type_error
       "is not supported yet"
       "generic struct Boxg207slice(T: type) { value: T; }
        fn boxg207slice_use() {
          let mut b: Boxg207slice([]u8);
        }");

  (* GitHub issue #207 build order step 5: generic function calls, resolved
     via the narrow inference rule (a bare Var/&Var argument whose type is
     already known locally). *)
  Alcotest.test_case
    "a generic function call with its type argument inferred from a local \
     variable's declared type compiles and registers the mangled \
     instantiation (issue #207)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct Boxg207fn(T: type) {
            value: T;
          }
          fn boxg207fn_get(T: type, b: *Boxg207fn(T)) -> T {
            return b.value;
          }
          fn boxg207fn_use() -> usize {
            let mut b: Boxg207fn(usize);
            b.value = 7;
            return boxg207fn_get(&b);
          }"
       in
       match Hashtbl.find_opt Llvm_gen.functions "boxg207fn_get$usize" with
       | Some _ -> ()
       | None -> Alcotest.fail "boxg207fn_get$usize was not generated");

  Alcotest.test_case
    "two instantiations of the same generic function, called with \
     different inferred types, coexist as distinct mangled functions \
     (issue #207)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct Boxg207fn2(T: type) {
            value: T;
          }
          fn boxg207fn2_get(T: type, b: *Boxg207fn2(T)) -> T {
            return b.value;
          }
          fn boxg207fn2_use_usize() -> usize {
            let mut b: Boxg207fn2(usize);
            b.value = 1;
            return boxg207fn2_get(&b);
          }
          fn boxg207fn2_use_u8() -> u8 {
            let mut c: Boxg207fn2(u8);
            c.value = 2 as u8;
            return boxg207fn2_get(&c);
          }"
       in
       let has name = Hashtbl.mem Llvm_gen.functions name in
       Alcotest.(check bool) "boxg207fn2_get$usize generated" true
         (has "boxg207fn2_get$usize");
       Alcotest.(check bool) "boxg207fn2_get$u8 generated" true
         (has "boxg207fn2_get$u8"));

  Alcotest.test_case
    "a generic function call whose two arguments would bind the same type \
     parameter to two DIFFERENT concrete types is rejected -- this is the \
     core soundness property the whole generics design hinges on \
     (issue #207)" `Quick
    (expect_type_error
       "conflicting inference for generic type parameter 'T'"
       "generic struct Pairg207(T: type) { a: T; }
        fn pairg207_combine(T: type, x: *Pairg207(T), y: *Pairg207(T)) -> T {
          return x.a;
        }
        fn pairg207_use() {
          let mut p1: Pairg207(usize);
          let mut p2: Pairg207(u8);
          pairg207_combine(&p1, &p2);
        }");

  (* -- Const generics follow-up to GitHub issue #207: `generic struct
     Name(T: type, N: usize)`, a plain integer VALUE parameter monomorphized
     exactly like a type parameter is. Motivated by
     linux_user/freelist_generic's capacity: a generic collection's own
     array-backed storage should not have to erase a caller's already-
     static array size into a runtime-length slice. -------------------- *)

  Alcotest.test_case
    "a generic struct with a value parameter (const generics) parses: \
     `T: type, N: usize`" `Quick
    (fun () ->
       let items = parse
         "generic struct FixedBufCgParse(T: type, N: usize) {
            data: [T; N];
          }"
       in
       match items with
       | [ Ast.GenericStructDef (name, params, _, _, _, _, _) ] ->
           Alcotest.(check string) "name" "FixedBufCgParse" name;
           (match params with
            | [ (tn, Ast.GPType); (nn, Ast.GPValue _) ] ->
                Alcotest.(check string) "T" "T" tn;
                Alcotest.(check string) "N" "N" nn
            | _ -> Alcotest.fail "unexpected param shape")
       | _ -> Alcotest.fail "expected a single GenericStructDef");

  Alcotest.test_case
    "two instantiations of the same generic struct with different N values \
     register two distinct mangled-name struct types, each with the right \
     array field length (const generics)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct FixedBufCg(T: type, N: usize) {
            data: [T; N];
          }
          private let mut fixedbufcg_g3: FixedBufCg(usize, 3);
          private let mut fixedbufcg_g5: FixedBufCg(usize, 5);"
       in
       let find name = match Hashtbl.find_opt Llvm_gen.struct_lltypes name with
         | Some llty -> llty
         | None -> Alcotest.failf "%s not registered in struct_lltypes" name
       in
       let arr_len llty = Llvm.array_length (Llvm.struct_element_types llty).(0) in
       let ty3 = find "FixedBufCg$usize$3" in
       let ty5 = find "FixedBufCg$usize$5" in
       Alcotest.(check int) "N=3 array field has length 3" 3 (arr_len ty3);
       Alcotest.(check int) "N=5 array field has length 5" 5 (arr_len ty5);
       Alcotest.(check bool) "the two instantiations are genuinely distinct LLVM types"
         true (ty3 <> ty5));

  Alcotest.test_case
    "a generic struct field's array size may be a symbolic arithmetic \
     expression over its own value parameter (`N + 1`), resolved once N is \
     bound (const generics)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct FixedBufCg2(T: type, N: usize) {
            data: [T; N + 1];
          }
          private let mut fixedbufcg2_g: FixedBufCg2(usize, 3);"
       in
       let ty = match Hashtbl.find_opt Llvm_gen.struct_lltypes "FixedBufCg2$usize$3" with
         | Some llty -> llty
         | None -> Alcotest.fail "FixedBufCg2$usize$3 not registered"
       in
       Alcotest.(check int) "N + 1 = 4"
         4 (Llvm.array_length (Llvm.struct_element_types ty).(0)));

  Alcotest.test_case
    "a generic function call infers BOTH its type parameter and its value \
     parameter from a bare pointer argument's own declared type, with no \
     explicit arguments at the call site (const generics)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct FixedBufCg3(T: type, N: usize) {
            data: [T; N];
          }
          fn fixedbufcg3_get(T: type, b: *FixedBufCg3(T, N)) -> T {
            let d = b.data;
            return d[0];
          }
          private let mut fixedbufcg3_g: FixedBufCg3(usize, 3);
          fn fixedbufcg3_use() -> usize {
            return fixedbufcg3_get(&fixedbufcg3_g);
          }"
       in
       match Hashtbl.find_opt Llvm_gen.functions "fixedbufcg3_get$usize$3" with
       | Some _ -> ()
       | None -> Alcotest.fail "fixedbufcg3_get$usize$3 was not generated");

  Alcotest.test_case
    "assigning a mismatched-size array into a const-generic struct's field \
     is an ordinary type error -- no new mismatch-detection code, plain \
     structural unification catches it once N is concrete" `Quick
    (expect_type_error "cannot unify"
       "generic struct FixedBufCg4(T: type, N: usize) { data: [T; N]; }
        fn fixedbufcg4_mismatch() {
          let mut a: FixedBufCg4(usize, 3);
          let mut src: [usize; 5];
          a.data = src;
        }");

  Alcotest.test_case
    "a generic function call whose two arguments would bind the same VALUE \
     parameter to two DIFFERENT concrete values is rejected -- the value- \
     parameter analogue of Pairg207's own conflicting-type-inference test \
     (const generics)" `Quick
    (expect_type_error
       "conflicting inference for generic value parameter 'N'"
       "generic struct Pairg207cg(T: type, N: usize) { a: [T; N]; }
        fn pairg207cg_combine(T: type, x: *Pairg207cg(T, N), y: *Pairg207cg(T, N)) -> T {
          let d = x.a;
          return d[0];
        }
        fn pairg207cg_use() {
          let mut p1: Pairg207cg(usize, 3);
          let mut p2: Pairg207cg(usize, 5);
          pairg207cg_combine(&p1, &p2);
        }");

  Alcotest.test_case
    "a const-generic struct instantiated with too few arguments (missing \
     N) is rejected with a clear arity error" `Quick
    (expect_type_error
       "expects 2 argument(s), got 1"
       "generic struct FixedBufCg5(T: type, N: usize) { data: [T; N]; }
        fn fixedbufcg5_missing() {
          let mut a: FixedBufCg5(usize);
        }");

  Alcotest.test_case
    "a const-generic struct instantiated with a TYPE where a VALUE is \
     expected is rejected with a clear kind-mismatch error, not a crash" `Quick
    (expect_type_error
       "parameter 'N' expects a value, got a type"
       "generic struct FixedBufCg6(T: type, N: usize) { data: [T; N]; }
        fn fixedbufcg6_wrongkind() {
          let mut a: FixedBufCg6(usize, usize);
        }");

  (* -- Freelist redesign follow-up: symbolic slice minimum (`[T; N..]`)
     and expression-level value-generic-parameter substitution ---------- *)

  Alcotest.test_case
    "a generic struct's slice field with a symbolic minimum length \
     (`[T; N..]`) parses to TypeSliceSym" `Quick
    (fun () ->
       let items = parse
         "generic struct FixedBufCg7(T: type, N: usize) {
            data: [T; N..];
          }"
       in
       match items with
       | [ Ast.GenericStructDef (_, _, [ ("data", field_ty) ], _, _, _, _) ] ->
           (match field_ty with
            | Ast.TypeSliceSym (Ast.TypeNamed "T", Ast.ASParam "N") -> ()
            | _ -> Alcotest.fail "expected TypeSliceSym(TypeNamed \"T\", ASParam \"N\")")
       | _ -> Alcotest.fail "expected a single GenericStructDef with one field");

  Alcotest.test_case
    "assigning a correctly-sized array-cast-to-slice into a symbolic- \
     minimum slice field succeeds" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct FixedBufCg8(T: type, N: usize) { data: [T; N..]; }
          private let mut fixedbufcg8_backing: [usize; 3];
          fn fixedbufcg8_ok() {
            let mut a: FixedBufCg8(usize, 3);
            a.data = fixedbufcg8_backing as []usize;
          }"
       in
       ());

  Alcotest.test_case
    "assigning an UNDERSIZED array-cast-to-slice into a symbolic-minimum \
     slice field is a compile-time type error -- the direct regression \
     test for the freelist redesign's motivating gap (an unconstrained \
     `[]T` field previously enforced nothing at all)" `Quick
    (expect_type_error "cannot pass"
       "generic struct FixedBufCg9(T: type, N: usize) { data: [T; N..]; }
        private let mut fixedbufcg9_backing: [usize; 2];
        fn fixedbufcg9_undersized() {
          let mut a: FixedBufCg9(usize, 3);
          a.data = fixedbufcg9_backing as []usize;
        }");

  Alcotest.test_case
    "a generic function may use its own inferred value-generic-parameter \
     as an ordinary runtime expression in its body (e.g. a for-loop \
     bound), not just in a type-level array size -- mirrors \
     freelist_core_init's actual shape" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct FixedBufCg10(N: usize) {
            data: [usize; N];
          }
          fn fixedbufcg10_init(target: *FixedBufCg10(N)) {
            let next = target.data;
            for i: isize in 0..<N {
              next[i] = i as usize;
            }
          }
          fn fixedbufcg10_use() {
            let mut a: FixedBufCg10(4);
            fixedbufcg10_init(&a);
          }"
       in
       match Hashtbl.find_opt Llvm_gen.functions "fixedbufcg10_init$4" with
       | Some _ -> ()
       | None -> Alcotest.fail "fixedbufcg10_init$4 was not generated");

  (* GitHub issue #207 const-generics/Freelist-redesign follow-up: a real,
     confirmed bug (found by disassembling an actually-miscompiled
     linux_user binary, not by inspection -- the AST was correct at every
     stage of monomorphize.ml; llvm_gen.ml's Call codegen picked the wrong
     target). Two DIFFERENT instantiations of a template whose body calls
     ANOTHER generic function end up with IDENTICAL Ast.loc values on the
     corresponding Call node (Monomorphize.transform/walk_stmt/walk_expr
     preserve the template's own loc verbatim), colliding in
     type_inf.ml's loc-keyed resolved_call_targets cache -- so one
     instantiation's nested call silently got resolved to the OTHER
     instantiation's target. Fixed by relocate_stmt/relocate_expr, giving
     each instantiation's own AST nodes a unique loc.pos_fname suffix. *)
  Alcotest.test_case
    "two instantiations of a generic struct (different T AND N) whose \
     init function calls ANOTHER generic function each call their OWN \
     matching nested instantiation, not each other's (regression test \
     for a real miscompilation found via the freelist redesign)" `Quick
    (fun () ->
       let _ = gen_codegen
         "generic struct RegrInner(N: usize) {
            data: [usize; N];
            dummy: usize;
          }
          fn regr_inner_init(target: *RegrInner(N)) {
            let d = target.data;
            for i: isize in 0..<N {
              d[i] = i as usize + 1;
            }
            target.dummy = 0;
          }
          generic struct RegrOuter(T: type, N: usize) {
            inner: RegrInner(N);
            payload: T;
          }
          fn regr_outer_init(T: type, target: *RegrOuter(T, N)) {
            regr_inner_init(&target.inner);
          }
          struct RegrPoint { x: usize; y: usize; }
          private let mut regr_outer3: RegrOuter(usize, 3);
          private let mut regr_outer2: RegrOuter(RegrPoint, 2);
          fn regr_use() {
            regr_outer_init(&regr_outer3);
            regr_outer_init(&regr_outer2);
          }"
       in
       let ir name = match Hashtbl.find_opt Llvm_gen.functions name with
         | Some (_, fn) -> Llvm.string_of_llvalue fn
         | None -> Alcotest.failf "%s was not generated" name
       in
       (* LLVM quotes identifiers containing '$', e.g. @"regr_inner_init$3". *)
       Alcotest.(check bool) "regr_outer_init$usize$3 calls regr_inner_init$3, not $2"
         true (contains_substring (ir "regr_outer_init$usize$3") "@\"regr_inner_init$3\""
               && not (contains_substring (ir "regr_outer_init$usize$3") "@\"regr_inner_init$2\""));
       Alcotest.(check bool) "regr_outer_init$RegrPoint$2 calls regr_inner_init$2, not $3"
         true (contains_substring (ir "regr_outer_init$RegrPoint$2") "@\"regr_inner_init$2\""
               && not (contains_substring (ir "regr_outer_init$RegrPoint$2") "@\"regr_inner_init$3\"")));

  (* GitHub issue #314/#319: &mut T codegens identically to *T -- same bare
     pointer representation, verified end-to-end through LLVM's own IR
     verifier (not just type-checked). Mirrors the growable_pool.tkb
     migration shape: a &mut-typed parameter mutates a field, called with
     a plain `&local`. *)
  Alcotest.test_case "&mut T parameter mutation codegens and verifies" `Quick
    (expect_codegen_ok
       "struct RefCodegenPool { count: usize; }
        fn ref_codegen_bump(p: &mut RefCodegenPool) { p.count = p.count + 1; }
        fn ref_codegen_app_main() -> usize {
          let mut pool: RefCodegenPool = {0};
          ref_codegen_bump(&pool);
          return pool.count;
        }");

  (* Exact growable_pool.tkb migration shape: `let core: &Core = &pool.core;`
     -- a &T local initialized from a nested field address, then used to
     read through. *)
  Alcotest.test_case "let with &T annotation from a nested field address codegens and verifies" `Quick
    (expect_codegen_ok
       "struct RefCodegenCore { n: usize; }
        struct RefCodegenOuter { core: RefCodegenCore; }
        fn ref_codegen_use_core(c: &RefCodegenCore) -> usize { return c.n; }
        fn ref_codegen_outer_main(pool: &mut RefCodegenOuter) -> usize {
          let core: &RefCodegenCore = &pool.core;
          return ref_codegen_use_core(core);
        }");

  (* GitHub issue #322: lib/monomorphize.ml's derive_arg_type/unify_arg is
     a THIRD independent layer (beyond type_inf.ml's Types.ty-level unify
     rules and llvm_gen.ml's own codegen matches) that re-derives "does
     this argument's type match this generic parameter's declared wrapper
     shape" reasoning, purely syntactically on raw Ast.type_expr, with
     zero visibility into type_inf.ml's own widening/subtyping rules.
     Adding TypeRef/TypeRefMut for #314/#319/#320 broke generic inference
     for every caller of a migrated generic function ("cannot infer type
     parameter 'T'"), caught only by a real `make kernelbuild-qemu`, not
     `dune test` -- neither gap was caught by any codegen test. These
     cases are the regression coverage that would have caught that (and
     would catch any future missing wrapper companion case) before a real
     kernel build does, one per wrapper Ast.type_expr constructor that can
     legally appear on a generic function's parameter. *)
  Alcotest.test_case
    "generic inference through a *T (TypePtr) parameter (issue #322)" `Quick
    (expect_codegen_ok
       "fn inner322ptr(T: type, p: *T) -> T { return *p; }
        fn outer322ptr() -> usize {
          let mut x: usize = 7;
          return inner322ptr(&x);
        }");

  (* Codegen has no Deref case for TypeAlignedPtr (only TypePtr/TypePtr(TypeIo
     _) -- a separate, pre-existing gap, not this issue's concern), so this
     exercises inference only, without dereferencing p. *)
  Alcotest.test_case
    "generic inference through a *align(N) T (TypeAlignedPtr) parameter \
     (issue #322)" `Quick
    (expect_codegen_ok
       "fn inner322align(T: type, p: *align(8) T) { }
        fn outer322align(p: *align(8) usize) {
          inner322align(p);
        }");

  (* type_inf.ml's validate_param_type restricts `borrow` to a raw/aligned
     pointer, slice, affine/linear opaque pointer, indexed owner, erased
     view, or kinded variant -- a bare generic `T` is none of those, so the
     wrapped type must itself be a raw pointer (`borrow *T`). *)
  Alcotest.test_case
    "generic inference through a borrow *T (TypeBorrow) parameter \
     (issue #322)" `Quick
    (expect_codegen_ok
       "fn inner322borrow(T: type, p: borrow *T) { }
        fn outer322borrow(x: *usize) {
          inner322borrow(x);
        }");

  (* validate_param_type restricts `borrow mut` specifically to an
     affine/linear INDEXED runtime owner (Ast.TypeIndexed on a kinded
     name) -- unlike the other wrappers, this one cannot wrap a bare
     generic T at all, so the type/value-generic inference driven through
     T here comes from a SEPARATE, ordinary `val: T` parameter alongside
     the borrow-mut-wrapped one; this still exercises unify_arg's
     `TypeBorrowMut a, b -> u a b` arm for the second parameter without
     crashing or mis-inferring the first. *)
  Alcotest.test_case
    "generic inference through a borrow mut Owner[n] (TypeBorrowMut) \
     parameter alongside an ordinary T parameter (issue #322)" `Quick
    (expect_codegen_ok
       "linear struct BorrowMut322Owner[n: usize] { value: i32; }
        fn inner322borrowmut(T: type, val: T, o: borrow mut BorrowMut322Owner[n]) { }
        fn outer322borrowmut(x: usize, o: borrow mut BorrowMut322Owner[m]) {
          inner322borrowmut(x, o);
        }");

  (* validate_param_type restricts `sink` to (among others) an
     affine/linear OPAQUE POINTER -- `sink *T` where T resolves to an
     affine opaque struct, mirroring `borrow *T` above. *)
  Alcotest.test_case
    "generic inference through a sink *T (TypeSink) parameter (issue #322)"
    `Quick
    (expect_codegen_ok
       "affine opaque struct Sink322Token;
        fn inner322sink(T: type, p: sink *T) { }
        fn outer322sink(x: *Sink322Token) {
          inner322sink(x);
        }");

  Alcotest.test_case
    "generic inference through a &T (TypeRef) parameter (issue #322)" `Quick
    (expect_codegen_ok
       "struct Ref322Point { n: usize; }
        fn inner322ref(T: type, p: &T) -> usize { return p.n; }
        fn outer322ref(pt: &Ref322Point) -> usize {
          return inner322ref(pt);
        }");

  Alcotest.test_case
    "generic inference through a &mut T (TypeRefMut) parameter \
     (issue #322)" `Quick
    (expect_codegen_ok
       "struct RefMut322Point { n: usize; }
        fn inner322refmut(T: type, p: &mut T) { p.n = p.n + 1; }
        fn outer322refmut(pt: &mut RefMut322Point) {
          inner322refmut(pt);
        }");

  Alcotest.test_case
    "generic inference through a *io T (TypeIo) parameter (issue #322)"
    `Quick
    (expect_codegen_ok
       "fn inner322io(T: type, p: *io T) -> T { return *p; }
        fn outer322io(p: *io u32) -> u32 {
          return inner322io(p);
        }");

  (* The &x.field nested-field-address form specifically -- derive_arg_
     type's own header comment calls this out as needed for "a generic
     function's own body calling ANOTHER generic function via a field
     address" (the kernel/lib/growable_pool.tkb-adjacent shape this
     mechanism was built for). Requires the outer variable's OWN type to
     already be a TypeGenericInst (an instantiated generic struct, not a
     plain one -- see issue #259 for the plain-struct gap this does NOT
     cover), matching derive_arg_type's own match arms exactly. *)
  Alcotest.test_case
    "generic inference through &x.field where x's own type is a generic \
     struct instance (issue #322)" `Quick
    (expect_codegen_ok
       "generic struct Field322Core(T: type) { n: T; }
        generic struct Field322Outer(T: type) { core: Field322Core(T); }
        fn inner322field(T: type, p: *Field322Core(T)) -> T { return p.n; }
        fn outer322field(o: Field322Outer(usize)) -> usize {
          return inner322field(&o.core);
        }");

  (* GitHub issue #323: routing the Call-argument loop through check_expr
     would make a bare `{ ... }` struct-literal argument against a
     struct-typed parameter type-check (check_expr's own StructLit cases),
     where it previously always raised "struct literal requires a type
     annotation" -- EXCEPT llvm_gen.ml's codegen has no support for a
     StructLit as a general call-argument expression (its own gen_expr
     raises "BUG: StructLit must be handled in gen_stmt / gen_global, not
     gen_expr" for it: this test caught that mismatch the first time it
     was written as a positive "now type-checks" case). #323's own Call
     loop deliberately special-cases StructLit arguments to bypass
     check_expr and keep calling infer_expr directly instead, preserving
     the exact pre-#323 rejection. This is the negative-control regression
     test for that deliberate exclusion. *)
  Alcotest.test_case
    "a bare struct-literal call argument is still rejected, not silently \
     accepted by check_expr (issue #323 negative control)" `Quick
    (expect_type_error "struct literal requires a type annotation"
       "struct Struct323Point { x: i32; y: i32; }
        fn struct323_sum(p: Struct323Point) -> i32 { return p.x + p.y; }
        fn struct323_use() -> i32 {
          return struct323_sum({1, 2});
        }");

  (* GitHub issue #259: derive_arg_type's &x.field case previously only
     matched when x's OWN type was itself a TypeGenericInst (an
     instantiated generic struct) -- a PLAIN, non-generic struct whose
     field is already a fully-concrete generic instantiation (nothing to
     substitute) had no matching case at all, so `N` could not be inferred
     and the call was rejected with "cannot infer generic value parameter
     'N'". Mirrors kernel/mm/page.tkb's BootPagePool shape (issue #253):
     an ordinary struct field whose declared type is already concrete. *)
  Alcotest.test_case
    "generic value-parameter inference through &x.field where x's own \
     type is a PLAIN (non-generic) struct (issue #259)" `Quick
    (expect_codegen_ok
       "generic struct Core259(N: usize) { cap: usize; }
        struct Outer259 { core: Core259(4); meta: usize; }
        private let mut outer259_global: Outer259;
        fn core259_init(c: *Core259(N)) { }
        fn outer259_use() {
          core259_init(&outer259_global.core);
        }");

]

(* GitHub issue #55: Use_resolver's DFS closure algorithm, tested against
   an in-memory fake "filesystem" (path -> already-parsed items) rather
   than real files -- parse_file/prescan are dependency-injected exactly
   so this is possible; see Use_resolver's own header comment. Each fake
   file's source is built with the ordinary `parse` helper (reusing the
   real lexer/parser) rather than hand-constructed Ast records, so these
   tests exercise the same UseDef-extraction path a real file would. *)
let use_resolver_tests =
  let uses_of items = List.filter_map (function Ast.UseDef p -> Some p | _ -> None) items in
  let make_fs pairs =
    let table = List.map (fun (path, src) -> (path, parse src)) pairs in
    let parse_file path =
      match List.assoc_opt path table with
      | Some items -> items
      | None -> Alcotest.failf "fake_fs: no such file %s" path
    in
    let prescan path = uses_of (parse_file path) in
    (parse_file, prescan)
  in
  [
    Alcotest.test_case "resolve: single file with no use returns itself" `Quick (fun () ->
      let (parse_file, prescan) = make_fs ["a.tkb", "fn f() {}"] in
      let result = Use_resolver.resolve ~parse_file ~prescan ["a.tkb"] in
      Alcotest.(check (list string)) "order" ["a.tkb"] (List.map fst result));

    Alcotest.test_case "resolve: dependency comes before dependent" `Quick (fun () ->
      let (parse_file, prescan) = make_fs [
        "a.tkb", "use \"b.tkb\";\nfn a_fn() {}";
        "b.tkb", "fn b_fn() {}";
      ] in
      let result = Use_resolver.resolve ~parse_file ~prescan ["a.tkb"] in
      Alcotest.(check (list string)) "order" ["b.tkb"; "a.tkb"] (List.map fst result));

    Alcotest.test_case "resolve: transitive A->B->C resolves in dependency order" `Quick (fun () ->
      let (parse_file, prescan) = make_fs [
        "a.tkb", "use \"b.tkb\";\nfn a_fn() {}";
        "b.tkb", "use \"c.tkb\";\nfn b_fn() {}";
        "c.tkb", "fn c_fn() {}";
      ] in
      let result = Use_resolver.resolve ~parse_file ~prescan ["a.tkb"] in
      Alcotest.(check (list string)) "order" ["c.tkb"; "b.tkb"; "a.tkb"] (List.map fst result));

    Alcotest.test_case "resolve: diamond dependency is visited only once" `Quick (fun () ->
      let (parse_file, prescan) = make_fs [
        "a.tkb", "use \"b.tkb\";\nuse \"c.tkb\";\nfn a_fn() {}";
        "b.tkb", "use \"d.tkb\";\nfn b_fn() {}";
        "c.tkb", "use \"d.tkb\";\nfn c_fn() {}";
        "d.tkb", "fn d_fn() {}";
      ] in
      let result = Use_resolver.resolve ~parse_file ~prescan ["a.tkb"] in
      let names = List.map fst result in
      Alcotest.(check int) "total files" 4 (List.length names);
      Alcotest.(check int) "d.tkb appears exactly once"
        1 (List.length (List.filter (( = ) "d.tkb") names));
      Alcotest.(check (option string)) "a.tkb is last (entry point, appended after all deps)"
        (Some "a.tkb") (List.nth_opt names (List.length names - 1)));

    Alcotest.test_case "resolve: a cycle does not infinite-loop and visits each file once" `Quick
      (fun () ->
         let (parse_file, prescan) = make_fs [
           "a.tkb", "use \"b.tkb\";\nfn a_fn() {}";
           "b.tkb", "use \"a.tkb\";\nfn b_fn() {}";
         ] in
         let result = Use_resolver.resolve ~parse_file ~prescan ["b.tkb"] in
         let names = List.map fst result in
         Alcotest.(check int) "total files" 2 (List.length names);
         Alcotest.(check bool) "a.tkb present" true (List.mem "a.tkb" names);
         Alcotest.(check bool) "b.tkb present" true (List.mem "b.tkb" names));

    Alcotest.test_case
      "resolve: no use declarations anywhere preserves command-line order exactly \
       (backward compatibility with every pre-#55 Makefile invocation)" `Quick
      (fun () ->
         let (parse_file, prescan) = make_fs [
           "x.tkb", "fn x_fn() {}";
           "y.tkb", "fn y_fn() {}";
         ] in
         let result = Use_resolver.resolve ~parse_file ~prescan ["x.tkb"; "y.tkb"] in
         Alcotest.(check (list string)) "order unchanged" ["x.tkb"; "y.tkb"] (List.map fst result));

    Alcotest.test_case "resolve rejects a use declaration appearing after another item" `Quick
      (fun () ->
         let (parse_file, prescan) = make_fs [
           "a.tkb", "use \"b.tkb\";\nfn a_fn() {}";
           "b.tkb", "fn early() {}\nuse \"a.tkb\";";
         ] in
         match Use_resolver.resolve ~parse_file ~prescan ["a.tkb"] with
         | _ -> Alcotest.fail "expected Use_resolver.Use_error"
         | exception Use_resolver.Use_error msg ->
             Alcotest.(check bool) "mentions the offending file" true
               (contains_substring msg "b.tkb"));
  ]

(* GitHub issue #306: depfile_contents is a pure string builder (no file
   I/O), so these test it directly rather than through write_depfile and a
   real temp file -- same "test the pure core, not the thin I/O wrapper"
   split use_resolver_tests already uses for resolve vs. parse_file. *)
let depfile_tests =
  [
    Alcotest.test_case "depfile_contents: no deps still names the output" `Quick (fun () ->
      Alcotest.(check string) "line"
        "main.o:\n" (Use_resolver.depfile_contents "main.o" []));

    Alcotest.test_case "depfile_contents: single dep" `Quick (fun () ->
      Alcotest.(check string) "line"
        "main.o: a.tkb\n" (Use_resolver.depfile_contents "main.o" ["a.tkb"]));

    Alcotest.test_case "depfile_contents: multiple deps stay in the given order, \
                         space-separated, matching Use_resolver.resolve's own \
                         dependency-before-dependent order" `Quick (fun () ->
      Alcotest.(check string) "line"
        "main.o: c.tkb b.tkb a.tkb\n"
        (Use_resolver.depfile_contents "main.o" ["c.tkb"; "b.tkb"; "a.tkb"]));

    Alcotest.test_case "depfile_contents: output composed directly with \
                         Use_resolver.resolve's own result" `Quick (fun () ->
      let uses_of items = List.filter_map (function Ast.UseDef p -> Some p | _ -> None) items in
      let table = [
        "a.tkb", parse "use \"b.tkb\";\nfn a_fn() {}";
        "b.tkb", parse "fn b_fn() {}";
      ] in
      let parse_file path = List.assoc path table in
      let prescan path = uses_of (parse_file path) in
      let resolved = Use_resolver.resolve ~parse_file ~prescan ["a.tkb"] in
      Alcotest.(check string) "line"
        "main.o: b.tkb a.tkb\n"
        (Use_resolver.depfile_contents "main.o" (List.map fst resolved)));
  ]

(* Takibi Core Slice 0: the surface checker's branch lattice is extracted
   behind Delta.Legacy_flow. Slice 3 later changed which component affine
   consults without changing this dataflow representation. *)
module Core_test_place = struct
  type t = string
  let compare = String.compare
end

module Core_test_flow = Takibi_core.Delta.Legacy_flow (Core_test_place)

let core_tests = [
  Alcotest.test_case "legacy flow: consume and produce" `Quick (fun () ->
    let consumed = Core_test_flow.consume "lease" Core_test_flow.empty in
    Alcotest.(check bool) "maybe consumed after consume" true
      (Core_test_flow.may_be_consumed "lease" consumed);
    Alcotest.(check bool) "consumed on all paths after consume" true
      (Core_test_flow.is_consumed_on_all_paths "lease" consumed);
    let produced = Core_test_flow.produce "lease" consumed in
    Alcotest.(check bool) "available after produce" false
      (Core_test_flow.may_be_consumed "lease" produced));

  Alcotest.test_case "legacy flow: one-branch consume is maybe, not must" `Quick
    (fun () ->
      let yes = Core_test_flow.consume "guard" Core_test_flow.empty in
      let joined = Core_test_flow.join_branches yes Core_test_flow.empty in
      Alcotest.(check bool) "union component" true
        (Core_test_flow.may_be_consumed "guard" joined);
      Alcotest.(check bool) "intersection component" false
        (Core_test_flow.is_consumed_on_all_paths "guard" joined));

  Alcotest.test_case "legacy flow: both-branch consume is must" `Quick (fun () ->
    let left = Core_test_flow.consume "pending" Core_test_flow.empty in
    let right = Core_test_flow.consume "pending" Core_test_flow.empty in
    let joined = Core_test_flow.join_branches left right in
    Alcotest.(check bool) "union component" true
      (Core_test_flow.may_be_consumed "pending" joined);
    Alcotest.(check bool) "intersection component" true
      (Core_test_flow.is_consumed_on_all_paths "pending" joined));
]

(* -- Entry point ----------------------------------------------------------- *)

let named_groups = [
  "core",     core_tests;
  "parser",   parser_tests;
  "type_inf", infer_tests;
  "use_resolver", use_resolver_tests;
  "depfile",      depfile_tests;
  "codegen",  codegen_tests;
]

(* GitHub issue #329: proactively surfaces cross-test state-leak bugs like
   issue #326's un-reset Hashtables, which sat dormant until a new test
   happened to land at exactly the wrong fixed position. Opt-in via
   SHUFFLE_TESTS (default run order above is completely unchanged when the
   env var is unset), and deliberately flattens/interleaves ALL SIX groups
   into one shuffled sequence rather than only shuffling within each named
   group -- #326's own bug crossed group boundaries (a type_inf-group test
   corrupted a codegen-group test), and Alcotest runs the groups given to
   `run` in the fixed order given to it, so shuffling only within each
   group can never reorder relative to another group and would not have
   caught that exact case.

   Alcotest has no built-in shuffle/seed option (`--help` confirms), and
   `'a test_case = string * speed_level * (a' -> return)` is registered
   per NAMED GROUP with per-group indices starting at 0 (lib/alcotest's
   own Core.register) -- passing the same group name in multiple separate
   `(name, cases)` entries to flatten across groups would make every entry
   restart its own index at 0, producing "Duplicate test path" errors, not
   an interleaved run. So a shuffled run collapses to ONE synthetic
   "shuffled" group with fresh sequential Alcotest-native numbers, NOT the
   original per-group numbers used elsewhere in this file and in past
   debugging sessions -- to keep a shuffled failure greppable back to
   where it lived before shuffling, each test's own original "group#index"
   is prefixed onto its doc string instead (visible in Alcotest's own
   printed test line, e.g. "shuffled 314 [codegen#181] ..."), a deliberate
   substitute for the numbering this design question in the issue itself
   flagged as a real cost, not an accidental side effect.

   SHUFFLE_TESTS=1 uses a fresh random seed (rerun to get a different
   order); any other value that parses as an int is used AS the seed
   verbatim, to reproduce an exact past shuffled run. The seed actually
   used is always printed first, in the SHUFFLE_TESTS=<seed> form, so a
   failure can be reproduced exactly regardless of which form triggered
   this run. *)
let () =
  match Sys.getenv_opt "SHUFFLE_TESTS" with
  | None -> Alcotest.run "takibi" named_groups
  | Some raw ->
      let seed = match raw with
        | "1" -> Random.self_init (); Random.bits ()
        | s -> (match int_of_string_opt s with
                | Some n -> n
                | None -> Random.self_init (); Random.bits ())
      in
      Printf.printf
        "SHUFFLE_TESTS=%d (rerun with SHUFFLE_TESTS=%d to reproduce this exact order)\n%!"
        seed seed;
      let rng = Random.State.make [| seed |] in
      let flat = List.concat_map (fun (gname, cases) ->
        List.mapi (fun i case -> (gname, i, case)) cases
      ) named_groups in
      let arr = Array.of_list flat in
      for i = Array.length arr - 1 downto 1 do
        let j = Random.State.int rng (i + 1) in
        let tmp = arr.(i) in arr.(i) <- arr.(j); arr.(j) <- tmp
      done;
      let shuffled = Array.to_list arr |> List.map (fun (gname, i, (doc, speed, fn)) ->
        (Printf.sprintf "[%s#%d] %s" gname (i + 1) doc, speed, fn)
      ) in
      Alcotest.run "takibi" [ "shuffled", shuffled ]
