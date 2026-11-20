# Phase 15 MS: 論理の純粋な無駄の棚卸し (Vivado 合成による)

FPGA 合成を試した人から「ROB がとても大きい」と報告があった (2026-11-20)。ユーザの指示は、性能を買っていないのに面積を食っている部分 (RAM の外も含む。retire record のような観測専用の状態と論理など) をすべて MS で取り除くこと。性能との引き換えになるものは対象外とする。この文書は、そのための合成フロー (§1)、使用量 (§2)、RAM の推論結果 (§3)、ROB の内訳 (§4)、無駄の一覧 (§5) をまとめる。RTL はこの作業では変えていない。§5 の提案はすべて判断待ちである。

前提として `doc/phase15_ms_sizing.md` §0 の決定 (D-1..D-6) がある。E (retire record 専用の ROB の field を define で外す)、F (例外記録の縮小)、G (`rob.res_q.next_pc` を FTQ から取る)、H (LQ の byte mask)、PA 幅を構成値にして既定 40 bit にすること、は決定済みで、ここでは合成での実測値を付けるだけにする。

## 0. 要約

- 合成の対象と結果 (Kintex UltraScale+ `xcku15p-ffve1517-2-e`、out-of-context、`HELIODOR_CHK` なし):
  - N=1 W2 SoC (L2 を除く): LUT 423,329 (うち LUTRAM 24,208)、FF 132,512、BRAM 0、DSP 349。core は LUT 413,957 / FF 128,330。
  - W4 core: LUT 807,513 (うち LUTRAM 27,408)、FF 195,535、BRAM 0、DSP 372。KU15P の LUT の 154 % で、この part に入らない。
  - L2 を含む SoC は合成できない。L2 のデータ配列 (`data_0..3`、512 × 512 bit × 4) が RAM に推論されず、FF への展開も上限 (262,144 bit) を超えて elaboration が 25 分 46 秒で止まる (§3.1)。SoC の数字は L2 を black box にしたものである。
  - BRAM は 1 個も使われていない。BTB、dcache のデータ、icache のデータと tag はすべて LUTRAM、dcache の tag の複製はすべて FF になった (§3)。
- 観測の出力を残すと大きくなる: retire record、perf、checker の出力をすべて生かした合成は、W4 core で LUT +78,760 (+9.8 %)、FF +17,078 (+8.7 %)、DSP +60、W2 core で LUT +19,444 (+4.7 %)、FF +9,299 (+7.2 %)、DSP +60 だった (§2.3)。W4 ではそのうち ROB 関連 (`obs_q`、`insn` とそれを書く論理) が FF 約 12,300、LUT 約 48,000 である。`heliodor_soc_smp` をそのまま top にすると `o_retire`、`o_core_perf` などが port に残るので、報告者の合成はこの状態だったと考えられる。その場合 W4 の ROB は LUT 66,560 / FF 35,444 になる。
- 機能の port だけを残した合成では、観測専用の論理は Vivado がすでに刈る。決定済みの E は、この場合は 0 しか減らない。E の効果は top が観測の port を出す場合に限られるので、E の define を retire record と perf の全体に広げることを提案する (§5 の O1)。
- 観測を除いた後の最大の無駄は、PMP 検査の重複 (W2 で約 41,000 LUT、W4 で約 62,000 LUT。§5 の P) と、SQ の forwarding の line 画像の組み立て (W2 約 9,000、W4 約 24,000 LUT。§5 の S1) である。どちらも同じ値を何度も計算しているだけで、cycle は変わらない。

## 1. 合成フロー

### 1.1 スクリプト (`synth/vivado/`)

| ファイル | 役割 |
|---|---|
| `run.sh <target> [threads]` | `heliodor.f` から合成のファイル一覧を作り、Vivado を batch で走らせる。出力は `synth/vivado/out/<target>/` (gitignore) |
| `synth.tcl` | `read_verilog -sv`、`synth_design -mode out_of_context -flatten_hierarchy rebuilt`、`report_utilization` (全体、階層 depth 4 と 12)、`report_ram_utilization -detail`、checkpoint の書き出し。message の上限を外す (既定の 100 件では RAM 推論の警告が途中で切れる) |
| `order.py` | ファイルを package の依存順に並べる。`heliodor.f` は依存順ではなく、Vivado の non-project flow は与えた順に compile するので必要 |
| `stub.py` | module の black box stub (port 宣言だけ) を作る。`soc_w2` で L2 に使う |
| `syn_soc_w2.sv` | N=1 W2 SoC の合成 top。memory map は `tb_platform_pkg::MAP_BOOT`。機能の port (AXI、UART、外部割り込み、DMI の APB) だけを残し、`o_retire`、`o_core_perf`、`o_core_chk`、`o_mc_perf`、`o_io_obs`、`o_dm_obs` は開放、`i_dbg_*` (schedule replay) は 0 に固定する |
| `syn_core.sv` | core 単体の合成 top (W2/W4)。`OBS = 0` は機能の port だけ、`OBS = 1` は retire record、perf、checker の全 bit を XOR 木で 1 本の出力に集め、`i_dbg_*` を port にする (観測を出す top の代価を測るため) |
| `syn_pmp.sv` | PMP 検査器の単体の原価を測る top (§5 の P) |
| `cells.tcl`、`cells.py` | checkpoint の全 primitive を名前つきで書き出し、階層または信号名で集計する。§4 と §5 の内訳はこれで取った |

target: `soc_w2`、`soc_w2_l2` (L2 込み、今は失敗する)、`core_w2`、`core_w4`、`core_w2_obs`、`core_w4_obs`、`pmp1`、`pmp3`、`pmp_if4`、`pmp_if8`。

手順:

```bash
./veryl/target/release-verylup/veryl build      # tb/*.sv と heliodor.f を出す
synth/vivado/run.sh soc_w2                       # sandbox の外で (license)
python3 synth/vivado/cells.py <dump> sig <instance path> 1
```

