# Phase 15 MS: 配列のサイズの見直し (BTB の sweep と同種の無駄の棚卸し)

`doc/phase15_ms_inventory.md` (MS の手順 1、2) の配列一覧を、**容量そのものの無駄** (幅、重複、根拠の無いエントリ数、複製) の観点で見直した結果。最大の配列 `bp_btb` は sweep で測り (§1)、他の配列は約 2 Kbit 以上を全部見た (§2)。**本書の提案はすべて判断待ち** (ユーザが決める)。既定のサイズは一つも変えていない。

コミットしたのは測定用の足場だけである (`bpu: parametrize BTB target width and add BTB training events`)。

- `bpu_pkg::BTB_STGT_W` / `BTB_TTGT_W`: 条件 slot と tail slot に格納する target の下位 bit 数。上位は lookup の pc (block の start_pc) から取る。既定は 64 (全 bit を格納) で、従来と同じ。
- `core_types::BtbPerf` (`o_perf.front.btb`): commit した block の学習ごとに、taken exit を持つ block 数 (`upd`)、その lookup がヒットしていた数 (`hit`)、exit が分岐か (`x_br`)、return 以外の jump か (`x_j`)、target と start_pc が bit k より上で食い違う数 (`far_br`: k = 12, 13, 14, 16, 20、`far_j`: k = 13, 16, 20, 24, 32)。perf の配線だけで、予測には影響しない。
- 既定点の一致: 5.15 N=1 boot の W2 は 14,633,581 サイクルで、`CLAUDE.md` の記録と同じ値。bench 8 本 (`test_cbench_w{2,4}_{dhrystone,coremark,fpmm,spmv}`) のサイクル数と instret が足場の前 (`a3b9a54b`) と完全に一致した (W2 dhrystone 268,712、coremark 381,237、W4 204,902、315,613 など)。

## 1. BTB の sweep (Task 1)

### 1.1 構造と bit 数

`bp_btb` の 1 エントリ (W2 / W4) = tag 16 + slot × (foff 3/4 + ctr 2 + target S) + tail (foff 3/4 + kind 3 + rvc 1 + target T)。valid (`vld`、`s_v`、`t_v`) は別の F 配列で 4 / 5 bit。S、T は格納する target の bit 数で、既定は 64 / 64。

圧縮の方式: **上位 bit を lookup の pc から取る (region 方式)**。target = {start_pc[63:S], 格納した target[S-1:0]}。加算器が要らず、lookup の pc はすでにレジスタ (`lk_pc_q`) にあるので予測の経路に入るのは AND/OR だけである。外れる (target と start_pc が bit S より上で違う) と予測 target が誤るが、正しさには影響しない: 直接分岐/jump は extract の V3 (target 違い) が redirect し、間接 jump は execute の mispredict になる。return の target は RAS から取るので tail の T は関係しない。

- target の bit 0 は常に 0 (分岐と JAL は偶数の offset、JALR は `& ~1`、`fu_bru.veryl:68`)。圧縮版では [S-1:1] だけを持てばよい。下表の「bit 0 なし」はそれを引いた値 (足場は測定を単純にするため bit 0 も格納している。挙動は同じ)。
- 他の方式との比較: XiangShan の FTB は下位 bit + 2 bit の carry 状態 (上位が pc と同じ / +1 / −1) を持ち、region 境界をまたぐ近い target も当てる。本 core の census (§1.2) では、条件分岐の取りこぼしは S = 16 で 6 回 / 73 万回しか無く、carry を足す利得は無い。BOOM のように「近い target 用の短い表 + 遠い target 用の別表」に分ける方式は、census で遠い target (> 2^24) が 0 回なので要らない。

| 点 (S, T) | W2 bit / エントリ | bit 0 なし | + valid | W4 bit / エントリ | bit 0 なし | + valid |
|---|---|---|---|---|---|---|
| (64, 64) 既定 | 225 | 225 | 229 | 298 | 298 | 303 |
| (20, 32) | 105 | 102 | 106 | 134 | 130 | 135 |
| (16, 24) | 89 | 86 | 90 | 114 | 110 | 115 |
| (13, 20) | 79 | 76 | 80 | 101 | 97 | 102 |

payload の総量 (bit 0 なし、valid を含まない):

