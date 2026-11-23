(* Erased lock declarations recorded by the parser and checked after types
   and overloads have resolved. Nothing in this registry reaches lowering. *)
type field =
  | Word of { field : string; free : int64; held : int64 }
  | Owner of { field : string; projector : string; lock : string }

type operation = Acquire | Release
type contract = { operation : operation; parameter : string }

let pending = ref []
let field_table : (string, field * Ast.loc) Hashtbl.t = Hashtbl.create 4
let contracts : (string * int * int, contract) Hashtbl.t = Hashtbl.create 4

let reset () =
  pending := [];
  Hashtbl.clear field_table;
  Hashtbl.clear contracts

let note field loc = pending := (field, loc) :: !pending

let finish name accepts =
  let declared = !pending in
  pending := [];
  match declared with
  | [] -> ()
  | [field, loc] when accepts field -> Hashtbl.replace field_table name (field, loc)
  | (_, loc) :: _ ->
      raise (Types.TypeError (loc,
        "expected one lockword on a plain struct or one owns_lock on a linear struct"))

let finish_function loc effects =
  let projected = function
    | text when String.starts_with ~prefix:"acquires(" text -> Some (Acquire, 9)
    | text when String.starts_with ~prefix:"releases(" text -> Some (Release, 9)
    | _ -> None in
  Option.map (List.filter (fun text ->
    match projected text with
    | None -> true
    | Some (operation, start) ->
        let key = Init_state.loc_key loc in
        if Hashtbl.mem contracts key then
          raise (Types.TypeError (loc, "a function can declare one projected lock transition"));
        let parameter = String.sub text start (String.length text - start - 1) in
        Hashtbl.add contracts key {operation; parameter};
        false)) effects

let contract loc = Hashtbl.find_opt contracts (Init_state.loc_key loc)
let fields () =
  Hashtbl.fold (fun name (field, loc) all -> (name, field, loc) :: all) field_table []
let enabled () = Hashtbl.length field_table > 0 || Hashtbl.length contracts > 0

let owner_field name =
  match Hashtbl.find_opt field_table name with
  | Some (Owner {field; _}, _) -> Some field
  | _ -> None

let projects_member name =
  Hashtbl.fold (fun _ (field, _) found ->
    found || match field with Owner {lock; _} -> lock = name | Word _ -> false)
    field_table false