### 1.2 設定

- Vivado 2021.2、`set_param general.maxThreads 2`、part `xcku15p-ffve1517-2-e` (Kintex UltraScale+ KU15P: LUT 522,720、FF 1,045,440、BRAM36 984、URAM 128、DSP 1,968)。W2 SoC は入るが W4 core は LUT が 154 % で入らない。合成の数字は part の大きさに依存しない (配置しない) ので、W4 もこの part の値として記録した。
- define: なし。`src` の生成 SV にある条件は `HELIODOR_CHK` だけで (69 箇所)、checker と retire record の一部 (`rob.src_q`、commit の `rx_q`、csr の観測値の差し替え) を囲む。合成の build は `HELIODOR_CHK` を定義しない。retire record の本体 (`rob.obs_q`、`RobEnt.insn`、commit の `ret_q`、`order_q`、LQ/SQ の `obs` の窓、`vu_adapter` の hash、csr の観測の読み口) と perf の配線は define で囲まれておらず、top が出力を残すかどうかで合成に残るかが決まる。
- ファイル一覧: `src/` (`src/v14/` を除く) + `tb/cfg_bad.sv`、`tb/cfg_w4_sb8.sv` (生成された `core_types` が参照する)、`tb/tb_platform_pkg.sv` (memory map) + `synth/vivado/*.sv`。
- `-flatten_hierarchy rebuilt`: 階層をまたいだ定数伝播と未使用論理の削除が効く (開放した出力だけを駆動する論理が消える) 代わりに、階層の帰属は近似になる。境界をまたいで最適化した論理は消費側か生成側のどちらかの階層に入る。例: W2 の `u_div/u_shell` の 13,608 LUT は大半が PRF の書き込み論理 (`rf_q`) で、divider 自身ではない。§4 と §5 の内訳は、階層ではなく cell の名前 (Vivado は register をその信号名で、LUT の多くを駆動する net の名前で呼ぶ) で集計した。cell の集計は LUT の primitive の数なので、2 つの LUT を 1 site に詰めた組を 1 と数える `report_utilization` より 1 割ほど多い (W2 core で 462,225 対 413,957)。

### 1.3 実行時間

| target | 結果 | synth_design (elapsed) | peak memory |
|---|---|---|---|
| `soc_w2_l2` | 失敗 (L2 の RAM 推論、§3.1) | elaboration で 25 分 46 秒 | 7.9 GB |
| `soc_w2` | 完走 | 17 分 33 秒 (全体 19 分 49 秒) | 6.1 GB |
| `core_w4` | 完走 | 35 分 34 秒 (全体 39 分 2 秒) | 8.2 GB |
| `core_w4_obs` | 完走 | 39 分 29 秒 (全体 43 分 33 秒) | 8.3 GB |
| `core_w2_obs` | 完走 | 16 分 46 秒 (全体 18 分 46 秒) | 6.2 GB |
| `pmp1`、`pmp3`、`pmp_if4`、`pmp_if8` | 完走 | 各 1 分弱 | |

## 2. 使用量

### 2.1 N=1 W2 SoC (`soc_w2`、L2 は black box)

全体: LUT 423,329 (logic 399,121、LUTRAM 24,208)、FF 132,512、CARRY8 18,366、F7 44,273、F8 16,129、BRAM 0、URAM 0、DSP 349。

SoC の core 以外: `u_mctrl` 3,991 / 3,148 (LUT / FF)、`u_sba` 778 / 262、`u_plic` 461 / 197、`u_dm` 384 / 389、`u_clint` 169 / 133、`u_dmi` 37 / 34、`u_uart` 0 / 17、`u_l2` (black box)。

core (`u_core`) の内訳 (階層は rebuilt、§1.2 の注意):

| block | LUT | LUTRAM | FF | DSP |
|---|---|---|---|---|
| `u_vu` | 82,080 | 0 | 5,383 | 309 |
| `u_csr` | 42,396 | 0 | 8,032 | 0 |
| `u_dc` | 40,626 | 4,096 | 15,917 | 0 |
| `u_sq` | 30,095 | 0 | 8,335 | 0 |
| `g_ep[1].u_ep` | 22,536 | 0 | 2,762 | 24 |
| `g_ep[0].u_ep` | 19,812 | 0 | 1,666 | 16 |
| `u_prf_i` | 15,052 | 0 | 6,144 | 0 |
| `u_bpu` | 14,630 | 11,520 | 1,319 | 0 |
| `u_lq` | 14,000 | 0 | 15,876 | 0 |
| `u_dptw` | 13,855 | 0 | 1,250 | 0 |
| `u_ic` | 11,462 | 8,592 | 1,838 | 0 |
| `u_vrf` | 10,954 | 0 | 4,096 | 0 |
| `u_prf_f` | 9,849 | 0 | 4,096 | 0 |
| `u_rob` | 9,253 | 0 | 11,215 | 0 |
| `g_mp[0].u_mp` | 8,931 | 0 | 2,564 | 0 |
| `g_iq[0].u_iq` | 8,666 | 0 | 2,784 | 0 |
| `u_rq` | 7,899 | 0 | 1,049 | 0 |
| `u_ftq` | 7,676 | 0 | 9,175 | 0 |
| `u_iptw` | 6,271 | 0 | 839 | 0 |
| `u_dtlb` | 5,694 | 0 | 3,941 | 0 |
| `u_vum` | 5,331 | 0 | 558 | 0 |
| `u_ren` | 5,262 | 0 | 2,720 | 0 |
| `u_sb` | 5,045 | 0 | 5,050 | 0 |
| `u_ext` | 4,460 | 0 | 2,393 | 0 |
| `u_itlb` | 4,205 | 0 | 1,876 | 0 |
| `u_flush` | 1,966 | 0 | 148 | 0 |
| `u_at` | 1,646 | 0 | 1,109 | 0 |
| `u_ifu` | 1,529 | 0 | 2,122 | 0 |
| `u_commit` | 1,364 | 0 | 384 | 0 |
| `g_iq[1].u_iq` | 1,099 | 0 | 1,632 | 0 |
| `u_io` | 1,040 | 0 | 378 | 0 |
| `u_fl_int` | 1,019 | 0 | 467 | 0 |
| `u_trig` | 859 | 0 | 190 | 0 |
| `u_fl_fp` | 682 | 0 | 239 | 0 |
| `u_vua` | 520 | 0 | 377 | 0 |
| `u_bt` | 340 | 0 | 320 | 0 |
| `u_arb` | 269 | 0 | 21 | 0 |
| `u_trap` | 34 | 0 | 0 | 0 |
| `u_dec` | 33 | 0 | 0 | 0 |
| `u_islot` | 11 | 0 | 57 | 0 |
| `g_rs[2].u_rs` | 9 | 0 | 4 | 0 |
| `u_xctx` | 2 | 0 | 0 | 0 |
| `g_rs[0].u_rs` | 1 | 0 | 1 | 0 |
| `g_rs[1].u_rs` | 1 | 0 | 1 | 0 |
| `u_dp` | 0 | 0 | 2 | 0 |
| 計 (`u_core`) | 413,957 | 24,208 | 128,330 | 349 |

