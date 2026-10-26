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
| GT2 / GT4 | litmus N=2 (既定は短い像、ITER=200) / N=4 | GT4 と ITER=1000 の full は `--ignored` | tohost==1 |
| GB2 / GB4 | SMP boot N=2 / N=4 (5.15。6.6/7.1 の SMP はマイルストーン末) | `--ignored` | hart 0 の x3==0xAA |
| GH | hvlinux (V=1 の二段翻訳を負荷下で通す唯一のゲート) | `--ignored` | x3==0xAA |
| GX | W2 対 W4 の差分 lockstep (§4.6) | マイルストーン末 | trace 一致 |
| GV | Verilator 相互確認 (`sim/verilator/` の既存ラッパ) | マイルストーン末 | PASSED 行 |
| GS | 速度と whole-comb fallback (§6) | マイルストーン末 | fallback 0、cy/s を記録 |
| GF | 発火行列 (§5.2) | マイルストーン末 | `fire_check.py` の exit code |
| GD / GD4 | debug の directed (§9.1): tb が APB の DMI ポートを script で駆動し、halt/resume/step、abstract command、progbuf、SBA、trigger、group、reset を N=1 (GD) / N=4 (GD4) で検査する (MD から) | GD は G0 に含む。GD4 は `--ignored` | script の全 CHECK が一致、`chk_debug`/`chk_dm` 0、tohost==1 |
| GG | riscv-tests の debug suite (`gdbserver.py`) を OpenOCD + GDB で Verilator のラッパ (tb 専用の JTAG DTM) に対して走らせる。spike を参照にする (§9.2、MD から) | マイルストーンの節目と末 | spike で通るテストのうち除外表に無いものがすべて pass |
| GM | 乱数遅延の再走 (§10.4): tb の AXI4 slave model の遅延と backpressure を seed 付きの乱数にして、GL-B、GT2/GT4、GB2、GB4 (W2)、GV を回す (MM から) | MM のコミットごと (GL-B と GT2 short)。GB2、GB4、GV は節目と末 | GL-B は record 数と最終 hash が固定遅延と一致、他は各ゲートの判定と同じ。`pass=1` の seed 一覧を記録する |
| GP | AXI4 の protocol checker の違反数 (§10.3、MM から) | 新コアの AXI を持つ全 run | 違反の sticky flag がすべて 0。G0 を含む |

### 1.2 マイルストーン × 構成

【決定】新コアのゲート投入時期を下表に固定する。理由: SMP は M4、デバッグは MD、H/V は M5 で初めて機能が揃うが、揃ったマイルストーンからは両構成で常に回し、後から足さない。MD は D9 (設計書 §1.4) で M4 と M5 の間に足したマイルストーンである。

| ゲート | M1a | M1b | M2 | M3 | M4 | MM | MD | M5 | M6 |
|---|---|---|---|---|---|---|---|---|---|
| G0 新コア分 | (新コアは無い。V14 の梯子 1-5 と SoC の unit test、spike の unit test) | W2: rv64ui 54 を lockstep。W4: rv64ui を pass/fail (最低でも ALU・分岐・load/store 群、目標は 54 全部) | W2: スカラ arch 全部 (lockstep 対象は §4.6) + smode_plic + 新規 directed (§7.4)。W4: rv64ui 全部 | W2 と W4 で同一リスト | + litmus N=2 short (W2, W4。ITER=200 の像) + `test_smp_coh` (CoRR、LR/SC、AMO watch、drain、wt_fires、PLIC claim。N=2 の W2、W4) + A/D 競合 (`ad.S`) + SMP uncached 読み (`unc.S`) | 同 (固定遅延の slave)。+ AXI の slave model と protocol checker の単体テスト、MM.5 の I1-I6 の directed (§10.4) | + GD (N=1 の debug directed、W2, W4)。rv64mi の breakpoint は pass/fail へ (§9.3) | + H 17 本、V 20 本、test_vmspre、debug と H/V の directed | 既定コアを新コアに |
| GA / GL-C |  |  | W2 | W2, W4 | 同 | 同 (固定遅延) | 同 | 同 | 同 |
| GL-B |  |  | W2 | W2, W4 | 同 | 同 + 乱数遅延で record 数と最終 hash が固定遅延と一致 (§10.4)。cycles は変わってよい | 同 + DMI idle で MD の前とビット一致 (§9.3) | 同 | 同 |
| GB1 |  |  | W2: 6.6, 7.1 | W2, W4 | 同 | 同 | 同 | + 7.1v | 同 |
| GT4, GB2 |  |  |  |  | W2, W4 | 同 + 乱数遅延 (GT2 short も) | 同 | 同 | 同 |
| GB4 |  |  |  | (新コアの SMP は無い。回し方を D7 の測定で決めた、§6.3) | W2: メモリ系の変更ごと。W4: マイルストーン末 (§6.3) | W2: MM の全コミット (固定遅延と乱数遅延)。W4: マイルストーン末 | 同 (SBA と hartreset の quiesce はメモリ系) | 同 | 同 |
| GH |  |  |  |  |  |  |  | W2, W4 | 同 |
| GX |  |  |  | 決定的なテスト全部 | 同 | 同 | 同 | + H/V | 同 |
| GV |  |  | N=1 boot (W2) | N=1 (W2, W4) | + litmus4, N=2, N=4 (NBA の相互確認だけで、N=4 の判定には使わない、§6.3) | 同 + 乱数遅延 (§10.4) | 同 | + hvlinux | 全部 |
| GD4 |  |  |  |  |  |  | W2: 節目と末。W4: 末 | 同 | 同 |
| GG |  |  |  |  |  |  | W2: N=1 全部と N=4 の SMP のテスト、節目と末。W4: N=1、末 | 同 (H/V の追加の後に再実行) | 同 |
| GS / GF | S1 の対照を記録 | 記録 | 記録 | 記録 + M3 判定の材料 | 同 | 同 (+ MM の事象、§10.4) | 同 (+ `dbg`、`gdb` の列) | 同 | 同 |

【決定】(M4 手順 1、ユーザ承認) G0 の litmus N=2 は短い像 `litmus_n2_short.hex` (ITER=200。AMO/LOCK は 1000/500 のまま。W2 985,091 cy、W4 971,035 cy) にする。理由: ITER=1000 の N=2 は負荷の高い箱で W2 約 35 分、W4 約 2 時間 (wall) で、G0 の時間に収まらない。ITER=1000 の像は `#[ignore]` の `test_{w2,w4}_litmus_full_2hart` に残す (W2 4,021,722 cy、W4 3,955,649 cy)。GT4 の W2 は 5,031,303 cy。
【未決】(M4) GT4 の W4 は約 140 cy/s で 10 時間級 (N=4 の段差) のため判定していない。表は W4 の GT4 を毎回回す形のままだが、GB4 の W4 と同じく「マイルストーンの末だけ」に改める案をユーザの判断に出す。

【決定】(D11) MM (外部メモリインタフェース、設計書 §MM) は M4 と MD の間のマイルストーンで、AXI4 の slave model と protocol checker (GP) を MM から全 run に入れる。GM は乱数遅延の再走で、MM 以降は GL-B と GT2 short を毎コミット、重いゲートを節目に回す。MD 以降の列は MM を含む。

旧コア (V14) は M6 まで既定コアであり、CLAUDE.md の梯子 1-5 (既定、litmus4、N=2 boot、N=4 boot、hvlinux) をそのまま回し続ける。

### 1.3 コミットごとの運用

- 新コアだけを変えるコミット: G0。M2-M3 では GL-B が最初の実ゲートになる (旧コアの「N=2 boot が最初の実ゲート」に相当)。
- メモリ系 (`lsu/`、`mem/`、dcache、MMU、SoC) を変えるコミット: M4 以降は GB4 必須 (設計書 §2.5)、M5 以降は GH も必須。front end と予測器の変更は M4 以降 GB2 必須。新コアの SMP は M4 から存在するので、M3 の dcache 2 ポート化 (bank、ポートごとの tag、MSHR file の構造) は `MSHR_N=N_FILL=1` のまま N=1 のゲート (G0、GA、GL-B、GB1、GX) で検査する。`MSHR_N`/`N_FILL` を 1 より大きくするコミットは、M4 で新コアの GB4 ができた後に限り、1 つずつ GB4 をゲートとする (`MSHR_N = 2` は M4 の手順 4 で採用、結果は §1.6)。
- 共有モジュール (CLINT、csr、SoC、dcache/MMU への追加出力) または V14 に触れるコミット: V14 で梯子 1-5 を回す。共有モジュールの変更は M2 まで追加のみ (設計書 §4.4) なので、V14 の dhrystone/coremark の cycles と instret はビット一致するはずであり、それを受入条件にする。
- AXI4 の外部メモリポート (設計書 §MM: `mem_ctrl` の外側、write buffer、ID、SoC の DRAM 側ポート) を変えるコミット (MM 以降): メモリ系なので GB4 (W2) 必須。加えて G0 (固定遅延)、GP、GL-B と GT2 short の乱数遅延 (GM)。V14 の枝に触れないことを V14 の dhrystone/coremark のビット一致で確かめる。
- デバッグの経路 (設計書 §D: commit の `dm_take` と outcome DEBUG、retire 制限、`trig_unit`、trigger の照合、DM、SBA、reset 木) を変えるコミット (MD 以降): G0 (GD を含む) と、DMI idle のビット一致 (§9.3: W2 の GL-B と新コアの bench 4 本)。SBA と hartreset の quiesce はメモリ系として GB4 も通す。trigger の照合や DM の ROM を変えたら GD4 と GG を節目で回す。
- サイクル予算は早期終了つきの上限であり、理由なく増やさない。ハーネスの載せ替えで予算が足りなくなった場合は、同じハーネスで V14 を測り、その値を根拠として記録してから変える。

### 1.4 M2 のゲートの結果 (2026-10-16)

M2 は統合ブランチ `phase15/m2-int` を master の `4fec4e4` に merge して閉じた。既定 `veryl test` は 850 passed、0 failed (W2 と W4 の生成ラッパ各 286 本を含む)。語: LS = W2 で golden と lockstep 一致、PF = pass/fail だけ。golden は `golden/b0f4668-obs` の `fab5ae5` (成果物、`TRACER_VER = 3`) と `6afdb10` (`ld_replay`、`supm_vm` の golden run を追加)。

| ゲート | 結果 |
|---|---|
| G0 (W2) | LS: rv64ui/um/ua/uc/uf/ud、rv64mi 14 本 (mcsr を含む)、rv64si、uzba/uzbb/uzbs、mzicbo、directed (zicond、hint、zcb、sysb、supm、supm_vm、ld_replay、cmo、svnapot、zfhmin、zfa、fma、fp_smoke)。PF: rv64mi の csr/ma_fetch (misa の値で制御フローが分かれる) と illegal (割込みの位置。arch harness に schedule replay が無い)、rv64ui_v と icache_alias (golden の checkpoint が無い)、svpbmt/svpbmt_dram、svadu/svadu_amo、sstc/hpm/sscofpmf/priv、lrsc_reorder、io_smoke、sc_wperm、smode_plic、IO directed 2 本 (io_access、io_plic)、§7.4 の probe 27 本 (b46_uart を含む) |
| G0 (W4) | PF: rv64ui 全部と、W2 と同じリスト全部 |
| GA / GL-C (W2) | 696 本で pass 696、golden の最終 hash 一致 690/690。残り 6 本は `m2_act.list` で `lockstep=0` (Zicntr 2 本と B56 の pmpsm 4 本) の GA だけ。M2 末の梯子 (`4fec4e4`) で再確認した |
| GA (W4) | Svadu の前 (`751944f`) に pass 692/696 (落ちたのは ADUE の 4 本)。W2 と W4 の最終 hash は Zicntr 2 本を除いて全一致。Svadu の後は W4 で再実行していない |
| GL-B | pass。16,360,435 サイクル、record 10,417,776 (非 trap 10,415,351) は golden と同数、2^16 record の checkpoint 158 個と最終 hash `74d4b7982390260f` が一致、割込み 30 回を replay して assert 0。新コアの修正は要らなかった |
| GB1 (W2) | 6.6: 21,940,363 サイクル、7.1 (FP、ADUE=1): 20,691,107 サイクルで pass。5.15 の pass/fail run は 16,433,955 サイクル |
| GV | Verilator の W2 5.15 N=1 boot (`sim/verilator/tb_soc_linux_boot_w2.sv`) が PASSED。cycles、instret 10,436,050、record 10,438,486、trace hash `789b5e3f5edaf8f1` が native の pass/fail run と完全に一致 |
| GS | §6.2 の M2 の行。W2 は decline 0、fallback 0。W4 は Clock event の 2 つの `If` の木が decline する (下の繰り越し) |
| GF | 発火行列 40 行のうち、走らせた 38 行がすべて 0 より大きい (`fire_check.py` exit 0)。走らせていない 2 行は smp ゲートの `ad.r_inv_race` と `at.fail` (M4) |
| V14 の梯子 | master の `4fec4e4` で 1-5 が緑: 既定 850 passed、litmus N=4 3.87M、N=2 boot 16.42M、N=4 boot 25.18M、hvlinux 22.32M、5.15 N=1 12.23M。dhrystone 235,804/264,834 と coremark 394,546/374,357 (cycles/instret) は M1a の値とビット一致 |

繰り越し (M2 の出口を妨げないもの):

- GS の W4: cy/s が W2 の約 1/15 (veryl の修正後も約 1/10)。原因と対処は §6.2 の M2 の補足。M3 の最初の作業にする。
- GF: matrix に無い事象で、どのログでも 0 のもの (W2 198 本中 17 本) の扱い (§5.2 の【M3 で決定】)。
- §7.4 の未作成の directed: walk 中の full kill による epoch 破棄 (PTW の遅延を伸ばす仕掛けが要る)、PLIC claim の競合 (M4)、PAUSE が drain しないこと。
- §7.1 の未充足の行 (§7.1 の M2 末の状態)。
- 設計書 §L.16 の Svadu の残り: 失敗する SC も D を立てる (未決)、A/D の書き込みは M4 まで STORE_WT。設計書 U28 の残り (他 hart の dirty コピーの recall、DRAM からの uncached fetch が自 hart の dirty line を見ない) は M4。
- 付録 B の B30 の case 4 は、直した語での golden 上の再確認をまだしていない (新コアは 4 case とも仕様どおり)。


### 1.5 M3 のゲートの結果 (2026-10-18)

M3 の手順 1-6 は master の `13241df` まで、手順 7 の sweep の採用値は `7c4bebf`、M3 の末の U26 は `797e61f` で入った (設計書の「M3 の進捗」と「M3 の完了」)。サイクル数は特に断らない限り 5.15 N=1 boot のもので、手順 6 までの 5.15 の pass/fail の run の値は 10,000 サイクル刻みである。手順 7 からは pass/fail の run も正確なサイクル数を記録した。

| 時点 | ゲート | 結果 |
|---|---|---|
| 手順 2 (`64fea45`) | G0 | 850 passed、0 failed、34 ignored。W4 の arch ラッパを lockstep で生成し直し、W2 と同じ 187 本が W4 でも lockstep で一致 |
| 手順 2 | GA / GL-C (W4) | 696/696 pass、hash 690/690 |
| 手順 2 | GL-B (W4) | 13,387,428 サイクル、record 10,417,776 は golden と同数、最終 hash `74d4b7982390260f` (W2 と同じ)、不一致 0 |
| 手順 2 | GB1 (W4) | 5.15 13,424,873 (instret 10,425,675。W2 は 16,433,955)、6.6 18,519,631、7.1 18,003,545 |
| 手順 2 | GV (W4) | `sim/verilator/tb_soc_linux_boot_w4.sv` が PASSED。cycles、instret、record 10,428,106、trace hash `0277005cc4357fd4` が native の pass/fail run と一致。1,869 s (7.2k cy/s) |
| 手順 2 | GX | 既定ログの W2/W4 の同名テスト 285 対で H 行を比べ、282 対が一致。違う 3 対は説明済み: `probe_b13_csrrd` (rdtime。mtime がサイクル由来)、`probe_b05_sc` と `mmu_svadu_amo` (W4 で SC が 1 回失敗。予約した line が自 hart の追い出しで消えた。D8 が許す失敗で、retry で成功する) |
| 手順 2 | GF (W4) | `fire_check.py` exit 0 (default、act、boot、bootls) |
| 手順 4 (`d658df4`) | G0 / GA / GL-C | 850 passed。ACT4 は W2 で 696/696、hash 690/690 |
| 手順 4 | GL-B | W2 15,713,503 (M2 末は 16,360,435)、W4 12,641,493。hash は golden と一致 |
| 手順 4 | GB1 | W2: 5.15 15,790,000 (M2 末は 16,433,955)、6.6 21,428,628、7.1 19,971,632。W4: 5.15 12,660,000 (手順 2 は 13,424,873) |
| 手順 4 | V14 (`c23af0c`、`v14_dcache` の凍結後) | litmus4 3.87M、N=2 16.42M、hvlinux 22.32M、N=4 25.18M、すべて pass。dhrystone 235,804/264,834、coremark 394,546/374,357 はビット一致 |
| 手順 5 (`56b5b46`) | G0 | 852 passed (`test_w{2,4}_mem_mem2` を追加。W2 4,176 / W4 2,847 サイクルで hash 一致) |
| 手順 5 | GA / GL-C | W2 と W4 で 696/696、hash 690/690 |
| 手順 5 | GL-B / GB1 | GL-B は W2 15,713,503 / W4 12,641,493 (手順 4 と同一)。GB1 は W2 15,790,000 / 21,428,628 / 19,971,632、W4 12,660,000 / 17,601,691 / 17,025,059 (5.15 / 6.6 / 7.1)。checker はすべて 0 |
| 手順 5 | GF | 0 の行なし。新しい 6 行は W4 の default で発火 |
| 手順 6 (`e7b9419`) | G0 | 852 passed、0 failed |
| 手順 6 | GA / GL-C | W2 と W4 で 696/696、hash 690/690 |
| 手順 6 | GL-B | W2 15,593,486 (−0.76 %)、W4 12,442,044 (−1.58 %)。hash `74d4b7982390260f` |
| 手順 6 | GB1 | W2 15,670,000 / 21,325,727 / 19,815,511、W4 12,480,000 / 17,490,395 / 16,921,813 (5.15 / 6.6 / 7.1) |
| 手順 6 | GF | exit 0。新しい行 `ren.ck_alloc`/`ck_restore`/`ck_none`、`disp.cut_ck`、`iss` はすべて 0 より大きい |
| 手順 7 (`902b273`、RTL は `2feea4b` と同一) | G0 | 852 passed、0 failed |
| 手順 7 | GA / GL-C | W2 と W4 で 696/696、hash 690/690 |
| 手順 7 | GL-B | W2 14,871,928 (手順 6 は 15,593,486、−4.6 %)、W4 12,108,086 (12,442,044、−2.7 %)。hash `74d4b7982390260f` |
| 手順 7 | GB1 | W2 14,948,679 / 21,263,334 / 19,589,910、W4 12,132,244 / 17,479,576 / 16,871,179 (5.15 / 6.6 / 7.1)。checker はすべて 0 |
| 手順 7 | GF | exit 0、matrix の行に 0 は無い |
| M3 の末 (`087a7d1`) | G0 | 852 passed、0 failed、44 ignored (916 s)。W2/W4 の lockstep arch を含む |
| M3 の末 | GA / GL-C | W2 と W4 で 696/696、hash 690/690 |
| M3 の末 | GL-B | W2 14,398,090 (手順 7 は 14,871,928、−3.19 %)、W4 11,763,601 (12,108,086、−2.85 %)。どちらも record 10,417,776、hash `74d4b7982390260f` (golden)、不一致 0 |
| M3 の末 | GB1 | W2 14,469,209 (−3.21 %) / 20,653,378 (−2.87 %) / 19,267,105 (−1.65 %)、W4 11,770,173 (−2.98 %) / 17,211,050 (−1.54 %) / 16,530,632 (−2.02 %) (5.15 / 6.6 / 7.1、手順 7 との比)。checker はすべて 0 |
| M3 の末 | GF | `fire_check.py` exit 0、matrix の行に 0 は無い (default、act、boot、bootls。boot と bootls には boot のログ 8 本すべて)。新しい行 `mp.ewake` (default) |
| M3 の末 | GV | Verilator 5.050 (`-O3`) で両構成が PASSED。W2 は cycles 14,469,209、instret 10,427,890、record 10,430,322、hash `e6c9b918825f45a3`、W4 は 11,770,173、10,418,577、10,421,005、`c146b7ae5ad120b5` で、native の pass/fail run と一致 |
| M3 の末 | GX | 既定ログの W2/W4 の同名テスト 286 対 (手順 5 で `mem2` が増えた) の最終 hash を比べ、284 対が一致。違う 2 対は下 |
| M3 の末 | V14 | 共有モジュールを変えていない (変更は `src/core/{common,lsu,mem}` と `heliodor_core` だけで、V14 はこれらを使わない) ので省いた |

