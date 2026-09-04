# -- Configuration ------------------------------------------------------------
# Parallel by default, overridable per-invocation: `make -j1 kernelcheck`
# forces serial execution back, e.g. when a build error needs to be read one
# recipe at a time. `-Oline` keeps completed recipe lines atomic at the
# terminal; interactive recipes must reconnect themselves to /dev/tty because
# their long-lived output is otherwise captured until the recipe exits.
# `-Otarget` remains unsuitable here: it hides all progress until a long
# recipe finishes.
ifeq ($(MAKELEVEL),0)
MAKEFLAGS += -j$(shell nproc)
endif
MAKEFLAGS += -Oline --no-print-directory

# Invoke the built binary directly rather than "dune exec takibi --": dune
# exec re-checks/re-locks the workspace on every call, which serializes
# concurrent invocations under `make -j`. Every .o rule below depends on
# $(TAKIBI) itself (a REAL prerequisite, not order-only -- see its own
# rule further down for why), so the binary is always fresh before any
# of these run, AND a genuine compiler change correctly invalidates every
# kernel object that was already built with an older compiler.
TAKIBI  := _build/default/bin/main.exe
LLVM_MC      := llvm-mc-19
LLD          := ld.lld-19
LLVM_OBJCOPY := llvm-objcopy-19

# -- This file covers kernel/ + the compiler only ------------------------------
# All new implementation and maintenance work happens under `kernel/` (see
# AGENTS.md's "Maintenance Scope: kernel/ Only"), so its targets stay in this
# top-level Makefile where they are the obvious, hard-to-miss default.
#
# `examples/` is historical heritage -- frozen bare-metal milestones that
# predate the standalone kernel and are no longer an active product surface.
# Its ~40 build/test/hardware-check targets live entirely in
# `examples/Makefile` instead, and are reached with an explicit
# `make -f examples/Makefile <target>` from the repo root (see that file's
# own header comment). This split exists because "kernel" and "RPi5" targets
# used to coexist under near-identical names in one Makefile (e.g. the
# examples-only `hwcheck-rpi5-net` next to the real kernel/ hardware target
# `kernelcheck`), which made it easy to run the wrong one by accident.

# -- Targets ------------------------------------------------------------------
.PHONY: build test kernelbuild kernelcheck kernelbuild-rpi5 kernelbuild-qemu kernelbuild-qemu-debug kernelcheck-rpi5 kernelcheck-ddb-rpi5-software kernelcheck-qemu kernelcheck-qemu-main kernelcheck-qemu-fdt-multibank kernelcheck-qemu-ash kernelcheck-shell-qemu kernelcheck-qemu-debug kernelcheck-qemu-debug-main kernelcheck-qemu-debug-repeat kernelcheck-qemu-debug-ash kernelcheck-oops-qemu kernelcheck-ddb-qemu kernelcheck-lifecycle-gap-qemu kernelcheck-alloc-rollback-qemu kernelcheck-repeat kernelsh-qemu kernelsh-rpi5 lease-status profile-kernel-workload-chart langcheck linuxbuild linuxcheck clean FORCE

.DEFAULT_GOAL := build

## build: build only the OCaml compiler (dune)
build: $(TAKIBI)

# $(TAKIBI) is the actual compiler binary dune produces. FORCE has no
# recipe and is always considered out of date, so this rule's recipe
# (dune build) runs on every `make` invocation that reaches it -- but
# dune's own incremental/content-addressed build only updates main.exe's
# mtime when the compiled output genuinely changes (confirmed
# empirically: repeated no-op builds, and even a comment-only source
# edit, leave the mtime untouched; a real code change updates it). Every
# kernel object rule below lists $(TAKIBI) as a REAL (not order-only)
# prerequisite, so a genuine compiler change correctly makes every kernel
# object look stale and get recompiled, with no separate `make clean` step
# required (found the hard way, back when this Makefile was one file with
# examples/ -- see AGENTS.md's "History: order-only `| build`" entry).
# This must stay the ONLY rule in the repo that invokes `dune build`:
# examples/Makefile depends on $(TAKIBI) too, but forwards to this target
# via `$(MAKE) -C .. build` instead of calling `dune build` itself, so a
# second, independent invocation racing this one under `make -j` can't
# reintroduce the "Unexpected contents of build directory global lock
# file" corruption already hit once before (`test: build` below reaches
# `dune build` exclusively through this one target too).
.PHONY: FORCE
FORCE:

ifeq ($(TAKIBI_KERNEL_BUILD_LOCK_HELD),1)
# The public locked targets depend on `build` before entering their recursive
# Make. The inner graph must reuse that completed compiler: invoking Dune from
# a second Make process would recreate the cross-invocation Dune lock race the
# top of this file deliberately prevents.
$(TAKIBI):
else
$(TAKIBI): FORCE
	dune build
endif

## test: run the ordered unit tests, then one reproducible shuffled pass
# Depends on `build` (not just order-only) so "dune test" never runs
# concurrently with "dune build": dune's build-directory lock file is not
# safe against two concurrent dune invocations racing to create it
# (observed: "Unexpected contents of build directory global lock file").
# ALCOTEST_COMPACT=1 collapses each passing test to a single '.' instead of
# a full "[OK] suite N description..." line -- with 1100+ tests, the
# uncompacted form buried real failures in thousands of lines of routine
# pass output.
#
# Routed through scripts/list_dune_test_failures.sh, not a bare `dune
# test`, because Alcotest's own terminal reporter prints only the FIRST
# failing case's detail box when several fail in one run -- discovered
# investigating issue #325 (33 real failures, one ever visible), and
# rediscovered the hard way again in the #344 session despite this script
# already existing, which is why `make test` calls it automatically now
# instead of leaving that up to whoever remembers. The script re-derives
# every failure's detail by grepping dune's own per-test `.output` log
# files (`--force`'d fresh on every run so a stale log is never mistaken
# for a current one) and still exits 0/1 like a bare `dune test` would, so
# nothing downstream that depends on `test`'s exit code changes. The second
# invocation uses issue #331's original reproducer seed: it interleaves all
# Alcotest groups deterministically, prints the seed, and keeps each case's
# original group/name in its shuffled display name. The ordered pass remains
# first so its stable native Alcotest paths remain available for diagnosis.
test: build
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env ALCOTEST_COMPACT=1 bash scripts/list_dune_test_failures.sh
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env ALCOTEST_COMPACT=1 SHUFFLE_TESTS=877156326 bash scripts/list_dune_test_failures.sh

## langcheck: verify that all source files contain only ASCII characters.
## Repo-wide (kernel/, examples/, the compiler itself), so this is the one
## canonical implementation; examples/Makefile's own `langcheck` target
## just forwards here via `$(MAKE) -C .. langcheck`.
.PHONY: unused-function-control
unused-function-control: build
	@$(TAKIBI) test/fixtures/unused_function_positive.tkb --target $(LINUX_AMD64_TARGET) \
		--forbid-trap --reject-unused-functions --external-entry main -o /tmp/takibi-unused-positive.o
	@status=0; output=`$(TAKIBI) test/fixtures/unused_function_negative.tkb \
		--target $(LINUX_AMD64_TARGET) --forbid-trap --reject-unused-functions \
		--external-entry main -o /tmp/takibi-unused-negative.o 2>&1` || status=$$?; \
	if [ $$status -eq 0 ]; then echo "FAIL unused-function-control: negative build succeeded" >&2; exit 1; fi; \
	case "$$output" in *"unused function 'stale_helper': no reachable caller or declared entry point"*) ;; \
	*) echo "FAIL unused-function-control: expected diagnostic not found" >&2; echo "$$output" >&2; exit 1;; esac; \
	echo "PASS unused-function-control: positive build succeeded and negative build failed for stale_helper"

## GitHub issue #488: the pool's payload accessor must keep returning a
## pointer TIED to the liveness proof. Untying it removes compile errors
## rather than adding them, so the kernel building is not evidence that the
## tie survives -- this is.
.PHONY: pool-liveness-control
POOL_CONTROL_SRCS = $(LINUX_USER_DIR)/common_linux/uart.tkb \
	$(LINUX_USER_DIR)/common_linux/print.tkb \
	$(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb \
	kernel/lib/spinlock.tkb kernel/lib/mutex.tkb \
	$(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
pool-liveness-control: build
	@$(TAKIBI) $(POOL_CONTROL_SRCS) test/fixtures/pool_liveness_positive.tkb \
		--target $(LINUX_AMD64_TARGET) --forbid-trap -o /tmp/takibi-pool-positive.o
	@status=0; output=`$(TAKIBI) $(POOL_CONTROL_SRCS) \
		test/fixtures/pool_liveness_negative.tkb \
		--target $(LINUX_AMD64_TARGET) --forbid-trap \
		-o /tmp/takibi-pool-negative.o 2>&1` || status=$$?; \
	if [ $$status -eq 0 ]; then echo "FAIL pool-liveness-control: a payload pointer escaped its proof and the build succeeded" >&2; exit 1; fi; \
	case "$$output" in *"authority-derived pointer 'payload' cannot be returned"*) ;; \
	*) echo "FAIL pool-liveness-control: expected diagnostic not found" >&2; echo "$$output" >&2; exit 1;; esac; \
	echo "PASS pool-liveness-control: the payload pointer cannot outlive its liveness proof"

.PHONY: effect-matrix-control
effect-matrix-control: build
	@tmp=`mktemp`; trap 'rm -f "$$tmp"' EXIT; \
	$(TAKIBI) --emit-effect-matrix > "$$tmp"; \
	if ! cmp -s EFFECTS.md "$$tmp"; then \
		echo "FAIL effect-matrix-control: EFFECTS.md is stale; regenerate with $(TAKIBI) --emit-effect-matrix" >&2; \
		diff -u EFFECTS.md "$$tmp" >&2 || true; exit 1; \
	fi; \
	echo "PASS effect-matrix-control: EFFECTS.md matches compiler effect rules"

langcheck: unused-function-control effect-matrix-control pool-liveness-control
	@python3 scripts/check_agents_paths.py
	@python3 scripts/test_check_expected_line_endings.py
	@python3 scripts/check_expected_line_endings.py
	@python3 scripts/test_check_elf_symbol_alignment.py
	@python3 scripts/test_check_kernel_memory_map.py
	@python3 scripts/test_check_kernel_asm_invariants.py
	@bash scripts/test_run_kernel_build_locked.sh
	@bash scripts/test_qemu_session_ports.sh
	@bash scripts/test_resource_lease.sh
	@python3 scripts/test_run_kernel_shell_console.py
	@python3 scripts/test_run_kernel_uart_driver.py
	@python3 scripts/test_check_direct_mmio_literals.py
	@python3 scripts/test_check_ddb_command_inventory.py
	@python3 scripts/test_measure_trusted_base.py
	@python3 scripts/test_profile_kernel_workload.py
	@python3 scripts/test_profile_kernel_samples.py
	@bash scripts/test_repeat_kernel_lane.sh
	@bash scripts/test_archive_kernel_failure.sh
	@python3 scripts/check_direct_mmio_literals.py kernel
	@python3 scripts/check_stale_depfiles.py
	@python3 scripts/check_single_dune_invocation.py
	@python3 scripts/check_compiler_sync_rules.py --quiet
	@python3 scripts/check_raw_pos_fname.py
	@python3 scripts/check_qemu_lane_ports.py
	@python3 scripts/check_kernel_interactive_httpd_protocol.py
	@python3 scripts/check_pool_release_paths.py
	@python3 scripts/check_platform_file_parity.py
	@python3 scripts/check_kernel_log_expectations.py
