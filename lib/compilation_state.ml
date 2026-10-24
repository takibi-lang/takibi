(* GitHub issue #996: the one reset of every table in lib/ that persists
   across compilations in one process (the driver's --regions re-parse,
   and every Alcotest case). Call it before parsing a program.

   Stages whose state is rebuilt on entry are not listed: Monomorphize.run
   and Region_builtin reset their own tables, Ast_strings keys its cache
   by the program's physical identity, and Llvm_gen is set up by
   Llvm_gen.setup_target and its codegen entry. Configuration refs
   (Def_extent.enabled, Range_obligation.enabled, Target_info, the
   Protocol_decl device file lists) are set by the driver, not reset. *)
let reset () =
  Const_env.reset ();
  Type_layout.reset ();
  Publish_registry.reset ();
  No_copy_registry.reset ();
  Per_cpu_registry.reset ();
  Init_state.reset ();
  Region_backing.reset ();
  Guarded_registry.reset ();
  Io_struct_registry.reset ();
  Hashtbl.reset Generic_variant.proven_empty_puts;
  Dma_fixed_registry.reset ();
  Device_protocol_registry.reset ();
  Generic_scope.reset ();
  Ast.reset_precedence_errors ();
  Type_inf.reset_compilation_state ()
