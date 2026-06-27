# takibi

OCaml 5.4.0 製の自作言語コンパイラ。LLVM 19 バックエンド経由でネイティブ機械語を生成する。
最終目標は Raspberry Pi 3 / RISC-V / STM32 ベアメタル環境で TCP/IP スタックを実装し HTTP サーバを動かすこと。

## 言語仕様（現時点）

- ファイル拡張子: `.tkb`
- 型: `int`, `char`, `void`, `*T`（ポインタ型、ネスト可）、`[T; N]`（配列型、関数引数はポインタに decay）、`fn(T...) -> R`（関数ポインタ型）
- 文:
  - `let x = e` / `let x: T = e` — 不変変数宣言（初期値必須、再代入不可）
  - `let mut x = e` / `let mut x: T = e` — 可変変数宣言（再代入可）
  - `let x: T;` — 未初期化グローバル変数宣言（グローバルスコープのみ）
  - `while`, `return`, 代入 (`x = e`)、ポインタ経由代入 (`*p = v`)
  - `if (cond) { ... }` — `else` は省略可
  - `if (cond) { ... } else { ... }` — 通常の if/else
  - `if (cond) { ... } else if (cond) { ... } else { ... }` — else if チェーン
  - 不変変数へのアドレス取得 (`&x`) はコンパイルエラー（グローバル変数は常に mutable 扱いなので `&global_var` は可）
- 式:
  - 整数リテラル（10進・16進 `0x...`）
  - 文字リテラル（`'a'`、`'\n'`、`'\r'`、`'\t'`、`'\0'`、`'\\'`）— `IntLit (Char.code c)` に脱糖
  - 文字列リテラル（`"..."` — `\n` `\r` `\t` `\\` `\"` エスケープ対応）
  - 算術演算（`+` `-` `*` `/` `%`）、比較演算（`<` `>` `<=` `>=` `==` `!=`）
  - ポインタ算術: `ptr + int` / `ptr - int` → 同じポインタ型（GEP として emit）。`int + ptr` も可。codegen は `build_neg + GEP` で実装
  - 単項マイナス（`-expr`）— パーサで `BinOp(Sub, IntLit 0, expr)` に脱糖
  - 論理 OR（`||`）
  - ビット演算（`>>` 右論理シフト、`<<` 左シフト、`&` ビット AND、`|` ビット OR、`^` ビット XOR）— 両辺 `int`、結果 `int`
  - 関数呼び出し、`*expr`（デリファレンス）、`&ident`（アドレス取得）
  - `expr as T` — 明示的型変換（int ↔ char、`*T` → int、`*T` → `*U`）。優先順位は算術より低いので `a + b as char` = `(a + b) as char`
- `extern fn name(params) -> ret;` — 外部アセンブリ関数宣言（LLVM `declare` を emit する）
- MMIO: volatile store/load として emit される（`set_volatile true`）
  - `*p` デリファレンスはすべて volatile load。グローバル変数の直接読み出しは非 volatile なので、
    割り込みハンドラと共有するフラグは `let p: *int = &global_flag; while (*p == 0) {}` の形で読む

## ビルドコマンド

```bash
make build          # コンパイラ (takibi) のビルド（= dune build）
make test           # ユニットテスト実行（99件）
make qemutest       # QEMU 結合テスト実行（全例題をビルドして自動検証）
make check          # make test + make qemutest を一括実行
make qemu-echo      # QEMU virt (AArch64) で echo サーバを手動実行（Ctrl-A X で終了）
make clean          # 生成物を削除
```

## ディレクトリ構成

