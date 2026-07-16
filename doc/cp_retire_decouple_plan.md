# R1 — decoupled retire + store queue (design plan)

Design phase for **R1**, the lower-risk first phase of the retire/memory-ordering redesign
(`retire_memory_ordering_redesign_study.md` §4). Goal: take the **live-TLB-fed retire gate** off the
`rob_commit_ack → n_inflight` critical path so the CP drops from the 13.71 ns retire wall toward the
~12.4 ns memory floor (the revised IS-stage-depth target, `deep_pipeline_status_and_replan.md` §8). This
doc resolves the hard questions **before** any RTL, the way `cp_dcache_sync_read_plan.md` §10/§11 did for
the D$ — the retire path is the SMP-ordering heart, so the design is scrutinised first.

Companion: the study §3 (the code map this builds on), `cp_commit_store_pretranslate_plan.md` (the
existing `STORE_PRETRANSLATE` scaffold R2 generalises), `cp_direction_c_port_separation_plan.md` §8 (the
~12.4 ns floor this lands on).

---

## 1. The precise target — two arms of one gate, both live-TLB-fed

From the study §3.1 + the §11.8 bundle measurement, `rob_commit_ack` (the ROB-head retire gate, freeing the
entry / decrementing `u_fl.n_inflight`) has **two store arms that both route through the live `u_dmem_mmu`
TLB**:

```
rob_commit_ack = rob_commit_valid && … 
   && !(c_is_store && sb_elig && sb_full && !sb_merge_ok)   // ARM-A: fast-store SB merge-match
   && !commit_trap-producing store/atomic fault             // ARM-B: fault/PMP → commit_trap
```

- **ARM-A (merge-match).** `sb_merge_ok → sb_match_v` scans the 4 SB entries against
  `sb_pa[63:6] = (dmem_vm_on_op ? dmu_dmem_addr(LIVE TLB) : c_store_addr)`. For a VM-on store the scan input
  is the live-TLB PA. On the retire path only when `sb_full`.
- **ARM-B (fault/PMP).** `commit_store_fire → AGU → live TLB translate → u_pmp_cbo_m_w → sfault/commit_trap
  → rob_commit_ack`. This is the arm the §11.8 bundle cone showed dominant (137 levels, `tlb_*` ×24) —
  because that measurement had `STORE_PRETRANSLATE=1`, which already registers ARM-A's `sb_pa` for **plain**
  stores, leaving ARM-B (**atomics + non-pretranslated VM stores**) as the residual live-TLB floor.

**Key consequence (scoping R1 vs R3):** with plain-store pre-translate on, the residual 13.71 floor is the
**atomic** commit path (`commit_store_fire` fires for AMOs; an AMO re-drives the MMU at commit — the
`AMO_XLATE_DFR` deferral was REFUTED, `cp_frontend_pipeline_plan.md` §13). So:

- **R1+R2 for PLAIN stores** cuts ARM-A and the plain-store ARM-B in the **default** build (where
  `STORE_PRETRANSLATE=0` and plain stores DO re-drive the live TLB at commit). This is the tractable,
  low-SMP-risk two-thirds.
- **The atomic ARM-B is R3** — the residual bundle floor, SMP-critical (M3b), deferred.

So R1's honest near-term win is: **make the plain-store retire path fully registered** (no live TLB, no
merge-match on `rob_commit_ack`), generalising + hardening the `STORE_PRETRANSLATE` groundwork into the
retire gate itself. Whether that moves the *bundle* CP (which is atomic-bound) is measured after; it
unambiguously advances the FINAL structure (decoupled retire) and cuts the *default*-build commit front.

---

## 2. The shape — decouple ALLOCATION from RETIRE (the SB is already drain-decoupled)

From study §3.2, heliodor's SB is **already decoupled on the drain side** (`sb_pop` runs at the dcache's
pace; a fast store retires the cycle `sb_push` fires, even while older entries drain). The one fusion left
is **allocation = retire**: `rob_commit_ack` waits on `sb_push`'s merge-or-room test, whose merge arm is
live-TLB-fed. The shape:

- **R2 (translate-at-execute, universal).** At the store's EXECUTE cycle, translate its VA→PA (the AGU +
  MMU already run there for the address) and register `{pa, fault, uncached, …}` into a per-ROB-entry
  shadow (`sh_store_pa`/`sh_store_fault`, the way `store_pretx_*` does for the pre-translate probe, but for
  **every** store, unconditionally). The commit then reads flops, never the live TLB.
- **R1 (retire gate on a registered condition).** The fast-store retire term becomes `!(sb_elig &&
  sb_full)` — a **registered `sb_cnt` compare**, dropping the `!sb_merge_ok` (live-TLB merge scan) unblock.
  The SB WRITE uses the registered `sh_store_pa`; the merge scan (which entry to combine into) still runs,
  but now (a) off the retire gate and (b) on the *registered* PA (shallow), feeding only the SB register D.
- **Precise exceptions.** A store that faults must NOT retire-into-SB. With R2 the fault is registered at
  execute (`sh_store_fault`), available at retire as a flop — so `commit_trap` reads the registered fault,
  not the live TLB. (This is exactly what `AMO_XLATE_DFR` tried for atomics but the atomic *also* re-drives
  the MMU for its RMW; a plain store does not — it only needs the fault + PA, both registerable.)

**Net:** `rob_commit_ack`'s plain-store arms become `sh_store_fault[head]` (flop) + `!sb_full` (registered
count) — no live TLB, no merge scan. The live TLB stays only for **loads** (Stage-A) and **atomics** (R3).

---

## 3. Hard questions to resolve before the scaffold

1. **Q1 — Does R1+R2 for plain stores move the CP, or only the default-build front?** The bundle floor is
   atomic-bound (§1). Measure: with `STORE_PRETRANSLATE=1` already in the bundle, does the R1 retire-gate
   decouple change anything, or is it a no-op until R3? **Resolve by a throwaway bundle synth of the R1
   scaffold** before investing further — if the plain-store decouple is fully masked by the atomic ARM-B,
   R1's value is structural (default-build + FINAL-structure) not bundle-CP, and R3 must follow to see CP.
