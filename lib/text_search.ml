(* Substring search without allocating (#917). Comparing String.sub at
   every position allocates a string per position; on the printed kernel
   that was most of the compiler's front end. scripts/check_text_search.py
   refuses that shape in lib/ and bin/. *)

(* Whether [sub] occurs in [s] at [i]. *)
let sub_at s i sub =
  let m = String.length sub in
  i >= 0 && i + m <= String.length s &&
  (let rec go k = k = m || (String.unsafe_get s (i + k) = String.unsafe_get sub k
                            && go (k + 1)) in
   go 0)

(* The first occurrence of [sub] in [s] at or after [i], or -1. The first
   character is found by String.index_from, which is a C loop. *)
let rec find_sub s i sub =
  if sub = "" then (if i <= String.length s then i else -1)
  else if i >= String.length s then -1
  else match String.index_from_opt s i sub.[0] with
    | None -> -1
    | Some k -> if sub_at s k sub then k else find_sub s (k + 1) sub

(* Whether [sub] occurs anywhere in [s]; the empty string always does. *)
let contains s sub = find_sub s 0 sub >= 0
