# -- Configuration ------------------------------------------------------------
# Parallel by default, overridable per-invocation: `make -j1 kernelcheck`
# forces serial execution back, e.g. when a build error needs to be read one
# recipe at a time. Deliberately not paired with -Otarget: that buffers each
# recipe's output until the recipe finishes, so progress isn't visible
# line-by-line while jobs are still running -- worse for watching a long
# build than the occasional interleaved line.
MAKEFLAGS += -j$(shell nproc)

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
.PHONY: build test kernelbuild kernelcheck kernelbuild-rpi5 kernelbuild-qemu kernelcheck-rpi5 kernelcheck-qemu langcheck linuxbuild linuxcheck clean FORCE

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

$(TAKIBI): FORCE
	dune build

## test: run unit tests
# Depends on `build` (not just order-only) so "dune test" never runs
# concurrently with "dune build": dune's build-directory lock file is not
# safe against two concurrent dune invocations racing to create it
# (observed: "Unexpected contents of build directory global lock file").
test: build
	dune test

## langcheck: verify that all source files contain only ASCII characters.
## Repo-wide (kernel/, examples/, the compiler itself), so this is the one
## canonical implementation; examples/Makefile's own `langcheck` target
## just forwards here via `$(MAKE) -C .. langcheck`.
langcheck:
	@echo "Checking for non-ASCII characters in source files..."
	@if LC_ALL=C grep -rnP '[^\x00-\x7F]' --exclude-dir=_build \
	       --include="*.ml" --include="*.mll" --include="*.mly" \
	       --include="*.tkb" --include="*.S" --include="*.md" \
	       --include="*.sh" --include="*.ld" --include="*.py" \
	       . Makefile examples/Makefile 2>/dev/null; then \
	    echo "ERROR: non-ASCII characters found (see above)"; exit 1; \
	fi
	@echo "OK: all files are ASCII-clean"

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
LINUX_USER_BUILD_DIR     := $(LINUX_USER_DIR)/build
COMMON_LINUX_DIR         := $(LINUX_USER_DIR)/common_linux
COMMON_LINUX_STARTUP_S   := $(COMMON_LINUX_DIR)/startup.S
COMMON_LINUX_STARTUP_O   := $(LINUX_USER_BUILD_DIR)/startup.o
COMMON_LINUX_SYSCALL_S   := $(COMMON_LINUX_DIR)/syscall.S
COMMON_LINUX_SYSCALL_O   := $(LINUX_USER_BUILD_DIR)/syscall.o
COMMON_LINUX_UART        := $(COMMON_LINUX_DIR)/uart.tkb
COMMON_LINUX_PRINT       := $(COMMON_LINUX_DIR)/print.tkb
COMMON_LINUX_PRINT_BASE  := $(LINUX_USER_DIR)/common/print.tkb $(LINUX_USER_DIR)/common/runtime.tkb
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
                             hello print_int print_hex print_ptr mem array struct struct_refined \
                             nonexhaustive refined narrow enum align packed struct_align const_global \
                             sizeof_offsetof int64 bitops indexed_view tcp_conn_view \
                             affine_escape_via_index align_ptr_proof linear_obligation tuple_pair \
                             field_lease match_int_lit \
                             callstack ringbuf crc8 djb2 slice foreach for loop fizzbuzz fibonacci \
                             bubblesort inet_checksum ip_parse tcp_parse wire_endian
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

