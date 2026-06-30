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
