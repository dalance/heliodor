# Deep-pipeline + realistic-SRAM campaign — plan / resume point

Goal (user, 2026-06-30): **halve CP (15.300 → ~7.5 ns)**, reach a **10+ stage
pipeline**, and **migrate to realistic ASIC SRAM** (1RW / 1R1W compiler memories,
not the current unlimited-port model). This is a large multi-session effort;
this doc is the cold-start resume point. Read this + `cp_pipelining_strategy.md`
+ the per-front CP plans before starting.

## Entry state (where we are now)

- **CURRENT (2026-06-30, master `43abb9d`): CP 14.565 ns**, endpoint `rs1_rdy[0]`.
  Progression since 15.300: the AMO-wstrb **wall cut** (`66c0f14`, one dead strobe,
  byte-identical, 15.300 → 14.565) + **FETCH_REG** committed DEAD (the FB *is* the F|D
  register; flip = 14.565 → 14.130, `cp_frontend_pipeline_plan.md §2.2`). FETCH_REG=1
  surfaces the keystone floor: `rs1_rdy` = **12.920** (the A-SCHED select→wakeup loop) under
  the commit-store (`n_inflight` 14.13) + vrf (13.88) wall — see the keystone section.
- heliodor `539b342` (historical entry) — VINT_PIPE flipped ON. **CP 15.300 ns / 161 levels**,
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

### ⚡ Phase-0 findings (2026-06-30) — re-measured + FF-insertion experiment
- **28-RAM inventory done** → `doc/sram_inventory.md`. L2 is excluded (it lives in
  the SoC above `heliodor_core`). Two structures the plan assumed flop actually
  infer as RAM: `iq_int.ops` (8×309 2R2W — **keep flop**) and `mmu.v1_ppn`
  (32×44 1R3W ×2 — trivial 1RW). Hardest: dcache data (64×512 **9R4W**), dcache tags
  (64×52 **13R1W**), bht (8192×2 4R2W).
- **Keystone design doc done** → `doc/speculative_wakeup_design.md` (execute staging,
  scheduled wakeup, replay; staged no-replay-first then replay-if-budget-demands).
- **IPC budget set by the user: ~10–15 %** (boot-cy / CoreMark / Dhrystone). Gates
  the campaign; Phase F structure growth runs in parallel as needed.
- 🔑 **CORRECTION to "Phase C dcache sync-read cuts the `valid_*` front".** It does
  NOT. FF-insertion proof: registering all six dcache READ outputs left the **top-60
  paths byte-identical** (headline `n_inflight` 15.300; `valid_1` 14.870 = 55/60).
  The dcache **read** is a deep-floor front (≤14.565), not the headline. Both
  headline fronts share the **commit-store front** `head → commit_store_fire →
  AGU → dmem_vaddr → MMU translate → {n_inflight, dcache fill `valid_*`}` — stores
  translate **at commit**. **→ First headline-moving lever = stage that front
  (pre-translate stores at execute, latch PA into the SB), flipped together with the
  keystone's execute staging.** Details: `speculative_wakeup_design.md §1.0, §9.1`.

## The keystone (REVISED 2026-06-30): the fused "Stage IE" is THREE structural problems

> **Decision criterion (reaffirmed, user 2026-06-30):** pick the next step by what
> advances the **FINAL pipeline structure**, NOT by which front is the binding synth
> CP number. Chasing the binding front one-by-one is CP-driven mole-whacking. A step
> that builds a genuine pipeline stage boundary is progress even when it does not move
> today's CP (it is masked below the wall). Revise this goal/plan if the structure
> demands it — as this section now does.

The fundamental floor is `rs1_rdy` — the fused **select=regread=execute=broadcast=
wakeup** cycle ("Stage IE", 161-levels fat). **MEASURED decomposition** (FF-insertion +
the FETCH_REG front-end cut + `--timing-paths 14000`; full trace in
`speculative_wakeup_design.md §1.1c`): the fused cycle splits into an EXECUTE half and a
SCHEDULER half, **the scheduler half is the binding one**, and it is itself two distinct
problems. The old single-bullet "decouple select from execute via replay; everything
else is mechanical" **conflated them** and understated the binding one. The three
first-class structural components:

- **A-EXE — execute staging** (`FR_Q → PRF read → ALU → CDB-broadcast → wakeup`,
  **< 11.7 ns**): register the CDB / split regread|execute|writeback into stages, with a
  bypass network; the existing grant-time scheduled wakeup keeps fixed-latency dependent
  ALU 1/cycle (no replay). A genuine, foundational stage boundary the deep pipe needs —
  **but NOT the binding delay**: it is already *below* the scheduler, so it is CP-neutral
  today (masked). The old plan's "Phase A register-the-CDB first" lever lives here. Lower
  risk. Build it for the STRUCTURE, not for a CP number.