機能別にまとめると (階層の値の和。子の和は rebuilt の帰属の揺れで `u_core` の値と 1 % ほど違う):

| 区分 | 含むもの | LUT | FF |
|---|---|---|---|
| VU | `u_vu`、`u_vrf`、`u_vua`、`u_vum` | 98,885 | 10,414 |
| CSR (PMP 検査を含む、§5 の P) | `u_csr` | 42,396 | 8,032 |
| 実行 port (ALU、BRU、MUL、DIV、FPU) | `g_ep[*]` | 42,348 | 4,428 |
| LSU | `u_sq`、`u_lq`、`u_sb`、`g_mp`、`u_at`、`u_io`、`u_arb` | 61,026 | 33,333 |
| dcache | `u_dc` | 40,626 | 15,917 |
| 前段 | `u_bpu`、`u_ftq`、`u_ifu`、`u_ic`、`u_ext`、`u_islot` | 39,768 | 16,904 |
| PRF | `u_prf_i`、`u_prf_f` | 24,901 | 10,240 |
| MMU | `u_dtlb`、`u_itlb`、`u_dptw`、`u_iptw`、`u_xctx` | 30,027 | 7,906 |
| rename と dispatch | `u_ren`、`u_rq`、`u_fl_*`、`u_bt`、`u_dp`、`u_dec` | 15,235 | 4,797 |
| ROB、commit、flush | `u_rob`、`u_commit`、`u_flush`、`u_trap` | 12,617 | 11,747 |
| IQ | `g_iq[*]` | 9,765 | 4,416 |
| debug | `u_trig` | 859 | 190 |

### 2.2 W4 core (`core_w4`)

全体: LUT 807,513 (logic 780,105、LUTRAM 27,408)、FF 195,535、CARRY8 27,919、F7 92,008、F8 34,569、BRAM 0、DSP 372。

| block | LUT | LUTRAM | FF | DSP |
|---|---|---|---|---|
| `u_sq` | 87,875 | 0 | 16,466 | 0 |
| `u_vu` | 83,644 | 0 | 5,441 | 308 |
| `u_csr` | 62,271 | 0 | 8,634 | 0 |
| `u_rob` | 49,175 | 0 | 23,541 | 0 |
| `u_dc` | 47,763 | 4,096 | 16,134 | 0 |
| `u_prf_i` | 44,185 | 0 | 10,240 | 0 |
| `g_mp[1].u_mp` | 40,349 | 0 | 2,594 | 0 |
| `u_lq` | 34,331 | 0 | 31,845 | 0 |
| `u_rq` | 31,189 | 0 | 2,148 | 0 |
| `g_mp[0].u_mp` | 29,685 | 0 | 2,752 | 0 |
| `g_ep[5].u_ep` | 28,798 | 0 | 2,556 | 24 |
| `g_ep[0].u_ep` | 22,923 | 0 | 382 | 0 |
| `u_sb` | 22,921 | 0 | 10,104 | 0 |
| `u_bpu` | 20,933 | 14,720 | 2,377 | 0 |
| `g_ep[4].u_ep` | 19,412 | 0 | 1,027 | 24 |
| `g_ep[1].u_ep` | 16,901 | 0 | 382 | 0 |
| `u_dptw` | 16,566 | 0 | 1,314 | 0 |
| `u_prf_f` | 14,999 | 0 | 6,144 | 0 |
| `g_iq[0].u_iq` | 12,127 | 0 | 3,488 | 0 |
| `u_ext` | 12,061 | 0 | 4,287 | 0 |
| `u_vrf` | 11,704 | 0 | 4,096 | 0 |
| `u_ic` | 11,671 | 8,592 | 2,152 | 0 |
| `u_ftq` | 10,110 | 0 | 10,654 | 0 |
| `g_ep[3].u_ep` | 8,814 | 0 | 982 | 0 |
| `u_dtlb` | 8,329 | 0 | 3,941 | 0 |
| `u_bt` | 6,675 | 0 | 512 | 0 |
| `u_itlb` | 6,579 | 0 | 1,876 | 0 |
| `u_iptw` | 6,444 | 0 | 842 | 0 |
| `g_ep[2].u_ep` | 5,573 | 0 | 683 | 16 |
| `g_iq[1].u_iq` | 4,548 | 0 | 2,016 | 0 |
| `u_ren` | 4,477 | 0 | 5,192 | 0 |
| `u_fl_int` | 4,426 | 0 | 1,065 | 0 |
| `u_commit` | 3,466 | 0 | 385 | 0 |
| `g_iq[2].u_iq` | 3,349 | 0 | 2,640 | 0 |
| `u_flush` | 3,295 | 0 | 198 | 0 |
| `u_trig` | 3,238 | 0 | 381 | 0 |
| `u_ifu` | 2,542 | 0 | 2,980 | 0 |
| `u_fl_fp` | 1,867 | 0 | 538 | 0 |
| `u_at` | 1,639 | 0 | 1,122 | 0 |
| `u_vum` | 1,066 | 0 | 561 | 0 |
| `u_vua` | 858 | 0 | 382 | 0 |
| `u_dp` | 596 | 0 | 2 | 0 |
| `u_arb` | 477 | 0 | 24 | 0 |
| `u_io` | 263 | 0 | 384 | 0 |
| `u_dec` | 112 | 0 | 0 | 0 |
| `u_islot` | 10 | 0 | 57 | 0 |
| `g_rs[6].u_rs` | 9 | 0 | 4 | 0 |
| `u_trap` | 6 | 0 | 0 | 0 |
| `u_xctx` | 2 | 0 | 0 | 0 |
| `g_rs[2].u_rs` | 0 | 0 | 1 | 0 |
| `g_rs[4].u_rs` | 0 | 0 | 1 | 0 |
| `g_rs[5].u_rs` | 0 | 0 | 1 | 0 |
| `g_rs[7].u_rs` | 0 | 0 | 4 | 0 |
| `u_dxarb` | 0 | 0 | 0 | 0 |
| 計 (`u_core`) | 802,601 | 27,408 | 195,532 | 372 |