# -I skips binary files. Without it a build directory left in the worktree
# under any name but `_build` -- a copy taken for diagnosis, say -- makes grep
# match dune's preprocessed .pp.ml files, which carry NUL. That reports
# "binary file matches" on stderr, which this recipe discards, so the run ends
# with "found (see above)" and nothing above it. The check is about source
# text, and a file grep calls binary is not source text.
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash -c ' \
		echo "Checking for non-ASCII characters in source files..."; \
		if LC_ALL=C grep -rnPI "[^\x00-\x7F]" --exclude-dir=_build \
		       --include="*.ml" --include="*.mll" --include="*.mly" \
		       --include="*.tkb" --include="*.S" --include="*.md" \
		       --include="*.sh" --include="*.ld" --include="*.py" \
		       . Makefile examples/Makefile 2>/dev/null; then \
		    echo "ERROR: non-ASCII characters found (see above)"; exit 1; \
		fi; \
		echo "OK: all files are ASCII-clean" \
	'

# -- linux_user/ (host-native Linux/AMD64 environment-independent tests) -----
# See AGENTS.md's "Where Should a New Test Go?": this directory holds
# compiled-AND-EXECUTED integration tests whose pass/fail does not depend on
# real hardware timing, interrupts, cache behavior, or concurrency -- if it
# would, the test belongs under kernel/ hardware testing instead, however
# inconvenient that is, not here for convenience. Compiled for this host's
# own x86_64 architecture and run natively, no QEMU or real hardware needed,
# so these stay part of the always-on `kernel/` + compiler surface (see the
# section comment above "-- This file covers kernel/ + the compiler only").
# Deliberately self-contained: nothing here `use`s anything under examples/,
# so it has no dependency on that frozen tree.
LINUX_AMD64_TARGET      := x86_64-pc-linux-gnu
LINUX_USER_DIR           := linux_user
LINUX_UNUSED_CHECK       := --reject-unused-functions --external-entry main
KERNEL_UNUSED_CHECK      := --reject-unused-functions \
	--external-entry main --external-entry kernel_secondary_main \
	--check-unused-file kernel/arch/arm64/boot/cpu.tkb
LINUX_USER_BUILD_DIR     := $(LINUX_USER_DIR)/build
COMMON_LINUX_DIR         := $(LINUX_USER_DIR)/common_linux
COMMON_LINUX_STARTUP_S   := $(COMMON_LINUX_DIR)/startup.S
COMMON_LINUX_STARTUP_O   := $(LINUX_USER_BUILD_DIR)/startup.o
COMMON_LINUX_SYSCALL_S   := $(COMMON_LINUX_DIR)/syscall.S
COMMON_LINUX_SYSCALL_O   := $(LINUX_USER_BUILD_DIR)/syscall.o
COMMON_LINUX_UART        := $(COMMON_LINUX_DIR)/uart.tkb
COMMON_LINUX_PRINT       := $(COMMON_LINUX_DIR)/print.tkb
COMMON_LINUX_PRINT_BASE  := $(LINUX_USER_DIR)/common/print.tkb $(LINUX_USER_DIR)/common/runtime.tkb kernel/printk/number.tkb
# One test per directory, name == directory name, matching examples/'s own
# convention. Add to this list as tests are migrated in from examples/ or
# written fresh (see AGENTS.md). Each of these six was verified to compile,
# link, and run under x86_64-pc-linux-gnu with output byte-identical to its
# original examples/ QEMU .expected before being migrated -- pure logic
# (type system, algorithms, checked arithmetic, ELF parsing, single-core
# allocator bookkeeping), no MMIO/interrupt/concurrency dependency.
# examples/klock_guard was tried and rejected: it links against
# enable_irq/disable_irq (real interrupt control), so it belongs in
# kernel/-style hardware testing per the litmus test below, not here,
# despite compiling cleanly -- compiling is not the bar, the litmus test is.
# The 41 single-fixture tests below were basic_suite/type_system_suite/
# algorithm_suite's sub-fixtures in examples/ (see AGENTS.md's "Copy, don't
# blindly move" note): those suites batch many fixtures into one QEMU/
# hardware boot and split the UART stream on markers to keep each fixture's
# own .expected independently checkable, because a QEMU/hardware boot is
# expensive enough that batching mattered. That reason doesn't apply here --
# a native process starts in a few milliseconds -- so each fixture below is
# its own directory/binary/`.expected`, source content unchanged from
# examples/ except one appended `fn app_main() { test_<name>(); }` wrapper
# (the suites supplied that wrapper themselves; a standalone binary needs
# its own). This split-not-batched shape is the template to follow when
# adding new linux_user/ tests for a new algorithm or data structure.
LINUX_USER_EXAMPLES      := linux_hello start checked_usize elf64_validate bump percpu page_pool \
                             freelist_pool freelist_generic slotmap refcount_slotmap growable_pool \
                             intrusive_pool intrusive_pool_portable pool_container page_run tcp_pool_shape \
                             hello print_int print_hex print_ptr mem array struct struct_refined \
                             nonexhaustive refined narrow enum align packed struct_align const_global \
                             sizeof_offsetof int64 bitops indexed_view tcp_conn_view \
                             affine_escape_via_index align_ptr_proof linear_obligation tuple_pair \
                             field_lease match_int_lit \
                             callstack ringbuf crc8 djb2 slice slice_from_field logical_eval foreach for loop fizzbuzz fibonacci \
                             bubblesort inet_checksum ip_parse tcp_parse wire_endian ref_type byte_slice atomic spinlock locked_cell diagnostic_ring publish fdt number
LINUX_USER_BINS          := $(foreach e,$(LINUX_USER_EXAMPLES),$(LINUX_USER_DIR)/$(e)/$(e).exe)
LINUX_USER_OBJS          := $(foreach e,$(LINUX_USER_EXAMPLES),$(LINUX_USER_DIR)/$(e)/$(e)_exe.o)

# Keep each %_exe.o after linking instead of GNU Make's default behavior of
# auto-deleting pattern-rule intermediates (.tkb -> _exe.o -> .exe is a
# chained implicit rule, so _exe.o counts as an intermediate unless listed
# here). Kept objects still rebuild correctly when a .tkb changes -- the
# %_exe.o pattern rule's own prerequisite on the .tkb file is unaffected by
# .SECONDARY, which only stops the auto-delete-after-use step. `make clean`
# already sweeps every linux_user/**/*.o (see the clean target below), so
# nothing else needs to change to actually remove these when wanted.
.SECONDARY: $(LINUX_USER_OBJS)

# Extra prerequisites (staleness tracking only -- `use` already resolves
# these transitively at compile time, same reasoning as examples/Makefile's
# own .tkb -> .o rule comment) for the tests above that `use` a shared file
# outside their own directory.
$(LINUX_USER_DIR)/checked_usize/checked_usize_exe.o: $(LINUX_USER_DIR)/common/checked_usize.tkb
$(LINUX_USER_DIR)/elf64_validate/elf64_validate_exe.o: $(LINUX_USER_DIR)/common/elf64_validate.tkb $(LINUX_USER_DIR)/common/checked_usize.tkb
$(LINUX_USER_DIR)/page_pool/page_pool_exe.o: $(LINUX_USER_DIR)/page_pool/page_pool_core.tkb
$(LINUX_USER_DIR)/inet_checksum/inet_checksum_exe.o: $(LINUX_USER_DIR)/common/inet_checksum.tkb
$(LINUX_USER_DIR)/tcp_parse/tcp_parse_exe.o: $(LINUX_USER_DIR)/common/inet_checksum.tkb $(LINUX_USER_DIR)/common/netutil.tkb
$(LINUX_USER_DIR)/byte_slice/byte_slice_exe.o: kernel/lib/byte_slice.tkb
# GitHub issue #470: the kernel's device-tree reader, run against a blob
# shaped like the board's own. The blob is generated because it stands in
# for another project's GPL binary; scripts/make_fdt_fixture.py carries the
# values it was read from.
$(LINUX_USER_BUILD_DIR)/fdt_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@

$(LINUX_USER_BUILD_DIR)/fdt_invalid_reservation_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-reservation

$(LINUX_USER_BUILD_DIR)/fdt_invalid_memory_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-memory

$(LINUX_USER_BUILD_DIR)/fdt_invalid_tree_reservation_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-tree-reservation

$(LINUX_USER_BUILD_DIR)/fdt_invalid_device_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-device

$(LINUX_USER_BUILD_DIR)/fdt_invalid_interrupt_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-interrupt

$(LINUX_USER_BUILD_DIR)/fdt_missing_interrupt_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --missing-interrupt

$(LINUX_USER_BUILD_DIR)/fdt_invalid_gic_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-gic

$(LINUX_USER_BUILD_DIR)/fdt_invalid_pcie_ranges_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-pcie-ranges

$(LINUX_USER_BUILD_DIR)/fdt_invalid_pcie_dma_ranges_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-pcie-dma-ranges

$(LINUX_USER_BUILD_DIR)/fdt_invalid_virtio_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --invalid-virtio

$(LINUX_USER_BUILD_DIR)/fdt_psci_smc_fixture.dtb: scripts/make_fdt_fixture.py | $(LINUX_USER_BUILD_DIR)
	python3 scripts/make_fdt_fixture.py $@ --psci-smc

# GitHub issue #470: linux_user/number checks the kernel's own number
# formatters directly. It needs no LINUX_USER_EXTRA_SRCS -- since the #470
# follow-up, linux_user/common/print.tkb `use`s kernel/printk/number.tkb and
# delegates its unsigned decimals to it, so EVERY test here links the
# kernel's formatter and this one just points at it deliberately.

$(LINUX_USER_DIR)/fdt/fdt_exe.o: kernel/boot/fdt.tkb $(LINUX_USER_BUILD_DIR)/fdt_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_memory_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_reservation_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_tree_reservation_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_device_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_interrupt_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_missing_interrupt_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_gic_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_pcie_ranges_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_pcie_dma_ranges_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_invalid_virtio_fixture.dtb $(LINUX_USER_BUILD_DIR)/fdt_psci_smc_fixture.dtb
$(LINUX_USER_DIR)/fdt/fdt_exe.o: LINUX_USER_EXTRA_SRCS := kernel/boot/fdt.tkb

# GitHub issue #445: the kernel's own spinlock, compiled and run natively.
# The same source the kernel links, not a copy -- see the freelist/slotmap
# note below for why that distinction is the point.
$(LINUX_USER_DIR)/spinlock/spinlock_exe.o: kernel/lib/spinlock.tkb kernel/lib/task_mutex.tkb
$(LINUX_USER_DIR)/spinlock/spinlock_exe.o: LINUX_USER_EXTRA_SRCS := kernel/lib/spinlock.tkb kernel/lib/task_mutex.tkb

# GitHub issue #452: kernel/lib/locked_cell.tkb, the container whose value
# cannot be named without its guard. It needs the same stand-ins the pool
# prototypes take -- spinlock for the exchange, pool_lock_check for the
# mutex_irq_save/_restore pair a hosted build has no interrupts to mask.
$(LINUX_USER_DIR)/locked_cell/locked_cell_exe.o: kernel/lib/spinlock.tkb kernel/lib/mutex.tkb kernel/lib/locked_cell.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/locked_cell/locked_cell_exe.o: LINUX_USER_EXTRA_SRCS := kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb

