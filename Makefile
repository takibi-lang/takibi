# -- Configuration ------------------------------------------------------------
# Parallel by default (this repo's ~50 independent example builds are the
# common case), overridable per-invocation: `make -j1 check` forces serial
# execution back, e.g. when a build error needs to be read one recipe at a
# time. Deliberately not paired with -Otarget: that buffers each recipe's
# output until the recipe finishes, so progress isn't visible line-by-line
# while jobs are still running -- worse for watching a long build than the
# occasional interleaved line.
MAKEFLAGS += -j$(shell nproc)

AARCH64_TARGET := aarch64-none-elf
LINUX_AMD64_TARGET := x86_64-pc-linux-gnu

# Invoke the built binary directly rather than "dune exec takibi --": dune
# exec re-checks/re-locks the workspace on every call, which serializes
# concurrent invocations under `make -j`. Every .o rule below depends on
# $(TAKIBI) itself (a REAL prerequisite, not order-only -- see its own
# rule further down for why), so the binary is always fresh before any
# of these run, AND a genuine compiler change correctly invalidates every
# example that was already built with an older compiler.
TAKIBI  := _build/default/bin/main.exe
LLVM_MC := llvm-mc-19
LLD     := ld.lld-19
QEMU    := qemu-system-aarch64

# -- Platform-independent and QEMU/AArch64 support files ----------------------
COMMON_DIR         := examples/common
COMMON_QEMU_DIR    := examples/common_qemu
COMMON_STARTUP_S   := $(COMMON_QEMU_DIR)/startup.S
COMMON_STARTUP_O   := $(COMMON_QEMU_DIR)/startup.o
COMMON_TIMER_ASM_S := $(COMMON_QEMU_DIR)/timer_asm.S
COMMON_TIMER_ASM_O := $(COMMON_QEMU_DIR)/timer_asm.o
COMMON_SEM_ASM_S   := $(COMMON_QEMU_DIR)/sem_asm.S
COMMON_SEM_ASM_O   := $(COMMON_QEMU_DIR)/sem_asm.o
COMMON_SEMIHOSTING_ASM_S := $(COMMON_QEMU_DIR)/semihosting_asm.S
COMMON_SEMIHOSTING_ASM_O := $(COMMON_QEMU_DIR)/semihosting_asm.o
COMMON_LINK_LD     := $(COMMON_QEMU_DIR)/link.ld
COMMON_UART        := $(COMMON_QEMU_DIR)/uart.tkb
# GitHub issue #55: examples/common_qemu/print.tkb now `use`s
# examples/common/print.tkb + examples/common/runtime.tkb itself, so no
# recipe needs to pass COMMON_PRINT_BASE on the takibi command line
# anymore -- COMMON_PRINT_QEMU (just the one file) is what belongs on a
# command line now. COMMON_PRINT/COMMON_PRINT_BASE are kept as
# PREREQUISITES only (left of the `:`), not command-line arguments, purely
# so Make's staleness tracking still notices when print.tkb/runtime.tkb
# change -- Make has no visibility into a `.tkb` file's own `use`
# declarations, only into the Makefile's explicit prerequisite list.
COMMON_PRINT_BASE  := $(COMMON_DIR)/print.tkb $(COMMON_DIR)/runtime.tkb
COMMON_PRINT_QEMU  := $(COMMON_QEMU_DIR)/print.tkb
COMMON_PRINT       := $(COMMON_PRINT_BASE) $(COMMON_PRINT_QEMU)
# GitHub issue #55: examples/common_qemu/virtio_mmio.tkb now `use`s this
# file itself (it references the `gic` struct directly for its own IRQ
# ack/EOI), and preempt.tkb/semaphore.tkb/watchdog.tkb/condvar.tkb/
# msgqueue.tkb each `use` it too (their QEMU-shaped dispatch entry point
# references `gic` even though it's dead code on STM32, AND their QEMU
# build genuinely needs gic.tkb's functions too, indirectly via
# examples/common_qemu/timer.tkb's own gic_init()/gic_enable_timer_ppi()
# calls -- see each file's header comment). COMMON_GIC is kept below
# purely as a prerequisite for staleness tracking for those five; no
# recipe passes it on the command line via their own `use`.
#
# GitHub issue #79 follow-up: irq.tkb/echo.tkb do NOT `use` full gic.tkb
# (unlike the five above) -- they `use` COMMON_GIC_REGS (types only)
# instead, because their STM32 build also needs examples/common_stm32/
# nvic.tkb's real irq_uart_rx_setup/irq_uart_rx_unmask, and gic.tkb
# defines those same two names again (used to silently collide with
# nvic.tkb's; now a compile error, see gic_regs.tkb's header comment for
# the full story). COMMON_GIC is passed explicitly on the command line
# for these two examples' QEMU builds instead (see IRQ_OBJS/GETC_OBJS
# below), since it's no longer reachable transitively through their own
# `use`.
COMMON_GIC         := $(COMMON_QEMU_DIR)/gic.tkb
COMMON_GIC_REGS    := $(COMMON_QEMU_DIR)/gic_regs.tkb
COMMON_TIMER       := $(COMMON_QEMU_DIR)/timer.tkb
COMMON_SYNC        := $(COMMON_DIR)/sync.tkb
COMMON_VIRTIO_MMIO := $(COMMON_QEMU_DIR)/virtio_mmio.tkb
COMMON_INET_CKSUM  := $(COMMON_DIR)/inet_checksum.tkb
COMMON_NETUTIL     := $(COMMON_DIR)/netutil.tkb
COMMON_FAT12       := $(COMMON_DIR)/fat12.tkb
COMMON_HTTP_SERVER := $(COMMON_DIR)/http_server_common.tkb $(COMMON_DIR)/http_conn_state.tkb
COMMON_HTTP_SDCARD := $(COMMON_DIR)/http_sdcard_server.tkb
COMMON_RTOS        := $(COMMON_DIR)/rtos.tkb
COMMON_RTC         := $(COMMON_QEMU_DIR)/rtc.tkb
COMMON_NETCONFIG   := $(COMMON_QEMU_DIR)/netconfig.tkb
COMMON_STM32_STUB  := $(COMMON_QEMU_DIR)/stm32_stub.tkb
COMMON_RPI3_STUB   := $(COMMON_DIR)/rpi3_stub.tkb
COMMON_FAT12_GEOMETRY := $(COMMON_DIR)/fat12_geometry.tkb

# -- Linux/AMD64 user-space support files -------------------------------------
COMMON_LINUX_DIR       := examples/common_linux
COMMON_LINUX_STARTUP_S := $(COMMON_LINUX_DIR)/startup.S
COMMON_LINUX_STARTUP_O := $(COMMON_LINUX_DIR)/startup.o
COMMON_LINUX_SYSCALL_S := $(COMMON_LINUX_DIR)/syscall.S
COMMON_LINUX_SYSCALL_O := $(COMMON_LINUX_DIR)/syscall.o
COMMON_LINUX_UART      := $(COMMON_LINUX_DIR)/uart.tkb
COMMON_LINUX_PRINT     := $(COMMON_LINUX_DIR)/print.tkb
LINUX_EXAMPLES         := linux_hello
LINUX_BINS             := $(foreach e,$(LINUX_EXAMPLES),examples/$(e)/$(e).exe)

# -- Examples ------------------------------------------------------------------
# To add a new example, just append its name here.
# Convention: examples/<name>/<name>.tkb -> examples/<name>/kernel.elf
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct struct_refined msgqueue watchdog refined narrow for loop enum nonexhaustive bitops align packed struct_align const_global sizeof_offsetof slice foreach int64 net_echo arp_reply inet_checksum ip_parse icmp_echo tcp_parse tcp_echo http_server fatfs affine_escape_via_index align_ptr_proof klock_guard percpu chan_rendezvous rtos_demo linear_obligation tuple_pair field_lease indexed_view tcp_conn_view kvs_server
ALL_KERNELS  := $(foreach e,$(EXAMPLES),examples/$(e)/kernel.elf)
EXAMPLE_OBJS := $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o)

# STM32F746G-DISCOVERY hardware port: the subset of EXAMPLES that's pure
# compute + uart_puts/uart_print_* output with no interrupt/timer/hand-written
# -assembly dependency (see the "STM32 hardware bring-up" section below for
# the full rationale and what's deliberately excluded, e.g. rtc/echo).
STM32_TARGET := thumbv7em-none-eabi
STM32_CPU    := cortex-m7
STM32_EXAMPLES := start hello print_int print_hex print_ptr mem array \
                  fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump \
                  scheduler struct struct_refined refined narrow for loop enum nonexhaustive \
                  bitops align packed struct_align const_global sizeof_offsetof slice foreach int64 \
                  indexed_view tcp_conn_view
STM32_OBJS     := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/$(e)_stm32.o)

# inet_checksum/ip_parse/tcp_parse: same CHECKSUM_OBJS group as the AArch64
# side, but examples/common/inet_checksum.tkb and examples/common/netutil.tkb
# are pure compute with no MMIO addresses at all (unlike uart.tkb) -- so
# unlike rtc/echo, no STM32-specific version of either is needed, both are
# reused completely unchanged. Kept as their own small group (not folded
# into STM32_EXAMPLES) since the recipe needs two extra common files that
# the rest of STM32_EXAMPLES doesn't.
STM32_CHECKSUM_EXAMPLES := inet_checksum ip_parse tcp_parse
STM32_CHECKSUM_OBJS     := $(foreach e,$(STM32_CHECKSUM_EXAMPLES),examples/$(e)/$(e)_stm32.o)

# `stm32build` builds every STM32 example as a RAM-execution image (see
# scripts/run_hwtest_ram.sh, scripts/run_hwtest_net_ram.sh, and
# examples/common_stm32/startup_ram.S for the full rationale: every one of
# these binaries is well under Flash Sector0's 32KB, so flashing all of
# them on every hardware-test run used to burn one erase cycle per example
# against Sector0's ~10,000-cycle guaranteed endurance -- loading directly
# into AXI SRAM1 over the debug port instead means neither hardware test
# target touches Flash at all). Every name here already has an existing
# examples/NAME/NAME_stm32.o rule (generic or bespoke) from the groups
# above; this only adds a link step against link_ram.ld.
#
# This used to be two separate targets (`stm32build`, Flash-only, and
# `stm32build-ram`) -- merged into one now that RAM execution is the only
# way any of these examples run, standalone Flash boot having no
# remaining consumer except examples/http_server's own explicit
# kernel_stm32.elf/.bin rule below (used only by `make stm32-http-server`,
# a deliberately-kept exception -- see that rule's comment for why).
#
# The 5 real-Ethernet examples (net_echo/arp_reply/icmp_echo/tcp_echo/
# http_server) are included here too: link_ram.ld gives them the SAME
# uniformly-cacheable AXI SRAM1 as everything else (no MPU non-cacheable
# window), so their DMA descriptor rings/buffers are genuinely cacheable
# and rely on eth.tkb's existing dma_prepare_tx/dma_prepare_rx/
# dma_finish_rx calls to actually maintain coherency -- see HISTORY.md's
# RAM-execution entries for why this is safe (those calls were already
# correct, just never exercised against real cacheable memory before) and
# for the real-hardware Ethernet validation this claim is based on.
#
# semaphore/condvar/msgqueue/rtos_demo/rtos_fatfs_sdcard/
# http_server_sdcard_rtos are deliberately left out of this list -- they
# need sem_asm.o linked in too, so they get their own bespoke rules below
# instead of the generic pattern rule.
STM32_RAM_EXAMPLES := $(STM32_EXAMPLES) rtc echo timer irq preempt watchdog \
                       $(STM32_CHECKSUM_EXAMPLES) \
                       net_echo arp_reply icmp_echo tcp_echo http_server sdcard fatfs_sdcard \
                       http_server_sdcard http_server_sdcard_install
# Target list for the generic $(STM32_RAM_ELFS_GENERIC) pattern rule below --
# deliberately distinct from STM32_RAM_ELFS (stm32build's full
# prerequisite list, used only for building "everything", never as a
# pattern rule's own target list): semaphore/condvar/msgqueue/rtos_demo/
# rtos_fatfs_sdcard/http_server_sdcard_rtos have their own explicit rules
# below with an extra sem_asm.o prerequisite, and a static pattern rule and
# an explicit rule may not both target the same file.
STM32_RAM_ELFS_GENERIC := $(foreach e,$(STM32_RAM_EXAMPLES),examples/$(e)/kernel_stm32_ram.elf)
STM32_RAM_ELFS := $(STM32_RAM_ELFS_GENERIC) \
                   examples/semaphore/kernel_stm32_ram.elf \
                   examples/condvar/kernel_stm32_ram.elf \
                   examples/msgqueue/kernel_stm32_ram.elf \
                   examples/rtos_demo/kernel_stm32_ram.elf \
                   examples/rtos_fatfs_sdcard/kernel_stm32_ram.elf \
                   examples/http_server_sdcard_rtos/kernel_stm32_ram.elf \
                   examples/kvs_server_sdcard_rtos/kernel_stm32_ram.elf \
                   examples/fatfs/kernel_stm32_ram.elf

