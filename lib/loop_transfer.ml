(* Compose a checked growth body with the concrete ensure loop.
   Entry-prefix and frame obligations remain for the caller to discharge. *)
module M = Types.StringMap
type summary = { pool_arg:int; index_arg:int; success_variant:string; success_case:string;
  pool_type:Ast.type_expr; slots:int64; capacity:int64; table:string; count:string; origin:Address_extent.value }
let rec object_type = function
  | Ast.TypeRef t | Ast.TypeRefMut t | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> object_type t
  | t -> t
let run ~functions ~key_of ~target ~growth_transfers ~struct_fields prog =
  let summaries = ref M.empty in
  let inspect (f : Ast.func) (info : Types.func_info) =
    let same a b = match Local_bindings.id_for_expr info.bindings a,
        Local_bindings.id_for_expr info.bindings b with
      | Some a,Some b -> a=b | _ -> false in
    let position e =
      let rec find n = function
        | [] -> None | id::xs -> if Local_bindings.id_for_expr info.bindings e=Some id
            then Some n else find (n+1) xs in
      find 0 info.bindings.param_ids in
    let capacity pool field =
      let rec named = function
        | Ast.TypeRef t | Ast.TypeRefMut t | Ast.TypeBorrow t | Ast.TypeBorrowMut t -> named t
        | Ast.TypeNamed n | Ast.TypeIndexed (n,_) -> Some n | _ -> None in
      Option.bind (Local_bindings.id_for_expr info.bindings pool) (fun id ->
        Option.bind (Option.bind (Types.IntMap.find_opt id info.binding_types) named) (fun n ->
          Option.bind (struct_fields n) (fun fields -> match List.assoc_opt field fields with
            | Some (Ast.TypeArray (Ast.TypeUsize,n)) -> Some (Int64.of_int n) | _ -> None))) in
    let return_tag = function
      | [{Ast.desc=Ast.Return (Some {desc=Ast.EnumVariant (v,c);_});_}] -> Some (v,c)
      | _ -> None in
    match f.body with
    | [{desc=Ast.If ({desc=Ast.BinOp (Ast.Ge,index0,limit);_},initial_failure,[]);_};
       {desc=Ast.While (
         {desc=Ast.BinOp (Ast.Ge,index,
           {desc=Ast.BinOp (Ast.Mul,{desc=Ast.FieldGet (pool,count);_},slots);_});_},
         [({desc=Ast.Let (false,_,_,Some {desc=Ast.FieldGet (copy_pool,copy_count);_},_);_} as capture);
          {desc=Ast.If ({desc=Ast.BinOp (Ast.Ge,chunk,ceiling);_},limit_failure,[]);_};
          {desc=Ast.Match (({desc=Ast.Call (_,[call_pool;call_chunk]);_} as call),arms);_}]);_};
       {desc=Ast.Return (Some {desc=Ast.EnumVariant (success_variant,success_case);_});_}] ->
        let failure ss = match return_tag ss with
          | Some (v,c) -> v=success_variant && c<>success_case
          | None -> false in
        let literal (e : Ast.expr) = match e.desc with
          | Ast.IntLit n when n>0L -> Some n | _ -> None in
        let capture_matches = match Local_bindings.ids_for_stmt info.bindings capture with
          | [id] -> Local_bindings.id_for_expr info.bindings chunk=Some id
          | _ -> false in
        let arms_match = List.length arms=2 && List.exists (function
            | Ast.ArmVariant (_,"Grown",None,[]) -> true | _ -> false) arms
          && List.exists (function
            | Ast.ArmVariant (_,"OutOfMemory",None,ss) -> failure ss | _ -> false) arms in
        (match Option.bind (target call) (fun k -> M.find_opt k growth_transfers),
            literal limit,literal slots,literal ceiling with
         | Some growth,Some _,Some slots,Some ceiling
             when same index0 index && same pool copy_pool && count=copy_count
               && same pool call_pool && same chunk call_chunk && capture_matches
               && failure initial_failure && failure limit_failure && arms_match
               && growth.Growth_transfer.count=Some count
               && capacity pool growth.table=Some ceiling ->
             (match position pool,position index with
              | Some p,Some i ->
                  (match Option.bind (Local_bindings.id_for_expr info.bindings pool)
                     (fun id -> Types.IntMap.find_opt id info.binding_types) with
                   | Some ty -> summaries := M.add (key_of f)
                       {pool_arg=p;index_arg=i;success_variant;success_case;pool_type=object_type ty;
                        slots;capacity=ceiling;table=growth.table;count;origin=growth.origin} !summaries
                   | None -> ())
              | _ -> ());
             ()
         | _ -> ())
    | _ -> () in
  List.iter (function Ast.FuncDef f ->
    Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
  !summaries
