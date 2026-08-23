(* Hindley-Milner type representation with unification variables *)

type ty =
  | TBool
  | TI8  | TI16 | TI32 | TI64
  | TU8  | TU16 | TU32 | TU64
  | TU16Be  (* u16be: 16-bit value stored in big-endian (wire) byte order.
               Does not unify with TU16 -- GitHub issue #186, see Ast.TypeU16Be. *)
  | TU32Be  (* u32be: 32-bit big-endian; same rules as TU16Be, see Ast.TypeU32Be. *)
  | TIsize  (* pointer-sized signed integer *)
  | TUsize  (* pointer-sized unsigned integer; maps to i64 on 64-bit targets *)
  | TVoid
  | TFun of ty list * ty * string list option
    (* param types, return type, checker-only call-effect contract.
       None = unknown; Some [] = explicitly non-blocking. *)
  | TVar of tv ref
  | TPtr of ty            (* *T    -- regular pointer, non-volatile *)
  | TIo  of ty            (* io T  -- volatile-qualified value type; *io T = TPtr(TIo T) *)
  | TArray of ty * int    (* array type: [T; N] *)
  | TStruct of string     (* named struct type *)
  | TView of string * static_term list
    (* Erased affine/linear permission value with checker-only indices. *)
  | TVariant of string * static_term list
    (* tagged runtime sum; kind is derived from payloads. The static
       argument list (GitHub issue #345) is erased, exactly like TView's
       and TIndexedStruct's -- it exists so a case payload can name the
       variant's own static parameter, and is unified positionally the
       same way those are. Empty for every variant that does not declare
       static parameters. *)
  | TExists of string * Ast.type_expr * static_term * ty
    (* Binder name, static sort, bound static term, payload schema. The
       binder is erased; a runtime owner retains its ordinary layout and an
       erased-view payload contributes no runtime field. *)
  | TIndexedStruct of string * static_term list
    (* First-class runtime struct carrying erased static indices. *)
  | TSingleton of ty * static_term
    (* Runtime value paired with an erased static name for that value. *)
  | TRefinedInt of int * int * ty
    (* {lo..<hi} -- refined int with known range; lo <= x < hi. Third field
       is the underlying primitive type this range is tied to (always one
       of TI8/TI16/TI32/TI64/TU8/TU16/TU32/TU64/TIsize/TUsize -- enforced by
       construction discipline, not the type system, same as this
       project's other "shape guaranteed by construction site, not by a
       dedicated variant" conventions, e.g. Const_env's bare-IntLit-only
       recording). Determines both the LLVM representation width (was
       unconditionally i32 before this field existed; see CLAUDE.md's
       "Refinement Numerical Type: Width/Signedness-Aware TRefinedInt"
       section) and signedness (is_unsigned reads it directly) for
       operations -- comparisons, shifts, extension direction -- performed
       on a refined value. Source annotations require the explicit
       `{lo..<hi as base}` syntax; bare `{lo..<hi}` is currently rejected.
       Range propagation preserves an already-typed operand's base (e.g.
       `u64_var & 0xff` produces a TU64-based {0..<256}), and a for-loop
       counter follows its bounds/annotation base. Array and slice indices
       therefore use TUsize-based refinements, while raw-pointer offsets use
       TIsize-based refinements. *)
  | TTuple of ty list     (* (T1, T2, ...) -- function-local product value
                             (OWNERSHIP_KERNEL.md 5.9, GitHub issue #120):
                             exists in returns/params/locals/literals only,
                             never in storage (fields/arrays/globals). Kind
                             = join of component kinds -- see type_inf. *)
  | TSlice of ty * int    (* []T / [T; N..] -- fat pointer (ptr + usize len);
                             int = compile-time minimum length (0 = unknown) *)
  | TAlignedPtr of int * ty
    (* *align(N) T -- a pointer PROVABLY a multiple of N bytes (GitHub issue
       #102). The pointer analogue of TRefinedInt: N is a compile-time
       constant, never a unification variable (enforced by construction,
       same discipline as TRefinedInt's own lo/hi/base). Subtyping (see
       unify below) mirrors TRefinedInt's one-directional pattern exactly:
       *align(N) T flows freely into a plain *T (widening) or a
       *align(K) T where K divides N; a plain *T or an insufficiently
       aligned pointer flowing into a *align(N) T position is rejected. *)
  | TRef of ty            (* &T -- shared, non-arithmetic reference (GitHub
                              issue #314/#319). Structurally distinct from
                              TPtr, not a qualifier on it. Widens freely
                              (one direction only) into a plain TPtr; the
                              reverse needs an explicit unsafe cast. *)
  | TRefMut of ty          (* &mut T -- exclusive reference: same as TRef,
                               plus field writes. Widens freely into TRef
                               (reborrow-as-shared) and into TPtr. *)

and tv =
  | Unbound of int  (* unresolved unification variable *)
  | Link    of ty   (* resolved: points to another type *)

and static_term =
  | SConst of int
  | SEnum of string * string
    (* Nominal finite-enum state. The runtime discriminant is deliberately
       not used as its identity: A::Ready and B::Ready remain distinct even
       if both happen to lower to zero. *)
  | SParam of int * string
    (* Rigid while checking a universally quantified function body. *)
  | SVar of static_var ref

and static_var =
  | SUnbound of int
  | SLink of static_term

(* -- Unification variables ------------------------------------------------- *)

exception TypeError of Ast.loc * string

(* GitHub issue #327 Stage 1: raised by Type_inf.infer_program once, after
   Pass 3 (function-body inference) has attempted EVERY function rather
   than aborting at the first failure, so a single compilation can report
   every independently-broken function in one run instead of one per
   edit-rebuild cycle. Always non-empty; callers should treat it the same
   way they treat a single TypeError, just report every entry instead of
   one. *)
exception MultiTypeError of (Ast.loc * string) list

let next_id = ref 0
let next_static_id = ref 0

let fresh () =
  incr next_id;
  TVar (ref (Unbound !next_id))

let fresh_static () =
  incr next_static_id;
  SVar (ref (SUnbound !next_static_id))

let rigid_static name =
  incr next_static_id;
  SParam (!next_static_id, name)

(* GitHub issue #266: the OLD "__value%d" name is an internal counter with
   no source-level meaning -- static_to_string prints an SParam's own name
   verbatim, so a "static value mismatch" error naming one of these leaked
   the raw counter straight into user-facing output (e.g. "static value
   mismatch: __value136 vs desc"), found porting kernel/drivers/net/
   virtio_net.tkb: an intermediate `let idx: {0..<8 as usize} = reply.index;`
   binding loses reply.index's own `@ desc` tie, and the fresh identity
   minted for `idx` here is what a later mismatch actually names. This
   message is deliberately generic (not a proposal to redesign static-value
   unification, just its diagnostic text for this one failure mode) --
   fresh_named_rigid_static below gives the one call site that already
   knows a source name (an immutable Var whose own identity was never
   established) a much more specific version of it. *)
let fresh_rigid_static () =
  incr next_static_id;
  SParam (!next_static_id, "an anonymous compile-time value")

(* Same as fresh_rigid_static, but for the one call site that already has
   the source-level variable name in hand -- names the actual construct
   responsible instead of falling back to the fully generic message. *)
let fresh_named_rigid_static name =
  incr next_static_id;
  SParam (!next_static_id, Printf.sprintf
    "an anonymous compile-time value (from '%s' -- possibly an \
     intermediate `let` binding that lost its own static identity)" name)

type static_scope = (string, static_term) Hashtbl.t

let create_static_scope () : static_scope = Hashtbl.create 8
let bind_static (scope : static_scope) name term = Hashtbl.replace scope name term

let static_in_scope (scope : static_scope) name =
  match Hashtbl.find_opt scope name with
  | Some t -> t
  | None ->
      let t = rigid_static name in
      Hashtbl.add scope name t;
      t

let rec static_repr = function
  | SVar ({ contents = SLink t } as r) ->
      let t' = static_repr t in
      r := SLink t';
      t'
  | t -> t

let static_to_string t =
  match static_repr t with
  | SConst n -> string_of_int n
  | SEnum (name, case) -> Printf.sprintf "%s::%s" name case
  | SParam (_, name) -> name
  | SVar { contents = SUnbound id } -> Printf.sprintf "__static%d" id
  | SVar { contents = SLink _ } -> assert false

(* Follow Link chains, applying path compression *)
let rec repr = function
  | TVar ({ contents = Link t } as r) ->
      let t' = repr t in r := Link t'; t'
  | t -> t

(* GitHub issue #239 companion to of_ast_in_scope's Ast.type_expr-level
   check: guards the `ty`-level minting sites (array decay, address-of)
   where a *T is constructed directly from an already-resolved `ty`
   rather than from an Ast.type_expr annotation, so of_ast_in_scope's
   check alone would not see it. Same io-qualifier-stripping rule. *)
let rec is_ty_pointer_shaped t =
  match repr t with
  | TPtr _ | TAlignedPtr _ -> true
  | TIo t -> is_ty_pointer_shaped t
  | _ -> false

let rec to_string t =
  match repr t with
  | TBool -> "bool"
  | TI8   -> "i8"  | TI16 -> "i16" | TI32 -> "i32" | TI64 -> "i64"
  | TU8   -> "u8"  | TU16 -> "u16" | TU32 -> "u32" | TU64 -> "u64"
  | TU16Be -> "u16be"
  | TU32Be -> "u32be"
  | TIsize -> "isize"
  | TUsize -> "usize"
  | TVoid -> "void"
  | TPtr t -> Printf.sprintf "*%s" (to_string t)   (* *io T prints as "*io T" via TPtr(TIo T) *)
  | TIo  t -> Printf.sprintf "io %s" (to_string t)
  | TArray (t, n) -> Printf.sprintf "[%s; %d]" (to_string t) n
  | TSlice (t, 0) -> Printf.sprintf "[]%s" (to_string t)
  | TSlice (t, n) -> Printf.sprintf "[%s; %d..]" (to_string t) n
  | TAlignedPtr (n, t) -> Printf.sprintf "*align(%d) %s" n (to_string t)
  | TRef t -> Printf.sprintf "&%s" (to_string t)
  | TRefMut t -> Printf.sprintf "&mut %s" (to_string t)
  | TFun (ps, r, effects) ->
      let suffix = match effects with
        | None -> ""
        | Some es -> Printf.sprintf " !{%s}" (String.concat ", " es)
      in
      Printf.sprintf "(%s) -> %s%s"
        (String.concat ", " (List.map to_string ps)) (to_string r) suffix
  | TStruct s -> s
  | TView (s, []) -> Printf.sprintf "view %s" s
  | TView (s, args) ->
      Printf.sprintf "view %s[%s]" s
        (String.concat ", " (List.map static_to_string args))
  | TVariant (s, []) -> Printf.sprintf "variant %s" s
  | TVariant (s, args) ->
      Printf.sprintf "variant %s[%s]" s
        (String.concat ", " (List.map static_to_string args))
  | TExists (name, sort, _, body) ->
      Printf.sprintf "exists %s: %s. %s" name
        (Ast.show_type_expr sort) (to_string body)
  | TIndexedStruct (s, args) ->
      Printf.sprintf "%s[%s]" s
        (String.concat ", " (List.map static_to_string args))
  | TSingleton (base, n) ->
      Printf.sprintf "%s @ %s" (to_string base) (static_to_string n)
  | TTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map to_string ts))
  | TRefinedInt (lo, hi, _) -> Printf.sprintf "{%d..<%d}" lo hi
  | TVar { contents = Unbound id } -> Printf.sprintf "'t%d" id
  | TVar { contents = Link _ }     -> assert false

(* -- Unification ----------------------------------------------------------- *)

exception Unify_error of string

let rec occurs rv = function
  | TVar { contents = Link t } -> occurs rv t
  | TVar r                     -> r == rv
  | TFun (ps, r, _)            -> List.exists (occurs rv) ps || occurs rv r
  | TPtr   t                   -> occurs rv t
  | TIo    t                   -> occurs rv t
  | TArray (t, _)              -> occurs rv t
  | TSlice (t, _)              -> occurs rv t
  | TAlignedPtr (_, t)         -> occurs rv t
  | TRef t | TRefMut t         -> occurs rv t
  | TTuple ts                  -> List.exists (occurs rv) ts
  | TExists (_, _, _, t)       -> occurs rv t
  | TIndexedStruct _           -> false
  | TSingleton (t, _)          -> occurs rv t
  | TStruct _ | TView _ | TVariant _ -> false
  | _                          -> false

let rec function_effect_rows t =
  match repr t with
  | TFun (params, ret, effects) ->
      effects
      :: (List.concat_map function_effect_rows params
          @ function_effect_rows ret)
  | TPtr t | TIo t | TArray (t, _) | TSlice (t, _)
  | TAlignedPtr (_, t) | TSingleton (t, _)
  | TRef t | TRefMut t -> function_effect_rows t
  | TTuple ts -> List.concat_map function_effect_rows ts
  | TExists (_, _, _, body) -> function_effect_rows body
  | _ -> []

let require_writable_pointer_effect_invariance t1 t2 =
  let rows1 = function_effect_rows t1 in
  let rows2 = function_effect_rows t2 in
  if rows1 <> rows2
     && (List.exists Option.is_some rows1 || List.exists Option.is_some rows2)
  then
    raise (Unify_error
      "function-pointer effect contracts are invariant behind writable pointers")

(* Replace one static_term (a TExists binder, either a rigid SParam or an
   SVar) with another throughout a ty. Shared by unify's own TExists-vs-
   TExists alpha-equivalence check (aligning the two binders before
   comparing bodies) and by instantiate_exists_ty below (opening a sealed
   existential for packing -- see its own comment). *)
let rec subst_static_term old replacement term =
  match static_repr old, static_repr term with
  | SParam (old_id, _), SParam (id, _) when old_id = id -> replacement
  | SVar old_r, SVar r when old_r == r -> replacement
  | _, term -> term
and subst_in_ty old replacement t =
  match repr t with
  | TFun (ps, r, effects) ->
      TFun (List.map (subst_in_ty old replacement) ps,
            subst_in_ty old replacement r, effects)
  | TPtr t -> TPtr (subst_in_ty old replacement t)
  | TIo t -> TIo (subst_in_ty old replacement t)
  | TArray (t, n) -> TArray (subst_in_ty old replacement t, n)
  | TRefinedInt (lo, hi, base) ->
      TRefinedInt (lo, hi, subst_in_ty old replacement base)
  | TTuple ts -> TTuple (List.map (subst_in_ty old replacement) ts)
  | TSlice (t, n) -> TSlice (subst_in_ty old replacement t, n)
  | TAlignedPtr (n, t) -> TAlignedPtr (n, subst_in_ty old replacement t)
  | TRef t -> TRef (subst_in_ty old replacement t)
  | TRefMut t -> TRefMut (subst_in_ty old replacement t)
  | TIndexedStruct (name, args) ->
      TIndexedStruct (name, List.map (subst_static_term old replacement) args)
  | TView (name, args) ->
      TView (name, List.map (subst_static_term old replacement) args)
  | TVariant (name, args) ->
      TVariant (name, List.map (subst_static_term old replacement) args)
  | TSingleton (base, n) ->
      TSingleton (subst_in_ty old replacement base,
                  subst_static_term old replacement n)
  | TExists (name, sort, binder, body) ->
      TExists (name, sort, binder, subst_in_ty old replacement body)
  | t -> t

(* `TExists`'s own binder is a SEALED name -- unifying a value directly
   against its body would compare that value's witness against this ONE
   specific rigid parameter and (correctly) always fail, since two
   different rigid witnesses can never unify. Both directions substitute
   a fresh replacement for the binder throughout the body first, but they
   need different KINDS of fresh term:
   - Introduction/pack (a value flowing INTO an existential-typed target,
     e.g. LetMatch's `x = payload;` (type_inf.ml's Assign case), or
     VariantCtor's own instantiate_exists over the AST form before a
     value even has a `ty`): a solvable SVar. The actual value's witness
     is discovered BY unifying against it -- this is what lets a caller
     write `x = p;` without ever having to spell out `page` explicitly.
   - Elimination/open (an existential-typed value flowing OUT to be used,
     e.g. passing a LetMatch-bound `exists page. PageOwner[page]` local
     as a plain `PageOwner[page]` argument): a rigid SParam, exactly like
     open_payload's match-arm payload binding already uses for the same
     reason -- the callee must never be able to discover, or accidentally
     get unified with, a concrete or otherwise-unrelated witness. *)
let instantiate_exists_ty ~witness t =
  match repr t with
  | TExists (_, _, binder, body) -> subst_in_ty binder witness body
  | t -> t

let pack_exists_ty t = instantiate_exists_ty ~witness:(fresh_static ()) t
let open_exists_ty t = instantiate_exists_ty ~witness:(rigid_static "_") t

let rec unify t1 t2 =
  match repr t1, repr t2 with
  | TBool, TBool | TVoid, TVoid -> ()
  | TI8,  TI8  | TI16, TI16 | TI32, TI32 | TI64, TI64 -> ()
  | TU8,  TU8  | TU16, TU16 | TU32, TU32 | TU64, TU64 -> ()
  | TU16Be, TU16Be -> ()
  | TU32Be, TU32Be -> ()
  | TIsize, TIsize -> ()
  | TUsize, TUsize -> ()
  | TPtr t1, TPtr t2 ->
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2
  | TIo  t1, TIo  t2 -> unify t1 t2
  | TArray (t1, n1), TArray (t2, n2) ->
      if n1 <> n2 then
        raise (Unify_error (Printf.sprintf "array size mismatch: %d vs %d" n1 n2));
      unify t1 t2
  | TFun (ps1, r1, effects1), TFun (ps2, r2, effects2) ->
      if List.length ps1 <> List.length ps2 then
        raise (Unify_error "argument count mismatch");
      List.iter2 unify ps1 ps2;
      unify r1 r2;
      (match effects1, effects2 with
       | _, None -> ()
       | None, Some _ ->
           raise (Unify_error
             "function pointer has unknown effects; an explicit effect contract is required here")
       | Some actual, Some expected ->
           let unexpected = List.filter (fun eff ->
             not (List.mem eff expected)) actual in
           if unexpected <> [] then
             raise (Unify_error (Printf.sprintf
               "function pointer may have effect%s %s, which the destination contract does not allow"
               (if List.length unexpected = 1 then "" else "s")
               (String.concat ", " unexpected))))
  | TRefinedInt (lo1, hi1, base1), TRefinedInt (lo2, hi2, base2) ->
      (* A stronger proof is a subtype of a weaker one: [lo1, hi1) may
         flow to [lo2, hi2) exactly when it is contained by it. Requiring
         identical ranges made additional flow analysis paradoxically
         break valid callers (e.g. a condition proving {129..<513} could
         no longer satisfy a parameter asking only for {0..<513}). *)
      if lo1 < lo2 || hi1 > hi2 then
        raise (Unify_error (Printf.sprintf
          "refined int range mismatch: {%d..<%d} vs {%d..<%d}" lo1 hi1 lo2 hi2));
      unify base1 base2
  (* Slice subtyping mirrors TRefinedInt's: a slice whose proven minimum
     length is LARGER can be used where a smaller minimum is expected
     (actual guarantee is stronger). unify's call sites pass (actual,
     expected) -- Call args, Assign, Return all follow that order. The
     reverse direction is the anti-subtyping guard: an unproven/shorter
     slice cannot flow into a position demanding a longer minimum. *)
  | TSlice (e1, m1), TSlice (e2, m2) ->
      if m1 < m2 then
        raise (Unify_error (Printf.sprintf
          "cannot pass %s where %s is required; \
           narrow with if (s.len >= %d) { ... } or a constant subslice"
          (to_string (TSlice (e1, m1))) (to_string (TSlice (e2, m2))) m2));
      unify e1 e2
  (* GitHub issue #186: TU16Be is deliberately NOT one of the ordinary
     integer bases the generic range-fit rules just below apply to. Those
     rules are base-BLIND (they only check whether the numeric range fits,
     not which base produced it), so without these two arms placed first,
     a refined wire-endian value would silently widen into an ordinary
     integer type purely because its range happens to fit -- exactly the
     accidental-host-order-use this type exists to prevent. Must come
     before the generic rules so OCaml's first-match-wins order catches it. *)
  | TRefinedInt (lo, hi, TU16Be), TU16Be when lo >= 0 && hi <= 65536 -> ()
  | TRefinedInt (_, _, TU16Be), (TU8|TU16|TU32|TU64|TUsize|TI8|TI16|TI32|TI64|TIsize|TU32Be) ->
      raise (Unify_error
        "cannot use a wire-endian {..<.. as u16be} value as a plain integer \
         type; convert with `as u16` first")
  | TRefinedInt (lo, _, TU32Be), TU32Be when lo >= 0 -> ()
  | TRefinedInt (_, _, TU32Be), (TU8|TU16|TU32|TU64|TUsize|TI8|TI16|TI32|TI64|TIsize|TU16Be) ->
      raise (Unify_error
        "cannot use a wire-endian {..<.. as u32be} value as a plain integer \
         type; convert with `as u32` first")
  (* Subtyping: TRefinedInt(lo, hi, base) is a subtype of any integer type
     where the range fits, REGARDLESS of its own base -- this check is
     purely about whether the VALUE range fits the target's representable
     range; coerce (llvm_gen.ml) already handles any width/sign mismatch
     between base and the target via ordinary narrow/widen. One direction
     only: refined -> wider type is OK; unproven wider type -> refined is NG. *)
  | TRefinedInt _, TI32 -> ()                           (* i32: always fits (i32 range) *)
  | TRefinedInt _, TI64  -> ()                          (* i64: i32 range always fits *)
  | TRefinedInt _, TIsize -> ()                         (* surface ranges fit signed 32-bit *)
  | TRefinedInt (lo, hi, _), TU8  when lo >= 0 && hi <= 256     -> ()
  | TRefinedInt (lo, hi, _), TU16 when lo >= 0 && hi <= 65536   -> ()
  | TRefinedInt (lo, _, _),  TU32 when lo >= 0                  -> ()   (* practical: hi < 2^31 *)
  | TRefinedInt (lo, _, _),  TU64 when lo >= 0                  -> ()
  | TRefinedInt (lo, _, _),  TUsize when lo >= 0                -> ()
  | TRefinedInt (lo, hi, _), TI8  when lo >= -128  && hi <= 128 -> ()
  | TRefinedInt (lo, hi, _), TI16 when lo >= -32768 && hi <= 32768 -> ()
  | t1, TRefinedInt (lo, hi, base) when t1 = repr base ->
      (* Anti-subtyping guard, generalized from the old TI32-only case: an
         UNPROVEN value of exactly the refined type's own base cannot flow
         into a position demanding a proven range. A value of a genuinely
         DIFFERENT type falls through to the generic "cannot unify"
         mismatch below instead. `base` is a NESTED field inside the
         already-repr'd t2, so it is not itself guaranteed dereferenced --
         must repr it again before comparing (t1 is already repr'd, via
         the outer `match repr t1, repr t2 with`). *)
      raise (Unify_error (Printf.sprintf
        "cannot pass unproven %s where {%d..<%d} is required; \
         use if (v >= %d && v < %d) { ... } to narrow the range"
        (to_string t1) lo hi lo hi))
  (* Pointer alignment (GitHub issue #102): same one-directional subtyping
     shape as TRefinedInt just above. *align(N) T* proves the address is a
     multiple of N; a stricter proof (N a multiple of the required K) or a
     widening to a plain, unqualified *T* is always fine. An UNPROVEN plain
     pointer (or one proven to a non-multiple alignment) flowing into an
     *align(N) T* position is rejected with a hint toward this type's three
     proof sources (see infer_expr's Cast/AddrOf/BinOp handling in
     type_inf.ml) rather than the generic "cannot unify" fallback. *)
  | TAlignedPtr (n1, t1), TAlignedPtr (n2, t2) ->
      if n1 mod n2 <> 0 then
        raise (Unify_error (Printf.sprintf
          "cannot pass *align(%d) %s where *align(%d) %s is required \
           (%d is not a multiple of %d)"
          n1 (to_string t1) n2 (to_string t2) n1 n2));
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2
  | TAlignedPtr (_, t1), TPtr t2 ->
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2  (* widening to a plain pointer is always OK *)
  | TPtr t1, TAlignedPtr (n, t2) when t1 = repr t2 ->
      raise (Unify_error (Printf.sprintf
        "cannot pass unproven %s where *align(%d) %s is required; use `&x` \
         on an align(%d) variable, a literal address, pointer arithmetic by \
         a multiple of %d, or `unsafe { ... as *align(%d) %s }` to mark it"
        (to_string (TPtr t1)) n (to_string t2) n n n (to_string t2)))
  (* GitHub issue #314/#319: &T/&mut T is a genuinely separate type from
     TPtr, not a qualifier on it -- see the `ty` constructor's own comment.
     Subtyping is one-directional, mirroring TAlignedPtr's shape: a
     reference always widens into a plain pointer (an address that is
     real, non-forged, and never was arithmetic'd is trivially a valid
     plain pointer), and &mut T additionally reborrows as &T. The reverse
     directions (TPtr -> TRef/TRefMut, TRef -> TRefMut) are deliberately
     absent here; going from a raw pointer to a reference requires an
     explicit `unsafe` cast (see type_inf.ml's Cast case), and a shared
     reference can never become exclusive. *)
  | TRef t1, TRef t2 ->
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2
  | TRefMut t1, TRefMut t2 ->
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2
  | TRefMut t1, TRef t2 ->
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2
  | TRef t1, TPtr t2 | TRefMut t1, TPtr t2 ->
      require_writable_pointer_effect_invariance t1 t2;
      unify t1 t2  (* widening to a plain pointer is always OK *)
  | TTuple ts1, TTuple ts2 ->
      if List.length ts1 <> List.length ts2 then
        raise (Unify_error (Printf.sprintf
          "tuple arity mismatch: %s vs %s"
          (to_string (TTuple ts1)) (to_string (TTuple ts2))));
      List.iter2 unify ts1 ts2
  | TIndexedStruct (s1, args1), TIndexedStruct (s2, args2) ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "struct type mismatch: %s vs %s" s1 s2));
      if List.length args1 <> List.length args2 then
        raise (Unify_error (Printf.sprintf
          "static argument count mismatch for %s: %d vs %d"
          s1 (List.length args1) (List.length args2)));
      List.iter2 unify_static args1 args2
  | TSingleton (base1, n1), TSingleton (base2, n2) ->
      unify base1 base2;
      unify_static n1 n2
  | (TSingleton _ as singleton), TVar rv ->
      (* Preserve a value's static identity when an inferred binding has
         not acquired a type yet.  Letting the widening rule below see the
         unresolved TVar would retain only the runtime base type, so
         `let y = x` could silently forget `x`'s singleton fact. *)
      (match !rv with
       | Link t -> unify singleton t
       | Unbound _ ->
           if occurs rv singleton then
             raise (Unify_error (Printf.sprintf
               "infinite type: %s occurs in %s"
               (to_string (TVar rv)) (to_string singleton)));
           rv := Link singleton)
  | TSingleton (base, _), expected ->
      (* Forgetting a singleton fact is a safe widening. The reverse
         direction is intentionally absent: an arbitrary runtime value
         does not prove a requested static identity. *)
      unify base expected
  | TStruct s1, TStruct s2 ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "struct type mismatch: %s vs %s" s1 s2))
  | TView (s1, args1), TView (s2, args2) ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "view type mismatch: %s vs %s" s1 s2));
      if List.length args1 <> List.length args2 then
        raise (Unify_error (Printf.sprintf
          "static argument count mismatch for view %s: %d vs %d"
          s1 (List.length args1) (List.length args2)));
      List.iter2 unify_static args1 args2
  | TVariant (s1, args1), TVariant (s2, args2) ->
      if s1 <> s2 then
        raise (Unify_error (Printf.sprintf "variant type mismatch: %s vs %s" s1 s2));
      if List.length args1 <> List.length args2 then
        raise (Unify_error (Printf.sprintf
          "static argument count mismatch for variant %s: %d vs %d"
          s1 (List.length args1) (List.length args2)));
      List.iter2 unify_static args1 args2
  | TExists (_, sort1, binder1, body1),
    TExists (_, sort2, binder2, body2) ->
      if sort1 <> sort2 then
        raise (Unify_error "existential static sort mismatch");
      unify body1 (subst_in_ty binder2 binder1 body2)
  | TVar rv, t | t, TVar rv ->
      (match !rv with
       | Link t' -> unify t' t
       | Unbound _ ->
           if occurs rv t then
             raise (Unify_error (Printf.sprintf
               "infinite type: %s occurs in %s"
               (to_string (TVar rv)) (to_string t)));
           rv := Link t)
  (* One side is an existential, the other a concrete/fresh-metavariable
     shape (not itself TExists, and not an unbound TVar -- that already
     matched above and must keep taking priority so plain type inference
     is unaffected). Structural contexts can nest an already-existential
     value inside another expected existential shape without ever
     reading it back out again -- e.g. VariantCtor packing a tuple of
     LetMatch-bound existential locals into a variant case whose payload
     schema existentially quantifies each tuple slot itself. Packing
     (fresh SVar, not rigid) is the right default here: this is a
     structural fit check, not a use site, so nothing needs the stronger
     "can never be unified with anything else" guarantee a genuine open
     (see open_exists_ty) provides. *)
  | TExists _, t2 -> unify (pack_exists_ty t1) t2
  | t1, TExists _ -> unify t1 (pack_exists_ty t2)
  | t1, t2 ->
      raise (Unify_error (Printf.sprintf "cannot unify %s with %s"
        (to_string t1) (to_string t2)))

