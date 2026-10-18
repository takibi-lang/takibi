(* GitHub issue #613: a boolean compare-exchange followed by an atomic load
   of the same word is rejected. The failed compare already read the word;
   the later load is a second observation, and a holder can change between
   the two (the #556 release window). `atomic_compare_swap_*` and
   `atomic_word_compare_swap` return the value the failed instruction read,
   which is what such a caller needs.

   The rule is syntactic and per function body. A load is "after" a
   boolean compare-exchange when it is in a later statement of a statement
   list that contains the compare-exchange (at any depth), or inside the
   branches of the `if` whose condition contains it. A loop that re-reads
   the word at the top of the next iteration loads BEFORE its compare in
   source order and is not rejected: that load starts a new attempt rather
   than explaining the failed one. Two words are the same when their
   address expressions are structurally equal after ignoring locations; a
   different spelling of the same address is not caught. *)

open Ast

let intrinsic_of name =
  match Atomic_spec.cell_intrinsic name with Some i -> i | None -> name

let operation_of name =
  match Atomic_spec.find (intrinsic_of name) with
  | Some spec -> Some spec.Atomic_spec.operation
  | None -> None

(* A location-free key for the address expressions callers actually write;
   None for any other shape, which is then never compared. *)
let rec key (e : expr) : string option =
  let ( let* ) = Option.bind in
  match e.desc with
  | Var n -> Some ("v:" ^ n)
  | IntLit k -> Some ("i:" ^ Int64.to_string k)
  | FieldGet (b, f) -> let* b = key b in Some ("(" ^ b ^ ")." ^ f)
  | AddrOf b -> let* b = key b in Some ("&(" ^ b ^ ")")
  | Deref b -> let* b = key b in Some ("*(" ^ b ^ ")")
  | Unsafe b -> key b
  | Cast (_, b) -> let* b = key b in Some ("cast(" ^ b ^ ")")
  | Index (b, i) ->
      let* b = key b in let* i = key i in Some ("(" ^ b ^ ")[" ^ i ^ "]")
  | BinOp (op, a, b) ->
      let* a = key a in let* b = key b in
      Some ("(" ^ a ^ " " ^ show_binop op ^ " " ^ b ^ ")")
  | _ -> None

let rec iter_expr (f : expr -> unit) (e : expr) : unit =
  f e;
  match e.desc with
  | Call (_, args) | StructLit args | TupleLit args ->
      List.iter (iter_expr f) args
  | VariantCtor (_, _, a) | Bnot a | Deref a | AddrOf a | Cast (_, a)
  | FieldGet (a, _) | Unsafe a ->
      iter_expr f a
  | BinOp (_, a, b) | Index (a, b) | Assign (a, b) ->
      iter_expr f a; iter_expr f b
  | SliceOf (a, b, c) -> iter_expr f a; iter_expr f b; iter_expr f c
  | IntLit _ | BoolLit _ | StringLit _ | ByteSliceLit _ | Var _ | ViewLit _
  | EnumVariant _ | SizeOf _ | ContainsStableOwner _ | AlignOf _
  | OffsetOf _ | EmbedFile _ ->
      ()

let arm_body = function
  | ArmVariant (_, _, _, b) | ArmWild b | ArmMiss b | ArmIntLit (_, b)
  | ArmByteSliceLit (_, b) -> b

let rec iter_stmt (f : expr -> unit) (s : stmt) : unit =
  match s.desc with
  | Return None | Break | Continue -> ()
  | Return (Some e) | Expr e | Yield e | StaticAssert (e, _)
  | LetTuple (_, e) ->
      iter_expr f e
  | Let (_, _, _, init, _) -> Option.iter (iter_expr f) init
  | Block b | UnsafeBlock b -> List.iter (iter_stmt f) b
  | If (c, t, el) ->
      iter_expr f c; List.iter (iter_stmt f) t; List.iter (iter_stmt f) el
  | While (c, b) -> iter_expr f c; List.iter (iter_stmt f) b
  | For (_, _, lo, hi, b) ->
      iter_expr f lo; iter_expr f hi; List.iter (iter_stmt f) b
  | ForEach (_, se, b) -> iter_expr f se; List.iter (iter_stmt f) b
  | Match (d, arms) | LetMatch (_, _, _, d, arms) ->
      iter_expr f d; List.iter (fun a -> List.iter (iter_stmt f) (arm_body a)) arms

(* The address keys of the boolean compare-exchanges in [visit]'s scope. *)
let cas_keys visit =
  let acc = ref [] in
  visit (fun (e : expr) -> match e.desc with
    | Call (name, addr :: _)
      when operation_of name = Some Atomic_spec.Compare_exchange ->
        Option.iter (fun k -> acc := (k, name) :: !acc) (key addr)
    | _ -> ());
  !acc

let reject_loads cases visit =
  if cases <> [] then
    visit (fun (e : expr) -> match e.desc with
      | Call (name, addr :: _) when operation_of name = Some Atomic_spec.Load ->
          (match key addr with
           | Some k when List.mem_assoc k cases ->
               raise (Types.TypeError (e.loc, Printf.sprintf
                 "'%s' reads the word a preceding '%s' already compared: a \
                  failed compare and a later load are two observations, and \
                  the word can change between them (GitHub issues #556, \
                  #613); use the compare-swap form, whose Observed(v) is the \
                  value the failed compare read"
                 name (List.assoc k cases)))
           | _ -> ())
      | _ -> ())

let rec check_list (stmts : stmt list) : unit =
  let rec go seen = function
    | [] -> ()
    | s :: rest ->
        reject_loads seen (fun f -> iter_stmt f s);
        check_stmt s;
        go (cas_keys (fun f -> iter_stmt f s) @ seen) rest
  in
  go [] stmts

and check_stmt (s : stmt) : unit =
  match s.desc with
  | If (c, t, el) ->
      let cases = cas_keys (fun f -> iter_expr f c) in
      reject_loads cases (fun f ->
        List.iter (iter_stmt f) t; List.iter (iter_stmt f) el);
      check_list t; check_list el
  | Block b | UnsafeBlock b | While (_, b) | For (_, _, _, _, b)
  | ForEach (_, _, b) ->
      check_list b
  | Match (_, arms) | LetMatch (_, _, _, _, arms) ->
      List.iter (fun a -> check_list (arm_body a)) arms
  | Return _ | Expr _ | Yield _ | StaticAssert _ | LetTuple _ | Let _
  | Break | Continue ->
      ()

let check (prog : toplevel list) : unit =
  List.iter (function
    | FuncDef f -> check_list f.body
    | _ -> ()) prog
