# -- Configuration ------------------------------------------------------------
AARCH64_TARGET := aarch64-none-elf

TAKIBI  := dune exec takibi --
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

# -- Examples ------------------------------------------------------------------
# To add a new example, just append its name here.
# Convention: examples/<name>/<name>.tkb -> examples/<name>/kernel.elf
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined narrow for loop enum nonexhaustive bitops align packed struct_align const_global sizeof net_echo arp_reply inet_checksum ip_parse icmp_echo tcp_parse tcp_echo http_server
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
                  bitops align packed struct_align const_global sizeof
STM32_OBJS     := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/$(e)_stm32.o)
STM32_KERNELS  := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/kernel_stm32.elf)
STM32_BINS     := $(foreach e,$(STM32_EXAMPLES),examples/$(e)/kernel_stm32.bin)
# rtc/echo: ported separately (real RTC peripheral / bidirectional serial
# test), each needs one extra common file beyond uart+print -- see the
# one-off rules near COMMON_STM32_RTC/COMMON_STM32_UART_GETC below.
STM32_EXTRA_BINS := examples/rtc/kernel_stm32.bin examples/echo/kernel_stm32.bin

# -- Targets ------------------------------------------------------------------
.PHONY: build test qemutest hwcheck langcheck check clean qemu-echo qemu-net-echo qemu-arp-reply qemu-icmp-echo qemu-tcp-echo qemu-http-server profile-http-server profile-tcp-echo

.DEFAULT_GOAL := build

## build: build only the OCaml compiler (dune)
build:
	dune build

## test: run unit tests
test:
	dune test

## qemutest: run QEMU integration tests (build all examples and verify automatically)
qemutest: $(ALL_KERNELS) examples/fizzbuzz/kernel.debug.elf examples/fibonacci/kernel.debug.elf
	@bash scripts/run_qemutest.sh

## hwcheck: run STM32 hardware integration tests (requires a real
## STM32F746G-DISCOVERY board connected via USB). NOT part of `make check` --
## unlike qemutest, this needs physical hardware, so it stays runnable-only-
## when-available rather than a requirement for every clone of this repo.
hwcheck: $(STM32_BINS) $(STM32_EXTRA_BINS)
	@bash scripts/run_hwtest.sh

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

## check: run unit tests + QEMU integration tests + ASCII check
check: test qemutest langcheck

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
# single-member-group treatment as IRQ_OBJS.
RTC_OBJS   := examples/rtc/rtc.o
GETC_OBJS  := examples/echo/echo.o
SPECIAL_OBJS := $(IRQ_OBJS) $(TIMER_OBJS) $(SYNC_OBJS) $(NET_OBJS) $(CHECKSUM_OBJS) $(APP_OBJS) \
                $(RTC_OBJS) $(GETC_OBJS)
STANDARD_OBJS := $(filter-out $(SPECIAL_OBJS), $(EXAMPLE_OBJS))

$(STANDARD_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -o $@

$(IRQ_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $< --target $(AARCH64_TARGET) -o $@

$(RTC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_RTC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_RTC) $< --target $(AARCH64_TARGET) -o $@

$(GETC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_UART_GETC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_UART_GETC) $< --target $(AARCH64_TARGET) -o $@

$(TIMER_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $< --target $(AARCH64_TARGET) -o $@

$(SYNC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) $< --target $(AARCH64_TARGET) -o $@

$(NET_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_NETUTIL) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_NETUTIL) $< --target $(AARCH64_TARGET) -o $@

$(CHECKSUM_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(AARCH64_TARGET) -o $@

$(APP_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) $< --target $(AARCH64_TARGET) -o $@

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
examples/fizzbuzz/fizzbuzz.debug.o: examples/fizzbuzz/fizzbuzz.tkb $(COMMON_UART) $(COMMON_PRINT) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -g -o $@

examples/fizzbuzz/kernel.debug.elf: $(COMMON_STARTUP_O) examples/fizzbuzz/fizzbuzz.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/fizzbuzz/fizzbuzz.debug.o -o $@

# Same pattern, second example (fibonacci): its `let mut a/b/tmp` locals and
# uart_putc's `c` parameter (uart.tkb is compiled in alongside it, same as
# the no-debug build) give run_dwarf_var_test something to check that
# fizzbuzz -- which has no `let mut` of its own -- doesn't exercise.
examples/fibonacci/fibonacci.debug.o: examples/fibonacci/fibonacci.tkb $(COMMON_UART) $(COMMON_PRINT) build
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
    $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) \
	          $< --target $(AARCH64_TARGET) -g -o $@

examples/http_server/kernel.debug.elf: $(COMMON_STARTUP_O) examples/http_server/http_server.debug.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/http_server/http_server.debug.o -o $@

# Same, for tcp_echo -- profile_http_server.py's profile landed ~100% in the
# idle interrupt-wait loop (network round trips dominate wall-clock time at
# the HTTP layer), so scripts/profile_tcp_echo.py profiles one layer down
# with a workload built to keep the server continuously busy instead.
examples/tcp_echo/tcp_echo.debug.o: examples/tcp_echo/tcp_echo.tkb \
    $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_VIRTIO_MMIO) $(COMMON_INET_CKSUM) $(COMMON_NETUTIL) \
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

$(COMMON_STM32_STARTUP_O): $(COMMON_STM32_STARTUP_S)
	$(LLVM_MC) --triple=$(STM32_TARGET) --filetype=obj $< -o $@

$(STM32_OBJS): examples/%_stm32.o: examples/%.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) build
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

examples/rtc/rtc_stm32.o: examples/rtc/rtc.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_RTC) build
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_RTC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/rtc/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/rtc/rtc_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/rtc/rtc_stm32.o -o $@

examples/rtc/kernel_stm32.bin: examples/rtc/kernel_stm32.elf
	llvm-objcopy-19 -O binary $< $@

examples/echo/echo_stm32.o: examples/echo/echo.tkb $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_UART_GETC) build
	$(TAKIBI) $(COMMON_STM32_UART) $(COMMON_PRINT) $(COMMON_STM32_UART_GETC) $< --target $(STM32_TARGET) --cpu $(STM32_CPU) -o $@

examples/echo/kernel_stm32.elf: $(COMMON_STM32_STARTUP_O) examples/echo/echo_stm32.o $(COMMON_STM32_LINK_LD)
	$(LLD) -T $(COMMON_STM32_LINK_LD) $(COMMON_STM32_STARTUP_O) examples/echo/echo_stm32.o -o $@

examples/echo/kernel_stm32.bin: examples/echo/kernel_stm32.elf
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
	      $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o examples/$(e)/kernel.elf examples/$(e)/kernel_stm32.bin)