| エントリ数 | W2 (64, 64) | W2 (16, 24) | W4 (64, 64) | W4 (16, 24) |
|---|---|---|---|---|
| 4096 (既定) | 921,600 | 352,256 | 1,220,608 | 450,560 |
| 2048 | 460,800 | 176,128 | 610,304 | 225,280 |
| 1024 | 230,400 | 88,064 | 305,152 | 112,640 |

### 1.2 target の距離の census (既定点、5.15 N=1 boot)

既定の 4096 × (64, 64) で、commit した taken exit のうち target が start_pc と bit k より上で違う割合 (`far_br` / `far_j`)。この数が、その幅の region 方式で外れうる学習の数である。

| W2 boot | 母数 | > 2^12 | > 2^13 | > 2^14 | > 2^16 | > 2^20 | > 2^24 | > 2^32 |
|---|---|---|---|---|---|---|---|---|
| 条件分岐 (`x_br`) | 730,550 | 18,493 (2.53 %) | 1,351 (0.18 %) | 1,324 (0.18 %) | 6 | 0 | — | — |
| jump (return を除く、`x_j`) | 655,639 | — | 164,383 (25.1 %) | — | 97,861 (14.9 %) | 35,044 (5.3 %) | 0 | 0 |

W4 boot も同じ形 (条件分岐 776,301 のうち > 2^13 が 4,206、> 2^16 が 6。jump 608,973 のうち > 2^20 が 35,044、> 2^24 が 0)。

- dhrystone と coremark は全点で 0 だった。text が 6 KB (coremark は `coremark.elf` の text 6,352 byte) しか無く、BTB のエントリ数も target の幅も効かない。**判定に使えるのは boot だけ**である (旧 blkpred の測定で 1024 エントリで bench が ~100 % だったのと同じ理由)。
- (20, 32) は census で (16, 24) と同じく無損失と分かるので、box の負荷のため run を省いた。
- この census から、(16, 24) は 5.15 boot で実質無損失 (条件分岐の外れ 6 回、jump 0 回) と予想し、(13, 20) を損失の出る点として測った。

### 1.3 結果

5.15 N=1 boot (`sz_w{2,4}_b515`、`test_w4_linux_boot` と同じ harness) と bench。boot の `cy` は SBI shutdown を 10,000 サイクル刻みで見つけたときの値。hit は「taken exit を持つ block の lookup がヒットしていた割合」(`hit / upd`)。V5 は predecode が見つけた予測されていない JAL による redirect (BTB ミスの代金)、V3 は直接 target 違いの redirect (圧縮の代金)、partial は execute の分岐 mispredict の kill (間接 jump の target 違いを含む)。

| エントリ × (S, T) | W2 boot cy | 差 | hit | V5 | V3 | partial | W4 boot cy | 差 | hit | V5 | V3 | partial |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 4096 × (64, 64) 既定 | 14,633,581 | 0 | 98.24 % | 168,062 | 14 | 365,753 | 12,286,122 | 0 | 98.20 % | 218,684 | 22 | 316,090 |
| 4096 × (16, 24) | 14,617,854 | −0.11 % | 98.24 % | 167,782 | 4 | 364,054 | 12,286,739 | +0.01 % | 98.20 % | 219,038 | 5 | 316,100 |
| 2048 × (64, 64) | 14,831,303 | +1.35 % | 96.84 % | 194,468 | 30 | 378,672 | 12,450,343 | +1.34 % | 96.92 % | 251,171 | 17 | 328,174 |
| 2048 × (16, 24) | 14,831,429 | +1.35 % | 96.84 % | 194,462 | 14 | 378,714 | 12,450,207 | +1.34 % | 96.92 % | 251,176 | 1 | 328,845 |
| 1024 × (64, 64) | 15,323,283 | +4.71 % | 92.76 % | 254,826 | 13 | 423,399 | 12,980,195 | +5.65 % | 92.86 % | 304,014 | 18 | 372,214 |
| 1024 × (16, 24) | 15,322,993 | +4.71 % | 92.76 % | 254,827 | 1 | 423,399 | 12,980,636 | +5.65 % | 92.86 % | 304,012 | 7 | 372,203 |
| 1024 × (13, 20) | 15,667,291 | +7.06 % | 92.76 % | 249,528 | 1,686 | 459,006 | 13,367,565 | +8.80 % | 92.87 % | 295,597 | 8,102 | 406,248 |

bench (サイクル数。全点で pass、instret は同じ、`fell_back` は全 run で 0):

