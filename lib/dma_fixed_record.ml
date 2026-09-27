(* Compiler-owned authority storage for a fixed DMA record. The first
   variant case has a zero pointer payload, so the zero-initialized global
   starts with exactly one CPU token. Source cannot spell a second slot or
   token declaration without a duplicate top-level name error. *)

open Ast

let run (prog : toplevel list) : toplevel list =
  let additions = ref [] in
  List.iter (function
    | StructDef (record, _, _, _, _, loc)
      when Dma_fixed_registry.is_fixed record ->
        let cpu = Dma_fixed_registry.cpu_token record in
        let device = Dma_fixed_registry.device_token record in
        let authority = Dma_fixed_registry.authority_variant record in
        let slot = Dma_fixed_registry.slot_type record in
        let global = Dma_fixed_registry.slot_global record in
        additions :=
          OpaqueStructDef (cpu, KindLinear, true, loc) ::
          OpaqueStructDef (device, KindLinear, true, loc) ::
          VariantDef (authority, [],
            ["Cpu", Some (TypePtr (TypeNamed cpu));
             "Empty", None;
             "Device", Some (TypePtr (TypeNamed device))],
            false, loc) ::
          StructDef (slot,
            ["mutex", TypeNamed "Mutex"; "value", TypeNamed authority],
            false, None, ["value"], loc) ::
          LetDef (global, Some (TypeNamed slot), None, None,
            true, true, loc) :: !additions
    | _ -> ()) prog;
  prog @ List.rev !additions
