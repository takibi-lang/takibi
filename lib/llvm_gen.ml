open Llvm
open Ast

exception Error of string

let context = global_context ()
let the_module = create_module context "takibi_module"
let builder = builder context

(* Counter for unique string literal global names *)
let str_counter = ref 0

(* Global tables -- populated during gen_program *)
(* Stores (ast_type, llvalue) for global variables *)
let global_vars : (string, Ast.type_expr * llvalue) Hashtbl.t = Hashtbl.create 16
(* Stores (function_lltype, llvalue) for declared functions *)
let functions   : (string, lltype * llvalue) Hashtbl.t = Hashtbl.create 16
(* Stores the return AST type for each function (needed when typing Call results) *)
let func_ret_ast_types : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 16
(* Stores the parameter AST types for each function (needed for function-as-value) *)
let func_param_ast_types : (string, Ast.type_expr list) Hashtbl.t = Hashtbl.create 16
(* Struct type registry: name -> LLVM struct lltype *)
let struct_lltypes : (string, lltype) Hashtbl.t = Hashtbl.create 8
(* Struct field registry: name -> ordered [(field_name, field_ast_type)] *)
let struct_fields  : (string, (string * Ast.type_expr) list) Hashtbl.t = Hashtbl.create 8

(* Locals are either immutable SSA values or mutable alloca pointers *)
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* direct SSA value -- no alloca *)
  | Mut of Ast.type_expr * llvalue  (* alloca pointer -- load/store *)

(* Collect per-variable bounds from an if-condition for codegen narrowing.
   Mirrors the logic in type_inf.ml:narrow_from_cond. *)
let collect_bounds_cond (cond : Ast.expr) =
  let take_lo a b = match a, b with
    | Some x, Some y -> Some (max x y)
    | Some _, None -> a | None, _ -> b in
  let take_hi a b = match a, b with
    | Some x, Some y -> Some (min x y)
    | Some _, None -> a | None, _ -> b in
  let update name lo_opt hi_opt acc =
    let (pl, ph) = match Types.StringMap.find_opt name acc with
      | Some p -> p | None -> (None, None) in
    Types.StringMap.add name (take_lo lo_opt pl, take_hi hi_opt ph) acc
  in
  let rec go e acc = match e.desc with
    | BinOp (And, e1, e2)                                     -> go e2 (go e1 acc)
    | BinOp (Ge, {desc=Var n;_}, {desc=IntLit lo;_})         -> update n (Some lo)     None          acc
    | BinOp (Gt, {desc=Var n;_}, {desc=IntLit lo;_})         -> update n (Some (lo+1)) None          acc
    | BinOp (Lt, {desc=Var n;_}, {desc=IntLit hi;_})         -> update n None          (Some hi)     acc
    | BinOp (Le, {desc=Var n;_}, {desc=IntLit hi;_})         -> update n None          (Some (hi+1)) acc
    | BinOp (Le, {desc=IntLit lo;_}, {desc=Var n;_})         -> update n (Some lo)     None          acc
    | BinOp (Lt, {desc=IntLit lo;_}, {desc=Var n;_})         -> update n (Some (lo+1)) None          acc
    | BinOp (Ge, {desc=IntLit hi;_}, {desc=Var n;_})         -> update n None          (Some (hi+1)) acc
    | BinOp (Gt, {desc=IntLit hi;_}, {desc=Var n;_})         -> update n None          (Some hi)     acc
    | _ -> acc
  in
  go cond Types.StringMap.empty

(* Temporarily narrow Imm locals based on condition bounds.
   Only Imm (immutable) bindings are narrowed; Mut bindings are skipped.
   Returns saved bindings for restoration after the then-branch. *)
let apply_narrowing (locals : (string, local_binding) Hashtbl.t) (cond : Ast.expr) =
  let bounds = collect_bounds_cond cond in
  Types.StringMap.fold (fun name (lo_opt, hi_opt) saved ->
    match lo_opt, hi_opt with
    | Some lo, Some hi ->
        (match Hashtbl.find_opt locals name with
         | Some (Imm (_, v) as old) ->
             Hashtbl.replace locals name (Imm (TypeRefined (lo, hi), v));
             (name, old) :: saved
         | _ -> saved)
    | _ -> saved
  ) bounds []

let restore_narrowing (locals : (string, local_binding) Hashtbl.t) saved =
  List.iter (fun (name, old) -> Hashtbl.replace locals name old) saved

(* Module-level table for Mut binding narrowing from if-conditions.
   Compilation is single-threaded, so a module-level Hashtbl is safe.
   gen_expr cannot access locals directly, so type overrides are passed through here. *)
let narrowing_ctx : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 4

(* Record narrowed types for Mut bindings into narrowing_ctx.
   Returns [(name, old_opt)] -- pass to restore_narrowing_mut after the then-branch. *)
let apply_narrowing_mut (locals : (string, local_binding) Hashtbl.t) (cond : Ast.expr) =
  let bounds = collect_bounds_cond cond in
  Types.StringMap.fold (fun name (lo_opt, hi_opt) saved ->
    match lo_opt, hi_opt with
    | Some lo, Some hi ->
        (match Hashtbl.find_opt locals name with
         | Some (Mut (TypeI32, _)) ->
             let old = Hashtbl.find_opt narrowing_ctx name in
             Hashtbl.replace narrowing_ctx name (TypeRefined (lo, hi));
             (name, old) :: saved
         | _ -> saved)
    | _ -> saved
  ) bounds []

let restore_narrowing_mut saved =
  List.iter (fun (name, old_opt) ->
    match old_opt with
    | None     -> Hashtbl.remove narrowing_ctx name
    | Some old -> Hashtbl.replace narrowing_ctx name old
  ) saved

let setup_target ?(triple = "") () =
  let _ = Llvm_all_backends.initialize () in
  let triple = if triple = "" then Llvm_target.Target.default_triple () else triple in
  set_target_triple triple the_module;
  let target  = Llvm_target.Target.by_triple triple in
  let machine = Llvm_target.TargetMachine.create ~triple target in
  let layout  = Llvm_target.TargetMachine.data_layout machine in
  set_data_layout (Llvm_target.DataLayout.as_string layout) the_module;
  machine

(* Run IR-level optimization passes.
   - Vectorization is disabled: AArch64 bare-metal may lack NEON.
   - "default<O2>" includes the loop-idiom pass, which replaces memset/memcpy-like loops
     with calls to external symbols -- causing link errors in bare-metal (no stdlib).
   - Custom pipeline with only the necessary passes:
     * mem2reg              : promote allocas to SSA registers (prerequisite for later passes)
     * early-cse            : basic common subexpression elimination
     * simplifycfg          : dead branch elimination for constant OOB (icmp uge const,const -> false -> block removed)
     * instcombine          : constant folding and redundant instruction elimination
     * correlated-propagation: propagate i<N inside while(i<N){ arr[i] } loop bodies,
                               folding bounds-check icmp uge i, N to false
     * constraint-elimination: stronger constraint-based elimination (deduplicates range checks)
     * simplifycfg          : final cleanup of dead blocks *)
