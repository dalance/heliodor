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
- **[done, verified — commit `a72d909`, ships DEAD at 0]** step 2 / order-item-2 — the
  fetch-buffer write is routed through Stage-B, a **1-deep skid register** between
  extract-assemble/predict (Stage-A, T)
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
    slot-0, as =0). Full regression with the fix (=1): `veryl test` 252/0, litmus N4 pass
    (cy=00559a10), SMP boot N2 pass (cy=01260970 = 19.27M), SMP boot N4 pass — all green.
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

## order-item-3 design analysis (2026-07-24, audited against the RTL)

Auditing the SYNC_READ scaffold + the extract datapath resolved *how* step 3 (flip
predictors clocked) actually lands. Three findings changed the step-3/step-4 framing:

**Finding 1 — flipping `*_SYNC_READ=1` REQUIRES the authority inversion; there is no
"L1 half-step".** The scaffold registers the read OUTPUT, not the address
(`btb.veryl:104` `r0_q = r0`, `lk_idx` combinational on `i_pc`). So at =1 EVERY core
consumer of `btb_hit`/`bht_taken`/`tage_*`/`pred_next_pc_bp` sees the read of
`ic_pc`(T-1), a cycle stale. The Stage-A steer (`ext_taken_redir`, the `ext_pc_q`
advance to `ext_next_pc`, `ext_pop`, RAS push/pop, spec-history, FTB-train — all at T,
`heliodor_core.veryl:1462/1497/1556/1660`) would apply a stale prediction. Moving the
consumers to Stage-B (T+1, where the registered read matches `a_pc`) forces Stage-A to
advance `ext_pc_q` at T on something *available at T* — NOT the clocked predictor —
else it re-presents the same `ext_pc_q` and the clocked read is a duplicate (1 advance
per 2 cycles = half throughput). A Stage-A speculative advance + a Stage-B override IS
the authority inversion. Step 3 (clock the arrays) and step 4 (override redirect) are
therefore inseparable — one change, not two.

**Finding 2 — the Stage-A fast path needs a per-PC predictor the core does not have.**
The FTB (`ICACHE_FETCH_DIRECTED`) is per-DWORD and a fetch-prefetch hint only, and it
EXCLUDES returns + indirects (`heliodor_core.veryl:1746` `!btb_is_ret && !btb_is_ind`).
It cannot supply the per-instruction taken/target the extract advance needs. If Stage-A
advances with only "sequential + computed direct-JAL target" guesses (no fast BTB/BHT),
then every taken conditional (~10 % of insns), every return, and every indirect pays a
+1 Stage-B override bubble → likely **>+10 % cycles, over the ~+8 % budget**. The
classic fix is a fast L0 structure (micro-BTB + fast bimodal) read combinationally at
Stage-A that the big clocked BTB/TAGE overrides — but that is a NEW structure to build.

**Finding 3 — RAS/return timing.** The RAS resolves at Stage-A today (0-bubble return
prediction, `:1331/1084`). In the inversion it moves to Stage-B (+1 per return) unless a
fast-RAS peek is retained at Stage-A. Returns are frequent, so this alone is a few %.

### Design options for order-item-3 (the fork)

- **(A) Accept the bubbles — pure clocked arrays, minimal new logic.** Stage-A advances
  sequentially + computed direct-JAL target; Stage-B (clocked BTB/BHT/TAGE/iBTB + RAS)
  is authoritative and overrides on any taken-cond / return / indirect (+1 each). Fully
  clocks all four arrays (truest "structural"), smallest diff, WORST IPC — measure the
  true cost; it also quantifies exactly how much fast-path option (B) must recover.
- **(B) Build an L0 fast predictor.** Add a per-PC fast BTB + fast bimodal (small
  async-read RF, realistic) at Stage-A for the 0-bubble common case; the clocked
  BTB/TAGE override only on disagreement. Best IPC, most new logic, biggest design.
