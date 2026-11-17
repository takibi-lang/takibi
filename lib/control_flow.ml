(* Checked non-returning Takibi bodies. This structural analysis proves only
   absence of normal function return, not termination, progress or memory
   safety. Calls use resolved targets supplied by the type checker. *)
type exits = { next : bool; returns : bool; breaks : bool; continues : bool }
let none = { next = false; returns = false; breaks = false; continues = false }
let fall = { none with next = true }
let union a b = { next = a.next || b.next; returns = a.returns || b.returns;
  breaks = a.breaks || b.breaks; continues = a.continues || b.continues }
let arm_body = function
  | Ast.ArmVariant (_, _, _, b) | Ast.ArmWild b | Ast.ArmMiss b
  | Ast.ArmIntLit (_, b) | Ast.ArmByteSliceLit (_, b) -> b
let rec statements ~noreturn ss =
  List.fold_left (fun acc s ->
    if acc.next then union { acc with next = false } (statement ~noreturn s)
    else acc) fall ss
and statement ~noreturn (s : Ast.stmt) =
  let body = statements ~noreturn in
  let expression e = if noreturn e then none else fall in
  match s.desc with
  | Ast.Return (Some e) when noreturn e -> none
  | Ast.Return _ -> { none with returns = true }
  | Ast.Break -> { none with breaks = true }
  | Ast.Continue -> { none with continues = true }
  | Ast.Expr e | Ast.Yield e | Ast.Let (_, _, _, Some e, _)
  | Ast.LetTuple (_, e) -> expression e
  | Ast.Block b | Ast.UnsafeBlock b -> body b
  | Ast.If ({ desc = Ast.BoolLit true; _ }, yes, _) -> body yes
  | Ast.If ({ desc = Ast.BoolLit false; _ }, _, no) -> body no
  | Ast.If (_, yes, no) -> union (body yes) (body no)
  | Ast.Match (_, arms) | Ast.LetMatch (_, _, _, _, arms) ->
      if arms = [] then fall else
        List.fold_left (fun acc arm -> union acc (body (arm_body arm))) none arms
  | Ast.While (condition, b) ->
      let exits = body b in
      let forever = match condition.desc with Ast.BoolLit true -> true | _ -> false in
      { none with next = not forever || exits.breaks; returns = exits.returns }
  | Ast.For (_, _, _, _, b) | Ast.ForEach (_, _, b) ->
      { fall with returns = (body b).returns }
  | Ast.Let _ | Ast.StaticAssert _ -> fall
let never_returns ~noreturn body =
  let exits = statements ~noreturn body in
  not (exits.next || exits.returns || exits.breaks || exits.continues)
