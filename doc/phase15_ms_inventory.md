# Phase 15 MS: 配列の棚卸しと分類規則 (手順 1、2)

設計書 §MS の手順 1 (棚卸し) と手順 2 (分類の規則) の成果物。手順 2 の規則と閾値、違反の直し方、Design Compiler を足すかは 2026-11-20 にユーザが決めた (各節の【決定】と設計書 §MS)。最初の棚卸しは `e5b77300` の時点のソースで取った。§1 は MS の出口の確認 (2026-11-23) で `fdecbf9f` のソースから取り直した表に置き換え、§2.3 に各違反の解消の commit を、§3 に出口の照合 (規則と Vivado の推論) を足した。

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

## 1. 棚卸し (出口の時点、`fdecbf9f`)

MS の出口の確認 (2026-11-23) で、`fdecbf9f` (本書の §2.3 の V1-V9 と、`doc/phase15_ms_logic.md` の論理の整理、D-2 (PALEN 40)、F、G、H、K を入れた後) のソースから取り直した。最初の棚卸し (`e5b77300`) の表は git の履歴にある。

- 方法: `src/` (`src/v14/` を除く) の `var` の配列宣言 815 個のうち、`always_ff` で書かれるもの 241 個を script で抜き出し、それぞれについて書く `always_ff` にリセットがあるか、リセットの枝で書くかを機械的に分類した。そのうえで記憶の配列をモジュールを読んで下の表にまとめた (`chk_*`、`#[ifdef(HELIODOR_CHK)]`、`HELIODOR_OBS` の中、`always_ff` の中の一時変数を除く)。
- 幅は Verilator で `$bits` を W2 と W4 のパッケージについて取った (PALEN 40: `pma_pkg::Line` 34 bit、`ExcRec` 73 bit)。
- 対象外は §0 と同じ。`src/mmu/` のうち新コアが使うのは `pmp_check.veryl` (組合せの検査器で記憶を持たない) だけである。
- 「区分」は §2 の規則による分類、「形」は規則に関わるコードの形: `S1R1W` は 1 読み 1 書き、`sync` は登録済みの読み (C/R を含む)、`BE` は byte (または dword) の write enable、`whole` は語全体の書き、`noRst` はリセットの無い `always_ff` で書くこと。

### 1.1 フロントエンド

| 配列 | 個数 | エントリ × 幅 (W2 / W4) | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 区分 | 備考 |
|---|---|---|---|---|---|---|---|---|
| `bp_btb.vt_q` (`vld`、`tag`) | 1 | 4096 × 17 | 69,632 | 1 / 1 | S | 無 | S | 書きの組 (§2.3 の V3、`doc/phase15_ms_logic.md` §8.1) ごとに 1 つの配列。whole の書き。valid は行に入り、リセット後の 4096 サイクルの掃き出しで消す |
| `bp_btb.tx_q` (tail の `t_off`、`t_knd`、`t_rvc`、`t_tgt`) | 1 | 4096 × 30 / 31 | 122,880 / 126,976 | 1 / 1 | S | 無 | S | |
| `bp_btb.tv_q` (tail の valid) | 1 | 4096 × 1 | 4,096 | 1 / 1 | S | 無 | S | |
| `bp_btb.g_slot.sv_q`、`so_q`、`sc_q`、`st_q` | slot 数 2 / 3 | 4096 × 1、3 / 4、2、15 | 4,096、12,288 / 16,384、8,192、61,440 | 1 / 1 | S | 無 | S | slot ごと、field ごとの配列 |
| `bp_ras.stk_q` | 1 | 16 / 32 × 64 | 1,024 / 2,048 | 1 / 1 | C/L | 無 | R | |
| `ftq.e_*` (start 64、pred 71/72、meta 17/27、ckpt 68/69、pd 32/64、res 71/72、last 3/4) | 1 | 32 × 326 / 372 | 10,432 / 11,904 | 4 + CW / E(3) | C/L | 無 | R | 深さ 32。G で commit の読み口 (`e_res.target`) が増えた |
| `icache_data_bank.mem_q` (`icache_array.g_data`) | 4 (way) | 256 × 256 | 65,536 | 1 / 1 | S | 無 | S | V4 (`dfd6ad1a`)。4 way を並列に読み、次のサイクルに way を選ぶ。dword の BE。read-old |
| `icache_array.tags_0..3` | 4 (way) | 128 × 27 | 3,456 | 1 / 1 | C/L | 無 | R | 同じサイクルのヒット判定に要る |
| `icache_array.valid_0..3`、`plru` | 5 | 128 × 1、128 × 3 | 128、384 | 2 / 2 + 一斉クリア | C/L | 有 | F | FENCE.I で全エントリを消す |
| `icache.ubuf_q` | 1 | 2 / 4 × 64 | 128 / 256 | A / 1 | — | 無 | F | |
| `lane_queue.buf_q` (FBQ、FetchBlk) | 1 | 4 × 371 / 560 | 1,484 / 2,240 | 1 / 1 | C/L | 無 | R | |
| `lane_queue.buf_q` (DQ、XOp) | 1 | 8 / 16 × 196 / 197 | 1,568 / 3,152 | FW / E(FW) | C/L | 無 | R | F で 64 bit の tval が無くなった |
| `lane_queue.buf_q` (RQ、DecOp) | 1 | 4 / 8 × 209 / 210 | 836 / 1,680 | RW / E(RW) | C/L | 無 | R | |

