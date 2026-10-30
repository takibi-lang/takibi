(* GitHub issue #779 option (c): the line ownership of a device protocol's
   region, decided from the concrete region identity b and element offset o
   that reach each P_init.

   A device protocol's cache work covers its region's lines, so the region
   must start on a cache line: the backing global must be aligned to the
   line and the element offset o, in bytes, a multiple of it. Before #779
   the compiler only checked that every backing global of the protocol's
   element type and count was aligned; a region made by region_split* of a
   larger region kept an unchecked base.

   Type inference records two things here:
   - the `__protocol_dma_own_lines(memory)` call in each generated P_init,
     with the region type's identity and offset statics in terms of
     P_init's own signature parameters (`b`, `b__off`), and
   - every call of a function whose parameters carry a region type, with
     the callee's signature statics and the call's instantiated ones.
   After every body is inferred (the static variables are solved), [solve]
   carries each requirement from callee to caller through those calls.
   A requirement whose statics end in a global and a constant reaches its
   protocol as (global, offset); one that still names the caller's
   parameters becomes the caller's requirement; anything else -- an
   existential identity (region_bytes_typed, a stored owner), a run-time
   split point -- is refused at that call, because its alignment cannot be
   known before run time. llvm_gen checks each (global, offset) against
   the target's line size and the global's alignment
   (Device_protocol_registry.reaching).

   Trusted: that every path to a P_init is a direct call -- a function
   carrying a requirement is refused as a function value
   ([check_value_use]). *)

open Types

