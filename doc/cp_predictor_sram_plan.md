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
  - **REMAINING — 2nd corner (boot, DISTINCT from slot-1; further localized).** With the fix, N=1
    Linux boot @ =1 no longer corrupts early but HANGS from cyc ~6M — the commit head pins (heartbeat)
    to a **`rdtime`-based `udelay` spin at VA 0x800b9bde–bf2**: `bde: rdtime a4` (start), then the loop
    `be2: rdtime a5; be6: sub a5,a5,a4 (elapsed); be8: bltu a5,a0,→bee; bec: ret (exit); bee: (dead);
    bf2: j be2` — adjacent to a `memcpy` at 0x800b9c8c–d32. (The earlier "siphash / `ra`=0x800b9be2
    self-return" note was a MIS-ALIGNED-disasm artifact; the trace's committed `c_instr` confirms
    VA→PA offset 0 and the real ops.) The delay's `bltu` exit fires normally around cyc 15M (elapsed
    reaches a0 → `ret`), but by cyc 30M it **never exits** (be8 taken 1432/1432) and the PC never
    returns to a higher-level caller for 58M+ cycles → an **outer loop that repeatedly calls this
    udelay is non-terminating**, and/or one udelay's `a4` baseline resets so `elapsed = rdtime−a4`
    never reaches the target (elapsed observed sawtoothing 0→~0x27ff). The loop carries periodic drift
    mispredicts (`be6` mp=1, pred_next skips be8) that ARE caught on lane 0 — so the escape is a
    DIFFERENT wrong-path-commit path than slot-1 (dhrystone+arch stay bit-exact). Behaviour is
    **time-varying** (completes ~15M, stuck ~30M). Not yet root-caused — needs register-operand
    (a0 / a4 / outer-loop-counter) tracing to pin the corrupted value.
  - **Strategic note (next-increment choice).** The hold-drift is the shared root of the slot-1 corner
    (fixed here) and very likely this boot corner. The **drift-fix — a per-module read-enable that
    FREEZES the predictor output register during a skid hold** (the option deferred at 3a.3's design
    pivot, where the naive combinational re-present closed a spurious comb loop) — removes the stray
    predictions at the source AND recovers the +48 % IPC. It therefore addresses both the remaining
    correctness corner and the viability gap in ONE structural step, so it is the higher-value next
    increment over continuing to chase this specific corner's corrupting commit.
  - **Shipped at 0** (all 7 consts reverted; the fix is DEAD, byte-identical). Next increment: the
    drift-fix (predictor output-register freeze) — resolves IPC + likely the boot corner — else option
    (B) L0 fast predictor. **[done in 3a.6 — the boot corner WAS the hold-drift.]**
- **3a.6 [DONE — hold-drift fix, boot corner RESOLVED, shipped at 0]** The hold-drift (the clocked
  predictor output drifting from pred(a_pc) to pred(successor) while a bundle is held in the skid,
  fb full > 1 cyc) is confirmed the shared root of the slot-1 corner (3a.5) AND the boot corner —
  freezing it makes BOTH go away.
  - **Fix (`heliodor_core.veryl`, `PRED_HOLD_FREEZE`, DEAD at 0).** Capture the ALIGNED resolved
    prediction (`predicted_taken`/`pred_target` ×2) on the drain-aligned cycle (`produce_q` = `fb_push0`
    delayed one cycle — the cycle on which the clocked outputs equal pred(a_pc)) into `held_*`, and
    FREEZE it while the bundle is held; Stage-B (`sb_next0/1`, `sb_slot1_kill`, `sb_override`,
    `sb_override_target`, `sb_ovr_taken1`) consumes the frozen `*_eff = produce_q ? live : held`. This
    is a REGISTERED capture, NOT the combinational re-present of a_pc that 3a.3's pivot found closes a
    spurious comb loop — so no loop. `*_eff` folds to the live value at 0 → byte-identical (cycle-exact).
    `PRED_HOLD_FREEZE` joins the flip set (now **8 consts**).
  - **Verify @ =1 (8 consts).** **N=1 Linux boot COMPLETES — cy 15.9M, +12 % vs base 14.2M** (was a
    HANG at =1 without the freeze; the boot corner WAS the hold-drift). dhrystone bit-exact (310655
    cy), coremark bit-exact (411616 cy), memcpy pass (118642 cy); full `veryl test` 252/0. @ =0:
    `veryl test` 252/0, byte-identical.
  - **IPC picture.** The freeze's big win is the **hold-heavy real workload** (boot: hang → +12 %).
    The compute-heavy microbenches stay high (dhrystone +24 %, coremark +49 %, memcpy +48 % vs base)
    because they hold rarely (little drift) and the **fundamental Stage-B override bubble** — a +1 on
    every taken-cond/return/indirect — dominates. Closing THAT is option (B) (an L0 fast predictor at
    Stage-A) or F2's FTQ, not the drift-fix.
  - **Remaining (accuracy-only).** RAS / spec-history (`spec_ghr`/`spec_ind_hist`) + the `btb_hit`/
    `is_call`/`is_ret`/`is_cond` RAS-train bits still re-read live under a hold, so they can drift —
    but that is ACCURACY-ONLY (every predictor output is validated + corrected at commit; the boot +
    dhrystone + arch are all bit-exact). Freezing them too (capture the raw btb bundle) is a clean
    follow-up if the residual +12 % boot / microbench accuracy is worth it.
  - **Shipped at 0** (all 8 consts reverted; DEAD, byte-identical). The overriding clocked predictor
    (variant A) is now **correct end-to-end at =1** (boot + dhrystone + arch); the remaining work is
    IPC (option (B) fast path / F2 FTQ) — a performance, not correctness, item.

## F1 option (B) L0 fast predictor + F2 FTQ — design (2026-07-25)

Written after 3a.6 made variant (A) correct end-to-end. The remaining gap is IPC:
the **Stage-B override bubble** — a +1 refill on every taken-cond / return / indirect
because Stage-A advances SEQUENTIALLY and Stage-B corrects a cycle late (microbench
+24–49 %; boot +12 %). Closing it is option (B) or F2. The audit below establishes
they are **the same structure at two scales**, so they form one continuous path.

### The unifying insight — L0 fast predictor IS the FTQ producer engine

The override bubble exists because *nothing at Stage-A produces a next-target in time*.
Both fixes add a **fast, combinational, per-PC next-target predictor** at the front:

- **option (B)** places it at **Stage-A** of the existing extract pipeline. Stage-A
  advances to the L0-predicted target (0 bubble); the clocked full BTB/BHT/TAGE at
  Stage-B **overrides only on disagreement** (the classic overriding-predictor pair).
  The current WORD-FIFO / Stage-A/B structure is otherwise unchanged. **Effort: medium.**
- **F2** promotes that same fast predictor into a **free-running loop** (PC → L0 →
  next PC, 1 block/cycle) that **enqueues fetch-block descriptors into an FTQ**; F0
  (icache read) becomes an FTQ *consumer*, decoupled, so the predictor runs many blocks
  ahead and hides icache-miss latency. The full clocked predictor is still the override.
  **Effort: large.**

So the L0 built for (B) is **not throwaway** — it is exactly the engine F2's FTQ
producer runs. Build order **B → F2** is one structure, incrementally decoupled.
(This also matches the real µarch: L0/µBTB fast path + L2/TAGE clocked override, then
the decoupled predictor→FTQ→fetch of Reinman/Calder — heliodor's shipped per-dword FTB
`ICACHE_FETCH_DIRECTED` is the germ of the F2 block predictor, currently gated OFF under
PRED_OVERRIDE.)

### What the L0 must reproduce (audit of the extract predictor)

Today's combinational extract prediction (`heliodor_core.veryl:1095/1104/1105`, slot-1
`:1149/1152/1153`), the thing variant (A) delayed to Stage-B:
- `predicted_taken = btb_hit && (!btb_is_cond || cond_taken0)`,
  `cond_taken0 = tage_hit ? tage_taken : bht_taken` (TAGE over gshare BHT).
- `pred_target = pred_use_ras ? ras_spec_top : pred_use_ibtb ? ibtb_target : btb_target`
  (return→RAS, indirect→iBTB, else BTB last-target).

The L0 is a **small, realistic (async-read flop RF, below the SRAM floor) approximation**
of this, read combinationally on `ext_pc_q` at Stage-A:
- **L0 µBTB** — direct-mapped, tagged, ~32 entries, `{target, is_cond, is_call, is_ret,
  is_ind}`. (Full BTB is 4096.)
- **L0 bimodal** — ~128–256 × 2-bit, **PC-indexed (no gshare)** for speed. (Full is 8192 gshare + TAGE.)
- **L0 RAS peek** — reuse the existing RAS `o_spec_top`/`o_spec_valid` (already combinational
  flops) at Stage-A for returns (Finding 3's fast-RAS peek). Indirects: **L0 skips them**
  (no fast iBTB) → they pay the Stage-B override bubble, rare.
- `l0_taken = l0_hit && (!l0_is_cond || l0_bimodal_taken)`;
  `l0_target = l0_is_ret ? ras_top : l0_btb_target`.

Realism note (feedback_heliodor_realistic_sram_real_port_config): keep the L0 **small on
purpose** — a real L0 is fast *because* it is small. CP is NOT the constraint here (retire
wall 12.8 ns, predictor cone masked ~7 ns below), but sizing the L0 to "whatever CP allows"
would be structurally dishonest. Start small, **measure the realistic overriding-predictor
IPC**, and accept it.

### Option (B) — concrete DEAD scaffold (`PRED_L0_FAST`, the 9th const)

New `const PRED_L0_FAST: bit = 0;` (requires the full variant-A flip set — PRED_PIPE +
PRED_OVERRIDE + {BTB,BHT,TAGE,IBTB}_SYNC_READ + PRED_HOLD_FREEZE + rob::PRED_OVERRIDE).
Mechanics at =1:
1. **L0 structures** (µBTB + bimodal flops, async read on `ext_pc_q`), trained at commit
   off the same taken-control train that fills the full BTB/BHT (a subset — L0 holds the
   hottest sites). If boot hit-rate is low, add an **L1→L0 fill** (populate L0 from the
   full BTB on a Stage-B hit) — a realistic second increment.
2. **Stage-A advance via L0.** `ext_l0_next = l0_taken ? l0_target : ext_seq_next`;
   `ext_eff_next = PRED_OVERRIDE ? (PRED_L0_FAST ? ext_l0_next : ext_seq_next) : ext_next_pc`.
   Capture `a_l0_taken`/`a_l0_target` into the skid alongside the bundle.
3. **Stage-B override on DISAGREEMENT.** The full clocked prediction resolves on `a_pc`
   (with the 3a.6 hold-freeze). Redefine `sb_override` from "any taken" to "full disagrees
   with what Stage-A did": `sb_override = (sb_full_taken != a_l0_taken) || (sb_full_taken &&
   sb_full_target != a_l0_target)`, redirect to the full result. Common case L0==full → **no
   override, 0 bubble**; residual bubble only on L0 miss / direction-mismatch.
4. **Correctness net unchanged.** Both L0 and the Stage-B full prediction are SPECULATIVE;
   commit-time `c_bp_mispredict` (+ the 3a.5 `rob::PRED_OVERRIDE` lane-B guard, still in
   force) remain authoritative. Option (B) is an **accuracy/IPC change, not correctness** —
   it rides on the 3a.5+3a.6 fixes. DEAD at 0: every new term under `if PRED_L0_FAST` →
   byte-identical; L0 arrays reset-only → DCE.

Increment decomposition (each verified, DEAD at 0): **b.1** L0 arrays + commit train
(no consumer) → **b.2** Stage-A L0 advance (capture a_l0_*) → **b.3** Stage-B
disagreement-override → **b.4** flip the 9 consts, measure IPC (expect the +48 % to
collapse toward baseline as far as L0 coverage reaches), regress (test / litmus / boot).
Optional **b.5** L1→L0 fill if hit-rate is the limiter.

### F2 — FTQ decoupled fetch (sketch, builds on (B)'s L0)

Promote the L0 loop to a free-running producer:
```
 predictor loop (L0 fast + clocked full override) ──enqueue──▶ FTQ ──dequeue──▶ F0 (icache read) ─▶ WORD FIFO ─▶ extract/decode