### 2.3 観測の出力を残した場合

| | 機能の port だけ | 観測も残す (`*_obs`) | 差 |
|---|---|---|---|
| W4 core LUT | 807,513 | 886,273 | +78,760 (+9.8 %) |
| W4 core FF | 195,535 | 212,613 | +17,078 (+8.7 %) |
| W4 core DSP | 372 | 432 | +60 (`vu_adapter` の VRF hash) |
| W4 `u_rob` | 49,175 / 23,541 | 66,560 / 35,444 | +17,385 / +11,903 |
| W2 core LUT | 413,957 (SoC 内) | 433,401 | +19,444 (+4.7 %) |
| W2 core FF | 128,330 (SoC 内) | 137,629 | +9,299 (+7.2 %) |
| W2 core DSP | 349 (SoC 内) | 409 | +60 |
| W2 `u_rob` | 9,253 / 11,215 | 12,826 / 16,993 | +3,573 / +5,778 |

W2 の左の列は SoC の中の core の値で、右は core 単体なので、SoC との境界の最適化の差 (1 % 未満と見込む) を含む。

W4 で増えた FF の内訳 (cell 名): `rob.obs_q` 8,192、`rob.ent_q.insn` 4,027 (残りは同じ値の FF と併合)、`ftq.e_res.target` の上位 1,280 (機能では BTB の学習が下位 24 bit しか読まないので刈られている)、commit の `ret_q` 3,000 前後 (`rd_wdata`、`pc`、`next_pc`、`mem_*`、`csr_wdata`、`order`、`insn` など)、`order_q` 64、`vu_adapter.hash_q` と `o_done.side` 136、ほか。LUT は、ROB の `obs_q` と `insn` の書き込み (WB_N + 1 = 9 源の one-hot mux がエントリごと。実行 port の出力段に置かれた分を含む) が約 48,000、commit の retire record の組み立て (ROB の commit 窓からの読みを含む) が約 22,000、LQ の観測の窓 8,200、`vu_adapter` と `vu_mem_adapter` 16,300 など。

## 3. RAM の推論

### 3.1 L2 のデータ配列 (推論に失敗し、合成が止まる)

```
ERROR: [Synth 8-3391] Unable to infer a block/distributed RAM for 'data_0_reg' because the memory pattern
used is not supported. Failed to dissolve the memory into bits because the number of bits (262144) is too large.
```

`data_0..3` の 4 個すべて。読みが組合せで 3 口 (lookup、merge、RMW の旧値)、書きが RMW の mask 書きを含めて 3 口あり、BRAM にも LUTRAM にもならない。FF への展開も既定の上限を超える。上限を上げれば (`dissolveMemorySizeLimit`) 1 Mbit の FF と mux になり、W2 SoC の FF を 9 倍にするだけなので試していない。これは棚卸しの V1 (L2 のデータを 1R1W の同期読みにする) で直す。

### 3.2 推論の結果の一覧

| 配列 | W2 | W4 | 結果 | 原因 | 対応 |
|---|---|---|---|---|---|
| `l2cache.data_0..3` | 512 × 512 × 4 | 同じ | 失敗 | §3.1 | V1 |
| `bp_btb.mem_q` | 4096 × 90 | 4096 × 115 | LUTRAM (`RAM256X1D` × 1,440 / 1,840)。LUT 11,520 / 14,720 | 書きが `mem_q[w] = (mem_q[w] & ~mask) \| (data & mask)` (bit 単位の mask の RMW)。旧値の読みが非同期の 2 本目の読み口になり、BRAM の形 (同期読み 1 口 + 書き 1 口) から外れる | §5 の R1 |
| `dcache_bank.mem_q` | 64 × 1024 × 2 | 64 × 512 × 4 | LUTRAM (`RAM64X1D`)。LUT 4,096 | BTB と同じ RMW の mask 書き。64 深さなので FPGA では LUTRAM が適する | §5 の R1 (ASIC 向けだけ) |
| `icache_array.data_0..3` | 256 × 256 × 4 | 同じ | LUTRAM (`RAM256X1D` × 1,024)。LUT 8,192 | 読みが組合せ (`data_0[blk_i]`) で、RMW の mask 書きも持つ | V4 |
| `icache_array.tags_0..3` | 128 × 43 × 4 | 同じ | LUTRAM (`RAM64M8` × 56) | 組合せ読み。128 × 43 は LUTRAM で妥当 | なし |
| `dcache_tagbank.tags_0..3` (複製 6 / 7 組) | 64 × 4 way × 44 | 同じ | FF に展開 (Synth 8-4767: 非同期リセットに敏感)。FF 12,224 + 読みの mux LUT 約 18,000 (W2) / 27,000 (W4) | リセット付きの `always_ff` の中で書く | V8 (§5 の R2) |
| `mem_ctrl.wb_data`、`wb_strb` | 書き込みバッファ | 同じ | FF に展開 (非同期リセット) | 同上 | V6 |
| `rename.g_pool.img_q` | checkpoint | 同じ | FF に展開 (port 数 16 が上限) | 多ポート | V5 |
| `rob.ent_q`、`snap_q`、`res_q`、IQ、LQ/SQ、FTQ、DQ など struct の配列 | | | FF (Synth 8-5858: struct の RAM は未対応) | 多ポートの R/F 区分で、もともと FF の想定 | なし |
| 定数 index で書く小配列 (13 / 15 個) | | | FF (8-4767: write port has constant address) | 想定どおり | なし |

