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

### 1.2 Target — one front register INSIDE `iq_int` (register the o_issue_* outputs)
Insert the **front register (FR) inside `iq_int`**, registering the `o_issue_*`
outputs: the select cone (`rob_head → blk_cand → iss0 argmin → issue_idx`) ends at
the FR in cycle N; the registered bundle drives `o_issue_*` in cycle N+1, so the
core's regread→AGU→MMU→dcache→commit starts from the registered output next cycle.

This is **far better than rewiring the 183 core `iq_iss_*` sites** (the first draft
of this plan): it is LOCALIZED to `iq_int`, the core execute datapath is UNTOUCHED,
and `FRONT_PIPE=0` folds to today's behavior with **no completeness risk** (nothing
in the core to "miss" — a missed core site would pass byte-identical at FRONT_PIPE=0
yet break at flip-on, which the localized approach avoids entirely).

- **ALU op**: cycle N — select picks, captures into FR (select cone alone). Cycle
  N+1 — FR presents `o_issue_*` → core regread/`u_alu` → `o_cdb` broadcast.
- **Plain load**: cycle N — select → FR. Cycle N+1 — FR presents → AGU+translate
  (old LSR Stage A) → LSR. Cycle N+2 — dcache (old Stage B) → wb. (Load-use 2→**3**.)

**Register the whole `RenamedOp` struct + valid per slot** (`fr0_op_q`/`fr0_valid_q`,
`fr1_op_q`/`fr1_valid_q`), NOT 26 per-field regs: capturing `ops[issue_idx]` (a
whole-struct dynamic read, already safe — `o_issue_op` does it) into a non-array reg
makes every `o_issue_<field>` a STATIC field read of `fr_op_q` (safe; the shadow
arrays only worked around the *dynamic*-index struct-field-read bug). Per-field
output = `FRONT_PIPE ? fr_op_q.<field> : sh_<field>[issue_idx]`.

**The FR must be UNIFORM across BOTH issue slots.** A slot-0-only FR is INCORRECT:
a slot-0-FR'd producer (result in PRF at N+2) feeding a slot-1 single-cycle consumer
(reads PRF at N+1) would read one cycle early. With both slots FR'd, every consumer
reads at select+1 and scheduled wakeup (wake at grant) is uniformly correct (§1.4).

The FR is a 1-deep stall-capable handshake register per slot: capture when the slot
selects AND the FR is empty-or-draining (`!fr_valid_q || i_issue_ack`); free the IQ
slot on capture (not on the core ack); drain on the core ack; clear on flush /
younger-than-branch partial squash. (Slot-1 can also stall — `issue2_fire` gates on
slot-1 load completion + `lsr_lane1_fire`, core 6516 — so both slots are symmetric.)

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

**I2 — front register INSIDE `iq_int`, gated OFF (`FRONT_PIPE=0` → today's combo
pass-through, cycle-exact).** Register the `o_issue_*` outputs (whole-`RenamedOp`
struct + valid per slot, both slots — §1.2). `o_issue_* = FRONT_PIPE ? fr_op_q.* :
sh_*[issue_idx]`; `o_issue_valid = FRONT_PIPE ? fr_valid_q : has_issuable`. Re-key
the IQ-slot free + the I1 scheduled wakeup to `slot_grant = FRONT_PIPE ? fr_capture
: (has_issuable && i_issue_ack)` (folds to today at FRONT_PIPE=0). Core UNTOUCHED.
Gate: default 251/0 + N1 boot cy unchanged + synth CP 25.105 unchanged (dead).

**I3 — flip ON: `FRONT_PIPE=1` + `SCHED_WAKEUP=1`.** The real timing change.

