# Phase 15 MS: 配列の棚卸しと分類規則 (手順 1、2)

設計書 §MS の手順 1 (棚卸し) と手順 2 (分類の規則) の成果物。手順 2 の規則と閾値、違反の直し方、Design Compiler を足すかは **判断待ち** (ユーザが決める)。本書は RTL を変えていない (`phase15/ms`、`e5b77300` の時点のソース)。

## 0. 方法

- 出典はソースだけである。旧コアの `doc/sram_inventory.md` は分類の出発点にしたが、数値は使っていない。`veryl synth --dump-area` (旧コアで使った推論の自動一覧) は新コアで `unsupported construct: dynamic range select` により止まるので使えない。
- `src/` (`src/v14/` を除く) の `var` の配列宣言を全数抜き出した: 823 個。そのうち `always_ff` で書かれる記憶が 263 個で、残りの 560 個は lane ごとの組合せの配線である。記憶の 263 個を、モジュールを読んで下の表にまとめた (同じ index と同じ口を持つ field の配列は 1 行にまとめ、way ごとの複製は「個数」に数える)。
- 幅は、構造体を含むものは Verilator で `$bits` を W2 と W4 の両方のパッケージについて取った。構成値は `cfg_w2`/`cfg_w4` と §3.3 の表。
- 対象外: `src/v14/` (凍結)、`src/mmu/` (旧 MMU。新 SoC は instantiate しない。`tb/test_mmu.veryl` だけが使う)、`src/peripheral/axi4_sram.veryl` (`tb/test_axi4.veryl` だけが使う)、`chk_*` と `#[ifdef(HELIODOR_CHK)]` の中の配列 (`rob.src_q`、`prf` の観測読み出しなど。合成のファイル一覧は `HELIODOR_CHK` を定義しない前提)。

### 0.1 表の記号

- **R / W**: 独立したアドレスで同じサイクルに読む口と書く口の数。
  - `E`: エントリごとの書き込み enable (各エントリが自分の条件で書かれる。同じサイクルに何エントリでも書ける)。括弧内は、そのサイクルに実際に書きうる源の数。
  - `A`: 連想読み (毎サイクル全エントリを比べる、または全エントリを並べて選ぶ)。
  - `row`: 1 行に全 field をまとめて読み書きする (行幅の 1 口)。
- **読みの型**:
  - `S`: 同期読み。アドレスはレジスタ (または macro 内のアドレスレジスタに相当する)、データは次のサイクルに使う。
  - `C/R`: そのサイクルの組合せアドレスで読み、データはレジスタにだけ入る (途中にマルチプレクサがあってもよい)。レジスタを macro の中へ移せば `S` と同じ時間関係になる。
  - `C/L`: そのサイクルの組合せアドレスで読み、同じサイクルの論理 (比較、選択、判定) が使う。
- **リセット**: `有` は `if_reset` で全エントリを初期化する。`無(rb)` はリセットしないが、非同期リセット付きの `always_ff` (`if_reset { } else { ... }`) の中で書く。生成 SV は `always_ff @(posedge clk, negedge rst)` になり、FPGA では RAM 推論を妨げ、ASIC ではリセットを書き込み enable に混ぜる。`無` はリセットの無い `always_ff` で書く。
- **容量**: 1 個あたりの bit 数 (W2 / W4)。N は hart 数。

## 1. 棚卸し

### 1.1 フロントエンド

