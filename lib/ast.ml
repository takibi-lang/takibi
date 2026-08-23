type loc = Lexing.position

let pp_loc fmt _ = Format.fprintf fmt "<loc>"

(* The real source file a loc came from, with any per-instantiation suffix
   removed. lib/monomorphize.ml's relocate_loc appends "#" ^ mangled name
   to pos_fname so that a nested generic call's Types.loc_key stays unique
   across instantiations (see its own comment for why that matters); every
   OTHER consumer of pos_fname wants the file that is actually on disk.
   Getting that wrong is not cosmetic: type_inf.ml's `private` checks all
   compare a use site's file against the declaring file, so before this
   existed, a `private let` global (or `private fn`, or a private struct
   field) referenced from a GENERIC function in its own declaring file was
   rejected as a cross-file access -- the use site's pos_fname had been
   rewritten to "file.tkb#fn$usize" while the declaration's was still
   "file.tkb". A path containing '#' would defeat this, which is why the
   split is on the FIRST occurrence: relocate_loc only ever appends, and
   can append more than once for a nested instantiation. *)
let source_file_of_loc (loc : loc) : string =
  match String.index_opt loc.Lexing.pos_fname '#' with
  | None -> loc.Lexing.pos_fname
  | Some i -> String.sub loc.Lexing.pos_fname 0 i

type 'a located = {
  desc: 'a;
  loc: loc [@printer pp_loc];
} [@@deriving show]

type ident = string
[@@deriving show]

type binop =
  | Add | Sub | Mul | Div | Mod
  | Lt | Gt | Le | Ge | Eq | Ne
  | Or | And | Bor | Bxor | Band | Shr | Shl
[@@deriving show]

type static_arg =
  | StaticName of string
  | StaticInt of int
  | StaticEnum of string * string
    (* Enum::Case -- a nominal finite-state constant used only by the
       checker. Unlike StaticInt, equal runtime discriminants from different
       enums are not interchangeable. *)
[@@deriving show]