### 1.2 rename、スケジューラ、レジスタファイル

| 配列 | 個数 | エントリ × 幅 (W2 / W4) | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 区分 | 備考 |
|---|---|---|---|---|---|---|---|---|
| `rename.spec_q`、`arch_q` | 2 | 64 × 7 / 8 | 448 / 512 | A / E | C/L | 有 | F | |
| `rename.img_q` (checkpoint) | 1 | 4 / 8 行 × (64 × 7 / 8) | 1,792 / 4,096 | 1 行 / 1 行 | C/L | 無 | R | V5 (`499e771d`)。深さ 4 / 8 |
| `rename.own_q` | 1 | 4 / 8 × 7 / 8 | 28 / 64 | A / E | — | 有 | F | |
| `free_list.ent_q` (int / fp) | 2 | 64 / 128 × 7 / 8、32 / 64 × 7 / 8 | 448 / 1,024、224 / 512 | RW / CW | C/L | 有 | F | 初期値 (空きの番号) が要る |
| `iq` の payload (`port_q`、`tag_q`、`fu_q`、`sen_q`、`spr_q`、`srdy_q`、`barw_q`、`cold_q`) | 2 / 3 | 24、16 / 32、24、24 × 約 120-130 | 約 3,000 / 約 4,200 | A / E | C/L | 無 | F | wakeup の比較と選択は全エントリ。`st_q` などの状態はリセット付きの F |
| `prf.rf_q` (int) | 1 | 96 / 160 × 64 | 6,144 / 10,240 | issue + VU の scalar / WB の数 | C/L | 無 | R | V9 (`fe485d78`)。p0 は読みで 0 に固定。T_R の帯 (§2.3 の V10) |
| `prf.rf_q` (fp) | 1 | 64 / 96 × 64 | 4,096 / 6,144 | 同上 | C/L | 無 | R | 同上 |
| `vrf.vrf` | 1 | 32 × 128 | 4,096 | 4 / 1 | C/L | 無 | R | V9。深さ 32 |
| `exec_port.wl_q`、`hist_q` | ポート数 | 数エントリ | < 200 | 小 | — | 有 | F | |

### 1.3 ROB、commit、CSR、debug

