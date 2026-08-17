open Types

module StringSet = Set.Make (String)

(* GitHub issue #310: used to scope guard_narrow_hints' own append to
   error messages that actually name the "unproven" failure shape,
   without needing a structured exception variant just for that check. *)
let contains_substring haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let compiler_builtins = StringSet.of_list [
  "slice_copy"; "slice_eq"; "stable_replace"; "min"; "max";
  "dma_publish"; "dma_consume"; "device_fence"; "signal_fence";
  "interrupt_wait"; "interrupt_notify";
  "dma_prepare_tx"; "dma_prepare_rx"; "dma_finish_rx";
  "checked_add_usize"; "checked_mul_usize";
  (* GitHub issue #226: a closed, enumerated set of system-register/barrier/
     TLBI intrinsics, to lift kernel/arch/arm64/kernel/timer.S and most of
     kernel/arch/arm64/mm/mmu.S into .tkb. Each name is exactly one AArch64
     instruction with registers chosen by LLVM's own allocator (see
     lib/llvm_gen.ml) -- never a user-supplied asm string or register
     choice, unlike general inline assembly (an explicit non-goal of #226:
     issue #209's second bug was a human picking the wrong register by
     hand). Deliberately not one generic `msr(reg_enum, value)` primitive:
     that would need a new base type, for no real benefit over enumerating
     the ~15 registers this kernel actually touches as plain names, matching
     the existing dma_publish/dma_consume/device_fence one-name-per-
     operation precedent above. No barrier is bundled into any of these:
     TTBR0_EL1 writes alone need different barrier sequences at different
     call sites (a fresh MMU activation's full TLB flush vs. an ASID-tagged
     root switch's lighter one), so which barrier follows which write stays
     ordinary, reviewable .tkb policy built on top of these raw primitives,
     not a compiler-hardcoded choice. *)
  "mrs_cntfrq_el0"; "mrs_cntpct_el0"; "mrs_sctlr_el1";
  (* GitHub issue #227 item 3: the four read-only registers
     el1_exception_evidence's fail-stop path needs to move it into ordinary
     .tkb, added to this same closed set. *)
  "mrs_esr_el1"; "mrs_far_el1"; "mrs_elr_el1"; "mrs_spsr_el1";
  "msr_cntp_tval_el0"; "msr_cntp_ctl_el0"; "msr_sctlr_el1";
  "msr_mair_el1"; "msr_tcr_el1"; "msr_ttbr0_el1";
  "msr_daifclr_irq"; "msr_daifset_irq";
  "tlbi_vmalle1"; "tlbi_vaae1is"; "tlbi_vae1is"; "tlbi_aside1is";
  "dsb_ish"; "dsb_ishst"; "isb";
  "smc4"; "hvc4"; "svc5";
]

let is_compiler_builtin name = StringSet.mem name compiler_builtins

let rec count_var_occurrences name (e : Ast.expr) =
  let count_all xs = List.fold_left (fun n x ->
    n + count_var_occurrences name x) 0 xs in
  match e.desc with
  | Ast.Var other -> if other = name then 1 else 0
  | Ast.Call (callee, args) ->
      (if callee = name then 1 else 0) + count_all args
  | Ast.VariantCtor (_, _, payload) -> count_var_occurrences name payload
  | Ast.BinOp (_, left, right) ->
      count_var_occurrences name left + count_var_occurrences name right
  | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x | Ast.Cast (_, x)
  | Ast.FieldGet (x, _) | Ast.Unsafe x -> count_var_occurrences name x
  | Ast.StructLit xs | Ast.TupleLit xs -> count_all xs
  | Ast.Index (base, index) ->
      count_var_occurrences name base + count_var_occurrences name index
  | Ast.SliceOf (base, lo, hi) ->
      count_var_occurrences name base
      + count_var_occurrences name lo + count_var_occurrences name hi
  | Ast.Assign (lhs, rhs) ->
      count_var_occurrences name lhs + count_var_occurrences name rhs
  | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.ViewLit _
  | Ast.EnumVariant _ | Ast.SizeOf _ | Ast.OffsetOf _ | Ast.EmbedFile _ -> 0

(* Type environment: immutable map from variable name to (type, is_mutable) *)
type tyenv = (ty * bool) StringMap.t

(* Struct environment: maps struct name to (ordered field list, is_packed,
   align_bytes) -- is_packed/align_bytes are needed by const_type_size/
   const_field_offset below (see their comment for why). *)
type senv = ((string * Ast.type_expr) list * bool * int option) StringMap.t

(* Static names written in one function share a rigid scope while its body
   is checked. Function signatures stored in fenv use a separate rigid
   scope and are instantiated freshly at each call site. *)
let active_static_scope : static_scope option ref = ref None
let value_static_identities : static_term StringMap.t ref = ref StringMap.empty
(* Per-function identities for the stable syntactic places supported by the
   first addr slice: &name and &name.field chains. *)
let place_static_identities : static_term StringMap.t ref = ref StringMap.empty
let active_readonly_borrows : StringSet.t ref = ref StringSet.empty
let function_param_modes : Ast.type_expr option list StringMap.t ref =
  ref StringMap.empty

(* GitHub issue #296: names any statement in the CURRENT (innermost)
   enclosing statement list writes to (Ast.written_names -- already used
   by if-condition narrowing's own then-branch kill logic, and already
   correctly covers nested Assigns, &mut aliasing, and same-name `let`
   re-declarations, not just a bare top-level `name = e;`). Set by each
   statement-list fold site (Block, function body, If's then/else,
   While/For/ForEach's body, Match/LetMatch arms) to written_names of
   the list about to be folded, save/restore around that fold exactly
   like active_static_scope above -- so by the time a NESTED If's own
   continuation-narrowing logic reads this ref, it reflects the
   INNERMOST enclosing list, correctly modeling lexical nesting.
   Consulted ONLY by the If case below, to decide whether a MUTABLE
   binding's early-return-guard narrowing can survive into the
   fallthrough continuation without risking a later sibling assignment
   invalidating it -- see that case's own comment for why the mut-only
   restriction this ref replaces was needed in the first place, and why
   this is sound (deliberately over-approximate: it uses "written
   ANYWHERE in the enclosing list", not the precise suffix after this
   exact If, which only ever makes narrowing MORE conservative, never
   less). *)
let enclosing_future_writes : StringSet.t ref = ref StringSet.empty

(* GitHub issue #328: mirrors lib/llvm_gen.ml's own unsafe_use_marker/
   unsafe_lint_active mechanism (that file's own "unnecessary unsafe" lint,
   GitHub issue #315), but for the PURE type-checker-level unsafe gates
   (check_kinded_ptr_cast_needs_unsafe, check_aligned_ptr_cast_needs_unsafe,
   check_io_ptr_cast_needs_unsafe, check_io_ptr_literal_needs_unsafe) that
   llvm_gen.ml's own codegen-side marker cannot see on its own -- those are
   pure type-checker rejections with no codegen footprint to hook a
   note_unsafe_use() call into. This was a real, repeated bug source (see
   issue #328's own history: the *io category needed a codegen-side
   note_unsafe_use() call independently rediscovered and placed at the
   right spot TWICE, in two different code shapes, for the SAME
   type-checker-level requirement -- and the affine/linear-opaque-cast
   category had NO coverage at all, a gap SPEC.md explicitly documented).
   Every check_*_needs_unsafe function now records into
   type_checker_unsafe_use_marker (via note_type_checker_unsafe_use) at
   the exact point it decides unsafe_depth > 0 satisfies its requirement --
   no codegen-side involvement needed, so any FUTURE check_*_needs_unsafe
   gate gets correct lint coverage automatically, by construction.

   type_checker_consumed_unsafe_at then records, per statement/expression
   location, whether anything AT OR UNDER that location consumed one of
   these type-checker-only justifications -- populated below by
   fold_stmts_with_future_writes (per statement, mirroring llvm_gen.ml's
   own run_stmts_with_future_writes) and by infer_expr's Unsafe case (as a
   single unit, mirroring llvm_gen.ml's own Unsafe-expr codegen case).
   lib/llvm_gen.ml's existing "unnecessary unsafe" report sites consult
   this table as an ADDITIONAL OR'd-in signal (see its own comment at
   record_unnecessary_unsafe's call sites), so a statement/expression whose
   ONLY justification is one of these type-checker-only categories is not
   wrongly flagged "unnecessary" by llvm_gen.ml's own, codegen-blind
   marker -- the false positive this issue's own history describes. This
   file never reads type_checker_consumed_unsafe_at itself. *)
let type_checker_unsafe_use_marker = ref 0
let note_type_checker_unsafe_use () = incr type_checker_unsafe_use_marker
let type_checker_lint_active = ref false
let type_checker_consumed_unsafe_at : (Lexing.position, unit) Hashtbl.t =
  Hashtbl.create 16

(* Drop-in replacement for `List.fold_left f init stmts` that keeps
   enclosing_future_writes correct at every step. Sets it to
   written_names of the SUFFIX strictly after the statement about to be
   processed (never the statement itself or anything before it) --
   critical, since Ast.written_names' own Let case adds the declared
   name to its result (by design, for narrow_from_cond's kill-set use;
   see its own comment), so using it over the WHOLE list (this file's
   first attempt) flagged a variable as "future-written" by its OWN
   declaring `let`, permanently defeating narrowing for every local.
   Re-set fresh before EVERY element rather than saved/restored around
   the whole fold: a nested statement's own recursive use of this same
   function (its own If/Block/etc. case processing a nested body) freely
   overwrites the ref for its own duration and this function's next step
   simply overwrites it again with the CORRECT value for this list's own
   next position -- no stack or restore needed, since every genuine use
   site (the If case below) captures the ref's value into a local BEFORE
   recursing into its own then/else bodies, rather than re-reading the
   ref afterward once nested processing may have left it in an unrelated
   state. *)
let fold_stmts_with_future_writes
    (f : 'a -> Ast.stmt -> 'a) (init : 'a) (stmts : Ast.stmt list) : 'a =
  let rec go acc = function
    | [] -> acc
    | s :: rest ->
        enclosing_future_writes := StringSet.of_list (Ast.written_names rest);
        (* GitHub issue #328: this is the single choke point every
           statement list in this file passes through (Block, UnsafeBlock,
           If's branches, While, For, ...), mirroring exactly why
           llvm_gen.ml hooks its own per-statement "unnecessary unsafe"
           check into its analogous run_stmts_with_future_writes rather
           than at each individual statement-list call site. Only active
           inside an UnsafeBlock (type_checker_lint_active, set there) --
           a statement outside any unsafe scope can never be "unnecessarily
           unsafe", so checking it would be meaningless overhead. *)
        let acc' =
          if !type_checker_lint_active then begin
            let before = !type_checker_unsafe_use_marker in
            let acc' = f acc s in
            if !type_checker_unsafe_use_marker <> before then
              Hashtbl.replace type_checker_consumed_unsafe_at s.loc ();
            acc'
          end else f acc s
        in
        go acc' rest
  in
  go init stmts

let view_kinds : (string, Ast.opaque_kind) Hashtbl.t = Hashtbl.create 8
let view_params : (string, Ast.static_param list) Hashtbl.t = Hashtbl.create 8
let variant_defs : (string, (string * Ast.type_expr option) list) Hashtbl.t =
  Hashtbl.create 8
let variant_kinds : (string, Ast.opaque_kind) Hashtbl.t = Hashtbl.create 8
let must_use_variants : (string, unit) Hashtbl.t = Hashtbl.create 8

let rec resolve_declared_type = function
  | Ast.TypeNamed name when Hashtbl.mem view_kinds name -> Ast.TypeView (name, [])
  | Ast.TypeIndexed (name, args) when Hashtbl.mem view_kinds name ->
      Ast.TypeView (name, args)
  | Ast.TypeNamed name when Hashtbl.mem variant_defs name -> Ast.TypeVariant name
  | Ast.TypePtr t -> Ast.TypePtr (resolve_declared_type t)
  | Ast.TypeIo t -> Ast.TypeIo (resolve_declared_type t)
  | Ast.TypeArray (t, n) -> Ast.TypeArray (resolve_declared_type t, n)
  | Ast.TypeFn (args, ret, effects) ->
      Ast.TypeFn
        (List.map resolve_declared_type args, resolve_declared_type ret, effects)
  | Ast.TypeRefined (lo, hi, base) ->
      Ast.TypeRefined (lo, hi, resolve_declared_type base)
  | Ast.TypeSlice (t, n) -> Ast.TypeSlice (resolve_declared_type t, n)
  | Ast.TypeBorrow t -> Ast.TypeBorrow (resolve_declared_type t)
  | Ast.TypeBorrowMut t -> Ast.TypeBorrowMut (resolve_declared_type t)
  | Ast.TypeSink t -> Ast.TypeSink (resolve_declared_type t)
  | Ast.TypeRef t -> Ast.TypeRef (resolve_declared_type t)
  | Ast.TypeRefMut t -> Ast.TypeRefMut (resolve_declared_type t)
  | Ast.TypeAlignedPtr (n, t) -> Ast.TypeAlignedPtr (n, resolve_declared_type t)
  | Ast.TypeTuple ts -> Ast.TypeTuple (List.map resolve_declared_type ts)
  | Ast.TypeSingleton (t, n) -> Ast.TypeSingleton (resolve_declared_type t, n)
  | Ast.TypeExists (name, sort, body) ->
      Ast.TypeExists (name, resolve_declared_type sort,
                      resolve_declared_type body)
  | t -> t

let of_ast_in_decl_scope scope t =
  of_ast_in_scope scope (resolve_declared_type t)

let of_ast t = match !active_static_scope with
  | Some scope -> of_ast_in_decl_scope scope t
  | None -> Types.of_ast (resolve_declared_type t)

let of_ast_opt = function Some t -> of_ast t | None -> fresh ()

type region_return_kind = RegionSlice | RegionPointer

let region_return_annotation = function
  | Ast.TypeSingleton (((Ast.TypeSlice _) as base), arg) ->
      Some (base, arg, RegionSlice)
  | Ast.TypeSingleton (((Ast.TypePtr _ | Ast.TypeAlignedPtr _) as base), arg) ->
      Some (base, arg, RegionPointer)
  | _ -> None

let region_kind_word = function
  | RegionSlice -> "slice"
  | RegionPointer -> "pointer"

(* An authority-derived region annotation on a slice or pointer RETURN type
   (`-> [u8; 1514..] @ desc` / `-> *Shared @ lock`)
   is checker-only: it feeds the region_return side table consumed by
   check_affine_func's taint tracking, and must stay invisible to HM
   unification, call_returns, the singleton machinery, and codegen. Strip
   it here -- these two ret_of_ast_opt* helpers are the ONLY places a
   FuncDef's raw ret_type enters HM typing, so any future new consumer of
   the raw AST return type must strip too. *)
let strip_region_return = function
  | Some t ->
      (match region_return_annotation t with
       | Some (base, _, _) -> Some base
       | None -> Some t)
  | None -> None

let ret_of_ast_opt t =
  match strip_region_return t with Some t -> of_ast t | None -> TVoid

let of_ast_opt_in_decl_scope scope = function
  | Some t -> of_ast_in_decl_scope scope t
  | None -> fresh ()

let ret_of_ast_opt_in_decl_scope scope t =
  match strip_region_return t with
  | Some t -> of_ast_in_decl_scope scope t
  | None -> TVoid

let indexed_struct_params : (string, Ast.static_param list) Hashtbl.t =
  Hashtbl.create 8

let indexed_struct_kinds : (string, Ast.opaque_kind) Hashtbl.t =
  Hashtbl.create 8

let field_type_for_instance sname args field_ast =
  match Hashtbl.find_opt indexed_struct_params sname with
  | None -> Types.of_ast (resolve_declared_type field_ast)
  | Some formals ->
      if List.length formals <> List.length args then
        raise (Unify_error (Printf.sprintf
          "static argument count mismatch for %s: expected %d, got %d"
          sname (List.length formals) (List.length args)));
      let scope = create_static_scope () in
      List.iter2 (fun (name, _) value -> bind_static scope name value)
        formals args;
      of_ast_in_decl_scope scope field_ast

let struct_instance = function
  | TStruct s -> Some (s, [])
  | TIndexedStruct (s, args) -> Some (s, args)
  | TPtr (TStruct s) | TPtr (TIo (TStruct s))
  | TAlignedPtr (_, TStruct s)
  | TRef (TStruct s) | TRefMut (TStruct s) -> Some (s, [])
  | _ -> None

(* sizeof(T)/offsetof(T, field) are only ever a genuine OCaml-computable
   compile-time constant here when the layout cannot depend on
   target-specific DataLayout: fixed-width primitive integers/bool, fixed
   -size arrays of such, and PACKED structs (with no align(N) -- tail
   padding is a deliberately deferred extension, not a hard limit; see
   the GitHub issue #77 fix this was added for) composed entirely of such
   fields, recursively. Every other type (pointers, usize/isize, enums,
   non-packed structs, aligned structs) keeps sizeof/offsetof's existing
   plain TUsize type, unrefined -- exactly the pre-existing behavior,
   deferring the actual value to codegen's DataLayout lookup as before.
   This computation is later re-verified against the real DataLayout in
   lib/llvm_gen.ml (sync rule, like every other type_inf/llvm_gen pair in
   this project) rather than trusted silently. *)
let rec const_type_size (senv : senv) (ty : Ast.type_expr) : int option =
  match ty with
  | Ast.TypeBool | Ast.TypeU8 | Ast.TypeI8 -> Some 1
  | Ast.TypeU16 | Ast.TypeI16 | Ast.TypeU16Be -> Some 2
  | Ast.TypeU32 | Ast.TypeI32 | Ast.TypeU32Be -> Some 4
  | Ast.TypeU64 | Ast.TypeI64 -> Some 8
  | Ast.TypeArray (elem, n) ->
      (match const_type_size senv elem with
       | Some sz -> Some (sz * n)
       | None -> None)
  | Ast.TypeSingleton (base, _) -> const_type_size senv base
  | Ast.TypeNamed name | Ast.TypeIndexed (name, _) ->
      (match StringMap.find_opt name senv with
       | Some (fields, true, None) ->
           List.fold_left (fun acc (_, fty) ->
             match acc, const_type_size senv fty with
             | Some a, Some b -> Some (a + b)
             | _ -> None
           ) (Some 0) fields
       | _ -> None)
  | _ -> None

(* Cumulative byte offset of `field` within packed struct `sname`, i.e.
   const_type_size of every field strictly before it. Tail padding from
   align(N) is irrelevant here even in principle (it is only ever
   appended AFTER the last real field -- see lib/llvm_gen.ml's Pass 0
   comment), but this still requires align_opt = None, matching
   const_type_size's scope exactly so the two never disagree about which
   structs are "safe". *)
let const_field_offset (senv : senv) (sname : string) (field : string) : int option =
  match StringMap.find_opt sname senv with
  | Some (fields, true, None) ->
      let rec go = function
        | [] -> None
        | (fname, _) :: _ when fname = field -> Some 0
        | (_, fty) :: rest ->
            (match const_type_size senv fty, go rest with
             | Some a, Some b -> Some (a + b)
             | _ -> None)
      in go fields
  | _ -> None

(* Enum environment: maps enum name to (underlying_ast_type, [(variant_name, value)]) *)
type eenv = (Ast.type_expr * (string * int) list) StringMap.t

let lookup_binding loc name env =
  match StringMap.find_opt name env with
  | Some b -> b
  | None   -> raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" name))

let lookup loc name env = fst (lookup_binding loc name env)

(* io T is a storage qualifier; strip it to get the value type for expression checks *)
let strip_io t = match repr t with TIo inner -> inner | _ -> t

let rec strip_singleton t = match repr t with
  | TSingleton (base, _) -> strip_singleton base
  | t -> t

let unify_at loc t1 t2 =
  try unify t1 t2
  with Unify_error msg -> raise (TypeError (loc, msg))

(* GitHub issue #100 follow-up: a bare integer literal's inferred type is a
   polymorphic, unbound type variable (see IntLit's own case below,
   `fresh ()`), so `unify_at` alone lets it bind STRUCTURALLY against any
   refined target -- e.g. `let v: {0..<8 as usize} = 20;` -- without ever
   checking whether the literal's actual VALUE fits {lo..<hi}. That is a
   genuine soundness hole, not just a missing diagnostic: downstream code
   (an array index, a narrowed subslice, ...) trusts `v`'s declared
   {0..<8} range to elide its own bounds check, so an out-of-range literal
   silently "proving" a range it doesn't satisfy lets --forbid-trap accept
   code with a real, unchecked out-of-bounds access at runtime. Checked
   here at every site where a literal-or-Const_env-constant expression
   flows into an already-known target type (Let, Assign, AssignDeref,
   AssignIndex, AssignField, Return, Call arguments, StructLit fields) --
   reuses Const_env.bound_value, the same "is this expression a
   compile-time-known integer" resolver already used throughout this file
   (e.g. collect_bounds's range_of), so bare literals and named constants
   are both covered identically. A non-constant expression (a variable, a
   computed value) is left alone: unify's existing anti-subtyping guard
   (`t1, TRefinedInt (lo, hi, base) when t1 = repr base -> ...`) already
   correctly rejects an unproven plain-base value flowing into a refined
   target, so there is nothing extra to check there.

   TBool branch added while fixing check_cond's own instance of this same
   root cause (`while (1)` silently "type-checking" then crashing at
   codegen, see check_cond's comment): the exact same unbound-type-variable
   hole means `let x: bool = 1;`, `return 1;` from a `-> bool` function,
   `f(1)` for a `bool` parameter, a `bool`-typed struct field initialized
   with `1`, etc. ALL silently accept an integer literal today, for the
   identical reason -- confirmed by hand (`let x: bool = 1;` compiles with
   no error, pre-existing and independent of check_cond). Every one of
   those flows into an already-known target type through one of this
   function's own existing call sites, so adding one match arm here closes
   all of them at once rather than needing a separate fix at each site.
   Unlike the TRefinedInt case, there is no "value fits the range" check to
   make -- ANY integer literal is invalid for a bool target, so this
   rejects unconditionally once Const_env.bound_value confirms `e` really
   is a compile-time integer (not, say, an already-bool-typed expression
   that happens to reach this function with a TBool target, which
   Const_env.bound_value correctly returns None for). *)
let check_literal_fits_refined loc (e : Ast.expr) (target : ty) =
  match strip_singleton target with
  | TRefinedInt (lo, hi, _) ->
      (match Const_env.bound_value e with
       | Some k when k < lo || k >= hi ->
           raise (TypeError (loc, Printf.sprintf
             "constant value %d does not fit the refined type {%d..<%d}"
             k lo hi))
       | _ -> ())
  | TBool ->
      (match Const_env.bound_value e with
       | Some k ->
           raise (TypeError (loc, Printf.sprintf
             "cannot use integer literal %d where bool is expected; use true/false"
             k))
       | None -> ())
  | _ -> ()

let rec static_place_key (e : Ast.expr) =
  match e.desc with
  | Ast.Var name -> Some name
  | Ast.FieldGet (base, field) ->
      Option.map (fun key -> key ^ "." ^ field) (static_place_key base)
  (* GitHub issue #158: `arr[idx]` is a valid stable_replace container base
     when `idx` is itself a valid place (a bare variable, or a field/index
     chain rooted in one) -- e.g. `fat_fd_table[slot].lock` and
     `fat_fd_table[slot].state` are "the same syntactic container" exactly
     when both occurrences spell the same `slot`, proven here by string
     equality of the combined key, the same structural-identity argument
     the existing Var/FieldGet cases already rest on (not by resolving
     `idx`'s actual runtime value, which this function never attempts).
     An `idx` that is NOT itself a place (e.g. a computed expression like
     `i + 1`) returns None here, same as any other unsupported place
     shape -- stable_replace's own caller must bind it to a variable
     first, matching how every other place in this function already
     requires a syntactically simple base. *)
  | Ast.Index (base, idx) ->
      (match static_place_key base, static_place_key idx with
       | Some base_key, Some idx_key -> Some (base_key ^ "[" ^ idx_key ^ "]")
       | _ -> None)
  | _ -> None

let static_identity_for_place place =
  match static_place_key place with
  | None -> fresh_rigid_static ()
  | Some key ->
      (match StringMap.find_opt key !place_static_identities with
       | Some identity -> identity
       | None ->
           let identity = rigid_static ("&" ^ key) in
           place_static_identities :=
             StringMap.add key identity !place_static_identities;
           identity)

let key_has_prefix prefix key =
  String.length key > String.length prefix
  && String.sub key 0 (String.length prefix) = prefix

let key_has_substring needle key =
  let nl = String.length needle and kl = String.length key in
  let rec go i = i + nl <= kl && (String.sub key i nl = needle || go (i + 1)) in
  nl > 0 && go 0

(* GitHub issue #158: an Index place key embeds its index sub-key inside
   brackets (static_place_key's own `id ^ "[" ^ idx_key ^ "]"`), e.g.
   "fat_fd_table[slot]" or "fat_fd_table[slot].sub". Reassigning `slot`
   must invalidate every cached identity keyed on ANY array indexed by
   it, not just a key literally equal to or prefixed by "slot" -- the
   existing prefix-only check would miss "fat_fd_table[slot]" entirely
   (it neither equals "slot" nor starts with "slot."), which would let a
   stale rigid identity survive a reassignment between a guard's
   construction and its use. Two markers cover both "slot is the whole
   index" and "slot is the base of a longer index projection". *)
let key_has_index_ref name key =
  key_has_substring ("[" ^ name ^ "]") key
  || key_has_substring ("[" ^ name ^ ".") key

let invalidate_place_binding name =
  let prefix = name ^ "." in
  place_static_identities := StringMap.filter (fun key _ ->
    key <> name && not (key_has_prefix prefix key)
    && not (key_has_index_ref name key)
  ) !place_static_identities

let invalidate_place_projections name =
  let prefix = name ^ "." in
  place_static_identities := StringMap.filter (fun key _ ->
    not (key_has_prefix prefix key)
    && not (key_has_index_ref name key)
  ) !place_static_identities

(* A singleton parameter introduces a static name for the runtime argument.
   Literals carry their exact static integer; an already-singleton value
   preserves its identity; every other expression receives a fresh hidden
   identity. That hidden term can escape in an indexed return type. *)
let adapt_actual_to_expected (tyenv : tyenv) (e : Ast.expr)
    (actual : ty) (expected : ty) : ty =
  match repr expected, repr actual with
  | TSingleton _, TSingleton _ -> actual
  | TSingleton (expected_base, _), _ ->
      let is_address = match repr expected_base with
        | TPtr _ | TAlignedPtr _ -> true
        | _ -> false
      in
      let identity_for_immutable_name ~is_address name =
        match StringMap.find_opt name tyenv with
        | Some (_, false) ->
            (match StringMap.find_opt name !value_static_identities with
             | Some identity -> identity
             | None ->
                 let identity =
                   if is_address then rigid_static name
                   else fresh_named_rigid_static name
                 in
                 value_static_identities :=
                   StringMap.add name identity !value_static_identities;
                 identity)
        | _ -> fresh_rigid_static ()
      in
      let n =
        if is_address then
          match e.desc with
          | AddrOf place -> static_identity_for_place place
          | Var name -> identity_for_immutable_name ~is_address:true name
          | _ -> fresh_rigid_static ()
        else
          match Const_env.bound_value e with
          | Some k -> SConst k
          | None ->
              (match e.desc with
               | Var name -> identity_for_immutable_name ~is_address:false name
               | _ -> fresh_rigid_static ())
      in
      TSingleton (actual, n)
  | _ -> actual

(* -- Expression inference -------------------------------------------------- *)

(* True for all unsigned integer types (including usize) *)
let is_unsigned_ty = function
  | TU8 | TU16 | TU32 | TU64 | TUsize -> true
  | _ -> false

(* min/max's "unknown bound" placeholder (see the Call case below) must
   itself be a legal value of whichever base type the result unifies
   against, or a fully-unconstrained call fails to type-check for no real
   reason: types.ml's TRefinedInt subtyping rules reject bounds wider than
   a narrow type's own representable range (u8 needs hi <= 256, u16 needs
   hi <= 65536, i8/i16 need |lo|/hi within their own range), so one fixed
   magic constant everywhere is only safe for i32/i64/u32/u64/usize, not
   u8/u16/i8/i16. Clamp per base instead. Sync rule: lib/llvm_gen.ml's
   min/max codegen mirrors this exactly (base must be repr'd first --
   see the Call case's own comment on why). *)
let min_max_sentinel base =
  match base with
  | TI8  -> (-128, 128)
  | TI16 -> (-32768, 32768)
  | TU8  -> (0, 256)
  | TU16 -> (0, 65536)
  | t when is_unsigned_ty t -> (0, 1_000_000_000)
  | _ -> (-1_000_000_000, 1_000_000_000)

(* if/while/&&/|| conditions must be bool, matching Rust/Zig -- no C-style
   implicit int-truthy coercion. Previously fell back to `unify_at loc ct
   TI32` for anything non-bool (originally just to let `while (1)` work as
   an infinite-loop idiom), but that fallback only ever unified against
   TI32 specifically -- u8/u32/u64/usize conditions were ALREADY rejected
   ("cannot unify u32 with i32"), so it was never truly a general
   C-style-truthy rule, just an inconsistent i32-only special case with no
   real hardware-interfacing benefit (MMIO/register checks in this
   codebase already always write an explicit bit-mask/comparison, e.g.
   `if ((ocr & 0x80000000) != 0)` in sdmmc.tkb, never relied on this
   fallback). Removing it closes off the classic C `if (x = 5)`
   assignment-vs-comparison-typo class of bug at compile time, matching
   this project's "detect errors at compile time" design principle.
   `while (1)`-style infinite loops now write `while (true)` instead (see
   CLAUDE.md's decision log).

   A bare (or bare-arithmetic, e.g. `1 + 1`) integer LITERAL needs its own
   explicit branch, not just `unify_at ct TBool`: per IntLit's own case
   above (`fresh ()`, "polymorphic: unifies with any integer type via
   context"), a literal's inferred type is a genuinely UNCONSTRAINED type
   variable, which happily unifies STRUCTURALLY with TBool even though a
   literal is never actually a legitimate bool value -- the same class of
   soundness gap check_literal_fits_refined exists to close for refined
   targets (see that function's own comment), just for a boolean target
   instead of a numeric range. Left unchecked, `while (1)` would silently
   "type-check" (the unresolved TVar binds to TBool) and then crash at
   codegen instead (`as_cond` receiving an i32 constant where an i1 was
   promised) -- found by testing this exact case by hand after this
   change, not by an existing test. A CONCRETE non-bool type (a real
   variable/expression whose type was pinned by something else, e.g. `x:
   i32`) is not affected -- unify_at already rejects those correctly
   ("cannot unify i32 with bool"), so only the genuinely-unresolved case
   needs its own branch here. *)
let check_cond loc ct =
  match strip_singleton ct with
  | TVar { contents = Unbound _ } ->
      raise (TypeError (loc,
        "condition must be bool -- a bare integer literal has no boolean \
         value; use `true`/`false` or an explicit comparison"))
  | _ -> unify_at loc ct TBool

(* Widen TRefinedInt to its OWN base type; leave explicit-width types
   unchanged. Used by arithmetic ops that do not propagate range
   information (Mul, Div, shifts, bitwise). Without this, `i: {0..<8}` in
   `i * 4` would produce TRefinedInt(0,8,base) and later cause
   `base >> TRefinedInt` to fail the unification anti-subtyping guard.
   Widening to the refined value's OWN base (not unconditionally TI32) is
   what makes this correct now that a refined range can be tied to any
   primitive type: `u64_i: {0..<8}:u64` in `u64_i * 4` must widen to TU64,
   not TI32 -- widening to the wrong (narrower or differently-signed) type
   would either lose information or produce a bogus unify error against
   the other, genuinely-u64-typed operand. *)
let canon_ty t =
  match strip_singleton t with TRefinedInt (_, _, base) -> base | t -> t

(* Require an integer type, WITHOUT defaulting a genuinely-unconstrained
   type variable -- only reject it if it's already resolved to something
   CONCRETE and non-integer (e.g. `buf[some_bool_var]`); an unresolved
   TVar is left alone, deferring to whatever resolves it later (more body
   usage, e.g. a for-loop counter passed to a function elsewhere in the
   loop) or, failing that, to Types.to_ast's `TVar (Unbound _) ->
   TypeI32` end-of-pipeline default. Used everywhere an index/loop-bound
   -shaped value is required (Index, AssignIndex, SliceOf, For): unlike
   TRefinedInt (which enjoys unconditional leniency into TI32 via its own
   subtyping rule), a BARE concrete type like TU8/TUsize/TI64 has no such
   rule, so a plain `unify_at loc t TI32` alone wrongly rejects, e.g., a
   for-loop counter over `s.len` (TUsize, not wrapped in TRefinedInt when
   the length isn't a compile-time constant) used as an array index -- a
   real gap found while generalizing For's loop-counter base (see
   CLAUDE.md's "Refinement Numerical Type" section).

   Originally this ALSO defaulted an unresolved TVar to i32 immediately,
   right here -- but that defeated deferred, usage-driven inference for a
   for-loop counter the MOMENT the body indexed anything with it
   (`buf[i]`), since Index calls this same function: the counter's shared
   type variable would get defaulted right there, before any LATER
   body statement (e.g. `foo(i)` with a concrete-typed parameter) ever
   got a chance to pin it. Removing the eager default here is safe for
   Index/AssignIndex/SliceOf too: none of their own downstream logic
   actually depends on an index's type being concrete (Index/AssignIndex
   only care about the CONTAINER's type; SliceOf's bound_range already
   has a graceful "unknown range" fallback for exactly this case) -- see
   CLAUDE.md's "For-Loop Counters..." follow-up section for the full
   story and its one honest limitation. *)
let require_integer loc t =
  let base = canon_ty t in
  match repr base with
  | TVar { contents = Unbound _ } -> ()
  | TI8 | TI16 | TI32 | TI64 | TU8 | TU16 | TU32 | TU64 | TIsize | TUsize -> ()
  | _ -> raise (TypeError (loc,
      Printf.sprintf "expected an integer type, got '%s'" (to_string t)))

(* Require an [T; N]/slice INDEX be usize specifically -- narrower than
   require_integer.
   Mirrors Rust/Zig, where array/slice Index is only ever implemented for
   usize: a value proven safe in some OTHER base (u8, i32, ...) must be
   re-typed or explicitly cast, even though the compiler can see it fits.

   Deliberately NOT implemented as a plain `unify_at loc t TUsize`: a bare
   `unify_at` would go through TRefinedInt's existing subtyping-into-TUsize
   leniency (types.ml's `TRefinedInt (lo, _), TUsize when lo >= 0 -> ()`),
   which ignores the refined value's own base entirely -- exactly the
   escape hatch that makes this check TOOTHLESS for the common case, since
   nearly every for-loop counter is Const_env-const-bounded (wrapped in
   TRefinedInt) and would sail through unchanged regardless of its base.
   This function checks the base directly instead.

   Unlike require_integer, this ACTIVELY resolves (not just tolerates) an
   unresolved TVar: both a bare literal index and a for-loop counter's
   still-open base get pinned to TUsize immediately. This is safe (unlike
   require_integer's old eager-i32-default mistake, see its own comment)
   because pinning to usize is exactly the type indexing already demands
   -- there is no "wait for a later, more informative use" concern the way
   there was for a bare loop counter with no fixed role yet. *)
let require_usize_index loc t =
  let reject () =
    raise (TypeError (loc, Printf.sprintf
      "array/slice index must be usize, got '%s' -- prefer declaring the \
       value as usize directly (e.g. `for i: usize in ...`), which keeps \
       any proven range; a plain `as usize` cast also works but discards \
       the proven range (reopening a runtime bounds check) -- use an \
       explicit `as {lo..<hi as usize}` cast instead to carry a proven \
       range across the base change"
      (to_string t)))
  in
  match strip_singleton t with
  | TUsize -> ()
  | TVar { contents = Unbound _ } -> unify_at loc t TUsize
  | TRefinedInt (_, _, base) ->
      (match repr base with
       | TUsize -> ()
       | TVar { contents = Unbound _ } -> unify_at loc base TUsize
       | _ -> reject ())
  | _ -> reject ()

(* Raw-pointer indexing is signed pointer displacement, matching ptr +/-
   offset and Rust's offset(isize): negative indices are meaningful and the
   operand must have the target's pointer width. Bare literals are pinned to
   isize; values in another integer base require an explicit cast. *)
let require_isize_offset loc t =
  let reject () =
    raise (TypeError (loc, Printf.sprintf
      "raw-pointer index/offset must be isize, got '%s' -- declare the value \
       as isize or cast it explicitly with `as isize`"
      (to_string t)))
  in
  match strip_singleton t with
  | TIsize -> ()
  | TVar { contents = Unbound _ } -> unify_at loc t TIsize
  | TRefinedInt (_, _, base) ->
      (match repr base with
       | TIsize -> ()
       | TVar { contents = Unbound _ } -> unify_at loc base TIsize
       | _ -> reject ())
  | _ -> reject ()

(* True if a type is not yet fully determined: a bare unresolved
   unification variable, or a TRefinedInt whose own base still is (e.g.
   `let x = min(5, 10);` with no annotation -- min/max's Call case can
   itself leave the base an open TVar when NEITHER argument pins one).
   Nested TVars are otherwise unreachable in this language: no written
   type-expression position ever embeds an inference placeholder, so a
   compound type (TArray/TPtr/TSlice/TStruct) can only ever have a
   concrete element/pointee/field type once its OWN top-level shape is
   concrete. Used by Let/LetDef to require an explicit annotation instead
   of silently deferring to Types.to_ast's i32 default -- see the Let
   case's own comment for why. *)
let rec is_undetermined t =
  match repr t with
  | TVar { contents = Unbound _ } -> true
  | TSingleton (base, _) -> is_undetermined base
  | TRefinedInt (_, _, base) -> is_undetermined base
  | _ -> false

(* Mirrors lib/parser.mly's base_bound_range/check_refined_base_range
   (sync rule, same reasoning, different representation): that check
   validates an Int64.t bound against an Ast.type_expr base at PARSE time
   for the literal `{lo..<hi as base}` surface syntax; this validates a
   plain OCaml int bound (already narrowed via Const_env.bound_value)
   against a Types.ty base at TYPE-CHECK time for `for i: base in
   lo..<hi`'s explicit annotation. Needed for the same reason: a bare
   -literal for-loop bound has no inherent width of its own, so the
   annotation is the ONLY source of width information, and a too-wide
   bound (e.g. `for i: u8 in 0..<300`) would otherwise silently wrap at
   codegen time via `const_int i8_type 300`. *)
let for_annotation_bound_range = function
  | TI8    -> (-128, Some 128)
  | TI16   -> (-32768, Some 32768)
  | TI32   -> (-2147483648, Some 2147483647)
  | TI64   -> (min_int, None)
  | TU8    -> (0, Some 256)
  | TU16   -> (0, Some 65536)
  | TU32   -> (0, Some 4294967296)
  | TU64   -> (0, None)
  | TIsize -> (-2147483648, Some 2147483647)
  | TUsize -> (0, Some 4294967296)
  | _ -> (min_int, None) (* unreachable: only reached via int_base_type_expr's 10 bases *)

let check_for_annotation_range loc lo hi base =
  let (blo, bhi_opt) = for_annotation_bound_range base in
  let out_of_range = lo < blo || (match bhi_opt with Some bhi -> hi > bhi | None -> false) in
  if out_of_range then
    raise (TypeError (loc, Printf.sprintf
      "for-loop bound {%d..<%d} does not fit the annotated type '%s'"
      lo hi (to_string base)))

(* Same bound table as check_for_annotation_range, for a match arm's
   literal-integer pattern (GitHub issue #151) against its discriminant's
   base type instead of a for-loop's declared bound. A negative literal
   against an unsigned base is rejected here (out of range) rather than
   given wraparound-bit-pattern meaning; that is a deliberate v1
   restriction, not an oversight -- see the issue for the open question. *)
let check_match_int_literal_range loc lit base =
  let (blo, bhi_opt) = for_annotation_bound_range base in
  let out_of_range = lit < blo || (match bhi_opt with Some bhi -> lit >= bhi | None -> false) in
  if out_of_range then
    raise (TypeError (loc, Printf.sprintf
      "match arm literal %d does not fit type '%s'" lit (to_string base)))

(* Extract a small-number-scoped compile-time integer from an expression:
   either a bare integer literal (see Ast.int_of_intlit's comment for why
   IntLit's Int64.t payload cannot always be narrowed to `int`), or
   (GitHub issue #185) a reference to a compile-time `const` -- exactly
   as statically known as a literal, and Const_env.find's own shadowing
   precondition (see its comment) means a Var here can only ever denote
   the global constant, never a same-named local. Used throughout range
   propagation below, which only ever needs to reason about realistic
   mask/comparison/multiplier constants, never a genuinely 64-bit-wide
   value. None uniformly covers "not a literal or known const at all"
   and "one, but too large to reason about here" -- both fall back to
   the conservative (unrefined) case, the same as any other non-constant
   expression would. Sync rule: llvm_gen.ml's own intlit_opt mirrors this
   exactly, change together. *)
let intlit_opt (e : Ast.expr) : int option =
  match e.desc with
  | IntLit k -> Ast.int_of_intlit k
  | Var name -> Const_env.find name
  | _ -> None

(* Is this expression built up entirely from compile-time integer
   LITERALS or a real object's address (`IntLit`, `&x`, casts of a
   literal/address-derived value, +/-/* combining two such values)? Used
   to decide whether a cast to an AFFINE OPAQUE pointer type needs
   `unsafe` -- see infer_expr's Cast case, which deliberately checks this
   ONLY for that narrow target (not pointers in general -- see that
   comment for why). Recognizes `0 as usize as *Token`-style null/
   singleton-token sentinels and `&fat_file_token_storage as *FatFile`
   -style singleton addresses -- but deliberately NOT a `let`-bound
   variable, a function's return value, or any other runtime-computed
   quantity. *)
let rec is_literal_derived (e : Ast.expr) : bool =
  match e.desc with
  | IntLit _ -> true
  | AddrOf _ -> true
  | Cast (_, inner) -> is_literal_derived inner
  | BinOp ((Add | Sub | Mul), a, b) -> is_literal_derived a && is_literal_derived b
  | _ -> false

(* Nesting depth of `unsafe { ... }` expressions around the expression
   currently being inferred. Compilation is single-threaded, so a module
   -level counter is safe (same pattern as llvm_gen's narrowing_ctx).
   Reset at the start of infer_program: a TypeError raised inside an
   unsafe block aborts that compilation with the counter left non-zero,
   and unit tests run many compilations in one process. *)
let unsafe_depth = ref 0

(* Names of every `affine opaque struct`, set once near the start of
   infer_program (before Pass 3 runs) and read from deep inside infer_expr's
   Cast case -- same "module-level ref set once per compilation" pattern as
   unsafe_depth/resolved_call_targets, needed because infer_expr is a
   separate top-level function with no closure access to infer_program's
   own locals. Integer-to-handle construction and resource-flow checks use
   this set (GitHub issue #15 follow-up). *)
let affine_opaque_names = ref StringSet.empty

(* Names of every `linear opaque struct` (OWNERSHIP_KERNEL.md Stage 1,
   GitHub issue #117): exactly-once-on-every-path obligations. Kept as a
   separate set from affine because linear adds all-path discharge,
   no-overwrite, and early-exit obligations. Both kinds reject contraction
   and cast-away; affine alone permits weakening. *)
let linear_opaque_names = ref StringSet.empty

(* A trackable place (OWNERSHIP_KERNEL.md Stage 3a, GitHub issue #89
   Hurdle 3): either a bare local/parameter, or ONE level of field
   projection through a bare local/parameter (`h.t`, base must itself be
   a plain identifier -- `f().t`, `arr[i].t` have no stable syntactic
   identity to key tracking on, so they are deliberately NOT paths and
   fall back to the pre-Stage-3 untracked behavior). Array/slice elements
   are also deliberately excluded: a runtime index has no proof of
   distinctness from another index without relational reasoning (the same
   identity between arbitrary runtime indices) -- that is later place/
   proposition work, not this increment. *)
type path = PVar of string | PField of string * string

let path_to_string = function
  | PVar n -> n
  | PField (b, f) -> b ^ "." ^ f

module ResourceFlow = Takibi_core.Delta.Legacy_flow(struct
  type t = path
  let compare = compare
end)

module PathSet = ResourceFlow.Places

(* The current dual consumption lattice now lives behind Takibi Core's
   explicitly transitional Delta.Legacy_flow boundary. Stage 3a widened its
   key from a bare variable name to `path` (above). *)
type consume_sets = ResourceFlow.t

(* Authority-derived region taint (issues #106/#128): local slice/pointer
   name -> the owner or guard paths it was derived from. Checked lazily
   against maybe_consumed at each use, so it shares Legacy_flow's
   union-at-join conservatism with no extra merge logic of its own. *)
module TaintEnv = Takibi_core.Delta.Region_taint (PathSet)

let is_linear_ptr_ty t = match repr t with
  | TPtr (TStruct n) -> StringSet.mem n !linear_opaque_names
  | TIndexedStruct (n, _) ->
      Hashtbl.find_opt indexed_struct_kinds n = Some Ast.KindLinear
  | _ -> false

let rec is_indexed_owner_ty t = match repr t with
  | TIndexedStruct _ -> true
  | TSingleton (base, _) -> is_indexed_owner_ty base
  | TTuple ts -> List.exists is_indexed_owner_ty ts
  | _ -> false

let rec contains_singleton_ty t = match repr t with
  | TSingleton _ -> true
  | TPtr t | TIo t | TArray (t, _) | TSlice (t, _)
  | TAlignedPtr (_, t) -> contains_singleton_ty t
  | TTuple ts -> List.exists contains_singleton_ty ts
  | TFun (args, ret, _) ->
      List.exists contains_singleton_ty args || contains_singleton_ty ret
  | _ -> false

let rec contains_view_ty t = match repr t with
  | TView _ -> true
  | TPtr t | TIo t | TArray (t, _) | TSlice (t, _)
  | TAlignedPtr (_, t) | TSingleton (t, _) -> contains_view_ty t
  | TTuple ts -> List.exists contains_view_ty ts
  | TFun (args, ret, _) ->
      List.exists contains_view_ty args || contains_view_ty ret
  | TExists (_, _, _, body) -> contains_view_ty body
  | _ -> false

let rec contains_variant_ty t = match repr t with
  | TVariant _ -> true
  | TPtr t | TIo t | TArray (t, _) | TSlice (t, _)
  | TAlignedPtr (_, t) | TSingleton (t, _) -> contains_variant_ty t
  | TTuple ts -> List.exists contains_variant_ty ts
  | TFun (args, ret, _) ->
      List.exists contains_variant_ty args || contains_variant_ty ret
  | TExists (_, _, _, body) -> contains_variant_ty body
  | _ -> false

let rec contains_kinded_variant_ty t = match repr t with
  | TVariant name -> Hashtbl.mem variant_kinds name
  | TPtr t | TIo t | TArray (t, _) | TSlice (t, _)
  | TAlignedPtr (_, t) | TSingleton (t, _) -> contains_kinded_variant_ty t
  | TTuple ts -> List.exists contains_kinded_variant_ty ts
  | TFun (args, ret, _) ->
      List.exists contains_kinded_variant_ty args
      || contains_kinded_variant_ty ret
  | TExists (_, _, _, body) -> contains_kinded_variant_ty body
  | _ -> false

let type_has_explicit_function_effect senv ty =
  let rec visit seen = function
    | Ast.TypeFn (args, ret, effects) ->
        Option.is_some effects
        || List.exists (visit seen) args || visit seen ret
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypeArray (t, _)
    | Ast.TypeSlice (t, _) -> visit seen t
    | Ast.TypeTuple ts -> List.exists (visit seen) ts
    | Ast.TypeExists (_, sort, body) -> visit seen sort || visit seen body
    | Ast.TypeNamed name | Ast.TypeIndexed (name, _) ->
        if StringSet.mem name seen then false
        else
          (match StringMap.find_opt name senv with
           | Some (fields, _, _) ->
               let seen = StringSet.add name seen in
               List.exists (fun (_, field_ty) -> visit seen field_ty) fields
           | None -> false)
    | _ -> false
  in
  visit StringSet.empty (resolve_declared_type ty)

let is_tuple_ty t = match repr t with
  | TTuple _ -> true
  | _ -> false

let is_variant_ty t = match repr t with
  | TVariant _ -> true
  | _ -> false

(* Direct calls are resolved during inference.  Codegen must consume this
   exact decision rather than attempting a second overload resolution. *)
let resolved_call_targets = ref StringMap.empty
let resolved_indirect_call_effects : string list option StringMap.t ref =
  ref StringMap.empty

let inferred_effect_locs : Lexing.position StringMap.t ref = ref StringMap.empty

let inferred_effect_location key = StringMap.find_opt key !inferred_effect_locs

(* GitHub issue #102: per-variable align(N) info, consulted by AddrOf/Var
   (array decay) in infer_expr to prove *align(N) T for `&x` / an aligned
   array's own name. Two-tier, mirroring how tyenv itself already models
   local-shadows-global: `global_align_bytes_baseline` is populated once,
   early in infer_program (globals are visible everywhere, and their
   names are already guaranteed unique by the toplevel-name-collision
   pass), and `var_align_bytes` is RESEEDED from that baseline at the
   start of every infer_func call, then updated incrementally as that
   function's own `let ... align(N)` locals are processed by infer_stmt's
   Let case -- so a local shadowing an aligned global's name (by
   overwriting the same key) is handled correctly, and no function's
   local aligned variables leak into the NEXT function's inference (the
   reseed discards them). infer_func calls are sequential and never
   nested (Pass 3's own fold), which is what makes this reset discipline
   sound. A function PARAMETER cannot itself be declared align(N) (no
   such syntax exists) so nothing further is needed for parameters. *)
let global_align_bytes_baseline : int StringMap.t ref = ref StringMap.empty
let var_align_bytes : int StringMap.t ref = ref StringMap.empty

(* GitHub issue #108: `private let` global name -> the source file (loc.pos_fname)
   it was declared in. Populated once, early in infer_program (globals are visible
   everywhere and already uniqueness-checked by claim_toplevel_name), then consulted
   by every ident-based reference site below (Var, Assign, Index, AssignIndex,
   SliceOf -- every AST construct that can name a global directly) to reject a
   reference whose OWN loc.pos_fname differs from the declaring file. This is a
   whole-program table rather than a closure-local one for the same reason
   affine_opaque_names/global_align_bytes_baseline above are: infer_expr/infer_stmt
   are top-level functions with no access to infer_program's own locals. *)
let private_globals : (string, string) Hashtbl.t = Hashtbl.create 8

(* GitHub issue #214: names bound by a LOCAL declaration (function
   parameter, let/let mut, tuple destructuring, for-loop counter, foreach
   element, or let-match) within the function currently being type-checked.
   A local binding always shadows a private global of the same name from a
   different file -- e.g. a `backing` parameter must not be misidentified
   as a reference to an unrelated file's `private let backing`. This
   language has no nested function definitions, so "current function" is
   unambiguous; reset once per infer_func call (see there) and once more
   before Pass 3 starts so global-initializer expressions (checked before
   any infer_func call) never see a stale set from a previous compilation
   unit test. Consulted, never itself driving type inference, by
   check_private_global_access below. *)
let locally_bound_names : StringSet.t ref = ref StringSet.empty

(* Known limitation: this checks by NAME only, not by resolved binding, so a
   local variable/parameter in a different file that happens to share a
   private global's exact name would previously have been misidentified as
   a violation -- fixed by consulting locally_bound_names above (GitHub
   issue #214; originally noted as a known gap in issue #108). *)
let check_private_global_access (use_loc : Ast.loc) (name : string) : unit =
  if StringSet.mem name !locally_bound_names then ()
  else
    match Hashtbl.find_opt private_globals name with
    | Some decl_file when decl_file <> use_loc.Lexing.pos_fname ->
        raise (TypeError (use_loc, Printf.sprintf
          "'%s' is a private global declared in '%s'; it may only be referenced \
           from that same file" name decl_file))
    | _ -> ()

(* OWNERSHIP_KERNEL.md Stage 2 (GitHub issue #108) tables, populated once
   per infer_program run, same discipline as private_globals above. *)

(* `private ... opaque struct` name -> declaring file. Construction (any
   cast whose TARGET type mentions the name) is declaring-file-only;
   naming the type in annotations stays legal everywhere, so values can
   still be held and passed around outside -- they just cannot be
   conjured there. *)
let private_opaque_types : (string, string) Hashtbl.t = Hashtbl.create 8

(* (struct name, private field name) -> declaring file. *)
let private_struct_fields : (string * string, string) Hashtbl.t = Hashtbl.create 8

(* A private field whose type is a linear variant is a stable owner
   slot. It is never read, written, or addressed directly; stable_replace is
   the only operation that exchanges its invariant-owned value. *)
let stable_owner_fields : (string * string, unit) Hashtbl.t = Hashtbl.create 8
let stable_owner_structs : (string, unit) Hashtbl.t = Hashtbl.create 8

let is_stable_owner_field sname fname =
  Hashtbl.mem stable_owner_fields (sname, fname)

(* Stable owner containers are locations, not ordinary values. A pointer to
   one is the intended API surface, but wrapping the value in another runtime
   aggregate must not turn whole-container copies back on. *)
let rec contains_stable_owner_value_ty t = match repr t with
  | TStruct name -> Hashtbl.mem stable_owner_structs name
  | TIo t | TArray (t, _) | TSlice (t, _) | TSingleton (t, _)
  | TExists (_, _, _, t) -> contains_stable_owner_value_ty t
  | TTuple ts -> List.exists contains_stable_owner_value_ty ts
  | TFun (args, ret, _) ->
      List.exists contains_stable_owner_value_ty args
      || contains_stable_owner_value_ty ret
  | TPtr _ | TAlignedPtr _ -> false
  | _ -> false

(* struct name -> declaring file, present iff the struct has at least one
   private field: constructing such a struct via a struct literal writes
   every field, private ones included, so the literal itself is
   declaring-file-only (this is what makes smart constructors real). *)
let private_struct_lit : (string, string) Hashtbl.t = Hashtbl.create 8

(* private erased view name -> declaring file. Naming remains public; only
   the explicit `view Name` mint expression is restricted. *)
let private_views : (string, string) Hashtbl.t = Hashtbl.create 8

let check_private_view_construction (loc : Ast.loc) name =
  match Hashtbl.find_opt private_views name with
  | Some file when file <> loc.Lexing.pos_fname ->
      raise (TypeError (loc, Printf.sprintf
        "cannot mint private view '%s' outside its declaring file '%s'"
        name file))
  | _ -> ()

(* Every opaque struct name of any kind, for the pointer-arithmetic
   completeness check (Stage 2 Part C): arithmetic on a pointer needs the
   pointee's size, which an opaque (incomplete) type does not have. Found
   via a user-review probe: `t + 1` on an affine handle passed BOTH type
   inference and kind checking (BinOp operands are non-consuming, so the
   result was a second tracked value conjured without consuming the
   first) and died only as an invalid-LLVM-IR internal error. *)
let opaque_struct_names_all = ref StringSet.empty

let check_private_type_construction (loc : Ast.loc) (target : Ast.type_expr) =
  let rec walk = function
    | Ast.TypeNamed n ->
        (match Hashtbl.find_opt private_opaque_types n with
         | Some file when file <> loc.Lexing.pos_fname ->
             raise (TypeError (loc, Printf.sprintf
               "cannot construct a value of private type '%s' outside its \
                declaring file '%s' (that file's functions are the only \
                legal source)" n file))
         | _ -> ())
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeSingleton (t, _)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> walk t
    | Ast.TypeIndexed (n, _) ->
        (match Hashtbl.find_opt private_struct_lit n with
         | Some file when file <> loc.Lexing.pos_fname ->
             raise (TypeError (loc, Printf.sprintf
               "cannot construct a value of private type '%s' outside its declaring file '%s'"
               n file))
         | _ -> ())
    | Ast.TypeTuple ts -> List.iter walk ts
    | _ -> ()
  in
  walk target

let check_private_field_access (loc : Ast.loc) (sname : string) (fname : string) =
  match Hashtbl.find_opt private_struct_fields (sname, fname) with
  | Some file when file <> loc.Lexing.pos_fname ->
      raise (TypeError (loc, Printf.sprintf
        "field '%s.%s' is private to '%s'; go through that file's accessor \
         functions" sname fname file))
  | _ -> ()

let check_private_struct_literal (loc : Ast.loc) (sname : string) =
  match Hashtbl.find_opt private_struct_lit sname with
  | Some file when file <> loc.Lexing.pos_fname ->
      raise (TypeError (loc, Printf.sprintf
        "cannot construct struct '%s' with a literal outside '%s': it has \
         private fields (use that file's constructor functions)" sname file))
  | _ -> ()

let check_ptr_arith_complete (loc : Ast.loc) (t : ty) =
  match repr t with
  | TPtr (TStruct n) | TAlignedPtr (_, TStruct n)
    when StringSet.mem n !opaque_struct_names_all ->
      raise (TypeError (loc, Printf.sprintf
        "pointer arithmetic/indexing on '*%s' is not allowed: '%s' is an \
         opaque (incomplete) type with no size" n n))
  | _ -> ()

(* Same "opaque struct has no known layout" reasoning as
   check_ptr_arith_complete, applied to Deref instead of arithmetic/
   indexing: `*p` for p: *OpaqueStruct has no size/fields to load, so it
   must be rejected here too rather than reaching llvm_gen.ml and
   producing an internal-compiler-error LLVM `load` of an opaque type. An
   affine/linear opaque handle's whole point is that its pointee never
   really exists (see is_literal_derived's callers -- these values are
   typically minted from a bare integer/address, e.g. `0 as usize as
   *Lease`), so this closes the same hole arithmetic/indexing already
   had, for the one remaining pointer operation that could still reach
   the missing-size problem. *)
let check_deref_complete (loc : Ast.loc) (t : ty) =
  match repr t with
  | TPtr (TStruct n) | TAlignedPtr (_, TStruct n)
    when StringSet.mem n !opaque_struct_names_all ->
      raise (TypeError (loc, Printf.sprintf
        "cannot dereference '*%s': '%s' is an opaque (incomplete) type \
         with no size" n n))
  | _ -> ()

let rec gcd a b = if b = 0 then abs a else gcd b (a mod b)

(* Is this integer expression PROVABLY a multiple of some compile-time-
   known k > 0 (and if so, the largest such k this simple analysis finds)?
   Used by infer_expr's pointer-arithmetic case to decide whether
   `aligned_ptr + offset` stays *align(N) T (offset must be provably a
   multiple of N -- see that case's own comment). Deliberately NOT a
   general symbolic/congruence solver: a literal OR a named compile-time
   constant (Const_env.bound_value, the same resolver the Mul range-
   propagation case above already uses for e.g. `idx * RX_BUF_SIZE`) is a
   multiple of itself; `_ * K` or `K * _` is a multiple of that K
   regardless of the other (unknown) operand's value -- the concrete case
   this exists for, `eth_rx_bufs + eth_rx_cur * ETH_BUF_SIZE`; and a sum/
   difference of two independently-provable multiples is a multiple of
   their gcd. Any other shape (a bare non-constant variable, a function
   call, multiplying two non-constant operands, ...) yields None -- the
   caller then requires `unsafe`, same as everywhere else this scoped-not
   -general style of proof falls short in this codebase. *)
let rec provable_multiple_of (e : Ast.expr) : int option =
  match Const_env.bound_value e with
  | Some n when n <> 0 -> Some (abs n)
  | _ ->
  match e.desc with
  | Cast (_, inner) -> provable_multiple_of inner
  | BinOp (Mul, a, b) ->
      (match Const_env.bound_value a, Const_env.bound_value b with
       | Some n, _ when n <> 0 -> Some (abs n)
       | _, Some n when n <> 0 -> Some (abs n)
       | _ -> None)
  | BinOp ((Add | Sub), a, b) ->
      (match provable_multiple_of a, provable_multiple_of b with
       | Some ka, Some kb -> Some (gcd ka kb)
       | _ -> None)
  | _ -> None

(* GitHub issue #102 Stage 2: is EVERY element of this pointee type
   itself guaranteed to start N bytes apart? If the pointee is a struct
   declared with its OWN `align(M)` where M is a multiple of N, GEP's
   element-wise stride (sizeof(struct), itself a multiple of M because
   struct `align(M)` tail-pads to it -- see Type_layout) means ANY
   integer element offset preserves *align(N) T, not just an offset
   PROVABLY a multiple of N in bytes (provable_multiple_of, above) --
   distinct proof source, needed for `eth_rx_descs + i` (examples/
   common_stm32/eth.tkb's `rx_desc_ptr`/`tx_desc_ptr`: EthDmaDesc is
   `align(32)`, so stepping by whole elements, for ANY `i`, never
   crosses into the middle of a cache line). *)
let elem_stride_aligned (senv : senv) (n : int) (elem : ty) : bool =
  match elem with
  | TStruct sname ->
      (match StringMap.find_opt sname senv with
       | Some (_, _, Some m) -> m mod n = 0
       | _ -> false)
  | _ -> false

(* GitHub issue #15 follow-up: require `unsafe` for a cast that builds an
   AFFINE/LINEAR OPAQUE pointer from anything other than a compile-time literal or
   a real object's address -- see is_literal_derived's comment for the
   full reasoning and why this is scoped to affine targets only, not
   pointer casts in general. Called from infer_expr's Cast case for BOTH
   ways a source integer can reach that point (a plain unrefined base, or
   a TRefinedInt -- e.g. a refined `{0..<4 as usize}` loop-proven index),
   since those are two separate match arms there and neither should skip
   this check. *)
let check_kinded_ptr_cast_needs_unsafe loc (src_expr : Ast.expr) (tgt : ty) =
  match tgt with
  | TPtr (TStruct sname) when StringSet.mem sname !affine_opaque_names
                           || StringSet.mem sname !linear_opaque_names ->
      if not (is_literal_derived src_expr) then begin
        if !unsafe_depth = 0 then
          raise (TypeError (loc,
            "casting a non-literal integer to an affine/linear handle asserts \
             it is valid with no evidence; write `unsafe { ... as "
            ^ to_string tgt ^ " }` to mark it"))
        else
          (* GitHub issue #328: this is the "consumed" branch --
             unsafe_depth > 0 is the only reason this cast is allowed.
             See type_checker_consumed_unsafe_at's own comment. *)
          note_type_checker_unsafe_use ()
      end
  | _ -> ()

let is_io_pointer_ty = function
  | TPtr (TIo _) | TAlignedPtr (_, TIo _) -> true
  | _ -> false

(* GitHub issue #316's decision: unlike check_kinded_ptr_cast_needs_unsafe's
   affine/linear case just above, `*io T` construction gets NO literal
   exemption. A hardcoded MMIO address (`0x107FFF9000 as *io u32`) is just
   as unprovable to the compiler as a runtime-discovered one (a PCI BAR
   scan today, a future dtb/ACPI table walk) -- the only difference is
   human reviewability, and that is exactly what marking the site with
   `unsafe` is for, not a reason to skip marking it. Deliberately applies
   to EVERY cast producing a *io-shaped target, regardless of the source
   expression's own shape (integer, *T, or another *io U being
   reinterpreted): the claim being asserted ("this really is a valid,
   correctly-sized hardware register region") is the same unprovable
   claim either way. Does NOT apply to ordinary pointer arithmetic on an
   ALREADY *io-typed value (`io_ptr + 4`) -- that is stepping an
   already-audited pointer, not minting a new one, matching this
   language's general "unsafe is not extended to plain pointer
   arithmetic" stance (see "unsafe { ... }" in SPEC.md). *)
let check_io_ptr_cast_needs_unsafe loc (tgt : ty) =
  if is_io_pointer_ty tgt then begin
    if !unsafe_depth = 0 then
      raise (TypeError (loc, Printf.sprintf
        "casting to '%s' asserts it denotes a real, correctly-sized hardware \
         register with no evidence (GitHub issue #316); write `unsafe { ... \
         as %s }` to mark it"
        (to_string tgt) (to_string tgt)))
    else
      (* GitHub issue #328: see type_checker_consumed_unsafe_at's comment. *)
      note_type_checker_unsafe_use ()
  end

(* Companion to check_io_ptr_cast_needs_unsafe for the IMPLICIT coercion
   path SPEC.md's "MMIO / Volatile" section documents ("An integer literal
   can be assigned directly to an MMIO pointer type"): `let dr: *io u8 =
   0x09000000;` never goes through an `as` Cast AST node at all, because
   IntLit's inferred type (infer_expr's `IntLit _ -> fresh ()` case) is a
   fully unconstrained metavariable that unifies with *io T directly at
   whichever Let/Assign/Return/Call-arg/struct-or-array-literal-field site
   the annotation lives -- the exact same site list check_literal_fits_
   refined already covers, called alongside it everywhere that function is
   called. Deliberately keyed on the raw AST shape (`e.desc = IntLit`) --
   any other expression shape reaching a *io-typed target without a Cast
   node would already have failed ordinary unification (TUsize does not
   unify with TPtr(TIo _)), so IntLit is the only implicit-coercion shape
   that can reach here at all. *)
let check_io_ptr_literal_needs_unsafe loc (e : Ast.expr) (target : ty) =
  match e.desc with
  | Ast.IntLit _ when is_io_pointer_ty target ->
      if !unsafe_depth = 0 then
        raise (TypeError (loc, Printf.sprintf
          "assigning an integer literal directly to '%s' asserts it denotes \
           a real, correctly-sized hardware register with no evidence \
           (GitHub issue #316); write `unsafe { ... }` around it"
          (to_string target)))
      else
        (* GitHub issue #328: see type_checker_consumed_unsafe_at's comment. *)
        note_type_checker_unsafe_use ()
  | _ -> ()

(* GitHub issue #218: audit-map warning for casting a non-literal integer
   to an ORDINARY (non-affine/linear) pointer -- deliberately a warning,
   not yet an error. This warning makes the full population visible without
   forcing an unsafe migration before safe slice-based replacements exist.
   `*io T` is exempted here because its dedicated hard error above already
   handles it, and affine/linear opaque targets are likewise already gated. *)
let nonliteral_ptr_cast_warnings : (Lexing.position * string) list ref = ref []

(* GitHub issue #327 Stage 1: every TypeError caught while attempting each
   function body in infer_program's Pass 3, in encounter order. Reset at
   the start of every infer_program call, same as nonliteral_ptr_cast_warnings
   just above. Empty on a clean compilation -- Pass 3 raises MultiTypeError
   directly (rather than leaving this for a caller to check) the moment it
   finds this non-empty, so nothing outside this file needs to read it. *)
let collected_type_errors : (Ast.loc * string) list ref = ref []

let is_io_pointee = function
  | TIo _ -> true
  | _ -> false

let check_nonliteral_ptr_cast_warning loc (src_expr : Ast.expr) (tgt : ty) =
  if not (is_literal_derived src_expr) then
    match tgt with
    | TPtr (TStruct sname)
      when StringSet.mem sname !affine_opaque_names
        || StringSet.mem sname !linear_opaque_names -> ()
    | TPtr elem | TAlignedPtr (_, elem) when not (is_io_pointee elem) ->
        if !unsafe_depth > 0 then
          (* An explicit unsafe block records this calculated-address mint
             as an audited boundary, even while #218 remains warning-only.
             This also tells the unnecessary-unsafe lint that the block has
             a real purpose. *)
          note_type_checker_unsafe_use ()
        else
          nonliteral_ptr_cast_warnings :=
            (loc, Printf.sprintf
              "casting a non-literal integer to %s asserts it is a valid \
               pointer with no evidence (GitHub issue #218); not yet an \
               error -- migrate this boundary to a checked slice or wrap it \
               in unsafe"
              (to_string tgt))
            :: !nonliteral_ptr_cast_warnings
    | _ -> ()

(* Slice 3: ownership-bearing values cannot be cast away. The temporary
   affine-to-usize exception existed only for null-sentinel acquisition;
   kind-carrying variants replace that encoding. `unsafe` does not duplicate
   or forget Delta permissions. *)
let check_resource_cast_away loc (src_ty : ty) =
  match repr src_ty with
  | TView (name, _) ->
      raise (TypeError (loc, Printf.sprintf
        "cannot cast erased view '%s': views have no runtime representation"
        name))
  | TIndexedStruct (sname, _) ->
      raise (TypeError (loc, Printf.sprintf
        "cannot cast indexed owner '%s': use its declaring module's constructor/accessor functions"
        sname))
  | TVariant name ->
      raise (TypeError (loc, Printf.sprintf
        "cannot cast variant '%s': inspect it with match" name))
  | TPtr (TStruct sname) when StringSet.mem sname !linear_opaque_names
                            || StringSet.mem sname !affine_opaque_names ->
      raise (TypeError (loc, Printf.sprintf
        "cannot cast an affine/linear value (*%s) to anything: use a variant for fallible ownership"
        sname))
  | _ -> ()

(* GitHub issue #102: casting an INTEGER expression to *align(N) T requires
   either `unsafe` or a compile-time proof the value is actually a multiple
   of N (provable_multiple_of, above) -- same "unchecked assertion must be
   visibly marked" reasoning as check_kinded_ptr_cast_needs_unsafe just
   above, applied to alignment instead of affine-handle identity. Called
   from infer_expr's Cast case for integer sources (both the plain and
   TRefinedInt match arms); a POINTER source casting to *align(N) T is a
   separate case, handled inline via `unify` where TPtr src is matched,
   since that is a widening/narrowing check between two pointer types, not
   an "is this integer's value provably X" question. *)
let check_aligned_ptr_cast_needs_unsafe loc (src_expr : Ast.expr) (tgt : ty) =
  match tgt with
  | TAlignedPtr (n, _) ->
      (match provable_multiple_of src_expr with
       | Some k when k mod n = 0 -> ()
       | _ ->
           if !unsafe_depth = 0 then
             raise (TypeError (loc, Printf.sprintf
               "casting a non-literal integer to %s asserts alignment with \
                no evidence; write `unsafe { ... as %s }` to mark it"
               (to_string tgt) (to_string tgt)))
           else
             (* GitHub issue #328: proof failed, so unsafe_depth > 0 is the
                only reason this cast is allowed -- see
                type_checker_consumed_unsafe_at's own comment. Unlike the
                `Some k when k mod n = 0` case above, this genuinely
                consumed the justification (previously, this whole branch
                wasn't even evaluated when already inside unsafe, so
                whether the proof would have succeeded or failed was never
                distinguished -- now it always is, so a cast that HAPPENS
                to sit inside unsafe but was always provably aligned
                anyway does not get wrongly credited as "needing" it). *)
             note_type_checker_unsafe_use ())
  | _ -> ()

(* GitHub issue #239: companion to types.ml's of_ast_in_scope check, for the
   handful of sites that mint a *T directly from an already-resolved `ty`
   (array-to-pointer decay, address-of) rather than from an Ast.type_expr
   annotation -- an of_ast_in_scope-only check would miss e.g. `let mut p:
   *u8 = ...; let pp = &p;` (pp's `**u8` is never written down, so no
   TypePtr AST node exists to reject; it is inferred straight from p's own
   already-resolved ty). Every other TPtr/TAlignedPtr construction in this
   file reconstructs an element type taken from an ALREADY pointer-typed
   value (pointer arithmetic, deref widening), so it can only repeat a
   nesting level that would already have been rejected when that pointer
   was first minted; only true minting sites need this call. *)
let check_no_nested_ptr_mint loc (inner : ty) =
  if is_ty_pointer_shaped inner then
    raise (TypeError (loc,
      "nested pointer indirection (e.g. **T) is not allowed; \
       Takibi has no ownership/lifetime model for multi-level pointers \
       (GitHub issue #239)"))

(* GitHub issue #310: per-variable "why didn't the early-return guard
   above narrow this" hint, name -> explanation text. Declared here
   (ahead of check_expr, its sole reader) so the reader has no forward
   reference to record_guard_narrow_hints (its writer, defined later
   near negate_cond -- see that function's own comment for the full
   design). Reset per function (see infer_func), matching
   locally_bound_names' own per-function-scoping precedent. *)
let guard_narrow_hints : (string, string) Hashtbl.t = Hashtbl.create 8

(* GitHub issue #311: this file's own resolved type for an Index/
   AssignIndex node's index expression, keyed by that expression's own
   location -- consulted by llvm_gen.ml as the primary source for its
   own bounds-check-elision decision, instead of independently
   re-deriving narrowing via its own separate narrowing_ctx (the
   duplication this issue is about). Scoped narrowly to Index/
   AssignIndex's own index sub-expression specifically (not a general
   "annotate every use site" mechanism) per this issue's own
   investigation comment: it is the one consumer of narrowing_ctx that
   matters for --forbid-trap soundness reporting, and the two files'
   independent re-derivation of narrowing has already caused two real,
   found gaps (issue #296, #311's own history).

   Sound to trust as the PRIMARY source, not just a supplementary check:
   `it` is exactly the proof type-checking itself used to accept the
   program (the same `infer_expr ... idx` call whose result later flows
   into unify_at/refinement checks elsewhere) -- codegen eliding a check
   based on it can only UNDER-prove relative to what a hand-rolled
   codegen-side re-derivation might have found (a missed optimization,
   never a soundness bug), since it never claims more than type-checking
   itself already established.

   Deliberately NOT a full replacement for llvm_gen.ml's own idx_ty
   computation: llvm_gen.ml's Const_env.bound_value fast path stays
   FIRST and unconditional, since `it` does not capture a compile-time
   constant's exact value the way Const_env.bound_value does (a `const`
   reference's own registered tyenv entry is its DECLARED type, e.g.
   plain usize, not a refined singleton reflecting the literal) --
   replacing that fast path with this table would regress existing
   --forbid-trap-clean constant-indexed accesses (e.g. `tcp[TCP_FLAGS]`)
   into needing a runtime check. The separate #213 slice_index_ctx
   mechanism (llvm_gen.ml-only, no type_inf.ml counterpart) is also left
   completely untouched -- it answers a different question ("is this
   exactly the same already-checked base/index pair") this table cannot
   express. Reset once per compilation (not per-function): the location
   key is unique across the whole program, and Index/AssignIndex nodes
   in different functions never collide. *)
let index_resolved_ty : (Lexing.position, Ast.type_expr) Hashtbl.t = Hashtbl.create 64

let rec infer_expr senv eenv tyenv fenv (e : Ast.expr) : ty =
  match e.desc with
  | IntLit _    -> fresh ()  (* polymorphic: unifies with any integer type via context *)
  | BoolLit _   -> TBool
  | StringLit _ -> TPtr TU8
  | ViewLit (name, args) ->
      if not (Hashtbl.mem view_kinds name) then
        raise (TypeError (e.loc, Printf.sprintf "unknown erased view '%s'" name));
      check_private_view_construction e.loc name;
      let scope = match !active_static_scope with
        | Some scope -> scope
        | None -> create_static_scope ()
      in
      TView (name, List.map (Types.static_of_ast scope) args)
  | Var name ->
      check_private_global_access e.loc name;
      (* Check local/global variables first *)
      (match StringMap.find_opt name tyenv with
       | Some (t, _) ->
           (* Array types decay to pointer. io T is a value type: return T (volatile handled in codegen) *)
           (match repr t with
            | TArray (inner, _) ->
                (* GitHub issue #102: an array declared `align(N)` decays to
                   a PROVEN *align(N) T, not a plain *T -- this is the
                   actual motivating shape (examples/common_stm32/eth.tkb's
                   `eth_rx_bufs`, a DMA buffer array used bare as its own
                   base address). *)
                check_no_nested_ptr_mint e.loc inner;
                (match StringMap.find_opt name !var_align_bytes with
                 | Some n -> TAlignedPtr (n, inner)
                 | None -> TPtr inner)
            | TIo    inner      -> inner
            | _                 -> t)
       | None ->
           (* Function name used as a value (function pointer) *)
           match StringMap.find_opt name fenv with
           | Some [(_, ft)] ->
               let ft = instantiate_static_params ft in
               if contains_view_ty ft then
                 raise (TypeError (e.loc, Printf.sprintf
                   "function '%s' has erased view parameters/results and cannot be used as a runtime function pointer in Slice 2"
                   name));
               ft
           | Some _ ->
               raise (TypeError (e.loc, Printf.sprintf
                 "overloaded function '%s' needs an expected function type; use an explicit wrapper" name))
           | None ->
               raise (TypeError (e.loc,
                 Printf.sprintf "Unbound variable: %s" name)))
  | BinOp (op, e1, e2) ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      let t2 = infer_expr senv eenv tyenv fenv e2 in
      if contains_view_ty t1 || contains_view_ty t2 then
        raise (TypeError (e.loc,
          "erased views cannot be operands of runtime operators"));
      (* GitHub issue #314/#319: &T/&mut T is bit-opaque -- no arithmetic,
         no bitwise ops, no comparison, with no `unsafe` escape (forgery
         -proofness is the entire point of this type). Checked here, before
         any operator-specific case below, so a same-shaped pair (which
         would otherwise unify fine, since TRef/TRefMut DO unify with
         themselves for ordinary argument-passing purposes) can never
         silently fall through the generic "unify and go" catchall that
         closes most of the cases below. Use the referent's OWN fields/
         values, or widen to *T first, for anything this rejects. *)
      (match repr t1, repr t2 with
       | (TRef _ | TRefMut _), _ | _, (TRef _ | TRefMut _) ->
           raise (TypeError (e.loc,
             "&/&mut does not support operators (arithmetic, bitwise, or \
              comparison); use its fields, or widen it to *T first"))
       | _ -> ());
      (* GitHub issue #186: u16be (bare or refined-over-it) deliberately does
         not participate in ordinary arithmetic, shifts, or ORDERING
         comparisons -- comparing two byte-swapped bit patterns numerically
         does not preserve the logical ordering on this little-endian
         target. == and != and the bitwise ops are safe and useful directly
         on wire-order bytes without a conversion (a conventionally-written
         big-endian hex literal already matches its own wire storage order,
         and bitwise masking is order-independent as long as the mask is
         written the same way) -- real network code keeps values in wire
         order from receive through transmit, so this is deliberately not
         "reject everything". Anything else must `as u16` first. *)
      (let is_wire_be_ty t = match repr t with
         | TU16Be | TU32Be -> true
         | TRefinedInt (_, _, (TU16Be | TU32Be)) -> true
         | _ -> false
       in
       match op with
       | Eq | Ne | Band | Bor | Bxor -> ()
       | _ ->
           if is_wire_be_ty t1 || is_wire_be_ty t2 then
             raise (TypeError (e.loc,
               "cannot use a wire-endian (u16be/u32be) value with this \
                operator; convert with `as u16`/`as u32` first (==, !=, &, \
                |, ^ are allowed directly)")));
      (match op with
       | Add ->
           (* Pointer arithmetic: ptr + isize -> returns the same pointer type. TIo is a value type, excluded.
              Range propagation (interval arithmetic; sync rule: llvm_gen's
              BinOp typing mirrors every case below, change together):
                {a..<b} + {c..<d} -> {a+c..<b+d-1}
                {a..<b} + k       -> {a+k..<b+k}   (and symmetric) *)
           (match repr t1, repr t2 with
            | TPtr _, TPtr _
            | TAlignedPtr _, TPtr _
            | TPtr _, TAlignedPtr _
            | TAlignedPtr _, TAlignedPtr _ ->
                raise (TypeError (e.loc, "cannot add two pointers"))
            | TAlignedPtr (n, elem), _ ->
                (* GitHub issue #102: aligned_ptr + offset stays *align(N) T
                   when EITHER the pointee's own element stride is itself a
                   multiple of N (elem_stride_aligned -- any offset works,
                   `eth_rx_descs + i`'s shape) OR offset is PROVABLY a
                   multiple of N in bytes (provable_multiple_of -- the
                   eth_rx_bufs + eth_rx_cur * ETH_BUF_SIZE shape); silently
                   decays to plain *T otherwise -- same "lose the proof,
                   don't error" style TRefinedInt's own arithmetic below
                   already uses when it can't keep a tighter range. *)
                unify_at e2.loc t2 TIsize;
                if elem_stride_aligned senv n elem then TAlignedPtr (n, elem)
                else (match provable_multiple_of e2 with
                      | Some k when k mod n = 0 -> TAlignedPtr (n, elem)
                      | _ -> TPtr elem)
            | _, TAlignedPtr (n, elem) ->
                unify_at e1.loc t1 TIsize;
                if elem_stride_aligned senv n elem then TAlignedPtr (n, elem)
                else (match provable_multiple_of e1 with
                      | Some k when k mod n = 0 -> TAlignedPtr (n, elem)
                      | _ -> TPtr elem)
            | TPtr _, _ ->
                check_ptr_arith_complete e.loc t1;
                unify_at e2.loc t2 TIsize;
                t1
            | _, TPtr _ ->
                check_ptr_arith_complete e.loc t2;
                unify_at e1.loc t1 TIsize;
                t2
            | TRefinedInt (a, b, base1), TRefinedInt (c, d, base2) ->
                unify_at e.loc base1 base2;
                TRefinedInt (a + c, b + d - 1, base1)
            | TRefinedInt (a, b, base), _ ->
                (match intlit_opt e2 with
                 | Some k ->
                     unify_at e2.loc t2 base;
                     TRefinedInt (a + k, b + k, base)
                 | None ->
                     unify_at e2.loc (canon_ty t2) base;
                     base)
            | _, TRefinedInt (c, d, base) ->
                (match intlit_opt e1 with
                 | Some k ->
                     unify_at e1.loc t1 base;
                     TRefinedInt (c + k, d + k, base)
                 | None ->
                     unify_at e1.loc (canon_ty t1) base;
                     base)
            | _ ->
                let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                unify_at e.loc ct1 ct2;
                ct1)
       | Sub ->
           (* Pointer arithmetic: ptr - isize -> returns the same pointer type; ptr - ptr -> isize.
              Range propagation (sync rule with llvm_gen, as for Add):
                {a..<b} - {c..<d} -> {a-d+1..<b-c}
                {a..<b} - k       -> {a-k..<b-k}
                k - {c..<d}       -> {k-d+1..<k-c+1}  (k a literal; symmetric
                                      with Add's both-directions handling --
                                      what makes `40 - ihl` carry ihl's
                                      Band/min-derived range through to
                                      "remaining room" for a chained clamp,
                                      see CLAUDE.md's P4c section) *)
           (match repr t1, repr t2 with
            | TPtr inner1, TPtr inner2
            | TAlignedPtr (_, inner1), TPtr inner2
            | TPtr inner1, TAlignedPtr (_, inner2)
            | TAlignedPtr (_, inner1), TAlignedPtr (_, inner2) ->
                (* GitHub issue #102: pointer difference (result TIsize) is
                   unaffected by alignment on either side -- checked BEFORE
                   the "aligned_ptr - offset" case below, since that case's
                   own pattern (TAlignedPtr, _) would otherwise also match
                   a pointer second operand. *)
                check_ptr_arith_complete e.loc t1;
                check_ptr_arith_complete e.loc t2;
                unify_at e.loc inner1 inner2;
                TIsize
            | TAlignedPtr (n, elem), _ ->
                (* aligned_ptr - offset stays *align(N) T when either the
                   element stride or the offset itself proves it -- same
                   reasoning as Add's own TAlignedPtr case above (kept
                   together, sync rule). *)
                unify_at e2.loc t2 TIsize;
                if elem_stride_aligned senv n elem then TAlignedPtr (n, elem)
                else (match provable_multiple_of e2 with
                      | Some k when k mod n = 0 -> TAlignedPtr (n, elem)
                      | _ -> TPtr elem)
            | TPtr _, _ ->
                check_ptr_arith_complete e.loc t1;
                unify_at e2.loc t2 TIsize;
                t1
            | TRefinedInt (a, b, base), _ ->
                (match repr t2 with
                 | TRefinedInt (c, d, base2) ->
                     unify_at e.loc base base2;
                     TRefinedInt (a - d + 1, b - c, base)
                 | _ ->
                     (match intlit_opt e2 with
                      | Some k ->
                          unify_at e2.loc t2 base;
                          TRefinedInt (a - k, b - k, base)
                      | None ->
                          unify_at e2.loc (canon_ty t2) base;
                          base))
            | _, _ ->
                (match intlit_opt e1, repr t2 with
                 | Some k, TRefinedInt (c, d, base) ->
                     unify_at e1.loc t1 base;
                     TRefinedInt (k - d + 1, k - c + 1, base)
                 | _ ->
                     let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                     unify_at e.loc ct1 ct2;
                     ct1))
       | Mul ->
           (* Range propagation: {a..<b} * k (k a positive literal OR a
              Const_env-resolvable named constant, e.g. `idx * RX_BUF_SIZE`
              -- see CLAUDE.md's P4c section for where using e2.desc's bare
              IntLit check alone missed this) -> {a*k..<(b-1)*k+1} -- what
              makes `tcp_hdr_len = doff * 4` carry doff's narrowed {5..<16}
              into {20..<61}. Sync rule with llvm_gen as for Add/Sub.
              Non-constant or non-positive multipliers fall back to i32. *)
           let k2 = Const_env.bound_value e2 and k1 = Const_env.bound_value e1 in
           (match repr t1, k2, repr t2, k1 with
            | TRefinedInt (a, b, base), Some k, _, _ when k > 0 ->
                unify_at e2.loc t2 base;
                TRefinedInt (a * k, (b - 1) * k + 1, base)
            | _, _, TRefinedInt (a, b, base), Some k when k > 0 ->
                unify_at e1.loc t1 base;
                TRefinedInt (a * k, (b - 1) * k + 1, base)
            | _ ->
                let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
                unify_at e.loc ct1 ct2;
                ct1)
       | Div ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           ct1
       | Lt | Gt | Le | Ge | Eq | Ne ->
           unify_at e.loc (canon_ty t1) (canon_ty t2);
           TBool
       (* Range propagation: n % m where m is a positive constant -> {0..<m}.
          Soundness condition: propagate only when n is guaranteed non-negative.
          TRefinedInt with lo>=0 or unsigned types ({lo..<_}, lo>=0) satisfy this.
          When n is int (can be negative), srem returns a negative remainder, so return same type.
          Example: (-5) % 8 = -5 (not 3) -- returning {0..<m} without non-negativity is unsound. *)
       | Mod ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           (match intlit_opt e2 with
            | Some m when m > 0 ->
                (match repr t1 with
                 | TRefinedInt (lo, _, _) when lo >= 0 -> TRefinedInt (0, m, ct1)
                 | t when is_unsigned_ty t -> TRefinedInt (0, m, ct1)
                 | _ -> ct1)
            | _ -> ct1)
       | Or | And ->
           check_cond e1.loc t1;
           check_cond e2.loc t2;
           TBool
       (* Range propagation: x & k -> {0..<k+1} when k is a non-negative
          literal mask. Sound regardless of x's own sign or range: bitwise
          AND with a non-negative value can only clear bits, so the result
          is always in [0, k] in two's complement, for ANY x (a negative x
          like -1 = all-ones still yields x & k <= k). Symmetric (k may be
          either operand). Sync rule: llvm_gen.ml's BinOp Band case must
          compute the same thing -- change together. *)
       | Band ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           (* GitHub issue #186: the [0, k+1) range-proving optimization just
              below is UNSOUND for u16be. It proves a bound on the RAW
              bit-pattern AND result; TRefinedInt's own meaning for a u16be
              base (see the Cast case's range-preservation) is the LOGICAL
              (post-swap) value's range, and byte-swapping a raw value
              bounded by k does not bound the logical value by k (swapping
              is not monotonic) -- so skip proving anything and keep the
              plain wire-order type instead of manufacturing a false proof
              that --forbid-trap code could then trust to elide a real
              check. *)
           if ct1 = TU16Be || ct1 = TU32Be then ct1 else
           (match intlit_opt e2 with
            | Some k when k >= 0 -> TRefinedInt (0, k + 1, ct1)
            | _ -> (match intlit_opt e1 with
                    | Some k when k >= 0 -> TRefinedInt (0, k + 1, ct1)
                    | _ -> ct1))
       | Bor | Bxor | Shr | Shl ->
           let ct1 = canon_ty t1 and ct2 = canon_ty t2 in
           unify_at e.loc ct1 ct2;
           ct1)
  | Bnot e1 ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      if contains_view_ty t1 then
        raise (TypeError (e.loc,
          "erased views cannot be operands of runtime operators"));
      canon_ty t1
  | Deref e1 ->
      let t1 = infer_expr senv eenv tyenv fenv e1 in
      check_deref_complete e1.loc t1;
      let inner = match repr t1 with
        | TPtr inner ->
            (* *io T deref returns T (io is a storage qualifier; volatile handled in codegen) *)
            strip_io inner
        | _ ->
            let inner = fresh () in
            unify_at e1.loc t1 (TPtr inner);
            inner
      in
      if contains_stable_owner_value_ty inner then
        raise (TypeError (e.loc,
          "stable owner container storage cannot be dereferenced or copied as a whole; access its ordinary fields through the pointer"));
      inner
  | AddrOf inner -> infer_addrof_wrapped senv eenv tyenv fenv e inner `Ptr
  | Cast (target_ty, e) ->
      let src_ty = infer_expr senv eenv tyenv fenv e in
      check_resource_cast_away e.loc src_ty;
      check_private_type_construction e.loc target_ty;
      if contains_stable_owner_value_ty src_ty
         || contains_stable_owner_value_ty (of_ast target_ty) then
        raise (TypeError (e.loc,
          "cannot cast a stable owner container value; only pointers to its private global storage may be cast"));
      (match resolve_declared_type target_ty with
       | Ast.TypeView (name, _) ->
           raise (TypeError (e.loc, Printf.sprintf
             "cannot construct erased view '%s' with a cast; use `view %s`"
             name name))
       | Ast.TypeIndexed (name, _) ->
           raise (TypeError (e.loc, Printf.sprintf
             "cannot construct indexed owner '%s' with a cast; use its constructor"
             name))
       | Ast.TypeTuple _ ->
           raise (TypeError (e.loc, "cannot cast to a tuple type"))
       | _ -> ());
      (match repr src_ty with
       | TTuple _ ->
           raise (TypeError (e.loc, "cannot cast a tuple to anything"))
       | _ -> ());
      let tgt_ty = of_ast target_ty in
      if type_has_explicit_function_effect senv (to_ast src_ty)
         || type_has_explicit_function_effect senv target_ty
      then
        (try unify src_ty tgt_ty
         with Unify_error reason ->
           raise (TypeError (e.loc, Printf.sprintf
             "cannot cast through an explicit function-pointer effect contract: %s"
             reason)));
      let src_enum = match repr src_ty with
        | TStruct sn when StringMap.mem sn eenv -> Some sn
        | _ -> None
      in
      let tgt_enum = match target_ty with
        | Ast.TypeNamed tn when StringMap.mem tn eenv -> Some tn
        | _ -> None
      in
      (match src_enum, tgt_enum with
       | Some ename, _ ->
           (* Enum -> T: T must be exactly the underlying type.
              Use (et as underlying) as T for any other conversion. *)
           let (underlying, _, _) = StringMap.find ename eenv in
           let expected = of_ast underlying in
           let got      = of_ast target_ty in
           if repr got <> repr expected then
             raise (TypeError (e.loc,
               Printf.sprintf
                 "cannot cast enum '%s' (underlying %s) to '%s': cast to '%s' first"
                 ename (to_string expected) (to_string got) (to_string expected)));
           of_ast target_ty
       | None, Some ename ->
           (* T -> Enum: T must be assignable to the underlying type.
              TRefinedInt subtyping is allowed (e.g. {0..<3} as Color where Color: u8). *)
           let (underlying, _, _) = StringMap.find ename eenv in
           let expected = of_ast underlying in
           (try unify src_ty expected
            with Unify_error _ ->
              raise (TypeError (e.loc,
                Printf.sprintf
                  "cannot cast '%s' to enum '%s' (underlying %s): cast to '%s' first"
                  (to_string src_ty) ename (to_string expected) (to_string expected))));
           of_ast target_ty
       | None, None ->
           let tgt = tgt_ty in
           (match tgt with
            | TRef _ | TRefMut _ ->
                (* GitHub issue #314/#319: the only legal casts INTO &T/
                   &mut T are (a) from an already-&/&mut-typed source of
                   the exact same referent (an explicit reborrow -- delegated
                   to `unify`'s own TRef/TRefMut subtyping rules, so a shared
                   -to-mut cast is rejected the same way an implicit one
                   would be) or (b) from a raw pointer to the EXACT SAME
                   pointee type, which always needs `unsafe` (this is the
                   one place a raw *T can be asserted to be a live,
                   correctly-typed, non-aliased value -- the ordinary,
                   unsafe-free way to get a reference is `&x`/`&mut x` on a
                   real value, see infer_addrof_wrapped). No other source is
                   legal, not even under `unsafe`: fabricating a reference
                   from an arbitrary integer or an unrelated pointer type
                   would defeat the entire "no forgery" point of this type. *)
                (match repr src_ty with
                 | TRef _ | TRefMut _ ->
                     (try unify src_ty tgt; tgt
                      with Unify_error reason ->
                        raise (TypeError (e.loc, Printf.sprintf
                          "cannot cast %s to %s: %s"
                          (to_string src_ty) (to_string tgt) reason)))
                 | TPtr inner | TAlignedPtr (_, inner) ->
                     let want_inner = match tgt with
                       | TRef t | TRefMut t -> t | _ -> assert false in
                     if repr inner <> repr want_inner then
                       raise (TypeError (e.loc, Printf.sprintf
                         "cannot cast %s to %s: &/&mut can only be cast from \
                          a raw pointer to the exact same pointee type"
                         (to_string src_ty) (to_string tgt)));
                     if !unsafe_depth = 0 then
                       raise (TypeError (e.loc, Printf.sprintf
                         "casting %s to %s asserts it is a live, correctly \
                          -typed, non-aliased value with no evidence; write \
                          `unsafe { ... as %s }` to mark it, or use \
                          `&x`/`&mut x` on the real value instead"
                         (to_string src_ty) (to_string tgt) (to_string tgt)));
                     tgt
                 | _ ->
                     raise (TypeError (e.loc, Printf.sprintf
                       "cannot cast %s to %s: &/&mut can only be minted with \
                        `&x`/`&mut x` on a real value, or (under `unsafe`) \
                        cast from a raw pointer to the exact same type"
                       (to_string src_ty) (to_string tgt))))
            | _ ->
           (match target_ty with
            | Ast.TypeSlice (el_ast, want_min) ->
                (* Slice creation cast. Sources:
                   - an array VARIABLE (its declared [T; N] carries the static
                     length; note infer_expr's Var case decays arrays to *T,
                     so the length must be recovered from the binding, not
                     from src_ty -- llvm_gen's Cast case does the same)
                   - another slice (min-length may only be relaxed) *)
                let el_want = of_ast el_ast in
                (match repr src_ty with
                 | TSlice (el_s, m) ->
                     unify_at e.loc el_s el_want;
                     if m < want_min then
                       raise (TypeError (e.loc, Printf.sprintf
                         "cannot cast %s to %s: minimum length %d is not proven"
                         (to_string src_ty) (to_string tgt) want_min));
                     TSlice (el_want, m)
                 | _ ->
                     (match e.desc with
                      | Ast.Var name ->
                          (match StringMap.find_opt name tyenv with
                           | Some (t, _) ->
                               (match repr t with
                                | TArray (el_a, n) ->
                                    unify_at e.loc el_a el_want;
                                    if n < want_min then
                                      raise (TypeError (e.loc, Printf.sprintf
                                        "cannot cast [_; %d] to %s: array is shorter \
                                         than the required minimum %d" n (to_string tgt) want_min));
                                    TSlice (el_want, n)
                                | t' -> raise (TypeError (e.loc, Printf.sprintf
                                    "cannot cast '%s' to a slice" (to_string t'))))
                           | None -> raise (TypeError (e.loc,
                               Printf.sprintf "Unbound variable: %s" name)))
                      | Ast.StringLit str ->
                          (* String literal as a slice: the compile-time
                             byte length (NUL excluded) becomes the minimum,
                             so `slice_copy(dst, "..." as []u8)` copies the
                             literal and returns its length -- no NUL scan,
                             no unbounded write. *)
                          unify_at e.loc TU8 el_want;
                          let n = String.length str in
                          if n < want_min then
                            raise (TypeError (e.loc, Printf.sprintf
                              "cannot cast a %d-byte string literal to %s"
                              n (to_string tgt)));
                          TSlice (el_want, n)
                      | _ -> raise (TypeError (e.loc,
                          "slice cast requires an array variable, string \
                           literal, or slice source"))))
            | _ ->
           (* GitHub issue #186: u16be/u32be cast ONLY to/from their own
              plain or refined host type (u16be<->u16, u32be<->u32) --
              never to/from any other integer type (including each other),
              which would let one silently reinterpret through a back door
              and defeat the entire point of a distinct wire-order type.
              Checked here, before the general numeric-cast dispatch below,
              since that dispatch's own final catch-all otherwise treats
              any bare integer source/target pair as an ordinary, unchecked
              truncating/widening reinterpret. *)
           let is_wire_be_flavored t = match t with
             | TU16Be | TU32Be -> true
             | TRefinedInt (_, _, (TU16Be | TU32Be)) -> true
             | _ -> false
           in
           let base_of t = match t with TRefinedInt (_, _, b) -> b | b -> b in
           let same_wire_family a b = match a, b with
             | TU16Be, TU16 | TU16, TU16Be | TU16Be, TU16Be -> true
             | TU32Be, TU32 | TU32, TU32Be | TU32Be, TU32Be -> true
             | _ -> false
           in
           if is_wire_be_flavored (repr src_ty) || is_wire_be_flavored tgt then begin
             if not (same_wire_family (base_of (repr src_ty)) (base_of tgt)) then
               raise (TypeError (e.loc, Printf.sprintf
                 "cannot cast %s to %s; only u16be <-> u16 or u32be <-> u32 \
                  is a legal conversion"
                 (to_string src_ty) (to_string tgt)));
             match repr src_ty with
             | TRefinedInt (lo, hi, _) -> TRefinedInt (lo, hi, tgt)
             | _ -> tgt
           end else
           (match repr src_ty with
            | TPtr _ | TAlignedPtr _ ->
                (* TAlignedPtr src (GitHub issue #102) shares TPtr's cast
                   rules exactly: `as usize` or `as *T` always widens/
                   drops the proof (an explicit cast to a WEAKER pointer
                   type is always allowed, same as passing an aligned
                   pointer where a plain one is expected elsewhere); `as
                   *align(N) T` is the one case needing its own check,
                   just below. *)
                (match tgt with
                 | TUsize | TPtr _ -> tgt
                 | TAlignedPtr (n_dst, _) ->
                     (* GitHub issue #102: an explicit cast asserting
                        alignment on an already-pointer source -- allowed
                        unconditionally inside `unsafe`, otherwise only
                        checks the ALIGNMENT NUMBER (src's own N must be a
                        multiple of n_dst), deliberately NOT full `unify`
                        against tgt: unlike an implicit assignment/call
                        argument (which must keep the exact same pointee
                        type), an explicit cast is exactly where a
                        REINTERPRET across pointee types is meant to stay
                        legal (e.g. `root_dir_buf as *align(32) u8`,
                        examples/common/fat12.tkb's own DirEntry-array ->
                        byte-pointer bridge, same as any other `*T as *U`
                        cast) -- only whether the alignment PROOF survives
                        is in question here, not the pointee type. *)
                     let src_n = match repr src_ty with
                       | TAlignedPtr (n, _) -> Some n
                       | _ -> None
                     in
                     (match src_n with
                      | Some n when n mod n_dst = 0 -> tgt
                      | _ when !unsafe_depth > 0 -> tgt
                      | _ -> raise (TypeError (e.loc, Printf.sprintf
                          "cannot cast unproven %s to %s; use `&x` on an \
                           align(%d) variable, a literal address, pointer \
                           arithmetic by a multiple of %d, or \
                           `unsafe { ... as %s }` to mark it"
                          (to_string src_ty) (to_string tgt) n_dst n_dst
                          (to_string tgt))))
                 | _ ->
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "cannot cast pointer to %s; \
                          use `(ptr as usize) as %s` to make the truncation explicit"
                         (to_string tgt) (to_string tgt))))
            | TSlice (elem, n) ->
                (match tgt with
                 | TPtr TU8 ->
                     (* Explicit bridge from the slice world back into the
                        BYTE-pointer world (`frame as *u8`) -- used where an
                        API still takes pointer+length (checksums,
                        net_transmit, response building). Free, unconditionally:
                        a byte pointer's "pointee size" is 1, so any slice
                        length already proves it, and this is the same
                        length-erasing operation `[]T as *T` element-typed
                        casts already are for the general case just below. *)
                     tgt
                 | TPtr pointee when repr pointee = repr elem ->
                     (* GitHub issue #218 follow-up regression (found via
                        kernel/lib/freelist.tkb#freelist_ref -- `[usize;
                        3..] as *usize`): when the cast target is the
                        SAME type as the slice's own element type, this
                        is not a reinterpretation asserting some OTHER
                        byte layout fits -- it is exactly the pointer-
                        extraction half of an ordinary array-to-pointer
                        decay (`arr as *T` on a `[T; N]`), always free
                        regardless of N. Checking sizeof at all here
                        would be both wrong in principle (no new claim
                        is being made) and impossible in practice for a
                        target-dependent element type like `usize` --
                        exactly what tripped this over, since
                        const_type_size cannot compute sizeof(usize)
                        and previously forced `unsafe` on a cast that
                        was never actually asserting anything. *)
                     tgt
                 | TPtr pointee ->
                     (* GitHub issue #218 follow-up (slice/struct-overlay
                        variant): a slice already carries a length -- unlike
                        the plain-integer #218 population, this cast can
                        actually be PROVEN safe when that length and the
                        target's size are both compile-time-known, instead
                        of only ever being warned about. Reuses
                        const_type_size (already built for sizeof(T)'s own
                        refined-literal fast path) so this can never
                        disagree with sizeof's own notion of "provable
                        here" -- both read the exact same struct/array
                        shape rules. n=0 means a dynamic-length slice (no
                        minimum length was ever proven, e.g. a runtime
                        `as []T` reinterpret); n>0 is a real lower bound
                        (a `[T; N..]` parameter, or a literal-bounds
                        subslice like `frame[14..<34]`). *)
                     if !unsafe_depth = 0 then
                       (match const_type_size senv (to_ast pointee), n > 0 with
                        | Some sz, true when n >= sz -> ()
                        | Some sz, true ->
                            raise (TypeError (e.loc, Printf.sprintf
                              "cannot cast %s to %s: proven minimum length %d \
                               is smaller than sizeof(%s) = %d bytes; write \
                               `unsafe { ... as %s }` to mark it"
                              (to_string src_ty) (to_string tgt) n
                              (to_string pointee) sz (to_string tgt)))
                        | Some sz, false ->
                            raise (TypeError (e.loc, Printf.sprintf
                              "casting %s to %s asserts it is at least \
                               sizeof(%s) = %d bytes with no evidence: this \
                               slice's length is not compile-time-provable; \
                               write `unsafe { ... as %s }` to mark it"
                              (to_string src_ty) (to_string tgt)
                              (to_string pointee) sz (to_string tgt)))
                        | None, _ ->
                            raise (TypeError (e.loc, Printf.sprintf
                              "casting %s to %s asserts it is a valid \
                               pointer with no evidence: sizeof(%s) is not \
                               provable at compile time here (its layout \
                               depends on target-specific data); write \
                               `unsafe { ... as %s }` to mark it"
                              (to_string src_ty) (to_string tgt)
                              (to_string pointee) (to_string tgt))));
                     tgt
                 | _ ->
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "cannot cast a slice to %s (only `as *T` is allowed)"
                         (to_string tgt))))
            | TRefinedInt (lo, hi, _) ->
                (* GitHub issue #72: a BARE cast target (`x as usize`, not the
                   explicit `x as {lo..<hi as usize}` form) still infers the
                   tightest possible refined type when x's own range is
                   already known and fits the target base -- e.g. `ihl as
                   usize` when ihl: {20..<21 as u16} now behaves exactly like
                   the old `ihl as {20..<21 as usize}` did, with no explicit
                   range restated by hand. This only ever WIDENS what the
                   cast proves (never narrows/weakens): `tgt` is one of the
                   plain integer base variants here (an explicit TypeRefined
                   target_ty already produced a TRefinedInt tgt above, so it
                   never reaches this arm), and unify's existing TRefinedInt
                   subtyping rule is reused as the single source of truth
                   for "does this range fit the target base", so this can
                   never drift from the manual-annotation path's own rules.
                   A range that does NOT fit (a genuine narrowing/truncating
                   cast, e.g. a {0..<1481}-typed value cast to u8) falls
                   through unchanged to today's behavior: a plain unrefined
                   `tgt`, silently truncating, exactly as before this
                   feature existed. *)
                (match tgt with
                 | TI8 | TI16 | TI32 | TI64
                 | TU8 | TU16 | TU32 | TU64
                 | TIsize | TUsize ->
                     (try unify src_ty tgt; TRefinedInt (lo, hi, tgt)
                      with Unify_error _ -> tgt)
                 | _ ->
                     (* A refined integer (e.g. a for-loop-proven
                        `{0..<4 as usize}` index) cast straight to a
                        pointer -- same GitHub issue #15/#102 checks as the
                        catch-all case below, needed here too since this
                        is a SEPARATE match arm reached whenever the
                        source already carries a refined range. *)
                     check_kinded_ptr_cast_needs_unsafe e.loc e tgt;
                     check_aligned_ptr_cast_needs_unsafe e.loc e tgt;
                     check_io_ptr_cast_needs_unsafe e.loc tgt;
                     check_nonliteral_ptr_cast_warning e.loc e tgt;
                     tgt)
            | _ ->
                (* GitHub issue #15 follow-up: casting a non-literal integer
                   to a pointer to an AFFINE OPAQUE struct type asserts
                   "this bit pattern is a valid handle" with no evidence at
                   all (check_kinded_ptr_cast_needs_unsafe, above). This
                   deliberately covers only affine-opaque targets, not
                   pointer casts in general: an earlier, broader version of
                   this check (any integer -> any pointer type) was
                   measured against the whole example suite and rejected --
                   this codebase's real MMIO drivers routinely cast a
                   runtime-DISCOVERED hardware base address, offset by a
                   computed value, straight to a plain `*io T` pointer
                   (examples/common_qemu/virtio_mmio.tkb's `(virtio_base +
                   offset) as *io i32`, `virtio_base` itself found by
                   scanning device slots at boot) -- so the general "any
                   pointer" version stays rejected, and this affine-only
                   case stays as narrow as before. GitHub issue #316 later
                   made a SEPARATE, deliberately narrower decision to
                   require `unsafe` for `*io T` specifically regardless of
                   literal-ness (check_io_ptr_cast_needs_unsafe, below) --
                   including the virtio_mmio.tkb-style discovered-base
                   pattern above, which now needs `unsafe { ... }` too. That
                   is a targeted MMIO-provenance decision, not a reversal of
                   the "any pointer" rejection: ordinary non-affine,
                   non-`io` pointer casts (array/struct-overlay offset math,
                   the roughly-1146-site population check_nonliteral_ptr_
                   cast_warning below still only warns about) remain
                   unsafe-free. An affine opaque handle is different in kind
                   from both: nothing legitimate ever needs to fabricate one
                   from an arbitrary computed integer (every real handle in
                   this codebase already comes from that type's own
                   constructor, e.g. `fat_open()`/`net_rx_acquire()`), so a
                   cast building one from anything other than a literal or a
                   real object's address (`&x`) is exactly the `examples/
                   affine_escape_via_index.tkb`-style misuse (a table index
                   smuggled through a pointer purely to get affine tracking)
                   this check exists to flag -- see HISTORY.md's issue #15
                   entry for the full before/after measurement. *)
                check_kinded_ptr_cast_needs_unsafe e.loc e tgt;
                check_aligned_ptr_cast_needs_unsafe e.loc e tgt;
                check_io_ptr_cast_needs_unsafe e.loc tgt;
                check_nonliteral_ptr_cast_warning e.loc e tgt;
                (* GitHub issue #100 follow-up: an EXPLICIT `x as {lo..<hi
                   as base}` cast target reaches here for any source that
                   isn't itself a pointer/slice/already-refined value (in
                   particular, a bare integer literal) -- same gap as
                   Let/Assign/etc: `tgt` was already computed from the
                   written syntax with no check against a literal source's
                   actual value. *)
                check_literal_fits_refined e.loc e tgt;
                tgt))))

  | FieldGet (base_expr, fname) ->
      infer_field_access ~decay:true senv eenv tyenv fenv e.loc base_expr fname

  | Index (base, idx) ->
      (* GitHub issue #217: base's un-decayed declared type, recovered by
         direct lookup/struct-field-table walk (place_undecayed_type)
         rather than general infer_expr -- an array-typed struct field
         must NOT decay to a bare element pointer here the way an
         ordinary (non-indexing) field read decays it, or bounds-check
         codegen loses the array length entirely. *)
      let vt = place_undecayed_type senv eenv tyenv fenv base in
      let it = infer_expr senv eenv tyenv fenv idx in
      Hashtbl.replace index_resolved_ty idx.loc (to_ast it);  (* GitHub issue #311 *)
      (match repr vt with
       | TArray (elem, n) ->
           require_usize_index idx.loc it;
           (* Constant index: check bounds at compile time. A literal too
              large to narrow natively (see Ast.int_of_intlit) is certainly
              out of bounds for any real array, so it is reported the same
              way rather than silently passing through unchecked. *)
           (match idx.desc with
            | IntLit k64 ->
                (match Ast.int_of_intlit k64 with
                 | Some k when k >= n ->
                     raise (TypeError (idx.loc,
                       Printf.sprintf "index %d is out of bounds for array of size %d" k n))
                 | Some _ -> ()
                 | None ->
                     raise (TypeError (idx.loc,
                       Printf.sprintf "index %Ld is out of bounds for array of size %d" k64 n)))
            | _ -> ());
           elem
       | TSlice (elem, _) ->
           require_usize_index idx.loc it;
           elem  (* runtime length; codegen elides the check
                    only when idx's range fits the MINIMUM *)
       | TPtr   elem      ->
           check_ptr_arith_complete e.loc (repr vt);
           require_isize_offset idx.loc it;
           strip_io elem     (* *T or *io T -> returns T (bounds unknown) *)
       | TAlignedPtr (_, elem) ->
           (* GitHub issue #102: indexing an aligned pointer is exactly as
              (un)checked as indexing a plain one -- alignment says nothing
              about how many elements are actually there, so this does not
              itself prove anything about the index. *)
           check_ptr_arith_complete e.loc (repr vt);
           require_isize_offset idx.loc it;
           strip_io elem
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt))))

  | SliceOf (base, lo_e, hi_e) ->
      let vt = place_undecayed_type senv eenv tyenv fenv base in
      let lo_t = infer_expr senv eenv tyenv fenv lo_e in
      let hi_t = infer_expr senv eenv tyenv fenv hi_e in
      (* A subslice range is indexing too: array/slice bounds use usize,
         matching single-element Index/AssignIndex and the runtime length's
         own type. Raw-pointer slice construction uses signed pointer-sized
         displacements, matching pointer arithmetic and pointer indexing. *)
      (match repr vt with
       | TArray _ | TSlice _ ->
           require_usize_index lo_e.loc lo_t;
           require_usize_index hi_e.loc hi_t
       | TPtr _ ->
           require_isize_offset lo_e.loc lo_t;
           require_isize_offset hi_e.loc hi_t
       | _ -> ());
      let const_bounds = (Const_env.bound_value lo_e, Const_env.bound_value hi_e) in
      (* Static value range of a bound: a compile-time constant k is {k..<k+1};
         a refined-typed expression contributes its own range. Sync rule:
         llvm_gen.ml's SliceOf makes the same proven/checked decision through
         the same formula (see its bound_range helper) -- change together. *)
      let bound_range be bt =
        match Const_env.bound_value be with
        | Some k -> Some (k, k + 1)
        | None -> (match repr bt with TRefinedInt (a, b, _) -> Some (a, b) | _ -> None)
      in
      (* Same-base rule: s[v ..< v + w] (same variable v as the lo bound,
         reused inside the hi bound) has lo <= hi and a guaranteed length
         >= lower(w) -- for ANY w with a known non-negative lower bound,
         not just a compile-time constant. This discharges the
         correlated-bounds pattern plain interval reasoning cannot (which
         treats the two occurrences of v as independent, so v's own
         WORST-CASE upper bound looks like it could exceed v+w's
         BEST-CASE lower bound, even though they can't actually both
         happen at once since it's the same v): both
         `frame[data_off ..< data_off + 3]` (w = a literal, wlo = 3
         exactly) and `ip[ihl ..< ihl + tcp_len]` (w = another refined
         variable, e.g. the result of a min()-clamp -- see CLAUDE.md's
         P4c section) are this same shape; only the SOURCE of w's lower
         bound differs. io-qualified v is excluded: its two loads are
         volatile and could disagree. Sync rule: llvm_gen's SliceOf must
         decompose hi_e identically. *)
      (* w is restricted to a bare literal or a bare variable (not an
         arbitrary expression): llvm_gen's mirror of this check must look
         up w's range WITHOUT re-running codegen on it a second time (w
         has already been evaluated once as part of hi_e itself), so it
         can only use a direct table lookup, not a general re-inference --
         keeping both sides to the same restriction is the sync rule. *)
      let same_base_len =
        match lo_e.desc with
        | Var v1 ->
            let w_opt = match hi_e.desc with
              | BinOp (Add, { desc = Var v2; _ }, w) when v2 = v1 -> Some w
              | BinOp (Add, w, { desc = Var v2; _ }) when v2 = v1 -> Some w
              | _ -> None
            in
            (match w_opt with
             | None -> None
             | Some w ->
                 let is_io = match StringMap.find_opt v1 tyenv with
                   | Some (t, _) -> (match repr t with TIo _ -> true | _ -> false)
                   | None -> false
                 in
                 if is_io then None
                 else
                   (* A const reference (GitHub issue #185) has as exact a
                      known value as a literal -- Const_env.bound_value
                      already covers both IntLit and a Var naming a
                      registered const, and Const_env's own shadowing
                      precondition (see its bound_value comment) means a
                      Var here can only ever denote the global constant,
                      never a same-named local. Only fall through to the
                      refined-variable check for a genuine non-const
                      variable. *)
                   match Const_env.bound_value w with
                   | Some k when k >= 0 -> Some k
                   | Some _ -> None
                   | None ->
                       match w.desc with
                       | Var w_name ->
                           (match StringMap.find_opt w_name tyenv with
                            | Some (t, _) ->
                                (match repr t with
                                 | TRefinedInt (wlo, _, _) when wlo >= 0 -> Some wlo
                                 | _ -> None)
                            | None -> None)
                       | _ -> None)
        | _ -> None
      in
      (match repr vt with
       | TSlice (elem, m) ->
           (* Proven subslice: 0 <= lo, lo <= hi, hi <= m must all follow
              from the bounds' STATIC ranges (m is a lower bound of the
              runtime length, so hi <= m implies hi <= len), except that
              lo <= hi may also come from the same-base rule. The result's
              minimum is the guaranteed length: exact k - j for same-base,
              min(hi) - max(lo) otherwise. This is how `frame[0..<len]`
              after `if (len >= 54 && len <= 1514)` narrowing yields
              [u8; 54..] with no runtime check at all. *)
           (match bound_range lo_e lo_t, bound_range hi_e hi_t with
            | Some (la, lb), Some (ha, hb)
              when la >= 0 && (lb - 1 <= ha || same_base_len <> None)
                   && hb - 1 <= m ->
                (match same_base_len with
                 | Some l -> TSlice (elem, l)
                 | None   -> TSlice (elem, ha - (lb - 1)))
            | lo_r, hi_r ->
                (match const_bounds with
                 | Some a, Some b when a < 0 || a > b ->
                     (* Definitely-malformed constants: reject rather than
                        emit a check that always traps. (b > m is NOT
                        definitely wrong for a slice -- the runtime length
                        may exceed the minimum -- so that becomes a check.) *)
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "subslice [%d..<%d] is malformed (lo must satisfy \
                          0 <= lo <= hi)" a b))
                 | _ ->
                     (* Runtime-checked subslice (gradual form): codegen
                        emits 0 <= lo && lo <= hi && hi <= s.len -> trap,
                        recorded as a --forbid-trap site. The result minimum
                        keeps whatever the static ranges still guarantee
                        once the check has passed: len = hi - lo >=
                        min(hi) - max(lo). *)
                     let min_after = match same_base_len with
                       | Some l -> l  (* exact once the check has passed *)
                       | None ->
                           (match lo_r, hi_r with
                            | Some (_, lb), Some (ha, _) when ha - (lb - 1) > 0 ->
                                ha - (lb - 1)
                            | _ -> 0)
                     in
                     TSlice (elem, min_after)))
       | TArray (elem, n) ->
           (* Arrays have an EXACT static length, so bounds must be provable
              outright; out-of-range constants are definite errors, and
              runtime bounds have no checked form here (cast to a slice
              first if a runtime-checked subslice is really wanted). *)
           (match bound_range lo_e lo_t, bound_range hi_e hi_t with
            | Some (la, lb), Some (ha, hb)
              when la >= 0 && (lb - 1 <= ha || same_base_len <> None)
                   && hb - 1 <= n ->
                (match same_base_len with
                 | Some l -> TSlice (elem, l)
                 | None   -> TSlice (elem, ha - (lb - 1)))
            | _ ->
                (match const_bounds with
                 | Some a, Some b ->
                     raise (TypeError (e.loc,
                       Printf.sprintf
                         "subslice [%d..<%d] is outside the proven range of \
                          '%s' (minimum length %d)" a b (to_string vt) n))
                 | _ ->
                     raise (TypeError (e.loc,
                       "subslice bounds on an array must be provable at \
                        compile time; cast to a slice first (`arr as []T`) \
                        for a runtime-checked subslice"))))
       | TPtr elem ->
           (* Slice construction from a raw pointer: an unchecked length
              ASSERTION with no evidence, so it must be visibly marked --
              only allowed inside unsafe { ... }. A false assertion here
              poisons every downstream "proof", which is categorically
              worse than a local pointer bug; the unsafe keyword is what
              makes that visible when writing and when reading. *)
           (match repr elem with
            | TIo _ ->
                raise (TypeError (e.loc,
                  "cannot make a slice from a volatile (*io) pointer: slice \
                   accesses are non-volatile and would silently drop io"))
            | _ ->
                if !unsafe_depth = 0 then
                  raise (TypeError (e.loc,
                    Printf.sprintf
                      "slice construction from a raw pointer asserts a length \
                       without evidence; write `unsafe { %s[..] }` to mark it"
                      (Option.value (static_place_key base) ~default:"expr")));
                (* Claimed minimum from the bounds' static ranges (sync
                   rule: same formula as llvm_gen's sub_of_ptr). *)
                (match bound_range lo_e lo_t, bound_range hi_e hi_t with
                 | Some (la, lb), Some (ha, _) when la >= 0 && lb - 1 <= ha ->
                     TSlice (elem, ha - (lb - 1))
                 | _ -> TSlice (elem, 0)))
       | t -> raise (TypeError (e.loc,
           Printf.sprintf "subslice on non-slice/array/pointer type '%s'" (to_string t))))

  | Unsafe e1 ->
      (* Transparent to typing except for permitting unchecked-assertion
         constructs inside. No exception-safe decrement needed: a TypeError
         aborts this top-level item's own checking (infer_program's Pass 3
         resets both unsafe_depth and this function's partial results
         before moving to the next FuncDef -- see issue #327/#328's own
         history for why that reset exists).
         GitHub issue #328: whole-expression granularity, mirroring
         llvm_gen.ml's own Unsafe-expr codegen case (unconditional, not
         gated by type_checker_lint_active -- that flag only matters for
         UnsafeBlock's per-STATEMENT checking below). *)
      incr unsafe_depth;
      let before = !type_checker_unsafe_use_marker in
      let t = infer_expr senv eenv tyenv fenv e1 in
      if !type_checker_unsafe_use_marker <> before then
        Hashtbl.replace type_checker_consumed_unsafe_at e.loc ();
      decr unsafe_depth;
      t

  | EnumVariant (ename, vname) ->
      (match StringMap.find_opt ename eenv with
       | Some (_, variants, _) ->
           if not (List.mem_assoc vname variants) then
             raise (TypeError (e.loc,
               Printf.sprintf "Unknown variant '%s' of enum '%s'" vname ename));
           TStruct ename
       | None ->
           (match Hashtbl.find_opt variant_defs ename with
            | None ->
                raise (TypeError (e.loc,
                  Printf.sprintf "unknown enum or variant '%s'" ename))
            | Some cases ->
                (match List.assoc_opt vname cases with
                 | None -> raise (TypeError (e.loc, Printf.sprintf
                     "unknown case '%s::%s'" ename vname))
                 | Some (Some _) -> raise (TypeError (e.loc, Printf.sprintf
                     "variant case '%s::%s' requires a payload" ename vname))
                 | Some None -> TVariant ename)))

  | VariantCtor (vtype, vname, payload) ->
      let schema = match Hashtbl.find_opt variant_defs vtype with
        | None -> raise (TypeError (e.loc,
            Printf.sprintf "unknown variant '%s'" vtype))
        | Some cases ->
            (match List.assoc_opt vname cases with
             | None -> raise (TypeError (e.loc,
                 Printf.sprintf "unknown case '%s::%s'" vtype vname))
             | Some None -> raise (TypeError (e.loc, Printf.sprintf
                 "variant case '%s::%s' has no payload" vtype vname))
             | Some (Some ty) -> ty)
      in
      let scope = create_static_scope () in
      let rec instantiate_exists = function
        | Ast.TypeExists (name, _, body) ->
            bind_static scope name (fresh_static ());
            instantiate_exists body
        | ty -> of_ast_in_decl_scope scope ty
      in
      let expected = instantiate_exists schema in
      let actual = infer_expr senv eenv tyenv fenv payload in
      let actual = adapt_actual_to_expected tyenv payload actual expected in
      unify_at payload.loc actual expected;
      check_literal_fits_refined payload.loc payload expected;
      check_io_ptr_literal_needs_unsafe payload.loc payload expected;
      TVariant vtype

  | SizeOf ty ->
      (* sizeof(T) is a compile-time constant of type usize. Validate named
         struct/enum types exist so unknown names are caught here rather than
         surfacing as an internal error during codegen. *)
      (match ty with
       | Ast.TypeNamed name when not (StringMap.mem name senv)
                                  && not (StringMap.mem name eenv)
                                  && not (Hashtbl.mem variant_defs name) ->
           raise (TypeError (e.loc, Printf.sprintf "unknown type '%s' in sizeof" name))
       | _ -> ());
      (* GitHub issue #77: when the size is genuinely target-independent
         (see const_type_size's comment), carry the actual value as a
         refined singleton range instead of a bare TUsize -- this is what
         lets it survive being threaded through a `let`/global and still
         be usable to prove a subslice bound, exactly like any other
         refined constant already does. Falls back to the original plain
         TUsize (unrefined, value deferred to codegen) whenever the value
         isn't computable here, e.g. non-packed or align(N) structs,
         pointers, usize/isize fields -- no behavior change for those. *)
      (match const_type_size senv ty with
       | Some v -> TRefinedInt (v, v + 1, TUsize)
       | None -> TUsize)

  | OffsetOf (ty, field) ->
      (* offsetof is meaningful only for a named struct. Validate both the
         type and field here so source errors do not become codegen errors. *)
      let sname = (match ty with
       | Ast.TypeNamed name ->
           (match StringMap.find_opt name senv with
            | None ->
                raise (TypeError (e.loc,
                  Printf.sprintf "unknown struct '%s' in offsetof" name))
            | Some (fields, _, _) when not (List.mem_assoc field fields) ->
                raise (TypeError (e.loc,
                  Printf.sprintf "unknown field '%s' in struct '%s'" field name))
            | Some _ -> name)
       | _ ->
           raise (TypeError (e.loc, "offsetof requires a named struct type")))
      in
      check_private_field_access e.loc sname field;
      (* Same GitHub issue #77 fix as SizeOf above -- see const_field_offset's
         comment for the exact scope (packed, no align(N)). *)
      (match const_field_offset senv sname field with
       | Some v -> TRefinedInt (v, v + 1, TUsize)
       | None -> TUsize)

  | StructLit _ ->
      raise (TypeError (e.loc,
        "struct literal requires a type annotation: `let mut x: Name = {...}`"))

  | EmbedFile _ ->
      (* GitHub issue #230: embed_file(...) is meaningful only as the
         direct initializer of a top-level `let`/`let mut` -- handled
         entirely by the global-initializer pass (Pass 2, below), which
         never reaches infer_expr for it (matching how a bare `Var` global
         initializer is also special-cased before falling through to this
         general dispatch). Reaching this case at all means embed_file was
         used somewhere else -- a local `let`, a function argument, nested
         inside another expression -- which is rejected outright, the same
         way StructLit just above requires its own special position. (An
         explicit array-size annotation on the global itself, e.g. `let x:
         [u8; 100] = embed_file(...)`, is fine -- Pass 2 unifies it against
         the real file size like any other typed initializer; this
         rejection is about POSITION, not annotation presence.) *)
      raise (TypeError (e.loc,
        "embed_file(...) may only be used as a top-level 'let'/'let mut' \
         initializer, e.g. 'let x = embed_file(\"path\");'"))

  | TupleLit exprs ->
      (* OWNERSHIP_KERNEL.md 5.9 (GitHub issue #120): a function-local
         product value. Kind handling lives in check_affine_func (a
         tracked component is consumed exactly when the literal itself
         flows into a consuming position). *)
      if List.length exprs < 2 then
        raise (TypeError (e.loc, "a tuple literal needs at least 2 components"));
      let ts = List.map (fun x -> infer_expr senv eenv tyenv fenv x) exprs in
      if List.exists contains_view_ty ts then
        raise (TypeError (e.loc,
          "an erased view cannot be stored in a runtime tuple in Slice 2"));
      if List.exists (fun t ->
           contains_variant_ty t
           && match repr t with TVariant _ -> false | _ -> true) ts then
        raise (TypeError (e.loc,
          "a variant cannot be nested below a direct runtime tuple component in Slice 3"));
      if List.exists contains_stable_owner_value_ty ts then
        raise (TypeError (e.loc,
          "a stable owner container cannot be nested in a runtime tuple"));
      TTuple ts

  | Call ("stable_replace", args) ->
      (match args with
       | [guard;
          ({ desc = AddrOf
               ({ desc = FieldGet (lock_base, _); _ } as lock_place); _ }
            as lock_addr);
          ({ desc = FieldGet (base_expr, fname); _ } as field_expr);
          replacement] ->
           (match guard.desc with
            | Var _ -> ()
            | _ -> raise (TypeError (guard.loc,
                "stable_replace guard must be a bare linear view binding")));
           let gt = infer_expr senv eenv tyenv fenv guard in
           let guard_lock = match repr gt with
            | TView (name, args)
              when Hashtbl.find_opt view_kinds name = Some Ast.KindLinear ->
                let formals = Option.value
                  (Hashtbl.find_opt view_params name) ~default:[] in
                let addr_args = List.fold_left2 (fun found (_, sort) arg ->
                  match sort with
                  | Ast.TypeNamed "addr" -> arg :: found
                  | _ -> found) [] formals args in
                (match addr_args with
                 | [lock] -> lock
                 | _ -> raise (TypeError (guard.loc,
                     "stable_replace guard must carry exactly one addr index")))
            | _ -> raise (TypeError (guard.loc,
                "stable_replace requires a linear erased-view guard"))
           in
           let lock_ty = infer_expr senv eenv tyenv fenv lock_addr in
           (match repr lock_ty with
            | TPtr _ | TAlignedPtr _ -> ()
            | _ -> raise (TypeError (lock_addr.loc,
                "stable_replace mutex argument must be a field address")));
           (try unify_static guard_lock (static_identity_for_place lock_place)
            with Unify_error msg ->
              raise (TypeError (lock_addr.loc,
                "stable_replace mutex does not match guard identity: " ^ msg)));
           (match static_place_key lock_base, static_place_key base_expr with
            | Some lock_key, Some owner_key when lock_key = owner_key -> ()
            | _ -> raise (TypeError (field_expr.loc,
                "stable_replace mutex and owner field must belong to the same \
                 syntactic container")));
           let bt = infer_expr senv eenv tyenv fenv base_expr in
           let (sname, static_args) = match struct_instance (repr bt) with
             | Some x -> x
             | None -> raise (TypeError (base_expr.loc,
                 "stable_replace target must be a struct field"))
           in
           check_private_field_access field_expr.loc sname fname;
           if not (is_stable_owner_field sname fname) then
             raise (TypeError (field_expr.loc, Printf.sprintf
               "field '%s.%s' is not stable owner storage; stable_replace requires a private linear variant field"
               sname fname));
           let fields = match StringMap.find_opt sname senv with
             | Some (fs, _, _) -> fs
             | None -> raise (TypeError (base_expr.loc,
                 Printf.sprintf "unknown struct type '%s'" sname))
           in
           let field_ty = match List.assoc_opt fname fields with
             | Some ft -> field_type_for_instance sname static_args ft
             | None -> raise (TypeError (field_expr.loc,
                 Printf.sprintf "no field '%s' in struct '%s'" fname sname))
           in
           let rt = infer_expr senv eenv tyenv fenv replacement in
           let rt = adapt_actual_to_expected tyenv replacement rt field_ty in
           unify_at replacement.loc rt field_ty;
           (match repr field_ty with
            | TVariant name
              when Hashtbl.find_opt variant_kinds name = Some Ast.KindLinear ->
                field_ty
            | _ -> raise (TypeError (field_expr.loc,
                "stable_replace target must hold a linear variant")))
       | [_; lock; { desc = FieldGet _; _ }; _] ->
           raise (TypeError (lock.loc,
             "stable_replace second argument must be the address of a mutex field"))
       | [_; _; field; _] ->
           raise (TypeError (field.loc,
             "stable_replace third argument must be a stable struct field"))
       | _ -> raise (TypeError (e.loc,
           "stable_replace expects 4 arguments: stable_replace(guard, &container.mutex, container.owner, replacement)")))

  | Call (("dma_publish" | "dma_consume" | "device_fence" | "signal_fence"
          | "interrupt_wait" | "interrupt_notify") as fname, args) ->
      (* Target-independent DMA/device ordering builtins. Their hardware
         lowering is selected in llvm_gen.ml; keeping them zero-argument
         makes the synchronization boundary explicit and prevents a runtime
         value from accidentally selecting barrier semantics. *)
      (match args with
       | [] -> TVoid
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects no arguments: %s()" fname fname)))

  | Call (("mrs_cntfrq_el0" | "mrs_cntpct_el0" | "mrs_sctlr_el1"
          | "mrs_esr_el1" | "mrs_far_el1" | "mrs_elr_el1" | "mrs_spsr_el1") as fname, args) ->
      (* GitHub issue #226/#227: closed system-register read intrinsics. Zero
         arguments, like dma_publish/etc. above -- a runtime value must not
         be able to select which register gets read. *)
      (match args with
       | [] -> TUsize
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects no arguments: %s()" fname fname)))

  | Call (("msr_daifclr_irq" | "msr_daifset_irq" | "tlbi_vmalle1"
          | "dsb_ish" | "dsb_ishst" | "isb") as fname, args) ->
      (* GitHub issue #226: closed zero-argument barrier/TLBI/DAIF-immediate
         intrinsics. *)
      (match args with
       | [] -> TVoid
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects no arguments: %s()" fname fname)))

  | Call (("msr_cntp_tval_el0" | "msr_cntp_ctl_el0" | "msr_sctlr_el1"
          | "msr_mair_el1" | "msr_tcr_el1" | "msr_ttbr0_el1"
          | "tlbi_vaae1is" | "tlbi_vae1is" | "tlbi_aside1is") as fname, args) ->
      (* GitHub issue #226: closed system-register write / TLBI intrinsics
         taking the one usize value the instruction's Xt operand carries. *)
      (match args with
       | [v] ->
           let vt = infer_expr senv eenv tyenv fenv v in
           unify_at v.loc vt TUsize;
           TVoid
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects one argument: %s(v)" fname fname)))

  | Call (("smc4" | "hvc4") as fname, args) ->
      (* GitHub issue #226: the raw `smc #0` trap, exposed as a plain
         4-in/1-out hardware primitive (the real SMCCC x0-x3 in / x0 out
         convention lives in lib/llvm_gen.ml's fixed register constraints,
         not in any PSCI-specific semantics here -- this intrinsic knows
         nothing about PSCI, matching "closed set of instructions", not
         "closed set of hypervisor calls").
         GitHub issue #237 (QEMU port): hvc4 is the same 4-in/1-out shape
         over `hvc #0` instead of `smc #0` -- QEMU `virt`'s own guest DTB
         reports its PSCI conduit as "hvc", not "smc" (confirmed by
         dumping it: SMC trapped as an Undefined Instruction at EL1, since
         this boot configuration has no EL3 to trap to at all, only EL2).
         RPi5's real TF-A firmware uses SMC; identical SMCCC argument
         convention either way, so this is the same type rule with one
         more name, not a new rule. *)
      (match args with
       | [a; b; c; d] ->
           List.iter (fun arg ->
             let t = infer_expr senv eenv tyenv fenv arg in
             unify_at arg.loc t TUsize) [a; b; c; d];
           TUsize
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects four arguments: %s(x0, x1, x2, x3)" fname fname)))

  | Call ("svc5" as fname, args) ->
      (* GitHub issue #228 (dependency named by that issue: #226's own
         raw-instruction-primitive precedent, extended to `svc`): the raw
         Linux/AArch64 `svc #0` syscall trap, exposed as a plain 6-in/1-out
         hardware primitive -- syscall number in x8, up to five argument
         registers x0-x4, result in x0 (the real Linux AArch64 syscall ABI
         convention lives in lib/llvm_gen.ml's fixed register constraints,
         same shape as smc4's own SMCCC constraints just above). "5" names
         the five DATA argument registers this intrinsic exposes (x0-x4),
         matching every real Linux syscall the initial EL0 test payload
         issues today (issue #228) -- clone(2) is the widest at five
         (flags, stack, ptid, tls, ctid). Unused trailing arguments are
         simply passed as 0, the same convention a real `mov x4, #0`
         would already need in hand-written assembly for a narrower
         syscall. *)
      (match args with
       | [nr; a0; a1; a2; a3; a4] ->
           List.iter (fun arg ->
             let t = infer_expr senv eenv tyenv fenv arg in
             unify_at arg.loc t TUsize) [nr; a0; a1; a2; a3; a4];
           TUsize
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects six arguments: %s(nr, x0, x1, x2, x3, x4)" fname fname)))

  | Call (("dma_prepare_tx" | "dma_prepare_rx" | "dma_finish_rx") as fname, args) ->
      let required_alignment =
        match Target_info.dma_cache_contract () with
        | Target_info.Cache_line n -> Some n
        | Target_info.Coherent -> None
        | Target_info.Unsupported ->
            raise (TypeError (e.loc,
              Printf.sprintf
                "%s is unavailable because the selected target has no DMA cache-maintenance contract"
                fname))
      in
      (match args with
       | [ptr; len] ->
           let pt = infer_expr senv eenv tyenv fenv ptr in
           let lt = infer_expr senv eenv tyenv fenv len in
           (match fname, repr pt with
            (* GitHub issue #102 Stage 2 and #171 Stage 1:
               dma_prepare_rx/dma_finish_rx are
               cache-line INVALIDATE operations -- an unaligned range can
               silently discard live neighboring data (the real HardFault
               examples/common_stm32/sdmmc.tkb's own comment documents),
               so require a pointer proven aligned to the selected target's
               DMA cache line, closing
               the gap that file's disk_read_bounce bounce buffer used to
               work around. dma_prepare_tx is a CLEAN (writeback), which
               cannot lose data even when its rounding spills into an
               unrelated live cache line (same file's comment) -- stays
               accepting any raw pointer, unaffected. *)
            | ("dma_prepare_rx" | "dma_finish_rx"),
              (TPtr elem | TAlignedPtr (_, elem)) ->
                Option.iter (fun n ->
                  unify_at ptr.loc pt (TAlignedPtr (n, elem)))
                  required_alignment
            | ("dma_prepare_rx" | "dma_finish_rx"), _ ->
                raise (TypeError (ptr.loc, Printf.sprintf
                  "%s expects a raw pointer as its first argument" fname))
            | _, (TPtr _ | TAlignedPtr _) -> ()
            | _, _ -> raise (TypeError (ptr.loc, Printf.sprintf
                "%s expects a raw pointer as its first argument" fname)));
           unify_at len.loc lt TUsize;
           TVoid
       | _ -> raise (TypeError (e.loc, Printf.sprintf
           "%s expects two arguments: %s(ptr, len)" fname fname)))

  | Call (("checked_add_usize" | "checked_mul_usize") as fname, args) ->
      (match Hashtbl.find_opt variant_defs "CheckedUsize" with
       | Some cases ->
           let value_ok = match List.assoc_opt "Value" cases with
             | Some (Some Ast.TypeUsize) -> true
             | _ -> false
           in
           let overflow_ok = match List.assoc_opt "Overflow" cases with
             | Some None -> true
             | _ -> false
           in
           if List.length cases <> 2 || not value_ok || not overflow_ok then
             raise (TypeError (e.loc,
               "checked usize builtins require `variant CheckedUsize { Value(usize); Overflow; }`"))
       | None ->
           raise (TypeError (e.loc,
             "checked usize builtins require `variant CheckedUsize { Value(usize); Overflow; }`")));
      (match args with
       | [left; right] ->
           let lt = infer_expr senv eenv tyenv fenv left in
           let rt = infer_expr senv eenv tyenv fenv right in
           unify_at left.loc lt TUsize;
           unify_at right.loc rt TUsize;
           TVariant "CheckedUsize"
       | _ -> raise (TypeError (e.loc, Printf.sprintf
           "%s expects two usize arguments: %s(left, right)" fname fname)))

  | Call ("slice_copy", args) ->
      (* Builtin (reserved name, see check_reserved_fn): copies
         min(dst.len, src.len) elements FORWARD from src to dst and returns
         the count as usize. Total function -- no trap, no check; a length
         mismatch shows up in the return value, never as a runtime error.
         The forward loop makes overlapping ranges safe when dst does not
         lead src (same guarantee bytes_copy's callers already rely on,
         e.g. the payload shift in tcp_echo -- see CLAUDE.md). The compiler
         emits the loop itself, so no takibi-level index proof is needed:
         this is how variable-length buffer code stays inside the
         non-relational interval world. *)
      (match args with
       | [d; s] ->
           let dt = infer_expr senv eenv tyenv fenv d in
           let st = infer_expr senv eenv tyenv fenv s in
           let ev = fresh () in
           unify_at d.loc dt (TSlice (ev, 0));
           unify_at s.loc st (TSlice (ev, 0));
           TUsize
       | _ -> raise (TypeError (e.loc,
           "slice_copy expects 2 arguments: slice_copy(dst, src)")))

  | Call ("slice_eq", args) ->
      (* Builtin: true iff the lengths are equal AND all elements match.
         Total function -- length mismatch is false, not an error. *)
      (match args with
       | [a; b] ->
           let at = infer_expr senv eenv tyenv fenv a in
           let bt = infer_expr senv eenv tyenv fenv b in
           let ev = fresh () in
           unify_at a.loc at (TSlice (ev, 0));
           unify_at b.loc bt (TSlice (ev, 0));
           TBool
       | _ -> raise (TypeError (e.loc,
           "slice_eq expects 2 arguments: slice_eq(a, b)")))

  | Call (("min" | "max") as fname, args) ->
      (* Builtins (P4c-2): min(a,b)/max(a,b) on i32. Purely interval-domain
         range propagation -- no relational reasoning. This is the tool for
         clamping a wire-derived value against a compile-time buffer
         capacity: `min(ihl, 20)` is provably <= 20 no matter what ihl
         turns out to be at runtime, closing a gap a plain runtime bounds
         check used to be the only answer for (see CLAUDE.md's P4c
         section). Sync rule: llvm_gen.ml's Call case must compute the
         identical range.

         Each bound is derived independently, and each needs a DIFFERENT
         amount of information -- this asymmetry is the actual content of
         the rule, not a simplification:
           min(a,b) <= a and <= b ALWAYS (definition of min), so if EITHER
             operand's upper bound is known, that alone bounds the
             result's upper side -- the OTHER operand may be totally
             unconstrained. But min(a,b) could equal WHICHEVER operand is
             smaller, so a LOWER bound requires BOTH operands' lower
             bounds to be known (an unconstrained operand could always be
             the one that's smaller, dragging the result down with it).
           max is the mirror image: a lower bound needs only one operand
             known (`max(tcp_len, 0)` proves >= 0 even though tcp_len
             itself is a bare, unconstrained i32 parameter); an upper
             bound needs both.
         "Unknown" is represented with a wide sentinel range rather than
         a genuine option type, so the result is always a plain
         TRefinedInt: a subslice/index proof against any REAL buffer
         capacity will correctly fail to close against a sentinel bound
         (never falsely succeed), so this is a representational
         convenience, not a soundness-relevant choice. *)
      (match args with
       | [a; b] ->
           let at = infer_expr senv eenv tyenv fenv a in
           let bt = infer_expr senv eenv tyenv fenv b in
           if contains_view_ty at || contains_view_ty bt then
             raise (TypeError (e.loc,
               "erased views cannot be operands of runtime min/max"));
           (* Both arguments must agree on a base type, same as any other
              binary numeric operation (Add/Sub/etc.) -- previously
              hardcoded TI32 for both, independently, which meant
              min/max simply could not be used on u32/u64/usize-typed
              values at all. Unifying them against EACH OTHER instead
              (and tagging the result TRefinedInt with that base) is what
              lets `min(some_u64_val, 20)` type-check and stay refined. *)
           let base_raw = canon_ty at in
           unify_at e.loc base_raw (canon_ty bt);
           (* repr again AFTER unify_at: unify_at may have just resolved
              base_raw in place (e.g. a or b was a fresh, not-yet-bound
              IntLit type variable) -- base must be the FULLY resolved
              type before is_unsigned_ty inspects its concrete shape below,
              or an unresolved TVar would silently (and wrongly) read as
              "not unsigned" regardless of what it actually resolves to
              (found via a real regression: min/max on two u64 arguments
              raised a spurious "cannot unify" error because the sentinel
              range's negative lower bound doesn't fit an unsigned
              destination -- see sentinel_lo below). *)
           let base = repr base_raw in
           let range_of (ae : Ast.expr) (aty : ty) =
             match Const_env.bound_value ae with
             | Some k -> Some (k, k + 1)
             | None -> (match repr aty with TRefinedInt (x, y, _) -> Some (x, y) | _ -> None)
           in
           let (sentinel_lo, sentinel_hi) = min_max_sentinel base in
           let ra = range_of a at and rb = range_of b bt in
           let lo =
             match ra, rb with
             | Some (la, _), Some (lb, _) ->
                 if fname = "min" then min la lb else max la lb
             | _ -> if fname = "max" then
                      (match ra, rb with
                       | Some (la, _), None | None, Some (la, _) -> la
                       | _ -> sentinel_lo)
                    else sentinel_lo
           in
           let hi =
             match ra, rb with
             | Some (_, ha), Some (_, hb) ->
                 if fname = "min" then min ha hb else max ha hb
             | _ -> if fname = "min" then
                      (match ra, rb with
                       | Some (_, ha), None | None, Some (_, ha) -> ha
                       | _ -> sentinel_hi)
                    else sentinel_hi
           in
           TRefinedInt (lo, hi, base)
       | _ -> raise (TypeError (e.loc,
           Printf.sprintf "%s expects 2 arguments: %s(a, b)" fname fname)))

  | Call (fname, args) ->
      let direct = StringMap.find_opt fname fenv in
      let ft_opt = match direct with
        | Some [(target, ft)] ->
            resolved_call_targets := StringMap.add (loc_key e.loc) target !resolved_call_targets;
            Some (instantiate_static_params ft)
        | Some candidates ->
            let candidates = List.map (fun (target, ft) ->
              (target, instantiate_static_params ft)) candidates in
            let arg_tys = List.map (infer_expr senv eenv tyenv fenv) args in
            let exact (_, ft) = match repr ft with
              | TFun (ps, _, _) when List.length ps = List.length arg_tys ->
                  List.for_all2 (fun at pt ->
                    match repr at with
                    | TVar { contents = Unbound _ } -> false
                    | TRefinedInt (_, _, base) -> repr base = repr pt
                    | actual -> actual = repr pt
                  ) arg_tys ps
              | _ -> false
            in
            (match List.filter exact candidates with
             | [(target, ft)] ->
                 resolved_call_targets := StringMap.add (loc_key e.loc) target !resolved_call_targets;
                 Some ft
             | [] ->
                 let unresolved = List.exists (fun t -> match repr t with
                   | TVar { contents = Unbound _ } -> true | _ -> false) arg_tys in
                 let why = if unresolved then
                   "argument type is not determined; add an explicit type annotation or 'as' cast"
                 else "no overload has exactly matching parameter types" in
                 raise (TypeError (e.loc, Printf.sprintf "cannot resolve overload '%s': %s" fname why))
             | _ -> raise (TypeError (e.loc, Printf.sprintf "ambiguous overload call '%s'" fname)))
        | None ->
            match StringMap.find_opt fname tyenv with
            | Some (t, _) -> Some t
            | None -> None
      in
      (match ft_opt with
       | None ->
           raise (TypeError (e.loc,
             Printf.sprintf "Undefined function: %s" fname))
       | Some ft ->
           let (param_tys, ret_ty, call_effects) = match repr ft with
             | TFun (ps, r, effects) -> (ps, r, effects)
             | _ ->
                 raise (TypeError (e.loc,
                   Printf.sprintf "'%s' is not a function or function pointer" fname))
           in
           if not (StringMap.mem (loc_key e.loc) !resolved_call_targets) then
             resolved_indirect_call_effects := StringMap.add
               (loc_key e.loc) call_effects !resolved_indirect_call_effects;
           if List.length args <> List.length param_tys then
             raise (TypeError (e.loc,
               Printf.sprintf "%s expects %d argument(s), got %d"
                 fname (List.length param_tys) (List.length args)));
           let target = Option.value
             (StringMap.find_opt (loc_key e.loc) !resolved_call_targets)
             ~default:fname in
           let modes = Option.value
             (StringMap.find_opt target !function_param_modes)
             ~default:(List.map (fun _ -> None) param_tys) in
           let mutable_places = List.filter_map (fun ((arg : Ast.expr), mode) ->
             match mode, arg.desc with
             | Some (Ast.TypeBorrowMut _), Ast.Var name -> Some (name, arg.loc)
             | Some (Ast.TypeBorrowMut _), _ ->
                 raise (TypeError (arg.loc,
                   "borrow mut requires a bare mutable local or parameter; temporaries and projections have no scoped owner place"))
             | _ -> None
           ) (List.combine args modes) in
           List.iter (fun (name, loc) ->
             let (_, is_mutable) = lookup_binding loc name tyenv in
             if not is_mutable then
               raise (TypeError (loc, Printf.sprintf
                 "cannot mutably borrow immutable value '%s'; bind it with `let mut` or `Case(mut %s)`"
                 name name));
             if StringSet.mem name !active_readonly_borrows then
               raise (TypeError (loc, Printf.sprintf
                 "cannot mutably borrow shared-borrow parameter '%s'; declare the parameter `borrow mut` to forward mutable access"
                 name));
             let uses = List.fold_left (fun count arg ->
               count + count_var_occurrences name arg) 0 args in
             if uses > 1 then
               raise (TypeError (loc, Printf.sprintf
                 "mutable borrow of '%s' overlaps another argument in the same call"
                 name))
           ) mutable_places;
           (* GitHub issue #323: routed through check_expr, which now
              covers everything this hand-written loop used to do itself
              (the AddrOf-vs-TRef/TRefMut dispatch, existential-argument
              opening, adapt_actual_to_expected, unify_at,
              check_literal_fits_refined, check_io_ptr_literal_needs_unsafe
              -- see check_expr's own cases and its header comment).

              One case is deliberately bypassed: a bare `{ ... }`
              struct-literal argument. check_expr's own StructLit cases
              would make this type-check where it previously always raised
              "struct literal requires a type annotation" (call arguments
              never routed through check_expr's StructLit handling before,
              unlike Let initializers and nested struct-literal fields,
              which already allowed it) -- but llvm_gen.ml's codegen has no
              support for a StructLit as a general call-argument
              expression (its own gen_expr raises "BUG: StructLit must be
              handled in gen_stmt / gen_global, not gen_expr" for it,
              caught by this issue's own new regression test). Accepting
              it here would trade a clean, expected TypeError for an
              internal-error codegen crash, so this keeps the exact
              pre-#323 rejection for this one shape instead. *)
           List.iter2 (fun (arg : Ast.expr) pt ->
             match arg.desc with
             | StructLit _ -> ignore (infer_expr senv eenv tyenv fenv arg)
             | _ -> ignore (check_expr senv eenv tyenv fenv arg pt)
           ) args param_tys;
           ret_ty)
  | Assign (lhs, rhs) ->
      (* GitHub issue #184: relocated verbatim from the 4 old dedicated
         `infer_stmt` cases (Assign/AssignDeref/AssignIndex/AssignField),
         dispatched on the unified expr's LHS shape instead of 4 separate
         AST constructors -- same logic, same error messages, just now
         reached from infer_expr instead of infer_stmt (using the whole
         Assign expr's own `e.loc` wherever the old code used the
         enclosing statement's `s.loc`). Always returns TVoid: assignment
         is not itself a readable value in this language (see Ast.Assign's
         own comment for why). *)
      (match lhs.desc with
       | Var name ->
           check_private_global_access lhs.loc name;
           invalidate_place_projections name;
           if StringSet.mem name !active_readonly_borrows then
             raise (TypeError (e.loc, Printf.sprintf
               "cannot assign to borrowed value '%s'; use `borrow mut` for scoped mutation"
               name));
           let (vty, is_mut) = lookup_binding e.loc name tyenv in
           if contains_stable_owner_value_ty vty then
             raise (TypeError (e.loc,
               "stable owner container storage cannot be assigned or copied as a whole"));
           if not is_mut then
             raise (TypeError (e.loc,
               Printf.sprintf "cannot assign to immutable variable '%s'; use 'let mut'" name));
           let target_ty = strip_io vty in
           let unify_target = match repr target_ty with
             | TExists _ -> pack_exists_ty target_ty
             | _ -> target_ty
           in
           let ety = infer_expr senv eenv tyenv fenv rhs in
           let ety = adapt_actual_to_expected tyenv rhs ety unify_target in
           unify_at rhs.loc ety unify_target;
           check_literal_fits_refined rhs.loc rhs unify_target;
           check_io_ptr_literal_needs_unsafe rhs.loc rhs unify_target;
           TVoid
       | Deref ptr_expr ->
           let pt = infer_expr senv eenv tyenv fenv ptr_expr in
           check_deref_complete ptr_expr.loc pt;
           (match repr pt with
            | TRef _ ->
                (* GitHub issue #314/#319: same "&T is read-only, &mut T
                   isn't" gate as the FieldGet case above, but for `*r = v`
                   -- Deref's own widen-to-TPtr fallback below would
                   otherwise let a shared reference through by accident,
                   since TRef -> TPtr widening is unconditional. *)
                raise (TypeError (ptr_expr.loc, Printf.sprintf
                  "cannot write through a shared reference '%s'; declare it \
                   '&mut ...' instead"
                  (to_string pt)))
            | _ -> ());
           let inner = match repr pt with
             | TPtr i -> strip_io i
             | _ ->
                 let inner = fresh () in
                 unify_at ptr_expr.loc pt (TPtr inner);
                 inner
           in
           if contains_stable_owner_value_ty inner then
             raise (TypeError (e.loc,
               "stable owner container storage cannot be overwritten or copied through a pointer"));
           let vt = infer_expr senv eenv tyenv fenv rhs in
           let vt = adapt_actual_to_expected tyenv rhs vt inner in
           if contains_view_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store an erased view through a pointer"));
           if contains_variant_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store a variant through a pointer in Slice 3"));
           if is_tuple_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store a tuple through a pointer: tuples are values, not storage (OWNERSHIP_KERNEL.md 5.9)"));
           if is_linear_ptr_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store a linear value through a pointer: it would escape \
                obligation tracking (OWNERSHIP_KERNEL.md Stage 3 will lift this)"));
           if is_indexed_owner_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store an indexed owner through a pointer: it would escape obligation tracking"));
           unify_at rhs.loc vt inner;
           check_literal_fits_refined rhs.loc rhs inner;
           check_io_ptr_literal_needs_unsafe rhs.loc rhs inner;
           TVoid
       | Index (base, idx) ->
           check_no_write_through_shared_ref senv eenv tyenv fenv base;
           let vt = place_undecayed_type senv eenv tyenv fenv base in
           let it = infer_expr senv eenv tyenv fenv idx in
           Hashtbl.replace index_resolved_ty idx.loc (to_ast it);  (* GitHub issue #311 *)
           let rt = infer_expr senv eenv tyenv fenv rhs in
           let elem_ty = match repr vt with
             | TArray (elem, n) ->
                 require_usize_index idx.loc it;
                 (match idx.desc with
                  | IntLit k64 ->
                      (match Ast.int_of_intlit k64 with
                       | Some k when k >= n ->
                           raise (TypeError (idx.loc,
                             Printf.sprintf "index %d is out of bounds for array of size %d" k n))
                       | Some _ -> ()
                       | None ->
                           raise (TypeError (idx.loc,
                             Printf.sprintf "index %Ld is out of bounds for array of size %d" k64 n)))
                  | _ -> ());
                 elem
             | TSlice (elem, _) -> require_usize_index idx.loc it; elem
             | TPtr   elem      ->
                 check_ptr_arith_complete e.loc (repr vt);
                 require_isize_offset idx.loc it; strip_io elem
             | TAlignedPtr (_, elem) ->
                 check_ptr_arith_complete e.loc (repr vt);
                 require_isize_offset idx.loc it; strip_io elem
             | _ -> raise (TypeError (e.loc,
                 Printf.sprintf "index operator on non-array/pointer type '%s'" (to_string vt)))
           in
           if contains_stable_owner_value_ty elem_ty then
             raise (TypeError (e.loc,
               "stable owner container storage cannot be overwritten or copied through an index"));
           let rt = adapt_actual_to_expected tyenv rhs rt elem_ty in
           if contains_view_ty rt then
             raise (TypeError (rhs.loc,
               "cannot store an erased view into an array/slice element"));
           if contains_variant_ty rt then
             raise (TypeError (rhs.loc,
               "cannot store a variant into an array/slice element in Slice 3"));
           if is_tuple_ty rt then
             raise (TypeError (rhs.loc,
               "cannot store a tuple into an array/slice element: tuples are values, not storage (OWNERSHIP_KERNEL.md 5.9)"));
           if is_linear_ptr_ty rt then
             raise (TypeError (rhs.loc,
               "cannot store a linear value into an array/slice element: it would \
                escape obligation tracking (OWNERSHIP_KERNEL.md Stage 3 will lift this)"));
           if is_indexed_owner_ty rt then
             raise (TypeError (rhs.loc,
               "cannot store an indexed owner into an array/slice element: it would escape obligation tracking"));
           unify_at rhs.loc rt elem_ty;
           check_literal_fits_refined rhs.loc rhs elem_ty;
           check_io_ptr_literal_needs_unsafe rhs.loc rhs elem_ty;
           TVoid
       | FieldGet (base_expr, fname) ->
           let bt = infer_expr senv eenv tyenv fenv base_expr in
           (match repr bt with
            | TIndexedStruct _ ->
                (match base_expr.desc with
                 | Var name ->
                     if StringSet.mem name !active_readonly_borrows then
                       raise (TypeError (base_expr.loc, Printf.sprintf
                         "cannot mutate shared-borrow parameter '%s'; use `borrow mut` for scoped mutation"
                         name));
                     let (_, is_mut) = lookup_binding base_expr.loc name tyenv in
                     if not is_mut then
                       raise (TypeError (base_expr.loc, Printf.sprintf
                         "cannot assign a field of immutable indexed owner '%s'; use 'let mut'"
                         name))
                 | _ ->
                     raise (TypeError (base_expr.loc,
                       "field assignment on an indexed owner requires a mutable local or parameter")))
            | TRef _ ->
                (* GitHub issue #314/#319: shared &T grants read-only field
                   access; only &mut T may write. Unlike TPtr (which has
                   never distinguished this), &T is meant to make "this
                   parameter cannot mutate" a real, checked guarantee. *)
                raise (TypeError (base_expr.loc, Printf.sprintf
                  "cannot write field '.%s' through a shared reference '%s'; \
                   declare it '&mut ...' instead"
                  fname (to_string bt)))
            | _ -> ());
           let (sname, static_args) = match struct_instance (repr bt) with
             | Some x -> x
             | _ ->
                 raise (TypeError (base_expr.loc,
                   Printf.sprintf "field assignment '.%s' on non-struct type '%s'"
                     fname (to_string bt)))
           in
           let fields = match StringMap.find_opt sname senv with
             | Some (fs, _, _) -> fs
             | None ->
                 raise (TypeError (e.loc,
                   Printf.sprintf "unknown struct type '%s'" sname))
           in
           check_private_field_access e.loc sname fname;
           if is_stable_owner_field sname fname then
             raise (TypeError (e.loc, Printf.sprintf
               "stable owner field '%s.%s' cannot be assigned directly; use stable_replace while holding its guard"
               sname fname));
           let field_ty = match List.assoc_opt fname fields with
             | Some ft -> field_type_for_instance sname static_args ft
             | None ->
                 raise (TypeError (e.loc,
                   Printf.sprintf "no field '%s' in struct '%s'" fname sname))
           in
           let vt = infer_expr senv eenv tyenv fenv rhs in
           let vt = adapt_actual_to_expected tyenv rhs vt (strip_io field_ty) in
           if contains_view_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store an erased view into a struct field"));
           if contains_kinded_variant_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store an affine/linear variant into a struct field"));
           if is_tuple_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store a tuple into a struct field: tuples are values, not storage (OWNERSHIP_KERNEL.md 5.9)"));
           if is_linear_ptr_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store a linear value into a struct field: it would escape \
                obligation tracking (OWNERSHIP_KERNEL.md Stage 3 will lift this)"));
           if is_indexed_owner_ty vt then
             raise (TypeError (rhs.loc,
               "cannot store an indexed owner into a struct field: it would escape obligation tracking"));
           unify_at rhs.loc vt (strip_io field_ty);
           check_literal_fits_refined rhs.loc rhs (strip_io field_ty);
           check_io_ptr_literal_needs_unsafe rhs.loc rhs (strip_io field_ty);
           TVoid
       | _ ->
           raise (TypeError (lhs.loc, "not an assignable expression")))

(* GitHub issue #314/#319 follow-up: index-assignment through an array
   FIELD reached via a shared &T was not gated the way a direct
   `.field = v` write or a `*r = v` write already are -- struct_instance/
   place_undecayed_type resolve the field name identically for &T and
   &mut T, so `r.some_array_field[i] = v;` silently succeeded through a
   shared reference. Walks the FieldGet chain rooted at an Index/AssignIndex
   base (the same "any depth" chain place_undecayed_type itself supports)
   checking each level's own immediate base type; a plain struct-valued
   intermediate field (not itself &-typed) never matches TRef, so this
   never rejects legitimate code, only the previously-unchecked shared
   -reference-write case. *)
and check_no_write_through_shared_ref senv eenv tyenv fenv (e : Ast.expr) : unit =
  match e.desc with
  | FieldGet (inner_expr, _) ->
      let inner_ty = infer_expr senv eenv tyenv fenv inner_expr in
      (match repr inner_ty with
       | TRef _ ->
           raise (TypeError (inner_expr.loc, Printf.sprintf
             "cannot write through a shared reference '%s'; declare it \
              '&mut ...' instead"
             (to_string inner_ty)))
       | _ -> check_no_write_through_shared_ref senv eenv tyenv fenv inner_expr)
  | _ -> ()

(* GitHub issue #314/#319: shared &expr (AddrOf) validation/typing, shared
   between infer_expr's own default (unconstrained) case and check_expr's
   expected-type-directed cases. `wrap` selects what the proven address is
   wrapped in: `Ptr (today's unconstrained default -- TAlignedPtr when an
   align(N) proof is available, else plain TPtr, byte-for-byte the same as
   before this type existed), `Ref (shared &T), or `RefMut (exclusive
   &mut T). The minting rules themselves (bare variable or struct field
   only, mutable local or any global, rejecting linear/indexed-owner/view/
   variant/singleton targets) are IDENTICAL regardless of `wrap` -- &T/
   &mut T does not relax or add to what & already refuses to mint, it only
   changes what type a successful mint produces. *)
and infer_addrof_wrapped senv eenv tyenv fenv (e : Ast.expr) (inner : Ast.expr)
    (wrap : [`Ptr | `Ref | `RefMut]) : ty =
  (match inner.desc with
   | Var name ->
       check_private_global_access e.loc name;
       let (t, is_mut) = lookup_binding e.loc name tyenv in
       (match repr t with
        | TPtr _ | TAlignedPtr _ -> invalidate_place_projections name
        | _ -> ());
       if is_linear_ptr_ty t then
         raise (TypeError (e.loc, Printf.sprintf
           "cannot take the address of linear value '%s': an alias would \
            escape obligation tracking" name));
       if is_indexed_owner_ty t then
         raise (TypeError (e.loc, Printf.sprintf
           "cannot take the address of indexed owner '%s': an alias would \
            escape obligation tracking" name));
       if contains_view_ty t then
         raise (TypeError (e.loc, Printf.sprintf
           "cannot take the address of erased view '%s': views have no runtime storage"
           name));
       if is_variant_ty t then
         raise (TypeError (e.loc, Printf.sprintf
           "cannot take the address of variant '%s': an alias would escape payload ownership tracking"
           name));
       if contains_singleton_ty t then
         raise (TypeError (e.loc, Printf.sprintf
           "cannot take the address of singleton value '%s': mutation \
            through a widened pointer would invalidate its static identity"
           name));
       if not is_mut then
         raise (TypeError (e.loc,
           Printf.sprintf "cannot take address of immutable variable '%s'" name));
       (match wrap with
        | `Ref -> TRef t
        | `RefMut -> TRefMut t
        | `Ptr ->
            (* GitHub issue #102: &x on an align(N)-declared variable proves
               *align(N) T, same source as the array-decay case above. *)
            check_no_nested_ptr_mint e.loc t;
            (match StringMap.find_opt name !var_align_bytes with
             | Some n -> TAlignedPtr (n, t)
             | None -> TPtr t))
   | FieldGet (base_expr, fname) ->
       let bt = infer_expr senv eenv tyenv fenv base_expr in
       let sname = match repr bt with
         | TStruct s | TPtr (TStruct s) | TPtr (TIo (TStruct s))
         | TAlignedPtr (_, TStruct s)
         | TRef (TStruct s) | TRefMut (TStruct s) -> s
         | _ -> raise (TypeError (base_expr.loc,
             Printf.sprintf "field address '.%s' on non-struct type '%s'"
               fname (to_string bt)))
       in
       let fields = match StringMap.find_opt sname senv with
         | Some (fs, _, _) -> fs
         | None -> raise (TypeError (e.loc,
             Printf.sprintf "unknown struct type '%s'" sname))
       in
       check_private_field_access e.loc sname fname;
       if is_stable_owner_field sname fname then
         raise (TypeError (e.loc, Printf.sprintf
           "stable owner field '%s.%s' cannot be addressed; use stable_replace while holding its guard"
           sname fname));
       (match List.assoc_opt fname fields with
        | Some ft ->
            let ft_ty = of_ast ft in
            (match wrap with
             | `Ptr -> check_no_nested_ptr_mint e.loc ft_ty; TPtr ft_ty
             | `Ref -> TRef ft_ty
             | `RefMut -> TRefMut ft_ty)
        | None -> raise (TypeError (e.loc,
            Printf.sprintf "no field '%s' in struct '%s'" fname sname)))
   | _ ->
       raise (TypeError (e.loc, "& requires a variable or struct field")))

(* GitHub issue #217: shared struct-field-access logic for both an ordinary
   field READ (FieldGet -- decays an array-typed field to a bare element
   pointer, `decay:true`) and an Index/SliceOf base's UN-DECAYED type
   recovery (`decay:false`, called from place_undecayed_type below). Single-
   sourced rather than duplicated so privacy/stable-owner checks and error
   messages can never drift between the two call sites -- the only actual
   difference between them is the one `match ... with TArray -> TPtr ...`
   step at the very end. *)
and infer_field_access ~decay senv eenv tyenv fenv (loc : Ast.loc)
    (base_expr : Ast.expr) (fname : string) : ty =
  let bt = infer_expr senv eenv tyenv fenv base_expr in
  match repr bt, fname with
  | TSlice _, "len" -> TUsize  (* s.len -- the slice's runtime length *)
  | bt_repr, _ ->
      let (sname, static_args) = match struct_instance bt_repr with
        | Some x -> x
        | _ ->
            raise (TypeError (base_expr.loc,
              Printf.sprintf "field access '.%s' on non-struct type '%s'"
                fname (to_string bt)))
      in
      let fields = match StringMap.find_opt sname senv with
        | Some (fs, _, _) -> fs
        | None ->
            raise (TypeError (loc,
              Printf.sprintf "unknown struct type '%s'" sname))
      in
      check_private_field_access loc sname fname;
      if is_stable_owner_field sname fname then
        raise (TypeError (loc, Printf.sprintf
          "stable owner field '%s.%s' cannot be read directly; use stable_replace while holding its guard"
          sname fname));
      (match List.assoc_opt fname fields with
       | Some ft ->
           let raw = field_type_for_instance sname static_args ft in
           if not decay then raw
           else (match raw with
             | TArray (inner, _) ->
                 check_no_nested_ptr_mint loc inner;
                 TPtr inner  (* array field decays to *elem *)
             | TIo    inner      -> inner        (* io field returns value type T (volatile handled in codegen) *)
             | t                 -> t)
       | None ->
           raise (TypeError (loc,
             Printf.sprintf "no field '%s' in struct '%s'" fname sname)))

(* GitHub issue #217: recover the UN-DECAYED declared type of a restricted
   Index/SliceOf base path -- a bare variable, or a chain of struct field
   accesses (through a pointer or value struct) rooted in one -- mirroring
   static_place_key's own restricted-shape recognition just above. Any
   other expr shape is rejected here: allowing indexing's base to be
   syntactically any expr (see the parser's own comment on Index/SliceOf)
   does not mean any expr is a semantically legal one, and only this
   restricted set keeps a direct, non-inferring lookup of the base's
   un-decayed type tractable, the same reasoning that motivated keeping
   Index's base an `ident` in the first place before this fix. A FieldGet
   chain of any depth (`a.b.c[i]`) works through ordinary recursion here
   (only the OUTERMOST field needs the un-decayed treatment -- ordinary
   infer_expr already threads intermediate struct-typed field addresses
   through correctly) and its matching codegen (llvm_gen.ml's
   gen_field_access ~decay:false) shares that same property. Deliberately
   NOT extended to another Index as a base (`a[i].field`, `a[i][j]`):
   doing so would need an address-preserving variant of Index's own
   codegen (today's Index always LOADS the final element value, discarding
   its address) that does not exist yet -- left for a follow-up rather
   than accepted here and left to crash the compiler at codegen. *)
and place_undecayed_type senv eenv tyenv fenv (e : Ast.expr) : ty =
  match e.desc with
  | Ast.Var name ->
      check_private_global_access e.loc name;
      lookup e.loc name tyenv
  | Ast.FieldGet (base_expr, fname) ->
      infer_field_access ~decay:false senv eenv tyenv fenv e.loc base_expr fname
  | Ast.Index _ ->
      raise (TypeError (e.loc,
        "indexing another index expression's result directly (`a[i][j]` or \
         `a[i].field[j]`) is not yet supported; bind the intermediate \
         result to a variable first"))
  | _ ->
      raise (TypeError (e.loc,
        "an index/slice base must be a variable or a chain of struct field \
         accesses, not an arbitrary expression"))

(* -- Checking mode --------------------------------------------------------- *)
(* check_expr pushes the expected type inward (bidirectional checking).
   Handles nested StructLit for both struct and array fields.
   Falls back to infer_expr + unify for all other expressions. *)

(* GitHub issue #323: returns the actual/resolved type (mirroring
   infer_expr's own return), not just unit -- needed so callers that
   route through this function (Let's initializer handling, in
   particular) can still see the resolved type for their own follow-up
   checks (e.g. the struct-by-value alloca check just below this
   function's own call sites) the same way they could when they called
   infer_expr/unify_at directly instead of through here. *)
and check_expr senv eenv tyenv fenv (e : Ast.expr) (expected : ty) : ty =
  match e.desc, repr expected with
  | StructLit exprs, TArray (elem_ty, n) ->
      if List.length exprs <> n then
        raise (TypeError (e.loc, Printf.sprintf
          "array [_; %d] expects %d elements but literal has %d"
          n n (List.length exprs)));
      List.iter (fun ei -> ignore (check_expr senv eenv tyenv fenv ei elem_ty)) exprs;
      expected
  | StructLit exprs, TStruct sname ->
      let fields = match StringMap.find_opt sname senv with
        | Some (fs, _, _) -> fs
        | None -> raise (TypeError (e.loc,
            Printf.sprintf "unknown struct type '%s'" sname))
      in
      check_private_struct_literal e.loc sname;
      if List.length fields <> List.length exprs then
        raise (TypeError (e.loc, Printf.sprintf
          "struct '%s' has %d fields but literal has %d values"
          sname (List.length fields) (List.length exprs)));
      List.iter2 (fun (_, ft) ei ->
        ignore (check_expr senv eenv tyenv fenv ei (of_ast ft))
      ) fields exprs;
      expected
  | StructLit exprs, TIndexedStruct (sname, static_args) ->
      let fields = match StringMap.find_opt sname senv with
        | Some (fs, _, _) -> fs
        | None -> raise (TypeError (e.loc,
            Printf.sprintf "unknown struct type '%s'" sname))
      in
      check_private_struct_literal e.loc sname;
      if List.length fields <> List.length exprs then
        raise (TypeError (e.loc, Printf.sprintf
          "struct '%s' has %d fields but literal has %d values"
          sname (List.length fields) (List.length exprs)));
      List.iter2 (fun (_, ft) ei ->
        ignore (check_expr senv eenv tyenv fenv ei
          (field_type_for_instance sname static_args ft))
      ) fields exprs;
      expected
  | AddrOf inner, TRef _ ->
      (* GitHub issue #314/#319: &expr's own grammar/minting rules never
         change (see infer_addrof_wrapped); only which type a successful
         mint produces depends on context, exactly like a call argument's
         declared parameter type already directs struct-literal checking
         above. A not-yet-migrated *T-typed context skips this case
         entirely (falls to the generic branch below, unchanged from
         before this type existed) -- so every existing `&x` call site
         keeps compiling with zero changes.
         GitHub issue #323: check_literal_fits_refined added here to match
         what the Call-argument and Let-initializer call sites already did
         in their own, now-removed, duplicate AddrOf/TRef cases -- a
         behavior difference from before #323 for this exact branch's
         OTHER two callers (StructLit field checking), which never
         exercised it since &expr cannot appear inside a `{ ... }`
         literal's own value list. *)
      let actual = infer_addrof_wrapped senv eenv tyenv fenv e inner `Ref in
      unify_at e.loc actual expected;
      check_literal_fits_refined e.loc e expected;
      actual
  | AddrOf inner, TRefMut _ ->
      let actual = infer_addrof_wrapped senv eenv tyenv fenv e inner `RefMut in
      unify_at e.loc actual expected;
      check_literal_fits_refined e.loc e expected;
      actual
  | _ ->
      let te = infer_expr senv eenv tyenv fenv e in
      (* GitHub issue #323: existential elimination, moved here from the
         Call-argument loop's own copy (see its own comment, now removed)
         -- an existentially-typed argument/initializer (e.g. a LetMatch-
         bound local passed to a parameter/annotation expecting the
         concrete shape underneath) must be opened before unify_at, or it
         always fails against `expected`'s own sealed binder. Previously
         only Call's own path did this; StructLit-field and Let-initializer
         callers of this function did not, though neither is currently
         known to be reachable with an existentially-typed field/init
         value in the existing test suite or kernel/ tree. *)
      let te = match repr te with
        | TExists _ -> open_exists_ty te
        | _ -> te
      in
      let te = adapt_actual_to_expected tyenv e te (strip_io expected) in
      (* If expected type is io T: check compatibility with T (strip the storage qualifier) *)
      (* GitHub issue #310: append a guard-narrowing hint when THIS exact
         failure shape (an "unproven" value flowing into a refined/proven
         target) names a variable an earlier early-return guard couldn't
         narrow -- see guard_narrow_hints' own comment. Purely additive to
         an error that was already going to fire (same loc, longer text),
         so this cannot change which programs are accepted; scoped to
         messages containing "unproven" so an unrelated unify failure for
         the same variable (a genuine type mismatch, not a missing proof)
         is not given a non-sequitur hint. *)
      (try unify_at e.loc te (strip_io expected)
       with TypeError (eloc, msg) ->
         let hint = match e.desc with
           | Var name when contains_substring msg "unproven" ->
               Hashtbl.find_opt guard_narrow_hints name
           | _ -> None
         in
         (match hint with
          | Some h -> raise (TypeError (eloc, msg ^ " (" ^ h ^ ")"))
          | None -> raise (TypeError (eloc, msg))));
      check_literal_fits_refined e.loc e (strip_io expected);
      check_io_ptr_literal_needs_unsafe e.loc e (strip_io expected);
      te

(* -- Flow-sensitive type narrowing ----------------------------------------- *)

(* Collect per-variable bounds from a condition: v >= lo / v < hi / && chains.
   Returns name -> (lo_opt, hi_opt). Commutative forms (lo < v) are also handled. *)
(* Collect per-variable bounds from an if condition. A comparison
   constrains `Var n` whenever the OTHER operand's static value range is
   known: an integer literal k is {k..<k+1}, a Const_env constant likewise;
   addition/subtraction of those constants is folded before narrowing;
   and a variable whose binding is refined contributes its own range
   (`total_len <= ip_len_in_frame` narrows total_len's upper bound to
   ip_len_in_frame's static maximum -- the fact collapses to a CONSTANT at
   collection time, so this is still interval reasoning, not a relational
   domain, and no new kill obligations arise: the constant was true when
   the condition executed and n's own kill is governed by written_names as
   before). Equality (`ihl == 20`) narrows to the operand's exact range.
   Sync rule: llvm_gen.ml's collect_bounds_cond is the same algorithm over
   its own binding tables; change the two together. *)
let collect_bounds tyenv (cond : Ast.expr) : (int option * int option) StringMap.t =
  let take_lo a b = match a, b with
    | Some x, Some y -> Some (max x y)
    | Some _, None -> a | None, _ -> b in
  let take_hi a b = match a, b with
    | Some x, Some y -> Some (min x y)
    | Some _, None -> a | None, _ -> b in
  let update name lo_opt hi_opt acc =
    let (pl, ph) = match StringMap.find_opt name acc with
      | Some p -> p | None -> (None, None) in
    StringMap.add name (take_lo lo_opt pl, take_hi hi_opt ph) acc
  in
  (* Static value range of a comparison operand, when known. *)
  let range_of (e : Ast.expr) =
    match Const_env.folded_value e with
    | Some k -> Some (k, k + 1)
    | None ->
        (match e.desc with
         | Var m ->
             (match StringMap.find_opt m tyenv with
              | Some (t, _) ->
                  (match repr t with
                   | TRefinedInt (a, b, _) -> Some (a, b)
                   | _ -> None)
              | None -> None)
         | _ -> None)
  in
  (* n <op> rhs where rhs's range is {c..<d} (so c <= rhs <= d-1). *)
  let constrain_left op n (c, d) acc =
    match op with
    | Ast.Ge -> update n (Some c)       None           acc
    | Ast.Gt -> update n (Some (c + 1)) None           acc
    | Ast.Le -> update n None           (Some d)       acc
    | Ast.Lt -> update n None           (Some (d - 1)) acc
    | Ast.Eq -> update n (Some c)       (Some d)       acc
    | _ -> acc
  in
  (* lhs <op> n where lhs's range is {c..<d} -- the mirrored constraints. *)
  let constrain_right op n (c, d) acc =
    match op with
    | Ast.Ge -> update n None           (Some d)       acc  (* n <= lhs *)
    | Ast.Gt -> update n None           (Some (d - 1)) acc  (* n <  lhs *)
    | Ast.Le -> update n (Some c)       None           acc  (* n >= lhs *)
    | Ast.Lt -> update n (Some (c + 1)) None           acc  (* n >  lhs *)
    | Ast.Eq -> update n (Some c)       (Some d)       acc
    | _ -> acc
  in
  let rec go (e : Ast.expr) acc = match e.desc with
    | BinOp (And, e1, e2) -> go e2 (go e1 acc)
    | BinOp ((Ge | Gt | Le | Lt | Eq) as op, l, r) ->
        let acc = match l.desc, range_of r with
          | Var n, Some rng -> constrain_left op n rng acc
          | _ -> acc
        in
        (match r.desc, range_of l with
         | Var n, Some rng -> constrain_right op n rng acc
         | _ -> acc)
    | _ -> acc
  in
  go cond StringMap.empty

(* Narrow the type environment for the then-branch of an if statement.
   Narrows int bindings (both mutable and immutable) when both lo and hi bounds are proven
   by the condition. Mutability is preserved so that assignment inside the branch still works.
   Codegen-side narrowing for bounds-check elision goes through the same kill rule.

   Invalidation (kill) rule: a variable the branch body may write to, alias
   (&x), or rebind is NOT narrowed at all -- the condition only proves the
   range at the moment it was evaluated, and any later write invalidates
   that proof (`if (v >= 0 && v < 8) { v = 100; use(v); }`). The kill set
   comes from Ast.written_names; llvm_gen.ml's apply_narrowing/_mut use the
   same function on the same body (sync rule -- see written_names' comment). *)
let narrow_from_cond tyenv (cond : Ast.expr) (then_body : Ast.stmt list) =
  let killed = Ast.written_names then_body in
  let bounds = collect_bounds tyenv cond in
  let env =
    StringMap.fold (fun name (lo_opt, hi_opt) env ->
      if List.mem name killed then env
      else match StringMap.find_opt name env with
      (* Already refined (e.g. an immutable let whose initializer was
         itself refined, kept via the "proofs survive weaker
         annotations" rule -- see check_bound_shadowing/B-plan) --
         INTERSECT rather than no-op. Without this, a variable that
         arrives at the if already-refined (very common once P4a's
         interval propagation is in play) would silently keep its
         WIDER pre-existing range instead of the tighter one the
         condition just proved, e.g. `icmp_len: {0..<1481}` at entry
         plus `if (icmp_len >= 8 && icmp_len <= 1480)` must become
         {8..<1481}, not stay {0..<1481}.
         GitHub issue #99: a single-sided `hi`-only condition (lo_opt =
         None) still narrows here, falling back to the variable's OWN
         already-proven `elo` as the effective lower bound -- sound
         unconditionally, since `elo` was already established as a valid
         lower bound before this condition was even reached. *)
      | Some (TRefinedInt (elo, ehi, base), is_mut) ->
          (match lo_opt, hi_opt with
           | Some lo, Some hi -> StringMap.add name (TRefinedInt (max lo elo, min hi ehi, base), is_mut) env
           | None, Some hi    -> StringMap.add name (TRefinedInt (elo, min hi ehi, base), is_mut) env
           | Some lo, None    -> StringMap.add name (TRefinedInt (max lo elo, ehi, base), is_mut) env
           | None, None       -> env)
      (* Any plain primitive integer type can be narrowed, not just
         TI32 -- a u8/u16/u32/u64/usize/i8/i16/i64-typed variable
         narrowed by an if-condition keeps ITS OWN type as the
         refined range's base (see types.ml's TRefinedInt comment).
         GitHub issue #99: for an UNSIGNED base with no lo_opt from the
         condition (e.g. `if (off < 511)`, not `if (off >= 0 && off <
         511)`), 0 is already a sound lower bound regardless of the
         condition -- every unsigned value is trivially >= 0 -- so the
         redundant explicit `>= 0` check is no longer required to trigger
         narrowing. Signed bases still require an explicit lo (no implicit
         floor exists for them). *)
      | Some ((TI8|TI16|TI32|TI64|TU8|TU16|TU32|TU64|TIsize|TUsize) as base, is_mut) ->
          let lo_opt = match lo_opt with
            | Some _ -> lo_opt
            | None -> if is_unsigned_ty base then Some 0 else None
          in
          (match lo_opt, hi_opt with
           | Some lo, Some hi -> StringMap.add name (TRefinedInt (lo, hi, base), is_mut) env
           | _ -> env)
      | _ -> env
    ) bounds tyenv
  in
  (* Slice minimum-length narrowing: `if (s.len >= K)` upgrades s's proven
     minimum for the branch. Same kill rule; llvm_gen's apply_narrowing/_mut
     consume the same Ast.slice_len_mins (sync rule). *)
  List.fold_left (fun env (name, k) ->
    if List.mem name killed then env
    else match StringMap.find_opt name env with
      | Some (t, is_mut) ->
          (match repr t with
           | TSlice (el, m) when k > m ->
               StringMap.add name (TSlice (el, k), is_mut) env
           | _ -> env)
      | None -> env
  ) env (Ast.slice_len_mins ~resolve_const:Const_env.find cond)

(* Logical negation of a condition expression, for narrowing the
   fallthrough path after an early-return guard (`if (cond) { return
   ...; }` with no else -- see stmt_list_always_returns/narrow_from_cond
   below). De Morgan's laws for And/Or, flipped relational operators for
   comparisons. Deliberately conservative: any condition shape not
   listed (function calls, field/index access used as a bool, anything
   this file's own `collect_bounds` would not have understood on the
   POSITIVE side either) returns None rather than guessing, matching
   collect_bounds' own "only known shapes contribute a bound" philosophy
   just above. Only ever applied to a condition already accepted by
   check_cond as boolean, so no further validation is needed here. *)
let rec negate_cond (e : Ast.expr) : Ast.expr option =
  match e.desc with
  | BinOp (And, a, b) ->
      (match negate_cond a, negate_cond b with
       | Some na, Some nb -> Some { e with desc = BinOp (Or, na, nb) }
       | _ -> None)
  | BinOp (Or, a, b) ->
      (match negate_cond a, negate_cond b with
       | Some na, Some nb -> Some { e with desc = BinOp (And, na, nb) }
       | _ -> None)
  | BinOp (Lt, a, b) -> Some { e with desc = BinOp (Ge, a, b) }
  | BinOp (Ge, a, b) -> Some { e with desc = BinOp (Lt, a, b) }
  | BinOp (Le, a, b) -> Some { e with desc = BinOp (Gt, a, b) }
  | BinOp (Gt, a, b) -> Some { e with desc = BinOp (Le, a, b) }
  | BinOp (Eq, a, b) -> Some { e with desc = BinOp (Ne, a, b) }
  | BinOp (Ne, a, b) -> Some { e with desc = BinOp (Eq, a, b) }
  | _ -> None

(* GitHub issue #310: populates guard_narrow_hints (declared near the top
   of this file, before check_expr, so check_expr's fallback -- defined
   earlier than negate_cond in this file's own dependency order -- can
   read it without a forward reference). When an early-return guard's
   negation can't narrow the fallthrough -- negate_cond returns None (an
   unrecognized shape), or returns Some but the negated shape is an Or at
   the top (from negating an And-guard; collect_bounds' own `go` has no
   Or case, see its comment), or a comparison inside the guard uses `==`
   (whose negation `!=` collect_bounds also has no case for) -- records
   WHY per mentioned variable, reusing negate_cond/collect_bounds' own
   existing shape recognition rather than inventing a second
   classification (this issue's own scope). Consulted by check_expr's
   fallback (the single choke point issue #323 already routes both
   call-argument and let-initializer checking through) when a "cannot
   pass unproven" error names one of these variables, so the message
   explains the actual reason instead of leaving it to be re-derived from
   source. Diagnostics-only: never consulted by narrow_from_cond or any
   other narrowing-DECISION site, so it cannot change which programs are
   accepted -- only appended to an error that was already going to fire. *)
let record_guard_narrow_hints (cond : Ast.expr) =
  let var_of (e : Ast.expr) = match e.desc with Var n -> Some n | _ -> None in
  let rec comparison_vars (e : Ast.expr) acc = match e.desc with
    | BinOp ((And | Or), a, b) -> comparison_vars b (comparison_vars a acc)
    | BinOp ((Ge | Gt | Le | Lt | Eq | Ne), l, r) ->
        List.filter_map var_of [l; r] @ acc
    | _ -> acc
  in
  let rec eq_vars (e : Ast.expr) acc = match e.desc with
    | BinOp (And, a, b) -> eq_vars b (eq_vars a acc)
    | BinOp (Eq, l, r) -> List.filter_map var_of [l; r] @ acc
    | _ -> acc
  in
  let generic_hint n = Printf.sprintf
    "'%s' was the subject of an early-return guard above whose negation \
     is not a condition shape this compiler's narrowing recognizes (e.g. \
     an Or, or an unrecognized comparison) -- wrap this use in an \
     explicit `if (...) { ...; use %s ...; }` instead of relying on the \
     guard's own fallthrough narrowing" n n
  in
  let eq_hint n = Printf.sprintf
    "'%s' was the subject of an early-return guard above using '==', \
     whose negation ('!=') cannot narrow the fallthrough to a single \
     contiguous range -- rewrite the guard using < or >= instead (e.g. \
     `if (%s < N) { return; }`), or wrap this use in an explicit \
     `if (%s ...) { ... }`" n n n
  in
  (match negate_cond cond with
   | None ->
       List.iter (fun n -> Hashtbl.replace guard_narrow_hints n (generic_hint n))
         (comparison_vars cond [])
   | Some neg ->
       (match neg.desc with
        | BinOp (Or, _, _) ->
            List.iter (fun n -> Hashtbl.replace guard_narrow_hints n (generic_hint n))
              (comparison_vars cond [])
        | _ -> ()));
  List.iter (fun n -> Hashtbl.replace guard_narrow_hints n (eq_hint n))
    (eq_vars cond [])

(* Purely syntactic "does this statement list always return" check, local
   to the range-narrowing pass (kept separate from the resource-flow
   checker's own always_terminates further down in this file -- same
   name, independently scoped, deliberately not shared: this one only
   needs to answer "is the fallthrough path after this branch dead",
   not the resource-flow checker's fuller noreturn-function/Match
   handling, and duplicating a five-line conservative check is lower
   risk than threading a shared helper across two otherwise-unrelated
   passes). Conservative in the safe direction, same as its namesake:
   a loop is never treated as a terminator, and any statement shape not
   explicitly listed returns false. *)
let rec stmt_always_returns (s : Ast.stmt) : bool = match s.desc with
  | Ast.Return _ -> true
  | Ast.If (_, yes, no) ->
      no <> [] && stmt_list_always_returns yes && stmt_list_always_returns no
  | Ast.Block body | Ast.UnsafeBlock body -> stmt_list_always_returns body
  | _ -> false
and stmt_list_always_returns stmts = List.exists stmt_always_returns stmts

(* GitHub issue #184: LetMatch's arms end in `Yield e` (this arm's value)
   or a diverging statement -- but LetMatch's own infer_stmt/check_stmt
   cases reuse `Match`'s ~300-line exhaustiveness/linear-payload engine
   as a black box, by recursing on a synthesized `Match (disc, arms)`
   node (see those cases' own comments). That shared Match engine has no
   notion of "capture this arm's value into a name" -- a bare `Yield e`
   walked through it just evaluates `e` and discards it (correct for an
   ORDINARY `match` statement, where the value genuinely has nowhere to
   go). So LetMatch's own case rewrites each arm's terminal `Yield e`
   into `Expr (Assign (Var name, e))` -- literally reconstructing the
   exact `name = e;` shape the pre-#184 sentinel-rewrite parser hack used
   to produce -- immediately before constructing the synthesized `Match`
   node, so the shared engine sees an ordinary, already-well-understood
   Assign-statement arm and needs no LetMatch-specific awareness at all.
   Purely an internal AST transform: the SOURCE syntax stays the clean
   `Allocated(p) => p;` tail; only the desugared tree handed to Match's
   engine differs. A diverging arm (Return/Break/Continue) has nothing to
   capture and passes through unchanged. Sync rule: llvm_gen.ml's own
   LetMatch codegen case needs the identical rewrite -- see its own copy
   of this function. *)
let rewrite_letmatch_arm_bodies (name : string) (arms : Ast.match_arm list)
    : Ast.match_arm list =
  let rewrite_body stmts =
    match List.rev stmts with
    | { Ast.desc = Ast.Yield e; loc } :: rest ->
        let assign = { Ast.desc = Ast.Assign (
          { Ast.desc = Ast.Var name; loc }, e); loc } in
        List.rev ({ Ast.desc = Ast.Expr assign; loc } :: rest)
    | _ -> stmts (* diverges; nothing to capture *)
  in
  List.map (function
    | Ast.ArmVariant (v, c, b, stmts) -> Ast.ArmVariant (v, c, b, rewrite_body stmts)
    | Ast.ArmWild stmts -> Ast.ArmWild (rewrite_body stmts)
    | Ast.ArmIntLit (ns, stmts) -> Ast.ArmIntLit (ns, rewrite_body stmts)
  ) arms

(* -- Statement inference --------------------------------------------------- *)
(* Returns (updated_tyenv, updated_raw_locals).
   tyenv grows with each Let in the current scope.
   raw_locals accumulates every Let type seen (including inside blocks/if/while)
   so that codegen can pre-allocate mutable locals at function entry. *)

let rec infer_stmt senv eenv tyenv fenv ret_ty raw_locals in_loop (s : Ast.stmt)
    : tyenv * ty StringMap.t =
  match s.desc with
  | Break | Continue ->
      if not in_loop then
        raise (TypeError (s.loc, "break/continue outside of a loop"));
      (tyenv, raw_locals)
  | Return None ->
      (match ret_ty with
       | TVoid -> ()
       | _ -> raise (TypeError (s.loc,
           "bare `return;` requires a void return type; this function returns a value -- use `return e;`")));
      (tyenv, raw_locals)
  | Return (Some e) ->
      let t = infer_expr senv eenv tyenv fenv e in
      let t = adapt_actual_to_expected tyenv e t ret_ty in
      unify_at e.loc t ret_ty;
      check_literal_fits_refined e.loc e ret_ty;
      check_io_ptr_literal_needs_unsafe e.loc e ret_ty;
      (tyenv, raw_locals)
  | Expr e ->
      ignore (infer_expr senv eenv tyenv fenv e);
      (tyenv, raw_locals)
  | Yield e ->
      (* GitHub issue #184: reached when infer_arm_body (the Match case
         below) walks a plain `match` STATEMENT's arm bodies via ordinary
         infer_stmt -- a `Yield e` arm here just means "this arm's value,
         if this were a value-producing context, would be `e`"; a plain
         `match` discards it, so this behaves exactly like `Expr e`.
         LetMatch's own case (below) does NOT reach here for a `Yield`
         arm -- it special-cases the arm bodies itself to CAPTURE the
         yielded value instead of discarding it (see its own comment). *)
      ignore (infer_expr senv eenv tyenv fenv e);
      (tyenv, raw_locals)
  | Let (is_mut, name, ty_opt, expr_opt, align_opt) ->
      value_static_identities := StringMap.remove name !value_static_identities;
      invalidate_place_binding name;
      let ty = of_ast_opt ty_opt in
      let init_ty_opt =
        match expr_opt with
        | None ->
            if not is_mut then
              raise (TypeError (s.loc,
                Printf.sprintf "immutable variable '%s' must have an initializer" name));
            None
        | Some { desc = StructLit exprs; loc } ->
            (* Struct literal: look up struct name from the type annotation and check each field *)
            if not is_mut then
              raise (TypeError (loc,
                Printf.sprintf "struct literal requires `let mut %s: Name = {...}`" name));
            (match repr ty with
             | (TStruct _ | TIndexedStruct _ | TArray _) as expected ->
                 ignore (check_expr senv eenv tyenv fenv { desc = StructLit exprs; loc } expected)
             | _ -> raise (TypeError (loc,
                 "literal { ... } requires a struct or array type annotation")));
            None
        | Some e ->
            (* GitHub issue #323: routed through check_expr, which now
               covers the AddrOf-vs-TRef/TRefMut dispatch this `let` case
               used to duplicate as its own separate match arm (see
               #314/#319's own history: `let core: &FreelistCore(N) =
               &pool.core;`, kernel/lib/growable_pool.tkb) -- check_expr's
               own AddrOf/TRef and AddrOf/TRefMut cases only fire when
               `ty`'s repr actually is TRef/TRefMut, so a `let` annotation
               of any other type (including *T, "not yet migrated" to
               &T/&mut T) still falls through to check_expr's fallback,
               which calls infer_expr's own AddrOf case exactly as this
               file's previous "Some e -> infer_expr ..." general branch
               did for every non-TRef/TRefMut annotation. Two observed
               behavior differences from before this change, both strict
               capability gains: an AddrOf initializer against a &T/&mut T
               annotation now also runs check_literal_fits_refined (the
               dedicated Let-side AddrOf branch never called it, unlike
               the Call-argument loop's own copy); and an existentially-
               typed initializer is now opened before unification the same
               way an existentially-typed call argument already was (see
               check_expr's own fallback comment) -- previously unique to
               Call, now shared, though no existing test or kernel/ site
               is known to exercise a Let initializer that would have hit
               either gap. *)
            let et = check_expr senv eenv tyenv fenv e (strip_io ty) in
            (* Same restriction as the struct-literal case just above, but
               for any OTHER struct-typed initializer (a function call
               returning a struct by value, a field/array read, etc.): an
               immutable `let` has no alloca (see llvm_gen.ml's Let(false,
               ...) case), so it has no memory location to hand `.field`
               access a pointer into -- codegen would otherwise emit a
               `getelementptr` directly on the raw aggregate SSA value,
               which is not a pointer and produces invalid LLVM IR. Found
               via examples/affine_escape_via_index/affine_escape_via_index.tkb's
               `let proc: Process = open_two();` during GitHub issue #89's
               escape-idiom work; see HISTORY.md. *)
            (match repr et with
             (* `Types.ty` represents both real structs AND enums as
                `TStruct sname` (see Types.of_ast's `TypeNamed s -> TStruct
                s`) -- only names registered in `senv` (populated from
                `StructDef`, not `EnumDef`) are actual structs needing an
                address for field access; an enum value is fine immutable
                (it's just an integer at the LLVM level, see llvm_gen.ml's
                enum_underlying handling). *)
             | TStruct sname when (not is_mut) && StringMap.mem sname senv ->
                 raise (TypeError (e.loc, Printf.sprintf
                   "struct-typed value requires `let mut %s: Name = ...` \
                    (an immutable let has no address for later field access)" name))
             | _ -> ());
            Some et
      in
      (* Proofs are only lost at mutation points, never at annotation
         (gradual-trap-elimination invariant): for an IMMUTABLE binding, a
         weaker annotation must not discard what the initializer proved --
         the value can never change, so keeping the stronger type is sound,
         and no runtime check (trap site) is manufactured out of
         already-proven code. Applies to the two proof-carrying types:
         slice minimum lengths, and refined int ranges -- the latter only
         when the annotation's own type MATCHES the refined value's base
         (generalized from the old i32-only check: a refined int's base
         now determines its storage representation, so an annotation
         naming a DIFFERENT primitive type would change that
         representation, and there the declared type must win, same
         reasoning as before just no longer hardcoded to i32). `let mut`
         keeps the declared type: reassignment can genuinely bring weaker
         values, so the weak type is honest. *)
      let bind_ty =
        if is_mut then ty
        else match init_ty_opt with
          | None -> ty
          | Some et ->
              (match repr ty, repr et with
               | TSlice (el, m1), TSlice (_, m2) when m2 > m1 -> TSlice (el, m2)
               (* `base` is a NESTED field inside the already-repr'd `et`,
                  so it is not itself guaranteed dereferenced (repr only
                  resolves the top-level TVar chain, not fields nested
                  inside a matched constructor) -- must repr it again
                  before comparing, or a base that's still a live
                  TVar(ref(Link TI32)) would structurally disagree with
                  the plain TI32 annotation despite meaning the same type
                  after resolution. Found via a real test regression
                  (Mul/Band chain producing a refined result whose base
                  came from a freshly-unified IntLit type variable). *)
               | t_ann, (TRefinedInt (_, _, base) as r) when t_ann = repr base -> r
               | _ -> ty)
      in
      if contains_stable_owner_value_ty bind_ty then
        raise (TypeError (s.loc,
          "stable owner container storage must be a private mutable global, not a local value"));
      (* Deliberately NOT checked here for is_undetermined: `let x = 1;
         return x;` is entirely ordinary, and the function's OWN return
         type (processed by a LATER statement) is what determines x's
         type -- checking immediately at this Let would reject it as a
         false positive, since later statements haven't run yet. The
         check instead runs once, in infer_func, after the WHOLE body has
         been processed and every constraint has had a chance to fire --
         see check_undetermined_lets. *)
      (match align_opt with
       | Some n -> var_align_bytes := StringMap.add name n !var_align_bytes
       | None -> ());
      locally_bound_names := StringSet.add name !locally_bound_names;  (* issue #214 *)
      ( StringMap.add name (bind_ty, is_mut) tyenv,
        StringMap.add name bind_ty raw_locals )
  | LetTuple (names, rhs) ->
      (* OWNERSHIP_KERNEL.md 5.9 (GitHub issue #120): destructuring is the
         ONLY tuple elimination. Bindings are immutable; component types
         come from the RHS and are recorded in raw_locals, so kind
         tracking sees unannotated destructured obligations. *)
      let seen = Hashtbl.create 4 in
      List.iter (fun n ->
        if Hashtbl.mem seen n then
          raise (TypeError (s.loc, Printf.sprintf
            "duplicate name '%s' in tuple pattern" n));
        Hashtbl.add seen n ()) names;
      let rt = infer_expr senv eenv tyenv fenv rhs in
      let comp_tys = match repr rt with
        | TTuple ts -> ts
        | other -> raise (TypeError (rhs.loc, Printf.sprintf
            "destructuring `let (...) = ...` needs a tuple right-hand side, \
             got '%s'" (to_string other)))
      in
      if List.length names <> List.length comp_tys then
        raise (TypeError (s.loc, Printf.sprintf
          "tuple has %d components but the pattern binds %d names"
          (List.length comp_tys) (List.length names)));
      (* Same restriction as Let's immutable-struct rule above: an
         immutable binding has no alloca, so a by-value struct component
         would have no address for later field access. *)
      List.iter (fun t ->
        match repr t with
        | TStruct sname when StringMap.mem sname senv ->
            raise (TypeError (rhs.loc, Printf.sprintf
              "tuple component of struct type '%s' cannot be destructured \
               into an immutable binding (no address for later field \
               access)" sname))
        | _ -> ()) comp_tys;
      List.iter (fun n ->
        locally_bound_names := StringSet.add n !locally_bound_names  (* issue #214 *)
      ) names;
      ( List.fold_left2 (fun env n t -> StringMap.add n (t, false) env)
          tyenv names comp_tys,
        List.fold_left2 (fun m n t -> StringMap.add n t m)
          raw_locals names comp_tys )
  | Block stmts ->
      (* Let bindings extend the inner env but do not escape the block *)
      let (_, raw_locals') = fold_stmts_with_future_writes
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (tyenv, raw_locals) stmts
      in
      (tyenv, raw_locals')
  | UnsafeBlock stmts ->
      (* GitHub issue #315: same as Block, except every statement inside
         is checked with unsafe_depth raised -- the block-granularity
         grant. No exception-safe decrement needed, same rationale as
         Ast.Unsafe's own case: a TypeError aborts this top-level item's
         own checking and infer_program's Pass 3 resets unsafe_depth
         before moving to the next FuncDef.
         GitHub issue #328: type_checker_lint_active turns on per-statement
         "unnecessary unsafe" tracking (via fold_stmts_with_future_writes,
         above) for every statement inside this scope, including ones
         nested arbitrarily deep in If/While/For/match bodies -- mirrors
         llvm_gen.ml's own UnsafeBlock codegen case exactly, including the
         save/restore (not unconditional on/off): a nested `unsafe { }`
         inside this one must not turn tracking OFF when IT exits. *)
      let was_lint_active = !type_checker_lint_active in
      type_checker_lint_active := true;
      incr unsafe_depth;
      let (_, raw_locals') = fold_stmts_with_future_writes
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (tyenv, raw_locals) stmts
      in
      decr unsafe_depth;
      type_checker_lint_active := was_lint_active;
      (tyenv, raw_locals')
  | If (cond, then_s, else_s) ->
      let ct = infer_expr senv eenv tyenv fenv cond in
      check_cond cond.loc ct;
      (* Captured NOW, before then_s/else_s's own nested folds below
         (each a fold_stmts_with_future_writes call in its own right)
         overwrite enclosing_future_writes for their own duration -- see
         that function's own comment for why re-reading the ref after
         nested processing would see the wrong (inner) scope's value
         instead of this If's own position in ITS enclosing list. *)
      let future_writes_here = !enclosing_future_writes in
      let then_tyenv = narrow_from_cond tyenv cond then_s in
      let (_, rl1) = fold_stmts_with_future_writes
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (then_tyenv, raw_locals) then_s
      in
      let (_, rl2) = fold_stmts_with_future_writes
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs in_loop s)
        (tyenv, rl1) else_s
      in
      (* Early-return-guard narrowing: when the then-branch always
         returns, the code after this WHOLE if/else is reached only on
         the path where `cond` was false -- i.e. exactly the else
         branch's own path, whether else_s is empty (including an
         explicit but empty `else {}`, indistinguishable from "no else"
         both at the AST level and semantically), non-empty, or absent
         entirely (else_s = [] either way). narrow_from_cond's kill
         source is else_s itself, not then_s and not [] unconditionally
         -- exactly mirroring then_tyenv's own kill discipline just
         above, so a write inside a real else branch still correctly
         invalidates the proof for whatever follows, the same way a
         write inside `then_s` already invalidates then_tyenv's proof
         for code inside the then-branch. negate_cond returning None
         (an unrecognized condition shape, or one whose negation lands
         on an Or -- see collect_bounds' own header -- this refinement
         system has no single-interval representation for a disjoint
         union of ranges, so an And-shaped guard's negated Or cannot
         narrow anything) falls back to today's exact behavior.

         GitHub issue #296: this continuation environment survives into
         arbitrarily many SIBLING statements after this whole if, unlike
         then_tyenv's own narrowing above (used only for checking
         statements INSIDE then_s itself, in the same List.fold_left
         that re-threads the environment after each statement, so a
         write anywhere inside then_s is checked against then_s's own
         kill set first). Originally restricted to IMMUTABLE bindings
         only, found the hard way against real kernel code
         (kernel/drivers/net/virtio_net.tkb's `if (initialized != 0) {
         return Failed; } initialized = 1;` init-guard idiom broke on
         the first whole-kernel build after this feature was first
         added): a later plain assignment to a narrowed MUTABLE variable
         was checked against the stale narrowed type instead of its
         declared type, rejecting the plainly-valid assignment. Now uses
         enclosing_future_writes (set by this If's own enclosing
         statement-list fold, see that ref's own comment) instead of a
         blanket mutability filter: a mutable binding keeps its
         narrowing into the continuation exactly when no statement
         anywhere in the SAME enclosing list writes to it, which covers
         virtio_net.tkb's shape (the write is caught, narrowing is
         correctly dropped for `initialized`) while still letting a
         mutable variable that is never reassigned after the guard (the
         actual common case, and the whole point of this feature) keep
         its narrowing. Applied to ALL bindings, not just mutable ones,
         since it strictly subsumes the old immutable case (an
         immutable name can never appear in written_names from an
         ordinary reassignment, only from a same-name shadowing `let`
         re-declaration -- which SHOULD also invalidate the old
         narrowing, a latent gap the old mutability-only filter never
         covered either). *)
      let filter_by_future_writes env =
        StringMap.mapi (fun name entry ->
          if StringSet.mem name future_writes_here then
            match StringMap.find_opt name tyenv with
            | Some original when entry <> original -> original
            | _ -> entry
          else entry
        ) env
      in
      let continuation_tyenv =
        if stmt_list_always_returns then_s then begin
          record_guard_narrow_hints cond;  (* GitHub issue #310 *)
          match negate_cond cond with
          | Some neg -> filter_by_future_writes (narrow_from_cond tyenv neg else_s)
          | None -> tyenv
        end else tyenv
      in
      (continuation_tyenv, rl2)
  | While (cond, body) ->
      let ct = infer_expr senv eenv tyenv fenv cond in
      check_cond cond.loc ct;
      (* GitHub issue #313: narrow_from_cond already computes exactly the
         soundness condition a `while` needs and no more -- its own kill
         set (Ast.written_names body) excludes any name written ANYWHERE
         in the body, not just before the narrowed use, which is
         precisely "the loop body provably never reassigns it at all"
         (the narrower first version this issue's own text calls out,
         avoiding the harder "not reassigned between the narrowed use and
         the next condition re-check" analysis a per-iteration narrowing
         would need). No new soundness analysis needed: `if`'s own use of
         this same function already established it's sound for exactly
         this kill rule, and a `while` condition holding for the ENTIRE
         body on every iteration is the same "cond implies these bounds
         for every statement that follows, up to the next write" fact
         `if`'s then-branch already relies on -- only reachable body
         statements differ (loop body vs. then-branch), not the
         underlying reasoning. Only applies to the BODY; the tyenv
         returned after the loop for the fallthrough stays unnarrowed
         (the condition is false there, a different, unrelated fact).
         Sync rule: llvm_gen.ml's own While codegen case now applies the
         same apply_narrowing/apply_narrowing_mut calls narrow_from_cond
         itself wraps, for the same reason #311/#312 needed the matching
         update -- without it this would be a real --forbid-trap
         regression risk (proving more here without codegen eliding the
         matching check). *)
      let narrowed_tyenv = narrow_from_cond tyenv cond body in
      let (_, raw_locals') = fold_stmts_with_future_writes
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
        (narrowed_tyenv, raw_locals) body
      in
      (tyenv, raw_locals')
  | For (name, ty_opt, lo_expr, hi_expr, body) ->
      let lo_ty = infer_expr senv eenv tyenv fenv lo_expr in
      let hi_ty = infer_expr senv eenv tyenv fenv hi_expr in
      (* The loop counter's base follows the BOUNDS' own type, instead of
         hardcoding TI32 (the same generalization already applied to
         min/max/Band/Mod/narrowing) -- unify lo/hi against EACH OTHER via
         canon_ty, mirroring min/max's Call case exactly. This was a real,
         found gap, not just a style choice: `for i in 0..<s.len` (s.len:
         TUsize) previously failed outright with "cannot unify usize with
         i32", because the OLD unconditional `unify_at ... TI32` forced
         both bounds to already be i32-compatible before any of
         TRefinedInt's leniency into TI32 could apply -- a bare (non
         -refined) TUsize has no such leniency rule. Fixed by unifying the
         bounds against each other instead, exactly like every other
         refinement-producing site in this file. *)
      let base_raw = canon_ty lo_ty in
      unify_at hi_expr.loc base_raw (canon_ty hi_ty);
      (* Explicit annotation (`for i: u8 in ...`): pins base_raw
         IMMEDIATELY, same as any other concrete-type unification --
         after this, base_raw is no longer a candidate for the deferred
         "still unresolved" path below at all. A conflicting bound (e.g.
         `for i: u8 in 0..<n` where n: u16) surfaces as an ordinary
         "cannot unify" error here, same as anywhere else a concrete type
         mismatch is caught. *)
      (match ty_opt with
       | Some ann_ty -> unify_at lo_expr.loc base_raw (of_ast ann_ty)
       | None -> ());
      (* Deliberately NOT validated/defaulted yet when there's no
         annotation: base_raw may still be resolved by how `name` is used
         INSIDE the body below (e.g. passed to a function with a
         concrete-typed parameter), exactly like ordinary HM inference
         lets a shared unification variable be pinned by any later
         constraint. Deferred to the check after the body, mirroring
         check_undetermined_lets's identical "let later constraints run
         first" reasoning. NOTE (see CLAUDE.md): for the single most
         common shape, `for i in 0..<4` with both bounds bare literals,
         this deferral has NO effect in practice, because such bounds get
         wrapped in TRefinedInt below, whose subtyping into a concrete
         type ignores the base field entirely -- the annotation syntax
         (`ty_opt`) is precisely the fix for that residual gap. *)
      (* Refine to TRefinedInt when both bounds are compile-time integers:
         a literal, or the name of a Const_env global constant (sound because
         check_const_shadowing rejects any local reusing a constant name).
         For runtime variables, conservatively use the bounds' own base.
         Sync rule: llvm_gen.ml's For case makes the same decision through
         the same Const_env.bound_value helper; keep them identical. *)
      let const_bounds = (Const_env.bound_value lo_expr, Const_env.bound_value hi_expr) in
      (* If both bounds are compile-time constants AND an explicit
         annotation was given, validate the bounds actually fit the
         annotated base -- a bare-literal bound has no inherent width of
         its own, so without this check `for i: u8 in 0..<300` would
         silently construct TRefinedInt(0, 300, TU8), wrapping around at
         codegen time exactly like the {lo..<hi as base} surface syntax's
         own bound check exists to prevent (see check_refined_base_range
         in parser.mly, sync rule -- same reasoning, different
         representation and call site). *)
      (match ty_opt, const_bounds with
       | Some _, (Some lo_v, Some hi_v) ->
           check_for_annotation_range lo_expr.loc lo_v hi_v (repr base_raw)
       | _ -> ());
      let idx_ty = match const_bounds with
        | Some lo_v, Some hi_v -> TRefinedInt (lo_v, hi_v, base_raw)
        | (lo_c, _) ->
            (* GitHub issue #312: hi_expr may not resolve via Const_env
               (a syntactic constant) yet already carry a proven
               TRefinedInt of its own (e.g. a runtime parameter `limit:
               {0..<N as usize}`) -- reuse that proof for the counter's
               own upper bound instead of falling back to the unrefined
               base. The lower bound comes from const_bounds' own lo_c
               when lo_expr IS a constant (the common `0..<limit` shape);
               when lo_expr is ALSO non-constant, its own inferred type
               is checked the same way. No useful lower bound at all
               (neither side provable) keeps today's unrefined behavior,
               matching this issue's own scoping note that a
               contributes-nothing bound stays as before.
               Sync rule: llvm_gen.ml's For case makes the same decision
               independently (via gen_expr's own returned type for
               hi_expr, mirroring the Const_env.bound_value sync just
               above); keep them identical. *)
            (match repr hi_ty with
             | TRefinedInt (_, hi_hi, hi_base) when repr hi_base = repr base_raw ->
                 let lo = match lo_c with
                   | Some lo_v -> Some lo_v
                   | None ->
                       (match repr lo_ty with
                        | TRefinedInt (lo_lo, _, lo_base) when repr lo_base = repr base_raw ->
                            Some lo_lo
                        | _ -> None)
                 in
                 (match lo with
                  | Some lo_v -> TRefinedInt (lo_v, hi_hi, base_raw)
                  | None -> base_raw)
             | _ -> base_raw)
      in
      (* Loop variable is immutable (Imm binding, no reassignment). Does not escape the loop.
         Also register under the mangled "__for_<name>" key: llvm_gen.ml's
         collect_lets pre-allocates the counter's own storage under that
         name, and resolve_local_ast looks types up by exactly this key --
         without this second binding, the counter's alloca would silently
         fall back to i32 regardless of what idx_ty says here. *)
      locally_bound_names := StringSet.add name !locally_bound_names;  (* issue #214 *)
      let body_env = StringMap.add name (idx_ty, false) tyenv in
      let raw_locals = StringMap.add ("__for_" ^ name) idx_ty raw_locals in
      let (_, raw_locals') = fold_stmts_with_future_writes
        (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
        (body_env, raw_locals) body
      in
      (* NOW validate base_raw: the body has had its full chance to pin it
         (via a shared TVar reference nested inside idx_ty/raw_locals' --
         mutating the ref cell in place propagates to the already-stored
         value, same reasoning as check_undetermined_lets). If STILL
         unresolved, this is a HARD ERROR, not a silent i32 default: now
         that `for i: T in ...` exists as an explicit escape hatch, there
         is no reason left to guess -- exactly the same reasoning as
         let/let mut's own "Undetermined ... Types Are a Compile Error"
         rule, applied here now that the annotation syntax closes the gap
         that rule used to leave open for loop counters specifically. If
         resolved to something CONCRETE but non-integer (e.g. `for i in
         0..<true`), raise a different, more specific error instead. *)
      (match repr base_raw with
       | TVar { contents = Unbound _ } ->
           raise (TypeError (lo_expr.loc, Printf.sprintf
             "cannot determine a concrete type for for-loop counter '%s': \
              add an explicit type annotation (e.g. `for %s: i32 in ...`) \
              -- this language does not default an undetermined integer type"
             name name))
       | _ -> ());
      (match repr base_raw with
       | TI8 | TI16 | TI32 | TI64 | TU8 | TU16 | TU32 | TU64 | TIsize | TUsize -> ()
       | _ -> raise (TypeError (lo_expr.loc,
           Printf.sprintf "for-loop bounds must be an integer type, got '%s'"
             (to_string base_raw))));
      (tyenv, raw_locals')

  | ForEach (name, se, body) ->
      let st = infer_expr senv eenv tyenv fenv se in
      (match repr st with
       | TSlice (el, _) ->
           (* Element is an immutable per-iteration value of the element type. *)
           locally_bound_names := StringSet.add name !locally_bound_names;  (* issue #214 *)
           let body_env = StringMap.add name (el, false) tyenv in
           let (_, raw_locals') = fold_stmts_with_future_writes
             (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs true s)
             (body_env, raw_locals) body
           in
           (tyenv, raw_locals')
       | t ->
           raise (TypeError (se.loc,
             Printf.sprintf
               "for-in iterates over a slice, got '%s' (write `arr as []T` \
                to iterate an array)" (to_string t))))

  | Match (disc, arms) ->
      let dt = infer_expr senv eenv tyenv fenv disc in
      let infer_arm_body env rl body =
        let (_, rl') = fold_stmts_with_future_writes
          (fun (env, locs) stmt ->
            infer_stmt senv eenv env fenv ret_ty locs in_loop stmt)
          (env, rl) body
        in
        rl'
      in
      (match repr dt with
       | TStruct ename when StringMap.mem ename eenv ->
           let (_, enum_variants, is_ne) = StringMap.find ename eenv in
           let has_wild = ref false in
           let covered = Hashtbl.create 4 in
           let raw_locals' = List.fold_left (fun rl arm ->
             match arm with
             | Ast.ArmVariant (aname, vname, binding, body) ->
                 if aname <> ename then
                   raise (TypeError (s.loc, Printf.sprintf
                     "arm type '%s' does not match discriminant '%s'"
                     aname ename));
                 if binding <> None then
                   raise (TypeError (s.loc, Printf.sprintf
                     "numeric enum case '%s::%s' has no payload" ename vname));
                 (match List.assoc_opt vname enum_variants with
                  | None -> raise (TypeError (s.loc, Printf.sprintf
                      "unknown variant '%s::%s'" ename vname))
                  | Some _ -> ());
                 Hashtbl.replace covered vname ();
                 infer_arm_body tyenv rl body
             | Ast.ArmWild body ->
                 has_wild := true;
                 infer_arm_body tyenv rl body
             | Ast.ArmIntLit (lits, _) ->
                 raise (TypeError (s.loc, Printf.sprintf
                   "match arm literal '%s' cannot be used against enum discriminant '%s'"
                   (String.concat " | " (List.map string_of_int lits)) ename))
           ) raw_locals arms in
           if is_ne then begin
             if not !has_wild then
               raise (TypeError (s.loc, Printf.sprintf
                 "non-exhaustive enum '%s' requires a '_' wildcard arm" ename))
           end else if not !has_wild then
             List.iter (fun (vname, _) ->
               if not (Hashtbl.mem covered vname) then
                 raise (TypeError (s.loc, Printf.sprintf
                   "non-exhaustive match: '%s::%s' not covered" ename vname))
             ) enum_variants;
           (tyenv, raw_locals')
       | TVariant vtype ->
           let cases = match Hashtbl.find_opt variant_defs vtype with
             | Some cases -> cases
             | None -> raise (TypeError (disc.loc, Printf.sprintf
                 "unknown variant type '%s'" vtype))
           in
           let has_wild = ref false in
           let covered = Hashtbl.create 4 in
           let open_payload schema =
             let scope = create_static_scope () in
             let rec open_exists = function
               | Ast.TypeExists (name, _, body) ->
                   bind_static scope name (rigid_static name);
                   open_exists body
               | ty -> of_ast_in_decl_scope scope ty
             in
             open_exists schema
           in
           let raw_locals' = List.fold_left (fun rl arm ->
             match arm with
             | Ast.ArmVariant (aname, cname, binding, body) ->
                 if aname <> vtype then
                   raise (TypeError (s.loc, Printf.sprintf
                     "arm type '%s' does not match discriminant '%s'"
                     aname vtype));
                 if Hashtbl.mem covered cname then
                   raise (TypeError (s.loc, Printf.sprintf
                     "duplicate match arm '%s::%s'" vtype cname));
                 Hashtbl.add covered cname ();
                 let payload = match List.assoc_opt cname cases with
                   | None -> raise (TypeError (s.loc, Printf.sprintf
                       "unknown case '%s::%s'" vtype cname))
                   | Some payload -> payload
                 in
                 (match payload, binding with
                  | None, None -> infer_arm_body tyenv rl body
                  | None, Some _ -> raise (TypeError (s.loc, Printf.sprintf
                      "variant case '%s::%s' has no payload" vtype cname))
                  | Some _, None -> raise (TypeError (s.loc, Printf.sprintf
                      "variant case '%s::%s' must bind its payload" vtype cname))
                  | Some schema, Some (name, is_mutable) ->
                      if Const_env.find name <> None then
                        raise (TypeError (s.loc, Printf.sprintf
                          "'%s' shadows a global constant of the same name" name));
                      if StringMap.mem name tyenv then
                        raise (TypeError (s.loc, Printf.sprintf
                          "variant payload binding '%s' shadows an existing value; choose a fresh arm-local name"
                          name));
                      let payload_ty = open_payload schema in
                      let env = StringMap.add name (payload_ty, is_mutable) tyenv in
                      (* The binder is arm-local, unlike ordinary `let`
                         entries accumulated in the function-wide raw-local
                         map. Resource checking reopens the case schema for
                         this arm instead of flattening disjoint binders by
                         name. *)
                      infer_arm_body env rl body)
             | Ast.ArmWild body ->
                 if !has_wild then
                   raise (TypeError (s.loc,
                     "duplicate '_' wildcard match arm"));
                 has_wild := true;
                 if Hashtbl.find_opt variant_kinds vtype = Some Ast.KindLinear then
                   raise (TypeError (s.loc, Printf.sprintf
                     "linear variant '%s' cannot use a wildcard arm because it could hide an unconsumed payload"
                     vtype));
                 infer_arm_body tyenv rl body
             | Ast.ArmIntLit (lits, _) ->
                 raise (TypeError (s.loc, Printf.sprintf
                   "match arm literal '%s' cannot be used against variant discriminant '%s'"
                   (String.concat " | " (List.map string_of_int lits)) vtype))
           ) raw_locals arms in
           if not !has_wild then
             List.iter (fun (cname, _) ->
               if not (Hashtbl.mem covered cname) then
                 raise (TypeError (s.loc, Printf.sprintf
                   "non-exhaustive match: '%s::%s' not covered" vtype cname))
             ) cases;
           (tyenv, raw_locals')
       | (TI8|TI16|TI32|TI64|TU8|TU16|TU32|TU64|TIsize|TUsize
          | TRefinedInt (_, _, _)) as int_ty ->
           (* Literal-integer match (GitHub issue #151). A `_` wildcard is
              always mandatory here, unlike enum/variant above: an
              integer's value space is never exhaustively listable, so
              there is no "every case covered, no wildcard needed" path
              analogous to a closed variant/exhaustive enum. *)
           let base_ty = match int_ty with
             | TRefinedInt (_, _, b) -> b
             | b -> b
           in
           let has_wild = ref false in
           let seen = Hashtbl.create 4 in
           let raw_locals' = List.fold_left (fun rl arm ->
             match arm with
             | Ast.ArmIntLit (lits, body) ->
                 List.iter (fun lit ->
                   if Hashtbl.mem seen lit then
                     raise (TypeError (s.loc, Printf.sprintf
                       "duplicate match arm literal '%d'" lit));
                   Hashtbl.replace seen lit ();
                   check_match_int_literal_range s.loc lit base_ty
                 ) lits;
                 infer_arm_body tyenv rl body
             | Ast.ArmWild body ->
                 if !has_wild then
                   raise (TypeError (s.loc,
                     "duplicate '_' wildcard match arm"));
                 has_wild := true;
                 infer_arm_body tyenv rl body
             | Ast.ArmVariant (aname, _, _, _) ->
                 raise (TypeError (s.loc, Printf.sprintf
                   "match arm '%s::...' cannot be used against a primitive integer discriminant"
                   aname))
           ) raw_locals arms in
           if not !has_wild then
             raise (TypeError (s.loc,
               "match on a primitive integer type requires a '_' wildcard arm \
                (an integer's value space cannot be exhaustively listed)"));
           (tyenv, raw_locals')
       | t -> raise (TypeError (disc.loc, Printf.sprintf
           "match requires an enum, variant, or primitive integer type, got '%s'" (to_string t))))
  | LetMatch (is_mut, name, ty_opt, disc, arms) ->
      (* GitHub issue #183 follow-up ("Layer 1", plus a later non-mut
         extension and #184's `Yield`-tail sugar): `let [mut] name [: ty] =
         match disc { arms };`. The parser has already verified each
         arm's body ends in `Yield e` (this arm's value) or
         Return/Break/Continue (diverges). rewrite_letmatch_arm_bodies
         (above) turns each `Yield e` into an ordinary `name = e;`
         statement first, so exhaustiveness, linear-payload handling, and
         every other Match rule above apply completely unchanged by
         recursing on a synthesized `Match` node -- Assign's own existing
         rule checks the rewritten `e` against name's now-known type,
         nothing new needed there. `name` itself is declared exactly like
         an ordinary `let mut name: ty;` (see the Let case above, which
         this mirrors minus the initializer-unification logic that
         doesn't apply here: there is no single initializer expression to
         unify a declared type against) -- ALWAYS mutable while checking
         the arms, regardless of the surface `mut`, since the rewritten
         `name = e;` needs that. A non-mut surface binding downgrades
         `name` back to immutable in the tyenv returned here, which is
         what continues past this whole statement -- a later
         `name = ...;` outside these arms then hits Assign's own existing
         "cannot assign to immutable variable" check, same as for any
         other non-mut `let`.

         GitHub issue #207: `ty_opt = None` seeds `ty` with a fresh
         unification variable via of_ast_opt (same as an ordinary untyped
         `let`, see the Let case above) instead of a concrete type. `ty`
         is a mutable TVar ref cell threaded into tyenv'/raw_locals'
         BEFORE the arms are checked below, so Assign's own `unify_at`
         call (reached through the same Yield -> `name = e;` rewrite)
         resolves/links it in place as each arm is checked -- no new
         unification logic needed. Every arm stays fully, explicitly
         named (never a wildcard), so this cannot hide a linear payload
         obligation the way the still-paused GitHub issue #212 "let-else"
         idea could -- see Ast.LetMatch's own comment for that
         distinction. *)
      value_static_identities := StringMap.remove name !value_static_identities;
      invalidate_place_binding name;
      locally_bound_names := StringSet.add name !locally_bound_names;  (* issue #214 *)
      let ty = of_ast_opt ty_opt in
      let tyenv' = StringMap.add name (ty, true) tyenv in
      let raw_locals' = StringMap.add name ty raw_locals in
      let arms = rewrite_letmatch_arm_bodies name arms in
      let (tyenv'', raw_locals'') = infer_stmt senv eenv tyenv' fenv ret_ty
        raw_locals' in_loop { desc = Match (disc, arms); loc = s.loc } in
      (* Checked after the arms (rather than immediately, as the mandatory-
         annotation form used to) so a freshly-seeded, still-unresolved
         TVar has had a chance to resolve first -- a no-op change for the
         mandatory case (already concrete going in), strictly more correct
         for the inferred case. *)
      if contains_stable_owner_value_ty ty then
        raise (TypeError (s.loc,
          "stable owner container storage must be a private mutable global, not a local value"));
      let tyenv''' =
        if is_mut then tyenv'' else StringMap.add name (ty, false) tyenv''
      in
      (tyenv''', raw_locals'')

(* -- Function inference ---------------------------------------------------- *)

(* Reject a local let / parameter / for-counter that reuses the name of a
   global compile-time constant (Const_env). Array sizes and for-loop bounds
   resolve such names through Const_env by name alone, with no scope
   information, so a shadowing local would silently make a refinement be
   computed from the global's value while the runtime value is the local's
   -- an unsound bounds-check elision. Checked after parsing (the Const_env
   table is complete by then), so declaration order cannot smuggle a shadow
   in: a function defined before the constant is checked all the same. *)
let check_const_shadowing (fdef : Ast.func) =
  let reject loc name =
    raise (TypeError (loc, Printf.sprintf
      "'%s' shadows a global constant of the same name (constant names are \
       resolved at compile time in array sizes and for-loop bounds); rename \
       the local" name))
  in
  List.iter (fun (pname, _) ->
    if Const_env.find pname <> None then reject fdef.def_loc pname
  ) fdef.params;
  let rec go_stmt (s : Ast.stmt) = match s.desc with
    | Ast.Let (_, name, _, _, _) ->
        if Const_env.find name <> None then reject s.loc name
    | Ast.Block ss | Ast.UnsafeBlock ss | Ast.While (_, ss) -> List.iter go_stmt ss
    | Ast.If (_, t, e) -> List.iter go_stmt t; List.iter go_stmt e
    | Ast.For (name, _, _, _, body) ->
        if Const_env.find name <> None then reject s.loc name;
        List.iter go_stmt body
    | Ast.ForEach (name, _, body) ->
        if Const_env.find name <> None then reject s.loc name;
        List.iter go_stmt body
    | Ast.Match (_, arms) ->
        List.iter (function
          | Ast.ArmVariant (_, _, binding, b) ->
              Option.iter (fun (name, _) ->
                if Const_env.find name <> None then reject s.loc name) binding;
              List.iter go_stmt b
          | Ast.ArmWild b            -> List.iter go_stmt b
          | Ast.ArmIntLit (_, b)     -> List.iter go_stmt b
        ) arms
    | _ -> ()
  in
  List.iter go_stmt fdef.body

(* Require an explicit type annotation on any `let`/`let mut` whose type is
   STILL undetermined after the whole function body has been processed
   (raw_locals reflects every constraint the ENTIRE function ever placed
   on it, not just what was known at the Let statement's own textual
   position -- see the Let case's own comment for why checking eagerly,
   right there, produces a false positive on the entirely ordinary
   `let x = 1; return x;` pattern). This is a plain syntactic re-walk
   (mirroring check_const_shadowing's go_stmt exactly) rather than
   threading a location map through infer_stmt's signature everywhere:
   raw_locals only holds name -> ty, with no location, so the AST is
   walked a second time purely to recover a `Let`'s source position for
   the error message. *)
let check_undetermined_lets (fdef : Ast.func) (raw_locals : ty StringMap.t) =
  let check loc name =
    match StringMap.find_opt name raw_locals with
    | Some ty when is_undetermined ty ->
        raise (TypeError (loc, Printf.sprintf
          "cannot determine a concrete type for '%s': add an explicit \
           type annotation (e.g. `: i32`) -- this language does not \
           default an undetermined integer type" name))
    | _ -> ()
  in
  let rec go_arms arms = List.iter (function
    | Ast.ArmVariant (_, _, _, b) -> List.iter go_stmt b
    | Ast.ArmWild b            -> List.iter go_stmt b
    | Ast.ArmIntLit (_, b)     -> List.iter go_stmt b
  ) arms
  and go_stmt (s : Ast.stmt) = match s.desc with
    | Ast.Let (_, name, None, _, _) -> check s.loc name
    | Ast.Let (_, _, Some _, _, _) -> ()
    | Ast.Block ss | Ast.UnsafeBlock ss | Ast.While (_, ss) -> List.iter go_stmt ss
    | Ast.If (_, t, e) -> List.iter go_stmt t; List.iter go_stmt e
    | Ast.For (_, _, _, _, body) | Ast.ForEach (_, _, body) -> List.iter go_stmt body
    | Ast.Match (_, arms) -> go_arms arms
    (* GitHub issue #207: an omitted-annotation LetMatch whose arms never
       pin down a concrete type (e.g. every arm diverges except one whose
       own Yield type is itself ambiguous) must be caught here too, or it
       would silently default to i32 via Types.to_ast instead of raising
       this "cannot determine a concrete type" error -- confirmed this is
       NOT already covered before adding these two cases. *)
    | Ast.LetMatch (_, name, None, _, arms) -> check s.loc name; go_arms arms
    | Ast.LetMatch (_, _, Some _, _, arms) -> go_arms arms
    | _ -> ()
  in
  List.iter go_stmt fdef.body

let infer_func senv eenv fenv genv (fdef : Ast.func) : func_info =
  let previous_scope = !active_static_scope in
  let previous_readonly = !active_readonly_borrows in
  let scope = create_static_scope () in
  active_static_scope := Some scope;
  active_readonly_borrows := List.fold_left (fun names (name, ty) ->
    match ty with
    | Some (Ast.TypeBorrow _) -> StringSet.add name names
    | _ -> names) StringSet.empty fdef.params;
  Fun.protect ~finally:(fun () ->
    active_static_scope := previous_scope;
    active_readonly_borrows := previous_readonly) (fun () ->
    check_const_shadowing fdef;
    value_static_identities := StringMap.empty;
    place_static_identities := StringMap.empty;
    Hashtbl.reset guard_narrow_hints;  (* GitHub issue #310, fresh per function *)
    var_align_bytes := !global_align_bytes_baseline;  (* see its own comment *)
    (* GitHub issue #214: reset per function, then seed with this
       function's own parameter names -- see locally_bound_names' own
       comment. *)
    locally_bound_names := StringSet.empty;
    List.iter (fun (name, _) ->
      locally_bound_names := StringSet.add name !locally_bound_names
    ) fdef.params;
    let param_tys = List.map (fun (_, ty_opt) -> of_ast_opt ty_opt) fdef.params in
    let ret_ty    = ret_of_ast_opt fdef.ret_type in
    (* Start with globals visible, then shadow them with params (params are mutable) *)
    let init_env  = List.fold_left2
      (fun m (name, _) ty -> StringMap.add name (ty, true) m)
      genv fdef.params param_tys
    in
    let (_, raw_locals) = fold_stmts_with_future_writes
      (fun (env, locs) s -> infer_stmt senv eenv env fenv ret_ty locs false s)
      (init_env, StringMap.empty) fdef.body
    in
    check_undetermined_lets fdef raw_locals;
    List.iter2 (fun (name, _) ty ->
      if contains_stable_owner_value_ty ty then
        raise (TypeError (fdef.def_loc, Printf.sprintf
          "stable owner container parameter '%s' cannot be passed by value; pass a pointer to its private global storage"
          name))
    ) fdef.params param_tys;
    {
      ret_type    = to_ast ret_ty;
      param_types = List.map2 (fun (name, _) ty -> (name, to_ast ty))
                      fdef.params param_tys;
      local_types = StringMap.map to_ast raw_locals;
      effects     = Option.value fdef.effects ~default:[];
    })

(* -- Whole-program inference ----------------------------------------------- *)

let infer_program (prog : Ast.toplevel list) : program_types =
  unsafe_depth := 0;  (* see its comment: fresh per compilation / per unit test *)
  nonliteral_ptr_cast_warnings := [];  (* fresh per compilation / per unit test *)
  collected_type_errors := [];  (* fresh per compilation / per unit test *)
  type_checker_unsafe_use_marker := 0;  (* GitHub issue #328, fresh per compilation / per unit test *)
  type_checker_lint_active := false;
  Hashtbl.reset type_checker_consumed_unsafe_at;
  Hashtbl.reset index_resolved_ty;  (* GitHub issue #311, fresh per compilation / per unit test *)
  enclosing_future_writes := StringSet.empty;  (* fresh per compilation / per unit test *)
  resolved_call_targets := StringMap.empty;
  resolved_indirect_call_effects := StringMap.empty;
  (* GitHub issue #79 follow-up: ONE flat namespace for every top-level
     name, not just functions and globals (the two kinds fixed earlier in
     this same follow-up) -- struct, opaque struct, and enum names now
     collide the same way. A single self-contained pass over the whole
     program, run before senv/eenv/fenv/genv exist, rather than one
     more scattered ad-hoc Hashtbl bolted onto each of those folds
     individually: the earlier two fixes each needed their own separate
     check (a same-file-only guard for functions, a StringMap.mem check
     against fenv for globals), and finding the struct/enum gap
     immediately after landing those two was the concrete signal that
     one shared, exhaustive mechanism is less error-prone than adding a
     fourth and fifth one-off check the same way. Functions are the one
     special case: two functions sharing a name is fine on ITS OWN (a
     valid overload, or a genuine duplicate signature -- both already
     handled by register_definition/fenv's own signature-aware logic
     further down); this registry only rejects a function name colliding
     with a NON-function kind, or two non-function kinds (struct, enum,
     global) colliding with each other or themselves. `Lexing.dummy_pos`
     for the same reason noted on the two earlier checks: `Ast.toplevel`
     carries no location except via `FuncDef`'s own `func.def_loc`. *)
  let toplevel_names : (string, string) Hashtbl.t = Hashtbl.create 32 in
  let article_for kind = if kind = "enum" then "an" else "a" in
  (* GitHub issue #227 item 1 (prototype slice): the closed set of field
     names/types an `exception_entry`'s `frame` struct must have exactly --
     AArch64's own GPRs (x0..x30), the three EL0/EL1 exception-return
     registers, the EL0 thread pointer, all 32 SIMD/FP registers (as
     [u8;16] -- this language has no 128-bit primitive type, and none is
     needed just to store bytes), and FPSR/FPCR. Order-independent: codegen
     computes each register's offset from whatever order the struct itself
     declares (packed, sequential), not from this list's order. *)
  let aarch64_exception_frame_register_set =
    (List.init 31 (fun i -> (Printf.sprintf "x%d" i, Ast.TypeUsize)))
    @ ["sp_el0", Ast.TypeUsize; "elr_el1", Ast.TypeUsize;
       "spsr_el1", Ast.TypeUsize; "tpidr_el0", Ast.TypeUsize]
    @ (List.init 32 (fun i -> (Printf.sprintf "q%d" i, Ast.TypeArray (Ast.TypeU8, 16))))
    @ ["fpsr", Ast.TypeUsize; "fpcr", Ast.TypeUsize]
  in
  (* Shared by ExceptionEntryDef and ExceptionRestoreDef: `frame` must name a
     `struct packed` whose fields are EXACTLY
     aarch64_exception_frame_register_set, one of each. Looked up directly
     in `prog` (see the call sites' own comment on why, not
     Type_layout.structs -- a module dependency cycle). `decl_kind` is
     "exception_entry"/"exception_restore", only used to word error
     messages the same way each declaration kind's other errors are
     worded. *)
  let validate_exception_frame decl_kind decl_name loc frame =
    let struct_def = List.find_map (function
      | Ast.StructDef (n, fields, is_packed, _, _, _) when n = frame ->
          Some (fields, is_packed)
      | Ast.OwnedStructDef (n, _, _, fields, is_packed, _, _, _, _) when n = frame ->
          Some (fields, is_packed)
      | _ -> None) prog
    in
    match struct_def with
    | None -> raise (TypeError (loc, Printf.sprintf
        "%s '%s' frame '%s' is not a known struct" decl_kind decl_name frame))
    | Some (fields, is_packed) ->
        if not is_packed then
          raise (TypeError (loc, Printf.sprintf
            "%s '%s' frame '%s' must be a packed struct" decl_kind decl_name frame));
        let seen = Hashtbl.create 70 in
        List.iter (fun (fname, fty) ->
          match List.assoc_opt fname aarch64_exception_frame_register_set with
          | None -> raise (TypeError (loc, Printf.sprintf
              "%s '%s' frame '%s' has field '%s', which is not an AArch64 exception-frame register name"
              decl_kind decl_name frame fname))
          | Some expected_ty ->
              if fty <> expected_ty then
                raise (TypeError (loc, Printf.sprintf
                  "%s '%s' frame '%s' field '%s' has the wrong type"
                  decl_kind decl_name frame fname));
              if Hashtbl.mem seen fname then
                raise (TypeError (loc, Printf.sprintf
                  "%s '%s' frame '%s' has field '%s' more than once"
                  decl_kind decl_name frame fname));
              Hashtbl.add seen fname ()
        ) fields;
        List.iter (fun (rname, _) ->
          if not (Hashtbl.mem seen rname) then
            raise (TypeError (loc, Printf.sprintf
              "%s '%s' frame '%s' is missing register field '%s'"
              decl_kind decl_name frame rname))
        ) aarch64_exception_frame_register_set
  in
  let claim_toplevel_name name kind =
    if name = "addr" then
      raise (TypeError (Lexing.dummy_pos,
        "'addr' is reserved for the checker-only static address sort"));
    match Hashtbl.find_opt toplevel_names name with
    | Some "function" when kind = "function" -> ()
    | Some existing ->
        raise (TypeError (Lexing.dummy_pos,
          Printf.sprintf "'%s' is already defined as %s %s"
            name (article_for existing) existing))
    | None -> Hashtbl.add toplevel_names name kind
  in
  List.iter (function
    | Ast.FuncDef fdef          -> claim_toplevel_name fdef.name "function"
    | Ast.ExternFuncDef (n, _, _, _) -> claim_toplevel_name n "function"
    | Ast.ExternSymbolDef (n, _) -> claim_toplevel_name n "symbol"
    | Ast.ConstDef (n, _, _, _) -> claim_toplevel_name n "constant"
    | Ast.LetDef (n, _, _, _, _, _, _)  -> claim_toplevel_name n "global"
    | Ast.StructDef (n, _, _, _, _, _)  -> claim_toplevel_name n "struct"
    | Ast.OwnedStructDef (n, _, _, _, _, _, _, _, _) ->
        claim_toplevel_name n "struct"
    | Ast.OpaqueStructDef (n, _, _, _)  -> claim_toplevel_name n "struct"
    | Ast.ViewDef (n, _, _, _, _)       -> claim_toplevel_name n "view"
    | Ast.EnumDef (n, _, _, _)    -> claim_toplevel_name n "enum"
    | Ast.VariantDef (n, _, _, _)  -> claim_toplevel_name n "variant"
    | Ast.GenericStructDef (n, _, _, _, _, _, _) ->
        claim_toplevel_name n "generic struct"
    | Ast.UseDef _              -> ()
    | Ast.VectorTableDef _      -> ()
    | Ast.ExceptionEntryDef (n, _, _) -> claim_toplevel_name n "function"
    | Ast.ExceptionRestoreDef (n, _, _) -> claim_toplevel_name n "function"
  ) prog;
  (* GitHub issue #227 item 2: at most one `vector_table` declaration per
     program. Unlike every other toplevel item, `vector_table` claims no
     name in toplevel_names above (it is anonymous -- nothing else could
     ever reference it by name), so a second declaration would otherwise
     go undetected here and only surface as a confusing duplicate-symbol
     error from the linker once codegen emits `el1_vectors` twice. *)
  (match List.filter (function Ast.VectorTableDef _ -> true | _ -> false) prog with
   | _ :: (Ast.VectorTableDef (_, loc)) :: _ ->
       raise (TypeError (loc, "a program may declare at most one vector_table"))
   | _ -> ());
  (* Closed enums are finite static sorts. Keep their nominal case names,
     rather than their machine discriminants, so equal integer encodings in
     unrelated enums cannot satisfy one another's state contracts. *)
  let static_enum_defs : (string, string list * bool) Hashtbl.t =
    Hashtbl.create 8 in
  List.iter (function
    | Ast.EnumDef (name, _, cases, is_nonexhaustive) ->
        Hashtbl.replace static_enum_defs name
          (List.map fst cases, is_nonexhaustive)
    | _ -> ()) prog;
  Hashtbl.reset view_kinds;
  Hashtbl.reset view_params;
  List.iter (function
    | Ast.ViewDef (name, kind, params, _, _) ->
        Hashtbl.replace view_kinds name kind;
        Hashtbl.replace view_params name params
    | _ -> ()) prog;
  Hashtbl.reset variant_defs;
  List.iter (function
    | Ast.VariantDef (name, cases, _, _) ->
        Hashtbl.replace variant_defs name cases
    | _ -> ()) prog;
  Hashtbl.reset must_use_variants;
  List.iter (function
    | Ast.VariantDef (name, _, true, _) ->
        Hashtbl.replace must_use_variants name ()
    | _ -> ()) prog;
  Hashtbl.reset indexed_struct_params;
  Hashtbl.reset indexed_struct_kinds;
  List.iter (function
    | Ast.OwnedStructDef (name, kind, params, _, _, _, _, _, _) ->
        Hashtbl.replace indexed_struct_params name params;
        Hashtbl.replace indexed_struct_kinds name kind
    | _ -> ()) prog;
  let opaque_names = List.fold_left (fun names -> function
    | Ast.OpaqueStructDef (name, _, _, _) -> StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  let concrete_struct_names = List.fold_left (fun names -> function
    | Ast.StructDef (name, _, _, _, _, _)
    | Ast.OwnedStructDef (name, _, _, _, _, _, _, _, _) ->
        StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  let ordinary_struct_fields = List.fold_left (fun defs -> function
    | Ast.StructDef (name, fields, _, _, _, _) ->
        StringMap.add name fields defs
    | _ -> defs
  ) StringMap.empty prog in
  let affine_names = List.fold_left (fun names -> function
    | Ast.OpaqueStructDef (name, Ast.KindAffine, _, _) -> StringSet.add name names
    | Ast.OwnedStructDef (name, Ast.KindAffine, _, _, _, _, _, _, _) ->
        StringSet.add name names
    | Ast.ViewDef (name, Ast.KindAffine, _, _, _) -> StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  affine_opaque_names := affine_names;
  let linear_names = List.fold_left (fun names -> function
    | Ast.OpaqueStructDef (name, Ast.KindLinear, _, _) -> StringSet.add name names
    | Ast.OwnedStructDef (name, Ast.KindLinear, _, _, _, _, _, _, _) ->
        StringSet.add name names
    | Ast.ViewDef (name, Ast.KindLinear, _, _, _) -> StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  linear_opaque_names := linear_names;
  Hashtbl.reset variant_kinds;
  let join_kind a b = match a, b with
    | Ast.KindLinear, _ | _, Ast.KindLinear -> Ast.KindLinear
    | Ast.KindAffine, _ | _, Ast.KindAffine -> Ast.KindAffine
    | _ -> Ast.KindPlain
  in
  let rec payload_kind = function
    | Ast.TypeExists (_, _, body) -> payload_kind body
    | Ast.TypeNamed name | Ast.TypeView (name, _) ->
        if StringSet.mem name linear_names then Ast.KindLinear
        else if StringSet.mem name affine_names then Ast.KindAffine
        else (match Hashtbl.find_opt variant_kinds name with
          | Some kind -> kind
          | None ->
              (match StringMap.find_opt name ordinary_struct_fields with
               | Some fields ->
                   List.fold_left (fun kind (_, ty) ->
                     join_kind kind (payload_kind ty)
                   ) Ast.KindPlain fields
               | None -> Ast.KindPlain))
    | Ast.TypeVariant name ->
        Option.value (Hashtbl.find_opt variant_kinds name)
          ~default:Ast.KindPlain
    | Ast.TypeIndexed (name, _) ->
        (match Hashtbl.find_opt view_kinds name with
         | Some kind -> kind
         | None -> Option.value (Hashtbl.find_opt indexed_struct_kinds name)
             ~default:Ast.KindPlain)
    | Ast.TypePtr (Ast.TypeNamed name) ->
        if StringSet.mem name linear_names then Ast.KindLinear
        else if StringSet.mem name affine_names then Ast.KindAffine
        else Ast.KindPlain
    | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t | Ast.TypeIo t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypePtr t
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> payload_kind t
    | Ast.TypeTuple ts ->
        List.fold_left (fun kind t -> join_kind kind (payload_kind t))
          Ast.KindPlain ts
    | Ast.TypeFn (args, ret, _) ->
        List.fold_left (fun kind t -> join_kind kind (payload_kind t))
          (payload_kind ret) args
    | _ -> Ast.KindPlain
  in
  List.iter (function
    | Ast.VariantDef (name, cases, _, _) ->
        let kind = List.fold_left (fun kind (_, payload) ->
          match payload with
          | None -> kind
          | Some ty -> join_kind kind (payload_kind ty)
        ) Ast.KindPlain cases in
        if kind <> Ast.KindPlain then Hashtbl.replace variant_kinds name kind
    | _ -> ()) prog;
  global_align_bytes_baseline := List.fold_left (fun m -> function
    | Ast.LetDef (name, _, _, Some n, _, _, _) -> StringMap.add name n m
    | _ -> m
  ) StringMap.empty prog;
  Hashtbl.reset private_globals;
  List.iter (function
    | Ast.LetDef (name, _, _, _, _, true, loc) ->
        Hashtbl.replace private_globals name loc.Lexing.pos_fname
    | _ -> ()
  ) prog;
  locally_bound_names := StringSet.empty;
  opaque_struct_names_all := opaque_names;
  Hashtbl.reset private_opaque_types;
  Hashtbl.reset private_struct_fields;
  Hashtbl.reset private_struct_lit;
  Hashtbl.reset private_views;
  List.iter (function
    | Ast.OpaqueStructDef (name, _, true, loc) ->
        Hashtbl.replace private_opaque_types name loc.Lexing.pos_fname
    | Ast.StructDef (sname, _, _, _, privs, loc) when privs <> [] ->
        Hashtbl.replace private_struct_lit sname loc.Lexing.pos_fname;
        List.iter (fun f ->
          Hashtbl.replace private_struct_fields (sname, f) loc.Lexing.pos_fname
        ) privs
    | Ast.OwnedStructDef (sname, _, _, _, _, _, privs, is_private, loc) ->
        if is_private || privs <> [] then
          Hashtbl.replace private_struct_lit sname loc.Lexing.pos_fname;
        List.iter (fun f ->
          Hashtbl.replace private_struct_fields (sname, f) loc.Lexing.pos_fname
        ) privs
    | Ast.ViewDef (name, _, _, true, loc) ->
        Hashtbl.replace private_views name loc.Lexing.pos_fname
    | _ -> ()
  ) prog;
  Hashtbl.reset stable_owner_fields;
  Hashtbl.reset stable_owner_structs;
  List.iter (function
    | Ast.StructDef (sname, fields, _, _, private_fields, _) ->
        List.iter (fun (fname, ty) ->
          let variant_name = match resolve_declared_type ty with
            | Ast.TypeVariant name -> Some name
            | _ -> None
          in
          match variant_name with
          | Some name
            when Hashtbl.find_opt variant_kinds name = Some Ast.KindLinear
                           && List.mem fname private_fields ->
              Hashtbl.replace stable_owner_fields (sname, fname) ();
              Hashtbl.replace stable_owner_structs sname ()
          | _ -> ()
        ) fields
    | _ -> ()
  ) prog;
  let ast_is_stable_owner_struct = function
    | Ast.TypeNamed name -> Hashtbl.mem stable_owner_structs name
    | _ -> false
  in
  (* GitHub issue #158 (OWNERSHIP_KERNEL.md #131/#132, "indexed owners
     stored in arbitrary fields, arrays, globals, or other stable
     places"): a FIXED-SIZE ARRAY of a stable owner struct, as a
     top-level global, is the one array shape allowed to "contain"
     stable owner storage -- every array ELEMENT is its own independent
     stable location (its own lock + its own linear slot), addressed by
     a runtime index exactly the way stable_replace's own "same
     syntactic container" check (static_place_key's new Index case
     below) already requires: `&arr[i].lock` and `arr[i].state` must be
     the SAME `i`, proven by structural identity within one call, not
     by resolving `i`'s actual runtime value. This is narrower than
     "arbitrary stable places" in general -- still only a private
     mutable global with no initializer, still no nesting inside a
     struct field/tuple/function signature (ast_contains_stable_owner_value
     below keeps rejecting those, unchanged) -- but it is the concrete
     minimal case a real per-page copy-on-write table (up to
     MAX_PROCESS_PAGES entries) actually needs, and the one this feature
     was implemented against. *)
  let ast_is_stable_owner_array = function
    | Ast.TypeArray (Ast.TypeNamed name, _) -> Hashtbl.mem stable_owner_structs name
    | _ -> false
  in
  let rec ast_contains_stable_owner_value ty =
    match resolve_declared_type ty with
    | Ast.TypeNamed name -> Hashtbl.mem stable_owner_structs name
    | Ast.TypeIo t | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _)
    | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t
    | Ast.TypeSingleton (t, _) | Ast.TypeRefined (_, _, t)
    | Ast.TypeExists (_, _, t) -> ast_contains_stable_owner_value t
    | Ast.TypeTuple ts -> List.exists ast_contains_stable_owner_value ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists ast_contains_stable_owner_value args
        || ast_contains_stable_owner_value ret
    | Ast.TypePtr _ | Ast.TypeAlignedPtr _ -> false
    | _ -> false
  in
  let validation_static_scope : (string, Ast.type_expr) Hashtbl.t option ref =
    ref None in
  let allow_implicit_static = ref false in
  let is_integer_static_sort = function
    | Ast.TypeI8 | Ast.TypeI16 | Ast.TypeI32 | Ast.TypeI64
    | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU32 | Ast.TypeU64
    | Ast.TypeIsize | Ast.TypeUsize -> true
    | _ -> false
  in
  let validate_static_sort loc = function
    | sort when is_integer_static_sort sort -> ()
    | Ast.TypeNamed "addr" -> ()
    | Ast.TypeNamed name ->
        (match Hashtbl.find_opt static_enum_defs name with
         | Some (_, false) -> ()
         | Some (_, true) -> raise (TypeError (loc, Printf.sprintf
             "non-exhaustive enum '%s' cannot be used as a finite static sort"
             name))
         | None -> raise (TypeError (loc, Printf.sprintf
             "static sort '%s' is not addr, a primitive integer, or an exhaustive enum"
             name)))
    | sort -> raise (TypeError (loc, Printf.sprintf
        "static sort must be addr, a primitive integer, or an exhaustive enum, got %s"
        (Types.to_string (Types.of_ast sort))))
  in
  let static_sort_of_value loc = function
    | Ast.TypeRefined (_, _, base) -> base
    | (Ast.TypeI8 | Ast.TypeI16 | Ast.TypeI32 | Ast.TypeI64
      | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU32 | Ast.TypeU64
      | Ast.TypeIsize | Ast.TypeUsize) as t -> t
    | Ast.TypePtr _ | Ast.TypeAlignedPtr _ -> Ast.TypeNamed "addr"
    | t -> raise (TypeError (loc, Printf.sprintf
        "singleton '@' requires an integer or pointer runtime type, got %s"
        (Types.to_string (Types.of_ast t))))
  in
  let check_static_const loc sort n =
    if not (is_integer_static_sort sort) then
      raise (TypeError (loc, Printf.sprintf
        "static integer %d cannot be used where addr or enum sort %s is required"
        n (Types.to_string (Types.of_ast sort))));
    let fits = match sort with
      | Ast.TypeU8 -> n >= 0 && n < 256
      | Ast.TypeU16 -> n >= 0 && n < 65536
      | Ast.TypeU32 | Ast.TypeU64 | Ast.TypeUsize -> n >= 0
      | Ast.TypeI8 -> n >= -128 && n < 128
      | Ast.TypeI16 -> n >= -32768 && n < 32768
      | Ast.TypeI32 | Ast.TypeI64 | Ast.TypeIsize -> true
      | _ -> false
    in
    if not fits then raise (TypeError (loc, Printf.sprintf
      "static integer %d does not fit its declared sort" n))
  in
  let check_static_arg loc sort = function
    | Ast.StaticInt n -> check_static_const loc sort n
    | Ast.StaticEnum (enum_name, case_name) ->
        validate_static_sort loc sort;
        (match sort with
         | Ast.TypeNamed expected when expected <> enum_name ->
             raise (TypeError (loc, Printf.sprintf
               "static enum case '%s::%s' has sort %s, but %s is required"
               enum_name case_name enum_name expected))
         | Ast.TypeNamed expected ->
             if expected = "addr" then
               raise (TypeError (loc, Printf.sprintf
                 "static enum case '%s::%s' cannot be used where addr is required"
                 enum_name case_name))
             else
               let cases, _ = Hashtbl.find static_enum_defs expected in
               if not (List.mem case_name cases) then
                 raise (TypeError (loc, Printf.sprintf
                   "unknown static enum case '%s::%s'" expected case_name))
         | _ -> raise (TypeError (loc, Printf.sprintf
             "static enum case '%s::%s' cannot be used where an integer sort is required"
             enum_name case_name)))
    | Ast.StaticName name ->
        (match !validation_static_scope with
         | None -> raise (TypeError (loc, Printf.sprintf
             "static name '%s' is not in scope" name))
         | Some scope ->
             (match Hashtbl.find_opt scope name with
              | Some old when old <> sort ->
                  raise (TypeError (loc, Printf.sprintf
                    "static name '%s' is used with inconsistent static sorts" name))
              | Some _ -> ()
              | None when !allow_implicit_static -> Hashtbl.add scope name sort
              | None -> raise (TypeError (loc, Printf.sprintf
                  "static name '%s' is not bound by this function signature or struct"
                  name))))
  in
  let validate_effects ~allow_interrupt ~allow_noreturn loc kind name effects =
    let seen = ref StringSet.empty in
    List.iter (fun eff ->
      if eff <> "may_block" && eff <> "unsafe" && eff <> "interrupt"
         && eff <> "exception" && eff <> "noreturn" then
        raise (TypeError (loc, Printf.sprintf
          "unknown effect '%s' on %s '%s'; supported effects are may_block, unsafe, interrupt, exception, and noreturn"
          eff kind name));
      if (eff = "interrupt" || eff = "exception") && not allow_interrupt then
        raise (TypeError (loc,
          Printf.sprintf "'%s' is a function declaration role, not a function-pointer call effect" eff));
      if eff = "noreturn" && not allow_noreturn then
        raise (TypeError (loc,
          "'noreturn' is currently restricted to trusted extern function declarations"));
      if StringSet.mem eff !seen then
        raise (TypeError (loc, Printf.sprintf
          "duplicate effect '%s' on %s '%s'" eff kind name));
      seen := StringSet.add eff !seen
    ) effects;
    if StringSet.mem "may_block" !seen && StringSet.mem "interrupt" !seen then
      raise (TypeError (loc, Printf.sprintf
        "%s '%s' cannot be both interrupt and may_block" kind name));
    if StringSet.mem "may_block" !seen && StringSet.mem "exception" !seen then
      raise (TypeError (loc, Printf.sprintf
        "%s '%s' cannot be both exception and may_block" kind name));
    if StringSet.mem "interrupt" !seen && StringSet.mem "exception" !seen then
      raise (TypeError (loc, Printf.sprintf
        "%s '%s' cannot be both interrupt and exception" kind name))
  in
  let validate_static_application loc kind name formals args =
    if List.length args <> List.length formals then
      raise (TypeError (loc, Printf.sprintf
        "%s '%s' expects %d static argument(s), got %d"
        kind name (List.length formals) (List.length args)));
    List.iter (fun (_, sort) -> validate_static_sort loc sort) formals;
    List.iter2 (fun arg (_, sort) -> check_static_arg loc sort arg)
      args formals
  in
  let rec validate_static_type loc ty =
    match ty with
    | Ast.TypeExists _ ->
        raise (TypeError (loc,
          "exists is only valid as the outermost payload type of a variant case in Slice 3"))
    | Ast.TypeNamed name when Hashtbl.mem indexed_struct_params name ->
        let arity = List.length (Hashtbl.find indexed_struct_params name) in
        raise (TypeError (loc, Printf.sprintf
          "indexed struct '%s' requires %d static argument(s); write %s[...]"
          name arity name))
    | Ast.TypeNamed name when Hashtbl.mem view_params name ->
        let arity = List.length (Hashtbl.find view_params name) in
        if arity <> 0 then
          raise (TypeError (loc, Printf.sprintf
            "indexed view '%s' requires %d static argument(s); write %s[...]"
            name arity name))
    | Ast.TypeView (name, args) ->
        (match Hashtbl.find_opt view_params name with
         | None -> raise (TypeError (loc, Printf.sprintf
             "unknown erased view '%s'" name))
         | Some formals ->
             validate_static_application loc "view" name formals args)
    | Ast.TypeIndexed (name, args) ->
        (match Hashtbl.find_opt view_params name,
               Hashtbl.find_opt indexed_struct_params name with
         | Some formals, _ ->
             validate_static_application loc "view" name formals args
         | None, None -> raise (TypeError (loc, Printf.sprintf
             "'%s' is not an indexed runtime struct or view" name))
         | None, Some formals ->
             if List.length args <> List.length formals then
               raise (TypeError (loc, Printf.sprintf
                 "indexed struct '%s' expects %d static argument(s), got %d"
                 name (List.length formals) (List.length args)));
             List.iter2 (fun arg (_, sort) -> check_static_arg loc sort arg)
               args formals)
    | Ast.TypeSingleton (base, arg) ->
        validate_static_type loc base;
        check_static_arg loc (static_sort_of_value loc base) arg
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> validate_static_type loc t
    | Ast.TypeFn (args, ret, effects) ->
        Option.iter
          (validate_effects ~allow_interrupt:false ~allow_noreturn:false loc "function pointer type" "fn")
          effects;
        List.iter (validate_static_type loc) args;
        validate_static_type loc ret
    | Ast.TypeTuple ts -> List.iter (validate_static_type loc) ts
    | _ -> ()
  in
  let rec validate_complete_type loc behind_ptr = function
    | Ast.TypeNamed "addr" ->
        raise (TypeError (loc,
          "addr is a checker-only static sort and cannot be used as a runtime type"))
    | Ast.TypeNamed name when StringSet.mem name opaque_names && not behind_ptr ->
        raise (TypeError (loc, Printf.sprintf
          "opaque struct '%s' is incomplete and may only be used behind a pointer" name))
    | Ast.TypePtr inner -> validate_complete_type loc true inner
    | Ast.TypeIo inner -> validate_complete_type loc behind_ptr inner
    | Ast.TypeArray (inner, _) | Ast.TypeSlice (inner, _) ->
        validate_complete_type loc false inner
    | Ast.TypeFn (args, ret, _) ->
        List.iter (validate_complete_type loc false) args;
        validate_complete_type loc false ret
    | Ast.TypeRefined (_, _, base) -> validate_complete_type loc false base
    | Ast.TypeBorrow inner | Ast.TypeBorrowMut inner | Ast.TypeSink inner
    | Ast.TypeSingleton (inner, _) -> validate_complete_type loc behind_ptr inner
    | Ast.TypeRef inner | Ast.TypeRefMut inner -> validate_complete_type loc true inner
    | Ast.TypeExists (_, _, inner) -> validate_complete_type loc behind_ptr inner
    | Ast.TypeIndexed _ -> ()
    | _ -> ()
  in
  let rec contains_borrow = function
    | Ast.TypeBorrow _ | Ast.TypeBorrowMut _ | Ast.TypeSink _ -> true
    | Ast.TypePtr t | Ast.TypeIo t -> contains_borrow t
    | Ast.TypeTuple ts -> List.exists contains_borrow ts
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> contains_borrow t
    | Ast.TypeFn (args, ret, _) ->
        List.exists contains_borrow args || contains_borrow ret
    | Ast.TypeRefined (_, _, base) | Ast.TypeSingleton (base, _) -> contains_borrow base
    | Ast.TypeExists (_, _, body) -> contains_borrow body
    | _ -> false
  in
  (* GitHub issue #314/#319: &T/&mut T is, in v1, legal only as a function
     parameter type or a local `let` binding type -- not a struct field,
     global, return type, or array/slice element (no escape/lifetime
     analysis is implemented for it yet; see #314's #132 discussion for
     why that is deliberate, not deferred-and-forgotten). Mirrors
     contains_borrow's own shape/call sites exactly. *)
  let rec contains_ref = function
    | Ast.TypeRef _ | Ast.TypeRefMut _ -> true
    | Ast.TypePtr t | Ast.TypeIo t -> contains_ref t
    | Ast.TypeTuple ts -> List.exists contains_ref ts
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> contains_ref t
    | Ast.TypeFn (args, ret, _) ->
        List.exists contains_ref args || contains_ref ret
    | Ast.TypeRefined (_, _, base) | Ast.TypeSingleton (base, _) -> contains_ref base
    | Ast.TypeExists (_, _, body) -> contains_ref body
    | _ -> false
  in
  (* &T/&mut T may only wrap a plain named struct -- the whole point is a
     struct borrow, not a general-purpose pointer alternative. Rejects
     nonsensical/underspecified shapes like &usize, &*T, or &&T up front. *)
  let validate_ref_referent loc = function
    | Ast.TypeNamed _ -> ()
    | inner -> raise (TypeError (loc, Printf.sprintf
        "&/&mut may only wrap a plain struct type, not '%s'"
        (Ast.show_type_expr inner))) in
  let is_kinded name =
    StringSet.mem name affine_names || StringSet.mem name linear_names in
  (* OWNERSHIP_KERNEL.md Stage 1 storage bans, declaration side: a linear
     pointer may not appear in any type that IS storage (struct fields,
     globals) or that nests it inside a container (arrays, slices --
     anywhere, including locals). Bare `*L` locals/params are the only
     legal homes until Stage 3's place tracking. The store-side runtime
     checks (AssignField/AssignIndex/AssignDeref) in infer_stmt are the
     load-bearing enforcement; these declaration bans reject the storage
     shapes up front so the error points at the declaration. *)
  let rec type_mentions_linear = function
    | Ast.TypeNamed n | Ast.TypeView (n, _) -> StringSet.mem n linear_names
    | Ast.TypeIndexed (n, _) -> StringSet.mem n linear_names
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> type_mentions_linear t
    | Ast.TypeTuple ts -> List.exists type_mentions_linear ts
    | Ast.TypeVariant name ->
        Hashtbl.find_opt variant_kinds name = Some Ast.KindLinear
    | Ast.TypeExists (_, _, body) -> type_mentions_linear body
    | _ -> false
  in
  let rec type_mentions_view = function
    | Ast.TypeView _ -> true
    | Ast.TypeNamed name -> Hashtbl.mem view_kinds name
    | Ast.TypeIndexed (name, _) when Hashtbl.mem view_kinds name -> true
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypeArray (t, _)
    | Ast.TypeSlice (t, _) -> type_mentions_view t
    | Ast.TypeTuple ts -> List.exists type_mentions_view ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists type_mentions_view args || type_mentions_view ret
    | Ast.TypeExists (_, _, body) -> type_mentions_view body
    | _ -> false
  in
  let is_direct_view_type ty = match resolve_declared_type ty with
    | Ast.TypeView _ -> true
    | _ -> false
  in
  let rec type_mentions_variant = function
    | Ast.TypeVariant _ -> true
    | Ast.TypeNamed name -> Hashtbl.mem variant_defs name
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypeArray (t, _)
    | Ast.TypeSlice (t, _) -> type_mentions_variant t
    | Ast.TypeTuple ts -> List.exists type_mentions_variant ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists type_mentions_variant args || type_mentions_variant ret
    | Ast.TypeExists (_, _, body) -> type_mentions_variant body
    | _ -> false
  in
  let rec type_mentions_kinded_variant = function
    | Ast.TypeVariant name -> Hashtbl.mem variant_kinds name
    | Ast.TypeNamed name when Hashtbl.mem variant_defs name ->
        Hashtbl.mem variant_kinds name
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypeArray (t, _)
    | Ast.TypeSlice (t, _) -> type_mentions_kinded_variant t
    | Ast.TypeTuple ts -> List.exists type_mentions_kinded_variant ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists type_mentions_kinded_variant args
        || type_mentions_kinded_variant ret
    | Ast.TypeExists (_, _, body) -> type_mentions_kinded_variant body
    | _ -> false
  in
  let is_direct_variant_type ty = match resolve_declared_type ty with
    | Ast.TypeVariant _ -> true
    | _ -> false
  in
  let is_direct_variant_tuple = function
    | Ast.TypeTuple elements ->
        List.exists is_direct_variant_type elements
        && List.for_all (fun element ->
             not (type_mentions_variant element)
             || is_direct_variant_type element) elements
    | _ -> false
  in
  let rec type_mentions_exists = function
    | Ast.TypeExists _ -> true
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypeArray (t, _)
    | Ast.TypeSlice (t, _) -> type_mentions_exists t
    | Ast.TypeTuple ts -> List.exists type_mentions_exists ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists type_mentions_exists args || type_mentions_exists ret
    | _ -> false
  in
  let rec type_mentions_indexed_owner = function
    | Ast.TypeIndexed (name, _) -> Hashtbl.mem indexed_struct_kinds name
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
    | Ast.TypeAlignedPtr (_, t) | Ast.TypeArray (t, _)
    | Ast.TypeSlice (t, _) -> type_mentions_indexed_owner t
    | Ast.TypeTuple ts -> List.exists type_mentions_indexed_owner ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists type_mentions_indexed_owner args || type_mentions_indexed_owner ret
    | Ast.TypeExists (_, _, body) -> type_mentions_indexed_owner body
    | _ -> false
  in
  let rec type_mentions_singleton = function
    | Ast.TypeSingleton _ -> true
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> type_mentions_singleton t
    | Ast.TypeTuple ts -> List.exists type_mentions_singleton ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists type_mentions_singleton args || type_mentions_singleton ret
    | Ast.TypeExists (_, _, body) -> type_mentions_singleton body
    | _ -> false
  in
  let rec singleton_under_storage inside = function
    | Ast.TypeSingleton _ -> inside
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) ->
        singleton_under_storage true t
    | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) ->
        singleton_under_storage inside t
    | Ast.TypeTuple ts -> List.exists (singleton_under_storage inside) ts
    | Ast.TypeFn (args, ret, _) ->
        List.exists (singleton_under_storage false) args
        || singleton_under_storage false ret
    | _ -> false
  in
  let rec indexed_owner_under_indirection inside = function
    | Ast.TypeIndexed (name, _) -> inside && Hashtbl.mem indexed_struct_kinds name
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) ->
        indexed_owner_under_indirection true t
    | Ast.TypeFn (args, ret, _) ->
        List.exists (indexed_owner_under_indirection true) args
        || indexed_owner_under_indirection true ret
    | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t)
    | Ast.TypeSingleton (t, _) -> indexed_owner_under_indirection inside t
    | Ast.TypeTuple ts -> List.exists (indexed_owner_under_indirection inside) ts
    | _ -> false
  in
  (* OWNERSHIP_KERNEL.md 5.9: tuples are values, not storage. A tuple type
     may appear only at the top level of a return type, parameter type, or
     local let annotation -- never under a pointer/array/slice/io (and, via
     the LetDef/StructDef checks below, never as a global or field). *)
  let rec tuple_under_indirection inside = function
    | Ast.TypeTuple ts ->
        inside || List.exists (tuple_under_indirection inside) ts
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) ->
        tuple_under_indirection true t
    | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) ->
        tuple_under_indirection inside t
    | Ast.TypeSingleton (t, _) -> tuple_under_indirection inside t
    | _ -> false
  in
  let rec type_mentions_tuple = function
    | Ast.TypeTuple _ -> true
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeAlignedPtr (_, t)
    | Ast.TypeSingleton (t, _)
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> type_mentions_tuple t
    | Ast.TypeExists (_, _, body) -> type_mentions_tuple body
    | _ -> false
  in
  (* GitHub issue #240 (capability-based reformulation, see that issue's
     comment thread): a struct field's pointer type is rejected unless it
     is already structurally incapable of pointer forgery -- today that
     means only a pointer to an affine/linear opaque struct, which
     already rejects arithmetic, indexing, dereference, and cast-away
     unconditionally (check_ptr_arith_complete, check_deref_complete,
     check_resource_cast_away), regardless of where the pointer value
     lives. An ordinary `*T`/`*align(N) T` field can still do all of
     those, so it can hide exactly the ownership/lifetime relationship
     this issue's Motivation describes. `*io T` used to be exempt here,
     deferred pending issue #316's MMIO scoping decision -- #316 resolved
     by requiring `unsafe` for `*io` construction uniformly, with the same
     capability-based reasoning this rule already uses (`*io T` supports
     the identical arithmetic/indexing/dereference as ordinary `*T`, so a
     `*io T` field can hide the same ownership/lifetime relationship via a
     paired, unenforced length field, e.g. `chan_regs: *io ChanRegs;
     chan_count: usize;` walked as `chan_regs + i`) -- extended here for
     consistency rather than left as a standing exemption. The repo-wide
     survey this decision was based on found exactly one real occurrence
     (examples/common_qemu/gic_regs.tkb's `GicRegs`, seven UNRELATED
     scattered-address registers with no paired length field at all, not
     an MMIO block hazard in practice), migrated to individual
     module-level `*io` globals -- the same pattern every other MMIO
     driver in this codebase already uses, and the one this rule's own
     error message below points to. A single large, OFFSET-CONSISTENT
     register block (the shape a future PCI-config/ACPI/dtb-discovered
     device would actually want) was never blocked by this rule in the
     first place: that is a `*io Struct` POINTER VARIABLE (`let regs: *io
     BigRegBlock = ...;`), not a struct FIELD, and `p.field` on it is
     already a volatile field load with compiler-checked offsets (see
     "MMIO / Volatile" in SPEC.md) -- entirely unaffected by this rule,
     which only governs pointer types stored INSIDE another struct's own
     fields. *)
  let struct_field_ptr_pointee_is_inert = function
    | Ast.TypeNamed sname ->
        StringSet.mem sname !affine_opaque_names
        || StringSet.mem sname !linear_opaque_names
    | _ -> false
  in
  let check_struct_field_pointer sname fname sloc ty =
    match ty with
    | Ast.TypePtr pointee | Ast.TypeAlignedPtr (_, pointee) ->
        if not (struct_field_ptr_pointee_is_inert pointee) then
          raise (TypeError (sloc, Printf.sprintf
            "struct field '%s.%s' cannot hold pointer type '%s': it still \
             supports arithmetic, indexing, and dereference, which can \
             hide an ownership/lifetime relationship (GitHub issue #240); \
             use a slice, an affine/linear opaque handle, or (for \
             individually named hardware registers) separate module-level \
             `*io`-qualified globals instead"
            sname fname (Ast.show_type_expr ty)))
    | _ -> ()
  in
  let rec linear_inside_container = function
    | Ast.TypeArray (t, _) | Ast.TypeSlice (t, _) -> type_mentions_linear t
    | Ast.TypePtr t | Ast.TypeIo t | Ast.TypeBorrow t | Ast.TypeBorrowMut t
    | Ast.TypeSink t
    | Ast.TypeRefined (_, _, t) | Ast.TypeAlignedPtr (_, t) ->
        linear_inside_container t
    | Ast.TypeSingleton (t, _) -> linear_inside_container t
    | Ast.TypeTuple ts -> List.exists linear_inside_container ts
    | _ -> false
  in
  let validate_param_type loc ty =
    validate_static_type loc ty;
    match ty with
    | Ast.TypeBorrow ((Ast.TypePtr _ | Ast.TypeAlignedPtr _
                      | Ast.TypeSlice _) as inner) ->
        validate_complete_type loc false inner
    | Ast.TypeBorrow (Ast.TypeNamed name as inner)
      when Hashtbl.mem view_kinds name -> validate_complete_type loc false inner
    | Ast.TypeBorrow (Ast.TypeView (name, _) as inner)
      when Hashtbl.mem view_kinds name -> validate_complete_type loc false inner
    | Ast.TypeBorrow (Ast.TypeIndexed (name, _) as inner)
      when is_kinded name -> validate_complete_type loc false inner
    | Ast.TypeBorrow (Ast.TypeNamed name as inner)
      when Hashtbl.mem variant_kinds name -> validate_complete_type loc false inner
    | Ast.TypeBorrow (Ast.TypeVariant name as inner)
      when Hashtbl.mem variant_kinds name -> validate_complete_type loc false inner
    | Ast.TypeBorrow _ ->
        raise (TypeError (loc,
          "borrow is only valid on a raw/aligned pointer, slice, affine/linear opaque pointer, indexed owner, erased view, or kinded variant parameter"))
    | Ast.TypeBorrowMut (Ast.TypeIndexed (name, _) as inner)
      when is_kinded name -> validate_complete_type loc false inner
    | Ast.TypeBorrowMut _ ->
        raise (TypeError (loc,
          "borrow mut is only valid on an affine/linear indexed runtime owner parameter"))
    | Ast.TypeSink (Ast.TypeNamed name as inner)
      when Hashtbl.mem view_kinds name -> validate_complete_type loc false inner
    | Ast.TypeSink (Ast.TypeView (name, _) as inner)
      when Hashtbl.mem view_kinds name -> validate_complete_type loc false inner
    | Ast.TypeSink (Ast.TypePtr (Ast.TypeNamed name) as inner)
      when is_kinded name -> validate_complete_type loc false inner
    | Ast.TypeSink (Ast.TypeIndexed (name, _) as inner)
      when is_kinded name -> validate_complete_type loc false inner
    | Ast.TypeSink (Ast.TypeNamed name as inner)
      when Hashtbl.mem variant_kinds name -> validate_complete_type loc false inner
    | Ast.TypeSink (Ast.TypeVariant name as inner)
      when Hashtbl.mem variant_kinds name -> validate_complete_type loc false inner
    | Ast.TypeSink _ ->
        raise (TypeError (loc,
          "sink is only valid on an affine/linear opaque pointer, indexed owner, erased view, or kinded variant parameter"))
    | Ast.TypeRef inner ->
        validate_ref_referent loc inner;
        validate_complete_type loc true inner
    | Ast.TypeRefMut inner ->
        validate_ref_referent loc inner;
        validate_complete_type loc true inner
    | ty ->
        if ast_contains_stable_owner_value ty then
          raise (TypeError (loc,
            "stable owner containers cannot be passed by value; pass a pointer to their private global storage"));
        if contains_borrow ty then
          raise (TypeError (loc,
            "borrow/sink must wrap the entire function parameter type"));
        if contains_ref ty then
          raise (TypeError (loc,
            "&/&mut must wrap the entire function parameter type"));
        if type_mentions_view ty && not (is_direct_view_type ty) then
          raise (TypeError (loc,
            "an erased view must be the entire function parameter type; it cannot live inside a runtime container or function pointer"));
        if type_mentions_variant ty && not (is_direct_variant_type ty)
           && not (is_direct_variant_tuple ty) then
          raise (TypeError (loc,
            "a variant must be the entire function parameter type in Slice 3"));
        if type_mentions_exists ty then
          raise (TypeError (loc,
            "exists is opened by matching a variant payload; it is not a direct parameter type in Slice 3"));
        if tuple_under_indirection false ty then
          raise (TypeError (loc,
            "a tuple cannot live behind a pointer or inside an array/slice: \
             tuples are values, not storage (OWNERSHIP_KERNEL.md 5.9)"));
        if indexed_owner_under_indirection false ty then
          raise (TypeError (loc,
            "an indexed owner cannot live behind a pointer or inside storage"));
        if singleton_under_storage false ty then
          raise (TypeError (loc,
            "a singleton value cannot live behind a pointer or inside array/slice storage"));
        validate_complete_type loc false ty
  in
  let validate_nonparam_type ?(allow_ref=false) loc ty =
    validate_static_type loc ty;
    if contains_borrow ty then
      raise (TypeError (loc, "borrow/sink is only valid in function parameter types"));
    (match ty with
     | (Ast.TypeRef inner | Ast.TypeRefMut inner) when allow_ref ->
         validate_ref_referent loc inner
     | _ ->
         if contains_ref ty then
           raise (TypeError (loc,
             "&/&mut is only valid in a function parameter type or a local \
              let binding type (GitHub issue #314/#319): not a struct \
              field, global, return type, or array/slice element")));
    if type_mentions_view ty && not (is_direct_view_type ty) then
      raise (TypeError (loc,
        "an erased view cannot live inside a runtime container or function pointer"));
    if type_mentions_variant ty && not (is_direct_variant_type ty)
       && not (is_direct_variant_tuple ty) then
      raise (TypeError (loc,
        "a variant cannot live inside another runtime container in Slice 3"));
    if type_mentions_exists ty then
      raise (TypeError (loc,
        "exists is only valid as a variant payload type in Slice 3"));
    if tuple_under_indirection false ty then
      raise (TypeError (loc,
        "a tuple cannot live behind a pointer or inside an array/slice: \
         tuples are values, not storage (OWNERSHIP_KERNEL.md 5.9)"));
    if linear_inside_container ty then
      raise (TypeError (loc,
        "a linear value cannot live inside an array/slice: it would escape \
         obligation tracking (OWNERSHIP_KERNEL.md Stage 3 will lift this)"));
    if indexed_owner_under_indirection false ty then
      raise (TypeError (loc,
        "an indexed owner cannot live behind a pointer, function pointer, array, or slice"));
    if singleton_under_storage false ty then
      raise (TypeError (loc,
        "a singleton value cannot live behind a pointer or inside array/slice storage"));
    validate_complete_type loc false ty
  in
  (* A `let`/LetMatch annotation may ALSO be a bare existential, packaging an
     indexed owner/view/tuple exactly like a variant payload does (same
     restriction, same reason: an existential's whole point is hiding the
     concrete index, and only these three shapes have a runtime
     representation that does not otherwise depend on it). Reuses the
     variant-payload validator's own "bind_all, then validate the stripped
     body under a scope that knows the bound names" pattern; the temporary
     scope is swapped back out afterward since a local `let`'s existential
     names are meant to be fresh to that one declaration, not to leak into
     the rest of the enclosing function the way a function's own static
     parameters do. *)
  let validate_let_type loc ty =
    match ty with
    | Ast.TypeExists _ ->
        let saved_scope = !validation_static_scope in
        let saved_implicit = !allow_implicit_static in
        let scope = Hashtbl.create 8 in
        let rec bind_all = function
          | Ast.TypeExists (name, sort, body) ->
              validate_static_sort loc sort;
              if Hashtbl.mem scope name then
                raise (TypeError (loc, Printf.sprintf
                  "duplicate existential '%s' in let binding" name));
              Hashtbl.add scope name sort;
              bind_all body
          | body -> body
        in
        let body = bind_all ty in
        (match resolve_declared_type body with
         | Ast.TypeIndexed _ | Ast.TypeView _ | Ast.TypeTuple _ -> ()
         | _ -> raise (TypeError (loc,
             "an existential let binding must package an indexed runtime \
              owner, erased view, or tuple containing owners")));
        validation_static_scope := Some scope;
        allow_implicit_static := false;
        validate_nonparam_type loc body;
        validation_static_scope := saved_scope;
        allow_implicit_static := saved_implicit
    | _ -> validate_nonparam_type ~allow_ref:true loc ty
  in
  let rec validate_expr_types (e : Ast.expr) =
    (match e.desc with
     | Ast.Cast (ty, x) ->
         (* GitHub issue #314/#319: `x as &T`/`x as &mut T` is a legal cast
            target (see infer_expr's Cast case for the actual semantics --
            only a same-referent raw pointer, gated by `unsafe`, or another
            &/&mut of the same referent, may cast INTO &T/&mut T); allow it
            here too, same as validate_let_type already does for a `let`
            annotation. *)
         validate_nonparam_type ~allow_ref:true e.loc ty; validate_expr_types x
     | Ast.SizeOf ty | Ast.OffsetOf (ty, _) ->
         if type_mentions_view ty then
           raise (TypeError (e.loc,
             "an erased view has no runtime size or layout"));
         validate_nonparam_type e.loc ty
     | Ast.BinOp (_, a, b) -> validate_expr_types a; validate_expr_types b
     | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x | Ast.FieldGet (x, _)
     | Ast.Unsafe x -> validate_expr_types x
     | Ast.Call (_, xs) | Ast.StructLit xs | Ast.TupleLit xs -> List.iter validate_expr_types xs
     | Ast.VariantCtor (_, _, payload) -> validate_expr_types payload
     | Ast.Index (_, i) -> validate_expr_types i
     | Ast.SliceOf (_, lo, hi) -> validate_expr_types lo; validate_expr_types hi
     | Ast.ViewLit (name, args) ->
         (match Hashtbl.find_opt view_params name with
          | None -> raise (TypeError (e.loc, Printf.sprintf
              "unknown erased view '%s'" name))
          | Some formals ->
              validate_static_application e.loc "view" name formals args)
     | Ast.Assign (lhs, rhs) -> validate_expr_types lhs; validate_expr_types rhs
     | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.Var _
     | Ast.EnumVariant _ | Ast.EmbedFile _ -> ())
  and validate_stmt_types (s : Ast.stmt) =
    (match s.desc with
     | Ast.Let (_, _, ty, init, _) ->
         Option.iter (fun t ->
           if ast_contains_stable_owner_value t then
             raise (TypeError (s.loc,
               "stable owner container storage must be a private mutable global, not a local value"))
         ) ty;
         Option.iter (validate_let_type s.loc) ty;
         Option.iter validate_expr_types init
     | Ast.For (_, ty, lo, hi, body) ->
         Option.iter (validate_nonparam_type s.loc) ty;
         validate_expr_types lo; validate_expr_types hi;
         List.iter validate_stmt_types body
     | Ast.Return (Some e) | Ast.Expr e | Ast.Yield e -> validate_expr_types e
     | Ast.Return None -> ()
     | Ast.LetTuple (_, e) -> validate_expr_types e
     | Ast.Block body | Ast.UnsafeBlock body -> List.iter validate_stmt_types body
     | Ast.While (c, body) ->
         validate_expr_types c; List.iter validate_stmt_types body
     | Ast.If (c, yes, no) ->
         validate_expr_types c; List.iter validate_stmt_types yes;
         List.iter validate_stmt_types no
     | Ast.ForEach (_, e, body) ->
         validate_expr_types e; List.iter validate_stmt_types body
     | Ast.Match (e, arms) ->
         validate_expr_types e;
         List.iter (function
           | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmIntLit (_, b) ->
               List.iter validate_stmt_types b) arms
     | Ast.LetMatch (_, _, ty, disc, arms) ->
         Option.iter (fun t ->
           if ast_contains_stable_owner_value t then
             raise (TypeError (s.loc,
               "stable owner container storage must be a private mutable global, not a local value"))
         ) ty;
         Option.iter (validate_let_type s.loc) ty;
         validate_expr_types disc;
         List.iter (function
           | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmIntLit (_, b) ->
               List.iter validate_stmt_types b) arms
     | Ast.Break | Ast.Continue -> ())
  in
  List.iter (function
    | Ast.FuncDef f ->
        Option.iter
          (validate_effects ~allow_interrupt:true ~allow_noreturn:false f.def_loc "function" f.name)
          f.effects;
        let scope = Hashtbl.create 8 in
        validation_static_scope := Some scope;
        allow_implicit_static := true;
        List.iter (fun (_, ty) -> Option.iter (validate_param_type f.def_loc) ty) f.params;
        (* Authority-derived region annotation on a slice or pointer return
           type (`-> [T; N..] @ name` / `-> *T @ name`, issues #106/#128):
           accepted ONLY here, as the whole return type of a function
           definition. The name must be a static index of a borrowed indexed
           owner or view. The callee body has no new obligation; this is a
           reviewed API contract restricting the CALLER's use of the result.
           Pointer singleton parameters retain their ordinary addr-identity
           meaning because this branch is return-position-only. *)
        (match Option.bind f.ret_type region_return_annotation with
         | Some (base, arg, kind) ->
             let value_kind = region_kind_word kind in
             (match arg with
              | Ast.StaticInt n ->
                  raise (TypeError (f.def_loc, Printf.sprintf
                    "%s return annotation '@ %d': a region annotation \
                     must name a static parameter, not an integer"
                    value_kind n))
              | Ast.StaticEnum (enum_name, case_name) ->
                  raise (TypeError (f.def_loc, Printf.sprintf
                    "%s return annotation '@ %s::%s': a region annotation \
                     must name a static parameter, not an enum case"
                    value_kind enum_name case_name))
              | Ast.StaticName n ->
                  let names_authority_index = function
                    | Some (Ast.TypeBorrow (Ast.TypeIndexed (_, args)))
                    | Some (Ast.TypeBorrowMut (Ast.TypeIndexed (_, args))) ->
                        List.mem (Ast.StaticName n) args
                    | _ -> false
                  in
                  if not (List.exists (fun (_, ty) -> names_authority_index ty)
                            f.params) then begin
                    let authority_desc = match kind with
                      | RegionSlice -> "indexed-owner parameter"
                      | RegionPointer -> "indexed-owner or indexed-view parameter"
                    in
                    raise (TypeError (f.def_loc, Printf.sprintf
                      "%s return annotation '@ %s': '%s' does not name a \
                       static index of any borrow or borrow mut %s of this \
                       function"
                      value_kind n n authority_desc))
                  end;
                  validate_nonparam_type f.def_loc base)
         | None when (match f.ret_type with
             | Some ret -> ast_contains_stable_owner_value ret
             | None -> false) ->
             raise (TypeError (f.def_loc,
               "stable owner containers cannot be returned by value"))
         | None -> Option.iter (validate_nonparam_type f.def_loc) f.ret_type);
        allow_implicit_static := false;
        List.iter validate_stmt_types f.body
    | Ast.ExternFuncDef (name, params, ret, effects) ->
        Option.iter (fun effects ->
          validate_effects ~allow_interrupt:true ~allow_noreturn:true Lexing.dummy_pos
            "extern function" name effects;
          if List.mem "interrupt" effects || List.mem "exception" effects then
            raise (TypeError (Lexing.dummy_pos, Printf.sprintf
              "extern function '%s' cannot be an interrupt or exception root because it has no body to check"
              name))
        ) effects;
        validation_static_scope := Some (Hashtbl.create 8);
        allow_implicit_static := true;
        List.iter (fun (pname, ty) -> match ty with
          | Some t -> validate_param_type Lexing.dummy_pos t
          | None -> raise (TypeError (Lexing.dummy_pos, Printf.sprintf
              "extern fn '%s' parameter '%s' has no type annotation; extern fn \
               parameters must be explicitly typed (there is no function body \
               to infer them from)" name pname))
        ) params;
        Option.iter (fun t ->
          if ast_contains_stable_owner_value t then
            raise (TypeError (Lexing.dummy_pos,
              "stable owner containers cannot be returned by value"));
          validate_nonparam_type Lexing.dummy_pos t
        ) ret
    | Ast.ConstDef (_gname, ty, init, gloc) ->
        validation_static_scope := None;
        allow_implicit_static := false;
        (match ty with
         | Ast.TypeI8 | Ast.TypeI16 | Ast.TypeI32 | Ast.TypeI64
         | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU16Be
         | Ast.TypeU32 | Ast.TypeU32Be | Ast.TypeU64
         | Ast.TypeIsize | Ast.TypeUsize -> ()
         | _ ->
             raise (TypeError (gloc,
               "`const` declarations are restricted to primitive integer types; \
                use a global `let` for pointers, io registers, arrays, structs, \
                sizeof/offsetof-derived values, or other runtime constants")));
        validate_nonparam_type gloc ty;
        validate_expr_types init
    | Ast.LetDef (gname, ty, init, _, is_mutable, is_private, gloc) ->
        validation_static_scope := None;
        allow_implicit_static := false;
        (match ty with
         | Some t when ast_is_stable_owner_struct t || ast_is_stable_owner_array t ->
             if not is_private then
               raise (TypeError (gloc, Printf.sprintf
                 "stable owner container global '%s' must be private" gname));
             if not is_mutable then
               raise (TypeError (gloc, Printf.sprintf
                 "stable owner container global '%s' must be mutable" gname));
             if Option.is_some init then
               raise (TypeError (gloc, Printf.sprintf
                 "stable owner container global '%s' must use zero-initialized storage without an initializer"
                 gname))
         | Some t when ast_contains_stable_owner_value t ->
             raise (TypeError (gloc, Printf.sprintf
               "global '%s' cannot contain stable owner storage inside another value"
               gname))
         | _ -> ());
        Option.iter (fun t ->
          if type_mentions_view t then
            raise (TypeError (gloc, Printf.sprintf
              "global '%s' cannot hold an erased view" gname));
          if type_mentions_variant t then
            raise (TypeError (gloc, Printf.sprintf
              "global '%s' cannot hold a variant in Slice 3" gname));
          if type_mentions_indexed_owner t then
            raise (TypeError (gloc, Printf.sprintf
              "global '%s' cannot hold an indexed owner" gname));
          if type_mentions_singleton t then
            raise (TypeError (gloc, Printf.sprintf
              "global '%s' cannot hold a singleton value in Slice 1" gname));
          if type_mentions_linear t then
            raise (TypeError (gloc, Printf.sprintf
              "global '%s' cannot hold a linear value: it would escape \
               obligation tracking (OWNERSHIP_KERNEL.md Stage 3 will lift this)"
              gname));
          if type_mentions_tuple t then
            raise (TypeError (gloc, Printf.sprintf
              "global '%s' cannot hold a tuple: tuples are values, not \
               storage (OWNERSHIP_KERNEL.md 5.9)" gname));
          validate_nonparam_type gloc t) ty;
        Option.iter validate_expr_types init
    | Ast.StructDef (sname, fields, _, _, _, sloc) ->
        validation_static_scope := None;
        allow_implicit_static := false;
        List.iter (fun (fname, ty) ->
          if type_mentions_view ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold an erased view" sname fname));
          if type_mentions_kinded_variant ty then begin
            if not (is_stable_owner_field sname fname) then
              raise (TypeError (sloc, Printf.sprintf
                "struct field '%s.%s' cannot hold an affine/linear variant; stable owner storage requires a private linear variant field"
                sname fname));
            let variant_name = match resolve_declared_type ty with
              | Ast.TypeVariant name -> name
              | _ -> raise (TypeError (sloc,
                  "stable owner storage must directly hold a linear variant"))
            in
            (match Hashtbl.find_opt variant_defs variant_name with
             | Some ((_, None) :: _) -> ()
             | _ -> raise (TypeError (sloc, Printf.sprintf
                 "stable owner variant '%s' must declare a payload-free empty case first for zero initialization"
                 variant_name)))
          end;
          if ast_contains_stable_owner_value ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot contain stable owner storage '%s'"
              sname fname (Ast.show_type_expr ty)));
          if type_mentions_indexed_owner ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold an indexed owner" sname fname));
          if type_mentions_singleton ty then
            raise (TypeError (sloc, Printf.sprintf
              "ordinary struct field '%s.%s' cannot hold a singleton value in Slice 1"
              sname fname));
          if type_mentions_linear ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a linear value: it would \
               escape obligation tracking (OWNERSHIP_KERNEL.md Stage 3 will \
               lift this)" sname fname));
          if type_mentions_tuple ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a tuple: tuples are values, \
               not storage (OWNERSHIP_KERNEL.md 5.9)" sname fname));
          check_struct_field_pointer sname fname sloc ty;
          validate_nonparam_type sloc ty) fields
    | Ast.OwnedStructDef (sname, _, params, fields, _, _, _, _, sloc) ->
        let scope = Hashtbl.create 8 in
        List.iter (fun (name, sort) ->
          validate_static_sort sloc sort;
          if Hashtbl.mem scope name then
            raise (TypeError (sloc, Printf.sprintf
              "duplicate static parameter '%s' on struct '%s'" name sname));
          Hashtbl.add scope name sort
        ) params;
        validation_static_scope := Some scope;
        allow_implicit_static := false;
        List.iter (fun (fname, ty) ->
          if ast_contains_stable_owner_value ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot contain stable owner storage '%s'"
              sname fname (Ast.show_type_expr ty)));
          if type_mentions_view ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a nested erased view"
              sname fname));
          if type_mentions_variant ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a nested variant"
              sname fname));
          if type_mentions_indexed_owner ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a nested indexed owner"
              sname fname));
          if type_mentions_linear ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a nested linear value"
              sname fname));
          if type_mentions_tuple ty then
            raise (TypeError (sloc, Printf.sprintf
              "struct field '%s.%s' cannot hold a tuple" sname fname));
          if singleton_under_storage false ty then
            raise (TypeError (sloc, Printf.sprintf
              "indexed owner field '%s.%s' cannot nest a singleton inside storage"
              sname fname));
          check_struct_field_pointer sname fname sloc ty;
          validate_nonparam_type sloc ty) fields
    | Ast.VariantDef (vname, cases, _, vloc) ->
        if cases = [] then
          raise (TypeError (vloc, Printf.sprintf
            "variant '%s' must declare at least one case" vname));
        let seen = Hashtbl.create 8 in
        List.iter (fun (cname, payload) ->
          if Hashtbl.mem seen cname then
            raise (TypeError (vloc, Printf.sprintf
              "duplicate case '%s::%s'" vname cname));
          Hashtbl.add seen cname ();
          Option.iter (fun schema ->
            if ast_contains_stable_owner_value schema then
              raise (TypeError (vloc, Printf.sprintf
                "variant payload '%s::%s' cannot contain stable owner storage"
                vname cname));
            if contains_borrow schema then
              raise (TypeError (vloc, Printf.sprintf
                "variant payload '%s::%s' cannot contain borrow/sink"
                vname cname));
            if type_mentions_variant schema then
              raise (TypeError (vloc, Printf.sprintf
                "variant payload '%s::%s' cannot nest another variant in Slice 3"
                vname cname));
            let rec strip_exists = function
              | Ast.TypeExists (_, _, body) -> strip_exists body
              | body -> resolve_declared_type body
            in
            let runtime_schema = strip_exists schema
            in
            (match runtime_schema with
             | Ast.TypeNamed name
               when StringSet.mem name concrete_struct_names
                    && Hashtbl.mem indexed_struct_kinds name ->
                 raise (TypeError (vloc, Printf.sprintf
                   "variant payload '%s::%s' cannot be an indexed owner struct; aggregate owner transfer is not implemented"
                   vname cname))
             | Ast.TypeNamed name
               when StringMap.mem name ordinary_struct_fields
                    && payload_kind runtime_schema <> Ast.KindPlain ->
                 raise (TypeError (vloc, Printf.sprintf
                   "variant payload '%s::%s' concrete struct must be unrestricted; nested affine/linear ownership is not implemented"
                   vname cname))
             | Ast.TypeArray _ ->
                 raise (TypeError (vloc, Printf.sprintf
                   "variant payload '%s::%s' cannot be an array in Slice 3; pass a slice or pointer instead"
                   vname cname))
             | _ -> ());
            (match schema with
             | Ast.TypeExists _ ->
                 let scope = Hashtbl.create 8 in
                 let rec bind_all = function
                   | Ast.TypeExists (name, sort, body) ->
                       validate_static_sort vloc sort;
                       if Hashtbl.mem scope name then
                         raise (TypeError (vloc, Printf.sprintf
                           "duplicate existential '%s' in payload '%s::%s'"
                           name vname cname));
                       Hashtbl.add scope name sort;
                       bind_all body
                   | body -> body
                 in
                 let body = bind_all schema in
                 (match resolve_declared_type body with
                  | Ast.TypeIndexed _ | Ast.TypeView _ | Ast.TypeTuple _ -> ()
                  | _ -> raise (TypeError (vloc, Printf.sprintf
                      "existential payload '%s::%s' must package an indexed runtime owner, erased view, or tuple containing owners"
                      vname cname)));
                 validation_static_scope := Some scope;
                 allow_implicit_static := false;
                 validate_static_type vloc body;
                 validate_complete_type vloc false body
             | body ->
                 validation_static_scope := Some (Hashtbl.create 0);
                 allow_implicit_static := false;
                 validate_static_type vloc body;
                 validate_complete_type vloc false body)
          ) payload
        ) cases;
        validation_static_scope := None
    | Ast.ViewDef (vname, _, params, _, vloc) ->
        let seen = Hashtbl.create 8 in
        List.iter (fun (name, sort) ->
          validate_static_sort vloc sort;
          if Hashtbl.mem seen name then
            raise (TypeError (vloc, Printf.sprintf
              "duplicate static parameter '%s' on view '%s'" name vname));
          Hashtbl.add seen name ()
        ) params;
        validation_static_scope := None
    | Ast.VectorTableDef (entries, loc) ->
        (* GitHub issue #227 item 2: slot range/uniqueness/exhaustiveness are
           all checked here, against toplevel_names (built above, still in
           scope) for target existence and Target_info for how many slots
           this architecture actually defines -- an architecture fact, not
           a language one (see Target_info.vector_table_contract's own
           comment). Codegen (lib/llvm_gen.ml) trusts this pass completely:
           it never re-checks range/uniqueness/exhaustiveness itself. *)
        let slot_count = match Target_info.vector_table_contract () with
          | Target_info.Fixed_slots n -> n
          | Target_info.Unsupported ->
              raise (TypeError (loc,
                "vector_table is unavailable because the selected target has no exception vector table contract"))
        in
        let seen = Hashtbl.create slot_count in
        List.iter (fun (slot, target) ->
          if slot < 0 || slot >= slot_count then
            raise (TypeError (loc, Printf.sprintf
              "vector_table slot %d is out of range for this target (must be 0..<%d)"
              slot slot_count));
          if Hashtbl.mem seen slot then
            raise (TypeError (loc, Printf.sprintf
              "vector_table slot %d is listed more than once" slot));
          Hashtbl.add seen slot ();
          (match Hashtbl.find_opt toplevel_names target with
           | Some ("function" | "symbol") -> ()
           | Some other -> raise (TypeError (loc, Printf.sprintf
               "vector_table target '%s' is %s %s, not a function or extern symbol"
               target (article_for other) other))
           | None -> raise (TypeError (loc, Printf.sprintf
               "vector_table target '%s' is not defined" target)))
        ) entries;
        for slot = 0 to slot_count - 1 do
          if not (Hashtbl.mem seen slot) then
            raise (TypeError (loc, Printf.sprintf
              "vector_table is missing slot %d (every slot 0..<%d must be listed exactly once)"
              slot slot_count))
        done
    | Ast.ExceptionEntryDef (name, fields, loc) ->
        (* GitHub issue #227 item 1 (prototype slice): frame/dispatch/before
           are the only recognized keys. dispatch/before are only checked
           for EXISTENCE here (not signature) -- this prototype trusts the
           caller to match the real dispatch shape (`fn(usize) -> usize`)
           and before shape (`fn()`); fenv (which could check that) is not
           built until a later pass. Revisit if this graduates past
           prototype. *)
        let frame_name = ref None and dispatch_name = ref None
        and before_name = ref None in
        List.iter (fun (key, value) -> match key with
          | "frame" -> frame_name := Some value
          | "dispatch" -> dispatch_name := Some value
          | "before" -> before_name := Some value
          | other -> raise (TypeError (loc, Printf.sprintf
              "exception_entry '%s' has unknown key '%s' (expected frame, dispatch, or before)"
              name other))
        ) fields;
        let frame = match !frame_name with
          | Some f -> f
          | None -> raise (TypeError (loc, Printf.sprintf
              "exception_entry '%s' is missing required key 'frame'" name))
        in
        let dispatch = match !dispatch_name with
          | Some d -> d
          | None -> raise (TypeError (loc, Printf.sprintf
              "exception_entry '%s' is missing required key 'dispatch'" name))
        in
        let check_fn_target key target = match Hashtbl.find_opt toplevel_names target with
          | Some "function" -> ()
          | Some other -> raise (TypeError (loc, Printf.sprintf
              "exception_entry '%s' %s target '%s' is %s %s, not a function"
              name key target (article_for other) other))
          | None -> raise (TypeError (loc, Printf.sprintf
              "exception_entry '%s' %s target '%s' is not defined" name key target))
        in
        check_fn_target "dispatch" dispatch;
        Option.iter (check_fn_target "before") !before_name;
        validate_exception_frame "exception_entry" name loc frame
    | Ast.ExceptionRestoreDef (name, fields, loc) ->
        let frame_name = ref None in
        List.iter (fun (key, value) -> match key with
          | "frame" -> frame_name := Some value
          | other -> raise (TypeError (loc, Printf.sprintf
              "exception_restore '%s' has unknown key '%s' (expected frame)"
              name other))
        ) fields;
        let frame = match !frame_name with
          | Some f -> f
          | None -> raise (TypeError (loc, Printf.sprintf
              "exception_restore '%s' is missing required key 'frame'" name))
        in
        validate_exception_frame "exception_restore" name loc frame
    | Ast.OpaqueStructDef _ | Ast.EnumDef _ | Ast.UseDef _
    | Ast.GenericStructDef _ | Ast.ExternSymbolDef _ -> ()) prog;
    (* GenericStructDef (GitHub issue #207): nothing to validate here yet
       -- its fields reference an unresolved type parameter, not a real
       type. Monomorphize.run (once it exists) is the only pass that ever
       elaborates one, producing an ordinary StructDef per concrete
       instantiation that this same validation then runs on normally. *)
  (* Pass 0: collect struct and enum definitions *)
  let senv = List.fold_left (fun m -> function
    | Ast.StructDef (name, fields, is_packed, align_opt, _, _) ->
        StringMap.add name (fields, is_packed, align_opt) m
    | Ast.OwnedStructDef (name, _, _, fields, is_packed, align_opt, _, _, _) ->
        StringMap.add name (fields, is_packed, align_opt) m
    | _ -> m
  ) StringMap.empty prog in
  let eenv = List.fold_left (fun m -> function
    | Ast.EnumDef (name, ty_opt, variants, is_ne) ->
        let underlying = match ty_opt with Some t -> t | None -> Ast.TypeU32 in
        let (_, resolved) = List.fold_left (fun (next, acc) (vname, vopt) ->
          let v = match vopt with Some v -> v | None -> next in
          (v + 1, acc @ [(vname, v)])
        ) (0, []) variants in
        StringMap.add name (underlying, resolved, is_ne) m
    | _ -> m
  ) StringMap.empty prog in
  (* Pass 1: collect function signatures *)
  (* Builtin names are reserved: infer_expr's Call case dispatches on them
     BEFORE consulting fenv, so a same-named user/extern function would be
     silently unreachable -- reject the definition instead. *)
  let check_reserved_fn loc name =
    if is_compiler_builtin name then
      raise (TypeError (loc,
        Printf.sprintf "'%s' is a compiler builtin and cannot be redefined" name))
  in
  let rec erase_static_for_abi = function
    | Ast.TypeSingleton (t, _) -> erase_static_for_abi t
    | Ast.TypeIndexed (name, _) -> Ast.TypeNamed name
    | Ast.TypePtr t -> Ast.TypePtr (erase_static_for_abi t)
    | Ast.TypeIo t -> Ast.TypeIo (erase_static_for_abi t)
    | Ast.TypeArray (t, n) -> Ast.TypeArray (erase_static_for_abi t, n)
    | Ast.TypeSlice (t, n) -> Ast.TypeSlice (erase_static_for_abi t, n)
    | Ast.TypeBorrow t -> Ast.TypeBorrow (erase_static_for_abi t)
    | Ast.TypeBorrowMut t -> Ast.TypeBorrowMut (erase_static_for_abi t)
    | Ast.TypeSink t -> Ast.TypeSink (erase_static_for_abi t)
    | Ast.TypeAlignedPtr (n, t) -> Ast.TypeAlignedPtr (n, erase_static_for_abi t)
    | Ast.TypeFn (args, ret, effects) ->
        Ast.TypeFn
          (List.map erase_static_for_abi args, erase_static_for_abi ret, effects)
    | Ast.TypeTuple ts -> Ast.TypeTuple (List.map erase_static_for_abi ts)
    | Ast.TypeRefined (lo, hi, base) ->
        Ast.TypeRefined (lo, hi, erase_static_for_abi base)
    | Ast.TypeExists (_, _, body) -> erase_static_for_abi body
    | t -> t
  in
  let type_code t =
    let t = erase_static_for_abi t in
    match t with
    | Ast.TypeBool -> "bool"
    | Ast.TypeI8 -> "i8" | Ast.TypeI16 -> "i16" | Ast.TypeI32 -> "i32" | Ast.TypeI64 -> "i64"
    | Ast.TypeU8 -> "u8" | Ast.TypeU16 -> "u16" | Ast.TypeU32 -> "u32" | Ast.TypeU64 -> "u64"
    | Ast.TypeIsize -> "isize" | Ast.TypeUsize -> "usize" | Ast.TypeVoid -> "void"
    | _ ->
        let source = Types.to_string (Types.of_ast t) in
        let b = Buffer.create (1 + String.length source * 2) in
        Buffer.add_char b 'x';
        String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) source;
        Buffer.contents b
  in
  let add_signature m name params =
        let signature = String.concat "_" (List.map (fun (_, t) ->
          match t with Some t -> type_code t | None -> "?") params) in
        let old = Option.value (StringMap.find_opt name m) ~default:StringSet.empty in
        StringMap.add name (StringSet.add signature old) m
  in
  let signatures = List.fold_left (fun m -> function
    | Ast.FuncDef f -> add_signature m f.name f.params
    | Ast.ExternFuncDef (name, params, _, _) -> add_signature m name params
    | _ -> m
  ) StringMap.empty prog in
  let fn_counts = StringMap.map StringSet.cardinal signatures in
  let fn_occurrences = List.fold_left (fun m -> function
    | Ast.FuncDef f ->
        StringMap.add f.name (1 + Option.value (StringMap.find_opt f.name m) ~default:0) m
    | Ast.ExternFuncDef (name, _, _, _) ->
        StringMap.add name (1 + Option.value (StringMap.find_opt name m) ~default:0) m
    | _ -> m
  ) StringMap.empty prog in
  let overload_key name params =
    if Option.value (StringMap.find_opt name fn_counts) ~default:0 <= 1 then name
    else begin
      if List.exists (fun (_, t) -> t = None) params then
        raise (TypeError (Lexing.dummy_pos, Printf.sprintf
          "overloaded function '%s' requires explicit parameter types" name));
      "_TK_" ^ name ^ "__" ^ String.concat "_" (List.map (fun (_, t) ->
        type_code (Option.get t)) params)
    end
  in
  let definition_files : (string, string) Hashtbl.t = Hashtbl.create 32 in
  let register_definition loc key name =
    let file = loc.Lexing.pos_fname in
    match Hashtbl.find_opt definition_files key with
    | Some previous ->
        (* Cross-file duplicates are rejected too, not just same-file ones
           (GitHub issue #79 follow-up): two `.tkb` files defining the exact
           same signature under the same overload key used to compile
           silently, with llvm_gen.ml's declare_func/gen_func pair (Pass 1
           registers only the FIRST FuncDef's llvalue per key; Pass 2 then
           calls gen_func on EVERY FuncDef with that key, appending a second,
           unreachable "entry" block onto the SAME llvalue) making whichever
           definition happened to come first in file-concatenation order the
           one that silently wins, with the other's body silently dead-coded
           -- no verifier error, no warning, correct only by accident of
           `use`/Makefile ordering. Found via examples/irq/irq.tkb's shared
           dispatch pattern: examples/common_qemu/gic.tkb and
           examples/common_stm32/nvic.tkb both had to be present in the same
           STM32 build (the former only for a dead-on-STM32 type reference,
           see gic.tkb's own header comment) and both defined
           irq_uart_rx_setup/irq_uart_rx_unmask with the identical
           signature -- previously silent, now a compile error pointing at
           both locations. *)
        if previous = file then
          raise (TypeError (loc, Printf.sprintf "duplicate overload '%s'" name))
        else
          raise (TypeError (loc, Printf.sprintf
            "duplicate definition of '%s': already defined in %s" name previous))
    | None -> Hashtbl.replace definition_files key file
  in
  let fenv = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        check_reserved_fn fdef.def_loc fdef.name;
        let scope = create_static_scope () in
        let pts = List.map (fun (_, t) -> of_ast_opt_in_decl_scope scope t) fdef.params in
        let rt  = ret_of_ast_opt_in_decl_scope scope fdef.ret_type in
        let key = overload_key fdef.name fdef.params in
        register_definition fdef.def_loc key fdef.name;
        let old = Option.value (StringMap.find_opt fdef.name m) ~default:[] in
        let old = List.filter (fun (k, _) -> k <> key) old in
        let call_effects = Option.map (fun effects ->
          List.filter (fun eff ->
            eff = "may_block" || eff = "unsafe") effects)
          fdef.effects in
        StringMap.add fdef.name ((key, TFun (pts, rt, call_effects)) :: old) m
    | Ast.ExternFuncDef (name, params, ret_ty, effects_for_extern) ->
        check_reserved_fn Lexing.dummy_pos name;
        if Option.value (StringMap.find_opt name fn_occurrences) ~default:0 > 1 then
          raise (TypeError (Lexing.dummy_pos, Printf.sprintf
            "extern function '%s' cannot be overloaded" name));
        let scope = create_static_scope () in
        let pts = List.map (fun (_, t) -> of_ast_opt_in_decl_scope scope t) params in
        let rt  = ret_of_ast_opt_in_decl_scope scope ret_ty in
        let key = overload_key name params in
        register_definition Lexing.dummy_pos key name;
        let old = Option.value (StringMap.find_opt name m) ~default:[] in
        let old = List.filter (fun (k, _) -> k <> key) old in
        let call_effects = match effects_for_extern with
          | None -> Some []
          | Some effects ->
              Some (List.filter (fun eff ->
                eff = "may_block" || eff = "unsafe") effects)
        in
        StringMap.add name ((key, TFun (pts, rt, call_effects)) :: old) m
    | Ast.ConstDef _ -> m
    | Ast.LetDef _    -> m
    | Ast.ExternSymbolDef _ -> m
    | Ast.StructDef _ -> m
    | Ast.OwnedStructDef _ -> m
    | Ast.OpaqueStructDef _ -> m
    | Ast.ViewDef _ -> m
    | Ast.EnumDef _   -> m
    | Ast.VariantDef _ -> m
    | Ast.UseDef _    -> m
    | Ast.VectorTableDef _ -> m
    | Ast.ExceptionEntryDef _ -> m
    | Ast.ExceptionRestoreDef _ -> m
    | Ast.GenericStructDef _ -> m
    (* GenericStructDef (GitHub issue #207): contributes no function
       signature until an instantiation exists as an ordinary FuncDef,
       produced by Monomorphize.run. *)
  ) StringMap.empty prog in
  (* GitHub issue #227 item 1 follow-up: exception_entry's dispatch/before
     targets are checked for EXISTENCE in the earlier pass (before fenv
     exists yet), but not for having the right signature -- that earlier
     pass runs before fenv is built, and fenv cannot easily move earlier
     since function signatures can themselves reference struct/enum names
     that senv/eenv (built between the two passes) resolve. A second,
     narrow pass here, now that fenv exists, closes that gap: dispatch
     must be exactly `fn(usize) -> usize` (the frame's own address in,
     the frame address to resume from out -- unchanged from the
     hand-written convention this replaces), before must be exactly
     `fn()`/`fn() -> void`. An overloaded name is rejected outright: which
     overload a raw `bl` reaches is not overload resolution, it is
     whatever the linker finds, so a name with more than one signature is
     inherently ambiguous here regardless of which one might happen to
     match. *)
  let check_exception_entry_target_signature loc entry_name key target
      ~want_params ~want_ret =
    match StringMap.find_opt target fenv with
    | None -> raise (TypeError (loc, Printf.sprintf
        "exception_entry '%s' %s target '%s' is not defined" entry_name key target))
    | Some [(_, TFun (pts, rt, _))] ->
        if pts <> want_params || rt <> want_ret then
          raise (TypeError (loc, Printf.sprintf
            "exception_entry '%s' %s target '%s' has the wrong signature (expected %s)"
            entry_name key target
            (match key with
             | "dispatch" -> "fn(usize) -> usize"
             | _ -> "fn()")))
    | Some _ -> raise (TypeError (loc, Printf.sprintf
        "exception_entry '%s' %s target '%s' is overloaded, which a raw branch cannot resolve"
        entry_name key target))
  in
  List.iter (function
    | Ast.ExceptionEntryDef (entry_name, fields, loc) ->
        List.iter (fun (key, target) -> match key with
          | "dispatch" ->
              check_exception_entry_target_signature loc entry_name "dispatch" target
                ~want_params:[TUsize] ~want_ret:TUsize
          | "before" ->
              check_exception_entry_target_signature loc entry_name "before" target
                ~want_params:[] ~want_ret:TVoid
          | _ -> ()
        ) fields
    | _ -> ()
  ) prog;
  (* Global mutability: plain `let` = immutable compile-time constant, `let mut` = variable.
     Reuses the same tyenv-based mutability check as local variables (Assign/AddrOf).
     GitHub issue #79 follow-up: duplicate/cross-kind global names are
     already rejected by claim_toplevel_name above (a single pass over
     the whole program, run before this fold), so this fold itself no
     longer needs its own duplicate guard -- by the time it runs, every
     name reaching here is already known unique across the whole
     program. *)
  let genv = List.fold_left (fun m -> function
    | Ast.ConstDef (name, ty, _, _) ->
        StringMap.add name (of_ast ty, false) m
    | Ast.LetDef (name, ty_opt, _, _, is_mutable, _, _) ->
        StringMap.add name (of_ast_opt ty_opt, is_mutable) m
    | Ast.ExternSymbolDef (name, _) ->
        (* Address-only: the bare name resolves to its own address, always
           usize, never load-through. Not writable. *)
        StringMap.add name (of_ast Ast.TypeUsize, false) m
    | Ast.FuncDef _                -> m
    | Ast.ExternFuncDef _          -> m
    | Ast.StructDef _              -> m
    | Ast.OwnedStructDef _         -> m
    | Ast.OpaqueStructDef _        -> m
    | Ast.ViewDef _                -> m
    | Ast.EnumDef _                -> m
    | Ast.VariantDef _             -> m
    | Ast.UseDef _                 -> m
    | Ast.VectorTableDef _         -> m
    | Ast.ExceptionEntryDef _      -> m
    | Ast.ExceptionRestoreDef _     -> m
    | Ast.GenericStructDef _       -> m
  ) StringMap.empty prog in
  (* Pass 2: check global initializers.
     GitHub issue #77: a plain List.iter used to be enough here, since no
     global initializer had ever needed to change genv's own STORED type
     for that global -- but sizeof/offsetof's new refined-singleton types
     (see the SizeOf/OffsetOf cases above) mean an immutable global's
     initializer can now be genuinely MORE REFINED than its own bare
     annotation (e.g. `let ETH_DST: usize = offsetof(EthHdr, dst);`).
     Mirroring local lets' `bind_ty` ("proofs are only lost at mutation
     points, never at annotation" -- see that comment), this global's
     entry in genv is upgraded to the refined type when the annotation's
     type exactly matches the refined value's own base, so every LATER
     consumer of genv sees it -- Pass 3 function bodies referencing this
     global by name (this is what actually lets e.g. arp_reply.tkb's
     `ip[IP_SRC..<IP_DST]` prove statically), and program_types.globals
     below. Now a List.fold_left threading an updated genv forward
     (instead of a plain List.iter) for exactly this reason. *)
  let genv = List.fold_left (fun genv item -> match item with
    | Ast.ConstDef (name, _, expr, _) ->
        let (ty, _) = StringMap.find name genv in
        let et = infer_expr senv eenv genv fenv expr in
        (try unify et (strip_io ty)
         with Unify_error m -> raise (TypeError (expr.loc, m)));
        check_literal_fits_refined expr.loc expr (strip_io ty);
        genv
    | Ast.LetDef (name, _, expr_opt, _, is_mutable, _, _) ->
        let (ty, _) = StringMap.find name genv in
        (match expr_opt with
         | None ->
             if not is_mutable then
               raise (TypeError (Lexing.dummy_pos,
                 Printf.sprintf "immutable global '%s' must have an initializer; use 'let mut' for uninitialized globals" name));
             genv
         | Some { desc = Ast.StructLit exprs; loc } ->
             (match repr ty with
              | (TStruct _ | TArray _) as expected ->
                  ignore (check_expr senv eenv genv fenv { desc = Ast.StructLit exprs; loc } expected)
              | _ -> raise (TypeError (loc,
                  "literal { ... } requires a struct or array type annotation")));
             genv
         | Some { desc = Ast.EmbedFile path; loc } ->
             (* GitHub issue #230: bypass infer_expr entirely (its own
                EmbedFile case unconditionally rejects it -- see that
                case's own comment) since this is the one position it is
                actually valid in. Reads the file here only to determine
                its byte length; llvm_gen.ml's gen_global re-reads it for
                the actual bytes (this module has no LLVM dependency to
                build a constant with, and does not need one just to learn
                a length). unify (not a forced check) means an explicit
                annotation is still allowed and gets verified naturally --
                `let x: [u8; 100] = embed_file(...)` where the real file
                is a different size is a normal unify TypeError, not a
                special case -- while the common unannotated `let x =
                embed_file(...)` binds the fresh type variable Pass 0
                gave `x` in genv to the real size, exactly like ConstDef's
                own unify call just above does for its own initializer. *)
             let n =
               try
                 let ic = open_in_bin path in
                 let len = in_channel_length ic in
                 close_in ic;
                 len
               with Sys_error msg -> raise (TypeError (loc, Printf.sprintf
                 "embed_file(\"%s\"): %s" path msg))
             in
             (try unify (TArray (TU8, n)) (strip_io ty)
              with Unify_error m -> raise (TypeError (loc, m)));
             genv
         | Some { desc = Ast.Var vname; loc } ->
             (* Bypass infer_expr's ordinary Var case here: it decays array
                types to a pointer (the right behavior for array VALUES used
                as ordinary expressions, e.g. passed to a function), but a
                global referencing another global by name means "copy that
                global's value" -- unifying against the decayed pointer type
                would reject `let B: [u8;4] = A;` even though it is exactly
                what array-typed global aliasing should allow. Looking the
                name up in genv directly (raw, undecayed type) and unifying
                against that instead fixes arrays/structs while leaving
                scalar references (which never decayed anyway) unaffected. *)
             (match StringMap.find_opt vname genv with
              | Some (vty, _) ->
                  (* GitHub issue #77: actual (referenced global's own
                     type) first, declared annotation second -- see the
                     comment on the plain-expression case just below for
                     why argument order matters here, not just style. *)
                  (try unify (strip_io vty) (strip_io ty)
                   with Unify_error m -> raise (TypeError (loc, m)));
                  (* Same bind_ty upgrade as the plain-expression case:
                     `let B: usize = A;` where A is itself refined should
                     let B inherit that range too. *)
                  let bind_ty =
                    if is_mutable then ty
                    else match repr ty, repr (strip_io vty) with
                      | t_ann, (TRefinedInt (_, _, base) as r) when t_ann = repr base -> r
                      | _ -> ty
                  in
                  if bind_ty == ty then genv
                  else StringMap.add name (bind_ty, is_mutable) genv
              | None ->
                  raise (TypeError (loc, Printf.sprintf "Unbound variable: %s" vname)))
         | Some e ->
             let et = infer_expr senv eenv genv fenv e in
             if contains_view_ty et then
               raise (TypeError (e.loc, Printf.sprintf
                 "global '%s' cannot hold an erased view" name));
             if contains_variant_ty et then
               raise (TypeError (e.loc, Printf.sprintf
                 "global '%s' cannot hold a variant in Slice 3" name));
             (* GitHub issue #77: `unify et (strip_io ty)` -- actual
                (initializer) type first, declared annotation second --
                matching the "actual, expected" convention every other
                unify/unify_at call site in this file already uses (e.g.
                unify_at e2.loc t2 TIsize). This file's global-initializer
                check previously called `unify (strip_io ty) et` (backwards:
                declared FIRST), which was never noticed because no global
                initializer had ever produced a genuinely MORE REFINED type
                than its own bare annotation before now: `unify TUsize
                (TRefinedInt (v, v+1, TUsize))` hits unify's anti-subtyping
                guard (`t1, TRefinedInt (lo, hi, base) when t1 = repr
                base`), which exists to reject an UNPROVEN base-typed value
                flowing into a position that demands the refined type --
                backwards from what is actually happening here (a PROVEN
                refined value flowing into a weaker plain-type annotation,
                which every TRefinedInt-into-base-type subtyping rule
                already allows once the arguments are the right way
                round). *)
             (try unify et (strip_io ty)
              with Unify_error m -> raise (TypeError (e.loc, m)));
             check_literal_fits_refined e.loc e (strip_io ty);
             check_io_ptr_literal_needs_unsafe e.loc e (strip_io ty);
             (* Mirrors local lets' bind_ty exactly (see that comment) --
                this is the piece that actually matters for issue #77: not
                just "does this type-check" but "does the global keep the
                proof for later use". *)
             let bind_ty =
               if is_mutable then ty
               else match repr ty, repr et with
                 | t_ann, (TRefinedInt (_, _, base) as r) when t_ann = repr base -> r
                 | _ -> ty
             in
             if bind_ty == ty then genv
             else StringMap.add name (bind_ty, is_mutable) genv)
    | _ -> genv
  ) genv prog in
  (* Preserve source-level parameter modes for call-site checks. Ordinary
     HM types intentionally erase borrow/sink wrappers, but `borrow mut`
     still needs the caller's place mutability and exclusivity checked. *)
  function_param_modes := List.fold_left (fun modes -> function
    | Ast.FuncDef f ->
        StringMap.add (overload_key f.name f.params) (List.map snd f.params) modes
    | Ast.ExternFuncDef (name, params, _, _) ->
        StringMap.add (overload_key name params) (List.map snd params) modes
    | _ -> modes
  ) StringMap.empty prog;
  (* Pass 3: infer function bodies.
     GitHub issue #327 Stage 1: each FuncDef's own infer_func call is fully
     self-contained here -- senv/eenv/fenv/genv are all closed-over/fixed
     for the whole fold, and no function's success or failure changes what
     any OTHER function in this same fold sees. That makes this the safe
     place to stop letting one broken function abort every function after
     it: a TypeError from one FuncDef is recorded and the fold moves on to
     the next one, so a single `main.exe` invocation can surface every
     independently-broken function in one pass (this is the concrete
     scenario the issue was filed over: dozens of *io cast sites across a
     40-file migration, each needing its own rebuild to discover under the
     old raise-on-first-error behavior). A function whose body fails to
     type-check gets no entry in `functions` at all; a call site elsewhere
     that depends on it will surface its own (possibly-cascading, expected
     per the issue's own Stage 2 scoping) error rather than silently using
     a placeholder. If anything was recorded, MultiTypeError is raised here
     -- before Pass 4's affine/linear checking, which assumes every
     function in `functions` type-checked cleanly -- reporting every
     collected error together instead of just the first. *)
  let functions = List.fold_left (fun m -> function
    | Ast.FuncDef fdef ->
        let key = overload_key fdef.name fdef.params in
        (try StringMap.add key (infer_func senv eenv fenv genv fdef) m
         with Types.TypeError (loc, msg) ->
           collected_type_errors := (loc, msg) :: !collected_type_errors;
           (* unsafe_depth is deliberately not exception-safe within a
              single infer_func call (see its own Unsafe/UnsafeBlock case
              comments: "a TypeError aborts this compilation, and
              infer_program resets the counter") -- true before this Stage
              1 change made this fold catch-and-continue rather than
              letting the first exception abort infer_program outright. A
              function that raised while unsafe_depth was > 0 would
              otherwise leak that non-zero depth into every function
              checked AFTER it in this same fold, silently authorizing
              their unrelated unsafe-gated casts as if they were inside an
              unsafe block they never wrote. Reset here restores the
              "every function starts outside any unsafe scope" invariant
              that was implicitly true before this fold could continue
              past a failure. GitHub issue #328's type_checker_lint_active
              is the same class of non-exception-safe flag (its own
              save/restore only runs on UnsafeBlock's normal exit path),
              so it needs the same reset here for the same reason. *)
           unsafe_depth := 0;
           type_checker_lint_active := false;
           m)
    | _ -> m
  ) StringMap.empty prog in
  (* Exactly one error behaves exactly as before (a plain TypeError, not
     wrapped) -- every existing caller/test that pattern-matches on
     Types.TypeError specifically (the overwhelmingly common case: one
     broken function) keeps working unchanged. MultiTypeError is only used
     when there is genuinely more than one to report, which is the only
     case where anything needs to change. *)
  (match List.rev !collected_type_errors with
   | [] -> ()
   | [(loc, msg)] -> raise (Types.TypeError (loc, msg))
   | errors -> raise (Types.MultiTypeError errors));
  (* Function-local affine/linear checking for kinded values.
     struct` / `linear opaque struct`. This deliberately stops short of a
     general ownership system: values are tracked per named local within a
     single function. `borrow T` is parameter-only and makes calls through
     that parameter non-consuming. `sink T` is also parameter-only and DOES
     consume at the call site (like a plain owning parameter), but marks
     the callee as this value's designated terminal consumer -- see
     check_affine_func's parameter-consumption check below for why plain
     owning parameters need this counterpart (GitHub issue #89: a purely
     syntactic "was this parameter forwarded" check cannot tell a genuine
     release function apart from an accidental no-op that silently drops
     the handle -- `sink` makes that distinction an explicit declaration).

     AFFINE: use at most once and may be dropped (standard weakening).
     LINEAR (OWNERSHIP_KERNEL.md Stage 1, GitHub issue #117): use exactly
     once on EVERY path (intersection semantics). Additional linear-only
     rules enforced here: reassignment over a live obligation is rejected;
     a pending obligation at return/break/continue is rejected (affine's
     union check silently accepts leak-on-early-exit; linear cannot);
     uninitialized `let` of a linear local is rejected. The cast-away ban
     and the storage bans (fields/slots/globals) live in infer_expr/
     infer_stmt where full types are available, not in this walk.

     MUST_USE VARIANT (GitHub issue #150): the same exactly-once, all-path
     flow obligation applies to handling or transferring the result, but it
     is a checker policy rather than a claim that the value owns a linear
     runtime resource. Its payload-derived kind and ABI remain unchanged.

     All tracked policies share one walk carrying a `consume_sets` value. Its
     maybe-consumed component is unioned at merges (governing double-use
     for both kinds), while its must-be-consumed component is intersected
     (governing linear discharge on every path). *)
  let rec strip_borrow = function
    | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t -> strip_borrow t
    | t -> t
  in
  let rec is_affine_type ty = match strip_borrow ty with
    | Ast.TypePtr (Ast.TypeNamed name) -> StringSet.mem name affine_names
    | Ast.TypeIndexed (name, _) -> StringSet.mem name affine_names
    | Ast.TypeNamed name | Ast.TypeView (name, _) | Ast.TypeVariant name ->
        Hashtbl.find_opt view_kinds name = Some Ast.KindAffine
        || Hashtbl.find_opt variant_kinds name = Some Ast.KindAffine
    | Ast.TypeTuple ts -> List.exists is_affine_type ts
    (* An existential (GitHub issue #183's follow-up) hides its index, not
       its ownership kind: `exists page. PageOwner[page]` still owns the
       SAME single-use resource `PageOwner[N]` would for a known N, so it
       must stay just as tracked -- otherwise a LetMatch-bound existential
       local would silently escape all affine/linear/must-use obligation
       checking the moment its type stopped being written out concretely. *)
    | Ast.TypeExists (_, _, body) -> is_affine_type body
    | _ -> false
  in
  let rec is_linear_type ty = match strip_borrow ty with
    | Ast.TypePtr (Ast.TypeNamed name) -> StringSet.mem name linear_names
    | Ast.TypeIndexed (name, _) -> StringSet.mem name linear_names
    | Ast.TypeNamed name | Ast.TypeView (name, _) | Ast.TypeVariant name ->
        Hashtbl.find_opt view_kinds name = Some Ast.KindLinear
        || Hashtbl.find_opt variant_kinds name = Some Ast.KindLinear
    | Ast.TypeTuple ts -> List.exists is_linear_type ts
    | Ast.TypeExists (_, _, body) -> is_linear_type body
    | _ -> false
  in
  let rec is_must_use_type ty = match strip_borrow ty with
    | Ast.TypeNamed name | Ast.TypeVariant name ->
        Hashtbl.mem must_use_variants name
    | Ast.TypeTuple ts -> List.exists is_must_use_type ts
    | Ast.TypeExists (_, _, body) -> is_must_use_type body
    | _ -> false
  in
  let is_tracked_type ty =
    is_affine_type ty || is_linear_type ty || is_must_use_type ty in
  let call_params = List.fold_left (fun m -> function
    | Ast.FuncDef f ->
        StringMap.add (overload_key f.name f.params) (List.map snd f.params) m
    | Ast.ExternFuncDef (name, params, _, _) -> StringMap.add name (List.map snd params) m
    | _ -> m
  ) StringMap.empty prog in
  let call_returns = List.fold_left (fun m -> function
    | Ast.FuncDef f ->
        let key = overload_key f.name f.params in
        let ret = (StringMap.find key functions).ret_type in
        StringMap.add key ret m
    | Ast.ExternFuncDef (name, _, ret, _) ->
        StringMap.add name (Option.value ret ~default:Ast.TypeVoid) m
    | _ -> m
  ) StringMap.empty prog in
  (* Authority-derived region returns (issues #106/#128): function key ->
     matching parameter indices plus returned value kind. Same overload_key
     keying as call_params, resolved per call site through
     resolved_call_targets, so overloads cannot mismatch. Declaration
     validation already guaranteed that the named static index belongs to a
     borrowed indexed owner/view. *)
  let region_return_info = List.fold_left (fun m -> function
    | Ast.FuncDef f ->
        (match f.ret_type with
         | Some ret ->
             (match region_return_annotation ret with
              | Some (_, Ast.StaticName n, kind) ->
                  let authority_indices = ref [] in
                  List.iteri (fun i (_, ty) -> match ty with
                    | Some (Ast.TypeBorrow (Ast.TypeIndexed (_, args)))
                    | Some (Ast.TypeBorrowMut (Ast.TypeIndexed (_, args))) ->
                        if List.mem (Ast.StaticName n) args then
                          authority_indices := i :: !authority_indices
                    | _ -> ()
                  ) f.params;
                  (match List.rev !authority_indices with
                   | _ :: _ as indices ->
                       StringMap.add (overload_key f.name f.params)
                         (indices, kind) m
                   | [] -> m)
              | _ -> m)
         | _ -> m)
    | _ -> m
  ) StringMap.empty prog in
  let noreturn_functions = List.fold_left (fun names -> function
    | Ast.ExternFuncDef (name, _, _, Some effects)
      when List.mem "noreturn" effects -> StringSet.add name names
    | _ -> names
  ) StringSet.empty prog in
  let check_affine_func fdef =
    let finfo = StringMap.find (overload_key fdef.Ast.name fdef.params) functions in
    let var_types = ref finfo.local_types in
    List.iter2 (fun (name, _) (_, ty) ->
      var_types := StringMap.add name ty !var_types
    ) fdef.params finfo.param_types;
    let param_names = List.fold_left (fun names (name, _) ->
      StringSet.add name names) StringSet.empty fdef.params in
    let is_stack_local name =
      StringMap.mem name !var_types && not (StringSet.mem name param_names)
    in
    let var_kind name = match StringMap.find_opt name !var_types with
      | Some ty when is_linear_type ty -> Some Ast.KindLinear
      | Some ty when is_must_use_type ty -> Some Ast.KindLinear
      | Some ty when is_affine_type ty -> Some Ast.KindAffine
      | _ -> None
    in
    (* OWNERSHIP_KERNEL.md Stage 3a (GitHub issue #89 Hurdle 3): a field
       access `h.t` through a bare local/parameter `h` is trackable the
       SAME way `h` itself is, when `h`'s own type is a struct (not
       itself an affine/linear handle -- a handle's own pointee has no
       fields reachable from takibi source, `opaque` forbids that) and
       field `t` has an AFFINE pointer type. LINEAR fields stay banned at
       the declaration level (validate_nonparam_type's linear_inside_container/
       type_mentions_linear checks, unchanged) -- extending linear's
       stronger all-paths guarantee through fields needs a form of
       definite-assignment analysis for partially-consumed structs, a
       materially bigger step reserved for a future increment once a
       concrete need for it shows up (the same "prove it with a real
       driver first" discipline every other stage here has followed).
       This function is intentionally the ONLY place struct field types
       get read for kind purposes -- no interprocedural reasoning, no
       aliasing between two different local variables of the same struct
       type (each `path` is keyed by the LOCAL NAME, not a resolved
       address, so `h1.t` and `h2.t` are always distinct paths even if
       they happened to alias at runtime through pointers -- a real but
       narrow gap, honestly the same shape as Stage 1's affine
       restriction to named locals, not solved here). *)
    let field_affine_type base_name fname =
      match StringMap.find_opt base_name !var_types with
      | None -> None
      | Some base_ty ->
          let sname = match strip_borrow base_ty with
            | Ast.TypeNamed s -> Some s
            | Ast.TypePtr (Ast.TypeNamed s) -> Some s
            | Ast.TypeIo (Ast.TypeNamed s) -> Some s
            | Ast.TypePtr (Ast.TypeIo (Ast.TypeNamed s)) -> Some s
            | _ -> None
          in
          (match sname with
           | None -> None
           | Some sname ->
               (match StringMap.find_opt sname senv with
                | None -> None
                | Some (fields, _, _) ->
                    (match List.assoc_opt fname fields with
                     | Some fty when is_affine_type fty -> Some fty
                     | _ -> None)))
    in
    let path_kind = function
      | PVar name -> var_kind name
      | PField (base, fname) ->
          (match field_affine_type base fname with
           | Some _ -> Some Ast.KindAffine
           | None -> None)
    in
    let is_tracked_path p = path_kind p <> None in
    let is_stack_origin = function
      | PVar name -> is_stack_local name && not (is_tracked_path (PVar name))
      | PField (name, _) ->
          is_stack_local name && not (is_tracked_path (PVar name))
    in
    let is_linear_path p = path_kind p = Some Ast.KindLinear in
    let is_must_use_path = function
      | PVar name ->
          (match StringMap.find_opt name !var_types with
           | Some ty -> is_must_use_type ty && not (is_linear_type ty)
           | None -> false)
      | PField _ -> false
    in
    let requires_all_paths p = is_linear_path p in
    let kind_word p =
      if is_must_use_path p then "must-use"
      else if is_linear_path p then "linear"
      else "affine"
    in
    (* `sink`/`borrow` parameters carry no callee-side obligation: sink is
       the terminal consumer (nothing further to forward), borrow never
       owns. Everything else linear-typed in scope must be discharged on
       every path, which the early-exit checks below enforce. *)
    let exempt_params = List.fold_left (fun s (name, ty_opt) ->
      match ty_opt with
      | Some (Ast.TypeBorrow _) | Some (Ast.TypeBorrowMut _)
      | Some (Ast.TypeSink _) -> PathSet.add (PVar name) s
      | _ -> s
    ) PathSet.empty fdef.params in
    let borrowed_params = List.fold_left (fun s (name, ty_opt) ->
      match ty_opt with
      | Some (Ast.TypeBorrow _) | Some (Ast.TypeBorrowMut _) ->
          PathSet.add (PVar name) s
      | _ -> s
    ) PathSet.empty fdef.params in
    let sink_params = List.fold_left (fun s (name, ty_opt) ->
      match ty_opt with
      | Some (Ast.TypeSink _) -> PathSet.add (PVar name) s
      | _ -> s
    ) PathSet.empty fdef.params in
    (* A sink-indexed owner -> linear indexed owner transition carrying the
       same static arguments is the narrow region-handoff shape used by the
       network TX drivers. Within that function, durable storage derived from
       the sink authority is covered by the returned linear owner. This is a
       reviewed signature contract, not general heap inference. *)
    let handoff_authorities =
      match strip_borrow finfo.ret_type with
      | Ast.TypeIndexed (_, ret_args) when is_linear_type finfo.ret_type ->
          List.fold_left (fun paths (name, ty_opt) ->
            match ty_opt with
            | Some (Ast.TypeSink (Ast.TypeIndexed (_, in_args)))
              when in_args = ret_args -> PathSet.add (PVar name) paths
            | _ -> paths)
            PathSet.empty fdef.params
      | _ -> PathSet.empty
    in
    let mv_empty = ResourceFlow.empty in
    let mv_consume = ResourceFlow.consume in
    let mv_clear = ResourceFlow.produce in
    let mv_merge = ResourceFlow.join_branches in
    let require_available loc moved p =
      if is_tracked_path p && ResourceFlow.may_be_consumed p moved then
        raise (TypeError (loc, Printf.sprintf
          "%s value '%s' was already consumed" (kind_word p) (path_to_string p)))
    in
    (* Linear early-exit rule (OWNERSHIP_KERNEL.md 4.2): wherever control
       leaves the region that owes the obligations (return, break,
       continue), every linear PATH in scope must already be definitely
       consumed. A returned linear value is consumed by the return
       expression's own walk before this runs, so no exemption is needed.
       Deliberately conservative for break/continue: an obligation
       declared OUTSIDE the loop that would have been consumed after it is
       also rejected -- v1 does not track loop boundaries (restructure:
       consume before the loop, or avoid break). In Stage 3a this only
       ever fires for PVar paths (linear fields stay banned), but is kept
       path-generic rather than re-special-cased, so a future lift of that
       ban needs no change here. *)
    let require_no_pending_linear loc what moved declared =
      PathSet.iter (fun p ->
        if requires_all_paths p && not (PathSet.mem p exempt_params)
           && not (ResourceFlow.is_consumed_on_all_paths p moved) then
          let msg =
            if is_must_use_path p then Printf.sprintf
              "must-use value '%s' is still pending at this %s (it must be \
               handled on every path)" (path_to_string p) what
            else Printf.sprintf
              "linear value '%s' is still pending at this %s (it must be \
               consumed on every path)" (path_to_string p) what
          in
          raise (TypeError (loc, msg))
      ) declared
    in
    (* Authority-derived region values (issues #106/#128). expr_taint
       computes which owner/guard paths a slice, pointer, or address-derived
       scalar expression depends on. Casts never discard a lifetime tie:
       changing representation (including pointer -> integer) is not
       permission to outlive the authority. Arithmetic/bitwise transforms
       propagate the tie as well, which covers pointer arithmetic and an
       integer address before a later cast back. Comparisons and scalar loads
       check the source while it is live and produce ordinary copied data.
       A dereference, index, or field read whose result is itself a pointer or
       slice does propagate, because that result is another address alias. *)
    let rec ast_region_kind = function
      | Ast.TypeSlice _ -> Some RegionSlice
      | Ast.TypePtr _ | Ast.TypeAlignedPtr _ -> Some RegionPointer
      | Ast.TypeSingleton (t, _) | Ast.TypeBorrow t | Ast.TypeBorrowMut t
      | Ast.TypeSink t -> ast_region_kind t
      | _ -> None
    in
    let rec expr_ast_type (e : Ast.expr) = match e.desc with
      | Ast.Var n -> StringMap.find_opt n !var_types
      | Ast.Cast (target, _) -> Some target
      | Ast.Unsafe x -> expr_ast_type x
      | Ast.Deref x ->
          (match Option.bind (expr_ast_type x) (fun ty -> Some (strip_borrow ty)) with
           | Some (Ast.TypePtr inner) | Some (Ast.TypeAlignedPtr (_, inner)) ->
               Some inner
           | _ -> None)
      | Ast.Index (base, _) ->
          (match Option.map strip_borrow (expr_ast_type base) with
           | Some (Ast.TypePtr inner) | Some (Ast.TypeAlignedPtr (_, inner))
           | Some (Ast.TypeArray (inner, _)) | Some (Ast.TypeSlice (inner, _)) ->
               Some inner
           | _ -> None)
      | Ast.FieldGet (base, field) ->
          let named = Option.bind (expr_ast_type base) (fun ty ->
            match strip_borrow ty with
            | Ast.TypeNamed name -> Some name
            | Ast.TypePtr (Ast.TypeNamed name)
            | Ast.TypeAlignedPtr (_, Ast.TypeNamed name) -> Some name
            | _ -> None)
          in
          Option.bind named (fun name ->
            Option.bind (StringMap.find_opt name senv) (fun (fields, _, _) ->
              List.assoc_opt field fields))
      | _ -> None
    in
    let expr_has_region_result e =
      Option.bind (expr_ast_type e) ast_region_kind <> None
    in
    let type_contains_region_alias ty =
      let rec visit seen = function
        | Ast.TypePtr _ | Ast.TypeAlignedPtr _ | Ast.TypeSlice _ -> true
        | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t
        | Ast.TypeRefined (_, _, t) | Ast.TypeSingleton (t, _)
        | Ast.TypeIo t | Ast.TypeArray (t, _) -> visit seen t
        | Ast.TypeTuple ts -> List.exists (visit seen) ts
        | Ast.TypeExists (_, sort, body) -> visit seen sort || visit seen body
        | Ast.TypeNamed name | Ast.TypeIndexed (name, _) ->
            if StringSet.mem name seen then false
            else
              let seen = StringSet.add name seen in
              (match StringMap.find_opt name senv with
               | Some (fields, _, _) ->
                   List.exists (fun (_, field_ty) -> visit seen field_ty) fields
               | None ->
                   (match Hashtbl.find_opt variant_defs name with
                    | Some cases ->
                        List.exists (fun (_, payload) ->
                          Option.fold ~none:false ~some:(visit seen) payload)
                          cases
                    | None -> false))
        | Ast.TypeVariant name ->
            if StringSet.mem name seen then false
            else
              let seen = StringSet.add name seen in
              (match Hashtbl.find_opt variant_defs name with
               | Some cases ->
                   List.exists (fun (_, payload) ->
                     Option.fold ~none:false ~some:(visit seen) payload)
                     cases
               | None -> false)
        | _ -> false
      in
      visit StringSet.empty (strip_borrow ty)
    in
    let expr_copies_region_aggregate e =
      match expr_ast_type e with
      | Some ty -> ast_region_kind ty = None && type_contains_region_alias ty
      | None -> false
    in
    let rec expr_taint taints (e : Ast.expr) = match e.desc with
      | Ast.Var n ->
          (match StringMap.find_opt n !var_types with
           | Some (Ast.TypeArray _) -> PathSet.empty
           | _ -> TaintEnv.get n taints)
      | Ast.SliceOf (base, _, _) ->
          (* A subslice needs the SAME `Cast(TypeSlice, Var n)` treatment
             below when base is a bare Var (a subslice IS a slice view of
             the array), NOT the ordinary Var case above -- that case's
             TypeArray exclusion exists for plain array reads elsewhere
             and would wrongly hide a stack-array's own taint here
             (GitHub issue #217; confirmed by test: "region slice: a
             stack-array subslice cannot be returned" regressed without
             this special case). base_taint captures exactly this. *)
          base_taint taints base
      | Ast.Cast (Ast.TypeSlice _, { Ast.desc = Ast.Var n; _ }) ->
          TaintEnv.get n taints
      | Ast.Cast (_, x) | Ast.Bnot x | Ast.Unsafe x -> expr_taint taints x
      | Ast.Deref x | Ast.FieldGet (x, _) when expr_has_region_result e ->
          expr_taint taints x
      | Ast.Index (base, _) when expr_has_region_result e ->
          base_taint taints base  (* issue #217: same reasoning as SliceOf's case above *)
      | Ast.BinOp ((Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod
                   | Ast.Bor | Ast.Bxor | Ast.Band | Ast.Shr | Ast.Shl),
                   left, right) ->
          PathSet.union (expr_taint taints left) (expr_taint taints right)
      | Ast.Call (name, args) ->
          let target = Option.value
            (StringMap.find_opt (loc_key e.loc) !resolved_call_targets)
            ~default:name in
          (match StringMap.find_opt target region_return_info with
           | Some (indices, _) ->
               List.fold_left (fun paths i ->
                 match List.nth_opt args i with
                 | Some { Ast.desc = Ast.Var authority; _ } ->
                     PathSet.add (PVar authority) paths
                 | _ -> paths)
                 PathSet.empty indices
           | None when target = "min" || target = "max" ->
               List.fold_left (fun paths arg ->
                 PathSet.union paths (expr_taint taints arg))
                 PathSet.empty args
           | None -> PathSet.empty)
      | _ -> PathSet.empty
    (* GitHub issue #217: an Index/SliceOf base's own taint -- a bare Var
       goes straight to TaintEnv (bypassing expr_taint's ordinary Var
       case's TypeArray exclusion, which exists for plain array reads
       elsewhere and is NOT what a subslice/element access of that same
       array means), anything else recurses through expr_taint normally. *)
    and base_taint taints (base : Ast.expr) =
      match base.desc with
      | Ast.Var n -> TaintEnv.get n taints
      | _ -> expr_taint taints base
    in
    let accepts_region_borrow = function
      | Some (Ast.TypeBorrow inner) -> ast_region_kind inner <> None
      | _ -> false
    in
    let rec expr_region_kind (e : Ast.expr) = match e.desc with
      | Ast.Var n -> Option.bind (StringMap.find_opt n !var_types) ast_region_kind
      | Ast.SliceOf _ -> Some RegionSlice
      | Ast.Unsafe x -> expr_region_kind x
      | Ast.Cast (target, _) -> ast_region_kind target
      | Ast.Deref _ | Ast.Index _ | Ast.FieldGet _ ->
          Option.bind (expr_ast_type e) ast_region_kind
      | Ast.Call (name, _) ->
          let target = Option.value
            (StringMap.find_opt (loc_key e.loc) !resolved_call_targets)
            ~default:name in
          Option.map snd (StringMap.find_opt target region_return_info)
      | _ -> None
    in
    (* The name a taint diagnostic should blame for an escaping expression. *)
    let rec taint_source_name (e : Ast.expr) = match e.desc with
      | Ast.Var n -> n
      | Ast.SliceOf (base, _, _) -> taint_source_name base
      | Ast.Cast (_, x) | Ast.Bnot x | Ast.Unsafe x -> taint_source_name x
      | Ast.Call (name, _) -> Printf.sprintf "result of '%s'" name
      | _ -> "<value>"
    in
    let require_no_region_aggregate_load loc e taint =
      if expr_copies_region_aggregate e && not (PathSet.is_empty taint) then
        raise (TypeError (loc,
          "an aggregate containing a pointer or slice cannot be copied from \
           authority-derived storage; aggregate region tracking is not \
           implemented, so project a scalar or direct pointer/slice value"))
    in
    (* Region taint is deliberately keyed by directly tracked local names;
       it has no component/case shape for runtime aggregates. Silently
       accepting a tied slice/pointer inside a tuple, variant payload, or
       struct literal would therefore lose the tie on extraction. Until a
       real API requires aggregate region polymorphism, reject that storage
       rather than pretending the lifetime survived. Search nested aggregate
       literals too so wrapping a tuple in a struct (or vice versa) cannot
       bypass the boundary. *)
    let rec first_tainted_aggregate_value taints (e : Ast.expr) =
      if not (PathSet.is_empty (expr_taint taints e)) then Some e
      else match e.desc with
        | Ast.TupleLit xs | Ast.StructLit xs ->
            List.find_map (first_tainted_aggregate_value taints) xs
        | Ast.VariantCtor (_, _, payload) ->
            first_tainted_aggregate_value taints payload
        | Ast.Unsafe x -> first_tainted_aggregate_value taints x
        | _ -> None
    in
    let require_no_taint_aggregate loc taints aggregate values =
      match List.find_map (first_tainted_aggregate_value taints) values with
      | None -> ()
      | Some source ->
          let source_taint = expr_taint taints source in
          let stack_derived = PathSet.exists is_stack_origin source_taint in
          let value_kind = Option.value
            (Option.map region_kind_word (expr_region_kind source))
            ~default:"value" in
          let derived_kind =
            if stack_derived && value_kind = "slice" then "stack-derived slice"
            else if stack_derived && value_kind = "pointer" then "stack-derived pointer"
            else if stack_derived then "stack-derived value"
            else if value_kind = "slice" then "owner-derived slice"
            else if value_kind = "pointer" then "authority-derived pointer"
            else "authority-derived value"
          in
          raise (TypeError (loc, Printf.sprintf
            "%s '%s' cannot be stored in a %s; aggregate region tracking \
             is not implemented, so keep the derived value in a directly \
             tracked local binding"
            derived_kind (taint_source_name source) aggregate))
    in
    (* Lazy kill: a tainted name is rejected at USE time once any of its
       owner paths may have been consumed. Checking against maybe_consumed
       (union at branch joins) gives the same conservative "possibly
       consumed" treatment affine double-use already has. *)
    let require_region_live loc taints moved name =
      PathSet.iter (fun p ->
        if ResourceFlow.may_be_consumed p moved then
          let value_kind = Option.value
            (Option.map region_kind_word
               (Option.bind (StringMap.find_opt name !var_types) ast_region_kind))
            ~default:"value" in
          raise (TypeError (loc, Printf.sprintf
            "%s '%s' is derived from %s value '%s' and cannot be used \
             after '%s' is consumed"
            value_kind name (kind_word p) (path_to_string p)
            (path_to_string p))))
        (TaintEnv.get name taints)
    in
    (* GitHub issue #217: an Index/SliceOf base is no longer always a bare
       ident -- region taint is deliberately keyed only by directly tracked
       local NAMES (see the "no component/case shape for runtime
       aggregates" limitation below), so a FieldGet/Index-chain base has no
       single tracked name to check liveness against. Apply the real check
       only when the base still reduces to the one shape it can say
       anything about (a bare Var); any other restricted shape is silently
       skipped here, matching the pre-existing "aggregate region tracking
       is not implemented" limitation rather than pretending to check
       something this design cannot yet check. *)
    let require_region_live_base loc taints moved (base : Ast.expr) =
      match base.desc with
      | Ast.Var name -> require_region_live loc taints moved name
      | _ -> ()
    in
    (* A taint names its authority by the current surface place key. Reusing
       that key for a new owner/guard would otherwise make an old derived
       value appear authorized by the new value and revive it after the old
       authority was consumed. Reject that key reuse while a dependent
       binding is still in scope. Reassigning the dependent to an unrelated
       value clears its taint, and leaving its scope removes it from
       [declared], so both intentional lifetime endings remain available. *)
    let require_no_authority_rebind loc declared taints name =
      let live_dependent =
        List.find_opt (fun dependent ->
          PathSet.mem (PVar dependent) declared)
          (TaintEnv.dependents (PVar name) taints)
      in
      match live_dependent with
      | Some dependent ->
          raise (TypeError (loc, Printf.sprintf
            "cannot rebind authority '%s' while derived value '%s' still \
             depends on its current lifetime"
            name dependent))
      | None -> ()
    in
    (* Region-bound values cannot escape unless the current signature performs
       the narrow indexed-owner handoff described above. *)
    let require_no_taint_escape loc taints escape (e : Ast.expr) =
      let t = expr_taint taints e in
      if not (PathSet.is_empty t)
         && not (PathSet.subset t handoff_authorities) then
        let owner = path_to_string (PathSet.choose t) in
        let stack_derived = PathSet.exists is_stack_origin t in
        let value_kind = Option.value
          (Option.map region_kind_word (expr_region_kind e)) ~default:"value" in
        let derived_kind =
          if stack_derived && value_kind = "slice" then "stack-derived slice"
          else if stack_derived && value_kind = "pointer" then "stack-derived pointer"
          else if stack_derived then "stack-derived value"
          else if value_kind = "slice" then "owner-derived slice"
          else if value_kind = "pointer" then "authority-derived pointer"
          else "authority-derived value"
        in
        let authority_kind =
          if stack_derived then "stack local"
          else if value_kind = "slice" then "owner" else "authority"
        in
        let msg = match escape with
          | `Return -> Printf.sprintf
              "%s '%s' cannot be returned from this \
               function (it is tied to %s '%s')"
              derived_kind (taint_source_name e) authority_kind owner
          | `Store -> Printf.sprintf
              "%s '%s' cannot be stored into a global, \
               struct field, array element, or through a pointer (it is \
               tied to %s '%s')"
              derived_kind (taint_source_name e) authority_kind owner
        in
        raise (TypeError (loc, msg))
    in
    (* Taking the address of a tainted local would move the lifetime-bearing
       value behind an untracked pointer-to-slot. Reject that laundering path
       rather than tainting every dereference result: reading through a tied
       pointer may legitimately produce ordinary copied scalar data. *)
    let require_no_taint_address loc taints (e : Ast.expr) =
      if not (PathSet.is_empty (expr_taint taints e)) then
        let value_kind = Option.value
          (Option.map region_kind_word (expr_region_kind e)) ~default:"value" in
        let derived_kind =
          if value_kind = "slice" then "owner-derived slice"
          else if value_kind = "pointer" then "authority-derived pointer"
          else "authority-derived value"
        in
        raise (TypeError (loc, Printf.sprintf
          "cannot take the address of %s '%s'; indirect local region tracking \
           is not implemented, so keep the derived value in a directly \
           tracked local binding"
          derived_kind (taint_source_name e)))
    in
    let rec check_expr taints moved consume (e : Ast.expr) =
      match e.desc with
      | Ast.ViewLit (name, _) ->
          if Hashtbl.find_opt view_kinds name = Some Ast.KindLinear
             && not consume then
            raise (TypeError (e.loc, Printf.sprintf
              "linear erased view '%s' must be moved into an owning binding or consumer"
              name));
          moved
      | Ast.Var name ->
          let p = PVar name in
          require_available e.loc moved p;
          require_region_live e.loc taints moved name;
          if consume && PathSet.mem p borrowed_params then
            raise (TypeError (e.loc, Printf.sprintf
              "cannot move borrowed value '%s'; borrow permits non-consuming access only"
              name));
          if consume && is_tracked_path p then mv_consume p moved else moved
      | Ast.FieldGet (base_expr, fname) ->
          require_no_region_aggregate_load e.loc e
            (expr_taint taints base_expr);
          (match base_expr.desc with
           | Ast.Var base_name when is_tracked_path (PField (base_name, fname)) ->
               let p = PField (base_name, fname) in
               require_available e.loc moved p;
               if consume then mv_consume p moved else moved
           | _ -> check_expr taints moved false base_expr)
      | Ast.Call ("stable_replace", [guard; lock; field; replacement]) ->
          if not consume then
            raise (TypeError (e.loc,
              "linear result of 'stable_replace' must be moved into an owning binding, returned, or matched"));
          let moved = check_expr taints moved false guard in
          let moved = check_expr taints moved false lock in
          let moved = match field.desc with
            | Ast.FieldGet (base, _) -> check_expr taints moved false base
            | _ -> moved
          in
          check_expr taints moved true replacement
      | Ast.Call (name, args) ->
          let target = Option.value
            (StringMap.find_opt (loc_key e.loc) !resolved_call_targets) ~default:name in
          let params = Option.value (StringMap.find_opt target call_params) ~default:[] in
          let rec check_args moved args params = match args with
            | [] -> moved
            | arg :: rest ->
            let param = match params with p :: _ -> p | [] -> None in
            let arg_taint = expr_taint taints arg in
            if not (PathSet.is_empty arg_taint)
               && not (is_compiler_builtin target)
               && not (accepts_region_borrow param)
               && not (PathSet.subset arg_taint handoff_authorities) then begin
              let value_kind = Option.value
                (Option.map region_kind_word (expr_region_kind arg))
                ~default:"value" in
              let origin =
                if PathSet.exists is_stack_origin arg_taint
                then "stack-derived"
                else "authority-derived" in
              raise (TypeError (arg.loc, Printf.sprintf
                "%s '%s' is %s and cannot be passed to \
                 retaining parameter of '%s'; declare that pointer or slice \
                 parameter as `borrow`, or perform the retention inside an \
                 indexed-owner handoff"
                value_kind (taint_source_name arg) origin name))
            end;
            let consume_arg = match params with
              | Some ty :: _ when is_tracked_type ty ->
                  (match ty with
                   | Ast.TypeBorrow _ | Ast.TypeBorrowMut _ -> false
                   | _ -> true)
              | _ -> false
            in
            let moved = check_expr taints moved consume_arg arg in
            check_args moved rest (match params with _ :: ps -> ps | [] -> [])
          in
          let moved = check_args moved args params in
          let returns_obligation = match StringMap.find_opt target call_returns with
            | Some ty -> is_linear_type ty || is_must_use_type ty
            | None -> false
          in
          if returns_obligation && not consume then begin
            let msg = match StringMap.find_opt target call_returns with
              | Some ty when is_must_use_type ty && not (is_linear_type ty) ->
                  Printf.sprintf
                  "must-use result of '%s' must be handled, returned, or moved into a binding"
                  name
              | _ -> Printf.sprintf
                  "linear result of '%s' must be moved into an owning binding or consumer"
                  name
            in
            raise (TypeError (e.loc, msg))
          end;
          moved
      | Ast.VariantCtor (vtype, _, payload) ->
          require_no_taint_aggregate e.loc taints "variant payload" [payload];
          if (Hashtbl.find_opt variant_kinds vtype = Some Ast.KindLinear
              || Hashtbl.mem must_use_variants vtype)
             && not consume then begin
            let msg = if Hashtbl.mem must_use_variants vtype
                         && Hashtbl.find_opt variant_kinds vtype
                            <> Some Ast.KindLinear then
              Printf.sprintf
                "must-use variant '%s' must be handled, returned, or moved into a binding"
                vtype
            else Printf.sprintf
              "linear variant '%s' must be moved into an owning binding or matched"
              vtype in
            raise (TypeError (e.loc, msg))
          end;
          check_expr taints moved consume payload
      | Ast.BinOp (_, a, b) ->
          check_expr taints (check_expr taints moved false a) false b
      | Ast.AddrOf a ->
          require_no_taint_address e.loc taints a;
          check_expr taints moved false a
      | Ast.Deref a ->
          require_no_region_aggregate_load e.loc e (expr_taint taints a);
          check_expr taints moved false a
      | Ast.Bnot a | Ast.Cast (_, a) | Ast.Unsafe a ->
          check_expr taints moved false a
      | Ast.StructLit xs ->
          require_no_taint_aggregate e.loc taints "struct value" xs;
          List.fold_left (fun m x -> check_expr taints m false x) moved xs
      | Ast.TupleLit xs ->
          require_no_taint_aggregate e.loc taints "tuple" xs;
          (* A tracked component moves into the tuple exactly when the
             tuple itself is being consumed (bound/passed/returned); a
             discarded literal consumes nothing, so obligations never
             vanish into a dropped temporary (OWNERSHIP_KERNEL.md 5.9). *)
          List.fold_left (fun m x -> check_expr taints m consume x) moved xs
      | Ast.Index (base, i) ->
          (* Index/SliceOf bases are not visited as ordinary Var/FieldGet
             expressions (place_undecayed_type reads them directly, not
             infer_expr), so the region use check must fire here
             explicitly (they are how a derived frame slice is actually
             read). *)
          require_region_live_base e.loc taints moved base;
          require_no_region_aggregate_load e.loc e (base_taint taints base);
          check_expr taints moved false i
      | Ast.SliceOf (base, lo, hi) ->
          require_region_live_base e.loc taints moved base;
          check_expr taints (check_expr taints moved false lo) false hi
      | Ast.SizeOf _ | Ast.OffsetOf _ | Ast.IntLit _ | Ast.BoolLit _
      | Ast.StringLit _ | Ast.EmbedFile _ -> moved
      | Ast.EnumVariant (vtype, _) ->
          if (Hashtbl.find_opt variant_kinds vtype = Some Ast.KindLinear
              || Hashtbl.mem must_use_variants vtype)
             && not consume then begin
            let msg = if Hashtbl.mem must_use_variants vtype
                         && Hashtbl.find_opt variant_kinds vtype
                            <> Some Ast.KindLinear then
              Printf.sprintf
                "must-use variant '%s' must be handled, returned, or moved into a binding"
                vtype
            else Printf.sprintf
              "linear variant '%s' must be moved into an owning binding or matched"
              vtype in
            raise (TypeError (e.loc, msg))
          end;
          moved
      | Ast.Assign (lhs, rhs) ->
          (* GitHub issue #184: a GENUINELY NESTED assignment (not the
             ordinary `x = e;` top-level-statement shape, which
             check_stmt's own dedicated Ast.Expr(Assign(...)) case above
             handles instead, with full declared/taints threading this
             function's signature cannot provide). A target that would
             need declared/taints updated -- a bare Var, or a tracked
             (indexed-owner) field -- is rejected outright here rather
             than silently skipping that update (which the old dedicated
             stmt cases always performed for exactly these two shapes):
             those two ARE reachable in check_stmt's own dedicated case,
             so this restriction only bites when someone genuinely nests
             a tracked-target assignment inside a larger expression (e.g.
             `if (x = alloc()) {...}`), which was never expressible before
             this feature existed anyway. Deref/Index/an ordinary
             (non-tracked) FieldGet target never touched declared/taints
             in the old code either -- those are handled fully here,
             identically to check_stmt's own case. *)
          (match lhs.desc with
           | Ast.Var name when is_tracked_path (PVar name) ->
               raise (TypeError (e.loc, Printf.sprintf
                 "assignment to linear/affine/must-use value '%s' is only \
                  supported as a standalone statement, not nested inside \
                  a larger expression" name))
           | Ast.FieldGet (Ast.{ desc = Var base_name; _ }, fname)
             when is_tracked_path (PField (base_name, fname)) ->
               raise (TypeError (e.loc,
                 "assignment to a linear/affine indexed-owner field is \
                  only supported as a standalone statement, not nested \
                  inside a larger expression"))
           | Ast.Var _ ->
               (* An untracked (plain scalar/etc.) bare-name target: the
                  old dedicated Assign case's declared/taints update is a
                  no-op-equivalent for tracking purposes here (nothing
                  safety-relevant depends on it for a value that was never
                  tracked to begin with), so evaluating the RHS for
                  move-safety is sufficient. *)
               check_expr taints moved false rhs
           | Ast.Deref a ->
               check_expr taints (check_expr taints moved false a) false rhs
           | Ast.FieldGet (base_expr, _) ->
               check_expr taints (check_expr taints moved false base_expr) false rhs
           | Ast.Index (base, i) ->
               require_region_live_base e.loc taints moved base;
               check_expr taints (check_expr taints moved false i) false rhs
           | _ -> moved (* not an lvalue; infer_expr already rejected it *))
    in
    (* Scope-end checks apply to LINEAR and MUST_USE obligations. Affine
       permits weakening by definition; maybe-consumed still rejects double
       use. *)
    let decl_locs : (path, Ast.loc) Hashtbl.t = Hashtbl.create 16 in
    let set_decl_loc p l = Hashtbl.replace decl_locs p l in
    (* Purely syntactic "does this statement list always return" check
       (GitHub issue #89 comment thread's "return-terminated branch" gap):
       a branch that unconditionally returns never reaches the code after
       its enclosing `if`/`match`, so what it consumed must not be merged
       into what continues past that `if`/`match` (in EITHER set: not
       unioned into maybe-consumed, not intersected into must-be-consumed).
       Deliberately
       conservative in the safe direction: loops are never treated as
       terminators here. *)
    let rec stmt_always_terminates (s : Ast.stmt) = match s.desc with
      | Ast.Return _ -> true
      | Ast.Expr { desc = Ast.Call (name, _); _ }
        when StringSet.mem name noreturn_functions -> true
      | Ast.If (_, yes, no) -> always_terminates yes && always_terminates no
      | Ast.Match (_, arms) -> List.for_all (fun arm ->
          let body = match arm with
            | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmIntLit (_, b) -> b in
          always_terminates body) arms
      | Ast.Block body | Ast.UnsafeBlock body -> always_terminates body
      | _ -> false
    and always_terminates stmts = List.exists stmt_always_terminates stmts in
    let rec check_stmts moved declared taints stmts =
      let initial_declared = declared in
      let initial_var_types = !var_types in
      let (moved, declared, taints) =
        List.fold_left (fun (moved, declared, taints) s ->
            check_stmt moved declared taints s)
          (moved, declared, taints) stmts
      in
      let newly_declared = PathSet.diff declared initial_declared in
      PathSet.iter (fun p ->
        let loc () = Option.value (Hashtbl.find_opt decl_locs p) ~default:fdef.def_loc in
        match path_kind p with
        | Some Ast.KindLinear when
            not (ResourceFlow.is_consumed_on_all_paths p moved) ->
            if ResourceFlow.may_be_consumed p moved then
              let msg = if is_must_use_path p then Printf.sprintf
                "must-use value '%s' is handled on some paths but not on every path"
                (path_to_string p)
              else Printf.sprintf
                "linear value '%s' is consumed on some paths but not on every path"
                (path_to_string p) in
              raise (TypeError (loc (), msg))
            else
              let msg = if is_must_use_path p then Printf.sprintf
                "must-use value '%s' is never handled" (path_to_string p)
              else Printf.sprintf
                "linear value '%s' is never consumed" (path_to_string p) in
              raise (TypeError (loc (), msg))
        | _ -> ()
      ) newly_declared;
      (* local_types is name-keyed for inference, but source bindings are
         lexically scoped and disjoint match/if arms may legitimately reuse
         one spelling with different types. Let annotations below refine the
         active binding while its statement list is checked; restore the
         outer map on scope exit so an arm-local status cannot make a later
         same-named integer look like a must-use obligation. *)
      var_types := initial_var_types;
      (moved, declared, taints)
    and check_stmt moved declared taints (s : Ast.stmt) =
      match s.desc with
      | Ast.Return None ->
          require_no_pending_linear s.loc "return" moved declared;
          (moved, declared, taints)
      | Ast.Return (Some e) ->
          require_no_taint_escape s.loc taints `Return e;
          let consumes = match fdef.ret_type with
            | Some ty -> is_tracked_type ty
            | None -> false
          in
          let moved = check_expr taints moved consumes e in
          require_no_pending_linear s.loc "return" moved declared;
          (moved, declared, taints)
      | Ast.Expr { desc = Ast.Assign (lhs, rhs); loc } ->
          (* GitHub issue #184: relocated verbatim from the 4 old dedicated
             stmt cases (Assign/AssignDeref/AssignField/AssignIndex),
             dispatched on the unified expr's LHS shape. Handled as its
             own Ast.Expr sub-case (matched BEFORE the generic `Ast.Expr e`
             case below) rather than folded into the shared check_expr:
             only THIS statement position can thread updated `declared`/
             `taints` back out (check_expr's own signature only threads
             `moved`) -- see check_expr's own new Assign case for how a
             genuinely NESTED assignment (not the top-level-statement
             shape every real use of this feature actually needs) is
             handled instead. *)
          (match lhs.desc with
           | Ast.Var name ->
               let p = PVar name in
               require_no_authority_rebind loc declared taints name;
               if PathSet.mem p borrowed_params then
                 raise (TypeError (loc, Printf.sprintf
                   "cannot assign to borrowed value '%s'; borrow permits non-consuming access only"
                   name));
               if PathSet.mem p sink_params then
                 raise (TypeError (loc, Printf.sprintf
                   "cannot assign to sink value '%s'; sink designates this parameter's terminal consumption"
                   name));
               (* Region taint: a GLOBAL target is durable storage the
                  function-local tracking cannot follow -- reject a tainted
                  RHS. A local target instead REPLACES its taint with the
                  RHS's (creation from a region call, alias/subslice
                  propagation, or clearing on any other RHS), mirroring how
                  reassignment clears consumed status. *)
               let is_local_target = StringMap.mem name !var_types in
               if not is_local_target then
                 require_no_taint_escape loc taints `Store rhs;
               let moved = check_expr taints moved (is_tracked_path p) rhs in
               (* Assignment is not a use of the old value: a binding whose
                  value was already moved may be reinitialized. The RHS walk
                  still rejects trying to read that moved value. A live
                  affine value may be weakened by overwrite; a live linear
                  obligation may not. The RHS runs first, so
                  `p = transform(p);` discharges the old linear value before
                  this check and remains legal. *)
               if requires_all_paths p
                  && PathSet.mem p declared
                  && not (ResourceFlow.is_consumed_on_all_paths p moved) then
                 raise (TypeError (loc, Printf.sprintf
                   "assigning over %s value '%s' would discard its \
                    obligation (consume it first)" (kind_word p) name));
               let taints =
                 if is_local_target then TaintEnv.set name (expr_taint taints rhs) taints
                 else taints
               in
               (mv_clear p moved, PathSet.add p declared, taints)
           | Ast.Deref a ->
               require_no_taint_escape loc taints `Store rhs;
               (check_expr taints (check_expr taints moved false a) false rhs,
                declared, taints)
           | Ast.FieldGet (base_expr, fname) ->
               require_no_taint_escape loc taints `Store rhs;
               (match base_expr.desc with
                | Ast.Var base_name when is_tracked_path (PField (base_name, fname)) ->
                    (* Stage 3a: this field is the producing site for a
                       fresh obligation, the field-path equivalent of a
                       `let`. The RHS is consumed if it is itself a tracked
                       expression (e.g. `h.t = some_other_handle;`), same
                       as a plain Assign's RHS. Linear fields cannot reach
                       this branch (banned at declaration), so no
                       overwrite-ban check is needed here yet -- kept
                       path-generic in is_tracked_path/is_linear_path above
                       so lifting that ban later is a small diff, not a
                       redesign. *)
                    let p = PField (base_name, fname) in
                    set_decl_loc p loc;
                    let moved = check_expr taints moved true rhs in
                    (mv_clear p moved, PathSet.add p declared, taints)
                | _ ->
                    (check_expr taints (check_expr taints moved false base_expr)
                       false rhs,
                     declared, taints))
           | Ast.Index (base, i) ->
               require_region_live_base loc taints moved base;
               require_no_taint_escape loc taints `Store rhs;
               (check_expr taints (check_expr taints moved false i) false rhs,
                declared, taints)
           | _ ->
               (* Not an lvalue shape infer_expr's own Assign case would
                  have already rejected during type inference -- this
                  branch is unreachable in a program that passed type
                  checking, kept only so this match stays exhaustive. *)
               (moved, declared, taints))
      | Ast.Expr e -> (check_expr taints moved false e, declared, taints)
      | Ast.Let (_, name, ty_opt, init, _) ->
          Option.iter (fun ty ->
            var_types := StringMap.add name (resolve_declared_type ty) !var_types)
            ty_opt;
          let p = PVar name in
          require_no_authority_rebind s.loc declared taints name;
          set_decl_loc p s.loc;
          (match init with
           | None when requires_all_paths p ->
               raise (TypeError (s.loc, Printf.sprintf
                 "%s value '%s' must be initialized at its declaration"
                 (kind_word p) name))
           | _ -> ());
          let moved = match init with
            | Some e -> check_expr taints moved (is_tracked_path p) e
            | None -> moved
          in
          let taints = TaintEnv.set name
            (match StringMap.find_opt name !var_types, init with
             (* A local array is stack storage. Its value expression decays
                to a pointer, and SliceOf builds a fat pointer into the same
                storage, so seed the backing array itself as a region origin.
                Globals deliberately never pass through this Let branch. *)
             | Some (Ast.TypeArray _), _ -> PathSet.singleton (PVar name)
             | _, Some e -> expr_taint taints e
             | _, None -> PathSet.empty)
            taints
          in
          (mv_clear p moved, PathSet.add p declared, taints)
      | Ast.LetTuple (names, rhs) ->
          List.iter
            (require_no_authority_rebind s.loc declared taints) names;
          List.iter (fun n -> set_decl_loc (PVar n) s.loc) names;
          (* Destructuring consumes the tuple (consume=true moves an RHS
             variable, or propagates into a direct TupleLit's tracked
             components); each bound name starts as a fresh obligation/
             handle of its component type. *)
          let moved = check_expr taints moved true rhs in
          let moved = List.fold_left (fun m n -> mv_clear (PVar n) m) moved names in
          let taints = List.fold_left
            (fun t n -> TaintEnv.set n PathSet.empty t) taints names in
          (moved,
           List.fold_left (fun d n -> PathSet.add (PVar n) d) declared names,
           taints)
      | Ast.Block body | Ast.UnsafeBlock body ->
          let (out, _, taints_out) = check_stmts moved declared taints body in
          (out, declared, taints_out)
      | Ast.If (cond, yes, no) ->
          let moved = check_expr taints moved false cond in
          let (ym, _, yt) = check_stmts moved declared taints yes in
          let (nm, _, nt) = check_stmts moved declared taints no in
          let (combined, combined_taints) =
            match always_terminates yes, always_terminates no with
            | true, false -> (nm, nt)  (* "yes" always returns: only "no" continues past this `if` *)
            | false, true -> (ym, yt)  (* symmetric case *)
            | _, _ -> (mv_merge ym nm, TaintEnv.join_branches yt nt)
              (* neither terminates, or BOTH do (nothing continues past
                 this `if` at all, so which set we report is moot) *)
          in
          (combined, declared, combined_taints)
      | Ast.While (cond, body) ->
          let moved = check_expr taints moved false cond in
          let (body_moved, _, body_taints) =
            check_stmts moved declared taints body in
          let newly_moved_outer =
            PathSet.inter declared
              (PathSet.diff (ResourceFlow.maybe_consumed body_moved)
                 (ResourceFlow.maybe_consumed moved)) in
          if not (PathSet.is_empty newly_moved_outer) then
            raise (TypeError (s.loc,
              "cannot consume an affine/linear value declared outside a loop inside that loop"));
          (moved, declared, TaintEnv.join_branches taints body_taints)
      | Ast.For (name, _, lo, hi, body) ->
          require_no_authority_rebind s.loc declared taints name;
          let moved = check_expr taints (check_expr taints moved false lo) false hi in
          let declared_body = PathSet.add (PVar name) declared in
          (* The counter rebinds `name` for the body, so any outer taint on
             that name must not leak into it (same rebinding treatment
             written_names gives narrowing kills). *)
          let body_taints_in = TaintEnv.set name PathSet.empty taints in
          let (body_moved, _, body_taints) =
            check_stmts moved declared_body body_taints_in body in
          let newly_moved_outer =
            PathSet.inter declared
              (PathSet.diff (ResourceFlow.maybe_consumed body_moved)
                 (ResourceFlow.maybe_consumed moved)) in
          if not (PathSet.is_empty newly_moved_outer) then
            raise (TypeError (s.loc,
              "cannot consume an affine/linear value declared outside a loop inside that loop"));
          (moved, declared, TaintEnv.join_branches taints body_taints)
      | Ast.ForEach (name, collection, body) ->
          require_no_authority_rebind s.loc declared taints name;
          let moved = check_expr taints moved false collection in
          let body_taints_in = TaintEnv.set name PathSet.empty taints in
          let (body_moved, _, body_taints) =
            check_stmts moved (PathSet.add (PVar name) declared)
              body_taints_in body in
          let newly_moved_outer =
            PathSet.inter declared
              (PathSet.diff (ResourceFlow.maybe_consumed body_moved)
                 (ResourceFlow.maybe_consumed moved)) in
          if not (PathSet.is_empty newly_moved_outer) then
            raise (TypeError (s.loc,
              "cannot consume an affine/linear value declared outside a loop inside that loop"));
          (moved, declared, TaintEnv.join_branches taints body_taints)
      | Ast.Match (e, arms) ->
          let moved = check_expr taints moved true e in
          let results = List.map (fun arm ->
            let (binding, binding_ty, body) = match arm with
              | Ast.ArmVariant (vtype, cname, binding, b) ->
                  let payload_ty = match binding with
                    | None -> None
                    | Some _ ->
                        let schema = match Hashtbl.find_opt variant_defs vtype with
                          | Some cases -> Option.join (List.assoc_opt cname cases)
                          | None -> None
                        in
                        let rec strip_exists = function
                          | Ast.TypeExists (_, _, inner) -> strip_exists inner
                          | ty -> ty
                        in
                        Option.map strip_exists schema
                  in
                  (binding, payload_ty, b)
              | Ast.ArmWild b -> (None, None, b)
              | Ast.ArmIntLit (_, b) -> (None, None, b)
            in
            let previous_binding_ty = match binding with
              | Some (name, _) -> StringMap.find_opt name !var_types
              | None -> None
            in
            Option.iter (fun (name, _) ->
              require_no_authority_rebind s.loc declared taints name)
              binding;
            (match binding, binding_ty with
             | Some (name, _), Some ty ->
                 var_types := StringMap.add name ty !var_types
             | _ -> ());
            let (arm_moved, arm_declared, binding_path) = match binding with
              | None -> (moved, declared, None)
              | Some (name, _) ->
                  let p = PVar name in
                  set_decl_loc p s.loc;
                  (mv_clear p moved, PathSet.add p declared, Some p)
            in
            (* A payload binder is a fresh value, never a region slice --
               clear any stale same-named taint for the arm body. *)
            let arm_taints = match binding with
              | Some (name, _) -> TaintEnv.set name PathSet.empty taints
              | None -> taints
            in
            let (out, _, out_taints) =
              check_stmts arm_moved arm_declared arm_taints body in
            Option.iter (fun p ->
              if requires_all_paths p
                 && not (ResourceFlow.is_consumed_on_all_paths p out) then
                if ResourceFlow.may_be_consumed p out then
                  raise (TypeError (s.loc, Printf.sprintf
                    "linear variant payload '%s' is consumed on some paths but not on every path"
                    (path_to_string p)))
                else
                  raise (TypeError (s.loc, Printf.sprintf
                    "linear variant payload '%s' is never consumed"
                    (path_to_string p)))
            ) binding_path;
            let out = match binding_path with
              | Some p -> mv_clear p out
              | None -> out
            in
            (match binding with
             | Some (name, _) ->
                 var_types := (match previous_binding_ty with
                   | Some ty -> StringMap.add name ty !var_types
                   | None -> StringMap.remove name !var_types)
             | None -> ());
            (always_terminates body, out, out_taints)
          ) arms in
          (* Same reasoning as `If` above: a terminating arm never reaches
             code after the `match`, so its consumption must not be merged
             into what continues -- unless EVERY arm terminates, in which
             case nothing continues anyway and the merge is moot. *)
          let non_terminating = List.filter (fun (terminates, _, _) -> not terminates) results in
          let contributing = if non_terminating = [] then results else non_terminating in
          let (arm_moved, arm_taints) = match contributing with
            | [] -> (moved, taints)
            | (_, first, first_taints) :: rest ->
                List.fold_left (fun (acc, acc_t) (_, am, at) ->
                    (mv_merge acc am, TaintEnv.join_branches acc_t at))
                  (first, first_taints) rest
          in
          (arm_moved, declared, arm_taints)
      | Ast.Break ->
          require_no_pending_linear s.loc "break" moved declared;
          (moved, declared, taints)
      | Ast.Continue ->
          require_no_pending_linear s.loc "continue" moved declared;
          (moved, declared, taints)
      | Ast.Yield e ->
          (* GitHub issue #184: reached when a plain `match` STATEMENT's
             arm bodies are walked here (LetMatch's own case below
             rewrites `Yield` away via rewrite_letmatch_arm_bodies before
             ever recursing into check_stmt, so it never sees a bare
             `Yield` itself) -- a plain match discards the arm's value,
             so this is identical to `Ast.Expr e`. *)
          (check_expr taints moved false e, declared, taints)
      | Ast.LetMatch (_, name, ty_expr, disc, arms) ->
          (* GitHub issue #183 follow-up, extended by #184's `Yield`-tail
             sugar: rewrite_letmatch_arm_bodies (module-level, shared with
             infer_stmt's own LetMatch case) turns each arm's terminal
             `Yield e` into an ordinary `name = e;` statement first, so
             everything below -- including this function's OWN new
             `Ast.Expr (Ast.Assign (...))` case above -- applies exactly
             as it did before #184, with no LetMatch-specific handling
             needed in the shared Match-recursion machinery itself.
             `name` IS pre-registered into `declared` before recursing
             (needed so a continuing arm's rewritten `name = ...;` is not
             mistaken by check_stmts's end-of-block sweep for a fresh,
             arm-scoped declaration that must be consumed before THAT
             arm's own block ends -- it is meant to escape to the
             enclosing scope instead, like any other already-declared
             Assign target).
             Unlike Ast.Let's initialized case, though, `name` is
             pre-registered as already CONSUMED, not merely produced:
             the two kinds of arm need different starting obligations and
             `declared` alone cannot distinguish them, so the obligation
             itself carries the distinction. A diverging arm (early
             return/break/continue) never touches `name` at all -- seen
             as "already consumed", it raises nothing, matching the fact
             that nothing was ever produced on that path. A continuing
             arm's rewritten `name = ...;` re-produces it fresh; Assign's
             own "discard an outstanding obligation" guard only fires
             when the existing obligation is NOT already fully consumed,
             so this re-production is accepted cleanly. Ast.Match's
             arm-merge logic (just above) already excludes terminating
             arms from the merge, so the diverging arm's vacuous
             "consumed" state cannot leak into what continues past the
             whole statement. *)
          Option.iter (fun ty ->
            var_types := StringMap.add name (resolve_declared_type ty) !var_types)
            ty_expr;
          let p = PVar name in
          require_no_authority_rebind s.loc declared taints name;
          set_decl_loc p s.loc;
          let moved = mv_consume p moved in
          let declared = PathSet.add p declared in
          let taints = TaintEnv.set name PathSet.empty taints in
          let arms = rewrite_letmatch_arm_bodies name arms in
          check_stmt moved declared taints
            { desc = Ast.Match (disc, arms); loc = s.loc }
    in
    if not (always_terminates fdef.body) then begin
      if is_direct_variant_type finfo.ret_type then
        raise (TypeError (fdef.def_loc, Printf.sprintf
          "function '%s' returns a variant and must return explicitly on every path"
          fdef.name));
      if is_tracked_type finfo.ret_type then
        raise (TypeError (fdef.def_loc, Printf.sprintf
          "function '%s' returns an affine/linear value and must return explicitly on every path"
          fdef.name))
    end;
    let initial_region_taints = List.fold_left (fun taints (name, ty_opt) ->
      if accepts_region_borrow ty_opt then
        TaintEnv.set name (PathSet.singleton (PVar name)) taints
      else taints)
      TaintEnv.empty fdef.params
    in
    let (final_moved, _, _) = check_stmts mv_empty
      (List.fold_left (fun d (name, _) -> PathSet.add (PVar name) d)
         PathSet.empty fdef.params) initial_region_taints fdef.body
    in
    (* A plain LINEAR or MUST_USE parameter is an accepted all-path
       obligation. Affine parameters may be dropped; borrow never owns and
       sink is terminal. *)
    List.iter (fun (name, ty_opt) ->
      let owned_kind = match ty_opt with
        | Some (Ast.TypeBorrow _) | Some (Ast.TypeBorrowMut _)
        | Some (Ast.TypeSink _) -> None
        | Some ty when is_linear_type ty || is_must_use_type ty ->
            Some Ast.KindLinear
        | _ -> None
      in
      match owned_kind with
      | Some Ast.KindLinear when
          not (ResourceFlow.is_consumed_on_all_paths (PVar name) final_moved) ->
          let msg = if is_must_use_path (PVar name) then Printf.sprintf
            "must-use parameter '%s' is not handled on every path of this function"
            name
          else Printf.sprintf
            "linear parameter '%s' is not consumed on every path of this \
             function (forward it on every path, or take it as `sink` if \
             this function is meant to be its terminal consumer)" name in
          raise (TypeError (fdef.def_loc, msg))
      | _ -> ()
    ) fdef.params
  in
  List.iter (function Ast.FuncDef f -> check_affine_func f | _ -> ()) prog;
  (* Effects are checker-only facts. `may_block` and `unsafe` are transitive properties of
     direct calls and effect-contracted indirect calls; `interrupt` and
     `exception` are declaration roots. Their root contracts are checked
     separately. An unannotated
     function-pointer type remains unknown and is rejected below a checked
     non-blocking root rather than guessed safe. *)
  let (declared_effects, effect_names, effect_locs) =
    List.fold_left (fun (effects, names, locs) -> function
      | Ast.FuncDef f ->
          let key = overload_key f.name f.params in
          (StringMap.add key f.effects effects,
           StringMap.add key f.name names,
           StringMap.add key f.def_loc locs)
      | Ast.ExternFuncDef (name, params, _, effects_for_extern) ->
          let key = overload_key name params in
          (StringMap.add key effects_for_extern effects,
           StringMap.add key name names,
           StringMap.add key Lexing.dummy_pos locs)
      | _ -> (effects, names, locs)
    ) (StringMap.empty, StringMap.empty, StringMap.empty) prog
  in
  let callable_keys = StringMap.fold (fun key _ keys ->
    StringSet.add key keys) declared_effects StringSet.empty in
  inferred_effect_locs := effect_locs;
  let summarize_effect_body body =
    let callees = ref StringSet.empty in
    let calls_interrupt_wait = ref false in
    let calls_blocking_indirect = ref false in
    let contains_unsafe = ref false in
    let calls_unsafe_indirect = ref false in
    let has_unknown_indirect_call = ref false in
    let rec visit_expr (e : Ast.expr) =
      match e.desc with
      | Ast.Call (name, args) ->
          List.iter visit_expr args;
          if name = "interrupt_wait" then
            calls_interrupt_wait := true
          else
            let target = Option.value
              (StringMap.find_opt (loc_key e.loc) !resolved_call_targets)
              ~default:name in
            if StringSet.mem target callable_keys then
              callees := StringSet.add target !callees
            else if not (is_compiler_builtin name) then
              (match StringMap.find_opt (loc_key e.loc)
                       !resolved_indirect_call_effects with
               | Some (Some effects) ->
                   if List.mem "may_block" effects then
                     calls_blocking_indirect := true;
                   if List.mem "unsafe" effects then
                     calls_unsafe_indirect := true
               | Some None | None -> has_unknown_indirect_call := true)
      | Ast.VariantCtor (_, _, payload) -> visit_expr payload
      | Ast.BinOp (_, left, right) -> visit_expr left; visit_expr right
      | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x | Ast.Cast (_, x)
      | Ast.FieldGet (x, _) -> visit_expr x
      | Ast.Unsafe x -> contains_unsafe := true; visit_expr x
      | Ast.StructLit xs | Ast.TupleLit xs -> List.iter visit_expr xs
      | Ast.Index (_, index) -> visit_expr index
      | Ast.SliceOf (_, lo, hi) -> visit_expr lo; visit_expr hi
      | Ast.Assign (lhs, rhs) -> visit_expr lhs; visit_expr rhs
      | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.Var _
      | Ast.ViewLit _ | Ast.EnumVariant _ | Ast.SizeOf _ | Ast.OffsetOf _
      | Ast.EmbedFile _ -> ()
    and visit_stmt (s : Ast.stmt) =
      match s.desc with
      | Ast.Return (Some e) | Ast.Expr e | Ast.LetTuple (_, e) | Ast.Yield e ->
          visit_expr e
      | Ast.Return None -> ()
      | Ast.Block stmts -> List.iter visit_stmt stmts
      | Ast.UnsafeBlock stmts ->
          contains_unsafe := true; List.iter visit_stmt stmts
      | Ast.Let (_, _, _, init, _) -> Option.iter visit_expr init
      | Ast.If (condition, yes, no) ->
          visit_expr condition; List.iter visit_stmt yes; List.iter visit_stmt no
      | Ast.While (condition, stmts) ->
          visit_expr condition; List.iter visit_stmt stmts
      | Ast.For (_, _, lo, hi, stmts) ->
          visit_expr lo; visit_expr hi; List.iter visit_stmt stmts
      | Ast.ForEach (_, collection, stmts) ->
          visit_expr collection; List.iter visit_stmt stmts
      | Ast.Match (subject, arms) ->
          visit_expr subject;
          List.iter (function
            | Ast.ArmVariant (_, _, _, stmts) | Ast.ArmWild stmts
            | Ast.ArmIntLit (_, stmts) ->
                List.iter visit_stmt stmts) arms
      | Ast.LetMatch (_, _, _, subject, arms) ->
          visit_expr subject;
          List.iter (function
            | Ast.ArmVariant (_, _, _, stmts) | Ast.ArmWild stmts
            | Ast.ArmIntLit (_, stmts) ->
                List.iter visit_stmt stmts) arms
      | Ast.Break | Ast.Continue -> ()
    in
    List.iter visit_stmt body;
    (!callees, !calls_interrupt_wait, !calls_blocking_indirect,
     !contains_unsafe, !calls_unsafe_indirect, !has_unknown_indirect_call)
  in
  let effect_summaries = List.fold_left (fun summaries -> function
    | Ast.FuncDef f ->
        StringMap.add (overload_key f.name f.params)
          (summarize_effect_body f.body) summaries
    | _ -> summaries
  ) StringMap.empty prog in
  let explicit_may_block = StringMap.fold (fun key effects blocked ->
    match effects with
    | Some effects when List.mem "may_block" effects -> StringSet.add key blocked
    | _ -> blocked
  ) declared_effects StringSet.empty in
  let explicit_unsafe = StringMap.fold (fun key effects unsafe ->
    match effects with
    | Some effects when List.mem "unsafe" effects -> StringSet.add key unsafe
    | _ -> unsafe
  ) declared_effects StringSet.empty in
  let close_property seed direct_property =
    let rec loop current =
      let next = StringMap.fold
        (fun caller (callees, waits, blocking_indirect, direct_unsafe,
                     unsafe_indirect, unknown_indirect) acc ->
        if direct_property waits blocking_indirect direct_unsafe unsafe_indirect
             unknown_indirect
           || StringSet.exists (fun callee -> StringSet.mem callee acc) callees
        then StringSet.add caller acc
        else acc
      ) effect_summaries current in
      if StringSet.equal current next then current else loop next
    in
    loop seed
  in
  let may_block = close_property explicit_may_block
    (fun waits blocking_indirect _ _ _ -> waits || blocking_indirect) in
  let may_unsafe = close_property explicit_unsafe
    (fun _ _ direct_unsafe unsafe_indirect _ ->
      direct_unsafe || unsafe_indirect) in
  let may_reach_unknown = close_property StringSet.empty
    (fun _ _ _ _ unknown_indirect -> unknown_indirect) in
  let exception_roots = StringMap.fold (fun key effects roots ->
    match effects with
    | Some effects when List.mem "exception" effects -> StringSet.add key roots
    | _ -> roots
  ) declared_effects StringSet.empty in
  let display_effect_key key = Option.value
    (StringMap.find_opt key effect_names) ~default:key in
  let rec find_blocking_path visited key =
    if StringSet.mem key visited then None
    else if StringSet.mem key explicit_may_block then
      Some [display_effect_key key]
    else
      let visited = StringSet.add key visited in
      match StringMap.find_opt key effect_summaries with
      | Some (_, true, _, _, _, _) ->
          Some [display_effect_key key; "interrupt_wait"]
      | Some (_, false, true, _, _, _) ->
          Some [display_effect_key key; "<indirect call !{may_block}>"]
      | Some (callees, false, false, _, _, _) ->
          let rec search = function
            | [] -> None
            | callee :: rest ->
                if StringSet.mem callee may_block then
                  (match find_blocking_path visited callee with
                   | Some path -> Some (display_effect_key key :: path)
                   | None -> search rest)
                else search rest
          in
          search (StringSet.elements callees)
      | None -> None
  in
  let rec find_unknown_path visited key =
    if StringSet.mem key visited then None
    else
      let visited = StringSet.add key visited in
      match StringMap.find_opt key effect_summaries with
      | Some (_, _, _, _, _, true) ->
          Some [display_effect_key key; "<indirect call>"]
      | Some (callees, _, _, _, _, false) ->
          let rec search = function
            | [] -> None
            | callee :: rest ->
                if StringSet.mem callee may_reach_unknown then
                  (match find_unknown_path visited callee with
                   | Some path -> Some (display_effect_key key :: path)
                   | None -> search rest)
                else search rest
          in
          search (StringSet.elements callees)
      | None -> None
  in
  let find_exception_reentry_path root =
    let rec search visited key =
      if StringSet.mem key visited then None
      else
        let visited = StringSet.add key visited in
        match StringMap.find_opt key effect_summaries with
        | None -> None
        | Some (callees, _, _, _, _, _) ->
            let rec search_callees = function
              | [] -> None
              | callee :: rest ->
                  if StringSet.mem callee exception_roots then
                    Some [display_effect_key key; display_effect_key callee]
                  else
                    (match search visited callee with
                     | Some path -> Some (display_effect_key key :: path)
                     | None -> search_callees rest)
            in
            search_callees (StringSet.elements callees)
    in
    search StringSet.empty root
  in
  StringMap.iter (fun key effects_opt ->
    let effects = Option.value effects_opt ~default:[] in
    (match StringMap.find_opt key effect_summaries with
     | Some (_, _, _, true, _, _) when not (List.mem "unsafe" effects) ->
         raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
           "function '%s' contains an unsafe expression but does not declare !{unsafe}"
           (display_effect_key key)))
     | _ -> ());
    if List.mem "interrupt" effects then begin
      if StringSet.mem key may_block then begin
        let path = Option.value (find_blocking_path StringSet.empty key)
          ~default:[display_effect_key key] in
        raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
          "interrupt function '%s' may block via %s"
          (display_effect_key key) (String.concat " -> " path)))
      end;
      if StringSet.mem key may_reach_unknown then begin
        let path = Option.value (find_unknown_path StringSet.empty key)
          ~default:[display_effect_key key; "<indirect call>"] in
        raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
          "interrupt function '%s' reaches a call with unknown effects via %s"
          (display_effect_key key) (String.concat " -> " path)))
      end
    end else if List.mem "exception" effects then begin
      if StringSet.mem key may_block then begin
        let path = Option.value (find_blocking_path StringSet.empty key)
          ~default:[display_effect_key key] in
        raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
          "exception function '%s' may block via %s"
          (display_effect_key key) (String.concat " -> " path)))
      end;
      if StringSet.mem key may_reach_unknown then begin
        let path = Option.value (find_unknown_path StringSet.empty key)
          ~default:[display_effect_key key; "<indirect call>"] in
        raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
          "exception function '%s' reaches a call with unknown effects via %s"
          (display_effect_key key) (String.concat " -> " path)))
      end;
      (match find_exception_reentry_path key with
       | Some path ->
           raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
             "exception function '%s' may re-enter an exception root via %s"
             (display_effect_key key) (String.concat " -> " path)))
       | None -> ())
    end else if effects_opt = Some [] then begin
      if StringSet.mem key may_block then begin
        let path = Option.value (find_blocking_path StringSet.empty key)
          ~default:[display_effect_key key] in
        raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
          "function '%s' violates its explicit !{} non-blocking contract via %s"
          (display_effect_key key) (String.concat " -> " path)))
      end;
      if StringSet.mem key may_reach_unknown then begin
        let path = Option.value (find_unknown_path StringSet.empty key)
          ~default:[display_effect_key key; "<indirect call>"] in
        raise (TypeError (StringMap.find key effect_locs, Printf.sprintf
          "function '%s' cannot verify its explicit !{} non-blocking contract: unknown effects via %s"
          (display_effect_key key) (String.concat " -> " path)))
      end
    end
    (* GitHub issue #179 originally made an explicit effect contract
       (may_block/interrupt/exception/bare !{}) reject transitively
       reaching unsafe unless the contract also listed "unsafe" --
       REMOVED (see HISTORY.md's entry reversing this): unlike
       may_block/interrupt/exception, which are real control-flow/
       concurrency hazards a CALLER's own reasoning needs to compose
       with, unsafe here just means "one bounded, local proof was done
       by hand instead of by the type system." Mandating that it
       propagate through every explicitly-effect-declared caller in a
       real kernel (MMIO/syscalls/interrupts touch the outside world
       constantly) turned a single accepted-risk line into a forced
       rewrite of every explicit-contract function transitively above
       it -- confirmed concretely: marking kernel/lib/freelist.tkb's
       freelist_core_remove !{unsafe} required touching 9 files across
       process/page/address-space/tcp/fd_table before this reversal.
       --forbid-unsafe (bin/main.ml, unchanged) remains the opt-in,
       whole-program "prove zero unsafe anywhere" mode for a subtree
       that wants it; kernel/ does not enable it. The self-declaration
       requirement above (a function whose OWN body contains unsafe{}
       must say !{unsafe}) is unchanged -- that part is a local,
       zero-propagation, grep-visible marker at the definition site,
       not a composing effect. *)
  ) declared_effects;
  let functions = StringMap.mapi (fun key info ->
    let declared = match StringMap.find_opt key declared_effects with
      | Some (Some effects) -> effects
      | Some None | None -> []
    in
    let effects =
      (if List.mem "interrupt" declared then ["interrupt"] else [])
      @ (if List.mem "exception" declared then ["exception"] else [])
      @ (if StringSet.mem key may_block then ["may_block"] else [])
      @ (if StringSet.mem key may_unsafe then ["unsafe"] else [])
    in
    { info with effects }
  ) functions in
  (* Deferred until AFTER Pass 3, same reasoning as check_undetermined_lets
     for locals: a global's type can be pinned not only by another global
     (the `Var vname` cross-reference case above) but also by a FUNCTION
     BODY'S usage (`let g = 1; fn f() i32 { return g; }` -- g's type is
     only ever determined by f's own return-type unification, which Pass
     3 performs). Checking right after Pass 2 (as first attempted)
     rejected that as a false positive; checking here, after everything
     that could ever constrain a global has run, does not. LetDef now
     carries its own declaration loc (issue #108's private-global
     enforcement needed it), so this reports the real position instead of
     the Lexing.dummy_pos placeholder other whole-program global checks
     still use. *)
  List.iter (function
    | Ast.LetDef (name, None, _, _, _, _, loc) ->
        (match StringMap.find_opt name genv with
         | Some (ty, _) when is_undetermined ty ->
             raise (TypeError (loc, Printf.sprintf
               "cannot determine a concrete type for global '%s': add an \
                explicit type annotation (e.g. `: i32`) -- this language \
                does not default an undetermined integer type" name))
         | _ -> ())
    | _ -> ()
  ) prog;
  let enums = StringMap.map (fun (underlying, variants, _) ->
    { underlying; variants }
  ) eenv in
  {
    globals   = StringMap.map (fun (ty, _) -> to_ast ty) genv;
    functions;
    structs   = senv;
    enums;
    call_targets = !resolved_call_targets;
  }
