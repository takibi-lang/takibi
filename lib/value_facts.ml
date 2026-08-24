(* Conservative integer facts inferred for one expression or binding.

   This is deliberately separate from source-level refined types.  A refined
   type is an API contract; these facts are local evidence and are discarded
   at joins or invalidation points whenever every incoming path cannot support
   them.

   [integer] uses a sign plus an unsigned Int64 magnitude.  Unlike OCaml int
   or signed Int64 bounds, it represents the complete mathematical range
   needed by all Takibi integer bases: -2^63 through 2^64-1. *)

type signedness = Signed | Unsigned
type base = { signedness : signedness; bits : int }

type sign = Negative | Zero | Positive
type integer = { sign : sign; magnitude : int64 }

type interval = { lo : integer; hi : integer }  (* inclusive *)

type t = {
  base : base;
  interval : interval;
  exact : integer option;
  excluded : integer list;
}

let compare_magnitude = Int64.unsigned_compare

let compare_integer a b =
  match a.sign, b.sign with
  | Negative, Negative -> compare_magnitude b.magnitude a.magnitude
  | Negative, _ -> -1
  | _, Negative -> 1
  | Zero, Zero -> 0
  | Zero, Positive -> -1
  | Positive, Zero -> 1
  | Positive, Positive -> compare_magnitude a.magnitude b.magnitude

let equal_integer a b = compare_integer a b = 0

let zero = { sign = Zero; magnitude = 0L }

let positive magnitude =
  if magnitude = 0L then zero else { sign = Positive; magnitude }

let negative magnitude =
  if magnitude = 0L then zero else { sign = Negative; magnitude }

let of_signed_int64 value =
  if value = 0L then zero
  else if value > 0L then positive value
  else negative (Int64.neg value)

let of_unsigned_int64 = positive

let to_string value =
  match value.sign with
  | Zero -> "0"
  | Positive -> Printf.sprintf "%Lu" value.magnitude
  | Negative -> Printf.sprintf "-%Lu" value.magnitude

let validate_base base =
  if not (List.mem base.bits [8; 16; 32; 64]) then
    invalid_arg "Value_facts: integer width must be 8, 16, 32, or 64"

let power_of_two bits = Int64.shift_left 1L bits

let full_interval base =
  validate_base base;
  match base.signedness, base.bits with
  | Unsigned, 64 ->
      { lo = zero; hi = positive Int64.minus_one }
  | Unsigned, bits ->
      { lo = zero; hi = positive (Int64.pred (power_of_two bits)) }
  | Signed, 64 ->
      { lo = negative Int64.min_int; hi = positive Int64.max_int }
  | Signed, bits ->
      let half = power_of_two (bits - 1) in
      { lo = negative half; hi = positive (Int64.pred half) }

let unknown base =
  { base; interval = full_interval base; exact = None; excluded = [] }

let interval_excludes interval value =
  compare_integer value interval.lo < 0 || compare_integer value interval.hi > 0

let excludes facts value =
  interval_excludes facts.interval value
  || List.exists (equal_integer value) facts.excluded

let max_excluded_values = 2

let add_exclusion facts value =
  if excludes facts value then facts
  else if List.length facts.excluded >= max_excluded_values then facts
  else { facts with excluded = value :: facts.excluded }

let exact base value =
  let full = full_interval base in
  if compare_integer value full.lo < 0 || compare_integer value full.hi > 0 then
    invalid_arg "Value_facts.exact: value is outside its base type";
  let facts =
    { base; interval = { lo = value; hi = value }; exact = Some value;
      excluded = [] }
  in
  if equal_integer value zero then facts else add_exclusion facts zero

let interval base lo hi =
  let full = full_interval base in
  if compare_integer lo hi > 0
     || compare_integer lo full.lo < 0
     || compare_integer hi full.hi > 0 then
    invalid_arg "Value_facts.interval: invalid or out-of-base interval";
  let exact = if equal_integer lo hi then Some lo else None in
  let facts = { base; interval = { lo; hi }; exact; excluded = [] } in
  if interval_excludes facts.interval zero then add_exclusion facts zero else facts

let same_base a b =
  a.signedness = b.signedness && a.bits = b.bits

let join a b =
  if not (same_base a.base b.base) then
    invalid_arg "Value_facts.join: base type mismatch";
  let lo = if compare_integer a.interval.lo b.interval.lo <= 0
    then a.interval.lo else b.interval.lo in
  let hi = if compare_integer a.interval.hi b.interval.hi >= 0
    then a.interval.hi else b.interval.hi in
  let exact = match a.exact, b.exact with
    | Some x, Some y when equal_integer x y -> Some x
    | _ -> None
  in
  let candidates = a.excluded @ b.excluded in
  let excluded = List.fold_left (fun kept value ->
    if List.exists (equal_integer value) kept
       || not (excludes a value && excludes b value)
       || List.length kept >= max_excluded_values then kept
    else value :: kept
  ) [] candidates in
  { base = a.base; interval = { lo; hi }; exact; excluded }

let invalidate facts = unknown facts.base

let prove_nonzero facts = add_exclusion facts zero

let multiply_exact a b =
  if not (same_base a.base b.base) then
    invalid_arg "Value_facts.multiply_exact: base type mismatch";
  match a.exact, b.exact with
  | Some x, Some y ->
      if x.sign = Zero || y.sign = Zero then Some (exact a.base zero)
      else
        let result_sign = if x.sign = y.sign then Positive else Negative in
        let full = full_interval a.base in
        let limit = match result_sign with
          | Positive -> full.hi.magnitude
          | Negative -> full.lo.magnitude
          | Zero -> assert false
        in
        let fits =
          Int64.unsigned_compare x.magnitude
            (Int64.unsigned_div limit y.magnitude) <= 0
        in
        if not fits then None
        else
          let magnitude = Int64.mul x.magnitude y.magnitude in
          let value = { sign = result_sign; magnitude } in
          Some (exact a.base value)
  | _ -> None

let cast_integer base value =
  validate_base base;
  let raw = match value.sign with
    | Zero -> 0L
    | Positive -> value.magnitude
    | Negative -> Int64.neg value.magnitude
  in
  let raw =
    if base.bits = 64 then raw
    else Int64.logand raw (Int64.pred (power_of_two base.bits))
  in
  match base.signedness with
  | Unsigned -> of_unsigned_int64 raw
  | Signed ->
      let sign_bit = Int64.shift_left 1L (base.bits - 1) in
      if Int64.logand raw sign_bit = 0L then positive raw
      else
        let magnitude =
          if base.bits = 64 then Int64.neg raw
          else Int64.sub (power_of_two base.bits) raw
        in
        negative magnitude

let cast_exact base facts =
  match facts.exact with
  | Some value -> Some (exact base (cast_integer base value))
  | None -> None
