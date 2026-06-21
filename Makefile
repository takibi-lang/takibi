# ── Configuration ────────────────────────────────────────────────────────────
SRC    := examples/start.takibi
OBJ    := examples/start.o
BIN    := examples/start.exe
MAIN_C := examples/main.c
CC     := gcc

# dune exec は実行前に OCaml ソースの変更を検知して再ビルドする
TAKIBI := dune exec takibi --

# ── Targets ──────────────────────────────────────────────────────────────────
.PHONY: all build ir run test clean

.DEFAULT_GOAL := all

## all: OCamlビルド → .o生成 → リンク
all: build $(BIN)

## build: OCamlコンパイラ(dune)のみビルド
build:
	dune build

## ir: LLVM IR と C コードを標準出力にダンプ
ir: build
	$(TAKIBI) $(SRC)

## $(OBJ): .takibi を機械語オブジェクトに変換
##   dune exec が OCaml 側の変更も自動的に面倒を見る
$(OBJ): $(SRC)
	$(TAKIBI) $(SRC) -o $@

## $(BIN): C の main とリンクして実行ファイルを生成
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
	rm -f $(OBJ) $(BIN)
