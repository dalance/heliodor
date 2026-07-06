# Deep-pipeline campaign — status consolidation + re-plan (2026-07-06)

Written at a deliberate inflection: after the FP-add (`FMA_PIPE3`, `fe49acc`) cut and the
Phase-E / ASAP7 investigation, the CP-chasing phase has hit a measured floor. Rather than
keep hammering the binding synth number (CP-driven mole-whacking — see
`feedback_heliodor_optimize_for_structure_not_cp`), this doc consolidates **what is built**,
**what the measured floors actually are**, and **re-frames the remaining work** with a full
overview. Companion docs: `deep_pipeline_sram_plan.md` (the master plan + stage diagram),
`cp_frontend_pipeline_plan.md` (§1–§13.1 the CP work log), `cp_direction_c_port_separation_plan.md`
(the abandoned commit-port work), `cp_a_sched_scheduler_pipeline_plan.md`, `cp_a_loop_plan.md`.

> **Correction carried into this re-plan (user, 2026-07-06):** the earlier phrasing that the
> deep-pipe target is *"unreachable"* is WRONG. 10+-stage multi-GHz OoO cores exist, so the
> limit is **heliodor's current single-cycle retire / memory-ordering microarchitecture**, not
> a fundamental barrier. The FINAL target value is **NOT lowered here** — that is an explicit,
> deliberate decision gate (see §5), not a silent miss.

---

## 1. Scaffold inventory — every pipeline-staging param, its state

All staging is param-gated `DEAD` scaffolding (`=0` is cycle-exact byte-identical; `=1` inserts
the register / stage). Current default build: **only `MEM_PIPE` and `VFP_PIPE` are ON**; every
other stage is `=0` (built, verified byte-identical, but not enabled — so it buys **no CP today**
and is masked below the back-end wall).

| Param | file:line | Dflt | FINAL stage it builds | Verified state | Notes |
|---|---|---|---|---|---|
| `FETCH_REG` | core:1218 | 0 | R (F\|D register) | DEAD byte-id; Phase D | front-end, ≤5.36 ns |
| `ICACHE_SYNC_READ` | icache:556 | 0 | F2 (sync-SRAM icache read) | DEAD byte-id; Phase D/C | = SRAM migration of I$ |
| `IMEM_MMU_STAGE` | imem_mmu:199 | 0 | F1 (registered imem translate) | DEAD byte-id; Phase D | |
| `DECODE_REG` | core:1464 | 0 | D (cexp+decode register) | DEAD byte-id; Phase D | |
| `MEM_PIPE` | core:1661 | **1** | C load Stage-A\|M\|Stage-B; AMO commit reg-PA | **LIVE (committed)** | registered `ac_pa_q` RMW write |
| `STORE_PRETRANSLATE` | core:1676 | 0 | C (plain-store commit pre-translate) | DEAD byte-id; −0.25 ns (sky130) plain-store | atomics excluded (share coherent port) |
| `DCACHE_SYNC_READ` | dcache:611 | 0 | C load Stage-B (sync-SRAM dcache read) | DEAD; Phase C | = SRAM migration of D$ |
| `EX_PIPE` | core:1523 | 0 | RR\|EX\|WB (CDB register = A-EXE keystone) | **arch 228/0 + SMP-complete** (litmus N2/N4 + SMP boot); byte-id at 0; **IPC −15 %** | the keystone; masked below the wall |
| `FROUND_PIPE` | fpu_wrap:27 (`:EX_PIPE`) | 0 | EX (3-stage Zfa FROUND) | ACT4 Zfa F/D validated; byte-id at 0 | wired to EX_PIPE |
| `FMA_PIPE3` | fpu_wrap:33 (`:EX_PIPE`) | 0 | EX (3-stage double FMA) | rv64ud/uf validated; byte-id at 0 | wired to EX_PIPE; cut s1_sum 13.86→11.74 (sky130) |
| `SEL_PIPE` | iq_int:266 | 0 | IS (scheduler select register) | DEAD; Phase A-SCHED | |
| `SPEC_WAKE` | iq_int:297 | 0 | IS loop (speculative wakeup) | DEAD; Phase A-LOOP | |
| `LOAD_SPEC` | iq_int:312 | 0 | IS loop (load latency-spec) | DEAD; A-LOOP (excluded from bundle) | highest risk (replay+SMP) |
| `VALU_PIPE` | vector_unit:63 | 0 | VU ALU staging | DEAD | vrf front |
| `VFP_PIPE` | vector_unit:34 | **1** | VU FP operand FETCH stage | **LIVE (default)** | already ON |

