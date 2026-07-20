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
let current_program_types : Types.program_types option ref = ref None
(* Struct type registry: name -> LLVM struct lltype *)
let struct_lltypes : (string, lltype) Hashtbl.t = Hashtbl.create 8
(* Struct field registry: name -> ordered [(field_name, field_ast_type)] *)
let struct_fields  : (string, (string * Ast.type_expr) list) Hashtbl.t = Hashtbl.create 8
(* Struct type-level alignment registry: name -> N (set when struct has align(N)) *)
let struct_alignments : (string, int) Hashtbl.t = Hashtbl.create 4
(* Struct packed-ness registry: name -> is_packed. Used only by
   const_type_size/const_field_offset below (GitHub issue #77) -- every
   other codegen use of "is this struct packed" already goes through
   struct_lltypes (packed_struct_type vs. struct_type), so this table
   exists solely to let those two OCaml-arithmetic helpers answer the
   question without touching LLVM at all, mirroring type_inf.ml's senv. *)
let struct_is_packed : (string, bool) Hashtbl.t = Hashtbl.create 8

(* Erased views are checked as affine/linear resources by type_inf.ml but
   have no LLVM storage or ABI component. Source annotations initially parse
   as TypeNamed; this registry lets codegen resolve them even in the supported
   no-program_types test path. *)
let erased_view_names : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Closed runtime variants are nominal at the source level.  The source
   declaration table is populated before any function signature is lowered;
   the LLVM layout and per-case table are populated after structs/enums. *)
let variant_defs :
    (string, (string * Ast.type_expr option) list) Hashtbl.t =
  Hashtbl.create 8

type variant_case_layout = {
  variant_tag : int;
  variant_payload : Ast.type_expr option;
  variant_payload_field : int option;
}

let variant_lltypes : (string, lltype) Hashtbl.t = Hashtbl.create 8
let variant_cases_tbl :
    (string, (string * variant_case_layout) list) Hashtbl.t =
  Hashtbl.create 8

let rec resolve_special_type = function
  | TypeNamed name when Hashtbl.mem erased_view_names name -> TypeView (name, [])
  | TypeIndexed (name, args) when Hashtbl.mem erased_view_names name ->
      TypeView (name, args)
  | TypeNamed name when Hashtbl.mem variant_defs name -> TypeVariant name
  | TypePtr t -> TypePtr (resolve_special_type t)
  | TypeIo t -> TypeIo (resolve_special_type t)
  | TypeArray (t, n) -> TypeArray (resolve_special_type t, n)
  | TypeFn (args, ret, effects) ->
      TypeFn (List.map resolve_special_type args,
              resolve_special_type ret, effects)
  | TypeRefined (lo, hi, base) ->
      TypeRefined (lo, hi, resolve_special_type base)
  | TypeSlice (t, n) -> TypeSlice (resolve_special_type t, n)
  | TypeBorrow t -> TypeBorrow (resolve_special_type t)
  | TypeBorrowMut t -> TypeBorrowMut (resolve_special_type t)
  | TypeSink t -> TypeSink (resolve_special_type t)
  | TypeAlignedPtr (n, t) -> TypeAlignedPtr (n, resolve_special_type t)
  | TypeTuple ts -> TypeTuple (List.map resolve_special_type ts)
  | TypeSingleton (t, n) -> TypeSingleton (resolve_special_type t, n)
  | TypeExists (name, sort, body) ->
      TypeExists (name, resolve_special_type sort, resolve_special_type body)
  | t -> t

let rec is_erased_view_type = function
  | TypeView _ -> true
  | TypeExists (_, _, body) -> is_erased_view_type body
  | TypeBorrow t | TypeBorrowMut t | TypeSink t -> is_erased_view_type t
  | _ -> false

let rec runtime_payload_type = function
  | TypeExists (_, _, body) -> runtime_payload_type body
  | ty -> resolve_special_type ty

let variant_case vtype cname =
  match Hashtbl.find_opt variant_cases_tbl vtype with
  | None -> raise (Error (Printf.sprintf "Unknown variant: %s" vtype))
  | Some cases ->
      (match List.assoc_opt cname cases with
       | Some layout -> layout
       | None -> raise (Error (Printf.sprintf
           "Unknown variant case %s::%s" vtype cname)))

(* This value never enters an alloca, call operand, return instruction, or
   global. It only satisfies gen_expr's internal `(type, llvalue)` shape while
   the type checker carries the real permission in Delta. *)
let erased_view_value () = undef (i1_type context)

(* Mirrors lib/type_inf.ml's const_type_size/const_field_offset exactly
   (GitHub issue #77 -- sync rule, change together). Operates purely on
   Ast.type_expr + struct_fields/struct_is_packed/struct_alignments,
   never on Llvm_target.DataLayout, so its answer for "is this value
   target-independent" matches type_inf.ml's decision by construction --
   codegen must never claim a wider class of sizeof/offsetof expressions
   provable than type inference already did (see SizeOf/OffsetOf's
   gen_expr case below, which cross-checks this against the real
   DataLayout-computed value and raises a BUG error on any disagreement,
   the same "codegen re-verifies rather than trusts" discipline this
   file already uses for SliceOf). *)
let rec const_type_size (ty : Ast.type_expr) : int option =
  match ty with
  | Ast.TypeBool | Ast.TypeU8 | Ast.TypeI8 -> Some 1
  | Ast.TypeU16 | Ast.TypeI16 -> Some 2
  | Ast.TypeU32 | Ast.TypeI32 -> Some 4
  | Ast.TypeU64 | Ast.TypeI64 -> Some 8
  | Ast.TypeArray (elem, n) ->
      (match const_type_size elem with
       | Some sz -> Some (sz * n)
       | None -> None)
  | Ast.TypeNamed name ->
      (match Hashtbl.find_opt struct_is_packed name, Hashtbl.find_opt struct_fields name with
       | Some true, Some fields when not (Hashtbl.mem struct_alignments name) ->
           List.fold_left (fun acc (_, fty) ->
             match acc, const_type_size fty with
             | Some a, Some b -> Some (a + b)
             | _ -> None
           ) (Some 0) fields
       | _ -> None)
  | _ -> None

let const_field_offset (sname : string) (field : string) : int option =
  match Hashtbl.find_opt struct_is_packed sname, Hashtbl.find_opt struct_fields sname with
  | Some true, Some fields when not (Hashtbl.mem struct_alignments sname) ->
      let rec go = function
        | [] -> None
        | (fname, _) :: _ when fname = field -> Some 0
        | (_, fty) :: rest ->
            (match const_type_size fty, go rest with
             | Some a, Some b -> Some (a + b)
             | _ -> None)
      in go fields
  | _ -> None

(* Target data layout -- set by setup_target; used for struct tail-padding computation *)
let target_data : Llvm_target.DataLayout.t option ref = ref None
(* Enum underlying type registry: enum name -> underlying Ast type (u8/u16/u32/u64) *)
let enum_underlying  : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 8
(* Enum variant registry: enum name -> [(variant_name, discriminant_value)] *)
let enum_variants_tbl: (string, (string * int) list) Hashtbl.t = Hashtbl.create 8
(* Non-exhaustive flag: enum name -> bool (true = has _ marker, int->enum cast skips trap) *)
let enum_nonexhaustive: (string, bool) Hashtbl.t = Hashtbl.create 8
(* Immutable global constant registry: name -> (declared_type, initializer_expr).
   Populated by gen_global as each global is processed, in source order, and
   consulted by eval_const's Cast/Var cases below so a later global's
   initializer can fold a reference to an earlier one (`let B: T = A;`) or a
   cast built on one (`let B: T = A as T;`). Only immutable globals with an
   initializer are recorded -- a `let mut` global's value can change at
   runtime, so it is never a compile-time constant, and looking it up here
   simply won't be found (giving a clear "not a compile-time constant" error
   rather than silently reading a stale value). Recording happens in source
   order with no forward-reference support, mirroring Const_env's existing
   array-size-constant mechanism. *)
let global_const_defs : (string, Ast.type_expr * Ast.expr) Hashtbl.t = Hashtbl.create 16

(* -- Trap-site accounting (--forbid-trap) --------------------------------- *)
(* Every runtime trap check emitted by codegen (array bounds check, checked
   refined cast, exhaustive-enum cast) is recorded here with its source
   location. bin/main.ml reads this after gen_program: under --forbid-trap a
   non-empty list is a compile error listing every unproven site.
   Recording happens at IR-generation time, i.e. it reflects exactly what the
   type system could not prove. This is deliberately independent of whether
   LLVM's optimizer would later fold a particular check away (see
   run_optimizations' correlated-propagation note): the --forbid-trap
   guarantee must stay deterministic across LLVM versions and pass behavior,
   so "the optimizer happened to remove it" never counts as proof. *)
let trap_sites : (Lexing.position * string) list ref = ref []
let record_trap loc what = trap_sites := (loc, what) :: !trap_sites

(* -- Function profiling (--profile-functions) --------------------------- *)
let function_profiling_enabled = ref false
let set_function_profiling enabled = function_profiling_enabled := enabled

let prof_entry_ty : lltype option ref = ref None
let prof_table : llvalue option ref = ref None
let prof_stack_cycles : llvalue option ref = ref None
let prof_stack_ids : llvalue option ref = ref None
let prof_depth : llvalue option ref = ref None
let prof_overflow : llvalue option ref = ref None
let prof_path_table : llvalue option ref = ref None
let prof_path_overflow : llvalue option ref = ref None
let prof_record_path_fn : llvalue option ref = ref None
let prof_func_ids : (string, int) Hashtbl.t = Hashtbl.create 64
let prof_task_capacity = 4
let prof_stack_capacity = 256
let prof_path_capacity = 256
(* Each packed call-path entry is 20 + (4 * depth) bytes. A depth of 12 covers
   the deepest currently profiled STM32 path (10 frames) while saving 4 KiB
   versus depth 16, which made KVS+SD+RTOS overflow AXI SRAM at link time. *)
let prof_path_max_depth = 12

let should_profile_function name =
  !function_profiling_enabled
  && name <> "pendsv_dispatch"
  && not (String.length name >= 7
          && String.sub name (String.length name - 7) 7 = "Handler")

let require_profile_global r name =
  match !r with
  | Some v -> v
  | None -> raise (Error (Printf.sprintf "BUG: profile global '%s' not initialized" name))

let profile_task_id () =
  match Hashtbl.find_opt global_vars "sched", Hashtbl.find_opt struct_lltypes "SchedState" with
  | Some (_, sched_g), Some sched_ty ->
      let p = build_in_bounds_gep sched_ty sched_g
        [| const_int (i32_type context) 0; const_int (i32_type context) 1 |]
        "prof.task.ptr" builder in
      build_load (i32_type context) p "prof.task" builder
  | _ -> const_int (i32_type context) 0

let build_profile_path_recorder () =
  let i32 = i32_type context in
  let i64 = i64_type context in
  let frames_ty = array_type i32 prof_path_max_depth in
  let path_entry_ty = packed_struct_type context [| i32; i32; i32; i64; frames_ty |] in
  let path_table_ty = array_type path_entry_ty prof_path_capacity in
  let stack_ids_g = require_profile_global prof_stack_ids "__takibi_prof_stack_ids" in
  let path_table_g = require_profile_global prof_path_table "__takibi_prof_path_table" in
  let path_overflow_g = require_profile_global prof_path_overflow "__takibi_prof_path_overflow" in
  let fty = function_type (void_type context) [| i32; i32; i64 |] in
  let fn = define_function "__takibi_prof_record_path" fty the_module in
  prof_record_path_fn := Some fn;

  let task_arg = param fn 0 in
  let depth_arg = param fn 1 in
  let elapsed_arg = param fn 2 in
  let entry_bb = entry_block fn in
  position_at_end entry_bb builder;

  let zero = const_int i32 0 in
  let one = const_int i32 1 in
  let max_depth = const_int i32 prof_path_max_depth in
  let too_deep = build_icmp Icmp.Ugt depth_arg max_depth "path.too_deep" builder in
  let use_depth = build_select too_deep max_depth depth_arg "path.depth" builder in

  let hash_ptr = build_alloca i32 "path.hash" builder in
  let i_ptr = build_alloca i32 "path.i" builder in
  ignore (build_store (const_int i32 0x811c9dc5) hash_ptr builder);
  ignore (build_store zero i_ptr builder);

  let hash_cond = append_block context "hash_cond" fn in
  let hash_body = append_block context "hash_body" fn in
  let hash_done = append_block context "hash_done" fn in
  ignore (build_br hash_cond builder);
  position_at_end hash_cond builder;
  let i = build_load i32 i_ptr "path.i" builder in
  let more = build_icmp Icmp.Ult i use_depth "path.hash.more" builder in
  ignore (build_cond_br more hash_body hash_done builder);
  position_at_end hash_body builder;
  let stack_ids_ty = array_type (array_type i32 prof_stack_capacity) prof_task_capacity in
  let id_ptr = build_in_bounds_gep stack_ids_ty stack_ids_g [| zero; task_arg; i |] "path.stack.id.ptr" builder in
  let id_v = build_load i32 id_ptr "path.stack.id" builder in
  let h0 = build_load i32 hash_ptr "path.hash.old" builder in
  let h1 = build_xor h0 id_v "path.hash.xor" builder in
  let h2 = build_mul h1 (const_int i32 0x01000193) "path.hash.mul" builder in
  ignore (build_store h2 hash_ptr builder);
  ignore (build_store (build_add i one "path.i.next" builder) i_ptr builder);
  ignore (build_br hash_cond builder);

  position_at_end hash_done builder;
  let hash_v = build_load i32 hash_ptr "path.hash.final" builder in
  let idx_ptr = build_alloca i32 "path.idx" builder in
  let chosen_ptr = build_alloca i32 "path.chosen" builder in
  ignore (build_store zero idx_ptr builder);
  ignore (build_store (const_int i32 (-1)) chosen_ptr builder);

  let scan_cond = append_block context "scan_cond" fn in
  let scan_body = append_block context "scan_body" fn in
  let scan_next = append_block context "scan_next" fn in
  let scan_done = append_block context "scan_done" fn in
  ignore (build_br scan_cond builder);
  position_at_end scan_cond builder;
  let idx = build_load i32 idx_ptr "path.idx" builder in
  let chosen = build_load i32 chosen_ptr "path.chosen" builder in
  let no_choice = build_icmp Icmp.Eq chosen (const_int i32 (-1)) "path.no_choice" builder in
  let in_range = build_icmp Icmp.Ult idx (const_int i32 prof_path_capacity) "path.in_range" builder in
  ignore (build_cond_br (build_and no_choice in_range "path.scan.more" builder) scan_body scan_done builder);

  position_at_end scan_body builder;
  let entry_ptr = build_in_bounds_gep path_table_ty path_table_g [| zero; idx |] "path.entry" builder in
  let e_hash_ptr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; zero |] "path.e.hash.ptr" builder in
  let e_depth_ptr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; one |] "path.e.depth.ptr" builder in
  let e_hash = build_load i32 e_hash_ptr "path.e.hash" builder in
  let e_depth = build_load i32 e_depth_ptr "path.e.depth" builder in
  let empty = build_icmp Icmp.Eq e_hash zero "path.empty" builder in
  let same_hash = build_icmp Icmp.Eq e_hash hash_v "path.same_hash" builder in
  let same_depth = build_icmp Icmp.Eq e_depth use_depth "path.same_depth" builder in
  let matched = build_or empty (build_and same_hash same_depth "path.same" builder) "path.match" builder in
  let choose_bb = append_block context "path_choose" fn in
  ignore (build_cond_br matched choose_bb scan_next builder);
  position_at_end choose_bb builder;
  ignore (build_store idx chosen_ptr builder);
  ignore (build_br scan_next builder);
  position_at_end scan_next builder;
  ignore (build_store (build_add idx one "path.idx.next" builder) idx_ptr builder);
  ignore (build_br scan_cond builder);

  position_at_end scan_done builder;
  let chosen = build_load i32 chosen_ptr "path.chosen.final" builder in
  let found = build_icmp Icmp.Ne chosen (const_int i32 (-1)) "path.found" builder in
  let update_bb = append_block context "path_update" fn in
  let overflow_bb = append_block context "path_overflow" fn in
  let ret_bb = append_block context "path_ret" fn in
  ignore (build_cond_br found update_bb overflow_bb builder);

  position_at_end overflow_bb builder;
  let ov = build_load i32 path_overflow_g "path.overflow.old" builder in
  ignore (build_store (build_add ov one "path.overflow.next" builder) path_overflow_g builder);
  ignore (build_br ret_bb builder);

  position_at_end update_bb builder;
  let entry_ptr = build_in_bounds_gep path_table_ty path_table_g [| zero; chosen |] "path.update.entry" builder in
  let e_hash_ptr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; zero |] "path.update.hash.ptr" builder in
  let e_depth_ptr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; one |] "path.update.depth.ptr" builder in
  let e_calls_ptr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; const_int i32 2 |] "path.update.calls.ptr" builder in
  let e_cycles_ptr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; const_int i32 3 |] "path.update.cycles.ptr" builder in
  ignore (build_store hash_v e_hash_ptr builder);
  ignore (build_store use_depth e_depth_ptr builder);
  let calls = build_load i32 e_calls_ptr "path.calls" builder in
  ignore (build_store (build_add calls one "path.calls.next" builder) e_calls_ptr builder);
  let cycles = build_load i64 e_cycles_ptr "path.cycles" builder in
  ignore (build_store (build_add cycles elapsed_arg "path.cycles.next" builder) e_cycles_ptr builder);

  ignore (build_store zero i_ptr builder);
  let copy_cond = append_block context "path_copy_cond" fn in
  let copy_body = append_block context "path_copy_body" fn in
  let copy_done = append_block context "path_copy_done" fn in
  ignore (build_br copy_cond builder);
  position_at_end copy_cond builder;
  let i = build_load i32 i_ptr "path.copy.i" builder in
  let more = build_icmp Icmp.Ult i use_depth "path.copy.more" builder in
  ignore (build_cond_br more copy_body copy_done builder);
  position_at_end copy_body builder;
  let src = build_in_bounds_gep stack_ids_ty stack_ids_g [| zero; task_arg; i |] "path.copy.src" builder in
  let dst_arr = build_in_bounds_gep path_entry_ty entry_ptr [| zero; const_int i32 4 |] "path.frames" builder in
  let dst = build_in_bounds_gep frames_ty dst_arr [| zero; i |] "path.copy.dst" builder in
  let v = build_load i32 src "path.copy.id" builder in
  ignore (build_store v dst builder);
  ignore (build_store (build_add i one "path.copy.next" builder) i_ptr builder);
  ignore (build_br copy_cond builder);
  position_at_end copy_done builder;
  ignore (build_br ret_bb builder);

  position_at_end ret_bb builder;
  ignore (build_ret_void builder);
  path_entry_ty

let profile_read_cyccnt () =
  let i32 = i32_type context in
  let demcr = const_inttoptr (const_int i32 0xE000EDFC) (pointer_type context) in
  let dwt_lar = const_inttoptr (const_int i32 0xE0001FB0) (pointer_type context) in
  let dwt_ctrl = const_inttoptr (const_int i32 0xE0001000) (pointer_type context) in
  let dwt_cyccnt = const_inttoptr (const_int i32 0xE0001004) (pointer_type context) in
  let lar_st = build_store (const_int i32 0xC5ACCE55) dwt_lar builder in
  set_volatile true lar_st;
  let demcr_v = build_load i32 demcr "prof.demcr" builder in
  set_volatile true demcr_v;
  let demcr_enabled = build_or demcr_v (const_int i32 0x01000000) "prof.demcr_enable" builder in
  let demcr_st = build_store demcr_enabled demcr builder in
  set_volatile true demcr_st;
  let ctrl = build_load i32 dwt_ctrl "prof.dwt_ctrl" builder in
  set_volatile true ctrl;
  let enabled = build_or ctrl (const_int i32 1) "prof.dwt_enable" builder in
  let st = build_store enabled dwt_ctrl builder in
  set_volatile true st;
  let cycles = build_load i32 dwt_cyccnt "prof.cyccnt" builder in
  set_volatile true cycles;
  cycles

let emit_profile_enter key =
  match Hashtbl.find_opt prof_func_ids key with
  | None -> ()
  | Some id ->
      let depth_g = require_profile_global prof_depth "__takibi_prof_depth" in
      let overflow_g = require_profile_global prof_overflow "__takibi_prof_overflow" in
      let stack_cycles_g = require_profile_global prof_stack_cycles "__takibi_prof_stack_cycles" in
      let stack_ids_g = require_profile_global prof_stack_ids "__takibi_prof_stack_ids" in
      let i32 = i32_type context in
      let i64 = i64_type context in
      let task = profile_task_id () in
      let zero = const_int i32 0 in
      let depth_arr_ty = array_type i32 prof_task_capacity in
      let depth_ptr = build_in_bounds_gep depth_arr_ty depth_g [| zero; task |] "prof.depth.ptr" builder in
      let depth = build_load i32 depth_ptr "prof.depth" builder in
      let cap = const_int i32 prof_stack_capacity in
      let ok = build_icmp Icmp.Ult depth cap "prof.depth.ok" builder in
      let cur_bb = insertion_block builder in
      let fn = block_parent cur_bb in
      let push_bb = append_block context "prof_enter_push" fn in
      let overflow_bb = append_block context "prof_enter_overflow" fn in
      let done_bb = append_block context "prof_enter_done" fn in
      ignore (build_cond_br ok push_bb overflow_bb builder);
      position_at_end push_bb builder;
      let now32 = profile_read_cyccnt () in
      let now64 = build_zext now32 i64 "prof.now64" builder in
      let cyc_arr_ty = array_type (array_type i64 prof_stack_capacity) prof_task_capacity in
      let id_arr_ty = array_type (array_type i32 prof_stack_capacity) prof_task_capacity in
      let cyc_slot = build_in_bounds_gep cyc_arr_ty stack_cycles_g [| zero; task; depth |] "prof.cyc.slot" builder in
      let id_slot = build_in_bounds_gep id_arr_ty stack_ids_g [| zero; task; depth |] "prof.id.slot" builder in
      ignore (build_store now64 cyc_slot builder);
      ignore (build_store (const_int i32 id) id_slot builder);
      let next_depth = build_add depth (const_int i32 1) "prof.depth.next" builder in
      ignore (build_store next_depth depth_ptr builder);
      ignore (build_br done_bb builder);
      position_at_end overflow_bb builder;
      let overflow_old = build_load i32 overflow_g "prof.overflow" builder in
      let overflow_new = build_add overflow_old (const_int i32 1) "prof.overflow.next" builder in
      ignore (build_store overflow_new overflow_g builder);
      ignore (build_br done_bb builder);
      position_at_end done_bb builder

let emit_profile_exit key =
  match Hashtbl.find_opt prof_func_ids key with
  | None -> ()
  | Some id ->
      let entry_ty = match !prof_entry_ty with
        | Some t -> t
        | None -> raise (Error "BUG: profile entry type not initialized")
      in
      let table_g = require_profile_global prof_table "__takibi_prof_table" in
      let depth_g = require_profile_global prof_depth "__takibi_prof_depth" in
      let stack_cycles_g = require_profile_global prof_stack_cycles "__takibi_prof_stack_cycles" in
      let i32 = i32_type context in
      let i64 = i64_type context in
      let task = profile_task_id () in
      let zero = const_int i32 0 in
      let depth_arr_ty = array_type i32 prof_task_capacity in
      let depth_ptr = build_in_bounds_gep depth_arr_ty depth_g [| zero; task |] "prof.depth.ptr" builder in
      let depth = build_load i32 depth_ptr "prof.depth" builder in
      let zero_depth = build_icmp Icmp.Eq depth (const_int i32 0) "prof.depth.zero" builder in
      let cur_bb = insertion_block builder in
      let fn = block_parent cur_bb in
      let pop_bb = append_block context "prof_exit_pop" fn in
      let done_bb = append_block context "prof_exit_done" fn in
      ignore (build_cond_br zero_depth done_bb pop_bb builder);
      position_at_end pop_bb builder;
      let new_depth = build_sub depth (const_int i32 1) "prof.depth.prev" builder in
      ignore (build_store new_depth depth_ptr builder);
      let cyc_arr_ty = array_type (array_type i64 prof_stack_capacity) prof_task_capacity in
      let start_slot = build_in_bounds_gep cyc_arr_ty stack_cycles_g [| zero; task; new_depth |] "prof.start.slot" builder in
      let start = build_load i64 start_slot "prof.start" builder in
      let now32 = profile_read_cyccnt () in
      let now64 = build_zext now32 i64 "prof.now64" builder in
      let elapsed = build_sub now64 start "prof.elapsed" builder in
      (match !prof_record_path_fn with
       | Some record_fn ->
           let record_ty = function_type (void_type context) [| i32; i32; i64 |] in
           let path_depth = build_add new_depth (const_int i32 1) "prof.path.depth" builder in
           ignore (build_call record_ty record_fn [| task; path_depth; elapsed |] "" builder)
       | None -> ());
      let table_ty = array_type entry_ty (Hashtbl.length prof_func_ids) in
      let entry_ptr = build_in_bounds_gep table_ty table_g [| zero; const_int i32 id |] "prof.entry" builder in
      let calls_ptr = build_in_bounds_gep entry_ty entry_ptr [| zero; const_int i32 1 |] "prof.calls.ptr" builder in
      let cycles_ptr = build_in_bounds_gep entry_ty entry_ptr [| zero; const_int i32 2 |] "prof.cycles.ptr" builder in
      let calls = build_load i32 calls_ptr "prof.calls" builder in
      ignore (build_store (build_add calls (const_int i32 1) "prof.calls.next" builder) calls_ptr builder);
      let cycles = build_load i64 cycles_ptr "prof.cycles" builder in
      ignore (build_store (build_add cycles elapsed "prof.cycles.next" builder) cycles_ptr builder);
      ignore (build_br done_bb builder);
      position_at_end done_bb builder

let emit_profile_return key ret_builder =
  emit_profile_exit key;
  ret_builder ()

