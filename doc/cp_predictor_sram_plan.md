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
- **f2.4-fix** (next) Root-cause + fix the 2 corners, then re-flip + full regress (test / litmus N4 /
  boot N2/N4), ship at 0 with the flip validated (cf. 3a.4→3a.5→3a.6).

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

## Independence

Fully independent of Blocks L (LSQ) and the commit side. Shares the front-end with
Block S (pipelined scheduler) only at the rename/IQ boundary — no conflict.
