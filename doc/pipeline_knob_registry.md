# Pipeline / SRAM knob registry — phase-1 close-out (2026-07-17)

Single map of every `const`/`param` pipeline-staging + SRAM-migration knob the deep-pipeline campaign
(`deep_pipeline_sram_plan.md`) accumulated, classified as **LIVE-shipped**, **DEAD-scaffold** (byte-identical
at its default, a component of a *future* program), or **bisect-alias** (tracks a parent, kept as de-risking
infrastructure). This is the entry point for future CP/pipeline work — the DEAD scaffolds ARE the extension
mechanism (flip one to add a stage / fold a port). Regenerate the raw list with:
`grep -rnE '^\s*(const|param)\s+[A-Z_0-9]+\s*:\s*bit\s*=' src/ --include='*.veryl'`.

Phase-1 outcome (`deep_pipeline_status_and_replan.md` §8.2): the realistic-SRAM migration (goal ③) is
DONE (D$ data + L2 data TRUE 1R1W, sync-read shipped); the near-term ~12 ns / 6–7-stage target is REACHED on
the *real* CP floor (~12.49–12.51 ns, the vector execute→writeback datapath — the reported headlines were
FALSE PATHs, `cp_store_queue_plan.md` §6). The 7.5 ns / 10-stage aspiration is a *separate future program*
whose components are the DEAD scaffolds below.

---

## 1. LIVE — shipped, permanent (the `=0`/`false` branch is a documented revert path; do NOT remove)

