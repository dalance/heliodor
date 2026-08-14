# Phase 14 — Front-end + LSQ structural completion (real deep-OoO)

Master plan (2026-07-24). **Goal: structural completeness, not CP.** After the
deep-pipeline campaign resolved that the real synth CP floor is the vector
execute→writeback datapath (`deep_pipeline_status_and_replan.md §8.2`, the retire
`n_inflight` headline was a FALSE PATH), further FF-insertion buys no CP. Phase 14
instead advances heliodor toward the structures a real multi-GHz OoO core has but
heliodor still **fuses into a single cycle** or **simplifies**:

- a true **decoupled front end** (predictor SRAM + overriding predictor + fetch
  target queue) instead of a combinational fetch loop with an FTB prefetch hint,
- a **pipelined scheduler** (select + speculative wakeup) instead of single-cycle
  select+wakeup,
- a **canonical LSQ** (store queue + translate-at-execute + a first-class load
  queue + queue-ordered atomics) instead of a committed-store buffer +
  commit-time-replay disambiguation.

User decision (2026-07-24): direction **A (structural completeness)**, scope
**front-end structure in full** — i.e. the whole 4-block program below.

This is a large, multi-session program. Methodology is the campaign's proven one:
every stage is a **DEAD param scaffold** (`=0` cycle-exact byte-identical, `=1`
inserts the register/stage), verified byte-identical at 0, then measured for
IPC/CP before any flip. Regression gate: `veryl test` (unit + arch suites) →
`veryl test --ignored --test test_litmus_4hart` → SMP boot N2/N4. CP via
`veryl synth` (sky130 default / asap7).

---

## Block F — Front-end array realism + decoupled fetch (the Phase-14 centre)

### F1 — Predictor-array SRAM migration (BTB / BHT / TAGE / iBTB → 1R1W clocked)

**Structural gap.** Phase 13 migrated every *cache* array to 1R1W clocked SRAM,
but the branch-predictor arrays are still flops read **combinationally in F0**:
BTB (4096 × ~60b ≈ 30 KB), BHT/gshare (8192 × 2b), TAGE-lite tables (several KB),
indirect-target BTB (512 × ~50b). ~35–40 KB of storage in flops — L1-way-sized —
the single largest remaining array-realism outlier. (RAS and the small
fully-assoc TLB/MSHR-class arrays are correctly **below the SRAM floor**; leave
them flop — not a gap.)

**What a real core does.** These arrays are SRAM macros with a **clocked
(registered-address)** read. A clocked predictor read cannot steer fetch in the
same cycle, so it forces an **overriding / ahead-pipelined predictor**: BTB read
in F0 → target used in F1, with a next-line / BTB1 fast path covering the bubble
and the F1 override correcting it. This is exactly the restructuring the icache
sync-read required — SRAM ⊂ pipeline deepening.

**Scaffold.** Add a `PRED_SYNC_READ` (or per-array) DEAD param, mirror the icache
1R1W byte-write pattern for each array, and add the F0→F1 override datapath. `=0`
keeps today's combinational F0 predict byte-identical; `=1` clocks the read and
enables the override. Measure the IPC cost (extra redirect bubble), budget it like
the icache's ~+8 %.

**Effort:** medium–large. The array flip is small; the override restructuring +
FTB/prefetcher reconciliation is the real work. **Independent of Block L.**

### F2 — True decoupled fetch (Fetch Target Queue)

**Structural gap.** Today's fetch is a combinational fetch FSM that reads the
icache and does predict/redirect in one tight loop; the shipped FTB
(`cp_icache_fetch_decouple_plan.md`, shape-W `7127cb9`) is a *directed-prefetch
hint* one step ahead — **not** a first-class FTQ.

**What a real core does** (Reinman/Calder/Austin decoupled front-end): the
predictor pipeline **enqueues fetch-block descriptors** into an FTQ; the fetch
engine dequeues them asynchronously. The predictor runs many blocks ahead, fully
hiding icache latency and driving run-ahead instruction prefetch.

**Prereq:** F1's overriding predictor (the predictor must produce fetch targets a
stage ahead to fill the FTQ). Build the FTQ, move prediction fully into the
enqueue side, make the fetch engine an FTQ consumer.

**Effort:** large. **Independent of Block L.**

---

## Block S — Pipelined scheduler (select + speculative wakeup)

**Structural gap.** The integer IQ does select → broadcast-wakeup → next-cycle
select as **one combinational path** today. `SEL_PIPE` (`iq_int.veryl:266`) and
`SPEC_WAKE` (`iq_int.veryl:297`) are built but DEAD; A-SCHED already measured the
pipelined select shortening the IS loop 12.92→9.52 ns (sky130).

**What a real core does.** Pipeline select, and add **speculative wakeup** — wake
dependents one cycle before the producer result is known so back-to-back dependent
ALU ops still issue in consecutive cycles under a pipelined select. The **EX_PIPE
keystone** (`heliodor_core.veryl:1523`, registered RR│EX│WB) is the matching
execute-side stage but costs −15 % IPC alone; recovering it needs a **bypass /
forwarding network** so pipelined-execute results reach waiting consumers without
a stall. Scheduler-pipelining and EX_PIPE+bypass are one coordinated sub-effort.

**S1 = SEL_PIPE + SPEC_WAKE enable/validate + EX_PIPE bypass network.**
`LOAD_SPEC` (`iq_int.veryl:312`, speculative load-hit wakeup + miss replay) is the
aggressive piece — deferred to Block R because its replay entangles SMP memory
ordering.

**Effort:** medium (SEL/SPEC + bypass). **Mostly independent** of L; `LOAD_SPEC`
touches R3's ordering machinery.

### ✅ S1 status (2026-07-27) — scheduler-pipeline SHIPPED LIVE; EX_PIPE banked

The scheduler pipeline is now the **FINAL structure, LIVE**: `SEL_PIPE=1` +
`SPEC_WAKE=1` (`iq_int.veryl:266/297`). Re-validated end-to-end in the current
tree (post-F1/F2): `veryl test` **252/0**, litmus **N4 pass** (cy 5.63M), **N2 SMP
boot** 19.25M, **N4 SMP boot** 30.55M — all at baseline cycle counts (**IPC-neutral**;
dhrystone +0.6 %, instret bit-exact). A1.0 pipelines the select→wakeup loop
(registers the SCHED_WAKEUP pdst); A1.1's grandparent speculative wakeup recovers
the +1-cy dependent-issue (litmus N2 returns to the byte-exact baseline). The CP
benefit stays masked under the wall (only realised in a bundle flip) — this ships
for the **structure**, per the campaign's "advance FINAL structure, not the synth
number" mandate.

**EX_PIPE (execute-staging keystone) is BANKED at 0** — two blockers in the current
tree, user-decided to bank (2026-07-27) and ship the scheduler-pipeline alone:
1. **Boot hang** (arch 252/0 passes, but N1 boot infinite-loops): at `EX_PIPE=1`
   early boot corrupts the paging-enable / control flow (`csrw satp` @0x80001040 →
   a wild jump to PC 0 → `handle_exception` re-enters forever because `ld sp,16(tp)`
   loads sp=0 → `sd ra,8(sp)` store-page-faults → nested-trap storm). Localised to
   the paging-enable/CSR-CDB region; a wrong-value from the EX register/bypass. The
   old "SMP-complete" validation (`deep_pipeline_status_and_replan.md`) predates
   F1/F2 + the grown suite. −15 % IPC alone, so IPC-negative even once fixed.
