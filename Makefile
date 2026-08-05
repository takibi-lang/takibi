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
LLVM_MC := llvm-mc-19
LLD     := ld.lld-19

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
.PHONY: build test kernelbuild kernelcheck kernelbuild-rpi5 kernelcheck-rpi5 langcheck linuxbuild linuxcheck clean FORCE

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
                             freelist_pool freelist_generic \
                             hello print_int print_hex print_ptr mem array struct struct_refined \
                             nonexhaustive refined narrow enum align packed struct_align const_global \
                             sizeof_offsetof int64 bitops indexed_view tcp_conn_view \
                             affine_escape_via_index align_ptr_proof linear_obligation tuple_pair \
                             field_lease match_int_lit \
                             callstack ringbuf crc8 djb2 slice foreach for loop fizzbuzz fibonacci \
                             bubblesort inet_checksum ip_parse tcp_parse wire_endian
LINUX_USER_BINS          := $(foreach e,$(LINUX_USER_EXAMPLES),$(LINUX_USER_DIR)/$(e)/$(e).exe)

# Extra prerequisites (staleness tracking only -- `use` already resolves
# these transitively at compile time, same reasoning as examples/Makefile's
# own .tkb -> .o rule comment) for the tests above that `use` a shared file
# outside their own directory.
$(LINUX_USER_DIR)/checked_usize/checked_usize_exe.o: $(LINUX_USER_DIR)/common/checked_usize.tkb
$(LINUX_USER_DIR)/elf64_validate/elf64_validate_exe.o: $(LINUX_USER_DIR)/common/elf64_validate.tkb $(LINUX_USER_DIR)/common/checked_usize.tkb
$(LINUX_USER_DIR)/page_pool/page_pool_exe.o: $(LINUX_USER_DIR)/page_pool/page_pool_core.tkb
$(LINUX_USER_DIR)/freelist_pool/freelist_pool_exe.o: $(LINUX_USER_DIR)/freelist_pool/freelist_pool_core.tkb
$(LINUX_USER_DIR)/inet_checksum/inet_checksum_exe.o: $(LINUX_USER_DIR)/common/inet_checksum.tkb
$(LINUX_USER_DIR)/tcp_parse/tcp_parse_exe.o: $(LINUX_USER_DIR)/common/inet_checksum.tkb $(LINUX_USER_DIR)/common/netutil.tkb