```
lib/
  ast.ml          — AST 定義（TypePtr, TypeArray, TypeFn, Deref, AddrOf, AssignDeref, Cast を含む）
  lexer.mll       — ocamllex（hex リテラル、& トークン、as キーワード、^ トークン、-> トークン、void キーワード含む）
  parser.mly      — Menhir（ポインタ型、配列型、関数ポインタ型、前置 * / & / 単項 -、as キャスト含む）
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
  print_ptr/
    print_ptr.tkb — ポインタ値を int キャスト（as int）して16進表示するデモ
    print_ptr.expected
  mem/
    mem.tkb       — memset/memcpy デモ（スタック配列 [char; 5] を使用）
    mem.expected
  array/
    array.tkb     — 配列の読み書き・デケイのデモ
    array.expected
  fizzbuzz/
    fizzbuzz.tkb  — FizzBuzz（% 剰余・if/else if チェーン）
    fizzbuzz.expected
  fibonacci/
    fibonacci.tkb — フィボナッチ数列（反復版、10項出力）
    fibonacci.expected
  bubblesort/
    bubblesort.tkb — バブルソート（arr[i]=v 書き込み・arr[i] 読み出しのデモ）
    bubblesort.expected
  ringbuf/
    ringbuf.tkb   — リングバッファ（&mut_var・buf[*ptr]=val・% 折り返しのデモ）
    ringbuf.expected
  callstack/
    callstack.tkb — 複数関数の呼び出し順テスト（スタック動作確認）
    callstack.expected
  crc8/
    crc8.tkb      — CRC-8/SMBUS 計算（ポインタ走査・^ XOR・<< シフト）
    crc8.expected
  djb2/
    djb2.tkb      — djb2 XOR ハッシュ関数（<< と ^ を使用）
    djb2.expected
  bump/
    bump.tkb      — 簡易バンプアロケータ（グローバル配列 [char; 256] を使用）
    bump.expected
  timer/
    timer.tkb     — PL031 RTC でポーリング 1 秒 delay のデモ
    timer.expected
  rtc/
    rtc.tkb       — PL031 RTC の複数レジスタ読み出し・tick 計測
    rtc.expected
  irq/
    irq.tkb       — GICv2 割り込みコントローラ経由の UART RX 割り込みハンドラ登録デモ（関数ポインタテーブル）
    irq.expected
    irq.stdin     — qemutest 用スクリプト入力
  scheduler/
    scheduler.tkb — ラウンドロビン協調スケジューラ（関数ポインタ配列、task_finish による終了通知）
    scheduler.expected
  preempt/
    preempt.tkb   — プリエンプティブスケジューラ（ARM Generic Timer + GICv2 + コンテキストスイッチ）
    preempt_asm.S — ARM Generic Timer システムレジスタスタブ4本 + task_exit_stub のみ（35行）
    preempt.expected
  semaphore/
    semaphore.tkb   — セマフォ（ldaxr/stlxr によるアトミック実装）のデモ。2タスクが各3回 sem_wait/sem_post → shared_count == 6 を確認
    semaphore_asm.S — ARM Generic Timer スタブ + sem_wait（ldaxr+stxr）・sem_post（ldxr+stlxr）
    semaphore.expected
  condvar/
    condvar.tkb   — mutex（sem_wait/sem_post の名前付きラッパー）+ 条件変数（シーケンスカウンタ方式）プロデューサー・コンシューマ デモ（5アイテム）
    condvar_asm.S — semaphore_asm.S と同内容
    condvar.expected
scripts/
  run_qemutest.sh — QEMU 結合テストスクリプト（FIFO 同期・タイミング検証付き）
test/
  test_takibi.ml  — Alcotest による parser / type_inf ユニットテスト（99件）
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

### binop を追加するときの更新ファイル
`Ast.binop` に新しいコンストラクタを追加する場合の手順:
- **既存トークンを再利用する場合（3ファイル）**: `lib/ast.ml`、`lib/type_inf.ml`、`lib/llvm_gen.ml`
- **新しいシンボルを追加する場合（5ファイル）**: 上記3ファイルに加えて `lib/lexer.mll`（トークン定義）、`lib/parser.mly`（優先順位・文法規則）

OCaml の網羅性チェック（exhaustive match）がコンパイルエラーで漏れを教えてくれる。

### ビット演算の優先順位（C とは異なる点あり）
`&`（Band）は比較演算子より**高い**優先順位を持つ（C では低い）。
これにより `n & mask == 0` は `(n & mask) == 0` と解釈される（C の有名な落とし穴を回避）。
`^`（Bxor）は比較演算子より**低い**（C と同じ）。`a ^ b == c` は `a ^ (b == c)` になる。
`|`（Bor）は `^` より**低い**（C と同じ）。`a | b ^ c` は `a | (b ^ c)` になる。
`>>`（Shr）と `<<`（Shl）は `&` より高く `+/-` より低い。`n >> 4 & 0xf` は `(n >> 4) & 0xf` になる。
`%`（Mod）は `*` `/` と同じ優先順位（乗除算グループ）。

優先順位（低→高）: `||` < `|` < `^` < 比較 < `&` < `as` < `+/-` < `>>` `<<` < `*/` `%` < 単項

### 単項マイナスはパーサで脱糖
`-expr` は `BinOp(Sub, IntLit 0, expr)` に変換される（`parser.mly` の `%prec UNARY` ルール）。
AST・型推論・codegen を変更せずに済む。LLVM IR でも `sub i32 0, %x` が整数否定の正規形。

### as キャストは5ファイルで構成
`expr as T` を追加した際の変更ファイル:
1. `lib/ast.ml` — `Cast of type_expr * expr` コンストラクタ
2. `lib/lexer.mll` — `"as"` キーワード
3. `lib/parser.mly` — `%nonassoc AS`（算術より低優先度）、`expr AS type_expr` 規則
4. `lib/type_inf.ml` — ソース式をチェックしてターゲット型を返す
5. `lib/llvm_gen.ml` — `coerce` 関数でターゲット型ごとに変換命令を選択:
   - `int → char`: `trunc i32, i8`
   - `char/i1 → int`: `zext`
   - `int → *T`: `zext i32, i64` → `inttoptr`（MMIO アドレス代入）
   - `*T → int`: `ptrtoint ptr, i64` → `trunc i64, i32`（ポインタ値の表示）
   - `*T → *U`: **no-op**（LLVM 19 では全ポインタが同じ `ptr` 型なので `coerce` の先頭の `if vty = dst_ll then v` が適用される。コンパイラ変更不要）

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

### グローバル配列と未初期化グローバル変数
`let heap: [char; 256];` のような未初期化グローバル変数宣言をサポートする。

- LLVM IR では `undef` として emit する（`zeroinitializer` ではない）
- `startup.S` が BSS セクションをゼロクリアするため、実行時には必ずゼロになる
- 配列型 `[T; N]` はグローバルスコープでのみ宣言可能。関数引数としては `*T` に decay する

`gen_global` の未初期化ケース:
```ocaml
| None -> undef llty  (* BSS はstartup.Sがゼロクリアするので安全 *)
```

### 関数ポインタ型は5ファイルで構成
`fn(T...) -> R` 型を追加した際の変更ファイル:
1. `lib/ast.ml` — `TypeFn of type_expr list * type_expr` コンストラクタ
2. `lib/lexer.mll` — `"->"` トークン、`"void"` キーワード
3. `lib/parser.mly` — `fn_type` 非終端記号（`FN LPAREN type_list RPAREN ARROW type_expr`）
4. `lib/type_inf.ml` — `Var` で関数名を `fenv` から `TFun` として取得、`Call` で直接呼び出し／間接呼び出し両対応
5. `lib/llvm_gen.ml` — `ltype_of_ast (TypeFn _) = pointer_type context`（opaque ptr）、間接呼び出しは `function_type` を再構成して `build_call`

**LLVM 19 における関数ポインタの実態**:  
LLVM 19 はすべてのポインタが `ptr` 1 種類（opaque pointer）。`fn(int) -> char` も `fn() -> void` も LLVM IR 上は同じ `ptr`。型の区別は takibi の型チェッカーが担い、呼び出し命令（`build_call`）に `function_type` を渡すことで正しい calling convention が生成される。C の `void*` とは異なり、takibi の型チェッカーが署名の一致を強制する。

### extern fn は5ファイルで構成
`extern fn timer_init();` のような外部アセンブリ関数宣言を追加した際の変更ファイル:
1. `lib/ast.ml` — `ExternFuncDef of ident * (ident * type_expr option) list * type_expr option`
2. `lib/lexer.mll` — `"extern"` キーワード
3. `lib/parser.mly` — `EXTERN FN IDENT LPAREN params RPAREN (ARROW type_expr)? SEMI` 規則
4. `lib/type_inf.ml` — `fenv` の Pass 1 で `TFun` を追加、`genv` の fold で `ExternFuncDef _ -> m`
5. `lib/llvm_gen.ml` — Pass 1 で `declare_function` を emit（Pass 2 は `ExternFuncDef _ -> ()`）

### 同期プリミティブの実装パターンと現状の制限

`examples/semaphore/` と `examples/condvar/` で実装した同期プリミティブの構造:

```
assembly (ldaxr / stlxr)
  └── sem_wait / sem_post          ← アトミック保証はここだけ（extern fn）

