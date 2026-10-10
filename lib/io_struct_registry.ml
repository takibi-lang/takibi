(* GitHub issue #637 stage 3, step A: register blocks. `io struct Name
   { f: u32 at 0x18; ... }` is laid out at the declared offsets, with the
   gaps filled by reserved byte arrays, and every access to its fields is
   volatile. The parser records the names here. *)

let structs : (string, unit) Hashtbl.t = Hashtbl.create 8

let reset () = Hashtbl.reset structs
let mark name = Hashtbl.replace structs name ()
let is_io name = Hashtbl.mem structs name

(* Size and alignment of a register field's type, known at parse time:
   fixed-width integers and arrays of them. *)
let rec size_align (t : Ast.type_expr) =
  match t with
  | Ast.TypeU8 | Ast.TypeI8 -> Some (1, 1)
  | Ast.TypeU16 | Ast.TypeI16 -> Some (2, 2)
  | Ast.TypeU32 | Ast.TypeI32 -> Some (4, 4)
  | Ast.TypeU64 | Ast.TypeI64 | Ast.TypeUsize -> Some (8, 8)
  | Ast.TypeArray (elem, n) ->
      Option.map (fun (s, a) -> (s * n, a)) (size_align elem)
  | _ -> None

(* Lay the fields out at their offsets: sorted, each naturally aligned, no
   overlap, gaps as `__io_gap<n>: [u8; k]`. Errors name the field. *)
let layout (fields : (string * Ast.type_expr * int) list) =
  let sorted = List.stable_sort (fun (_, _, a) (_, _, b) -> compare a b) fields in
  let gap = ref 0 in
  let rec go cursor acc = function
    | [] -> Ok (List.rev acc)
    | (name, ty, offset) :: rest ->
        (match size_align ty with
         | None -> Error (Printf.sprintf
             "io struct field '%s' must be a fixed-width integer or an array of them" name)
         | Some (size, align) ->
             if offset mod align <> 0 then
               Error (Printf.sprintf
                 "io struct field '%s' at 0x%x is not %d-byte aligned" name offset align)
             else if offset < cursor then
               Error (Printf.sprintf
                 "io struct field '%s' at 0x%x overlaps the field before it (which ends at 0x%x)"
                 name offset cursor)
             else
               let acc =
                 if offset > cursor then begin
                   incr gap;
                   (Printf.sprintf "__io_gap%d" !gap,
                    Ast.TypeArray (Ast.TypeU8, offset - cursor)) :: acc
                 end else acc
               in
               go (offset + size) ((name, ty) :: acc) rest)
  in
  go 0 [] sorted
