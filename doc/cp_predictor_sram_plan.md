# F1+F2 — Decoupled front-end: predictor clocked-read + overriding predictor + FTQ

Sub-plan of Phase 14 (`phase14_frontend_deep_ooo_plan.md`, Blocks F1+F2, unified).
Written 2026-07-24 after auditing the predictor RTL and the core fetch datapath.

## Corrected starting picture (the audit result)

The earlier framing "predictor arrays are still flops → migrate to SRAM" is
**wrong**. Reality:

- **Arrays are already 1R1W SRAM port-shape** (2026-07-06, byte-identical,
  `--dump-area`-confirmed; `sram_inventory.md:166`). `btb`/`ibtb`/`bht` were
  narrowed to 1R1W by **read-port replication** (one packed word per copy, commit
  train writes all copies). `TAGE` stays a **register-file array** — never inferred
  as SRAM, the correct realistic choice (`sram_inventory.md:111,156`).
- **The read is still combinational.** The remaining structural gap is
  **combinational-read → clocked (registered-address) read**, i.e. an
  **overriding / ahead-pipelined predictor**.
- **Sync-read scaffolds are BUILT-but-DEAD** in `btb.veryl` (`BTB_SYNC_READ`),
  `bht.veryl` (`BHT_SYNC_READ`), `ibtb.veryl` (`IBTB_SYNC_READ`) — each registers
  the read result + compare operands, `=0` byte-identical (DCE), `=1` a cycle late.
  **TAGE had no such scaffold** — added this session (`TAGE_SYNC_READ`, registers
  the final per-slot `o_hit`/`o_taken`).
- The scaffold headers all state the flip is **functional only under decoupled
  fetch** ("Flip with btb/bht/ibtb + shape-W"). So the predictor sync-read *is* the
  overriding-predictor / FTQ work — not an independent array swap.

## Current fetch datapath (what F1+F2 build on)

Already shipped in Phase 13 (`ICACHE_SYNC_READ=1`, default-on):

- **F0 stream** (`heliodor_core.veryl:1350+`): `pc_fetch_q` (dword-aligned) is
  presented to imem_mmu + icache; the **synchronous** dword lands next cycle and is
  pushed into a **WORD FIFO**. An **FTB** (`ICACHE_FETCH_DIRECTED`, 64 fetch-block
  entries, `:1392+`) reads on `pc_fetch_q` and re-steers F0 ahead of extract to
  unconditional + strong-taken conditional targets — a *directed-prefetch hint*,
  the FTQ's germ.
- **extract** (`:989–1084`): pops the WORD FIFO, reads **btb/bht/tage/ibtb
  combinationally on `ic_pc` (= `ext_pc_q`)**, computes
  `predicted_taken`/`pred_next_pc_bp` (`:1026,1036`) and the slot-1 pair
  (`:1080,1084`), pushes the bundle into the fetch buffer, and on a taken delivery
  flushes + re-steers F0 (`ext_taken_redir`, `:1426`).

So prediction happens **at extract, combinationally**. Making the predictor read
clocked forces prediction one stage earlier (at F0, on `pc_fetch_q`), with the
result carried forward — which is exactly a **Fetch Target Queue**: the predictor
pipeline enqueues *predicted* fetch-block descriptors; extract dequeues them.

## Target structure (FINAL)

```
 F0  pc_fetch_q → {imem-MMU translate, icache sync read, PREDICTOR sync read (index here)}
 F1  predictor result lands → resolve predicted_taken / next-target → enqueue FTQ descriptor
     {dword(s), pred_taken, pred_target, gshare idx, ind-hist, is_call/ret/ind, RAS action}
     └─ override: if F1 prediction disagrees with the F0 FTB steer, correct pc_fetch_q (+1 bubble)
 EXT dequeue FTQ + WORD FIFO → assemble bundle (prediction already attached) → fetch buffer
```

The FTB becomes the **fast (0-bubble) first-guess** feeding F0; the full predictor
(BTB+BHT+TAGE+iBTB+RAS) is the **override** in F1 that confirms/corrects it — the
classic overriding-predictor pair. The WORD FIFO gains a parallel **FTQ** carrying
the per-block prediction metadata.