| 配列 (module.signal) | 個数 | エントリ × 幅 (W2 / W4) | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 備考 |
|---|---|---|---|---|---|---|---|
| `bp_btb` payload (`tagv`, `s_off`, `s_ctr`, `s_tgt`, `t_off`, `t_knd`, `t_rvc`) | 1 | 4096 × 225 / 298 | 921,600 / 1,220,608 | 1 / 1 | S (`lk_pc_q` から) | 無 | 書きは field ごとの enable (slot ごとの ctr と target)。W4 は slot が 2 から 3 に増え、FOFF_W が 3 から 4 になる |
| `bp_btb` valid (`vld`, `s_v[slot]`, `t_v`) | 1 | 4096 × 4 / 5 | 16,384 / 20,480 | 1 / 1 | S | 有 | 全エントリのリセット |
| `bp_ras.stk_q` | 1 | 16 / 32 × 64 | 1,024 / 2,048 | 1 / 1 | C/L | 無 | |
| `ftq.e_*` (start 64, pred 71/72, meta 17/27, ckpt 68/69, pd 32/64, res 71/72, last 3/4) | 1 | 32 × 326 / 372 | 10,432 / 11,904 | 4 / E(3) | C/L | 無 | field ごとに読みの口数が違う (start 4、pred/pd/res 3、meta/ckpt 2) |
| `icache_array.data_0..3` | 4 (way) | 256 × 256 | 65,536 | 1 / 1 | C/R | 無 | 読みは `i_req.pa` (cycle A)。way は同じサイクルの tag 比較で選んでから読む。書きは 64 bit の slot mask の RMW 形 |
| `icache_array.tags_0..3` | 4 (way) | 128 × 43 | 5,504 | 1 / 1 | C/L | 無 | |
| `icache_array.valid_0..3` | 4 | 128 × 1 | 128 | 2 / 2 + 一斉クリア | C/L | 有 | FENCE.I で全エントリを 0 にする |
| `icache_array.plru` | 1 | 128 × 3 | 384 | 1 / 2 | C/L | 有 | |
| `icache.ubuf_q` | 1 | 2 / 4 × 64 | 128 / 256 | A / 1 | — | 無 | |
| `lane_queue.buf_q` (`ifu` FBQ, FetchBlk) | 1 | 4 × 440 / 629 | 1,760 / 2,516 | 1 / 1 | C/L | 無 | |
| `lane_queue.buf_q` (`extract` DQ, XOp) | 1 | 8 / 16 × 265 / 266 | 2,120 / 4,256 | FW / E(FW) | C/L | 無 | 口数は lane 数 (W2 2、W4 4) |
| `lane_queue.buf_q` (core RQ, DecOp) | 1 | 4 / 8 × 278 / 279 | 1,112 / 2,232 | RW / E(RW) | C/L | 無 | |

### 1.2 rename、スケジューラ、レジスタファイル

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 備考 |
|---|---|---|---|---|---|---|---|
| `rename.spec_q` | 1 | 64 × 7 / 8 | 448 / 512 | A / E | C/L | 有 | 投機 RAT |
| `rename.arch_q` | 1 | 64 × 7 / 8 | 448 / 512 | A / E | C/L | 有 | |
| `rename.img_q` (checkpoint) | 1 | 4 / 8 × (64 × 7 / 8) | 1,792 / 4,096 | 1 row / 1 row | C/L | 無(rb) | 1 行 = RAT 全体の像。書きも読みも行単位 |
| `rename.own_q` | 1 | 4 / 8 × 7 / 8 | 28 / 64 | A / E | — | 有 | |
| `free_list.ent_q` (int) | 1 | 64 / 128 × 7 / 8 | 448 / 1,024 | RW / CW | C/L | 有 | 初期値 (空きの物理レジスタ番号) が要る |
| `free_list.ent_q` (fp) | 1 | 32 / 64 × 7 / 8 | 224 / 512 | RW / CW | C/L | 有 | |
| `iq` (`st_q`, `port_q`, `tag_q`, `fu_q`, `sen_q`, `spr_q`, `srdy_q`, `barw_q`) | 2 / 3 | 24, 16 / 32, 24, 24 × 約 60 | 約 1,500 / 約 1,900 | A / E | C/L | 一部有 | wakeup の比較 (`spr_q`) と選択は全エントリ |
| `iq.cold_q` | 2 / 3 | 同上 × 64 / 67 | 1,536, 1,024 / 2,144, 1,608, 1,608 | 発行ポート数 / E | C/L | 無 | 発行時に選んだエントリから読む |
| `prf.rf_q` (int) | 1 | 96 / 160 × 64 | 6,144 / 10,240 | 6+2 / 3 → 13+2 / 7 | C/L | 有 | R の +2 は VU の scalar 読み (§X.2 の表の外)。書きは WB ポート |
| `prf.rf_q` (fp) | 1 | 64 / 96 × 64 | 4,096 / 6,144 | 4+1 / 2 → 8+1 / 4 | C/L | 有 | |
| `vrf.vrf` | 1 | 32 × 128 | 4,096 | 4 / 1 | C/L | 有 | 全エントリを 0 にリセット |
| `exec_port.wl_q`, `hist_q` | ポート数 | 数エントリ | < 200 | 小 | — | 有 | |

