# Build checks

Every check in this repository is here, and its name says which lane runs it.
That is dispatch rather than documentation: `make langcheck` and
`make slowcheck` discover their members by glob, so a check that exists runs,
and a check that runs is inventoried here because `check_agents_paths.py`
requires it.

Each check fails rather than warns; do not bypass or weaken one merely to
complete a change.

## `check_*` -- the fast gate

`make langcheck` runs each of these under `CHECK_TIMEOUT_SECONDS`. They read
tracked files and nothing else: no sleep, no socket, no lease, no board. A
member that waits is killed and the lane goes red, which is what makes the
boundary a mechanism instead of a sentence.

`check_<subject>_controls` verifies a check rather than the product. The
suffix is description; dispatch reads only the prefix.

| Check | Enforced invariant |
| --- | --- |
| `check_agents_paths.py` | paths named by root guidance resolve and this table names every check |
| `check_archive_kernel_failure_controls.sh` | Regression controls for the failing-lane archive |
| `check_ci_opam_deps.py` | every library the dune files name is installed by the CI workflow or provided by the compiler |
| `check_ci_opam_deps_controls.py` | Controls for the CI dependency link, including what it is allowed to read |
| `check_compiler_sync_rules.py` | declared compiler counterpart changes stay synchronized |
| `check_ddb_command_inventory.py` | DDB dispatch, help, documentation, classification, and coverage agree |
| `check_ddb_command_inventory_controls.py` | Positive and build-faithful negative controls for the DDB inventory check |
| `check_ddb_wait_reason_names.py` | DDB's wait view names every process state and wait reason the kernel encodes for the debugger snapshot, spelled from the enum case |
| `check_ddb_wait_reason_names_controls.py` | Controls for the DDB wait-vocabulary check |
| `check_dead_slot_peek_not_retained.py` | the dead-slot-tolerant record peek is read on the spot, never bound |
| `check_diagnostic_event_ids.py` | fixed diagnostic event IDs are unique 16-bit values |
| `check_direct_mmio_literals.py` | MMIO pointers derive from validated resource bases |
| `check_direct_mmio_literals_controls.py` | Positive and negative controls for check_direct_mmio_literals.py |
| `check_documented_counts.py` | a count transcribed into documentation still matches the tree it counts |
| `check_documented_counts_controls.py` | Controls for the documented-count check |
| `check_elf_symbol_alignment_controls.py` | Positive and faithful negative controls for the ELF alignment guard |
| `check_execution_model_coverage.py` | mutable kernel state declares its execution model |
| `check_expected_line_endings.py` | stdout fixtures use one newline convention |
| `check_expected_line_endings_controls.py` | Positive and failure-specific controls for expected-line-ending checks |
| `check_fallback_counters.py` | every dead-slot fallback counter is summed into one positively reported line a view expects, so a fallback that fires loses a line rather than adding one |
| `check_fallback_counters_controls.py` | Controls for the dead-slot fallback report check |
| `check_find_stale_issue_workarounds_controls.py` | Controls for the stale-workaround worklist's matching |
| `check_flag_guarded_fields.py` | optional fields are read only after their presence flags |
| `check_invariant_lines_unviewed.py` | invariant reports are either diagnostic-only or enforced by absence, never asserted as correct |
| `check_irq_restore_sites.py` | no `enable_irq()` restores interrupts without consulting the state it overwrites |
| `check_irq_restore_sites_controls.py` | Controls for the IRQ-restore site check |
| `check_kernel_asm_invariants_controls.py` | Controls for the SCTLR alignment-policy disassembly check |
| `check_kernel_ddb_postmortem_controls.py` | Controls for the UART driver's DDB postmortem walk, with no QEMU in the room |
| `check_kernel_interactive_httpd_protocol.py` | interactive HTTP runners avoid listener/request deadlock |
| `check_kernel_lib_limitations_header.py` | core kernel files state their current limitations |
| `check_kernel_log_expectations.py` | test runners wait only for logs the kernel can emit |
| `check_kernel_memory_map_controls.py` | Positive and faithful negative controls for allocator layout fixtures |
| `check_kernel_views_controls.sh` | Controls for the shared view comparison (GitHub issue #530) |
| `check_liveness_proof_escapes.py` | every place that drops a pool's liveness proof is declared with a reason |
| `check_lock_discipline.py` | global mutexes are not force-reset and raw atomics stay allowlisted |
| `check_measure_kernel_tcp_throughput_controls.py` | Controls for the wire-throughput measurement, with a scripted curl |
| `check_measure_trusted_base_controls.py` | Lexical controls for the trusted-base unsafe-block inventory |
| `check_net_link_wait_controls.py` | Controls for the shared host-side reachability wait |
| `check_no_conflict_markers.py` | no tracked file is left mid-merge, where a pattern-scanning check would answer about the half above the marker |
| `check_no_conflict_markers_controls.py` | Positive and faithful negative controls for the conflict-marker check |
| `check_pass_line_counts.py` | every check reports PASS through `scripts/pass_line.py`, asserting a count that is zero when it examined nothing |
| `check_pass_line_counts_controls.py` | Controls for the PASS-line guard, in both directions |
| `check_pipefail_early_exit.py` | no `pipefail` script pipes a large producer into a consumer that leaves at the first match |
| `check_pipefail_early_exit_controls.py` | Controls for the pipefail/SIGPIPE check, in both directions |
| `check_platform_file_parity.py` | duplicated platform functions do not drift silently, and neither do identical inline runs of eight significant lines |
| `check_platform_file_parity_controls.py` | Controls for the platform-parity check, both halves of it |
| `check_platform_view_parity.py` | a view compared on one lane only says why it is not shared |
| `check_platform_view_parity_controls.py` | Controls for the platform-view parity check |
| `check_pool_release_paths.py` | every kernel pool has a release path or explicit exemption |
| `check_probe_entry_gates.py` | a two-core probe's arrival gate waits on a count that only grows, never on a level the other core clears |
| `check_profile_kernel_samples_controls.py` | Controls for bounded flat-PC sample validation and symbolization |
| `check_profile_kernel_workload_controls.py` | Positive and negative controls for workload-profile host artifacts |
| `check_qemu_lane_ports.py` | QEMU lanes do not claim conflicting protocol ports, and every lane fits the per-session port block |
| `check_raw_pos_fname.py` | source identity uses the canonical path helpers |
| `check_repeat_kernel_lane_controls.sh` | Regression controls for the repeat runner's two modes |
| `check_rpi5_set_kernel_byte_controls.py` | Controls for the live RPi5 kernel-byte writer without using the board |
| `check_run_kernel_shell_console_controls.py` | Regression controls for the interactive console's UART marker detection |
| `check_run_kernel_uart_driver_controls.py` | Regression controls for the UART driver's timeout diagnosis |
| `check_single_dune_invocation.py` | exactly one rule runs `dune build`, so no second make invocation races its lock |
| `check_stale_depfiles.py` | generated kernel depfiles name live prerequisites |
| `check_validate_kernel_dmesg_timestamps_controls.py` | Controls for the dmesg timestamp validator, which had none |

## `slowcheck_*` -- the slow lane

`make slowcheck` runs these without a timeout. Each waits on something real --
a pty, a lease, a lock, a port registry, a subprocess it must let run -- and
that is why it is named this way. The prefix is a confession, made at the
moment of the decision rather than discovered later.

They are deliberately out of the fast gate. A control that drives real time
has no business gating a compile: one of them held CI red for nine
consecutive runs in September 2026, six of those on that single script, and
for several rounds it gated `allbuild` so no kernel lane ran at all.

| Check | Enforced invariant |
| --- | --- |
| `slowcheck_board_link_gate.sh` | Controls for the shared board-link gate |
| `slowcheck_kernel_net_readiness.py` | Controls for the host peer's readiness waits, with no QEMU in the room |
| `slowcheck_qemu_session_ports.sh` | Regression controls for the per-session QEMU port block claim |
| `slowcheck_resource_lease.sh` | Regression controls for cross-container board and aggregate-suite leases |
| `slowcheck_run_kernel_build_locked.sh` | Regression controls for the cross-Make kernel build lock |
| `slowcheck_run_kernel_ddb_rpi5_driver.py` | Controls for the RPi5 DDB driver, over a pty standing in for the board |
| `slowcheck_run_lane.sh` | Controls for the lane timing receipts and the summary built from them |

## `buildcheck_*` -- checks of a build product

Not a lane. Each must be handed a linked ELF or a built kernel, so each runs
from the rule that produces it -- which is also why a clean checkout cannot
run them, and why they sit outside both globs above.

| Check | Enforced invariant |
| --- | --- |
| `buildcheck_elf_symbol_alignment.py` | Reject a linked ELF when a required symbol is under-aligned |
| `buildcheck_kernel_asm_invariants.py` | TODO |
| `buildcheck_kernel_memory_map.py` | Fail the build when kernel/MEMORY_MAP.md and the build disagree |
| `buildcheck_suite_output.py` | Split a batched UART stream and compare each case with its fixture |
| `buildcheck_user_payload_no_rw_globals.py` | TODO |

## Reporting

Every check above prints its verdict through `scripts/pass_line.py`, which
refuses to print PASS when a count the verdict rests on is zero. A new check
reports the same way: pick the number that is zero when the check did no work
-- usually the size of the set it scanned, not the number of findings it made
-- and pass it to `report_pass`. A nonzero count proves the check looked at
something; it does not prove the set was complete, and where completeness is
the property at risk the count is compared against a separately discovered
total instead.

The scripts themselves are authoritative for exact mechanics. This table is
maintained by hand and generated from nothing, which is why
`check_agents_paths.py` refuses a check that is missing from it: a complete
inventory that nothing enforces is the one that goes stale first.
