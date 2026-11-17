(* Narrow body-derived boolean adapters for the candidate ensure-Ok summary.
   Only a single exhaustive match with literal boolean returns is supported.
   The underlying allocator summary remains an experimental assumption. *)
module M = Types.StringMap
let infer ~functions ~key_of ~target ~loop_summaries prog =
  List.fold_left (fun summaries -> function
    | Ast.FuncDef f ->
        let key = key_of f in
        (match M.find_opt key functions, f.Ast.body with
         | Some info, [{Ast.desc = Ast.Match
               (({desc = Ast.Call (_, [pool; index]); _} as call), arms); _}]
             when Option.fold ~none:false ~some:(fun key -> M.mem key loop_summaries) (target call) ->
             let param e =
               let rec find pos = function
                 | [] -> None
                 | id :: rest ->
                     if Some id = Local_bindings.id_for_expr info.Types.bindings e
                     then Some pos else find (pos + 1) rest in
               match e.Ast.desc with Ast.Var _ -> find 0 info.bindings.param_ids | _ -> None in
             let expected = ["ChunkLimitReached"; "IndexOutOfRange"; "Ok"; "OutOfMemory"] in
             let cases = List.filter_map (function
               | Ast.ArmVariant ("GrowablePoolEnsureResult", tag, None,
                   [{Ast.desc = Ast.Return (Some {desc = Ast.BoolLit b; _}); _}]) -> Some (tag,b)
               | _ -> None) arms in
             let good = List.length cases = List.length arms
               && List.sort String.compare (List.map fst cases) = expected
               && List.assoc "Ok" cases
               && List.for_all (fun (tag,b) -> tag = "Ok" || not b) cases in
             (match good,param pool,param index with
              | true,Some p,Some i ->
                  ();
                  (match Option.bind (target call) (fun k -> M.find_opt k loop_summaries) with
                   | Some schema -> M.add key (p,i,schema) summaries | None -> summaries)
              | _ -> summaries)
         | _ -> summaries)
    | _ -> summaries) M.empty prog
