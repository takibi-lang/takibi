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
.PHONY: build test kernelbuild kernelcheck kernelbuild-rpi5 kernelcheck-rpi5 langcheck clean FORCE

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

# -- Raspberry Pi 5 (BCM2712) -------------------------------------------------
RPI5_TARGET := aarch64-none-elf
RPI5_CPU    := cortex-a76

# -- Standalone kernel tree (GitHub issue #177) -------------------------------
KERNEL_DIR              := kernel
KERNEL_BUILD_DIR        := $(KERNEL_DIR)/build/rpi5
KERNEL_RPI5_ENTRY_S     := $(KERNEL_DIR)/arch/arm64/boot/entry.S
KERNEL_RPI5_ENTRY_O     := $(KERNEL_BUILD_DIR)/entry.o
KERNEL_RPI5_TIMER_S     := $(KERNEL_DIR)/arch/arm64/kernel/timer.S
KERNEL_RPI5_TIMER_O     := $(KERNEL_BUILD_DIR)/timer.o
KERNEL_RPI5_MMU_S       := $(KERNEL_DIR)/arch/arm64/mm/mmu.S
KERNEL_RPI5_MMU_O       := $(KERNEL_BUILD_DIR)/mmu.o
KERNEL_RPI5_MMU_EXTERN  := $(KERNEL_DIR)/arch/arm64/mm/mmu_extern.tkb
KERNEL_RPI5_USER_ENTRY_S := $(KERNEL_DIR)/arch/arm64/kernel/user_entry.S
KERNEL_RPI5_USER_ENTRY_O := $(KERNEL_BUILD_DIR)/user_entry.o
KERNEL_RPI5_USER_EXTERN  := $(KERNEL_DIR)/arch/arm64/kernel/user_entry_extern.tkb
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
KERNEL_PROCESS_IMAGE_TKB := $(KERNEL_DIR)/mm/process_image.tkb
KERNEL_PROCESS_TKB      := $(KERNEL_DIR)/kernel/process.tkb
KERNEL_SYSCALL_TKB      := $(KERNEL_DIR)/kernel/syscall.tkb
KERNEL_INITRAMFS_TKB    := $(KERNEL_DIR)/fs/initramfs.tkb
KERNEL_ELF64_TKB        := $(KERNEL_DIR)/fs/elf64.tkb
KERNEL_MEMORY_BLOCK_TKB := $(KERNEL_DIR)/drivers/block/memory.tkb
KERNEL_EXT2_TKB         := $(KERNEL_DIR)/fs/ext2/ext2.tkb
KERNEL_LOG_TKB          := $(KERNEL_DIR)/printk/log.tkb
KERNEL_RPI5_PCIE_TKB    := $(KERNEL_DIR)/platform/rpi5/pcie.tkb
KERNEL_RPI5_UART_TKB    := $(KERNEL_DIR)/platform/rpi5/uart.tkb
KERNEL_RPI5_USB_XHCI_TKB := $(KERNEL_DIR)/platform/rpi5/usb_xhci.tkb
KERNEL_RPI5_GEM_TKB     := $(KERNEL_DIR)/drivers/net/rp1_gem.tkb
KERNEL_BYTE_TKB         := $(KERNEL_DIR)/lib/byte.tkb
KERNEL_NETCONFIG_TKB    := $(KERNEL_DIR)/net/netconfig.tkb
KERNEL_ARP_TKB          := $(KERNEL_DIR)/net/arp.tkb
KERNEL_CHECKSUM_TKB     := $(KERNEL_DIR)/net/checksum.tkb
KERNEL_ICMP_TKB         := $(KERNEL_DIR)/net/icmp.tkb
KERNEL_WIRE_TKB         := $(KERNEL_DIR)/net/wire.tkb
KERNEL_TCP_TKB          := $(KERNEL_DIR)/net/tcp.tkb
KERNEL_SOCKET_CAP_TKB   := $(KERNEL_DIR)/net/socket_capability.tkb
KERNEL_RPI5_TIMER_EXTERN := $(KERNEL_DIR)/arch/arm64/kernel/timer_asm_extern.tkb
KERNEL_RPI5_MAIN_O      := $(KERNEL_BUILD_DIR)/main.o
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

