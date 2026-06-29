# Realistic-SRAM migration — 28-RAM inventory (`heliodor_core`)

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
and `mmu.v1_ppn` (32×44 1R3W ×2). Recommendation: **keep `iq_int.ops` flop** (tiny +
on the wakeup→select critical path); `mmu.v1_ppn` is a trivial 1RW. Everything else
the plan called flop (valid/dirty/excl/plru meta, V=0 TLB, TAGE) is read
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
