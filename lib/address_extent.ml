(* Relative-address range inference for declared static byte arrays.
   Summaries concern offsets, extent and alignment, not allocation uniqueness
   or the backend guarantee that the declared object has a valid address. *)
module M = Types.StringMap
module I = Types.IntMap
type value = Unknown | Number of int64 * int64 | Address of string * int64 * int64 * int64 * int64
let plus a b = if b > Int64.sub Int64.max_int a then None else Some (Int64.add a b)
let times a b = if a <> 0L && b > Int64.div Int64.max_int a then None else Some (Int64.mul a b)
let run ~functions ~key_of ~struct_fields ~global_type prog =
  let summaries = ref M.empty in
  let constants = List.fold_left (fun m -> function
    | Ast.ConstDef (name, _, {desc = Ast.IntLit n; _}, _) when n >= 0L -> M.add name n m
    | _ -> m) M.empty prog in
  let alignments = List.fold_left (fun m -> function
    | Ast.LetDef (name,Some (Ast.TypeArray (Ast.TypeU8,_)),_,alignment,_,_,_) ->
        M.add name (Int64.of_int (Option.value ~default:1 alignment)) m
    | _ -> m) M.empty prog in
  let rec gcd a b = if b=0L then a else gcd b (Int64.rem a b) in
  let inspect (f : Ast.func) (info : Types.func_info) =
    let values = ref I.empty in
    let divisors = ref I.empty in
    let binding e = Local_bindings.id_for_expr info.bindings e in
    let rec ty (e : Ast.expr) = match e.desc with
      | Ast.Var _ -> Option.bind (binding e) (fun id -> I.find_opt id info.binding_types)
      | Ast.FieldGet (base, field) ->
          let rec record = function
            | Ast.TypeBorrow t | Ast.TypeBorrowMut t | Ast.TypeRef t | Ast.TypeRefMut t -> record t
            | Ast.TypeNamed n | Ast.TypeIndexed (n, _) -> Some n
            | _ -> None in
          Option.bind (Option.bind (ty base) record) (fun n ->
            Option.bind (struct_fields n) (List.assoc_opt field))
      | _ -> None in
    let number_of_type e = match ty e with
      | Some (Ast.TypeRefined (lo, hi, Ast.TypeUsize)) when lo >= 0 && hi > lo ->
          Number (Int64.of_int lo, Int64.of_int (hi - 1))
      | _ -> Unknown in
    let rec value (e : Ast.expr) = match e.desc with
      | Ast.IntLit n when n >= 0L -> Number (n,n)
      | Ast.Var name -> (match binding e with
          | Some id -> Option.value ~default:(number_of_type e) (I.find_opt id !values)
          | None -> (match M.find_opt name constants, global_type name with
              | Some n, _ -> Number (n,n)
              | _, Some (Ast.TypeArray (Ast.TypeU8,n)) when n > 0 ->
                  Address (name,Int64.of_int n,0L,0L,1L)
              | _ -> Unknown))
      | Ast.FieldGet _ -> number_of_type e
      | Ast.Cast ((Ast.TypeUsize | Ast.TypePtr Ast.TypeU8), x) | Ast.Unsafe x -> value x
      | Ast.BinOp (Ast.Mul,a,b) -> (match value a,value b with
          | Number (lo,hi),Number (lo2,hi2) -> (match times lo lo2,times hi hi2 with
              | Some lo,Some hi -> Number (lo,hi) | _ -> Unknown)
          | _ -> Unknown)
      | Ast.BinOp (Ast.Add,a,b) -> (match value a,value b with
          | Address (name,extent,lo,hi,_),Number (lo2,hi2) ->
              (match plus lo lo2,plus hi hi2 with
               | Some lo,Some hi when hi <= extent -> Address (name,extent,lo,hi,1L)
               | _ -> Unknown)
          | Number (lo,hi),Number (lo2,hi2) -> (match plus lo lo2,plus hi hi2 with
              | Some lo,Some hi -> Number (lo,hi) | _ -> Unknown)
          | _ -> Unknown)
      | _ -> Unknown in
    let rec divisor (e:Ast.expr) = match e.desc with
      | Ast.IntLit n when n>=0L -> n
      | Ast.Var name -> (match binding e with
          | Some id -> Option.value ~default:1L (I.find_opt id !divisors)
          | None -> Option.value ~default:(Option.value ~default:1L (M.find_opt name constants))
              (M.find_opt name alignments))
      | Ast.Cast ((Ast.TypeUsize | Ast.TypePtr Ast.TypeU8),x) | Ast.Unsafe x -> divisor x
      | Ast.BinOp (Ast.Add,a,b) -> gcd (divisor a) (divisor b)
      | Ast.BinOp (Ast.Mul,a,b) ->
          Option.value ~default:1L (times (divisor a) (divisor b))
      | _ -> 1L in
    let rec body = function
      | [{Ast.desc = Ast.Return (Some e); _}] -> value e
      | ({Ast.desc = Ast.Let (false,_,_,Some e,_); _} as s)::rest ->
          (match Local_bindings.ids_for_stmt info.bindings s with
           | [id] -> values := I.add id (value e) !values; divisors := I.add id (divisor e) !divisors; body rest
           | _ -> Unknown)
      | _ -> Unknown in
    match body f.body with
    | Address (name,extent,lo,hi,_) ->
        let alignment = match List.rev f.body with
          | {Ast.desc=Ast.Return (Some e);_}::_ ->
              let n=divisor e in if n=0L then 1L else Int64.logand n (Int64.neg n)
          | _ -> 1L in
        summaries := M.add (key_of f) (Address (name,extent,lo,hi,alignment)) !summaries;
        ()
    | _ -> () in
  List.iter (function Ast.FuncDef f ->
    Option.iter (inspect f) (M.find_opt (key_of f) functions) | _ -> ()) prog;
  !summaries
