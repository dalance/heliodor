# A-LOOP — pipelined speculative select→wakeup + replay (the ~7.5 ns megaproject)

The campaign's hardest 80 %, and the **only** path below the ~12.9 ns keystone floor
(`cp_a_sched_scheduler_pipeline_plan.md §6`: the select→wakeup loop is 12.930 ns / **126
levels**, distributed, with **no incremental lever** — it cannot be *shortened*, only
*pipelined*). This doc is the unified design + roadmap, co-designing AS-d (pipelined select)
with A-LOOP (latency-speculative wakeup + replay), grounded in `iq_int.veryl`.

User committed to this (2026-07-01) after the keystone re-attack proved 15.3→7.5 is
unreachable by front-cutting. Status: **design only, no A-LOOP RTL yet.**

---

## 1. Why pipelining (not shortening), and why that forces speculation

The 1-cycle select→wakeup loop:
```
cycle N:  head → [SELECT: age = rob_idx − head → cand/ready → oldest-ready argmin → issue_idx]
               → [WAKEUP: sched_wake0_pdst = sh_rd_pdst[issue_idx] → ==sh_rs*_pdst[i] → rs*_rdy[i] (FF D)]
cycle N+1: the woken consumer is selectable → issues 1 cycle after its producer (1/cycle dependent issue)
```
The 126 levels are SELECT (age-subtract + cand-build + argmin + 2-wide-alloc interplay) +
WAKEUP (dyn-mux `sh_rd_pdst[issue_idx]` + per-entry compare + `prf_ready` write-arb cascade +
`rs*_rdy` mux). Measured: argmin ~3 levels (AS-b), wakeup tail ~0.2 ns (AS-a) — so the depth
is **spread across the whole datapath**, not one block. → Cannot DEAD-cut it. **Must split it
across two clock cycles** (~63 levels / ~6.5 ns each).

**The conflict:** registering the select midpoint (the AS-d "pipelined select") makes the
consumer selectable at **N+2**, not N+1 → **½ dependent-issue throughput** (proven, A-SCHED
§2 probe-3). For a fixed-latency ALU chain (the common case) that is a catastrophic IPC loss.

**The resolution — speculative wakeup:** keep the WAKEUP **combinational off the LIVE select
pick** at cycle N (consumer ready at N+1 = 1/cycle preserved), while pipelining only the
SELECT→ISSUE/grant path (the op physically leaves the IQ at N+1). The wakeup is now
*speculative*: the live pick at N may not equal the confirmed grant at N+1 (a 2-wide alloc
inserts an older op; the grant is denied by back-pressure; a load misses). On misspeculation,
**squash** the speculatively-woken wave and re-wake on the real event. This is AS-d + A-LOOP
fused: **pipelined select + speculative wakeup + replay.**

## 2. The two speculation classes (different replay triggers)

| producer | speculation | misspeculation trigger | frequency |
|---|---|---|---|
| **ALU/fixed** | the live select pick at N issues at N+1 | the pick CHANGES N→N+1 (2-wide alloc inserts older; grant back-pressured) | rare, controllable |
| **LOAD** | woken at grant+`HIT_LATENCY`, assumed hit | **dcache miss** at Stage-B | load-dependent |

The ALU class is the *cheaper* half: the only misspeculation is the select pick changing
between N and N+1, which is **bounded and detectable** (compare live-pick vs confirmed-grant)
and can even be made impossible by **freezing the pick** once speculatively broadcast (a
1-entry "select latch" that holds until grant). The LOAD class is the classic speculative-load
replay (the real 80 %): poison vector + selective squash + re-wake on fill.

## 3. Structural pieces (grounded in iq_int.veryl)

1. **Select pipeline register** (AS-d): register `{issue_idx, has_issuable, sched_wake0_*}` at
   the cycle-N pick (`iq_int:365-366,500-503`). The grant/issue (`o_issue_*`, the op leaving
   the IQ) moves to N+1 off the register. The FR (`fr0_*_q`) already is a 1-deep version of
   this — extend it / add the select-stage register before it.
2. **Speculative wakeup** off the LIVE pick (unregistered `sched_wake0_pdst`) → `rs*_rdy` at
   N+1 (unchanged wakeup path, just sourced from the live pick — it already is). The NEW part
   is marking the woken entry `speculative` (a new per-entry bit) and the producer's pick
   "frozen" until grant.
3. **Retain-until-confirmed IQ** (`§5.3(a)`): do NOT free the IQ entry at grant
   (`iq_int:659`); free only when the producer's wakeup is non-speculative (`prf_done` real
   broadcast / load hit confirmed). A squash clears `speculative`+`issued` so it re-selects.
   This removes the load-from-FR bar (`iq_int:457-465`). Costs IQ occupancy → Phase-F IQ growth.
4. **Poison vector** (`§5.4`, size PRF_N): a producer squashed (mis-picked / load-miss) poisons
   its pdst; consumers woken on a poisoned pdst self-squash (transitive). Clears on real
   re-execute. Reuses the `prf_ready`/`prf_done` split (`§6.1`): speculative = `ready=1,
   done=0, poison-able`.
5. **Speculation depth bound** (`§5.5`): ≤1–2 outstanding speculative loads; beyond, fall back
   to broadcast wakeup. Bounds replay storms + poison fan-out.

## 4. Staging (de-risk: ALU-class speculation first, load replay last)

- **A0 — A-EXE flip first (committed scaffold E1/E2 `4ff4b54`/`a4dc093`).** Register the CDB
  (`EX_PIPE=1`) + bypass. Cuts the CDB-snoop (12.320) front that A-LOOP's pipelined select
  *surfaces*. ⚠️ Carries §1.0b: a stalled AMO/LR/SC re-fires its issue-time side-effects
  (`issue_amo_read` dcache RFO) — must be solved (hold + backpressure with side-effect
  suppression). Validate: litmus N2/N4 + SMP.
- **A1 — pipelined select + ALU-class speculative wakeup, NO load replay.** Add the select
  register + the `speculative` bit + the pick-freeze. Loads STAY broadcast-woken (no load
  speculation yet). Misspeculation only from the select pick changing → squash (rare). This
  splits the 126-level loop into 2 stages and keeps ALU 1/cycle. **Measure: does the loop
  drop to ~6.5 ns?** (the headline question — only answerable AFTER the wall bundle is cut to
  expose the loop, so this co-flips with the bundle). IPC: the rare ALU-pick squash.
- **A2 — speculative load wakeup + replay (the 80 %).** Add load speculative wake @
  grant+HIT_LATENCY + the poison vector + selective squash + re-wake on fill + the depth
  bound. Full SMP/litmus re-verification (§7). Only if A1's load-use (loads still broadcast)
  blows the ~10–15 % IPC budget.
- **AF — collapsing/age-ordered IQ (optional, if A1/A2 select stage still > budget).** Replace
  the age-argmin select with a position-encoded priority select (entries physically ordered by
  age), so the select stage is a priority-encode not an argmin. Big structural change; only if
  the select half is still the binding ~6.5 ns after pipelining.

## 5. SMP / correctness (non-negotiable, §7)

- **Atomics (AMO/LR/SC) are NEVER speculatively woken or replayed** — they issue at the ROB
  head, commit single-cycle (the proven +1-cy-breaks-atomicity constraint). Exclude from the
  speculative tier.
- **Replayed loads re-observe coherence**: a squashed load re-reads through dcache/MESI as a
  FRESH access (no stale Stage-B latch), re-evaluating `i_block_*` store-ordering at re-issue.
- **The select-pick freeze** must not deadlock (a frozen pick whose grant never comes — bound
  it / release on back-pressure).
- Gate ladder EVERY step: default 252/0 · backend-validate · ACT4 696 · litmus N2/N4 · N2/N4
  SMP boot · Verilator. Dual metric: CP + IPC (boot-cy/CoreMark/Dhrystone).

## 6. The measurement dependency (why this co-flips with the bundle)