| 配列 | 個数 | エントリ × 幅 (W2 / W4) | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 区分 | 備考 |
|---|---|---|---|---|---|---|---|---|
| `rob.ent_q` | 1 | 64 / 128 × 93 / 98 | 5,952 / 12,544 | CW + 2 × WALK_W / E(RW) | C/L | 無 | R | V7 (`1c219a0c`)。T_R の帯 (V10) |
| `rob.snap_q` | 1 | 64 / 128 × 36 / 42 | 2,304 / 5,376 | 1 / E(RW) | C/L | 無 | R | V7。W4 は T_R の帯 (V10) |
| `rob.res_q` (`mispred`、`taken`) | 1 | 64 / 128 × 2 | 128 / 256 | CW / E(BRU 数) | C/L | 無 | R | G (`9e534856`) で next_pc 64 bit を外した |
| `rob.ffl_q` | 1 | 64 / 128 × 5 | 320 / 640 | CW / E | C/L | 無 | R | V7 |
| `rob.done_q`、`rec_q` | 2 | 64 / 128 × 1 | 64 / 128 | CW / E | C/L | 有 | F | |
| `rob.walk_q`、`commit.pc` など | 1 | 小 | < 1,000 | — | — | 有 | F | `rob.obs_q`、`commit.ret_q`、`rx_q` は `HELIODOR_OBS`/`HELIODOR_CHK` の中で合成の対象外 |
| `csr.hpmc_q`、`hpme_q` | 2 | 29 × 64 | 1,856 | A / 1 | — | 有 | F | C1 (`b7b2c821`) で 0-2 を外した。カウンタは毎サイクル独立に増える |
| `csr.pmpaddr`、`pmpcfg` | 1 | 16 × 64 (PALEN 40 で生きている bit は 38)、2 × 64 | 1,024、128 | A / 1 | — | 有 | F | PMP の decode は全エントリ |
| `trig_unit.tr_q` | 1 | 2 / 4 × Trig | < 600 | A / 1 | — | 有 | F | |

### 1.4 LSU と dcache

| 配列 | 個数 | エントリ × 幅 (W2 / W4) | 容量 / 個 (W2 / W4) | R / W | 読みの型 | リセット | 区分 | 備考 |
|---|---|---|---|---|---|---|---|---|
| `lq.e_*` の payload (wrap、ex、op、sqlim、va 64、line0/1 34+34、dw、why、fid、key) | 1 | 32 / 64 × 181 / 185 | 5,792 / 11,840 | A / E(RW + 2 × MEM_W) | C/L | 無 | F | `fdecbf9f` でリセットの無い `always_ff` へ (§2.3 の注の決定)。順序違反の scan と wakeup は全エントリ。H (`8a4dfb73`) で `e_lm0/1` を外した |
| `lq` の状態 (state、seen0/1、half、io、ioord、dram、poison) と `e_xexc` (ExcRec 73) | 1 | 32 / 64 × 10 + 73 | 2,656 / 5,312 | A / E | C/L | 有 | F | `e_xexc` は確保で 0 にする (valid が機能に要る) |
| `sq.e_*` の payload (wrap、rob、lqlim、op、va 64、line0/1、dw0、m16、data 120、rhalf) | 1 | 16 / 32 × 298 / 300 | 4,768 / 9,600 | A / E(RW + 2 × MEM_W) | C/L | 無 | F | `fdecbf9f` でリセットの無い `always_ff` へ。K (`b53de1e3`) で data を 120 bit に |
| `sq` の状態 (cross、av0/1、exc、dv、rdy、xw、dw、full、io、ioord、dram、wtd) と `e_xexc` | 1 | 16 / 32 × 13 + 73 | 1,376 / 2,752 | A / E | C/L | 有 | F | |
| `sb.e_line`、`e_wrap`、`e_data`、`e_strb` | 1 | 8 / 16 × 611 | 4,888 / 9,776 | A / E | C/L | 無 | F | `fdecbf9f` でリセットの無い `always_ff` へ。深さ 8 / 16。forwarding と write-combining は全エントリ |
| `atomic_unit.preg_q`、`cval_q`、`mem_port_arb`、`ptw.q_*`、`dcache_mshr.*`、`dcache.s1_*`、`resp_q`、`wb_data_q` | 各 1 | 数エントリ | < 1,000 | 小 | — | 一部有 | F | |
| `tlb.ent_q` (D / I) | 2 | 32 × 107、16 × 107 | 3,424、1,712 | A / 1 | — | 無 (v_q は有) | F | 全エントリの比較 |
| `dcache_bank.mem_q` (`dcache_data.g_bank`) | DC_NB = 2 / 4 | 64 × 1,024 / 512 | 65,536 / 32,768 | 1 / 1 | S | 無 | S | 行 = 1 set の全 way の、その bank の dword。`89b9114a` で bit の mask の RMW から byte の BE に。同じ行への書きは読み出しレジスタへ前方転送 (ヘッダに記載) |
| `dcache_tagbank.tags_0..3` (dcache の tag 複製) | 4 (way) × TC_N 6 / 7 | 64 × 28 | 1,792 | 1 / 1 | C/L | 無 | R | V8 (`c3b86c8c`)。読み手ごとの複製 |
| `dcache_tags.valid_q`、`excl_q`、`dirty_q`、`plru_q` | 4 | 64 × 4、64 × 3 | 256、192 | TC_N / 複数 + 一斉クリア | C/L | 有 | F | |