## Steps (DEAD-scaffold methodology, measure before flip)

1. **[done] TAGE sync-read scaffold** (`TAGE_SYNC_READ`, byte-identical at 0) —
   the last predictor without one. Now all four predictors register their read.
2. **Move prediction to F0.** Re-index btb/bht/tage/ibtb on `pc_fetch_q` (the F0
   address) instead of `ext_pc_q`; carry the combinational result forward one cycle
   (this is what the `*_SYNC_READ` registers already do). Reconcile `spec_ghr` /
   `spec_ind_hist` update timing (history advances at F0 now).
3. **FTQ descriptor.** Extend the WORD FIFO push (or a parallel queue) with
   `{pred_taken, pred_target, gshare_idx, ind_hist, is_call/ret/ind}`; extract
   consumes the attached prediction instead of re-reading the predictors.
4. **Overriding redirect.** When the F1 predictor disagrees with the F0 FTB steer,
   correct pc_fetch_q (+1 bubble); the FTB stays the 0-bubble common case.
5. **Flip** `{BTB,BHT,IBTB,TAGE}_SYNC_READ=1` together, validate byte-behavior
   under the new structure, **measure IPC** (extra redirect bubble — budget like
   the icache sync-read's ~+8 %) and CP (`veryl synth`).

## Risks

- **IPC**: prediction a cycle late adds a redirect bubble on taken branches not
  caught by the FTB fast path. The FTB coverage (already tuned) mitigates; measure.
- **TAGE provider-select timing**: registering the final `o_hit`/`o_taken`
  (not each table) keeps the multi-table mux in the F0→F1 combinational cone; watch
  it does not become the new front-end CP wall.
- **spec history**: moving the lookup to F0 shifts where `spec_ghr`/`spec_ind_hist`
  are sampled; the commit-side train re-read (TAGE/iBTB carried-index proof) is
  unaffected, but the speculative-history restore on redirect must track the new
  sample point.
- **straddle / FIFO corners**: the WORD FIFO already handles miss/PTW/fault
  back-pressure (W3); the FTQ must stay in lockstep with it.

## CP measurement (2026-07-24) — F1 buys ZERO global CP, confirmed

`veryl synth --top heliodor_core`, sky130:

| build | CP | binding path |
|---|---|---|
| baseline (`*_SYNC_READ=0`) | 12.805 ns | `n_inflight[5]` (retire megacone — the §8.2 FALSE PATH) |
| predictors `*_SYNC_READ=1` (measurement flip, functional-invalid) | **12.805 ns (unchanged)** | same; the registered predictor cone (`pc_fetch_q → *_q`) surfaces far below the wall |

The predictor read cone is masked ~7 ns below the binding wall, so clocking it moves
**no global CP**. F1+F2 is therefore a **pure structural-fidelity** change: it makes
the front end a real overriding/decoupled predictor at an **IPC cost** (the override
bubble) and **zero CP benefit** — exactly consistent with the Phase-14 "structural
completeness, not CP" mandate. There is no CP number to chase here; success =
"the front end is a real decoupled/overriding structure, IPC cost budgeted+measured."

## Status / next increment

- **[done, verified]** step 1 — `TAGE_SYNC_READ` scaffold added; `veryl test` 252/0;
  byte-identical (const-folded). All four predictors now carry a sync-read scaffold.
- **[done, verified]** step 2 / order-item-1 — `PRED_PIPE` param + the Stage-A/B pipeline
  register substrate (`a_valid/a_pc/a_s0/a_s1/a_slot1_elig/a_straddle/a_ftb_next`), latched
  in a dedicated always_ff after the W2 `ext_pc_q` register, DEAD at 0. `veryl test` 252/0,
  byte-identical (reset-only writes + zero consumers → DCE), no new analyzer warnings.
- **[implemented, validating]** step 2 / order-item-2 — the fetch-buffer write is routed
  through Stage-B, a **1-deep skid register** between extract-assemble/predict (Stage-A, T)
  and the fb write (Stage-B, T+1). Only the fb WRITE is delayed; ext_pc_q advance / WORD-FIFO
  pop / F0 steer / RAS / spec-history / FTB-train stay at Stage-A (so the predicted stream is
  unchanged — the fb just fills a cycle later). Back-pressure: Stage-A produces only when the
  skid can accept (`sb_can_accept = !a_valid || sb_drain`), replacing fb_push0's `!fb_full`;
  fb-room checking moved to the drain (`sb_drain = a_valid && fb_free>=sb_ops`). Register set:
  `a_valid/a_push0/a_push1` + the full fb-push0/1 metadata for both slots. Everything gated
  `if PRED_PIPE ? new : old` → **byte-identical at 0** (`veryl test` 252/0).
  - **=1 IPC**: litmus N2 +1.14%, N1 boot +1.05%, N2 boot **+0.4%** (cy 19.27M) — the +1
    front-end stage, far under the ~+8% budget (prediction is NOT delayed, so no taken-branch
    bubble; only the fb write is +1).
  - **N2-boot livelock + fix (important)**: the first =1 cut ALSO dropped the slot-1
    produce-time `fb_free>=2` gate (`fb_push1 = fb_push0 && slot1_valid`), so near-full slot-1
    was always bundled → ext_pc_q skipped to `pred_next_pc1` and parked a 2-op bundle in the
    skid that only drains on `fb_free>=2`, pathologically stalling Stage-A under N2 lock
    contention → **N2 SMP boot livelocked** (100M-cy timeout; N1 boot + litmus N4 passed). An
    isolation test (revert ONLY that gate) fixed N2 boot → the **pure +1 skid latency is fine**;
    the culprit was the slot-1-bundling trajectory change, NOT a fetch-latency SMP fragility.
    Fix = keep the =0 `fb_free>=2` gate at both settings (defer near-full slot-1 to a future
    slot-0, as =0). Regression re-run with the fix: `veryl test` 252/0, N2 boot pass 19.27M;
    litmus N4 + N4 boot validating.
  - Predictors stay COMBINATIONAL here (outputs captured into Stage-A regs, replayed at
    Stage-B) — step 3 removes those prediction regs and lets the clocked `*_SYNC_READ` flops
    be the Stage-A→B prediction latch.
- **[measured]** F1 CP = 0 (above). The remaining F1+F2 work is a **large,
  multi-session restructuring of the fetch datapath** (pipeline extract across the
  clocked predictor read → FTQ + overriding redirect), reworking the already-complex
  shape-W WORD FIFO / FTB / straddle logic, with an IPC cost to budget. Not
  byte-identical — it changes fetch timing. Approach it as its own incremental
  sub-effort (Stage-A/Stage-B extract split first, then FTQ).

## Implementation recipe — extract Stage-A/B split (`PRED_PIPE`)

Signal-level design for step 2, derived from the audit. The current extract datapath
(all combinational at cycle T):

- `ext_pc_q` (`heliodor_core.veryl:412`) = extract PC; advances to `ext_next_pc`
  (`:1389` = `fb_push1 ? pred_next_pc1 : pred_next_pc_bp`) on `fetch_ready`, reseeds on
  redirect (`:1575` ff).
- predictors read combinationally on `ic_pc = ext_pc_q` → `predicted_taken` (`:1026`),
  `pred_target` (`:1035`), `pred_next_pc_bp` (`:1036`); slot-1 pair `:1080/:1084`.
- consumers, all at T: `ext_pc_q` advance (`:1585`), `ext_next_pc`/`ext_pop`
  (`:1389/:1390`), `pc_q` next (`:1323`), `fb_push0/1` (`:1133/:1134`) + stored
  `fb_pred_next_pc`, and the F0 override redirects `ext_taken_redir` (`:1426`) /
  `ext_buf_mismatch` / `f0_diverged`.

**Why a mux scaffold is insufficient.** The `*_SYNC_READ=1` flip registers the
predictor output → available at T+1. But `ext_pc_q` advances at T, so at T+1 the
registered prediction no longer matches `ext_pc_q`. A `if PRED_PIPE ? q : comb` at each
consumer is byte-identical at 0 but at 1 applies a stale-by-one prediction — wrong.
The fix is a real 2-stage split, NOT a mux.

**Stage-A (T): assemble + index.** Pop the WORD FIFO, build the bundle
(`s0_instr`/`s1_instr`, RVC-expanded), present `ext_pc_q` to the (now clocked)
predictors, and **register the bundle + `ext_pc_q` + FTB-followed next-PC** into a
Stage-A/B pipeline register `{a_pc, a_s0, a_s1, a_slot1_elig, a_straddle, a_ftb_next}`.
Do NOT push to the fetch buffer or steer here.

**Stage-B (T+1): predict + steer + push.** The registered predictor outputs
(`predicted_taken_q`, `pred_next_pc_bp_q`, slot-1) now correspond to `a_pc`. Apply
them: push `{a_s0,a_s1}` to the fetch buffer with the resolved prediction, set the
fetch-buffer's stored next-PC, and drive the F0 override — **redirect F0 only when the
Stage-B prediction disagrees with the FTB-followed path `a_ftb_next`** (the overriding
predictor: FTB is the 0-bubble fast path, BTB/BHT/TAGE the +1 override).

**Throughput.** Stage-A of bundle N+1 overlaps Stage-B of bundle N — 1 bundle/cycle
sustained (no per-bundle bubble). The +1 bubble is paid only on an override redirect
(FTB disagreed) and on taken branches the FTB didn't pre-steer. This is the IPC cost to
measure; FTB coverage (already tuned) bounds it.

**Authority inversion (the crux).** Today extract-BTB is authoritative and the FTB is a
hint. Stage-B makes the FTB-followed stream the delivered path and BTB/BHT/TAGE the
override. `ext_taken_redir`/`ext_buf_mismatch`/`f0_diverged` fold into the single
Stage-B override-redirect. This is the largest single change — do it behind `PRED_PIPE`
with the FTB path proven first.

**Straddle / slot-1 / spec-history.** (i) straddle_q's 2-cycle path must register into
Stage-A so Stage-B sees the assembled 32-bit straddled instr; (ii) slot-1 eligibility
(`slot1_eligible`, `:1087`) is computed at Stage-A, its prediction applied at Stage-B;
(iii) `spec_ghr`/`spec_ghr_l`/`spec_ind_hist` advance at Stage-B (where the prediction
resolves) — the redirect-restore must sample the Stage-B point; the commit-train
carried-index proof is unaffected (older ops all committed).

**Order of implementation (each a verified increment):**
1. **[done, verified]** `PRED_PIPE` param + the Stage-A/B pipeline register, DEAD at 0
   (reset-only → DCE, byte-identical; verified `veryl test` 252/0). Declares the substrate,
   no consumer rewire yet. `const PRED_PIPE: bit = 0` + the `a_valid/a_pc/a_s0/a_s1/
   a_slot1_elig/a_straddle/a_ftb_next` regs (`heliodor_core.veryl` ~412), latched in a
   dedicated always_ff after the W2 `ext_pc_q` register (written ONLY under `else if
   PRED_PIPE` → reset-only at 0 → the regs + fanin DCE). No new analyzer warnings.
2. **[next]** Route the fetch-buffer push through Stage-B under `PRED_PIPE=1` (predictors
   still combinational — a pure +0 structural stage first, measure IPC of the extra stage).
3. Flip predictors to clocked (`*_SYNC_READ=1`) coupled to `PRED_PIPE`; the Stage-B
   apply now consumes the registered read. Prove the FTB-followed delivery + override.
4. Measure IPC (boot cycle counts + benchmarks) and CP (`veryl synth`, expect no CP
   move — confirmed 0 above). Then FTQ (F2) generalises Stage-A to run ahead > 1 block.

Best started in a clean, focused context (large multi-file restructure of the most
delicate, already-tuned fetch logic — same guidance §8.1 gave for R1).

## Independence

Fully independent of Blocks L (LSQ) and the commit side. Shares the front-end with
Block S (pipelined scheduler) only at the rename/IQ boundary — no conflict.