let run_optimizations machine =
  let opts = Llvm_passbuilder.create_passbuilder_options () in
  Llvm_passbuilder.passbuilder_options_set_loop_vectorization opts false;
  Llvm_passbuilder.passbuilder_options_set_slp_vectorization opts false;
  let pipeline =
    "function(mem2reg,early-cse,simplifycfg,\
              correlated-propagation,constraint-elimination,simplifycfg)"
  in
  (match Llvm_passbuilder.run_passes the_module pipeline machine opts with
   | Ok ()    -> ()
   | Error msg -> raise (Error (Printf.sprintf "IR optimization failed: %s" msg)));
  Llvm_passbuilder.dispose_passbuilder_options opts

let emit_object machine output_path =
  run_optimizations machine;
  Llvm_target.TargetMachine.emit_to_file
    the_module
    Llvm_target.CodeGenFileType.ObjectFile
    output_path
    machine

(* -- Type helpers -------------------------------------------------------- *)

let rec ltype_of_ast = function
  | TypeBool        -> i1_type  context
  | TypeI8  | TypeU8  -> i8_type  context
  | TypeI16 | TypeU16 -> i16_type context
  | TypeI32 | TypeU32 -> i32_type context
  | TypeI64 | TypeU64 -> i64_type context
  | TypeVoid        -> void_type context
  | TypePtr _       -> pointer_type context   (* LLVM 19: all pointers are opaque ptr *)
  | TypeIo  t       -> ltype_of_ast t         (* io T is a value type: LLVM type is the same as T *)
  | TypeArray (t, n) -> array_type (ltype_of_ast t) n
  | TypeFn _        -> pointer_type context   (* function pointers are also opaque ptr *)
  | TypeRefined _   -> i32_type context       (* refined int is identical to i32 at the LLVM level *)
  | TypeNamed sname ->
      match Hashtbl.find_opt struct_lltypes sname with
      | Some llty -> llty
      | None -> raise (Error (Printf.sprintf "Unknown struct type: %s" sname))

(* True for unsigned integer types (use udiv/urem/icmp ult etc.) *)
let is_unsigned = function
  | TypeU8 | TypeU16 | TypeU32 | TypeU64 -> true
  | _ -> false

(* True for 64-bit integer types *)
let is_64bit = function
  | TypeI64 | TypeU64 -> true
  | _ -> false

(* Widen a loaded value to the arithmetic width (i32 or i64).
   i8/u8/i16/u16 -> i32 (C-style integer promotion).
   i32/u32/int   -> i32 (no-op for i32 values).
   i64/u64       -> i64 (keep as-is).
   Signed types use sext; unsigned types use zext. *)
let widen_load (ast_ty : Ast.type_expr) v =
  match ast_ty with
  | TypeI64 | TypeU64 -> v
  | TypeBool -> v
  | TypeI8 | TypeI16 | TypeI32 ->
      let dst = i32_type context in
      let src = type_of v in
      if src = dst then v
      else build_sext v dst "sext" builder
  | TypeU8 | TypeU16 | TypeU32 ->
      let dst = i32_type context in
      let src = type_of v in
      if src = dst then v
      else build_zext v dst "zext" builder
  | _ -> v

let ltype_of_ret_ast = function
  | TypeVoid -> void_type context
  | t        -> ltype_of_ast t

(* Coerce an llvalue to match a destination AST type.
   Invariant: arithmetic values arrive here at i32 (for <=32-bit types) or i64 (for 64-bit types).
   Handles truncation to narrow types, extension to i64, bool conversion,
   and integer -> pointer conversion (inttoptr) for MMIO addresses. *)
let rec coerce v (dst : Ast.type_expr) =
  let vty    = type_of v in
  let dst_ll = ltype_of_ast dst in
  if vty = dst_ll then v
  else match dst with
  | TypePtr _ ->
      let v64 =
        if   vty = i64_type context then v
        else build_zext v (i64_type context) "zext64" builder
      in
      build_inttoptr v64 (pointer_type context) "inttoptr" builder
  | TypeU8 | TypeI8 ->
      if vty = i32_type context || vty = i64_type context
      then build_trunc v (i8_type context) "trunc" builder
      else v
  | TypeU16 | TypeI16 ->
      if vty = i32_type context || vty = i64_type context
      then build_trunc v (i16_type context) "trunc" builder
      else v
  | TypeI32 | TypeU32 ->
      if vty = i64_type context then build_trunc v (i32_type context) "trunc" builder
      else if vty = i1_type  context then build_zext  v (i32_type context) "zext"  builder
      else if vty = pointer_type context then
        let i64v = build_ptrtoint v (i64_type context) "ptrtoint" builder in
        build_trunc i64v (i32_type context) "trunc" builder
      else build_zext v (i32_type context) "zext" builder
  | TypeI64 ->
      if vty = pointer_type context then
        build_ptrtoint v (i64_type context) "ptrtoint" builder
      else if vty = i32_type context then build_sext v (i64_type context) "sext" builder
      else build_zext v (i64_type context) "zext" builder
  | TypeU64 ->
      if vty = pointer_type context then
        build_ptrtoint v (i64_type context) "ptrtoint" builder
      else build_zext v (i64_type context) "zext" builder
  | TypeBool ->
      if vty = i1_type context then v
      else build_icmp Icmp.Ne v (const_int vty 0) "tobool" builder
  | TypeIo t    -> coerce v t
  | TypeVoid    -> v
  | TypeArray _ -> v
  | TypeFn _    -> v
  | TypeNamed _ -> v
  | TypeRefined _ -> coerce v TypeI32

(* Widen an integer value to i32 so arithmetic stays uniform (legacy helper for TypeInt/TypeChar).
   Does NOT touch pointer values. *)
let to_i32 v =
  let ty = type_of v in
  if ty = i32_type context || ty = pointer_type context then v
  else build_zext v (i32_type context) "zext" builder

(* Promote a value to its arithmetic width based on its AST type.
   <=32-bit types -> i32.  64-bit types -> i64.  bool -> i1 (unchanged).
   Replaces to_i32 for new explicit-width types. *)
let to_arith_width (ast_ty : Ast.type_expr) v = widen_load ast_ty v

(* Build an i1 condition from an integer or comparison result *)
let as_cond v =
  if type_of v = i1_type context then v
  else build_icmp Icmp.Ne v (const_int (i32_type context) 0) "tobool" builder

