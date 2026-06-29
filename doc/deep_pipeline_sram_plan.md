# Deep-pipeline + realistic-SRAM campaign — plan / resume point

Goal (user, 2026-06-30): **halve CP (15.300 → ~7.5 ns)**, reach a **10+ stage
pipeline**, and **migrate to realistic ASIC SRAM** (1RW / 1R1W compiler memories,
not the current unlimited-port model). This is a large multi-session effort;
this doc is the cold-start resume point. Read this + `cp_pipelining_strategy.md`
+ the per-front CP plans before starting.

## Entry state (where we are now)

- heliodor master `539b342` — VINT_PIPE flipped ON. **CP 15.300 ns / 161 levels**,
  endpoint `head → n_inflight[5]`. ~**5 integer stages**, **~161 logic levels per
  stage** (commercial high-Fmax cores target ~20–30). veryl on pure upstream
  master `b13a0654` (no local patches).
- CP campaign arc so far: 25.105 → 20.395 (FR, scheduled-wakeup front register)
  → 17.040 (MEM_PIPE, MMU→dcache PA-latch) → 15.300 (VINT_PIPE, VU datapath).
  All three are param-gated and flipped ON: `SCHED_WAKEUP`/`FRONT_PIPE`
  (`iq_int`), `VFP_PIPE`/`VINT_PIPE` (`vector_unit`), `MEM_PIPE` (core const).
- **The wall** (synth top-500 @ 15.300): a dense multi-front band 14.39–15.30 ns:
  - `n_inflight` 14.70–15.30 (6) — scalar **commit-store** megacone
    (`commit_store_fire → core_dmem_vaddr → MMU → free-list`).
  - `valid_0–3` 14.87 (256) — **dcache fill/victim** way-valid (`dcache.veryl:245`).
  - `redirect_pc_q` 14.47–14.81 (59) — **branch mispredict** redirect.
  - **`rs1_rdy` 14.565 (8) — scalar issue/wakeup** (rename→issue-select→
    scheduled-wakeup): **the fundamental floor**.
  - `mhpmcounter` 14.39 (168) — HPM perf counters (below the floor, not limiting).
- Memory: **28 RAM blocks** inferred (caches + predictor tables); **159 k FFs**
  (PRF/VRF/ROB/RAT/SB/MSHR/TLB are flop-based — unlimited ports are legitimate
  there, standard cells, no SRAM compiler).

## The keystone: scheduler decouple (latency-speculative wakeup + replay)

The fundamental floor is `rs1_rdy` — the **single-cycle issue=execute=broadcast=
wakeup loop** (designer label "Stage IE"). The base design fused select / regread
/ execute / broadcast into one cycle; that is why stages are 161-levels fat.
**Commercial depth is impossible without decoupling select from execute**, which
needs **latency-speculative wakeup** (the scheduler wakes consumers by the
producer's *expected* latency, before the result is broadcast, and **replays** on
misspeculation — e.g. load miss). FR (done) already added grant-time scheduled
wakeup for *fixed*-latency producers; the keystone extends it to *variable*-
latency producers (load/div/fp) with a replay mechanism. **80 % of the campaign
difficulty is here** (replay correctness + full SMP re-verification). Everything
else (cache/front-end/execute staging) is mechanical once select↔execute is split.

## Phased roadmap

- **Phase 0 — fix the targets.** Pick CP (~7.5 ns), depth (~10–12 stages), ROB
  size (64), and the **IPC budget** (allowed boot-cy / CoreMark / Dhrystone
  regression). Deeper pipe costs IPC (mispredict penalty↑, load-use↑, replay);
  commercial cores hide it with **bigger structures** — depth and structure
  growth are co-designed. Establish the dual metric: synth CP **and** IPC.
- **Phase A — KEYSTONE: latency-speculative wakeup + replay.** Decouple select
  from execute. Reuse the `lsu-phase1-wip` 2-stage load + LSR as the seed. Do
  this early — all execute/regread staging depends on it, and it is the only way
  below the 14.565 `rs1_rdy` floor. Highest risk.
- **Phase B — regread / execute staging.** On top of A: separate regread stage,
  pipelined execute + bypass network, per-FU-latency wakeup tiers (extend FR's
  tiering).
- **Phase C — cache pipeline = SRAM migration of caches.** Convert dcache/icache/
  l2 from **combinational read → synchronous (registered) SRAM read** (this read
  *is* a pipeline stage). tag/data split, banked 1RW data, arbitrate
  load/store/fill/slot-1/replay to one access/cycle (the campaign already added
  line-wide RAM + port arbitration — extend it). Cuts the `dcache valid_*` front.
- **Phase D — front-end deepening = SRAM migration of icache/predictor.**
  Registered icache read (fetch stage), separate predict / decode / rename
  stages; predictor tables → 1R1W SRAM. Raises mispredict penalty — TAGE
  (already strong) compensates. Lowest risk (in-order front-end).
- **Phase E — commit/retire (LAST, SMP-constrained).** The `n_inflight`
  commit-store megacone. **Atomic commit must stay single-cycle** (a +1 cy commit
  breaks SMP atomicity — proven: litmus N2 amoadd wedge). Direction-C-style port
  separation for *non-atomic* commit only; low leverage (≤1.3 ns). Defer.
- **Phase F — grow structures (parallel).** ROB 32→64→128, PRF, IQ (8→larger),
  SB, MSHRs to fill the deeper pipe and absorb the penalties from C/D/E.

## Realistic-SRAM migration (integrated with Phases C/D)