### 1.5 VU

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 | R / W | 読みの型 | リセット | 区分 | 備考 |
|---|---|---|---|---|---|---|---|---|
| `vector_unit.fifo_*` | 1 | 8 × 約 140 | 約 1,100 | 1 / 1 | C/L | 有 | F | 命令 FIFO。W2 と W4 で同じ |
| `vu_adapter.lastm_q` | 1 | 32 × 64 | 2,048 | 1 / 2 | C/L | 有 | F | |
| `vrf.vrf` | 1 | 32 × 128 | 4,096 | 4 / 1 | C/L | 無 | R | (§1.2 に再掲) |

### 1.6 SoC (L2、mem_ctrl、周辺、debug module)

| 配列 | 個数 | エントリ × 幅 | 容量 / 個 | R / W | 読みの型 | リセット | 区分 | 備考 |
|---|---|---|---|---|---|---|---|---|
| `l2_data_bank.mem_q` (`l2cache.gen_data`) | 4 (way) | 512 × 512 | 262,144 | 1 / 1 | S | 無 | S | V1 (`5e1ff8a8`)。4 way を同じ index で並列に読み、登録した tag の比較で選ぶ。byte の BE。read-old |
| `l2_tag_bank.mem_q` (`l2cache.gen_tag`) | 4 (way) | 512 × (25 + N + 1) | 13,824 (N = 1) / 15,360 (N = 4) | 1 / 1 | S | 無 | S | V2/C (`3ffdf899`)。tag と directory (own、shr) の語。登録した前方転送は配列の外 |
| `l2cache.gen_tag.lv_q` (line の valid)、`plru` | 4 + 1 | 512 × 1、512 × 3 | 512、1,536 | 1 / 1 | C/L | 有 | F | valid はリセットで消す (掃き出しにすると reset から最初の命令までが延びる、`doc/phase15_verification_plan.md` §9.18) |
| `mem_ctrl.buf_q` (slot ごと) | 2N + 1 | 8 × 64 | 512 | 2 / 1 | C/L | 有 | F | |
| `mem_ctrl.wb_data`、`wb_strb` | 1 | 8 × 2N × (64 + 8) | 1,152 × N | 1 / 8 lane | C/R | 無 | R | V6 (`3a88b97a`) |
| `mem_ctrl.acc_wait_q`、`wb_v`、`wb_line` ほか | slot 数 | 小 | < 300 | — | — | 有 | F | |
| `clint.mtimecmp`、`msip`、`plic.*`、`dm.pbuf_q`、`hgrp_q`、`rgrp_q` | 各 1 | 小 | < 600 | 小 | C/L | 有 | F | |

### 1.7 集計 (出口の時点)

| 区分 | 配列 | 規則との照合 |
|---|---|---|
| S | `bp_btb` の書きの組 (W2 11 個、W4 14 個)、`icache_data_bank` × 4、`dcache_bank` × 2 / 4、`l2_data_bank` × 4、`l2_tag_bank` × 4 | すべて 1R1W、登録済みの読み、リセット無し、1 つの書き込み文、whole か BE の書き、ヘッダに読みと書きの衝突時の値 (S1-S5) |
| R | `prf` × 2、`vrf`、`rob` の payload 4 本、`ftq`、`rename.img_q`、`lane_queue` × 3、`icache_array.tags`、`dcache_tagbank` (dcache)、`mem_ctrl.wb_data/wb_strb`、`bp_ras` | すべて T_S 未満、payload はリセット無しの `always_ff` (R1-R4)。T_R の帯の行は §2.3 の V10 に理由 |
| F | 残り | すべて T_S 未満 (F1)。最大は `lq` の payload (W4 11,840) |

T_S (16 Kbit、深さ 64 以上) を超える配列は、S の配列だけである。最大の R は W4 の `rob.ent_q` (12,544)。

