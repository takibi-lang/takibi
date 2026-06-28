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
EXAMPLES     := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar struct msgqueue watchdog refined
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
	@bash scripts/run_qemutest.sh

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
# 追加アセンブリが必要な例題（preempt など）は個別ルールで定義するためここから除外する。
GENERIC_KERNELS := $(filter-out examples/preempt/kernel.elf examples/semaphore/kernel.elf examples/condvar/kernel.elf examples/msgqueue/kernel.elf examples/watchdog/kernel.elf, $(ALL_KERNELS))

$(GENERIC_KERNELS): examples/%/kernel.elf: \
    $(COMMON_STARTUP_O) examples/%/$$*.o $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) examples/$*/$*.o -o $@

# ── preempt: 追加アセンブリオブジェクトが必要なので個別ルールで上書き ─────────
PREEMPT_ASM_S := examples/preempt/preempt_asm.S
PREEMPT_ASM_O := examples/preempt/preempt_asm.o

$(PREEMPT_ASM_O): $(PREEMPT_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

examples/preempt/kernel.elf: \
    $(COMMON_STARTUP_O) examples/preempt/preempt.o $(PREEMPT_ASM_O) $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) \
	       examples/preempt/preempt.o $(PREEMPT_ASM_O) -o $@

# ── semaphore: 追加アセンブリオブジェクトが必要なので個別ルールで上書き ──────
SEMAPHORE_ASM_S := examples/semaphore/semaphore_asm.S
SEMAPHORE_ASM_O := examples/semaphore/semaphore_asm.o

$(SEMAPHORE_ASM_O): $(SEMAPHORE_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

examples/semaphore/kernel.elf: \
    $(COMMON_STARTUP_O) examples/semaphore/semaphore.o $(SEMAPHORE_ASM_O) $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) \
	       examples/semaphore/semaphore.o $(SEMAPHORE_ASM_O) -o $@

# ── condvar: 追加アセンブリオブジェクトが必要なので個別ルールで上書き ────────
CONDVAR_ASM_S := examples/condvar/condvar_asm.S
CONDVAR_ASM_O := examples/condvar/condvar_asm.o

$(CONDVAR_ASM_O): $(CONDVAR_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

examples/condvar/kernel.elf: \
    $(COMMON_STARTUP_O) examples/condvar/condvar.o $(CONDVAR_ASM_O) $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) \
	       examples/condvar/condvar.o $(CONDVAR_ASM_O) -o $@

# ── watchdog: 追加アセンブリオブジェクトが必要なので個別ルールで上書き ──────
WATCHDOG_ASM_S := examples/watchdog/watchdog_asm.S
WATCHDOG_ASM_O := examples/watchdog/watchdog_asm.o

$(WATCHDOG_ASM_O): $(WATCHDOG_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

examples/watchdog/kernel.elf: \
    $(COMMON_STARTUP_O) examples/watchdog/watchdog.o $(WATCHDOG_ASM_O) $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) \
	       examples/watchdog/watchdog.o $(WATCHDOG_ASM_O) -o $@

# ── QEMU run targets ──────────────────────────────────────────────────────────
QEMU_FLAGS := -machine virt -cpu cortex-a53 -nographic \
              -semihosting-config enable=on,target=native

## qemu-echo: QEMU virt で echo サーバを手動実行 (Ctrl-A X で終了)
qemu-echo: examples/echo/kernel.elf
	$(QEMU) $(QEMU_FLAGS) -kernel $<

# ── msgqueue: 追加アセンブリオブジェクトが必要なので個別ルールで上書き ───────
MSGQUEUE_ASM_S := examples/msgqueue/msgqueue_asm.S
MSGQUEUE_ASM_O := examples/msgqueue/msgqueue_asm.o

$(MSGQUEUE_ASM_O): $(MSGQUEUE_ASM_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

examples/msgqueue/kernel.elf: \
    $(COMMON_STARTUP_O) examples/msgqueue/msgqueue.o $(MSGQUEUE_ASM_O) $(COMMON_LINK_LD)
	$(LLD) -T $(COMMON_LINK_LD) $(COMMON_STARTUP_O) \
	       examples/msgqueue/msgqueue.o $(MSGQUEUE_ASM_O) -o $@

# ── clean ─────────────────────────────────────────────────────────────────────
## clean: dune の生成物 + リンク成果物を削除
clean:
	dune clean
	rm -f $(COMMON_STARTUP_O) \
	      $(foreach e,$(EXAMPLES),examples/$(e)/$(e).o examples/$(e)/kernel.elf) \
	      $(PREEMPT_ASM_O) $(SEMAPHORE_ASM_O) $(CONDVAR_ASM_O) $(MSGQUEUE_ASM_O) $(WATCHDOG_ASM_O)
