(* GitHub issue #954: the initialization predicate of an array or slice leaf,
   Init(k) for k in a union of half-open intervals [lo, hi) whose bounds are
   linear integer terms (docs/VERIFICATION_DESIGN.md).

   Terms are mathematical integers over ATOMS: the value of an immutable
   binding (`v<id>`), the length of a slice binding (`len<id>`), a call's
   result (`result`) or a contract arm's payload binder. Every atom is a
   usize, so it lies in [0, 2^64). Init_flow builds a term of the body
   only when its mathematical value is the machine's: leaves at the usize
   width, and no step that may wrap (#983).

   Coverage of a goal [a, b) is decided by a chain walk that needs only
   constant differences between terms: from cur = a, stop when b - cur <= 0
   or some interval has lo <= cur and hi >= b; else take an interval with
   lo <= cur <= hi (each interval once) and continue from hi. With all
   terms constant this is exact on a finite set; with
   symbolic terms it is a sound, incomplete decision in quantifier-free
   linear integer arithmetic. Every positive conclusion is written as an
   SMT-LIB obligation (QF_LIA, one existential point k) that z3 re-checks
   under --facts rangeobl, the channel of #952. *)

module SMap = Map.Make (String)
module SSet = Set.Make (String)

type lin = { c : int; m : int SMap.t }   (* c + sum coeff * atom *)

let const c = { c; m = SMap.empty }
let atom a = { c = 0; m = SMap.singleton a 1 }

(* GitHub issue #983: terms compute on the checker's native ints, which
   are 63 bits wide, so a sum or product can wrap where the mathematical
   value does not. Every constant and coefficient stays inside
   (-2^62, 2^62); a step that would leave it raises [Overflow], which the
   deciders below read as "not shown" and Init_flow reports as an error.
   A leaf constant is at most [limit] (2^60), so ordinary terms never get
   near the edge. *)
exception Overflow

let limit = 1 lsl 60

let edge = 1 lsl 62 - 1

let chk v = if v > edge || v < - edge then raise Overflow else v

let chk_add a b =
  let s = a + b in
  (* Native wrap: the sign of the sum disagrees with both operands. *)
  if (a >= 0 && b >= 0 && s < 0) || (a < 0 && b < 0 && s >= 0) then raise Overflow
  else chk s

let chk_mul a b =
  if a = 0 || b = 0 then 0
  else
    let p = a * b in
    if p / b <> a || (a = min_int && b = -1) || (b = min_int && a = -1)
    then raise Overflow
    else chk p

let add x y =
  let c = chk_add x.c y.c in
  if x.c = 0 && SMap.is_empty x.m then y
  else if y.c = 0 && SMap.is_empty y.m then x
  else { c;
    m = SMap.union (fun _ a b ->
          let s = chk_add a b in if s = 0 then None else Some s) x.m y.m }

let scale k x =
  if k = 0 then const 0
  else if k = 1 then begin
    ignore (chk x.c);
    SMap.iter (fun _ a -> ignore (chk a)) x.m;
    x
  end else { c = chk_mul k x.c; m = SMap.map (fun a -> chk_mul k a) x.m }

let sub x y = add x (scale (-1) y)

let equal x y = x.c = y.c && SMap.equal ( = ) x.m y.m

let compare_lin x y =
  match compare x.c y.c with
  | 0 -> SMap.compare compare x.m y.m
  | n -> n

(* x - y when it is a constant. *)
let diff x y = let d = sub x y in if SMap.is_empty d.m then Some d.c else None

let atoms x = SMap.fold (fun a _ acc -> a :: acc) x.m []

(* Substitute a term for an atom. *)
let subst a by x =
  match SMap.find_opt a x.m with
  | None -> x
  | Some k ->
      let rest = SMap.remove a x.m in
      if x.c = 0 && SMap.is_empty rest then scale k by
      else add { x with m = rest } (scale k by)

let to_string ?(name = fun a -> a) x =
  let parts = SMap.fold (fun a k acc ->
    (if k = 1 then name a else Printf.sprintf "%d*%s" k (name a)) :: acc) x.m [] in
  let parts = List.rev parts in
  match parts, x.c with
  | [], c -> string_of_int c
  | ps, 0 -> String.concat " + " ps
  | ps, c when c < 0 -> String.concat " + " ps ^ " - " ^ string_of_int (-c)
  | ps, c -> String.concat " + " ps ^ " + " ^ string_of_int c

type interval = lin * lin

let interval_equal (a, b) (c, d) = equal a c && equal b d

let is_empty (lo, hi) = match diff hi lo with Some d -> d <= 0 | None -> false

(* Equalities known on the path, as atom := term substitutions applied
   before comparing. *)
type eqs = (string * lin) list

let normalize (eqs : eqs) x = List.fold_left (fun x (a, t) -> subst a t x) x eqs

(* GitHub issue #975: linear facts known on the path, from branch
   conditions, loop bounds and `min` bindings. [ge] holds terms t with
   t >= 0; [mins] holds definitions atom = min(a, b). Both are
   quantifier-free linear integer arithmetic. *)
type facts = { ge : lin list; mins : (string * lin * lin) list }

let no_facts = { ge = []; mins = [] }

let normalize_facts (eqs : eqs) f =
  { ge = List.map (normalize eqs) f.ge;
    mins = List.map (fun (x, a, b) -> (x, normalize eqs a, normalize eqs b)) f.mins }

let coeff a x = match SMap.find_opt a x.m with Some k -> k | None -> 0

(* Does t >= 0 follow from the facts? A sound, incomplete search: t holds
   outright when its constant and every coefficient are nonnegative (every
   atom is a usize); else subtract a fact that shares an atom with t with
   the same sign (t = g + (t - g) with g >= 0), or expand an atom defined as a min: k*min(a, b) + r >= 0
   holds iff both k*a + r and k*b + r do (k > 0), and -k*min(a, b) + r >= 0
   holds if either -k*a + r or -k*b + r does. [depth] bounds the steps. *)
let entails ?(depth = 4) (f : facts) (t : lin) =
  let rec go depth t =
    (t.c >= 0 && SMap.for_all (fun _ k -> k >= 0) t.m)
    || (depth > 0 &&
        (List.exists (fun g ->
           SMap.exists (fun a k -> let j = coeff a g in j <> 0 && (j > 0) = (k > 0)) t.m
           && go (depth - 1) (sub t g)) f.ge
         || List.exists (fun (x, a, b) ->
              let k = coeff x t in
              if k = 0 then false else
              let rest = { t with m = SMap.remove x t.m } in
              let ta = add rest (scale k a) and tb = add rest (scale k b) in
              if k > 0 then go (depth - 1) ta && go (depth - 1) tb
              else go (depth - 1) ta || go (depth - 1) tb) f.mins))
  in
  try go depth t with Overflow -> false

(* None: covered. Some cur: the first point the walk could not cover. *)
let uncovered ?(need_gap = true) ?(eqs = []) ?(facts = no_facts) (ivs : interval list) ((a, b) : interval) =
  try
  let n = normalize eqs in
  let facts = normalize_facts eqs facts in
  let ge x y = entails facts (sub x y) in   (* x >= y *)
  let ivs = List.map (fun (lo, hi) -> (n lo, n hi)) ivs in
  let b = n b in
  (* Explore reachable endpoints rather than greedily taking the first
     interval. Two known prefixes can have incomparable symbolic ends;
     choosing the shorter-looking one must not hide a usable adjacent
     chunk. Each endpoint is visited once, so the search stays bounded by
     the number of intervals. Every edge still requires lo <= cur <= hi. *)
  let visited = ref [] in
  let rec go cur report =
    if ge cur b then None
    else if List.exists (fun (lo, hi) -> ge cur lo && ge hi b) ivs then None
    else begin
      visited := cur :: !visited;
      let next = List.filter_map (fun (lo, hi) ->
        if ge cur lo && ge hi cur && not (equal hi cur) then Some hi
        else None) ivs in
      let rec search first_failure = function
        | [] -> Some (Option.value ~default:report first_failure)
        | hi :: rest when List.exists (equal hi) !visited -> search first_failure rest
        | hi :: rest ->
            let advanced = entails facts (sub (sub hi cur) (const 1)) in
            match go hi (if advanced then hi else report) with
            | None -> None
            | Some point -> search (match first_failure with
                | None -> Some point | old -> old) rest in
      search None next
    end
  in
  let start = n a in
  (* A successful walk ends at its start or at an interval's upper bound.
     If no such endpoint can reach b, candidate checking can reject without
     exploring every edge. Diagnostics still walk to locate a useful gap. *)
  if not need_gap && not (ge start b) &&
     not (List.exists (fun (_, hi) -> ge hi b) ivs)
  then Some start else go start start
  with Overflow -> Some a

(* ---- z3 obligations ---------------------------------------------------- *)

let header = "; takibi-init-obligation v1"

(* GitHub issue #1372: the SMT name of an atom is injective. It used to map
   every character outside [A-Za-z0-9_] to '_', so the versioned binding
   "v3@1" and an atom "v3_1", or "ret:call" and "ret_call", became one z3
   constant, and an obligation over two different values could be proved
   from an equality they never had. '_' is now doubled and any other
   character becomes '_' and two hex digits, so distinct atoms stay
   distinct constants. *)
(* GitHub issue #1394: the encoding lives in Smt_name, the one place a
   z3 constant name can be made. *)
let smt_atom a = Smt_name.to_string (Smt_name.atom a)

let smt_int k = if k < 0 then Printf.sprintf "(- %d)" (-k) else string_of_int k

let smt x =
  let terms = SMap.fold (fun a k acc ->
    (if k = 1 then smt_atom a else Printf.sprintf "(* %s %s)" (smt_int k) (smt_atom a))
    :: acc) x.m [] in
  match List.rev terms, x.c with
  | [], c -> smt_int c
  | [t], 0 -> t
  | ts, 0 -> "(+ " ^ String.concat " " ts ^ ")"
  | ts, c -> "(+ " ^ String.concat " " ts ^ " " ^ smt_int c ^ ")"

(* The shared prelude of an init obligation: header, every atom declared
   as a usize, the path's equalities and facts. [terms] are the other
   terms the query names, so their atoms are declared too. *)
let prelude ~rule ~claim ?(facts = no_facts) (eqs : eqs) (terms : lin list) =
  (* Drop disconnected premises, never strengthen one. The retained query
     is at least as strong: fewer assumptions cannot hide a counterexample.
     Close through equalities, inequalities and min definitions so multi-hop
     arithmetic dependencies remain available. *)
  let groups = List.map (fun (x, t) -> x :: atoms t) eqs
    @ List.map atoms facts.ge
    @ List.map (fun (x, l, r) -> x :: atoms l @ atoms r) facts.mins in
  let intersects needed names = List.exists (fun x -> SSet.mem x needed) names in
  let rec close needed =
    let next = List.fold_left (fun needed names ->
      if intersects needed names then List.fold_left (fun s x -> SSet.add x s) needed names
      else needed) needed groups in
    if SSet.equal next needed then needed else close next in
  let needed = close (SSet.of_list (List.concat_map atoms terms)) in
  let keep names = names = [] || intersects needed names in
  let eqs = List.filter (fun (x, t) -> keep (x :: atoms t)) eqs in
  let facts = { ge = List.filter (fun t -> keep (atoms t)) facts.ge;
    mins = List.filter (fun (x, l, r) -> keep (x :: atoms l @ atoms r)) facts.mins } in
  let all = List.concat_map atoms terms
    @ List.concat_map (fun (x, t) -> x :: atoms t) eqs
    @ List.concat_map atoms facts.ge
    @ List.concat_map (fun (x, l, r) -> x :: atoms l @ atoms r) facts.mins in
  let all = List.sort_uniq compare all in
  let buf = Buffer.create 512 in
  let line s = Buffer.add_string buf s; Buffer.add_char buf '\n' in
  line header;
  line ("; rule: " ^ rule);
  line ("; claim: " ^ claim);
  line "(set-logic QF_LIA)";
  List.iter (fun x ->
    line (Printf.sprintf "(declare-const %s Int)" (smt_atom x));
    line (Printf.sprintf "(assert (and (<= 0 %s) (< %s 18446744073709551616)))"
            (smt_atom x) (smt_atom x))) all;
  List.iter (fun (x, t) ->
    line (Printf.sprintf "(assert (= %s %s))" (smt_atom x) (smt t))) eqs;
  List.iter (fun t -> line (Printf.sprintf "(assert (>= %s 0))" (smt t))) facts.ge;
  List.iter (fun (x, l, r) ->
    line (Printf.sprintf "(assert (= %s (ite (<= %s %s) %s %s)))"
            (smt_atom x) (smt l) (smt r) (smt l) (smt r))) facts.mins;
  buf, line

let obligation ~claim ?(facts = no_facts) (eqs : eqs) (ivs : interval list)
    ((a, b) : interval) =
  let buf, line = prelude ~rule:"init" ~claim ~facts eqs
      (List.concat_map (fun (lo, hi) -> [lo; hi]) ((a, b) :: ivs)) in
  line "(declare-const k Int)";
  line (Printf.sprintf "(assert (and (<= %s k) (< k %s)))" (smt a) (smt b));
  let inside = List.map (fun (lo, hi) ->
    Printf.sprintf "(and (<= %s k) (< k %s))" (smt lo) (smt hi)) ivs in
  line (Printf.sprintf "(assert (not (or false %s)))" (String.concat " " inside));
  line "(check-sat)";
  Buffer.contents buf

(* GitHub issue #990: a term Init_flow built from a step it judged not to
   wrap at the usize width ([bits]): `a - b` (the term is >= 0) or `a + b`,
   `k * a` (the term is below 2^bits). The judgement is the checker's own
   search over the path facts (entails); this obligation states the machine
   property itself under the same equalities and facts, and asks z3 for a
   value k of the term outside the usize range. `unsat` proves the step is
   the machine's; `sat` names the wrapped value. *)
type nowrap = Nonneg | Below

let nowrap_obligation ~claim ~facts eqs ~bits (kind : nowrap) (t : lin) =
  let buf, line = prelude ~rule:(match kind with Nonneg -> "nowrap-sub"
                                              | Below -> "nowrap-add")
      ~claim ~facts eqs [t] in
  line "(declare-const k Int)";
  line (Printf.sprintf "(assert (= k %s))" (smt t));
  (match kind with
   | Nonneg -> line "(assert (not (>= k 0)))"
   | Below ->
       line (Printf.sprintf "(assert (not (< k %s)))"
               (if bits >= 64 then "18446744073709551616"
                else string_of_int (1 lsl bits))));
  line "(check-sat)";
  Buffer.contents buf

(* GitHub issue #798: an index [j] into a slice of length [len] that the
   runtime order graph could not prove, discharged by [entails] from the
   path facts (len - j - 1 >= 0). The obligation asserts the same facts and
   asks z3 for a path where the index is not below the length. *)
let index_obligation ~claim ~facts eqs ~(index : lin) ~(len : lin) =
  let buf, line = prelude ~rule:"index" ~claim ~facts eqs [index; len] in
  line (Printf.sprintf "(assert (not (< %s %s)))" (smt index) (smt len));
  line "(check-sat)";
  Buffer.contents buf

let call_where_obligation ~facts eqs goal =
  let buf, line = prelude ~rule:"affine-call-where"
    ~claim:"direct call where clause" ~facts eqs [goal] in
  line (Printf.sprintf "(assert (< %s 0))" (smt goal));
  line "(check-sat)";
  Buffer.contents buf

(* GitHub issue #960: the checker's reading of a literal or const leaf
   against the literal itself. [pattern] is the source's 64-bit pattern;
   this obligation spells it as the unsigned value at [bits] (usize), never
   through the checker's reading, and asks z3 for a reading k that differs.
   So the leaves every init term is built from are checked by z3, not
   assumed: #983's 0xFFFFFFFFFFFFFFFF read as -1 is a counterexample. The
   terms built from leaves are exact over mathematical integers (checked
   against Overflow), so the leaf is the one fold a term carries. *)
let leaf_obligation ~read ~(pattern : Int64.t) ~bits =
  let value =
    if bits >= 64 then Printf.sprintf "%Lu" pattern
    else Printf.sprintf "%Lu"
        (Int64.logand pattern (Int64.sub (Int64.shift_left 1L bits) 1L)) in
  String.concat "\n" [
    header; "; rule: leaf";
    Printf.sprintf "; claim: literal 0x%Lx at usize" pattern;
    "(set-logic QF_LIA)";
    "(declare-const k Int)";
    Printf.sprintf "(assert (= k %s))" (smt_int read);
    Printf.sprintf "(assert (not (= k %s)))" value;
    "(check-sat)"; "" ]
