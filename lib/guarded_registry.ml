(* GitHub issue #131 slice 3 / #686: a Place field declared
   `private f: Place(T) guarded_by(L);` is serialized by the global lock L
   rather than by a mutex in its own struct. The parser records the
   declaration here; the checker asks for it at each place operation and
   requires the guard's index to be &L. Field level, like Clang's
   GUARDED_BY: the declaration claims only the field it is written on. *)

let fields : (string * string, string) Hashtbl.t = Hashtbl.create 4
let pending : (string * string) list ref = ref []

let reset () =
  Hashtbl.reset fields;
  pending := []

let note field lock = pending := (field, lock) :: !pending

(* A plain struct's declaration completes: its pending fields are its own. *)
let finish name =
  List.iter (fun (field, lock) -> Hashtbl.replace fields (name, field) lock)
    !pending;
  pending := []

(* Any other struct form: the modifier is not accepted there. *)
let take_pending () =
  let p = !pending in
  pending := [];
  p

let lock_of name field = Hashtbl.find_opt fields (name, field)
