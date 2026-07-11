%{
open Ast

(* Narrow an INT token's Int64.t value to a native int for grammar positions
   that only ever need a small, realistic value (alignment, enum
   discriminants, array sizes) -- see Ast.int_of_intlit's comment for why a
   plain Int64.to_int would be unsound here (OCaml's int is one bit
   narrower than Int64.t on a 64-bit host). Unlike the small-number-scoped
   ANALYSIS code elsewhere (range propagation, narrowing) that silently
   falls back to a conservative "can't reason about this" behavior on
   overflow, each of these grammar positions has no such fallback -- the
   value is used directly as a hard requirement (LLVM's set_alignment, an
   enum's discriminant, an array's element count) -- so overflow here is a
   hard TypeError instead. *)
let narrow_int64 pos what (n : Int64.t) : int =
  match Ast.int_of_intlit n with
  | Some i -> i
  | None ->
      raise (Types.TypeError (pos,
        Printf.sprintf "%s value %Ld is too large to represent" what n))

(* Display name for an explicit {lo..<hi as base} base, error messages only. *)
let base_type_name = function
  | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32" | TypeI64 -> "i64"
  | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32" | TypeU64 -> "u64"
  | TypeIsize -> "isize" | TypeUsize -> "usize" | _ -> "?"

(* The (inclusive lo, exclusive-upper-bound-or-None) range an explicit
   {lo..<hi as base} bound must fit within, so a too-wide range doesn't
   silently truncate at codegen time the same way a bare {lo..<hi} bound
   used to before the i32-range check above was added -- same reasoning,
   generalized per base. i64/u64 (and usize, treated as the narrowest
   width it can have across supported targets -- Cortex-M's usize is
   32-bit -- so it's checked the same as u32, not left as wide as i64/u64
   themselves) have no upper limit checked here: their own representable
   range either already exceeds what narrow_int64 can hold (i64/u64) or
   isn't target-width-independent to state precisely (usize), and
   types.ml's own TRefinedInt subtyping rules for those bases likewise
   impose no hi restriction. *)
let base_bound_range = function
  | TypeI8    -> (-128L, Some 128L)
  | TypeI16   -> (-32768L, Some 32768L)
  | TypeI32   -> (-2147483648L, Some 2147483647L)
  | TypeI64   -> (Int64.min_int, None)
  | TypeU8    -> (0L, Some 256L)
  | TypeU16   -> (0L, Some 65536L)
  | TypeU32   -> (0L, Some 4294967296L)
  | TypeU64   -> (0L, None)
  | TypeIsize -> (-2147483648L, Some 2147483647L)
  | TypeUsize -> (0L, Some 4294967296L)
  | _ -> (Int64.min_int, None) (* unreachable: int_base_type_expr only ever produces the above *)

let check_refined_base_range pos lo hi base =
  let (blo, bhi_opt) = base_bound_range base in
  let out_of_range =
    lo < blo || (match bhi_opt with Some bhi -> hi > bhi | None -> false)
  in
  if out_of_range then
    raise (Types.TypeError (pos,
      Printf.sprintf
        "refined type bound {%Ld..<%Ld as %s} is out of range for %s"
        lo hi (base_type_name base) (base_type_name base)))
%}

%token <Int64.t> INT
%token <string> IDENT
%token <string> STRING
%token FN RETURN LET MUT EXTERN STRUCT OPAQUE AFFINE BORROW SINK PACKED IO ENUM MATCH ALIGN SIZEOF OFFSETOF UNSAFE USE
%token DARROW COLONCOLON UNDERSCORE
%token LBRACE RBRACE LPAREN RPAREN LBRACKET RBRACKET COMMA SEMI DOTDOTLT DOTDOT
%token ASSIGN DOT
%token IF ELSE WHILE FOR IN BREAK CONTINUE
%token EOF
%token AMP TILDE

%token LT GT LE GE EQ NE
%token PLUS MINUS TIMES DIV PERCENT
%token OR PIPE HAT SHR SHL DAMP
%token AS
%token PLUS_EQ MINUS_EQ PIPE_EQ AMP_EQ HAT_EQ SHL_EQ SHR_EQ