(* Look up a struct field by name; returns (field_index, field_ast_type) *)
let field_info struct_name fname =
  let fields = match Hashtbl.find_opt struct_fields struct_name with
    | Some fs -> fs
    | None -> raise (Error (Printf.sprintf "Unknown struct: %s" struct_name))
  in
  let rec find i = function
    | [] -> raise (Error (Printf.sprintf "No field '%s' in struct '%s'" fname struct_name))
    | (n, t) :: _ when n = fname -> (i, t)
    | _ :: rest -> find (i + 1) rest
  in
  find 0 fields

(* Pre-scan only mutable Let bindings -- immutable ones need no alloca.
   For-loop counters ("__for_<name>") are also pre-allocated here. *)
let rec collect_lets stmts =
  List.concat_map (fun s ->
    match s.desc with
    | Let (true, name, ty_opt, _) -> [(name, ty_opt)]
    | Block ss                    -> collect_lets ss
    | If (_, t, e)                -> collect_lets t @ collect_lets e
    | While (_, b)                -> collect_lets b
    | For (name, _, _, body)      -> ("__for_" ^ name, Some TypeI32) :: collect_lets body
    | _                           -> []
  ) stmts

(* -- resolve helpers: map AST annotation -> Ast.type_expr using HM results -- *)

let resolve_local_ast (pt : Types.program_types option) fname name ty_opt =
  let fallback = match ty_opt with Some t -> t | None -> TypeI32 in
  match pt with
  | None -> fallback
  | Some pt ->
      match Types.StringMap.find_opt fname pt.Types.functions with
      | None -> fallback
      | Some fi ->
          (match List.assoc_opt name fi.Types.param_types with
           | Some t -> t
           | None ->
               match Types.StringMap.find_opt name fi.Types.local_types with
               | Some t -> t
               | None   -> fallback)

let resolve_ret_ast (pt : Types.program_types option) fname ty_opt =
  let fallback = match ty_opt with Some t -> t | None -> TypeVoid in
  match pt with
  | None -> fallback
  | Some pt ->
      match Types.StringMap.find_opt fname pt.Types.functions with
      | None    -> fallback
      | Some fi -> fi.Types.ret_type

(* -- Bounds check --------------------------------------------------------- *)
(* Bounds check for [T; N] arrays. Traps via llvm.trap when idx >= N (unsigned compare).
   The unsigned compare also catches negative indices (idx < 0) as too-large unsigned values. *)
let emit_bounds_check idx_v n =
  let cur_f  = block_parent (insertion_block builder) in
  let oob_bb = append_block context "oob"    cur_f in
  let ok_bb  = append_block context "idx_ok" cur_f in
  let n_llv  = const_int (i32_type context) n in
  let cmp    = build_icmp Icmp.Uge idx_v n_llv "oob_cmp" builder in
  ignore (build_cond_br cmp oob_bb ok_bb builder);
  position_at_end oob_bb builder;
  let trap_ft = function_type (void_type context) [||] in
  let trap_fn = declare_function "llvm.trap" trap_ft the_module in
  ignore (build_call trap_ft trap_fn [||] "" builder);
  ignore (build_unreachable builder);
  position_at_end ok_bb builder

(* -- Expression codegen --------------------------------------------------- *)
(* Returns (ast_type, llvalue).  ast_type is needed for Deref to know
   the element type when emitting a load instruction (LLVM 19 opaque ptrs). *)

