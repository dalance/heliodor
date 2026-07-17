# Vector-datapath CP cut — the real post-R1a floor (design plan, 2026-07-17)

After R1a (`SB_PA_REG=1`, −6 %) shipped, `cp_store_queue_plan.md` §6 proved the 12.965 ns headline
(`pc_q → n_inflight`) is a **FALSE PATH** (a fetch-icache-miss → shared-dmem-port → commit-store
stitch, not co-sensitizable). Cutting it (throwaway `ic_route = ic_owns`) drops the reported CP to
**12.510 ns** and exposes the **real** floor: a tight cluster of **vector-unit execute→writeback**
paths. This doc characterizes that floor and the two cuts that move it.

## 1. The real CP floor — two vector-unit paths converging on the `vrf` write

With the `pc_q → n_inflight` false path removed, `synth --timing-paths 30` shows two real endpoints:

| path | delay | what it is |
|---|---|---|
| `fr_d1_q[10] → fr_d_sum_q` | 12.510 | **vector FP double datapath** — the registered FP operand (`u_vu.u_vfpu.d1`) → `u_fround_d_add` (double-precision rounding adder) → the FP result |
| `head[0] → vrf[*]` | 12.490 | **vector integer vx datapath** — `head` → `fifo[head]` → `u_prf.prf` (scalar operand read) → `bbcast` (scalar→vector broadcast) → `valu_res` (per-element ALU mux tree, ~10 mux levels) → `vrf` write |

Both are **REAL** register-to-register datapaths inside the vector unit (`u_vu`). The unit reads
operands, computes (FP add / element ALU), merges into the element position, and writes `vrf` — all in
one ~12.5 ns combinational cone. The existing VU pipeline scaffolds each register PART of this cone but
not the compute→write tail:

- `VFP_PIPE=1` — registers the u_vfpu operands (fetch→stage-1 split, ~23.6→~13 ns). Already live. The
  residual ~12.5 ns is stage-1 itself (`fr_d1_q → fround → vrf`).
- `VALU_PIPE=1` — registers the *vector* operand (`va_vs2_q`). Already live. But the **scalar** operand
  path (`head → prf → bbcast`) for a vx op is NOT registered, so it stays on the `head → vrf` critical
  path.
- `VINT_PIPE=1` — registers vrgather addressing. Already live (permute datapath).

## 2. The two cuts (measured evidence)

### 2.1 FP path — wire the EXISTING `FROUND_PIPE` / `FMA_PIPE3` scaffolds to the vector `u_vfpu`

`fpu_wrap` has two DEAD-at-default FP pipeline params, built for the scalar core's `EX_PIPE`:
- `FROUND_PIPE` (default 0) — registers the double `fround` rounding-add (splits the ~13 ns add into
  add-part1 | add-part2 | magic-sub; the op holds one extra cycle and broadcasts on the 3rd).
- `FMA_PIPE3` (default 0) — registers the FMA 53×53 mantissa multiply before align+add.

The vector `u_vfpu` is instantiated with **only `PIPE:1`**, so both default to 0 — the fround-add is
live on the vector FP critical path. **Measured (throwaway):** adding `FROUND_PIPE:1, FMA_PIPE3:1` to
the `u_vfpu` instantiation → **`fr_d1_q → fr_d_sum_q` DISAPPEARS from the top-30** (the FP path is cut).
So the lever is: pass the FP-pipe params to the vector `u_vfpu` AND extend the VU FP element FSM
(`fp_ph` present/capture) to hold the element one extra cycle (as the scalar `EX_PIPE` FSM does), so
the registered fround/FMA result broadcasts a cycle later. Cost: +1 cycle per FP element.

### 2.2 Integer vx path — register the scalar-operand / `bbcast` path (or `valu_res` writeback)

`head → prf(scalar) → bbcast → valu_res → vrf` survives the FP cut (still 12.490 after 2.1). VALU_PIPE
registered `va_vs2_q` but not `bbcast`. Two options:
- **(a) register `bbcast`** (the scalar broadcast) into the VALU fetch phase, like `va_vs2_q` — puts
  the scalar operand behind a register so `valu_res` computes off registered inputs next cycle.
- **(b) VU writeback stage** — register `valu_res` / the vector compute result before the `o_vd_data`
  merge + `vrf` write. Splits [operand+compute] | [write]. Heavier (a whole writeback phase) but cuts
  both the FP and integer tails uniformly.

