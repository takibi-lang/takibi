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

# -- Shared AArch64 bare-metal support files -----------------------------------
COMMON_DIR         := examples/common
COMMON_STARTUP_S   := $(COMMON_DIR)/startup.S
COMMON_STARTUP_O   := $(COMMON_DIR)/startup.o
COMMON_TIMER_ASM_S := $(COMMON_DIR)/timer_asm.S
COMMON_TIMER_ASM_O := $(COMMON_DIR)/timer_asm.o
COMMON_SEM_ASM_S   := $(COMMON_DIR)/sem_asm.S
COMMON_SEM_ASM_O   := $(COMMON_DIR)/sem_asm.o
COMMON_LINK_LD     := $(COMMON_DIR)/link.ld
COMMON_UART        := $(COMMON_DIR)/uart.tkb
COMMON_PRINT       := $(COMMON_DIR)/print.tkb
COMMON_GIC         := $(COMMON_DIR)/gic.tkb
COMMON_TIMER       := $(COMMON_DIR)/timer.tkb
COMMON_SYNC        := $(COMMON_DIR)/sync.tkb
COMMON_VIRTIO_MMIO := $(COMMON_DIR)/virtio_mmio.tkb
COMMON_INET_CKSUM  := $(COMMON_DIR)/inet_checksum.tkb
COMMON_NETUTIL     := $(COMMON_DIR)/netutil.tkb
COMMON_RTC         := $(COMMON_DIR)/rtc.tkb
COMMON_UART_GETC   := $(COMMON_DIR)/uart_getc.tkb
COMMON_NETCONFIG   := $(COMMON_DIR)/netconfig.tkb
COMMON_STM32_STUB  := $(COMMON_DIR)/stm32_stub.tkb

# -- Examples ------------------------------------------------------------------
# To add a new example, just append its name here.
# Convention: examples/<name>/<name>.tkb -> examples/<name>/kernel.elf
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined narrow for loop enum nonexhaustive bitops align packed struct_align const_global sizeof_offsetof slice foreach int64 net_echo arp_reply inet_checksum ip_parse icmp_echo tcp_parse tcp_echo http_server
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
                  scheduler struct refined narrow for loop enum nonexhaustive \
                  bitops align packed struct_align const_global sizeof_offsetof slice foreach int64
STM32_OBJS     := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/$(e)_stm32.o)
STM32_KERNELS  := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/kernel_stm32.elf)
STM32_BINS     := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/kernel_stm32.bin)
# rtc/echo/timer: ported separately (real RTC peripheral / bidirectional
# serial test / rtc.tkb HAL reuse), each needs one extra common file beyond
# uart+print -- see the one-off rules near COMMON_STM32_RTC/
# COMMON_STM32_UART_GETC below.
STM32_EXTRA_BINS := examples/rtc/kernel_stm32.bin examples/echo/kernel_stm32.bin \
                    examples/timer/kernel_stm32.bin examples/irq/kernel_stm32.bin \
                    examples/preempt/kernel_stm32.bin examples/semaphore/kernel_stm32.bin \
                    examples/condvar/kernel_stm32.bin examples/msgqueue/kernel_stm32.bin \
                    examples/watchdog/kernel_stm32.bin examples/net_echo/kernel_stm32.bin \
                    examples/arp_reply/kernel_stm32.bin examples/icmp_echo/kernel_stm32.bin \
                    examples/tcp_echo/kernel_stm32.bin examples/http_server/kernel_stm32.bin

# inet_checksum/ip_parse/tcp_parse: same CHECKSUM_OBJS group as the AArch64
# side, but examples/common/inet_checksum.tkb and examples/common/netutil.tkb
# are pure compute with no MMIO addresses at all (unlike uart.tkb) -- so
# unlike rtc/echo, no STM32-specific version of either is needed, both are
# reused completely unchanged. Kept as their own small group (not folded
# into STM32_EXAMPLES) since the recipe needs two extra common files that
# the rest of STM32_EXAMPLES doesn't.
STM32_CHECKSUM_EXAMPLES := inet_checksum ip_parse tcp_parse
STM32_CHECKSUM_OBJS     := $(foreach e,$(STM32_CHECKSUM_EXAMPLES),examples/$(e)/$(e)_stm32.o)
STM32_CHECKSUM_KERNELS  := $(foreach e,$(STM32_CHECKSUM_EXAMPLES),examples/$(e)/kernel_stm32.elf)
STM32_CHECKSUM_BINS     := $(foreach e,$(STM32_CHECKSUM_EXAMPLES),examples/$(e)/kernel_stm32.bin)

