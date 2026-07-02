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

# -- Examples ------------------------------------------------------------------
# To add a new example, just append its name here.
# Convention: examples/<name>/<name>.tkb -> examples/<name>/kernel.elf
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined narrow for loop enum nonexhaustive bitops align packed struct_align const_global sizeof net_echo arp_reply inet_checksum ip_parse icmp_echo tcp_parse tcp_echo
ALL_KERNELS  := $(foreach e,$(EXAMPLES),examples/$(e)/kernel.elf)
EXAMPLE_OBJS := $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o)

# -- Targets ------------------------------------------------------------------
.PHONY: build test qemutest langcheck check clean qemu-echo qemu-net-echo qemu-arp-reply qemu-icmp-echo qemu-tcp-echo

.DEFAULT_GOAL := build

## build: build only the OCaml compiler (dune)
build:
	dune build

## test: run unit tests
test:
	dune test

## qemutest: run QEMU integration tests (build all examples and verify automatically)
qemutest: $(ALL_KERNELS)
	@bash scripts/run_qemutest.sh

## langcheck: verify that all source files contain only ASCII characters
langcheck:
	@echo "Checking for non-ASCII characters in source files..."
	@if LC_ALL=C grep -rnP '[^\x00-\x7F]' --exclude-dir=_build \
	       --include="*.ml" --include="*.mll" --include="*.mly" \
	       --include="*.tkb" --include="*.S" --include="*.md" \
	       --include="*.sh" --include="*.ld" \
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
#   App group  : + gic.tkb + virtio_mmio.tkb + inet_checksum.tkb + netutil.tkb (icmp_echo, tcp_echo)
.SECONDEXPANSION:

IRQ_OBJS   := examples/irq/irq.o
# semaphore.tkb declares its own extern fn sem_wait/sem_post, so no sync.tkb needed here
TIMER_OBJS := examples/preempt/preempt.o examples/semaphore/semaphore.o \
              examples/watchdog/watchdog.o
SYNC_OBJS  := examples/condvar/condvar.o examples/msgqueue/msgqueue.o
NET_OBJS   := examples/net_echo/net_echo.o examples/arp_reply/arp_reply.o
CHECKSUM_OBJS := examples/inet_checksum/inet_checksum.o examples/ip_parse/ip_parse.o \
                 examples/tcp_parse/tcp_parse.o
APP_OBJS   := examples/icmp_echo/icmp_echo.o examples/tcp_echo/tcp_echo.o
SPECIAL_OBJS := $(IRQ_OBJS) $(TIMER_OBJS) $(SYNC_OBJS) $(NET_OBJS) $(CHECKSUM_OBJS) $(APP_OBJS)
STANDARD_OBJS := $(filter-out $(SPECIAL_OBJS), $(EXAMPLE_OBJS))

$(STANDARD_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -o $@

$(IRQ_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $< --target $(AARCH64_TARGET) -o $@

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

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts and linker outputs
clean:
	dune clean
	rm -f $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) $(COMMON_SEM_ASM_O) \
	      $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o examples/$(e)/kernel.elf)