2. **Q2 — SB sizing / the dropped merge-when-full.** R1 drops "merge into a full SB to avoid a retire
   stall." How often is the SB full AND the store same-line? Measure the IPC cost (boot-cy / CoreMark);
   if non-negligible, either bump `SB_N` (4→6/8) or keep a *registered* merge-when-full (the previous
   cycle's merge verdict, not the live one). Budget: the ~10–15 % IPC.
3. **Q3 — Store→load ordering.** The load poison-replay scan (rob.veryl:863) resolves the store's address
   at commit and scans younger loads. With R2 the store PA is registered at execute — does the scan use
   the registered PA (good, earlier) and stay correct? Verify the scan's timing + that no ordering window
   opens (a load that executed between the store's execute and commit must still be checked).
4. **Q4 — Atomics untouched.** R1 must decouple only PLAIN (`sb_elig`) stores; the `!sb_elig` AMO/SC path
   (in-cache RMW, `amo_cwr_en`, watch/poison) stays exactly as-is (R3 territory). Confirm the scaffold's
   `if RETIRE_DECOUPLE` gates never touch the atomic arms → the SMP litmus/M3b machinery is byte-identical.
5. **Q5 — Interaction with `MEM_PIPE`/`STORE_PRETRANSLATE`.** R2 generalises `STORE_PRETRANSLATE` (which
   probes at execute for a *clean cacheable hit* only). R2 must register the PA for **all** stores incl.
   misses/uncached (they still need the registered PA at retire, just routed to the slow path). Decide:
   extend `STORE_PRETRANSLATE`, or a new universal `sh_store_pa` shadow. Likely the latter (cleaner, always
   valid), with `STORE_PRETRANSLATE`'s fast-drain path as a consumer.

---

## 4. DEAD-scaffold strategy (the campaign's proven methodology)

Param `RETIRE_DECOUPLE: bit = 0` (+ its R2 companion, e.g. `STORE_XLATE_EXEC`). At `=0` byte-identical
(every changed `rob_commit_ack` term / SB-write source is `if RETIRE_DECOUPLE ? <=1 registered> : <exact
original>`; new `sh_store_*` regs const-gated → DCE, per the §10.10 rule). Build order:

1. **R2 shadow** — `sh_store_pa`/`sh_store_fault` registered at execute (DEAD; the regs DCE at 0). Verify
   byte-id (252/0, litmus N2 cy-exact, synth CP/FF unchanged, N1 boot cy-exact).
2. **R1 retire-gate swap** — `rob_commit_ack` plain-store arms read the shadow + `!sb_full` under
   `RETIRE_DECOUPLE`. Verify byte-id at 0.
3. **FF-insertion / bundle measurement (Q1)** — throwaway synth with `RETIRE_DECOUPLE=1` (+ the bundle) to
   see if/where the CP moves. This decides whether R1 alone is CP-visible or needs R3.

## 5. Verification ladder (retire = SMP-ordering heart — the full ladder gates the =1 flip)

Same as the D$ (`cp_dcache_sync_read_plan.md` §11.4): DEAD `=0` — default 252/0 + litmus N2 cy-exact +
synth CP/FF/levels/endpoint unchanged + N1 boot cy-exact. FUNCTIONAL `=1` — the full SMP ladder: litmus
N2/N4 + N2/N4 SMP boot + Verilator (NBA — caught the MEM_PIPE M-stage corners) + ACT4 + the IPC budget
(Q2). The `=1` flip is the gated step; the DEAD scaffolds land freely.

**▶️ First step:** build the R2 shadow (`sh_store_pa`/`sh_store_fault` at execute) as a DEAD scaffold and
verify byte-identical — the smallest piece that grounds the rest. Then R1's retire-gate swap, then the Q1
measurement to decide the R3 dependency.

---

## 6. MEASURED (2026-07-07) — Q1 answered UP FRONT: R1+R2-plain is already built (STORE_PRETRANSLATE) and MASKED; the binding is the SLOW-store fault via a runtime-mux live TLB

Before building the R2 shadow, the existing store machinery was read + the §11.8 bundle cone re-traced for
store-type discriminators. **Two findings collapse the "low-risk R1+R2-plain" premise:**

**(a) STORE_PRETRANSLATE already IS R1+R2 for the plain (fast) store.** `heliodor_core.veryl` already
registers the plain VM store's PA (`m_pa_q`, `store_pretx_pa`) and fault (`m_spage_q`/`m_sacc_q`/`m_gstage_q`)
at the execute/M-stage (`:1677-1696, :7293-7295`), and the commit reads them via `sfault_*_eff` (`:4020-4022`),
`c_store_eff_pa` (`:5495`) → `sb_pa` (`:6060`) → the retire gate. So the intended R2 shadow +
R1 retire-source-swap **exist** for plain stores; a fresh `sh_store_*` shadow would duplicate them.

**(b) But it does NOT cut the live TLB — the deferral is a RUNTIME MUX (the §13 flaw), and the binding is
the FAULT, not the PA.** Re-tracing the bundle `n_inflight` cone (STORE_PRETRANSLATE=1) for discriminators,
the binding path is:
```
agu_addr_iss / c_store_addr → dmem_mmu.i_vaddr → LIVE TLB (dmem_mmu.u_mmu.tlb_* ×~40)
   → sfault_pg_eff → u_pmp_cbo_m_w (the cbo.m PMP, ×20) → commit_trap → rob_commit_ack → n_inflight
```
It is the **fault check** (`sfault_pg_eff`), **not** the PA/merge (`c_store_eff_pa`/`sb_merge_ok`/`sb_pa`
are absent from the cone). And `sfault_pg_eff = if !store_xlate_dfr ? dmem_mmu_fault_s : … m_spage_q` is a
**runtime 2:1 mux** — exactly the `AMO_XLATE_DFR` refutation (`cp_frontend_pipeline_plan.md` §13): a runtime
gate cannot prune the live arm, so `sfault_pg_eff`'s delay ≥ the live TLB **for every store sharing that
wire**. Worse, `store_xlate_dfr` (`:4019`) **excludes `c_is_amo`, `c_is_cbo_zero`, `c_is_cbo_m`** — so the
slow/management ops' fault is *unconditionally* the live TLB, and the `u_pmp_cbo_m_w` in the cone points at
**cbo.m** (a cache-block-management op) as a concrete binding requester.

**Consequence — Q1 answered: R1+R2 for plain stores does NOT move the bundle CP.** The plain fast-store
decouple is already built (STORE_PRETRANSLATE) *and* is masked below the **slow-store commit-fault path**
(cbo.m / atomic / TLB-miss), whose live TLB binds `rob_commit_ack` — kept there by a runtime mux, not
prunable by FF-insertion. To move the CP below 13.71 the SLOW-store fault must come off the live TLB, which
means **const-gating** the deferral (not a runtime mux) AND registering the cbo.m / atomic fault at
execute — and for atomics that is the §13-refuted problem (the atomic re-drives the MMU at commit for its
coherent RMW, not just the fault). **So R1's CP value is gated on R3 (the SMP/management-critical slow-store
path), confirming the study's §4 finding. There is no independent low-risk R1+R2-plain CP win left.**

### 6.1 Revised approach

The honest levers below 13.71 are now clear, none of them "low-risk plain R1":

- **(L1) Const-gate the fault deferral (fix the §13 runtime-mux flaw).** Replace `sfault_*_eff`'s
  `if !store_xlate_dfr ? live : reg` runtime mux with a **const-gated** `if RETIRE_DECOUPLE ? reg : live`,
  so the live arm DCEs — *but* only valid if the registered fault covers every store on that wire,
  including cbo.m/atomic. Needs their execute-time fault registration (below). Measure whether even the
  plain-store wire then drops (it may still be pinned by the shared slow-store requester).
- **(L2) Register the cbo.m fault at execute.** cbo.m is a *management* op (no RMW) — its fault may be
  execute-registerable like a plain store (unlike an atomic). Investigate why `store_xlate_dfr` excludes it;
  if it is mere conservatism, extending the (const-gated) registration to cbo.m could cut the concrete
  binding requester the cone named. **Lower-risk than the atomic and a concrete first target.**
- **(L3) The atomic slow path = R3.** The §13-refuted RMW-re-drive; the SMP minefield; deferred.

**▶️ Revised first step:** investigate **(L2)** — why cbo.m is excluded from `store_xlate_dfr`, and whether
its commit fault can be registered at execute + const-gated. If yes, it is the smallest concrete CP lever
(cuts the cone's named `u_pmp_cbo_m_w`/live-TLB requester) at lower SMP risk than the atomic. If cbo.m
genuinely needs live commit translation, then the only remaining lever is R3, and the campaign should either
commit to that SMP-critical program or bank the CP work per `deep_pipeline_status_and_replan.md` §6.
**This is a user decision** (the low-risk R1 premise is gone; what remains is R3-adjacent) — surface before
building.

### 6.2 L2 investigated (2026-07-07) — cbo.m IS execute-registerable, but the shared TLB means no single-requester CP win

Read the cbo.m path: `cbo_m_addr = dmem_vm_on_op ? dmu_dmem_addr : c_store_addr` (`:5541`) is the **live**
TLB PA; `u_pmp_cbo_m_r/w` (`:5544-5558`) PMP-check it; `cbo_m_acc_fault = c_is_cbo_m && cbo_m_pmp_deny_r &&
cbo_m_pmp_deny_w` (`:5560`, R-AND-W deny — cbo.m's special fault, why it is excluded from the standard
`sfault_*` deferral, not a fundamental live-translation need). cbo.m is a **management op (no RMW)**, so —
unlike an atomic — its PA + fault **could** be registered at execute (like `m_pa_q`) and const-gated at
commit. So L2 is structurally viable and lower-risk than the atomic.

**But it does not move the CP alone.** cbo.m, atomics, and non-pretranslated stores **share the single
`u_dmem_mmu` port/TLB**. The TLB output reaches `rob_commit_ack` through *whichever* of them re-checks at
commit; cutting one requester (cbo.m) just leaves the live TLB on the retire gate via the next (atomic /
the runtime-mux `sfault_pg_eff` for other stores). The TLB itself cannot be removed (loads' Stage-A needs
it) — only its arrival at `rob_commit_ack` can, and that requires **every** commit-time store/atomic/cbo
fault requester to read registered values. **So there is no independent low-risk sub-step that moves the
CP; the whole slow-store-commit-fault decouple (L1 const-gate + L2 cbo.m + L3 atomic) is one R3-adjacent
program**, its dominant cost the atomic (L3 = the §13-refuted, SMP-critical minefield).

**Conclusion:** the campaign has reached the end of independent, low-/moderate-risk CP levers. Below 13.71 ns
lies only the atomic-inclusive slow-store retire redesign (SMP-critical). The honest options are now the
`deep_pipeline_status_and_replan.md` §6 set: **commit to the R3-adjacent program** (large, SMP-gated) **or
bank the CP work** (all scaffolds built + verified; ~13.7 ns accepted as the current-µarch floor) **and
pivot** to the SRAM-realism deliverable (goal b) or a consolidation/default-flip checkpoint. **User
decision.**

---

## 7. R3 COMMITTED (2026-07-16) — the concrete staged build plan

**User decision (2026-07-16):** after the D$ tag-array SRAM sub-track reached its own end (tag §15.5-S2 =
zero synth-area/CP payoff, tag RAM is bit-capacity-charged + 11 live SMP coherence/AMO consumers), pivot
back to the CP front and **commit to R3** (the atomic-inclusive slow-store retire decouple) — the one lever
that cuts the real wall.

**Fresh measurement (2026-07-16, current default build, `synth --dump-timing`):** the default headline is
**14.745 ns** — the fused front-end→scheduler cone `pc_q → decode(dec_op2) → rename_fire → alloc_op →
rs1_rdy` (the 8 `u_iq.rs1_rdy[*]` endpoints), NOT the retire wall. A throwaway `FETCH_REG=1 + DECODE_REG=1`
front-end-register flip drops it to **14.130 ns** and exposes exactly the **`n_inflight` commit-store
megacone** (`head → commit_store_fire → AGU → MMU translate → n_inflight`) as the new binding front — the
R3 wall. Below it: `vrf` 13.880, scheduler ~10 ns (all masked). **So the front-end/A-EXE/A-SCHED scaffolds
shave only ~0.6 ns before hitting the R3 wall; R3 is the only lever below ~14.1 ns.** (`fp_divider`/`fp_sqrt`
do NOT appear in the top-30 paths — a masked deep floor, not the headline; the earlier "easiest CP lever"
guess was wrong.)

### 7.1 The full LIVE commit-fault source inventory (everything on `rob_commit_ack` via commit_store_sacc/sfault, `:4353-4354`)

R3 must make ALL SIX read execute-registered values so the live TLB+PMP cone DCEs off the retire gate:

1. **`sfault_pg_eff` / `sfault_acc_eff` / `sfault_gs_eff`** (`:4350-4352`) — the MMU page/access/G-stage
   fault, runtime-muxed `if !store_xlate_dfr ? live(dmem_mmu_*_s) : reg(m_spage_q/m_sacc_q/m_gstage_q)`.
   Registered (M-stage `m_*_q`, `:7625-7628`) only for the plain STORE_PRETRANSLATE class; LIVE for
   cbo.m / atomic / non-pretranslated stores.
2. **`dmem_mmu_pte_acc_fault`** (`:534`) — live MMU-walk PTE-PMP deny (cbo.m keeps it live).
3. **`dmem_mmu_pma_hole`** (`:535`) — live PMA hole on the translated PA (cbo.m keeps it live).
4. **`fast_store_acc_fault`** (`:5790`) — fast (bare store-drain) PMP deny — a SEPARATE PMP path, not
   through the dmem MMU.
5. **`amo_commit_acc_fault`** (`:5840`) = `commit_store_fire && c_is_amo && amo_commit_pmp_deny` — the
   atomic commit-time WRITE PMP (`u_pmp_amo_commit`, `:5832`, on LIVE `dmu_dmem_addr`).
6. **`cbo_m_acc_fault`** (`:5890`) = `… && cbo_m_pmp_deny_r && cbo_m_pmp_deny_w` — cbo.m R-AND-W PMP deny
   (`u_pmp_cbo_m_r/w`, `:5874-5888`, on LIVE `cbo_m_addr = dmu_dmem_addr`).

**Why cbo.m/atomic are the hard part:** their PA/fault is computed at COMMIT (they re-drive the dmem MMU at
commit — `cbo_m_addr`/`amo_commit` PMP inputs are the live `dmu_dmem_addr`). The M-stage `m_*_q` flops capture
`dmu_dmem_addr` every cycle but at EXECUTE that port carries the load/plain-store, not the cbo.m/atomic. So
registering their fault requires ROUTING them through the MMU at EXECUTE (like STORE_PRETRANSLATE does for
plain stores) — a datapath change. For the ATOMIC, §13 refuted deferring the translate because the atomic
ALSO re-drives the MMU at commit for its coherent RMW (not just the fault) — that is L3, the SMP minefield.

### 7.2 Staged build sequence (each a full-slow-gate flip; DEAD scaffold → verify byte-id → flip)

- **✅ S0 (2026-07-16) — the const-gate skeleton.** `const RETIRE_DECOUPLE: bit = 0` (`:4348`). The three
  `sfault_*_eff` become `if RETIRE_DECOUPLE ? (store_fetched_q ? m_*_q : 0) : <the exact STORE_PRETRANSLATE
  runtime mux>`. At =0 const-folds to the current mux = byte-identical (the live arm survives). Reserves the
  const-gated structure exactly like the D$ §13.7 S0 spine; the =1 arm is only fully correct once L2/L3 land.
- **L1 — const-gate the remaining `_eff` live terms + PMP-result registration groundwork.** Fold
  `dmem_mmu_pte_acc_fault` / `dmem_mmu_pma_hole` and the PMP-deny results into registered M-stage flops
  (`m_pte_acc_q` / `m_pma_hole_q`, captured at execute alongside `m_pa_q`), const-gated under
  RETIRE_DECOUPLE. Byte-id at 0.
- **L2 — cbo.m execute-translate + fault register.** cbo.m is a MANAGEMENT op (no RMW), so route its VA
  through the dmem MMU at execute (extend the STORE_PRETRANSLATE probe to `c_is_cbo_m`) and register
  `{cbo_m_pmp_deny_r, cbo_m_pmp_deny_w, m_pa}`; the commit reads the flops. Structurally viable, lower risk
  than the atomic (§6.2). Does NOT move CP alone (shared TLB) — must land with L1+L3.
- **L3 — atomic execute-translate + fault register (the SMP minefield).** Register the atomic's
  `amo_commit_pmp_deny` + MMU fault at execute; the RMW re-drive at commit stays LIVE for the coherent
  memory op but reads the REGISTERED PA/fault for the trap decision (the §13-refuted split: fault-at-execute,
  RMW-at-commit-on-registered-PA). Highest risk = M3b atomicity (a +1 skew on the commit write wedges litmus
  N2 amoadd — proven). Co-design + re-verify at each sub-step.
- **L1-flip — const-gate on.** Once L1+L2+L3 register every requester, flip `RETIRE_DECOUPLE=1` so the live
  TLB+PMP arm DCEs off `rob_commit_ack`. Measure the bundle CP (target ~12.4 ns memory floor).

### 7.3 Verification ladder (retire = SMP-ordering heart)

Per §5: DEAD `=0` — default 252/0 + litmus N2 cy-exact + synth CP/FF/levels/endpoint unchanged + N1 boot
cy-exact. FUNCTIONAL `=1` — the FULL SMP ladder: litmus N2/N4 + N2/N4 SMP boot + Verilator (NBA — the M3b
minefield surfaces only on multi-hart NBA) + ACT4 (S-mode paging + cbo.m + PMP suites) + the IPC budget.
The `=1` flip is the gated step; the DEAD scaffolds land freely.

### 7.4 L2/L3 feasibility — the fault-capturing translation problem (2026-07-16, post-S0 code read)

Reading the store-pretranslate / MMU-port machinery to scope L2 surfaced a finding that shapes the whole
L2/L3 design:

**(a) The STORE_PRETRANSLATE probe captures only CLEAN PAs — it cannot register a fault.** The dmem MMU's
side-effect-free TLB probe (`dmem_sprobe_pa/ok`, `:5973-5977`) latches a PA only on a clean store-permitted
hit (`dmem_sprobe_ok`); **any deny / miss / uncached / mid-walk falls back to commit translation**, and
`store_pretx_xfault` is a hard `1'b0` (`:5974`). So the existing probe is the WRONG tool for R3's fault
decouple — R3 registers FAULTS, the probe registers only fault-free PAs.

**(b) What S0 already covers, and what is left.** A plain VM store DOES translate at the MEM_PIPE M-stage
(`store_fetched_q` 2-cycle hold), so `m_spage_q`/`m_sacc_q`/`m_gstage_q` (`:7625-7628`) already register its
page/access/G-stage fault — the source S0's `=1` arm reads. **So after S0, plain VM stores are decoupled.**
The residual LIVE commit-fault terms are all cbo.m / atomic / bare:
  - `cbo_m_acc_fault` + `dmem_mmu_pte_acc_fault`/`pma_hole` (cbo.m-only) — cbo.m translates at **commit**
    (`core_dmem_cbo = core_dmem_wen && c_is_cbo_m`, `store_drive`-routed, `:5981`); at execute it asserts no
    dmem MMU ren/wen, so `m_*_q` do NOT hold its fault.
  - `amo_commit_acc_fault` — the atomic re-drives the MMU at commit (§13).
  - `fast_store_acc_fault` — a BARE PMP on `c_store_addr` (`:5790`, not through the TLB) → **non-binding**
    (the §7.1 cone is the TLB path, not this); registering it is cleanup, not a CP lever.

**(c) L2 (cbo.m) approach — route cbo.m through the M-stage translate, reuse `m_*_q`.** cbo.m is a NOP (no
memory op), so a squashed cbo.m discards freely. Make cbo.m assert an execute-time dmem-MMU translate
request (like a store's MEM_PIPE M-stage) so `m_spage_q`/`m_sacc_q` capture its page/access fault, and add
an M-stage PMP R-AND-W check on `m_pa_q` registered into `m_cbom_pmp_q` (cbo.m's special R-AND-W deny rule,
`:5905`). Const-gate `cbo_m_acc_fault` + the `pte_acc`/`pma_hole` terms to read the registered values at =1.
**Caveat — the TLB-MISS case:** a TLB-hit cbo.m registers cleanly, but a TLB-MISS cbo.m needs a full walk;
doing it at execute is a SPECULATIVE walk (squash-safe for a NOP, but contends with load walks + deepens
cbo.m). If we instead keep the TLB-miss cbo.m on the commit fallback, the live TLB is NOT fully off the
retire gate → the `=1` live arm cannot DCE → **no CP**. So L2's CP value requires cbo.m to ALWAYS translate
at execute (speculative walk), not just on a TLB hit. **This is the crux to resolve before the L2 RTL.**

**(d) L3 (atomic) — the §13 split + M3b.** Register the atomic's fault + PMP at execute (same M-stage route)
but keep the coherent RMW LIVE at commit on the REGISTERED PA (the fault-at-execute / RMW-at-commit split
§13 refuted for *deferral* but which R3 must implement as a *const-gate*). Highest risk: a +1 skew on the
atomic commit write wedges litmus N2 amoadd (M3b, proven) — the RMW must stay single-cycle at commit.

**(e) Consequence for staging + CP.** Every L2/L3 piece is byte-identical at `=0` and moves NO CP alone; the
CP lands only at the full `RETIRE_DECOUPLE=1` flip once cbo.m AND atomic AND (for completeness) fast-store
all read registered faults and the live TLB+PMP arm DCEs. The dominant new machinery is the **speculative
execute-time walk** (cbo.m + atomic), which is A-LOOP-adjacent depth — confirming §6.2's "R3 is one
SMP-critical program." **Recommended next RTL: L2 cbo.m** — the lower-risk of the two real requesters
(NOP → squash-free, no RMW), starting with the M-stage-translate route + the speculative-walk decision (c).

### 7.5 ✅ L2 IMPLEMENTED (2026-07-16) — cbo.m rides M3a; NO speculative walk (§7.4c corrected)

Building L2 corrected §7.4(c)'s "speculative execute-time walk" concern — it was over-thought. **A VM cbo.m
is `c_is_store` (`mem_wen=1`, `decoder:673`) + `!sb_elig` (VM ⇒ not a fast store), so it ALREADY rides the
M3a `store_fetched_q` 2-cycle commit.** Its MMU walk still happens at commit exactly as before (the retire is
stalled by `dmem_mmu_busy` during the walk); `store_fetched_q` sets the cycle N the walk completes
(`!dmem_mmu_busy`), the fault is registered at N, and retire fires at N+1 from the flops. **No execute-time
translate, no speculative walk** — just the +1 retire deferral M3a already pays for every slow store. So S0
already registered cbo.m's page/access fault (`m_spage_q`/`m_sacc_q`); L2 adds the four REMAINING cbo.m-only
sources at the same cycle N: `m_pte_acc_q`/`m_pma_hole_q` (walk PTE-PMP deny / PMA hole) and
`m_cbom_pmp_r_q`/`m_cbom_pmp_w_q` (the R-AND-W PMP on the live TLB PA — the §7.1 binding requester
`u_pmp_cbo_m_w`). `commit_store_sacc`/`sfault` route the walk-fault terms through `pte_acc_eff`/`pma_hole_eff`
and `cbo_m_acc_fault`'s PMP through the flops, all `if RETIRE_DECOUPLE ? (store_fetched_q ? reg : 0) : live`.

**Committed DEAD (`07843e8`), byte-identical:** veryl test 252/0, litmus N2 cy=00231860 (baseline-exact),
synth headline 14.745 ns @ rs1_rdy (the flops DCE at 0). At `RETIRE_DECOUPLE=1` the cbo.m live TLB+PMP cone
is now fully off `rob_commit_ack` (S0 page/access + L2 pte_acc/pma_hole/PMP).

**Implication for L3 (atomic):** the atomic is NOT a `store_fetched_q` slow store — M3a EXCLUDES it
(`!c_is_amo`, its commit write is single-cycle live `amo_commit_live`). But the M4 machinery already captured
its read-time translated PA in `ac_pa_q` (held issue→commit, = the commit PA — it drives the write). So L3
did NOT touch the write timing (no M3b risk): it sources the AMO commit-PMP address off the REGISTERED
`ac_pa_q` (`u_pmp_amo_commit i_addr : if RETIRE_DECOUPLE ? ac_pa_q : <live>`), leaving the TLB off the retire
gate while the RMW write stays live single-cycle. Committed DEAD `3183010` (byte-identical: 252/0, litmus N2
cy=00231860, synth 14.745 ns @ rs1_rdy).

### 7.6 ✅ MEASURED (2026-07-16) — the R3 flip CUTS the n_inflight wall (14.130 → 13.880, TLB off the retire gate)

Throwaway synth flip (all four latent fronts on: `FETCH_REG` + `DECODE_REG` + `STORE_PRETRANSLATE` +
`RETIRE_DECOUPLE` = 1; then reverted) confirms R3 achieves its goal:

| Config | headline | binding front |
|---|---|---|
| default | 14.745 | front-end→scheduler cone (`pc_q → decode → rename → rs1_rdy`) |
| + front-end register | 14.130 | **`n_inflight` commit-store wall** (`head → commit_store_fire → dmem_vaddr → live TLB → n_inflight`) |
| + front-end + `RETIRE_DECOUPLE` (STORE_PRETRANSLATE=0) | 14.130 | STILL `n_inflight` — the STORE **PA** translate binds (RETIRE_DECOUPLE cuts only the FAULT; the plain-store PA is live at commit until STORE_PRETRANSLATE registers it) |
| + front-end + `STORE_PRETRANSLATE` + `RETIRE_DECOUPLE` | **13.880** | **`n_inflight` GONE (0 of the top paths)** → `vrf` now binds |

So **R3 needs its PARTNER `STORE_PRETRANSLATE`** (PA registered) to show CP — RETIRE_DECOUPLE registers the
FAULT, STORE_PRETRANSLATE registers the PA; both are needed for the live TLB to leave `rob_commit_ack`.
Together they cut the `n_inflight` commit-store wall from 14.130 to below 13.880 (the `vrf` front, previously
masked, now binds). R3's own contribution is ~0.25 ns — modest, but it removes the wall that masked
everything below it and takes the live TLB off the retire gate (the deep-pipeline structural goal). The next
front is `vrf` (the `VALU_PIPE` scaffold), then the coordinated multi-front flip.

**State:** S0 + L2 + L3 all committed DEAD + byte-identical. The `RETIRE_DECOUPLE=1` functional flip (with
`STORE_PRETRANSLATE=1`) is the GATED step — it needs the full SMP ladder (litmus N2/N4 + N2/N4 SMP boot +
Verilator NBA + ACT4 PMP/paging + IPC budget) before it can be enabled. Remaining scaffold-side: fast-store
(non-binding bare PMP; register for completeness, but it does not pin the TLB).

### 7.7 ✅ FULL 5-SCAFFOLD BUNDLE RE-MEASURED (2026-07-16) — 13.120 ns; the residual is the ATOMIC-commit LIVE TLB

The "next front is vrf" above refers to the ALREADY-BUILT `VALU_PIPE` scaffold (`vector_unit.veryl:63`,
committed DEAD 2026-07-02, `cp_vrf_cut_plan.md §6`) — NOT new work. All five front-cut scaffolds are built
(`FETCH_REG DECODE_REG STORE_PRETRANSLATE RETIRE_DECOUPLE VALU_PIPE`). Re-verified VALU_PIPE healthy after
the dcache+R3 churn (`veryl test` 252/0 at =1) and measured the full 5-flip bundle in the current tree:
**14.745 → 13.120 ns (−11 %)**, binding = `head → n_inflight[5]`. Gate trace shows the residual is the
**atomic (CAS/AMO) commit path re-driving the LIVE dmem MMU TLB** (`commit_store_fire → dmem_vaddr →
u_dmem_mmu.tlb_* → … → n_inflight`) — the §13/L3 coherent-RMW re-translate that L3 left LIVE (L3 only
sourced the AMO commit-PMP off `ac_pa_q`, not the TLB). So the plain-store TLB is off the retire gate, but
the atomic's is not. Below it: redirect_pc_q/mip ~12.6. Full detail + the top-30 band in `cp_vrf_cut_plan.md
§7`. **Next real lever below 13.120 = the atomic-commit TLB decouple (register the atomic's execute-time PA
+ permission so the commit RMW reads a flop — the hardest M3b SMP-atomicity work), or the redirect/CSR wall.**

## 8. ❌ REFUTED BY MEASUREMENT (2026-07-16, user-selected "atomic-commit TLB decouple") — a runtime `c_is_amo` gate CANNOT prune the shared live-TLB→sb_merge; §13 re-confirmed in the post-Phase-C tree

The user selected the atomic-commit TLB decouple. A code-based map (Explore) + two throwaway
CP-isolation synths establish that the residual 13.120 ns atomic cone is a **shared, false-path wall**,
not a surgically-cuttable requester — re-confirming `cp_frontend_pipeline_plan.md` §13 in the current tree.

**The map.** Under the full bundle (`MEM_PIPE=1` + `RETIRE_DECOUPLE=1` + `STORE_PRETRANSLATE=1`) the
atomic's commit-time live-TLB output `dmu_dmem_addr` has these consumers, ALL already registered EXCEPT one:
- WRITE PA → `ac_pa_q` (MEM_PIPE, `:7260`) ✅ ; PMP → `ac_pa_q` (RETIRE_DECOUPLE, `:5880`) ✅ ;
  page/access fault → `0` (RETIRE_DECOUPLE S0, atomic is `store_fetched_q=0`) ✅
- **`sb_pa` (= `c_store_eff_pa`, `:5861`) → still `dmu_dmem_addr` for a VM atomic** ❌ — feeds `sb_match_v`/
  `sb_merge_ok` → `rob_commit_ack`. But `sb_merge_ok` is MASKED for atomics (`sb_elig` requires `!c_is_amo`,
  `:6434`; the atomic never merges). So the cone is a **FALSE PATH**: STA cannot correlate the `c_is_cas_q`
  START with the `sb_elig=0` mask END, so it reports the live TLB. (`ac_pa_q` is captured at issue for every
  real AMO/SC/CAS — `is_cas_q ⊂ is_amo`, `decode.veryl:188` — but not LR; and `ac_pa_q == dmu_dmem_addr`
  for a correct serialized-head atomic, so any register-source is behaviourally identical.)

**Two throwaway CP-isolation flips (bundle=1 + a new `ATOMIC_PA_DECOUPLE` const; reverted):**

| config (on top of the 5-flip bundle @ 13.120) | headline | vs 13.120 |
|---|---|---|
| gate `c_store_eff_pa` → `if ATOMIC_PA_DECOUPLE && c_is_amo ? ac_pa_q : <live mux>` | **13.270** | **+0.15 WORSE** |
| + also gate `store_drive &&= !(ATOMIC_PA_DECOUPLE && c_is_amo)` (atomic skips the commit MMU drive) | **13.350** | **+0.23 WORSE** |

Both endpoints stay `head → n_inflight[5]`, **still CAS-started** (`c_cas_q_mem_hi → c_is_cas_q →
commit_store_fire → dmem_vaddr → u_dmem_mmu.tlb_* → … → sb_merge_ok → rob_commit_ack → n_inflight`).

**Root cause — the §13 refutation, exactly.** `c_is_amo` is a RUNTIME signal, so
`if c_is_amo ? ac_pa_q : dmu_dmem_addr` is a 2:1 mux whose `dmu_dmem_addr` arm stays logically reachable
(the `!c_is_amo` plain-store-miss path shares `c_store_eff_pa`) — STA cannot prune it and the extra mux
ADDS a level. Gating `store_drive` fails the same way: `commit_store_fire → store_drive` drives the
`core_dmem_vaddr` mux SELECT, so the arc `commit_store_fire → store_drive → mux → MMU` survives regardless
of the select VALUE; `&& !c_is_amo` just deepens `store_drive`. **A runtime gate cannot prune a shared,
logically-reachable live-TLB arm — precisely `cp_frontend_pipeline_plan.md` §13's "deferral-via-mux cannot
be faster than its slowest input."**

**Consequence.** The 13.120 residual is the SHARED live-TLB → `sb_merge_ok` coherence check (§13.1: even
forcing all commit faults free bottoms at ~13.27; the whole-commit-cone-off-MMU cut buys only ~1.3 ns →
~12.4, on the dcache-internal floor, at the highest SMP-atomicity risk). Cutting it needs a **CONST /
physical separation** of the atomic commit path from the shared MMU/`sb_merge` net — a separate
commit-translation port or a true multi-cycle commit stage (§13's M3b minefield, Direction-C §8 abandoned
at ≤1.3 ns as atomicity-bound), NOT a scaffold-level runtime gate. **Verdict: the atomic-commit TLB
decouple is refuted as a scaffold lever in the current tree.** The honest options below 13.120 are now the
`deep_pipeline_status_and_replan.md` §6 set: (a) **bank the −11 % bundle** (`14.745 → 13.120`, all five
scaffolds built + measured; flip is GATED on the full SMP ladder) and accept ~13.1 as the µarch floor;
(b) the **redirect/CSR wall** (`redirect_pc_q`/`mip` ~12.6, a different front, masked below 13.120);
(c) the **physical commit-path separation** (the largest, most SMP-dangerous redesign). Tree clean at
`00b4818` (all experiment code reverted; only this doc + `cp_vrf_cut_plan.md §7` changed).

## 9. 🚨 BUNDLE-FLIP FAST GATE (2026-07-16, user-selected "bank the −11 % bundle") — the bundle is NOT monolithic: R3-pair+VALU are FUNCTIONALLY CORRECT at =1, but the front-end registers are BROKEN (never functionally flipped)

Flipping all five scaffolds to =1 (permanent, not throwaway) and running the FAST gate (`veryl test`)
surfaces the key readiness fact: the DEAD scaffolds were verified byte-identical at =0 and CP-measured via
throwaway SYNTH, but their =1 FUNCTIONAL correctness (together) was never tested. Result:

| config (`veryl test`) | result |
|---|---|
| all five =1 (`FETCH_REG DECODE_REG STORE_PRETRANSLATE RETIRE_DECOUPLE VALU_PIPE`) | **23 / 229 FAIL** — pervasive HANG (`tohost=0`=timeout, even rv64ui-beq/lh) |
| **front-end OFF** (`FETCH_REG=DECODE_REG=0`), `STORE_PRETRANSLATE=RETIRE_DECOUPLE=VALU_PIPE=1` | **252 / 0 PASS** |

**So the 229 failures are ENTIRELY the front-end registers (`FETCH_REG`/`DECODE_REG`).** The SMP-critical
retire pair (`STORE_PRETRANSLATE` + `RETIRE_DECOUPLE`) + `VALU_PIPE` are **functionally correct at =1** on
the fast gate — R3's whole staged program (S0/L2/L3) works when flipped live. The front-end registers add a
fetch/decode pipe stage whose +1-shift redirect/squash timing was never fixed (they are CP-measurement DEAD
scaffolds), so mispredict/trap flushes wedge the pipe → pervasive timeout — exactly the class of the
`lsu-phase1` FRONT-pipeline flip's "3 +1-shift corner fixes" (FR squash NBA hazard / slot-1-load+FR deadlock
/ FP div-sqrt owner-exact broadcast, `project_heliodor_lsu_pipelining`).

**Consequence for "bank the −11 %".** The −11 % (14.745 → 13.120) REQUIRES the front-end registers: without
them the front-end→scheduler cone (14.745) MASKS the n_inflight wall, so R3-pair+VALU alone give 0 headline
CP (§7.6). So banking the −11 % = **debugging the front-end registers' +1-shift redirect/squash corners** —
a well-scoped but real multi-session task (the retire pair is already proven; only the front-end stage's
control timing is unfinished). The two sub-bundles:
- **R3-pair + VALU (3 scaffolds)** — functionally correct at =1 (fast gate), 0 headline CP alone (masked).
  Bankable as a STRUCTURE flip (retire-decouple + VU pipe live) via the full SMP ladder, if the campaign
  values the structure at 0 CP (per `feedback_heliodor_optimize_for_structure_not_cp`).
- **front-end regs (2 scaffolds)** — unmask the −11 %, but need the +1-shift corner debug before they pass
  even the fast gate. This is the gating work for the CP.

## 10. 🎉 RESOLVED (2026-07-16, user-selected "front-end +1-shift corner debug") — DECODE_REG is NOT NEEDED for the −11 %; a 4-scaffold bundle (FETCH_REG alone, no DECODE_REG) hits 13.120 and is FUNCTIONALLY CORRECT

Debugging the front-end registers (§9's gating work) surfaced a much better outcome than a hard pipeline-
register fix:

**Isolation (fast gate):**
- `FETCH_REG=1` ALONE → **252 / 0 PASS.** FETCH_REG makes the fetch buffer a true F|D pipeline register;
  decode reads `fb_instr[fb_head]` and the metadata reads `fb_pc[fb_head]` — **both from the same FB slot,
  so op + metadata stay consistent** (just +1 fetch latency). Functionally correct as-is.
- `DECODE_REG=1` ALONE → **FAIL** (vstr/amoxor/hint/hvsirq…). DECODE_REG registers `dec_op` but leaves the
  fetch metadata LIVE and `fb_pop == rename_fire` (`:1059`/`:2227`), so `dec_op_q` (cycle T−1's decode) is
  paired with `if_pc_q`/`if_v_q` (cycle T's FB head after the pop) → **metadata skew** (ROB entry gets op A
  with PC B) → wrong redirect targets → pervasive hang. This is the documented "FF-insertion measurement
  only, not functional" (`:1786-1791`); a real fix needs a valid/stall skid (register the metadata + split
  `fb_pop` from `rename_fire` + flush).

**The key measurement — DECODE_REG is MASKED, so it is not needed:**

| bundle (synth `--dump-timing`) | headline | binding |
|---|---|---|
| 5-scaffold (incl. DECODE_REG) | 13.120 | `head → n_inflight[5]` |
| **4-scaffold (FETCH_REG + STORE_PRETRANSLATE + RETIRE_DECOUPLE + VALU_PIPE, NO DECODE_REG)** | **13.120** | `head → n_inflight[5]` |

**Identical.** DECODE_REG contributes ZERO to the headline — it cuts the `decode → rename` segment, but that
segment is already BELOW the `n_inflight` wall (13.120), so it is masked. DECODE_REG would only matter if
`n_inflight` were cut further — and §8 refuted that (the atomic `sb_merge` wall needs a physical commit-path
separation). **So the hard DECODE_REG pipeline-register fix is AVOIDED: the −11 % (14.745 → 13.120) is
delivered by the 4-scaffold bundle, all of which are functionally correct** (`veryl test` 252/0 with all four
=1). `FETCH_REG` alone unmasks the wall exactly as well as `FETCH_REG+DECODE_REG` — the fetch-buffer register
is the F|D stage that drops the front-end cone below the wall; the D|R stage (DECODE_REG) is redundant until
the wall itself moves. **Next: the full SMP ladder (litmus N4 + SMP boot N2/N4 + Verilator NBA + ACT4
paging/PMP + IPC budget) gates the 4-scaffold commit** (`DECODE_REG` stays DEAD =0). `DECODE_REG` remains a
built-but-dead scaffold for a future sub-13.120 campaign.

## 11. 🚧 SMP LADDER (2026-07-16) — GREEN except ONE ACT4 test: a latent R3-L2 cbo.m PMP-write fault-decouple bug at =1

Ran the full SMP ladder on the 4-scaffold bundle (FETCH_REG + STORE_PRETRANSLATE + RETIRE_DECOUPLE +
VALU_PIPE = 1, DECODE_REG = 0):

| gate | result | IPC (=1 vs =0) |
|---|---|---|
| fast gate (252, incl litmus N2) | ✅ 252/0 | — |
| N1 boot (smoke/7.1/7.1v/6.6) | ✅ 4/4 pass | +4–5 % (7.1v 20.9M→22.0M) |
| SMP N2 boot | ✅ pass | +6.7 % (16.66M→17.78M) |
| **litmus N4** (R3's SMP-ordering gate) | ✅ **no forbidden** | +0.2 % |
| SMP N4 boot | ✅ pass | +1.3 % |
| **ACT4 696** | ❌ **695/1** — `pmpzicbo_cbo_wr_01` fail (tohost=3) | — |

**IPC verdict:** +4–7 % boot-cycle cost vs the −11 % CP (+12.4 % frequency) = **net ~+6–8 % faster** — a
GOOD trade (not net-negative like shape-W). litmus N4 passing (no forbidden) is the key R3 SMP-safety proof:
taking the plain-store live TLB off the retire gate does NOT break RVWMO under 4-hart stress.

**The blocker — one ACT4 test:** `test_act_pmpzicbo_pmpzicbo_cbo_wr_01` (a cbo.m write to a PMP-protected
region) fails at =1, **reproduced with `RETIRE_DECOUPLE=1` ALONE** (FETCH_REG=STORE_PRETRANSLATE=VALU_PIPE=0).
So it is the R3-L2 cbo.m fault decouple: `cbo_m_acc_fault` (`:5941`) reads `if RETIRE_DECOUPLE ?
(store_fetched_q ? (m_cbom_pmp_r_q && m_cbom_pmp_w_q) : 0) : (cbo_m_pmp_deny_r && cbo_m_pmp_deny_w)`, and
the registered arm (`m_cbom_pmp_*_q` captured unconditionally every cycle at `:7686`) mis-delivers the
R-AND-W PMP deny for this cbo.m at its commit cycle — the cbo write to a PMP-denied region does not trap.
The DEAD scaffold was verified byte-id at =0 (ACT4 696/0) but the =1 cbo.m PMP path is NOT in the fast gate,
so this latent bug survived. **This is a real R3 correctness bug that gates the commit; the fix is a focused
debug of the cbo.m fault-decouple timing ($display the store_fetched_q / m_cbom_pmp_*_q / cbo_m_pmp_deny_*
alignment at the cbo.m commit cycle).** MEM_PIPE=1 default; reproduce with
`veryl test --ignored --test test_act_pmpzicbo_pmpzicbo_cbo_wr_01` at RETIRE_DECOUPLE=1. Tree reverted clean
(`00b4818`, all scaffolds =0); the boot/litmus/IPC results above prove the other three scaffolds + R3's
plain-store/atomic paths are correct — only the cbo.m PMP-write fault-decouple corner remains.

## 12. ✅ FIXED + BANKED (2026-07-16) — the cbo.m fault-decouple bug root-caused ($display) and fixed; ACT4 696/0, bundle committable

`$display` at the cbo.m commit (RETIRE_DECOUPLE=1) pinned it immediately:
```
CBOM pc=80002188 vm=0 priv=11 sfq=0 ack=1 | reg r=0 w=0 | live r=1 w=1 | fault=0 | caddr=80009000 cboaddr=80009000
```
A **BARE (M-mode, `vm=0`) cbo.m retires in ONE cycle (`ack=1`) with `store_fetched_q=0`** — it never rides
the M3a 2-cycle handshake (that is a VM-walk thing). So `cbo_m_acc_fault`'s =1 arm `store_fetched_q ? reg :
0` returned 0, dropping the (correct, `live r=1 w=1`) R-AND-W PMP deny; the registered `m_cbom_pmp_*_q` held
the PREVIOUS op's deny (`reg r=0 w=0`, stale). §7.5's "cbo.m rides M3a store_fetched_q" holds only for the
VM case.

**Fix (`:5941`):** branch the =1 arm on `dmem_vm_on_op`. A bare cbo.m has `cbo_m_addr = c_store_addr`
(ROB-registered, NOT the live TLB), so its live PMP deny is CP-neutral on `rob_commit_ack` and is the ONLY
correct source when `store_fetched_q` never fires — use it. A VM cbo.m (`cbo_m_addr = dmu_dmem_addr`, live
TLB) keeps the walk-cycle-registered `m_cbom_pmp_*_q` (gated by `store_fetched_q`), so the TLB stays off the
retire gate. Byte-identical at `RETIRE_DECOUPLE=0` (the =0 arm is unchanged live deny).

**Verified (4-scaffold bundle FETCH_REG + STORE_PRETRANSLATE + RETIRE_DECOUPLE + VALU_PIPE = 1, DECODE_REG =
0):** `pmpzicbo_cbo_wr_01` now `tohost=1 pass=1`; **ACT4 696/0**; full boot/litmus ladder + IPC as §11. The
−11 % bundle (14.745 → 13.120) is now fully green and committable. `DECODE_REG` stays a built-but-dead
scaffold. This completes the "bank the bundle" goal.
