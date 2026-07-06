# Retire / memory-ordering redesign — paper study (2026-07-06)

**Purpose.** The deep-pipeline campaign is at its decision gate (`deep_pipeline_status_and_replan.md`
§6.1): keep the 7.5 ns / 10-stage FINAL target, or revise to the IS-stage-depth target (~12 ns / 6–7
stages)? The gate hinges on whether the **retire / store-queue / memory-ordering redesign** — the one
remaining structural lever below the measured 13.71 ns bundle wall — fits the campaign's budget
(~10–15 % IPC, SMP-correct, reasonable area). This study scopes that redesign and its cost so the target
decision is made on data, not on the stale 7.5 ns aspiration. It does **not** implement anything; the
recommendation is for the user's §6.1 decision. Companion: `deep_pipeline_status_and_replan.md` §4/§5/§6,
`cp_direction_c_port_separation_plan.md` §8, `cp_frontend_pipeline_plan.md` §13/§13.1,
`cp_dcache_sync_read_plan.md` §11.8.

---

## 1. The measured wall — what actually binds the CP

Everything the campaign built (front-end F1/F2/D/R, the A-EXE execute keystone, A-SCHED's 12.9→9.5 ns
scheduler loop, the vrf cut, and now the D$ synchronous-read structure) is **masked below a single
back-end wall**. Measured in the coordinated bundle synth (all scaffolds `=1`, `cp_dcache_sync_read_plan`
§11.8, 2026-07-06):

```
bundle CP = 13.710 ns / 137 levels   head → n_inflight[5]      (sky130)
cone: commit_store_fire
      → u_dmem_mmu.u_mmu.tlb_*  (×24 gates — the LIVE V=1 two-stage TLB, ~4 ns)
      → u_pmp_cbo_m_w.*         (the commit-time PMP check)
      → commit_trap / sb_merge / rob_commit_ack
      → u_fl.n_inflight          (the free-list retire counter)
#2 endpoint: redirect_pc_q 13.210  (the branch-mispredict-redirect arm of the same commit→trap cone)
```

**This is a store/atomic RETIRE megacone.** Two independent measurements pin down what it is:

- **It is NOT the fault check.** Forcing every commit-store fault to 0 (`cp_frontend_pipeline_plan` §13.1
  CP-isolation) drops `n_inflight` only −0.44 ns in sky130 (13.71→13.27) and −0.06 in ASAP7. The residual
  13.27 cone is the **store RETIRE path**: `commit_store_fire → AGU → live TLB translate (~4 ns) → m_pa_q
  → c_store_addr → sb_line/sb_match → sb_merge_ok → rob_commit_ack → do_push2 → n_inflight`. A store/atomic
  cannot free its ROB entry until its translated PA is merge-matched against the store buffer.
- **It is PDK-independent in KIND.** In ASAP7 the same cone is `n_inflight` 3.445 ns, #3 (0.34 ns under the
  FP-adder front); the retire path is the floor in both PDKs.

- **Deferral / FF-insertion cannot cut it.** `AMO_XLATE_DFR` (register the atomic's fault check at issue,
  `cp_frontend_pipeline_plan` §13) was implemented and REFUTED by flip synth: a runtime 2:1 mux
  (`sfault_eff = dfr ? ac_page_q : dmem_mmu_fault_s`) cannot prune the shared live-TLB input — its delay is
  `max(both arms)+mux ≥ live TLB`. And Direction-C physical port separation (`cp_direction_c_port_separation`
  §8) cuts the *whole* commit cone off the MMU/dcache to ≤1.3 ns — but only for NON-atomic commit; atomics
  need the shared coherent port and land on a ~vrf-12.4 dcache-internal floor. Both abandoned.

**Conclusion of §1:** the wall is not a stray net or a fault check — it is the **structural fact that a
store/atomic retires in the same cycle it (re-)translates and merge-matches against the store buffer**. To
move the CP below ~13.7 ns (sky130) the retire has to stop being single-cycle-fused with translate + SB
merge. That is a microarchitecture redesign, not another FF-insertion scaffold.

---

## 2. Why real multi-GHz OoO cores do not have this wall (the reference design)

10+-stage multi-GHz OoO cores retire several instructions/cycle without a translate-and-merge on the retire
path. The standard structure that avoids it:

