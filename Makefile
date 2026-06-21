# ── Configuration ────────────────────────────────────────────────────────────
SRC    := examples/start.tkb
OBJ    := examples/start.o
BIN    := examples/start.exe
MAIN_C := examples/main.c
CC     := gcc

AARCH64_TARGET := aarch64-none-elf
AARCH64_OBJ    := examples/start-aarch64.o

# dune exec は実行前に OCaml ソースの変更を検知して再ビルドする
TAKIBI := dune exec takibi --

# ── Hello World (QEMU virt / AArch64 bare-metal) ─────────────────────────────
HELLO_DIR   := examples/hello
HELLO_SRC   := $(HELLO_DIR)/hello.tkb
HELLO_OBJ   := $(HELLO_DIR)/hello.o
STARTUP_S   := $(HELLO_DIR)/startup.S
STARTUP_OBJ := $(HELLO_DIR)/startup.o
KERNEL_ELF  := $(HELLO_DIR)/kernel.elf
LINK_LD     := $(HELLO_DIR)/link.ld
LLVM_MC     := llvm-mc-19
LLD         := ld.lld-19
QEMU        := qemu-system-aarch64

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build ir ir-aarch64 run test clean qemu

.DEFAULT_GOAL := all

## all: OCamlビルド → .o生成 → リンク (ホスト向け)
all: build $(BIN)

## build: OCamlコンパイラ(dune)のみビルド
build:
	dune build

## ir: ホスト向け LLVM IR をダンプ
ir: build
	$(TAKIBI) $(SRC)

## ir-aarch64: AArch64 ベアメタル向け LLVM IR をダンプ
ir-aarch64: build
	$(TAKIBI) $(SRC) --target $(AARCH64_TARGET)

## $(OBJ): ホスト向け機械語オブジェクト
$(OBJ): $(SRC)
	$(TAKIBI) $(SRC) -o $@

## $(AARCH64_OBJ): AArch64 ベアメタル向け機械語オブジェクト
$(AARCH64_OBJ): $(SRC)
	$(TAKIBI) $(SRC) --target $(AARCH64_TARGET) -o $@

## $(BIN): C の main とリンクして実行ファイルを生成 (ホスト向け)
$(BIN): $(OBJ) $(MAIN_C)
	$(CC) -o $@ $(MAIN_C) $(OBJ)

## run: ビルドしてそのまま実行
run: $(BIN)
	$<

## test: テスト実行
test:
	dune test

## $(HELLO_OBJ): hello.tkb を AArch64 オブジェクトにコンパイル
$(HELLO_OBJ): $(HELLO_SRC) build
	$(TAKIBI) $< --target $(AARCH64_TARGET) -o $@

## $(STARTUP_OBJ): スタートアップアセンブリをアセンブル
$(STARTUP_OBJ): $(STARTUP_S)
	$(LLVM_MC) --triple=aarch64-none-elf --filetype=obj $< -o $@

## $(KERNEL_ELF): オブジェクトをリンカスクリプトでリンク
$(KERNEL_ELF): $(STARTUP_OBJ) $(HELLO_OBJ) $(LINK_LD)
	$(LLD) -T $(LINK_LD) $(STARTUP_OBJ) $(HELLO_OBJ) -o $@

## qemu: QEMU virt で Hello World を実行
qemu: $(KERNEL_ELF)
	$(QEMU) -machine virt -cpu cortex-a53 -nographic \
		-semihosting-config enable=on,target=native \
		-kernel $(KERNEL_ELF)

## clean: dune の生成物 + リンク成果物を削除
clean:
	dune clean
	rm -f $(OBJ) $(BIN) $(AARCH64_OBJ) \
	      $(HELLO_OBJ) $(STARTUP_OBJ) $(KERNEL_ELF)