- 手順 4 の W2 6.6 は、メモの値 21,428,720 が最終版より前のもので、master の `d658df4` で走らせ直した 21,428,628 が正しい。
- GS と D7 の測定は §6.2 と §6.3 に置く。手順 6 の CPU 時間は W2 の boot 4 本で 12,157 s (user)、W4 の 4 本で 34,645 s。測定中のマシンの負荷 (loadavg 7-48) で揺れるので、速度の結論に使うのは同時に走らせた対 (`NUM_CKPT` 0 対 4 の +6.6 %) だけである。
- 手順 4-6 では GV と GX を記録していない (マイルストーン末に回す)。
- M3 の末の GX の差 2 対: `probe_b13_csrrd` (rdtime を読む。record は W2 2,279 / W4 2,278 で、mtime がサイクル由来なので当然違う)、`probe_b05_sc` (record は 5,639 で同数。W2 で SC が 1 回失敗した (`at.rsv_coh` 1、`sc_nores` 1、W4 は 0)。probe は SC の成否どちらも許し、a0 を合算するので制御フローは同じ)。手順 2 にあった `mmu_svadu_amo` の差は今回は出なかった。`io_access` は H 行を出さないが、arch 行の hash が一致した (`feb3a60a07723337`)。
- 手順 7 の CPU 時間は W2 の boot 4 本で 12,332 s (user)、W4 の 4 本で 39,915 s (4 コアに固定)。
- 既知の不具合 (修正済み): master (`7c4bebf` 以降) で `veryl build` (SV の出力) が veryl の emitter (`emitter.rs:3522` の unreachable) で panic する。`2feea4b` では通り、引き金は `902b273` の tb 用構成 `cfg_w4_sb8` (test_lsu の `h5 = lsu_harness::<cfg_w4_sb8>`) である。解決に失敗しているのは `core_types.veryl:490` の `tag_next::<FTQ_TAG_W, CFG::FTQ_N>` (`ftq_next`) を `CFG = cfg_w4_sb8` で解くところ。`cfg_w4_sb8` の値をすべてリテラルにしても、`src/core/common` に移しても、名前を変えても再現するので、alias は原因ではない。veryl のバグで、別に直している。`veryl test` (sim) は通るので G0 には影響しないが、直るまで GV と synth 用の SV は master のままでは出せない。M3 の末の GV は、作業用の worktree で `h5` を一時的に `cfg_w4` に置き換え、`cfg_w4_sb8` を退避して `veryl build` し、走らせた後に戻した (commit していない)。原因は analyzer が import 経由でしか届かない generic package 内の global function の引数を呼び出し側の namespace で修飾していたことで、veryl の `fix/emit-generic-fn-cfg-lookup` (`1e287ff7`) で直し、共有バイナリを作り直した。master `797e61f` で `veryl build` が通る。

新コアの bench (`tohost` までのサイクル数。`test_cbench_*`、§2.4。基準は手順 6 の値で、設計書 §3.3):

| 時点 | 構成 | dhrystone | coremark | fpmm | spmv |
|---|---|---|---|---|---|
| 手順 6 | W2 | 272,321 | 395,868 | 1,175,729 | 45,936 |
| 手順 6 | W4 | 212,453 | 327,210 | 982,010 | 36,114 |
| 手順 7 | W2 | 272,262 | 400,101 | 1,123,913 | 44,084 |
| 手順 7 | W4 | 212,453 | 327,210 | 982,010 | 36,114 |
| M3 の末 | W2 | 268,750 (−1.29 %) | 381,245 (−4.71 %) | 1,115,855 (−0.72 %) | 43,773 (−0.71 %) |
| M3 の末 | W4 | 204,945 (−3.53 %) | 315,611 (−3.54 %) | 975,168 (−0.70 %) | 36,113 (0) |

M3 の末の百分率は手順 7 との比。手順 7 の W2 の coremark が遅くなったのは `FTQ_N` を 32 にしたためで (設計書 §3.4)、W4 は採用値で bench の値が変わらない。

---

### 1.6 M4 のゲートの結果 (2026-10-25、完了)

M4 の手順 4 で `MSHR_N = 2` を `cfg_w2`/`cfg_w4` に採った (`90f6f8e`、`6eb785a`、`b7b852d`。設計書 §M.6.4)。W4 の GB2/GT4 と W2 の 6.6/7.1 の SMP boot はマイルストーン末に走らせ、下の表に結果を置いた。W4 の GB4 (native) と W4 の 6.6/7.1 の SMP boot は M6 の既定切替のゲートに繰り延べた (表の下)。

| ゲート | 結果 (`MSHR_N = 2`) |
|---|---|
| G0 | 860 passed、0 failed。`tb/test_lsu` の seed を h0 1 → 5、h1 3 → 7、h2 2 → 9 に替えた (`MSHR_N = 2` で W2 の `sb.urgent`、`at.watch`、W4 の `at.fail` の coverage assert が旧 seed で発火しなくなったため) |
| GL-B | record 10,417,776、hash `74d4b7982390260f`、`chk_dcache` 0 |
| GB2 (W2) | 19,082,790 |
| GB4 (W2) | 24,808,238 pass、checker はすべて 0。積み重ねた先端 (手順 1-3、7 と mtime firmware、`MSHR_N = 1`) では 24,922,839 pass。旧 4-hart firmware の像は 43,479,101 だったので、以前の N=4 SMP の遅さは firmware の delay だった |
| GT4 (W2) | 5,029,995 pass |
| GB2 (W4) | 16,159,839 pass、checker はすべて 0 |
| GT4 (W4) | 5,028,286 pass |
| GB2 6.6 / 7.1 (W2、SMP N=2) | 31,657,282 / 23,814,202 pass、chk はすべて 0 |
| GB4 (W4、native) | 未実行 (下の決定) |
| GV (W2) | Verilator で 5.15 N=2 19,082,790、litmus N=4 5,029,995、5.15 N=4 24,808,238 がすべて PASSED。cycles は native の GB2/GT4/GB4 (W2) と完全に一致 |
| GV (W4) | Verilator で 5.15 N=2 16,159,839、litmus N=4 5,028,286 が PASSED で native と完全に一致。5.15 N=4 は 22,546,887 で PASSED (native は未実行) |

【決定】(2026-10-25、ユーザ承認) W4 の 5.15 N=4 boot は native で走らせない。理由: この箱で約 130 cy/s なので約 48 時間かかる。代わりに Verilator の W4 N=4 boot の PASSED と、W2/W4 のほかの GV (N=2、litmus N=4) が native と cycle 単位で一致していることで担保する。native の W4 GB4 と W4 の 6.6/7.1 の SMP boot は M6 の既定切替のゲートに繰り延べる。

`MSHR_N` の sweep (1 / 2 / 4。W2、W4。coremark は 3 点とも同一で W2 381,245、W4 315,611、dhrystone はほぼ不変):

| 測定 | W2 | W4 |
|---|---|---|
| GL-B | 14,398,090 / 14,316,714 / 14,313,517 | 11,763,601 / 11,681,911 / 11,675,464 |
| fpmm | 1,115,855 / 1,044,649 / 1,044,450 | 975,168 / 861,025 / 855,571 |
| spmv | 43,773 / 41,165 / 40,852 | 36,113 / 32,160 / 32,190 |

`DcachePerf` に足した `mshr_live2` (live な MSHR が 2 本以上のサイクル) と `alloc_ovl` (別のエントリが live の間の alloc) は、`fire_matrix.txt` の boot の行である (`fire_check.py` は struct から名前を復元するので、表の変更は要らない)。GL-B では W2 が 331,640 サイクル (2.3 %)、alloc 32,166 のうち 11,703 が重なり、W4 が 349,443 サイクル (3.0 %)、32,167 のうち 12,396 が重なる。

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
| `o_perf`, `o_chk`, `o_chk_io` | 出力 | 設計書 §4.5 の event wire と checker flag、§8 の IO モニタ。実装 (M2) の名前は `o_core_perf` (`PERF_W` = 512 bit に 0 拡張)、`o_core_chk`、`o_io_obs` (IO モニタ自体は tb 側、§8)。 |
| `i_dbg_retire_limit_en/limit`, `i_dbg_irq_mask/allow` | 入力 `[N_HARTS]` | 設計書 §5.13。harness が駆動しない限り 0。 |
| `i_mtime_tick` | 入力 | `MTIME_SRC=EXTERNAL` のときだけ使う (§4.7)。 |
| `i_ext_irq_src` | 入力 | PLIC の追加ソース。smode_plic の tb パルス用。既定 0。 |
| `UART_WRCNT` | param (M2) | 1 なら UART + 0x100 の読み出しが device 側の UART 書き込み回数を返す (b46_uart 用)。既定 0。 |
| `i_dm_rst`、`i_dm_psel/penable/pwrite/paddr/pwdata/pstrb/pprot`、`o_dm_pready/prdata/pslverr` | 入出力 (MD) | DM のドメインの reset と APB4 の DMI ポート (設計書 §D.3)。debug を使わない harness は `i_dm_psel = 0`、`i_dm_rst = rst` を明示的に接続する。V14 の枝は `pready = 1`、`prdata = 0`。 |
| `DM_BASE` | param (MD) | debug memory の base (設計書 §D.7、U38)。DM の 2 領域は `MAP_BOOT`/`MAP_ARCH`/`MAP_LITMUS` のすべてに入る (§2.2)。 |
| `o_dm_obs` | 出力 (MD) | DM の観測 (DMI アクセス、abstract command と cmderr、SBA と sberror、group の伝播、reset)。`perf_acc` と `chk_dm` が読む (§5.1、§5.2)。 |
| V14 用の `o_dbg_r3/pc/retire_v/trap_*` | 出力 | V14 の既存 harness が読むものだけを残す。消費者のない 23 本の forensic 出力は統合時に削除する。 |

Veryl では未接続の入力は警告にしかならず、浮いたまま動作が変わりうる。新しい harness はすべての入力を明示的に接続し、新規ファイルの `missing_port` 警告は 0 とする (設計書 §5.15 の lint 差分)。

### 2.2 PMA map パラメータ

PMA 表の型と評価関数は設計書 §5.11、boot 系のプラットフォームマップの値と表の不変条件は設計書 §S.2 が持つ。harness ごとに使う表を `tb/tb_platform_pkg.veryl` に置く。

| 表 | 使う harness | 内容 (旧コアとの違い) |
|---|---|---|
| `MAP_BOOT` | N=1/SMP boot、hvlinux、smode_plic | ROM [0, 0x4000) は executable かつ uncacheable。DRAM 0x8000_0000 から 32 MiB。CLINT/PLIC/UART は IO。旧コアは ROM を hole に置き、`PMA_FAULT=0` で hole 判定を切っていた。 |
| `MAP_ARCH` | arch、ACT4、bench | ROM なし。DRAM は harness の配列サイズ (4 MiB、bench は 256 KiB)。0x5000_0000 (`RVMODEL_ACCESS_FAULT_ADDRESS`) は hole。旧コアは pa[31] だけを見て 2 GiB を backed とし、PA[63:32] を無視していた (付録 B の B34)。 |
| `MAP_LITMUS` | litmus | DRAM 32 MiB、ROM なし。tohost の write-through 窓は存在しない (設計書 §5.11 PM5)。 |

