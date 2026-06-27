# CP Front-Pipeline Plan — scheduled-wakeup, no replay (the big lever)

Concrete RTL plan for the **scheduled-wakeup FRONT pipeline** — step 3 of the
committed deep-pipeline program (`cp_pipelining_strategy.md` §6). This is THE lever
below ~24 ns: it registers the iq-issue→execute boundary so the ~7 ns issue-select
megacone head stops sitting in series with regread→AGU→MMU→dcache→commit-cluster.

Seeded 2026-06-27 on branch `lsu-phase1-wip`. Baseline (this branch): `veryl synth`
CP **25.105 ns**, endpoint `u_fl.n_inflight[5]` (commit cluster); default `veryl
test` **251/0**. Companion: `cp_pipelining_strategy.md`, `lsu_pipeline_plan.md` (§11).

---

## 1. The design (grounded in the current RTL)

### 1.1 Today (this branch)
- **ALU op** (fixed latency 1): cycle N — `u_iq` issue-select picks `issue_idx`
  (the `rob.blk_cand`→`iq.iss0_*` argmin cone, ~7 ns) → `u_prf` read (combinational)
  → `u_alu` execute → `o_cdb` broadcast. **All in cycle N.** `alu_wrap` has zero
  `always_ff`; `o_cdb.valid = i_issue_valid`. PRF write at N→N+1 edge; `u_iq` CDB
  snoop (`iq_int.veryl:457`) sets consumers' `rs*_rdy` at the same edge → consumer
  selectable N+1, reads PRF N+1 = exactly when the producer's write landed. **No
  bypass needed today** (`prf_int.veryl` header states this invariant).
- **Plain load** (already 2-staged — the LSR, this branch): cycle N (Stage A) —
  issue-select → AGU (`agu_addr_iss`) → MMU translate (`dmu_dmem_addr`) →
  `lsr_capture` latches `lsr_*_q`, acks out of the IQ; **no dcache read this cycle**.
  Cycle N+1 (Stage B) — `lsr_v_q` → `lsr_drive` reads dcache at `lsr_paddr_q` →
  `u_lsu` forms `lsu_cdb` → writeback (lane 1 `lsr_lane1_fire`, else lane 0).
  Load-use latency = 2 (broadcast wakeup at N+1, consumer selectable N+2).

### 1.2 Target — one front register, "Option A" (register pdsts, regread AFTER)
Insert a **front register (FR)** at the `u_iq` issue output → execute boundary that
holds the *issued op's pdsts + control* (NOT operands — regread stays after the FR).

- **ALU op**: cycle N — issue-select picks, captures into FR (select cone alone in
  cycle N). Cycle N+1 — FR drives `u_prf` read → `u_alu` → `o_cdb` broadcast.
- **Plain load**: cycle N — select → FR. Cycle N+1 — AGU+translate (old Stage A) →
  LSR. Cycle N+2 — dcache (old Stage B) → writeback. (Load-use 2 → **3**, +1.)

Why "Option A" (register pdsts, regread after the FR) and not "register operands":
registering operands keeps regread in the select cone (no CP win) and needs an
operand bypass. Registering pdsts moves the whole regread→AGU→…→dcache chain into
the post-FR cycle and **isolates the select cone** — which is the point.

### 1.3 Scheduled wakeup WITHOUT replay — split by FU latency class
A naive FR adds +1 to every dependency edge → dependent ALU chains at ½ throughput.
Avoided by waking fixed-latency consumers one cycle EARLIER (at the producer's
grant, not its broadcast):

- **Fixed-latency FUs (ALU/branch/JAL/JALR/LUI/AUIPC) → issue-grant SCHEDULED
  wakeup.** When such a producer is GRANTED (`has_issuable && i_issue_ack`, the op
  actually leaves the IQ) at cycle N, set its consumers' `rs*_rdy` and
  `prf_ready[pdst]` at the N→N+1 edge — mirroring the CDB snoop but keyed on
  `sh_rd_pdst[issue_idx]`. The fixed-latency set is exactly the existing `pipe1_ok`
  predicate (`!load && !store && !amo && !csr && !fp_ld && !fp_st && !div`).