W2 と W4 で区分か読みの型が変わる配列は無い。容量は `bp_btb` (slot 数と FOFF_W)、`dcache_bank` (bank 数。総量は同じ 128 Kbit)、ROB/LQ/SQ/SB/PRF/IQ の深さで変わる。

## 2. 分類の規則 (2026-11-20 に決定)

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

【決定】(2026-11-20、ユーザ) 推奨どおり。T_S = 16 Kbit (深さ 64 以上) は S が必須、4-16 Kbit (T_R の帯) は S にすべきで、R のままにするなら理由を本書に記録する。単位は配列 1 個 (index 空間が 1 つで口の組が 1 つ)。出力がレジスタにしか入らない組合せ読み (`C/R`) は同期読みとして数える。

### 2.3 規則を当てた結果: 違反の一覧と直し方

| # | 配列 | 区分 | 違反 | 直し方の案 | リスク |
|---|---|---|---|---|---|
| V1 | `l2cache.data_0..3` (D12 と §MS が名指し) | S | S2: way を同じサイクルの tag 比較で選んでから読む。S3/S4: 非同期リセット付きの `always_ff` の中で書く。S4: 書きが RMW 形 (`(data & ~msk) \| (new & msk)`)。死んだ口 (`L2_READ_1R1W` の spec 読み、`!L2_PORTS_1R1W` の merge 読みと 2 本の書き) が生成 SV に残る | データ配列を `dcache_bank` と同じ形の 1R1W のモジュール (リセットの無い書き、byte enable の書き、登録済みの読み) に出し、4 way を同じ index で並列に読んで、登録済みの `ctm` で次のサイクルに選ぶ。merge は byte enable の書き込みで行うので古い行の読みは要らない。死んだ scaffold (`L2_READ_1R1W`、`L2_PORTS_1R1W = 0` の枝、`w_old_line`、`w_merged_line`) を消す。V14 の `v14_*` が共有するインタフェースを変える場合は D13 に従って V14 側も `veryl check` を通す | mem_ctrl の HIT_WAIT がすでに 1 サイクルの読みを隠しているので、サイクルは変わらない見込み。L2 の書き込みの原子性 (merge と install が同じサイクルに来ない、SoC の `wgrant_ok`) は今の規則のまま。ゲートは G0、N=2 boot、litmus N=4、N=4 boot (メモリ系の変更) |
| V2 | `l2cache.tag_0..3` と L2 の tag 複製 4 組 | S (25 Kbit / way、深さ 512) | S2: 読みが C/L (lookup、install、engine、write、misaligned の各経路が同じサイクルにヒット判定を使う)。S3/S4: リセット付きの `always_ff` で書く。複製が 5 組で、tag の総量は 490 Kbit とデータの半分近い | 案 a (推奨): L2 の作り直しで tag の読みを 1 段パイプラインにし、tag と directory (`lv`、`own`、`shr`) を 1 語にまとめた way ごとの 1RW (または 1R1W) マクロ 1 組にする。mem_ctrl の各経路 (lookup、install、engine、write、misaligned) は 1 本の tag ポートを調停する (同じ line の直列化は今の per-line 規則がすでに持つ)。案 b: tag を R に分類し直す (閾値の例外)。案 b は 25 Kbit × 5 組の FF で、T_S を破る | 案 a は mem_ctrl の LOOKUP と write grant の時間関係が変わる。SMP の一貫性 (recall、veto、per-line の直列化) に触れるので、litmus N=4 と N=4 boot が必須。MS で最も大きい変更。【決定】(2026-11-20、ユーザ) 案 a |
| V3 | `bp_btb` valid (`vld`、`s_v`、`t_v`) | F (16 / 20 Kbit) | F1: T_S 以上の F。全エントリのリセット | valid を payload の語に入れて S にし、リセット後に 4096 行を掃き出す FSM (4096 サイクル、その間は予測しない) か、2-3 bit の世代番号で無効化する。予測は正しさに影響しない (extract が全予測を検査する) | 低い。サイクル数はリセット直後だけ変わる (掃き出しの間は予測が無い)。GL-B の record 列と hash は変わらない見込み (予測は retire 列に出ない) |
| V4 | `icache_array.data_0..3` | S | S2: way を同じサイクルの tag 比較で選んでから読む (C/R だが way 選択が前)。S4: 書きが RMW 形 | 4 way を `blk_i` で並列に読み、tag のヒットで次のサイクルに選ぶ (応答はもともと 1 サイクル後なので遅延は変わらない)。書きを 64 bit の書き込み enable の形にする | 低い。`IC_RESP_LAT = 1` は変わらない |
| V5 | `rename.img_q` (§MS が名指し) | R | R4: リセット付きの `always_ff` の中で書く (書く文はリセットしない) | 書きをリセットの無い `always_ff` に移す。`ckv_q` と `own_q` はリセット付きのまま | 低い。値とサイクルは変わらない |
| V6 | `mem_ctrl.wb_data`、`wb_strb` (§MS が名指し) | R | R3: payload を非同期リセットで 0 にする | payload のリセットを消す (有効は `wb_v` が持つ)。書きをリセットの無い `always_ff` に移す | 低い。リセット直後の値を誰も読まないことを `wb_v` で確かめる |
| V7 | `rob.ent_q`、`snap_q`、`obs_q`、`res_q`、`ffl_q` | R | R4: リセット付きの `always_ff` の中で書く | V5 と同じ移動。`done_q`、`rec_q` はリセット付きの F として残す | 低い |
| V8 | `dcache_tagbank.tags_0..3` (dcache の複製) | R (2.8 Kbit) | R4: リセット付きの `always_ff` の中で書く | 移動だけ。L2 側の複製は V2 で消える | 低い |
| V9 | `prf.rf_q`、`vrf.vrf` | R | R3: payload を全エントリ 0 にリセットする | `prf`: x0 (int の pdst 0) だけを読み出し側で 0 に固定し、リセットを消す。`vrf`: リセットを消す。ただし v レジスタの初期値 0 に依存している tb (golden の lockstep、spike との cosim の初期状態) が無いかを先に確かめる | `vrf` は初期値の差が cosim と GL-B に出うる。【決定】(2026-11-20、ユーザ) `vrf` もリセットを消す。ゲートで初期状態の差が出たら、tb から初期化する。`prf` は低い |
| V10 | `lq.e_xexc` (W4 9 Kbit)、`icache_array.tags` (5.5 Kbit / way) | R (T_R 以上) | 違反ではない (推奨 S の帯)。R のままにする理由: `e_xexc` は E の書き (エントリごとの enable) で 1 口にまとまらない。icache の tag は C/L で、同じサイクルのヒット判定に要る | 記録だけ | — |

