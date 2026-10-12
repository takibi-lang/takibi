(* Protocol declarations (GitHub issue #720, first slice).

   A `protocol` item is the single source of a resource-transfer protocol:
   its states, the region it retains, its transitions and the external
   observations those transitions consume. This module validates the raw
   syntax once into one checked representation [t], and emits the TLA+
   model from that representation. The sealed permission types are a later
   consumer of the same [t]; nothing here generates or checks code yet, so
   [extract] removes the item before any other compiler pass sees it.

   The emitted model's semantics, fixed by the declaration words:
   - the region is [model cells N] abstract cells; the initial state holds
     them all as CPU-available authority;
   - a [split] transition out of the initial state moves a nonempty span of
     available cells into the protocol owner ("held");
   - a state written [access write] grants the CPU authority over the held
     span; a state written [device] makes the held span device-active when it
     is entered from a non-device state (publication);
   - returning to the initial state merges the held span back;
   - [requires prepared] guards a transition on every held cell having been
     written, and each such write is one Prepare action;
   - an observation outcome marked [completes] ends device access to the
     span, one marked [quiesces] does so for a reset/stop, and an unmarked
     outcome changes nothing but the pending event. A transition naming an
     outcome as its witness consumes that pending event.
   The model's verdict is bounded evidence about the declaration, not a
   compiler axiom. *)

open Ast

let fail loc fmt = Printf.ksprintf (fun m -> raise (Types.TypeError (loc, m))) fmt

type state = {
  s_name : string;
  s_params : string list;
  s_write : bool;
  s_device : bool;
}

type outcome = {
  o_name : string;
  o_args : string list;
  o_subject : string;
  o_effect : [ `Plain | `Completes | `Quiesces ];
}

type alt = { a_label : string option; a_target : string }

type transition = {
  t_name : string;
  t_input : string;
  t_witness : string option;
  t_alts : alt list;
  t_split : bool;
  t_prepared : bool;
}

type t = {
  name : string;
  states : state list;
  init : string;
  transitions : transition list;
  outcomes : outcome list;
  disjoint : bool;
  prepared_before_read : bool;
  cells : int;
}

let supported_properties = [ "disjoint"; "prepared_before_read" ]

let check_distinct loc what names =
  ignore (List.fold_left (fun seen n ->
    if List.mem n seen then fail loc "duplicate %s '%s'" what n;
    n :: seen) [] names)

(* Validate one declaration into the checked representation. *)
let validate (d : protocol_decl) : t =
  let loc = d.proto_loc in
  let _, _, idx = d.proto_region in
  if List.length idx <> 2 then
    fail loc "protocol '%s' must retain region(T)[base, length]" d.proto_name;
  let states = List.filter_map (function
    | PState (r, attrs) ->
        List.iter (fun (a, fresh) ->
          if fresh then fail r.pr_loc "state '%s' parameter '%s' cannot be fresh"
            r.pr_name a) r.pr_args;
        let params = List.map fst r.pr_args in
        check_distinct r.pr_loc "state parameter" params;
        let rec parse w dev = function
          | [] -> (w, dev)
          | "access" :: "write" :: rest when not w -> parse true dev rest
          | "device" :: rest when not dev -> parse w true rest
          | a :: _ -> fail r.pr_loc "unsupported state attribute '%s' on '%s'"
                        a r.pr_name in
        let w, dev = parse false false attrs in
        if w && dev then
          fail r.pr_loc "state '%s' cannot be both 'access write' and 'device'"
            r.pr_name;
        Some ({ s_name = r.pr_name; s_params = params; s_write = w;
                s_device = dev }, r.pr_loc)
    | _ -> None) d.proto_items in
  check_distinct loc "state" (List.map (fun (s, _) -> s.s_name) states);
  let states = List.map fst states in
  if states = [] then fail loc "protocol '%s' declares no state" d.proto_name;
  let find_state rloc n =
    match List.find_opt (fun s -> s.s_name = n) states with
    | Some s -> s
    | None -> fail rloc "unknown protocol state '%s'" n in
  let check_arity (r : proto_ref) (s : state) =
    if List.length r.pr_args <> List.length s.s_params then
      fail r.pr_loc "state '%s' takes %d parameter(s), given %d" s.s_name
        (List.length s.s_params) (List.length r.pr_args) in
  let init = match List.filter_map (function PInit r -> Some r | _ -> None)
                     d.proto_items with
    | [ r ] ->
        let s = find_state r.pr_loc r.pr_name in
        if s.s_params <> [] then
          fail r.pr_loc "initial state '%s' cannot take parameters" s.s_name;
        s.s_name
    | [] -> fail loc "protocol '%s' has no 'init' state" d.proto_name
    | _ -> fail loc "protocol '%s' has more than one 'init' state" d.proto_name in
  (* Observations: each outcome is a witness type bound to its subject. *)
  let outcomes = List.concat_map (function
    | PObserve (_, subj, outs, oloc) ->
        let s = find_state subj.pr_loc subj.pr_name in
        check_arity subj s;
        let bound = List.map fst subj.pr_args in
        check_distinct oloc "observed parameter" bound;
        List.iter (fun (_, f) ->
          if f then fail oloc "an observed state cannot take a fresh parameter")
          subj.pr_args;
        List.map (fun ((r : proto_ref), mods) ->
          List.iter (fun (a, f) ->
            if f || not (List.mem a bound) then
              fail r.pr_loc "outcome '%s' argument '%s' is not bound by the \
                observed state" r.pr_name a) r.pr_args;
          let eff = match mods with
            | [] -> `Plain
            | [ "completes" ] ->
                if not s.s_device then
                  fail r.pr_loc "outcome '%s' completes device access, but \
                    state '%s' is not a device state" r.pr_name s.s_name;
                `Completes
            | [ "quiesces" ] -> `Quiesces
            | m :: _ -> fail r.pr_loc "unsupported outcome modifier '%s'" m in
          if List.exists (fun st -> st.s_name = r.pr_name) states then
            fail r.pr_loc "outcome '%s' has the name of a state" r.pr_name;
          { o_name = r.pr_name; o_args = List.map fst r.pr_args;
            o_subject = s.s_name; o_effect = eff }) outs
    | _ -> []) d.proto_items in
  check_distinct loc "observation outcome" (List.map (fun o -> o.o_name) outcomes);
  let action_names = List.filter_map (function
    | PTransition (n, _, _, _, _, _) | PObserve (n, _, _, _) -> Some n
    | _ -> None) d.proto_items in
  check_distinct loc "transition or observation" action_names;
  let transitions = List.filter_map (function
    | PTransition (n, input, witness, alts, mods, tloc) ->
        let s = find_state input.pr_loc input.pr_name in
        check_arity input s;
        List.iter (fun (a, f) ->
          if f then fail input.pr_loc "transition '%s' input parameter '%s' \
            cannot be fresh" n a) input.pr_args;
        let bound = List.map fst input.pr_args in
        check_distinct tloc "input parameter" bound;
        let witness = Option.map (fun (w : proto_ref) ->
          match List.find_opt (fun o -> o.o_name = w.pr_name) outcomes with
          | None -> fail w.pr_loc "transition '%s' consumes '%s', which no \
              observation produces" n w.pr_name
          | Some o ->
              if o.o_subject <> s.s_name then
                fail w.pr_loc "transition '%s' consumes '%s', which is \
                  observed on state '%s', not '%s'" n w.pr_name o.o_subject
                  s.s_name;
              if List.length w.pr_args <> List.length o.o_args then
                fail w.pr_loc "outcome '%s' takes %d argument(s), given %d"
                  o.o_name (List.length o.o_args) (List.length w.pr_args);
              List.iter (fun (a, f) ->
                if f || not (List.mem a bound) then
                  fail w.pr_loc "witness argument '%s' is not bound by the \
                    input state" a) w.pr_args;
              o.o_name) witness in
        let alts = List.map (fun a ->
          let r = a.pa_state in
          let target = find_state r.pr_loc r.pr_name in
          check_arity r target;
          List.iter (fun (arg, f) ->
            if f && List.mem arg bound then
              fail r.pr_loc "fresh parameter '%s' shadows an input parameter" arg;
            if (not f) && not (List.mem arg bound) then
              fail r.pr_loc "result argument '%s' of transition '%s' is not \
                bound by its input; write 'fresh %s' for a new identity" arg n
                arg) r.pr_args;
          { a_label = a.pa_label; a_target = target.s_name }) alts in
        check_distinct tloc "result label"
          (List.filter_map (fun a -> a.a_label) alts);
        let rec parse sp pr = function
          | [] -> (sp, pr)
          | "split" :: rest when not sp -> parse true pr rest
          | "requires" :: "prepared" :: rest when not pr -> parse sp true rest
          | m :: _ -> fail tloc "unsupported transition modifier '%s'" m in
        let split, prepared = parse false false mods in
        (* Static rules (maintainer, 2026-10-11): evidence that ends device
           access must name the request it is about, and the span leaves
           device access only on such evidence. Leaving to any non-device
           state is covered, not just to a CPU-access one: a detour through
           a neutral state (Halted) would otherwise reach Ready unwitnessed. *)
        Option.iter (fun w ->
          let o = List.find (fun o -> o.o_name = w) outcomes in
          if o.o_args = [] then
            fail tloc "transition '%s' consumes witness '%s', which carries no \
              request identifier" n w) witness;
        if s.s_device then
          List.iter (fun a ->
            let target = find_state tloc a.a_target in
            if not target.s_device then begin
              let ends_access = match witness with
                | None -> false
                | Some w ->
                    (List.find (fun o -> o.o_name = w) outcomes).o_effect
                    <> `Plain in
              if not ends_access then
                fail tloc "transition '%s' leaves device state '%s' for '%s' \
                  without a 'completes' or 'quiesces' witness" n s.s_name
                  target.s_name
            end) alts;
        if split && s.s_name <> init then
          fail tloc "transition '%s' splits the region, so its input must be \
            the initial state '%s'" n init;
        if prepared && not s.s_write then
          fail tloc "transition '%s' requires prepared cells, but '%s' grants \
            no write access" n s.s_name;
        Some { t_name = n; t_input = s.s_name; t_witness = witness;
               t_alts = alts; t_split = split; t_prepared = prepared }
    | _ -> None) d.proto_items in
  (* Only transitions produce states: an unreachable state would need an
     outside constructor, which the declaration does not have. *)
  let rec reach seen = function
    | [] -> seen
    | s :: rest ->
        let next = List.concat_map (fun t ->
          if t.t_input = s then List.map (fun a -> a.a_target) t.t_alts else [])
          transitions in
        let fresh = List.filter (fun n -> not (List.mem n seen)) next in
        reach (fresh @ seen) (fresh @ rest) in
  let reached = reach [ init ] [ init ] in
  List.iter (fun s ->
    if not (List.mem s.s_name reached) then
      fail loc "protocol state '%s' is unreachable from '%s'" s.s_name init)
    states;
  let props = List.filter_map (function
    | PProperty (p, ploc) ->
        if not (List.mem p supported_properties) then
          fail ploc "unsupported protocol property '%s' (supported: %s)" p
            (String.concat ", " supported_properties);
        Some p
    | _ -> None) d.proto_items in
  check_distinct loc "property" props;
  if props = [] then fail loc "protocol '%s' declares no property" d.proto_name;
  let cells = match List.filter_map (function
      | PModel (k, n, mloc) -> Some (k, n, mloc) | _ -> None) d.proto_items with
    | [ ("cells", n, mloc) ] ->
        if n < 1 || n > 3 then fail mloc "model cells must be 1..3, got %d" n;
        n
    | [ (k, _, mloc) ] -> fail mloc "unsupported model bound '%s'" k
    | [] -> fail loc "protocol '%s' needs a 'model cells N' bound" d.proto_name
    | _ -> fail loc "protocol '%s' has more than one model bound" d.proto_name in
  { name = d.proto_name; states; init; transitions; outcomes;
    disjoint = List.mem "disjoint" props;
    prepared_before_read = List.mem "prepared_before_read" props; cells }

(* Split protocol items from the program, validating each. *)
let extract (prog : toplevel list) : toplevel list * t list =
  let protos = List.filter_map (function
    | ProtocolDef d -> Some (validate d) | _ -> None) prog in
  check_distinct Lexing.dummy_pos "protocol" (List.map (fun p -> p.name) protos);
  (List.filter (function ProtocolDef _ -> false | _ -> true) prog, protos)

(* ---- TLA+ emission ---- *)

let quote s = "\"" ^ s ^ "\""
let set_of l = "{" ^ String.concat ", " l ^ "}"

let action_name t a =
  match t.t_alts with
  | [ _ ] -> t.t_name
  | _ -> t.t_name ^ "_" ^ (match a.a_label with Some l -> l | None -> a.a_target)

let to_tla (p : t) : string =
  let b = Buffer.create 4096 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s;
                                   Buffer.add_char b '\n') fmt in
  let is_device n = (List.find (fun s -> s.s_name = n) p.states).s_device in
  let write_states = List.filter_map (fun s ->
    if s.s_write then Some (quote s.s_name) else None) p.states in
  let events = "None" :: List.map (fun o -> o.o_name) p.outcomes in
  let header = Printf.sprintf "MODULE %s" p.name in
  let dashes = String.make ((76 - String.length header) / 2) '-' in
  line "%s %s %s" dashes header dashes;
  line "(* GENERATED by takibi --emit-tla from protocol %s; do not edit. *)" p.name;
  line "EXTENDS Integers, FiniteSets, TLC";
  line "";
  line "Cells == 0..%d" (p.cells - 1);
  line "States == %s" (set_of (List.map (fun s -> quote s.s_name) p.states));
  line "WriteStates == %s" (set_of write_states);
  line "Events == %s" (set_of (List.map quote events));
  line "";
  line "VARIABLES";
  List.iteri (fun i (v, ty) ->
    line "    \\* @type: %s;" ty;
    line "    %s%s" v (if i = 6 then "" else ","))
    [ ("phase", "Str"); ("available", "Set(Int)"); ("held", "Set(Int)");
      ("prepared", "Set(Int)"); ("deviceActive", "Set(Int)");
      ("event", "Str"); ("invalidRead", "Bool") ];
  line "";
  line "vars == <<phase, available, held, prepared, deviceActive, event, invalidRead>>";
  line "";
  line "Init ==";
  line "    /\\ phase = %s" (quote p.init);
  line "    /\\ available = Cells";
  line "    /\\ held = {}";
  line "    /\\ prepared = {}";
  line "    /\\ deviceActive = {}";
  line "    /\\ event = \"None\"";
  line "    /\\ invalidRead = FALSE";
  line "";
  let unchanged all changed =
    match List.filter (fun v -> not (List.mem v changed)) all with
    | [] -> ()
    | vs -> line "    /\\ UNCHANGED <<%s>>" (String.concat ", " vs) in
  let all_vars = [ "phase"; "available"; "held"; "prepared"; "deviceActive";
                   "event"; "invalidRead" ] in
  let next = ref [] in
  List.iter (fun t ->
    List.iter (fun a ->
      let name = action_name t a in
      let takes_span = t.t_split && a.a_target <> p.init in
      let changed = ref [ "phase" ] in
      line "%s%s ==" name (if takes_span then "(span)" else "");
      line "    /\\ phase = %s" (quote t.t_input);
      Option.iter (fun w -> line "    /\\ event = %s" (quote w)) t.t_witness;
      if t.t_prepared then line "    /\\ prepared = held";
      line "    /\\ phase' = %s" (quote a.a_target);
      if takes_span then begin
        line "    /\\ span # {}";
        line "    /\\ span \\subseteq available";
        line "    /\\ available' = available \\ span";
        line "    /\\ held' = span";
        line "    /\\ prepared' = {}";
        changed := [ "available"; "held"; "prepared" ] @ !changed
      end else if a.a_target = p.init && t.t_input <> p.init then begin
        line "    /\\ available' = available \\cup held";
        line "    /\\ held' = {}";
        line "    /\\ prepared' = {}";
        changed := [ "available"; "held"; "prepared" ] @ !changed
      end;
      if is_device a.a_target && not (is_device t.t_input) then begin
        line "    /\\ deviceActive' = held";
        changed := "deviceActive" :: !changed
      end;
      if t.t_witness <> None then begin
        line "    /\\ event' = \"None\"";
        changed := "event" :: !changed
      end;
      unchanged all_vars !changed;
      line "";
      next := (if takes_span then
                 Printf.sprintf "\\E span \\in SUBSET Cells : %s(span)" name
               else name) :: !next) t.t_alts) p.transitions;
  line "Prepare(cell) ==";
  line "    /\\ phase \\in WriteStates";
  line "    /\\ cell \\in held \\ prepared";
  line "    /\\ prepared' = prepared \\cup {cell}";
  unchanged all_vars [ "prepared" ];
  line "";
  next := "\\E cell \\in Cells : Prepare(cell)" :: !next;
  line "DeviceRead ==";
  line "    /\\ deviceActive # {}";
  line "    /\\ ~invalidRead";
  line "    /\\ invalidRead' = ~(deviceActive \\subseteq prepared)";
  unchanged all_vars [ "invalidRead" ];
  line "";
  next := "DeviceRead" :: !next;
  List.iter (fun o ->
    let name = "Observe_" ^ o.o_name in
    line "%s ==" name;
    line "    /\\ phase = %s" (quote o.o_subject);
    line "    /\\ event = \"None\"";
    (match o.o_effect with
     | `Completes ->
         line "    /\\ deviceActive # {}";
         line "    /\\ deviceActive' = {}"
     | `Quiesces -> line "    /\\ deviceActive' = {}"
     | `Plain -> ());
    line "    /\\ event' = %s" (quote o.o_name);
    unchanged all_vars
      ("event" :: (if o.o_effect = `Plain then [] else [ "deviceActive" ]));
    line "";
    next := name :: !next) p.outcomes;
  (* A pending event no transition out of the current state consumes is
     dropped; it is not evidence about the retained span. *)
  let consumers = List.filter_map (fun t ->
    Option.map (fun w -> Printf.sprintf "(phase = %s /\\ event = %s)"
                  (quote t.t_input) (quote w)) t.t_witness) p.transitions in
  line "Discard ==";
  line "    /\\ event # \"None\"";
  if consumers <> [] then
    line "    /\\ ~(%s)" (String.concat " \\/ " consumers);
  line "    /\\ event' = \"None\"";
  unchanged all_vars [ "event" ];
  line "";
  next := "Discard" :: !next;
  line "Next ==";
  List.iter (fun a -> line "    \\/ %s" a) (List.rev !next);
  line "";
  line "CpuAuthority == available \\cup (IF phase \\in WriteStates THEN held ELSE {})";
  line "NoOverlap == CpuAuthority \\intersect deviceActive = {}";
  line "ReadyBeforeRead == ~invalidRead";
  let safety = (if p.disjoint then [ "NoOverlap" ] else [])
               @ (if p.prepared_before_read then [ "ReadyBeforeRead" ] else []) in
  line "Safety == %s" (String.concat " /\\ " safety);
  line "TypeOK ==";
  line "    /\\ phase \\in States";
  line "    /\\ available \\subseteq Cells";
  line "    /\\ held \\subseteq Cells";
  line "    /\\ prepared \\subseteq Cells";
  line "    /\\ deviceActive \\subseteq Cells";
  line "    /\\ event \\in Events";
  line "    /\\ invalidRead \\in BOOLEAN";
  line "";
  line "Spec == Init /\\ [][Next]_vars";
  line "";
  line "CInit == TRUE";
  line "%s" (String.make 77 '=');
  Buffer.contents b

let to_cfg (_ : t) : string =
  "SPECIFICATION Spec\nCHECK_DEADLOCK FALSE\nINVARIANT TypeOK\nINVARIANT Safety\n"

(* ---- Sealed permission types (acceptance items 1 and 2) ----

   Each protocol generates Takibi source, parsed under the synthetic file
   name "<protocol Name>". File privacy then makes the generated functions
   the only code that can construct a state owner, read its retained region
   or mint an outcome witness: no user file is that file.

   For a protocol P retaining region(T)[b, n]:
   - every state S[p...] is `linear struct P_S[b: addr, b__off: usize,
     n: usize, p: usize...] { private memory: region(T)[b, n]; }`;
   - P_init(region) -> P_<init> and P_release(P_<init>) -> region are the
     region's way in and out;
   - every outcome W[a...] carrying arguments is a private linear view
     P_W[a...], minted only by its observation wrapper and consumed only by
     the transition that names it;
   - observe o(S[...]) generates P_o(borrow P_S) -> P_o_Outcome[...] that
     calls the user's `fn o(s: borrow P_S[...]) -> P_o_Raw`, the declared
     trusted boundary, and brands its answer;
   - transition t(I[...], W[...]) generates P_t(P_I, P_W) that calls the
     user's `fn t(s: borrow P_I[...])` (or `-> P_t_Choice` when there is
     more than one result) and moves the region into the successor.
   A declared transition or observation without its user function in the
   declaring file is rejected: an action with no lowering.
   The region's identity b is the protocol instance's identity; the
   protocol's own static parameters take no part in the generated types
   yet. *)

let rec type_source loc = function
  | TypeBool -> "bool" | TypeI8 -> "i8" | TypeI16 -> "i16" | TypeI32 -> "i32"
  | TypeI64 -> "i64" | TypeU8 -> "u8" | TypeU16 -> "u16" | TypeU32 -> "u32"
  | TypeU64 -> "u64" | TypeIsize -> "isize" | TypeUsize -> "usize"
  | TypeNamed n -> n
  | TypeArray (t, k) -> Printf.sprintf "[%s; %d]" (type_source loc t) k
  | _ -> fail loc "unsupported region element type in a protocol declaration"

let generated_file name = Printf.sprintf "<protocol %s>" name

let source_of (d : protocol_decl) (p : t) : string =
  let _, elem, idx = d.proto_region in
  let b, n = match idx with [ b; n ] -> (b, n) | _ -> assert false in
  let elem = type_source d.proto_loc elem in
  let pn = p.name in
  let buf = Buffer.create 4096 in
  let add fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s;
                                  Buffer.add_char buf '\n') fmt in
  let region = Printf.sprintf "region(%s)[%s, %s]" elem b n in
  let base = [ b; b ^ "__off"; n ] in
  let state s = List.find (fun st -> st.s_name = s) p.states in
  let ty s args = Printf.sprintf "%s_%s[%s]" pn s (String.concat ", " (base @ args)) in
  let view w args = Printf.sprintf "%s_%s[%s]" pn w (String.concat ", " args) in
  List.iter (fun s ->
    add "linear struct %s_%s[%s] {" pn s.s_name
      (String.concat ", " ([ b ^ ": addr"; b ^ "__off: usize"; n ^ ": usize" ]
                          @ List.map (fun x -> x ^ ": usize") s.s_params));
    add "    private memory: %s;" region;
    add "}") p.states;
  add "fn %s_init(memory: %s) -> %s {" pn region (ty p.init []);
  add "    let mut owner: %s = { memory };" (ty p.init []);
  add "    return owner;";
  add "}";
  add "fn %s_release(owner: %s) -> %s {" pn (ty p.init []) region;
  add "    return owner.memory;";
  add "}";
  List.iter (fun o ->
    if o.o_args <> [] then begin
      add "private linear view %s_%s[%s];" pn o.o_name
        (String.concat ", " (List.map (fun a -> a ^ ": usize") o.o_args));
      add "fn %s_%s_spend(w: sink %s) {}" pn o.o_name (view o.o_name o.o_args)
    end) p.outcomes;
  (* Observations, grouped by declaration order of their outcomes. *)
  let observes = List.filter_map (function
    | PObserve (name, subj, _, _) -> Some (name, subj) | _ -> None) d.proto_items in
  List.iter (fun (name, (subj : proto_ref)) ->
    let outs = List.filter (fun o -> o.o_subject = subj.pr_name &&
      List.exists (fun it -> match it with
        | PObserve (n', _, os, _) when n' = name ->
            List.exists (fun ((r : proto_ref), _) -> r.pr_name = o.o_name) os
        | _ -> false) d.proto_items) p.outcomes in
    let args = List.map fst subj.pr_args in
    add "variant %s_%s_Raw {" pn name;
    List.iter (fun o -> add "    %s;" o.o_name) outs;
    add "}";
    let params = String.concat ", " (List.map (fun a -> a ^ ": usize") args) in
    add "variant %s_%s_Outcome%s {" pn name
      (if args = [] then "" else "[" ^ params ^ "]");
    List.iter (fun o ->
      if o.o_args = [] then add "    %s;" o.o_name
      else add "    %s(%s);" o.o_name (view o.o_name o.o_args)) outs;
    add "}";
    let outcome_ty = Printf.sprintf "%s_%s_Outcome%s" pn name
      (if args = [] then "" else "[" ^ String.concat ", " args ^ "]") in
    add "fn %s_%s(s: borrow %s) -> %s {" pn name (ty subj.pr_name args) outcome_ty;
    add "    match %s(s) {" name;
    List.iter (fun o ->
      if o.o_args = [] then
        add "        %s_%s_Raw::%s => { return %s_%s_Outcome::%s; }" pn name
          o.o_name pn name o.o_name
      else
        add "        %s_%s_Raw::%s => { return %s_%s_Outcome::%s(view %s); }"
          pn name o.o_name pn name o.o_name (view o.o_name o.o_args)) outs;
    add "    }";
    add "}") observes;
  let trans_items = List.filter_map (function
    | PTransition (name, input, witness, alts, _, _) -> Some (name, input, witness, alts)
    | _ -> None) d.proto_items in
  List.iter (fun (name, (input : proto_ref), (witness : proto_ref option), alts) ->
    let t = List.find (fun t -> t.t_name = name) p.transitions in
    let in_args = List.map fst input.pr_args in
    let params = Printf.sprintf "s: %s%s" (ty input.pr_name in_args)
      (match witness with
       | None -> ""
       | Some w -> Printf.sprintf ", w: %s" (view w.pr_name (List.map fst w.pr_args))) in
    let spend = match witness with
      | None -> ""
      | Some w -> Printf.sprintf "%s_%s_spend(w); " pn w.pr_name in
    let target_ty (a : proto_alt) ~packed =
      ty a.pa_state.pr_name (List.map (fun (x, fresh) ->
        if fresh && packed then "0" else x) a.pa_state.pr_args) in
    let fresh_of (a : proto_alt) =
      List.filter_map (fun (x, f) -> if f then Some x else None) a.pa_state.pr_args in
    let simple = match alts with
      | [ a ] -> fresh_of a = []
      | _ -> false in
    ignore (state input.pr_name);
    if simple then begin
      let a = List.hd alts in
      add "fn %s_%s(%s) -> %s {" pn name params (target_ty a ~packed:false);
      add "    %s%s(s);" spend name;
      add "    let mut next: %s = { s.memory };" (target_ty a ~packed:false);
      add "    return next;";
      add "}"
    end else begin
      let label (a : proto_alt) = match a.pa_label with
        | Some l -> l | None -> a.pa_state.pr_name in
      let res_params = String.concat ", "
        ([ b ^ ": addr"; b ^ "__off: usize"; n ^ ": usize" ]
         @ List.map (fun x -> x ^ ": usize") in_args) in
      add "variant %s_%s_Choice {" pn name;
      List.iter (fun a -> add "    %s;" (label a)) alts;
      add "}";
      add "variant %s_%s_Result[%s] {" pn name res_params;
      List.iter (fun a ->
        let fr = fresh_of a in
        let body = target_ty a ~packed:false in
        add "    %s(%s%s);" (label a)
          (String.concat "" (List.map (fun x -> Printf.sprintf "exists %s: usize. " x) fr))
          body) alts;
      add "}";
      let result_ty = Printf.sprintf "%s_%s_Result[%s]" pn name
        (String.concat ", " (base @ in_args)) in
      add "fn %s_%s(%s) -> %s {" pn name params result_ty;
      if spend <> "" then add "    %s" spend;
      add "    match %s(s) {" name;
      List.iter (fun a ->
        add "        %s_%s_Choice::%s => {" pn name (label a);
        add "            let mut next: %s = { s.memory };" (target_ty a ~packed:true);
        add "            return %s_%s_Result::%s(next);" pn name (label a);
        add "        }") alts;
      add "    }";
      add "}"
    end;
    ignore t) trans_items;
  Buffer.contents buf

let parse_generated (name : string) (src : string) : toplevel list =
  let lexbuf = Lexing.from_string src in
  Lexing.set_filename lexbuf (generated_file name);
  try Parser.program Lexer.read lexbuf
  with Parser.Error ->
    let pos = Lexing.lexeme_start_p lexbuf in
    failwith (Printf.sprintf
      "internal error: generated protocol %s source does not parse at line %d:\n%s"
      name pos.Lexing.pos_lnum src)

(* Every declared action needs its lowering: a user function of the same
   name in the declaring file, taking exactly the borrowed state. *)
let check_lowering (prog : toplevel list) (d : protocol_decl) (p : t) =
  let file = source_file_of_loc d.proto_loc in
  let actions = List.filter_map (function
    | PTransition (n, input, _, alts, _, l) ->
        let simple = match alts with
          | [ a ] -> List.for_all (fun (_, f) -> not f) a.pa_state.pr_args
          | _ -> false in
        Some (n, input, (if simple then None
                         else Some (Printf.sprintf "%s_%s_Choice" p.name n)), l)
    | PObserve (n, subj, _, l) ->
        Some (n, subj, Some (Printf.sprintf "%s_%s_Raw" p.name n), l)
    | _ -> None) d.proto_items in
  List.iter (fun (n, (input : proto_ref), ret, l) ->
    match List.find_opt (function
        | FuncDef f -> f.name = n && source_file_of_loc f.def_loc = file
        | _ -> false) prog with
    | Some (FuncDef f) ->
        let owner = Printf.sprintf "%s_%s" p.name input.pr_name in
        let arity = 3 + List.length input.pr_args in
        let param_ok = match f.params with
          | [ (_, Some (TypeBorrow (TypeIndexed (name, args)))) ] ->
              name = owner && List.length args = arity
          | _ -> false in
        if not param_ok then
          fail f.def_loc "protocol '%s' action '%s' must take exactly \
            'borrow %s[...]' with %d static argument(s)" p.name n owner arity;
        let ret_ok = match ret, f.ret_type with
          | None, (None | Some TypeVoid) -> true
          | Some want, Some (TypeNamed got) -> want = got
          | _ -> false in
        if not ret_ok then
          fail f.def_loc "protocol '%s' action '%s' must return %s" p.name n
            (match ret with Some r -> r | None -> "nothing")
    | _ ->
        fail l "protocol '%s' action '%s' has no lowering: define fn %s in \
          the file that declares the protocol" p.name n n) actions

(* The compile path: validate, check every action's lowering, and replace
   each protocol item with its generated sealed types and wrappers. *)
let lower (prog : toplevel list) : toplevel list =
  ignore (extract prog);
  List.concat_map (function
    | ProtocolDef d ->
        let p = validate d in
        check_lowering prog d p;
        parse_generated p.name (source_of d p)
    | item -> [ item ]) prog