(* Precedence: low -> high.  UNARY is a pseudo-token for %prec. *)
%left OR          (* || -- lowest precedence logical operator *)
%left DAMP        (* && -- higher than ||, lower than comparison operators *)
%left PIPE        (* bitwise OR: looser than comparison so (a==0)|(b==0) works *)
%left HAT         (* bitwise XOR: between | and comparison *)
%left LT GT LE GE EQ NE
%left AMP         (* bitwise AND -- also used as unary AddrOf prefix *)
%nonassoc AS      (* as cast: lower than arithmetic so a+b as T = (a+b) as T *)
%left PLUS MINUS
%left SHR SHL     (* shifts: tighter than +/-, looser than * / % *)
%left TIMES DIV PERCENT  (* multiplicative *)
%nonassoc UNARY   (* unary * (deref), & (addrof), unary - *)
%left DOT         (* highest: field access -- postfix, binds tighter than prefix ops *)

%token VOID_TYPE BOOL_TYPE
%token I8_TYPE I16_TYPE I32_TYPE I64_TYPE
%token U8_TYPE U16_TYPE U32_TYPE U64_TYPE ISIZE_TYPE USIZE_TYPE
%token TRUE FALSE
%token COLON ARROW

%start <Ast.toplevel list> program

%%

program:
  | items EOF { $1 }

items:
  | item { [$1] }
  | item items { $1 :: $2 }

%inline mut_flag:
  | /* empty */ { false }
  | MUT         { true }

item:
  | func_def { FuncDef $1 }
  | LET m = mut_flag IDENT let_rhs SEMI
    { Const_env.define_if_literal m $3 (snd $4);
      LetDef ($3, fst $4, snd $4, None, m) }
  | LET m = mut_flag IDENT COLON type_expr ALIGN LPAREN INT RPAREN SEMI
    { LetDef ($3, Some $5, None, Some (narrow_int64 $symbolstartpos "alignment" $8), m) }
  | LET m = mut_flag IDENT COLON type_expr ALIGN LPAREN INT RPAREN ASSIGN expr SEMI
    { LetDef ($3, Some $5, Some $11, Some (narrow_int64 $symbolstartpos "alignment" $8), m) }
  | EXTERN FN IDENT LPAREN params RPAREN SEMI
    { ExternFuncDef ($3, $5, None) }
  | EXTERN FN IDENT LPAREN params RPAREN ARROW type_expr SEMI
    { ExternFuncDef ($3, $5, Some $8) }
  | struct_intro LBRACE struct_fields RBRACE
    { let (name, is_packed, align_opt) = $1 in
      Type_layout.finish_struct name $3 is_packed align_opt;
      StructDef (name, $3, is_packed, align_opt) }
  | OPAQUE STRUCT IDENT SEMI
    { OpaqueStructDef ($3, false) }
  | AFFINE OPAQUE STRUCT IDENT SEMI
    { OpaqueStructDef ($4, true) }
  | ENUM IDENT COLON base_type_expr LBRACE enum_variants RBRACE
    { let (vs, ne) = $6 in
      Type_layout.register_enum $2 $4;
      EnumDef ($2, Some $4, vs, ne) }
  | ENUM IDENT LBRACE enum_variants RBRACE
    { let (vs, ne) = $4 in
      Type_layout.register_enum $2 TypeU32;
      EnumDef ($2, None, vs, ne) }
  | USE STRING SEMI
    { UseDef $2 }

struct_intro:
  | STRUCT IDENT
    { Type_layout.begin_struct $2;
      ($2, false, None) }
  | STRUCT PACKED IDENT
    { Type_layout.begin_struct $3;
      ($3, true, None) }
  | STRUCT IDENT ALIGN LPAREN INT RPAREN
    { let align = narrow_int64 $symbolstartpos "alignment" $5 in
      Type_layout.begin_struct $2;
      ($2, false, Some align) }
  | STRUCT PACKED IDENT ALIGN LPAREN INT RPAREN
    { let align = narrow_int64 $symbolstartpos "alignment" $6 in
      Type_layout.begin_struct $3;
      ($3, true, Some align) }