let rec gen_expr locals (e : Ast.expr) : Ast.type_expr * llvalue =
  match e.desc with
  | IntLit i ->
      (TypeRefined (i, i + 1), const_int (i32_type context) i)

  | BoolLit b ->
      (TypeBool, const_int (i1_type context) (if b then 1 else 0))

  | StringLit s ->
      (* Place the null-terminated byte sequence as a global constant array and return a pointer to its start *)
      incr str_counter;
      let name   = Printf.sprintf ".str%d" !str_counter in
      let len    = String.length s in
      let arr_ty = array_type (i8_type context) (len + 1) in
      let bytes  = Array.init (len + 1) (fun i ->
        if i < len then const_int (i8_type context) (Char.code s.[i])
        else             const_int (i8_type context) 0)
      in
      let arr    = const_array (i8_type context) bytes in
      let g      = define_global name arr the_module in
      set_global_constant true g;
      set_linkage Linkage.Private g;
      let zero   = const_int (i32_type context) 0 in
      let ptr    = build_in_bounds_gep arr_ty g [|zero; zero|] "strptr" builder in
      (TypePtr TypeU8, ptr)

  | Var name ->
      (match Hashtbl.find_opt locals name with
       | Some (Imm (ast_ty, v)) ->
           (ast_ty, to_arith_width ast_ty v)
       | Some (Mut (ast_ty, ptr)) ->
           (match ast_ty with
            | TypeArray (elem_ty, n) ->
                let arr_ll = array_type (ltype_of_ast elem_ty) n in
                let zero   = const_int (i32_type context) 0 in
                let ep = build_in_bounds_gep arr_ll ptr [|zero; zero|] (name ^ "_ptr") builder in
                (TypePtr elem_ty, ep)
            | TypeNamed _ ->
                (ast_ty, ptr)
            | TypeIo inner_ty ->
                let inst = build_load (ltype_of_ast inner_ty) ptr name builder in
                set_volatile true inst;
                (inner_ty, to_arith_width inner_ty inst)
            | _ ->
                let v = build_load (ltype_of_ast ast_ty) ptr name builder in
                (ast_ty, to_arith_width ast_ty v))
       | None ->
           (match Hashtbl.find_opt global_vars name with
            | Some (TypeArray (elem_ty, n), ptr) ->
                let arr_ll = array_type (ltype_of_ast elem_ty) n in
                let zero   = const_int (i32_type context) 0 in
                let ep = build_in_bounds_gep arr_ll ptr [|zero; zero|] (name ^ "_ptr") builder in
                (TypePtr elem_ty, ep)
            | Some (TypeNamed _ as ast_ty, ptr) ->
                (ast_ty, ptr)
            | Some (TypeIo inner_ty, ptr) ->
                let inst = build_load (ltype_of_ast inner_ty) ptr name builder in
                set_volatile true inst;
                (inner_ty, to_arith_width inner_ty inst)
            | Some (ast_ty, ptr) ->
                let v = build_load (ltype_of_ast ast_ty) ptr name builder in
                (ast_ty, to_arith_width ast_ty v)
            | None ->
                (* Use function name as a function pointer value *)
                match Hashtbl.find_opt functions name with
                | Some (_, f) ->
                    let param_asts = match Hashtbl.find_opt func_param_ast_types name with
                      | Some ps -> ps | None -> []
                    in
                    let ret_ast = match Hashtbl.find_opt func_ret_ast_types name with
                      | Some r -> r | None -> TypeVoid
                    in
                    (TypeFn (param_asts, ret_ast), f)
                | None ->
                    raise (Error (Printf.sprintf "Undefined variable: %s" name))))

  | Deref e1 ->
      let (ty1, v1) = gen_expr locals e1 in
      (match ty1 with
       | TypePtr (TypeIo inner_ty) ->
           let inst = build_load (ltype_of_ast inner_ty) v1 "deref" builder in
           set_volatile true inst;
           (inner_ty, to_arith_width inner_ty inst)
       | TypePtr inner_ty ->
           let inst = build_load (ltype_of_ast inner_ty) v1 "deref" builder in
           (inner_ty, to_arith_width inner_ty inst)
       | _ -> raise (Error "dereference of non-pointer type"))

  | AddrOf inner ->
      (match inner.desc with
       | Var name ->
           (match Hashtbl.find_opt locals name with
            | Some (Mut (ast_ty, alloca)) -> (TypePtr ast_ty, alloca)
            | Some (Imm _) ->
                raise (Error (Printf.sprintf "BUG: addrof immutable '%s' (should be caught by type_inf)" name))
            | None ->
                (* Global variable address: LLVM global value is already a pointer *)
                match Hashtbl.find_opt global_vars name with
                | Some (ast_ty, ptr) -> (TypePtr ast_ty, ptr)
                | None -> raise (Error (Printf.sprintf "cannot take address of '%s'" name)))
       | FieldGet (base_expr, fname) ->
           (* &expr.field -- get a pointer to the field via GEP (no load) *)
           let (base_ty, base_v) = gen_expr locals base_expr in
           let sname = match base_ty with
             | TypeNamed s        -> s
             | TypePtr (TypeNamed s) -> s
             | _ -> raise (Error (Printf.sprintf
                 "field address '.%s' on non-struct type" fname))
           in
           let (idx, field_ty) = field_info sname fname in
           let llty = Hashtbl.find struct_lltypes sname in
           let field_ptr = build_in_bounds_gep llty base_v
             [| const_int (i32_type context) 0; const_int (i32_type context) idx |]
             (fname ^ "_addr") builder
           in
           (TypePtr field_ty, field_ptr)
       | _ ->
           raise (Error "& requires a variable or struct field"))

  | BinOp (op, e1, e2) ->
      let (ty1, v1) = gen_expr locals e1 in
      let (ty2, v2) = gen_expr locals e2 in
      (match op with
       | Add ->
           (* Pointer arithmetic: ptr + int -> GEP. *io T = TypePtr(TypeIo T) also matches TypePtr *)
           (match ty1 with
            | TypePtr inner ->
                (ty1, build_gep (ltype_of_ast inner) v1 [|v2|] "ptradd" builder)
            | _ ->
                (match ty2 with
                 | TypePtr inner ->
                     (ty2, build_gep (ltype_of_ast inner) v2 [|v1|] "ptradd" builder)
                 | _ ->
                     (* Range propagation: {a..<b} + k -> {a+k..<b+k} (symmetric with type_inf.ml) *)
                     let sum = build_add v1 v2 "addtmp" builder in
                     let ret_ty = match ty1, e2.desc with
                       | TypeRefined (a, b), IntLit k -> TypeRefined (a + k, b + k)
                       | _ -> (match ty2, e1.desc with
                               | TypeRefined (c, d), IntLit k -> TypeRefined (c + k, d + k)
                               | _ -> TypeI32)
                     in
                     (ret_ty, sum)))
       | Sub ->
           (* Pointer arithmetic: ptr - int -> GEP with negated index *)
           (match ty1 with
            | TypePtr inner ->
                let neg = build_neg v2 "negtmp" builder in
                (ty1, build_gep (ltype_of_ast inner) v1 [|neg|] "ptrsub" builder)
            | _ ->
                (* Range propagation: {a..<b} - k -> {a-k..<b-k} (symmetric with type_inf.ml) *)
                let diff = build_sub v1 v2 "subtmp" builder in
                let ret_ty = match ty1, e2.desc with
                  | TypeRefined (a, b), IntLit k -> TypeRefined (a - k, b - k)
                  | _ -> TypeI32
                in
                (ret_ty, diff))
       | Mul -> (ty1, build_mul v1 v2 "multmp" builder)
       | Div ->
           let result = if is_unsigned ty1
                        then build_udiv v1 v2 "divtmp" builder
                        else build_sdiv v1 v2 "divtmp" builder
           in (ty1, result)
       | Lt ->
           let cmp = if is_unsigned ty1
                     then build_icmp Icmp.Ult v1 v2 "lttmp" builder
                     else build_icmp Icmp.Slt v1 v2 "lttmp" builder
           in (TypeBool, cmp)
       | Gt ->
           let cmp = if is_unsigned ty1
                     then build_icmp Icmp.Ugt v1 v2 "gttmp" builder
                     else build_icmp Icmp.Sgt v1 v2 "gttmp" builder
           in (TypeBool, cmp)
       | Le ->
           let cmp = if is_unsigned ty1
                     then build_icmp Icmp.Ule v1 v2 "letmp" builder
                     else build_icmp Icmp.Sle v1 v2 "letmp" builder
           in (TypeBool, cmp)
       | Ge ->
           let cmp = if is_unsigned ty1
                     then build_icmp Icmp.Uge v1 v2 "getmp" builder
                     else build_icmp Icmp.Sge v1 v2 "getmp" builder
           in (TypeBool, cmp)
       | Eq  -> (TypeBool, build_icmp Icmp.Eq v1 v2 "eqtmp" builder)
       | Ne  -> (TypeBool, build_icmp Icmp.Ne v1 v2 "netmp" builder)
       | Or  -> (TypeBool, build_or  (as_cond v1) (as_cond v2) "ortmp"   builder)
       | And -> (TypeBool, build_and (as_cond v1) (as_cond v2) "landtmp" builder)
       | Bor  -> (ty1, build_or  v1 v2 "bortmp" builder)
       | Bxor -> (ty1, build_xor v1 v2 "xortmp" builder)
       | Band -> (ty1, build_and v1 v2 "andtmp" builder)
       | Shr  ->
           let result = if is_unsigned ty1
                        then build_lshr v1 v2 "shrtmp" builder
                        else build_ashr v1 v2 "shrtmp" builder
           in (ty1, result)
       | Shl  -> (ty1, build_shl v1 v2 "shltmp" builder)
       (* Range propagation: n % m where m is a positive constant and n is guaranteed non-negative.
          Symmetric condition with type_inf.ml: relaxing only one side causes a mismatch. *)
       | Mod  ->
           let result = if is_unsigned ty1
                        then build_urem v1 v2 "modtmp" builder
                        else build_srem v1 v2 "modtmp" builder
           in
           let ret_ty = match e2.desc with
             | IntLit m when m > 0 ->
                 (match ty1 with
                  | TypeRefined (lo, _) when lo >= 0 -> TypeRefined (0, m)
                  | _ when is_unsigned ty1 -> TypeRefined (0, m)
                  | _ -> ty1)
             | _ -> ty1
           in
           (ret_ty, result))

  | Cast (target_ty, e) ->
      let (_, v) = gen_expr locals e in
      (target_ty, coerce v target_ty)

  | FieldGet (base_expr, fname) ->
      let (base_ty, base_v) = gen_expr locals base_expr in
      let (sname, through_io) = match base_ty with
        | TypeNamed s                      -> (s, false)
        | TypePtr   (TypeNamed s)          -> (s, false)
        | TypePtr   (TypeIo (TypeNamed s)) -> (s, true)   (* field access through *io Struct is volatile *)
        | _ -> raise (Error (Printf.sprintf
            "field access '.%s' on non-struct type" fname))
      in
      let (idx, field_ty) = field_info sname fname in
      let llty = Hashtbl.find struct_lltypes sname in
      let field_ptr = build_in_bounds_gep llty base_v
        [| const_int (i32_type context) 0; const_int (i32_type context) idx |]
        (fname ^ "_ptr") builder
      in
      (match field_ty with
       | TypeNamed _ ->
           (* Nested struct field: return the pointer as-is (same approach as array decay) *)
           (TypePtr field_ty, field_ptr)
       | TypeArray (elem_ty, _) ->
           (* Array field: return a pointer to the first element (same decay as local array variables) *)
           (TypePtr elem_ty, field_ptr)
       | TypeIo inner_ty ->
           let v = build_load (ltype_of_ast inner_ty) field_ptr fname builder in
           set_volatile true v;
           (inner_ty, to_arith_width inner_ty v)
       | _ ->
           let v = build_load (ltype_of_ast field_ty) field_ptr fname builder in
           if through_io then set_volatile true v;
           (field_ty, to_arith_width field_ty v))

  | Index (id, idx) ->
      let (idx_ty_raw, idx_raw) = gen_expr locals idx in
      let idx_v = to_i32 idx_raw in
      (* Prioritize Mut narrowing from narrowing_ctx (set by if-condition) when determining idx_ty *)
      let idx_ty = match idx.desc with
        | Var n -> (match Hashtbl.find_opt narrowing_ctx n with
                    | Some t -> t | None -> idx_ty_raw)
        | _ -> idx_ty_raw
      in
      (* Array load [T; N]: skip bounds check when TypeRefined proves safety *)
      let load_from_array elem_ty n arr_ptr =
        let needs_check = match idx_ty with
          | TypeRefined (lo, hi) -> lo < 0 || hi > n
          | _ -> true
        in
        if needs_check then emit_bounds_check idx_v n;
        let arr_ll = array_type (ltype_of_ast elem_ty) n in
        let zero   = const_int (i32_type context) 0 in
        let ep = build_in_bounds_gep arr_ll arr_ptr [|zero; idx_v|] "idx_ptr" builder in
        let v  = build_load (ltype_of_ast elem_ty) ep "idx_val" builder in
        (elem_ty, to_arith_width elem_ty v)
      in
      let load_through_ptr elem_ty ptr_v is_volatile =
        let ep = build_gep (ltype_of_ast elem_ty) ptr_v [|idx_v|] "idx_ptr" builder in
        let v  = build_load (ltype_of_ast elem_ty) ep "idx_val" builder in
        if is_volatile then set_volatile true v;
        (elem_ty, to_arith_width elem_ty v)
      in
      (match Hashtbl.find_opt locals id with
       | Some (Mut (TypeArray (elem_ty, n), ptr)) ->
           load_from_array elem_ty n ptr
       | Some (Mut (TypePtr (TypeIo elem_ty), alloca_ptr)) ->
           (* *io T variable: load pointer value from alloca, then volatile access *)
           let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
           load_through_ptr elem_ty ptr_v true
       | Some (Mut (TypePtr elem_ty, alloca_ptr)) ->
           let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
           load_through_ptr elem_ty ptr_v false
       | Some (Imm (TypePtr (TypeIo elem_ty), ptr_v)) ->
           load_through_ptr elem_ty ptr_v true
       | Some (Imm (TypePtr elem_ty, ptr_v)) ->
           load_through_ptr elem_ty ptr_v false
       | Some _ ->
           raise (Error (Printf.sprintf "Index: '%s' is not an array or pointer" id))
       | None ->
           (match Hashtbl.find_opt global_vars id with
            | Some (TypeArray (elem_ty, n), gptr) ->
                load_from_array elem_ty n gptr
            | Some (TypePtr (TypeIo elem_ty), gptr) ->
                let ptr_v = build_load (pointer_type context) gptr id builder in
                load_through_ptr elem_ty ptr_v true
            | Some (TypePtr elem_ty, gptr) ->
                let ptr_v = build_load (pointer_type context) gptr id builder in
                load_through_ptr elem_ty ptr_v false
            | Some _ ->
                raise (Error (Printf.sprintf "Index: '%s' is not an array or pointer" id))
            | None ->
                raise (Error (Printf.sprintf "Index: undefined variable '%s'" id))))

  | StructLit _ ->
      raise (Error "BUG: StructLit must be handled in gen_stmt / gen_global, not gen_expr")

  | Call (fname, args) ->
      (match Hashtbl.find_opt functions fname with
       | Some (ft, callee) ->
           let param_asts = match Hashtbl.find_opt func_param_ast_types fname with
             | Some ps -> ps | None -> []
           in
           let arg_vals =
             List.mapi (fun i a ->
               let (_, av) = gen_expr locals a in
               let param_ast = (try List.nth param_asts i with _ -> TypeI32) in
               coerce av param_ast
             ) args |> Array.of_list
           in
           let ret_lty = return_type ft in
           let call_name = if ret_lty = void_type context then "" else "calltmp" in
           let v = build_call ft callee arg_vals call_name builder in
           let ast_ret = match Hashtbl.find_opt func_ret_ast_types fname with
             | Some t -> t | None -> TypeI32
           in
           (ast_ret, v)
       | None ->
           (* Indirect call: local or global function pointer variable *)
           let (fn_ast_ty, fn_ptr) =
             match Hashtbl.find_opt locals fname with
             | Some (Imm (ast_ty, v)) -> (ast_ty, v)
             | Some (Mut (ast_ty, ptr)) ->
                 (ast_ty, build_load (ltype_of_ast ast_ty) ptr fname builder)
             | None ->
                 match Hashtbl.find_opt global_vars fname with
                 | Some (ast_ty, ptr) ->
                     (ast_ty, build_load (ltype_of_ast ast_ty) ptr fname builder)
                 | None ->
                     raise (Error (Printf.sprintf "Undefined function: %s" fname))
           in
           (match fn_ast_ty with
            | TypeFn (param_asts, ret_ast) ->
                let param_lls = List.map ltype_of_ast param_asts |> Array.of_list in
                let ret_ll    = ltype_of_ret_ast ret_ast in
                let ft        = function_type ret_ll param_lls in
                let arg_vals  =
                  List.map2 (fun a param_ast ->
                    coerce (snd (gen_expr locals a)) param_ast
                  ) args param_asts |> Array.of_list
                in
                let call_name = if ret_ll = void_type context then "" else "calltmp" in
                let v = build_call ft fn_ptr arg_vals call_name builder in
                (ret_ast, v)
            | _ ->
                raise (Error (Printf.sprintf
                  "'%s' is not a function or function pointer" fname))))