(* A requirement, with its statics written over the function's own
   signature parameter names (SParam's id is not stable between the
   signature in fenv and the body's scope; the name is). *)
type req = { rb : static_term; ro : static_term; proto : string }

type call = {
  caller : string;
  callee : string;
  loc : Ast.loc;
  formal : ty;  (* the callee's signature, uninstantiated *)
  actual : ty;  (* the same signature instantiated at this call *)
}

(* Per function key: the body scope's signature parameters, name -> id. *)
let signatures : (string, (string, int) Hashtbl.t) Hashtbl.t = Hashtbl.create 64
(* Per function key: own_lines calls, raw body terms. *)
let seeds : (string * static_term * static_term * string * Ast.loc) list ref = ref []
let calls : call list ref = ref []
(* Functions used as values (not called): name -> first loc. *)
let values : (string, Ast.loc) Hashtbl.t = Hashtbl.create 16

let reset () =
  Hashtbl.reset signatures;
  seeds := [];
  calls := [];
  Hashtbl.reset values;
  Hashtbl.reset Device_protocol_registry.reaching

let rec mentions_region t =
  match repr t with
  | TIndexedStruct (n, _) ->
      String.length n > 8 && String.sub n 0 8 = "region__"
  | TFun (ps, _, _) -> List.exists mentions_region ps
  | TTuple ts -> List.exists mentions_region ts
  | TPtr t | TRef t | TRefMut t -> mentions_region t
  | _ -> false

let record_signature key (scope : static_scope) =
  let names = Hashtbl.create 8 in
  Hashtbl.iter (fun name term ->
    match static_repr term with
    | SParam (id, _) -> Hashtbl.replace names name id
    | _ -> ()) scope;
  Hashtbl.replace signatures key names

let record_seed key b o proto loc = seeds := (key, b, o, proto, loc) :: !seeds

let record_call ~caller ~callee loc ~formal ~actual =
  if mentions_region formal then
    calls := { caller; callee; loc; formal; actual } :: !calls

let record_value name loc =
  if not (Hashtbl.mem values name) then Hashtbl.replace values name loc

(* The callee's parameter names, each paired with its instantiated term at
   this call: the two signatures have the same shape. *)
let bindings formal actual =
  let found = Hashtbl.create 8 in
  let rec st f a =
    match static_repr f with
    | SParam (_, name) ->
        if not (Hashtbl.mem found name) then Hashtbl.replace found name a
    | SAdd (f1, f2) | SSub (f1, f2) | SMul (f1, f2) ->
        (match static_repr a with
         | SAdd (a1, a2) | SSub (a1, a2) | SMul (a1, a2) -> st f1 a1; st f2 a2
         | _ -> ())
    | _ -> ()
  and ty f a =
    match repr f, repr a with
    | TFun (fs, fr, _), TFun (as_, ar, _) when List.length fs = List.length as_ ->
        List.iter2 ty fs as_; ty fr ar
    | TIndexedStruct (_, fs), TIndexedStruct (_, as_)
    | TView (_, fs), TView (_, as_)
      when List.length fs = List.length as_ -> List.iter2 st fs as_
    | TVariant (_, fs, ft), TVariant (_, as_, at)
      when List.length fs = List.length as_ && List.length ft = List.length at ->
        List.iter2 st fs as_; List.iter2 ty ft at
    | TTuple fs, TTuple as_ when List.length fs = List.length as_ -> List.iter2 ty fs as_
    | (TPtr f, TPtr a | TRef f, TRef a | TRefMut f, TRefMut a) -> ty f a
    | TSingleton (fb, fs), TSingleton (ab, as_) -> ty fb ab; st fs as_
    | _ -> ()
  in
  ty formal actual;
  found

exception Unknown of string

(* A term solved in the caller's body, rewritten over the caller's
   signature names; anything not fixed at compile time is Unknown. *)
let rec over_signature names t =
  match static_repr t with
  | (SConst _ | SGlobal _) as t -> t
  | SParam (id, label) ->
      (match Hashtbl.fold (fun n i acc -> if i = id then Some n else acc) names None with
       | Some n -> SParam (0, n)
       | None -> raise (Unknown label))
  | SVar _ -> raise (Unknown "an unsolved compile-time value")
  | SEnum _ -> raise (Unknown "an enum state")
  | SAdd (a, b) -> SAdd (over_signature names a, over_signature names b)
  | SSub (a, b) -> SSub (over_signature names a, over_signature names b)
  | SMul (a, b) -> SMul (over_signature names a, over_signature names b)

let rec substitute map t =
  match t with
  | SParam (_, n) ->
      (match Hashtbl.find_opt map n with
       | Some a -> a
       | None -> raise (Unknown n))
  | SAdd (a, b) -> SAdd (substitute map a, substitute map b)
  | SSub (a, b) -> SSub (substitute map a, substitute map b)
  | SMul (a, b) -> SMul (substitute map a, substitute map b)
  | t -> t

let rec closed = function
  | SConst _ | SGlobal _ -> true
  | SParam _ | SVar _ | SEnum _ -> false
  | SAdd (a, b) | SSub (a, b) | SMul (a, b) -> closed a && closed b

let rec eval = function
  | SConst n -> n
  | SAdd (a, b) -> eval a + eval b
  | SSub (a, b) -> eval a - eval b
  | SMul (a, b) -> eval a * eval b
  | _ -> raise (Unknown "a region identity used as an offset")

let refuse loc proto why =
  raise (TypeError (loc, Printf.sprintf
    "device protocol '%s': the region reaching its _init here has %s as its \
     identity or element offset, which is not fixed at compile time, so its \
     cache-line ownership cannot be checked; give it a region claimed from a \
     backing global and split at constant points (GitHub issue #779)" proto why))

(* A requirement that has become closed: the protocol is reached from
   global g at element offset o. *)
let reach loc r =
  match r.rb with
  | SGlobal g ->
      let o = (try eval r.ro with Unknown why -> refuse loc r.proto why) in
      Device_protocol_registry.add_reaching r.proto (g, o, loc)
  | _ -> refuse loc r.proto "a non-global identity"

let limit = 64

let solve () =
  let reqs : (string, req list) Hashtbl.t = Hashtbl.create 16 in
  let work = Queue.create () in
  let add key loc r =
    if closed r.rb && closed r.ro then reach loc r
    else begin
      let have = Option.value (Hashtbl.find_opt reqs key) ~default:[] in
      if not (List.mem r have) then begin
        if List.length have >= limit then
          refuse loc r.proto "an offset that grows without bound through recursion";
        Hashtbl.replace reqs key (r :: have);
        Queue.add (key, r) work
      end
    end in
  let names_of key = Option.value (Hashtbl.find_opt signatures key)
                       ~default:(Hashtbl.create 1) in
  List.iter (fun (key, b, o, proto, loc) ->
    let names = names_of key in
    let r = try { rb = over_signature names b; ro = over_signature names o; proto }
            with Unknown why -> refuse loc proto why in
    add key loc r) (List.rev !seeds);
  let by_callee = Hashtbl.create 64 in
  List.iter (fun c -> Hashtbl.add by_callee c.callee c) !calls;
  while not (Queue.is_empty work) do
    let (key, r) = Queue.pop work in
    (match Hashtbl.find_opt values key with
     | Some loc -> raise (TypeError (loc, Printf.sprintf
         "'%s' passes its region on to device protocol '%s''s _init, so it \
          must be called directly: through a function value the region's \
          cache-line ownership cannot be checked (GitHub issue #779)" key r.proto))
     | None -> ());
    List.iter (fun c ->
      let map = bindings c.formal c.actual in
      let names = names_of c.caller in
      let r' =
        try { r with rb = over_signature names (substitute map r.rb);
                     ro = over_signature names (substitute map r.ro) }
        with Unknown why -> refuse c.loc r.proto why in
      add c.caller c.loc r') (Hashtbl.find_all by_callee key)
  done
