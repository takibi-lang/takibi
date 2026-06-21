# ── Configuration ────────────────────────────────────────────────────────────
SRC    := examples/start.takibi
OBJ    := examples/start.o
BIN    := examples/start.exe
MAIN_C := examples/main.c
CC     := gcc

AARCH64_TARGET := aarch64-none-elf
AARCH64_OBJ    := examples/start-aarch64.o

# dune exec は実行前に OCaml ソースの変更を検知して再ビルドする
TAKIBI := dune exec takibi --

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build ir ir-aarch64 run test clean

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

## clean: dune の生成物 + リンク成果物を削除
clean:
	dune clean
	rm -f $(OBJ) $(BIN) $(AARCH64_OBJ)