type type_expr =
  | TypeBool
  | TypeI8  | TypeI16 | TypeI32 | TypeI64
  | TypeU8  | TypeU16 | TypeU32 | TypeU64
  | TypeU16Be
  | TypeU32Be
    (* u16be/u32be -- 16-/32-bit values stored in big-endian (wire) byte
       order. Deliberately does NOT unify with TypeU16/TypeU32: crossing
       between wire and host order requires an explicit `as` cast (GitHub
       issue #186), the same discipline TypeRefined's own `{lo..<hi as
       base}` already requires to cross representations. See
       lib/types.ml's TU16Be/TU32Be for the unification/subtyping rules
       and lib/type_inf.ml's BinOp case for the narrow set of operators
       (==, !=, &, |, ^, ~) allowed directly on either without a
       conversion. *)
  | TypeIsize                              (* pointer-sized signed integer *)
  | TypeUsize                              (* pointer-sized unsigned integer *)
  | TypeVoid
  | TypePtr of type_expr           (* *T     -- regular pointer, non-volatile *)
  | TypeIo  of type_expr           (* io T   -- volatile-qualified value type; *io T = TypePtr(TypeIo T) *)
  | TypeArray of type_expr * int   (* [T; N] *)
  | TypeFn of type_expr list * type_expr * ident list option
    (* fn [!{effects}](T...) -> R. None means the call effect is unknown;
       Some [] is an explicit non-blocking contract. Checker-only. *)
  | TypeNamed of string            (* struct type by name *)
  | TypeView of string * static_arg list
    (* Elaborated erased view type, including checker-only static indices.
       Source annotations use the declared bare/indexed name; type inference
       resolves it to this distinct constructor so runtime structs and
       Delta-only views cannot be confused. *)
  | TypeVariant of string * static_arg list
    (* Elaborated tagged runtime variant type. Source annotations use the
       declared bare name; payload kind is tracked separately in Delta. *)
  | TypeExists of ident * type_expr * type_expr
    (* exists n: Sort. T[n] -- an erased static binder around a variant
       payload. Sort may be an integer or a finite enum; the payload may be
       an indexed runtime owner or an indexed erased view. *)
  | TypeIndexed of string * static_arg list
    (* Name[n, ...] -- a runtime named value indexed by erased static
       integers. The named value keeps its ordinary runtime layout; only
       the arguments disappear after type checking. *)
  | TypeKind
    (* `type` -- the pseudo-type of a compile-time type value. Valid only
       as a generic parameter's declared type (`fn f(T: type, ...)`) or
       (once monomorphization exists) as a generic function's return type.
       Has no runtime representation at all; a value of this "type" never
       exists at runtime, matching this language's zero-cost-abstraction
       ethos -- unlike TypeIndexed's `[n, ...]` (an erased, checker-only
       *value* identity with zero runtime cost but still a real value),
       TypeKind parameters are resolved away entirely by monomorphization
       before codegen ever runs. GitHub issue #207 (generics). *)
  | TypeGenericInst of string * type_expr list
    (* Name(T1, T2, ...) -- a generic struct/variant instantiated with
       concrete type arguments, e.g. `Freelist(Page)`. Deliberately a
       different grammar shape (parens, not TypeIndexed's brackets) so a
       type parameter (needs monomorphization) and TypeIndexed's erased
       *value*-identity static argument (checker-only, same representation
       as the unindexed type) stay visually and structurally distinct --
       see SPEC.md's "Indexed Runtime Owners" for the existing bracket
       form this is deliberately NOT reusing. GitHub issue #207. *)
  | TypeSingleton of type_expr * static_arg
    (* T @ n -- a runtime integer, pointer, or reference T whose
       value/identity is also available as an erased static argument.

       This wrapper is structurally transparent: SPEC.md says it has the
       same LLVM representation as T. Shape-oriented Ast.type_expr code
       must use strip_singleton below rather than open-coding a match, so
       the transparency rule has one implementation. *)
  | TypeRefined of int * int * type_expr
    (* {lo..<hi} -- refined int: lo <= x < hi. Third field is the
       underlying primitive type (mirrors Types.ty's TRefinedInt -- see
       its comment). Source annotations require `{lo..<hi as base}` with
       an explicit primitive integer base; bare `{lo..<hi}` is reserved for
       future contextual inference and currently rejected. Inference and
       range propagation can construct refined types that preserve an
       operand's existing base. *)
  | TypeSlice of type_expr * int   (* []T / [T; N..] -- fat pointer (ptr + usize len);
                                     int = compile-time MINIMUM length (0 = unknown).
                                      The runtime length is always >= the minimum; index
                                      proofs and constant subslices check against it. *)
  | TypeBorrow of type_expr        (* parameter-only, shared non-consuming borrow *)
  | TypeBorrowMut of type_expr
    (* parameter-only scoped mutable borrow. The callee receives exclusive
       access to the caller's runtime place; ownership remains with caller. *)
  | TypeSink of type_expr
    (* parameter-only kinded "sink": like a plain owning parameter
       at the call site (the argument IS consumed there), but marks this
       function as the designated terminal consumer of the value, so the
       callee's own body is NOT required to forward/consume it further
       (GitHub issue #89's "sink" design -- see HISTORY.md). *)
  | TypeRef of type_expr
    (* &T -- shared, non-arithmetic reference to an owned struct value.
       Structurally distinct from TypePtr (not a qualifier on it), so a
       future raw-pointer unsafe mandate never matches it. Field reads only;
       no arithmetic, no indexing, no casts to/from any other type except a
       free (no-unsafe) widen to *T. GitHub issue #314/#319: v1 is legal
       only as a function parameter or local `let` binding type -- not a
       struct field, global, return type, or array/slice element. Minted
       only via `&lvalue` (AddrOf); never forged. *)
  | TypeRefMut of type_expr
    (* &mut T -- exclusive reference: same restrictions as TypeRef, but
       field writes are also allowed. Does not itself prove no other alias
       of the same place exists concurrently -- see #314/#132 discussion:
       that stronger guarantee is deliberately out of scope here. *)
  | TypeTuple of type_expr list
    (* (T1, T2, ...) -- function-local product (OWNERSHIP_KERNEL.md 5.9,
       GitHub issue #120). Legal in function return types, parameter
       types, and local `let` annotations; rejected in struct fields,
       arrays/slices, globals, and casts (either direction). Kind = join
       of component kinds -- a linear-containing tuple is itself linear. *)
  | TypeAlignedPtr of int * type_expr
    (* *align(N) T -- a pointer PROVABLY a multiple of N bytes, the pointer
       analogue of a refined integer's {lo..<hi as base} (GitHub issue #102
       -- see HISTORY.md/SPEC.md). Structurally parallel to TypePtr, not a
       wrapper like TypeBorrow/TypeSink: align(N) modifies the pointer
       sigil itself, matching the already-existing align(N) local/global
       variable and struct-level syntax. *)
  | TypeIntLit of int
    (* A bare integer literal, legal ONLY as a TypeGenericInst VALUE
       argument (e.g. the `3` in `Freelist(usize, 3)`) -- const generics'
       counterpart to a `type` argument. Never legal anywhere else a
       type_expr can appear; Monomorphize.run unwraps it against a
       Value-kinded generic parameter position and it never reaches
       type_inf.ml/llvm_gen.ml, same contract as TypeKind/TypeGenericInst
       (GitHub issue #207, const-generics follow-up). *)
  | TypeArraySym of type_expr * array_size_expr
    (* [T; SZ] where SZ symbolically references one of the ENCLOSING
       `generic struct`'s own not-yet-bound value parameters (e.g.
       `data: [T; N]` inside `generic struct Freelist(T: type, N: usize)`).
       Only ever produced while parsing a generic struct's own field list
       (lib/generic_scope.ml gates this); Monomorphize.run substitutes N
       with its concrete bound value and rewrites this to an ordinary
       TypeArray before type_inf.ml/llvm_gen.ml ever run -- same contract
       as TypeKind/TypeGenericInst above. *)
  | TypeSliceSym of type_expr * array_size_expr
    (* [T; SZ..] -- the slice-minimum counterpart of TypeArraySym: a
       generic struct's own field whose declared MINIMUM length
       symbolically references one of the struct's own not-yet-bound
       value parameters (e.g. `data: [T; N..]`). Same contract as
       TypeArraySym in every other respect (parser-gated, resolved by
       Monomorphize.run to an ordinary TypeSlice, never reaches
       type_inf.ml/llvm_gen.ml). Freelist redesign follow-up to GitHub
       issue #207: lets a size-mismatched backing slice become a real
       compile-time TSlice-subtyping error instead of silently accepting
       any size (an unconstrained `[]T` field enforces nothing). *)
[@@deriving show]

and array_size_expr =
  (* Mirrors lib/parser.mly's own array_size arithmetic grammar (literal,
     named reference, +/-/*// of those) but keeps a named reference
     symbolic instead of resolving it via Const_env immediately -- needed
     so a generic struct's own value parameter (not yet bound to a
     concrete int until monomorphization) can appear in an array size. *)
  | ASLit of int
  | ASParam of ident
  | ASSizeof of type_expr
    (* sizeof(T) where T mentions one of the ENCLOSING generic's own
       not-yet-bound TYPE parameters, e.g. `storage: [u8; sizeof(T)]`.
       The type-parameter counterpart of ASParam: array_size's SIZEOF
       case evaluates eagerly to an ASLit whenever it can (the common,
       non-generic case), and only defers to this node when eager
       evaluation is impossible because T has no layout yet.
       Monomorphize.run substitutes T and rewrites this to an ordinary
       TypeArray before type_inf.ml/llvm_gen.ml ever run -- the same
       contract TypeArraySym itself has. *)
  | ASAdd of array_size_expr * array_size_expr
  | ASSub of array_size_expr * array_size_expr
  | ASMul of array_size_expr * array_size_expr
  | ASDiv of array_size_expr * array_size_expr
[@@deriving show]

(* TypeSingleton is a checker-only identity wrapper.  Shape-oriented passes
   must opt into seeing through it through this single helper.  Peel one
   layer so callers retain control over recursive traversal. *)
let strip_singleton = function
  | TypeSingleton (base, _) -> base
  | ty -> ty

type static_param = ident * type_expr
(* Static parameter sorts are addr, primitive integers, or exhaustive enums. *)
[@@deriving show]

type generic_param_kind =
  | GPType
  | GPValue of type_expr
    (* the declared base int type, e.g. TypeUsize -- const generics
       follow-up to GitHub issue #207 *)
[@@deriving show]

type expr = expr_desc located
and expr_desc =
  | IntLit of Int64.t
    (* Full 64-bit value (the raw bit pattern of the literal as written --
       see CLAUDE.md's "64-bit Integer Literals" section). Int64.t, not
       `int`: OCaml's native `int` is only 63 bits on a 64-bit host, one bit
       short of holding every u64/i64 bit pattern (e.g. a hex literal with
       the top bit set). Consumers that only ever need a small, realistic
       value (array sizes, alignment, refined-type bounds, range-propagation
       constants) narrow via `int_of_intlit` below rather than assuming the
       value fits. *)
  | BoolLit of bool
  | StringLit of string     (* "..."  -- null-terminated *char constant *)
  | Var of ident
  | ViewLit of ident * static_arg list
    (* `view Name[args]` -- explicitly mint an erased permission value. It
       has no runtime representation; privacy, indices, and kind flow are
       checked later. The brackets are omitted for a non-indexed view. *)
  | Call of ident * expr list
  | VariantCtor of string * string * expr
    (* Name::Case(payload) -- tagged runtime variant construction. Nullary
       cases retain the existing EnumVariant syntax node and are resolved
       against enum/variant declarations during type inference. *)
  | BinOp of binop * expr * expr
  | Bnot of expr               (* ~expr -- bitwise NOT *)
  | Deref of expr           (* *expr  -- read through pointer *)
  | AddrOf of expr          (* &lvalue -- variable or struct field address *)
  | Cast of type_expr * expr  (* expr as T -- explicit type cast *)
  | FieldGet of expr * string  (* expr.field -- read a struct field *)
  | StructLit of expr list     (* { e, e, ... } -- positional struct literal *)
  | TupleLit of expr list      (* (e1, e2, ...) -- 2+ components; a tracked
                                  (affine/linear) component is consumed
                                  exactly when the literal itself flows into
                                  a consuming position (bound/passed/
                                  returned) -- see check_affine_func *)
  | Index of expr * expr
      (* base[idx] -- preserves array/pointer type for bounds checking.
         GitHub issue #217: `base` is syntactically any expr (so
         `s.field[i]` parses without a manual `let` workaround), but
         type_inf.ml's own place-path recovery (see its
         "undecayed_place_type"/index base comment) restricts which
         SHAPES are actually legal here -- a bare variable, a chain of
         FieldGets, or another Index (for `a[i][j]`), never an arbitrary
         expr -- so the un-decayed declared type of an array-typed base
         can always be recovered by direct lookup/struct-field-table walk
         instead of general type inference (which would otherwise decay
         an array field to a bare pointer and lose bounds-check info). *)
  | SliceOf of expr * expr * expr  (* base[lo..<hi] -- subslice of a slice/array (compile-time
                                       constant bounds, proven against the min length) or
                                       slice construction from a raw pointer (unchecked
                                       assertion; only allowed inside unsafe { ... }); `base`
                                       has the same restricted-shape rule as Index above. *)
  | Unsafe of expr             (* unsafe { expr } -- permits unchecked-assertion
                                  constructs (pointer -> slice construction) inside.
                                  Changes NO semantics and generates NO code of its
                                  own: it is a visibility marker, gating what the
                                  type checker accepts. *)
  | EnumVariant of string * string  (* EtherType::IPv4 -- enum name, variant name *)
  | SizeOf of type_expr        (* sizeof(T) -- compile-time size in bytes, type usize *)
  | ContainsStableOwner of type_expr
      (* contains_stable_owner(T) -- 1 if T is, or reaches, stable owner
         storage (a private field whose type is a linear variant); 0
         otherwise. Type usize. Exists so a static_assert can reject a
         type in a position that cannot honour the zero-initialisation
         its empty state depends on -- see GitHub issue #369. *)
  | AlignOf of type_expr
      (* alignof(T) -- compile-time ABI alignment in bytes, type usize.
         Read from the same LLVM DataLayout the emitted code actually
         uses, never from an independent OCaml formula, so it can never
         promise an alignment the generated layout does not deliver. That
         matters today: a struct's own `align(N)` tail-pads its size
         without raising the alignment it is embedded at, so alignof
         reports the real 8 rather than the declared N. *)
  | OffsetOf of type_expr * string
      (* offsetof(T, field) -- compile-time field offset in bytes, type usize *)
  | EmbedFile of string
      (* embed_file("path") -- GitHub issue #230: compile-time file embed.
         Reads the named file (path resolved the same way `use "...";`
         resolves its own paths -- relative to the directory takibi is
         invoked from) at compile time and becomes a `[u8; N]` array
         constant, N the file's real byte size. Deliberately restricted to
         exactly one position: the direct initializer of a top-level
         `let`/`let mut` (type_inf.ml's global-initializer pass special-
         cases it there, the same way it already special-cases a bare
         `Var` initializer; infer_expr's own case for this constructor
         unconditionally rejects it, so any other position -- a local
         `let`, a function argument, nested inside another expression --
         is a clear compile error instead of a confusing one). An explicit
         array-size annotation on the global itself is still allowed and
         gets verified against the real file size like any other typed
         initializer -- the restriction is about POSITION, not annotation
         presence. No general "embed arbitrary compile-time data"
         facility is intended; this exists to replace `.incbin` in a
         hand-written `.S` file with no other author, matching the same
         "generate/embed, don't hand-author and mirror" reasoning behind
         issue #227's exception-frame declarations, applied to blob data
         instead of a register frame. *)
  | Assign of expr * expr
      (* lhs = rhs -- GitHub issue #184: assignment is a genuine expr (not
         a family of statement-only forms), matching Rust's own
         `ExprKind::Assign`. `lhs` may be ANY expr syntactically; type_inf.ml
         dispatches on its shape (Var/FieldGet/Index/Deref) and rejects
         anything else ("not an assignable expression") -- the same
         "accept syntactically, reject semantically in a later pass"
         split Rust's own parser uses for `f() = x`. Always types as
         TVoid (NOT the assigned value's type, unlike C/Rust): this
         sidesteps any question of a linear/affine RHS being "read back"
         through this new expr path -- chained assignment `a = b = c`
         is simply a type error (`c`'s void result not unifying with
         whatever `b`'s own type is), which is fine since nothing needs
         it. Parsed at the LOWEST precedence (below `||`), matching every
         other language with this feature, so `a + b = c` still requires
         explicit parens. Needed so a match/let-match arm's tail
         (Ast.Yield below) can be told apart from an ordinary preceding
         statement with only 1 token of LALR(1) lookahead: when
         assignment was a separate `stmt`-only category, `x.field` (a
         legal PREFIX of both a field-read expr and a field-assign stmt)
         made that decision genuinely ambiguous partway through parsing
         the prefix -- see the GitHub issue for the full conflict
         analysis that grounded this design. *)
[@@deriving show]

(* Parentheses are normally erased by the parser, but the precedence lint
   needs to distinguish `a & b == 0` from the explicitly chosen
   `a & (b == 0)`. Keep that one bit of surface syntax out-of-band so the
   semantic AST remains unchanged. Physical identity is intentional: two
   structurally equal subexpressions at different source sites must not share
   the parenthesized mark. The table is parse-lifetime state and is reset with
   the error list before each compilation/test parse. *)
module PhysicalExpr = Hashtbl.Make (struct
  type t = expr
  let equal a b = a == b
  let hash = Hashtbl.hash
end)

let parenthesized_exprs : unit PhysicalExpr.t = PhysicalExpr.create 32
let precedence_error_sites : (Lexing.position * string) list ref = ref []

let reset_precedence_errors () =
  PhysicalExpr.reset parenthesized_exprs;
  precedence_error_sites := []

let mark_parenthesized e =
  PhysicalExpr.replace parenthesized_exprs e ();
  e

let is_parenthesized e = PhysicalExpr.mem parenthesized_exprs e

let record_precedence_error loc msg =
  precedence_error_sites := (loc, msg) :: !precedence_error_sites

type stmt = stmt_desc located
and stmt_desc =
  | Return of expr option
    (* `return e;` = Some e. `return;` (GitHub issue #153-adjacent fix) =
       None -- only legal inside a function whose declared return type is
       void; see type_inf.ml's own check. *)
  | Expr of expr
      (* Evaluate for effect, discard the value -- GitHub issue #184
         generalized this from "calls only" (the original grammar
         restriction) to any expr, since assignment (now itself an expr,
         see Ast.Assign) needed a way to appear as an ordinary statement:
         `x = e;` is `Expr (Assign (Var x, e))`. The old dedicated
         `stmt`-only Assign/AssignDeref/AssignField/AssignIndex
         constructors are gone -- this is their sole replacement. *)
  | Yield of expr
      (* GitHub issue #184: `Pattern => e;` inside a match/let-match arm
         body -- `e` IS this arm's value. Valid ONLY as an arm body's
         LAST statement (checked structurally by the parser, the same
         way it already checked the pre-#184 `id = e;`-or-diverge
         convention -- see lib/parser.mly). For an ordinary `match`
         STATEMENT, a `Yield e` arm just evaluates `e` and discards it
         (treated like `Expr e`); for `LetMatch`, the yielded value
         becomes the arm's contribution to the bound name. Not reachable
         anywhere else -- unlike Return/Break/Continue, this does not
         participate in general control flow, only in "is this an arm's
         terminal statement" structural checks. *)
  | Block of stmt list
  | UnsafeBlock of stmt list
      (* unsafe { stmt* } -- GitHub issue #315: block-granularity sibling
         of `Unsafe` (the expr form, above). Same grant primitive (widens
         `unsafe_depth` around everything nested inside), just applied to
         a statement list instead of a single expr, so a tight,
         already-justified stretch of code (e.g. a loop body doing
         several unproven index ops under one trust rationale) needs one
         wrap instead of one per operation. Does NOT change `!{unsafe}`'s
         own meaning or requirement -- that stays a per-function audit
         declaration only (see Ast.Unsafe's comment and SPEC.md), never a
         grant by itself; wrapping an entire function body in `unsafe {
         ... }` is how you grant a whole function, not `!{unsafe}` alone. *)
  | Let of bool * ident * type_expr option * expr option * int option  (* is_mutable, name, type, init, align *)
  | If of expr * stmt list * stmt list
  | While of expr * stmt list
  | For of ident * type_expr option * expr * expr * stmt list
      (* for i [: T] in lo..<hi { body } -- the optional T is an explicit
         base-type annotation on the loop counter (e.g. `for i: u8 in
         0..<4 { ... }`), letting the programmer pin the counter's type
         directly instead of relying on inference to guess it from the
         bounds/body usage (which, for the common bare-literal-bounds
         case, cannot: see CLAUDE.md's for-loop sections for why). *)
  | ForEach of ident * expr * stmt list
      (* for x in s { body } -- element iteration over a slice. The slice
         expression is evaluated ONCE at loop entry (snapshot semantics,
         like For's bounds); x is an immutable per-iteration element value.
         Safe by construction: the compiler generates the counter and the
         in-bounds access itself, so no index proof is ever needed. *)
  | LetTuple of ident list * expr
      (* let (a, b) = e; -- destructuring, the ONLY tuple elimination
         (no .0/.1 projection -- that is Stage 3's partial-access
         question). Consumes the tuple; each component becomes a fresh
         immutable binding, kind-tracked via its inferred type. *)
  | Break
  | Continue
  | StaticAssert of expr * string option
      (* static_assert(cond[, "message"]); -- GitHub issue #344. A
         statement, not a top-level item, because the facts worth
         asserting are usually about a GENERIC function's own type
         parameter (`sizeof(Slot(T)) <= PAGE_SIZE - HEADER`), and T is in
         scope nowhere else. Evaluated in llvm_gen.ml after
         monomorphization has substituted concrete types, so a generic
         function is checked once per instantiation and an instantiation
         that never happens is never checked. Emits no code. *)
  | Match of expr * match_arm list
      (* match expr { Name::Case(binding) => {...} Name::None => {...} } *)
  | LetMatch of bool * ident * type_expr option * expr * match_arm list
      (* let [mut] id [: ty] = match disc { arms }; -- GitHub issue #183
         follow-up ("Layer 1": match producing a value for a let binding,
         so a chain of fallible steps reads as flat statements instead of
         nesting one match per step), extended by issue #184's `Yield`
         sugar (see Ast.Yield above): each arm's body ends in `Yield e`
         (this arm's value) or Return/Break/Continue (diverges). The bool
         is the surface `mut` (parser-supplied, mirrors Let's own leading
         bool): internally `id` is ALWAYS alloca-based regardless (a
         `Yield e` arm needs a memory location to store its value into no
         matter what the surface binding claims -- there is no phi-node/
         pure-SSA alternative implemented), so a non-mut LetMatch differs
         from a mut one ONLY in that infer_stmt downgrades `id` back to
         immutable in the tyenv that continues past this statement, once
         its own arms have been checked -- see type_inf.ml's LetMatch
         case. GitHub issue #207 follow-up: `ty` is now `type_expr
         option`, mirroring Ast.Let's own optional annotation -- `None`
         means infer id's type from what the (fully explicit, no
         wildcard) arms `Yield`, via the same TVar/unification machinery
         an ordinary untyped `let` already uses (type_inf.ml's LetMatch
         case seeds a fresh unification variable via Types.of_ast_opt
         instead of the old mandatory Types.of_ast, and Assign's existing
         rule -- reached via rewrite_letmatch_arm_bodies's Yield ->
         `id = e;` rewrite -- unifies it against each arm's yielded
         value). This is deliberately narrower than the still-paused
         GitHub issue #212 "let-else" idea: every arm here stays fully,
         explicitly named, so no wildcard is ever introduced and the
         linear-payload-hiding concern that paused #212 does not apply.

         `arms` are ordinary match_arm bodies (each one's last statement
         checked structurally by the parser, not via full flow analysis
         -- a legitimately-always-diverging block whose last statement is
         itself a nested if/match is rejected as a clear error rather
         than silently accepted). This means type_inf.ml and llvm_gen.ml
         can treat `arms` as a completely ordinary match_arm list and
         reuse the existing Match handling in both files, adding only one
         new `Yield` case each, by recursing on a synthesized `Match
         (disc, arms)` node -- see those files' own LetMatch cases for
         why. Kept as one AST node (not desugared into a separate Let +
         Match at parse time) so `id` stays live in the ENCLOSING scope
         rather than a sub-block's. *)
and match_arm =
  | ArmVariant of string * string * (ident * bool) option * stmt list
      (* Name::Case[(payload_name)] => { stmts }; bool means `mut` binding. *)
  | ArmWild    of stmt list                    (* _ => { stmts } *)
  | ArmIntLit  of int list * stmt list
      (* N => { stmts }, or N1 | N2 | ... => { stmts } -- literal-integer
         match arm (GitHub issue #151), extended with pipe-separated
         alternation so several literals can share one body without
         duplicating it (GitHub issue #156's own syscall-dispatch use
         case, mirroring OCaml's/Rust's own `|` pattern alternation --
         this compiler's own implementation language already uses
         exactly this syntax). The list is never empty. Only legal when
         the discriminant is a primitive integer type or a
         {lo..<hi as base} refinement of one; a `_` wildcard arm is always
         mandatory (an integer's value space is never exhaustively
         listable the way a closed variant/enum's cases are). *)
[@@deriving show]

type func = {
  name : ident;
  params: (ident * type_expr option) list;
  ret_type : type_expr option;
  effects : ident list option;
  (* Checker effect contract. None means inferred/unannotated; Some [] is
     an explicit non-blocking contract; `interrupt` and `exception` mark
     declaration roots whose contracts are checked separately. *)
  body : stmt list;
  is_inline : bool;
  is_noinline : bool;
  is_private : bool;
  (* GitHub issue #269: `private fn` restricts every direct call/function-
     pointer reference to the same source file the function was declared
     in, mirroring `private let`'s existing cross-file check (issue #108) --
     see type_inf.ml's private_functions table and check_private_function_
     access. *)
  def_loc : loc [@printer pp_loc];  (* location of the "fn" keyword -- used for DWARF DISubprogram *)
}
[@@deriving show]

type opaque_kind = KindPlain | KindAffine | KindLinear
[@@deriving show]

type toplevel =
  | FuncDef of func
  | ConstDef of ident * type_expr * expr * loc
  (* const NAME: IntType = LITERAL; -- a named compile-time integer constant.
     Const_env records only these declarations for type-level grammar
     positions such as array sizes, for-loop literal bounds, and refined
     integer bounds. IntType is restricted to primitive integer types;
     pointers/io/arrays/structs remain global `let` territory. Codegen
     currently emits consts as immutable globals too, so ordinary expression
     reads keep working without adding a second runtime constant path. *)
  | LetDef of ident * type_expr option * expr option * int option * bool * bool * loc
  (* name, type, init, align_bytes, is_mutable, is_private, loc -- align_bytes = Some N means
     global align(N). is_mutable: `let mut` = true (variable), plain `let` = false (compile-time
     constant). is_private (GitHub issue #108): `private let ...` restricts every reference to
     this global (read or write, via Var/Assign) to expressions/statements whose own source file
     (loc.pos_fname) matches this declaration's own loc -- enforced in type_inf.ml. loc is this
     declaration's own position, needed to know which file "declared" it. *)
  | ExternFuncDef of ident * (ident * type_expr option) list * type_expr option
      * ident list option
  (* extern fn name(params) -> ret !{effects}; -- body is external. *)
  | ExternSymbolDef of ident * loc
  (* extern symbol name; -- GitHub issue #225. Declares a symbol defined
     elsewhere (hand-written assembly or the linker script) with no Takibi
     type at all: there is nothing to read or write through it, only an
     address. Referencing the bare name evaluates to that address as a
     `usize`, replacing the `adrp x0, sym; add x0, x0, :lo12:sym; ret`
     accessor-function pattern used throughout kernel/arch and kernel/user.
     Deliberately NOT `extern static name: T;` with load/store semantics --
     see the issue for why a typed read-through extern was rejected: the
     compiler cannot verify an assembly-defined region's layout matches a
     declared Takibi type any better than it already can't for ExternFuncDef
     signatures, so a typed version would add surface without adding a
     safety property it does not actually deliver. *)
  | VectorTableDef of (int * ident) list * loc
  (* vector_table { N => target; ... } -- GitHub issue #227 item 2. Declares
     the target-architecture hardware exception vector table: each entry
     names the architectural vector slot N and the function or `extern
     symbol` branched to for it. Checked in type_inf.ml for slot range,
     uniqueness, and exhaustiveness (every slot the target architecture
     defines must be listed exactly once -- how many slots that is is an
     architecture fact, not a language one, so the exact count is validated
     against Target_info, not hardcoded here). Codegen (lib/llvm_gen.ml)
     emits the actual table -- fixed alignment/per-slot spacing that is
     equally an architecture fact (e.g. AArch64's VBAR_ELn requiring 2KB
     table alignment and 128-byte-spaced entries, per the Architecture
     Reference Manual, not something LLVM's target abstractions expose) --
     as target-specific inline assembly, replacing what used to be a
     hand-laid-out table in kernel/arch/arm64/boot/entry.S with no
     compiler-checked coverage. *)
  | ExceptionEntryDef of ident * (string * string) list * loc
  (* exception_entry name { frame: FrameStruct; dispatch: fn_name;
     before: fn_name; } -- GitHub issue #227 item 1, first (prototype)
     slice: generates the raw save-frame/dispatch/restore-frame/eret
     sequence for ONE exception vector's entry point, from a `struct
     packed` frame declaration instead of a hand-written .inc macro pair
     (kernel/arch/arm64/kernel/exception_context.inc's EXC_CONTEXT_SAVE/
     EXC_CONTEXT_RESTORE). `frame` and `dispatch` are required; `before` is
     an optional extra call inserted between save and dispatch (the
     fpsimd-clobber fixture hook el1_current_irq_entry needs, that
     el0_irq_entry does not). Field keys are a closed, unordered set (order
     in source does not matter) -- deliberately reusing struct_fields'
     plain `IDENT COLON IDENT SEMI` shape rather than inventing new keyword
     tokens per key, matching this project's general "no new syntax
     surface beyond what's needed" bias. `dispatch`'s function is called
     with the frame's own stack address (usize) and must return a usize
     (the same or a different frame's address to resume from -- unchanged
     shape from the hand-written version). type_inf.ml validates: `frame`
     names a real struct whose fields are EXACTLY the closed
     x0..x30/sp_el0/elr_el1/spsr_el1/q0..q31/fpsr/fpcr register-name set
     (each with the one correct type), `dispatch`/`before` name real
     functions with the right signature, and no unknown key appears.
     Codegen (lib/llvm_gen.ml) reuses the struct's own Type_layout offsets
     to emit the same stp/ldp/mrs/msr sequence exception_context.inc's
     macros already do, as one self-contained raw assembly blob (same
     `set_module_inline_asm` technique as VectorTableDef, and for the same
     reason: this runs before any calling convention is established, so it
     cannot be an ordinary .tkb function body). Only covers the uniform
     SAVE -> optional before -> dispatch -> RESTORE -> eret shape; the
     several places that call EXC_CONTEXT_RESTORE standalone (process
     resume without a preceding save, e.g. `el0_context_resume`/
     `run_initial_user`/`.Ldata_abort` in kernel/arch/arm64/kernel/
     user_entry.S) are deliberately out of scope for this first slice --
     see HISTORY.md's issue #227 item 1 entry. *)
  | ExceptionRestoreDef of ident * (string * string) list * loc
  (* exception_restore name { frame: FrameStruct; } -- GitHub issue #227
     item 1 follow-up. Generates just the restore-frame/eret half of
     ExceptionEntryDef, for a standalone resume entry point reached via an
     ordinary `bl`/call with the frame's own address already in x0 (AAPCS
     first-argument register), not via a preceding save in the same
     sequence -- exactly `el0_context_resume`'s existing shape
     (kernel/arch/arm64/kernel/user_entry.S), the first (and, so far, only)
     of the three sites ExceptionEntryDef's own comment named as
     out-of-scope that actually fits this pattern: `run_initial_user`
     constructs a synthetic resume state directly from raw entry/stack
     arguments, never from a saved ExceptionFrame, and `.Ldata_abort` is
     inline control flow inside el0_sync_entry's own larger dispatch body,
     not a standalone entry point -- neither is expressible this way.
     Reuses ExceptionEntryDef's own frame-validation (type_inf.ml) and
     restore-codegen (lib/llvm_gen.ml). The generated symbol still needs an
     ordinary `extern fn name(frame_sp: usize) !{noreturn};` declaration
     alongside it for other .tkb code to call it normally (this
     declaration only defines the raw-asm BODY, the same relationship an
     `extern fn` normally has with its assembly-defined body -- just a
     compiler-generated one instead of hand-written). *)
  | StructDef of string * (string * type_expr) list * bool * int option * string list * loc
  (* name, fields, is_packed, align_bytes, private_field_names, loc --
     align_bytes = Some N means type-level align(N). private_field_names
     (OWNERSHIP_KERNEL.md Stage 2, GitHub issue #108): fields listed here
     may be read/written/offsetof'd -- and the struct constructed via a
     struct literal -- only from the file this declaration's loc names.
     Kept as a parallel name list rather than widening the field tuples,
     so Type_layout/codegen/senv consumers stay untouched (privacy is a
     type-checking concern with zero layout footprint). *)
  | OwnedStructDef of string * opaque_kind * static_param list
      * (string * type_expr) list * bool * int option * string list * bool * loc
  (* name, affine/linear kind, erased static parameters, runtime fields,
     layout flags, private field names, is_private, loc. Unlike an opaque
     handle this is a first-class runtime aggregate; only its static
     parameters are erased. *)
  | GenericStructDef of string * (ident * generic_param_kind) list
      * (string * type_expr) list * bool * int option * string list * loc
  (* GitHub issue #207: `generic struct Name(T1: type, ...) { fields }` --
     name, parameters (each either GPType or, since the const-generics
     follow-up, GPValue base -- e.g. `N: usize`), raw fields (a field's
     type_expr may reference a type parameter name as an ordinary
     TypeNamed placeholder, e.g. `data: []T`, or a value parameter's own
     array-size use as a TypeArraySym, e.g. `data: [T; N]`), layout
     flags, private field names, loc. Unlike
     StructDef, this is NEVER laid out at parse time (Type_layout.
     begin_struct/finish_struct are deliberately not called for this
     production -- a type parameter has no size until monomorphization
     substitutes a concrete type for it); Monomorphize.run is the only
     consumer, turning each concrete instantiation actually used into an
     ordinary StructDef under a mangled name before type_inf.ml/llvm_gen.ml
     ever see it. Never reaches type_inf.ml/llvm_gen.ml directly. *)
  | ViewDef of string * opaque_kind * static_param list * bool * loc
  (* name, affine/linear kind, erased static parameters, is_private, loc.
     A view has no fields, size, address, or runtime ABI representation. *)
  | OpaqueStructDef of string * opaque_kind * bool * loc
  (* name, kind, is_private, loc -- incomplete nominal type, usable only
     behind a pointer.
     KindAffine: use at most once; weakening (dropping without consuming) is
     permitted. KindLinear: use exactly once on EVERY path (intersection
     semantics -- OWNERSHIP_KERNEL.md Stage 1, GitHub issue #117). Casting
     either kind away is rejected.
     is_private (Stage 2, issue #108): value CONSTRUCTION -- any cast whose
     target type mentions this type -- is legal only in loc's file; naming
     the type stays legal everywhere. *)
  | EnumDef of string * type_expr option * (string * int option) list * bool
  (* enum Name: u16 { Variant = val; _; } -- last bool = is_nonexhaustive *)
  | VariantDef of string * static_param list
      * (string * type_expr option) list * bool * loc
  (* [must_use] variant Name[p: sort, ...] { None; Some(T); } -- closed
     tagged sum. The static parameter list (GitHub issue #345) is erased
     exactly like an indexed owner struct's own: it adds no field and no
     ABI word, and exists so a case payload can name it -- which is what
     lets a fallible operation return an owner branded to the resource
     that produced it (see issue #344's pool). Empty for every variant
     that does not use the feature, which is all of them today. Each
     case has at most one directly supported payload in Slice 3. The bool is
     true for `must_use variant`: a checker-only obligation requiring every
     produced value to be handled or transferred on every path, without
     pretending the status value owns a linear runtime resource. *)
  | UseDef of string
  (* use "path/to/file.tkb"; -- GitHub issue #55. Path is resolved relative
     to the compiler's own working directory (the same convention already
     used for every file named on the command line), not to the file the
     `use` appears in. Consumed entirely by Use_resolver (see that
     module's header comment) before type inference ever runs -- by the
     time a UseDef item reaches type_inf.ml/llvm_gen.ml, it carries no
     further meaning and both simply skip over it, matching how every
     other whole-program pass in this codebase treats a toplevel item it
     doesn't care about. Must appear before any other item in its file
     (Use_resolver.resolve enforces this with a dedicated error, not a
     silent no-op) -- see that module for why. *)
[@@deriving show]

let show_toplevel_list lst =
  String.concat "\n" (List.map show_toplevel lst)

(* Narrow an IntLit's Int64 payload to a native `int`, safely: OCaml's `int`
   is 63 bits on a 64-bit host, one bit short of Int64.t, so a plain
   `Int64.to_int` can silently wrap a genuinely-64-bit value (e.g. a hex
   literal with the top bit set) into the wrong native int with no warning
   -- exactly the class of silent-miscompilation risk this project already
   guards against elsewhere (see CLAUDE.md's `{lo..<hi}` i32-range check and
   the Mod/lo>=0 sync rule). Round-tripping through Int64 detects this: if
   converting back doesn't reproduce the original value, the conversion
   would have lost information, so this returns None instead.
   Every caller of this function is a small-number-scoped subsystem (array
   sizes, alignment, enum discriminants, refined-type bounds, range
   propagation, narrowing) that only ever needs to reason about realistic
   values (buffer sizes, bit positions, comparison constants) -- None means
   "fall back to the conservative/unproven case", the same way an ordinary
   non-constant runtime expression already does at each of those call
   sites, never a hard error. *)
let int_of_intlit (k : Int64.t) : int option =
  let i = Int64.to_int k in
  if Int64.of_int i = k then Some i else None

(* Names a statement list may write to or rebind:
   - direct assignment targets (x = e, x[i] = e; compound assignments are
     already desugared to these in the parser)
   - &x anywhere in an expression (once aliased, any later *p = v may write
     x without naming it)
   - let re-declarations and for-counter names (a fresh binding under the
     same name must not inherit an outer binding's narrowing)

   This is the invalidation pre-scan for if-condition range narrowing: a
   name in this set must NOT be narrowed to {lo..<hi} for the branch body,
   because the body can change the value after the condition was evaluated
   -- `if (v >= 0 && v < 8) { v = 100; buf[v] = ...; }` must keep its
   bounds check. Conservative by design: a write anywhere in the body
   kills narrowing for the whole body (no before/after distinction).

   Sync rule: type_inf.ml (narrow_from_cond) and llvm_gen.ml
   (apply_narrowing / apply_narrowing_mut) must both consult this same
   function. If only one side skips a variable, the two disagree and the
   elision becomes unsound -- same class of rule as the Mod range
   propagation's lo >= 0 guard (see CLAUDE.md). *)
let written_names (stmts : stmt list) : string list =
  let acc = Hashtbl.create 8 in
  let add n = Hashtbl.replace acc n () in
  let rec go_expr (e : expr) = match e.desc with
    | AddrOf { desc = Var n; _ } -> add n
    | AddrOf e1 | Bnot e1 | Deref e1 | Cast (_, e1) | FieldGet (e1, _)
    | Unsafe e1 ->
        go_expr e1
    | BinOp (_, a, b) -> go_expr a; go_expr b
    | Call (_, args) | StructLit args | TupleLit args -> List.iter go_expr args
    | VariantCtor (_, _, payload) -> go_expr payload
    | Index (base, idx) -> go_expr base; go_expr idx
    | SliceOf (base, lo, hi) -> go_expr base; go_expr lo; go_expr hi
    | Assign (lhs, rhs) ->
        (* GitHub issue #184: mirrors the old dedicated Assign/AssignIndex/
           AssignDeref/AssignField stmt cases exactly (same names added,
           same sub-expressions walked), now dispatched by the unified
           expr's LHS shape instead of 4 separate AST constructors. *)
        (match lhs.desc with
         | Var n -> add n
         | Index (base, idx) ->
             (* GitHub issue #217: base is now any restricted-shape expr,
                not just a bare ident -- mirror FieldGet's own "walk the
                base, add nothing by name" behavior unless the base IS a
                bare Var (the common, previously-only-possible case),
                where invalidating that name's narrowing is still correct. *)
             (match base.desc with Var n -> add n | _ -> go_expr base);
             go_expr idx
         | Deref p -> go_expr p
         | FieldGet (b, _) -> go_expr b
         | _ -> go_expr lhs);
        go_expr rhs
    | IntLit _ | BoolLit _ | StringLit _ | Var _ | ViewLit _
    | EnumVariant _ | SizeOf _ | AlignOf _ | ContainsStableOwner _
    | OffsetOf _ | EmbedFile _ ->
        ()
  in
  let rec go_stmt (s : stmt) = match s.desc with
    | Let (_, n, _, init, _) -> add n; (match init with
                                        | Some e -> go_expr e | None -> ())
    | LetTuple (ns, e)       -> List.iter add ns; go_expr e
    | Expr e | Return (Some e) | Yield e -> go_expr e
    | Return None            -> ()
    | Block ss | UnsafeBlock ss -> List.iter go_stmt ss
    | If (c, t, el)          -> go_expr c;
                                List.iter go_stmt t; List.iter go_stmt el
    | While (c, b)           -> go_expr c; List.iter go_stmt b
    | For (n, _, lo, hi, b)  -> add n; go_expr lo; go_expr hi;
                                List.iter go_stmt b
    | ForEach (n, se, b)     -> add n; go_expr se; List.iter go_stmt b
    | Break | Continue       -> ()
    | StaticAssert (e, _)    -> go_expr e
    | Match (d, arms)        ->
        go_expr d;
        List.iter (function
          | ArmVariant (_, _, binding, b) ->
              Option.iter (fun (name, _) -> add name) binding;
              List.iter go_stmt b
          | ArmWild b -> List.iter go_stmt b
          | ArmIntLit (_, b) -> List.iter go_stmt b
        ) arms
    | LetMatch (_, n, _, d, arms) ->
        add n; go_expr d;
        List.iter (function
          | ArmVariant (_, _, binding, b) ->
              Option.iter (fun (name, _) -> add name) binding;
              List.iter go_stmt b
          | ArmWild b -> List.iter go_stmt b
          | ArmIntLit (_, b) -> List.iter go_stmt b
        ) arms
  in
  List.iter go_stmt stmts;
  Hashtbl.fold (fun n () l -> n :: l) acc []

(* Decompose a subslice bound into (base variable, constant offset) when it
   has that syntactic shape: `v`, `v + k`, or `k + v`. Used by the
   same-base subslice rule in type_inf.ml and llvm_gen.ml (sync rule --
   single shared implementation): s[v + j ..< v + k] has length exactly
   k - j, and lo <= hi holds iff j <= k, regardless of v's runtime value.
   This is the one depth-1 "difference constraint" protocol code actually
   needs (the TCP options skip: frame[data_off ..< data_off + 3]), obtained
   syntactically -- no relational abstract domain, no solver.
   Callers must exclude io-qualified base variables: the two bound
   expressions load v twice, and a volatile v could change between the
   loads, silently breaking lo <= hi. *)
let var_plus_const (e : expr) : (ident * int) option =
  match e.desc with
  | Var v -> Some (v, 0)
  | BinOp (Add, { desc = Var v; _ }, { desc = IntLit k; _ }) ->
      (match int_of_intlit k with Some k -> Some (v, k) | None -> None)
  | BinOp (Add, { desc = IntLit k; _ }, { desc = Var v; _ }) ->
      (match int_of_intlit k with Some k -> Some (v, k) | None -> None)
  | _ -> None

(* Slice length lower bounds proven by an if condition: [(name, min_len)].
   Recognized shapes (joined by &&): `s.len >= K`, `s.len > K`,
   `K <= s.len`, `K < s.len`, and equality in either order, with K a
   statically resolved integer. Used by
   if-narrowing to upgrade a slice binding's compile-time minimum length
   within the then-branch (subject to the same written_names kill rule as
   integer range narrowing). Single shared implementation for type_inf.ml
   and llvm_gen.ml -- sync rule, same reasoning as written_names above.

   `resolve_bound` is injected because ast.ml cannot depend on the type and
   layout environments needed to resolve target-independent sizeof/offsetof
   expressions. Its default preserves the original literal/const behavior;
   type inference and codegen pass matching resolvers so neither side can
   prove a wider class than the other. `resolve_const` remains separate for
   callers which only have Const_env's name table. *)
let slice_len_mins ?(resolve_const = fun (_ : string) -> None)
    ?resolve_bound
    (cond : expr) : (string * int) list =
  let acc = Hashtbl.create 4 in
  let update name k =
    let prev = match Hashtbl.find_opt acc name with Some p -> p | None -> 0 in
    Hashtbl.replace acc name (max prev k)
  in
  let default_bound e = match e.desc with
    | IntLit k -> int_of_intlit k
    | Var name -> resolve_const name
    | _ -> None
  in
  let bound_of = match resolve_bound with
    | Some f -> f
    | None -> default_bound
  in
  let rec go e = match e.desc with
    | BinOp (And, e1, e2) -> go e1; go e2
    | BinOp (Ge, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }, rhs) ->
        (match bound_of rhs with Some k -> update n k | None -> ())
    | BinOp (Gt, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }, rhs) ->
        (match bound_of rhs with Some k -> update n (k + 1) | None -> ())
    | BinOp (Le, lhs, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }) ->
        (match bound_of lhs with Some k -> update n k | None -> ())
    | BinOp (Lt, lhs, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }) ->
        (match bound_of lhs with Some k -> update n (k + 1) | None -> ())
    | BinOp (Eq, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }, rhs)
    | BinOp (Eq, rhs, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }) ->
        (match bound_of rhs with Some k -> update n k | None -> ())
    | _ -> ()
  in
  go cond;
  Hashtbl.fold (fun n k l -> (n, k) :: l) acc []
