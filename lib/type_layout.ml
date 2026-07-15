open Ast

type struct_info = {
  fields: (string * Ast.type_expr) list;
  is_packed: bool;
  align_opt: int option;
}

let structs : (string, struct_info) Hashtbl.t = Hashtbl.create 16
let enums   : (string, Ast.type_expr) Hashtbl.t = Hashtbl.create 8
let views   : (string, unit) Hashtbl.t = Hashtbl.create 8
let variants :
    (string, (string * Ast.type_expr option) list) Hashtbl.t =
  Hashtbl.create 8
let in_progress : (string, unit) Hashtbl.t = Hashtbl.create 16

let reset () =
  Hashtbl.reset structs;
  Hashtbl.reset enums;
  Hashtbl.reset views;
  Hashtbl.reset variants;
  Hashtbl.reset in_progress

let register_enum name underlying =
  Hashtbl.replace enums name underlying

let register_view name =
  Hashtbl.replace views name ()

let register_variant name cases =
  Hashtbl.replace variants name cases

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
  | TypeView name -> fail pos (Printf.sprintf
      "erased view '%s' has no runtime size or alignment" name)
  | TypeExists (_, _, body) -> size_align_of_type pos seen body
  | TypeBorrow t | TypeSink t | TypeSingleton (t, _) ->
      size_align_of_type pos seen t
  | TypeAlignedPtr _ -> ptr_size_align ()
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
  | TypeTuple ts ->
      (* Function-local product value (OWNERSHIP_KERNEL.md 5.9): laid out
         like a plain (non-packed) struct's fields, in declaration order,
         matching ltype_of_ast's ordinary LLVM struct_type. sizeof/offsetof
         on a bare tuple TYPE has no real use today (tuples are values,
         not named types), but this keeps size_align_of_type total rather
         than failing on a type that legitimately exists in the language. *)
      let (off, max_align) = List.fold_left (fun (offset, max_align) t ->
        let (tsz, talign) = size_align_of_type pos seen t in
        let offset = align_up offset talign in
        (offset + tsz, max max_align talign)
      ) (0, 1) ts in
      (align_up off max_align, max_align)
  | TypeVariant name ->
      (match Hashtbl.find_opt variants name with
       | None -> fail pos (Printf.sprintf "unknown variant '%s' in sizeof" name)
       | Some cases ->
           let runtime_payload = function
             | TypeExists (_, _, body) -> body
             | payload -> payload
           in
           let fields = TypeI32 :: List.filter_map (fun (_, payload) ->
             match payload with
             | None -> None
             | Some payload ->
                 let payload = runtime_payload payload in
                 (match payload with
                  | TypeView _ -> None
                  | TypeNamed view when Hashtbl.mem views view -> None
                  | _ -> Some payload)
           ) cases in
           let (off, max_align) = List.fold_left (fun (offset, max_align) t ->
             let (tsz, talign) = size_align_of_type pos seen t in
             let offset = align_up offset talign in
             (offset + tsz, max max_align talign)
           ) (0, 1) fields in
           (align_up off max_align, max_align))
  | TypeNamed name | TypeIndexed (name, _) ->
      (match Hashtbl.find_opt enums name with
       | Some underlying -> size_align_of_type pos seen underlying
       | None ->
           if Hashtbl.mem variants name then
             size_align_of_type pos seen (TypeVariant name)
           else if Hashtbl.mem views name then
             fail pos (Printf.sprintf
               "erased view '%s' has no runtime size or alignment" name)
           else if List.mem name seen || Hashtbl.mem in_progress name then
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
