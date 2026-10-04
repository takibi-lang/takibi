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
| `check_affinity_probe_migrates.py` | the syscall /bin/affinity uses to make the migration gate fire is the one the gdb watcher waits for, and is still on the refusal list (`syscall_peer_refused`) |
| `check_affinity_probe_migrates_controls.py` | Controls for the affinity-probe premise check |
| `check_agents_paths.py` | paths named by root guidance resolve and this table names every check |
| `check_ash_bin_inventory.py` | ash's expected /bin listing matches every image-recipe entry in order |
| `check_ash_bin_inventory_controls.py` | Controls for additions, omissions, and unrecognized /bin image commands |
| `check_found_by_policy_controls.py` | Controls for the `Found-by:` and `Protocol:` trailers an issue-closing commit must carry |
| `check_archive_kernel_failure_controls.sh` | Regression controls for the failing-lane archive |
| `check_ci_opam_deps.py` | every library the dune files name is provided by a package in dune-project's depends stanza or by the compiler |
| `check_ci_opam_deps_controls.py` | Controls for the Dune project dependency link, including what it is allowed to read |
| `check_compiler_sync_rules.py` | declared compiler counterpart changes stay synchronized |
| `check_await_summary_controls.py` | Aggregate await capture isolation, phase budgets, half-budget boundaries, missing observations and summary wiring |
| `check_rpi5_ddb_await_controls.py` | RPi5 DDB first-arrival observations, original session budget, missing milestones and error-path capture |
| `check_uart_await_timing_controls.py` | Common UART connection budget, capture ceiling, progress-renewed arrivals and unfinished markers remain distinct |
| `check_ddb_await_timing_controls.py` | QEMU DDB normal/postmortem await observations retain separate deadlines and preserve split prompts, failures and margin reporting |
| `check_ddb_command_inventory.py` | DDB dispatch, help, documentation, classification, and coverage agree |
| `check_ddb_command_inventory_controls.py` | Positive and build-faithful negative controls for the DDB inventory check |
| `check_ddb_qemu_capture_controls.py` | Retained UART/software BREAK captures exercise the shared live/offline predicates; missing evidence, wrong values and ordering violations fail with individual diagnoses |
| `check_ddb_rpi5_capture_controls.py` | Live and offline DDB verdicts accept LF/CRLF and refuse missing console-hold/release evidence, unheld mutex/phase, echoed commands, and invalid peer-stop evidence |
| `check_ddb_signal_names.py` | DDB's process view names every signal kill(2) accepts, spelled from the ABI constant, and subtracts the named bits from its hex remainder; both QEMU runner gates accept the rendered sets |
| `check_ddb_signal_names_controls.py` | Controls for the DDB signal-vocabulary check |
| `check_ddb_wait_reason_names.py` | DDB's wait view names every process state and wait reason the kernel encodes for the debugger snapshot, spelled from the enum case |
| `check_ddb_wait_reason_names_controls.py` | Controls for the DDB wait-vocabulary check |
| `check_dead_slot_peek_not_retained.py` | the dead-slot-tolerant record peek is read on the spot, never bound |
| `check_diagnostic_event_ids.py` | fixed diagnostic event IDs are unique 16-bit values |
| `check_direct_mmio_literals.py` | MMIO pointers derive from validated resource bases |
| `check_direct_mmio_literals_controls.py` | Positive and negative controls for check_direct_mmio_literals.py |
| `check_documented_counts.py` | a count transcribed into documentation still matches the tree it counts |
| `check_documented_counts_controls.py` | Controls for the documented-count check |
| `check_elf_symbol_alignment_controls.py` | Positive and faithful negative controls for the ELF alignment guard |
| `check_el0_raw_deref_audit.py` | Every Takibi object linked into an EL0 PIE uses the shared audit recipe and rebuilds when the budget or checker changes |
| `check_el0_raw_deref_audit_controls.py` | A bypassed recipe, missing audit/gate/depfile/rebuild dependency, and empty EL0 coverage are refused |
| `check_execution_model_coverage.py` | mutable kernel state declares its execution model |
| `check_ext2_image_free_blocks.py` | the fixture ext2 image keeps at least 128 free blocks, so a program added to it cannot silently push a boot into the exhaustion stall of #658 |
| `check_ext2_mutation_guard.py` | every ext2 mutation is reached under the filesystem lock's guard, or its file is named with the reason it cannot race a peer |
| `check_model_function_map.py` | every kernel function a TLA+ model under kernel/models/ claims to abstract still has a definition, every path a model drops says why that is safe, and no mapped function changed since its row was reviewed |
| `check_expected_line_endings.py` | stdout fixtures use one newline convention |
| `check_expected_line_endings_controls.py` | Positive and failure-specific controls for expected-line-ending checks |
| `check_fallback_counters.py` | every dead-slot fallback counter is summed into one positively reported line a view expects, so a fallback that fires loses a line rather than adding one |
| `check_fallback_counters_controls.py` | Controls for the dead-slot fallback report check |
| `check_fd_clone_transaction.py` | the linear fd-clone transaction begins empty, advances exactly through a successful install, preserves failures, and rolls back its recorded prefix |
| `check_fd_clone_transaction_controls.py` | Negative controls for the fd-clone transaction implementation boundary |
| `check_find_stale_issue_workarounds_controls.py` | Controls for the stale-workaround worklist's matching |
| `check_flag_guarded_fields.py` | optional fields are read only after their presence flags |
| `check_gdb_bounded.py` | every gdb a lane runner starts runs under `timeout`, so a `continue` that never stops cannot hold an aggregate |
| `check_gdb_bounded_controls.py` | Controls for the bounded-gdb check, in both directions |
| `check_gdb_no_guest_memory_read.py` | a gdb check script decides from registers, not guest memory read through whatever translation the stopped CPU has active (#585) |
| `check_gdb_no_guest_memory_read_controls.py` | Controls for the gdb guest-memory-read check, in both directions |
| `check_invariant_lines_unviewed.py` | invariant reports are either diagnostic-only or enforced by absence, never asserted as correct |
| `check_gic_iar_intid.py` | the platform interrupt dispatchers decide on `GICC_IAR & 0x3FF` and hand only the raw word back to GICC_EOIR, so an SGI's sender bits cannot hide it (#632) |
| `check_stack_proof_states.py` | a process start takes only a `Startable` token and a reap only a `Reapable` one, only the named mint functions build them, and each reads `stack_owner_cpu` (StackOwnership.tla's StartsOnFreeStack) |
| `check_stack_proof_states_controls.py` | Negative controls for the stack-free proof: a start taking Ready, a reap taking Exited, a token minted elsewhere or written as a literal, and a mint that stopped reading the owner are refused |
| `check_world_stop_refusals.py` | no `WorldStopResult::Busy` or `Partial` arm fail-stops the kernel; a refused world stop is waited out or handed back (#632) |
| `check_irq_restore_sites.py` | no `enable_irq()` restores interrupts without consulting the state it overwrites |
| `check_irq_restore_sites_controls.py` | Controls for the IRQ-restore site check |
| `check_kernel_asm_entries.py` | the Makefile declares exactly the Takibi functions kernel assembly calls by name as entry points |
| `check_kernel_asm_invariants_controls.py` | Controls for the SCTLR alignment-policy disassembly check |
| `check_kernel_elf_freshness_controls.sh` | Controls for the stale-kernel guard: a lane refuses to run against a kernel older than its own sources |
| `check_kernel_ddb_postmortem_controls.py` | Controls for the UART driver's DDB postmortem walk, with no QEMU in the room |
| `check_console_progress_controls.py` | PTY and STARVED driver flows renew on UART; PTY startup and exit observations preserve separate budgets, missing arrivals and cleanup verdicts |
| `check_rpi5_shell_smoke_controls.py` | Interactive RPi5 shell smoke checks two HTTP responses and fresh HTTPd process snapshots; absent readiness, echoed markers, extra workers and bad responses fail |
| `check_kernel_net_wait_controls.py` | UART progress renews readiness waits; silence and the outer ceiling still fail, with bounded DDB protection |
| `check_kernel_interactive_httpd_protocol.py` | interactive HTTP runners avoid listener/request deadlock |
| `check_kernel_lib_limitations_header.py` | core kernel files state their current limitations |
| `check_kernel_log_expectations.py` | test runners wait only for logs the kernel can emit |
| `check_kernel_memory_map_controls.py` | Linked-image growth, exact QEMU boot views, invalid rendering inputs, and allocator layout controls |
| `check_kernel_views_controls.sh` | Controls for the shared view comparison (GitHub issue #530) |
| `check_oops_await_timing_controls.py` | Deterministic crash-console arrival, common-deadline and half-budget controls, including partial markers, failures and unavailable artifacts |
| `check_known_intermittent_issues_controls.py` | Controls for the known-intermittent open-issue gate, with the GitHub answer injected rather than fetched |
| `check_known_intermittents.py` | every row of the known-intermittent table names one issue and a symptom the tree still produces, and the roadmap points at the table rather than carrying the list |
| `check_known_intermittents_controls.py` | Controls for the known-intermittent table's rules, in both directions |
| `check_lane_artifact_root.py` | every kernel lane hangs its capture off one artifact root, so a repeated lane keeps each sample's evidence instead of overwriting it |
| `check_lane_artifact_root_controls.py` | Controls for the lane artifact-root check, in both directions |
| `check_legacy_dma_rx_scope.py` | legacy receive cache calls in maintained code remain only the audited GEM data-buffer calls |
| `check_legacy_dma_rx_scope_controls.py` | Controls for new, changed, and removed legacy RX calls |
| `check_liveness_proof_escapes.py` | every place that drops a pool's liveness proof is declared with a reason |
| `check_process_running_mints.py` | every caller of `process_running_here`, the mint of a process's evidence that it is running, is declared (#693) |
| `check_address_space_root_mints.py` | every maker of an `AddressSpaceRoot` (which carries its backing handle) is declared (#693) |
| `check_process_record_bare_uses.py` | the bare `scheduled_process_record_at`/`_of` calls left in `process.tkb` equal a budget that only goes down (#693) |
| `check_lock_discipline.py` | global mutexes are not force-reset and raw atomics stay allowlisted |
| `check_measure_kernel_tcp_throughput_controls.py` | Controls for the wire-throughput measurement, with a scripted curl |
| `check_measure_trusted_base_controls.py` | Lexical controls for the trusted-base unsafe-block inventory, and for the raw-pointer dereference ratchet: a file with no row, over, under, gone or zero is refused, another target's files are not checked, and `--lower` lowers, never raises and drops a zero row; a zero-site compiled source passes but an empty depfile is refused |
| `check_net_link_wait_controls.py` | Controls for the shared host-side reachability wait |
| `check_no_conflict_markers.py` | no tracked file is left mid-merge, where a pattern-scanning check would answer about the half above the marker |
| `check_no_conflict_markers_controls.py` | Positive and faithful negative controls for the conflict-marker check |
| `check_race_window_overlay_only.py` | a widened race window's spin exists only in its overlay, never in kernel/, so no ordinary kernel carries it (#615) |
| `check_race_window_overlay_only_controls.py` | Controls for the race-window overlay check, in both directions |
| `check_no_cursor_reply.py` | no host driver answers BusyBox's cursor query, whose late reply lands in the next command (#644) |
| `check_no_cursor_reply_controls.py` | Controls for the cursor-reply check, in both directions |
| `check_pass_line_counts.py` | every check reports PASS through `scripts/pass_line.py`, asserting a count that is zero when it examined nothing |
| `check_pass_line_counts_controls.py` | Controls for the PASS-line guard, in both directions |
| `check_patch_embedded_image_controls.py` | Controls for the exact embedded-rootfs replacement used by the interactive RPi5 image |
| `check_pipefail_early_exit.py` | no `pipefail` script pipes a large producer into a consumer that leaves at the first match |
| `check_pipefail_early_exit_controls.py` | Controls for the pipefail/SIGPIPE check, in both directions |
| `check_platform_file_parity.py` | duplicated platform functions do not drift silently, and neither do identical inline runs of eight significant lines |
| `check_platform_file_parity_controls.py` | Controls for the platform-parity check, both halves of it |
| `check_platform_view_parity.py` | a view compared on one lane only says why it is not shared |
| `check_platform_view_parity_controls.py` | Controls for the platform-view parity check |
| `check_peer_filesystem_controls.py` | the peer filesystem verdict requires CPU-1 reads, failed first lock attempts on both CPUs, and capture completion on both platforms; controls remove each link |
| `check_peer_console_process_controls.py` | the peer-console verdict requires real EL0 writes, CPU migration, alternating parent/child order, actual short counts, all 1071 bytes, bounded DDB hold and release publication before IRQ restore |
| `check_pool_release_paths.py` | every kernel pool has a release path or explicit exemption |
| `check_pool_zero_before_stamp.py` | a pool slot's storage is cleared before the generation that makes it answer Live is stamped, so a lockless walker cannot read the free-chain link as a payload (#514) |
| `check_pool_zero_before_stamp_controls.py` | Controls for the pool clear-before-stamp check, in both directions |
| `check_probe_entry_gates.py` | a two-core probe's arrival gate waits on a count that only grows, never on a level the other core clears |
| `check_profile_kernel_samples_controls.py` | Controls for bounded flat-PC sample validation and symbolization |
| `check_profile_kernel_workload_controls.py` | Positive and negative controls for workload-profile host artifacts |
| `check_qemu_lane_ports.py` | QEMU lanes do not claim conflicting protocol ports, and every lane fits the per-session port block |
| `check_raw_pos_fname.py` | source identity uses the canonical path helpers |
| `check_repeat_kernel_lane_controls.sh` | Regression controls for the repeat runner's two modes |
| `check_roadmap_size.py` | ROADMAP.md stays the current work split rather than regrowing into a knowledge base |
| `check_rpi5_set_kernel_byte_controls.py` | Controls for the live RPi5 kernel-byte writer without using the board |
| `check_run_kernel_shell_console_controls.py` | Regression controls for the interactive console's UART marker detection |
| `check_run_kernel_uart_driver_controls.py` | Regression controls for UART timeout diagnosis and exact ash echo normalization |
| `check_slot_proof_dropped_to_index.py` | a slot liveness proof dropped to a bare index is declared with a reason, so #569's shape is a decision rather than a line |
| `check_slot_proof_dropped_to_index_controls.py` | Controls for the slot-proof-to-index check, in both directions |
| `check_single_dune_invocation.py` | exactly one rule runs `dune build`, so no second make invocation races its lock |
| `check_validate_kernel_dmesg_timestamps_controls.py` | Controls for dmesg integrity, measurement-only QEMU boot duration, and separately enforced performance bounds |
| `check_validate_protocol_trace_controls.py` | Controls for the protocol-trace replay: three recorded QEMU windows pass (one with `Nap` in `SwitchAway`'s place), two of them fail without `ChildExitStart` and `InterruptDepart`; a tick leave outside an interrupt, #609's shared-stack start, a lost change, a cut report, an unlocked change, an unsafe snapshot and an unexercised window are refused, and so are Wait4Block.tla's block with a zombie child, lost wakeup and wake of a non-parent, RecordLifetime.tla's unlocked or premature removal, and a wait published on a Running process |
| `check_wont_compile_catalog.py` | every defect-catalog entry names a test case that exists, shows its figure, and agrees with the index |
| `check_wont_compile_catalog_controls.py` | Controls for the defect catalog's structure check and for the sample runner's verdicts |

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
| `slowcheck_known_intermittent_issues.py` | every row of the known-intermittent table names an issue that is still open |
| `slowcheck_board_link_gate.sh` | Controls for the shared board-link gate |
| `slowcheck_kernel_net_readiness.py` | Controls for the host peer's readiness waits, with no QEMU in the room |
| `slowcheck_qemu_session_ports.sh` | Regression controls for the per-session QEMU port block claim |
| `slowcheck_resource_lease.sh` | Regression controls for cross-container board and aggregate-suite leases |
| `slowcheck_run_kernel_build_locked.sh` | Regression controls for the cross-Make kernel build lock |
| `slowcheck_run_kernel_ddb_rpi5_driver.py` | PTY controls for console-hold and release evidence, a newline wake before BREAK on CPU 0, and the RPi5 DDB driver's resume retry |
| `slowcheck_run_lane.sh` | Controls for the lane timing receipts and the summary built from them |
| `slowcheck_run_tlc.py` | Parallel TLC jobs use private standard-module files, preserve JVM exit statuses, and clean temporary directories on success and failure |

## `buildcheck_*` -- checks of a build product

Not a lane. Each must be handed a linked ELF or a built kernel, so each runs
from the rule that produces it -- which is also why a clean checkout cannot
run them, and why they sit outside both globs above.

| Check | Enforced invariant |
| --- | --- |
| `buildcheck_elf_symbol_alignment.py` | Reject a linked ELF when a required symbol is under-aligned |
| `buildcheck_kernel_asm_invariants.py` | TODO |
| `buildcheck_kernel_memory_map.py` | Check kernel/MEMORY_MAP.md and allocator fixtures; render QEMU boot capacity from the loaded ELF |
| `buildcheck_kernel_unused_coverage.py` | every kernel file a target compiles is checked for unused functions or exempt for a stated reason |
| `measure_trusted_base.py --check-raw-deref` | the raw-pointer dereference ratchet (#639): run by each kernel object's rule on the compiler's `--emit-raw-deref-audit`, including standalone EL0 payload objects, it holds every file's dereference count to `raw_deref_budget.tsv`, so the count can only go down on purpose. Also the trusted-boundary inventory of `make trustedbasecheck` |
| `buildcheck_suite_output.py` | Split a batched UART stream and compare each case with its fixture |
| `buildcheck_user_payload_no_rw_globals.py` | TODO |
| `buildcheck_wont_compile_samples.py` | every program the defect catalog prints is rejected with the diagnostic beside it, or accepted, by the built compiler |

## Reporting

`make linuxcheck` also runs `scripts/fuzz_compiler.py` through
`make compiler-fuzz`, so both aggregate gates execute generated native
programs and a seeded interval-rule defect control. This is an execution
test, outside the file-reading check globs. See
[`COMPILER_FUZZING.md`](COMPILER_FUZZING.md) for its bounds and artifacts.

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
