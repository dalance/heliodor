# Phase 14 — Front-end + LSQ structural completion (real deep-OoO)

Master plan (2026-07-24). **Goal: structural completeness, not CP.** After the
deep-pipeline campaign resolved that the real synth CP floor is the vector
execute→writeback datapath (`deep_pipeline_status_and_replan.md §8.2`, the retire
`n_inflight` headline was a FALSE PATH), further FF-insertion buys no CP. Phase 14
instead advances heliodor toward the structures a real multi-GHz OoO core has but
heliodor still **fuses into a single cycle** or **simplifies**:

- a true **decoupled front end** (predictor SRAM + overriding predictor + fetch
  target queue) instead of a combinational fetch loop with an FTB prefetch hint,
- a **pipelined scheduler** (select + speculative wakeup) instead of single-cycle
  select+wakeup,
- a **canonical LSQ** (store queue + translate-at-execute + a first-class load
  queue + queue-ordered atomics) instead of a committed-store buffer +
  commit-time-replay disambiguation.

User decision (2026-07-24): direction **A (structural completeness)**, scope
**front-end structure in full** — i.e. the whole 4-block program below.

This is a large, multi-session program. Methodology is the campaign's proven one:
every stage is a **DEAD param scaffold** (`=0` cycle-exact byte-identical, `=1`
inserts the register/stage), verified byte-identical at 0, then measured for
IPC/CP before any flip. Regression gate: `veryl test` (unit + arch suites) →
`veryl test --ignored --test test_litmus_4hart` → SMP boot N2/N4. CP via
`veryl synth` (sky130 default / asap7).

---

## Block F — Front-end array realism + decoupled fetch (the Phase-14 centre)

### F1 — Predictor-array SRAM migration (BTB / BHT / TAGE / iBTB → 1R1W clocked)

**Structural gap.** Phase 13 migrated every *cache* array to 1R1W clocked SRAM,
but the branch-predictor arrays are still flops read **combinationally in F0**:
BTB (4096 × ~60b ≈ 30 KB), BHT/gshare (8192 × 2b), TAGE-lite tables (several KB),
indirect-target BTB (512 × ~50b). ~35–40 KB of storage in flops — L1-way-sized —
the single largest remaining array-realism outlier. (RAS and the small
fully-assoc TLB/MSHR-class arrays are correctly **below the SRAM floor**; leave
them flop — not a gap.)

**What a real core does.** These arrays are SRAM macros with a **clocked
(registered-address)** read. A clocked predictor read cannot steer fetch in the
same cycle, so it forces an **overriding / ahead-pipelined predictor**: BTB read
in F0 → target used in F1, with a next-line / BTB1 fast path covering the bubble
and the F1 override correcting it. This is exactly the restructuring the icache
sync-read required — SRAM ⊂ pipeline deepening.

**Scaffold.** Add a `PRED_SYNC_READ` (or per-array) DEAD param, mirror the icache
1R1W byte-write pattern for each array, and add the F0→F1 override datapath. `=0`
keeps today's combinational F0 predict byte-identical; `=1` clocks the read and
enables the override. Measure the IPC cost (extra redirect bubble), budget it like
the icache's ~+8 %.

**Effort:** medium–large. The array flip is small; the override restructuring +
FTB/prefetcher reconciliation is the real work. **Independent of Block L.**

### F2 — True decoupled fetch (Fetch Target Queue)

**Structural gap.** Today's fetch is a combinational fetch FSM that reads the
icache and does predict/redirect in one tight loop; the shipped FTB
(`cp_icache_fetch_decouple_plan.md`, shape-W `7127cb9`) is a *directed-prefetch
hint* one step ahead — **not** a first-class FTQ.

**What a real core does** (Reinman/Calder/Austin decoupled front-end): the
predictor pipeline **enqueues fetch-block descriptors** into an FTQ; the fetch
engine dequeues them asynchronously. The predictor runs many blocks ahead, fully
hiding icache latency and driving run-ahead instruction prefetch.

**Prereq:** F1's overriding predictor (the predictor must produce fetch targets a
stage ahead to fill the FTQ). Build the FTQ, move prediction fully into the
enqueue side, make the fetch engine an FTQ consumer.