MD から、3 つの表すべてに DM code と DM data の 2 領域 (target DEBUG、設計書 §S.2) が入る。Debug Mode の外からのアクセスはアクセス fault になるので、既存のテストの振る舞いは変わらない。`pma_check.py` は target DEBUG の領域を DTS と `sail.json` との照合から外す。

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
| 新コアの bench ラッパ (M3) | tb/test_core_bench.veryl | `#[ignore]`、ゲートではない | 新規。`arch_soc_harness` の上の `test_cbench_w{2,4}_{dhrystone,coremark,fpmm,spmv}` (pass = tohost 1。cycles、instret、perf の dump を印字) と、5.15 N=1 boot (`test_w{2,4}_linux_boot` と同じもの) を他のテスト名と部分文字列が衝突しない名前で走らせる `test_cboot_w{2,4}`。fpmm は upstream の mm kernel (double、fmadd.d が主体、48×50×48 を 4 回、tohost は 0x8000_3000)、spmv は upstream の spmv (double、load が主体で小さい)。M3 の sweep の指標 (設計書 §3.3)。1 構成分は `veryl test --ignored --test test_cbench_w2` のように走らせる。 |
| `test_lsu` (単体 tb) | tb/test_lsu.veryl | 既定 1 本 | 新規 (M1b)。乱数 program を `lsu_harness` に流す。instance は `cfg_w2` 2 本、`cfg_w4` 3 本、tb 専用の構成 `cfg_w4_sb8` 1 本 (`h5`)。`cfg_w4_sb8` (tb/cfg_w4_sb8.veryl) は `SB_N` だけを 8 にし、他の値は `cfg_w4` を参照する (M3)。理由: `SB_N` を 16 にした `cfg_w4` では、乱数 program が SB に 14 line までしか溜めず、W4 の urgent drain (`sb.urgent`) が発火しない。M3 の末から dcache の `o_vhit` を実物から配線し、V 段の早期 wake も unit test で走る。`cfg_w4_sb8` は `veryl build` の panic (veryl の不具合、§1.5) の引き金になっている。 |
| `test_smode_plic_harness` | tb/test_smode_plic.veryl | 既定 1 本 | 移植。新コア枝は統合 SoC (`MAP_BOOT`、ROM に hex) で、source 10 のパルスは `i_ext_irq_src` から入れる。2,000 サイクル予算は SoC 経由の遅延で足りなくなりうるので、V14 を同じ SoC 構成で測った値の 2 倍に改める (§1.3)。PLIC claim の読み出し回数 == 1 を assert に加える (§8)。実装 (M2): 新コア枝は `test_w2_smode_plic`/`test_w4_smode_plic` で、ROM ではなく同じ program を DRAM 0x8000_0000 から `arch_soc_harness` (`MAP_ARCH`) で走らせる (コードが PC 相対なので載せ替えが要らない)。source 10 は harness の param `EXT_IRQ_SRC = 0x400` をサイクル 8-14 に `i_ext_irq_src` へ入れる。合否は `PASS_BY_X3` で x3 := 0xAA、予算は 1,000 サイクル刻みの早期終了で上限 20,000。claim の 1 回性は回数の assert ではなく、§8 の `chk_io_mon` (claim を含む PLIC アクセスがすべて retire したアクセスとちょうど 1 対 1) で検査する。V14 枝は現行の harness のまま。 |
| `test_smoke`, `test_hello`, `test_linux_boot` | 同名 .veryl | `#[ignore]`、梯子の外。forensic `o_dbg_*` の唯一の消費者 | 削除 (M1a の最初、v14 改名より前)。 |
| `test_soc_linux_boot_harness` (+66/71/71v) | tb/test_soc_linux_boot*.veryl | N=1 boot 4 本 | 統合 SoC `N_HARTS=1` へ移す。`CORE` param を足す。x3 は V14 なら `o_dbg_r3`、新コアなら `retire_mon`。census の印字は V14 枝だけに残す。lockstep 用の param (`MTIME_SRC`、schedule、checkpoint ファイル) を足す。 |
| `test_soc_smp_linux_boot_harness` (+66/71) | tb/test_soc_smp_linux_boot*.veryl | SMP boot 7 本 | `CORE` を足す。生存プローブと最初の 4 trap の印字は `retire_mon` から作る (旧 `o_dbg_trap_pc` は c_pc で、割込みと偽 ifault で誤っていた)。 |
| `test_litmus_harness` | tb/test_litmus.veryl:17-385 | litmus 3 本 | `CORE` を足す。新コアの tohost は retire store から取る。新コアでは litmus の atomic がどの番地でも cacheable になる。 |
| 新コアの SMP ラッパ (M4) | tb/test_core_smp.veryl | G0 の litmus N=2 short (W2、W4)。`#[ignore]`: litmus full N=2、litmus N=4、5.15 SMP boot N=2/4 | 新規。`boot_soc_harness` を `N_HARTS` で一般化した上のラッパ (hart ごとに `retire_mon`、`rvfi_tracer`、perf_acc。pass は hart 0、fail はいずれかの hart。`PROBE_LOG2` で hart ごとの pc、records、traps を印字)。litmus は `MAP_ARCH` (ROM なし、4 MiB)、tohost は `retire_mon` が retire record の store から見る。DRAM の配列を読まないので histogram の dump は無い。N=4 boot は新コア専用の firmware `test/hex/linux_boot_fw_4hart_mt.hex` を使う (設計書 M4 の進捗)。 |
| `test_smp_coh` (M4) | tb/test_smp_coh.veryl、test/coh/{coh,ad,unc}.S | G0 (N=2、W2/W4)、N=4 は `#[ignore]` | 新規 (§7.2)。coh.S は CoRR、LR/SC の reservation、AMO の watch、drain の飢餓の上限、`wt_fires`、PLIC claim の競合 (N=2 で W2 132,938 cy、W4 128,288 cy)。ad.S は 2 hart の A/D の競合、unc.S は SMP の uncached 読みと他 hart の dirty line (W2 6,128 cy、W4 6,155 cy)。 |
| `test_soc_hvlinux_harness` | tb/test_soc_hvlinux.veryl:15-208 | hvlinux | 統合 SoC `N_HARTS=1` へ移す。`CORE` を足す。 |
| 単体 tb (`test_clint` ほか) | | | `test_clint` は CLINT の新入力を `i_tick_sel=0` に固定すれば無変更で通る (§4.1)。 |
| Verilator ラッパ | sim/verilator/*.sv | N=1/2/4/8 boot、litmus4、hvlinux、ACT PMP | 変更しない。harness の名前とポートだけに依存しているので、`CORE` の既定値 (§2.5) に従う。 |
| `dm_soc_harness` (MD) | tb/dm_soc_harness.veryl、tb/dm_seq.veryl | GD、GD4 | 新規。統合 SoC (`MAP_ARCH`、`N_HARTS` は 1 か 4) の上に DMI script の player `dm_seq` を置き、APB を駆動する (§9.1)。program の hex と script の hex を param で受ける。ゲートリスト `test/gates/md_dbg.list` から生成ラッパ (`tb/test_w{2,4}_dbg*.veryl`) を作る。 |
| debug の Verilator ラッパ (MD) | sim/verilator/tb_soc_dm_n1.sv、tb_soc_dm_n4.sv、sim/verilator/jtag_dtm.sv、sim/verilator/rbb_dpi.c | GG | 新規、tb 専用。boot の harness と同じ SoC に、JTAG の TAP と DTM (dtmcs、dmi) を SV で置いて APB の master にし、DPI の C で OpenOCD の remote_bitbang を localhost の TCP で受ける (§9.2)。設計には入らない (設計書 §D.1)。 |

### 2.5 コアの選択と旧コアとの共存 (D6)

- SoC と各 harness は `CORE` param を持ち、generate-if で枝を選ぶ。V14 枝は旧 harness 本体の逐語移設なので、V14 のゲート結果は動かない。M6 では V14 枝と `src/v14/`、V14 専用の印字を削除し、`CORE` の既定値を変える。
- 【決定】新コアのテストは、ゲートリスト `test/gates/<milestone>.list` から `test/gates/gen_core_tests.py` が生成するラッパ (`tb/test_w2_*.veryl`、`tb/test_w4_*.veryl`) で走らせる。生成物は既定スイートに入るのでコミットする。ラッパは `CORE` を明示し、早期終了ループと golden checkpoint ファイルの param を持つ。理由: 1 回の `veryl test` で V14 と W2/W4 を同時に回せる。
- 【決定】(M2) 生成される suite のファイル (`tb/test_<core>_<suite>.veryl`) 1 つにつき、それを生成するゲートリストはちょうど 1 つとする。M2 のリストは領域ごとに分け、lockstep のリスト (`m2_<領域>.list`) と pass/fail のリスト (`m2_<領域>_pf.list`、`--no-lockstep`) が同じ suite を持たないようにする。理由: `gen_core_tests.py` は 1 回の実行で suite ごとのファイルを丸ごと書き直し、その実行が作らないファイルには触れない。2 つのリストが同じ suite のエントリを持つと、後に生成した方がもう一方のエントリを消す。
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
| 駆動 | master 側の `test/golden/run_golden.py <list>` が golden worktree でテストを走らせ、成果物を master の `test/golden/` に書き戻す (M2 で実装済み。手順は §3.6)。最初の成果物 (§3.5) は手で走らせて書き戻した。 |

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
| `tb/golden_runs_*.veryl` (生成) | ゲートリストから `run_golden.py` が生成する golden 実行用テスト (§3.6)。boot だけは手書きの `test_golden_boot_linux515_n1`。 |

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
- 窓の中のカーネル page fault の数は M2 で数えた: golden boot の trap は S の ecall 2,421、U の ecall 2、偽 ifault 1、U の命令 page fault 1 だけで、カーネルの page fault は 0 (§4.7、B03 は SAME)。
- 現行の成果物は `TRACER_VER = 3` で golden `fab5ae5` から作り直したもので、record 数は上表と同じ、最終 hash は `74d4b7982390260f` (上表の hash は `TRACER_VER = 1` と 2 のもの。`TRACER_VER = 2` のまま MASK 規則 SC_PA と AMO_X0_DATA を足した `4dbad87` で変わり、3 では変わっていない)。

### 3.6 成果物の扱い

| 成果物 | 置き場所 | コミット |
|---|---|---|
| MANIFEST (golden ブランチの commit、veryl の commit、`TRACER_VER`、`retire_pkg` の sha256、K、各テスト image の sha256) | `test/golden/MANIFEST` | する |
| arch 系の checkpoint (2^10 record ごと + 最終) | `test/golden/arch/<suite>/<test>.ck.hex` | する。`run_golden.py` が `test/gates/*.list` (`*_pf.list` を除く) から作る。M2 末で 190 本 (rv64ui/um/ua/uc/uf/ud/mi/si、uzba/uzbb/uzbs、mzicbo、directed。golden `6afdb10` で `ld_replay` と `supm_vm` を足した) |
| ACT4 の最終 `(order, hash)` (image の sha256 つき) | `test/golden/act/<ext>.final` | する (ACT4 の hex は gitignore だが、ツールチェーンは pin されているので再生成で一致する)。`run_golden.py` が `test/gates/m2_act.list` の `act_<ext>` suite から書く。61 ファイル、690 本 (`lockstep=0` の 6 本は持たない) |
| boot の checkpoint (2^16 record ごと)、schedule、`gtag` 位置 | `test/golden/boot/linux515_n1.{ck,irq,tag}.hex` | する (`0bc2467` で済み)。`tag.hex` は `AMO_VM` の位置を持たない (VM 下の AMO ごとに 1 つ立つので数が多すぎる)。その計数だけを `MANIFEST` に残す |
| golden 上の directed probe の結果 | 付録 B の probe 列 | ファイルにはしなかった。結果は付録 B の各行の probe 列に書き、probe のソースは branch `golden/probes` にある (§7.4) |
| 全文 trace (boot で約 1,000 万行) と差分 dump | `.golden/cache/` (zstd) | しない。必要時に再生成する |

- 再生成の契機: パッチの変更、tracer か `retire_pkg` の変更、test image の変更、K の変更 (D1)。`*.ck.hex` の先頭語に `TRACER_VER` を入れ、tracer は読み込み時に照合する。不一致は lockstep の不一致ではなく「golden が古い」として失敗させる。
- 道具 (M2 で実装): `test/golden/run_golden.py <list>...` は、すべての `test/gates/*.list` (`*_pf.list` を除く) の和集合から golden worktree に `tb/golden_runs_<suite>.veryl` を生成し (`#[ignore]` の `test_golden_arch_<suite>_<name>`。和集合なので、どのリストを走らせても生成物は同じ)、golden の veryl で suite ごとに走らせ、`arch/<suite>/<name>.ck.hex` と `MANIFEST` の節、ACT4 の suite `act_<ext>` なら `act/<ext>.final` の行を書く。`lockstep=0` のエントリは golden の run も成果物も持たない。受理条件は tohost == 1、H 行がちょうど 1 つで harness の要約と一致、K 行が 2^CK_LOG2 の連続した倍数、retire 契約 checker と FP の自己検査が 0。
- ACT4 の新コア側は `test/gates/run_act.py --core w2|w4` が回す: `m2_act.list` (696 本) から `gen_core_tests.py` で `tb/test_<core>_act_<ext>.veryl` (`#[ignore]`) を書き、`veryl test --ignored --test test_<core>_act_ --format json` を 1 回走らせ、GA (pass) と GL-C (最終 H 行と `<ext>.final` の一致。`check_hash.py` と同じ比較) を判定し、ラッパを消す (既定の `veryl test` がコンパイルしないように)。`--pass-fail` は GA だけ、`--from-json` は保存した report を判定し直す。`check_hash.py` は新コアの名前 `test_<core>_<rest>` を final の `test_<rest>` に対応させる。ACT4 の hex は gitignore なので `make -C test/act` で作る。
- 再生成 (M2): `TRACER_VER = 3` (§4.8) で、arch 188 本、boot、ACT4 690 本を golden `fab5ae5` から作り直した。boot の hash は、その直前 (`TRACER_VER = 2` のまま SC_PA と AMO_X0_DATA を足した `4dbad87`) と変わっていない。
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
- M2 で足した MASK 規則 (`TRACER_VER = 3`、§4.8): `SC_PA` (すべての特権の SC の store の PA と IO 印。golden は M+MPRV を含めて翻訳前の VA を出す、付録 B の B57)、`AMO_X0_DATA` (rd=x0 の AMO の store データ、B55)、`MISA` (misa を読む Zicsr op の rd と、その値から計算した値。B43 の taint 規則、§4.8)。

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
| ACT4 (全スカラ suite、Zabha/Zacas を含む) | golden lockstep (最終 hash) | M2 W2、M3 から W4 も | Zicntr は両者 `MTIME_SRC=INSTRET`、他は `OFF`。Zicntr 2 本 (B15) と pmpsm の 4 本 (B56) は `m2_act.list` の `lockstep=0` で GA だけ (M2)。 |
| 5.15 N=1 boot (ADUE off) | golden lockstep (checkpoint + schedule replay) | M2 W2、M3 から W4 も | `MTIME_SRC=INSTRET`、K=10。 |
| 割込みを受けるテスト (sstc_stimecmp、sscofpmf、smode_plic、hsstc、hvtmr、hvirq、hvsirq)、hpm_counter、test_arch_svadu、test_arch_svpbmt、test_lrsc_reorder | pass/fail | | 割込みの位置は arch harness では replay しない。svadu は ADUE (B33)、svpbmt は DRAM 内の NC/IO (設計書 §5.11)、lrsc_reorder は投機に依存する SC の成否 (B06) を含む。hpm の値はマイクロアーキテクチャ依存。 |
| 6.6 N=1、7.1 (FP、ADUE)、7.1v、全 SMP、litmus、hvlinux | pass/fail | | ADUE は投機的な A bit の書き込みで PTE の内容を変えうる。SMP は順序が非決定的。6.6 は DRAM 内の Svpbmt NC/IO を使いうる (設計書 §5.11 で trace diff の対象外)。 |
| GX: W2 対 W4 | 新コアどうしの差分 lockstep | M3 から | 決定的なテストのうち、golden lockstep から外したもの (golden 側の誤り、H/V) も含める。割込みを受けるテストは W2 を先行させ、その schedule を W4 で replay する。 |

### 4.7 golden だけに存在する区間と時刻の補正

【決定】(M2) EXCLUDE 窓と `MTIME_SRC=EXTERNAL` は使わない。golden の 5.15 boot の trap は S の ecall 2,421、U の ecall 2、偽 ifault 1、U の命令 page fault 1 だけで、カーネルモードの page fault は 0 だった。下の「無ければ」の場合に当たり、新コアは `INSTRET` のまま GL-B を通った (§1.4)。付録 B の B03 は SAME。`tick_align` は作らない。ACT4 の GL-C は最終 H 行だけを比べ (golden の ACT4 run は K 行を出さない)、`check_hash.py` は NUL で埋まったログから NUL を落としてから読む。

決定前の問い: EXCLUDE 窓と `MTIME_SRC=EXTERNAL` を使うかどうか。測るものは §3.5 の最初の成果物で、golden の 5.15 boot に、csrw satp (PA 0x8000_46C2 または 0x8000_475A) から最初の /init への sret までの間に、カーネルモードの page fault (scause 12/13/15) があるかどうかを見る (付録 B の B03 の (a))。

- 無ければ: 新コアの mtime は自分の retire record から作る (`INSTRET`)。それで計数は golden と一致する。
- 有れば: その trap から sret までを golden 側の EXCLUDE 窓 [a, b) とする。golden の tracer は窓の中の record を出さず、それ以降の order から b-a を引く。新コアは `MTIME_SRC=EXTERNAL` とし、tb モジュール `tick_align` が新コアの order を golden の order に写像したうえで (窓の後では窓の中の非 trap retire 数 L を加える) K ごとに tick を出す。こうしないと、窓の後の時刻の読み値が floor(L/K) だけずれ、以後の比較が崩れる。

---

### 4.8 実装で確定した規則 (M1a、`src/pkg/retire_pkg.veryl`、`tb/rvfi_tracer.veryl`、`tb/retire_mon.veryl`)

- mask と data: `mem_rmask`/`mem_wmask` は右詰めの 16 bit (16 B アクセスまで)、data は `_lo`/`_hi` の 64+64 bit。tracer は wdata を wmask のバイトで切り出してから印字・hash する。
- 混合関数: `mix64` (splitmix64 の finalizer) は `retire_pkg` に、rolling の 1 段 `h' = mix64((h ^ w) + 0x9e3779b97f4a7c15)` は tracer に置く。版は `retire_pkg::TRACER_VER` (現在 3。M1b で mnstatus の `N` 行を足して 2 に、M2 で下の MASK 規則を足して 3 に上げた)。`retire_pkg` を変えたら golden 成果物を再生成する。
- vector: §4.4 の形式に `V <vtype> <vl> <vstart> <wcnt> <vrf_hash>` を足す (vector op の record にだけ付く)。後から足すと TRACER_VER を上げることになるので最初から入れた。
- ビット単位の MASK (付録 B の mhpmevent の bit 63、mip/sip の bit 13 など) は、そのビットを 0 にしてから印字・hash する。フィールド全体を `*` にするのはフィールド単位の MASK だけ。
- rd=x0 の書き込みは record に出さない (rd_kind=INT かつ rd_addr=0 は「書き込みなし」)。`F` は fflags が 0 でないときだけ付ける。rd=x0 の load の `mem_rdata` の MASK は、trace に load の値を出さないので実装しない。
- M2 の MASK 規則 (`TRACER_VER = 3`):
  - `SC_PA`: SC の store record の PA と IO 印を hash から外す。全特権で適用する。golden は SC の store record に翻訳前の VA を出す (Sv39 の S/U だけでなく、M-mode の MPRV でも。付録 B の B57)。
  - `AMO_X0_DATA`: rd=x0 の AMO (LR/SC を除く。amocas を含む) の store データを外す (B55)。
  - `MISA`: misa を読む Zicsr op の rd を外し、その rd に taint bit を立てる。x レジスタは taint bit を持ち、taint の立った源を読む 32 bit の整数 op の rd と store データも外して、その rd に taint を伝える。taint はそれ以外の書き込みで消える。RVC と FP の op が taint の立ったレジスタを読んだときは外さないので、そういう使い方は不一致として表に出る (隠さない)。各コアは自分の build の ISA を misa で報告するので (B43)、ACT4 の trap/prolog の misa の読み出しと、rv64mi/mcsr のように読んだ値を計算に使うテストがこれで一致する。制御フローが misa で分かれる rv64mi の csr と ma_fetch は pass/fail のまま。
  - Zicntr: カウンタの読み出しは B15 の MASK:CNT で外れるが、ACT4 Zicntr はその値から計算するので、GL-C から外して GA だけで判定する (`m2_act.list` の `lockstep=0`)。
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
| `chk_io_mon` | tb (SoC の `o_io_obs` を読む) | §8 | 設計書 §5.14 |
| `chk_debug` (MD) | core | 入場と dret は lane 0 の唯一の flush、Debug Mode の間は割込みの受付と csr の trap 入力が無い、`dm_req` の間に started パルスが無い、step の arm から入場までの record と IrqEvent は合わせて高々 1、hit bit は受付のサイクルにだけ立つ、Debug Mode の外で DM 領域へのアクセスが完了しない | 設計書 §D.15 |
| `chk_dm` (MD) | tb (SoC の APB と `o_dm_obs` を読む) | APB の手順、存在しない hart への haltreq が無い、abstract command の実行中に対象 hart が running にならない、SBA の未完了は高々 1 | 設計書 §D.15 |

【M1a で決定】の synth からの除外方法は設計書 §5.15 に従う。`$assert` と `$display` は RTL に置かず、tb だけで使う (cc backend の whole-comb bail を避けるため)。

### 5.2 機構ごとの発火カウンタ

- コアは機構ごとに event wire を `o_perf` (`core_types::CorePerf`) に出す (設計書 §4.5)。SoC は hart ごとに `o_core_perf: logic<soc_pkg::PERF_W=512>` (V14 枝は 0) として出し、tb モジュール `perf_acc` (`tb/perf_acc.veryl`) が hart ごとに、各ビットが 1 のサイクル数と、full kill の `RedirKind` ごとの回数を 64 bit で累算する。arch と boot の harness が instantiate する。
- 【決定】(M2) 印字は名前ではなくビット番号で行う。テストの終わりに `PERF <core> <PERF_W> <width> <N_IQ> <ISSUE_W> <MEM_W> <WB_N> <RETIRE_CNT_W>` を 1 行、`PB <core> <bit> <count>` を 0 でないビットだけ (bit 0 は CorePerf の LSB)、`PK <core> <RedirKind> <count>` を出す。名前は `fire_check.py` が `core_types.veryl` と `xlate_pkg.veryl` の struct 定義から復元し、計算した幅を PERF 行の `<width>` と照合する (ずれたら exit 2)。理由: RTL 側に名前表を持たずに済み、struct の変更に自動で追従する。CorePerf は W2 で 195 bit、W4 で 225 bit。
- ゲート名 (matrix の列) は `fire_matrix.txt` の冒頭で定義した: `default` (既定 `veryl test` の W2/W4 の arch、directed、probe)、`act` (`run_act.py` の ACT4)、`boot` (W2 5.15 N=1 の pass/fail)、`bootls` (W2 5.15 N=1 の lockstep。retire limit と replay)、`smp` (M4 からの SMP boot と litmus)。MD で `dbg` (GD と GD4 のログ) と `gdb` (GG の Verilator の run の perf の dump) を足す。行の形は `<event> <gate>[:w2|:w4][,...]` で、`<event>` は葉か接頭辞 (`mp` は `mp[*]` の全要素)、`flush.full_kind.<KIND>` は PK の値。行は、列のゲートの合計が 0 より大きければ pass。ログの無いゲートだけの行は「走らせていない」と表示し、失敗にしない。
- M2 末の結果 (§1.4): 40 行のうち走らせた 38 行がすべて pass。走らせたログは default、act (W2 の pass/fail 114 本: misalign*、sv*、exceptionssv*、zalrsc、zacas、zaamo、zicbom/z、zifencei)、boot (5.15/6.6/7.1)、bootls。`flush.full_kind.BR` は設計上 0 (分岐は partial kill) なので matrix に載せない。
- `--zero` はどのログでも 0 の葉を列挙する。M2 末で W2 は 198 本中 17 本: `disp.cut_int`、`disp.cut_fp`、`ad.empty_gen`、`ad.excl_fail`、`ad.ev_skid`、`dtlb.fill_inv`、`itlb.fill_inv`、`ptw_i.full`、`ptw_i.afault`、`ptw_i.a_wr`、`ptw_i.d_wr`、`ptw_i.ad_rd`、`at.fail`、`at.watch`、`at.backoff`、`at.rsv_coh`、`flush.drop_older`。分類: 構造的に起こりえない (`disp.cut_int`: `PRF_INT_N` 96 = 32 + ROB 64。`flush.drop_older`: W2 は BRU 1 本)、SMP を待つ (`at.fail/watch/backoff/rsv_coh`、`ad.excl_fail`)、directed が要る候補 (`dtlb/itlb.fill_inv`、`ad.empty_gen`、`ad.ev_skid`、`ptw_*.afault`)、要確認 (`disp.cut_fp`、`ptw_i.a_wr/d_wr/ad_rd`: Svadu の後も I 側の A/D 更新が 0)。W4 は default しか走らせていないので 228 本中 40 本が 0 (boot 系の事象は 0 で当然)。
- 【M3 で決定】matrix に無い事象がどのゲートでも 0 のときに失敗とするか。今は `--zero` で一覧するだけで失敗にしない。失敗にするなら、上の「構造的に 0」と「SMP 待ち」を許容表に載せる必要がある。
- 【決定】`test/gates/fire_matrix.txt` に「機構、それが 0 より大きくなるべきゲート」を列挙し、`test/gates/fire_check.py` がマイルストーン末の梯子のログを集計する。どのゲートでも 0 のままの機構があれば exit code で失敗とし、directed test を足すか、その機構を消す。理由: ビット一致の結果は「発火しなかった」と読む (設計書 §5.15)。

| 機構 (event) | 所有者 | 期待するゲート | 判定に使う【M3 で決定】 |
|---|---|---|---|
| RETRY: FILL_BUSY / INV_RACE / PREEMPTED / WB_BLOCKED / BANK_CONFLICT | `dcache_port_adapter` (M2)、`dcache` (M3 から、`dc.r_*`) | boot / M4 の SMP boot と litmus / boot / (M3 の dcache は出さない、設計書 §M.6.7) / W4 の全テスト | dcache の bank 数 (設計書 §3.2。M3 で決定、U19) |
| kill: partial、full (trap / irq / REPLAY / RETIRE_FLUSH / T8 backstop) | `flush_ctrl` | 全テスト / boot。T8 は W4 (BRU 2 本) で、0 なら同じサイクルに mispredict する分岐 2 本の directed を足す | |
| commit group の切断理由: alone、lane>0 の例外、SB 予算、retire limit、irq_take | `commit` | arch / boot / lockstep run | |
| forward hit (SQ、SB)、drain shadow の適用 | `lq`, `sb` | arch (ld_st)、boot | |
| rename walk (回数、サイクル)、walk 中に捨てた resolve | `rename` | boot | walk 中の kill の扱い (設計書 §5.4 T9)、`NUM_CKPT` |
| checkpoint pool 枯渇からの walk fallback (M3 から、`ren.ck_none`) | `rename` | boot で 0 より大 (設計書 §3.3)。M3 で W2 と W4 の boot の両方で発火 | |
| commit 時 REPLAY (順序違反) | `lq` | 順序違反の directed (§7.4)、SMP boot | |
| HOLE_FILL の待ち (DIV、FDIV、io、atomic) | `wb_resv` | rv64um div、rv64ud fdiv、boot | |
| PTW の walk、TLB miss、epoch 不一致による install の破棄 | `ptw`, `tlb` | boot。epoch は walk 中に full kill をかける directed | port 0 のクラス別占有 (設計書 §5.9 の D-PTW) |
| IO load、IO store、NC load の件数 | `io_unit`, `lq` | boot (UART、CLINT)、svpbmt | NC load の投機発行 (設計書 §5.14) |
| CSR 書き込み後 flush の件数とそのコスト | `commit` | boot、bench | 白リスト化 (設計書 §5.5 の 1 % 規則) |
| misaligned の分割、page またぎの分割 | `mem_pipe` | ma_data、ACT4 Misalign、§7.4 | |
| atomic: LR、SC 成功/失敗、AMO | `atomic_unit` | rv64ua、boot | |
| `mem_port_arb` の最大待ちサイクル | `mem_port_arb` | 上限 B (設計書 §5.9 MP4) を超えない | |
| (MD) Debug Mode の入場 (原因ごと)、Debug Mode 中の ebreak と例外、dret、step の完了、`dm_req` の待ち | `commit`、`csr` (`CorePerf.dbg`) | `dbg` (GD/GD4 のログ)、`gdb` (GG) | |
| (MD) trigger の照合 (execute、load、store) と受付 (action ごと)、icount の発火、照合したが kill された op | `ifu`/`extract`、`mem_pipe`、`trig_unit` | `dbg`。kill された一致は wrong path に trigger の番地を置く directed で 0 より大 | `TRIG_N` と照合機能の範囲 (U34) |
| (MD) DMI アクセス、abstract command と cmderr、SBA と sberror、group の伝播、ndmreset と hartreset、hartreset の quiesce | `dm`、`dm_sba` (`o_dm_obs`)、core | `dbg`、`gdb` | |

上表のうち、M2 末の `CorePerf` に無いもの: RETRY の WB_BLOCKED (adapter の perf に無い。M3 の dcache はこの理由を出さないので、構造的に 0)、drain shadow の適用 (shadow のハードウェアが無い、設計書 U8)、NC load の件数、page またぎの分割 (`mp.split` は line 跨ぎだけを数える)、`mem_port_arb` の最大待ちサイクル (カウンタでなく最大値で、`o_perf` に出ていない)、CSR 書き込み後 flush のコスト (件数 `cm.rf_serial` だけ)。checkpoint pool の枯渇は M3 で `ren.ck_none` として入った。

M3 で `CorePerf` に足したもの (手順ごと。`fire_check.py` は struct 定義から名前と幅を復元するので、表の変更は要らない):

- 手順 4: `dc.*` (`DcachePerf`: accept、hit、crit_hit、attach、alloc、RETRY の理由別 `r_fill_busy`/`r_inv_race`/`r_preempted`/`r_bank`、`share`、`huf`、`launch`、`vic_wb`、排他の pass/fail/busy、`nf_busy`、`unc_done`、`wt_done`、`cmo`、drain の merge/wt/rfo/bank、probe の ack/wb/defer、`ev_skid` など) と `dtlb.lk2` (2 ポート以上の同時 lookup)。
- 手順 5: `sq.sta_multi`、`sq.fwd_multi`、`sq.ret_multi`、`lq.scan_multi`、`sb.push_multi`、`sb.merge_same` (設計書 §L.20)。checker は `chk_sq` bit 4。
- 手順 6: `ren.ck_alloc`、`ren.ck_restore`、`ren.ck_none`、`disp.cut_ck`、`iss[p]` (exec ポート p が op を受理したサイクル。`ep[p]` は「source が bypass の値を取った」で、ポートの使用率ではない)。checker は `chk_rename` bit 2 と bit 3 (設計書 §R.3.5)。
- M3 の末: `mp.ewake` (`MemPipePerf.ewake`、load の pass が dcache の V 段の HIT か全 forward で consumer を起こした。設計書 §L.2)。matrix の default の行。
- matrix に足した行: `dc.*` と `dtlb.lk2` (手順 4)、手順 5 の 6 本 (default)、`ren.ck_alloc`/`ck_restore` (default)、`ren.ck_none` (boot)、`disp.cut_ck` (default)、`iss` (default)。手順 2 の W4 の `--zero` (どのログでも 0): `disp.cut_int`/`cut_fp`、`iq[1].tok_wait`、DIV と FDIV 以外のポートの `rs[*].hf_*`、`ad.empty_gen`/`excl_fail`/`ev_skid`、`dtlb`/`itlb.fill_inv`、`ptw_i.full`/`d_wr`、`at.fail`/`watch`/`backoff`、`io.retry` (`ad.*` は手順 4 で adapter とともに消えた)。

---

## 6. シミュレーション速度計画

### 6.1 現状の数値 (旧コア、`.build/test_timings`、5.15 boot)

| harts | 実行時間 | cycles | cy/s | hart-cycle あたり |
|---|---|---|---|---|
| N1 | 145.2 s | 12.2M | 84.0k | 84.0k |
| N2 | 448.7 s | 16.4M | 36.5k | 73.1k |
| N4 | 3793.2 s | 25.2M | 6.64k | 26.6k |
| N8 | 15216.2 s | 36.6M | 2.41k | 19.2k |

N4 の値は `.build/test_timings` のもので、CLAUDE.md にあった 4408 s は 2026-08-05 に別の実行で測った壁時間である (設計書 D7 の 4408 s はこちら)。どちらも測定条件 (`VERYL_AOT_C_ASYNC` の設定、並行実行の有無) が記録されていないので、§6.3 の matched 測定で置き換える。2026-06-11 に同じ木で直列に測った値は N1/N2/N4 で 251k/118k/50.6k cy/s であり、ほぼ線形だった。N=4 の段差 (hart-cycle あたり約 2.7 倍) はその後に現れた。CLAUDE.md の「N=1 約 1 分、N=2 約 3 分」は外挿値で、実測では約 2.4 分と約 7.5 分である。旧コアの梯子 (litmus4 523 s + N2 449 s + N4 3793 s + hv 243 s) は直列で約 83 分で、そのうち N4 boot が 76 % を占める。Verilator の N4 boot は約 11k cy/s で、native の約 1.6 倍速い、としていた。【訂正】(M3 の手順 1) matched に測ると、V14 の N4 boot は Verilator 4.66k cy/s、native 6.92k cy/s (どちらも CPU 時間で割った値) で、Verilator の方が遅い (§6.3)。1.6 倍は測定条件の違う値どうしを比べたものだった。

### 6.2 測定の規約と記録

- 【決定】速度は `VERYL_AOT_C_ASYNC=0` で、直列に、同じ木と同じマシンで測る。他の重い実行と重ねない。理由: 非同期の cc ビルド中は Cranelift で走るので、短い run は cc の速度を測っていない。また過去の数値は日付のない値や外挿値が混ざって誤っていた。
- 【決定】(M3) cy/s は壁時間ではなく、そのプロセスの CPU 時間 (user) か `perf stat` のホストのサイクル数で割って求める。CPU は固定するなら空いているコアを選ぶ (他の作業と同じコアに固定しない)。理由: マシンは共有で、壁時間は他の負荷で大きく伸びる。CPU 時間でも、同時に走る負荷による L2 の取り合い (§6.3) で揺れるので、2 つの構成を比べるときは同じ時間帯に同時に走らせた対を使う。
- 【決定】各マイルストーンの末に次の表へ 1 行ずつ追記する。対象は 5.15 N=1 boot (W2/W4)、dhrystone (W2/W4)、既定スイートの壁時間、梯子全体の壁時間、M4 からは N=4 boot である。

| マイルストーン | 構成 | 対象 | cycles | 実行時間 | cy/s | whole-comb / event の fallback | 木の commit | veryl の commit |
|---|---|---|---|---|---|---|---|---|
| M0 基準 | 旧コア | 5.15 N=1 boot | 12.2M | 145.2 s | 84.0k | 未測定 (§6.4 の S1) | b0f4668 | fbd14729 |
| M1b | W2 | rv64ui ld_st (boot は M1b では走らない。arch テストで代用) | 5,347 (settle 6,005) | 2.335 s | 2.57k | 0 / 0 (設計のコード。tb の `$display` 5 文だけが残る) | 7f425c7 | 2c63092a |
| M1b | W4 | rv64ui ld_st (同上) | 7,386 (settle 8,004) | 24.138 s | 0.33k | Clock event の 2 つの `If` の木 (94,241 文と 56,545 文) が AOT-C の 1 文の上限 16 MiB を超えて decline。dataflow は 0 | 7f425c7 | 2c63092a |
| M2 | W2 | rv64ui ld_st | 5,347 (settle 6,005) | 0.181 s | 33.3k | 0 / 0 (Clock event も whole-AOT) | fa4cfa9 | 4a48677b |
| M2 | W2 | 5.15 N=1 boot (pass/fail、`MTIME_SRC=CYCLE`) | 16,433,955 | 464.3 s | 35.4k | 0 / 0 | fa4cfa9 | 4a48677b |
| M2 | W2 | 5.15 N=1 boot (lockstep、`INSTRET`) | 16,360,435 | 484.6 s | 33.8k | 0 / 0 | fa4cfa9 | 4a48677b |
| M2 | W2 | 6.6 / 7.1 N=1 boot | 21,940,363 / 20,691,107 | 637.4 s / 585.0 s | 34.4k / 35.4k | 0 / 0 | fa4cfa9 | 4a48677b |
| M2 | W4 | rv64ui ld_st | 7,386 (settle 8,004) | 3.481 s | 2.30k | M1b と同じ 2 つの `If` の木が decline。dataflow の fallback 0 | fa4cfa9 | 4a48677b |
| M2 | W4 | rv64ui ld_st (veryl の大きな event の分割後) | 同上 | — | 3.4k | decline 0 (Clock event が whole-AOT) | fa4cfa9 | dd72276c |
| M2 | V14 + 新コア | 既定スイート 850 本 / 梯子全体 (既定、bench、N=1、litmus4、N=2、hvlinux、W2 lockstep boot、ACT4 W2、N=4 を直列) | | 2,547 s / 9,311 s | | | 4fec4e4 | 4a48677b |
| M3 (手順 1) | V14 | 5.15 boot、N=1 / N=2 / N=4 (matched、CPU 時間) | 12.2M / 16.4M / 25.2M | | 約 84k / 40.1k / 6.92k | | | |
| M3 (手順 1) | V14 | 5.15 N=4 boot、Verilator (CPU 時間) | 25.2M | | 4.66k | | | |
| M3 (手順 2) | W4 | arch (1 CPU に固定、直列) | | | 5.1k | fallback 0 | 64fea45 | dd72276c |
| M3 (手順 2) | W4 | 5.15 / 6.6 / 7.1 N=1 boot (4 本を並行、負荷下) | 13.4M / 18.5M / 18.0M | | 3.6k-4.4k | whole_event 2-11 %、dataflow 7-24 % | 64fea45 | dd72276c |
| M3 (手順 2) | W4 | ACT4 (並行) | | | 1.1k | dataflow は 0 本で成立、whole_event はほぼ全部 fallback | 64fea45 | dd72276c |
| M3 (手順 2) | W4 | 5.15 N=1 boot、Verilator | 13.4M | 1,869 s | 7.2k | | 64fea45 | |
| M3 (末) | W2 | 5.15 N=1 boot GL-B / pass/fail、6.6、7.1 (3-4 本を並行、user 時間で build を含む) | 14.4M / 14.5M / 20.7M / 19.3M | | 5.8k / 6.2k / 6.1k / 6.1k | | 087a7d1 | |
| M3 (末) | W4 | 同上 | 11.8M / 11.8M / 17.2M / 16.5M | | 1.69k / 1.68k / 1.87k / 1.87k | | 087a7d1 | |
| M3 (末) | W2 / W4 | arch rv64ui 108 本 (1 コアに固定、`sim_s` の合計) | | | 5.5k / 1.7k | degraded modules W2 162 / W4 215 | 087a7d1 | |
| M3 (末) | W2 / W4 | 5.15 N=1 boot、Verilator 5.050 `-O3` | 14.5M / 11.8M | | 22.6k / 8.1k | | 087a7d1 | |

M3 の行の補足: W2 の boot は手順 2 の時点で fallback 0 のまま。W4 の boot と ACT4 に残る whole_event と dataflow の fallback は、M3 末の GS で原因を見る。手順 6 の `NUM_CKPT` の対では、同時に走らせた W2 の 5.15 boot の CPU 時間が 0 で 2,327 s、4 で 2,481 s (+6.6 %)、2 で 2,336 s、8 で 2,510 s だった。checkpoint を lane ごとに持つ最初の形は、W4 の `NUM_CKPT=8` で同時実行の進みが約 1/2-1/3 に落ちた (設計書 §R.3.5)。

M3 の末の行の補足: 記録だけで、速度の結論には使わない。boot の cy/s は 3-4 本を並行に走らせた user 時間 (build を含む) で割った値で、手順 2 の W4 の値 (3.6k-4.4k、条件が違う) とは直接比べられない。arch の行は小さいテストが多く初期化が支配するので、boot より低く出る。degraded modules の数は veryl の診断出力の値をそのまま記した。手順 6 の補足で「M3 末の GS で原因を見る」とした W4 の whole_event と dataflow の fallback は、M3 ではまだ原因を見ていない。

M2 の行の補足: 測定は `VERYL_AOT_C_ASYNC=0`、`taskset -c 3` で 1 本ずつ直列、perf_acc 込みの harness。cy/s は settle 数 / `sim_s`。5.15 N=1 boot と dhrystone の W4、dhrystone の W2 はまだ走らせていない (新コアの bench harness と W4 の boot テストが無い)。梯子の行は master の M2 末の梯子 (`logs/summary.txt` の壁時間の合計、うち N=4 boot 3,791 s) で、GS の測定条件 (直列・単独) は守っているが CPU の固定はしていない。
- W2: M1b の 2.5k cy/s から約 13 倍。M1b では tb の `$display` のために Clock event が whole-AOT にならなかったが、M2 では whole-AOT になった (下の veryl の修正)。旧コアの N=1 boot (84.0k cy/s、§6.1) の約 0.42 倍。Verilator (1 thread、HELIODOR_CHK なし) の W2 5.15 boot は 12.6k cy/s (1,308 s) で native の約 1/2.8。
- M2 で入れた veryl の修正 (いずれも clone の `local/heliodor-fixes`): `fix/aot-print-wide-args` (AOT-C の event が幅の広い引数の `$display` で decline しない)、`fix/comb-hoist-sink-to-reader` (hoist した let を読む always_ff の分岐の中で評価する)、`fix/aot-lock-owner-namespace` (§6.2 の注の lock の不具合)、`fix/dataflow-coarse-cap` (粗粒度化の上限、§6.3)、`fix/aot-c-split-big-if` (大きな event の block を別の AOT-C 関数に切り出す。`dd72276c`)。
- W4: M1b と同じ Clock event の 2 つの `If` の木 (94,241 / 56,545 文、33.5 MB / 20.1 MB) が 16 MiB の上限を超えて全テストで decline し、W2 の約 1/15 だった。加えて `[dataflow] fallback marking commit` が 128-256 回出る (W2 は 0)。木の発生源は `prf.veryl:54-64` の書き込みループで、`tree_onehot_mux` (`tree_pkg.veryl:91`、`:93`) がエントリごと・ビットごとに展開されている。`fix/aot-c-split-big-if` で decline は 0 になり 2.2k から 3.4k cy/s に上がったが、W2 との差はまだ約 10 倍残る。残りは comb の settle (W4 105-205 us 対 W2 14-23 us) で、同じ bit 転置の `tree_*` helper が comb にもあるためと推定する。M3 の最初に、`tree_onehot_mux`/`tree_enc` を語幅の AND-OR に書き換える RTL 側の変更として扱う (設計書の M2 の完了)。W4 の Clock の `.so` の cold compile は単一の翻訳単位で約 10 分かかる。

M1b の行の補足: cy/s は settle 数 / `sim_s` (build を除く)。W4 は ma_data で 220、sd で 210 cy/s で、W2 (2.5k 前後) の約 8-12 倍遅い。`VERYL_AOT_C_MAX_STMT_MB=64` で decline を無くすと、W4 はさらに遅くなる (ld_st 196、ma_data 190 cy/s) ので、上限は W4 の遅さの原因ではない。54 本を並行に流した batch の W4 で dataflow が全 settle で fallback したのは、AOT-C の compile lock が残っていたための失敗で再現しない (下の注)。どちらの数値も arch harness のもので、旧コアの boot の 84k cy/s とは比べられない。

注 (veryl の不具合): `~/.cache/veryl/aot_c/` に、途中で終わった run が残した `.so` の無い `.lock` が溜まると、待つ側が持ち主を生きていると誤認して止まる (sandbox の各起動は別の PID 名前空間で、死んだ持ち主の pid が別のプロセスを指す。pid が記録されていると 600 s の年齢規則が効かない)。clone 側で直す。それまでは古い lock を退避すれば進む。

### 6.3 N=4 の段差の調査 (D7、M3 の最初の作業)

1. S3-1: V14 で (新コアの SMP は M4 から)、同じ木、同じマシンで、5.15 boot の先頭 5M サイクルを N=1/2/4 の順に直列で走らせる (`VERYL_AOT_C_ASYNC=0`)。`--features profile` でビルドした veryl (`release-verylup-prof`) で、SimProfile の settle/comb/event の ns を SoC サイクルあたりに直す。段差が comb、event、settle のどこにあるかを見る。
2. S3-2: 同じ slice を Verilator でも測る。Verilator にも段差が出るなら設計とホストのキャッシュ容量の問題、出ないなら veryl 固有の問題と切り分ける。
3. S3-3: 仮説を 1 つずつ潰す。(a) 設計の肥大: hart-cycle あたりのコストが N によらず一定かを見る。(b) ホストのキャッシュ容量: `perf stat` で LLC miss を N=2 と N=4 で比べる。(c) N=4 でだけ whole-comb か whole-event が bail している: N ごとに `VERYL_AOT_C_DIAG=1 VERYL_AOT_C_EVENT_DIAG=1` を見る。(d) 生成 C の関数が巨大になる影響: `.so` のサイズと命令キャッシュ miss を N ごとに比べる。
4. S3-4: 原因が veryl にあれば clone 側で直し (プロジェクト規則)、同じ slice で再測定する。結論 (2026-10-15): 段差の原因は、veryl の dataflow の粗粒度化の上限 `DATAFLOW_COARSE_MAX_STMTS` に N=4 の設計が掛かることだと特定した。veryl の clone 側で修正中で、修正後に同じ slice で再測定する。修正は M2 中に `fix/dataflow-coarse-cap` として `local/heliodor-fixes` (`4a48677b`) に入った。同じ slice の matched な再測定はまだで、M3 の最初に行う。参考: この veryl で回した M2 末の梯子の V14 N=4 boot は 3,791 s で、§6.1 の 3,793 s とほぼ同じだった (matched な条件ではない)。

   【訂正】(M3 の手順 1、2026-10-16) 修正後の veryl で matched に測り直すと段差は残り、上の結論は誤りだった。V14 の 5.15 boot (CPU 時間で割った cy/s) は N=1 約 84k、N=2 40.1k、N=4 6.92k で、hart-cycle あたり N=1 から N=2 は平ら、N=4 で約 2.9 倍の段差がある。Verilator の N=4 は 4.66k cy/s で、native より遅い。原因は (b) のホストのキャッシュ容量で、生成コードがホストの L2 (1 コアあたり 2 MB) に収まらない。veryl は hart の instance ごとに生成コードの複製を持つので、N=4 でコードが L2 を溢れる。veryl のバグではないので clone では直さない。instance 間でコードを共有すれば N=4 で約 3 倍の見込みがあり、veryl のロードマップ項目とする。
5. N=4 boot ゲートを両構成で回すかどうか (M3 で決めた。決定は下の 6.、M4 から適用する)。新コアの N=4 boot は M4 まで存在しないので、S3 の後の V14 の N=4 boot の壁時間に、W2/W4 と V14 の N=1 boot の cy/s の比を掛けて W2 と W4 の値を見積もる。M4 で実測し、見積もりと大きく違えば見直す。両構成の梯子が直列で約 4 時間以内に収まるなら両方で回す。収まらなければ、メモリ系の変更ごとに W4 だけで回し、W2 はマイルストーン末だけにする。Verilator を N=4 のゲートエンジンにする案 (約 1.6 倍速いとしていたが、実測では native より遅かった。`-O1 -j 2` が必要) もこのときに比べる。
6. 【決定】(M3 の手順 1、U1 と U2。M4 から適用) 見積もり: 新コアの N=4 boot は、W2 が静かなマシンで約 3 時間、負荷下で 5-6 時間、W4 が 4-14 時間。両構成の梯子は 4 時間に収まらないので、次のように回す。W2 の N=4 boot (GB4) をメモリ系の変更ごとのゲートにする。litmus N=4 (GT4) は両構成で回す。W4 の N=4 boot はマイルストーンの末に夜間に回す。Verilator は N=4 の判定に使わず (native より遅い)、マイルストーン末の NBA の相互確認 (GV、`-O1 -j 2`) にだけ使う。M4 で新コアの N=4 boot を実測し、見積もりと大きく違えば見直す。

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
| Zicntr | rv64mi zicntr、instret_overflow | Zicntr 2 | | minstret = popcount (設計書 §5.12 C8)。ACT4 Zicntr は INSTRET モードで走らせるが、カウンタの値から計算するので GA だけで判定する (M2 の決定、付録 B の B15) |
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

M2 末 (2026-10-16) の状態: 上表の既定スイートと ACT4 の列はすべてゲートに入り、ACT4 は W2 で 696/696 pass、GL-C の対象 690 本が hash 一致 (Zabha、Zacas、Svadu/SvaduPMP、Svpbmt を含む)。boot の列は 5.15 (lockstep)、6.6、7.1 が W2 で pass。証明が揃っていない行:

| 行 | 足りないもの |
|---|---|
| Zkt | FU 契約のレビュー (対象 op のレイテンシがデータに依存しないこと) をまだしていない |
| Zicntr | ACT4 は GA だけ (上の注記)。lockstep で守られるのはカウンタの読み出しの位置だけ |
| Zihpm、Sscofpmf | event 5 (memory port busy) の再定義が adapter の受理と一致するかを確かめていない |
| misaligned load/store | ACT4 の `MISALIGNED_MAX_ATOMICITY_GRANULE_SIZE` はまだ 4096 (`test/act/config/heliodor/heliodor.yaml`)。64 に下げる作業 (設計書 §5.9 MP5) は M3 に繰り越す |
| Smpmp | Verilator の `tb_act_pmps_cfg_xwr.sv` での確認 (GV) をしていない |
| Zicsr | rv64mi/illegal は pass/fail だけ (割込みの位置)。CSR の存在表に golden が 0 を読ませる CSR を含めること (B31) を、表として明示的には照合していない |

### 7.2 M4 (SMP)

RVWMO (litmus N=2/4/8)、remote invalidate による reservation の消去、atomic の line 所有、Zawrs と Svinval の SMP 下の動作 (7.1 SMP boot)、PLIC claim の競合 (§8 の directed)。

M4 の directed (手順 2、3、7): `test/coh/coh.S` (`tb/test_smp_coh.veryl`)、`ad.S` (A/D の owned RMW。変更前の RTL で失敗)、`unc.S` (uncached 読みの recall。変更前の RTL で失敗)。穴: hart ごとの `chk_io_mon` が無く、PLIC の read 回数は間接的にしか検査していない。CoRR の発火は間接で、B05 の `SC_REPLAY` の probe は未作成。7.1 の boot は HW の A/D 更新を通らない (Linux は A=D=1 の PTE を作る) ので、A/D は `ad.S` が唯一の検査である。SBA の書き込み側の recall は MD で検査する。旧コアでは N=1 のビット一致が N=4 boot の正しさを含意しなかったので、メモリ系の変更には GB4 を必須とする (§1.3)。

### 7.3 M5 (H/V)

| 機能 | 既定スイート | boot | 注記 |
|---|---|---|---|
| H | htwostage、hvstrap、hvirq、hgpf、hgpfns、higpf、hlv、hvinst、hconf、hmtval2、hvscsr、hvtvm、hvsirq、hsstc、hmini、hvtiny、hvtmr (17 本) | hvlinux | ACT4 に H は無い。golden 側の V=1 の誤り (B11、B23、B25、B40) があるので golden lockstep はしない。GX で W2 と W4 を突き合わせる |
| V | test_arch_vadd ... vfarith (20 本)、test_vmspre | 7.1v N=1 | ACT4 に V は無い。VRF への書き込みは retire record の `vrf_wcnt`/`vrf_hash` に入るので (設計書 §5.12、§V.7)、W2/W4 の GX で vector の結果を突き合わせられる。golden も D1 パッチの最初の版から同じフィールドを出すので、V テストで最初に食い違う vector op の局所化 (設計書 §V.11) にも使える。VU の上限の修正または宣言 (設計書 §3.4) |

### 7.4 新規 directed test (自己検査型)

【決定】付録 B で golden の誤りと分かっている振る舞いと、golden lockstep で守れない規則には、`test/directed/` に自己検査型のテストを置く。tohost は、仕様どおりの振る舞いなら 1、golden の誤りと同じ振る舞いなら付録 B の番号を符号化した専用の値 (`0xB000 + 番号`) を書く。golden 上で走らせて誤りを確認する (D4) のと、新コアのゲートに入れるのを同じプログラムで済ませるためである。対象: B03、B04、B05、B07、B10、B12、B19、B21、B22、B24、B26、B28、B30、B35、B36、B46、B49-B54 (付録 B の各行の probe 列。B46 は UART THR への書き込み回数を数える)。順序違反の commit 時 REPLAY、walk 中の full kill による epoch 破棄、SC 失敗時の書き込み権限での翻訳、Supm の Sv39/U-mode 版、§8 の IO 系 directed もここに置く。

golden 上の probe は作成済みで、branch `golden/probes` にある (ソースは `test/directed/`、Veryl の test は `tb/test_golden_probe.veryl`)。tohost の符号化は、1 が仕様どおり、`0xB000 + n` が Bn の誤りを観測 (n は付録 B の行番号の 10 進値、bit [23:16] は sub-case か観測した変種のマスク)、`0xE000 + x` が判定不能である。走らせた probe は上の対象に B13、B14、B17、B20、B27、B39 を加えた 22 本で、結果は付録 B の各行の状態と probe 列に書いた。B10 の probe からは新しい行 B47 (fault する store がデータを書く) が見つかった。B48 (riscv-tests の env が書く mnstatus) は probe ではなく M1b の decode の実装で見つかった。B49-B54 (FP の変換の誤り) は、M2 の準備で FP の FU を `fpu_wrap` から移植したときに見つかり、同じ branch に足した 6 本の probe (`b49_fcvt_l_d` から `b54_fcvt_tininess`) で全部確定した。probe の期待値は Sail で確かめた。

- 再現せず: B20、B21 (pmpcfg)、B36 の Svinval 部分、B39 の ASQ の順序。どれも扱いは STOP か OUT のまま残す。
- 判定不能: B05。N=1 では自分の eviction でしか poison が起きず、掃引 2 通りで `SC_REPLAY` は 0 だった。M4 で remote の inv で poison する SMP の probe を足す。
- 未 probe: B23、B25、B40 は H/V なので M5 で作る。B33 は OUT (7.1 は pass/fail) なので probe は要らない。

M2 末の新コア側: 付録 B の probe 27 本 (`m2_probe_pf.list` の 15 本と `m2_fp_pf.list` の 12 本。b39 は vector なので M5) は W2/W4 ですべて tohost=1。b46_uart は SoC の param `UART_WRCNT` (UART + 0x100 の読み出しが device 側の UART 書き込み回数を返す) で回数を読む。M2 で足した directed:

| テスト | 確かめること | ゲート |
|---|---|---|
| `ld_replay` | 古い store のアドレスが遅れて決まり、若い load が先に走る (順序違反と commit 時 REPLAY) | W2 lockstep、W4 PF |
| `supm_vm` | Supm の pointer masking を Sv39 の S-mode と U-mode で | W2 lockstep、W4 PF |
| `sc_wperm` | SC は成否によらず store 権限で翻訳する: 書けないページへの SC は reservation の有無によらず cause 15 で、何も書かない | PF (golden は失敗する SC の store 権限の検査を飛ばす。付録 B の B58) |
| `io_access`、`io_plic` | §8 の IO 系 (§8 の表) | PF (`m2_io_pf.list`) |
| `svadu_amo` | ADUE=1 で AMO と oldest でない store が D を立てる経路 | PF (`m2_mmu_pf.list`) |

未作成: walk 中の full kill による epoch 破棄 (PTW の遅延を伸ばす仕掛けが要る)、PLIC claim の競合 (M4、§8)、PAUSE が drain しないこと。

### 7.5 MD (デバッグ、設計書 §D)

証明の担い手: GD (N=1 の debug directed)、GD4 (N=4)、GG (riscv-tests の debug suite、spike を参照)。テスト名は §9.1 の表。

| 機能 | GD | GD4 | GG | 注記 |
|---|---|---|---|---|
| haltreq による halt と resume、resumeack、dpc | dm_halt_resume | dm_smp_select | 全テストの前提 | dpc が次に実行する命令の pc であること。割込みが pending でも halt が先 |
| ebreak (ebreakm/s/u) と software breakpoint | dm_ebreak | | software breakpoint の系 | ebreakX=0 なら通常の breakpoint 例外 (tval = epc) |
| single step (stepie 0/1、trap する命令、割込み、CSR 書き込みと IO の op) | dm_step | | step の系 | 1 record ごとに入場すること、trap したらハンドラの先頭で止まること |
| dcsr/dpc/dscratch と DRET の合法性 | dm_dcsr | | | Debug Mode の外では不正命令 (cause 2) |
| Debug Mode 中の例外と ebreak | dm_exc | | | cmderr = 3。mcause/mepc/mtval が変わらないこと |
| Access Register (GPR、FPR、CSR。aarsize 2/3、transfer、write、postexec) | dm_abs_gpr、dm_abs_fpr_csr | | register の系 | s0/s1 の値が hart の値であること。FS=Off の FPR は cmderr = 3。aarpostincrement は cmderr = 2 |
| progbuf の実行と abstractauto | dm_progbuf | | メモリ (MemTest*) の系 | progbuf が hart の GPR を見ること、impebreak |
| stopcount、stoptime | dm_counters | dm_smp_stoptime | | N=1 は halt 中に mcycle/minstret/mtime が止まる。N=4 は全 hart が止まったときだけ mtime が止まる |
| trigger: execute (match 0-3、chain) | dm_trig_exec | | hardware breakpoint (Hwbp*) | block の境界をまたぐ範囲、RVC と 32 bit の命令 |
| trigger: load/store (line 内の misaligned、line 跨ぎ、AMO、LR/SC、IO の load と store) | dm_trig_ldst | | watchpoint と Trigger* の系 | before: 一致した store がメモリに残らず、IO load が device に届かない (`chk_io_mon`) |
| trigger が wrong path で止めない | dm_trig_wrongpath | | | mispredict の影の命令と load に一致させ、入場が 0 回、照合したが kill された数が 0 より大 |
| trigger: action=0 (tval、tcontrol の mte/mpte) と icount | dm_trig_action0、dm_icount | | | M のハンドラで再入しないこと、icount の境界が group の途中に来ないこと |
| hit bit | dm_trig_exec、dm_trig_ldst | | | 受け付けた trigger だけが立つ |
| SBA (sbaccess 8-64、autoincrement、readonaddr/readondata、sbbusyerror、sberror) | dm_sba | | DownloadTest、メモリの系 | hole と DM 領域は sberror = 2 |
| SBA の一貫性 (他 hart の dirty line、書き込みの後の sharer) | | dm_smp_sba_coh | | 他 hart が書いた dirty line を SBA が最新の値で読む。SBA の書き込みの後、他 hart の load が新しい値を見る |
| SBA で書き換えたコードの実行 | dm_sba_code | | software breakpoint の系 | resume の `fence.i` で新しい命令を実行する |
| hart の選択、hasel/hawindow、haltsum0、nonexistent | | dm_smp_select | hart の切替の系 | |
| halt group と resume group | | dm_smp_group | | 1 hart の trigger で group 全体が止まる |
| ndmreset、hartreset、havereset/ackhavereset、resethaltreq、dmactive | dm_reset | dm_smp_hartreset | reset の系 | hartreset の間も他 hart が走り続け、共有データの一貫性が保たれる (U32) |
| PMP と PMA の免除 | dm_pmp_lock | | | lock した PMP が DM 領域を覆っても debug でき、Debug Mode の外の DM 領域へのアクセスは fault |
| DMI idle の等価 | §9.3 | | | GL-B と bench のビット一致 |

H/V との相互作用 (M5): VS/VU からの入場と dret (dcsr.v、prv)、ebreakvs/vu、mcontrol6 の vs/vu、HLV/HSV と vector の要素アクセスの trigger。§7.3 の H/V の directed と同じ扱いで G0 に足す。

---

## 8. SoC 側の IO モニタ (設計書 §5.14)

【決定】観測専用の `chk_io_mon` を hart ごとに置き、sticky flag を合否に畳み込む (M2 の実装は下の「実装」のとおり tb 側)。V14 では使わない (V14 には retire port が無く、IO store の重複書き込みが推定されている)。

- 観測するもの: (1) device 側。`PMA_REGIONS` で `io_ordered=1` の領域 (CLINT、PLIC、UART) への読み書きの enable と、それを出した hart (memory_bus の grant から求める)、アドレス、方向、store のデータと strobe。(2) コア側。その hart の retire record のうち `mem_io=1` のもの。
- 照合規則: IO 操作は oldest token でしか始まらず、IO store は non-posted なので (設計書 §5.14)、hart ごとの未照合の device アクセスは常に 0 個か 1 個である。device アクセスを 1 段のレジスタに保持し、次の `mem_io` record とアドレス、方向、(store なら) データと strobe で照合する。2 つ目の device アクセスが照合の前に来たら DUP、保持が空のまま `mem_io` record が来たら MISSING、テストの終わりに保持が残っていれば ORPHAN (wrong-path や kill 後のアクセス) とする。
- device アクセスは必ず record より先に起こる (IO load は応答を LQ で受けてから retire し、IO store は WT_DONE を受けてから retire する)。逆順は ORDER 違反とする。
- AMO、LR/SC、misaligned、fetch、PTE の読み出しで IO 領域に触れると、翻訳時にアクセス fault になり device には何も届かない。届いたら ORPHAN として現れる。

実装 (M2): 上の規則は SoC の中ではなく tb モジュール `chk_io_mon` (`tb/chk_io_mon.veryl`、hart ごと) に置いた。SoC は観測だけを出す: `o_io_obs[2]` (`soc_pkg::IoObs {valid, write, hart, addr, data, strb}`。[0] が device の読み、[1] が書き込みで、CLINT/PLIC/UART の enable、grant された hart、アドレス、読みデータか書きデータと strobe)。`o_chk_io` という SoC のポートは作らなかった。理由: 照合の相手の retire record は harness が持っており、SoC に checker を置くと SoC が `retire_pkg` と PMA の照合に依存する。
- `chk_io_mon` は record のうち `mem_io=1` で、`PMA_REGIONS` が `io_ordered=1` とする領域へのものだけを数える (DRAM 内の Svpbmt IO ページは device に届かない)。flag は 4 bit: DUP、MISSING (逆順を含む)、DIFF (保持したアクセスと record の方向・アドレス・バイトが違う)、ORPHAN (終端 record のサイクルに保持が残っている)。新コアの arch harness (`arch_soc_harness`) と smode_plic が instantiate し、flag は `o_pass`/`o_fail` に畳み込む。boot の harness には入れていない。
- SoC の付随する変更 (新コア枝だけ): UART の読みデータを offset の byte lane に置き、書きデータを offset の byte lane から取る (V14 枝は下位 byte 固定の旧い振る舞いのまま)。param `UART_WRCNT` で UART + 0x100 の読み出しが device 側の UART 書き込み回数を返す (b46_uart 用)。

上表の M2 での担い手: PLIC claim の読み出し回数は smode_plic と `io_plic` の `chk_io_mon`、wrong-path の claim と古い store の後ろの claim は `io_plic`、IO store から IO load、misaligned/AMO/LR の IO アクセス、IO 領域からの fetch、LSR の byte lane は `io_access`、UART の送信回数は b46_uart (W2/W4 で tohost=1)。claim の競合は M4。

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

## 9. デバッグの検証 (MD、設計書 §D)

### 9.1 native の directed: DMI script の player (GD、GD4)

【決定】debug の主ゲートは native シミュレーションの directed とし、tb が APB の DMI ポートを直接駆動する。理由: OpenOCD と JTAG を通さずに済むので速く、tb の外のツールの版に依存しない。spec の DM の振る舞いは DMI のレジスタの読み書きの列として書けるので、script で表せる。

- `dm_seq` (tb のモジュール) は script の hex (tb の `$readmemh`) を 1 命令ずつ実行し、APB の transfer を 1 つずつ出す。命令は `WR addr data`、`RD addr expect mask` (一致しなければ fail の bit を立てる)、`POLL addr mask value timeout`、`WAIT n`、`MARK id` (ログに印字)、`END`。
- hart は同じ harness の DRAM で小さな program (hex) を走らせる。program は自分の結果を tohost に書いてもよい。合否は「script が END に達し、CHECK の不一致が 0、`chk_debug` と `chk_dm` が 0、program が tohost を書くなら tohost == 1」。
- script の源は人が読める `test/debug/dmi/*.dmi` で、`make -C test/debug` が hex を作る (hex は他の hex と同じく gitignore)。program は `test/debug/prog/*.S` で、同じ `make` で作る。
- 【決定】期待値の出所: 各 CHECK に、spec の節か設計書 §D の節をコメントで付ける。DM の実装に依存しない CHECK (halted、cmderr、data の値、sberror) は、同じ `.dmi` を OpenOCD の `riscv dmi_read`/`riscv dmi_write` で spike の DM に流す driver (`test/debug/dmi/run_spike.py`) でも確かめる。理由: script の期待値を自分の実装から写すと、spec の読み違いが両側にそろって見えなくなる。spike は gdbserver の参照と同じ版 (U36) を使う。
- 生成ラッパとゲートリスト: `test/gates/md_dbg.list` (N=1、G0) と `test/gates/md_dbg4.list` (N=4、`--ignored`) から `gen_core_tests.py` が `tb/test_w{2,4}_dbg.veryl` と `tb/test_w{2,4}_dbg4.veryl` を作る (§2.5 の 1 suite 1 リストの規則)。

| テスト | N | 確かめること |
|---|---|---|
| dm_halt_resume | 1 | haltreq、resumereq、dmstatus (allhalted/allrunning/allresumeack)、dpc、割込みが pending のときの halt、ROB が空でない状態からの halt、started の op (IO、AMO) の完了を待つ halt、halted の後も haltreq を下ろさない間に abstract command と progbuf が進む (`dm_req` が `!debug_mode` を含む、設計書 §D.4 の M4-3) |
| dm_ebreak | 1 | ebreakm/s/u の各特権、ebreakX=0 での通常の breakpoint 例外 |
| dm_step | 1 | step の 1 record、trap する命令 (ハンドラの先頭で止まる)、stepie 0/1、CSR 書き込みと IO store の step、step 中の WFI、step する命令の直後に若い分岐の mispredict がある列 (部分 kill が `dm_take` を遅らせても record は 1 つ、設計書 §D.5 の【M4 で決定】) |
| dm_dcsr | 1 | Debug Mode の外での dcsr/dpc/dscratch と DRET の不正命令、dcsr の WARL |
| dm_exc | 1 | progbuf の例外で cmderr = 3、mcause/mepc/mtval が変わらない、Debug Mode 中の ebreak の再入場 |
| dm_abs_gpr、dm_abs_fpr_csr | 1 | Access Register の全組合せ、s0/s1、FS=Off、aarpostincrement の拒否、cmderr の sticky と W1C |
| dm_progbuf | 1 | progbuf の store と load、autoexecdata/autoexecprogbuf、busy 中のアクセスの cmderr = 1 |
| dm_counters | 1 | stopcount と stoptime (N=1 で mtime が止まる) |
| dm_trig_exec | 1 | match 0/1/2/3、chain、block の境界、RVC、hit bit |
| dm_trig_ldst | 1 | load、store、line 内の misaligned、line 跨ぎ (hi の半分だけが一致)、AMO、LR/SC、IO load と IO store (device に届かない、`chk_io_mon`) |
| dm_trig_wrongpath | 1 | mispredict の影の命令と load への一致で入場しない。照合したが kill された数が 0 より大 |
| dm_trig_action0、dm_icount | 1 | action=0 の cause 3 と tval、tcontrol の mte/mpte、icount の count と action 0/1 |
| dm_sba | 1 | sbaccess 8/16/32/64、autoincrement、readonaddr、readondata、sbbusyerror、sberror 2/3/4 |
| dm_sba_code | 1 | SBA で命令を書き換え、resume で新しい命令を実行する (ROM の `fence.i`) |
| dm_reset | 1 | ndmreset、havereset/ackhavereset、resethaltreq (最初の命令の前に止まる)、dmactive = 0 |
| dm_pmp_lock | 1 | lock した PMP が DM 領域を覆っても halt と abstract command が動く。Debug Mode の外の DM 領域へのアクセスは fault |
| dm_smp_select | 4 | hartsel、hasel/hawindow、haltsum0、anynonexistent、選んだ全 hart の halt と resume |
| dm_smp_group | 4 | halt group (1 hart の trigger で group が止まる)、resume group |
| dm_smp_sba_coh | 4 | 他 hart の dirty line を SBA が最新の値で読む、SBA の書き込みを他 hart の load が見る |
| dm_smp_hartreset | 4 | 1 hart の hartreset の間、他の hart が共有のカウンタを更新し続け、値が保たれる (U32) |
| dm_smp_stoptime | 4 | 一部の hart だけ止めても mtime は進み、全 hart を止めると止まる |

### 9.2 riscv-tests の debug suite (GG)

- 構成: Verilator のラッパ (`sim/verilator/tb_soc_dm_n1.sv`、`tb_soc_dm_n4.sv`) が統合 SoC と tb 専用の JTAG DTM (`jtag_dtm.sv`: TAP、IDCODE、dtmcs、dmi) を instantiate し、DTM が APB の master として DM を駆動する。DPI の C (`rbb_dpi.c`) が OpenOCD の remote_bitbang を localhost の TCP で受け、TCK/TMS/TDI/TDO と reset を毎サイクル受け渡す。DTM もラッパも設計には入らない (設計書 §D.1)。
- OpenOCD の構成 `test/debug/openocd/heliodor.cfg` (remote_bitbang、riscv の target、N=4 では SMP)。`gdbserver.py` の target `test/debug/targets/heliodor/{w2_n1,w2_n4,w4_n1}.py` (hart 数、RAM の base と大きさ、link script、sim の起動コマンド、OpenOCD の構成、timeout)。suite は `test/riscv-arch-test/upstream/debug/` の clone を使い、commit を記録する (U36)。
- 【決定】spike を参照にする。同じ版の `gdbserver.py` を spike の target (`spike64` と、SMP の `spike64-2` 相当) で走らせて pass の集合を記録し、heliodor は「spike で pass し、除外表 (設計書 U37、`test/debug/heliodor_excludes.yaml`) に無いテスト」をすべて通す。理由: suite のテストには DM の optional 機能や spike の実装の都合に依存するものがあり、heliodor の結果だけを見ると、不具合と持たない機能を区別できない。除外表の各行は持たない optional 機能か spike との意図した差に結び付ける。
- 回す範囲: W2 の N=1 で全テスト、N=4 (`w2_n4`) で SMP のテスト (hart の切替、全 hart の halt と resume、group)、W4 の N=1 をマイルストーンの末に。結果 (pass/fail/除外の数、壁時間、OpenOCD・GDB・spike・suite の版) は MD の結果の節に記録する。
- 速度: 1 回の DMI アクセスが JTAG の数十から百を超える TCK になるので、target の timeout を sim の速度に合わせて伸ばす。壁時間が梯子の予算 (目安 2 時間) を超えたら、tb の transport を OpenOCD の `jtag_dpi` に替える (設計書 U36、R10)。
- 発火: GG の run も `perf_acc` の dump を出し、GF の `gdb` 列にする (§5.2)。

### 9.3 DMI が idle のときの等価と lockstep

- 【決定】MD のコミットは、DMI が idle (`psel = 0`、DM の出力は登録済みの 0) のとき、M4 までのゲートの結果を変えてはならない。検査: W2 (節目では W4 も) の GL-B の cycles、record 数、最終 hash と、新コアの bench 4 本 (`test_cbench_w{2,4}_*`) の cycles と instret が、MD の直前の master とビット一致すること。理由: DMI が idle なら新しい項 (`dm_req`、step、icount、DM 領域の PMA) はどれも定数の側にあり、1 サイクルでもずれたらそれは debug の経路が通常の経路に漏れた欠陥である。boot の cy は 10,000 刻みなので、ビット一致を言うのは GL-B の record と hash と bench の値である。
- lockstep の run は Debug Mode に入らないので、`o_retire_dm` の印の付いた record は現れない。tracer と retire_mon は印の付いた record を数えず、lockstep の run でそれが 1 つでも現れたら fail にする (debug の経路が誤って発火した印)。
- rv64mi の breakpoint: MD から新コアは trigger を持つので、golden (trigger 無し) と制御の流れが分かれる。lockstep のリストから pass/fail のリストへ移す (付録 B の B59)。
- `MTIME_SRC = INSTRET` の tick は印の付いた record を数えない (設計書 §D.9)。GL-B は Debug Mode に入らないので、tick の列は MD の前と同一である。

### 9.4 M5 での追加

H/V とデバッグの相互作用 (設計書 §D.16 の M5 行) の directed を GD に足す: VS/VU からの halt と dret (dcsr.v、prv)、ebreakvs/ebreakvu、mcontrol6 の vs/vu、HLV/HSV と vector の要素アクセスへの trigger (U39)、Debug Mode での MPRV と MPV。GG は H を持つ target の spike と比べて再び回す。

---

## 10. 外部メモリインタフェースの検証 (MM、設計書 §MM)

【決定】MM の検証は、メモリ側のタイミングだけを振って機能の結果が変わらないことを示す形にする。理由: AXI4 にした目的は、メモリ側の遅延と順序をコアの性質から外すことである。固定遅延でしか確かめていないと、その目的が果たされたことは分からない。

### 10.1 tb の AXI4 slave model

- `tb/axi4_slave_model.veryl` (tb のモジュール)。メモリの内容は他の harness と同じく `$readmemh` の hex を配列に持つ (ROM の置き場所は設計書 U44)。DRAM の配列の base と大きさは `MAP_*` (§2.2) に従う。
- 遅延と backpressure の parameter (channel ごと): AR と AW の受理の遅れ、R の初回遅延と beat 間の隙間、W の ready の確率、B の遅延、R と B の ID 間の順不同 (同じ ID の中は順序を守る)。乱数は seed を parameter に持つ LFSR で作る。`$random` は使わない。理由: Verilator でも同じ列が出て (GV)、失敗した seed を回帰に固定できる。
- 設定の名前を 4 つに固定する: `FIXED` (固定遅延。AR と AW は即受理、初回遅延は固定、beat は毎サイクル、W は常に ready)、`SLOW` (遅延が大きい。outstanding が 1 に近い)、`BACKPRESSURE` (遅延は小さく、全 channel の ready を確率で落とす)、`REORDER` (複数 ID の応答が順不同に返る)。各設定は seed を持つ。
- 単体テスト: model だけを protocol checker の下で駆動する (master 役の tb が合法な取引と、わざと違反した取引を出し、checker が違反を捕まえること)。
- 【MM で決定】実装: `tb/axi4_slave_model.veryl`、設定は `tb/axi4_tb_pkg.veryl` の `SlaveCfg` (`FIXED`/`SLOW`/`BACKPRESSURE`/`REORDER`) と `SEED`、乱数は channel ごとの xorshift32。model は AW を受けた後にだけ W を取り (AXI が許す)、R の burst は 1 本ずつ (interleave しない)、範囲外は DECERR。R の遅延は `r_lat` (line の burst) と `r_lat1` (`ARLEN = 0` の 1 beat) を別に持つ。単体テストは `tb/test_axi4.veryl` で、4 設定の clean run (16 burst の write と read-back、master は RREADY/BREADY を乱数で落とす) と、違反の注入 13 種を G0 に置く (合わせて数秒)。ROM の領域 (U44) は SoC につなぐ手順で足す。 directed 専用の設定 `WR_LAG` と `STALL` を後で足した (§10.4)。

### 10.2 固定遅延の設定と cycles の許容

- `FIXED` は MM の前の DRAM の遅延 (L2 miss から最初の beat まで) を再現するように決める。完全な一致は求めない。理由: gather の beat の調停 (bus の rotation) と `DRAM_WAIT` が無くなり、遅延の入り方が変わる。
- 受入: `FIXED` で、W2/W4 の GL-B (5.15 N=1) と新コアの bench 4 本の cycles が MM の前の値と近いこと。許容幅は最初の測定で決め、本書に記録する (MM の手順 2 の末)。決めた後は、許容を超えるずれは調査の対象にし、乱数設定の cycles は参考値として記録するだけで、ゲートにはしない。
- 機能の結果 (GL-B の record 数と最終 hash、tohost、x3) は `FIXED` と他の設定で一致しなければならない。cycles を含めて一致を求めるのは V14 だけである。

### 10.3 AXI4 の protocol checker

- tb のモジュール `axi4_mon` が、SoC の AXI4 ポートに常時接続する。違反は sticky flag の群で出し、`$error` や SV の assert は使わない (JIT で panic するため)。flag は `o_chk` に似た形で各 harness の合否に含める (§2.3)。
- 検査する規則 (master の側と、slave model の側の両方): valid は ready まで下げない。valid のあいだ payload (アドレス、ID、LEN、SIZE、BURST、strb、data、LAST) が変わらない。valid が ready に依存して立たない (ready を待たずに立つ)。`RLAST`、`WLAST` が burst の最後の beat だけに立つ。W の beat 数が `AWLEN + 1` に一致する。INCR の burst が 4 KiB をまたがない。AR と R、AW と B の ID の対応 (応答の無い ID の応答が来ない、同じ ID の順序)。outstanding が param の上限以下。reset 後に valid が 0。
- 各規則に、わざと違反した取引で flag が立つ単体テストを 1 本付ける (§10.1 の単体テスト)。
- 【MM で決定】実装は `tb/axi4_mon.veryl`、flag は `axi4_tb_pkg::CHK_*` の 12 本。「valid が ready に依存して立たない」と「reset 中の valid が 0」は、クロックの edge で標本化する monitor からは観測できないので flag にしない (前者は master の RTL のレビューで、後者は valid が reset された register から出ることで守る)。同じ ID の順序は「応答はその ID の最古の未完了の要求のもの」として beat 数と `xLAST` の照合に含める。AW より先に終わった W の burst は 1 本だけ追跡する (mem_ctrl は AW と W を同時に立てるので足りる)。
- 判定: G0 を含む新コアの AXI を持つ全 run で、すべての flag が 0。

### 10.4 乱数遅延のゲート (GM) と directed

- directed (設計書 MM.5 の不変条件ごと): I1 は、write の B を遅らせた slave で、同じ line の read を出す (read が古い値を返さない)。I2 は、他 hart が所有する line への write の recall と AW の遅れを重ねる。I3 は、`i_hunc` の読みを、R を遅らせた slave で recall と重ねる。I4 は、gather 中の line に write を入れ、`install_ok` が落ちて L1 が再 fetch すること。I5 は、複数 slot の gather を `REORDER` で順不同に返す。I6 は、各 channel の ready を長く落とした slave で deadlock しないこと。`test/axi/*.S` と `tb/test_axi_*.veryl` に置き、G0 に入れる (N=2 を含む)。
- GM の run: GL-B (W2 の 5.15 N=1) を `FIXED`、`SLOW`、`BACKPRESSURE`、`REORDER` の各設定で、設定ごとに複数の seed で走らせ、record 数と最終 hash が `FIXED` と一致すること。GT2 short は各設定の複数 seed、GT4 は 1 seed ずつ (禁止結果の hit は memory-model のバグ)。GB2 と GB4 (W2) は `BACKPRESSURE` と `REORDER` を 1 seed ずつ (GB4 は MM の全コミット)。seed の数は MM の最初の測定で、壁時間が梯子の予算に収まるように決めて記録する。
- GV: AXI の slave model を `veryl build` で SV にし (`sim/verilator/` のラッパから instantiate)、litmus4、N=2、N=4 の boot を `BACKPRESSURE` で走らせる。Verilator は NBA の相互確認で、N=4 の判定には使わない (§6.3 のまま)。
- 【MM で実装】directed は `tb/test_axi_dir.veryl` (G0、W2) の 8 本: `test_axi_i1` (I1、`test/axi/i1.S`。NC の store → fence → NC load、NC の store → fence → cacheable load (L2 miss)、IO の store → IO load (fence 無し) を 16 本の新しい line で。U43 の `io_ordered` の store の後の load を兼ねる)、`test_axi_i4_slow` (I4、`test/axi/i4.S`、N=2。hart 0 が cacheable の load で line を gather するあいだに、hart 1 の NC store を round ごとに遅らせて gather の窓を横切らせる)、`test_axi_coh_bp` (I2、`coh.S` を `BACKPRESSURE`)、`test_axi_unc_slow` (I3、`unc.S` を `SLOW`)、`test_axi_ad_reorder` (I5、`ad.S` を `REORDER`)、`test_axi_i1_stall` と `test_axi_unc_stall` (I6、`STALL`)、`test_axi_err` (U46、下記)。名前付きの 4 設定では I1 と I4 の窓が開かないので、directed 専用の設定を 2 つ足した: `WR_LAG` (W と B が遅く R が速い。write を追い越した read は古い値を読む) と `STALL` (全 ready と R の beat を 232/256 で落とし、順不同)。
- 【MM で確認】directed が規則を検査していることを、規則を外した RTL で確かめた (commit していない変異): I1 を外す (`ar_cand` から `ar_haz` を外す) と `test_axi_i1` が round 0 の step 3 で失敗する (tohost 0x302)。I4 を外す (`inst_do` から `iok` を外す) と `test_axi_i4_slow` が round 13 で失敗する (tohost 0xd0402)。正しい RTL では `i1_hold` が 1,959 サイクル、`inst_abort` が 13 回発火する (GF)。i4.S の最初の形 (hart 1 が NC store を続けて出す) は変異を見逃した: 後の write が L2 に merge して古い line を直してしまうため。最後の write が gather の窓に入る形に直した。
- 失敗した seed は回帰の一覧 (`test/gates/mm_seeds.list`) に固定して残す。seed だけを変えて通すことはしない (原因を調べる)。
- 発火 (GF): 設計書 MM.5 の I1 (read を write の B まで止めた回数)、I4 (`install_ok` が落ちた回数)、write buffer 満杯での write grant の停止、AR の停止 (line buffer の確保失敗) の事象を `o_perf` に出し、乱数遅延の run で 0 より大きいことを `fire_check.py` で確かめる。`FIXED` では I1 と I4 が 0 でもよい。
- 【MM で決定】GF の実装: `soc_pkg::McPerf` を SoC の `o_mc_perf` に出し、harness の `tb/mc_perf_acc.veryl` が `PERF 0`/`PB 0` (core 0 = mem_ctrl、`fire_check.py` が `McPerf` から名前を付ける) と、人が読む `MC` の 2 行を印字する。事象: `ar_line`/`ar_dram1`/`ar_rom` (AR の handshake、取引の種類ごと)、`aw`、`w_beat`、`i1_hold` (I1)、`ar_wait` (AR channel を他の slot が持つ)、`ar_bp` (ARREADY の backpressure)、`wb_full` (write の要求があるのに write buffer が満杯)、`inst_abort` (I4)。`lat_line`/`lat_dram1`/`lat_rom` は slot ごとの「AR valid から最後の R まで」、`lat_wr` は write buffer の entry ごとの「AW valid から B まで」の bit で、bit の count の和がその種類の遅延の合計になる (費用 = 件数 × 平均遅延が `MC` の行で直接読める)。mem_ctrl の設計では R に backpressure をかけないので、AR の停止の源は I1、channel 待ち、ARREADY の 3 つである。
- V14: 梯子 1-5 と dhrystone/coremark のビット一致 (設計書 MM.7)。V14 の枝の経路は AXI の slave model を通らない。

### 10.5 MM の最初の実装の記録 (手順 2-5、固定遅延)

- 範囲: U45 の凍結コピー `src/v14/v14_mem_ctrl.veryl` (SoC の V14 の枝だけが使う)、新コアの `mem_ctrl` の read path (AR/R、`ARID` = slot、line は `ARLEN = 7`、uncached と ROM は `ARLEN = 0`)、write path (`WB_N = 2 × N_HARTS` の FIFO、`AWID = 0`、strobe の lane 範囲の 1 burst、B で解放、I1)、U44 の ROM (SoC の `mc_unc` を `pma_check` の target ∈ {DRAM, ROM} に替え、ROM の内容は slave model が持つ)。harness は `boot_soc_harness` と `arch_soc_harness` が `tb/axi4_mem.veryl` (`axi4_slave_model` + `axi4_mon`) を `FIXED` でつなぎ、`axi4_mon` の flag は retire_mon の chk に入る (GP)。
- 未着手 (この節の初版の時点): U46 の sticky な error 観測、GM (乱数設定での再走)、§10.4 の directed、GV、U47。GF の事象は §10.4 のとおり実装済み (下の分解に使った)。その後の GM、directed、U46、U47 は §10.6。
- 下の表の「MM」列は最初の `FIXED` (`r_lat = 20` を line にも 1 beat にも使う) の値で、「新 FIXED」列は分解の後に `FIXED` を MM の前の遅延に合わせた (`r_lat = 17`、`r_lat1 = 0`) 値である。

| ゲート (W2、`FIXED`) | MM の前 (`0ebac00`) | MM (`r_lat` 20) | MM、新 FIXED |
|---|---|---|---|
| G0 | 860 passed (M4 の記録) | 865 passed、0 failed | 865 passed、0 failed |
| GL-B | 14,316,714 | 15,597,260 (+8.9 %)。record 10,417,776、hash `74d4b7982390260f`、chk 0 (AXI の flag を含む) | 14,570,718 (+1.77 %)。record と hash は同じ、chk 0 |
| GB2 | 19,082,790 | 20,880,466 (+9.4 %)、pass、chk 0 (両 hart) | 19,380,793 (+1.56 %)、pass、chk 0 (両 hart)。ROM の read 897,133 回の大半は hart 1 が ROM の中で起動を待つ spin |
| cbench dhrystone / coremark / fpmm / spmv | 268,712 / 381,245 / 1,044,649 / 41,165 | 268,776 / 381,354 / 1,046,441 / 42,819 | 未測定 |
| V14 dhrystone / coremark | 235,804 (instret 264,834) / 394,546 (374,357) | 同じ (ビット一致) | 変更の範囲外 (V14 は AXI を通らない) |
| V14 5.15 N=1 boot | cy=0x00ba9d70 | 同じ | 同じく範囲外 |

#### GL-B の +8.9 % の分解

取引ごとの遅延 (MM の前はソースからの導出、MM は `MC` の行の実測。L は slot が L2 を lookup したサイクル):

| 取引 | MM の前 (`0ebac00`) | MM、`r_lat` 20 | MM、新 FIXED |
|---|---|---|---|
| line fill (L2 miss) | DWAIT 20 の後に bus の gather 8 beat。最初の beat は L+21、INSTALL は L+29 | ST_AR 1 サイクル、AR の handshake、最初の R は AR の 22 サイクル後: L+24 / L+32 (+3)。AR valid から最後の R まで平均 30.1 | `r_lat` 17 で L+21 / L+29 (一致)。平均 27.1 |
| ROM の read (1 beat) | legacy の組合せの経路: slot を使わず、bus の read grant と同じサイクルにデータ | accept、LOOKUP、ST_AR、AR、R、ST_UNCD の slot の取引。AR valid から R まで平均 23.0、要求から約 27 サイクル | `r_lat1` 0 で AR valid から R まで 4.0 (AR の 1 サイクルと slave の登録 2 段)、要求から約 8 サイクル |
| DRAM の uncached 1 beat | ST_UNC: L+1 (bus の grant と同じサイクル) | ROM と同じ | ROM と同じ。GL-B では 0 件 |
| write | 1 サイクルの posted。gather の beat と legacy の ROM read のあいだだけ grant を止める | write buffer (`WB_N` = 2) に入り、AW と W を出し B で解放。92,523 本、うち line の 8 beat がほぼ全部 (W 740,184 beat)、AW valid から B まで平均 13.4 | 同じ |

件数 (GL-B、`r_lat` 20 / 新 FIXED): line 48,668 / 49,596、ROM 54,024 / 56,562、DRAM の 1 beat 0 / 0、write の burst 92,523 / 92,537、`wb_full` 316,826 / 305,299 サイクル、`i1_hold` 2,135 / 669、`ar_wait`、`ar_bp`、`inst_abort` はどれも 0。ROM の read は、boot の間 M-mode の trap の処理 (ROM の firmware) を uncached で fetch するもので、1 beat ずつ直列に待つので遅延がほぼそのまま cycles に出る。

遅延を 1 つずつ戻した GL-B の run で差分を取った (record と hash はすべて同じ):

| 区分 | 根拠の run | cycles | +8.9 % (1,280,546) に占める割合 |
|---|---|---|---|
| ROM の fetch の遅延 (1 beat に `r_lat` 20) | `r_lat` 20 → line 20 / 1 beat 0 (14,659,950) | 937,310 | 73.2 % |
| line fill (+3 サイクル: ST_AR と AR の handshake の 2 段と、R の登録の 1 段) | line 20 / 1 beat 0 → line 17 / 1 beat 0 (14,570,718) | 89,232 (潜在 3 × 48,668 = 146,004 の 61 %) | 7.0 % |
| DRAM の uncached 1 beat | 件数 0 | 0 | 0 % |
| write (write buffer 満杯の停止を含む) | 新 FIXED で `WB_N` を 6 にした run (14,579,390、`wb_full` 2,541 サイクル) | 0 (差は -8,672 で雑音の幅。`wb_full` は 305,299 サイクルあるが core の進行を止めていない) | 0 % |
| 残り (AXI の構造: 主に ROM の 1 beat が slot の取引になったこと) | 新 FIXED と MM の前の差 | 254,004 | 19.8 % (GL-B の +1.77 %) |

- 【MM で決定】`FIXED` を MM の前の遅延に合わせた: `r_lat = 17` (line の最初の beat が lookup の 21 サイクル後になり、`DRAM_WAIT = 20` の gather と同じサイクルにそろう)、`r_lat1 = 0` (1 beat は slave が出せる最短。MM の前の 1 beat は組合せで返っていた)。`b_lat` は 1 のまま (0 と 1 は model の中で同じ時刻になる)。他の 3 設定は `r_lat1 = r_lat` で、振る舞いを変えない。
- 残りの 254,004 (+1.77 %) は AXI の構造による。MM の前の ROM の read は slot を使わずに同じサイクルで返っていたが、AXI では 1 beat ごとに accept、LOOKUP、ST_AR、AR、slave の登録 2 段、ST_UNCD を通り、最短でも要求から約 8 サイクルかかる。56,562 回 × 約 4.5 サイクルでこの残りに見合う (ROM 以外の寄与は分けて測っていない)。mem_ctrl の側で削れるのは ST_AR の 1 サイクル (LOOKUP の miss から直接 AR を立てる) と ST_UNCD の 1 サイクルで、残りは registered な AXI の往復そのものである。§10.2 の許容幅はこの値を基準に決める。
- write の側は、`WB_N = 2` で `wb_full` が 305,299 サイクル立つが、`WB_N = 6` にして 2,541 サイクルまで消しても cycles は変わらなかった (14,579,390)。したがって `WB_N` の sweep (設計書 MM.4) は今は不要である。なお、この run では harness の `axi4_mon` の `MAX_WR` (`N_HARTS × 2`) も 6 に上げる必要があった。`MAX_WR` は `WB_N` に追従させる。

### 10.6 GM、directed、U46、U47 の記録

- GM の test は `tb/test_axi_gm.veryl` (`#[ignore]`、`veryl test --ignored --test test_gm_`): GL-B (W2 の 5.15 N=1 lockstep) を `SLOW`、`BACKPRESSURE`、`REORDER` の各設定で seed 2 つ (`32'h1`、`32'h5eed_0002`)、W2 の N=2 boot を `BACKPRESSURE` と `REORDER` で seed 1 つ (`32'h1`)。cycle の上限は `SLOW` を見込んだ早期終了の上限 (GL-B 120M、N=2 200M) で、測った値ではない。8 本を 1 回の invocation で並列に走らせ、壁時間は N=2 の boot が律速で約 4 時間 (共有の box)。`FIXED` の GL-B は U46 と U47 の後 (`9cc4a65`) で取り直し、`de5ef6c` の値と同じだった (`r_err`/`b_err` 0)。
- 結果: 全 run が pass、chk 0 (AXI の protocol flag を含む。GM の run は `f884fe7` で、U46 の前なので error flag は含まない。slave model は範囲内の access に DECERR を返さない)。GL-B の record 数と最終 hash はすべての設定と seed で `FIXED` と一致した。失敗した seed は無いので `test/gates/mm_seeds.list` はまだ作っていない。RTL のバグは見つからなかった。

| run | 設定 / seed | cycles | record / hash | 備考 (MC の行) |
|---|---|---|---|---|
| GL-B | `FIXED` | 14,570,718 | 10,417,776 / `74d4b7982390260f` | `wb_full` 305,299、`i1_hold` 669 |
| GL-B | `BACKPRESSURE` / 1 | 14,989,456 (+2.9 %) | 同じ | `ar_bp` 63,459、`wb_full` 542,756、`i1_hold` 5,451 |
| GL-B | `BACKPRESSURE` / 2 | 14,987,691 (+2.9 %) | 同じ | |
| GL-B | `REORDER` / 1 | 16,105,055 (+10.5 %) | 同じ | ROM の 1 beat の遅延の合計 1,446,652 (`FIXED` は 226,510) |
| GL-B | `REORDER` / 2 | 16,111,181 (+10.6 %) | 同じ | |
| GL-B | `SLOW` / 1 | 23,509,127 (+61.3 %) | 同じ | `wb_full` 1,955,812、`ar_bp` 292,633 |
| GL-B | `SLOW` / 2 | 23,530,627 (+61.5 %) | 同じ | |
| GB2 (W2 N=2) | `FIXED` (`de5ef6c`) | 19,380,793 | pass | |
| GB2 (W2 N=2) | `BACKPRESSURE` / 1 | 19,855,455 (+2.4 %) | pass、chk 0 (両 hart) | `i1_hold` 14,817、`ar_wait` 12,631 |
| GB2 (W2 N=2) | `REORDER` / 1 | 21,419,924 (+10.5 %) | pass、chk 0 (両 hart) | |

- GF: GM の run で `i1_hold`、`ar_wait`、`ar_bp`、`wb_full` は 0 より大きい。`inst_abort` (I4) は GM の boot ではどの設定でも 0 だった: N=1 では gather 中の line に書けるのは自 hart だけで、N=2 の boot でも他 hart の line は per-line の直列化と recall を通るので、gather の窓に write が入る経路は NC と uncached の store だけである。I4 の発火は directed の `test_axi_i4_slow` (13 回) で確かめる (§10.4)。
- `SLOW` では `wb_full` が 1.96M サイクル立つ (cycles の 8 %)。設計書 MM.4 の `WB_N` の sweep の材料で、`SLOW` で `WB_N` を上げた run はまだ取っていない (`FIXED` では効かないことを §10.5 で確かめた)。
- directed (§10.4) の cycles: `test_axi_i1` 4,819、`test_axi_i1_stall` 13,054、`test_axi_i4_slow` 18,397、`test_axi_unc_slow` 8,382、`test_axi_unc_stall` 12,258、`test_axi_coh_bp` 132,336、`test_axi_ad_reorder` 91,896、`test_axi_err` 388。G0 は 874 passed、0 failed (MM の前の 865 に directed 8 本と `test_axi4_sram` を足した)。
- U46: `test_axi_err` (`test/axi/err.S`) は slave の DRAM を 2 MiB にした harness (`AXI_MEM_DW`) で、PMA の DRAM (4 MiB) の中だが slave の外の line を読み、NC で 1 dword を書く。`r_err` 9 beat、`b_err` 1 回、両方の sticky flag が立ち、core は trap しない。
- U47: `test_axi4_sram` が pass (`axi4_mon` の flag 0、read-back 一致)。生成した SV の RAM は reset の無い `always_ff @(posedge clk)` の read-enable 付き read と byte-enable の write で、BRAM に推論できる形である。Verilator の `--lint-only -Wall` は使わない address の bit (`UNUSEDSIGNAL`) だけを出す。
- GT2 と GT4、GB4 の乱数設定 (`e93eca2`): GT2 short は `tb/test_axi_gm.veryl` の `test_gm_w2_litmus_2hart_{slow,bp,reorder}_{s1,s2}` (native、`#[ignore]`、6 本を 1 回の invocation で並列、壁時間 約 10 分)。N=4 は native が遅い (約 600 cy/s) ので Verilator で回す。`sim/verilator/` の W2 のラッパ 3 本 (`tb_litmus_4hart_w2.sv`、`tb_soc_smp_linux_boot_{2,4}hart_w2.sv`) に module parameter `AXI_SEL` (0 `FIXED`、1 `SLOW`、2 `BACKPRESSURE`、3 `REORDER`) と `AXI_SEED` を足し、build 時に `-GAXI_SEL=3 -GAXI_SEED=1` のように渡す (既定は `FIXED` で、従来の build と同じ)。設定ごとに Mdir を分ける (`build_<top>_<設定>_s1`、`-O1 -j 2`)。Verilator の run は 1 本ずつ直列に走らせた。

| run | 設定 / seed | cycles | 結果 | 備考 (MC の行)、壁時間 |
|---|---|---|---|---|
| GT2 short (native) | `FIXED` | 985,016 | pass | `test_w2_litmus_2hart` |
| GT2 short (native) | `SLOW` / 1、2 | 987,747、987,618 | pass | |
| GT2 short (native) | `BACKPRESSURE` / 1、2 | 985,124、985,155 | pass | |
| GT2 short (native) | `REORDER` / 1、2 | 985,487、985,600 | pass | |
| GT4 (Verilator) | `FIXED` (M4 末) | 5,029,779 | pass | |
| GT4 (Verilator) | `BACKPRESSURE` / 1 | 5,029,816 | pass、chk 0 (4 hart) | `line` 170、`aw` 125,956、`ar_bp` 104、`wb_full` 0。38 分 |
| GT4 (Verilator) | `REORDER` / 1 | 5,030,147 | pass、chk 0 (4 hart) | `line` 171、`aw` 125,952、`ar_bp` 28、`wb_full` 0。40 分 |
| GB4 (Verilator) | `FIXED` (M4 末) | 24,989,451 | pass | |
| GB4 (Verilator) | `BACKPRESSURE` / 1 | 25,515,720 (+2.1 %) | pass、chk 0 (4 hart) | `line` 111,874、`ar_bp` 933,313、`wb_full` 524,250、`i1_hold` 10,806、`ar_wait` 72,174。3 時間 20 分 |
| GB4 (Verilator) | `REORDER` / 1 | 26,848,519 (+7.4 %) | pass、chk 0 (4 hart) | `line` 113,333、`ar_bp` 143,662、`wb_full` 191,725、`i1_hold` 6,962、`ar_wait` 6,096。3 時間 30 分 |
| GB2 (Verilator) | `BACKPRESSURE` / 1 | 19,855,455 | pass、chk 0 (両 hart) | native の GM run と cycles が一致 (同じ値)。`ar_bp` 420,504、`wb_full` 571,601。1 時間 4 分 |

- litmus の乱数設定は cycles がほとんど動かない。litmus の image は L2 に収まり、DRAM の line read は N=4 でも 170 本しかない。GT2 と GT4 の乱数設定が試すのは主に write path (AW 12.6 万本) と coherence であって、read の順不同ではない。read の順不同と backpressure を負荷の下で試すのは GB2 と GB4 である。
- `WB_N` の sweep (設計書 MM.4、U42): `mem_ctrl` の `WB_N` を `4 × N_HARTS` (N=1 で 4) にし、`boot_soc_harness` の `MAX_WR` を `N_HARTS × 4` に合わせて GL-B を 2 本走らせた。record 数と hash は両方とも `FIXED` と一致した。

| GL-B | `WB_N = 2` (既定) | `WB_N = 4` | 差 |
|---|---|---|---|
| `FIXED` | 14,570,718 (`wb_full` 305,299) | 14,564,006 (`wb_full` 244,656) | -0.05 % |
| `SLOW` / 1 | 23,509,127 (`wb_full` 1,955,812) | 22,651,396 (`wb_full` 865,521) | -3.65 % |

- 【決定】`WB_N` は既定の `2 × N_HARTS` のままにする。理由: `FIXED` の差は -0.05 % で、§10.5 の `WB_N = 6` の run (差は雑音の幅) と同じく、固定遅延の memory では write buffer は core の進行を止めていない。`SLOW` の 3.65 % は、遅延が大きく outstanding が 1 に近い slave でだけ出る利得で、entry を倍にする面積 (line 幅の data と strobe の FF、N=4 で 8 から 16 entry) に見合う根拠にはならない。実 memory の遅延が `SLOW` に近い構成 (FPGA の DRAM controller、U48) では `WB_N` を上げる価値があるので、`WB_N` は parameter のまま残し、その構成を測るときに決め直す。
- 残り: なし。`axi4_sram` を boot の harness で使う形 (DRAM の hex を 64 bit/行に変換する必要がある) は FPGA の実機の作業 (U48) に繰り延べた (2026-10-27、ユーザ承認)。W4 の GL-B は 12,262,946 (MM の前 11,681,911、+4.97 %)、record 数と hash は一致。GV の残りは無い。

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
| B03 | satp_shadow が古い satp を保持する。csrw satp (と satp の読み出し) は旧値を latch し、次の sfence まで MMU は古い root で翻訳する | 確定 (probe)。boot への影響は無い (M2 で決定、§4.7) | 7170-7185、csr.veryl:1088 | 不明。§3.5 の run で sfence の無い satp 書き込みの窓 (`SATP_WIN`) を 4 つ確認した: 76987-76993 (B02)、2438786、4286867-4286885、10336234-10341956 (約 5.7K record)。窓の中で (a) 余分なカーネル page fault が出るか、(b) 窓が実害なく閉じるかは、窓の中の page fault をまだ数えていないので未決 | SAME。【決定】(M2) golden boot のカーネルの page fault は 0 で (b) に当たる (§4.7)。GL-B はこの窓を含めて一致した | `b03_satp_shadow`、tohost 0x1B003。sfence なしで root 2 へ csrw satp した後、root 2 にだけ写した VA への MPRV-S load が page fault (13) になった (walk が古い root を使った)。`SATP_WIN` gtag 223 |
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
| B15 | カウンタ CSR の読み値がマイクロアーキテクチャに依存する | 確定 | csr.veryl:574-584、1190-1239 | n (静的に数えて 0、時刻は 0xC01 の 23 か所だけ) | MASK:CNT。対象: 0xB00/0xC00、0xB02/0xC02、0xB03-0xB1F/0xC03-0xC1F の rd、0x323-0x33F の bit 63、0xDA0、mip/sip の bit 13。外れるのは読み出しの rd だけなので、読んだ値から計算する ACT4 Zicntr の 2 本は GL-C から外し、GA だけで判定する (M2、`m2_act.list` の `lockstep=0`) | 不要 |
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
| B30 | decoder が予約符号化を通す (未知の SYSTEM funct12 は NOP、AMO の funct5/幅、予約 LOAD/STORE funct3、静的な予約 rm) | 確定 (probe、4/4) | decoder.veryl:684-735、609-632、334-352 | n | STOP | `b30_reserved_enc`、tohost 0xFB01E。DRET、LOAD funct3=7、SYSTEM funct12=0x7ff、AMO funct5=0x06 のどれも trap しない。case 4 の語は当初 0x0807b02f (funct5=0x01 の正当な amoswap.d) で誤っており、M2 で 0x3007b02f (funct5=0x06、予約) に直した。tohost の値は修正前の run のもので、case 4 の golden での再確認が要る (M2 末でも未実施)。新コアは直した語で 4 case とも trap し、W2/W4 で tohost=1 (`m2_fp_pf.list`) |
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
| B43 | 再利用する csr.veryl の癖 (satp の MODE が WARL でない、mstatus[63] を格納する、mip の読み値が pin 由来の bit を含まない、misa に F/D/C が無い) | 確定 | csr.veryl:1088、421、570、517 | y (satp の書き込み、misa の読み出しはありうる) | satp の MODE は新コアが csr 修正で WARL にする (設計書 §C.9 #20) ので STOP:SATP_WARL (5.15 は MODE を probe しないので 0 回の見込み)。mstatus[63] と mip は SAME。misa は【決定】(M2) 新コアがその build の ISA をそのまま報告する (設計書 §C.9。M2 の値 `0x8000_0000_0014_112d`、golden は `0x8000_0000_0034_1181`) ので、misa を読む record は rd で食い違う。rv64mi の csr、mcsr、ma_fetch は pass/fail で判定する (`m2_csr_pf.list`)。ACT4 の trap/prolog の misa の読み出しは MASK:MISA で吸収する。【決定】(M2) MASK:MISA は taint 規則として tracer に実装した (`TRACER_VER = 3`、§4.8): misa を読む Zicsr op の rd と、その値を源に持つ 32 bit の整数 op の rd と store データを外す (RVC と FP の使用は外さない)。これで ACT4 の misa の不一致がすべて消え、rv64mi/mcsr も lockstep に入った。csr と ma_fetch は misa で制御フローが分かれるので pass/fail のまま。5.15 boot は misa を読まない | S-mode で satp に MODE=9 を書いて読み戻す。golden の期待値は 9 が残る |
| B44 | 時刻の CSR を読む時点 (旧コアは head で issue、新コアは oldest token の `fu_sys`) | 確定 | iq_int.veryl:425-428、csr.veryl:576 | y (rdtime 23 か所) | SAME (§4.1 の議論により両者とも retire 順位だけで決まる) | 不要 |
| B45 | mhpmevent の OF (bit 63) が既に立っていても、counter の再度の wrap で LCOFI を再び pend する | 確定 | csr.veryl:1226-1239 | n (5.15 は Sscofpmf の overflow を使わない) | STOP:LCOFI (新コアは OF の 0→1 でだけ pend する csr 修正、設計書 §C.9 #21) | OF を立てたまま hpmcounter を再び overflow させ、mip.LCOFIP を読む |
| B46 | console の文字が 2 回ずつ出る (`pprriinnttkk`)。パッチ前の `b0f4668` でも同じで、B41 の IO store の重複書き込み (M 段の無条件の latch) による | 確定 (probe、現象と原因) | 11940 (fill_1 の M 段 latch) | y (console の全文字) | 許容差異。新コアは IO store をちょうど 1 回だけ書く (設計書 §5.14) ので、console に出るバイト列は golden と違う。trace には現れない (store の record は両コアとも 1 つ) ので、IO デバイス側の書き込み (console の出力を含む) を trace の比較に入れない。新コアの回数は §8 の IO モニタと、UART THR への書き込み回数を数える自己検査型の directed test (§7.4) で守る | `b46_uart`、tohost 0xB02E。commit した THR への byte store 12 個に対し device 書き込みは 21 回。trace の IO store record は store ごとにちょうど 1 つ。連続する store と fence で隔てた store は 2 回書かれ、直後に DRAM への sd が続く store は 1 回 (別の store が M 段の latch を上書きすると重複が消える) |
| B47 | W=1/D=0 のページ (ADUE=0) で page fault する store が、trap しながらデータをメモリに書く | 確定 (probe) | `b10_amo_vm` の trace と実行後のメモリ。コード位置は未特定 | 不明 (D=0 のページへ ADUE=0 で store したときだけ起こる。測った範囲では 5.15 lockstep boot はそうしないが、数えるタグは無い) | 許容差異。新コアは trap する op では何も書かない (設計書 §5.8)。trap record は両コアで同じなので、差は後でその番地を読む load の rd に現れ、lockstep はそこで止まる | `b10_amo_vm` (B10 と同じ probe)。trace `T ... 0062b023 0f 0000000080201000` で store が cause 15 で trap した後、メモリにはその store のデータ (0x10) が入っていた |
| B48 | riscv-tests の env (`upstream/env/p/riscv_test.h` の `INIT_RNMI`) が全テストの先頭で `csrwi mnstatus, MNSTATUS_NMIE` (CSR 0x744、Smrnmi) を実行する。golden は未実装 CSR として書き込みを捨てて retire する (B31 と同じ機構)。新コアは CSR の存在検査 (設計書 §C.8) で不正命令 (cause 2) の trap にする。env は直前に mtvec をこの命令の直後に向けているので、どちらも同じ次 PC から続く | 確定 (コード。M1b の decode で判明) | `upstream/env/p/riscv_test.h:120-125`、csr.veryl:585-591 | n (boot は推定)。arch では riscv-tests の env を使う全テストで y (1 回ずつ) | NORM。【決定】(M1b) tracer が CSR 0x744 の Zicsr op を、golden の R record と新コアの cause 2 の T record のどちらでも `N <order> <pc> 744` の 1 行に正規化し、hash もこの形で取る (`TRACER_VER = 2`、§4.8)。理由: どちらも record は 1 つで同じ次 PC から続くので、この 1 命令の形を揃えれば残りはそのまま比べられる。mnstatus を存在表に入れると Smrnmi を持つふりになる |
 不要 (env のコードと両コアの trace で確認できる) |
| B49 | FCVT.L.D で \|x\| ∈ [2^53, 2^63) の結果が誤る。仮数をシフトせずにそのまま返す。fflags は正しい | 確定 (probe) | `fpu_wrap.veryl` の FP→整数変換 (行は未特定)。M2 準備の `fp_cvt` の移植で判明 | 不明 (カーネルはこれらの変換をほとんど使わないと推定。数えるタグは無い) | 許容差異。新コアが正しく、golden が誤り。差は rd に現れ、lockstep はそこで止まる。VU は M5 まで `fpu_wrap` を通して同じ誤りを引き継ぐ (設計書 §X.8 の【M5 で決定】) | `b49_fcvt_l_d`、tohost 0x001FB031。sub-case のマスク 0x1F のすべてで仮数がシフトされずに返った |
| B50 | FCVT.W.D の NX と NV が境界で入れ替わる: +2^31 に丸め上がる入力と -(2^31, 2^31+1) の入力。FCVTMOD.W.D は -(2^31+0.5) で同じ。結果の値は正しい | 確定 (probe) | 同上 | 不明 (同上) | 許容差異。差は fflags (と後でそれを読む rd) に現れる。VU の扱いは B49 と同じ | `b50_fcvt_w_d`、tohost 0x00BFB032。境界の sub-case で NX と NV が入れ替わった |
| B51 | FCVT.WU.D で 2^32 に丸め上がる入力が NV でなく NX を立てる。結果の値は正しい | 確定 (probe) | 同上 | 不明 (同上) | 許容差異 (B50 と同じ) | `b51_fcvt_wu_d`、tohost 0x0007B033 |
| B52 | FCVT.S.D の丸めによる overflow で OF が立たない (fflags 0x01、正しくは 0x05)。結果の値は正しい | 確定 (probe) | `fpu_wrap.veryl` の D→S 変換 (行は未特定) | 不明 (同上) | 許容差異 (B50 と同じ) | `b52_fcvt_s_d_of`、tohost 0x001FB034 |
| B53 | FCVT.H.D で \|x\| < 2^-24 の結果が常に ±0 になる。正しくは、RUP/RDN/RMM で 0 から離れる向きに丸める場合と、RNE で \|x\| ∈ (2^-25, 2^-24) の場合に ±0x0001 | 確定 (probe) | `fpu_wrap.veryl` の D→H 変換 (行は未特定) | 不明 (同上) | 許容差異 (B49 と同じく rd に現れる) | `b53_fcvt_h_d_tiny`、tohost 0x003FB035 |
| B54 | FCVT.S.D、FCVT.H.S、FCVT.H.D が tininess を丸めの前に判定する。丸めると正規数の最小値になる入力で UF\|NX を立てる (正しくは NX だけ) | 確定 (probe) | `fpu_wrap.veryl` の FP→FP 変換 (行は未特定) | 不明 (同上) | 許容差異 (B50 と同じ) | `b54_fcvt_tininess`、tohost 0x00DBB036。3 つの変換すべてで UF\|NX |
| B55 | rd=x0 の AMO で、golden の store record のデータが AMO の書いた値 (旧値と rs2 の演算結果) でなく rs2 そのものになる。golden の観測 (§3.3 の N8 の `c_store_data`) の誤りで、メモリに書かれる値ではない | 確定 (M2 の ACT4 診断。Zaamo 16 本、Zabha 16 本の GL-C 不一致) | §3.3 の N8 | y (5.15 boot の GL-B の全文比較で 2,836 回) | 許容差異 (新コアが正しい)。【決定】(M2) MASK:AMO_X0_DATA (rd=x0 の AMO の store record の `mem_wdata`、§4.8)。理由: golden の adapter はこの op の旧値を持たず、正しい値を作れない (NORM にできない) | 不要 (ACT4 の trace で確認できる) |
| B56 | store で書き換えたコードへ、fence.i を挟まずに飛ぶ。golden は古い命令を、新コアは新しい命令を実行する。fence.i の前の命令の取り込みは spec 上どちらも合法 | 確定 (M2 の ACT4 診断。pmpsm の cfg_A_tor_zero と tor_check_01..03 の 4 本。record 数が 19 違う) | ACT4 の該当テストの trace | n (推定。カーネルは自己書換えの後に fence.i を使う) | OUT: 該当の 4 本は GL-C から外し、GA (pass/fail) だけで判定する。golden と新コアのどちらの取り込みにも合わせない。実装 (M2): `test/gates/m2_act.list` の 4 エントリに `lockstep=0` を付けた (golden の run と final を持たず、`run_act.py` は GA だけで判定する) | 不要 |
| B57 | golden の SC の store record の PA と IO 印が、翻訳前の VA から作られる (PA = VA)。Sv39 の S/U の SC だけでなく、M-mode で MPRV が翻訳する SC も同じ。メモリへの書き込みは正しい PA に行く | 確定 (M2。GL-B の全文 trace 比較と ACT4 の S/U と MPRV の SC) | §3.3 の N8 (SC の store record の PA の源) | y (5.15 boot の SC。GL-B の全文比較の差分 2 種類のうちの 1 つ) | 許容差異。MASK:SC_PA (SC の store record の PA と IO 印、全特権、§4.8) | 不要 (trace で確認できる) |
| B58 | golden で、失敗する SC (reservation が無い) が store 権限の検査を飛ばし、書けないページ (R のみ、Svade で D=0、無効) への SC が fault しない。仕様は SC を成否によらず store として翻訳・検査することを求める (Sail も同じ) | 確定 (M2。`sc_wperm` の作成時に判明) | `test/directed/sc_wperm.S` | 不明 (失敗する SC を数えるタグは無い。カーネルは書けるページにしか SC を出さないと推定) | 許容差異。新コアは書けないページへの SC を reservation の有無によらず cause 15 で trap する (AMO と同じく W と D の権限で翻訳する、設計書 §L.16)。trap record が食い違うので lockstep はそこで止まる。`sc_wperm` は pass/fail だけで判定する (`m2_lsu_pf.list`) | `sc_wperm` (新コアの directed。golden は reservation の無い SC の case で fault しない) |
| B59 | golden は Sdtrig の trigger を持たない (tselect、tdata1、tdata2、tcontrol は 0 を読み書き込みを捨てる、M2 の新コアも同じ)。MD から新コアは trigger を持つので、tselect に書いた値が読めるかで trigger の有無を判断するテスト (rv64mi の breakpoint) の制御の流れが分かれる | 確定 (設計、設計書 §D.14) | 設計書 §C.8 の Sdtrig の【決定】、§D.14 | n (boot の firmware は自前の `test/linux/fw/linux_boot_fw.S` で trigger の CSR を触らず、S-mode の kernel は M の CSR に触れない) | OUT。MD から rv64mi の breakpoint を lockstep のリストから pass/fail のリストへ移す (§9.3) | 不要 |