# -- Targets ------------------------------------------------------------------
.PHONY: build test qemutest stm32build linuxbuild linuxcheck optimizercheck hwcheck-stm32 hwcheck-stm32-net hwcheck-rpi3 stress-stm32-kvs-server-sdcard-rtos perfcheck langcheck check allcheck clean qemu-echo qemu-net-echo qemu-arp-reply qemu-icmp-echo qemu-tcp-echo qemu-http-server qemu-kvs stm32-http-server stm32-http-server-sdcard stm32-http-server-sdcard-rtos profile-http-server profile-tcp-echo profile-stm32-http-server-sdcard-rtos profile-stm32-kvs-server-sdcard-rtos

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
# example .o rule below lists $(TAKIBI) as a REAL (not order-only)
# prerequisite -- previously it was only an order-only `| build` -- so a
# genuine compiler change now correctly makes every example look stale
# and get recompiled by plain `make check`, with no separate `make
# clean` step required (found the hard way: a non-clean `make check`
# silently kept using an old .o built by a previous compiler, a false
# pass that `make clean && make check` did not share -- see CLAUDE.md).
# This must stay the ONLY rule that invokes `dune build`: a second,
# independent invocation racing this one under `make -j` would
# reintroduce the "Unexpected contents of build directory global lock
# file" corruption already documented below (`test: build` and every
# .o rule now reach `dune build` exclusively through this one target).
.PHONY: FORCE
FORCE:

$(TAKIBI): FORCE
	dune build

## test: run unit tests
# Depends on `build` (not just order-only) so "dune test" never runs
# concurrently with "dune build" under `make -j`: dune's build-directory
# lock file is not safe against two concurrent dune invocations racing to
# create it (observed: "Unexpected contents of build directory global lock
# file" under `make -j check`). Every other per-example rule below no
# longer touches dune at all (see TAKIBI's comment), so this is the only
# ordering constraint needed to make the whole `check` pipeline -j-safe.
test: build
	dune test

## qemutest: run QEMU plus host-side integration tests and verify automatically
qemutest: $(ALL_KERNELS) examples/fibonacci/kernel.debug.elf examples/dwarf_debug/kernel.debug.elf $(LINUX_BINS) examples/inline_check/inline_check.o
	@bash scripts/run_qemutest.sh

## stm32build: link every ported STM32 example as a RAM-execution image, with
## no flashing/serial capture -- unlike hwcheck-stm32, this needs no physical
## hardware (only the same LLVM toolchain qemutest already requires), so it
## IS part of `make check`: it's the only thing that would otherwise catch
## a compiler regression breaking Cortex-M/Thumb2 codegen specifically
## (qemutest only ever exercises the aarch64-none-elf path). See
## STM32_RAM_EXAMPLES's comment above for why RAM execution is the only
## build this target produces for everything else, and examples/http_server/
## kernel_stm32.elf's own rule below for the one deliberate Flash-execution
## exception -- included as a prerequisite here too (link-only, no
## hardware needed) so `make check` still catches a build regression in
## that path even on a day `make hwcheck-stm32-net` doesn't run against real
## hardware. Without this, `stm32build`'s own "every ported example"
## promise would be silently false for exactly one example.
stm32build: $(STM32_RAM_ELFS) examples/http_server/kernel_stm32.bin examples/http_server_sdcard/kernel_stm32.bin examples/http_server_sdcard_rtos/kernel_stm32.bin

## hwcheck-stm32: run STM32 hardware integration tests (requires a real
## STM32F746G-DISCOVERY board connected via USB). NOT part of `make check` --
## unlike stm32build, this needs physical hardware, so it stays runnable-
## only-when-available rather than a requirement for every clone of this repo.
## Runs entirely from RAM (see scripts/run_hwtest_ram.sh) -- no Flash write
## happens anywhere in this target, so it carries no flash-endurance cost
## no matter how often it runs in CI.
hwcheck-stm32: stm32build
	@STM32_SERIAL_DEV="$(STM32_SERIAL_DEV)" bash scripts/run_hwtest_ram.sh

## hwcheck-stm32-net: run all STM32 real-Ethernet hardware tests (net_echo today,
## more as they're ported -- see scripts/run_hwtest_net_ram.sh) over a physical
## point-to-point link to the STM32F746G-DISCOVERY board (requires the
## board's Ethernet port wired directly to this machine's NIC). NOT part of
## hwcheck-stm32's automated UART-diff suite, and NOT part of `make check`/
## `make hwcheck-stm32` -- these are network tests (raw AF_PACKET sockets), not a
## UART capture/diff, and need CAP_NET_RAW (run with sudo) plus
## ETH_TEST_IFACE set to the wired interface if it isn't the default.
## Runs entirely from RAM, same as `make hwcheck-stm32` -- EXCEPT http_server,
## which is deliberately tested twice: once from RAM like everything else,
## and once via a genuine Flash write+reset of examples/http_server/
## kernel_stm32.bin (hence the extra prerequisite below), since that is the
## one Flash-execution boot path left in this repository and it would
## otherwise have zero automated coverage -- see scripts/run_hwtest_net_ram.sh's
## header comment.
hwcheck-stm32-net: stm32build examples/http_server/kernel_stm32.bin examples/http_server_sdcard/kernel_stm32.bin
	@STM32_SERIAL_DEV="$(STM32_SERIAL_DEV)" bash scripts/run_hwtest_net_ram.sh

## stress-stm32-kvs-server-sdcard-rtos: opt-in real-board stress run for
## examples/kvs_server_sdcard_rtos. This deliberately stays OUT of allcheck:
## issue #135 found that concurrent Ethernet plus SD write-through load is
## board/load sensitive on STM32F746G-DISCOVERY. Defaults match the practical
## manual profile workload: concurrency 4, fixed key, 30s. Override with
## TAKIBI_STRESS_CONCURRENCY, TAKIBI_STRESS_DURATION, TAKIBI_STRESS_FIXED_KEY,
## TAKIBI_STRESS_PUT_RATIO, TAKIBI_STRESS_GET_RATIO, and
## TAKIBI_STRESS_DELETE_RATIO.
stress-stm32-kvs-server-sdcard-rtos: examples/kvs_server_sdcard_rtos/kernel_stm32_ram.elf
	@STM32_SERIAL_DEV="$(STM32_SERIAL_DEV)" bash scripts/stress_stm32_kvs_server_sdcard_rtos.sh

## perfcheck: run real-hardware profiling smoke tests. This checks that the
## profiler's firmware table ABI, OpenOCD dump path, and host-side decoder
## still agree; it does not assert stable performance numbers -- the .tkb
## code and compiler are both moving targets, so exact cycle counts are not
## a meaningful regression signal here, only "did the mechanism run at all"
## is. Each profile run claims the one physical board exclusively (see
## scripts/stm32_hw_claim.sh); invoked as separate $(MAKE) sub-calls
## (same pattern as allcheck below), not as parallel prerequisites, so
## `make -jN perfcheck` can't race two profile scripts for the same
## hardware -- listing them as ordinary prerequisites let `-j` start both
## at once, and stm32_hw_claim.sh's takeover check doesn't recognize a
## profile script as a safe process to interrupt, so the loser just failed
## outright instead of queueing.
perfcheck:
	$(MAKE) profile-stm32-http-server-sdcard-rtos
	$(MAKE) profile-stm32-kvs-server-sdcard-rtos

## langcheck: verify that all source files contain only ASCII characters
langcheck:
	@echo "Checking for non-ASCII characters in source files..."
	@if LC_ALL=C grep -rnP '[^\x00-\x7F]' --exclude-dir=_build \
	       --include="*.ml" --include="*.mll" --include="*.mly" \
	       --include="*.tkb" --include="*.S" --include="*.md" \
	       --include="*.sh" --include="*.ld" --include="*.py" \
	       . Makefile 2>/dev/null; then \
	    echo "ERROR: non-ASCII characters found (see above)"; exit 1; \
	fi
	@echo "OK: all files are ASCII-clean"

## check: run unit tests + QEMU/host integration tests + STM32 build check + ASCII check
check: langcheck test stm32build qemutest

## linuxbuild: build Linux/AMD64 user-space examples (no libc, _start -> app_main)
linuxbuild: $(LINUX_BINS)

## linuxcheck: run Linux/AMD64 user-space examples and diff expected stdout
linuxcheck: linuxbuild
	@bash scripts/run_qemutest.sh --host-only linux_hello

## optimizercheck: inspect generated objects for backend optimization regressions
examples/inline_check/inline_check.o: examples/inline_check/inline_check.tkb $(TAKIBI)
	$(TAKIBI) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

optimizercheck: examples/inline_check/inline_check.o
	@bash scripts/run_qemutest.sh --host-only inline_check

## allcheck: clean build artifacts, then run software and hardware checks
allcheck:
	$(MAKE) clean
	$(MAKE) check
	$(MAKE) hwcheck-stm32
	$(MAKE) perfcheck
	$(MAKE) hwcheck-stm32-net