- **A-LOOP — latency-speculative wakeup + replay** (break the select→wakeup *loop*):
  the loop must close in **one cycle** for back-to-back dependent issue. Variable-latency
  producers (load hit/miss, div, fp) force the loop to wait the full deepened pipe unless
  the scheduler wakes consumers at the producer's *expected* latency and **replays** on
  misspeculation (load miss). This is the plan's original "80 % difficulty" (replay
  correctness + SMP). **But it breaks the LOOP — it does not shorten the select LOGIC.**
- **A-SCHED — scheduler-logic pipelining** (the binding stage depth, **~12.9 ns**, was a
  footnote — now FIRST-CLASS): the select-stage *combinational logic* is
  `head → ROB load-ordering block-scan (depth-5 argmin, rob.veryl:741) → IQ oldest-ready
  select (depth-3 argmin, iq_int.veryl:324) → sched_wake → rs*_rdy` — **two argmin trees
  in series**, ~12.9 ns, which **exceeds the ~7.5 ns stage budget independently of replay**
  (replay shortens no gate on this path; `EX_PIPE`/CDB-register touches none of it — source
  is `head`, structurally disjoint from the execute cone). Reaching 7.5 needs this logic
  **pipelined**: move the ROB block-scan to its own stage (register the block age, lean on
  the existing load-store violation→replay for the rare stale plain-store window, keep
  atomic/fence/cbo.zero blockers LIVE for SMP), and/or reduce/speculate the IQ argmin.