`report_ram_utilization` の結果も BRAM 0、URAM 0 だった。W4 の LUTRAM 27,408 の内訳は BTB 14,720、icache 8,592 (データ 8,192 + tag 400)、dcache のデータ 4,096。

## 4. ROB の大きさ

### 4.1 構造

`rob` (W2 / W4): ROB_N 64 / 128。書き口: dispatch の RENAME_W 2 / 4 lane (`ent_q`、`snap_q`、`done_q`)、WB の WB_N 3 / 8 port と VU の完了 (`done_q`、`ffl_q`、`obs_q`)、BRU の port (`res_q`)。読み口: commit 窓 CW 2 / 4 (`ent`、`done`、`fflags`、`res`、`recovered`、`obs`)、walk の 2 × WALK_W = 4 / 8 (`has_rd`、`cls`、`rd_arch`、`old_pdst`)、flush_ctrl の snapshot 1 (`snap_q`)。全部の配列がリセット付きの `always_ff` の中で書かれ (V7)、struct の配列なので FF になる。

### 4.2 内訳 (機能の port だけの合成、cell 名で集計)

LUT はほとんどが ROB の階層に入るが、消費側の register の名前で呼ばれる (例: commit の `arch_pc_q`、flush_ctrl の `kill_q`)。下の「読み」はそれらの和である。

| 部分 | W2 LUT | W2 FF | W4 LUT | W4 FF |
|---|---|---|---|---|
| `ent_q` (RobEnt、`insn` を除く) の記憶と dispatch の書き | 476 | 3,904 | 10,934 | 8,448 |
| `res_q` (`next_pc` 64 + `mispred` + `taken`) の記憶 | 19 | 4,224 | 61 | 8,448 |
| `res_q.next_pc` の書き (BRU の出力段に置かれた分) | 約 270 | | 8,362 | |
| `snap_q` (DispSnap) の記憶と書き | 567 | 2,304 | 7,312 | 5,376 |
| `done_q`、`rec_q`、`ffl_q` | 153 | 448 | 553 | 896 |
| commit 窓の読みと pointer、exc_q など | 6,434 | 301 | 26,623 | 309 |
| walk の読み (2 組) | 1,041 | 34 | 4,334 | 64 |
| snapshot の読み (flush_ctrl へ) | 841 | | 1,473 | |
| 計 (ROB の階層) | 9,531 | 11,215 | 51,290 | 23,541 |

- port あたり: W4 の commit 窓の読みは 1 lane あたり約 6,600 LUT (128:1 の mux が約 140 bit。1 bit あたり LUT 32 + MUXF 24)。walk の読みは 1 組 (WALK_W 本) あたり約 2,200 LUT。dispatch の書きは 4 lane の one-hot mux で FF 1 bit あたり約 1.3 LUT、W2 の 2 lane は FF の CE と D の LUT にほぼ収まる。
- `res_q.next_pc` (決定済みの G) は W4 で FF 8,192 (ROB の FF の 35 %)、書き 8,362 LUT、commit の pc の連鎖への読み約 3,000 LUT で、合計約 19,600。W2 は FF 4,096 と LUT 約 800 で約 4,900。
- `obs_q` と `insn` (決定済みの E) は、この合成では 0 である (Vivado が刈った。W2 の `g_ent.insn` 90 FF は `rd_arch` と同値の FF の併合で、実体は `rd_arch`)。観測の port を残すと W4 で FF 12,219 と LUT 約 48,000 になる (§2.3)。報告者が見た「大きい ROB」は W4 なら LUT 66,560 / FF 35,444 で、そのうち FF の 35 % が観測 (`obs_q`、`insn`)、23 % が `next_pc` だった。
- 残りの大きさの源は、多ポートの FF 配列という構造そのもの (commit 窓 4 lane × 128 エントリの読みと 4 lane の書き) で、これは性能 (幅) の代金である。

## 5. 純粋な無駄の一覧

対象: 振る舞い (cycle、retire の列) を変えずに消せるもの。並びは W4 の LUT + FF の節約の順。「実測」は合成の値、「推定」は実測した部品の原価からの見積もり。すべて判断待ち。