```
- **FTQ** = queue of block descriptors `{start_pc, taken, target, pred metadata}`. The
  predictor loop (L0-driven, 1 block/cycle) fills it regardless of F0's rate; F0 dequeues
  and reads the icache for each block. This is the second decoupling queue (the WORD FIFO
  is the existing icache→extract one).
- **Full predictor = override**, a stage behind L0 in the producer (or checked at decode):
  a block the full predictor disagrees with squashes the FTQ tail + re-steers — the same
  override, now at the FTQ granularity.
- The shipped per-dword FTB is re-cast as the block predictor feeding the loop; the
  delicate FTB/straddle/WORD-FIFO reconciliation (deferred throughout F1) is the bulk of
  F2's work. **Large, its own multi-session sub-effort — start after (B) is measured.**

### Recommendation

**B first, then F2.** (B) recovers IPC on the already-correct variant (A), is a clean
9th-const DEAD scaffold on the current structure, and its L0 is precisely F2's producer
engine — so no work is wasted and the fast-predictor accuracy is proven before the large
FTQ restructure. F2 then decouples the same L0 into the run-ahead FTQ, the true Phase-14
decoupled front end.

### (B) BUILT + MEASURED (b.1–b.4, 2026-07-25) — placement-1 L0 is MARGINAL

Built as three DEAD-at-0 increments (each `veryl test` 252/0 byte-identical), then flipped
(the 8 variant-A consts + `PRED_L0_FAST` = the 9-const set):
- **b.1** `l0pred.veryl` (32-entry µBTB + 128-entry PC-bimodal, async-read flop RF, all
  fields reset — a real flop RF, NOT the SRAM-inference idiom) + instance + commit train +
  the Stage-A advance arm (`ext_eff_next` L0 target) + slot1 gate. `veryl check` == baseline
  (zero new warnings).
- **b.2** `l0_redir` — the Stage-A F0 re-steer (flush WORD FIFO + steer `pc_fetch_q` to the
  L0 target), the Stage-A analogue of `sb_override`; `sb_override` (older, draining bundle)
  outranks it. `ext_pc_q` already advanced via b.1's `ext_eff_next`.
- **b.3** Stage-B disagreement-override: `sb_override` fires only when the clocked FULL
  slot-0 prediction disagrees with what Stage-A (L0) did (`a_l0_taken`/`a_l0_target` captured
  in the skid). `sb_next0` (the full prediction) stays the fb_pred_next_pc / commit
  check-of-record — it equals the L0 target when they agree and the override makes the stream
  follow full when they disagree, so it is the actual stream next-PC either way.

**b.4 flip @ 9 consts — `veryl test` 252/0, all instret BIT-EXACT (correct), no comb loop.**
IPC vs base / variant-A (3a.6):

| bench      | base   | variant-A     | L0 cond-ON     | L0 cond-OFF   |
|------------|--------|---------------|----------------|---------------|
| dhrystone  | 251423 | 310655 (+24%) | 294328 (+17%)  | 307875 (+23%) |
| memcpy     | 80099  | 118642 (+48%) | 102650 (+28%)  | 118642 (+48%) |
| coremark   | 276893 | 411616 (+49%) | 419488 (+51%!) | 407593 (+47%) |
| boot N=1   | 14.2M  | 15.9M (+12%)  | 15.58M (+9.7%) | 15.81M (+11%) |

**Finding: placement-1 L0 caps at ~1 cycle per L0-predicted taken branch** (the Stage-A vs
Stage-B earliness) and does NOT remove the dominant bubble (the target's icache-read latency),
because the L0 sits at extract's Stage-A — BEHIND fetch — so it re-steers F0 one cycle sooner
but cannot prefetch the taken path ahead of extract. Worse, the L0's weak gshare-less bimodal
disagrees with the full TAGE on context-dependent conditionals, **double-bubbling** them
(l0_redir to the wrong side + Stage-B correct):
- **cond-ON** takes strong-bimodal conditionals → wins on simple loops (memcpy −13%, boot −2%,
  dhrystone −5%) but **REGRESSES coremark +2%** (its TAGE-favourable branches).
- **cond-OFF** (unconditional + return only, where the L0 can never disagree with full on
  direction) never regresses but the win is tiny (< 2% everywhere) — coremark −1%, boot ~0.

Neither config is a clear win. The measurement DECISIVELY confirms the plan's Finding 2/3
framing: the override bubble is dominated by the target-fetch latency, which only **run-ahead
fetch (F2 FTQ)** hides — a fast predictor a stage earlier (placement-1) is not enough; the
predictor must run AHEAD of fetch (placement-2). **Recommendation: pivot to F2**, reusing the
b.1–b.3 L0 as the FTQ producer's fast engine, with the FULL clocked TAGE (not the weak L0
bimodal) as the block-direction predictor.

**Shipped at 0** (all 9 consts + `L0_PRED_COND` reverted; `veryl test` 252/0 byte-identical).
The L0 scaffold (`l0pred.veryl` + the b.1–b.3 datapath) is BANKED DEAD as F2 substrate, not
enabled — placement-1's marginal, workload-dependent IPC does not justify shipping it live.

## F2 — FTQ decoupled fetch: detailed design (2026-07-25, post-(B) pivot)

The (B) measurement fixed the requirement: to remove the override bubble the fast predictor
must run **AHEAD of fetch** (placement-2) so the taken path is *prefetched* before extract
reaches the branch — a predictor read one stage earlier (placement-1) only shaves the Stage-A
vs Stage-B cycle. Over heliodor's variable-length RVC stream the run-ahead predictor cannot
decode ahead to find branch offsets, so it must be **per-fetch-address (dword)** — which is
exactly the shipped **FTB** (`ICACHE_FETCH_DIRECTED`), not the per-branch-PC L0/BTB.

### The key realization — the FTB already IS placement-2; variant-A disabled it

Pre-variant-A (`ICACHE_FETCH_DIRECTED=1`, extract-authoritative) the FTB **re-steers F0** to
predicted targets, so F0 prefetches the taken path into the WORD FIFO and extract consumes a
correctly-predicted stream — placement-2 for the FTB-covered branches (unconditional +
strong-cond). That is why the pre-variant-A baseline has decent IPC. **Variant-A's +48% is
mostly the cost of GATING THE FTB OFF** (`!PRED_OVERRIDE` on `f0_ftb_hit`/`ext_taken_redir`/
`f0_diverged`) to make F0 purely sequential — the SIMPLE-(A) recipe did this deliberately to
avoid the "FIFO-follow reconciliation" it deferred. **F2 is that deferred reconciliation:**
keep the big BTB/BHT/TAGE **clocked** (variant-A's structural win — the ~35 KB arrays are
SRAM-registered) AND re-enable the **FTB as the run-ahead F0 driver**, with the clocked full
predictor at extract as the **override**. FTB fast-path prefetch + clocked-full override = the
"overriding predictor" the plan named, now correctly placement-2.

### F2-lite (first target) vs F2-full

- **F2-lite — FTB-authoritative F0 + clocked-full override (~1 block ahead).** Re-enable the
  FTB under PRED_OVERRIDE so F0 follows FTB targets (prefetch); extract's clocked full pred
  overrides on FTB miss/mispredict (the disagreement-override pattern from (B) b.3, now FTB-vs-
  full instead of L0-vs-full). This is the deferred FTB reconciliation and recovers the bulk of
  the +48% (the prefetched taken path removes the icache-latency bubble on FTB-covered branches).
  Returns/indirects (FTB-excluded) still override → bubble, as today.
- **F2-full — first-class multi-block FTQ (N blocks ahead).** Decouple the FTB predictor loop
  from F0 entirely: `pc_pred` advances independently (clocked FTB read → next `pc_pred`), each
  block enqueued into an **FTQ** {dword_pc, taken, target, gshare_idx/ind_hist/kind for train};
  F0 dequeues and reads the icache, running many blocks behind the predictor so icache-miss
  latency is fully hidden and run-ahead prefetch is driven. Generalises F2-lite's 1-ahead FTB
  into an N-deep queue.

### heliodor realization + the reconciliation challenges

The hard part (why (A) deferred it): with F0 following the FTB, the WORD FIFO holds the
FTB-predicted (jumping) stream, so extract's `ext_pc_q` is non-sequential vs the FIFO and the
existing `ext_head_match` / `f0_diverged` / straddle / `f0_no_ftb` corners all re-engage —
now composed with the Stage-A/B skid + clocked predictors. Specifically:
- **FTB coverage of returns/indirects.** The FTB excludes them (`!btb_is_ret && !btb_is_ind`),
  so F0 can't prefetch a return/indirect target — these stay Stage-B overrides. A first-class
  FTQ could carry a run-ahead RAS for returns (a known decoupled-front-end technique).
- **FTB direction for conditionals.** The FTB's 2-bit `ftb_conf` (strong-taken==3 follows) is
  the run-ahead direction — weaker than TAGE, so a strong-FTB-but-TAGE-not-taken cond
  double-bubbles (the same trap (B) hit). The full TAGE override at extract corrects it; the
  FTB conf gate bounds how often it fires wrong.
- **straddle / slot-1 / WORD-FIFO head tracking** must be re-reconciled with a non-sequential
  F0 stream under the skid — the delicate, already-tuned shape-W logic, now under PRED_OVERRIDE.
- **Train.** The FTB trains at extract/commit on the delivered prediction (as today); under F2
  it must train from the clocked-full resolution so the FTB tracks the authoritative predictor.

### Increment plan (DEAD-scaffold, each =0 byte-identical, flip last)

- **f2.1** ✅ DONE (`dd0f4da`). Re-enable the FTB F0 redirect under PRED_OVERRIDE behind a new
  `const FTB_OVERRIDE`. The three `!PRED_OVERRIDE` gates that keep the FTB inert are coupled to
  `!PRED_OVERRIDE || FTB_OVERRIDE`: **`ftb_br_deliver`** (the FTB *train* — this is the actual
  "f0_ftb_hit off" mechanism: with train gated, no entry is ever written so `f0_ftb_hit` never
  fires and F0 streams sequentially; `f0_ftb_hit` itself needs no change — it starts firing once
  the FTB retrains), **`ext_taken_redir`**, **`f0_diverged`**. DEAD at 0: folds to `!PRED_OVERRIDE`
  → *.sv byte-identical to HEAD; veryl test 252/0. This is the substrate — F0 can follow the FTB
  while the clocked predictors are on.
- **f2.2** ✅ DONE (`ext_eff_next` FIFO-follow substrate). Extract-side reconciliation: the Stage-A
  advance now tracks the FTB-followed (non-sequential) WORD FIFO under PRED_OVERRIDE. New
  `ext_ftb_follow` predicate — on a sequential dword-cross where the next FIFO entry is a buffered
  non-sequential FTB target (`wf_count>=2 && !head1_seq`) — makes `ext_eff_next` follow
  `wf_pc[wf_head+1]` (the dword F0 actually fetched) instead of the sequential successor, so
  `ext_head_match` holds next cycle (no stall on the non-sequential FIFO) and `ext_pop` consumes the
  head as the cross is taken. `ext_head_match`/straddle "track" by construction once the advance
  follows the FIFO (the across-dword read already self-guards on `head1_seq`/`ext_next_valid`). The
  target's within-dword offset is resolved at Stage-B (`sb_override`, f2.3) — extract resumes at
  offset 0 here. DEAD at FTB_OVERRIDE=0: `ext_ftb_follow` const-false → inner mux folds to
  `ext_seq_next`, predicate + `wf_pc[head+1]` read DCE → `ext_eff_next` byte-identical; *.sv
  byte-identical to HEAD, veryl test 252/0. See "f2.2/f2.3 reconciliation design" below.
- **f2.3** ✅ DONE (`sb_ovr_soft` prefetch-reuse). Stage-B override = FTB-vs-clocked-full
  disagreement, realized via the FLUSH condition (cleaner than suppressing the fire — the override
  must still re-steer ext_pc_q offset-correctly): `sb_override` fires on any taken as before, but a
  new `sb_ovr_soft` (FTB_OVERRIDE && sb_override && pt0_eff && wf_count>=2 &&
  wf_pc[wf_head+1][63:3]==tgt0_eff[63:3] — the clocked full target is prefetched at head+1, i.e. the
  FTB agreed) makes it SOFT: the WORD FIFO is NOT flushed (`sb_override && !sb_ovr_soft` gates the
  flush), instead the branch dword is popped (wf_head→the prefetched target entry), F0 is NOT
  re-steered (stays running ahead), and ext_pc_q = sb_override_target (==tgt0_eff, offset-correct) as
  before → the taken-path icache bubble is removed (only the Stage-A/B skid +1 remains). On
  DISAGREEMENT (target not prefetched at head+1) it stays HARD = today's flush + F0 re-steer +
  refetch. sb_disagree0 unchanged. DEAD at FTB_OVERRIDE=0: sb_ovr_soft const-false → hard everywhere,
  `if sb_ovr_soft{} else if ext_pop{}` folds to `if ext_pop{}`, `sb_override && !sb_ovr_soft` folds to
  `sb_override` → *.sv byte-identical to HEAD, veryl test 252/0. Edit sites: sb_ovr_soft def, FIFO
  flush+wf_head always_ff, F0 FSM sb_override arm (ext_pc_q re-steer needs NO change).
- **f2.4** ⏳ FLIPPED + MEASURED — 2 corners found, bisected, reverted to =0 (ship-safe). Flip = 9
  const (variant-A 8-set + FTB_OVERRIDE; PRED_L0_FAST stays 0). Builds, **no comb loop**. Results:
  - `veryl test` **251/1** — `test_litmus_2hart` TIMEOUT (tohost=0, cy=30M vs normal ~2.1M; both
    harts stuck ~0x800007b8). arch suite + all else pass.
  - **dhrystone SILENT CORRUPTION** — instret **213489 vs base 264834** (~51k insts skipped),
    tohost=1 MISLEADING (3a.4 lesson: instret bit-exactness, not tohost, is the correctness check).
  - **N1 boot HANG** — cy=45M timeout (x3=0x80a85b60), did not reach SBI shutdown.
  - **Bisection — `sb_ovr_soft` forced 0 (f2.3 soft-redirect OFF, keep f2.1 train + f2.2 follow +
    hard override)**: dhrystone **BIT-EXACT 264834**, cy 319915 (**+27%** = variant-A train+follow
    cost, no prefetch benefit since hard-flush wastes it) → **f2.3 = the dhrystone-corruption
    culprit**. BUT N1 boot **STILL hangs identically** (45M, same x3=0x80a85b60) → **the boot hang is
    f2.1/f2.2 (FTB train + FIFO-follow), NOT f2.3** — a boot-path-specific forward-progress failure
    that the tight dhrystone loop doesn't trigger.
  - **⇒ TWO independent bugs**: (1) f2.3 soft-redirect silently skips insts (hypothesis: the
    head+1 target assumption + wf_count/pop bookkeeping under the Stage-A/B skid — the timing corner
    flagged in the design analysis; boundary-vs-mid-dword branch changes whether the target sits at
    head or head+1). (2) f2.1/f2.2 boot hang (needs further bisect: f2.1's re-engaged
    ext_taken_redir/f0_diverged vs f2.2's follow advance; and ICACHE_FTB_COND on/off = the
    conditional-FTB double-bubble risk the design flagged). Next: trace root-cause both (cf. 3a.5
    commit-PC trace; boot needs c_instr + register-operand trace like 3a.5's udelay corner).
- **f2.4-fix** ✅ DONE — 3 leaks ROOT-CAUSED + FIXED (all DEAD-at-0, veryl test 252/0, dhrystone
  bit-exact cy 251423 / instret 264834). **Re-flip N1 boot now COMPLETES (17.6M, x3=0xaa pass=1)** with
  the divergence trap silent for the whole boot — corner 3 was the last leak. The fixes are committed at
  0 (behavior-inert, cf. the f1 skid additions); the flip (9-const set below) is validated but stays at
  0 for ship. Debug method that closed corner 3 = the **divergence trap** (fetch-stream invariant
  pred_next==next-committed-PC, mechanism-agnostic — catches wrong-PATH skips a wrong-bytes detector
  misses) + a windowed produce/commit/redirect trace; keep it in the reusable-harness kit.
  - **Corner 1 [FIXED — `a_eff_next`]** dhrystone silent corruption (was: 51k insts skipped, instret
    213489 vs 264834). Root: under FTB_OVERRIDE `ext_ftb_follow` (f2.2) advances extract NON-
    sequentially to the FTB target dword at OFFSET 0. When the clocked-full pred resolves the branch
    NOT-taken (pt0_eff=0, FTB-vs-full disagreement) `sb_override` does not fire, so extract is
    stranded at the offset-0 target — but the recorded pred_next (`sb_next0` not-taken arm) used the
    SEQUENTIAL fall-through (`a_pc + a_len0`), which equalled the branch's arch_next, MASKING
    `c_bp_mispredict` so the wrong-path offset-0 instr silently retired (the strcpy 0x9a→0x98 leak:
    `bnez` at 0xa6 delivered 0x98 `mv a5,a0` instead of 0x9a). **Fix:** capture the ACTUAL Stage-A
    advance `a_eff_next = ext_eff_next` at produce (the true delivered successor) and record IT on the
    not-taken arm: `sb_next0 = pt0_eff ? tgt0_eff : (a_push1 ? a_pc+a_len0 : a_eff_next)`, `sb_next1 =
    pt1_eff ? tgt1_eff : a_eff_next`. Now pred_next == delivered successor → the mispredict fires and
    flushes the leak. dhrystone **bit-exact 264834** (PC stream identical to base; cy 333910). Folds to
    ext_seq_next at FTB_OVERRIDE=0 → variant-A/HEAD unchanged.
  - **Corner 2 [FIXED — `ext_next_valid` !ext_bypass]** boot garbage-ra panic (`epc=ra=0xf00406c88…`,
    "Attempted to kill the idle task"). Root: an across-dword slot-1 (or straddle slot-0) reads the
    next word from `wf_data[head+1]`, but during an `ext_bypass` the slot-0 comes from the ARRIVING
    push, NOT `wf_data[head]` — head lags ext_pc_q (points at an OLDER FIFO entry), so `wf_data[head+1]`
    is NOT ext_pc_q's next dword and the `head1_seq` guard (head vs head+1) is irrelevant. The old code
    relied on `wf_count~0` during a bypass to fail `wf_count >= 2`, but under FTB_OVERRIDE the FTB-follow
    leaves stale older entries → a bypass fired with wf_count=2 → the slot-1 read a WRONG dword (boot:
    slot-1 at 0x80202e20 got `slli ra,ra,29` (0x01d09093) from the stale head+1 instead of `sub a5`,
    writing x1=garbage → a later `ret` jumped to it). **Fix:** `ext_next_valid`'s across-dword arm gets
    `&& (!FTB_OVERRIDE || !ext_bypass)` — the across-dword read only consumes head+1 when head IS
    ext_pc_q's dword; the slot-1/straddle just waits a cycle during a bypass. DEAD at FTB_OVERRIDE=0.
  - **Corner 3 [FIXED — `c_bp_mispredict` gated on `rob_commit_ack` for non-control ops]** boot init
    SIGSEGV / hang. Root-caused with a **divergence trap** (a temp `always_ff`: the fetch-stream
    invariant "instr A's recorded pred_next_pc == the PC of the NEXT committed instr B"; fires on the
    first violation, invalidated across any redirect, latched once) + a windowed produce/commit/redirect
    trace. The FIRST divergence was a SKIPPED store at 0x800abf4e: the sequence
    `jal ra→0x800abf4c` (cy 0x30d28) → `c.addi16sp` (0x800abf4c, lane B) → **`c.swsp x9,132(x2)`
    (0x800abf4e) NEVER COMMITS** → `c.sdsp` (0x800abf50). The `c.swsp` (a stack register-save store, the
    LAST RVC in dword 0x800abf48, offset 6) was fetched with `ext_ftb_follow` (f2.2) engaged: a
    stale/aliased FTB entry for dword 0x800abf48 pointed at 0x800ac2c0, so slot-1's pred_next was
    recorded as 0x800ac2c0 (the FTB target) not the sequential 0x800abf50. That IS a correctly-detected
    `c_bp_mispredict` (pred 0x800ac2c0 ≠ arch_next 0x800abf50) — **but the store was still draining**
    (`rob_commit_valid=1`, `rob_commit_ack=0`: sb_elig / store_fetched_q / dcache gating). The OLD
    `c_bp_mispredict = rob_commit_valid && (pred != arch)` fired the redirect on `rob_commit_valid`, so
    the redirect (to c_arch_next_pc = the store's fall-through 0x800abf50) FLUSHED the store *before it
    retired* and re-fetched from 0x800abf50 — permanently SKIPPING the store (s1 never saved → corrupted
    stack → the eventual init fault). **Fix:** `&& (c_is_control || rob_commit_ack)` — a NON-control
    mispredict waits for the op to actually retire (execute) before firing the redirect; control ops keep
    rob_commit_valid (exact baseline). Corner 1's op was a simple ALU op (retires immediately), so it
    never hit this; only STORES (and c_serial/c_flush_op) stall at the head long enough to be flushed
    pre-retire. **DEAD/byte-identical at =0** (a non-control op's pred_next == fall-through there, so the
    non-control mispredict is 0 regardless). Validated: re-flip N1 boot **completes 17.6M, DIVERGE trap
    silent for the whole boot** (corner 3 was the LAST leak); at =0 veryl test 252/0, dhrystone
    bit-exact cy 251423 / instret 264834.
  - **IPC note (partial):** at =1 (both fixes) dhrystone is 333910 cy = **+33% vs base, WORSE than
    variant-A's +26%** — the FTB-vs-clocked disagreement-recovery flush (every loop-exit / TAGE
    disagreement) costs more than the FTB prefetch saves on dhrystone's tiny strcpy/strcmp loops. Only
    dhrystone measured (f2.4's worst case: short loops); boot/coremark/longer-loop IPC unmeasured and
    may favour f2.4. IPC tuning (recover the disagreement flush at Stage-B instead of via early/commit
    redirect) is a post-correctness item.
  - **Debug harness (reusable, for corner 3+):**
    - **Divergence trap (THE tool that closed corner 3 — mechanism-agnostic, timing-noise-immune):**
      a temp `always_ff` that verifies the fetch-stream invariant **A.pred_next_pc == the PC of the NEXT
      committed instr B** (in correct operation the frontend steers the next fetch to exactly A's
      recorded pred_next, so a wrong-path/skip commit breaks this). Keep `dv_prev_pred`/`dv_prev_pc`/
      `dv_valid`/`dv_seen`/`dv_cy` regs: on `rob_commit_ack`, if `dv_valid && !dv_seen && c_pc !=
      dv_prev_pred` → `$display("DIVERGE-A ...")` + latch `dv_seen`; then set `dv_prev_pred =
      c_pred_next_pc` (lane A) or `c2_pc + (c2_is_rvc?2:4)` on `commit2_fire` (lane B, whose c2_valid
      guard already forces pred==fall). **Crucial:** invalidate `dv_valid=1'b0` on
      `redirect_fire || early_redir_fire_q || commit_redirect` OUTSIDE the `rob_commit_ack` block — an
      async interrupt/trap redirects on a NON-commit cycle, and missing that gives a false DIVERGE at the
      trap vector (got=trap-handler-PC). Soundness control: it must be SILENT on a variant-A (=0-ish)
      boot. It catches wrong-PATH skips a wrong-bytes detector misses; it does NOT catch pure wrong-VALUE
      (data) leaks. Needs the lane-B `o_commit2_is_rvc`/`o_commit2_instr` temp rob ports (below).
    - **Windowed produce/commit/redirect trace:** once the trap gives the divergence `dv_cy`, gate a
      second `always_ff` on `dv_cy in [lo,hi]` and dump per-cycle: fetch PRODUCE (`fb_push0`: ic_pc,
      ext_eff_next, ext_ftb_follow, ext_next_valid, ext_bypass, fb_push1, s1_pc, sb_override, ext_pc_q,
      wf_count), COMMIT (lanes A/B: pc, instr, pred_next, is_rvc), REDIRECT (any of redirect_fire/
      early_redir_fire_q/sb_override/ext_taken_redir/f0_diverged/commit_redirect: their PCs +
      c_bp_mispredict/c_arch_next_pc), and ROB ALLOC (`rename_fire` gated on `if_pc_q` in the region:
      if_pc_q, if_pred_next_pc_q, rename_fire2). This is what showed corner 3: the store was ALLOCATED
      (AL), reached the head with `c_bp_mispredict=1` but `rob_commit_ack=0` (draining), and the redirect
      flushed it pre-retire. dv_cy is deterministic across runs (the trap regs don't feed RTL).
    - **Commit trace:** in the perf-counter `always_ff` (`else` arm), `const TRACE_COMMIT: bit = 1;`
      then `if TRACE_COMMIT { if rob_commit_ack { $display("A %h %h", c_pc, c_instr); } if
      commit2_fire { $display("B %h %h", c2_pc, c2_instr); } }`. Lane B's instr needs a temp rob port:
      add `o_commit2_instr : output logic<32>` + `assign o_commit2_instr = sh_instr[head1_idx];` in
      rob.veryl, and a `var c2_instr` + `o_commit2_instr: c2_instr` on the core's rob instance. (Veryl
      $display in always_ff is fine; no `$finish`/relational `>`; the UART console double-chars but
      $display does not — dedouble a captured console line with `sed 's/\(.\)\1/\1/g'`.)
    - **Kernel disasm** (N1 boot loads `test/hex/linux_dram_real.hex` at PA 0x80000000; VA
      0xffffffff80xxxxxx → PA 0x80xxxxxx): hex line M (1-based) = the 32-bit word at PA 0x80000000 +
      4*(M-1), so M = (PA-0x80000000)/4 + 1. Extract a range, little-endian each word to bytes, and
      `riscv64-unknown-elf-objdump -b binary -m riscv:rv64 -M no-aliases -D` (add PA to the blob
      offsets; branch targets in the objdump text are blob-relative — add the blob base).
    - **First-novel-PC diff:** trace a variant-A boot (FTB_OVERRIDE=0, others 1) → `vA_pcset =
      sort -u of its A/B PCs`; trace the =1 boot; `awk 'NR==FNR{seen[$1];next} /^A |^B /{if(!($2 in
      seen)){print FNR": "$2; exit}}' vA_pcset fix1_boot` = first PC variant-A never runs (a wrong-path
      entry — but may be a downstream data-branch; the ROOT is upstream, trace the corrupted value back).
    - **Wrong-bytes detector (banked, found nothing for corner 3):** `grep '^A \|^B ' | awk '{print
      $2,$3}' | sort -u | awk '{c[$1]++} END{for(p in c)if(c[p]>1)print p}'` = PCs committed with >1
      distinct instr. Catches corner-2-style wrong-bytes; corner 3 is wrong-PATH/VALUE so this is empty.

  **Flip recipe (the 9-const F2-lite set; PRED_L0_FAST stays 0):**
  ```
  sed -i 's/const PRED_PIPE: bit = 0;/const PRED_PIPE: bit = 1;/'             src/core/heliodor_core.veryl
  sed -i 's/const PRED_OVERRIDE: bit = 0;/const PRED_OVERRIDE: bit = 1;/'     src/core/heliodor_core.veryl
  sed -i 's/const FTB_OVERRIDE: bit = 0;/const FTB_OVERRIDE: bit = 1;/'       src/core/heliodor_core.veryl
  sed -i 's/const PRED_HOLD_FREEZE: bit = 0;/const PRED_HOLD_FREEZE: bit = 1;/' src/core/heliodor_core.veryl
  sed -i 's/const IBTB_SYNC_READ: bit = 0;/const IBTB_SYNC_READ: bit = 1;/'   src/core/ibtb.veryl
  sed -i 's/const BHT_SYNC_READ: bit = 0;/const BHT_SYNC_READ: bit = 1;/'     src/core/bht.veryl
  sed -i 's/const BTB_SYNC_READ: bit = 0;/const BTB_SYNC_READ: bit = 1;/'     src/core/btb.veryl
  sed -i 's/const TAGE_SYNC_READ: bit = 0;/const TAGE_SYNC_READ: bit = 1;/'   src/core/tage.veryl
  sed -i 's/const PRED_OVERRIDE: bit = 0;/const PRED_OVERRIDE: bit = 1;/'     src/core/rob.veryl
  ```
  Revert with `git checkout -- src/core/{heliodor_core,ibtb,bht,btb,tage,rob}.veryl`. Bisect f2.3 by
  editing `let sb_ovr_soft ... = FTB_OVERRIDE &&` → `= 1'b0 && FTB_OVERRIDE &&` (isolates f2.3: with
  it forced 0, dhrystone was bit-exact but boot still hung ⇒ boot hang is f2.1/f2.2). Correctness
  check = dhrystone **instret == 264834** (NOT tohost — tohost=1 lies under this corruption). Baseline
  dhrystone at =0: cy 251423 / instret 264834. Known-good ref: 3a.6 variant-A (FTB_OVERRIDE=0) boots
  N1 at ~15.9M. Boot-hang signature: cy=45M timeout, x3=0x80a85b60. Litmus-hang: 30M, harts ~0x800007b8.
