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
linear struct @R@[base: usize, count: usize] {
    private address: usize;
    private length: usize;
}

private fn region_discharge(r: sink @R@[b, n]) {}

// A split whose point is only known at run time: the region comes back
// whole when it does not fit. No trap.
must_use variant @S@[b: usize, n: usize, k: usize] {
    TooShort(@R@[b, n]);
    Split((@R@[b, k], @R@[b + k, n - k]));
}

// A declared array's region, once. A second claim of the same array, by a
// second call or the same call run again, finds it gone.
must_use variant @O@[b: usize, n: usize] {
    Gone;
    Taken(@R@[b, n]);
}

fn __region_claim(address: usize @ b, count: usize @ n, claimed: *bool,
                  witness: *@T@) -> @O@[b, n] !{unsafe} {
    if (*claimed) { return @O@::Gone; }
    *claimed = true;
    let mut r: @R@[b, n] = { address, count };
    return @O@::Taken(r);
}

fn region_split(r: sink @R@[b, n], at: usize @ k) -> @S@[b, n, k] {
    if (at > r.length) { return @S@::TooShort(r); }
    let mut head: @R@[b, k] = { r.address, at };
    let mut tail: @R@[b + k, n - k] = {
        r.address + at * sizeof(@T@), r.length - at
    };
    region_discharge(r);
    return @S@::Split((head, tail));
}

// The split point is proved within the count where the call is made
// (`where k <= n`), so there is no failure to handle.
fn region_split_static(r: sink @R@[b, n], at: usize @ k)
        -> (@R@[b, k], @R@[b + k, n - k]) where k <= n {
    let mut head: @R@[b, k] = { r.address, at };
    let mut tail: @R@[b + k, n - k] = {
        r.address + at * sizeof(@T@), r.length - at
    };
    region_discharge(r);
    return (head, tail);
}

// Accepted only when tail starts where head ends: the static terms say so.
fn region_merge(head: sink @R@[b, k], tail: sink @R@[b + k, m])
        -> @R@[b, k + m] {
    let mut whole: @R@[b, k + m] = { head.address, head.length + tail.length };
    region_discharge(head);
    region_discharge(tail);
    return whole;
}

// Element i, proved below the count where the call is made. The pointer is
// derived from the borrow of r and dies with it.
fn region_at(r: borrow @R@[b, n], i: usize @ k) -> *@T@ @ b !{unsafe}
        where k < n {
    return unsafe { (r.address + i * sizeof(@T@)) as *@T@ };
}

fn region_count(r: borrow @R@[b, n]) -> usize {
    return r.length;
}

fn region_release(r: sink @R@[b, n]) { region_discharge(r); }
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
  |> replace_all ~sub:"@T@" ~by:elem

let parse_source src =
  let lexbuf = Lexing.from_string src in
  Lexing.set_filename lexbuf builtin_file;
  Parser.program Lexer.read lexbuf

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
      done) [ "region__"; "RegionSplit__"; "RegionOf__" ] in
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

let run ~enabled prog =
  if not enabled then prog
  else begin
    Monomorphize.region_arrays := global_arrays prog;
    Monomorphize.region_claims := [];
    let prog = Monomorphize.lower_regions prog in
    let claims = List.sort_uniq compare !Monomorphize.region_claims in
    let claimed = List.filter_map (fun name ->
      Option.map (fun info -> (name, info))
        (List.assoc_opt name !Monomorphize.region_arrays)) claims in
    let elems = element_types prog claimed in
    let defs = List.concat_map (fun elem -> parse_source (instance elem)) elems in
    let flags = parse_source (String.concat "" (List.map (fun (name, _) ->
      Printf.sprintf "let mut %s: bool = false;\n" (flag_name name)) claimed)) in
    defs @ flags @ prog
  end