**Effort:** large. **Independent of Block L.**

---

## Block S — Pipelined scheduler (select + speculative wakeup)

**Structural gap.** The integer IQ does select → broadcast-wakeup → next-cycle
select as **one combinational path** today. `SEL_PIPE` (`iq_int.veryl:266`) and
`SPEC_WAKE` (`iq_int.veryl:297`) are built but DEAD; A-SCHED already measured the
pipelined select shortening the IS loop 12.92→9.52 ns (sky130).

**What a real core does.** Pipeline select, and add **speculative wakeup** — wake
dependents one cycle before the producer result is known so back-to-back dependent
ALU ops still issue in consecutive cycles under a pipelined select. The **EX_PIPE
keystone** (`heliodor_core.veryl:1523`, registered RR│EX│WB) is the matching
execute-side stage but costs −15 % IPC alone; recovering it needs a **bypass /
forwarding network** so pipelined-execute results reach waiting consumers without
a stall. Scheduler-pipelining and EX_PIPE+bypass are one coordinated sub-effort.

**S1 = SEL_PIPE + SPEC_WAKE enable/validate + EX_PIPE bypass network.**
`LOAD_SPEC` (`iq_int.veryl:312`, speculative load-hit wakeup + miss replay) is the
aggressive piece — deferred to Block R because its replay entangles SMP memory
ordering.

**Effort:** medium (SEL/SPEC + bypass). **Mostly independent** of L; `LOAD_SPEC`
touches R3's ordering machinery.

### ✅ S1 status (2026-07-27) — scheduler-pipeline SHIPPED LIVE; EX_PIPE banked

The scheduler pipeline is now the **FINAL structure, LIVE**: `SEL_PIPE=1` +
`SPEC_WAKE=1` (`iq_int.veryl:266/297`). Re-validated end-to-end in the current
tree (post-F1/F2): `veryl test` **252/0**, litmus **N4 pass** (cy 5.63M), **N2 SMP
boot** 19.25M, **N4 SMP boot** 30.55M — all at baseline cycle counts (**IPC-neutral**;
dhrystone +0.6 %, instret bit-exact). A1.0 pipelines the select→wakeup loop
(registers the SCHED_WAKEUP pdst); A1.1's grandparent speculative wakeup recovers
the +1-cy dependent-issue (litmus N2 returns to the byte-exact baseline). The CP
benefit stays masked under the wall (only realised in a bundle flip) — this ships
for the **structure**, per the campaign's "advance FINAL structure, not the synth
number" mandate.

**EX_PIPE (execute-staging keystone) is BANKED at 0** — two blockers in the current
tree, user-decided to bank (2026-07-27) and ship the scheduler-pipeline alone:
1. **Boot hang** (arch 252/0 passes, but N1 boot infinite-loops): at `EX_PIPE=1`
   early boot corrupts the paging-enable / control flow (`csrw satp` @0x80001040 →
   a wild jump to PC 0 → `handle_exception` re-enters forever because `ld sp,16(tp)`
   loads sp=0 → `sd ra,8(sp)` store-page-faults → nested-trap storm). Localised to
   the paging-enable/CSR-CDB region; a wrong-value from the EX register/bypass. The
   old "SMP-complete" validation (`deep_pipeline_status_and_replan.md`) predates
   F1/F2 + the grown suite. −15 % IPC alone, so IPC-negative even once fixed.
