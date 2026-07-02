# CP — vrf (VU integer-compute datapath) cut + the dense-band floor finding

The vrf front (`head → vrf` 13.880 ns, 246+ paths) is the dominant masking front of the
upper band. This doc records the gate-trace, the confirmed cut, and — more importantly —
the **data-backed strategic picture** the vrf experiment exposed.

## 1. Gate trace (FETCH_REG=1 + STORE_PRETRANSLATE=1, vrf as #1) — 2026-06-30

```
head → u_vu.fifo_op/h_op decode → velem/h_vd/h_vs2     ~2.4
  → u_vrf.vrf read (vs2)                                ~3.0
  → [~7.2 ns arithmetic cone — xor2/ao22 carry-save = the MULTIPLY (vmuldiv)]
    (synth labels it "u_vu.bbcast" — a name-inheritance artifact; the real bbcast,
     vector_unit.veryl:1271, is just a scalar/imm mux)
  → i_vs2_data / i_vdold_data (operand muxes)           ~1.8
  → valu_res (the per-element VALU result mux)          ~2.0
  → vrf write (FF D)                                    13.880
```

🔑 **The lever is the MULTIPLY (`vmuldiv`, lines 421–465), not the ALU.** The memory's
"vector compute ~8.7 ns" was imprecise — the dominant chunk is the W×W array multiply
(partial products + carry-sum) embedded per-element in `valu_res` (lines 1306/1340/1374/
1408). The integer VALU/multiply path is **purely combinational, single-cycle** — unlike
the FP (`VFP_PIPE`) and permute (`VINT_PIPE`) paths, which already register operands via a
FETCH phase. valu_res is the *end* of the cone (13.73 in the trace), so registering it (the
naive "register the result") is useless (splits 13.88 into 13.7 + 0.15).

## 2. The confirmed cut: register the VALU operands (a FETCH phase, like VINT/VFP_PIPE)

**FF-insertion experiment (2026-06-30, throwaway, reverted):** registered the element-sliced
compute operands (`i_vs2_data[i*W]`/`i_vs1_data[i*W]` → `vs2_rq`/`vs1_rq`, 12 sites in
valu_res + vcmp) and synth-measured. Result: **vrf drops out of the top entirely** (below
13.35). So the cut = register the operands after the VRF read → stage 1 = VRF-read+latch
(~3 ns), stage 2 = multiply+ALU+write (~10 ns), then the multiply itself can be split further.
The clean implementation is a **VALU FETCH phase** matching `VFP_PIPE`/`VINT_PIPE`: a
`VALU_PIPE` param + `va_fetched_q` + registered operands (`va_vs1_q`/`va_vs2_q`), inserted
into the present/capture FSM (vector_unit.veryl ~line 2754). Cost: **+1 cycle per VU integer
op** (the FETCH cycle). Corners: the va_reg group accumulation, masking/tail, LMUL>1 grouping.

## 3. 🚨 The dense-band floor finding (the strategically important result)

The same experiment exposed what is *below* vrf once vrf + commit-store are cut
(FETCH_REG=1, STORE_PRETRANSLATE=1, VALU operands registered):

```
#1   n_inflight    13.840   (commit residual — the cbo path left LIVE in the trap-deferral)
#2-5 n_inflight    13.55-13.73
#6   redirect_pc_q 13.350
     vrf — GONE
```

**The upper band 14.13 → ~12.9 is a near-continuous ramp of ~6 fronts**, each cuttable for
only ~0.05–0.5 ns with its own +1-cycle IPC cost and correctness risk:
`n_inflight 14.13 / 13.84(cbo) · vrf 13.88 · redirect 13.35 · mip/hpm ~13.2 · rs1_rdy/dcache
~12.9`. Cutting vrf in isolation (with commit-store already cut) moved the top only
13.880 → 13.840 (the cbo residual is right there).

🎯 **Data-backed conclusion: front-cutting bottoms at the `rs1_rdy`/scheduler keystone floor
≈ 12.9 ns.** Reaching it means cutting the WHOLE band (front-end + commit-store(+cbo) + vrf +
redirect + mip/hpm) — a giant coordinated bundle, cumulative IPC cost, ~14.565 → ~12.9
(≈ −12 % CP). **7.5 ns is NOT reachable this way** — it needs the keystone (A-SCHED) itself,
which is refuted/stuck (no standalone lever; the select→wakeup loop logic depth). This is
exactly the `deep_pipeline_sram_plan.md` decision gate: "If A-SCHED proves infeasible within
the IPC/SMP budget, the realistic goal revises to the IS-stage depth (~12 ns), not 7.5 ns."

