# Phase 15 検証計画と golden モデル

本書は `doc/phase15_core_design.md` (以下「設計書」) の検証側の正本である。設計書第 0 部の D1-D4 (§1.4) と、retire record (§5.12)、割込みの受付点 (§5.13)、I/O 規則 (§5.14)、レビューゲート (§5.15) を、ゲート・ハーネス・golden モデル・比較手順として具体化する。設計書の契約は再定義せず、「設計書 §5.12」の形で参照する。旧コアの行番号はすべて凍結コミット `b0f4668` のもの。マークの意味は設計書 §1.2 に従う。

用語:

| 語 | 意味 |
|---|---|
| golden | `b0f4668` に観測専用パッチを当てた旧コア。別 worktree でだけビルドする (D1)。 |
| V14 | master 上で `v14_` に改名された旧コア。SoC の `CORE=V14` で選ぶ。M6 まで既定コアとしてゲートを通り続ける (D6)。golden とは別物。 |
| W2 / W4 | 新コアの `cfg_w2` / `cfg_w4` (`CORE=W2/W4`)。 |
| record | `retire_pkg::RetireRec` 1 個 (設計書 §5.12)。`IrqEvent` は record ではない。 |
| trace | record と IrqEvent を order 順に直列化したテキスト。lane 数に依存しない (§4.4)。 |
| schedule | golden の割込み列 `(order, cause)` (D2)。 |
| checkpoint | 一定 record 数ごとの rolling hash `(order, hash)` (§4.5)。 |

---

## 1. ゲートの梯子

### 1.1 ゲート一覧

【決定】ゲートを次の ID で呼ぶ。理由: マイルストーンと構成の組合せごとに「何が守られているか」を表で検査できるようにするため。走らせないゲートは守られていない (旧コアでは N=4 boot のライブロックが 18 コミット、ゲスト Linux の破損が 2 か月見逃された)。

| ID | 内容 | 起動 | 判定 |
|---|---|---|---|
| G0 | 既定 `veryl test` (旧コアの既定テスト + 新コアの生成ラッパ) | 毎コミット | 全 pass。新コア分は checker 0 と lockstep 一致を `o_pass` に含む (§2.3) |
| GL-A | arch 系 lockstep。G0 の新コア生成ラッパが golden の checkpoint とオンライン比較する | G0 に含む | checkpoint と最終 `(order, hash)` が一致 |
| GA | ACT4 pass/fail (`--ignored --test test_act_`、コアは §2.5 の define で選ぶ) | マイルストーン内の節目 | tohost==1、checker 0 |
| GL-C | ACT4 lockstep。GA のログの最終 H 行を `test/golden/check_hash.py` が golden と照合 | GA と同時 | script の exit code |
| GL-B | 5.15 N=1 boot lockstep (ADUE off、`MTIME_SRC=INSTRET`、schedule replay) | `--ignored` | x3==0xAA、checkpoint 一致、割込み assert 0 |
| GB1 | N=1 boot pass/fail: 6.6、7.1 (FP、ADUE)、7.1v (M5) | `--ignored` | x3==0xAA |
| GT2 / GT4 | litmus N=2 (既定) / N=4 | GT4 は `--ignored` | tohost==1 |
| GB2 / GB4 | SMP boot N=2 / N=4 (5.15。6.6/7.1 の SMP はマイルストーン末) | `--ignored` | hart 0 の x3==0xAA |
| GH | hvlinux (V=1 の二段翻訳を負荷下で通す唯一のゲート) | `--ignored` | x3==0xAA |
| GX | W2 対 W4 の差分 lockstep (§4.6) | マイルストーン末 | trace 一致 |
| GV | Verilator 相互確認 (`sim/verilator/` の既存ラッパ) | マイルストーン末 | PASSED 行 |
| GS | 速度と whole-comb fallback (§6) | マイルストーン末 | fallback 0、cy/s を記録 |
| GF | 発火行列 (§5.2) | マイルストーン末 | `fire_check.py` の exit code |

### 1.2 マイルストーン × 構成

【決定】新コアのゲート投入時期を下表に固定する。理由: SMP は M4、H/V は M5 で初めて機能が揃うが、揃ったマイルストーンからは両構成で常に回し、後から足さない。

| ゲート | M1a | M1b | M2 | M3 | M4 | M5 | M6 |
|---|---|---|---|---|---|---|---|
| G0 新コア分 | (新コアは無い。V14 の梯子 1-5 と SoC の unit test、spike の unit test) | W2: rv64ui 54 を lockstep。W4: rv64ui を pass/fail (最低でも ALU・分岐・load/store 群、目標は 54 全部) | W2: スカラ arch 全部 (lockstep 対象は §4.6) + smode_plic + 新規 directed (§7.4)。W4: rv64ui 全部 | W2 と W4 で同一リスト | + litmus N=2 (W2, W4) | + H 17 本、V 20 本、test_vmspre | 既定コアを新コアに |
| GA / GL-C | | | W2 | W2, W4 | 同 | 同 | 同 |
| GL-B | | | W2 | W2, W4 | 同 | 同 | 同 |
| GB1 | | | W2: 6.6, 7.1 | W2, W4 | 同 | + 7.1v | 同 |
| GT4, GB2 | | | | | W2, W4 | 同 | 同 |
| GB4 | | | | (新コアの SMP は無い。回し方を D7 の測定で決める、§6.3) | M3 の決定に従う (W2, W4) | 同 | 同 |
| GH | | | | | | W2, W4 | 同 |
| GX | | | | 決定的なテスト全部 | 同 | + H/V | 同 |
| GV | | | N=1 boot (W2) | N=1 (W2, W4) | + litmus4, N=2, N=4 | + hvlinux | 全部 |
| GS / GF | S1 の対照を記録 | 記録 | 記録 | 記録 + M3 判定の材料 | 同 | 同 | 同 |

旧コア (V14) は M6 まで既定コアであり、CLAUDE.md の梯子 1-5 (既定、litmus4、N=2 boot、N=4 boot、hvlinux) をそのまま回し続ける。

### 1.3 コミットごとの運用

- 新コアだけを変えるコミット: G0。M2-M3 では GL-B が最初の実ゲートになる (旧コアの「N=2 boot が最初の実ゲート」に相当)。
- メモリ系 (`lsu/`、`mem/`、dcache、MMU、SoC) を変えるコミット: M4 以降は GB4 必須 (設計書 §2.5)、M5 以降は GH も必須。front end と予測器の変更は M4 以降 GB2 必須。新コアの SMP は M4 から存在するので、M3 の dcache 2 ポート化 (bank、ポートごとの tag、MSHR file の構造) は `MSHR_N=N_FILL=1` のまま N=1 のゲート (G0、GA、GL-B、GB1、GX) で検査する。`MSHR_N`/`N_FILL` を 1 より大きくするコミットは、M4 で新コアの GB4 ができた後に限り、1 つずつ GB4 をゲートとする。
- 共有モジュール (CLINT、csr、SoC、dcache/MMU への追加出力) または V14 に触れるコミット: V14 で梯子 1-5 を回す。共有モジュールの変更は M2 まで追加のみ (設計書 §4.4) なので、V14 の dhrystone/coremark の cycles と instret はビット一致するはずであり、それを受入条件にする。
- サイクル予算は早期終了つきの上限であり、理由なく増やさない。ハーネスの載せ替えで予算が足りなくなった場合は、同じハーネスで V14 を測り、その値を根拠として記録してから変える。

---

## 2. ハーネスの載せ替え (D3)

### 2.1 統合 SoC

【決定】M1a で (v14 改名と spike の後に) `heliodor_soc` を削除し、`heliodor_soc_smp` に統合する。V14 の N=1 boot (5.15/6.6/7.1/7.1v) と hvlinux が統合 SoC (`N_HARTS=1`) で通ることを確認し、cy の新しい基準値 (10,000 刻み) を記録する。統合で cy が動くのは platform の変更として扱い、README の数値の出所を併記する。

統合 SoC に追加するパラメータとポート (所有者は設計書 §S.1 と §S.5、ここでは検証が要求するものだけを挙げる):

| 名前 | 種別 | 内容 |
|---|---|---|
| `CORE` | param enum `V14/W2/W4` | generate-if でコアを選ぶ (設計書 §3.6、D6)。 |
| `N_HARTS` | param ≥ 1 | `N_HARTS=1` で幅 0 の信号が生じないこと (`idx_w` 相当の helper を使う)。 |
| `PMA_REGIONS` | const struct 配列 param | 設計書 §5.11。harness ごとの表は §2.2。 |
| `MTIME_SRC`, `MTIME_DIV` | param | §4.1。既定は `CYCLE`、`MTIME_DIV=10` (現行と同じ)。 |
| `o_retire`, `o_irq_evt` | 出力 `[N_HARTS]` | 新コアの retire port をそのまま出す。lane 数は `CORE` から導く定数で決める。V14 では valid=0。 |
| `o_perf`, `o_chk`, `o_chk_io` | 出力 | 設計書 §4.5 の event wire と checker flag、§8 の IO モニタ。 |
| `i_dbg_retire_limit_en/limit`, `i_dbg_irq_mask/allow` | 入力 `[N_HARTS]` | 設計書 §5.13。harness が駆動しない限り 0。 |
| `i_mtime_tick` | 入力 | `MTIME_SRC=EXTERNAL` のときだけ使う (§4.7)。 |
| `i_ext_irq_src` | 入力 | PLIC の追加ソース。smode_plic の tb パルス用。既定 0。 |
| V14 用の `o_dbg_r3/pc/retire_v/trap_*` | 出力 | V14 の既存 harness が読むものだけを残す。消費者のない 23 本の forensic 出力は統合時に削除する。 |

Veryl では未接続の入力は警告にしかならず、浮いたまま動作が変わりうる。新しい harness はすべての入力を明示的に接続し、新規ファイルの `missing_port` 警告は 0 とする (設計書 §5.15 の lint 差分)。

### 2.2 PMA map パラメータ

PMA 表の型と評価関数は設計書 §5.11、boot 系のプラットフォームマップの値と表の不変条件は設計書 §S.2 が持つ。harness ごとに使う表を `tb/tb_platform_pkg.veryl` に置く。

| 表 | 使う harness | 内容 (旧コアとの違い) |
|---|---|---|
| `MAP_BOOT` | N=1/SMP boot、hvlinux、smode_plic | ROM [0, 0x4000) は executable かつ uncacheable。DRAM 0x8000_0000 から 32 MiB。CLINT/PLIC/UART は IO。旧コアは ROM を hole に置き、`PMA_FAULT=0` で hole 判定を切っていた。 |
| `MAP_ARCH` | arch、ACT4、bench | ROM なし。DRAM は harness の配列サイズ (4 MiB、bench は 256 KiB)。0x5000_0000 (`RVMODEL_ACCESS_FAULT_ADDRESS`) は hole。旧コアは pa[31] だけを見て 2 GiB を backed とし、PA[63:32] を無視していた (付録 B の B34)。 |
| `MAP_LITMUS` | litmus | DRAM 32 MiB、ROM なし。tohost の write-through 窓は存在しない (設計書 §5.11 PM5)。 |

harness の DRAM 配列サイズと表の DRAM 領域の一致は harness 内の const で検査する。設計書 §5.11 PM6 の照合は `test/gates/pma_check.py` が行う。照合対象は `tb_platform_pkg` の表、`test/linux/dts/*.dts` の memory/CLINT/PLIC/UART ノード、`test/act/config/heliodor/sail.json` の領域、`rvmodel_macros.h` の hole アドレスである。ずれは exit code で失敗とし、マイルストーン末と表を変えたコミットで回す。

### 2.3 retire port からの合否検出: `retire_mon`

【決定】合否と計数はすべて tb モジュール `retire_mon` (hart ごと) が新コアの retire port から作る。理由: tohost の write-through 窓と arch_regs shadow をコアから除けるのは、観測を retire port に一本化した場合だけだから (設計書 §5.11 PM5、§5.5)。

