open Takibi

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let parse src =
  let lexbuf = Lexing.from_string src in
  Parser.program Lexer.read lexbuf

let infer src =
  Type_inf.infer_program (parse src)

(* Custom Alcotest testables *)

let rec show_type = function
  | Ast.TypeInt   -> "int"
  | Ast.TypeChar  -> "char"
  | Ast.TypeVoid  -> "void"
  | Ast.TypePtr t -> "*" ^ show_type t

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

(* Expect inference to succeed *)
let expect_ok src () =
  match infer src with
  | _ -> ()
  | exception Types.TypeError (_, msg) ->
      Alcotest.failf "unexpected TypeError: %s" msg

(* ── Parser tests ────────────────────────────────────────────────────────── *)

let parser_tests = [

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
    match parse "fn add(a: int, b: int) int { return a; }" with
    | [Ast.FuncDef f] ->
        Alcotest.(check string) "name" "add" f.name;
        Alcotest.(check int)    "param count" 2 (List.length f.params);
        let (n0, t0) = List.nth f.params 0 in
        let (n1, t1) = List.nth f.params 1 in
        Alcotest.(check string)        "param0 name" "a"   n0;
        Alcotest.(check (option type_t)) "param0 type" (Some Ast.TypeInt) t0;
        Alcotest.(check string)        "param1 name" "b"   n1;
        Alcotest.(check (option type_t)) "param1 type" (Some Ast.TypeInt) t1;
        Alcotest.(check (option type_t)) "ret type" (Some Ast.TypeInt) f.ret_type;
        Alcotest.(check int)    "body length" 1 (List.length f.body)
    | _ -> Alcotest.fail "expected single FuncDef"
  );

  Alcotest.test_case "global let without type" `Quick (fun () ->
    match parse "let x = 1;" with
    | [Ast.LetDef (name, ty, init)] ->
        Alcotest.(check string)        "name"    "x"   name;
        Alcotest.(check (option type_t)) "type"    None  ty;
        (match init with
         | Some { Ast.desc = Ast.IntLit 1; _ } -> ()
         | _ -> Alcotest.fail "expected IntLit 1")
    | _ -> Alcotest.fail "expected single LetDef"
  );

  Alcotest.test_case "global let with type annotation" `Quick (fun () ->
    match parse "let g: char = 0;" with
    | [Ast.LetDef (name, ty, _)] ->
        Alcotest.(check string)        "name" "g" name;
        Alcotest.(check (option type_t)) "type" (Some Ast.TypeChar) ty
    | _ -> Alcotest.fail "expected single LetDef"
  );

  Alcotest.test_case "return statement" `Quick (fun () ->
    match parse "fn f() int { return 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 42; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "let statement with initializer" `Quick (fun () ->
    match parse "fn f() { let x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let ("x", None, Some { desc = Ast.IntLit 5; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(x, None, IntLit 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "assign statement" `Quick (fun () ->
    match parse "fn f() { x = 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Assign ("x", { desc = Ast.IntLit 3; _ }) -> ()
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

  Alcotest.test_case "arithmetic BinOp" `Quick (fun () ->
    match parse "fn f() int { return 1 + 2 * 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "outer op is Add" Ast.Add op
         | _ -> Alcotest.fail "expected Return(BinOp)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "comparison BinOp" `Quick (fun () ->
    match parse "fn f() int { return 1 != 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Ne" Ast.Ne op
         | _ -> Alcotest.fail "expected Return(BinOp)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "function call expression" `Quick (fun () ->
    match parse "fn f() int { return g(1, 2); }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Call ("g", args); _ } ->
             Alcotest.(check int) "arg count" 2 (List.length args)
         | _ -> Alcotest.fail "expected Return(Call)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "multiple top-level items" `Quick (fun () ->
    let prog = parse "let x = 0; fn f() {} fn g() int { return 1; }" in
    Alcotest.(check int) "item count" 3 (List.length prog);
    (match List.nth prog 0 with
     | Ast.LetDef ("x", _, _) -> ()
     | _ -> Alcotest.fail "first item should be LetDef x");
    (match List.nth prog 1 with
     | Ast.FuncDef { name = "f"; _ } -> ()
     | _ -> Alcotest.fail "second item should be FuncDef f")
  );

  (* ── Pointer / address-of tests ────────────────────────────── *)

  Alcotest.test_case "pointer type in function param" `Quick (fun () ->
    match parse "fn f(p: *int) {}" with
    | [Ast.FuncDef { params = [(_, Some t)]; _ }] ->
        Alcotest.check type_t "param type is *int" (Ast.TypePtr Ast.TypeInt) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "pointer-to-pointer type" `Quick (fun () ->
    match parse "fn f(p: **int) {}" with
    | [Ast.FuncDef { params = [(_, Some t)]; _ }] ->
        Alcotest.check type_t "param type is **int"
          (Ast.TypePtr (Ast.TypePtr Ast.TypeInt)) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "deref expression" `Quick (fun () ->
    match parse "fn f(p: *int) int { return *p; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Deref { desc = Ast.Var "p"; _ }; _ } -> ()
         | _ -> Alcotest.fail "expected Return(Deref(Var p))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "addrof expression" `Quick (fun () ->
    match parse "fn f() { let x = 0; let p = &x; }" with
    | [Ast.FuncDef { body = [_; s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, Some { desc = Ast.AddrOf "x"; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(p, AddrOf x)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "assign through pointer" `Quick (fun () ->
    match parse "fn f(p: *int) { *p = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref ({ desc = Ast.Var "p"; _ },
                             { desc = Ast.IntLit 42; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(Var p, IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "hex integer literal" `Quick (fun () ->
    match parse "fn f() int { return 0xff; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 255; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 255)")
    | _ -> Alcotest.fail "unexpected structure"
  );

]

(* ── Type inference tests ────────────────────────────────────────────────── *)

let infer_tests = [

  (* ── 成功ケース ─────────────────────────────────────────────── *)

  Alcotest.test_case "fully annotated function passes" `Quick
    (expect_ok "fn add(a: int, b: int) int { return a; }");

  Alcotest.test_case "infer local let from literal" `Quick (fun () ->
    let pt = infer "fn f() int { let x = 1; return x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "x inferred as int" Ast.TypeInt
      (Types.StringMap.find "x" fi.Types.local_types)
  );

  Alcotest.test_case "char annotation on global let" `Quick (fun () ->
    let pt = infer "let g: char = 0;" in
    Alcotest.check type_t "g is char" Ast.TypeChar
      (Types.StringMap.find "g" pt.Types.globals)
  );

  Alcotest.test_case "annotated return type preserved" `Quick (fun () ->
    let pt = infer "fn f() int { return 1; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is int" Ast.TypeInt fi.Types.ret_type
  );

  Alcotest.test_case "infer param type used in arithmetic" `Quick (fun () ->
    let pt = infer "fn f(a: int, b: int) int { return a + b; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "a: int" Ast.TypeInt
      (List.assoc "a" fi.Types.param_types);
    Alcotest.check type_t "b: int" Ast.TypeInt
      (List.assoc "b" fi.Types.param_types)
  );

  Alcotest.test_case "cross-function call type-checks" `Quick
    (expect_ok "fn id(x: int) int { return x; }
                fn caller() int { return id(5); }");

  Alcotest.test_case "global let used inside function" `Quick
    (expect_ok "let g = 1; fn f() int { return g; }");

  Alcotest.test_case "comparison result used in while" `Quick
    (expect_ok "fn f() int { let r = 0;
                               while (r != 0) { r = 1; }
                               return r; }");

  Alcotest.test_case "if/else branches both valid" `Quick
    (expect_ok "fn abs(x: int) int {
                  if (x > 0) { return x; } else { return 0; } }");

  (* ── エラーケース ───────────────────────────────────────────── *)

  Alcotest.test_case "undefined variable" `Quick
    (expect_type_error "Unbound variable"
       "fn f() int { return z; }");

  Alcotest.test_case "undefined function" `Quick
    (expect_type_error "Undefined function"
       "fn f() int { return noexist(1); }");

  Alcotest.test_case "too many arguments" `Quick
    (expect_type_error "expects 1 argument"
       "fn id(x: int) int { return x; }
        fn f() int { return id(1, 2); }");

  Alcotest.test_case "too few arguments" `Quick
    (expect_type_error "expects 2 argument"
       "fn add(a: int, b: int) int { return a; }
        fn f() int { return add(1); }");

  Alcotest.test_case "arithmetic operand type mismatch" `Quick
    (expect_type_error "cannot unify"
       "fn f(a: int, b: char) int { return a + b; }");

  (* ── ポインタ型推論 ──────────────────────────────────────── *)

  Alcotest.test_case "local pointer annotation type-checks" `Quick
    (expect_ok "fn f() { let p: *int = 0x09000000; *p = 1; }");

  Alcotest.test_case "deref yields element type" `Quick (fun () ->
    let pt = infer "fn f(p: *int) int { return *p; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is int" Ast.TypeInt fi.Types.ret_type
  );

  Alcotest.test_case "addrof yields pointer type" `Quick (fun () ->
    let pt = infer "fn f() { let x: int = 0; let p = &x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "p has type *int"
      (Ast.TypePtr Ast.TypeInt)
      (Types.StringMap.find "p" fi.Types.local_types)
  );

  Alcotest.test_case "deref non-pointer is a type error" `Quick
    (expect_type_error "cannot unify"
       "fn f(x: int) { *x = 1; }");

]

(* ── Entry point ─────────────────────────────────────────────────────────── *)

let () = Alcotest.run "takibi" [
  "parser",   parser_tests;
  "type_inf", infer_tests;
]
