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
foundation it builds on. The FF-insertion synth at `SEL_PIPE=1` (this/next session) measures
whether stage-1 (argmin+dyn-mux) is now the ~6.5 ns half it should be.

## 8. Anchors
- `iq_int.veryl:324-366` select (cand/argmin/issue_idx) · `:384-401` o_issue_* (the grant) ·
  `:487` slot0_grant · `:500-503` sched_wake · `:573-642` rs*_rdy writes · `:659` FR slot free ·
  `:457-465` load-from-FR bar (removed by retain-until-confirmed).
- `speculative_wakeup_design.md §4` (no-replay-first staging), `§5` (replay mechanism), `§6`
  (latency tiers), `§7` (SMP). `cp_a_sched_scheduler_pipeline_plan.md §6` (the 126-level
  measurement — why pipeline not shorten). A-EXE: `heliodor_core.veryl EX_PIPE` + §1.0b.
