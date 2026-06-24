# takibi

OCaml 5.4.0 製の自作言語コンパイラ。LLVM 19 バックエンド経由でネイティブ機械語を生成する。
最終目標は Raspberry Pi 3 / RISC-V / STM32 ベアメタル環境で TCP/IP スタックを実装し HTTP サーバを動かすこと。

## 言語仕様（現時点）

- ファイル拡張子: `.tkb`
- 型: `int`, `char`, `void`, `*T`（ポインタ型、ネスト可）
- 文:
  - `let x = e` / `let x: T = e` — 不変変数宣言（初期値必須、再代入不可）
  - `let mut x = e` / `let mut x: T = e` — 可変変数宣言（再代入可）
  - `while`, `return`, 代入 (`x = e`)、ポインタ経由代入 (`*p = v`)
  - `if (cond) { ... }` — `else` は省略可
  - `if (cond) { ... } else { ... }` — 通常の if/else
  - `if (cond) { ... } else if (cond) { ... } else { ... }` — else if チェーン
  - 不変変数へのアドレス取得 (`&x`) はコンパイルエラー（今後必要になったとき再検討）
- 式:
  - 整数リテラル（10進・16進 `0x...`）
  - 文字リテラル（`'a'`、`'\n'`、`'\r'`、`'\t'`、`'\0'`、`'\\'`）— `IntLit (Char.code c)` に脱糖
  - 文字列リテラル（`"..."` — `\n` `\r` `\t` `\\` `\"` エスケープ対応）
  - 算術演算（`+` `-` `*` `/`）、比較演算（`<` `>` `<=` `>=` `==` `!=`）
  - 単項マイナス（`-expr`）— パーサで `BinOp(Sub, IntLit 0, expr)` に脱糖
  - 論理 OR（`||`）
  - ビット演算（`>>` 右論理シフト、`&` ビット AND）— 両辺 `int`、結果 `int`
  - 関数呼び出し、`*expr`（デリファレンス）、`&ident`（アドレス取得）
  - `expr as T` — 明示的型変換（int ↔ char）。優先順位は算術より低いので `a + b as char` = `(a + b) as char`
- MMIO: volatile store/load として emit される（`set_volatile true`）

## ビルドコマンド

```bash
make build          # コンパイラ (takibi) のビルド（= dune build）
make test           # ユニットテスト実行（66件）
make qemutest       # QEMU 結合テスト実行（全例題をビルドして自動検証）
make check          # make test + make qemutest を一括実行
make qemu-echo      # QEMU virt (AArch64) で echo サーバを手動実行（Ctrl-A X で終了）
make clean          # 生成物を削除
```

## ディレクトリ構成

```
lib/
  ast.ml          — AST 定義（TypePtr, Deref, AddrOf, AssignDeref, Cast を含む）
  lexer.mll       — ocamllex（hex リテラル、& トークン、as キーワード含む）
  parser.mly      — Menhir（ポインタ型、前置 * / & / 単項 -、as キャスト含む）
  types.ml        — 内部型 (ty) + HM 型推論の出力型 + StringMap
  type_inf.ml     — Hindley-Milner 型推論（immutable StringMap ベース）
  typechecker.ml  — 外部向けラッパー（main.ml から呼ぶ）
  llvm_gen.ml     — LLVM IR 生成・オブジェクトファイル出力
bin/
  main.ml         — CLI（`takibi <file.tkb> [-o out.o] [--target <triple>]`）
examples/
  common/
    startup.S     — _start → main、BSS ゼロクリア、AArch64 semihosting exit（全例題共通）
    link.ld       — リンカスクリプト（ロードアドレス 0x40000000）（全例題共通）
  start/
    start.tkb     — グローバル変数・if/else/while のデモ
    start.expected
  hello/
    hello.tkb     — AArch64 ベアメタル Hello World
    hello.expected
  echo/
    echo.tkb      — UART echo サーバ（q+Enter で終了、char リテラル・|| を使用）
    echo.expected
    echo.stdin    — qemutest 用スクリプト入力
  print_int/
    print_int.tkb — uart_print_int / as キャスト・単項マイナスのデモ
    print_int.expected
  print_hex/
    print_hex.tkb — uart_print_hex / >> と & ビット演算のデモ
    print_hex.expected
tests/
  qemu_test.sh    — QEMU 結合テストスクリプト（FIFO で同期、sleep 不要）
test/
  test_takibi.ml  — Alcotest による parser / type_inf ユニットテスト（66件）
```

## 重要な設計上のポイント

### LLVM 19 opaque pointers
LLVM 19 はポインタ型が 1 種類（`pointer_type context`）のみ。`build_load` に element type を明示する必要がある。
そのため `gen_expr` は `llvalue` だけでなく `(Ast.type_expr * llvalue)` を返す設計になっている。

### 型推論環境は immutable Map
`tyenv` は `(ty * bool) Types.StringMap.t`（`Map.Make(String)` ベース、bool = is_mutable）。
`Hashtbl` は使わない。`infer_stmt` のシグネチャ:
```ocaml
val infer_stmt : tyenv -> fenv -> ty -> ty StringMap.t -> Ast.stmt
               -> tyenv * ty StringMap.t
```
戻り値の第2要素 `raw_locals` が codegen 用の Let バインディング型マップ（可変・不変両方を含む）。

