open Ast
open Types

module StringSet = Set.Make (String)

type error = Unknown_entry of string | Unknown_check_file of string | Unused of func

let check ~external_entries ~check_files (prog : toplevel list) (types : program_types) =
  let definitions = List.filter_map (function FuncDef f -> Some f | _ -> None) prog in
  let key_of f = StringMap.find (loc_key f.def_loc) types.function_def_keys in
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
  let rec expr from (e : expr) =
    (match StringMap.find_opt (loc_key e.loc) types.function_values with
     | Some target -> add_reference from target | None -> ());
    match e.desc with
    | Call (_, args) ->
        (match StringMap.find_opt (loc_key e.loc) types.call_targets with
         | Some target -> add_reference from target | None -> ());
        List.iter (expr from) args
    | VariantCtor (_, _, x) | Bnot x | Deref x | AddrOf x | Cast (_, x)
    | FieldGet (x, _) | Unsafe x -> expr from x
    | BinOp (_, a, b) | Index (a, b) | Assign (a, b) -> expr from a; expr from b
    | SliceOf (base, lo, hi) -> expr from base; expr from lo; expr from hi
    | StructLit xs | TupleLit xs -> List.iter (expr from) xs
    | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _ | ViewLit _
    | EnumVariant _ | SizeOf _ | ContainsStableOwner _ | AlignOf _ | OffsetOf _
    | EmbedFile _ -> ()
  and stmt from (s : stmt) = match s.desc with
    | Return (Some e) | Expr e | Yield e | LetTuple (_, e) | StaticAssert (e, _) -> expr from e
    | Return None | Break | Continue -> ()
    | Block ss | UnsafeBlock ss -> List.iter (stmt from) ss
    | Let (_, _, _, init, _) -> Option.iter (expr from) init
    | If (c, yes, no) -> expr from c; List.iter (stmt from) yes; List.iter (stmt from) no
    | While (c, body) -> expr from c; List.iter (stmt from) body
    | For (_, _, lo, hi, body) -> expr from lo; expr from hi; List.iter (stmt from) body
    | ForEach (_, collection, body) -> expr from collection; List.iter (stmt from) body
    | Match (subject, arms) | LetMatch (_, _, _, subject, arms) ->
        expr from subject;
        List.iter (function
          | ArmVariant (_, _, _, body) | ArmWild body | ArmIntLit (_, body)
          | ArmByteSliceLit (_, body) -> List.iter (stmt from) body) arms
  in
  List.iter (fun f -> List.iter (stmt (Some (key_of f))) f.body) definitions;
  List.iter (fun (f : Ast.func) -> match f.effects with
    | Some effects when List.mem "interrupt" effects || List.mem "exception" effects ->
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
    | ConstDef (_, _, init, _) | LetDef (_, _, Some init, _, _, _, _) -> expr None init
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
  let normalized_file file = Filename.concat (Sys.getcwd ()) file in
  let def_file f =
    let file = Ast.source_file_of_loc f.def_loc in
    if Filename.is_relative file then normalized_file file else file in
  let check_errors = List.filter_map (fun file ->
    let file = normalized_file file in
    let matches = List.filter (fun f -> def_file f = file) definitions in
    if matches = [] then Some (Unknown_check_file file) else None) check_files in
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
    (check_files = [] || List.exists (fun file -> def_file f = normalized_file file) check_files) in
  entry_errors @ check_errors @ List.filter_map (fun f ->
    if not (is_candidate f) || StringSet.mem (key_of f) reachable
    then None else Some (Unused f)) definitions
