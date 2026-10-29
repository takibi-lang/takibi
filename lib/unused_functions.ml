open Ast
open Types

module StringSet = Set.Make (String)

type error = Unknown_entry of string | Missing_check_file of string
  | Unknown_check_file of string | Unused of func

let check ~external_entries ~check_files (prog : toplevel list) (types : program_types) =
  let definitions = List.filter_map (function FuncDef f -> Some f | _ -> None) prog in
  let key_of f = Call_graph.definition_key types f in
  let by_name = List.fold_left (fun m f ->
    let old = Option.value (StringMap.find_opt f.name m) ~default:[] in
    StringMap.add f.name (key_of f :: old) m
  ) StringMap.empty definitions in
  let defined = List.fold_left (fun s f -> StringSet.add (key_of f) s)
      StringSet.empty definitions in
  let edges = ref StringMap.empty in
  let roots = ref StringSet.empty in
  let add_reference from target =
    if StringSet.mem target defined then match from with
    | None -> roots := StringSet.add target !roots
    | Some caller ->
        let old = Option.value (StringMap.find_opt caller !edges) ~default:StringSet.empty in
        edges := StringMap.add caller (StringSet.add target old) !edges
  in
  (* GitHub issue #987: the edges come from the traversal --facts callgraph.tsv
     writes, so the two cannot disagree about what calls what. *)
  Call_graph.iter_references (fun from reference target ->
    match reference with
    | Call_graph.Call | Call_graph.Value -> add_reference from target
    | Call_graph.Indirect -> ()) prog types;
  List.iter (fun (f : Ast.func) -> match f.effects with
    | Some effects when List.mem "interrupt" effects || List.mem "exception" effects
                     || List.mem "nmi" effects ->
        roots := StringSet.add (key_of f) !roots
    | _ -> ()) definitions;
  (* GitHub issue #540: a function whose whole body is static_assert
     statements exists to hold them, and does its job by being compiled --
     the type checker evaluates them whether or not anything calls it. The
     kernel's *_execution_model_assumption functions are that shape by
     design, and reporting them made the check unusable beyond one file. A
     function that does anything else besides is still a function nobody
     calls. *)
  List.iter (fun (f : Ast.func) ->
    let assertion_only (s : stmt) =
      match s.desc with StaticAssert _ -> true | _ -> false in
    if f.body <> [] && List.for_all assertion_only f.body then
      roots := StringSet.add (key_of f) !roots) definitions;
  List.iter (function
    | VectorTableDef (entries, _) ->
        List.iter (fun (_, name) ->
          List.iter (add_reference None)
            (Option.value (StringMap.find_opt name by_name) ~default:[])) entries
    (* Every hook an exception entry or restore names is called by the code
       the compiler generates for it -- `before`, `dispatch`, `after_switch`,
       `stack_guard_handler` alike -- so each is a root. GitHub issue #540's
       measurement found the check reading only `dispatch` and `before`, and
       reporting kernel_process_stack_switch_complete and
       kernel_stack_overflow_fail_stop, which every exception return and
       every stack-guard trip reaches. A field whose value is not a function
       (`frame`, `stack_guard_shift`) finds nothing in by_name. *)
    | ExceptionEntryDef (_, fields, _) | ExceptionRestoreDef (_, fields, _) ->
        List.iter (fun (_, name) ->
          List.iter (add_reference None)
            (Option.value (StringMap.find_opt name by_name) ~default:[])) fields
    | _ -> ()) prog;
  let entry_errors = List.filter_map (fun name -> match StringMap.find_opt name by_name with
    | None -> Some (Unknown_entry name)
    | Some keys -> List.iter (fun key -> roots := StringSet.add key !roots) keys; None)
      external_entries in
  (* The working directory and each definition's file are read once: per
     definition and check file they were quadratic in the kernel (#917). *)
  let cwd = Sys.getcwd () in
  let normalized_file file = Filename.concat cwd file in
  let def_file f =
    let file = Ast.source_file_of_loc f.def_loc in
    if Filename.is_relative file then normalized_file file else file in
  let def_files = List.fold_left (fun acc f -> StringSet.add (def_file f) acc)
      StringSet.empty definitions in
  let check_set = List.fold_left (fun acc file ->
      StringSet.add (normalized_file file) acc) StringSet.empty check_files in
  let check_errors = List.filter_map (fun file ->
    if not (Sys.file_exists file) then Some (Missing_check_file file) else
    let file = normalized_file file in
    if not (StringSet.mem file def_files) then Some (Unknown_check_file file)
    else None) check_files in
  let rec close seen pending = match StringSet.choose_opt pending with
    | None -> seen
    | Some key ->
        let pending = StringSet.remove key pending in
        if StringSet.mem key seen then close seen pending else
          let next = Option.value (StringMap.find_opt key !edges) ~default:StringSet.empty in
          close (StringSet.add key seen) (StringSet.union pending next)
  in
  let reachable = close StringSet.empty !roots in
  let is_candidate f =
    (* Monomorphized copies use '$' in their compiler-generated name. Their
       source template is checked through every concrete call site, while a
       speculative copy emitted for another instantiation is not a source
       declaration the programmer can remove independently. *)
    not (String.contains f.name '$') &&
    (check_files = [] || StringSet.mem (def_file f) check_set) in
  entry_errors @ check_errors @ List.filter_map (fun f ->
    if not (is_candidate f) || StringSet.mem (key_of f) reachable
    then None else Some (Unused f)) definitions

(* GitHub issue #796: --check-unused-file without --reject-unused-functions
   would be silently ignored; suspicious input is an error, never a warning. *)
let flag_error ~reject ~check_files =
  if check_files <> [] && not reject then
    Some "--check-unused-file requires --reject-unused-functions"
  else None
