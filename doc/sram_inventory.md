# Realistic-SRAM migration — 28-RAM inventory (`heliodor_core`)

> ## ✅ PHASE-1 CLOSE-OUT (2026-07-17) — the realistic-SRAM migration (campaign goal ③) is DONE
>
> The tables below are the **Phase-0 baseline** (targets, on `c09f99c`). What SHIPPED (default-on,
> full-SMP-ladder + Verilator N1/N2 verified — see `cp_dcache_sync_read_plan.md`, `cp_l2_sync_read_plan.md`,
> `cp_dcache_data_write_collapse`):
> - **D$ data array `64×512 ×4`: 9R4W → TRUE 1R1W** (`DCACHE_DATA_1RW` byte-write-enable +
>   `DCACHE_DATA_READ_1R` read-fold + `DCACHE_CAP_1R` writeback-capture fold). Synchronous read = a stage.
> - **D$ tag array `64×52 ×4`: 15R1W → 13R1W** + demand-hit from registered tags (`DCACHE_TAG_READ_1R`,
>   §15.5-S1). Further port reduction (§15.5-S2, `index` fold → 12R1W) is un-built (a DEAD next step).
> - **L2 data `512×512 ×4`: TRUE 1R1W** (byte-write-enable + `L2_PORTS_1R1W` write-collapse) + synchronous
>   read (`L2_SYNC_READ`). L2 read-port fold (`L2_READ_1R1W`) is a DEAD scaffold (un-flipped).
> - **Predictor tables** (btb/bht/ibtb) + **icache**: sync-read scaffolds BUILT but DEAD (`*_SYNC_READ=0`,
>   `ICACHE_SYNC_READ=0`) — they flip with the Phase-D front-end deepening (a future program).
>
> Full knob map (live / dead-scaffold / bisect): **`doc/pipeline_knob_registry.md`**. Campaign status +
> target revision: `deep_pipeline_status_and_replan.md` §8.2. The caches are on realistic 1RW/1R1W SRAM;
> the remaining un-flipped folds (D$ tag §15.5-S2, L2 read-1R1W, predictor/icache sync) are documented DEAD
> scaffolds for the front-end/L2 follow-on, not gaps in the shipped design.

Phase-0 deliverable for the deep-pipeline + realistic-SRAM campaign
(`doc/deep_pipeline_sram_plan.md`). Each of the 28 RAM blocks `veryl synth
--top heliodor_core --dump-area` infers, mapped to its RTL declaration, with
logical ports, access pattern, and a 1RW / 1R1W / banked / replicated / keep-flop
target. Re-measured on master `c09f99c`.

## Scope note (why no L2 / no 512×512)
Synth top = `heliodor_core` (a **single** core). The shared **L2 cache + `mem_ctrl`
+ `memory_bus`** are instantiated one level up (`heliodor_soc{,_smp}.veryl:482`),
**outside** this synth — so l2 data (`logic<512>[512]`×4), l2 tags (`512×49`×4),
l2 plru/state are **not** in these 28. They join the inventory when the migration
reaches the SoC level (Phase C extends to L2 as 1R1W + fill buffering).

## Refinement to the plan's flop assumption
`deep_pipeline_sram_plan.md` assumed "PRF/VRF/ROB/RAT/SB/MSHR/**TLB**/IQ stay flop."
Two of those actually **infer as RAM** and appear below: `iq_int.ops` (8×309 2R2W)
and `mmu.v1_ppn` (32×44 1R3W ×2). Recommendation: **keep BOTH flop.** `iq_int.ops` is
tiny + on the wakeup→select critical path. `mmu.v1_ppn` (⟵ REVISED 2026-07-06 from the
earlier "trivial 1RW") is the **V=1 two-stage TLB's host-PPN store — a TLB, which the
plan keeps flop**; at **32 entries** it is below any SRAM compiler's practical minimum
(~64-128 words), so real PD maps it to flops regardless. veryl infers it as RAM only
because of the 44-bit *width* (the sibling `v1_r/w/x/u/level` read the same `[v1_sel]`
index but are too narrow to infer) — a model artifact, not a migration target; forcing
a 1RW here would be a risky consolidation of the correctness-critical H-ext two-stage
walk (GST_L2/L1/L0, each writing a level-dependent `g_hpa`) for a flop-anyway array.
Everything else the plan called flop (valid/dirty/excl/plru meta, V=0 TLB, TAGE) is read
*associatively every cycle* and correctly stays flop (never inferred as RAM).