# GitHub issue #217 (2026-08-15) closed the array-field-decay gap this
# comment used to describe for the four targets below: FreelistCore(N)'s
# next_free, SlotMap(N)'s occupant_generation, and RefcountSlotMap(N,
# MAX_REFS)'s generation/refcount all now index directly through their
# owning struct pointer (core.next_free[i], not a decayed *usize) and go
# through the SAME checked/elidable bounds-check codegen a local array
# already got. 17 of 18 call sites across the three files are statically
# proven with zero residual trap; the one that genuinely cannot be (issue
# #216's cross-function owner-index provenance gap in
# freelist_core_remove) is now an explicit, grep-visible `unsafe { ... }`
# marker instead of silently-unchecked pointer arithmetic the checker had
# stopped looking at. See HISTORY.md's 2026-08-15 entries (the migration
# itself, and the adjacent one reversing part of issue #179's unsafe-
# effect propagation, which this migration is what surfaced). `data` (the
# payload storage) stayed a caller-owned slice throughout -- it was never
# affected by the array-field decay gap in the first place.
#
# All four of freelist_pool/freelist_generic/slotmap/refcount_slotmap
# `use` kernel/lib/'s own production files directly (not a re-prototyped
# linux_user/-local copy, which freelist_pool/freelist_generic originally
# were -- issue #207's design-prototyping stage, per AGENTS.md's
# linux_user/ charter), so these are genuine real regression coverage of
# what kernel/ actually ships. See HISTORY.md's 2026-08-07 issue #207/
# #242 entry for why that copy-vs-use distinction mattered here (two real
# double frees were only found via a multi-hour real-hardware boot-log
# bisection with no fast test catching them first). No override of the
# default %_exe.o pattern rule needed (--forbid-trap included) -- only an
# extra prerequisite on the kernel/lib/ files each one `use`s, since the
# default pattern rule doesn't know about a `use` outside a test's own
# directory.
$(LINUX_USER_DIR)/freelist_pool/freelist_pool_exe.o: kernel/lib/freelist.tkb
$(LINUX_USER_DIR)/freelist_generic/freelist_generic_exe.o: kernel/lib/freelist.tkb
$(LINUX_USER_DIR)/slotmap/slotmap_exe.o: kernel/lib/slotmap.tkb kernel/lib/freelist.tkb
$(LINUX_USER_DIR)/refcount_slotmap/refcount_slotmap_exe.o: kernel/lib/refcount_slotmap.tkb kernel/lib/freelist.tkb
$(LINUX_USER_DIR)/growable_pool/growable_pool_exe.o: kernel/lib/freelist.tkb kernel/lib/slotmap.tkb $(LINUX_USER_DIR)/growable_pool/growable_pool_lib.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb
# GitHub issue #344's prototype reuses growable_pool's own fake page
# provider rather than copying it, so that both pools draw from the same
# 9-page supply -- which is what makes intrusive_pool.tkb's side-by-side
# static-footprint comparison (it `use`s growable_pool_lib.tkb too, purely
# to take sizeof of a GrowablePool holding the same object count) a
# like-for-like one.
# kernel/lib/intrusive_pool.tkb names no provider (issue #364), so the
# is supplied here and must precede it.
$(LINUX_USER_DIR)/growable_pool/growable_pool_exe.o: LINUX_USER_EXTRA_SRCS := $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb
$(LINUX_USER_DIR)/growable_pool/growable_pool_exe.o: $(LINUX_USER_DIR)/growable_pool/growable_pool_lib.tkb kernel/lib/freelist.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb
$(LINUX_USER_DIR)/intrusive_pool/intrusive_pool_exe.o: LINUX_USER_EXTRA_SRCS := $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/pool_container/pool_container_exe.o: LINUX_USER_EXTRA_SRCS := $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/pool_container/pool_container_exe.o: kernel/lib/intrusive_pool.tkb kernel/lib/freelist.tkb kernel/lib/slotmap.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/tcp_pool_shape/tcp_pool_shape_exe.o: LINUX_USER_EXTRA_SRCS := $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/tcp_pool_shape/tcp_pool_shape_exe.o: kernel/lib/intrusive_pool.tkb kernel/lib/freelist.tkb kernel/lib/slotmap.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/intrusive_pool_portable/intrusive_pool_portable_exe.o: LINUX_USER_EXTRA_SRCS := $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb kernel/lib/spinlock.tkb kernel/lib/mutex.tkb $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb
$(LINUX_USER_DIR)/intrusive_pool_portable/intrusive_pool_portable_exe.o: kernel/lib/freelist.tkb kernel/lib/slotmap.tkb kernel/lib/intrusive_pool.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb
$(LINUX_USER_DIR)/intrusive_pool/intrusive_pool_exe.o: $(LINUX_USER_DIR)/intrusive_pool/pool_lock_check.tkb kernel/lib/freelist.tkb kernel/lib/slotmap.tkb kernel/lib/intrusive_pool.tkb $(LINUX_USER_DIR)/growable_pool/growable_pool_lib.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb
# GitHub issue #363: the contiguous-run allocator lives in the same fake
# provider both pool prototypes draw from, so this exerciser shares it
# rather than copying -- and a change there is meant to be seen by all
# three.
$(LINUX_USER_DIR)/page_run/page_run_exe.o: kernel/lib/freelist.tkb kernel/lib/slotmap.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb

$(LINUX_USER_DIR)/ip_parse/ip_parse_exe.o: $(LINUX_USER_DIR)/common/inet_checksum.tkb $(LINUX_USER_DIR)/common/netutil.tkb
$(LINUX_USER_DIR)/tcp_parse/tcp_parse_exe.o: $(LINUX_USER_DIR)/common/inet_checksum.tkb $(LINUX_USER_DIR)/common/netutil.tkb

$(LINUX_USER_BUILD_DIR):
	mkdir -p $@

$(COMMON_LINUX_STARTUP_O): $(COMMON_LINUX_STARTUP_S) | $(LINUX_USER_BUILD_DIR)
	$(LLVM_MC) --triple=$(LINUX_AMD64_TARGET) --filetype=obj $< -o $@

$(COMMON_LINUX_SYSCALL_O): $(COMMON_LINUX_SYSCALL_S) | $(LINUX_USER_BUILD_DIR)
	$(LLVM_MC) --triple=$(LINUX_AMD64_TARGET) --filetype=obj $< -o $@

# $(LINUX_USER_DIR)/%_exe.o <- $(LINUX_USER_DIR)/%.tkb (% matches "name/name",
# same static-pattern-rule idiom as examples/Makefile's own .tkb -> .o rule).
# Every linux_user test only ever needs the same minimal uart+print HAL --
# unlike examples/'s many hardware-HAL groupings, there is no MMIO/interrupt
# surface here to vary by test.  That HAL is linked into every test
# unconditionally (below), so a test must never define its own copy of a
# printer: twelve of them had each pasted in the same uart_print_bool body,
# which is exactly the shape that let GitHub issue #470's decimal formatter
# stay wrong on one platform.  Need a new formatter?  Add it to
# linux_user/common/print.tkb, where one edit reaches every caller.
# GitHub issue #364: LINUX_USER_EXTRA_SRCS lets a test name sources that
# must be compiled BEFORE its own, which is how a provider-agnostic
# library binds to a stand-in here and to the real thing in a kernel
# build. The ordering is the whole point -- constants resolve as the
# parser walks the list left to right -- so these go ahead of `$<`.
LINUX_USER_EXTRA_SRCS :=

$(LINUX_USER_DIR)/%_exe.o: $(LINUX_USER_DIR)/%.tkb $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $(COMMON_LINUX_PRINT_BASE) $(TAKIBI)
	$(TAKIBI) $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $(LINUX_USER_EXTRA_SRCS) $< --target $(LINUX_AMD64_TARGET) -o $@ --forbid-trap $(LINUX_UNUSED_CHECK) --check-unused-file $<

$(LINUX_USER_DIR)/%.exe: $(LINUX_USER_DIR)/%_exe.o $(COMMON_LINUX_STARTUP_O) $(COMMON_LINUX_SYSCALL_O)
	$(LLD) -static -nostdlib -e _start $^ -o $@

## linuxbuild: build linux_user/'s host-native Linux/AMD64 tests (no libc, _start -> app_main)
linuxbuild: $(LINUX_USER_BINS)

## linuxcheck: run linux_user/'s tests natively and diff stdout against each .expected
linuxcheck: linuxbuild
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash -c ' \
		fail=0; \
		for e in $(LINUX_USER_EXAMPLES); do \
		    got=$$($(LINUX_USER_DIR)/$$e/$$e.exe); \
		    exp=$$(cat $(LINUX_USER_DIR)/$$e/$$e.expected); \
		    if [ "$$got" = "$$exp" ]; then \
		        echo "PASS  $$e (linux amd64)"; \
		    else \
		        echo "FAIL  $$e (linux amd64)"; \
		        echo "  expected: $$exp"; \
		        echo "  got:      $$got"; \
		        fail=1; \
		    fi; \
		done; \
		exit $$fail \
	'

# -- Raspberry Pi 5 (BCM2712) -------------------------------------------------
RPI5_TARGET := aarch64-none-elf
RPI5_CPU    := cortex-a76

