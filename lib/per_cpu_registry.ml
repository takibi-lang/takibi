(* GitHub issue #704: per-CPU storage. `struct cpu_authority Name { private
   f: {0..<N as usize}; }` is the one current-CPU authority: its field is
   private, so only its declaring file mints one. `struct per_cpu Store
   {...}` is a store type that exists only as a per-CPU global,
   `private let mut g: [Store; N];`, and `g[a]` is the one way to reach an
   element, with `a` an authority value. Declared_type_resolver rewrites
   `g[a]` to `g[a.f]` and records the read here, so the privacy check lets
   that one read through and the checker can insist `a` is the authority. *)

let stores : (string, unit) Hashtbl.t = Hashtbl.create 4
let authority : (string * (string * Ast.type_expr) list) option ref = ref None
let pending_authority : string option ref = ref None
(* The file that declares the authority: the only file that may read
   TPIDR_EL1 (`mrs_tpidr_el1`), the register through which it finds this
   CPU's preempt count without an authority in hand (#638 stage 2). *)
let authority_file : string option ref = ref None
let globals : (string, string) Hashtbl.t = Hashtbl.create 4
let rewritten : (string * int, string) Hashtbl.t = Hashtbl.create 8

(* GitHub issue #638: `preempt_off (cpu) { body }` is parsed as a block whose
   first statement is `let cpu = preempt_off_enter();`. The parser records
   that call's location here, and only a recorded call may reach the private
   mint across files. The block is the region in which preemption is
   disabled: the checker forbids may_block in it and keeps the authority
   from leaving it.

   Stage 2 (#638): the block also ends with `preempt_off_exit();`, recorded
   the same way, and code generation repeats that call before every
   `return`, `break` or `continue` that leaves the block, so the per-CPU
   preempt count the mint raised is lowered on every exit. *)
let preempt_off_mint_name = "preempt_off_enter"
let preempt_off_exit_name = "preempt_off_exit"
let preempt_off_mints : (string * int, unit) Hashtbl.t = Hashtbl.create 32
let preempt_off_exits : (string * int, unit) Hashtbl.t = Hashtbl.create 32

let reset () =
  Hashtbl.reset stores;
  authority := None;
  pending_authority := None;
  authority_file := None;
  Hashtbl.reset globals;
  Hashtbl.reset rewritten;
  Hashtbl.reset preempt_off_mints;
  Hashtbl.reset preempt_off_exits

let mark_store name = Hashtbl.replace stores name ()
let is_store name = Hashtbl.mem stores name
let mark_authority name (loc : Ast.loc) =
  pending_authority := Some name;
  authority_file := Some (Ast.source_file_of_loc loc)

let finish name fields =
  if !pending_authority = Some name then begin
    pending_authority := None;
    authority := Some (name, fields)
  end

let authority_name () = Option.map fst !authority

(* The authority's one field: its name and the exclusive bound N of its
   `{0..<N as usize}` type, once the checker has validated the shape. *)
let authority_field () =
  match !authority with
  | Some (_, [(field, _)]) -> Some field
  | _ -> None

let loc_key (loc : Ast.loc) = (Ast.source_file_of_loc loc, loc.Lexing.pos_cnum)
let mark_rewritten loc global = Hashtbl.replace rewritten (loc_key loc) global
let rewritten_global loc = Hashtbl.find_opt rewritten (loc_key loc)
let mark_preempt_off_mint loc = Hashtbl.replace preempt_off_mints (loc_key loc) ()
let is_preempt_off_mint loc = Hashtbl.mem preempt_off_mints (loc_key loc)
let mark_preempt_off_exit loc = Hashtbl.replace preempt_off_exits (loc_key loc) ()
let is_preempt_off_exit loc = Hashtbl.mem preempt_off_exits (loc_key loc)

(* A call the parser wrote for a preempt_off block: the mint or the exit.
   Only these reach the authority file's private pair from another file. *)
let is_preempt_off_call name loc =
  (name = preempt_off_mint_name && is_preempt_off_mint loc)
  || (name = preempt_off_exit_name && is_preempt_off_exit loc)

(* The block a `preempt_off` statement parses to: its first statement binds
   the recorded mint and its last calls the recorded exit. *)
let preempt_off_block (stmts : Ast.stmt list) =
  match stmts with
  | { Ast.desc = Ast.Let (_, _, _, Some { Ast.desc = Ast.Call (m, []); loc = ml }, _); _ }
    :: (_ :: _ as rest) when m = preempt_off_mint_name && is_preempt_off_mint ml ->
      (match List.rev rest with
       | ({ Ast.desc = Ast.Expr { Ast.desc = Ast.Call (x, []); loc = xl }; _ } as exit) :: _
         when x = preempt_off_exit_name && is_preempt_off_exit xl -> Some exit
       | _ -> None)
  | _ -> None
