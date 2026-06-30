# Phase A keystone — execute staging, latency-speculative wakeup & replay

Design doc for the **keystone** of the deep-pipeline campaign
(`doc/deep_pipeline_sram_plan.md`). This is the ~80 % of the campaign difficulty:
splitting the fused **issue=execute=broadcast=wakeup** cycle ("Stage IE") so the
critical path drops to the *select→wakeup→select loop* floor (~7.5 ns), at an IPC
cost inside the **user-set budget of ~10–15 %** (boot-cy / CoreMark / Dhrystone).

Read after: `cp_pipelining_strategy.md` (Directions A–D + the "scheduled wakeup
WITHOUT replay" refinement §6), `cp_front_pipeline_plan.md` (the FR + scheduled
wakeup already landed), `deep_pipeline_sram_plan.md` (the campaign arc).

Status: **design only** — no RTL yet. Entry state heliodor master `c09f99c`,
CP **15.300 ns**, all of `SCHED_WAKEUP`/`FRONT_PIPE`/`MEM_PIPE`/`VINT_PIPE`/`VFP_PIPE`
flipped ON.

---

## 1. The floor we are breaking (grounded in `veryl synth` @ 15.300)

### 1.0 What the synth headline actually is (re-measured `c09f99c`)
The synth **headline** endpoint at 15.300 ns is **NOT** the issue/wakeup loop — it
is the **commit-store megacone** `head[0] → n_inflight[5]` (161 levels), and the
**dcache-fill way-valid** `head → valid_1` (14.870, 148 levels) right behind it.
Traced, path #1 is:

```
head[FF]  → ROB commit decode (u_rob.sh_rd_arch)
          → arch_regs read  → amocas.q compare (c_cas_q_mem_hi / c_is_cas_q)
          → commit_store_fire  → store AGU (agu_addr_iss)  → dmem_vaddr
          → MMU TLB translate (u_dmem_mmu.u_mmu.tlb_*)  → … → n_inflight[FF]
```

This is the **commit-store / store-at-commit path** (Phase E) + the amocas.q
serialized-commit tail, riding the shared `head → AGU → MMU → dcache` front. It does
**not** traverse the issue-select FR — the FR registered the *issue* half of the
front; the *commit-store* half is a separate combinational sweep from `head`.

### 1.0a ⚡ MEASURED (2026-06-30, `--timing-paths 80`) — the front is a ~200-PATH WALL, not a headline

The commit-store/dcache-fill front is not just *the headline* — it is the **entire top
~200 endpoints**. The top-80 are ALL `head[0] → n_inflight[0..5]` (15.01–15.300) and
`head[0] → valid_1[0..63]` / `valid_3[*]` (**14.870, every bit of two 64-bit dcache
way-valid words**). `rs1_rdy` (14.565) does **not** appear in the top-80 — it is masked by
this wall. **Consequence:** the keystone (and Phase B, and everything ≤14.565) is *invisible
to synth CP* until the **whole** `head → MMU → {n_inflight, valid_*}` front is cut — n_inflight
**and** the ~128 `valid_*` dcache-fill bits together. The commit-store pre-translate P3
experiment (`cp_commit_store_pretranslate_plan.md §4.1`) cut the plain-store `n_inflight`
piece to 14.890 but left the `valid_*` fill front and the AMO residual standing — so the wall
barely moved. ~~**Cutting this wall = pre-translate plain stores (2-cycle SB push for the
non-pre-translated) + AMO pre-translate/registration + the dcache fill/invalidate fed from a
registered PA.**~~ Only then does `rs1_rdy` surface and the keystone's CP become measurable.

> ✅✅ **SUPERSEDED (2026-06-30) — the wall was ONE dead AMO signal, NOT a multi-front
> pre-translate problem.** Tracing path #1 to the gate showed the whole `head → MMU →
> {n_inflight, valid_*}` wall rides the AMO commit's `dmem_wstrbhi_m` arm (`core.veryl:6601`):
> at `MEM_PIPE=1` the AMO commit already drains a registered PA (`ac_pa_q`)/write-OK
> (`ac_wok_q`), and the ONE straggler was `dmem_wstrbhi_m`'s `amo_commit_live ? dc_st_wstrb_hi`
> arm — and `dc_st_wstrb_hi = dc_i_wen ? st_wstrb_hi : 0` pulls the live MMU `acc_fault`
> through `sb_vm_ok`. That single live net fed BOTH the `n_inflight` (dcache stall cone →
> `rob_commit_ack`) and the `valid_*` (dcache fill) endpoints = the entire wall. It is
> **functionally dead**: a committing atomic is always aligned, so `st_wstrb_hi ≡ 0`. Tying
> the arm to `8'd0` is **byte-identical** (default 252/0, N1 boot 4/4 with 7.1 cy=01210060
> matching baseline) and drops **15.300 → 14.565** in one line — no pre-translate, no IPC
> cost. `rs1_rdy` now surfaces; the keystone is measurable. See
> `cp_cut_the_wall_plan.md §7`.