| # | 対象 | 節約 W2 (LUT / FF) | 節約 W4 (LUT / FF) | 根拠 |
|---|---|---|---|---|
| O1 | 観測専用の論理 (retire record、perf、VRF hash、schedule replay) を define で外す | 19,444 / 9,299 + DSP 60 | 78,760 / 17,078 + DSP 60 | 実測 (§2.3)。top が観測の port を出す場合 |
| P | PMP 検査の重複 | 約 41,000 / 0 | 約 62,000 / 0 | 部品の実測 + 推定 |
| S1 | SQ の forwarding の line 画像 | 約 9,000 / 0 | 約 24,000 / 0 | 実測の内訳 + 推定 |
| R2 | dcache tag の複製の FF 展開 (V8) | 約 16,000 / 12,224 | 約 25,000 / 12,224 | 実測 + 推定 |
| G | `rob.res_q.next_pc` (決定済み) | 約 800 / 4,096 | 約 11,400 / 8,192 | 実測 |
| R1 | BTB が BRAM にならない | LUTRAM 11,520 → RAMB36 約 10 | LUTRAM 14,720 → RAMB36 約 13 | 実測 |
| F | 例外記録 (決定済み) | 小 / 約 5,300 | 小 / 約 10,600 | 実測の FF から |
| H | LQ の byte mask (決定済み) | + decoder / 4,096 | + decoder / 8,192 | 実測の FF |
| C1 | CSR の幅と死んだ状態 | 約 1,000 / 約 2,300 | 同じ | 実測の FF |
| S2 | SQ の forwarding の byte ごとの age 木 | 要測定 (最大 約 13,000) | 要測定 (最大 約 37,000) | 推定 |
| W1 | ROB の walk の読みが 2 組 | 約 500 / 0 | 約 2,200 / 0 | 実測の内訳 |

### O1. 観測専用の論理 (判断待ち)

- 何か: `rob.obs_q` と `RobEnt.insn` (E)、commit の `ret_q`、`order_q`、`evt_q`、LQ/SQ の `o_win[].obs`、`vu_adapter` の `hash_q` と `o_done.side` (VRF hash に DSP 60)、csr の 2 本目の読み口 (`i_obs_addr` → `o_obs_data`)、FTQ の `e_res.target` の上位 bit、`perf` の配線 (`hpm_ev` の 7 本を除く)、`i_dbg_retire_limit*` と `i_dbg_irq_*` (schedule replay、tb 専用) とそれを比べる `order_q` の 64 bit の比較 3 個。
- 実測: W4 で LUT 78,760、FF 17,078、DSP 60 (core の LUT の 9.8 %)。W2 で LUT 19,444、FF 9,299、DSP 60。
- なぜ純粋か: どれも機能の論理に戻らない。機能の port だけの合成で Vivado がすべて刈ったことがその証拠である (刈れないものは機能の論理が読んでいる)。cycle は変わらない。
- 修正: D-3 で決めた define (例 `HELIODOR_RETIRE`) を ROB の 2 field だけでなく上の全部に使い、define の無い build では `o_retire`、`o_irq_evt`、`o_retire_dm`、`o_perf` (HPM の 8 bit を除く) を 0 に、`i_dbg_*` を未使用にする。`Veryl.toml` の `[test].defines` に入れ、lockstep、cosim、bench (perf を読む) は今までどおり動かす。SoC の port は残してよい (0 を出すだけ)。
- リスク: 低。define の有無で機能の論理が変わらないことは、機能の port だけの合成と define 無しの合成の使用量が一致することで確かめられる (両方のフローがこのスクリプトにある)。注意: perf のうち `hpm_ev` (mhpmevent の event 7 本) は CSR が読むので残す。

### P. PMP 検査の重複 (判断待ち)

PMP の検査器 (`src/mmu/pmp_check.veryl` の `pmp_range_check`、`pmp_check`) は、16 エントリのそれぞれについて NAPOT の mask (54 bit の加算)、TOR の 2 つの 54 bit 比較、NAPOT の比較を行い、一番小さい一致エントリを選ぶ。core はこれを次の数だけ instance している。

| 置き場所 | 数 | 内容 |
|---|---|---|
| `mem_pipe` の m1 | 3 × MEM_W | 同じ範囲を read、write、execute で 3 回 |
| `ptw` (D と I の 2 個) | 5 × 2 | PTE の読み書きの範囲を read と write で 2 回、最後の PA を read、write、execute で 3 回 (`acc` で 1 つを選ぶ) |
| `ifu` | GRAN_N = 4 / 8 | fetch block の 4 byte ごとに 1 回 (アドレスは `pa + 4g`) |

実測 (`syn_pmp.sv`、同じ part): 1 個 4,310 LUT + CARRY8 564。同じ範囲の 3 個は 12,611 LUT で、共有はほぼ起きない (2.93 倍)。`ifu` の形の 4 個は 14,536、8 個は 29,054 LUT。core の中で PMP の比較に帰属する LUT (cell 名で `f1_q.id`、`data_q.exc`、`resp_q.exc`、`w_*_q`) は W2 で約 55,800、W4 で約 86,100 (CARRY8 が別に 5,300 / 8,500) で、W2 core の LUT の 13 % に当たる。CSR の階層の 42,396 / 62,271 LUT の大半はこれで、CSR 自身ではない。

