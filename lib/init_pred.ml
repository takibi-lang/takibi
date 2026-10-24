(* GitHub issue #954: the initialization predicate of an array or slice leaf,
   Init(k) for k in a union of half-open intervals [lo, hi) whose bounds are
   linear integer terms (docs/VERIFICATION_DESIGN.md).

   Terms are mathematical integers over ATOMS: the value of an immutable
   binding (`v<id>`), the length of a slice binding (`len<id>`), a call's
   result (`result`) or a contract arm's payload binder. Every atom is a
   usize, so it lies in [0, 2^64). A term only ever comes from a slice
   bound or an index the program itself computes and bounds-checks, so the
   mathematical value is the machine's.

   Coverage of a goal [a, b) is decided by a chain walk that needs only
   constant differences between terms: from cur = a, stop when b - cur <= 0
   or some interval has lo <= cur and hi >= b; else take an interval with
   lo <= cur < hi and continue from hi. With all terms constant this is exact on a finite set; with
   symbolic terms it is a sound, incomplete decision in quantifier-free
   linear integer arithmetic. Every positive conclusion is written as an
   SMT-LIB obligation (QF_LIA, one existential point k) that z3 re-checks
   under --emit-range-obligations, the channel of #952. *)

module SMap = Map.Make (String)

type lin = { c : int; m : int SMap.t }   (* c + sum coeff * atom *)

let const c = { c; m = SMap.empty }
let atom a = { c = 0; m = SMap.singleton a 1 }

let add x y =
  { c = x.c + y.c;
    m = SMap.union (fun _ a b -> if a + b = 0 then None else Some (a + b)) x.m y.m }

let scale k x =
  if k = 0 then const 0 else { c = k * x.c; m = SMap.map (fun a -> k * a) x.m }

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
  | Some k -> add { x with m = SMap.remove a x.m } (scale k by)

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
  go depth t

(* None: covered. Some cur: the first point the walk could not cover. *)
let uncovered ?(eqs = []) ?(facts = no_facts) (ivs : interval list) ((a, b) : interval) =
  let n = normalize eqs in
  let facts = normalize_facts eqs facts in
  let ge x y = entails facts (sub x y) in   (* x >= y *)
  let ivs = List.map (fun (lo, hi) -> (n lo, n hi)) ivs in
  let b = n b in
  let rec go cur fuel =
    if ge cur b then None
    else if fuel = 0 then Some cur
    else
      (* An interval that starts at or before cur and reaches b ends the
         walk; else one that starts at or before cur and ends past it
         advances it. *)
      let reaches = List.exists (fun (lo, hi) -> ge cur lo && ge hi b) ivs in
      if reaches then None else
      let step = List.find_map (fun (lo, hi) ->
        if ge cur lo && entails facts (sub (sub hi cur) (const 1)) then Some hi
        else None) ivs in
      (match step with
       | Some hi -> go hi (fuel - 1)
       | None -> Some cur)
  in
  go (n a) (List.length ivs + 1)

(* ---- z3 obligations ---------------------------------------------------- *)

let header = "; takibi-init-obligation v1"

let smt_atom a =
  "x_" ^ String.map (fun ch ->
    match ch with
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> ch
    | _ -> '_') a

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

let obligation ~claim ?(facts = no_facts) (eqs : eqs) (ivs : interval list)
    ((a, b) : interval) =
  let all = List.concat_map (fun (lo, hi) -> atoms lo @ atoms hi)
      ((a, b) :: ivs)
    @ List.concat_map (fun (x, t) -> x :: atoms t) eqs
    @ List.concat_map atoms facts.ge
    @ List.concat_map (fun (x, l, r) -> x :: atoms l @ atoms r) facts.mins in
  let all = List.sort_uniq compare all in
  let buf = Buffer.create 512 in
  let line s = Buffer.add_string buf s; Buffer.add_char buf '\n' in
  line header;
  line "; rule: init";
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
  line "(declare-const k Int)";
  line (Printf.sprintf "(assert (and (<= %s k) (< k %s)))" (smt a) (smt b));
  let inside = List.map (fun (lo, hi) ->
    Printf.sprintf "(and (<= %s k) (< k %s))" (smt lo) (smt hi)) ivs in
  line (Printf.sprintf "(assert (not (or false %s)))" (String.concat " " inside));
  line "(check-sat)";
  Buffer.contents buf
