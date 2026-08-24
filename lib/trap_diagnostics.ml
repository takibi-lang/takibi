type group = {
  loc : Lexing.position;
  message : string;
  instances : string list;
  count : int;
}

module Key = struct
  type t = string * int * int * string
  let equal = ( = )
  let hash = Hashtbl.hash
end

module Table = Hashtbl.Make (Key)

(* Preserve source-site order. Sort instantiation names so Hashtbl-driven
   monomorphization discovery cannot perturb diagnostic output. The CLI passes
   trap_sites in source order, after reversing codegen's accumulator. *)
let group sites =
  let table = Table.create (List.length sites) in
  let order = ref [] in
  List.iter (fun (loc, message) ->
    let normalized = Ast.source_loc loc in
    let column = normalized.Lexing.pos_cnum - normalized.Lexing.pos_bol in
    let key = (Ast.source_file_of_loc normalized, normalized.Lexing.pos_lnum,
               column, message) in
    let instance = Ast.monomorphization_of_loc loc in
    match Table.find_opt table key with
    | None ->
        let instances = Option.to_list instance in
        Table.add table key { loc = normalized; message; instances; count = 1 };
        order := key :: !order
    | Some old ->
        let instances = match instance with
          | Some name when not (List.mem name old.instances) ->
              old.instances @ [name]
          | _ -> old.instances
        in
        Table.replace table key
          { old with instances; count = old.count + 1 }
  ) sites;
  List.rev_map (fun key ->
    let group = Table.find table key in
    { group with instances = List.sort String.compare group.instances }
  ) !order

let representative_limit = 3

let instantiation_note group =
  match group.instances with
  | [] -> None
  | instances ->
      let shown = List.filteri (fun i _ -> i < representative_limit) instances in
      let hidden = List.length instances - List.length shown in
      let suffix = if hidden = 0 then ""
        else Printf.sprintf ", ... (+%d more)" hidden in
      Some (Printf.sprintf
        "grouped %d trap site(s) across %d generic instantiation(s): %s%s"
        group.count (List.length instances) (String.concat ", " shown) suffix)