and unify_static s1 s2 =
  match static_repr s1, static_repr s2 with
  | SConst a, SConst b when a = b -> ()
  | SEnum (enum1, case1), SEnum (enum2, case2)
      when enum1 = enum2 && case1 = case2 -> ()
  | SParam (a, _), SParam (b, _) when a = b -> ()
  | SVar r1, SVar r2 when r1 == r2 -> ()
  | SVar r, t | t, SVar r ->
      (match !r with
       | SLink t' -> unify_static t' t
       | SUnbound _ -> r := SLink t)
  | a, b ->
      raise (Unify_error (Printf.sprintf "static value mismatch: %s vs %s"
        (static_to_string a) (static_to_string b)))

(* -- Conversion to/from Ast types ----------------------------------------- *)

let static_of_ast scope = function
  | Ast.StaticName name -> static_in_scope scope name
  | Ast.StaticInt n -> SConst n
  | Ast.StaticEnum (name, case) -> SEnum (name, case)

(* GitHub issue #239: reject *T where T is itself pointer-shaped, i.e. two
   levels of raw pointer indirection (written * *T, *align(N) *T, *io *T,
   and so on). Nested indirection introduces ownership/lifetime/provenance
   questions the language does not otherwise need to solve, and no kernel
   code needs it (a repo-wide survey found zero genuine uses). `io` is a
   qualifier, not a pointer layer, so it is stripped before checking --
   `*io T` stays legal as long as T itself is not pointer-shaped. *)
