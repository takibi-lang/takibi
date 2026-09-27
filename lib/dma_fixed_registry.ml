(* Fixed DMA record declarations. A marked record has one compiler-known
   allocation and its fields may only be accessed through ownership-aware
   operations. The registry is populated by the parser and reset per parse. *)

let pending : (string, unit) Hashtbl.t = Hashtbl.create 8
let records : (string, (string * Ast.type_expr) list) Hashtbl.t =
  Hashtbl.create 8
let allocations : (string, string) Hashtbl.t = Hashtbl.create 8

let reset () =
  Hashtbl.reset pending;
  Hashtbl.reset records;
  Hashtbl.reset allocations

let mark name = Hashtbl.replace pending name ()

let finish name fields =
  if Hashtbl.mem pending name then begin
    Hashtbl.replace records name fields;
    Hashtbl.remove pending name
  end

let is_fixed name = Hashtbl.mem records name
let fields_of name = Hashtbl.find_opt records name
let register_allocation record global =
  Hashtbl.replace allocations record global
let allocation_of record = Hashtbl.find_opt allocations record

let cpu_token record = record ^ "Cpu"
let device_token record = record ^ "Device"
let authority_variant record = record ^ "Authority"
let slot_type record = record ^ "Slot"
let slot_global record = "dma_owner_" ^ record

let record_of_token name =
  Hashtbl.fold (fun record _ found ->
    if name = cpu_token record || name = device_token record
    then Some record else found) records None

let record_of_slot_type name =
  Hashtbl.fold (fun record _ found ->
    if name = slot_type record then Some record else found) records None

let is_initial_authority_variant name =
  Hashtbl.fold (fun record _ found ->
    found || name = authority_variant record) records false

let rec type_contains_slot record = function
  | Ast.TypeNamed name | Ast.TypeIndexed (name, _) ->
      name = slot_type record
  | Ast.TypeArray (ty, _) | Ast.TypeArraySym (ty, _)
  | Ast.TypeIo ty | Ast.TypeSingleton (ty, _)
  | Ast.TypeRefined (_, _, ty) | Ast.TypeMultiple (_, ty) ->
      type_contains_slot record ty
  | _ -> false

let rec type_mentions_token = function
  | Ast.TypeNamed name | Ast.TypeIndexed (name, _) ->
      Option.is_some (record_of_token name)
      || is_initial_authority_variant name
      || Option.is_some (record_of_slot_type name)
  | Ast.TypePtr ty | Ast.TypeAlignedPtr (_, ty) | Ast.TypeIo ty
  | Ast.TypeArray (ty, _) | Ast.TypeSlice (ty, _)
  | Ast.TypeBorrow ty | Ast.TypeBorrowMut ty | Ast.TypeSink ty
  | Ast.TypeSingleton (ty, _) | Ast.TypeRefined (_, _, ty)
  | Ast.TypeMultiple (_, ty) | Ast.TypeExists (_, _, ty)
  | Ast.TypeArraySym (ty, _) | Ast.TypeSliceSym (ty, _) ->
      type_mentions_token ty
  | Ast.TypeTuple tys -> List.exists type_mentions_token tys
  | Ast.TypeFn (args, ret, _) ->
      List.exists type_mentions_token args || type_mentions_token ret
  | _ -> false