違反ではないが確かめが要るもの:
- `dcache_bank` (S): 書きが RMW 形で、読み出しレジスタの前方転送も mask を使う。Vivado が byte enable の 1R1W と認識するかは手順 4 の合成で確かめる。認識しなければ書き込みを byte ごとの `if` の形に書き換える (値は同じ)。
- F に分類した `lq`/`sq`/`sb` の payload はリセット付きの `always_ff` の中で書かれる (無(rb))。F なので規則違反ではないが、FPGA ではリセットを clock enable に混ぜる論理が増える。【決定】(2026-11-20、ユーザ) 手順 3 でこれらの payload の書きもリセットの無い `always_ff` に移す。

解消の状況 (MS の出口、2026-11-23):

| # | 状態 | commit |
|---|---|---|
| V1 | 解消。way ごとの `l2_data_bank` (1R1W、byte の BE、登録済みの読み、リセット無し)。死んだ scaffold も消した | `5e1ff8a8` |
| V2 | 解消 (案 a)。tag と directory を way ごとの `l2_tag_bank` 1 組にまとめ、tag port を 1 段のパイプラインにした。複製 4 組は消えた。line の valid と PLRU はリセット付きの F に残した | `3ffdf899` |
| V3 | 解消。valid を BTB の行に入れ、リセット後に掃き出す。行を書きの組ごとの配列に分けて block RAM に推論させた | `b4b85f3a`、`7a1c74d3` |
| V4 | 解消。4 way を並列に読み、dword の BE で書く `icache_data_bank` | `dfd6ad1a` |
| V5 | 解消 | `499e771d` |
| V6 | 解消 | `3a88b97a` |
| V7 | 解消 (`obs_q` は `HELIODOR_OBS` の中) | `1c219a0c` |
| V8 | 解消。dcache の tag の複製は LUTRAM に推論される | `c3b86c8c` |
| V9 | 解消。初期状態の差はゲートに出ず、tb の初期化は要らなかった | `fe485d78` |
| V10 | 記録のまま。`icache_array.tags` は PALEN 40 で 3,456 bit になり T_R を下回った。`lq.e_xexc` は F の縮小で 2,336 / 4,672 bit になり、確保で 0 にする (valid が機能に要る) ので F に分類し直した。出口の時点で T_R の帯にある R は `prf` (int 6,144 / 10,240、fp 4,096 / 6,144)、`rob.ent_q` (5,952 / 12,544)、`rob.snap_q` (W4 5,376)、`ftq` (10,432 / 11,904)、`rename.img_q` (W4 4,096)、`vrf` (4,096) で、どれも多ポート (PRF、ROB) か深さ 64 未満 (FTQ、checkpoint、VRF) で 1R1W の S にできない | — |
| 注の `dcache_bank` | 解消。出口の照合で、書きが bit の mask の RMW のままだと分かり、byte の BE にした (§3.1) | `89b9114a` |
| 注の LQ/SQ/SB | 解消。出口の照合で、決定が未実施だと分かり、payload の書きをリセットの無い `always_ff` に移した (§3.1) | `fdecbf9f` |