# Freelist redesign follow-up: --forbid-trap now PASSES for the four
# targets below -- but this is NOT a safety improvement over the earlier
# #213/#215-tracked trap sites, and must not be read as one.
# freelist.tkb's FreelistCore(N) now embeds its bookkeeping array
# (next_free: [usize; N]) directly as a struct field; reading that field
# decays to a raw, UNCHECKED pointer (lib/type_inf.ml's FieldGet TArray
# case, lib/llvm_gen.ml's matching TypeArray case -- confirmed, and
# tracked as a concrete instance of GitHub issue #15 "Safe pointer").
# Unchecked pointer arithmetic never emits a bounds-check trap at all, so
# --forbid-trap has nothing left to reject here -- the checker stopped
# LOOKING at this code, it did not prove it safe. See freelist.tkb's own
# per-function #15 comments (freelist_core_init/_insert/_remove) for the
# precise accepted-risk sites. `data` (the payload storage) deliberately
# stayed a caller-owned slice specifically to keep REAL checked/elidable
# indexing (see freelist.tkb's own header comment) -- only the internal
# bookkeeping array traded that away, by deliberate choice, to avoid
# forcing collection-library callers to declare index storage themselves.
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
$(LINUX_USER_DIR)/growable_pool/growable_pool_exe.o: kernel/lib/freelist.tkb kernel/lib/slotmap.tkb $(LINUX_USER_DIR)/growable_pool/growable_pool_core.tkb $(LINUX_USER_DIR)/growable_pool/fake_page_provider.tkb
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
# surface here to vary by test.
$(LINUX_USER_DIR)/%_exe.o: $(LINUX_USER_DIR)/%.tkb $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $(COMMON_LINUX_PRINT_BASE) $(TAKIBI)
	$(TAKIBI) $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $< --target $(LINUX_AMD64_TARGET) -o $@ --forbid-trap

$(LINUX_USER_DIR)/%.exe: $(LINUX_USER_DIR)/%_exe.o $(COMMON_LINUX_STARTUP_O) $(COMMON_LINUX_SYSCALL_O)
	$(LLD) -static -nostdlib -e _start $^ -o $@

## linuxbuild: build linux_user/'s host-native Linux/AMD64 tests (no libc, _start -> app_main)
linuxbuild: $(LINUX_USER_BINS)

## linuxcheck: run linux_user/'s tests natively and diff stdout against each .expected
linuxcheck: linuxbuild
	@fail=0; \
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
	exit $$fail

# -- Raspberry Pi 5 (BCM2712) -------------------------------------------------
RPI5_TARGET := aarch64-none-elf
RPI5_CPU    := cortex-a76