- **(C) Clock TAGE-output only (partial).** TAGE is already the register-file array
  (never SRAM); registering only its OUTPUT while BTB/BHT keep their combinational Stage-A
  read is a smaller, lower-value partial step that does NOT clock the big SRAM-shaped
  arrays — rejected as "structural completion" but available as a stopgap.

**Recommendation:** (A) first, as the honest structural baseline that fully clocks the
arrays and MEASURES the real IPC cost; then (B) only if (A) exceeds the +8 % budget. (A)
is also the smaller first increment and its measured bubbles size the fast path.

### DECISION (user, 2026-07-24): (A) bubble-tolerant baseline first.

### (A) implementation recipe — SIMPLE variant (FTB-off, cleanly measurable)

The clean-measurement trap: keeping the F0 FTB while Stage-A advances sequentially is
INCONSISTENT (F0's FIFO holds FTB-taken target dwords; a sequential Stage-A reads the
wrong ones) — reconciling that IS the hard FIFO-follow logic we are deferring. So the
SIMPLE (A) gates the F0 FTB OFF under the override, making F0 + Stage-A both purely
sequential. The FTB-loss does NOT muddy the measurement: isolate it with the existing
`ICACHE_FETCH_DIRECTED` knob —

    inversion-cost = cyc(override=1, FTB=0)  −  cyc(order-item-2, FTB=0)

both terms FTB-off, so the delta is the pure authority-inversion (taken-branch refill)
cost. (Then (B) recovers it with a fast path; the FTB itself is one candidate fast path.)

New knob: `const PRED_OVERRIDE: bit = 0;` (requires `PRED_PIPE` — the skid is the
Stage-A/B substrate the override rides on). At =1 it also forces the four
`{BTB,BHT,TAGE,IBTB}_SYNC_READ=1` (clocked) and gates `ICACHE_FETCH_DIRECTED`'s F0
redirect off. DEAD at 0 (every new branch under `if PRED_OVERRIDE` → byte-identical).

Mechanics at PRED_OVERRIDE=1:
1. **Clocked predictors.** `{BTB,BHT,TAGE,IBTB}_SYNC_READ` couple to PRED_OVERRIDE, so
   the module outputs (`btb_hit`/`bht_taken`/`tage_*`/`ibtb_*`) are the read of
   `ic_pc`(T-1) — i.e. they now correspond to `a_pc` when consumed at Stage-B (T+1).
2. **Stage-A (T) — no prediction.** Pop the WORD FIFO head, assemble the bundle
   (`a_s0`/`a_s1`, RVC/straddle), present `ext_pc_q` to the clocked predictors, and
   advance `ext_pc_q` PURELY SEQUENTIALLY (`ic_pc + pc_advance`, and slot-1 sequential
   `s1_pc + s1_len`) — never take a branch here. Capture the raw bundle into the a_*
   skid (already present). `ext_pop` follows the sequential advance. NO F0 steer, NO RAS
   push/pop, NO spec-history update at Stage-A.
3. **Stage-B (T+1) — predict + override.** The clocked outputs now match `a_pc`. Compute
   `predicted_taken`/`pred_next_pc_bp` (+ slot-1) HERE. Write the fetch buffer with the
   resolved prediction (as today). Do the RAS push/pop, spec-history (`spec_ghr`/
   `spec_ghr_l`/`spec_ind_hist`) update, and FTB-train HERE (all keyed on the Stage-B
   delivery). If `predicted_taken` (slot-0) or slot-1-taken → OVERRIDE: redirect F0 to
   the target ({target[63:3],0}), flush the WORD FIFO + fetch-buffer entries younger than
   this bundle, and re-steer `ext_pc_q` to the target. F0 refills from the target (icache
   latency = the taken-branch bubble). Commit/early redirect keep priority.
4. **F0 FTB off.** `f0_ftb_hit`/`ext_taken_redir`/`ext_buf_mismatch`/`f0_diverged` fold
   away (FTB gated) so F0 is a plain sequential stream; the override redirect above is the
   only extract→F0 steer. This removes the delicate FTB reconciliation from the =1 path.

