(* GitHub issue #1005: the one table of instruction builtins, in
   Atomic_spec's shape. Each row is a builtin that lowers to one named
   machine instruction at the call site (inline asm, never a call), and
   everything the compiler knows about it is written here: the name the
   language reserves (Language_words), the arguments and result its type
   rule checks (Type_inf), the inline asm and constraints its lowering
   emits (Llvm_gen), and the checker rules that read it by role rather
   than by a name spelled elsewhere (the IRQ flow rule, #809; the raw
   authority sites, Raw_authority_policy). Adding an instruction is one
   row.

   Every operand is a usize; a builtin never lets a runtime value choose
   which register or instruction it names (#226). *)

(* What the call looks like to the type rule and to the emitter. *)
type shape =
  | Read          (* f() -> usize: `mrs $0, <reg>`, result through "=r" *)
  | Bare          (* f() -> void *)
  | Write1        (* f(v) -> void: the value through one "r" input *)
  | Trap4         (* f(x0, x1, x2, x3) -> usize, fixed registers (SMCCC) *)
  | Trap6         (* f(nr, x0, ..., x4) -> usize, fixed registers (Linux) *)

(* The checker rules that recognize a row. *)
type role =
  | Plain
  | Irq_unmask    (* msr DAIFClr: the IRQ flow rule's restore (#351, #809) *)
  | Irq_mask      (* msr DAIFSet: its mask *)
  | Irq_save      (* mrs DAIF: the saved mask a restore puts back *)

type t = {
  name : string;
  shape : shape;
  asm : string;                 (* AArch64 *)
  (* GitHub issue #1035: the host lowering, for the rows a host-native
     build of kernel code needs (linux_user/ext2_host). None: AArch64 only. *)
  asm_x86_64 : string option;
  constraints : string;
  role : role;
  (* Raw_authority_policy: the instruction can change what an address
     means (translation registers, TLB maintenance by VA or ASID). *)
  raw_site : bool;
}

let read name reg =
  { name; shape = Read; asm = "mrs $0, " ^ reg; asm_x86_64 = None;
    constraints = "=r,~{memory}"; role = Plain; raw_site = false }
let bare name asm =
  { name; shape = Bare; asm; asm_x86_64 = None; constraints = "~{memory}";
    role = Plain; raw_site = false }
let write1 name asm =
  { name; shape = Write1; asm; asm_x86_64 = None;
    constraints = "r,~{memory}"; role = Plain; raw_site = false }

let all = [
  (* GitHub issue #226/#227: system-register reads. *)
  read "mrs_cntfrq_el0" "cntfrq_el0";
  read "mrs_cntpct_el0" "cntpct_el0";
  read "mrs_sctlr_el1" "sctlr_el1";
  read "mrs_esr_el1" "esr_el1";
  read "mrs_far_el1" "far_el1";
  read "mrs_elr_el1" "elr_el1";
  read "mrs_spsr_el1" "spsr_el1";
  (* GitHub issue #402: ID_AA64MMFR0_EL1.ASIDBits, the ASID width this
     implementation has rather than the 8-bit floor. *)
  read "mrs_id_aa64mmfr0_el1" "id_aa64mmfr0_el1";
  (* GitHub issue #445: which core is asking. WHICH affinity field is
     per-platform and belongs in kernel/platform/*/init.tkb's cpu_id(). *)
  read "mrs_mpidr_el1" "mpidr_el1";
  (* GitHub issue #351: reading the mask is what lets a lock restore it. *)
  { (read "mrs_daif" "daif") with role = Irq_save };
  (* GitHub issue #226: system-register writes and TLB maintenance taking
     the one value the instruction's Xt operand carries. *)
  write1 "msr_cntp_tval_el0" "msr cntp_tval_el0, $0";
  write1 "msr_cntp_ctl_el0" "msr cntp_ctl_el0, $0";
  { (write1 "msr_sctlr_el1" "msr sctlr_el1, $0") with raw_site = true };
  { (write1 "msr_mair_el1" "msr mair_el1, $0") with raw_site = true };
  { (write1 "msr_tcr_el1" "msr tcr_el1, $0") with raw_site = true };
  { (write1 "msr_ttbr0_el1" "msr ttbr0_el1, $0") with raw_site = true };
  { (write1 "tlbi_vae1is" "tlbi vae1is, $0") with raw_site = true };
  { (write1 "tlbi_aside1is" "tlbi aside1is, $0") with raw_site = true };
  (* GitHub issue #226: zero-argument barriers, TLBI and DAIF immediates. *)
  { (bare "msr_daifclr_irq" "msr DAIFClr, #0x2") with role = Irq_unmask };
  { (bare "msr_daifset_irq" "msr DAIFSet, #0x2") with role = Irq_mask };
  bare "tlbi_vmalle1" "tlbi vmalle1";
  (* GitHub issue #446: the Inner Shareable sibling. *)
  bare "tlbi_vmalle1is" "tlbi vmalle1is";
  (* GitHub issue #1035: the data barriers also lower on x86-64, where
     kernel/fs/ext2/mutation_lock.tkb runs host-natively; `mfence` is the
     store-load ordering the lock's Dekker half needs. *)
  { (bare "dsb_ish" "dsb ish") with asm_x86_64 = Some "mfence" };
  { (bare "dsb_ishst" "dsb ishst") with asm_x86_64 = Some "mfence" };
  bare "isb" "isb";
  (* GitHub issue #447: NOT interrupt_wait()'s `wfe`. A core that only
     wants its own interrupt has to say so: every timer tick executes SEV. *)
  bare "wfi" "wfi";
  (* GitHub issue #226 and #237: the raw SMCCC conduits, x0-x3 in and x0
     out. RPi5's firmware takes SMC; QEMU `virt` reports "hvc". *)
  { name = "smc4"; shape = Trap4; asm = "smc #0"; asm_x86_64 = None;
    constraints = "={x0},{x0},{x1},{x2},{x3},~{memory}"; role = Plain;
    raw_site = false };
  { name = "hvc4"; shape = Trap4; asm = "hvc #0"; asm_x86_64 = None;
    constraints = "={x0},{x0},{x1},{x2},{x3},~{memory}"; role = Plain;
    raw_site = false };
  (* GitHub issue #228: the Linux/AArch64 syscall trap, x8 = number, x0-x4
     arguments, x0 result (x0 named twice: the ABI reuses it). *)
  { name = "svc5"; shape = Trap6; asm = "svc #0"; asm_x86_64 = None;
    constraints = "={x0},{x8},{x0},{x1},{x2},{x3},{x4},~{memory}";
    role = Plain; raw_site = false };
]

module StringMap = Map.Make (String)

let by_name = List.fold_left (fun specs spec ->
  StringMap.add spec.name spec specs
) StringMap.empty all

let find name = StringMap.find_opt name by_name
let is_instruction name = Option.is_some (find name)
let names = List.map (fun spec -> spec.name) all

let arity = function
  | Read | Bare -> 0
  | Write1 -> 1
  | Trap4 -> 4
  | Trap6 -> 6

let returns_value = function
  | Read | Trap4 | Trap6 -> true
  | Bare | Write1 -> false

(* The type rule's message for a call with the wrong number of arguments. *)
let arity_message spec =
  let f = spec.name in
  match spec.shape with
  | Read | Bare -> Printf.sprintf "%s expects no arguments: %s()" f f
  | Write1 -> Printf.sprintf "%s expects one argument: %s(v)" f f
  | Trap4 -> Printf.sprintf "%s expects four arguments: %s(x0, x1, x2, x3)" f f
  | Trap6 ->
      Printf.sprintf "%s expects six arguments: %s(nr, x0, x1, x2, x3, x4)" f f

(* The asm for a target triple, or the reason the row has none there. *)
let asm_for_triple spec triple =
  let starts prefix =
    String.length triple >= String.length prefix
    && String.sub triple 0 (String.length prefix) = prefix in
  if starts "aarch64" then Ok spec.asm
  else if starts "x86_64" then
    (match spec.asm_x86_64 with
     | Some asm -> Ok asm
     | None -> Error (Printf.sprintf
         "%s is an AArch64 instruction (%s) with no lowering for target '%s'"
         spec.name spec.asm triple))
  else Error (Printf.sprintf
      "%s is an AArch64 instruction (%s) with no lowering for target '%s'"
      spec.name spec.asm triple)

let names_with_role role =
  List.filter_map (fun spec ->
    if spec.role = role then Some spec.name else None) all

let name_with_role role =
  match names_with_role role with
  | [name] -> name
  | _ -> invalid_arg "Instr_spec.name_with_role: not exactly one row"

let raw_site_names =
  List.filter_map (fun spec ->
    if spec.raw_site then Some spec.name else None) all

(* The IRQ flow rule's three names (#351, #809), read by role. *)
let irq_unmask = name_with_role Irq_unmask
let irq_mask = name_with_role Irq_mask
let irq_save = name_with_role Irq_save