- **Variable-latency FUs (loads, div, FP, MSHR fills) → keep the existing
  CDB-broadcast snoop** (`iq_int.veryl:457-490`). Consumers wake on the REAL
  broadcast (true load-use latency) ⇒ nothing to squash ⇒ **no replay machinery.**

### 1.4 The load-bearing timing fact — why NO operand bypass is needed
With scheduled wakeup, for an ALU producer P granted at cycle N:
- `prf_ready[P.pdst]` / consumer `rs_rdy` set at N→N+1 edge → **visible cycle N+1.**
- P executes in cycle N+1 (FR → u_alu, single non-stalling cycle); result written
  to PRF at N+1→N+2 edge → **in PRF cycle N+2.**
- A consumer woken by P is selectable at N+1 → captured into FR at N+1→N+2 →
  reads PRF at N+2. **The FR's one-cycle select→read delay exactly bridges the
  one-cycle gap between "ready visible" (N+1) and "result in PRF" (N+2).** They
  cancel. The consumer reads the correct value with **no bypass**.

The same holds for a consumer *renamed* in cycle N+1 (seeds `rs_rdy` from
`prf_ready[P.pdst]=1`, selectable N+2, reads PRF N+3 — result long landed).

**Hard constraint that makes this true:** a scheduled-wakeup (fixed-latency)
producer MUST traverse the FR in exactly 1 non-stalling cycle. ALU ops never stall
(combinational, fire unconditionally the cycle after grant; flush clears all). The
FR stage must therefore never back-pressure a fixed-latency op. (Loads use
broadcast wakeup, so a load/LSR stall is harmless — no schedule to violate.)

### 1.5 Expected CP after the FR
Cutting the select cone (~7 ns) out of series leaves the back half: regread (~2.7) →
AGU (~0.9) → MMU (~4) → PMP (~1.6) → dcache (~4.6) → commit-cluster (~4) as the
post-FR chain. First-cut CP ≈ **17–18 ns** (the regread→…→commit back half), down
from 25.1. Getting below that needs a SECOND register (after MMU — for loads that is
already the LSR Stage-A/B boundary; for the commit cluster see Direction-C-style
port separation, deferred). Confirm empirically with `veryl synth` after the FR lands.

### 1.6 IPC cost (judged NET against CP, per the committed program)
- Dependent ALU chains: **unchanged 1/cycle** (scheduled wakeup hides the FR depth).
- Load-use: **+1** (2→3) over this branch.
- Branch mispredict / flush penalty: **+1** pipeline stage.
- No mis-speculation replays (scheduled wakeup is deterministic; loads stay broadcast).
Measure boot cy + CoreMark + Dhrystone deltas at the flip-on step; report net.

---

## 2. Staged increments (each green through its gate ladder)

The full change is a uniform "+1 stage" on the execute datapath — large regression
surface (every issue-time memory-ordering side effect shifts a cycle). Build it the
way Phase 8 built superscalar: **infrastructure first, gated OFF (cycle-exact),
then flip on and debug.**

**I1 — scheduled-wakeup logic in `iq_int`, param-gated DEAD** *(this turn)*
Add `param SCHED_WAKEUP: bit = 0`. When 0, byte-identical (no new behavior). The
block (in the `always_ff` else-branch, alongside the CDB snoop) wakes
`pipe1_ok`-class consumers + sets `prf_ready` on `has_issuable && i_issue_ack`,
keyed on `sh_rd_pdst[issue_idx]`. Gate: build byte-identical + default 251/0 +
N1 boot cy unchanged. (Live correctness validated at I3, where the FR makes the
timing right; enabling SCHED_WAKEUP alone — without the FR — is wrong by design and
must stay off.)

