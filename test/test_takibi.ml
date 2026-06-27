open Takibi

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let parse src =
  let lexbuf = Lexing.from_string src in
  Parser.program Lexer.read lexbuf

let infer src =
  Type_inf.infer_program (parse src)

(* Custom Alcotest testables *)

let rec show_type = function
  | Ast.TypeInt         -> "int"
  | Ast.TypeChar        -> "char"
  | Ast.TypeVoid        -> "void"
  | Ast.TypePtr t       -> "*" ^ show_type t
  | Ast.TypeIo  t       -> "io " ^ show_type t   (* TypePtr(TypeIo t) → "*io T" 自動合成 *)
  | Ast.TypeArray (t,n) -> Printf.sprintf "[%s; %d]" (show_type t) n
  | Ast.TypeFn (ps, r)  ->
      Printf.sprintf "fn(%s) -> %s"
        (String.concat ", " (List.map show_type ps)) (show_type r)
  | Ast.TypeNamed s     -> s

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

  Alcotest.test_case "let statement (immutable) with initializer" `Quick (fun () ->
    match parse "fn f() { let x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (false, "x", None, Some { desc = Ast.IntLit 5; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(false, x, None, IntLit 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "let mut statement (mutable) with initializer" `Quick (fun () ->
    match parse "fn f() { let mut x = 5; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "x", None, Some { desc = Ast.IntLit 5; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(true, x, None, IntLit 5)")
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

  Alcotest.test_case "*io int param type parses" `Quick (fun () ->
    match parse "fn f(p: *io int) {}" with
    | [Ast.FuncDef { params = [(_, Some t)]; _ }] ->
        Alcotest.check type_t "param type is *io int"
          (Ast.TypePtr (Ast.TypeIo Ast.TypeInt)) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bare io type in global let parses" `Quick (fun () ->
    match parse "let flag: io int;" with
    | [Ast.LetDef (_, Some t, None)] ->
        Alcotest.check type_t "type is io int" (Ast.TypeIo Ast.TypeInt) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "io type in struct field parses" `Quick (fun () ->
    match parse "struct S { done: io int; }" with
    | [Ast.StructDef (_, [(_, t)])] ->
        Alcotest.check type_t "field type is io int" (Ast.TypeIo Ast.TypeInt) t
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

  Alcotest.test_case "addrof expression (let mut required)" `Quick (fun () ->
    match parse "fn f() { let mut x = 0; let p = &x; }" with
    | [Ast.FuncDef { body = [_; s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.AddrOf { desc = Ast.Var "x"; _ }; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(_, AddrOf x)")
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

  Alcotest.test_case "char literal becomes IntLit" `Quick (fun () ->
    match parse "fn f() int { return 'A'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 65; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 65)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "char escape literals" `Quick (fun () ->
    match parse "fn f() { let a = '\\n'; let b = '\\r'; let c = '\\0'; }" with
    | [Ast.FuncDef { body = [s1; s2; s3]; _ }] ->
        let check name expected s =
          match s.Ast.desc with
          | Ast.Let (_, _, _, Some { desc = Ast.IntLit n; _ }) ->
              Alcotest.(check int) name expected n
          | _ -> Alcotest.failf "%s: expected Let with IntLit" name
        in
        check "\\n" 10 s1; check "\\r" 13 s2; check "\\0" 0 s3
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "logical OR expression" `Quick (fun () ->
    match parse "fn f(a: int, b: int) int { return a == 1 || b == 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "outer op is Or" Ast.Or op
         | _ -> Alcotest.fail "expected Return(BinOp Or)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "if without else" `Quick (fun () ->
    match parse "fn f(x: int) { if (x == 0) { x = 1; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.If (_, [_], []) -> ()
         | _ -> Alcotest.fail "expected If with empty else")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "else if chain" `Quick (fun () ->
    match parse "fn f(x: int) int {
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

  (* ── 単項マイナス ───────────────────────────────────────────── *)

  Alcotest.test_case "unary minus desugars to Sub from zero" `Quick (fun () ->
    match parse "fn f() int { return -42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Sub,
                                 { desc = Ast.IntLit 0; _ },
                                 { desc = Ast.IntLit 42; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(BinOp(Sub, IntLit 0, IntLit 42))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── as キャスト ─────────────────────────────────────────────── *)

  Alcotest.test_case "as cast to char" `Quick (fun () ->
    match parse "fn f(n: int) char { return n as char; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Cast (Ast.TypeChar,
                                 { desc = Ast.Var "n"; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(Cast(TypeChar, Var n))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "as cast to int" `Quick (fun () ->
    match parse "fn f(c: char) int { return c as int; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Cast (Ast.TypeInt,
                                 { desc = Ast.Var "c"; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(Cast(TypeInt, Var c))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "as has lower precedence than arithmetic" `Quick (fun () ->
    match parse "fn f(a: int, b: int) char { return a + b as char; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Cast (Ast.TypeChar,
                                 { desc = Ast.BinOp (Ast.Add, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Cast(TypeChar, BinOp(Add, ...)) — as must bind looser than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── ビット演算 ──────────────────────────────────────────────── *)

  Alcotest.test_case "bitwise AND expression" `Quick (fun () ->
    match parse "fn f(n: int) int { return n & 15; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Band" Ast.Band op
         | _ -> Alcotest.fail "expected Return(BinOp Band)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "right shift expression" `Quick (fun () ->
    match parse "fn f(n: int) int { return n >> 4; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Shr" Ast.Shr op
         | _ -> Alcotest.fail "expected Return(BinOp Shr)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case ">> binds tighter than &" `Quick (fun () ->
    (* n >> 4 & 0xf  should parse as  (n >> 4) & 0xf *)
    match parse "fn f(n: int) int { return n >> 4 & 15; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Band,
                                 { desc = Ast.BinOp (Ast.Shr, _, _); _ }, _); _ } -> ()
         | _ -> Alcotest.fail "expected Band(Shr(...), 15) — >> must bind tighter than &")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "& binds tighter than comparison" `Quick (fun () ->
    (* n & 15 == 0  should parse as  (n & 15) == 0 *)
    match parse "fn f(n: int) int { return n & 15 == 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Eq,
                                 { desc = Ast.BinOp (Ast.Band, _, _); _ }, _); _ } -> ()
         | _ -> Alcotest.fail "expected Eq(Band(...), 0) — & must bind tighter than ==")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "modulo BinOp" `Quick (fun () ->
    match parse "fn f(n: int) int { return n % 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Mod" Ast.Mod op
         | _ -> Alcotest.fail "expected Return(BinOp Mod)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "% binds tighter than +" `Quick (fun () ->
    (* a + b % 3  should parse as  a + (b % 3) *)
    match parse "fn f(a: int, b: int) int { return a + b % 3; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Add, _,
                                 { desc = Ast.BinOp (Ast.Mod, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Add(a, Mod(b,3)) — % must bind tighter than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bitwise OR expression" `Quick (fun () ->
    match parse "fn f(a: int, b: int) int { return a | b; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Bor" Ast.Bor op
         | _ -> Alcotest.fail "expected Return(BinOp Bor)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "| binds looser than ==" `Quick (fun () ->
    (* a == 0 | b == 0  should parse as  (a == 0) | (b == 0) *)
    match parse "fn f(a: int, b: int) int { return a == 0 | b == 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Bor,
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ },
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Bor(Eq(...),Eq(...)) — | must bind looser than ==")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "left shift expression" `Quick (fun () ->
    match parse "fn f(n: int) int { return n << 2; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Shl" Ast.Shl op
         | _ -> Alcotest.fail "expected Return(BinOp Shl)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "bitwise XOR expression" `Quick (fun () ->
    match parse "fn f(a: int, b: int) int { return a ^ b; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (op, _, _); _ } ->
             Alcotest.check binop_t "op is Bxor" Ast.Bxor op
         | _ -> Alcotest.fail "expected Return(BinOp Bxor)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "^ binds tighter than |" `Quick (fun () ->
    (* a | b ^ c  should parse as  a | (b ^ c) *)
    match parse "fn f(a: int, b: int, c: int) int { return a | b ^ c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Bor, _,
                                 { desc = Ast.BinOp (Ast.Bxor, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Bor(a, Bxor(b,c)) — ^ must bind tighter than |")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "== binds tighter than ^" `Quick (fun () ->
    (* a ^ b == c  should parse as  a ^ (b == c)  — same as C *)
    match parse "fn f(a: int, b: int, c: int) int { return a ^ b == c; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Bxor, _,
                                 { desc = Ast.BinOp (Ast.Eq, _, _); _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Bxor(a, Eq(b,c)) — == must bind tighter than ^")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "array write arr[i]=v desugars to AssignDeref" `Quick (fun () ->
    match parse "fn f(arr: *char, i: int) { arr[i] = 'X'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref (
             { desc = Ast.BinOp (Ast.Add,
                 { desc = Ast.Var "arr"; _ },
                 { desc = Ast.Var "i"; _ }); _ },
             { desc = Ast.IntLit 88; _ }) -> ()   (* 'X' = 88 *)
         | _ -> Alcotest.fail "expected AssignDeref(BinOp(Add,arr,i), 'X')")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── 配列 ────────────────────────────────────────────────────── *)

  Alcotest.test_case "array type annotation parses" `Quick (fun () ->
    match parse "fn f() { let mut buf: [char; 8]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "buf", Some (Ast.TypeArray (Ast.TypeChar, 8)), None) -> ()
         | _ -> Alcotest.fail "expected Let(mut, buf, TypeArray(char,8), None)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "array indexing desugars to Deref(Add(arr,idx))" `Quick (fun () ->
    match parse "fn f(arr: *char, i: int) char { return arr[i]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.Deref
             { desc = Ast.BinOp (Ast.Add,
                 { desc = Ast.Var "arr"; _ },
                 { desc = Ast.Var "i"; _ }); _ }; _ } -> ()
         | _ -> Alcotest.fail "expected Return(Deref(BinOp(Add, arr, i)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "arr[i] binds tighter than addition" `Quick (fun () ->
    (* a + arr[i]  should parse as  a + deref(arr+i), not deref(a+arr)[i] *)
    match parse "fn f(a: int, arr: *char, i: int) int { return a + arr[i]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Add, { desc = Ast.Var "a"; _ },
                                 { desc = Ast.Deref _; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Add(a, Deref(...)) — [] must bind tighter than +")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── 関数ポインタ型 ──────────────────────────────────────────── *)

  Alcotest.test_case "fn pointer type with no args parses" `Quick (fun () ->
    match parse "fn f(h: fn() -> void) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([], Ast.TypeVoid)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn() -> void"
  );

  Alcotest.test_case "fn pointer type with one arg parses" `Quick (fun () ->
    match parse "fn f(h: fn(int) -> char) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([Ast.TypeInt], Ast.TypeChar)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn(int) -> char"
  );

  Alcotest.test_case "fn pointer type with multiple args parses" `Quick (fun () ->
    match parse "fn f(h: fn(int, char) -> int) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([Ast.TypeInt; Ast.TypeChar], Ast.TypeInt)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn(int, char) -> int"
  );

  Alcotest.test_case "let variable with fn pointer type annotation parses" `Quick (fun () ->
    match parse "fn foo() {} fn f() { let h: fn() -> void = foo; }" with
    | [Ast.FuncDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (false, "h", Some (Ast.TypeFn ([], Ast.TypeVoid)), Some _) -> ()
         | _ -> Alcotest.fail "expected Let(h, TypeFn([], void), Some(foo))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── 構造体構文 ──────────────────────────────────────────────── *)

  Alcotest.test_case "struct definition parses" `Quick (fun () ->
    match parse "struct Point { x: int; y: int; }" with
    | [Ast.StructDef ("Point", fields)] ->
        Alcotest.(check int) "field count" 2 (List.length fields);
        let (n0, t0) = List.nth fields 0 in
        let (n1, t1) = List.nth fields 1 in
        Alcotest.(check string) "field0 name" "x" n0;
        Alcotest.(check type_t) "field0 type" Ast.TypeInt t0;
        Alcotest.(check string) "field1 name" "y" n1;
        Alcotest.(check type_t) "field1 type" Ast.TypeInt t1
    | _ -> Alcotest.fail "expected StructDef(Point, [x:int; y:int])"
  );

  Alcotest.test_case "struct type in function param parses" `Quick (fun () ->
    match parse "struct P { x: int; } fn f(p: *P) -> int { return p.x; }" with
    | [Ast.StructDef _; Ast.FuncDef { params = [("p", Some (Ast.TypePtr (Ast.TypeNamed "P")))]; _ }] -> ()
    | _ -> Alcotest.fail "expected *P param type"
  );

  Alcotest.test_case "field access expression parses to FieldGet" `Quick (fun () ->
    match parse "struct P { x: int; } fn f(p: *P) -> int { return p.x; }" with
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
                             { desc = Ast.IntLit 5; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignField(p, x, 5)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "field access binds tighter than addition" `Quick (fun () ->
    (* p.x + p.y should parse as (p.x) + (p.y), not p.(x + p).y *)
    match parse "struct P { x: int; } fn f(p: *P) -> int { return p.x + p.x; }" with
    | [Ast.StructDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.BinOp (Ast.Add,
               { desc = Ast.FieldGet _; _ },
               { desc = Ast.FieldGet _; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Add(FieldGet, FieldGet)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── extern fn ─────────────────────────────────────────────────── *)

  Alcotest.test_case "extern fn without return type parses" `Quick (fun () ->
    match parse "extern fn uart_putc(c: char);" with
    | [Ast.ExternFuncDef ("uart_putc", [("c", Some Ast.TypeChar)], None)] -> ()
    | _ -> Alcotest.fail "expected ExternFuncDef(uart_putc, [c:char], None)"
  );

  Alcotest.test_case "extern fn with return type parses" `Quick (fun () ->
    match parse "extern fn uart_getc() -> char;" with
    | [Ast.ExternFuncDef ("uart_getc", [], Some Ast.TypeChar)] -> ()
    | _ -> Alcotest.fail "expected ExternFuncDef(uart_getc, [], Some char)"
  );

  (* ── 文字列リテラル ──────────────────────────────────────────── *)

  Alcotest.test_case "string literal parses to StringLit" `Quick (fun () ->
    match parse "fn f() { let s = \"hello\"; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.StringLit "hello"; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(_, StringLit \"hello\")")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── -> 戻り値型構文 ─────────────────────────────────────────── *)

  Alcotest.test_case "arrow return type syntax -> int parses" `Quick (fun () ->
    match parse "fn f() -> int { return 0; }" with
    | [Ast.FuncDef { ret_type = Some Ast.TypeInt; _ }] -> ()
    | _ -> Alcotest.fail "expected ret_type = Some TypeInt"
  );

  (* ── 構造体リテラル ──────────────────────────────────────────── *)

  Alcotest.test_case "struct literal { e, e } parses to StructLit" `Quick (fun () ->
    match parse "fn f() { let mut p: P = {1, 2}; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "p", Some (Ast.TypeNamed "P"),
                    Some { desc = Ast.StructLit [_; _]; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(mut, p, TypeNamed P, StructLit [_, _])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── 複合ポインタ代入 ────────────────────────────────────────── *)

  Alcotest.test_case "complex pointer assign *(expr) = v parses to AssignDeref" `Quick (fun () ->
    match parse "fn f(arr: *int, i: int) { *(arr + i) = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref (
             { desc = Ast.BinOp (Ast.Add, _, _); _ },
             { desc = Ast.IntLit 42; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(BinOp(Add,...), 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── 構造体フィールドのアドレス取得 ─────────────────────────── *)

  Alcotest.test_case "addrof struct field parses to AddrOf(FieldGet)" `Quick (fun () ->
    match parse "fn f() { let q = &p.x; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.AddrOf
             { desc = Ast.FieldGet _; _ }; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(_, AddrOf(FieldGet(...)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── 残りエスケープ文字 ──────────────────────────────────────── *)

  Alcotest.test_case "tab escape char literal '\\t'" `Quick (fun () ->
    match parse "fn f() { let t = '\\t'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.IntLit 9; _ }) -> ()
         | _ -> Alcotest.fail "expected IntLit 9 (tab = ASCII 9)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "backslash escape char literal '\\\\'" `Quick (fun () ->
    match parse "fn f() { let bs = '\\\\'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.IntLit 92; _ }) -> ()
         | _ -> Alcotest.fail "expected IntLit 92 (backslash = ASCII 92)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── ブロック文 ──────────────────────────────────────────────── *)

  Alcotest.test_case "block statement parses to Block" `Quick (fun () ->
    match parse "fn f() { { let x = 1; } }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Block [_] -> ()
         | _ -> Alcotest.fail "expected Block([Let ...])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* ── コメント ────────────────────────────────────────────────── *)

  Alcotest.test_case "line comment // is ignored" `Quick (fun () ->
    match parse "// this is a comment\nfn f() int { return 1; }" with
    | [Ast.FuncDef { name = "f"; _ }] -> ()
    | _ -> Alcotest.fail "expected single FuncDef f"
  );

  Alcotest.test_case "inline line comment after code" `Quick (fun () ->
    match parse "fn f() int { return 42; // answer\n}" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 42; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "block comment /* */ is ignored" `Quick (fun () ->
    match parse "fn f() int { /* skip this */ return 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 0; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 0)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "multi-line block comment is ignored" `Quick (fun () ->
    match parse "fn f() int {\n  /*\n   * multi\n   * line\n   */\n  return 7;\n}" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 7; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 7)")
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

  Alcotest.test_case "let mut in while loop" `Quick
    (expect_ok "fn f() int { let mut r = 0;
                              while (r != 0) { r = 1; }
                              return r; }");

  Alcotest.test_case "logical OR of two comparisons" `Quick
    (expect_ok "fn f(x: int) int { return x == 1 || x == 2; }");

  Alcotest.test_case "logical OR type error: char operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(a: int, b: char) int { return a == 1 || b; }");

  Alcotest.test_case "if/else branches both valid" `Quick
    (expect_ok "fn abs(x: int) int {
                  if (x > 0) { return x; } else { return 0; } }");

  (* ── 不変性チェック ─────────────────────────────────────────── *)

  Alcotest.test_case "assign to immutable variable is a type error" `Quick
    (expect_type_error "cannot assign to immutable"
       "fn f() { let x = 0; x = 1; }");

  Alcotest.test_case "let mut allows reassignment" `Quick
    (expect_ok "fn f() { let mut x = 0; x = 1; }");

  Alcotest.test_case "addrof immutable variable is a type error" `Quick
    (expect_type_error "cannot take address of immutable"
       "fn f() { let x = 0; let p = &x; }");

  Alcotest.test_case "addrof mutable variable succeeds" `Quick
    (expect_ok "fn f() { let mut x: int = 0; let p = &x; }");

  Alcotest.test_case "immutable let without initializer is a type error" `Quick
    (expect_type_error "must have an initializer"
       "fn f() { let x: int; }");

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
    let pt = infer "fn f() { let mut x: int = 0; let p = &x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "p has type *int"
      (Ast.TypePtr Ast.TypeInt)
      (Types.StringMap.find "p" fi.Types.local_types)
  );

  (* ── io 修飾型の型推論 ──────────────────────────────────────────── *)

  Alcotest.test_case "deref *io int param yields int" `Quick (fun () ->
    let pt = infer "fn f(p: *io int) int { return *p; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is int" Ast.TypeInt fi.Types.ret_type
  );

  Alcotest.test_case "addrof io int global yields *io int" `Quick (fun () ->
    let pt = infer "let flag: io int;\nfn f() { let p: *io int = &flag; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "p has type *io int"
      (Ast.TypePtr (Ast.TypeIo Ast.TypeInt))
      (Types.StringMap.find "p" fi.Types.local_types)
  );

  Alcotest.test_case "assign int to io int global type-checks" `Quick
    (expect_ok "let flag: io int;\nfn f() { flag = 1; }");

  Alcotest.test_case "io int global in comparison type-checks" `Quick
    (expect_ok "let flag: io int;\nfn f() int { if (flag == 0) { return 1; } return 0; }");

  Alcotest.test_case "io int struct field type-checks" `Quick
    (expect_ok "struct S { done: io int; }\nlet s: S;\nfn f() { s.done = 1; }");

  Alcotest.test_case "deref non-pointer is a type error" `Quick
    (expect_type_error "cannot unify"
       "fn f(x: int) { *x = 1; }");

  Alcotest.test_case "write through immutable pointer variable is allowed" `Quick
    (expect_ok "fn f() { let p: *int = 0x09000000; *p = 1; }");

  (* ── 単項マイナス ───────────────────────────────────────────── *)

  Alcotest.test_case "unary minus type-checks" `Quick
    (expect_ok "fn f(n: int) int { return -n; }");

  (* ── as キャスト ─────────────────────────────────────────────── *)

  Alcotest.test_case "as cast int to char passes" `Quick
    (expect_ok "fn f(n: int) char { return n as char; }");

  Alcotest.test_case "as cast char to int passes" `Quick
    (expect_ok "fn f(c: char) int { return c as int; }");

  Alcotest.test_case "as cast result type is the target type" `Quick (fun () ->
    let pt = infer "fn f(n: int) char { return n as char; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is char" Ast.TypeChar fi.Types.ret_type
  );

  Alcotest.test_case "as cast pointer to int passes" `Quick
    (expect_ok "fn f(p: *int) int { return p as int; }");

  Alcotest.test_case "as cast pointer to pointer passes" `Quick
    (expect_ok "fn f(p: *char) int { let q: *int = p as *int; return 0; }");

  (* ── ビット演算 ──────────────────────────────────────────────── *)

  Alcotest.test_case "bitwise AND type-checks" `Quick
    (expect_ok "fn f(n: int) int { return n & 15; }");

  Alcotest.test_case "right shift type-checks" `Quick
    (expect_ok "fn f(n: int) int { return n >> 4; }");

  Alcotest.test_case "bitwise AND type error: non-int operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(n: int, p: *int) int { return n & p; }");

  Alcotest.test_case "bitwise XOR type-checks" `Quick
    (expect_ok "fn f(a: int, b: int) int { return a ^ b; }");

  Alcotest.test_case "bitwise XOR type error: non-int operand" `Quick
    (expect_type_error "cannot unify"
       "fn f(n: int, p: *int) int { return n ^ p; }");

  (* ── 配列 ────────────────────────────────────────────────────── *)

  Alcotest.test_case "array declaration type-checks" `Quick
    (expect_ok "fn f() { let mut buf: [char; 8]; }");

  Alcotest.test_case "array write via pointer arith type-checks" `Quick
    (expect_ok "fn f() { let mut buf: [char; 8]; *(buf + 0) = 'A'; }");

  Alcotest.test_case "pointer subtraction ptr - int type-checks" `Quick
    (expect_ok "fn f(p: *char) *char { return p - 8; }");

  Alcotest.test_case "array read via indexing type-checks" `Quick
    (expect_ok "fn putc(c: char) {} fn f() { let mut buf: [char; 4]; putc(buf[0]); }");

  Alcotest.test_case "array decays to *char when passed to pointer param" `Quick
    (expect_ok "fn fill(p: *char, n: int) {}
                fn f() { let mut buf: [char; 4]; fill(buf, 4); }");

  Alcotest.test_case "array write arr[i]=v type-checks" `Quick
    (expect_ok "fn f(arr: *char) { arr[0] = 'A'; }");

  Alcotest.test_case "array write to non-pointer is a type error" `Quick
    (expect_type_error "cannot unify"
       "fn f(n: int) { n[0] = 1; }");

  Alcotest.test_case "array write with deref index buf[*ptr]=val type-checks" `Quick
    (expect_ok "fn f(buf: *int, tail: *int) { buf[*tail] = 42; }");

  Alcotest.test_case "addrof mut var as function argument type-checks" `Quick
    (expect_ok "fn push(tail: *int) {}
                fn f() { let mut t: int = 0; push(&t); }");

  (* ── 関数ポインタ型 ──────────────────────────────────────────── *)

  Alcotest.test_case "fn pointer param can be called indirectly" `Quick
    (expect_ok "fn foo() {}
                fn f(h: fn() -> void) { h(); }");

  Alcotest.test_case "fn pointer let binding and indirect call type-checks" `Quick
    (expect_ok "fn foo() {}
                fn f() { let h: fn() -> void = foo; h(); }");

  Alcotest.test_case "fn pointer stored in global array type-checks" `Quick
    (expect_ok "let handlers: [fn() -> void; 4];
                fn f(h: fn() -> void) { handlers[0] = h; }");

  Alcotest.test_case "fn pointer argument count mismatch is a type error" `Quick
    (expect_type_error "argument count mismatch"
       "fn foo(x: int) {}
        fn f(h: fn() -> void) { h = foo; }");

  (* ── 構造体 ────────────────────────────────────────────────────── *)

  Alcotest.test_case "struct field access type-checks" `Quick
    (expect_ok "struct Point { x: int; y: int; }
                fn sum(p: *Point) -> int { return p.x + p.y; }");

  Alcotest.test_case "struct field write type-checks" `Quick
    (expect_ok "struct Point { x: int; y: int; }
                fn f() { let mut p: Point; p.x = 3; p.y = 4; }");

  Alcotest.test_case "struct passed by pointer type-checks" `Quick
    (expect_ok "struct Point { x: int; y: int; }
                fn sum(p: *Point) -> int { return p.x + p.y; }
                fn f() { let mut s: Point; s.x = 1; s.y = 2; sum(&s); }");

  Alcotest.test_case "global struct variable type-checks" `Quick
    (expect_ok "struct Point { x: int; y: int; }
                let g: Point;
                fn f() { g.x = 10; g.y = 20; }");

  Alcotest.test_case "struct field char type type-checks" `Quick
    (expect_ok "struct Pair { a: int; b: char; }
                fn f() { let mut p: Pair; p.a = 1; p.b = 'X'; }");

  Alcotest.test_case "unknown field name is a type error" `Quick
    (expect_type_error "no field"
       "struct Point { x: int; y: int; }
        fn f(p: *Point) -> int { return p.z; }");

  Alcotest.test_case "field access on non-struct is a type error" `Quick
    (expect_type_error "non-struct"
       "fn f(n: int) -> int { return n.x; }");

  Alcotest.test_case "struct type mismatch: passing *B where *A expected" `Quick
    (expect_type_error "struct type mismatch"
       "struct A { x: int; }
        struct B { x: int; }
        fn use_a(a: *A) {}
        fn f(b: *B) { use_a(b); }");

  (* ── extern fn ─────────────────────────────────────────────────── *)

  Alcotest.test_case "extern fn void can be called" `Quick
    (expect_ok "extern fn uart_putc(c: char);
                fn f() { uart_putc('A'); }");

  Alcotest.test_case "extern fn with return type propagates" `Quick
    (expect_ok "extern fn uart_getc() -> char;
                fn f() char { return uart_getc(); }");

  (* ── 文字列リテラル ──────────────────────────────────────────── *)

  Alcotest.test_case "string literal infers as *char" `Quick (fun () ->
    let pt = infer "fn f() { let s = \"hello\"; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "s has type *char" (Ast.TypePtr Ast.TypeChar)
      (Types.StringMap.find "s" fi.Types.local_types)
  );

  (* ── 構造体リテラル ──────────────────────────────────────────── *)

  Alcotest.test_case "struct literal initializer type-checks" `Quick
    (expect_ok "struct Point { x: int; y: int; }
                fn f() { let mut p: Point = {1, 2}; }");

  Alcotest.test_case "array literal initializer type-checks" `Quick
    (expect_ok "fn f() { let mut arr: [char; 3] = {'a', 'b', 'c'}; }");

  Alcotest.test_case "struct literal wrong field count is a type error" `Quick
    (expect_type_error "has"
       "struct Point { x: int; y: int; }
        fn f() { let mut p: Point = {1, 2, 3}; }");

  Alcotest.test_case "struct literal field type mismatch is a type error" `Quick
    (expect_type_error "cannot unify"
       "struct S { x: int; }
        fn f(p: *int) { let mut s: S = {p}; }");

  (* ── int + ptr 可換ポインタ算術 ─────────────────────────────── *)

  Alcotest.test_case "int + ptr commutative pointer arithmetic type-checks" `Quick
    (expect_ok "fn f(p: *char) *char { return 1 + p; }");

  (* ── &s.field ────────────────────────────────────────────────── *)

  Alcotest.test_case "&s.field yields pointer-to-field-type" `Quick (fun () ->
    let pt = infer "struct P { x: int; }
                    fn f() { let mut s: P; let q = &s.x; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "q has type *int" (Ast.TypePtr Ast.TypeInt)
      (Types.StringMap.find "q" fi.Types.local_types)
  );

  (* ── ポインタレシーバのフィールド代入 ───────────────────────── *)

  Alcotest.test_case "field assign via pointer receiver type-checks" `Quick
    (expect_ok "struct Point { x: int; y: int; }
                fn f(p: *Point) { p.x = 1; p.y = 2; }");

  (* ── let mut ローカル変数（初期化なし） ─────────────────────── *)

  Alcotest.test_case "let mut local without initializer type-checks" `Quick
    (expect_ok "fn f() { let mut x: int; x = 0; }");

  (* ── 左シフト・ビット OR ─────────────────────────────────────── *)

  Alcotest.test_case "left shift Shl type-checks" `Quick
    (expect_ok "fn f(n: int) int { return n << 3; }");

  Alcotest.test_case "bitwise OR Bor type-checks" `Quick
    (expect_ok "fn f(a: int, b: int) int { return a | b; }");

]

(* ── Entry point ─────────────────────────────────────────────────────────── *)

let () = Alcotest.run "takibi" [
  "parser",   parser_tests;
  "type_inf", infer_tests;
]
