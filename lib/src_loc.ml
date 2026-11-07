(* GitHub issue #1024: the opaque SrcLoc that src_loc() returns is one u32,
   file index << 20 | line. The file index is the file's position in this
   compile's table: the driver registers the `use` closure in order before
   checking, and a file not registered (a test's in-memory program) takes
   the next index when first seen. `--facts DIR` writes the table as
   srcloc.tsv, which scripts/decode_srcloc.py reads to print file:line. *)

let line_bits = 20
let max_line = (1 lsl line_bits) - 1
let max_file = (1 lsl (32 - line_bits)) - 1

let files : (string, int) Hashtbl.t = Hashtbl.create 64
let order : string list ref = ref []

let reset () = Hashtbl.reset files; order := []

let register name =
  if not (Hashtbl.mem files name) then begin
    Hashtbl.replace files name (Hashtbl.length files);
    order := name :: !order
  end

let index_of name = register name; Hashtbl.find files name

(* None when the position cannot be packed; the caller reports it. *)
let pack (pos : Lexing.position) : int64 option =
  let line = pos.pos_lnum and file = index_of pos.pos_fname in
  if line < 0 || line > max_line || file > max_file then None
  else Some (Int64.logor (Int64.shift_left (Int64.of_int file) line_bits)
               (Int64.of_int line))

let write_table path =
  let out = open_out path in
  output_string out "# index\tfile (GitHub issue #1024; SrcLoc = index << 20 | line)\n";
  List.iteri (fun i name -> Printf.fprintf out "%d\t%s\n" i name)
    (List.rev !order);
  close_out out