2. **FROUND_PIPE=1 latent bug** (coupled to EX_PIPE): the 3-stage Zfa FROUND applies
   the wrong rounding mode for STATIC-rm `fround.s` and drops the `froundnx.s` NX
   flag — the held-at-head op's rounding-mode / fflags are read LIVE one cycle after
   the op released (`test_arch_zfa_s2`; ACT4's single dynamic-rm fround never hit it).
   **Decoupled** (`FROUND_PIPE=FMA_PIPE3=0`, byte-identical at `EX_PIPE=0`) so a
   future EX_PIPE flip does not re-enable it; the fix + re-couple is FP-CP follow-up.

EX_PIPE + its bypass/E3 scaffold + corner-fixes stay committed (built, `=0`); the
boot corner and the FROUND bug are the remaining work for a future execute-staging /
FP-CP session. `LOAD_SPEC=0` remains deferred to Block R.

---

## Block L — Canonical LSQ (store queue + translate@execute + load queue)

Heliodor's memory-ordering fuses what a real LSQ separates
(`retire_memory_ordering_redesign_study.md`, `cp_retire_decouple_plan.md`,
`cp_store_queue_plan.md`):

- **L1 — R1 decoupled-retire + store queue.** Break the single-cycle
  `commit_store_fire → live-TLB translate → sb_merge_ok → rob_commit_ack →
  n_inflight` fusion. A store frees its ROB entry when non-speculative; the write
  drains later from a real SQ. `SB_PA_REG` (R1a, `aee7ecd`) already registered the
  store-buffer PA off `rob_commit_ack` and is LIVE; `RETIRE_DECOUPLE`
  (`heliodor_core.veryl:~1690`) is the DEAD groundwork. The committed-store buffer
  (4 × 64 B line write-combining drainer) becomes the SQ's drain stage.
- **L2 — R2 translate-at-execute.** Compute the PA at AGU/execute, carry it in the
  SQ; commit stops re-driving the TLB. `STORE_PRETRANSLATE`
  (`heliodor_core.veryl:1676`) scaffold built (−0.25 ns plain-store, **atomics
  excluded** — they share the coherent port and stay commit-translated until R3).
- **L3 — first-class load queue.** Today disambiguation is **load-violation detect
  + commit-time replay** with no explicit LQ. Add an **age-ordered LQ-CAM** checked
  at store-execute (the "L" half; R1/R2 build the "S" half). Store-to-load
  forwarding (now split across ROB scan + committed buffer) folds into one
  age-ordered SQ CAM.

**Effort:** large (L1, L3), medium (L2). **Independent of Blocks F/S** — commit
side, can proceed in parallel. Build L1→L2→L3 as DEAD scaffolds and measure
before R3.

---

## L3 — FIRST-CLASS LOAD QUEUE: hand-off for a clean context (2026-08-09)

Written to be self-contained; start here in a fresh session, the way f2.7 / f2.13 / f2.15e / f2.16
were. User chose L3 after F2 shipped.

### ⚠️ FIRST: the premise is CONTESTED by this repo's own study — census before building

Block L3 above says "today disambiguation is load-violation detect + commit-time replay with **no
explicit LQ**" and prescribes an age-ordered LQ-CAM. But
`retire_memory_ordering_redesign_study.md` §3.5/§3.7 examined the same code and concluded the
opposite:

> load speculation + forwarding + poison-replay — **already decoupled ✅ keep (modern)**
> "✅ This is already a modern speculative-memory scheme."

One says build it, the other says keep it. **f2.16 is the precedent for what to do here:** its
hand-off prescribed a run-ahead RAS, the census showed returns were 1.4 % of the target population,
and the increment was correctly abandoned before a line was written. Do the same.

**Measured already, at the shipped default (2026-08-09):**

| workload | `loadviol` |
|---|---|
| dhrystone | **0** |
| coremark | **0** |

**Zero load-order violations.** The replay mechanism the plan wants to replace never fires on either
microbenchmark, so its IPC cost there is exactly nothing. **The boot harnesses do not expose the
counter at all** (`tb/test_soc_*_linux_boot*.veryl` have no `loadviol` port) — wiring
`o_dbg_load_viol_cnt` through them is the first task, because the kernel and SMP are the only places
a violation is plausible.

> ⚠️ **Superseded by L3.0/L3.1 below (2026-08-09).** The wiring was done and the boot answer is
> **not** zero — 19,539 poisons / 16,496 replays on the N=1 boot. The microbenchmarks read 0 because
> they run **bare**, where the overlap test is exact; the degradation is Sv39-only. But the
> *conclusion* here still holds for a different reason: deleting the dominant poison source outright
> buys only **0.41 %** (L3.1). Right verdict, wrong evidence. Read L3.0/L3.1, not this.

**Decide the justification before building.** If `loadviol` is ~0 on the boots too, L3 cannot be
sold on IPC and must stand or fall on (a) canonical LSQ structure and (b) CP — and (b) needs a
`veryl synth` number, not an argument. Bring that to the user rather than assuming.

### L3.0 — THE CENSUS, MEASURED (2026-08-09). The microbenchmark zero does not carry.

The counters are now wired through the SoCs into the boot harnesses (`o_dbg_load_viol_cnt` and, new
here, `o_dbg_load_replay_cnt` / `o_dbg_inv_viol_cnt` / `o_dbg_mshr_pois_cnt` /
`o_dbg_viol_store_cnt` / `o_dbg_viol_self_cnt` / `o_dbg_viol_exact_cnt` / `o_dbg_viol_pgx_cnt` /
`o_dbg_st_resolve_cnt`). All are diagnostic — the N=1 boot is **`cy=00deee50`, bit-exact with the
shipped baseline**, so nothing here perturbs the design.

**N=1 Linux boot, shipped default (`78529fe`): 14,609,488 cy / 10,434,358 instret**

| counter | value | what it is |
|---|---|---|
| `stresolve` | 1,877,893 | stores resolving on CDB lane 0 — the denominator |
| `loadviol` | **19,539** | poison events (both scans fused, as the old counter always was) |
| ├ `violstore` | 6,459 | the store-resolve scan (a store poisons younger executed loads) |
| │ └ of which `exact` | **6,419** | …a full-width compare of the two recorded addresses also fires |
| │ └ of which `pgx` | **0** | …the VM page-cross blanket. **Never fires. Hypothesis dead.** |
| └ `violself` | **13,083** | the S15 record-time self-scan (a load poisons ITSELF) |
| `loadreplay` | **16,496** | commit-time replays — full redirect + refetch of the load and younger |
| `invviol` | 0 | P9.0 CoRR remote-invalidate poison (expected 0 at N=1) |
| `mshrpois` | 0 | S10.3 aborted-MSHR-fill poison |
| `loadwait` | 2,987,980 | 20.5 % of all cycles: a selected load cannot issue |

**The hand-off premise above is refuted, but not in the direction it assumed.** It is not that
disambiguation never fires — it fires 19,539 times and costs 16,496 full redirects. It is that
**the microbenchmarks run bare (no MMU) where the overlap test is an exact 64-bit compare, so they
cannot see the problem at all.** Under Sv39 the test degrades, and that degradation is the entire
signal. dhrystone/coremark reading 0 was never evidence about the kernel.

**Where the 19,539 actually come from — attributed, not inferred:**

- The **store-resolve scan is already precise**: 6,419 of its 6,459 events (99.4 %) are confirmed by
  a full-width compare. There is nothing to win here.
- The **S15 record-time self-scan is 13,083 events — 67 % of all poisons — and has no exact arm at
  all.** Its firing condition (`rob.veryl`, `rec0/rec1/recq_self_viol_w`) is literally *page offsets
  overlap AND the full VAs do not*: `a0_ovl && !a0_va_ovl`. That is the "different VA, might still
  be the same PA" alias suspicion, and it is resolved by poisoning unconditionally.

**Why it is approximate, and why the fix is already half-built.** Under VM the load record and the
resolving store are not in the same address space — `sh_load_addr` is fed from the lane-0/lane-1 CDB
(`lsr_vaddr_q`, a **VA**) while MSHR captures record a **PA**, and the store shadow `sh_store_addr`
is a VA. Only bits [11:0] are translation-invariant, hence the 13-bit range compare. But **both
exact PAs already exist in the RTL and neither is used by disambiguation**:

- the load's PA is `lsr_paddr_q` (`heliodor_core.veryl:4228`), the Stage-A translated PA, live at
  the load's execute cycle — the ROB records the VA next to it and drops the PA;
- the store's PA is `store_pretx_pa` (`:8572` — the TLB probe L2/`STORE_PRETRANSLATE` already
  captures for the commit drain), and it is **already a ROB input and shadow field**
  (`i_cdb_store_pa` → `sh_store_pa` / `sh_store_pa_valid`, `rob.veryl:448`). `store_pretx_valid`
  asserts on `cdb.valid && cdb.is_store` — *the same cycle the scan runs*.

