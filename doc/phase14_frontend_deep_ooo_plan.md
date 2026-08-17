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
so shipping is also what keeps them exercised. The IPC case (7 %) is dead; the structural case
stands.

#### 🏁 L4 step-2 SHIPPED — `LSR_MSHR_B=1` is the default path

**Verilator NBA cross-check 4/4**, every cycle count matching the Veryl sim (this campaign requires
Verilator for anything touching coherence timing, and these five fixes are exactly that):

| | Verilator | Veryl sim |
|---|---|---|
| N=1 boot | `$finish` 146 ms = 14.60 M | 14,600,000 |
| N=2 SMP boot | 195 ms = 19.5 M | 19,530,000 |
| litmus N=4 | `cy=3,931,194` pass=1 | 3,940,000 |
| N=4 SMP boot | 283 ms = 28.3 M | 28,320,000 |

**Full gate list, all green at `=1`:** default suite 252/0 (incl. litmus N=2) · litmus N=4 ·
N=1/N=2/N=4 Linux boots · dhrystone 263,395 · coremark 421,803 · Verilator NBA 4/4.

**The `=0` arm stays as a fold-away fallback**, same pattern as `ATOMIC_SQ=0` — re-verified
bit-exact (252/0, `cy=00deee50`, instret 10434358) after every fix landed.

⚠️ **Before shipping, the diagnosis scaffolds were made to actually fold away.** `CAPB_BUDGET`'s
`capb_cnt_q <: 32'hffff_ffff` is always true in practice but is **not constant-foldable**, so it
would have put a live 32-bit counter + comparator in the ship path; `trc_cy_q` was an unconditional
free-running counter. Both now sit behind `CAPB_BISECT` / `CMT_TRACE || MSHR_TRACE` so their
registers are reset-only → DCE. Re-validated after the change: 252/0, `cy=00dec740`, instret
10434447 — identical. **A DEAD scaffold is only dead if the const can fold it; check the comparison,
not just the intent.**

**New default baselines** (supersede the F2-ship figures): N=1 `cy=00dec740` 14.60 M · N=2
`cy=012a0110` 19.53 M · N=4 `cy=01b02100` 28.32 M · litmus N=4 3.94 M · dhrystone 263,395 ·
coremark 421,803 · 252/0. README not updated (phase-end task).

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

## L3.2 — THE BUILD: a first-class load queue (2026-08-15). Structure, not IPC.

**User decision, 2026-08-15:** "performance is of almost no interest right now; I want structural
progress — performance falling out of it is a bonus." L3 is therefore promoted to *the next block*
on the structural leg alone. Phase 14 defines itself as *front-end + LSQ structural completion*, and
after F2 / S1 / L1 / L2 / L4 shipped, **the load queue is the only named structure never built**:
`pipeline_pkg::LQ_DEPTH = 8` / `LQ_IDX_W = 3` (and `SQ_DEPTH = 8`) have sat in the package **unread
by any module** since they were written — the plan's own evidence that this one was skipped.

⚠️ **This will not move IPC and that is not a failure.** L3.1 measured the disambiguation ceiling by
deleting the dominant poison source outright: **0.41 % of the N=1 boot, and that is the UNSOUND
bound**. Anyone reading a flat cycle count on the flip as "L3 failed" is reading it wrong; the
same reading of L4 step-2 would have thrown away five latent-bug fixes. Record the number, ship the
structure. Do not go looking for an IPC story afterwards.

### L3.2.0 — audit of what is actually there today (re-verified against HEAD, not from memory)

| piece | where | what it really is |
|---|---|---|
| the "queue" | `rob.veryl:468-471` | `sh_load_done/addr/funct3/poison`, four **ROB_DEPTH=32** arrays indexed by `rob_idx` |
| age order | `rob.veryl:938-939` | derived per-scan by subtracting `head_idx`, not held by the structure |
| record ports | `rob.veryl:1500` / `:1530` / `:1543` | lane-0 CDB, lane-1 CDB, MSHR capture |
| store-resolve CAM | `rob.veryl:933-978` | 32-wide, over the same arrays |
| self-scan (S15) | `rob.veryl:994-1044` | 32-wide, over the ROB store shadow |
| CoRR invalidate scan | `rob.veryl:1059-1072` | 32-wide line compare |
| replay | `rob.veryl:693` → `heliodor_core.veryl:6210` | `o_commit_load_poison` → full redirect + refetch |

It works, and L3.0 already concluded the *shape* is an age-ordered LQ checked at store-execute. What
is missing is everything that makes it a **structure** rather than four more shadow arrays:

1. **No queue.** No head/tail, no occupancy, no depth of its own — it is ROB-indexed, so "load queue
   depth" is not a design parameter of this machine at all. `LQ_DEPTH` is unread.
2. **The tag is the wrong address.** Both CDB record ports write a **VA** (`i_cdb_store_addr` = the
   AGU output), while the MSHR port writes a **PA** (`mshr_rec_addr = lsr_paddr_q`,
   `heliodor_core.veryl:10690`). One array, two address spaces, distinguished nowhere.
3. **🚩 …and that makes the CoRR scan unsound under VM — a correctness gap, not a performance one.**
   `inv_viol_w` (`rob.veryl:1066`) compares the record against `i_inv_addr[63:6]`, and `i_inv_addr`
   is a **PA** (port comment, `rob.veryl:126`). For a CDB-recorded load under Sv39 the record is a
   VA, so the compare is against the wrong address space: a remote write that should poison an
   executed-uncommitted load **silently does not**. It has never been caught because the litmus
   battery runs **bare** (VA == PA there, so the compare is exact) and the SMP boots hit the case
   once in an entire 2-hart boot (L3.1). This is the first argument for L3 that is not structural
   taste: **PA-exact records close a real hole in RVWMO CoRR under paging.**
4. **Allocation is implicit.** A load "enters the queue" the cycle it *executes* (its record port
   fires). There is no dispatch-time entry, so nothing in the machine knows how many loads are in
   flight, and no back-pressure exists to know about.
5. **Disambiguation state is spread across three modules.** The queue is in `rob`, the exact PA is in
   `heliodor_core` (`lsr_paddr_q`), the forward network is in `alu_wrap`.

### L3.2.1 — the design

A new peer module **`load_queue.veryl`**, instantiated in `heliodor_core` alongside `rob` (not inside
it): the point of the block is to make the interface of load disambiguation explicit, and a module
nested inside the ROB would hide exactly that. Every input it needs already exists at core level —
they are the signals the core drives into `rob` today.

```
                 dispatch (dec_op.is_load)          ┌──────────────┐
   rename ──────────────────────────────────────────▶│              │
   CDB lane0 / lane1 / MSHR record (VA + PA + size) ─▶│  load_queue  │── o_poison_head  ─┐
   store resolve (rob_idx, VA, PA, size) ───────────▶│  LQ_N entries │── o_poison_head1 ─┤
   remote invalidate / evict (PA line) ×4 ──────────▶│  head / tail  │                   │
   MSHR abort poison ×2 ────────────────────────────▶│  age-ordered  │                   ▼
   commit / flush / partial squash ─────────────────▶│              │            rob commit gate
                                                     └──────────────┘
```

- **Entry**: `{ valid, rob_idx, done, va, pa, pa_valid, size, poison }`. Allocated **in program
  order at dispatch** for every op with `dec_op.is_load` (= `mem_ren`, `decode.veryl:223` — a
  superset of every op that can later record: `alu_wrap.veryl:441` gates the CDB record with the
  same `base.is_load`, and the MSHR record is a load miss). Freed **in order at commit**, up to 2
  per cycle (`c2_simple` permits a load in commit slot-1).