### 1.0b ⚠️ The keystone's CDB-register has a writeback-arbitration conflict (naive E1 is INCORRECT)

Registering `alu_cdb` (the E1 step) is **not** a simple flop: the unified CDB is a single
broadcast lane arbitrated `fpu > mshr > int_div > alu > lsu > vu` (`core.veryl:2323`). Today
the ALU broadcasts **combinationally at its issue cycle N**, and issue is gated on
`!fpu_cdb.valid && !mshr_cdb.valid` *at N* — so no conflict. If `alu_cdb` is registered it
broadcasts at **N+1**, where a NEW higher-priority FU result (fpu/mshr completing at N+1,
which N's issue gate could not see) wins the mux → **the registered ALU result is silently
DROPPED**. So E1 needs a **writeback buffer / arbitration** (give the registered ALU result a
guaranteed slot, or a 1–2 entry WB queue that holds it until the lane is free) — this is part
of the "80 % difficulty," not a detail. The DEAD scaffold (`EX_PIPE=0`, combinational) is
byte-identical, but the **flip** cannot be correct without resolving this.

`rs1_rdy` (`iq_int.veryl:171`, **14.565 ns**) — the issue/wakeup loop, the
*fundamental floor* this keystone targets — sits **below** the headline and does
**not** appear in the top-12 (in fact not in the top-80, §1.0a). Two consequences that
shape the whole campaign:

1. **The keystone alone will not move the 15.300 headline.** Registering execute /
   the CDB cuts the `rs1_rdy` front, but the commit-store (`n_inflight`) and
   dcache-fill (`valid_*`) fronts are *above* it. They are cut by **Phase E**
   (commit) and **Phase C** (dcache) respectively. The headline only drops when
   **all three fronts drop together** — exactly the plan's "flip multiple fronts
   together; intermediate no-CP-gain steps are expected" (`deep_pipeline_sram_plan.md`).
2. **Why the keystone is still "first":** it builds the scheduled-wakeup + execute-
   staging *infrastructure* that Phase B (and the load-side of C) depend on, and it
   is the highest-risk piece (replay + SMP) — de-risk early. But the **measurable CP
   win this session** comes from the **dcache warm-up (Phase C, the `valid_*`
   front)**, which is why the user picked "keystone design + low-risk warm-up in
   parallel." Direction-C analysis already bounded the *commit-only* tail at ≤1.3 ns
   (`cp_direction_c_port_separation_plan.md`), so the front — not the commit tail —
   is the prize.

### 1.1 The issue/wakeup floor itself (`rs1_rdy`, 14.565)
`rs1_rdy[i]` is a **register** set in the `iq_int` `always_ff`
(line 573–585) by the **CDB snoop**:

```
rs1_rdy[i].D  ←  i_cdb_valid && sh_rs1_pdst[i] == i_cdb_pdst
```

and `i_cdb` (the lane-0 CDB) is driven **combinationally from execute** —
`alu_wrap` has **zero `always_ff`** (verified), and the core's CDB mux
(`heliodor_core.veryl:2300`) is a pure priority mux
`fpu > mshr > int_div > alu > lsu > vu`. So the combinational cone ending at the
`rs1_rdy` flop is:

```
fr0_op_q[FF]  →  PRF read  →  ALU execute  →  alu_cdb (comb)  →  rs1_rdy[FF].D
   (iq_int FR)    (prf_int)    (alu_wrap)       (core mux)        (iq_int snoop)
```

This is the **execute+broadcast cone feeding the wakeup register**. It is *not* the
select loop — `FRONT_PIPE` (the FR, `iq_int.veryl:232`) already pulled the
issue-select cone out of series by registering `o_issue_*`. What remains in series
is **execute → CDB-broadcast → wakeup**: one combinational sweep from the FR output
through the ALU to the readiness flop.

> **Key consequence.** As long as the CDB is combinational from the FR output,
> *any* deeper pipelining is masked — this cone (~14.6 ns) dominates. The keystone
> is to **register the CDB** (put an execute stage register before the broadcast).
> Then the CDB-snoop path collapses to `EX_reg[Q] → compare → rs1_rdy[D]` (short),
> and the new floor is the **select→wakeup→select loop** the FR already isolates.

> 🚨🚨 **MEASURED CORRECTION (2026-06-30, after the wall cut `66c0f14`) — the above cone
> is NOT the rs1_rdy critical path. The keystone (register the CDB) does NOT cut 14.565.**
> Once the AMO-wstrb wall fell (15.300 → 14.565), `--dump-timing` shows the actual
> `rs1_rdy[0]` worst path is the **FRONT-END fetch→decode→rename→allocate sweep**, not the
> execute/broadcast/wakeup cone:
> ```
> pc_q[34][FF] → u_imem_mmu V=1 two-stage TLB (v1_vpn→v1_level→v1_valid→v1_hit, ~5.0 ns)
>   → imem_paddr → u_icache hit_3 (~1.3 ns)
>   → u_cexp (compressed-instr expand) → u_dec.opcode (DECODE, ~4.5 ns)
>   → stall_dr → u_fl.i_pop_en (free-list pop = pdst alloc)
>   → u_iq.i_rename_pdst2 → u_iq.prf_ready[*] → rs1_rdy[0][FF].D   (14.565 ns, 138 levels)
> ```
> `rs1_rdy[i]` has TWO write paths in the `iq_int` always_ff: (1) the CDB-snoop (wakeup,
> what §1.1 analyzed) and (2) the **allocate** path that *initializes* a freshly-dispatched
> op's `rs1_rdy` from `prf_ready` at the cycle it enters the IQ. The **allocate** path —
> the entire single-cycle front-end from the fetch PC through the imem MMU, icache, cexp,
> decode, rename and free-list to the IQ write — is the critical one; the CDB-snoop is far
> shorter. EMPIRICALLY CONFIRMED: a DEAD-then-flipped `EX_PIPE` scaffold that registers
> `alu_cdb` (the §1.1 cone) leaves `rs1_rdy` at **14.565 unchanged** (and surfaces an
> unrelated FROUND FP cone at ~16.7 — a parallel front, plus a synth re-balance artifact).
> So the keystone's "register the CDB" lever is mis-aimed at the current netlist.
>
> **→ Corrected campaign order.** The 14.565 floor is the **shallow (single-cycle) front
> end**: `pc → imem-MMU-translate → icache → cexp/decode → rename/free-list → IQ-allocate`
> is ONE combinational cycle (no IF/ID register). The real next lever is **Phase D /
> front-end pipelining** — split fetch (pc→MMU→icache→raw instr, ~6.7 ns) from
> decode/rename/allocate (~7.9 ns) with an IF/ID register, which roughly halves 14.565 to
> ~8 ns. The imem MMU V=1 (hypervisor two-stage) TLB is the single largest chunk (~5 ns) —
> registering the instruction-fetch translation (mirror of the dmem-side work) is the
> highest-value sub-cut. The **execute/wakeup keystone (Phase A) stays masked** below this
> front-end floor and becomes the lever only AFTER the front end is pipelined — same
> "wall masks the loop" pattern the AMO-wstrb wall just exhibited. The `EX_PIPE` scaffold
> was reverted (premise invalid); revisit Phase A after the front end is cut.

### 1.1c 🚨🚨🚨 MEASURED (2026-06-30, after FETCH_REG) — the keystone floor is the SELECT→WAKEUP LOOP, and "register the CDB" is mis-aimed a THIRD time

FETCH_REG cut the front-end allocate path (§2.2 of `cp_frontend_pipeline_plan.md`). With
`FETCH_REG=1` synth-flipped and the masking fronts read past via `--timing-paths 14000`, the
`rs1_rdy[0]` worst path is now **12.920 ns (126 levels), sourced from `head[0]`** — it is the
**scheduled-wakeup SELECT loop**, NOT the execute/CDB-broadcast cone:

```
head_idx[FF]
  → (rob.veryl:741) age_i = i − head_idx  →  is_block (per ROB entry)
  → blk_cand → pick_oldest_blk balanced-argmin tree (DEPTH 5, 32 entries) → o_block_store_age
  → (iq_int.veryl:349) blocked = block_store_exists && (block_store_age <: age)   [load-ordering gate]
  → ready = occupied & rs1_rdy & rs2_rdy & !blocked  →  cand0
  → pick_oldest balanced-argmin tree (DEPTH 3, IQ_N=8)  →  issue_idx
  → sched_wake0_pdst = sh_rd_pdst[issue_idx]  →  == sh_rs1_pdst[i]  →  rs1_rdy[i][FF].D
```

**The binding floor is TWO argmin trees in SERIES** — the ROB oldest-store-blocker scan
(depth-5) feeding the IQ oldest-ready select (depth-3) — plus two head-relative age subtracts
and a short wakeup tail. This is precisely the "select→wakeup→select loop" §1.1 (line 166)
names as the ~7.5 ns *target* — and it measures **12.920**, not 7.5.

**Two decisive confirmations that "register the CDB" (E1) does NOT touch it:**
1. **Source = `head[0]`.** Only the SELECT path (age/blocked/at_head) depends on the ROB head.
   The CDB-snoop wakeup and the allocate seed do not — so a flop on `alu_cdb` cannot shorten a
   head-sourced path.
2. **`SCHED_WAKEUP=0` makes `rs1_rdy` VANISH from the top-14000 (floor 11.74).** Removing the
   scheduled-wakeup writes drops `rs1_rdy`'s worst path below 11.74 — i.e. the CDB-snoop +
   allocate cone (the E1 lever's target) is **< 11.74**, well under the 12.920 select loop. The
   residual head-sourced IQ endpoint is `occupied[*]` at 11.800 (the select half alone).

**→ Structural conclusion (NOT a CP verdict).** Reading this by *structure* (not "which front
is the binding synth number" — that lens is the mole-whacking 43abb9d retired): the measurement
**decomposes the fused "Stage IE"** into its real pipeline shape. The CDB-register lever (the old
E1 first step) targets the EXECUTE half (< 11.74), which is a **genuine, foundational stage
boundary the deep pipe needs** — its being CP-neutral today (masked below the scheduler) is *fine*
and expected, NOT a reason to reject it. What the measurement *adds* is that the **SCHEDULER half**
(this 12.920 select→wakeup loop = the two serial argmin trees + the load-ordering block gate) is a
**separate, binding pipeline stage** that the old plan under-scoped, and it is **two distinct
problems** — the loop must close in 1 cycle (latency-speculative wakeup + replay), *and* the
select-logic depth (~12 ns ROB block-scan + IQ argmin) exceeds the ~7.5 ns stage budget
**independently of replay**. The keystone is therefore re-scoped into **A-EXE / A-LOOP / A-SCHED**
(see `deep_pipeline_sram_plan.md` "The keystone (REVISED)" + the FINAL target microarchitecture);
A-SCHED (scheduler-logic pipelining: register the ROB block-scan into its own stage, keep
atomic/fence/cbo blockers live, lean on the existing violation→replay) is **promoted from this
section's out-of-scope footnote to a first-class component** because it is the binding stage.
Build A-EXE first (foundational, structure not CP); A-SCHED is the gate to ~7.5 ns.

### 1.1 What the select→wakeup→select loop is (the ~7.5 ns target)
After the CDB is registered, the IPC-preserving floor is the single-cycle loop that
*must* stay one cycle for back-to-back dependent ALU ops to issue 1/cycle:

```
rs*_rdy[FF] → cand0 build (occupied/age/blocked, iq_int:324-355)
            → pick_oldest argmin tree (depth 3 for IQ_N=8, iq_int:358-364)
            → issue_idx / slot0_grant
            → sched_wake0 (iq_int:619-630) sets rs*_rdy[D] of the consumer
            → [edge] rs*_rdy[FF]      (back to top)
```

`cp_pipelining_strategy.md §3.A` estimates this loop at ~6–8 ns. **~7.5 ns is the
CP target** — it is this loop. Going below it needs structural scheduler changes
(speculative multi-cycle select, IQ banking) that are *out of scope* for the
keystone; the keystone's job is to **expose** this loop by registering everything
after select.

---

## 2. What already exists (do not rebuild)

`iq_int` is **already a two-tier wakeup** (this is the seed — extend it, don't
replace it):

| producer class | wakeup mechanism | when | replay? |
|---|---|---|---|
| **fixed-latency** (ALU/branch/LUI/AUIPC, `pipe1_ok`) | **scheduled** at GRANT (`sched_wake0/1`, `iq_int:619-642`) — sets `prf_ready[rd]` + wakes consumers one cycle *before* the CDB broadcast | grant edge N | **none** (deterministic) |
| **variable-latency** (load, div, fp) | **CDB-broadcast snoop** (`iq_int:573-608`) — consumer wakes on the *real* broadcast | broadcast edge | **none** (no speculation) |

Plus the supporting state:
- `prf_ready` (`iq_int:209`) — drives **selection seeding**; set early at scheduled grant.
- `prf_done` (`iq_int:220`) — set **only** at the real CDB broadcast; gates the FR
  *present* (`fr0_src_done`, `iq_int:375`) so a producer that **stalled in the FR**
  (lane-0 yielded to FPU/MSHR/MMU-walk) holds its consumer instead of feeding a
  stale PRF read. **This is already a no-replay "confirmed-execute" guard** — the
  consumer is *speculatively selected* but only *presents* once sources truly landed.
- The FR (`fr0_op_q`/`fr1_op_q`) frees the IQ slot **at capture** (`slot0_grant`,
  `iq_int:659`). ⚠️ This is why **loads are barred from the FR / slot-1**
  (`iq_int:457-465`): a missing load freed from the IQ has no retry path and
  deadlocks. **Replay will have to revisit this** (§5).

MEM_PIPE already stages the load: **Stage-A** (AGU+translate+PMP) → **M-stage**
(PA latch `m_pa_q`, `heliodor_core.veryl:1577`) → **Stage-B** (dcache+forward+CDB).
The dcache read is **combinational** today (`dcache.veryl:342-377`: `hit_*` →
`rdata_*` → way-mux). Converting it to **synchronous (registered) read** = the
Phase-C SRAM migration *and* adds the dcache stage register (warm-up scaffold).

---

## 3. The keystone in one picture

```
        TODAY (fused IE, CP 15.3)              KEYSTONE (staged execute, CP ~7.5 target)
        ────────────────────────              ─────────────────────────────────────────
  N  : select → FR capture              N  : select → FR capture            (the loop)
  N+1: FR_Q → PRF → ALU → CDB(comb)     N+1: FR_Q → PRF/regread            (RR stage)
       → wakeup[D]                       N+2: ALU execute → EX_reg[D]        (EX stage)
                                         N+3: EX_reg[Q] → CDB broadcast      (WB stage)
                                              → wakeup[D]   (now SHORT: reg→cmp→flop)
   dependent ALU 1/cycle via             dependent ALU 1/cycle via
   scheduled wakeup + 1-deep FR          scheduled wakeup + BYPASS network
```

The new registers (RR / EX / WB boundaries) turn the 14.6 ns execute+broadcast cone
into 2–3 thin stages. The cost: a producer's result reaches the PRF later, so a
dependent consumer reading the PRF would miss it → a **bypass (forwarding) network**
must span the new register(s). The scheduled wakeup already wakes the consumer at
the right cycle; bypass just supplies the *value* before it is in the PRF.

### 3.1 Why fixed-latency ALU needs **bypass, not replay**
Scheduled wakeup at grant is **deterministic** for fixed-latency FUs: the producer
*will* land its result a known number of cycles later, every time. The consumer is
woken to arrive at execute exactly when the producer's EX_reg holds the result;
bypass feeds it. There is **no misspeculation**, so **no replay** for the ALU tier.
This is the entire content of `cp_pipelining_strategy.md §6` ("scheduled wakeup
WITHOUT replay") — and it is the **lower-risk first half** of the keystone.

### 3.2 Why variable-latency loads are where replay lives
A load's latency is **data-dependent**: hit = fixed (e.g. 3–4 cy), miss = unknown
(MSHR fill, 10s of cy). Two ways to wake a load's consumers:

- **(no replay) keep CDB-broadcast** — the consumer waits for the *real* load
  broadcast. Always correct, never replays. **Cost:** load-use latency = the *full*
  (deepened) load pipe depth on **every** load, even hits → as the pipe deepens this
  is the dominant IPC loss on load-heavy code (boot, CoreMark).
- **(replay) speculatively wake at expected-hit latency** — wake the load's
  consumers assuming a hit, so a hit→use chain runs at min latency. On a **miss**,
  the speculatively-issued consumers read garbage and must be **squashed and
  re-woken** on the real fill. **Cost:** the replay machinery + full SMP
  re-verification; **benefit:** recovers the load-use IPC the no-replay path loses.

---

## 4. Staged plan: no-replay first, replay only if the budget demands it

> **Re-scope (2026-06-30, §1.1c):** this section's **A.1 = A-EXE** (execute staging) and
> **A.2 = A-LOOP** (latency-speculative wakeup + replay). It is **missing A-SCHED** — the
> scheduler-logic pipelining (ROB block-scan stage + IQ-argmin reduction) that the §1.1c
> measurement showed is the binding ~12.9 ns stage. A.1/A.2 below remain valid for the
> A-EXE/A-LOOP components; **A-SCHED is the added first-class component** (own staged plan
> TODO). Sequencing across the three is in `deep_pipeline_sram_plan.md` "Sequencing & risk".

Given the **~10–15 % IPC budget**, the design sequences the *risk* deliberately:

### Phase A.1 — execute staging, **no replay** (lower risk, do first)
1. **EX register + WB stage** for the ALU lane(s): register `alu_cdb` so the CDB is
   driven from a flop, not combinationally from the FR output. The scheduled wakeup
   (already present) keeps dependent ALU chains 1/cycle.
2. **Bypass network** spanning the EX register: forward EX_reg / WB_reg → ALU
   operand inputs (the core's PRF read mux gains bypass sources keyed on
   producer-pdst == consumer-rs-pdst). Mirror for lane-1 (`alu_cdb2`).
3. **Loads stay CDB-broadcast-woken** (the existing variable-latency tier). Their
   `prf_done` guard already prevents stale presents. Load-use grows by the added
   stage depth — **this is the IPC we measure against the budget.**
4. **div/fp** unchanged (already CDB-broadcast, multi-cycle; they ride the same WB
   register or their own — see §6.3).

→ Re-synth: expect the 14.6 ns execute cone to split; new headline = the
select→wakeup loop (~7.5–9 ns) **or** a back-half front (dcache/commit) that now
dominates and is cut by Phases C/D/E. Measure boot-cy/CoreMark/Dhrystone.

**Decision gate:** if A.1's IPC loss is **within ~10–15 %**, the keystone may be
*done without replay* (huge risk reduction). Only if load-use blows the budget do we
proceed to A.2.

### Phase A.2 — latency-speculative load wakeup + replay (the hard 80 %, only if needed)
Add speculative wake for **loads** (the highest-frequency variable-latency producer;
div/fp are rare enough to stay broadcast-woken). This is §6.

---

## 5. The replay mechanism (Phase A.2 detailed design)

### 5.1 Speculative wake
On a load **grant**, schedule-wake its consumers at `grant + HIT_LATENCY` (the
fixed hit pipe depth), exactly like the ALU scheduled wakeup but with the load's
latency tier. The consumer issues into the deepened pipe and reads the load result
via **bypass** off the dcache-read register (Stage-B output) — *iff* the load hit.

### 5.2 Misspeculation detection & squash scope
The load resolves hit/miss at Stage-B (`cache_hit`, `dcache.veryl:346`). On a
**miss**:
- The load's **speculative wave** = every op woken (directly or transitively) by the
  load's speculative broadcast that is now in-flight with a *garbage* operand.
- These must be **squashed and re-woken** on the real fill. The squash is
  **selective** (re-issue from the IQ), NOT a full flush — a full flush per load
  miss is catastrophic IPC.

### 5.3 IQ retention — the structural conflict to resolve
Today the FR **frees the IQ slot at capture** (`iq_int:659`), and loads are barred
from the FR for exactly this reason (`iq_int:457-465`: a freed missing load can't
retry → deadlock). For replay, a speculatively-issued op **must remain re-issuable
until its wakeup source is non-speculative**. Options (decide in A.2):
- **(a) Retain-until-confirmed**: do not free the IQ entry at grant; mark it
  `speculative`, free it only when all its wakeup sources have `prf_done` (real
  broadcast). A squash clears the `speculative`+`issued` flags so it re-selects.
  *Cost:* IQ occupancy pressure (entries live longer) → may need Phase-F IQ growth.
- **(b) Replay queue**: a separate small structure holds in-flight speculative ops;
  on squash they drain back into the IQ / re-issue. *Cost:* new structure + ordering.
- **(c) Non-selective per-load-miss flush of younger-than-load**: simplest, correct,
  but IPC-poisonous; **rejected** except as a correctness fallback.

Recommendation: **(a) retain-until-confirmed**, co-designed with Phase-F IQ growth.

### 5.4 Poison / cancel propagation
A squashed op may have *already* broadcast its own (garbage) result and woken *its*
consumers → transitive squash. Track a per-pdst **poison** bit set when a producer is
squashed; a consumer that woke on a poisoned producer is itself squashed. Clears when
the producer re-executes non-speculatively. (This is the classic "speculative wakeup
poison vector"; size = PRF_N.)

### 5.5 Speculation depth bound
Bound the number of outstanding speculative loads (e.g. 1–2 deep). Beyond the bound,
fall back to broadcast wakeup (no speculation) for further loads. Keeps the poison
fan-out and replay storms tractable, and keeps the worst-case replay cost bounded.

---

## 6. FU-by-FU latency tiers (the wakeup schedule table)

| FU | latency | wakeup tier | bypass source |
|---|---|---|---|
| ALU / branch / LUI / AUIPC | fixed 1 (in EX) | **scheduled @ grant** | EX_reg, WB_reg |
| MUL | fixed (pipelined) | **scheduled @ grant** + latency offset | EX/WB |
| DIV/REM (`int_divider`) | variable ~34 cy | **CDB-broadcast** (rare) | none |
| FP (`fpu_wrap`, pipelined) | fixed-ish per op | broadcast (rare) or scheduled-with-offset | WB |
| **LOAD (hit)** | fixed `HIT_LATENCY` | A.1: **broadcast**; A.2: **speculative @ grant** | dcache-read reg |
| **LOAD (miss)** | variable (MSHR) | **broadcast on fill** (always) | mshr_cdb |
| VU | decoupled in-order | own `vu_cdb` | n/a |

### 6.1 The `prf_ready` vs `prf_done` split generalizes cleanly
`prf_ready` (early/selection) and `prf_done` (real/present) already exist. Replay
adds a third state implicitly: *speculatively-broadcast-but-unconfirmed*. Model it as
`prf_ready=1, prf_done=0, prf_poison-able`. The FR-present guard (`fr0_src_done` on
`prf_done`) **already** prevents a consumer from *presenting* on an unconfirmed
source — replay extends it to *squash* (not just *hold*) when the source is
*poisoned* (miss), vs *hold* when merely late.

---

## 7. SMP correctness & the verification plan (non-negotiable)

Memory ordering is **not separable** from this work. The cautionary tale: a
+1-cycle commit drain silently broke SMP AMO atomicity (litmus N2 `amoadd`
lost-update wedge) — passed all single-hart tests, caught only by litmus/SMP. Two
specific hazards for replay:

1. **Replayed loads must re-observe coherence.** A squashed-and-re-issued load must
   re-read through the dcache/MESI as a *fresh* access (no stale Stage-B latch). It
   must re-evaluate the store-ordering / `i_block_*` gates at re-issue.
2. **Atomics stay single-cycle at commit** (proven constraint). AMO/LR/SC issue at
   the ROB head and must **never** be speculatively woken or replayed across the
   atomic commit — they are excluded from the speculative tier (they are already
   excluded from `pipe1_ok` and gated to `at_head`).

**Hard gate at every increment** (same ladder as the FR/MEM_PIPE flips):
- `veryl test` default 251/0
- `--backend-validate` (cc vs cranelift)
- **ACT4 696/696** (essential — it alone caught the MEM_PIPE S-mode paging corner)
- litmus N2 **and** N4
- N2 **and** N4 SMP Linux boot (N4 only at milestones — `feedback_regression_cadence`)
- Verilator SMP boot

Dual metric every step: synth **CP** *and* **IPC** (boot-cy / CoreMark / Dhrystone),
judged NET. Commit to the structural change; intermediate no-CP-gain steps are
expected (multi-front wall).

---

## 8. Staged increments (param-gated DEAD → flip → corner-debug)

Reuse the proven methodology verbatim. Each `Ek` is a dead param-gate (=0
cycle-exact) → synth FF-insertion measure → flip → corner-debug.

- **E0 (warm-up, parallel):** dcache **synchronous-read** param-gate scaffold
  (`DCACHE_SYNC_READ=0` dead). Measures the Phase-C achievable floor AND exercises
  the multi-front-flip muscle. Down payment on Phase C. (See §9.)
- **E1:** EX register on the ALU lane-0 CDB, param-gated DEAD (`EX_PIPE=0`,
  byte-identical). Add `prf_ready`-seeded scheduled wakeup confirmation (already
  present). Synth: confirm the dead reg is cycle-exact.
- **E2:** bypass network spanning EX_reg (lane-0), still DEAD-gated. The bypass is
  *unused* at `EX_PIPE=0` (the CDB is still combinational).
- **E3:** FLIP `EX_PIPE=1` lane-0. Full gate ladder. Corner-debug the +1-shift
  (store-to-load forward timing, the FR present-guard interaction, branch-resolve
  timing). Re-synth: the headline should leave the execute cone.
- **E4:** extend to lane-1 (`alu_cdb2`) + MUL latency offset.
- **E5 (decision point):** measure IPC vs the 10–15 % budget. If within → keystone
  done (no replay). If over → E6.
- **E6 (replay, only if E5 over budget):** speculative load wakeup + IQ
  retain-until-confirmed (§5.3a) + poison vector (§5.4) + bounded speculation depth
  (§5.5), param-gated DEAD (`LOAD_SPEC=0`). FLIP with the **full SMP/litmus matrix**
  at each sub-step. Highest risk.

---

## 9. The E0 warm-up scaffold (dcache synchronous read) — concrete

The dcache read (`dcache.veryl:342-377`) is combinational. A real compiler SRAM is
**synchronous**: present the index at N, the tag/data outputs are registered and
valid at N+1. Scaffold:
- `param DCACHE_SYNC_READ: bit = 0` (default DEAD = today's combinational read).
- When 1: register the read index/address; the `hit_*`/`rdata_*`/way-mux operate on
  the *registered* arrays → the dcache read becomes a pipeline stage (the load
  Stage-B splits into address-present | data-available).
- DEAD (=0): outputs fall through combinationally = byte-identical (cycle-exact),
  validated by N1 boot-cy match.
- Measure: synth FF-insertion on the read output gives the **Phase-C achievable CP
  floor** cheaply, *before* committing to the full sync-read flip. This is the
  down-payment number that sizes Phase C.

⚠️ Scope note: the dcache read feeds load Stage-B, the AMO read, the slot-1
hit-only port, the store RMW, and the fill path. A *truly* cycle-exact dead scaffold
must fall through **all** of these at `=0`. If that proves invasive, the
**FF-insertion synth experiment** (insert a throwaway register, measure, discard)
delivers the Phase-C floor number without the dead-scaffold plumbing — do that first
to decide whether the full scaffold is worth landing this session.

### 9.1 ⚡ MEASURED (2026-06-30) — the dcache READ is **not** the headline
FF-insertion experiment done: registered all six dcache load-read outputs
(`o_rdata`, `o_rdata_next`, `o_hit_safe`, `o_rdata2`, `o_rdata2_next`, `o_hit2`) and
re-synthesized. **Result: the top-60 critical paths are byte-identical to baseline**
— headline still `head → n_inflight[5]` 15.300, and `head → valid_1` 14.870 fills 55
of the top 60. Neither the read register nor `rs1_rdy` appears in the top-60 (both
are below 14.870). **Conclusion: registering the dcache read moves nothing in the
headline region** — the read is a deep-floor front (≤14.565), exactly as the
inventory predicted (`sram_inventory.md`: read and fill are *separate* fronts).

**This corrects a plan assumption.** `deep_pipeline_sram_plan.md` said "Phase C
dcache sync-read cuts the `valid_*` front." It does NOT: `valid_*` is the dcache
**FILL/invalidate** path, and both headline fronts share the **commit-store front**:

```
head → commit_store_fire → store AGU (agu_addr_iss) → dmem_vaddr
     → MMU translate (u_dmem_mmu.u_mmu.tlb_vpn → tlb_level → tlb_valid)
     → { commit decision → n_inflight   (15.300, tallest) }
     → { dcache fill/invalidate → valid_*  (14.870, 55/60 paths, broadest) }
```

Stores **compute their address and translate at COMMIT** here (the
`commit_store_fire → AGU → MMU` sweep), so the MMU sits on the commit critical path
feeding *both* the free-list and the dcache fill.

**→ The first headline-moving lever is to stage the commit-store front**, i.e.
**pre-translate stores at execute** (latch the translated PA into the store buffer
at execute/Stage-A, so commit just drains a ready PA with no head→AGU→MMU sweep).
This serves both `n_inflight` and `valid_*` at once. The dcache **read** SRAM
migration (E0 above) stays valuable as the load-floor / SRAM down-payment, but it is
**not** what moves CP from 15.300 — sequence the **commit-store pre-translate**
(a Phase-E-adjacent, Direction-C-refined change) as the first measurable-CP step,
flipped together with the keystone's execute staging.

---

## 10. Open decisions (resolve as the campaign proceeds)
- **HIT_LATENCY** value once the load pipe is deepened (sets the speculative wake
  offset and the bypass register stage). Depends on how many stages Stage-B splits
  into (C/D).
- **IQ size** (`IQ_N=8` today) — replay's retain-until-confirmed raises occupancy;
  Phase-F growth target (16?).
- Whether MUL/FP join the **scheduled** tier (latency offset) or stay broadcast —
  measure their dependent-chain frequency first.
- Real-STA vs `veryl synth` CP as the true target (the synth tool cannot see
  exclusivity-masked false paths; a real flow would report a lower CP for the
  *current* design). Revisit if a PD/STA flow becomes available.

---

## 11. Risk register
| risk | severity | mitigation |
|---|---|---|
| replay breaks SMP atomicity (silent on 1-hart) | **critical** | litmus N2/N4 + SMP boot every sub-step; atomics excluded from spec tier |
| bypass network completeness (miss a source → stale operand) | high | dead-gate + backend-validate + ACT4; enumerate every CDB producer |
| IQ deadlock from retained speculative entries | high | bounded speculation depth; at-head escape; FR/slot-1 load bar revisited carefully |
| poison fan-out / replay storms | medium | speculation-depth bound (§5.5); fall back to broadcast past the bound |
| A.1 alone blows the budget (load-use too deep) | medium | that is exactly the E5 decision gate → proceed to replay |
| veryl sim masks an NBA hazard the FR-squash class showed | medium | Verilator cross-check (SV NBA) + backend-validate |
