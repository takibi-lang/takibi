open Takibi

(* -- Helpers --------------------------------------------------------------- *)

let parse src =
  let lexbuf = Lexing.from_string src in
  Parser.program Lexer.read lexbuf

let infer src =
  Type_inf.infer_program (parse src)

(* Custom Alcotest testables *)

let rec show_type = function
  | Ast.TypeBool        -> "bool"
  | Ast.TypeI8          -> "i8"  | Ast.TypeI16 -> "i16" | Ast.TypeI32 -> "i32" | Ast.TypeI64 -> "i64"
  | Ast.TypeU8          -> "u8"  | Ast.TypeU16 -> "u16" | Ast.TypeU32 -> "u32" | Ast.TypeU64 -> "u64"
  | Ast.TypeVoid        -> "void"
  | Ast.TypePtr t       -> "*" ^ show_type t
  | Ast.TypeIo  t       -> "io " ^ show_type t
  | Ast.TypeArray (t,n) -> Printf.sprintf "[%s; %d]" (show_type t) n
  | Ast.TypeFn (ps, r)  ->
      Printf.sprintf "fn(%s) -> %s"
        (String.concat ", " (List.map show_type ps)) (show_type r)
  | Ast.TypeNamed s     -> s
  | Ast.TypeRefined (lo, hi) -> Printf.sprintf "{%d..<%d}" lo hi

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