(* -- Function codegen ---------------------------------------------------- *)

let gen_func ?prog_types fdef =
  let res name ty_opt = resolve_local_ast prog_types fdef.name name ty_opt in

  let (_, f) =
    match Hashtbl.find_opt functions fdef.name with
    | Some x -> x
    | None ->
        let param_ast = List.map (fun (n, t) -> res n t) fdef.params in
        let param_lls = List.map ltype_of_ast param_ast |> Array.of_list in
        let ret_ast   = resolve_ret_ast prog_types fdef.name fdef.ret_type in
        let ret_ll    = ltype_of_ret_ast ret_ast in
        let ft        = function_type ret_ll param_lls in
        let f         = declare_function fdef.name ft the_module in
        Hashtbl.add functions fdef.name (ft, f);
        Hashtbl.add func_ret_ast_types fdef.name ret_ast;
        (ft, f)
  in

  let ret_ast = match Hashtbl.find_opt func_ret_ast_types fdef.name with
    | Some t -> t
    | None   -> TypeI32
  in

  let entry_bb = append_block context "entry" f in
  position_at_end entry_bb builder;

  (* locals maps name -> local_binding *)
  let locals : (string, local_binding) Hashtbl.t = Hashtbl.create 16 in

  (* Alloca + store for every parameter (params are always mutable) *)
  List.iteri (fun i (name, ty_opt) ->
    let ast_ty = res name ty_opt in
    let ptr    = build_alloca (ltype_of_ast ast_ty) name builder in
    ignore (build_store (param f i) ptr builder);
    Hashtbl.add locals name (Mut (ast_ty, ptr))
  ) fdef.params;

  (* Pre-alloca every mutable Let declared in the body *)
  List.iter (fun (name, ty_opt) ->
    if not (Hashtbl.mem locals name) then begin
      let ast_ty = res name ty_opt in
      let ptr    = build_alloca (ltype_of_ast ast_ty) name builder in
      Hashtbl.add locals name (Mut (ast_ty, ptr))
    end
  ) (collect_lets fdef.body);

  (* Recursively initialize a memory location from a possibly-nested literal.
     Handles nested StructLit for struct/array fields; falls back to gen_expr+store. *)
  let rec init_memory (ptr : llvalue) (ast_ty : Ast.type_expr) (e : Ast.expr) =
    match e.desc, ast_ty with
    | StructLit exprs, TypeNamed sname ->
        let llty = Hashtbl.find struct_lltypes sname in
        let fields = Hashtbl.find struct_fields sname in
        List.iteri (fun i ((_, ft), ei) ->
          let fptr = build_in_bounds_gep llty ptr
            [| const_int (i32_type context) 0; const_int (i32_type context) i |]
            ("fld" ^ string_of_int i) builder in
          init_memory fptr ft ei
        ) (List.combine fields exprs)
    | StructLit exprs, TypeArray (elem_ty, n) ->
        let arr_ll = array_type (ltype_of_ast elem_ty) n in
        List.iteri (fun i ei ->
          let ep = build_in_bounds_gep arr_ll ptr
            [| const_int (i32_type context) 0; const_int (i32_type context) i |]
            ("elem" ^ string_of_int i) builder in
          init_memory ep elem_ty ei
        ) exprs
    | _ ->
        let (_, v) = gen_expr locals e in
        ignore (build_store (coerce v ast_ty) ptr builder)
  in

  (* Stack of (break_bb, continue_bb) for the innermost enclosing loop.
     Pushed when entering While/For, popped on exit. *)
  let loop_stack : (llbasicblock * llbasicblock) Stack.t = Stack.create () in

  (* -- Statement codegen (defined here to access `res` for immutable lets) -- *)
  let rec gen_stmt (s : Ast.stmt) =
    (* Skip dead code after a terminator *)
    if block_terminator (insertion_block builder) <> None then ()
    else
    match s.desc with
    | Return e ->
        let (_, v) = gen_expr locals e in
        ignore (build_ret (coerce v ret_ast) builder)

    | Expr e ->
        ignore (gen_expr locals e)

    | Assign (name, e) ->
        let (_, v) = gen_expr locals e in
        (match Hashtbl.find_opt locals name with
         | Some (Mut (ast_ty, ptr)) ->
             let inst = build_store (coerce v ast_ty) ptr builder in
             (match ast_ty with TypeIo _ -> set_volatile true inst | _ -> ())
         | Some (Imm _) ->
             raise (Error (Printf.sprintf "BUG: assign to immutable '%s'" name))
         | None ->
             match Hashtbl.find_opt global_vars name with
             | Some (ast_ty, gvar) ->
                 let inst = build_store (coerce v ast_ty) gvar builder in
                 (match ast_ty with TypeIo _ -> set_volatile true inst | _ -> ())
             | None -> raise (Error (Printf.sprintf "Undefined variable: %s" name)))

    | AssignDeref (ptr_expr, val_expr) ->
        let (ptr_ty, ptr_v) = gen_expr locals ptr_expr in
        let (_, val_v)      = gen_expr locals val_expr in
        let (is_volatile, coerced) = match ptr_ty with
          | TypePtr (TypeIo inner) -> (true,  coerce val_v inner)   (* *io T: volatile store *)
          | TypePtr inner          -> (false, coerce val_v inner)   (* regular pointer: non-volatile *)
          | _                      -> (false, val_v)
        in
        let inst = build_store coerced ptr_v builder in
        if is_volatile then set_volatile true inst

    | AssignIndex (id, idx, rhs) ->
        let (idx_ty_raw, idx_raw) = gen_expr locals idx in
        let idx_v = to_i32 idx_raw in
        (* Prioritize Mut narrowing from narrowing_ctx (set by if-condition) when determining idx_ty *)
        let idx_ty = match idx.desc with
          | Var n -> (match Hashtbl.find_opt narrowing_ctx n with
                      | Some t -> t | None -> idx_ty_raw)
          | _ -> idx_ty_raw
        in
        let (_, rhs_v) = gen_expr locals rhs in
        let store_to_array elem_ty n arr_ptr =
          let needs_check = match idx_ty with
            | TypeRefined (lo, hi) -> lo < 0 || hi > n
            | _ -> true
          in
          if needs_check then emit_bounds_check idx_v n;
          let arr_ll = array_type (ltype_of_ast elem_ty) n in
          let zero   = const_int (i32_type context) 0 in
          let ep = build_in_bounds_gep arr_ll arr_ptr [|zero; idx_v|] "idx_ptr" builder in
          ignore (build_store (coerce rhs_v elem_ty) ep builder)
        in
        let store_through_ptr elem_ty ptr_v is_volatile =
          let ep = build_gep (ltype_of_ast elem_ty) ptr_v [|idx_v|] "idx_ptr" builder in
          let inst = build_store (coerce rhs_v elem_ty) ep builder in
          if is_volatile then set_volatile true inst
        in
        (match Hashtbl.find_opt locals id with
         | Some (Mut (TypeArray (elem_ty, n), ptr)) ->
             store_to_array elem_ty n ptr
         | Some (Mut (TypePtr (TypeIo elem_ty), alloca_ptr)) ->
             let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
             store_through_ptr elem_ty ptr_v true
         | Some (Mut (TypePtr elem_ty, alloca_ptr)) ->
             let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
             store_through_ptr elem_ty ptr_v false
         | Some (Imm (TypePtr (TypeIo elem_ty), ptr_v)) ->
             store_through_ptr elem_ty ptr_v true
         | Some (Imm (TypePtr elem_ty, ptr_v)) ->
             store_through_ptr elem_ty ptr_v false
         | Some _ ->
             raise (Error (Printf.sprintf "AssignIndex: '%s' is not an array or pointer" id))
         | None ->
             (match Hashtbl.find_opt global_vars id with
              | Some (TypeArray (elem_ty, n), gptr) ->
                  store_to_array elem_ty n gptr
              | Some (TypePtr (TypeIo elem_ty), gptr) ->
                  let ptr_v = build_load (pointer_type context) gptr id builder in
                  store_through_ptr elem_ty ptr_v true
              | Some (TypePtr elem_ty, gptr) ->
                  let ptr_v = build_load (pointer_type context) gptr id builder in
                  store_through_ptr elem_ty ptr_v false
              | Some _ ->
                  raise (Error (Printf.sprintf "AssignIndex: '%s' is not an array or pointer" id))
              | None ->
                  raise (Error (Printf.sprintf "AssignIndex: undefined variable '%s'" id))))

    | AssignField (base_expr, fname, val_expr) ->
        let (base_ty, base_v) = gen_expr locals base_expr in
        let sname = match base_ty with
          | TypeNamed s           -> s
          | TypePtr (TypeNamed s) -> s
          | _ -> raise (Error (Printf.sprintf
              "field assignment '.%s' on non-struct type" fname))
        in
        let (idx, field_ty) = field_info sname fname in
        let llty = Hashtbl.find struct_lltypes sname in
        let (_, val_v) = gen_expr locals val_expr in
        let field_ptr = build_in_bounds_gep llty base_v
          [| const_int (i32_type context) 0; const_int (i32_type context) idx |]
          (fname ^ "_ptr") builder
        in
        let inst = build_store (coerce val_v field_ty) field_ptr builder in
        (match field_ty with TypeIo _ -> set_volatile true inst | _ -> ())

    | Let (true, name, _, expr_opt) ->
        (* Mutable: alloca was pre-allocated; store the initial value via init_memory *)
        (match Hashtbl.find_opt locals name with
         | None -> raise (Error (Printf.sprintf "BUG: no alloca for %s" name))
         | Some (Mut (ast_ty, ptr)) ->
             Option.iter (init_memory ptr ast_ty) expr_opt
         | Some (Imm _) ->
             raise (Error (Printf.sprintf "BUG: %s marked mutable but stored as Imm" name)))

    | Let (false, name, ty_opt, expr_opt) ->
        (* Immutable: evaluate the init expr and store the SSA value directly *)
        (match expr_opt with
         | None ->
             raise (Error (Printf.sprintf "BUG: immutable '%s' has no initializer" name))
         | Some e ->
             let ast_ty = res name ty_opt in
             let (_, v) = gen_expr locals e in
             Hashtbl.add locals name (Imm (ast_ty, coerce v ast_ty)))

    | Block stmts ->
        List.iter gen_stmt stmts

    | If (cond, then_stmts, else_stmts) ->
        let cond_v   = as_cond (snd (gen_expr locals cond)) in
        let then_bb  = append_block context "then"  f in
        let else_bb  = append_block context "else"  f in
        let merge_bb = append_block context "merge" f in
        ignore (build_cond_br cond_v then_bb else_bb builder);

        position_at_end then_bb builder;
        let saved     = apply_narrowing     locals cond in
        let saved_mut = apply_narrowing_mut locals cond in
        List.iter gen_stmt then_stmts;
        restore_narrowing     locals saved;
        restore_narrowing_mut saved_mut;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br merge_bb builder);

        position_at_end else_bb builder;
        List.iter gen_stmt else_stmts;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br merge_bb builder);

        position_at_end merge_bb builder

    | Break ->
        let (break_bb, _) = Stack.top loop_stack in
        ignore (build_br break_bb builder)

    | Continue ->
        let (_, continue_bb) = Stack.top loop_stack in
        ignore (build_br continue_bb builder)

    | While (cond, body) ->
        let cond_bb  = append_block context "while_cond"  f in
        let body_bb  = append_block context "while_body"  f in
        let after_bb = append_block context "while_after" f in
        ignore (build_br cond_bb builder);

        position_at_end cond_bb builder;
        let cond_v = as_cond (snd (gen_expr locals cond)) in
        ignore (build_cond_br cond_v body_bb after_bb builder);

        position_at_end body_bb builder;
        Stack.push (after_bb, cond_bb) loop_stack;
        List.iter gen_stmt body;
        ignore (Stack.pop loop_stack);
        if block_terminator (insertion_block builder) = None then
          ignore (build_br cond_bb builder);

        position_at_end after_bb builder

    | For (name, lo_expr, hi_expr, body) ->
        (* Loop counter is pre-allocated in the entry block by collect_lets.
           The loop variable name is exposed to the body as an Imm binding (no reassignment).
           When both bounds are integer literals, assigns TypeRefined -> bounds check elision (Step 3.4). *)
        let (_, lo_v) = gen_expr locals lo_expr in
        let (_, hi_v) = gen_expr locals hi_expr in
        let lo_i32    = to_i32 lo_v in
        let hi_i32    = to_i32 hi_v in
        let ctr_name  = "__for_" ^ name in
        let ctr_ptr   = match Hashtbl.find_opt locals ctr_name with
          | Some (Mut (_, p)) -> p
          | _ -> raise (Error (Printf.sprintf "BUG: for counter '%s' not found" ctr_name))
        in
        ignore (build_store lo_i32 ctr_ptr builder);
        let cond_bb = append_block context "for_cond" f in
        let body_bb = append_block context "for_body" f in
        let incr_bb = append_block context "for_incr" f in
        let exit_bb = append_block context "for_exit" f in
        ignore (build_br cond_bb builder);

        position_at_end cond_bb builder;
        let i_val = build_load (i32_type context) ctr_ptr "for_i" builder in
        let cmp   = build_icmp Icmp.Slt i_val hi_i32 "for_cmp" builder in
        ignore (build_cond_br cmp body_bb exit_bb builder);

        position_at_end body_bb builder;
        let loop_ty = match lo_expr.desc, hi_expr.desc with
          | IntLit lo_k, IntLit hi_k -> TypeRefined (lo_k, hi_k)
          | _ -> TypeI32
        in
        Hashtbl.add locals name (Imm (loop_ty, i_val));
        Stack.push (exit_bb, incr_bb) loop_stack;
        List.iter gen_stmt body;
        ignore (Stack.pop loop_stack);
        Hashtbl.remove locals name;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br incr_bb builder);

        (* incr_bb: increment counter and loop back. continue jumps here.
           i_val is defined in cond_bb which dominates incr_bb, so the SSA use is valid. *)
        position_at_end incr_bb builder;
        let i_next = build_add i_val (const_int (i32_type context) 1) "for_next" builder in
        ignore (build_store i_next ctr_ptr builder);
        ignore (build_br cond_bb builder);

        position_at_end exit_bb builder
  in

  List.iter gen_stmt fdef.body;

  (* Ensure the exit block has a terminator *)
  if block_terminator (insertion_block builder) = None then begin
    if ret_ast = TypeVoid then ignore (build_ret_void builder)
    else ignore (build_ret (const_int (ltype_of_ast ret_ast) 0) builder)
  end;

  Llvm_analysis.assert_valid_function f;
  f