# -- Standalone kernel tree (GitHub issue #177) -------------------------------
KERNEL_DIR              := kernel
KERNEL_FDT_TKB          := $(KERNEL_DIR)/boot/fdt.tkb
KERNEL_BUILD_DIR        := $(KERNEL_DIR)/build/rpi5
KERNEL_RPI5_ENTRY_S     := $(KERNEL_DIR)/arch/arm64/boot/entry.S
KERNEL_RPI5_ENTRY_O     := $(KERNEL_BUILD_DIR)/entry.o
KERNEL_RPI5_BOOT_EXTERN := $(KERNEL_DIR)/arch/arm64/boot/boot_extern.tkb
KERNEL_RPI5_MMU_TKB     := $(KERNEL_DIR)/arch/arm64/mm/mmu.tkb
KERNEL_RPI5_ASID_TKB    := $(KERNEL_DIR)/arch/arm64/mm/asid.tkb
KERNEL_RPI5_USER_ENTRY_S := $(KERNEL_DIR)/arch/arm64/kernel/user_entry.S
KERNEL_RPI5_USER_ENTRY_O := $(KERNEL_BUILD_DIR)/user_entry.o
KERNEL_RPI5_USER_EXTERN  := $(KERNEL_DIR)/arch/arm64/kernel/user_entry_extern.tkb
KERNEL_RPI5_EXC_CONTEXT := $(KERNEL_DIR)/arch/arm64/kernel/exception_context.inc
# Generated (GitHub issue #286, gitignored) -- offset constants only,
# `.include`d by the hand-written file above. Emitted by $(TAKIBI)'s own
# --emit-exception-frame-offsets flag (see the file rule below), not a
# separate script.
KERNEL_EXC_CONTEXT_OFFSETS := $(KERNEL_DIR)/arch/arm64/kernel/exception_context_offsets.inc
KERNEL_CRASH_SNAPSHOT_LAYOUT := _build/kernel-crash-snapshot-layout.gdb
KERNEL_DEBUG_METADATA := _build/kernel-debug-metadata.json
KERNEL_RPI5_DEBUG_METADATA := _build/kernel-debug-metadata-rpi5.json
KERNEL_RPI5_FPSIMD_S     := $(KERNEL_DIR)/arch/arm64/kernel/fpsimd_probe.S
KERNEL_RPI5_FPSIMD_O     := $(KERNEL_BUILD_DIR)/fpsimd_probe.o
KERNEL_RPI5_FPSIMD_EXTERN := $(KERNEL_DIR)/arch/arm64/kernel/fpsimd_probe_extern.tkb
# GitHub issue #500: the PMUv3 cycle-counter sampling shim. Assembly for the
# same reason fpsimd_probe.S is not .tkb -- see its own header.
KERNEL_PMU_S             := $(KERNEL_DIR)/arch/arm64/kernel/pmu.S
KERNEL_RPI5_PMU_O        := $(KERNEL_BUILD_DIR)/pmu.o
KERNEL_PMU_EXTERN        := $(KERNEL_DIR)/arch/arm64/kernel/pmu_extern.tkb
KERNEL_USER_BUILD_DIR    := $(KERNEL_DIR)/build/user
KERNEL_BUSYBOX_URL       := https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/busybox-static-1.37.0-r31.apk
KERNEL_BUSYBOX_APK       := $(KERNEL_USER_BUILD_DIR)/busybox-static.apk
KERNEL_BUSYBOX_STATIC    := $(KERNEL_USER_BUILD_DIR)/busybox-static
KERNEL_BUSYBOX_EXTRAS_URL := https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/busybox-extras-1.37.0-r31.apk
KERNEL_BUSYBOX_EXTRAS_APK := $(KERNEL_USER_BUILD_DIR)/busybox-extras.apk
KERNEL_BUSYBOX_EXTRAS     := $(KERNEL_USER_BUILD_DIR)/busybox-extras
KERNEL_MUSL_URL          := https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/musl-1.2.6-r2.apk
KERNEL_MUSL_APK          := $(KERNEL_USER_BUILD_DIR)/musl.apk
KERNEL_MUSL_LOADER       := $(KERNEL_USER_BUILD_DIR)/ld-musl-aarch64.so.1
KERNEL_EXT2_FIXTURE_DIR  := $(KERNEL_DIR)/tests/ext2
KERNEL_EXT2_IMAGE        := $(KERNEL_USER_BUILD_DIR)/ext2.img
KERNEL_RPI5_LINK_LD     := $(KERNEL_DIR)/arch/arm64/boot/link.ld
KERNEL_INIT_TEST_DRIVER_TKB := $(KERNEL_DIR)/init/test_driver.tkb
KERNEL_RPI5_MAIN_TKB    := $(KERNEL_DIR)/platform/rpi5/init.tkb
KERNEL_FREELIST_TKB     := $(KERNEL_DIR)/lib/freelist.tkb
KERNEL_SLOTMAP_TKB      := $(KERNEL_DIR)/lib/slotmap.tkb
KERNEL_REFCOUNT_SLOTMAP_TKB := $(KERNEL_DIR)/lib/refcount_slotmap.tkb
KERNEL_PAGE_TKB         := $(KERNEL_DIR)/mm/page.tkb
KERNEL_ADDRESS_SPACE_TKB := $(KERNEL_DIR)/mm/address_space.tkb
KERNEL_USER_MEMORY_TKB  := $(KERNEL_DIR)/mm/user_memory.tkb
KERNEL_PROCESS_IMAGE_TKB := $(KERNEL_DIR)/mm/process_image.tkb
KERNEL_PROCESS_TKB      := $(KERNEL_DIR)/kernel/process.tkb
KERNEL_FD_TABLE_TKB     := $(KERNEL_DIR)/kernel/fd_table.tkb
KERNEL_SYSCALL_TKB      := $(KERNEL_DIR)/kernel/syscall.tkb
KERNEL_ELF64_TKB        := $(KERNEL_DIR)/fs/elf64.tkb
KERNEL_MEMORY_BLOCK_TKB := $(KERNEL_DIR)/drivers/block/memory.tkb
KERNEL_EXT2_TKB         := $(KERNEL_DIR)/fs/ext2/ext2.tkb
KERNEL_LOG_TKB          := $(KERNEL_DIR)/printk/log.tkb
KERNEL_RPI5_PCIE_TKB    := $(KERNEL_DIR)/platform/rpi5/pcie.tkb
KERNEL_RPI5_UART_TKB    := $(KERNEL_DIR)/platform/rpi5/uart.tkb
KERNEL_RPI5_INTC_TKB    := $(KERNEL_DIR)/platform/rpi5/intc.tkb
KERNEL_RPI5_TIMER_IRQ_TKB := $(KERNEL_DIR)/platform/rpi5/timer_irq.tkb
KERNEL_RPI5_USB_XHCI_TKB := $(KERNEL_DIR)/platform/rpi5/usb_xhci.tkb
KERNEL_RPI5_MEMORY_TKB  := $(KERNEL_DIR)/platform/rpi5/memory.tkb
KERNEL_RPI5_MMU_LAYOUT_TKB := $(KERNEL_DIR)/platform/rpi5/mmu_layout.tkb
KERNEL_RPI5_GEM_TKB     := $(KERNEL_DIR)/drivers/net/rp1_gem.tkb
KERNEL_NETCONFIG_TKB    := $(KERNEL_DIR)/net/netconfig.tkb
KERNEL_ARP_TKB          := $(KERNEL_DIR)/net/arp.tkb
KERNEL_CHECKSUM_TKB     := $(KERNEL_DIR)/net/checksum.tkb
KERNEL_ICMP_TKB         := $(KERNEL_DIR)/net/icmp.tkb
KERNEL_WIRE_TKB         := $(KERNEL_DIR)/net/wire.tkb
KERNEL_TCP_TKB          := $(KERNEL_DIR)/net/tcp.tkb
KERNEL_SOCKET_CAP_TKB   := $(KERNEL_DIR)/net/socket_capability.tkb
KERNEL_RPI5_TIMER_TKB   := $(KERNEL_DIR)/arch/arm64/kernel/timer.tkb
KERNEL_RPI5_EXC_EVIDENCE_TKB := $(KERNEL_DIR)/arch/arm64/kernel/exception_evidence.tkb
KERNEL_RPI5_VECTOR_TABLE_TKB := $(KERNEL_DIR)/arch/arm64/kernel/vector_table.tkb
KERNEL_RPI5_EXC_FRAME_TKB := $(KERNEL_DIR)/arch/arm64/kernel/exception_frame.tkb
KERNEL_RPI5_USER_PAYLOAD_TKB := $(KERNEL_DIR)/arch/arm64/kernel/user_payload.tkb
KERNEL_RPI5_USER_PAYLOAD_ASM_S := $(KERNEL_DIR)/arch/arm64/kernel/user_payload_asm.S
KERNEL_RPI5_USER_PAYLOAD_TKB_O := $(KERNEL_BUILD_DIR)/user_payload_tkb.o
KERNEL_RPI5_USER_PAYLOAD_ASM_O := $(KERNEL_BUILD_DIR)/user_payload_asm.o
KERNEL_RPI5_USER_PAYLOAD_ELF := $(KERNEL_BUILD_DIR)/user_payload.elf
KERNEL_BUSY_LOOP_TKB     := $(KERNEL_DIR)/arch/arm64/kernel/busy_loop.tkb
KERNEL_BUSY_LOOP_O       := $(KERNEL_BUILD_DIR)/busy_loop.o
KERNEL_BUSY_LOOP_A_ELF   := $(KERNEL_BUILD_DIR)/busy_a.elf
KERNEL_BUSY_LOOP_B_ELF   := $(KERNEL_BUILD_DIR)/busy_b.elf
KERNEL_BUSY_LOOP_SPIN_ELF := $(KERNEL_BUILD_DIR)/busy_spin.elf
KERNEL_RPI5_MAIN_O      := $(KERNEL_BUILD_DIR)/main.o
KERNEL_RPI5_MAIN_DEBUG_O := $(KERNEL_BUILD_DIR)/main.debug.o

$(KERNEL_RPI5_MAIN_O): $(KERNEL_FD_TABLE_TKB)
KERNEL_RPI5_ELF         := $(KERNEL_BUILD_DIR)/kernel.elf
KERNEL_RPI5_DEBUG_ELF   := $(KERNEL_BUILD_DIR)/kernel-debug.elf

$(KERNEL_BUILD_DIR):
	mkdir -p $@

$(KERNEL_USER_BUILD_DIR):
	mkdir -p $@

$(KERNEL_BUSYBOX_APK): | $(KERNEL_USER_BUILD_DIR)
	curl -sSLf $(KERNEL_BUSYBOX_URL) -o $@

$(KERNEL_BUSYBOX_STATIC): $(KERNEL_BUSYBOX_APK)
	tar -xOzf $< bin/busybox.static > $@
	chmod +x $@

$(KERNEL_BUSYBOX_EXTRAS_APK): | $(KERNEL_USER_BUILD_DIR)
	curl -sSLf $(KERNEL_BUSYBOX_EXTRAS_URL) -o $@

$(KERNEL_BUSYBOX_EXTRAS): $(KERNEL_BUSYBOX_EXTRAS_APK)
	tar -xOzf $< bin/busybox-extras > $@
	chmod +x $@

$(KERNEL_MUSL_APK): | $(KERNEL_USER_BUILD_DIR)
	curl -sSLf $(KERNEL_MUSL_URL) -o $@

$(KERNEL_MUSL_LOADER): $(KERNEL_MUSL_APK)
	tar -xOzf $< lib/ld-musl-aarch64.so.1 > $@
	chmod +x $@

$(KERNEL_EXT2_IMAGE): Makefile $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $(KERNEL_EXT2_FIXTURE_DIR)/index.html $(KERNEL_EXT2_FIXTURE_DIR)/about.html $(KERNEL_EXT2_FIXTURE_DIR)/icon.png $(KERNEL_EXT2_FIXTURE_DIR)/init.sh $(KERNEL_EXT2_FIXTURE_DIR)/httpd-serve.sh $(KERNEL_EXT2_FIXTURE_DIR)/script-shebang.sh $(KERNEL_EXT2_FIXTURE_DIR)/script-interpreter-argument.sh $(KERNEL_EXT2_FIXTURE_DIR)/not-a-program $(KERNEL_EXT2_FIXTURE_DIR)/bad-interpreter.sh $(KERNEL_EXT2_FIXTURE_DIR)/crlf.sh $(KERNEL_EXT2_FIXTURE_DIR)/no-newline.sh $(KERNEL_EXT2_FIXTURE_DIR)/long-shebang.sh $(KERNEL_EXT2_FIXTURE_DIR)/inittab $(KERNEL_EXT2_FIXTURE_DIR)/large.txt $(KERNEL_RPI5_USER_PAYLOAD_ELF) $(KERNEL_BUSY_LOOP_A_ELF) $(KERNEL_BUSY_LOOP_B_ELF) $(KERNEL_BUSY_LOOP_SPIN_ELF) $(KERNEL_BUSYBOX_STATIC) $(KERNEL_BUSYBOX_EXTRAS) $(KERNEL_MUSL_LOADER) | $(KERNEL_USER_BUILD_DIR)
	rm -f $@.tmp
	truncate -s 2621440 $@.tmp
	E2FSPROGS_FAKE_TIME=1700000000 mke2fs -q -t ext2 -b 1024 -I 128 -N 1024 -O none -F -U 00000000-0000-0000-0000-000000000177 $@.tmp 2560
	debugfs -w -R 'mkdir /etc' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'mkdir /bin' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'mkdir /lib' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'mkdir /dev' $@.tmp >/dev/null 2>&1
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $@.tmp:/hello.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $@.tmp:/mutable.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/index.html $@.tmp:/index.html
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/about.html $@.tmp:/about.html
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/icon.png $@.tmp:/icon.png
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/init.sh $@.tmp:/etc/init.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/httpd-serve.sh $@.tmp:/bin/httpd-serve.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/script-shebang.sh $@.tmp:/etc/script-shebang.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/script-interpreter-argument.sh $@.tmp:/bin/script-interpreter-argument.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/not-a-program $@.tmp:/etc/not-a-program
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/bad-interpreter.sh $@.tmp:/etc/bad-interpreter.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/crlf.sh $@.tmp:/etc/crlf.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/no-newline.sh $@.tmp:/etc/no-newline.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/long-shebang.sh $@.tmp:/etc/long-shebang.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/inittab $@.tmp:/etc/inittab
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/large.txt $@.tmp:/large.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_BUSYBOX_STATIC) $@.tmp:/bin/busybox.static
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_BUSYBOX_EXTRAS) $@.tmp:/bin/busybox-extras
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_MUSL_LOADER) $@.tmp:/lib/ld-musl-aarch64.so.1
	truncate -s 0 $@.devnull.tmp
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $@.devnull.tmp $@.tmp:/dev/null
	rm -f $@.devnull.tmp
	dd if=/dev/zero bs=13311 count=1 status=none | tr '\0' Z >$@.read_indirect.tmp
	printf '\n' >>$@.read_indirect.tmp
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $@.read_indirect.tmp $@.tmp:/read_indirect.txt
	rm -f $@.read_indirect.tmp
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_RPI5_USER_PAYLOAD_ELF) $@.tmp:/bin/user_payload
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_BUSY_LOOP_A_ELF) $@.tmp:/bin/busy-a
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_BUSY_LOOP_B_ELF) $@.tmp:/bin/busy-b
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_BUSY_LOOP_SPIN_ELF) $@.tmp:/bin/spin
	debugfs -w -R 'set_inode_field /bin/busybox.static mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/busybox-extras mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /lib/ld-musl-aarch64.so.1 mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/init.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/httpd-serve.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/script-shebang.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/script-interpreter-argument.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/not-a-program mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/bad-interpreter.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/crlf.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/no-newline.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /etc/long-shebang.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/user_payload mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/busy-a mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/busy-b mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/spin mode 0100755' $@.tmp >/dev/null 2>&1
	E2FSPROGS_FAKE_TIME=1700000000 debugfs -w -R 'symlink /latest hello.txt' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/busybox' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/sh' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/cat' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/uname' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/od' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/echo' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/ls' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/ps' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox.static /bin/dmesg' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'link /bin/busybox-extras /bin/httpd' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'mkdir /many' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'expand /many' $@.tmp >/dev/null 2>&1
	for index in $$(seq -w 0 19); do \
		debugfs -w -R "link /bin/busybox.static /many/entry-$$index" $@.tmp >/dev/null 2>&1; \
	done
	debugfs -w -R 'set_inode_field /bin/busybox.static links_count 30' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /bin/busybox-extras links_count 2' $@.tmp >/dev/null 2>&1
	e2fsck -fn $@.tmp >/dev/null
	mv $@.tmp $@