### 1.3 ROB、commit、CSR、debug

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 備考 |
|---|---|---|---|---|---|---|---|
| `rob.ent_q` | 1 | 64 / 128 × 93 / 98 | 5,952 / 12,544 | 6 / E(2) → 12 / E(4) | C/L | 無(rb) | 読み = commit の CW + walk の 2 × WALK_W。書き = dispatch の RW lane |
| `rob.snap_q` | 1 | 64 / 128 × 36 / 42 | 2,304 / 5,376 | 1 / E(RW) | C/L | 無(rb) | |
| `rob.obs_q` | 1 | 64 / 128 × 64 | 4,096 / 8,192 | CW / E(WB_N + 1) | C/L | 無(rb) | WB_N は 3 / 8 |
| `rob.res_q` | 1 | 64 / 128 × 66 | 4,224 / 8,448 | CW / E(BRU 数) | C/L | 無(rb) | |
| `rob.ffl_q` | 1 | 64 / 128 × 5 | 320 / 640 | CW / E | C/L | 無(rb) | |
| `rob.done_q`, `rec_q` | 1 | 64 / 128 × 1 | 64 / 128 | CW / E | C/L | 有 | |
| `rob.walk_q` | 1 | RW × 14 / 15 | < 100 | — | — | 有 | |
| `commit.ret_q`, `rx_q`, `pc` | 1 | CW × 小 | < 1,000 | — | — | 一部有 | |
| `csr.mhpmcounter` | 1 | 32 × 64 | 2,048 | A / E | — | 有 | 各カウンタが毎サイクル独立に増える |
| `csr.mhpmevent` | 1 | 32 × 64 | 2,048 | 3 / 2 | C/L | 有 | |
| `csr.pmpaddr`, `pmpcfg` | 1 | 16 × 64, 2 × 64 | 1,024, 128 | A / 1 | — | 有 | PMP 照合は全エントリ |
| `trig_unit.tr_q` | 1 | 2 / 4 × Trig | < 600 | A / 1 | — | 有 | |

### 1.4 LSU と dcache

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 備考 |
|---|---|---|---|---|---|---|---|
| `lq.e_*` (va 64、line0/1 50+50、lm0/1 64+64、ex、op、sqlim、key、fid、dw、flags) | 1 | 32 / 64 × 約 345 | 約 11,000 / 約 22,000 | A / E(MEM_W + 1) | C/L | 無(rb) | 順序違反の検出と wakeup は全エントリの比較。field ごとの最大は `e_lm0`/`e_lm1` の 2,048 / 4,096 |
| `lq.e_xexc` | 1 | 32 / 64 × 142 | 4,544 / 9,088 | 1 / E | C/L | 有 | 読みは `rsel_q` だけ |
| `sq.e_*` (rob、lqlim、op、va、line0/1、dw0、m16、data 128、flags) | 1 | 16 / 32 × 約 348 | 約 5,600 / 約 11,100 | A / E(MEM_W + 1) | C/L | 無(rb) | forwarding は全エントリの比較 |
| `sq.e_xexc` | 1 | 16 / 32 × 142 | 2,272 / 4,544 | 1 / E | C/L | 有 | |
| `sb.e_line`, `e_data`, `e_strb` | 1 | 8 / 16 × 626 | 5,008 / 10,016 | A / E | C/L | 無(rb) | forwarding と write-combining (RMW) は全エントリ。最大の field は `e_data` 4,096 / 8,192 |
| `atomic_unit.preg_q`, `cval_q`、`mem_port_arb`、`ptw.q_*` | 各 1 | 数エントリ | < 600 | 小 | — | 一部有 | |
| `tlb.ent_q` (D) | 1 | 32 × 123 | 3,936 | A / 1 | — | 無 (v_q は有) | 全エントリの比較 |
| `tlb.ent_q` (I) | 1 | 16 × 123 | 1,968 | A / 1 | — | 無 (v_q は有) | |
| `dcache_bank.mem_q` (data) | DC_NB = 2 / 4 | 64 × 1,024 / 512 | 65,536 / 32,768 | 1 / 1 | S | 無 | 行 = 1 set の全 way の、その bank の dword。書きは byte mask の RMW 形。読み出しレジスタは同じ行への書きを前方転送する |
| `dcache_tagbank.tags_0..3` (dcache の tag 複製) | 4 (way) × TC_N = 6 / 7 | 64 × 44 | 2,816 | 1 / 1 | C/L | 無(rb) | 読み手ごとの複製 (TC_N = MEM_W + 5)。合計 67,584 / 78,848 |
| `dcache_tags.valid_q`, `excl_q`, `dirty_q` | 各 1 | 64 × 4 | 256 | TC_N / 1 + CLR_N 5 + MRK_N 2 | C/L | 有 | |
| `dcache_tags.plru_q` | 1 | 64 × 3 | 192 | TC_N / MEM_W + 1 | C/L | 有 | |
| `dcache_mshr.*` | 1 | MSHR_N = 2 × 小 | < 300 | A / E | — | 一部有 | |
| `dcache.wb_data_q`、`s1_*`、`resp_q` | 1 | 8 × 64、MEM_W × 小 | 512 他 | — | — | 一部有 | |