# -- Standalone kernel tree (GitHub issue #177) -------------------------------
KERNEL_DIR              := kernel
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
KERNEL_RPI5_FPSIMD_S     := $(KERNEL_DIR)/arch/arm64/kernel/fpsimd_probe.S
KERNEL_RPI5_FPSIMD_O     := $(KERNEL_BUILD_DIR)/fpsimd_probe.o
KERNEL_RPI5_FPSIMD_EXTERN := $(KERNEL_DIR)/arch/arm64/kernel/fpsimd_probe_extern.tkb
KERNEL_USER_BUILD_DIR    := $(KERNEL_DIR)/build/user
KERNEL_BUSYBOX_URL       := https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/busybox-static-1.37.0-r31.apk
KERNEL_BUSYBOX_APK       := $(KERNEL_USER_BUILD_DIR)/busybox-static.apk
KERNEL_BUSYBOX_STATIC    := $(KERNEL_USER_BUILD_DIR)/busybox-static
KERNEL_HTTPD_URL         := https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/busybox-extras-1.37.0-r31.apk
KERNEL_HTTPD_APK         := $(KERNEL_USER_BUILD_DIR)/busybox-extras.apk
KERNEL_HTTPD             := $(KERNEL_USER_BUILD_DIR)/busybox-httpd
KERNEL_MUSL_URL          := https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/musl-1.2.6-r2.apk
KERNEL_MUSL_APK          := $(KERNEL_USER_BUILD_DIR)/musl.apk
KERNEL_MUSL_LOADER       := $(KERNEL_USER_BUILD_DIR)/ld-musl-aarch64.so.1
KERNEL_INITRAMFS_CPIO    := $(KERNEL_USER_BUILD_DIR)/initramfs.cpio
KERNEL_EXT2_FIXTURE_DIR  := $(KERNEL_DIR)/tests/ext2
KERNEL_EXT2_IMAGE        := $(KERNEL_USER_BUILD_DIR)/ext2.img
KERNEL_RPI5_LINK_LD     := $(KERNEL_DIR)/arch/arm64/boot/link.ld
KERNEL_RPI5_MAIN_TKB    := $(KERNEL_DIR)/init/main.tkb
KERNEL_FREELIST_TKB     := $(KERNEL_DIR)/lib/freelist.tkb
KERNEL_SLOTMAP_TKB      := $(KERNEL_DIR)/lib/slotmap.tkb
KERNEL_REFCOUNT_SLOTMAP_TKB := $(KERNEL_DIR)/lib/refcount_slotmap.tkb
KERNEL_GROWABLE_POOL_TKB := $(KERNEL_DIR)/lib/growable_pool.tkb
KERNEL_PAGE_TKB         := $(KERNEL_DIR)/mm/page.tkb
KERNEL_ADDRESS_SPACE_TKB := $(KERNEL_DIR)/mm/address_space.tkb
KERNEL_USER_MEMORY_TKB  := $(KERNEL_DIR)/mm/user_memory.tkb
KERNEL_PROCESS_IMAGE_TKB := $(KERNEL_DIR)/mm/process_image.tkb
KERNEL_PROCESS_TKB      := $(KERNEL_DIR)/kernel/process.tkb
KERNEL_FD_TABLE_TKB     := $(KERNEL_DIR)/kernel/fd_table.tkb
KERNEL_SYSCALL_TKB      := $(KERNEL_DIR)/kernel/syscall.tkb
KERNEL_INITRAMFS_TKB    := $(KERNEL_DIR)/fs/initramfs.tkb
KERNEL_ELF64_TKB        := $(KERNEL_DIR)/fs/elf64.tkb
KERNEL_MEMORY_BLOCK_TKB := $(KERNEL_DIR)/drivers/block/memory.tkb
KERNEL_EXT2_TKB         := $(KERNEL_DIR)/fs/ext2/ext2.tkb
KERNEL_LOG_TKB          := $(KERNEL_DIR)/printk/log.tkb
KERNEL_RPI5_PCIE_TKB    := $(KERNEL_DIR)/platform/rpi5/pcie.tkb
KERNEL_RPI5_UART_TKB    := $(KERNEL_DIR)/platform/rpi5/uart.tkb
KERNEL_RPI5_INTC_TKB    := $(KERNEL_DIR)/platform/rpi5/intc.tkb
KERNEL_RPI5_TIMER_IRQ_TKB := $(KERNEL_DIR)/platform/rpi5/timer_irq.tkb
KERNEL_RPI5_USB_XHCI_TKB := $(KERNEL_DIR)/platform/rpi5/usb_xhci.tkb
KERNEL_RPI5_MAILBOX_TKB := $(KERNEL_DIR)/platform/rpi5/mailbox.tkb
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
KERNEL_RPI5_MAIN_O      := $(KERNEL_BUILD_DIR)/main.o

$(KERNEL_RPI5_MAIN_O): $(KERNEL_FD_TABLE_TKB)
KERNEL_RPI5_ELF         := $(KERNEL_BUILD_DIR)/kernel.elf

$(KERNEL_BUILD_DIR):
	mkdir -p $@

$(KERNEL_USER_BUILD_DIR):
	mkdir -p $@

$(KERNEL_BUSYBOX_APK): | $(KERNEL_USER_BUILD_DIR)
	curl -sSLf $(KERNEL_BUSYBOX_URL) -o $@

$(KERNEL_BUSYBOX_STATIC): $(KERNEL_BUSYBOX_APK)
	tar -xOzf $< bin/busybox.static > $@
	chmod +x $@

$(KERNEL_HTTPD_APK): | $(KERNEL_USER_BUILD_DIR)
	curl -sSLf $(KERNEL_HTTPD_URL) -o $@

$(KERNEL_HTTPD): $(KERNEL_HTTPD_APK)
	tar -xOzf $< bin/busybox-extras > $@
	chmod +x $@

$(KERNEL_MUSL_APK): | $(KERNEL_USER_BUILD_DIR)
	curl -sSLf $(KERNEL_MUSL_URL) -o $@

$(KERNEL_MUSL_LOADER): $(KERNEL_MUSL_APK)
	tar -xOzf $< lib/ld-musl-aarch64.so.1 > $@
	chmod +x $@