struct_fields:
  | /* empty */ { [] }
  | IDENT COLON type_expr SEMI struct_fields { ($1, $3) :: $5 }

enum_variants:
  | /* empty */                         { ([], false) }
  | UNDERSCORE SEMI enum_variants       { let (vs, _) = $3 in (vs, true) }
  | IDENT ASSIGN INT SEMI enum_variants
    { let (vs, ne) = $5 in
      (($1, Some (narrow_int64 $symbolstartpos "enum discriminant" $3)) :: vs, ne) }
  | IDENT SEMI            enum_variants { let (vs, ne) = $3 in (($1, None)    :: vs, ne) }

func_def:
  | FN IDENT LPAREN params RPAREN ret_type_opt LBRACE stmts RBRACE
    {
      Ast.{ name = $2; params = $4; ret_type = $6; body = $8; def_loc = $symbolstartpos }
    }

param:
  | IDENT { ($1, None) }
  | IDENT COLON type_expr { ($1, Some $3) }

params:
  | /* empty */ { [] }
  | param rest_params { $1 :: $2 }

rest_params:
  | /* empty */ { [] }
  | COMMA param rest_params { $2 :: $3 }

ret_type_opt:
  | /* empty */          { None }
  | ARROW type_expr      { Some $2 }   (* fn foo() -> int  preferred form *)
  | base_type_expr       { Some $1 }   (* fn foo() int  backward-compatible; {lo..<hi} cannot be written without -> *)

stmts:
  | /* empty */ { [] }
  | stmt stmts { $1 :: $2 }

