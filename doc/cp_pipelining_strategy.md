# Critical-Path Reduction Strategy — Deep Pipelining (IPC tradeoffs accepted)

Planning doc seeded 2026-06-26 for a fresh strategic session. The user has decided
to **allow large-scale structural changes and accept IPC tradeoffs** to push the
critical path (CP) below the current ~25 ns floor. This doc frames the design space
and the established facts so the next session can decide a direction, not re-derive
them. Companion: `doc/lsu_pipeline_plan.md` (§11), memory
`project_heliodor_lsu_pipelining` + `project_heliodor_long_comb_path_reduction`.

---

## 0. Where we are (why no-IPC work is exhausted)

The no-IPC-cost CP campaign took `veryl synth` CP **104 → 25.5 ns** (LZC tree-ize,
FROUND/PMP/MMU-TLB/hpm/`vmspre` retimings, all bit-exact). That well is **dry**.

This session proved the remaining ~25 ns is **not** removable without IPC cost:
- The wall is a **multi-front plateau**: `n_inflight` 25.1 / `redirect_pc_q` 24.6 /
  `mip` / `mhpm*` — the whole **commit cluster** — all sit within ~0.5 ns.
- They are fed by one **shared front** (below). Cutting one cone is whack-a-mole.
- The decisive experiment: making the slow-store commit-drain stall **fully clean**
  (registered state only, no load contamination) dropped CP **25.105 → 24.775 ns
  (−1.3 %)**. So the store-drain stall is *not* the bottleneck — the commit cluster
  is fed by the shared front through **several** exclusivity-masked inputs
  (store-drain stall, **SB ordering** `sb_st_ovl/sb_merge_ok` via `sb_match`←dcache
  fill, `dmem_mmu_busy`). Cleaning one shifts the path to the next.
- A registered (+1-cycle) commit drain **breaks SMP AMO atomicity** (litmus N=2
  barrier `amoadd` lost-update → wedge); verified this session.

**Conclusion: the ~25 ns CP is the cost of "the shared front reaching the commit
cluster." No-IPC cleaning cannot remove it. Only pipelining can.**

---

## 1. The ~25 ns critical path (grounded, `veryl synth`)

One long combinational chain from the ROB head pointer to the commit-cluster FFs:

```
head[FF Q]
  → ROB block-store argmin   u_rob.blk_cand        ~0.0→3.5 ns
  → IQ oldest-ready select   u_iq.iss0_a3          ~3.5→6.3 ns
  → PRF read                 u_prf.prf             ~6.3→9.0 ns
  → AGU (rs1+imm)            agu_addr_iss          ~9.0→9.9 ns
  → MMU TLB translate        u_dmem_mmu...pa       ~9.9→14  ns
  → PMP                      u_pmp_amo_w           ~14 →15.6 ns
  → dcache tag + RAM         u_dcache.hit_*/RAM    ~15.6→21 ns
  → commit cluster           rob_commit_ack →      ~21 →25.1 ns
                             n_inflight / redirect / mip / mhpm
```

`~16.5 ns` front (head→dcache) + `~4–9 ns` cone tails. **Every** endpoint (load
data `sh_load_poison`, free-list `n_inflight`, branch `redirect_pc_q`, CSR `mip`,
hpm) rides this front. The front is shared by ALU, load, branch, and commit.

---

## 2. The load-bearing constraint: single-cycle issue=execute=broadcast

- **ALU executes and broadcasts in the issue cycle** — `alu_wrap` has *zero*
  `always_ff`; `o_cdb.valid = i_issue_valid`.
- **Wakeup is broadcast-based, NOT latency-scheduled** — `iq_int` snoops the live
  CDB and sets `rs*_rdy` combinationally (`iq_int.veryl:457`). There is no
  `LOAD_LATENCY` table; a consumer issues the cycle after the actual broadcast.