| knob | file:line | what it ships |
|---|---|---|
| `FETCH_REG=1` | heliodor_core:1552 | front-end F\|D register (bundle `c2a98fe`) |
| `STORE_PRETRANSLATE=1` | heliodor_core:2018 | plain-store PA registered off the retire gate (bundle) |
| `RETIRE_DECOUPLE=1` | heliodor_core:4390 | commit-fault sources registered off `rob_commit_ack` (bundle) |
| `VALU_PIPE=1` | vector_unit:63 (param) | VU same-width int ALU: VRF-read \| compute+write split (bundle) |
| `MEM_PIPE=1` | heliodor_core:2003 | MMU→dcache PA-latch pipeline (registered translated PA) |
| `SB_PA_REG=1` | heliodor_core:5889 | **R1a (this campaign's last scalar ship)** — shared commit live-TLB (sb_pa + cbo.m PMP) off `rob_commit_ack`, CP −6 % |
| `VFP_PIPE=1` | vector_unit:34 (param) | VU FP operand FETCH stage (registers u_vfpu operands) |
| `VINT_PIPE=1` | vector_unit:53 (param) | VU permute (vrgather) addressing FETCH stage |
| `FRONT_PIPE=1` | iq_int:36 (param) | scheduler front register |
| `SCHED_WAKEUP=1` | iq_int:32 (param) | scheduler wakeup path |
| `BLK_ROT=1` | rob:808 | ROB block-rotate commit |
| `DCACHE_SYNC_READ=1` | dcache:605 | D$ synchronous (registered) read = a real pipeline stage |
| `DCACHE_DATA_1RW=1` | dcache:620 | D$ data byte-write-enable TRUE 1-write (8R4W→7R1W) |
| `DCACHE_DATA_READ_1R=1` | dcache:655 | D$ data read-port fold → **TRUE 1R1W** (with CAP_1R) |
| `DCACHE_NF_REROUTE=1` | dcache:680 | non-folded (AMO/misaligned/replay/xline) → registered read |
| `DCACHE_CAP_1R=1` | dcache:741 | writeback-capture read folds onto rd1_index → the FINAL 1R1W fold |
| `DCACHE_TAG_READ_1R=1` | dcache:781 | D$ tag demand-hit from registered tags (a pipeline stage) |
| `L2_SYNC_READ=1` | l2cache:249, mem_ctrl:249 | L2 data synchronous read |
| `L2_PORTS_1R1W=1` | l2cache:260 | L2 data write-port collapse 2R2W→2R1W |

## 2. DEAD scaffolds — byte-identical at default; components of the *future* 7.5 ns / 10-stage program

Each is verified byte-identical at its shown value; flipping is a full-SMP-ladder-gated step (+ often an IPC
/ throughput measurement). Grouped by the program phase (`deep_pipeline_sram_plan.md` §142) it belongs to.

| knob | file:line | program / phase | flip note |
|---|---|---|---|
| `SEL_PIPE=0` | iq_int:266 | **A-SCHED** — scheduler-logic pipelining | ⭐ the plan's identified **"only path below ~12 ns → the 7.5 ns gate"**; the highest-leverage un-built scaffold |
| `EX_PIPE=0` | heliodor_core:1865 | **A-EXE** — execute keystone (CDB register / regread\|exec\|wb) | wires `FROUND_PIPE`/`FMA_PIPE3`/`STAGE3` in the scalar FPU |
| `VFP_EX_PIPE=0` | vector_unit:2261 | vector datapath cut (`cp_vector_datapath_cut_plan.md`) | **built + gate-tested this session**: functionally correct (=1 252/0, vfarith PASS) but moves real CP only 0.02 ns alone (vx co-floor) — flip only PAIRED with the un-built integer-vx cut; throughput-gated |
| `DECODE_REG=0` | heliodor_core:1806 | front-end (sub-13.120) | built-dead; masked below the current wall |
| `IMEM_MMU_STAGE=0` | imem_mmu:199 | Phase D front-end | instruction-side MMU stage |
| `ICACHE_SYNC_READ=0` | icache:561, heliodor_core:336 | Phase D — I$ shape-W | net-negative alone (§21); superseded by fetch-directed prefetch |
| `ICACHE_FIFO_BYPASS=0` | heliodor_core:818 | Phase D — I$ fetch decouple | N4-clean body vs de-risked bypass |
| `BTB_SYNC_READ=0` | btb:88 | Phase D — predictor SRAM | flip bundled with shape-W |
| `BHT_SYNC_READ=0` | bht:54 | Phase D — predictor SRAM | (livelock caution — directory sync) |
| `IBTB_SYNC_READ=0` | ibtb:66 | Phase D — predictor SRAM | |
| `SPEC_WAKE=0` | iq_int:297 | scheduler (speculative wakeup) | `speculative_wakeup_design.md` |
| `LOAD_SPEC=0` | iq_int:312 | scheduler (load speculation) | |
| `L2_READ_1R1W=0` | l2cache:274 | Phase C — L2 read-port fold | the L2 analog of D$ CAP_1R (un-flipped) |
| `MEM_PIPE=0` | vector_unit:43 (param) | VU mem pipeline | distinct from the core's MEM_PIPE=1; VU-element mem split |
| `FROUND_PIPE=0` `FMA_PIPE3=0` | fpu_wrap:27,33 (param) | wired via EX_PIPE (scalar) / VFP_EX_PIPE (vector) | register the fround-add / FMA mantissa-mul |
| `STAGE3=0` | fp_fma:30 (param) | FMA 3rd stage | wired via FMA_PIPE3 |

## 3. Bisect-aliases — KEEP (intentional de-risking infrastructure, not clutter)

These track a parent LIVE const (so `=0` on the parent is byte-identical) but stay **named per fold** so a
Verilator/NBA hang or a coherence failure can be pinned to ONE fold: temp-set the parent =1 and override a
single alias to 0 to revert just that fold to its live read (`cp_dcache_sync_read_plan.md` §14.6/§14.7). This
is how the S1 demand-read NBA hang was pinned. Inlining them would destroy the bisect capability + the
per-fold documentation — do NOT. All in `dcache.veryl`:

- data read folds (→ `DCACHE_DATA_READ_1R`): `S1_DEMAND` `S2_FILL` `S3_SLOT1` `S4_STREAM`
- nf reroute (→ `DCACHE_NF_REROUTE`): `DCACHE_NF_REPLAY` `DCACHE_NF_XLINE`
- cap sources (→ `DCACHE_CAP_1R`): `CAP_FILL_1R` `CAP_PROBE_1R` `CAP_MIS_1R` `CAP_FLUSH_1R`
- tag (→ `DCACHE_TAG_READ_1R` / `S3_SLOT1`): `TAG_SLOT1` `S5_DEMAND_TAG`
- DCE gates (composite AND of the above — gate the statement-block DCE): `DCACHE_R1_DCE` `DCACHE_R4_DCE`
  `DCACHE_CAP_DCE`

## 4. Non-campaign params (per-instantiation, not scaffolds)

`PMA_FAULT` (core=0, dmem_mmu/imem_mmu=1, mmu=0), `PIPE`/`TAG_W`/`DATA_W`/`IDX_W` etc. — ordinary module
parameters, not deep-pipeline knobs.

---

## Note on `veryl check`

`veryl check` reports warnings (≈4789 `missing_port`, 29 `missing_reset_statement`, some `unused`/`mismatch`)
and exits non-zero — this is the **pre-existing, benign** state (the SRAM data arrays + pipeline registers
intentionally lack reset for area; `missing_port` is systemic). The functional gate is `veryl test` (252/0).
Not a phase-close blocker; do not chase.
