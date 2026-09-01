(* Source-independent contracts for Takibi's closed set of raw atomic
   intrinsics. Type checking, effect inference, and every target lowering use
   this table so an operation cannot acquire a different ordering merely by
   taking another backend branch. *)

type operation = Load | Store | Exchange | Fetch_add
type ordering = Relaxed | Acquire | Release

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
