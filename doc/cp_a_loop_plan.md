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
   (`SEL_PIPE=0` byte-identical). FF-insertion: confirm the loop splits.
3. **A1 flip in the bundle** — measure the loop floor (~6.5 ns?); IPC.
4. **A2** — load speculative wakeup + replay, if needed for the load-use IPC.
5. **AF** — collapsing IQ, if the select half is still binding.

## 8. Anchors
- `iq_int.veryl:324-366` select (cand/argmin/issue_idx) · `:384-401` o_issue_* (the grant) ·
  `:487` slot0_grant · `:500-503` sched_wake · `:573-642` rs*_rdy writes · `:659` FR slot free ·
  `:457-465` load-from-FR bar (removed by retain-until-confirmed).
- `speculative_wakeup_design.md §4` (no-replay-first staging), `§5` (replay mechanism), `§6`
  (latency tiers), `§7` (SMP). `cp_a_sched_scheduler_pipeline_plan.md §6` (the 126-level
  measurement — why pipeline not shorten). A-EXE: `heliodor_core.veryl EX_PIPE` + §1.0b.
