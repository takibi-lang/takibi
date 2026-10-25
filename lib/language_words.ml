module StringSet = Set.Make (String)

(* The authoritative inventory of source words with compiler-owned meaning.
   Keep the categories source-facing: lexer keywords create grammar boundaries,
   builtins look like calls but have compiler-defined typing/lowering, and
   predeclared names enter an otherwise ordinary identifier namespace. *)
(* GitHub issue #1003: each hard keyword carries its class as data, so
   WORDS.md (takibi --emit-doc words) states it without a hand-kept comment.
   Kernel_qualifier marks the words the maintained kernel's needs brought in. *)
type keyword_class =
  | Core
  | Ownership
  | Layout
  | Kernel_qualifier
  | Codegen_declaration

let keyword_class_name = function
  | Core -> "core"
  | Ownership -> "ownership / permission"
  | Layout -> "layout"
  | Kernel_qualifier -> "kernel-driven qualifier"
  | Codegen_declaration -> "codegen declaration"

let classified_hard_keywords = [
  "fn", Core;
  "inline", Codegen_declaration;
  "noinline", Codegen_declaration;
  "where", Core;
  "requires", Core;
  "ensures", Core;
  "return", Core;
  "const", Core;
  "let", Core;
  "mut", Core;
  "if", Core;
  "else", Core;
  "while", Core;
  "for", Core;
  "in", Core;
  "break", Core;
  "continue", Core;
  "as", Core;
  "void", Core;
  "extern", Core;
  "symbol", Codegen_declaration;
  "vector_table", Codegen_declaration;
  "exception_entry", Codegen_declaration;
  "exception_restore", Codegen_declaration;
  "embed_file", Codegen_declaration;
  "struct", Core;
  "opaque", Core;
  "affine", Ownership;
  "linear", Ownership;
  "view", Ownership;
  "variant", Core;
  "must_use", Ownership;
  "exists", Core;
  "borrow", Ownership;
  "sink", Ownership;
  "private", Core;
  "packed", Layout;
  "be", Layout;
  "publish", Kernel_qualifier;
  "no_copy", Ownership;
  "dma_fixed", Kernel_qualifier;
  "per_cpu", Kernel_qualifier;
  "cpu_authority", Kernel_qualifier;
  "preempt_off", Kernel_qualifier;
  "guarded_by", Kernel_qualifier;
  "io", Kernel_qualifier;
  "enum", Core;
  "match", Core;
  "align", Layout;
  "multiple", Layout;
  "sizeof", Core;
  "alignof", Core;
  "contains_stable_owner", Ownership;
  "use", Core;
  "offsetof", Core;
  "static_assert", Core;
  "type", Core;
  "generic", Core;
  "bool", Core;
  "unsafe", Core;
  "true", Core;
  "false", Core;
  "i8", Core;
  "i16", Core;
  "i32", Core;
  "i64", Core;
  "u8", Core;
  "u16", Core;
  "u32", Core;
  "u64", Core;
  "u16be", Layout;
  "u32be", Layout;
  "isize", Core;
  "usize", Core;
]

let hard_keywords = List.map fst classified_hard_keywords

(* GitHub issue #720: `protocol` introduces a protocol item only at the
   start of a top-level item, where no other production accepts an
   identifier; everywhere else it is an ordinary identifier. The words inside
   a protocol body (state, init, transition, observe, ...) are deliberately
   not listed: they are plain identifiers there too, checked by
   Protocol_decl, and listing them would make an unrelated syntax error next
   to a variable named `state` report a contextual keyword. *)
let contextual_keywords = ["protocol"]

let compiler_builtins = [
  "slice_copy"; "slice_eq"; "zero_fill"; "assume_init"; "place_take"; "place_put"; "place_borrow"; "place_is_full"; "min"; "max";
  "i32_min";
  "wrapping_mul_u32";
  "dma_publish"; "dma_consume"; "signal_fence";
  "interrupt_wait"; "interrupt_notify";
  "dma_prepare_tx"; "dma_prepare_rx"; "dma_finish_rx";
  "dma_cpu_slice"; "dma_begin_rx"; "dma_finish_owned_rx";
  "dma_begin_tx"; "dma_finish_owned_tx";
  "dma_device_span"; "dma_span_address"; "dma_span_length";
  "checked_add_usize"; "checked_mul_usize";
  "mrs_cntfrq_el0"; "mrs_cntpct_el0"; "mrs_sctlr_el1";
  "mrs_esr_el1"; "mrs_far_el1"; "mrs_elr_el1"; "mrs_spsr_el1";
  "mrs_id_aa64mmfr0_el1"; "mrs_mpidr_el1";
  "msr_cntp_tval_el0"; "msr_cntp_ctl_el0"; "msr_sctlr_el1";
  "msr_mair_el1"; "msr_tcr_el1"; "msr_ttbr0_el1";
  "msr_daifclr_irq"; "msr_daifset_irq"; "mrs_daif";
  "tlbi_vmalle1"; "tlbi_vmalle1is";
  "tlbi_vae1is"; "tlbi_aside1is";
  "dsb_ish"; "dsb_ishst"; "isb"; "wfi"; "smc4"; "hvc4"; "svc5";
  (* GitHub issue #17/#467: the closed atomic set comes from Atomic_spec,
     the same source used by typing, effect inference, and code generation.
     It is reserved for the same reason as every builtin above -- infer_expr
     dispatches on the name before it consults fenv, so a user function of
     the same name would be silently unreachable. *)
] @ Atomic_spec.names @ List.map fst Atomic_spec.cell_ops @ [
  (* GitHub issue #299: the publication record's four operations. Reserved
     for the same reason -- and additionally because a user function named
     publish_commit that did NOT commit would be the most misleading name
     available in this language. *)
  "publish_begin"; "publish_commit"; "publish_abandon"; "publish_copy";
  (* GitHub issue #131: the two place operations of a stored linear field. *)
  "field_take"; "field_put";
]

(* GitHub issue #1003: the builtins that each lower to one named machine
   instruction (or a fixed short sequence), marked in WORDS.md until #1005's
   instruction table owns them. *)
let instruction_builtins = List.filter (fun name ->
    List.exists (fun prefix -> String.starts_with ~prefix name)
      ["mrs_"; "msr_"; "tlbi_"; "dsb_"]
    || List.mem name ["isb"; "wfi"; "smc4"; "hvc4"; "svc5"])
  compiler_builtins

(* GitHub issue #1004: words removed from the language. A use gets a
   targeted diagnostic (type_inf.ml) and the name stays reserved, but it is
   not a builtin: `builtin::stable_replace` is an unknown builtin. *)
let removed_words = ["stable_replace"]

(* GitHub issue #1004: builtins only a device protocol's generated code
   calls (Device_protocol_registry.builtins; a test keeps the two lists
   equal). They are not public: `builtin::` does not name them, a call from
   user source is an unresolved identifier, and the names stay reserved so
   a user function cannot shadow them. *)
let generator_builtins = [
  "__protocol_dma_clean"; "__protocol_dma_prepare_rx";
  "__protocol_dma_finish_rx"; "__protocol_dma_span";
  "__protocol_dma_own_lines"; "__protocol_dma_refresh_at";
]

(* GitHub issue #1003: type and function names the compiler supplies from
   its own templates rather than from a library, with the module that owns
   each. Kept by hand: the region templates build these names from
   placeholders, so there is no registry to list them from. *)
let compiler_owned_types = [
  "Place(T)", "generic_variant.ml";
  "region(T)[b, n]", "region_builtin.ml";
  "places(P)", "region_builtin.ml";
  "slots(P)", "region_builtin.ml";
  "SlotsCell", "region_builtin.ml";
  "RegionOf", "region_builtin.ml";
  "RegionTable", "region_builtin.ml";
  "RegionTyped", "region_builtin.ml";
  "RegionPool", "region_builtin.ml";
  "RegionPoolAlloc", "region_builtin.ml";
  "RegionBytes", "region_builtin.ml";
  "IoHandle(T)", "region_builtin.ml";
]

let compiler_owned_functions = [
  "region_of", "region_builtin.ml";
  "region_table_of", "region_builtin.ml";
  "region_table_lock", "region_builtin.ml";
  "region_bytes_assume", "region_builtin.ml";
]

(* GitHub issue #1003: declaration qualifiers -- the forms that make a
   declaration compiler-tracked -- with the module that records each.
   `scratch` and `region` before `let` are plain identifiers the parser
   accepts only there (lib/parser.mly), so they are listed here and not as
   keywords. *)
let declaration_qualifiers = [
  "struct publish", "publish_registry.ml";
  "struct no_copy", "no_copy_registry.ml";
  "struct per_cpu", "per_cpu_registry.ml";
  "struct cpu_authority", "per_cpu_registry.ml";
  "struct dma_fixed", "dma_fixed_registry.ml";
  "struct packed, struct packed be", "type_layout.ml";
  "io struct", "io_struct_registry.ml";
  "private f: T guarded_by(lock)", "guarded_registry.ml";
  "scratch let mut", "init_state.ml";
  "region let mut", "region_backing.ml";
  "protocol", "protocol_decl.ml, device_protocol_registry.ml";
]

let predeclared_names = ["DMA_CACHE_LINE"]
let checker_intrinsics = ["addr"; "self"]

let hard_keyword_set = StringSet.of_list hard_keywords
let contextual_keyword_set = StringSet.of_list contextual_keywords
let compiler_builtin_set = StringSet.of_list compiler_builtins
let predeclared_name_set = StringSet.of_list predeclared_names
let checker_intrinsic_set = StringSet.of_list checker_intrinsics

let is_hard_keyword name = StringSet.mem name hard_keyword_set
let is_contextual_keyword name = StringSet.mem name contextual_keyword_set
let is_compiler_builtin name = StringSet.mem name compiler_builtin_set
let is_generator_builtin name = List.mem name generator_builtins
(* A name no user function may define: infer_expr dispatches on these
   before it consults fenv. *)
let is_reserved_function_name name =
  is_compiler_builtin name || is_generator_builtin name
  || List.mem name removed_words
let is_predeclared_name name = StringSet.mem name predeclared_name_set
let is_checker_intrinsic name = StringSet.mem name checker_intrinsic_set

let builtin_namespace = "builtin"
