# R1 — store queue / decoupled retire (design plan, 2026-07-17)

The re-plan (`deep_pipeline_status_and_replan.md` §8.1, RE-AFFIRMED 2026-07-17) named **R1
(decoupled-retire + store queue)** the **sole remaining structural front**: after banking the
−11 % bundle (`c2a98fe`: FETCH_REG + STORE_PRETRANSLATE + RETIRE_DECOUPLE + VALU_PIPE live) and
exhausting every maskable front-end / SRAM scaffold, the binding wall is the **atomic-commit live
TLB → `sb_merge_ok` → `rob_commit_ack` → `n_inflight`** retire megacone (13.800 ns fresh synth).
The near-term ~12 ns / 6–7-stage target hinges entirely on R1.

This doc is the design phase — resolve the hard questions **before** RTL, the campaign's proven
methodology (`cp_dcache_sync_read_plan.md` §10/§11, `cp_retire_decouple_plan.md` §1–§5).
Companion: `cp_retire_decouple_plan.md` (§8 = the atomic-decouple refutation this builds past),
`retire_memory_ordering_redesign_study.md` §3/§4 (the fused-vs-decoupled map + R1/R2/R3 framing),
`cp_direction_c_port_separation_plan.md` §8 (the ~12.4 ns memory floor R1 lands on).

---

## 1. The precise residual wall (post-bundle, `cp_retire_decouple_plan.md` §7.7/§8)

The banked bundle already took MOST of the live TLB off the retire gate:

| retire-path live-TLB consumer (for a VM store/atomic) | status | how |
|---|---|---|
| plain-store **PA** → `sb_pa` | registered | STORE_PRETRANSLATE (`c_pretx_fast`/`sb_2cyc_ok` → `c_store_pa`/`m_pa_q`) |
| plain/cbo.m/slow **fault** → `commit_trap` | registered | RETIRE_DECOUPLE S0/L2 (`m_spage_q`…/`m_cbom_pmp_*_q`) |
| atomic commit **WRITE PA** → dcache | registered | MEM_PIPE `ac_pa_q` (`:7280`) |
| atomic commit **PMP** → `amo_commit_acc_fault` | registered | RETIRE_DECOUPLE L3 (`u_pmp_amo_commit` off `ac_pa_q`, `:5892`) |
| atomic page/access **fault** → `sfault_*_eff` | 0 (deferred) | RETIRE_DECOUPLE S0 (atomic `store_fetched_q=0`) |
| **atomic `sb_pa` (= `c_store_eff_pa`)** → `sb_match_v`/`sb_merge_ok` → `rob_commit_ack` | ❌ **STILL LIVE** | `c_store_eff_pa`'s `dmem_vm_on_op ? dmu_dmem_addr` arm (`:5873`) |