stmt:
  | RETURN e = expr SEMI { { desc = Return e; loc = $symbolstartpos } }
  | fname = IDENT LPAREN args = args RPAREN SEMI
    (* Only function calls are allowed as expression statements. IDENT LPAREN disambiguates, eliminating S/R conflicts with DOT *)
    { let loc = $symbolstartpos in
      { desc = Expr { desc = Call (fname, args); loc }; loc } }
  | LET id = IDENT rhs = let_rhs SEMI
    { { desc = Let (false, id, fst rhs, snd rhs, None); loc = $symbolstartpos } }
  | LET MUT id = IDENT rhs = let_rhs SEMI
    { { desc = Let (true, id, fst rhs, snd rhs, None); loc = $symbolstartpos } }
  | LET MUT IDENT COLON type_expr ALIGN LPAREN INT RPAREN SEMI
    (* `align(N)` on a local requires `mut`: an immutable local is an SSA
       value with no alloca/memory location for LLVM's set_alignment to
       apply to (unlike a global, which is always memory-backed regardless
       of mutability) -- see SPEC.md's "Local-variable alignment" note. *)
    { { desc = Let (true, $3, Some $5, None,
                     Some (narrow_int64 $symbolstartpos "alignment" $8));
        loc = $symbolstartpos } }
  | LET MUT IDENT COLON type_expr ALIGN LPAREN INT RPAREN ASSIGN expr SEMI
    { { desc = Let (true, $3, Some $5, Some $11,
                     Some (narrow_int64 $symbolstartpos "alignment" $8));
        loc = $symbolstartpos } }
  | LBRACE s = stmts RBRACE { { desc = Block s; loc = $symbolstartpos } }
  | IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE p = else_part
    { { desc = If(c, t, p); loc = $symbolstartpos } }
  | WHILE LPAREN c = expr RPAREN LBRACE b = stmts RBRACE
    { { desc = While(c, b); loc = $symbolstartpos } }
  | FOR id = IDENT IN lo = expr DOTDOTLT hi = expr LBRACE body = stmts RBRACE
    { { desc = For (id, None, lo, hi, body); loc = $symbolstartpos } }
  | FOR id = IDENT COLON ty = int_base_type_expr IN lo = expr DOTDOTLT hi = expr LBRACE body = stmts RBRACE
    (* Explicit base annotation on the loop counter (e.g. `for i: u8 in
       0..<4 { ... }`) -- restricted to int_base_type_expr (the same 9
       primitive integer types {lo..<hi as base} accepts), not the full
       type_expr grammar: a loop counter's type is always one of these by
       convention (see TRefinedInt's own comment in types.ml), and a
       pointer/array/struct annotation here would be nonsensical. *)
    { { desc = For (id, Some ty, lo, hi, body); loc = $symbolstartpos } }
  | FOR id = IDENT IN s = expr LBRACE body = stmts RBRACE
    (* for x in s { ... } -- element iteration over a slice (LBRACE after the
       expression disambiguates from the lo..<hi range form) *)
    { { desc = ForEach (id, s, body); loc = $symbolstartpos } }
  | BREAK SEMI    { { desc = Break;    loc = $symbolstartpos } }
  | CONTINUE SEMI { { desc = Continue; loc = $symbolstartpos } }
  | MATCH expr LBRACE match_arms RBRACE
    { { desc = Match ($2, $4); loc = $symbolstartpos } }
  | id = IDENT ASSIGN e = expr SEMI
    { { desc = Assign (id, e); loc = $symbolstartpos } }
  | id = IDENT LBRACKET idx = expr RBRACKET ASSIGN rhs = expr SEMI
    (* arr[i] = rhs -- preserves id+size for bounds checking in codegen *)
    { { desc = AssignIndex (id, idx, rhs); loc = $symbolstartpos } }
  | TIMES id = IDENT ASSIGN rhs = expr SEMI
    (* *p = v  -- simple pointer-deref write *)
    { let loc = $symbolstartpos in
      let ptr = { desc = Var id; loc } in
      { desc = AssignDeref (ptr, rhs); loc } }
  | TIMES LPAREN lhs = expr RPAREN ASSIGN rhs = expr SEMI
    (* *(complex_expr) = v  -- e.g. *(arr + i) = v *)
    { { desc = AssignDeref (lhs, rhs); loc = $symbolstartpos } }
  | id = IDENT DOT fname = IDENT ASSIGN rhs = expr SEMI
    (* s.field = v  or  ptr.field = v -- struct field write *)
    { let loc = $symbolstartpos in
      let base = { desc = Var id; loc } in
      { desc = AssignField (base, fname, rhs); loc } }
  | id = IDENT LBRACKET idx = expr RBRACKET DOT fname = IDENT ASSIGN rhs = expr SEMI
    (* arr[i].field = v -- indexed struct field write *)
    { let loc = $symbolstartpos in
      let base = { desc = Index (id, idx); loc } in
      { desc = AssignField (base, fname, rhs); loc } }
  | id = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let lhs = { desc = Var id; loc } in
      { desc = Assign (id, { desc = BinOp (op, lhs, rhs); loc }); loc } }
  | id = IDENT LBRACKET idx = expr RBRACKET op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let load = { desc = Index (id, idx); loc } in
      { desc = AssignIndex (id, idx, { desc = BinOp (op, load, rhs); loc }); loc } }
  | TIMES id = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let ptr = { desc = Var id; loc } in
      let load = { desc = Deref ptr; loc } in
      { desc = AssignDeref (ptr, { desc = BinOp (op, load, rhs); loc }); loc } }
  | TIMES LPAREN lhs = expr RPAREN op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let load = { desc = Deref lhs; loc } in
      { desc = AssignDeref (lhs, { desc = BinOp (op, load, rhs); loc }); loc } }
  | id = IDENT DOT fname = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let base = { desc = Var id; loc } in
      let load = { desc = FieldGet (base, fname); loc } in
      { desc = AssignField (base, fname, { desc = BinOp (op, load, rhs); loc }); loc } }
  | id = IDENT LBRACKET idx = expr RBRACKET DOT fname = IDENT op = compound_op rhs = expr SEMI
    { let loc = $symbolstartpos in
      let base = { desc = Index (id, idx); loc } in
      let load = { desc = FieldGet (base, fname); loc } in
      { desc = AssignField (base, fname, { desc = BinOp (op, load, rhs); loc }); loc } }

%inline compound_op:
  | PLUS_EQ  { Add }
  | MINUS_EQ { Sub }
  | PIPE_EQ  { Bor }
  | AMP_EQ   { Band }
  | HAT_EQ   { Bxor }
  | SHL_EQ   { Shl }
  | SHR_EQ   { Shr }

