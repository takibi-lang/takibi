(* Erased linked-initialization certificates. A certificate says that every
   in-bounds node reachable from a value is initialized in one storage object.
   It says nothing about bounds, acyclicity, ownership or concurrency. The
   flow checker supplies binding identities, proves terminal values, and
   invalidates certificates when storage can be changed through an alias. *)
module Storage = struct
  type t = string * string list
  let compare = compare
end
module Storages = Set.Make (Storage)
module Values = Map.Make (String)

type storage = Storage.t
type t = Storages.t Values.t

let empty = Values.empty
let certificates state value =
  match Values.find_opt value state with Some s -> s | None -> Storages.empty

let ready state ~full storage value =
  full || Storages.mem storage (certificates state value)

let establish state storage value =
  Values.add value (Storages.add storage (certificates state value)) state

let forget_value state value = Values.remove value state

let copy state ~target ~source =
  let s = certificates state source in
  if Storages.is_empty s then forget_value state target
  else Values.add target s state

let invalidate state storage =
  Values.filter_map (fun _ s ->
    let s = Storages.remove storage s in
    if Storages.is_empty s then None else Some s) state

let invalidate_root state root =
  Values.filter_map (fun _ s ->
    let s = Storages.filter (fun (r, _) -> r <> root) s in
    if Storages.is_empty s then None else Some s) state

(* Calls may overwrite scalar certificates as well as link memory. Copies
   of an old scalar remain certified if its link storage is unchanged. *)
let invalidate_path state (root, path) =
  let rec prefix a b = match a, b with
    | [], _ -> true
    | x :: xs, y :: ys when x = y -> prefix xs ys
    | _ -> false in
  let key = root ^ ":" ^ (if path = [] then "" else "." ^ String.concat "." path) in
  Values.filter_map (fun value storages ->
    let overwritten = value = key || String.starts_with
      ~prefix:(if path = [] then key else key ^ ".") value in
    if overwritten then None else
      let storages = Storages.filter (fun (r, p) ->
        r <> root || not (prefix path p || prefix p path)) storages in
      if Storages.is_empty storages then None else Some storages) state

let join left right =
  Values.merge (fun _ a b -> match a, b with
    | Some a, Some b ->
        let s = Storages.inter a b in
        if Storages.is_empty s then None else Some s
    | _ -> None) left right

(* The caller separately checks the actual store's index. Overwriting a
   node with a certified successor preserves every old certificate and
   establishes one for the written node. Otherwise every predecessor might
   reach that node, so all certificates for this storage must be forgotten.
   A full array remains fully initialized after any initialized scalar store. *)
let store state ~full storage ~index ~successor =
  if ready state ~full storage successor then establish state storage index
  else invalidate state storage

(* Reading the successor transfers the certificate to the loaded scalar.
   A false return grants nothing; ordinary initialization diagnostics apply.
   Numeric values must not be confused with a mutable binding's later value. *)
let load state ~full storage ~index ~target =
  let proven = ready state ~full storage index in
  let state = forget_value state target in
  if proven then Some (establish state storage target) else None