- P1 (`mem_pipe`): 一致の計算は access の種類に依存しない (`perm` の選択だけが `i_acc` に依る)。一致を 1 回だけ計算し、一番小さい一致エントリの R/W/X/L と「全 byte が一致したか」を返す検査器にして、3 つの fault をそこから作る。節約 8,300 LUT / pipe (実測の差)。W2 8,300、W4 16,600。
- P2 (`ptw`): PTE の 2 個を 1 個に (節約 約 4,300)、最後の 3 個を 1 個に (`pmp_check` 1 個は 4 個組の実測から約 3,600 なので節約 約 7,200)。walker あたり約 11,500、2 個で約 23,000 (両構成)。最後の 3 個は `acc` で 1 つしか使わず、AMO が R と W の両方を見るだけである。
- P3 (`ifu`): fetch block は 1 つの 64 byte の塊に収まるので、PA[55:6] の比較 (TOR の大小と NAPOT の一致の上位) はすべての granule で同じである。上位の比較を 1 回だけ行い、granule ごとには下位 4 bit の比較だけを行う (`pmp_range_check` がすでに範囲の両端について同じことをしている)。推定: 1 個分 + granule あたり数百 LUT で、W2 約 5,000 (節約 約 9,500)、W4 約 6,000 (節約 約 23,000)。
- P4: NAPOT の mask (`this_a ^ (this_a + 1)`)、TOR の下限、cfg の decode はエントリの CSR だけの関数で、すべての検査器が同じものを計算している。csr で 1 回だけ組合せで計算して配る (register にしない。書き込みの次のサイクルから見える今の時間関係を保つ)。推定: 残る検査器 1 個あたり約 900 LUT (要測定)。
- なぜ純粋か: どの変更も同じ真理値表を少ない論理で作るだけで、検査の結果、時期、cycle は変わらない。
- 修正の形: `pmp_match` (一致エントリの one-hot、全一致、R/W/X/L、一致の有無) を 1 つ作り、`pmp_range_check` と `pmp_check` はその上の permission の選択にする。
- リスク: 低-中。ACT4 の PMP (`project_act4_pmp` の全 pass 済みの suite)、rv64mi、PTW の H の検査 (hvlinux) が判定になる。P3 は 64 byte の塊の前提 (fetch block が塊をまたがないこと) を module header に書く。D-2 (PA 40 bit) は比較の幅を 54 から 38 bit にするので、P の残りがさらに約 30 % 減る。
- 確認が要る点 (要確認): `ptw` の最後の PA の検査は `mem_pipe` の m1 の検査と同じ PA を同じ権限で見ているように読める。walk の応答が fault を持ち帰るためだけなら、片方は不要かもしれない。この文書では両方を残す前提で数えた。

### S1. SQ の forwarding の line 画像 (判断待ち)

`sq.veryl` の forwarding は、エントリごとに 16 byte の data を 64 byte の line 画像 (`lo_d`: 512 bit を `e_dw0` で 8 位置にずらす) に置き、load の query ごと、エントリごとにその画像を `dw` で 128 bit に切り出す (`sd = d >> {dw, 6'd0}`)。mask も同じ (`lo_m64`、`sm`)。cell 名で `e_data` と呼ばれる LUT が W2 11,420、W4 32,189 あり (エントリ 16 / 32、query 1 / 2)、エントリあたり約 1,000 LUT (W4) で、ほぼこの 2 段のずらしである。

- 修正: store の 16 byte の窓と load の 16 byte の窓が重なるのは `e_dw0 - dw` が -1、0、+1 のときだけである (hi の line は `dw` = 0 のときだけ)。query ごと、エントリごとに 128 bit の 3:1 の選択と、line の端を越える byte の mask にする。cbo.zero (`e_full`) は「窓の中の line 内の byte を全部覆い、data は 0」のまま。推定: query × エントリ × 約 130 LUT で、W2 約 2,100、W4 約 8,300 になり、節約は W2 約 9,000、W4 約 24,000。
- なぜ純粋か: 各 byte の cov と data の値は同じ式の別の書き方で、forwarding の結果と cycle は変わらない。
- リスク: 低-中。正しさは test_lsu、litmus、boot。同じ形の検査を `tb/test_vmspre.veryl` の型で、旧式との全数比較 (dw0、dw、mask、full、hi) にできる。
- 重なり: K (`sq.e_data` の上位 64 bit を amocas.q 用の 1 本に) を入れると data の幅が 64 bit になり、S1 の後の選択も半分になる。

### R2. dcache tag の複製の FF 展開 (判断待ち、V8 と同じ修正)

`dcache_tagbank` の tag (64 set × 4 way × 44 bit) は MEM_W + 5 組 (W2 6 組、W4 7 組) あり、リセット付きの `always_ff` で書かれるので FF 12,224 になり、各組の 64:1 の読みの mux が LUT 約 3,000 ずつ (W2 で約 18,000、W4 で約 27,000) かかっている。V8 (リセットの無い書き) を入れれば、各組は 64 深さの 1 書き 1 読みの LUTRAM (`RAM64M8`) になる。推定: 1 組 4 way × 44 bit で約 200 LUTRAM、6 / 7 組で約 1,200 / 1,400。節約は FF 12,224 と LUT 約 16,000 / 25,000。D (読み手の時分割) は性能の判断が要るので別。

- なぜ純粋か: tag の内容は valid で守られているので、リセットで tag を 0 にする必要は無い (V8 の論拠)。cycle は変わらない。
- リスク: 低 (V8 と同じ)。

### G. `rob.res_q.next_pc` (決定済み)

§4.2 のとおり W4 で FF 8,192 + LUT 約 11,400 (書き 8,362 + commit への読み 約 3,000)、W2 で FF 4,096 + LUT 約 800。FTQ から読む口を足す代金 (lane あたり 64 bit × 32:1 の読み、W4 で約 2,000 LUT) を引いた値が純節約になる。

### R1. BTB が BRAM にならない (判断待ち)

D-1/V3 で BTB を「リセット無しの 1R1W 同期読み」にしたが、書きを `mem_q[w] = (mem_q[w] & ~mask) | (data & mask)` (bit mask の RMW) で書いたため、Vivado は旧値の読みを非同期の 2 本目の読み口とみなし、BRAM ではなく LUTRAM にした (W4: `RAM256X1D` × 1,840、LUT 14,720)。`dcache_bank` も同じ形で LUTRAM (4,096 LUT)。

- 修正: BRAM の書き込みは byte (8/9 bit) 単位の enable しか持たない。BTB は field ごとに書くので、(a) 行を「一緒に書く field の組」ごとの別の配列に分ける (BtbRow の vld+tag、slot ごと、tail)、または (b) 行を 9 bit の lane に並べ直して field 単位の書きを lane の enable にする。`dcache_bank` は byte の strobe なので `for b { if mask_byte[b] { mem_q[w][b*8+:8] = d } }` の形にすれば byte enable の RAM として推論される。ただし `dcache_bank` は 64 深さで幅が広く、FPGA では LUTRAM (`RAM64X1D`、1 bit 1 LUT) の方が BRAM (幅 72 の RAMB36 を 8 個並べて深さの 1/8 しか使わない) より効率がよいので、FPGA の面積の無駄ではない。書き方を直す意味は ASIC の macro への対応だけである。
- なぜ純粋か: 記憶の中身と読みの時期は変わらない。
- 節約: BTB の LUTRAM 14,720 (W4) / 11,520 (W2) が RAMB36 約 13 / 10 (4096 × 9 bit の構成で 115 / 90 bit) になる。ASIC では SRAM macro が bit 単位の write enable を持つかどうかで同じ問題になる。
- リスク: 低。BTB の read-old の約束 (`doc/phase15_ms_sizing.md` §3.1) を保つこと。

