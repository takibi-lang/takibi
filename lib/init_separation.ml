(* Check inferred frame requirements at direct calls. This bounded provenance
   domain follows immutable references to inline objects; pointer loads,
   returned addresses, indexed aliases and rebinding remain unknown. *)
open Init_separation_domain
module StringMap = Types.StringMap
module IntMap = Types.IntMap
module IntSet = Set.Make (Int)

let check ~functions ~key_of ~target ~function_values ~global_type ~struct_fields
    ~initial prog =
  let requirements = ref initial in
  let sites = ref [] in
  let errors = ref [] in
  let error loc msg = errors := (loc, msg) :: !errors in
  let prepare (f : Ast.func) (info : Types.func_info) =
    let aliases = ref IntMap.empty and unstable = ref IntSet.empty in
    let calls = ref [] in
    let binding e = Local_bindings.Expr_table.find_opt info.bindings.expr_ids e in
    let destabilize e = Option.iter (fun id -> unstable := IntSet.add id !unstable) (binding e) in
    let rec expr (e : Ast.expr) =
      (match e.desc with
       | Ast.Call (_, args) ->
           Option.iter (fun key -> calls := (e, key, args) :: !calls) (target e);
           List.iter expr args
       | Ast.Assign (a, b) ->
           (match a.desc with Ast.Var _ -> destabilize a | _ -> ()); expr a; expr b
       | Ast.AddrOf ({desc = Ast.Var _; _} as a) -> destabilize a; expr a
       | Ast.VariantCtor (_, _, a) | Ast.Bnot a | Ast.Deref a | Ast.AddrOf a
       | Ast.Cast (_, a) | Ast.FieldGet (a, _) | Ast.Unsafe a -> expr a
       | Ast.BinOp (_, a, b) | Ast.Index (a, b) -> expr a; expr b
       | Ast.SliceOf (a, b, c) -> expr a; expr b; expr c
       | Ast.StructLit xs | Ast.TupleLit xs -> List.iter expr xs
       | _ -> ())
    and stmt (s : Ast.stmt) =
      let body = List.iter stmt in
      let arms xs = List.iter (fun arm -> body (Control_flow.arm_body arm)) xs in
      match s.desc with
      | Ast.Let (mutable_, _, _, init, _) ->
          (match Local_bindings.ids_for_stmt info.bindings s with
           | [id] -> if mutable_ then unstable := IntSet.add id !unstable
               else Option.iter (fun e -> aliases := IntMap.add id e !aliases) init
           | _ -> ()); Option.iter expr init
      | Ast.Return e -> Option.iter expr e
      | Ast.Expr e | Ast.Yield e | Ast.LetTuple (_, e) | Ast.StaticAssert (e, _) -> expr e
      | Ast.Block ss | Ast.UnsafeBlock ss -> body ss
      | Ast.If (c, a, b) -> expr c; body a; body b
      | Ast.While (c, ss) | Ast.ForEach (_, c, ss) -> expr c; body ss
      | Ast.For (_, _, lo, hi, ss) -> expr lo; expr hi; body ss
      | Ast.Match (e, xs) | Ast.LetMatch (_, _, _, e, xs) -> expr e; arms xs
      | Ast.Break | Ast.Continue -> () in
    List.iter stmt f.body;
    let typed id = Option.map Init_writes.strip (IntMap.find_opt id info.binding_types) in
    let position id =
      let rec go i = function [] -> None | x :: xs -> if id = x then Some i else go (i + 1) xs in
      go 0 info.bindings.param_ids in
    let rec object_at seen (e : Ast.expr) = match e.desc with
      | Ast.Var name -> (match binding e with
          | Some id -> (match typed id with
              | Some ((Ast.TypeRef _ | Ast.TypeRefMut _) as ty) ->
                  Option.map (fun p -> (p, match ty with Ast.TypeRef t | Ast.TypeRefMut t -> t | _ -> assert false))
                    (address seen e)
              | Some (Ast.TypePtr _) | None -> None
              | Some ty -> Some ((Local id, []), ty))
          | None -> (match Option.map Init_writes.strip (global_type name) with
              | Some (Ast.TypePtr _ | Ast.TypeRef _ | Ast.TypeRefMut _) | None -> None
              | Some ty -> Some ((Global name, []), ty)))
      | Ast.FieldGet (base, field) ->
          Option.bind (object_at seen base) (fun ((root, path), ty) ->
            match Init_writes.strip ty with
            | Ast.TypeNamed n | Ast.TypeIndexed (n, _) ->
                Option.bind (struct_fields n) (fun fields ->
                  Option.map (fun ty -> ((root, path @ [field]), ty)) (List.assoc_opt field fields))
            | _ -> None)
      | Ast.Unsafe e -> object_at seen e
      | _ -> None
    and address seen (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Option.bind (binding e) (fun id ->
          if IntSet.mem id !unstable || List.mem id seen then None else
          match typed id with
          | Some (Ast.TypeRef _ | Ast.TypeRefMut _) ->
              (match position id with
               | Some i -> Some (Parameter i, [])
               | None -> Option.bind (IntMap.find_opt id !aliases) (address (id :: seen)))
          | _ -> None)
      | Ast.AddrOf ({desc = Ast.Var _; _} as base) ->
          (match binding base with
           | Some id -> (match typed id with
               | Some (Ast.TypeRef _ | Ast.TypeRefMut _ | Ast.TypePtr _) -> Some (Local id, [])
               | _ -> Option.map fst (object_at seen base))
           | None -> Option.map fst (object_at seen base))
      | Ast.AddrOf base -> Option.map fst (object_at seen base)
      | Ast.Unsafe e -> address seen e
      | _ -> None in
    List.iter (fun (e, callee, args) ->
      let actual (root, path) = match root with
        | Global _ -> Some (root, path)
        | Local _ -> None
        | Parameter i -> Option.bind (List.nth_opt args i) (fun arg ->
            Option.map (fun (r, p) -> (r, p @ path)) (address [] arg)) in
      sites := (key_of f, e.Ast.loc, callee, actual) :: !sites) !calls in
  List.iter (function Ast.FuncDef f ->
    Option.iter (prepare f) (StringMap.find_opt (key_of f) functions) | _ -> ()) prog;
  (* Monotone finite closure: only named roots and existing inline paths can
     propagate. Root-only inferred requirements never grow a recursive path. *)
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun (caller, _, callee, actual) ->
      let needed = Option.value ~default:Conditions.empty (StringMap.find_opt callee !requirements) in
      Conditions.iter (fun (a, b) -> match actual a, actual b with
        | Some a, Some b -> (match classify a b with
            | Required pair ->
                (* Keep the propagated domain finite even through recursive
                   calls that pass nested fields: strengthen to whole roots. *)
                let (ra, _), (rb, _) = pair in
                let pair = ordered (ra, []) (rb, []) in
                let old = Option.value ~default:Conditions.empty (StringMap.find_opt caller !requirements) in
                if not (Conditions.mem pair old) then begin
                  requirements := StringMap.add caller (Conditions.add pair old) !requirements;
                  changed := true
                end
            | _ -> ())
        | _ -> ()) needed) !sites
  done;
  List.iter (fun (_, loc, callee, actual) ->
    let needed = Option.value ~default:Conditions.empty (StringMap.find_opt callee !requirements) in
    Conditions.iter (fun ((a, b) as pair) ->
      let failure = match actual a, actual b with
        | Some a, Some b -> (match classify a b with Overlap -> Some "arguments overlap" | _ -> None)
        | _ -> Some "argument storage provenance is unknown" in
      Option.iter (fun reason -> error loc (Printf.sprintf
        "init_links cannot prove separation at call to '%s': %s requires %s; use independent inline storage or a checked wrapper"
        callee reason (show pair))) failure) needed) !sites;
  StringMap.iter (fun _ key -> match StringMap.find_opt key !requirements with
    | Some conditions when not (Conditions.is_empty conditions) ->
        (* Report the definition when only the resolved location key remains. *)
        List.iter (function Ast.FuncDef f when key_of f = key ->
          error f.def_loc (Printf.sprintf
            "function value for '%s' would erase inferred separation: %s; use a checked wrapper that discharges the condition"
            f.name (show (Conditions.min_elt conditions))) | _ -> ()) prog
    | _ -> ()) function_values;
  let boundary loc name =
    List.iter (function Ast.FuncDef f when f.name = name ->
      (match StringMap.find_opt (key_of f) !requirements with
       | Some cs when not (Conditions.is_empty cs) -> error loc (Printf.sprintf
           "entry '%s' would erase inferred separation: %s; use a checked wrapper"
           name (show (Conditions.min_elt cs)))
       | _ -> ()) | _ -> ()) prog in
  let rec global_init (e : Ast.expr) =
    (match target e with
     | Some key when StringMap.mem key !requirements ->
         error e.loc ("global initializer cannot discharge inferred separation for '" ^ key ^ "'; use a checked wrapper")
     | _ -> ());
    match e.desc with
    | Ast.Call (_, xs) | Ast.StructLit xs | Ast.TupleLit xs -> List.iter global_init xs
    | Ast.VariantCtor (_, _, x) | Ast.Bnot x | Ast.Deref x | Ast.AddrOf x
    | Ast.Cast (_, x) | Ast.FieldGet (x, _) | Ast.Unsafe x -> global_init x
    | Ast.BinOp (_, a, b) | Ast.Index (a, b) | Ast.Assign (a, b) -> global_init a; global_init b
    | Ast.SliceOf (a, b, c) -> global_init a; global_init b; global_init c
    | _ -> () in
  List.iter (function
    | Ast.FuncDef f when f.name = "main" || Option.fold ~none:false
        ~some:(List.exists (fun e -> List.mem e ["interrupt"; "exception"; "nmi"])) f.effects ->
        boundary f.def_loc f.name
    | Ast.VectorTableDef (entries, loc) ->
        List.iter (fun (_, name) -> boundary loc name) entries
    | Ast.ExceptionEntryDef (_, entries, loc) | Ast.ExceptionRestoreDef (_, entries, loc) ->
        List.iter (fun (_, name) -> boundary loc name) entries
    | Ast.ConstDef (_, _, e, _) | Ast.LetDef (_, _, Some e, _, _, _, _) -> global_init e
    | _ -> ()) prog;
  !requirements, List.rev !errors