$(KERNEL_RPI5_ENTRY_O): $(KERNEL_RPI5_ENTRY_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_USER_ENTRY_O): $(KERNEL_RPI5_USER_ENTRY_S) $(KERNEL_RPI5_EXC_CONTEXT) $(KERNEL_EXC_CONTEXT_OFFSETS) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_FPSIMD_O): $(KERNEL_RPI5_FPSIMD_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_PMU_O): $(KERNEL_PMU_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

# GitHub issue #241: the EL0 syscall-ABI test payload, compiled/linked
# standalone (never linked into kernel.elf itself) as a real static-PIE ELF
# and placed in the ext2 fixture image (KERNEL_EXT2_IMAGE below), loaded
# through the kernel's general-purpose ELF loader like busybox-static-pie
# rather than a custom flat-binary/embed_file mechanism. -pie
# --no-dynamic-linker (no linker script) is sufficient: this payload has no
# writable globals (enforced by check_user_payload_no_rw_globals.py below),
# so the resulting ET_DYN ELF has zero dynamic relocations -- verified
# empirically before this rule existed (see HISTORY.md's #241 entry).
$(KERNEL_RPI5_USER_PAYLOAD_TKB_O): $(KERNEL_RPI5_USER_PAYLOAD_TKB) $(TAKIBI) | $(KERNEL_BUILD_DIR)
	$(TAKIBI) $< --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --forbid-trap --reject-unused-functions --external-entry initial_user_payload --emit-depfile $@.d -o $@

$(KERNEL_RPI5_USER_PAYLOAD_ASM_O): $(KERNEL_RPI5_USER_PAYLOAD_ASM_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_USER_PAYLOAD_ELF): $(KERNEL_RPI5_USER_PAYLOAD_TKB_O) $(KERNEL_RPI5_USER_PAYLOAD_ASM_O)
	$(LLD) -pie --no-dynamic-linker -e initial_user_payload $(KERNEL_RPI5_USER_PAYLOAD_TKB_O) $(KERNEL_RPI5_USER_PAYLOAD_ASM_O) -o $@
	python3 scripts/check_user_payload_no_rw_globals.py $@

# GitHub issue #448: the CPU-bound pair /etc/inittab starts. One source and
# one object, linked twice with different ELF entry points, so /bin/busy-a
# and /bin/busy-b are separate images that need no argv parsing to know
# which of the two inittab entries they are. Same static-PIE shape and same
# no-writable-globals rule as the payload above.
$(KERNEL_BUSY_LOOP_O): $(KERNEL_BUSY_LOOP_TKB) $(TAKIBI) | $(KERNEL_BUILD_DIR)
	$(TAKIBI) $< --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --forbid-trap --reject-unused-functions --external-entry busy_loop_a --external-entry busy_loop_b --external-entry busy_loop_spin --emit-depfile $@.d -o $@

-include $(KERNEL_BUSY_LOOP_O).d

$(KERNEL_BUSY_LOOP_A_ELF): $(KERNEL_BUSY_LOOP_O)
	$(LLD) -pie --no-dynamic-linker -e busy_loop_a $< -o $@
	python3 scripts/check_user_payload_no_rw_globals.py $@

$(KERNEL_BUSY_LOOP_B_ELF): $(KERNEL_BUSY_LOOP_O)
	$(LLD) -pie --no-dynamic-linker -e busy_loop_b $< -o $@
	python3 scripts/check_user_payload_no_rw_globals.py $@

$(KERNEL_BUSY_LOOP_SPIN_ELF): $(KERNEL_BUSY_LOOP_O)
	$(LLD) -pie --no-dynamic-linker -e busy_loop_spin $< -o $@
	python3 scripts/check_user_payload_no_rw_globals.py $@

$(KERNEL_RPI5_MAIN_O): $(KERNEL_RPI5_MAIN_TKB) $(KERNEL_INIT_TEST_DRIVER_TKB) $(KERNEL_FREELIST_TKB) $(KERNEL_SLOTMAP_TKB) $(KERNEL_REFCOUNT_SLOTMAP_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_USER_MEMORY_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_TKB) $(KERNEL_RPI5_ASID_TKB) $(KERNEL_RPI5_MMU_LAYOUT_TKB) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_RPI5_BOOT_EXTERN) $(KERNEL_RPI5_FPSIMD_EXTERN) $(KERNEL_PMU_EXTERN) $(KERNEL_EXT2_IMAGE) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) $(KERNEL_RPI5_MEMORY_TKB) $(KERNEL_FDT_TKB) \
    $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_INTC_TKB) $(KERNEL_RPI5_TIMER_IRQ_TKB) $(KERNEL_RPI5_TIMER_TKB) $(KERNEL_RPI5_EXC_EVIDENCE_TKB) $(KERNEL_RPI5_VECTOR_TABLE_TKB) $(KERNEL_RPI5_EXC_FRAME_TKB) $(TAKIBI) Makefile | $(KERNEL_BUILD_DIR)
	$(TAKIBI) $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_MMU_LAYOUT_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_FDT_TKB) $< --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --frame-pointers --forbid-trap $(KERNEL_UNUSED_CHECK) --emit-depfile $@.d -o $@

# GitHub issue #306: same depfile fix as $(KERNEL_QEMU_MAIN_O)'s own, for
# this target's own hand-written prerequisite list above.
-include $(KERNEL_RPI5_MAIN_O).d

$(KERNEL_RPI5_ELF): $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_RPI5_FPSIMD_O) $(KERNEL_RPI5_PMU_O) $(KERNEL_RPI5_MAIN_O) $(KERNEL_RPI5_LINK_LD)
	$(LLD) -T $(KERNEL_RPI5_LINK_LD) $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_RPI5_FPSIMD_O) $(KERNEL_RPI5_PMU_O) $(KERNEL_RPI5_MAIN_O) -o $@
	python3 scripts/check_kernel_asm_invariants.py $@ 2
	python3 scripts/check_elf_symbol_alignment.py $@ boot_page_pool 16

# External RPi5 inspection uses the same code and load addresses as the
# ordinary image, with DWARF added only to the host ELF. Depending on main.o
# gives this second compile its complete depfile-backed source boundary.
$(KERNEL_RPI5_MAIN_DEBUG_O): $(KERNEL_RPI5_MAIN_O)
	$(TAKIBI) $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_MMU_LAYOUT_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_FDT_TKB) $(KERNEL_RPI5_MAIN_TKB) --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --frame-pointers --forbid-trap $(KERNEL_UNUSED_CHECK) -g --emit-depfile $@.d -o $@

-include $(KERNEL_RPI5_MAIN_DEBUG_O).d

$(KERNEL_RPI5_DEBUG_ELF): $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_RPI5_FPSIMD_O) $(KERNEL_RPI5_PMU_O) $(KERNEL_RPI5_MAIN_DEBUG_O) $(KERNEL_RPI5_LINK_LD)
	$(LLD) -T $(KERNEL_RPI5_LINK_LD) $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_RPI5_FPSIMD_O) $(KERNEL_RPI5_PMU_O) $(KERNEL_RPI5_MAIN_DEBUG_O) -o $@
	python3 scripts/check_kernel_asm_invariants.py $@ 2
	python3 scripts/check_elf_symbol_alignment.py $@ boot_page_pool 16

$(KERNEL_RPI5_DEBUG_METADATA): $(KERNEL_RPI5_MAIN_O) $(TAKIBI)
	@mkdir -p $(dir $@)
	$(TAKIBI) $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_MMU_LAYOUT_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_FDT_TKB) $(KERNEL_RPI5_MAIN_TKB) --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --emit-debug-metadata $@

# -- QEMU/AArch64 (GitHub issue #237) -----------------------------------------
# Reuses the same aarch64-none-elf triple as RPi5 (no --cpu passed to
# LLVM_MC for either target's assembly -- see KERNEL_RPI5_ENTRY_O's own
# rule above), but a lower --cpu for the .tkb compile, matching QEMU
# `virt`'s own -cpu cortex-a53 (examples/common_qemu/AGENTS.md).
QEMU_TARGET := aarch64-none-elf
QEMU_CPU    := cortex-a53