# -- Shared assembly objects ---------------------------------------------------
$(COMMON_STARTUP_O): $(COMMON_STARTUP_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

$(COMMON_TIMER_ASM_O): $(COMMON_TIMER_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

$(COMMON_SEM_ASM_O): $(COMMON_SEM_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

$(COMMON_SEMIHOSTING_ASM_O): $(COMMON_SEMIHOSTING_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

$(COMMON_LINUX_STARTUP_O): $(COMMON_LINUX_STARTUP_S)
	$(LLVM_MC) --triple=$(LINUX_AMD64_TARGET) --filetype=obj $< -o $@

$(COMMON_LINUX_SYSCALL_O): $(COMMON_LINUX_SYSCALL_S)
	$(LLVM_MC) --triple=$(LINUX_AMD64_TARGET) --filetype=obj $< -o $@

examples/linux_hello/linux_hello_exe.o: examples/linux_hello/linux_hello.tkb $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $(COMMON_PRINT_BASE) $(TAKIBI)
	$(TAKIBI) $(COMMON_LINUX_UART) $(COMMON_LINUX_PRINT) $< --target $(LINUX_AMD64_TARGET) -o $@ --forbid-trap

examples/linux_hello/linux_hello.exe: $(COMMON_LINUX_STARTUP_O) $(COMMON_LINUX_SYSCALL_O) examples/linux_hello/linux_hello_exe.o
	$(LLD) -static -nostdlib -e _start $^ -o $@

# -- .tkb -> .o  (static pattern rules) ----------------------------------------
# For examples/%.o, % matches "name/name" (including the slash).
# Example: examples/start/start.o <- examples/start/start.tkb
#
# GitHub issue #55: each example's own file-level `use` declarations now
# pull in gic.tkb/timer.tkb-equivalent.../sync.tkb/virtio_mmio.tkb/
# inet_checksum.tkb/netutil.tkb where needed (see each .tkb file's header
# comment), so the recipes below no longer need to pass those files on the
# takibi COMMAND LINE. They are still listed as PREREQUISITES (left of the
# `:`) below, purely so Make's own staleness tracking keeps working when
# one of those files changes -- Make has no visibility into a `.tkb`
# file's own `use` declarations, only into what this Makefile lists
# explicitly. Target-specific files with no single shared path across both
# targets (uart.tkb, print.tkb's per-target half, timer.tkb/scheduler.tkb,
# rtc.tkb, uart_irq_stub.tkb, netconfig.tkb) are NOT `use`-able from a
# shared example file and stay on the command line as before -- see
# CLAUDE.md's "No module/import system" note.
#
# Common file sets still passed to takibi:
#   Standard   : uart.tkb + print.tkb                        (most examples)
#   IRQ group  : + uart_irq_stub.tkb                         (irq)
#   Timer group: + timer.tkb + stm32_stub.tkb                (preempt semaphore watchdog)
#   Sync group : + timer.tkb + stm32_stub.tkb                (condvar msgqueue)
#   Net group  : + virtio_mmio.tkb + netconfig.tkb           (net_echo, arp_reply)
#   Checksum group: (nothing extra -- each file `use`s what it needs)
#   App group  : + virtio_mmio.tkb + netconfig.tkb           (icmp_echo, tcp_echo, http_server)
.SECONDEXPANSION:

IRQ_OBJS   := examples/irq/irq.o
COMMON_UART_IRQ_STUB := $(COMMON_QEMU_DIR)/uart_irq_stub.tkb
# semaphore.tkb declares its own extern fn sem_wait/sem_post, so no sync.tkb needed here
TIMER_OBJS := examples/preempt/preempt.o examples/semaphore/semaphore.o \
              examples/watchdog/watchdog.o
SYNC_OBJS  := examples/condvar/condvar.o examples/msgqueue/msgqueue.o examples/chan_rendezvous/chan_rendezvous.o
RTOS_OBJS  := examples/rtos_demo/rtos_demo.o
NET_OBJS   := examples/net_echo/net_echo.o examples/arp_reply/arp_reply.o
CHECKSUM_OBJS := examples/inet_checksum/inet_checksum.o examples/ip_parse/ip_parse.o \
                 examples/tcp_parse/tcp_parse.o
APP_OBJS   := examples/icmp_echo/icmp_echo.o examples/tcp_echo/tcp_echo.o \
              examples/http_server/http_server.o examples/kvs_server/kvs_server.o
# rtc needs one extra common file and echo needs GIC plus the UART IRQ stub,
# so neither fits STANDARD_OBJS. timer.tkb turned out to need
# the same rtc.tkb HAL as rtc itself (not gic.tkb/timer.tkb -- it just polls
# the RTC directly, unlike TIMER_OBJS below which is unrelated), so it
# joins this group too.
RTC_OBJS   := examples/rtc/rtc.o examples/timer/timer.o
GETC_OBJS  := examples/echo/echo.o
FATFS_OBJS := examples/fatfs/fatfs.o
SPECIAL_OBJS := $(IRQ_OBJS) $(TIMER_OBJS) $(SYNC_OBJS) $(RTOS_OBJS) $(NET_OBJS) $(CHECKSUM_OBJS) $(APP_OBJS) \
                $(RTC_OBJS) $(GETC_OBJS) $(FATFS_OBJS)
STANDARD_OBJS := $(filter-out $(SPECIAL_OBJS), $(EXAMPLE_OBJS))

$(STANDARD_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# examples/irq/irq.tkb `use`s gic_regs.tkb (types only) itself now, but
# needs gic.tkb's actual FUNCTIONS for the QEMU build (irq_uart_rx_setup/
# irq_uart_rx_unmask's real implementation) -- passed explicitly here
# since it can't be reached transitively through irq.tkb's own `use`
# without reintroducing the cross-file duplicate-definition collision
# with examples/common_stm32/nvic.tkb (see gic_regs.tkb's header comment,
# GitHub issue #79 follow-up).
$(IRQ_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_UART_IRQ_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_GIC) $(COMMON_UART_IRQ_STUB) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

$(RTC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_RTC) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# examples/echo/echo.tkb: same reasoning as irq above.
$(GETC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_UART_IRQ_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_GIC) $(COMMON_UART_IRQ_STUB) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# COMMON_STM32_STUB supplies pendsv_trigger() (a no-op here) so each of
# these shared examples' STM32-shaped SysTick_Handler/pendsv_dispatch
# entry points (dead code under QEMU) still compile -- see
# examples/preempt/preempt.tkb's header comment. preempt.tkb/semaphore.tkb/
# watchdog.tkb each `use` full gic.tkb themselves (unlike irq.tkb/echo.tkb
# above -- these three use examples/common_stm32/scheduler.tkb on STM32,
# not nvic.tkb, so there's no colliding irq_uart_rx_setup/unmask name to
# worry about; see gic_regs.tkb's header comment for the distinction), so
# COMMON_GIC is a prerequisite only here.
$(TIMER_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_STM32_STUB) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_TIMER) $(COMMON_STM32_STUB) $(COMMON_RPI3_STUB) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# condvar.tkb/msgqueue.tkb/chan_rendezvous.tkb `use` sync.tkb and gic.tkb
# themselves now. COMMON_RPI3_STUB supplies rpi3_timer_irq_pending()
# (RPi3-only) for condvar.tkb/msgqueue.tkb's own dead-here rpi3_irq_dispatch
# (chan_rendezvous.tkb has no such function yet, so the extra .tkb file is
# simply unused there -- harmless, same reasoning as every other COMMON_*
# prerequisite shared across a group with only partial need).
$(SYNC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) $(COMMON_STM32_STUB) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_TIMER) $(COMMON_STM32_STUB) $(COMMON_RPI3_STUB) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# rtos_demo.tkb `use`s common/rtos.tkb, which itself `use`s sync.tkb and
# gic_regs.tkb. QEMU still passes full gic.tkb explicitly because
# common_qemu/timer.tkb calls gic_init()/gic_enable_timer_ppi() by name.
# COMMON_RTOS is listed here purely for Make's own staleness tracking (Make
# cannot see into a .tkb file's own `use` declarations), same reasoning as
# every other COMMON_* prerequisite in this file. COMMON_RPI3_STUB supplies
# rpi3_timer_irq_pending() (RPi3-only, referenced by rtos.tkb's dead-here
# rpi3_irq_dispatch) -- same reasoning as $(TIMER_OBJS)'s own identical need
# further up.
$(RTOS_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_STM32_STUB) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_STM32_STUB) $(COMMON_RPI3_STUB) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# COMMON_NETCONFIG (OUR_IP) is unused-but-harmless for net_echo (no
# IP awareness at all) -- it just gets one inert extra constant rather than
# needing a split recipe group of its own. net_echo.tkb/arp_reply.tkb
# `use` netutil.tkb themselves now; virtio_mmio.tkb `use`s gic.tkb itself
# (it owns its own GIC dispatch and queue interrupt flags, keeping IRQ
# details out of applications), so COMMON_GIC/COMMON_NETUTIL are
# prerequisites only here.
$(NET_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# inet_checksum.tkb/ip_parse.tkb/tcp_parse.tkb each `use` exactly the
# subset of inet_checksum.tkb/netutil.tkb they actually need themselves
# now, so neither is passed on the command line here anymore.
$(CHECKSUM_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# fatfs.tkb `use`s netutil.tkb itself (bytes_copy for FAT12 field/name
# writes), so only COMMON_NETUTIL as a staleness prerequisite is needed,
# same reasoning as CHECKSUM_OBJS above.
#
# --forbid-trap: the fatfs+SD-card milestone (issues #61/#62/#98) is now
# proven working end to end on real hardware (see HISTORY.md's issue #98
# entry), so this is the first STANDARD_OBJS-style rule in the group to
# turn the flag on, per CLAUDE.md's "New .tkb Code: Prove It Without
# --forbid-trap First, Then Turn It On" process.
$(FATFS_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# icmp_echo.tkb/tcp_echo.tkb/http_server.tkb/kvs_server.tkb each `use`
# inet_checksum.tkb and netutil.tkb themselves now; virtio_mmio.tkb `use`s
# gic.tkb itself (see NET_OBJS above). kvs_server.tkb (GitHub issue #135)
# joined this group, --forbid-trap included from the start, once its QEMU
# baseline (working example + deterministic test + a manual curl session,
# all without the flag) was proven -- see HISTORY.md's issue #135 entry for
# what --forbid-trap flagged and how it was fixed.
$(APP_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_HTTP_SERVER) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $< --target $(AARCH64_TARGET) -o $@ --forbid-trap

# -- example.o + startup.o -> kernel.elf ---------------------------------------
# For examples/%/kernel.elf, % matches "name" (no slash).
# $$*.o expands in two stages to examples/<name>/<name>.o.
#
# Link sets:
#   Standard   : startup.o                         (most examples)
#   Timer group: startup.o + timer_asm.o            (preempt semaphore watchdog)
#   Sync group : startup.o + timer_asm.o + sem_asm.o (condvar msgqueue)
# timer_asm.o only (no semaphore symbols needed)
TIMER_KERNELS := examples/preempt/kernel.elf examples/watchdog/kernel.elf
# timer_asm.o + sem_asm.o (semaphore, condvar, msgqueue all need both)
SEM_KERNELS   := examples/semaphore/kernel.elf \
                 examples/condvar/kernel.elf examples/msgqueue/kernel.elf examples/chan_rendezvous/kernel.elf \
                 examples/rtos_demo/kernel.elf
# semihosting_asm.o only (fatfs.tkb's extern fn semihosting_open/write/close)
FATFS_KERNELS := examples/fatfs/kernel.elf
GENERIC_KERNELS := $(filter-out $(TIMER_KERNELS) $(SEM_KERNELS) $(FATFS_KERNELS), $(ALL_KERNELS))

$(GENERIC_KERNELS): examples/%/kernel.elf: \
    $(COMMON_STARTUP_O) examples/%/$$*.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/$*/$*.o -o $@

$(TIMER_KERNELS): examples/%/kernel.elf: \
    $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) examples/%/$$*.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) \
	       examples/$*/$*.o -o $@

$(SEM_KERNELS): examples/%/kernel.elf: \
    $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) $(COMMON_SEM_ASM_O) examples/%/$$*.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) $(COMMON_SEM_ASM_O) \
	       examples/$*/$*.o -o $@

$(FATFS_KERNELS): examples/%/kernel.elf: \
    $(COMMON_STARTUP_O) $(COMMON_SEMIHOSTING_ASM_O) examples/%/$$*.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) $(COMMON_SEMIHOSTING_ASM_O) \
	       examples/$*/$*.o -o $@

# -- DWARF debug-info regression checks -----------------------------------------
# Dedicated -g builds, entirely separate from the always-g-free rules above
# (their own .debug.o / kernel.debug.elf outputs, so they cannot collide
# with or affect normal kernels). Fibonacci gives run_dwarf_var_test a small
# dwarfdump-level variable smoke test; dwarf_debug is the live QEMU/GDB
# source-level fixture.
examples/fibonacci/fibonacci.debug.o: examples/fibonacci/fibonacci.tkb $(COMMON_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $< --target $(AARCH64_TARGET) -g -o $@ --forbid-trap

examples/fibonacci/kernel.debug.elf: $(COMMON_STARTUP_O) examples/fibonacci/fibonacci.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/fibonacci/fibonacci.debug.o -o $@

# Dedicated -g fixture for a live GDB check: typed globals, enum display,
# struct member layout, slice fat-value layout, aggregate locals/arguments,
# tuple-destructured locals, scoped locals, step/next/backtrace, and
# `set variable` against QEMU's gdbstub.
examples/dwarf_debug/dwarf_debug.debug.o: examples/dwarf_debug/dwarf_debug.tkb examples/common/runtime.tkb $(COMMON_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) examples/common/runtime.tkb $(COMMON_UART) $(COMMON_PRINT_QEMU) $< --target $(AARCH64_TARGET) -g -o $@ --forbid-trap

examples/dwarf_debug/kernel.debug.elf: $(COMMON_STARTUP_O) examples/dwarf_debug/dwarf_debug.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/dwarf_debug/dwarf_debug.debug.o -o $@

# Third dedicated -g build, this time for the "App group" common files
# (see the compilation-groups comment above IRQ_OBJS): needed so
# scripts/profile_http_server.py has DWARF line info to resolve sampled
# addresses against. Not part of `make check`/`qemutest` -- profiling is an
# exploratory dev activity, not a pass/fail regression (same reasoning as
# the manual qemu-* targets below).
examples/http_server/http_server.debug.o: examples/http_server/http_server.tkb \
    $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_HTTP_SERVER) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) \
	          $< --target $(AARCH64_TARGET) -g -o $@ --forbid-trap

examples/http_server/kernel.debug.elf: $(COMMON_STARTUP_O) examples/http_server/http_server.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/http_server/http_server.debug.o -o $@

# Same, for tcp_echo -- profile_http_server.py's profile landed ~100% in the
# idle interrupt-wait loop (network round trips dominate wall-clock time at
# the HTTP layer), so scripts/profile_tcp_echo.py profiles one layer down
# with a workload built to keep the server continuously busy instead.
examples/tcp_echo/tcp_echo.debug.o: examples/tcp_echo/tcp_echo.tkb \
    $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT_QEMU) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) \
	          $< --target $(AARCH64_TARGET) -g -o $@ --forbid-trap

examples/tcp_echo/kernel.debug.elf: $(COMMON_STARTUP_O) examples/tcp_echo/tcp_echo.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/tcp_echo/tcp_echo.debug.o -o $@

