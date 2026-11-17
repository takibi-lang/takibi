(* Erased entry requirements for preserving initialization frames. Local
   storage identities are used only while checking a caller, never exported
   as an inferred entry condition. Paths denote inline storage, not pointees. *)
type root = Parameter of int | Global of string | Local of int
type place = root * string list
module Conditions = Set.Make (struct
  type t = place * place
  let compare = compare
end)
type verdict = Proven | Required of (place * place) | Overlap
let ordered a b = if compare a b <= 0 then (a, b) else (b, a)
let rec prefix a b = match a, b with
  | [], _ -> true
  | x :: xs, y :: ys when x = y -> prefix xs ys
  | _ -> false
let classify ((ra, pa) as a) ((rb, pb) as b) =
  if ra = rb then
    if prefix pa pb || prefix pb pa then Overlap else Proven
  else match ra, rb with
    | Local _, _ | _, Local _ | Global _, Global _ -> Proven
    | _ -> Required (ordered a b)
let show_place (root, path) =
  (match root with
   | Parameter i -> Printf.sprintf "parameter %d" (i + 1)
   | Global name -> "global " ^ name
   | Local i -> Printf.sprintf "local #%d" i)
  ^ (if path = [] then "" else "." ^ String.concat "." path)
let show (a, b) = show_place a ^ " disjoint from " ^ show_place b