# GitHub issue #213: freelist_generic's capacity is a runtime slice length,
# not a compile-time constant, so its bounds checks cannot be proven away
# by today's checker (a relational-bounds gap, not a real safety hole --
# see the comments at each accepted trap site in freelist_core.tkb). This
# overrides the shared %_exe.o pattern rule below for this one target only,
# dropping --forbid-trap; every other linux_user/ target is unaffected.
#
# Issue #213's relational `v < s.len` narrowing landed and closed the
# freelist_core_pop site (was 1 of the 3 original sites) -- 2 of 3 remain,
# genuinely out of scope for that fix (a for-loop init needing cross-
# variable-init-history reasoning, and a cross-function-call-boundary
# argument), so this override still cannot be dropped.
#
# Coarser than ideal: freelist_generic.tkb `use`s freelist_core.tkb, and
# both are concatenated into ONE compilation (this language has no real
# separate compilation yet -- see AGENTS.md's issue #55 Part B note), so
# --forbid-trap can only be dropped for the whole unit, not just the 2
# known sites -- confirmed by rebuilding with --forbid-trap still on and
# checking the reported trap count stays exactly 2, all in
# freelist_core.tkb, none in freelist_generic.tkb's own code, at the time
# this comment was last updated. If freelist_generic.tkb's own app_main
# code grows, re-run that check (drop this override, rebuild, confirm the
# trap count and file names reported) rather than trusting this comment to
# still be accurate.
$(LINUX_USER_DIR)/freelist_generic/freelist_generic_exe.o: $(LINUX_USER_DIR)/freelist_generic/freelist_generic.tkb $(LINUX_USER_DIR)/freelist_generic/freelist.tkb $(LINUX_USER_DIR)/freelist_generic/freelist_core.tkb $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $(COMMON_LINUX_PRINT_BASE) $(TAKIBI)
	$(TAKIBI) $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $(LINUX_USER_DIR)/freelist_generic/freelist_generic.tkb --target $(LINUX_AMD64_TARGET) -o $@
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
KERNEL_RPI5_TIMER_S     := $(KERNEL_DIR)/arch/arm64/kernel/timer.S
KERNEL_RPI5_TIMER_O     := $(KERNEL_BUILD_DIR)/timer.o
KERNEL_RPI5_MMU_S       := $(KERNEL_DIR)/arch/arm64/mm/mmu.S
KERNEL_RPI5_MMU_O       := $(KERNEL_BUILD_DIR)/mmu.o
KERNEL_RPI5_MMU_EXTERN  := $(KERNEL_DIR)/arch/arm64/mm/mmu_extern.tkb
KERNEL_RPI5_USER_ENTRY_S := $(KERNEL_DIR)/arch/arm64/kernel/user_entry.S
KERNEL_RPI5_USER_ENTRY_O := $(KERNEL_BUILD_DIR)/user_entry.o
KERNEL_RPI5_USER_EXTERN  := $(KERNEL_DIR)/arch/arm64/kernel/user_entry_extern.tkb
KERNEL_RPI5_USER_CONTEXT := $(KERNEL_DIR)/arch/arm64/kernel/user_context.inc
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
KERNEL_INITRAMFS_S       := $(KERNEL_DIR)/user/initramfs.S
KERNEL_INITRAMFS_O       := $(KERNEL_BUILD_DIR)/initramfs.o
KERNEL_INITRAMFS_EXTERN  := $(KERNEL_DIR)/user/initramfs_extern.tkb
KERNEL_EXT2_FIXTURE_DIR  := $(KERNEL_DIR)/tests/ext2
KERNEL_EXT2_IMAGE        := $(KERNEL_USER_BUILD_DIR)/ext2.img
KERNEL_EXT2_IMAGE_S      := $(KERNEL_DIR)/user/ext2_image.S
KERNEL_EXT2_IMAGE_O      := $(KERNEL_BUILD_DIR)/ext2_image.o
KERNEL_EXT2_IMAGE_EXTERN := $(KERNEL_DIR)/user/ext2_image_extern.tkb
KERNEL_RPI5_LINK_LD     := $(KERNEL_DIR)/arch/arm64/boot/link.ld
KERNEL_RPI5_MAIN_TKB    := $(KERNEL_DIR)/init/main.tkb
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
KERNEL_RPI5_GEM_TKB     := $(KERNEL_DIR)/drivers/net/rp1_gem.tkb
KERNEL_NETCONFIG_TKB    := $(KERNEL_DIR)/net/netconfig.tkb
KERNEL_ARP_TKB          := $(KERNEL_DIR)/net/arp.tkb
KERNEL_CHECKSUM_TKB     := $(KERNEL_DIR)/net/checksum.tkb
KERNEL_ICMP_TKB         := $(KERNEL_DIR)/net/icmp.tkb
KERNEL_WIRE_TKB         := $(KERNEL_DIR)/net/wire.tkb
KERNEL_TCP_TKB          := $(KERNEL_DIR)/net/tcp.tkb
KERNEL_SOCKET_CAP_TKB   := $(KERNEL_DIR)/net/socket_capability.tkb
KERNEL_RPI5_TIMER_EXTERN := $(KERNEL_DIR)/arch/arm64/kernel/timer_asm_extern.tkb
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

