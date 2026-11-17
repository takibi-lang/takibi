(* Compose the complete allocation body under explicit entry premises.
   The caller must establish prefix, chain and occupancy coverage and
   separation from the globals modified by growth. *)
module M=Types.StringMap
module E=Local_bindings.Expr_table
type summary = { pool_arg:int; pool_type:Ast.type_expr; count:string; table:string;
 slots:int64; capacity:int64; metadata_capacity:int64; links:string list; head:string list; occupancy:string;
 owner_type:string; index_field:string; success_variant:string; success_case:string;
 origin:Address_extent.value; globals:Growth_body.S.t }
let run ~functions ~key_of ~target ~struct_fields ~growth_bodies ~pop_summaries ~pop_finish_calls ~activation_calls prog =
 let summaries=ref M.empty in
 let inspect (f:Ast.func) (info:Types.func_info) =
  let rec path (e:Ast.expr) = match e.desc with
   | Ast.AddrOf e -> path e
   | Ast.Var _ -> Option.map (fun i -> i,[]) (Local_bindings.id_for_expr info.bindings e)
   | Ast.FieldGet (e,n) -> Option.map (fun (i,ns) -> i,ns@[n]) (path e)
   | _ -> None in
  let finish ss=match ss with
   | [{Ast.desc=Ast.Return (Some call);_}] -> E.find_opt pop_finish_calls call
   | _ -> None in
  let failure summary ss=match ss with
   | [{Ast.desc=Ast.Return (Some {desc=Ast.EnumVariant (v,c);_});_}] ->
     v=summary.Finish_range.success_variant && c<>summary.success_case
   | _ -> false in
  match f.body with
  | [{Ast.desc=Ast.Match (({desc=Ast.Call (_,args);_} as first),arms);_}] ->
   (match Option.bind (target first) (fun k -> M.find_opt k pop_summaries) with
    | Some pop when List.length arms=3 ->
     let arm case=List.find_map (function Ast.ArmVariant (v,c,_,ss) when v=pop.Pop_range.success_variant && c=case -> Some ss | _ -> None) arms in
     (match Option.bind (arm pop.success_case) finish,arm pop.exhausted_case,arm pop.empty_case with
      | Some finished,Some exhausted,Some [capture;guard;growth;{desc=Ast.Expr activate;_};{desc=Ast.Match (({desc=Ast.Call (_,again_args);_} as again),again_arms);_}]
        when failure finished exhausted && target first=target again && List.length args=1 && List.length again_args=1
          && path (List.hd args)=path (List.hd again_args) && List.length again_arms=3 ->
        let initial_root=Option.bind (path (List.hd args)) (fun (i,ns) -> if ns=[] then None else Some i) in
        let activated=match E.find_opt activation_calls activate,path (List.hd args) with
          | Some (Some pool,_,activation),Some (_,core_path) -> initial_root=Some pool
            && activation.Activation_range.links=core_path@[pop.links]
            && activation.head=core_path@[pop.head]
          | _ -> false in
        let guard_ok=match guard.Ast.desc with Ast.If (_,ss,[]) -> failure finished ss | _ -> false in
        let growth_ok=match growth.Ast.desc with Ast.Match (_,gs) ->
          List.length gs=2 && List.for_all (function
           | Ast.ArmVariant (_,"Grown",None,[]) -> true
           | Ast.ArmVariant (_,"OutOfMemory",None,ss) -> failure finished ss
           | _ -> false) gs | _ -> false in
        let again_ok=List.for_all (function
         | Ast.ArmVariant (v,c,_,ss) when v=pop.success_variant ->
           if c=pop.success_case then finish ss=Some finished
           else if c=pop.empty_case || c=pop.exhausted_case then failure finished ss else false
         | _ -> false) again_arms in
        let capture_ok=match capture.Ast.desc with Ast.Let (false,_,_,Some _,_) -> true | _ -> false in
        if activated && guard_ok && growth_ok && again_ok && capture_ok then begin
         ();
         let growth_summary=match growth.Ast.desc with Ast.Match (call,_) ->
           Option.bind (target call) (fun k -> M.find_opt k growth_bodies) | _ -> None in
         (match E.find_opt activation_calls activate,growth_summary,initial_root with
          | Some (_,count,activation),Some (tail,globals),Some pool when tail.Growth_transfer.count=Some count ->
           let pool_type=Option.map Loop_transfer.object_type (Types.IntMap.find_opt pool info.binding_types) in
           let fields=Option.bind (Option.bind pool_type Record_transfer.record) struct_fields in
           let array_size name=Option.bind fields (fun fs -> match List.assoc_opt name fs with
             | Some (Ast.TypeArray (Ast.TypeUsize,n)) -> Some (Int64.of_int n) | _ -> None) in
           let limit=match guard.Ast.desc with Ast.If ({desc=Ast.BinOp (_,_,{desc=Ast.IntLit n;_});_},_,_) -> Some n | _ -> None in
           (match pool_type,array_size tail.table,array_size finished.occupancy with
            | Some pool_type,Some capacity,Some occupancy_capacity
              when capacity>0L && activation.slots>0L && limit=Some capacity
                && occupancy_capacity=pop.capacity && capacity<=Int64.div pop.capacity activation.slots ->
              let rec position n=function [] -> None | i::xs -> if i=pool then Some n else position (n+1) xs in
              (match position 0 info.bindings.param_ids with
               | Some pool_arg ->
                summaries:=M.add (key_of f) {pool_arg;pool_type;count;table=tail.table;
                 slots=activation.slots;capacity;metadata_capacity=pop.capacity;links=activation.links;head=activation.head;
                 occupancy=finished.occupancy;owner_type=finished.owner_type;index_field=finished.index_field;
                 success_variant=finished.success_variant;success_case=finished.success_case;origin=tail.origin;globals} !summaries;
                ()
               | None -> ())
            | _ -> ())
          | _ -> ())
        end
      | _ -> ())
    | _ -> ())
  | _ -> () in
 List.iter (function Ast.FuncDef f -> Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
 !summaries