(* -- Parser tests ---------------------------------------------------------- *)

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
    match parse "let g: u8 = 0;" with
    | [Ast.LetDef (name, ty, _)] ->
        Alcotest.(check string)        "name" "g" name;
        Alcotest.(check (option type_t)) "type" (Some Ast.TypeU8) ty
    | _ -> Alcotest.fail "expected single LetDef"
  );

  Alcotest.test_case "return statement" `Quick (fun () ->
    match parse "fn f() i32 { return 42; }" with
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
     | Ast.LetDef ("x", _, _) -> ()
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
    | [Ast.LetDef (_, Some t, None)] ->
        Alcotest.check type_t "type is io i32" (Ast.TypeIo Ast.TypeI32) t
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "io type in struct field parses" `Quick (fun () ->
    match parse "struct S { done: io i32; }" with
    | [Ast.StructDef (_, [(_, t)])] ->
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
         | Ast.Let (_, _, _, Some { desc = Ast.AddrOf { desc = Ast.Var "x"; _ }; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(_, AddrOf x)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "assign through pointer" `Quick (fun () ->
    match parse "fn f(p: *i32) { *p = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref ({ desc = Ast.Var "p"; _ },
                             { desc = Ast.IntLit 42; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(Var p, IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "hex integer literal" `Quick (fun () ->
    match parse "fn f() i32 { return 0xff; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 255; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 255)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "u8 literal becomes IntLit" `Quick (fun () ->
    match parse "fn f() i32 { return 'A'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 65; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 65)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "u8 escape literals" `Quick (fun () ->
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
                                 { desc = Ast.IntLit 0; _ },
                                 { desc = Ast.IntLit 42; _ }); _ } -> ()
         | _ -> Alcotest.fail "expected Return(BinOp(Sub, IntLit 0, IntLit 42))")
    | _ -> Alcotest.fail "unexpected structure"
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
             { desc = Ast.IntLit 88; _ }) -> ()   (* 'X' = 88 *)
         | _ -> Alcotest.fail "expected AssignIndex(arr, Var i, IntLit 88)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Arrays ------------------------------------------------------ *)

  Alcotest.test_case "array type annotation parses" `Quick (fun () ->
    match parse "fn f() { let mut buf: [u8; 8]; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (true, "buf", Some (Ast.TypeArray (Ast.TypeU8, 8)), None) -> ()
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
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([], Ast.TypeVoid)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn() -> void"
  );

  Alcotest.test_case "fn pointer type with one arg parses" `Quick (fun () ->
    match parse "fn f(h: fn(i32) -> u8) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([Ast.TypeI32], Ast.TypeU8)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn(i32) -> u8"
  );

  Alcotest.test_case "fn pointer type with multiple args parses" `Quick (fun () ->
    match parse "fn f(h: fn(i32, u8) -> i32) {}" with
    | [Ast.FuncDef { params = [("h", Some (Ast.TypeFn ([Ast.TypeI32; Ast.TypeU8], Ast.TypeI32)))]; _ }] -> ()
    | _ -> Alcotest.fail "expected param h: fn(i32, u8) -> i32"
  );

  Alcotest.test_case "let variable with fn pointer type annotation parses" `Quick (fun () ->
    match parse "fn foo() {} fn f() { let h: fn() -> void = foo; }" with
    | [Ast.FuncDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (false, "h", Some (Ast.TypeFn ([], Ast.TypeVoid)), Some _) -> ()
         | _ -> Alcotest.fail "expected Let(h, TypeFn([], void), Some(foo))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Struct syntax ------------------------------------------------ *)

  Alcotest.test_case "struct definition parses" `Quick (fun () ->
    match parse "struct Point { x: i32; y: i32; }" with
    | [Ast.StructDef ("Point", fields)] ->
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
                             { desc = Ast.IntLit 5; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignField(p, x, 5)")
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
         | Ast.Let (_, _, _, Some { desc = Ast.EnumVariant ("Color", "Red"); _ }) -> ()
         | _ -> Alcotest.fail "expected Let(_, EnumVariant(Color, Red))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "match with variant arm parses to Match/ArmVariant" `Quick (fun () ->
    match parse "enum Color: u8 { Red = 0; }
                 fn f(c: Color) { match c { Color::Red => { let x = 0; } } }" with
    | [Ast.EnumDef _; Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Match (_, [Ast.ArmVariant ("Color", "Red", [_])]) -> ()
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
    | [Ast.ExternFuncDef ("uart_putc", [("c", Some Ast.TypeU8)], None)] -> ()
    | _ -> Alcotest.fail "expected ExternFuncDef(uart_putc, [c:u8], None)"
  );

  Alcotest.test_case "extern fn with return type parses" `Quick (fun () ->
    match parse "extern fn uart_getc() -> u8;" with
    | [Ast.ExternFuncDef ("uart_getc", [], Some Ast.TypeU8)] -> ()
    | _ -> Alcotest.fail "expected ExternFuncDef(uart_getc, [], Some u8)"
  );

  (* -- String literals -------------------------------------------- *)

  Alcotest.test_case "string literal parses to StringLit" `Quick (fun () ->
    match parse "fn f() { let s = \"hello\"; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.StringLit "hello"; _ }) -> ()
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
                    Some { desc = Ast.StructLit [_; _]; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(mut, p, TypeNamed P, StructLit [_, _])")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Compound pointer assignment ------------------------------------------ *)

  Alcotest.test_case "complex pointer assign *(expr) = v parses to AssignDeref" `Quick (fun () ->
    match parse "fn f(arr: *i32, i: i32) { *(arr + i) = 42; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.AssignDeref (
             { desc = Ast.BinOp (Ast.Add, _, _); _ },
             { desc = Ast.IntLit 42; _ }) -> ()
         | _ -> Alcotest.fail "expected AssignDeref(BinOp(Add,...), 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Taking address of struct fields --------------------------- *)

  Alcotest.test_case "addrof struct field parses to AddrOf(FieldGet)" `Quick (fun () ->
    match parse "fn f() { let q = &p.x; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.AddrOf
             { desc = Ast.FieldGet _; _ }; _ }) -> ()
         | _ -> Alcotest.fail "expected Let(_, AddrOf(FieldGet(...)))")
    | _ -> Alcotest.fail "unexpected structure"
  );

  (* -- Remaining escape characters ---------------------------------------- *)

  Alcotest.test_case "tab escape u8 literal '\\t'" `Quick (fun () ->
    match parse "fn f() { let t = '\\t'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.IntLit 9; _ }) -> ()
         | _ -> Alcotest.fail "expected IntLit 9 (tab = ASCII 9)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "backslash escape u8 literal '\\\\'" `Quick (fun () ->
    match parse "fn f() { let bs = '\\\\'; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Let (_, _, _, Some { desc = Ast.IntLit 92; _ }) -> ()
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
         | Ast.Return { desc = Ast.IntLit 42; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 42)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "block comment /* */ is ignored" `Quick (fun () ->
    match parse "fn f() i32 { /* skip this */ return 0; }" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 0; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 0)")
    | _ -> Alcotest.fail "unexpected structure"
  );

  Alcotest.test_case "multi-line block comment is ignored" `Quick (fun () ->
    match parse "fn f() i32 {\n  /*\n   * multi\n   * line\n   */\n  return 7;\n}" with
    | [Ast.FuncDef { body = [s]; _ }] ->
        (match s.desc with
         | Ast.Return { desc = Ast.IntLit 7; _ } -> ()
         | _ -> Alcotest.fail "expected Return(IntLit 7)")
    | _ -> Alcotest.fail "unexpected structure"
  );

]

(* -- Type inference tests -------------------------------------------------- *)

let infer_tests = [

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

  Alcotest.test_case "if/else branches both valid" `Quick
    (expect_ok "fn abs(x: i32) i32 {
                  if (x > 0) { return x; } else { return 0; } }");

  (* -- Immutability checks ------------------------------------------- *)

  Alcotest.test_case "assign to immutable variable is a type error" `Quick
    (expect_type_error "cannot assign to immutable"
       "fn f() { let x = 0; x = 1; }");

  Alcotest.test_case "let mut allows reassignment" `Quick
    (expect_ok "fn f() { let mut x = 0; x = 1; }");

  Alcotest.test_case "addrof immutable variable is a type error" `Quick
    (expect_type_error "cannot take address of immutable"
       "fn f() { let x = 0; let p = &x; }");

  Alcotest.test_case "addrof mutable variable succeeds" `Quick
    (expect_ok "fn f() { let mut x: i32 = 0; let p = &x; }");

  Alcotest.test_case "immutable let without initializer is a type error" `Quick
    (expect_type_error "must have an initializer"
       "fn f() { let x: i32; }");

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
    let pt = infer "let flag: io i32;\nfn f() { let p: *io i32 = &flag; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "p has type *io i32"
      (Ast.TypePtr (Ast.TypeIo Ast.TypeI32))
      (Types.StringMap.find "p" fi.Types.local_types)
  );

  Alcotest.test_case "assign i32 to io i32 global type-checks" `Quick
    (expect_ok "let flag: io i32;\nfn f() { flag = 1; }");

  Alcotest.test_case "io i32 global in comparison type-checks" `Quick
    (expect_ok "let flag: io i32;\nfn f() i32 { if (flag == 0) { return 1; } return 0; }");

  Alcotest.test_case "io i32 struct field type-checks" `Quick
    (expect_ok "struct S { done: io i32; }\nlet s: S;\nfn f() { s.done = 1; }");

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

  Alcotest.test_case "as cast pointer to i32 passes" `Quick
    (expect_ok "fn f(p: *i32) i32 { return p as i32; }");

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

  Alcotest.test_case "pointer subtraction ptr - i32 type-checks" `Quick
    (expect_ok "fn f(p: *u8) *u8 { return p - 8; }");

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
    (expect_ok "fn f(buf: *i32, tail: *i32) { buf[*tail] = 42; }");

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
    (expect_ok "let handlers: [fn() -> void; 4];
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

  Alcotest.test_case "struct passed by pointer type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                fn sum(p: *Point) -> i32 { return p.x + p.y; }
                fn f() { let mut s: Point; s.x = 1; s.y = 2; sum(&s); }");

  Alcotest.test_case "global struct variable type-checks" `Quick
    (expect_ok "struct Point { x: i32; y: i32; }
                let g: Point;
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

  (* -- Commutative pointer arithmetic: int + ptr ------------------------------- *)

  Alcotest.test_case "i32 + ptr commutative pointer arithmetic type-checks" `Quick
    (expect_ok "fn f(p: *u8) *u8 { return 1 + p; }");

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

  Alcotest.test_case "dynamic index on array still type-checks" `Quick
    (expect_ok "fn f(i: i32) i32 { let mut arr: [i32; 4]; return arr[i]; }");

  Alcotest.test_case "constant OOB on global array is a compile error" `Quick
    (expect_type_error "out of bounds"
       "let buf: [u8; 8]; fn f() u8 { return buf[8]; }");

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
       "let buf: [i32; 4]; fn f() { buf[4] = 0; }");

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

  (* -- TypeRefined syntax (Step 3.1 / 3.2) ----------------------- *)

  Alcotest.test_case "TypeRefined parses as param annotation" `Quick (fun () ->
    let pt = infer "fn f(i: {0..<8}) i32 { return i; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "i has type {0..<8}"
      (Ast.TypeRefined (0, 8))
      (snd (List.hd fi.Types.param_types)));

  Alcotest.test_case "TypeRefined after -> parses as return type" `Quick (fun () ->
    let pt = infer "fn f() -> {0..<8} { return 0; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {0..<8}"
      (Ast.TypeRefined (0, 8))
      fi.Types.ret_type);

  Alcotest.test_case "TypeRefined in let annotation type-checks" `Quick
    (expect_ok "fn f() { let x: {0..<8} = 3; }");

  Alcotest.test_case "TypeRefined as param unifies with i32 body" `Quick
    (expect_ok "fn f(i: {0..<8}) i32 { return i; }");

  Alcotest.test_case "TypeRefined can be used as array index" `Quick
    (expect_ok "fn f(i: {0..<8}, p: *u8) { p[i] = 'A'; }");

  (* -- Step 3.3c: Range propagation ------------------------------------ *)

  Alcotest.test_case "Add propagates TRefinedInt: {0..<7}+1 is {1..<8}" `Quick (fun () ->
    let pt = infer "fn f(i: {0..<7}) -> {1..<8} { return i + 1; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {1..<8}"
      (Ast.TypeRefined (1, 8))
      fi.Types.ret_type);

  Alcotest.test_case "Sub propagates TRefinedInt: {1..<8}-1 is {0..<7}" `Quick (fun () ->
    let pt = infer "fn f(i: {1..<8}) -> {0..<7} { return i - 1; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {0..<7}"
      (Ast.TypeRefined (0, 7))
      fi.Types.ret_type);

  Alcotest.test_case "Add propagation: k+{c..<d} commutative" `Quick (fun () ->
    let pt = infer "fn f(i: {0..<4}) -> {3..<7} { return 3 + i; }" in
    let fi = Types.StringMap.find "f" pt.Types.functions in
    Alcotest.check type_t "return type is {3..<7}"
      (Ast.TypeRefined (3, 7))
      fi.Types.ret_type);

  Alcotest.test_case "TRefinedInt result is subtype of i32 return" `Quick
    (expect_ok "fn f(i: {0..<7}) -> i32 { return i + 1; }");

  Alcotest.test_case "Mismatched refined return is a type error" `Quick
    (expect_type_error "range mismatch"
      "fn f(i: {0..<8}) -> {0..<8} { return i + 1; }");

  (* -- Step 3.3c: soundness condition for % range propagation ---------------------------- *)
  (* When the left operand is int (possibly negative), do not return {0..<m}.
     LLVM's srem returns a negative remainder when the dividend is negative, making this unsound.
     Example: (-5) % 8 = -5 (not 3) -- returning {0..<8} without a non-negative guarantee is wrong. *)

  Alcotest.test_case "i32%m stays TInt -- negative left operand possible" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<4}) {} \
       fn f(n: i32) { foo(n % 4); }");

  Alcotest.test_case "{0..<8}%4 propagates to {0..<4}" `Quick
    (expect_ok
      "fn foo(i: {0..<4}) {} \
       fn f(i: {0..<8}) { foo(i % 4); }");

  Alcotest.test_case "{0..<8}%8 can index [u8;8] without bounds check" `Quick
    (expect_ok
      "let buf: [u8; 8]; \
       fn f(i: {0..<8}) { buf[i % 8] = 'X'; }");

  (* -- Step 3.4: Bounds check elision (global array + TypeRefined index) -- *)

  Alcotest.test_case "refined index on global array compiles" `Quick
    (expect_ok
      "let buf: [u8; 8]; \
       fn f(i: {0..<8}) { buf[i] = 'X'; }");

  Alcotest.test_case "refined pair write (i and i+1) compiles" `Quick
    (expect_ok
      "let buf: [u8; 8]; \
       fn f(i: {0..<7}) { buf[i] = 'A'; buf[i+1] = 'B'; }");

  Alcotest.test_case "refined arithmetic range mismatch caught at return" `Quick
    (expect_type_error "range mismatch"
      "fn f(i: {0..<8}) -> {0..<8} { return i + 1; }");

  Alcotest.test_case "non-proven index (overflow range) still compiles" `Quick
    (expect_ok
      "let buf: [u8; 8]; \
       fn f(i: {0..<8}) { buf[i+1] = 'Z'; }");

  (* -- Step 3.5: Type narrowing via if-condition ------------------------------- *)

  Alcotest.test_case "if (v>=0 && v<8) narrows v to {0..<8}" `Quick
    (expect_ok
      "let buf: [u8; 8]; \
       fn foo(i: {0..<8}) {} \
       fn f(v: i32) { if (v >= 0 && v < 8) { foo(v); } }");

  Alcotest.test_case "if (v>=0 && v<8) allows buf[v] write" `Quick
    (expect_ok
      "let buf: [u8; 8]; \
       fn f(v: i32) { if (v >= 0 && v < 8) { buf[v] = 'X'; } }");

  Alcotest.test_case "outside if block v remains i32 (no escape)" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<8}) {} \
       fn f(v: i32) { if (v >= 0 && v < 8) {} foo(v); }");

  Alcotest.test_case "single bound (only v<8) does not narrow" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<8}) {} \
       fn f(v: i32) { if (v < 8) { foo(v); } }");

  Alcotest.test_case "let mut variable is also narrowed in then-branch" `Quick
    (expect_ok
      "fn foo(i: {0..<8}) {} \
       fn f() { let mut v: i32 = 3; if (v >= 0 && v < 8) { foo(v); } }");

  Alcotest.test_case "else branch does not get narrowing" `Quick
    (expect_type_error "unproven i32"
      "fn foo(i: {0..<8}) {} \
       fn f(v: i32) { if (v >= 0 && v < 8) {} else { foo(v); } }");

  Alcotest.test_case "commutative form (0<=v && v<8) also narrows" `Quick
    (expect_ok
      "fn foo(i: {0..<8}) {} \
       fn f(v: i32) { if (0 <= v && v < 8) { foo(v); } }");

  (* -- Step 3.5 for loop: for i in lo..<hi ----------------------------------- *)

  Alcotest.test_case "for loop parses and type-checks" `Quick
    (expect_ok "fn f() { for i in 0..<8 {} }");

  Alcotest.test_case "for loop variable has refined type (literal bounds)" `Quick
    (fun () ->
      let pt = infer "let buf: [u8; 8]; \
                      fn f() { for i in 0..<8 { buf[i] = 'X'; } }" in
      (* buf[i] should compile without error: i:{0..<8} covers [u8;8] *)
      ignore pt);

  Alcotest.test_case "for loop body accesses refined-param function" `Quick
    (expect_ok
      "fn foo(i: {0..<8}) {} \
       fn f() { for i in 0..<8 { foo(i); } }");

  Alcotest.test_case "for loop variable does not escape" `Quick
    (expect_type_error "Unbound variable"
      "fn f() { for i in 0..<8 {} let x: i32 = i; }");

  Alcotest.test_case "for with variable bounds gives plain i32" `Quick
    (expect_ok
      "fn f(n: i32) { let mut s: i32 = 0; for i in 0..<n { s = s + i; } }");

  Alcotest.test_case "nested for loops compile" `Quick
    (expect_ok
      "let buf: [u8; 4]; \
       fn f() { for i in 0..<4 { buf[i] = 'A'; } \
                for i in 0..<4 { buf[i] = 'B'; } }");

  (* -- break and continue ---------------------------------------------------- *)

  Alcotest.test_case "break in while parses and type-checks" `Quick
    (expect_ok "fn f() { while (1) { break; } }");

  Alcotest.test_case "continue in while parses and type-checks" `Quick
    (expect_ok "fn f() { while (1) { continue; } }");

  Alcotest.test_case "break in for parses and type-checks" `Quick
    (expect_ok "fn f() { for i in 0..<10 { break; } }");

  Alcotest.test_case "continue in for parses and type-checks" `Quick
    (expect_ok "fn f() { for i in 0..<10 { continue; } }");

  Alcotest.test_case "break inside if inside while type-checks" `Quick
    (expect_ok "fn f(x: i32) { while (1) { if (x == 0) { break; } } }");

  Alcotest.test_case "continue inside if inside for type-checks" `Quick
    (expect_ok "fn f(x: i32) { for i in 0..<10 { if (x == 0) { continue; } } }");

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
         Color::Red   => { let x = 0; }
         Color::Green => { let y = 1; } } }");

  Alcotest.test_case "exhaustive enum match missing variant is a type error" `Quick
    (expect_type_error "non-exhaustive match: 'Color::Green' not covered"
      "enum Color: u8 { Red = 0; Green = 1; }
       fn f(c: Color) { match c { Color::Red => { let x = 0; } } }");

  Alcotest.test_case "exhaustive enum match with wildcard type-checks" `Quick
    (expect_ok
      "enum Color: u8 { Red = 0; Green = 1; }
       fn f(c: Color) { match c {
         Color::Red => { let x = 0; }
         _ => { let y = 1; } } }");

  Alcotest.test_case "non-exhaustive enum match with _ type-checks" `Quick
    (expect_ok
      "enum EtherType: u16 { IPv4 = 0x0800; _; }
       fn f(et: EtherType) { match et {
         EtherType::IPv4 => { let x = 0; }
         _ => { let y = 1; } } }");

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
       fn f() { for i in 0..<3 { let c: Color = i as Color; } }");

]

(* -- Entry point ----------------------------------------------------------- *)

let () = Alcotest.run "takibi" [
  "parser",   parser_tests;
  "type_inf", infer_tests;
]
