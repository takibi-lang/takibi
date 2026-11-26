(* Check the resolved ext2 call graph for writes outside the undo log
   (GitHub issues #1088 and #1120). *)
module Names = Call_graph.StringSet
module Rows = Map.Make (String)

let ext2_file = "kernel/fs/ext2/ext2.tkb"
let block_file = "kernel/drivers/block/memory.tkb"
let write = "ext2_block_write"
let begin_log = "ext2_undo_begin"

let roots = [
  "ext2_truncate_regular_file_with";
  "ext2_unlink_name_with";
  "ext2_rename_over";
  "ext2_rmdir_release";
  "ext2_create_file_in_with";
  "ext2_create_empty_file_in_with";
  "ext2_make_directory_in_with";
  "ext2_rename_new";
]

let writers = [
  "ext2_undo_write";       (* Append the landed write to the log. *)
  "ext2_undo_put_back";    (* Restore the logged range on rollback. *)
  "ext2_release_commit";   (* Free the blocks before recount and scrub. *)
  "ext2_walk_visit";       (* Only the commit's scrub mode writes. *)
  "ext2_claimed_write";    (* Write to a block whose bit is still clear. *)
  "ext2_create_commit";    (* Claim the new blocks before recount. *)
]

let direct_writes callees =
  Names.fold (fun label found ->
    let name = Call_graph.reference_name label in
    let file = Call_graph.reference_file label in
    if (name = write && file = ext2_file) ||
       (name = "block_write" && file = block_file)
    then Names.add name found else found
  ) callees Names.empty

let problems rows callees =
  let missing = List.filter_map (fun name ->
    if Rows.mem name rows then None else Some (Printf.sprintf
      "%s is not defined in %s; a rename would leave this check matching nothing"
      name ext2_file)) (roots @ writers) in
  if missing <> [] then Error missing else
  let root_names = Names.of_list roots and writer_names = Names.of_list writers in
  let rec walk seen errors = function
    | [] -> seen, List.rev errors
    | name :: pending when Names.mem name seen -> walk seen errors pending
    | name :: pending ->
        let seen = Names.add name seen in
        if Names.mem name writer_names then walk seen errors pending else
        let row = Rows.find name rows in
        let called = callees row in
        let at = Printf.sprintf "%s:%d %s" ext2_file row.Ast.def_loc.Lexing.pos_lnum name in
        let direct = direct_writes called in
        let errors =
          if Names.is_empty direct then errors else
          Printf.sprintf
            "%s is reached from a release and calls %s itself. A release or create writes through ext2_undo_save/ext2_undo_write and frees or claims its blocks in ext2_release_commit or ext2_create_commit, so a rejected write can be put back (GitHub issues #1088, #1120); route the write through the log, or name the writer with the reason"
            at (String.concat ", " (Names.elements direct)) :: errors in
        let errors =
          if Names.mem name root_names ||
             not (Names.exists (fun label -> Call_graph.reference_name label = begin_log)
                    called) then errors else
          Printf.sprintf
            "%s is reached from a release and opens its own undo log (%s), which commits outside the release's rollback (GitHub issue #1088); pass the release's log down instead"
            at begin_log :: errors in
        let pending = Names.fold (fun label pending ->
          if Call_graph.reference_file label = ext2_file
          then Call_graph.reference_name label :: pending else pending
        ) called pending in
        walk seen errors pending
  in
  let reached, errors = walk Names.empty [] (List.rev roots) in
  let unreachable_writers = List.filter_map (fun name ->
    if Names.mem name reached then None else
    Some (name ^ " is allowed to write but no release reaches it: remove the entry")
  ) writers in
  match errors @ unreachable_writers with
  | [] -> Ok (Names.cardinal reached, List.length roots, List.length writers)
  | errors -> Error errors

let check (graph : Call_graph.graph) =
  let rows = List.fold_left (fun rows definitions ->
    let f = List.hd definitions in
    if Call_graph.function_file f = ext2_file
    then Rows.add (Call_graph.function_name f) f rows else rows
  ) Rows.empty graph.definitions in
  match problems rows graph.callees with
  | Error _ as error -> error
  | Ok _ as success ->
      let subject = "ext2_inode_clear_logged" in
      let refused callee =
        let callees f =
          let calls = graph.callees f in
          if Call_graph.function_name f = subject then
            Names.add (Printf.sprintf "%s@%s:1" callee ext2_file) calls
          else calls in
        Result.is_error (problems rows callees) in
      if Rows.mem subject rows && refused write && refused begin_log then success else
      Error ["a negative control (a logged helper calling ext2_block_write, or opening its own log) was accepted"]