## 4. The strategic crossroads (user decision)

- **(a) Accept the ~12.9 floor (revise the goal 7.5 → ~12.9) and build the bundle.** Cut the
  whole upper band as a coordinated flip. ~−12 % CP, large cumulative IPC, big multi-session
  effort, but a real, achievable structural deepening (the FINAL ~6-7 stage pipe).
- **(b) Re-attack the keystone (A-SCHED) with a fresh approach.** It was refuted as a
  *standalone* lever (the loop is masked by the wall), but it is the ONLY path below ~12.9.
  Needs a genuinely different idea (collapsing/age-ordered IQ, latency-speculative wakeup +
  replay) — the campaign's hardest 80 %.
- **(c) Implement vrf as a structural stage anyway** (the VALU_PIPE FETCH phase) — valid
  "structure not CP" progress + a needed bundle component, accepting it is ~0 CP standalone.
- **(d) Pause / reassess** — front-cutting has hit deep diminishing returns; the remaining
  CP is gated by the keystone and a giant bundle.

## 5. Anchors
- `vector_unit.veryl`: `vmuldiv` 421–465 · `valu_res` 1272 + per-SEW 1306/1340/1374/1408 ·
  operands `a`/`b` 1284-1387 · `o_vd_data` mux 2494 · FSM (fp_ph/va_reg/present-capture)
  ~874–958, 2754 · `VFP_PIPE` 34 / `VINT_PIPE` 53 (the FETCH-phase precedent).
- Measure: `veryl synth --top heliodor_core --dump-timing` at FETCH_REG=1 (+STORE_PRETRANSLATE=1
  to put vrf at #1).

## 6. ✅ IMPLEMENTED + MEASURED (2026-07-02) — `VALU_PIPE` DEAD scaffold, flip cuts vrf 13.88 → GONE (top = n_inflight 13.84 cbo residual)

`param VALU_PIPE` (`vector_unit.veryl:63`, DEAD default 0), matching the VFP_PIPE/VINT_PIPE
FETCH-phase precedent. Registered operands `va_vs1_q`/`va_vs2_q` + `va_fetched_q`; a
plain-valu/compare group first spends a FETCH cycle (`va_fetch_need`) that latches the VRF
operands, and the compute (`va_step`/`va_fire`, gated on `va_ops_rdy`) runs next cycle off the
registers. Widen/narrow/viota/divide keep live operands and DON'T fetch (`va_use_reg=0` for them:
their SELECTED result is `vw_res`/`vn_step`/`viota_res`/`dv_acc`, not the `a*b` compute); **vdold
stays LIVE** (the `valu_res` default / `cmp_seed`) so divide's inactive/tail lanes are correct
without fetching. `va_vs2`/`va_vs1` swapped into `valu_res` + `vcmp` only (the §2 sites).

