# A-SCHED — scheduler-logic shortening (the binding ~12.9 ns select→wakeup loop)

Staged design for **A-SCHED**, the keystone component that is the *binding* pipeline
stage (`deep_pipeline_sram_plan.md` "The keystone (REVISED)"). A-EXE (execute staging,
committed `4ff4b54`/`a4dc093`) and A-LOOP (latency-speculative wakeup + replay) are the
other two. **This is the gate to ~7.5 ns** — without it the realistic floor is the
scheduler depth ~12 ns.

Status: **design, grounded in measurement** (FETCH_REG=1 + `--timing-paths` exposing the
masked loop; all throwaway probes reverted, tree clean). No A-SCHED RTL yet.

---

## 0. 🚨🚨 MEASURED CORRECTION — AS-b is NOT the lever (gate trace, 2026-06-30)

I implemented AS-b as a DEAD param-gate (`AGE_MATRIX`, byte-identical: default 252/0,
synth 14.565 unchanged with the matrix flops DCE'd, N1 7.1 boot cy=01210060 exact) and ran
the de-risking flip. **The matrix is bit-exact** (AGE_MATRIX=1 → litmus N2 cy=0022a330,
*identical* to the argmin) but **it does NOT move the select loop**: at FETCH_REG=1,
`rs1_rdy[0]` is **12.920 ns** with the argmin (126 levels) and **12.920 ns** with the matrix
(123 levels) — **3 gate levels, 0 ns**. The age-argmin tree was never the binding depth.

**Why — the `--dump-timing` gate trace of the `head[0] → rs1_rdy[0]` 12.920 path:**

```
0.00  head[0] (FF Q)
      → commit (sh_rd_arch → arch_regs → c_cas_q_mem_hi → c_is_cas_q)
2.96  → commit_store_fire
      → iq_issue_op → dmem_eff_priv → u_dmem_mmu (vm_enabled) → m_pa_q → dmem_pa_m
4.41  → u_dcache.i_addr
4.94  → RAM Q            (dcache TAG read)
      → next_tag compare → next_hit → miss → srfo_want → index
7.00  → RAM Q            (dcache 2nd read)
      → f_tag → fm_0 → plru_way → victim_way → vic_valid → vic_dirty → fill_blocked_wb
      → load_sel → filling → dc_mem_req → o_dmem_iread → i_dmem_grant → fill_start_fire
      → i_wen → wenl_fires → state
10.13 → dcache_stall → replay_q → iss_reads_dmem → iq_issue_valid
10.84 → fr0_valid_q → has_issuable → slot0_grant
11.27 → prf_ready (×7 mux2 cascade = the wakeup-WRITE arbitration)
12.47 → i_alloc_op → rs1_rdy (×3 mux)
12.92  rs1_rdy[0] (FF D)
```

**~10.5 ns of the 12.9 (80 %) is the `commit-store → MMU → dcache` WALL** — the *same* front
that binds `n_inflight` (14.130) and `valid_*` — leaking into the scheduler through the
**grant-gating** (`dcache_stall → iss_reads_dmem → iq_issue_valid → slot0_grant`). The
remaining ~2.4 ns is the **wakeup tail** (the `prf_ready` write-arbitration mux cascade +
the `rs1_rdy` write mux). **The SELECT (argmin/matrix `has_issuable`) is a side input to
`slot0_grant`, off the binding path — the argmin is a *tiny* fraction.**

**Conclusions (these supersede §1/§3 below):**
1. **AS-b (age-matrix select) is REFUTED as a CP lever** — depth-neutral (3 levels, 0 ns),
   CP-neutral, and the select is not the binding path. It is not FINAL-structure-advancing
   either (it adds 64 FF + maintenance for an argmin that is already cheap on a tie-free
   key). The AS-b scaffold was **reverted** (not committed). The plan's "AS-b is the lever /
   the only road to ~7.5 ns" was wrong.
2. **AS-a (dependency-matrix wakeup) targets the ~2.4 ns wakeup tail** — that tail is real
   (the `prf_ready` cascade + `rs1_rdy` mux), *bigger* than the doc's "~0.2 ns", but it is
   masked behind the grant-gating + the wall, so it is not first either.
3. **The scheduler's actual CP contribution is AS-c (decouple grant-gating)** — but the
   grant-gating *is* the dcache wall leaking in, and cutting it only exposes the CDB-snoop
   (12.320, cut by **A-EXE**), with the global CP still pinned by the wall (14.130). So the
   scheduler region only moves **inside the coordinated bundle** with the commit-store/dcache
   wall (Phase C dcache sync-read) + A-EXE. There is **no scheduler-only lever**.
4. The probe-based reasoning in §1.1 (which ranked the argmin as the lever) read the
   *logical* loop; the **gate trace reads the physical path** and overrules it. The earlier
   probe results are consistent once re-read as multi-path masking at the `rs1_rdy` endpoint:
   path-1 grant-gating (12.920, dcache wall), path-2 CDB-snoop (12.320, A-EXE), path-3 the
   select loop (≤ 12.3, below both — which is why AS-b never showed).

**▶️ The corrected next move is NOT in this file** — it is the coordinated deep-pipeline
flip (commit-store/dcache wall = Phase C dcache synchronous-read SRAM pipe, + A-EXE CDB
register, + the front-end and vector fronts), per `deep_pipeline_sram_plan.md`. A-SCHED has
no standalone lever; fold AS-c into that bundle if/when the wall is cut.

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

## 6. 🚨🚨🚨 FRESH RE-ATTACK (2026-07-01) — the keystone floor is ~12.9 ns / 126 levels, NO incremental lever; 7.5 needs A-LOOP

User chose "re-attack the keystone" after the vrf/dense-band finding (`cp_vrf_cut_plan.md`),
on the hypothesis that the context had changed: the wall (commit-store/dcache/vrf) is now
*cuttable*, so the select→wakeup loop should be the actual floor and might have a lever once
exposed. I measured this directly by **stacking the cuts** that mask the loop and reading
where the scheduler region lands. Four synth runs (all throwaway, reverted, tree clean):

| config (FETCH_REG=1 +) | rs1_rdy / IQ-select region | masked by |
|---|---|---|
| baseline | rs1_rdy 12.920 (grant-gating = wall leak) | — |
| EX_PIPE=1 (cut CDB-snoop) | rs1_rdy < top (not in top-400) | vrf 13.88 + FP `fr_*_sum_q` + the EX_PIPE `s2_cheap_fflags` 17.49 artifact |
| + grant-gating cut (sched_wake from `has_issuable`) | rs1_rdy still masked | same |
| **+ commit-store(STORE_PRETRANSLATE=1) + vrf(register VALU operands)** | **`head → [N][0]` 12.930 / 126 levels** (the IQ select-region nets; rs1_rdy below it) | `s2_cheap_fflags` 17.49 · mhpmcounter (351) · `fr_*_sum_q` · redirect 59 |

🎯 **The keystone select→wakeup region is robustly ~12.9 ns / 126 levels** — identical to the
original masked rs1_rdy 12.920. Cutting the *entire* wall (commit-store + vrf) + CDB-snoop +
grant-gating did **not** drop it below ~12.9. So the "the wall was masking a short loop"
hypothesis is **FALSE**: the loop's own logic is ~12.9 ns / 126 levels deep, and the wall
just happened to leak in at the same height via grant-gating. The keystone is the deepest
floor, masked under EVERYTHING (commit-store 14.13 · vrf 13.88 · FP fround · HPM · CDB-snoop
12.32 · redirect 13.35), and it does not get shorter when they are removed.

**And there is no incremental lever** (this is the load-bearing conclusion):
- AS-b (age-matrix select) is depth-neutral (§0): the argmin is ~3 of the 126 levels.
- AS-a (wakeup tail / dependency-matrix) is ~0.2 ns (§3): the `prf_ready` write is a few levels.
- AS-c (grant-gating) is the wall leak, not the loop's own depth.
- So the **126 levels are DISTRIBUTED** across the select→wakeup datapath (age-subtract,
  cand/ready build, the per-entry rs*_rdy writes, the 2-wide alloc interplay) — no single
  hotspot a DEAD-param cut removes. Halving it to ~75 levels / ~7.5 ns is not an incremental
  edit; it is a **structural IQ/scheduler redesign**: a collapsing/age-ordered IQ + the
  **A-LOOP latency-speculative wakeup + replay** (the campaign's "80 % difficulty",
  `speculative_wakeup_design.md §5/§7`) that lets the loop be *pipelined* without losing
  1/cycle dependent issue.

🏁 **Campaign-level conclusion (data-backed, the decision gate fires):** the realistic
achievable floor via front-cutting + a collapsed-loop is the scheduler depth **~12–12.9 ns**
(`deep_pipeline_sram_plan.md` "If A-SCHED proves infeasible within the IPC/SMP budget, the
realistic goal revises to the IS-stage depth (~12 ns), not 7.5 ns"). **7.5 ns is gated on the
A-LOOP speculative-wakeup+replay redesign** — not an incremental lever, a multi-session
megaproject with full SMP/litmus re-verification. The keystone cannot be attacked in
isolation either: it is masked under the whole bundle, so even *measuring* a candidate lever
needs the bundle cut first.

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

## 7. ✅ RE-MEASURED post-A2 (2026-07-02) — the loop is 11.79/126 lv, MASKED under a dense wall; §6's "no lever" REFINED — the 126 lv decompose, block-store scan (37 lv) is the biggest single chunk

After A2 (wake-on-select, commit `6436a0d`) removed the dcache grant-gating leak, the scheduler
select→wakeup loop is `rs1_rdy` = **11.790 ns / 126 levels** (was 12.920 pre-A2; the −1.13 is the
dcache leaving, §11.5/§11.7). MEASURED with `FETCH_REG=1 + STORE_PRETRANSLATE=1 + LOAD_SPEC=1`
(wake-on-select), `--timing-paths 25000` (reverted, tree clean).

**A-SCHED is now MASKED, CP-neutral (a structural piece, not a synth-number mover).** The 12.0–13.4
band above `rs1_rdy` 11.79 is NOT the select loop — it is `redirect_pc_q` (13.35), `mip` (13.33),
`mhpmcounter/mhpmevent` (12.93), `hpm_ovf_pend` (12.86), `arch_regs` (12.68) = the **commit / CSR /
HPM / redirect wall**, under `vrf` 13.880 + `n_inflight` (commit-store) 13.55–13.84. So §6's
"`head → [N][0]` 12.930" was the HPM/redirect nets, NOT the loop. The loop sits ~2 ns BELOW the wall
→ shortening it moves NO global CP until the whole commit/CSR/redirect/vrf wall is also cut (the
bundle). Build A-SCHED for the FINAL structure (per the campaign philosophy), measured by throwaway
FF-insertion.

**126-level decomposition (rs1_rdy[0] path, grouped):**
| segment | levels | what |
|---|---|---|
| **`blk_cand` (ROB block-store scan)** | **~37** | oldest unknown-addr store/fence/HSV blocker (load-ordering) → `i_block_store_age`/`_exists` → `cand0.blocked` |
| `iss` + `win` + `cand` (argmin) | ~39 | slot-0 `pick_oldest` age-argmin (depth 3) + slot-1 `win2A/win2L` trees + cand build |
| `prf_ready` + `rs*_rdy` write + `sched_wake` | ~14 | the wakeup tail |
| `i_block_store_age` + misc | ~12 | age wiring into cand |

**→ §6's "no incremental lever, 126 distributed" is REFINED: the block-store scan (37 lv) is the
biggest single chunk, and §6's probe missed it** (§1.1 registered `o_block_store_age`, the OUTPUT,
→ −3 lv; the 37 lv are INSIDE `blk_cand` + the `pick_oldest_blk` tree, feeding BOTH age and exists).

**The block-store scan IS a lever (byte-exact restructure), grounded:** `rob.veryl:740-793`. Today =
per-entry `age_i = i − head_idx` (5-bit subtract ×32) → `blk_cand[i]={is_block,age}` → depth-5
`pick_oldest_blk` tree (each node ~7 lv: 5-bit age-compare + 3 nested muxes) = ~37 lv. The tree
STRUCTURE is already balanced; the depth is `5 × 7`. The min-age blocker = the OLDEST (closest to
head) blocking entry = **the first set bit of `is_block` scanning CIRCULARLY from `head_idx`**.
Restructure: `is_block` vector (head-INDEPENDENT) → **barrel-rotate by `head_idx`** (~5 lv) →
**priority-encode lowest set bit** (~5 lv tree) → position = `o_block_store_age`, OR-reduce = `_exists`.
~10–15 lv vs 37 → **~22 lv (~2 ns) off the loop, BYTE-EXACT** (same oldest-blocker; `is_block` is
unchanged, only the min-reduction is replaced by rotate+priority-encode). Load-ordering-critical →
full ladder (default · backend-validate · **ACT4** · litmus N2/N4 · N2/N4 SMP) even though byte-exact.
DEAD param-gate (`BLK_ROT=0` = the age-tree, byte-identical).

**Remaining after the block-scan cut:** the argmin (~39 lv) — AS-b (age-matrix) is depth-neutral (§0),
so the argmin needs a genuinely different structure (or A-SCHED accepts ~89 lv). The wakeup tail
(~14 lv) is AS-a (small). So the realistic A-SCHED sequence is **BLK_ROT (block-scan rotate+priomux,
−22 lv, byte-exact) FIRST** (the biggest, cleanest chunk), then re-measure the argmin as the new
binding segment. `blk_cand` anchor: `rob.veryl:740-793` (`blk_cand`, `pick_oldest_blk`, `blk_r16..2`,
`blk_win`, `o_block_store_age`/`_exists`).