let rec is_pointer_shaped = function
  | Ast.TypePtr _ | Ast.TypeAlignedPtr _ -> true
  | Ast.TypeIo t -> is_pointer_shaped t
  | _ -> false

let reject_nested_pointer t =
  if is_pointer_shaped t then
    raise (TypeError (Lexing.dummy_pos,
      "nested pointer indirection (e.g. **T) is not allowed; \
       Takibi has no ownership/lifetime model for multi-level pointers \
       (GitHub issue #239)"))

let rec of_ast_in_scope scope = function
  | Ast.TypeBool     -> TBool
  | Ast.TypeI8       -> TI8  | Ast.TypeI16 -> TI16 | Ast.TypeI32 -> TI32 | Ast.TypeI64 -> TI64
  | Ast.TypeU8       -> TU8  | Ast.TypeU16 -> TU16 | Ast.TypeU32 -> TU32 | Ast.TypeU64 -> TU64
  | Ast.TypeU16Be    -> TU16Be
  | Ast.TypeU32Be    -> TU32Be
  | Ast.TypeIsize    -> TIsize
  | Ast.TypeUsize    -> TUsize
  | Ast.TypeVoid     -> TVoid
  | Ast.TypePtr   t      -> reject_nested_pointer t; TPtr   (of_ast_in_scope scope t)
  | Ast.TypeIo    t      -> TIo (of_ast_in_scope scope t)
  | Ast.TypeArray (t, n) -> TArray (of_ast_in_scope scope t, n)
  | Ast.TypeFn (ps, r, effects) ->
      TFun (List.map (of_ast_in_scope scope) ps,
            of_ast_in_scope scope r, effects)
  | Ast.TypeNamed s      -> TStruct s
  | Ast.TypeView (s, args) ->
      TView (s, List.map (static_of_ast scope) args)
  | Ast.TypeVariant (s, args) ->
      TVariant (s, List.map (static_of_ast scope) args)
  | Ast.TypeExists (name, sort, body) ->
      let inner_scope = Hashtbl.copy scope in
      let binder = rigid_static name in
      bind_static inner_scope name binder;
      TExists (name, sort, binder, of_ast_in_scope inner_scope body)
  | Ast.TypeIndexed (s, args) ->
      TIndexedStruct (s, List.map (static_of_ast scope) args)
  | Ast.TypeSingleton (base, n) ->
      TSingleton (of_ast_in_scope scope base, static_of_ast scope n)
  | Ast.TypeRefined (lo, hi, base) ->
      TRefinedInt (lo, hi, of_ast_in_scope scope base)
  | Ast.TypeSlice (t, n) -> TSlice (of_ast_in_scope scope t, n)
  | Ast.TypeTuple ts -> TTuple (List.map (of_ast_in_scope scope) ts)
  | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeSink t ->
      of_ast_in_scope scope t
  | Ast.TypeAlignedPtr (n, t) -> reject_nested_pointer t; TAlignedPtr (n, of_ast_in_scope scope t)
  | Ast.TypeRef t -> TRef (of_ast_in_scope scope t)
  | Ast.TypeRefMut t -> TRefMut (of_ast_in_scope scope t)
  | Ast.TypeKind ->
      raise (TypeError (Lexing.dummy_pos,
        "'type' is only valid as a generic parameter's declared type; \
         generics are not implemented yet (GitHub issue #207)"))
  | Ast.TypeGenericInst (name, _) ->
      raise (TypeError (Lexing.dummy_pos, Printf.sprintf
        "'%s(...)' is a generic instantiation, which is not implemented \
         yet (GitHub issue #207)" name))
  | Ast.TypeIntLit _ ->
      raise (TypeError (Lexing.dummy_pos,
        "BUG: a bare generic value argument reached type inference \
         unresolved -- Monomorphize.run should have substituted it"))
  | Ast.TypeArraySym _ ->
      raise (TypeError (Lexing.dummy_pos,
        "BUG: a symbolic generic array size reached type inference \
         unresolved -- Monomorphize.run should have substituted it"))
  | Ast.TypeSliceSym _ ->
      raise (TypeError (Lexing.dummy_pos,
        "BUG: a symbolic generic slice minimum reached type inference \
         unresolved -- Monomorphize.run should have substituted it"))

