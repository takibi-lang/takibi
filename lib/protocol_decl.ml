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
   - returning to the initial state merges the held span back; a protocol
     with no [split] holds every cell from its initial state on;
   - a device protocol's model adds the cache (GitHub issue #778): see
     [to_tla];
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
  s_read : bool;
  (* `access read` (GitHub issue #740): element reads only. Kept apart from
     `access write` so that a read-only state can later be held by several
     owners at once (a counted share) without touching writable states. On
     a device state it is accepted only when the device reads the region
     (a tx state): kernel/models/DmaTxReadBorrow.tla. *)
  s_device : bool;
  s_addressed : bool;
  (* `access write addressed` (GitHub issue #720, decision of 2026-10-13):
     a writable state of a device protocol that also yields the span, for
     structures that hold their own address (an xHCI Link TRB) or whose
     address programs the controller while the CPU writes them. *)
}

type outcome = {
  o_name : string;
  o_args : string list;
  o_subject : string;
  o_effect : [ `Plain | `Completes | `Quiesces | `Snapshot ];
}

type alt = { a_label : string option; a_target : string }

type transition = {
  t_name : string;
  t_input : string;
  t_witness : string option;
  t_alts : alt list;
  t_split : bool;
  t_prepared : bool;
  t_edge : Device_protocol_registry.direction option;
  (* `tx` or `rx` after a publishing edge of a `txrx` region (#740). *)
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
  direction : Device_protocol_registry.direction option;
  state_dirs : (string * Device_protocol_registry.direction) list;
  (* For a device protocol, the direction of each device state: the
     region's own, or for `txrx` the one its publishing edges name. *)
}

(* A publishing edge enters a device state from a non-device one; a
   finishing edge leaves a device state for a non-device one (validate
   requires a `completes` or `quiesces` witness on it). *)
let is_device_state p n = (List.find (fun s -> s.s_name = n) p.states).s_device
let publishes p input target =
  (not (is_device_state p input)) && is_device_state p target
let finishes p input target =
  is_device_state p input && not (is_device_state p target)
let is_publishing p t =
  List.exists (fun a -> publishes p t.t_input a.a_target) t.t_alts

(* GitHub issue #778: the cache work a device protocol's edge carries, by
   the direction of the device state it publishes or finishes. The one
   source for both the generated wrappers (source_of) and the emitted model
   (to_tla), so the model checks the placement the generator emits. A
   publishing edge has exactly one result (validate); a `tx` finishing edge
   has no cache work. *)
type cache_step = Clean | Prepare_rx | Finish_rx

let cache_step p t target =
  let dir n = List.assoc_opt n p.state_dirs in
  if p.direction = None then None
  else match t.t_alts with
    | [ _ ] when publishes p t.t_input target ->
        (match dir target with
         | Some Device_protocol_registry.Tx -> Some Clean
         | Some Device_protocol_registry.Rx -> Some Prepare_rx
         | Some Device_protocol_registry.TxRx | None -> None)
    | _ when finishes p t.t_input target ->
        (match dir t.t_input with
         | Some Device_protocol_registry.Rx -> Some Finish_rx
         | _ -> None)
    | _ -> None

let cache_builtin = function
  | Clean -> Device_protocol_registry.clean
  | Prepare_rx -> Device_protocol_registry.prepare_rx
  | Finish_rx -> Device_protocol_registry.finish_rx

let supported_properties = [ "disjoint"; "prepared_before_read" ]

let check_distinct loc what names =
  ignore (List.fold_left (fun seen n ->
    if List.mem n seen then fail loc "duplicate %s '%s'" what n;
    n :: seen) [] names)

(* GitHub issue #740: the direction of each device state. A `tx` or `rx`
   region gives every device state its own direction. A `txrx` region needs
   one on every publishing edge, and a device state takes the direction of
   the edges that publish into it, carried along device-to-device edges
   (InFlight -> Unconfirmed); a state reached in both directions is
   rejected, because its finishing edge's cache work would be ambiguous. *)
let state_directions loc (p : t) =
  match p.direction with
  | None -> []
  | Some (Device_protocol_registry.Tx | Device_protocol_registry.Rx as d) ->
      List.filter_map (fun s -> if s.s_device then Some (s.s_name, d) else None)
        p.states
  | Some Device_protocol_registry.TxRx ->
      let device n = (List.find (fun s -> s.s_name = n) p.states).s_device in
      let seeds = List.concat_map (fun t ->
        List.filter_map (fun a ->
          if (not (device t.t_input)) && device a.a_target then
            match t.t_edge with
            | Some e -> Some (a.a_target, e)
            | None -> fail loc "transition '%s' publishes a 'txrx' region, so \
                it must name its direction: write 'tx' or 'rx' before '->'"
                t.t_name
          else begin
            if t.t_edge <> None then
              fail loc "transition '%s' names a direction but publishes \
                nothing: only an edge into a device state from a CPU state does"
                t.t_name;
            None
          end) t.t_alts) p.transitions in
      let rec close known =
        let next = List.concat_map (fun t ->
          match List.assoc_opt t.t_input known with
          | Some e when device t.t_input ->
              List.filter_map (fun a ->
                if device a.a_target then Some (a.a_target, e) else None) t.t_alts
          | _ -> []) p.transitions in
        let fresh = List.filter (fun x -> not (List.mem x known)) next in
        if fresh = [] then known else close (fresh @ known) in
      let all = close (List.sort_uniq compare seeds) in
      List.iter (fun (n, e) ->
        if List.exists (fun (n', e') -> n' = n && e' <> e) all then
          fail loc "device state '%s' of a 'txrx' region is published both tx \
            and rx; give each direction its own state" n) all;
      List.sort_uniq compare all

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
        let rec parse w rd dev ad = function
          | [] -> (w, rd, dev, ad)
          | "access" :: "write" :: rest when not w && not rd -> parse true rd dev ad rest
          | "access" :: "read" :: rest when not rd && not w -> parse w true dev ad rest
          | "device" :: rest when not dev -> parse w rd true ad rest
          | "addressed" :: rest when not ad -> parse w rd dev true rest
          | a :: _ -> fail r.pr_loc "unsupported state attribute '%s' on '%s'"
                        a r.pr_name in
        let w, rd, dev, ad = parse false false false false attrs in
        if ad && not w then
          fail r.pr_loc "state '%s' is 'addressed' but not 'access write': \
            a device state already yields its span" r.pr_name;
        if ad && d.proto_direction = None then
          fail r.pr_loc "state '%s' is 'addressed', which only a device \
            protocol (a region with tx or rx) has" r.pr_name;
        if w && dev then
          fail r.pr_loc "state '%s' cannot be both 'access write' and 'device'"
            r.pr_name;
        Some ({ s_name = r.pr_name; s_params = params; s_write = w;
                s_read = rd; s_device = dev; s_addressed = ad }, r.pr_loc)
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
            (* GitHub issue #720 decision E1: a snapshot copies one element
               of a region the device still owns; it ends nothing. *)
            | [ "snapshot" ] ->
                if not s.s_device then
                  fail r.pr_loc "outcome '%s' is a snapshot, but state '%s' is \
                    not a device state" r.pr_name s.s_name;
                if d.proto_direction <> Some "rx"
                   && d.proto_direction <> Some "txrx" then
                  fail r.pr_loc "outcome '%s' is a snapshot, which only an rx \
                    device protocol has" r.pr_name;
                if r.pr_args <> [] then
                  fail r.pr_loc "snapshot outcome '%s' takes no arguments" r.pr_name;
                `Snapshot
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
              if o.o_effect = `Snapshot then
                fail w.pr_loc "transition '%s' consumes snapshot '%s': a snapshot \
                  is released through its own generated function, not a \
                  transition" n w.pr_name;
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
        let rec parse sp pr ed = function
          | [] -> (sp, pr, ed)
          | "split" :: rest when not sp -> parse true pr ed rest
          | "requires" :: "prepared" :: rest when not pr -> parse sp true ed rest
          | "tx" :: rest when ed = None ->
              parse sp pr (Some Device_protocol_registry.Tx) rest
          | "rx" :: rest when ed = None ->
              parse sp pr (Some Device_protocol_registry.Rx) rest
          | m :: _ -> fail tloc "unsupported transition modifier '%s'" m in
        let split, prepared, edge = parse false false None mods in
        if edge <> None && d.proto_direction <> Some "txrx" then
          fail tloc "transition '%s' names a direction, which only a \
            publishing edge of a 'txrx' region does" n;
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
                    (match (List.find (fun o -> o.o_name = w) outcomes).o_effect with
                     | `Completes | `Quiesces -> true
                     | `Plain | `Snapshot -> false) in
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
               t_alts = alts; t_split = split; t_prepared = prepared;
               t_edge = edge }
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
  let direction = match d.proto_direction with
    | None -> None
    | Some "tx" -> Some Device_protocol_registry.Tx
    | Some "rx" -> Some Device_protocol_registry.Rx
    | Some "txrx" -> Some Device_protocol_registry.TxRx
    | Some w -> fail loc "unsupported region direction '%s' on protocol '%s' \
        (supported: tx, rx, txrx)" w d.proto_name in
  let p = { name = d.proto_name; states; init; transitions; outcomes;
    disjoint = List.mem "disjoint" props;
    prepared_before_read = List.mem "prepared_before_read" props; cells;
    direction; state_dirs = [] } in
  let p = { p with state_dirs = state_directions loc p } in
  List.iter (fun s ->
    if s.s_read && s.s_device
       && List.assoc_opt s.s_name p.state_dirs <> Some Device_protocol_registry.Tx then
      fail loc "device state '%s' is 'access read', but the device writes it: \
        only a state the device reads (tx) may be read while it is posted"
        s.s_name) states;
  List.iter (fun o ->
    if o.o_effect = `Snapshot
       && List.assoc_opt o.o_subject p.state_dirs <> Some Device_protocol_registry.Rx then
      fail loc "outcome '%s' is a snapshot of state '%s', which the device \
        does not write (it is published tx)" o.o_name o.o_subject) outcomes;
  (* GitHub issue #720 option a: a device protocol's publishing edge does the
     cache work and the state change in one generated step, then runs its
     lowering on the device-state owner (the doorbell). The lowering cannot
     choose a result after publication, so such an edge has exactly one. *)
  if direction <> None then begin
    if not (List.exists (fun s -> s.s_device) states) then
      fail loc "device protocol '%s' has no 'device' state to publish to"
        d.proto_name;
    List.iter (fun t ->
      if is_publishing p t then begin
        if List.length t.t_alts <> 1 then
          fail loc "transition '%s' publishes the region to the device, so it \
            must have exactly one result" t.t_name;
        if t.t_split then
          fail loc "transition '%s' publishes the region to the device, so it \
            cannot split it: a device protocol owns its whole region" t.t_name
      end) transitions
  end;
  p

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

(* GitHub issue #778: a fault control for `make modelcheck` only. The
   generator always emits the cache step, so the control that shows the
   model catches a missing one leaves it out of the model instead: every
   publishing step (`Omit_publish`) or every finishing step
   (`Omit_finish`), or (GitHub issue #801) every snapshot observation's
   per-element invalidate (`Omit_refresh`). The module is renamed so the
   control and the fixed model can sit side by side. *)
type omit = Omit_publish | Omit_finish | Omit_refresh

let omit_of_string = function
  | "publish" -> Some Omit_publish
  | "finish" -> Some Omit_finish
  | "refresh" -> Some Omit_refresh
  | _ -> None

let module_name ?omit (p : t) =
  match omit with
  | None -> p.name
  | Some Omit_publish -> p.name ^ "_omitpublish"
  | Some Omit_finish -> p.name ^ "_omitfinish"
  | Some Omit_refresh -> p.name ^ "_omitrefresh"

let to_tla ?omit (p : t) : string =
  let b = Buffer.create 4096 in
  let line fmt = Printf.ksprintf (fun s -> Buffer.add_string b s;
                                   Buffer.add_char b '\n') fmt in
  let is_device n = (List.find (fun s -> s.s_name = n) p.states).s_device in
  let names f = List.filter_map (fun s ->
    if f s then Some (quote s.s_name) else None) p.states in
  let write_states = names (fun s -> s.s_write) in
  let events = "None" :: List.map (fun o -> o.o_name) p.outcomes in
  let device = p.direction <> None in
  (* A protocol without a split owns the whole region from its initial
     state on: every cell is held, none is merely available. *)
  let has_split = List.exists (fun t -> t.t_split) p.transitions in
  let mname = module_name ?omit p in
  let header = Printf.sprintf "MODULE %s" mname in
  let dashes = String.make ((76 - String.length header) / 2) '-' in
  line "%s %s %s" dashes header dashes;
  line "(* GENERATED by takibi --generate tla from protocol %s; do not edit. *)" p.name;
  (match omit with
   | None -> ()
   | Some o ->
       line "(* FAULT CONTROL: the %s cache step is left out. *)"
         (match o with Omit_publish -> "publishing" | Omit_finish -> "finishing"
                     | Omit_refresh -> "snapshot refresh"));
  line "EXTENDS Integers, FiniteSets, TLC";
  line "";
  line "Cells == 0..%d" (p.cells - 1);
  line "States == %s" (set_of (List.map (fun s -> quote s.s_name) p.states));
  line "WriteStates == %s" (set_of write_states);
  line "Events == %s" (set_of (List.map quote events));
  if device then begin
    let dir d = names (fun s -> s.s_device
                                && List.assoc_opt s.s_name p.state_dirs = Some d) in
    line "ReadStates == %s" (set_of (names (fun s -> s.s_read)));
    line "TxStates == %s" (set_of (dir Device_protocol_registry.Tx));
    line "RxStates == %s" (set_of (dir Device_protocol_registry.Rx))
  end;
  line "";
  (* GitHub issue #778: a device protocol's cache. `cached` lines hold a
     copy of a cell, `dirty` ones a CPU write not yet at the point of
     coherence, `stale` ones a copy taken before the device last wrote the
     cell. cacheFault records the device reading a dirty cell (tx), the
     device writing a cell whose dirty line may later be written back over
     it (rx), or the CPU reading a stale copy (rx). *)
  let vars = [ ("phase", "Str"); ("available", "Set(Int)"); ("held", "Set(Int)");
               ("prepared", "Set(Int)"); ("deviceActive", "Set(Int)");
               ("event", "Str"); ("invalidRead", "Bool") ]
             @ (if device then [ ("cached", "Set(Int)"); ("dirty", "Set(Int)");
                                 ("stale", "Set(Int)"); ("cacheFault", "Bool") ]
                else []) in
  let all_vars = List.map fst vars in
  let last = List.length vars - 1 in
  line "VARIABLES";
  List.iteri (fun i (v, ty) ->
    line "    \\* @type: %s;" ty;
    line "    %s%s" v (if i = last then "" else ",")) vars;
  line "";
  line "vars == <<%s>>" (String.concat ", " all_vars);
  line "";
  line "Init ==";
  line "    /\\ phase = %s" (quote p.init);
  line "    /\\ available = %s" (if has_split then "Cells" else "{}");
  line "    /\\ held = %s" (if has_split then "{}" else "Cells");
  line "    /\\ prepared = {}";
  line "    /\\ deviceActive = {}";
  line "    /\\ event = \"None\"";
  line "    /\\ invalidRead = FALSE";
  if device then begin
    line "    /\\ cached = {}";
    line "    /\\ dirty = {}";
    line "    /\\ stale = {}";
    line "    /\\ cacheFault = FALSE"
  end;
  line "";
  let unchanged changed =
    match List.filter (fun v -> not (List.mem v changed)) all_vars with
    | [] -> ()
    | vs -> line "    /\\ UNCHANGED <<%s>>" (String.concat ", " vs) in
  let omitted = ref 0 in
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
      (* The cells the edge's cache step covers: the generated wrapper
         applies it to the owner's whole retained region. *)
      let span_now = if takes_span then "span" else "held" in
      (match cache_step p t a.a_target with
       | Some step ->
           let skip = match step, omit with
             | (Clean | Prepare_rx), Some Omit_publish
             | Finish_rx, Some Omit_finish -> true
             | _, (None | Some (Omit_publish | Omit_finish | Omit_refresh)) -> false in
           if skip then begin
             incr omitted;
             line "    \\* FAULT CONTROL: %s left out" (cache_builtin step)
           end else begin
             line "    \\* generated %s(s.memory)" (cache_builtin step);
             line "    /\\ dirty' = dirty \\ %s" span_now;
             (match step with
              | Clean -> changed := "dirty" :: !changed
              | Prepare_rx | Finish_rx ->
                  line "    /\\ cached' = cached \\ %s" span_now;
                  line "    /\\ stale' = stale \\ %s" span_now;
                  changed := [ "dirty"; "cached"; "stale" ] @ !changed)
           end
       | None -> ());
      if takes_span then begin
        line "    /\\ span # {}";
        line "    /\\ span \\subseteq available";
        line "    /\\ available' = available \\ span";
        line "    /\\ held' = span";
        line "    /\\ prepared' = {}";
        changed := [ "available"; "held"; "prepared" ] @ !changed
      end else if a.a_target = p.init && t.t_input <> p.init then begin
        if has_split then begin
          line "    /\\ available' = available \\cup held";
          line "    /\\ held' = {}";
          changed := [ "available"; "held" ] @ !changed
        end;
        line "    /\\ prepared' = {}";
        changed := "prepared" :: !changed
      end;
      if is_device a.a_target && not (is_device t.t_input) then begin
        line "    /\\ deviceActive' = %s" span_now;
        changed := "deviceActive" :: !changed
      end;
      if t.t_witness <> None then begin
        line "    /\\ event' = \"None\"";
        changed := "event" :: !changed
      end;
      unchanged !changed;
      line "";
      next := (if takes_span then
                 Printf.sprintf "\\E span \\in SUBSET Cells : %s(span)" name
               else name) :: !next) t.t_alts) p.transitions;
  line "Prepare(cell) ==";
  line "    /\\ phase \\in WriteStates";
  line "    /\\ cell \\in held \\ prepared";
  line "    /\\ prepared' = prepared \\cup {cell}";
  unchanged [ "prepared" ];
  line "";
  next := "\\E cell \\in Cells : Prepare(cell)" :: !next;
  line "DeviceRead ==";
  line "    /\\ deviceActive # {}";
  line "    /\\ ~invalidRead";
  line "    /\\ invalidRead' = ~(deviceActive \\subseteq prepared)";
  unchanged [ "invalidRead" ];
  line "";
  next := "DeviceRead" :: !next;
  if device then begin
    line "\\* A CPU store: the line becomes cached and dirty.";
    line "CpuWrite(cell) ==";
    line "    /\\ cell \\in available \\cup (IF phase \\in WriteStates THEN held ELSE {})";
    line "    /\\ cached' = cached \\cup {cell}";
    line "    /\\ dirty' = dirty \\cup {cell}";
    unchanged [ "cached"; "dirty" ];
    line "";
    line "\\* A CPU load: a stale copy is a fault.";
    line "CpuRead(cell) ==";
    line "    /\\ cell \\in available \\cup (IF phase \\in WriteStates \\cup ReadStates THEN held ELSE {})";
    line "    /\\ ~cacheFault";
    line "    /\\ cacheFault' = (cell \\in stale)";
    line "    /\\ cached' = cached \\cup {cell}";
    unchanged [ "cacheFault"; "cached" ];
    line "";
    line "\\* A speculative fill of any cell, device-owned or not.";
    line "Fetch(cell) ==";
    line "    /\\ cell \\notin cached";
    line "    /\\ cached' = cached \\cup {cell}";
    unchanged [ "cached" ];
    line "";
    line "\\* An eviction writes a dirty line back and drops the copy.";
    line "Evict(cell) ==";
    line "    /\\ cell \\in cached";
    line "    /\\ cached' = cached \\ {cell}";
    line "    /\\ dirty' = dirty \\ {cell}";
    line "    /\\ stale' = stale \\ {cell}";
    unchanged [ "cached"; "dirty"; "stale" ];
    line "";
    (* GitHub issue #802: a device step goes in only when the protocol has
       a state of its direction. DeviceWrite in a tx-only model was a
       disjunct no reachable state enabled, which make modelcheck's coverage
       check (scripts/model_coverage.py) refuses. *)
    let has_dir d =
      List.exists (fun s -> s.s_device
                            && List.assoc_opt s.s_name p.state_dirs = Some d)
        p.states in
    let tx = has_dir Device_protocol_registry.Tx
    and rx = has_dir Device_protocol_registry.Rx in
    if tx then begin
      line "\\* The device reads a tx cell: a dirty line holds data it misses.";
      line "DeviceFetch(cell) ==";
      line "    /\\ phase \\in TxStates";
      line "    /\\ cell \\in deviceActive";
      line "    /\\ ~cacheFault";
      line "    /\\ cacheFault' = (cell \\in dirty)";
      unchanged [ "cacheFault" ];
      line ""
    end;
    if rx then begin
      line "\\* The device writes an rx cell: a dirty line may be written back over";
      line "\\* it, and a cached copy is now stale.";
      line "DeviceWrite(cell) ==";
      line "    /\\ phase \\in RxStates";
      line "    /\\ cell \\in deviceActive";
      line "    /\\ ~cacheFault";
      line "    /\\ cacheFault' = (cell \\in dirty)";
      line "    /\\ stale' = stale \\cup (cached \\intersect {cell})";
      unchanged [ "cacheFault"; "stale" ];
      line ""
    end;
    next := List.rev_append
        (List.map (fun a -> "\\E cell \\in Cells : " ^ a ^ "(cell)")
           ([ "CpuWrite"; "CpuRead"; "Fetch"; "Evict" ]
            @ (if tx then [ "DeviceFetch" ] else [])
            @ (if rx then [ "DeviceWrite" ] else [])))
        !next
  end;
  List.iter (fun o ->
    let name = "Observe_" ^ o.o_name in
    if o.o_effect = `Snapshot && device then begin
      (* GitHub issue #801: a snapshot copies element i of the held,
         device-owned region after the generated wrapper invalidates that
         element's lines (source_of: refresh_at, then region_at). The two
         are one step here: a device write between them makes the copy old,
         not incoherent -- the consumer's protocol rereads an old entry. A
         stale copy read without the invalidate is a fault. *)
      line "%s(cell) ==" name;
      line "    /\\ phase = %s" (quote o.o_subject);
      line "    /\\ event = \"None\"";
      line "    /\\ cell \\in held";
      line "    /\\ ~cacheFault";
      if omit = Some Omit_refresh then begin
        incr omitted;
        line "    \\* FAULT CONTROL: %s left out" Device_protocol_registry.refresh_at;
        line "    /\\ cacheFault' = (cell \\in stale)";
        line "    /\\ cached' = cached \\cup {cell}";
        line "    /\\ event' = %s" (quote o.o_name);
        unchanged [ "cacheFault"; "cached"; "event" ]
      end else begin
        line "    \\* generated %s(s.memory, i)" Device_protocol_registry.refresh_at;
        line "    /\\ dirty' = dirty \\ {cell}";
        line "    /\\ stale' = stale \\ {cell}";
        line "    \\* then the copy, which reads the line back in";
        line "    /\\ cacheFault' = (cell \\in stale')";
        line "    /\\ cached' = cached \\cup {cell}";
        line "    /\\ event' = %s" (quote o.o_name);
        unchanged [ "dirty"; "stale"; "cacheFault"; "cached"; "event" ]
      end;
      line "";
      next := Printf.sprintf "\\E cell \\in Cells : %s(cell)" name :: !next
    end else begin
    line "%s ==" name;
    line "    /\\ phase = %s" (quote o.o_subject);
    line "    /\\ event = \"None\"";
    (match o.o_effect with
     | `Completes ->
         line "    /\\ deviceActive # {}";
         line "    /\\ deviceActive' = {}"
     | `Quiesces -> line "    /\\ deviceActive' = {}"
     | `Plain | `Snapshot -> ());
    line "    /\\ event' = %s" (quote o.o_name);
    unchanged
      ("event" :: (match o.o_effect with
                   | `Completes | `Quiesces -> [ "deviceActive" ]
                   | `Plain | `Snapshot -> []));
    line "";
    next := name :: !next
    end) p.outcomes;
  if omit <> None && !omitted = 0 then
    failwith (Printf.sprintf "--internal-tla-omit-cache: protocol %s has no such \
                              cache step, so the control would be vacuous" p.name);
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
  unchanged [ "event" ];
  line "";
  next := "Discard" :: !next;
  line "Next ==";
  List.iter (fun a -> line "    \\/ %s" a) (List.rev !next);
  line "";
  line "CpuAuthority == available \\cup (IF phase \\in WriteStates THEN held ELSE {})";
  line "NoOverlap == CpuAuthority \\intersect deviceActive = {}";
  line "ReadyBeforeRead == ~invalidRead";
  if device then line "CacheCoherent == ~cacheFault";
  let safety = (if p.disjoint then [ "NoOverlap" ] else [])
               @ (if p.prepared_before_read then [ "ReadyBeforeRead" ] else [])
               @ (if device then [ "CacheCoherent" ] else []) in
  line "Safety == %s" (String.concat " /\\ " safety);
  line "TypeOK ==";
  line "    /\\ phase \\in States";
  line "    /\\ available \\subseteq Cells";
  line "    /\\ held \\subseteq Cells";
  line "    /\\ prepared \\subseteq Cells";
  line "    /\\ deviceActive \\subseteq Cells";
  line "    /\\ event \\in Events";
  line "    /\\ invalidRead \\in BOOLEAN";
  if device then begin
    line "    /\\ cached \\subseteq Cells";
    line "    /\\ dirty \\subseteq cached";
    line "    /\\ stale \\subseteq cached";
    line "    /\\ cacheFault \\in BOOLEAN"
  end;
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
   - every `access write` state S gets P_S_write(borrow P_S, i, value) and
     P_S_read(borrow P_S, i), each `where k < n` for the index's identity k;
     no other state has any access to its region.
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

let generated_file = Ast.protocol_file

(* The length M of the element struct's `bytes: [u8; M]` field, if it has
   one (GitHub issue #740, packet buffers). *)
let element_bytes (prog : toplevel list) (d : protocol_decl) : int option =
  let _, elem, _ = d.proto_region in
  match elem with
  | TypeNamed n ->
      List.find_map (function
        | StructDef (n', fields, _, _, _, _) when n' = n ->
            (match List.assoc_opt "bytes" fields with
             | Some (TypeArray (TypeU8, m)) -> Some m
             | _ -> None)
        | _ -> None) prog
  | _ -> None

let source_of ?bytes_field (d : protocol_decl) (p : t) : string =
  let _, elem, idx = d.proto_region in
  let b, n = match idx with [ b; n ] -> (b, n) | _ -> assert false in
  let elem = type_source d.proto_loc elem in
  let pn = p.name in
  let buf = Buffer.create 4096 in
  let add fmt = Printf.ksprintf (fun s -> Buffer.add_string buf s;
                                  Buffer.add_char buf '\n') fmt in
  (* A count naming a declared constant fixes the region's length: owners
     keep their count index (the stored-owner rule needs all three), but
     every generated signature instantiates it with the literal, so the
     only owners that exist have that count and lowerings can prove indices
     against it. Otherwise the count stays a static index throughout. *)
  let fixed = Option.map string_of_int (Const_env.find n) in
  let count = Option.value fixed ~default:n in
  let field_region = Printf.sprintf "region(%s)[%s, %s]" elem b n in
  let region = Printf.sprintf "region(%s)[%s, %s]" elem b count in
  let base = [ b; b ^ "__off"; count ] in
  let base_params = [ b ^ ": addr"; b ^ "__off: usize" ]
                    @ (if fixed = None then [ n ^ ": usize" ] else []) in
  let base_args = [ b; b ^ "__off" ] @ (if fixed = None then [ n ] else []) in
  let struct_params = [ b ^ ": addr"; b ^ "__off: usize"; n ^ ": usize" ] in
  let state s = List.find (fun st -> st.s_name = s) p.states in
  let ty s args = Printf.sprintf "%s_%s[%s]" pn s (String.concat ", " (base @ args)) in
  let view w args = Printf.sprintf "%s_%s[%s]" pn w (String.concat ", " args) in
  List.iter (fun s ->
    add "linear struct %s_%s[%s] {" pn s.s_name
      (String.concat ", " (struct_params
                          @ List.map (fun x -> x ^ ": usize") s.s_params));
    add "    private memory: %s;" field_region;
    add "}") p.states;
  (* CPU access exists only for `access write` states: element reads and
     writes through the retained region, the index proved below the count
     at each call (`where`), with no escaping pointer. *)
  List.iter (fun s ->
    if s.s_write || s.s_read then begin
      let owner = ty s.s_name s.s_params in
      if s.s_write then begin
        add "inline fn %s_%s_write(s: borrow %s, i: usize @ k, value: %s) where k < %s {"
          pn s.s_name owner elem count;
        add "    let element = region_at(s.memory, i);";
        add "    *element = value;";
        add "}"
      end;
      (* GitHub issue #740: an element struct with a `bytes: [u8; M]` field
         (a packet buffer) is read and written in place through a slice
         derived from the owner's borrow, so header overlays can view it;
         the slice dies with the borrow. A read-only state gets a const one. *)
      Option.iter (fun m ->
        add "inline fn %s_%s_bytes(s: borrow %s, i: usize @ k) -> [%su8; %d..] @ %s where k < %s {"
          pn s.s_name owner (if s.s_write then "" else "const ") m b count;
        add "    let element = region_at(s.memory, i);";
        add "    return element.bytes[0..<%d];" m;
        add "}") bytes_field;
      add "inline fn %s_%s_read(s: borrow %s, i: usize @ k) -> %s where k < %s {"
        pn s.s_name owner elem count;
      add "    return *region_at(s.memory, i);";
      add "}"
    end) p.states;
  (* GitHub issue #720 option a: a device state's owner yields the span the
     device is given -- the whole region or one element -- as the existing
     DmaDeviceSpan, tied to the borrow of the owner. No CPU-access state has
     one, so an address exists only while the CPU holds no write authority. *)
  let device = p.direction <> None in
  if device then
    List.iter (fun s ->
      if s.s_device || s.s_addressed then begin
        let owner = ty s.s_name s.s_params in
        let whole = Printf.sprintf "%s_%s_span" pn s.s_name in
        let one = whole ^ "_at" in
        Device_protocol_registry.register_span_function whole;
        Device_protocol_registry.register_span_function one;
        add "inline fn %s(s: borrow %s) -> DmaDeviceSpan {" whole owner;
        add "    return %s(s.memory, 0, %s);" Device_protocol_registry.span count;
        add "}";
        add "inline fn %s(s: borrow %s, i: usize @ k) -> DmaDeviceSpan where k < %s {"
          one owner count;
        add "    return %s(s.memory, i, 1);" Device_protocol_registry.span;
        add "}"
      end) p.states;
  add "fn %s_init(memory: %s) -> %s {" pn region (ty p.init []);
  if device then add "    %s(memory);" Device_protocol_registry.own_lines;
  add "    let mut owner: %s = { memory };" (ty p.init []);
  add "    return owner;";
  add "}";
  add "inline fn %s_release(owner: %s) -> %s {" pn (ty p.init []) region;
  add "    return owner.memory;";
  add "}";
  List.iter (fun o ->
    if o.o_args <> [] then begin
      add "private linear view %s_%s[%s];" pn o.o_name
        (String.concat ", " (List.map (fun a -> a ^ ": usize") o.o_args));
      add "inline fn %s_%s_spend(w: sink %s) {}" pn o.o_name (view o.o_name o.o_args)
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
    let snap = List.find_opt (fun o -> o.o_effect = `Snapshot) outs in
    add "variant %s_%s_Raw {" pn name;
    List.iter (fun o -> add "    %s;" o.o_name) outs;
    add "}";
    (* GitHub issue #720 decision E1: a snapshot is a copy of element i of
       the device-owned region, taken after invalidating that element's
       lines, carried with the region's identity so that its release -- the
       consumer's acknowledgement to the device -- names the same region. *)
    let snap_idx = [ b; b ^ "__off" ] in
    Option.iter (fun o ->
      let sty = Printf.sprintf "%s_%s[%s]" pn o.o_name (String.concat ", " snap_idx) in
      add "linear struct %s_%s[%s: addr, %s__off: usize] {" pn o.o_name b b;
      add "    private value: %s;" elem;
      add "    private unit: usize;";
      add "}";
      add "inline fn %s_%s_value(snap: borrow %s) -> %s {" pn o.o_name sty elem;
      add "    return snap.value;";
      add "}";
      add "fn %s_%s_release(s: borrow %s, snap: sink %s) {" pn o.o_name
        (ty subj.pr_name args) sty;
      add "    %s_release(s);" name;
      add "}") snap;
    let all_params = (match snap with
      | Some _ -> [ b ^ ": addr"; b ^ "__off: usize" ] | None -> [])
      @ List.map (fun a -> a ^ ": usize") args in
    let all_args = (match snap with Some _ -> snap_idx | None -> []) @ args in
    add "variant %s_%s_Outcome%s {" pn name
      (if all_params = [] then "" else "[" ^ String.concat ", " all_params ^ "]");
    List.iter (fun o ->
      if o.o_effect = `Snapshot then
        add "    %s(%s_%s[%s]);" o.o_name pn o.o_name (String.concat ", " snap_idx)
      else if o.o_args = [] then add "    %s;" o.o_name
      else add "    %s(%s);" o.o_name (view o.o_name o.o_args)) outs;
    add "}";
    let outcome_ty = Printf.sprintf "%s_%s_Outcome%s" pn name
      (if all_args = [] then "" else "[" ^ String.concat ", " all_args ^ "]") in
    (match snap with
     | None ->
         add "fn %s_%s(s: borrow %s) -> %s {" pn name (ty subj.pr_name args) outcome_ty;
         add "    match %s(s) {" name
     | Some _ ->
         add "fn %s_%s(s: borrow %s, i: usize @ k) -> %s where k < %s {" pn name
           (ty subj.pr_name args) outcome_ty count;
         add "    %s(s.memory, i);" Device_protocol_registry.refresh_at;
         add "    let mut value: %s = *region_at(s.memory, i);" elem;
         add "    match %s(s, value) {" name);
    List.iter (fun o ->
      if o.o_effect = `Snapshot then
        add "        %s_%s_Raw::%s => { let mut snap: %s_%s[%s] = { value, 0 }; \
             return %s_%s_Outcome::%s(snap); }" pn name o.o_name pn o.o_name
          (String.concat ", " snap_idx) pn name o.o_name
      else if o.o_args = [] then
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
    let finish (a : proto_alt) indent =
      match cache_step p t a.pa_state.pr_name with
      | Some Finish_rx -> add "%s%s(s.memory);" indent (cache_builtin Finish_rx)
      | Some (Clean | Prepare_rx) | None -> () in
    let label (a : proto_alt) = match a.pa_label with
      | Some l -> l | None -> a.pa_state.pr_name in
    let res_params = String.concat ", "
      (base_params @ List.map (fun x -> x ^ ": usize") in_args) in
    let result_variant () =
      add "variant %s_%s_Result[%s] {" pn name res_params;
      List.iter (fun a ->
        let fr = fresh_of a in
        let body = target_ty a ~packed:false in
        add "    %s(%s%s);" (label a)
          (String.concat "" (List.map (fun x -> Printf.sprintf "exists %s: usize. " x) fr))
          body) alts;
      add "}";
      Printf.sprintf "%s_%s_Result[%s]" pn name
        (String.concat ", " (base_args @ in_args)) in
    let publishing = match alts with
      | [ a ] ->
          (match cache_step p t a.pa_state.pr_name with
           | Some (Clean | Prepare_rx as c) -> Some (cache_builtin c, a)
           | Some Finish_rx | None -> None)
      | _ -> None in
    match publishing with
    | Some (prepare, a) ->
        (* Publication: the cache work and the state change are one step,
           and the lowering (the doorbell) runs after both, on the
           device-state owner. A fresh request identity is packed into a
           one-case result, as for any transition with a fresh result. *)
        let fresh = fresh_of a <> [] in
        let ret = if fresh then result_variant () else target_ty a ~packed:false in
        add "fn %s_%s(%s) -> %s {" pn name params ret;
        if spend <> "" then add "    %s" spend;
        add "    %s(s.memory);" prepare;
        add "    let mut next: %s = { s.memory };" (target_ty a ~packed:true);
        add "    %s(next);" name;
        if fresh then add "    return %s_%s_Result::%s(next);" pn name (label a)
        else add "    return next;";
        add "}"
    | None ->
    if simple then begin
      let a = List.hd alts in
      add "fn %s_%s(%s) -> %s {" pn name params (target_ty a ~packed:false);
      add "    %s%s(s);" spend name;
      finish a "    ";
      add "    let mut next: %s = { s.memory };" (target_ty a ~packed:false);
      add "    return next;";
      add "}"
    end else begin
      add "variant %s_%s_Choice {" pn name;
      List.iter (fun a -> add "    %s;" (label a)) alts;
      add "}";
      let result_ty = result_variant () in
      add "fn %s_%s(%s) -> %s {" pn name params result_ty;
      if spend <> "" then add "    %s" spend;
      add "    match %s(s) {" name;
      List.iter (fun a ->
        add "        %s_%s_Choice::%s => {" pn name (label a);
        finish a "            ";
        add "            let mut next: %s = { s.memory };" (target_ty a ~packed:true);
        add "            return %s_%s_Result::%s(next);" pn name (label a);
        add "        }") alts;
      add "    }";
      add "}"
    end) trans_items;
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
        (* A device protocol's publishing edge runs its lowering after the
           state change, on the device-state owner, and chooses nothing
           (validate gave it one result). *)
        let subject = match alts with
          | [ a ] when p.direction <> None
                       && publishes p input.pr_name a.pa_state.pr_name ->
              a.pa_state
          | _ -> input in
        Some (n, subject, (if simple || subject != input then None
                           else Some (Printf.sprintf "%s_%s_Choice" p.name n)), l)
    | PObserve (n, subj, _, l) ->
        Some (n, subj, Some (Printf.sprintf "%s_%s_Raw" p.name n), l)
    | _ -> None) d.proto_items in
  let snapshot_observe n = List.exists (function
    | PObserve (n', _, outs, _) when n' = n ->
        List.exists (fun (_, mods) -> mods = [ "snapshot" ]) outs
    | _ -> false) d.proto_items in
  let _, elem, _ = d.proto_region in
  (* A snapshot observation also needs its release lowering: what the
     consumer tells the device once it has read the entry. *)
  let actions = actions @ List.concat_map (fun (n, subj, _, l) ->
    if snapshot_observe n then [ (n ^ "_release", subj, None, l) ] else [])
    actions in
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
                && not (snapshot_observe n)
          | [ (_, Some (TypeBorrow (TypeIndexed (name, args)))); (_, Some t) ] ->
              name = owner && List.length args = arity
                && snapshot_observe n && t = elem
          | _ -> false in
        if not param_ok then
          fail f.def_loc "protocol '%s' action '%s' must take exactly \
            'borrow %s[...]' with %d static argument(s)%s" p.name n owner arity
            (if snapshot_observe n then ", then the element value" else "");
        if f.where_clauses <> [] then
          fail f.def_loc "protocol '%s' action '%s' cannot add 'where' \
            constraints: the generated wrapper has no facts to discharge them; \
            fix the region's count with a declared constant instead" p.name n;
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
(* GitHub issue #720 option a (decision D2 = Q1): a device protocol's
   `observe` lowerings assert device facts -- completion, quiescence -- that
   end device access and, for rx, make the CPU read what the device wrote.
   Only a file named by --device-semantics-file may declare one; the kernel's
   list is kernel/DEVICE_SEMANTICS_FILES. *)
let device_semantics_files : string list ref = ref []

(* GitHub issue #796: the files that declared a device protocol in this
   compilation, so a --device-semantics-file entry granting nothing is
   rejected as stale. *)
let declared_device_files : string list ref = ref []

let normalize file =
  if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file
  else file

let check_device (d : protocol_decl) (p : t) =
  match p.direction with
  | None -> ()
  | Some direction ->
      let file = source_file_of_loc d.proto_loc in
      declared_device_files := file :: !declared_device_files;
      if not (List.exists (fun f -> normalize f = normalize file)
                !device_semantics_files) then
        fail d.proto_loc "device protocol '%s' (a region with a direction) may \
          only be declared in a device-semantics file, named by \
          --device-semantics-file; its observations assert device completion \
          and quiescence" d.proto_name;
      let _, elem, idx = d.proto_region in
      let n = match idx with [ _; n ] -> n | _ -> assert false in
      (match elem with
       | TypeU8 | TypeNamed _ -> ()
       | _ -> fail d.proto_loc "device protocol '%s' must retain a region of \
                u8 or of a named type" d.proto_name);
      match Const_env.find n with
      | Some count ->
          Device_protocol_registry.register d.proto_name
            { Device_protocol_registry.elem; count; direction;
              loc = d.proto_loc }
      | None ->
          fail d.proto_loc "device protocol '%s' must fix its region's count \
            with a declared constant: the cache work and the line-ownership \
            check need its byte extent" d.proto_name

(* GitHub issue #782: the names an item refers to -- every call and every
   variable -- so that generated functions nothing reaches can be dropped. *)
module Names = Set.Make (String)

let rec expr_names acc (e : expr) =
  match e.desc with
  | Var n -> Names.add n acc
  | Call (f, args) -> List.fold_left expr_names (Names.add f acc) args
  | Index (a, i) -> expr_names (expr_names acc a) i
  | SliceOf (a, lo, hi) -> expr_names (expr_names (expr_names acc a) lo) hi
  | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | EnumVariant _
  | EmbedFile _ | ViewLit _ | SizeOf _ | AlignOf _ | ContainsStableOwner _
  | OffsetOf _ -> acc
  | StructLit args | TupleLit args -> List.fold_left expr_names acc args
  | VariantCtor (_, _, a) | Bnot a | Deref a | AddrOf a | Cast (_, a)
  | FieldGet (a, _) | Unsafe a -> expr_names acc a
  | BinOp (_, a, b) | Assign (a, b) -> expr_names (expr_names acc a) b

and stmt_names acc (st : stmt) =
  match st.desc with
  | Return None | Break | Continue -> acc
  | Return (Some e) | Expr e | Yield e -> expr_names acc e
  | StaticAssert (c, _) -> expr_names acc c
  | Block ss | UnsafeBlock ss -> List.fold_left stmt_names acc ss
  | Let (_, _, _, e, _) -> Option.fold ~none:acc ~some:(expr_names acc) e
  | If (c, t, f) ->
      List.fold_left stmt_names (List.fold_left stmt_names (expr_names acc c) t) f
  | While (c, b) -> List.fold_left stmt_names (expr_names acc c) b
  | For (_, _, lo, hi, b) ->
      List.fold_left stmt_names (expr_names (expr_names acc lo) hi) b
  | ForEach (_, e, b) -> List.fold_left stmt_names (expr_names acc e) b
  | LetTuple (_, e) -> expr_names acc e
  | Match (e, arms) | LetMatch (_, _, _, e, arms) ->
      List.fold_left arm_names (expr_names acc e) arms

and arm_names acc = function
  | ArmVariant (_, _, _, ss) | ArmWild ss | ArmMiss ss
  | ArmIntLit (_, ss) | ArmByteSliceLit (_, ss) -> List.fold_left stmt_names acc ss

let item_names acc = function
  | FuncDef f -> List.fold_left stmt_names acc f.body
  | LetDef (_, _, Some e, _, _, _, _) | ConstDef (_, _, e, _) -> expr_names acc e
  | VectorTableDef (entries, _) ->
      List.fold_left (fun acc (_, n) -> Names.add n acc) acc entries
  | _ -> acc

(* Keep a generated function only when something outside the generated
   code reaches it, directly or through other kept generated functions.
   The declaration's validation and lowering checks already ran on the
   whole generated set, so dropping changes no verdict, only the image. *)
let drop_unreferenced (program : toplevel list) (generated : toplevel list list) =
  let all_gen = List.concat generated in
  let gen_fn = List.filter_map (function
    | FuncDef f -> Some (f.name, f) | _ -> None) all_gen in
  let roots = List.fold_left item_names Names.empty program in
  let rec close kept frontier =
    let next = Names.fold (fun n acc ->
      match List.assoc_opt n gen_fn with
      | Some f when not (Names.mem n kept) -> item_names acc (FuncDef f)
      | _ -> acc) frontier Names.empty in
    let kept' = Names.union kept (Names.filter (fun n -> List.mem_assoc n gen_fn) frontier) in
    let fresh = Names.diff next kept' in
    if Names.is_empty fresh then kept' else close kept' fresh in
  let kept = close Names.empty roots in
  List.map (List.filter (function
    | FuncDef f -> Names.mem f.name kept
    | _ -> true)) generated

let lower (prog : toplevel list) : toplevel list =
  declared_device_files := [];
  ignore (extract prog);
  let expanded = List.map (function
    | ProtocolDef d ->
        let p = validate d in
        check_device d p;
        check_lowering prog d p;
        `Generated (parse_generated p.name
                      (source_of ?bytes_field:(element_bytes prog d) d p))
    | item -> `Item item) prog in
  let program = List.filter_map (function `Item i -> Some i | _ -> None) expanded in
  let generated = List.filter_map (function `Generated g -> Some g | _ -> None) expanded in
  let kept = ref (drop_unreferenced program generated) in
  List.concat_map (function
    | `Item i -> [ i ]
    | `Generated _ ->
        (match !kept with
         | g :: rest -> kept := rest; g
         | [] -> [])) expanded

(* GitHub issue #758: each protocol's generated Takibi source, for
   --generate protocol-source. Only the declaration is validated, so the source
   can be read when a lowering's error points into `<protocol Name>`. *)
let generated_sources (prog : toplevel list) : (string * string) list =
  List.filter_map (function
    | ProtocolDef d ->
        let p = validate d in
        Some (p.name, source_of ?bytes_field:(element_bytes prog d) d p)
    | _ -> None) prog
