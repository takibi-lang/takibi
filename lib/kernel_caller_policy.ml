(* Explicit maintained-kernel policy over the same compiled definitions and
   resolved references as the call graph facts. *)
module Names = Call_graph.StringSet
module Callers = Set.Make (struct
  type t = string * string
  let compare = compare
end)
module By_name = Map.Make (String)

exception Rule_error of string

type rule = {
  name : string;
  target : string;
  allowed : Callers.t;
  issue : string;
  reason : string;
}

let read_rules path =
  In_channel.with_open_text path (fun input ->
    let rec read number seen rules =
      match In_channel.input_line input with
      | None when rules = [] -> raise (Rule_error (path ^ ": no rules"))
      | None -> List.rev rules
      | Some line when String.trim line = "" || String.starts_with ~prefix:"#" line ->
          read (number + 1) seen rules
      | Some line ->
          let bad message = raise (Rule_error (Printf.sprintf "%s:%d: %s" path number message)) in
          let fields = String.split_on_char '\t' line in
          match fields with
          | [name; target; paths; issue; reason]
              when List.for_all (fun field -> String.trim field <> "") fields ->
              if Names.mem name seen then bad ("duplicate check " ^ name);
              let allowed = List.fold_left (fun allowed caller ->
                match String.index_opt caller ':' with
                | Some colon when colon > 0 && colon < String.length caller - 1 ->
                    let file = String.sub caller 0 colon in
                    let fn = String.sub caller (colon + 1) (String.length caller - colon - 1) in
                    if not (Sys.file_exists file) || Sys.is_directory file then
                      bad ("caller file " ^ file ^ " does not exist");
                    Callers.add (file, fn) allowed
                | _ -> bad ("caller " ^ caller ^ " is not file:function")
              ) Callers.empty (String.split_on_char ',' paths) in
              read (number + 1) (Names.add name seen) ({name; target; allowed; issue; reason} :: rules)
          | _ -> bad "expected five nonempty tab-separated fields"
    in read 1 Names.empty [])

let check path (graph : Call_graph.graph) =
  try
    let rules = read_rules path in
    let rows = List.map List.hd graph.definitions in
    if rows = [] then raise (Rule_error "compiled call graph has no rows");
    let ids f = Call_graph.function_file f, Call_graph.function_name f in
    let files = List.fold_left (fun set f -> Names.add (fst (ids f)) set) Names.empty rows in
    let targets = List.fold_left (fun set rule -> Names.add rule.target set) Names.empty rules in
    let add found row label =
      let name = Call_graph.reference_name label in
      if Names.mem name targets then
        By_name.update name (fun old ->
          Some (Callers.add row (Option.value old ~default:Callers.empty))) found
      else found in
    let gather accessor = List.fold_left (fun found f ->
      Names.fold (fun edge acc -> add acc (ids f) edge) (accessor f) found
    ) By_name.empty rows in
    let calls = gather graph.callees and values = gather graph.values in
    let find table name = Option.value (By_name.find_opt name table) ~default:Callers.empty in
    let kernel_rows = List.filter_map (fun f ->
      let file, _ as pair = ids f in
      if String.starts_with ~prefix:"kernel/" file then Some pair else None) rows in
    let count, problems = List.fold_left (fun (count, issues) rule ->
      let allowed = Callers.filter (fun (file, _) -> Names.mem file files) rule.allowed in
      let direct = find calls rule.target and indirect_uses = find values rule.target in
      let differences direct indirect_uses =
        let seen = Callers.union direct indirect_uses in
        Callers.diff seen allowed, Callers.diff allowed seen in
      let valid direct indirect_uses =
        let unexpected, absent = differences direct indirect_uses in
        Callers.is_empty unexpected && Callers.is_empty absent in
      let unexpected, absent = differences direct indirect_uses in
      let decorate message = rule.name ^ ": " ^ message in
      let errors =
        List.map (fun (file, fn) -> decorate (Printf.sprintf "%s: %s uses %s; %s (%s)"
          file fn rule.target rule.reason rule.issue)) (Callers.elements unexpected) @
        List.map (fun (file, fn) -> decorate (Printf.sprintf "%s: %s no longer calls %s"
          file fn rule.target)) (Callers.elements absent) in
      let errors = if errors <> [] then errors else
        match List.find_opt (fun pair -> not (Callers.mem pair allowed)) kernel_rows with
        | None -> [decorate "no compiled kernel function for the negative controls"]
        | Some victim ->
            if valid (Callers.add victim direct) indirect_uses ||
               valid direct (Callers.add victim indirect_uses) ||
               (not (Callers.is_empty allowed) && valid Callers.empty Callers.empty)
            then [decorate "a negative control was accepted"] else [] in
      count + Callers.cardinal allowed, List.rev_append errors issues
    ) (0, []) rules in
    if problems = [] then Ok (List.length rules, count) else Error (List.rev problems)
  with Rule_error message | Sys_error message -> Error [message]