### 2.4 Vivado と Design Compiler (ツールの確認と提案)

| ツール | 場所 | 確認したこと |
|---|---|---|
| Vivado 2021.2 | `/storage/eda/tools/xilinx/Vivado/2021.2/bin/vivado` | sandbox の外で、64 × 32 の 1R1W の小さい例を `synth_design -mode out_of_context` (xc7a35t) にかけ、ライセンス取得 (`Synthesis`) と RAMB18 1 個への推論を確かめた。sandbox の中ではライセンスで止まる (§MS の記録どおり) |
| Design Compiler X-2025.06-SP2 | `/storage/eda/tools/synopsys/DC/X-2025.06-SP2/bin/dc_shell` | sandbox の外で `analyze`/`elaborate` が通り、メモリの推論 (`Inferred memory devices`) を報告した。セルライブラリは `/storage/eda/libs/common/arm/umc28hpcp/...` などの `.db` がある (`compile` までは試していない) |
| Verilator 5.050 | `~/local/bin/verilator` | 既存 |
| yosys | 無し | riscv-formal (§MV、D14) に要る。MS の後の作業で導入が要る |

提案: 手順 4 で Vivado の out-of-context 合成に加えて、**Design Compiler で S 区分の配列をブラックボックスにした合成**を足す。【決定】(2026-11-20、ユーザ) 足す。
- やり方: 手順 3 で S 区分の配列をすべて共通のラッパ (`sram_1r1w`、`sram_1rw`。シミュレーション用の振る舞いモデルを持つ) に置き換え、DC ではラッパを black box にして `compile` する。ラッパは「S 区分の配列が他に無い」ことの機械的な検査にもなる (DC の `Inferred memory devices` に S 級の大きさのメモリが残れば規則違反)。
- 得るもの: ASIC で問題になる構造 (latch の推論、組合せループ、多重駆動、巨大な FF 配列) の検出と、R と F の実際の面積。Vivado は FPGA の推論しか見ないので、`C/R` を FPGA の block RAM の出力レジスタが吸収して ASIC で破綻するような差は DC でしか見えない。
- 代金: 合成スクリプトの保守、ライセンスの占有、実行時間 (SoC 全体で数時間の見込み、未測定)。ゲートの頻度は節目ごと (MS の出口と以後のメモリ系の変更) にする案。
- 足さない場合: Vivado の推論結果 (RAM と FF の内訳) だけを出口条件にし、ASIC の面積は記録しない。

【変更】(MS の途中、ユーザ) Design Compiler の合成は MS の出口条件に含めない。出口は Vivado の推論結果 (§3.2) で判定する。S の配列はそれぞれ専用の 1R1W のモジュール (`l2_data_bank`、`l2_tag_bank`、`icache_data_bank`、`dcache_bank`) か、`bp_btb` の中の 1R1W の配列になっており、ASIC の macro への差し替えはこの境界で行える。

## 3. 出口の照合 (2026-11-23、`fdecbf9f`)

### 3.1 規則との照合 (設計書の MS の出口条件の 2)