### 1.5 VU

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 | R / W | 読みの型 | リセット | 備考 |
|---|---|---|---|---|---|---|---|
| `vector_unit.fifo_*` (op、instr、vd/vs1/vs2、pdst、tag ...) | 1 | 8 × 約 140 | 約 1,100 | 1 / 1 | C/L | 有 | 命令 FIFO。W2 と W4 で同じ |
| `vu_adapter.lastm_q` | 1 | 32 × 64 | 2,048 | 1 / 2 | C/L | 有 | |
| `vrf.vrf` | 1 | 32 × 128 | 4,096 | 4 / 1 | C/L | 有 | (1.2 に再掲) |

### 1.6 SoC (L2、mem_ctrl、AXI、周辺、debug module)

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 | R / W | 読みの型 | リセット | 備考 |
|---|---|---|---|---|---|---|---|
| `l2cache.data_0..3` | 4 (way) | 512 × 512 | 262,144 | 1 (+2) / 1 (+2) | C/R | 無(rb) | 既定 (`L2_SYNC_READ = 1`、`L2_PORTS_1R1W = 1`、`L2_READ_1R1W = 0`) で生きている口は、lookup の読み 1 (`c_index`、結果は `c_line_q`) と書き 1 (merge と install を 1 口に束ねた byte mask の RMW 形)。括弧内は const で死んでいるが生成 SV に残る口 (`w_index` の merge 読み、`rd_index` の spec 読み、merge と install の別々の書き)。way は同じサイクルの tag 比較 (`ctm_*`) で選んでから読む |
| `l2cache.tag_0..3` (install 用) | 4 (way) | 512 × 49 | 25,088 | 1 / 1 | C/L | 無(rb) | |
| `dcache_tagbank` (L2 の tag 複製 `u_l2tag_e`、`_c`、`_w`、`_nxt`) | 4 (way) × 4 | 512 × 49 | 25,088 | 1 / 1 | C/L | 無(rb) | install 用と合わせて tag は 5 組 (way あたり 125,440 bit、合計 501,760 bit) |
| `l2cache.lv_0..3` | 4 | 512 × 1 | 512 | 5 / 4 | C/L | 有 | |
| `l2cache.own_0..3` | 4 | 512 × 1 | 512 | 4 / 6 | C/L | 有 | |
| `l2cache.shr_0..3` | 4 | 512 × N | 512 × N | 4 / 6 | C/L | 有 | |
| `l2cache.plru` | 1 | 512 × 3 | 1,536 | 3 / 4 | C/L | 有 | |
| `mem_ctrl.buf_q` (slot ごと) | 2N + 1 | 8 × 64 | 512 | 2 / 1 | C/L | 有 | slot の gather buffer |
| `mem_ctrl.wb_data`、`wb_strb` | 1 | 8 × WB_N × (64 + 8) (WB_N = 2N) | 1,152 × N (N = 1 で 1,152、N = 4 で 4,608) | 1 / 1 row | C/R (`wb_w` と `w_lane` は登録済み) | 有 | AXI の書き込みバッファ。`wb_v`、`wb_line`、`wb_lo`、`wb_hi` は小さい制御 |
| `mem_ctrl.acc_wait_q` ほか | slot 数 | 小 | < 100 | — | — | 有 | |
| `memory_bus` | — | — | — | — | — | — | 記憶の配列は無い (選択器だけ) |
| `clint.mtimecmp`、`msip` | 1 | N × 64、N × 1 | 64N | 2 / 2 | C/L | 有 | |
| `plic.prio`、`enable`、`threshold`、`claimed` | 1 | 32 × 3、2N × 32、2N × 3、2N × 5 | < 600 | A / 小 | — | 有 | |
| `dm.pbuf_q`、`hgrp_q`、`rgrp_q` | 1 | 8 × 32、N × 小 | 256 他 | 2 / 2 | C/L | 有 | progbuf |