KERNEL_QEMU_BUILD_DIR    := $(KERNEL_DIR)/build/qemu
KERNEL_QEMU_ENTRY_O      := $(KERNEL_QEMU_BUILD_DIR)/entry.o
KERNEL_QEMU_USER_ENTRY_O := $(KERNEL_QEMU_BUILD_DIR)/user_entry.o
KERNEL_QEMU_FPSIMD_O     := $(KERNEL_QEMU_BUILD_DIR)/fpsimd_probe.o
KERNEL_QEMU_PMU_O        := $(KERNEL_QEMU_BUILD_DIR)/pmu.o
KERNEL_QEMU_MAIN_TKB     := $(KERNEL_DIR)/platform/qemu/init.tkb
KERNEL_QEMU_MAIN_O       := $(KERNEL_QEMU_BUILD_DIR)/main.o
KERNEL_QEMU_LINK_LD      := $(KERNEL_DIR)/arch/arm64/boot/link_qemu.ld
KERNEL_QEMU_ELF          := $(KERNEL_QEMU_BUILD_DIR)/kernel.elf
KERNEL_QEMU_UART_TKB     := $(KERNEL_DIR)/platform/qemu/uart.tkb
KERNEL_QEMU_INTC_TKB     := $(KERNEL_DIR)/platform/qemu/intc.tkb
KERNEL_QEMU_TIMER_IRQ_TKB := $(KERNEL_DIR)/platform/qemu/timer_irq.tkb
KERNEL_QEMU_MEMORY_TKB   := $(KERNEL_DIR)/platform/qemu/memory.tkb
KERNEL_QEMU_MMU_LAYOUT_TKB := $(KERNEL_DIR)/platform/qemu/mmu_layout.tkb
KERNEL_QEMU_VIRTIO_NET_TKB := $(KERNEL_DIR)/drivers/net/virtio_net.tkb
KERNEL_VIRTIO_BLK_TKB     := $(KERNEL_DIR)/drivers/block/virtio_blk.tkb
# A shared relay lock for concurrent kernel integration runners. It is only
# held while printing one complete line, never while a test itself runs.
KERNEL_CHECK_OUTPUT_LOCK  := $(CURDIR)/_build/kernelcheck-output.lock
KERNEL_BUILD_LOCK         := $(CURDIR)/_build/kernel-build.lock
KERNEL_BUILD_LOCK_RUN     := bash scripts/run_kernel_build_locked.sh "$(KERNEL_BUILD_LOCK)"

$(KERNEL_QEMU_BUILD_DIR):
	mkdir -p $@

KERNEL_QEMU_ENTRY_S := $(KERNEL_DIR)/arch/arm64/boot/entry_qemu.S

$(KERNEL_QEMU_ENTRY_O): $(KERNEL_QEMU_ENTRY_S) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

$(KERNEL_QEMU_USER_ENTRY_O): $(KERNEL_RPI5_USER_ENTRY_S) $(KERNEL_RPI5_EXC_CONTEXT) $(KERNEL_EXC_CONTEXT_OFFSETS) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

$(KERNEL_QEMU_FPSIMD_O): $(KERNEL_RPI5_FPSIMD_S) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

$(KERNEL_QEMU_PMU_O): $(KERNEL_PMU_S) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

# GitHub issue #237: kernel/kernel/syscall.tkb's own `use` graph
# unconditionally reaches kernel/fs/ext2/ext2.tkb -> kernel/drivers/block/
# memory.tkb (needs disk_read/disk_write) and kernel/net/{socket_capability,
# arp,icmp}.tkb -> kernel/drivers/net/rp1_gem.tkb (RPi5's real Ethernet
# driver) -- there is no QEMU storage/network driver yet (that is separate,
# planned follow-up work, see kernel/README.md), so RPi5's own pcie.tkb/
# usb_xhci.tkb/rp1_gem.tkb are linked here too, purely so the whole-program
# link resolves. kernel/platform/qemu/init.tkb never calls disk_initialize()/
# net_init(), so their real RP1/RPi5 MMIO addresses are never touched --
# this is unreachable code, not a functional dependency on RPi5 hardware.
# kernel/platform/rpi5/uart.tkb/intc.tkb/timer_irq.tkb/memory.tkb/
# mmu_layout.tkb are deliberately NOT included here: each defines a
# platform_* name kernel/platform/qemu/'s own files already define, and a
# duplicate top-level definition is a compile error by design.
$(KERNEL_QEMU_MAIN_O): $(KERNEL_QEMU_MAIN_TKB) $(KERNEL_INIT_TEST_DRIVER_TKB) $(KERNEL_FREELIST_TKB) $(KERNEL_SLOTMAP_TKB) $(KERNEL_REFCOUNT_SLOTMAP_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_USER_MEMORY_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_TKB) $(KERNEL_RPI5_ASID_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_RPI5_BOOT_EXTERN) $(KERNEL_RPI5_FPSIMD_EXTERN) $(KERNEL_PMU_EXTERN) $(KERNEL_EXT2_IMAGE) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_FDT_TKB) \
    $(KERNEL_QEMU_UART_TKB) $(KERNEL_QEMU_INTC_TKB) $(KERNEL_QEMU_TIMER_IRQ_TKB) $(KERNEL_RPI5_TIMER_TKB) $(KERNEL_RPI5_EXC_EVIDENCE_TKB) $(KERNEL_RPI5_VECTOR_TABLE_TKB) $(KERNEL_RPI5_EXC_FRAME_TKB) $(TAKIBI) Makefile | $(KERNEL_QEMU_BUILD_DIR)
	$(TAKIBI) $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $< --target $(QEMU_TARGET) --cpu $(QEMU_CPU) --frame-pointers --forbid-trap $(KERNEL_UNUSED_CHECK) --emit-depfile $@.d -o $@

# GitHub issue #306: the hand-written prerequisite list on $(KERNEL_QEMU_MAIN_O)
# above is a second, independently-maintained copy of exactly what the
# compiler's own `use` resolution (issue #55/#95 Part A) already computes
# correctly on every invocation -- it drifted once already (issue #305's
# kernel/kernel/fd_table.tkb was reachable only transitively and missing
# from that list, so Make silently kept a stale kernel.elf). --emit-depfile
# above writes the real, complete closure to $(KERNEL_QEMU_MAIN_O).d in
# gcc -MMD/-MF's Makefile-fragment format; -include-ing it here makes
# Make's own staleness check as accurate as the compiler's. `-include`
# (not `include`) so a missing .d file on a clean checkout is silently
# skipped rather than a hard error, matching this convention's standard
# clean-build bootstrap behavior.
-include $(KERNEL_QEMU_MAIN_O).d

$(KERNEL_QEMU_ELF): $(KERNEL_QEMU_ENTRY_O) $(KERNEL_QEMU_USER_ENTRY_O) $(KERNEL_QEMU_FPSIMD_O) $(KERNEL_QEMU_PMU_O) $(KERNEL_QEMU_MAIN_O) $(KERNEL_QEMU_LINK_LD)
	$(LLD) -T $(KERNEL_QEMU_LINK_LD) $(KERNEL_QEMU_ENTRY_O) $(KERNEL_QEMU_USER_ENTRY_O) $(KERNEL_QEMU_FPSIMD_O) $(KERNEL_QEMU_PMU_O) $(KERNEL_QEMU_MAIN_O) -o $@
	python3 scripts/check_kernel_asm_invariants.py $@ 1
	python3 scripts/check_elf_symbol_alignment.py $@ boot_page_pool 16

.PHONY: _kernelbuild-qemu
_kernelbuild-qemu: kernel-lib-check kernel-verify-exception-frame $(KERNEL_QEMU_ELF)

kernelbuild-qemu: build
	@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _kernelbuild-qemu

# Compiler-owned names for integer diagnostic ABI fields plus target-aware
# closed-variant layout. This is a host sidecar only: it is not linked into the
# kernel and therefore adds no production runtime data or instructions. The
# main object dependency gives this second compiler invocation the same source
# staleness boundary without adding another hand-maintained prerequisite list.
$(KERNEL_DEBUG_METADATA): $(KERNEL_QEMU_MAIN_O) $(TAKIBI)
	$(TAKIBI) $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_QEMU_MAIN_TKB) --target $(QEMU_TARGET) --cpu $(QEMU_CPU) --emit-debug-metadata $@

# Debug variant: identical inputs to $(KERNEL_QEMU_MAIN_O)/$(KERNEL_QEMU_ELF)
# above, just with -g added, so GDB would get real DWARF type info --
# struct fields, enum variant names, bool -- instead of only raw addresses.
# A separate object/ELF rather than always building kernel.elf with -g keeps
# the ordinary kernelcheck-qemu lane on its compact non-debug artifact while
# kernelcheck-qemu-debug exercises the same QEMU integration coverage with
# DWARF enabled. Distinct TCP/UDP ports and artifact directories let both
# lanes run concurrently under the default parallel make configuration.
KERNEL_QEMU_MAIN_DEBUG_O := $(KERNEL_QEMU_BUILD_DIR)/main.debug.o
KERNEL_QEMU_DEBUG_ELF    := $(KERNEL_QEMU_BUILD_DIR)/kernel-debug.elf

$(KERNEL_QEMU_MAIN_DEBUG_O): $(KERNEL_QEMU_MAIN_TKB) $(KERNEL_INIT_TEST_DRIVER_TKB) $(KERNEL_FREELIST_TKB) $(KERNEL_SLOTMAP_TKB) $(KERNEL_REFCOUNT_SLOTMAP_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_USER_MEMORY_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_TKB) $(KERNEL_RPI5_ASID_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_RPI5_BOOT_EXTERN) $(KERNEL_RPI5_FPSIMD_EXTERN) $(KERNEL_PMU_EXTERN) $(KERNEL_EXT2_IMAGE) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_FDT_TKB) \
    $(KERNEL_QEMU_UART_TKB) $(KERNEL_QEMU_INTC_TKB) $(KERNEL_QEMU_TIMER_IRQ_TKB) $(KERNEL_RPI5_TIMER_TKB) $(KERNEL_RPI5_EXC_EVIDENCE_TKB) $(KERNEL_RPI5_VECTOR_TABLE_TKB) $(KERNEL_RPI5_EXC_FRAME_TKB) $(TAKIBI) Makefile | $(KERNEL_QEMU_BUILD_DIR)
	$(TAKIBI) $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $< --target $(QEMU_TARGET) --cpu $(QEMU_CPU) --frame-pointers --forbid-trap $(KERNEL_UNUSED_CHECK) -g --emit-depfile $@.d -o $@

# GitHub issue #306: same depfile fix as $(KERNEL_QEMU_MAIN_O)'s own, for
# this target's own hand-written prerequisite list above.
-include $(KERNEL_QEMU_MAIN_DEBUG_O).d

$(KERNEL_QEMU_DEBUG_ELF): $(KERNEL_QEMU_ENTRY_O) $(KERNEL_QEMU_USER_ENTRY_O) $(KERNEL_QEMU_FPSIMD_O) $(KERNEL_QEMU_PMU_O) $(KERNEL_QEMU_MAIN_DEBUG_O) $(KERNEL_QEMU_LINK_LD)
	$(LLD) -T $(KERNEL_QEMU_LINK_LD) $(KERNEL_QEMU_ENTRY_O) $(KERNEL_QEMU_USER_ENTRY_O) $(KERNEL_QEMU_FPSIMD_O) $(KERNEL_QEMU_PMU_O) $(KERNEL_QEMU_MAIN_DEBUG_O) -o $@
	python3 scripts/check_kernel_asm_invariants.py $@ 1
	python3 scripts/check_elf_symbol_alignment.py $@ boot_page_pool 16

.PHONY: _kernelbuild-qemu-debug
_kernelbuild-qemu-debug: kernel-lib-check kernel-verify-exception-frame $(KERNEL_QEMU_DEBUG_ELF) $(KERNEL_DEBUG_METADATA)

kernelbuild-qemu-debug: build
	@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _kernelbuild-qemu-debug

# Pure source-text check (issues #207/#242, see HISTORY.md's 2026-08-07
# entry) -- no build product needed, so it runs independent of and before
# the actual compile below rather than being tied to a .o/.elf rule.
.PHONY: kernel-lib-check
kernel-lib-check:
	python3 scripts/check_kernel_lib_limitations_header.py $(KERNEL_DIR)/lib $(KERNEL_DIR)/kernel $(KERNEL_DIR)/net
	python3 scripts/check_diagnostic_event_ids.py
	python3 scripts/check_flag_guarded_fields.py $(KERNEL_DIR)
	python3 scripts/check_execution_model_coverage.py
	python3 scripts/check_lock_discipline.py
	python3 scripts/check_liveness_proof_escapes.py
	python3 scripts/check_invariant_lines_unviewed.py
	python3 scripts/check_dead_slot_peek_not_retained.py

