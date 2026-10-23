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
| `check_space_checkpoint_controls.py` | milestone measurement, justified incremental reuse, source fingerprint freshness, tracked evidence, and the mandatory pre-allcheck publication hook |
| `check_wait_interrupt_sites.py` | every `return` of `SyscallAction::WaitInterrupt` (or `InterruptWait`) in `kernel/kernel/syscall.tkb` is counted per function against a reviewed allowlist with reasons; an event wait must Block on its wake source instead of keeping the process Running (#866) |
| `check_wait_status_sites.py` | every `process_end_exited` argument in a kernel `.tkb` is a reviewed form (exit/exit_group's code, a probe's stamped codes) -- the `ProcessEnd` variant (#886) already keeps an exit code and a signal apart, but not an integer that mixes them going in -- and no kernel `.tkb` outside `kernel/kernel/wait_status.tkb` adds 128 to a signal or status in code: wait4 reports Linux's WTERMSIG form, not a shell's `$?` (#882) |
| `check_qemu_vcpu_lease.py` | every maintained QEMU guest starts through `scripts/qemu.sh`, never `qemu-system-aarch64` directly, and every file that starts the shim takes a vCPU lease from the host-wide budget |
| `check_lease_before_deadline.py` | a driver that spawns a lease-taking QEMU runner (a script calling `resource_lease_vcpu_acquire`, or `make kernelsh-qemu`) takes the vCPU lease itself first, so no deadline is spent in the runner's wait (#719) |
| `check_execution_model_coverage_controls.py` | a comment-only (line or block comment) mention of an execution-model constant and an empty EXEMPT reason are refused; a code `static_assert` and a reasoned EXEMPT entry are accepted |
| `check_lease_wait_controls.py` | `lease_wait.lease_pending` classifies waiting, allocator waits, waits after a grant and transcripts without a wait, and only a pending wait is named in a timeout |
| `check_service_space_controls.py` | actual FD/fork phase and actor coverage, open-description sharing, retained capacities, Takibi pool resource identities, repeats, and incomplete/error capture rejection |
| `check_pool_retention_controls.py` | real-kernel retention accounting, workload completion, repeated counts, platform clock separation, and malformed capture rejection |
| `check_pool_replay_controls.py` | equal-workload Takibi/SLUB/UMA sample coverage, storage arithmetic, recorded comparison freshness, and failed or incomplete capture controls |
| `check_pool_space_controls.py` | pool-space capture framing, complete production-pool coverage, allocation accounting, and malformed numeric samples |
| `check_affinity_probe_migrates.py` | the syscall /bin/affinity uses to make the migration gate fire is the one the gdb watcher waits for, and is still on the refusal list (`syscall_peer_refused`) |
| `check_affinity_probe_migrates_controls.py` | Controls for the affinity-probe premise check, including an svc5 call present only in a comment (#815) |
| `check_boot_log_snapshot.py` | the boot dmesg snapshot precedes the variable-length protocol report |
| `check_boot_log_snapshot_controls.py` | Controls reject old snapshot ordering and missing, duplicate or commented commands |
| `check_agents_paths.py` | paths named by root guidance resolve to Git-tracked files and this table names every check |
| `check_agents_paths_controls.py` | an untracked directory or an empty glob does not satisfy a path root guidance names |
| `check_ash_bin_inventory.py` | ash's expected /bin listing matches every image-recipe entry in order |
| `check_ash_bin_inventory_controls.py` | Controls for additions, omissions, and unrecognized /bin image commands |
| `check_assume_init_sites.py` | every function in maintained kernel/ and linux_user/ Takibi code that calls `assume_init` (comments blanked) is listed in TRUSTED_BASE.md as `path:function`, and every listed site still calls it (#764) |
| `check_kernel_compile_flags.py` | every Makefile kernel compile recipe takes `$(KERNEL_QEMU_COMPILE_FLAGS)` or `$(KERNEL_RPI5_COMPILE_FLAGS)` (directly or through a `KERNEL_*_FLAGS` variable) without respelling a shared flag, and every script run with `$(KERNELBUILD_CHECK_ARGS)` takes its flags from `scripts/kernel_compile_flags.py`; the EL0 payload define is the one exemption (#781) |
| `check_kernel_compile_flags_controls.py` | a bypassing recipe, a `kernel/*.tkb` path compile, a respelled flag, a respelling flags variable, an unlisted define and a script spelling its own flags are refused; the EL0 define, a prerequisite line and the real tree are accepted |
| `check_assume_init_sites_controls.py` | an unlisted `assume_init` site and a stale TRUSTED_BASE.md listing are refused; a comment-only mention is ignored; the listed real sites are accepted |
| `check_dma_qemu_transcript_controls.py` | The DMA QEMU runner waits for the complete diagnostic under every serial byte split; partial success/failure markers never terminate capture |
| `check_found_by_policy_controls.py` | Controls for the `Found-by:` and `Protocol:` trailers an issue-closing commit must carry |
| `check_capture_kernel_console_controls.py` | A GDB error with exit zero, nonzero exit, timeout and absent sidecars remain unavailable; success needs reader completion and every attempt restores the prior run state |
| `check_churn_gdb_controls.py` | Bounded churn GDB failures restore the prior guest state; the dump precedes DDB and diagnostic failure preserves the stall verdict |
| `check_archive_kernel_failure_controls.sh` | Regression controls for the failing-lane archive |
| `check_ci_opam_deps.py` | every library the dune files name is provided by a package in dune-project's depends stanza or by the compiler |
| `check_ci_opam_deps_controls.py` | Controls for the Dune project dependency link, including what it is allowed to read |
| `check_compiler_sync_rules.py` | declared compiler counterpart changes stay synchronized |
| `check_refined_range_constructor.py` | range-propagation and cast rules in type_inf.ml/llvm_gen.ml build a refined result only through the base-checked refined_or_base (#935) |
| `check_refined_range_constructor_controls.py` | Controls for the refined-range constructor check: issue #935's raw Sub constructor is refused |
| `check_await_summary_controls.py` | Aggregate await capture isolation, phase budgets, half-budget boundaries, missing observations and summary wiring |
| `check_rpi5_ddb_await_controls.py` | RPi5 DDB first-arrival observations; software BRK boot and post-snapshot budgets, delayed release, echoed-only output, missing milestones and unavailable UART |
| `check_fixed_wait_await_controls.py` | The FDT multi-bank boots and the stack-overflow runner (through `await_timing.py`'s command line) record arrival against their fixed budgets, print the margin past half without changing the verdict, and record a missing line as not arrived |
| `check_dma_mint_files.py` | Every `dma_fixed` record is declared in a listed mint file, and only the listed functions there call `dma_finish_owned_rx`/`_tx`; a record in a driver file, an unlisted finisher and a stale entry are each refused (#716, #717) |
| `check_slot_pool_entries.py` | For each slot pool (ext2's `Ext2Slot`, the block layer's `BlockSlot`, the exec loader's `ProcessImageSlot`, the syscall scratch's `SyscallSlot`), one operation holds one slot: an entry point that acquires is never called from inside the pool's file (for `SyscallSlot`, never reached from a slot holder) and is never handed a slot. No slot holder of any pool reaches a scheduler sleep (`kernel_process_block_*`) and no function but the acquire returns a slot; block_cache.tkb's slot-indexed functions are called from memory.tkb only (#638) |
| `check_cpu_authority_mints.py` | `cpu_here_for_boot_probe`, the CPU-authority mint that names any CPU, is called only by its reviewed boot probe (#704) |
| `check_uart_await_timing_controls.py` | Common UART connection budget, capture ceiling, progress-renewed arrivals and unfinished markers remain distinct |
| `check_ddb_await_timing_controls.py` | QEMU DDB normal/postmortem await observations retain separate deadlines and preserve split prompts, failures and margin reporting |
| `check_ddb_command_inventory.py` | DDB dispatch, help, documentation, classification, and coverage agree |
| `check_ddb_command_inventory_controls.py` | Positive and build-faithful negative controls for the DDB inventory check |
| `check_ddb_rpi5_capture_controls.py` | Live and offline DDB verdicts accept LF/CRLF and refuse missing console-hold/release evidence, unheld mutex/phase, echoed commands, and invalid peer-stop evidence |
| `check_gdb_progress_verdict_controls.py` | affinity-gdb, peer-exit and exec-enomem read a stalled guest (gdb_progress STALLED) as inconclusive at every stage and only a quiet one as a finding; each tick read restores the caller's QEMU PhyMemMode (#878) |
| `check_ddb_signal_names.py` | DDB's process view names every signal kill(2) accepts, spelled from the ABI constant, and subtracts the named bits from its hex remainder; both QEMU runner gates accept the rendered sets |
| `check_ddb_wait_reason_names.py` | DDB's wait view names every process state and wait reason the kernel encodes for the debugger snapshot, spelled from the enum case |
| `check_ddb_wait_reason_names_controls.py` | Controls for the DDB wait-vocabulary check |
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
| `check_ext2_fixed_times.py` | self-test of `ext2_fixed_times.py`, the last step of each fixture image build, which pins every allocated inode's times: images stamped at different clocks converge, reserved and free inodes are kept, and a different epoch (the control) gives different bytes (#890) |
| `check_ext2_mutation_guard.py` | every ext2 mutation is reached under the filesystem lock's guard, or its file is named with the reason it cannot race a peer |
| `check_model_function_map_controls.py` | Function extraction preserves qualifiers, effects, nested blocks and first-definition semantics while total full-source scan work stays constant across distinct and repeated lookups |
| `check_model_coverage_controls.py` | `scripts/model_coverage.py`, which `make modelcheck` runs on every fully explored TLC log, refuses an action never taken, an allow-list entry without a reason, a stale or unjudged entry, a log without coverage, and judges only the last coverage report (#802) |
| `check_model_function_map.py` | every kernel function a TLA+ model under kernel/models/ claims to abstract still has a definition, every path a model drops says why that is safe, and no mapped function changed since its row was reviewed |
| `check_expected_line_endings.py` | stdout fixtures use one newline convention |
| `check_expected_line_endings_controls.py` | Positive and failure-specific controls for expected-line-ending checks |
| `check_fallback_counters.py` | every dead-slot fallback counter is summed into one positively reported line a view expects, so a fallback that fires loses a line rather than adding one |
| `check_fd_clone_transaction.py` | the linear fd-clone transaction begins empty, advances exactly through a successful install, preserves failures, and rolls back its recorded prefix |
| `check_fd_clone_transaction_controls.py` | Negative controls for the fd-clone transaction implementation boundary, including the success fragment present only in a comment (#815) |
| `check_find_stale_issue_workarounds_controls.py` | Controls for the stale-workaround worklist's matching |
| `check_flag_guarded_fields.py` | optional fields are read only after their presence flags |
| `check_gdb_bounded.py` | every gdb a lane runner starts runs under `timeout`, so a `continue` that never stops cannot hold an aggregate |
| `check_gdb_bounded_controls.py` | Controls for the bounded-gdb check, in both directions |
| `check_secondary_tick_count_layout.py` | `secondary_tick_count` is one 8-byte AtomicWord per core, the layout the gdb tick read (`scripts/gdb_tick_count.py`) steps through (#865, #867) |
| `check_secondary_tick_count_layout_controls.py` | Controls for the secondary_tick_count layout check, in both directions |
| `check_gdb_wallclock_continue.py` | a gdb Python check resumes the guest under a host-time interrupt only in a slice primitive its callers bound by guest progress (`scripts/gdb_progress.py`), or a `gdb-wallclock-waiver:` comment says why not (#865) |
| `check_gdb_wallclock_continue_controls.py` | Controls for the gdb wall-clock continue check, in both directions |
| `check_qmp_reply_reads.py` | a QMP client in scripts/ reads no command reply raw after the capability negotiation: replies go through `scripts/qmp_wire.py` qmp_reply, which skips async events (#879, #880) |
| `check_gdb_scheduler_locking.py` | a gdb stage that turns scheduler-locking on first parks the vCPUs it leaves frozen (`takibi-park-threads`), or a `scheduler-locking-waiver:` comment says why not (#795) |
| `check_gdb_scheduler_locking_controls.py` | Controls for the scheduler-locking park check, in both directions |
| `check_gdb_no_guest_memory_read.py` | a gdb check script decides from registers, not guest memory read through whatever translation the stopped CPU has active (#585) |
| `check_gdb_no_guest_memory_read_controls.py` | Controls for the gdb guest-memory-read check, in both directions |
| `check_invariant_lines_unviewed.py` | invariant reports are either diagnostic-only or enforced by absence, never asserted as correct |
| `check_gic_iar_intid.py` | the platform interrupt dispatchers decide on `GICC_IAR & 0x3FF` and hand only the raw word back to GICC_EOIR, so an SGI's sender bits cannot hide it (#632); a mask present only in a comment is refused (#815) |
| `check_stack_proof_states.py` | a process start takes only `Startable` and a reap only `Reapable`, named token mints read `stack_owner_cpu`; frame mint callers and bare-address seams are declared, and direct default `FrameRef` declarations are refused (not arbitrary aggregate initialization) |
| `check_stack_proof_states_controls.py` | Negative controls for weakened stack tokens/mints, undeclared frame mints/address seams, and direct default frame declarations; comments and strings remain permitted |
| `check_stopped_pool_inspection.py` | the finite RegionPool diagnostic mint set borrows full-stop authority, retains IRQ exclusion, and has complete resume/start invalidation annotations |
| `check_stopped_pool_inspection_controls.py` | missing context markers, weakened mint contracts and an unreviewed inspection mint are refused |
| `check_world_stop_refusals.py` | no `WorldStopResult::Busy` or `Partial` arm fail-stops the kernel; a refused world stop is waited out or handed back (#632) |
| `check_core_role_sites.py` | every literal fixed-core comparison in kernel `.tkb` carries a `core-role:` reason (#775) |
| `check_irq_restore_sites.py` | no `enable_irq()` restores interrupts without consulting the state it overwrites |
| `check_kernel_asm_entries.py` | the Makefile declares exactly the Takibi functions kernel assembly calls by name as entry points |
| `check_kernel_asm_invariants_controls.py` | Controls for the SCTLR alignment-policy disassembly check |
| `check_kernel_same_operand_csel_controls.py` | Controls for the same-operand csel ceiling: the #893 `mov`+`csel` and a direct same-register `csel` are counted, distinct sources and a `mov` in another function are not, and one planted above the ceiling is refused |
| `check_kernel_elf_freshness_controls.sh` | Controls for the stale-kernel guard: a lane refuses to run against a kernel older than its own sources |
| `check_kernel_ddb_postmortem_controls.py` | Controls for the UART driver's DDB postmortem walk, with no QEMU in the room |
| `check_console_progress_controls.py` | PTY and GDB boot waits renew on UART; fixed protocol waits, injected verdicts, marker ordering and ceilings stay bounded; churn wait observations preserve half-budget flags, EOF, errors and failure priority; the PTY httpd reap count reads only echo output markers, never a workload-split command echo (#856) |
| `check_typed_markers.py` | no console driver types `echo WORD` with WORD unquoted: an awaited output marker is typed through `scripts/typed_marker.py` so a workload-split echo of the command can never be the marker line (#856, #857) |
| `check_typed_markers_controls.py` | the old #856/#857 driver spellings, names, byte-at-a-time loops and unseen words are refused; quoted, redirected and bare echoes and str file writes pass |
| `check_gem_tx_fixture_controls.py` | Physical GEM ownership and IRQ evidence refuses stale verdicts, missing or corrupt frames, incorrect authorities, incomplete timestamps and missing or wrong-bank IRQ witnesses |
| `check_rpi5_postmortem_controls.py` | The GEM fixture runner and the shell smoke take #869's SWD snapshot before one BREAK and the full DDB walk after a post-load failure (#872), and nothing before the load |
| `check_rpi5_shell_smoke_controls.py` | Interactive RPi5 shell smoke checks two HTTP responses, fresh HTTPd process snapshots and optional bulk measurement completion; absent readiness, echoed markers, extra workers and bad responses fail |
| `check_kernel_http_peer_controls.py` | Delayed replies from earlier HTTP phases cannot answer a new handshake; malformed current replies still fail |
| `check_kernel_net_wait_controls.py` | UART progress renews readiness waits; silence and the outer ceiling still fail, with bounded DDB protection |
| `check_kernel_interactive_httpd_protocol.py` | interactive HTTP runners avoid listener/request deadlock; every required step is read with its file's comments blanked (#818) |
| `check_kernel_interactive_httpd_protocol_controls.py` | a protocol step kept only in a shell, Python, inittab or .tkb comment is refused, and a forbidden name in a comment is not (#818) |
| `check_kernel_lib_limitations_header.py` | core kernel files state their current limitations |
| `check_kernel_log_expectations.py` | test runners wait only for logs the kernel can emit; a `b"` byte string is read only at a token boundary (#817) |
| `check_kernel_log_expectations_controls.py` | a `b"` inside a word (a plain string's closing quote) is not read as an expectation; real byte strings after a space, comma or paren are (#817) |
| `check_kernel_memory_map_controls.py` | Linked-image growth, exact QEMU boot views, invalid rendering inputs, and allocator layout controls |
| `check_kernel_views_controls.sh` | Controls for the shared view comparison (GitHub issue #530) |
| `check_kernel_view_filters.sh` | every line of each kernel view `.expected` (common, platform, and the `qemu-debug` overlay) is selected by the `.filter` its lane resolves, using the lanes' own `kernel_views_select`; an `.expected` no lane compares is refused (#834) |
| `check_kernel_view_filters_controls.sh` | Controls for the view filter/expected check: an unselected line, a platform or overlay expected, an orphan expected and an empty tree fail; a platform filter override passes (#834) |
| `check_oops_await_timing_controls.py` | Deterministic crash-console arrival, common-deadline and half-budget controls, including partial markers, failures and unavailable artifacts |
| `check_known_intermittent_issues_controls.py` | Controls for the known-intermittent open-issue gate, with the GitHub answer injected rather than fetched |
| `check_known_intermittents.py` | every row of the known-intermittent table names one issue and a symptom the tree still produces, and the roadmap points at the table rather than carrying the list |
| `check_known_intermittents_controls.py` | Controls for the known-intermittent table's rules, in both directions |
| `check_lane_artifact_root.py` | every kernel lane hangs its capture off one artifact root, so a repeated lane keeps each sample's evidence instead of overwriting it, and archives a failing capture through `archive_kernel_failure.sh` from an EXIT trap (#877) |
| `check_lane_artifact_root_controls.py` | Controls for the lane artifact-root check, in both directions |
| `check_legacy_dma_rx_scope.py` | no legacy receive cache call remains in maintained code; GEM's buffer became a fixed allocation (#622) |
| `check_legacy_dma_rx_scope_controls.py` | Controls: a planted legacy RX call in any file, GEM included, is refused |
| `check_function_qualifier_controls.py` | Eight source-check function matchers recognize every supported inline/noinline qualifier; the actual liveness gate rejects an undeclared qualified escape by name |
| `check_liveness_proof_escapes.py` | every place that drops a pool's liveness proof is declared with a reason |
| `check_wall_clock_bounds.py` | every kernel wait bounded by host wall-clock time (`read_cntfrq() * N`) is declared in `scripts/wall_clock_bounds.tsv` with a class; `pending` rows, whose QEMU verdict a starved host can flip, are removed one at a time |
| `check_wall_clock_bounds_controls.py` | an undeclared bound, a stale row, a wrong count and an unknown class are each refused |
| `check_page_freelist_rebuild_callers.py` | the page allocator's whole-table free-list rebuild is called only where the runtime tables are installed, never from an allocation or release path (#771) |
| `check_page_freelist_rebuild_callers_controls.py` | a per-run rebuild call is refused; the install-only call and commented calls pass |
| `check_control_replace_once.py` | every negative control patches source text through `control_patch.replace_once`, which refuses an anchor that does not occur exactly once (#845); capture-mutating controls are exempt with a reason |
| `check_process_running_mints_controls.py` | mutation controls reject missing context/phase markers, additional mints, public constructors, and unmarked writers |
| `check_process_running_mints.py` | current-process witness entry and transition mint counts, private constructors, and context/phase writer annotations match the reviewed boundary |
| `check_address_space_root_mints.py` | every maker of an `AddressSpaceRoot` (which carries its backing handle) is declared (#693) |
| `check_process_record_bare_uses.py` | no bare ProcessRecord lookup bodies; reviewed authority mints, private constructors, loan transfers and destructive record contracts |
| `check_process_record_bare_uses_controls.py` | negative controls for changed lookup/mint scopes, constructor visibility and missing destructive annotations |
| `check_lock_discipline.py` | global mutexes are not force-reset and raw atomics stay allowlisted |
| `check_lock_rank_wrappers.py` | every kernel function that calls `region_pool_lock`, `region_pool_lock_saving` or `mutex_acquire` declares `acquires_lock_<rank>_<name>` or has a reviewed exemption (#789: #745 silently dropped the process pool's rank) |
| `check_source_scan_cache.py` | no `functools` cache in scripts/ outside `source_scan.py`, and every check a controls script imports in-process caches its per-file scan with `source_scan.per_file` (unbounded, refuses mutable results) or is reviewed (#808: uncached and size-8-cached scans re-read the tree per control and approached the fast gate's 10 s bound) |
| `check_source_scan_cache_controls.py` | an uncached in-process check, `lru_cache`/`functools.cache` in either spelling, a new uncached in-process check, stale reviewed entries, an evicting cache and a mutable cached result are each refused; a transitive use passes; importing only `code_only` is not cache use, and `code_only` blanks `//` and `/* */` comments in place while keeping string and character literals (#815); `code_skeleton`, `compact`, `py_code_only` and `sh_code_only` behave as specified (#818) |
| `check_comment_strippers.py` | no hand-rolled comment stripper (a literal `//` or `/*` given to split/partition/find/startswith, or a `//[^\n]*`, `//.*` or `/\*` regex) in scripts/ outside `source_scan.py`, except reviewed non-source strippers; records the checks reviewed as raw-text matching by intent (#818) |
| `check_comment_strippers_controls.py` | each pre-#818 stripper shape is refused; a commented shape, a longer comment anchor and `source_scan` itself pass; stale allow-list entries are refused |
| `check_text_search.py` | no `String.sub s i m = x` (or `<>`) at a non-zero offset in lib/ or bin/: a search must use `lib/text_search.ml`, which does not allocate per position (#917) |
| `check_text_search_controls.py` | each pre-#917 search shape is refused; a prefix test at 0, a value use, a comment and `==` pass |
| `check_compile_alloc_budget_controls.py` | the pre-#917 allocation, one word over budget, malformed counts and an unknown target are refused by `buildcheck_compile_alloc_budget.py`; the budget and the measurement pass (#923) |
| `check_fast_gate_no_spawn.py` | no fast-gate Python member spawns a non-git process (subprocess, os.system, os.exec/spawn) unless reviewed with why it stays fast (#808: a member waiting on children overran the 10 s bound under the parallel allcheck; such members are `slowcheck_*`) |
| `check_fast_gate_no_spawn_controls.py` | a Python child, a compiler child, a computed argv, os.system and os.execv are refused; git and a spawn named in a string pass; stale reviewed entries are refused |
| `check_lock_rank_wrappers_controls.py` | the process pool losing its rank, a commented rank, new unranked region, mutex and one-line wrappers, a neighbour's rank, and a stale exemption are each refused |
| `check_guest_syscalls_dispatched.py` | every syscall number an in-tree EL0 guest issues (`svcN(...)` literals and same-file consts and every `const *_SYSCALL` in `kernel/**/*.tkb`, `mov x8, #N` before `svc #0` in `.S`/`.c`, raw-ABI `call(N, ...)` in C) has a `number == N` arm in `kernel_syscall_dispatch_action`, or is on the reviewed `EXPECTED_ENOSYS` list, whose stale entries are refused; an `svc` number it cannot read is refused (#792: #665's probe issued an unimplemented sched_yield on a load-dependent path). Run by `kernel-lib-check` |
| `check_guest_syscalls_dispatched_controls.py` | the sched_yield dispatch arm removed (its peer-safety mention kept), an unused probe constant, literal, hex-const, asm and C-call issues of an undispatched number, an unreadable `svc` number, and stale expected-ENOSYS entries are each refused |
| `check_measure_kernel_tcp_throughput_controls.py` | Controls for the wire-throughput measurement, with a scripted curl |
| `check_profile_kernel_session_controls.py` | Controls for the kernel profile folder (`scripts/profile_kernel_session.py`, #497): dump parsing and refusal, skid weighting, root-first EL1 stacks, EL0 kept apart |
| `check_measure_kernel_fileio_controls.py` | Controls for the file-I/O workload timer (`scripts/measure_kernel_fileio.py`, #765): `real` lines parsed or refused, summary spread, comparison deltas |
| `check_kernel_shell_tcp_controls.py` | Controls for checksum-verified bulk HTTP measurements and retained failure artifacts |
| `check_measure_trusted_base_controls.py` | Lexical controls for the trusted-base unsafe-block inventory, and for the raw-pointer dereference ratchet: a file with no row, over, under, gone or zero is refused, another target's files are not checked, and `--lower` lowers, never raises and drops a zero row; a zero-site compiled source passes but an empty depfile is refused |
| `check_net_link_wait_controls.py` | Controls for the shared host-side reachability wait |
| `check_no_conflict_markers.py` | no tracked file is left mid-merge, where a pattern-scanning check would answer about the half above the marker |
| `check_no_conflict_markers_controls.py` | Positive and faithful negative controls for the conflict-marker check |
| `check_probe_tick_windows.py` | Direct wall-clock waits in boot contention/occupancy probes and FD refcount helpers are refused except six documented deliberate holds; this is a source-shape check, not a progress proof |
| `check_probe_visit_latch.py` | Every idle-loop probe arming question takes `core_id` and reads the calling core's own progress, so a peer that has done its part does not re-enter (#853, #860; two reviewed holds); `peer_tick_window_peer()` only in reviewed functions, so a core-0 wait across several peers takes each peer's own window (#756, #860). Source shape only |
| `check_probe_visit_latch_controls.py` | Arming without the visit latch, an idle-loop ask without `core_id`, stale hold/pair entries and a new fixed-pair wait reject; comments and strings pass |
| `check_probe_tick_windows_controls.py` | Real entry/helper waits, new functions, extra holds and missing reasons reject; intentional holds, comments and strings pass |
| `check_probe_round_restart.py` | Discover re-entered secondary probe entries and reject invocation-local `0..<ROUNDS` batches; not a proof of helper-hidden or arbitrary phase protocols |
| `check_probe_round_restart_controls.py` | The actual previous freelist loop, iterator renaming and qualifiers reject; comments/strings and local buffer loops pass; new, absent and duplicate entry bodies are covered |
| `check_race_window_anchors.py` | Every armed/reverted race edit matches the tracked source exactly once before compilation; obsolete, absent and duplicate anchors are refused |
| `check_race_window_builds.py` | Every race-window kernel a lane or script boots (`KERNEL_QEMU_RACE_WINDOW=`, `kernel-race-*.elf`) is one `kernelbuild-check` builds from `KERNEL_QEMU_RACE_WINDOWS`/`KERNEL_QEMU_RACE_CONTROLS`, and names a window the overlay builder defines; an omitted control, an armed boot of a reverted-only control and an unknown window are refused (#839) |
| `check_race_window_overlay_only.py` | a widened race window's spin exists only in its overlay, never in kernel/, so no ordinary kernel carries it (#615) |
| `check_race_window_overlay_only_controls.py` | Controls for the race-window overlay check, in both directions |
| `check_no_cursor_reply.py` | no host driver answers BusyBox's cursor query, whose late reply lands in the next command (#644) |
| `check_no_cursor_reply_controls.py` | Controls for the cursor-reply check, in both directions |
| `check_pass_line_counts.py` | every check reports PASS through `scripts/pass_line.py`, asserting a count that is zero when it examined nothing |
| `check_patch_embedded_image_controls.py` | Controls for the exact embedded-rootfs replacement used by the interactive RPi5 image |
| `check_pipefail_early_exit.py` | no `pipefail` script pipes a large producer into a consumer that leaves at the first match |
| `check_pipefail_early_exit_controls.py` | Controls for the pipefail/SIGPIPE check, in both directions |
| `check_platform_file_parity.py` | duplicated platform functions do not drift silently, and neither do identical inline runs of eight significant lines |
| `check_platform_view_parity.py` | a view compared on one lane only says why it is not shared |
| `check_platform_view_parity_controls.py` | Controls for the platform-view parity check |
| `check_fixture_poll_bounds.py` | every `while` loop in an EL0 fixture that polls WORKLOAD_PROGRESS counts against an UPPER_CASE bound or carries a `// poll-bound:` reason (#844); controls plant an unbounded poll, an answer-only compare and masked bounds |
| `check_peer_filesystem_controls.py` | the peer filesystem verdict requires CPU-1 reads, failed first lock attempts on both CPUs, and capture completion on both platforms; controls remove each link |
| `check_peer_console_process_controls.py` | the peer-console verdict requires real EL0 writes, CPU migration, alternating parent/child order, actual short counts, all 1071 bytes, bounded DDB hold and release publication before IRQ restore |
| `check_pool_release_paths.py` | every kernel pool has a release path or explicit exemption |
| `check_pool_zero_before_stamp.py` | a pool slot's storage is cleared before the generation that makes it answer Live is stamped, so a lockless walker cannot read the free-chain link as a payload (#514) |
| `check_pool_zero_before_stamp_controls.py` | Controls for the pool clear-before-stamp check, in both directions |
| `check_probe_entry_gates.py` | a two-core probe's arrival gate waits on a count that only grows, never on a level the other core clears |
| `check_mpidr_reads.py` | MPIDR_EL1 is read only by the platform's `cpu_id()` and boot code; a snapshot that stored raw MPIDR named every RPi5 core core 0 (#830) |
| `check_invariant_stop_controls.py` | Explicit kernel stop call-site resolution against exact ELF; wrong identity, origin, unsupported instruction and truncated RAM refusal |
| `check_symbolize_ddb_controls.py` | Exact-capture PID/ELF registration, PIE and fixed executable PCs, verified entry/bias consistency, archived identities, segment and malformed-user-boundary refusal |
| `check_qemu_lane_ports.py` | QEMU lanes do not claim conflicting protocol ports, and every lane fits the per-session port block |
| `check_raw_pos_fname.py` | source identity uses the canonical path helpers |
| `check_keyword_tables.py` | the lexer's keyword table and `Language_words.hard_keywords` name the same words, so a new keyword cannot silently lex as an identifier (#704) |
| `check_repeat_kernel_lane_controls.sh` | Regression controls for the repeat runner's two modes |
| `check_lane_budget.py` | allcheck runs at most 25 leaf QEMU lanes and, when `_build/lane-timing` is present, the last allcheck spent at most 9000 lane-seconds; a new error case joins an existing lane (`docs/LANE_INVENTORY.md`, #908) |
| `check_lane_budget_controls.py` | an added lane is counted, aggregates expand to leaves, both budget boundaries hold, a renamed lane list is refused and receipts are summed |
| `check_roadmap_size.py` | ROADMAP.md stays the current work split rather than regrowing into a knowledge base |
| `check_lane_kernel_prereqs.py` | no public phony Make target names a kernel build output as a direct prerequisite; it must build it under the kernel build lock (#645 land: litmuscheck raced allcheck's kernel lanes on ext2.img) |
| `check_lane_kernel_prereqs_controls.py` | a direct object, a continued-line image and a literal kernel/build path are refused; private inner targets, file rules, order-only directories and reviewed targets pass |
| `check_herdtools_pin.py` | the herdtools7 opam pin (herd7 for `make litmuscheck`, #645) is one version and the same in .devcontainer/devcontainer.json and scripts/build_herd7.sh; ci.yml never opam-installs herdtools7 and runs the build only on a herd7 cache miss, into the cached path HERD7 names |
| `check_herdtools_pin_controls.py` | a drifted CI pin, an unpinned devcontainer install and two pins in one file are refused |
| `check_ci_parts.py` | CI's hardware-free matrix runs `make cicheck-<part>` for exactly the Makefile's CICHECK_PART_* parts, whose concatenation is cicheck's lane list; expanded by make, the parts hold every hardware-free allcheck lane exactly once; every part runs `ci_time_budget.py`; and each tool step (Java, model-tools cache, herd7 cache and build, kernel-image prebuild) admits exactly the parts whose lanes use it (#816); its controls refuse a dropped part, a dropped lane list entry, a missing target, a single serial job, a removed budget step, a lane in two parts or none, a tool set up for a part that does not use it or withheld from one that does, and an unreadable `if:` |
| `check_ci_time_budget_controls.py` | `ci_time_budget.py` reads the job's one `timeout-minutes` and fails a CI part past 75% of it, before the hard limit cancels it without a verdict (#816) |
| `check_rpi5_set_kernel_byte_controls.py` | Controls for the live RPi5 kernel-byte writer without using the board |
| `check_run_kernel_shell_console_controls.py` | Regression controls for the interactive console's UART marker detection |
| `check_run_kernel_uart_driver_controls.py` | UART timeout diagnosis, final-report and fresh post-settings prompt gates, and exact ash echo normalization |
| `check_slot_proof_dropped_to_index.py` | a slot liveness proof dropped to a bare index is declared with a reason, so #569's shape is a decision rather than a line |
| `check_slot_proof_dropped_to_index_controls.py` | Controls for the slot-proof-to-index check, in both directions |
| `check_process_slot_zero.py` | no process is slot 0: the static bootstrap's names stay gone, placement, stack-run, record and root selection branch on no slot, and no per-process call is given slot 0 (#831) |
| `check_process_slot_zero_controls.py` | Controls for the process-slot-zero check, in both directions |
| `check_single_dune_invocation.py` | exactly one rule runs `dune build`, so no second make invocation races its lock |
| `check_dune_root.py` | every dune call pins its workspace root to its own tree (Makefile `override DUNE_ROOT := $(CURDIR)`, DUNE_ROOT/--root in scripts), so a build in a nested worktree never builds the enclosing checkout's _build (#753, #760); the $(TAKIBI) recipe also fails when dune did not touch _build/.lock here |
| `check_nice_heavy.py` | every unleased CPU-heavy Makefile recipe (the compiler, dune, model/litmus/fuzz/slowcheck runners, the dune test lister, the kernel and linux_user build-lock runners) runs under `$(NICE_HEAVY)` (`nice -n 10`), and no QEMU lane (`scripts/run_lane.sh`) does, so a land's own compiles cannot starve the guests' lock-step boot probes (#854); controls plant an un-niced compile, continuation, dune, slowcheck, lock runner, zero niceness and a niced lane |
| `check_untimed_dune_build.py` | no script or recipe runs `dune build` under a wall-clock limit: a build follows machine load, so it runs untimed as its own step (#641) |
| `check_validate_protocol_trace_controls.py` | Controls for the protocol-trace report parser that feeds TLC (#606 stage 2), in process: a lost change, a cut report, a missing or second window, a miscounted header, malformed lines, a snapshot missing a core or not first, an unknown state and a reparented process are refused; the generated module's conventions (fresh record Constructing from the start, other late pids Absent, locked-only wait reasons, Reaped with its parent) hold; and StackOwnership.tla's Next, StackOwnershipTrace.tla's labelled actions and the validator's `--without` choices are one list. The protocol refusals run TLC and live in `scripts/protocol_trace_tlc_controls.py`, part of `make modelcheck`: four recorded windows accepted, each refused without the action it needs, and #609, 765a27af, #803, #550, #647 and #653 shapes refused |
| `check_validate_log_ring_trace_controls.py` | Controls for the log-ring trace parser that feeds TLC (#656), in process: a missing, doubled, cut, lossy or miscounted window, malformed events, a record wider than LogRing.tla's K, a slot index past its record, a nonzero Free word, a reader event before its begin, a read word wider than K, and a malformed, stamped-begin or backward counter stamp are refused; stamps are rebased; the opening-state conventions (shift by a multiple of the slot count, earliest word per slot, a writer first seen mid-record) hold; and LogRing.tla's Next, LogRingTrace.tla's labelled actions, the validator's `--without` choices and the event kinds are one list. The protocol refusals run TLC in `scripts/log_ring_trace_tlc_controls.py`, part of `make modelcheck`: a synthetic window accepted and refused without Commit; a short window accepted with stamps in order and refused when its stamps put a load before the write it saw; a torn read, a silent loss and a double owner refused |
| `check_wont_compile_catalog.py` | every defect-catalog entry names a test case and external comparison set with a valid nonfuture date, shows its figure, and agrees with the index; external truth is not checked |
| `check_xhci_register_offsets.py` | RP1 xHCI register fields sit at their xHCI-specification offsets, and an ERST programmed via ERSTBA also declares and writes ERSTSZ (#754) |
| `check_xhci_register_offsets_controls.py` | Controls for the spec layout, the #754 missing ERSTSZ, an unwritten ERSTSZ and misplaced registers, and an ERSTSZ field or write present only in a comment (#815) |
| `check_register_offsets.py` | every kernel io struct beyond xHCI has a sourced offset table (public spec, Raspberry Pi Linux source, or board evidence) and each field sits at its table's offset with its table's array size (#805) |
| `check_register_offsets_controls.py` | Controls for the kernel layout, a GEM TBQPH at 0x4C4, an unlisted queue-bank field, a resized or scalarized array, a BCM2712 HARD_DEBUG at another chip's offset, an unsourced block, a vanished block and an unreadable field line |

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
| `slowcheck_qmp_reply_reads_controls.py` | Controls for the QMP reply-read check, and each QMP client against a fake QMP that sends an event before every reply |
| `slowcheck_checkpoint_rebase_controls.py` | In scripted Git repos, a rebase conflict confined to `docs/SPACE_CHECKPOINT.json` resolves to the branch's review rebound to the rebased sources (space_checkpoint passes); a conflict that also touches another file stays stopped (exit 4); a branch whose own review was stale is refused (exit 2); a clean rebase adds no commit (#832); a `kernel/models/README.md` conflict in Reviewed stamps only merges, is restamped in its own commit before the checkpoint re-record, and one with any other cell change stays stopped (exit 4) (#833) |
| `slowcheck_land_precheck_controls.py` | The real land shell stops at the first failed host gate, names its lane and preserves diagnostics; green gates retain the full clean aggregate and exact-HEAD push, and failed clean/allcheck cannot publish |
| `slowcheck_preflight_kernel_file_controls.py` | `scripts/preflight_kernel_file.py`, the on-demand list of every registry a new, moved or renamed kernel file, assembly file or lane runner must join, names each missing or stale row for planted files and reports an unchanged file clean |
| `slowcheck_ddb_qemu_capture_controls.py` | Retained UART/software BREAK captures exercise the shared live/offline predicates; missing evidence, wrong values and ordering violations fail with individual diagnoses |
| `slowcheck_ddb_signal_names_controls.py` | Controls for the DDB signal-vocabulary check |
| `slowcheck_fallback_counters_controls.py` | Controls for the dead-slot fallback report check |
| `slowcheck_core_role_sites_controls.py` | Controls for the core-role site check |
| `slowcheck_irq_restore_sites_controls.py` | Controls for the IRQ-restore site check |
| `slowcheck_pass_line_counts_controls.py` | Controls for the PASS-line guard, in both directions |
| `slowcheck_platform_file_parity_controls.py` | Controls for the platform-parity check, both halves of it |
| `slowcheck_profile_kernel_samples_controls.py` | Controls for bounded flat-PC sample validation and symbolization |
| `slowcheck_profile_kernel_workload_controls.py` | Positive and negative controls for workload-profile host artifacts |
| `slowcheck_validate_kernel_dmesg_timestamps_controls.py` | Controls for dmesg integrity, measurement-only QEMU boot duration, and separately enforced performance bounds |
| `slowcheck_wont_compile_catalog_controls.py` | Controls for catalog structure, missing/malformed/future comparison dates and a valid leap day, and sample runner verdicts |
| `slowcheck_debug_return_entry.py` | Real GDB accepts an indirect forced return at machine entry and rejects a later PC before writing the result buffer |
| `slowcheck_known_intermittent_issues.py` | every row of the known-intermittent table names an issue that is still open |
| `slowcheck_lease_wait.py` | a shell driver keeps waiting while its runner prints `[lease] waiting` past the deadline, and still times out a runner silent as long without one |
| `slowcheck_board_link_gate.sh` | Controls for the shared board-link gate |
| `slowcheck_kernel_net_readiness.py` | Controls for the host peer's readiness waits, with no QEMU in the room |
| `slowcheck_qemu_session_ports.sh` | Regression controls for the per-session QEMU port block claim |
| `slowcheck_resource_lease.sh` | Regression controls for cross-container board and aggregate-suite leases |
| `slowcheck_run_kernel_build_locked.sh` | Regression controls for the cross-Make kernel build lock |
| `slowcheck_run_kernel_ddb_rpi5_driver.py` | PTY controls for console-hold and release evidence, a newline wake before BREAK on CPU 0, and the RPi5 DDB driver's resume retry |
| `slowcheck_run_lane.sh` | Controls for the lane timing receipts and the summary built from them |
| `slowcheck_lane_new_archives.sh` | `run_lane.sh` refuses a passing lane that left a failure archive tagged with its run id (`lane_new_archives.py`) unless the archive says why it is expected; the race-window reverted kernel is marked expected and the armed one never (#883) |
| `slowcheck_run_tlc.py` | Parallel TLC jobs use private standard-module files, preserve JVM exit statuses, and clean temporary directories on success and failure |

## `buildcheck_*` -- checks of a build product

Not a lane. Each must be handed a linked ELF or a built kernel, so each runs
from the rule that produces it -- which is also why a clean checkout cannot
run them, and why they sit outside both globs above.

| Check | Enforced invariant |
| --- | --- |
| `buildcheck_elf_symbol_alignment.py` | Reject a linked ELF when a required symbol is under-aligned |
| `buildcheck_gdb_helper_names.py` | Every symbol, struct type and field the GDB helpers name (scripts/*.gdb, the gdb-importing scripts, every runner's `gdb -ex` commands) exists in the linked debug kernel's DWARF and symbol table -- member chains rooted at a global are resolved type by type, and a debugger-only function removed by `--gc-sections` is a missing symbol (#766, #786); names built at run time from a literal tuple loop are checked per value, a subscript on a typed local against its DWARF type, Takibi enum/variant/case/constant names against the debug-metadata JSON, and any other run-time argument must be listed in `DYNAMIC` (#889). RPi5 runners are checked against the RPi5 debug ELF with `--rpi5`. `stall_probe.gdb` is checked against each race-window ELF and `debug_return_abi.gdb` against its fixture; `--controls` renames one name of each kind in a copy and requires refusal |
| `buildcheck_backing_exists.py` | Real kernel overlays accept borrowed backing/image/FD evidence and reject unensured writers, wrong-record evidence and foreign minting |
| `buildcheck_user_write_result.py` | Real kernel overlays accept a matched user-memory store and reject an ignored, unmatched or bool-read `UserWriteResult` (#725) |
| `buildcheck_process_current_phase.py` | Real Running/Constructing transition APIs reject retained current authority; consuming it permits transition |
| `overlay_jobs.py` | not a check: the three overlay buildchecks above run their cases through it on a pool of a quarter of the host threads, one symlinked overlay per worker, reporting in case order (#915); `TAKIBI_BUILDCHECK_JOBS=1` restores the serial run |
| `buildcheck_kernel_asm_invariants.py` | Linked-kernel instruction invariants: UXN bits, eret masking, the spinlock and mutex sequences, broadcast TLB invalidation, per-core exception stacks, the stack handoff hook, explicit stops, and no misaligned q-register store in the MMU-off page allocator (#746) |
| `buildcheck_kernel_same_operand_csel.py` | Linked production kernels: the number of `csel` whose two sources are one value (directly or through a `mov` among the three instructions before it) stays at or under its ceiling, 6 QEMU and 10 RPi5 (#893; the remaining ones are #939) |
| `buildcheck_kernel_memory_map.py` | Check kernel/MEMORY_MAP.md and allocator fixtures; render QEMU boot capacity from the loaded ELF |
| `buildcheck_ext2_reproducible.sh` | run by kernelbuild-check: rebuilds ext2.img and ext2-shell.img from the same inputs and fails on any byte difference; the control rebuilds at another `KERNEL_EXT2_FAKE_TIME` and requires a difference; the prior images are restored with their timestamps (#890) |
| `buildcheck_kernel_unused_coverage.py` | every kernel file a target compiles is checked for unused functions or exempt for a stated reason |
| `buildcheck_compile_alloc_budget.py` | the QEMU kernel main.o compile allocates no more OCaml heap words (`--emit-alloc-words`) than its recorded budget; a load-independent guard on compiler speed (#923) |
| `measure_trusted_base.py --check-raw-deref` | the raw-pointer dereference ratchet (#639): run by each kernel object's rule on the compiler's `--emit-raw-deref-audit`, including standalone EL0 payload objects, it holds every file's dereference count to `raw_deref_budget.tsv`, so the count can only go down on purpose. Also the trusted-boundary inventory of `make trustedbasecheck` |
| `buildcheck_suite_output.py` | Split a batched UART stream and compare each case with its fixture |
| `buildcheck_user_payload_no_rw_globals.py` | TODO |
| `buildcheck_wont_compile_samples.py` | every program the defect catalog prints is rejected with the diagnostic beside it, or accepted, by the built compiler |
| `buildcheck_regions_flag.py` | a program using region built-ins without `--regions` is refused up front with a diagnostic naming the flag, and compiles with it |

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

## Publication boundary

`scripts/space_checkpoint.py` is invoked by `scripts/land.sh`, after rebase
and before clean allcheck. It reads the exact Git source tree and refuses a
missing/stale space checkpoint, malformed classification, absent evidence or
reuse at a milestone. It is not a fast/build lane: it checks the actual
publication range. Its pure controls run in langcheck.
