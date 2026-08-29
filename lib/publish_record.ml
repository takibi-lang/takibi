(* GitHub issue #299: fixed-layout records with atomic commit publication.

   The protocol this exists to make checkable is the one
   kernel/lib/diagnostic_ring.tkb already implements by hand: a writer
   clears a sequence word, writes the payload, and writes the sequence
   LAST as the commit; a reader acquire-loads that word, copies, and
   acquire-loads it again, accepting the copy only if the two agree. It is
   correct today and none of it is visible to the compiler -- the payload
   is a flat `[usize; N]` reached by hand-computed word offsets, so a
   wrong offset, a swapped pair of stores, a commit written before the
   payload, or a reader with no re-check all compile.

   What this module owns:

   - the DECLARATION rules for `struct publish Name { ... }`, checked
     where the record is written rather than where it is used;
   - synthesising the linear write token type that gates every payload
     store.

   The token is a `linear opaque struct` named after its record. Being an
   ordinary declaration rather than a new kind of value is the whole
   point: everything the linear checker already enforces -- consumed on
   every path, no storage, no cast-away, rejected at an early exit --
   applies to a half-written record with nothing further to write. A
   record left in flight is a compile error, not a slot that stays torn
   until the ring wraps over it.

   At runtime the token IS the record pointer, so a store through it is
   the same instruction a store through `*Record` would have been. The
   type is what differs, and the type is the whole mechanism. *)

open Ast

let fail pos msg = raise (Types.TypeError (pos, msg))

(* A payload field has to survive being read out of a crash snapshot by a
   debugger that is not this program: it is copied by value, compared by
   value, and decoded from raw bytes against the emitted layout. Integers,
   `bool`, and enums do all three. A pointer names an address space that
   may no longer exist by the time anyone reads the record, and an
   aggregate or array turns "copy the payload" into a question about
   interior padding -- so both are refused here rather than accepted and
   then documented as unwise. *)
let rec payload_field_ok ty =
  match ty with
  | TypeBool
  | TypeI8 | TypeI16 | TypeI32 | TypeI64
  | TypeU8 | TypeU16 | TypeU32 | TypeU64
  | TypeIsize | TypeUsize -> true
  | TypeRefined (_, _, base) -> payload_field_ok base
  | TypeNamed name -> Hashtbl.mem Type_layout.enums name
  | _ -> false

let describe_type ty =
  match ty with
  | TypePtr _ -> "a pointer"
  | TypeIo _ -> "an io value"
  | TypeArray _ -> "an array"
  | TypeU16Be | TypeU32Be -> "a big-endian wire integer"
  | TypeNamed _ -> "an aggregate"
  | _ -> "not a scalar"

(* Checked at the declaration, so a record that cannot carry the protocol
   is rejected once where it is written rather than at every use. *)
let check_declaration name fields pos =
  (match fields with
   | [] ->
       fail pos (Printf.sprintf
         "`struct publish %s` has no fields: the first field is the \
          publication field and there has to be one" name)
   | [ (only, _) ] ->
       fail pos (Printf.sprintf
         "`struct publish %s` has only the publication field '%s': a \
          record with no payload publishes nothing, so this wants at \
          least one more field" name only)
   | (seq_name, seq_ty) :: payload ->
       (match seq_ty with
        | TypeUsize -> ()
        | _ ->
            fail pos (Printf.sprintf
              "publication field '%s.%s' must be `usize`: it is written by \
               the atomic commit, and this language's atomics are \
               pointer-width. A narrower field would be published by a \
               store that also overwrote the field beside it"
              name seq_name));
       List.iter (fun (fname, fty) ->
         if not (payload_field_ok fty) then
           fail pos (Printf.sprintf
             "payload field '%s.%s' is %s: a publish record is copied by \
              value and decoded from its emitted layout by a debugger \
              outside this program, so its payload fields are integers, \
              `bool`, and enums"
             name fname (describe_type fty))) payload)

(* One whole-program pass, run before monomorphization so that every phase
   after it sees only ordinary declarations. *)
let run (prog : toplevel list) : toplevel list =
  let tokens = ref [] in
  List.iter (function
    (* `packed` is not reachable here and is not checked for: the grammar
       has no `struct publish packed` production, deliberately -- a
       publication record is read by this machine's own debugger, not put
       on a wire, so there is no byte order to declare and no reason to
       give up the natural alignment the atomic commit needs. *)
    | StructDef (name, fields, _, _, _, pos)
      when Publish_registry.is_publish name ->
        check_declaration name fields pos;
        tokens := OpaqueStructDef
                    (Publish_registry.token_name name, KindLinear, false, pos)
                  :: !tokens
    | _ -> ()) prog;
  if !tokens = [] then prog else prog @ List.rev !tokens