`dm_mem` の ROM (`dm_rom_pkg`) は定数の関数で、記憶の配列ではない。

### 1.7 W2 と W4 で口数か読みの型が変わるもの

| 配列 | W2 | W4 |
|---|---|---|
| `prf.rf_q` (int / fp) | 6+2 R 3 W / 4+1 R 2 W | 13+2 R 7 W / 8+1 R 4 W |
| `rob.ent_q` | 6 R、2 lane の書き | 12 R、4 lane の書き |
| `rob.obs_q` | 2 R、4 源の書き | 4 R、9 源の書き |
| `dcache_bank` | 2 bank × 1,024 bit の行 | 4 bank × 512 bit の行 (容量は同じ 128 Kbit) |
| `dcache_tagbank` (dcache) | 6 複製 | 7 複製 |
| `iq` | 2 個 (24, 16) | 3 個 (32, 24, 24) |
| `lane_queue` (DQ、RQ) | 2 lane の入出力 | 4 lane の入出力 |
| `bp_btb` payload | slot 2 (225 bit) | slot 3 (298 bit) |
| `rename.img_q` | 4 行 × 448 bit | 8 行 × 512 bit |

読みの型 (S、C/R、C/L、A) が W2 と W4 で変わる配列は無い。

### 1.8 集計

| 区分 (下の §2 の規則案で分類) | 行数 | 主なもの |
|---|---|---|
| S (SRAM マクロ) | 5 | `bp_btb` payload、`icache_array.data`、`dcache_bank`、`l2cache.data`、`l2cache.tag` と L2 の tag 複製 (4 組)。§2.3 の V3 を採れば `bp_btb` valid も S に入る |
| R (レジスタファイル) | 17 | `prf` (int/fp)、`vrf`、`rob` の payload 5 本、`ftq`、`rename.img_q`、`lane_queue` 3 種、`iq.cold_q`、`icache_array.tags`、`dcache_tagbank` (dcache)、`mem_ctrl.wb_data/wb_strb`、`lq.e_xexc`、`sq.e_xexc`、`vu_adapter.lastm_q`、`bp_ras` |
| F (FF) | 残り (約 35 行) | 連想読みの `lq`/`sq`/`sb`/`tlb`/`iq`/`pmp`、リセットや一斉クリアの要る valid、PLRU、カウンタ、ディレクトリのビット |

大きい順 (1 個あたり、W4): `bp_btb` payload 1.22 Mbit、`l2cache.data` 256 Kbit × 4、`icache_array.data` 64 Kbit × 4、`dcache_bank` 32 Kbit × 4 (W2 は 64 Kbit × 2)、`l2cache.tag` 25 Kbit × 4 × 5 組、`bp_btb` valid 20 Kbit、`rob.ent_q` 12.5 Kbit、`ftq` 11.9 Kbit、`prf` int 10 Kbit、`sb` 10 Kbit (F)、`lq.e_xexc` 9 Kbit。合計で見ると、旧コアの棚卸しに無かった `bp_btb` (新しいフロントエンドの BTB、W4 で 1.2 Mbit) が L2 のデータ (1 Mbit) より大きい。

## 2. 分類の規則 (提案、判断待ち)

### 2.1 3 つの区分