$(KERNEL_EXT2_IMAGE): $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $(KERNEL_EXT2_FIXTURE_DIR)/index.html $(KERNEL_EXT2_FIXTURE_DIR)/init.sh | $(KERNEL_USER_BUILD_DIR)
	rm -f $@.tmp
	truncate -s 1048576 $@.tmp
	E2FSPROGS_FAKE_TIME=1700000000 mke2fs -q -t ext2 -b 1024 -I 128 -O none -F -U 00000000-0000-0000-0000-000000000177 $@.tmp 1024
	debugfs -w -R 'mkdir /etc' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'mkdir /bin' $@.tmp >/dev/null 2>&1
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $@.tmp:/hello.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $@.tmp:/mutable.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/index.html $@.tmp:/index.html
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/init.sh $@.tmp:/init.sh
	debugfs -w -R 'set_inode_field /init.sh mode 0100755' $@.tmp >/dev/null 2>&1
	E2FSPROGS_FAKE_TIME=1700000000 debugfs -w -R 'symlink /latest hello.txt' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'symlink /busybox /init.sh' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'symlink /bin/echo /busybox' $@.tmp >/dev/null 2>&1
	debugfs -w -R 'symlink /echo /busybox' $@.tmp >/dev/null 2>&1
	e2fsck -fn $@.tmp >/dev/null
	mv $@.tmp $@

$(KERNEL_RPI5_ENTRY_O): $(KERNEL_RPI5_ENTRY_S) $(KERNEL_RPI5_USER_CONTEXT) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_TIMER_O): $(KERNEL_RPI5_TIMER_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_MMU_O): $(KERNEL_RPI5_MMU_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_USER_ENTRY_O): $(KERNEL_RPI5_USER_ENTRY_S) $(KERNEL_RPI5_USER_CONTEXT) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_INITRAMFS_O): $(KERNEL_INITRAMFS_S) $(KERNEL_INITRAMFS_CPIO) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_EXT2_IMAGE_O): $(KERNEL_EXT2_IMAGE_S) $(KERNEL_EXT2_IMAGE) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_MAIN_O): $(KERNEL_RPI5_MAIN_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_USER_MEMORY_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_INITRAMFS_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_EXTERN) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_RPI5_BOOT_EXTERN) $(KERNEL_INITRAMFS_EXTERN) $(KERNEL_EXT2_IMAGE_EXTERN) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) \
    $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_INTC_TKB) $(KERNEL_RPI5_TIMER_IRQ_TKB) $(KERNEL_RPI5_TIMER_EXTERN) $(TAKIBI) | $(KERNEL_BUILD_DIR)
	$(TAKIBI) $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_PCIE_TKB) $< --target $(RPI5_TARGET) --cpu $(RPI5_CPU) --forbid-trap -o $@

$(KERNEL_RPI5_ELF): $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_TIMER_O) $(KERNEL_RPI5_MMU_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_INITRAMFS_O) $(KERNEL_EXT2_IMAGE_O) $(KERNEL_RPI5_MAIN_O) $(KERNEL_RPI5_LINK_LD)
	$(LLD) -T $(KERNEL_RPI5_LINK_LD) $(KERNEL_RPI5_ENTRY_O) $(KERNEL_RPI5_TIMER_O) $(KERNEL_RPI5_MMU_O) $(KERNEL_RPI5_USER_ENTRY_O) $(KERNEL_INITRAMFS_O) $(KERNEL_EXT2_IMAGE_O) $(KERNEL_RPI5_MAIN_O) -o $@

kernelbuild-rpi5: $(KERNEL_RPI5_ELF)

kernelbuild: kernelbuild-rpi5

## RPI5_SERIAL_DEV: empty by default, resolved at runtime by
## scripts/rpi5_uart_dev.sh (which picks the ttyACM device out by its
## /dev/serial/by-id label). Override only if the auto-detected device is
## wrong.
RPI5_SERIAL_DEV ?=

# A compile is not an integration pass. This deliberately fails until the
# first observable RPi5 EL1 milestone connects its real-hardware harness.
kernelcheck-rpi5: kernelbuild-rpi5
	@RPI5_SERIAL_DEV="$(RPI5_SERIAL_DEV)" bash scripts/run_kernel_hwtest_rpi5.sh

kernelcheck: kernelcheck-rpi5

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
