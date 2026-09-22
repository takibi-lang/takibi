(* Names declared with `struct no_copy`. Their storage identity matters, so
   whole-value stores and copies must not bypass their field API. *)

let names : (string, unit) Hashtbl.t = Hashtbl.create 8

let reset () = Hashtbl.reset names
let mark name = Hashtbl.replace names name ()
let is_no_copy name = Hashtbl.mem names name