🔑🔑 **CRUX — the operand alias MUST be PARAM-gated, not runtime-gated (the first attempt failed).**
A first cut used `va_vs2 = if va_use_reg ? va_vs2_q : i_vs2_data` where `va_use_reg` is a *runtime*
signal (exclude widen/div at runtime). Synth: **vrf did NOT drop (13.88 → 14.03, still `head →
vrf`).** The gate trace showed the multiply cone feeding `i_vs2_data → va_vs2` (the mux's LIVE
input) → valu_res → write: STA times the live input through the runtime mux and reports it — a
**FALSE PATH** (it's only "live" when `va_use_reg=0` = widen/div, but then valu_res isn't the
selected result; STA can't correlate the mux selects). This is exactly why VFP_PIPE/VINT_PIPE gate
on the *param* (`if VFP_PIPE ?` folds to just the register — no mux, no false path). Fix: gate the
alias on `VALU_PIPE` (param) → folds to `va_vs2_q` at =1. **Lesson: a datapath operand register is
only effective if its select is a compile-time param (folds the mux away); a runtime `sel ? reg :
live` mux leaves the live input as a false path that defeats the cut. Runtime exclusion belongs on
the FETCH trigger / write-enable (control), NOT on the datapath mux.**

**MEASURED (reverted, tree DEAD):**
- DEAD (VALU_PIPE=0): synth **14.565 unchanged** (registers DCE via the `if VALU_PIPE` block-fold);
  default **252/0** (litmus N2 cy=0022a330); N1 7.1V **vector** boot cy=013cc5c0 = cycle-EXACT.
- FLIP (VALU_PIPE=1 alone): default **252/0** (the `test_arch_v*` vadd/vmul/vmseq exercise the
  fetch phase); 7.1V vector boot pass=1, **cy=013cc5c0 UNCHANGED** = the VU has slack in the boot →
  **~0 IPC cost on boots** (the VU integer datapath is not the boot bottleneck; +1 cy/group only
  bites VU-bound microbenchmarks).
- FLIP CP (FETCH_REG=1 + STORE_PRETRANSLATE=1 + VALU_PIPE=1): **vrf GONE from the top**, CP
  13.880 → **13.840**, top = `head → n_inflight[5]` 13.840 (the cbo commit residual left LIVE in
  the trap-deferral, §3 #1) then redirect_pc_q 13.35 / mip 13.33. **Exactly §3's dense-band
  finding** (vrf drops below 13.35; the cbo residual is the next cap).

**Committed DEAD** (like STORE_PRETRANSLATE/FETCH_REG). Full-ladder (backend-validate / ACT4 /
litmus N4 / N2·N4 SMP / Verilator) deferred to the permanent bundle flip.

### 6.1 🚨 GATE-TRACED (2026-07-02) — the 13.84 cap is the dcache COMBINATIONAL TAG LOOKUP, not the cbo fault; VALU_PIPE nets only −0.04 alone, and the next front is Phase C (dcache sync-read), a different effort class

Tracing the FLIP-CP path #1 (`head → n_inflight[5]` 13.840) to the gate: the dominant segment is
**not** the cbo MMU fault — it is the **dcache combinational tag lookup ~5 ns**:
`commit_store_fire → (priv → dmem_mmu → dmem_pa_m ~1.4 ns) → u_dcache.i_addr → tag RAM Q →
next_tag/next_hit/next_line_hit → miss → lo_miss → srfo_want → index → f_tag/fm_0 → plru_way →
victim_way → vic_valid/vic_dirty → fill_blocked_wb → load_sel → filling → dc_mem_req → o_dmem_iread
→ i_dmem_grant → commit_excp → commit_trap → rob_commit_ack → n_inflight` (two `RAM Q +0.525`
reads = tag-then-victim). So **deferring the cbo fault (the §6/§3 plan) does NOT cut 13.84** — the
fault logic is a small tail; the body is the async dcache tag read + hit/miss/victim/fill cone. This
is precisely the **Phase C dcache-synchronous-read** target (`cp_dcache_sync_read_plan.md §1`, "the
commit-store→dcache wall body"; register the `64×52 13R1W` tag read, `sram_inventory.md` row 2).

🔑🔑 **Strategic consequence — the "quick" WALL front-cuts are EXHAUSTED.** VALU_PIPE's bundle
contribution is only **−0.04 ns** (vrf 13.88 → cbo 13.84 sits right underneath). front-end (FETCH_REG,
scaffold) + commit-store fault (STORE_PRETRANSLATE trap-deferral, scaffold) + vrf (VALU_PIPE,
scaffold) are the last *scaffold-flip* fronts. **Everything below 13.84 is a different effort class:**
(1) the **dcache sync-read (Phase C)** — the 13.84 body AND the load-path dcache read, a major
SMP-critical restructure of the hardest RAM (register the tag/way-mux, 2-stage tag-then-data, corners
in `cp_dcache_sync_read_plan.md §5`), which is *also* the campaign's SRAM-migration goal; then
(2) the **commit/CSR/redirect wall** (`redirect_pc_q` 13.35, `mip` 13.33, HPM 12.6–12.9) exposed
below it. The permanent flip of the 3 current scaffolds alone (→13.84, −5 % CP for ~+7 % IPC, mostly
STORE_PRETRANSLATE) is a **poor trade** — not worth committing until the dcache body is also cut.
**▶️ Next major front = Phase C dcache synchronous-read** (`cp_dcache_sync_read_plan.md`; DEAD
`DCACHE_SYNC_READ` scaffold like ICACHE_SYNC_READ, §6/§8). The scheduler (9.52, A-SCHED) stays well
below the whole band.