The keystone loop is masked under the ENTIRE upper band (commit-store 14.13 · vrf 13.88 · FP
fround · HPM · CDB-snoop 12.32 · redirect 13.35). So A-LOOP's CP effect — does the pipelined
loop actually reach ~6.5 ns? — is **only measurable after the bundle is cut** (commit-store
[done] + vrf + dcache + FP + A-EXE). A-LOOP is therefore built + functionally/SMP-validated as
structure first, and its CP confirmed in the coordinated bundle flip. The order: **A-EXE flip
→ A1 (pipelined select + ALU spec wakeup) DEAD scaffold → bundle-flip-measure → A2 (load
replay) if budget demands.**

## 7. Roadmap (multi-session)
1. **A-EXE flip** (A0) — solve §1.0b, flip EX_PIPE, full ladder. The down-payment + surfaces
   the CDB-snoop A-LOOP will need cut.
2. **A1 DEAD scaffold** — select register + `speculative` bit + pick-freeze, param-gated
   (`SEL_PIPE=0` byte-identical). FF-insertion: confirm the loop splits. **✅ A1.0 landed
   (the loop-split core — register the scheduled-wakeup pdst). A1.1 (1/cycle recovery)
   pending — see §9.**
3. **A1 flip in the bundle** — measure the loop floor (~6.5 ns?); IPC.
4. **A2** — load speculative wakeup + replay, if needed for the load-use IPC.
5. **AF** — collapsing IQ, if the select half is still binding.

## 9. ✅ A1.0 implementation status (2026-07-01) — the loop-split core landed DEAD

`SEL_PIPE` scaffold (`iq_int.veryl`, `const SEL_PIPE: bit = 0`). User chose "A1 pipelined-
select scaffold" (over A-EXE flip / vrf VALU_PIPE) as the next FINAL-structure increment.

**What landed (the unambiguous loop-split half — register the wakeup):** the keystone loop is
`rs*_rdy → cand0/argmin → sched_wake0 (sh_rd_pdst[issue_idx] dyn-mux → per-entry compare) →
rs*_rdy`. A1.0 registers the SCHEDULED-WAKEUP pdst/en (`sel_wake{0,1}_pdst_q`/`_en_q`) AFTER
the argmin + `sh_rd_pdst[pick]` dyn-mux:
- stage 1 (deep)   = `cand0/argmin + sh_rd_pdst[issue_idx]` → `sel_wake0_pdst_q`
- stage 2 (shallow) = `sel_wake0_pdst_q → per-entry compare → rs*_rdy` write
The SCHED_WAKEUP application reads `if SEL_PIPE ? sel_wake*_q : sched_wake*`; the register is
written unconditionally (a comb `let`) and cleared on reset + `i_flush` (a squashed producer
must not wake late). **The grant (FR capture / IQ-slot free) stays LIVE at N** — only the
in-loop wakeup half is pipelined here, so there is NO second grant-pipeline stage (no extra
issue latency, no retain-until-confirmed `pending` needed for A1.0).

**Why this is the right first cut, not the §1 "wakeup off live pick":** §1's 1/cycle design
keeps the wakeup combinational off the LIVE argmin at N (deep, in-loop) and pipelines the
*grant* — but the grant is NOT in the §6 12.9 ns path (`head → … → argmin → sched_wake0 →
rs1_rdy`), so pipelining it alone would not split the measured loop. Registering the WAKEUP
pdst *is* a register inside that exact path → it splits the 126-level loop. The cost: at
`SEL_PIPE=1` the wakeup lands one cycle LATE (it coincides with the producer's real CDB
broadcast, so the CDB snoop would have woken the consumer anyway — **conservative, never a
stale read**, only the +1-cy dependent-issue IPC of losing the SCHED_WAKEUP head-start).

**Validation (DEAD = byte-identical at SEL_PIPE=0):** `veryl check` clean (the only warnings
are the pre-existing dcache/icache `missing_reset` on RAM arrays + `dmem_wstrb`; the new
`sel_wake*_q` are reset). default **252/0**, litmus N=2 **cy=0022a330** (identical to
baseline), N1 boot **4/4** (linux 7.1 **cy=01210060** — cycle-exact with baseline),
**backend-validate 252/0** (cc vs cranelift no divergence). DEAD scaffold is byte-identical.

