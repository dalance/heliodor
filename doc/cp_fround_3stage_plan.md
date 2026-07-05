# CP: 3-stage FROUND (unblock the EX_PIPE=1 default flip)

## Why

A-EXE (`EX_PIPE`) is arch-complete (228/0) + SMP-complete (litmus N2/N4 + SMP
boot N2 pass) as of commit `0ee0e5f`. The only blocker to making `EX_PIPE=1` the
default is a **synth CP regression**: `EX_PIPE=1` standalone CP = **17.490 ns**
(vs `EX_PIPE=0` = 14.745 ns), +2.7 ns.

The 17.490 path is **not** an integer-CDB / EX_PIPE net. It is the Zfa FROUND
`rint`-trick rounding-**add**, combinational in FPU stage 1 (~13 ns):

```
u_iq_fp.occupied scan → FP issue-select(s1_pdst) → u_prf_fp read → d1
  → u_fpu.u_fround_d_add (PIPE=0, ~13 ns combinational) → fr_d_sum_fflags
  → fpu_fflags_comb → s2_cheap_fflags (FF D)          [197 levels]
```

It is EX_PIPE-**independent** but only *exposed* at EX_PIPE=1: at EX_PIPE=0 the
DEAD A-EXE scaffold's const nets let synth const-prop shrink the FP cone (this
path is <14.165, off the top-800 endpoints); at EX_PIPE=1 the scaffold goes live
(+231K gates), const-prop is lost, and the fround-add path floats up to #1.

**Confirmed fix (throwaway synth):** give `u_fround_{s,d}_add` `#(PIPE:1)` →
EX_PIPE=1 CP 17.490 → **14.745** (endpoint returns to the front-end
`pc_q→rs1_rdy` floor = matches EX_PIPE=0; regression gone).

## Structure (this is structural progress, not CP-chasing)

The FPU (`u_fpu: fpu_wrap #(PIPE:1)`) is *always* 2-stage. FROUND today is
2-stage: rounding-add (stage 1, ~13 ns combinational) | magic-subtract (stage 2).
Making the add `PIPE:1` splits the add across two flops, so FROUND becomes a
proper **3-stage** op: add-part1 (N) | add-part2 (N+1) | magic-sub (N+2), and its
result broadcasts at N+2 instead of N+1. The sub stage (~13 ns) is still below the
current 14.745 front-end floor (masked); it gets split later when the floor drops.

## Gating discipline

Gate the whole change on a new fpu_wrap param **`FROUND_PIPE`**, wired from core
as `EX_PIPE`. `FROUND_PIPE=0` (EX_PIPE=0, the production default) keeps today's
2-stage FROUND, **byte-identical**. `FROUND_PIPE=1` (EX_PIPE=1) activates the
3-stage FROUND. This keeps every commit EX_PIPE=0 byte-identical (the campaign
invariant) and lets the final `EX_PIPE 0→1` flip activate both the registered CDB
*and* the 3-stage FROUND together.

## Completion: FROUND as a fixed-latency multi-cycle op (busy-hold)

The FP scheduler (iq_fp) is **CDB-driven** — `fp_prf_ready` is set by the actual
FP CDB broadcast, not a fixed-latency speculative wake. So a FROUND that
broadcasts at N+2 wakes its consumers at N+2 automatically; **no scheduler
change**. The only requirement: FROUND must broadcast at N+2, not N+1, and must
not collide with a common op on the single CDB port.

Model FROUND (in 3-stage mode) exactly like div/sqrt: **hold it at the iq_fp head
for 2 extra cycles** via `o_fpu_busy` (the core gates `iqf_issue_ack` with
`!fpu_busy`), broadcasting on the 3rd cycle. Holding makes everything trivial:
- operands (`d1`/`s1_val`) and metadata (`i_issue_rd_pdst`/`rob`/`has_rd`) are
  **stable** while held → no s2/s3 metadata pipelining, no operand realignment
  (the existing `fr_*_sum_q` / `fr_*1*_q` registers converge to the correct value
  by N+2 because their inputs are held);
- busy blocks any new issue during the hold → no common op is in flight at N+2 →
  **no CDB-port collision** (same guarantee div/sqrt rely on);
- the div/sqrt "else" branch of the CDB field-select (`if s2_valid ? s2_* :
  i_issue_*`) already carries a held-at-head op — FROUND reuses it verbatim.

2-cycle-hold FSM (2-bit counter, const-gated → DCE at FROUND_PIPE=0):
```
fround_active = FROUND_PIPE==1 && i_issue_valid && is_fround
fround_cnt_q  : 0 on reset/flush/!active; else (cnt==2 ? 0 : cnt+1)
fround_busy   = fround_active && cnt != 2   // cycles 0,1 hold issue
fround_done   = fround_active && cnt == 2   // cycle 2 broadcast
```
Trace (op held at head T..T+2): T cnt0 busy; T+1 cnt1 busy; T+2 cnt2 **done** →
broadcast+ack. `fr_*_sum` valid T+1 (adder PIPE:1), `fr_*_sum_q` valid T+2, sub
combinational T+2 → `fround_*_final` → `fpu_result` → `o_cdb.data`.
`fpu_fflags_comb` (FROUNDNX NX from `fr_*_sum_fflags[0]`, valid T+2) → `o_fflags`.
div/sqrt vs fround are mutually exclusive at head; busy-hold ⇒ s2_valid and
fround_done never coincide → no arbitration needed.

