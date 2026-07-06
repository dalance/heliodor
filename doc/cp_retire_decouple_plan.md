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