| 区分 | 定義 | 守ること |
|---|---|---|
| **S: SRAM マクロ** | 1RW か 1R1W のマクロ 1 個 (または bank、way ごとの複数個) に置く配列 | (S1) 口は 1RW か 1R1W。読み手が 2 つ以上なら bank 分け、時分割、複製のどれかで 1 口にする。(S2) 同期読み: アドレスはクロック端で取り込まれ (macro 内のアドレスレジスタ)、データは次のサイクルに使う。`C/R` は可 (レジスタを macro の中に移せる形)。`C/L` は不可。(S3) リセット無し。valid などリセットの要るビットは S の外の F に置くか、リセット後の掃き出し (掃除用の FSM で全行に書く) か世代番号で初期化する。(S4) 書きはリセットの無い `always_ff` で、1 つの書き込み文にまとめる。部分書きは byte (FPGA) か bit (ASIC) の書き込み enable で書けるコード形にする。(S5) 同じ行への読みと書きが同じサイクルに起きたときの値 (read-old / read-new / 前方転送) をモジュールヘッダに書く |
| **R: レジスタファイル** | FF と書き込み decoder と読み出し mux で作る、多ポートの小さい配列 (§5.15) | (R1) 容量は閾値 T_S 未満。(R2) 読みは組合せでよい。(R3) payload はリセットしない。リセットの要るビット (valid、x0 の 0) は F に分ける。(R4) 書きはリセットの無い `always_ff` で書く (FPGA で LUTRAM に、ASIC でリセットの無い FF にする) |
| **F: FF** | 連想読み、一斉クリア、毎サイクルの独立更新 (カウンタ)、リセットが機能上要るもの、または小さいもの | (F1) 容量は閾値 T_S 未満 |

### 2.2 閾値

- **T_S = 16 Kbit (1 個の配列あたり)**: これ以上で深さ 64 以上の配列は S でなければならない。R と F は T_S 未満に限る。
- **T_R = 4 Kbit**: 4 Kbit 以上 16 Kbit 未満で、深さ 64 以上、口が 1R1W に収まる配列は S を推奨し、R にするなら理由を本書に記録する。
- 4 Kbit 未満、または深さ 64 未満は R か F。

理由:
1. FPGA: 7 系列の block RAM は 1 個 18 Kbit (RAMB18)。16 Kbit 以上を FF で作ると、xc7a35t 級の FF 数 (約 4 万) の半分近くを 1 配列が使い、D12 で見た「FF への展開と 70 分の elaboration」が再発する。LUTRAM (分散 RAM) は深さ 64 以下で効率が良く、R 区分の多くはそこに入る。
2. ASIC: 28 nm 級で FF 1 bit (書き込み mux を含む) は SRAM の bit cell の 20-40 倍の面積を取る。SRAM マクロは周辺回路の固定費があるので、数 Kbit 以下では FF の RF の方が小さく速い。損益分岐はおおむね 2-8 Kbit で、16 Kbit では明確に SRAM が有利。旧コアの棚卸しでも「32 エントリは SRAM コンパイラの最小 (64-128 語) より小さい」を理由に TLB を FF に残した。
3. 多ポートで同期読みにできない構造 (PRF、ROB の payload、wakeup の CAM) は、実在のコアでも FF の RF か latch 配列で作る。その最大 (W4 の `rob.ent_q` 12.5 Kbit、`prf` int 10 Kbit) が 16 Kbit 未満に収まるので、T_S = 16 Kbit なら構成を大きくしない限り R と F は破れない。W4 を将来広げる (ROB 256 など) と `rob.ent_q` が T_S を超えるので、そのときは lane ごとの bank 分けが要る。
4. 単位を「1 個の配列」(同じ index と同じ口を持つ field の束) にしたのは、`rob` のように口の違う field (dispatch で書く `ent_q` と WB で書く `obs_q`) を足し合わせると、実在しない「巨大な多ポート配列」を作ってしまうため。

判断待ち: T_S と T_R の値 (16 Kbit / 4 Kbit)、単位の決め方、`C/R` を S の同期読みとして認めるか。

### 2.3 規則を当てた結果: 違反の一覧と直し方