§1 の全行を §2 の規則に当てた。結果: すべての行が規則に合う。

- 照合で見つけて直したもの (どちらも値とサイクルを変えない。ゲートは `doc/phase15_verification_plan.md` §9.22):
  - `dcache_bank` (S): 書きが bit の mask の RMW (`(mem & ~mask) | (data & mask)`) のままで、2026-11-20 の「S 類に bit の mask の RMW をしない」規則 (`doc/phase15_ms_logic.md` §7) に反していた。mask はもともと byte 単位 (`dcache_data` の `row_mask` が byte の bit を 8 回並べる) なので、port を byte の write enable (`i_wbe`) にし、書きと前方転送を byte ごとの形にした。読み出しレジスタのリセットも外した (`89b9114a`)。
  - `lq`、`sq`、`sb` の payload (F): §2.3 の注の決定 (2026-11-20、リセットの無い `always_ff` に移す) が入っていなかった。payload の書きをリセット付きのプロセスから外し、エントリの状態 (リセットの要るビット) だけを残した (`fdecbf9f`)。
- 残る例外 (規則に合うが記録しておくもの): `dcache_bank` は FPGA では block RAM でなく LUTRAM に推論される (§3.2)。深さ 64 で行が 1,024 / 512 bit と広く、block RAM にすると RAMB36 を 15 個前後並べて深さの 1/8 しか使わないので、Vivado の選択は面積の上で正しい。S の規則 (1R1W、登録済みの読み、リセット無し、BE の書き) には合っており、ASIC では SRAM の macro に置ける形である。前方転送は読み出しレジスタの前にあり、macro にするときは前方転送の data を登録する形 (`l2_tag_bank` と同じ) に移す。

### 3.2 Vivado の推論 (出口条件の 3、4)

合成は `doc/phase15_ms_logic.md` §1 のフロー (KU15P、Vivado 2021.2、2 thread、define なし)。`soc_w2_l2` (L2 込みの N=1 W2 SoC) は synth_design 33 分 24 秒で完走した (sim 4 本、Vivado 3 本を並べた)。`core_w4` は 43 分 38 秒、`soc_w2` (L2 を black box) は 18 分 58 秒。

S の配列の推論 (`ram.rpt` と `util_hier_full.rpt`):

| 配列 | W2 (`soc_w2_l2`) | W4 (`core_w4`) | 判定 |
|---|---|---|---|
| `l2_data_bank` × 4 | RAM_SDP 512 × 512、各 RAMB36 8 (byte の write enable) | (L2 は SoC にある) | RAM |
| `l2_tag_bank` × 4 | RAM_SDP 512 × 27、各 RAMB18 1 | | RAM |
| `icache_data_bank` × 4 | 256 × 256 (65,536 bit)、各 RAMB36 4。dword の enable は幅 64 で BRAM の byte enable の上限 (32) を超えるので、Vivado が dword ごとの RAM に分けた (Synth 8-6841、値は同じ) | 同じ | RAM |
| `bp_btb` の書きの組 (W2 11 個、W4 14 個) | RAM_SDP。RAMB36 6 + RAMB18 7、`tx_q` は URAM 1 | RAMB36 8 + RAMB18 10 + URAM 1 | RAM |
| `dcache_bank` × 2 / 4 | LUTRAM (`RAM64X1D`、bank あたり 2,048 LUT)、読み出しレジスタ 1,024 FF | LUTRAM (bank あたり 1,024)、512 FF | RAM (分散 RAM。§3.1 の例外) |

R の配列: `icache_array.tags`、`dcache_tagbank` (6 / 7 組)、`vrf` は LUTRAM。`rename.img_q` (port 16)、`mem_ctrl.wb_data/wb_strb` (8 lane の書き)、struct の配列 (`rob`、`ftq`、`lane_queue`、`iq`、`prf` など、Synth 8-5858) は FF。いずれも T_S 未満で、区分どおりである。FF に展開された配列 (Synth 8-4767) は W2 SoC と W4 core のどちらも 16 個で、`img_q`、`wb_data`、`wb_strb` のほかは定数の index で書く小さい配列だった。T_S を超える配列が FF に展開されたものは無く、推論の失敗 (Synth 8-3391) も無い。

使用量: `doc/phase15_ms_logic.md` §8.15。