# -- STM32F746G-DISCOVERY hardware bring-up (step 2/2b: pure-compute examples) --
# Covers every example that only needs examples/common_qemu/uart.tkb +
# examples/common/print.tkb on the AArch64 side (i.e. STANDARD_OBJS), minus
# two deliberately excluded for reasons unrelated to "is it portable":
#   - rtc: pokes the QEMU-only PL031 RTC address directly, no STM32 RTC
#     peripheral support exists yet (separate task, different peripheral
#     entirely from anything ported so far).
#   - echo: uses the QEMU GIC dispatch and uniform UART RX callback stub
#     register, and its test methodology needs writing bytes to the serial
#     port (interactive stdin), not just reading -- scripts/run_hwtest_ram.sh
#     only supports the read-and-diff shape today.
# Every other STANDARD_OBJS example is pure compute + uart_puts/uart_print_*
# output with no interrupt/timer/hand-written-assembly dependency (confirmed
# by inspection before adding this list), so all of them reuse
# examples/common_stm32/uart.tkb + examples/common/print.tkb exactly like
# examples/hello/hello.tkb did in the first STM32 port, and their existing
# .expected files (already used by the AArch64/QEMU run_test calls below) are
# reused unchanged -- uart_puts/uart_print_* write the exact same bytes on
# either HAL.
# (STM32_TARGET/STM32_CPU/STM32_EXAMPLES/STM32_OBJS/STM32_RAM_EXAMPLES
# are defined near the top of this file, alongside EXAMPLES/ALL_KERNELS, so
# that hwcheck-stm32's prerequisite list further up can reference them.)
COMMON_STM32_DIR       := examples/common_stm32
COMMON_STM32_STARTUP_S := $(COMMON_STM32_DIR)/startup.S
COMMON_STM32_STARTUP_O := $(COMMON_STM32_DIR)/startup.o
COMMON_STM32_UART      := $(COMMON_STM32_DIR)/uart.tkb
# Same COMMON_PRINT_QEMU/COMMON_PRINT split as the QEMU side above:
# examples/common_stm32/print.tkb now `use`s COMMON_PRINT_BASE itself, so
# COMMON_STM32_PRINT_ONLY (just the one file) belongs on the command
# line; COMMON_STM32_PRINT (kept, unchanged) stays a prerequisite only.
COMMON_STM32_PRINT_ONLY := $(COMMON_STM32_DIR)/print.tkb
COMMON_STM32_PRINT     := $(COMMON_PRINT_BASE) $(COMMON_STM32_PRINT_ONLY)
# eth.tkb's DMA descriptor rings/buffers need AXI SRAM -- used only by
# examples/http_server/kernel_stm32.elf's rule now (see its comment), the
# one deliberately-kept Flash-execution example.
COMMON_STM32_LINK_ETH_LD := $(COMMON_STM32_DIR)/link_eth.ld
# RAM-execution variant (used by every other STM32 example -- see
# STM32_RAM_EXAMPLES's comment above) and startup_ram.S's header comment
# for the full rationale.
COMMON_STM32_STARTUP_RAM_S := $(COMMON_STM32_DIR)/startup_ram.S
COMMON_STM32_STARTUP_RAM_O := $(COMMON_STM32_DIR)/startup_ram.o
COMMON_STM32_LINK_RAM_LD   := $(COMMON_STM32_DIR)/link_ram.ld

$(COMMON_STM32_STARTUP_O): $(COMMON_STM32_STARTUP_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

$(COMMON_STM32_STARTUP_RAM_O): $(COMMON_STM32_STARTUP_RAM_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

$(STM32_OBJS): examples/%_stm32.o: examples/%.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# RAM-execution link: reuses whichever examples/%/%_stm32.o rule already
# exists (generic or bespoke, from any group above) -- only the startup
# object and linker script differ from a Flash build.
$(STM32_RAM_ELFS_GENERIC): examples/%/kernel_stm32_ram.elf: \
    $(COMMON_STM32_STARTUP_RAM_O) examples/%/$$*_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) examples/$*/$*_stm32.o -o $@

# rtc and echo need target-specific RTC/interrupt-controller dependencies,
# so they keep one-off rules rather than joining the generic group above.
COMMON_STM32_RTC       := $(COMMON_STM32_DIR)/rtc.tkb
COMMON_STM32_NVIC      := $(COMMON_STM32_DIR)/nvic.tkb
COMMON_STM32_SCHEDULER := $(COMMON_STM32_DIR)/scheduler.tkb
COMMON_STM32_SEM_ASM_S := $(COMMON_STM32_DIR)/sem_asm.S
COMMON_STM32_SEM_ASM_O := $(COMMON_STM32_DIR)/sem_asm.o

$(COMMON_STM32_SEM_ASM_O): $(COMMON_STM32_SEM_ASM_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

COMMON_STM32_SEMIHOSTING_STUB_S := $(COMMON_STM32_DIR)/semihosting_stub.S
COMMON_STM32_SEMIHOSTING_STUB_O := $(COMMON_STM32_DIR)/semihosting_stub.o

$(COMMON_STM32_SEMIHOSTING_STUB_O): $(COMMON_STM32_SEMIHOSTING_STUB_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

examples/rtc/rtc_stm32.o: examples/rtc/rtc.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_RTC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# timer: turned out (during the interrupt-batch research) to need exactly
# the same rtc.tkb HAL as rtc itself, not any interrupt/scheduler
# infrastructure -- see examples/timer/timer.tkb's own comment.
examples/timer/timer_stm32.o: examples/timer/timer.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_RTC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# examples/echo/echo.tkb `use`s gic_regs.tkb (types only), not full
# gic.tkb (both platforms' interrupt entry points are compiled regardless
# of target; the QEMU-shaped irq_dispatch entry point references the gic
# struct even though it's dead code here -- see that file's header
# comment) -- GitHub issue #79 follow-up: full gic.tkb would redefine
# irq_uart_rx_setup/irq_uart_rx_unmask, colliding with
# examples/common_stm32/nvic.tkb's real versions, so COMMON_GIC_REGS is
# the prerequisite here (not COMMON_GIC), and only for staleness
# tracking -- neither is passed on the command line.
examples/echo/echo_stm32.o: examples/echo/echo.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_GIC_REGS) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_NVIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# irq/preempt/semaphore/condvar/watchdog/msgqueue: each compiles the *same*
# examples/<name>/<name>.tkb file the QEMU build uses (see
# examples/net_echo/net_echo.tkb's header comment for the general pattern,
# and examples/irq/irq.tkb / examples/preempt/preempt.tkb's header comments
# for how GICv2-vs-NVIC dispatch is unified despite the two hardware models
# genuinely differing). Each of these six files needs SOME source of the
# `GicRegs` type (harmless, unused on this target) so the QEMU-shaped
# entry point in each shared file still compiles -- see
# examples/common_qemu/stm32_stub.tkb's comment for the other half of that
# (QEMU needing STM32-only stand-ins). irq.tkb specifically `use`s
# gic_regs.tkb (types only, not full gic.tkb -- GitHub issue #79
# follow-up, see that file's header comment); the other five `use` full
# gic.tkb (no naming collision for them, see the comment above
# $(TIMER_OBJS) on the QEMU side). COMMON_GIC/COMMON_GIC_REGS are kept as
# prerequisites only below, not command-line arguments, for the same
# staleness-tracking reason noted near their definitions.
#
# irq: NVIC vectors directly to USART1_IRQHandler, a fundamentally
# different dispatch model from GICv2's software IAR/EOIR table.
examples/irq/irq_stm32.o: examples/irq/irq.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_GIC_REGS) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_NVIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# preempt: PendSV_Handler lives directly in the always-shared
# common_stm32/startup.S (unlike a separate optional assembly object) --
# harmless for every other example since nothing triggers PENDSVSET unless
# a program enables SysTick, so no extra object needs linking here beyond
# the usual startup.o.
examples/preempt/preempt_stm32.o: examples/preempt/preempt.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# semaphore: same scheduler restructure as preempt; declares its own extern
# fn sem_wait/sem_post (no sync.tkb needed, same as the AArch64 version),
# links against the STM32 sem_asm.o (ldrex/strex, not ldaxr/stlxr).
# COMMON_RPI3_STUB: see preempt_stm32.o's own comment above -- semaphore.tkb
# now defines its own rpi3_irq_dispatch too (examples/common_rpi3/AGENTS.md).
examples/semaphore/semaphore_stm32.o: examples/semaphore/semaphore.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# condvar/msgqueue: same scheduler restructure, plus reuse
# examples/common/sync.tkb completely unchanged (pure takibi logic calling
# only sem_wait/sem_post), linked against the STM32 sem_asm.o. Both files
# `use` sync.tkb and gic.tkb themselves now, and now also define their own
# rpi3_irq_dispatch (COMMON_RPI3_STUB, same reasoning as semaphore above).
examples/condvar/condvar_stm32.o: examples/condvar/condvar.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_GIC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/msgqueue/msgqueue_stm32.o: examples/msgqueue/msgqueue.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_GIC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# rtos_demo.tkb `use`s common/rtos.tkb, which itself `use`s sync.tkb and
# gic.tkb. The STM32 build provides the target-specific scheduler.tkb on
# the command line exactly like preempt/condvar/msgqueue do. COMMON_RPI3_STUB
# supplies rpi3_timer_irq_pending() (RPi3-only, referenced by rtos.tkb's
# dead-here rpi3_irq_dispatch) -- same reasoning as preempt_stm32.o's own
# identical need further up.
examples/rtos_demo/rtos_demo_stm32.o: examples/rtos_demo/rtos_demo.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

COMMON_STM32_SDMMC := $(COMMON_STM32_DIR)/sdmmc.tkb
COMMON_STM32_ETH_SDMMC_REGS := $(COMMON_STM32_DIR)/eth_sdmmc_regs.tkb
COMMON_STM32_FAT12_SDMMC := $(COMMON_STM32_DIR)/fat12_sdmmc.tkb

# rtos_fatfs_sdcard: SD/FAT worker task combining common/rtos.tkb with
# fat12.tkb and a real storage backend. Like rtos_demo it needs the
# target-specific scheduler.tkb on the command line. Shared with
# Raspberry Pi 3B (GitHub issue #145): rtos_fatfs_sdcard.tkb no longer
# `use`s a target-specific adapter itself, so COMMON_STM32_FAT12_SDMMC is
# now on the actual compile command line here (see fatfs_sdcard's own
# comment for the full reasoning) -- the other storage/FAT files are
# listed here purely for Make's own staleness tracking.
# COMMON_RPI3_STUB: see rtos_demo_stm32.o's own comment above.
examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard_stm32.o: examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_NETUTIL) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# fatfs: `use`s fat12.tkb (which itself `use`s netutil.tkb) directly, needs
# no STM32-specific HAL beyond uart+print. --forbid-trap enabled, same
# milestone-wide reason as the QEMU-side FATFS_OBJS rule.
examples/fatfs/fatfs_stm32.o: examples/fatfs/fatfs.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# RAM-execution builds of semaphore/condvar/msgqueue/rtos_demo/
# rtos_fatfs_sdcard/http_server_sdcard_rtos -- these need sem_asm.o linked
# in too, so they get their own explicit rules here instead of the generic
# $(STM32_RAM_ELFS_GENERIC) pattern rule.
examples/semaphore/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/semaphore/semaphore_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/semaphore/semaphore_stm32.o -o $@

examples/condvar/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/condvar/condvar_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/condvar/condvar_stm32.o -o $@

examples/msgqueue/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/msgqueue/msgqueue_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/msgqueue/msgqueue_stm32.o -o $@

examples/rtos_demo/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/rtos_demo/rtos_demo_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/rtos_demo/rtos_demo_stm32.o -o $@

examples/rtos_fatfs_sdcard/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/rtos_fatfs_sdcard/rtos_fatfs_sdcard_stm32.o -o $@

examples/http_server_sdcard_rtos/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.o -o $@

examples/http_server/kernel_stm32_ram.debug.elf: $(COMMON_STM32_STARTUP_RAM_O) examples/http_server/http_server_stm32.debug.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) examples/http_server/http_server_stm32.debug.o -o $@

examples/http_server_sdcard/kernel_stm32_ram.debug.elf: $(COMMON_STM32_STARTUP_RAM_O) examples/http_server_sdcard/http_server_sdcard_stm32.debug.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) examples/http_server_sdcard/http_server_sdcard_stm32.debug.o -o $@

examples/http_server_sdcard_rtos/kernel_stm32_ram.debug.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.debug.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.debug.o -o $@

# fatfs: needs semihosting_stub.o linked in too (fatfs.tkb's extern fn
# semihosting_open/read/write/close), so it gets its own explicit rule
# instead of the generic $(STM32_RAM_ELFS_GENERIC) pattern rule.
examples/fatfs/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEMIHOSTING_STUB_O) examples/fatfs/fatfs_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEMIHOSTING_STUB_O) examples/fatfs/fatfs_stm32.o -o $@

# watchdog: same scheduler restructure as preempt, no semaphore needed.
# COMMON_RPI3_STUB: see preempt_stm32.o's own comment above -- watchdog.tkb
# now defines its own rpi3_irq_dispatch too.
examples/watchdog/watchdog_stm32.o: examples/watchdog/watchdog.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# net_echo/arp_reply/icmp_echo/tcp_echo/http_server (STM32): real Ethernet
# MAC/PHY/DMA (examples/common_stm32/eth.tkb) instead of virtio-net. Each
# compiles the *same* examples/<name>/<name>.tkb file the QEMU build uses
# (see examples/net_echo/net_echo.tkb's header comment) -- unlike
# irq/preempt/etc., there is no genuinely-different-shape logic here
# anymore, eth.tkb just implements the same typed net_rx_acquire/
# len/frame/release API plus net_init/net_transmit/net_tx_complete/net_read_mac
# examples/common_qemu/virtio_mmio.tkb does. Links against
# COMMON_STM32_LINK_ETH_LD (AXI SRAM), not the shared DTCM-based link.ld.
# eth.tkb now `use`s nvic.tkb (enable_eth_irq), netconfig.tkb (OUR_MAC),
# and netutil.tkb (bytes_copy, for net_read_mac) itself -- see its header
# comment -- so none of COMMON_STM32_NVIC/COMMON_STM32_NETCONFIG/
# COMMON_NETUTIL need to be passed on the command line for any of these
# five examples anymore; icmp_echo.tkb/tcp_echo.tkb/http_server.tkb
# additionally `use` inet_checksum.tkb themselves. All are kept as
# prerequisites only, for staleness tracking.
COMMON_STM32_ETH       := $(COMMON_STM32_DIR)/eth.tkb
COMMON_STM32_NETCONFIG := $(COMMON_STM32_DIR)/netconfig.tkb