let init_function_profile_table keys =
  Hashtbl.reset prof_func_ids;
  prof_entry_ty := None;
  prof_table := None;
  prof_stack_cycles := None;
  prof_stack_ids := None;
  prof_path_table := None;
  prof_path_overflow := None;
  prof_record_path_fn := None;
  prof_depth := None;
  prof_overflow := None;
  if !function_profiling_enabled then begin
    let profiled =
      keys
      |> List.filter should_profile_function
      |> List.sort String.compare
    in
    List.iteri (fun i key -> Hashtbl.add prof_func_ids key i) profiled;
    let i32 = i32_type context in
    let i64 = i64_type context in
    let entry_ty = struct_type context [| i32; i32; i64 |] in
    prof_entry_ty := Some entry_ty;
    let entries =
      profiled
      |> List.mapi (fun id _key ->
        const_struct context [| const_int i32 id; const_int i32 0; const_int i64 0 |])
      |> Array.of_list
    in
    let table_init = const_array entry_ty entries in
    let table_g = define_global "__takibi_prof_table" table_init the_module in
    set_section ".takibi_prof" table_g;
    prof_table := Some table_g;
    let n_g = define_global "__takibi_prof_count" (const_int i32 (List.length profiled)) the_module in
    set_global_constant true n_g;
    set_section ".takibi_prof" n_g;
    prof_depth := Some (define_global "__takibi_prof_depth"
      (const_null (array_type i32 prof_task_capacity)) the_module);
    prof_overflow := Some (define_global "__takibi_prof_overflow" (const_int i32 0) the_module);
    prof_stack_cycles := Some (define_global "__takibi_prof_stack_cycles"
      (const_null (array_type (array_type i64 prof_stack_capacity) prof_task_capacity)) the_module);
    prof_stack_ids := Some (define_global "__takibi_prof_stack_ids"
      (const_null (array_type (array_type i32 prof_stack_capacity) prof_task_capacity)) the_module);
    let frames_ty = array_type i32 prof_path_max_depth in
    let path_entry_ty = packed_struct_type context [| i32; i32; i32; i64; frames_ty |] in
    prof_path_table := Some (define_global "__takibi_prof_path_table"
      (const_null (array_type path_entry_ty prof_path_capacity)) the_module);
    prof_path_overflow := Some (define_global "__takibi_prof_path_overflow" (const_int i32 0) the_module);
    ignore (build_profile_path_recorder ())
  end

(* Mirrors type_inf.ml's unsafe_depth (sync rule): nesting depth of
   `unsafe { ... }` around the expression currently being generated.
   Consulted by the SliceOf codegen case (P4c-1) to decide whether an
   unprovable slice/array-base subslice's runtime check should be emitted
   (default, unchanged behavior) or skipped (inside unsafe -- an explicit
   unchecked assertion, same semantics as the pointer-base case). Reset
   per compilation for the same reason type_inf's counter is. *)
let unsafe_depth = ref 0

(* Human-readable type names for trap-site messages (Ast.show_type_expr's
   raw constructor dump is too noisy for a user-facing compile error). *)
let rec ty_str = function
  | TypeBool -> "bool"
  | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32" | TypeI64 -> "i64"
  | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32" | TypeU64 -> "u64"
  | TypeIsize -> "isize"
  | TypeUsize -> "usize"
  | TypeVoid  -> "void"
  | TypePtr t -> "*" ^ ty_str t
  | TypeIo  t -> "io " ^ ty_str t
  | TypeArray (t, n) -> Printf.sprintf "[%s; %d]" (ty_str t) n
  | TypeFn _  -> "fn(...)"
  | TypeNamed s -> s
  | TypeView (s, []) -> "view " ^ s
  | TypeView (s, args) ->
      let arg = function
        | StaticName n -> n
        | StaticInt n -> string_of_int n
        | StaticEnum (name, case) -> name ^ "::" ^ case
      in
      Printf.sprintf "view %s[%s]" s
        (String.concat ", " (List.map arg args))
  | TypeVariant s -> s
  | TypeExists (name, sort, body) ->
      Printf.sprintf "exists %s: %s. %s" name (ty_str sort) (ty_str body)
  | TypeIndexed (s, args) ->
      let arg = function
        | StaticName n -> n
        | StaticInt n -> string_of_int n
        | StaticEnum (name, case) -> name ^ "::" ^ case
      in
      Printf.sprintf "%s[%s]" s (String.concat ", " (List.map arg args))
  | TypeSingleton (t, arg) ->
      let n = match arg with
        | StaticName n -> n
        | StaticInt n -> string_of_int n
        | StaticEnum (name, case) -> name ^ "::" ^ case
      in
      Printf.sprintf "%s @ %s" (ty_str t) n
  | TypeRefined (lo, hi, _) -> Printf.sprintf "{%d..<%d}" lo hi
  | TypeSlice (t, 0) -> Printf.sprintf "[]%s" (ty_str t)
  | TypeSlice (t, n) -> Printf.sprintf "[%s; %d..]" (ty_str t) n
  | TypeBorrow t -> "borrow " ^ ty_str t
  | TypeBorrowMut t -> "borrow mut " ^ ty_str t
  | TypeSink t -> "sink " ^ ty_str t
  | TypeAlignedPtr (n, t) -> Printf.sprintf "*align(%d) %s" n (ty_str t)
  | TypeTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map ty_str ts))

(* ---- DWARF debug info (opt-in via -g; see enable_debug_info) ----
   Everything DI-related elsewhere in this file (gen_func / gen_stmt / gen_program)
   checks !debug_info_enabled first and is a no-op when -g was not passed. *)
let debug_info_enabled = ref false
let dibuilder_opt : Llvm_debuginfo.lldibuilder option ref = ref None
let di_compile_unit : Llvm.llmetadata option ref = ref None
(* One DIFile per source filename: `takibi a.tkb b.tkb -o out.o` concatenates ASTs
   from different files, so each function's DISubprogram needs the DIFile that
   actually matches where it was written, not just the first input file. *)
let di_files : (string, Llvm.llmetadata) Hashtbl.t = Hashtbl.create 8

let di_file_for (dib : Llvm_debuginfo.lldibuilder) (filename : string) : Llvm.llmetadata =
  match Hashtbl.find_opt di_files filename with
  | Some f -> f
  | None ->
      (* Every DIFile's directory must be absolute. DWARF resolves a *relative*
         directory by joining it onto the DICompileUnit's own (single) comp_dir,
         so two files in different relative directories -- e.g. examples/common_qemu/uart.tkb
         and examples/fizzbuzz/fizzbuzz.tkb -- would otherwise get concatenated into
         one bogus path (observed: "examples/common/examples/fizzbuzz/fizzbuzz.tkb")
         by addr2line/llvm-dwarfdump. Making every directory absolute sidesteps
         comp_dir entirely. *)
      let abs_filename =
        if Filename.is_relative filename
        then Filename.concat (Sys.getcwd ()) filename
        else filename
      in
      let f = Llvm_debuginfo.dibuild_create_file dib
          ~filename:(Filename.basename abs_filename)
          ~directory:(Filename.dirname abs_filename) in
      Hashtbl.add di_files filename f;
      f

(* Enable DWARF line-table emission for the rest of this compilation.
   Called once from bin/main.ml when -g is passed, before gen_program runs.
   [primary_file] anchors the DICompileUnit; each function's own DISubprogram
   still points at its true source file via di_file_for. *)
let enable_debug_info (primary_file : string) =
  debug_info_enabled := true;
  let dib = Llvm_debuginfo.dibuilder the_module in
  dibuilder_opt := Some dib;
  let file = di_file_for dib primary_file in
  let cu = Llvm_debuginfo.dibuild_create_compile_unit dib
      Llvm_debuginfo.DWARFSourceLanguageKind.C
      ~file_ref:file
      ~producer:"takibi"
      ~is_optimized:true
      ~flags:""
      ~runtime_ver:0
      ~split_name:""
      Llvm_debuginfo.DWARFEmissionKind.Full
      ~dwoid:0
      ~di_inlining:false
      ~di_profiling:false
      ~sys_root:""
      ~sdk:""
  in
  di_compile_unit := Some cu;
  (* Without these module flags LLVM silently strips all debug metadata again
     (a missing/mismatched "Debug Info Version" is treated as "no debug info"). *)
  add_module_flag the_module ModuleFlagBehavior.Warning "Debug Info Version"
    (value_as_metadata (const_int (i32_type context) (Llvm_debuginfo.debug_metadata_version ())));
  add_module_flag the_module ModuleFlagBehavior.Warning "Dwarf Version"
    (value_as_metadata (const_int (i32_type context) 4))

(* Locals are either immutable SSA values or mutable alloca pointers *)
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* direct SSA value -- no alloca *)
  | Mut of Ast.type_expr * llvalue  (* alloca pointer -- load/store *)

(* Module-level table for Mut binding narrowing from if-conditions.
   Compilation is single-threaded, so a module-level Hashtbl is safe.
   gen_expr cannot access locals directly, so type overrides are passed through here. *)
let narrowing_ctx : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 4