let of_ast t = of_ast_in_scope (create_static_scope ()) t

(* None -> fresh unification variable *)
let of_ast_opt = function
  | Some t -> of_ast t
  | None   -> fresh ()

(* Return type: None means void; annotation required for non-void returns *)
let ret_of_ast_opt = function
  | Some t -> of_ast t
  | None   -> TVoid

let of_ast_opt_in_scope scope = function
  | Some t -> of_ast_in_scope scope t
  | None -> fresh ()

let ret_of_ast_opt_in_scope scope = function
  | Some t -> of_ast_in_scope scope t
  | None -> TVoid

let instantiate_static_params ty =
  let subst : (int, static_term) Hashtbl.t = Hashtbl.create 8 in
  let rec inst_static t =
    match static_repr t with
    | (SConst _ | SEnum _) as t -> t
    | SVar _ as t -> t
    | SParam (id, _) ->
        (match Hashtbl.find_opt subst id with
         | Some t -> t
         | None ->
             let t = fresh_static () in
             Hashtbl.add subst id t;
             t)
  and inst t =
    match repr t with
    | TFun (ps, r, effects) -> TFun (List.map inst ps, inst r, effects)
    | TPtr t -> TPtr (inst t)
    | TIo t -> TIo (inst t)
    | TArray (t, n) -> TArray (inst t, n)
    | TRefinedInt (lo, hi, base) -> TRefinedInt (lo, hi, inst base)
    | TTuple ts -> TTuple (List.map inst ts)
    | TSlice (t, n) -> TSlice (inst t, n)
    | TAlignedPtr (n, t) -> TAlignedPtr (n, inst t)
    | TRef t -> TRef (inst t)
    | TRefMut t -> TRefMut (inst t)
    | TIndexedStruct (name, args) ->
        TIndexedStruct (name, List.map inst_static args)
    | TView (name, args) -> TView (name, List.map inst_static args)
    | TVariant (name, args) -> TVariant (name, List.map inst_static args)
    | TSingleton (base, n) -> TSingleton (inst base, inst_static n)
    | TExists _ as t -> t
    | t -> t
  in
  inst ty

