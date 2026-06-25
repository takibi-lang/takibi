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

# ── Examples ──────────────────────────────────────────────────────────────────
# 新しい例題を追加するときはここに名前を足すだけ。
# 規約: examples/<name>/<name>.tkb → examples/<name>/kernel.elf
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf
ALL_KERNELS  := $(foreach e,$(EXAMPLES),examples/$(e)/kernel.elf)
EXAMPLE_OBJS := $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o)

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: build test qemutest check clean qemu-echo

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

# ── Shared startup object ─────────────────────────────────────────────────────
$(COMMON_STARTUP_O): $(COMMON_STARTUP_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

# ── .tkb → .o  (static pattern rule) ─────────────────────────────────────────
# examples/%.o に対して % は "name/name"（スラッシュ込み）にマッチする。
# 例: examples/start/start.o ← examples/start/start.tkb
.SECONDEXPANSION:

$(EXAMPLE_OBJS): examples/%.o: examples/%.tkb build
	$(TAKIBI) $< --target $(AARCH64_TARGET) -o $@

# ── example.o + startup.o → kernel.elf ───────────────────────────────────────
# examples/%/kernel.elf の % は "name" にマッチ（スラッシュなし）。
# $$*.o は2段展開で examples/<name>/<name>.o になる:
#   1段目: $$* → $*  ($$が$に縮退)
#   2段目: $*  → name (ステム展開)
$(ALL_KERNELS): examples/%/kernel.elf: \
    $(COMMON_STARTUP_O) examples/%/$$*.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/$*/$*.o -o $@

# ── QEMU run targets ──────────────────────────────────────────────────────────
QEMU_FLAGS := -machine virt -cpu cortex-a53 -nographic \
              -semihosting-config enable=on,target=native

## qemu-echo: QEMU virt で echo サーバを手動実行 (Ctrl-A X で終了)
qemu-echo: examples/echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) -kernel $<

# ── clean ─────────────────────────────────────────────────────────────────────
## clean: dune の生成物 + リンク成果物を削除
clean:
	dune clean
	rm -f $(COMMON_STARTUP_O) \
	      $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o examples/$(e)/kernel.elf)