| 出力 | 定義 |
|---|---|
| `x3` | lane 順に走査し、`rd_kind==INT && rd_addr==3` の `rd_wdata` を反映した shadow (若い lane が勝つ)。boot の pass = hart 0 の `x3 == 0xAA`。 |
| `tohost` | 最初の record で `mem_paddr == TOHOST_PA && mem_wmask != 0` を満たすものの `mem_wdata[31:0]` を保持する。`TOHOST_PA = 0x8000_0000 + 4*TOHOST_IDX`。litmus では全 hart の OR を取る。 |
| `o_pass` | tohost 系 harness (arch、ACT4、bench、litmus) は `tohost == 1`、boot 系 (N=1/SMP boot、hvlinux、smode_plic) は hart 0 の `x3 == 0xAA`。どちらも `&& chk == 0 && !hash_mismatch` を付ける。checker と lockstep 不一致を pass に含めるので、テスト本体を変えない ACT4 でも検査が効く。 |
| `o_fail` | `(tohost != 0 && tohost != 1) || chk != 0 || hash_mismatch`。旧 harness の「偶数の非 0」は、riscv-tests の `(TESTNUM<<1)\|1` と ACT4 の HALT_FAIL=3 を取り逃がしていたので改める。 |
| `cycles`, `instret` | tohost の store を含む record が出たサイクルで凍結する。`instret` は `popcount(valid && !trap)` の累計 (64 bit)。旧コアの「instret」(ROB の pop 数、32 bit、trap を含み、最大 1 サイクル遅れ) とは比較しない。 |
| `last_pc`, `ret_cnt`, `trap_cnt` | SMP/litmus の生存プローブ用。旧 `o_dbg_pc` (ROB head の pc) の代わりに最後に retire した pc を出す。 |
| `chk` | `o_chk` と §5.1 の tb 側 checker の OR (sticky)。 |
| `o_done` | tohost 系は `tohost != 0`、boot 系は `x3 == 0xAA`。どちらも `\|\| chk != 0 \|\| hash_mismatch` を付ける。早期終了に使う。riscv-tests は x3 (gp) を TESTNUM に使うので、tohost 系では x3 を見ない。 |

早期終了: 新コアの生成ラッパは `for _i in 0..(BUDGET/1000) { clk.next(1000); if done { break; } }` で回す。boot は現行どおり 10,000 刻み。arch の予算 (100K/200K/300K/500K) は上限としてそのまま使う。ACT4 は生成テンプレートを変えないので `clk.next(300000)` の固定長で走る (§2.5)。

litmus の histogram (0x8000_4000) と barrier 語 (0x8000_6000) の DRAM ダンプは、write-back L1 の新コアでは古い値を読みうる。合否には使わず、印字専用であることをハーネスのコメントに書く。

### 2.4 ハーネスごとの扱い

