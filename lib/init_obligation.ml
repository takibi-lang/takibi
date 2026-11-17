(* Re-check finite initialization coverage over the flow checker's leaf facts.
   The required footprint is kept separate from its acceptance decision: a
   historical padding omission in that decision must still yield SAT here.
   State extraction, layout and transfer correctness remain trusted; this is
   not an independent execution model or a proof of pointer validity. *)

let membership indices =
  let rec runs start last acc = function
    | x :: xs when x = last + 1 -> runs start x acc xs
    | rest ->
        let span = if start = last then Printf.sprintf "(= k %d)" start
          else Printf.sprintf "(and (<= %d k) (< k %d))" start (last + 1) in
        let acc = span :: acc in
        match rest with
        | [] -> List.rev acc
        | x :: xs -> runs x x acc xs in
  match indices with
  | [] -> "false"
  | x :: xs ->
      match runs x x [] xs with
      | [one] -> one
      | spans -> "(or " ^ String.concat " " spans ^ ")"

(* Each entry is (leaf name, definitely initialized, required by this use).
   Numbering follows the required layout leaves, including required padding. *)
let body ~claim leaves =
  (* Irrelevant leaves cannot witness required \ initialized. Projecting to
     the footprint preserves that set difference and lets equal coverage
     questions share a solver/cache entry across unrelated record layouts. *)
  let leaves = List.filter (fun (_, _, required) -> required) leaves in
  let indices select = List.mapi (fun i (_, known, needed) ->
    if select known needed then Some i else None) leaves |> List.filter_map Fun.id in
  let known = indices (fun known _ -> known) in
  let needed = indices (fun _ needed -> needed) in
  let labels = List.mapi (fun i (name, _, _) ->
    Printf.sprintf "; leaf: %d %s\n" i name) leaves |> String.concat "" in
  Printf.sprintf
    "; takibi-init-obligation v1\n; rule: init-leaves\n; claim: %s\n%s(set-logic QF_LIA)\n(declare-const k Int)\n(assert %s)\n(assert (not %s))\n(check-sat)\n"
    claim labels (membership needed) (membership known)

let record loc ~claim leaves =
  if !Range_obligation.enabled && List.exists (fun (_, _, required) -> required) leaves
  then Range_obligation.record_text loc (body ~claim leaves)
