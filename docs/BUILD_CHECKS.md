# Build checks

`make langcheck` runs these repository policy checks. Each check fails rather
than warns; do not bypass or weaken one merely to complete a change.

| Check | Enforced invariant |
| --- | --- |
| `check_agents_paths.py` | paths named by root guidance resolve and this table names every check |
| `check_compiler_sync_rules.py` | declared compiler counterpart changes stay synchronized |
| `check_elf_symbol_alignment.py` | linked symbols meet hardware alignment requirements |
| `check_kernel_asm_invariants.py` | linked AArch64 assembly preserves EL0 entry/return and SCTLR alignment invariants |
| `check_kernel_lib_limitations_header.py` | core kernel files state their current limitations |
| `check_diagnostic_event_ids.py` | fixed diagnostic event IDs are unique 16-bit values |
| `check_ddb_command_inventory.py` | DDB dispatch, help, documentation, classification, and coverage agree |
| `check_direct_mmio_literals.py` | MMIO pointers derive from validated resource bases |
| `check_flag_guarded_fields.py` | optional fields are read only after their presence flags |
| `check_lock_discipline.py` | global mutexes are not force-reset and raw atomics stay allowlisted |
| `check_liveness_proof_escapes.py` | every place that drops a pool's liveness proof is declared with a reason |
| `check_invariant_lines_unviewed.py` | invariant reports are either diagnostic-only or enforced by absence, never asserted as correct |
| `check_dead_slot_peek_not_retained.py` | the dead-slot-tolerant record peek is read on the spot, never bound |
| `check_execution_model_coverage.py` | mutable kernel state declares its execution model |
| `check_expected_line_endings.py` | stdout fixtures use one newline convention |
| `check_kernel_memory_map.py` | linked normal/debug layout agrees with the memory map and exact boot allocator fixtures |
| `check_kernel_log_expectations.py` | test runners wait only for logs the kernel can emit |
| `check_kernel_interactive_httpd_protocol.py` | interactive HTTP runners avoid listener/request deadlock |
| `check_platform_file_parity.py` | duplicated platform functions do not drift silently |
| `check_pool_release_paths.py` | every kernel pool has a release path or explicit exemption |
| `check_qemu_lane_ports.py` | QEMU lanes do not claim conflicting protocol ports, and every lane fits the per-session port block |
| `check_raw_pos_fname.py` | source identity uses the canonical path helpers |
| `check_single_dune_invocation.py` | exactly one rule runs `dune build`, so no second make invocation races its lock |
| `check_stale_depfiles.py` | generated kernel depfiles name live prerequisites |
| `check_suite_output.py` | batched UART cases appear in manifest order and match their fixtures |
| `check_user_payload_no_rw_globals.py` | flat EL0 payloads contain no writable globals |

The scripts and their tests are authoritative for exact mechanics. Update this
table when adding or removing a `scripts/check_*.py` check.