examples/net_echo/net_echo_stm32.o: examples/net_echo/net_echo.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/arp_reply/arp_reply_stm32.o: examples/arp_reply/arp_reply.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/icmp_echo/icmp_echo_stm32.o: examples/icmp_echo/icmp_echo.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/tcp_echo/tcp_echo_stm32.o: examples/tcp_echo/tcp_echo.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/http_server/http_server_stm32.o: examples/http_server/http_server.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_HTTP_SERVER) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/http_server/http_server_stm32.debug.o: examples/http_server/http_server.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_HTTP_SERVER) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -g -o $@ --forbid-trap

# sdcard: GitHub issue #62, real SDMMC1 microSD driver, built and verified
# entirely independently of examples/fatfs (see sdmmc.tkb's header comment).
# STM32-only -- no QEMU build exists (no virtual SD controller in this
# project's QEMU setup). --forbid-trap enabled: already compiled clean
# under it with no changes needed (sdcard.tkb's own fixed-size loops were
# already fully provable).
examples/sdcard/sdcard_stm32.o: examples/sdcard/sdcard.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SDMMC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SDMMC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# fatfs_sdcard: GitHub issue #98, wires fat12.tkb's FAT12 logic (issue #61)
# onto sdmmc.tkb's real SD card driver (issue #62) -- see fatfs_sdcard.tkb's
# own header comment. Shared with Raspberry Pi 3B as of GitHub issue #145:
# fatfs_sdcard.tkb no longer `use`s a target-specific adapter itself, so
# COMMON_STM32_FAT12_SDMMC is now on the actual compile command line (it
# transitively `use`s fat12.tkb + sdmmc.tkb itself, same reasoning
# examples/net_echo.tkb's own target HAL command-line composition already
# established) -- the other storage/FAT files are listed here purely for
# Make's own staleness tracking. No QEMU build (no virtual SD/USB
# controller in this project's QEMU setup, same reasoning as sdcard).
# --forbid-trap enabled, same milestone-wide reason as examples/fatfs and
# examples/sdcard.
examples/fatfs_sdcard/fatfs_sdcard_stm32.o: examples/fatfs_sdcard/fatfs_sdcard.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_SDMMC) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_NETUTIL) $(COMMON_STM32_FAT12_SDMMC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_FAT12_SDMMC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# http_server_sdcard: GitHub issue #97, combines http_server.tkb's TCP/IP +
# HTTP state machine with fatfs_sdcard.tkb's real SD card access -- see
# http_server_sdcard.tkb's own header comment. `use`s fat12_sdmmc.tkb for the
# FAT12/SDMMC storage boundary, so only uart+print+eth need to be on the
# command line; the rest are listed here purely for Make's own staleness
# tracking. STM32-only (no virtual SD controller under QEMU, same reasoning
# as fatfs_sdcard/sdcard).
#
# --forbid-trap enabled: this file and the installer below were first
# built and verified against real hardware WITHOUT --forbid-trap (see
# CLAUDE.md's Development Process section), then hardened together in one
# pass once the whole milestone worked end to end -- see
# http_server_sdcard.tkb's own header comment for what --forbid-trap did
# and did not flag.
examples/http_server_sdcard/http_server_sdcard_stm32.o: examples/http_server_sdcard/http_server_sdcard.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_HTTP_SDCARD) $(COMMON_STM32_FAT12_SDMMC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_FAT12_SDMMC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/http_server_sdcard/http_server_sdcard_stm32.debug.o: examples/http_server_sdcard/http_server_sdcard.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_HTTP_SDCARD) $(COMMON_STM32_FAT12_SDMMC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_FAT12_SDMMC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -g -o $@ --forbid-trap

# http_server_sdcard_rtos: same HTTP+SD server as http_server_sdcard, but
# SD/FAT operations run behind a Simple RTOS worker task. It needs both
# target-specific Ethernet and scheduler implementations on the command
# line, and links with sem_asm.o via its explicit RAM target above.
# COMMON_RPI3_STUB: see rtos_demo_stm32.o's own comment further up.
examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.o: examples/http_server_sdcard_rtos/http_server_sdcard_rtos.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_HTTP_SDCARD) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.debug.o: examples/http_server_sdcard_rtos/http_server_sdcard_rtos.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_HTTP_SDCARD) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -g -o $@ --forbid-trap

examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.prof.o: examples/http_server_sdcard_rtos/http_server_sdcard_rtos.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_HTTP_SDCARD) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) --profile-functions -o $@ --forbid-trap

examples/http_server_sdcard_rtos/kernel_stm32_ram.prof.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.prof.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.prof.o -o $@

# kvs_server_sdcard_rtos (GitHub issue #135): STM32 port of
# examples/kvs_server, combining real Ethernet + SD-card persistence
# through FAT12 + RTOS task separation as one milestone. Same shape as
# http_server_sdcard_rtos above (SD/FAT operations run behind a Simple
# RTOS worker task, needs both target-specific Ethernet and scheduler
# implementations on the command line, links with sem_asm.o via its
# explicit RAM target below) but does NOT use COMMON_HTTP_SDCARD -- this
# is a plain HTTP REST dispatch over COMMON_HTTP_SERVER, not a file
# server. RAM-only, no Flash variant -- see kvs_server_sdcard_rtos.tkb's
# own header comment for the design. A .prof.o/.prof.elf pair exists
# below (profile-stm32-kvs-server-sdcard-rtos) to measure where the
# write-through PUT/DELETE path's cycles actually go, per the stress-test
# findings on GitHub issue #135; no .debug.o/.debug.elf pair exists yet
# (add one the same way if source-level GDB debugging is ever needed).
#
# --forbid-trap: ON. Proved working on real hardware first (including the
# persistence-survives-a-reset check) per AGENTS.md's Development Process
# section, committed as that baseline ("KVS server with SD card on RTOS"),
# then this flag turned on in a follow-up pass -- the copied Phase-1 store/
# parsing logic was already --forbid-trap clean, and the new RTOS/SD code
# (for-loop-bounded table clearing, plain fat_write/fat_read calls with
# literal sizes, the RPC channel mirroring http_server_sdcard_rtos.tkb's
# already-hardened SdRequestChan) needed no fixes either -- this is the
# rare case where the whole milestone was already trap-clean the moment
# the flag was flipped. See HISTORY.md's issue #135 entry.
examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.o: examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

examples/kvs_server_sdcard_rtos/kernel_stm32_ram.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.o -o $@

examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.prof.o: examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_STM32_NVIC) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_STM32_SDMMC) $(COMMON_STM32_ETH_SDMMC_REGS) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_STM32_FAT12_SDMMC) $(COMMON_RPI3_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_ETH) $(COMMON_STM32_SCHEDULER) $(COMMON_RPI3_STUB) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) --profile-functions -o $@ --forbid-trap

examples/kvs_server_sdcard_rtos/kernel_stm32_ram.prof.elf: $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.prof.o $(COMMON_STM32_LINK_RAM_LD)
	$(LLD) -T $(COMMON_STM32_LINK_RAM_LD) $(COMMON_STM32_STARTUP_RAM_O) $(COMMON_STM32_SEM_ASM_O) examples/kvs_server_sdcard_rtos/kvs_server_sdcard_rtos_stm32.prof.o -o $@

# http_server_sdcard_install: provisioning-only helper (make hwcheck-stm32-net,
# make stm32-http-server-sdcard) that writes a real mtools-built FAT12
# image onto the SD card via disk_write, so neither target needs a human
# to touch the card -- see that file's own header comment and
# scripts/provision_http_server_sdcard.sh. Never `use`s fat12.tkb (writes
# raw sectors only). --forbid-trap enabled, same milestone-wide reason as
# http_server_sdcard above -- see that file's own header comment for the
# one site --forbid-trap flagged here and how it was fixed.
examples/http_server_sdcard_install/http_server_sdcard_install_stm32.o: examples/http_server_sdcard_install/http_server_sdcard_install.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_FAT12_GEOMETRY) $(COMMON_STM32_SDMMC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $(COMMON_STM32_SDMMC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# examples/http_server is the one deliberate exception to "every STM32
# example runs from RAM" (see STM32_RAM_EXAMPLES's comment above): flashing
# it lets a demo unit boot the HTTP server standalone by power-on alone,
# with no debugger attached -- `make stm32-http-server` below depends on
# this .bin specifically. Genuinely cacheable AXI SRAM1 for its DMA
# descriptors/buffers even in this Flash build, same as the RAM-execution
# path -- see examples/common_stm32/startup.S's header comment for why the
# non-cacheable MPU window this file used to configure was removed
# entirely (both execution modes now rely on eth.tkb's dma_prepare_tx/
# dma_prepare_rx/dma_finish_rx calls for DMA coherency, not a hardware
# memory-attribute workaround) and HISTORY.md's RAM-execution entries for
# the full reasoning and validation.
examples/http_server/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/http_server/http_server_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) examples/http_server/http_server_stm32.o -o $@

examples/http_server/kernel_stm32.bin: examples/http_server/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# examples/http_server_sdcard and examples/http_server_sdcard_rtos get the
# same deliberate Flash-execution exception as examples/http_server (see
# that rule's comment just above, and `make stm32-http-server-sdcard` /
# `make stm32-http-server-sdcard-rtos` below): a demo unit should be able
# to boot the SD-card-backed HTTP server standalone from power-on, with no
# debugger attached -- RAM execution cannot do this at all, since AXI
# SRAM1 loses its contents when power is removed. Same genuinely-cacheable
# AXI SRAM1 DMA policy as http_server's own Flash build.
examples/http_server_sdcard/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/http_server_sdcard/http_server_sdcard_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) examples/http_server_sdcard/http_server_sdcard_stm32.o -o $@

examples/http_server_sdcard/kernel_stm32.bin: examples/http_server_sdcard/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/http_server_sdcard_rtos/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/http_server_sdcard_rtos/http_server_sdcard_rtos_stm32.o -o $@

examples/http_server_sdcard_rtos/kernel_stm32.bin: examples/http_server_sdcard_rtos/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# inet_checksum.tkb/ip_parse.tkb/tcp_parse.tkb each `use` exactly the
# subset of inet_checksum.tkb/netutil.tkb they actually need themselves
# now (same as the QEMU-side CHECKSUM_OBJS rule above), so neither is
# passed on the command line here anymore.
$(STM32_CHECKSUM_OBJS): examples/%_stm32.o: examples/%.tkb $(COMMON_STM32_UART) $(COMMON_STM32_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_STM32_PRINT_ONLY) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@ --forbid-trap

# -- QEMU run targets ----------------------------------------------------------
QEMU_FLAGS := -machine virt -cpu cortex-a53 -nographic \
              -semihosting-config enable=on,target=native

## qemu-echo: manually run the echo server on QEMU virt (press Ctrl-A X to quit)
qemu-echo: examples/echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) -kernel $<

# Offloads disabled so GuestFeatures negotiates to 0 and virtio_net_hdr
# stays a fixed 10 bytes -- see examples/common_qemu/virtio_mmio.tkb.
VIRTIO_NET_FLAGS := -global virtio-mmio.force-legacy=on \
    -netdev dgram,id=net0,local.type=inet,local.host=127.0.0.1,local.port=17771,remote.type=inet,remote.host=127.0.0.1,remote.port=17772 \
    -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off

## qemu-net-echo: manually run the L2 echo server (Ctrl-A X to quit).
## In another terminal: python3 scripts/virtio_net_test.py
qemu-net-echo: examples/net_echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) $(VIRTIO_NET_FLAGS) -kernel $<

## qemu-arp-reply: manually run the ARP responder (Ctrl-A X to quit).
## In another terminal: python3 scripts/arp_test.py
qemu-arp-reply: examples/arp_reply/kernel.elf
	$(QEMU) $(QEMU_FLAGS) $(VIRTIO_NET_FLAGS) -kernel $<

## qemu-icmp-echo: manually run the ICMP echo (ping) responder (Ctrl-A X to quit).
## In another terminal: python3 scripts/icmp_echo_test.py
qemu-icmp-echo: examples/icmp_echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) $(VIRTIO_NET_FLAGS) -kernel $<

## qemu-tcp-echo: manually run the TCP echo server (Ctrl-A X to quit).
## In another terminal: python3 scripts/tcp_echo_test.py
qemu-tcp-echo: examples/tcp_echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) $(VIRTIO_NET_FLAGS) -kernel $<