So the age-ordered load queue Block L3 asks for is, structurally, already present: the ROB shadow
arrays (`sh_load_addr` / `sh_load_done` / `sh_load_funct3` / `sh_load_poison`) ARE an age-ordered LQ
checked at store-execute. What is missing is not the queue — it is that **the queue is tagged with
the wrong address**. The canonical increment is therefore *PA-exact LQ records*, not a new structure:
record `lsr_paddr_q` alongside the VA, and let both scans use an exact PA overlap test whenever both
PAs are valid, falling back to today's conservative test otherwise. Strictly fewer poisons, same
true positives (PA overlap ⟺ byte overlap), and the stale-translation case is already gated by
`rob_has_pending_xlate` on the store side.

### L3.1 — THE CEILING, MEASURED. **0.41 %. Do not build L3 for IPC.**

Rather than estimate the prize from the event count, delete the dominant source outright and read
the cycles. `S15_SELF_SCAN` (`rob.veryl:768`) gates the three record-time self-scan flags. It is a
**measurement arm only** — removing the scan is UNSOUND for a genuine VA alias — and it must stay
at 1. At 0 the N=1 boot still reaches SBI shutdown with correct output:

| N=1 boot | `S15_SELF_SCAN=1` (ship) | `=0` (probe) | Δ |
|---|---|---|---|
| cycles | **14,609,488** (`00deee50`) | **14,549,488** (`00de03f0`) | **−60,000 = −0.41 %** |
| `loadreplay` | 16,496 | 10,524 | −5,972 |
| `violself` | 13,083 | 0 | −13,083 |
| `violstore` | 6,459 (exact 6,419) | **11,743** (exact 11,709) | **+5,284** |
| `instret` | 10,434,358 | 10,434,440 | +82 |

**Deleting 13,083 poisons buys 5,972 fewer replays, not 13,083.** The machine that stops replaying
runs further ahead, and 5,284 of the avoided conservative poisons come straight back as *genuine*
store-resolve violations (99.7 % exact-confirmed). The two scans partly cover the same conflicts
from opposite sides; suppressing one just moves the detection.

**So the ceiling on the whole PA-exact idea is 0.41 % of the N=1 boot — and that is the UNSOUND
bound.** A sound PA-exact test only fires where both PAs are available (`sh_store_pa_valid` needs a
clean TLB-probe hit, no pending xlate), so the real number is strictly less. **L3 has no IPC case.**
The earlier estimate in this document of "roughly 1–2 %" was derived from the event count and a
redirect-cost band; the direct measurement refutes it. Attribute, then measure the ceiling, then
build — the estimate was wrong by 3–5×.

**SMP adds nothing to the case.** N=2 boot, `cy=012b60a0` (baseline, bit-exact):

| | `loadreplay` | `loadviol` | `invviol` | `mshrpois` | `loadwait` | `instret` |
|---|---|---|---|---|---|---|
| hart0 | 19,971 | 22,442 | **0** | 0 | 4,014,596 | 13,301,401 |
| hart1 | 879 | 961 | **1** | 0 | 875,021 | 14,600,654 |

The P9.0 CoRR remote-invalidate poison fires **once** in an entire 2-hart Linux boot. There is no
SMP-specific memory-ordering cost to recover either.

**What survives as a reason to do L3:** only (a) canonical LSQ structure and (b) CP — and (b) still
needs a `veryl synth` number, not an argument. The IPC leg is now measured and gone.

**Where the cycles actually are, for whoever picks the next block.** `loadwait` is 20.5 % of N=1
cycles (2,987,980) and 4.0 M/0.9 M per hart at N=2. That is issue-side serialization —
`load_blocks_on_store` in `heliodor_core.veryl` (`sb_cnt >= 3`, `store_drive`, `asq_dr_busy`,
`asq_ld_ovl`, the page-edge hold) — **not** disambiguation, and an LQ-CAM does not address it. It is
an aggregate rate, so per the campaign's own rule it needs a per-event attribution before anything
is built on it.

### L4 — `loadwait` CENSUS: the 20.5 % is one structure, and it is not the CAM (2026-08-09)