(* After unification, collapse to a concrete Ast type.
   Unbound variables default to int (unconstrained integer) *)
let rec to_ast t =
  match repr t with
  | TBool -> Ast.TypeBool
  | TI8   -> Ast.TypeI8  | TI16 -> Ast.TypeI16 | TI32 -> Ast.TypeI32 | TI64 -> Ast.TypeI64
  | TU8   -> Ast.TypeU8  | TU16 -> Ast.TypeU16 | TU32 -> Ast.TypeU32 | TU64 -> Ast.TypeU64
  | TU16Be -> Ast.TypeU16Be
  | TU32Be -> Ast.TypeU32Be
  | TIsize -> Ast.TypeIsize
  | TUsize -> Ast.TypeUsize
  | TVoid -> Ast.TypeVoid
  | TPtr   t      -> Ast.TypePtr  (to_ast t)
  | TIo    t      -> Ast.TypeIo   (to_ast t)
  | TArray (t, n) -> Ast.TypeArray (to_ast t, n)
  | TFun (ps, r, effects) -> Ast.TypeFn (List.map to_ast ps, to_ast r, effects)
  | TStruct s     -> Ast.TypeNamed s
  | TView (s, args) -> Ast.TypeView (s, List.map static_to_ast args)
  | TVariant (s, args) -> Ast.TypeVariant (s, List.map static_to_ast args)
  | TExists (name, sort, _, body) ->
      Ast.TypeExists (name, sort, to_ast body)
  | TIndexedStruct (s, args) ->
      Ast.TypeIndexed (s, List.map static_to_ast args)
  | TSingleton (base, n) -> Ast.TypeSingleton (to_ast base, static_to_ast n)
  | TRefinedInt (lo, hi, base) -> Ast.TypeRefined (lo, hi, to_ast base)
  | TSlice (t, n) -> Ast.TypeSlice (to_ast t, n)
  | TAlignedPtr (n, t) -> Ast.TypeAlignedPtr (n, to_ast t)
  | TRef t -> Ast.TypeRef (to_ast t)
  | TRefMut t -> Ast.TypeRefMut (to_ast t)
  | TTuple ts -> Ast.TypeTuple (List.map to_ast ts)
  | TVar { contents = Unbound _ } -> Ast.TypeI32
  | TVar { contents = Link _ }    -> assert false