**I3 MEASUREMENT (2026-06-27, flip not committed — see the correctness gap below).**
Synth with both params on: **CP 25.105 → 23.580 ns**, and the endpoint MOVED from
`u_fl.n_inflight[5]` (the issue→commit megacone) to `u_vu.u_vfpu.u_fround_d_add`
(`s1_exp_sel/s1_sum_sel → fr_d_sum_q[51]`) — the **vector FP FROUND adder**. So the
front register DID cut the issue→commit megacone off the top; it fell BELOW 23.58
(by the Direction-C residual reasoning — that experiment bottomed the load
issue→execute path at 23.8 *with* the select cone in series; removing the ~7 ns
select cone puts the megacone at ~16-18). The headline only moved −6 % because the
**vector FROUND front (23.58)** sits right under it — a separate, crushable cone.
**Implication: the FR's real benefit (megacone 25→~18) is MASKED until the FP front
+ the 18-23 band are also crushed.** Multi-front, exactly as the program expects.

**CORRECTNESS GAP found at I3 (the "no replay" assumption is FALSE for slot-0).**
Plan §1.4 requires a scheduled-wakeup producer to traverse the FR in exactly 1
non-stalling cycle. **Slot-0 ALU ops CAN stall in the FR**: `iq_issue_ack` (core
2498) deasserts on `fpu_cdb.valid` / `mshr_cdb.valid` / `dmem_mmu_busy` (lane-0
yields to FP/MSHR completions and MMU walks). When a scheduled-woken ALU producer
stalls, its result lands late and the consumer — selected 1-cycle-behind on the
schedule — reads PRF STALE. (Slot-1/pipe-1 ALU never stalls, so only slot-0 is
affected, but slot-0 is the common path.) This needs one of:
- **(fix A) FR-drain readiness gate** — make the FR a 1-entry reservation station:
  add a `prf_done` bitmap set ONLY at the real CDB broadcast (not at the scheduled
  grant), and gate each FR's drain/present on `(!has_rs1||prf_done[rs1])&&(!has_rs2
  ||prf_done[rs2])` (+ the FP-store rs2 / load / AMO source variants). Scheduled
  wakeup still selects the consumer early (into the FR); the FR holds it until its
  sources REALLY landed, then presents — no stale read, no squash, no replay. In the
  no-stall common case `prf_done` is set exactly when the consumer reaches the FR, so
  it drains immediately (1/cycle preserved). This is the right fix; it is the bulk of
  the remaining work.
- (fix B) replay/cancel — the machinery the program set out to avoid. Not preferred.

**Sequencing decision (user chose "crush FP front first").** The FP front turned
out NOT to be a cheap tree-ize: the 23.58 ns cone is the VU COMPUTE present-phase
running the VRF operand fetch (~10.5 ns) AND u_vfpu stage-1 (~13 ns) in ONE comb
cycle; the element-selects/forwarding are already barrel shifts (no linear scan
left). The cut is **VU FP operand pipelining** — see VFP_PIPE below.

**VFP_PIPE (vector_unit, `a6cead6`, built dead).** Insert a FETCH phase that
registers the u_vfpu operands (`fp_s1/2/3_q`, `fp_int_rs1_q`) before present, via a
separate `fp_fetched_q` flag (not a widened `fp_ph`) so VFP_PIPE=0 is cycle-exact.
Cost when on: +1 cycle/FP element (3 phases vs 2 — vector FP only, rare in the gate
workloads). **Convergence measured (all 3 params temp-on, synth):**

```
baseline 25.105  →  FRONT_PIPE only 23.580  →  FRONT_PIPE + VFP_PIPE 20.395 ns   (−18.7%)
```

VFP_PIPE crushes the vector FROUND cone below 20.4; the FR-isolated commit/load
megacone (`n_inflight`: head → prf → MMU-TLB → … → n_inflight) is the new floor at
**20.4 ns**, confirming the ~18-20 estimate. **The campaign converges.**

**State now:** three dead/parked params — `SCHED_WAKEUP` (I1), `FRONT_PIPE` (I2),
`VFP_PIPE` — all cycle-exact at default 0. The committed CP is still 25.105.

**FR fix A — DONE (`a0f79a4`, built dead).** `prf_done` bitmap (set only at the real
CDB broadcast, cleared at rename, NOT at the scheduled grant) gates the FR present
(`o_issue_valid{,2}`) on the FR'd op's int sources being prf_done. Speculative
SELECTION (scheduled wakeup, 1/cycle), confirmed EXECUTE (waits for the real
producer) — no stale read, no replay. Cycle-exact at FRONT_PIPE=0 (251/0).

**FLIP STATUS (temp FRONT_PIPE=1 + SCHED_WAKEUP=1, NOT committed): 221 pass / 30
fail.** Fix A works (not stale reads). SCHED_WAKEUP=0 gives 61/190 (mostly TIMEOUTS —
without scheduled wakeup the FR halves dependent-ALU throughput → confirms scheduled
wakeup works).

**ROOT CAUSE LOCALIZED (bltu deadlock trace).** Bisection: FRONT_PIPE=1 +
SCHED_WAKEUP=1 + **`s8e_flip_en=0` (early redirect OFF) → 247/4**. So the
**early-redirect (s8.E execute-time branch redirect) + FR interaction causes 26 of
the 30 failures.** Traced bltu (deadlocks ~cy197, ROB full):
- The ROB head is a **CSR write to mstatus (0x300), `rob_commit_valid=0` (never
  marked DONE), but NOT in the IQ and NOT in the FR — it VANISHED.** It left the IQ
  but never executed and never re-issued, so the head can't commit; the in-flight
  mstatus write keeps the xlate barrier high and downstream CSR ops (blocked
  `!at_head`) pile up → ROB fills → deadlock. The vanish happens during the
  early-redirect burst (cy 138-196).
- **Leading hypothesis (VERIFY next):** the FR frees the IQ slot at CAPTURE (before
  execute, via `slot_grant`), so there is a window where an op lives only in the FR.
  If the early-redirect recovery drops/diverts it (or the ROB-pointer recovery is
  inconsistent with the FR's extra stage) before it executes, the ROB entry is
  orphaned with no IQ/FR copy to complete it. (Note: a pure younger-than-branch
  squash should drop FR + ROB consistently — so the bug is more likely a head/at_head
  or recovery-ordering edge specific to the early redirect, not the plain squash.)

**Next: fix the early-redirect + FR orphan (the 26-failure dominant bug).** Options
to investigate: keep the IQ slot occupied until the op DRAINS (executes) so a dropped
FR op re-issues; or make the early-redirect ROB recovery account for the in-FR op; or
re-insert a squash-dropped FR op. Then the remaining 4 non-early-redirect corners
(amo/LR-SC, misalign, csr, fcvt — surfaced with early redirect off). Multi-session.

**Remaining to realize the 20.4 floor:**
1. ~~FR fix A~~ DONE. The +1-shift core corners (30 fails) are now the work.
2. The eventual flip enables all three params together + the full gate ladder.
3. **Next front after 20.4** = the `n_inflight` commit/load megacone back-half
   (head → prf → AGU → MMU → dcache → commit). That is the load-2-stage LSU / the
   Direction-C commit-port separation territory — another pipeline, another IPC step.

Re-confirm at the eventual flip: full gate ladder + re-synth.

---

## CAMPAIGN CONVERGED — all 3 params FLIPPED ON, committed (CP 25.105 → 20.395 ns, −18.7%)

The 30-fail flip is RESOLVED. The 30 were three distinct +1-shift corners, all
genuine consequences of the FR freeing the IQ slot at capture / the FR's extra
stage, all now fixed. SCHED_WAKEUP, FRONT_PIPE, VFP_PIPE are now default 1.

**Corner 1 — FR squash NBA hazard (early-redirect, 26/30).** The leading
hypothesis above was right in spirit (op orphaned, lives only in the FR) but the
mechanism is an **NBA read-old-write-new** in the squash, not a recovery-ordering
edge. capture/drain/squash were NOT mutually exclusive: in an `always_ff`, the
squash's `if i_squash_en && fr0_valid_q { … fr0_op_q.rob_idx … }` reads the
PRE-edge fr0_op_q (NBA), so on a refill cycle (capture + drain of the OLD
occupant) where the old occupant is younger-than-branch, the squash decided
"drop" from the OLD op's age and ran `fr0_valid_q <= 0` AFTER the capture's
`<= 1` → the just-captured op (a CSR at the ROB head in the bltu trace) got
valid=0 while already freed from the IQ → orphan → head can't commit → deadlock.
Fix: one mutually-exclusive if/else-if — capture decides validity from the
CAPTURED op's age, hold decides from the held op's age. (`iq_int.veryl`.)

**Corner 2 — slot-1 loads + FR deadlock (ma_data, litmus N=2).** Tier-L
(slot-1/pipe-1 LOADS, S5.2) complete only on a same-cycle dcache hit; on a miss
the baseline holds them in the IQ and re-issues. The FR frees the IQ slot at
capture, so a missed load captured into fr1 has no retry path — it can become the
ROB head while stuck in fr1 (which has no MSHR) → deadlock. Loads are also
variable-latency, outside the scheduled-wakeup fixed-latency set. Fix: disable
Tier-L under FRONT_PIPE; all loads take slot-0 (the LSR 2-stage + MSHR). fr1 then
only ever holds pipe1_ok ALU ops. (`iq_int.veryl`.)

**Corner 3 — FP div/sqrt owner-exact broadcast (rv64uf-fdiv subtest 6).** A
wrong-path long-latency div/sqrt started the fpu_wrap FSM (owner_q = its
rob_idx). The EARLY redirect squashed it but does NOT assert `i_flush` (i_flush =
commit redirect only), so the FSM kept running and latched `done_q` with the
STALE owner. The broadcast gated on bare `done_q` (`ds_done`) then fired the
stale result tagged with the CURRENT iq_fp head's rob_idx (≠ owner), writing a
wrong-path fsqrt's NV flag into that entry's ROB slot → leaked into the committed
fcsr → subtest 6's `bne a1,a2` (fflags==0 check) failed. Found via SCHED_WAKEUP=0
bisection (passes) → inner-FSM `$display` (owner=27 while head=8). Fix: gate
`ds_done` on `done_for_me` (owner == head). Normal path owner==head ⇒ unchanged.
(`fpu_wrap.veryl`.)

**Bonus — iq_fp int-source seed uses prf_DONE not prf_ready.** Scheduled wakeup
sets prf_ready a cycle early to hide the FR depth for FR-delayed INT consumers;
iq_fp has no FR, so it must seed int-source readiness from the real-broadcast
prf_done (else an int→fp op renamed in the early window reads a stale int
operand). SCHED_WAKEUP=0 ⇒ prf_done == prf_ready ⇒ byte-identical. (`iq_int.veryl`.)

**Gate ladder (all 3 params on): GREEN.** default 251/0 · backend-validate (cc vs
cranelift) 251/0 · N1 boot 4/4 (incl 7.1 V-boot) · litmus N=4 pass (5.42M, no
forbidden outcome) · N=2 SMP boot pass (16.5M) · N=4 SMP boot pass · synth
**20.395 ns / 206 levels / endpoint head[0]→n_inflight[5]**.

**IPC cost (net vs the −18.7% CP, per the committed program).** microbench smoke
~11.47M → 11.94M (+4%; load-use +1, mispredict +1). N=2 SMP ~15.87M → 16.5M
(+4%). V-boot cy unchanged (vector FP rare in boot, so VFP_PIPE's +1/element is
invisible there).

**Next front after 20.4 = the n_inflight commit/load megacone back-half**
(head → prf → AGU → MMU → dcache → commit). Now the synth endpoint. Future work:
load-2-stage LSU back half / Direction-C-style commit-port separation — another
pipeline + IPC step.

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
