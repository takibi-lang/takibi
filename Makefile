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

# -- Examples ------------------------------------------------------------------
# To add a new example, just append its name here.
# Convention: examples/<name>/<name>.tkb -> examples/<name>/kernel.elf
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined narrow for loop enum nonexhaustive bitops align
ALL_KERNELS  := $(foreach e,$(EXAMPLES),examples/$(e)/kernel.elf)
EXAMPLE_OBJS := $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o)

# -- Targets ------------------------------------------------------------------
.PHONY: build test qemutest langcheck check clean qemu-echo

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
.SECONDEXPANSION:

IRQ_OBJS   := examples/irq/irq.o
# semaphore.tkb declares its own extern fn sem_wait/sem_post, so no sync.tkb needed here
TIMER_OBJS := examples/preempt/preempt.o examples/semaphore/semaphore.o \
              examples/watchdog/watchdog.o
SYNC_OBJS  := examples/condvar/condvar.o examples/msgqueue/msgqueue.o
SPECIAL_OBJS := $(IRQ_OBJS) $(TIMER_OBJS) $(SYNC_OBJS)
STANDARD_OBJS := $(filter-out $(SPECIAL_OBJS), $(EXAMPLE_OBJS))

$(STANDARD_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $< --target $(AARCH64_TARGET) -o $@

$(IRQ_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $< --target $(AARCH64_TARGET) -o $@

$(TIMER_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $< --target $(AARCH64_TARGET) -o $@

$(SYNC_OBJS): examples/%.o: examples/%.tkb $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) build
	$(TAKIBI) $(COMMON_UART) $(COMMON_PRINT) $(COMMON_GIC) $(COMMON_TIMER) $(COMMON_SYNC) $< --target $(AARCH64_TARGET) -o $@

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

# -- clean ---------------------------------------------------------------------
## clean: remove dune build artifacts and linker outputs
clean:
	dune clean
	rm -f $(COMMON_STARTUP_O) $(COMMON_TIMER_ASM_O) $(COMMON_SEM_ASM_O) \
	      $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o examples/$(e)/kernel.elf)
