(* The resolved call graph (GitHub issue #987, #567 Stage 1).

   Two consumers share one traversal here:

   - lib/unused_functions.ml closes reachability over [iter_references];
   - --emit-call-graph writes [write_table], one TSV row per function
     definition, so the build checks under scripts/ read the compiler's own
     resolution instead of re-deriving a call graph from source text with
     regular expressions. docs/CALL_GRAPH.md is the format's contract.

   The edges are the type checker's decisions, not a second resolution:
   Types.program_types.call_targets (a direct call, after overloads and
   generic instantiation), function_values (a function used as a value), and
   Type_inf.resolved_indirect_call_effects (a call through a function value,
   whose target is not known). *)

open Ast
open Types

module StringSet = Set.Make (String)

(* What one expression site refers to. The target is passed beside it, not
   inside it, so a compile without --emit-call-graph allocates nothing more
   for --reject-unused-functions than it did before the traversal was
   shared (#923's budget measures words). *)
type reference =
  | Call      (* a resolved direct call; the target is its definition key *)
  | Value     (* a function named as a value; likewise *)
  | Indirect  (* a call through a function value; the target is "" *)

(* The key type inference gives a definition. Generic instances share their
   template's def_loc (lib/monomorphize.ml copies it), so the loc-keyed
   function_def_keys holds only the last instance's key for all of them;
   a monomorphized name is unique, and overload_key returns a unique name
   unchanged, so an instance's key is its own name. Before #987, looking
   every instance up by loc attributed all their calls to one instance, and
   --reject-unused-functions reported a helper reached only through another
   instance as unused. *)
let definition_key (types : program_types) (f : func) =
  if String.contains f.name '$' then f.name
  else StringMap.find (loc_key f.def_loc) types.function_def_keys

(* The key must name one definition. A collision attributes one
   definition's calls to another, which is the #987 defect's shape; it is
   an internal error, checked on every compile that walks the graph. *)
let check_distinct_keys (types : program_types) (prog : toplevel list) =
  ignore (List.fold_left (fun seen -> function
    | FuncDef f ->
        let key = definition_key types f in
        if StringSet.mem key seen then
          failwith (Printf.sprintf
            "internal error: two function definitions share the key '%s'" key);
        StringSet.add key seen
    | _ -> seen) StringSet.empty prog)

(* Every reference in the program, with the definition key of the function
   it occurs in, or None for a global or constant initializer. *)
let iter_references (visit : string option -> reference -> string -> unit)
    (prog : toplevel list) (types : program_types) =
  check_distinct_keys types prog;
  let indirect = !Type_inf.resolved_indirect_call_effects in
  let rec expr from (e : expr) =
    (* One key per expression: loc_key formats a string, and a second one
       per call would be the only allocation the shared walk added to
       --reject-unused-functions. *)
    let key = loc_key e.loc in
    (match StringMap.find_opt key types.function_values with
     | Some target -> visit from Value target | None -> ());
    match e.desc with
    | Call (_, args) ->
        (match StringMap.find_opt key types.call_targets with
         | Some target -> visit from Call target
         | None -> if StringMap.mem key indirect then visit from Indirect "");
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
          | ArmVariant (_, _, _, body) | ArmWild body | ArmMiss body | ArmIntLit (_, body)
          | ArmByteSliceLit (_, body) -> List.iter (stmt from) body) arms
  in
  List.iter (function
    | FuncDef f -> List.iter (stmt (Some (definition_key types f))) f.body
    | ConstDef (_, _, init, _) | LetDef (_, _, Some init, _, _, _, _) -> expr None init
    | _ -> ()) prog

(* ---- The table ---------------------------------------------------------- *)

let format_version = 1

let columns = [
  "file"; "line"; "end_line"; "name"; "qualifiers"; "declared"; "effects";
  "params"; "callees"; "callers"; "values"; "body_hash" ]

(* One token of a definition: where it ends, how it is spelled, and whether
   it is word-like (an identifier, keyword, number or string) for the
   canonical spacing below. *)
type token = { stop : int; text : string; word : bool }

let spelling (tok : Parser.token) lexbuf =
  match tok with
  | Parser.STRING s -> Printf.sprintf "%S" s
  | Parser.BS_STRING s -> Printf.sprintf "bs%S" s
  (* One token spelled with its blanks, which a reformat may change. *)
  | Parser.BORROW_INIT -> "borrow init"
  | Parser.BORROW_UNINIT -> "borrow uninit"
  | _ -> Lexing.lexeme lexbuf

let is_word text =
  text <> "" &&
  (match text.[0] with
   | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '"' | '\'' -> true
   | _ -> false)

(* The file's tokens from the compiler's own lexer, so comments and layout
   are gone exactly as the parser sees them. A token's start is not usable
   for a string literal (the lexer's string rule restarts the lexeme), so
   tokens are placed by their end. None when the file cannot be read: the
   region built-ins and protocol-generated definitions have no file. *)
let lex_file file : token array option =
  match open_in_bin file with
  | exception Sys_error _ -> None
  | chan ->
      let lexbuf = Lexing.from_channel chan in
      Lexing.set_filename lexbuf file;
      let rec loop acc =
        match Lexer.read lexbuf with
        | Parser.EOF -> Some (Array.of_list (List.rev acc))
        | tok ->
            let text = spelling tok lexbuf in
            loop ({ stop = (Lexing.lexeme_end_p lexbuf).Lexing.pos_cnum;
                    text; word = is_word text } :: acc)
        | exception _ -> None
      in
      let tokens = loop [] in
      close_in chan;
      tokens

(* The tokens ending inside (start, stop], by binary search for the first. *)
let slice (tokens : token array) start stop =
  let n = Array.length tokens in
  let rec first lo hi =
    if lo >= hi then lo
    else let mid = (lo + hi) / 2 in
      if tokens.(mid).stop <= start then first (mid + 1) hi else first lo mid in
  let rec take i acc =
    if i >= n || tokens.(i).stop > stop then List.rev acc
    else take (i + 1) (tokens.(i) :: acc) in
  take (first 0 n) []

(* Canonical spelling of a token run: a blank only between two word-like
   tokens. A comma or semicolon is therefore never followed by a blank,
   which is what lets the params column separate parameters with ", ". *)
let canonical (tokens : token list) =
  let buf = Buffer.create 32 in
  ignore (List.fold_left (fun prev tok ->
    if prev && tok.word then Buffer.add_char buf ' ';
    Buffer.add_string buf tok.text; tok.word) false tokens);
  Buffer.contents buf

(* "name: type" for each parameter between the definition's first
   parenthesis and its match, split at commas outside any bracket. *)
let params_of (tokens : token list) =
  let rec to_paren = function
    | [] -> []
    | tok :: rest -> if tok.text = "(" then rest else to_paren rest in
  let rec split depth current acc = function
    | [] -> List.rev acc
    | tok :: rest ->
        let finish () = if current = [] then acc else List.rev current :: acc in
        if depth = 0 && tok.text = ")" then List.rev (finish ())
        else if depth = 0 && tok.text = "," then split depth [] (finish ()) rest
        else
          let depth = match tok.text with
            | "(" | "[" | "{" -> depth + 1
            | ")" | "]" | "}" -> depth - 1
            | _ -> depth in
          split depth (tok :: current) acc rest
  in
  split 0 [] [] (to_paren tokens)
  |> List.map (function
    | name :: colon :: ty when colon.text = ":" -> name.text ^ ": " ^ canonical ty
    | other -> canonical other)

let relative file =
  let cwd = Sys.getcwd () ^ Filename.dir_sep in
  if String.starts_with ~prefix:cwd file then
    String.sub file (String.length cwd) (String.length file - String.length cwd)
  else file

let cell = function [] -> "-" | items -> String.concat "," items

let write_table (out : out_channel) (prog : toplevel list) (types : program_types) =
  let definitions = List.filter_map (function FuncDef f -> Some f | _ -> None) prog in
  (* A row is a source definition; the instances of one generic function
     are one row, identified by their shared def_loc. *)
  let row_id (f : func) =
    (source_file_of_loc f.def_loc, f.def_loc.Lexing.pos_cnum) in
  let row_of_key = Hashtbl.create 1024 in
  let rows = Hashtbl.create 1024 in
  let order = ref [] in
  List.iter (fun (f : func) ->
    let id = row_id f in
    Hashtbl.replace row_of_key (definition_key types f) id;
    match Hashtbl.find_opt rows id with
    | Some instances -> Hashtbl.replace rows id (f :: instances)
    | None -> Hashtbl.replace rows id [f]; order := id :: !order) definitions;
  let base_name name = match String.index_opt name '$' with
    | Some i -> String.sub name 0 i | None -> name in
  let label id = match Hashtbl.find_opt rows id with
    | Some (f :: _) ->
        Printf.sprintf "%s@%s:%d" (base_name f.name)
          (relative (fst id)) f.def_loc.Lexing.pos_lnum
    | _ -> assert false in
  let empty = StringSet.empty in
  let add table id item =
    Hashtbl.replace table id
      (StringSet.add item (Option.value (Hashtbl.find_opt table id) ~default:empty)) in
  let callees = Hashtbl.create 1024 and callers = Hashtbl.create 1024
  and values = Hashtbl.create 1024 in
  let target_label key = match Hashtbl.find_opt row_of_key key with
    | Some id -> Some id, label id
    | None -> None, key ^ "@-" in
  iter_references (fun from reference key ->
    match Option.bind from (Hashtbl.find_opt row_of_key) with
    | None -> ()
    | Some id -> match reference with
      | Indirect -> add callees id "*"
      | Call ->
          let target, text = target_label key in
          add callees id text;
          Option.iter (fun target -> add callers target (label id)) target
      | Value -> add values id (snd (target_label key))) prog types;
  let lexed = Hashtbl.create 64 in
  let tokens_of file = match Hashtbl.find_opt lexed file with
    | Some tokens -> tokens
    | None -> let tokens = lex_file file in Hashtbl.replace lexed file tokens; tokens in
  Printf.fprintf out "# takibi call graph, format %d; see docs/CALL_GRAPH.md\n"
    format_version;
  output_string out (String.concat "\t" columns ^ "\n");
  List.iter (fun id ->
    let instances = Hashtbl.find rows id in
    let f = List.hd instances in
    let file = fst id in
    let extent = Def_extent.find f.def_loc in
    let span = match extent, tokens_of file with
      | Some stop, Some tokens ->
          Some (slice tokens f.def_loc.Lexing.pos_cnum stop.Lexing.pos_cnum)
      | _ -> None in
    let qualifiers = List.filter_map (fun (flag, word) ->
      if flag then Some word else None)
      [ f.is_private, "private"; f.is_inline, "inline"; f.is_noinline, "noinline" ] in
    let declared = match f.effects with
      | None -> "-" | Some [] -> "{}" | Some effects -> String.concat "," effects in
    let inferred = List.fold_left (fun acc (g : func) ->
      match StringMap.find_opt (definition_key types g) types.functions with
      | Some info -> List.fold_left (fun acc e -> StringSet.add e acc) acc info.effects
      | None -> acc) empty instances in
    let set table = match Hashtbl.find_opt table id with
      | Some s -> cell (StringSet.elements s) | None -> "-" in
    let fields = [
      relative file;
      string_of_int f.def_loc.Lexing.pos_lnum;
      (match extent with Some stop -> string_of_int stop.Lexing.pos_lnum | None -> "-");
      base_name f.name;
      cell qualifiers;
      declared;
      cell (StringSet.elements inferred);
      (match span with
       | Some tokens -> (match params_of tokens with
           | [] -> "-" | ps -> String.concat ", " ps)
       | None -> "-");
      set callees;
      set callers;
      set values;
      (match span with
       | Some tokens ->
           Digest.to_hex (Digest.string
             (String.concat " " (List.map (fun t -> t.text) tokens)))
       | None -> "-");
    ] in
    output_string out (String.concat "\t" fields ^ "\n")) (List.rev !order)