- **f2.5** (F2-full) Promote to a multi-block FTQ + independent `pc_pred` loop + run-ahead RAS.
  Detailed design + increment decomposition below ("## F2-full (f2.5) — detailed design").

### f2.2/f2.3 reconciliation design (the FIFO-follow) — analysis before scaffold

(Analogous to F1 order-item-3's `65fe514` design-analysis-before-scaffold. Pins the mechanism so
the f2.2/f2.3 DEAD scaffolds and the f2.4 flip have a written target.)

**The core tension (why this is the hard part).** Under PRED_OVERRIDE the authority is inverted:
Stage-A has NO offset-correct branch target (the clocked BTB/BHT/TAGE resolve at Stage-B). So when
F0 follows the FTB and jumps `pc_fetch_q` to `{ftb_target[63:3],3'b000}` (dword-aligned, offset
DROPPED), the WORD FIFO holds a non-sequential stream but Stage-A cannot itself compute where in
the target dword to resume — it only has the sequential advance (`ext_seq_next`). This is exactly
why variant (A) gated the F0 FTB off. F2-lite keeps the FTB as a *dword-granular prefetch hint*
and leaves the offset-correct redirect at Stage-B — "extract stays authoritative" (§24.4), now
meaning **the clocked full pred at Stage-B is the branch-point/offset authority; the FTB only
run-ahead-prefetches the target dword.**

**f2.2 — FIFO-follow advance (the substrate).** The one thing Stage-A CAN do without the target
offset: keep `ext_pc_q`'s DWORD consistent with the non-sequential FIFO. On a dword-crossing
advance, instead of `ext_seq_next` (which assumes the sequential successor `D0+8`), follow the
FIFO's next-entry PC `wf_pc[wf_head+1]` — the dword F0 actually fetched (FTB target dword, or the
sequential successor when F0 did not jump). Effect: `ext_head_match` (`wf_pc[wf_head] ==
ext_head_dw`) holds next cycle instead of failing → extract does not stall on the non-sequential
FIFO. The straddle/slot-1 across-dword read already self-guards on the non-sequential head+1 via
`head1_seq`/`ext_next_valid` (stalls the across-dword read when head+1 is a non-sequential FTB
target) — so f2.2 is primarily the `ext_eff_next` advance change; the head-match/straddle "track"
by construction once the advance follows the FIFO. The target's within-dword offset is NOT
recovered here (Stage-A has no offset) — extract resumes at offset 0 of the target dword; the
offset is corrected at Stage-B by `sb_override` (offset-correct clocked target). Folds to
`ext_seq_next` at FTB_OVERRIDE=0 (and whenever head+1 is sequential) → byte-identical.

**f2.3 — Stage-B override = FTB-vs-clocked-full disagreement + prefetch reuse.** Today `sb_override`
ALWAYS flushes the WORD FIFO and F0 refetches the target (full icache latency) — so the FTB
prefetch is wasted. f2.3 makes it reuse the prefetch: when the clocked full pred resolves the
branch and its offset-correct target's DWORD is already buffered in the FIFO (F0's FTB jump was
right — the common case), `sb_override` does a SOFT redirect (advance `wf_head` to the prefetched
target entry + set `ext_pc_q = sb_override_target` with the correct offset, NO flush) instead of a
hard flush+refetch → the taken-path icache-latency bubble is removed (only the Stage-A/B skid +1
remains). On DISAGREEMENT (FTB missed / mispredicted / different target — stale FTB vs evicted BTB,
or a strong-FTB-but-TAGE-not-taken cond) it falls back to today's hard flush+refetch. This is the
(B) b.3 disagreement-override pattern, now FTB-vs-clocked-full instead of L0-vs-full. DEAD at 0.

**Skid-composition corners (expect at f2.4 flip, debug then — cf. 3a.4→3a.6).** The FTB-followed
FIFO now composes with the 1-deep Stage-A/B skid + clocked predictors: (a) a mid-dword FTB branch
lets Stage-A cross D0 sequentially into the prefetched target a cycle before `sb_override` fires
(race between the FIFO-follow cross and the override) — the override still corrects offset+path, so
worst case is a 1-cycle wrong-dword fetch that is squashed; (b) `f0_diverged`'s straddle/head
corners re-engage under a non-sequential head+1 and must survive the skid; (c) the FTB `conf` gate
bounds how often a strong-FTB-but-TAGE-not-taken cond double-bubbles. All of these are correctness-
preserving (the clocked full pred + `c_bp_mispredict` at commit remain the backstop, as in 3a.6);
they cost IPC, not correctness, and are tuned at/after the flip.

**Guidance (plan §8.1 / this doc): F2 is a large, delicate multi-session restructure of the
most-tuned fetch logic (WORD FIFO / FTB / straddle / skid) — best begun in a clean, focused
context.** The banked L0 (b.1–b.3) is not the F2 producer after all (it is per-PC, extract-side;
the FTB is the per-dword run-ahead producer) — but the (B) disagreement-override + l0_redir
flush *patterns* transfer directly to f2.3/f2.1, and the L0 stays available as an extract-side
secondary fast path if wanted.

## F2-full (f2.5) — detailed design (2026-07-26, audited against the RTL)

Written after auditing the F2-lite datapath (F0 FSM `heliodor_core.veryl:1803-1904`, WORD FIFO
`:1907-1952`, extract Stage-A/B `:1668-1984`) for how F2-full lands. F2-lite (f2.4-fix, the 9-const
set) is correct end-to-end at =1 (boots 17.6M, dhrystone bit-exact) and shipped at 0.

### The clean-decoupling insight — extract is UNTOUCHED; f2.5 is entirely upstream of F0

In F2-lite `pc_fetch_q` serves DOUBLE duty: (1) the icache read address (F0 demand fetch), and
(2) the FTB read address whose hit steers the NEXT `pc_fetch_q` (the predictor loop). They advance
in LOCKSTEP — `pc_fetch_q` moves only on `f0_present` (icache read succeeds + WORD-FIFO room), so a
miss / full FIFO stalls the predictor loop too. There is exactly ONE queue (the WORD FIFO) between
fetch and extract.

**F2-full splits these two duties into two independent pointers with a queue (the FTQ) between:**
```
 pc_pred ─▶ FTB read ─▶ {enqueue FTQ: dword_pc (+ later: taken/target/kind for run-ahead RAS)}
        └────────────────────────────────▶ next pc_pred (1 block/cyc, independent of F0)
                                     │
                                     ▼  FTQ  (NEW queue, addresses only)
                                     │
 pc_fetch_q = FTQ.head ─▶ icache read ─(T+1)─▶ dword ─▶ WORD FIFO ─▶ extract  (UNCHANGED)
```

**The crux (audited): the WORD-FIFO stream `wf_pc[*]` is IDENTICAL under F2-full.** `pc_pred`
computes exactly the same dword sequence the F2-lite `pc_fetch_q` FTB loop did (same FTB reads,
same `f0_ftb_hit`/`f0_no_ftb_q` steer, same redirect re-seeds), enqueues it, and F0 fetches those
dwords IN ORDER — so the WORD FIFO fills with the same non-sequential stream. Therefore the entire
delicate extract side — `ext_ftb_follow` (f2.2), `f0_prefetched_target`/`ext_taken_redir`,
`sb_override`/`sb_ovr_soft` (f2.3), the straddle/`head1_seq`/`ext_next_valid` corners, and the
f2.4-fix `a_eff_next`/`ext_next_valid !ext_bypass`/`c_bp_mispredict rob_commit_ack` fixes — all read
the WORD FIFO (`wf_*`) or the F0 fetch pointer `pc_fetch_q`, NOT the new `pc_pred`, and stay
STRUCTURALLY UNCHANGED. (Verified: `f0_diverged` `:1750` is the only extract-recovery term that
references `pc_fetch_q` directly — and it references the F0 FETCH pointer, which F2-full KEEPS as
`pc_fetch_q`; the run-ahead pointer is the NEW `pc_pred`.) f2.5 is a pure F0-front restructure.

### Honest IPC assessment — structural, marginal IPC on the CURRENT memory system

The plan's mandate is structural completeness, not IPC (Phase-14; §CP: F1 CP = 0). F2-full is the
textbook decoupled front end (Reinman/Calder: predictor→FTQ→fetch) and completing it is the Phase-14
front-end endpoint. But be honest about the IPC it buys on heliodor AS SHIPPED:
- The WORD FIFO already gives F2-lite up to WF_N=8 dwords of predictor run-ahead (F0 follows FTB
  targets 8 dwords ahead of extract before `wf_full` stalls it). The FTQ adds MORE run-ahead
  (`pc_pred` leads F0 by FTQ-depth blocks), but extract still drains at its own rate — deeper
  run-ahead does not make extract faster BY ITSELF.
