(* GitHub issue #952: range obligations, a second judge for derived ranges.

   Every range the checker derives for an arithmetic or cast result is built
   through refined_or_base (lib/type_inf.ml, lib/llvm_gen.ml). Each such site
   also describes the machine operation it reasoned about, and, under
   --emit-range-obligations DIR, this module writes one SMT-LIB file per
   distinct obligation. The file asserts, in QF_BV at the operation's own
   width, that some input inside its known range gives a result OUTSIDE the
   derived range [lo, hi). So `unsat` means the derived range is proved for
   what the machine actually computes (wrap, truncation, signedness), and
   `sat` comes with a counterexample. scripts/buildcheck_range_obligations.py
   runs z3 on every file.

   File format (version 1; docs/RANGE_OBLIGATIONS.md is the reference):

     ; takibi-range-obligation v1
     ; rule: <add|sub|mul|div|mod|band|cast>
     ; claim: {lo..<hi as T}
     ; site: file:line:col          (one line per site, sorted)
     (set-logic QF_BV)
     (declare-const a (_ BitVec Wa))  ; operand a at its own width
     (declare-const b (_ BitVec Wb))  ; operand b, binary rules only
     (assert ...)                     ; a, b inside their known ranges
     (define-fun r () (_ BitVec W) <the machine operation on a b>)
     (assert (not (in-range r)))
     (check-sat)

   Ranges are compared at width W+2 after extending the value by its
   signedness, so a bound such as hi = 2^W (u8's 256) is representable and
   every comparison is a plain signed comparison. A constant operand is the
   literal reduced modulo 2^W, which is what the machine holds. The site
   lines are comments; the obligation's identity (and file name) is the MD5
   of the remaining text, so an obligation shared by many sites, or derived
   by both type_inf.ml and llvm_gen.ml, is written and solved once. *)

type operand =
  | Range of int * int   (* known [lo, hi) *)
  | Any                  (* any value of the operand's width *)
  | Const of int         (* a compile-time literal *)

type rule =
  | Add | Sub | Mul | Div | Mod | Band
  | Cast of int * bool   (* source width and signedness *)

type t = {
  rule : rule;
  a : operand;
  b : operand option;    (* None for Cast *)
  bits : int;            (* result width; also the operand width of a
                            binary rule *)
  signed : bool;         (* result signedness *)
  type_name : string;    (* result base, for the claim comment *)
  lo : int;
  hi : int;
}

let enabled = ref false

(* body digest -> (body, sites) *)
let table : (string, string * (string, unit) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 256

(* Two's-complement bit string of v at width w, for any w (bits above
   OCaml's 63 repeat the sign). *)
let bits_of v w =
  String.init w (fun i ->
    let bit = w - 1 - i in
    let b = if bit >= 62 then (if v < 0 then 1 else 0) else (v asr bit) land 1 in
    if b = 1 then '1' else '0')

let bv v w = "#b" ^ bits_of v w

let ext ~signed name =
  Printf.sprintf "((_ %s 2) %s)"
    (if signed then "sign_extend" else "zero_extend") name

let in_range ~signed name w lo hi =
  let x = w + 2 in
  Printf.sprintf "(and (bvsle %s %s) (bvslt %s %s))"
    (bv lo x) (ext ~signed name) (ext ~signed name) (bv hi x)

let rule_name = function
  | Add -> "add" | Sub -> "sub" | Mul -> "mul" | Div -> "div"
  | Mod -> "mod" | Band -> "band" | Cast _ -> "cast"

let body (o : t) =
  let buf = Buffer.create 512 in
  let line s = Buffer.add_string buf s; Buffer.add_char buf '\n' in
  line "; takibi-range-obligation v1";
  line ("; rule: " ^ rule_name o.rule);
  line (Printf.sprintf "; claim: {%d..<%d as %s}" o.lo o.hi o.type_name);
  line "(set-logic QF_BV)";
  let a_bits, a_signed = match o.rule with
    | Cast (w, s) -> w, s
    | _ -> o.bits, o.signed in
  let operand name w signed = function
    | Const k -> bv k w
    | Range (lo, hi) ->
        line (Printf.sprintf "(declare-const %s (_ BitVec %d))" name w);
        line (Printf.sprintf "(assert %s)" (in_range ~signed name w lo hi));
        name
    | Any ->
        line (Printf.sprintf "(declare-const %s (_ BitVec %d))" name w);
        name in
  let a = operand "a" a_bits a_signed o.a in
  let b = match o.b with
    | Some b -> operand "b" o.bits o.signed b
    | None -> "" in
  let s = o.signed in
  let expr = match o.rule with
    | Add -> Printf.sprintf "(bvadd %s %s)" a b
    | Sub -> Printf.sprintf "(bvsub %s %s)" a b
    | Mul -> Printf.sprintf "(bvmul %s %s)" a b
    | Div -> Printf.sprintf "(%s %s %s)" (if s then "bvsdiv" else "bvudiv") a b
    | Mod -> Printf.sprintf "(%s %s %s)" (if s then "bvsrem" else "bvurem") a b
    | Band -> Printf.sprintf "(bvand %s %s)" a b
    | Cast (w, src_signed) ->
        if w = o.bits then a
        else if w > o.bits then
          Printf.sprintf "((_ extract %d 0) %s)" (o.bits - 1) a
        else
          Printf.sprintf "((_ %s %d) %s)"
            (if src_signed then "sign_extend" else "zero_extend")
            (o.bits - w) a in
  line (Printf.sprintf "(define-fun r () (_ BitVec %d) %s)" o.bits expr);
  line (Printf.sprintf "(assert (not %s))" (in_range ~signed:s "r" o.bits o.lo o.hi));
  line "(check-sat)";
  Buffer.contents buf

let site_of_loc (loc : Lexing.position) =
  Printf.sprintf "%s:%d:%d" (Ast.source_file_of_loc loc) loc.Lexing.pos_lnum
    (loc.Lexing.pos_cnum - loc.Lexing.pos_bol + 1)

let record (loc : Lexing.position) (o : t) =
  if !enabled then begin
    let text = body o in
    let key = Digest.to_hex (Digest.string text) in
    let sites = match Hashtbl.find_opt table key with
      | Some (_, sites) -> sites
      | None ->
          let sites = Hashtbl.create 4 in
          Hashtbl.replace table key (text, sites); sites in
    Hashtbl.replace sites (site_of_loc loc) ()
  end

(* Write DIR/<digest>.smt2 for every recorded obligation, after removing
   the .smt2 files a previous run left there. *)
let write_dir dir =
  (try Sys.mkdir dir 0o755 with Sys_error _ -> ());
  Array.iter (fun f ->
      if Filename.check_suffix f ".smt2" then Sys.remove (Filename.concat dir f))
    (Sys.readdir dir);
  Hashtbl.iter (fun key (text, sites) ->
      let sites = Hashtbl.fold (fun s () acc -> s :: acc) sites [] in
      let sites = List.sort compare sites in
      let oc = open_out (Filename.concat dir (key ^ ".smt2")) in
      (* The site comments go after the version line so the header stays
         first; they are not part of the digest. *)
      (match String.index_opt text '\n' with
       | Some i ->
           output_string oc (String.sub text 0 (i + 1));
           List.iter (fun s -> output_string oc ("; site: " ^ s ^ "\n")) sites;
           output_string oc (String.sub text (i + 1) (String.length text - i - 1))
       | None -> output_string oc text);
      close_out oc)
    table

(* Fault control only (--range-obligation-fault-control): plants #935's
   rule, an unsigned base keeping a negative lower bound, so
   scripts/buildcheck_range_obligations.py can show it reports the
   counterexample. Never set in a real build. *)
let fault_unsigned_negative_lo = ref false