takibi
  └── mutex_lock / mutex_unlock    ← sem_wait/sem_post の名前付きラッパー
  └── cond_wait / cond_signal      ← シーケンスカウンタ方式（takibi で記述）
```

**`sem_wait` の ldaxr/stxr パターン（semaphore_asm.S）**:
```asm
sem_wait:
.Lw_retry:
    ldaxr   w1, [x0]     // load-exclusive + acquire barrier
    cbz     w1, .Lw_zero // counter == 0 → 待機
    sub     w2, w1, #1
    stxr    w3, w2, [x0] // store-exclusive
    cbnz    w3, .Lw_retry
    ret
.Lw_zero:
    clrex                // exclusive monitor をクリア（必須）
    b       .Lw_retry
```
`sem_post` は `ldxr` + `stlxr`（release）。

**`cond_wait` の取りこぼし防止（condvar.tkb）**:
```takibi
fn cond_wait(seq: *int, m: *int) {
    let s: int = *seq;    // ① mutex を持ったままシーケンスを読む
    mutex_unlock(m);       // ② アンロック
    while (*seq == s) {}  // ③ *seq は volatile load — スピン
    mutex_lock(m);         // ④ 再取得
}
```
① でシーケンスを保存してから ② でアンロックするため、アンロックとスピン開始の間に
`cond_signal` が来ても取りこぼさない。

**現状の制限: シングルコアのみ保証**
- `sem_wait` / `sem_post` は `ldaxr`/`stlxr` を使うためアトミックだが、
  `cond_signal` の `*seq = *seq + 1` はアトミックではない。
  常に mutex を持った状態で呼ぶ規約により、シングルコアでは正しく動作する。
- `cond_wait` のスピン `while (*seq == s) {}` はハードウェアメモリバリアを持たない
  通常の volatile load。シングルコア(QEMU)では問題ないが、マルチコアでは
  `ldar`（load-acquire）を使ったスピンに置き換える必要がある。
- マルチコア対応には `cond_signal` のアトミック化と `cond_wait` のスピンのバリア追加が必要。

### グローバル変数 volatile 読み出し（割り込み共有フラグ）
LLVM は `while (flag == 0) {}` のようなタイトループで、グローバル変数の load をループ外に
ホイストすることがある（結果: `cbz reg, self` の無限ループ）。
割り込みハンドラと共有するフラグは必ずポインタ経由で読む:
```takibi
let p: *int = &sched_done;   // &global は llvm_gen.ml の AddrOf が global_vars を返す
while (*p == 0) {}           // *p は volatile load（set_volatile true）
```
`AddrOf` は `locals` になければ `global_vars` テーブルを検索して LLVM global value を返す。

### Integer literal → pointer coercion
`let dr: *int = 0x09000000;` は整数リテラルをポインタ型変数に代入する。
`llvm_gen.ml` の `coerce` 関数が `inttoptr(zext(i32, i64), ptr)` を emit する。

### Makefile の例題登録規約
`EXAMPLES` リストに名前を追加するだけで新例題を登録できる。
規約: `examples/<name>/<name>.tkb` → `examples/<name>/kernel.elf`

```makefile
EXAMPLES := start hello echo print_int print_hex print_ptr mem array fizzbuzz fibonacci bubblesort ringbuf callstack crc8 djb2 bump timer rtc irq scheduler preempt semaphore condvar  # ← ここに追加するだけ
```

`qemu-echo` のようにインタラクティブな手動起動が必要なターゲットだけ個別に追加する。
自動化できるプログラムは `qemutest` に `.expected` / `.stdin` ファイルを用意して登録する。
タイミング検証が必要なテスト（delay が正しく動いているか確認）は `run_test_timed` を使う。

**追加アセンブリが必要な例題**（`*_asm.S` を持つもの）は `GENERIC_KERNELS` フィルタから除外して個別リンクルールを書く:
```makefile
GENERIC_KERNELS := $(filter-out examples/preempt/kernel.elf examples/semaphore/kernel.elf examples/condvar/kernel.elf, $(ALL_KERNELS))
```
新たに `*_asm.S` を追加する場合は、このフィルタへの追加・専用リンクルール・`clean` の `rm -f` への追記の3点が必要。

## QEMU ベアメタル（AArch64）

- マシン: `virt`, CPU: `cortex-a53`
- PL011 UART レジスタ: `0x09000000`（QEMU が事前初期化するので baud rate 設定不要）
- PL031 RTC レジスタ: `0x09010000`（RTCDR: +0、RTCCR: +0x0C）— 1 秒粒度の時刻カウンタ
  - RTCCR は QEMU で常に 1 を返す（RTC が常時動作中）
  - ARM Generic Timer（`mrs` 命令）は takibi からは直接呼び出し不可（システムレジスタのため）
- ロードアドレス: `0x40000000`（QEMU virt の RAM 開始アドレス）
- セミホスティング exit: `SYS_EXIT` (x0=0x18) + AArch64 拡張フォーマット
  - x1 は値ではなく `[ADP_Stopped_ApplicationExit, 0]` の 2 ワードブロックへのポインタ
  - QEMU 起動オプション: `-semihosting-config enable=on,target=native`
- アセンブラ: `llvm-mc-19`、リンカ: `ld.lld-19`
- QEMU 結合テストは named pipe (FIFO) 経由で stdin を同期供給する（`scripts/run_qemutest.sh`）
- `startup.S` は全例題共通で IRQ/FIQ を有効化済み（`msr DAIFClr, #0x3`）。GIC 未初期化時は全割り込み無効なので既存例題に影響しない
- 例外ベクタテーブル（2KB アライン）: EL1t/EL1h の IRQ・FIQ エントリがすべて `irq_entry` に接続済み。`irq_entry` はレジスタ全保存後 `irq_dispatch` を呼ぶ。takibi プログラムが `irq_dispatch` を定義しない場合は `.weak` な no-op が使われる
- GICv2（`0x08000000`）: QEMU virt に内蔵。セキュリティ拡張なし（`secure=on` 不使用）では GICD_CTLR bit0=EnableGrp0。GICD_IGROUPR を書かなければ全 SPI は Group0 のまま。GICC_CTLR.FIQEn=0（デフォルト）では Group0 割り込みは IRQ として届く（0x280: EL1h IRQ ベクタ）。FIQEn=1 にして初めて FIQ（0x300）に届く
- ARM Generic Timer（EL1 物理タイマ）:
  - `cntp_tval_el0`: countdown timer value レジスタ（発火までのカウント）
  - `cntp_ctl_el0`: bit0=ENABLE（1 で有効）
  - `cntfrq_el0`: タイマクロック周波数（QEMU virt では 62500000 = 62.5 MHz）
  - PPI #30 (GICD_ISENABLER0 bit30) で GIC に接続
  - `cntfrq_el0 / 64 ≈ 15 ms` 間隔で発火させる場合は `lsr x0, cntfrq, #6` → `msr cntp_tval_el0, x0`
  - 仮想タイマ（CNTV、PPI #27）は QEMU virt では EL2 ハイパーバイザ設定が必要なため、
    ベアメタル EL1 では物理タイマ（CNTP、PPI #30）を使う

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
