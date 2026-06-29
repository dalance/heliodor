# CP — commit-store pre-translate (the first headline-moving lever)

Concrete RTL plan for the **first measurable-CP step** of the deep-pipeline campaign
(`deep_pipeline_sram_plan.md`). Phase-0 FF-insertion proved the 15.300 ns headline is
the **commit-store front**, not the dcache read (`speculative_wakeup_design.md §9.1`).
This plan removes the MMU from that front.

Entry: master `bf1287c`, CP **15.300 ns**, endpoint `head → n_inflight[5]`.

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

## 2. The key enabler — the MMU **already translates the store's VA at issue**

A store issues on **slot-0** (the only mem-capable issue lane; slot-1/pipe-1 excludes
load/store/amo). At its issue cycle, `core_dmem_vaddr = agu_addr_iss` = the store's
`rs1+imm` (no `store_drive` yet) → the MMU produces `dmu_dmem_addr` = the store's **PA**
— and today that result is **discarded** (a store does not touch the dcache at issue;
it re-translates at commit). The store's **VA** is already captured into the ROB at
execute (`rob.veryl:1258 sh_store_addr[i_cdb_rob_idx] = i_cdb_store_addr`).

> **Pre-translate = capture the issue-time `dmu_dmem_addr` (PA) + fault into the ROB,
> then drain that PA at commit instead of re-running the MMU.** No new MMU port: the
> store already drives the one MMU at its slot-0 issue, and at most one mem op issues
> per cycle, so there is zero added port pressure.

## 3. Design

### 3.1 New ROB per-entry state (captured at execute / CDB edge)
- `sh_store_pa[rob_idx]` ← `dmu_dmem_addr` (the issue-time translated PA).
- `sh_store_xfault[rob_idx]` ← `dmem_mmu_fault_s || dmem_mmu_acc_fault_s` (store page /
  access fault, latched at issue) + the fault sub-fields needed for `mtval`/`htval`
  (gpa/gstage) already plumbed for loads.
- `sh_store_pa_valid[rob_idx]` ← issue-time translation was **complete and usable**
  (TLB hit, not a PTW-walk-in-progress, not blocked — see §3.3).

Captured on the **same CDB write** that already writes `sh_store_addr` — gate by
"this CDB op is a store AND its issue-cycle MMU translated its own VA" (the executing
store on lane-0 is the op whose `agu_addr_iss` the MMU saw).

### 3.2 Commit drain uses the pre-translated PA
At commit, for a **pre-translated plain store** (`sh_store_pa_valid[head]`):
- `c_store_pa = sh_store_pa[head]` drives the SB push (`sb_pa`/`sb_line`) directly.
- **`store_drive` no longer asserts the MMU** for this store → `core_dmem_vaddr` stays
  on the load-issue path; the `head → … → MMU → {n_inflight, valid_*}` sweep is gone.
- The precise store fault is raised at commit from `sh_store_xfault[head]` (the fault
  was *detected* at issue, *delivered* at commit — same precise-trap timing as today;
  `core.veryl:~3746` already special-cases store-fault delivery at commit).

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

- **P1 (dead):** add `sh_store_pa` / `sh_store_xfault` / `sh_store_pa_valid` ROB fields
  + capture logic, param-gated `STORE_PRETRANSLATE: bit = 0`. At 0 the fields are
  written but **unread** (commit still uses `store_drive`/MMU) → cycle-exact,
  byte-identical (N1 boot cy match). Synth CP unchanged.
- **P2 (dead bypass):** wire the commit drain to *optionally* use `sh_store_pa` under
  the param, still 0. Confirm dead.
- **P3 (flip):** `STORE_PRETRANSLATE=1`. Commit drains the pre-translated PA; remove
  `store_drive`'s MMU access for the pre-translated class. **Full gate ladder.**
  Corner-debug: the translation-state-change fallback (§3.4), store-fault precise
  delivery, the `sb_vm_ok`/`sb_elig` interaction, MMIO classification (`c_store_mmio`
  needs the PA — now from `sh_store_pa`), and the fast_store/bare path (unchanged).
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
