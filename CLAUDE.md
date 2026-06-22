# takibi

OCaml 5.4.0 製の自作言語コンパイラ。LLVM 19 バックエンド経由でネイティブ機械語を生成する。
最終目標は Raspberry Pi 3 / RISC-V / STM32 ベアメタル環境で TCP/IP スタックを実装し HTTP サーバを動かすこと。

## 言語仕様（現時点）

- ファイル拡張子: `.tkb`
- 型: `int`, `char`, `void`, `*T`（ポインタ型、ネスト可）
- 文:
  - `let`, `while`, `return`, 代入 (`x = e`)、ポインタ経由代入 (`*p = v`)
  - `if (cond) { ... }` — `else` は省略可
  - `if (cond) { ... } else { ... }` — 通常の if/else
  - `if (cond) { ... } else if (cond) { ... } else { ... }` — else if チェーン
- 式:
  - 整数リテラル（10進・16進 `0x...`）
  - 文字リテラル（`'a'`、`'\n'`、`'\r'`、`'\t'`、`'\0'`、`'\\'`）— `IntLit (Char.code c)` に脱糖
  - 文字列リテラル（`"..."` — `\n` `\r` `\t` `\\` `\"` エスケープ対応）
  - 算術演算（`+` `-` `*` `/`）、比較演算（`<` `>` `<=` `>=` `==` `!=`）
  - 論理 OR（`||`）
  - 関数呼び出し、`*expr`（デリファレンス）、`&ident`（アドレス取得）
- MMIO: volatile store/load として emit される（`set_volatile true`）

## ビルドコマンド

```bash
dune build          # コンパイラ (takibi) のビルド
dune test           # テスト実行（42件）
make qemu           # QEMU virt (AArch64) でベアメタル Hello World を実行
make qemu-echo      # QEMU virt (AArch64) で echo サーバを実行（q+Enter で終了）
make ir             # ホスト向け LLVM IR をダンプ
make ir-aarch64     # AArch64 向け LLVM IR をダンプ
```

## ディレクトリ構成

```
lib/
  ast.ml          — AST 定義（TypePtr, Deref, AddrOf, AssignDeref を含む）
  lexer.mll       — ocamllex（hex リテラル、& トークン含む）
  parser.mly      — Menhir（ポインタ型、前置 * / & 演算子含む）
  types.ml        — 内部型 (ty) + HM 型推論の出力型 + StringMap
  type_inf.ml     — Hindley-Milner 型推論（immutable StringMap ベース）
  typechecker.ml  — 外部向けラッパー（main.ml から呼ぶ）
  llvm_gen.ml     — LLVM IR 生成・オブジェクトファイル出力
bin/
  main.ml         — CLI（`takibi <file.tkb> [-o out.o] [--target <triple>]`）
examples/
  start.tkb       — ホスト向けサンプル
  hello/
    hello.tkb     — AArch64 ベアメタル Hello World（自作言語で書かれたソース）
    startup.S     — _start → main、BSS ゼロクリア、AArch64 semihosting exit
    link.ld       — リンカスクリプト（ロードアドレス 0x40000000）
    kernel.elf    — リンク成果物（make qemu で生成）
  echo/
    echo.tkb      — UART echo サーバ（q+Enter で終了、char リテラル・|| を使用）
    startup.S     — hello/ と同一
    link.ld       — hello/ と同一
    kernel.elf    — リンク成果物（make qemu-echo で生成）
test/
  test_takibi.ml  — Alcotest による parser / type_inf テスト
```

## 重要な設計上のポイント

### LLVM 19 opaque pointers
LLVM 19 はポインタ型が 1 種類（`pointer_type context`）のみ。`build_load` に element type を明示する必要がある。
そのため `gen_expr` は `llvalue` だけでなく `(Ast.type_expr * llvalue)` を返す設計になっている。

### 型推論環境は immutable Map
`tyenv` は `ty Types.StringMap.t`（`Map.Make(String)` ベース）。
`Hashtbl` は使わない。`infer_stmt` のシグネチャ:
```ocaml
val infer_stmt : tyenv -> ty StringMap.t -> ty -> ty StringMap.t -> Ast.stmt
               -> tyenv * ty StringMap.t
```
戻り値の第2要素 `raw_locals` が codegen 用の Let バインディング型マップ。

### binop を追加するときは3ファイルを更新する
`Ast.binop` に新しいコンストラクタを追加する場合、以下の3ファイルを必ず更新する必要がある。
OCaml の網羅性チェック（exhaustive match）がコンパイルエラーで漏れを教えてくれる。

1. `lib/ast.ml` — コンストラクタ定義
2. `lib/type_inf.ml` — `BinOp` の match に型推論ルールを追加
3. `lib/llvm_gen.ml` — `BinOp` の match に LLVM IR 生成を追加

### Integer literal → pointer coercion
`let dr: *int = 0x09000000;` は整数リテラルをポインタ型変数に代入する。
`llvm_gen.ml` の `coerce` 関数が `inttoptr(zext(i32, i64), ptr)` を emit する。

## QEMU ベアメタル（AArch64）

- マシン: `virt`, CPU: `cortex-a53`
- PL011 UART レジスタ: `0x09000000`（QEMU が事前初期化するので baud rate 設定不要）
- ロードアドレス: `0x40000000`（QEMU virt の RAM 開始アドレス）
- セミホスティング exit: `SYS_EXIT` (x0=0x18) + AArch64 拡張フォーマット
  - x1 は値ではなく `[ADP_Stopped_ApplicationExit, 0]` の 2 ワードブロックへのポインタ
  - QEMU 起動オプション: `-semihosting-config enable=on,target=native`
- アセンブラ: `llvm-mc-19`、リンカ: `ld.lld-19`

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