$(KERNEL_EXT2_IMAGE): $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $(KERNEL_EXT2_FIXTURE_DIR)/index.html | $(KERNEL_USER_BUILD_DIR)
	rm -f $@.tmp
	truncate -s 1048576 $@.tmp
	E2FSPROGS_FAKE_TIME=1700000000 mke2fs -q -t ext2 -b 1024 -I 128 -O none -F -U 00000000-0000-0000-0000-000000000177 $@.tmp 1024
	E2FSPROGS_FAKE_TIME=1700000000 e2mkdir $@.tmp:/etc
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/hello.txt $@.tmp:/hello.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/mutable.txt $@.tmp:/mutable.txt
	E2FSPROGS_FAKE_TIME=1700000000 e2cp $(KERNEL_EXT2_FIXTURE_DIR)/index.html $@.tmp:/index.html
	E2FSPROGS_FAKE_TIME=1700000000 debugfs -w -R 'symlink /latest hello.txt' $@.tmp >/dev/null 2>&1
	e2fsck -fn $@.tmp >/dev/null
	mv $@.tmp $@

$(KERNEL_RPI5_ENTRY_O): $(KERNEL_RPI5_ENTRY_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_TIMER_O): $(KERNEL_RPI5_TIMER_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_MMU_O): $(KERNEL_RPI5_MMU_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_USER_ENTRY_O): $(KERNEL_RPI5_USER_ENTRY_S) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_INITRAMFS_O): $(KERNEL_INITRAMFS_S) $(KERNEL_INITRAMFS_CPIO) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_EXT2_IMAGE_O): $(KERNEL_EXT2_IMAGE_S) $(KERNEL_EXT2_IMAGE) | $(KERNEL_BUILD_DIR)
	$(LLVM_MC) --triple=$(RPI5_TARGET) --filetype=obj $< -o $@

$(KERNEL_RPI5_MAIN_O): $(KERNEL_RPI5_MAIN_TKB) $(KERNEL_PAGE_TKB) $(KERNEL_ADDRESS_SPACE_TKB) $(KERNEL_PROCESS_IMAGE_TKB) $(KERNEL_PROCESS_TKB) $(KERNEL_SYSCALL_TKB) $(KERNEL_INITRAMFS_TKB) $(KERNEL_ELF64_TKB) $(KERNEL_MEMORY_BLOCK_TKB) $(KERNEL_EXT2_TKB) $(KERNEL_LOG_TKB) $(KERNEL_RPI5_MMU_EXTERN) $(KERNEL_RPI5_USER_EXTERN) $(KERNEL_INITRAMFS_EXTERN) $(KERNEL_EXT2_IMAGE_EXTERN) $(KERNEL_RPI5_PCIE_TKB) $(KERNEL_RPI5_USB_XHCI_TKB) $(KERNEL_RPI5_GEM_TKB) $(KERNEL_BYTE_TKB) $(KERNEL_NETCONFIG_TKB) $(KERNEL_ARP_TKB) $(KERNEL_CHECKSUM_TKB) $(KERNEL_ICMP_TKB) $(KERNEL_WIRE_TKB) $(KERNEL_TCP_TKB) $(KERNEL_SOCKET_CAP_TKB) \
    $(KERNEL_RPI5_UART_TKB) $(KERNEL_RPI5_TIMER_EXTERN) $(TAKIBI) | $(KERNEL_BUILD_DIR)
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

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts and kernel/ link outputs. Does not
## touch examples/ -- use `make -f examples/Makefile clean` for that.
clean:
	dune clean
	find kernel/build -type f \( -name '*.o' -o -name '*.elf' -o -name '*.bin' -o -name '*.img' \) -delete 2>/dev/null || true