and static_to_ast t =
  match static_repr t with
  | SConst n -> Ast.StaticInt n
  | SEnum (name, case) -> Ast.StaticEnum (name, case)
  | SParam (_, name) -> Ast.StaticName name
  | SVar { contents = SUnbound id } -> Ast.StaticName (Printf.sprintf "__static%d" id)
  | SVar { contents = SLink _ } -> assert false

(* -- Output structs passed to codegen ------------------------------------- *)

module StringMap = Map.Make(String)
module IntMap = Map.Make(Int)

type func_info = {
  ret_type    : Ast.type_expr;
  param_types : (string * Ast.type_expr) list;
  local_types : Ast.type_expr StringMap.t;
  bindings    : Local_bindings.resolution;
  binding_types : Ast.type_expr IntMap.t;
  effects     : string list;
  (* Inferred checker effects. These have no runtime representation. *)
}

type enum_info = {
  underlying : Ast.type_expr;         (* u8 / u16 / u32 / u64 *)
  variants   : (string * int) list;   (* [(variant_name, discriminant_value); ...] *)
}

type program_types = {
  globals   : Ast.type_expr StringMap.t;
  functions : func_info StringMap.t;
  structs   : ((string * Ast.type_expr) list * bool * int option) StringMap.t;
    (* fields, is_packed, align_bytes -- see lib/type_inf.ml's senv, which
       this is a direct passthrough of. *)
  enums     : enum_info StringMap.t;
  call_targets : string StringMap.t;
  (* struct name -> ordered field list [(field_name, field_type)] *)
  (* enum name  -> underlying type + variant list                 *)
}

let loc_key (loc : Ast.loc) =
  Printf.sprintf "%s:%d:%d" loc.Lexing.pos_fname loc.Lexing.pos_lnum
    (loc.Lexing.pos_cnum - loc.Lexing.pos_bol)
