# ── Configuration ────────────────────────────────────────────────────────────
AARCH64_TARGET := aarch64-none-elf

TAKIBI  := dune exec takibi --
LLVM_MC := llvm-mc-19
LLD     := ld.lld-19
QEMU    := qemu-system-aarch64

# ── Shared AArch64 bare-metal support files ───────────────────────────────────
COMMON_DIR       := examples/common
COMMON_STARTUP_S := $(COMMON_DIR)/startup.S
COMMON_STARTUP_O := $(COMMON_DIR)/startup.o
COMMON_LINK_LD   := $(COMMON_DIR)/link.ld

# ── Per-example sources and artefacts ────────────────────────────────────────
START_DIR        := examples/start
START_SRC        := $(START_DIR)/start.tkb
START_OBJ        := $(START_DIR)/start.o
START_KERNEL_ELF := $(START_DIR)/kernel.elf

HELLO_DIR        := examples/hello
HELLO_SRC        := $(HELLO_DIR)/hello.tkb
HELLO_OBJ        := $(HELLO_DIR)/hello.o
HELLO_KERNEL_ELF := $(HELLO_DIR)/kernel.elf

ECHO_DIR         := examples/echo
ECHO_SRC         := $(ECHO_DIR)/echo.tkb
ECHO_OBJ         := $(ECHO_DIR)/echo.o
ECHO_KERNEL_ELF  := $(ECHO_DIR)/kernel.elf

PRINT_INT_DIR        := examples/print_int
PRINT_INT_SRC        := $(PRINT_INT_DIR)/print_int.tkb
PRINT_INT_OBJ        := $(PRINT_INT_DIR)/print_int.o
PRINT_INT_KERNEL_ELF := $(PRINT_INT_DIR)/kernel.elf

ALL_KERNELS := $(START_KERNEL_ELF) $(HELLO_KERNEL_ELF) \
               $(ECHO_KERNEL_ELF) $(PRINT_INT_KERNEL_ELF)

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build test qemutest check clean \
        qemu-start qemu qemu-echo qemu-print-int

.DEFAULT_GOAL := build

## build: OCamlコンパイラ(dune)のみビルド
build:
	dune build

## test: ユニットテスト実行
test:
	dune test

## qemutest: QEMU 結合テストを実行（全例題をビルドして自動検証）
qemutest: $(ALL_KERNELS)
	@bash tests/qemu_test.sh

## check: ユニットテスト + QEMU 結合テストを実行
check: test qemutest

# ── Shared startup object (built once, reused by all examples) ────────────────
$(COMMON_STARTUP_O): $(COMMON_STARTUP_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

# ── Generic rule: .tkb → .o (AArch64) ────────────────────────────────────────
$(START_OBJ):     $(START_SRC)     build
$(HELLO_OBJ):     $(HELLO_SRC)     build
$(ECHO_OBJ):      $(ECHO_SRC)      build
$(PRINT_INT_OBJ): $(PRINT_INT_SRC) build

$(START_OBJ) $(HELLO_OBJ) $(ECHO_OBJ) $(PRINT_INT_OBJ):
	$(TAKIBI) $< --target $(AARCH64_TARGET) -o $@

# ── Generic rule: startup.o + example.o → kernel.elf ─────────────────────────
$(START_KERNEL_ELF):     $(COMMON_STARTUP_O) $(START_OBJ)
$(HELLO_KERNEL_ELF):     $(COMMON_STARTUP_O) $(HELLO_OBJ)
$(ECHO_KERNEL_ELF):      $(COMMON_STARTUP_O) $(ECHO_OBJ)
$(PRINT_INT_KERNEL_ELF): $(COMMON_STARTUP_O) $(PRINT_INT_OBJ)

$(ALL_KERNELS):
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) \
	    $(filter-out $(COMMON_STARTUP_O), $^) -o $@

# ── QEMU run targets ──────────────────────────────────────────────────────────
QEMU_FLAGS := -machine virt -cpu cortex-a53 -nographic \
              -semihosting-config enable=on,target=native

## qemu-start: QEMU virt で start デモを実行
qemu-start: $(START_KERNEL_ELF)
	$(QEMU) $(QEMU_FLAGS) -kernel $<

## qemu: QEMU virt で Hello World を実行
qemu: $(HELLO_KERNEL_ELF)
	$(QEMU) $(QEMU_FLAGS) -kernel $<

## qemu-echo: QEMU virt で echo サーバを実行 (Ctrl-A X で終了)
qemu-echo: $(ECHO_KERNEL_ELF)
	$(QEMU) $(QEMU_FLAGS) -kernel $<

## qemu-print-int: QEMU virt で uart_print_int テストを実行
qemu-print-int: $(PRINT_INT_KERNEL_ELF)
	$(QEMU) $(QEMU_FLAGS) -kernel $<

# ── clean ─────────────────────────────────────────────────────────────────────
## clean: dune の生成物 + リンク成果物を削除
clean:
	dune clean
	rm -f $(COMMON_STARTUP_O) \
	      $(START_OBJ)     $(START_KERNEL_ELF) \
	      $(HELLO_OBJ)     $(HELLO_KERNEL_ELF) \
	      $(ECHO_OBJ)      $(ECHO_KERNEL_ELF) \
	      $(PRINT_INT_OBJ) $(PRINT_INT_KERNEL_ELF)