| エントリ | W2 dhrystone | W2 coremark | W4 dhrystone | W4 coremark |
|---|---|---|---|---|
| 4096 (圧縮の有無とも同じ値) | 268,712 | 381,237 | 204,902 | 315,613 |
| 2048 | 268,712 | 381,339 (+0.03 %) | 204,902 | 315,790 (+0.06 %) |
| 1024 | 268,712 | 381,307 (+0.02 %) | 204,902 | 315,747 (+0.04 %) |

読み方:

- **target の圧縮 (16, 24) は 3 つのエントリ数すべてで無損失** (boot の差は ±0.11 % 以内で、圧縮なしの同じエントリ数との差は 10,000 サイクル刻みの量子化と同程度)。census のとおり、外れうる学習は条件分岐の 6 回だけで、V3 (直接 target 違いの redirect) はどの点でも 2 桁以下である。
- **(13, 20) は損失が出る**: 1024 エントリの圧縮なしに対して boot +2.25 % (W2) / +2.98 % (W4)。V3 が 1,686 / 8,102 に増え、jump の 5.3 % が 2^20 を超える census と、`BR_CM` の full kill の増加 (W4 9,927 → 17,606) が代金である。圧縮の幅は census で決めてよく、(16, 24) が損失の出ない最小の目安になる。
- **エントリ数は効く**。4096 → 2048 で W2/W4 とも boot +1.35 %、1024 で +4.7 % / +5.7 %。hit は 98.2 → 96.8 → 92.8 % で、増えた V5 (予測の無い JAL を predecode が見つけた redirect) と partial (execute の mispredict) がそのまま代金になっている。commit 時の backstop (`BR_CM` の full kill) も 2,164 → 3,515 → 9,874 (W2) と増える。
- 旧 blkpred の測定 (1024 で 91.4 %、4096 で 96.2 % の boot coverage) と同じ形で、新しい表でも 4096 がまだ膝の手前にある。
- 7.1 boot は回していない (この間 box の負荷が 16 CPU に対して 50-110 で、sim の同時実行を 1 本に制限した)。

### 1.4 推奨 (判断待ち)

**推奨: エントリ数 4096 のまま、target を (S, T) = (16, 24) に圧縮し、bit 0 を持たない。** 1 エントリは W2 86 bit (V3 で valid を入れて 90 bit)、W4 110 bit (115 bit)。

| | W2 | W4 |
|---|---|---|
| payload の今 | 4096 × 225 = 921,600 | 4096 × 298 = 1,220,608 |
| 推奨 (bit 0 なし) | 4096 × 86 = 352,256 | 4096 × 110 = 450,560 |
| 節約 | 569,344 (−62 %) | 770,048 (−63 %) |
| V3 を入れた語 | 4096 × 90 | 4096 × 115 |
| 5.15 boot の代金 | −0.11 % (量子化の範囲) | +0.01 % |

理由:

1. 構造: 深さ 4096 は 2 の冪で、1R1W の macro (またはその bank 分け) に素直に乗る。幅 90 / 115 bit は、W2 は 96 bit 幅 1 個、W4 は 128 bit 幅 1 個に余りを残して収まる (余りは tag を広げるか、W4 の T を 32 にする予備に使える)。
2. 代金: target の圧縮は測った 3 つのエントリ数のすべてで無損失だった。エントリ数を減らす方は 2048 でも boot +1.35 % の性能が要る。圧縮だけで 62-63 % 減り、BTB は L2 のデータ (1 Mbit) の 1/3 程度になる。
3. 圧縮の方式は region 方式 (上位を lookup の pc から取る)。加算器が要らず予測の経路への影響が最小で、census で carry 方式や遠い target 用の別表が要らないことを確かめた。

判断待ちの選択肢:

- (a) 推奨点 4096 × (16, 24)。
- (b) さらに面積を取るなら 2048 × (16, 24) (W2 176,128、W4 225,280、元の 19 %)。代金は boot +1.35 % (W2/W4)。dhrystone/coremark は変わらない。
- (c) 1024 は boot +4.7-5.7 % で勧めない。
- T = 24 の余裕: 5.15 boot で 2^24 を超える jump は 0 回だが、カーネルの text が 16 MiB 境界をまたぐ構成や、共有ライブラリを跨ぐ間接 jump (PLT) では外れうる (正しさには影響せず、外れは execute の mispredict)。安全側に倒すなら W4 は T = 32 でも 128 bit 幅に収まる (123 bit)。
- `BTB_TAG_W` 16 → 12 (4096 エントリで 16,384 bit) は測っていない。推奨点で 1 run 測るかは判断待ち。
- 実装するときは `bp_btb` の `s_tgt`/`t_tgt` を [S-1:1] にし (足場では bit 0 も格納している)、既定値 `BTB_STGT_W`/`BTB_TTGT_W` を変える。V3 (valid を語に入れて掃き出す) と同じ変更にまとめると、`bp_btb` の配列は 1 語の 1R1W になる。

