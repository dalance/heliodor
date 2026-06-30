# CP — commit-store pre-translate (the first headline-moving lever)

> ## ▶️ ACTIVE FRONT (2026-06-30, user-chosen after the Phase-C gate-trace refutation)
>
> The user chose **this front** as the next structural step over Phase C dcache and
> the vrf. Reason: a clean gate trace at **FETCH_REG=1** confirms the binding wall
> `head → n_inflight[5]` (**14.130 ns**, the global CP once the front-end is staged)
> is **exactly this path** — commit-store **live MMU TLB (~3.8 ns) + PMP-W (~1.9 ns)**
> → fault → commit-trap → free-list. The dcache is NOT on it; it is the masked 3rd
> front 1.2 ns below (`cp_dcache_sync_read_plan.md` correction banner). The 2nd front
> is `vrf` 13.880 (vector, 246+ paths). So cutting this front alone caps at ≈13.88
> (vrf) — a ~0.25 ns CP move — but it IS the FINAL-structure gap: **store address
> translation belongs at execute (Stage-A), not commit.** Build it for the structure
> (the P1' probe `7598185` is the down-payment); the CP follows in the coordinated
> bundle once vrf + the rest also move.
>
> **The hard part is NOT the pre-translate — it is the fallback.** §4.1 proved the
> naive flip (`sb_vm_ok = c_pretx_fast`, force every non-pre-translated VM store onto
> the slow M-stage path) **breaks the Linux boot**: a cacheable DRAM store has never
> completed via the M-stage *dcache write* (it always SB-pushes after the TLB fills),
> so it is lost → corruption. The correct fallback is a **2-cycle registered SB push**
> (§9 below, NEW): a non-pre-translated cacheable VM store translates+registers its PA
> in commit cycle N and SB-pushes the **registered** PA in cycle N+1 — a new path,
> distinct from the M-stage slow write, so no store ever SB-pushes with a live-MMU PA
> in the same cycle the free-list/`n_inflight` reads. Only then does the MMU leave the
> front (modulo the AMO commit-translation residual, atomicity-bound).

Concrete RTL plan for the **first measurable-CP step** of the deep-pipeline campaign
(`deep_pipeline_sram_plan.md`). Phase-0 FF-insertion proved the 15.300 ns headline is
the **commit-store front**, not the dcache read (`speculative_wakeup_design.md §9.1`).
This plan removes the MMU from that front.

Entry: master `bf1287c`, CP **15.300 ns**, endpoint `head → n_inflight[5]`.
(Re-measured 2026-06-30 at FETCH_REG=1 after the AMO-wstrb wall cut `66c0f14`: the same
front is now `head → n_inflight[5]` **14.130 ns** — the AMO strobe that dominated 15.300
is gone, exposing the **plain-store** commit MMU+PMP translation as the binding wall.)

---

## 1. The front to cut (grounded, `veryl synth` path #1/#6)

Both headline fronts — `n_inflight` (commit, 15.300) and `valid_*` (dcache fill,
14.870, 55/60 of the top paths) — share one combinational sweep:

```
head[FF] → ROB commit decode → c_store_addr (= sh_store_addr[head], the store VA)
         → commit_store_fire → store_drive
         → core_dmem_vaddr  (mux: store_drive ? c_store_addr : agu_addr_iss)   [core:5309]
         → u_dmem_mmu translate (tlb_vpn → tlb_level → tlb_valid)              [core:6214]
         → { free-list update → n_inflight }   { dcache fill/invalidate → valid_* }
```

**Stores translate ONLY at commit.** `core_dmem_vaddr` is the single shared MMU input,
time-multiplexed `vu_mem > store-commit(store_drive) > PTW-walk > load-issue(agu_addr_iss)`
(`core.veryl:5309`). A committing store flips it to `c_store_addr` and runs the MMU on
the commit critical path. `store_drive = commit_store_fire && !load_walk_busy &&
!fast_store` (`core:5286`).

## 2. ⚠️ CORRECTED (2026-06-30) — the store does **NOT** translate at issue; an active TLB **probe** is needed

> **The original §2 premise below was FALSE and is kept struck-through for the record.**
> A plain store on slot-0 asserts **no MMU request** at execute: `core_dmem_ren` excludes
> stores and `core_dmem_wen = store_drive` is 0 until commit, so `mem_req = i_wen||i_ren = 0`.
> With no request the dmem MMU passes the VA straight through (`mmu.veryl:198`
> `o_dmem_addr = i_vaddr` when `!ptw_valid`), so `dmu_dmem_addr` at a store's execute is the
> **untranslated VA**, not the PA. Proven empirically: a paging boot with a capture-vs-commit
> checker showed **every** captured store MISMATCH (cap = `0xffffffff8…` kernel VA, live =
> `0x80……` PA). `core.veryl:~3760` states it directly: "A STORE translates only at commit …
> its CDB-time is_sfault is always 0 for them."
>
> ~~Pre-translate = capture the issue-time `dmu_dmem_addr` (PA) … the store already drives
> the one MMU at its slot-0 issue~~ — **wrong: the MMU is not driven at issue.**

**The real mechanism (matches `speculative_wakeup_design.md §9.1` "pre-translate stores AT
EXECUTE"): a side-effect-free STORE TLB probe.** The dmem MMU's TLB lookup (`tlb_hit`,
`tlb_pa`, `tlb_perm_w`, `tlb_u_ok`) is **pure combinational on `i_vaddr`** — it is computed
regardless of `mem_req`; only the *output mux* gates `o_dmem_addr` on `ptw_valid`. So expose
the TLB-hit translation as new outputs **`o_sprobe_pa` / `o_sprobe_ok`** (mmu → dmem_mmu →
core), evaluated with **store semantics** (W with D folded at fill: `tlb_perm_w = pte_w &&
pte_d`; U via the same `tlb_u_ok`; cacheable; canonical; IDLE; V=0 single-stage; + a PMP-W
and PMA-backing check on the probe PA in dmem_mmu). At a store's execute cycle
`core_dmem_vaddr` already carries the store's VA (confirmed: `cap_pa == c_store_addr`), so
the probe yields the store's PA — **the exact PA the commit translation would produce**.

> **Pre-translate = at execute, latch the side-effect-free TLB-probe PA (`dmem_sprobe_pa`)
> into the ROB when `dmem_sprobe_ok` (clean store-permitted cacheable hit) and no
> translation-state change is in flight; at commit drain that registered PA.** No new MMU
> port (combinational TLB read, no request); anything not a clean hit falls back to commit
> translation. ✅ **Implemented + verified DEAD (commit `7598185`, P1'): probe = commit
> translation on 240/240 boot stores, 0 mismatch, cy byte-identical.**

### 2.1 ⚠️ The synth-CP crux discovered in P1' — the fallback must ALSO leave the fast front

The 15.300 front is specifically the **fast `sb_vm_ok` store**: a clean TLB-hit DRAM store
that **translates AND commits in one cycle** (`head → commit_store_fire → MMU TLB hit →
sb_vm_ok → rob_commit_ack → n_inflight`, and the dcache fill/invalidate → `valid_*`). Slow
stores (AMO/SC, misaligned, MMIO, TLB-miss) already take ≥2 cycles via the M-stage
(`store_fetched_q`, MEM_PIPE M3a) and are **not** on this front.

`veryl synth` reports the **worst-case** path, so pre-translating the *common* store while a
*non-pre-translated* `sb_vm_ok` store can still translate-and-commit in one cycle leaves the
MMU on the front → **the headline would not drop.** Therefore the flip must **force every
non-pre-translated VM store onto the slow (registered, ≥2-cycle) path**, i.e. redefine
`sb_vm_ok` to admit **only** pre-translated DRAM stores (`c_pretx_fast`, §3.6). A VM store
that hit the TLB at commit but was not pre-translated at execute (entry filled in between)
then commits one cycle slower — a small, bounded IPC cost inside the campaign budget. This
is the behavioral change that makes the cut real; it is also why the flip needs the full
SMP/litmus/ACT4 ladder (store-commit timing + ordering change).

## 3. Design

### 3.1 ROB per-entry state (captured at execute / CDB edge) — ✅ IMPLEMENTED (P1')
- `sh_store_pa[rob_idx]` ← `dmem_sprobe_pa` (the **active TLB-probe** PA, not `dmu_dmem_addr`).
- `sh_store_pa_valid[rob_idx]` ← `cdb.is_store && !iq_iss_is_amo && !store_drive &&
  !mmu_walk_inflight && !vu_mem_active && dmem_sprobe_ok && !rob_has_pending_xlate`
  (a clean store fast-path probe hit on the store's own VA, no in-flight xlate change).
- `sh_store_xfault` ← **constant 0**: faults never pre-translate (any W/D/U/PMP/PMA deny
  makes `dmem_sprobe_ok=0` → fall back to the commit walk, which raises the precise fault
  exactly as today). The field is kept for plumbing symmetry but is dead; drop it if a
  later cleanup wants to.

Captured on the **same CDB write** that writes `sh_store_addr` (the executing store on
lane-0, whose `agu_addr_iss == core_dmem_vaddr` this cycle is what the probe sees).

### 3.2 Commit drain uses the pre-translated PA — ▶️ P3 (flip)
At commit, for a **pre-translated plain DRAM store** (`c_pretx_fast`, §3.6):
- `c_store_pa = sh_store_pa[head]` (a ROB FF, plumbed via `o_commit_store_pa`) feeds the
  SB push (`sb_pa`) and the MMIO classifier (`c_store_mmio`) directly — via a
  `c_store_eff_pa = c_pretx_fast ? c_store_pa : (dmem_vm_on_op ? dmu_dmem_addr : c_store_addr)`
  mux at each consumer.
- **`store_drive` no longer asserts the MMU/dcache port** for this store: split it into
  `store_drive_mmu = store_drive && !c_pretx_fast` and use `store_drive_mmu` for
  `core_dmem_vaddr` / `core_dmem_wen` / `core_dmem_wstrb` and the load-blocking / port
  gates (a `c_pretx_fast` store frees the port — it goes to the SB, not the dcache). The
  store still *retires* as a store (the role-2 `store_drive`/`commit_store_fire` stays).
- No store fault is delivered for a `c_pretx_fast` store (it was a clean hit by
  construction); faulting stores are never `c_pretx_fast`.

### 3.6 The flip's eligibility gate `c_pretx_fast` and the forced-slow fallback
```
c_pretx_fast = STORE_PRETRANSLATE && commit_store_fire && c_store_pa_valid
            && !c_is_amo && dmem_vm_on_op && st_wstrb_hi == 8'd0      // aligned single-dword
            && c_store_pa[63:25] == 39'h40                            // DRAM
            && !(c_store_pa[31:14]==18'h20000 || c_store_pa[31:12]==20'h80008); // not tohost
sb_vm_ok = c_pretx_fast;   // <-- the semantic change: ONLY pre-translated DRAM stores are fast
```
Replacing the live-MMU `sb_vm_ok` with `c_pretx_fast` forces every **non**-pre-translated
VM store (TLB-miss-at-execute, HSV V=1, uncached, misaligned, stale-xlate fallback) onto the
slow `!sb_elig` M-stage path (`store_fetched_q`, ≥2-cycle, MMU-translated + registered) — so
**no** store translates-and-commits in one cycle and the MMU leaves the `n_inflight`/`valid_*`
front (§2.1). MMIO pre-translated stores (`c_store_pa` not DRAM) are not `c_pretx_fast` →
slow path with the live MMU (unchanged), so `store_drive_mmu` stays asserted for them.

### 3.3 Scope — plain `sb_elig` stores only (first cut)
Pre-translate **plain cacheable/MMIO stores** (the `sb_elig = fast_store || sb_vm_ok`
class, `core:5732`) — the high-frequency bulk. **Leave commit-translation untouched
for:**
- **AMO / LR / SC** — must stay single-cycle atomic at commit (proven SMP constraint:
  a +1 commit slip breaks atomicity, litmus N2 amoadd wedge). They already issue at
  ROB head; excluded from pre-translate.
- **misaligned / 2-dword / `is_cas_q`** stores — special commit handling; defer.
- **bare-mode** (`fast_store`) — no translation at all; `c_store_addr` is already PA.
- A store whose issue-time translate was **incomplete** (TLB miss → PTW walk in flight,
  or `dmem_mmu_busy`) → `sh_store_pa_valid=0` → **fall back to commit translation**
  (today's path). Pre-translate is a *fast path*, not a replacement.

### 3.4 Translation-state-change hazard (the correctness crux)
A store may issue (and pre-translate) **before** an older `satp`/`sstatus`(SUM/MXR/MPRV)
write, `SFENCE.VMA`, or `MRET`/`SRET` commits — making its pre-translation **stale**.
Today this is impossible because stores translate at commit, after all older ops retire.

Mitigation (reuse existing machinery): **extend `i_block_mem_xlate` to gate store
*issue-time translation capture*.** The barrier (`iq_int` consumes it; high while an
older translation-state change is in flight, `core` drives it) already blocks
LOAD/AMO issue for exactly this reason. Two options:
- **(a) gate capture:** a store may *issue* freely, but `sh_store_pa_valid` is set only
  if `!i_block_mem_xlate` at its translate — else it falls back to commit translation
  (§3.3). Cheapest, no new issue stall. **Recommended.**
- **(b) gate issue:** block store issue under `i_block_mem_xlate` (symmetric with
  loads). Simpler invariant, small IPC cost (stores wait behind rare xlate-changes).

Either keeps the SMP/precise-translation invariant: a store never *commits* a
translation that crossed an older translation-state change.

> Note: store→store and store→PTE ordering is **not** an issue — translation depends
> only on `satp`+PTEs, and PTE writes are `SFENCE`-ordered (covered by the barrier). A
> store does not depend on a *younger or older data store* for its own translation.

### 3.5 What stays / what is removed on the front
- Removed from the commit front: `c_store_addr → store_drive → core_dmem_vaddr → MMU`
  for pre-translated plain stores. The free-list (`n_inflight`) and dcache fill
  (`valid_*`) decisions now consume a **registered** PA (`sh_store_pa[head]`, a ROB FF)
  instead of a combinational MMU output.
- Kept: the SB push/merge, the dcache write, the fill/invalidate — but fed from the
  ROB FF, so the `head → … → MMU` levels (≈3.9–7 ns of path #1) leave the cone.

## 4. Staging (param-gate DEAD → flip → corner-debug)

- ~~**P1 (dead, `1661bed`):**~~ captured `dmu_dmem_addr` — **WRONG (the VA, §2)**; superseded.
- ✅ **P1' (dead, `7598185`):** add the side-effect-free STORE TLB probe (`mmu.o_sprobe_*`,
  `dmem_mmu` PMP-W/PMA gate) and capture `dmem_sprobe_pa` into the ROB; plumb the commit-side
  `o_commit_store_pa/xfault/pa_valid` → `c_store_*`. `STORE_PRETRANSLATE=0` → fields/outputs
  written-but-unread → **byte-identical** (default 252/0; N1 boot 4/4, 7.1 cy=0x01210060).
  Verified: a temp capture-vs-commit checker showed **240 MATCH / 0 MISMATCH** — the probe PA
  equals the commit translation on every clean store.
- ▶️ **P3 (flip) — NEXT, the high-risk step:**
  1. Define `c_pretx_fast` (§3.6) and `c_store_eff_pa`; route `c_store_eff_pa` into `sb_pa`
     and `c_store_mmio` (in place of the `dmem_vm_on_op ? dmu_dmem_addr : c_store_addr` mux).
  2. `sb_vm_ok = c_pretx_fast` (the forced-slow-fallback semantic change, §2.1/§3.6).
  3. `store_drive_mmu = store_drive && !c_pretx_fast`; use it for `core_dmem_vaddr` /
     `core_dmem_wen` / `core_dmem_wstrb` and the `!store_drive` load-blocking / port gates
     (`load_blocks_on_store`, `core_dmem_ren`, `sc_walk_drive`, `replay_drive`, `lsr_drive`,
     `core_dmem_is_amo`). Keep role-2 `store_drive`/`commit_store_fire` for retire/SB-push.
  4. Confirm the dcache fill/invalidate (`valid_*`) path is not driven by a `c_pretx_fast`
     store (it goes to the SB, not the dcache); if it is, feed it `c_store_eff_pa`.
  5. `STORE_PRETRANSLATE=1`. **Synth-measure** (expect `n_inflight` 15.300 + `valid_*` 14.870
     to drop off the MMU; new headline ≈ `redirect_pc_q` 14.8 / `rs1_rdy` 14.565).
  6. **Full gate ladder** (memory ordering is not separable): default 251/0 ·
     `--backend-validate` · **ACT4 696/696 (ESSENTIAL — S-mode + Sv39 store page/access
     faults are exactly this path)** · litmus N2/N4 · N2/N4 SMP boot · Verilator SMP.
  7. **IPC**: boot-cy / CoreMark / Dhrystone (non-pre-translated VM stores now 1 cycle
     slower; expect small, inside the ~10–15 % budget).
  Corner-debug watch-list: stale-xlate fallback (§3.4, gated at capture by
  `!rob_has_pending_xlate`), MMIO classification from `c_store_eff_pa`, HSV (V=1) stores
  forced slow, the SB push/forward consistency when the port is freed to a concurrent load,
  and SMP store ordering / atomicity (litmus).

### 4.1 ⚡ P3 flip EXPERIMENT (2026-06-30) — measured **15.300 → 14.890** but REVERTED (two blockers)

The flip above was implemented and measured, then reverted to `STORE_PRETRANSLATE=0`
(tree back at P1' `7598185`). Two findings:

1. **Synth: only −0.41 ns (15.300 → 14.890, −2.7 %).** The cut removed the plain-store
   `sb_vm_ok` MMU dependency, but the worst path is STILL `head → commit_store_fire →
   store_drive_mmu (mux select) → core_dmem_vaddr → MMU tlb → pa → u_pmp_amo_w → … →
   n_inflight`. **The residual is the AMO/SC + slow-store commit translation feeding the
   commit fault → commit decision → free-list.** AMO/SC translate at commit single-cycle
   by atomicity constraint (proven: a +1-cy AMO commit slip breaks SMP atomicity), so this
   tail is NOT pipelinable the way a plain store is. The dense plateau right below (14.870
   `valid_*`, 14.8 `redirect_pc_q`, **14.565 `rs1_rdy` keystone floor**) means even crushing
   the *entire* commit-store front caps at ≈14.5 — i.e. the whole lever is worth ≈5 % and is
   gated by the **keystone**, not by this front.

2. **Functional: the flip BREAKS the Linux boot** (kernel panic, cause 13 load page fault,
   `cy=0x02aea540`, x3≠0xAA) although default `veryl test` 252/0 (arch + litmus N2) passes.
   Root cause: `sb_vm_ok = c_pretx_fast` forces a **non-pre-translated cacheable VM store**
   (TLB-hit at commit but not at execute) onto the slow `!sb_elig` M-stage path — but that
   path was only ever exercised for MMIO / misaligned / TLB-miss stores; a cacheable DRAM
   store has **never** completed via the M-stage write (it always went through the SB after
   the TLB filled). The M-stage cacheable write does not write-allocate/SB-merge correctly →
   lost store → memory corruption → the load fault. **The slow path is NOT a correct
   substitute for the SB fast path for cacheable stores.**

**→ Correct redesign (if pursued):** a non-pre-translated cacheable VM store must still go
to the **SB**, but via a **2-cycle registered SB push** (translate + register PA in cycle N,
SB-push the registered PA in cycle N+1) — a NEW path, distinct from the M-stage slow write —
so no store SB-pushes with a live-MMU PA in the same cycle. Only then does the front fully
leave the MMU (modulo the AMO residual). This is materially more work than the flip above,
for a ≈2.7 % headline (≈5 % if the AMO residual is also pre-translated, atomicity-hard).

**→ Strategic read:** the 14.4–15.3 ns band is a dense multi-front wall **capped by the
`rs1_rdy` 14.565 keystone floor**. Picking individual fronts (commit-store) yields sub-1 ns
each with diminishing returns and real correctness risk. The campaign's actual lever is the
**keystone** (`speculative_wakeup_design.md`, Phase A). Keep P1' (the verified probe) as a
down-payment; sequence the commit-store *completion* (2-cycle SB push + AMO pre-translate)
AFTER the keystone, or fold it into the keystone's execute-staging flip.

- **P4:** re-synth → expect `n_inflight`/`valid_*` to drop off the MMU; new headline
  is whatever front is next (likely the load-issue `agu_addr_iss → MMU` — shared with
  the keystone — or `redirect_pc_q`). Measure IPC (boot-cy/CoreMark/Dhrystone).

## 5. Gates (every step — memory ordering is not separable)
default `veryl test` 251/0 · `--backend-validate` · **ACT4 696/696 (ESSENTIAL — store
page/access faults under S-mode + Sv39 paging are exactly this path; ACT4 alone caught
the MEM_PIPE store corner)** · litmus N2/N4 · N2/N4 SMP boot · Verilator SMP.

The dirty-bit / demand-paging store-fault tests (`rv64si-dirty`, execve demand paging,
referenced at `core.veryl:~3746`) are the precise-fault canaries — run them.

## 6. Risk register
| risk | severity | mitigation |
|---|---|---|
| stale pre-translation across an older satp/SFENCE | **critical** | §3.4 barrier-gated capture + commit fallback; ACT4 Sv* + SMP |
| store page-fault precision (raised early / dropped) | high | fault detected at issue, **delivered at commit** (unchanged timing); rv64si-dirty canary |
| MMIO/uncached store misclassified (PA-dependent) | med | `c_store_mmio` recomputed from `sh_store_pa`; ACT4 + UART boot |
| AMO atomicity (must NOT be pre-translated) | **critical** | AMO/SC excluded by construction (commit-translated, single-cycle) |
| capture/commit PA mismatch (wrong rob_idx) | high | dead-gate byte-identical check; capture on the same CDB write as `sh_store_addr` |

## 7. Anchors
- `core.veryl:5309` core_dmem_vaddr mux · `5286` store_drive · `6214` u_dmem_mmu ·
  `6225` o_dmem_addr=dmu_dmem_addr · `5732` sb_elig · `~3746` store-fault commit
  delivery · `692-705` SB (sb_pa/sb_line/sb_vm_ok).
- `rob.veryl:1258` sh_store_addr capture · `598` o_commit_store_addr · `41`
  i_cdb_store_addr.
- Precedent: `cp_direction_c_port_separation_plan.md` (commit-port separation, the
  ≤1.3 ns commit-tail bound — this plan instead cuts the *front*, the actual prize).

## 8. Live measurement at FETCH_REG=1 (2026-06-30, the active-front re-grounding)

`--dump-timing --timing-paths 1`, FETCH_REG=1 (front-end staged, so the wall is
exposed), STORE_PRETRANSLATE=0, master tree. Path #1 `head → n_inflight[5]` 14.130 ns:

| range (ns) | sub-cone | ~ns |
|---|---|---|
| 0.00→2.96 | head → commit reg-read → `c_is_cas_q` → `commit_store_fire` | 2.96 |
| 3.11→7.18 | store VA → `u_dmem_mmu.u_mmu` TLB (`tlb_vpn`/`tlb_level`/`tlb_valid`/`tlb_hit_ppn`/`pa`) | **~3.8** |
| 7.71→9.59 | `u_pmp_amo_w` (store-write PMP, shared plain+AMO) → `pmp_deny` | **~1.9** |
| 9.59→9.88 | `acc_deny` → `dmem_mmu_acc_fault_s` | ~0.3 |
| 9.98→12.13 | `commit_store_fire`/`sb_elig`/`c_is_store` → `rob_commit_valid`/`ack` → `commit_csrw_satp`/`c_illegal` → `commit_excp`/`commit_trap`/`commit_redirect` → `do_push2` | ~2.25 |
| 12.51→14.13 | `u_fl.n_inflight` counter update | ~2.0 |

**MMU TLB (~3.8) + PMP-W (~1.9) = ~5.7 ns of the 14.13** — the chunk pre-translate
removes (replaced by a registered-PA/-fault read). The store-write PMP `u_pmp_amo_w`
is **shared** by plain stores and AMO, so the **AMO residual** (commit-translated,
single-cycle, atomicity-bound) keeps a near-identical path alive after the plain-store
cut — the ≈2.7 % cap of §4.1. The 2nd front is `vrf` 13.880 (vector, 246+ paths), so
even a full plain-store cut lands at max(AMO-residual, 13.880). **CP leverage is small;
the value is the FINAL-structure boundary (store xlate → execute).**

## 9. The boot-corner-correct fallback — 2-cycle registered SB push (the part P3 lacked)

§4.1's flip broke boot because `sb_vm_ok = c_pretx_fast` forced a non-pre-translated
**cacheable** VM store onto the M-stage slow path, whose cycle-N+1 action is a **dcache
write** — a cacheable store has never completed that way (it SB-pushes after the TLB
fills), so it was lost. The fix **reuses the existing M-stage 2-cycle handshake**
(`store_fetched_q` + `m_pa_q`, `core.veryl:1637`/`7074`) but **routes a cacheable held
store's cycle-N+1 action to an SB push from the registered `m_pa_q`** instead of the
dcache write.

### 9.1 The store-commit classes after the flip
| class | gate (all registered/cheap — NO live MMU) | cycle-N | cycle-N+1 |
|---|---|---|---|
| bare `fast_store` | `fast_store` | SB push, PA=`c_store_addr` | — (1-cy) |
| **pretx VM** `c_pretx_fast` | §3.6 (`c_store_pa_valid` ROB FF) | SB push, PA=`c_store_pa` | — (1-cy) |
| **non-pretx VM cacheable** | `!sb_elig` ∧ VM ∧ !AMO ∧ aligned ∧ (m_pa_q DRAM) | **translate, hold** (set `store_fetched_q`) | **SB push, PA=`m_pa_q`** ← NEW |
| MMIO / misaligned / TLB-miss | `!sb_elig` (existing) | translate, hold | M-stage dcache write (existing) |
| AMO / SC | `c_is_amo` | commit-translate (live, atomicity) | — (1-cy, unchanged) |

The two changes:
- **(A) `sb_vm_ok = c_pretx_fast`** (§3.6): the live-MMU 1-cycle fast retire is removed.
  Non-pretx VM cacheable stores become `!sb_elig` → they fall into the `store_fetched_q`
  2-cycle handshake automatically. The `rob_commit_ack` M3a hold-gate (`core:3399`,
  `!(… && !sb_elig && !c_is_amo && !store_fetched_q)`) now uses the registered `sb_elig`
  (= `fast_store || c_pretx_fast`) — **no live MMU on the n_inflight gate.**
- **(B) cycle-N+1 SB-push routing** (NEW): in the `store_fetched_q` retire cycle, if the
  registered `m_pa_q` is **cacheable DRAM** (`m_pa_q[63:25]==39'h40 && !tohost`), fire an
  SB push with `sb_pa = m_pa_q`, `sb_vm_ok_2cyc = 1`, and the store data/strobe from the
  ROB head (`c_store_data`/`c_store_wstrb` — the head has not advanced during the hold),
  and **suppress** the M-stage dcache write for it. MMIO/tohost held stores keep the
  M-stage write (existing). So: `sb_pa = c_pretx_fast ? c_store_pa : (store_fetched_q &&
  m_pa_cacheable ? m_pa_q : c_store_addr)` and `sb_vm_ok = c_pretx_fast || (store_fetched_q
  && m_pa_cacheable && !m_fault_q)` — all registered.

### 9.2 Why n_inflight leaves the MMU
No store retires from the **live** MMU in one cycle: pretx retires from the ROB FF
`c_store_pa`; non-pretx holds one cycle (`store_fetched_q`, the gate registered) and
retires from `m_pa_q` (registered). The live `!dmem_mmu_busy` only feeds the
`store_fetched_q` D input (cycle N), and the store does not retire in cycle N, so n_inflight
in cycle N never depends on the live MMU. The AMO commit-translate residual (single-cycle,
atomicity) is the remaining live-MMU n_inflight contributor (§8) → the ≈2.7 % cap.

### 9.3 IPC
Every **non-pretx** VM cacheable store now costs +1 commit cycle (was 1, now 2). The
pretx hit-rate (TLB warm at execute) bounds this; P1' saw 240/240 probe==commit on a
boot, so the rate is high. Measure boot-cy / CoreMark / Dhrystone (≤10–15 % budget).

### 9.4 Corners (the full ladder is mandatory — store ordering is not separable)
- **SB drain / forward consistency** when the held store's port is freed to a concurrent
  load in cycle N (the SB push is one cycle later — a younger load must still forward
  correctly or stall). Reuse the existing `sb_st_ovl` / forward machinery.
- **store→store ordering**: two back-to-back non-pretx stores each take 2 cycles; in-order
  commit preserves order, but verify the SB merge (`sb_merge_ok`) across the +1 slip.
- **fault precision**: a non-pretx store that **faults** at commit translate (cycle N)
  must trap, not SB-push — gate (B) on `!m_fault_q` and deliver the registered fault.
- **SMP atomicity**: AMO/SC stay 1-cycle commit-translate (unchanged). litmus N2/N4 + SMP.
- **stale xlate** (§3.4): the pretx capture is `!rob_has_pending_xlate`-gated; the
  non-pretx fallback translates at commit (after older xlate-changes retired) — safe.

### 9.5 Staging
- **P5a (DEAD scaffold, byte-identical):** add the registered `m_fault_q` + the
  `m_pa_cacheable` decode + the gate-(B) SB-push wiring, all under `STORE_PRETRANSLATE=0`
  so `sb_vm_ok`/`sb_pa` keep their live-MMU form (the new terms unread). Verify default
  252/0 + N1 boot cy exact + synth CP 14.565 unchanged.
- **P5b (flip):** `STORE_PRETRANSLATE=1` → changes (A)+(B) active. Synth-measure (expect
  n_inflight → max(AMO-residual, vrf 13.880)). Full ladder + IPC.
- **P6 (optional, atomicity-hard):** AMO/SC PA pre-translate (W2) to remove the residual —
  translate at execute, keep only the atomic RMW *write* at commit. Deferred.

### 9.6 P5a built + P5b flip experiment (2026-06-30) — boot corner FIXED, CP needs the trap-deferral

- **P5a DEAD scaffold complete + byte-identical** (commits `808b806` change A, `2850a52`
  change B): default 252/0, litmus N2 cy=0022a330, N1 7.1 boot cy=01210060 (exact) +
  V-boot cy=013cc5c0, synth CP 14.565 unchanged. The scaffold is kept DEAD
  (STORE_PRETRANSLATE=0) — flip-ready, like the A-EXE E1/E2 scaffolds.
- **P5b flip experiment (STORE_PRETRANSLATE=1, then reverted):**
  - ✅ **The §4.1 P3 boot corner is FIXED.** default 252/0; **5.15 smoke boot pass=1
    (cy=00c265a0); 6.6 boot pass=1 (cy=01496ff0)** — a full ~21.6 M-cycle paging boot to
    shutdown. A non-pre-translated cacheable VM store now SB-pushes the registered m_pa_q
    (change B) instead of the lost M-stage dcache write (P3). (The 7.1 model's cc recompile
    of its large embedded image is pathologically slow after a source change — not run to
    completion; the 6.6 full paging boot is the decisive evidence.)
  - **IPC:** 5.15 smoke cy 0x00b6a5d0 → 0x00c265a0 ≈ **+6 %** (every non-pretx VM store
    costs +1 commit cycle). Inside the ~10–15 % budget but high — the pretx hit-rate is
    lower than hoped (many stores miss the execute-time probe: cold TLB / port busy at
    execute). Characterise + improve (e.g. probe earlier / wider) before a permanent flip.
  - 🔑 **change A+B alone is CP-NEUTRAL.** The commit fault-check `commit_store_sfault`
    (`core.veryl:3876`) still reads the **live** `dmem_mmu_fault_s`/`dmem_mmu_acc_fault_s`
    → `c_is_sfault_eff` → `commit_excp` → `rob_commit_ack` → `n_inflight`. So the live MMU
    stays on the n_inflight path via the **fault check**, even though the PA drain is now
    registered. **The CP cut needs the trap-deferral** (route the committing store's fault
    through the registered `c_store_xfault` for pretx / `m_fault_q` for 2-cycle, gating the
    live `dmem_mmu_*_s` arm of `commit_store_sfault` with `!c_pretx_fast && !sb_2cyc_ok`).
  - And even with the trap-deferral, the **AMO commit-translate residual**
    (`amo_commit_acc_fault`, live PMP on `dmu_dmem_addr`, single-cycle by atomicity) keeps
    a near-identical n_inflight path → the ≈2.7 % cap of §4.1, capped further by vrf 13.880.

**→ State: change A+B is a verified, flip-ready DEAD scaffold (the structural Stage-A store
translate + the boot-corner-correct fallback). The CP-relevant flip = change A+B +
trap-deferral (§9.6), folded into the coordinated bundle with vrf / the AMO W2 residual /
the rest — a single-front flip here is CP-neutral-to-≈0.25 ns and costs ~6 % IPC, so it is
not worth flipping standalone.** Next concrete step toward CP: the trap-deferral, then
measure n_inflight at FETCH_REG=1.

### 9.7 Trap-deferral built + flip-measured (2026-06-30, commit `1a7178f`) — cuts to vrf 13.880, NOT AMO-capped

The trap-deferral (the CP-relevant piece) is implemented DEAD (byte-identical) and
flip-validated:
- **It cuts n_inflight as predicted.** A throwaway (defer the live plain fault) AND the
  real trap-deferral both give, at FETCH_REG=1 + STORE_PRETRANSLATE=1: `head → n_inflight`
  14.130 **disappears**, top = `head → vrf` **13.880**. 🔑 **NOT AMO-capped** — §4.1's worry
  was wrong: the AMO-wstrb wall cut (`66c0f14`) had already lowered the AMO commit-translate
  path below vrf, so the commit-store front cleanly cuts 14.130 → vrf 13.880 (−0.25 ns). The
  AMO W2 (P6) is **not** needed to reach vrf.
- **Implementation** (`core.veryl`): register the store fault components m_spage_q (page,
  cause 15) / m_sacc_q (access, cause 7) / m_gstage_q (G-stage, cause 23) alongside m_pa_q;
  `store_xlate_dfr` = a committing plain VM store (not AMO/bare/cbo); `sfault_{pg,acc,gs}_eff
  = store_xlate_dfr ? (store_fetched_q ? m_*_q : 0) : live`. A held store traps from the
  registered fault at its retire cycle; pretx/mid-translate have fault 0 (clean/deferred).
  No c_pretx_fast/commit_store_fire dependency (those are late lets; the fault is 0 in all
  non-store_fetched_q cases, so they are unnecessary). commit_store_sacc/sfault + excp_cause
  rewired to the _eff signals. cbo stays live (its special R-AND-W / pte-acc fault rules are
  untouched — and cbo is rare, so its residual live path is below vrf in practice).
- **Also fixed** a change-B flip-correctness bug: sb_2cyc_ok now excludes a MISALIGNED held
  store (m_wstrbhi_q != 0) so it takes the M-stage 2-line write, not a (double-handling)
  SB push.
- **Validation (DEAD byte-identical + flip functional):** DEAD — default 252/0, N1 7.1 boot
  cy=01210060 exact, synth CP 14.565 unchanged. FLIP — default 252/0, litmus N2 cy=0022a330,
  and **142 ACT4 store-fault canaries PASS** (sv 70 [incl. SvaduPMP], svade 2, exceptionssv
  10 [incl. Zaamo], pmps 60 [PMP-W S-mode]) — the precise Sv page/access + PMP-W fault tests
  the trap-deferral most risks. Reverted to DEAD (STORE_PRETRANSLATE=0); the permanent flip
  waits for the vrf bundle.
- **Remaining before a permanent flip:** full ACT4 696, litmus N4, N2/N4 SMP boot, Verilator,
  full boots, IPC (boot-cy / CoreMark / Dhrystone; ~+6 % seen on the 5.15 smoke). All folded
  into the coordinated bundle flip (commit-store + **vrf** + front-end), since the front caps
  at vrf 13.880 alone.