- **Age** is the queue's own order. Comparisons against a *store* still need the ROB's `head_idx`,
  because stores live in the ROB shadow (that is L1, the SQ half, which was never built either —
  the ROB's exported `o_store_*` arrays stand in for it, and the interface says so).
- **Depth** `LQ_N` is a real parameter. It starts at **32** = ROB_DEPTH so the queue can never fill
  and the flip measures the *structure* alone; the depth sweep (8 / 16) is a separate, honest
  measurement of what this machine actually needs, run afterwards.
- **Squash** rewinds `tail` to the first entry younger than the branch — a prefix count over the
  survivors, the queue analogue of the ROB's `squash_new_tail`.

### L3.2.2 — increments (each DEAD at `LQ_REAL = 0`, flip last)

| step | content | gate |
|---|---|---|
| **a** | the queue substrate: alloc / free / flush / squash, records, no scans, outputs unread | `veryl test` 252/0 + **membership equivalence vs the ROB shadow proven over a full boot** |
| **b** | the three scans re-derived in the LQ + a per-cycle divergence trap vs the ROB's decisions | boot with **0 divergences** |
| **c** | flip: `o_commit_load_poison` / `c2_simple` sourced from the LQ | full ladder: 252/0, dhrystone, N=1, litmus N=2/N=4, N=2 SMP |
| **d** | PA-exact records + exact overlap when both PAs are valid (closes gap 3 above) | same ladder + the CoRR-under-VM argument re-checked |

**DEAD criterion is the f2.5a one, not "byte-identical":** Veryl 0.20.2 does not fold
`else if CONST_FALSE` at SV-text level, so the standard is *existing SV preserved verbatim (the diff
is pure addition) + every addition const-gated and unread*. A new module that nothing reads meets it.

**Predictions, written before the measurement** (so they can be scored, per the campaign rule):
`c` moves cycles by **< 0.5 %** in either direction and is expected to be **exactly bit-identical**,
because at `LQ_REAL=1` the LQ recomputes the same poison decisions from the same inputs — anything
else is a bug, not a result. `d` is bounded by L3.1's 0.41 % and will land **below** it, since a
sound PA-exact test only fires where both PAs are valid. The one thing `d` genuinely buys that no
counter shows is CoRR correctness under Sv39.

### L3.2a/b — BUILT, DEAD, AND PROVEN EQUIVALENT ON A FULL LINUX BOOT

`src/core/load_queue.veryl` (new module, instantiated in `heliodor_core` next to `rob`). It allocates
at dispatch on `dec_op.is_load`, frees up to two entries at commit, rewinds on partial squash by a
survivor count, empties on flush, records at the ROB's three record sites verbatim, and re-derives
all three scans (store-resolve / S15 self / CoRR invalidate) with **bit-identical arithmetic**. The
ROB gained four pure-addition outputs — `o_lq_rec_set`, `o_lq_pois_set`, `o_store_known` — and the
`LQ_REAL` flip mux; nothing existing changed.

**The check is the deliverable, not the code.** Every cycle the queue compares its own state against
the shadow arrays it is meant to replace, in both directions:

| check | what a hit would mean | N=1 boot |
|---|---|---|
| record with no LQ entry (`orphan`) | the dispatch alloc predicate is not a superset of the recorders | **0** |
| executed-load set != the ROB's | alloc / free / squash diverges | **0** |
| poison set != the ROB's | one of the three scans differs | **0** |
| push into a full queue | LQ_N too small | **0** |
| alloc in a squash/flush cycle | the "alloc never coexists with squash" assumption is false | **0** |

Set equality is proven as *containment + equal cardinality* (3 × 32 compares), not a 32 × 32 matrix:
the matrix is exact too but costs 1024 compares per simulated cycle, and this runs for 13.58 M of
them. Containment is a dynamic read of the reference vector by the entry's own `rob_idx`.

**Gates:** `veryl test` **252/0** · N=1 Linux boot **`cy=00cf36e0`, `x3=0xaa`, matching the shipped
Block-W baseline** (at the harness's 10,000-cycle print granularity — see the resolution note under
L3.2c; the queue being *unread* is the real proof it is dead) — and the boot is the
run that matters because all three scans are Sv39-only (L3.0: 19,539 poisons / 16,496 replays there,
**0** on the bare microbenchmarks).

🎯 **Measured, and it is the answer to "what depth?": the high-water occupancy of a full Linux boot
is 16 of 32** (8 across the whole arch + litmus suite). So `LQ_DEPTH = 8` — the number that has sat
unread in `pipeline_pkg` since it was written — **would have been too small**, and 16 is the honest
size for this machine. The queue ships at 32 (= ROB_DEPTH, cannot fill) so that the flip measures the
structure and nothing else; depth is a separate experiment, and it now has a measured starting point
instead of a guess.

**Two assumptions were converted into measurements rather than left as comments:** that
`dec_op.is_load` is a superset of every op that can record (orphan = 0 over a boot), and that
dispatch never coexists with a squash (0 over a boot). Both are load-bearing for the queue's
pointers, and both were previously only implied by other modules' gating.

### L3.2c — FLIPPED. Bit-identical, exactly as predicted, and the shadow keeps agreeing.

`LQ_REAL = 1` (one `const` in `heliodor_core`, passed as a **param** to both `rob` and the queue —
the `ras::PRED_AHEAD` form, not the duplicated-const form that made `rob::PRED_OVERRIDE` a hazard in
3a.5). At 1 the ROB's `o_commit_load_poison` and its commit-slot-1 gate read the queue instead of
`sh_load_poison`. Build clean, **no comb loop** (the queue's outputs are FF-derived, so the
core→queue→rob→core path has no cycle).

| gate | `=0` (shipped) | `=1` (flip) |
|---|---|---|
| `veryl test` | 252/0 | **252/0** |
| dhrystone (exact counters) | 237,827 cy / instret 264,834 | **237,827 / 264,834 — bit-identical** |
| N=1 Linux boot | `cy=00cf36e0` | **`cy=00cf36e0`** |
| N=2 SMP Linux boot | `cy=01154090` | **`cy=01154090`** |
| litmus N=2 / N=4 | `cy=002e6300` / `cy=003c6cc0` | **`cy=002e6300` / `cy=003c6cc0`** |
| **per-cycle equivalence vs the shadow** | 0 divergences | **0 divergences** |

⚠️ **Read those `cy` figures at the right resolution.** The boot and litmus harnesses advance the
clock in **10,000-cycle chunks** (`clk.next(10000)` in `tb/test_litmus.veryl`, "poll in 10000-cycle
chunks" in `tb/test_soc_linux_boot.veryl`), so their reported `cy` is quantised to 10,000 — a match
there means |Δ| < 10,000 (< 0.07 % at N=1), **not** bit-exactness. This applies to every boot/litmus
number this campaign has ever quoted, including the Block-W table above. Only dhrystone/coremark
report an exact cycle count, and those are bit-identical here.

**The strong evidence for this flip is not the cycle print — it is the checker**: the ROB shadow was
left running as a live reference, and its executed-load set and poison set agreed with the queue's
**every cycle, with zero divergences**, across the whole suite, the N=1 boot, the N=2 SMP boot and
litmus N=4, while the queue was the authority. That is a per-cycle equality proof over ~50 M
simulated cycles, which the 10,000-cycle `cy` print could never give.

Reverted to `=0` for ship-safety at the time of measurement; **whether `LQ_REAL=1` becomes the
default path is the user's call**, as it was for `ATOMIC_SQ` and `LSR_MSHR_B`.

**The prediction written before the measurement was "< 0.5 % in either direction, expected exactly
bit-identical". It is exactly bit-identical**, on both workloads, which is the only honest outcome:
the queue recomputes the same decisions from the same inputs. A cycle difference here would have
been a bug, not a result.

The interesting property of this flip is that it is **self-validating**: the ROB shadow is left
running as a live reference, so at `=1` the machine is simultaneously using the new structure and
proving it agrees with the old one, cycle for cycle. That check is what makes the eventual deletion
of the shadow arrays a mechanical step rather than a leap.

### L3.2d — PA-exact records: built DEAD, and the COVERAGE is measured first

The queue carries both addresses per entry (`va`, `pa`, `pa_valid`), and every scan has an exact arm
that fires only where both sides have a PA: the store-resolve scan against `store_pretx_pa` (L2's
pre-translate probe, live on the resolving store's own cycle), the record-time self-scan against the
ROB's per-entry `sh_store_pa`, and — the one that is a correctness fix rather than a precision one —
the CoRR line compare, which is a **VA-vs-PA compare today** and therefore silently never matches
under Sv39. `LQ_PA_EXACT = 0` keeps every one of those folded to today's arm.

**The coverage is measured before the arm is switched on** (the f2.16 rule: an increment whose
target population is small should die before a line of it is enabled). Counters: `rec` (cycles with
a record), `pa_rec` (…carrying an exact PA), `exact` (store-resolve cycles decided PA-to-PA), `saved`
(poisons the approximation raises that the exact test does not), `invnopa` (a line leaves the L1
while an executed record has no PA — the residual hole).

🚩 **First measurement: 45,349 / 1,613,658 = 2.8 %.** Almost no record carried a PA — and the reason
was a wiring mistake this measurement is exactly designed to catch: **a plain integer load writes
back on LANE 1**, not lane 0 (`lsr_to_lane1 = 1` for it, and `alu_cdb2 = lsr_lane1_fire ? lsu_cdb :
alu2_pipe_cdb`), and only the lane-0 record port had been given the PA. Guessing from the code would
have "confirmed" the lane-0 wiring; the counter refused it in one boot.

**After wiring lane 1: 1,606,011 / 1,613,658 = 99.5 % of load records carry an exact PA**, with the
N=1 boot still at `cy=00cf36e0` (recorded but unread at `LQ_PA_EXACT = 0`). The load side of the
exact test is therefore fully covered; what is left to measure is the store side and the prize.

**And the prize can be measured at zero risk** — worth stating as a method. Set `LQ_PA_EXACT = 1`
while leaving `LQ_REAL = 0`: the ROB shadow is still the authority, so the machine executes the OLD
policy and the cycle count cannot move, while the queue running alongside reports what the NEW
policy would have decided (`saved` = poisons the approximation raises that the exact test does not;
the poison-set divergence counter is the same number seen from the other side). A policy change that
is normally flip-and-pray becomes an observation.

**Result of that observation, N=1 boot (`cy=00cf36e0`, unchanged as designed):**

| | at 4.19 M cy | at 8.39 M cy | at 12.58 M cy |
|---|---|---|---|
| store-resolve cycles decided PA-to-PA | 13,051 | 39,684 | 71,494 |
| **poisons the exact test would AVOID** | **14** | **41** | **63** |
| load records carrying a PA | 501,526 / 501,749 | 1,032,571 / 1,035,974 | 1,606,011 / 1,613,658 |
| executed-load set vs the ROB's | 0 divergences | 0 | 0 |

🎯 **~63 avoided poisons against the boot's 19,539 — 0.35 % of them.** The precision half of the
PA-exact idea is therefore **measured dead**, and it died *below* the bound L3.1 set (0.41 % of
cycles), exactly as this document predicted before the run. Note what that also says about the
census's own framing: the S15 self-scan's 13,083 "VA alias suspicion" poisons are **not**
false positives waiting to be cleaned up — where an exact PA compare can be made, it almost always
agrees with the conservative answer.

**What survives is the CoRR correctness fix, and it is not measurable at N=1** — a single hart
receives no invalidates at all (`invnopa = 0` for that reason, not a good one). That measurement
needs N ≥ 2.

**N=2 SMP boot, same zero-risk configuration** (`LQ_PA_EXACT=1`, `LQ_REAL=0`), full boot,
`cy=01154090` = 18,170,000 unchanged, per hart (each has its own queue):

| | hart 0 | hart 1 |
|---|---|---|
| load records carrying a PA | 1,678,464 / 1,781,996 = **94.2 %** | 2,090,360 / 2,106,145 = **99.3 %** |
| store-resolve cycles with a pre-translated store PA | 339,346 / 1,088,552 = **31 %** | 840,346 / 2,157,839 = **39 %** |
| cycles with a PA-carrying known older store | 1,695,544 / 5,937,276 = **29 %** | 3,543,513 / 5,071,828 = **70 %** |
| store-resolve cycles decided PA-to-PA | 109,496 | 105,576 |
| **poisons the exact test would avoid** | **5** | **99** |
| executed record with NO PA when a line leaves the L1 (`invnopa`) | **38** | **78** |
| executed-load set vs the ROB's | **0 divergences** | **0 divergences** |

⚠️ **Correction to the 4.19 M-cycle sample read earlier in this session: `invnopa` is NOT 0 over a
full boot — it is 38 + 78 = 116.** A partial sample said zero and the honest number is small but
nonzero, so the claim "sound for essentially every record" has to be stated as: the exact arm closes
the CoRR hole for the ~94-99 % of executed records that carry a PA, and **a residual 116 cycles per
2-hart boot remain where a line leaves the L1 while an executed record has none**. Closing that
last part needs the record to carry a PA unconditionally, which is a separate change.

Two things fall out. **The store side is the coverage bottleneck** (37 %, because L2's pre-translate
probe declines on `!dmem_sprobe_ok` / pending-xlate / `store_drive`), not the load side (99.9 %) —
so anyone tempted to revisit precision should go after `store_pretx_valid`, not the load record. And
**even where the exact test does run, it almost always agrees**: 12,584 exact decisions bought 14
avoided poisons. The conservative test is not sloppy; it is nearly right.

**The CoRR fix is the part worth shipping, and it is nearly — not entirely — complete.** Turning
`LQ_PA_EXACT` on makes the remote-invalidate line compare sound for the 94-99 % of executed records
that carry a PA, against a compare that today matches nothing at all under Sv39. The residual is the
116 cycles above. That ships for correctness, not for cycles, and the remaining hole is a known,
quantified follow-up rather than an unknown.

### 🏁 L3.3 SHIPPED — `LQ_REAL = 1` + `LQ_PA_EXACT = 1` are the default path

User decision, 2026-08-16: ship both. `LQ_CHECK` goes to **0** at the same time — the equivalence
counters and their 3 x 32 compares are verification hardware, and a scaffold is only dead if the
const can fold it (the `CAPB_BUDGET` lesson). The equivalence itself is already proven, at `=0` and
at `=1`, over ~50 M simulated cycles; and with the exact arm on, the shadow is *supposed* to
disagree, so the check has done its job.

| gate | baseline | shipped (both = 1) |
|---|---|---|
| `veryl test` | 252/0 | **252/0** |
| dhrystone (exact) | 237,827 cy / instret 264,834 | **237,827 / 264,834 — bit-identical** |
| N=1 Linux boot | `cy=00cf36e0` | **`cy=00cf36e0`** |
| litmus N=2 | `cy=002e6300` | **`cy=002e6300`** |
| litmus N=4 | `cy=003c6cc0` | **`cy=003c6cc0`** |
| **N=2 SMP Linux boot** | `cy=01154090` = 18,170,000 | **`cy=01165200` = 18,240,000 — +0.39 %** |

**The one number that moved is N=2, and it moved the direction the correctness fix predicts.**
Everything single-hart and every bare-mode test is unchanged; the SMP boot — the only gate with
remote invalidates AND translation on — costs 0.39 %. The only mechanism in this change that can
*add* poisons is the CoRR arm: it now compares PA to PA, so it starts catching remote-write cases
that the VA-vs-PA compare silently missed, and each catch is a replay. N=1 has no invalidates at all
and is unchanged, which is consistent with that reading. (Not separately instrumented — `LQ_CHECK`
is off in the shipped build — so this is the coherent explanation, not a measured attribution.)

**The cost scales with hart count, and that is the strongest evidence for the mechanism.** The N=4
SMP boot came in at `cy=01985340` = **26,760,000 vs 26,440,000 = +1.21 %**, pass=1. So:

| | N=1 | N=2 | N=4 |
|---|---|---|---|
| cost of the shipped config | **0 %** | **+0.39 %** | **+1.21 %** |

Monotone in the number of harts, which is exactly the shape a coherence-correctness fix has: more
harts, more remote invalidates, more of the previously-missed cases now caught, more replays. A
constant overhead (extra logic in a hot path) would not look like this, and a single-hart machine
pays nothing at all.

**That is the trade this block ships: 0 / 0.39 / 1.21 % by hart count, for a memory-model hole that
has been open since VM support landed.** The precision half that L3.2d measured dead buys nothing
back, as predicted.

**New default baselines**: N=1 `cy=00cf36e0` / N=2 `cy=01165200` / N=4 `cy=01985340` /
litmus N=2 `cy=002e6300` / litmus N=4 `cy=003c6cc0` / dhrystone 237,827 / instret 264,834 / 252/0.

**Verilator NBA cross-check: 4/4 PASS**, every one built from scratch. Its exact counts also
confirm the 10,000-cycle quantisation of every Veryl harness number — each lands inside the bucket
the Veryl sim reported:

| | Verilator (exact) | Veryl sim (quantised) |
|---|---|---|
| N=1 Linux boot | **PASSED, cy=13,575,874** | 13,580,000 ok |
| N=2 SMP Linux boot | **PASSED, cy=18,233,239** | 18,240,000 ok |
| litmus N=4 | **PASSED, cy=3,952,044** | 3,960,000 ok |
| N=4 SMP Linux boot | **PASSED, cy=26,750,722** | 26,760,000 ok |

The litmus N=4 figure 3,952,044 is **the same number to the cycle as the pre-L3 Block-W run** - the
RVWMO battery is bit-identical under the new structure, on the NBA semantics that matter.

### Do NOT delete the ROB shadow — at the shipped setting it is already gone

The obvious follow-up after L3.3 is "now remove the shadow arrays, so the structure is a replacement
rather than a duplicate". Checked, and the answer is **no**. At `LQ_REAL=1` / `LQ_CHECK=0` /
`DBG_CENSUS=0` the complete reader set of `sh_load_done/addr/funct3/poison` is:

| reader | state when shipped |
|---|---|
| `o_commit_load_poison`, `c2_simple` | the **unselected** arm of `if LQ_REAL ? queue : shadow` |
| `o_lq_rec_set` / `o_lq_pois_set` | consumed only by the queue's `LQ_CHECK` block — folded at 0 |
| the three scans themselves | their only sinks are the two rows above and the DBG_CENSUS counters |

So the 4 × 32 arrays and the three 32-wide scans have **no live consumer in the shipped netlist**;
synthesis removes them. Deleting them from the source would buy zero gates and would destroy the
`LQ_REAL=0` fold-away fallback this campaign deliberately keeps (the `ATOMIC_SQ=0` / `LSR_MSHR_B=0`
precedent). The duplication is source-level only, and source-level duplication that a const can fold
is exactly what the campaign's DEAD-scaffold discipline asks for.

## NEXT BLOCK — memory dependence prediction + selective replay: hand-off for a clean context

Written to be self-contained, the way the L3 hand-off was. Start here.

### Where the machine is now

Block L3 shipped (`633a74f`): loads have a **first-class age-ordered queue**
(`src/core/load_queue.veryl`, a peer of the ROB), allocated at dispatch, freed at commit, holding
`{rob_idx, done, va, pa, pa_valid, size, poison}` per entry, and it is the authority for the
commit-side load poison. High-water occupancy on a Linux boot is **16 of 32**. The ROB shadow arrays
still exist in source as the `LQ_REAL=0` fallback but are absent from the shipped netlist.

**Recovery is still the pre-OoO model.** A poisoned load sets `o_commit_load_poison`; the core turns
that into `commit_load_replay` — a **full redirect + refetch of that load and everything younger**
(`heliodor_core.veryl`, search `commit_load_replay`). Nothing replays selectively, and nothing
predicts. That is the gap this block is about, and it is the last item on the modern-OoO list that
the memory system actually owns.

### What the L3 measurements already settled — do NOT re-derive

1. **The conservative poisons are mostly REAL.** L3.2d put an exact PA compare next to the
   approximate one and let it run a full boot: of ~19.5 k poisons, the exact test would avoid **63**
   (0.35 %). So the population is not full of false positives waiting to be filtered — *making
   disambiguation more precise is a dead lever, and it has been measured twice now* (L3.1: 0.41 %
   ceiling; L3.2d: 0.35 % of poisons).
2. Therefore the two live levers are **(a) don't speculate into the conflict** (a dependence
   predictor) and **(b) make the recovery cheaper** (selective replay). They attack different halves
   of the same event and can be built independently.
3. **Volumes need re-censusing.** The 19,539 poisons / 16,496 replays figures are from the
   *pre-Block-W* N=1 boot (14.6 M cycles). The default is now 13.58 M cycles with a 32 KB L1I, 2-wide
   rename for control ops and the PA-exact scans. Re-measure before sizing anything.
4. **The queue is the place to hang both.** A dependence predictor needs "which store did this load
   conflict with, last time" keyed by load PC; selective replay needs "re-execute exactly this entry"
   — and the LQ entry is the only structure that now knows both the load's identity and its address.

### The campaign rule that applies hardest here

⚠️ **A stall/event census tells you WHERE, never HOW MUCH.** The tally so far: L3 over-predicted by
3-5x, L4 step-2 by infinity (7.14 % bucket → 0 cycles), W1a by ~40x (8.3 % → 0.21 %). Price every
increment by **building it DEAD and flipping it**, never by multiplying an event count by a cost
band. And for a policy change, remember the trick L3.2d used: run the new policy's decision logic
alongside the old one with the old one still in authority — the machine cannot move, and the queue
reports what the new policy *would* have decided. That turns a flip-and-pray into an observation.

⚠️ **Boot/litmus `cy` is quantised to 10,000** by the harness poll loop. Only dhrystone/coremark
report exact cycles. For per-cycle equality claims, put a checker in the RTL (that is how L3 proved
~50 M cycles of set equality).

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

## Block M — the replay is PRICED, and one of the two levers is measured dead (2026-08-16)

The hand-off above named two live levers — (a) do not speculate, (b) make recovery cheap — and
required the volumes to be re-censused before anything was sized. This block did that, and then did
the thing the campaign keeps having to learn: it measured **cycles**, not events.

### M0 — what one commit-time load replay actually costs

Census buckets 60-73 (`heliodor_core.veryl`, `DBG_CENSUS`). Method: open a window at the replay
redirect, latch the load's PC, close it when that PC commits again; charge a trap-interrupted window
to its own bucket. N=1 boot, `cy=00cf36e0` = 13,580,000 — **bit-identical to the default**, so the
instrumentation does not perturb the machine it measures.

| | |
|---|---|
| replay events | **19,757** (dedup exactly matches `load_replay_cnt`, so the redirect is a 1-cycle pulse) |
| **total recovery cycles** | **180,895 = 1.33 % of the boot** |
| per event | **9.15 cy** (worst clean window 76) |
| ROB entries squashed per event | **9.94** (`squashsum` 196,419) |
| windows: clean / trap / runaway | 19,756 / 1 / 0 — the accounting closes |
| poison sources | store-resolve 14,797 · **self-scan 7,686** · MSHR-abort 128 · CoRR 0 |

**M0b — the window splits into the half a selective replay deletes and the half it still pays**:
redirect → the same PC back at rename = **79,208 cy (4.01 cy/event)**; the remaining
**101,687 cy (5.15 cy/event)** is re-issue → re-execute → re-commit, which a selective replay still
owes.

### M1 — lever (a), "don't speculate", is DEAD. The RTL already had the arm.

`rob.veryl:781 s9_speculate_en` has been a global "loads never pass an unknown-address store" switch
since Phase 8 S9.4. Flipping it to 0 is the strongest possible dependence predictor — one that is
right about every load, for free — so it **upper-bounds every predictor of this shape**:

| | default | `s9_speculate_en = 0` |
|---|---|---|
| cycles | 13,580,000 | **13,670,000 (+0.66 %)** |
| store-resolve violations | 14,797 | **0** |
| **self-scan violations** | 7,686 | **18,273 (+10,587)** |
| replay events | 19,757 | 18,024 |
| **recovery cycles** | 180,895 | **163,368 (−17,527 only)** |

🎯 **Blocking the load does not prevent the violation — it changes which detector raises it.** Holding
the load until older stores resolve makes those stores *known*, and the record-time self-scan then
fires on the same dynamic loads: **72 % of the eliminated store-resolve violations came back as
self-scan violations.** So the whole lever is worth at most **17,527 cy = 0.13 %**, and its global
form is a measured **+0.66 % regression**. A per-PC predictor cannot beat the global arm at avoiding
violations (the global arm blocks a superset), so the ceiling holds for the selective version too.

⚠️ Note what this kills: the hand-off's "the two live levers are (a) and (b)" is now **one** lever.
Precision was measured dead twice (L3.1, L3.2d); not-speculating is measured dead here.

### M1b — the end-to-end price of a replay, and the calibration that validates M0

`S15_SELF_SCAN` (the record-time self-scan) is an existing measurement-only arm — unsound to ship,
since a genuine VA alias would go unreplayed. Removing it deletes a whole poison population, so the
cycle delta prices a replay end-to-end, including the squashed younger instructions that M0's window
cannot see:

| | default | self-scan off |
|---|---|---|
| cycles | 13,580,000 | **13,460,000 (−0.88 %)** |
| replay events | 19,757 | 8,650 |

**120,000 cy / 11,107 events = 10.8 cycles per replay, end to end** — against M0's window figure of
9.15. The two methods agree within 15 %, which is the first time in this campaign that a census
number converted to cycles at face value (L3 3-5×, L4 step-2 ∞, W1a ~40× over). **It converted
because this census counted cycles, not events.** Total cost of the phenomenon:
19,757 × 10.8 ≈ **213,000 cy = 1.57 % of the boot** — that is the ceiling for Block M *entire*.

⚠️ **Trap paid for again, in one flip:** `S15_SELF_SCAN` exists in BOTH `rob.veryl` and
`load_queue.veryl` and the comment says they are flip-coupled. Flipping only `rob.veryl`'s gave a
**bit-identical** boot — because L3.3 shipped `LQ_REAL=1` and the ROB's copy is dead code. Useful
confirmation of L3.3's claim; a wasted run all the same.

### M1c — what the self-scan poisons ARE (buckets 74-77, `load_queue.veryl` outputs)

The 0.88 % looked like a precision problem, so it was asked the L3.2d question — when the self-scan
fires, did it decide PA-to-PA or fall back to the 13-bit page-offset approximation?

| self-scan poisons, N=1 boot | |
|---|---|
| fired | **7,627** |
| ...decided **PA-to-PA** | **7,378 (96.7 %)** |
| ...decided by the approximation (no PA pair) | **249 (3.3 %)** |
| ...PA attribution failures (`pa[11:0] != va[11:0]`), load side / store side | **0 / 0** |

Two conclusions, and they point opposite ways:

1. **Precision is dead here too.** Only 249 poisons ride the approximation; a better address supply
   is worth 249 × 10.8 ≈ 2.7 k cycles = **0.02 %**. That is the third precision measurement in this
   campaign and the third zero.
2. 🎯 **The other 7,378 are REAL physical overlaps between an executed load and an older in-flight
   store whose VAs differ — genuine VA aliases.** The attribution check confirms both PAs belong to
   their own access (L3.2d's `lsr_v_q && lsr_rob_idx_q == cdb.rob_idx` gate holds, 0 failures), so
   this is not a stale-address artefact. These loads really did read bytes an older uncommitted store
   owns, and **the store-to-load forward network could not serve them because it is keyed on VA**
   (`o_store_fwdable` + the alu_wrap byte merge compare full VAs; the self-scan's own S16 exemption
   is exactly "a full-VA overlap was forwarded, so only the alias case still poisons").

⚠️ So `S15_SELF_SCAN=0` is genuinely unsound, as its comment says — its −0.88 % is **not bankable**,
and a boot passing without the scan proves nothing (those 7,378 stale reads simply did not happen to
kill this kernel).

### Where that leaves the block

| lever | measured ceiling | verdict |
|---|---|---|
| (a) dependence prediction | **0.13 %** (global arm: **−0.66 %**) | **DEAD — do not build** |
| (b) selective replay | **0.58 %** (refetch half) … ~0.8 % with the squash waste | alive; large build (re-issue from the LQ, dependent re-wakeup, a ROB that does not squash) |
| (c) disambiguation precision | **0.02 %** (249 events) | **DEAD** (third zero) |
| (d) **PA-keyed store→load forwarding** | **~0.6 %** (7,627 events × 10.8 cy), sound | alive; it is also the endpoint L3 named — "fold forwarding into one SQ CAM" |

Block M's ceiling *entire* is **1.57 %**, and (b) and (d) are complementary rather than additive:
(d) deletes 39 % of the replay events at the source, (b) makes whatever remains cheaper.

**(d) is the recommended next build.** It is sound, its population is measured, and it is the one
item on the modern-LSQ list this machine still does not have: the byte merge lives in `alu_wrap` at
AGU time, where only the VA exists, so the work is to move (or mirror) it to the stage that holds
`lsr_paddr_q` and `sh_store_pa` — the same PA pair the disambiguation scans already use.

⚠️ Both remaining levers are worth under 1 %. For comparison, the post-Block-W re-census above still
has `lsr`→**`lane0` at 705,559 cy = 5.2 %** unbuilt, and `storeamo` ineligible-on-slot-1 at
1,600,337 cy. Pick this block for structural completeness (the reason L3 shipped), not for cycles.

### M2 — building lever (d), and what building it actually found

The plan was to key the uncommitted store→load byte network on physical addresses, the way the
committed (`sbf*`) half already is. That is a small, local change — the network is evaluated at
Stage B, which holds `lsr_paddr_q` for the load and `ls_pa[i]` (L2's `STORE_PRETRANSLATE`) for every
store — plus the mirror-image change to the self-scan's S16 exemption, which is a statement about
that same key. Both were built const-gated (`FWD_PA`, flip-coupled across the two files) and DEAD at
0 was verified bit-identical (252/0, `cy=00cf36e0`, instret 10,431,242).

**The flip was bit-identical too** — the fifth time in this campaign. Chasing "why was it not
reached" rather than re-deriving the design is what found the actual defect:

| self-scan poisons, N=1 boot, by record port | |
|---|---|
| port 0 (lane-0 CDB record) — the port the S16 exemption is written for | **0** |
| port 2 (MSHR fill capture) | 2 |
| **port 1 (lane-1 CDB record)** | **~7,627, i.e. all of them** |

Port 1's own comment reads *"lane-1 CDB, bare-only today, kept for symmetry"*, and it has **no
exemption at all** — it poisons on ANY overlap. That comment went stale when L4 step-1.5 routed the
LSR's completion to lane 1 (`lsr_to_lane1`: fault/FP loads stay on lane 0, **everything else goes to
lane 1**). So since L4, the port carrying ordinary VM loads has been poisoning loads the byte network
had **already served** — a full commit-time replay each, for bytes that were correct in the register
file.

### M2a — give port 1 the exemption. **−1.03 %.**

| | default | `P1_SERVED=1` |
|---|---|---|
| default suite | 252/0 | **252/0** |
| **N=1 boot** | 13,580,000 (`00cf36e0`) | **13,440,000 (`00cd1400`) = −1.03 %** |
| replay events | 19,757 | **11,145** |
| replay recovery cycles | 180,895 | **102,733** |
| poisons suppressed | — | 16,556 |

Bigger than the −0.88 % the *unsound* `S15_SELF_SCAN=0` arm bought, because removing the poison at
the source also removes the store-resolve violations the replays themselves caused.

Two things make the exemption sound rather than plausible, and both were added after measuring:

1. **The identity guard `i_rec1_pa_valid`** (= `lsr_v_q && lsr_rob_idx_q == alu_cdb2.rob_idx`). With
   it the exemption is not an argument but a term-for-term identity with the network's coverage
   predicate: same forwardable set (`i_store_fwd` = the net's `ls_fwd`), same age test (the ages are
   equal exactly when the rob indices are), same address, same cycle.
2. **An interlock against the network's own mask.** The scan computes the byte mask this store
   covers and suppresses only if it is a subset of `sf_rob_mask` (the ROB half of the live forward
   mask — the committed store buffer is a different question). The exemption therefore cannot claim
   more than the datapath delivered, whatever anyone believes about the identity above.

⚠️ **One open item, deliberately left visible.** A counter placed in the CORE reports 3 suppressions
(of 16,556) on cycles where `sf_rob_mask` reads 0; the SAME question asked INSIDE the load queue,
where the mask is a port read, reports **0**. Two readers of one combinational signal, same cycle,
different answers — so it is a sampling artefact rather than 3 unserved loads, and the interlock the
LQ actually decides with is the one reading 0. **Verilator arbitrated: the N=1 boot PASSES under SV
NBA at `$finish` 134 ms** (default 135.75 ms), i.e. the improvement is real under proper NBA
semantics and the suppression does not break the boot on the reference simulator. The disagreement
itself is a Veryl-sim scheduling detail worth a separate look, not an RTL hole.

### M2b — the PA key itself is worth **exactly zero**

With the port-1 exemption in place, `FWD_PA=1` gives a **bit-identical** boot: same cycles, same
11,145 replays, same 16,556 suppressions.

🎯 **So M1c's reading was wrong, and the flip is what corrected it.** "96.7 % decided PA-to-PA with 0
attribution failures" was true, but the inference — *therefore they are VA aliases the network cannot
serve* — silently imported port 0's structure (`&& !a0_vaovl`) into port 1, which has no VA test at
all. Those poisons had overlapping VAs the whole time. The PA key stays in-tree at 0 as a fold-away
arm, with the measurement recorded next to it.

**Lever (d) was therefore worth ~1 % — but not for the reason it was chosen.** What the block
actually found is a latent over-poisoning bug that L4 step-1.5 introduced and no gate caught, because
a spurious replay is invisible to every correctness test and only shows up in cycles.

### M2a gates (default = the post-L3.3 baselines)

| gate | default | M2a | Δ |
|---|---|---|---|
| default suite (incl. litmus N=2) | 252/0 | **252/0** | — |
| **N=1 boot** | `00cf36e0` 13,580,000 | **`00cd1400` 13,440,000** | **−1.03 %** |
| **N=2 SMP boot** | `01165200` 18,240,000 | **`011567a0` 18,180,000** | **−0.33 %** |
| dhrystone | 237,827 / instret 264,834 | **237,827 / 264,834** | bit-exact |
| coremark | 404,355 / instret 374,357 | **404,355 / 374,357** | bit-exact |
| **litmus N=4** | `003c6cc0` | **`003c6cc0` pass=1** | **cycle-identical** |
| **N=4 SMP boot** | `01985340` 26,760,000 | **`019d3540` 27,080,000 pass=1** | ⚠️ **+1.20 %** |
| **Verilator NBA, N=1 boot** | 135.75 ms = 13,575,874 | **134 ms, PASSED** | reproduces under SV NBA |
| **Verilator NBA, N=2 boot** | 182.3 ms = 18,233,239 | **182 ms, PASSED** | (ms resolution cannot see 0.33 %) |
| **Verilator NBA, litmus N=4** | cy = 3,952,044 | **cy = 3,952,044, PASSED** | **exact same cycle** |
| **Verilator NBA, N=4 boot** | — | **cy = 27,073,544, PASSED** | inside the Veryl sim's 27,080,000 bucket |

**Verilator NBA cross-check: 4/4, all PASS** — the same standard R3, L3.3 and Block W shipped on. The
N=4 regression is confirmed by the reference simulator, not an artefact of the Veryl sim: 27,073,544
lands exactly inside the 10,000-cycle bucket the Veryl harness reports as `019d3540`.

⚠️ **This is not a free win, and the shape says so: −1.03 % / −0.33 % / +1.20 % is monotone in hart
count.** The Veryl simulator is deterministic (same RTL + same image ⇒ same cycle count), so the N=4
figure is exact, not run-to-run noise; the "±1M band" in this document is about drift ACROSS changes,
not repeats. The natural hypothesis — untested, and labelled as such — is that a commit-time replay
was acting as an accidental **backoff**: the poisoned load and everything younger were thrown away
and re-run later, which under 4-hart contention reduces pressure on a contended line. Removing it
lets those loads proceed and bounce lines instead. That is the same shape L3.3 measured (+1.21 % at
N=4, 0 % at N=1) for a different coherence-correctness fix, and the mirror image of P9.3.B's
contended-atomic result.

Deciding what to do with that is a ship decision, not a measurement:

- **at 1** the machine is right (it stops replaying loads that were correct), 1 % faster per core,
  1.2 % slower at 4 harts;
- **at 0** it keeps a latent over-poisoning bug that costs ~8,600 spurious full replays per N=1 boot.

### 🏁🚢 M2a SHIPPED — `P1_SERVED = 1` is the default path (user decision, 2026-08-17)

Correctness of the mechanism wins over the 4-hart cycle count: the machine no longer replays loads
whose bytes the forward network had already delivered. The `=0` arm stays in-tree as a fold-away
fallback with its numbers recorded above, exactly like `ATOMIC_SQ=0` and `LQ_REAL=0`.

**New default baselines** (supersede the post-L3.3 set): N=1 `cy=00cd1400` · N=2 `cy=011567a0` ·
**N=4 `cy=019d3540`** · litmus N=4 `cy=003c6cc0` (unchanged) · dhrystone 237,827 / instret 264,834 ·
coremark 404,355 / instret 374,357 · suite 252/0.

⚠️ **The +1.20 % at N=4 is now a standing item, not a closed one.** It is the first measured case in
this campaign of a *correctness* fix paying a contention tax, and the backoff hypothesis above is
untested. If a later block wants those cycles back, the question to ask is not "undo M2a" but "what
is the replay doing for contention that nothing else does" — the same question P9.3.B answered from
the other side.

### ▶️ START HERE NEXT — hand-off for a clean context (2026-08-17)

**Block M is finished and shipped.** Everything above is measured, not planned. Read this section
and the `Block M` heading above it; nothing else in this document is required to resume.

**State of the machine.** `P1_SERVED=1` (`load_queue.veryl`) is the default path. Baselines:
N=1 `cy=00cd1400` · N=2 `cy=011567a0` · N=4 `cy=019d3540` · litmus N=4 `cy=003c6cc0` ·
dhrystone 237,827 / instret 264,834 · coremark 404,355 / instret 374,357 · suite 252/0 ·
Verilator NBA 4/4. Fold-away arms kept at 0 with their numbers recorded: `P1_SERVED=0` (the old
behaviour), `FWD_PA=0` (PA-keyed forwarding — measured worth *exactly zero*), `DBG_CENSUS=0` (the
80-bucket census, buckets 60-79 are Block M's).

**What is dead, so nobody re-derives it.** Dependence prediction (0.13 % ceiling, global arm
−0.66 %). Disambiguation precision (three separate zeros: L3.1, L3.2d, M1c). PA-keyed forwarding
(bit-identical). What survives in this area is **selective replay only**, and M2a cut its own ceiling
to ~0.3-0.5 % (11,145 replays × ~9.2 cy) for a large build.

**The two candidates, in the order the measurements support:**

1. **`lsr`→`lane0` port contention — 705,559 cy = 5.2 % of the N=1 boot, untouched.** The largest
   unbuilt item on the post-Block-W map, and structural rather than capacity (W3 proved doubling the
   L1D does not move it: 705,559 → 708,405). See `lsr_lane0_free` / `lsr_to_lane1`. ⚠️ This is the
   same lane routing M2a just found a stale assumption in — expect more of them.
2. **The N=4 contention tax** (+1.20 %, standing item above). Cheaper to *diagnose* than to fix, and
   a census there costs 90 minutes per run.

**Traps this session paid for, that generalise:**

- 🎯 **Split a multi-port mechanism by port before believing anything about its population.** M2's
  whole first day went into a design premised on port 0's condition structure while port 0 fires
  **zero** times; the exemption was missing on port 1. One counter per port would have found it
  immediately.
- **"Flip is bit-identical" is a measurement, not a dead end** — it happened three times today and
  each time the answer was one counter away.
- **A stale comment is load-bearing.** "bare-only today, kept for symmetry" survived L4 step-1.5 and
  hid the bug for a whole block.
- **`instret` is only a canary for changes that do not move cycles.** The boot's stream is
  timing-dependent through `rdtime`; M2a legitimately moves it by 0.03 %.
- **Flip-coupled constants exist** (`S15_SELF_SCAN` in both `rob.veryl` and `load_queue.veryl`,
  `FWD_PA` likewise). Flipping one gives a bit-identical run and wastes a boot.

The two microbenchmarks being **bit-exact** is the load-bearing check, not a null result: they run
bare, and the whole change is gated on `i_conservative` (Sv39 active). A change that moved them would
have been firing somewhere it must not.

⚠️ `instret` on the N=1 boot moves 10,431,242 → 10,428,249 (−0.03 %). That is expected here and is
NOT the canary failing: the boot's instruction count is timing-dependent through `rdtime` spin loops,
and the unsound `S15_SELF_SCAN=0` arm lands at 10,428,245 — the same ballpark — for the same reason.
`instret` is only a bit-exact canary for changes that do not move cycles.



## Block W — WIDTH. The machine is ~1-wide, and that caps everything above (2026-08-15)

**Why this block exists.** With F/S/L/R all shipped, an architecture-level review asked what is
missing versus a modern OoO. The answer is not in the memory system — L3 measured a 0.41 % ceiling
and L4 step-2 measured **zero** recoverable cycles from a 7.14 % stall bucket. Both came back empty
for the same reason: **the machine is rename-limited, not memory-limited.**

Rename is 2-wide on paper, but slot-1 takes only a simple integer ALU op:

```veryl
dec_op2_eligible = dec_op2.has_rd && !fp && !is_load && !is_store && !is_amo
                   && !is_csr && !is_branch && !is_jal && !is_jalr && !is_vec && ...
```

Measured IPC: dhrystone **1.005**, coremark 0.89, N=1 boot 0.71 — exactly what a 1-wide rename caps
at. Structure sizes match that scale: ROB **32**, PRF int **64**, IQ **8/8/8** (modern: ROB 200-600,
PRF 200-400, IQ 60-100+).

### W0 — the rename-width census (routing probe, `DBG_CENSUS` buckets 28-39)

N=1 boot, 14,600,000 cy. The four top-level states **partition exactly** (sum 14,598,965):

| state | cycles | of boot |
|---|---|---|
| rename fired **1-wide** | 6,883,844 | 47.1 % |
| rename fired **2-wide** | 2,200,786 | 15.1 % |
| instruction available, rename did not fire | 2,473,601 | 16.9 % |
| **front end empty** | 3,040,734 | 20.8 % |

Sole-blocker split of the 1-wide cycles (sums exactly to 6,883,844):

| blocker | cycles | of 1-wide |
|---|---|---|
| **slot-1 op INELIGIBLE** | 2,757,384 | **40.1 %** |
| multi | 2,387,633 | 34.7 % |
| no 2nd instruction in the FIFO | 1,261,868 | 18.3 % |
| **resource (ROB / free-list / IQ full)** | 476,959 | **6.9 %** |

Ineligible by class: **store/AMO 1,527,051 · branch 1,205,693 · load 1,100,640** · other 59,693.

### What the census changes about the plan

1. ⚠️ **Deepening ROB/PRF/IQ is NOT the first move.** Resource-full is the sole blocker on 6.9 % of
   1-wide cycles = **3.3 % of all cycles**. ROB 32 *is* shallow, but it only starts to bind once
   width actually exists — at ~1 IPC a 32-entry window is not the constraint. This also avoided a
   large edit: **sizing has no single source of truth** — `pipeline_pkg` and `decode_pkg` carry the
   consts, and `rob` / `rat` / `free_list` / `iq_int` / `iq_fp` / `prf_int` / `prf_fp` / `alu_wrap` /
   `lsu` / `fpu_wrap` each carry their OWN defaults, and **not one core instantiation overrides
   them**. They merely happen to agree at 32/64/8. Fix that before any resize.
2. **No single opcode class unlocks width** — the ineligible cycles split ~39/31/28 across
   store-AMO / branch / load.
3. **The front end is a second, independent axis** that was not in the original review:
   `front end empty` 20.8 % + `no 2nd in FIFO` 18.3 %.

### The three stages disagree about eligibility — and that is the map

| class | rename slot-1 | execute pipe-1 | commit slot-1 (`c2_simple`) |
|---|---|---|---|
| int ALU | ✅ | ✅ | ✅ |
| **control** (branch/JAL/JALR) | ❌ predicate only | ✅ **already built** (S3: "ALU/branch/JAL/JALR/LUI/AUIPC") | ❌ `!sh_is_control` |
| **load** | ❌ (no mem-IQ slot-1 alloc port) | partial (`lsr_to_lane1` writeback; the 2nd dcache read port is best-effort DENIED by `S3_SLOT1` at `DCACHE_DATA_READ_1R=1`) | ✅ **already allowed** |
| store/AMO | ❌ | ❌ | ❌ (commit is the memory ordering point) |

**⇒ Control transfers on slot-1 are the cheapest real width increment.** The execute pipe already
does them and `dec_op2_eligible`'s own comment says so ("Control transfers are excluded for now
(conservative first flip); a later milestone can admit them"). The ROB already carries
`i_cdb2_mispredict` / `i_cdb2_redirect_pc`. What is actually missing is two predicates plus the
commit-slot-1 next-PC handling — `c2_simple` excludes control because "the architectural next PC
after a slot-1 commit is just pc + (rvc ? 2 : 4)", which a taken branch breaks.

Loads are the opposite shape: commit already allows them, but the second dcache read port was
**traded away for the 1R1W SRAM**, so re-admitting them means banking the L1D — a big build.

### W1a — control transfers on rename slot-1: BUILT, FLIPPED, MEASURED

`W1_CTRL_SLOT1` (`heliodor_core.veryl`, at `dec_op2_eligible`). It turned out to be a **one-predicate
change**: everything downstream is not merely wired but **already exercised in the shipped design**,
because `iq_int`'s `pipe1_ok` excludes only load/store/amo/csr/fp/div — so control ops renamed on
SLOT-0 already issue on pipe-1 today. `u_alu2` is a full `alu_wrap`; `early_mispredict1` is exactly
symmetric with lane 0 (age-picked between lanes); `rob_alloc_entry2` already fills `is_control` /
`is_call` / `is_ret` / `pred_index` / `ghr_fold`, so predictor training is right; `i_rename_en2` and
`fl_pop_en2` are both `&& has_rd`, so a rd-less branch touches neither RAT nor free list; and
`sb_slot1_kill` kills slot-1 at the FRONT END when slot-0 is predicted taken, so the FIFO never
holds a wrong-path slot-1. DEAD at 0 verified bit-exact (252/0, `cy=00dec740`, instret 10434447).

| | `W1=0` | `W1=1` | Δ |
|---|---|---|---|
| **cycles** | 14,600,000 | **14,570,000** | **−0.21 %** |
| 1-wide rename | 6,883,844 | 5,754,483 | −1,129,361 |
| 2-wide rename | 2,200,786 | 2,776,763 | **+575,977 (+26 %)** |
| front end empty | 3,040,734 | 3,453,341 | **+412,607** |
| no 2nd in FIFO | 1,261,868 | 1,807,139 | **+545,271** |
| resource | 476,959 | 758,781 | +281,822 |
| **branch ineligible** | 1,205,693 | **0** | eliminated |

Suite 252/0 (incl. litmus N=2). Two independent runs agree on the cycle count.

**The flip fired perfectly and bought almost nothing, and the census says exactly why.** Renaming
26 % wider only **drained the fetch FIFO faster**: front-end-supply-limited cycles (`empty` +
`no2nd`) went **4,302,602 → 5,260,480, +958k**, absorbing essentially all of the 1,129,361-cycle
reduction in 1-wide rename. ⚠️ **The prediction in this plan — that commit (`c2_simple` excluding
control) or the 32-entry ROB would become the new limiter — was WRONG.** `resource` grew but stays
small. The limiter moved **upstream**, not downstream.

⚠️ **Third confirmation that a stall census does not convert.** L3 over-promised 3-5×, L4 step-2
over-promised ∞ (7.14 % → 0), W1a over-promised **~40×** (8.3 % → 0.21 %). Treat every future
bucket the same way: it says WHERE, never HOW MUCH.

W1a is banked at 0 — it is correct and it removes an arbitrary restriction outright, but 0.21 % does
not justify its own multi-hour ladder (litmus N=4 + N=2/N=4 SMP boots + Verilator NBA). Gate it
together with W2, which touches the same paths.

### W2.0 — the front-end census (buckets 40-51, measured at `W1=1`)

Both halves split, N=1 boot, `cy=00de5210`:

**Why the fetch FIFO is EMPTY at rename** (3,453,341, partitions exactly):

| cause | cycles |
|---|---|
| fetch not ready | 1,978,518 |
| ├ fetch-ahead FIFO empty (icache miss / I-PTW / run-ahead starved) | 1,593,317 |
| └ straddle (slow path) | 385,201 |
| fetch ready but FIFO still empty (produce→visible latency / skid) | 1,436,237 |
| redirect flush | 38,586 |

**Why slot-1 was NOT produced** on a cycle slot-0 was:

| cause | cycles |
|---|---|
| **straddle** | **2,035,379** |
| **cross-line (`s1_needs_next`)** | **895,789** |
| predicted-taken (structural: the block ends at a taken branch) | 946,952 |
| fb room held | 680,863 |
| *(slot-1 actually produced)* | *4,109,713* |

⚠️ **The dominant slot-1 loss is ALIGNMENT, not branches and not cache misses.** straddle +
cross-line = **2.93 M**, three times the predicted-taken term.

**And the straddle term looks recoverable by a predicate, exactly like W1a.** The fetch granule is
already a 64-bit dword with a next-dword peek (`wf_data: logic<64> [WF_N]`,
`wf_data[wf_head + 1]`), and:

```veryl
needs_straddle   = !straddle_q && ic_pc[1] && !curr_is_rvc   // 32-bit insn at a 2-byte offset
straddle_oneshot = needs_straddle && ic_rdata_nv && straddle_same_page
slot1_eligible   = fetch_ready && !straddle_q && !straddle_oneshot && !ic_ifault && slot1_pred_ok
```

`straddle_oneshot` is the case where **the next dword is ALREADY valid and same-page** — slot-0
costs no extra cycle, and slot-1 would start at `ic_pc + 4`, which is inside
`wf_head_next_data`, i.e. **data we already hold**. `slot1_eligible` kills slot-1 there anyway.
So straddle here is a *control* conservatism, not a fetch-width problem.

### W2a — slot-1 on a one-shot straddle: BUILT, FLIPPED, MEASURED. **The first real win.**

⚠️ **The census pointed at a predicate; the RTL said one layer deeper.** Unlike W1a this was *not*
just a predicate — `slot1_eligible` excluded straddle because the extraction could not handle it:

```veryl
let s1_hw : logic<16> = if s1_b1 == 2'd1 ? fw_hw1 : fw_hw2;   // b1∈{1,2}
```

A straddling slot-0 (`ic_pc[1] && !curr_is_rvc`) puts slot-1 at window halfword **3**, which that
mux never handled. The window is `{ic_rdata_next, ic_rdata}` = 4 halfwords, so slot-1's OWN halfword
(hw3) is present but its SECOND would be hw4, one past the end. Hence the rule: **a one-shot
straddle may deliver slot-1 only when slot-1 is RVC** — most of the population in RVC-dense kernel
code. The SLOW straddle (`straddle_q`) is left untouched (it re-fetches, so the extraction window is
not the one it will run in). `W2A_STRADDLE_SLOT1`; DEAD at 0 verified bit-exact.

| config | cycles | vs base |
|---|---|---|
| base | 14,600,000 | — |
| W1a | 14,570,000 | −0.21 % |
| **W1a + W2a** | **14,390,000** | **−1.44 %** (W2a's own share **−1.24 %**, 6× W1a) |

Suite 252/0. Census at `W1a+W2a`: slot-1 produced 4,109,713 → **4,712,401** (+602,688), straddle
loss 2,035,379 → **1,068,857** (−966,522 — about half, exactly the RVC share), 2-wide rename
2,776,763 → **3,087,802**.

🎯 **This is where the "fires but buys nothing" chain broke, and it broke by removing the wall in
front of the earlier step.** W1a alone was worth 0.21 %; with W2a's wall removed the pair is worth
1.44 %. Measuring the two together was the right call — a lever pressed against a wall reads as
worthless even when it is not.

### W2b — the wall is the L1I, and it is CAPACITY, not run-ahead

The W2b census partitions the 1,660,371 "extract wants a dword, FIFO cannot supply" cycles exactly:

| | cycles | share |
|---|---|---|
| FIFO **genuinely empty** (`wf_count == 0`) | **1,655,976** | 99.7 % |
| FIFO non-empty, head is the WRONG dword (run-ahead diverged) | 4,395 | 0.3 % |

…and on those cycles, the producer's state:

| | cycles | share |
|---|---|---|
| **icache miss** (`icache_stall_comb`) | **1,224,545** | 73.8 % |
| presenting, data not back yet | 434,724 | 26.2 % |
| I-PTW | 902 | 0.05 % |
| `wf_full` (back-pressure) | **0** | 0 % |

⚠️ **Three hypotheses die at once: run-ahead divergence (4,395), I-PTW (902) and FIFO depth
(`wf_full` = 0).** The run-ahead MACHINERY was never the problem. This also closes
[[f2.14]] from the other side — deepening run-ahead was unamortisable because *the miss, not the
pointer,* is what starves fetch.

**L1I 16 KB → 32 KB** (`INDEX_W` 6 → 7; 128 sets × 4 ways × 64 B). Measured: icache-miss cycles
1,224,545 → **426,402 (−65 %)**, FIFO-empty 1,655,976 → **843,393 (−49 %)**.

### 🏁 Block W result — full Veryl ladder green

| gate | old default | W1a + W2a + 32 KB L1I | Δ |
|---|---|---|---|
| default suite | 252/0 | **252/0** | — |
| **dhrystone** | 263,393 | **237,827** | **−9.71 %** (IPC 1.005 → **1.114**) |
| **N=2 SMP boot** | 19,620,000 | **18,170,000** | **−7.39 %** |
| **N=4 SMP boot** | 28,530,000 | **26,440,000** | **−7.33 %** |
| **N=1 boot** | 14,600,000 | **13,580,000** | **−6.99 %** |
| coremark | 421,616 | 404,355 | −4.09 % |
| litmus N=4 | 3,940,000 | 3,960,000 | +0.51 % |

**IPC crosses 1.0 for the first time in this campaign** (dhrystone 1.005 → 1.114) — the "effectively
1-wide" diagnosis, solved. Boot improves ~7 % at N=1/2/4 alike, i.e. it is per-core, not an SMP
effect. **Cost: the L1I SRAM doubles, per hart.**

Verilator NBA cross-check — **4/4**, all clean rebuilds, all matching the Veryl sim:

| | Verilator | Veryl sim |
|---|---|---|
| N=1 boot | `$finish` 136 ms = 13.6 M ✓ | 13,580,000 |
| N=2 SMP boot | 182 ms = 18.2 M ✓ | 18,170,000 |
| litmus N=4 | `cy=3,952,044` pass=1 ✓ | 3,960,000 (−0.20 %, the same systematic offset as the previous session's 3,931,194 vs 3,940,000) |
| N=4 SMP boot | 264 ms = 26.4 M ✓ | 26,440,000 |

Same verification standard R3 shipped on.

⚠️ **Two Verilator-side traps this cost real time on, both worth remembering:**
1. **A stale build directory lies convincingly.** The first N=2 attempt reported `$finish at 195ms`
   — *exactly the pre-improvement number* — because an interrupted incremental build left old
   objects in `build_n2`. A clean rebuild gave 182 ms. **`rm -rf` the `build_*` dir whenever the
   configuration changes.**
2. **`-O3` cannot build the 4-hart models here any more**: `g++: internal compiler error: Bus error
   signal terminated program cc1plus`, reproducibly, on `Vtb_litmus_4hart___024root__12.o`. Disk is
   fine (7.6 T free), so it is compiler memory pressure. **`-O1 -j 2` builds cleanly** (slower sim,
   ~490 s for litmus N=4 vs ~490 s at `-O3` previously — no real loss). The CLAUDE.md recipe still
   says `-O3`; that no longer works for N=4 tops on this box.

⚠️ **A stale Verilator build directory lies convincingly.** The first N=2 attempt reported
`$finish at 195ms` — *exactly the pre-improvement number* — because an interrupted incremental build
left old objects in `build_n2`. A clean rebuild gave 182 ms. **`rm -rf` the `build_*` dir whenever
the configuration changes**; an incremental Verilator build can otherwise produce a plausible,
wrong, and very believable result.


### 🗺️ Post-Block-W re-census (2026-08-15) — the map changed, so it was re-measured

Every bucket in this document above was taken on a machine that no longer exists (~1-wide,
16 KB L1I). Re-measured at the new default (`cy=00cf36e0` = 13,580,000):

| pool | cycles | of boot |
|---|---|---|
| **`loadwait`** (back end) | **2,758,130** | **20.3 %** |
| **front end empty** | **2,648,008** | **19.5 %** |

The two are now level — and note `loadwait` did **not** shrink in absolute terms; the front-end
work simply removed cycles around it. `loadwait` splits:

| sole blocker | cycles |
|---|---|
| **`lsr` occupancy** | **1,440,381** |
| ├ `dcache` | 734,816 |
| └ **`lane0`** | **705,559** |
| `load_blocks_on_store` | 723,149 |
| `dmem_mmu_busy` | 261,794 |
| AMO path | 106,413 |
| replay (live now that the MSHR ships) | 50,147 |
| mshr | 17,466 |

⚠️ **`lane0` was ~0 before Block W.** It is the Stage-B load waiting for a free lane-0 writeback
slot (`lsr_lane0_free`) — a PORT CONTENTION created by the extra traffic 2-wide rename delivers.
A bottleneck Block W *made*, not one it found.

### W3 probe — L1D 16 KB → 32 KB: **−1.40 %. Do not adopt.**

Same one-parameter probe that returned −5.63 % on the L1I. The data side does not behave like the
instruction side at all:

| | 16 KB | 32 KB | Δ |
|---|---|---|---|
| cycles | 13,580,000 | 13,390,000 | **−1.40 %** |
| `lsr`→`dcache` | 734,816 | 692,398 | **−5.8 %** |
| `lsr`→`lane0` | 705,559 | 708,405 | +0.4 % (unmoved) |
| `loadwait` | 2,758,130 | 2,647,076 | −4.0 % |

Doubling the L1I cut its miss cycles **−65 %**; doubling the L1D cuts its stall bucket **−5.8 %**.
D-side misses here are compulsory/coherence traffic, not capacity — **the same SRAM area buys 4×
more on the instruction side.** Probe reverted; not shipped.

**⇒ Next lever is `lane0` (705,559 cy), and it is structural, not capacity** — port contention on
the lane-0 writeback, untouched by any cache size. See `lsr_lane0_free` / `lsr_to_lane1`
(step-1.5's "fault/FP loads stay on lane 0, everything else goes to lane 1").

### Order (revised AGAIN, by the W2a flip)

1. **W2b — the fetch-ahead FIFO not delivering** (1,660,371 cy at `W1a+W2a`). This is the wall that
   has now capped BOTH W1a and W2a. ⚠️ It has **two causes needing opposite fixes**, and
   `ext_head_avail = ext_head_match || ext_bypass` with
   `ext_head_match = (wf_count >= 1) && (wf_pc[wf_head] == ext_head_dw)` splits them:
   **(a) FIFO genuinely empty** (`wf_count == 0`) → producer can't keep up: icache miss / I-PTW /
   bandwidth; **(b) FIFO non-empty but the head is the WRONG dword** → stale after a redirect, or
   the run-ahead followed a different path (FTB follow). `WF_N = 8`, so plain depth is unlikely to
   be it. **Census the split before building.**
2. **W2c — cross-line slot-1** (869,632 cy): deeper `wf` lookahead across a line boundary.
3. **straddle remainder** (1,068,857 cy): the 32-bit-slot-1 half, which needs hw4 — a 3-word /
   128-bit window.
4. *(predicted-taken 790,845 is fetch-BLOCK SHAPE — only a wider block attacks it. Last.)*
2. **W1b — control on commit slot-1** (`c2_simple`'s `!sh_is_control`; needs the slot-1 next-PC to
   stop assuming `pc + (rvc?2:4)`). Only after W2, and only if commit shows up as the limiter then.
3. **W3 — loads on slot-1** — mem-IQ slot-1 alloc + a banked/dual-ported L1D.
4. **W4 — resize ROB/PRF/IQ** — still last; `resource` is 758,781 cy even at `W1=1`. First give
   sizing a single source of truth.

⚠️ Census discipline, per L4 step-2: a sole-blocker census bounds the **OPPORTUNITY**, not the
**PRIZE**. Use these numbers to choose WHERE to build, never to predict what a build is worth.
Price every one of W1-W4 the same way: build it DEAD, flip it, read the cycle counter.

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
