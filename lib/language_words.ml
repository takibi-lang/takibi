module StringSet = Set.Make (String)

(* The authoritative inventory of source words with compiler-owned meaning.
   Keep the categories source-facing: lexer keywords create grammar boundaries,
   builtins look like calls but have compiler-defined typing/lowering, and
   predeclared names enter an otherwise ordinary identifier namespace. *)
let hard_keywords = [
  "fn"; "inline"; "noinline"; "return"; "const"; "let"; "mut";
  "if"; "else"; "while"; "for"; "in"; "break"; "continue"; "as";
  "void"; "extern"; "symbol"; "vector_table"; "exception_entry";
  "exception_restore"; "embed_file"; "struct"; "opaque"; "affine";
  "linear"; "view"; "variant"; "must_use"; "exists"; "borrow";
  "sink"; "private"; "packed"; "be"; "io"; "enum"; "match";
  "align"; "sizeof"; "alignof"; "contains_stable_owner"; "use";
  "offsetof"; "static_assert"; "type"; "generic"; "bool"; "unsafe";
  "true"; "false"; "i8"; "i16"; "i32"; "i64"; "u8"; "u16";
  "u32"; "u64"; "u16be"; "u32be"; "isize"; "usize";
]

(* No word is contextual today: ocamllex has no parser-position feedback, and
   changing modifier spellings is not needed by a current program.  New words
   must be put here only when the parser actually accepts them as identifiers
   outside their special positions. *)
let contextual_keywords = []

let compiler_builtins = [
  "slice_copy"; "slice_eq"; "stable_replace"; "min"; "max";
  "i32_min"; "i32_max";
  "wrapping_mul_u32";
  "dma_publish"; "dma_consume"; "device_fence"; "signal_fence";
  "interrupt_wait"; "interrupt_notify";
  "dma_prepare_tx"; "dma_prepare_rx"; "dma_finish_rx";
  "checked_add_usize"; "checked_mul_usize";
  "mrs_cntfrq_el0"; "mrs_cntpct_el0"; "mrs_sctlr_el1";
  "mrs_esr_el1"; "mrs_far_el1"; "mrs_elr_el1"; "mrs_spsr_el1";
  "mrs_id_aa64mmfr0_el1";
  "msr_cntp_tval_el0"; "msr_cntp_ctl_el0"; "msr_sctlr_el1";
  "msr_mair_el1"; "msr_tcr_el1"; "msr_ttbr0_el1";
  "msr_daifclr_irq"; "msr_daifset_irq"; "mrs_daif";
  "tlbi_vmalle1"; "tlbi_vaae1is"; "tlbi_vae1is"; "tlbi_aside1is";
  "dsb_ish"; "dsb_ishst"; "isb"; "smc4"; "hvc4"; "svc5";
]

let predeclared_names = ["DMA_CACHE_LINE"]
let checker_intrinsics = ["addr"]

let hard_keyword_set = StringSet.of_list hard_keywords
let contextual_keyword_set = StringSet.of_list contextual_keywords
let compiler_builtin_set = StringSet.of_list compiler_builtins
let predeclared_name_set = StringSet.of_list predeclared_names
let checker_intrinsic_set = StringSet.of_list checker_intrinsics

let is_hard_keyword name = StringSet.mem name hard_keyword_set
let is_contextual_keyword name = StringSet.mem name contextual_keyword_set
let is_compiler_builtin name = StringSet.mem name compiler_builtin_set
let is_predeclared_name name = StringSet.mem name predeclared_name_set
let is_checker_intrinsic name = StringSet.mem name checker_intrinsic_set

let builtin_namespace = "builtin"