# -netdev user (SLIRP) instead of -netdev dgram: a real IP-routable
# network so an actual browser on the host can reach the guest, unlike
# the raw point-to-point pipe scripts/*_test.py use. SLIRP's default
# guest-side address is 10.0.2.15 (http_server.tkb's our_ip matches this
# on purpose) and it will not deliver any IP packet to the guest until
# the guest has answered an ARP request for that address -- see
# http_server.tkb's file header for how that was discovered.
#
# HTTP_HOST_PORT is overridable (make qemu-http-server HTTP_HOST_PORT=8081)
# in case the default is still taken on your machine -- QEMU fails with
# "Could not set up host forwarding rule" if so, which doesn't say *why*
# it failed. Check what's using it first with `lsof -i :18080`
# (macOS/Linux). Deliberately NOT one of the well-known dev-server ports
# (3000, 5000, 8000, 8080, 8888, 9000, ...) -- 8080 was the original
# default here and immediately collided with Syncthing on a real machine;
# 18080 follows the same "high, uncommon port" convention as this
# project's own dgram test transport (17771/17772).
HTTP_HOST_PORT ?= 18080
HTTP_SERVER_FLAGS := -global virtio-mmio.force-legacy=on \
    -netdev user,id=net0,hostfwd=tcp::$(HTTP_HOST_PORT)-:80 \
    -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off

## qemu-http-server: run the HTTP server and browse to it from the host
## (Ctrl-C to quit -- see HTTP_SERVER_QEMU_FLAGS for why this one target
## doesn't need Ctrl-A X like the others). Open http://localhost:18080/ in
## a browser while this is running. If port 18080 is already taken on your
## machine, override it: make qemu-http-server HTTP_HOST_PORT=8081
#
# Every other qemu-* target uses $(QEMU_FLAGS)'s -nographic, which pipes
# the terminal through to the guest's serial console in raw mode so
# keystrokes reach the guest -- that's why they need the QEMU-specific
# Ctrl-A X escape instead of plain Ctrl-C (raw mode passes Ctrl-C to the
# guest as a byte, not as a host-level interrupt). http_server never reads
# from the guest's UART -- all interaction is over the network via a real
# browser -- so it doesn't need that pass-through: -serial file:/dev/stdout
# still shows the "http_server: init/ready" debug output, but without
# putting the terminal in raw mode, plain Ctrl-C reaches QEMU as a normal
# SIGINT and it exits cleanly (confirmed via `kill -INT`, matching what a
# terminal's Ctrl-C sends).
HTTP_SERVER_QEMU_FLAGS := -machine virt -cpu cortex-a53 -display none \
    -serial file:/dev/stdout -monitor none \
    -semihosting-config enable=on,target=native

qemu-http-server: examples/http_server/kernel.elf
	@echo "Open http://localhost:$(HTTP_HOST_PORT)/ in your browser (Ctrl-C to quit)"
	$(QEMU) $(HTTP_SERVER_QEMU_FLAGS) $(HTTP_SERVER_FLAGS) -kernel $<

## qemu-kvs: run the key-value store (GitHub issue #135) and exercise it
## with curl from the host (Ctrl-C to quit -- see qemu-http-server's
## comment above for why this doesn't need Ctrl-A X). Example:
##   make qemu-kvs
##   curl -si -X PUT --data-binary hello http://localhost:18081/keys/foo
##   curl -s  http://localhost:18081/keys/foo
##   curl -si -X DELETE http://localhost:18081/keys/foo
##   curl -s  http://localhost:18081/keys
## If port 18081 is taken, override it: make qemu-kvs KVS_HOST_PORT=18082
KVS_HOST_PORT ?= 18081
KVS_FLAGS := -global virtio-mmio.force-legacy=on \
    -netdev user,id=net0,hostfwd=tcp::$(KVS_HOST_PORT)-:80 \
    -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56,csum=off,guest_csum=off,gso=off,guest_tso4=off,guest_tso6=off,guest_ufo=off,guest_uso4=off,guest_uso6=off,mrg_rxbuf=off,ctrl_vq=off,mq=off,indirect_desc=off,event_idx=off

qemu-kvs: examples/kvs_server/kernel.elf
	@echo "KVS listening on http://localhost:$(KVS_HOST_PORT)/keys (Ctrl-C to quit)"
	$(QEMU) $(HTTP_SERVER_QEMU_FLAGS) $(KVS_FLAGS) -kernel $<

# Same STM32_SERIAL_DEV convention as scripts/run_hwtest_ram.sh
# (overridable the same way: STM32_SERIAL_DEV=/dev/ttyACM1 make ...). This
# target still flashes over Flash/st-flash (a real device needs its
# firmware in non-volatile storage) -- unlike make hwcheck-stm32/make hwcheck-stm32-net,
# which both run entirely from RAM.
# Default points at /dev-host, not /dev, on purpose: .devcontainer/
# devcontainer.json no longer bind-mounts /dev/ttyACM0 directly (that
# required the ST-LINK to already be plugged in at container start, or the
# whole devcontainer failed to build/start -- see its runArgs comment). It
# instead bind-mounts the host's entire /dev read-only at /dev-host, so a
# board plugged in after the container is already running still shows up
# here with no rebuild/restart needed.
STM32_SERIAL_DEV ?= /dev-host/ttyACM0
STM32_FLASH_ADDR := 0x08000000

## stm32-http-server: flash and run the HTTP server demo on the real
## STM32F746G-DISCOVERY board (requires it connected via USB -- ST-LINK for
## flashing, VCP serial for the log lines below -- and its Ethernet port
## wired directly to this machine's NIC, see examples/common_stm32/
## netconfig.tkb's OUR_IP comment for why that specific subnet was chosen).
## Same UX as qemu-http-server (announce the URL, then let the server's own
## log lines scroll by, Ctrl-C to quit), but the URL is parsed from
## netconfig.tkb's HTTP_SERVER_IP constant instead of a fixed QEMU/SLIRP
## address, so it can't silently drift out of sync with the board's actual
## configured IP. The serial reader is attached (backgrounded) before the
## explicit reset, not after, so the board's own earliest "ready" message
## isn't lost to a reader that hasn't opened the port yet -- same ordering
## reasoning as read_until_quiet's WAIT_FOR_DATA case in run_hwtest_ram.sh.
stm32-http-server: examples/http_server/kernel_stm32.bin
	@if [ ! -e "$(STM32_SERIAL_DEV)" ]; then \
	    echo "error: $(STM32_SERIAL_DEV) not found -- is the STM32F746G-DISCOVERY board connected?" >&2; \
	    exit 1; \
	fi
	@if ! st-info --probe > /dev/null 2>&1; then \
	    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2; \
	    exit 1; \
	fi
	st-flash --connect-under-reset write $< $(STM32_FLASH_ADDR)
	@rhs=$$(grep -m1 '^let HTTP_SERVER_IP:' examples/common_stm32/netconfig.tkb | grep -oP '= \K.*(?=;)'); \
	case "$$rhs" in \
	  \{*) lit="$$rhs" ;; \
	  *) lit=$$(grep -m1 "^let $$rhs:" examples/common_stm32/netconfig.tkb | grep -oP '= \K.*(?=;)') ;; \
	esac; \
	ip=$$(echo "$$lit" | tr -d '{} ' | tr ',' '.'); \
	echo "Open http://$$ip/ in your browser (Ctrl-C to quit)"; \
	stty -F $(STM32_SERIAL_DEV) 115200 raw -echo; \
	cat $(STM32_SERIAL_DEV) & \
	catpid=$$!; \
	sleep 0.2; \
	st-flash --connect-under-reset reset > /dev/null 2>&1; \
	wait $$catpid

## stm32-http-server-sdcard: flash and run the SD-card-backed HTTP server
## demo (GitHub issue #97) on the real board, same UX/mechanics as
## stm32-http-server just above (see that target's comment) but for
## examples/http_server_sdcard/kernel_stm32.bin instead.
##
## Fully self-contained -- does NOT depend on `make hwcheck-stm32-net` having
## run first. Before flashing anything, this target itself provisions the
## real SD card with a fresh mtools-built FAT12 image via
## scripts/provision_http_server_sdcard.sh (same script `make hwcheck-stm32-net`
## uses, not duplicated). If that fails -- most commonly no card inserted
## in the STM32F746G-DISCOVERY's microSD slot -- this target stops right
## there with a clear error message; it deliberately does NOT go on to
## flash and boot a server that would only ever be able to answer "404:
## file not found" to every request, leaving a human staring at a
## browser tab with no idea the card was ever missing.
stm32-http-server-sdcard: examples/http_server_sdcard/kernel_stm32.bin examples/http_server_sdcard_install/kernel_stm32_ram.elf
	@if [ ! -e "$(STM32_SERIAL_DEV)" ]; then \
	    echo "error: $(STM32_SERIAL_DEV) not found -- is the STM32F746G-DISCOVERY board connected?" >&2; \
	    exit 1; \
	fi
	@if ! st-info --probe > /dev/null 2>&1; then \
	    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2; \
	    exit 1; \
	fi
	bash scripts/provision_http_server_sdcard.sh examples/http_server_sdcard_install/kernel_stm32_ram.elf
	st-flash --connect-under-reset write $< $(STM32_FLASH_ADDR)
	@rhs=$$(grep -m1 '^let HTTP_SERVER_IP:' examples/common_stm32/netconfig.tkb | grep -oP '= \K.*(?=;)'); \
	case "$$rhs" in \
	  \{*) lit="$$rhs" ;; \
	  *) lit=$$(grep -m1 "^let $$rhs:" examples/common_stm32/netconfig.tkb | grep -oP '= \K.*(?=;)') ;; \
	esac; \
	ip=$$(echo "$$lit" | tr -d '{} ' | tr ',' '.'); \
	echo "Open http://$$ip/ in your browser (Ctrl-C to quit)"; \
	stty -F $(STM32_SERIAL_DEV) 115200 raw -echo; \
	cat $(STM32_SERIAL_DEV) & \
	catpid=$$!; \
	sleep 0.2; \
	st-flash --connect-under-reset reset > /dev/null 2>&1; \
	wait $$catpid

## stm32-http-server-sdcard-rtos: flash and run the RTOS variant of the
## SD-card-backed HTTP server. Same provisioning and browser UX as
## stm32-http-server-sdcard, but flashes
## examples/http_server_sdcard_rtos/kernel_stm32.bin.
stm32-http-server-sdcard-rtos: examples/http_server_sdcard_rtos/kernel_stm32.bin examples/http_server_sdcard_install/kernel_stm32_ram.elf
	@if [ ! -e "$(STM32_SERIAL_DEV)" ]; then \
	    echo "error: $(STM32_SERIAL_DEV) not found -- is the STM32F746G-DISCOVERY board connected?" >&2; \
	    exit 1; \
	fi
	@if ! st-info --probe > /dev/null 2>&1; then \
	    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2; \
	    exit 1; \
	fi
	bash scripts/provision_http_server_sdcard.sh examples/http_server_sdcard_install/kernel_stm32_ram.elf
	st-flash --connect-under-reset write $< $(STM32_FLASH_ADDR)
	@rhs=$$(grep -m1 '^let HTTP_SERVER_IP:' examples/common_stm32/netconfig.tkb | grep -oP '= \K.*(?=;)'); \
	case "$$rhs" in \
	  \{*) lit="$$rhs" ;; \
	  *) lit=$$(grep -m1 "^let $$rhs:" examples/common_stm32/netconfig.tkb | grep -oP '= \K.*(?=;)') ;; \
	esac; \
	ip=$$(echo "$$lit" | tr -d '{} ' | tr ',' '.'); \
	echo "Open http://$$ip/ in your browser (Ctrl-C to quit)"; \
	stty -F $(STM32_SERIAL_DEV) 115200 raw -echo; \
	cat $(STM32_SERIAL_DEV) & \
	catpid=$$!; \
	sleep 0.2; \
	st-flash --connect-under-reset reset > /dev/null 2>&1; \
	wait $$catpid

## profile-http-server: rough execution profile of http_server.tkb under QEMU
## (gdb-multiarch PC sampling against the -g build + a repeated-request
## load generator). See scripts/profile_http_server.py's module docstring
## for the caveats -- this is a *relative* profile (QEMU's TCG emulation
## doesn't model real Cortex-A53 timing), useful for "which function/line
## dominates", not an absolute cycle count.
profile-http-server: examples/http_server/kernel.debug.elf
	python3 scripts/profile_http_server.py $<

## profile-tcp-echo: rough execution profile of tcp_echo.tkb under QEMU,
## using a sustained burst of large data segments (see
## scripts/profile_tcp_echo.py's module docstring for why this exists
## alongside profile-http-server, and the same directional-only caveats).
profile-tcp-echo: examples/tcp_echo/kernel.debug.elf
	python3 scripts/profile_tcp_echo.py $<

## profile-stm32-http-server-sdcard-rtos: run the STM32 HTTP+SD+RTOS
## firmware from RAM with function profiling enabled, fetch /ICON.PNG with
## curl, then halt the board and dump the profiling table through OpenOCD.
profile-stm32-http-server-sdcard-rtos: examples/http_server_sdcard_rtos/kernel_stm32_ram.prof.elf examples/http_server_sdcard_install/kernel_stm32_ram.elf
	@STM32_SERIAL_DEV="$(STM32_SERIAL_DEV)" bash scripts/profile_stm32_http_server_sdcard_rtos.sh

