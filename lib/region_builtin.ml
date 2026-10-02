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

fn __region_claim__@T@(address: usize, count: usize @ n, claimed: *bool,
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
    private chunk: usize;
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

fn __region_table_claim__@T@(address: usize, count: usize @ n, claimed: *bool,
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
    let mut h: @H@ = { 0, slot, *region_table_generation(t, slot) };
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

// -- region_pool: a table that grows (#672) --------------------------------
//
// A pool is declared as a global, so `&pool` gives it the same identity on
// every lock. It grows by taking a byte region (a chunk, from the page
// allocator or any region of u8) and shrinks by giving a chunk whose slots
// are all free back as a byte region. No fixed capacity.
//
// A chunk, at its own address:
//   word 0: the next chunk's address, 0 at the end
//   word 1: its slot count
//   word 2: its length in bytes
//   words 3 .. 3 + count: each slot's state (low two bits) and generation
//   then the slots, from the first multiple of 16 after that.
// Eight bytes per slot (#675).
struct @P@ {
    private lock: usize;
    private first: usize;
}

linear struct @PG@[pool: addr] {
    private pool: usize;
    // What the caller saved before taking the lock (the kernel's interrupt
    // mask), handed back by region_pool_unlock_saved. 0 for region_pool_lock.
    private saved: usize;
}

must_use variant @GR@[c: addr, o: usize, n: usize] {
    Grown;
    TooSmall(region__u8[c, o, n]);
}

must_use variant @SH@ {
    Nothing;
    Chunk(exists c: addr. exists o: usize. exists n: usize. region__u8[c, o, n]);
}

fn region_pool_lock(p: *@P@ @ b) -> @PG@[b] !{unsafe} {
    return region_pool_lock_saving(p, 0);
}

// The same lock, carrying a value the caller saved before taking it. The
// kernel masks interrupts first and passes the previous mask here; the
// built-in has no CPU-specific code of its own (#672).
fn region_pool_lock_saving(p: *@P@ @ b, saved: usize) -> @PG@[b] !{unsafe} {
    let word: usize = p as usize;
    while (unsafe { atomic_compare_exchange_acquire(word, 0, 1) } == false) {
        while (unsafe { atomic_load_acquire(word) } != 0) { }
    }
    let mut g: @PG@[b] = { word, saved };
    return g;
}

fn region_pool_unlock(g: sink @PG@[b]) !{unsafe} {
    let saved: usize = region_pool_unlock_saved(g);
}

// Releases the lock and gives back what region_pool_lock_saving was handed,
// for the caller to restore after the lock is gone.
fn region_pool_unlock_saved(g: sink @PG@[b]) -> usize !{unsafe} {
    let saved: usize = g.saved;
    unsafe { atomic_store_release(g.pool, 0); }
    return saved;
}

// The chunk an address lies in, or 0. Walks the pool's own list, so an
// address the pool did not hand out is never read through.
private fn pool_chunk_of(g: borrow @PG@[b], address: usize) -> usize !{unsafe} {
    let mut chunk: usize = *pool_word(g.pool, 1);
    while (chunk != 0) {
        let base: usize = pool_slots_base(chunk);
        let count: usize = *pool_word(chunk, 1);
        if (address >= base && address < base + count * sizeof(@T@)) {
            return chunk;
        }
        chunk = *pool_word(chunk, 0);
    }
    return 0;
}

private fn pool_slot(g: borrow @PG@[b], address: usize @ k) -> @SL@[b, k] {
    let mut s: @SL@[b, k] = { address };
    return s;
}

fn region_pool_grow(g: borrow @PG@[b], chunk: sink region__u8[c, o, n])
        -> @GR@[c, o, n] !{unsafe} {
    let bytes: usize = region_count(chunk);
    if (bytes < 64 + sizeof(@T@) + 8) { return @GR@::TooSmall(chunk); }
    let address: usize = chunk.address;
    let count: usize = (bytes - 48) / (sizeof(@T@) + 8);
    *pool_word(address, 1) = count;
    *pool_word(address, 2) = bytes;
    let mut i: usize = 0;
    while (i < count) { *pool_word(address, 3 + i) = 0; i = i + 1; }
    *pool_word(address, 0) = *pool_word(g.pool, 1);
    *pool_word(g.pool, 1) = address;
    region_discharge(chunk);
    return @GR@::Grown;
}

fn region_alloc(g: borrow @PG@[b]) -> @A@[b] !{unsafe} {
    let mut chunk: usize = *pool_word(g.pool, 1);
    while (chunk != 0) {
        let count: usize = *pool_word(chunk, 1);
        let mut i: usize = 0;
        while (i < count) {
            let state: *usize = pool_word(chunk, 3 + i);
            if ((*state & 3) == @T@__REGION_FREE) {
                *state = (*state & ~(3 as usize)) | @T@__REGION_OUT;
                return @A@::Allocated(pool_slot(g,
                    pool_slots_base(chunk) + i * sizeof(@T@)));
            }
            i = i + 1;
        }
        chunk = *pool_word(chunk, 0);
    }
    return @A@::Full;
}

fn region_give(g: borrow @PG@[b], s: sink @SL@[b, k]) -> @H@ !{unsafe} {
    let chunk: usize = pool_chunk_of(g, s.address);
    let i: usize = (s.address - pool_slots_base(chunk)) / sizeof(@T@);
    let state: *usize = pool_word(chunk, 3 + i);
    *state = (*state & ~(3 as usize)) | @T@__REGION_LIVE;
    let mut h: @H@ = { chunk, i, *state >> 2 };
    region_slot_discharge(s);
    return h;
}

fn region_take(g: borrow @PG@[b], h: @H@) -> @TK@[b] !{unsafe} {
    let mut chunk: usize = *pool_word(g.pool, 1);
    while (chunk != 0 && chunk != h.chunk) { chunk = *pool_word(chunk, 0); }
    if (chunk == 0 || h.slot >= *pool_word(chunk, 1)) { return @TK@::Stale; }
    let state: *usize = pool_word(chunk, 3 + h.slot);
    if ((*state & 3) != @T@__REGION_LIVE || (*state >> 2) != h.generation) {
        return @TK@::Stale;
    }
    *state = (*state & ~(3 as usize)) | @T@__REGION_OUT;
    return @TK@::Taken(pool_slot(g,
        pool_slots_base(chunk) + h.slot * sizeof(@T@)));
}

fn region_free(g: borrow @PG@[b], s: sink @SL@[b, k]) !{unsafe} {
    let chunk: usize = pool_chunk_of(g, s.address);
    let i: usize = (s.address - pool_slots_base(chunk)) / sizeof(@T@);
    let state: *usize = pool_word(chunk, 3 + i);
    *state = (((*state >> 2) + 1) << 2) | @T@__REGION_FREE;
    region_slot_discharge(s);
}

// Give back a chunk whose slots are all Free, as the byte region it came
// in as. Its identity is new: the pool owned those bytes, and this is where
// they leave it.
fn region_pool_shrink(g: borrow @PG@[b]) -> @SH@ !{unsafe} {
    let mut previous: usize = 0;
    let mut chunk: usize = *pool_word(g.pool, 1);
    while (chunk != 0) {
        let count: usize = *pool_word(chunk, 1);
        let mut all_free: bool = true;
        let mut i: usize = 0;
        while (i < count) {
            if ((*pool_word(chunk, 3 + i) & 3) != @T@__REGION_FREE) {
                all_free = false;
            }
            i = i + 1;
        }
        if (all_free) {
            let next: usize = *pool_word(chunk, 0);
            if (previous == 0) { *pool_word(g.pool, 1) = next; }
            else { *pool_word(previous, 0) = next; }
            return @SH@::Chunk(region_bytes_mint(chunk, *pool_word(chunk, 2)));
        }
        previous = chunk;
        chunk = *pool_word(chunk, 0);
    }
    return @SH@::Nothing;
}
|}

(* Shared by every instance: a chunk leaving a pool is a byte region again,
   with a new identity. Private to the built-in file. *)
let common_source = {|
// The page allocator's boundary (#672): the caller asserts that `bytes`
// bytes at `address` are its alone -- a page run it was just given. The one
// way a byte region comes from an address rather than a declared array; it
// carries the `unsafe` effect, so every caller declares it and the trusted
// base counts it.
must_use variant RegionBytes {
    Assumed(exists c: addr. exists n: usize. region__u8[c, 0, n]);
}

fn region_bytes_assume(address: usize, bytes: usize) -> RegionBytes !{unsafe} {
    return RegionBytes::Assumed(region_bytes_mint(address, bytes));
}

private fn pool_word(address: usize, i: usize) -> *usize !{unsafe} {
    return unsafe { (address + i * 8) as *usize };
}

private fn pool_slots_base(chunk: usize) -> usize !{unsafe} {
    let count: usize = *pool_word(chunk, 1);
    return (chunk + (3 + count) * 8 + 15) & ~(15 as usize);
}


private fn region_bytes_mint(address: usize, bytes: usize @ n)
        -> region__u8[c, 0, n] {
    let mut r: region__u8[c, 0, n] = { address, bytes };
    return r;
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
  |> replace_all ~sub:"@PG@" ~by:("RegionPoolGuard__" ^ elem)
  |> replace_all ~sub:"@GR@" ~by:("RegionGrow__" ^ elem)
  |> replace_all ~sub:"@SH@" ~by:("RegionShrink__" ^ elem)
  |> replace_all ~sub:"@P@" ~by:("RegionPool__" ^ elem)
  |> replace_all ~sub:"@TO@" ~by:("RegionTableOf__" ^ elem)
  |> replace_all ~sub:"@TK@" ~by:("RegionTake__" ^ elem)
  |> replace_all ~sub:"@A@" ~by:("RegionAlloc__" ^ elem)
  |> replace_all ~sub:"@H@" ~by:("RegionHandle__" ^ elem)
  |> replace_all ~sub:"@T@" ~by:elem

(* Every instance is parsed from the same template, so without care two
   instances' calls would sit at the same source position -- and the
   compiler records which overload a call resolved to by position, so one
   instance's choice would overwrite the other's. Each parse starts on its
   own line range instead; the file name stays the same, which keeps the
   instances' private fields visible to each other. *)
let next_first_line = ref 1

let parse_source src =
  if String.trim src = "" then [] else
  let lexbuf = Lexing.from_string src in
  Lexing.set_filename lexbuf builtin_file;
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p with Lexing.pos_lnum = !next_first_line };
  next_first_line := !next_first_line + 100000;
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
         "RegionSlot__"; "RegionPool__"; "RegionPoolGuard__"; "RegionGrow__";
         "RegionShrink__" ] in
  List.iter (fun item -> scan (Ast.show_toplevel item)) prog;
  Hashtbl.fold (fun k () acc -> k :: acc) found [] |> List.sort compare

(* Every global array of a named element type: name -> (element, length).
   Monomorphize.lower_regions consults it to lower `region_of(name)` and
   records which ones were claimed. *)
let global_arrays (prog : Ast.toplevel list) =
  List.filter_map (function
    | Ast.LetDef (name, Some (Ast.TypeArray (elem_ty, n)), _, _, _, _, _) ->
        (match elem_ty with
         | Ast.TypeNamed elem -> Some (name, (elem, n))
         | Ast.TypeU8 -> Some (name, ("u8", n))
         | _ -> None)
    | _ -> None) prog

(* A program that names RegionBytes or region_bytes_assume without any
   typed region still needs the u8 instance and the common source. *)
let region_bytes_used (prog : Ast.toplevel list) =
  List.exists (fun item ->
    let text = Ast.show_toplevel item in
    let contains sub =
      let n = String.length text and m = String.length sub in
      let rec go i = i + m <= n && (String.sub text i m = sub || go (i + 1)) in
      go 0 in
    contains "region_bytes_assume" || contains "RegionBytes") prog

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
    next_first_line := 1;
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
    (* Every instance's pool takes chunks as regions of u8, so u8's own
       instance is always there. *)
    let uses_bytes = elems <> [] || region_bytes_used prog in
    let elems = if not uses_bytes || List.mem "u8" elems then elems
                else "u8" :: elems in
    let defs = if not uses_bytes then []
      else List.concat_map (fun elem -> parse_source (instance elem)) elems
           @ parse_source common_source in
    let flags = parse_source (String.concat "" (List.map (fun (name, (_, n)) ->
      Printf.sprintf "let mut %s: bool = false;\nlet mut %s: [usize; %d];\n"
        (flag_name name) (meta_name name) (2 * n)) claimed)) in
    let lock_defs = parse_source (String.concat "" (List.filter_map (fun name ->
      Option.map (lock_source name) (List.assoc_opt name !Monomorphize.region_arrays))
      locks)) in
    defs @ flags @ lock_defs @ prog
  end
