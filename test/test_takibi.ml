open Takibi

(* -- Helpers --------------------------------------------------------------- *)

let parse src =
  Const_env.reset ();
  Type_layout.reset ();
  let lexbuf = Lexing.from_string src in
  Parser.program Lexer.read lexbuf

let infer src =
  Type_inf.infer_program (parse src)

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
  Type_inf.infer_program prog

(* Runs the full pipeline through LLVM codegen (no target machine, no
   object-file emission -- gen_program works without setup_target, see its
   align_opt handling). Each caller must use function/global names unique
   within this test binary: Llvm_gen.the_module is a single process-global
   module with no reset, so two test cases defining the same name would
   collide. *)
let gen_codegen src =
  let prog = parse src in
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
  | Ast.TypeView s      -> "view " ^ s
  | Ast.TypeVariant s   -> s
  | Ast.TypeExists (name, sort, body) ->
      Printf.sprintf "exists %s: %s. %s" name (show_type sort) (show_type body)
  | Ast.TypeIndexed (s, args) ->
      let arg = function
        | Ast.StaticName n -> n
        | Ast.StaticInt n -> string_of_int n
      in
      Printf.sprintf "%s[%s]" s (String.concat ", " (List.map arg args))
  | Ast.TypeSingleton (t, n) ->
      let n = match n with
        | Ast.StaticName n -> n
        | Ast.StaticInt n -> string_of_int n
      in
      Printf.sprintf "%s @ %s" (show_type t) n
  | Ast.TypeRefined (lo, hi, _) -> Printf.sprintf "{%d..<%d}" lo hi
  | Ast.TypeSlice (t, 0) -> Printf.sprintf "[]%s" (show_type t)
  | Ast.TypeSlice (t, n) -> Printf.sprintf "[%s; %d..]" (show_type t) n
  | Ast.TypeBorrow t -> "borrow " ^ show_type t
  | Ast.TypeBorrowMut t -> "borrow mut " ^ show_type t
  | Ast.TypeSink t -> "sink " ^ show_type t
  | Ast.TypeAlignedPtr (n, t) -> Printf.sprintf "*align(%d) %s" n (show_type t)
  | Ast.TypeTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map show_type ts))

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
      | [Ast.ViewDef ("ParsedPending", Ast.KindLinear, true, _);
         Ast.FuncDef { ret_type = Some (Ast.TypeNamed "ParsedPending");
                       body = [{ desc = Ast.Return
                         { desc = Ast.ViewLit "ParsedPending"; _ }; _ }]; _ }] -> ()
      | _ -> Alcotest.fail "expected a private linear ViewDef and ViewLit");

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
                Ast.TypeIndexed ("ParsedOwner", [Ast.StaticName "n"]))))], _);
         Ast.FuncDef { body = [{ desc = Ast.Return
           { desc = Ast.VariantCtor ("ParsedMaybe", "Some", _); _ }; _ }]; _ };
         Ast.FuncDef { body = [{ desc = Ast.Match (_,
           [Ast.ArmVariant ("ParsedMaybe", "None", None, []);
            Ast.ArmVariant ("ParsedMaybe", "Some", Some ("owner", false), [])]); _ }]; _ }] -> ()
      | _ -> Alcotest.fail "expected Slice 3 variant AST nodes");

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
         fn parsed_nonblocking() !{} {}" with
      | [Ast.ExternFuncDef ("parsed_wait", [], None, Some ["may_block"]);
         Ast.FuncDef { name = "parsed_irq"; effects = Some ["interrupt"]; _ };
         Ast.FuncDef { name = "parsed_nonblocking"; effects = Some []; _ }] -> ()
      | _ -> Alcotest.fail "expected may_block and interrupt effect annotations");


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
    | [Ast.FuncDef { name = "add1"; is_inline = true; _ }] -> ()
    | _ -> Alcotest.fail "expected inline FuncDef"
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

  Alcotest.test_case "array size via named compile-time constant resolves" `Quick (fun () ->
    match parse "let N: i32 = 4; let ring: [u8; N];" with
    | [Ast.LetDef _; Ast.LetDef ("ring", Some (Ast.TypeArray (Ast.TypeU8, 4)), None, None, false, _, _)] -> ()
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
    match parse "let QNUM: i32 = 8; let RX_BUF_SIZE: i32 = 1536; \
                 let bufs: [u8; QNUM * RX_BUF_SIZE];" with
    | [_; _; Ast.LetDef ("bufs", Some (Ast.TypeArray (Ast.TypeU8, 12288)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 12288"
  );

  Alcotest.test_case "array size formula: difference of a named constant and a literal" `Quick (fun () ->
    match parse "let COUNT: i32 = 4; let ring: [u8; COUNT - 1];" with
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
    match parse "let PAGE_SIZE: i32 = 4096; let bufs: [u8; (2 * PAGE_SIZE) / 2];" with
    | [_; Ast.LetDef ("bufs", Some (Ast.TypeArray (Ast.TypeU8, 4096)), None, None, false, _, _)] -> ()
    | _ -> Alcotest.fail "expected array size resolved to 4096"
  );

  Alcotest.test_case "array size formula: division by zero is a compile error, \
                       not a crash" `Quick (fun () ->
    match parse "let Z: i32 = 0; let ring: [u8; 4 / Z];" with
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
         | Ast.Return { desc = Ast.IntLit 42L; _ } -> ()
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
         | Ast.Assign ("x", { desc = Ast.IntLit 3L; _ }) -> ()
         | _ -> Alcotest.fail "expected Assign(x, IntLit 3)")
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
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "outer op is Add" Ast.Add op
         | _ -> Alcotest.fail "expected Return(BinOp)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "comparison BinOp" `Quick (fun () ->
    match parse "fn f() i32 { return 1 != 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Ne" Ast.Ne op
         | _ -> Alcotest.fail "expected Return(BinOp)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "function call expression" `Quick (fun () ->
    match parse "fn f() i32 { return g(1, 2); }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Call ("g", args); _ } ->
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
         | Ast.Return { desc = Ast.Deref { desc = Ast.Var "p"; _ }; _ } -> ()
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
         | Ast.AssignDeref ({ desc = Ast.Var "p"; _ },
                             { desc = Ast.IntLit 42L; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(Var p, IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "hex integer literal" `Quick (fun () ->
    match parse "fn f() i32 { return 0xff; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 255L; _ } -> ()
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
         | Ast.Return { desc = Ast.IntLit (-1L); _ } -> ()
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
         | Ast.Return { desc = Ast.IntLit (-1L); _ } -> ()  (* u64::MAX's bit pattern *)
         | _ -> Alcotest.fail "expected Return(IntLit -1L)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "u8 literal becomes IntLit" `Quick (fun () ->
    match parse "fn f() i32 { return 'A'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 65L; _ } -> ()
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
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "outer op is Or" Ast.Or op
         | _ -> Alcotest.fail "expected Return(BinOp Or)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "logical AND expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a >= 0 && b < 8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "outer op is And" Ast.And op
         | _ -> Alcotest.fail "expected Return(BinOp And)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "&& has lower prec than comparisons" `Quick (fun () ->
    (* a >= 0 && b < 8  ->  (a >= 0) && (b < 8): outer is And, both children are comparisons *)
    match parse "fn f(a: i32, b: i32) i32 { return a >= 0 && b < 8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.And,
             { desc = Ast.BinOp (Ast.Ge, _, _); _ },
             { desc = Ast.BinOp (Ast.Lt, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected And(Ge, Lt)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "&& has higher prec than ||" `Quick (fun () ->
    (* a || b && c  ->  a || (b && c): outer is Or *)
    match parse "fn f(a: i32, b: i32, c: i32) i32 { return a || b && c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Or, _,
             { desc = Ast.BinOp (Ast.And, _, _); _ }); _ } -> ()
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
         | Ast.Return { desc = Ast.BinOp (Ast.Sub,
                                 { desc = Ast.IntLit 0L; _ },
                                 { desc = Ast.IntLit 42L; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(BinOp(Sub, IntLit 0, IntLit 42))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- sizeof -------------------------------------------------- *)

  Alcotest.test_case "sizeof(T) parses to SizeOf" `Quick (fun () ->
    match parse "fn f() usize { return sizeof(i32); }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.SizeOf Ast.TypeI32; _ } -> ()
         | _ -> Alcotest.fail "expected Return(SizeOf TypeI32)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "sizeof(StructName) parses to SizeOf TypeNamed" `Quick (fun () ->
    match parse "struct P { x: i32; } fn f() usize { return sizeof(P); }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.SizeOf (Ast.TypeNamed "P"); _ } -> ()
         | _ -> Alcotest.fail "expected Return(SizeOf (TypeNamed P))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "offsetof(T, field) parses to OffsetOf" `Quick (fun () ->
    match parse "struct P { x: u8; y: i32; } fn f() usize { return offsetof(P, y); }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.OffsetOf (Ast.TypeNamed "P", "y"); _ } -> ()
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
         | Ast.Return { desc = Ast.Cast (Ast.TypeU8,
                                 { desc = Ast.Var "n"; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(Cast(TypeChar, Var n))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "as cast to i32" `Quick (fun () ->
    match parse "fn f(c: u8) i32 { return c as i32; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Cast (Ast.TypeI32,
                                 { desc = Ast.Var "c"; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(Cast(TypeInt, Var c))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "as has lower precedence than arithmetic" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) u8 { return a + b as u8; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Cast (Ast.TypeU8,
                                 { desc = Ast.BinOp (Ast.Add, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Cast(TypeChar, BinOp(Add, ...)) -- as must bind looser than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Bitwise operations ------------------------------------------------ *)

  Alcotest.test_case "bitwise AND expression" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n & 15; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Band" Ast.Band op
         | _ -> Alcotest.fail "expected Return(BinOp Band)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "right shift expression" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n >> 4; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Shr" Ast.Shr op
         | _ -> Alcotest.fail "expected Return(BinOp Shr)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case ">> binds tighter than &" `Quick (fun () ->
    (* n >> 4 & 0xf  should parse as  (n >> 4) & 0xf *)
    match parse "fn f(n: i32) i32 { return n >> 4 & 15; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Band,
                                 { desc = Ast.BinOp (Ast.Shr, _, _); _ }, _); _ } -> ()
         | _ -> Alcotest.fail "expected Band(Shr(...), 15) -- >> must bind tighter than &")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "& binds tighter than comparison" `Quick (fun () ->
    (* n & 15 == 0  should parse as  (n & 15) == 0 *)
    match parse "fn f(n: i32) i32 { return n & 15 == 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Eq,
                                 { desc = Ast.BinOp (Ast.Band, _, _); _ }, _); _ } -> ()
         | _ -> Alcotest.fail "expected Eq(Band(...), 0) -- & must bind tighter than ==")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "modulo BinOp" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n % 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Mod" Ast.Mod op
         | _ -> Alcotest.fail "expected Return(BinOp Mod)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "% binds tighter than +" `Quick (fun () ->
    (* a + b % 3  should parse as  a + (b % 3) *)
    match parse "fn f(a: i32, b: i32) i32 { return a + b % 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Add, _,
                                 { desc = Ast.BinOp (Ast.Mod, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Add(a, Mod(b,3)) -- % must bind tighter than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bitwise OR expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a | b; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Bor" Ast.Bor op
         | _ -> Alcotest.fail "expected Return(BinOp Bor)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "| binds looser than ==" `Quick (fun () ->
    (* a == 0 | b == 0  should parse as  (a == 0) | (b == 0) *)
    match parse "fn f(a: i32, b: i32) i32 { return a == 0 | b == 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Bor,
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ },
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Bor(Eq(...),Eq(...)) -- | must bind looser than ==")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "left shift expression" `Quick (fun () ->
    match parse "fn f(n: i32) i32 { return n << 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Shl" Ast.Shl op
         | _ -> Alcotest.fail "expected Return(BinOp Shl)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bitwise XOR expression" `Quick (fun () ->
    match parse "fn f(a: i32, b: i32) i32 { return a ^ b; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Bxor" Ast.Bxor op
         | _ -> Alcotest.fail "expected Return(BinOp Bxor)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "^ binds tighter than |" `Quick (fun () ->
    (* a | b ^ c  should parse as  a | (b ^ c) *)
    match parse "fn f(a: i32, b: i32, c: i32) i32 { return a | b ^ c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Bor, _,
                                 { desc = Ast.BinOp (Ast.Bxor, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Bor(a, Bxor(b,c)) -- ^ must bind tighter than |")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "== binds tighter than ^" `Quick (fun () ->
    (* a ^ b == c  should parse as  a ^ (b == c)  -- same as C *)
    match parse "fn f(a: i32, b: i32, c: i32) i32 { return a ^ b == c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Bxor, _,
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Bxor(a, Eq(b,c)) -- == must bind tighter than ^")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "array write arr[i]=v produces AssignIndex" `Quick (fun () ->
    match parse "fn f(arr: *u8, i: i32) { arr[i] = 'X'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignIndex ("arr",
             { desc = Ast.Var "i"; _ },
             { desc = Ast.IntLit 88L; _ }) -> ()   (* 'X' = 88 *)
         | _ -> Alcotest.fail "expected AssignIndex(arr, Var i, IntLit 88)")
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
         | Ast.Return { desc = Ast.Index ("arr", { desc = Ast.Var "i"; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(Index(arr, Var i))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "arr[i] binds tighter than addition" `Quick (fun () ->
    (* a + arr[i]  should parse as  a + Index(arr,i), not Index(a+arr,i) *)
    match parse "fn f(a: i32, arr: *u8, i: i32) i32 { return a + arr[i]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Add, { desc = Ast.Var "a"; _ },
                                 { desc = Ast.Index ("arr", _); _ }); _ } -> ()
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
         | Ast.Return { desc = Ast.FieldGet ({ desc = Ast.Var "p"; _ }, "x"); _ } -> ()
         | _ -> Alcotest.fail "expected Return(FieldGet(p, x))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "field assignment statement parses to AssignField" `Quick (fun () ->
    match parse "fn f() { p.x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignField ({ desc = Ast.Var "p"; _ }, "x",
                             { desc = Ast.IntLit 5L; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignField(p, x, 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "indexed field assignment parses to AssignField(Index(...))" `Quick (fun () ->
    match parse "fn f(i: i32) { descs[i].value = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignField (
             { desc = Ast.Index ("descs", { desc = Ast.Var "i"; _ }); _ },
             "value", { desc = Ast.IntLit 5L; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignField(Index(descs, i), value, 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "indexed compound field assignment parses" `Quick (fun () ->
    match parse "fn f(i: i32) { descs[i].value += 1; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignField (
             ({ desc = Ast.Index ("descs", _); _ } as base), "value",
             { desc = Ast.BinOp (Ast.Add,
                 { desc = Ast.FieldGet (load_base, "value"); _ },
                 { desc = Ast.IntLit 1L; _ }); _ })
           when base == load_base -> ()
         | _ -> Alcotest.fail "expected indexed AssignField compound desugaring")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "field access binds tighter than addition" `Quick (fun () ->
    (* p.x + p.y should parse as (p.x) + (p.y), not p.(x + p).y *)
    match parse "struct P { x: i32; } fn f(p: *P) -> i32 { return p.x + p.x; }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Add,
               { desc = Ast.FieldGet _; _ },
               { desc = Ast.FieldGet _; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Add(FieldGet, FieldGet)")
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

  Alcotest.test_case "complex pointer assign *(expr) = v parses to AssignDeref" `Quick (fun () ->
    match parse "fn f(arr: *i32, i: i32) { *(arr + i) = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref (
             { desc = Ast.BinOp (Ast.Add, _, _); _ },
             { desc = Ast.IntLit 42L; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(BinOp(Add,...), 42)")
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
         | Ast.Return { desc = Ast.IntLit 42L; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "block comment /* */ is ignored" `Quick (fun () ->
    match parse "fn f() i32 { /* skip this */ return 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 0L; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 0)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "multi-line block comment is ignored" `Quick (fun () ->
    match parse "fn f() i32 {\n  /*\n   * multi\n   * line\n   */\n  return 7;\n}" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 7L; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 7)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Bitwise NOT and compound assignment tests ---------------------- *)

  Alcotest.test_case "bitwise NOT parses to Bnot" `Quick (fun () ->
    match parse "fn f(x: i32) i32 { return ~x; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Bnot { desc = Ast.Var "x"; _ }; _ } -> ()
         | _ -> Alcotest.fail "expected Return(Bnot(Var x))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "compound += desugars to Assign(BinOp(Add))" `Quick (fun () ->
    match parse "fn f() { let mut x = 0; x += 1; }" with
    | [Ast.FuncDef { body = [_let; s]; _ }] ->
        (match s.desc with
         | Ast.Assign ("x", { desc = Ast.BinOp (Ast.Add, { desc = Ast.Var "x"; _ }, _); _ }) -> ()
         | _ -> Alcotest.fail "expected Assign(x, BinOp(Add, Var x, _))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "compound |= desugars to Assign(BinOp(Bor))" `Quick (fun () ->
    match parse "fn f() { let mut x = 0; x |= 2; }" with
    | [Ast.FuncDef { body = [_let; s]; _ }] ->
        (match s.desc with
         | Ast.Assign ("x", { desc = Ast.BinOp (Ast.Bor, { desc = Ast.Var "x"; _ }, _); _ }) -> ()
         | _ -> Alcotest.fail "expected Assign(x, BinOp(Bor, Var x, _))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "compound &= on deref desugars to AssignDeref(BinOp(Band))" `Quick (fun () ->
    match parse "fn f(p: *i32) { *p &= 0xff; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref (_, { desc = Ast.BinOp (Ast.Band, { desc = Ast.Deref _; _ }, _); _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(_, BinOp(Band, Deref _, _))")
    | _ -> Alcotest.fail "unexpected structure"
  );

]

(* -- Type inference tests -------------------------------------------------- *)

let infer_tests = [
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
                fn f(idx: usize) {
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

  (* Negative control: casting a non-literal integer to an ORDINARY
     (non-affine) pointer stays legal -- this is the real driver pattern
     (a runtime-discovered MMIO base address, offset and cast to a plain
     `*io T`) the affine-only scoping exists to preserve. *)
  Alcotest.test_case "casting a non-literal integer to a non-affine pointer needs no unsafe" `Quick
    (expect_ok "fn f(base: usize, offset: usize) { let p: *io u32 = (base + offset) as *io u32; }");

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
    (expect_ok "fn f(p: *u8) -> *align(32) u8 { return unsafe { p as *align(32) u8 }; }");

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

  Alcotest.test_case "borrow is rejected for ordinary parameter types" `Quick
    (expect_type_error "borrow is only valid"
       "fn bad(x: borrow *u8) {}");

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
       "fn f(p: *u8, lo: isize, hi: isize) -> []u8 {
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

  Alcotest.test_case "TRefinedInt result is subtype of i32 return" `Quick
    (expect_ok "fn f(i: {0..<7 as i32}) -> i32 { return i + 1; }");

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
    (expect_ok "let QUEUE_SIZE: i32 = 4;
                let mut ring: [u8; QUEUE_SIZE];
                fn f() { ring[3] = 1; }");

  Alcotest.test_case "array size via named constant still bounds-checks" `Quick
    (expect_type_error "out of bounds"
       "let QUEUE_SIZE: i32 = 4;
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

  Alcotest.test_case "linear: storing through a pointer is a compile error" `Quick
    (expect_type_error "cannot store a linear value through a pointer"
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

  Alcotest.test_case "Slice 3: a concrete struct payload is rejected before codegen" `Quick
    (expect_type_error "aggregate payload ownership is not implemented"
       "struct VariantPair7b { left: i32; right: i32; }
        variant VariantStruct7b { None; Pair(VariantPair7b); }");

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

]

(* -- Codegen tests ----------------------------------------------------------
   parser/type_inf tests check the AST/type layer; these additionally run
   real LLVM codegen and its verifier, catching bugs that only manifest as
   invalid IR (mismatched operand types, missing terminators, etc.) rather
   than a type error. Kept small and targeted rather than broad: this is a
   regression suite for specific past codegen bugs, not a general codegen
   test bed (that role is filled by examples/ + make qemutest, which also
   checks runtime behavior, not just "the IR verifies"). *)

let codegen_tests = [
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
       "let FTRAP_SIZE: usize = 4;
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
       "let FTRAP_N: i32 = 4;
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

  Alcotest.test_case
    "constant subslice: s[2..<6] of [u8; 8..] yields [u8; 4..]; index 3 \
     within it is proven (zero sites)" `Quick
    (expect_trap_sites 0
       "fn ftsl_subslice(s: [u8; 8..]) -> u8 {
          let m = s[2..<6];
          return m[3];
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
         "fn ftsl_from_ptr(p: *u8) -> u8 {
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
       "let RX_BUF_SIZE: usize = 1536;
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
         "fn cache_ops(p: *align(32) u8, n: usize) {
            dma_prepare_tx(p, n);
            dma_prepare_rx(p, n);
            dma_finish_rx(p, n);
          }" ();
       expect_type_error "raw pointer"
         "fn bad_cache_ptr(n: usize) { dma_prepare_tx(n, n); }" ();
       expect_type_error "cannot unify"
         "fn bad_cache_len(p: *align(32) u8, n: i32) { dma_finish_rx(p, n); }" ());

  Alcotest.test_case "dma_finish_rx rejects an unproven pointer, dma_prepare_tx accepts it" `Quick
    (fun () ->
       expect_type_error "cannot pass unproven"
         "fn f(p: *u8) { dma_finish_rx(p, 512); }" ();
       expect_ok "fn f(p: *u8) { dma_prepare_tx(p, 512); }" ());

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
        fn ftp4c1_unsafe_slice(pkt: [u8; 40..], raw_ihl: usize, tcp_len: usize) -> i32 {
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
       let ir = Llvm.string_of_llmodule Llvm_gen.the_module in
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

  (* Companion to the test above, covering the parts of ditype_of_ast
     (lib/llvm_gen.ml) that one only exercises with a pointer-to-struct
     parameter, a struct-typed local, and an array-typed local: the i32
     params/locals in the previous test never touch the TypePtr / TypeNamed
     / TypeArray branches at all. Also a self-referential struct (a node
     pointing at its own type) -- this is precisely the shape ditype_of_ast
     is built to never recurse into (structs always resolve to a memberless
     forward declaration, regardless of whether reached directly or through
     a pointer), so this is the regression test for that specific
     "must not hang/crash on self-reference" guarantee, not just "it
     verifies". Also exercises the di_struct_placeholders cache: DwarfNode
     is named twice (once via the pointer parameter, once via the direct
     local), which must resolve to the same cached forward-decl rather than
     create a duplicate metadata node each time. *)
  Alcotest.test_case
    "DWARF debug info (-g): pointer-to-struct parameter, struct-typed local, \
     and array-typed local all produce verifier-accepted IR, including a \
     self-referential struct type (regression coverage for ditype_of_ast's \
     struct-as-forward-declaration design)" `Quick
    (expect_codegen_ok
       "struct DwarfNode {
          value: i32;
          next: *DwarfNode;
        }

        fn codegen_debug_info_struct_ptr(n: *DwarfNode) -> i32 {
          let mut node: DwarfNode;
          let mut arr: [i32; 4];
          node.value = n.value;
          arr[0] = node.value;
          return arr[0];
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
     payload-binding match produce verifier-accepted IR even though Slice 3 \
     deliberately defers source-level tagged-union DIType metadata"
    `Quick
    (expect_codegen_ok
       "variant DwarfVariantResult {
          Empty;
          Value(i32);
        }

        fn codegen_debug_info_variant(input: DwarfVariantResult) -> i32 {
          let current: DwarfVariantResult = input;
          match current {
            DwarfVariantResult::Empty => { return 0; }
            DwarfVariantResult::Value(value) => { return value; }
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
     Llvm_gen.the_module's target triple/data layout (Llvm_gen.target_data)
     for the rest of this test process -- there is no way to reset back to
     "no target machine". Every codegen test registered above this point
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
       let gv = match Llvm.lookup_global "GLOBAL_ENUM_STATE" Llvm_gen.the_module with
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
       let gv = match Llvm.lookup_global "GLOBAL_ENUM_CODE" Llvm_gen.the_module with
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

let () = Alcotest.run "takibi" [
  "core",     core_tests;
  "parser",   parser_tests;
  "type_inf", infer_tests;
  "use_resolver", use_resolver_tests;
  "codegen",  codegen_tests;
]
