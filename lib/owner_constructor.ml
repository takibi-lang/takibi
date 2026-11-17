(* Match source-derived initial field values to a concrete insert schema.
   Empty means no reachable nodes and no occupied indices, not allocated bytes. *)
module M=Types.StringMap
module I=Types.IntMap
module P=Record_init.P
let run ~functions ~record_initializers ~insert_summaries =
 let constructors=ref M.empty in
 M.iter (fun key facts -> match M.find_opt key functions with
  | None -> ()
  | Some (info:Types.func_info) ->
   M.iter (fun _ (schema:Insert_body.summary) ->
    List.iteri (fun position id ->
     let ty=Option.map Loop_transfer.object_type (I.find_opt id info.binding_types) in
     let value path=P.find_opt (id,path) facts in
     let empty_head=match value schema.head with
      | Some (Record_init.Scalar head) -> head>=schema.metadata_capacity
      | _ -> false in
     if ty=Some schema.pool_type && value [schema.count]=Some (Record_init.Scalar 0L)
       && empty_head
       && value [schema.occupancy]=Some (Record_init.Uniform(schema.metadata_capacity,0L)) then begin
      let old=Option.value ~default:[] (M.find_opt key !constructors) in
      constructors:=M.add key ((position,schema)::old) !constructors;
      ()
     end) info.bindings.param_ids) insert_summaries) record_initializers;
 !constructors