**→ Consequence for the goal.** ~7.5 ns is reachable, **but ONLY with A-SCHED.** A-EXE and
A-LOOP do not break A-SCHED; without A-SCHED the realistic floor (once the commit-store /
vrf wall is cut) is the scheduler depth **~12 ns**. The old plan ("execute staging is
mechanical; replay is the 80 %") was correct that replay is hard, but **misidentified the
binding stage** — it is the scheduler *logic* depth (A-SCHED), not the execute cone.

### FINAL target microarchitecture (the 10+-stage structure the phases build toward)

```
 F1   PC → imem-MMU translate (registered)                         [Phase D]
 F2   icache read (sync SRAM)                                      [Phase D/C]
 D    cexp + decode                                                [Phase D]
 R    rename + free-list + IQ allocate                             [done: FETCH_REG = F|D reg]
 IS   ISSUE/SELECT — scheduler  ◀── select→wakeup 1-cy loop ──┐    [Phase A-SCHED + A-LOOP]
 RR   regread (PRF sync SRAM)                                 │    [Phase A-EXE]
 EX   execute (1+ cycles)                                     │    [Phase A-EXE/B]
 WB   writeback / CDB broadcast  ── wakeup ───────────────────┘    [Phase A-EXE]
 C    commit / retire                                              [Phase E]
   load side: Stage-A (AGU+xlate+PMP) │ M (PA latch) │ Stage-B (dcache sync read+fwd+CDB)
```

The **select→wakeup loop** (IS → wakeup back into IS) is the one edge that **must close in
≤ 1 cycle** for 1/cycle dependent issue — so the IS-stage logic must fit one cycle (~7.5 ns).
Today IS is ~12.9 ns (A-SCHED) and the loop also carries variable-latency producers (A-LOOP).
Everything *outside* the loop (RR/EX/WB/F1/F2/caches) pipelines freely with bypass — that is
the "mechanical once split" part. The loop is the hard core. **If A-SCHED proves
infeasible within the IPC/SMP budget, the realistic goal revises to the IS-stage depth
(~12 ns / ~6–7 stages), not 7.5 ns** — an explicit decision gate, not a silent miss.

## Phased roadmap

- **Phase 0 — fix the targets.** Pick CP (~7.5 ns), depth (~10–12 stages), ROB
  size (64), and the **IPC budget** (allowed boot-cy / CoreMark / Dhrystone
  regression). Deeper pipe costs IPC (mispredict penalty↑, load-use↑, replay);
  commercial cores hide it with **bigger structures** — depth and structure
  growth are co-designed. Establish the dual metric: synth CP **and** IPC.
- **Phase A — KEYSTONE: split the fused "Stage IE"** (three components, see the
  keystone section above). Reuse the `lsu-phase1-wip` 2-stage load + LSR as the seed.
  - **A-EXE** (execute staging): register the CDB, split regread|execute|writeback,
    bypass network; scheduled wakeup keeps fixed-latency chains 1/cycle. Foundational
    stage boundary — all further execute/regread staging depends on it — but CP-neutral
    today (it is below the scheduler). Lower risk; the down-payment structural step.
  - **A-LOOP** (latency-speculative wakeup + replay): break the select→wakeup loop for
    variable-latency producers (load/div/fp). Highest risk (replay + SMP). The "80 %".
  - **A-SCHED** (scheduler-logic pipelining — the binding ~12.9 ns stage): pipeline the
    ROB load-ordering block-scan out of the IQ select (register block age + violation→
    replay for the stale window; atomic/fence/cbo blockers stay live), reduce/speculate
    the argmin. **The only path below the ~12 ns scheduler floor → the gate for ~7.5 ns.**
- **Phase B — regread / execute staging (folds into A-EXE).** Separate regread stage,
  pipelined execute + bypass, per-FU-latency wakeup tiers (extend FR's tiering).
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
Phase A  KEYSTONE — split the fused "Stage IE":
   ├─ A-EXE   execute staging (CDB reg + bypass)    ← foundational, lower risk,
   │                                                  CP-neutral today (below sched)
   ├─ A-SCHED scheduler-logic pipelining            ← THE binding ~12 ns stage;
   │            (ROB block-scan stage + argmin)        the only path below ~12 ns → 7.5
   └─ A-LOOP  latency-speculative wakeup + replay   ← breaks the 1-cy loop; the 80 %
   │            (load/div/fp; SMP-bound)
   ├── Phase B  regread/execute staging (⊂ A-EXE)  ┐ on top of A, flip together
   ├── Phase C  dcache sync-SRAM pipeline           │ (fronts mask each other)
   ├── Phase D  front-end + predictor SRAM          ┘ = SRAM migration of caches/pred
   │
Phase E  commit/retire (SMP-constrained, low leverage) — LAST
   │
Phase F  grow ROB/PRF/IQ/SB/MSHR — parallel with B–E, absorbs penalties
```
- **Within Phase A:** build **A-EXE first** — it is the foundational stage boundary
  everything else stages onto, and the lowest-risk way to exercise the bypass/wakeup
  machinery — *accepting it does not move CP* (structure, not CP number). **A-SCHED is
  the binding-stage work** that actually unlocks ~7.5 ns; **A-LOOP** (replay) recovers the
  load-use IPC the deepened pipe costs. A-SCHED and A-LOOP both touch the scheduler and
  SMP — co-design + re-verify (litmus N2/N4 + SMP boot) at each sub-step.
- A is ~80 % of the difficulty (A-SCHED depth + A-LOOP replay + SMP). E is
  SMP-atomicity-bound and low leverage. SRAM bank-conflict + sync-read latency = C/D IPC.

## First steps for the fresh context

Phase 0 is DONE (targets + IPC budget ~10–15 %; 28-RAM inventory → `sram_inventory.md`;
keystone design doc; the AMO-wstrb wall cut + FETCH_REG). The keystone floor is measured
(`rs1_rdy` 12.920 = A-SCHED select→wakeup loop). **Next = begin Phase A RTL, re-scoped:**

1. Read this doc's keystone section + FINAL microarchitecture, then
   `speculative_wakeup_design.md` (§1.1c measurement, §4 re-scope note, §6 wakeup tiers).
2. **A-EXE (build first, foundational, structure-not-CP):** the `EX_PIPE` execute-stage
   scaffold — register `alu_cdb` (lane-0, then `alu_cdb2`), DEAD-gated byte-identical, +
   bypass network spanning the EX register, + the §1.0b CDB writeback-arbitration buffer.
   Gate ladder at the flip (default · backend-validate · ACT4 · litmus N2/N4 · SMP boot).
3. **A-SCHED (the binding ~12.9 ns stage — the gate to ~7.5 ns):** pipeline the ROB
   load-ordering block-scan (`rob.veryl:741`, `o_block_store_age/exists`) into its own
   stage — register the block age, keep atomic/fence/cbo.zero blockers LIVE (SMP), lean on
   the existing load-store violation→replay for the rare stale plain-store window; then
   reduce/speculate the IQ argmin. Needs its own staged design (TODO) + full litmus/SMP.
4. **A-LOOP (replay, the 80 %):** latency-speculative load wakeup + IQ retain-until-confirmed
   + poison vector (`speculative_wakeup_design.md §5`), only if A-EXE's load-use blows budget.
5. Defer vrf / commit-store / dcache-sync-read cuts to the coordinated multi-front flip
   (they mask each other in the 13.2–14.1 band); they are mechanical once A is in place.

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
