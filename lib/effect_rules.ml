type declaration = Inferred | Required | Local_required | Trusted_extern

type rule = {
  name : string;
  declaration : declaration;
  declaration_role : bool;
  function_pointer : bool;
  propagates : bool;
  effect_free_forbidden : bool;
  excludes_declared : string list;
  excludes_reachable : string list;
  rejects_unknown_indirect : bool;
  forbids_reentry : bool;
}

type lock_annotation = {
  rank : int;
  label : string;
}

let parse_lock_annotation prefix name =
  let prefix_len = String.length prefix in
  if String.length name <= prefix_len
     || String.sub name 0 prefix_len <> prefix then None
  else
    let rest = String.sub name prefix_len (String.length name - prefix_len) in
    match String.index_opt rest '_' with
    | None -> None
    | Some separator ->
        let rank_text = String.sub rest 0 separator in
        let label = String.sub rest (separator + 1)
          (String.length rest - separator - 1) in
        (match int_of_string_opt rank_text with
         | Some rank when rank >= 0 && label <> "" -> Some { rank; label }
         | _ -> None)

let lock_acquire_annotation =
  parse_lock_annotation "acquires_lock_"

let lock_guard_annotation =
  parse_lock_annotation "lock_guard_"

(* GitHub issue #528: the two checker-only words of the IRQ-restoration rule.
   `irq_masking_guard` marks a function returning a linear guard whose
   acquire saved and masked the interrupt state; `restores_saved_irq` marks
   a function that restores exactly a state its caller saved, which is the
   trusted boundary the rule stops at. Like the lock annotations, neither
   appears in a function-pointer row. *)
let irq_masking_guard_annotation = "irq_masking_guard"

(* GitHub issue #694: an acquisition function whose lock class has exactly
   one instance. Re-acquiring such a class while its guard is live is a
   self-deadlock, so the equal-rank exemption does not apply to it. *)
let single_instance_lock_annotation = "single_instance_lock"
let restores_saved_irq_annotation = "restores_saved_irq"

(* GitHub issue #920: the IRQ mask need not be DAIF.I. With a GICv2
   priority-mask pseudo-NMI the kernel masks ordinary interrupts by writing
   GICC_PMR, an MMIO store the #528/#809 checks cannot recognise as a mask.
   `masks_irq` marks the function that performs that store: every call to it
   is read as msr_daifset_irq is, and its body is trusted rather than
   summarised (it may clear DAIF.I as part of handing the mask to PMR, which
   is not an unmask). Checker-only, like the two words above. *)
let masks_irq_annotation = "masks_irq"

(* GitHub issue #920 (maintainer decision 2): the debug/crash stop escalates
   to the pseudo-NMI, so it can hold a core that owns any lock. The function
   that begins it declares `starts_debug_stop`; every caller of such a
   function must be a `debug_stopped` root (below). Checker-only. *)
let starts_debug_stop_annotation = "starts_debug_stop"

(* GitHub issue #493: the two checker-only words of effect-indexed
   invalidation. `invalidates_<Type>` marks a function after which a
   plain handle of struct type <Type> may name a destroyed object; the
   checker propagates it to every caller. `handle_of_witness` marks the
   trusted accessor that returns the handle of the object its one
   borrowed linear argument proves alive. *)
let invalidation_prefix = "invalidates_"

let invalidation_annotation name =
  let prefix_len = String.length invalidation_prefix in
  if String.length name > prefix_len
     && String.sub name 0 prefix_len = invalidation_prefix
  then Some (String.sub name prefix_len (String.length name - prefix_len))
  else None

let handle_of_witness_annotation = "handle_of_witness"

(* Checker-only destructive boundary, keyed by an indexed authority kind. *)
let record_mutation_annotation name =
  let prefix = "record_mutates_" in
  if String.starts_with ~prefix name && String.length name > String.length prefix
  then Some (String.sub name (String.length prefix)
      (String.length name - String.length prefix))
  else None

(* A logical-context replacement cannot overlap its linear witness kind. *)
let witness_change_annotation name =
  let prefix = "changes_witness_" in
  if String.starts_with ~prefix name && String.length name > String.length prefix
  then Some (String.sub name (String.length prefix)
      (String.length name - String.length prefix))
  else None

(* A private, checked source-loan to destination-authority return boundary. *)
let loan_transfer_annotation = "loan_transfer"

(* GitHub issue #850: the checker-only words, one row each. `dynamic_rule`
   accepts exactly the words this table matches, and `markdown` prints it
   into EFFECTS.md, so a new word changes that tracked contract document
   (DECISIONS.md 2026-10-24: no new such word). *)
type checker_word = {
  pattern : string;
  matches : string -> bool;
  marks : string;
  read_by : string;
  replaced_by : string;
}

let exact word name = String.equal name word
let some f name = f name <> None

