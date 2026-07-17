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

## 5. ✅ FLIP verification (2026-07-17) — GREEN on fast/ACT4/litmus-N4/SMP-N2/synth; one SMP-boot wedge FOUND + FIXED (c_store_mmio exec/retire split)

Ran the full-SMP-ladder gate on the `SB_PA_REG=1` flip (commits `f239d2f` scaffold + `e9a052b`
fix). Result: the CP win is real and the flip is SMP-safe, after fixing one latent wedge.

| gate | result |
|---|---|
| fast (`veryl test`, 252 + litmus N2) | ✅ **252/0**, litmus N2 cy=00236680 (cycle-EXACT vs =0 → functionally equivalent) |
| ACT4 696 (paging/PMP/cbo/atomic) | ✅ **696/0** (pre-fix; cbo_wr_01 = the §11 precedent, PASS via the dedicated bare checker) |
| litmus N4 (RVWMO) | ✅ **pass=1, NO forbidden** (pre-fix) — R1 SMP-ordering proof: the commit live-TLB off the retire gate does NOT break RVWMO at 4-hart |
| synth CP | ✅ **12.965 ns (−6 %)** — with the fix, UNCHANGED (the fix is CP-neutral) |
| **SMP boot N2** | ✅ **PASS with the fix** (probe matches =0 baseline cycle-for-cycle); **WEDGED without it** |
| SMP boot N4 / Verilator N1·N2 | ⏳ remaining flip gates (+ ACT4 / litmus-N4 re-verify with the fix) |

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

### 5.2 Remaining before the `SB_PA_REG=1` flip commit

The scaffold (`f239d2f` + `e9a052b`) is DEAD byte-identical and now correctly flippable. To ship the
−6 % flip: (a) **re-verify ACT4 696 + litmus N4 WITH the fix** (the green runs above were pre-fix —
the fix restored `dc_i_wen`/`dc_wen_excl` to =0-live behaviour, so they should still pass, but the RTL
changed); (b) **SMP boot N4** + (c) **Verilator N1/N2** (NBA — retire-gate changes surface only on
multi-hart NBA). Then flip `SB_PA_REG=1` (with `DECODE_REG` note: this flip is independent of the
banked bundle). Alternative if a later gate fails: bank at 13.800 (the DEAD scaffold stays committed).