This is the **key enabler** (mixed FU latencies "just work"; the MSHR late-fill and
the LSU 2-stage split need no scheduling) **and the key constraint**: *any* register
placed in the issue→execute→broadcast path delays the broadcast by 1 cycle, and
because wakeup keys off the broadcast, **every dependent edge gains +1 cycle** →
dependent ALU chains run at **½ throughput** — unless wakeup is rebuilt to be
latency-speculative. (This is exactly why the handoff §11 "shared-front register"
cut #3 is poisonous as-is, and why the LSU 2-stage split was net-negative.)

---

## 3. Strategic directions (all accept structural change / IPC cost)

### A. Latency-speculative wakeup + pipelined execute  ← canonical deep-OoO; recommended
Rebuild `iq_int` scheduling: wake a consumer at the **producer's grant (select)**
using the producer's **known FU latency**, so the consumer is selected to arrive at
execute exactly when the bypass is ready. Requires:
- a **bypass network** spanning the new execute register,
- **replay / cancel** on mis-speculation — a load that misses (variable latency)
  must squash the speculatively-woken dependents and re-wake them on the real fill.
  (This is the machinery heliodor deliberately AVOIDS today via broadcast wakeup.)

Then registers can split `select | regread | AGU/translate | dcache | writeback`.
The IPC-preserving floor becomes the **select→wakeup→select loop** (blk_cand argmin
+ issue-select, ~6–8 ns) → CP target **~8 ns (≈3×)**.
- **IPC cost**: small if speculation is right — dependent ALU stays 1/cycle;
  load-use +1–2; the only real loss is mis-speculation replays (load misses) and
  the deeper mispredict/flush penalty.
- **Effort / risk**: MAJOR. New replay path + full SMP re-validation (litmus N4,
  N2/N4 SMP boot, Verilator) at each stage. Multi-session.
- **This is the only direction that meaningfully cuts CP without large IPC loss.**

### B. Pipeline the front, keep broadcast wakeup (accept the IPC hit)
Register `select | execute` with no scheduler change. Simple, but dependent ALU
chains halve (~30–50 % IPC loss on ALU-bound code). The step-1.5 LSU experiment
showed even a **load-only** +1 cycle was net-negative; an ALU-wide +1 is far worse.
**Not recommended** — almost certainly net-negative throughput.

### C. Physical dmem-port separation (load vs store-commit)   ← complementary partial win
Give the store-commit / SB-drain path its own translate + tag (a duplicate MMU-lite
+ dcache-tag read), so the **commit cluster stops reading the load's shared front**.
Cuts the `n_inflight / redirect / mip / mhpm` coupling to the load (the actual top
cones). The load datapath (`sh_load_poison`) and the head→issue-select front (shared
by ALU/load) remain. **Area cost**, lower risk than A, doesn't need wakeup changes.
Pairs well with A (A cuts the front; C frees the commit cluster).

### D. Pipeline only the commit cluster (front→commit register)
Register `rob_commit_ack → cluster`. **Tried this session → broke SMP AMO atomicity**
(the commit point must be atomic with the in-cache AMO write; a +1-cycle slip lets a
remote hit interleave). Salvageable only for the *non-atomic* commit path with
precise-exception/recovery re-engineering, and even then the ~21 ns front to the
commit decision remains. Low value alone.

---

## 4. Recommendation to seed the discussion

Commit to **Direction A** (latency-speculative wakeup) as the backbone — it is the
standard way to deepen an OoO pipeline and the only path to a real halving without
gutting IPC. Sequence it incrementally with the existing assets:
1. Build speculative wakeup + replay for a **single** new register (`select|regread`),
   keep everything else single-cycle, validate the full SMP/litmus matrix.
2. Add the **AGU/translate | dcache** split — reuse the **step-1 LSU 2-stage** work
   on branch `lsu-phase1-wip` (it is a working, tested 2-stage load; extend, don't
   rebuild).
3. Layer **Direction C** (dmem-port separation) to free the commit cluster.
4. Re-baseline IPC (boot cycles, CoreMark/Dhrystone) at each step; the trade is
   "a few-% to ~10–15 % IPC for ~3× CP" — decide the acceptable IPC budget up front.

**Hard gates at every step** (memory-ordering is not separable): default `veryl test`
251/0 + `--backend-validate` + N1 boot cy + litmus N2/N4 + N2/N4 SMP boot + Verilator
SMP. The +1-cycle-commit failure this session is the cautionary tale: SMP atomicity
breaks silently on single-hart tests and only litmus/SMP catches it.

---

## 5. Open questions for the strategic session
- IPC budget: what boot-cycle / CoreMark regression is acceptable for a ~3× CP?
- Scope of the wakeup rebuild: full latency-speculative scheduler, or a narrower
  "1-deep speculative" that only covers the new register?
- Is `veryl synth`'s CP the right target at all, or should a real STA flow with
  false-path constraints set the goal? (This session showed `veryl synth` cannot
  see the exclusivity-masked false paths — a real flow would report a lower CP for
  the *current* design, changing the baseline the pipelining is measured against.)
- Do we keep the `lsu-phase1-wip` 2-stage load as the seed (yes — it works), and
  fold the new front stages around it?

---

## 6. COMMITTED PROGRAM (2026-06-27) — deep pipeline, accept net-IPC, no retreat

User directive (verbatim intent): *we must do the structural change that ultimately
LARGELY reduces CP; intermediate steps with NO CP gain are expected and accepted
(the multi-front wall only drops once EVERY front is crushed); IPC loss is judged
NET against CP reduction — refusing IPC loss in isolation means doing nothing.* This
supersedes the timid "no-IPC micro-fix → no CP gain → retreat" loop of prior
sessions. The program below is committed; we persist through no-gain intermediates.

### Key technical refinement — scheduled wakeup WITHOUT replay
The §A concern ("front register needs replay/cancel for load-miss mis-speculation")
is AVOIDABLE. Split wakeup by FU latency class:
- **Fixed-latency FUs (ALU, etc.) → issue-grant SCHEDULED wakeup.** When the
  producer is GRANTED (selected) at cycle N, set its consumers' `rs*_rdy` for
  selection at N+1 (not at the broadcast). With a front register the producer's
  result is bypassable when the consumer reaches execute, so dependent ALU chains
  stay 1/cycle. Deterministic latency ⇒ never mis-schedules ⇒ **no replay**.
- **Variable-latency FUs (loads) → keep the existing CDB-broadcast snoop**
  (`iq_int.veryl:457-490`). Load consumers wake on the REAL broadcast (load-use
  latency, no speculation) ⇒ nothing to squash ⇒ **no replay**.
This removes the riskiest machinery. Needs: (1) the front pipeline register,
(2) issue-grant scheduled wakeup for fixed-latency producers in `iq_int`,
(3) a bypass network spanning the register. The `prf_ready` bitmap must also reflect
scheduled (granted-but-not-broadcast) producers so newly-allocated consumers seed
correctly.

### Sequencing — on branch `lsu-phase1-wip` (the load is already 2-staged here, so
each front cut MOVES the headline; on master the load masks everything).
Risk-ascending:
1. **load-split** — DONE (`2e93dc4`/`58e8b42`). load-use +1.
2. ~~Direction C — store-commit / dmem-port separation~~ — **ABANDONED 2026-06-27
   (commit `af1dcd4`).** Implemented + fully validated three variants (drain-ack:
   CP +1.4 ns regression; pin-active gate: SMP livelock; amo_owned_q gate: correct,
   all atomicity green, but +0.25 ns CP / +1.8 % N4 IPC). DECISIVE synth experiment:
   forcing the WHOLE commit cone off the dcache (slow `dcache_stall` AND fast
   `sb_merge_ok`) drops CP only 25.1 → 23.8 (−1.3 ns), residual = the load's own
   issue→execute datapath. So commit-side decoupling is capped at ≤1.3 ns —
   `dcache_stall` was never the bottleneck. See `cp_direction_c_port_separation_plan.md`
   §7-8 + patches `cp_c1_amo_drain_routing.patch` / `cp_amo_owned_step.patch`. SKIP.