# Generate AArch64 exception-frame offset constants from the struct
# definition (GitHub issue #286). This is a REAL file-based Make rule (not
# .PHONY) so parallel builds and `user_entry.o`'s own prerequisite on this
# file both see a correct dependency graph -- a stale or missing generated
# file is regenerated before anything tries to assemble against it, and a
# rebuild is skipped entirely when the struct hasn't changed.
#
# 2026-08-13 follow-up: this used to shell out to scripts/gen_exception_frame.py,
# a Python script that independently re-parsed exception_frame.tkb's struct
# syntax (via regex) and reimplemented the same packed-layout algorithm
# lib/llvm_gen.ml's exception_frame_offsets already computes for exception_
# entry/exception_restore codegen. That duplication caused a real bug (a
# q0-specific alignment step this Python reimplementation added but the
# compiler's own algorithm never had -- see HISTORY.md's 2026-08-13 entry).
# The compiler's `--emit-exception-frame-offsets <StructName>` flag now
# dumps the SAME computation exception_entry/exception_restore already use
# internally, as GAS `.equ` constants, so there is exactly one
# implementation of "how to lay out this struct" left, not two kept in
# sync by hand. This still only ever writes offset constants, never
# hand-written assembly macro bodies (those remain the ordinary,
# git-tracked exception_context.inc) -- so there is still no placeholder/
# fallback path that could silently emit broken assembly.
$(KERNEL_EXC_CONTEXT_OFFSETS): $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_QEMU_MAIN_TKB) $(KERNEL_RPI5_EXC_FRAME_TKB) $(KERNEL_EXT2_IMAGE) $(TAKIBI)
	$(TAKIBI) $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_QEMU_MAIN_TKB) --target $(QEMU_TARGET) --cpu $(QEMU_CPU) --emit-exception-frame-offsets ExceptionFrame --emit-depfile $@.d -o $@

# GitHub issue #306: same depfile fix as $(KERNEL_QEMU_MAIN_O)'s own, for
# this target's own hand-written prerequisite list above.
-include $(KERNEL_EXC_CONTEXT_OFFSETS).d

$(KERNEL_CRASH_SNAPSHOT_LAYOUT): $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_QEMU_MAIN_TKB) $(KERNEL_EXT2_IMAGE) $(TAKIBI)
	@mkdir -p $(dir $@)
	$(TAKIBI) $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_FDT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_VIRTIO_BLK_TKB) $(KERNEL_QEMU_MAIN_TKB) --target $(QEMU_TARGET) --cpu $(QEMU_CPU) --emit-struct-layout CrashSnapshot --emit-depfile $@.d -o $@

# GitHub issue #306, hit again live while adding CrashSnapshot fields
# (issue #294): this target's own hand-written prerequisite list above
# does not include kernel/arch/arm64/kernel/exception_evidence.tkb --
# the file CrashSnapshot is actually DEFINED in -- so a struct-only
# change there left a stale layout .gdb file in place, and
# kernelcheck-oops-qemu's GDB readback failed against the new binary's
# real (shifted) field offsets. Same fix as #306's KERNEL_QEMU_MAIN_O.
-include $(KERNEL_CRASH_SNAPSHOT_LAYOUT).d

## Verify that exception-frame offsets are consistent and the hand-written
## SAVE/RESTORE macros contain real assembly, not placeholder/empty bodies.
.PHONY: kernel-verify-exception-frame
kernel-verify-exception-frame: $(KERNEL_EXC_CONTEXT_OFFSETS)
	@python3 scripts/verify_exception_frame.py

.PHONY: _kernelbuild-rpi5
_kernelbuild-rpi5: kernel-lib-check kernel-verify-exception-frame $(KERNEL_RPI5_ELF)

kernelbuild-rpi5: build
	@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _kernelbuild-rpi5

.PHONY: _kernelbuild-rpi5-debug kernelbuild-rpi5-debug
_kernelbuild-rpi5-debug: kernel-lib-check kernel-verify-exception-frame \
	$(KERNEL_RPI5_DEBUG_ELF) $(KERNEL_RPI5_DEBUG_METADATA)

kernelbuild-rpi5-debug: build
	@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _kernelbuild-rpi5-debug

## kernel/MEMORY_MAP.md's checkable rows against both linked kernels.  Here
## rather than in a check lane because it needs both ELFs and nothing else,
## and because a memory map that is only verified when someone runs the
## slow suite is a memory map that is wrong when someone trusts it.
.PHONY: kernel-memory-map-check
kernel-memory-map-check: _kernelbuild-rpi5 _kernelbuild-qemu
	python3 scripts/check_kernel_memory_map.py

.PHONY: _kernelbuild
_kernelbuild: _kernelbuild-rpi5 _kernelbuild-qemu kernel-memory-map-check

kernelbuild: build
	@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _kernelbuild

# Every integration lane reads one or more shared kernel/build artifacts.
# Build their union once under the cross-invocation lock, then release it
# before the long QEMU/RPi5 runs. This preserves the ordinary lane fan-out
# while preventing another Make process from interleaving object writes.
.PHONY: _kernelbuild-check kernelbuild-check
_kernelbuild-check: _kernelbuild _kernelbuild-qemu-debug _kernelbuild-rpi5-debug \
	kernel-debug-layout-check \
	$(KERNEL_CRASH_SNAPSHOT_LAYOUT)

kernelbuild-check: build
	@$(KERNEL_BUILD_LOCK_RUN) $(MAKE) _kernelbuild-check

.PHONY: kernel-debug-layout-check
kernel-debug-layout-check: _kernelbuild _kernelbuild-qemu-debug
	python3 scripts/check_kernel_memory_map.py --debug

## trustedbasecheck: repeatable inventory of the maintained kernel's checked
## source coverage and explicit trusted boundaries. Reads build-produced
## depfiles, so it depends on kernelbuild rather than guessing from the tree.
.PHONY: trustedbasecheck
trustedbasecheck: kernelbuild
	python3 scripts/measure_trusted_base.py

## RPI5_SERIAL_DEV: empty by default, resolved at runtime by
## scripts/rpi5_uart_dev.sh (which picks the ttyACM device out by its
## /dev/serial/by-id label). Override only if the auto-detected device is
## wrong.
RPI5_SERIAL_DEV ?=
# The connected Debug Probe/board has been validated at 30 MHz SWD. Keep this
# override at the maintained kernel target boundary so historical examples'
# hardware lanes retain their existing default; use RPI5_SWD_SPEED=1000 when
# a different probe/cable needs the conservative speed.
RPI5_SWD_SPEED ?= 30000

# A compile is not an integration pass. This deliberately fails until the
# first observable RPi5 EL1 milestone connects its real-hardware harness.
kernelcheck-rpi5: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env RPI5_SERIAL_DEV="$(RPI5_SERIAL_DEV)" RPI5_SWD_SPEED="$(RPI5_SWD_SPEED)" bash scripts/run_kernel_hwtest_rpi5.sh
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env RPI5_SERIAL_DEV="$(RPI5_SERIAL_DEV)" RPI5_SWD_SPEED="$(RPI5_SWD_SPEED)" bash scripts/run_kernel_ddb_rpi5_softwaretest.sh

## Focused physical-board check for the deliberate software BRK. Unlike the
## ordinary RPi5 lane's external UART BREAK, this stops at a deterministic EL1
## checkpoint and must walk compiler-generated frames to the boot-assembly
## boundary before resuming the same shell.
kernelcheck-ddb-rpi5-software: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env RPI5_SERIAL_DEV="$(RPI5_SERIAL_DEV)" RPI5_SWD_SPEED="$(RPI5_SWD_SPEED)" bash scripts/run_kernel_ddb_rpi5_softwaretest.sh

## PROFILE_ARTIFACTS: space-separated saved busy-pair JSON artifacts.
## PROFILE_CHART: output SVG path for their revision comparison.
PROFILE_ARTIFACTS ?=
PROFILE_CHART ?= _build/kernel-workload-comparison.svg
.PHONY: profile-kernel-workload-chart
profile-kernel-workload-chart:
	@test -n "$(PROFILE_ARTIFACTS)" || { echo "error: set PROFILE_ARTIFACTS to one or more saved JSON artifacts" >&2; exit 1; }
	python3 scripts/profile_kernel_workload.py chart --output "$(PROFILE_CHART)" $(PROFILE_ARTIFACTS)

## Each long full-system boot already validates the complete ash transcript.
## Keep the ash-only targets below for focused debugging, but do not run their
## duplicate boots from the aggregate checks.  The ordinary PTY smoke covers
## a distinct host terminal path and remains behind the long boot: even after
## removing both duplicate ash boots, running it in the full QEMU fan-out can
## leave its QMP interaction stalled under host load.  Everything remains in
## one dependency graph, so $(TAKIBI) is still built exactly once (see the
## allcheck comment below).  The timing-sensitive DDB checks deliberately
## remain sequential within kernelcheck-ddb-qemu.
## kernelcheck-repeat: run a lane N times and report the failure RATE
## (make kernelcheck-repeat N=20 LANE=kernelcheck-qemu)
##
## An intermittent failure was declared fixed on a clean run of eight --
## twice, wrongly -- because nobody computed that a clean eight against a
## one-in-six event happens 23% of the time. This prints the observed rate
## and how many clean runs the claim would actually need, so the number is
## in front of whoever is about to say "fixed".
##
## Every sample keeps its own artifact directory, and PORT_BASE separates
## concurrent runs: two agents in different worktrees pick different bases
## and stop colliding on the fixed lane ports.
PORT_BASE ?=
REPEAT_MODE ?= measure
N ?= 10
LANE ?= kernelcheck-qemu
kernelcheck-repeat:
	@bash scripts/repeat_kernel_lane.sh --mode "$(REPEAT_MODE)" \
	    $(if $(PORT_BASE),--port-base "$(PORT_BASE)",) \
	    "$(N)" $(MAKE) $(LANE)

kernelcheck-qemu: kernelcheck-qemu-main kernelcheck-qemu-fdt-multibank

kernelcheck-qemu-main: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash scripts/run_kernel_qemutest.sh
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" python3 scripts/run_kernel_shell_qemu_smoketest.py

kernelcheck-qemu-fdt-multibank: kernelbuild-check
	@python3 kernel/tests/check_fdt_multibank_qemu.py

kernelcheck-qemu-ash: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash scripts/run_kernel_ash_qemutest.sh

## Exercise make -> /dev/tty -> miniterm -> ash in a pseudo-terminal.  This
## complements the UART protocol tests above by covering the interactive entry
## point and its host-side terminal file descriptors.  Its runner omits the
## NIC: the full boot immediately before it already covers virtio-net and HTTP,
## while user-mode networking otherwise makes this terminal-only check spend
## about 15 seconds in the kernel's network retry fixture.
kernelcheck-shell-qemu: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" python3 scripts/run_kernel_shell_qemu_smoketest.py

kernelcheck-qemu-debug: kernelcheck-qemu-debug-main

