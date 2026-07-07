open Ast

type struct_info = {
  fields: (string * Ast.type_expr) list;
  is_packed: bool;
  align_opt: int option;
}

let structs : (string, struct_info) Hashtbl.t = Hashtbl.create 16
let enums   : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 8
let in_progress : (string, unit) Hashtbl.t = Hashtbl.create 16

let reset () =
  Hashtbl.reset structs;
  Hashtbl.reset enums;
  Hashtbl.reset in_progress

let register_enum name underlying =
  Hashtbl.replace enums name underlying

let begin_struct name =
  Hashtbl.replace in_progress name ()

let finish_struct name fields is_packed align_opt =
  Hashtbl.replace structs name { fields; is_packed; align_opt };
  Hashtbl.remove in_progress name

let fail pos msg = raise (Types.TypeError (pos, msg))

let target_data () = !Llvm_gen.target_data

let ptr_size_align () =
  match target_data () with
  | Some dl ->
      let sz = Llvm_target.DataLayout.pointer_size dl in
      (sz, sz)
  | None -> (8, 8)

let primitive_size_align ty =
  match ty with
  | TypeBool ->
      (match target_data () with
       | Some dl ->
           let llty = Llvm.i1_type Llvm_gen.context in
           (Int64.to_int (Llvm_target.DataLayout.abi_size llty dl),
            Llvm_target.DataLayout.abi_align llty dl)
       | None -> (1, 1))
  | TypeI8 | TypeU8 -> (1, 1)
  | TypeI16 | TypeU16 -> (2, 2)
  | TypeI32 | TypeU32 -> (4, 4)
  | TypeI64 | TypeU64 -> (8, 8)
  | TypeIsize | TypeUsize -> ptr_size_align ()
  | _ -> failwith "primitive_size_align: not a primitive integer"

let align_up n a =
  if a <= 1 then n else ((n + a - 1) / a) * a

let rec size_align_of_type pos seen ty =
  match ty with
  | TypeBool | TypeI8 | TypeI16 | TypeI32 | TypeI64
  | TypeU8 | TypeU16 | TypeU32 | TypeU64
  | TypeIsize | TypeUsize -> primitive_size_align ty
  | TypeVoid -> fail pos "sizeof(void) is not allowed"
  | TypeBorrow t -> size_align_of_type pos seen t
  | TypePtr _ | TypeFn _ -> ptr_size_align ()
  | TypeIo t -> size_align_of_type pos seen t
  | TypeRefined (_, _, base) -> size_align_of_type pos seen base
  | TypeArray (elem, n) ->
      let (esz, ealign) = size_align_of_type pos seen elem in
      (esz * n, ealign)
  | TypeSlice (_, _) ->
      let (psz, palign) = ptr_size_align () in
      let (lsz, lalign) = size_align_of_type pos seen TypeUsize in
      let off = align_up 0 palign + psz in
      let off = align_up off lalign + lsz in
      let align = max palign lalign in
      (align_up off align, align)
  | TypeNamed name ->
      (match Hashtbl.find_opt enums name with
       | Some underlying -> size_align_of_type pos seen underlying
       | None ->
           if List.mem name seen || Hashtbl.mem in_progress name then
             fail pos (Printf.sprintf "recursive sizeof(%s) is not supported" name)
           else
             match Hashtbl.find_opt structs name with
             | None -> fail pos (Printf.sprintf "unknown type '%s' in sizeof" name)
             | Some { fields; is_packed; align_opt } ->
                 let rec walk offset max_align = function
                   | [] ->
                       let struct_align =
                         match align_opt with
                         | Some n -> n
                         | None -> if is_packed then 1 else max_align
                       in
                       (align_up offset struct_align, struct_align)
                   | (_, field_ty) :: rest ->
                       let (fsz, falign) = size_align_of_type pos (name :: seen) field_ty in
                       let falign = if is_packed then 1 else falign in
                       let offset = align_up offset falign in
                       walk (offset + fsz) (max max_align falign) rest
                 in
                 walk 0 1 fields)

let sizeof_type pos ty =
  let (sz, _) = size_align_of_type pos [] ty in
  sz
