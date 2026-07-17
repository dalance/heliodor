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

### 5.1 Front-end architectural audit (does the front end have a commit-style wall or a forced/hacky cut?)

Checked at this consolidation (user question, 2026-07-06). **No forced/hacky CP cuts are kept.**
The front-end scaffolds are honest: `FETCH_REG` is fully functional (it reuses the fetch buffer
= the existing IF/ID register; verified 252/0 + N1 boot on first flip). `ICACHE_SYNC_READ`,
`IMEM_MMU_STAGE`, `DECODE_REG` are byte-identical DEAD at `=0`, and their `=1` flips are
explicitly labelled **"FF-insertion measurement only, not functional"** — the functional work is
named, not faked (`icache.veryl:549-553`). The one crude/forced-slow flip that ever existed
(`STORE_PRETRANSLATE` forced-slow path) was on the commit side and was **reverted** (§2.3 of
`cp_frontend_pipeline_plan.md`). The FROUND 3-stage fix deliberately **avoided** a dead-but-timed
false path (used a dedicated CDB arm, not the fpu_result path). So there is no hidden CP debt.

**But the front end DOES have ONE architectural item, analogous to the commit retire fusion:**
the **fetch / branch-redirect loop is coupled to the combinational icache read.** Today the fetch
FSM reads the icache combinationally to get RVC lengths + feed prediction + restart on redirect,
all in one cycle. Making the icache **synchronous** (`ICACHE_SYNC_READ=1` — which *is* the I$ SRAM
migration) is therefore not a free register: it needs functional restructuring of (i) straddle /
cross-line fetch (a 2-halfword instr spanning a line reads the 1-cycle-late `o_rdata`), (ii) FB
push/pop refill timing, and (iii) **branch-redirect → fetch restart (+1 bubble)**, and it carries
a real **+1 branch-mispredict-penalty IPC cost** (`cp_frontend_pipeline_plan.md` §3). This is the
front-end version of "the current single-cycle structure fuses what a deep pipe must decouple" —
the standard fix is **decoupled fetch** (a fetch target queue with BTB-driven prediction running
*ahead* of the icache read), exactly as real multi-GHz front ends do. `IMEM_MMU_STAGE` (F1) and
`DECODE_REG` (D) are by contrast clean register stages (TLB is flops; prediction indexes the
*virtual* PC, not the translate; decode-reg is a downstream boundary).

**Plan (fold into (b), not a separate effort):** the I$ SRAM migration in the SRAM-migration phase
**is** this fetch-loop decoupling — make it a first-class deliverable of that phase: sync-read I$ +
straddle/FB/branch-redirect restructuring (toward decoupled fetch) + the IPC-budget measurement.
It is independent of the commit wall and advances the FINAL front-end structure; do it as the I$
step of (b).

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

## 8. DECISION (2026-07-06) — the study is in; §6.1 resolved

The paper study is done (`retire_memory_ordering_redesign_study.md`, commit `fdfeeef`), and the D$
sync-read structure landed + measured off `n_inflight` (deltas 3+5 + §11.8 FF-insertion,
`cp_dcache_sync_read_plan.md`). The study's data: the retire/memory-ordering redesign is the **only**
lever below 13.71 ns, but its own ceiling is **~12.4 ns** (the dcache-internal fill/victim floor,
Direction-C §8 measured) — **not** 7.5 ns; 7.5 ns needs the retire redesign **plus** memory-floor
pipelining **plus** the A-SCHED scheduler exposure, a multi-phase program whose dominant cost is the
SMP-correctness risk concentrated in R3 (atomic reorder / M3b minefield).

**User decision (§6.1, 2026-07-06):** invoke the plan's own decision gate — **revise the near-term FINAL
target to the IS-stage-depth ~12 ns / 6–7 stages**, achievable by the retire redesign's lower-risk
two-thirds (R1 decoupled-retire + R2 translate-at-execute), and **hold 7.5 ns / 10-stage as the long-term
aspiration** contingent on R3 clearing the SMP ladder + the memory-floor/scheduler phases. **Next: begin
R1** (decoupled-retire + store queue) as a `DEAD` param scaffold (byte-identical at 0, the campaign's proven
methodology), build + measure R1+R2 before committing to R3. Design in `cp_retire_decouple_plan.md`.

### 8.1 RE-AFFIRMED (2026-07-17) — front-end scaffolding now EXHAUSTED; R1 is the sole remaining structural front