(* -- Top-level codegen --------------------------------------------------- *)

let gen_global ?prog_types name ty_opt expr_opt =
  let ast_ty = match prog_types with
    | None -> (match ty_opt with Some t -> t | None -> TypeI32)
    | Some (pt : Types.program_types) ->
        match Types.StringMap.find_opt name pt.Types.globals with
        | Some t -> t
        | None   -> (match ty_opt with Some t -> t | None -> TypeI32)
  in
  let llty = ltype_of_ast ast_ty in
  (* Recursively evaluate a compile-time constant expression. *)
  let rec eval_const (ft : Ast.type_expr) (e : Ast.expr) : llvalue =
    match e.desc, ft with
    | IntLit i, TypePtr _ ->
        const_inttoptr (const_int (i64_type context) i) (pointer_type context)
    | IntLit i, _ ->
        const_int (ltype_of_ast ft) i
    | StructLit exprs, TypeNamed sname ->
        let llty = match Hashtbl.find_opt struct_lltypes sname with
          | Some t -> t | None -> raise (Error (Printf.sprintf "unknown struct '%s'" sname))
        in
        let fields = match Hashtbl.find_opt struct_fields sname with
          | Some fs -> fs | None -> raise (Error (Printf.sprintf "unknown struct '%s'" sname))
        in
        const_named_struct llty
          (Array.of_list (List.map2 (fun (_, ft) e -> eval_const ft e) fields exprs))
    | StructLit exprs, TypeArray (elem_ty, _) ->
        let lelem = ltype_of_ast elem_ty in
        const_array lelem (Array.of_list (List.map (eval_const elem_ty) exprs))
    | _ -> raise (Error "global initializer: unsupported constant expression")
  in
  let init = match expr_opt with
    | Some e -> eval_const ast_ty e
    | None   -> undef llty  (* no initializer -> LLVM undef; startup.S zeroes BSS *)
  in
  let gvar = define_global name init the_module in
  Hashtbl.add global_vars name (ast_ty, gvar)