## 2. 同種の無駄の棚卸し (Task 2)

対象は inventory の約 2 Kbit 以上の配列 (W2 / W4)。見たもの: (a) 64 bit の pc、アドレス、target を必要以上の幅で持つもの、(b) 複数の構造に同じ値を持つもの、(c) 測らずに決めたエントリ数、(d) 承認済みの MS の修正で不要になる複製、(e) 必要より大きい構成値から導いた幅。

前提の確認:

- 仮想アドレスは Sv39 だけ (`csr.veryl:705`、satp の MODE は BARE と SV39)。H 拡張の G-stage は Sv39x4 なので GPA は 41 bit。物理アドレスは 56 bit で decode する (`pma_pkg.veryl:8`、`type Pa = logic<56>`)。M モードと BARE の pc は物理アドレスなので、**pc の幅は PALEN で決まる** (PALEN 56 なら 57 bit = 56 + 不正アドレスを不正のまま保つ 1 bit。spec は xepc と xtval について「不正なアドレスは別の不正なアドレスに変えてよい」)。
- pc を ROB と IQ に持たない設計はすでにできている (`RobEnt`、`IqCold` は `ftq` + `foff` で、pc は FTQ にだけある)。(b) の重複は下の G と I の範囲に限られる。
- inventory の訂正: `vu_adapter.lastm_q` (32 × 64) は `#[ifdef(HELIODOR_CHK)]` の中にあり (`vu_adapter.veryl:216-221`)、合成されない。inventory の §1.5 の行は消してよい。

### 2.1 一覧 (W4 の節約順)

**どの行も判断待ち**。「節約」は bit 数 (W2 / W4)。重なりは inventory の §2.3 の V 番号 (承認済みの MS の修正) との関係。