## Geometry (all instances use module defaults)
- **dcache** `INDEX_W=6` → SETS=64, TAG_W=52; data `logic<512>[64]`×4 ways.
- **icache** `INDEX_W=6` → SETS=64, TAG_W=52; data `logic<32>[1024]`×4 ways.
- **btb** `IDX_W=12` → ENTRIES=4096, TAG_W=51.  **bht** ENTRIES=8192.
- **ibtb** `IDX_W=9` → ENTRIES=512, TAG_W=16.
- **mmu** (×2: imem + dmem) V=1 TLB 32-deep.  **iq_int** `IQ_N=8`, RenamedOp ≈ 309 b.

## The 28 blocks

| RAM signature | module.array (file:line) | ports | reads / writes | conflict freq | SRAM target + rationale |
|---|---|---|---|---|---|
| **4096×64 ×1** | `btb.target` (btb.veryl:58) | 2R1W | R: lookup `i_pc` + slot-1 `i_pc2`; W: taken-branch retire train | R/cy, W rare | **1R1W** — drop or replicate slot-1 read |
| **4096×51 ×1** | `btb.tag` (btb.veryl:57) | 2R1W | as target | same | **1R1W** — co-located with target |
| **4096×1 ×4** | `btb.is_cond/call/ret/ind` (btb.veryl:59-62) | 2R1W | as target | rare W | **fold into target's 1R1W word** (single-bit ×4) |
| **64×512 ×4** | `dcache.data_0..3` (dcache.veryl:256-259) | **9R4W** | R: hit/victim/next-hit/probe/flush/wb muxes; W: store-merge / AMO-excl 128b / fill | **load read /cy, write collides w/ fill** | **banked 1RW + write-merge buffer** — register way-mux (9R→1R, Phase C), serialize 4 writes; per-way line-wide single-port macro. **The hardest.** |
| **512×64 ×1** | `ibtb.target` (ibtb.veryl:47) | 2R1W | R: lookup×2; W: train | R/cy, W rare | **1R1W** |
| **8192×2 ×1** | `bht.ctr` (bht.veryl:37) | **4R2W** | R: 3 lookup ports; W: saturating RMW train | 3R/cy, RMW W frequent | **1R1W + replicate-for-reads** — 2-bit counters; replicate for the 3 reads, 1R1W counter macro for the RMW |
| **64×52 ×4 (13R1W)** | `dcache.tags_0..3` (dcache.veryl:249-252) | **13R1W** | R: hit-compare + victim/next/probe/flush/wb (15 sites); W: fill | tag read every load | **register tag read → 1RW (Phase C)** or replicate ×4 |
| **64×52 ×4 (4R1W)** | `icache.tags_0..3` (icache.veryl:82-85) | 4R1W | R: hit/next-line/non-leaf/prefetch; W: fill | fetch read + 3 probes | **1R1W (register fetch read, Phase D)** |
| **512×16 ×1** | `ibtb.tag` (ibtb.veryl:46) | 2R1W | R: lookup×2; W: train | R/cy, W rare | **1R1W** — co-located w/ ibtb.target |
| **32×44 ×2 (1R3W)** | `mmu.v1_ppn` (mmu.veryl:306), imem+dmem | 1R3W | R: `v1_ppn[v1_sel]`; W: 3 mutually-exclusive G-stage refill arms | R on G-hit, W rare | **1RW** — single read, exclusive refill writes |
| **8×309 ×1 (2R2W)** | `iq_int.ops` (iq_int.veryl:169) | 2R2W | R: `ops[issue_idx]`,`ops[issue_idx2]`; W: `ops[free_idx]`,`ops[free_idx2]` | **2R+2W collide every cycle** | **KEEP-FLOP** — 2.5 Kb, on the wakeup→select critical path; RF cheaper/faster than banked SRAM here |

Block count: 1+1+4+4+1+1+4+4+1+2+1 = **28.** ✓

## Hard multi-port problems (ranked) & migration order
1. **dcache data `64×512 9R4W ×4`** — central Phase-C target. Register the way-mux →
   synchronous 1-cycle read (9R→1R), serialize 4 writes through a write-merge buffer,
   per-way line-wide single-port macro. **This is the E0 warm-up scaffold's array.**
2. **dcache tags `64×52 13R1W ×4`** — register the tag read (Phase C) or replicate.
3. **bht `8192×2 4R2W`** — replicate for 3 reads + 1R1W counter macro for RMW.
4. **iq_int ops `8×309 2R2W`** — **keep flop** (do not migrate).

