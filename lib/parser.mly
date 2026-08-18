%{
open Ast

(* Prefix runtime qualifiers consume [type_expr], so without this small
   normalization `*T @ place` would build `*(T @ place)`. Singleton values
   are forbidden behind pointers; the useful and documented interpretation
   is instead "the pointer T, indexed by place". Applying the same
   lift through [io] makes `*io T @ place` behave consistently, and
   (GitHub issue #347) through `&`/`&mut` makes `&mut T @ place` mean
   "the reference to T, indexed by place" -- the only reading that is
   meaningful, since an identity is a fact about a reference VALUE and
   `&mut T`'s pointee is not one. Without it a branded API had to be
   spelled with a raw pointer, undoing issue #314 at exactly the call
   sites it was written for. *)
let lift_singleton wrap = function
  | TypeSingleton (base, arg) -> TypeSingleton (wrap base, arg)
  | ty -> wrap ty

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

(* GitHub issue #184: an arm body's LAST statement (for BOTH plain
   `match` and `let mut id: ty = match disc { arms };`) must be `Yield e`
   (this arm's value -- discarded for a plain match, captured for a
   let-match, see type_inf.ml/llvm_gen.ml's own Yield/LetMatch cases) or
   Return/Break/Continue (diverges) -- checked structurally rather than
   via full flow analysis, so a block that diverges only through a
   nested if/match's own tail is conservatively rejected, not silently
   accepted as unsound. Reuses `arm_body`'s own bare-tail-expr production
   (below) for the Yield case -- a bare `expr` with no trailing `;` is
   already how an arm produces a value, so this check only needs to
   confirm the LAST statement's shape, not desugar anything itself. *)
let arm_body_ok stmts =
  match List.rev stmts with
  | { Ast.desc = (Ast.Yield _ | Ast.Return _ | Ast.Break | Ast.Continue); _ } :: _ -> true
  | _ -> false

let validate_arm_bodies pos arms =
  List.iter (fun arm ->
    let stmts = match arm with
      | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmIntLit (_, b) -> b
    in
    if not (arm_body_ok stmts) then
      raise (Types.TypeError (pos,
        "this match arm must end in a value expression, or in \
         return/break/continue to diverge"))
  ) arms;
  arms

(* Display name for an explicit {lo..<hi as base} base, error messages only. *)
let base_type_name = function
  | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32" | TypeI64 -> "i64"
  | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32" | TypeU64 -> "u64"
  | TypeU16Be -> "u16be" | TypeU32Be -> "u32be"
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
  | TypeU16Be -> (0L, Some 65536L)
  | TypeU32   -> (0L, Some 4294967296L)
  | TypeU32Be -> (0L, Some 4294967296L)
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

let check_const_type pos = function
  | TypeI8 | TypeI16 | TypeI32 | TypeI64
  | TypeU8 | TypeU16 | TypeU16Be | TypeU32 | TypeU32Be | TypeU64
  | TypeIsize | TypeUsize -> ()
  | _ ->
      raise (Types.TypeError (pos,
        "`const` declarations are restricted to primitive integer types; \
         use a global `let` for pointers, io registers, arrays, structs, \
         sizeof/offsetof-derived values, or other runtime constants"))

(* `struct packed be Name { field: u16; ... }` sugar (GitHub issue #186):
   every eligible multi-byte integer field is auto-promoted to its `*be`
   type, so a whole wire-format header can be declared endian-aware at
   once instead of writing `u16be`/`u32be` on each field by hand. Only
   plain u16/u32 (bare or refined-over-them) are promoted -- u8 and
   byte-array fields need no swap and are left exactly as written;
   anything else (nested structs, pointers, arrays of other element
   types, ...) is also left alone, matching how a hand-written `u16be`
   field would never appear there either. *)
let promote_be_field_type = function
  | TypeU16 -> TypeU16Be
  | TypeU32 -> TypeU32Be
  | TypeRefined (lo, hi, TypeU16) -> TypeRefined (lo, hi, TypeU16Be)
  | TypeRefined (lo, hi, TypeU32) -> TypeRefined (lo, hi, TypeU32Be)
  | ty -> ty
%}

%token <Int64.t> INT
%token <string> IDENT
%token <string> STRING
%token FN INLINE NOINLINE RETURN CONST LET MUT EXTERN SYMBOL STRUCT OPAQUE AFFINE LINEAR VIEW VARIANT MUST_USE EXISTS BORROW SINK PACKED BE IO ENUM MATCH ALIGN SIZEOF OFFSETOF UNSAFE USE PRIVATE VECTOR_TABLE EXCEPTION_ENTRY EXCEPTION_RESTORE EMBED_FILE
%token TYPE GENERIC
%token DARROW COLONCOLON UNDERSCORE BANG
%token LBRACE RBRACE LPAREN RPAREN LBRACKET RBRACKET COMMA SEMI DOTDOTLT DOTDOT AT
%token ASSIGN DOT
%token IF ELSE WHILE FOR IN BREAK CONTINUE STATIC_ASSERT
%token EOF
%token AMP TILDE

%token LT GT LE GE EQ NE
%token PLUS MINUS TIMES DIV PERCENT
%token OR PIPE HAT SHR SHL DAMP
%token AS
%token PLUS_EQ MINUS_EQ PIPE_EQ AMP_EQ HAT_EQ SHL_EQ SHR_EQ

(* Precedence: low -> high.  UNARY is a pseudo-token for %prec. *)
%right ASSIGN PLUS_EQ MINUS_EQ PIPE_EQ AMP_EQ HAT_EQ SHL_EQ SHR_EQ
                  (* GitHub issue #184: `=` and compound (`+=` etc.) as
                     exprs, LOWEST of all -- `a + b = c` still requires
                     explicit parens around the assignment, matching
                     every other language with this feature (right-
                     associative so `a = b = c` parses, though
                     type_inf.ml rejects it: Assign's own type is TVoid,
                     which never unifies as a valid RHS). The compound-op
                     tokens need a precedence declared here too (not just
                     `%prec ASSIGN` on their own production): without
                     one, Menhir has no basis to resolve shift/reduce
                     between e.g. `expr TIMES expr` and `expr SHR_EQ
                     expr` when SHR_EQ is the lookahead token, which
                     produced real conflicts (confirmed via
                     `dune build`) once compound-op became a genuine
                     infix `expr` operator instead of a token only ever
                     reachable from dedicated, unambiguous `stmt`
                     productions. *)
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
%nonassoc BRACKET_ELSEWHERE
   (* GitHub issue #217 pseudo-token: LOWER than LBRACKET, tagged via
      %prec on the two OTHER grammar spots that also see IDENT/empty
      immediately followed by `[` -- `IDENT` completing a bare
      base_type_expr (vs. extending into `IDENT[args]`, a generic type
      instantiation) and `view_static_args`' empty alternative (vs.
      extending into `[args]`, explicit view arguments). Both want `[`
      to always extend THEM rather than let Index's own now-general
      `expr LBRACKET ...` rule claim it instead -- e.g. `x as T[N]` must
      stay "cast to generic type T[N]", never "(x as T)[N]" (index the
      cast result). Lower than LBRACKET makes shift (extend) win
      deterministically instead of menhy's undeclared-precedence default. *)
%left DOT LBRACKET
   (* highest: field access / indexing -- postfix, binds tighter than prefix
      ops. GitHub issue #217: LBRACKET joined DOT here once Index/SliceOf's
      base became a general expr (previously a bare IDENT could not be
      followed by a binary operator before `[`, so no conflict existed);
      without a declared precedence, `a + b[i]` and every other "binary op
      immediately followed by `[`" shape was an unresolved (if consistently
      shift-favoring) conflict against each `expr -> expr OP expr`
      reduction. Same tier as DOT, matching how postfix `.field` and `[i]`
      already compose with each other with no ordering surprise. *)
%nonassoc TYPE_BASE
%nonassoc AT

%token VOID_TYPE BOOL_TYPE
%token I8_TYPE I16_TYPE I32_TYPE I64_TYPE
%token U8_TYPE U16_TYPE U32_TYPE U64_TYPE ISIZE_TYPE USIZE_TYPE
%token U16BE_TYPE U32BE_TYPE
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

%inline private_flag:
  | /* empty */ { false }
  | PRIVATE     { true }

item:
  | func_def { FuncDef $1 }
  | CONST name = IDENT COLON ty = type_expr ASSIGN n = array_size SEMI
    { let loc = $symbolstartpos in
      if Const_env.is_builtin name then
        raise (Types.TypeError (loc,
          Printf.sprintf
            "'%s' is a compiler-supplied target constant and cannot be redefined"
            name));
      check_const_type loc ty;
      (* Reuses array_size's own IDENT/+/-/*// grammar (GitHub issue #295
         follow-up) instead of only a bare INT: array_size's own IDENT case
         already resolves a previously-declared const by name via
         Const_env.find (the SAME ordering guarantee this const declaration
         itself relies on -- "no forward references", enforced by
         lib/use_resolver.ml's post-order file DFS), and eagerly collapses
         any +/-/*// of two already-resolved operands to a literal. A
         top-level const initializer is never inside a Generic_scope (that
         only exists while parsing a generic struct/function's own body),
         so array_size's ASParam arm -- returned only when a name is
         neither a known Const_env constant nor a Generic_scope value
         parameter -- can never be reached from here; array_size's IDENT
         case raises its own TypeError directly for an unknown name before
         ever returning ASParam in that case. This lets e.g.
         `const KERNEL_SOCKET_FD_MAX: usize = PROCESS_FD_MAX;` or
         `const SHARED_OBJECT_MAX_REFS: usize = PROCESS_CONTEXT_MAX *
         PROCESS_FD_MAX;` replace a manually-duplicated literal that can
         silently drift from what it was meant to equal -- exactly the
         KERNEL_SOCKET_FD_MAX vs PROCESS_FD_MAX drift issue #295's audit
         found. *)
      let literal = match n with
        | Ast.ASLit v -> v
        (* ASSizeof is unreachable here for the same reason ASParam is: it
           is produced only when the type mentions an enclosing generic's
           own type parameter, and a top-level const has no enclosing
           generic. A `sizeof(ConcreteType)` initializer folds to ASLit
           above and is entirely legal. *)
        | Ast.ASParam _ | Ast.ASSizeof _ | Ast.ASAdd _ | Ast.ASSub _
        | Ast.ASMul _ | Ast.ASDiv _ ->
            raise (Types.TypeError (loc,
              Printf.sprintf
                "const '%s' initializer is not a fully resolved compile-time \
                 integer constant" name))
      in
      let e = { desc = IntLit (Int64.of_int literal); loc } in
      Const_env.define_if_literal name (Some e);
      ConstDef (name, ty, e, loc) }
  | p = private_flag LET m = mut_flag IDENT let_rhs SEMI
    { LetDef ($4, fst $5, snd $5, None, m, p, $symbolstartpos) }
  | p = private_flag LET m = mut_flag IDENT COLON type_expr ALIGN LPAREN alignment_value RPAREN SEMI
    { LetDef ($4, Some $6, None, Some $9, m, p, $symbolstartpos) }
  | p = private_flag LET m = mut_flag IDENT COLON type_expr ALIGN LPAREN alignment_value RPAREN ASSIGN expr SEMI
    { LetDef ($4, Some $6, Some $12, Some $9, m, p, $symbolstartpos) }
  | EXTERN FN IDENT LPAREN params RPAREN ret_type_opt effects_opt SEMI
    { ExternFuncDef ($3, $5, $7, $8) }
  | EXTERN SYMBOL IDENT SEMI
    { ExternSymbolDef ($3, $symbolstartpos) }
  | VECTOR_TABLE LBRACE entries = vector_table_entries RBRACE
    { VectorTableDef (entries, $symbolstartpos) }
  | EXCEPTION_ENTRY name = IDENT LBRACE fields = exc_entry_fields RBRACE
    { ExceptionEntryDef (name, fields, $symbolstartpos) }
  | EXCEPTION_RESTORE name = IDENT LBRACE fields = exc_entry_fields RBRACE
    { ExceptionRestoreDef (name, fields, $symbolstartpos) }
  | struct_intro LBRACE struct_fields RBRACE
    { let (name, is_packed, align_opt, is_be) = $1 in
      let fields = List.map (fun (fname, ty, _) ->
        (fname, if is_be then promote_be_field_type ty else ty)) $3 in
      let private_fields =
        List.filter_map (fun (fname, _, is_priv) ->
          if is_priv then Some fname else None) $3 in
      Type_layout.finish_struct name fields is_packed align_opt;
      StructDef (name, fields, is_packed, align_opt, private_fields, $symbolstartpos) }
  | owned_struct_intro LBRACE struct_fields RBRACE
    { let (name, kind, static_params, is_private) = $1 in
      let fields = List.map (fun (fname, ty, _) -> (fname, ty)) $3 in
      let private_fields =
        List.filter_map (fun (fname, _, is_priv) ->
          if is_priv then Some fname else None) $3 in
      Type_layout.finish_struct name fields false None;
      OwnedStructDef
        (name, kind, static_params, fields, false, None, private_fields,
         is_private, $symbolstartpos) }
  | intro = generic_struct_intro LBRACE fields = struct_fields RBRACE
    (* GitHub issue #207: deliberately does NOT call
       Type_layout.begin_struct/finish_struct (unlike struct_intro's own
       production above) -- a field referencing a type parameter (an
       ordinary TypeNamed placeholder at this point) has no size until
       monomorphization substitutes a concrete type. *)
    { let (name, tps) = intro in
      let field_list = List.map (fun (fname, ty, _) -> (fname, ty)) fields in
      let private_fields =
        List.filter_map (fun (fname, _, is_priv) ->
          if is_priv then Some fname else None) fields in
      GenericStructDef (name, tps, field_list, false, None, private_fields,
                         $symbolstartpos) }
  | p = private_flag k = owned_kind VIEW name = IDENT ps = view_static_params SEMI
    { Type_layout.register_view name;
      ViewDef (name, k, ps, p, $symbolstartpos) }
  | p = private_flag OPAQUE STRUCT IDENT SEMI
    { OpaqueStructDef ($4, KindPlain, p, $symbolstartpos) }
  | p = private_flag AFFINE OPAQUE STRUCT IDENT SEMI
    { OpaqueStructDef ($5, KindAffine, p, $symbolstartpos) }
  | p = private_flag LINEAR OPAQUE STRUCT IDENT SEMI
    { OpaqueStructDef ($5, KindLinear, p, $symbolstartpos) }
  | ENUM IDENT COLON base_type_expr LBRACE enum_variants RBRACE
    { let (vs, ne) = $6 in
      Type_layout.register_enum $2 $4;
      EnumDef ($2, Some $4, vs, ne) }
  | ENUM IDENT LBRACE enum_variants RBRACE
    { let (vs, ne) = $4 in
      Type_layout.register_enum $2 TypeU32;
      EnumDef ($2, None, vs, ne) }
  (* GitHub issue #345: the optional `[p: sort, ...]` reuses
     view_static_params (the same "empty or a static_params list" rule
     `view` already has), so an indexed variant's payload can name a
     static parameter -- see Ast.VariantDef. *)
  | VARIANT name = IDENT ps = view_static_params LBRACE cases = variant_cases RBRACE
    { Type_layout.register_variant name cases;
      VariantDef (name, ps, cases, false, $symbolstartpos) }
  | MUST_USE VARIANT name = IDENT ps = view_static_params LBRACE cases = variant_cases RBRACE
    { Type_layout.register_variant name cases;
      VariantDef (name, ps, cases, true, $symbolstartpos) }
  | USE STRING SEMI
    { UseDef $2 }

struct_intro:
  | STRUCT IDENT
    { Type_layout.begin_struct $2;
      ($2, false, None, false) }
  | STRUCT PACKED IDENT
    { Type_layout.begin_struct $3;
      ($3, true, None, false) }
  | STRUCT PACKED BE IDENT
    { Type_layout.begin_struct $4;
      ($4, true, None, true) }
  | STRUCT IDENT ALIGN LPAREN alignment_value RPAREN
    { Type_layout.begin_struct $2;
      ($2, false, Some $5, false) }
  | STRUCT PACKED IDENT ALIGN LPAREN alignment_value RPAREN
    { Type_layout.begin_struct $3;
      ($3, true, Some $6, false) }
  | STRUCT PACKED BE IDENT ALIGN LPAREN alignment_value RPAREN
    { Type_layout.begin_struct $4;
      ($4, true, Some $7, true) }

owned_struct_intro:
  | p = private_flag k = owned_kind STRUCT name = IDENT ps = static_params
    { Type_layout.begin_struct name;
      (name, k, ps, p) }

generic_struct_intro:
  | GENERIC STRUCT name = IDENT LPAREN tps = generic_params RPAREN
    (* Registers this generic struct's own VALUE parameter names (e.g. `N`)
       so array_size's IDENT fallback can recognize them as symbolic --
       accumulates forever (Generic_scope.register, never un-registered),
       not scoped to just this struct's own field list, since a generic
       FUNCTION's parameter list may also need to spell a value parameter
       symbolically (e.g. `data_backing: [T; N..]`) with no per-function
       scope boundary the parser could reliably enter/exit around (a
       plain `fn` has no dedicated grammar marking it generic at parse
       time -- see lib/generic_scope.ml's own header comment). Const
       generics follow-up to GitHub issue #207; whole-program
       registration is the Freelist redesign's own further follow-up. *)
    { Generic_scope.register (List.filter_map (function
        | (n, GPValue _) -> Some n | (_, GPType) -> None) tps);
      (* ...and this struct's own TYPE parameter names, so array_size's
         `sizeof(...)` case can tell "defer, T has no layout yet" from a
         genuine unknown type. See lib/generic_scope.ml's type_table. *)
      Generic_scope.register_types (List.filter_map (function
        | (n, GPType) -> Some n | (_, GPValue _) -> None) tps);
      (name, tps) }

owned_kind:
  | AFFINE { KindAffine }
  | LINEAR { KindLinear }

static_params:
  | LBRACKET ps = separated_nonempty_list(COMMA, static_param) RBRACKET { ps }

(* GitHub issue #207 (const generics follow-up): a generic parameter is
   either kind `type` (T: type) or a plain integer VALUE parameter
   (N: usize), the latter monomorphized -- substituted + mangled per
   concrete value -- exactly like a type parameter is per concrete type. *)
generic_params:
  | ps = separated_nonempty_list(COMMA, generic_param) { ps }

generic_param:
  | name = IDENT COLON TYPE { (name, GPType) }
  | name = IDENT COLON base = int_base_type_expr { (name, GPValue base) }

view_static_params:
  | /* empty */ { [] }
  | ps = static_params { ps }

static_param:
  | name = IDENT COLON sort = static_sort_expr { (name, sort) }

struct_fields:
  | /* empty */ { [] }
  | IDENT COLON type_expr SEMI struct_fields { ($1, $3, false) :: $5 }
  | PRIVATE IDENT COLON type_expr SEMI struct_fields { ($2, $4, true) :: $6 }

vector_table_entries:
  | /* empty */ { [] }
  | n = INT DARROW target = IDENT SEMI rest = vector_table_entries
    { (narrow_int64 $symbolstartpos "vector table slot" n, target) :: rest }

exc_entry_fields:
  | /* empty */ { [] }
  | key = IDENT COLON value = IDENT SEMI rest = exc_entry_fields
    { (key, value) :: rest }

enum_variants:
  | /* empty */                         { ([], false) }
  | UNDERSCORE SEMI enum_variants       { let (vs, _) = $3 in (vs, true) }
  | IDENT ASSIGN INT SEMI enum_variants
    { let (vs, ne) = $5 in
      (($1, Some (narrow_int64 $symbolstartpos "enum discriminant" $3)) :: vs, ne) }
  | IDENT SEMI            enum_variants { let (vs, ne) = $3 in (($1, None)    :: vs, ne) }

variant_cases:
  | /* empty */ { [] }
  | name = IDENT SEMI rest = variant_cases
    { (name, None) :: rest }
  | name = IDENT LPAREN payload = type_expr RPAREN SEMI rest = variant_cases
    { (name, Some payload) :: rest }

func_def:
  | p = private_flag FN IDENT LPAREN params RPAREN ret_type_opt effects_opt LBRACE stmts RBRACE
    {
      Ast.{ name = $3; params = $5; ret_type = $7; effects = $8;
            body = $10; is_inline = false; is_noinline = false; is_private = p;
            def_loc = $symbolstartpos }
    }
  | p = private_flag INLINE FN IDENT LPAREN params RPAREN ret_type_opt effects_opt LBRACE stmts RBRACE
    {
      Ast.{ name = $4; params = $6; ret_type = $8; effects = $9;
            body = $11; is_inline = true; is_noinline = false; is_private = p;
            def_loc = $symbolstartpos }
    }
  | p = private_flag NOINLINE FN IDENT LPAREN params RPAREN ret_type_opt effects_opt LBRACE stmts RBRACE
    {
      Ast.{ name = $4; params = $6; ret_type = $8; effects = $9;
            body = $11; is_inline = false; is_noinline = true; is_private = p;
            def_loc = $symbolstartpos }
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

effects_opt:
  | /* empty */ { None }
  | BANG LBRACE effects RBRACE { Some $3 }

effects:
  | separated_list(COMMA, effect_name) { $1 }

effect_name:
  | IDENT { $1 }
  | UNSAFE { "unsafe" }

stmts:
  | /* empty */ { [] }
  | stmt stmts { $1 :: $2 }

stmt:
  | RETURN e = expr SEMI { { desc = Return (Some e); loc = $symbolstartpos } }
  | RETURN SEMI { { desc = Return None; loc = $symbolstartpos } }
  | e = expr SEMI
    (* GitHub issue #184: any expr, evaluated for effect and discarded --
       generalized from the pre-#184 call-only restriction now that
       assignment is itself an expr (`x = e;` is `Expr (Assign (Var x,
       e))`) and needs an ordinary statement form to appear in. Subsumes
       the old dedicated call-statement production entirely: `expr`
       already has its own Call alternative. *)
    { { desc = Expr e; loc = $symbolstartpos } }
  | LET id = IDENT rhs = let_rhs SEMI
    { { desc = Let (false, id, fst rhs, snd rhs, None); loc = $symbolstartpos } }
  | LET LPAREN id1 = IDENT COMMA id2 = IDENT ids = ident_rest RPAREN ASSIGN e = expr SEMI
    (* let (a, b, ...) = e; -- tuple destructuring, 2+ names
       (OWNERSHIP_KERNEL.md 5.9, GitHub issue #120), the ONLY tuple
       elimination. Same "mandatory second element" shape as above. *)
    { { desc = LetTuple (id1 :: id2 :: ids, e); loc = $symbolstartpos } }
  | LET MUT id = IDENT rhs = let_rhs SEMI
    { { desc = Let (true, id, fst rhs, snd rhs, None); loc = $symbolstartpos } }
  | LET MUT IDENT COLON type_expr ALIGN LPAREN alignment_value RPAREN SEMI
    (* `align(N)` on a local requires `mut`: an immutable local is an SSA
       value with no alloca/memory location for LLVM's set_alignment to
       apply to (unlike a global, which is always memory-backed regardless
       of mutability) -- see SPEC.md's "Local-variable alignment" note. *)
    { { desc = Let (true, $3, Some $5, None, Some $8);
        loc = $symbolstartpos } }
  | LET MUT IDENT COLON type_expr ALIGN LPAREN alignment_value RPAREN ASSIGN expr SEMI
    { { desc = Let (true, $3, Some $5, Some $11, Some $8);
        loc = $symbolstartpos } }
  | LET MUT id = IDENT COLON ty = type_expr ASSIGN MATCH disc = expr
    LBRACE arms = match_arms RBRACE SEMI
    (* let mut id: ty = match disc { arms }; -- GitHub issue #183
       follow-up, now using the shared `match_arms`/`arm_body` grammar
       (see arm_body's own comment): each arm ends in a bare tail `expr`
       (desugars to `Yield e`, this arm's value) or diverges. Unambiguous
       against the ordinary `LET MUT id COLON ty ASSIGN expr SEMI` path
       (let_rhs's own COLON-type_expr-ASSIGN-expr branch): MATCH is not a
       valid start-of-expr token, so one token of lookahead after ASSIGN
       is enough to pick this production instead. *)
    { { desc = LetMatch (true, id, Some ty, disc,
                          validate_arm_bodies $symbolstartpos arms);
        loc = $symbolstartpos } }
  | LET MUT id = IDENT ASSIGN MATCH disc = expr
    LBRACE arms = match_arms RBRACE SEMI
    (* let mut id = match disc { arms }; -- GitHub issue #207: the same
       production as just above, minus the annotation, unambiguous
       against the ordinary `LET MUT id ASSIGN expr SEMI` path
       (let_rhs's own bare-ASSIGN-expr branch) for the identical reason:
       MATCH is not in expr's FIRST set, so one token of lookahead after
       ASSIGN still picks this production. type_inf.ml infers id's type
       from what the arms `Yield`. *)
    { { desc = LetMatch (true, id, None, disc,
                          validate_arm_bodies $symbolstartpos arms);
        loc = $symbolstartpos } }
  | LET id = IDENT COLON ty = type_expr ASSIGN MATCH disc = expr
    LBRACE arms = match_arms RBRACE SEMI
    (* let id: ty = match disc { arms }; -- the non-mut spelling. `id`
       is still alloca-based internally (an arm's yielded value needs a
       memory location to be stored into no matter what), but
       type_inf.ml's LetMatch case downgrades it back to immutable in the
       tyenv that continues past this whole statement, once its own arms
       (which DO need it mutable) have been checked -- so a later
       `id = ...;` outside these arms is rejected exactly like assigning
       to any other non-mut `let` would be. *)
    { { desc = LetMatch (false, id, Some ty, disc,
                          validate_arm_bodies $symbolstartpos arms);
        loc = $symbolstartpos } }
  | LET id = IDENT ASSIGN MATCH disc = expr
    LBRACE arms = match_arms RBRACE SEMI
    (* let id = match disc { arms }; -- GitHub issue #207, the non-mut
       spelling of the annotation-omitted form just above. *)
    { { desc = LetMatch (false, id, None, disc,
                          validate_arm_bodies $symbolstartpos arms);
        loc = $symbolstartpos } }
  | LBRACE first = stmt rest = stmts RBRACE
    (* GitHub issue #184: requires at least one statement (unlike every
       other `{ stmts }` position in this grammar, which stays 0-or-more)
       specifically to break a genuine reduce/reduce ambiguity an EMPTY
       `{}` here would otherwise have against a bare empty struct literal
       `{}` used as a discarded expr-statement (both reduce on the same
       LBRACE-then-immediate-RBRACE token sequence, and this is the one
       stmt position where a nested Block-as-statement and the general
       `expr SEMI` stmt production -- which now includes struct literals
       -- are both reachable) -- confirmed via `dune build` reporting
       zero conflicts with this restriction in place. A deliberately
       empty scope block has no observable effect either way, so
       requiring at least one statement costs nothing in practice. *)
    { { desc = Block (first :: rest); loc = $symbolstartpos } }
  | UNSAFE LBRACE b = stmts RBRACE
    (* GitHub issue #315: unsafe { stmt* } -- block-granularity sibling of
       expr's own `UNSAFE LBRACE e = expr RBRACE` (see below in this same
       grammar). `stmts` is 0-or-more (unlike the plain Block production
       above), since the leading UNSAFE token already disambiguates this
       from a struct-literal-as-statement -- no reduce/reduce conflict to
       avoid here the way bare `{ }` has. *)
    { { desc = UnsafeBlock b; loc = $symbolstartpos } }
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
  (* GitHub issue #344: static_assert(cond); / static_assert(cond, "why");
     -- a compile-time-only check with no runtime form. A statement rather
     than a top-level item so that it can name a generic function's own
     type parameter; see Ast.StaticAssert for the rest of the rationale. *)
  | STATIC_ASSERT LPAREN c = expr RPAREN SEMI
    { { desc = StaticAssert (c, None); loc = $symbolstartpos } }
  | STATIC_ASSERT LPAREN c = expr COMMA m = STRING RPAREN SEMI
    { { desc = StaticAssert (c, Some m); loc = $symbolstartpos } }
  | CONTINUE SEMI { { desc = Continue; loc = $symbolstartpos } }
  | MATCH expr LBRACE match_arms RBRACE
    { { desc = Match ($2, $4); loc = $symbolstartpos } }
  (* Plain `=` and compound (`+=` etc.) assignment (GitHub issue #184)
     are no longer dedicated `stmt` productions -- `x = e;` /
     `arr[i] = e;` / `*p = e;` / `*(expr) = e;` / `x.field = e;` /
     `arr[i].field = e;`, and their compound-op equivalents, are all now
     just `expr SEMI` (the general expr-statement production above).
     Compound assignment was FIRST tried as a separate, bare-IDENT-rooted
     `stmt` production (on the theory that its own distinct compound-op
     tokens would never overlap with `expr`'s start tokens) -- this
     reproduced the same class of conflict `expr SEMI`'s own
     introduction was meant to fix: `id.field` is a valid PREFIX of both
     `expr`'s own FieldGet chain (eventually forming a plain `expr SEMI`
     statement) and the dedicated compound-op production, so the two
     nonterminals still competed for the same tokens. Folding compound
     assignment into `expr` too (below) removes that overlap the same
     way plain assignment's own fold did, confirmed via `dune build`
     reporting zero conflicts with this design. *)

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
  | IDENT COLONCOLON IDENT DARROW LBRACE arm_body RBRACE
    { ArmVariant ($1, $3, None, $6) }
  | IDENT COLONCOLON IDENT LPAREN mutable_ = mut_flag binding = IDENT RPAREN DARROW LBRACE arm_body RBRACE
    { ArmVariant ($1, $3, Some (binding, mutable_), $10) }
  | UNDERSCORE DARROW LBRACE arm_body RBRACE
    { ArmWild $4 }
  | ns = match_int_lits DARROW LBRACE body = arm_body RBRACE
    (* N => { ... }, or N1 | N2 | ... => { ... } -- one or more
       pipe-separated literal-integer patterns sharing one body (GitHub
       issue #156: OCaml-/Rust-style pattern alternation, so several
       syscall numbers etc. can share a handler without duplicating its
       body). This grammar position is a pattern, not `expr`, so `|`
       here never contends with `expr`'s own PIPE-as-bitwise-or rule
       below. *)
    { ArmIntLit (ns, body) }

match_int_lits:
  | n = match_int_lit { [n] }
  | n = match_int_lit PIPE rest = match_int_lits { n :: rest }

match_int_lit:
  | n = INT
    (* narrow_int64 gives the same hard-overflow-is-an-error treatment as
       every other grammar position that needs a realistic native int
       (array size, alignment, enum discriminant, refined type bound). *)
    { narrow_int64 $symbolstartpos "match arm literal" n }
  | MINUS n = INT
    (* -N -- a negative literal pattern (e.g. matching a -1 sentinel),
       mirroring the desugared-unary-minus treatment `-expr` gets in
       ordinary expression position, but resolved directly to a negative
       native int here since a pattern is not a general expression. *)
    { - (narrow_int64 $symbolstartpos "match arm literal" n) }

(* arm_body: a match/let-match arm's body -- ordinary statements
   (reusing `stmt`'s full grammar verbatim: every existing statement form
   works here exactly as it always has, INCLUDING the ones that build an
   `Assign` expr internally, e.g. `x.field = e;`) optionally capped by
   ONE trailing bare `expr` with NO trailing `;` -- the ML/Rust "a
   block's value is its last expression" convention (GitHub issue #184).
   The earlier, abandoned attempt at this exact shape hit real Menhir
   conflicts (struct-literal-vs-block, call-expr-vs-call-stmt, field-
   read-expr-vs-field-assign-stmt) because `stmt` and `expr` had disjoint,
   overlapping-prefix productions for those cases; folding assignment
   (and the old call-only statement form) into `expr` beforehand removes
   every one of those conflicts, confirmed by `dune build` reporting zero
   shift/reduce and zero reduce/reduce conflicts with this final design.
   The bare tail is wrapped as `Yield e`; validate_arm_bodies (above)
   confirms it (or a diverging Return/Break/Continue) is present. *)
arm_body:
  | /* empty */ { [] }
  | e = expr { [ { desc = Yield e; loc = $symbolstartpos } ] }
  | s = stmt rest = arm_body { s :: rest }

expr:
  | e1 = expr ASSIGN e2 = expr %prec ASSIGN
    (* GitHub issue #184: assignment as a genuine expr, LHS unrestricted
       at the grammar level -- type_inf.ml's infer_expr dispatches on
       lhs.desc (Var/FieldGet/Index/Deref; anything else is a clear "not
       an assignable expression" TypeError), matching how Rust's own
       parser accepts a syntactically-any-expr LHS and rejects it
       semantically in a later pass. `expr`'s own existing FieldGet/
       Index/Deref productions already cover every LHS shape the 6 old
       dedicated `stmt`-only Assign/AssignIndex/AssignDeref(x2)/
       AssignField(x2) productions used to (`x`, `arr[i]`, `*p`,
       `*(expr)`, `x.field`, `arr[i].field`) -- this ONE production
       subsumes all of them, which is what removes the grammar-level
       ambiguity a match/let-match arm's tail-expr sugar (arm_body,
       below) used to hit: `expr` and `stmt` no longer have separate,
       overlapping-prefix productions competing for the same tokens. *)
    { { desc = Assign (e1, e2); loc = $symbolstartpos } }
  | e1 = expr op = compound_op e2 = expr %prec ASSIGN
    (* `x += e` sugar for `x = x + e` -- e1 is reused as BOTH the read
       (inside the synthesized BinOp) and the write target (via Assign's
       own LHS-shape dispatch), matching how the pre-#184 dedicated
       compound-op productions already reused the same idx/base
       sub-expression twice (once for the read, once for the store
       address) -- unchanged evaluation-order behavior, just reached via
       a single general production instead of 6 duplicated, LHS-shape-
       specific ones. *)
    { { desc = Assign (e1, { desc = BinOp (op, e1, e2); loc = $symbolstartpos });
        loc = $symbolstartpos } }
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
  | VIEW name = IDENT args = view_static_args
    { { desc = ViewLit (name, args); loc = $symbolstartpos } }
  | IDENT { { desc = Var $1; loc = $symbolstartpos } }
  | IDENT LPAREN args RPAREN { { desc = Call ($1, $3); loc = $symbolstartpos } }
  | IDENT COLONCOLON IDENT
    { { desc = EnumVariant ($1, $3); loc = $symbolstartpos } }
  | IDENT COLONCOLON IDENT LPAREN payload = expr RPAREN
    { { desc = VariantCtor ($1, $3, payload); loc = $symbolstartpos } }
  | SIZEOF LPAREN t = type_expr RPAREN
    { { desc = SizeOf t; loc = $symbolstartpos } }
  | OFFSETOF LPAREN t = type_expr COMMA field = IDENT RPAREN
    { { desc = OffsetOf (t, field); loc = $symbolstartpos } }
  | EMBED_FILE LPAREN path = STRING RPAREN
    { { desc = EmbedFile path; loc = $symbolstartpos } }
  | LPAREN e = expr RPAREN { e }
  | LPAREN e1 = expr COMMA e2 = expr es = rest_args RPAREN
    (* (e1, e2, ...) -- tuple literal, 2+ components (OWNERSHIP_KERNEL.md
       5.9, GitHub issue #120). Same "mandatory second element" shape as
       the tuple-type rule above, for the same reason (rest_args's own
       leading COMMA, reused as-is for elements after e2). Unambiguous
       with the grouping-parens rule just above: that one has no comma. *)
    { { desc = TupleLit (e1 :: e2 :: es); loc = $symbolstartpos } }
  | e = expr AS t = type_expr
    { { desc = Cast (t, e); loc = $symbolstartpos } }
  | b = expr LBRACKET idx = expr RBRACKET
    (* base[i] -- preserved as Index node; codegen emits bounds check for
       [T;N] arrays. GitHub issue #217: base is any expr syntactically
       (so `s.field[i]` parses directly, matching `s.field` itself being
       an ordinary expr via the DOT rule below) -- type_inf.ml restricts
       which shapes are actually legal as an Index base. *)
    { { desc = Index (b, idx); loc = $symbolstartpos } }
  | b = expr LBRACKET lo = expr DOTDOTLT hi = expr RBRACKET
    (* base[lo..<hi] -- subslice (constant bounds, proven) or slice-from-pointer (unchecked) *)
    { { desc = SliceOf (b, lo, hi); loc = $symbolstartpos } }
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

ident_rest:
  | /* empty */ { [] }
  | COMMA id = IDENT ids = ident_rest { id :: ids }

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
  | U16BE_TYPE { TypeU16Be }
  | U32BE_TYPE { TypeU32Be }
  | ISIZE_TYPE { TypeIsize }
  | USIZE_TYPE { TypeUsize }
  | TYPE       { TypeKind }
    (* GitHub issue #207: the pseudo-type of a compile-time type value,
       e.g. `fn freelist_init(T: type, ...)`. No runtime representation. *)
  | IO         type_expr { lift_singleton (fun t -> TypeIo t) $2 }
  | TIMES      type_expr { lift_singleton (fun t -> TypePtr t) $2 }
  | TIMES ALIGN LPAREN n = alignment_value RPAREN t = type_expr
    { lift_singleton (fun t -> TypeAlignedPtr (n, t)) t }
  | LBRACKET t = type_expr SEMI n = array_size RBRACKET
    { match n with
      | Ast.ASLit k -> TypeArray (t, k)
      | sym -> TypeArraySym (t, sym) }
      (* sym is only reachable when the name is a registered generic
         struct value-parameter somewhere in the file (Generic_scope.mem);
         everywhere else array_size's IDENT case already rejects an
         unresolved name at parse time. *)
  | LBRACKET RBRACKET t = type_expr { TypeSlice (t, 0) }
    (* []T -- slice with no compile-time minimum length *)
  | LBRACKET t = type_expr SEMI n = array_size DOTDOT RBRACKET
    { match n with
      | Ast.ASLit k -> TypeSlice (t, k)
      | sym -> TypeSliceSym (t, sym) }
      (* sym is only reachable when the name is a registered generic
         struct value-parameter somewhere in the file, mirroring
         TypeArraySym's own comment at the array production just above. *)
    (* [T; N..] -- slice whose runtime length is at least N *)
  | FN effects_opt LPAREN fn_type_params RPAREN ARROW type_expr
    { TypeFn ($4, $7, $2) }
  | FN effects_opt LPAREN fn_type_params RPAREN
    { TypeFn ($4, TypeVoid, $2) }
  | LPAREN t1 = type_expr COMMA t2 = type_expr ts = fn_type_params_rest RPAREN
    (* (T1, T2, ...) -- tuple type, 2+ components (OWNERSHIP_KERNEL.md 5.9,
       GitHub issue #120). The mandatory t2 both enforces "at least 2
       components" at the grammar level and avoids double-consuming a
       comma against fn_type_params_rest's own leading COMMA (that rest
       nonterminal is "(COMMA type_expr)*", reused as-is for any further
       components after t2). Unambiguous with a plain parenthesized type
       (no such grouping form exists in base_type_expr today) since a
       COMMA is required. *)
    { TypeTuple (t1 :: t2 :: ts) }
  | name = IDENT LBRACKET args = separated_nonempty_list(COMMA, static_arg) RBRACKET
    { TypeIndexed (name, args) }
  | name = IDENT LPAREN args = separated_nonempty_list(COMMA, type_expr) RPAREN
    { TypeGenericInst (name, args) }
    (* GitHub issue #207: Name(T1, T2, ...) -- a generic struct/variant
       instantiated with concrete type arguments, e.g. `Freelist(Page)`.
       Unambiguous against the bare `IDENT -> TypeNamed` rule below (one
       token of lookahead: LPAREN or not) and, deliberately, against the
       TypeIndexed bracket rule just above -- parens for type parameters
       (need monomorphization), brackets stay reserved for today's erased
       *value*-identity static arguments (checker-only, zero runtime
       cost). Keeping these two visually distinct was an explicit design
       goal, not an accident. *)
  | IDENT %prec BRACKET_ELSEWHERE { TypeNamed $1 }
  | n = INT { TypeIntLit (narrow_int64 $symbolstartpos "generic value argument" n) }
    (* Const generics follow-up to GitHub issue #207: a bare integer as a
       TypeGenericInst value argument, e.g. the `3` in `Freelist(usize,
       3)`. Legal syntactically anywhere a type_expr is (INT starts no
       other base_type_expr alternative, so no conflict), but semantically
       meaningful only as a generic value-argument -- Monomorphize.run
       rejects it anywhere else. *)

static_arg:
  | name = IDENT { StaticName name }
  | n = INT { StaticInt (narrow_int64 $symbolstartpos "static integer" n) }
  | enum_name = IDENT COLONCOLON case_name = IDENT
    { StaticEnum (enum_name, case_name) }

view_static_args:
  | /* empty */ %prec BRACKET_ELSEWHERE { [] }
  | LBRACKET args = separated_nonempty_list(COMMA, static_arg) RBRACKET { args }

(* Array size: a compile-time integer constant expression -- a literal, the
   name of an earlier `const NAME: T = N;`, or +/-/*// arithmetic combining those (parentheses allowed for
   grouping), e.g. `[u8; QNUM * RX_BUF_SIZE]` or `[u8; ETH_RX_DESC_COUNT *
   ETH_DESC_SIZE]`. Evaluated directly during parsing into a plain int, the
   same as the single-literal/single-name forms already were -- this only
   widens what counts as a "compile-time integer constant expression" here
   from one token to a small formula, so an array size never has to be a
   hand-computed literal that can silently drift from the constants it was
   computed from (see CLAUDE.md's "Global Constant Folding" section for the
   same drift concern on the *value* side of a global let). No forward
   references: a referenced name must already be in Const_env's table (its
   `const` appeared earlier in the concatenated source). *)
(* Returns Ast.array_size_expr, not a plain int: inside a generic struct's
   own field list, a name may refer to one of ITS OWN not-yet-bound value
   parameters (Generic_scope), which cannot resolve to a literal until
   monomorphization. Every arithmetic action eagerly collapses to ASLit
   when both operands are already ASLit, so ordinary (non-generic) code's
   behavior is byte-for-byte identical to before this widening -- only
   building a symbolic ASAdd/ASSub/ASMul/ASDiv node when a Generic_scope
   name is actually involved. Const generics follow-up to GitHub issue
   #207. *)
array_size:
  | n = INT   { Ast.ASLit (narrow_int64 $symbolstartpos "array size" n) }
  | name = IDENT
    { match Const_env.find name with
      | Some n -> Ast.ASLit n
      | None ->
          if Generic_scope.mem name then Ast.ASParam name
          else raise (Types.TypeError ($symbolstartpos,
            Printf.sprintf
              "array size '%s' is not a known compile-time integer constant \
               (declare it earlier as `const %s: T = N;`)"
              name name)) }
  | SIZEOF LPAREN t = type_expr RPAREN
    (* Eager whenever it can be: for a concrete type the layout is already
       known here, and folding to an ASLit keeps every downstream pass
       seeing a plain integer, exactly as before. A type mentioning the
       enclosing generic's own type parameter has no layout until
       Monomorphize.run binds it, so that case -- and only that case --
       defers to a symbolic ASSizeof, the type-parameter counterpart of
       the ASParam the IDENT case above produces for value parameters. *)
    { if Generic_scope.mentions_type_param t then Ast.ASSizeof t
      else Ast.ASLit (Type_layout.sizeof_type $symbolstartpos t) }
  | LPAREN n = array_size RPAREN { n }
  | a = array_size PLUS  b = array_size
    { match a, b with
      | Ast.ASLit x, Ast.ASLit y -> Ast.ASLit (x + y)
      | _ -> Ast.ASAdd (a, b) }
  | a = array_size MINUS b = array_size
    { match a, b with
      | Ast.ASLit x, Ast.ASLit y -> Ast.ASLit (x - y)
      | _ -> Ast.ASSub (a, b) }
  | a = array_size TIMES b = array_size
    { match a, b with
      | Ast.ASLit x, Ast.ASLit y -> Ast.ASLit (x * y)
      | _ -> Ast.ASMul (a, b) }
  | a = array_size DIV   b = array_size
    { match a, b with
      | Ast.ASLit x, Ast.ASLit y ->
          if y = 0 then
            raise (Types.TypeError ($symbolstartpos,
              "array size expression: division by zero"))
          else Ast.ASLit (x / y)
      | _ -> Ast.ASDiv (a, b) }

alignment_value:
  | n = INT { narrow_int64 $symbolstartpos "alignment" n }
  | name = IDENT
    { match Const_env.find name with
      | Some n -> n
      | None ->
          raise (Types.TypeError ($symbolstartpos,
            Printf.sprintf
              "alignment '%s' is not a known compile-time integer constant"
              name)) }

(* type_expr: base_type_expr + TypeRefined. Used in unambiguous positions such as after : or -> *)
type_expr:
  | base_type_expr %prec TYPE_BASE { $1 }
  | t = base_type_expr AT n = static_arg { TypeSingleton (t, n) }
  | BORROW MUT t = type_expr { TypeBorrowMut t }
  | BORROW t = type_expr { TypeBorrow t }
  | SINK t = type_expr { TypeSink t }
  | AMP MUT t = type_expr { lift_singleton (fun t -> TypeRefMut t) t }
  | AMP t = type_expr { lift_singleton (fun t -> TypeRef t) t }
  | EXISTS name = IDENT COLON sort = static_sort_expr DOT body = type_expr
    { TypeExists (name, sort, body) }
  | LBRACE lo = refined_bound DOTDOTLT hi = refined_bound RBRACE
    { (* Reserved for future contextual base inference. Until the AST and
         signature inference can represent an unresolved refinement base,
         require the programmer to state it instead of retaining the old,
         implicit i32 default. Do not infer the smallest fitting type: that
         would make an innocent range edit silently change ABI width. *)
      raise (Types.TypeError ($symbolstartpos,
        Printf.sprintf
          "refined type {%d..<%d} requires an explicit base; write \
           {%d..<%d as i32} (or another integer base)"
          lo hi lo hi)) }
  | LBRACE lo = refined_bound DOTDOTLT hi = refined_bound AS base = int_base_type_expr RBRACE %prec TYPE_BASE
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
      let lo64 = Int64.of_int lo and hi64 = Int64.of_int hi in
      check_refined_base_range $symbolstartpos lo64 hi64 base;
      TypeRefined (lo, hi, base) }
  | LBRACE lo = refined_bound DOTDOTLT hi = refined_bound AS base = int_base_type_expr RBRACE
      AT n = static_arg
    { let lo64 = Int64.of_int lo and hi64 = Int64.of_int hi in
      check_refined_base_range $symbolstartpos lo64 hi64 base;
      TypeSingleton
        (TypeRefined (lo, hi, base), n) }

refined_bound:
  | n = INT { narrow_int64 $symbolstartpos "refined type bound" n }
  | name = IDENT
    { match Const_env.find name with
      | Some n -> n
      | None ->
          raise (Types.TypeError ($symbolstartpos,
            Printf.sprintf
              "refined type bound '%s' is not a known compile-time integer constant \
               (declare it earlier as `const %s: T = N;`)"
              name name)) }
  | SIZEOF LPAREN t = type_expr RPAREN
    { Type_layout.sizeof_type $symbolstartpos t }
  | LPAREN n = refined_bound RPAREN { n }
  | a = refined_bound PLUS  b = refined_bound { a + b }
  | a = refined_bound MINUS b = refined_bound { a - b }
  | a = refined_bound TIMES b = refined_bound { a * b }
  | a = refined_bound DIV   b = refined_bound
    { if b = 0 then
        raise (Types.TypeError ($symbolstartpos,
          "refined type bound expression: division by zero"))
      else a / b }

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
  | U16BE_TYPE { TypeU16Be }
  | U32_TYPE   { TypeU32 }
  | U32BE_TYPE { TypeU32Be }
  | U64_TYPE   { TypeU64 }
  | ISIZE_TYPE { TypeIsize }
  | USIZE_TYPE { TypeUsize }

(* Static indices are addresses, primitive integers, or values of a closed
   enum. `addr` and enum names both parse as IDENT; the checker distinguishes
   the builtin sort and verifies exhaustive enums without making parsing
   declaration-order-dependent. *)
static_sort_expr:
  | int_base_type_expr { $1 }
  | name = IDENT { TypeNamed name }

fn_type_params:
  | /* empty */                              { [] }
  | type_expr fn_type_params_rest            { $1 :: $2 }

fn_type_params_rest:
  | /* empty */                              { [] }
  | COMMA type_expr fn_type_params_rest      { $2 :: $3 }