(* Collect per-variable bounds from an if-condition for codegen narrowing.
   A comparison constrains `Var n` whenever the OTHER operand's static
   value range is known: an integer literal / Const_env constant is
   {k..<k+1}, and a variable whose binding (or active narrowing) is
   refined contributes its own range. The fact collapses to a CONSTANT at
   collection time -- still interval reasoning, no relational domain, and
   no new kill obligations (the constant was true when the condition
   executed; n's own kill is governed by written_names as before).
   Equality (`ihl == 20`) narrows to the operand's exact range.
   Sync rule: mirrors type_inf.ml's collect_bounds -- change together.
   Known conservative gap vs type_inf: refined GLOBALS and Mut-narrowed
   variables reached through arithmetic are not consulted here, so codegen
   may keep a check type_inf considered proven -- safe direction, shows up
   as a --forbid-trap site; bind the value to an immutable local to fix. *)
let collect_bounds_cond (locals : (string, local_binding) Hashtbl.t)
    (cond : Ast.expr) =
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
  let range_of (e : Ast.expr) =
    match Const_env.bound_value e with
    | Some k -> Some (k, k + 1)
    | None ->
        (match e.desc with
         | Var m ->
             let refined = function
               | TypeRefined (a, b, _) -> Some (a, b)
               | _ -> None
             in
             (match Hashtbl.find_opt narrowing_ctx m with
              | Some t -> refined t
              | None ->
                  (match Hashtbl.find_opt locals m with
                   | Some (Imm (t, _)) | Some (Mut (t, _)) -> refined t
                   | None -> None))
         | _ -> None)
  in
  (* n <op> rhs where rhs's range is {c..<d} (so c <= rhs <= d-1). *)
  let constrain_left op n (c, d) acc =
    match op with
    | Ge -> update n (Some c)       None           acc
    | Gt -> update n (Some (c + 1)) None           acc
    | Le -> update n None           (Some d)       acc
    | Lt -> update n None           (Some (d - 1)) acc
    | Eq -> update n (Some c)       (Some d)       acc
    | _ -> acc
  in
  (* lhs <op> n where lhs's range is {c..<d} -- mirrored constraints. *)
  let constrain_right op n (c, d) acc =
    match op with
    | Ge -> update n None           (Some d)       acc  (* n <= lhs *)
    | Gt -> update n None           (Some (d - 1)) acc  (* n <  lhs *)
    | Le -> update n (Some c)       None           acc  (* n >= lhs *)
    | Lt -> update n (Some (c + 1)) None           acc  (* n >  lhs *)
    | Eq -> update n (Some c)       (Some d)       acc
    | _ -> acc
  in
  let rec go e acc = match e.desc with
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
  go cond Types.StringMap.empty

(* True for unsigned primitive integer AST types -- an unsigned value is
   trivially >= 0, so a hi-only if-condition can still narrow it (GitHub
   issue #99) without an explicit, redundant `>= 0` conjunct. Sync rule:
   mirrors type_inf.ml's is_unsigned_ty (same primitive set, Ast.type_expr
   form instead of Types.ty). *)
let is_unsigned_ast_ty = function
  | Ast.TypeU8 | Ast.TypeU16 | Ast.TypeU32 | Ast.TypeU64 | Ast.TypeUsize -> true
  | _ -> false

(* Temporarily narrow Imm locals based on condition bounds.
   Only Imm (immutable) bindings are narrowed; Mut bindings are skipped.
   Returns saved bindings for restoration after the then-branch.
   [killed] is the branch body's Ast.written_names: an Imm binding cannot
   be assigned or aliased, but the body can REBIND the name (let / for
   counter), and the narrowed entry must not leak into that fresh binding's
   uses -- so killed names are skipped here too. *)
let apply_narrowing (locals : (string, local_binding) Hashtbl.t)
    (cond : Ast.expr) (killed : string list) =
  let bounds = collect_bounds_cond locals cond in
  let saved =
    Types.StringMap.fold (fun name (lo_opt, hi_opt) saved ->
      if List.mem name killed then saved
      else match Hashtbl.find_opt locals name with
      | Some (Imm (TypeSlice _, _)) -> saved  (* handled below *)
      | Some (Imm (TypeRefined (elo, ehi, base), v) as old) ->
          (* Already refined (sync rule with type_inf.ml's
             narrow_from_cond): INTERSECT, don't just overwrite --
             needed so an if-condition that's true but WIDER than an
             already-proven fact (e.g. a redundant re-check) can never
             discard precision codegen would otherwise disagree with
             type_inf about. GitHub issue #99: a hi-only condition
             (lo_opt = None) still narrows, falling back to the
             already-proven `elo`. *)
          (match lo_opt, hi_opt with
           | Some lo, Some hi -> Hashtbl.replace locals name (Imm (TypeRefined (max lo elo, min hi ehi, base), v)); (name, old) :: saved
           | None, Some hi    -> Hashtbl.replace locals name (Imm (TypeRefined (elo, min hi ehi, base), v)); (name, old) :: saved
           | Some lo, None    -> Hashtbl.replace locals name (Imm (TypeRefined (max lo elo, ehi, base), v)); (name, old) :: saved
           | None, None       -> saved)
      | Some (Imm (((TypeI8|TypeI16|TypeI32|TypeI64|TypeIsize
                    |TypeU8|TypeU16|TypeU32|TypeU64|TypeUsize) as base), v) as old) ->
          (* Any plain primitive integer type can be narrowed, not
             just TypeI32 (sync rule with type_inf.ml's
             narrow_from_cond) -- the variable's OWN type becomes the
             refined range's base. GitHub issue #99: an unsigned base
             with no lo_opt defaults to 0. *)
          let lo_opt = match lo_opt with
            | Some _ -> lo_opt
            | None -> if is_unsigned_ast_ty base then Some 0 else None
          in
          (match lo_opt, hi_opt with
           | Some lo, Some hi ->
               Hashtbl.replace locals name (Imm (TypeRefined (lo, hi, base), v));
               (name, old) :: saved
           | _ -> saved)
      | _ -> saved
    ) bounds []
  in
  (* Slice minimum-length narrowing (`if (s.len >= K)`) for Imm slice
     bindings. type_inf.ml's narrow_from_cond consumes the same
     Ast.slice_len_mins (sync rule). *)
  List.fold_left (fun saved (name, k) ->
    if List.mem name killed then saved
    else match Hashtbl.find_opt locals name with
      | Some (Imm (TypeSlice (el, m), v) as old) when k > m ->
          Hashtbl.replace locals name (Imm (TypeSlice (el, k), v));
          (name, old) :: saved
      | _ -> saved
  ) saved (Ast.slice_len_mins cond)

let restore_narrowing (locals : (string, local_binding) Hashtbl.t) saved =
  List.iter (fun (name, old) -> Hashtbl.replace locals name old) saved

(* Record narrowed types for Mut bindings into narrowing_ctx.
   Returns [(name, old_opt)] -- pass to restore_narrowing_mut after the then-branch.
   Invalidation (kill) rule: a variable the branch body may write to, alias
   (&x), or rebind is NOT narrowed at all -- the condition only proves the
   range at the moment it was evaluated, and any later write invalidates
   that proof (`if (v >= 0 && v < 8) { v = 100; buf[v] = ...; }` must keep
   its bounds check). [killed] comes from Ast.written_names on the branch
   body; type_inf.ml's narrow_from_cond applies the same rule through the
   same function (sync rule -- see written_names' comment). *)
let apply_narrowing_mut (locals : (string, local_binding) Hashtbl.t)
    (cond : Ast.expr) (killed : string list) =
  let bounds = collect_bounds_cond locals cond in
  let saved =
    Types.StringMap.fold (fun name (lo_opt, hi_opt) saved ->
      if List.mem name killed then saved
      else match Hashtbl.find_opt locals name with
      | Some (Mut (((TypeI8|TypeI16|TypeI32|TypeI64|TypeIsize
                    |TypeU8|TypeU16|TypeU32|TypeU64|TypeUsize) as base), _)) ->
          let old = Hashtbl.find_opt narrowing_ctx name in
          (* An outer if may have already narrowed this Mut variable
             (nested ifs): INTERSECT with any existing narrowing_ctx
             entry rather than overwriting it, mirroring type_inf.ml's
             tyenv-threading (an inner narrow_from_cond naturally sees
             the outer narrowing already applied) -- sync rule. Any
             plain primitive integer type can be narrowed, not just
             TypeI32 -- the variable's OWN type becomes the refined
             range's base. GitHub issue #99: an unsigned base with no
             lo_opt from the condition defaults to 0 (trivially sound);
             a signed base with no lo_opt falls back to any existing
             narrowing_ctx lower bound instead, same as the hi-only case. *)
          let lo_opt = match lo_opt with
            | Some _ -> lo_opt
            | None -> if is_unsigned_ast_ty base then Some 0 else None
          in
          (match lo_opt, hi_opt with
           | Some lo, Some hi ->
               let (nlo, nhi) = match old with
                 | Some (TypeRefined (elo, ehi, _)) -> (max lo elo, min hi ehi)
                 | _ -> (lo, hi)
               in
               Hashtbl.replace narrowing_ctx name (TypeRefined (nlo, nhi, base));
               (name, old) :: saved
           | None, Some hi ->
               (match old with
                | Some (TypeRefined (elo, ehi, _)) ->
                    Hashtbl.replace narrowing_ctx name (TypeRefined (elo, min hi ehi, base));
                    (name, old) :: saved
                | _ -> saved)
           | Some lo, None ->
               (match old with
                | Some (TypeRefined (elo, ehi, _)) ->
                    Hashtbl.replace narrowing_ctx name (TypeRefined (max lo elo, ehi, base));
                    (name, old) :: saved
                | _ -> saved)
           | None, None -> saved)
      | _ -> saved
    ) bounds []
  in
  (* Slice minimum-length narrowing for Mut slice bindings, via
     narrowing_ctx (consulted by effective_slice_min at Index/AssignIndex
     sites). Same kill rule and same Ast.slice_len_mins as the Imm side
     and type_inf.ml (sync rule). *)
  List.fold_left (fun saved (name, k) ->
    if List.mem name killed then saved
    else match Hashtbl.find_opt locals name with
      | Some (Mut (TypeSlice (el, m), _)) when k > m ->
          let old = Hashtbl.find_opt narrowing_ctx name in
          Hashtbl.replace narrowing_ctx name (TypeSlice (el, max m k));
          (name, old) :: saved
      | _ -> saved
  ) saved (Ast.slice_len_mins cond)

let restore_narrowing_mut saved =
  List.iter (fun (name, old_opt) ->
    match old_opt with
    | None     -> Hashtbl.remove narrowing_ctx name
    | Some old -> Hashtbl.replace narrowing_ctx name old
  ) saved

type device_barrier_kind = DmaPublish | DmaConsume | DeviceFence

let starts_with s prefix =
  let n = String.length prefix in
  String.length s >= n && String.sub s 0 n = prefix

let get_or_declare_intrinsic name fty =
  match lookup_function name the_module with
  | Some fn -> fn
  | None -> declare_function name fty the_module

(* Emit a target-specific hardware barrier which is also opaque to LLVM's
   memory optimizer. ARM/AArch64 and x86 have target intrinsics; LLVM 19/22
   expose no RISC-V fence intrinsic carrying the I/O predecessor/successor
   bits, so RISC-V uses compiler-internal side-effecting inline asm with a
   memory clobber. This is an implementation detail, not source-level asm.

   ARM currently uses the conservative DSB SY for all three operations --
   exactly the instruction validated by the STM32 Ethernet bring-up. x86
   likewise starts conservatively with MFENCE. These can be weakened later
   per platform without changing Takibi source semantics. *)
let emit_device_barrier kind =
  let triple = target_triple the_module in
  let void_fn = function_type (void_type context) [||] in
  if starts_with triple "aarch64" then begin
    let fty = function_type (void_type context) [| i32_type context |] in
    let fn = get_or_declare_intrinsic "llvm.aarch64.dsb" fty in
    ignore (build_call fty fn [| const_int (i32_type context) 15 |] "" builder)
  end else if starts_with triple "arm" || starts_with triple "thumb" then begin
    let fty = function_type (void_type context) [| i32_type context |] in
    let fn = get_or_declare_intrinsic "llvm.arm.dsb" fty in
    ignore (build_call fty fn [| const_int (i32_type context) 15 |] "" builder)
  end else if starts_with triple "x86_64" || starts_with triple "i386"
       || starts_with triple "i486" || starts_with triple "i586"
       || starts_with triple "i686" then begin
    let fn = get_or_declare_intrinsic "llvm.x86.sse2.mfence" void_fn in
    ignore (build_call void_fn fn [||] "" builder)
  end else if starts_with triple "riscv32" || starts_with triple "riscv64" then begin
    let asm = match kind with
      | DmaPublish -> "fence w, o"
      | DmaConsume -> "fence i, r"
      | DeviceFence -> "fence iorw, iorw"
    in
    let inline = const_inline_asm void_fn asm "~{memory}" true false in
    ignore (build_call void_fn inline [||] "" builder)
  end else
    raise (Error (Printf.sprintf
      "DMA/device barriers are not implemented for target '%s'" triple))

(* A retained event avoids the check-then-sleep lost-wakeup race: ARM SEV
   sets the event register even if the matching WFE has not executed yet.
   WFE may also return spuriously, so source code must always re-check its
   flag in a loop.  Do not silently substitute WFI on targets without an
   equivalent retained notification -- that would reintroduce the race. *)
let emit_interrupt_event notify =
  let triple = target_triple the_module in
  let fty = function_type (void_type context) [||] in
  let asm =
    if starts_with triple "aarch64" || starts_with triple "arm"
       || starts_with triple "thumb" then
      if notify then "sev" else "wfe"
    else
      raise (Error (Printf.sprintf
        "interrupt event wait/notify is not implemented for target '%s'" triple))
  in
  let inline = const_inline_asm fty asm "~{memory}" true false in
  ignore (build_call fty inline [||] "" builder)

let setup_target ?(triple = "") ?(cpu = "") ?(features = "") () =
  let _ = Llvm_all_backends.initialize () in
  let triple = if triple = "" then Llvm_target.Target.default_triple () else triple in
  set_target_triple triple the_module;
  let target  = Llvm_target.Target.by_triple triple in
  let machine = Llvm_target.TargetMachine.create ~triple ~cpu ~features target in
  let layout  = Llvm_target.TargetMachine.data_layout machine in
  set_data_layout (Llvm_target.DataLayout.as_string layout) the_module;
  target_data := Some layout;
  machine

(* Run IR-level optimization passes.
   - Vectorization is disabled: AArch64 bare-metal may lack NEON.
   - "default<O2>" includes the loop-idiom pass, which replaces memset/memcpy-like loops
     with calls to external symbols -- causing link errors in bare-metal (no stdlib).
   - Custom pipeline with only the necessary passes:
     * mem2reg              : promote allocas to SSA registers (prerequisite for later passes)
     * early-cse            : basic common subexpression elimination
     * simplifycfg          : dead branch elimination for constant OOB (icmp uge const,const -> false -> block removed)
     * correlated-propagation: propagate i<N inside while(i<N){ arr[i] } loop bodies,
                               folding bounds-check icmp uge i, N to false
     * constraint-elimination: stronger constraint-based elimination (deduplicates range checks)
     * always-inline        : honor Takibi `inline fn` without enabling default<O2>/loop-idiom
                              (disabled for -g builds to keep GDB stepping/locals stable)
     * simplifycfg          : final cleanup of dead blocks *)
let run_optimizations machine =
  if !function_profiling_enabled then ()
  else
  let opts = Llvm_passbuilder.create_passbuilder_options () in
  Llvm_passbuilder.passbuilder_options_set_loop_vectorization opts false;
  Llvm_passbuilder.passbuilder_options_set_slp_vectorization opts false;
  let pipeline =
    if !debug_info_enabled then
      "function(mem2reg,early-cse,simplifycfg,\
                correlated-propagation,constraint-elimination,simplifycfg)"
    else
      "function(mem2reg,early-cse,simplifycfg,\
                correlated-propagation,constraint-elimination,simplifycfg),\
       always-inline,\
       function(mem2reg,early-cse,simplifycfg,\
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

(* usize's LLVM width follows the target's pointer size (32-bit on Cortex-M7,
   64-bit on AArch64/RISC-V64). Falls back to i64 when no target machine has
   been set up yet (unit tests construct IR via gen_program with no
   setup_target call -- see the codegen_tests group in test_takibi.ml -- so
   this must not raise/depend on Some). *)
let usize_lltype () =
  match !target_data with
  | Some dl -> Llvm_target.DataLayout.intptr_type context dl
  | None    -> i64_type context

let isize_lltype () = usize_lltype ()

type dma_cache_op = CacheClean | CacheInvalidate

(* Cortex-M7 exposes cache-line maintenance through the memory-mapped SCB
   DCCMVAC/DCIMVAC registers. The operation covers every 32-byte line touched
   by [ptr, ptr+len); callers must still ensure that DMA buffers do not share
   cache lines with unrelated mutable data. *)
let emit_cortex_m_cache_range op ptr len =
  let fn = block_parent (insertion_block builder) in
  let preheader = insertion_block builder in
  let cond_bb = append_block context "dma.cache.cond" fn in
  let body_bb = append_block context "dma.cache.body" fn in
  let done_bb = append_block context "dma.cache.done" fn in
  let ity = usize_lltype () in
  let addr = build_ptrtoint ptr ity "dma.addr" builder in
  let mask = const_int ity (-32) in
  let start = build_and addr mask "dma.line.start" builder in
  let end_unaligned = build_add addr len "dma.end.unaligned" builder in
  let end_rounded = build_and
    (build_add end_unaligned (const_int ity 31) "dma.end.plus31" builder)
    mask "dma.line.end" builder in
  ignore (build_br cond_bb builder);
  position_at_end cond_bb builder;
  let line = build_phi [(start, preheader)] "dma.line" builder in
  let nonempty = build_icmp Icmp.Ne len (const_null ity) "dma.nonempty" builder in
  let before_end = build_icmp Icmp.Ult line end_rounded "dma.before.end" builder in
  ignore (build_cond_br (build_and nonempty before_end "dma.cache.more" builder)
            body_bb done_bb builder);
  position_at_end body_bb builder;
  let reg_addr = match op with
    | CacheClean -> 0xE000EF68
    | CacheInvalidate -> 0xE000EF5C
  in
  let reg = const_inttoptr (const_int ity reg_addr) (pointer_type context) in
  let line32 = if ity = i32_type context then line
               else build_trunc line (i32_type context) "dma.line32" builder in
  let st = build_store line32 reg builder in
  set_volatile true st;
  let next = build_add line (const_int ity 32) "dma.line.next" builder in
  ignore (build_br cond_bb builder);
  add_incoming (next, body_bb) line;
  position_at_end done_bb builder

(* AArch64 has no memory-mapped cache-maintenance registers (unlike
   Cortex-M7's SCB above); `dc cvac`/`dc ivac` are real instructions, and
   LLVM exposes no intrinsic for arbitrary `dc` sub-operations. Rather than
   re-deriving a CFG loop by hand, this emits ONE self-contained inline-asm
   blob (loop and all) that is bit-for-bit the same algorithm as
   examples/common_rpi3/cache_asm.S's hand-written, hardware-verified
   dcache_clean_range/dcache_invalidate_range: line size read at runtime
   from CTR_EL0.DminLine (not hardcoded -- see that file's own comment for
   why a fixed constant would be wrong), start rounded down to a line
   boundary, end walked up to (not rounded). `${:uid}` makes the loop label
   unique per call site so this stays correct even if the same call is
   inlined more than once into one function (see issue #146). *)
let emit_aarch64_cache_range op ptr len =
  let ity = usize_lltype () in
  let addr = build_ptrtoint ptr ity "dma.addr" builder in
  let dc_insn, tail = match op with
    | CacheClean      -> "dc cvac, x13", "dsb ish"
    | CacheInvalidate -> "dc ivac, x13", "dsb ish\n\tisb"
  in
  let asm = Printf.sprintf
    "mrs x9, ctr_el0\n\
    \tubfx x9, x9, #16, #4\n\
    \tmov x10, #4\n\
    \tlsl x10, x10, x9\n\
    \tadd x11, $0, $1\n\
    \tsub x12, x10, #1\n\
    \tbic x13, $0, x12\n\
    .Ldmacache${:uid}:\n\
    \t%s\n\
    \tadd x13, x13, x10\n\
    \tcmp x13, x11\n\
    \tb.lo .Ldmacache${:uid}\n\
    \t%s"
    dc_insn tail
  in
  let fty = function_type (void_type context) [| ity; ity |] in
  let constraints =
    "r,r,~{x9},~{x10},~{x11},~{x12},~{x13},~{cc},~{memory}" in
  let inline = const_inline_asm fty asm constraints true false in
  ignore (build_call fty inline [| addr; len |] "" builder)

(* Test-only introspection: usize's current bit-width (32 or 64) as a plain
   int, so test_takibi.ml can assert on it without needing the `llvm`
   ocamlfind package linked directly (this library already depends on it). *)
let usize_bitwidth () = integer_bitwidth (usize_lltype ())
let isize_bitwidth () = integer_bitwidth (isize_lltype ())

let rec ltype_of_ast = function
  | TypeBool        -> i1_type  context
  | TypeI8  | TypeU8  -> i8_type  context
  | TypeI16 | TypeU16 -> i16_type context
  | TypeI32 | TypeU32 -> i32_type context
  | TypeI64 | TypeU64 -> i64_type context
  | TypeIsize       -> isize_lltype ()
  | TypeUsize       -> usize_lltype ()
  | TypeVoid        -> void_type context
  | TypeView (name, _) -> raise (Error (Printf.sprintf
      "internal error: erased view '%s' reached runtime layout" name))
  | TypeVariant name ->
      (match Hashtbl.find_opt variant_lltypes name with
       | Some llty -> llty
       | None -> raise (Error (Printf.sprintf "Unknown variant type: %s" name)))
  | TypeExists (_, _, body) -> ltype_of_ast body
  | TypePtr _       -> pointer_type context   (* LLVM 19: all pointers are opaque ptr *)
  | TypeIo  t       -> ltype_of_ast t         (* io T is a value type: LLVM type is the same as T *)
  | TypeArray (t, n) -> array_type (ltype_of_ast t) n
  | TypeFn _        -> pointer_type context   (* function pointers are also opaque ptr *)
  | TypeRefined (_, _, base) -> ltype_of_ast base
    (* Representation follows the refined range's own base (see
       types.ml's TRefinedInt comment) -- was unconditionally i32_type
       before "Refinement Numerical Type" generalized TRefinedInt to carry
       a base. For-loop counters likewise retain their inferred or explicit
       integer base, so their refined LLVM width follows that base. *)
  | TypeSlice _     ->
      (* Fat value {ptr, len}: len width follows the target pointer size
         (usize), so the layout is {ptr, i32} on Cortex-M and {ptr, i64} on
         AArch64. Passed by value; LLVM lowers small aggregates to register
         pairs on both targets. *)
      struct_type context [| pointer_type context; usize_lltype () |]
  | TypeNamed sname ->
      (match Hashtbl.find_opt variant_lltypes sname with
       | Some llty -> llty
       | None ->
      match Hashtbl.find_opt enum_underlying sname with
       | Some ut -> ltype_of_ast ut   (* enum: integer type of the underlying type *)
       | None ->
           match Hashtbl.find_opt struct_lltypes sname with
           | Some llty -> llty
           | None -> raise (Error (Printf.sprintf "Unknown named type: %s" sname)))
  | TypeIndexed (sname, _) ->
      (match Hashtbl.find_opt struct_lltypes sname with
       | Some llty -> llty
       | None -> raise (Error (Printf.sprintf "Unknown indexed type: %s" sname)))
  | TypeSingleton (t, _) -> ltype_of_ast t
  | TypeTuple ts ->
      (* Function-local product value (OWNERSHIP_KERNEL.md 5.9): an
         anonymous struct, passed/returned by value like TypeSlice's fat
         value just above -- LLVM's ABI lowering handles by-value
         aggregates on both targets. *)
      struct_type context (Array.of_list (List.map ltype_of_ast ts))
  | TypeBorrow t | TypeSink t -> ltype_of_ast t
  | TypeBorrowMut _ -> pointer_type context
  | TypeAlignedPtr _ -> pointer_type context

(* DWARF Attribute Type Encoding constants (DWARF5 spec section 7.8, table 7.11).
   Llvm_debuginfo has no named enum for these -- they're stable spec constants,
   not an implementation detail of this compiler, so hardcoding is fine. *)
let dw_ate_boolean        = 0x02
let dw_ate_signed         = 0x05
let dw_ate_unsigned       = 0x07
let dw_tag_structure_type = 0x13

(* One DIType cache per named aggregate/enum. Structs also keep a permanent
   forward declaration so self-referential pointer fields can terminate
   without requiring LLVM's temporary-node RAUW API, which the OCaml binding
   does not expose. *)
let di_struct_placeholders : (string, llmetadata) Hashtbl.t = Hashtbl.create 8
let di_struct_types : (string, llmetadata) Hashtbl.t = Hashtbl.create 8
let di_struct_in_progress : (string, unit) Hashtbl.t = Hashtbl.create 8
let di_enum_types : (string, llmetadata) Hashtbl.t = Hashtbl.create 8
let di_slice_types : (string, llmetadata) Hashtbl.t = Hashtbl.create 8

let di_size_align_bits (ty : lltype) : int * int =
  match !target_data with
  | Some dl ->
      (Int64.to_int (Llvm_target.DataLayout.abi_size ty dl) * 8,
       Llvm_target.DataLayout.abi_align ty dl * 8)
  | None ->
      let bits =
        match classify_type ty with
        | TypeKind.Integer -> integer_bitwidth ty
        | TypeKind.Pointer -> integer_bitwidth (usize_lltype ())
        | _ -> 0
      in
      (bits, bits)

let di_struct_placeholder dib file sname =
  match Hashtbl.find_opt di_struct_placeholders sname with
  | Some placeholder -> placeholder
  | None ->
      let (size_bits, align_bits) =
        match Hashtbl.find_opt struct_lltypes sname with
        | Some llty -> di_size_align_bits llty
        | None -> (0, 0)
      in
      let placeholder =
        Llvm_debuginfo.dibuild_create_forward_decl dib ~tag:dw_tag_structure_type
          ~name:sname ~scope:file ~file ~line:0 ~runtime_lang:0
          ~size_in_bits:size_bits ~align_in_bits:align_bits
          ~unique_identifier:("takibi.struct.fwd." ^ sname)
      in
      Hashtbl.add di_struct_placeholders sname placeholder;
      placeholder

let rec di_is_unsigned = function
  | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeUsize -> true
  | TypeRefined (_, _, base) -> di_is_unsigned base
  | _ -> false

(* DIType for a variable's declared type (parameters / `let mut` locals /
   globals). This intentionally favors debugger usability over just enough
   metadata for line tables: globals get named enum types, structs get member
   layout, and slices are represented as their actual {ptr,len} fat value. *)
let rec ditype_of_ast (dib : Llvm_debuginfo.lldibuilder) (file : llmetadata) (ty : Ast.type_expr) : llmetadata =
  let basic_int name bits encoding =
    Llvm_debuginfo.dibuild_create_basic_type dib ~name ~size_in_bits:bits ~encoding
      (Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero)
  in
  match ty with
  | TypeView _ -> Llvm_debuginfo.llmetadata_null ()
  | TypeVariant _ -> Llvm_debuginfo.llmetadata_null ()
    (* Slice 3 preserves the complete runtime aggregate in LLVM IR. A
       source-level tagged-union DIType is deferred until the surface form
       and debugger presentation have settled. *)
  | TypeExists (_, _, body) -> ditype_of_ast dib file body
  | TypeSingleton (base, _) -> ditype_of_ast dib file base
  | TypeIndexed (name, _) -> ditype_of_ast dib file (TypeNamed name)
  | TypeBool -> basic_int "bool" 8 dw_ate_boolean
  | TypeI8    -> basic_int "i8"    8  dw_ate_signed
  | TypeI16   -> basic_int "i16"   16 dw_ate_signed
  | TypeI32   -> basic_int "i32"   32 dw_ate_signed
  | TypeI64   -> basic_int "i64"   64 dw_ate_signed
  | TypeU8    -> basic_int "u8"    8  dw_ate_unsigned
  | TypeU16   -> basic_int "u16"   16 dw_ate_unsigned
  | TypeU32   -> basic_int "u32"   32 dw_ate_unsigned
  | TypeU64   -> basic_int "u64"   64 dw_ate_unsigned
  | TypeIsize -> basic_int "isize" (integer_bitwidth (isize_lltype ())) dw_ate_signed
  | TypeUsize -> basic_int "usize" (integer_bitwidth (usize_lltype ())) dw_ate_unsigned
  | TypeVoid  -> Llvm_debuginfo.llmetadata_null ()
  | TypeRefined (_, _, base) -> ditype_of_ast dib file base  (* same LLVM-level representation as its base; see ltype_of_ast *)
  | TypeTuple _ -> Llvm_debuginfo.llmetadata_null ()
    (* v1: no DWARF type for tuples (function-local values; -g builds work,
       tuple-typed variables just carry no type info in gdb) *)
  | TypeBorrow t | TypeSink t -> ditype_of_ast dib file t
  | TypeBorrowMut t -> ditype_of_ast dib file (TypePtr t)
  | TypeAlignedPtr (_, t) -> ditype_of_ast dib file (TypePtr t)
      (* alignment is a compile-time-only proof (see ltype_of_ast); gdb
         just sees an ordinary pointer *)
  | TypeIo t       -> ditype_of_ast dib file t       (* io T is a value type at the LLVM level too; see ltype_of_ast *)
  | TypePtr t ->
      let ptr_bits = integer_bitwidth (usize_lltype ()) in
      Llvm_debuginfo.dibuild_create_pointer_type dib ~pointee_ty:(ditype_of_ast dib file t)
        ~size_in_bits:ptr_bits ~align_in_bits:ptr_bits ~address_space:0 ~name:""
  | TypeArray (t, n) ->
      let elem_bits =
        match !target_data with
        | Some dl -> Int64.to_int (Llvm_target.DataLayout.abi_size (ltype_of_ast t) dl) * 8
        | None    -> 0
      in
      Llvm_debuginfo.dibuild_create_array_type dib ~size:(elem_bits * n) ~align_in_bits:0
        ~ty:(ditype_of_ast dib file t) ~subscripts:[||]
  | TypeFn (params, ret, _) ->
      let ret_ty = ditype_of_ast dib file ret in
      let param_tys = List.map (ditype_of_ast dib file) params in
      let sub_ty =
        Llvm_debuginfo.dibuild_create_subroutine_type dib ~file
          ~param_types:(Array.of_list (ret_ty :: param_tys))
          (Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero)
      in
      let ptr_bits = integer_bitwidth (usize_lltype ()) in
      Llvm_debuginfo.dibuild_create_pointer_type dib ~pointee_ty:sub_ty
        ~size_in_bits:ptr_bits ~align_in_bits:ptr_bits ~address_space:0 ~name:""
  | TypeSlice (elem_ty, min_len) ->
      let name =
        if min_len = 0
        then Printf.sprintf "[]%s" (ty_str elem_ty)
        else Printf.sprintf "[%s; %d..]" (ty_str elem_ty) min_len
      in
      (match Hashtbl.find_opt di_slice_types name with
       | Some slice_ty -> slice_ty
       | None ->
           let llty = ltype_of_ast ty in
           let (size_bits, align_bits) = di_size_align_bits llty in
           let ptr_bits = integer_bitwidth (usize_lltype ()) in
           let ptr_ty = ditype_of_ast dib file (TypePtr elem_ty) in
           let len_ty = ditype_of_ast dib file TypeUsize in
           let flags = Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero in
           let ptr_member =
             Llvm_debuginfo.dibuild_create_member_type dib ~scope:file ~name:"ptr"
               ~file ~line_number:0 ~size_in_bits:ptr_bits ~align_in_bits:ptr_bits
               ~offset_in_bits:0 flags ~ty:ptr_ty
           in
           let len_member =
             Llvm_debuginfo.dibuild_create_member_type dib ~scope:file ~name:"len"
               ~file ~line_number:0 ~size_in_bits:ptr_bits ~align_in_bits:ptr_bits
               ~offset_in_bits:ptr_bits flags ~ty:len_ty
           in
           let slice_ty =
             Llvm_debuginfo.dibuild_create_struct_type dib ~scope:file ~name ~file
               ~line_number:0 ~size_in_bits:size_bits ~align_in_bits:align_bits
               flags ~derived_from:(Llvm_debuginfo.llmetadata_null ())
               ~elements:[| ptr_member; len_member |]
               Llvm_debuginfo.DWARFSourceLanguageKind.C
               ~vtable_holder:(Llvm_debuginfo.llmetadata_null ())
               ~unique_id:("takibi.slice." ^ name)
           in
           Hashtbl.add di_slice_types name slice_ty;
           slice_ty)
  | TypeNamed sname ->
      (match Hashtbl.find_opt enum_underlying sname with
       | Some ut ->
           (match Hashtbl.find_opt di_enum_types sname with
            | Some enum_ty -> enum_ty
            | None ->
                let llty = ltype_of_ast ut in
                let (size_bits, align_bits) = di_size_align_bits llty in
                let elements =
                  Hashtbl.find enum_variants_tbl sname
                  |> List.map (fun (vname, value) ->
                    Llvm_debuginfo.dibuild_create_enumerator dib
                      ~name:(sname ^ "::" ^ vname)
                      ~value
                      ~is_unsigned:(di_is_unsigned ut))
                  |> Array.of_list
                in
                let enum_ty =
                  Llvm_debuginfo.dibuild_create_enumeration_type dib
                    ~scope:file ~name:sname ~file ~line_number:0
                    ~size_in_bits:size_bits ~align_in_bits:align_bits
                    ~elements ~class_ty:(Llvm_debuginfo.llmetadata_null ())
                in
                Hashtbl.add di_enum_types sname enum_ty;
                enum_ty)
       | None ->
           match Hashtbl.find_opt di_struct_types sname with
           | Some struct_ty -> struct_ty
           | None when Hashtbl.mem di_struct_in_progress sname ->
               di_struct_placeholder dib file sname
           | None ->
               let llty = match Hashtbl.find_opt struct_lltypes sname with
                 | Some llty -> llty
                 | None -> raise (Error (Printf.sprintf "Unknown named type: %s" sname))
               in
               let fields = match Hashtbl.find_opt struct_fields sname with
                 | Some fields -> fields
                 | None -> []
               in
               Hashtbl.add di_struct_in_progress sname ();
               let (size_bits, align_bits) = di_size_align_bits llty in
               let flags = Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero in
               let elements =
                 fields
                 |> List.mapi (fun i (fname, fty) ->
                   let f_llty = ltype_of_ast fty in
                   let (f_size_bits, f_align_bits) = di_size_align_bits f_llty in
                   let offset_bits =
                     match !target_data with
                     | Some dl -> Int64.to_int (Llvm_target.DataLayout.offset_of_element llty i dl) * 8
                     | None ->
                         (match const_field_offset sname fname with
                          | Some off -> off * 8
                          | None -> 0)
                   in
                   Llvm_debuginfo.dibuild_create_member_type dib
                     ~scope:file ~name:fname ~file ~line_number:0
                     ~size_in_bits:f_size_bits ~align_in_bits:f_align_bits
                     ~offset_in_bits:offset_bits flags ~ty:(ditype_of_ast dib file fty))
                 |> Array.of_list
               in
               let struct_ty =
                 Llvm_debuginfo.dibuild_create_struct_type dib ~scope:file ~name:sname ~file
                   ~line_number:0 ~size_in_bits:size_bits ~align_in_bits:align_bits
                   flags ~derived_from:(Llvm_debuginfo.llmetadata_null ())
                   ~elements
                   Llvm_debuginfo.DWARFSourceLanguageKind.C
                   ~vtable_holder:(Llvm_debuginfo.llmetadata_null ())
                   ~unique_id:("takibi.struct." ^ sname)
               in
               Hashtbl.remove di_struct_in_progress sname;
               Hashtbl.add di_struct_types sname struct_ty;
               struct_ty)

(* True for unsigned integer types (use udiv/urem/icmp ult etc.). Recurses
   into a refined type's own base -- this is what fixes the BinOp i32/i64
   width-sync's sign- vs zero-extension choice (see CLAUDE.md's
   "Refinement Numerical Type" section): before TRefinedInt carried a
   base, this always returned false for ANY refined value, so widening one
   in a mixed-width BinOp always sign-extended, which only ever happened
   to be safe because the old i32-guess fallback for bare literals never
   produced a refined value with the sign bit set. *)
let rec is_unsigned = function
  | TypeU8 | TypeU16 | TypeU32 | TypeU64 | TypeUsize -> true
  | TypeRefined (_, _, base) -> is_unsigned base
  | TypeSingleton (base, _) -> is_unsigned base
  | _ -> false

let rec erase_singleton_type = function
  | TypeSingleton (base, _) -> erase_singleton_type base
  | t -> t

(* Sync rule with type_inf.ml's min_max_sentinel: the "unknown bound"
   placeholder must itself be a legal value of whichever base type the
   result is tagged with, or a fully-unconstrained min/max call on a
   narrow type would disagree with what type_inf.ml already proved.
   Operates on Ast.type_expr (already fully resolved by codegen time, no
   repr needed here). *)
let min_max_sentinel base =
  match base with
  | TypeI8  -> (-128, 128)
  | TypeI16 -> (-32768, 32768)
  | TypeU8  -> (0, 256)
  | TypeU16 -> (0, 65536)
  | t when is_unsigned t -> (0, 1_000_000_000)
  | _ -> (-1_000_000_000, 1_000_000_000)

(* Widen TypeRefined to its own base type; leave explicit-width types
   unchanged. Mirrors type_inf.ml's canon_ty (sync rule): codegen needs
   this too now that a refined value's LLVM representation width follows
   its base (see ltype_of_ast) -- a "give up on refinement" fallback must
   return the refined value's OWN base, not a hardcoded TypeI32, or the
   returned ast_type would disagree with the actual (possibly i64-wide)
   llvalue just computed. *)
let rec canon_ty = function
  | TypeSingleton (base, _) -> canon_ty base
  | TypeRefined (_, _, base) -> base
  | t -> t

(* A singleton adds an equality fact without discarding the range carried by
   its runtime base. Bounds proof sites must inspect through that checker-only
   wrapper; otherwise `{0..<N} @ n` spuriously regains a runtime trap. *)
let rec refinement_range = function
  | TypeSingleton (base, _) -> refinement_range base
  | TypeRefined (lo, hi, _) -> Some (lo, hi)
  | _ -> None

(* Extract a small-number-scoped compile-time integer from an expression,
   iff it is exactly an integer literal that fits natively (see
   Ast.int_of_intlit's comment for why IntLit's Int64.t payload cannot
   always be narrowed to `int`). Used throughout the range-propagation
   mirror of type_inf.ml's BinOp typing below (sync rule: both sides must
   make the same decision). None uniformly covers both "not a literal at
   all" and "a literal, but too large to reason about here" -- both fall
   back to the conservative (unrefined) case. *)
let intlit_opt (e : Ast.expr) : int option =
  match e.desc with
  | Ast.IntLit k -> Ast.int_of_intlit k
  | _ -> None

(* Widen a loaded value to the arithmetic width (i32 or i64).
   i8/u8/i16/u16 -> i32 (C-style integer promotion).
   i32/u32/int   -> i32 (no-op for i32 values).
   i64/u64       -> i64 (keep as-is).
   Signed types use sext; unsigned types use zext.
   TypeRefined recurses into its own base (sync note: this was MISSED when
   TRefinedInt/TypeRefined was generalized to carry a non-i32 base -- see
   CLAUDE.md's "Refinement Numerical Type" section. Before that
   generalization every TypeRefined value was i32-shaped in memory, so the
   old `| _ -> v` fallthrough here was a harmless no-op (the value was
   already the right width). Once a TypeRefined value can genuinely be
   i8/i16-shaped (e.g. base = u8, from `let x: u8 = a & mask;`), the same
   fallthrough silently returned an UN-widened narrow value to a caller
   that assumes arithmetic-width input -- e.g. a later `x * 4` emitted
   `mul i8 %x, i32 4`, an LLVM type mismatch caught by gen_func's own IR
   verifier. Found via a real regression while testing the new explicit
   -base `{lo..<hi as base}` surface syntax, the first construct to
   exercise an Imm binding holding a genuinely narrow-based TypeRefined
   value used again in later arithmetic.) *)
let rec widen_load (ast_ty : Ast.type_expr) v =
  match ast_ty with
  | TypeSingleton (base, _) -> widen_load base v
  | TypeRefined (_, _, base) -> widen_load base v
  | TypeI64 | TypeU64 | TypeIsize | TypeUsize -> v
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
  | TypeVoid | TypeView _ -> void_type context
  | t        -> ltype_of_ast t

(* Coerce an llvalue to match a destination AST type.
   Invariant: arithmetic values arrive here at i32 (for <=32-bit types) or i64 (for 64-bit types).
   Handles truncation to narrow types, extension to i64, bool conversion,
   and integer -> pointer conversion (inttoptr) for MMIO addresses. *)
let rec coerce v (dst : Ast.type_expr) =
  if is_erased_view_type dst then v
  else
  let vty    = type_of v in
  let dst_ll = ltype_of_ast dst in
  if vty = dst_ll then v
  else match dst with
  | TypeTuple ts ->
      (* Element-wise re-coercion: a tuple built from unhinted literals can
         carry narrower component widths than the destination expects. *)
      let (agg, _) = List.fold_left (fun (agg, i) t ->
        let cv = build_extractvalue v i "tupc" builder in
        (build_insertvalue agg (coerce cv t) i "tupc" builder, i + 1))
        (undef dst_ll, 0) ts in
      agg
  | TypePtr _ | TypeAlignedPtr _ ->
      (* inttoptr auto-truncates/zero-extends the source integer to the
         pointer width per the LLVM LangRef, so no manual width-matching
         step is needed -- this works whether the pointer is 32-bit
         (Cortex-M7) or 64-bit (AArch64) without knowing which. *)
      build_inttoptr v (pointer_type context) "inttoptr" builder
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
  | TypeIsize ->
      let dst_ty = isize_lltype () in
      let src_bits = integer_bitwidth vty and dst_bits = integer_bitwidth dst_ty in
      if src_bits > dst_bits then build_trunc v dst_ty "trunc" builder
      else if src_bits < dst_bits then build_sext v dst_ty "sext" builder
      else v
  | TypeUsize ->
      let dst_ty = usize_lltype () in
      if vty = pointer_type context then
        (* ptrtoint auto-adjusts to dst_ty's width, whatever it is. *)
        build_ptrtoint v dst_ty "ptrtoint" builder
      else
        let src_bits = integer_bitwidth vty and dst_bits = integer_bitwidth dst_ty in
        if src_bits > dst_bits then build_trunc v dst_ty "trunc" builder
        else if src_bits < dst_bits then build_zext v dst_ty "zext" builder
        else v
  | TypeBool ->
      if vty = i1_type context then v
      else build_icmp Icmp.Ne v (const_int vty 0) "tobool" builder
  | TypeIo t    -> coerce v t
  | TypeVoid    -> v
  | TypeArray _ -> v
  | TypeFn _    -> v
  | TypeVariant _ -> v
  | TypeExists (_, _, body) -> coerce v body
  | TypeNamed _ ->
      (* A struct-typed value is always carried internally as a pointer
         to its alloca (see Var's TypeNamed case) -- field access, struct
         arguments to `*Struct`-typed parameters, etc. all want that
         pointer, so coerce leaves it alone in every context except the
         two places the ABI genuinely needs the AGGREGATE value itself:
         `return <struct-local>;` from a function whose own return type
         is that struct (by value, not `*Struct`), and passing a struct
         local to a by-value (not `*Struct`) call argument. Both funnel
         through this same coerce call. Loading here whenever the source
         is a pointer but the destination is the bare aggregate type
         fixes both without a separate special case at either call site.
         Enum-typed destinations never reach this branch: Var already
         yields the loaded underlying integer for an enum (not a
         pointer), so `vty = dst_ll` is already true above and this
         whole match arm is skipped. *)
      if vty = pointer_type context then build_load dst_ll v "structval" builder
      else v
  | TypeIndexed _ -> v
  | TypeSingleton (base, _) -> coerce v base
  | TypeRefined (_, _, base) -> coerce v base
  | TypeSlice _ -> v   (* fat values are never numerically coerced *)
  | TypeBorrow t | TypeSink t -> coerce v t
  | TypeBorrowMut _ -> v
  | TypeView _ -> v

(* Normalize an index/offset value to usize width for use as a GEP index --
   used by Index/AssignIndex/SliceOf. The old path unconditionally
   truncated to i32 even for a genuinely i64/usize-typed index. On a
   64-bit target (usize = i64) that silently discarded the index's upper
   bits, corrupting any access into a buffer needing more than 2^31
   elements to address -- a real correctness gap given a genuine 64-bit
   address space, even though no actual bare-metal target this project
   ships for has anywhere near enough RAM to trigger it today.
   is_signed controls sext vs zext when WIDENING a narrower type (matches
   the value's own signedness. Raw-pointer offsets are isize and array/slice
   indices are usize, so both already have target pointer width after type
   checking; the extension logic remains useful for literal/intermediate IR;
   only truncates when the source is genuinely WIDER than usize. *)
let to_index_width ~is_signed v =
  let ty = type_of v in
  let target = usize_lltype () in
  if ty = target || ty = pointer_type context then v
  else
    let src_bits = integer_bitwidth ty and dst_bits = integer_bitwidth target in
    if src_bits > dst_bits then build_trunc v target "idxtrunc" builder
    else if src_bits < dst_bits then
      (if is_signed then build_sext v target "idxsext" builder
       else build_zext v target "idxzext" builder)
    else v

(* Promote a value to its arithmetic width based on its AST type.
   <=32-bit types -> i32.  64-bit types -> i64.  bool -> i1 (unchanged).
   Replaces to_i32 for new explicit-width types. *)
let to_arith_width (ast_ty : Ast.type_expr) v = widen_load ast_ty v

(* All 4 call sites (If/While condition codegen, Or/And operand codegen)
   correspond exactly to type_inf.ml's check_cond call sites, which now
   requires TBool (i1) unconditionally -- no more C-style int-truthy
   fallback (see check_cond's own comment). A non-i1 value here would mean
   the type checker's invariant was violated, not a legitimate case to
   silently coerce via `icmp ne 0` like the old fallback did. *)
let as_cond v =
  if type_of v = i1_type context then v
  else raise (Error (Printf.sprintf
    "internal error: as_cond expected i1 (bool), got %s -- type checker's \
     bool-only condition invariant was violated" (string_of_lltype (type_of v))))

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
   For-loop counters ("__for_<name>") are also pre-allocated here.
   Each entry also carries the originating statement's loc, used to give the
   DWARF DILocalVariable (see gen_func) its declaration line -- Let itself
   is the located node, so this is the same loc gen_stmt would attach to it. *)
let rec collect_lets stmts =
  List.concat_map (fun s ->
    match s.desc with
    | Let (true, name, ty_opt, _, align_opt) -> [(name, ty_opt, s.loc, align_opt)]
    | Block ss                    -> collect_lets ss
    | If (_, t, e)                -> collect_lets t @ collect_lets e
    | While (_, b)                -> collect_lets b
    | For (name, _, _, _, body)   ->
        (* type_inf.ml's For case now registers "__for_<name>" in
           raw_locals with the bounds' own base type (sync rule), so
           resolve_local_ast finds the real type via local_types --
           `None` here is a dead fallback, never actually consulted, but
           kept `None` (rather than the old hardcoded `Some TypeI32`) so
           it doesn't misleadingly suggest i32 is still the answer. *)
        ("__for_" ^ name, None, s.loc, None) :: collect_lets body
    | ForEach (name, _, body)     -> ("__foreach_" ^ name, Some TypeUsize, s.loc, None) :: collect_lets body
    | Match (_, arms)             ->
        List.concat_map (fun arm ->
          match arm with
          | ArmVariant (_, _, _, body) -> collect_lets body
          | ArmWild body            -> collect_lets body
        ) arms
    | _                           -> []
  ) stmts

let mutable_pattern_key loc vtype cname name =
  Printf.sprintf "%s:%s:%s:%s" (Types.loc_key loc) vtype cname name

(* Mutable variant payloads need stable storage because `borrow mut` passes
   their address to callees. Pre-collect them just like mutable lets so a
   match inside a loop does not execute an alloca on every iteration. *)
let rec collect_mutable_pattern_binders stmts =
  List.concat_map (fun (s : Ast.stmt) ->
    match s.desc with
    | Block body | While (_, body) | For (_, _, _, _, body)
    | ForEach (_, _, body) -> collect_mutable_pattern_binders body
    | If (_, yes, no) ->
        collect_mutable_pattern_binders yes
        @ collect_mutable_pattern_binders no
    | Match (_, arms) ->
        List.concat_map (fun arm ->
          match arm with
          | ArmVariant (vtype, cname, binding, body) ->
              let here = match binding with
                | Some (name, true) ->
                    let layout = variant_case vtype cname in
                    let schema = match layout.variant_payload with
                      | Some schema -> schema
                      | None -> raise (Error (Printf.sprintf
                          "BUG: nullary variant %s::%s has a mutable binder"
                          vtype cname))
                    in
                    let payload_ty = runtime_payload_type schema in
                    if is_erased_view_type payload_ty then []
                    else [(mutable_pattern_key s.loc vtype cname name,
                           name, payload_ty, s.loc)]
                | _ -> []
              in
              here @ collect_mutable_pattern_binders body
          | ArmWild body -> collect_mutable_pattern_binders body
        ) arms
    | Let _ | LetTuple _ | Return _ | Expr _ | Assign _ | AssignDeref _
    | AssignField _ | AssignIndex _ | Break | Continue -> []
  ) stmts

(* Immutable `let` bindings normally stay as SSA values (Imm) so codegen can
   keep using the existing narrowing/range machinery. Under -g, however, GDB
   needs a stable address for `info locals` / `p name`; Llvm_debuginfo exposes
   dbg.declare but not dbg.value. collect_immutable_lets lets gen_func create
   a debug-only alloca for each immutable binding while leaving the real
   codegen binding as Imm. *)
let rec collect_immutable_lets stmts =
  List.concat_map (fun s ->
    match s.desc with
    | Let (false, name, ty_opt, Some _, _) -> [(name, ty_opt, s.loc)]
    | LetTuple (names, _)          -> List.map (fun name -> (name, None, s.loc)) names
    | Block ss                    -> collect_immutable_lets ss
    | If (_, t, e)                -> collect_immutable_lets t @ collect_immutable_lets e
    | While (_, b)                -> collect_immutable_lets b
    | For (_, _, _, _, body)      -> collect_immutable_lets body
    | ForEach (_, _, body)        -> collect_immutable_lets body
    | Match (_, arms)             ->
        List.concat_map (fun arm ->
          match arm with
          | ArmVariant (_, _, _, body) -> collect_immutable_lets body
          | ArmWild body            -> collect_immutable_lets body
        ) arms
    | _                           -> []
  ) stmts

(* -- resolve helpers: map AST annotation -> Ast.type_expr using HM results -- *)

(* `pt = None` (no type-inference results at all) is a genuine, supported
   mode -- unit tests build IR via gen_program with no prior inference pass
   (see usize_lltype's own comment for the same convention) -- so THAT
   fallback stays a graceful default, not a bug.

   Once `pt = Some _` (a fully type-checked program IS available), the
   ENCLOSING FUNCTION (`fname`) failing to resolve within it is an internal
   inconsistency: gen_program's Pass 1 registers every function's signature
   before Pass 2 ever asks to resolve one of its locals, so this should be
   structurally unreachable -- raise loudly rather than silently guessing.

   A specific LOCAL/PARAMETER `name` failing to resolve within an
   otherwise-found function is different: llvm_gen.ml's own `collect_lets`
   synthesizes names type_inf.ml never registers at all (e.g.
   `"__foreach_" ^ name` for a for-in loop's slice index, paired with an
   explicit `Some TypeUsize` hint) purely for DWARF variable declarations
   -- a real, legitimate case, not a bug. So `ty_opt` (an explicit hint
   from the caller) is still honored here; only "neither inference nor an
   explicit hint has anything to say" is the truly-unreachable case worth
   raising on. *)
let resolve_local_ast (pt : Types.program_types option) fname name ty_opt =
  let resolved = match pt with
    | None -> (match ty_opt with Some t -> t | None -> TypeI32)
    | Some pt ->
        match Types.StringMap.find_opt fname pt.Types.functions with
        | None -> raise (Error (Printf.sprintf
            "BUG: resolve_local_ast: function '%s' not found in type-checked program" fname))
        | Some fi ->
            (match List.assoc_opt name fi.Types.param_types with
             | Some t -> t
             | None ->
                 match Types.StringMap.find_opt name fi.Types.local_types with
                 | Some t -> t
                 | None ->
                     match ty_opt with
                     | Some t -> t
                     | None -> raise (Error (Printf.sprintf
                         "BUG: resolve_local_ast: '%s' in function '%s' not found in \
                          type-checked program and no explicit type hint was given"
                         name fname)))
  in
  resolve_special_type resolved

let resolve_ret_ast (pt : Types.program_types option) fname ty_opt =
  let resolved = match pt with
    | None -> (match ty_opt with Some t -> t | None -> TypeVoid)
    | Some pt ->
        match Types.StringMap.find_opt fname pt.Types.functions with
        | None -> raise (Error (Printf.sprintf
            "BUG: resolve_ret_ast: function '%s' not found in type-checked program" fname))
        | Some fi -> fi.Types.ret_type
  in
  resolve_special_type resolved

let function_key (pt : Types.program_types option) (fdef : Ast.func) =
  match pt with
  | None -> fdef.name
  | Some pt ->
      let declared = List.map snd fdef.params in
      let rec abi_type = function
        | TypeNamed name when Hashtbl.mem erased_view_names name -> TypeView (name, [])
        | TypeIndexed (name, _) when Hashtbl.mem erased_view_names name ->
            TypeView (name, [])
        | TypeNamed name when Hashtbl.mem variant_defs name -> TypeVariant name
        | TypeView (name, _) -> TypeView (name, [])
        | TypeVariant name -> TypeVariant name
        | TypeExists (_, _, body) -> abi_type body
        | TypeBorrow t | TypeBorrowMut t | TypeSink t
        | TypeAlignedPtr (_, t) -> abi_type t
        | TypeSingleton (t, _) -> abi_type t
        | TypeIndexed (name, _) -> TypeIndexed (name, [])
        | t -> t
      in
      let matches _ fi =
        List.length declared = List.length fi.Types.param_types &&
        List.for_all2 (fun d (_, actual) -> match d with
          | Some t -> abi_type t = abi_type actual | None -> true) declared fi.Types.param_types
      in
      let candidates = Types.StringMap.bindings pt.Types.functions
        |> List.filter (fun (key, fi) ->
             (key = fdef.name || String.starts_with ~prefix:("_TK_" ^ fdef.name ^ "__") key)
             && matches key fi)
      in
      match candidates with
      | [(key, _)] -> key
      | _ -> fdef.name

(* -- Runtime trap checks -------------------------------------------------- *)
(* Branch to llvm.trap when [bad] is true, then continue at a fresh block.
   Shared tail of every runtime check codegen emits. *)
let emit_trap_when bad ~bad_name ~ok_name =
  let cur_f  = block_parent (insertion_block builder) in
  let bad_bb = append_block context bad_name cur_f in
  let ok_bb  = append_block context ok_name  cur_f in
  ignore (build_cond_br bad bad_bb ok_bb builder);
  position_at_end bad_bb builder;
  let trap_ft = function_type (void_type context) [||] in
  let trap_fn = declare_function "llvm.trap" trap_ft the_module in
  ignore (build_call trap_ft trap_fn [||] "" builder);
  ignore (build_unreachable builder);
  position_at_end ok_bb builder

(* Bounds check for [T; N] arrays. Traps via llvm.trap when idx >= N (unsigned compare).
   The unsigned compare also catches negative indices (idx < 0) as too-large unsigned values.
   n_llv is built at idx_v's OWN width (usize width via to_index_width, not
   hardcoded i32): comparing a usize-width idx_v against a hardcoded i32
   constant would be an LLVM type mismatch on a 64-bit target. *)
let emit_bounds_check loc idx_ty idx_v n =
  record_trap loc (Printf.sprintf
    "array bounds check remains: index type %s cannot prove range {0..<%d}"
    (ty_str idx_ty) n);
  let n_llv = const_int (type_of idx_v) n in
  let cmp   = build_icmp Icmp.Uge idx_v n_llv "oob_cmp" builder in
  emit_trap_when cmp ~bad_name:"oob" ~ok_name:"idx_ok"

(* Checked refined cast: `expr as {lo..<hi}` where the source type cannot
   prove the target range. Mirrors `int as ExhaustiveEnum` (switch + trap):
   the cast is the explicit, runtime-checked bridge from unproven integers
   into a refined type, and under --forbid-trap it becomes a compile error
   unless the source range is provable.
   Signed compare is correct here: every unproven source arrives either
   i32-widened (widen_load invariant) or as a genuine i64 (i64/u64/usize);
   a u64 bit pattern >= 2^63 compares negative and correctly traps. *)
let emit_refined_cast_check loc src_ty v lo hi =
  record_trap loc (Printf.sprintf
    "checked cast remains: %s as {%d..<%d} needs a runtime range check"
    (ty_str src_ty) lo hi);
  let v = if type_of v = i1_type context
          then build_zext v (i32_type context) "zext" builder else v in
  let cty = type_of v in
  let lt  = build_icmp Icmp.Slt v (const_int cty lo) "rc_lt" builder in
  let ge  = build_icmp Icmp.Sge v (const_int cty hi) "rc_ge" builder in
  let bad = build_or lt ge "rc_bad" builder in
  emit_trap_when bad ~bad_name:"rc_trap" ~ok_name:"rc_ok"

(* Bounds check against a slice's RUNTIME length (a usize-width value).
   The index arrives i32-widened (widen_load invariant); zext to the
   length's width first -- a negative i32 zext-widens to a huge unsigned
   value, so the single unsigned compare catches both directions.
   min_len only feeds the trap-site message. *)
let emit_bounds_check_dyn loc idx_ty idx_v min_len len_v =
  record_trap loc (Printf.sprintf
    "slice bounds check remains: index type %s cannot prove range {0..<%d} \
     (the slice's compile-time minimum length)"
    (ty_str idx_ty) min_len);
  let lw = type_of len_v in
  let idx_w = if type_of idx_v = lw then idx_v
              else build_zext idx_v lw "zext" builder in
  let cmp = build_icmp Icmp.Uge idx_w len_v "oob_cmp" builder in
  emit_trap_when cmp ~bad_name:"oob" ~ok_name:"idx_ok"

(* -- Slice (fat value {ptr, len}) helpers --------------------------------- *)

let slice_ptr fat = build_extractvalue fat 0 "s_ptr" builder
let slice_len fat = build_extractvalue fat 1 "s_len" builder

let make_slice ptr len =
  let v0 = undef (ltype_of_ast (TypeSlice (TypeU8, 0))) in
  let v1 = build_insertvalue v0 ptr 0 "s0" builder in
  build_insertvalue v1 len 1 "s" builder

(* Effective compile-time minimum length of the slice named [id]:
   the binding's own minimum, upgraded by any active if-condition narrowing
   (narrowing_ctx, Mut bindings only -- Imm bindings are replaced in the
   locals table directly by apply_narrowing). *)
let effective_slice_min id m =
  match Hashtbl.find_opt narrowing_ctx id with
  | Some (TypeSlice (_, m2)) -> max m m2
  | _ -> m

(* -- Expression codegen --------------------------------------------------- *)
(* Returns (ast_type, llvalue).  ast_type is needed for Deref to know
   the element type when emitting a load instruction (LLVM 19 opaque ptrs). *)

let rec gen_expr ?expected_ty locals (e : Ast.expr) : Ast.type_expr * llvalue =
  match e.desc with
  | IntLit i ->
      (* When the caller already knows exactly what type this literal must
         become (a Let's declared/resolved type, a function's return type,
         a call argument's parameter type, a struct/array literal field's
         type, ...), construct the LLVM constant DIRECTLY at that width,
         via ?expected_ty -- rather than always guessing from the value's
         own magnitude and coercing after the fact. This is what makes a
         literal in an already-typed position genuinely polymorphic all
         the way through codegen, not just at the HM type-inference level:
         no i32 (or i64) intermediate representation exists to widen/
         truncate away, not even conceptually -- see CLAUDE.md's "64-bit
         Integer Literals" section for the follow-up this closes (that
         section's own example showed the intermediate i32 stage being
         erased only by LLVM's own constant folding, which is invisible
         and not something to rely on architecturally). *)
      let direct_ty = match expected_ty with
        | Some (TypeIo t) -> Some t  (* io is a storage qualifier; values are never tagged io *)
        | other -> other
      in
      (match direct_ty with
       | Some ((TypeI8|TypeI16|TypeI32|TypeI64
               |TypeU8|TypeU16|TypeU32|TypeU64|TypeIsize|TypeUsize|TypeBool) as ty) ->
           (ty, const_of_int64 (ltype_of_ast ty) i true)
       | _ ->
           (* No usable hint (or an exotic destination -- TypeRefined,
              TypeSlice, a pointer, ... -- already served correctly by the
              guess below): represent the literal at i32 width when it
              fits NON-NEGATIVELY there (0..0x7FFFFFFF), or i64 otherwise
              -- never the FULL signed i32 range. This asymmetry is
              deliberate, not an oversight: with no hint, gen_expr has no
              visibility into what type this bare literal will eventually
              be coerced to (i64/signed vs u64/unsigned), and coerce's
              widening direction (build_sext vs build_zext) depends
              entirely on the DESTINATION type's signedness. An i32
              representation can only be safely widened either way --
              reconstructing the exact same 64-bit value regardless of
              which extension the destination applies -- when bit 31 is
              clear; once bit 31 is set, sign- and zero-extension diverge
              (e.g. 0xFFFFFFFFFFFFFFFF, i.e. Int64 -1, would wrongly
              become 0x00000000FFFFFFFF if zero-extended from a truncated
              i32 -1, instead of staying all-ones). Routing anything with
              bit 31 set through the i64-native path instead sidesteps the
              ambiguity entirely: i64 -> narrower is always a plain,
              sign-agnostic build_trunc (see coerce's and to_i32's
              narrowing branches), so a wide value is always reconstructed
              correctly no matter which narrower type it is eventually
              used as. Never silently truncate to i32 the way an
              unconditional `const_int i32_type i` would for a value
              outside i32's non-negative range -- see CLAUDE.md's "64-bit
              Integer Literals" section for the real, previously-invisible
              bug that was (a plain literal like 5_000_000_000 assigned to
              a u64 local silently became wrong, truncated-then-zero-
              extended, since LLVM's const_int wraps its input to the
              target type's width with no warning). *)
           if i >= 0L && i <= 2147483647L then
             let i32v = Int64.to_int i in
             (TypeRefined (i32v, i32v + 1, TypeI32), const_int (i32_type context) i32v)
           else
             (TypeU64, const_of_int64 (i64_type context) i true))

  | BoolLit b ->
      (TypeBool, const_int (i1_type context) (if b then 1 else 0))

  | ViewLit (name, args) ->
      (TypeView (name, args), erased_view_value ())

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
            | TypeNamed sname when Hashtbl.mem enum_underlying sname ->
                (* Enum variable: load the integer value (unlike struct which returns the pointer) *)
                let ut = Hashtbl.find enum_underlying sname in
                let v  = build_load (ltype_of_ast ut) ptr name builder in
                (ast_ty, v)
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
            | Some (TypeNamed sname as ast_ty, ptr) when Hashtbl.mem enum_underlying sname ->
                let ut = Hashtbl.find enum_underlying sname in
                let v  = build_load (ltype_of_ast ut) ptr name builder in
                (ast_ty, v)
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
                    (TypeFn (param_asts, ret_ast, None), f)
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
             | TypeAlignedPtr (_, TypeNamed s) -> s   (* GitHub issue #102 *)
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
      (* IntLit always emits i32 in codegen, but the type inferencer may have unified it
         with usize (i64).  Widen the narrower side before binary operations so that LLVM
         does not see a type mismatch (e.g. `usize_val == 0` or `usize_val & 15`). *)
      let (ty1, v1, ty2, v2) =
        let ll1 = type_of v1 and ll2 = type_of v2 in
        if ll1 = i64_type context && ll2 = i32_type context then
          let v2w = if is_unsigned ty1 then build_zext v2 (i64_type context) "wi" builder
                    else build_sext v2 (i64_type context) "wi" builder in
          (ty1, v1, ty2, v2w)
        else if ll2 = i64_type context && ll1 = i32_type context then
          let v1w = if is_unsigned ty2 then build_zext v1 (i64_type context) "wi" builder
                    else build_sext v1 (i64_type context) "wi" builder in
          (ty1, v1w, ty2, v2)
        else
          (ty1, v1, ty2, v2)
      in
      (* GitHub issue #102: TypeAlignedPtr is also a pointer at the LLVM
         level (see ltype_of_ast) but carries a proof that may or may not
         survive THIS SPECIFIC addition/subtraction -- mirrors (sync rule)
         type_inf.ml's own Add/Sub cases: either the pointee's own element
         stride is itself a multiple of N (Type_layout's struct_alignments
         -- struct `align(M)` tail-pads sizeof to M, so GEP's per-element
         stride preserves *align(N) T for ANY integer offset when M is a
         multiple of N, `eth_rx_descs + i`'s shape) or the offset itself is
         Type_inf.provable_multiple_of N. *)
      let elem_stride_aligned n inner = match inner with
        | TypeNamed sname ->
            (match Hashtbl.find_opt struct_alignments sname with
             | Some m -> m mod n = 0
             | None -> false)
        | _ -> false
      in
      let ptr_result_ty original_ty offset_expr = match original_ty with
        | TypeAlignedPtr (n, inner) ->
            if elem_stride_aligned n inner then original_ty
            else (match Type_inf.provable_multiple_of offset_expr with
                  | Some k when k mod n = 0 -> original_ty
                  | _ -> TypePtr inner)
        | t -> t
      in
      (match op with
       | Add ->
           (* Pointer arithmetic: ptr + isize -> GEP. *io T = TypePtr(TypeIo T) also matches TypePtr *)
           (match ty1 with
            | TypePtr inner | TypeAlignedPtr (_, inner) ->
                (ptr_result_ty ty1 e2, build_gep (ltype_of_ast inner) v1 [|v2|] "ptradd" builder)
            | _ ->
                (match ty2 with
                 | TypePtr inner | TypeAlignedPtr (_, inner) ->
                     (ptr_result_ty ty2 e1, build_gep (ltype_of_ast inner) v2 [|v1|] "ptradd" builder)
                 | _ ->
                     (* Range propagation (interval arithmetic; sync rule
                        with type_inf.ml's Add case, change together):
                        {a..<b}+{c..<d} -> {a+c..<b+d-1}; {a..<b}+k -> shift *)
                     let sum = build_add v1 v2 "addtmp" builder in
                     let ret_ty = match ty1, ty2 with
                       | TypeRefined (a, b, base), TypeRefined (c, d, _) ->
                           TypeRefined (a + c, b + d - 1, base)
                       | _ ->
                           (match ty1, intlit_opt e2 with
                            | TypeRefined (a, b, base), Some k -> TypeRefined (a + k, b + k, base)
                            | _ -> (match ty2, intlit_opt e1 with
                                    | TypeRefined (c, d, base), Some k -> TypeRefined (c + k, d + k, base)
                                    | _ -> canon_ty ty1))
                     in
                     (ret_ty, sum)))
       | Sub ->
           (* Pointer difference is measured in elements; pointer - isize
              remains element-addressed GEP with a negated index. *)
           (match ty1, ty2 with
            | (TypePtr inner1 | TypeAlignedPtr (_, inner1)), (TypePtr _ | TypeAlignedPtr _) ->
                (TypeIsize, build_ptrdiff (ltype_of_ast inner1) v1 v2 "ptrdiff" builder)
            | (TypePtr inner | TypeAlignedPtr (_, inner)), _ ->
                let neg = build_neg v2 "negtmp" builder in
                (ptr_result_ty ty1 e2, build_gep (ltype_of_ast inner) v1 [|neg|] "ptrsub" builder)
            | _, _ ->
                (* Range propagation (sync rule with type_inf.ml's Sub):
                   {a..<b}-{c..<d} -> {a-d+1..<b-c}; {a..<b}-k -> shift *)
                let diff = build_sub v1 v2 "subtmp" builder in
                let ret_ty = match ty1, ty2 with
                  | TypeRefined (a, b, base), TypeRefined (c, d, _) ->
                      TypeRefined (a - d + 1, b - c, base)
                  | _ ->
                      (match ty1, intlit_opt e2 with
                       | TypeRefined (a, b, base), Some k -> TypeRefined (a - k, b - k, base)
                       | _ -> canon_ty ty1)
                in
                (ret_ty, diff))
       | Mul ->
           (* Range propagation (sync rule with type_inf.ml's Mul):
              {a..<b} * k (a positive literal OR Const_env-resolvable
              named constant) -> {a*k..<(b-1)*k+1} *)
           let k2 = Const_env.bound_value e2 and k1 = Const_env.bound_value e1 in
           let ret_ty = match ty1, k2, ty2, k1 with
             | TypeRefined (a, b, base), Some k, _, _ when k > 0 ->
                 TypeRefined (a * k, (b - 1) * k + 1, base)
             | _, _, TypeRefined (a, b, base), Some k when k > 0 ->
                 TypeRefined (a * k, (b - 1) * k + 1, base)
             | _ -> canon_ty ty1
           in
           (ret_ty, build_mul v1 v2 "multmp" builder)
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
       | Bor  -> (canon_ty ty1, build_or  v1 v2 "bortmp" builder)
       | Bxor -> (canon_ty ty1, build_xor v1 v2 "xortmp" builder)
       | Band ->
           (* Range propagation (sync rule with type_inf.ml's Band case):
              x & k -> {0..<k+1} for a non-negative literal mask k,
              regardless of x's own sign/range. *)
           let ret_ty = match intlit_opt e2 with
             | Some k when k >= 0 -> TypeRefined (0, k + 1, canon_ty ty1)
             | _ -> (match intlit_opt e1 with
                     | Some k when k >= 0 -> TypeRefined (0, k + 1, canon_ty ty1)
                     | _ -> canon_ty ty1)
           in
           (ret_ty, build_and v1 v2 "andtmp" builder)
       | Shr  ->
           let result = if is_unsigned ty1
                        then build_lshr v1 v2 "shrtmp" builder
                        else build_ashr v1 v2 "shrtmp" builder
           in (canon_ty ty1, result)
       | Shl  -> (canon_ty ty1, build_shl v1 v2 "shltmp" builder)
       (* Range propagation: n % m where m is a positive constant and n is guaranteed non-negative.
          Symmetric condition with type_inf.ml: relaxing only one side causes a mismatch. *)
       | Mod  ->
           let result = if is_unsigned ty1
                        then build_urem v1 v2 "modtmp" builder
                        else build_srem v1 v2 "modtmp" builder
           in
           let ret_ty = match intlit_opt e2 with
             | Some m when m > 0 ->
                 (match ty1 with
                  | TypeRefined (lo, _, base) when lo >= 0 -> TypeRefined (0, m, base)
                  | _ when is_unsigned ty1 -> TypeRefined (0, m, ty1)
                  | _ -> canon_ty ty1)
             | _ -> canon_ty ty1
           in
           (ret_ty, result))

  | Bnot e1 ->
      let (ty1, v1) = gen_expr locals e1 in
      (ty1, build_not v1 "bnottmp" builder)

  | EnumVariant (ename, vname) ->
      (match Hashtbl.find_opt enum_underlying ename with
       | Some ut ->
           let variants = Hashtbl.find enum_variants_tbl ename in
           let value = match List.assoc_opt vname variants with
             | Some v -> v
             | None -> raise (Error (Printf.sprintf
                 "Unknown enum variant %s::%s" ename vname))
           in
           (TypeNamed ename, const_int (ltype_of_ast ut) value)
       | None ->
           let layout = variant_case ename vname in
           (match layout.variant_payload with
            | Some _ -> raise (Error (Printf.sprintf
                "BUG: payload variant %s::%s reached nullary constructor codegen"
                ename vname))
            | None -> ());
           let llty = ltype_of_ast (TypeVariant ename) in
           let value = build_insertvalue (undef llty)
             (const_int (i32_type context) layout.variant_tag) 0
             "variant.tag" builder in
           (TypeVariant ename, value))

  | VariantCtor (vtype, vname, payload) ->
      let layout = variant_case vtype vname in
      let schema = match layout.variant_payload with
        | Some schema -> schema
        | None -> raise (Error (Printf.sprintf
            "BUG: nullary variant %s::%s reached payload constructor codegen"
            vtype vname))
      in
      let payload_ty = runtime_payload_type schema in
      let (_, payload_v) = gen_expr ~expected_ty:payload_ty locals payload in
      let llty = ltype_of_ast (TypeVariant vtype) in
      let value = build_insertvalue (undef llty)
        (const_int (i32_type context) layout.variant_tag) 0
        "variant.tag" builder in
      let value = match layout.variant_payload_field with
        | None -> value
        | Some field ->
            build_insertvalue value (coerce payload_v payload_ty) field
              "variant.payload" builder
      in
      (TypeVariant vtype, value)

  | SizeOf ty ->
      let elem_llty = ltype_of_ast ty in
      let dl = match !target_data with
        | Some dl -> dl
        | None -> raise (Error "sizeof: target data layout not initialized")
      in
      let sz = Int64.to_int (Llvm_target.DataLayout.abi_size elem_llty dl) in
      (* GitHub issue #77: same restricted refined-type treatment as
         type_inf.ml's SizeOf case (sync rule) -- see const_type_size's
         comment. The disagreement check below is a genuine soundness
         guard, not defensive boilerplate: if it ever fires, the
         OCaml-arithmetic formula and the real DataLayout have diverged,
         which would otherwise mean SliceOf could prove a bound using a
         value narrower than what actually gets emitted. *)
      let result_ty = match const_type_size ty with
        | Some v when v <> sz ->
            raise (Error (Printf.sprintf
              "BUG: sizeof(%s) OCaml-computed value %d disagrees with DataLayout value %d"
              (Ast.show_type_expr ty) v sz))
        | Some v -> TypeRefined (v, v + 1, TypeUsize)
        | None -> TypeUsize
      in
      (result_ty, const_int (ltype_of_ast TypeUsize) sz)

  | OffsetOf (ty, field) ->
      let (name, llty) = match ty with
        | TypeNamed name -> (name, ltype_of_ast ty)
        | _ -> raise (Error "offsetof requires a named struct type")
      in
      let (field_index, _) = field_info name field in
      let dl = match !target_data with
        | Some dl -> dl
        | None -> raise (Error "offsetof: target data layout not initialized")
      in
      let offset = Llvm_target.DataLayout.offset_of_element llty field_index dl in
      (* GitHub issue #77: same restricted refined-type treatment as
         type_inf.ml's OffsetOf case (sync rule) -- see const_field_offset's
         comment and SizeOf's disagreement-check comment just above. *)
      let offset_int = Int64.to_int offset in
      let result_ty = match const_field_offset name field with
        | Some v when v <> offset_int ->
            raise (Error (Printf.sprintf
              "BUG: offsetof(%s, %s) OCaml-computed value %d disagrees with DataLayout value %d"
              name field v offset_int))
        | Some v -> TypeRefined (v, v + 1, TypeUsize)
        | None -> TypeUsize
      in
      (result_ty, const_of_int64 (ltype_of_ast TypeUsize) offset false)

  | Cast (target_ty, src_e) ->
      let (src_ty_raw, v) = gen_expr locals src_e in
      (* Consult narrowing_ctx when the source is a bare Var, same pattern
         as Index/AssignIndex/SliceOf: an if-narrowed Mut variable's proven
         range must be visible here too, since `v as {lo..<hi as usize}` is
         now the standard idiom for carrying a narrowed range across a base
         change (e.g. into a usize-typed array index -- see
         require_usize_index in type_inf.ml). Without this, a narrowed i32
         cast to a usize-based refined type would look unproven here even
         though type_inf.ml (which threads the narrowed tyenv through
         infer_expr) already proved it, silently reopening a runtime check
         that used to be elided -- a correctness gap for the runtime CHECK
         COUNT (not soundness: the check is merely redundant, never wrong). *)
      let src_ty = match src_e.desc with
        | Var n -> (match Hashtbl.find_opt narrowing_ctx n with
                    | Some t -> t | None -> src_ty_raw)
        | _ -> src_ty_raw
      in
      (* GitHub issue #72: a BARE cast target (`x as usize`, not the
         explicit `x as {lo..<hi as usize}` form) is upgraded to the exact
         TypeRefined target type_inf.ml's Cast case now also infers,
         whenever src_ty is already refined and its range fits the target
         base's native representable range -- this is what lets the
         TypeRefined branch below elide the runtime check exactly as it
         already does for an explicitly-written `{lo..<hi as base}` cast,
         with no other change needed anywhere in this function. The
         fits-check below must stay in sync with types.ml's unify
         TRefinedInt-subtyping arms (same independently-computed-twice
         discipline this project already uses for sizeof/offsetof -- see
         llvm_gen.ml's const_type_size/const_field_offset comment). *)
      let target_ty =
        match target_ty, src_ty with
        | (TypeI8|TypeI16|TypeI32|TypeI64|TypeU8|TypeU16|TypeU32|TypeU64
          |TypeIsize|TypeUsize),
          TypeRefined (lo, hi, _) ->
            let fits = match target_ty with
              | TypeI32 | TypeI64 | TypeIsize      -> true
              | TypeU8                             -> lo >= 0 && hi <= 256
              | TypeU16                             -> lo >= 0 && hi <= 65536
              | TypeU32 | TypeU64 | TypeUsize       -> lo >= 0
              | TypeI8                              -> lo >= -128   && hi <= 128
              | TypeI16                             -> lo >= -32768 && hi <= 32768
              | _                                   -> false
            in
            if fits then TypeRefined (lo, hi, target_ty) else target_ty
        | _ -> target_ty
      in
      (match target_ty with
       | TypeNamed ename when Hashtbl.mem enum_underlying ename ->
           let ut    = Hashtbl.find enum_underlying ename in
           let is_ne = Hashtbl.find enum_nonexhaustive ename in
           let v_coerced = coerce v ut in
           let variants_proven () =
             (* A refined source whose entire range consists of variant
                values proves the cast statically -- no switch, no trap.
                E.g. `i as Color` where i: {0..<3} and Color = {0,1,2}
                (examples/enum/enum.tkb's for-loop cast). An empty range
                (lo >= hi) is vacuously proven: the value cannot exist. *)
             let variants = Hashtbl.find enum_variants_tbl ename in
             match src_ty with
             | TypeRefined (a, b, _) ->
                 let rec all_in v =
                   v >= b
                   || (List.exists (fun (_, dv) -> dv = v) variants
                       && all_in (v + 1))
                 in
                 all_in a
             | _ -> false
           in
           if is_ne then
             (* non-exhaustive enum: any integer is valid; round-trip is guaranteed *)
             (TypeNamed ename, v_coerced)
           else if variants_proven () then
             (TypeNamed ename, v_coerced)
           else begin
             (* exhaustive enum: trap on unknown value at runtime *)
             record_trap e.loc (Printf.sprintf
               "enum check remains: %s as %s (exhaustive) needs a runtime variant check"
               (ty_str src_ty) ename);
             let variants = Hashtbl.find enum_variants_tbl ename in
             let cur_f    = block_parent (insertion_block builder) in
             let ok_bb    = append_block context "enum_ok"  cur_f in
             let bad_bb   = append_block context "enum_bad" cur_f in
             let ll_ut    = ltype_of_ast ut in
             let sw = build_switch v_coerced bad_bb (List.length variants) builder in
             List.iter (fun (_, value) ->
               add_case sw (const_int ll_ut value) ok_bb
             ) variants;
             position_at_end bad_bb builder;
             let trap_ft = function_type (void_type context) [||] in
             let trap_fn = declare_function "llvm.trap" trap_ft the_module in
             ignore (build_call trap_ft trap_fn [||] "" builder);
             ignore (build_unreachable builder);
             position_at_end ok_bb builder;
             (TypeNamed ename, v_coerced)
           end
       | TypeRefined (lo, hi, _) ->
           (* Checked refined cast. When the source's static range already
              proves the target range, this is a plain subtype coercion and
              no check is emitted (so it stays legal under --forbid-trap).
              Everything else gets a runtime range check + trap -- previously
              this cast was silently unchecked, which let
              `arr[v as {0..<N}]` elide the bounds check for an arbitrary
              i32 v: an unsound OOB access with no trap at all. This range
              check is base-agnostic by design (matches types.ml's
              subtyping rule): a proven fit is about the VALUE range, not
              whether src's base happens to match the cast target's base,
              selected by `{lo..<hi as base}`. *)
           let proven = match src_ty with
             | TypeRefined (a, b, _) -> lo <= a && b <= hi
             | TypeBool -> lo <= 0 && 2 <= hi           (* i1 zext: {0..<2} *)
             | TypeU8   -> lo <= 0 && 0x100   <= hi     (* zext-widened     *)
             | TypeU16  -> lo <= 0 && 0x10000 <= hi
             | _ -> false
           in
           if not proven then emit_refined_cast_check e.loc src_ty v lo hi;
           (target_ty, to_arith_width target_ty (coerce v target_ty))
       | TypeSlice (el, _) ->
           (* Slice creation cast. type_inf already proved the minimum-length
              requirement; here we only build the fat value. *)
           (match src_ty with
            | TypeSlice (_, m) ->
                (* slice -> slice: min-length relaxation is a no-op on the value *)
                (TypeSlice (el, m), v)
            | _ ->
                (* array variable -> slice: gen_expr already decayed the value
                   to an elem-0 pointer (exactly the ptr half we need); the
                   static length comes from the declared binding, which the
                   decayed TYPE no longer carries. *)
                (match src_e.desc with
                 | Var name ->
                     let arr_len = match Hashtbl.find_opt locals name with
                       | Some (Mut (TypeArray (_, n), _)) -> Some n
                       | _ ->
                           (match Hashtbl.find_opt global_vars name with
                            | Some (TypeArray (_, n), _) -> Some n
                            | _ -> None)
                     in
                     (match arr_len with
                      | Some n ->
                          (TypeSlice (el, n),
                           make_slice v (const_int (usize_lltype ()) n))
                      | None -> raise (Error
                          "slice cast source must be an array variable, string \
                           literal, or slice"))
                 | StringLit str ->
                     (* v is the literal's global pointer; the compile-time
                        byte length (NUL excluded) becomes the minimum. *)
                     let n = String.length str in
                     (TypeSlice (el, n),
                      make_slice v (const_int (usize_lltype ()) n))
                 | _ -> raise (Error
                     "slice cast source must be an array variable, string \
                      literal, or slice")))
       | TypePtr _ when (match src_ty with TypeSlice _ -> true | _ -> false) ->
           (* slice -> pointer: the explicit bridge back into the pointer
              world; just the ptr half of the fat value. *)
           (target_ty, slice_ptr v)
       | _ ->
           (* Every other u8/i16/etc-typed expression result (Var, Index,
              FieldGet, Deref) is represented in-flight as an i32-widened
              value per widen_load's invariant ("arithmetic values arrive
              at coerce already widened"); coerce narrows only at the
              point of storage. `as` must match that invariant too: coerce
              to the true narrow width first (so truncation semantics are
              correct, e.g. `300 as u8` really wraps to 44), then widen
              back so the returned value composes correctly with other
              expressions (e.g. `idx_expr == literal_expr as u8`, where
              idx_expr is an i32-widened Index read of a u8 array/pointer
              -- returning a bare narrow i8 here would make the two sides
              of `==` disagree in LLVM type despite matching AST types). *)
           (target_ty, to_arith_width target_ty (coerce v target_ty)))

  | FieldGet (base_expr, fname) ->
      let (base_ty, base_v) = gen_expr locals base_expr in
      (match base_ty, fname with
       | TypeSlice _, "len" ->
           (TypeUsize, slice_len base_v)
       | TypeIndexed (sname, _), _ ->
           let (idx, field_ty) = field_info sname fname in
           let v = build_extractvalue base_v idx fname builder in
           let value_ty = erase_singleton_type field_ty in
           (value_ty, to_arith_width value_ty v)
       | _ ->
      let (sname, through_io) = match base_ty with
        | TypeNamed s                      -> (s, false)
        | TypePtr   (TypeNamed s)          -> (s, false)
        | TypePtr   (TypeIo (TypeNamed s)) -> (s, true)   (* field access through *io Struct is volatile *)
        | TypeAlignedPtr (_, TypeNamed s)  -> (s, false)  (* GitHub issue #102 *)
        | _ -> raise (Error (Printf.sprintf
            "field access '.%s' on non-struct type" fname))
      in
      let (idx, field_ty) = field_info sname fname in
      let llty = Hashtbl.find struct_lltypes sname in
      if type_of base_v = llty then begin
        let value_ty = resolve_special_type field_ty in
        let v = build_extractvalue base_v idx fname builder in
        (value_ty, to_arith_width value_ty v)
      end else begin
        let field_ptr = build_in_bounds_gep llty base_v
          [| const_int (i32_type context) 0; const_int (i32_type context) idx |]
          (fname ^ "_ptr") builder
        in
        (match field_ty with
       | TypeNamed name when Hashtbl.mem variant_defs name ->
           let v = build_load (ltype_of_ast field_ty) field_ptr fname builder in
           if through_io then set_volatile true v;
           (TypeVariant name, v)
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
      end)

  | Index (id, idx) ->
      let (idx_ty_raw, idx_raw) = gen_expr locals idx in
      let idx_v = to_index_width ~is_signed:(not (is_unsigned idx_ty_raw)) idx_raw in
      (* idx_ty priority: Const_env constant name (e.g. tcp[TCP_FLAGS] --
         sound because check_const_shadowing forbids shadowing, so the value
         is exactly the recorded literal) > Mut narrowing from narrowing_ctx
         (if-condition) > the raw inferred type. *)
      let idx_ty = match Const_env.bound_value idx with
        | Some k -> TypeRefined (k, k + 1, TypeUsize)  (* idx_v is already forced to usize width via to_index_width above *)
        | None ->
            (match idx.desc with
             | Var n -> (match Hashtbl.find_opt narrowing_ctx n with
                         | Some t -> t | None -> idx_ty_raw)
             | _ -> idx_ty_raw)
      in
      (* Array load [T; N]: skip bounds check when TypeRefined proves safety *)
      let load_from_array elem_ty n arr_ptr =
        let needs_check = match refinement_range idx_ty with
          | Some (lo, hi) -> lo < 0 || hi > n
          | _ -> true
        in
        if needs_check then emit_bounds_check e.loc idx_ty idx_v n;
        let arr_ll = array_type (ltype_of_ast elem_ty) n in
        let zero   = const_int (i32_type context) 0 in
        let ep = build_in_bounds_gep arr_ll arr_ptr [|zero; idx_v|] "idx_ptr" builder in
        match elem_ty with
        | TypeNamed _ -> (elem_ty, ep)
        | _ ->
            let v = build_load (ltype_of_ast elem_ty) ep "idx_val" builder in
            (elem_ty, to_arith_width elem_ty v)
      in
      let load_through_ptr elem_ty ptr_v is_volatile =
        let ep = build_gep (ltype_of_ast elem_ty) ptr_v [|idx_v|] "idx_ptr" builder in
        match elem_ty with
        | TypeNamed _ when is_volatile -> (TypePtr (TypeIo elem_ty), ep)
        | TypeNamed _ -> (elem_ty, ep)
        | _ ->
            let v = build_load (ltype_of_ast elem_ty) ep "idx_val" builder in
            if is_volatile then set_volatile true v;
            (elem_ty, to_arith_width elem_ty v)
      in
      (* Slice load: elide the check only when idx's range fits the slice's
         compile-time MINIMUM length (a lower bound of the runtime length,
         so hi <= min implies hi <= len). Otherwise check against the
         runtime length. *)
      let load_from_slice elem_ty min_len fat =
        let proven = match refinement_range idx_ty with
          | Some (lo, hi) -> lo >= 0 && hi <= min_len
          | _ -> false
        in
        if not proven then
          emit_bounds_check_dyn e.loc idx_ty idx_v min_len (slice_len fat);
        let ep = build_gep (ltype_of_ast elem_ty) (slice_ptr fat) [|idx_v|] "idx_ptr" builder in
        let v  = build_load (ltype_of_ast elem_ty) ep "idx_val" builder in
        (elem_ty, to_arith_width elem_ty v)
      in
      (match Hashtbl.find_opt locals id with
       | Some (Mut (TypeArray (elem_ty, n), ptr)) ->
           load_from_array elem_ty n ptr
       | Some (Mut (TypeSlice (elem_ty, m), alloca_ptr)) ->
           let fat = build_load (ltype_of_ast (TypeSlice (elem_ty, m))) alloca_ptr id builder in
           load_from_slice elem_ty (effective_slice_min id m) fat
       | Some (Imm (TypeSlice (elem_ty, m), fat)) ->
           load_from_slice elem_ty m fat
       | Some (Mut (TypePtr (TypeIo elem_ty), alloca_ptr))
       | Some (Mut (TypeAlignedPtr (_, TypeIo elem_ty), alloca_ptr)) ->
           (* *io T variable: load pointer value from alloca, then volatile access *)
           let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
           load_through_ptr elem_ty ptr_v true
       | Some (Mut (TypePtr elem_ty, alloca_ptr))
       | Some (Mut (TypeAlignedPtr (_, elem_ty), alloca_ptr)) ->
           let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
           load_through_ptr elem_ty ptr_v false
       | Some (Imm (TypePtr (TypeIo elem_ty), ptr_v))
       | Some (Imm (TypeAlignedPtr (_, TypeIo elem_ty), ptr_v)) ->
           load_through_ptr elem_ty ptr_v true
       | Some (Imm (TypePtr elem_ty, ptr_v))
       | Some (Imm (TypeAlignedPtr (_, elem_ty), ptr_v)) ->
           load_through_ptr elem_ty ptr_v false
       | Some _ ->
           raise (Error (Printf.sprintf "Index: '%s' is not an array or pointer" id))
       | None ->
           (match Hashtbl.find_opt global_vars id with
            | Some (TypeArray (elem_ty, n), gptr) ->
                load_from_array elem_ty n gptr
            | Some (TypeSlice (elem_ty, m), gptr) ->
                let fat = build_load (ltype_of_ast (TypeSlice (elem_ty, m))) gptr id builder in
                load_from_slice elem_ty (effective_slice_min id m) fat
            | Some (TypePtr (TypeIo elem_ty), gptr)
            | Some (TypeAlignedPtr (_, TypeIo elem_ty), gptr) ->
                let ptr_v = build_load (pointer_type context) gptr id builder in
                load_through_ptr elem_ty ptr_v true
            | Some (TypePtr elem_ty, gptr)
            | Some (TypeAlignedPtr (_, elem_ty), gptr) ->
                let ptr_v = build_load (pointer_type context) gptr id builder in
                load_through_ptr elem_ty ptr_v false
            | Some _ ->
                raise (Error (Printf.sprintf "Index: '%s' is not an array or pointer" id))
            | None ->
                raise (Error (Printf.sprintf "Index: undefined variable '%s'" id))))

  | SliceOf (id, lo_e, hi_e) ->
      (* Sync rule: the proven/checked decision below uses the same
         bound-range formula as type_inf.ml's SliceOf case (constant via
         Const_env.bound_value, else the bound expression's refined range,
         with narrowing_ctx consulted for Mut variables) -- change the two
         together. Codegen re-verifies rather than trusting type_inf
         blindly: an array subslice that fails the proof here is a BUG
         error, not silent emission. *)
      let gen_bound be =
        let (bty_raw, bv) = gen_expr locals be in
        let bty = match be.desc with
          | Var n -> (match Hashtbl.find_opt narrowing_ctx n with
                      | Some t -> t | None -> bty_raw)
          | _ -> bty_raw
        in
        let range = match Const_env.bound_value be with
          | Some k -> Some (k, k + 1)
          | None -> refinement_range bty
        in
        (to_index_width ~is_signed:(not (is_unsigned bty_raw)) bv, range)
      in
      (* Same-base rule: s[v ..< v + w] has lo <= hi and a guaranteed
         length >= lower(w), for ANY w with a known non-negative lower
         bound (a literal, or another refined variable e.g. from a
         min()-clamp) -- sync rule with type_inf's SliceOf, which must
         decompose hi_e identically. io-qualified v is excluded: two
         volatile loads could disagree between the bounds. *)
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
                 let is_io = function TypeIo _ -> true | _ -> false in
                 let base_is_io =
                   match Hashtbl.find_opt locals v1 with
                   | Some (Imm (t, _)) | Some (Mut (t, _)) -> is_io t
                   | None ->
                       (match Hashtbl.find_opt global_vars v1 with
                        | Some (t, _) -> is_io t
                        | None -> false)
                 in
                 if base_is_io then None
                 else
                   (* w is looked up WITHOUT calling gen_expr/gen_bound on
                      it a second time (it will be evaluated once, as part
                      of hi_e itself, below) -- a direct table lookup only,
                      restricted to a bare literal or a bare variable (sync
                      rule with type_inf.ml's identical restriction; see
                      its comment for why re-evaluating an arbitrary
                      expression here would risk duplicating side
                      effects). *)
                   (match w.desc with
                    | IntLit _ ->
                        (match intlit_opt w with
                         | Some k when k >= 0 -> Some k
                         | _ -> None)
                    | Var w_name ->
                        let wty = match Hashtbl.find_opt narrowing_ctx w_name with
                          | Some t -> Some t
                          | None ->
                              (match Hashtbl.find_opt locals w_name with
                               | Some (Imm (t, _)) | Some (Mut (t, _)) -> Some t
                               | None ->
                                   (match Hashtbl.find_opt global_vars w_name with
                                    | Some (t, _) -> Some t
                                    | None -> None))
                        in
                        (match wty with
                         | Some (TypeRefined (wlo, _, _)) when wlo >= 0 -> Some wlo
                         | _ -> None)
                    | _ -> None))
        | _ -> None
      in
      let ranges_proven lo_r hi_r limit =
        match lo_r, hi_r with
        | Some (la, lb), Some (ha, hb) ->
            la >= 0 && (lb - 1 <= ha || same_base_len <> None)
            && hb - 1 <= limit
        | _ -> false
      in
      let guaranteed_min lo_r hi_r =
        match same_base_len with
        | Some l -> l  (* exact length, proven or once the check has passed *)
        | None ->
            (match lo_r, hi_r with
             | Some (_, lb), Some (ha, _) when ha - (lb - 1) > 0 -> ha - (lb - 1)
             | _ -> 0)
      in
      let finish_sub elem_ty base_ptr lo_v hi_v min_len =
        let ep = build_gep (ltype_of_ast elem_ty) base_ptr [| lo_v |] "sub_ptr" builder in
        let len = build_sub hi_v lo_v "sub_len" builder in
        (TypeSlice (elem_ty, min_len), make_slice ep len)
      in
      let sub_of_slice elem_ty min_len fat =
        let (lo_v, lo_r) = gen_bound lo_e in
        let (hi_v, hi_r) = gen_bound hi_e in
        if not (ranges_proven lo_r hi_r min_len) then begin
          if !unsafe_depth > 0 then
            (* P4c-1: unsafe skips the check entirely -- an explicit,
               visible "trust me" (same semantics as the pointer-base
               case) for a bound the current interval/same-base tools
               cannot close (e.g. two independently-clamped variables
               whose combination is actually bounded by a relation the
               type system doesn't track -- see CLAUDE.md's P4c section).
               No trap site recorded: this is a deliberate assertion, not
               a residual gap --forbid-trap should report. *)
            ()
          else begin
            (* Runtime-checked subslice (gradual form): one check, one
               recorded trap site, and everything downstream of the
               resulting view is bounds-governed again. *)
            record_trap e.loc (Printf.sprintf
              "subslice bounds check remains: bounds cannot prove range \
               {0..<%d} (the slice's compile-time minimum length)" min_len);
            let inv  = build_icmp Icmp.Ugt lo_v hi_v "ss_inv" builder in
            let over = build_icmp Icmp.Ugt hi_v (slice_len fat) "ss_over" builder in
            let bad  = build_or inv over "ss_bad" builder in
            emit_trap_when bad ~bad_name:"ss_trap" ~ok_name:"ss_ok"
          end
        end;
        finish_sub elem_ty (slice_ptr fat) lo_v hi_v (guaranteed_min lo_r hi_r)
      in
      let sub_of_array elem_ty n arr_ptr =
        let (lo_v, lo_r) = gen_bound lo_e in
        let (hi_v, hi_r) = gen_bound hi_e in
        if not (ranges_proven lo_r hi_r n) then begin
          let show_range = function
            | Some (a, b) -> Printf.sprintf "{%d..<%d}" a b
            | None -> "unknown"
          in
          raise (Error (Printf.sprintf
            "BUG: subslice bounds %s..<%s not proven against array size %d \
             (type_inf should have rejected this)"
            (show_range lo_r) (show_range hi_r) n))
        end;
        let arr_ll = array_type (ltype_of_ast elem_ty) n in
        let zero = const_int (i32_type context) 0 in
        let ep = build_in_bounds_gep arr_ll arr_ptr [| zero; lo_v |] "sub_ptr" builder in
        let len = build_sub hi_v lo_v "sub_len" builder in
        (TypeSlice (elem_ty, guaranteed_min lo_r hi_r), make_slice ep len)
      in
      let sub_of_ptr elem_ty base_ptr =
        (* Slice construction from a raw pointer: UNCHECKED by design (the
           unsafe-gated escape hatch, used once at a driver boundary). The
           claimed minimum is whatever the bounds' static ranges guarantee
           (sync rule: same formula as type_inf's TPtr branch). *)
        let (lo_v, lo_r) = gen_bound lo_e in
        let (hi_v, hi_r) = gen_bound hi_e in
        let min_len = match lo_r, hi_r with
          | Some (la, lb), Some (ha, _) when la >= 0 && lb - 1 <= ha ->
              ha - (lb - 1)
          | _ -> 0
        in
        finish_sub elem_ty base_ptr lo_v hi_v min_len
      in
      (match Hashtbl.find_opt locals id with
       | Some (Mut (TypeSlice (el, m), alloca_ptr)) ->
           let fat = build_load (ltype_of_ast (TypeSlice (el, m))) alloca_ptr id builder in
           sub_of_slice el (effective_slice_min id m) fat
       | Some (Imm (TypeSlice (el, m), fat)) ->
           sub_of_slice el m fat
       | Some (Mut (TypeArray (el, n), ptr)) ->
           sub_of_array el n ptr
       | Some (Mut (TypePtr el, alloca_ptr)) ->
           let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
           sub_of_ptr el ptr_v
       | Some (Imm (TypePtr el, ptr_v)) ->
           sub_of_ptr el ptr_v
       | Some _ ->
           raise (Error (Printf.sprintf "SliceOf: '%s' is not a slice/array/pointer" id))
       | None ->
           (match Hashtbl.find_opt global_vars id with
            | Some (TypeSlice (el, m), gptr) ->
                let fat = build_load (ltype_of_ast (TypeSlice (el, m))) gptr id builder in
                sub_of_slice el (effective_slice_min id m) fat
            | Some (TypeArray (el, n), gptr) ->
                sub_of_array el n gptr
            | Some (TypePtr el, gptr) ->
                let ptr_v = build_load (pointer_type context) gptr id builder in
                sub_of_ptr el ptr_v
            | Some _ ->
                raise (Error (Printf.sprintf "SliceOf: '%s' is not a slice/array/pointer" id))
            | None ->
                raise (Error (Printf.sprintf "SliceOf: undefined variable '%s'" id))))

  | Unsafe e1 ->
      (* Mostly a type-checker gate (see Ast.Unsafe): for the pointer->slice
         case this is fully transparent to codegen. For a SLICE/ARRAY-base
         subslice whose bounds aren't statically provable (P4c-1), codegen
         DOES look at unsafe_depth (below): inside unsafe, the runtime
         check that would otherwise be emitted is skipped entirely, an
         explicit "trust me" mirroring the pointer case's own semantics
         (an unchecked length assertion), rather than requiring a genuine
         relational domain to discharge a small number of cases like
         tcp_echo's data-echo path or tcp_parse's checksum span (see
         CLAUDE.md's P4c section for why those are correlated-bounds cases
         plain intervals can't close). *)
      incr unsafe_depth;
      let r = gen_expr locals e1 in
      decr unsafe_depth;
      r

  | StructLit _ ->
      raise (Error "BUG: StructLit must be handled in gen_stmt / gen_global, not gen_expr")

  | TupleLit exprs ->
      (* OWNERSHIP_KERNEL.md 5.9 (GitHub issue #120): build the anonymous
         aggregate via insertvalue. When the consumer's tuple type is known
         (let/return/call argument), thread per-component expected types so
         literal components land at the right width. *)
      let expected_comps = match expected_ty with
        | Some (TypeTuple ts) when List.length ts = List.length exprs ->
            List.map (fun t -> Some t) ts
        | _ -> List.map (fun _ -> None) exprs
      in
      let comps = List.map2 (fun x hint ->
        match hint with
        | Some t ->
            let (_, v) = gen_expr ~expected_ty:t locals x in
            (t, coerce v t)
        | None -> gen_expr locals x
      ) exprs expected_comps in
      let comp_tys = List.map fst comps in
      let tuple_ty = TypeTuple comp_tys in
      let agg_llty = ltype_of_ast tuple_ty in
      let (agg, _) = List.fold_left (fun (agg, i) (_, cv) ->
        (build_insertvalue agg cv i "tup" builder, i + 1)
      ) (undef agg_llty, 0) comps in
      (tuple_ty, agg)

  | Call ("dma_publish", []) ->
      emit_device_barrier DmaPublish;
      (TypeVoid, const_null (i1_type context))

  | Call ("dma_consume", []) ->
      emit_device_barrier DmaConsume;
      (TypeVoid, const_null (i1_type context))

  | Call ("device_fence", []) ->
      emit_device_barrier DeviceFence;
      (TypeVoid, const_null (i1_type context))

  | Call ("signal_fence", []) ->
      let fty = function_type (void_type context) [||] in
      let inline = const_inline_asm fty "" "~{memory}" true false in
      ignore (build_call fty inline [||] "" builder);
      (TypeVoid, const_null (i1_type context))

  | Call ("interrupt_wait", []) ->
      emit_interrupt_event false;
      (TypeVoid, const_null (i1_type context))

  | Call ("interrupt_notify", []) ->
      emit_interrupt_event true;
      (TypeVoid, const_null (i1_type context))

  | Call ("stable_replace",
          [guard_e; lock_e; { desc = FieldGet (base_e, fname); _ };
           replacement_e]) ->
      (* The erased guard has no ABI value. The lock address is evaluated for
         ordinary left-to-right source semantics; the checker uses its static
         place identity and guarantees it belongs to the stable container. *)
      ignore (gen_expr locals guard_e);
      ignore (gen_expr locals lock_e);
      let (base_ty, base_v) = gen_expr locals base_e in
      let sname = match base_ty with
        | TypeNamed name | TypePtr (TypeNamed name)
        | TypePtr (TypeIo (TypeNamed name))
        | TypeAlignedPtr (_, TypeNamed name) -> name
        | _ -> raise (Error
            "BUG: stable_replace base is not a struct place")
      in
      let (idx, field_ty) = field_info sname fname in
      let llty = Hashtbl.find struct_lltypes sname in
      if type_of base_v = llty then
        raise (Error "BUG: stable_replace base has no stable address");
      let field_ptr = build_in_bounds_gep llty base_v
        [| const_int (i32_type context) 0; const_int (i32_type context) idx |]
        (fname ^ ".stable_ptr") builder in
      let value_ty = resolve_special_type field_ty in
      let (_, replacement_v) =
        gen_expr ~expected_ty:value_ty locals replacement_e in
      (* Argument side effects complete before the exchange observes the
         slot, matching ordinary left-to-right call evaluation. *)
      let old_value = build_load (ltype_of_ast value_ty) field_ptr
        (fname ^ ".stable_old") builder in
      ignore (build_store (coerce replacement_v value_ty) field_ptr builder);
      (value_ty, old_value)

  | Call (("dma_prepare_tx" | "dma_prepare_rx" | "dma_finish_rx") as name,
          [ptr_e; len_e]) ->
      let (_, ptr) = gen_expr locals ptr_e in
      let (_, len) = gen_expr ~expected_ty:TypeUsize locals len_e in
      let triple = target_triple the_module in
      if starts_with triple "arm" || starts_with triple "thumb" then begin
        (match name with
         | "dma_prepare_tx" ->
             emit_cortex_m_cache_range CacheClean ptr len;
             emit_device_barrier DmaPublish
         | "dma_prepare_rx" ->
             emit_cortex_m_cache_range CacheInvalidate ptr len;
             emit_device_barrier DmaPublish
         | _ ->
             emit_device_barrier DmaConsume;
             emit_cortex_m_cache_range CacheInvalidate ptr len;
             emit_device_barrier DmaConsume)
      end else if starts_with triple "aarch64" then begin
        (match name with
         | "dma_prepare_tx" ->
             emit_aarch64_cache_range CacheClean ptr len;
             emit_device_barrier DmaPublish
         | "dma_prepare_rx" ->
             emit_aarch64_cache_range CacheInvalidate ptr len;
             emit_device_barrier DmaPublish
         | _ ->
             emit_device_barrier DmaConsume;
             emit_aarch64_cache_range CacheInvalidate ptr len;
             emit_device_barrier DmaConsume)
      end else if starts_with triple "x86_64" || starts_with triple "i386"
           || starts_with triple "i486" || starts_with triple "i586"
           || starts_with triple "i686" then
        (* Verified no-op, NOT a placeholder (see issue #146, unlike the
           AArch64 gap that issue found): PC-class DMA is cache-coherent by
           chipset/IOMMU snooping in essentially every real x86 deployment,
           so a bare fence is the correct lowering here -- there is no
           missing cache instruction to add. *)
        emit_device_barrier (match name with
          | "dma_prepare_tx" | "dma_prepare_rx" -> DmaPublish
          | _ -> DmaConsume)
      else
        (* Deliberately narrower than emit_device_barrier's own fallback:
           a bare barrier here would silently reproduce the exact
           stale-cache-line hazard issue #146 found on AArch64/RPi3, on
           whatever target hits this next. RISC-V in particular needs the
           Zicbom extension's cbo.clean/cbo.flush/cbo.inval to implement
           this for real; that lowering is intentionally NOT written yet
           because no RISC-V target/toolchain exists anywhere in this
           project to verify it against (this codebase's own convention is
           to prove code against a real target before shipping it, not
           ship unverified speculative lowering) -- add it, with real
           testing, once an actual RISC-V target exists here. *)
        raise (Error (Printf.sprintf
          "dma_prepare_tx/dma_prepare_rx/dma_finish_rx need real cache \
           maintenance on target '%s' and no implementation exists for it \
           yet (see issue #146)" triple));
      (TypeVoid, const_null (i1_type context))

  | Call ("slice_copy", [d_e; s_e]) ->
      (* Builtin (see type_inf.ml's Call case for the full semantics
         contract): copy min(dst.len, src.len) elements forward, return the
         count as usize. The loop is built with a phi, NOT an alloca, so a
         slice_copy inside a while loop does not grow the stack per
         iteration. An explicit loop rather than llvm.memcpy: with a
         dynamic length the intrinsic lowers to a memcpy libcall, a link
         error on bare-metal (same reason run_optimizations excludes the
         loop-idiom pass). *)
      let (dt, dv) = gen_expr locals d_e in
      let (_,  sv) = gen_expr locals s_e in
      let elem_ty = match dt with
        | TypeSlice (el, _) -> el
        | _ -> raise (Error "BUG: slice_copy on non-slice (type_inf should reject)")
      in
      let usz  = usize_lltype () in
      let dptr = slice_ptr dv and dlen = slice_len dv in
      let sptr = slice_ptr sv and slen = slice_len sv in
      let lt = build_icmp Icmp.Ult dlen slen "sc_lt" builder in
      let n  = build_select lt dlen slen "sc_n" builder in
      let cur_f   = block_parent (insertion_block builder) in
      let pre_bb  = insertion_block builder in
      let cond_bb = append_block context "sc_cond" cur_f in
      let body_bb = append_block context "sc_body" cur_f in
      let exit_bb = append_block context "sc_exit" cur_f in
      ignore (build_br cond_bb builder);
      position_at_end cond_bb builder;
      let i_phi = build_phi [ (const_int usz 0, pre_bb) ] "sc_i" builder in
      let cmp = build_icmp Icmp.Ult i_phi n "sc_cmp" builder in
      ignore (build_cond_br cmp body_bb exit_bb builder);
      position_at_end body_bb builder;
      let sp = build_gep (ltype_of_ast elem_ty) sptr [| i_phi |] "sc_sp" builder in
      let v  = build_load (ltype_of_ast elem_ty) sp "sc_v" builder in
      let dp = build_gep (ltype_of_ast elem_ty) dptr [| i_phi |] "sc_dp" builder in
      ignore (build_store v dp builder);
      let i_next = build_add i_phi (const_int usz 1) "sc_next" builder in
      add_incoming (i_next, insertion_block builder) i_phi;
      ignore (build_br cond_bb builder);
      position_at_end exit_bb builder;
      (TypeUsize, n)

  | Call ("slice_eq", [a_e; b_e]) ->
      (* Builtin: lengths equal AND elements equal; length mismatch is
         false, never an error. Same phi-loop construction as slice_copy. *)
      let (at, av) = gen_expr locals a_e in
      let (_,  bv) = gen_expr locals b_e in
      let elem_ty = match at with
        | TypeSlice (el, _) -> el
        | _ -> raise (Error "BUG: slice_eq on non-slice (type_inf should reject)")
      in
      let usz  = usize_lltype () in
      let i1t  = i1_type context in
      let aptr = slice_ptr av and alen = slice_len av in
      let bptr = slice_ptr bv and blen = slice_len bv in
      let cur_f    = block_parent (insertion_block builder) in
      let entry_bb = insertion_block builder in
      let cond_bb  = append_block context "se_cond" cur_f in
      let body_bb  = append_block context "se_body" cur_f in
      let done_bb  = append_block context "se_done" cur_f in
      let len_eq = build_icmp Icmp.Eq alen blen "se_len_eq" builder in
      ignore (build_cond_br len_eq cond_bb done_bb builder);
      position_at_end cond_bb builder;
      let i_phi  = build_phi [ (const_int usz 0, entry_bb) ] "se_i" builder in
      let at_end = build_icmp Icmp.Eq i_phi alen "se_at_end" builder in
      ignore (build_cond_br at_end done_bb body_bb builder);
      position_at_end body_bb builder;
      let ap = build_gep (ltype_of_ast elem_ty) aptr [| i_phi |] "se_ap" builder in
      let la = build_load (ltype_of_ast elem_ty) ap "se_la" builder in
      let bp = build_gep (ltype_of_ast elem_ty) bptr [| i_phi |] "se_bp" builder in
      let lb = build_load (ltype_of_ast elem_ty) bp "se_lb" builder in
      let eqv = build_icmp Icmp.Eq la lb "se_eqv" builder in
      let i_next = build_add i_phi (const_int usz 1) "se_next" builder in
      add_incoming (i_next, insertion_block builder) i_phi;
      ignore (build_cond_br eqv cond_bb done_bb builder);
      position_at_end done_bb builder;
      let res = build_phi [ (const_int i1t 0, entry_bb);   (* length mismatch  *)
                            (const_int i1t 1, cond_bb);    (* reached the end  *)
                            (const_int i1t 0, body_bb) ]   (* element mismatch *)
                  "se_res" builder in
      (TypeBool, res)

  | Call (("min" | "max") as fname, [a_e; b_e]) ->
      (* Builtin (P4c-2): sync rule with type_inf.ml's Call case -- the
         range computed here for the RESULT must match exactly (including
         the asymmetric one-operand-known cases, see that case's comment),
         or codegen could accept an access type_inf never proved. *)
      let (at, av) = gen_expr locals a_e in
      let (bt, bv) = gen_expr locals b_e in
      (* Width-sync mirroring BinOp's (sync rule): type_inf.ml's min/max
         now unifies its two arguments against EACH OTHER (not hardcoded
         TI32), so a genuinely u32/u64/usize-typed call is legal -- but
         the actual llvalues can still arrive at different LLVM widths
         (e.g. IntLit's own i32-vs-i64 guess), so widen the narrower one
         exactly like BinOp does, using is_unsigned to pick the correct
         extension direction. Previously this unconditionally truncated
         both operands to i32 via to_i32, which would have silently
         corrupted a genuinely-wide argument now that one is possible. *)
      let (at, av, bt, bv) =
        let ll1 = type_of av and ll2 = type_of bv in
        if ll1 = i64_type context && ll2 = i32_type context then
          let bvw = if is_unsigned at then build_zext bv (i64_type context) "wi" builder
                    else build_sext bv (i64_type context) "wi" builder in
          (at, av, bt, bvw)
        else if ll2 = i64_type context && ll1 = i32_type context then
          let avw = if is_unsigned bt then build_zext av (i64_type context) "wi" builder
                    else build_sext av (i64_type context) "wi" builder in
          (at, avw, bt, bv)
        else
          (at, av, bt, bv)
      in
      let range_of (ae : Ast.expr) (aty : Ast.type_expr) =
        match Const_env.bound_value ae with
        | Some k -> Some (k, k + 1)
        | None -> refinement_range aty
      in
      (* canon_ty here (not raw `at`): `at` can itself still be a
         TypeRefined wrapping the true base (e.g. one operand was already
         narrowed before reaching this call), and min_max_sentinel pattern
         -matches concrete base constructors directly -- feeding it an
         un-canon'd TypeRefined would miss the TypeU8/TypeI8/etc. cases
         and fall back to the wide generic sentinel, producing a bound
         that then fails ret_ty's OWN subtyping check below. *)
      let base = canon_ty at in
      let (sentinel_lo, sentinel_hi) = min_max_sentinel base in
      let ra = range_of a_e at and rb = range_of b_e bt in
      let lo =
        match ra, rb with
        | Some (la, _), Some (lb, _) -> if fname = "min" then min la lb else max la lb
        | _ -> if fname = "max" then
                 (match ra, rb with
                  | Some (la, _), None | None, Some (la, _) -> la
                  | _ -> sentinel_lo)
               else sentinel_lo
      in
      let hi =
        match ra, rb with
        | Some (_, ha), Some (_, hb) -> if fname = "min" then min ha hb else max ha hb
        | _ -> if fname = "min" then
                 (match ra, rb with
                  | Some (_, ha), None | None, Some (_, ha) -> ha
                  | _ -> sentinel_hi)
               else sentinel_hi
      in
      let ret_ty = TypeRefined (lo, hi, base) in
      let cmp = if is_unsigned at then
                  (if fname = "min" then build_icmp Icmp.Ult av bv "mm_cmp" builder
                   else build_icmp Icmp.Ugt av bv "mm_cmp" builder)
                else
                  (if fname = "min" then build_icmp Icmp.Slt av bv "mm_cmp" builder
                   else build_icmp Icmp.Sgt av bv "mm_cmp" builder)
      in
      (ret_ty, build_select cmp av bv "mm_res" builder)

  | Call (fname, args) ->
      let direct_name = match !current_program_types with
        | Some pt -> Option.value
            (Types.StringMap.find_opt (Types.loc_key e.loc) pt.Types.call_targets)
            ~default:fname
        | None -> fname
      in
      (match Hashtbl.find_opt functions direct_name with
       | Some (ft, callee) ->
           (* declare_func/gen_func always populate functions,
              func_ret_ast_types, and func_param_ast_types together (see
              gen_func's own comment) -- direct_name being in `functions`
              guarantees the other two, so a miss below is an internal
              inconsistency, not a legitimate "unknown signature" case. *)
           let param_asts = match Hashtbl.find_opt func_param_ast_types direct_name with
             | Some ps -> ps
             | None -> raise (Error (Printf.sprintf
                 "BUG: Call: '%s' has no func_param_ast_types entry despite being declared"
                 direct_name))
           in
           let arg_vals =
             if List.length args <> List.length param_asts then
               raise (Error (Printf.sprintf
                 "BUG: Call: '%s' called with %d argument(s), expected %d -- type_inf should have rejected this arity mismatch"
                 direct_name (List.length args) (List.length param_asts)));
             List.map2 (fun a param_ast ->
               if is_erased_view_type param_ast then begin
                 ignore (gen_expr locals a);
                 None
               end else match param_ast with
               | TypeBorrowMut _ ->
                   (match a.desc with
                    | Var name ->
                        (match Hashtbl.find_opt locals name with
                         | Some (Mut (_, ptr)) -> Some ptr
                         | _ -> raise (Error (Printf.sprintf
                             "BUG: borrow mut argument '%s' has no mutable storage"
                             name)))
                    | _ -> raise (Error
                        "BUG: borrow mut argument is not a bare variable"))
               | _ ->
                   let (_, av) = gen_expr ~expected_ty:param_ast locals a in
                   Some (coerce av param_ast)
             ) args param_asts
             |> List.filter_map Fun.id
             |> Array.of_list
           in
           let ret_lty = return_type ft in
           let call_name = if ret_lty = void_type context then "" else "calltmp" in
           let v = build_call ft callee arg_vals call_name builder in
           let ast_ret = match Hashtbl.find_opt func_ret_ast_types direct_name with
             | Some t -> t
             | None -> raise (Error (Printf.sprintf
                 "BUG: Call: '%s' has no func_ret_ast_types entry despite being declared"
                 direct_name))
           in
           if is_erased_view_type ast_ret then
             (ast_ret, erased_view_value ())
           else
             (ast_ret, to_arith_width ast_ret v)
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
            | TypeFn (param_asts, ret_ast, _) ->
                let param_lls = List.map ltype_of_ast param_asts |> Array.of_list in
                let ret_ll    = ltype_of_ret_ast ret_ast in
                let ft        = function_type ret_ll param_lls in
                let arg_vals  =
                  List.map2 (fun a param_ast ->
                    coerce (snd (gen_expr ~expected_ty:param_ast locals a)) param_ast
                  ) args param_asts |> Array.of_list
                in
                let call_name = if ret_ll = void_type context then "" else "calltmp" in
                let v = build_call ft fn_ptr arg_vals call_name builder in
                (ret_ast, to_arith_width ret_ast v)
            | _ ->
                raise (Error (Printf.sprintf
                  "'%s' is not a function or function pointer" fname))))

(* -- Function codegen ---------------------------------------------------- *)

let gen_func ?prog_types fdef =
  let key = function_key prog_types fdef in
  let res name ty_opt = resolve_local_ast prog_types key name ty_opt in

  (* gen_program's Pass 1 (declare_func) registers every FuncDef's signature
     -- in `functions`, `func_ret_ast_types`, AND `func_param_ast_types`
     together -- before Pass 2 calls gen_func on that same fdef; this
     function is never invoked any other way (confirmed: test_takibi.ml's
     codegen tests always go through gen_program, never gen_func directly).
     A missing entry here would mean gen_func ran for a function Pass 1
     never saw -- raise instead of quietly re-declaring it (which used to
     populate `functions`/`func_ret_ast_types` but not
     `func_param_ast_types`, a real asymmetry masked by this fallback). *)
  let (_, f) =
    match Hashtbl.find_opt functions key with
    | Some x -> x
    | None -> raise (Error (Printf.sprintf
        "BUG: gen_func: '%s' not declared by Pass 1 (declare_func)" key))
  in

  let ret_ast = match Hashtbl.find_opt func_ret_ast_types key with
    | Some t -> t
    | None -> raise (Error (Printf.sprintf
        "BUG: gen_func: '%s' has no func_ret_ast_types entry despite being declared" key))
  in

  let entry_bb = append_block context "entry" f in
  position_at_end entry_bb builder;

  (* DWARF: one DISubprogram per function, captured (together with the
     DIBuilder and DIFile used to create it) so gen_stmt and the two
     parameter/local-variable loops below can all attach info scoped to it.
     di_ctx is None whenever -g wasn't passed, making every DWARF-related
     block below a no-op. *)
  let di_ctx =
    if !debug_info_enabled then begin
      let dib = match !dibuilder_opt with Some d -> d | None -> assert false in
      let cu  = match !di_compile_unit with Some c -> c | None -> assert false in
      let file = di_file_for dib fdef.def_loc.Lexing.pos_fname in
      let line = fdef.def_loc.Lexing.pos_lnum in
      let param_ast_for_di =
        Option.value (Hashtbl.find_opt func_param_ast_types key)
          ~default:(List.map (fun (n, t) -> res n t) fdef.params)
        |> List.filter (fun t -> not (is_erased_view_type t))
      in
      let subroutine_ty =
        Llvm_debuginfo.dibuild_create_subroutine_type dib ~file
          ~param_types:(Array.of_list
            (ditype_of_ast dib file ret_ast :: List.map (ditype_of_ast dib file) param_ast_for_di))
          (Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero)
      in
      let sp =
        Llvm_debuginfo.dibuild_create_function dib
          ~scope:cu ~name:fdef.name ~linkage_name:key ~file ~line_no:line
          ~ty:subroutine_ty ~is_local_to_unit:false ~is_definition:true
          ~scope_line:line ~flags:(Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero)
          ~is_optimized:true
      in
      Llvm_debuginfo.set_subprogram f sp;
      (* Seed a location before the parameter-alloca/pre-alloca prologue below,
         which runs before the first gen_stmt call would otherwise set one. *)
      let loc = Llvm_debuginfo.dibuild_create_debug_location context ~line ~column:1 ~scope:sp in
      set_current_debug_location builder (metadata_as_value context loc);
      Some (dib, file, sp)
    end else None
  in
  let di_subprogram = Option.map (fun (_, _, sp) -> sp) di_ctx in

  (* Emit an llvm.dbg.declare for an alloca-backed parameter/local so it shows
     up with a real value in gdb. Llvm_debuginfo exposes dbg.declare insertion
     but not dbg.value, so immutable SSA lets get debug-only allocas under -g;
     without those, gdb would have no stable location to inspect. *)
  let declare_var ~is_param ~argno ~name ~ast_ty ~line ~ptr =
    match di_ctx with
    | None -> ()
    | Some (dib, file, sp) ->
        let ty = ditype_of_ast dib file ast_ty in
        let flags = Llvm_debuginfo.diflags_get Llvm_debuginfo.DIFlag.Zero in
        let var_di =
          if is_param
          then Llvm_debuginfo.dibuild_create_parameter_variable dib
                 ~scope:sp ~name ~argno ~file ~line ~ty ~always_preserve:true flags
          else Llvm_debuginfo.dibuild_create_auto_variable dib
                 ~scope:sp ~name ~file ~line ~ty ~always_preserve:true flags ~align_in_bits:0
        in
        let loc = Llvm_debuginfo.dibuild_create_debug_location context ~line ~column:1 ~scope:sp in
        ignore (Llvm_debuginfo.dibuild_insert_declare_at_end dib
                  ~storage:ptr ~var_info:var_di ~expr:(Llvm_debuginfo.dibuild_expression dib [||])
                  ~location:loc ~block:entry_bb)
  in
  (* for-loop counters ("__for_<name>") are an internal implementation detail
     with a mangled name that doesn't correspond to any `let mut` the user
     wrote -- see collect_lets -- so they're deliberately excluded here. *)
  let is_for_counter name = String.length name > 6 && String.sub name 0 6 = "__for_" in

  (* locals maps name -> local_binding *)
  let locals : (string, local_binding) Hashtbl.t = Hashtbl.create 16 in
  let debug_immutable_allocas : (string, Ast.type_expr * llvalue) Hashtbl.t = Hashtbl.create 16 in
  let mutable_pattern_allocas : (string, Ast.type_expr * llvalue) Hashtbl.t =
    Hashtbl.create 8 in

  (* Apply struct type-level alignment to an alloca if the type has one registered. *)
  let apply_struct_align ast_ty ptr =
    match ast_ty with
    | TypeNamed sname | TypeArray (TypeNamed sname, _)
    | TypeIndexed (sname, _) ->
        (match Hashtbl.find_opt struct_alignments sname with
         | Some n -> set_alignment n ptr
         | None   -> ())
    | _ -> ()
  in

  let rec is_debug_aggregate_ty = function
    | TypeArray _ | TypeSlice _ | TypeTuple _ | TypeVariant _ -> true
    | TypeNamed sname -> not (Hashtbl.mem enum_underlying sname)
    | TypeIndexed _ -> true
    | TypeExists (_, _, body) -> is_debug_aggregate_ty body
    | TypeRefined (_, _, base)
    | TypeSingleton (base, _)
    | TypeBorrow base
    | TypeBorrowMut base
    | TypeSink base
    | TypeIo base -> is_debug_aggregate_ty base
    | TypeView _ | TypeAlignedPtr _ | TypePtr _ | TypeFn _
    | TypeI8 | TypeU8 | TypeI16 | TypeU16 | TypeI32 | TypeU32
    | TypeI64 | TypeU64 | TypeUsize | TypeIsize | TypeBool | TypeVoid -> false
  in

  (* Runtime parameters use allocas as before. Erased view parameters occupy
     neither an LLVM parameter slot nor stack/debug storage. *)
  let runtime_param_index = ref 0 in
  let param_abi_types = Option.value
    (Hashtbl.find_opt func_param_ast_types key)
    ~default:(List.map (fun (name, ty) -> res name ty) fdef.params) in
  List.iter2 (fun (name, ty_opt) abi_ty ->
    let ast_ty = res name ty_opt in
    if is_erased_view_type abi_ty then
      Hashtbl.add locals name (Imm (ast_ty, erased_view_value ()))
    else begin
      let i = !runtime_param_index in
      incr runtime_param_index;
      match abi_ty with
      | TypeBorrowMut _ ->
          let ptr = param f i in
          Hashtbl.add locals name (Mut (ast_ty, ptr));
          declare_var ~is_param:true ~argno:(i + 1) ~name ~ast_ty
            ~line:fdef.def_loc.Lexing.pos_lnum ~ptr
      | _ ->
          let ptr = build_alloca (ltype_of_ast ast_ty) name builder in
          apply_struct_align ast_ty ptr;
          let inst = build_store (param f i) ptr builder in
          if !debug_info_enabled && is_debug_aggregate_ty ast_ty then set_volatile true inst;
          Hashtbl.add locals name (Mut (ast_ty, ptr));
          declare_var ~is_param:true ~argno:(i + 1) ~name ~ast_ty
            ~line:fdef.def_loc.Lexing.pos_lnum ~ptr
    end
  ) fdef.params param_abi_types;

  (* Pre-alloca every mutable Let declared in the body *)
  List.iter (fun (name, ty_opt, let_loc, align_opt) ->
    if not (Hashtbl.mem locals name) then begin
      let ast_ty = res name ty_opt in
      if not (is_erased_view_type ast_ty) then begin
        let ptr = build_alloca (ltype_of_ast ast_ty) name builder in
        (* An explicit `let ... align(N)` wins over the type's own struct-level
           alignment (if any) -- same precedence as the global case (see
           gen_global's eff_align). *)
        (match align_opt with
         | Some n -> set_alignment n ptr
         | None   -> apply_struct_align ast_ty ptr);
        Hashtbl.add locals name (Mut (ast_ty, ptr));
        if not (is_for_counter name) then
          declare_var ~is_param:false ~argno:0 ~name ~ast_ty
            ~line:let_loc.Lexing.pos_lnum ~ptr
      end
    end
  ) (collect_lets fdef.body);

  List.iter (fun (pattern_key, name, ast_ty, _) ->
    if not (Hashtbl.mem mutable_pattern_allocas pattern_key) then begin
      let ptr = build_alloca (ltype_of_ast ast_ty) (name ^ ".payload") builder in
      apply_struct_align ast_ty ptr;
      Hashtbl.add mutable_pattern_allocas pattern_key (ast_ty, ptr)
    end
  ) (collect_mutable_pattern_binders fdef.body);

  (* Debug-only storage for immutable lets. The real codegen binding remains
     Imm/SSA; this alloca exists solely so GDB has a concrete location. *)
  if !debug_info_enabled then
    List.iter (fun (name, ty_opt, let_loc) ->
      if not (Hashtbl.mem debug_immutable_allocas name) then begin
        let ast_ty = res name ty_opt in
        match ast_ty with
        | TypeTuple _ | TypeView _ -> ()
        | _ ->
            let ptr = build_alloca (ltype_of_ast ast_ty) (name ^ ".dbg") builder in
            apply_struct_align ast_ty ptr;
            Hashtbl.add debug_immutable_allocas name (ast_ty, ptr);
            declare_var ~is_param:false ~argno:0 ~name ~ast_ty
              ~line:let_loc.Lexing.pos_lnum ~ptr
      end
    ) (collect_immutable_lets fdef.body);

  emit_profile_enter key;

  (* Recursively initialize a memory location from a possibly-nested literal.
     Handles nested StructLit for struct/array fields; falls back to gen_expr+store. *)
  let rec init_memory ?(preserve_for_debug = false) (ptr : llvalue) (ast_ty : Ast.type_expr) (e : Ast.expr) =
    match e.desc, ast_ty with
    | StructLit exprs, TypeNamed sname
    | StructLit exprs, TypeIndexed (sname, _) ->
        let llty = Hashtbl.find struct_lltypes sname in
        let fields = Hashtbl.find struct_fields sname in
        List.iteri (fun i ((_, ft), ei) ->
          let fptr = build_in_bounds_gep llty ptr
            [| const_int (i32_type context) 0; const_int (i32_type context) i |]
            ("fld" ^ string_of_int i) builder in
          init_memory ~preserve_for_debug fptr ft ei
        ) (List.combine fields exprs)
    | StructLit exprs, TypeArray (elem_ty, n) ->
        let arr_ll = array_type (ltype_of_ast elem_ty) n in
        List.iteri (fun i ei ->
          let ep = build_in_bounds_gep arr_ll ptr
            [| const_int (i32_type context) 0; const_int (i32_type context) i |]
            ("elem" ^ string_of_int i) builder in
          init_memory ~preserve_for_debug ep elem_ty ei
        ) exprs
    | _ ->
        let (_, v) = gen_expr ~expected_ty:ast_ty locals e in
        let inst = build_store (coerce v ast_ty) ptr builder in
        if preserve_for_debug then set_volatile true inst
  in

  (* Stack of (break_bb, continue_bb) for the innermost enclosing loop.
     Pushed when entering While/For, popped on exit. *)
  let loop_stack : (llbasicblock * llbasicblock) Stack.t = Stack.create () in

  (* -- Statement codegen (defined here to access `res` for immutable lets) -- *)
  let rec gen_stmt (s : Ast.stmt) =
    (* DWARF: every build_* call after set_current_debug_location auto-attaches
       this location, until the next call changes it -- so one call per statement
       here is enough to tag the whole statement, including nested If/While/For/
       Block bodies (they recurse back into gen_stmt with their own s.loc). *)
    (match di_subprogram with
     | Some sp ->
         let line   = s.loc.Lexing.pos_lnum in
         let column = s.loc.Lexing.pos_cnum - s.loc.Lexing.pos_bol + 1 in
         let loc    = Llvm_debuginfo.dibuild_create_debug_location context ~line ~column ~scope:sp in
         set_current_debug_location builder (metadata_as_value context loc)
     | None -> ());
    (* Skip dead code after a terminator *)
    if block_terminator (insertion_block builder) <> None then ()
    else
    match s.desc with
    | Return e ->
        let (_, v) = gen_expr ~expected_ty:ret_ast locals e in
        if is_erased_view_type ret_ast then
          emit_profile_return key (fun () -> ignore (build_ret_void builder))
        else
          let rv = coerce v ret_ast in
          emit_profile_return key (fun () -> ignore (build_ret rv builder))

    | Expr e ->
        ignore (gen_expr locals e)

    | Assign (name, e) ->
        (* Look up the target's type first (a second, cheap lookup below
           re-derives the same binding for the actual store) so a bare
           literal on the RHS can be hinted directly at the assignment
           target's type instead of guessing from its own magnitude. *)
        let target_ty_opt =
          match Hashtbl.find_opt locals name with
          | Some (Mut (ast_ty, _)) -> Some ast_ty
          | Some (Imm (ast_ty, _)) when is_erased_view_type ast_ty -> Some ast_ty
          | Some (Imm _) | None ->
              (match Hashtbl.find_opt global_vars name with
               | Some (ast_ty, _) -> Some ast_ty
               | None -> None)
        in
        let (_, v) = gen_expr ?expected_ty:target_ty_opt locals e in
        (match Hashtbl.find_opt locals name with
         | Some (Mut (ast_ty, ptr)) ->
             let inst = build_store (coerce v ast_ty) ptr builder in
             (match ast_ty with TypeIo _ -> set_volatile true inst | _ -> ())
         | Some (Imm (ast_ty, _)) when is_erased_view_type ast_ty ->
             Hashtbl.replace locals name (Imm (ast_ty, erased_view_value ()))
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
        let pointee_ty = match ptr_ty with
          | TypePtr (TypeIo inner) | TypePtr inner -> Some inner
          | _ -> None
        in
        let (_, val_v) = gen_expr ?expected_ty:pointee_ty locals val_expr in
        let (is_volatile, coerced) = match ptr_ty with
          | TypePtr (TypeIo inner) -> (true,  coerce val_v inner)   (* *io T: volatile store *)
          | TypePtr inner          -> (false, coerce val_v inner)   (* regular pointer: non-volatile *)
          | _                      -> (false, val_v)
        in
        let inst = build_store coerced ptr_v builder in
        if is_volatile then set_volatile true inst

    | AssignIndex (id, idx, rhs) ->
        let (idx_ty_raw, idx_raw) = gen_expr locals idx in
        let idx_v = to_index_width ~is_signed:(not (is_unsigned idx_ty_raw)) idx_raw in
        (* Same idx_ty priority as gen_expr's Index case (sync rule):
           Const_env constant name > narrowing_ctx > raw inferred type. *)
        let idx_ty = match Const_env.bound_value idx with
          | Some k -> TypeRefined (k, k + 1, TypeUsize)  (* idx_v is already forced to usize width via to_index_width above *)
          | None ->
              (match idx.desc with
               | Var n -> (match Hashtbl.find_opt narrowing_ctx n with
                           | Some t -> t | None -> idx_ty_raw)
               | _ -> idx_ty_raw)
        in
        (* Peek at the container's element type so a bare literal RHS can
           be hinted directly, mirroring the fuller match on the same
           binding further below (which does the actual store). *)
        let elem_ty_hint =
          match Hashtbl.find_opt locals id with
          | Some (Mut (TypeArray (elem_ty, _), _))
          | Some (Mut (TypeSlice (elem_ty, _), _))
          | Some (Imm (TypeSlice (elem_ty, _), _))
          | Some (Mut (TypePtr (TypeIo elem_ty), _))
          | Some (Mut (TypePtr elem_ty, _))
          | Some (Imm (TypePtr (TypeIo elem_ty), _))
          | Some (Imm (TypePtr elem_ty, _))
          | Some (Mut (TypeAlignedPtr (_, TypeIo elem_ty), _))
          | Some (Mut (TypeAlignedPtr (_, elem_ty), _))
          | Some (Imm (TypeAlignedPtr (_, TypeIo elem_ty), _))
          | Some (Imm (TypeAlignedPtr (_, elem_ty), _)) -> Some elem_ty
          | _ -> None
        in
        let (_, rhs_v) = gen_expr ?expected_ty:elem_ty_hint locals rhs in
        let store_to_array elem_ty n arr_ptr =
          let needs_check = match refinement_range idx_ty with
            | Some (lo, hi) -> lo < 0 || hi > n
            | _ -> true
          in
          if needs_check then emit_bounds_check s.loc idx_ty idx_v n;
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
        (* Mirrors load_from_slice in gen_expr's Index case: elide only when
           idx's range fits the compile-time minimum, else check against the
           runtime length. *)
        let store_to_slice elem_ty min_len fat =
          let proven = match refinement_range idx_ty with
            | Some (lo, hi) -> lo >= 0 && hi <= min_len
            | _ -> false
          in
          if not proven then
            emit_bounds_check_dyn s.loc idx_ty idx_v min_len (slice_len fat);
          let ep = build_gep (ltype_of_ast elem_ty) (slice_ptr fat) [|idx_v|] "idx_ptr" builder in
          ignore (build_store (coerce rhs_v elem_ty) ep builder)
        in
        (match Hashtbl.find_opt locals id with
         | Some (Mut (TypeArray (elem_ty, n), ptr)) ->
             store_to_array elem_ty n ptr
         | Some (Mut (TypeSlice (el, m), alloca_ptr)) ->
             let fat = build_load (ltype_of_ast (TypeSlice (el, m))) alloca_ptr id builder in
             store_to_slice el (effective_slice_min id m) fat
         | Some (Imm (TypeSlice (el, m), fat)) ->
             store_to_slice el m fat
         | Some (Mut (TypePtr (TypeIo elem_ty), alloca_ptr))
         | Some (Mut (TypeAlignedPtr (_, TypeIo elem_ty), alloca_ptr)) ->
             let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
             store_through_ptr elem_ty ptr_v true
         | Some (Mut (TypePtr elem_ty, alloca_ptr))
         | Some (Mut (TypeAlignedPtr (_, elem_ty), alloca_ptr)) ->
             let ptr_v = build_load (pointer_type context) alloca_ptr id builder in
             store_through_ptr elem_ty ptr_v false
         | Some (Imm (TypePtr (TypeIo elem_ty), ptr_v))
         | Some (Imm (TypeAlignedPtr (_, TypeIo elem_ty), ptr_v)) ->
             store_through_ptr elem_ty ptr_v true
         | Some (Imm (TypePtr elem_ty, ptr_v))
         | Some (Imm (TypeAlignedPtr (_, elem_ty), ptr_v)) ->
             store_through_ptr elem_ty ptr_v false
         | Some _ ->
             raise (Error (Printf.sprintf "AssignIndex: '%s' is not an array or pointer" id))
         | None ->
             (match Hashtbl.find_opt global_vars id with
              | Some (TypeArray (elem_ty, n), gptr) ->
                  store_to_array elem_ty n gptr
              | Some (TypeSlice (el, m), gptr) ->
                  let fat = build_load (ltype_of_ast (TypeSlice (el, m))) gptr id builder in
                  store_to_slice el (effective_slice_min id m) fat
              | Some (TypePtr (TypeIo elem_ty), gptr)
              | Some (TypeAlignedPtr (_, TypeIo elem_ty), gptr) ->
                  let ptr_v = build_load (pointer_type context) gptr id builder in
                  store_through_ptr elem_ty ptr_v true
              | Some (TypePtr elem_ty, gptr)
              | Some (TypeAlignedPtr (_, elem_ty), gptr) ->
                  let ptr_v = build_load (pointer_type context) gptr id builder in
                  store_through_ptr elem_ty ptr_v false
              | Some _ ->
                  raise (Error (Printf.sprintf "AssignIndex: '%s' is not an array or pointer" id))
              | None ->
                  raise (Error (Printf.sprintf "AssignIndex: undefined variable '%s'" id))))

    | AssignField (base_expr, fname, val_expr) ->
        let (base_ty, base_v) = gen_expr locals base_expr in
        let (sname, through_io, base_ptr) = match base_ty with
          | TypeNamed s                      -> (s, false, base_v)
          | TypePtr (TypeNamed s)            -> (s, false, base_v)
          | TypePtr (TypeIo (TypeNamed s))   -> (s, true, base_v)
          | TypeAlignedPtr (_, TypeNamed s)  -> (s, false, base_v)   (* GitHub issue #102 *)
          | TypeIndexed (s, _) ->
              (match base_expr.desc with
               | Var name ->
                   (match Hashtbl.find_opt locals name with
                    | Some (Mut (TypeIndexed _, ptr)) -> (s, false, ptr)
                    | _ -> raise (Error (Printf.sprintf
                        "BUG: indexed owner '%s' field assignment has no mutable storage"
                        name)))
               | _ -> raise (Error
                   "BUG: indexed owner field assignment has no stable base"))
          | _ -> raise (Error (Printf.sprintf
              "field assignment '.%s' on non-struct type" fname))
        in
        let (idx, field_ty) = field_info sname fname in
        let llty = Hashtbl.find struct_lltypes sname in
        let (_, val_v) = gen_expr ~expected_ty:field_ty locals val_expr in
        let field_ptr = build_in_bounds_gep llty base_ptr
          [| const_int (i32_type context) 0; const_int (i32_type context) idx |]
          (fname ^ "_ptr") builder
        in
        let inst = build_store (coerce val_v field_ty) field_ptr builder in
        if through_io || (match field_ty with TypeIo _ -> true | _ -> false)
        then set_volatile true inst

    | Let (true, name, ty_opt, expr_opt, _) ->
        (* Mutable: alloca was pre-allocated; store the initial value via init_memory *)
        let ast_ty = res name ty_opt in
        if is_erased_view_type ast_ty then begin
          (match expr_opt with
           | Some e -> ignore (gen_expr ~expected_ty:ast_ty locals e)
           | None -> raise (Error (Printf.sprintf
               "BUG: erased view '%s' has no initializer" name)));
          Hashtbl.replace locals name (Imm (ast_ty, erased_view_value ()))
        end else
        (match Hashtbl.find_opt locals name with
         | None -> raise (Error (Printf.sprintf "BUG: no alloca for %s" name))
         | Some (Mut (ast_ty, ptr)) ->
             let preserve_for_debug = !debug_info_enabled && is_debug_aggregate_ty ast_ty in
             Option.iter (init_memory ~preserve_for_debug ptr ast_ty) expr_opt
         | Some (Imm _) ->
             raise (Error (Printf.sprintf "BUG: %s marked mutable but stored as Imm" name)))

    | Let (false, name, ty_opt, expr_opt, _) ->
        (* Immutable: evaluate the init expr and store the SSA value directly *)
        (match expr_opt with
         | None ->
             raise (Error (Printf.sprintf "BUG: immutable '%s' has no initializer" name))
         | Some e ->
             let ast_ty = res name ty_opt in
             let (_, v) = gen_expr ~expected_ty:ast_ty locals e in
             if is_erased_view_type ast_ty then
               Hashtbl.add locals name (Imm (ast_ty, erased_view_value ()))
             else begin
               let coerced = coerce v ast_ty in
               (match Hashtbl.find_opt debug_immutable_allocas name with
                | Some (_, ptr) ->
                    let inst = build_store coerced ptr builder in
                    set_volatile true inst
                | None -> ());
               Hashtbl.add locals name (Imm (ast_ty, coerced))
             end)

    | LetTuple (names, rhs) ->
        (* OWNERSHIP_KERNEL.md 5.9: destructure a tuple value into
           immutable SSA bindings via extractvalue -- one Imm binding per
           component, mirroring Let(false, ...) above. Component types come
           from local_types (res with no annotation), the same source any
           unannotated let uses, so kind tracking and codegen agree. *)
        let comp_tys = List.map (fun n -> res n None) names in
        let tuple_ty = TypeTuple comp_tys in
        let (_, v) = gen_expr ~expected_ty:tuple_ty locals rhs in
        let v = coerce v tuple_ty in
        List.iteri (fun i n ->
          let cty = List.nth comp_tys i in
          let cv = build_extractvalue v i ("tup_" ^ n) builder in
          (match Hashtbl.find_opt debug_immutable_allocas n with
           | Some (_, ptr) ->
               let inst = build_store cv ptr builder in
               set_volatile true inst
           | None -> ());
          Hashtbl.add locals n (Imm (cty, cv))
        ) names

    | Block stmts ->
        List.iter gen_stmt stmts

    | If (cond, then_stmts, else_stmts) ->
        let cond_v   = as_cond (snd (gen_expr locals cond)) in
        let then_bb  = append_block context "then"  f in
        let else_bb  = append_block context "else"  f in
        let merge_bb = append_block context "merge" f in
        ignore (build_cond_br cond_v then_bb else_bb builder);

        position_at_end then_bb builder;
        let killed    = Ast.written_names then_stmts in
        let saved     = apply_narrowing     locals cond killed in
        let saved_mut = apply_narrowing_mut locals cond killed in
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

    | For (name, _ty_opt, lo_expr, hi_expr, body) ->
        (* _ty_opt (the explicit `for i: T in ...` annotation, if any) is
           not consulted directly here: type_inf.ml has already folded it
           into the counter's resolved type, retrieved below via `res
           ctr_name None` exactly as before -- codegen needs no separate
           annotation-handling logic of its own. *)
        (* Loop counter is pre-allocated in the entry block by collect_lets,
           at whatever type type_inf.ml determined for the bounds (sync
           rule: both sides now unify lo/hi against EACH OTHER instead of
           hardcoding TI32, so the counter's base follows the bounds' own
           type -- e.g. `for i in 0..<s.len` gives i a usize-based type,
           matching s.len itself, instead of failing to compile at all).
           The loop variable name is exposed to the body as an Imm binding
           (no reassignment). When both bounds are integer literals,
           assigns TypeRefined -> bounds check elision (Step 3.4). *)
        (* Looked up by the MANGLED "__for_<name>" key, matching what
           type_inf.ml's For case actually stores in raw_locals -- the
           bare user-visible name is deliberately NOT reused here (a flat,
           whole-function StringMap keyed by plain "i" would collide with
           an unrelated local, or a second for-loop, also named "i"). *)
        let ctr_name     = "__for_" ^ name in
        let counter_ty   = res ctr_name None in
        let counter_base = canon_ty counter_ty in
        let is_uns       = is_unsigned counter_base in
        let (_, lo_v0) = gen_expr ~expected_ty:counter_base locals lo_expr in
        let (_, hi_v0) = gen_expr ~expected_ty:counter_base locals hi_expr in
        let lo_w      = to_arith_width counter_base lo_v0 in
        let hi_w      = to_arith_width counter_base hi_v0 in
        let ctr_ptr   = match Hashtbl.find_opt locals ctr_name with
          | Some (Mut (_, p)) -> p
          | _ -> raise (Error (Printf.sprintf "BUG: for counter '%s' not found" ctr_name))
        in
        ignore (build_store (coerce lo_w counter_base) ctr_ptr builder);
        let cond_bb = append_block context "for_cond" f in
        let body_bb = append_block context "for_body" f in
        let incr_bb = append_block context "for_incr" f in
        let exit_bb = append_block context "for_exit" f in
        ignore (build_br cond_bb builder);

        position_at_end cond_bb builder;
        let i_raw = build_load (ltype_of_ast counter_base) ctr_ptr "for_i" builder in
        let i_val = to_arith_width counter_base i_raw in
        let cmp   = if is_uns then build_icmp Icmp.Ult i_val hi_w "for_cmp" builder
                    else build_icmp Icmp.Slt i_val hi_w "for_cmp" builder in
        ignore (build_cond_br cmp body_bb exit_bb builder);

        position_at_end body_bb builder;
        (* Sync rule: type_inf.ml's For case makes the same decision through
           the same Const_env.bound_value helper; keep them identical. *)
        let loop_ty = match Const_env.bound_value lo_expr, Const_env.bound_value hi_expr with
          | Some lo_k, Some hi_k -> TypeRefined (lo_k, hi_k, counter_base)
          | _ -> counter_base
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
        let i_next = build_add i_val (const_int (type_of i_val) 1) "for_next" builder in
        ignore (build_store (coerce i_next counter_base) ctr_ptr builder);
        ignore (build_br cond_bb builder);

        position_at_end exit_bb builder

    | ForEach (name, se, body) ->
        (* Element iteration over a slice: the compiler generates the
           counter, the length compare, and the in-bounds element load
           itself -- safe by construction, zero trap sites, no index proof
           ever needed. The slice expression is evaluated ONCE here
           (snapshot semantics; reassigning the slice variable inside the
           body does not affect the iteration -- same as For evaluating its
           bounds once). Block layout mirrors For, including continue ->
           incr_bb. *)
        let (sty, fat) = gen_expr locals se in
        let elem_ty = match sty with
          | TypeSlice (el, _) -> el
          | _ -> raise (Error "BUG: for-in over non-slice (type_inf should reject)")
        in
        let ptr   = slice_ptr fat in
        let len_v = slice_len fat in
        let usz   = usize_lltype () in
        let ctr_name = "__foreach_" ^ name in
        let ctr_ptr  = match Hashtbl.find_opt locals ctr_name with
          | Some (Mut (_, p)) -> p
          | _ -> raise (Error (Printf.sprintf "BUG: foreach counter '%s' not found" ctr_name))
        in
        ignore (build_store (const_int usz 0) ctr_ptr builder);
        let cond_bb = append_block context "fe_cond" f in
        let body_bb = append_block context "fe_body" f in
        let incr_bb = append_block context "fe_incr" f in
        let exit_bb = append_block context "fe_exit" f in
        ignore (build_br cond_bb builder);

        position_at_end cond_bb builder;
        let i_val = build_load usz ctr_ptr "fe_i" builder in
        let cmp   = build_icmp Icmp.Ult i_val len_v "fe_cmp" builder in
        ignore (build_cond_br cmp body_bb exit_bb builder);

        position_at_end body_bb builder;
        let ep = build_gep (ltype_of_ast elem_ty) ptr [| i_val |] "fe_ptr" builder in
        let ev = build_load (ltype_of_ast elem_ty) ep "fe_val" builder in
        Hashtbl.add locals name (Imm (elem_ty, to_arith_width elem_ty ev));
        Stack.push (exit_bb, incr_bb) loop_stack;
        List.iter gen_stmt body;
        ignore (Stack.pop loop_stack);
        Hashtbl.remove locals name;
        if block_terminator (insertion_block builder) = None then
          ignore (build_br incr_bb builder);

        position_at_end incr_bb builder;
        let i_next = build_add i_val (const_int usz 1) "fe_next" builder in
        ignore (build_store i_next ctr_ptr builder);
        ignore (build_br cond_bb builder);

        position_at_end exit_bb builder

    | Match (disc, arms) ->
        let (disc_ty, disc_v) = gen_expr locals disc in
        let variant_name = match disc_ty with
          | TypeVariant name -> Some name
          | TypeNamed name when Hashtbl.mem variant_defs name -> Some name
          | _ -> None
        in
        let switch_v = match variant_name with
          | Some _ -> build_extractvalue disc_v 0 "variant.tag" builder
          | None -> disc_v
        in
        let switch_ll_ty = type_of switch_v in
        let merge_bb = append_block context "match_merge" f in
        let dead_bb  = append_block context "match_dead"  f in
        let merge_reachable = ref false in
        (* Build per-arm basic blocks *)
        let arm_bbs = List.map (fun arm ->
          match arm with
          | ArmVariant (_, vname, _, _) ->
              (arm, append_block context ("match_" ^ vname) f)
          | ArmWild _ ->
              (arm, append_block context "match_wild" f)
        ) arms in
        (* Default target: wildcard arm if present, otherwise dead (unreachable) *)
        let default_bb = match List.find_opt (fun (a, _) ->
          match a with ArmWild _ -> true | _ -> false) arm_bbs with
          | Some (_, bb) -> bb
          | None         -> dead_bb
        in
        let n_variants = List.length (List.filter (fun (a, _) ->
          match a with ArmVariant _ -> true | _ -> false) arm_bbs) in
        let sw = build_switch switch_v default_bb n_variants builder in
        List.iter (fun (arm, bb) ->
          match arm with
          | ArmVariant (ename, vname, _, _) ->
              let value = match variant_name with
                | Some actual when actual = ename ->
                    (variant_case ename vname).variant_tag
                | Some actual -> raise (Error (Printf.sprintf
                    "BUG: match arm variant '%s' does not match '%s'"
                    ename actual))
                | None ->
                    let variants = Hashtbl.find enum_variants_tbl ename in
                    List.assoc vname variants
              in
              add_case sw (const_int switch_ll_ty value) bb
          | ArmWild _ -> ()
        ) arm_bbs;
        List.iter (fun (arm, bb) ->
          position_at_end bb builder;
          (match arm with
           | ArmVariant (vtype, cname, binding, body) ->
               (match variant_name, binding with
                | Some _, Some (name, is_mutable) ->
                    let layout = variant_case vtype cname in
                    let schema = match layout.variant_payload with
                      | Some schema -> schema
                      | None -> raise (Error (Printf.sprintf
                          "BUG: nullary variant %s::%s has a match binder"
                          vtype cname))
                    in
                    let payload_ty = runtime_payload_type schema in
                    let payload_v = match layout.variant_payload_field with
                      | Some field ->
                          build_extractvalue disc_v field
                            ("variant." ^ name) builder
                      | None -> erased_view_value ()
                    in
                    let old = Hashtbl.find_opt locals name in
                    if is_mutable && not (is_erased_view_type payload_ty) then begin
                      let pattern_key = mutable_pattern_key s.loc vtype cname name in
                      let (_, ptr) = match Hashtbl.find_opt mutable_pattern_allocas pattern_key with
                        | Some entry -> entry
                        | None -> raise (Error (Printf.sprintf
                            "BUG: mutable variant binder '%s' was not pre-allocated" name))
                      in
                      ignore (build_store (coerce payload_v payload_ty) ptr builder);
                      Hashtbl.replace locals name (Mut (payload_ty, ptr))
                    end else
                      Hashtbl.replace locals name (Imm (payload_ty, payload_v));
                    List.iter gen_stmt body;
                    (match old with
                     | Some prior -> Hashtbl.replace locals name prior
                     | None -> Hashtbl.remove locals name)
                | Some _, None -> List.iter gen_stmt body
                | None, None -> List.iter gen_stmt body
                | None, Some _ -> raise (Error
                    "BUG: numeric enum match arm has a payload binder"))
           | ArmWild body            -> List.iter gen_stmt body);
          if block_terminator (insertion_block builder) = None then begin
            merge_reachable := true;
            ignore (build_br merge_bb builder)
          end
        ) arm_bbs;
        (* dead_bb: only reachable when no wildcard and match is fully exhaustive *)
        position_at_end dead_bb builder;
        ignore (build_unreachable builder);
        position_at_end merge_bb builder;
        (* A fully terminating match still needs an LLVM terminator on its
           synthetic merge block even though no arm branches there. Leaving
           it open made gen_func's generic scalar fallback try to return an
           integer zero from aggregate-returning functions. *)
        if not !merge_reachable then ignore (build_unreachable builder)
  in

  List.iter gen_stmt fdef.body;

  (* Ensure the exit block has a terminator *)
  if block_terminator (insertion_block builder) = None then begin
    if ret_ast = TypeVoid || is_erased_view_type ret_ast then
      emit_profile_return key (fun () -> ignore (build_ret_void builder))
    else
      let rv = const_int (ltype_of_ast ret_ast) 0 in
      emit_profile_return key (fun () -> ignore (build_ret rv builder))
  end;

  (* Use the non-aborting checker, not Llvm_analysis.assert_valid_function:
     that variant prints a diagnostic to stderr and calls C's abort() (see
     llvm_analysis.mli) on invalid IR, which is not a catchable OCaml
     exception. That took down the entire test process with SIGABRT and no
     indication of which test case triggered it (see git history around
     2026-07 for the codegen bug this caught and the experiment that
     compared both). Raising Error here instead lets both the CLI (which
     already doesn't catch Error specially, same as every other internal
     Error in this file) and the test suite report a normal, attributable
     failure. *)
  if not (Llvm_analysis.verify_function f) then
    raise (Error (Printf.sprintf
      "internal compiler error: invalid LLVM IR generated for function '%s'\n%s"
      fdef.name (string_of_llvalue f)));
  f

(* -- Top-level codegen --------------------------------------------------- *)

(* Bit width to mask a compile-time integer cast against, mirroring what
   ltype_of_ast would give that AST type -- kept separate from ltype_of_ast
   itself since eval_const_int stays entirely in OCaml int space (see its
   comment below for why). *)
let rec int_bits_of_ast (ty : Ast.type_expr) =
  match ty with
  | TypeI8  | TypeU8   -> 8
  | TypeI16 | TypeU16  -> 16
  | TypeI32 | TypeU32  -> 32
  | TypeI64 | TypeU64  -> 64
  | TypeIsize          -> usize_bitwidth ()
  | TypeUsize          -> usize_bitwidth ()
  | TypeBool           -> 1
  | TypeRefined (_, _, base) -> int_bits_of_ast base
    (* Refined constants use their selected/inferred base width. Source
       annotations select it with `{lo..<hi as base}`; propagated
       refinements preserve the operand's primitive integer base. *)
  | _                  -> 64  (* not reached: eval_const only calls this for the cases above *)

let mask_to_bits bits (n : Int64.t) : Int64.t =
  if bits >= 64 then n  (* nothing narrower than Int64.t's own 64 bits to mask against *)
  else Int64.logand n (Int64.sub (Int64.shift_left 1L bits) 1L)

(* Reduce a compile-time integer/bool-valued expression (int literal, `as`
   cast chain, or a reference to an earlier immutable global constant) to
   an Int64.t -- the full 64-bit raw bit pattern, matching IntLit's own
   payload type (see CLAUDE.md's "64-bit Integer Literals" section). This
   still works entirely in Int64/OCaml space rather than emitting LLVM
   const_trunc/zext/sext at each cast layer, sidestepping a real gap: the
   LLVM 19 OCaml bindings expose const_trunc but not const_zext/const_sext,
   so a widening step has no direct constant-folding primitive to call.
   const_of_int64's own width-based wraparound already produces the
   correct final bit pattern once a value is embedded at its true
   destination width, so the only place that actually needs to happen
   mid-chain is a NARROWING cast -- hence the explicit mask on every Cast
   layer here, using that layer's own target width (not the outer
   caller's), so e.g. `(300 as u8) as i32` truncates to 44 before widening
   back to i32, instead of the outer i32 cast silently seeing the original
   untruncated 300. *)
let rec eval_const_int (e : Ast.expr) : Int64.t =
  match e.desc with
  | IntLit n -> n
  | BoolLit b -> if b then 1L else 0L
  | EnumVariant (ename, vname) ->
      let variants = match Hashtbl.find_opt enum_variants_tbl ename with
        | Some variants -> variants
        | None -> raise (Error (Printf.sprintf "Unknown enum: %s" ename))
      in
      (match List.assoc_opt vname variants with
       | Some value -> Int64.of_int value
       | None -> raise (Error (Printf.sprintf "Unknown variant %s::%s" ename vname)))
  | Cast (target_ty, inner) ->
      let v = eval_const_int inner in
      (match target_ty with
       | TypePtr _ | TypeAlignedPtr _ -> v  (* address value; no integer width to mask against *)
       | _ -> mask_to_bits (int_bits_of_ast target_ty) v)
  | BinOp (Sub, { desc = IntLit 0L; _ }, inner) ->
      (* Unary minus is desugared to this exact shape in the parser (see
         parser.mly's MINUS rule) -- recognized here so a plain negative
         global constant like `let X: i32 = -5;` folds, without taking on
         general compile-time arithmetic folding beyond this one shape. *)
      Int64.neg (eval_const_int inner)
  | Var name ->
      (match Hashtbl.find_opt global_const_defs name with
       | Some (_, ge) -> eval_const_int ge
       | None -> raise (Error (Printf.sprintf
           "'%s' is not a compile-time integer constant (must be an immutable \
            global with a constant initializer, declared earlier in the source)"
           name)))
  | SizeOf ty ->
      let elem_llty = ltype_of_ast ty in
      let dl = match !target_data with
        | Some dl -> dl
        | None -> raise (Error "sizeof: target data layout not initialized")
      in
      Llvm_target.DataLayout.abi_size elem_llty dl
  | OffsetOf (ty, field) ->
      let (name, llty) = match ty with
        | TypeNamed name -> (name, ltype_of_ast ty)
        | _ -> raise (Error "offsetof requires a named struct type")
      in
      let (field_index, _) = field_info name field in
      let dl = match !target_data with
        | Some dl -> dl
        | None -> raise (Error "offsetof: target data layout not initialized")
      in
      Llvm_target.DataLayout.offset_of_element llty field_index dl
  | _ -> raise (Error "global initializer: unsupported constant expression")

let attach_global_debug name ast_ty decl_loc gvar =
  if !debug_info_enabled then
    let dib = match !dibuilder_opt with Some d -> d | None -> assert false in
    let cu  = match !di_compile_unit with Some c -> c | None -> assert false in
    let file = di_file_for dib decl_loc.Lexing.pos_fname in
    let line = decl_loc.Lexing.pos_lnum in
    let ty = ditype_of_ast dib file ast_ty in
    let align_bits =
      match alignment gvar with
      | 0 -> snd (di_size_align_bits (ltype_of_ast ast_ty))
      | n -> n * 8
    in
    let gve =
      Llvm_debuginfo.dibuild_create_global_variable_expression dib
        ~scope:cu ~name ~linkage:name ~file ~line ~ty
        ~is_local_to_unit:false
        ~expr:(Llvm_debuginfo.dibuild_expression dib [||])
        ~decl:(Llvm_debuginfo.llmetadata_null ())
        ~align_in_bits:align_bits
    in
    ignore gve

let gen_global ?prog_types name ty_opt expr_opt align_opt is_mutable decl_loc =
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
        const_inttoptr (const_of_int64 (usize_lltype ()) i true) (pointer_type context)
    | IntLit i, _ ->
        const_of_int64 (ltype_of_ast ft) i true
    | BoolLit b, TypeBool ->
        (* Same i1 constant gen_expr's own BoolLit case builds (see that
           case above) -- gen_global's compile-time constant folding never
           exercised a bare `true`/`false` global initializer before
           (every prior affine-token-style global was an integer/pointer),
           so this arm was simply missing rather than deliberately
           unsupported. Found while adding examples/common/fat12.tkb's
           `let mut ff_is_open: bool = false;`. *)
        const_int (ltype_of_ast ft) (if b then 1 else 0)
    | EnumVariant (ename, _), TypeNamed target_name when ename = target_name ->
        let underlying = match Hashtbl.find_opt enum_underlying ename with
          | Some underlying -> underlying
          | None -> raise (Error (Printf.sprintf "Unknown enum: %s" ename))
        in
        const_of_int64 (ltype_of_ast underlying) (eval_const_int e) false
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
    | SizeOf ty, _ ->
        const_of_int64 (ltype_of_ast ft)
          (eval_const_int { Ast.desc = SizeOf ty; loc = Lexing.dummy_pos }) true
    | OffsetOf (ty, field), _ ->
        const_of_int64 (ltype_of_ast ft)
          (eval_const_int { Ast.desc = OffsetOf (ty, field); loc = Lexing.dummy_pos }) false
    | Cast (_, _), TypePtr _ ->
        const_inttoptr (const_of_int64 (usize_lltype ()) (eval_const_int e) true) (pointer_type context)
    | (Cast (_, _) | BinOp (Sub, { desc = IntLit 0L; _ }, _)),
      (TypeI8|TypeU8|TypeI16|TypeU16|TypeI32|TypeU32
      |TypeI64|TypeU64|TypeIsize|TypeUsize|TypeBool|TypeRefined _) ->
        (* Cast chains fold via eval_const_int (see its comment for why an
           `as` cast needs its own evaluator); a bare unary minus (desugared
           to BinOp(Sub, IntLit 0L, _) in the parser) reuses the same
           evaluator's matching case rather than duplicating the negation
           here. *)
        const_of_int64 (ltype_of_ast ft) (eval_const_int e) true
    | Var name, _ ->
        (match Hashtbl.find_opt global_const_defs name with
         | Some (_, ge) -> eval_const ft ge
         | None -> raise (Error (Printf.sprintf
             "'%s' is not a compile-time constant (must reference an earlier \
              immutable global with a constant initializer)" name)))
    | _ -> raise (Error "global initializer: unsupported constant expression")
  in
  let init = match expr_opt with
    | Some e -> eval_const ast_ty e
    | None   -> undef llty  (* no initializer -> LLVM undef; startup.S zeroes BSS *)
  in
  if (not is_mutable) then
    (match expr_opt with
     | Some e -> Hashtbl.add global_const_defs name (ast_ty, e)
     | None -> ());
  let gvar = define_global name init the_module in
  let eff_align = match align_opt with
    | Some _ -> align_opt
    | None   -> (match ast_ty with
                 | TypeNamed sname -> Hashtbl.find_opt struct_alignments sname
                 | TypeArray (TypeNamed sname, _) -> Hashtbl.find_opt struct_alignments sname
                 | _ -> None)
  in
  (match eff_align with Some n -> set_alignment n gvar | None -> ());
  if not is_mutable then set_global_constant true gvar;
  attach_global_debug name ast_ty decl_loc gvar;
  Hashtbl.add global_vars name (ast_ty, gvar)

let declare_func ?prog_types fdef =
  let key = function_key prog_types fdef in
  if not (Hashtbl.mem functions key) then begin
    let res name ty_opt = resolve_local_ast prog_types key name ty_opt in
    let param_ast = List.map (fun (n, annotation) ->
      let resolved = res n annotation in
      match annotation with
      | Some (TypeBorrowMut _) -> TypeBorrowMut resolved
      | _ -> resolved
    ) fdef.params in
    let param_lls = param_ast
      |> List.filter (fun t -> not (is_erased_view_type t))
      |> List.map ltype_of_ast |> Array.of_list in
    let ret_ast   = resolve_ret_ast prog_types key fdef.ret_type in
    let ret_ll    = ltype_of_ret_ast ret_ast in
    let ft        = function_type ret_ll param_lls in
    let f         = declare_function key ft the_module in
    if fdef.is_inline then
      add_function_attr f (create_enum_attr context "alwaysinline" 0L) AttrIndex.Function;
    Hashtbl.add functions key (ft, f);
    Hashtbl.add func_ret_ast_types key ret_ast;
    Hashtbl.add func_param_ast_types key param_ast
  end

let gen_program ?prog_types prog =
  current_program_types := prog_types;
  trap_sites := [];  (* fresh per compilation (and per unit test) *)
  unsafe_depth := 0;
  Hashtbl.reset erased_view_names;
  Hashtbl.reset variant_defs;
  Hashtbl.reset variant_lltypes;
  Hashtbl.reset variant_cases_tbl;
  List.iter (function
    | ViewDef (name, _, _, _, _) -> Hashtbl.replace erased_view_names name ()
    | VariantDef (name, cases, _) -> Hashtbl.replace variant_defs name cases
    | _ -> ()) prog;
  (* Pass 0a: enums and opaque structs do not depend on aggregate layout. *)
  List.iter (function
    | OpaqueStructDef (name, _, _, _) ->
        Hashtbl.add struct_lltypes name (named_struct_type context name)
    | EnumDef (name, ty_opt, variants, is_ne) ->
        let underlying = match ty_opt with Some t -> t | None -> TypeU32 in
        let (_, resolved) = List.fold_left (fun (next, acc) (vname, vopt) ->
          let v = match vopt with Some v -> v | None -> next in
          (v + 1, acc @ [(vname, v)])
        ) (0, []) variants in
        Hashtbl.add enum_underlying    name underlying;
        Hashtbl.add enum_variants_tbl  name resolved;
        Hashtbl.add enum_nonexhaustive name is_ne
    | _ -> ()
  ) prog;
  let rec ast_mentions_variant = function
    | TypeVariant _ -> true
    | TypeNamed name -> Hashtbl.mem variant_defs name
    | TypePtr t | TypeIo t | TypeArray (t, _) | TypeSlice (t, _)
    | TypeBorrow t | TypeBorrowMut t | TypeSink t
    | TypeRefined (_, _, t) | TypeAlignedPtr (_, t)
    | TypeSingleton (t, _) -> ast_mentions_variant t
    | TypeFn (args, ret, _) ->
        List.exists ast_mentions_variant args || ast_mentions_variant ret
    | TypeTuple ts -> List.exists ast_mentions_variant ts
    | TypeExists (_, _, body) -> ast_mentions_variant body
    | _ -> false
  in
  let register_struct name fields is_packed align_opt =
    let field_lltys = List.map (fun (_, ty) -> ltype_of_ast ty) fields
                      |> Array.of_list in
    let mk_struct fltys = if is_packed then packed_struct_type context fltys
                          else struct_type context fltys in
    let llty = mk_struct field_lltys in
    (* Tail-pad the struct so sizeof(struct) is a multiple of align(N). *)
    let llty = match align_opt with
      | None -> llty
      | Some n ->
          (match !target_data with
           | None -> llty
           | Some dl ->
               let sz = Int64.to_int (Llvm_target.DataLayout.abi_size llty dl) in
               let pad = (n - (sz mod n)) mod n in
               if pad = 0 then llty
               else mk_struct (Array.append field_lltys
                     [| array_type (i8_type context) pad |]))
    in
    Hashtbl.add struct_lltypes name llty;
    Hashtbl.add struct_fields name fields;
    Hashtbl.add struct_is_packed name is_packed;
    Option.iter (fun n -> Hashtbl.add struct_alignments name n) align_opt
  in
  let register_struct_if has_variant = function
    | StructDef (name, fields, is_packed, align_opt, _, _)
    | OwnedStructDef (name, _, _, fields, is_packed, align_opt, _, _, _)
      when List.exists (fun (_, ty) -> ast_mentions_variant ty) fields
           = has_variant ->
        register_struct name fields is_packed align_opt
    | _ -> ()
  in
  (* Variants may carry ordinary structs by value, so those layouts come first. *)
  List.iter (register_struct_if false) prog;
  (* A Slice 3 variant is a compact tagged aggregate in the semantic sense,
     but deliberately uses one LLVM field per runtime-bearing case for now:
     `{ i32 tag, payload0, payload1, ... }`.  This is target-independent,
     keeps every payload strongly typed, and avoids inventing an untyped byte
     union before Takibi has a settled ABI.  Erased view payloads and
     existential binders add no field; the existential body still does. *)
  List.iter (function
    | VariantDef (name, cases, _) ->
        let next_field = ref 1 in
        let runtime_fields = ref [] in
        let layouts = List.mapi (fun tag (cname, payload) ->
          let payload_field = match payload with
            | None -> None
            | Some schema ->
                let runtime_ty = runtime_payload_type schema in
                if is_erased_view_type runtime_ty then None
                else begin
                  let field = !next_field in
                  incr next_field;
                  runtime_fields := !runtime_fields @ [ltype_of_ast runtime_ty];
                  Some field
                end
          in
          (cname, {
            variant_tag = tag;
            variant_payload = payload;
            variant_payload_field = payload_field;
          })
        ) cases in
        let fields = i32_type context :: !runtime_fields |> Array.of_list in
        Hashtbl.replace variant_lltypes name (struct_type context fields);
        Hashtbl.replace variant_cases_tbl name layouts
    | _ -> ()) prog;
  (* Plain variants may in turn be held in ordinary struct storage. *)
  List.iter (register_struct_if true) prog;
  (* Pass 1: register all globals and function signatures *)
  List.iter (function
    | FuncDef fdef                    -> declare_func ?prog_types fdef
    | ConstDef (name, ty, expr, loc) ->
        gen_global ?prog_types name (Some ty) (Some expr) None false loc
    | LetDef (name, ty_opt, expr_opt, align_opt, is_mutable, _, loc) ->
        gen_global ?prog_types name ty_opt expr_opt align_opt is_mutable loc
    | ExternFuncDef (name, params, ret_ty, _) ->
        if not (Hashtbl.mem functions name) then begin
          let param_ast = List.map (fun (_, t) ->
            resolve_special_type
              (match t with Some t -> t | None -> TypeI32)) params in
          let param_lls = param_ast
            |> List.filter (fun t -> not (is_erased_view_type t))
            |> List.map ltype_of_ast |> Array.of_list in
          let ret_ast = resolve_special_type
            (match ret_ty with Some t -> t | None -> TypeVoid) in
          let ret_ll    = ltype_of_ret_ast ret_ast in
          let ft        = function_type ret_ll param_lls in
          let f         = declare_function name ft the_module in
          Hashtbl.add functions name (ft, f);
          Hashtbl.add func_ret_ast_types name ret_ast;
          Hashtbl.add func_param_ast_types name param_ast
        end
    | StructDef _ -> ()
    | OwnedStructDef _ -> ()
    | OpaqueStructDef _ -> ()
    | ViewDef _ -> ()
    | EnumDef _   -> ()
    | VariantDef _ -> ()
    | UseDef _    -> ()
  ) prog;
  let function_keys =
    prog
    |> List.filter_map (function
      | FuncDef fdef -> Some (function_key prog_types fdef)
      | _ -> None)
  in
  init_function_profile_table function_keys;
  (* Pass 2: generate function bodies *)
  List.iter (function
    | FuncDef fdef    -> ignore (gen_func ?prog_types fdef)
    | ConstDef _      -> ()
    | LetDef _        -> ()
    | ExternFuncDef _ -> ()
    | StructDef _     -> ()
    | OwnedStructDef _ -> ()
    | OpaqueStructDef _ -> ()
    | ViewDef _ -> ()
    | EnumDef _       -> ()
    | VariantDef _    -> ()
    | UseDef _        -> ()
  ) prog;
  (* Resolve any deferred/forward-referenced DI metadata. Must run after every
     gen_func call above, before the module is optimized or emitted to an object. *)
  (match !dibuilder_opt with
   | Some dib -> Llvm_debuginfo.dibuild_finalize dib
   | None -> ())