kernelcheck-qemu-debug-main: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_ELF="$(KERNEL_QEMU_DEBUG_ELF)" KERNEL_QEMU_LABEL=qemu-debug KERNEL_QEMU_EXPECTED_VIEW_DIR="$(CURDIR)/kernel/tests/qemu-debug/views" KERNEL_QEMU_HWTEST_ARTIFACT_DIR="$(CURDIR)/_build/kernel-hwtest-qemu-debug" KERNEL_QEMU_SERIAL_PORT=18683 KERNEL_QEMU_NETDEV_LOCAL_PORT=18684 KERNEL_QEMU_NETDEV_REMOTE_PORT=18685 bash scripts/run_kernel_qemutest.sh

## Preserve every boot separately when chasing a probabilistic failure.
## This is intentionally not part of allcheck: repetition is a diagnostic
## sampling tool, not additional product coverage. Override the default with
## KERNEL_QEMU_DEBUG_REPEAT=<count>.
KERNEL_QEMU_DEBUG_REPEAT ?= 5
kernelcheck-qemu-debug-repeat: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_DEBUG_REPEAT="$(KERNEL_QEMU_DEBUG_REPEAT)" bash scripts/repeat_kernel_qemu_debug_check.sh

kernelcheck-qemu-debug-ash: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_ASH_ELF="$(KERNEL_QEMU_DEBUG_ELF)" KERNEL_QEMU_ASH_LABEL=qemu-debug KERNEL_QEMU_ASH_ARTIFACT_DIR="$(CURDIR)/_build/kernel-hwtest-qemu-debug-ash" KERNEL_QEMU_ASH_SERIAL_PORT=18686 KERNEL_QEMU_ASH_NETDEV_LOCAL_PORT=18687 KERNEL_QEMU_ASH_NETDEV_REMOTE_PORT=18688 bash scripts/run_kernel_ash_qemutest.sh

## Focused terminal-path check.  This is deliberately separate from the
## ordinary QEMU suite because its expected result is a terminal fail-stop
## serving the read-only UART crash console.
kernelcheck-oops-qemu: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash scripts/run_kernel_oops_qemutest.sh
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_OOPS_MODE=data_abort_write KERNEL_QEMU_OOPS_GDB_PORT=18693 KERNEL_QEMU_OOPS_SERIAL_PORT=18694 KERNEL_QEMU_OOPS_ARTIFACT_DIR="$(CURDIR)/_build/kernel-oops-qemu-data-abort" bash scripts/run_kernel_oops_qemutest.sh
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_OOPS_MODE=child_exec KERNEL_QEMU_OOPS_GDB_PORT=18695 KERNEL_QEMU_OOPS_SERIAL_PORT=18696 KERNEL_QEMU_OOPS_ARTIFACT_DIR="$(CURDIR)/_build/kernel-oops-qemu-child-exec" bash scripts/run_kernel_oops_qemutest.sh

## A real PL011 BREAK enters the resumable, interrupt-safe DDB subset. The
## check inspects state and guarded kernel memory, then proves `continue`
## resumes ordinary boot.
kernelcheck-ddb-qemu: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_DDB_ELF="$(KERNEL_QEMU_DEBUG_ELF)" bash scripts/run_kernel_ddb_qemutest.sh
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" env KERNEL_QEMU_DDB_ELF="$(KERNEL_QEMU_DEBUG_ELF)" KERNEL_QEMU_DDB_BREAK_SOURCE=software KERNEL_QEMU_DDB_SERIAL_PORT=18704 KERNEL_QEMU_DDB_QMP_PORT=18705 KERNEL_QEMU_DDB_GDB_PORT=18706 KERNEL_QEMU_DDB_ARTIFACT_DIR="$(CURDIR)/_build/kernel-ddb-qemu-software" bash scripts/run_kernel_ddb_qemutest.sh

## Issue #377 regression: the exception-entry stack guard.  Deliberately
## separate from the ordinary QEMU suite for the same reason as
## kernelcheck-oops-qemu -- its expected result is a parked fail-stop.  GDB
## moves SP to just above the boot stack's bottom at a real IRQ entry and
## sends PC back to the entry symbol; the generated single-bit test then
## fires on the ordinary path, with nothing about the kernel modified.
kernelcheck-stack-overflow-qemu: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash scripts/run_kernel_stack_overflow_qemutest.sh

## Issue #289 negative-path regression: GDB pokes the exec-commit lifecycle
## checkpoint's own one-shot guard so its print is skipped while the real
## exec-commit logic runs untouched, proving the interactive-HTTPd harness's
## own last-completed/next-expected diagnosis names the right gap -- see
## scripts/run_kernel_qemutest_lifecycle_gap.sh for the full rationale. It
## uses the DWARF-enabled ELF so GDB has Takibi source and type information.
kernelcheck-lifecycle-gap-qemu: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash scripts/run_kernel_qemutest_lifecycle_gap.sh

## Issue #414: the rollback chain inside scheduled_process_alloc has never
## run -- the arrays it replaced could not fail, so every "give back what
## was already acquired" path is a failure mode the pooling introduced and
## nothing exercised. GDB empties the page allocator's free list for the
## duration of ONE acquisition (address_space_allocate_root, past the
## record and the stack run) and puts it back at the exhaustion log call
## the failing arm makes before it rolls anything back. The verdict is the
## kernel's own end-of-run accounting: the refusal was reported, and every
## pooled record and page came back. Uses the DWARF-enabled ELF.
kernelcheck-alloc-rollback-qemu: kernelbuild-check
	@bash scripts/run_line_locked.sh "$(KERNEL_CHECK_OUTPUT_LOCK)" bash scripts/run_kernel_alloc_rollback_qemutest.sh

## kernelsh-qemu: boot the standalone kernel, attach the current terminal to
## its TCP-backed UART console, and forward localhost:18080 to guest httpd.
## Exit miniterm with Ctrl-].
kernelsh-qemu: kernelbuild-qemu
	@bash scripts/run_kernel_shell_qemu.sh

## kernelsh-rpi5: inject the standalone kernel over SWD and attach the current
## terminal to the RPi5 Debug Probe UART. Requires python3-serial (the Debian
## package is python3-serial); exit miniterm with Ctrl-].
kernelsh-rpi5: kernelbuild-rpi5
	@RPI5_SERIAL_DEV="$(RPI5_SERIAL_DEV)" RPI5_SWD_SPEED="$(RPI5_SWD_SPEED)" bash scripts/run_kernel_shell_rpi5.sh

## lease-status: report which session holds each shared resource, and since when
lease-status:
	@bash -c '. scripts/resource_lease.sh; resource_lease_status'

KERNELCHECK_LANES := kernelcheck-qemu kernelcheck-qemu-debug \
	kernelcheck-oops-qemu kernelcheck-ddb-qemu \
	kernelcheck-stack-overflow-qemu kernelcheck-lifecycle-gap-qemu \
	kernelcheck-alloc-rollback-qemu kernelcheck-rpi5

kernelcheck: $(KERNELCHECK_LANES)

## allcheck: run every check this Makefile knows about -- langcheck, test,
## linuxcheck, kernelcheck -- so a single command surfaces a failure
## anywhere in the compiler/kernel/linux_user surface. kernelcheck talks to
## real RPi5 hardware (RPI5_SERIAL_DEV) same as it always has; nothing about
## bundling it into allcheck changes that. Parallel by default like
## everything else in this file (MAKEFLAGS -j at the top); safe because
## every one of these four ultimately funnels through the single shared
## $(TAKIBI) prerequisite, which Make's own dependency tracking runs (and
## therefore serializes `dune build`) at most once regardless of how many
## targets reach it concurrently -- see "Known dune footgun" above for why
## that invariant matters and must not be bypassed by a future change. In
## particular, do NOT split this single `$(MAKE) langcheck test linuxcheck
## kernelcheck` call into several separate `$(MAKE) <target>` invocations
## (e.g. one recursive make per lane) to add output locking -- that was
## tried (issue #295 session) and each lane became an independent make
## process with its own view of $(TAKIBI), so up to four genuinely
## concurrent `dune build` invocations raced on dune's build-directory
## lock file and hung (multiple `dune build` processes stuck at 0% CPU
## for 15-29+ minutes, twice, both requiring a manual kill) -- exactly the
## footgun this comment warns about, just one level removed. langcheck/
## test/linuxcheck/kernelcheck's own recipes now route their OWN output
## through the same line lock (KERNEL_CHECK_OUTPUT_LOCK, scripts/
## run_line_locked.sh) that kernelcheck's sub-targets already used, fixing
## the original interleaved/garbled-output report without spawning any
## new recursive make process or touching this target's single `$(MAKE)`
## call.
.PHONY: allcheck
allcheck:
	@status=0; . scripts/resource_lease.sh; \
	resource_lease_run_suite allcheck \
		$(MAKE) langcheck test linuxcheck kernelcheck || status=$$?; \
	if [ $$status -eq 0 ]; then \
		echo "PASS allcheck: langcheck test linuxcheck $(KERNELCHECK_LANES)"; \
	else \
		echo "FAIL allcheck: one or more checks failed (see the lane output above)" >&2; \
		exit $$status; \
	fi

# allcheck's recursive Make invocation intentionally fans out the independent
# lanes in parallel. It is wrapped in one shell recipe so a failing lane still
# produces a final, unmistakable allcheck failure receipt after Make has
# waited for the other scheduled jobs.
ifneq (,$(filter allcheck,$(MAKECMDGOALS)))
$(info [allcheck] includes: langcheck, compiler unit tests, linux_user, QEMU integration, QEMU debug integration, QEMU oops, QEMU DDB, QEMU stack overflow, QEMU lifecycle gap, QEMU allocation rollback, and RPi5 integration)
endif

## allbuild: a fast, no-execution/no-hardware smoke gate across all three
## source trees (kernel/, linux_user/, examples/) -- COMPILES everything
## (type-checks, since this compiler has no separate type-check-only mode;
## codegen/link still runs, but nothing is ever executed or flashed) without
## the QEMU boot/UART-diff/hardware time allcheck's full lanes spend. Exists
## specifically to catch a new lib/type_inf.ml or lib/llvm_gen.ml check that
## is too strict (or too loose) somewhere allcheck's own kernel-only build
## step would never reach -- kernel/ does not exercise every generic
## instantiation or code shape the OTHER two trees do (e.g. kernel/ never
## instantiates kernel/lib/freelist.tkb's Freelist(T) with T=usize; only
## linux_user/freelist_generic/freelist_generic.tkb does), so a compiler
## change that only ran `make kernelbuild` before landing can still break
## `make allcheck` elsewhere. Run this after any lib/*.ml change, before
## considering it done.
.PHONY: allbuild
allbuild:
	@status=0; $(MAKE) langcheck test linuxbuild kernelbuild || status=$$?; \
	$(MAKE) -f examples/Makefile allcheck-build || status=$$?; \
	if [ $$status -eq 0 ]; then \
		echo "PASS allbuild: langcheck + compiler unit + linux_user + kernel (RPi5+QEMU) + every examples/ target, all build-only"; \
	else \
		echo "FAIL allbuild: one or more lanes failed to build (see the lane output above)" >&2; \
		exit $$status; \
	fi

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts, kernel/ link outputs, and linux_user/
## build outputs. Does not touch examples/ -- use `make -f examples/Makefile
## clean` for that.
clean:
	dune clean
	find kernel/build -type f \( -name '*.o' -o -name '*.elf' -o -name '*.bin' -o -name '*.img' -o -name '*.d' \) -delete 2>/dev/null || true
	rm -f kernel/arch/arm64/kernel/exception_context_offsets.inc kernel/arch/arm64/kernel/exception_context_offsets.inc.d
	rm -rf $(LINUX_USER_BUILD_DIR)
	find $(LINUX_USER_DIR) -type f \( -name '*.o' -o -name '*.exe' \) -delete 2>/dev/null || true