Known subtleties (discover/handle at implementation):
- **spec-history 1-cycle staleness**: back-to-back branches — bundle N+1's Stage-A read
  index uses `spec_ghr` before bundle N's Stage-B update lands (a common real-pipe
  approximation; bypass if it measurably hurts). The commit-train carried-index proof is
  unaffected (older ops all committed).
- **RAS ordering**: push/pop now at Stage-B; the 1-deep skid means at most one bundle
  in flight between the RAS read and its update — verify a call immediately followed by
  its return (skid-adjacent) still nests correctly (may need a Stage-A→B bypass).
- **straddle / slot-1**: unchanged datapath, but slot-1's taken-override and the
  straddle 2-cycle path must re-time onto the Stage-B resolve.
- **override flush vs skid**: the a_* skid holds the CURRENT bundle (being delivered);
  the override flushes YOUNGER state (WORD FIFO + fb), not the delivering bundle itself.

### (A) increment decomposition (each a verified step; DEAD at 0 until the flip)

- **3a.1 + 3a.2 [done, verified — `veryl test` 252/0 byte-identical]** Declared
  `const PRED_OVERRIDE: bit = 0;` (with the full (A) design comment) next to `PRED_PIPE`,
  and wired the Stage-A SEQUENTIAL advance: `ext_seq_next = fb_push1 ? s1_pc+s1_len :
  ic_pc+pc_advance`, `ext_eff_next = if PRED_OVERRIDE ? ext_seq_next : ext_next_pc`, with
  `ext_pop` + the `ext_pc_q` advance now following `ext_eff_next`. Every arm folds to
  today's `ext_next_pc` at 0 (const-fold) → byte-identical. NOTE the substrate is thin —
  order-item-2's a_* skid is reused; Stage-B recomputes the prediction from the CLOCKED
  module outputs (which auto-align to `a_pc` once `*_SYNC_READ=1`), and reuses the already
  -captured `a_pred_index0`/`a_ghr_fold0` for the commit-carried index. No new capture regs
  for the prediction itself; RAS/spec-history bypass regs (if needed) are discovered in 3a.3.
  Slot-1 caveat carried to 3a.3: `ext_seq_next` still uses `fb_push1`, whose `slot1_eligible`
  gates on `!predicted_taken` — a Stage-A prediction that will not exist at =1; the slot-1
  eligibility must be re-timed onto the Stage-B resolve in 3a.3 (byte-identical at 0 today).
- **3a.3 [done, verified — 3 commits, `veryl test` 252/0 byte-identical each]** The full
  authority inversion, DEAD at 0, in three slices:
  - **3a.3(i)** `sb_next0/1` (Stage-B resolved next-PC = `predicted_taken?pred_target:a_pc+a_len`,
    reusing the clocked `predicted_taken`/`pred_target` + the captured a_pc for the fall-through),
    `sb_slot1_kill`, `slot1_eligible` drop-`!predicted_taken`, fb-write `fb_pred_next_pc`/`fb_ghr_fold`
    routed through sb_* under PRED_OVERRIDE.
  - **3a.3(ii)** `deliver0/deliver1` (Stage-B delivery); RAS spec push/pop, gshare + indirect
    spec-history, keyed on deliver0/1; FTB-train gated OFF under PRED_OVERRIDE.
  - **3a.3(iii)** `sb_override` (Stage-B taken redirect) + `sb_override_target`; `ext_taken_redir`/
    `f0_diverged` gated off; pc_fetch_q/WORD-FIFO-flush/ext_pc_q-re-steer/skid-squash all add
    sb_override.
  - **Design pivot (loop + drift, documented at `sb_next0`):** the planned "re-present a_pc to the
    clocked predictor during a skid hold" closes a SPURIOUS comb loop (pred-index → sb_hold →
    fb_free → rename_fire2 → slot1_valid → predicted_taken → pred-index; FETCH_REG=1-dead
    fb_bypass2/fb_fall keep it symbolically live so Veryl rejects it though the real circuit has
    none). Variant A instead ACCEPTS hold-drift (a bundle held >1 cycle resolves with its
    successor's prediction) — proven accuracy-only (every predictor output feeds only the
    speculative fetch path; `c_bp_mispredict = pred_next_pc != arch_next_pc` validates EVERY
    committed op incl. non-branches, so a drifted non-branch → sequential arch_next → caught).