2. **FROUND_PIPE=1 latent bug** (coupled to EX_PIPE): the 3-stage Zfa FROUND applies
   the wrong rounding mode for STATIC-rm `fround.s` and drops the `froundnx.s` NX
   flag — the held-at-head op's rounding-mode / fflags are read LIVE one cycle after
   the op released (`test_arch_zfa_s2`; ACT4's single dynamic-rm fround never hit it).
   **Decoupled** (`FROUND_PIPE=FMA_PIPE3=0`, byte-identical at `EX_PIPE=0`) so a
   future EX_PIPE flip does not re-enable it; the fix + re-couple is FP-CP follow-up.

EX_PIPE + its bypass/E3 scaffold + corner-fixes stay committed (built, `=0`); the
boot corner and the FROUND bug are the remaining work for a future execute-staging /
FP-CP session. `LOAD_SPEC=0` remains deferred to Block R.

---

## Block L — Canonical LSQ (store queue + translate@execute + load queue)

Heliodor's memory-ordering fuses what a real LSQ separates
(`retire_memory_ordering_redesign_study.md`, `cp_retire_decouple_plan.md`,
`cp_store_queue_plan.md`):

- **L1 — R1 decoupled-retire + store queue.** Break the single-cycle
  `commit_store_fire → live-TLB translate → sb_merge_ok → rob_commit_ack →
  n_inflight` fusion. A store frees its ROB entry when non-speculative; the write
  drains later from a real SQ. `SB_PA_REG` (R1a, `aee7ecd`) already registered the
  store-buffer PA off `rob_commit_ack` and is LIVE; `RETIRE_DECOUPLE`
  (`heliodor_core.veryl:~1690`) is the DEAD groundwork. The committed-store buffer
  (4 × 64 B line write-combining drainer) becomes the SQ's drain stage.
- **L2 — R2 translate-at-execute.** Compute the PA at AGU/execute, carry it in the
  SQ; commit stops re-driving the TLB. `STORE_PRETRANSLATE`
  (`heliodor_core.veryl:1676`) scaffold built (−0.25 ns plain-store, **atomics
  excluded** — they share the coherent port and stay commit-translated until R3).
- **L3 — first-class load queue.** Today disambiguation is **load-violation detect
  + commit-time replay** with no explicit LQ. Add an **age-ordered LQ-CAM** checked
  at store-execute (the "L" half; R1/R2 build the "S" half). Store-to-load
  forwarding (now split across ROB scan + committed buffer) folds into one
  age-ordered SQ CAM.

**Effort:** large (L1, L3), medium (L2). **Independent of Blocks F/S** — commit
side, can proceed in parallel. Build L1→L2→L3 as DEAD scaffolds and measure
before R3.

---

## Block R — SMP-critical finale (gated)

- **R3 — atomic reorder.** Atomics today are a **single-cycle commit-time RMW into
  an owned line** (`amo_watch`/`amo_poison`, P9.3); a +1-cy commit slip desyncs
  this (the litmus-N2 amoadd "M3b wedge"). Route atomics through the LSQ +
  coherence protocol so multi-cycle atomic handling is tolerated. **Highest SMP
  risk** — the M3b minefield.
- **LOAD_SPEC** replay validation lands here too (speculative load wakeup's
  miss-replay interacts with coherence/ordering in SMP).

**Gate:** only commit to R after L1/L2/L3 + S are built and measured. If R proves
out of the SMP-correctness budget, bank F+S+L (front-end + LSQ decoupled-retire)
and treat atomic reorder as a separately-scoped follow-on — the fallback the
campaign has always kept open.

---

## Dependency graph & sequence

```
F1 predictor SRAM ──▶ F2 decoupled FTQ ─┐
S1 pipelined sched (+ EX_PIPE bypass) ──┤
L1 store-Q ─▶ L2 xlate@exec ─▶ L3 load-Q┼──▶ R3 atomic reorder + LOAD_SPEC  (gated)
```

Recommended order (front-end-first, risk last):
1. **F1** predictor SRAM + overriding predictor — clearest path (icache pattern), front-end centre.
2. **F2** decoupled FTQ — F1's natural extension.
3. **S1** pipelined scheduler + EX_PIPE bypass — independent, front-end-adjacent (can overlap F).
4. **L1→L2→L3** LSQ — commit side, parallelisable throughout.
5. **R3 + LOAD_SPEC** — gated SMP finale.

## First step

Begin **F1**: audit the current predictor RTL (exact array sizes, ports, F0
combinational read paths for BTB/BHT/TAGE/iBTB), then design the `PRED_SYNC_READ`
DEAD scaffold and the F0→F1 override datapath. Sub-plan doc:
`cp_predictor_sram_plan.md` (to be written).
