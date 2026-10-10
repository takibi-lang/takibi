(* Source-independent contracts for Takibi's closed set of raw atomic
   intrinsics. Type checking, effect inference, and every target lowering use
   this table so an operation cannot acquire a different ordering merely by
   taking another backend branch. *)

type operation = Load | Store | Exchange | Fetch_add | Compare_exchange
type ordering = Relaxed | Acquire | Release | Acq_rel

type t = {
  name : string;
  operation : operation;
  ordering : ordering;
}

let all = [
  { name = "atomic_load_acquire"; operation = Load; ordering = Acquire };
  { name = "atomic_store_release"; operation = Store; ordering = Release };
  { name = "atomic_swap_acquire"; operation = Exchange; ordering = Acquire };
  { name = "atomic_fetch_add_relaxed"; operation = Fetch_add;
    ordering = Relaxed };
  { name = "atomic_compare_exchange_acquire"; operation = Compare_exchange;
    ordering = Acquire };
  (* GitHub issue #672: a count that both publishes and consumes (a pin
     count whose last decrement hands the object to its freer). *)
  { name = "atomic_compare_exchange_acq_rel"; operation = Compare_exchange;
    ordering = Acq_rel };
]

module StringMap = Map.Make (String)

let by_name = List.fold_left (fun specs spec ->
  StringMap.add spec.name spec specs
) StringMap.empty all

let find name = StringMap.find_opt name by_name
let is_intrinsic name = Option.is_some (find name)
let names = List.map (fun spec -> spec.name) all

let ordering_name = function
  | Relaxed -> "relaxed"
  | Acquire -> "acquire"
  | Release -> "release"
  | Acq_rel -> "acq_rel"

(* GitHub issue #637 stage 3, step C: the AtomicWord cell operations. Each
   takes a pointer to an `AtomicWord` (one private usize) instead of a bare
   address, so it needs no `unsafe`: the cell is reached only through these,
   and every access to it is atomic. Each maps onto one intrinsic above. *)
let cell_ops = [
  ("atomic_word_load", "atomic_load_acquire");
  ("atomic_word_store", "atomic_store_release");
  ("atomic_word_swap", "atomic_swap_acquire");
  ("atomic_word_fetch_add", "atomic_fetch_add_relaxed");
  ("atomic_word_compare_exchange", "atomic_compare_exchange_acquire");
]
let cell_intrinsic name = List.assoc_opt name cell_ops
let is_cell_op name = Option.is_some (cell_intrinsic name)
let cell_type = "AtomicWord"