| # | 配列 | 区分 | 違反 | 直し方の案 | リスク |
|---|---|---|---|---|---|
| V1 | `l2cache.data_0..3` (D12 と §MS が名指し) | S | S2: way を同じサイクルの tag 比較で選んでから読む。S3/S4: 非同期リセット付きの `always_ff` の中で書く。S4: 書きが RMW 形 (`(data & ~msk) \| (new & msk)`)。死んだ口 (`L2_READ_1R1W` の spec 読み、`!L2_PORTS_1R1W` の merge 読みと 2 本の書き) が生成 SV に残る | データ配列を `dcache_bank` と同じ形の 1R1W のモジュール (リセットの無い書き、byte enable の書き、登録済みの読み) に出し、4 way を同じ index で並列に読んで、登録済みの `ctm` で次のサイクルに選ぶ。merge は byte enable の書き込みで行うので古い行の読みは要らない。死んだ scaffold (`L2_READ_1R1W`、`L2_PORTS_1R1W = 0` の枝、`w_old_line`、`w_merged_line`) を消す。V14 の `v14_*` が共有するインタフェースを変える場合は D13 に従って V14 側も `veryl check` を通す | mem_ctrl の HIT_WAIT がすでに 1 サイクルの読みを隠しているので、サイクルは変わらない見込み。L2 の書き込みの原子性 (merge と install が同じサイクルに来ない、SoC の `wgrant_ok`) は今の規則のまま。ゲートは G0、N=2 boot、litmus N=4、N=4 boot (メモリ系の変更) |
| V2 | `l2cache.tag_0..3` と L2 の tag 複製 4 組 | S (25 Kbit / way、深さ 512) | S2: 読みが C/L (lookup、install、engine、write、misaligned の各経路が同じサイクルにヒット判定を使う)。S3/S4: リセット付きの `always_ff` で書く。複製が 5 組で、tag の総量は 490 Kbit とデータの半分近い | 案 a (推奨): L2 の作り直しで tag の読みを 1 段パイプラインにし、tag と directory (`lv`、`own`、`shr`) を 1 語にまとめた way ごとの 1RW (または 1R1W) マクロ 1 組にする。mem_ctrl の各経路 (lookup、install、engine、write、misaligned) は 1 本の tag ポートを調停する (同じ line の直列化は今の per-line 規則がすでに持つ)。案 b: tag を R に分類し直す (閾値の例外)。案 b は 25 Kbit × 5 組の FF で、T_S を破る | 案 a は mem_ctrl の LOOKUP と write grant の時間関係が変わる。SMP の一貫性 (recall、veto、per-line の直列化) に触れるので、litmus N=4 と N=4 boot が必須。MS で最も大きい変更 |
| V3 | `bp_btb` valid (`vld`、`s_v`、`t_v`) | F (16 / 20 Kbit) | F1: T_S 以上の F。全エントリのリセット | valid を payload の語に入れて S にし、リセット後に 4096 行を掃き出す FSM (4096 サイクル、その間は予測しない) か、2-3 bit の世代番号で無効化する。予測は正しさに影響しない (extract が全予測を検査する) | 低い。サイクル数はリセット直後だけ変わる (掃き出しの間は予測が無い)。GL-B の record 列と hash は変わらない見込み (予測は retire 列に出ない) |
| V4 | `icache_array.data_0..3` | S | S2: way を同じサイクルの tag 比較で選んでから読む (C/R だが way 選択が前)。S4: 書きが RMW 形 | 4 way を `blk_i` で並列に読み、tag のヒットで次のサイクルに選ぶ (応答はもともと 1 サイクル後なので遅延は変わらない)。書きを 64 bit の書き込み enable の形にする | 低い。`IC_RESP_LAT = 1` は変わらない |
| V5 | `rename.img_q` (§MS が名指し) | R | R4: リセット付きの `always_ff` の中で書く (書く文はリセットしない) | 書きをリセットの無い `always_ff` に移す。`ckv_q` と `own_q` はリセット付きのまま | 低い。値とサイクルは変わらない |
| V6 | `mem_ctrl.wb_data`、`wb_strb` (§MS が名指し) | R | R3: payload を非同期リセットで 0 にする | payload のリセットを消す (有効は `wb_v` が持つ)。書きをリセットの無い `always_ff` に移す | 低い。リセット直後の値を誰も読まないことを `wb_v` で確かめる |
| V7 | `rob.ent_q`、`snap_q`、`obs_q`、`res_q`、`ffl_q` | R | R4: リセット付きの `always_ff` の中で書く | V5 と同じ移動。`done_q`、`rec_q` はリセット付きの F として残す | 低い |
| V8 | `dcache_tagbank.tags_0..3` (dcache の複製) | R (2.8 Kbit) | R4: リセット付きの `always_ff` の中で書く | 移動だけ。L2 側の複製は V2 で消える | 低い |
| V9 | `prf.rf_q`、`vrf.vrf` | R | R3: payload を全エントリ 0 にリセットする | `prf`: x0 (int の pdst 0) だけを読み出し側で 0 に固定し、リセットを消す。`vrf`: リセットを消す。ただし v レジスタの初期値 0 に依存している tb (golden の lockstep、spike との cosim の初期状態) が無いかを先に確かめる | `vrf` は初期値の差が cosim と GL-B に出うる (判断待ち: 例外として残すか)。`prf` は低い |
| V10 | `lq.e_xexc` (W4 9 Kbit)、`icache_array.tags` (5.5 Kbit / way) | R (T_R 以上) | 違反ではない (推奨 S の帯)。R のままにする理由: `e_xexc` は E の書き (エントリごとの enable) で 1 口にまとまらない。icache の tag は C/L で、同じサイクルのヒット判定に要る | 記録だけ | — |