**FF-insertion synth — the loop SPLITS (confirmed, `veryl synth --top heliodor_core
--dump-timing --timing-paths N`, throwaway flips reverted):** the wakeup loop is masked under
the upper band, so it is read at `FETCH_REG=1` (which cuts the front-end allocate path so
`rs1_rdy`'s dominant path becomes the wakeup loop, exactly the §6 setup):

| config (FETCH_REG=1 +) | `head → rs1_rdy[0]` | global top (unchanged) |
|---|---|---|
| SEL_PIPE=0 | **12.920 ns / 126 levels** (#7778) — the §6 loop, reproduced exactly | n_inflight 14.130 · vrf 13.880 |
| **SEL_PIPE=1** | **< 11.080 ns** (absent from the top 25 000 paths; was #7778 at 12.920) — **dropped ≥ 1.84 ns / ≥ 15 levels** | n_inflight 14.130 · vrf 13.880 (identical) |

The registered `sel_wake0_pdst_q` carries the stage-1 (argmin + `sh_rd_pdst[pick]` dyn-mux)
boundary; it too is < 11.080 (an anonymous endpoint), so the **new loop floor is the argmin /
ROB-block-scan half (~11 ns)** — the wakeup tail registered cleanly OUT of `rs1_rdy`. This is
the expected partial cut from a SINGLE register in a 126-level distributed loop: it confirms
the register is correctly placed IN the loop (the scaffold works), and that reaching the
~6.5 ns target needs A1.1 (speculative wakeup off the live pick) + AF (collapsing/age-ordered
IQ to shorten the argmin half). The global CP is unchanged (the loop is masked under
n_inflight/vrf) — its true floor is a bundle-flip measurement (§6 dependency).

**SEL_PIPE=1 standalone flip — IPC cost measured + ONE corner exposed (throwaway flip, reverted).**
A1.0's late wakeup loses the SCHED_WAKEUP head-start (dependent ALU chains fall back to the CDB
snoop), so the cost is a +1-cy dependent issue. Measured on Linux boot (cy, vs SEL_PIPE=0):

| boot | SEL_PIPE=0 | SEL_PIPE=1 | Δ |
|---|---|---|---|
| 7.1 | 0x1210060 | 0x1265790 | **+1.85 %** |
| 7.1 V | 0x13cc5c0 | 0x1421cf0 | **+1.7 %** |
| 6.6 | 0x13ee8a0 | 0x1590050 | **+8.2 %** |

So the head-start matters (6.6 is dependent-chain-heavy) → **A1.1 (the 1/cycle recovery) is
justified, not optional.** Functionally the SEL_PIPE=1 flip is clean — default **251/0 (only
`test_arch_hlv` fails)**, all 4 boots PASS — so the +1-cy late wakeup is safe everywhere EXCEPT:

🚨 **`test_arch_hlv` wrong-result at SEL_PIPE=1 (RTL, BOTH backends `tohost=0x100`=fail1) — a
PRE-EXISTING latent core ordering hole exposed by the re-timing, NOT an A1.0 defect.** fail1 is
`hsv.d t3,(GVA 0x2000)` then a cross-check `ld t1,(HPA 0x80030000)` (the GVA two-stage-maps to
that HPA) → `bne t1,t3`. Store-to-load disambiguation is VA-based and **only sound when VA==PA**
(`heliodor_core.veryl:433-437`): under an MMU it falls back to conservative ordering via
`dmem_vm_on → ROB i_conservative`, BUT an **HLV/HSV (`dmem_op_hlv`) is deliberately NOT folded
into `i_conservative`** (`:442-449`, to break a `dmem_op_hlv→i_conservative→ROB-scan→commit→
dmem_op_hlv` combinational loop). So an HSV store (VA 0x2000 ≠ PA) does not make a following
bare load to the SAME PA (VA 0x80030000 == PA, non-conservative) wait/forward; with the
baseline timing the HSV commits before the load reads (passes), but A1.0's re-timing lets the
load read stale. This is a real latent bug ANY timing perturbation could trip. Narrow
(HSV-specific; all non-HSV tests + all boots pass).

✅ **FIXED (commit `7efed5d`).** An in-flight HLV/HSV store (`sh_is_store && sh_mem_virt`;
`sh_mem_virt` already == the op's `hlv` marker — set ONLY for HLV/HSV, not ordinary V=1
accesses) is now an **unconditional ROB block-scan blocker** (`rob.veryl:755`): younger loads
wait until it commits, then read via the PA-based committed-store buffer. No new per-entry flag
needed (sh_mem_virt existed); the comb loop is sidestepped because the blocker is a *registered*
ROB-entry property, not the live `dmem_op_hlv`. HLV loads (is_store=0) excluded; ordinary V=1
stores (sh_mem_virt=0) keep S15 offset-compare + replay → no guest perf regression. One added
term, byte-identical for non-HSV. Validation: default **252/0 at BOTH SEL_PIPE=0 and SEL_PIPE=1**
(hlv PASS both, both backends — the A1.0-exposed hole is closed); hv boot (full hypervisor Linux)
PASS cy=0165f8a0; N1 boot 4/4 all cy cycle-exact with baseline. The A1.0 bundle-flip prerequisite
is cleared.

**A1.1 — the 1/cycle recovery (next sub-step, the `speculative`/freeze/squash half), DEFERRED
to the bundle flip:** to claw back the +1-cy dependent-issue at `SEL_PIPE=1`, add the
speculative wakeup off the LIVE pick at N (so the critical dependent is still woken same-cycle)
+ the per-entry `speculative` bit + the pick-freeze (1-entry select latch held until grant) +
the mispick-squash (live-pick ≠ confirmed-grant). This is §3 pieces 2/4 and is where the
genuine speculation/replay risk lives — it co-flips and is SMP/litmus-validated in the
coordinated bundle (§6 measurement dependency), not standalone. A1.0 is the byte-identical
foundation it builds on.

🔑 **A1.1 mechanism — the subtlety the A1.0 measurement forces (READ THIS before implementing).**
A1.0 split the loop UNBALANCED: `rs1_rdy` dropped 12.920 → < 11.080, but stage-1
(argmin + ROB-block-scan + `sh_rd_pdst[pick]` dyn-mux → `sel_wake0_pdst_q`) is itself < 11.080
— i.e. the argmin half is still ~11 ns, NOT ~6.5. So the wakeup tail was never the deep part;
the ARGMIN is. Consequence for A1.1: the naive §3-piece-2 phrasing "speculative wakeup off the
LIVE pick at N" does **not** recover 1/cycle *cheaply* — the live pick IS the argmin output, so
waking off it re-introduces the full ~11 ns argmin cone into the loop (exactly the 12.9 ns path
A1.0 just registered out). A wakeup that is BOTH 1/cycle AND shallow must be **decoupled from
the current-cycle argmin**. Two real options (pick in the next session):
- **Grandparent-style latency-speculative wakeup** (the classic): wake a consumer off a
  *registered* producer-ISSUE event (the producer that granted last cycle → `sel_wake0_pdst_q`,
  which A1.0 already registers), predicting the parent issues on schedule; confirm at the
  parent's real grant, squash+re-wake on mispredict. Shallow (register→compare) AND keeps
  dependent issue flowing — but the prediction can be wrong (parent's other operand not ready),
  hence the `speculative` bit + squash + poison (→ A2 load replay reuses the same machinery).
- **AF — collapsing / age-ordered IQ** (`§4 AF`): replace the age-argmin with a position-encoded
  priority select so stage-1 itself drops from ~11 ns to a priority-encode. This attacks the
  argmin depth directly rather than speculating around it. Bigger structural change.
A1.0's `sel_wake0_pdst_q` (the registered producer pdst) is already the right hook for the
grandparent scheme. The `speculative`/freeze/squash of §3 pieces 2/4 attach here.

## 8. Anchors
- `iq_int.veryl:324-366` select (cand/argmin/issue_idx) · `:384-401` o_issue_* (the grant) ·
  `:487` slot0_grant · `:500-503` sched_wake · `:573-642` rs*_rdy writes · `:659` FR slot free ·
  `:457-465` load-from-FR bar (removed by retain-until-confirmed).
- `speculative_wakeup_design.md §4` (no-replay-first staging), `§5` (replay mechanism), `§6`
  (latency tiers), `§7` (SMP). `cp_a_sched_scheduler_pipeline_plan.md §6` (the 126-level
  measurement — why pipeline not shorten). A-EXE: `heliodor_core.veryl EX_PIPE` + §1.0b.

## 10. A1.1 design — grandparent speculative wakeup (the 1/cycle recovery), grounded

User chose the **grandparent** option (2026-07-01, over AF collapsing-IQ) as the A1.1
mechanism. This section is the code-grounded design; the scaffold is `SPEC_WAKE` in
`iq_int.veryl`.

### 10.1 The key simplification the A1.0 code already gives us (why ALU-class needs NO replay)

`speculative_wakeup_design.md §6.1` + the existing FR: heliodor **already** does
"speculative select, confirmed present, no replay." A consumer selected off the SCHEDULED
wake is captured into the FR and its PRESENT is gated by `fr0_src_done = prf_done[sources]`
(`iq_int.veryl:404-407`). `prf_done[P]` is set ONLY at P's REAL CDB broadcast
(`:615,631`), never at a scheduled/speculative wake. So a consumer that was woken
early **cannot read a stale operand** — if its producer has not really executed, the FR
simply **holds** it (does not present). This is the whole no-replay guarantee, and it is
INDEPENDENT of *how* `rs*_rdy` got set. Consequence:

> **For the ALU/fixed-latency class, grandparent mis-speculation is resolved by HOLD
> (FR + `prf_done`), not by squash/replay.** Waking a consumer early off a wrong
> grandparent prediction only makes it *select* early; the FR holds it until the producer
> truly executes. No stale read, no poison, no re-issue. The poison/squash machinery of
> `§5` is for the LOAD class (A2), where a load MISS makes an *already-presented* operand
> genuinely garbage. A1.1 (ALU) does not need it.

### 10.2 The mechanism (grandparent = register the newly-ready op's pdst one cycle early)

The A1.0 loop split is UNBALANCED: `rs1_rdy` dropped 12.9→<11.08 but stage-1
(argmin + `sh_rd_pdst[pick]` dyn-mux → `sel_wake0_pdst_q`) is still ~11 ns, and the
registered wake lands one cycle LATE (the +1.7..8.2 % IPC). The recovery must wake the
consumer BOTH 1/cycle AND shallow → decoupled from the current-cycle argmin (`§9`).

Timeline of a dependent ALU chain `O → P → C → D` (all in the IQ), SEL_PIPE=1+SPEC_WAKE=1:
```
T-2: O selected. sched_wake0(O) → registered → sel_wake0_pdst_q at T-1.
T-1: apply sel_wake0_pdst_q = O.pdst → wake P (P now fully ready).
     DETECT: P became newly-fully-ready via this wake → register P.rd_pdst → gp_wake0_pdst_q at T.
T  : apply sel_wake0_pdst_q = P.pdst (conservative, P selected T-1) → wake C.
     apply gp_wake0_pdst_q = P.rd_pdst (SPECULATIVE grandparent) → ALSO wake C, one cycle EARLIER
        than the conservative wake would alone → C ready at T (not T+1).   ← the recovered cycle
     DETECT: C newly-ready → register C.rd_pdst → gp_wake0_pdst_q at T+1.
T+1: C selected. apply gp_wake0_pdst_q = C.rd_pdst → wake D early. …chain self-sustains 1/cycle.
```
The chain **primes itself**: once any op is scheduled-woken, the grandparent register
carries the prediction forward so every subsequent op in the chain is spec-woken 1/cycle.
Only the chain's ENTRY op (whose producer was not scheduled-woken — e.g. a load/div CDB
broadcast, or a long-ago producer) still eats A1.0's +1cy. For tight ALU chains (the 6.6
boot's +8.2 % case) that recovers nearly all of it.

The **predictor** = "an entry made NEWLY-FULLY-READY by this cycle's applied wake":
```
becomes_ready0[i] = occupied[i] && sh_has_rd[i] && !(rs1_rdy[i] && rs2_rdy[i])
                 && (rs1_rdy[i] || woke0_rs1[i]) && (rs2_rdy[i] || woke0_rs2[i])
                 && (woke0_rs1[i] || woke0_rs2[i])
```
where `woke0_rs*[i]` = the applied conservative wake (`aw0 = SEL_PIPE ? sel_wake0_*_q :
sched_wake0_*`) matches entry i's rs*. Pick the OLDEST such i (reuse the `pick_oldest`
argmin tree over `{becomes_ready0[i], age, i}`) → `gp_wake0_pdst = sh_rd_pdst[that i]`,
registered → `gp_wake0_pdst_q`. The prediction is "that op (now ready) is selected next
cycle"; the grandparent wake pre-wakes ITS consumers a cycle early.

### 10.3 Why the spec wake is shallow (the CP claim to FF-measure)

- **Predictor stage** (cycle T): `aw0 (register/live) → becomes_ready0 compare + pick_oldest
  tree (depth 3) → gp_wake0_pdst_q (register)`. Bounded, registered out — NOT the argmin.
- **Spec-wake stage** (cycle T+1): `gp_wake0_pdst_q (register) → per-entry compare →
  rs*_rdy write`. Register→compare, identical depth to A1.0 stage-2. Shallow.
Neither stage contains the age-argmin/select cone, so the loop stays split at ~½ each
(the FF-measure question: does `rs1_rdy` stay < 11 ns AND does the boot-cy +1cy recover?).

### 10.4 The one remaining corner (deferred to the bundle co-flip, per §6)

`prf_done`-hold is airtight for stale reads, but a spec-woken consumer selected early
**occupies an FR slot** while it holds. If its (mis-predicted) producer is slow to be
re-selected, the FR slot is head-of-line-blocked → a THROUGHPUT loss, and — if BOTH FR
slots wedge on producers that each need the other's slot — a potential DEADLOCK. The
resolution is `§5.3(a)` retain-until-confirmed + `§5.5` a speculation depth bound (only
spec-wake when the FR can drain), co-designed with Phase-F IQ growth. Per `§6` this is
validated at the coordinated bundle flip (SMP/litmus), not standalone. The scaffold builds
the byte-identical structure; the bound/retain is the next sub-step.

### 10.5 Scaffold scope (`SPEC_WAKE`, DEAD = byte-identical) and deferrals

**In the scaffold (this increment):** slot-0 grandparent predictor register
(`gp_wake0_{en,pdst}_q`) + the `becomes_ready0` detection + the slot-0 speculative-wake
application lane, all gated `if SPEC_WAKE` (const 0). Byte-identical proof = A1.0's: the
new registers are written unconditionally from comb detection but READ only inside the
`if SPEC_WAKE` block → const-folded away / DCE'd at =0; `rs*_rdy` and all outputs are
unaffected. The spec-wake sets `rs*_rdy` for EXISTING entries only (no `prf_ready` seed of
new renames, no `prf_done` — PRESENT stays gated by the real broadcast).

**Deferred (documented next sub-steps):** (1) slot-1 grandparent (mechanical mirror of
slot-0 off `sw1`/`sched_wake1`); (2) recursive spec→spec chaining (register newly-ready
detected off the spec-wake too, not just the conservative wake) for chains longer than one
grandparent hop; (3) `rs*_spec` per-operand bits + the FR-HoL bound/retain (§10.4); (4)
the A2 load poison/replay. The scaffold is the structural seed; correctness of `=1` (incl.
the FR-HoL corner) is a bundle-flip measurement.

### 10.6 Anchors (A1.1)
- Applied conservative wake `aw0`: mirror of `iq_int.veryl:664-667` `sw0` at module level.
- Predictor detection + register: near the `sel_wake0_pdst_q` write (`:690-698`).
- Spec-wake application: after the `SCHED_WAKEUP` block (`:659-699`), gated `SPEC_WAKE`.
- `prf_done` present-gate (the no-replay guarantee): `:404-407` `fr0_src_done`, `:615,631`.

### 10.7 ✅ MEASURED (2026-07-01) — the spec-wake lane IS shallow (CP), and the =1 flip is DEADLOCK-limited (§10.4), NOT stale-read (§10.1 holds)

Throwaway flips (reverted; the committed scaffold stays DEAD). Two independent results:

**CP (FF-insertion synth, `FETCH_REG=1 + SEL_PIPE=1 + SPEC_WAKE=1`, `--timing-paths
25000`, threshold = 11.080 ns):**

| endpoint | path | reading |
|---|---|---|
| global CP | 14.130 ns `head→n_inflight[5]` | UNCHANGED (loop masked under n_inflight/vrf) |
| `rs1_rdy` / `rs2_rdy` | **absent** (< 11.080) | same as SEL_PIPE=1 alone → **SPEC_WAKE does NOT re-deepen the loop** |
| `gp_wake0_pdst_q` (the spec-wake predictor reg) | **absent** (< 11.080) | the predictor stage (aw0-reg → detect + pick_oldest tree → reg) is SHALLOW |
| `sel_wake0_en_q` | 11.200 ns (#21053) | the A1.0 stage-1 (argmin) half, unchanged |

→ The grandparent spec-wake is register→compare shallow as designed (§10.3): it keeps the
loop split (~11 ns argmin + shallow wakeup) and adds NO new deep path. Reaching ~6.5 ns
still needs AF (shorten the ~11 ns argmin half, `§9`).

**Functional (`SEL_PIPE=1 + SPEC_WAKE=1`, no FETCH_REG needed):** SEL_PIPE=1 ALONE is
**252/0**; adding SPEC_WAKE=1 → **217/252, 35 fail**. The failures are HANGS, not wrong
values: a failing test (`rv64ui-st_ld`) has `tohost=0` (never completed = timeout),
litmus N=2 runs to its `cy=0x1c9c380` cap with `tohost=0`. **tohost=0 = deadlock, not a
mis-computed result.** So:
- **§10.1 holds** (no stale reads — every failure is a hang, never a wrong `tohost` value).
  The `prf_done` PRESENT-hold really is airtight; a spec-woken ALU consumer never
  mis-computes.
- **The gating corner is exactly §10.4: the FR head-of-line DEADLOCK.** A spec-woken
  consumer is SELECTED early, captured into the FR, and FREES its IQ slot (`iq_int:716`);
  it then HOLDS on `prf_done[producer]`. If the producer it waits on needs that same FR
  slot to execute (both FR slots can wedge on producers that each need the other's slot),
  no one drains → deadlock. This is why the note deferred `=1` correctness to the bundle:
  it needs **retain-until-confirmed** (`§5.3(a)`: do not free the IQ slot at spec-select,
  keep it re-issuable) + a **speculation depth bound** (`§5.5`: only spec-wake when the FR
  can drain), co-designed with Phase-F IQ growth.

**Refinement landed from the measurement:** the spec-wake is now restricted to
FIXED-LATENCY ALU-class CONSUMERS (`spec_ok` = not load/store/amo/csr/fp) — a memory-op
consumer spec-woken breaks its issue-side-effects/ordering (measured: `lh`/`amoxor`
failed even harder without the gate). This is the correct §10.1 scoping, but it is NOT
sufficient alone (the deadlock is a producer/FR-slot problem, independent of consumer
class).

### 10.8 ✅ DEADLOCK FIXED (2026-07-01) — restrict the PREDICTOR to ALU-class producers; =1 now boots + IPC partially recovered

The §10.4 FR head-of-line deadlock has a specific single root, found by the ordering
argument: argmin is oldest-first, so **a producer is always OLDER than its consumer and is
selected first**; a pure dependency chain drains from its (executed) root and cannot wedge.
The one wedge is a consumer spec-woken off a **slot-0-only producer** (load/amo/csr) — the
consumer holds `fr0` waiting `prf_done[producer]`, but that producer needs `fr0` to execute
→ neither drains. An **ALU/branch/mul producer runs on EITHER FR slot**, so the consumer
always drains (the producer takes the other slot). Fix = gate the predictor `becomes_ready0`
with `prod_ok` (the `pipe1_ok` set: not load/store/amo/csr/fp/div). This is exactly A1.1's
scope (ALU-class, no load speculation → A2). div is excluded too (many-cycle → long FR hold).

**MEASURED (`SEL_PIPE=1 + SPEC_WAKE=1`, predictor+consumer both ALU-gated):**
- **Deadlock GONE, full functional ladder green:** default **252/0** · litmus N=2 **pass**
  (`cy=0022f150`) · litmus **N=4 pass** (`cy=0x530200`) · N1 boots 7.1/7.1-V/6.6 all pass ·
  **N2 SMP boot pass** (`cy=0x00fef970`). The spec-wake touches only ALU dependency wakeups,
  never the memory-ordering path, so SMP/litmus are unaffected (confirmed).
- **IPC partially recovered** (boot cy, vs A1.0 = SEL_PIPE=1/SPEC_WAKE=0):

  | boot | baseline | A1.0 | A1.1 | A1.1 residual | recovered |
  |---|---|---|---|---|---|
  | 7.1 | 0x1210060 | 0x1265790 (+1.85%) | 0x1265790 | +1.85 % | 0 % |
  | 7.1-V | 0x13cc5c0 | 0x1421cf0 (+1.7%) | 0x1404830 | +1.1 % | ~34 % |
  | **6.6** | 0x13ee8a0 | 0x1590050 (**+8.2%**) | 0x14ccb50 | **+4.35 %** | **~47 %** |

  The grandparent recovers ~half of the heavy dependent-chain case (6.6). It is a SINGLE
  slot-0 hop, so it does not recover everything: the rest is the deferred **slot-1
  grandparent** (mirror off `sw1`) + **recursive spec→spec chaining** (register newly-ready
  detected off the spec-wake, for chains > 1 grandparent hop). 7.1 recovers 0 % — its small
  +1.85 % is not the ALU-chain kind the single-hop grandparent covers.

**Status:** the `=1` flip is now FUNCTIONALLY VIABLE and ladder-validated (default + litmus
N2/N4 + N1 boots + N2 SMP). The predictor-ALU restriction avoids the *measured* deadlock and
the ordering argument suggests it cannot wedge; **retain-until-confirmed (§5.3a) remains the
rigorous belt-and-suspenders** for any rarer FR-HoL corner and is co-designed with Phase-F
IQ growth.

### 10.9 ✅ A1.1 COMPLETE (2026-07-01) — TWO lanes + RECURSIVE chaining; 6.6 IPC recovered ~82 %

Extended the single-slot-0 hop to the full mechanism: the predictor now scans entries made
newly-ready by ALL of this cycle's +1cy/spec wakes — `{aw0, aw1}` (both scheduled/sel slots)
PLUS last cycle's speculative `{gp0, gp1}` (the RECURSION, gated to ALU consumers like the
application) — and registers the **OLDEST TWO** ALU-producers `gp_wake0`/`gp_wake1`
(mirroring `issue_idx`/`issue_idx2`); the spec-wake applies BOTH lanes. slot-1 covers the
2-wide issue; recursion carries a dependent chain > 1 grandparent hop. Still ALU-producer-only
(`prod_ok`), so the §10.8 deadlock-safety holds unchanged.

**MEASURED (`SEL_PIPE=1 + SPEC_WAKE=1`, 2-lane + recursive):**
- **Functional ladder green** (deadlock-free): default **252/0** · litmus N=2 pass
  (`cy=0022a330`, now baseline-exact) · litmus N=4 pass (`cy=0x530200`) · N1 boots pass ·
  **N2 SMP pass** (`cy=0x00fe3620`).
- **CP still shallow** (FF-insertion synth, FETCH_REG=1): `gp_wake*` / `rs1_rdy` / `rs2_rdy`
  all **absent < 11.080** (the recursion + slot-1 add no deep path), global CP 14.130 unchanged.
- **IPC — the recovery largely closed:**

  | boot | baseline | A1.0 | A1.1 slot-0 | **A1.1 2-lane+rec** | recovered |
  |---|---|---|---|---|---|
  | 6.6 | 0x13ee8a0 | 0x1590050 (+8.2%) | 0x14ccb50 (+4.35%) | **0x1437c80 (+1.44%)** | **~82 %** |
  | 7.1-V | 0x13cc5c0 | 0x1421cf0 (+1.7%) | 0x1404830 (+1.1%) | **0x1406f40 (+1.15%)** | ~31 % |
  | 7.1 | 0x1210060 | 0x1265790 (+1.85%) | 0x1265790 (0%) | **0x124f800 (+1.37%)** | ~26 % |

  The heavy dependent-chain case (6.6) drops from +8.2 % to **+1.44 %** — the keystone's
  1/cycle recovery is now essentially complete. Residuals are all ≤ +1.44 %, comfortably
  inside the ~10-15 % campaign budget.

**Status:** A1.1 (the grandparent speculative wakeup — the keystone's 1/cycle recovery) is
FUNCTIONALLY COMPLETE and ladder-validated (default + litmus N2/N4 + N1 boots + N2 SMP) and
its CP/IPC measured. Scaffold stays DEAD-committed (`SPEC_WAKE=0` byte-identical). The CP
benefit is still MASKED (global CP 14.130, loop under n_inflight/vrf) — the PERMANENT flip is
a coordinated-bundle decision (§6). Remaining before that: ACT4 (S-mode paging), N4 SMP,
Verilator. **The next major CP lever is AF (age-ordered/collapsing IQ) to shorten the ~11 ns
argmin half** — its trigger (the select half still binding after pipelining, §4) is now
confirmed. retain-until-confirmed / A2 load replay stay deferred (only if the ALU-class
budget or load-use demands). **[SUPERSEDED by §10.11 — the visible binding scheduler front is
the LOAD grant-gating leak (A2), not the argmin (AF); see below.]**

### 10.10 ✅ A1.1 DEAD scaffold was NOT synth-CP-neutral — gp_wake reg-D gate (2026-07-01, commit `d0c2be9`)

Measuring the committed default (`FETCH_REG=SEL_PIPE=SPEC_WAKE=0`, all DEAD) exposed a
regression A1.1 (`f9f5644`) shipped: the synth #1 was **16.780 ns / 176 levels →
gp_wake1_pdst_q**, not the documented 14.565. The predictor wrote `gp_wake{0,1}_q`
UNCONDITIONALLY on the theory that at `SPEC_WAKE=0` the register Q is unused → the cone
"const-folds / DCEs away". True in SIM (Q unused → byte-identical) but FALSE in `veryl synth`:
**the synthesizer does NOT DCE an unused REGISTER, only the fanout of its Q.** So the recursive
2-lane predictor cone (`… → rs1_rdy → cand_gp0 → gp0 argmin → cand_gp1 → gp1 argmin (the
recursion = TWO argmins in series) → sh_rd_pdst dyn-mux → gp_wake1_pdst_q`) still drove the FF
D — a 16.780 ns DEAD path that became the committed synth #1. Fix: gate the D with the const
param — `gp_wake*_q = if SPEC_WAKE ? <pred> : 0`. Restores 16.780 → **14.565** (`pc_q →
rs1_rdy`, the pre-A-LOOP floor); default 252/0, litmus N=2 cy=0022a330 (byte-identical).
**Methodology rule for the campaign: a DEAD param-gated scaffold that adds a NEW register whose
D-cone does not mirror a live signal is NOT synth-CP-neutral unless the D itself is const-gated.
Sim-byte-identical is necessary but not sufficient — always synth the committed DEAD state.**
(`sel_wake` is safe: its D = `sched_wake0_pdst`, a live signal, so its dead cone already exists.)

### 10.11 🎯 MEASURED plan-revision — the binding scheduler front is the LOAD grant-gating leak (A2), NOT the argmin (AF)

With the baseline clean (§10.10), the `rs1_rdy` scheduler floor was decomposed by exposing the
loop (`FETCH_REG=1 + STORE_PRETRANSLATE=1` → #5670 `head → rs1_rdy[0]` **12.920 ns / 126 levels**,
reproducing §9 exactly). Reading the full trace **overturns the "next = AF" assumption**: the
126-level path is NOT the argmin/age/block-scan. It is the **DCACHE (~7.3 ns) leaking into the
loop via grant-gating**:
```
head → commit_store_fire → dmem_mmu → m_pa_q → u_dcache.i_addr → [RAM Q ×2 + tag-cmp + next_hit
+ miss + victim_way + vic_dirty + fill_blocked + filling + dcache_stall]  (~3.1→10.1 ns, dcache)
→ replay_q → iss_reads_dmem → iq_issue_valid → slot0_grant → prf_ready (dyn-mux ×8) → rs1_rdy
```
i.e. commit-store front (~3.1) + **dcache RAM/miss/fill/stall (~7.3)** + sched_wake tail (~2.5).
The **argmin (cand0/iss0_win), age-subtract, and ROB block-scan (blk_win) are NOT on this path.**
Entry-93's "126 levels distributed (age-subtract/cand/argmin)" was measured only AFTER a throwaway
*grant-gating cut* removed exactly this leak — so there are **TWO co-equal ~12.9 ns fronts to
`rs1_rdy`**:
- **(a) the LOAD grant-gating leak** — `dcache_stall → iq_issue_valid → slot0_grant → sched_wake
  → rs1_rdy`: a load's own single-cycle AGU→MMU→dcache access gates its consumers' scheduled
  wakeup. Cured by **A2** (load speculative wakeup + replay: wake the consumer off SELECT assuming
  load-hit, replay on miss → the dcache leaves the scheduler loop) + eventually dcache pipelining
  (sync-read SRAM) for the ~7.3 ns blob itself. This is the **VISIBLE binding front**.
- **(b) the argmin loop** — age-subtract + cand0 + argmin + dyn-mux + rs*_rdy write. Cured by
  **AF** (collapsing/age-ordered IQ). MASKED under (a).

**Consequence: AF alone cannot move the scheduler floor below ~12.9** — front (a) is co-binding
and AF does not touch it. This **confirms the roadmap order A1 → A2 → AF** (not "next = AF"):
the load grant-gating leak (A2) is the binding front and must be decoupled first; AF's argmin is
masked under it. `dcache ~7.3 ns` (nearly the whole 7.5 budget in one combinational blob) also
independently forces LSU/dcache pipelining for the 7.5 target regardless of the scheduler. A2 is
the A-LOOP "80 % hard part" (genuine load replay, SMP/litmus-sensitive) — see `speculative_
wakeup_design.md §5/§7` + the parked `lsu-phase1-wip` (2-stage load groundwork) + `cp_dcache_
sync_read_plan` (Phase C sync-read).

## 11. A2 — decouple the LOAD grant-gating leak (user-chosen 2026-07-01, the binding front)

User chose A2 (over dcache-sync-read / AF) after §10.11 identified the leak as the visible
binding scheduler front. This section grounds the decouple in the exact code the §10.11 trace
walks through.

### 11.1 The leak, grounded (heliodor_core.veryl + iq_int.veryl)

The scheduled early-wakeup is ALREADY load-excluded — `sched_wake0_en = slot0_grant &&
iss0_pipe1 && sh_has_rd[issue_idx]` (`iq_int:557-560`), and `iss0_pipe1` excludes
load/store/amo/csr/fp/div. So a LOAD never *produces* a sched_wake. The leak is instead the
**GRANT itself** feeding the sched_wake of the *next* (ALU) op, through the 1-deep FR:
- `slot0_grant = FRONT_PIPE ? fr_capture0 : …` and `fr_capture0 = has_issuable &&
  (!fr0_valid_q || fr_drain0) && !i_flush`, with `fr_drain0 = fr0_valid_q && i_issue_ack`
  (`iq_int:543-547`).
- `i_issue_ack` (= core `iq_issue_ack`, `heliodor_core.veryl:2682`) is dcache-gated:
  `(… && iss_dc_ok && … && !iss_is_plain_load && !(lsr_v_q && iq_iss_is_amo) && !amo_fetch_hold)
  || lsr_capture || mshr_capture`, and `iss_dc_ok = !iss_reads_dmem || (!replay_q &&
  (!dcache_stall || ld0_hum_ok || dmem_mmu_acc_fault))` (`:2358`), `iss_reads_dmem = is_load ||
  is_amo` (`:2351`).
So when the FR occupant / current issue is a **dcache-stalling load or AMO**, `i_issue_ack=0`
→ `fr_drain0=0` → `fr_capture0=0` → `slot0_grant=0` → the *next* op's `sched_wake0` stalls →
`rs1_rdy` late. That is `dcache_stall → iss_dc_ok → i_issue_ack → fr_drain0 → fr_capture0 →
slot0_grant → sched_wake0 → prf_ready → rs1_rdy` = the 126-level path. Plain loads already ack
out via `lsr_capture` (Stage-A LSR latch, NOT dcache-gated) — but the LSR is **1-deep +
block-on-issue** (the `!lsr_v_q`-style gates + `!iss_is_plain_load` on the normal path hold the
IQ while a load occupies the LSR), so a stalled load in the LSR still back-pressures the drain.

### 11.2 The decouple (what A2 must change)

Make the **grant / FR-drain / IQ-slot-free independent of an in-flight load/AMO's
dcache-complete**, so `slot0_grant` (hence the following ALU `sched_wake`) fires on schedule and
the dcache leaves the loop. Reusing the A-LOOP §3 pieces:
1. **Retain-until-confirmed IQ (§3.3)** — a load *grants* (fires `slot0_grant`, captures into the
   LSR/FR, frees the select slot for the next op) at Stage-A **without** waiting for the dcache;
   the entry is retained (not freed) until the load's completion is CONFIRMED (hit / fill), and a
   miss **squashes** it (re-select). This removes the `!lsr_v_q` block-on-issue + the `iss_dc_ok`
   drain-gate from `slot0_grant`.
2. **Speculative consumer wakeup + poison (§3.2/§3.4)** — a load's consumers wake at
   grant+`HIT_LATENCY` (assume hit) via the speculative tier (`speculative` bit = `ready=1,
   done=0`, NOT `prf_done`), so they SELECT early but HOLD in the FR on `fr0_src_done` (prf_done)
   exactly like A1.1's ALU spec-wake. On a **dcache miss** the load poisons its pdst → woken
   consumers self-squash (transitive) → re-wake on fill. The A1.1 `prf_ready`/`prf_done` split +
   the FR present-hold is the reusable substrate; A2 adds the **poison vector** (`PRF_N`) and the
   **selective squash** loads (not ALU) need because their misspeculation is a real value-miss,
   not just a pick change.
3. **Depth bound (§3.5)** — ≤1–2 outstanding speculative loads; beyond, fall back to
   broadcast-wake (bounds replay storms + poison fan-out).

### 11.3 SMP / correctness (non-negotiable, §5/§7)

- **AMO/LR/SC never speculate** — they issue at ROB head, commit single-cycle (the proven
  +1cy-breaks-atomicity constraint). The AMO branch of the leak stays dcache-gated (rare: head-
  serialized), so A2 targets the **plain-load** leak; the AMO residual is accepted (or a later
  step). Keep `!(lsr_v_q && iq_iss_is_amo)` / `amo_fetch_hold` as-is.
- **Replayed loads re-observe coherence** — a squashed load re-reads through dcache/MESI FRESH
  (no stale Stage-B latch), re-evaluating `i_block_*` store-ordering at re-issue.
- **The select-slot free must not deadlock** — a retained entry whose confirm never comes must be
  bounded / released on back-pressure. Gate ladder EVERY step: default 252/0 · backend-validate ·
  **ACT4 696** (MEM_PIPE lesson) · litmus N2/N4 · N2/N4 SMP · Verilator. Dual metric CP + IPC.

### 11.4 First step (next session) + open questions

**First scaffold step:** a DEAD param (`LOAD_SPEC`/`A2_PIPE`, =0 byte-identical) that (i) adds the
per-entry `speculative` bit + the `PRF_N` poison vector regs (reset-clean, const-gated D per the
§10.10 rule so the DEAD state is synth-neutral), and (ii) routes a plain-load grant so
`slot0_grant`/slot-free no longer wait on `iss_dc_ok`/`!lsr_v_q` — measured by FF-insertion (loop
exposed via `FETCH_REG=1+STORE_PRETRANSLATE=1`, the §10.11 setup) to confirm the dcache leaves
the `rs1_rdy` path (target: the 12.920 path's ~7.3 ns dcache segment drops out; residual = the
argmin (b), then AF).

**Open questions to resolve at implementation (from the code read, not yet pinned):**
- Exact current LSR depth/semantics in master vs. `lsu-phase1-wip` — how much 2-stage groundwork
  (Stage-A `lsr_capture`, `lsr_v_q`, Stage-B) is already live, and whether block-on-issue is
  full or AMO-only (`iq_issue_ack` shows `!(lsr_v_q && iq_iss_is_amo)`, comment says `!lsr_v_q`).
- Whether the leaked `iq_issue_valid` in the trace is the AMO path or the plain-load `iss_dc_ok`
  residual (disambiguate by a throwaway: force `iss_dc_ok=1` for plain loads and re-measure #5670).
- IPC of retain-until-confirmed (IQ occupancy ↑ → may need Phase-F IQ growth) vs. the parked
  lsu-phase1 finding that the 2-stage load was net-negative on the OLD ~25 ns wall (re-measure on
  the current floor; the negative there was mole-whacking, not the structure).

### 11.5 ✅ MEASURED (2026-07-01) — the leak is TWO plain-load dcache-completion edges (BOTH slot grants), not one; cutting both → rs1_rdy 12.920→11.790, dcache GONE, argmin front (b) exposed

Ran the §11.4 disambiguation (loop exposed via `FETCH_REG=1 + STORE_PRETRANSLATE=1`, `--dump-timing
--timing-paths 25000`; committed default confirmed 14.565 before/after, tree byte-clean). #5670
reproduced exactly: `head → rs1_rdy[0]` **12.920 / 126 lv**, and its trace matched §10.11 (commit-store
front → `m_pa_q` → `u_dcache.i_addr` → tag/hit/miss/victim/fill/state ~6 ns → `dcache_stall` → grant →
`prf_ready` → `rs1_rdy`). Three throwaway STA cuts (all reverted) pinned the leak:

| cut | rs1_rdy | what left |
|---|---|---|
| — (baseline, loop exposed) | **12.920** | slot-0 grant leak visible |
| `iss_dc_ok = 1'b1` (const) | **12.320** | slot-0 edge gone; **slot-1 edge surfaces** |
| + `lsr_read_done = lsr_drive` (drop `!dcache_stall`) | **11.790** | **dcache GONE**; argmin front (b) surfaces |

**Method correction (important):** the first attempt forced `iss_dc_ok=1` for plain loads by ORing a
`(is_load && !is_amo)` term in — this did NOTHING to STA (12.920→12.950). In static timing, `iss_dc_ok
= A || plain_load || (dcache term)` still has the `dcache_stall → iss_dc_ok` topological edge; ORing a
parallel signal does not cut a path (STA follows ALL paths, blind to the fact `plain_load==1` would
functionally mask the dcache term). To cut a path in STA you must make the signal **structurally**
dcache-independent (const, or delete the term). The A2 RTL must likewise make the grant *structurally*
not-in-the-dcache-cone, not merely add an override.

**The two leak edges (both = the in-flight PLAIN LOAD's dcache completion gating the FR drain / grant;
NOT AMO — AMO is head-serialized and off this path):**
- **(a1) slot-0:** `dcache_stall → iss_dc_ok (`:2358`) → iq_issue_ack (`:2682`) → fr_drain0 →
  fr_capture0 = slot0_grant (`iq_int:543-547`) → sched_wake0 → prf_ready → rs1_rdy`. Worth ~0.6 ns.
- **(a2) slot-1:** `dcache_stall → lsr_read_done (`= lsr_drive && !dcache_stall`, `:7057`) → lsr_complete
  (`:7075`) → lsr_lane1_fire (`:7076`) → issue2_fire (`= …&& !lsr_lane1_fire`, `:6913`, drives
  `i_issue_ack2`) → fr_drain1 → fr_capture1 = slot1_grant (`iq_int:544/546/548`) → sched_wake1 →
  prf_ready → rs1_rdy`. Worth ~0.53 ns more. This is the SLOT-1 TWIN of (a1) — the flexible lane-1
  load-completion path (`lsr_to_lane1` = non-fault, non-FP plain load; `lsr_read_done` is its Stage-B
  dcache read landing). **§11.2 only named slot-0 / `iss_dc_ok`/`!lsr_v_q`; the slot-1 `lsr_lane1_fire →
  issue2_fire → fr_drain1` edge is co-equal and MUST also be decoupled.**

With both cut, the residual **11.790 / 126 lv** path is dcache-free and is EXACTLY the argmin loop
(front (b), §10.11): `iss0 argmin tree (slot-0 select) → issue_idx → cand2A build → win2A argmin tree →
has_issuable → sh_rd_pdst → sched_wake1_pdst → prf_ready → rs1_rdy`. That is AF's target, masked under
(a) until now.

**Consequences for A2 (scope refinement):**
1. A2 must decouple **BOTH** slot grants from the in-flight plain-load's dcache completion:
   - slot-0: `fr_drain0`/`slot0_grant` must not wait on `iss_dc_ok` (the load-dcache term) — grant at
     Stage-A select.
   - slot-1: `fr_drain1`/`slot1_grant` (via `i_issue_ack2 = issue2_fire`) must not wait on
     `lsr_lane1_fire`'s `lsr_read_done`/`dcache_stall` — the lane-1 load's grant/slot-free must fire on
     select, retained-until-confirmed, replay on miss.
   Retain-until-confirmed + speculative consumer wakeup + poison (§11.2) is the mechanism for both; the
   scaffold's grant-reroute (§11.4 step) must cover slot-1 as well as slot-0.
2. Expected A2 CP effect (loop-exposed): rs1_rdy **12.920 → ~11.790** (−1.13 ns / −8.7 %), removing the
   dcache from the scheduler wakeup loop entirely. The **argmin front (b) at ~11.79** then becomes the
   scheduler floor → AF (age-ordered/collapsing IQ) is the next lever after A2, exactly the A1→A2→AF
   order. Global CP stays 13.880 (vrf) throughout — A2's win is STRUCTURAL (dcache out of the loop),
   realized as CP only in the vrf+front-end bundle co-flip (§6), per the campaign's "advance FINAL
   structure, not the throttling synth number" guidance.
3. Open-Q1 answered: LSR is **1-deep** (`lsr_capture` requires `!lsr_v_q`, `:6635`), and the normal
   ack-path block-on-issue is **AMO-only** on master (`!(lsr_v_q && iq_iss_is_amo)`, `:2682/2415` — the
   `!lsr_v_q` comment is stale; a non-AMO ALU op DOES ack out while a load sits in the LSR via the
   flexible lane-1 route). So the load-vs-load 1-deep block (`lsr_capture`'s `!lsr_v_q`) is the depth
   constraint A2 must lift (retain-until-confirmed IQ, not the 1-deep LSR).

### 11.6 ✅ MEASURED (2026-07-01) — the AMO residual is CO-DEEP (§11.3 "accept it" is wrong for CP); A2 must FR-decouple AMOs too + grounded implementation

Follow-up STA cut (loop exposed, both slot-1 cut + slot-0 gated dcache-free for every NON-AMO op:
`iss_dc_ok = if iq_iss_is_amo ? <orig dcache-gated> : 1'b1`): **rs1_rdy = 12.950**, dcache STILL on the
path (61 dcache nodes; `dcache_stall → iss_dc_ok(amo branch) → iq_issue_ack → fr_drain0 → slot0_grant`).
So keeping the AMO dcache-gated per §11.3 leaves the slot-0 grant **co-deep** — STA takes the worst
op-type, so the AMO residual FULLY masks the plain-load decouple. **§11.3's "accept the AMO residual"
is correct for IPC (AMOs are rare, head-serialized) but WRONG for CP/synth** (worst-case path). To move
the scheduler floor off 12.9, A2 must cut the AMO grant path structurally too.

Root cause: an AMO in `fr0` that dcache-stalls holds `fr_drain0 = 0` (it must NOT ack out — there is no
AMO holding structure, so it stays in fr0 to re-drive its RFO), which blocks the next op's `slot0_grant`
on the AMO's own dcache. Unavoidable with the 1-deep FR + no AMO retain. NOT a speculation problem (§11.3
correctly bars AMO speculation) — a FR-occupancy problem.

**A2 = THREE decouples, ALL required for the measured 11.790 (not "plain-load first, AMO later"):**
1. **slot-0 plain-load** — already functionally dcache-independent (acks via `lsr_capture`, retains in
   LSR→MSHR on miss). Pure STA artifact: `fr_drain0` uses `i_issue_ack = iq_issue_ack`, whose cone holds
   the `iss_dc_ok` normal-path branch (= 0 for a plain load via `!iss_is_plain_load`, but STA-visible).
   Fix: give the FR-drain a **dcache-free drain-ack** — for a load-in-fr0, drain on `lsr_capture` /
   `mshr_capture` only, not the iss_dc_ok normal branch.
2. **slot-0 AMO** — the new structure A2 adds: a **retain-until-confirmed FR-decouple** for AMO. The
   AMO drains `fr0` into a Stage-B AMO-holding reg at select (freeing fr0 for the next op), is retained
   in the IQ, and completes single-cycle at the ROB head from the holding reg (M3b `amo_fetched_q` /
   `amo_commit_live` semantics preserved). NO consumer speculation, NO poison — the AMO result is not
   spec-woken; only its FR-occupancy is decoupled.
3. **slot-1 plain-load** — `fr_drain1 = fr1_valid_q && i_issue_ack2`, `i_issue_ack2 = issue2_fire`
   gated by `lsr_lane1_fire` (dcache via `lsr_read_done`). Fix: the lane-1 load's grant / slot-free
   fires on select, retained-until-confirmed, replay + poison on miss (the plain-load spec path).

**Shared substrate (reuse A1.1):** retain-until-confirmed IQ (do not free the entry at spec-select;
keep it re-selectable) + the plain-load **poison vector** (`PRF_N`, new) for load-consumer
misspeculation + the A1.1 `prf_ready`/`prf_done` split + FR present-hold. AMO reuses ONLY the retain
(no poison). Depth bound ≤1–2 outstanding spec loads (§3.5). All the SMP/litmus constraints of §11.3
hold: AMO/LR/SC single-cycle commit unchanged, replayed loads re-observe coherence fresh.

**Scaffold plan (LOAD_SPEC=0 byte-identical, any new reg's D const-gated per §10.10):** the pieces do
NOT cleanly separate into a trivial "regs first" step (a DEAD poison vector with const-0 D just DCEs =
dead weight). The first LANDABLE increment is the **slot-0 plain-load FR-drain re-route** (piece 1) —
it is nearly free (loads already retain), touches only the drain-ack structure, and is independently
byte-identical + synth-neutral at =0. Pieces 2 (AMO retain) and 3 (slot-1 load spec+poison) are the
substantive keystone work and co-flip with the retain/poison substrate. Sequence: piece 1 scaffold →
piece 3 (load spec+poison+retain, the "80 %") → piece 2 (AMO FR-decouple) → co-flip measure (target
rs1_rdy 12.920→~11.790, dcache out of the scheduler loop; argmin front (b) ~11.79 next → AF).

### 11.7 🎉 MEASURED (2026-07-01) — WAKE-ON-SELECT collapses A2 to one change: fire the scheduled wake on has_issuable (select), not slot_grant. dcache leaves the loop, NO retain/poison/AMO-decouple needed for CP

Before building the retain/poison keystone (pieces 2/3), a throwaway reframed the leak. The dcache
reaches `rs1_rdy` because the **scheduled wakeup fires on `slot_grant`** (`sched_wake0_en = slot0_grant
&& iss0_pipe1 && sh_has_rd`, `iq_int:580`), and `slot0_grant = fr_capture0 = has_issuable &&
(!fr0_valid_q || fr_drain0) && !i_flush` carries `fr_drain0` (→ `i_issue_ack`/`iss_dc_ok`/dcache) and
`slot1_grant` carries `fr_drain1` (→ `lsr_lane1_fire`/dcache). But the wake does not NEED the grant —
it only needs the producer to be **selected** (won the argmin). Firing it on `has_issuable` /
`has_issuable2A` (the dcache-free argmin front) instead removes `fr_drain` (hence the dcache) from the
wake cone entirely.

Throwaway (loop exposed, `FETCH_REG=1+STORE_PRETRANSLATE=1`, LOAD_SPEC=0/piece-1 dead):
```
sched_wake0_en = has_issuable   && iss0_pipe1 && sh_has_rd[issue_idx]    // was slot0_grant && …
sched_wake1_en = has_issuable2A && sh_has_rd[issue_idx2]                 // was slot1_grant && has_issuable2A && …
```
→ **rs1_rdy 12.920 → 11.790**, **dcache GONE** (0 nodes; path = `has_issuable → sched_wake → prf_ready
→ rs1_rdy` = the argmin front (b)). IDENTICAL to the §11.5 "both edges cut" 11.790. So wake-on-select
achieves the FULL slot-0 + slot-1 decouple in one change — **no retain-until-confirmed, no poison
vector, no AMO FR-decouple needed for the CP win.** Committed synth stays **14.565** (scheduler loop
masked under the front-end at FETCH_REG=0 → CP-neutral at committed default).

**Why it is correct (the A1.1 §10.1 invariant does the work):** the wake sets `rs*_rdy` EARLY, but a
spec-woken consumer captured into the FR still HOLDS on `fr_src_done = prf_done` (the producer's REAL
CDB broadcast) — never a stale read. And unlike A1.1's `gp_wake` (which predicts FUTURE winners and can
wake a consumer before its producer, → the §10.4 deadlock), wake-on-select fires only off the ACTUAL
current argmin winners; the **oldest-first argmin guarantees a producer is captured into the FR before
its (younger) consumer**, so no consumer ever holds the FR slot its producer needs → no §10.4 deadlock.
Flush is handled at the application layer (the `sw0`/`sw1` write is in the `else` (not-flush) branch,
`iq_int:750/799`; the flush branch clears `sel_wake*_en_q`/`gp_wake*_en_q`), so dropping `!i_flush` from
the comb `sched_wake*_en` is safe — the final form restores `!i_flush` anyway for clarity/parity.

**Functional (raw wake-on-select, committed params):** default **252/0** (litmus N2 cy=0022a330,
unchanged) + N1 boot 4/4, and **IPC IMPROVED** — 7.1 cy 01210060→0120d950, 7.1V 013cc5c0→012e6de0
(−4.4 %), 6.6 unchanged. (The early wake recovers the A1.0 +1cy scheduled-wake latency for the
FR-occupancy case.) Ladder (=1): **litmus N4 PASS** (cy=00532910 — the hardest ordering/contention
stress, no deadlock, no forbidden outcome), **N2 SMP boot PASS** (cy=00fc8870 pass=1 — full SMP boot
completes, no deadlock; +10k cy / +0.06 % vs committed, noise), **backend-validate all-passing** (every
rv64ui/uf test dual-backend cc==cranelift, no divergence — timed out mid-suite under box load, not a
fail). N4 SMP boot progressing-normally (cy ~8M/16.6M, PCs advancing, NOT hung) — timed out under box
load; N4-completion + full backend-validate + ACT4 (needs `make -C test/act`) are the residual =1 gates,
co-flipped with the bundle. The two key SMP/ordering gates (N2 SMP + litmus N4) are GREEN → no §10.4
deadlock, no memory-ordering violation.

**Committed (LOAD_SPEC=0, gated, byte-identical): `3eeef8c` sibling — this commit.** Verified DEAD-clean
at =0: synth **14.565** UNCHANGED, default **252/0** (litmus N2 cy=0022a330), N1 boot 4/4 cycle-exact
(smoke 00b6a5d0, 7.1 01210060, 7.1V 013cc5c0, 6.6 013ee8a0). The =1 wake-on-select is the A2 mechanism,
validated (litmus N4 + 252/0 + N1 boots + IPC↑) — the full =1 ladder (SMP completion, backend-validate,
ACT4) co-flips with the bundle.

**Consequence for the roadmap:** A2's CP goal is met by wake-on-select alone, gated under LOAD_SPEC
(with piece 1 as harmless subsumed groundwork — the wake no longer routes through fr_drain0). Pieces 2
(AMO FR-decouple) and 3 (retain-until-confirmed + poison) are now **optional IPC optimisations, not
CP-required** — the "80 % hard part" is BYPASSED for the scheduler-loop decouple. The next floor is the
argmin front (b) ~11.79 → AF, exactly the A1→A2→AF order.