### F、H (決定済み)

合成での FF (tval + gpa): W2 は LQ 4,032、SQ 2,016、DQ 1,008、RQ 504 (計 7,560)、W4 は 8,064、4,032、2,016、1,008 (計 15,120)。F (tval を持たず、gpa を 39 bit) で約 70 % が消える。H の `lq.e_lm0`、`e_lm1` は W2 4,096、W4 8,192 FF。H は CAM のエントリごとに decoder を足すので、純節約は FF から decoder の LUT を引いた値になる (要測定)。

### C1. CSR の幅と死んだ状態 (判断待ち)

合成で残っている FF のうち、値が取りうる範囲より広いもの:

| CSR | 今 (FF) | 必要 | 根拠 |
|---|---|---|---|
| `mhpmcounter[0..2]`、`mhpmevent[0..2]` | 192 + 192 | 0 | 番号 0-2 は mcycle、minstret などで、この配列の index 0-2 は decode で届かないが、`wr_a[4:0]` の動的な index のため合成が消せない |
| `mhpmevent[3..31]` | 1,856 | 約 290 | L (sizing §2.1) と同じ |
| `vl` | 64 | 8 | vl ≤ VLMAX = 128 |
| `vtype` | 64 | 9 | vill + vtype[7:0] |
| `mcause`、`scause`、`vscause` | 192 | 21 | interrupt bit + 6 bit の code。xcause の code は WLRL |
| `mtinst`、`htinst` | 128 | 4 | trap が書く値は 0、0x3000、0x3020 だけ。WARL で、自動で書く値だけを持てればよい |

計 約 2,300 FF と、その書きと読みの mux。なぜ純粋か: 保持できる値の集合は spec の WARL/WLRL の範囲で、trap と命令が書く値は変わらない。リスク: 低。ACT4 の CSR の読み戻しの検査 (書いた値がそのまま読めることを期待するもの) が WARL の範囲で書かれているかを確かめる。

### S2. SQ の forwarding の byte ごとの age 木 (要測定)

forwarding は byte (16 個) ごとに `tree_oldest` (tag の比較を節点に持つ木) で一番新しい候補を選ぶ。cell 名 `fwd_dat` が W2 15,552、W4 43,900 LUT で、`fwd_cov` が 2,285 / 5,914。候補はすべて生きているエントリで ring の上の 1 つの窓にあるので、年齢の順は `sq_lim` を基準にした index の回転で決まる。query ごとに 1 回だけ回転 (または年齢の順位を作る) し、byte ごとには優先度の符号化 (find-first) と one-hot の data の選択だけにできる。tag の比較を byte ごとに 31 回行う今の形との差は、推定で W2 最大 約 13,000、W4 最大 約 37,000 LUT。推定の幅が大きいので、`tree_oldest` の形と回転の形を単体で合成して測ってから決める。なぜ純粋か: 選ぶエントリは同じ。CP も短くなる見込み。

### W1. ROB の walk の読みが 2 組 (判断待ち、CP の確認が要る)

walk は kill の直後の組 (`k_batch`、`tail_q` から) と続きの組 (`c_batch`、`wtop_q` から) を両方読み、最後に選ぶ。同じサイクルに使うのは片方だけなので、読みの基点を先に選べば (`start ? tail_q : wtop_q`) 読みは 1 組で足りる。節約は W4 約 2,200 LUT + MUXF 1,350、W2 約 500。cycle は変わらないが、`i_kill` から読みの mux の前に選択が入るので CP の経路が延びうる。CP の分解で問題が無いと分かってから入れる。

### 対象外 (性能との引き換え、記録だけ)

- VU (W2 で LUT 98,885、core の 24 %)。VU は自分の FP 器 (`u_vfpu` 21,539 LUT) と除算器を持ち、スカラの FPU と共有しない。共有は構造の衝突を作るので性能の判断である。VU の中の `o_vd_data` の各源 (`fp_acc_next`、`pm_acc_next`、`mem_wr_data`、`cmp_res` など) がそれぞれ 128 bit の要素挿入 (可変量のずらしと mask) を持っており、書き込みは 1 口なので挿入を 1 段にまとめられる可能性がある。これは純粋な重複の候補だが、VU の中を読み切っていないので一覧に入れていない (次の調査の候補)。
- dcache tag の読み手の時分割 (D)、BTB の大きさ、ROB/LQ/SQ/IQ の深さ、PRF の port 数、LQ の CoRR の line 比較 (`e_poison` W4 18,157 LUT。MEM_W × 2 half × COH_N の 50 bit 比較で、PA 40 bit (D-2) で 34 bit になる)。
- PA 幅 (D-2) は P、LQ/SQ の line 比較、dcache/L2 の tag をまとめて縮める。今回の合成は 56 bit のままである。

## 6. 次の手順の案 (判断待ち)

1. O1 の define の範囲と名前を決める (D-3 の拡張)。
2. P、S1、R1、R2、C1 を入れるか。P と S1 はそれぞれ単独のモジュールの変更で、旧式との全数比較 (P は ACT4 の PMP も) で判定できる。
3. S2 と P4 は単体の合成で測ってから決める。
4. MS の出口条件 (L2 込みの SoC の合成の完走) は V1 が入るまで満たせない。V1 の後にこのフロー (`soc_w2_l2`) を回す。