Re-confirmed by the user after banking the **I$ decoupled-fetch (shape-W)** scaffold (`7127cb9`,
`cp_icache_fetch_decouple_plan.md §22`) — the **last** maskable front-end SRAM stage (F2). The intervening
work since 2026-07-06 (the deep-pipeline **bundle bank** `c2a98fe` = FETCH_REG+STORE_PRETRANSLATE+
RETIRE_DECOUPLE+VALU_PIPE, −11 %; the D$/L2 sync-read + read-port collapses; shape-W) built/verified **every
maskable CP scaffold** — front-end (F1/F2/D/R), execute keystone (A-EXE), scheduler (A-SCHED), and the SRAM
migration (D$ 1R1W, L2 sync, I$ shape-W). A fresh `veryl synth --top heliodor_core` on the banked tree
(2026-07-16) re-confirms the binding wall UNMOVED in KIND: **13.800 ns `head → commit_store_fire → live dmem
TLB → n_inflight[5]`** (the absolute drifted 13.71→13.800 with the veryl/cell-model update; the cone is the
same §1 retire megacone), with the `redirect_pc_q`/`mip` band ~0.5 ns below (masked, same cone tail). §8's
`c_is_amo` runtime-gate refutation was re-verified this session (`cp_retire_decouple_plan.md §8`).

**Consequence:** there is no longer any front-end/SRAM scaffold left to defer to — **R1 (decoupled-retire +
store queue) is now the sole remaining structural lever**, and the near-term ~12 ns target hinges entirely on
it. The decision stands: **sequence R1 → R2 as DEAD scaffolds (measure before R3); R3 (atomic reorder / M3b
minefield) is the gated SMP-critical finale.** R1 is a fresh, large multi-session piece (a real store queue,
not FF-insertion) best started in a clean context. The alternative (§6 item, un-chosen) — bank at ~13.8 and
treat the retire redesign as a future separately-scoped program — remains available if R1 proves out of budget.

### 8.2 ✅ REACHED (2026-07-17, user decision §6.2-D) — the near-term ~12 ns target is MET on the *real* floor; R1a shipped, the reported wall was a FALSE PATH

R1a (`SB_PA_REG=1`, `aee7ecd`, −6 % headline 13.800→12.965) took the last shared commit live-TLB off
`rob_commit_ack`. Then `cp_store_queue_plan.md` §6 proved (throwaway `ic_route = ic_owns`) that the
`pc_q → n_inflight` 12.965 headline — and, by strong inference, the 13.800/13.120/14.130 headlines before
it — is a **FALSE PATH** (a fetch-icache-miss → shared-dmem-port → commit-store stitch, not co-sensitizable).
The **real** synth CP has been **~12.5 ns** for a while, bounded not by the retire µarch but by the **vector
execute→writeback datapath**: two co-floors 0.02 ns apart — FP double (`fr_d1_q → fround_d_add → vrf`,
12.510) and integer-vx (`head → prf → bbcast → valu_res → vrf`, 12.490) (`cp_vector_datapath_cut_plan.md`).

The FP cut (`VFP_EX_PIPE`, `ef12620`, DEAD) is functionally correct at =1 (fast 252/0, `test_arch_vfarith`
PASS) but moves the real CP only 12.510→12.490 (the vx co-floor is right behind), so it is **not worth
flipping alone** against its +1–2-cycle-per-FP-element vector throughput cost. Moving below ~12.5 needs a
**coordinated FP+vx vector-pipelining multi-cut** whose combined throughput cost must beat a ≤~0.5 ns CP gain
— a poor trade unless vector-FP-heavy code dominates.

**User decision (§6.2-D, 2026-07-17): the near-term ~12 ns / 6–7-stage FINAL target is REACHED on the real
floor (12.49–12.51 ns).** The CP-reduction campaign has taken every scalar retire/commit/fetch + SRAM lever
(14.745 → real ~12.5); R1a −6 % was the last high-value scalar ship. **The 7.5 ns / 10-stage aspiration stays
long-term, now explicitly contingent on a SEPARATE program: coordinated FPU/vector-datapath pipelining
(`cp_vector_datapath_cut_plan.md`, throughput-gated) + the ~12.4 ns memory floor (Direction-C §8) + R3 atomic
reorder / scheduler phases.** The DEAD scaffolds (`SB_PA_REG` live; `VFP_EX_PIPE`, `MEM_PIPE`, the vx cut
un-built) remain as the components of that future program. Optional metric-hygiene follow-on: §6.2-B (register
`ic_route`/the dmem grant) to structurally break the false stitch so `synth` reports the real ~12.5.
