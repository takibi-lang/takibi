type loc = Lexing.position

let pp_loc fmt _ = Format.fprintf fmt "<loc>"

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
[@@deriving show]

type type_expr =
  | TypeBool
  | TypeI8  | TypeI16 | TypeI32 | TypeI64
  | TypeU8  | TypeU16 | TypeU32 | TypeU64
  | TypeIsize                              (* pointer-sized signed integer *)
  | TypeUsize                              (* pointer-sized unsigned integer *)
  | TypeVoid
  | TypePtr of type_expr           (* *T     -- regular pointer, non-volatile *)
  | TypeIo  of type_expr           (* io T   -- volatile-qualified value type; *io T = TypePtr(TypeIo T) *)
  | TypeArray of type_expr * int   (* [T; N] *)
  | TypeFn of type_expr list * type_expr  (* fn(T...) -> R *)
  | TypeNamed of string            (* struct type by name *)
  | TypeIndexed of string * static_arg list
    (* Name[n, ...] -- a runtime named value indexed by erased static
       integers. The named value keeps its ordinary runtime layout; only
       the arguments disappear after type checking. *)
  | TypeSingleton of type_expr * static_arg
    (* T @ n -- a runtime T whose value is the erased static integer n. *)
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
  | TypeBorrow of type_expr        (* parameter-only, non-consuming affine borrow *)
  | TypeSink of type_expr
    (* parameter-only affine "sink": like a plain (owning) affine parameter
       at the call site (the argument IS consumed there), but marks this
       function as the designated terminal consumer of the value, so the
       callee's own body is NOT required to forward/consume it further
       (GitHub issue #89's "sink" design -- see HISTORY.md). *)
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
[@@deriving show]

type static_param = ident * type_expr
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
  | Call of ident * expr list
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
  | Index of ident * expr      (* arr[idx] -- preserves array/pointer type for bounds checking *)
  | SliceOf of ident * expr * expr  (* s[lo..<hi] -- subslice of a slice/array (compile-time
                                       constant bounds, proven against the min length) or
                                       slice construction from a raw pointer (unchecked
                                       assertion; only allowed inside unsafe { ... }) *)
  | Unsafe of expr             (* unsafe { expr } -- permits unchecked-assertion
                                  constructs (pointer -> slice construction) inside.
                                  Changes NO semantics and generates NO code of its
                                  own: it is a visibility marker, gating what the
                                  type checker accepts. *)
  | EnumVariant of string * string  (* EtherType::IPv4 -- enum name, variant name *)
  | SizeOf of type_expr        (* sizeof(T) -- compile-time size in bytes, type usize *)
  | OffsetOf of type_expr * string
      (* offsetof(T, field) -- compile-time field offset in bytes, type usize *)
[@@deriving show]

type stmt = stmt_desc located
and stmt_desc =
  | Return of expr
  | Expr of expr
  | Assign of ident * expr
  | AssignDeref of expr * expr   (* *lhs = rhs -- write through pointer *)
  | AssignField of expr * string * expr  (* base.field = rhs -- write a struct field *)
  | AssignIndex of ident * expr * expr  (* arr[idx] = rhs -- indexed write with bounds check *)
  | Block of stmt list
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
  | Match of expr * match_arm list  (* match expr { EName::V => {...} _ => {...} } *)
and match_arm =
  | ArmVariant of string * string * stmt list  (* EnumName::Variant => { stmts } *)
  | ArmWild    of stmt list                    (* _ => { stmts } *)
[@@deriving show]

type func = {
  name : ident;
  params: (ident * type_expr option) list;
  ret_type : type_expr option;
  body : stmt list;
  is_inline : bool;
  def_loc : loc [@printer pp_loc];  (* location of the "fn" keyword -- used for DWARF DISubprogram *)
}
[@@deriving show]

type opaque_kind = KindPlain | KindAffine | KindLinear
[@@deriving show]

type toplevel =
  | FuncDef of func
  | LetDef of ident * type_expr option * expr option * int option * bool * bool * loc
  (* name, type, init, align_bytes, is_mutable, is_private, loc -- align_bytes = Some N means
     global align(N). is_mutable: `let mut` = true (variable), plain `let` = false (compile-time
     constant). is_private (GitHub issue #108): `private let ...` restricts every reference to
     this global (read or write, via Var/Assign) to expressions/statements whose own source file
     (loc.pos_fname) matches this declaration's own loc -- enforced in type_inf.ml. loc is this
     declaration's own position, needed to know which file "declared" it. *)
  | ExternFuncDef of ident * (ident * type_expr option) list * type_expr option
  (* extern fn name(params) -> ret; -- body is provided by external assembly *)
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
  | OpaqueStructDef of string * opaque_kind * bool * loc
  (* name, kind, is_private, loc -- incomplete nominal type, usable only
     behind a pointer.
     KindAffine: use at most once, must be consumed on at least one path
     (union semantics -- see SPEC.md's Affine Types). KindLinear: use
     exactly once on EVERY path (intersection semantics -- OWNERSHIP_KERNEL.md
     Stage 1, GitHub issue #117); casting a linear value away is rejected.
     is_private (Stage 2, issue #108): value CONSTRUCTION -- any cast whose
     target type mentions this type -- is legal only in loc's file; naming
     the type stays legal everywhere. *)
  | EnumDef of string * type_expr option * (string * int option) list * bool
  (* enum Name: u16 { Variant = val; _; } -- last bool = is_nonexhaustive *)
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
    | Index (_, idx) -> go_expr idx
    | SliceOf (_, lo, hi) -> go_expr lo; go_expr hi
    | IntLit _ | BoolLit _ | StringLit _ | Var _ | EnumVariant _ | SizeOf _
    | OffsetOf _ ->
        ()
  in
  let rec go_stmt (s : stmt) = match s.desc with
    | Assign (n, e)          -> add n; go_expr e
    | AssignIndex (n, i, e)  -> add n; go_expr i; go_expr e
    | AssignDeref (p, e)     -> go_expr p; go_expr e
    | AssignField (b, _, e)  -> go_expr b; go_expr e
    | Let (_, n, _, init, _) -> add n; (match init with
                                        | Some e -> go_expr e | None -> ())
    | LetTuple (ns, e)       -> List.iter add ns; go_expr e
    | Expr e | Return e      -> go_expr e
    | Block ss               -> List.iter go_stmt ss
    | If (c, t, el)          -> go_expr c;
                                List.iter go_stmt t; List.iter go_stmt el
    | While (c, b)           -> go_expr c; List.iter go_stmt b
    | For (n, _, lo, hi, b)  -> add n; go_expr lo; go_expr hi;
                                List.iter go_stmt b
    | ForEach (n, se, b)     -> add n; go_expr se; List.iter go_stmt b
    | Break | Continue       -> ()
    | Match (d, arms)        ->
        go_expr d;
        List.iter (function
          | ArmVariant (_, _, b) | ArmWild b -> List.iter go_stmt b
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
   `K <= s.len`, `K < s.len` with K a bare integer literal. Used by
   if-narrowing to upgrade a slice binding's compile-time minimum length
   within the then-branch (subject to the same written_names kill rule as
   integer range narrowing). Single shared implementation for type_inf.ml
   and llvm_gen.ml -- sync rule, same reasoning as written_names above. *)
let slice_len_mins (cond : expr) : (string * int) list =
  let acc = Hashtbl.create 4 in
  let update name k =
    let prev = match Hashtbl.find_opt acc name with Some p -> p | None -> 0 in
    Hashtbl.replace acc name (max prev k)
  in
  let rec go e = match e.desc with
    | BinOp (And, e1, e2) -> go e1; go e2
    | BinOp (Ge, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ },
                 { desc = IntLit k; _ }) ->
        (match int_of_intlit k with Some k -> update n k | None -> ())
    | BinOp (Gt, { desc = FieldGet ({ desc = Var n; _ }, "len"); _ },
                 { desc = IntLit k; _ }) ->
        (match int_of_intlit k with Some k -> update n (k + 1) | None -> ())
    | BinOp (Le, { desc = IntLit k; _ },
                 { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }) ->
        (match int_of_intlit k with Some k -> update n k | None -> ())
    | BinOp (Lt, { desc = IntLit k; _ },
                 { desc = FieldGet ({ desc = Var n; _ }, "len"); _ }) ->
        (match int_of_intlit k with Some k -> update n (k + 1) | None -> ())
    | _ -> ()
  in
  go cond;
  Hashtbl.fold (fun n k l -> (n, k) :: l) acc []