else_part:
  | ELSE LBRACE e = stmts RBRACE { e }
  | ELSE IF LPAREN c = expr RPAREN LBRACE t = stmts RBRACE p = else_part
    { [{ desc = If(c, t, p); loc = $symbolstartpos }] }
  | (* empty *) { [] }

match_arms:
  | /* empty */ { [] }
  | match_arm match_arms { $1 :: $2 }

match_arm:
  | IDENT COLONCOLON IDENT DARROW LBRACE stmts RBRACE
    { ArmVariant ($1, $3, $6) }
  | UNDERSCORE DARROW LBRACE stmts RBRACE
    { ArmWild $4 }

expr:
  | expr OR      expr  { { desc = BinOp (Or,   $1, $3); loc = $symbolstartpos } }
  | expr DAMP    expr  { { desc = BinOp (And,  $1, $3); loc = $symbolstartpos } }
  | expr PIPE    expr  { { desc = BinOp (Bor,  $1, $3); loc = $symbolstartpos } }
  | expr HAT     expr  { { desc = BinOp (Bxor, $1, $3); loc = $symbolstartpos } }
  | expr AMP     expr  { { desc = BinOp (Band, $1, $3); loc = $symbolstartpos } }
  | expr SHR     expr  { { desc = BinOp (Shr,  $1, $3); loc = $symbolstartpos } }
  | expr SHL     expr  { { desc = BinOp (Shl,  $1, $3); loc = $symbolstartpos } }
  | expr PLUS    expr  { { desc = BinOp (Add,  $1, $3); loc = $symbolstartpos } }
  | expr MINUS   expr  { { desc = BinOp (Sub,  $1, $3); loc = $symbolstartpos } }
  | expr TIMES   expr  { { desc = BinOp (Mul,  $1, $3); loc = $symbolstartpos } }
  | expr DIV     expr  { { desc = BinOp (Div,  $1, $3); loc = $symbolstartpos } }
  | expr PERCENT expr  { { desc = BinOp (Mod,  $1, $3); loc = $symbolstartpos } }
  | expr LT expr   { { desc = BinOp (Lt, $1, $3); loc = $symbolstartpos } }
  | expr GT expr   { { desc = BinOp (Gt, $1, $3); loc = $symbolstartpos } }
  | expr LE expr   { { desc = BinOp (Le, $1, $3); loc = $symbolstartpos } }
  | expr GE expr   { { desc = BinOp (Ge, $1, $3); loc = $symbolstartpos } }
  | expr EQ expr   { { desc = BinOp (Eq, $1, $3); loc = $symbolstartpos } }
  | expr NE expr   { { desc = BinOp (Ne, $1, $3); loc = $symbolstartpos } }
  | TIMES e = expr %prec UNARY { { desc = Deref e;    loc = $symbolstartpos } }
  | AMP e = expr %prec UNARY { { desc = AddrOf e; loc = $symbolstartpos } }
  | TILDE e = expr %prec UNARY { { desc = Bnot e; loc = $symbolstartpos } }
  | MINUS e = expr %prec UNARY
    { { desc = BinOp (Sub, { desc = IntLit 0L; loc = $symbolstartpos }, e);
        loc = $symbolstartpos } }
  | INT    { { desc = IntLit $1;       loc = $symbolstartpos } }
  | TRUE   { { desc = BoolLit true;   loc = $symbolstartpos } }
  | FALSE  { { desc = BoolLit false;  loc = $symbolstartpos } }
  | STRING { { desc = StringLit $1;   loc = $symbolstartpos } }
  | IDENT { { desc = Var $1; loc = $symbolstartpos } }
  | IDENT LPAREN args RPAREN { { desc = Call ($1, $3); loc = $symbolstartpos } }
  | IDENT COLONCOLON IDENT
    { { desc = EnumVariant ($1, $3); loc = $symbolstartpos } }
  | SIZEOF LPAREN t = type_expr RPAREN
    { { desc = SizeOf t; loc = $symbolstartpos } }
  | OFFSETOF LPAREN t = type_expr COMMA field = IDENT RPAREN
    { { desc = OffsetOf (t, field); loc = $symbolstartpos } }
  | LPAREN e = expr RPAREN { e }
  | e = expr AS t = type_expr
    { { desc = Cast (t, e); loc = $symbolstartpos } }
  | id = IDENT LBRACKET idx = expr RBRACKET
    (* arr[i] -- preserved as Index node; codegen emits bounds check for [T;N] arrays *)
    { { desc = Index (id, idx); loc = $symbolstartpos } }
  | id = IDENT LBRACKET lo = expr DOTDOTLT hi = expr RBRACKET
    (* s[lo..<hi] -- subslice (constant bounds, proven) or slice-from-pointer (unchecked) *)
    { { desc = SliceOf (id, lo, hi); loc = $symbolstartpos } }
  | UNSAFE LBRACE e = expr RBRACE
    (* unsafe { e } -- visibility marker permitting unchecked-assertion constructs in e *)
    { { desc = Unsafe e; loc = $symbolstartpos } }
  | e = expr DOT fname = IDENT
    (* e.field -- struct field read; works for both Struct and *Struct *)
    { { desc = FieldGet (e, fname); loc = $symbolstartpos } }
  | LBRACE fs = args RBRACE
    (* { e, e, ... } -- positional struct literal; requires a type annotation *)
    { { desc = StructLit fs; loc = $symbolstartpos } }