## profile-stm32-kvs-server-sdcard-rtos: run the STM32 KVS+SD+RTOS
## firmware from RAM with function profiling enabled, PUT to the same key
## twice with curl (warm-up, then measured), then halt the board and dump
## the profiling table through OpenOCD -- see GitHub issue #135's stress-
## test findings for why PUT (the write-through SD save path) is the
## operation being profiled here rather than GET.
profile-stm32-kvs-server-sdcard-rtos: examples/kvs_server_sdcard_rtos/kernel_stm32_ram.prof.elf
	@STM32_SERIAL_DEV="$(STM32_SERIAL_DEV)" bash scripts/profile_stm32_kvs_server_sdcard_rtos.sh

# -- Raspberry Pi 3B (BCM2837) bring-up (GitHub issue #140) --------------------
# JTAG-only bring-up: examples are injected into RAM over JTAG rather than
# written to the SD card as a real kernel8.img -- see examples/common_rpi3/
# AGENTS.md for the full rationale (why a physical power cycle stands in
# for STM32's `reset halt`, why a separate jtag_stub.S spin-stub image
# exists) and scripts/rpi3_jtag_load.sh for the OpenOCD catch/load/run
# sequence.
#
# RPI3_EXAMPLES mirrors STM32_EXAMPLES' own "plain compute, no interrupt/
# timer/RTC dependency" grouping (same reasoning: rtc/timer/echo/irq/
# preempt/semaphore/condvar/msgqueue/watchdog/rtos_demo need a real
# BCM2837 interrupt-controller/timer driver -- a separate, substantially
# larger piece of work -- ported one at a time, not speculatively ahead
# of that; see examples/common_rpi3/AGENTS.md). RPI3_CHECKSUM_EXAMPLES
# mirrors STM32_CHECKSUM_EXAMPLES the same way STM32's own group does.
RPI3_TARGET := aarch64-none-elf
RPI3_CPU    := cortex-a53
COMMON_RPI3_DIR          := examples/common_rpi3
COMMON_RPI3_STARTUP_S    := $(COMMON_RPI3_DIR)/startup.S
COMMON_RPI3_STARTUP_O    := $(COMMON_RPI3_DIR)/startup.o
COMMON_RPI3_MMU_S        := $(COMMON_RPI3_DIR)/mmu.S
COMMON_RPI3_MMU_O        := $(COMMON_RPI3_DIR)/mmu.o
COMMON_RPI3_LINK_LD      := $(COMMON_RPI3_DIR)/link.ld
COMMON_RPI3_UART         := $(COMMON_RPI3_DIR)/uart.tkb
COMMON_RPI3_PRINT        := $(COMMON_RPI3_DIR)/print.tkb
COMMON_RPI3_INTC         := $(COMMON_RPI3_DIR)/intc.tkb
COMMON_RPI3_RTC          := $(COMMON_RPI3_DIR)/rtc.tkb
COMMON_RPI3_TIMER_ASM_S  := $(COMMON_RPI3_DIR)/timer_asm.S
COMMON_RPI3_TIMER_ASM_O  := $(COMMON_RPI3_DIR)/timer_asm.o
COMMON_RPI3_SMP_S        := $(COMMON_RPI3_DIR)/smp.S
COMMON_RPI3_SMP_O        := $(COMMON_RPI3_DIR)/smp.o
COMMON_RPI3_MAILBOX      := $(COMMON_RPI3_DIR)/mailbox.tkb
COMMON_RPI3_JTAG_STUB_S  := $(COMMON_RPI3_DIR)/jtag_stub.S
COMMON_RPI3_JTAG_STUB_O  := $(COMMON_RPI3_DIR)/jtag_stub.o
COMMON_RPI3_JTAG_STUB_LD := $(COMMON_RPI3_DIR)/jtag_stub.ld

$(COMMON_RPI3_STARTUP_O): $(COMMON_RPI3_STARTUP_S)
	$(LLVM_MC) --triple=$(RPI3_TARGET) --filetype=obj $< -o $@

$(COMMON_RPI3_MMU_O): $(COMMON_RPI3_MMU_S)
	$(LLVM_MC) --triple=$(RPI3_TARGET) --filetype=obj $< -o $@

$(COMMON_RPI3_TIMER_ASM_O): $(COMMON_RPI3_TIMER_ASM_S)
	$(LLVM_MC) --triple=$(RPI3_TARGET) --filetype=obj $< -o $@

$(COMMON_RPI3_SMP_O): $(COMMON_RPI3_SMP_S)
	$(LLVM_MC) --triple=$(RPI3_TARGET) --filetype=obj $< -o $@

$(COMMON_RPI3_JTAG_STUB_O): $(COMMON_RPI3_JTAG_STUB_S)
	$(LLVM_MC) --triple=$(RPI3_TARGET) --filetype=obj $< -o $@

## examples/common_rpi3/jtag_stub.img: the SD card's kernel8.img. Raw
## binary, not ELF -- the GPU firmware's loader expects a flat binary at a
## fixed address, not an ELF container.
examples/common_rpi3/jtag_stub.elf: $(COMMON_RPI3_JTAG_STUB_O) $(COMMON_RPI3_JTAG_STUB_LD)
	$(LLD) -T $(COMMON_RPI3_JTAG_STUB_LD) $(COMMON_RPI3_JTAG_STUB_O) -o $@

examples/common_rpi3/jtag_stub.img: examples/common_rpi3/jtag_stub.elf
	llvm-objcopy-19 -O binary $< $@

RPI3_EXAMPLES := start hello print_int print_hex print_ptr mem array \
                 fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump \
                 scheduler struct struct_refined refined narrow for loop enum nonexhaustive \
                 bitops align packed struct_align const_global sizeof_offsetof \
                 slice foreach int64 indexed_view tcp_conn_view \
                 klock_guard percpu \
                 affine_escape_via_index align_ptr_proof linear_obligation tuple_pair field_lease
RPI3_OBJS     := $(foreach e,$(RPI3_EXAMPLES),examples/$(e)/$(e)_rpi3.o)
# The working hardware baseline was committed before this flag was enabled.
# Keep every RPi3 group on one hardening switch so a newly added example or
# shared HAL cannot silently reintroduce a runtime bounds-check trap.
RPI3_TAKIBI_FLAGS := --forbid-trap

$(RPI3_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# inet_checksum.tkb/ip_parse.tkb/tcp_parse.tkb each `use` exactly the
# subset of inet_checksum.tkb/netutil.tkb they actually need themselves
# (same reasoning as the AArch64/QEMU CHECKSUM_OBJS group above), so
# neither is passed on the command line here, only listed as a
# prerequisite for Make's own staleness tracking.
RPI3_CHECKSUM_EXAMPLES := inet_checksum ip_parse tcp_parse
RPI3_CHECKSUM_OBJS     := $(foreach e,$(RPI3_CHECKSUM_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_CHECKSUM_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# examples/echo/echo.tkb and examples/irq/irq.tkb `use` COMMON_GIC_REGS
# themselves (GicRegs type only, for their own dead-here GICv2-shaped
# irq_dispatch() to type-check -- same reasoning as the STM32 build,
# see examples/common_rpi3/intc.tkb's header comment) -- so it's passed
# on the command line here too, alongside our own real
# COMMON_RPI3_INTC implementation.
RPI3_IRQ_EXAMPLES := echo irq
RPI3_IRQ_OBJS      := $(foreach e,$(RPI3_IRQ_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_IRQ_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_INTC) $(COMMON_GIC_REGS) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_INTC) $(COMMON_GIC_REGS) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# rtc.tkb/timer.tkb need read_cntfrq()/read_cntpct() (COMMON_RPI3_TIMER_ASM_O,
# an assembly stub -- mrs cannot be called directly from takibi), so they
# get their own link rule below (COMMON_RPI3_TIMER_ASM_O is an EXTRA link
# input, not one every RPi3 example needs) -- same reasoning as QEMU's own
# TIMER_KERNELS/GENERIC_KERNELS split further up this file. This board has
# no RTC peripheral at all; rtc.tkb reimplements the shared rtc_* HAL on
# the ARM Generic Timer's free-running counter instead (seconds-since-boot,
# not wall-clock -- see rtc.tkb's own header comment for the full
# rationale, agreed in GitHub issue #140).
RPI3_RTC_EXAMPLES := rtc timer
RPI3_RTC_OBJS     := $(foreach e,$(RPI3_RTC_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_RTC_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_RTC) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# Preemptive-scheduler group: examples/preempt/watchdog need no semaphore
# (RPI3_SCHED_EXAMPLES); examples/semaphore/condvar/msgqueue/rtos_demo
# additionally need sem_wait/sem_post linked in (RPI3_SCHED_SEM_EXAMPLES) --
# same TIMER_KERNELS/SEM_KERNELS split QEMU's own link section further up
# this file already uses, for the same reason. See examples/common_rpi3/
# AGENTS.md/timer.tkb's own header comment for why each of these files
# needs its own rpi3_irq_dispatch -- the scheduling DECISION is
# example-specific, unlike UART's uniformly-shared uart_irq_handler.
# Neither gic.tkb nor gic_regs.tkb is passed on the command line for
# preempt/watchdog/semaphore/condvar/msgqueue -- each of those files' own
# unconditional `use "examples/common_qemu/gic.tkb"` already brings both
# in for every target (matching the existing QEMU/STM32 Makefile
# comments' own reasoning for the same files); rtos_demo.tkb instead
# reaches the `gic` instance transitively through common/rtos.tkb's own
# `use "examples/common_qemu/gic_regs.tkb"` (types + the `gic` global,
# no functions -- see that file's own header comment), which is enough
# for its dead-here irq_dispatch to type-check without needing full
# gic.tkb explicitly either. COMMON_STM32_STUB supplies pendsv_trigger()
# (STM32-only, referenced by every one of these files' dead-here
# SysTick_Handler) -- reused as-is from the QEMU build's own identical
# need for the same files, see that variable's own comment further up.
RPI3_SCHED_EXAMPLES     := preempt watchdog
RPI3_SCHED_SEM_EXAMPLES := semaphore condvar msgqueue rtos_demo chan_rendezvous
RPI3_SCHED_OBJS         := $(foreach e,$(RPI3_SCHED_EXAMPLES) $(RPI3_SCHED_SEM_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_SCHED_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_DIR)/timer.tkb $(COMMON_STM32_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_DIR)/timer.tkb $(COMMON_STM32_STUB) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# First real SMP milestone (GitHub issue #6).  Its working unrefined baseline
# was committed before this dedicated rule gained --forbid-trap, preserving
# the repository's baseline-then-hardening history.  The assembly shim gives
# core 1 a dedicated entry/stack; sem_asm supplies the cross-core atomic mutex.
examples/smp_handoff/smp_handoff_rpi3.o: examples/smp_handoff/smp_handoff.tkb \
    $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_SYNC) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) --forbid-trap -o $@

# USB bring-up group (GitHub issue #140's Ethernet milestone -- see
# examples/usb_probe/usb_probe.tkb's own header comment and
# examples/common_rpi3/AGENTS.md for the full plan). Grows one milestone
# at a time; as of milestone 2 needs COMMON_RPI3_MAILBOX (milestone 1)
# and COMMON_RPI3_DIR/usb_dwc2.tkb (milestone 2, itself reusing
# read_cntfrq()/read_cntpct() for delay_ms -- hence COMMON_RPI3_TIMER_ASM_O
# joining this group's link line below, same stubs the RTC/scheduler
# groups already share) on the command line. The mailbox/USB DMA
# cache-coherency calls (examples/common_rpi3/mailbox.tkb, usb_dwc2.tkb)
# are the compiler's own dma_prepare_tx/dma_finish_rx builtins (GitHub
# issue #146) -- no extra link input needed for those, unlike the
# hand-written cache_asm.S stub this group used to also need.
RPI3_USB_EXAMPLES := usb_probe
RPI3_USB_OBJS     := $(foreach e,$(RPI3_USB_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_USB_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/lan9514.tkb $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/lan9514.tkb $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# Ethernet group (milestone 6-7): examples/common_rpi3/eth.tkb wraps the
# whole USB bring-up chain above behind the same net_init/net_rx_*/
# net_transmit API examples/common_stm32/eth.tkb and
# examples/common_qemu/virtio_mmio.tkb expose, so net_echo.tkb and
# siblings compile against it unmodified -- same command-line-args-vs-
# prerequisites split those two targets already use (COMMON_RPI3_ETH
# alone on the command line; netconfig.tkb/netutil.tkb are pulled in
# transitively via its own `use` lines, listed here only so Make's
# staleness tracking notices when they change).
COMMON_RPI3_ETH       := $(COMMON_RPI3_DIR)/eth.tkb
COMMON_RPI3_NETCONFIG := $(COMMON_RPI3_DIR)/netconfig.tkb
RPI3_NET_EXAMPLES := net_echo arp_reply icmp_echo tcp_echo http_server kvs_server
RPI3_NET_OBJS     := $(foreach e,$(RPI3_NET_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_NET_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/lan9514.tkb $(COMMON_RPI3_ETH) $(COMMON_RPI3_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_HTTP_SERVER) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/lan9514.tkb $(COMMON_RPI3_ETH) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_TAKIBI_FLAGS) -o $@

# USB Mass Storage group (GitHub issue #145, the storage follow-on to the
# Ethernet milestone above): examples/common_rpi3/usb_msc.tkb -- new,
# unproven-on-real-hardware code as of this milestone (Bulk-Only
# Transport + SCSI-10 over this board's DWC2 host stack). Per root
# AGENTS.md's "Development Process" (new .tkb work first WITHOUT
# --forbid-trap, hardened in one later pass once the whole milestone
# works end to end -- same as the Ethernet milestone's own history, see
# HISTORY.md's "RPi3 --forbid-trap hardening pass" entry), this group
# deliberately does NOT use $(RPI3_TAKIBI_FLAGS) yet.
RPI3_MSC_TAKIBI_FLAGS :=
RPI3_MSC_EXAMPLES := usb_msc_probe
RPI3_MSC_OBJS     := $(foreach e,$(RPI3_MSC_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_MSC_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_MSC_TAKIBI_FLAGS) -o $@

# fatfs-family group (GitHub issue #145's own follow-on): shared example
# sources (fatfs_sdcard.tkb today, more to follow) that `use` fat12.tkb
# transitively through whichever storage adapter is on the command line --
# see fatfs_sdcard.tkb's own header comment. COMMON_RPI3_FAT12_USBMSC
# itself only `use`s fat12.tkb + usb_msc.tkb; usb_msc.tkb's own further
# dependencies (mailbox/usb_dwc2/usb_hub) still need to be listed
# explicitly, same as the plain RPI3_MSC_OBJS rule above. Same
# not-yet-`--forbid-trap` reasoning as that group -- this shared example
# source is already hardened (proven on STM32), but usb_msc.tkb
# underneath is not yet, so the flag stays off for the whole build
# command until this milestone's own later hardening pass.
COMMON_RPI3_FAT12_USBMSC := $(COMMON_RPI3_DIR)/fat12_usbmsc.tkb
RPI3_FATFS_EXAMPLES := fatfs_sdcard
RPI3_FATFS_OBJS     := $(foreach e,$(RPI3_FATFS_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_FATFS_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_RPI3_FAT12_USBMSC) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_RPI3_FAT12_USBMSC) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_MSC_TAKIBI_FLAGS) -o $@

# rtos_fatfs_sdcard (RPi3): the fatfs-family adapter above PLUS the
# scheduler group's timer.tkb/COMMON_STM32_STUB (same combination
# RPI3_SCHED_OBJS uses) -- the first RPi3 build to ever combine the
# scheduler HAL with the USB HAL on one command line. This surfaced a
# real latent bug: examples/common_rpi3/timer.tkb and usb_dwc2.tkb (and
# rtc.tkb) each used to declare their own `extern fn read_cntfrq`
# locally; takibi rejects a second declaration of the same extern
# symbol even with a matching signature, so combining any two used to be
# a hard conflict. Fixed by factoring that declaration out into
# examples/common_rpi3/timer_asm_extern.tkb, `use`d by all three now
# (same fix shape as gic_regs.tkb's own split, GitHub issue #79
# follow-up, for the identical class of problem).
RPI3_FATFS_RTOS_EXAMPLES := rtos_fatfs_sdcard
RPI3_FATFS_RTOS_OBJS     := $(foreach e,$(RPI3_FATFS_RTOS_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

$(RPI3_FATFS_RTOS_OBJS): examples/%_rpi3.o: examples/%.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_DIR)/timer.tkb $(COMMON_STM32_STUB) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_RPI3_FAT12_USBMSC) $(COMMON_SYNC) $(COMMON_RTOS) $(COMMON_GIC_REGS) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_DIR)/timer.tkb $(COMMON_STM32_STUB) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_RPI3_FAT12_USBMSC) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_MSC_TAKIBI_FLAGS) -o $@

# http_server_sdcard (RPi3): the network HAL AND the storage backend on
# one command line -- both go through the same DWC2 USB host stack, made
# concurrent by usb_dwc2.tkb's per-device bulk slots + usb_host.tkb's
# shared enumeration (see those files' own comments). The installer is
# storage-only (no eth); its harness side is
# scripts/rpi3_provision_http_server_sdcard.sh.
RPI3_HTTP_SDCARD_EXAMPLES := http_server_sdcard http_server_sdcard_install
RPI3_HTTP_SDCARD_OBJS     := $(foreach e,$(RPI3_HTTP_SDCARD_EXAMPLES),examples/$(e)/$(e)_rpi3.o)

examples/http_server_sdcard/http_server_sdcard_rpi3.o: examples/http_server_sdcard/http_server_sdcard.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/lan9514.tkb $(COMMON_RPI3_ETH) $(COMMON_RPI3_NETCONFIG) $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_RPI3_FAT12_USBMSC) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(COMMON_FAT12_GEOMETRY) $(COMMON_FAT12) $(COMMON_HTTP_SERVER) $(COMMON_HTTP_SDCARD) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/lan9514.tkb $(COMMON_RPI3_ETH) $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_RPI3_FAT12_USBMSC) $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_MSC_TAKIBI_FLAGS) -o $@