- The two mechanisms that WOULD convert run-ahead into IPC both need memory-system support heliodor
  currently lacks: (a) **FTQ-driven prefetch** — issue icache reads for FTQ-queued blocks ahead of
  demand — is exactly the next-line prefetch **P9.6 turned OFF** (it holds the single shared per-hart
  mem_ctrl port, starving the D-cache; `icache.veryl:73`). (b) **hit-under-miss at F0** — F0 issuing
  the next FTQ block's read while a prior miss fills — needs F0 to sustain multiple outstanding reads
  (it stalls on `!icache_stall_comb` today, one at a time). Neither is in f2.5's scope.
- So on the current single-outstanding, prefetch-off memory system, F2-full is **IPC-≈-neutral vs
  F2-lite** (a structural-fidelity change), and it is the SUBSTRATE that makes FTQ-driven prefetch /
  hit-under-miss a localized follow-up once the P9.6 port contention is addressed. This mirrors the
  L0 "marginal, banked" finding — build the structure, measure, document, don't over-claim IPC.

**Recommendation:** build f2.5a–f2.5c (the decoupled FTQ substrate — `pc_pred` loop + FTQ + F0
dequeue, returns still overriding at extract as in F2-lite) as the structural completion, measure to
confirm IPC-neutral, and treat f2.5d (run-ahead RAS) + FTQ-driven prefetch as value-add increments
gated on whether the measured structure motivates them. Surface the IPC assessment to the user after
the substrate lands so they choose whether to push run-ahead RAS + prefetch.

### FTQ / pc_pred consistency invariant (the correctness backbone)