$(KERNEL_INITRAMFS_CPIO): $(KERNEL_BUSYBOX_STATIC) $(KERNEL_HTTPD) $(KERNEL_MUSL_LOADER)
	cd $(KERNEL_USER_BUILD_DIR) && printf '%s\n' busybox-static busybox-httpd ld-musl-aarch64.so.1 | cpio -o -H newc > initramfs.cpio

$(KERNEL_EXT2_IMAGE): $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $(KERNEL_EXT2_FIXTURE_DIR)/index.html $(KERNEL_EXT2_FIXTURE_DIR)/init.sh $(KERNEL_EXT2_FIXTURE_DIR)/large.txt $(KERNEL_RPI5_USER_PAYLOAD_ELF) | $(KERNEL_USER_BUILD_DIR)
	rm -f $@.tmp
	truncate -s 1048576 $@.tmp
	E2FSPROGS_FAKE_TIME=1700000000 mke2fs -q -t ext2 -b 1024 -I 128 -O none -F -U 00000000-0000-0000-0000-000000000177 $@.tmp 1024
	debugfs -w -R 'mkdir /etc' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'mkdir /bin' $@.tmp >/dev/null 2>&1
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $@.tmp:/hello.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $@.tmp:/mutable.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/index.html $@.tmp:/index.html
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/init.sh $@.tmp:/init.sh
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/large.txt $@.tmp:/large.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_RPI5_USER_PAYLOAD_ELF) $@.tmp:/user_payload
	debugfs -w -R 'set_inode_field /init.sh mode 0100755' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'set_inode_field /user_payload mode 0100755' $@.tmp >/dev/null 2>&1
	E2FSPROGS_FAKE_TIME=1700000000 debugfs -w -R 'symlink /latest hello.txt' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'symlink /busybox /init.sh' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'symlink /bin/echo /busybox' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'symlink /echo /busybox' $@.tmp >/dev/null 2>&1
	e2fsck -fn $@.tmp >/dev/null
	mv $@.tmp $@

$(KERNEL_RPI5_ENTRY_O): $(KERNEL_RPI5_ENTRY_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_USER_ENTRY_O): $(KERNEL_RPI5_USER_ENTRY_S) $(KERNEL_RPI5_EXC_CONTEXT) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_FPSIMD_O): $(KERNEL_RPI5_FPSIMD_S) | $(KERNEL_BUILD_DIR)
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
	$(TAKIBI) $< --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --forbid-trap -o $@

$(KERNEL_RPI5_USER_PAYLOAD_ASM_O): $(KERNEL_RPI5_USER_PAYLOAD_ASM_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_USER_PAYLOAD_ELF): $(KERNEL_RPI5_USER_PAYLOAD_TKB_O) $(KERNEL_RPI5_USER_PAYLOAD_ASM_O)
	$(LLD) -pie --no-dynamic-linker -e initial_user_payload $(KERNEL_RPI5_USER_PAYLOAD_TKB_O) $(KERNEL_RPI5_USER_PAYLOAD_ASM_O) -o $@
	python3 scripts/check_user_payload_no_rw_globals.py $@

$(KERNEL_RPI5_MAIN_O): $(KERNEL_RPI5_MAIN_TKB) $(KERNEL_FREELIST_TKB) $(KERNEL_SLOTMAP_TKB) $(KERNEL_REFCOUNT_SLOTMAP_TKB) $(KERNEL_GROWABLE_POOL_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_USER_MEMORY_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_INITRAMFS_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_TKB) $(KERNEL_RPI5_ASID_TKB) $(KERNEL_RPI5_MMU_LAYOUT_TKB) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_RPI5_BOOT_EXTERN) $(KERNEL_RPI5_FPSIMD_EXTERN) $(KERNEL_INITRAMFS_CPIO) $(KERNEL_EXT2_IMAGE) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) $(KERNEL_RPI5_MAILBOX_TKB) \
    $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_INTC_TKB) $(KERNEL_RPI5_TIMER_IRQ_TKB) $(KERNEL_RPI5_TIMER_TKB) $(KERNEL_RPI5_EXC_EVIDENCE_TKB) $(KERNEL_RPI5_VECTOR_TABLE_TKB) $(KERNEL_RPI5_EXC_FRAME_TKB) $(TAKIBI) | $(KERNEL_BUILD_DIR)
	$(TAKIBI) $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_MMU_LAYOUT_TKB) $(KERNEL_RPI5_GEM_TKB) $< --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --forbid-trap -o $@

