# A-SCHED — scheduler-logic shortening (the binding ~12.9 ns select→wakeup loop)

Staged design for **A-SCHED**, the keystone component that is the *binding* pipeline
stage (`deep_pipeline_sram_plan.md` "The keystone (REVISED)"). A-EXE (execute staging,
committed `4ff4b54`/`a4dc093`) and A-LOOP (latency-speculative wakeup + replay) are the
other two. **This is the gate to ~7.5 ns** — without it the realistic floor is the
scheduler depth ~12 ns.

Status: **design, grounded in measurement** (FETCH_REG=1 + `--timing-paths` exposing the
masked loop; all throwaway probes reverted, tree clean). No A-SCHED RTL yet.

---

## 1. The measured floor (MEASURED 2026-06-30, not assumed)

With FETCH_REG=1 (front end cut) the `rs1_rdy[0]` worst path is **12.920 ns / 126 levels,
sourced from `head[0]`** — the scheduled-wakeup SELECT→WAKEUP loop:

```
head[FF] → age = sh_rob_idx[i] − head  (8×)  → blocked/ready → cand0
        → pick_oldest age-argmin tree (depth 3, iq_int:358) → issue_idx
        → slot0_grant (= fr_capture0, gated by i_issue_ack)
        → sched_wake0_pdst = sh_rd_pdst[issue_idx] → == sh_rs1_pdst[i] → rs1_rdy[i][D]
```

### 1.1 What is and is NOT in the loop — four throwaway probes