**Read of the inventory:** the front-end (F1/F2/D/R), the execute keystone (A-EXE = EX_PIPE +
FROUND/FMA staging), and the plain-store commit pre-translate are all **built and verified**,
sitting at `=0`. The scaffolds are correct and cheap to enable — but enabling them **moves no
CP** because they are all masked below the back-end commit-store wall, and `EX_PIPE=1` alone
costs ~15 % IPC. So the accumulated structure is real but **latent**.

---

## 2. Current vs FINAL pipeline structure

FINAL target (from `deep_pipeline_sram_plan.md`):

```
 F1  PC → imem-MMU translate (reg)        [IMEM_MMU_STAGE]      ─ built =0
 F2  icache read (sync SRAM)              [ICACHE_SYNC_READ]    ─ built =0  (= I$ SRAM migration)
 D   cexp + decode                        [DECODE_REG]          ─ built =0
 R   rename + free-list + IQ allocate     [FETCH_REG]           ─ built =0
 IS  ISSUE/SELECT  ◀─ select→wakeup 1cy ─┐ [SEL_PIPE/SPEC_WAKE] ─ built =0  ← the hard core (A-SCHED/A-LOOP)
 RR  regread (PRF)                        │ [EX_PIPE]            ─ built =0, keystone verified
 EX  execute (1+ cy)                      │ [EX_PIPE/FROUND/FMA] ─ built =0
 WB  writeback / CDB  ── wakeup ──────────┘ [EX_PIPE]            ─ built =0
 C   commit / retire                        [STORE_PRETRANSLATE, MEM_PIPE=1] ─ partial; the WALL
      load: Stage-A (AGU+xlate+PMP) │ M (PA latch) │ Stage-B (dcache sync read) [MEM_PIPE=1, DCACHE_SYNC_READ=0]
```

**Done / verified:** the entire front end (Phase D), the execute keystone (A-EXE), FP-execute
staging, and MEM_PIPE's load Stage-A/M/Stage-B + registered AMO commit write. **A-SCHED** already
shortened the IS scheduler loop 12.92→9.52 ns (sky130). **Not done:** the **commit/retire (C)
back half** — the `n_inflight` commit-store megacone — and the A-LOOP replay core, plus the SRAM
migration of I$/D$/L2/predictor (built as `=0` sync-read scaffolds for the caches; predictor not
started).

---

## 3. Measured CP floors — sky130 vs ASAP7 (the reason to step back)

`veryl synth` has a built-in cell model selected by `[synth] library` in `Veryl.toml`
(default `sky130`; `asap7` also available — measured this session, config reverted).

| build | sky130 (130 nm, default) | ASAP7 (7 nm) |
|---|---|---|
| DEAD (shipping) | 14.745 ns `pc_q→rs1_rdy` | 3.877 ns `pc_q→fb_count` |
| bundle (all scaffolds =1, LOAD_SPEC=0) | 13.710 ns `n_inflight` | 3.785 ns `fr_d_sum_q` (FP FROUND-D) |

**The binding front CHANGES with the PDK.** In sky130 the bundle floor is the atomic
commit-store megacone (`n_inflight` 13.71) — the lone wall the whole Phase E saga chased. In
ASAP7 the top fronts are the **FP adder datapath** (fr_d_sum_q 3.785 / fr_s_sum_q 3.524 /
s1_sum_mag_q 3.404), and the commit megacone (`n_inflight` **3.445**) sits **#3, just 0.34 ns
below** the FP wall — masked, but close behind.

**The commit megacone is PDK-independent in KIND.** Forcing ALL commit-store faults to 0
(CP-isolation) drops `n_inflight` only −0.44 ns in sky130 (13.71→13.27) and −0.06 in ASAP7
(3.445→3.384): in both PDKs the megacone is the **store RETIRE path**, not the fault check —
`commit_store_fire → agu → live TLB translate → translated-PA → sb_merge_ok (store-buffer merge)
→ rob_commit_ack → n_inflight`. A store/atomic cannot retire (free its ROB entry) until its
translated PA is merge-matched against the store buffer. See `cp_frontend_pipeline_plan.md`
§13/§13.1 and `cp_direction_c_port_separation_plan.md` §8 (the same finding, 2026-06-27).

**Consequence for "keep cutting CP":** cutting the FP fronts in ASAP7 buys ~0.34 ns and then
hits the same retire wall; deferral/FF-insertion cannot cut that wall (a runtime mux/gate cannot
prune the shared live TLB — §13). So more CP hammering is diminishing returns **for the current
retire microarchitecture**.

---

## 4. Corrected diagnosis — the wall is the retire/memory-ordering µarch, not a fundamental limit