examples/http_server_sdcard_install/http_server_sdcard_install_rpi3.o: examples/http_server_sdcard_install/http_server_sdcard_install.tkb $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $(COMMON_FAT12_GEOMETRY) $(TAKIBI)
	$(TAKIBI) $(COMMON_RPI3_UART) $(COMMON_RPI3_PRINT) $(COMMON_RPI3_MAILBOX) $(COMMON_RPI3_DIR)/usb_dwc2.tkb $(COMMON_RPI3_DIR)/usb_hub.tkb $(COMMON_RPI3_DIR)/usb_host.tkb $(COMMON_RPI3_DIR)/usb_msc.tkb $< --target $(RPI3_TARGET) --cpu $(RPI3_CPU) $(RPI3_MSC_TAKIBI_FLAGS) -o $@

RPI3_EXAMPLES += $(RPI3_CHECKSUM_EXAMPLES) $(RPI3_IRQ_EXAMPLES) $(RPI3_RTC_EXAMPLES) $(RPI3_SCHED_EXAMPLES) $(RPI3_SCHED_SEM_EXAMPLES) $(RPI3_USB_EXAMPLES) $(RPI3_NET_EXAMPLES) $(RPI3_MSC_EXAMPLES) $(RPI3_FATFS_EXAMPLES) $(RPI3_FATFS_RTOS_EXAMPLES) $(RPI3_HTTP_SDCARD_EXAMPLES)
RPI3_KERNELS       := $(foreach e,$(RPI3_EXAMPLES),examples/$(e)/kernel_rpi3.elf)
# rtc/timer/preempt/watchdog need COMMON_RPI3_TIMER_ASM_O linked in
# (read_cntfrq() and friends -- mrs cannot be called directly from
# takibi); semaphore/condvar/msgqueue/rtos_demo need that PLUS
# $(COMMON_SEM_ASM_O) for sem_wait/sem_post -- reused as-is from the QEMU
# build (examples/common_qemu/sem_asm.S is pure ldaxr/stlxr AArch64
# architecture code with no QEMU-specific addressing, and RPI3_TARGET is
# the same aarch64-none-elf triple as AARCH64_TARGET, so the QEMU-built
# object is directly link-compatible -- same reasoning already applied to
# COMMON_STM32_STUB/COMMON_RPI3_STUB's own cross-target reuse above).
# usb_probe/net examples need COMMON_RPI3_TIMER_ASM_O too (delay_ms, see
# the USB bring-up group comment above) -- same link line as rtc/timer/
# preempt/watchdog, so they join that same kernel group below rather
# than getting their own (this group used to also need a separate
# COMMON_RPI3_CACHE_ASM_O; retired once mailbox.tkb/usb_dwc2.tkb moved
# to the compiler's own dma_prepare_tx/dma_finish_rx builtins, GitHub
# issue #146). Everything else uses the plain startup.o+mmu.o link line.
RPI3_TIMER_ASM_KERNELS := $(foreach e,$(RPI3_RTC_EXAMPLES) $(RPI3_SCHED_EXAMPLES) $(RPI3_USB_EXAMPLES) $(RPI3_NET_EXAMPLES) $(RPI3_MSC_EXAMPLES) $(RPI3_FATFS_EXAMPLES) $(RPI3_HTTP_SDCARD_EXAMPLES),examples/$(e)/kernel_rpi3.elf)
RPI3_SEM_KERNELS       := $(foreach e,$(RPI3_SCHED_SEM_EXAMPLES) $(RPI3_FATFS_RTOS_EXAMPLES),examples/$(e)/kernel_rpi3.elf)
RPI3_GENERIC_KERNELS   := $(filter-out $(RPI3_TIMER_ASM_KERNELS) $(RPI3_SEM_KERNELS),$(RPI3_KERNELS))

$(RPI3_GENERIC_KERNELS): examples/%/kernel_rpi3.elf: \
    $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) examples/%/$$*_rpi3.o $(COMMON_RPI3_LINK_LD)
	$(LLD) -T $(COMMON_RPI3_LINK_LD) $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) examples/$*/$*_rpi3.o -o $@

$(RPI3_TIMER_ASM_KERNELS): examples/%/kernel_rpi3.elf: \
    $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) $(COMMON_RPI3_TIMER_ASM_O) examples/%/$$*_rpi3.o $(COMMON_RPI3_LINK_LD)
	$(LLD) -T $(COMMON_RPI3_LINK_LD) $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) $(COMMON_RPI3_TIMER_ASM_O) examples/$*/$*_rpi3.o -o $@

$(RPI3_SEM_KERNELS): examples/%/kernel_rpi3.elf: \
    $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) $(COMMON_RPI3_TIMER_ASM_O) $(COMMON_SEM_ASM_O) examples/%/$$*_rpi3.o $(COMMON_RPI3_LINK_LD)
	$(LLD) -T $(COMMON_RPI3_LINK_LD) $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) $(COMMON_RPI3_TIMER_ASM_O) $(COMMON_SEM_ASM_O) examples/$*/$*_rpi3.o -o $@

examples/smp_handoff/kernel_rpi3.elf: $(COMMON_RPI3_STARTUP_O) \
    $(COMMON_RPI3_MMU_O) $(COMMON_RPI3_SMP_O) $(COMMON_SEM_ASM_O) \
    examples/smp_handoff/smp_handoff_rpi3.o $(COMMON_RPI3_LINK_LD)
	$(LLD) -T $(COMMON_RPI3_LINK_LD) $(COMMON_RPI3_STARTUP_O) $(COMMON_RPI3_MMU_O) $(COMMON_RPI3_SMP_O) $(COMMON_SEM_ASM_O) examples/smp_handoff/smp_handoff_rpi3.o -o $@

## hwcheck-rpi3: run Raspberry Pi 3B (BCM2837) hardware integration tests
## (requires a real Raspberry Pi 3B connected via JTAG + UART -- see
## examples/common_rpi3/AGENTS.md). NOT part of `make check`/`make allcheck`:
## unlike hwcheck-stm32, this cannot fully reset the board itself (no wired
## JTAG system reset line on this board, see scripts/rpi3_jtag_load.sh's
## header comment), so it needs the board already sitting in
## examples/common_rpi3/jtag_stub.S's spin loop (a manual power cycle after
## flashing examples/common_rpi3/jtag_stub.img as kernel8.img) before the
## first run -- board-state-dependent hardware preconditions like this are
## why hwcheck-stm32 itself, and stress-stm32-kvs-server-sdcard-rtos, also
## stay out of check/allcheck.
hwcheck-rpi3: $(RPI3_KERNELS) examples/smp_handoff/kernel_rpi3.elf examples/common_rpi3/jtag_stub.img
	@bash scripts/run_hwtest_rpi3.sh

## hwcheck-rpi3-net: run all RPi3 real-Ethernet hardware tests (net_echo/
## arp_reply/icmp_echo/tcp_echo/http_server/kvs_server -- see
## scripts/run_hwtest_rpi3_net.sh) over a physical point-to-point link to
## the Raspberry Pi 3B (requires the board's Ethernet port, behind the
## LAN9514 USB hub -- see examples/common_rpi3/AGENTS.md's "USB host
## stack" section -- wired directly to this machine's NIC). Same split
## as hwcheck-stm32/hwcheck-stm32-net and the same reasons: NOT part of
## hwcheck-rpi3's UART-diff suite, and NOT part of `make check`/`make
## allcheck` -- these are network tests (raw AF_PACKET sockets), not a
## UART capture/diff, and need CAP_NET_RAW (run with sudo, which
## scripts/run_hwtest_rpi3_net.sh already does for the Python side only
## -- JTAG itself must never run under sudo in this devcontainer, see
## that script's own header comment) plus ETH_TEST_IFACE/ETH_TEST_SUBNET/
## ETH_TEST_MAC set to the wired interface/this board's own address if
## they differ from the defaults.
hwcheck-rpi3-net: $(RPI3_KERNELS) examples/common_rpi3/jtag_stub.img
	@bash scripts/run_hwtest_rpi3_net.sh

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts and linker outputs
clean:
	dune clean
	find examples -type f \( -name '*.o' -o -name '*.elf' -o -name '*.bin' -o -name '*.exe' -o -name '*.img' \) -delete