$(KERNEL_RPI5_ELF): $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_RPI5_FPSIMD_O) $(KERNEL_RPI5_MAIN_O) $(KERNEL_RPI5_LINK_LD)
	$(LLD) -T $(KERNEL_RPI5_LINK_LD) $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_RPI5_FPSIMD_O) $(KERNEL_RPI5_MAIN_O) -o $@
	python3 scripts/check_kernel_asm_invariants.py $@ 2

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
KERNEL_QEMU_MAIN_TKB     := $(KERNEL_DIR)/init/main_qemu.tkb
KERNEL_QEMU_MAIN_O       := $(KERNEL_QEMU_BUILD_DIR)/main.o
KERNEL_QEMU_LINK_LD      := $(KERNEL_DIR)/arch/arm64/boot/link_qemu.ld
KERNEL_QEMU_ELF          := $(KERNEL_QEMU_BUILD_DIR)/kernel.elf
KERNEL_QEMU_UART_TKB     := $(KERNEL_DIR)/platform/qemu/uart.tkb
KERNEL_QEMU_INTC_TKB     := $(KERNEL_DIR)/platform/qemu/intc.tkb
KERNEL_QEMU_TIMER_IRQ_TKB := $(KERNEL_DIR)/platform/qemu/timer_irq.tkb
KERNEL_QEMU_MEMORY_TKB   := $(KERNEL_DIR)/platform/qemu/memory.tkb
KERNEL_QEMU_MMU_LAYOUT_TKB := $(KERNEL_DIR)/platform/qemu/mmu_layout.tkb
KERNEL_QEMU_VIRTIO_NET_TKB := $(KERNEL_DIR)/drivers/net/virtio_net.tkb

$(KERNEL_QEMU_BUILD_DIR):
	mkdir -p $@

KERNEL_QEMU_ENTRY_S := $(KERNEL_DIR)/arch/arm64/boot/entry_qemu.S

$(KERNEL_QEMU_ENTRY_O): $(KERNEL_QEMU_ENTRY_S) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

$(KERNEL_QEMU_USER_ENTRY_O): $(KERNEL_RPI5_USER_ENTRY_S) $(KERNEL_RPI5_EXC_CONTEXT) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

$(KERNEL_QEMU_FPSIMD_O): $(KERNEL_RPI5_FPSIMD_S) | $(KERNEL_QEMU_BUILD_DIR)
	$(LLVM_MC) --triple=$(QEMU_TARGET) --filetype=obj $< -o $@

# GitHub issue #237: kernel/kernel/syscall.tkb's own `use` graph
# unconditionally reaches kernel/fs/ext2/ext2.tkb -> kernel/drivers/block/
# memory.tkb (needs disk_read/disk_write) and kernel/net/{socket_capability,
# arp,icmp}.tkb -> kernel/drivers/net/rp1_gem.tkb (RPi5's real Ethernet
# driver) -- there is no QEMU storage/network driver yet (that is separate,
# planned follow-up work, see kernel/README.md), so RPi5's own pcie.tkb/
# usb_xhci.tkb/rp1_gem.tkb are linked here too, purely so the whole-program
# link resolves. kernel/init/main_qemu.tkb never calls disk_initialize()/
# net_init(), so their real RP1/RPi5 MMIO addresses are never touched --
# this is unreachable code, not a functional dependency on RPi5 hardware.
# kernel/platform/rpi5/uart.tkb/intc.tkb/timer_irq.tkb/mailbox.tkb/
# mmu_layout.tkb are deliberately NOT included here: each defines a
# platform_* name kernel/platform/qemu/'s own files already define, and a
# duplicate top-level definition is a compile error by design.
$(KERNEL_QEMU_MAIN_O): $(KERNEL_QEMU_MAIN_TKB) $(KERNEL_FREELIST_TKB) $(KERNEL_SLOTMAP_TKB) $(KERNEL_REFCOUNT_SLOTMAP_TKB) $(KERNEL_GROWABLE_POOL_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_USER_MEMORY_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_INITRAMFS_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_TKB) $(KERNEL_RPI5_ASID_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_RPI5_BOOT_EXTERN) $(KERNEL_RPI5_FPSIMD_EXTERN) $(KERNEL_INITRAMFS_CPIO) $(KERNEL_EXT2_IMAGE) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) $(KERNEL_QEMU_MEMORY_TKB) \
    $(KERNEL_QEMU_UART_TKB) $(KERNEL_QEMU_INTC_TKB) $(KERNEL_QEMU_TIMER_IRQ_TKB) $(KERNEL_RPI5_TIMER_TKB) $(KERNEL_RPI5_EXC_EVIDENCE_TKB) $(KERNEL_RPI5_VECTOR_TABLE_TKB) $(KERNEL_RPI5_EXC_FRAME_TKB) $(TAKIBI) | $(KERNEL_QEMU_BUILD_DIR)
	$(TAKIBI) $(KERNEL_QEMU_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_QEMU_MMU_LAYOUT_TKB) $(KERNEL_QEMU_MEMORY_TKB) $(KERNEL_QEMU_VIRTIO_NET_TKB) $< --target $(QEMU_TARGET) --cpu $(QEMU_CPU) --forbid-trap -o $@