- **3a.4 [DONE — flip measured, correctness bug localized, SHIPPED AT 0]** Flipped all six consts
  (`PRED_PIPE`, `PRED_OVERRIDE`, `{BTB,BHT,TAGE,IBTB}_SYNC_READ`) in a test build. Findings:
  - **Builds, NO comb loop; `veryl test` 252/0** (fast + arch rv64ui/um/ua/mi/si/uf/ud all pass —
    basic branch/jump/jalr correctness holds).
  - **Microbench matrix (correct runs → valid IPC):** memcpy PASS (121333 cy vs 80099 base, **+51%**),
    multiply PASS, median PASS, **coremark PASS bit-exact** (instret 374357 == base; 410812 cy vs
    276893, **+48%**). So the inversion cost is **~+48–51 % cycles — far over the ~+8 % budget**,
    decisively confirming Finding 2: variant (A) is the honest worst-case and needs the fast-path
    (B) or the drift-fix to be viable. There is no CP number to chase (F1 CP = 0, §CP measurement).
  - **CORRECTNESS BUG (dhrystone + boot): silent data corruption, localized to the slot-1 + override
    interaction.** dhrystone commits 2.36M instret (base completes at 273K) without reaching tohost,
    with `mispred=0 redirect=0 earlymis=13488` — control flow IS corrected (early redirects) but a
    WRONG value commits (an instruction delivered with wrong bytes / skipped / duplicated whose
    next-PC matches, so `c_bp_mispredict` doesn't fire). **Bisection:**
    - `PRED_PIPE=1` alone → dhrystone PASS (instret 264834).
    - `SYNC_READ=1 + PRED_PIPE=1 + PRED_OVERRIDE=0` (stale-prediction "measurement flip") → PASS
      (instret 264834, slow) — the SYNC_READ scaffolds are functionally HEALTHY.
    - `PRED_OVERRIDE=1` full → FAIL (2.36M loop).
    - `PRED_OVERRIDE=1` + **slot-1 disabled** (`slot1_valid_gate = !PRED_OVERRIDE`) → **PASS**
      (instret 264834, 380185 cy). ⇒ the single-slot inversion (Stage-A seq advance, Stage-B
      predict/RAS/spec/override) is CORRECT; the bug is SPECIFIC to the dual-issue slot-1 path.
    - Analysis of every slot-1 sub-signal (a_s1/a_s1_pc capture, sb_next1, sb_slot1_kill, deliver1,
      sb_ovr_taken1, fb_wr1, ext_seq_next-via-fb_push1, RAS ordering) found each self-consistent;
      the exact corner is NOT yet pinpointed. **Next debug step:** commit-PC trace of the slot-1-on
      run vs the slot-1-off (correct) run under an identical seed, diff to the first divergence PC —
      that instruction's bundle is the corner (candidate: a 2-slot bundle where slot-0 is taken and
      slot-1 was optimistically produced, at a dword boundary / under back-pressure hold).
  - **Shipped at 0** (all six consts reverted; repo == the 3a.3(iii) commit, byte-identical). The
    slot-1 bug + the IPC recovery (drift-fix output-register-stall, and/or option (B) fast path)
    are the next increment; a single-issue (slot-1-off) PRED_OVERRIDE=1 is a WORKING but
    lower-IPC fallback baseline if a dual-issue fix proves hard. **[slot-1 bug root-caused + fixed
    in 3a.5.]**
