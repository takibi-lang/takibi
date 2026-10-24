(* GitHub issue #988 (#567 Stage 3): --require-execution-model <path>.

   A source file that declares a mutable top-level global (`let mut`, not
   a `region` backing or `scratch` global, which keep their own rules) must
   say what makes that state safe: a `static_assert` whose condition, as
   parsed, names one of the policy file's constants, or an `exempt` entry in
   the policy file with a non-empty reason. This replaces
   scripts/check_execution_model_coverage.py, whose regular expressions
   passed on a comment that named a constant (GitHub issue #814).

   Deliberately NOT a check that the assertion is correct: the rule is "a
   file with state says something".

   Policy file, one entry per line, `#` starts a comment line:

     constant KERNEL_ACTIVE_CORES
     exempt kernel/kernel/stall_probe.tkb  reason text ...

   The exempt list is a ratchet: an entry whose file does not exist, or
   which this compilation reads and which declares no mutable global, is an
   error, as a stale --raw-mint-file entry is (GitHub issue #739). A file
   another target compiles is not read here and is skipped. *)

type policy = {
  constants : string list;
  exempt : (string * string * int) list;  (* path, reason, line *)
}

let parse_policy path =
  if not (Sys.file_exists path) then
    Error [ Printf.sprintf "--require-execution-model: policy file '%s' does not exist" path ]
  else begin
    let chan = open_in path in
    let errors = ref [] and constants = ref [] and exempt = ref [] in
    let lineno = ref 0 in
    (try
       while true do
         let line = String.trim (input_line chan) in
         incr lineno;
         let err msg = errors := Printf.sprintf "%s:%d: %s" path !lineno msg :: !errors in
         if line = "" || line.[0] = '#' then ()
         else
           let word, rest = match String.index_opt line ' ' with
             | None -> line, ""
             | Some i -> String.sub line 0 i,
                         String.trim (String.sub line i (String.length line - i)) in
           match word with
           | "constant" ->
               if rest = "" || String.contains rest ' ' then
                 err "'constant' takes exactly one name"
               else constants := rest :: !constants
           | "exempt" ->
               let file, reason = match String.index_opt rest ' ' with
                 | None -> rest, ""
                 | Some i -> String.sub rest 0 i,
                             String.trim (String.sub rest i (String.length rest - i)) in
               if file = "" then err "'exempt' needs a path"
               else if reason = "" then
                 err (Printf.sprintf
                   "exemption of '%s' has an empty reason: an exemption is a claim \
                    a reviewer can disagree with only when it says something" file)
               else if List.exists (fun (f, _, _) -> f = file) !exempt then
                 err (Printf.sprintf "'%s' is exempted twice" file)
               else exempt := (file, reason, !lineno) :: !exempt
           | _ -> err (Printf.sprintf "unknown entry '%s' (expected 'constant' or 'exempt')" word)
       done
     with End_of_file -> close_in chan);
    if !constants = [] && !errors = [] then
      errors := [ Printf.sprintf "%s: names no constant" path ];
    if !errors <> [] then Error (List.rev !errors)
    else Ok { constants = List.rev !constants; exempt = List.rev !exempt }
  end

let rec expr_names_constant constants (e : Ast.expr) =
  let go = expr_names_constant constants in
  let open Ast in
  match e.desc with
  | Var n -> List.mem n constants
  | Unsafe x | VariantCtor (_, _, x) | Bnot x | Deref x | AddrOf x
  | Cast (_, x) | FieldGet (x, _) -> go x
  | Call (_, xs) | StructLit xs | TupleLit xs -> List.exists go xs
  | BinOp (_, a, b) | Index (a, b) | Assign (a, b) -> go a || go b
  | SliceOf (a, b, c) -> go a || go b || go c
  | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | ViewLit _
  | EnumVariant _ | SizeOf _ | ContainsStableOwner _ | AlignOf _
  | OffsetOf _ | EmbedFile _ -> false

(* Files (normalized) holding a static_assert whose condition names a
   constant. A message string is never the condition, and a comment is
   never parsed, which is the #814 shape. *)
let asserting_files constants program =
  let files = ref Raw_authority_policy.Paths.empty in
  let rec stmt (s : Ast.stmt) =
    let open Ast in
    match s.desc with
    | StaticAssert (c, _) ->
        if expr_names_constant constants c then
          files := Raw_authority_policy.Paths.add
              (Raw_authority_policy.normalize (Ast.source_file_of_loc s.loc)) !files
    | UnsafeBlock b | Block b | While (_, b) | ForEach (_, _, b)
    | For (_, _, _, _, b) -> List.iter stmt b
    | If (_, a, b) -> List.iter stmt a; List.iter stmt b
    | Match (_, arms) | LetMatch (_, _, _, _, arms) -> List.iter arm arms
    | Return _ | Let _ | Expr _ | Yield _ | LetTuple _ | Break | Continue -> ()
  and arm = function
    | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmMiss b
    | Ast.ArmIntLit (_, b) | Ast.ArmByteSliceLit (_, b) -> List.iter stmt b in
  List.iter (function Ast.FuncDef f -> List.iter stmt f.Ast.body | _ -> ()) program;
  !files

(* The first mutable global of each source file, in declaration order. *)
let stateful_files program =
  List.fold_left (fun acc -> function
    | Ast.LetDef (name, _, _, _, true, _, loc)
      when not (Region_backing.is_marked name || Init_state.is_scratch name) ->
        let file = Ast.source_file_of_loc loc in
        if String.length file > 0 && file.[0] = '<' then acc else
        let key = Raw_authority_policy.normalize file in
        if List.mem_assoc key acc then acc else (key, (name, loc)) :: acc
    | _ -> acc) [] program
  |> List.rev

(* Returns errors as (location option, message). *)
let check ~policy_file ~compiled_files program =
  match parse_policy policy_file with
  | Error messages -> List.map (fun m -> (None, m)) messages
  | Ok policy ->
      let declared = List.filter_map (function
        | Ast.ConstDef (n, _, _, _) | Ast.LetDef (n, _, _, _, _, _, _) -> Some n
        | _ -> None) program in
      let undeclared = List.filter (fun c -> not (List.mem c declared)) policy.constants in
      let asserting = asserting_files policy.constants program in
      let exempt = List.map (fun (f, _, _) -> Raw_authority_policy.normalize f) policy.exempt in
      let stateful = stateful_files program in
      let silent = List.filter_map (fun (key, (name, loc)) ->
        if Raw_authority_policy.Paths.mem key asserting || List.mem key exempt then None
        else Some (Some (Ast.source_loc loc), Printf.sprintf
          "execution model: mutable global '%s' is declared in a file with no \
           static_assert naming %s (a mention in a comment does not count): \
           state that is safe only because of one of those numbers must assert \
           it, or the file must be exempted in %s with the reason it does not \
           need to" name (String.concat " or " policy.constants) policy_file)) stateful in
      let compiled = List.map Raw_authority_policy.normalize compiled_files in
      let stale = List.filter_map (fun (file, _, line) ->
        let key = Raw_authority_policy.normalize file in
        if not (Sys.file_exists file) then
          Some (None, Printf.sprintf
            "%s:%d: execution model: exempted file '%s' does not exist; remove the entry"
            policy_file line file)
        else if List.mem key compiled && not (List.mem_assoc key stateful) then
          Some (None, Printf.sprintf
            "%s:%d: execution model: exempted file '%s' declares no mutable global; \
             remove the entry rather than leaving a claim about nothing"
            policy_file line file)
        else None) policy.exempt in
      let undeclared = List.map (fun c -> (None, Printf.sprintf
        "%s: execution model: constant '%s' is not declared in this program"
        policy_file c)) undeclared in
      undeclared @ silent @ stale