Measure both; (a) is the smaller, more surgical cut aligned with the existing VALU_PIPE FETCH phase.

## 3. The fundamental tradeoff — vector latency vs. throughput

Every VU pipeline stage adds **+1 cycle per element** (VFP_PIPE already made FP 3-phase; adding a
writeback makes it 4). For an element-loop vector unit this is a **throughput** cost, not just latency:
a v-op over VL elements pays +VL cycles per added stage. The CP gain (clock speed-up) must beat the
per-element throughput loss on real vector workloads (the RVV Linux boot + any vector benchmark). This
is the classic vector pipelining tension and is why this is "harder, different-domain" work than the
scalar retire scaffolding. **Gate the flip on a vector-workload IPC measurement, not just the CP.**

## 4. Staging + method (DEAD scaffold, per campaign methodology)

1. **FP cut first** (2.1) — ✅ **DEAD scaffold built + committed (`ef12620`, `const VFP_EX_PIPE = 0`).**
   Key simplification discovered during build: **no FSM extension is needed.** `fpu_wrap` asserts
   `o_fpu_busy` during the FROUND_PIPE/FMA_PIPE3 hold cycles (`o_fpu_busy = … || fround_busy || fma_busy`,
   `:2756`), exactly like div/sqrt, and the VU `fp_ph` COMPUTE FSM already gates the CAPTURE/write on
   `!vfpu_busy` (`fp_reg_wr`, `:2368`) — so it waits the extra cycles automatically. The scaffold is just
   the const + the two param pass-throughs on the `u_vfpu` instantiation. Verified DEAD (=0): fast 252/0,
   litmus N2 cy=00236680 (cycle-EXACT).

   ⚠️ **=1 flip gate result (2026-07-17) — functionally correct, but NOT worth flipping alone.** At
   `VFP_EX_PIPE=1`: fast **252/0** including `test_arch_vfarith` (the V3a vector FP arith test —
   vfadd/vfmul single+double, which drives the u_vfpu fround/FMA) PASS, litmus N2 cy=00236680 (integer,
   unchanged). So the +1–2-cycle FP hold via `o_fpu_busy` is functionally sound (the busy-gate auto-wait
   works). **BUT the real CP barely moves.** Throwaway (`VFP_EX_PIPE=1` + `ic_route = ic_owns` to strip
   the false headline): real CP = **12.490 ns** (`head → vrf`), vs. the =0 baseline real CP of 12.510
   (`fr_d_sum_q`). **The FP cut moves the real CP only 0.020 ns (0.16 %)** — because the integer-vx path
   (`head → prf → bbcast → valu_res → vrf`, 12.490) is a **co-floor** sitting 0.02 ns behind the FP path.
   Removing the FP path just exposes it. **Decision: do NOT flip `VFP_EX_PIPE=1` alone** — a 0.02 ns gain
   (masked anyway by the 12.965 false headline) cannot justify ANY vector-FP throughput cost. The DEAD
   scaffold stays committed as a *component* of a future coordinated cut.
2. **Integer vx cut** (2.2a) — register `bbcast` in the VALU fetch phase under a const; byte-identical
   at 0. Measure. (Not yet started.) **This is now the GATING lever:** the FP cut only pays off when
   PAIRED with this one, so BOTH co-floors (12.510 FP + 12.490 vx) drop together below the next real
   floor. A coordinated FP+vx flip with a single throughput budget.
3. Both green + throughput acceptable → flip TOGETHER. Given the FP-cut-alone result (0.02 ns), the
   realistic outcome is increasingly **§6.2 option D**: the real CP floor is the vector datapath at
   ~12.49–12.51 ns (two co-floors), the near-term ~12 ns target is met on the *real* floor, and pushing
   below it needs the coordinated FP+vx multi-cut whose combined vector-throughput cost must be justified
   against a ≤~0.5 ns CP gain — a poor trade unless a vector-FP-heavy workload dominates.

**Note on the reported headline.** Until the `pc_q → n_inflight` false stitch is structurally broken
(register `ic_route` / the dmem grant — `cp_store_queue_plan.md` §6.2 option B), `synth` will keep
*reporting* 12.965 even after these cuts land (the false path caps the number). Track the **real** floor
via the throwaway `ic_route = ic_owns` diagnostic, or land option B to clean the metric.
