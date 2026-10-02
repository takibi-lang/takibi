(* GitHub issue #672: the built-in region, memory as a linear permission.

   A `region(T)[b, n]` is the right to touch n elements of type T, the first
   at static position b. It is never copied; it is split into two adjacent
   regions and merged back, and the static arithmetic on its indices
   (Types.unify_static) is what makes a wrong-order merge a type error.
   Counts are element counts: no byte size appears in a program.

   The definitions are Takibi source compiled into the compiler and added to
   a program only under `--regions`, one copy per element type the program
   uses, in a file named BUILTIN_FILE. They are the compiler's, not the
   program's: the fields are private to that file, so a program cannot forge
   a region, and the `unsafe` they contain is part of the compiler's trusted
   base, not the program's. Everything built on them is checked.

   `region(T)` is spelled `region__T` internally, and `RegionSplit(T)` /
   `RegionOf(T)` likewise (Parser.mangle_builtin_instance). The language has
   no type-generic variants, so each element type gets its own; the
   operations are overloads distinguished by their region parameter.

   This is the first layer. region_table, the only way to store
   permissions, follows; see #672 for the three-layer decision. *)

let builtin_file = "<builtin region>"

(* One element type's instance. @T@ is the element type, @R@ the region,
   @S@ and @O@ its split and claim results. *)
let template = {|
// Internally a region has three statics: its identity (sort addr, which
// takes no arithmetic, so two regions' identities are only ever equal or
// not), its offset within that identity, and its count. A program writes two,
// `region(T)[b + k, n]`, and the parser reads b as the identity and
// `b__off + k` as the offset (Parser.region_indices).
linear struct @R@[id: addr, offset: usize, count: usize] {
    private address: usize;
    private length: usize;
}

private fn region_discharge(r: sink @R@[b, o, n]) {}

// A split whose point is only known at run time: the region comes back
// whole when it does not fit. No trap.
must_use variant @S@[b: addr, o: usize, n: usize, k: usize] {
    TooShort(@R@[b, o, n]);
    Split((@R@[b, o, k], @R@[b, o + k, n - k]));
}

// A declared array's region, once. A second claim of the same array, by a
// second call or the same call run again, finds it gone.
must_use variant @O@[b: addr, n: usize] {
    Gone;
    Taken(@R@[b, 0, n]);
}

fn __region_claim(address: usize, count: usize @ n, claimed: *bool,
                  witness: *@T@ @ b) -> @O@[b, n] !{unsafe} {
    if (*claimed) { return @O@::Gone; }
    *claimed = true;
    let mut r: @R@[b, 0, n] = { address, count };
    return @O@::Taken(r);
}

fn region_split(r: sink @R@[b, o, n], at: usize @ k) -> @S@[b, o, n, k] {
    if (at > r.length) { return @S@::TooShort(r); }
    let mut head: @R@[b, o, k] = { r.address, at };
    let mut tail: @R@[b, o + k, n - k] = {
        r.address + at * sizeof(@T@), r.length - at
    };
    region_discharge(r);
    return @S@::Split((head, tail));
}

// The split point is proved within the count where the call is made
// (`where k <= n`), so there is no failure to handle.
fn region_split_static(r: sink @R@[b, o, n], at: usize @ k)
        -> (@R@[b, o, k], @R@[b, o + k, n - k]) where k <= n {
    let mut head: @R@[b, o, k] = { r.address, at };
    let mut tail: @R@[b, o + k, n - k] = {
        r.address + at * sizeof(@T@), r.length - at
    };
    region_discharge(r);
    return (head, tail);
}

// Accepted only when tail is the same region and starts where head ends.
fn region_merge(head: sink @R@[b, o, k], tail: sink @R@[b, o + k, m])
        -> @R@[b, o, k + m] {
    let mut whole: @R@[b, o, k + m] = {
        head.address, head.length + tail.length
    };
    region_discharge(head);
    region_discharge(tail);
    return whole;
}

// Element i, proved below the count where the call is made. The pointer is
// derived from the borrow of r and dies with it.
fn region_at(r: borrow @R@[b, o, n], i: usize @ k) -> *@T@ @ b !{unsafe}
        where k < n {
    return unsafe { (r.address + i * sizeof(@T@)) as *@T@ };
}

fn region_count(r: borrow @R@[b, o, n]) -> usize {
    return r.length;
}

fn region_release(r: sink @R@[b, o, n]) { region_discharge(r); }

// -- region_table: the only way to store permissions (#672, second layer) --
//
// A table holds the one-element regions of every slot of a claimed array.
// A slot is Free (in the table, unused), Live (in the table, named by a
// handle) or Out (its region is held by the program). Each slot has a
// generation, bumped on free, so a stored handle to a freed slot is
// refused. The state and generation words are a hidden array per table.
linear struct @TBL@[base: addr, count: usize] {
    private address: usize;
    private length: usize;
    private meta: usize;
    // The lock word of a guarded table (region_table_lock), 0 for a table
    // claimed once (region_table_of).
    private lock: usize;
}

// One slot's permission, out of its table: b is the TABLE's position and k
// the slot index. It is its own type rather than a region of the array, so
// a slot of another table has another b and nothing solves one for the
// other -- the static arithmetic would, given region[b + k, 1].
linear struct @SL@[table: addr, slot: usize] {
    private address: usize;
}

private fn region_slot_discharge(s: sink @SL@[b, k]) {}

// The element in a slot; the pointer dies with the borrow of the slot.
fn region_slot_at(s: borrow @SL@[b, k]) -> *@T@ @ b !{unsafe} {
    return unsafe { s.address as *@T@ };
}

// What a program may store: a slot and the generation it was handed out in.
struct @H@ {
    private slot: usize;
    private generation: usize;
}

must_use variant @TO@[b: addr, n: usize] {
    Gone;
    Taken(@TBL@[b, n]);
}

must_use variant @A@[b: addr] {
    Full;
    Allocated(exists k: usize. @SL@[b, k]);
}

must_use variant @TK@[b: addr] {
    Stale;
    Taken(exists k: usize. @SL@[b, k]);
}

const @T@__REGION_FREE: usize = 0;
const @T@__REGION_LIVE: usize = 1;
const @T@__REGION_OUT: usize = 2;

private fn region_table_state(t: borrow @TBL@[b, n], slot: usize) -> *usize
        !{unsafe} {
    return unsafe { (t.meta + slot * 16) as *usize };
}

private fn region_table_generation(t: borrow @TBL@[b, n], slot: usize)
        -> *usize !{unsafe} {
    return unsafe { (t.meta + slot * 16 + 8) as *usize };
}

private fn region_slot(t: borrow @TBL@[b, n], slot: usize @ k)
        -> @SL@[b, k] {
    let mut s: @SL@[b, k] = { t.address + slot * sizeof(@T@) };
    return s;
}

private fn region_slot_of(t: borrow @TBL@[b, n], s: borrow @SL@[b, k])
        -> usize {
    return (s.address - t.address) / sizeof(@T@);
}

fn __region_table_claim(address: usize, count: usize @ n, claimed: *bool,
                        meta: usize, witness: *@T@ @ b) -> @TO@[b, n] !{unsafe} {
    if (*claimed) { return @TO@::Gone; }
    *claimed = true;
    let mut t: @TBL@[b, n] = { address, count, meta, 0 };
    return @TO@::Taken(t);
}

// A Free slot becomes Out, its region handed to the caller.
fn region_alloc(t: borrow @TBL@[b, n]) -> @A@[b] !{unsafe} {
    let mut slot: usize = 0;
    while (slot < t.length) {
        if (*region_table_state(t, slot) == @T@__REGION_FREE) {
            *region_table_state(t, slot) = @T@__REGION_OUT;
            return @A@::Allocated(region_slot(t, slot));
        }
        slot = slot + 1;
    }
    return @A@::Full;
}

// Give an Out slot back as Live. The slot names its table by b, so a slot
// of another table does not type-check.
fn region_give(t: borrow @TBL@[b, n], s: sink @SL@[b, k]) -> @H@ !{unsafe} {
    let slot: usize = region_slot_of(t, s);
    *region_table_state(t, slot) = @T@__REGION_LIVE;
    let mut h: @H@ = { slot, *region_table_generation(t, slot) };
    region_slot_discharge(s);
    return h;
}

// Take a Live slot out by a stored handle. A handle whose slot was freed
// since, or is out already, is Stale.
fn region_take(t: borrow @TBL@[b, n], h: @H@) -> @TK@[b] !{unsafe} {
    if (h.slot >= t.length) { return @TK@::Stale; }
    if (*region_table_state(t, h.slot) != @T@__REGION_LIVE ||
        *region_table_generation(t, h.slot) != h.generation) {
        return @TK@::Stale;
    }
    *region_table_state(t, h.slot) = @T@__REGION_OUT;
    return @TK@::Taken(region_slot(t, h.slot));
}

// A table lives for the program: there is no tear-down yet, so a table is
// kept rather than released.
fn region_table_keep(t: sink @TBL@[b, n]) {}

// Give a guarded table back: releases its lock. Every slot taken out under
// it stays valid and may be given back under a later lock.
fn region_table_unlock(t: sink @TBL@[b, n]) !{unsafe} {
    if (t.lock != 0) { unsafe { atomic_store_release(t.lock, 0); } }
}

// Free an Out slot: every handle to it becomes Stale.
fn region_free(t: borrow @TBL@[b, n], s: sink @SL@[b, k]) !{unsafe} {
    let slot: usize = region_slot_of(t, s);
    *region_table_state(t, slot) = @T@__REGION_FREE;
    *region_table_generation(t, slot) = *region_table_generation(t, slot) + 1;
    region_slot_discharge(s);
}
|}

let replace_all ~sub ~by s =
  let lsub = String.length sub in
  let buf = Buffer.create (String.length s) in
  let i = ref 0 in
  while !i < String.length s do
    if !i + lsub <= String.length s && String.sub s !i lsub = sub then begin
      Buffer.add_string buf by; i := !i + lsub
    end else begin
      Buffer.add_char buf s.[!i]; incr i
    end
  done;
  Buffer.contents buf

let instance elem =
  template
  |> replace_all ~sub:"@R@" ~by:("region__" ^ elem)
  |> replace_all ~sub:"@S@" ~by:("RegionSplit__" ^ elem)
  |> replace_all ~sub:"@O@" ~by:("RegionOf__" ^ elem)
  |> replace_all ~sub:"@TBL@" ~by:("RegionTable__" ^ elem)
  |> replace_all ~sub:"@SL@" ~by:("RegionSlot__" ^ elem)
  |> replace_all ~sub:"@TO@" ~by:("RegionTableOf__" ^ elem)
  |> replace_all ~sub:"@TK@" ~by:("RegionTake__" ^ elem)
  |> replace_all ~sub:"@A@" ~by:("RegionAlloc__" ^ elem)
  |> replace_all ~sub:"@H@" ~by:("RegionHandle__" ^ elem)
  |> replace_all ~sub:"@T@" ~by:elem

let parse_source src =
  if String.trim src = "" then [] else
  let lexbuf = Lexing.from_string src in
  Lexing.set_filename lexbuf builtin_file;
  try Parser.program Lexer.read lexbuf
  with Parser.Error ->
    let pos = Lexing.lexeme_start_p lexbuf in
    raise (Types.TypeError (pos, Printf.sprintf
      "BUG: the built-in region source does not parse at '%s'"
      (Lexing.lexeme lexbuf)))

(* Element types the program names: `region(T)`, `RegionSplit(T)` and
   `RegionOf(T)` all reach the AST as a mangled name, and a claimed array
   names its element type in its declaration. Read off the printed AST,
   which every construct derives. *)
let element_types (prog : Ast.toplevel list) claimed =
  let found = Hashtbl.create 8 in
  List.iter (fun (_, (elem, _)) -> Hashtbl.replace found elem ()) claimed;
  let scan text =
    List.iter (fun prefix ->
      let lp = String.length prefix in
      let n = String.length text in
      let i = ref 0 in
      while !i + lp <= n do
        if String.sub text !i lp = prefix then begin
          let j = ref (!i + lp) in
          while !j < n && (match text.[!j] with
              | 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' -> true | _ -> false) do
            incr j done;
          if !j > !i + lp then
            Hashtbl.replace found (String.sub text (!i + lp) (!j - !i - lp)) ();
          i := !j
        end else incr i
      done) [ "region__"; "RegionSplit__"; "RegionOf__"; "RegionTable__";
         "RegionTableOf__"; "RegionTake__"; "RegionAlloc__"; "RegionHandle__";
         "RegionSlot__" ] in
  List.iter (fun item -> scan (Ast.show_toplevel item)) prog;
  Hashtbl.fold (fun k () acc -> k :: acc) found [] |> List.sort compare

(* Every global array of a named element type: name -> (element, length).
   Monomorphize.lower_regions consults it to lower `region_of(name)` and
   records which ones were claimed. *)
let global_arrays (prog : Ast.toplevel list) =
  List.filter_map (function
    | Ast.LetDef (name, Some (Ast.TypeArray (Ast.TypeNamed elem, n)),
                  _, _, _, _, _) -> Some (name, (elem, n))
    | _ -> None) prog

let flag_name array = "__region_claimed__" ^ array
let lock_name array = "__region_lock__" ^ array

(* A guarded table's lock: one spin lock word per array, taken by an
   acquire compare-exchange and released by a release store. The table's
   identity comes from `&array`, which is the same static on every call, so
   a slot taken under one lock is given back under another. No interrupt
   masking: that is the kernel's pool_lock, to be tied in when a kernel pool
   is rebuilt on this. *)
let lock_source array (elem, n) =
  Printf.sprintf {|
let mut %s: usize = 0;
fn __region_table_lock__%s(w: *[%s; %d] @ b) -> RegionTable__%s[b, %d] !{unsafe} {
    let word: usize = (&%s) as usize;
    while (unsafe { atomic_compare_exchange_acquire(word, 0, 1) } == false) {
        while (unsafe { atomic_load_acquire(word) } != 0) { }
    }
    let first: usize = w as usize;
    let mut t: RegionTable__%s[b, %d] = {
        first, %d, (%s as *usize) as usize, word
    };
    return t;
}
|} (lock_name array) array elem n elem n (lock_name array) elem n n
    ("__region_meta__" ^ array)
let meta_name array = "__region_meta__" ^ array

let run ~enabled prog =
  if not enabled then prog
  else begin
    Monomorphize.region_arrays := global_arrays prog;
    Monomorphize.region_claims := [];
    Monomorphize.region_locks := [];
    let prog = Monomorphize.lower_regions prog in
    let claims = List.sort_uniq compare (!Monomorphize.region_claims @ !Monomorphize.region_locks) in
    let locks = List.sort_uniq compare !Monomorphize.region_locks in
    List.iter (fun name ->
      if List.mem name !Monomorphize.region_claims then
        raise (Types.TypeError (Lexing.dummy_pos, Printf.sprintf
          "'%s' is claimed once and also locked; an array is one or the other"
          name))) locks;
    let claimed = List.filter_map (fun name ->
      Option.map (fun info -> (name, info))
        (List.assoc_opt name !Monomorphize.region_arrays)) claims in
    let elems = element_types prog claimed in
    let defs = List.concat_map (fun elem -> parse_source (instance elem)) elems in
    let flags = parse_source (String.concat "" (List.map (fun (name, (_, n)) ->
      Printf.sprintf "let mut %s: bool = false;\nlet mut %s: [usize; %d];\n"
        (flag_name name) (meta_name name) (2 * n)) claimed)) in
    let lock_defs = parse_source (String.concat "" (List.filter_map (fun name ->
      Option.map (lock_source name) (List.assoc_opt name !Monomorphize.region_arrays))
      locks)) in
    defs @ flags @ lock_defs @ prog
  end