# -- Targets ------------------------------------------------------------------
.PHONY: build test qemutest stm32build hwcheck hwcheck-net langcheck check clean qemu-echo qemu-net-echo qemu-arp-reply qemu-icmp-echo qemu-tcp-echo qemu-http-server stm32-http-server profile-http-server profile-tcp-echo

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

## qemutest: run QEMU integration tests (build all examples and verify automatically)
qemutest: $(ALL_KERNELS) examples/fizzbuzz/kernel.debug.elf examples/fibonacci/kernel.debug.elf
	@bash scripts/run_qemutest.sh

## stm32build: compile every ported STM32 example to a linked .bin, with no
## flashing/serial capture -- unlike hwcheck, this needs no physical
## hardware (only the same LLVM toolchain qemutest already requires), so it
## IS part of `make check`: it's the only thing that would otherwise catch
## a compiler regression breaking Cortex-M/Thumb2 codegen specifically
## (qemutest only ever exercises the aarch64-none-elf path).
stm32build: $(STM32_BINS) $(STM32_EXTRA_BINS) $(STM32_CHECKSUM_BINS)

## hwcheck: run STM32 hardware integration tests (requires a real
## STM32F746G-DISCOVERY board connected via USB). NOT part of `make check` --
## unlike stm32build, this needs physical hardware, so it stays runnable-
## only-when-available rather than a requirement for every clone of this repo.
hwcheck: stm32build
	@bash scripts/run_hwtest.sh

## hwcheck-net: run all STM32 real-Ethernet hardware tests (net_echo today,
## more as they're ported -- see scripts/run_hwtest_net.sh) over a physical
## point-to-point link to the STM32F746G-DISCOVERY board (requires the
## board's Ethernet port wired directly to this machine's NIC). NOT part of
## hwcheck's automated UART-diff suite, and NOT part of `make check`/
## `make hwcheck` -- these are network tests (raw AF_PACKET sockets), not a
## UART capture/diff, and need CAP_NET_RAW (run with sudo) plus
## ETH_TEST_IFACE set to the wired interface if it isn't the default.
hwcheck-net: stm32build
	@bash scripts/run_hwtest_net.sh

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

## check: run unit tests + QEMU integration tests + STM32 build check + ASCII check
check: langcheck test stm32build qemutest

