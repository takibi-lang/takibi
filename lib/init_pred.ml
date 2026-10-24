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
   constant differences between terms: from cur = a, take an interval with
   lo <= cur < hi (both differences constant) and continue from hi, until
   b - cur <= 0. With all terms constant this is exact on a finite set; with
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

(* None: covered. Some cur: the first point the walk could not cover. *)
let uncovered ?(eqs = []) (ivs : interval list) ((a, b) : interval) =
  let n = normalize eqs in
  let ivs = List.map (fun (lo, hi) -> (n lo, n hi)) ivs in
  let b = n b in
  let rec go cur fuel =
    match diff b cur with
    | Some d when d <= 0 -> None
    | _ when fuel = 0 -> Some cur
    | _ ->
        let step = List.find_map (fun (lo, hi) ->
          match diff cur lo, diff hi cur with
          | Some x, Some y when x >= 0 && y > 0 -> Some hi
          | _ -> None) ivs in
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

let obligation ~claim (eqs : eqs) (ivs : interval list) ((a, b) : interval) =
  let all = List.concat_map (fun (lo, hi) -> atoms lo @ atoms hi)
      ((a, b) :: ivs)
    @ List.concat_map (fun (x, t) -> x :: atoms t) eqs in
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
  line "(declare-const k Int)";
  line (Printf.sprintf "(assert (and (<= %s k) (< k %s)))" (smt a) (smt b));
  let inside = List.map (fun (lo, hi) ->
    Printf.sprintf "(and (<= %s k) (< k %s))" (smt lo) (smt hi)) ivs in
  line (Printf.sprintf "(assert (not (or false %s)))" (String.concat " " inside));
  line "(check-sat)";
  Buffer.contents buf