The unlimited-port assumption only matters for the **28 inferred RAMs** (caches +
predictor). Flop structures (PRF/VRF/ROB/RAT/SB/MSHR/TLB) stay as flops — at
64×64 the multi-port is free and correct; commercial PRFs use *custom* multi-port
cells = the "special memory" we are avoiding, so flop is the right call here.

Key coupling: **real compiler SRAM is synchronous (registered, 1-cy read)**, while
heliodor reads combinationally. Converting → the read becomes a pipeline stage →
**SRAM migration ⊂ pipeline deepening** (do them in the same flip).

Multi-port → 1RW/1R1W techniques: **banking** (address split, conflict stall),
**replication** (duplicate for read ports, all writes to all copies),
**read/write arbitration + stall**, **tag/data split** (cache). Avoid double-pump
(hard at high Fmax).

Per structure:
- **dcache** (has the groundwork): sync-read + tag(1RW)/data(set-banked 1RW) split
  + arbitrate load-read/store-write/fill/slot-1/replay/LSR to 1 access/cy
  (slot-1 hit-only load → bank or drop, it is a perf optimization).
- **icache / l2**: 1R1W (read=fetch/miss, write=fill), or 1RW + fill buffering.
- **predictor** (BTB/BHT/IBTB/TAGE): 1R1W (predict=read, update=write); same-index
  conflict → drop the update (predictors are approximate).
- **PRF/VRF**: keep flop by default; only if area-critical, bank-by-reg# +
  replicate-for-reads + conflict-stall (or execution-cluster PRF copies).
- **veryl tooling**: synth infers RAM (`conv/ram.rs`) at the RTL's port count. For
  real SRAM, (a) narrow ports in RTL so inference lands on 1RW/1R1W, (b) in PD,
  black-box-instantiate the memory-compiler macro (wrap caches/predictor in a
  swappable SRAM module), (c) optionally add port-constrained-RAM / macro
  expression to veryl (upstream contribution candidate).

## Methodology (proven — reuse verbatim, scaled up)

```
dead-scaffold (param-gate, =0 cycle-exact)
  → synth FF-insertion measure (achievable floor + which front is exposed next)
  → flip MULTIPLE fronts together (they mask each other in the 14.4–15.3 band)
  → corner-debug (+1-cy-shift: replay / store-to-load forward / atomicity)
```
Dual metric every step: synth CP **and** IPC (boot cy / CoreMark / Dhrystone),
judge NET. Gates: **default + ACT4 (essential — caught the MEM_PIPE corner) +
litmus N2/N4 + N2/N4 SMP boot + Verilator**. Commit to the structural change;
intermediate no-gain steps are expected (multi-front wall). FF-insertion test to
tell real vs false path.

## Sequencing & risk

```
Phase 0 (targets + IPC budget)
   │
Phase A  KEYSTONE: speculative wakeup + replay   ← everything depends on this;
   │                                               only path below 14.565
   ├── Phase B  regread/execute staging          ┐ on top of A, flip together
   ├── Phase C  dcache sync-SRAM pipeline         │ (fronts mask each other)
   ├── Phase D  front-end + predictor SRAM        ┘ = SRAM migration of caches/pred
   │
Phase E  commit/retire (SMP-constrained, low leverage) — LAST
   │
Phase F  grow ROB/PRF/IQ/SB/MSHR — parallel with B–E, absorbs penalties
```
- A first (keystone). De-risk by first exercising the multi-front-flip muscle on
  the low-risk C/D scaffolds; introduce replay from the simplest fixed-latency
  producers outward.
- A is ~80 % of the difficulty (replay + SMP). E is SMP-atomicity-bound and low
  leverage. SRAM bank-conflict and sync-read latency are the C/D IPC costs.

## First steps for the fresh context

1. Read this doc + `cp_pipelining_strategy.md` + `cp_front_pipeline_plan.md` +
   `cp_mmu_dcache_pipeline_plan.md`.
2. **Confirm the targets + IPC budget with the user** (CP, depth, ROB size,
   allowed IPC regression). This gates the whole campaign.
3. Build the **memory inventory table**: each of the 28 RAMs × {size, logical R/W
   ports, conflict frequency} → assign 1RW / 1R1W / banked / replicated.
4. Start the **speculative-wakeup design doc** (replay mechanism + SMP
   verification plan) — the keystone. The `lsu-phase1-wip` branch is the seed.
5. In parallel, a low-risk warm-up: dcache **synchronous-read** param-gate
   scaffold (combinational ↔ registered), measure the cycle/IPC delta — this is
   both the SRAM migration start and a Phase-C down payment.

## Reference anchors

- CP measure: `./veryl/target/release-verylup/veryl synth --top heliodor_core
  --dump-timing --timing-paths N` (origin localization shows `instance.signal`).
  `--dump-area` → RAM/FF counts.
- Pipeline flags: `MEM_PIPE` (`heliodor_core.veryl` const), `SCHED_WAKEUP`/
  `FRONT_PIPE` (`iq_int`), `VFP_PIPE`/`VINT_PIPE` (`vector_unit`).
- Strategy/precedent docs: `cp_pipelining_strategy.md` (Directions A–D),
  `lsu_pipeline_plan.md`, `cp_direction_c_port_separation_plan.md` (commit-port,
  ≤1.3 ns, SMP-atomicity wall), `cp_mmu_dcache_pipeline_plan.md`,
  `cp_vu_datapath_pipeline_plan.md`.
- Designer stage labels: F (fetch) · D (decode) · R (rename) · IE (issue/execute,
  the fused stage the campaign is splitting) · Commit. Load adds Stage-A
  (AGU+translate+PMP) / M-stage (PA latch) / Stage-B (dcache+forward+CDB).