let declare_func ?prog_types fdef =
  if not (Hashtbl.mem functions fdef.name) then begin
    let res name ty_opt = resolve_local_ast prog_types fdef.name name ty_opt in
    let param_ast = List.map (fun (n, t) -> res n t) fdef.params in
    let param_lls = List.map ltype_of_ast param_ast |> Array.of_list in
    let ret_ast   = resolve_ret_ast prog_types fdef.name fdef.ret_type in
    let ret_ll    = ltype_of_ret_ast ret_ast in
    let ft        = function_type ret_ll param_lls in
    let f         = declare_function fdef.name ft the_module in
    Hashtbl.add functions fdef.name (ft, f);
    Hashtbl.add func_ret_ast_types fdef.name ret_ast;
    Hashtbl.add func_param_ast_types fdef.name param_ast
  end

let gen_program ?prog_types prog =
  (* Pass 0: register struct types -- must precede ltype_of_ast for TypeNamed *)
  List.iter (function
    | StructDef (name, fields) ->
        let field_lltys = List.map (fun (_, ty) -> ltype_of_ast ty) fields
                          |> Array.of_list in
        let llty = struct_type context field_lltys in
        Hashtbl.add struct_lltypes name llty;
        Hashtbl.add struct_fields  name fields
    | _ -> ()
  ) prog;
  (* Pass 1: register all globals and function signatures *)
  List.iter (function
    | FuncDef fdef                    -> declare_func ?prog_types fdef
    | LetDef (name, ty_opt, expr_opt) -> gen_global ?prog_types name ty_opt expr_opt
    | ExternFuncDef (name, params, ret_ty) ->
        if not (Hashtbl.mem functions name) then begin
          let param_ast = List.map (fun (_, t) -> match t with Some t -> t | None -> TypeI32) params in
          let param_lls = List.map ltype_of_ast param_ast |> Array.of_list in
          let ret_ast   = match ret_ty with Some t -> t | None -> TypeVoid in
          let ret_ll    = ltype_of_ret_ast ret_ast in
          let ft        = function_type ret_ll param_lls in
          let f         = declare_function name ft the_module in
          Hashtbl.add functions name (ft, f);
          Hashtbl.add func_ret_ast_types name ret_ast;
          Hashtbl.add func_param_ast_types name param_ast
        end
    | StructDef _ -> ()
  ) prog;
  (* Pass 2: generate function bodies *)
  List.iter (function
    | FuncDef fdef    -> ignore (gen_func ?prog_types fdef)
    | LetDef _        -> ()
    | ExternFuncDef _ -> ()
    | StructDef _     -> ()
  ) prog