This table (built from §8's stale map) shows `sb_pa` as **a** residual live-TLB arm: for a VM atomic,
`c_pretx_fast=0` and `sb_2cyc_ok=0` (both exclude atomics), so `c_store_eff_pa` falls to
`dmem_vm_on_op ? dmu_dmem_addr` = the LIVE TLB, feeding `sb_pa[63:6] → sb_match_v → sb_merge_ok →
rob_commit_ack` (term `:3891`) and `c_store_mmio → rob_commit_ack` (term `:3890`). **But the fresh
2026-07-17 synth (§2.2) shows `sb_pa` is NOT the binding requester — the cbo.m PMP is.** The retire
wall is a shared-live-TLB cone with SEVERAL commit requesters; `sb_pa` is one brick of the cut, not
the whole wall. The §8 cone (for the sb_pa arm) was:

```
c_is_cas_q → commit_store_fire → store_drive → core_dmem_vaddr(=c_store_addr) → u_dmem_mmu.tlb_*
   → dmu_dmem_addr → c_store_eff_pa → sb_pa → sb_merge_ok → rob_commit_ack → n_inflight  (13.8 ns)
```

**It is a FALSE PATH.** `rob_commit_ack`'s merge term is `c_is_store && sb_elig && sb_full &&
!sb_merge_ok`, and `sb_elig = (fast_store || sb_vm_ok) && …` with `sb_vm_ok` requiring `!c_is_amo`
(`sb_vm_live_ok`, `:6447`). An atomic is never `sb_elig` → never merges → the term is masked. But
STA cannot correlate the `c_is_cas_q` START with the `sb_elig=0` mask END, so it reports the live
TLB as the CP.

## 2. Why §8's atomic-PA decouple was REFUTED — and how R1 differs

`cp_retire_decouple_plan.md` §8 tried to cut this by gating `c_store_eff_pa`:
```
if ATOMIC_PA_DECOUPLE && c_is_amo ? ac_pa_q : <the original live mux incl. dmu_dmem_addr>
```
→ **13.270 ns, +0.15 WORSE.** Root cause = the §13 rule: `c_is_amo` is a RUNTIME signal, so the
`<live mux>` false arm (reachable via the `!c_is_amo` plain-store-miss path) keeps `dmu_dmem_addr`
logically alive; STA cannot prune it and the extra mux ADDS a level. §8 concluded correctly: the
cut needs a **CONST / physical separation** of the atomic commit path from the shared MMU/`sb_merge`
net — **not a runtime gate** — but did not build it.

**R1's first piece IS that const separation.** Instead of muxing AROUND the live arm, it **DELETES**
`dmu_dmem_addr` from `c_store_eff_pa` entirely (const-gated) and replaces it with two FLOPS:

```veryl
const SB_PA_REG: bit = 0;
let c_store_eff_pa = if c_pretx_fast ? c_store_pa : if sb_2cyc_ok ? m_pa_q
    : if dmem_vm_on_op ? (if SB_PA_REG ? (if c_is_amo ? ac_pa_q : m_pa_q) : dmu_dmem_addr) : c_store_addr;
```

At `SB_PA_REG=1` the `dmem_vm_on_op` arm is `if c_is_amo ? ac_pa_q : m_pa_q` — **both registered**,
`dmu_dmem_addr` appears NOWHERE → the live TLB → `c_store_eff_pa` arc DCEs. The `if c_is_amo` here
selects between two flops (unlike §8's flop-vs-live mux), so STA has no live arm to keep.

### 2.1 Correctness — every store reaching the deleted live arm

The live arm is reached only when `!c_pretx_fast && !sb_2cyc_ok && dmem_vm_on_op`. Enumerate:

- **(a) VM atomic (AMO/SC/LR).** `c_is_amo=1` → `ac_pa_q` (the atomic's read-time translated PA,
  held issue→commit at the serialized head; `= dmu_dmem_addr` for a correct atomic). `sb_pa` is
  **fully don't-care** for an atomic anyway: `sb_elig=0` ⇒ never pushes, `sb_merge_ok` masked in
  the retire gate. (For an LR `ac_pa_q` is stale, but an LR is `!c_is_store` ⇒ term 3890/3891
  masked — same harmlessness as `u_pmp_amo_commit`'s LR note, `:5886`.)
- **(b) VM slow store at its M3a TRANSLATE cycle** (`store_fetched_q=0`). Held by `rob_commit_ack`
  term `:3889` (`MEM_PIPE && c_is_store && !sb_elig && !c_is_amo && !store_fetched_q`) or `:3884`
  (`dmem_mmu_busy`) → not retiring. `sb_elig=0` ⇒ no push. `sb_pa`/`c_store_mmio` don't-care
  (masked by the same-cycle held gate). Substituting the stale `m_pa_q` cannot release retire.
- **(c) VM MMIO / uncached / misaligned slow store at its RETIRE cycle** (`store_fetched_q=1`, but
  `sb_2cyc_ok=0` because it is not aligned-cacheable-DRAM). `c_is_amo=0` → `m_pa_q`. It rode the
  M3a handshake (`store_fetched_q` set at translate), so `m_pa_q` (`= dmu_dmem_addr` captured at
  the translate cycle, `:7700`) IS this store's own PA. Its one live consumer, `c_store_mmio` (term
  `:3890`), reads the CORRECT registered PA → identical behaviour.

**So `SB_PA_REG=1` is functionally equivalent, not merely byte-identical-at-0**: eligible stores use
the untouched `c_pretx_fast`/`sb_2cyc_ok` arms; every store on the deleted live arm is either
don't-care (masked/held) or reads a correct flop. The live TLB just leaves the STA cone.

### 2.2 ✅ MEASURED (2026-07-17) — `sb_pa` is NOT the binding requester; the current wall is the cbo.m PMP false path. TWO cuts (sb_pa + cbo.m) move it 13.800 → 12.965

Fresh `synth --top heliodor_core --dump-timing` on the current tree corrects §8's stale map (which
predates the veryl/cell-model update, 13.71→13.800):

| config (throwaway synth) | headline | binding cone |
|---|---|---|
| baseline (SB_PA_REG=0) | **13.800** | `head → CAS operand → commit_store_fire → agu → LIVE TLB → **u_pmp_cbo_m_w** (cbo.m WRITE PMP) → cbo_m_pmp_deny → commit_trap → rob_commit_ack → n_inflight` |
| SB_PA_REG=1 (sb_pa cut) alone | **13.800** | SAME — `sb_pa`/`sb_merge_ok` are ABSENT from the baseline cone; cutting sb_pa moves nothing |
| SB_PA_REG=1 + cbo.m PMP bare-arm cut | **12.965** (`pc_q → u_imem_mmu → n_inflight`) | the dmem-side commit live-TLB cone is GONE; a NEW front (instruction-side MMU) binds |

**Correction to §1/§8.** `sb_pa` is NOT the last (nor the binding) live-TLB consumer in the current
tree. The binding one is the **cbo.m PMP** (`u_pmp_cbo_m_r/w`): a committing VM **atomic** drives the
shared dmem MMU (`commit_store_fire → agu → live TLB`), whose output fans out to the cbo.m PMP
checker (`cbo_m_addr`'s VM arm = `dmu_dmem_addr`), and `cbo_m_acc_fault`'s **bare** arm reads that
LIVE deny (`:5985`) — a shared-live-TLB FALSE PATH (masked by `c_is_cbo_m`, runtime-unprunable). This
is the SAME §13 shared-MMU false-path pattern as sb_pa, on a DIFFERENT requester. So the commit
retire wall is a **shared-live-TLB cone with MULTIPLE requesters** (sb_pa, cbo.m PMP, and whatever
sits behind them); the CP moves only when ALL co-binding requesters are cut. **Two const-separation
bricks (sb_pa + cbo.m-bare, both under `SB_PA_REG`) drop it 13.800 → 12.965 ns (−6 %)**, exposing the
instruction-side MMU (`u_imem_mmu`) as the next front — validating the R1 program: chaining
const-separations off the shared commit MMU DOES move the CP toward the ~12.4 memory floor.

---

## 3. R1 scope — this piece vs. the full store queue

`SB_PA_REG` is the **CP-moving core** of R1: it takes the last live TLB off `rob_commit_ack`, the
structural goal. It is NOT yet the full "store queue" of the study §4 (which additionally decouples
SB **allocation** from retire for IPC — dropping the `sb_full && !sb_merge_ok` stall). The staging:

- **R1a — `SB_PA_REG` (this doc, 2 bricks).** Take the SHARED commit live-TLB off `rob_commit_ack`
  by const-separating each requester that reads it: **(i) `sb_pa`** (`c_store_eff_pa` live arm →
  `if c_is_amo ? ac_pa_q : m_pa_q`) and **(ii) the cbo.m PMP** (`cbo_m_acc_fault`'s bare arm → the
  dedicated `u_pmp_cbo_m_bare_r/w` on `c_store_addr`, not the shared TLB-muxed checker). Both are
  low-risk (functionally equivalent / byte-identical, §2.1) and together move the CP **13.800 →
  12.965 (§2.2)**. The next requester behind them is the instruction-side MMU (`u_imem_mmu`, a
  DIFFERENT cone). Full-SMP-ladder-gated flip. (If more dmem-commit requesters re-appear at the
  12.965 front on a fuller trace, they extend the same `SB_PA_REG` brick set.)
- **R1b — allocation decouple (IPC).** If `SB_PA_REG=1` moves the CP, the residual `sb_merge_ok`
  merge-match scan (now on registered PAs, shallow) can be lifted off the retire gate structurally
  (retire on a registered `sb_full` count; keep a registered merge verdict or bump `SB_N`). Measure
  the IPC of the dropped merge-when-full (study §4 Q2). Optional / follow-on.
- **R2 — universal execute-time translate.** Generalise so EVERY store's PA is registered at execute
  into the SQ entry (covers the plain-store MISS case that STORE_PRETRANSLATE's hit-only probe skips)
  — makes `SB_PA_REG` unconditional rather than relying on the M3a `m_pa_q`. Follow-on.
- **R3 — atomic reorder through SQ + coherence.** The M3b minefield; deferred. `SB_PA_REG` does NOT
  touch the atomic RMW write timing (still `ac_pa_q`, single-cycle live) — it only registers the
  atomic's `sb_pa`, which the atomic never functionally uses. So R1a is M3b-SAFE.

## 4. DEAD-scaffold strategy + verification ladder

`const SB_PA_REG: bit = 0`. At `=0` const-folds to the exact `dmu_dmem_addr` mux → byte-identical.

- **DEAD (=0):** default `veryl test` 252/0 + litmus N2 cy-exact + synth CP/FF/levels/endpoint
  unchanged. (This turn.)
- **Throwaway `=1` synth:** measure whether the 13.8 `n_inflight` wall drops (§2.2). Go/no-go.
- **FUNCTIONAL `=1` flip (gated):** the FULL SMP ladder — litmus N2/N4 + N2/N4 SMP boot + Verilator
  (NBA — the M3b/retire corners surface only on multi-hart NBA) + ACT4 (paging/PMP/cbo suites) +
  the IPC budget. `sb_pa` is the memory-ordering heart; the flip lands only after the whole ladder
  is green.

**▶️ This turn:** build `SB_PA_REG` DEAD, verify byte-identical (fast gate), then the throwaway `=1`
synth to answer §2.2 (does R1a move the CP?). That measurement decides whether R1 continues to R1b/
R2 or whether the wall needs the deeper (R3) work.

---

## 5. ✅ FLIP verification (2026-07-17) — FULL LADDER GREEN, `SB_PA_REG=1` SHIPPED (−6 % CP); one SMP-boot wedge FOUND + FIXED (c_store_mmio exec/retire split)

Ran the full-SMP-ladder gate on the `SB_PA_REG=1` flip (commits `f239d2f` scaffold + `e9a052b`
fix). Result: the CP win is real and the flip is SMP-safe, after fixing one latent wedge. **Every
gate re-verified WITH the fix on the current tree — all green — so the flip is committed.**

| gate | result |
|---|---|
| fast (`veryl test`, 252 + litmus N2) | ✅ **252/0**, litmus N2 cy=00236680 (cycle-EXACT vs =0 → functionally equivalent) |
| ACT4 696 (paging/PMP/cbo/atomic) | ✅ **696/0** (re-verified WITH the fix; cbo_wr_01 = the §11 precedent, PASS via the dedicated bare checker) |
| litmus N4 (RVWMO) | ✅ **pass=1, NO forbidden**, cy=00537730 (re-verified WITH the fix) — R1 SMP-ordering proof: the commit live-TLB off the retire gate does NOT break RVWMO at 4-hart |
| synth CP | ✅ **12.965 ns (−6 %)** (`pc_q[34] → n_inflight[5]`, 137 levels) — with the fix, UNCHANGED (CP-neutral); the new front is the instruction-side MMU, exactly as §2.2 predicted |
| **SMP boot N2** | ✅ **PASS with the fix** (probe matches =0 baseline cycle-for-cycle); **WEDGED without it** |
| **SMP boot N4** | ✅ **PASS, r3=0xAA, cy=0x1647200** (~23.36 M; two independent runs byte-identical → deterministic) |
| **Verilator N1** (NBA) | ✅ **PASSED**, SBI shutdown / x3==0xAA, cy=13052883 |
| **Verilator N2** (NBA, multi-hart) | ✅ **PASSED**, SBI shutdown / x3==0xAA, cy=17776159 — the retire-gate change is NBA-correct at 2-hart (the wedge's home turf) |

### 5.1 The wedge + fix — c_store_mmio is BOTH a retire gate AND a dcache-write input

Pre-fix, the `SB_PA_REG=1` flip WEDGED the 2-hart SMP boot: hart1 stuck in firmware (PC ~0x510,
`trap1=0`, never woken) — the **S20R MMIO-doorbell** signature (`:3872`). The =0 baseline boots clean
(hart1 in the kernel, `trap1>0`), so the wedge is a real =1 bug. Root cause: `c_store_mmio`
(`:6511`) is computed from the now-registered `c_store_eff_pa`, so at =1 it is **STALE during a slow
store's translate cycle**. It feeds not only the term-3890 retire gate (where registered is correct
*at the retire cycle* + off the live TLB = the CP win) but ALSO the **dcache write enables
`dc_i_wen`/`dc_wen_excl`** (`:7114`/`:7125`), which are sampled at the **translate cycle N** (latched
into `m_wen_q` for the N+1 write). A stale-DRAM MMIO classification there routes a VM MMIO store to
the wrong drain-order path → it leaks past older buffered stores → the CLINT doorbell passes its
mailbox → the woken hart parks. **Lesson: `c_store_mmio` has an exec role (dcache-write, needs the
LIVE translate-cycle PA) and a retire role (term 3890, wants the registered PA for CP) — the two must
be split, they are not the same PA.**

**Fix (`e9a052b`):** `c_store_mmio_x` classifies from the LIVE translate-cycle PA (`c_store_pa_x =
dmem_vm_on_op ? dmu_dmem_addr : c_store_addr`) and feeds `dc_i_wen`/`dc_wen_excl`; term 3890 keeps the
registered `c_store_mmio` (CP). The exec classifier reaches `rob_commit_ack` only through the
multi-cycle dcache state/stall (not combinationally), so it is **CP-neutral** (synth stays 12.965 ns,
verified). At =0 `c_store_mmio_x ≡ c_store_mmio` → byte-identical.

### 5.2 ✅ SHIPPED — `SB_PA_REG=1` committed (the full ladder is green)

All the gates §5.2 previously listed as remaining are now green **with the fix** on the current tree:
(a) ACT4 696/0 + litmus N4 pass=1/no-forbidden re-verified WITH the fix; (b) SMP boot N4 PASS
(r3=0xAA, cy=0x1647200, two runs byte-identical); (c) Verilator N1 + N2 PASSED (NBA-correct, SBI
shutdown / x3==0xAA). synth re-confirmed **12.965 ns** on the committed flip. So `const SB_PA_REG:
bit = 1` is committed — the last shared commit live-TLB requester (sb_pa + cbo.m PMP) is off
`rob_commit_ack`, CP **13.800 → 12.965 (−6 %)** with IPC neutral (SMP-N2 boot is cycle-for-cycle
identical to =0, so the flip is functionally equivalent, not merely byte-identical-at-0). The flip is
independent of the banked bundle (`DECODE_REG` stays 0). Revert path if a regression later surfaces:
`SB_PA_REG=0` restores the DEAD byte-identical scaffold.

The reported worst path after the flip is `pc_q[34] → … → n_inflight[5]` (137 levels, 12.965 ns) —
BUT §6 proves this is a **FALSE PATH**. The **real** post-flip CP floor is **~12.51 ns** (the FP /
vector execution datapaths). See §6.

---

## 6. ⚠️ Post-flip CP characterization (2026-07-17) — the 12.965 headline is a FALSE PATH; the REAL scalar-core CP floor is ~12.51 ns (FP / vector datapaths)

After the flip, `synth --timing-paths 30` shows a **tight cluster** at the top, NOT a single wall:

| # | delay | levels | endpoint | verdict |
|---|---|---|---|---|
| #1–5 | 12.675–**12.965** | 132–137 | `pc_q[34] → n_inflight[1..5]` | **FALSE PATH** (proven below) |
| #6–7 | 12.510 | 143 | `fr_d1_q[10] → fr_d_sum_q[51/52]` | **REAL** — FP double datapath (align/add/normalize/round) |
| #8–30 | 12.490 | 111 | `head[0] → vrf[*]` | vector RF writeback (real-or-false TBD) |

**The #1–5 `pc_q → n_inflight` family is a FALSE PATH — proven by a throwaway synth.** The full trace
is: `pc_q` → imem MMU Sv39 translate (~5.4 ns) → icache tag RAM read → **icache MISS** → the shared
dmem read-port arbiter `ic_route = ic_owns || (is_req && !dc_mem_req)` (`:8029`) → `i_dmem_grant` →
`u_dcache.load_sel` → dcache `i_wen`/`state` → `c_is_store` → `rob_commit_ack` → `commit_csrw_satp`
**and** `commit_trap` → free-list `do_push2` → `n_inflight`. It stitches the **store-commit front half**
(a committing store waiting on the dcache port) with the **CSR-write / trap back half** — but a single
committing instruction cannot be a store AND a satp-write AND a trap. STA over-approximates by fanning
through control-signal cones that are not co-sensitizable. Throwaway test: replace `ic_route` with
`ic_owns` (drop the `is_req` term = cut the icache-miss→port→dcache prefix), re-synth →
**CP 12.965 → 12.510 ns and the entire `pc_q → n_inflight` family DISAPPEARS from the top-30** (new #1
= the FP path). Reverted. Corroborating signal: the top-30 has **NO commit-register-rooted
`n_inflight` path** — only `pc_q`-rooted ones — so the real store-commit→`n_inflight` path is
sub-12.49; the fetch prefix alone inflates it to 12.9.

### 6.1 Implications — the scalar retire/commit/fetch fronts are EXHAUSTED for *real* CP

1. **fetch-decouple would be net-negative.** Registering the imem MMU / icache only removes this false
   path; the real CP (12.51, FP/vector) does not move. This is exactly the §21 shape-W net-negative
   trap — now *confirmed* for the fetch front. Do NOT pursue fetch-decouple for CP.
2. **The n_inflight endpoint has masqueraded as the headline across many campaign states** (13.800,
   13.120, 14.130 all reported `→ n_inflight`). Strong inference (not yet re-measured per state): those
   headlines were also fetch/commit false stitches to the same endpoint, and the real scalar-core CP
   floor has been ~12.5 for a while — the retire/store-queue scaffolding (R1a here, R3 before) moved
   the FALSE-path *prefix* (dmem-side 13.800 → imem-side 12.965), not the real CP. R1a's STRUCTURAL win
   (the live TLB off the retire gate = the memory-ordering heart) is real and independently valuable;
   its 12.965 *number* was false-path-inflated.
3. **The real CP floor is the FP / vector execution datapath.** `fr_d1_q → fr_d_sum_q` (143 levels) is
   genuine deep FP double arithmetic; `head → vrf` (111 levels) is the vector-commit RF writeback (still
   to be confirmed real vs. false). To move the REAL CP below ~12.5 the lever must pipeline the FPU /
   vector datapath — a different, harder class of work than scalar retire scaffolding.

### 6.2 The honest fork (revise-the-plan moment, per the optimize-for-structure principle)

- **(A) FP / vector datapath pipelining** — attack the real 12.51 floor. First confirm `head → vrf`
  real-vs-false (cheap throwaway, same method as §6), then pipeline `fr_d_sum_q` (FP add/FMA) and/or the
  vector writeback. Hard, but the only lever that moves the *real* CP.
- **(B) Structurally break the fetch↔commit false stitch** — register the shared-port arbitration
  (`ic_route` / the dmem grant) so fetch-miss and commit-store are not combinationally coupled. Cleans
  up the CP metric to show the real 12.51 AND is a genuine decouple; measure the IPC cost of the +1
  arbitration latency. Does not lower the real CP but removes the misleading headline.
- **(C) R1b / R2 store-queue continuation** — CP-neutral on the real floor, but real store-queue
  structure / IPC progress (drop the `sb_full && !sb_merge_ok` retire stall). Consistent with
  optimize-for-structure even though it will not move the 12.51 synth number.
- **(D) Accept ~12.5 as the reached scalar floor and revise the §6.1/§8.1 target** — the near-term
  ~12 ns goal is essentially met on the *real* floor (12.51 ≈ 12); the 7.5 ns aspiration was always
  contingent on FPU/vector + memory-floor + R3 SMP work (a different program).

---

# ▶️ Part II — the STRUCTURAL half (Block L1, design phase, 2026-08-19)

Part I above is the **CP** half of L1 and it shipped (`SB_PA_REG=1`, −6 % CP). The user chose L1 as
the next block on **structural** grounds (`phase14_frontend_deep_ooo_plan.md`, "▶️ Block L1"): the
canonical LSQ's fourth piece — the store queue itself — was never built. This part is the design the
plan doc says still needs writing. It resolves the five hard questions **before** RTL, per the
campaign's proven order.

## 7. The audit — what the store path actually is today

A store passes through **three** structures, and only the middle one is age-ordered per store:

| stage | structure | key | age | lifetime |
|---|---|---|---|---|
| dispatch → commit | **ROB shadow** `sh_store_{addr,data,funct3,pa,pa_valid}` (`rob.veryl:479`) | **VA** (`FWD_PA=0`) | ROB index | allocated at dispatch, written at execute (CDB), **dies at commit** (`sh_valid` clears) |
| commit → drain-ack | **committed SB** `sb_{line,data,strb,lmap}`, 4 × 64 B write-combining | **PA** | FIFO (in-order, index 0 = head) | pushed at `sb_push`, **popped on `dc_sdrain_ack`** |
| drain-ack → ∞ | the dcache array | PA | — | the merge lands at the ack's clock edge |

Forwarding is the OR of the first two: `sf*` (ROB scan, VA-keyed, aged by `stld_fwd_age`) and `sbf*`
(SB scan, PA-keyed, youngest-index-wins), both evaluated at **Stage B** against `lsr_vaddr_q` /
`lsr_paddr_q`, plus a same-cycle `sb_push` fold.

⚠️ **The age split is sound; only the KEY is not.** Commit is in-order, so every committed store is
older than every in-flight load — the SB needs no age compare, and youngest-index-wins is exact. What
the two halves genuinely disagree about is *what an address is* (M1c). So "one age-ordered CAM" is a
**key** unification, not an age unification. (`FWD_PA=1` measured worth exactly zero *given the
current split*; it is a structural cleanup, not an IPC lever. Do not re-price it as one.)

## 8. 🎯 The reframing that changes the plan: `store_drive` is a TRANSLATE hold, not a drain-port hold

The plan doc prices `store_drive` at **641,637 cy = 4.87 %** of the N=1 boot and describes it as "a
committing store holding the shared dcache port". The audit sharpens that, and the sharpening moves
the fix:

- **The SQ already has a private drain port.** The SB drains through the dcache's SECOND write port
  (`i_saddr`/`i_swen`/`o_sdrain_ack`, `dcache.veryl:126`), which is disjoint from the load read port.
  Question 5's "can the SQ drain without ever taking the load port?" is **already answered YES**, and
  has been since Phase 8 S6. The drain is not what costs 641,637 cycles.
- **What costs them is the commit-time TRANSLATE.** `store_drive` pins `core_dmem_vaddr` /
  `core_dmem_wen` to the committing store, i.e. it takes the **shared dmem MMU request port** — and
  three separate consumers yield to it: `load_blocks_on_store` (Stage-A capture), `lsr_drive`
  (Stage-B read), `replay_drive`. A load cannot even *translate* while a store commits.
- **And under VM it fires for EVERY store, including ones that need nothing.** `fast_store` — the
  bare-mode store that S6 already excludes from `store_drive` — requires `!dmem_vm_on`. Once Linux
  turns paging on, `fast_store ≡ 0`, so every kernel store re-drives the MMU at commit **even when
  its PA was already produced at execute** by the `STORE_PRETRANSLATE` probe.

**Enumerate what a pre-translated store (`c_pretx_fast`) still reads off that live port:**

| commit-time need | where it comes from at `STORE_PRETRANSLATE=1` |
|---|---|
| its PA | `c_store_eff_pa` takes the `c_pretx_fast` arm = `c_store_pa`, a ROB **flop** |
| SB-push eligibility | `sb_vm_ok = c_pretx_fast` — a **registered** classifier |
| MMIO classification | `c_store_mmio` from the registered `c_store_eff_pa` |
| page / access fault | `RETIRE_DECOUPLE` ⇒ `sfault_*_eff = store_fetched_q ? m_*_q : 0`, and a pretx store retires in ONE cycle **without ever setting `store_fetched_q`** ⇒ already 0 |
| A/D write-back | none — `dmem_sprobe_ok` required W **and D** already set |
| the dcache write | none — `sb_elig` suppresses the write-through (`dc_i_wen`'s `!sb_vm_live_ok`), it drains via `i_saddr` |

**NOTHING.** The port hold is pure fusion. This is the same structure S6 already dissolved for bare
mode, left un-generalised to VM only because `c_pretx_fast` postdates it.

⇒ **L1.a is the first build**, and it attacks the whole 641,637-cy bucket rather than the 0.23 %
guard: exclude a pre-translated store from `store_drive`.

⚠️ **The predicate must be loop-free, and `c_pretx_fast` is not.** `c_pretx_fast` reads
`dmem_vm_on_op = dmem_vm_on || dmem_op_hlv`, and `dmem_op_hlv` reads `store_drive` (`:9360`) — the
exact edge `fast_store`'s "use `c_is_mem_virt`, NOT `dmem_vm_on_op`" comment exists to avoid. The
scaffold therefore rebuilds the predicate from the CSR-derived `dmem_vm_on` (registers) and excludes
HSV outright, which **implies** `c_pretx_fast` (`dmem_vm_on ⇒ dmem_vm_on_op`) without closing the
loop. Every other term is `c_pretx_fast`'s own, verbatim.

**Second-order gain:** `store_pretx_valid` itself carries `&& !store_drive` (`:9012`) — the probe
cannot fire while a store owns the port. So freeing the port also raises the probe's hit rate, which
raises the `c_pretx_fast` population, which frees more ports. L1.a is self-reinforcing; expect the
flip to move more than a static census of today's `c_pretx_fast` rate would predict.

**What L1.a does NOT cover:** the `sb_2cyc_ok` population — stores that MISSED the execute-time probe
and translate live at commit cycle N, pushing the registered `m_pa_q` at N+1. Those genuinely need
the port. Closing them is L1.b.

## 9. 🎯 The visibility hole, located exactly: a snapshot SKEW, not just an early pop

Block T proved the hole exists and papered it with `LSR_B2B_SBQ`. The audit names the mechanism, and
it is narrower and more fixable than "pop-on-ack is too early":

```
cycle N            cycle N+1
─────────────────  ─────────────────
Stage A: i_ren_r / i_addr_r presented (lsr_capture)
         DCACHE_SYNC_READ reads the array COMBINATIONALLY and REGISTERS it
drain:   store_can_drain=1 → o_sdrain_ack=1     ← the merge is applied AT THIS EDGE
sb:      entry still counted in sb_cnt          sb_pop → sb_cnt drops
                                    Stage B: the sbf* forward net is evaluated (lsr_v_q)
                                             …against a buffer that no longer holds the entry
```

The **data read** snapshots the array at the end of cycle N (pre-merge). The **forward net**
snapshots the buffer at cycle N+1 (post-pop). A store drained at that edge is in **neither**. It is
not that the entry is freed before its write lands — the write lands at the same edge. It is that the
load's two halves sample **different cycles**, and the entry's lifetime covers neither of them fully.

⇒ **The visibility contract (question 2) is: an SQ entry must stay in the forward net until every
read that could have SNAPSHOTTED the array before its write has completed.** With a 2-stage load that
is exactly **one cycle past the drain ack** — a one-entry *drain shadow* holding the popped entry's
{line PA, 8 lanes, strobes}, ORed into `sbf*`, cleared the following cycle. `LSR_B2B_SBQ` then has
nothing left to protect and can be deleted rather than sharpened.

⚠️ **Re-open the "wider than the head line" finding before trusting it.** Block T recorded that
restricting the b2b suppression to the COLLIDING LINE was insufficient (the oops returned 8,590
cycles later) and concluded the window is wider than the head entry's line. If the hole is exactly
the merge-cycle skew above, a *correct* line compare should have sufficed — so the more likely
reading is that the compare was made against the wrong address (the incumbent's `lsr_paddr_q` rather
than the capturing load's `dmu_dmem_addr`, which is what Stage A actually presents). **Check which
address that test compared before designing around a wide window.** A shadow entry sidesteps the
question entirely — it is address-exact by construction — which is another reason to prefer it over
sharpening the guard.

**Open, and NOT covered by the shadow:** the `wt_fires` drain (`dcache.veryl:1350`). A full-line
drain that misses locally acks on its **bus write-channel grant** and never enters the local array;
"architecturally readable" for it means the bus write has been ordered ahead of any later fill of the
same line. That is a memory_bus/L2 ordering property, not an L1 lifetime property. Confirm it holds
before declaring the contract closed; if it does not, the shadow must persist until write completion,
not for a fixed cycle.

## 10. The five hard questions — resolved

**Q1. Allocation point → dispatch, ROB-indexed. Do not build a second free list.**
The ROB shadow already allocates at dispatch and is written at execute; age *is* the ROB index, free.
A separate SQ with its own pointers buys nothing but a second full-condition to stall dispatch on, and
W0 measured `resource` (ROB/free-list/IQ full) at only 6.9 % of 1-wide cycles even after Block W. The
"queue" L1 must build is not new storage before commit — it is a **lifetime extension after** it.

**Q2. Visibility contract → an entry is freed only when every possible reader's snapshot is after its
write.** Concretely: one cycle past `dc_sdrain_ack` for the local-merge path (§9), and past bus write
completion for `wt_fires` if §9's open item says so. Today's pop-on-ack is the bug; `LSR_B2B_SBQ` is
its workaround and is deleted, not sharpened, by the fix.

**Q3. Forwarding key and CAM shape → PA-unified, one net, ROB half retires into the same net.**
The age structure is already correct (§7), so this is a key change (`FWD_PA` + `load_queue.veryl`'s
S16 exemption, **flip-coupled** — flipping one alone is either gainless or unsound). Sequence it
LAST: it is measured worth zero IPC and it touches the disambiguation, the highest-risk net in the
tree. Ship it as structure, on the structure gate, after the two IPC pieces are banked.

**Q4. Relationship to the ASQ → keep two queues; do not fold atomics in.**
R3 shipped the ASQ with an explicit ordering contract already enforced at three points:
`asq_st_block = !asq_empty` (no store may drive while an atomic is queued), `asq_ld_ovl` (no younger
overlapping access may pass a queued atomic — it *cannot* forward, since its value does not exist
until the drain computes it), and `asq_dr_busy` (all load/AMO issue held while the drain engine runs).
An atomic's entry is fundamentally different from a store's — no forwardable data — so folding it into
a forwarding CAM would need a per-entry "cannot forward, must wait" bit, i.e. exactly the ASQ, inlined.
The `asq_dr_busy` (9,997 cy) and `asq_ld_ovl` (0 cy) buckets say the split costs nothing measurable.
**Fold nothing. Document the ordering contract as the answer.**

**Q5. The drain port → already private (§8). The question was mis-stated; the real one is the
TRANSLATE port,** and the answer is "every store's PA is registered before commit" (L1.a for the
probe-hit population, L1.b for the rest).

## 11. Build order — three DEAD scaffolds, each priced by its own flip

Each step is const-gated, verified byte-identical at 0, flipped, and priced by reading the cycle
counter — never by its census bucket (L4 step-2 recovered **zero** from a 7.14 % bucket; W1a
over-promised 40×).

- **L1.a — `STORE_NOPORT`** (`heliodor_core.veryl`, at `store_drive`). A pre-translated store does not
  take the shared dmem port. Small, self-contained, aimed at the 641,637-cy bucket, and it rides a
  shipped precedent (S6 for bare mode). ⚠️ It lets a load issue in the same cycle an older store
  commits — sound because the load's Stage-B forward net covers the SB entry, including the
  same-cycle `sb_push` fold — but it is a memory-ordering change and gates on the **full SMP ladder**.
- **L1.b — universal execute-time translate.** Give the `sb_2cyc_ok` population a registered PA too,
  so no store ever needs the commit port. The probe misses today for three reasons (execute-time TLB
  miss, port taken by another requester, `rob_has_pending_xlate`); the canonical fix is an **SQ
  translate retry** that re-probes a missed store from its ROB entry in idle port cycles, instead of
  at commit where it blocks. This is the piece that makes the store queue a real queue rather than a
  shadow. Depends on L1.a having freed the port for the retries to use.
- **L1.c — the visibility contract** (§9): the drain shadow, then **delete** `LSR_B2B_SBQ`. Its
  yardstick is already measured (0.23 pp at N=1, ~0.2 % at every width — the "cost grows with harts"
  prediction was made and REFUTED). Ship for correctness; the 0.2 % is a bonus.
- **L1.d — the unified PA-keyed forward net** (Q3), last, on the structure gate.

**Gate for every step:** default suite (252/0, incl. litmus N=2) → litmus N=4 → N=1 boot → N=2 SMP
boot → N=4 SMP boot → Verilator NBA cross-check. Retire and memory ordering is the highest-risk area
in the tree; Block T's own N=2 kernel oops surfaced only at 2 harts.

## 12. Facts recorded before the first flip

Baselines (shipped default, `LSR_B2B=1` + `LSR_B2B_SBQ=1` + `P1_SERVED=1`):
N=1 `cy=00c91c60` · N=2 `cy=01142f20` · N=4 `cy=01876350` · litmus N=2 `cy=002e3bf0` /
N=4 `cy=003b3440` · dhrystone 235,828 / instret 264,834 · coremark 394,551 / instret 374,357 ·
suite 252/0.

Census at that default, `DBG_CENSUS=1` (N=1 boot, 13,180,000 cy): `store` sole-blocker 701,128
(5.32 %), of which **`store_drive` 641,637 (4.87 %)**, `sb_cnt >= 3` 49,485, `asq_dr_busy` 9,997,
page-edge 9, `asq_ld_ovl` 0. `lsr` sole-blocker 758,020 (5.75 %), now 100 % dcache miss.
`LSR_B2B_SBQ` suppressed/fired 19,023 / 682,106.

---

## 13. 🏁🚢 SHIPPED (2026-08-19) — L1.a + L1.c are the DEFAULT PATH. **N=1 −6.15 % / N=2 −4.20 % / N=4 −3.39 %**, and `LSR_B2B_SBQ` is DELETED

`STORE_NOPORT=1` + `SB_DRAIN_SHADOW=1` + `LSR_B2B_SBQ=0` ship as the default path (`0f2fe0d`). Full Veryl ladder + Verilator NBA 4/4 green; revert path proven (§13.8). New baselines: **N=1 `cy=00bcc050`** · **N=2 `cy=01089660`** · **N=4 `cy=017a1ce0`** · dhrystone 235,804 · coremark 394,546 · litmus N=2 `cy=002e3bf0` / N=4 `cy=003b3440`.

Both scaffolds were built DEAD, verified, flipped, and priced by the cycle counter. Two of §11's
predictions held and **one ordering decision in §11 was WRONG and is corrected below.**

### 13.1 The ladder

| gate | baseline | L1.a + L1.c + `LSR_B2B_SBQ=0` | Δ |
|---|---|---|---|
| default suite | 252/0 | **252/0** | — |
| litmus N=2 | `cy=002e3bf0` | `cy=002e3bf0` | **identical** |
| litmus N=4 | `cy=003b3440` | `cy=003b3440` | **identical** |
| dhrystone | 235,828 / instret 264,834 | 235,804 / **instret 264,834** | −24 cy |
| coremark | 394,551 / instret 374,357 | 394,546 / **instret 374,357** | −5 cy |
| **N=1 boot** | 13,180,000 | **12,370,000** | **−6.15 %** |
| **N=2 SMP boot** | 18,100,000 | **17,340,000** | **−4.20 %** |

The bare-mode gates move by tens of cycles with **instret bit-identical** — `STORE_NOPORT` cannot
fire in bare mode (it requires `dmem_vm_on`; S6's `fast_store` already covers bare), so the residue
is `LSR_B2B_SBQ`'s deletion alone. That is a strong functional-equivalence signal, not a null result.

### 13.2 L1.a paid MORE than its census bucket — the self-reinforcement is real

`store_drive`'s sole-blocker bucket was 641,637 cy. The unrestricted flip removed **790,000**. §8
predicted exactly this: `store_pretx_valid` carries `&& !store_drive`, so freeing the port raises the
execute-time probe's own hit rate, which grows the `c_pretx_fast` population, which frees more ports.

⚠️ Worth recording as the campaign's **first over-delivery**. L3 over-promised 3-5×, L4 step-2
over-promised ∞ (7.14 % → 0), W1a over-promised 40×. A sole-blocker census still says WHERE and not
HOW MUCH — but the error is not signed. Do not start treating buckets as floors either.

### 13.3 🚨 ORDER CORRECTION: L1.c is a PREREQUISITE for L1.a, not a follow-on

§11 sequenced L1.a first and L1.c third. **That was wrong, and the machine said so.** L1.a alone:

| config | N=1 boot | N=2 SMP boot |
|---|---|---|
| `STORE_NOPORT=1` alone | 12,390,000 (−5.99 %) | ❌ **WEDGE** — hart1 never leaves firmware (`h1_pc=0x51a`, `trap1=0`), the S20R doorbell signature (§5.1) |
| `+ STORE_NOPORT_SBE=1` (restrict to `sb_empty`) | 12,980,000 (−1.52 %) | 17,550,000 (−3.04 %) ✅ |
| **`+ SB_DRAIN_SHADOW=1`** (the real fix, unrestricted) | 12,390,000 (−5.99 %) | **17,390,000 (−3.92 %)** ✅ |
| **`+ LSR_B2B_SBQ=0`** | **12,370,000 (−6.15 %)** | **17,340,000 (−4.20 %)** ✅ |

**Two hypotheses were live and the bisection killed one.** (i) the §9 snapshot skew, now reachable
through the ORDINARY capture path — `LSR_B2B_SBQ` only ever guarded the b2b one; (ii) **drain
starvation** — `store_drive` was an implicit drain priority (every committing store idled the load
stream for a cycle, handing the IDLE-only drain its slots), and S20.2 explicitly documents that
coupling, keeping only the `sb_cnt >= 3` watermark when the buffer took over. Both live in the
non-empty-SB window, so a one-run `&& sb_empty` restriction proved the hazard is SB-related; the
drain shadow then fixed it outright at full width, **refuting (ii)**.

🎯 **`feedback_removed_bubble_was_protection` fired for the second time in two blocks.** Block T
deleted the LSR turnaround bubble and found it was the only thing keeping loads out of the store-drain
window. L1.a deletes the commit-store port hold and finds it was the only thing keeping loads out of
the *same* window through a *different* door. **The general form: when a bubble protects a window,
removing ANY of the mechanisms that create it re-opens the window — so fix the window, not the door.**
That is what the shadow does, and it is why it was worth building the contract rather than another
capture gate.

### 13.4 `LSR_B2B_SBQ` is deleted, exactly as §10 Q2 predicted

With the shadow in place the guard is dead weight: dropping it gains **+0.16 pp at N=1** (12,390,000 →
12,370,000) and **+0.28 pp at N=2**, and every gate stays green. Block T's own yardstick for it was
0.23 pp at N=1 — consistent. The visibility contract is now a **contract**, not a workaround:
*an entry is not freed until every reader that could have snapshotted the array before its write has
completed.*

This also retires Block T's open question about the window's width. Block T measured a same-LINE
restriction insufficient and concluded the window is wider than the head entry's line; §9 flagged that
for re-checking. The shadow is address-exact by construction and needs no width estimate, so the
question is moot — but the §9 reading (that the earlier test compared the wrong address) remains the
likely explanation and should not be propagated as "the window is wide".

### 13.5 Revised build order

1. ✅ **L1.c `SB_DRAIN_SHADOW`** — the visibility contract. **First**, because L1.a is unsafe without it.
2. ✅ **L1.a `STORE_NOPORT`** — the pre-translated store does not take the shared dmem port.
3. ✅ **`LSR_B2B_SBQ` deleted** — subsumed by 1.
4. ▶️ **L1.b** — universal execute-time translate (the `sb_2cyc_ok` population; an SQ translate retry
   in idle port cycles). Now unblocked: L1.a freed the port those retries need.
5. **L1.d** — the unified PA-keyed forward net, last, on the structure gate.

### 13.6 ⚠️ Open before ship

- **N=4 SMP boot** and the **Verilator NBA cross-check** (4 configs) are the remaining gates. Running.
- **The AMO hole is NOT closed by the shadow.** AMO/LR reads do not forward — they wait on
  `sb_ld_ovl` / `!sb_empty` — so the same one-cycle skew exists for them: `sb_empty` goes true on the
  drain ack, one cycle before the merge is readable. litmus N=2/N=4 are identical to baseline and the
  boots pass, which is evidence but not proof (the atomic population that straddles a drain ack may
  simply be rare). If any N=4 gate fails, the fix is `sb_empty_eff = sb_empty && !sbs_v_q` at the
  ordering gates — the same contract, applied to the readers that cannot forward.
- **`wt_fires`** (§9): a full-line write-through drain acks on its bus grant and never enters the local
  array. The shadow covers it for one cycle, which is not obviously the right lifetime there. Still open.
- **Scaffold hygiene:** `STORE_NOPORT_SBE` is the bisection arm and is now 0; keep it as a fold-away
  arm with its numbers (§13.3) or delete it at ship. `SB_DRAIN_SHADOW=0` must stay byte-identical.

### 13.7 ✅ Verilator NBA cross-check — 4/4, all matching the Veryl sim

Same standard R3 and Block W shipped on. Built with `-O1 -j 2` (the 4-hart tops still ICE cc1plus at
`-O3` on this box) into freshly `rm -rf`'d `build_*` dirs.

| config | Verilator (NBA) | Veryl sim |
|---|---|---|
| N=1 boot | **PASSED** (SBI shutdown, x3==0xAA), `$finish` 124 ms = 12.4 M | 12,370,000 ✓ |
| N=2 SMP boot | **PASSED**, `$finish` 173 ms = 17.3 M | 17,340,000 ✓ |
| N=4 SMP boot | **PASSED**, `$finish` 248 ms = 24.8 M | 24,780,000 ✓ |
| litmus N=4 | **PASSED**, `pass=1 fail=0 tohost=1`, `cy=3,878,771` | 3,880,000 ✓ |

⚠️ **A `$finish` line is NOT a pass.** Both wrappers `$finish` unconditionally after printing their
verdict, so an early `$finish` only proves the loop broke — on `pass` for the boots (`MAX_CY` =
100,000,000, so finishing at 24.8 M IS conclusive there) but on `pass || fail` for litmus, which is
not. The litmus verdict line had to be re-read from a second run. **Grep the verdict, not `$finish`.**

### 13.8 Revert path proven

All three consts back to DEAD (`STORE_NOPORT=0`, `SB_DRAIN_SHADOW=0`, `LSR_B2B_SBQ=1`) reproduces the
baseline exactly: default suite 252/0, litmus N=2 `cy=002e3bf0`, **N=1 boot `cy=00c91c60` =
13,180,000** — the recorded baseline to the cycle. `STORE_NOPORT_SBE` is kept at 0 as a fold-away arm
with its numbers in §13.3.

### 13.9 The generalisable lesson

🎯 **When a bubble protects a window, removing ANY of the mechanisms that create the bubble re-opens
the window — so fix the window, not the door.**

Block T deleted the LSR turnaround bubble, found it had been the only thing keeping loads out of the
store-drain window, and patched the *door* it had come through (`LSR_B2B_SBQ`, a capture gate). L1.a
deleted the commit-store port hold and walked into the **same window through a different door** —
which is why the N=2 wedge looked like a brand-new bug and was not. Building the *contract* instead
(the entry stays visible until every reader that could have snapshotted the array before its write
has completed) closed both doors at once and let Block T's patch be deleted.

This is the second consecutive block where `feedback_removed_bubble_was_protection` was the operative
rule. The refinement worth carrying forward: **enumerate the mechanisms that create a protective
bubble, not just the one you are removing.**

---

## 14. L1.b routing census (2026-08-19) — ⚠️ the first read was made with the WRONG census

N=1 boot at the shipped default (`cy=00bcc050` = 12,370,000), `DBG_CENSUS=1`.

### 14.1 What L1.a did to the store bucket

| bucket | before L1.a | after |
|---|---|---|
| `store` sole-blocker | 701,128 (5.32 %) | **102,057 (0.82 %)** — −85 % |
| ├ `store_drive` | 641,637 | **6,348** — **−99 %** |
| └ `sb_cnt >= 3` | 49,485 | **85,937** — GREW |

The port is still held **650,789 cy** by plain stores (15,975 by atomics), but it is almost never the
thing a waiting load is stuck behind any more. L1.a did not remove the hold; it removed the hold's
*consequence*. `sb_cnt >= 3` grew because stores now reach the buffer without waiting for the port, so
it runs fuller — an expected second-order effect, and the largest store-side term left.

### 14.2 🚨 The trap: a load-wait census cannot price a COMMIT-path change

Read off §14.1 alone, L1.b's ceiling is **6,348 cy = 0.05 %** and the block is dead. That reading is
**wrong**, and the error is worth recording because it is not the usual one:

**A probe-missed store falls to the `sb_2cyc_ok` path, which costs a COMMIT CYCLE, not a load stall.**
`rob_commit_ack`'s term `!(MEM_PIPE && c_is_store && !sb_elig && !c_is_amo && !store_fetched_q)` holds
the store at cycle N (translate) and retires it at N+1. ~345,000 stores miss the probe on this boot,
so ~345,000 cycles of **retire bandwidth** — **2.8 % of the boot** — are lost to the two-cycle path.
`lw_cause_cnt`'s sole-blocker buckets count *loads waiting*; they are structurally blind to this.

🎯 **Lesson: match the census to the PATH the change moves, not to the biggest pool you already have
instrumented.** L4/W1a/L3 taught that a bucket bounds opportunity and not prize; this adds the prior
question — *is the mechanism even in this census's population?*

### 14.3 The build is a RETRY, not a speculative store walk

Store execute events 1,855,598, priority-encoded:

| outcome | events | share |
|---|---|---|
| probe **FIRED** (PA registered at execute) | 1,510,968 | **81.4 %** |
| missed — **the shared port was busy** | 267,781 | **14.4 %** |
| missed — TLB / perm / cacheability | 42,645 | 2.3 % |
| missed — `rob_has_pending_xlate` | 34,204 | 1.8 % |

**86 % of the misses are port contention, not TLB misses.** So L1.b does not need a speculative store
PTW (an order more machine, and squarely in the retire/memory-ordering risk area); it needs a **probe
retry for a ROB-resident store in an idle port cycle** — which is precisely the resource L1.a freed.

**Sketch.** A retry pointer over the ROB store shadow selects an entry with `sh_store_pa_valid == 0`;
on a cycle no one else drives the dmem port it presents that entry's `sh_store_addr` and captures
`dmem_sprobe_pa/ok` into `sh_store_pa`/`sh_store_pa_valid`. Needs a SECOND write port into those two
arrays (today only the CDB writes them) and one more arm on the `core_dmem_vaddr` mux.

⚠️ **Staleness is already safe by ORDER, not by luck:** an SFENCE/satp write younger than the store
commits *after* it, so a PA captured early is still that store's PA at its own commit. The retry must
still honour `rob_has_pending_xlate` exactly as the execute-time probe does.

---

## 15. ❌ L1.b REFUTED (2026-08-19) — an opportunistic re-probe on the shared MMU port is structurally impossible

The build §14.3 routed — a probe retry for a ROB-resident store in an idle port cycle — was built
DEAD (byte-identical, 252/0, litmus N=2 `cy=002e3bf0`), flipped, and **fails catastrophically**:
43-50/252, a litmus forbidden outcome, N=1 boot dead at instret 121,850.

### 15.1 Three facts that pin it

1. **The ROB write port is innocent.** Forcing `sqrt_cap` to 0 (port arm live, second write port
   dead) still fails — **208/252**.
2. **Tightening the free-cycle predicate makes it WORSE.** Adding
   `dmem_mmu_idle && !lsr_capture && !lsr_drive && !replay_q && !iq_issue_valid` moved it from 202
   to **209** failures. A predicate that reads more of the users' state is not a safer predicate.
3. **It breaks in BARE mode** (`rv64ui-add`), where the probe cannot capture at all —
   `o_sprobe_ok` carries `vm_enabled`. So the damage is not the captured PA.

### 15.2 🎯 Root cause — the shared address bus has an UNCONDITIONAL consumer

```veryl
} else {
    m_pa_q = dmu_dmem_addr;    // heliodor_core.veryl:11709 — every cycle, NO enable
```

The M-stage PA register mirrors whatever sits on the shared MMU output, and its consumers read it
under their **own** latched control (`m_wen_q` / `m_ren_q`). **There is therefore no such thing as a
free cycle on this port**: every cycle's address is captured by the M stage, so an opportunistic
re-probe simply becomes the next cycle's memory address.

🎯 **This is the mirror image of `feedback_driver_is_not_owner_sync_read`.** There, after
`DCACHE_SYNC_READ`, the *driver* was no longer the *owner*. Here **every driver is unconditionally
the owner** — the bus has a free-running latch on it. Both say the same thing from opposite sides:
**on a shared bus, establish who captures each cycle before assuming a cycle is spare.**

⚠️ The design error was mine and it is worth naming precisely: "the probe is side-effect-free" is
true of the **MMU** and false of the **shared bus**. Side-effect-freedom of a *consumer* says nothing
about the *medium*.

### 15.3 Two ways to revive it, neither justified by L1.b alone

- **(a) Give `m_pa_q` a real enable.** Improvement in its own right — it free-runs today, so it also
  toggles for nothing — but it is the heart of the shipped MEM_PIPE, and it would change the M-stage
  timing that RETIRE_DECOUPLE / SB_PA_REG all rest on.
- **(b) Give the probe its OWN address port** — a second TLB read port. Kills the whole hazard class
  (fix the window, not the door), and costs real area under the realistic-SRAM discipline.

Against L1.b's **~2.8 % ceiling** (§14.2 — a bound, not a prize; L4 step-2 recovered zero from
7.14 %), neither is worth doing *for L1.b*. If (a) is ever done for its own reasons, L1.b becomes
nearly free and should be re-tried then.

**`SQ_RETRY` is kept DEAD and marked DO-NOT-FLIP** rather than deleted, so this dead end is not
re-derived. The `i_sqrt_*` ROB write port stays with it (it is correct and inert at 0).

### 15.4 Block L1 status

| piece | status |
|---|---|
| L1.c `SB_DRAIN_SHADOW` — the visibility contract | 🚢 **SHIPPED** |
| L1.a `STORE_NOPORT` — the store stops taking the load port | 🚢 **SHIPPED** |
| `LSR_B2B_SBQ` deleted (subsumed) | 🚢 **SHIPPED** |
| L1.b — universal execute-time translate | ❌ **REFUTED** on the shared port (§15.2); needs (a) or (b) first |
| L1.d — unified PA-keyed forward net | not started; IPC measured zero, ship-for-structure only |

**Next front is no longer in the store path.** After L1.a the `store` sole-blocker bucket is 102,057
(0.82 %), of which `sb_cnt >= 3` is 85,937. The largest single sole-blocker is now **`lsr` 745,356
(6.03 %), which Block T established is 100 % dcache miss — an MLP question, not a queue question.**

---

## 16. 🏁🚢 SHIPPED (2026-08-19) — `SB_EMPTY_EFF`: the visibility contract now holds for the readers that CANNOT forward

§15.4 left the contract with a footnote, recorded honestly as a standing item: L1.c closed the
drain-ack window for loads by keeping the drained entry in the `sbf*` net for one cycle, but **AMO/LR
have no forward net at all** — they keep order by WAITING on `sb_empty`, and `sb_empty` goes true on
the drain ack, the very edge the merge lands on. So the shipped contract was **stated more strongly
than it held**. This closes it.

### 16.1 The change: one signal, two different questions

`sb_empty` is read at 15 sites, and they are not asking the same thing:

- **ORDERING** — "are all my older stores architecturally readable?" — 12 sites, now `sb_empty_eff`:
  `dc_flush_req`, `asq_takeover`, the retire gate's `c_is_amo || c_store_mmio ? !sb_empty`,
  `c_serial`'s drain wait, the page-edge load hold, the release-AMO and `cas_q` issue gates,
  `dc_i_wen`'s write-order term, **`amo_cwr_en`** (the atomic's commit write), `asq_dr_start`,
  `asq_alloc`, `vu_mem_idle`.
- **RESOURCE** — a different question, deliberately left on the raw `sb_empty`:
  `imem_aw_grant` ("is the drain port free?" — it feeds `sb_pop`'s underflow guard) and
  `sdrain_swen` ("is there anything left to drain?" — a shadow entry has ALREADY drained, so
  asserting swen for it would re-drain the line).

`sb_empty_eff = sb_empty && !sbs_v_q`. It cannot deadlock (`sbs_v_q = sb_pop`, a single-cycle pulse,
so it is at most ONE cycle later) and every use delays in the conservative direction.

### 16.2 🎯 The gap was REAL and REACHABLE — litmus N=2 moved

| gate | before | after | Δ |
|---|---|---|---|
| default suite | 252/0 | **252/0** | — |
| **litmus N=2** | 3,030,000 | **3,070,000** | **+1.32 %** ← the contract's price |
| litmus N=4 | 3,880,000 | 3,870,000 | −0.26 % |
| dhrystone / coremark | 235,804 / 394,546 | **bit-identical** | 0 |
| N=1 boot | 12,370,000 | 12,370,000 | 0.00 % |
| **N=2 SMP boot** | 17,340,000 | **16,950,000** | **−2.25 %** |
| N=4 SMP boot | 24,780,000 | 24,720,000 | −0.24 % |

**litmus N=2 changing is the headline, and it is not a performance result.** It is direct evidence
that AMO/LR *do* straddle the drain-ack window — the footnote was reachable, not theoretical. Every
gate had been green with the footnote in place, which is exactly what "green is evidence, not proof"
was written to guard against. **The right move was to make the implementation match the claim, not to
weaken the claim to match the implementation.**

The bare-mode benchmarks being **bit-identical** confirms the change is as local as intended: a
single-hart bare program with no atomics never has an ordering waiter coincide with a shadow cycle.

⚠️ **The N=2 SMP boot −2.25 % is UNEXPLAINED and is not claimed as a mechanism.** A conservative
delay making the machine faster is plausible (delaying the atomic drain start changes the contention
waveform — the same shape as M2a's "replay was an accidental backoff"), but that is a hypothesis. It
*is* real rather than noise: Verilator reproduces it independently (169 ms vs the previous 173 ms).

### 16.3 Verilator NBA cross-check — 4/4, verdict lines read (not `$finish`)

| config | Verilator | Veryl sim |
|---|---|---|
| N=1 boot | **PASSED**, 124 ms = 12.4 M | 12,370,000 ✓ |
| N=2 SMP boot | **PASSED**, 169 ms = 16.9 M | 16,950,000 ✓ |
| litmus N=4 | **PASSED**, `pass=1 fail=0 tohost=1`, `cy=3,864,789` | 3,870,000 ✓ |
| N=4 SMP boot | **PASSED**, 247 ms = 24.7 M | 24,720,000 ✓ |

### 16.4 Block L1 cumulative, and what is still open

| gate | pre-L1 baseline | shipped now | Δ |
|---|---|---|---|
| **N=1 boot** | 13,180,000 | **12,370,000** | **−6.15 %** |
| **N=2 SMP boot** | 18,100,000 | **16,950,000** | **−6.35 %** |
| **N=4 SMP boot** | 25,650,000 | **24,720,000** | **−3.62 %** |

No SRAM added. New baselines: N=1 `cy=00bcc050` · N=2 `cy=0102a2f0` · N=4 `cy=01793280` ·
litmus N=2 `cy=002ed830` / N=4 `cy=003b0d30` · dhrystone 235,804 · coremark 394,546.

**Still open — `wt_fires`.** A full-line write-through drain acks on its **bus write-channel grant**
and never enters the local array, so "architecturally readable" for it is a bus-ordering property, not
an L1 lifetime one. The shadow covers it for one cycle, which is not obviously the right lifetime.
⚠️ **Do not lengthen the shadow on suspicion** — measure whether a `wt_fires` drain ack is ever
straddled first. Absent evidence, it stays a recorded standing item, not a speculative fix.