$(KERNEL_QEMU_ELF): $(KERNEL_QEMU_ENTRY_O) $(KERNEL_QEMU_USER_ENTRY_O) $(KERNEL_QEMU_FPSIMD_O) $(KERNEL_QEMU_MAIN_O) $(KERNEL_QEMU_LINK_LD)
	$(LLD) -T $(KERNEL_QEMU_LINK_LD) $(KERNEL_QEMU_ENTRY_O) $(KERNEL_QEMU_USER_ENTRY_O) $(KERNEL_QEMU_FPSIMD_O) $(KERNEL_QEMU_MAIN_O) -o $@
	python3 scripts/check_kernel_asm_invariants.py $@ 1

kernelbuild-qemu: kernel-lib-check $(KERNEL_QEMU_ELF)

# Pure source-text check (issues #207/#242, see HISTORY.md's 2026-08-07
# entry) -- no build product needed, so it runs independent of and before
# the actual compile below rather than being tied to a .o/.elf rule.
.PHONY: kernel-lib-check
kernel-lib-check:
	python3 scripts/check_kernel_lib_limitations_header.py $(KERNEL_DIR)/lib

kernelbuild-rpi5: kernel-lib-check $(KERNEL_RPI5_ELF)

kernelbuild: kernelbuild-rpi5 kernelbuild-qemu

## RPI5_SERIAL_DEV: empty by default, resolved at runtime by
## scripts/rpi5_uart_dev.sh (which picks the ttyACM device out by its
## /dev/serial/by-id label). Override only if the auto-detected device is
## wrong.
RPI5_SERIAL_DEV ?=

# A compile is not an integration pass. This deliberately fails until the
# first observable RPi5 EL1 milestone connects its real-hardware harness.
kernelcheck-rpi5: kernelbuild-rpi5
	@RPI5_SERIAL_DEV="$(RPI5_SERIAL_DEV)" bash scripts/run_kernel_hwtest_rpi5.sh

kernelcheck-qemu: kernelbuild-qemu
	@bash scripts/run_kernel_qemutest.sh

kernelcheck: kernelcheck-qemu kernelcheck-rpi5

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
## that invariant matters and must not be bypassed by a future change.
.PHONY: allcheck
allcheck: langcheck test linuxcheck kernelcheck

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts, kernel/ link outputs, and linux_user/
## build outputs. Does not touch examples/ -- use `make -f examples/Makefile
## clean` for that.
clean:
	dune clean
	find kernel/build -type f \( -name '*.o' -o -name '*.elf' -o -name '*.bin' -o -name '*.img' \) -delete 2>/dev/null || true
	rm -rf $(LINUX_USER_BUILD_DIR)
	find $(LINUX_USER_DIR) -type f \( -name '*.o' -o -name '*.exe' \) -delete 2>/dev/null || true