let checker_words = [
  { pattern = "acquires_lock_<rank>_<name>";
    matches = some lock_acquire_annotation;
    marks = "a function that acquires the ranked lock class <name>";
    read_by = "lock rank order";
    replaced_by = "ranked lock token (#789)" };
  { pattern = "lock_guard_<rank>_<name>";
    matches = some lock_guard_annotation;
    marks = "a function returning the linear guard of lock class <name>";
    read_by = "lock rank order";
    replaced_by = "ranked lock token (#789)" };
  { pattern = "single_instance_lock";
    matches = exact single_instance_lock_annotation;
    marks = "an acquisition whose lock class has one instance";
    read_by = "lock rank order, equal-rank self-deadlock (#694)";
    replaced_by = "ranked lock token (#789)" };
  { pattern = "irq_masking_guard";
    matches = exact irq_masking_guard_annotation;
    marks = "a function returning a guard that saved and masked IRQs";
    read_by = "IRQ restoration (#528)";
    replaced_by = "IrqState token (#638, #850)" };
  { pattern = "restores_saved_irq";
    matches = exact restores_saved_irq_annotation;
    marks = "the trusted restore of a state its caller saved";
    read_by = "IRQ restoration (#528)";
    replaced_by = "IrqState token (#638, #850)" };
  { pattern = "masks_irq";
    matches = exact masks_irq_annotation;
    marks = "a call read as msr_daifset_irq (GIC PMR mask); body trusted";
    read_by = "IRQ restoration and IRQ flow (#528, #809, #920)";
    replaced_by = "IrqState token (#638, #850)" };
  { pattern = "starts_debug_stop";
    matches = exact starts_debug_stop_annotation;
    marks = "the function that begins the debug/crash stop";
    read_by = "debug-stop callers must be debug_stopped roots (#920)";
    replaced_by = "IrqState token (#638, #850)" };
  { pattern = "invalidates_<Type>";
    matches = some invalidation_annotation;
    marks = "a call after which a plain <Type> handle may be destroyed";
    read_by = "effect-indexed invalidation (#493)";
    replaced_by = "witness and authority types (#850)" };
  { pattern = "handle_of_witness";
    matches = exact handle_of_witness_annotation;
    marks = "the trusted accessor from a live witness to its handle";
    read_by = "effect-indexed invalidation (#493)";
    replaced_by = "witness and authority types (#850)" };
  { pattern = "record_mutates_<Kind>";
    matches = some record_mutation_annotation;
    marks = "a destructive boundary keyed by an indexed authority kind";
    read_by = "record mutation";
    replaced_by = "witness and authority types (#850)" };
  { pattern = "changes_witness_<Kind>";
    matches = some witness_change_annotation;
    marks = "a logical-context replacement of linear witness kind <Kind>";
    read_by = "witness change";
    replaced_by = "witness and authority types (#850)" };
  { pattern = "loan_transfer";
    matches = exact loan_transfer_annotation;
    marks = "a checked source-loan to destination-authority return";
    read_by = "loan transfer";
    replaced_by = "witness and authority types (#850)" };
]

let dynamic_rule name =
  let checker_only = List.exists (fun w -> w.matches name) checker_words in
  if not checker_only then None else Some {
      name; declaration = Required; declaration_role = false;
      function_pointer = false; propagates = false;
      effect_free_forbidden = false; excludes_declared = [];
      excludes_reachable = []; rejects_unknown_indirect = false;
      forbids_reentry = false;
    }