### binop を追加するときは3ファイルを更新する
`Ast.binop` に新しいコンストラクタを追加する場合、以下の3ファイルを必ず更新する必要がある。
OCaml の網羅性チェック（exhaustive match）がコンパイルエラーで漏れを教えてくれる。

1. `lib/ast.ml` — コンストラクタ定義
2. `lib/type_inf.ml` — `BinOp` の match に型推論ルールを追加
3. `lib/llvm_gen.ml` — `BinOp` の match に LLVM IR 生成を追加

### ビット演算の優先順位（C とは異なる）
`&`（Band）は比較演算子より**高い**優先順位を持つ（C では低い）。
これにより `n & mask == 0` は `(n & mask) == 0` と解釈される（C の有名な落とし穴を回避）。
`>>`（Shr）は `&` より高く `+/-` より低い優先順位。`n >> 4 & 0xf` は `(n >> 4) & 0xf` になる。

優先順位（低→高）: `||` < 比較 < `&` < `as` < `+/-` < `>>` < `*/` < 単項

### 単項マイナスはパーサで脱糖
`-expr` は `BinOp(Sub, IntLit 0, expr)` に変換される（`parser.mly` の `%prec UNARY` ルール）。
AST・型推論・codegen を変更せずに済む。LLVM IR でも `sub i32 0, %x` が整数否定の正規形。

### as キャストは4ファイルで構成
`expr as T` を追加した際の変更ファイル:
1. `lib/ast.ml` — `Cast of type_expr * expr` コンストラクタ
2. `lib/lexer.mll` — `"as"` キーワード
3. `lib/parser.mly` — `%nonassoc AS`（算術より低優先度）、`expr AS type_expr` 規則
4. `lib/type_inf.ml` — ソース式をチェックしてターゲット型を返す
5. `lib/llvm_gen.ml` — 既存の `coerce` 関数を呼ぶだけ（`i32→i8` trunc / `i8→i32` zext）

### 不変変数と可変変数の codegen
`llvm_gen.ml` の locals テーブルは `(string, local_binding) Hashtbl.t` で管理する。

```ocaml
type local_binding =
  | Imm of Ast.type_expr * llvalue  (* 不変: alloca なし、SSA 値を直接保持 *)
  | Mut of Ast.type_expr * llvalue  (* 可変: alloca ポインタ *)
```

- `let x = e` → 式を評価した llvalue を `Imm` としてテーブルに登録。`alloca/store/load` を生成しない
- `let mut x = e` → エントリーブロックで `alloca` を確保（`Mut`）し、宣言箇所で `store`
- 関数の引数は常に `Mut`（パラメータは再代入可能）

**`gen_stmt` は `gen_func` の内側に定義されている**。これは不変 `let` の型を、HM 型推論結果を参照する `res` 関数で解決する必要があるため。OCaml のクロージャとして `gen_func` スコープの `res` を自然に参照できる。

### Integer literal → pointer coercion
`let dr: *int = 0x09000000;` は整数リテラルをポインタ型変数に代入する。
`llvm_gen.ml` の `coerce` 関数が `inttoptr(zext(i32, i64), ptr)` を emit する。

### Makefile の例題登録規約
`EXAMPLES` リストに名前を追加するだけで新例題を登録できる。
規約: `examples/<name>/<name>.tkb` → `examples/<name>/kernel.elf`

```makefile
EXAMPLES := start hello echo print_int print_hex  # ← ここに追加するだけ
```

`qemu-echo` のようにインタラクティブな手動起動が必要なターゲットだけ個別に追加する。
自動化できるプログラムは `qemutest` に `.expected` / `.stdin` ファイルを用意して登録する。

## QEMU ベアメタル（AArch64）

- マシン: `virt`, CPU: `cortex-a53`
- PL011 UART レジスタ: `0x09000000`（QEMU が事前初期化するので baud rate 設定不要）
- ロードアドレス: `0x40000000`（QEMU virt の RAM 開始アドレス）
- セミホスティング exit: `SYS_EXIT` (x0=0x18) + AArch64 拡張フォーマット
  - x1 は値ではなく `[ADP_Stopped_ApplicationExit, 0]` の 2 ワードブロックへのポインタ
  - QEMU 起動オプション: `-semihosting-config enable=on,target=native`
- アセンブラ: `llvm-mc-19`、リンカ: `ld.lld-19`
- QEMU 結合テストは named pipe (FIFO) 経由で stdin を同期供給する（`tests/qemu_test.sh`）

## Claude Code への指示

- **git commit は作成しない**。ユーザーが明示的に依頼した場合のみ行う
- OCaml は慣用的なスタイルを優先する。`Hashtbl` より `Map.Make(String)` を使う
- `base` パッケージは使わない（LLVM バインディングとの境界で摩擦が生じるため）
- ユーザーは OCaml 初心者のため、コードの変更理由を「なぜこう書くのか」の観点で説明する
- **`~/.claude` へのメモリ保存は行わない**。プロジェクト固有の情報はこのファイルに集約する（環境をまたいで共有できないため）

## 依存ツール

```
ocaml 5.4.0, dune, menhir
llvm-19 OCaml bindings (llvm, llvm.analysis, llvm.target, llvm.all_backends)
ppx_deriving.show
llvm-mc-19, ld.lld-19   (ベアメタルビルド用)
qemu-system-aarch64     (QEMU 実行用)
```