## Edit list (all EX_PIPE=0 byte-identical)

1. **core** `u_fpu` inst (`heliodor_core.veryl:3093`): add `FROUND_PIPE: EX_PIPE,`.
2. **fpu_wrap** param (`:19`): add `param FROUND_PIPE: u32 = 0,`.
3. **fpu_wrap** `u_fround_s_add`/`u_fround_d_add` (`:850`,`:864`): add `#(PIPE: FROUND_PIPE,)`.
4. **fpu_wrap** `fpu_result` FROUND (`:1494-1499`): emit `fround_*_final` when
   `!(PIPE==1 && FROUND_PIPE==0)` (i.e. also when FROUND_PIPE==1), else `64'd0`.
5. **fpu_wrap** add `is_fround` + `fround_cnt_q` FSM + `fround_busy`/`fround_done`
   near `is_div_sqrt` (`:2675`).
6. **fpu_wrap** `o_fpu_busy` (`:2673`): `|| fround_busy`.
7. **fpu_wrap** `s2_valid` (`:2730`): `&& !(FROUND_PIPE==1 && is_fround)`.
8. **fpu_wrap** `cdb_fire` (`:2794`): `(s2_valid || cdb_fire_ds || fround_done)`.
9. **fpu_wrap** `o_cdb.has_rd` (`:2797`): `(cdb_fire_ds || fround_done) && i_issue_has_rd`.

(pdst/data/rob/fflags/dest_is_fp already fall through to the held-at-head else
branch when `s2_valid=0`; no change.)

## Verification

- **EX_PIPE=0 byte-identical:** `veryl test` default 252/0 (litmus N2
  cy=0022a330), N1 boot cy-exact (7.1 01210060 / 7.1V 013cc5c0 / 6.6 013ee8a0),
  `veryl synth` 14.565 / 159948 FF (fround_cnt_q DCE via const-gate). ACT4 F/D.
- **EX_PIPE=1 correctness:** ACT4 Zfa fround 6/6, F 82/82, D 114/114,
  `--backend-validate` FP, arch 228/0.
- **EX_PIPE=1 CP:** standalone synth 17.490 → **14.745** (endpoint back at
  front-end `pc_q→rs1_rdy`).
- Then the remaining default-flip gates: N4 SMP boot (EX_PIPE=1), IPC
  (boot cy / CoreMark / Dhrystone), litmus N2/N4 re-confirm → flip `EX_PIPE 0→1`.

## Results / refinements (as implemented)

- **Edit 4 refined:** routing the fround result through `fpu_result` (as first
  drafted) created a *false* timing path `fr_d_sum_q → magic-sub → fpu_result →
  s2_cheap_result` (dead for FROUND since `s2_valid=0`, but veryl times it) that
  held the EX_PIPE=1 CP at **14.910 ns**. Fixed by broadcasting the held FROUND via
  a **dedicated `o_cdb.data` arm** (`fround_data = is_D ? fround_d_final :
  fround_s_final`), leaving `fpu_result` dead for FROUND (like the 2-stage path).
  The magic-sub then lands only on `o_cdb.data` (masked below the front-end floor),
  and the CP drops to the front-end floor **14.745 ns** (`pc_q → rs1_rdy`).
- `FROUND_PIPE` is a **`bit`** param wired `FROUND_PIPE: EX_PIPE`.
- **+4 dead FFs at EX_PIPE=0** (not FF-neutral): `fround_cnt_q` (2 bits × the
  scalar + vector fpu_wrap instances) is NOT DCE'd by veryl's simple synth, because
  a submodule INSTANCE parameter is not const-propagated into the body (unlike a
  same-module `const` such as EX_PIPE / SPEC_WAKE). The FFs hold 0, are off the
  critical path, and a real synth tool folds them. **CP is exactly neutral**
  (14.745 = 14.745), which is the invariant that matters; not worth a two-const
  local-const refactor to shave 4 dead FFs.

### Measured

- EX_PIPE=1: synth CP **17.490 → 14.745** (endpoint back at `pc_q → rs1_rdy`);
  ACT4 Zfa **zfaf 7/7 + zfad 15/15** (all 6 fround/froundnx PASS, Sail-signed);
  N4 SMP Linux boot **PASS** (`pass=1`, this milestone's outstanding gate (1)).
- EX_PIPE=0: default suite **252/0** (litmus N2 cy=0022a330 exact); synth CP
  **14.745** (FF 159953 vs baseline 159949 = +4 dead, see above); N1 boot cy-exact.

### 🚨 New blocker found: EX_PIPE=1 IPC regression

N4 SMP boot at EX_PIPE=1 = **cy 0x1644af0 ≈ 23.3M** vs EX_PIPE=0 ~16.6M = **+40%**.
Far beyond the +1 CDB latency; likely the E3 issue-deferral (`ex3_defer`) over-
deferring the integer ALU whenever mshr/fpu/div is active (memory-heavy SMP boot
hits this constantly). This is a SECOND default-flip blocker alongside the (now
fixed) CP regression. Quantify with CoreMark / Dhrystone (EX_PIPE=0 baselines:
CoreMark 276,893 cy / IPC 1.352, Dhrystone 210,037 cy / IPC 1.301) → then decide:
tighten E3 vs accept vs defer the flip.
</content>
</invoke>