let rules = [
  { name = "may_block"; declaration = Inferred; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = true;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "allocates"; declaration = Inferred; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = true;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "locks"; declaration = Inferred; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = true;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "logs"; declaration = Inferred; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = true;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "requires_mmu"; declaration = Inferred; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = false;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "unsafe"; declaration = Local_required; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = false;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "interrupt"; declaration = Required; declaration_role = true;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = ["may_block"; "allocates"; "logs"; "exception"; "mmu_off"];
    excludes_reachable = ["may_block"; "allocates"; "logs"; "requires_irq_unmasked"];
    rejects_unknown_indirect = true; forbids_reentry = false };
  (* GitHub issue #920: the handler of the pseudo-NMI -- the world-stop SGI,
     raised above the GIC priority mask so it reaches a core whose ordinary
     IRQs are masked, including one hung inside an IRQ handler. It can
     interrupt a holder of any lock on its own core, so it may take none:
     besides what an `interrupt` root may not reach, an `nmi` root may not
     reach `locks`. *)
  { name = "nmi"; declaration = Required; declaration_role = true;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = ["may_block"; "allocates"; "logs"; "locks"; "interrupt";
                         "exception"; "mmu_off"];
    excludes_reachable = ["locks"; "may_block"; "allocates"; "logs";
                          "requires_irq_unmasked"];
    rejects_unknown_indirect = true; forbids_reentry = false };
  (* GitHub issue #920 (maintainer decision 3): a function that begins the
     debug/crash stop. Once the machine is stopped that way a held core may
     own any lock, so the stopping side never waits on one: its reachable
     calls exclude `locks`, like an `nmi` root's -- Linux's lock-free panic
     path, made static. It combines with `interrupt` or `exception` (DDB and
     the crash path run in both). It may not return a linear value or a
     variant carrying one, so the stop token cannot leave the checked root. *)
  { name = "debug_stopped"; declaration = Required; declaration_role = true;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = ["may_block"; "allocates"; "locks"; "mmu_off"];
    excludes_reachable = ["locks"; "may_block"; "allocates";
                          "requires_irq_unmasked"];
    rejects_unknown_indirect = true; forbids_reentry = false };
  { name = "exception"; declaration = Required; declaration_role = true;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = ["may_block"; "allocates"; "logs"; "interrupt"; "mmu_off"];
    excludes_reachable = ["may_block"; "allocates"; "logs"; "requires_irq_unmasked"];
    rejects_unknown_indirect = true; forbids_reentry = true };
  { name = "mmu_off"; declaration = Required; declaration_role = true;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = ["interrupt"; "exception"; "requires_mmu"];
    excludes_reachable = ["requires_mmu"; "requires_devices"];
    rejects_unknown_indirect = true; forbids_reentry = false };
  (* GitHub issue #637 step A: a register reached through an IoHandle needs
     the device map built; boot code that runs before it says so and
     cannot reach one. *)
  { name = "requires_devices"; declaration = Inferred; declaration_role = false;
    function_pointer = true; propagates = true; effect_free_forbidden = false;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
  { name = "devices_unmapped"; declaration = Required; declaration_role = true;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = ["requires_devices"];
    excludes_reachable = ["requires_devices"];
    rejects_unknown_indirect = true; forbids_reentry = false };
  (* GitHub issue #809: a function that spins until another core takes an
     interrupt -- the world-stop back-off -- needs this core's IRQs
     unmasked, or two cores retrying with IRQs masked time each other out
     forever (WorldStopRetry.tla, variant maskedbackoff). Declared on the
     back-off itself and inferred for every caller. Rejected three ways:
     reachable from an `interrupt` or `exception` root (their
     excludes_reachable), called while an `irq_masking_guard` guard is live,
     and called after a bare msr_daifset_irq in the same flow (the last two
     in type_inf.ml). #850 reviews the effect set. *)
  { name = "requires_irq_unmasked"; declaration = Inferred;
    declaration_role = false; function_pointer = true; propagates = true;
    effect_free_forbidden = false; excludes_declared = [];
    excludes_reachable = []; rejects_unknown_indirect = false;
    forbids_reentry = false };
  { name = "noreturn"; declaration = Trusted_extern; declaration_role = false;
    function_pointer = false; propagates = false; effect_free_forbidden = false;
    excludes_declared = []; excludes_reachable = [];
    rejects_unknown_indirect = false; forbids_reentry = false };
]

let find name = match List.find_opt (fun rule -> rule.name = name) rules with
  | Some _ as rule -> rule
  | None -> dynamic_rule name
let names = List.map (fun rule -> rule.name) rules
let propagating = List.filter_map (fun rule ->
  if rule.propagates then Some rule.name else None) rules
let effect_free_forbidden = List.filter_map (fun rule ->
  if rule.effect_free_forbidden then Some rule.name else None) rules

let yes_no = function true -> "yes" | false -> "no"
let declaration_text = function
  | Inferred -> "inferred"
  | Required -> "explicit"
  | Local_required -> "local explicit + inferred"
  | Trusted_extern -> "trusted extern only"
let list_text = function [] -> "-" | xs -> String.concat ", " xs

let markdown () =
  let b = Buffer.create 4096 in
  Buffer.add_string b
    "<!-- GENERATED by takibi --emit-effect-matrix. Do not edit. -->\n\n# Effect relations\n\n";
  Buffer.add_string b
    "| Effect | Declaration | Declaration role | Function pointer row | Propagates | Excludes when co-declared | Forbidden in reachable calls | Unknown indirect call | Re-entry |\n";
  Buffer.add_string b
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n";
  List.iter (fun rule ->
    Printf.bprintf b "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s |\n"
      rule.name (declaration_text rule.declaration)
      (yes_no rule.declaration_role) (yes_no rule.function_pointer)
      (yes_no rule.propagates) (list_text rule.excludes_declared)
      (list_text rule.excludes_reachable)
      (if rule.rejects_unknown_indirect then "rejected" else "allowed")
      (if rule.forbids_reentry then "forbidden" else "allowed")) rules;
  Buffer.add_string b
    "\nA bare `!{}` contract forbids the transitive effects: ";
  Buffer.add_string b (String.concat ", " (List.map (Printf.sprintf "`%s`") effect_free_forbidden));
  Buffer.add_string b
    ". `locks` propagates and is forbidden by `!{}`, but is intentionally allowed from `interrupt` and `exception` roots; an `nmi` root forbids it.\n";
  Buffer.add_string b
    "\n# Checker-only words\n\nAccepted in an explicit `!{...}` row only; never in a function-pointer row, never propagated. No new word is added (DECISIONS.md, 2026-10-24); each row migrates to the replacing type.\n\n| Word | Marks | Read by | Replaced by |\n| --- | --- | --- | --- |\n";
  List.iter (fun w ->
    Printf.bprintf b "| `%s` | %s | %s | %s |\n"
      w.pattern w.marks w.read_by w.replaced_by) checker_words;
  Buffer.contents b