違反ではないが確かめが要るもの:
- `dcache_bank` (S): 書きが RMW 形で、読み出しレジスタの前方転送も mask を使う。Vivado が byte enable の 1R1W と認識するかは手順 4 の合成で確かめる。認識しなければ書き込みを byte ごとの `if` の形に書き換える (値は同じ)。
- F に分類した `lq`/`sq`/`sb` の payload はリセット付きの `always_ff` の中で書かれる (無(rb))。F なので規則違反ではないが、FPGA ではリセットを clock enable に混ぜる論理が増える。手順 3 のついでに移すかは判断待ち。

### 2.4 Vivado と Design Compiler (ツールの確認と提案)

| ツール | 場所 | 確認したこと |
|---|---|---|
| Vivado 2021.2 | `/storage/eda/tools/xilinx/Vivado/2021.2/bin/vivado` | sandbox の外で、64 × 32 の 1R1W の小さい例を `synth_design -mode out_of_context` (xc7a35t) にかけ、ライセンス取得 (`Synthesis`) と RAMB18 1 個への推論を確かめた。sandbox の中ではライセンスで止まる (§MS の記録どおり) |
| Design Compiler X-2025.06-SP2 | `/storage/eda/tools/synopsys/DC/X-2025.06-SP2/bin/dc_shell` | sandbox の外で `analyze`/`elaborate` が通り、メモリの推論 (`Inferred memory devices`) を報告した。セルライブラリは `/storage/eda/libs/common/arm/umc28hpcp/...` などの `.db` がある (`compile` までは試していない) |
| Verilator 5.050 | `~/local/bin/verilator` | 既存 |
| yosys | 無し | riscv-formal (§MV、D14) に要る。MS の後の作業で導入が要る |

提案 (判断待ち): 手順 4 で Vivado の out-of-context 合成に加えて、**Design Compiler で S 区分の配列をブラックボックスにした合成**を足す。
- やり方: 手順 3 で S 区分の配列をすべて共通のラッパ (`sram_1r1w`、`sram_1rw`。シミュレーション用の振る舞いモデルを持つ) に置き換え、DC ではラッパを black box にして `compile` する。ラッパは「S 区分の配列が他に無い」ことの機械的な検査にもなる (DC の `Inferred memory devices` に S 級の大きさのメモリが残れば規則違反)。
- 得るもの: ASIC で問題になる構造 (latch の推論、組合せループ、多重駆動、巨大な FF 配列) の検出と、R と F の実際の面積。Vivado は FPGA の推論しか見ないので、`C/R` を FPGA の block RAM の出力レジスタが吸収して ASIC で破綻するような差は DC でしか見えない。
- 代金: 合成スクリプトの保守、ライセンスの占有、実行時間 (SoC 全体で数時間の見込み、未測定)。ゲートの頻度は節目ごと (MS の出口と以後のメモリ系の変更) にする案。
- 足さない場合: Vivado の推論結果 (RAM と FF の内訳) だけを出口条件にし、ASIC の面積は記録しない。