**Whenever the WORD FIFO is flushed OR `pc_fetch_q` is re-steered, the FTQ is flushed and `pc_pred`
is re-seeded to the SAME target** — so `pc_pred`/FTQ never lead F0 down a path F0's own pointer was
redirected off. Concretely, mirror the F0 `pc_fetch_q` FSM arms (`:1824-1881`) and the WORD-FIFO
flush (`:1922`) onto `pc_pred`/FTQ:
- `redirect_fire` / `early_redir_fire_q` (arch / early redirect): flush FTQ, `pc_pred` = the redirect
  target dword (+ carry `f0_no_ftb_q`'s mid-dword-reentry guard onto the pc_pred FTB read).
- `sb_override && !sb_ovr_soft` (HARD extract override — FTB-vs-full disagreement): flush FTQ,
  `pc_pred` = `sb_override_target` dword.
- `ext_taken_redir` / `f0_diverged` (FTB reconciliation redirects, re-engaged under FTB_OVERRIDE):
  flush FTQ, `pc_pred` = the re-steer target (`ext_next_pc` / `ext_pc_q` dword) — same as F2-lite
  re-steers `pc_fetch_q`.
- `sb_ovr_soft` (SOFT — FTB agreed, WORD FIFO NOT flushed, F0 keeps running): FTQ NOT flushed,
  `pc_pred` keeps running. (Consistent — the FTB stream was right.)
- Steady state (no redirect): `pc_pred` advances via its own FTB read (`pc_pred_ftb_hit ? target :
  pc_pred+8`) whenever the FTQ has room; F0 dequeues the FTQ head on `f0_present`.

The correctness net is UNCHANGED: `pc_pred`/FTQ are pure speculation feeding F0; the WORD-FIFO
stream, the Stage-B clocked-full override, and commit `c_bp_mispredict` (+ the 3a.5 rob lane-B guard)
remain authoritative. f2.5 is an accuracy/structure change, not a correctness change — it rides on
the f2.4-fix corners.

### Increment decomposition (DEAD-scaffold, each =0 byte-identical, flip last) — the 10th const

New `const FTQ_DECOUPLE: bit = 0;` (requires the F2-lite 9-const set; PRED_L0_FAST stays 0).

- **f2.5a** ✅ DONE (`a70afa1`). FTQ storage substrate (`pc_pred`/`pp_no_ftb_q`/`ftq_pc[FTQ_N]`/
  `ftq_head`/`ftq_tail`/`ftq_count`, FTQ_N=8) + the `pc_pred` FTB PRODUCER (`pp_ftb_hit`/`pp_next` =
  the `f0_ftb_hit` logic on `pc_pred`) + FTQ enqueue + the redirect re-seed/flush invariant. NO F0
  consumer yet (f2.5b). Written ONLY under `else if FTQ_DECOUPLE`; `pp_ftb_hit` carries `FTQ_DECOUPLE
  &&`. `veryl check` no new warnings; `veryl test` 252/0.
  - **DEAD-proof caveat (learned here — correct the "byte-identical" shorthand):** Veryl 0.20.2 does
    NOT const-fold `else if CONST_FALSE` / reset-only flops at the SV-TEXT level — the generated
    heliodor_core.sv literally contains the (dead) localparam=0, the flop decls, the always_comb, and
    the `else if (FTQ_DECOUPLE)` always_ff. The correct DEAD criterion is **the existing SV is
    preserved VERBATIM and the additions are inert**: the SV diff vs HEAD is PURE ADDITIONS (all `a`
    hunks, zero `c`/`d` — no existing line changed/removed), and every addition is const-gated
    (`FTQ_DECOUPLE`=0 → the always_ff non-reset branch never runs, pc_pred/ftq hold reset, pp_ftb_hit
    const-false, all unread) → synth-DCE + sim-inert → behavior provably identical (existing netlist
    untouched + additions unread ⟹ cannot perturb any existing signal). This is STRONGER than a
    cycle-count check. (Prior "byte-identical" claims for register-adding scaffolds — PRED_PIPE,
    PRED_HOLD_FREEZE — meant this behavioral sense; only EXPRESSION-level folds like f2.1's `||0` are
    literally byte-identical SV. `.sv` is gitignored, so verify via build+diff, not `git diff`.)
- **f2.5b** ✅ DONE (`7df1264`). Wired the F0 CONSUMER (the enqueue+pc_pred loop landed in
  f2.5a). **Scheme b1** (audited as the cleanly-correct variant): F0 fetches EXCLUSIVELY from the FTQ
  (no direct re-seed fetch), so the redirect target is not duplicated. Mechanics under FTQ_DECOUPLE:
  - `f0_fetch_pc = FTQ_DECOUPLE ? (ftq_count>=1 ? ftq_pc[ftq_head] : pc_pred) : pc_fetch_q` — F0's
    actual fetch address is the FTQ head; on a momentarily-empty FTQ (the redirect-refill cycle) it
    falls back to `pc_pred` (a valid address) so the always-on MMU translate (`i_req=!any_redirect`)
    never walks a garbage slot, and `f0_present` is gated off then anyway. Routed to the 3 real uses of
    "the presented fetch address": `fetch_vaddr` (→imem_mmu), `wf_push_pc_q` (the pushed dword's PC),
    and `f0_diverged`'s pointer compare. Folds to `pc_fetch_q` at 0.
  - `f0_present` gains `&& (!FTQ_DECOUPLE || ftq_count>=1)` — F0 presents only when the FTQ has an
    entry (else it waits for `pc_pred` to refill = the +1 redirect bubble, a known decoupled-front-end
    cost, to be measured/mitigated at f2.5c/with a bypass).
  - dequeue `f0_ftq_pop = FTQ_DECOUPLE && f0_present && f0_beat_done` (once per dword, non-cacheable
    2-beat pops on beat-1); the producer always_ff's steady-state arm now does DEQUEUE (`ftq_head++`)
    + ENQUEUE (`ftq_pc[ftq_tail]=pc_pred`, `pc_pred=pp_next`) independently, `count += enq - deq`.
  - **The coupled loop DCEs at the flip:** at FTQ_DECOUPLE=1, `pc_fetch_q` + its arms + `f0_ftb_hit`
    (F0's FTB read port) become UNREAD (all fetch-address uses route to `f0_fetch_pc`=ftq head) → the
    whole F2-lite coupled machinery DCEs, leaving only `pc_pred`'s FTB read (1 port, the final
    structure). At FTQ_DECOUPLE=0 the reverse: `f0_fetch_pc≡pc_fetch_q`, everything else FTQ-gated →
    the coupled loop is authoritative, `pc_pred`/FTQ DCE.
  - **DEAD-at-0 proof (behavioral, not pure-addition — f2.5b MODIFIES existing exprs to route through
    `f0_fetch_pc`):** `f0_fetch_pc` folds to `pc_fetch_q` at 0 (ternary else) and every other addition
    is FTQ_DECOUPLE-gated → provably identical by construction. Verified: `veryl test` **252/0**, litmus
    N2 **cy=0x282170 = cycle-exact to f2.5a/HEAD**; no new analyzer warnings (ftq_pc reset in if_reset
    silences the const-gated-read "unassigned" flag). **Note the run-ahead already works** — `pc_pred`
    fills the FTQ up to FTQ_N while F0 drains, so f2.5b already IS the decoupled structure; f2.5c is
    just the flip + measurement (no separate "decouple depth" step needed).
    - **Gotcha logged:** Veryl `for` loops take NO type annotation — `for i in 0..N {` (not
      `for i: u32 in 0..N`, a SyntaxError that a warm `.build` cache HIDES until `rm -rf .build`).
- **f2.5c** ✅ FLIPPED + MEASURED (=0 reverted, ship-safe). Flipped the 10-const set (F2-lite 9 +
  FTQ_DECOUPLE). **Builds, NO comb loop.**
  - **CORRECTNESS — FULLY HEALTHY on the FIRST flip, ZERO corners** (contrast f2.4's 3 corners):
    dhrystone **instret 264834 = base (BIT-EXACT)**; `veryl test` **252/0** (arch rv64ui/um/ua/mi/si/
    uf/ud + litmus N2 all pass — better than f2.4's 251/1 litmus-timeout); **N1 Linux boot COMPLETES
    cy 0x139df90 ≈ 20.6M, x3=0xaa, pass=1.** This validates the clean-decoupling design: because f2.5
    is purely UPSTREAM of extract (the WORD-FIFO stream is provably identical), it inherits the
    f2.4-fix correctness wholesale and introduces NO new corner. The predicted skid/straddle/
    `f0_diverged`-under-FTQ corners did NOT materialize — the FTQ is transparent to extract.
  - **IPC — NEGATIVE (the +1 redirect bubble, as the honest assessment predicted):**
    | bench     | base (=0)       | F2-lite (f2.4-fix) | F2-full (f2.5c)        |
    |-----------|-----------------|--------------------|------------------------|
    | dhrystone | 251423          | 333910 (+33%)      | 378650 (+50.6%)        |
    | boot N1   | 14.2M           | 17.6M (+24%)       | 20.6M (+45%)           |
    | litmus N2 | 2.63M(0x282170) | —                  | 3.52M (0x35b600, +34%) |
    Each redirect (taken branch not FTB-prefetched, every mispredict) now costs +1 (the FTQ-refill
    bubble: after a flush, F0 waits one cycle for `pc_pred` to re-enqueue the target before it can
    dequeue). On the current single-outstanding / prefetch-OFF (P9.6) memory system there is NO
    offsetting run-ahead-prefetch gain, so the decoupling is a **net IPC LOSS vs F2-lite** (~+17% boot,
    +13% dhrystone). Exactly the "structural completion, not IPC win" outcome the assessment named.
  - **⇒ F2-full is STRUCTURALLY COMPLETE + CORRECT end-to-end, shipped DEAD at 0.** The decoupled
    predictor→FTQ→fetch front end (Reinman/Calder) now exists and boots Linux correctly at =1. The
    IPC is negative until the redirect bubble is mitigated AND the run-ahead is converted to IPC:
    - **redirect-bubble mitigation (memory-system-INDEPENDENT, the cheapest win):** a bypass — F0
      fetches `pc_pred` directly on the empty-FTQ refill cycle — removes the +1 bubble. → **f2.5c.1
      below (DONE, recovers F2-lite PARITY).**
    - **IPC payoff (memory-system-DEPENDENT):** f2.5d run-ahead RAS + f2.5e FTQ-driven prefetch /
      hit-under-miss, gated on the P9.6 mem-port contention being addressed.
- **f2.5c.1** ✅ DONE (`132d470`). Redirect-bubble BYPASS — recovers F2-lite parity while keeping the
  decoupled FTQ. **Mechanism:** F0 fetches `pc_pred` DIRECTLY when the FTQ is empty (the `f0_fetch_pc`
  fallback is already `pc_pred`); the empty-FTQ `f0_present` gate is removed so F0 presents then. To
  avoid duplicating that dword, the producer treats an empty-FTQ present as a BYPASS (`f0_ftq_byp =
  f0_present && ftq_count==0`): it does NOT enqueue `pc_pred` (F0 took it directly) and advances
  `pc_pred` on beat-done; the FTQ only ENQUEUES when F0 did not bypass (i.e. when F0 is stalled or
  behind). **Net effect:** in sync (FTQ empty) F0 tracks `pc_pred` with 0 bubble = F2-lite coupled
  behavior; the FTQ buffers ONLY when F0 falls behind `pc_pred` (miss / `wf_full`) — the true
  decoupling, retained. Dequeue (`f0_ftq_pop`) now requires `ftq_count>=1` (a real entry, not a
  bypass). DEAD at 0 (all under `else if FTQ_DECOUPLE` / gated; the `f0_present` gate was already a
  fold-to-1 at 0). **Verified — flip measured (=0 reverted):** correct (dhrystone instret 264834
  BIT-EXACT, `veryl test` 252/0, **N1 boot 0x10c66f0 ≈ 17.6M = F2-lite parity, x3=0xaa**), IPC:
  | bench     | base   | F2-lite | f2.5c (no byp) | **f2.5c.1 (byp)** |
  |-----------|--------|---------|----------------|-------------------|
  | dhrystone | 251423 | 333910  | 378650         | **334165 (≈parity)** |
  | boot N1   | 14.2M  | 17.6M   | 20.6M          | **17.6M (parity)** |
  | litmus N2 | 2.63M  | —       | 3.52M          | **3.07M**         |
  So **F2-full = the decoupled predictor→FTQ→fetch front end AT F2-lite IPC** — a no-regression
  structural upgrade, with the FTQ run-ahead retained as the substrate for f2.5d/e. Shipped DEAD at 0.
- **f2.5d** (value-add, gated on f2.5c's measurement) Run-ahead RAS: extend the FTB (or a companion)
  to mark block-terminating returns + carry is_call, add a `pc_pred`-side run-ahead RAS pushed/popped
  as `pc_pred` predicts, so `pc_pred` predicts return targets AHEAD (removing the return override
  bubble that survives f2.5c). Enqueue the RAS action in the FTQ; repair the run-ahead RAS from the
  committed RAS on a mispredict. The hardest, most speculative part — its own increment, deferred.
  **Built 2026-07-31 as f2.5d.1–d.3 (below); the 11th const is `PRED_RAS_AHEAD`.** No FTQ-carried RAS
  action was needed — the run-ahead stack is resynced wholesale from the speculative stack on every
  `pc_pred` re-seed (the f2.5a invariant already flushes the FTQ there), which is simpler and strictly
  more accurate than replaying queued actions.

### f2.5d — run-ahead RAS: audit findings + increments (2026-07-31)

**Audit finding (a real bug in f2.1, fixed in d.1): the FTB train was ALIASED BY ONE BUNDLE under
`PRED_OVERRIDE`.** f2.1 re-enabled `ftb_br_deliver` but left it keyed on the STAGE-A produce
(`fb_push0`) and indexed by the Stage-A PC (`ic_pc`) — while `btb_hit` / `btb_is_*` / `pred_target`
on that cycle are the CLOCKED read of `ic_pc(T-1)`. So every trained entry recorded
`dword(ic_pc(T)) → target-of-the-branch-at-ic_pc(T-1)`. This is the "stale/aliased FTB entry"
the f2.4-fix corner-3 trace saw (`0x800abf48 → 0x800ac2c0`) and it plausibly explains a chunk of
F2-lite's IPC deficit (a garbage FTB steers F0 wrong → the disagreement-flush path fires constantly).
It is accuracy-only — Stage-B + commit are authoritative — which is why the ladder still passed.
The run-ahead RAS CANNOT be built on it (an aliased `is_call` pushes a stray return address), so
re-timing the train is the prerequisite increment.

- **f2.5d.1** ✅ DONE. (i) Extend `PRED_HOLD_FREEZE` to the RAW btb bundle — `held_{hit,cond,call,
  ret,ind}0` + `held_{hit,call,ret}1`, with `*_eff` accessors — which is exactly 3a.6's documented
  "accuracy-only remainder" (the kind bits still re-read live under a skid hold). (ii) Re-time the
  FTB train to Stage-B: `ftb_tr_{fire,pc,rvc,hit,cond,ret,ind,dir,tgt}` = `PRED_OVERRIDE ? Stage-B :
  Stage-A` (`deliver0` / `a_pc` / `a_is_rvc0` / the frozen prediction; `pt0_eff` stands in for
  `cond_taken0`, equal in the arm that reads it). (iii) The speculative RAS push/pop
  (`s0/s1_ras_push/pop`) now read the frozen kind bits too. **DEAD at 0** — every term is a
  `CONST ? new : old` ternary with the const 0, plus reset-only regs. Verified `veryl test` **252/0**
  AND **cycle-exact** (litmus N2 `cy=0x2e6300`, identical to HEAD).
- **f2.5d.2** ✅ DONE. FTB gains `is_call` / `is_ret` / `ret_addr` (`ftb_ret_addr` = the call's
  fall-through PC). The unconditional arm records `is_call`+`ret_addr`; the conditional arm clears
  both (re-tagging); and a NEW arm `ftb_ret_deliver` trains RETURN entries — which the base FTB
  excludes precisely because a stored return target is caller-dependent, but which become useful once
  a stack supplies the target. `is_call`/`is_ret` are reset + written only under `PRED_RAS_AHEAD`
  (reset-only at 0 → DCE); `ret_addr` is written ungated (masked by `is_call`) so the analyzer does
  not flag it unassigned — exactly the `ftb_tag`/`ftb_target` policy.
- **f2.5d.3** ✅ DONE. `ras.veryl` gains a THIRD stack (`pred_stack`/`pred_tos`) behind a new
  `param PRED_AHEAD` **flip-coupled through the instantiation** (`PRED_AHEAD: PRED_RAS_AHEAD`) — no
  duplicated const to desync, unlike `rob::PRED_OVERRIDE`. It restores from `arch_stack` on
  `i_recovery_fire` and from `spec_stack` on `i_pred_resync` (every `pc_pred` re-seed), and otherwise
  pushes/pops as the predictor loop follows call/return entries. Core side: `pp_ftb_is_call/is_ret`,
  `pp_ftb_hit` additionally requires `ras_pred_valid` on a return entry (an empty stack = a miss →
  sequential, today's behavior), and `pp_next` takes `{ras_pred_top[63:3],3'b000}` for a return. The
  producer's control terms (`pp_reseed`/`ftq_enq`/`pp_advance`) are hoisted to module level so the
  RAS instance can be driven by them (the steady-state arm reads the hoisted `ftq_enq`, identical
  there by construction). **Nothing on the extract side changes**: f2.3's `sb_ovr_soft` already turns
  a Stage-B override into a soft pop whenever the target dword sits at `wf_head+1`, so a prefetched
  return target converts automatically.
  - **Known accuracy limit (documented, not fixed):** an INDIRECT call (`jalr ra,rs` → `btb_is_ind`)
    is excluded from the FTB (today's policy), so the run-ahead stack does not push for it while the
    speculative stack does — the two drift until the next resync. Direct `jal` calls dominate; if the
    measurement shows returns still overriding, admitting is_ind call entries is the next knob.
- **f2.5d.1b** ✅ DONE (found while auditing d.1, same root cause, kept because it measures POSITIVE).
  `ext_taken_redir`'s `ext_deliver_taken` term is `(fb_push0 && predicted_taken) || …` — a STAGE-A
  produce ANDed with the CLOCKED (one-cycle-stale) prediction. Under the authority inversion Stage-A
  never takes a branch, so that term is meaningless there, yet it fired a full WORD-FIFO flush + an F0
  re-steer to a stale target on essentially every produce after a taken branch — destroying exactly
  the FTB prefetch f2.1/f2.3 exist to create. Gated `!PRED_OVERRIDE`, and `ext_buf_mismatch` now
  compares against the advance Stage-A ACTUALLY took (`ext_eff_next`) instead of the stale
  `ext_next_pc`. Measured at the flip: `ext_taken_redir` fires **0** times (was the dominant flush),
  dhrystone 338665→337169, **N1 boot 16.85M→16.69M (−0.95 %)**. DEAD at PRED_OVERRIDE=0.
- **f2.5d.4** ⏳ FLIPPED + MEASURED — **CORRECT but IPC-NEGATIVE; shipped DEAD at 0 (banked)**, the
  same outcome as option (B)'s L0. Flip = the F2-full 10-const set + `PRED_RAS_AHEAD`
  (`ras::PRED_AHEAD` auto-couples). Builds, no comb loop.
  - **Correctness: clean.** `veryl test` 252/0; dhrystone **instret 264834 = BIT-EXACT** at every
    configuration measured; **N1 Linux boot COMPLETES** (`cy=0x102a2f0` ≈ 16.95M, x3=0xaa, pass=1).
    Like f2.5c, f2.5d introduced ZERO new correctness corners — it is purely upstream of extract.
  - **IPC (this tree; baselines re-measured because S1 + Block R shipped since f2.5c.1):**

    | config | dhrystone | Δ vs =0 | N1 boot | Δ vs =0 |
    |---|---|---|---|---|
    | =0 (ship) | 252939 | — | 14.27M (0xd9be30) | — |
    | 10-const F2-full (d.1 train fix, no d.1b) | 338665 | +33.9 % | 16.85M | +18.1 % |
    | 10-const + d.1b | 337169 | +33.3 % | 16.69M | +17.0 % |
    | **11-const (+run-ahead RAS) + d.1b** | **368644** | **+45.7 %** | **16.95M** | **+18.8 %** |
    | 11-const, ret entries TRAINED but never FOLLOWED | 338665 | +33.9 % | — | — |

    So the run-ahead RAS costs **+9.3 % on dhrystone and +1.6 % on boot** relative to the same tree
    without it. Not a measurement artifact: instret is bit-exact and `earlymis` is IDENTICAL (1753)
    in both configurations, so architectural prediction quality is unchanged — the loss is entirely
    front-end. `frontidl` 87378 → 116369 (**+28991**) accounts for the whole +31475-cycle delta.
  - **ROOT CAUSE — the FTQ never actually runs ahead, so there is nothing for the run-ahead RAS to
    exploit.** Per-event instrumentation over dhrystone (temporary `$display` counters, removed):

    | event | RAS-ahead OFF | RAS-ahead ON |
    |---|---|---|
    | F0 BYPASS (FTQ empty → F0 fetches `pc_pred` directly) | 331853 / 337169 cy (**98.4 %**) | 358365 |
    | `ftq_enq` (a block actually buffered) | 4796 | 7781 |
    | `f0_diverged` | 11744 | **35211** (arm A 27725 / arm B 7486) |
    | `sb_override` HARD | 44796 | 42813 |
    | `sb_ovr_soft` (prefetch reused) | 3982 | 5474 |
    | `ext_taken_redir` | 0 (d.1b) | 0 |
    | `pp_reseed` (FTQ flush) | 57003 | 68002 |
    | run-ahead RAS push / pop | 0 / 0 | 10969 / 32495 |

    **f2.5c.1's bypass — added to remove the +1 redirect bubble — locks `pc_pred` to F0's rate
    whenever the FTQ is empty, and on an all-hitting icache with ~57k front-end flushes the FTQ is
    empty 98 % of the time.** The decoupling is therefore latent: correct and structurally present,
    but with ZERO effective run-ahead depth. The return prediction's only realised effect is to make
    F0's stream NON-SEQUENTIAL at return sites; f2.2's FIFO-follow can only track that when
    `wf_count >= 2`, which a zero-depth queue often fails, so extract advances sequentially into a
    dword F0 never fetched → `f0_diverged` arm A → full flush. That triples `f0_diverged` and IS the
    +29k front-end idle.
  - **Two clean sub-findings.** (i) The run-ahead STACK is not at fault: substituting `ras_spec_top`
    for `ras_pred_top` gives the byte-identical cycle count (368644 both ways). (ii) FTB pollution by
    return entries is FREE: training them but never following them reproduces the RAS-off count
    **exactly** (338665), so the 64-entry FTB has room for them.
  - **Also measured, for f2.5e:** soft overrides are only **8–13 %** of all Stage-B overrides
    (3982/44796 → 5474/42813). The FTB prefetch is RARELY reused — that, not the return bubble, is
    F2-lite's dominant IPC deficit, and it is the correct next target.

### f2.3b — widening the soft override: TRIED AND REJECTED (2026-07-31)

Direct follow-up on that last measurement, recorded because the negative result pins the mechanism.

**Why the soft rate is low.** `sb_ovr_soft` tests `wf_pc[wf_head+1] == tgt0_eff`. But the f2.2
FIFO-follow advance often crosses INTO the prefetched target dword BEFORE the Stage-B override fires
— the "mid-dword FTB branch vs override race" the f2.2/f2.3 design analysis already flagged. After
that cross the target sits at `wf_head`, not `wf_head+1`, the test fails, and the override HARD
-flushes the very dword the FTB prefetched for it. So the prefetch is discarded exactly in the case
where it succeeded.

**The obvious fix does not work.** Adding a second soft flavor for "target already at `wf_head`",
with no pop (the branch dword was consumed by the earlier cross), is faster on dhrystone
(337169 → 332665) and keeps instret bit-exact — but it **HANGS the N1 boot** (45M timeout,
`x3=0x80a85b60`, the f2.4 boot-hang signature). Guarding it with `ext_head_match && !ext_bypass`
(the stale-entry shape of f2.4-fix corner 2) removes the spurious firings — `mispred` drops from 124
back to 1 — but the boot **hangs identically**, and the remaining gain collapses to −0.15 %.

**Neither hardening rescues it, and both erase the speedup.** Two hypotheses were implemented and
measured:

| variant | dhrystone | N1 boot |
|---|---|---|
| baseline (head+1 only) | 337169 | 16.69M ✅ |
| f2.3b head case, unguarded | 332665 (−1.34 %) | **HANG** 45M |
| f2.3b + `ext_head_match && !ext_bypass` (stale-head guard) | 336671 (−0.15 %) | **HANG** 45M |
| f2.3c + registered "last pop WAS an FTB-follow cross" | 336671 (−0.15 %) | **HANG** 45M |

f2.3c's gate was meant to supply the forward-progress guarantee the head flavor lacks — it proves a
dword WAS consumed on this branch's behalf the previous cycle, so the cycle *pair* consumes exactly
one dword. It changes dhrystone not at all and the boot hangs identically, so **the boot-fatal
interaction is neither staleness nor forward progress.** Equally important, both safe variants give
back almost the whole speedup: the −1.34 % came from the UNSAFE firings, and the real, safely
reachable upside is **−0.15 %**. Not worth root-causing at that price. Reverted; the analysis is left
as a comment at `sb_ovr_soft`.

**⇒ If the soft rate is revisited, attack the CAUSE, not the test:** hold the Stage-A FIFO-follow
cross while a drained bundle's override is still pending, so the target stays at `head+1` and the
existing pop-guaranteed soft path applies unchanged. Also note the reframing this measurement forces
— the 8–13 % soft rate is a big number, but the fraction these variants could safely convert bought
only 0.15 %, so "raise the soft rate" is not automatically where F2-lite's IPC is hiding.

## F2's IPC premise is REFUTED by measurement (2026-08-01) — variant-A beats F2-lite/F2-full

The f2.3b/c dead end prompted a direct test of the plan's central IPC claim (§"The key realization":
*"Variant-A's +48 % is mostly the cost of GATING THE FTB OFF … re-enable the FTB as the run-ahead F0
driver … recovers the bulk of the +48 %"*). It does not. Re-measured end-to-end in the current tree:

| config (current tree) | dhrystone | Δ vs =0 | N1 boot | Δ vs =0 |
|---|---|---|---|---|
| **=0 (shipped)** | 252939 | — | 14.27M | — |
| **variant-A** (clocked predictors, Stage-B override, F0 purely SEQUENTIAL) | **318202** | **+25.8 %** | **16.03M** | **+12.3 %** |
| F2-full (FTB-driven F0 + FTQ, incl. d.1 + d.1b) | 337169 | +33.3 % | 16.69M | +17.0 % |
| F2-full + run-ahead RAS (f2.5d) | 368644 | +45.7 % | 16.95M | +18.8 % |

**Variant-A — the variant that keeps the FTB OFF — is the best of the three inversion configurations
on BOTH workloads** (dhrystone −5.6 %, boot −4.1 % vs F2-full). The FTB-driven F0 does not recover
variant-A's cost; it ADDS to it. (f2.4's note already saw this on dhrystone — "+33 %, WORSE than
variant-A's +26 %" — but it was attributed to dhrystone's short loops and left for boot to redeem.
Boot does not redeem it.)

**An FTB size sweep makes the mechanism unambiguous — and the sign FLIPS with authority:**

| FTB entries | dhrystone @ F2-full | dhrystone @ =0 |
|---|---|---|
| 16 | **329192** | — |
| 64 (shipped) | 337169 | 252939 |
| 256 | 340655 | **251943** |

Under the inversion, *fewer* FTB entries is monotonically *better*; at =0, *more* is better. So the
FTB is a good prefetch hint **while extract is authoritative**, and a net liability **when it drives
F0 under the inversion**: each additional FTB-followed jump costs more in reconciliation (the
`f0_diverged` recovery flushes plus the hard override whenever the clocked full predictor disagrees)
than its prefetch saves. That is a property of the FTB-follow mechanism itself, not of coverage,
tuning, or the run-ahead depth — which also explains why f2.5d, f2.3b and f2.3c all failed to move it.

**Consequences.**
- **F2 (f2.1–f2.5) stands as a STRUCTURAL result, not an IPC one**: a real decoupled
  predictor→FTQ→fetch front end exists, is correct end-to-end, and boots Linux. Its IPC is worse than
  the simpler variant-A. Shipping any of this LIVE is a Phase-14 decision for the user; if it ever
  ships, **variant-A (8 consts, `FTB_OVERRIDE=FTQ_DECOUPLE=0`) is the configuration to ship**, not
  F2-lite/F2-full.
- **Enlarging the shipped FTB is NOT worth it**: 64→256 buys −0.39 % dhrystone / −0.21 % boot at =0
  for 4× the FTB flop RF (~7.9 Kb → ~31.5 Kb). Rejected on area.
- The remaining honest IPC lever for the inversion is unchanged and unaddressed: the Stage-B override
  bubble itself (+1 on every taken-cond / return / indirect), which needs a genuine fast path AT
  Stage-A — option (B)'s L0 placed correctly, or a fundamentally different fetch structure. Not the
  FTB.

## Deficit decomposition, and the f2.6 round (2026-08-02)

**Where variant-A's deficit actually is.** Measured with the tb's own counters:

| dhrystone | =0 | variant-A | Δ |
|---|---|---|---|
| cycles | 252939 | 318202 | **+65263** |
| front-idle | 14066 | 63960 | **+49894** |

**76 % of the deficit is front-end idle**, against ~48.8 k taken control transfers (the `sb_override`
count) — i.e. **~1.0 cycle of front-end idle per taken transfer**, because Stage-A has no next-target.
This CORRECTS option (B)'s conclusion that "the dominant bubble is the target's icache-read latency,
which a Stage-A fast path cannot hide": on an icache hit the whole bubble is ~1.0 cycle, exactly what
an L0 hit removes. (B) under-delivered on coverage/accuracy, not because of a structural ceiling.

**A real bug found on the way — the banked option-(B) L0 had been silently broken since 2026-07-25.**
Flipping variant-A + `PRED_L0_FAST` reproduced neither (B)'s numbers nor its bit-exactness: dhrystone
instret **206663 vs 264834**, with `tohost=1` lying (the 3a.4 lesson again). Bisected to a worktree at
the session-start commit — broken there too, so it predates this session. Root cause: **f2.4-fix
corner 1 (`a_eff_next`) is correct for the FTB-follow and WRONG under `PRED_L0_FAST`**. The rule is
"record the ACTUAL delivered successor"; under `FTB_OVERRIDE` the Stage-A advance IS that successor,
but under `PRED_L0_FAST` the Stage-A advance is the L0 TARGET, and when the clocked full predictor
then resolves NOT-taken the disagreement override re-steers to the FALL-THROUGH. Recording
`a_eff_next` there put the L0's target in the `pred_next` of an op that actually fell through.
Corner 1 landed after (B) was measured and nobody re-flipped (B). **Fixed** (`PRED_L0_FAST ?
fall-through : a_eff_next`): dhrystone **bit-exact 264834** again, and the L0 is worth
**318202 → 298401 (−6.2 %)**, coremark 409984 — the best inversion result measured so far
(+18.0 % vs =0, down from variant-A's +25.8 %).

**f2.6 — TAGE combinational at Stage-A: REFUTED.** The idea: TAGE is deliberately a register file and
never inferred as SRAM (`sram_inventory.md:111,156`), so `TAGE_SYNC_READ` is a uniformity scaffold,
not an SRAM-realism requirement — TAGE may stay combinational at Stage-A, letting the L0 use the REAL
direction the full predictor will use, which removes the L0-vs-full direction disagreement that
double-bubbled (B)'s cond-ON. Built as `TAGE_STAGEA` (Stage-B replays the value captured at produce,
`a_tage_*`, since a combinational read is aligned to Stage-A's PC, not to the draining bundle).
Measured:

| | dhrystone | coremark |
|---|---|---|
| L0, TAGE clocked (bimodal direction) | 298401 | **409984** |
| L0 + `TAGE_STAGEA`, TAGE-only direction | 299899 | — |
| L0 + `TAGE_STAGEA`, TAGE-then-bimodal | 298400 | **414743 (+1.2 %)** |

It does not help on dhrystone (1 cycle) and it **costs 1.2 % on coremark** — the very workload the
disagreement was supposed to be hurting. Mechanism, from the counters: `earlymis` **8926 → 9412
(+5.4 %)** while front-idle barely moves. Reading TAGE at Stage-A means the FULL predictor now indexes
it with **one-update-staler speculative history** (`spec_ghr`/`spec_ghr_l` advance at Stage-B), and
TAGE — unlike the bimodal — is history-dependent, so its accuracy drops. Not readily fixable: getting
up-to-date history at Stage-A requires the in-flight bundle's predicted direction, which under the
inversion is precisely what is not yet known. **The direction disagreement was not the binding
constraint, and paying for it with staler TAGE history is net-negative.** Shipped DEAD at 0.

## f2.7 — root-causing the L0 boot failure (2026-08-02)

With corner 1 fixed, variant-A + L0 is bit-exact on dhrystone AND coremark but the N1 boot dies with
**`Kernel panic - not syncing: Attempted to kill init! exitcode=0xb`** (init SIGSEGV). (Correction to
an earlier note: `x3=0x80a85b60` is NOT a fingerprint — `x3`=`gp` is a kernel constant, so it only
says "the kernel was running".) What the campaign established:

- **It is NOT a wrong-path commit.** Built the f2.4-fix **divergence trap** (fetch-stream invariant
  "A.pred_next_pc == the PC of the next committed instruction"). Two iterations were needed:
  - Asserting the EARLY-redirect target as the next expected PC is **unsound** — it fires
    speculatively and can be superseded before anything commits from it. It produced an identical hit
    at cy=0xb0 on the PASSING control, and (because the original recipe latches the first hit) that
    single false positive blinded the whole run. Fixed by asserting only the COMMIT-redirect target
    (precise) and by reporting up to 12 hits instead of latching one. **Recommended amendment to the
    reusable harness.**
  - Sound version: **0 hits on the failing run**, silent on the passing control. So every committed
    instruction's successor is exactly what the front end predicted, including across commit
    redirects.
- **The failing value, traced.** epc `0x800b9d3a` is `sb a4,0(t6)` inside `memcpy` with `t6`=`a0`=6;
  a windowed commit trace of the failing call showed `kmalloc`'s inner allocator call
  (`jal ra,0x8003434c` at `0x80048d3a`) returning **6**, so `bgeu a5,a0` (a5=16) took the
  "allocation failed" path and returned `s0`=6 to `kstrdup`, which memcpy'd to address 6.
- **Stream diffing hits a hard limit — the streams diverge LEGITIMATELY.** A full committed-PC diff
  against the passing run puts the first control-flow split at commit #3,972,269 (a CRC/LFSR loop,
  `c.beqz a5` on a data bit), with NO novel PC anywhere. Diffing committed RESULTS puts the first
  value difference much earlier, at #3,786,987 — and it is **benign twice over**: the instruction is
  `amoor.d zero,a5,(a1)`, whose result is architecturally discarded (and whose recorded result is
  meaningless by design since R3.2c's `ASQ_NOREAD=1` skips the read for `rd==x0` atomics). The next
  differences are **time-derived** (`0x7b614` vs `0x77216` ≈ cycle counts) and cascade from there.
  Because the L0 changes cycle counts, any `rdtime` makes the two streams differ legitimately, so
  good-vs-bad diffing cannot localize anything downstream of the first timer read.
- **Narrowed to L0-predicted CONDITIONALS.** `L0_PRED_COND=0` (L0 restricted to unconditional +
  return, where it can never disagree with the full predictor on direction) **BOOTS**: N1
  **15.86M, pass=1** — and that is **−1.1 % vs variant-A's 16.03M**, a small but real working win.
  With `L0_PRED_COND=1` the boot SIGSEGVs. dhrystone at cond-OFF is 313433 (vs variant-A 318202,
  −1.5 %; cond-ON was 298401, −6.2 %).

**Where this leaves the deficit.** The only measured attack on the 76 % is the L0, and it currently
splits into a safe-but-small config and a valuable-but-boot-broken one:

| config | dhrystone | N1 boot |
|---|---|---|
| variant-A | 318202 (+25.8 %) | 16.03M ✅ |
| + L0, cond-OFF | 313433 (+23.9 %) | **15.86M ✅** |
| + L0, cond-ON | **298401 (+18.0 %)** | SIGSEGV ❌ |

## 🚨 f2.7 RESULT — the L0 is INNOCENT; the bug is in the EARLY-REDIRECT (S8.E) path

> **Amended by the root-cause section below.** The "S8.E is where the bug lives" half of this
> heading is WRONG. S8.E is the EXPOSER, not the location: the defect is an unsound interrupt-`epc`
> source in the commit/CSR path that is present with the early redirect off too. Everything else
> here (the L0 is innocent, `s8e_flip_en=0` boots) stands. Kept as written — this is a lab notebook.

Continuing the bisection past the "L0-predicted conditional" trigger produced the real answer.
**Disabling the execute-time early redirect (`s8e_flip_en = 1'b0`, the documented revert-to-S8.D
knob) makes variant-A + L0 cond-ON BOOT — N1 `cy=0x00edbb60` ≈ 15.58M, pass=1** — and that is the
best boot number of any authority-inversion configuration measured:

| config | N1 boot, `s8e_flip_en=1` (shipped) | N1 boot, `s8e_flip_en=0` |
|---|---|---|
| =0 baseline | 14.27M | — |
| variant-A | 16.03M ✅ | 15.94M ✅ |
| variant-A + L0, cond-OFF | 15.86M ✅ | — |
| variant-A + L0, cond-ON | **init SIGSEGV** ❌ | **15.58M ✅** |

So the L0 works and is worth **−2.3 %** on boot (15.94M → 15.58M) and **−6.2 %** on dhrystone. What
breaks is the **execute-time early-redirect / partial-squash machinery**, which the L0's prediction
pattern merely EXPOSES. `s8e_flip_en=1` is the **shipped default**, so this is a latent correctness
risk in the shipped core, not a defect of the DEAD scaffolds.

**What has been excluded** (each by measurement or by inspection):
- **wrong PATH** — the (hardened, control-verified) divergence trap reports 0 hits on the failing run.
- **wrong BYTES** — the banked detector (a PC committed with >1 distinct encoding) reports 0 hits.
- **the L0 disagreement-override (b.3)** — forcing `sb_disagree0 = pt0_eff` (override on ANY taken,
  making the L0 a pure F0 prefetch hint) still fails, so the damage is done at Stage-A.
- **lane-1 early mispredict** — forcing `early_mispredict1 = 0` still fails.
- **the dual-rename checkpoint construction** — inspected: `free_list` snapshots `post0_head`/
  `post1_head` and `rat` snapshots `post0_pak`/`post1_pak`, both of which correctly include slot-0's
  allocation in slot-1's snapshot.

**Top remaining suspect, and a trap blind spot worth knowing.** `early_redir_fix0/1` rewrites the
committed `pred_next_pc` of every mispredicting lane so the surviving op does not re-redirect at
commit. That rewrite makes the divergence trap's invariant **trivially true** for exactly those ops —
`c_pred_next_pc` is compared against the next committed PC after having been overwritten with the
resolved target. **The trap is therefore blind to a bad `early_redir_fix`**, which would explain a
silent trap alongside a corrupted machine. The other live suspects are the liveness gate
(`em*_live`, age &lt; size), the IQ partial squash, and the LSU/store-buffer view of a partial squash.
Next step: instrument `early_redir_fix*` (which entry is rewritten, with what, and whether that entry
is still live) rather than chasing the L0 further.

### Reproduction recipe for the S8.E hunt (self-contained — start in a clean context)

**The failing configuration** = variant-A (8 consts) + the L0, with the shipped early redirect on:

```sh
sed -i 's/const PRED_PIPE: bit = 0;/const PRED_PIPE: bit = 1;/'               src/core/heliodor_core.veryl
sed -i 's/const PRED_OVERRIDE: bit = 0;/const PRED_OVERRIDE: bit = 1;/'       src/core/heliodor_core.veryl
sed -i 's/const PRED_HOLD_FREEZE: bit = 0;/const PRED_HOLD_FREEZE: bit = 1;/' src/core/heliodor_core.veryl
sed -i 's/const PRED_L0_FAST: bit = 0;/const PRED_L0_FAST: bit = 1;/'         src/core/heliodor_core.veryl
sed -i 's/const IBTB_SYNC_READ: bit = 0;/const IBTB_SYNC_READ: bit = 1;/'     src/core/ibtb.veryl
sed -i 's/const BHT_SYNC_READ: bit = 0;/const BHT_SYNC_READ: bit = 1;/'       src/core/bht.veryl
sed -i 's/const BTB_SYNC_READ: bit = 0;/const BTB_SYNC_READ: bit = 1;/'       src/core/btb.veryl
sed -i 's/const TAGE_SYNC_READ: bit = 0;/const TAGE_SYNC_READ: bit = 1;/'     src/core/tage.veryl
sed -i 's/const PRED_OVERRIDE: bit = 0;/const PRED_OVERRIDE: bit = 1;/'       src/core/rob.veryl
# FTB_OVERRIDE / FTQ_DECOUPLE / PRED_RAS_AHEAD / TAGE_STAGEA stay 0 (variant-A, not F2).
```
Revert with `git checkout -- src/core/{heliodor_core,ibtb,bht,btb,tage,rob}.veryl`.

- **FAIL signature:** `veryl test --ignored --test test_soc_linux_boot` → 45M timeout,
  `Kernel panic - not syncing: Attempted to kill init! exitcode=0xb`, fault `epc=0x800b9d3a`
  (memcpy `sb a4,0(t6)` with `t6=a0=6`). Console is UART-doubled — de-double with
  `sed 's/\(.\)\1/\1/g'`. dhrystone/coremark are BIT-EXACT in this config, so the boot is the only
  reproducer.
- **The one-line control that proves it is S8.E, not the L0:**
  `sed -i "s/let s8e_flip_en: logic = 1'b1;/let s8e_flip_en: logic = 1'b0;/" src/core/heliodor_core.veryl`
  → boots, 15.58M. Toggle it back and forth to confirm before instrumenting anything.
- **Kernel disasm** (needed to read any PC): hex line `M = (PA - 0x80000000)/4 + 1` in
  `test/hex/linux_dram_real.hex`; extract N words, little-endian each to bytes, then
  `toolchain/elf/bin/riscv64-unknown-elf-objdump -b binary -m riscv:rv64 -M no-aliases -D
  --adjust-vma=0x<PA>`. **Committed PCs are VIRTUAL** (`0xffffffff80xxxxxx`); the VA→PA offset is 0,
  so compare traces against the VA, not the PA (a full trace run was wasted on this).
- **Trace plumbing** already proven in this campaign: `o_commit2_is_rvc` / `o_commit2_instr` are the
  two temp `rob` ports lane-B tracing needs (`sh_is_rvc[head1_idx]` / `sh_instr[head1_idx]`).
  Veryl relational operators are `<:` / `>:` (not `<` / `>`).
- **Capture gotcha:** pipe a long `$display` run to a FILE and post-process it; piping the live run
  through `grep | sort` silently truncated a 10.4M-line trace to 51 k lines and produced a bogus
  "streams identical" conclusion.
- **`$display` gotcha (new):** the Veryl simulator's formatter supports only bare `%h/%d/%b/%o/%c/%s`
  — a WIDTH/FLAG modifier is not parsed (`crates/simulator/src/ir/statement.rs:486`, the `_ =>` arm).
  `%0d` therefore prints the two characters `%0` followed by `d` and **consumes no argument**, so a
  whole instrumented run comes back as unsubstituted format strings. Use `%d`, never `%0d`. (Real SV
  accepts `%0d`, so this is a genuine simulator gap worth an upstream fix.)

### f2.7 instrumentation round 1+2 — the rename/writeback datapath is INNOCENT

Instrumented the failing configuration with five always-on invariant detectors in the core / `rob` /
`rat` (all silent unless violated, plus a 1 M-cycle summary line). Two runs, both carried **past** the
point where the passing control has already booted (23.0 M and 16.8 M cycles vs the 15.58 M passing
boot), **every counter zero**:

| detector | what a hit would mean | result |
|---|---|---|
| `S8E-STALE0/1` | a CDB writeback whose `rob_idx` age ≥ `rob_size` — a squashed op's straggler landing in a dead entry (its pdst already reclaimed) | **0** |
| `S8E-WBDUP` | an entry written back **twice** between alloc and commit — the same straggler landing in a slot that has since been REALLOCATED, the one shape the head-relative liveness test cannot see | **0** |
| `S8E-TAGBAD` | CDB `pdst` ≠ the ROB entry's `rd_pdst` — an IQ payload/`rob_idx` desync after a partial squash (FU writes through the wrong physical tag) | **0** |
| `S8E-RATDUP` | `rat_spec` (or `rat_arch`) not pairwise distinct — the free list handed one tag out twice, the classic mis-sized checkpoint rewind | **0** |
| `S8E-MISROUTE` | `early_redir_fix0` applied to a different entry than the ALU resolved, because it rides the SHARED lane-0 `cdb` priority mux (fpu > mshr > int_div > alu > lsu > vu) while being derived from `alu_cdb_eff` | **0** |
| `S8E-SURVIVOR` | both lanes mispredict and the NON-selected (also-fixed) lane is not strictly younger, so the partial squash would not remove it | **0** |
| `S8E-MSHRABAND` | an MSHR entry squashed while it OWNS an in-flight dcache fill — the fill is bound to a load by `own_q`, NOT by a line tag, so an orphaned fill can be latched by whichever entry holds the slot when it lands | **0** |
| `S8E-LSRABAND` | the LSR squashed mid Stage-B read | ~13/M — **benign, see below** |

So the `early_redir_fix` rewrite itself is well-behaved, and the whole **stale-writeback / renaming**
class is dead: no straggler write, no double write, no tag desync, no free-list double-allocation.
Worth recording because two of these looked structurally damning by inspection:

- **the lane-0 CDB priority mux** genuinely can deliver a different op than `alu_cdb_eff` — but only
  at `EX_PIPE=1`; at the shipped `EX_PIPE=0` the ALU issue gate (`!fpu_cdb.valid && !mshr_cdb.valid`,
  plus a DIV holding the `iq_int` head) makes `cdb ≡ alu_cdb_eff` whenever the ALU is valid. **A
  latent `EX_PIPE=1` hazard, not this bug.**
- **`fpu_wrap` is the one FU that is NOT told about the partial squash** — its `i_flush` is wired to
  `redirect_fire` (commit redirect) only, so a stage-2 op younger than the resolved branch keeps
  going. The div/sqrt FSMs were already hardened against exactly this (`done_for_me`, and the comment
  there says outright that the early redirect does not assert `i_flush`), but `s2_valid` is not. The
  detectors say this window is never actually hit in this boot, so it too is **latent, not the bug**.
- **the LSR abandoned mid-read** DOES happen (~13 per million cycles, and the printed events are the
  expected shape — the squashed load sits exactly one ROB slot after the resolving branch). It is
  nonetheless **benign**: `dcache.o_rdata` is driven from the tag/data lookup of the address being
  driven THIS cycle (`dhit_rdata_sel` / `o_rdata_live`), not from a fill buffer keyed to the original
  miss offset, and `o_stall` holds through `FILL`/`DONE`/`miss` — so the LSR's next occupant reads
  its own address or waits. (`o_fill_rdata`, which IS keyed to the original miss offset, goes only to
  the MSHR, and `S8E-MSHRABAND` says that binding is never orphaned.) Worth recording because the
  asymmetry is real: after a FULL flush the pipe is empty and the abandoned access has long finished
  before a new load can issue, whereas after a PARTIAL squash a new load can capture the LSR two
  cycles later — S8.E genuinely opens a window that S8.D never opens.

**Next step: budget bisection** (the technique that localized the R3.2c atomic bug). `S8E_BUDGET`
lets the early redirect fire only for its first N events and behave exactly like `s8e_flip_en=0`
after; a binary search over N names the single early redirect that breaks the machine. The boot tb's
chunk cap is temporarily 1800 (18 M) instead of 4500 (45 M) so a failing probe aborts in a third of
the time. Bracket measured: **94,428 firings** over the failing run, ~11–13 min per probe, so ~17
iterations. It is sound because the budget only truncates the event sequence — the first N firings
of a budget-N run are bit-identical to the first N of the unlimited run, so the search converges on a
single, dumpable event.

### 🎯 f2.7 BISECTION RESULT — the culprit is early-redirect firing **#88,784**

17 probes, monotone as required (every budget ≤ 88,783 boots, every budget ≥ 88,784 fails):

```
budget  47250 PASS   70875 PASS   82687 PASS   88593 PASS   88777 PASS   88782 PASS   88783 PASS
budget  91546 FAIL   90069 FAIL   89331 FAIL   88962 FAIL   88869 FAIL   88823 FAIL   88800 FAIL
        88788 FAIL   88785 FAIL   88784 FAIL
⇒ last-good budget 88783, first-bad 88784
```

Sanity-checked rather than assumed: each probe's `S8E-SUM` shows `fire` saturating at exactly its
configured budget (so the `sed` really took), and `lsrab` differs between probes (so the trajectories
really are distinct). The identical shutdown cycle across several PASS probes is timer quantization
at the end of boot, not a stuck knob.

**The payoff is a perfectly matched control.** A budget-N and a budget-(N+1) run are bit-identical up
to firing N, so `S8E_BUDGET=88783` (PASS) and `88784` (FAIL) form an aligned pair from the culprit
firing onward. That defeats the wall this campaign hit earlier — good-vs-bad committed-stream diffing
was useless because any `rdtime` read makes two differently-timed runs diverge legitimately. Here the
two streams are architecturally identical until the bug bites, so the **first non-time-derived
difference names the corrupted instruction outright**. `S8E_DUMP_FROM` dumps `(pc, rd, value)` for
both commit lanes from firing #88,783 on, in both arms, for the diff.

## 🎉 f2.7 ROOT CAUSE — an interrupt's `epc` was read off the SPECULATIVE FRONT END

The matched-control diff put the machine's death on one line. First difference, commit #380 — the
trap-entry save of the interrupted PC — and then the payoff 2000 commits later:

```
PASS   C0 80002714 x0 <- 0102     (sret)          FAIL   C0 80002714 x0 <- 0102     (sret)
       C0 80048d3a x1 <- 80048d3e  jal ra,8003434c        C0 80048d3e ...   <- jal SKIPPED
       C0 8003434c ... (callee, 25 instrs)                C0 80048d40 x8 <- 6
       C0 8003438e x0 <- 80034390  ret
       C1 80048d3e ...             back at caller
```

`0x80048d3e` is the FALL-THROUGH of a taken `jal` — a PC the architectural control flow never
reaches. The interrupt's `sepc` was wrong, `sret` resumed past the call, the callee never ran, and
`a0` kept a stale 6 — which is precisely the "`kmalloc`'s inner call returned 6" the earlier windowed
trace had found, now explained rather than merely observed.

**The defect** (`heliodor_core.veryl`, the `csr` instance):

```veryl
let commit_irq: logic = (rob_size == 8'd0) && !redirect_fire_q && !commit_excp && csr_irq_pending;
i_trap_pc: if commit_irq ? (if if_v_q ? if_pc_q : ic_pc) : ... c_pc,   // ← unsound
```

An async interrupt's `epc` must be the architectural successor of the last COMMITTED instruction —
a commit-side quantity. It was instead read off the front end. `if_pc_q`/`ic_pc` are **speculative
fetch pointers**, and `rob_size == 0` drains the ROB but says nothing about the **fetch pipeline**:
`ic_pc` runs ahead of the architectural PC by an amount that varies with front-end depth and timing.
Both arms take this interrupt on the SAME cycle (11,325,830) with `if_v=0`, so both fall to `ic_pc`:

| | `ic_pc` (= `sepc`) | `since_earl` |
|---|---|---|
| PASS | `80048d3a` ✅ the jal | 255 (no early redirect) |
| FAIL | `80048d3e` ❌ its fall-through | 199 |

Same last-committed instruction, same cycle, different `epc` — `epc` had become a function of
TIMING rather than of architectural state.

**The fix**: maintain the committed architectural next PC and use it.

```veryl
let c2_arch_next_pc: logic<64> = c2_pc + (if c2_is_rvc ? 64'd2 : 64'd4);
always_ff (clk, rst) {
    if_reset            { arch_next_pc_q = RESET_PC;        }
    else if redirect_fire { arch_next_pc_q = redirect_pc;     }   // commit redirect target
    else if commit2_fire  { arch_next_pc_q = c2_arch_next_pc; }   // slot 1 (non-control by c2_simple)
    else if rob_commit_ack { arch_next_pc_q = c_arch_next_pc; }   // slot 0, full control-aware form
}
i_trap_pc: if commit_irq ? arch_next_pc_q : ...
```

`c_arch_next_pc` already existed (it is what the commit-time mispredict check compares against); the
EARLY redirect is deliberately NOT tracked, since it is speculative and its branch has not committed.
Needs one new `rob` output, `o_commit2_is_rvc` (slot-1 length) — slot-1 commit excludes control ops,
so slot-1's successor is just `pc+len`. **44 + 6 lines total.**

**Result: the failing configuration BOOTS** — variant-A + L0 cond-ON + `s8e_flip_en=1`, unlimited
budget, `cy=0x00eea5c0` ≈ **15.64 M, pass=1** (vs variant-A's 16.03 M: **−2.4 %**).

And the mechanism is proven, not just the symptom cured: instrumenting "IRQs where the fixed `epc`
differs from the old one" over the whole 15.6 M-cycle boot reports **exactly one**:

```
S8E-IRQ cy=7325862 NEW=800b3ebe OLD=800b3ec2 if_v=0 if_pc=800b3f22 ic_pc=800b3ec2 since_earl=255 fbc=0
```

`OLD = NEW + 4`: the old source skipped one 4-byte instruction that was still inside the fetch pipe,
with the fetch buffer already EMPTY (`fbc=0`) — so the `if_v_q ? if_pc_q : ic_pc` selector, which
only ever accounted for ONE fetched-but-undispatched instruction, had nothing left to fall back on.

### f2.8 — the corrected ladder for variant-A + L0 cond-ON (2026-08-03)

With the epc fix in, the whole ladder was re-measured end-to-end in one tree. **This is the first
time the cond-ON configuration has passed every gate**, so it supersedes every earlier cond-ON
number (those were taken from a machine whose boot was broken).

| gate | =0 (shipped) | **variant-A + L0 cond-ON** | Δ |
|---|---|---|---|
| `veryl test` | 252 / 0 | **252 / 0** | — |
| litmus N=2 | `0x2e6300` 3.04 M | `0x320c80` 3.28 M | +7.9 % |
| litmus N=4 | `0x3b0d30` 3.87 M | `0x3fef30` 4.19 M | +8.3 % |
| dhrystone | 252939 | **298401** | **+18.0 %** |
| coremark | 367139 | **409984** | **+11.7 %** |
| boot N=1 | `0x0d9be30` 14.27 M | `0x0eea5c0` **15.64 M** | +9.6 % |
| boot N=2 SMP | `0x125bb50` 19.25 M | `0x13bdb60` **20.70 M** | +7.5 % |
| boot N=4 SMP | `0x1c4e180` 29.68 M | `0x1dcaf40` **31.24 M** | +5.3 % |

instret is BIT-EXACT vs `=0` on both benchmarks (264834 / 374357), so every delta above is pure
front-end cycles. Against the previously best BOOTABLE inversion config (variant-A): dhrystone
318202 → 298401 (**−6.2 %**), boot N1 16.03 M → 15.64 M (**−2.4 %**).

**The cost falls as harts are added** (+9.6 % → +7.5 % → +5.3 %): SMP boot is increasingly
memory/coherence bound, so a front-end cost matters less. The single-hart numbers are the worst case.

**Deficit decomposition — the remaining cost is almost entirely front-end idle:**

| | cycles Δ vs =0 | front-idle Δ vs =0 | front-idle share of the deficit |
|---|---|---|---|
| dhrystone, variant-A | +65263 | +49894 | 76 % |
| dhrystone, **+L0** | **+45462** | **+29608** | **65 %** |
| coremark, **+L0** | +42845 | +42113 | **98 %** |

So the L0 removed **41 %** of variant-A's front-idle excess (49894 → 29608) — real, and exactly the
mechanism predicted (≈1.0 cycle per taken transfer removed on an L0 hit) — but the SAME lever still
dominates what is left, and on coremark it is essentially the ONLY thing left. Tuning anything other
than Stage-A next-target coverage cannot move these numbers.

### f2.9 — where the remaining bubbles actually are: it is SLOT-1, not L0 capacity

Every `sb_override` is one front-end bubble, and `26800 × ~0.87 cy ≈ 29608` accounts for essentially
ALL of dhrystone's front-idle excess — so attributing the overrides IS attributing the deficit.
Instrumented the split by CAUSE (`sb_disagree0` decomposes exactly three ways) plus, for the L0's
own misses, the reason. Measured at variant-A + L0 cond-ON:

| override cause | dhrystone | coremark |
|---|---|---|
| **total** | 26800 | 26677 |
| **S1 — slot-0 agreed, SLOT-1 was taken** | **17851 (67 %)** | **18243 (68 %)** |
| A — full taken, L0 declined (coverage miss) | 8919 (33 %) | 5952 (22 %) |
| B — L0 took, full did not (L0 was WRONG) | 30 (0.1 %) | 2482 (9.3 %) |
| C — both taken, targets differ | **0** | **0** |
| A: micro-BTB miss / indirect / weak dir / no RAS | 8917 / 0 / 2 / 0 | 2682 / 4 / 3266 / 0 |

**The dominant cost is not the L0 at all — it is `sb_ovr_taken1`.** The front end is 2-wide but the
L0 only ever looked up slot 0 (`i_pc` = `ic_pc`; `slot1_pred_ok = !l0_taken`), so a taken slot-1
branch paid an override bubble unconditionally, no matter how good the L0 was. That is two thirds of
all bubbles on both benchmarks. **C = 0 everywhere** is worth noting separately: when the L0 hits, its
target is always right — aliasing is simply not a problem, so nothing here argues for more tags.

Added a second async read port to `l0pred` (on `s1_pc`) purely observationally, to size the prize
before building a datapath for it:

| slot-1 population | dhrystone | coremark |
|---|---|---|
| **covered — the L0 WOULD have predicted it** (jal / strong-cond) | **9426 (53 %)** | **14218 (78 %)** |
| micro-BTB miss | 7425 | 683 |
| return (would drag RAS ordering into Stage-A) | 999 | 1242 |
| indirect / weak direction | 0 / 1 | 441 / 1659 |

So the SIMPLEST possible slot-1 path — direct targets only, **returns and indirects excluded, no RAS
at Stage-A** — addresses **35 % of all overrides on dhrystone and 53 % on coremark**. At coremark's
~1.58 cy/override that is ~22.5 k cycles, i.e. +11.7 % → ≈ +5.5 % vs `=0`.

**Micro-BTB capacity sweep — REJECTED, the lever is weak:**

| micro-BTB entries | dhrystone | Δ | coremark | Δ |
|---|---|---|---|---|
| 32 (shipped) | 298401 | — | 409984 | — |
| 64 | 296397 | −0.67 % | 409459 | −0.13 % |
| 128 | 293417 | −1.67 % | 409394 | −0.14 % |

4× the array for −1.67 % / −0.14 %, on an **async-read flop RF that sits on the Stage-A critical
path** — the structure whose entire reason for existing is being fast. Same shape of trade the
campaign already rejected for the FTB (64→256 for −0.39 %). Kept at 32. (A useful artefact of the
sweep: slot-1 `ret` rises 999 → 3058 as entries grow, because those PCs now HIT and get identified as
returns instead of being counted as misses — the return share is real, not a capacity artefact.)

**⇒ Next lever: a slot-1 L0 path, not a bigger L0.** Chosen by measurement, against the prior
expectation that capacity was the constraint.

### f2.10 — the slot-1 L0 fast path, BUILT and measured (`L0_SLOT1`, DEAD at 0)

Built what f2.9 pointed at: a second async read port on `l0pred` (on `s1_pc`) and the same
Stage-A-predict / Stage-B-override-on-disagreement protocol slot 0 already had. Returns and
indirects deliberately excluded, so the RAS never enters the Stage-A fast path.

Touches, all folding away at `L0_SLOT1=0`: `l0_taken1` + `l0_slot1_deliv`; `ext_l0_next` (Stage-A
advances to slot-1's target); `l0_redir` / `l0_redir_target` (the F0 re-steer); `a_l0_taken1` /
`a_l0_target1`; `sb_ovr_taken1` becomes a disagreement check mirroring `sb_disagree0`; one new arm in
`sb_override_target` for "the L0 falsely took slot 1" → slot-1's fall-through.

| | =0 | variant-A + L0 | **+ slot-1** | Δ |
|---|---|---|---|---|
| dhrystone | 252939 | 298401 (+18.0 %) | **286080 (+13.1 %)** | **−4.13 %** |
| coremark | 367139 | 409984 (+11.7 %) | **407093 (+10.9 %)** | −0.71 % |
| litmus N=2 | 3.039 M | 3.279 M (+7.9 %) | **3.101 M (+2.0 %)** | −5.5 % |
| boot N=1 | 14.27 M | 15.64 M (+9.6 %) | **15.51 M (+8.7 %)** | −0.84 % |

instret BIT-EXACT on both benchmarks (264834 / 374357). `veryl test` **252/0** with it on; at
`L0_SLOT1=0` the whole ladder is byte-identical to the f2.8 numbers, and at the shipped default
config `veryl test` 252/0 + litmus `0x2e6300` + dhrystone 252939/264834 are unchanged — the scaffold
is genuinely inert.

Overrides: dhrystone 26800 → 16640 (S1 17851 → **7825**), coremark 26677 → 14056 (S1 18243 →
**5735**). The `s1: covered` population collapses to ~0, which is the signature of exactly those
bubbles now being covered.

**A bug in the first cut, caught by instret and worth recording.** The initial gate was
`slot1_eligible`. That is NOT the condition under which slot 1 is delivered — `fb_push1` also needs
`slot1_valid` (the cross-line `s1_needs_next` case) and fetch-buffer room for two. So Stage-A
advanced to slot-1's target on produces that pushed only slot 0, and **slot 1 was skipped**:
dhrystone retired **264336 instead of 264834**. `tohost` still said pass — the 3a.4 lesson again, and
the reason instret is the canary of record. Fixed by gating on `slot1_valid && fb_free >= 2`, kept
produce-INDEPENDENT so `ext_eff_next`'s every-cycle consumers (`f0_diverged` / `ext_exp_next`) see
the shape they always did.

**A projection of mine that was WRONG, also worth recording.** f2.9 estimated coremark would go
+11.7 % → ≈ +5.5 %, by dividing its front-idle excess by its override count (1.58 cy/override) and
scaling. Actual: **+10.9 %**. Measured cost per override removed is **1.21 cy on dhrystone but only
0.23 cy on coremark** — on coremark the front-end bubbles largely OVERLAP icache/back-end stalls, so
removing them buys almost nothing. **A global average cycles-per-override is not a valid projector**;
it is only near-additive where the front end is actually the binding constraint (dhrystone, litmus).

**Where the deficit stands now.** dhrystone +13.1 %, remaining overrides 16640 = slot-0 coverage 8782
(all micro-BTB miss) + slot-1 7825 (btbmiss 6836, returns 984). So after the slot-1 path the
remaining population IS mostly micro-BTB capacity — but f2.9 already measured that lever as weak
(−1.67 % for 4× the array, on the Stage-A critical path), and it would now have to pay for BOTH
slots' read ports. Not obviously worth it; the honest next candidates are slot-1 returns (needs RAS
at Stage-A) and coremark's direction confidence, neither of which is a capacity problem.

### 🚩 f2.11 — the synth answer: the predictor is NOT on the critical path (CP-neutral flip)

The one thing the campaign had never measured: what the front-end flip does to **synth CP**. Run in
the current tree, sky130, `veryl synth --top heliodor_core --dump-timing/--dump-area`, baseline vs
the full LIVE candidate (variant-A 8 consts + `PRED_L0_FAST` + `L0_SLOT1`):

| | CP | top path | gates | FFs | area (um²) |
|---|---|---|---|---|---|
| `=0` shipped | **12.975 ns** | `pc_fetch_q[34] → n_inflight[5]`, 138 levels | 1178181 | 162575 | 19877985.60 |
| variant-A + L0 + slot-1 | **12.975 ns** | **identical, cell-for-cell** | 1193696 | 167975 | 20153085.60 |
| Δ | **0.000 ns** | — | +1.32 % | **+3.32 %** | +1.38 % |

**The critical path contains ZERO predictor cells** — grepping path #1 for `btb|bht|tage|ibtb|l0pred`
returns nothing. What the 12.975 ns megacone actually is:

```
pc_fetch_q → u_imem_mmu.u_mmu (Sv39 translate) → u_icache.i_addr → u_icache.next_hit
           → u_dcache.i_wen → rob_commit_valid → commit_trap → u_fl.n_inflight
```

i.e. **instruction-fetch MMU + icache hit → commit/trap → rename resource**. The branch predictor
read is a shorter PARALLEL cone that never binds, so making it clocked cuts something that was not
the wall. The identical number is a real measurement, not a stale-cache artefact: FF count moves
162575 → 167975 (+5400 = the sync-read output registers + the L0 flop RF + its slot-1 read port) with
RAM bits unchanged at 1627752, so the netlist demonstrably changed while path #1 did not.

Second front, for reference: `head[0] → xline_lo_q` at 12.680 ns — the commit-store PMP
(`u_dmem_mmu.u_pmp_amo_w`) → `m_wstrb_q` → dcache `d1_msk` cone. Also not front-end. So even a
*perfect* front-end cut could only have bought 0.295 ns (2.3 %) before hitting a non-front-end wall.

**⇒ The LIVE decision is a pure structure-for-IPC trade with NO timing compensation:**

| | cost of going LIVE |
|---|---|
| dhrystone | **+13.1 %** (was +18.0 % before the L0 + slot-1 work) |
| coremark | +10.9 % |
| boot N=1 / N=2 / N=4 | +8.7 % / +7.5 %* / +5.3 %* |
| litmus N=2 | +2.0 % |
| synth CP | **0.000 ns** |
| area / FFs | +1.38 % / +3.32 % |

<sub>* N=2/N=4 measured at f2.8 without the slot-1 path; both improve with it.</sub>

This is **not** the "free structural win" the campaign's framing might suggest, and it is worth
stating plainly. Phase 14's mandate is explicitly *structural completeness, not CP*, and
`feedback: CP-neutral stage boundaries still count as progress` — on those terms a clocked-read
predictor is a genuine advance toward what a real core has, and the L0 + slot-1 work is what brought
the price down from +18.0 % to +13.1 %. But the price is real, it is paid on every workload, and
nothing in the timing report offsets it. **The flip is the user's call; the measurement no longer
leaves it ambiguous.**

**If CP were the goal instead**, this report names the target unambiguously and it is not the
predictor: the `imem_mmu → icache → commit_trap → n_inflight` fetch-to-rename megacone (138 levels),
with the commit-store PMP → dcache mask cone 0.295 ns behind it.

### 🔬 f2.12 — WHY the decoupling never paid: the FTQ is RATE-MATCHED to fetch

Prompted by the right question: real cores use overriding/clocked-read predictors *and* have high
IPC, so either the structure is unusual (it is not — it is standard) or heliodor is missing the
mechanism that hides its latency. That mechanism is a **run-ahead FTQ**, and F2 has one. Measured
what it actually does, at F2-full (variant-A + L0 + slot-1 + `FTB_OVERRIDE` + `FTQ_DECOUPLE`),
dhrystone:

| | enq | pop | mean depth | bypass cycles | `pp_reseed` |
|---|---|---|---|---|---|
| shipped policy | 3909 (1.2 %) | 1040 | **0.026** | **97.9 %** | 52418 (16 %) |
| `FTQ_RUNAHEAD=1` | **275176 (84 %)** | **321841 (98 %)** | **0.026** | 97.9 % | 52418 (16 %) |

`FTQ_N=8`, and the mean occupancy is **0.026 entries**. The FTQ is a pass-through, not a queue.

**First finding — the bypass policy.** `f0_ftq_byp = FTQ_DECOUPLE && f0_present && ftq_count == 0`
suppresses `ftq_enq`, so the instant the queue empties the producer stops producing: empty → bypass →
no enqueue → still empty. Depth could only ever accumulate while F0 was STALLED, i.e. exactly when it
is useless. `FTQ_RUNAHEAD` (DEAD scaffold, byte-identical at 0) removes that: keep enqueuing on a
bypass cycle and let the same cycle's beat-done consume the bypassed entry. It works — enq goes
1.2 % → 84 % — and **changes nothing**: depth stays 0.026, cycles stay 358627, instret bit-exact.

**Root finding — producer and consumer are rate-matched by construction.** `pp_next = pc_pred + 8`:
`pc_pred` advances **one dword per cycle**, and F0 consumes one dword per beat, which on an icache
hit is one cycle (`pop` = 98 % of cycles confirms fetch really is running at ~1 dword/cycle). A queue
between a producer and a consumer of equal rate **cannot accumulate depth**, whatever its capacity or
bypass policy. That is why f2.5d was "blocked on run-ahead depth", why enlarging `FTQ_N` would do
nothing, and why F2 measured WORSE than variant-A: it pays the reconciliation cost of a decoupled
front end while structurally unable to collect the benefit.

Compounding it: `pp_reseed` fires on **16 %** of cycles (52418; `f0_diverged` is 19689 of those),
flushing the queue to empty roughly every sixth cycle. Even a rate-advantaged producer would struggle
against that.

**What a real core does differently.** Its predictor produces a whole **fetch BLOCK** per cycle — a
run of instructions up to the next taken branch, often many dwords — while fetch consumes one line
per cycle. The producer is therefore *faster* than the consumer, the queue fills, and the predictor's
(clocked, multi-cycle) latency is amortised across the queue depth instead of paid per branch.
heliodor's FTB predicts **per dword**, so it can never out-run fetch.

**⇒ The honest answer to "can the IPC loss be recovered separately": yes in principle, by the
mechanism real cores use, but that mechanism requires BLOCK-GRANULARITY prediction.** It is not a
tuning problem — not the L0's capacity (measured, weak), not the FTQ's depth (measured, irrelevant at
equal rates), not the bypass policy (built, measured, no effect). It is a restructure of the
prediction granularity itself, and that is materially larger than anything left in Phase 14's current
scope. Until it exists, the +13.1 % is the standing price of the clocked-read front end, and F2's
decoupling cannot pay for itself.

`FTQ_RUNAHEAD` is kept as a DEAD scaffold: it is a genuine correctness improvement to the bypass
policy (the queue can now fill whenever the producer is ahead) and it is the prerequisite any
block-granularity work would need — but on its own it is worth exactly zero, and the table above is
the record of that.

## f2.13 — BLOCK-GRANULARITY PREDICTION: hand-off for a clean context

User decision (2026-08-04) after f2.12: proceed to block-granularity prediction. Written to be
self-contained — start here in a fresh session, the way f2.7's recipe was used.

### The one-sentence problem

`pp_next = pc_pred + 64'd8` advances the predictor **one dword per cycle**; F0 consumes one dword per
beat (1 cycle on an icache hit). Equal rates ⇒ the FTQ can never accumulate depth ⇒ the clocked
predictor's latency is paid per branch instead of amortised ⇒ +13.1 % dhrystone. **Make the producer
faster than the consumer.**

### What "block granularity" has to mean here

Today the FTB is a per-dword map: `dword PC → next dword PC`. A block-granularity predictor maps
**fetch block → fetch block**: given a block's start PC, produce in ONE cycle the block's *end* (where
the taken branch is, or the line end) and the *next block's* start PC. Then one predictor cycle
supplies many dwords of fetch, and the queue fills at (block size) : 1 against F0.

Concretely, the FTQ entry stops being a dword PC (`ftq_pc[]`) and becomes a descriptor:
`{start_pc, n_dwords / end_pc, taken, target, kind(call/ret/ind), RAS action}` — the shape the F2
plan already sketched (§"Target structure", the `enqueue FTQ descriptor` line) but never built,
because f2.5a wired the FTQ as an address queue.

### RTL anchors (all in `heliodor_core.veryl`)

| what | where |
|---|---|
| producer loop | `pc_pred`, `pp_next`, `pp_ftb_hit/target/is_ret`, `pp_advance` |
| the queue | `ftq_pc[FTQ_N]` (`FTQ_N=8`), `ftq_head/tail/count` |
| consumer | `f0_fetch_pc`, `f0_ftq_pop`, `f0_ftq_byp`, `f0_beat_done`, `f0_present` |
| flush | `pp_reseed` (= redirect / early-redirect / hard `sb_override` / `ext_taken_redir` / `f0_diverged`) |
| bypass fix | `FTQ_RUNAHEAD` (DEAD@0, f2.12) — keep it; a block producer still needs it |
| FTB itself | `ftb_valid/tag/target[]`, `ICACHE_FETCH_DIRECTED`, indexed per dword today |

### Two blockers that will bite, both measured

1. **`pp_reseed` fires on 16 % of cycles** (52418 / 327679; `f0_diverged` is 19689 of them). A queue
   flushed every sixth cycle cannot stay deep no matter how fast the producer is. `f0_diverged`
   compares `f0_fetch_pc[63:3] != ext_pc_q[63:3]` — a **lockstep assumption**: it treats F0 being at a
   different dword from extract as an error. Under a genuine run-ahead that is the NORMAL state.
   **This check must be re-scoped (or dropped under FTQ_DECOUPLE) before depth is possible.**
2. **Reconciliation cost scales with depth.** Every `sb_override` throws away the queued run-ahead.
   Deeper queue ⇒ more discarded work per disagreement. f2.3/f2.4 measured FTB-follow reconciliation
   as already net-negative *at depth 0*; it is not obvious this improves with depth, and that is the
   real risk to the whole idea. **Measure depth first, IPC second — do not build the full descriptor
   FTQ before confirming depth can be held.**

### Config recipe (F2-full — the arm this work lives in)

```sh
sed -i 's/const PRED_PIPE: bit = 0;/const PRED_PIPE: bit = 1;/'               src/core/heliodor_core.veryl
sed -i 's/const PRED_OVERRIDE: bit = 0;/const PRED_OVERRIDE: bit = 1;/'       src/core/heliodor_core.veryl
sed -i 's/const PRED_HOLD_FREEZE: bit = 0;/const PRED_HOLD_FREEZE: bit = 1;/' src/core/heliodor_core.veryl
sed -i 's/const PRED_L0_FAST: bit = 0;/const PRED_L0_FAST: bit = 1;/'         src/core/heliodor_core.veryl
sed -i 's/const L0_SLOT1: bit = 0;/const L0_SLOT1: bit = 1;/'                 src/core/heliodor_core.veryl
sed -i 's/const FTB_OVERRIDE: bit = 0;/const FTB_OVERRIDE: bit = 1;/'         src/core/heliodor_core.veryl
sed -i 's/const FTQ_DECOUPLE: bit = 0;/const FTQ_DECOUPLE: bit = 1;/'         src/core/heliodor_core.veryl
sed -i 's/const IBTB_SYNC_READ: bit = 0;/const IBTB_SYNC_READ: bit = 1;/'     src/core/ibtb.veryl
sed -i 's/const BHT_SYNC_READ: bit = 0;/const BHT_SYNC_READ: bit = 1;/'       src/core/bht.veryl
sed -i 's/const BTB_SYNC_READ: bit = 0;/const BTB_SYNC_READ: bit = 1;/'       src/core/btb.veryl
sed -i 's/const TAGE_SYNC_READ: bit = 0;/const TAGE_SYNC_READ: bit = 1;/'     src/core/tage.veryl
sed -i 's/const PRED_OVERRIDE: bit = 0;/const PRED_OVERRIDE: bit = 1;/'       src/core/rob.veryl
```
Revert: `git checkout -- src/core/{heliodor_core,ibtb,bht,btb,tage,rob}.veryl`.

### Baselines to beat (dhrystone, this tree)

| config | cycles |
|---|---|
| `=0` shipped | 252939 |
| variant-A + L0 + slot-1 (**the number to beat**) | **286080** |
| F2-full (+FTB_OVERRIDE +FTQ_DECOUPLE) | 358627 |

instret must stay **264834** (dhrystone) / **374357** (coremark) — see the traps below.

### Depth instrumentation (reproduce f2.12's table in ~2 min)

Counters on `ftq_count` (sum for mean, max), `f0_ftq_byp`, `pp_reseed`, `f0_diverged`, `ftq_enq`,
`f0_ftq_pop`, printed every 2^16 cycles from an `always_ff` next to the FTQ. f2.12's numbers to
reproduce as the control: mean depth **0.026**, byp **97.9 %**, reseed **16 %**.

### Traps this campaign has actually paid for

- **`instret` is the canary, not `tohost`.** A skipped instruction still reports pass (3a.4, and
  f2.10's `slot1_eligible` gate: 264336 vs 264834).
- **Veryl `$display` has no width specifiers** — `%0d` prints literally and consumes NO argument. Use
  `%d`. (`crates/simulator/src/ir/statement.rs:486`.)
- **No dynamic array READ inside `always_ff`** — the simulator rejects it and blames an unrelated,
  legitimate read of the same array. Hoist to a module-level `let`.
- **Sanity-check the `sed`.** Confirm a flipped const actually changed behaviour (a saturating
  counter, a differing statistic) before believing an A/B result.
- Veryl relational operators are `<:` / `>:`.

### Judgement to keep in view

The whole exercise is gated on blocker 2. If depth CAN be held and IPC still does not improve, that
is a genuine negative result and the honest conclusion is that the +13.1 % is the permanent price of
the clocked-read front end in this microarchitecture — which is a legitimate place to stop, given
Phase 14's goal is structural completeness rather than CP (and f2.11 showed the flip is CP-neutral
anyway).

### Corrections to the earlier f2.7 write-up

- **S8.E is the EXPOSER, not the location.** At the confirmed mismatch `since_earl=255` — no early
  redirect anywhere near it. The unsound `epc` source is in the shipped commit/CSR path and is
  independent of the early redirect; S8.E (and variant-A's deeper front end, and the L0) only change
  the timing that decides whether the window is hit. So this is a **latent correctness bug in the
  shipped core**, not a defect of the DEAD scaffolds — the f2.7 heading above overstated the case.
- **The event is rare and timing-fragile**: one occurrence per boot, and any front-end timing change
  moves whether it happens at all. That is why variant-A alone boots and variant-A + L0 does not, and
  why dhrystone/coremark are bit-exact in the failing configuration (no interrupts of consequence).
- **Method note.** The three techniques that mattered, in order: (1) invariant detectors to kill whole
  hypothesis classes cheaply — six of them, all zero, which is what stopped the hunt from chasing the
  rename/writeback datapath; (2) **budget bisection** to name the single causal event; (3) the
  **matched control** that bisection hands you for free, which is what finally beat the `rdtime`
  problem that had made good-vs-bad stream diffing useless.
  - **⇒ Shipped DEAD at 0** (all 11 consts reverted; `veryl test` 252/0 + cycle-exact litmus N2).
    d.1 (train re-timing) and d.1b (stale Stage-A redirect) STAY — both are structurally correct and
    measure non-negative — while the run-ahead RAS itself is BANKED as f2.5e substrate. **f2.5d is
    blocked on run-ahead depth, not on its own design:** it should be re-flipped once the FTQ can
    actually get ahead of F0 (a conditional bypass — let `pc_pred` free-run to N blocks instead of
    bypassing whenever the queue is momentarily empty — and/or f2.5e's hit-under-miss / FTQ-driven
    prefetch). Re-measure it there before judging the structure.
- **f2.5e** (value-add, gated) FTQ-driven prefetch / F0 hit-under-miss — convert the run-ahead into
  IPC once the P9.6 mem-port contention is addressed. Out of f2.5's structural scope; noted as the
  path that makes the decoupling pay.

## Independence

Fully independent of Blocks L (LSQ) and the commit side. Shares the front-end with
Block S (pipelined scheduler) only at the rename/IQ boundary — no conflict.