**Order** (real SRAM = synchronous → migration *forces* the pipeline-stage split, so
this co-runs with Phases C/D of the deep-pipeline plan):
1. **Phase C — dcache:** `data 64×512` (biggest area + the `dirty_0`/`valid_*` front
   that is the synth headline #6+), then `tags 64×52`. Registering the way-mux read
   both infers a real 1RW SRAM *and* stages the load pipe.
2. **Phase D — icache + predictors:** icache `tags 64×52` + `data 1024×32` (register
   fetch read), then btb / ibtb / bht as 1R1W.
3. **mmu `v1_ppn` ×2** — trivial 1RW, fold in opportunistically.
4. **Keep flop:** `iq_int.ops`, all associatively-read valid/dirty/excl/plru meta,
   the V=0 TLB, and TAGE (never inferred as RAM).

## Tie to the keystone
The dcache `valid_*` front (synth #6, 14.870) is cut by the **Phase-C dcache
synchronous-read** migration (#1 above) — which is the **E0 warm-up scaffold** in
`doc/speculative_wakeup_design.md §9`. So the SRAM migration's first step and the
keystone campaign's de-risking warm-up are the **same RTL change**.

## Migration status

- **✅ Predictors → 1R1W (2026-07-06, byte-identical, `--dump-area`-confirmed).** The
  branch-predictor SRAM arrays were narrowed to realistic **1R1W** (no compiler offers
  the old 2R1W / 4R1W) by **replication-for-reads** — each read port gets its own copy,
  the commit train writes all copies identically, so behavior is byte-identical (only
  the port count / macro shape change; the read stays combinational — the synchronous
  read is the fetch-decouple bundle). Verified: default 252/0, litmus N2 `cy=0022a330`,
  **N1 boot cy-EXACT** (7.1 `01210060`, 6.6 `013ee8a0`, both == baseline).
  - `btb` (`btb.veryl`): 6 arrays (target/tag/is_cond/call/ret/ind, 2R1W) → **one packed
    `{meta,target,tag}` word ×2 copies = `4096×119 1R1W ×2`** (slot-0 reads `d0`, slot-1
    reads `d1`). `valid` stays a reset flop array. Block count 6→2.
  - `ibtb` (`ibtb.veryl`): target+tag (2R1W) → **`512×80 1R1W ×2`** (packed `{target,tag}`,
    replicated). `valid` stays flop.
  - `bht` (`bht.veryl`): `ctr` (3 lookup reads + train RMW) → **`8192×2 1R1W ×4`**
    (`ctr_a/b/c/d`; copy d is the RMW read-old+write, same index). Block count 1→4.
  - **Area note:** the btb slot-1 replication doubles a 4096-deep table (~3.95M um²).
    Byte-identical replication is the conservative default; dropping the slot-1 btb read
    (lose dual-issue btb prediction) would avoid the doubling — a future perf/area tuning.
  - Total inferred-RAM blocks 28 → **27** (btb −4, bht +3). Remaining non-1R1W:
    dcache data `9R4W` / tags `14R1W`, icache data `2R2W` / tags `4R1W`,
    `mmu.v1_ppn 1R3W` (**keep-flop** — TLB, 32-entry flop-territory; see §Refinement),
    `iq_int.ops 2R2W` (keep-flop).

- **Landscape after the predictors (independent port-narrowing vs bundle).** The
  independently-landable, byte-identical *port-narrowing* (replicate-for-reads while
  the read stays combinational) splits the remaining RAMs cleanly:
  - **icache** (`icache.veryl`, tags `4R1W`, data `2R2W`) — NOT a clean standalone
    (checked 2026-07-06): the data `2W` is the fill's adjacent lo/hi 32-bit word writes
    (`fill_widx_lo/hi`), so `1W` needs a **64-bit-dword widen** (SETS×8 × 64, rewriting
    every 32-bit read extraction); the tags `4R` includes two prefetch reads
    (`nl_index`/`pf_index`) feeding the OFF prefetch (`s11_pf_en=0`), so a clean `1R1W`
    needs DCE-cleanup or absurd 4×-per-way replication. Both are intertwined with the
    fetch read structure the **sync-read (fetch-decouple) bundle restructures anyway** →
    **fold the icache port-narrowing INTO that bundle**, not a standalone landing.
  - **dcache** (tags `14R1W`, data `9R4W`) — CANNOT be independently narrowed: the 14
    tag / 9 data reads are genuinely concurrent at different indices (hit / victim /
    next / probe / flush / store-drain / slot-1 / presence), so replication is absurd.
    Needs the *pipelined* Stage-R/Stage-D structure = the sync-read functional flip =
    the coordinated bundle (§8, task #2).
  - **mmu.v1_ppn / iq_int.ops** — keep-flop (above).
  **So: the independent, byte-identical port-narrowing is COMPLETE with the predictors.**
  All remaining SRAM work (dcache, icache) is bundle-coupled (the pipelined sync-read
  restructure); v1_ppn / iq_int.ops are flop. The SRAM migration is back at the campaign
  inflection: further progress = committing to a pipeline bundle (D$ load/commit §8, or
  icache fetch-decouple) — the big SMP-critical / IPC-costing core work.

- **✅ D$ sync-read landed default-on + data 10R4W→8R4W (2026-07-07).** The `DCACHE_SYNC_READ=1`
  functional flip is now the default (`dd9bf2a`) — the demand tag/data read is synchronous
  (registered-address). Re-measured `--dump-area`: the flip *added* ports (staging, not narrowing)
  — data `9R4W→10R4W`, tags `13R1W→15R1W`. One **byte-identical** narrowing then folds the five
  write-back-buffer capture reads (fill-victim / probe / misaligned lo-hi / flush — mutually
  exclusive by the `cap_*_go` priority chain) into a single shared `cap_data = data_{cap_way}[cap_index]`
  port, dropping the data reads at `f_index`/`p_index`/`fl_set`: **data `10R4W → 8R4W`**
  (CP 14.745 / FF 160644 both unchanged; N1 boot 7.1 cy-EXACT). See `cp_dcache_sync_read_plan.md §12`.
  - **Tags stay 15R1W** — `vic_tag`(`f_index`)/`phit`(`p_index`) have non-capture consumers
    (`ev_fill_vic`, `probe_depart`/`o_probe_ack`), so no clean capture-only fold.
  - **8R → 1RW is the read-port arbitration flip** (demand + store-drain + fill-RMW + slot-1 +
    next-forward genuinely concurrent → time-multiplex with stalls = functional, IPC cost, full SMP
    ladder). Same SMP-critical class as the sync-read; the capture-fold is the byte-identical
    down-payment toward the "banked 1RW + write-merge buffer" row-1 target.

- **✅ D$ data write-collapse → true 1-write byte-write-enable SRAM: 8R4W → 7R1W (2026-07-11,
  `b5a9976`, cycle-identical).** The four data writers (plain store-merge, AMO/SC commit, fill
  beat, store drain) are **mutually exclusive per cycle** (store-merge/AMO/drain are `state==IDLE`
  + `i_wen`-exclusive; fill is `state==FILL`) and each targets a **one-hot** way, so per bank at
  most one fires. They collapse into ONE muxed **byte-write-enable** write per bank
  (`data_k[idx] = (data_k[idx] & ~msk) | (new & msk)`, `DCACHE_DATA_1RW`); the retention read
  `data_k[idx]` folds into the SRAM byte-enable (same veryl inference as L2 P3.b-B), and the
  store-drain old-line read — the **only** read at `sindex` — folds away too. Net: **write ports
  4→1, one read dropped → data `64×512 8R4W → 7R1W ×4`** (FF 160645→157573). No priority resolution
  (the writers never co-fire), so the masked write reproduces `wr_dword(old, off, merge_dword(...))`
  exactly → cycle-identical. Verified: default 252/0, litmus N2 `0022f150` / N4 `00535020` (exact,
  no RVWMO forbidden outcome), N1 boot 7.1v `013d8910` / 6.6 `01402120` (exact), SMP N2 boot PASS,
  **Verilator N1 `12036187` (exact, independent SV-NBA ground truth)**.
  - **Remaining for the D$ 1RW target: the read side.** After this, data is 7R1W — the 7 reads
    (demand `index` / slot-1 `index2` / next-forward `next_index` / slot-1-next `next_index2` /
    capture `cap_index` / fill-forward `fill_index` / sync-registered `dhit_index_d`) are genuinely
    concurrent at distinct indices, so 7R→1R is the **read-port arbitration flip** (time-multiplex +
    stalls = functional, IPC cost, SMP-critical, full ladder). The write side is now done (1W).