| probe | result | conclusion |
|---|---|---|
| register the **ROB block-store scan** (`o_block_store_age`, rob.veryl:780) | 12.920 → 12.920 (−3 levels) | **NOT the lever.** The depth-5 ROB argmin is ~0 of the loop. (This **corrects** the plan's first A-SCHED bullet "pipeline the ROB block-scan".) |
| sched_wake from `has_issuable` (drop the `slot0_grant`/`i_issue_ack` grant-gating) | 12.920 → **12.320** | grant-gating (→ dcache `iss_dc_ok`, MMU) = **−0.6 ns, minor** |
| register the **select output** (`has_issuable`+`issue_idx`, 2-stage select), sched_wake from the reg | 12.320 (**unchanged**) | the sched_wake is no longer worst → a **different head-sourced path now binds at 12.320** |
| (that 12.320 path) | `head → argmin → issue_idx → issuing op → ALU execute → cdb → i_cdb_pdst → compare → rs1_rdy` | the **CDB-snoop** wakeup — the EXECUTE cone, **cut by A-EXE (register `alu_cdb`)** |

### 1.2 🎯 Key structural insight — A-SCHED and A-EXE are a COORDINATED PAIR

The 12–13 ns scheduler/execute region is a multi-front wall, all head-sourced:
- **sched_wake select loop 12.920** — cut by A-SCHED (shorten the loop).
- **CDB-snoop 12.320** (`…→ execute → cdb → rs_rdy`) — cut by **A-EXE** (`EX_PIPE=1`, register the CDB).
- an unnamed **13.220 cluster** (`head → [N][0]`, ~hundreds of paths) — IQ/RS-internal select-region nets, the next front behind.
- above them the commit wall (`n_inflight` 14.13, `vrf` 13.88, redirect/mip/hpm 13.2–13.6).

**→ A-EXE is NOT CP-neutral after all** — it is the front *right behind* the sched_wake loop.
Cutting the sched_wake loop (A-SCHED) **surfaces** the CDB-snoop (12.320), which A-EXE then
cuts. They must **flip together** (the committed A-EXE scaffold is exactly this front's tool).
This both vindicates building A-EXE and pins the bundle: **A-SCHED + A-EXE + the 13.220
cluster + the commit wall, flipped together.**

---

## 2. The constraint: SHORTEN the loop, do NOT pipeline it

The select→wakeup loop must close in **one cycle** for back-to-back dependent ALU issue at
1/cycle: a producer granted at N wakes its consumer so the consumer is *selectable at N+1*.
**Pipelining the select** (register the grant, sched_wake at N+1) makes the consumer
selectable at N+2 = **½ dependent-issue throughput** — the probe-3 measurement confirms a
registered select removes sched_wake from the path but does NOT help (the CDB-snoop binds),
i.e. pipelining buys nothing here without also paying IPC. So A-SCHED's job is to **reduce
the combinational depth of the 1-cycle loop**, not add a stage. (A pipelined/speculative
select that *preserves* 1/cycle needs A-LOOP's speculative wakeup + squash — kept as the
last-resort AS-d, since it costs the replay machinery.)

---

## 3. Levers (measure-first; each a DEAD param-gate → FF-insertion → flip)

The loop = `head → age-subtract → age-argmin → issue_idx → wakeup-tail → rs_rdy`, plus the
grant-gating side input.

> **🚨 Ranked by MEASURED/analyzed impact (2026-06-30) — the SELECT argmin dominates, the
> wakeup tail does NOT.** Probe-2 (live argmin+tail, no grant-gating) = 12.320; probe-3
> (registered select) pushed the sched_wake tail *below* the CDB-snoop floor (12.320) — i.e.
> the tail is NOT the binding part of the loop; the **age-argmin is**. So **AS-b is the real
> lever**; **AS-a (wakeup tail) is the SMALLEST** (~1–2 gate levels / ~0.2 ns — the matrix
> swaps a dyn-mux+compare for an onehot+AND-OR of comparable depth, since the producer here is
> a *slot* not a value). Do NOT start with AS-a. Order: **AS-c (free) → AS-b (the lever) →
> AS-d (if forced)**; AS-a only as cleanup if the matrix infra is wanted for AS-d.

- **AS-b — age-ordered IQ / age-matrix (shorten the SELECT ARGMIN — THE LEVER).** Today
  "oldest ready" is an argmin over `age = rob_idx − head` (per-entry head-relative subtract +
  a depth-3 age-compare tree). Replace with an **age-matrix** `M[i][j]=entry i older than j`
  (8×8, REGISTERED, maintained on alloc — youngest row=0, col=occupied): then
  `oldest_ready[i] = ready[i] && AND_{j≠i}(!ready[j] || M[i][j])` — a registered-matrix
  AND-reduction, **removing the age-compare tree from the loop** (keep the `age` value only for
  the `blocked` compare, which is shallow). DEAD param-gate (`AGE_MATRIX=0` → the argmin,
  byte-identical). Must be **bit-exact to the argmin's oldest-ready pick** (SMP/load-ordering).
  High risk: the matrix maintenance on the 2-wide alloc + the slot-1 select must match exactly.
- **AS-c — decouple the grant-gating (−0.6 ns, measured).** `slot0_grant`→`fr_drain0`→
  `i_issue_ack` pulls `iss_dc_ok` (dcache_stall / MMU) into the loop. Make the *wakeup* not wait
  on the current FR op's memory verdict (fire on the argmin pick; a producer that can't drain is
  covered by the `prf_done` present-guard). Small; ⚠️ correctness-subtle (the early-wake +
  present-guard + FR head-of-line must be litmus/boot-validated — NOT free as first thought).
- **AS-d — pipelined/speculative select (LAST resort).** Only if AS-b/c don't reach budget:
  register the select, speculatively wake from the live pick to keep 1/cycle, squash on
  mis-pick. Co-designed with **A-LOOP** (shared speculative-wakeup + poison + SMP).
- **AS-a — dependency-matrix wakeup (the wakeup TAIL — SMALLEST, ~0.2 ns).** Precompute
  `M[prod][cons]=(sh_rd_pdst[prod]==sh_rs1_pdst[cons])` off the loop; tail becomes
  `wake[cons]=OR_prod(grant_onehot[prod] & M[prod][cons])`. Bit-exact, IPC-neutral, but the
  measurement says it barely moves the loop (the argmin, not the tail, binds). Cleanup only.

**Sequencing (corrected):** **AS-b (age-matrix select) is the lever** — start there. AS-c
(grant-gating, −0.6) alongside if its present-guard correctness validates. AS-a (wakeup tail)
is cleanup (~0.2 ns), not first. AS-d only if forced. Each lands as a DEAD param-gate, measured
by FF-insertion, flipped **in the bundle with A-EXE** (the surfaced CDB-snoop front).

---

## 4. Correctness & verification

The select/wakeup is the OoO core's heart — every change is SMP-relevant.
- **AS-a (matrix):** must be **bit-exact** to the current wakeup (same pdst matches). The
  load-ordering `blocked` gate is unchanged (stays in the `ready`/cand path). Gate: default +
  backend-validate + litmus N2/N4 + SMP boot.
- **AS-b (age-ordered IQ):** changes the issue *order* mechanism (not the policy — still
  oldest-ready). High risk: the collapse/shift must preserve the exact oldest-ready pick the
  argmin makes, and the load-ordering age comparisons (`i_block_store_age < age`) must stay
  consistent. Full ladder incl. **ACT4** (the load-ordering corner) + litmus N4 + N4 SMP.
- **AS-c:** the grant/wakeup decouple must not wake a consumer whose producer never drains —
  rely on the existing `prf_done` present-guard (a stalled producer holds the consumer).
- **AS-d:** the full A-LOOP replay matrix (§5/§7 of `speculative_wakeup_design.md`).

Dual metric every step: synth **CP** + **IPC** (boot-cy / CoreMark / Dhrystone, ~10–15 %
budget). Methodology = the proven DEAD-gate → FF-insertion measure → bundle-flip → corner-debug.

---

## 5. Anchors
- `iq_int.veryl:324-366` cand0 build + pick_oldest age-argmin + issue_idx; `:500-503`
  sched_wake0/1; `:573-642` the rs*_rdy writes (CDB-snoop + sched_wake).
- `rob.veryl:740-781` blk_cand + block-store argmin (`o_block_store_age`) — **not** the loop.
- A-EXE scaffold: `heliodor_core.veryl` `EX_PIPE` (`alu_cdb_q`/`alu_cdb_eff`, bypass
  `prf_*_data_b`) — the CDB-snoop front's tool, flips in this bundle.
- `speculative_wakeup_design.md §1.1c` (the measured keystone-floor decomposition), §8.1
  (A-EXE status), §5/§7 (A-LOOP replay, for AS-d).
- Measure: `veryl synth --top heliodor_core --timing-paths N`; expose the masked loop with
  `FETCH_REG=1` (revert after — it is a committed DEAD scaffold).