| # | 配列 | 今 | 提案 | 根拠 | 節約 (W2 / W4) | リスク | 重なり |
|---|---|---|---|---|---|---|---|
| A | `bp_btb` payload | 4096 × 225 / 298 | §1.4 | §1 の sweep | §1.4 | §1.4 | V3 (valid を payload の語に入れる。幅の勘定は §1.1 の「+ valid」) |
| B | PALEN (系の決定) | 56 bit | 40 bit (DRAM は 0x8000_0000 から。1 TiB の物理空間) | Rocket/BOOM 32-36、XiangShan 36-48。今の SoC の memory map は 2^32 未満 | L2 tag 163,840 (V2 の後 32,768)、dcache tag 24,576 / 28,672、icache tag 8,192、lq/sq/sb の line 1,664 / 3,328、TLB の ppn 768、pmpaddr 256。合計 199,296 / 205,056 (V2 の後 68,224 / 73,984)。C を含まない | 中。SoC の param (memory map) と `pma_pkg::Pa` を一緒に縮める。PMA の decode と pmpaddr の WARL、`satp.PPN` の WARL が変わる。ACT4 の PMP テストが pmpaddr の書けない上位 bit を想定どおりに扱うかを確かめる | V2 (L2 tag の複製が 1 組になると L2 分が 1/5)。下の I の前提 |
| C | L2 tag (`l2cache.tag_*`、`u_l2tag_*` の 4 組) | 49 bit = addr[63:15] | 41 bit = PA[55:15] | アドレスの上位 8 bit は PA の外で常に 0 (dcache の tag 44 bit と icache の 43 bit はすでに 56 bit の PA から導いている。L2 だけが 64 bit から) | 81,920 (V2 の後 16,384) / 同じ | 低。比較の幅が減るだけ | V2、V1。L2 の RTL は CBO の作業と同じファイルなので、`phase15/ms` の CBO を入れた後に行う |
| D | dcache tag 複製 (`dcache_tagbank`、TC_N = MEM_W + 5 = 6 / 7 組) | 6 / 7 × 4 way × 64 × 44 | 読み手のうち inv、inv2、probe、victim、write の 5 組を 2 組に時分割する (案) | 5 つの読み手は同じサイクルの C/L 読みだが、port の読み (MEM_W 組) と違って毎サイクル要るわけではない | 33,792 / 33,792 | 高。dcache の内部の時間関係が変わる。メモリ系なので N=4 boot、litmus N=4 が必須。測定してから決める (今回は未測定) | V8 (書きの移動) と同じ配列 |
| E | `rob.obs_q` (64)、`RobEnt.insn` (32) | 96 × 64 / 128 | retire record 専用なので define (例 `HELIODOR_RETIRE`) の中に入れ、合成では消す | `rob.veryl:151`、`core_types.veryl:597` のコメントのとおり観測専用。機能の論理は読まない (`commit.veryl` の `c.ent.insn` は retire record と `HELIODOR_CHK` の中だけ) | 6,144 / 12,288 | 低 (機能)。tb は golden lockstep で retire record を使うので、`Veryl.toml` の `[test].defines` に入れる。合成のトップが `o_retire` を残す限り、define が無いと消えない | V7 (同じ配列の書きの移動) |
| F | `exc_pkg::ExcRec` を持つ queue (`lq.e_xexc`、`sq.e_xexc`、FBQ、DQ の `XOp.exc`、RQ の `DecOp.exc`) | 142 bit / 記録 (tval 64、gpa 62) | tval を持たず、pc / va / insn からの選択子 (2 bit) で commit 時に作る。gpa を 39 bit (Sv39x4 の GPA 41 bit >> 2) にする | tval の出所は pass の va (`mem_pipe.veryl:565`、`ptw.veryl:637`)、pc か pc + 2 (`extract.veryl:319-401`、`ifu.veryl:202`)、命令 (`decode.veryl:625`) で、どれも同じエントリか ROB/FTQ にある。htval は spec 上 0 でもよい (GPA が 41 bit を超える不正なものは 0 にできる) | 85 bit × 記録数 (64 / 124) = 5,440 / 10,540 | 中。trap の tval の組み立てを commit 側に移す。tval の ACT4 テスト (misaligned、page fault、H の guest page fault) が回帰の判定 | V10 (`lq.e_xexc` を R に残す理由の記録)。縮めると V10 の行は T_R 未満になる |
| G | `rob.res_q.next_pc` | 64 × 64 / 128 | 持たない。taken の BRU op の next_pc は FTQ の最終予測 (`FtqRead.pred.target`)、not-taken は pc + len | commit は BRU op の next_pc で pc を進める (`commit.veryl:341,394`)。BRU op が taken なら block の exit であり、mispredict なら FTQ の res が resolve で正しい target に直る。同じ値が FTQ にある | 4,096 / 8,192 | 中。commit の pc の連鎖が FTQ の読み口に依存する (読み口の数か時間関係が変わる)。GL-B の lockstep で判定できる | V7 |
| H | `lq.e_lm0`、`e_lm1` (line 内の byte mask) | 128 × 32 / 64 | 持たない。va[5:0] と size (`e_op`) から比較のたびに作る | 値は va と size の関数 | 4,096 / 8,192 | 中。順序違反の CAM の各エントリに 64 bit の decoder が入り、比較の経路が延びる。F 区分の配列なので面積は FF 128 個 vs decoder | なし |
| I | pc / VA を持つ field の幅 (FTQ の `e_start`、`e_pred.target`、`e_res.target`、ckpt の RAS top、`bp_ras.stk_q`、FBQ の `start_pc` と `pred.target`、DQ の `XOp.pc`、`lq.e_va`、`sq.e_va`) | 64 bit | PCW = max(PALEN, 41) + 1。PALEN 40 なら 42 bit、56 なら 57 bit | §2 の前提。Sv39 の VA は 39 bit の符号拡張、GPA は 41 bit | PCW 42: 4,576 / 6,160。PCW 57: 1,456 / 1,960 (G と A を除く) | 中。core 全体の型 (`logic<64>` の pc) を `logic<PCW>` に変える広い変更。不正アドレスの trap (tval と xepc の値) の扱いを spec の「別の不正アドレス」で揃える | B (PCW は PALEN で決まる) |
| J | FTQ の ckpt の RAS top (`RasCkpt.top`) | 64 × 32 | 持たず、tos だけを戻す (BOOM と同じ) | 投機 push が top を上書きしたときだけ回復後の return 予測を外す (精度だけ) | 2,048 / 2,048 | 低 (正しさ)。性能は未測定: boot の return の mispredict を測ってから決める | なし |
| K | `sq.e_data` の上位 64 bit | 128 × 16 / 32 | amocas.q の上位だけを 1 本の別レジスタに置く | 上位を使うのは 16 byte の store (amocas.q) だけ (`sq.veryl:171`) | 1,024 / 2,048 | 低-中。amocas.q を同時に 1 本に限る規則が要る (atomic はもともと head で 1 本ずつ) | なし |
| L | `csr.mhpmevent` | 32 × 64 | WARL で実装する bit だけ (select 4、OF、MINH/SINH/UINH/VSINH/VUINH 5 の 10 bit) × 29 | `csr.veryl:312` (select は 4 bit で event は 8 個) | 1,758 / 1,758 | 低 (WARL)。計数器の本数を 29 から減らす案 (21 本で 1,344 bit) は ACT4 の Zihpm/Sscofpmf のテストへの影響を確かめてから | なし |
| M | `bp_ras.stk_q` の深さ | 16 / 32 (= 8 × FETCH_W) | W4 を 16 にする案 | 測っていない (§3.3 の sweep の表に無い)。return の mispredict で判断する | 0 / 1,024 | 低 | I (幅) |
| N | `csr.pmpaddr` | 16 × 64 | 54 bit (PA[55:2]) | spec の pmpaddr は PA の幅で WARL | 160 / 160 | 低 | B |

