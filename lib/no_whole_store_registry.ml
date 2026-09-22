(* Names declared with `struct no_whole_store`. A place has stable storage identity:
   assigning its whole value would overwrite state behind its API. The parser
   records declarations here so the checker can reject such stores. *)

let names : (string, unit) Hashtbl.t = Hashtbl.create 8

let reset () = Hashtbl.reset names
let mark name = Hashtbl.replace names name ()
let is_place name = Hashtbl.mem names name