**I2 — front register infrastructure in the core, gated OFF (`FRONT_PIPE=0` →
pass-through wire, byte-identical).** Route the execute datapath's `iq_iss_*` /
`iq_issue_*` reads through a new `fr_*` bundle = `FRONT_PIPE ? fr_*_q : iq_iss_*`.
With FRONT_PIPE=0 this is a pure wire ⇒ byte-identical build. This is the bulky
mechanical rewiring, done in a SAFE (byte-identical) step. Gate: byte-identical +
default 251/0 + N1 boot cy. (Big diff; consider doing the memory side — LR/SC,
store buffer, dc_amo_read, replay — in its own sub-commit from the ALU/csr side.)

**I3 — flip ON: `FRONT_PIPE=1` + `SCHED_WAKEUP=1`.** The real timing change. Debug
through the FULL gate ladder. Re-synth to confirm the select cone split and the new
~17-18 ns headline. Expect iterations on memory-ordering corners (the +1 shift
interacts with replay / store-to-load forward / LR-SC / xlate-barrier timing).

**I4 — second register / commit-cluster freeing.** Once the back half is the wall,
add the next split (post-MMU, or Direction-C port separation for the commit cluster).

### Gate ladder (every flip-on / behavioral step — memory ordering is not separable)
default `veryl test` 251/0 + `--backend-validate` + N1 boot cy + litmus N2/N4 +
N2/N4 SMP boot + Verilator SMP. Fast sub-gate for no-behavioral-change steps:
default + N1 boot cy + litmus N2. (Per `feedback_regression_cadence`: N4 SMP only at
milestones.) The +1-cycle-commit failure (strategy §3.D) is the cautionary tale —
SMP atomicity breaks silently on single-hart tests; only litmus/SMP catches it.

### Known blocker (final validation only)
Verilator is blocked by a pre-existing veryl SV-emission bug: `heliodor_fpu_pkg::
__clz__16` from `mmu.veryl`'s `clz::<16>` is not monomorphized into `fpu_pkg.sv`.
Unrelated to this work; fix in the veryl clone before the Verilator gate at I3.

---

## 3. Exact signals (insertion map)

- **Issue-select / grant** (`iq_int.veryl`): `issue_idx` (314), `has_issuable`
  (313), `i_issue_ack` (← `iq_issue_ack`, core 2498). Grant = `has_issuable &&
  i_issue_ack`. Fixed-latency = `pipe1_ok` (358). Producer pdst =
  `sh_rd_pdst[issue_idx]`, has_rd via `ops[issue_idx].base.has_rd`.
- **CDB snoop to mirror** (`iq_int.veryl:457-490`): sets `prf_ready[pdst]=1` and
  `rs1_rdy/rs2_rdy[i]` for matching occupied entries (respect `sh_rs2_is_fp`).
- **FR contents** (core): the `iq_iss_*` set feeding execute — `iq_issue_op`,
  `iq_iss_{rs1,rs2,rd,rd_old}_pdst`, `iq_iss_rob_idx`, `iq_iss_is_{load,amo,csr}`,
  `iq_iss_amo_funct5`, `iq_iss_is_cas_q`, `iq_iss_csr_*`, `iq_iss_rs1_arch`,
  `iq_iss_fp_{ld,st}`. Model on the LSR latch (`heliodor_core.veryl:6700-6715`).
- **Execute consumers to re-point**: `u_alu` (2240), `u_int_div` (2341),
  AGU `agu_addr_iss` (~1474/4376), `u_dmem_mmu` (6106), `u_dcache` (6374), the
  LR/SC reservation block (4748+), `store_drive`/`dc_amo_read` (5298/5380), CSR read,
  ROB writeback. The LSR (load) path already reads `iq_iss_*` at `lsr_capture` — with
  the FR it captures one cycle later; the existing LSR becomes the SECOND stage.
- **prf seeding** (`iq_int` alloc, 540-550 / 583-596): a consumer renamed the cycle
  after a scheduled grant must see `prf_ready[pdst]=1` — I1 sets it at grant, so this
  already works; no change to the alloc-seed expressions.