### 2.2 測らずに決めたエントリ数

M3 の手順 7 で sweep したもの (`ROB_N`、`LQ_N`/`SQ_N`、`SB_N`、`FTQ_N`、`PRF_*`、`NUM_CKPT`、`DTLB_N`、`DC_NB`、IQ。`doc/phase15_core_design.md` §3.3) は対象外にした。残る未測定は次の 4 つで、`BP_BTB_N` は §1 で測った。

| 定数 | 値 | 出所 | 扱い |
|---|---|---|---|
| `BP_BTB_N` | 4096 | 旧 blkpred (offset だけの表) の値 | §1 |
| `BTB_TAG_W` | 16 | `bpu_pkg.veryl` のコメント「untuned starting values」 | 4096 エントリで 12 bit にすると 16,384 bit (W2/W4)。false hit は lookup あたり 2^-12 で、extract が検査する。§1 の推奨点で 1 run 測る価値がある (判断待ち) |
| `BP_RAS_N` | 16 / 32 | 8 × FETCH_W | 表の M |
| `ITLB_N` | 16 | 旧 mmu のリテラル (§3.3 で「sweep せず」) | 16 × 123 = 1,968 bit で 2 Kbit 未満。CAM なので対象外 |

### 2.3 合計と判断が要る点

リスクが低-中で測定の要らない提案 (A の推奨点、C、E、F、G、H、J、K、L、N) を全部入れた場合:

| | W2 | W4 |
|---|---|---|
| A (BTB 4096 × (16, 24)) | 569,344 | 770,048 |
| C、E、F、G、H、J、K、L、N | 106,686 | 127,146 |
| 合計 | 676,030 | 897,194 |

系の決定や測定が要る追加分: B (PALEN 40) +199,296 / +205,056 (V2 の後は +68,224 / +73,984)、I (PCW 42、B が前提) +4,576 / +6,160、D (dcache tag の複製を 2 組減らす) +33,792、M (W4 の RAS 16) +1,024、`BTB_TAG_W` 12 +16,384。

ユーザの判断が要る点:

1. BTB: §1.4 の (a) / (b) / (c)、T を 24 にするか 32 にするか、tag 12 bit を測るか。
2. PALEN を 56 のまま残すか、40 などに縮めるか (B、I、N がこれで決まる)。memory map は SoC の param なので、PALEN を SoC の param にする案も含む。
3. retire record 専用の field (E) を define で合成から外す方針にするか (外すなら define の名前と、tb の既定に入れること)。
4. 中リスクの F、G、H を MS で入れるか、MS の後に回すか。どれも正しさの判定は既存のゲート (ACT4 の trap の tval、GL-B の lockstep、litmus と boot) で足りる。
5. D (dcache tag の複製) を調べるか。測定と設計が要り、MS の中で最も高いリスクの変更になる。
6. 順序: C は L2 の RTL (CBO の作業と V1/V2 の作り直し) と同じファイルなので、`phase15/ms` の CBO が入った後に V2 と一緒に行う。A は V3 と一緒に行う。