- **3a.5 [DONE — slot-1 corner ROOT-CAUSED + FIXED, shipped at 0]** Commit-PC trace bisection
  (3a.4's planned next step) localized the dhrystone corruption to `Proc_1`'s call of `Proc_3`.
  - **Mechanism.** A 2-op bundle {slot-0 `c.ld`@0x13a, slot-1 `c.sd`@0x13c} held in the a_* skid
    (fb full) ≥2 cyc lets `ext_pc_q` drift to 0x13e (`jal Proc_3`); the clocked predictor output
    then drifts to pred(0x13e)=TAKEN / target 0xe4. At the drain the drifted `predicted_taken`=1 →
    `sb_slot1_kill` drops the store 0x13c, `sb_override` steers F0 to 0xe4 (skipping the jal 0x13e),
    and the non-branch slot-0 (0x13a) is delivered carrying a stray `pred_next`=0xe4.
  - **Root cause.** 0x13a retires on **commit lane B (`commit2`)**, which does NOT run the
    commit-time mispredict check (`c_bp_mispredict` is head/lane-0 only). Lane B relied on the
    invariant "a simple non-control op always falls through" — true for the plain predictor, but
    PRED_OVERRIDE's drift/override breaks it. The stray `pred_next`=0xe4 is thus never validated;
    the ROB holds 0x13a→0xe4 (skipping store 0x13c + jal 0x13e), `ra` is never written, and Proc_3
    returns to garbage → runaway. Exactly the "wrong-bytes / skipped, next-PC-matches" class 3a.4 named.
  - **Fix (`rob.veryl` only, DEAD at 0).** `c2_valid` under `PRED_OVERRIDE` additionally requires the
    head+1 op's recorded `pred_next` == its fall-through (== arch_next for a non-control op, which
    lane-B ops always are). A stray/mispredicting simple op is thereby kept OFF lane B and deferred
    to the head, where `c_bp_mispredict` fires and redirects to the fall-through — recovering the
    skipped store+jal. Written as `if PRED_OVERRIDE ? guarded : original`; the rob-internal
    `const PRED_OVERRIDE` is **FLIP-COUPLED** to the core's (flip both together — a mismatched pair
    silently re-opens the corner). `heliodor_core.sv` stays byte-identical; `rob.sv` adds only the
    inert mux. Flip set is now **7 consts** (the six + `rob::PRED_OVERRIDE`).
  - **Verify @ =1 (7 consts flipped).** dhrystone PASS, **instret 264834 == base (BIT-EXACT)**,
    316680 cy (+26% vs 251423 base — and faster than the 380185-cy single-issue slot-1-off fallback,
    so the dual-issue overriding predictor now works AND beats that baseline). full `veryl test` 252/0
    (fast + arch). @ =0: `veryl test` 252/0; SV byte-identical (cycle-exact DEAD scaffold).
  - **REMAINING — 2nd corner (boot, DISTINCT from slot-1).** With the fix, N=1 Linux boot @ =1 no
    longer corrupts early, but hits a separate infinite loop: from cyc ~6.0M the commit head pins to a
    kernel siphash-style leaf at PA 0x800b9be2–bf2 forever (heartbeat: PC frozen, retire count still
    creeping at IPC ~0.1). The `ret`@0x800b9bf2 resolves `ra`=0x800b9be2 — i.e. `ra` is corrupted to
    point back into the callee → self-return loop. dhrystone + all arch are bit-exact with the fix, so
    this is NOT the lane-B slot-1 case; it is a separate PRED_OVERRIDE data/`ra`-corruption path the
    boot's early page-table/mem-init (~0x80010cxx, entry ~cyc 6.2M) exercises. Localized but not yet
    root-caused. **Next debug step:** window the commit trace at the ~6.2M loop entry and find the
    jal/store whose effect on `ra` is lost.
  - **Shipped at 0** (all 7 consts reverted; the fix is DEAD, byte-identical). Next increment: the
    boot 2nd corner, then IPC recovery (drift-fix output-register-stall / option (B) fast path).

## Independence

Fully independent of Blocks L (LSQ) and the commit side. Shares the front-end with
Block S (pipelined scheduler) only at the rename/IQ boundary — no conflict.
