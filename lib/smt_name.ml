(* One injective encoding for every z3 constant name (GitHub issue #1394;
   see smt_name.mli).

   [esc] keeps [A-Za-z0-9], doubles '_', and writes any other byte as '_'
   and two UPPERCASE hex digits. Its output is a prefix code: after a '_'
   comes another '_' or [0-9A-F], never anything else. Every name starts
   "x_". An atom continues with [esc] of its text, so its third character
   is alphanumeric, a '_' followed by '_', or a '_' followed by a hex digit.
   Every other kind continues with "_" and a lowercase tag letter that is
   not a hex digit (p, v, g, e), which no atom can produce; and an enum
   separates its two escaped names with "_S", which [esc] never emits. So
   distinct values give distinct names, across kinds too. *)

type t = string

let esc s =
  let buf = Buffer.create (String.length s + 2) in
  String.iter (fun ch ->
    match ch with
    | 'a'..'z' | 'A'..'Z' | '0'..'9' -> Buffer.add_char buf ch
    | '_' -> Buffer.add_string buf "__"
    | _ -> Buffer.add_string buf (Printf.sprintf "_%02X" (Char.code ch))) s;
  Buffer.contents buf

let atom a = "x_" ^ esc a
let param id = Printf.sprintf "x__p%d" id
let var id = Printf.sprintf "x__v%d" id
let global name = "x__g" ^ esc name
let enum name case = "x__e" ^ esc name ^ "_S" ^ esc case
let to_string t = t