args:
  | /* empty */ { [] }
  | expr rest_args { $1 :: $2 }

rest_args:
  | /* empty */ { [] }
  | COMMA expr rest_args { $2 :: $3 }

let_rhs:
  | /* empty */ { (None, None) }
  | COLON type_expr { (Some $2, None) }
  | COLON type_expr ASSIGN expr { (Some $2, Some $4) }
  | ASSIGN expr { (None, Some $2) }

(* base_type_expr: type expression that does not start with {. Used for the legacy ret_type_opt form (`fn f() int`).
   TypeRefined is excluded here because { would conflict with the function body's LBRACE. *)
base_type_expr:
  | VOID_TYPE { TypeVoid }
  | BOOL_TYPE { TypeBool }
  | I8_TYPE   { TypeI8  } | I16_TYPE { TypeI16 } | I32_TYPE { TypeI32 } | I64_TYPE { TypeI64 }
  | U8_TYPE   { TypeU8  } | U16_TYPE { TypeU16 } | U32_TYPE { TypeU32 } | U64_TYPE { TypeU64 }
  | ISIZE_TYPE { TypeIsize }
  | USIZE_TYPE { TypeUsize }
  | IO         type_expr { TypeIo  $2 }
  | TIMES      type_expr { TypePtr $2 }
  | LBRACKET t = type_expr SEMI n = array_size RBRACKET { TypeArray (t, n) }
  | LBRACKET RBRACKET t = type_expr { TypeSlice (t, 0) }
    (* []T -- slice with no compile-time minimum length *)
  | LBRACKET t = type_expr SEMI n = array_size DOTDOT RBRACKET { TypeSlice (t, n) }
    (* [T; N..] -- slice whose runtime length is at least N *)
  | FN LPAREN fn_type_params RPAREN ARROW type_expr { TypeFn ($3, $6) }
  | FN LPAREN fn_type_params RPAREN                 { TypeFn ($3, TypeVoid) }
  | IDENT { TypeNamed $1 }

(* Array size: a compile-time integer constant expression -- a literal, the
   name of an immutable global constant declared earlier (`let NAME: T =
   N;`), or +/-/*// arithmetic combining those (parentheses allowed for
   grouping), e.g. `[u8; QNUM * RX_BUF_SIZE]` or `[u8; ETH_RX_DESC_COUNT *
   ETH_DESC_SIZE]`. Evaluated directly during parsing into a plain int, the
   same as the single-literal/single-name forms already were -- this only
   widens what counts as a "compile-time integer constant expression" here
   from one token to a small formula, so an array size never has to be a
   hand-computed literal that can silently drift from the constants it was
   computed from (see CLAUDE.md's "Global Constant Folding" section for the
   same drift concern on the *value* side of a global let). No forward
   references: a referenced name must already be in Const_env's table (its
   `let` appeared earlier in the concatenated source). *)
array_size:
  | n = INT   { narrow_int64 $symbolstartpos "array size" n }
  | name = IDENT
    { match Const_env.find name with
      | Some n -> n
      | None ->
          raise (Types.TypeError ($symbolstartpos,
            Printf.sprintf
              "array size '%s' is not a known compile-time integer constant \
               (declare it earlier as an immutable global `let %s: T = N;`)"
              name name)) }
  | SIZEOF LPAREN t = type_expr RPAREN
    { Type_layout.sizeof_type $symbolstartpos t }
  | LPAREN n = array_size RPAREN { n }
  | a = array_size PLUS  b = array_size { a + b }
  | a = array_size MINUS b = array_size { a - b }
  | a = array_size TIMES b = array_size { a * b }
  | a = array_size DIV   b = array_size
    { if b = 0 then
        raise (Types.TypeError ($symbolstartpos,
          "array size expression: division by zero"))
      else a / b }

(* type_expr: base_type_expr + TypeRefined. Used in unambiguous positions such as after : or -> *)
type_expr:
  | base_type_expr { $1 }
  | BORROW t = type_expr { TypeBorrow t }
  | SINK t = type_expr { TypeSink t }
  | LBRACE lo = INT DOTDOTLT hi = INT RBRACE
    { (* Reserved for future contextual base inference. Until the AST and
         signature inference can represent an unresolved refinement base,
         require the programmer to state it instead of retaining the old,
         implicit i32 default. Do not infer the smallest fitting type: that
         would make an innocent range edit silently change ABI width. *)
      raise (Types.TypeError ($symbolstartpos,
        Printf.sprintf
          "refined type {%Ld..<%Ld} requires an explicit base; write \
           {%Ld..<%Ld as i32} (or another integer base)"
          lo hi lo hi)) }
  | LBRACE lo = INT DOTDOTLT hi = INT AS base = int_base_type_expr RBRACE
    { (* Explicit-base {lo..<hi as base} surface syntax: lets a programmer
         write a refined type whose LLVM representation genuinely is
         `base` (i8/i16/i32/i64/u8/u16/u32/u64/isize/usize), rather than only
         ever getting a non-i32 base indirectly through the compiler's
         own range-propagation machinery (Add/Sub/Mul/Band/Mod/min/max/
         narrowing -- see CLAUDE.md's "Refinement Numerical Type"
         section). Needed for a {lo..<hi}-typed FUNCTION PARAMETER: the
         same-base subslice rule requires an argument passed into it to
         unify EXACTLY (bounds and base) against the declared parameter
         type, so as long as {lo..<hi} could only ever spell base=i32,
         any local variable feeding such a parameter -- and everything
         entangled in that same-base proof alongside it -- was forced to
         stay i32 too, even when every one of those values was naturally
         narrower on the wire (see CLAUDE.md's protocol examples for the
         concrete case this unblocks). *)
      check_refined_base_range $symbolstartpos lo hi base;
      TypeRefined (narrow_int64 $symbolstartpos "refined type bound" lo,
                   narrow_int64 $symbolstartpos "refined type bound" hi,
                   base) }

(* Restricted to the primitive integer types {lo..<hi as base} is allowed
   to name -- matches the "by convention" restriction on TRefinedInt's own
   base documented in lib/types.ml (pointers/arrays/structs/etc. make no
   sense as a refined integer's representation). *)
int_base_type_expr:
  | I8_TYPE    { TypeI8 }
  | I16_TYPE   { TypeI16 }
  | I32_TYPE   { TypeI32 }
  | I64_TYPE   { TypeI64 }
  | U8_TYPE    { TypeU8 }
  | U16_TYPE   { TypeU16 }
  | U32_TYPE   { TypeU32 }
  | U64_TYPE   { TypeU64 }
  | ISIZE_TYPE { TypeIsize }
  | USIZE_TYPE { TypeUsize }

fn_type_params:
  | /* empty */                              { [] }
  | type_expr fn_type_params_rest            { $1 :: $2 }

fn_type_params_rest:
  | /* empty */                              { [] }
  | COMMA type_expr fn_type_params_rest      { $2 :: $3 }