L3.1 pointed at `loadwait` as the real pool but warned it is an aggregate rate. Decomposed per
cause. For a PLAIN load `iq_issue_ack` is exactly `lsr_capture || mshr_capture`, so the blockers are
the negated terms of `lsr_capture` — an enumerable set. Each cause is counted **only when it is the
SOLE blocker** (the causes overlap heavily; "was X present" is not actionable, "would removing X
alone have let the load through" is). Cycles with ≥2 live causes go to a `multi` bucket.

**N=1 boot, `cy=00deee50` (bit-exact — the counters do not perturb).** The buckets sum to
**2,987,980 = `loadwait` exactly**, so the partition is complete and there are no unexplained cycles
(`none` = 0 confirms it):

| sole blocker | cycles | of `loadwait` | of boot |
|---|---|---|---|
| **`lsr_v_q`** — LSR occupied | **1,757,323** | **58.8 %** | **12.03 %** |
| `load_blocks_on_store` | 729,009 | 24.4 % | 4.99 % |
| `dmem_mmu_busy` | 272,825 | 9.1 % | 1.87 % |
| AMO/LR/SC issue path | 106,663 | 3.6 % | 0.73 % |
| multi (≥2 causes) | 89,270 | 3.0 % | 0.61 % |
| redirect (squash cycle, not a stall) | 32,890 | 1.1 % | 0.23 % |
| `load_walk_block` / `fpu_cdb` / `mshr_cdb` / `replay_q` | **0** | 0 % | 0 % |

Four of the eight enumerated blockers **never block alone**. The lane-0 contenders (FPU, MSHR,
divider) are not the problem; neither is the PTW.

**Drill-down on the dominant bucket — why is the incumbent load not completing?** Priority-encoded,
and again an exact partition (sums to 1,757,323):

| incumbent state | cycles | of boot | |
|---|---|---|---|
| driving, `dcache_stall` | **1,043,579** | **7.14 %** | a missing load holds the only LSR slot for the whole miss |
| read done, `lsr_v_q` still set | **713,742** | **4.89 %** | the hand-off bubble |
| `m_store_wr_busy` | 2 | — | |
| fault / `store_drive` / MMU walk / replay | **0** | 0 % | Stage B essentially never loses the port |

**Both halves are the same fact: the Load Stage Register is ONE entry deep.**

- The 4.89 % is structural, not contention. `lsr_capture` requires `!lsr_v_q`, and `lsr_v_q` only
  drops the cycle *after* `lsr_complete`. For a plain integer load `lsr_to_lane1` is 1, so
  `lsr_complete` is just `read_done` — the incumbent finishes *this* cycle and the newcomer still
  waits one. **Every back-to-back load pays a dead cycle even on a dcache hit**, capping load
  throughput at 1 per 2 cycles.
- The 7.14 % is the absence of memory-level parallelism for loads. A load that captured into the LSR
  and then misses sits there for the entire miss; `mshr_capture` releases the *IQ*, not the LSR, so
  every younger load is behind it. The load path is **blocking**.

**The obvious one-line bypass is not available — tried it, the loop is real.** `doc/lsu_pipeline_
plan.md` §11 claims the bubble is "recoverable with back-to-back capture (`lsr_accept = !lsr_v_q ||
lsr_complete`)". It is not, as stated. Relaxing the gate that way and running the suite gives
**230/252 failed with the simulator's `involved in loop`**, closing through `heliodor_soc.veryl:78`
(`in_dram = c_dmem_addr[31]`) and `heliodor_core.veryl` `lsr_drive`.

Two things worth carrying forward from that experiment:

- **`veryl build` does NOT catch it, and neither does a narrow test.** The build is clean and
  `test_dcache` passes; only the full-core simulation reports the loop. The step-1 commit's "veryl
  build (clean, no comb loop)" is not the check it reads like. **Run the default suite.**
- **The loop is not the one the step-1 comment names.** That comment cites `i_ren ← lsr_capture`,
  and that path is genuinely broken now — at `MEM_PIPE=1` (`:4283`) `dmem_ren_m` takes the
  registered `m_ren_q` arm, so the `!lsr_capture` fold is only on the dead `MEM_PIPE=0` arm. The
  loop that actually fires closes through the dcache **address/decode** path instead:
  `lsr_capture` → the dmem address mux → SoC decode → hit/miss → `dcache_stall` → `lsr_read_done` →
  `lsr_complete` → `lsr_capture`. A comment can outlive its reason while the conclusion stays true.

**A second LSR entry avoids the question entirely**: accept is then a function of a flop
(`!lsr_v_q[tail]`), never of the incumbent completing this cycle, so no accept→complete edge exists.

**But depth-2 is not the best first increment — step-2 is.** A 2-deep LSR recovers the 4.89 %
bubble and little of the 7.14 %: if entry 0 is stalled on a fill, entry 1 can capture but still
cannot drive, because the dcache is busy. The 7.14 % needs the load to *leave* on a miss — which is
exactly **step-2, "non-blocking MSHR-from-Stage-B"**, named and deferred by the step-1 commit
(`88b7735`) and never built. Its receiving machinery is **already in the tree and merely
disconnected**: `let mshr_plain_load: logic = 1'b0;` (`:10423`) kills a fully-built 2-entry
miss-under-miss MSHR — owner/queued capture, replay engine, deferred `mshr_cdb` writeback, age-based
squash safety, SMP aborted-fill poison. The census confirms it is inert (`mshr_cdb` never blocks,
`mshrack` = 0).

So the ranking within this bucket is: **step-2 (7.14 %, machinery exists, must be re-qualified from
the LSR's latched state instead of the issue-side signals) before depth-2 (4.89 %, all-new state).**
⚠️ The MSHR path has been dead since 2026-06-26 and the tree has since gained R3's atomic SQ,
`ASQ_NOREAD`, the F2 front end and `MEM_PIPE`. Waking dead RTL across that much churn is the risk to
budget for — build it DEAD-gated and flip it against the full ladder, N=2 SMP included.

**So Block L3's value is real, but it is on the other side of the block from where the plan put it.**
The plan framed L3 as an age-ordered LQ-CAM for disambiguation; that half is measured dead (L3.1,
0.41 % ceiling). The half that is worth 12 % of boot stall cycles is **load-queue DEPTH** — more
than one load in flight — which the plan does not mention at all.

⚠️ **Do not read 12.03 % as 12.03 % of cycles recoverable.** `loadwait` counts cycles where a load
is *selected but does not ack*; some overlap with work the back end is doing anyway. L3.1 is the
standing warning here — an event/stall count over-predicted the real prize by 3–5× last time, and
the only thing that settled it was deleting the mechanism and reading the clock. There is no const
gate that "deletes" LSR depth, so **the ceiling for this one has to come from building the 2-deep
scaffold DEAD and flipping it**, not from another counter.

**Next drill, if wanted:** the `load_blocks_on_store` bucket (729,009 cy, 4.99 % of boot) is still
undecomposed — `load_blocks_on_store` (`heliodor_core.veryl:8672`) ORs `store_drive`, `sb_cnt >= 3`,
`asq_ld_ovl`, `asq_dr_busy`, the page-edge hold and the AMO terms. Same sole-blocker treatment
applies and is cheap.

### L4 step-2 — BUILT AND FLIPPED. Flip FAILS on a lost AMO update; scaffold banked at 0.

`LSR_MSHR_B` (`heliodor_core.veryl:10478`) hands a Stage-B load that misses to the 2-entry MSHR and
frees the LSR the same cycle. Eligibility mirrors the original issue-side qualifier against the
LSR's latched state (not faulting / FP / uncached / cross-dword span / forwarded-bytes /
wrong-path). Kept separate from `mshr_capture` because that signal also drives `iq_issue_ack` and a
Stage-B handoff must not ack an unrelated IQ op; it *does* drive the ROB LQ-record port, from
`lsr_paddr_q`.

| arm | result |
|---|---|
| **`=0` (DEAD, shipped)** | **252/0, N=1 boot `cy=00deee50`, `instret` 10434358, every census counter bit-identical.** Verified, committed. |
| **`=1` (flip)** | **249 passed / 3 failed** — `test_litmus_2hart`: `tohost=0x7012` → test 7, slot 1 = LOST AMO UPDATE. **AND the N=1 Linux boot does not complete**: `cy=02aea540` (the 45 M budget cap), `x3=ffffffff80a85b60`, `pass=0`, `instret` 34,427,162 vs 10,434,358. |

Test 7 is AMO atomicity: two harts each run `AMO_ITER` × `amoadd.w` on one word and the total must
be `2*AMO_ITER`. Losing an update is a real memory-model bug, not a timing shift.

**The mechanism itself works — that is not what is broken.** In the failing `=1` boot the census
shows the handoff doing exactly its job: the `lsr` sole-blocker bucket falls 1,757,323 → 242,587 and
its `dcache` sub-bucket 1,043,579 → 44,730, while `mshr` (2,074) and `replay` (4,938) appear as sole
blockers for the first time (both were 0). The LSR is being freed on a miss as designed. What is
wrong is the *correctness* of the woken path.

**⚠️ The N=1 boot failure is the cheaper reproduction, and it reshapes the hypothesis.** A
single-hart boot has no cross-hart coherence traffic, so "two harts race on an atomic" cannot be the
whole story — but the ASQ drain engine exists at N=1 too, so the port-contention hypothesis
survives. More usefully: 34.4 M instructions retire without reaching shutdown, so this is a
livelock / wrong-data-then-error-loop, **not** a deadlock, and it reproduces in ~1 minute against
litmus's longer loop. **Diagnose on the N=1 boot first.**

**Leading hypothesis — the replay engine and R3's atomic drain have never coexisted.** Waking the
handoff also wakes `replay_q` / `replay_drive`, which have been inert since `88b7735`
(2026-06-26). Everything R3 built *after* that — `ATOMIC_SQ`, `ASQ_NOREAD`, the drain engine and its
port arbitration (`asq_dr_busy`, and `asq_dr_go_r` forcing `dmem_ren_m` at `:10187`) — was designed
and validated against a tree where **no replay could ever drive the dcache port**. Both now claim
it. R3's own history says this exact symptom is what a port/latch race there looks like: the §7.11
root cause was a diverted atomic's write latching into `m_wen_q` and landing twice, found only by
per-event attribution.

#### L4 step-2 diagnosis — bisected to the QUEUED arm; the ASQ hypothesis is refuted

`LSR_MSHR_B_QUE` (`:10601`) splits the two capture arms. `_own` only needs the entry to latch
`dc_fill_rdata` at DONE; `_que` is the one that revives the **replay engine** (a queued entry has
`own_q=0`, which is what drives `mshra_queued` → `replay_q` → `replay_drive`).

| arm | default suite | N=1 boot |
|---|---|---|
| `LSR_MSHR_B=0` | 252/0 | `cy=00deee50` pass |
| `=1`, `QUE=1` | 249/3 (litmus test 7 lost AMO) | **pass=0**, hangs at the 45 M cap |
| **`=1`, `QUE=0` (own only)** | **252/0** | **`cy=00de5210` pass, −0.27 %** |

**Every failure — the three suite failures, the lost AMO update and the boot hang — is in the
queued/replay arm. The Stage-B handoff itself is correct.** Own-only is green on the fast gates.

**But own-only recovers almost nothing: −40,000 cy (−0.27 %),** and the `dcache` sub-bucket only
falls 1,043,579 → 912,463 (−12.6 %). `_own` fires only on the exact `dc_miss_valid` cycle, and most
stalled cycles are loads arriving at an *already busy* dcache — which is precisely the `_que` case.
**The 7.14 % prize requires the replay engine to work.**

**Refuted: the ASQ port hypothesis.** `replay_drive` genuinely lacks both checks R3 added to
`load_blocks_on_store` (`asq_dr_busy`, `asq_ld_ovl`) — it has been dead since before R3 existed, so
it was never in scope. Added both (`asq_replay_ovl` compares `asq_pa_q[0]` against `replay_addr`,
single-dword since cross-dword spans cannot be captured). Result: **bit-identical** — same
`cy=02aea540`, same `instret` 34,427,162, same counters down to `replay=4938`. Per this campaign's
rule, bit-identical means the change never fired: `asq_valid_q[0]` (a queued atomic) essentially
never coincides with a replay on an N=1 boot. The terms are kept — they close a real gap and are
inert at `ATOMIC_SQ`-idle — but they are **not** the boot bug. They may still matter for litmus.

**Refuted #2: replay starvation.** Both `lsr_capture` and `lsr_drive` carry `!replay_q`, so a
pending replay does freeze the whole plain-load path — but it barely happens. Instrumented
(`o_dbg_lw_cause[20..27]`, exact partition, `=0` control all-zero):

`replay_q` resident **78,986 cy of 45 M = 0.18 %**, of which **driving 66,982 (85 %)**; blocked
`store_drive` 11,699, `dmem_mmu_idle` 305, everything else 0. The replay gets the port almost
immediately. **Not a starvation stall — the boot failure is wrong data or wrong control.**

**Refuted #3 (as sole cause): the S27 sb-forward gap.** This one is a genuine hole and is now fixed,
but it is not the whole bug. S27 — added *after* the MSHR path went dead — stopped blocking a plain
load on a committed-store overlap and instead has the **sb forward layer** (`sbf*`/`sbg*`) patch the
pending bytes onto the Stage-B data path. A captured load never takes that path: it completes from
raw `dcache_rdata`/`dc_fill_rdata` via `mshr_cdb`, so those bytes are silently dropped.
`stld_fwd_mask` does not cover it — that is the ROB-scan (uncommitted-store) forward, a different
layer — and `sb_ld_ovl` is built from the ISSUE address, so Stage B needs its own compare against
`lsr_vaddr_q` (`lsr_sb_ovl`). Added to the qualifier. It **fires** (`replay_q` resident 78,986 →
68,026, `instret` 34,427,162 → 34,429,930, so it is not a no-op) but the boot still fails at the
same `cy=02aea540` with the same `x3`. **A real gap closed; the failure survives it.**

**Remaining suspects for whoever resumes** — the theme is the same in each: machinery added after
2026-06-26 that assumed no captured load could exist.
1. **Data formatting.** `mshr_cdb` writes back `mshra_data_q`, a raw dword. Sign/zero-extension and
   byte selection by `funct3`/offset happen in the in-pipe path; confirm the MSHR writeback still
   applies them the same way after the LSU split moved that logic.
2. **`dc_hit_safe` semantics.** `replay_hit_fire` completes from `dcache_rdata` on the drive cycle.
   Verify that verdict is still the *replay's* and not the LSR's, now that `lsr_drive` also muxes
   `i_addr` (`:10245`) — the two are made exclusive only by `lsr_drive`'s `!replay_q`.
3. **The ROB LQ-record.** The scaffold routes a Stage-B handoff into `i_lq_rec_*`. Check the index
   is right and that a captured load's ROB entry cannot also be completed by the normal CDB.
4. Note the `i_addr` mux comment at `:10244` still asserts "lsr_drive and replay_drive are mutually
   exclusive (the MSHR is disabled for plain loads in step-1)" — the premise is exactly what step-2
   removes. It happens to remain true via `!replay_q`, but it is the kind of stale invariant this
   whole diagnosis keeps tripping over.

**Where to start** (do not re-derive the design — the scaffold is correct as far as the flip goes):
1. Reproduce on the **N=1 boot** at `=1` (~1 min, single-hart, no coherence traffic). Only fall back
   to `veryl test --ignored --test test_litmus_2hart` once the single-hart bug is out of the way.
2. Instrument the *port*, not the outcome: count cycles where `replay_drive` and `asq_dr_busy` (or
   `asq_dr_go_r`, or `commit_store_fire`) are simultaneously live. If that count is 0 the hypothesis
   is dead and the bug is elsewhere — cheap and decisive either way.
3. The matched-control trick applies: `=0` with the same instrumentation is the control.
4. If the ports do collide, the fix is arbitration (the ASQ drain should block a replay start, or
   `replay_drive` must yield like `lsr_drive` already does via `!store_drive && dmem_mmu_idle &&
   !m_store_wr_busy` — note `replay_drive` may simply be missing the ASQ terms that were added to
   `lsr_drive`'s peers after it went dead).

⚠️ Do not flip `LSR_MSHR_B` to 1 on master until litmus N=2 **and** N=4 pass. The other two failures
in the 249/3 run were not captured (the suite output was tail-truncated) — re-run and collect them
before diagnosing, since they may share the root cause or be a second, independent one.

#### L4 step-2 diagnosis, round 2 — the failure signature, and the replay's side-band inputs

**The N=1 failure is a kernel Oops, not a hang.** The boot testbench mirrors UART TX to stdout, and
the earlier runs only ever looked at the tail, so this was sitting there unread the whole time:

```
epc: ffffffff800b9e58  ra: ffffffff802007fc0  sp: ffffffff80a03f00
status: 0000000200000100  badaddr: ffffffdf83ffde80  cause: 000000000000000f
Kernel panic - not syncing: Attempted to kill the idle task!
```

`cause=0xf` is a **store/AMO page fault**, `badaddr` is a vmalloc-region address, and `a0 == badaddr`
with `a2 = 0x1180` — a `memset`-shaped call faulting on its very first store. That is the shape of a
**load having returned a wrong value that was then used as a pointer**, not a lost store or a
livelock. (Lesson, again: read the whole console log before theorising. It was free.)

**Budget bisection is armed and works.** `CAPB_BUDGET` (`heliodor_core.veryl`, by
`mshr_cap_b_que`) allows only the first N queued handoffs and then holds the arm off, printing the
first REJECTED event's `pc`/`va`/`pa`/`funct3`/`rob`. Runs with budget ≥ N take events `0..N-1`
identically — the trajectory only diverges at the first suppressed event — so a PASS at N and a FAIL
at N+1 names event #N *and* hands over a perfectly matched control pair. First probe:

| budget | result |
|---|---|
| 0 (= `LSR_MSHR_B_QUE=0`, own-only) | PASS, `cy=00de5210` |
| 1 | **PASS**, `cy=00dec740`, `instret` 10,434,456; REJECT #1 at `pc=8020319a va=pa=80a87fb8 f3=3` |
| all-ones | FAIL (the Oops above) |

**Suspects 1-3 above are all REFUTED by reading the code** (each took minutes; none needed a run):
1. **Data formatting is correct.** `mshr_shift = {mshr_wb_addr[2:0], 3'b000}` + the `funct3` case at
   `:10921` is exactly `alu_wrap`'s `ld_*` select on a within-dword dword. Cross-dword and
   forwarded-byte loads are excluded at capture, so the single-dword slice is the whole job.
2. **`lsr_drive` and `replay_drive` really are exclusive** — not for the stale reason the `:10244`
   comment gives, but because `lsr_drive` carries `!replay_q` (`:9816`). The invariant holds; only
   its stated justification is dead. Fix the comment, not the logic.
3. **The ROB LQ-record is right.** `sh_load_addr` is documented as a VA and the scaffold records
   `lsr_paddr_q`, but every consumer under VM compares `[11:0]` only (`ovl_vm`), and in bare mode
   VA==PA — so the unit mismatch is benign, exactly as `:10438` claims. `sh_load_done` is set from
   `i_lq_rec_valid` and `mshr_cdb.is_load=0` prevents a second record.

**What the code review DID find — the replay's side-band inputs.** The dcache's data path has a
2-cycle registered-read (`DCACHE_DATA_READ_1R`) with a bypass for "non-folded" accessors
(`nf_reroute`), and `DCACHE_R1_DCE=1` **deleted the live read**, so anything that falls off *both*
the folded-demand path and the nf path reads **zero**. For a replay cycle:

| dcache input | during `replay_drive` | guarded? |
|---|---|---|
| `i_load_next` | `dmem_lnext_m && !replay_drive` | ✅ explicit |
| `i_amo_read` | `dmem_amord_m && !replay_drive` | ✅ explicit |
| `i_ren_folded` | `lsr_drive` (= 0, needs `!replay_q`) | ✅ structural |
| `i_uncached` | `dmem_unc_m` | ❌ **unguarded** |

`dc_uncached` (`:9850`) carries its own `!replay_drive` term — the pre-step-1 design knew a replay
must never look uncached. But `MEM_PIPE=1` sources `i_uncached` from the **registered** `m_unc_q`,
latched a cycle earlier, when `replay_drive` was still 0. The guard is one cycle too early and
misses. A replay landing one cycle after a non-capturing uncached read (an MMIO load whose
`lsr_capture` was blocked by `lsr_v_q`) therefore presents `i_uncached=1`, and then:
`uncached_active` fires a **spurious uncached bus read at the replay's address**, and
`rd1_req_nf = i_ren && !dhit_use && !i_uncached` drops → `nf_reroute=0` → `nf_replay_ready=1` → the
live `o_hit_safe` completes the replay off `live_hit_rdata`, **which DCEs to 0**. A load returning 0
into a pointer is precisely the Oops signature above. Fix (dead at `MEM_PIPE=0`, where the live
`!replay_drive` already covers it):

```veryl
i_uncached : if lsr_drive ? lsr_unc_q : (dmem_unc_m && !replay_drive),
```

This is the same failure mode as R3.2c (`sb_2cyc_ok` missing `!c_is_amo`) and as the S27 gap: a
guard written for a live path, then invalidated by a later change while the path it protected was
dead, so nothing caught it.

⚠️ **The `i_uncached` fix is BIT-IDENTICAL at N=1** — `cy=02aea540`, `x3=ffffffff80a85b60`,
`instret=34,429,930`, the same three numbers as before it. The hole is real and the guard is kept
as hardening, but it never fires at N=1 and it is **not** this bug. That is the fifth consecutive
hypothesis to die bit-identical. Stop hypothesising here; the next section is what worked.

#### L4 step-2 diagnosis, round 3 — ROOT CAUSE: `o_miss_valid` is not the edge it claims to be

**Step 1: get a cheap repro.** The 249/3 failures had never been collected in six sessions of
diagnosis (the suite output was always tail-truncated). Collecting them took one run:

| failing test | cost |
|---|---|
| **`test_arch_rv64mi_ma_addr`** | **seconds**, directed, deterministic — `tohost=0x2f` → subtest **23** |
| `test_arch_hvtmr` | seconds |
| `test_litmus_2hart` | ~3.1 M cy |

That single run replaced a 45 M-cycle boot with a seconds-long directed test. **Do this first next
time** — the whole round-1/round-2 flailing was paid for by not having it.

**Step 2: trace the retire stream, not the cycle counts.** Cycle counts and census buckets
legitimately differ between the arms, so neither can name a wrong VALUE. A PC-keyed COMMIT trace
(`CMT_TRACE`) plus an MSHR life-cycle trace (`MSHR_TRACE`) can, and on ma_addr the whole run has
only **12** MSHR events. Subtest 23 is `sw x0, 5(s0)` — a cross-dword misaligned store — followed by
four `lb`s whose expected values are fixed by the test source. The trace:

```
M[317] cap own=0 pc=80000498 pa=80002009 f3=0 rob=30   <- lb 9(s0), QUEUED
M[321] MISS rq=1 ld=0 av=1 ao=0 bv=0 bo=0              <- fill starts, replay drives
M[321] claim isa=1 a=80002009                          <- entry A becomes the owner
M[322] MISS rq=0 ld=1 av=1 ao=1 bv=0 bo=0              <- SECOND pulse, SAME fill, A already owns
M[322] cap own=1 pc=800004a0 pa=80002005 rob=0         <- entry B becomes a SECOND owner
M[323] fillA a=80002009 d=eeffee1122334400 rdy=1
M[323] fillB a=80002005 d=eeffee1122334400 rdy=1       <- both latch the same dword
M[324] wb rob=30 a=80002009 raw=eeffee1122334400 out=0000000000000044   <- correct
M[325] wb rob=0  a=80002005 raw=eeffee1122334400 out=ffffffffffffffee   <- WRONG (must be 0)
```

**`dc_miss_valid` pulses on two consecutive cycles for one fill.** 0x80002005 is the line's dword 0
and 0x80002009 is dword 1; `o_fill_rdata` is the ONE critical word the fill was demanded for
(`fill_crit_q`, §13.8), so the second owner necessarily gets a dword it never asked for. `lb 5(s0)`
returned `0xee` where the test requires 0 → `bnez t1, fail`.

**Root cause.** `o_miss_valid = load_sel && !fill_blocked_wb && i_memr_grant`, documented as "pulses
on the cycle a LOAD fill actually STARTS (the IDLE→FILL edge)". Under `DCACHE_SYNC_READ=1`,
`load_sel` is `load_sel_q` — the PREVIOUS cycle's `load_sel_raw`. `load_sel_raw` is itself IDLE-gated
(`lo_miss`/`hi_miss` carry `state == State::IDLE`), but the FSM's IDLE→FILL transition registers at
the END of the start cycle, so on the next cycle `load_sel_q` still carries the pre-transition raw,
and with `i_memr_grant` held across the burst the output pulses again. The FSM is safe
(`fill_start_fire` is consumed inside the `State::IDLE` arm); **only this output escaped the gate**.
Fix (`src/cache/dcache.veryl`):

```veryl
assign o_miss_valid = load_sel && !fill_blocked_wb && i_memr_grant && state == State::IDLE;
```

This is a **latent defect in shipped RTL**, not a step-2 defect. It is invisible today only because
`mshr_plain_load = 0` leaves every ownership consumer (`mshr_capture_own`, `replay_claim`) dead; the
one live consumer is the core's `fill_busy_q` SET, which the first pulse already performed. Measured:

| arm | result |
|---|---|
| `LSR_MSHR_B=0` (shipped) | **252/0**, `cy=00deee50`, `instret 10434358` — **bit-exact baseline** |
| `LSR_MSHR_B=1` | **249/3 → 251/1**; `ma_addr` and `hvtmr` both fixed |

**Still failing at `=1`: `test_litmus_2hart`, `tohost=0x7012` = test 7 slot 1** (`amoadd.w x0` ×1000
per hart, then `lw t0,0(s4)` must read 2000). This is a SECOND, independent bug. The MSHR trace
names it precisely — `pc=0x800005e0` is that check load, it executes exactly **once** in the whole
run, and:

```
M h=0 [2559146] cap own=0 pc=800005e0 pa=80007000 f3=2 rob=4
M h=0 [2559162] claim isa=1 a=80007000
M h=0 [2559194] fillA a=80007000 d=0000000000000000 rdy=1 cmp=0
M h=0 [2559195] wb rob=4 a=80007000 f3=2 raw=0 out=0
```

The load's **fill returned 0**. So the AMOs are not lost — the captured load's fill read a stale
line. (The ASQ drain trace then proved it outright: the RMW chain runs unbroken 0x7c8, 0x7c9, …
**0x7d0 = 2000**, so x really is 2000 and only hart 0's fill disagrees.)

#### L4 step-2 — SOLVED. Five bugs, one root cause: `DCACHE_SYNC_READ` broke "driver == owner"

The remaining four all fell out of the same sentence:

> **`DCACHE_SYNC_READ=1` made every fill decision a function of the PREVIOUS cycle's port state,
> and the MSHR/replay path was already dead when that landed, so nothing caught it.**

A *blocking* LSR drive holds `i_addr`/`i_ren` on every cycle of its wait, so "whoever is driving
the port now" and "whoever the in-flight thing belongs to" stay the same signal by accident. A
*replay* drive is intermittent, and every place that relied on that accident breaks:

| # | invariant that quietly died | fix |
|---|---|---|
| 1 | `o_miss_valid` is the IDLE→FILL edge | `&& state == State::IDLE` (dcache) |
| 2 | "a captured load's bus request survives the capture" | queued handoff only while `fill_busy_q` (`LSR_MSHR_B_QUE_FILLONLY`) |
| 3 | "the driver at the pulse owns the fill" — LINE | compare `dc_mem_addr[63:6]` |
| 4 | "the port is free" | `replay_drive` yields to `m_ren_q` like the ASQ drain does |
| 5 | "…owns the fill" — **DWORD** | new `o_miss_offset`; compare `[63:3]` |

**#2** — `dcache_stall && !dc_miss_valid && !dc_hit_safe` conflates "the dcache is filling someone
else's line" (safe: `lo_miss` carries `state == IDLE`, so we have no request outstanding) with "our
OWN miss is waiting for the bus grant" (fatal: `o_memr_req` is asserted and, as the `o_miss_valid`
comment already spelled out, "needs `i_ren` held to keep requesting the bus"). Freeing the LSR
withdraws the request mid-arbitration. Restricting the handoff to `fill_busy_q` fixed litmus N=2.

**#5** — `o_fill_rdata` is the ONE critical word the fill was demanded for, and `f_offset_q` is a
previous-cycle register just like `f_index_q`. Two accesses to the same line but different dwords
across those two cycles give a line-match with an offset-mismatch, and the owner latches its
neighbour's dword. `o_memr_addr` zeroes the offset at a fill start, hence the new port.

**How #5 was found — the technique to reach for first.** Retire is in-order and both arms run the
same program, so the commit streams are identical up to the first wrong VALUE. Dump both
(`CMT_TRACE`, pc + rd/data, rd only when `has_rd` so branch/store result slots cannot add false
divergences) and `cmp`:

```
cmp cmt_dead.log cmt_live.log   ->  differ: line 3216288       (of 10.4M)

  =0   C pc=ffffffff8021786c rd=15 d=0000000080000000
  =1   C pc=ffffffff8021786c rd=15 d=0000000001fff000   <- the value the NEXT instruction loads
```

One command, one culprit instruction, zero hypotheses. Cost: two traced boots (375 MB + 1.2 GB).
Contrast the five preceding hypotheses, every one of which died **bit-identical** (never fired).

**Ladder at `LSR_MSHR_B=1`** (all green):

| gate | result | =0 baseline |
|---|---|---|
| default suite | **252 / 0** | 252 / 0 |
| litmus N=4 | PASS `cy=003c1ea0` (3.94 M) | 3.78 M — **+4.3 %** |
| N=1 Linux boot | PASS `cy=00dec740` (14.60 M) | 14.61 M — −0.07 % |
| N=2 SMP boot | PASS `cy=012a0110` (19.53 M) | 19.62 M — −0.46 % |
| `LSR_MSHR_B=0` re-check | **252 / 0, `cy=00deee50`, instret 10434358** | bit-exact |

#### THE VERDICT: step-2 is CORRECT, COMPLETE and IPC-NEUTRAL. Do not ship it for IPC.

L4 priced the LSR-occupancy bucket at 7.14 % of the boot. Measured, with every arm green:

| config | suite | N=1 boot | dhrystone | coremark |
|---|---|---|---|---|
| `LSR_MSHR_B=0` (shipped) | 252/0 | `00deee50` 14.610 M | 263,393 | 421,616 |
| `=1`, `QUE_FILLONLY=1` | 252/0 | `00dec740` 14.600 M (−0.07 %) | 263,395 (+2 cy) | 421,803 (+0.04 %) |
| `=1`, `QUE_FILLONLY=0` (full queued) | 252/0 | `00dec740` **14.600 M — identical** | — | — |

Boot cycles, every `=0` figure a MATCHED control on this same tree:

| gate | `=0` | `=1` | Δ |
|---|---|---|---|
| N=1 boot | 14,610,000 | 14,600,000 | −0.07 % |
| N=2 SMP boot | 19,620,000 | 19,530,000 | −0.46 % |
| N=4 SMP boot | 28,530,000 | 28,320,000 | **−0.74 %** |
| litmus N=4 | 3,780,000 | 3,940,000 | **+4.3 %** |

The boot gain is **monotone in hart count** (0.07 → 0.46 → 0.74 %), which is the shape the structure
predicts: more harts ⇒ longer misses (coherence traffic) ⇒ more value in freeing the LSR. litmus
N=4 is the opposite regime (contended atomics paying for the replays).

⚠️ **Take the matched control, not a remembered baseline.** The recorded F2-ship N=4 figure is
29.39 M; measuring `=0` on this tree gives **28.53 M**. Comparing against the remembered number
would have reported −3.6 % — a **5× overstatement**. Every intervening commit is DEAD-gated and was
verified bit-exact, but only at N=1, so the 2.9 % gap between the recorded and measured `=0` N=4 is
**unexplained and open**. Re-measure `=0` N=4 before trusting it again.

**The `QUE_FILLONLY=0` row is the important one.** The suspicion was that restricting the handoff
to "another fill in flight" left the prize on the table, since the census said the
waiting-for-grant case dominates. With the five attribution bugs fixed, the full queued arm runs
clean — **and buys exactly zero cycles.** Same cycle count to the digit.

So the census bucket was never recoverable. `lsr_v_q` occupancy measures cycles the LSR is BLOCKED,
not cycles that would be SAVED by unblocking it: the loads behind the missing load are either
dependent on it, or on the same line (so they hit off the same fill either way), or the machine
runs out of other work regardless. **A sole-blocker census is an upper bound on the OPPORTUNITY,
not on the PRIZE** — the same lesson as [[feedback_measure_ceiling_dont_estimate]], one level up:
there the estimate was wrong and measurement fixed it; here the measurement itself was of the wrong
quantity. The only sound way to price a structural change remains: build it DEAD, flip it, read the
cycle counter.

What step-2 *is* worth: it is the canonical non-blocking-MSHR structure, it is now correct and
fully gated, the boot gain grows with hart count, and building it flushed out **five latent defects
in shipped RTL** — defects whose fixes go back to being dead code the moment the scaffold sits at 0,
so shipping is also what keeps them exercised. That may justify shipping on structural grounds —
but that is the user's call, and the IPC case (7 %) is dead.

⚠️ Bugs #1, #3, #4, #5 are **latent defects in shipped RTL**, not step-2 defects — every consumer
that could observe them is dead at `mshr_plain_load = 0`. They become live the moment anything
takes fill ownership again.

**Instrumentation left in the tree** (all diagnostic; N=1 boot stays bit-exact at `00deee50`):
`o_dbg_load_replay_cnt` / `o_dbg_inv_viol_cnt` / `o_dbg_mshr_pois_cnt` / `o_dbg_viol_store_cnt` /
`o_dbg_viol_self_cnt` / `o_dbg_viol_exact_cnt` / `o_dbg_viol_pgx_cnt` / `o_dbg_st_resolve_cnt` and
the L4 array `o_dbg_lw_cause[20]` on `heliodor_core` + `rob`, wired through `heliodor_soc` into
`test_soc_linux_boot`. The per-hart
subset (`load_viol`/`load_replay`/`inv_viol`/`mshr_pois`/`load_wait`/`rob_commit`) is wired through
`heliodor_soc_smp` into the N=2/N=4 harnesses; the decomposition counters are N=1-only.

### What is already built — do NOT rebuild

| piece | state |
|---|---|
| `RETIRE_DECOUPLE` (L1) | **LIVE**, `heliodor_core.veryl:6722` |
| `STORE_PRETRANSLATE` (L2) | **LIVE**, `heliodor_core.veryl:4288` |
| `ATOMIC_SQ` / `ASQ_NOREAD` (R3) | **LIVE**, `:987` / `:1006` — atomics already route through the SQ |
| store buffer + drain | decoupled since P9; `sb_pop` |
| store→load forwarding | `stld_fwd_*`, ROB scan + committed buffer |
| load poison / replay | `sh_load_poison` → `commit_load_replay`; counter `o_dbg_load_viol_cnt` (`:201`) |

So the "S" half the plan says L3 depends on is **done and shipped**. What L3 adds is the age-ordered
LQ-CAM and folding forwarding into one SQ CAM.

### Baselines — ⚠️ ALL CHANGED TODAY, F2 SHIPPED (`78529fe`)

Every pre-2026-08-08 number in this repo's docs is against the OLD front end. The current default:

| gate | value |
|---|---|
| default suite | **252 passed / 0 failed** |
| dhrystone | **263393** (instret 264834) |
| coremark | **421616** (instret 374357) |
| N=1 boot | **`cy=00deee50`** |
| SMP N=2 boot | **`cy=012b60a0`** |
| SMP N=4 boot | **`cy=01c074b0`** 29.39 M |
| litmus N=4 | **`cy=003bd080`** |

`instret` is the canary and must stay bit-exact. **The N=4 SMP boot gate takes ~75 minutes.**

### Traps this campaign has paid for — the ones that generalise

- **Attribute before building.** Every increment built from an aggregate rate failed (f2.16 attacked
  the largest producer bucket and regressed); every one built from a per-event attribution landed
  (f2.16c, f2.17, f2.20).
- **A bit-identical result means the change never fired.** This happened FOUR times in one session
  (a PC-region gate, a double pop, a RAS pop, a 4× table). Chase "why was it not reached" before
  re-deriving the design.
- **The N=2 SMP boot is the first gate that exercises a second hart at all.** An increment passed
  252/0 + bit-exact `instret` + N=1 boot + a cycle-identical litmus N=4 and still hung SMP bringup.
  Run it before writing a result up, not after.
- **Say which arm a claim covers.** "252/0 at `=0`" is not "the increment is safe".
- **A guard can be load-bearing for a reason its comment does not state** — ask what goes to zero
  because of it.
- **Consuming a resource whose bookkeeping you do not maintain** is the shape of three separate
  bugs here (`ext_pop2` assuming head+2, `l0_redir`'s suppression, the Stage-A RAS read).

### Do NOT re-measure

- The F2 ladder and the coremark attribution — see `cp_predictor_sram_plan.md` §f2.21. Three
  candidate fixes for coremark are refuted there, two bit-identically.
- `d_why` (`pd_why` → `ftq_d_why` → `wf_d_why` → `bd_why`) is **functional, not instrumentation** —
  `bd_why != 2 && != 7` gates `l0_redir`'s suppression. Do not strip it as a counter.

---

## Block R — SMP-critical finale (gated)

- **R3 — atomic reorder.** Atomics today are a **single-cycle commit-time RMW into
  an owned line** (`amo_watch`/`amo_poison`, P9.3); a +1-cy commit slip desyncs
  this (the litmus-N2 amoadd "M3b wedge"). Route atomics through the LSQ +
  coherence protocol so multi-cycle atomic handling is tolerated. **Highest SMP
  risk** — the M3b minefield. **User chose R3 next (2026-07-27)** after L1/L2 were
  found already-LIVE and the study marked the load side (L3) already-modern.
  Detailed design + DEAD-scaffold decomposition (R3.0 substrate → R3.1 retire-
  into-SQ → R3.2 ownership-locked drain → R3.3 flip+litmus): **`cp_r3_atomic_
  reorder_plan.md`**. ⚠️ Note there: with EX_PIPE banked (S1), R3's M3b/CP
  motivation is LATENT — its value is structural canonicalisation + contended-
  atomic IPC + future-EX_PIPE-enablement, at the highest SMP-validation cost.
- **LOAD_SPEC** replay validation lands here too (speculative load wakeup's
  miss-replay interacts with coherence/ordering in SMP).

**Gate:** only commit to R after L1/L2/L3 + S are built and measured. If R proves
out of the SMP-correctness budget, bank F+S+L (front-end + LSQ decoupled-retire)
and treat atomic reorder as a separately-scoped follow-on — the fallback the
campaign has always kept open.

---

## Dependency graph & sequence

```
F1 predictor SRAM ──▶ F2 decoupled FTQ ─┐
S1 pipelined sched (+ EX_PIPE bypass) ──┤
L1 store-Q ─▶ L2 xlate@exec ─▶ L3 load-Q┼──▶ R3 atomic reorder + LOAD_SPEC  (gated)
```

Recommended order (front-end-first, risk last):
1. **F1** predictor SRAM + overriding predictor — clearest path (icache pattern), front-end centre.
2. **F2** decoupled FTQ — F1's natural extension.
3. **S1** pipelined scheduler + EX_PIPE bypass — independent, front-end-adjacent (can overlap F).
4. **L1→L2→L3** LSQ — commit side, parallelisable throughout.
5. **R3 + LOAD_SPEC** — gated SMP finale.

## First step

Begin **F1**: audit the current predictor RTL (exact array sizes, ports, F0
combinational read paths for BTB/BHT/TAGE/iBTB), then design the `PRED_SYNC_READ`
DEAD scaffold and the F0→F1 override datapath. Sub-plan doc:
`cp_predictor_sram_plan.md` (to be written).