3. **scheduled-wakeup FRONT pipeline** ← **IN PROGRESS (the big lever).** Register
   `select | regread/AGU` (`iq_int` output → execute), issue-grant scheduled wakeup
   for fixed-latency FUs (ALU), keep CDB-broadcast for loads. Cuts the ~9.7 ns shared
   front of ALL cones (the issue-select → MMU → dcache megacone is the real wall —
   §7.1 of the Direction C doc segments it: issue-select 7.3 + MMU/PMP 6.5 + dcache
   4.6, all already tree-optimized). IPC: issue +1 absorbed by scheduling; load-use
   +1. This is the ONLY path below ~24 ns. **Concrete RTL plan + staged increments
   (I1-I4): `cp_front_pipeline_plan.md`. NO operand bypass is needed — the scheduled
   wakeup sets `ready` exactly one cycle before the result lands and the FR delays the
   consumer's PRF read by exactly one cycle; they cancel (plan §1.4 proof).**
   - **I1 DONE (`caf8d89`):** grant-time scheduled wakeup in `iq_int`, param-gated
     DEAD (`SCHED_WAKEUP=0`, cycle-exact; synth CP 25.105/n_inflight[5] unchanged).
   - **I2 DONE (`243e3bb`):** front register INSIDE `iq_int` (register the
     `o_issue_*` outputs; whole-`RenamedOp` reg + valid per slot, both slots),
     gated DEAD (`FRONT_PIPE=0` → live combinational select = today). Core execute
     datapath UNTOUCHED — far better than the 183-site core rewire (no completeness
     risk). Cycle-exact: default 251/0, N1 boot cy identical, synth CP 25.105 unch.
   - **I3 NEXT:** flip ON (`FRONT_PIPE=1` + `SCHED_WAKEUP=1`), full gate ladder,
     re-synth (expect the select cone to split, new headline ~17-18 ns). Debug the
     +1-shift memory-ordering corners (replay / store-to-load fwd / LR-SC / xlate).
4. branch redirect / VU / further front splits.

Gates at every step: default 251/0 + `--backend-validate` + N1 boot cy + litmus
N2/N4 + N2/N4 SMP + Verilator SMP. (Verilator is currently blocked by a pre-existing
veryl SV-emission bug — `heliodor_fpu_pkg::__clz__16` from mmu.veryl's `clz::<16>` is
not monomorphized into fpu_pkg.sv; unrelated to this work, fix in the veryl clone.)

### START HERE (next session) — scheduled-wakeup front pipeline
1. Read §2 (the single-cycle issue=execute=broadcast constraint) + §3.A + the
   "scheduled wakeup WITHOUT replay" refinement above — that is the design.
2. Grep `iq_int.veryl:457-490` (the broadcast wakeup) and the issue-select / grant
   logic; identify where to insert the front register (`iq_int` issue output →
   AGU/regread → execute) and where the bypass must span it.
3. Decide the IPC budget FIRST (acceptable boot-cy / CoreMark regression) — the front
   register adds +1 to every dependency edge UNLESS scheduled wakeup keeps fixed-
   latency ALU chains 1/cycle. Getting the scheduled wakeup + bypass right is the
   whole game; a naive front register without it ≈ halves dependent-ALU IPC.
4. Re-synth after the register lands to confirm the ~9.7 ns front actually splits and
   the new headline is the back half (~13-16 ns), then run the full gate ladder.