# -- Shared assembly objects ---------------------------------------------------
$(COMMON_STARTUP_O): $(COMMON_STARTUP_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

$(COMMON_TIMER_ASM_O): $(COMMON_TIMER_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

$(COMMON_SEM_ASM_O): $(COMMON_SEM_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

# -- .tkb -> .o  (static pattern rules) ----------------------------------------
# For examples/%.o, % matches "name/name" (including the slash).
# Example: examples/start/start.o <- examples/start/start.tkb
#
# Common file sets passed to takibi:
#   Standard   : uart.tkb + print.tkb                        (most examples)
#   IRQ group  : + gic.tkb                                   (irq)
#   Timer group: + gic.tkb + timer.tkb                       (preempt semaphore watchdog)
#   Sync group : + gic.tkb + timer.tkb + sync.tkb            (condvar msgqueue)
#   Net group  : + gic.tkb + virtio_mmio.tkb + netutil.tkb  (net_echo, arp_reply)
#   Checksum group: + inet_checksum.tkb + netutil.tkb       (inet_checksum, ip_parse, tcp_parse)
#   App group  : + gic.tkb + virtio_mmio.tkb + inet_checksum.tkb + netutil.tkb (icmp_echo, tcp_echo, http_server)
.SECONDEXPANSION:

IRQ_OBJS   := examples/irq/irq.o
# semaphore.tkb declares its own extern fn sem_wait/sem_post, so no sync.tkb needed here
TIMER_OBJS := examples/preempt/preempt.o examples/semaphore/semaphore.o \
              examples/watchdog/watchdog.o
SYNC_OBJS  := examples/condvar/condvar.o examples/msgqueue/msgqueue.o
NET_OBJS   := examples/net_echo/net_echo.o examples/arp_reply/arp_reply.o
CHECKSUM_OBJS := examples/inet_checksum/inet_checksum.o examples/ip_parse/ip_parse.o \
                 examples/tcp_parse/tcp_parse.o
APP_OBJS   := examples/icmp_echo/icmp_echo.o examples/tcp_echo/tcp_echo.o \
              examples/http_server/http_server.o
# rtc/echo each need one extra common file (rtc.tkb / uart_getc.tkb) beyond
# the standard uart+print pair, so neither fits STANDARD_OBJS -- same
# single-member-group treatment as IRQ_OBJS. timer.tkb turned out to need
# the same rtc.tkb HAL as rtc itself (not gic.tkb/timer.tkb -- it just polls
# the RTC directly, unlike TIMER_OBJS below which is unrelated), so it
# joins this group too.
RTC_OBJS   := examples/rtc/rtc.o examples/timer/timer.o
GETC_OBJS  := examples/echo/echo.o
SPECIAL_OBJS := $(IRQ_OBJS) $(TIMER_OBJS) $(SYNC_OBJS) $(NET_OBJS) $(CHECKSUM_OBJS) $(APP_OBJS) \
                $(RTC_OBJS) $(GETC_OBJS)
STANDARD_OBJS := $(filter-out $(SPECIAL_OBJS), $(EXAMPLE_OBJS))

$(STANDARD_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -o $@

# COMMON_GIC is needed because examples/irq/irq.tkb is now a single file
# shared with the STM32 build -- see that file's header comment. Both
# platforms' interrupt entry points are compiled regardless of target;
# COMMON_GIC supplies the QEMU-only gic struct/functions the (real, active)
# irq_dispatch entry point references.
$(IRQ_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $< --target $(AARCH64_TARGET) -o $@

$(RTC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_RTC) $< --target $(AARCH64_TARGET) -o $@

$(GETC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_UART_GETC) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_UART_GETC) $< --target $(AARCH64_TARGET) -o $@

# COMMON_STM32_STUB supplies pendsv_trigger() (a no-op here) so each of
# these shared examples' STM32-shaped SysTick_Handler/pendsv_dispatch
# entry points (dead code under QEMU) still compile -- see
# examples/preempt/preempt.tkb's header comment.
$(TIMER_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_STM32_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_STM32_STUB) $< --target $(AARCH64_TARGET) -o $@

$(SYNC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) $(COMMON_STM32_STUB) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) $(COMMON_STM32_STUB) $< --target $(AARCH64_TARGET) -o $@

# COMMON_NETCONFIG (OUR_IP) is unused-but-harmless for net_echo (no
# IP awareness at all) -- it just gets one inert extra constant rather than
# needing a split recipe group of its own. GIC is no longer needed at all:
# virtio_mmio.tkb polls the used ring directly now instead of routing
# through an interrupt (see that file's header comment).
$(NET_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_NETUTIL) $< --target $(AARCH64_TARGET) -o $@

$(CHECKSUM_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(AARCH64_TARGET) -o $@

$(APP_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(AARCH64_TARGET) -o $@

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
                 examples/condvar/kernel.elf examples/msgqueue/kernel.elf
GENERIC_KERNELS := $(filter-out $(TIMER_KERNELS) $(SEM_KERNELS), $(ALL_KERNELS))

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

# -- DWARF debug-info regression check ------------------------------------------
# A dedicated -g build of ONE example (fizzbuzz), entirely separate from the
# always-g-free rules above (its own .debug.o / kernel.debug.elf, so it can't
# collide with or affect examples/fizzbuzz/kernel.elf). Exists so that
# scripts/run_qemutest.sh's run_dwarf_test can verify the emitted DWARF line
# table actually resolves to the correct source line (via llvm-dwarfdump-19
# and addr2line), using fizzbuzz.tkb's fixed, well-known shape (fn main() at
# line 3, for at line 4, final uart_puts at line 13) as the expected answer.
examples/fizzbuzz/fizzbuzz.debug.o: examples/fizzbuzz/fizzbuzz.tkb $(COMMON_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -g -o $@

examples/fizzbuzz/kernel.debug.elf: $(COMMON_STARTUP_O) examples/fizzbuzz/fizzbuzz.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/fizzbuzz/fizzbuzz.debug.o -o $@

# Same pattern, second example (fibonacci): its `let mut a/b/tmp` locals and
# uart_putc's `c` parameter (uart.tkb is compiled in alongside it, same as
# the no-debug build) give run_dwarf_var_test something to check that
# fizzbuzz -- which has no `let mut` of its own -- doesn't exercise.
examples/fibonacci/fibonacci.debug.o: examples/fibonacci/fibonacci.tkb $(COMMON_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -g -o $@

examples/fibonacci/kernel.debug.elf: $(COMMON_STARTUP_O) examples/fibonacci/fibonacci.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/fibonacci/fibonacci.debug.o -o $@

# Third dedicated -g build, this time for the "App group" common files
# (see the compilation-groups comment above IRQ_OBJS): needed so
# scripts/profile_http_server.py has DWARF line info to resolve sampled
# addresses against. Not part of `make check`/`qemutest` -- profiling is an
# exploratory dev activity, not a pass/fail regression (same reasoning as
# the manual qemu-* targets below).
examples/http_server/http_server.debug.o: examples/http_server/http_server.tkb \
    $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) \
	          $< --target $(AARCH64_TARGET) -g -o $@

examples/http_server/kernel.debug.elf: $(COMMON_STARTUP_O) examples/http_server/http_server.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/http_server/http_server.debug.o -o $@

# Same, for tcp_echo -- profile_http_server.py's profile landed ~100% in the
# idle interrupt-wait loop (network round trips dominate wall-clock time at
# the HTTP layer), so scripts/profile_tcp_echo.py profiles one layer down
# with a workload built to keep the server continuously busy instead.
examples/tcp_echo/tcp_echo.debug.o: examples/tcp_echo/tcp_echo.tkb \
    $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_VIRTIO_MMIO) $(COMMON_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) \
	          $< --target $(AARCH64_TARGET) -g -o $@

examples/tcp_echo/kernel.debug.elf: $(COMMON_STARTUP_O) examples/tcp_echo/tcp_echo.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/tcp_echo/tcp_echo.debug.o -o $@

# -- STM32F746G-DISCOVERY hardware bring-up (step 2/2b: pure-compute examples) --
# Covers every example that only needs examples/common/uart.tkb +
# examples/common/print.tkb on the AArch64 side (i.e. STANDARD_OBJS), minus
# two deliberately excluded for reasons unrelated to "is it portable":
#   - rtc: pokes the QEMU-only PL031 RTC address directly, no STM32 RTC
#     peripheral support exists yet (separate task, different peripheral
#     entirely from anything ported so far).
#   - echo: defines its own uart_getc() against the QEMU-only PL011 FR
#     register, and its test methodology needs writing bytes to the serial
#     port (interactive stdin), not just reading -- scripts/run_hwtest.sh
#     only supports the read-and-diff shape today.
# Every other STANDARD_OBJS example is pure compute + uart_puts/uart_print_*
# output with no interrupt/timer/hand-written-assembly dependency (confirmed
# by inspection before adding this list), so all of them reuse
# examples/common_stm32/uart.tkb + examples/common/print.tkb exactly like
# examples/hello/hello.tkb did in the first STM32 port, and their existing
# .expected files (already used by the AArch64/QEMU run_test calls below) are
# reused unchanged -- uart_puts/uart_print_* write the exact same bytes on
# either HAL.
# (STM32_TARGET/STM32_CPU/STM32_EXAMPLES/STM32_OBJS/STM32_KERNELS/STM32_BINS
# are defined near the top of this file, alongside EXAMPLES/ALL_KERNELS, so
# that hwcheck's prerequisite list further up can reference them.)
COMMON_STM32_DIR       := examples/common_stm32
COMMON_STM32_STARTUP_S := $(COMMON_STM32_DIR)/startup.S
COMMON_STM32_STARTUP_O := $(COMMON_STM32_DIR)/startup.o
COMMON_STM32_LINK_LD   := $(COMMON_STM32_DIR)/link.ld
COMMON_STM32_UART      := $(COMMON_STM32_DIR)/uart.tkb
# eth.tkb's DMA descriptor rings/buffers need AXI SRAM, not the DTCM every
# other STM32 example links into -- see link_eth.ld's own comment.
COMMON_STM32_LINK_ETH_LD := $(COMMON_STM32_DIR)/link_eth.ld

$(COMMON_STM32_STARTUP_O): $(COMMON_STM32_STARTUP_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

$(STM32_OBJS): examples/%_stm32.o: examples/%.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

$(STM32_KERNELS): examples/%/kernel_stm32.elf: \
    $(COMMON_STM32_STARTUP_O) examples/%/$$*_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/$*/$*_stm32.o -o $@

$(STM32_BINS): examples/%/kernel_stm32.bin: examples/%/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# rtc and echo each need one extra STM32-specific common file beyond the
# standard uart+print pair (real RTC peripheral driver / USART1 RX poll),
# so -- like their AArch64-side RTC_OBJS/GETC_OBJS counterparts -- they get
# their own one-off rule pairs rather than joining the generic
# STM32_EXAMPLES loop above.
COMMON_STM32_RTC       := $(COMMON_STM32_DIR)/rtc.tkb
COMMON_STM32_UART_GETC := $(COMMON_STM32_DIR)/uart_getc.tkb
COMMON_STM32_NVIC      := $(COMMON_STM32_DIR)/nvic.tkb
COMMON_STM32_SCHEDULER := $(COMMON_STM32_DIR)/scheduler.tkb
COMMON_STM32_SEM_ASM_S := $(COMMON_STM32_DIR)/sem_asm.S
COMMON_STM32_SEM_ASM_O := $(COMMON_STM32_DIR)/sem_asm.o

$(COMMON_STM32_SEM_ASM_O): $(COMMON_STM32_SEM_ASM_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

examples/rtc/rtc_stm32.o: examples/rtc/rtc.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_RTC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/rtc/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/rtc/rtc_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/rtc/rtc_stm32.o -o $@

examples/rtc/kernel_stm32.bin: examples/rtc/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# timer: turned out (during the interrupt-batch research) to need exactly
# the same rtc.tkb HAL as rtc itself, not any interrupt/scheduler
# infrastructure -- see examples/timer/timer.tkb's own comment.
examples/timer/timer_stm32.o: examples/timer/timer.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_RTC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_RTC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/timer/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/timer/timer_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/timer/timer_stm32.o -o $@

examples/timer/kernel_stm32.bin: examples/timer/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/echo/echo_stm32.o: examples/echo/echo.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_UART_GETC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_UART_GETC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/echo/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/echo/echo_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/echo/echo_stm32.o -o $@

examples/echo/kernel_stm32.bin: examples/echo/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# irq/preempt/semaphore/condvar/watchdog/msgqueue: each compiles the *same*
# examples/<name>/<name>.tkb file the QEMU build uses (see
# examples/net_echo/net_echo.tkb's header comment for the general pattern,
# and examples/irq/irq.tkb / examples/preempt/preempt.tkb's header comments
# for how GICv2-vs-NVIC dispatch is unified despite the two hardware models
# genuinely differing). COMMON_GIC is included for all six (harmless,
# unused on this target) so the QEMU-shaped entry point in each shared file
# still compiles -- see examples/common/stm32_stub.tkb's comment for the
# other half of that (QEMU needing STM32-only stand-ins).
#
# irq: NVIC vectors directly to USART1_IRQHandler, a fundamentally
# different dispatch model from GICv2's software IAR/EOIR table.
examples/irq/irq_stm32.o: examples/irq/irq.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_NVIC) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_NVIC) $(COMMON_GIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/irq/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/irq/irq_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/irq/irq_stm32.o -o $@

examples/irq/kernel_stm32.bin: examples/irq/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# preempt: PendSV_Handler lives directly in the always-shared
# common_stm32/startup.S (unlike a separate optional assembly object) --
# harmless for every other example since nothing triggers PENDSVSET unless
# a program enables SysTick, so no extra object needs linking here beyond
# the usual startup.o.
examples/preempt/preempt_stm32.o: examples/preempt/preempt.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/preempt/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/preempt/preempt_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/preempt/preempt_stm32.o -o $@

examples/preempt/kernel_stm32.bin: examples/preempt/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# semaphore: same scheduler restructure as preempt; declares its own extern
# fn sem_wait/sem_post (no sync.tkb needed, same as the AArch64 version),
# links against the STM32 sem_asm.o (ldrex/strex, not ldaxr/stlxr).
examples/semaphore/semaphore_stm32.o: examples/semaphore/semaphore.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/semaphore/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/semaphore/semaphore_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/semaphore/semaphore_stm32.o -o $@

examples/semaphore/kernel_stm32.bin: examples/semaphore/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# condvar/msgqueue: same scheduler restructure, plus reuse
# examples/common/sync.tkb completely unchanged (pure takibi logic calling
# only sem_wait/sem_post), linked against the STM32 sem_asm.o.
examples/condvar/condvar_stm32.o: examples/condvar/condvar.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_GIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/condvar/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/condvar/condvar_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/condvar/condvar_stm32.o -o $@

examples/condvar/kernel_stm32.bin: examples/condvar/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/msgqueue/msgqueue_stm32.o: examples/msgqueue/msgqueue.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_SYNC) $(COMMON_GIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/msgqueue/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/msgqueue/msgqueue_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_SEM_ASM_O) examples/msgqueue/msgqueue_stm32.o -o $@

examples/msgqueue/kernel_stm32.bin: examples/msgqueue/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# watchdog: same scheduler restructure as preempt, no semaphore needed.
examples/watchdog/watchdog_stm32.o: examples/watchdog/watchdog.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_SCHEDULER) $(COMMON_GIC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/watchdog/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/watchdog/watchdog_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/watchdog/watchdog_stm32.o -o $@

examples/watchdog/kernel_stm32.bin: examples/watchdog/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# net_echo/arp_reply/icmp_echo/tcp_echo/http_server (STM32): real Ethernet
# MAC/PHY/DMA (examples/common_stm32/eth.tkb) instead of virtio-net. Each
# compiles the *same* examples/<name>/<name>.tkb file the QEMU build uses
# (see examples/net_echo/net_echo.tkb's header comment) -- unlike
# irq/preempt/etc., there is no genuinely-different-shape logic here
# anymore, eth.tkb just implements the same net_init/net_poll_rx/
# net_rx_buf/net_transmit/net_rx_release/net_read_mac API
# examples/common/virtio_mmio.tkb does. Links against
# COMMON_STM32_LINK_ETH_LD (AXI SRAM), not the shared DTCM-based link.ld.
# netconfig.tkb (OUR_MAC/OUR_IP) and netutil.tkb (bytes_eq/
# bytes_copy/read_u16be/write_u16be, needed by net_read_mac's bytes_copy
# call) are included for all five, even net_echo (which never references
# either symbol) -- harmless, matching the same "one inert extra file
# rather than a split recipe group" choice the QEMU-side NET_OBJS makes.
COMMON_STM32_ETH       := $(COMMON_STM32_DIR)/eth.tkb
COMMON_STM32_ETH_ASM_S := $(COMMON_STM32_DIR)/eth_asm.S
COMMON_STM32_ETH_ASM_O := $(COMMON_STM32_DIR)/eth_asm.o
COMMON_STM32_NETCONFIG := $(COMMON_STM32_DIR)/netconfig.tkb

$(COMMON_STM32_ETH_ASM_O): $(COMMON_STM32_ETH_ASM_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

examples/net_echo/net_echo_stm32.o: examples/net_echo/net_echo.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_NETUTIL) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/net_echo/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/net_echo/net_echo_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/net_echo/net_echo_stm32.o -o $@

examples/arp_reply/arp_reply_stm32.o: examples/arp_reply/arp_reply.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_NETUTIL) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/arp_reply/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/arp_reply/arp_reply_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/arp_reply/arp_reply_stm32.o -o $@

examples/arp_reply/kernel_stm32.bin: examples/arp_reply/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/icmp_echo/icmp_echo_stm32.o: examples/icmp_echo/icmp_echo.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/icmp_echo/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/icmp_echo/icmp_echo_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/icmp_echo/icmp_echo_stm32.o -o $@

examples/icmp_echo/kernel_stm32.bin: examples/icmp_echo/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/tcp_echo/tcp_echo_stm32.o: examples/tcp_echo/tcp_echo.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/tcp_echo/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/tcp_echo/tcp_echo_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/tcp_echo/tcp_echo_stm32.o -o $@

examples/tcp_echo/kernel_stm32.bin: examples/tcp_echo/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/http_server/http_server_stm32.o: examples/http_server/http_server.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_ETH) $(COMMON_STM32_NETCONFIG) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/http_server/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/http_server/http_server_stm32.o $(COMMON_STM32_LINK_ETH_LD)
	$(LLD) -T $(COMMON_STM32_LINK_ETH_LD) $(COMMON_STM32_STARTUP_O) $(COMMON_STM32_ETH_ASM_O) examples/http_server/http_server_stm32.o -o $@

examples/http_server/kernel_stm32.bin: examples/http_server/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/net_echo/kernel_stm32.bin: examples/net_echo/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

$(STM32_CHECKSUM_OBJS): examples/%_stm32.o: examples/%.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $(TAKIBI)
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

$(STM32_CHECKSUM_KERNELS): examples/%/kernel_stm32.elf: \
    $(COMMON_STM32_STARTUP_O) examples/%/$$*_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/$*/$*_stm32.o -o $@

$(STM32_CHECKSUM_BINS): examples/%/kernel_stm32.bin: examples/%/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

# -- QEMU run targets ----------------------------------------------------------
QEMU_FLAGS := -machine virt -cpu cortex-a53 -nographic \
              -semihosting-config enable=on,target=native

## qemu-echo: manually run the echo server on QEMU virt (press Ctrl-A X to quit)
qemu-echo: examples/echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) -kernel $<

# Offloads disabled so GuestFeatures negotiates to 0 and virtio_net_hdr
# stays a fixed 10 bytes -- see examples/common/virtio_mmio.tkb.
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

# Same STM32_SERIAL_DEV/FLASH_ADDR convention as scripts/run_hwtest.sh
# (overridable the same way: STM32_SERIAL_DEV=/dev/ttyACM1 make ...).
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
## reasoning as read_until_quiet's WAIT_FOR_DATA case in run_hwtest.sh.
stm32-http-server: examples/http_server/kernel_stm32.bin
	@if [ ! -e "$(STM32_SERIAL_DEV)" ]; then \
	    echo "error: $(STM32_SERIAL_DEV) not found -- is the STM32F746G-DISCOVERY board connected?" >&2; \
	    exit 1; \
	fi
	@if ! st-info --probe > /dev/null 2>&1; then \
	    echo "error: st-info --probe failed -- is the ST-LINK debug interface accessible?" >&2; \
	    exit 1; \
	fi
	st-flash write $< $(STM32_FLASH_ADDR)
	@ip=$$(grep -m1 '^let HTTP_SERVER_IP' examples/common_stm32/netconfig.tkb | grep -oP '\{[^}]*\}' | tr -d '{} ' | tr ',' '.'); \
	echo "Open http://$$ip/ in your browser (Ctrl-C to quit)"; \
	stty -F $(STM32_SERIAL_DEV) 115200 raw -echo; \
	cat $(STM32_SERIAL_DEV) & \
	catpid=$$!; \
	sleep 0.2; \
	st-flash reset > /dev/null 2>&1; \
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

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts and linker outputs
clean:
	dune clean
	rm -f $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) $(COMMON_SEM_ASM_O) \
	      $(foreach e,$(EXAMPLES),examples/$(e)/*.o examples/$(e)/*.elf examples/$(e)/*.bin)