The original plan's **Phase E was under-scoped.** It states (`deep_pipeline_sram_plan.md`
Phase E): *"Atomic commit must stay single-cycle (a +1 cy commit breaks SMP atomicity — proven:
litmus N2 amoadd wedge). Direction-C-style port separation for non-atomic commit only; low
leverage (≤1.3 ns). Defer."* This accepts heliodor's **current** atomic structure — in-cache AMO
(P9.3 `amo_watch`/`amo_poison`, commit-time RMW write into an owned line) — as fixed, and
correctly concludes low leverage *within that structure*.

But real multi-GHz 10+-stage OoO cores **do not** keep the commit/retire single-cycle. They:
- **Decouple ROB-retire from the memory write.** A store retires when it becomes non-speculative;
  the actual write drains later from a **store queue**, off the retire critical path. Retire is
  not gated on a live `sb_merge_ok` tag-compare.
- **Translate at AGU/execute**, not at commit — the PA lives in the store queue; commit does not
  re-drive the TLB.
- **Order atomics via the load/store queues + memory disambiguation + the coherence protocol**,
  which tolerate multi-cycle atomic handling — instead of a single-cycle "RMW-write-into-owned-
  line + watch/poison replay" that a +1 cy slip desyncs (the M3b wedge is an artifact of *this*
  atomic implementation, not of atomicity itself).

So the deep-pipe target is reachable — but the remaining structural work at the commit/retire
end is a **genuine µarch redesign of the retire + store-queue + memory-ordering subsystem**, not
another FF-insertion scaffold. That is bigger than everything done so far (which was
FF-insertion into existing combinational paths), and it is the honest re-scope of Phase E.

---

## 5. The two campaign goals — re-weighted

The campaign always had two goals (`deep_pipeline_sram_plan.md` intro): **(a)** halve CP / 10+-stage
pipeline, and **(b)** migrate to realistic ASIC SRAM (1RW/1R1W synchronous). Current standing:

- **(a) deep-pipe CP.** Front-end + execute keystone + A-SCHED are built. The remaining gate is
  the **retire/memory-ordering redesign** (§4) — high value, high effort, SMP-critical. The
  original 7.5 ns target's own decision gate (`deep_pipeline_sram_plan.md`:132-134) already says:
  *"If A-SCHED proves infeasible within the IPC/SMP budget, the realistic goal revises to the
  IS-stage depth (~12 ns / ~6–7 stages), not 7.5 ns — an explicit decision gate."* **We are at
  that gate.** (Decision deferred per user — do NOT lower the target here.)
- **(b) SRAM migration.** Largely **untouched** (28-RAM inventory done → `sram_inventory.md`;
  D$ has sync-read groundwork via `DCACHE_SYNC_READ`; I$/L2/predictor not started). It is
  **independent of the commit wall**, directly makes the design tapeout-realistic, and
  **SRAM ⊂ pipeline deepening** (a synchronous SRAM read *is* a pipeline stage — the same flip).
  This is high-value remaining work that does NOT need the retire redesign first.

---

## 6. Open decisions for the user (NOT decided here)

1. **FINAL target.** Keep 7.5 ns / 10-stage, or invoke the plan's own decision gate to the
   IS-stage-depth target (~12 ns sky130 / ~6–7 stages)? Requires studying whether the
   retire/memory-ordering redesign (§4) is in budget — decide after that study, not now.
2. **Next direction.** (i) Study + prototype the **retire/store-queue/memory-ordering redesign**
   (re-scoped Phase E — the real path below the commit wall); (ii) pivot to the **SRAM migration**
   (independent, tapeout-realistic, SRAM⊂deepening); (iii) **consolidate/enable** the built
   scaffolds (default-flip strategy) as a stable checkpoint.
3. **Default-flip strategy.** The scaffolds are all `=0` (no CP benefit while masked; `EX_PIPE=1`
   costs ~15 % IPC). Decide whether to leave them latent, or enable a subset as the new baseline
   (e.g., front-end F1/F2/D/R, which are near-IPC-free) — noting global CP will not move until the
   commit wall is addressed.

## 7. Recommendation (mine, for discussion)

Sequence, low-risk first: **(b) SRAM migration** is the most valuable *independent* next block —
it advances the FINAL structure (SRAM⊂deepening), is tapeout-relevant, and sidesteps the
commit-wall entirely; do the caches (D$ groundwork exists) then predictor. In **parallel**, run a
**paper study of the retire/memory-ordering redesign** (§4) — what a store queue + decoupled
retire + LQ/SQ disambiguation would cost in area/IPC/SMP-complexity for heliodor — to inform the
§6.1 target decision with data instead of the stale 7.5 ns aspiration. Only commit to the retire
redesign (the big one) once that study says it fits the budget. **Do not** keep hammering CP, and
**do not** lower the target until the study is in.