| harness | ファイル | 現在の利用 | 扱い |
|---|---|---|---|
| `test_arch_common_harness` | tb/test_arch_common.veryl:10-319 | arch 201 + FP 28 + fp_smoke + lrsc_reorder + ACT4 696 | 移植。`CORE` で分岐し、V14 枝は現在の本体 (平坦メモリ、`PMA_FAULT=1`、`COHERENT_IFETCH=0`、DRAM の tohost 監視) を `v14_arch_bare` に逐語移設する。新コア枝は統合 SoC + `MAP_ARCH` + `retire_mon` + `rvfi_tracer`。ポート (`o_pass/o_fail/o_tohost`) と param (`HEX_FILE/TOHOST_IDX/MTIME_EN`) は変えない。 |
| `test_arch_common_harness_dbg` | 同 :321-500 | どこからも instantiate されていない | 削除 (M1a の最初)。 |
| `test_perf_harness` | tb/test_bench.veryl:14-335 | bench 5 本 | 移植。V14 枝は逐語移設する (設計書 §4.4 の改名受入で dhrystone/coremark のビット一致を測る基準なので、1 bit も変えない)。新コア枝は `retire_mon` の凍結値と `o_perf` の合計を出す。旧 census ポートは新コアでは出さない。 |
| `test_smode_plic_harness` | tb/test_smode_plic.veryl | 既定 1 本 | 移植。新コア枝は統合 SoC (`MAP_BOOT`、ROM に hex) で、source 10 のパルスは `i_ext_irq_src` から入れる。2,000 サイクル予算は SoC 経由の遅延で足りなくなりうるので、V14 を同じ SoC 構成で測った値の 2 倍に改める (§1.3)。PLIC claim の読み出し回数 == 1 を assert に加える (§8)。 |
| `test_smoke`, `test_hello`, `test_linux_boot` | 同名 .veryl | `#[ignore]`、梯子の外。forensic `o_dbg_*` の唯一の消費者 | 削除 (M1a の最初、v14 改名より前)。 |
| `test_soc_linux_boot_harness` (+66/71/71v) | tb/test_soc_linux_boot*.veryl | N=1 boot 4 本 | 統合 SoC `N_HARTS=1` へ移す。`CORE` param を足す。x3 は V14 なら `o_dbg_r3`、新コアなら `retire_mon`。census の印字は V14 枝だけに残す。lockstep 用の param (`MTIME_SRC`、schedule、checkpoint ファイル) を足す。 |
| `test_soc_smp_linux_boot_harness` (+66/71) | tb/test_soc_smp_linux_boot*.veryl | SMP boot 7 本 | `CORE` を足す。生存プローブと最初の 4 trap の印字は `retire_mon` から作る (旧 `o_dbg_trap_pc` は c_pc で、割込みと偽 ifault で誤っていた)。 |
| `test_litmus_harness` | tb/test_litmus.veryl:17-385 | litmus 3 本 | `CORE` を足す。新コアの tohost は retire store から取る。新コアでは litmus の atomic がどの番地でも cacheable になる。 |
| `test_soc_hvlinux_harness` | tb/test_soc_hvlinux.veryl:15-208 | hvlinux | 統合 SoC `N_HARTS=1` へ移す。`CORE` を足す。 |
| 単体 tb (`test_clint` ほか) | | | `test_clint` は CLINT の新入力を `i_tick_sel=0` に固定すれば無変更で通る (§4.1)。 |
| Verilator ラッパ | sim/verilator/*.sv | N=1/2/4/8 boot、litmus4、hvlinux、ACT PMP | 変更しない。harness の名前とポートだけに依存しているので、`CORE` の既定値 (§2.5) に従う。 |

### 2.5 コアの選択と旧コアとの共存 (D6)

- SoC と各 harness は `CORE` param を持ち、generate-if で枝を選ぶ。V14 枝は旧 harness 本体の逐語移設なので、V14 のゲート結果は動かない。M6 では V14 枝と `src/v14/`、V14 専用の印字を削除し、`CORE` の既定値を変える。
- 【決定】新コアのテストは、ゲートリスト `test/gates/<milestone>.list` から `test/gates/gen_core_tests.py` が生成するラッパ (`tb/test_w2_*.veryl`、`tb/test_w4_*.veryl`) で走らせる。生成物は既定スイートに入るのでコミットする。ラッパは `CORE` を明示し、早期終了ループと golden checkpoint ファイルの param を持つ。理由: 1 回の `veryl test` で V14 と W2/W4 を同時に回せる。
- 【M1a で決定】テンプレートを変えない既存テスト (ACT4 の生成テスト、`test_arch_fp` 等) と Verilator ラッパは、harness の `CORE` の既定値 `tb_core_sel::CORE` に従う。この定数を `#[ifdef]` で切り替え、`veryl test --define CORE_W2` (および Verilator 用の `veryl build`) で新コアを選ぶ案を spike (設計書 §3.7) で確かめる。測るのは、package const への `#[ifdef]` が `test` と `build` の両方で効くかどうかである。だめなら Verilator 用に `#(.CORE(...))` だけを足した新しいラッパファイルを追加し、既存ファイルには触れない。define を切り替えると `.build` の再構築が起きるので、構成ごとに worktree を分けるか直列に回す (veryl は同時に 1 起動まで)。
- ACT4 の生成テンプレート (`test/act/gen_suite.py`) は変えない。テンプレートは harness 名、3 つのポート、`HEX_FILE/TOHOST_IDX/MTIME_EN` にしか依存しておらず、checker と lockstep の判定は §2.3 で `o_pass` に畳み込まれている。代償として ACT4 は早期終了せず、1 本 300K サイクルを使い切る。
- Verilator で新コアを回すときは `build_w2_n1` のように Mdir を構成ごとに分け、構成を変えたら `rm -rf` してから作り直す。4-hart top は `-O1 -j 2` で作る。

### 2.6 20 テストの時間測定と flat-memory slot adapter

【M1a で決定】arch 系を統合 SoC に載せるか、flat-memory slot adapter に載せるか。測るものは、SoC に載せたことによるシミュレーション時間の倍率 f である。

- 対象 20 本: rv64ui の add, lw, sd, jal, fence_i, ld_st, ma_data。rv64um の div。rv64ua の amoadd_d, lrsc。rv64uc の rvc。rv64uf の fadd, fdiv。rv64ud の fcvt。rv64mi の csr, illegal。rv64si の dirty。directed の test_arch_cmo, test_arch_svnapot。ACT4 の I-addi-00。
- 手順: `VERYL_AOT_C_ASYNC=0`、直列、同じ木。`.build/test_timings` の RUN 秒 (モデルのビルドは除く) を読む。(a) V14 + 現行の平坦ハーネス、(b) V14 を統合 SoC に載せた一時ハーネス (計測専用。`PMA_FAULT` 依存のテストは除く)、(c) W2 + 統合 SoC。いずれも早期終了つきで測る。
- 判定: f = Σ(b)/Σ(a) が 1.5 以下なら統合 SoC のままにする。超えたら adapter を作る。(c)/(b) は新コア自身のコストなので、この判定には使わず §6 に記録する。

adapter (`tb/tb_flat_slot_mem.veryl`) の仕様: コアの外部ポート (設計書 §4.5 の D read slot、I read slot、write channel、coherence 入力) にそのまま接続する。mem_ctrl と同じ accept + 8-beat STREAM (DRAM 領域) と legacy single-beat (非 DRAM) を、平坦配列から即時の accept で返す。write channel は即 grant し、coherence 入力は 0 に固定する。CLINT と UART の印字は `pma_check` でデコードして harness に置き、PLIC は持たない (smode_plic は常に統合 SoC で走らせる)。コア側には knob を足さない (D3)。


#### 2.6.1 結果 (2026-10-14、M1a 手順 7)

【決定】f = 1.21 / 1.25 (2 回の測定) で 1.5 以下。新コアの arch テストは統合 SoC に載せる。flat-memory slot adapter は作らない。

- 20 本すべてが統合 SoC 上の V14 で tohost=1 になった。除外したテストは無い。
- サイクルあたりのシミュレーション時間の比は約 1.22 (SoC 10.9 us 対 平坦 8.9 us)。
- V14 が pass までに要するサイクル数は SoC 上で約 1.49 倍 (mem_ctrl/L2 の遅延。平坦メモリは遅延 0)。
- 現行の平坦ハーネスは早期終了しない。早期終了を入れると arch 系の時間は約 1/18 になり、1 本あたり約 0.13 s の固定費 (simulator の生成と hex 読み込み) が支配的になる。新コアの生成ラッパに早期終了を入れる (§2.3) 効果はこちらの方がはるかに大きい。

---

## 3. golden モデル (D1)

### 3.1 置き場所とビルド

【決定】次の配置にする。理由: master の veryl は Phase 15 中に spike の修正で進むが、旧い src は新しい veryl でビルドできなかった前例があるため、golden は固定した compiler で別にビルドする。

| 項目 | 値 |
|---|---|
| ブランチ | `golden/b0f4668-obs` (親は `b0f4668`)。push しない。 |
| worktree | `.golden/` (master の直下、gitignore)。`Veryl.toml` の sources は `src`/`tb` を明示しているので、master の veryl からは見えない。`.build/lock` も別なので、master の veryl と同時に走らせてよい。 |
| veryl | `.golden/veryl` に `fbd14729` を detached で置き、`cargo build --profile release-verylup` でビルドする。golden の実行は `VERYL=.golden/veryl/target/release-verylup/veryl` で行う。 |
| 駆動 | master 側の `test/golden/run_golden.py <list>` が golden worktree でテストを走らせ、成果物を master の `test/golden/` に書き戻す。未作成 (残作業、M1b の rv64ui trace ゲートより前に要る)。最初の成果物 (§3.5) は手で走らせて書き戻した。 |

### 3.2 パッチの中身 (観測専用)

| ファイル (golden ブランチ) | 変更 |
|---|---|
| `src/core/rob.veryl` | 出力 `o_commit2_instr = sh_instr[head1_idx]` を追加 (lane 1 の insn。`sh_instr` は rob.veryl:467 に既存)。 |
| `src/core/golden_rvfi_adapter.veryl` (新規) | §3.3 の正規化をすべてここに書く。入力は旧コアの内部信号、出力は `RetireRec [2]`、`IrqEvent`、tick 計数、`gtag` (§3.3 N14)。実装ではこれに `o_irq_lat` (pending の立ち上がりから受付までの order の差、§3.5 の分布の源) を足した。観測専用で比較対象外。 |
| `src/core/heliodor_core.veryl` | adapter を instantiate し、出力ポート `o_rvfi`、`o_rvfi_irq`、`o_rvfi_gtag` を追加する。既存の論理には触れない。 |
| `src/pkg/retire_pkg.veryl` | master の版を逐語コピーする。vector フィールド `{vec_v, vrf_wcnt, vrf_hash, vtype, vl, vstart}` (設計書 §5.12) は最初の版から含める。adapter は `u_vrf` の書込ポートから `vrf_wcnt`/`vrf_hash` を作り、vector 以外の record ではすべて 0 にする (設計書 §V.7)。 |
| `src/peripheral/clint.veryl` | `i_tick_sel` と `i_tick` を追加する (§4.1。master と同じ変更)。 |
| `src/core/heliodor_soc.veryl` | `MTIME_SRC/MTIME_DIV`、tick 生成、`o_rvfi*` の通過、`i_tick_sel=1` の配線。 |
| `tb/test_arch_common.veryl`, `tb/test_soc_linux_boot.veryl` | harness に `MTIME_SRC` (arch harness では内部の `mtime_ctr` を INSTRET でも進められるようにする)、`rvfi_tracer`、schedule と checkpoint の印字を足す。 |
| `tb/rvfi_tracer.veryl`, `tb/retire_mon.veryl` | master の版を逐語コピーする (trace 形式、MASK、hash の唯一の定義)。 |
| `tb/golden_runs_*.veryl` (生成) | ゲートリストから生成する golden 実行用テスト。未作成 (残作業、M1b の rv64ui trace ゲートより前に要る)。現在あるのは手書きの `test_golden_boot_linux515_n1` だけ。 |

D1 が挙げる 3 点 (adapter、CLINT の tick 入力、schedule printer) に加えて、rolling hash、`gtag`、arch harness の INSTRET モード、retire record の vector フィールドもこのパッチに入れる。どれも観測専用で、旧コアの状態を変えない。

### 3.3 adapter の正規化規則

規則は adapter のソースにコメントとして書き、本表と一致させる (設計書 §5.12)。旧コアの「retire」の定義が 7 通りあり、旧 cosim で規約のずれが偽の不一致を何度も生んだため、どの信号を使うかまで固定する。

| 規則 | 内容 | 根拠 (heliodor_core.veryl) |
|---|---|---|
| N1 lane 0 | `valid = (rob_commit_ack \|\| commit_excp) && !(commit_sc_replay && !commit_excp)`。`rob_commit_valid` と arch_regs は使わない。 | 6402 (ack は sc_replay を除外しない)、7125-7127、8402、7808 |
| N2 trap | `trap = commit_excp`。trap record は `rd_kind=NONE`、`wmask=0`、`csr_valid=0`、`next_pc=0`。cause は `trap_cause`、tval は `i_trap_tval` の式から取る。`o_dbg_trap_pc` (=c_pc) と `o_dbg_stval_out` (登録済みの stval) は使わない。ack=0 で trap する経路 (store を保持中の TVM sfence など) もこれで拾う。 | 7249 (`trap_cause`)、7316、7328-7346、7442-7445、7469 |
| N3 xRET | mret/sret は trap=0 の通常 record にする (旧 `o_dbg_retire_v_a` は除外していた)。 | 7146-7147, 7887 |
| N4 偽 ifault | `inject_fake_ifault` のサイクルは 2 record にする: lane 0 = csrw satp (trap=0、`csr_valid=1`、`csr_wdata=c_csr_wdata`)、lane 1 = 合成 trap {pc=c_pc+4、cause 12、tval=c_pc+4、insn=MASK}。tick 計数では csrw を 1 と数える。設計書 §5.12 により lane の位置は比較対象外なので、trap が lane 1 にあってよい。golden の harness は `retire_mon` を `TRAP_ANY_LANE=1` で instantiate して lane 1 の trap を契約違反にせず、代わりに harness の `i_chk` が「`FAKE_IFAULT` タグの無い lane 1 の trap」を数えて違反とする (§3.4 の 3)。 | 7050-7058, 7316, 7328-7329、csr.veryl:905 対 1047 |
| N5 lane 1 | `valid = commit2_fire`。`o_commit2_valid` は使わない。pc/rd は c2_*、insn は新設の `o_commit2_instr`、next_pc は `c2_arch_next_pc`。lane 1 には trap も store も CSR も来ない。 | 8460, 7570、rob.veryl:592-625 |
| N6 frm 同時 retire | `commit_csrw_frm && commit2_fire` のサイクルは lane 1 の record を出さず、tick にも数えない (直後の再実行が record を出す)。冪等でない op なら値が狂うが、それは golden の誤りとして B04 で扱う。 | 7014, 8451, 7758-7762 |
| N7 rd | lane 0: `c_has_rd && !trap` なら INT (`c_rd_arch`, `c_result_data`)、`c_is_fp_dest` なら FP。amocas.q は `cas_q_retire` で rd と rd2 に `c_cas_q_mem_lo/hi`。priv-illegal (TVM/TSR/FS-off など) は N2 で rd なしになる。 | 6427, 6967, 7826-7837 |
| N8 store | `c_store_eff_pa` (commit が実際に書いた PA)、`c_store_data`、`c_store_funct3` から wmask/wdata を作り、16 B アクセスでは hi 側も載せる。`mem_io = c_store_mmio`。`c_store_pa` は翻訳前の probe の PA なので使わない。 | 6226-6229, 8792-8806, 6375 |
| N9 CSR | `csr_valid = commit_csrwr && would_wr(insn)` (RW、または rs1/uimm != 0)。旧コアは読み出しだけの CSR 命令でも書き込みポートを動かしていたので、その分を落とす。 | 7000、alu_wrap.veryl:461 |
| N10 load | load のアドレスと読み値は出さない (`mem_rmask=0`)。旧コアには commit 時に読めるポートが無い。 | rob.veryl:237-239 |
| N11 割込み | `commit_irq` で `IrqEvent {cause=csr_irq_cause, epc=arch_next_pc_q, order}`。 | 7144, 7316 |
| N12 order と tick | order は正規化後の record 数 (64 bit)。tick 計数 `o_rvfi_tick_cnt` は正規化後の `popcount(valid && !trap)` で、登録済みの record からではなく commit のサイクルの信号から組合せで作る。理由: 旧コアは、古い op が retire した次のサイクルに CSR の読み出しを issue するので、record (1 サイクル後に登録) から tick を作ると、その読み出しは直前の retire の分の tick をまだ見ない。新コアは record から作ってよい (§4.1)。`minstret` (7420) と ROB の `commit_cnt` は使わない。 | 7420、rob.veryl:1719-1730 |
| N13 priv/virt | commit サイクルの `csr_priv`/`csr_virt` (trap による更新の前の値)。 | |
| N14 gtag | 観測フラグ (比較対象外)。trace の行末に `#TAG` として付ける: `FAKE_IFAULT`、`SC_REPLAY`、`FRM_CORETIRE`、`MA_PAGEX` (misaligned アクセスが 4 KiB をまたいだ)、`AMO_VM` (VM 下の AMO の commit)、`PRIV_ILL_RD` (rd を持つ priv-illegal trap)、`SATP_WIN` (csrw satp から次の sfence までの窓)。付録 B の「発火」はこのタグを数えて埋める。`AMO_VM` は現在 VM 下のすべての AMO で立つ (5.15 boot で 18,925 回) ので、W か D を欠くページへの AMO だけに絞るまでは STOP のタグに使えない (付録 B の B10)。 | |

golden の実装 (`golden/b0f4668-obs` の `8ee7a1d`) で分かった、観測の穴と設計からのずれ:

- `MA_PAGEX` は store にだけ付く。load は record にアドレスを出さない (N10) ので、page をまたぐ misaligned load は数えていない。
- cbo.* の record は store を持たない (`mem_wmask=0`)。cbo.zero の書き込みは trace に現れない。
- `vrf_hash` は M5 まで best effort である。vector を使うテストを lockstep に載せる M5 で、`u_vrf` の書込ポートからの作り方を確かめ直す。
- golden の SoC は、§4.1 の elaborate 時の検査 (`MTIME_SRC==INSTRET` のとき `MTIME_DIV ≥` lane 数) を持たない。また単一 hart の構成でしか作っていない。K=10 と lane 数 2 なので現状は問題にならない。

### 3.4 受入条件

1. (D1) 既定パラメータでの dhrystone と coremark の cycles と instret が、パッチ前の `b0f4668` とビット一致すること。
2. 5.15 N=1 boot を `MTIME_SRC=CYCLE` で走らせ、cy (10,000 刻み) と `o_dbg_rob_commit_cnt` がパッチ前と一致すること。CLINT と SoC の変更が時刻の挙動を変えていないことを確かめる。
3. `retire_mon` の retire-contract checker (§5.1 の `chk_retire`) を adapter の出力に当て、arch 全テストと 5.15 boot で違反 0 であること。例外として N4 の lane 1 trap だけを許す (`TRAP_ANY_LANE=1` と harness の `i_chk` による数え上げ、N4)。
4. `test_rvfi_tracer_selftest` (合成した record 列を tracer に流し、既知の hash と canonical テキストを得る) が、golden の veryl `fbd14729` と master の veryl の両方で同じ出力を出すこと。`$display` の書式が compiler の版で変わっても、比較が壊れないことを保証するため。
5. FP の rd 値の自己整合: rv64ud の全テストで、record の FP rd 値が、直後にその値を読む fsd/fmv.x.d の record と一致すること (`c_result_data` に FP の結果が載るという推定を確認する)。

### 3.5 最初の golden 成果物

【決定】パッチの後、他の何よりも先に、golden が `MTIME_SRC=INSTRET`、K=10 で 5.15 N=1 boot を x3==0xAA まで走りきることを確かめ、それを最初の成果物とする。理由: lockstep 全体がこれを前提にしており、retire 数で進む時刻のもとでは割込みの位置が変わるため、旧コアに潜んだタイムアウトや drain 方針の問題があるならここで最初に表に出る。成果物は checkpoint 列、schedule、`gtag` の出現位置、割込みの総数、pending の立ち上がりから受付までの order の差の分布である。付録 B の「発火」列のうち「不明」の欄は、この run の `gtag` 計数で埋める。

結果 (2026-10-14、golden ブランチ `golden/b0f4668-obs` の `8ee7a1d`、veryl `fbd14729`、成果物は master の `0bc2467`):

| 項目 | 値 |
|---|---|
| 終了 | x3==0xAA、cy=0xba4f50 |
| record | 10,417,776 (非 trap 10,415,351、trap 2,425)。最終 hash `14df514488a28718` |
| 割込み | 30 回 (cause 7 が 15 回、cause 5 が 15 回) |
| pending から受付までの order の差 | 最小 0、中央値 2、p90 20、最大 30 |
| `gtag` 計数 | FAKE_IFAULT=1、SC_REPLAY=0、FRM_CORETIRE=0、MA_PAGEX=0、AMO_VM=18,925、PRIV_ILL_RD=0、SATP_WIN=4,241 |
| `SATP_WIN` の窓 (record の範囲) | 76987-76993 (B02 の窓)、2438786、4286867-4286885、10336234-10341956 (約 5.7K record、sfence の無い satp 書き込みの窓で B03 に当たる) |

ファイル: `test/golden/MANIFEST` (上の計数と image の sha256)、`test/golden/boot/linux515_n1.ck.hex` (2^16 record ごとの checkpoint)、`linux515_n1.irq.hex` (schedule)、`linux515_n1.tag.hex` (`gtag` の位置、§3.6)。

- 割込みの受付はすべて最大 30 order 以内に収まった。旧コアに潜むタイムアウトや drain 方針の問題は INSTRET モードでは表に出なかった。
- console の文字が 2 回ずつ出る (`pprriinnttkk`)。パッチ前の `b0f4668` でも同じなので golden の変更によるものではない (付録 B の B46)。
- 窓の中のカーネル page fault の数はまだ測っていない (B03 の判定に要る)。

### 3.6 成果物の扱い

| 成果物 | 置き場所 | コミット |
|---|---|---|
| MANIFEST (golden ブランチの commit、veryl の commit、`TRACER_VER`、`retire_pkg` の sha256、K、各テスト image の sha256) | `test/golden/MANIFEST` | する |
| arch 系の checkpoint (2^10 record ごと + 最終) | `test/golden/arch/<suite>/<test>.ck.hex` | する。未作成 (残作業、M1b の rv64ui trace ゲートより前に要る) |
| ACT4 の最終 `(order, hash)` (image の sha256 つき) | `test/golden/act/<ext>.final` | する (ACT4 の hex は gitignore だが、ツールチェーンは pin されているので再生成で一致する)。未作成 (残作業、GL-C を始める M2 より前に要る) |
| boot の checkpoint (2^16 record ごと)、schedule、`gtag` 位置 | `test/golden/boot/linux515_n1.{ck,irq,tag}.hex` | する (`0bc2467` で済み)。`tag.hex` は `AMO_VM` の位置を持たない (VM 下の AMO ごとに 1 つ立つので数が多すぎる)。その計数だけを `MANIFEST` に残す |
| golden 上の directed probe の結果 | `test/golden/probe/RESULTS` | する。未作成 (残作業、M2 より前に要る、付録 B の probe 列) |
| 全文 trace (boot で約 1,000 万行) と差分 dump | `.golden/cache/` (zstd) | しない。必要時に再生成する |

- 再生成の契機: パッチの変更、tracer か `retire_pkg` の変更、test image の変更、K の変更 (D1)。`*.ck.hex` の先頭語に `TRACER_VER` を入れ、tracer は読み込み時に照合する。不一致は lockstep の不一致ではなく「golden が古い」として失敗させる。
- 残作業のまとめ: `run_golden.py`、生成する `golden_runs_*` テスト、arch 系の checkpoint は M1b の rv64ui trace ゲートより前に、ACT4 の最終値と probe は M2 より前に要る。
- 成果物は `$readmemh` で読む。上限 (`evaluate_size_limit` 8M) に対して、boot の checkpoint は約 200 語、arch は数十語なので十分小さい。

---

## 4. lockstep の仕組み

### 4.1 retire 数で進む mtime

- 【決定】CLINT に `i_tick_sel` と `i_tick` を追加する。`i_tick_sel=0` なら従来どおり内部の /10 prescaler、1 なら `i_tick` のサイクルに mtime を 1 進める。理由: 設計書 §4.4 の「M2 まで共有モジュールは追加のみ」を満たし、`test_clint` とその他の instantiation を変えずに済む。
- 【決定】SoC の `MTIME_SRC` は `CYCLE` (MTIME_DIV サイクルごと)、`INSTRET` (hart 0 の retire record で `popcount(valid && !trap)` を累算し、`MTIME_DIV` に達するごとに 1 tick)、`EXTERNAL` (`i_mtime_tick`)、`OFF` (mtime は 0 のまま) の 4 値とする。arch harness の `MTIME_EN=0` は `OFF`、`MTIME_EN=1` は `CYCLE` かつ `MTIME_DIV=1` (旧 harness の毎サイクル計数) に対応させる。
- 【決定】K = `MTIME_DIV` = 10 とする。理由: IPC が 1 前後なら tick の頻度が現行とほぼ同じになり、また `K ≥ COMMIT_W` (最大 4) なら 1 サイクルの tick は最大 1 回で済むので CLINT の入力が 1 bit で足りる。SoC は `MTIME_SRC==INSTRET` のとき `N_HARTS==1` と `MTIME_DIV ≥` lane 数を elaborate 時に検査する。
- 時刻が決定的になる理由: tick はサイクル t の record から組合せで作られ、t+1 の edge で mtime に入る。新コアは時刻を oldest token を持つ `fu_sys` で読む (設計書 §5.6 F6)。旧コアは CSR を ROB head でしか issue しない (iq_int.veryl:425-428)。どちらも、読む op より古い op がすべて前のサイクルまでに retire しているので、読み値は `floor(それより前の非 trap retire 数 / K)` になり、retire 順位だけで決まる。この議論は、oldest token が登録済みの head から作られ、古い op が retire したのと同じサイクルにはその次の op へ token が出ないことを前提にする。同じサイクルに出すと、時刻の読みが tick の 1 サイクル前になりうる。この前提は設計書 §5.12 と §C (C.2.6) が保証している。新コアの retire record は retire の次のサイクルに登録済みで出る (設計書 §C.2.7) ので、サイクル r の retire による tick は r+1 の record から作られ r+1 の edge で mtime に入り、次の op が token を得るのは r+1、その `fu_sys` の受理は早くて r+2 である。余裕は 0 サイクルなので、SoC の tick の経路にレジスタを足してはならない (設計書 §S.5 の【決定】)。
- tick の源は golden では adapter の正規化後の計数 (N12)、新コアでは自分の retire record である。偽 ifault の csrw を両者とも 1 と数えるので、計数は一致する (付録 B の B02)。

### 4.2 割込みの schedule replay (D2)

- golden は自由走行し、IrqEvent ごとに `I <order> <cause> <epc>` を出す。これを `linux515_n1.irq.hex` にする。
- 新コア側は tb モジュール `irq_replay` が schedule を `$readmemh` で読み、hart 0 の `i_dbg_*` を登録済みの状態から駆動する。手順は設計書 §5.13 のとおりで、次の項目 (K, cause) に対して `limit=K, limit_en=1, mask=1, allow=1` とする。
- assert: (a) 最後の record の order が K-1 になってから (K=0 なら reset 直後から) W=1,000 サイクル以内に IrqEvent が出ること。出なければ「golden の割込みが自コアで pending でない」として失敗にする。(b) IrqEvent の cause と epc が golden と一致すること。(c) schedule の外で IrqEvent が出ないこと。
- 【決定】allow+assert だけを実装し、cause を強制注入する変種は持たない。理由: 設計書 §5.13 には注入入力が無い。また assert が失敗するなら、それは IO store の完了と retire の順序 (設計書 §5.14) か pending の計算の誤りであり、tb で隠すべきものではない。
- 同じ order に 2 つの割込みが続く場合 (S への trap の直後に M の割込みが入るなど) も、schedule の次の項目が同じ K を持つだけで同じ手順で扱える。`irq_replay` は IrqEvent を見た次のサイクルに入力を更新するので、コアには「受付の直後のサイクル (full kill のサイクル) には次を受け付けない」ことが必要になる。1 サイクル登録した pending (設計書 §5.13 I1) は trap の受付直後に更新前の値を指しうるので、これは replay の都合ではなく受付規則そのものの条件である。設計書 §5.13 I2 は、`kill.valid` のサイクルと、アーキ状態を変える retire の次のサイクルには受け付けないと定めており (§C では `!kill.valid` の 1 項が両方を担う)、この要求を満たす。
- 最後の割込みの後は `limit` を golden trace の終端 order (x3:=0xAA の record) にして止める。

### 4.3 WFI

WFI は、合法な場合は両コアとも NOP である (D2、設計書 §5.5)。retire 数で進む時刻のもとで WFI が停止すると mtime も止まり、タイマ待ちが deadlock するので、lockstep には NOP が必須である。新コアは Sail に合わせて U-mode と TW=1 の S-mode の WFI を不正命令にし (設計書 §C.8)、golden はそれも NOP として実行する。lockstep の範囲の WFI は S-mode・TW=0 (5.15 の idle ループ) だけなので両コアとも NOP になり、trap する条件の WFI は STOP:WFI_TRAP とする (付録 B の B29)。

### 4.4 trace の形式

【決定】trace は record を order 順に直列化した行の列とし、lane の位置を含めない。理由: W2 の golden、W2 の新コア、W4 の新コアがバイト単位で同じテキストを出せるようにする。

```
R <order> <priv><virt> <pc> <insn>[c] [x<n>=<v> | f<n>=<v>] [y=<v>] [S <pa> <wmask> <wdata> [IO]] [C <csr>=<v>] [F <fflags>]
T <order> <priv><virt> <pc> <insn>[c] <cause> <tval>
I <order> <cause> <epc>
H <order> <hash>
```

- `c` は `is_rvc` (insn は展開後の 32 bit)。`y` は amocas.q の rd2。`S` は store (load は golden が出せないので出さない、N10)。MASK した値は `*` と書く。golden の行には `#TAG` が付くことがある (比較前に落とす)。
- tracer (`tb/rvfi_tracer.veryl`) は 1 つの always_ff の中で lane を 0 から順に走査する。generate の instance をまたいだ `$display` の順序には依存しない。
- 正準化: `test/golden/canon.py` が 16 進の桁と空白を正規化し、`#TAG` を外す。比較はその出力に対する `cmp` だけで行い、判定は exit code で下す。
- MASK 規則 (tracer に実装し、hash の計算前に適用する。golden と新コアで同じソースを使う): 付録 B の「MASK」の行、fetch fault の trap record (cause 1/12/20) の insn (設計書 §5.12)、rd=x0 の load の `mem_rdata` (LQ はデータを持たないので新コアでも再構成できない、設計書 §5.12)、vector op の `mem_*` (設計書 §V.7)。trace に load の値は出さないので (N10)、rd=x0 の規則が効くのは GX と、将来 load の値を出す場合である。窓を伴う MASK は、両コアの record から同じ規則で開閉を判定できるものに限る。

### 4.5 オフライン cmp とオンライン rolling hash

- tracer は record と IrqEvent ごとに rolling hash を更新する。lane l の結果を次の lane の入力にする連鎖は lane ごとの配列で書き、同じ関数の入れ子呼び出しはしない (設計書 §3.7)。混合関数の唯一の定義は tracer のソースであり、`TRACER_VER` で版を管理する。
- 【決定】checkpoint の間隔は arch 系で 2^10 record、boot で 2^16 record とする。tracer は golden の checkpoint 列を `$readmemh` で読み、オンラインで照合する。最初に不一致になった区間で sticky の `hash_mismatch` を立て、テストは早期終了する。理由: boot の全文 trace (約 1 GB) を毎回書かずに済み、不一致の区間を 65,536 record 以内に絞れる。
- 【決定】新コアの全テストは、tohost の store か x3:=0xAA の record の時点で最終行 `H <order> <hash>` を 1 回だけ印字する。ACT4 のようにテンプレートを変えないテストでも、`check_hash.py` がログを読んで GL-C を判定できるようにするため。
- 局所化: `test/golden/diff.py <test> <区間>` が、golden と新コアの両方を dump 区間つきで走らせ (golden の全文が `.golden/cache` にあればそれを使う)、正準化して `cmp` し、最初に異なる行の前後と近くの `#TAG` を表示する。
- オンラインで全文を比較する手段 (veryl の component を native で読み込む、golden trace の streaming 比較) は使わない。checkpoint と区間 dump で足りなくなった場合の予備とする。

### 4.6 lockstep の対象

【決定】次の表で固定する (D4)。

| 対象 | 方式 | 構成 | 条件 |
|---|---|---|---|
| arch (rv64ui/um/ua/uc/uf/ud/mi/si、uzba/uzbb/uzbs、mzicbo、test_arch_zicond/cmo/zcb/sysb/svnapot/zfhmin/supm/hint、zfa_s1..s4、fp_smoke) | golden lockstep | M1b W2 (rv64ui)、M2 W2 (全部)、M3 から W4 も | `MTIME_SRC=OFF`。rv64uf/ud は B04 の N6 正規化を通したうえで比較する。冪等でない op が二重実行された場合は STOP として個別に除外する。riscv-tests の env が先頭で書く mnstatus は付録 B の B48 で扱う (M1b の rv64ui ゲートより前に扱いを決める)。 |
| ACT4 (全スカラ suite、Zabha/Zacas を含む) | golden lockstep (最終 hash) | M2 W2、M3 から W4 も | Zicntr は両者 `MTIME_SRC=INSTRET`、他は `OFF`。 |
| 5.15 N=1 boot (ADUE off) | golden lockstep (checkpoint + schedule replay) | M2 W2、M3 から W4 も | `MTIME_SRC=INSTRET`、K=10。 |
| 割込みを受けるテスト (sstc_stimecmp、sscofpmf、smode_plic、hsstc、hvtmr、hvirq、hvsirq)、hpm_counter、test_arch_svadu、test_arch_svpbmt、test_lrsc_reorder | pass/fail | | 割込みの位置は arch harness では replay しない。svadu は ADUE (B33)、svpbmt は DRAM 内の NC/IO (設計書 §5.11)、lrsc_reorder は投機に依存する SC の成否 (B06) を含む。hpm の値はマイクロアーキテクチャ依存。 |
| 6.6 N=1、7.1 (FP、ADUE)、7.1v、全 SMP、litmus、hvlinux | pass/fail | | ADUE は投機的な A bit の書き込みで PTE の内容を変えうる。SMP は順序が非決定的。6.6 は DRAM 内の Svpbmt NC/IO を使いうる (設計書 §5.11 で trace diff の対象外)。 |
| GX: W2 対 W4 | 新コアどうしの差分 lockstep | M3 から | 決定的なテストのうち、golden lockstep から外したもの (golden 側の誤り、H/V) も含める。割込みを受けるテストは W2 を先行させ、その schedule を W4 で replay する。 |

### 4.7 golden だけに存在する区間と時刻の補正

【M2 で決定】EXCLUDE 窓と `MTIME_SRC=EXTERNAL` を使うかどうか。測るものは §3.5 の最初の成果物で、golden の 5.15 boot に、csrw satp (PA 0x8000_46C2 または 0x8000_475A) から最初の /init への sret までの間に、カーネルモードの page fault (scause 12/13/15) があるかどうかを見る (付録 B の B03 の (a))。

- 無ければ: 新コアの mtime は自分の retire record から作る (`INSTRET`)。それで計数は golden と一致する。
- 有れば: その trap から sret までを golden 側の EXCLUDE 窓 [a, b) とする。golden の tracer は窓の中の record を出さず、それ以降の order から b-a を引く。新コアは `MTIME_SRC=EXTERNAL` とし、tb モジュール `tick_align` が新コアの order を golden の order に写像したうえで (窓の後では窓の中の非 trap retire 数 L を加える) K ごとに tick を出す。こうしないと、窓の後の時刻の読み値が floor(L/K) だけずれ、以後の比較が崩れる。

---

### 4.8 実装で確定した規則 (M1a、`src/pkg/retire_pkg.veryl`、`tb/rvfi_tracer.veryl`、`tb/retire_mon.veryl`)

- mask と data: `mem_rmask`/`mem_wmask` は右詰めの 16 bit (16 B アクセスまで)、data は `_lo`/`_hi` の 64+64 bit。tracer は wdata を wmask のバイトで切り出してから印字・hash する。
- 混合関数: `mix64` (splitmix64 の finalizer) は `retire_pkg` に、rolling の 1 段 `h' = mix64((h ^ w) + 0x9e3779b97f4a7c15)` は tracer に置く。版は `retire_pkg::TRACER_VER` (現在 1)。`retire_pkg` を変えたら golden 成果物を再生成する。
- vector: §4.4 の形式に `V <vtype> <vl> <vstart> <wcnt> <vrf_hash>` を足す (vector op の record にだけ付く)。後から足すと TRACER_VER を上げることになるので最初から入れた。
- ビット単位の MASK (付録 B の mhpmevent の bit 63、mip/sip の bit 13 など) は、そのビットを 0 にしてから印字・hash する。フィールド全体を `*` にするのはフィールド単位の MASK だけ。
- rd=x0 の書き込みは record に出さない (rd_kind=INT かつ rd_addr=0 は「書き込みなし」)。`F` は fflags が 0 でないときだけ付ける。rd=x0 の load の `mem_rdata` の MASK は、trace に load の値を出さないので実装しない。
- 終端: `retire_mon` が終端 record (tohost store、boot 系では x3:=0xAA) を lane ごとに示し、tracer はそこまでだけを hash する。cycles/instret もその record を含めて凍結する。終端が来ないテストは flush で H 行を出す。H 行の order は吸収した record 数。
- `o_chk` は `{tb の sticky checker, retire 契約 checker}` の連結とする (OR ではない)。retire 契約 checker は lane の連続性、order の +1、trap が lane 0 だけであること、trap の後に record がないこと、IrqEvent の条件と order、trap record に副作用がないことを見る。
- checkpoint ファイル: `[0]` TRACER_VER、`[1]` 間隔の log2、`[2]` 個数 n、`[3..3+n)` 各 checkpoint の hash、`[3+n]` 最終 count、`[4+n]` 最終 hash。版か間隔が合わなければ stale として fail にする。`CK_PRINT=1` で `K <count> <hash>` 行を出し、golden の checkpoint ファイルを作る。`canon.py` は R/T/I/H 以外の行を無視する。

## 5. invariant checker と発火カウンタ (設計書 §5.15)

### 5.1 invariant checker

【決定】最低限、次の checker を置く。コア内のものは観測専用の `chk_*` モジュールで、出力は sticky flag の `o_chk` だけとする (設計書 §5.15)。tb 側のものは `retire_mon` と `irq_replay` に置く。どれも全テストで有効にし、§2.3 のとおり `o_pass`/`o_fail` に畳み込む。テストの終わりに `CHK <bits>` を印字し、早期終了のループは `chk != 0` でも抜ける。

| checker | 置き場所 | 検査する不変条件 | 根拠 |
|---|---|---|---|
| `chk_kill` | core | kill の edge の後、`killed()` が選ぶタグが ROB/IQ/LQ/SQ/段レジスタ/反復 FU の shell に残っていない | 設計書 §5.4 T7 |
| `chk_alloc_kill` | core | kill のサイクルにタグの割り当てが無い | T2 |
| `chk_wb` | core | 1 つの ROB エントリへの二重完了、未割り当てエントリへの完了、同じ WB ポートの同一サイクル二重使用 | 設計書 §5.6, §5.7 |
| `chk_rat` | core | 投機 RAT と arch RAT の重複写像 | 設計書 §5.4 |
| `chk_free_list` | core | 漏れと重複 (free + 写像中 + 解放待ちの総数 = `PRF_*_N`) | |
| `chk_mem_resp` | core | 受理した要求ごとにちょうど `RESP_LAT` 後に応答が 1 つ。未知のタグ宛ての応答が無い | 設計書 §5.9 MP1, MP2 |
| `chk_oldest` | core | 各 unit (`fu_sys`、`io_unit`、`atomic_unit`、`sq` の D ビット経路、M5 の `vu_adapter`) の `o_started` パルスのサイクルに token が有効で、そのタグが発生源の op のタグに等しい。`head_started_q` が各 unit の started latch の OR に等しい。started latch を立てた op が自分の retire と trap 以外の kill に選ばれない。owner を落とした `nonspec` walk が PTE を書かない。M1b では unit の started latch がまだ無いので、`chk_commit` が「パルスのサイクルに token が有効」だけを検査し、`chk_oldest` は M2 で入れる | 設計書 §5.2, §5.13.1, §C.10 |
| `chk_retire` | tb (`retire_mon`) | lane が lane 0 から連続している、order が 1 ずつ増える、trap は lane 0 だけ (golden では N4 を許す)、1 サイクルの flush は最大 1、IrqEvent は record の無いサイクルだけ、trap record に rd/store/CSR が無い | 設計書 §5.12 |
| `chk_irq` | tb (`irq_replay`) | §4.2 の (a)(b)(c) | D2 |
| `chk_io` | SoC | §8 | 設計書 §5.14 |

【M1a で決定】の synth からの除外方法は設計書 §5.15 に従う。`$assert` と `$display` は RTL に置かず、tb だけで使う (cc backend の whole-comb bail を避けるため)。

### 5.2 機構ごとの発火カウンタ

- コアは機構ごとに event wire を `o_perf` に出す (設計書 §4.5)。tb モジュール `perf_acc` が hart ごとに 64 bit で累算し、テストの終わりに `P <name> <count>` を印字する。
- 【決定】`test/gates/fire_matrix.txt` に「機構、それが 0 より大きくなるべきゲート」を列挙し、`test/gates/fire_check.py` がマイルストーン末の梯子のログを集計する。どのゲートでも 0 のままの機構があれば exit code で失敗とし、directed test を足すか、その機構を消す。理由: ビット一致の結果は「発火しなかった」と読む (設計書 §5.15)。

| 機構 (event) | 所有者 | 期待するゲート | 判定に使う【M3 で決定】 |
|---|---|---|---|
| RETRY: FILL_BUSY / INV_RACE / PREEMPTED / WB_BLOCKED / BANK_CONFLICT | `dcache_port_adapter` | boot / M4 の SMP boot と litmus / boot / boot / W2 の boot (HOLD 中の要求と port 0 予約の前サイクル) と W4 の全テスト | dcache の bank 数 (設計書 §3.2) |
| kill: partial、full (trap / irq / REPLAY / RETIRE_FLUSH / T8 backstop) | `flush_ctrl` | 全テスト / boot。T8 は W4 (BRU 2 本) で、0 なら同じサイクルに mispredict する分岐 2 本の directed を足す | |
| commit group の切断理由: alone、lane>0 の例外、SB 予算、retire limit、irq_take | `commit` | arch / boot / lockstep run | |
| forward hit (SQ、SB)、drain shadow の適用 | `lq`, `sb` | arch (ld_st)、boot | |
| rename walk (回数、サイクル)、walk 中に捨てた resolve | `rename` | boot | walk 中の kill の扱い (設計書 §5.4 T9)、`NUM_CKPT` |
| checkpoint pool 枯渇からの walk fallback (M3 から) | `rename` | W4 boot で 0 より大 (設計書 §3.3) | |
| commit 時 REPLAY (順序違反) | `lq` | 順序違反の directed (§7.4)、SMP boot | |
| HOLE_FILL の待ち (DIV、FDIV、io、atomic) | `wb_resv` | rv64um div、rv64ud fdiv、boot | |
| PTW の walk、TLB miss、epoch 不一致による install の破棄 | `ptw`, `tlb` | boot。epoch は walk 中に full kill をかける directed | port 0 のクラス別占有 (設計書 §5.9 の D-PTW) |
| IO load、IO store、NC load の件数 | `io_unit`, `lq` | boot (UART、CLINT)、svpbmt | NC load の投機発行 (設計書 §5.14) |
| CSR 書き込み後 flush の件数とそのコスト | `commit` | boot、bench | 白リスト化 (設計書 §5.5 の 1 % 規則) |
| misaligned の分割、page またぎの分割 | `mem_pipe` | ma_data、ACT4 Misalign、§7.4 | |
| atomic: LR、SC 成功/失敗、AMO | `atomic_unit` | rv64ua、boot | |
| `mem_port_arb` の最大待ちサイクル | `mem_port_arb` | 上限 B (設計書 §5.9 MP4) を超えない | |

---

## 6. シミュレーション速度計画

### 6.1 現状の数値 (旧コア、`.build/test_timings`、5.15 boot)

| harts | 実行時間 | cycles | cy/s | hart-cycle あたり |
|---|---|---|---|---|
| N1 | 145.2 s | 12.2M | 84.0k | 84.0k |
| N2 | 448.7 s | 16.4M | 36.5k | 73.1k |
| N4 | 3793.2 s | 25.2M | 6.64k | 26.6k |
| N8 | 15216.2 s | 36.6M | 2.41k | 19.2k |

N4 の値は `.build/test_timings` のもので、CLAUDE.md の 4408 s は 2026-08-05 に別の実行で測った壁時間である (設計書 D7 の 4408 s はこちら)。どちらも測定条件 (`VERYL_AOT_C_ASYNC` の設定、並行実行の有無) が記録されていないので、§6.3 の matched 測定で置き換える。2026-06-11 に同じ木で直列に測った値は N1/N2/N4 で 251k/118k/50.6k cy/s であり、ほぼ線形だった。N=4 の段差 (hart-cycle あたり約 2.7 倍) はその後に現れた。CLAUDE.md の「N=1 約 1 分、N=2 約 3 分」は外挿値で、実測では約 2.4 分と約 7.5 分である。旧コアの梯子 (litmus4 523 s + N2 449 s + N4 3793 s + hv 243 s) は直列で約 83 分で、そのうち N4 boot が 76 % を占める。Verilator の N4 boot は約 11k cy/s で、native の約 1.6 倍速い。

### 6.2 測定の規約と記録

- 【決定】速度は `VERYL_AOT_C_ASYNC=0` で、直列に、同じ木と同じマシンで測る。他の重い実行と重ねない。理由: 非同期の cc ビルド中は Cranelift で走るので、短い run は cc の速度を測っていない。また過去の数値は日付のない値や外挿値が混ざって誤っていた。
- 【決定】各マイルストーンの末に次の表へ 1 行ずつ追記する。対象は 5.15 N=1 boot (W2/W4)、dhrystone (W2/W4)、既定スイートの壁時間、梯子全体の壁時間、M4 からは N=4 boot である。

| マイルストーン | 構成 | 対象 | cycles | 実行時間 | cy/s | whole-comb / event の fallback | 木の commit | veryl の commit |
|---|---|---|---|---|---|---|---|---|
| M0 基準 | 旧コア | 5.15 N=1 boot | 12.2M | 145.2 s | 84.0k | 未測定 (§6.4 の S1) | b0f4668 | fbd14729 |

### 6.3 N=4 の段差の調査 (D7、M3 の最初の作業)

1. S3-1: V14 で (新コアの SMP は M4 から)、同じ木、同じマシンで、5.15 boot の先頭 5M サイクルを N=1/2/4 の順に直列で走らせる (`VERYL_AOT_C_ASYNC=0`)。`--features profile` でビルドした veryl (`release-verylup-prof`) で、SimProfile の settle/comb/event の ns を SoC サイクルあたりに直す。段差が comb、event、settle のどこにあるかを見る。
2. S3-2: 同じ slice を Verilator でも測る。Verilator にも段差が出るなら設計とホストのキャッシュ容量の問題、出ないなら veryl 固有の問題と切り分ける。
3. S3-3: 仮説を 1 つずつ潰す。(a) 設計の肥大: hart-cycle あたりのコストが N によらず一定かを見る。(b) ホストのキャッシュ容量: `perf stat` で LLC miss を N=2 と N=4 で比べる。(c) N=4 でだけ whole-comb か whole-event が bail している: N ごとに `VERYL_AOT_C_DIAG=1 VERYL_AOT_C_EVENT_DIAG=1` を見る。(d) 生成 C の関数が巨大になる影響: `.so` のサイズと命令キャッシュ miss を N ごとに比べる。
4. S3-4: 原因が veryl にあれば clone 側で直し (プロジェクト規則)、同じ slice で再測定する。
5. 【M3 で決定】N=4 boot ゲートを両構成で回すかどうか (決定は M4 から適用する)。新コアの N=4 boot は M4 まで存在しないので、S3 の後の V14 の N=4 boot の壁時間に、W2/W4 と V14 の N=1 boot の cy/s の比を掛けて W2 と W4 の値を見積もる。M4 で実測し、見積もりと大きく違えば見直す。両構成の梯子が直列で約 4 時間以内に収まるなら両方で回す。収まらなければ、メモリ系の変更ごとに W4 だけで回し、W2 はマイルストーン末だけにする。Verilator を N=4 のゲートエンジンにする案 (約 1.6 倍速い、`-O1 -j 2` が必要) もこのときに比べる。

### 6.4 whole-comb fallback の検査

- S1 (M1a の spike の前): V14 の N=1 boot で `VERYL_AOT_C_DIAG=1 VERYL_AOT_C_EVENT_DIAG=1 VERYL_AOT_C_ASYNC=0` を走らせ、whole-comb と whole-event が効いているかを記録する。この対照が無いと、新コアの「fallback 0」に意味がない。
- S2 (M1a の spike、設計書 §3.7): 両構成の skeleton で fallback 0 を確かめる。lane 配列の要素幅を 128 bit 以下、129-256 bit、256 bit 超に変えて、wide-helper の経路のコストも測る。
- 各マイルストーン末と veryl の更新時: arch harness (W2/W4)、N=1 boot harness (W2/W4)、M4 からは N=4 SMP harness で DIAG を見て、declined statement が 0 であること (設計書 §2.5、§5.15)。0 でなければ、どの statement 種別かを census から特定し、veryl の clone で直す。

---

## 7. ISA カバレッジ checklist

### 7.1 M2 (スカラ) で証明が揃っていなければならない機能

| 機能 | 既定スイート | ACT4 | boot | 注記 |
|---|---|---|---|---|
| RV64I | rv64ui 54 | I 51 | 全 boot | M1b で lockstep |
| M、Zmmul | rv64um 13 | M 13、Zmmul 5 | | |
| Zalrsc、Zaamo | rv64ua 19、test_lrsc_reorder | Zaamo 18、Zalrsc 4 | 全 boot | lrsc_reorder は旧コアでは `#[ignore]`。新コアでは既定に入れる。SMP 側は M4 |
| Zabha、Zacas (amocas.q を含む) | | Zabha 18、Zacas 3、ZacasZabha 2 | | 既定の EXT に無い。`make EXT=...` で生成する (sandbox の外で)。amocas.q の形の決定 (設計書 §5.5) に使う |
| F、D | rv64uf 11、rv64ud 12、test_fp_* | F 82、D 114 | 7.1 | lockstep には N6 正規化が必要 (B04) |
| Zfa、Zfhmin | zfa_s1..s4、test_arch_zfhmin | ZfaF 7、ZfaD 15、Zfhmin 6、ZfhminD 6 | | |
| C (Zca/Zcd)、Zcb、Zcmop | rv64uc rvc、test_arch_zcb、test_c_expander | Zca 32、Zcd 4、Zcb 7 ほか 5、Zcmop 8 | 全 boot | rv64uc は C.FLD 系を突かない (7.1 の FP boot で初めて見つかった)。ACT4 Zcd を必須とする |
| Zimop、Zihintntl、Zihintpause、Zicbop | test_arch_hint | Zimop 40、Zihintntl 4+4、Zihintpause 1、Zicbop 3 | | PAUSE は FENCE のように drain しない |
| Zawrs | test_arch_sysb | なし | 7.1 SMP (M4) | |
| Zba、Zbb、Zbs、Zicond | uzba 8、uzbb 24、uzbs 8、test_arch_zicond | 同数、Zicond 2 | | |
| Zkt | なし | なし | | 試験不能。FU 契約で、対象 op の公表レイテンシがデータに依存しないことをレビューで確認する |
| Zicsr、Zifencei | rv64mi csr/mcsr/illegal、rv64si csr、rv64ui fence_i | Zicsr 6、Zifencei 1 | | CSR の存在表は golden が 0 を読ませる CSR (mvendorid 等) を含めること (B31) |
| Zicntr | rv64mi zicntr、instret_overflow | Zicntr 2 | | minstret = popcount (設計書 §5.12 C8)。ACT4 Zicntr は INSTRET モードで lockstep |
| Zihpm、Sscofpmf | test_arch_hpm_counter、test_arch_sscofpmf | Zihpm 2 | | event 5 = memory port busy の再定義を満たすこと。pass/fail のみ |
| Sstc | test_arch_sstc_stimecmp | なし | 6.6、7.1 | |
| Supm/Ssnpm | test_arch_supm | なし | | 判別力が弱い (SC の完全 VA 比較に依存)。Sv39/U-mode 版の directed を足す (§7.4) |
| Zicbom、Zicboz | test_arch_cmo、rv64mzicbo zero | Zicbom 3、Zicboz 1、PMPZicbo 4、SvZicbo 6、SvPMPZicbo 8 | 6.6、7.1 | |
| Sv39、Svbare、Svade | rv64si dirty、test_mmu | Sv 33、Svbare 3、Svade 2、ExceptionsSv 4 | 全 boot | |
| Svadu | test_arch_svadu | Svadu 2、SvaduPMP 2 | 7.1 | M1-M3 の A/D は STORE_WT (設計書 §5.9) |
| Svnapot、Svpbmt、Svinval | test_arch_svnapot、test_arch_svpbmt、test_arch_sysb | Svnapot 4、Svpbmt 4、Svinval 2 | 6.6、7.1 | DRAM 内の NC/IO の基本線は設計書 §5.11 の【M2 で決定】 |
| Smpmp | rv64mi pmpaddr | PMPS 9、PMPSm 51、PMPU 9、PMPF 1、PMPZaamo 1、PMPZalrsc 1、PMPZca 11、SvPMP 4 | | Verilator の `tb_act_pmps_cfg_xwr.sv` でも確認する |
| PMA の hole | (MAP_ARCH) | ExceptionsSv 4、ExceptionsSvZaamo 3、ExceptionsSvZalrsc 3 | | §2.2 の表で hole を作る |
| misaligned load/store | rv64ui ma_data、rv64mi ma_addr と *-misaligned 6 本 | Misalign 8、MisalignD 2、MisalignF 2、MisalignZca 8 | | ACT4 の `MISALIGNED_MAX_ATOMICITY_GRANULE_SIZE` を 4096 から 64 に下げる (設計書 §5.9 MP5)。page またぎは §7.4 |
| M/S/U の trap と xRET | rv64mi/si 全般 | Exceptions* | 全 boot | xRET の特権検査と MPRV のクリアは §7.4 |
| 割込み | test_clint、test_plic、test_smode_plic、sstc | なし | 全 boot (GL-B は replay) | |

### 7.2 M4 (SMP)

RVWMO (litmus N=2/4/8)、remote invalidate による reservation の消去、atomic の line 所有、Zawrs と Svinval の SMP 下の動作 (7.1 SMP boot)、PLIC claim の競合 (§8 の directed)。旧コアでは N=1 のビット一致が N=4 boot の正しさを含意しなかったので、メモリ系の変更には GB4 を必須とする (§1.3)。

### 7.3 M5 (H/V)

| 機能 | 既定スイート | boot | 注記 |
|---|---|---|---|
| H | htwostage、hvstrap、hvirq、hgpf、hgpfns、higpf、hlv、hvinst、hconf、hmtval2、hvscsr、hvtvm、hvsirq、hsstc、hmini、hvtiny、hvtmr (17 本) | hvlinux | ACT4 に H は無い。golden 側の V=1 の誤り (B11、B23、B25、B40) があるので golden lockstep はしない。GX で W2 と W4 を突き合わせる |
| V | test_arch_vadd ... vfarith (20 本)、test_vmspre | 7.1v N=1 | ACT4 に V は無い。VRF への書き込みは retire record の `vrf_wcnt`/`vrf_hash` に入るので (設計書 §5.12、§V.7)、W2/W4 の GX で vector の結果を突き合わせられる。golden も D1 パッチの最初の版から同じフィールドを出すので、V テストで最初に食い違う vector op の局所化 (設計書 §V.11) にも使える。VU の上限の修正または宣言 (設計書 §3.4) |

### 7.4 新規 directed test (自己検査型)

【決定】付録 B で golden の誤りと分かっている振る舞いと、golden lockstep で守れない規則には、`test/directed/` に自己検査型のテストを置く。tohost は、仕様どおりの振る舞いなら 1、golden の誤りと同じ振る舞いなら付録 B の番号を符号化した専用の値 (`0xB000 + 番号`) を書く。golden 上で走らせて誤りを確認する (D4) のと、新コアのゲートに入れるのを同じプログラムで済ませるためである。対象: B03、B04、B05、B07、B10、B12、B19、B21、B22、B24、B26、B28、B30、B35、B36、B46 (付録 B の各行の probe 列。B46 は UART THR への書き込み回数を数える)。順序違反の commit 時 REPLAY、walk 中の full kill による epoch 破棄、SC 失敗時の書き込み権限での翻訳、Supm の Sv39/U-mode 版、§8 の IO 系 directed もここに置く。

golden 上の probe は作成済みで、branch `golden/probes` にある (ソースは `test/directed/`、Veryl の test は `tb/test_golden_probe.veryl`)。tohost の符号化は、1 が仕様どおり、`0xB000 + n` が Bn の誤りを観測 (n は付録 B の行番号の 10 進値、bit [23:16] は sub-case か観測した変種のマスク)、`0xE000 + x` が判定不能である。走らせた probe は上の対象に B13、B14、B17、B20、B27、B39 を加えた 22 本で、結果は付録 B の各行の状態と probe 列に書いた。B10 の probe からは新しい行 B47 (fault する store がデータを書く) が見つかった。B48 (riscv-tests の env が書く mnstatus) は probe ではなく M1b の decode の実装で見つかった。

- 再現せず: B20、B21 (pmpcfg)、B36 の Svinval 部分、B39 の ASQ の順序。どれも扱いは STOP か OUT のまま残す。
- 判定不能: B05。N=1 では自分の eviction でしか poison が起きず、掃引 2 通りで `SC_REPLAY` は 0 だった。M4 で remote の inv で poison する SMP の probe を足す。
- 未 probe: B23、B25、B40 は H/V なので M5 で作る。B33 は OUT (7.1 は pass/fail) なので probe は要らない。

---

## 8. SoC 側の IO モニタ (設計書 §5.14)

【決定】統合 SoC に観測専用の `chk_io_mon` を hart ごとに置き、sticky flag を `o_chk_io` に出す。V14 では無効にする (V14 には retire port が無く、IO store の重複書き込みが推定されている)。

- 観測するもの: (1) device 側。`PMA_REGIONS` で `io_ordered=1` の領域 (CLINT、PLIC、UART) への読み書きの enable と、それを出した hart (memory_bus の grant から求める)、アドレス、方向、store のデータと strobe。(2) コア側。その hart の retire record のうち `mem_io=1` のもの。
- 照合規則: IO 操作は oldest token でしか始まらず、IO store は non-posted なので (設計書 §5.14)、hart ごとの未照合の device アクセスは常に 0 個か 1 個である。device アクセスを 1 段のレジスタに保持し、次の `mem_io` record とアドレス、方向、(store なら) データと strobe で照合する。2 つ目の device アクセスが照合の前に来たら DUP、保持が空のまま `mem_io` record が来たら MISSING、テストの終わりに保持が残っていれば ORPHAN (wrong-path や kill 後のアクセス) とする。
- device アクセスは必ず record より先に起こる (IO load は応答を LQ で受けてから retire し、IO store は WT_DONE を受けてから retire する)。逆順は ORDER 違反とする。
- AMO、LR/SC、misaligned、fetch、PTE の読み出しで IO 領域に触れると、翻訳時にアクセス fault になり device には何も届かない。届いたら ORPHAN として現れる。

boot ではデバイスの読み出し副作用が一度も起きないので、モニタの照合が意味を持つのは directed test である。次を `test/directed/` に置く (M2、claim の競合は M4)。

| テスト | 確かめること |
|---|---|
| PLIC claim の読み出し回数 | smode_plic を拡張し、claim の読み出しが 1 回であることを tb で assert する |
| wrong-path の claim | mispredict する分岐の影で claim を読む命令を置く。device の読み出しが 0 回であること (ORPHAN 0) |
| 古い store の後ろの claim | 同じ line への古い store の後に claim を読む。forward も poison も replay も起こらず、読み出しが 1 回であること |
| IO store から IO load へ | UART の THR と RBR (同じ offset 0) に sw と lw を続ける。読み値が forward されず device から来ること |
| misaligned、AMO、LR の IO アクセス | cause 5 または 7 で trap し、device アクセスが 0 であること |
| IO 領域からの fetch | 命令アクセス fault になること |
| UART の送信回数 | THR への retire した store の数と device の書き込み回数が一致すること (旧コアで推定された重複書き込みの検出) |
| LSR を offset 5 から lb で読む | SoC の読みデータの lane 契約を確かめる (SoC は offset によらず下位 byte を返している推定がある) |
| claim の競合 (M4、N=2) | 2 hart が同時に claim し、合計の読み出しが 2 回で値が重複しないこと |

---

## 付録 B. 許容差異表

列の意味: 「状態」は確定 (コードで確認) か推定。golden 上の directed probe (§7.4) を走らせた行は、その結果で 確定 (probe)、再現せず、判定不能 のいずれかに更新し、probe 列に probe 名、tohost、一行の根拠を書いた。「再現せず」は probe の条件でその誤りが出なかったことだけを言い、誤りが無いことの証明ではない。「発火」は 5.15 N=1 boot で起こるか (y / n / 不明)。不明の欄は §3.5 の最初の成果物の `gtag` 計数で埋める。「扱い」の語彙は次のとおり。

| 語 | 意味 |
|---|---|
| REPLAY | D2 の schedule replay で構造的に吸収する |
| NORM | golden adapter の正規化 (§3.3) |
| MASK:<tag> | tracer がそのフィールドを `*` にし、hash から外す (golden と新コアの両方) |
| EXCL:<tag> | golden だけに存在する record 区間を除外し、order と時刻を補正する (§4.7) |
| STOP:<tag> | lockstep の範囲では発火しない前提。発火したら比較を止めてタグを表示し、そのテストは lockstep から外して自己検査か pass/fail で判定する |
| OUT | lockstep の範囲外 (pass/fail のみ) |
| SAME | 差異ではない (両コアで同じ振る舞い) |

「probe」は M2 の前に golden 上で走らせる directed test (§7.4)。ファイル名の無い行番号は `src/core/heliodor_core.veryl`、ファイル名の後に続く番号はそのファイルのもの。

| # | 項目 | 状態 | 根拠 | 発火 | 扱い | probe (golden で M2 前に) |
|---|---|---|---|---|---|---|
| B01 | 割込みは ROB が空になってから受け付ける。受付の order は pending の立ち上がり + 実行中の op 数で、タイミングに依存する | 確定 | 4648-4650 (rename 停止)、7144 (commit_irq)、7316 | y (タイマ割込みのたび) | REPLAY | 不要。§3.5 の run で割込み数と立ち上がりから受付までの差を記録する |
| B02 | 最初の S-mode Sv39 satp 書き込みで偽の命令 page fault を合成する。csrw は retire 扱いにならず、satp の書き込みは trap に負けて消える。その後は Bare のまま上位 VA を PA の alias で fetch する | 確定 | 7050-7058、7316、7328-7329、7170-7182、csr.veryl:905 対 1047 | y (1 回、PA 0x8000_1040) | NORM (N4)。窓の中の store の `mem_paddr` は MASK:SATP_ENABLE_WIN。窓は、最初の S-mode の satp 書き込み record (`csr_wdata[63:60]==8`) から次の satp 書き込み record までで、両コアの record から同じ規則で判定できる (約 6 record、store は 0 個と推定) | 5.15 trace で `FAKE_IFAULT` がちょうど 1 回であること。S-mode で MODE=8 を書く directed で csrw と合成 trap の 2 record を確認 |
| B03 | satp_shadow が古い satp を保持する。csrw satp (と satp の読み出し) は旧値を latch し、次の sfence まで MMU は古い root で翻訳する | 確定 (probe)、boot への影響は未決 | 7170-7185、csr.veryl:1088 | 不明。§3.5 の run で sfence の無い satp 書き込みの窓 (`SATP_WIN`) を 4 つ確認した: 76987-76993 (B02)、2438786、4286867-4286885、10336234-10341956 (約 5.7K record)。窓の中で (a) 余分なカーネル page fault が出るか、(b) 窓が実害なく閉じるかは、窓の中の page fault をまだ数えていないので未決 | (b) なら SAME。(a) なら EXCL:SATP_LAG (§4.7)。probe は機構を確かめただけで (a)/(b) は決めないので、扱いは変わらない | `b03_satp_shadow`、tohost 0x1B003。sfence なしで root 2 へ csrw satp した後、root 2 にだけ写した VA への MPRV-S load が page fault (13) になった (walk が古い root を使った)。`SATP_WIN` gtag 223 |
| B04 | frm/fcsr への CSR 命令 (読み出しを含む) と同じサイクルに lane 1 の単純 op が retire し、その後の redirect で再実行される | 確定 (probe) | 8451 (commit_redirect に commit_csrw_frm が無い)、7014、7758-7762、8460 | n (5.15 に FP CSR 命令なし)。arch では rv64uf/ud 全テストで y (`csrwi fcsr,0` の直後の auipc) | NORM (N6) で重複 record を落とす。冪等でない op の値の誤りは STOP:FRM_CORETIRE | `b04_frm`、tohost 0x1B004。csrw frm、frrm、csrwi fcsr の 3 通りとも、直後の addi の計数が 16 回でなく 32 回になった。`FRM_CORETIRE` gtag 48 |
| B05 | poison された SC が rd=0 で retire した後に再実行され、2 回 retire する。rd==rs1 なら base が壊れる | 確定 (コード)。probe は判定不能 (N=1 で再現せず) | 6402、8402、8451、7729-7737 | 不明 (稀と推定。N=1 では自分の eviction でしか poison されない) | NORM (N1 で 1 回目を落とす)。rd==rs1 は STOP:SC_REPLAY。新コアの SC は REPLAY されない (D8: 結果は PASS/FAIL で 1 回だけ retire する) | `b05_sc`、tohost 1 (判定不能)。予約 line と同じ set への若い load を 0-23 の遅延で並べる掃引と、同じ set への古い commit 済み store 4-8 個の掃引の 2 通りで、`SC_REPLAY` gtag 0、SC はすべて成功した。N=1 で poison を起こせなかっただけで、誤りの有無は何も言えない。M4 で SMP の probe (remote の inv で poison する) を足す |
| B06 | SC の成否がキャッシュのタイミングと投機に依存する (予約 line の eviction、アドレスが一致する wrong-path の store/AMO の issue、satp の読み出し) | 確定 | 8291-8296、8349-8360 | 不明 | STOP:SC_BENIGN (仕様上は合法な失敗なので別分類で表示し、自動では許さない)。新コア (D8) の SC が失敗するのは reservation の喪失 (自 hart の追い出し、remote の inv) か watch の発火だけで、wrong path の store/AMO や satp の読み出しでは失敗しない。N=1 で食い違いうるのは、golden 側の wrong path と satp による失敗と、両コアの追い出しのタイミングの違いである | B05 と同じ prog で rd=1 の SC を数える。【M2 で決定】発火した場合に、SC の結果を tb から与える入力を設計書 §5.13 に足すか、その boot を lockstep から外すか (設計書 §L L.12 の【M2 で決定】と同じ判断) |
| B07 | page をまたぐ misaligned アクセスを 1 回の翻訳で済ませ、上位側は PA+8 を使う | 確定 (probe、load と store) | 10677-10682、9352、dcache.veryl:576 | n (推定) | STOP:MA_PAGEX | `b07_ma_pagex`、tohost 0x1B007。VA 0x8020cffc の misaligned ld は上位側を隣の PA から読み、sd は上位側を隣の PA へ書いた。`MA_PAGEX` gtag 1 |
| B08 | 不正な vector 符号化が完了元を持たず ROB head で wedge する | 確定 | 5971、6075、decoder.veryl:1136、rob.veryl:1303 | n | OUT (golden は hang する) | `vmacc.vv v1,v2,v3` (0xB63120D7) を VS on で。golden の期待値はタイムアウト |
| B09 | arch_regs が rob_commit_valid で書かれ、priv-illegal の rd も入る (sfence と amocas.q のオペランド、x3 の源) | 確定 | 7808、6958-6966 | n (推定) | NORM (adapter は arch_regs を読まない)。sfence のオペランドに影響したら STOP:PRIV_ILL_RD | TVM=1 の S-mode で `csrr a0,satp` を trap させ、handler から戻った直後に `sfence.vma a0` |
| B10 | VM 下の AMO の書き込みが W/D の page 権限を検査しない | 確定 (probe、R のみのページと D=0 のページ) | 8733-8736、7110-7113、dmem_mmu.veryl:262、mmu.veryl:584-594 | 不明。現在の `AMO_VM` タグは VM 下のすべての AMO で立ち、§3.5 の run で 18,925 回 (権限を欠くページへの AMO かどうかは区別していない) | STOP:AMO_VM。ただしタグを「W か D を欠くページへの AMO」に絞るまでは STOP に使えない (今のままでは boot が必ず止まる)。絞るのは golden のパッチの変更なので成果物を再生成する | `b10_amo_vm`、tohost 0x1B00A。R のみのページでは対照の sd が fault (15) してメモリは変わらず、amoadd.d は fault せずに 0x64 を 0x65 にした。D=0 のページ (ADUE=0) でも amoadd は fault しない (`AMO_VM` gtag 2)。同じ probe で B47 も見つかった |
| B11 | store/AMO の guest page fault が cause 23 でなく 15 になる | 確定 | 7226-7229 | n (V=1) | OUT (M5、hvlinux は pass/fail) | M5 で: HS からゲストの G-stage 未写像ページへの AMO |
| B12 | S/U からの MRET、U からの SRET を trap しない | 確定 (probe、3/3) | 7146-7147 | n | STOP | `b12_xret_priv`、tohost 0x7B00C。U-mode の mret、S-mode の mret、U-mode の sret がすべて実行された |
| B13 | 読み出しだけの CSR 命令も commit で書き戻す (カウンタの巻き戻し、mip の LCOFIP 消去、mstatus の SD の固着、satp/frm の読み出しで flush) | 確定 (probe、カウンタと SD) | 7000、alu_wrap.veryl:384-392、461 | カウンタは n、satp の読み出しは y (asids_init、record には現れない)、SD は n (5.15 は FS off) | NORM (N9 で csr_valid を書き込み意図で絞る)。値の差は MASK:CNT (B15) と STOP:SD | `b13_csrrd`、tohost 0x3B00D。`csrr mcycle` 256 回で mcycle +1311 に対し time +1825 (読むたびに約 2 サイクル失う。対照ループは 0x71d 対 0x71f)。FS=Dirty で `csrr mstatus` の後に FS=Clean にすると mstatus は 0x8000000a00004000 (SD=1 のまま FS=Clean) |
| B14 | minstret が retire 数でない (保持中のサイクルを数え、lane 1 を数えない) | 確定 (probe) | 7420、csr.veryl:1199 | n (instret の読み出しなし) | MASK:CNT。tick の源には使わない (N12) | `b14_minstret`、tohost 0x1B00E。独立な addi 200 個で minstret +196、instret +197、仕様は 201 (約 2.5 % の不足。一部は B13 の巻き戻しかもしれない) |
| B15 | カウンタ CSR の読み値がマイクロアーキテクチャに依存する | 確定 | csr.veryl:574-584、1190-1239 | n (静的に数えて 0、時刻は 0xC01 の 23 か所だけ) | MASK:CNT。対象: 0xB00/0xC00、0xB02/0xC02、0xB03-0xB1F/0xC03-0xC1F の rd、0x323-0x33F の bit 63、0xDA0、mip/sip の bit 13 | 不要 |
| B16 | 不正な RVC の insn と tval が 0 になる (fetch で 0 に置き換える) | 確定 | 1219-1223、7339-7346 | n | MASK:RVC_ILL (cause 2 かつ is_rvc の insn と tval) | 予約された RVC 符号化 (`c.addi4spn` の imm=0 など) |
| B17 | EBREAK の tval が 0 (heliodor.yaml は VA を報告すると宣言) | 確定 (probe) | 7328-7346、heliodor.yaml:171 | n | MASK:EBREAK_TVAL。新コアの値は ACT4 の設定に合わせて M2 で決める | `b17_ebreak_tval`、tohost 0xB011。ebreak で mcause 3、mtval 0 |
| B18 | virtual-instruction の tval が 0 | 確定 | 7339-7346 (cause 22 は除外) | n (V=1) | OUT (M5) | 不要 |
| B19 | page をまたぐ 32 bit 命令の上位側の fetch fault を見ない | 確定 (probe) | 1259-1262 (head の dword だけ)、1184、1207-1210 | n (推定) | STOP | `b19_straddle`、tohost 0xB013。上位側が無効ページにある VA 0x80204ffe の 32 bit 命令が fault せず 00130513 として retire した (メモリ上の上位側は 0x1235 なので古いか alias のデータ)。次の 0x80205002 の fetch は cause 12 でなく 2 で trap した |
| B20 | FP div/sqrt の完了と stage 2 の WB が衝突しうる | 再現せず | fpu_wrap.veryl:2815-2817、iq_fp.veryl:150-156 | n (FP なし) | STOP (再現しなかったが、発火すれば hang か誤値になるので外さない) | `b20_fdiv_fadd`、tohost 1。fdiv.d/fsqrt.d の後に先頭 nop 0-7 個 + fadd.d 22 個の列を 16 通り。hang せず結果も正しい |
| B21 | 翻訳 barrier が vsatp/hgatp/hstatus/menvcfg/pmp* の書き込みを含まない | 再現せず (pmpcfg) | rob.veryl:765-774 | n (推定。fw は PMP を書かない) | STOP (pmpcfg 以外の CSR は未 probe なので外さない) | `b21_pmp_barrier`、tohost 1。MPRV=1/MPP=S で R を外す csrw pmpcfg0 の直後の load は 4/4 で cause 5 |
| B22 | SFENCE.VMA が redirect しないので、取り込み済みの若い命令は古い翻訳のまま走る | 確定 (probe) | 8451 (sfence の arm が無い) | 不明 | STOP | `b22_sfence_refetch`、tohost 0xB016。PTE の書き換え + sfence.vma + jr の後、古いページのコードが 4/4 で走った |
| B23 | VU-mode の HFENCE/SFENCE を trap しない、VS-mode の HFENCE は VTVM のときだけ trap、VU からの S-CSR アクセスが cause 2 | 推定 | 6920-6922、6937-6938 | n (V=1) | OUT (M5) | M5 で |
| B24 | M 未満へ戻る xRET が MPRV をクリアしない | 確定 (probe) | csr.veryl:981-1021 | n (fw は MPRV を使わない) | STOP | `b24_mprv_xret`、tohost 0xB018。S への mret の後 mstatus 0xa00022080 で MPRV=1 のまま |
| B25 | HS への trap が V=0 でも hstatus.SPVP を書く。htval/mtval2 を GPF 以外の trap で 0 にしない | 推定 | csr.veryl:924-925、942-946、957-961 | n (V=1) | OUT (M5) | M5 で |
| B26 | 例外の優先順位: FS=Off の FP load が page fault も持つと illegal より fault を報告する | 確定 (probe) | 7213-7230 | n | STOP | `b26_fs_off_fault`、tohost 0xB01A。FS=Off で未写像 VA への flw が cause 2 でなく 13 |
| B27 | FP load、FP CSR の書き込み、vector で FS/VS を Dirty にしない | 確定 (probe、FS) | csr.veryl:1053-1055、1164-1169 | n (5.15 は FPU off) | STOP:FS_DIRTY (設計書 §C.9 #10。新コアは csr 修正で直す。arch suite で発火したテストは lockstep から外して pass/fail で判定する) | `b27_fs_dirty`、tohost 0x3B01B。fld と csrwi fflags の後も FS=Clean のまま。fmv.d.x では Dirty になる |
| B28 | FS/VS=Off のときの FP/vector CSR アクセスを trap しない | 確定 (probe、FS) | 6893-6898、decoder.veryl:779-790 | n | STOP | `b28_fs_off_csr`、tohost 0x3B01C。FS=Off で csrr fflags と csrr frm が trap しない |
| B29 | WFI は NOP (TW/VTW も見ない) | 確定 | 4641 (コメント)、decoder.veryl:693-695 | y (idle ループ、S-mode・TW=0) | S-mode・TW=0 の WFI は SAME (両コア NOP)。新コアは U-mode と TW=1 の S-mode で不正命令にする (設計書 §C.8) ので、その条件の WFI は STOP:WFI_TRAP | U-mode で wfi。golden の期待値は NOP として retire |
| B30 | decoder が予約符号化を通す (未知の SYSTEM funct12 は NOP、AMO の funct5/幅、予約 LOAD/STORE funct3、静的な予約 rm) | 確定 (probe、4/4) | decoder.veryl:684-735、609-632、334-352 | n | STOP | `b30_reserved_enc`、tohost 0xFB01E。DRET、LOAD funct3=7、SYSTEM funct12=0x7ff、AMO funct5=0x02 のどれも trap しない |
| B31 | 未実装 CSR は 0 を読み書き込みを捨てる。新コアは decode で存在を検査する (設計書 §5.5) | 確定 | csr.veryl:585-591 | y (推定。SBI base の mvendorid/marchid/mimpid) | SAME とするため、新コアの CSR 存在表に、golden が 0 を読ませる必須 CSR (mvendorid、marchid、mimpid) を含める。それ以外は STOP:CSR_EXIST | 不要 (§3.5 の trace で触れた CSR アドレスを列挙して存在表と照合する) |
| B32 | counteren を強制しない | 確定 | csr.veryl:408-409 | n (fw は mcounteren=7、S は time だけを読む) | STOP | U-mode で scounteren=0 のまま rdcycle |
| B33 | Svadu の差 (TLB が W を w&&d で持つ、A/D 更新が非 atomic、I 側の投機的な A bit) | 推定 | 10536、mmu.veryl:297、918-921 | n (5.15 は ADUE off) | OUT (7.1 は pass/fail) | 不要 |
| B34 | PA は下位 32 bit だけでデコードされ alias を作る。キャッシュ可能窓 (32 MiB) と PMA の DRAM (2 GiB) が食い違う | 確定 | imem_mmu.veryl:181、mmu.veryl:465、dmem_mmu.veryl:299、heliodor_soc.veryl:78-81 | y (B02 の Bare 窓での上位 VA の fetch) | B02 の窓は NORM と MASK。それ以外の alias アクセスは STOP:PA_ALIAS | DRAM 外 (0x1_8000_0000) への load。golden の期待値は fault なしで alias を読む |
| B35 | `pmp_check` がアクセスサイズを見ず、領域境界をまたぐアクセスを検査しない | 確定 (probe) | pmp_check.veryl:14-20、48-52 | n | STOP | `b35_pmp_straddle`、tohost 0xB023。MPRV-S で PMP が拒否するページへまたぐ misaligned ld が fault せずに完了 |
| B36 | faulting な amocas.q が rd:rd+1 を書く。c2_simple が Svinval の fence と HLV を除外しないので、U-mode の SFENCE.W.INVAL が lane 1 で trap せずに retire しうる | amocas.q は確定 (probe)。Svinval の co-retire は再現せず | 6427、6433-6436、rob.veryl:593-601 | n | STOP (Svinval の部分も lane 1 で揃わなかっただけなので外さない) | `b36_amocas_svinval`、tohost 0x1B024。PMA の hole への amocas.q は fault (7) するが a2/a3 が変わる。U-mode の `addi; sfence.w.inval` は sfence.w.inval が cause 2 で trap し、lane 1 での co-retire は確かめられなかった |
| B37 | load のアドレスと読み値を golden が出せない | 確定 | rob.veryl:237-239 (store だけ) | y (全 load) | NORM (N10)。load の値は rd で比べる | 不要 |
| B38 | HPM の event の意味がコアごとに違う | 確定 | 13196-13207 | n | MASK:CNT。hpm_counter と sscofpmf は pass/fail | 不要 |
| B39 | vector: マスク外と tail へ 0 を書く load、vill を強制しない、vstart を無視して要素 0 から再開、vector の PMP fault を無視、VS=Off の副作用、misaligned 要素の切り捨て、G-stage を live で取る | 推定。ASQ の順序は再現せず | 5249、6540-6547、vector_unit.veryl:1239-1279、1993-1995、2562-2567 | n (5.15 に V なし) | OUT (M5)。VU 内部の挙動は再利用で両コア同じ。glue 由来の差は 7.1v と V directed の pass/fail と GX で見る | `b39_amo_vle`、tohost 1。`amoadd x0` の直後の vle64 は、同じ dword (8 回) でも同じ line (8 回) でも常に AMO の結果を読んだ。残りの項目は M5 で |
| B40 | V=1 の MXR を G-stage にも適用する、二段 walk が cbo を store として扱う | 推定 | mmu.veryl:583-594、716 | n (V=1) | OUT (M5) | M5 で |
| B41 | IO load が head を待たずに投機発行されうる、遅い store の retire の次サイクルに IO 書き込みを再提示しうる | IO store の再提示は確定 (probe、B46)。IO load は推定 | 10705-10714、11940 | y (console の文字が倍になることを §3.5 の run で確認、B46) | trace には現れない。新コアは §8 の IO モニタで守る。golden ではモニタを走らせない | store 側は B46 の `b46_uart` を見よ。IO load の投機発行は未 probe |
| B42 | boot の SoC は hole で fault しない (`PMA_FAULT=0`)。新コアの `MAP_BOOT` は hole を fault にする | 確定 | 64 (`PMA_FAULT` の既定 0、両 SoC とも上書きしない)、7988、8861 | 不明 (n を期待) | STOP:PMA_HOLE | 不要 (§3.5 の trace で DRAM/ROM/IO 以外への PA を列挙する) |
| B43 | 再利用する csr.veryl の癖 (satp の MODE が WARL でない、mstatus[63] を格納する、mip の読み値が pin 由来の bit を含まない、misa に F/D/C が無い) | 確定 | csr.veryl:1088、421、570、517 | y (satp の書き込み、misa の読み出しはありうる) | satp の MODE は新コアが csr 修正で WARL にする (設計書 §C.9 #20) ので STOP:SATP_WARL (5.15 は MODE を probe しないので 0 回の見込み)。残りは SAME で、M6 まで misa と firmware から見える CSR の振る舞いは変えない。変える場合はこの行を見直して golden 成果物を再生成する | S-mode で satp に MODE=9 を書いて読み戻す。golden の期待値は 9 が残る |
| B44 | 時刻の CSR を読む時点 (旧コアは head で issue、新コアは oldest token の `fu_sys`) | 確定 | iq_int.veryl:425-428、csr.veryl:576 | y (rdtime 23 か所) | SAME (§4.1 の議論により両者とも retire 順位だけで決まる) | 不要 |
| B45 | mhpmevent の OF (bit 63) が既に立っていても、counter の再度の wrap で LCOFI を再び pend する | 確定 | csr.veryl:1226-1239 | n (5.15 は Sscofpmf の overflow を使わない) | STOP:LCOFI (新コアは OF の 0→1 でだけ pend する csr 修正、設計書 §C.9 #21) | OF を立てたまま hpmcounter を再び overflow させ、mip.LCOFIP を読む |
| B46 | console の文字が 2 回ずつ出る (`pprriinnttkk`)。パッチ前の `b0f4668` でも同じで、B41 の IO store の重複書き込み (M 段の無条件の latch) による | 確定 (probe、現象と原因) | 11940 (fill_1 の M 段 latch) | y (console の全文字) | 許容差異。新コアは IO store をちょうど 1 回だけ書く (設計書 §5.14) ので、console に出るバイト列は golden と違う。trace には現れない (store の record は両コアとも 1 つ) ので、IO デバイス側の書き込み (console の出力を含む) を trace の比較に入れない。新コアの回数は §8 の IO モニタと、UART THR への書き込み回数を数える自己検査型の directed test (§7.4) で守る | `b46_uart`、tohost 0xB02E。commit した THR への byte store 12 個に対し device 書き込みは 21 回。trace の IO store record は store ごとにちょうど 1 つ。連続する store と fence で隔てた store は 2 回書かれ、直後に DRAM への sd が続く store は 1 回 (別の store が M 段の latch を上書きすると重複が消える) |
| B47 | W=1/D=0 のページ (ADUE=0) で page fault する store が、trap しながらデータをメモリに書く | 確定 (probe) | `b10_amo_vm` の trace と実行後のメモリ。コード位置は未特定 | 不明 (D=0 のページへ ADUE=0 で store したときだけ起こる。測った範囲では 5.15 lockstep boot はそうしないが、数えるタグは無い) | 許容差異。新コアは trap する op では何も書かない (設計書 §5.8)。trap record は両コアで同じなので、差は後でその番地を読む load の rd に現れ、lockstep はそこで止まる | `b10_amo_vm` (B10 と同じ probe)。trace `T ... 0062b023 0f 0000000080201000` で store が cause 15 で trap した後、メモリにはその store のデータ (0x10) が入っていた |
| B48 | riscv-tests の env (`upstream/env/p/riscv_test.h` の `INIT_RNMI`) が全テストの先頭で `csrwi mnstatus, MNSTATUS_NMIE` (CSR 0x744、Smrnmi) を実行する。golden は未実装 CSR として書き込みを捨てて retire する (B31 と同じ機構)。新コアは CSR の存在検査 (設計書 §C.8) で不正命令 (cause 2) の trap にする。env は直前に mtvec をこの命令の直後に向けているので、どちらも同じ次 PC から続く | 確定 (コード。M1b の decode で判明) | `upstream/env/p/riscv_test.h:120-125`、csr.veryl:585-591 | n (boot は推定)。arch では riscv-tests の env を使う全テストで y (1 回ずつ) | 【M1b で決定】B31 の STOP:CSR_EXIST のままでは rv64ui の lockstep がすべて先頭で止まるので、M1b の rv64ui trace ゲートより前に扱いを決める。この 1 命令の record (golden は R、新コアは cause 2 の T) をどう吸収するか (正規化、MASK、mnstatus を存在表に入れるか) は未決 | 不要 (env のコードと両コアの trace で確認できる) |