- **Decoupled retire ≠ memory write.** A store becomes *non-speculative* (retires from the ROB, frees its
  entry) as soon as it is the oldest and fault-free. The actual memory write happens **later**, drained
  asynchronously from a **store queue (SQ)** that lives *after* the ROB. Retire is a pointer bump; it is
  **not** gated on a tag-compare against a buffer. heliodor today fuses these (retire waits on
  `sb_merge_ok`).
- **Translate at AGU/execute, once.** The store's PA is computed and TLB-translated at the AGU/execute
  stage and written into the SQ entry. Commit/retire **never re-drives the TLB** — it just marks the SQ
  entry committed so the drain engine may write it. heliodor re-drives the live `u_dmem_mmu` at commit for
  atomics (and, absent `STORE_PRETRANSLATE`, for plain stores too).
- **Ordering via LQ/SQ + disambiguation + coherence, tolerant of multi-cycle.** Load↔store ordering and
  store↔store ordering are enforced by the load queue / store queue with address-match disambiguation and
  the cache-coherence protocol — mechanisms that are inherently **multi-cycle-tolerant**. Atomics are
  ordered through the same queues + coherence (an LR/SC or AMO holds the line in the coherence protocol and
  serialises through the SQ), **not** through a single-cycle "RMW-write-into-an-owned-line + watch/poison
  replay" that a +1 cy slip desyncs. heliodor's in-cache AMO (P9.3) is exactly that single-cycle scheme —
  the `M3b amoadd wedge` (a +1 cy atomic-commit slip desyncs the SMP litmus barrier) is an artifact of
  *this* implementation, not of atomicity itself.

So the deep-pipe target is reachable in principle; the remaining work is a **genuine redesign of the
retire + store-queue + memory-ordering subsystem**, bigger than everything done so far (all of which was
FF-insertion into existing combinational paths). This is the honest re-scope of the plan's "Phase E."

## 3. The current heliodor retire / memory-ordering structure (code map)

Grounded in `heliodor_core.veryl` / `rob.veryl` / `free_list.veryl`. The point of this map is to separate
**what is single-cycle-fused at retire** (the redesign targets) from **what is already decoupled** (leave
as-is). heliodor is further along than a naïve "everything is single-cycle" — but the two fused pieces are
exactly the wall.

### 3.1 The retire gate — `rob_commit_ack` (`heliodor_core.veryl:3530-3540`)

The ROB head frees when `rob_commit_ack` holds. It is a combinational AND of "not-replayed" and several
store-drain gates:

```
rob_commit_ack = rob_commit_valid && !commit_load_replay && !commit_amo_replay
   && !(c_is_store && !sb_elig && (dmem_mmu_busy || walk…))          // slow store: TLB-miss walk wait
   && !(MEM_PIPE && c_is_store && !sb_elig && !c_is_amo && !store_fetched_q)  // slow store: translate-cycle hold
   && !(c_is_store && !sb_elig && (dcache_stall || !sb_empty))       // slow store: dcache/buffer drain wait
   && !(c_is_store && sb_elig && sb_full && !sb_merge_ok)            // ★ FAST store: SB merge-match gate
   && !(c_serial && !sb_empty);                                      // fence/satp: drain wait
```

The **★ term is the CP wall**. `sb_merge_ok` (`:6089`) = `sb_match_v && …`, where `sb_match_v` is a
combinational scan of the 4 SB entries for a line-address match:
`for i in 0..4: if i < sb_cnt && sb_line[i] == sb_pa[63:6]` (`:6077-6086`). And crucially:

> `sb_pa = c_store_eff_pa` (`:6060`) `= dmem_vm_on_op ? dmu_dmem_addr : c_store_addr` — for a VM-on store
> **`sb_pa` is the LIVE MMU-translated PA `dmu_dmem_addr`.**

**This reconciles the bundle-synth cone** (`§11.8`: `u_dmem_mmu.u_mmu.tlb_*` ×24 → … → `n_inflight`): the
retire wall is one fused combinational chain —
`commit_store_fire → AGU → live TLB translate (dmu_dmem_addr, the ~4 ns / 137-level DEEP part) → sb_pa →
4-entry SB merge-match scan (the shallow tail) → !sb_merge_ok → rob_commit_ack → do_push2 → n_inflight`.
The TLB is the depth; the merge-match + retire gate is the shallow tail on top of it. **Both must decouple.**

### 3.2 The store buffer — already half-decoupled (`heliodor_core.veryl:700-710, 6060-6213`)

`SB_N=4` line entries (`sb_line[58]` = PA[63:6], `sb_data[32]` = 8 dword lanes/line, `sb_strb`, `sb_lmap`,
`sb_cnt`). Write-combining at line granularity (S25). Key timing facts:

- **Push at COMMIT** (`sb_push = sb_elig && (sb_merge_ok || !sb_full)`, `:6090`) — a store enters the SB
  only when it retires, in program order.
- **Drain is DECOUPLED from retire** (`sb_pop = dc_sdrain_ack && …`, `:6066`) — the dcache drains the SB
  head asynchronously; a fast store retires the cycle `sb_push` fires **even while older entries are still
  draining**. ✅ This half is already what a redesign wants.
- **But retire is GATED on the merge-match** (§3.1's ★): when `sb_full && !sb_merge_ok` the store cannot
  push and stalls at the head. So the SB is decoupled on the *drain* side but **fused on the *allocation***
  side (allocation = retire).

### 3.3 Translation timing (`heliodor_core.veryl:3428-3436, 5346-5349, 6060`)

- **Plain stores:** `STORE_PRETRANSLATE=0` (dead, `:1676`). Bare stores use `c_store_addr` (VA==PA, no
  MMU); VM-on stores re-drive the live `u_dmem_mmu` at commit (`sb_pa = dmu_dmem_addr`). The dead
  `STORE_PRETRANSLATE` path *would* register the PA at execute (`store_pretx_*`) via the SB side-port —
  but even enabled it excludes atomics.
- **Atomics:** the PA is latched at execute into `ac_pa_q` (`:5346-5349`), and the commit RMW uses that
  **registered** PA (`dmem_pa_m = amo_commit_live ? ac_pa_q`). So the atomic's *write* PA is already
  registered — but the retire-gate's fault/merge path and the VM-store `sb_pa` still ride the live TLB.

### 3.4 In-cache atomics (P9.3) — the single-cycle SMP crown jewel (`heliodor_core.veryl:5313-5333, 6856-6877`)

- **Arm at execute:** `amo_watch_valid_q/pa_q/rob_q` latched, `amo_poison_q` tracks the watched line
  (`:5313-5326`).
- **Commit RMW is a single-cycle write into an OWNED dcache line:**
  `amo_cwr_en = store_drive && sb_empty && ac_wok_q && (dc_amo_present || !EX_PIPE)` (`:6863`) — it writes
  only if the line is present-and-exclusive at the commit cycle (`dc_amo_present`).
- **Poison → replay:** if the watched line departs (remote invalidate / eviction) between the arm and the
  commit, `amo_poison_q` sets and `commit_amo_replay` (`:3474`) suppresses retire → redirect + re-fetch.
- **Why +1 cy breaks it (the M3b wedge, `:6866-6876`):** a slipped commit write can land the cycle *after*
  the line departs — a store leak into a no-longer-owned line, desyncing the SMP barrier. **This is the
  exact constraint that makes single-cycle atomic commit load-bearing** — and the reason a naïve "add a
  pipeline stage to commit" breaks litmus. A redesign must reorder atomics through a queue+coherence, not
  slip the in-cache RMW.

### 3.5 Load-store ordering / disambiguation (`rob.veryl:406-459, 863-999`)

- **No separate LQ** — the load-order record is embedded per-ROB-entry (`sh_load_done/addr/funct3/poison`).
- **Speculative loads + forwarding, not conservative blocking:** loads read the dcache speculatively and
  are byte-forwarded from older in-flight/SB stores (`stld_fwd_*`, `:2197`). A committing store resolves
  its address and scans younger executed loads for overlap → `sh_load_poison` → `commit_load_replay`
  (`:3462`) → redirect/re-execute. ✅ This is already a modern speculative-memory scheme.
- **The SB overlap scan uses VA page-offset `[11:3]`** (not PA) to avoid a comb loop through the MMU
  (`:6092-6106`) — false positives only hold an atomic a few cycles.

### 3.6 Memory-model enforcement (RVWMO) (`heliodor_core.veryl:2244-2269, 3503, 5144-5229`)

- **FENCE / SFENCE / satp** (`c_serial`) retire only after the SB drains (`!(c_serial && !sb_empty)`).
- **LR/SC** via `rsv_valid_q`/`rsv_pa_q` + `sc_watch` poison on remote invalidate.
- **Coherence (MESI-like L1↔L2 directory)** orders stores at the home; remote writes pulse invalidates that
  poison executed-uncommitted loads (CoRR), clear reservations, and poison AMO watches.
- **This is the validated litmus-battery machinery** — the redesign's single hardest constraint is not
  regressing it (litmus N2/N4 + SMP boot N2/N4 + Verilator).

### 3.7 What is fused vs. decoupled — the redesign surface

| structure | at retire? | redesign target? |
|---|---|---|
| `rob_commit_ack` retire gate | **single-cycle, combinational** | ★ the wall |
| `sb_merge_ok` 4-entry match scan feeding retire | **single-cycle, IN the CP** | ★ decouple allocation from retire |
| `sb_pa` = live TLB translate (VM store) | **single-cycle, the DEEP part** | ★ translate-at-execute (needs SQ) |
| SB drain to dcache | already decoupled (`sb_pop`) | ✅ keep |
| atomic write PA (`ac_pa_q`) | already registered at execute | ✅ keep |
| **atomic in-cache RMW commit** | **single-cycle (load-bearing, M3b)** | ★ hardest — reorder via SQ+coherence |
| load speculation + forwarding + poison-replay | already speculative/decoupled | ✅ keep (modern) |
| coherence / LR-SC / fence-drain | protocol-ordered, multi-cycle-tolerant | ✅ keep |

**Reading:** heliodor already has the *drain* side decoupled, the atomic write-PA registered, and a modern
speculative-load-with-replay scheme. The two things still fused at retire are (a) **retire-gated-on-SB-
allocation** (the merge-match) and (b) **the live TLB translate feeding the retire gate**, plus (c) the
**single-cycle in-cache atomic RMW** that a +1 cy slip desyncs. A redesign is exactly: a store queue that
takes allocation off the retire path + translate-at-execute for all stores/atomics + atomics reordered
through the SQ/coherence instead of the single-cycle in-cache RMW.

---

## 4. Redesign options + cost framework (to be scored against the §6.1 budget)

The decision needs each option scored on four axes: **CP win** (does it break 13.71 ns, and to what floor),
**IPC cost** (the ~10–15 % budget), **SMP-correctness risk** (the litmus / SMP-boot / Verilator ladder —
heliodor's memory model is validated, not to be regressed), and **area / effort**.

Candidate structural moves (from the §3 map — the three fused pieces):

- **(R1) Decoupled retire + store queue.** Give the SB an *allocation* path independent of retire: a store
  retires when oldest + fault-free + its PA is known (pointer bump), entering a store queue that the dcache
  drains asynchronously (the drain side is already decoupled, §3.2). Removes the `sb_full && !sb_merge_ok`
  merge-match term from `rob_commit_ack` (§3.1 ★). The hard part: precise exceptions (a store that faults
  must not have retired) and keeping the SQ ordered vs. loads (the §3.5 poison-replay already helps).
- **(R2) Translate-at-execute for ALL stores/atomics.** Write the execute-time PA into the SQ entry; commit
  never re-drives the TLB. Removes the live `dmem_mmu` from `sb_pa` / the retire gate (§3.3). For plain
  stores the dead `STORE_PRETRANSLATE` already prototypes this (−0.25 ns plain-store, `§11.8`); the
  residual is atomics, which share the coherent port (`§13`) and so need the SQ (R1), not a side port.
- **(R3) Reorder atomics through the SQ + coherence (retire the single-cycle in-cache RMW).** Replace the
  `amo_cwr_en` single-cycle write-into-owned-line (§3.4) with an atomic that acquires ownership and
  performs its RMW from the SQ under the coherence protocol, tolerant of multi-cycle. Directly removes the
  M3b single-cycle constraint. **Highest SMP risk — this is the litmus minefield.**

These are **not independent** — R1 is the enabler; R2 and R3 ride it. The realistic package is
**R1+R2+R3 together** = a store-queue / decoupled-retire / reordered-atomic redesign.

### 4.1 Cost estimate, per axis

| axis | estimate | basis |
|---|---|---|
| **CP win** | 13.71 → **~12.4 ns** (sky130), NOT 7.5 | Direction-C `§8` MEASURED: cutting the *entire* commit cone off the MMU/dcache (incl. `sb_merge_ok`) lands at ≤1.3 ns commit + a **residual ~vrf 12.49 dcache-internal fill/victim floor**. So the retire redesign's own ceiling is the memory floor (~12.4), = the plan's "IS-stage-depth ~12 ns" gate — **not** 7.5 ns. |
| **remaining to 7.5** | needs 2 MORE fronts after the retire redesign | below ~12.4 the floors are the **dcache-internal fill/victim (vrf 12.49, VALU_PIPE built)** then the **A-SCHED scheduler loop (9.52, built)**. Reaching 7.5 ns needs those *also* exposed + the execute/issue pipelined — i.e., the retire redesign is **necessary but not sufficient** for 7.5. |
| **IPC** | R1/R2 ≈ **neutral-to-positive**, R3 ≈ **risk on contended atomics** | decoupled retire *reduces* head-of-line store blocking (stores retire without waiting the merge-match / drain), typically IPC-positive; the drain side is already decoupled so no regression there. R3's multi-cycle atomic pays latency on *contended* atomics (already true post-P9.3.B, per CLAUDE.md litmus note). Fits the ~10–15 % budget with margin *if* R3 is done carefully. |
| **SMP-correctness risk** | **HIGH — the dominant cost** | R3 touches the exact machinery the litmus battery + M3b wedge validate (§3.4/§3.6). The full ladder (litmus N2/N4, SMP boot N2/N4, Verilator NBA — which caught MEM_PIPE M-stage bugs the Veryl sim masked) is mandatory and the redesign is one long minefield-crossing. This is why the plan deferred it. |
| **area / effort** | **large** — bigger than the whole campaign so far | a real SQ (address + data + age + committed bits), execute-time translate wiring for atomics, atomic-in-SQ ordering, precise-exception replay. Everything to date was FF-insertion into existing comb paths; this is new structure. Multi-turn, SMP-gated. |

---

## 5. Recommendation for the §6.1 target decision

**The data (this study) says three things:**

1. **The retire/memory-ordering redesign is the ONLY lever below 13.71 ns.** Every other front the campaign
   built is already masked below it, and FF-insertion/deferral cannot cut it (§1). So *if* the campaign
   continues to reduce CP at all, this redesign is mandatory — there is no cheaper alternative.

2. **But the retire redesign alone reaches ~12.4 ns, not 7.5 ns.** Its measured ceiling is the
   dcache-internal fill/victim floor (Direction-C §8: ~vrf 12.49). That is **exactly the plan's own
   "IS-stage-depth ~12 ns / 6–7 stages" fallback target** (`deep_pipeline_sram_plan.md`:132-134). Reaching
   7.5 ns requires the retire redesign **plus** pipelining the dcache-internal memory floor **plus**
   exposing the A-SCHED scheduler loop — a multi-front program, of which the retire redesign is only the
   first (and largest-risk) phase.

3. **The dominant cost is SMP-correctness risk, concentrated in R3 (atomic reorder), not IPC or CP.** R1+R2
   (decoupled retire + translate-at-execute) are moderate-risk and IPC-neutral-to-positive; R3 crosses the
   litmus/M3b minefield the plan deliberately deferred.

**Recommendation (for the user's decision — the target is the user's call, not lowered here):**

- **Revise the realistic near-term FINAL target to the IS-stage-depth ~12 ns / 6–7 stages** — which the
  retire redesign (R1+R2, the lower-risk two-thirds) achieves — and hold **7.5 ns / 10-stage as the
  long-term aspiration**, explicitly contingent on (i) R3 clearing the SMP ladder and (ii) the subsequent
  memory-floor + scheduler pipelining. This matches the plan's pre-registered decision gate and is honest
  about the two facts above: the redesign is necessary but not sufficient for 7.5, and its ceiling is ~12.
- **Do NOT start R3 (or the full flip) autonomously.** Sequence the *low-risk* two-thirds first if the user
  wants to proceed: **R1 (decoupled-retire scaffold) then R2 (extend `STORE_PRETRANSLATE`-style
  execute-translate to the SQ)** — both can be built as `DEAD` param scaffolds (byte-identical at 0, the
  campaign's proven methodology) and measured before committing to R3. R3 is the gated, SMP-critical
  finale.
- **Alternatively, bank the campaign's CP work as-is** (all scaffolds built + verified, dcache off
  `n_inflight`, `§11.8`) and pivot to the **SRAM-realism deliverable** (the tapeout-relevant goal (b)) or a
  consolidation/default-flip checkpoint — accepting ~13.7 ns as the CP floor for the current retire µarch.
  The retire redesign is then a future, separately-scoped program.

**Bottom line:** the 7.5 ns target is *reachable* but only via a large, SMP-critical, multi-phase retire +
memory-ordering + memory-floor + scheduler program whose first phase (this redesign) itself lands at ~12 ns.
The evidence supports **revising the near-term target to ~12 ns** and treating 7.5 ns as a longer program —
but this is the user's §6.1 decision, and the study's job is to make it on data, which it now is.
