# Block N — N-entry MSHR / memory-level parallelism (design plan, 2026-08-21)

Phase 14's remaining structural front, picked on structural grounds after Block L1 shipped
(`c593d6d`): the machine has **no memory-level parallelism at all**. Every level of the read
path — the core's load-miss queue, the L1 D-cache fill engine, the core's DRAM read channel,
and the shared `mem_ctrl` transaction slot — is **exactly one deep**, so a second miss cannot
start until the first one has streamed its last beat.

This doc is the design phase — resolve the hard questions **before** RTL, the campaign's proven
methodology (`cp_dcache_sync_read_plan.md` §10/§11). Companion docs: `cp_store_queue_plan.md`
Part II (the block this follows), `p92_mesi_design.md` / `p93_c2c_amo_design.md` (the coherence
protocol the fill path carries), `phase14_frontend_deep_ooo_plan.md` (the campaign's ledger).

---

## 1. The census entry point, and the question it does NOT answer

Block L1 left `lsr` as the largest single sole-blocker bucket in the load-issue census:
**745,356 cy = 6.03 %** of the N=1 boot (12,370,000). Block T established that this bucket is
**100 % dcache miss** — bucket 12 (`lwl_drive && dcache_stall`), not a port-contention or
turnaround artifact.

`feedback_census_must_match_the_path` says to ask, before pricing any mechanism: **is that
mechanism even in this census's population?** For an N-entry MSHR the answer is *partly*, and
the part that is missing is the whole point:

- The census counts cycles in which **a new load cannot issue** because the LSR is occupied by
  an older missing load. Handing that older load off to an MSHR frees the LSR, so more entries
  do move cycles out of this bucket.
- But the census says nothing about whether the **second miss can be serviced concurrently**.
  It cannot (§2). Freeing the LSR only lets the younger load *reach* the dcache and discover it
  is stalled; its fill still waits for the incumbent's to finish. The queue gets deeper; the
  memory system does not get wider.

So the bucket is the symptom this block starts from, and the *ceiling* has to be measured a
different way (§4) — the census will overstate what N entries alone can recover, exactly the
error `feedback_measure_ceiling_dont_estimate` was written for.

---

## 2. Audit: the read path is one deep at four consecutive levels

### 2.1 The core's "MSHR" is a 2-entry load-completion queue, not a cache miss register

`heliodor_core.veryl` has two hand-unrolled entries, A and B — `mshra_*_q` / `mshrb_*_q` — with
per-entry ports all the way out to the ROB (`mshr_abort_poison` / `mshr_abort_poison2`,
`mshr_poison_idx` / `mshr_poison_idx2`, the LQ record ports). There is no `MSHR_N` parameter;
only `const MSHR_TRACE`. Making this N-deep is a **structural rewrite, not a sizing change**.

Two capture paths exist, and only one is live:

| path | gate | state |
|---|---|---|
| issue-side capture (`mshr_capture_own` / `_que`) | `mshr_plain_load` | **dead** — `let mshr_plain_load: logic = 1'b0` since LSU 2-stage step-1 |
| Stage-B handoff (`mshr_cap_b_own` / `_que`) | `LSR_MSHR_B` | **live** (L4 step-2, `2319734`) |

An entry holds `own_q` (this entry started the fill; it latches `dc_fill_rdata` at DONE) or
queued (`!own_q`; the replay engine re-injects its address once the dcache is idle). So the
"two entries = miss-under-miss" claim is true *at the queue*, and false *at the memory system*:
the queued entry's line read has not started and cannot start until the owner's fill retires.

The eligibility qualifier `lsr_mshr_ok` excludes faulting, FP, uncached, cross-dword and
store-forwarded loads — and, notably, `mshr_free_ok = !mshra_v_q || !mshrb_v_q`. `LSR_MSHR_B_QUE_FILLONLY = 1`
further restricts the queued handoff to case (a) *"the dcache is filling someone else's line"*,
excluding case (b) *"our own miss is waiting for the bus grant"*. The reason is recorded in the
source and is itself a symptom of the missing structure:

> `o_miss_valid` … "needs `i_ren` held to keep requesting the bus, so a core that captured the
> load into an MSHR on the raw miss and dropped `i_ren` would strand the fill".

That is the textbook job of an MSHR — **hold the miss address and keep the request alive
independently of the requester** — and the dcache does not have one. The LSR is standing in for
it by holding `i_ren`.

### 2.2 The D-cache fill engine is a single FSM

`dcache.veryl:415`:

```
enum State: logic<2> { IDLE = 2'd0, FILL = 2'd1, DONE = 2'd2 }
var state, fill_count, fill_index, fill_tag, fill_way, fill_offset, fill_aborted, fill_rfo
```

One `state`, one `fill_*` set. IDLE → (bus grant) → FILL (8 beats, advancing only on granted
cycles) → DONE → IDLE. `o_stall` is asserted for the whole of FILL and DONE. Load misses and
store-RFO fills share this one engine (`load_sel` / `srfo_sel`). Hit-under-miss exists
(`dc_hit_safe` / `ld0_hum_ok`) — a *hitting* load may proceed during a fill — but **miss-under-miss
does not**: a second missing line has nowhere to record itself.

There is also no **secondary-miss merge**: two loads to the *same* missing line are two separate
misses, the second discovering a hit only after the first fill completes.

### 2.3 The core exports ONE read channel, shared by four requesters

`heliodor_core.veryl:12149`:

```
assign o_dmem_addr = if ic_route ? is_mem_addr : dc_mem_addr;
assign o_dmem_req  = if ic_route ? is_req      : dc_mem_req;
```

`ic_route` muxes the **instruction side** (I-cache line fill and the I-side page-table walker)
onto the same single request port as the D-side (`dc_mem_req` wins). So an I-cache miss and a
D-cache miss are mutually exclusive at the boundary — with W2b's finding that 74 % of the Block-W
front-end stall census is I-cache miss, this is not a corner case.

The I-cache fill engine is one deep too (`var filling: logic`, one `fill_*` set), so the
single channel is not the only limit on that side — but it is the one that has already been
paid for. `icache.veryl:72`:

> P9.6: prefetch is now OFF. With fills routed through `mem_ctrl` (shared with the D-cache read
> port), a speculative prefetch HOLDS the single per-hart slot for a whole transaction and blocks
> a subsequent demand D-cache fill — measured net-negative on boot (N=1 13.84M→13.30M, N=2
> 18.77M→17.25M).

**A built, working next-line prefetcher (S11.2) is switched off because of §2.4.** That is a
second prize riding on the same change, and it is measured, not estimated: the arm exists
(`s11_pf_en`) and flipping it back is free once the slot is no longer shared.

### 2.4 `mem_ctrl` has one slot per hart — and says so

`mem_ctrl.veryl:24`:

> One slot per hart (an L1 dcache has a single fill FSM, so one outstanding line read per hart
> is the structural maximum). Slots progress independently: hart B's L2-hit fill streams while
> hart A waits out its DRAM latency — the "multiple outstanding" half of P9.1.

P9.1 already built the **split-transaction machinery** (ACCEPT → LOOKUP → HWAIT/DWAIT → GATHER →
INSTALL → STREAM, per-line serialization, the recall engine, the directory updates). What it
sized to one was the **slot count per hart**, and it sized it that way *because* §2.2 is one deep.
This is the cheapest of the four levels to widen: the state is already a per-slot array indexed
by hart, and the arbitration between slots (L2 lookup port, DRAM gather beats, install port)
already exists for the cross-hart case.

### 2.5 The latency being serialized

`mem_ctrl` params: `DRAM_WAIT = 20`, `HIT_WAIT = 2`; STREAM is 8 beats.

| outcome | modeled cycles, accept → last beat |
|---|---|
| L2 hit | 1 accept + 1 lookup + 2 HWAIT + 8 stream ≈ **12** |
| L2 miss | + 20 DWAIT + 8 gather (bus-arbitrated) + install ≈ **38+** |

Every one of those cycles is exclusive: no other line read by this hart — instruction or data —
can be in flight.

### 2.6 Summary of the four levels

| level | depth today | what N-deep needs |
|---|---|---|
| core load-miss queue (`mshra/b`) | 2 (hand-unrolled, one live capture path) | array + per-entry ports collapsed to indexed ones |
| L1 D-cache fill engine | **1** | N fill contexts + secondary-miss merge + per-entry `i_ren` independence |
| core DRAM read channel | **1** (shared with I-side) | request/grant vectors, or a request queue |
| `mem_ctrl` slot | **1 per hart** | slot array widened past `N_HARTS` |

**An N-entry core MSHR alone moves nothing.** The binding level is §2.2/§2.3.

---

## 3. Open design questions (to be answered before RTL)

1. **Where does the miss address live?** In the dcache (a true MSHR file, `i_ren`-independent) or
   in the core (extending today's queue and keeping the dcache a slave)? The `QUE_FILLONLY`
   restriction and the `i_ren`-holding contract say the dcache; the existing squash/poison/LQ
   plumbing says the core. A split is possible: address+way reservation in the cache, load
   completion state in the core.
2. **Secondary misses.** Do two loads to the same line share one fill (merge into one MSHR entry
   with two waiters) or stay two entries? Merging is the larger win per entry and the standard
   design, but it needs a per-entry waiter list.
3. **Way reservation / eviction interlock.** Two concurrent fills into the same set must not pick
   the same victim way, and neither may evict a line another in-flight fill is filling. Today
   `victim_way` is chosen at fill start with nothing else in flight.
4. **Write-back buffer.** A dirty victim is captured into the single `wb_*` buffer at fill start
   ("guaranteed free — `fill_blocked_wb` holds the start otherwise"). N concurrent fills means N
   possible dirty victims.
5. **Coherence.** `fill_aborted` is per-fill state; the invalidate checks (`inv_fill_hit`) compare
   against the single `fill_index`/`fill_tag`. Each in-flight fill needs its own abort bit and its
   own comparator, and the P9.2 directory's per-line serialization in `mem_ctrl` must still hold
   with several slots per hart.
6. **Ordering.** RVWMO: loads may complete out of order (the LQ already exists and does the
   disambiguation), but an RFO fill for a store and a load fill to the same line must not race.
   `mem_ctrl`'s per-line serialization covers the L2 side; the L1 side needs the same rule.
7. **How wide?** Modern cores run 8–16. The first useful step is **2**, because that is the step
   that proves the four levels can be widened at all; the sizing question comes after.

---

## 4. Ceiling first (`feedback_measure_ceiling_dont_estimate`)

Before any of §3, price the prize by **deleting the cost and reading the cycle count**, not by
converting a census bucket into cycles.

**O1 — latency oracle. MEASURED 2026-08-21.** Set `DRAM_WAIT = 1`, `HIT_WAIT = 1` and boot.

| arm | N=1 boot | vs default |
|---|---|---|
| default (`DRAM_WAIT=20`, `HIT_WAIT=2`) | 12,370,000 (`00bcc050`) | — |
| **O1** (`DRAM_WAIT=1`, `HIT_WAIT=1`) | **11,480,000 (`00af2bc0`)** | **−890,000 = −7.20 %** |

This is unsound (it pretends DRAM and the L2 answer instantly) but it is the right *shape* of
bound for N2/N3, and the reason is worth stating precisely: **a fill's cost splits into latency
and transfer, and MLP can only overlap the latency half.** The transfer half — 8 STREAM beats,
plus 8 gather beats on an L2 miss — moves one dword per cycle over resources that stay singular
no matter how many miss contexts exist (`o_hrdata` is one dword; the DRAM read channel is one
beat per grant). O1 deletes exactly the latency half and leaves the transfer half alone, so

> **any depth of MSHR wins less than 890,000 cy (7.20 %) on the N=1 boot.**

For scale, Block L1 shipped at −6.15 % on the same gate, so this is a real block, not a rounding
error — but it is bounded, and the bound is now known before any RTL exists.

**O1 does NOT bound N1.** Splitting the I and D channels does not delete latency; it deletes a
*conflict* between two requesters that O1 leaves fully intact (O1 still has one channel). N1's
prize is disjoint from these 890,000 cycles and is measured separately by census bucket 101.

**O1b — split the oracle.** `DRAM_WAIT` alone vs `HIT_WAIT` alone separates "L2 misses are the
cost" from "even L2 hits are the cost", which decides whether the win lives in the L1↔L2 path
(cheap, 2 slots) or in the DRAM path (needs deeper queues and the gather arbitration).

**O2 — the I/D channel oracle.** Give the instruction side its own `mem_ctrl` slot (§2.3/§2.4)
and boot. This is the *sound* half of the same idea, and W2b's 74 % says it may be the larger
half. It also needs no MSHR at all.

Then, and only then, census the population that N entries could serve:
- fills in flight while another line's miss is known and waiting,
- captures declined because `mshr_free_ok = 0`,
- `QUE_FILLONLY` declines (case (b): our own miss waiting for the grant).

---

## 5. Three ways in, ranked by what they change structurally

### N1 — split the instruction and data read channels

The **sound** half of §2.3/§2.4, and the one that needs no MSHR at all.

| level | change |
|---|---|
| `heliodor_core` | give the I-side (I-fill + I-PTW) its own `o_imemr_*` request/grant/rdata port; delete the `ic_route` mux and the `ic_owns` transaction latch |
| `heliodor_soc` / `_smp` | `ctrl_hreq` / `ctrl_haddr` / … become 2 entries per hart |
| `mem_ctrl` | separate the two meanings of `N_HARTS`: **slot count** (`N_SLOTS = 2*N_HARTS`, hart id = `slot >> 1`) from **directory width** (`i_l2_c_shr`, `i_iv_sharers`, `o_probe_v`, `i_probe_ack` stay `N_HARTS` — they address L1 caches, not transactions). The per-line accept blocking, the lookup-port selector, the c2c capture and the recall engine already iterate over slots and generalize unchanged; `o_bus_rreq[h]` stays per-hart with a 2-way internal pick |
| `l2cache` | `i_busy_line` / `i_busy_v` (the install victim exclusion) follow the slot count, not the hart count |
| `memory_bus` | **unchanged** — DRAM gather beats stay one request per hart; `mem_ctrl` aggregates its two slots onto the single `o_bus_rreq[h]` |

Why two slots per hart are genuinely concurrent (and not just queued): after ACCEPT the shared
resources are already time-sliced by construction — the **L2 lookup port** serves one slot per
cycle and accepts are one per cycle, the **DRAM gather** rides the bus read-channel rotation
(so two gathering slots serialize exactly as two harts do today, and because gathers serialize
the **install port** still cannot collide), and **STREAM** runs out of each slot's own `buf_all`
with its own `o_hrdata`. So two L2-**hit** fills overlap completely, and two L2-**miss** fills
overlap their DWAIT and serialize only their gather beats — which is the latency/transfer split
of §4 falling out of the existing structure rather than being designed in.

Unlocks: I/D fill concurrency (W2b: 74 % of the front-end stall census is I-cache miss) **and**
`s11_pf_en` — the built next-line prefetcher that P9.6 had to switch off *because* the slot is
shared. Does not touch the MSHR, the dcache fill FSM, or coherence: the L2-side per-line
serialization that makes two slots safe is the same rule that already makes N harts safe.

### N2 — a real MSHR file inside the D-cache

⚠️ Scope warning from the audit: miss *detection* itself is written against the single FSM —
`lo_miss` / `hi_miss` / `srfo_want` / `uncached_active` all carry `state == State::IDLE`, and the
fill target (`f_index_raw` / `f_tag_raw` / `f_offset_raw`) is a combinational function of the
**currently presented** request. So N2 is not "add entries beside the FSM"; it is re-deriving
miss detection and fill targeting from a request that is *latched in an MSHR entry* rather than
live on `i_addr`. That is the same change that removes the `i_ren`-holding contract (§2.1) and
makes `QUE_FILLONLY` unnecessary — which is the argument for doing it, and the reason it is not
the first step.

The textbook structure the machine does not have: N miss contexts, each holding its own
address / way reservation / abort bit, keeping its own bus request alive independently of the
requester (`i_ren`), with **secondary-miss merge** so two loads to one line are one fill. This
is what §3.1–§3.6 have to be answered for, and it is the only path to true miss-under-miss.

### N3 — widen the core's load-miss queue past 2

Cheapest to write (collapse `mshra_*`/`mshrb_*` into arrays, one poison/LQ port pair instead of
two) and **worth nothing on its own** (§2.6). Only meaningful once N2 exists — then it is the
matching sizing change.

Order follows structure, not IPC: **N1, then N2, then N3.** N1 is independently shippable, needs
no new correctness argument, and its prize is already measured on both sides (the prefetch
regression is the same number read backwards).

---

## 6. The Block N census (buckets 96-107) and how to read it

Added to `heliodor_core.veryl`'s `DBG_CENSUS` block; read off the N=1 boot tb.

| # | predicate | what it prices |
|---|---|---|
| 96 | `fill_busy_q` | the serialized resource itself: cycles with a D-cache fill in flight |
| 97 | 96 `&& (mshra_queued \|\| mshrb_queued)` | **N2's ceiling** — a second miss is already known while the first fills |
| 98 | 96 `&& nx_miss_wait` | the LSR *also* holds a missing load (a third) |
| 99 | `lsr_mshr_elig && !mshr_free_ok && nx_miss_wait` | **N3's population** — handoffs declined only because the queue was full |
| 100 | `nx_fo_rej` | handoffs declined by `QUE_FILLONLY` (case (b): our own miss awaiting the grant) |
| 101 | `ic_owns && dc_mem_req` | **N1's ceiling** — the I-side holds the channel while the D-side wants it |
| 102 | `is_req && dc_mem_req && !ic_owns` | the I-side yields (the same conflict, other direction) |
| 103 | `dc_mem_req && !i_dmem_grant` | D requests not granted (bus + `mem_ctrl` back-pressure) |
| 104 / 105 | `ic_route` / `dc_mem_req` | channel occupancy by side (denominators) |
| 106 | `dc_miss_valid` | fill starts (events — the divisor for average fill cost) |
| 107 | `!fill_busy_q && !ic_route && !dc_mem_req` | the memory system is completely idle |

Reading rules for this block, both learned the hard way:

- **97 and 101 are disjoint prizes.** 97 lives inside the 890,000 cy O1 bounded; 101 does not
  (§4). Adding them is legitimate; comparing either against O1 alone is not.
- **A bucket is a place, not an amount** (`feedback_census_must_match_the_path`). 97 counts
  cycles in which a second fill *could* have been running — it does not follow that a second
  fill context recovers them, because the transfer half of both fills still contends for one
  dword per cycle. Expect the realized win to be a fraction of 97, and get the fraction by
  building the smallest arm and reading the boot, not by scaling 97.

### 6.1 Pass 1 result (N=1 boot, 2026-08-21)

`cy=00bcc050` and `instret=10424067` — **bit-identical to the default arm**, so the census is
logically neutral and the numbers below describe the shipped machine exactly.

| # | bucket | cycles | % of 12,370,000 |
|---|---|---|---|
| 96 | fill in flight | 740,402 | 5.99 % |
| 97 | … and a second miss queued | **468,688** | **3.79 %** |
| 98 | … and the LSR also holds a missing load | 155,383 | 1.26 % |
| 99 | handoff declined — queue FULL | 129,438 | 1.05 % |
| 100 | handoff declined — `QUE_FILLONLY` | 147,992 | 1.20 % |
| 101 | I-side owns the channel, D-side waiting | **146,647** | **1.19 %** |
| 102 | I-side yields to the D-side | 83,710 | 0.68 % |
| 103 | D request not granted | **1,612,034** | **13.03 %** |
| 104 | I-side using the channel | 781,134 | 6.31 % |
| 105 | D request cycles | 2,331,469 | 18.85 % |
| 106 | fill starts | 32,218 events | 23.0 cy/fill |
| 107 | memory system idle | 9,371,551 | 75.76 % |

Three things fall out, and the third one re-plans the block:

1. **The demand for MLP is real.** 97/96 = **63 %** — while a fill runs, a second miss is
   already sitting in the queue almost two thirds of the time. Together with 99 (1.05 % of
   handoffs declined purely because the 2-entry queue was full) the machine is visibly starved
   of miss contexts.
2. **N1 is smaller than the front-end census suggested.** The I-side conflict costs 146,647 cy
   = 1.19 %, not the multi-percent W2b's "74 % of front-end stalls are I-cache miss" might
   imply. The two are consistent — most I-cache misses are not *conflicting* with a D-side
   request — but it does demote N1 from "the obvious first step" to "a 1.2 % structural
   cleanup that also unlocks `s11_pf_en`".
3. **The fill FSM is not where the time goes.** The D side asks for the bus 18.85 % of the
   time and is refused 13.03 % of it, while a fill is only in flight 5.99 % of the time. So
   **most of the ungranted time is spent before a fill even starts** — 32,218 fills at 23.0
   cycles each account for the 740,402, and the other ~870,000 ungranted cycles are something
   else. Pass 2 (buckets 108-115) splits that.

### 6.2 Pass 2 result — the time is spent BEFORE the fill starts

Again `cy=00bcc050` / `instret=10424067`, bit-identical.

| # | bucket | cycles | % |
|---|---|---|---|
| 108 | ungranted **inside** a running (load) fill | 450,440 | 3.64 % |
| 109 | ungranted **before** a fill starts | 1,161,594 | 9.39 % |
| 110 | … the I-side holds the channel | 105,551 | 0.85 % |
| 111 | … an uncached/MMIO read | **0** | — |
| 112 | … `mem_ctrl` declines to ACCEPT | **1,056,043** | **8.54 %** |
| 113 | a queued MSHR entry is waiting (any reason) | 597,674 | 4.83 % |
| 114 | … with no load fill in flight at all | 128,986 | 1.04 % |
| 115 | `dcache_stall` (the core actually held) | 2,519,509 | 20.37 % |

The partitions are exact — 108 + 109 = 1,612,034 = bucket 103, and 110 + 111 + 112 = 1,161,594
= bucket 109 — so nothing is unaccounted for.

**Read this bucket carefully.** `dc_mem_req && !i_dmem_grant` counts cycles the D side is asking
the read channel for something it is not getting *this cycle*; that includes a fill's own
latency (its DWAIT/HWAIT are ungranted by construction), not only a fill that has not started.
So 108 is "load-fill latency" and 112 is "everything else the D side spends holding the channel
request up", which is where the surprise lives:

**`fill_busy_q` is set from `dc_miss_valid`, and `dc_miss_valid` never pulses for a store-RFO
fill** ("store-RFO fills never pulse it (no load to capture)", `dcache.veryl:2769`). A partial
line store that misses (or holds only S) raises a read-for-ownership fill that occupies the
`mem_ctrl` slot and holds `o_memr_req` for its whole 12-40 cycle transaction — with
`fill_busy_q = 0` the entire time. Every one of those cycles lands in 112 by construction.
Pass 3 (buckets 116-119) splits 112 by `dc_mem_rfo` to confirm it, and counts the RFO traffic.

If it holds, the largest single item in the memory path is **store ownership traffic**, not load
misses — and the campaign's picture of the D side changes shape again: L1 took stores off the
*load port*, and this says stores are still the bigger consumer one level down, at the *bus*.

---

## 7. What the census is pushing the block towards (pending pass 3)

If pass 3 confirms that 112 is store-RFO traffic, the block's first step is neither N1 nor a
general N-entry MSHR, but the narrower cut the D-cache is already half-way shaped for:

### N1′ — split the LOAD fill and the STORE-RFO fill into two fill contexts

`dcache.veryl` already computes the two miss classes **separately** and then forces them to
share one FSM:

```
let srfo_want   = i_swen && (state == IDLE) && !i_wen && !s_hit_excl && !s_full_line;
let srfo_sel_raw= srfo_want && (!miss_raw || i_sdrain_urgent);   // store wins only if urgent
let load_sel_raw= miss_raw && !(srfo_want && i_sdrain_urgent);   // ... else the load does
```

That arbitration exists *because* there is one `state` / `fill_*` set. Two contexts (one for
demand loads, one for ownership fills) delete the arbitration instead of tuning it, and they
need no secondary-miss merge and no general waiter list — the two contexts have fixed, disjoint
consumers (the MSHR/LSR completion path vs the store-drain merge).

What it still needs, and what N2 would need anyway:
- a second victim-way reservation + a second `fill_aborted` / invalidate comparator,
- the writeback buffer sized for two possible dirty victims (or an interlock that keeps the
  second context out of a set whose victim is already in the buffer),
- two `mem_ctrl` slots per hart (identical to N1's change — the slot work is shared),
- a second read channel out of the core (again the same change as N1).

So N1 and N1′ **share their entire downstream cost**; they differ only in who gets to use the
second channel. That makes the sizing question ("how many slots?") the real one, and the answer
is at least two either way.

### 6.3 Pass 3 result — it is store ownership traffic, exactly

`cy=00bcc050` / `instret=10424067` again.

| # | bucket | cycles | % |
|---|---|---|---|
| 116 | 112 ∩ an RFO fill is running | **1,056,043** | 8.54 % |
| 117 | 112 ∩ genuinely waiting for an ACCEPT | **0** | — |
| 118 | RFO request cycles | **1,515,421** | **12.25 %** |
| 119 | RFO cycles not granted | 1,107,156 | 8.95 % |

116 = 112 to the cycle and 117 = 0, so **every cycle in "mem_ctrl declines to ACCEPT" is a
store's read-for-ownership fill**, and there is no accept starvation anywhere. The D side's
single biggest consumer of the read channel is not load misses:

| consumer | request cycles | ungranted (latency) |
|---|---|---|
| **store RFO fills** | **1,515,421 (12.25 %)** | **1,107,156 (8.95 %)** |
| load fills | 740,402 (5.99 %) | 450,440 (3.64 %) |
| I-side (I-fill + I-PTW) | 781,134 (6.31 %) | — |

This re-frames the whole block. Block L1 took the committing store off the **load port**; the
census now says the store is still the larger consumer one level down, at the **bus**, where it
serializes against every load miss through the single fill FSM. `dcache_stall` totals
2,519,509 cy (20.37 %) — the machine spends a fifth of the boot with the D-cache holding the
core, and ownership traffic is the biggest single reason.

---

## 8. O3 — the RFO-off oracle

Rather than convert 1,515,421 into a prize by arithmetic (`feedback_measure_ceiling_dont_estimate`),
delete the mechanism and read the boot: force `s_full_line = 1` so every unowned drain takes the
**write-through** path and `srfo_want` is identically 0.

This is a policy change rather than an unsound hack — the write-through path already byte-merges
through `i_swstrb` and invalidates our own S copy, so a partial line is as correct as a full one.
What it gives up is write-allocate locality: subsequent stores to the same line no longer find it
owned, and subsequent loads no longer find it cached. So O3 is **two-sided** — it deletes
1.5 M cycles of ownership traffic and adds an unknown amount of re-miss traffic — and the boot
number is the net. A large win says the RFO policy itself is mis-tuned; a small win or a loss
says the traffic is buying something, and the fix is to overlap it (N1′) rather than remove it.

**O4 — the RFO-latency oracle (the clean bound for N1′).** O3 changes a policy and so measures
a *net* that mixes two effects. The bound N1′ actually needs is "what if an ownership fill cost
the load path nothing?", which is one line in `mem_ctrl`: give a slot whose transaction is an RFO
(`rfo_all[h]`) a wait of 0 (`DRAM_WAIT`/`HIT_WAIT` bypass). That is unsound (ownership cannot
arrive before the data does) but it isolates exactly what overlapping the RFO would hide, with
no locality side-effects. Run it if O3 comes back ambiguous.

### 8.1 O3 result — the place is huge, the amount is not

| arm | N=1 boot | vs default |
|---|---|---|
| default | 12,370,000 (`00bcc050`) | — |
| **O3** (`RFO_OFF=1`, every unowned drain writes through) | **11,980,000 (`00b6cce0`)** | **−390,000 = −3.15 %** |

`pass=1`, `instret=10422006` (vs 10424067 — the tiny drift is the usual boot-timing sensitivity,
not a correctness change).

| census | default | O3 |
|---|---|---|
| RFO request cycles (118) | 1,515,421 | **70,409** (only the AMO/LR ownership reads are left) |
| **`dcache_stall` (115)** | 2,519,509 | **1,285,980 (−49 %)** |
| D request not granted (103) | 1,612,034 | 714,520 |
| load fill busy (96) / starts (106) | 740,402 / 32,218 | 940,626 / 34,450 |
| a second miss queued (97) | 468,688 | 557,676 |

Two results, and the second is the one to remember:

1. **Ownership traffic really is half of `dcache_stall`.** Deleting it halves the cycles the
   D-cache holds the core, and empties bucket 112 to the cycle.
2. **Halving `dcache_stall` is worth 3.15 %, not 10 %.** The out-of-order core is already
   hiding most of that stall behind independent work — which is exactly what
   `feedback_measure_ceiling_dont_estimate` exists to catch. A census bucket is a *place*; the
   *amount* only comes from deleting the mechanism and reading the boot.

O3 also shows its own cost: fills go from 32,218 × 23.0 cy to 34,450 × 27.3 cy, i.e. more misses
*and* slower ones (a written line is no longer allocated in L1 **or** L2, so the re-read comes
from DRAM). So −3.15 % is the *net* of deleting 1.5 M cycles of ownership traffic and paying for
the lost locality — N1′, which overlaps the traffic instead of deleting it, does not pay that
second half.

### 8.2 O4 result — the clean bound on overlapping ownership traffic

| arm | N=1 boot | vs default |
|---|---|---|
| default | 12,370,000 (`00bcc050`) | — |
| O3 (`RFO_OFF`, deletes the traffic, costs locality) | 11,980,000 | −3.15 % |
| **O4** (`RFO_FAST`, deletes only the RFO's modeled latency) | **12,010,000 (`00b74210`)** | **−2.91 %** |

`pass=1`, `instret=10422007`.

| census | default | O4 |
|---|---|---|
| RFO request cycles | 1,515,421 | 1,124,248 |
| RFO ungranted (its latency) | 1,107,156 | 590,024 |
| `dcache_stall` | 2,519,509 | 2,120,463 |
| load fill busy / starts | 740,402 / 32,218 | 718,237 / 32,258 |

O4 keeps the fills (starts are within 40 of the default — the locality is untouched) and removes
only what an overlapped RFO would hide. **So N1′ is bounded at 2.91 %**, and the residual
1,124,248 RFO request cycles are the transfer half that no amount of overlap removes.

### 8.3 The block's ledger, and what it says

| step | what it overlaps / removes | measured bound (N=1 boot) |
|---|---|---|
| **N1′** load vs store-RFO fill contexts | ownership latency | **2.91 %** (O4) |
| **N1** I-side vs D-side read channel | I/D channel conflict | **1.19 %** (census 101) |
| **N2** load vs load (a real MSHR file) | the rest of the load-fill latency | ≤ 7.20 % − 2.91 % ≈ **3.1 %** (O1 minus O4) |
| N3 more queue entries | nothing on its own | — |

Total ≈ 7.2 % (O1) + 1.2 % (N1, disjoint from O1) ≈ **8.4 %**, and no single step is worth more
than 3 %. For comparison Block L1 shipped at −6.15 % with one predicate and a one-entry shadow.

That is the honest arithmetic, and it is the argument **for** taking the block on structural
grounds rather than IPC ones (`feedback_heliodor_optimize_for_structure_not_cp`,
`feedback_ooo_priority`): MLP = 1 is a capability the machine does not have, every modern core
has 8-16 miss contexts, and the three steps above share their entire downstream cost (the second
`mem_ctrl` slot, the second core read channel). Doing them separately buys 1-3 % each; doing the
slot work once and hanging all three off it is the structural change.

---

## 9. Where this leaves the block (decision point)

Everything above is measurement; none of it is RTL. The state is:

- **The structural claim is proven.** Four consecutive levels of the read path are one deep, the
  audit quotes the source comments that say so, and one built feature (`s11_pf_en`) is already
  switched off because of it.
- **The prize is bounded and modest.** 7.20 % for everything O1 covers, 1.19 % for the I/D
  conflict on top, and no single step worth more than ~3 %.
- **The first step is identified and is not the one the block was named for.** The largest
  consumer of the single read channel is *store ownership traffic*, not load misses, and
  overlapping it (N1′) is bounded at 2.91 %.
- **The downstream work is shared.** N1, N1′ and N2 all need the same two things: a second
  `mem_ctrl` slot per hart and a second read channel out of the core. That work is the block.

Per `feedback_phase_end_user_decides`, whether to spend the block here is the user's call. The
options, with what each costs and buys:

| option | work | buys |
|---|---|---|
| **A. Full block** — slot/channel widening, then N1′ + N1, N2 after | large (multi-session) | ≤ 4.1 % now, the structure for N2's ~3 % later, `s11_pf_en` back |
| **B. N1′ only** — two fill contexts + two slots, load/store fixed use | medium | ≤ 2.91 %, no MSHR rewrite, no new correctness argument beyond two victim/abort contexts |
| **C. Park the block** — record the audit + ceilings, spend the campaign elsewhere | none | the measurement is banked; nothing regresses |
| **D. O3 as a policy** — ship `RFO_OFF` (write-through for unowned partial drains) | one line | −3.15 % at N=1, but it reverses a P9.2 design decision and needs the SMP ladder to price the coherence side |

Option D is listed because the number is real and the change is one line, but it trades a
structural property (write-allocate ownership) for cycles, which is the opposite of this
campaign's stated priority — and its SMP behaviour is unmeasured (every unowned partial store
becomes a bus write + invalidate broadcast instead of a one-time ownership fetch).

### 8.4 O4 at N=2 — the gain SHRINKS with hart count

| arm | N=1 boot | N=2 SMP boot |
|---|---|---|
| default | 12,370,000 (`00bcc050`) | 16,950,000 (`0102a2f0`) |
| **O4** | 12,010,000 (`00b74210`) = **−2.91 %** | **16,590,000 (`00fd24b0`) = −2.12 %** |

This is the **opposite** of the last two blocks. Block T went −1.93 % (N=1) → −5.28 % (N=4) and
Block L1 held roughly flat; the ownership-latency prize instead *dilutes* as harts are added,
because at N=2 the memory system's time is increasingly spent on things overlapping a single
hart's RFO cannot touch (coherence recalls, cross-hart bus rotation, L2 port contention).

Two consequences for the plan:

- **Do not assume the block scales.** The N=1 ceilings in §8.3 are the *best* case; at N=2 the
  N1′ bound is 2.12 % and N=4 is likely lower still (unmeasured — the N=4 boot is a ~75 min gate,
  worth spending only if the block is taken).
- **It strengthens the structural argument and weakens the IPC one.** If the reason to build MLP
  were cycles, a prize that shrinks with width is the wrong prize. The reason to build it is that
  the machine has one miss context and every modern core has 8-16 — and that argument does not
  depend on the boot number at all.

---

## 10. Build log — N1 step 1: separate "slot" from "hart" in `mem_ctrl` / `l2cache`

`mem_ctrl` used `N_HARTS` for **two different quantities** and got away with it only because the
D-cache has one fill FSM: how many L1 caches the directory addresses (a hart count) and how many
line reads can be in flight (a slot count). Untangling them is the whole of step 1.

Introduced `param SPH` (slots per hart) and `param N_SLOTS = N_HARTS * SPH`, then split every use:

| stays per-HART | becomes per-SLOT |
|---|---|
| `i_l2_c_shr`, `i_iv_sharers`, `i_inst_oldshr`, `i_w_shr(_hi)` (directory masks) | `i_hreq/i_haddr/i_hdram/o_hgrant/o_hrdata/i_hrfo/i_iread/o_hexcl` |
| `o_probe_v`, `i_probe_ack`, `o_inv1_v`, `o_inv2_v` (they address L1s) | `st_all`/`line_all`/`gcnt_all`/`iok_all`/`conf_all`/`rfo_all`/`iread_all`/`buf_all`/… |
| `o_bus_rreq`, `i_bus_rgrant` (memory_bus is unchanged) | `lk_sel_all`, `acc_line_busy`, `accept`, `inst_go_all`, `inst_excl_w`, `o_busy_line/v` |
| `N_HARTS == 1` grant-policy tests | `l2cache`'s `i_busy_line/v` + `bm_0..3` (victim exclusion is per transaction) |

Four places needed a real **slot → hart map** (`h / SPH`, the identity at SPH=1):
- the c2c capture's "not my own writeback" test (`i_w_hart != hart_of(slot)`),
- `lk_oh`, which is ANDed with the directory's sharer mask — it must be a HART one-hot,
- `o_cadd_hart`, the directory sharer add,
- the install one-hot, which is consumed **both** as a slot mask (go/hold) and as a hart mask
  (the abort-invalidate target and the in-place-overwrite sharer test) — the hart view is now
  derived explicitly as `inst_sel_hart_oh`.

`inst_sel_h` widened 3 → 4 bits (up to 8 harts × SPH slots). The DRAM read channel stays **one
request per hart**: each slot drives `slot_bus_req`, a per-hart OR produces `o_bus_rreq[h]`, and
the hart's single grant goes to its lowest-indexed requesting slot (`slot_bus_gnt`). At SPH=1 the
`lower` term folds to 0 and this is exactly the old direct wiring.

**Verified logically identical** by diffing the generated SystemVerilog against a build of the
pre-change source: every hunk is either a rename (`N_HARTS` → `N_SLOTS`, same value at SPH=1),
`h / SPH` → `h`, or the new aggregation collapsing to `i_bus_rgrant[h] && slot_bus_req[h]` —
and in all three of its use sites `slot_bus_req` is 1 by construction (GATHER or legacy).

Next: SPH=2 with the second slot left unused (must stay cycle-identical — slot 1 never accepts,
so the lookup/accept priority encoders and the bus aggregation see no change), then wire the
core's I-side to it.

### 10.1 Step 2 — a second slot, tied off

`heliodor_soc` widens the mem_ctrl-facing wires to 2 and instantiates `mem_ctrl` / `l2cache` with
`SPH: 2`. Slot 1 is tied off (`ctrl_hreq[1] = 0`). An IDLE slot never accepts, never selects the
lookup port, never requests the bus and reports `o_busy_v = 0`, so this stage must be
**cycle-identical** — it exercises the widened priority encoders and the bus aggregation with the
second slot present but silent.

### 10.2 Step 3 — the core's instruction-side read channel (design)

Today `heliodor_core` muxes four requesters onto one port:

```
assign ic_route   = ic_owns || (is_req && !dc_mem_req);   // I-side wins only when D is idle
assign o_dmem_req = if ic_route ? is_req : dc_mem_req;
assign dc_grant   = i_dmem_grant && !ic_route;
```

Step 3 adds `o_imemr_{req,addr}` / `i_imemr_{grant,rdata}` and a const gate `ID_SPLIT`:

| | `ID_SPLIT=0` (dead) | `ID_SPLIT=1` |
|---|---|---|
| `ic_route` | unchanged | `1'b0` — the D port is the D side's, always |
| `o_imemr_req` | `1'b0` | `is_req` |
| I-side grant | `i_dmem_grant && ic_route` | `i_imemr_grant` |
| I-side data | `i_dmem_rdata` | `i_imemr_rdata` |
| `dc_grant` | `i_dmem_grant && !ic_route` | `i_dmem_grant` |

`ic_owns` / `is_ptw_q` stay: they still pick between the I-fill and the I-PTW and track the
transaction across its 8 STREAM beats — what disappears is only the *arbitration against the D
side*. On the SoC side slot 1 gets `i_hdram = 1` (an I-side mem_ctrl read is always DRAM; a
non-DRAM fetch uses the separate `o_imem` passthrough) and `i_iread = 1` (uncounted — no
directory sharer is added for an instruction fill).

#### 10.2.1 A trap in this refactor, and why N=1 caught it

Splitting one identifier into two is not a textual edit: **each occurrence's meaning is fixed by
the array it indexes, not by where it appears.** Two adjacent loops in `mem_ctrl` look identical
and mean opposite things:

```
for h in 0..? { if i_l2_c_shr[h] { lk_owner = h; } }        // directory mask -> HART
for h in 0..? { if lk_go_all[h]  { o_cadd_hart = ...; } }   // slot array    -> SLOT
```

Both were flipped the wrong way in the first pass. The one that mattered was caught by
`veryl check`'s `invalid_select` — *because this stage runs at N_HARTS=1 with SPH=2*, so a hart
mask indexed by a slot number is provably out of range. Had the first flip been made at
N_HARTS=2/SPH=2, both indices would have been in range and the bug would have been silent: the
recall engine would occasionally probe the wrong hart.

Also caught in the same sweep: `o_w_cadd_hart` (the c2c directory add) was still writing the
slot index into a hart field.

Rule for the rest of this block: **when a loop bound changes, read the loop body and classify by
the arrays it subscripts** — and do the first flip at the width where a mistake is out of range.

### 10.3 Step 3 built — the I side has its own slot

`heliodor_core` gains `o_imemr_{req,addr}` / `i_imemr_{grant,rdata}` and `const ID_SPLIT`. At 1:

- `ic_route` folds to 0 — the D side owns `o_dmem_*` unconditionally, and `o_dmem_iread` with it;
- `o_imemr_req = is_req`, `o_imemr_addr = is_mem_addr` (the existing I-PTW / I-fill sub-mux);
- `is_grant = i_imemr_grant && is_req`, and the I-side read data comes off `is_rdata`
  (`i_imemr_rdata` when split), feeding both the I-cache fill and the I-PTW dword capture.

`ic_owns` / `is_ptw_q` survive unchanged: they still choose I-PTW over I-fill and hold the
transaction across its 8 STREAM beats. Both accept sites were rewritten through `is_grant`
(`is_req && !dc_mem_req && i_dmem_grant` → `is_req && is_grant`), which is an identity at
ID_SPLIT=0 inside the `!ic_owns` arm and the correct condition at 1.

`heliodor_soc` maps slot 0 → D, slot 1 → I. `heliodor_soc_smp` builds a per-slot request bundle
(`mc_req`/`mc_addr`/`mc_dram`, slot `2h` = D and `2h+1` = I) and moves every per-hart core wire
to the even slot; `i_hdram = 1` and `i_iread = 1` are constants on the odd slots.

### 10.4 N1 MEASURED — the I side gets its own slot

| arm | N=1 boot | vs default |
|---|---|---|
| default (shared read channel) | 12,370,000 (`00bcc050`) | — |
| **ID_SPLIT=1, SPH=2** | **12,230,000 (`00ba9d70`)** | **−140,000 = −1.13 %** |

Census bucket 101 (`ic_owns && dc_mem_req` — the I side holding the channel while the D side
wants it) predicted 146,647 cy. The build recovers **140,000 of them, 95 % of the bucket.** That
is an unusually clean agreement between a census and a build for this campaign, and it is worth
noting *why* it held here when it did not for `dcache_stall` in §8.1: bucket 101 counts a
**structural conflict between two named requesters**, not a stall whose cost the out-of-order
core might already be hiding. When the census predicate IS the mechanism, the bucket is the
amount; when it is a symptom, it is not.

**One bug on the way, worth recording.** The first build booted 77 k instructions and died. The
cause was a single extra term: `is_grant = i_imemr_grant && is_req`. `mem_ctrl`'s STREAM beats do
**not** depend on `i_hreq` — `stream_ok` is `slot in STREAM && i_haddr line == line_q` — and
`is_req` can drop mid-transaction (an I-fill abandoned by a redirect). The shared path never
noticed because `ic_route` carries an `ic_owns` term that keeps routing the port for the whole
transaction. Removing the `is_req` term fixed it. The general shape: **when you split a shared
resource, the state that used to keep the shared path open is not automatically reproduced by
the new dedicated path.**

#### 10.4.1 `ID_SPLIT` must be a PARAMETER, not a const

The first full-suite run after N1 booted came back **23 passed / 229 failed** — including
single-hart tests that have nothing to do with SMP. The cause is structural, not a logic bug:
six testbenches instantiate `heliodor_core` **directly** against a simple memory model
(`test_arch_common`, `test_bench`, `test_smoke`, `test_hello`, `test_smode_plic`,
`test_linux_boot`). They have no `mem_ctrl`, so there is no second slot to give the instruction
side — with `ID_SPLIT` a module-internal `const`, they routed their I-fills to an unconnected
port and starved instruction fetch.

Rule: **a flag that creates a new EXTERNAL dependency (a port that must be wired) belongs in the
parameter list, not in a const.** A const is forced on every instantiation; the wiring it
requires is not. `ID_SPLIT` now defaults to 0 (shared path, exactly as before) and the two SoCs —
the only instantiators that own a `mem_ctrl` — pass 1.

This is the mirror of `feedback_dead_scaffold_must_constant_fold`: a const is the right home for
a scaffold that must fold away *inside* the module, and the wrong home for one whose "off" state
is what an outside instantiator needs.

#### 10.4.2 Slot numbering is not free: hart-major starves the higher harts

With `ID_SPLIT=1` the single-hart boot was fine (−1.13 %) and the arch suite passed 251/1, but
**litmus N=2 timed out and the N=2 SMP boot never reached SBI shutdown** — in both cases with
every hart still retiring instructions (hart 1 spinning in firmware, 52 M retired). Not a
deadlock: a starvation.

The first numbering was **hart-major** — slot `2h` = hart h's D side, slot `2h+1` = its I side.
`mem_ctrl` picks with two lowest-id-wins encoders: the accept arbiter, and the **single L2 lookup
port**. The second one matters more than it looks, because a slot that hits an OWNED line stays
in `ST_LOOKUP` and *re-enters the selection every cycle* while the recall engine works. Under
hart-major, hart 0 owns slots 0 and 1, so both of its transactions outrank every slot of hart 1 —
and while either of them is retrying, hart 1 cannot look anything up at all.

Renumbered **slot-major**: slots `[0, N_HARTS)` are the D side (one per hart, in hart order) and
`[N_HARTS, 2*N_HARTS)` the I side, so `hart_of(s) = s % N_HARTS`. The inter-hart order of the D
side is then exactly what the pre-Block-N module had, and the I side sits below all of it. At
SPH=1 this is the identity, same as `s / SPH` was.

Worth generalizing: **when you widen a resource that is arbitrated by a priority encoder, the
INDEX ORDER is part of the design, not bookkeeping.** Adding a second slot per hart doubled
hart 0's share of the priority space without anyone choosing that.

With slot-major numbering the suite is **252/0** and litmus N=2 comes back `cy=002ed830` —
**bit-identical to the shipped default**, which is itself informative: the litmus battery is a
handful of tight loops with essentially no I-cache misses, so splitting the I and D channels
changes nothing there. The win is a boot-shaped one, exactly as census bucket 101 said.

### 10.5 N1 result — and it SCALES with hart count

| gate | default | N1 (`ID_SPLIT=1`, `SPH=2`) |
|---|---|---|
| suite | 252/0 | **252/0** |
| **N=1 boot** | 12,370,000 (`00bcc050`) | **12,230,000 (`00ba9d70`) = −1.13 %** |
| **N=2 SMP boot** | 16,950,000 (`0102a2f0`) | **16,420,000 (`00fa8ca0`) = −3.13 %** |
| litmus N=2 | `002ed830` | `002ed830` (bit-identical) |

The N=1 number matched census bucket 101 to 95 %. **The N=2 number is nearly 3× the N=1 one**,
which the census could not have predicted — bucket 101 is a per-hart count from a single-hart
boot. Two effects compound at N=2 and neither is visible at N=1:

- there are twice as many I-side transactions competing for the same shared L2 lookup port and
  DRAM gather rotation, so every I/D conflict a split removes also removes a knock-on delay to
  the *other* hart's transactions;
- the higher hart is the one that was losing the shared channel most often (the arbiter gives
  the D side strict priority, and hart 1's D side is busiest exactly when hart 0's I side is).

This is the same shape as Block T (−1.93 % at N=1 → −5.28 % at N=4) and the opposite of the O4
ownership-latency oracle (§8.4), which diluted with width. Worth measuring N=4 before drawing the
curve, but the direction is already the useful one.

---

## 11. N1′ design — two fill contexts in the D-cache (load vs store-RFO)

With N1 shipped the downstream is built: `mem_ctrl` takes any number of slots per hart, the SoCs
route them, and the priority-order trap is understood (§10.4.2). N1′ reuses all of it and adds a
**third** requester class: the D-cache's ownership fills, separated from its demand-load fills.

Measured bound: **2.91 %** at N=1 (O4, §8.2), **2.12 %** at N=2 (§8.4) — note this one *dilutes*
with width, unlike N1.

### 11.1 What has to double inside the D-cache

The fill FSM's state is one set today (`dcache.veryl:415-439`):

| state | why a second copy is needed | difficulty |
|---|---|---|
| `state` (IDLE/FILL/DONE) | the two contexts advance independently | mechanical |
| `fill_count` / `fill_offset` | per-burst beat position and critical word | mechanical |
| `fill_index` / `fill_tag` / `fill_way` | which line each is filling | mechanical |
| `fill_rfo` | becomes a constant per context (that is the point) | folds away |
| `fill_aborted` + the `inv_fill_hit` comparators | each in-flight line needs its own remote-invalidate watch | **needs care** |
| `victim_way` / `victim_way_q` reservation | two fills must not pick the same way in the same set | **needs an interlock** |
| the writeback buffer (`wb_v`/`wb_line`/`wb_data`) | two fills can each evict a dirty victim | **needs a second buffer or a block** |

### 11.2 The two interlocks

**Same-set way collision.** `victim_way_raw` is PLRU + invalid-way preference, computed from the
tag array. Two fills that start in the same set on different cycles can pick the same victim way,
and the second would evict the line the first is still filling. Cheapest correct rule: the second
context may not START a fill whose index equals a live context's `fill_index` (a one-comparator
block, same shape as `fill_blocked_wb`). It costs nothing on the common case — an RFO and a load
miss in the same set at the same time is rare — and it is strictly conservative.

**Writeback buffer.** Today the buffer is "guaranteed free" at fill start because `fill_blocked_wb`
holds the start otherwise. With two contexts, either give the buffer a second entry or extend
`fill_blocked_wb` to mean "the buffer is occupied at all" for whichever context wants to start
second. The block is the cheaper first cut and preserves the existing invariant exactly.

### 11.3 Where the ordering argument lives

The load and the RFO contexts serve **different consumers** (the MSHR/LSR completion path vs the
store-drain merge), so there is no new forwarding or age question inside the core. The memory
ordering that matters is at the L2, and it is already handled: `mem_ctrl`'s per-line accept
blocking (`acc_line_busy`) serializes any two transactions on the same line **across all slots**,
which now includes the same hart's own load and RFO. That is the rule that made two harts safe;
it makes two contexts safe for free.

### 11.4 Suggested build order

1. `SPH: 3` and a third SoC-side slot, tied off — must be cycle-identical (as §10.1 was).
2. The D-cache's second context behind a param (`RFO_CTX`), reachable only by store-RFO fills,
   with both interlocks conservative.
3. Flip, read the boot, and check the interlocks are not the whole cost (census the two blocks).

---

## 12. The prefetch that N1 unblocks

`icache.veryl:78` still carries the whole S11.2 next-line prefetcher — `pf_pending` / `pf_line`,
the present-check against the fill and the pending line, the request path — behind
`let s11_pf_en: logic = 1'b0`. The comment above it says exactly why it is off:

> P9.6: prefetch is now OFF. With fills routed through mem_ctrl (shared with the D-cache read
> port), a speculative prefetch HOLDS the single per-hart slot for a whole transaction and blocks
> a subsequent demand D-cache fill — measured net-negative on boot (N=1 13.84M→13.30M, N=2
> 18.77M→17.25M).

**That reason is now gone**: the I side has its own slot, and a prefetch occupying it no longer
delays any D-side fill. It can still delay a *demand I-fill* (the same slot), which is the real
question the flip now asks — and it is a much smaller one than blocking the D side.

Flip `s11_pf_en` to 1 and read the boot at N=1 and N=2. This is free to try (one constant, the
machinery is intact) and it is the second prize N1 was predicted to unlock in §2.3.

### 10.6 N=4 — the gain does NOT continue; it reverses

| gate | default | N1 | delta |
|---|---|---|---|
| N=1 boot | 12,370,000 | 12,230,000 | **−1.13 %** |
| N=2 SMP | 16,950,000 | 16,420,000 | **−3.13 %** |
| **N=4 SMP** | 24,720,000 (`01793280`) | **25,180,000 (`01803760`)** | **+1.86 %** |

`pass=1`. The N=4 boot carries a ±1M timing band (CLAUDE.md), so +460,000 is inside the noise and
this is not a demonstrated regression — but it is definitely **not** the continuation of the N=2
trend, and the plan must not assume one.

The likely mechanism is the one shared resource N1 does not widen: **the L2 lookup port is one
per cycle**, and N1 doubles the number of slots contending for it (N=4 goes from 4 slots to 8).
While the I side shared the D-side port, an I-side lookup consumed a D-side slot's turn rather
than adding a new contender. The same effect is invisible at N=1 (2 slots, no contention) and
still favourable at N=2 (4 slots), which is exactly the shape observed.

If N1 is to scale, the lookup port is the next thing to look at — either a second lookup port
(the L2 directory is flops; the DATA array is the sync-read one) or a fairer selection than
lowest-id-wins among the slots in `ST_LOOKUP`. Recorded as a standing item; the ship decision for
N1 at its current shape is the user's.

### 12.1 Re-tested, and it stays OFF

| arm (all with N1 live) | N=1 boot | vs N1 |
|---|---|---|
| `s11_pf_en = 0` (shipped) | 12,230,000 (`00ba9d70`) | — |
| **`s11_pf_en = 1`** | **12,390,000 (`00bd0e70`)** | **+160,000 = +1.31 %** |

`pass=1`, `instret=10424070`. Still net-negative — and slightly *slower than the pre-N1 default*.

So P9.6's decision was right for more than the reason it recorded. Removing the D-side blocking
was necessary but not sufficient: a speculative next-line fetch still occupies **the I side's own
slot** for a whole 12-40 cycle transaction, and the demand I-fill queued behind it costs more
than the prefetch saves. The prefetcher would need to be *cancellable* (drop the speculative
transaction when a demand miss arrives) or to have a slot of its own before it pays.

Left at 0 with this measurement in the comment, so the next person does not re-derive it.

---

## 13. The fifth level: the L2 lookup port

The §2 audit counted four levels of the read path and missed one. `mem_ctrl`'s **L2 lookup port
serves one slot per cycle**, and a slot that hits an OWNED line stays in `ST_LOOKUP` re-entering
the selection every cycle until the recall engine clears the ownership. N1 doubled the number of
slots contending for that port without widening it, which is the most likely explanation for
§10.6's reversal at N=4 (4 slots → 8).

This matters far beyond N1: **N miss contexts cannot start N misses if lookups are 1/cycle.**
Every remaining step in the ledger (N1′, N2, N3) adds contenders to this same port, so it is a
prerequisite for all of them rather than a repair to one of them. It is also the campaign's own
first-layer rule — *make what already shipped actually hold* — and the same shape as Block L1's
`SB_EMPTY_EFF`: the claim ("the I and D sides proceed independently") is stronger than the
implementation, so fix the implementation rather than weaken the claim.

### 13.1 Two failures that look identical from the boot number

| | mechanism | signature in the census | fix |
|---|---|---|---|
| **starvation** | the port has spare cycles, but lowest-id-wins keeps giving them to the same slots | `wait` high while `busy` is well under 100 % | a fairer selection (round-robin / last-served) — cheap |
| **bandwidth** | 1 lookup/cycle is simply not enough | `busy` at ~100 % whenever `cont` | replicate the **directory** (it is flops); the sync-read DATA array can stay single-ported, since only a HITTING slot reads it |

### 13.2 The census (`LK_CENSUS`, DEAD at 0)

Per cycle, counted in `mem_ctrl` and printed periodically so the SMP arms need no census port
plumbing (the Block T `B2B_SUP_TRACE` trick):

| counter | meaning |
|---|---|
| `busy` | at least one slot was in `ST_LOOKUP` (the port had work) |
| `cont` | **two or more** slots were in `ST_LOOKUP` (they contended) |
| `dwait` | a D-side slot was in `ST_LOOKUP` and NOT selected |
| `iwait` | an I-side slot was in `ST_LOOKUP` and NOT selected |
| `hiwait` | the **highest-numbered D slot** was waiting — the hart the encoder ranks last, where starvation appears first |
| `ownretry` | the selected slot was re-looking-up an OWNED line (the retry that holds the port) |

Read at N=2 (where N1 wins) and N=4 (where it reverses); the *difference* between the two is the
answer, not either one alone.

### 13.3 REFUTED at N=2 — the lookup port is idle

| `LK` at cy=15,000,000 (N=2 boot, N1 live) | value | of 15 M |
|---|---|---|
| `busy` (any slot in `ST_LOOKUP`) | 158,276 | **1.06 %** |
| `cont` (**two or more** slots wanting it) | 338 | **0.002 %** |
| `dwait` / `iwait` | 42 / 299 | ~0 |
| `hiwait` (last-ranked D slot waiting) | 42 | ~0 |
| `ownretry` | 6,795 | 0.05 % |

**The port is idle.** It does work on 1 % of cycles and two slots want it on 0.002 % of them, so
neither failure mode in §13.1 is present — there is no starvation to fix and no bandwidth to add.
Scaling the contention 4× for N=4 still leaves it under 0.01 %, which cannot produce the +1.86 %
of §10.6. **The hypothesis is refuted, and it is refuted cheaply, before any RTL was written for
it.**

That is worth stating plainly because the reasoning that produced it was sound and still wrong:
"N1 doubles the contenders for a 1/cycle port" is true, and irrelevant, because the port was
never near its limit. `feedback_shared_bus_has_no_free_cycles` says to check who captures every
cycle before riding a shared bus — the mirror rule applies here: **before blaming a shared
resource for a regression, measure whether it is actually busy.**

So the +1.86 % at N=4 is still unexplained. Pass 2 widens the net to the other resources a second
slot per hart adds contenders to — per-line accept blocking, accept arbitration, the shared DRAM
read channel within a hart, the L2 install port, and the single recall engine — with N=4 as the
arm that has to show the difference.

### 13.4 Pass 2 at N=2 — every other shared resource is idle too

| `LK2`/`LK3` at cy=15,000,000 (N=2) | value | of 15 M |
|---|---|---|
| `accline` (accept refused by per-line serialization) | 891 | 0.006 % |
| `acclost` (accept refused — another slot won the cycle) | 680 | 0.005 % |
| `busboth` (a hart's D **and** I slot both wanted the DRAM channel) | 11,047 | 0.07 % |
| `instblk` (the selected INSTALL slot held) | 15,511 | 0.10 % |
| `engbusy` / `engwait` (recall engine busy / wanted while busy) | 15,520 / 14,581 | 0.10 % |

Nothing above 0.1 %. Four times that for N=4 is still under half a percent, so **no shared
resource inside `mem_ctrl` can account for +1.86 %** unless N=4 changes their behaviour in kind
rather than in degree. N=4 is running with the same counters to settle that.

If N=4 also comes back idle, the honest conclusion is that the +1.86 % is **not a structural cost
of N1 at all** but the N=4 boot's known ±1M timing sensitivity re-rolling: the same "small change,
large re-arrangement" property CLAUDE.md warns about, and half the band. That would make it a
standing item to re-measure when something else moves the N=4 number, not a defect to fix — and
the block would continue to N2 rather than stopping to widen a resource that is 99 % idle.

---

## 14. N2 design — a real MSHR file inside the D-cache

This is the capability the block is named for and the machine does not have. N1′ (§11) is a
special case of it — two fixed-purpose contexts — so N2 subsumes it and N1′ should not be built
separately (`feedback_commit_to_structural_cp_change`: commit to the structural change rather
than iterating small ones).

### 14.1 The layering, which the current code does not have

| layer | owns | today |
|---|---|---|
| **line fill** (D-cache MSHR) | the missing LINE: address, way reservation, abort bit, beat counter, who is waiting | fused into the single fill FSM, driven from the LIVE `i_addr` |
| **load completion** (core MSHR) | the missing LOAD: rob idx, pdst, funct3, poison, the deferred CDB writeback | exists (2 entries, Stage-B handoff) |

The relationship is **1:N** — one line fill can have several loads waiting on it — and that is
exactly what a secondary-miss merge is. Today it cannot exist because there is no object
representing "the line being fetched" that a second load could attach to. Note the core layer is
already right and should not be rebuilt; N2 is entirely below it.

### 14.2 The change that carries all the others

Miss *detection* is currently a function of the request presented this cycle:

```
let lo_miss: logic = i_ren && !cache_hit && !i_uncached && state == State::IDLE;
let f_index_raw = if srfo_sel_raw ? sindex : if fill_is_hi ? next_index : index;   // live i_addr
let want_fill_start = (load_sel || srfo_sel) && !fill_blocked_wb;                  // live again
```

Every `state == IDLE` term and every "which line" mux reads the live port. N2 splits this in two:

1. **allocate** (demand side): on a miss, look the line up in the MSHR file. Hit → attach (a
   secondary miss, no new fill). Miss → allocate an entry, capturing address / way / rfo.
2. **launch** (MSHR side): any allocated entry that has not started its fill requests the bus,
   *independently of whether its requester is still presenting the address*.

Step 2 is what dissolves the `i_ren`-holding contract that `dcache.veryl:2769` documents and that
forced `LSR_MSHR_B_QUE_FILLONLY = 1` in the core (§2.1): once the entry holds the address, the
core is free to drop `i_ren` and the fill is not stranded. **`QUE_FILLONLY` should be deleted as
part of N2, not before it** — it is the symptom, and removing it early re-opens the bug it was
introduced for.

### 14.3 Per-entry state, and the two interlocks (unchanged from §11.2)

Each entry needs its own `line`/`way`/`offset`/`beat`/`rfo`/`aborted` plus its own invalidate
comparator (the `inv_fill_hit` check is currently against the single `fill_index`/`fill_tag`).
The two structural interlocks are the same ones N1′ would have needed:

- **same-set way collision**: an entry may not allocate a victim way in a set where another live
  entry is filling. Cheapest correct rule is to refuse allocation on an index match — one
  comparator per entry, strictly conservative, and rare in practice.
- **writeback buffer**: today "guaranteed free at fill start" via `fill_blocked_wb`. With N
  entries either the buffer gains entries or allocation blocks while it is occupied. Block first,
  measure, then size.

Ordering needs no new argument inside the core (the load and store consumers are distinct, the LQ
already does disambiguation), and at the L2 `mem_ctrl`'s per-line accept blocking already
serializes any two transactions on the same line across all slots — the rule that made N harts
safe makes N entries safe.

### 14.4 Build order

1. **MSHR file with N=1 entry**, allocate/launch split, everything else unchanged → must be
   cycle-identical. This is the step that proves the re-derivation of miss detection is faithful,
   and it is where the real risk lives.
2. N=2 entries + both interlocks conservative → read the boot. Expect ≤ the O1 bound of 7.20 %
   minus what N1 already took.
3. Delete `QUE_FILLONLY` (and re-check the litmus case its comment cites), then size N.
4. Secondary-miss merge last — it is the largest win per entry but needs the waiter list, and
   steps 1-3 are useful without it.

### 13.5 N=4 settles it — nothing in `mem_ctrl` is busy

| counter, cy=25,000,000 (N=4 boot, N1 live) | value | of 25 M | N=2 equivalent |
|---|---|---|---|
| `busy` (lookup port had work) | 210,006 | **0.84 %** | 1.06 % |
| `cont` (2+ slots wanted it) | 812 | 0.003 % | 0.002 % |
| `hiwait` (last-ranked D slot waiting) | 106 | ~0 | ~0 |
| `accline` / `acclost` | 5,496 / 1,375 | 0.02 % / 0.005 % | 0.006 % / 0.005 % |
| `busboth` (a hart's D and I both wanting the channel) | 20,453 | 0.08 % | 0.07 % |
| `instblk` | 27,968 | 0.11 % | 0.10 % |
| `engbusy` / `engwait` | 28,852 / 26,999 | 0.12 % / 0.11 % | 0.10 % |

**Every counter is the same order of magnitude at N=4 as at N=2, and none exceeds 0.12 %.** The
465,000 cycles of §10.6 are not in any of them. Widening a resource that is 99 % idle would buy
nothing, so the L2 lookup port — and the rest of `mem_ctrl`'s shared machinery — is dismissed.

**Conclusion: the +1.86 % at N=4 is not a structural cost of N1.** It is the N=4 boot's known
±1M timing sensitivity re-rolling (CLAUDE.md), and +465,000 is under half that band. Recorded as
a standing item to re-measure whenever something else moves the N=4 number, not a defect to
repair. The block continues to N2.

Method note worth keeping: the whole investigation — hypothesis, instrumentation, refutation at
N=2, confirmation at N=4 — cost two boots and no RTL. The alternative (building a second lookup
port and reading the boot) would have cost days and produced a change that could not have helped.
**Measure whether the suspect is busy before widening it.**

### 14.5 N2.1 built — the fill state is an MSHR file (one entry)

`dcache.veryl`'s single fill context becomes `MSHR_N`-deep arrays (`m_st_q`, `m_cnt_q`,
`m_index_q`, `m_tag_q`, `m_way_q`, `m_off_q`, `m_abort_q`, `m_rfo_q`) with **read aliases** for
entry 0 named exactly as before (`state`, `fill_count`, `fill_index`, …). All 68 readers are
untouched; only the 20 writes — every one of them inside the fill `always_ff` — address the entry.

At `MSHR_N=1` this is the same registers under a different name, and the N=1 boot confirms it:
`cy=00ba9d70`, `instret=10421567`, **bit-identical to N1**.

Doing the mechanical reshape as its own step is deliberate. The risk in N2 is concentrated in one
place — re-deriving miss detection from a **latched entry** instead of the live `i_addr` (§14.2) —
and separating the reshape means that when the next step breaks something, the cause is
structural rather than a slip in renaming 88 sites.

### 14.6 N2.2 splits in two, because of a constraint N1 exposed

Writing the next step out revealed something the §14 plan glossed over: **a second MSHR entry does
not by itself give a second concurrent fill.** `mem_ctrl` holds one slot per requester class, and
the D side has exactly one. Two allocated entries would still take turns on it.

So N2.2 is two steps with different values:

**N2.2a — the MSHR file becomes real (one launch port).** Two entries, allocate decoupled from
launch, miss detection re-derived from the latched entry. Even with a single slot this buys:
- **secondary-miss merge** — a second load to a line already being fetched attaches instead of
  waiting for the fill to retire and then missing again;
- the end of the `i_ren`-holding contract, hence `QUE_FILLONLY` and the core-side restriction it
  forces (§2.1);
- `o_stall` stops meaning "a fill is in flight" and starts meaning "no entry is free".

**N2.2b — a second D-side slot (`SPH: 3`).** This is what makes two fills actually concurrent, and
it is the same wiring exercise N1 already did (core port, SoC bundle, slot-major numbering). The
O1 bound minus what N1 took is what is left to win here.

Doing 2.2a first also keeps the risky part isolated: 2.2a changes *when* a fill is recorded, 2.2b
changes *how many* can run. If the boot moves the wrong way, the two causes are separable.

### 14.7 N2.2a built — and `state == IDLE` meant THREE things, not two

The ALLOC state is in: a miss without a grant this cycle captures the line into the entry and
waits there, so the request survives its requester. `o_memr_req`/`addr`/`rfo`/`ren` come from the
entry while it is in ALLOC, the invalidate watch covers ALLOC as well as FILL, and `o_miss_valid`
fires on the ALLOC → FILL launch too (with a new per-entry `m_ld_q`, since `load_sel` is a live
signal that means nothing by then).

Restricted to a **clean victim**. Capturing a dirty victim's writeback at ALLOC would clear
`dirty` and leave the still-valid, now-stale-in-DRAM line exposed to a store for the whole grant
wait — a far wider window than the 8-cycle FILL the current design tolerates. Dirty victims keep
the pre-N2.2a behaviour until the entry gets its own dirty/tag read port.

**The bug worth recording.** The first build ran 35.6 M instructions without finishing. I had
split the twelve `state == State::IDLE` sites into two classes — "the arrays are free" (stores,
which ran during the old grant wait and must keep running) and "no entry yet" (miss detection) —
and that split was right as far as it went. It missed a third:

> **`uncached_active` and `amo_upg` are not array tests; they COMPETE FOR THE READ CHANNEL.**

An MMIO read allowed to fire during ALLOC asserts `o_memr_req` with its own address, wins the
single `i_memr_grant`, and the allocated entry — watching only `i_memr_grant` — takes that grant
as its own launch and enters FILL against a transaction that was never its. Both are back on
`state == IDLE`; an MMIO read arriving during ALLOC simply does not assert `o_data_valid`, so the
core waits, which is correct and costs nothing.

Generalizing: **when you split an overloaded predicate, the granularity is set by who READS it,
not by what it looks like it means.** Three readers, three classes — array occupancy, entry
occupancy, and channel arbitration — and the third only becomes visible once something else can
hold the channel.

### 14.8 The bisect answers it: ALLOC is right, dropping `o_stall` is not

Including `m_alloc` in `o_stall` makes the N=1 boot come back `cy=00ba9d70`,
`instret=10421567` — **bit-identical to N2.1**. So:

- **the ALLOC state itself is correct** — capturing the line into the entry and waiting there is
  exactly equivalent to the old "hold in IDLE", cycle for cycle;
- **the failure was entirely in letting `o_stall` drop.** `miss` is built from `miss_raw`, which
  is IDLE-gated, so an allocated entry silently stops asserting it. The core then sees "not
  stalled" together with "no data", and 35.6 M instructions later the boot has not finished.

That is a better outcome than a fix would have been, because it separates the two things N2.2a
was bundling:

| | what it is | status |
|---|---|---|
| the entry **holds the line** independently of `i_ren` | the MSHR property; what `QUE_FILLONLY` exists to work around | **works, bit-identical** |
| the D-cache stops stalling while an entry waits | non-blocking behaviour; needs the CORE to handle "no stall, no data" | **needs core-side work, deferred** |

Revised order: ship ALLOC **with** the stall (a pure structural change, no behaviour delta), then
take the first real prize by deleting `QUE_FILLONLY` — the restriction that exists only because
the fill used to be stranded when `i_ren` dropped. Non-blocking D-cache behaviour becomes its own
step, paired with the core-side change that gives "not stalled, no data" a meaning.

Method note: the bisect cost one boot and converted "N2.2a is broken" into "one term of `o_stall`
is broken", with the rest proven bit-identical. Isolating a suspect term is cheaper than reading
a 35 M-instruction trace.

### 14.9 `QUE_FILLONLY=0` — the predicted failure IS fixed, a different one appears

With ALLOC in place, flipping `LSR_MSHR_B_QUE_FILLONLY` to 0:

| test | before N2.2a | with ALLOC |
|---|---|---|
| litmus N=2 (the failure the const's comment records) | retires 0 from a fill | **pass**, `cy=003037c0` |
| `rv64ui-ma_data` | pass | **fail** |
| everything else | pass | pass (251/252) |

The first line is the point: the const exists because case (b) — our own miss waiting for the bus
grant — stranded the fill when the Stage-B handoff dropped `i_ren`. **ALLOC closes exactly that
hole, and the test that documented it now passes.** The theory predicted a specific failure and
the predicted fix removes it.

The second line is a *different* composition problem, not a return of the first. A misaligned
load spans two lines and fills them **sequentially**: `hi_miss` requires `cache_hit` (the lo line
already present) *and* `state == IDLE`. So the hi-side fill can only be detected after the lo-side
fill has fully retired to IDLE — and a Stage-B handoff that happens across the lo-side ALLOC
leaves nothing in the pipe to re-present the hi half. `lsr_mshr_ok` excludes `lsr_dc_load_next`
(cross-dword spans never hand off), so the interaction is indirect and needs its own diagnosis.

Left at 1 with this evidence in the comment. The fix belongs with the step that makes the D-cache
non-blocking (§14.8), because both need the same thing: a miss that is *recorded* rather than
*re-detected*, including the hi half of a span.

### 14.10 The ALLOC state is entered 14 times in a 12 M-cycle boot

§14.9 left two things to fix together — let `o_stall` drop during ALLOC (a), and record the hi
half of a misaligned span (b) — with the prize named as census bucket 100, "handoff declined by
`QUE_FILLONLY`". Before building either, the bucket was **split by the D-cache's reason for
stalling**, because a bucket names a *place* and not an *amount* and because a population has to
be checked against the mechanism that would serve it (`feedback_census_must_match_the_path`).

`dcache.veryl` gained `o_mshr_alloc` (an entry is in `State::ALLOC`; its line is `o_memr_addr`,
since ALLOC drives the read channel from the entry and excludes `filling`/`uncached_active`) and
`o_stall_why[7:0]`, a decomposition of the `o_stall` OR into reason classes. The core's
`LSR_MSHR_B_QUE_FILLONLY` bit became `LSR_MSHR_B_QUE_SCOPE`:

| scope | which stall cycles may hand off | |
|---|---|---|
| **0** | `fill_busy_q` only | the shipped arm — case (a) |
| **1** | + an MSHR entry holds **our** line (`dc_alloc_ours`) | case (b), the one ALLOC was built for |
| **2** | any stall | the blanket arm |

**Scope 1 is correct and useless.** The full suite passes 252/0 — so the precise case-(b) handoff
is safe, and the whole `rv64ui-ma_data` failure of §14.9 lives in the *rest* of scope 2. But the
N=1 boot comes back `cy=00ba9d70`, `instret=10421567` — **bit-identical**. Not "small": identical.
The handoff never fires.

The census says why:

| N=1 boot, 12,230,000 cy | value |
|---|---|
| **`State::ALLOC` cycles, any requester** | **14** |
| bucket 100 slice where an entry holds a line (case (b)) | **0** |
| bucket 100 total (`fillonly`) | 72,615 |
| … a fill IS running (`state == FILL`, `fill_busy_q` low) | 39,986 |
| … the registered Stage-A hit path (`dhit_*`) | 24,701 |
| … an inv race / sync-read gap / MMIO | 23,854 |
| … a miss not yet allocated / DONE / a write | 125 / 771 / 0 |

**Fourteen cycles.** The state that N2.2a was built to add — hold the missing line while waiting
for a bus grant — is entered fourteen times in a twelve-million-cycle boot. A load's fill request
is granted the cycle it is made; `fill_alloc_fire` needs `!i_memr_grant`, and after N1 gave the D
side its own `mem_ctrl` slot that condition is essentially never true. The `prefill_accept=0` line
of the earlier census said the same thing and was not believed hard enough: **there is no
pre-launch wait for a load fill to overlap.**

So `QUE_FILLONLY` was guarding an empty population, and the "prize" of deleting it is not case (b)
at all. What bucket 100 actually contains is 55 % **"a fill is running that `fill_busy_q` cannot
see"** — `o_miss_valid` is qualified by `m_ld_q`, so a store-RFO fill never sets the core's
tracker — plus 34 % `dhit_miss` / 33 % inv-and-gap cycles, which are the load's *first* Stage-B
cycle, before the D-cache has evaluated its own miss. Those last two are where `ma_data` breaks:
handing off there hands off a load whose miss has not been recorded anywhere.

Consequences for the block:

1. **(a) and (b) are not the next step, and they were not one step.** Making `o_stall` droppable
   during ALLOC buys nothing while ALLOC lasts 14 cycles. The span fix (b) is a real bug but it is
   only reachable through scope 2, which is not a shape worth shipping.
2. **`fill_busy_q` means the wrong thing** — "a fill I asked for" rather than "the D-cache is
   filling". It gates the Stage-B handoff *and* arms `replay_q`, so during an RFO fill the core
   both declines the handoff and lets a queued entry spin the replay engine over the port. One
   definition fixes both. Whether it is worth doing is a 0.33 %-of-boot question (39,986 cy), so
   it is a cleanup, not a lever.
3. **N2's remaining value is entirely in the second entry**, not in the allocate/launch split.
   Overlapping the 32,565 fill starts × ~23 cy needs two fills in flight = N2.2b's second
   `mem_ctrl` slot. ALLOC was never on that path.

Method note, and the reason this cost two boots instead of a week: the step that would have been
built here (non-blocking `o_stall` + span recording, both non-trivial) was priced first by
splitting the bucket that justified it. The bucket's largest slice turned out to be a measurement
artefact and its named slice turned out to be zero. **Split the bucket before building for it.**

### 14.11 …and the same blind spot was mislabelling 8.7 % of the boot

`fill_busy_q` mattering more than it looked led to one more counter, because §6.2/§8 had built the
block's picture on buckets that all read `!fill_busy_q`. Bucket 109 ("ungranted BEFORE a fill
starts", 1,061,519 cy = **8.68 %** of the N=1 boot) and its remainder 112 ("`mem_ctrl` declines to
ACCEPT", 1,035,087 = 8.46 %) are the two largest single numbers this block has produced. Adding
`nx_pre && (D-cache state == FILL)`:

| N=1 boot, 12,230,000 cy | value |
|---|---|
| D-cache `State::FILL` cycles, **any** requester | **2,119,006** |
| `fill_busy_q` cycles (bucket 96) | 741,563 |
| bucket 109 "ungranted BEFORE a fill starts" | 1,061,519 |
| … of which the D-cache **IS** filling | **1,061,504 = 99.9986 %** |

**There is no pre-fill accept wait. There never was.** `o_miss_valid` is qualified by `m_ld_q`, so
a store-RFO fill never sets `fill_busy_q`; every one of that fill's ungranted burst beats was
therefore counted as "waiting to start". The core sees 741,563 of the D-cache's 2,119,006 fill
cycles — **35 %** — and the missing 1.38 M are ownership fetches.

So the block's "the read channel's biggest consumer is store RFO" (§6.3) stands and is if anything
understated, but the **shape** recorded next to it does not: bucket 112 was read as arbitration
pressure at `mem_ctrl` (which is what motivated §13's lookup-port hypothesis, itself refuted by
measurement). It is not arbitration. It is the RFO fill's own DRAM latency and transfer —
precisely the thing O4 priced at **−2.91 %** and precisely the thing only a second fill context
can overlap. Two counters that disagreed about the same 1.06 M cycles, and the disagreement was
the whole finding.

Corrections to carry forward:

- **`prefill_accept=0` was already saying this** and was recorded as "true accept wait = 0" without
  following it to "then what are the other 1.03 M cycles?". A zero in one bucket is a claim about
  its neighbours.
- **Any bucket qualified by `fill_busy_q` describes load fills only.** 96/97/98 (the MLP≥2 ceiling),
  107 (memory idle), 108/109 and their children, and the Stage-B handoff gate all inherit it.
- The fix is one line — `fill_busy` should be the D-cache's `filling`, exported, not the core's
  load-fill tracker — and it changes behaviour in two places at once (the handoff gate, and
  `replay_q`'s arming, which currently lets a queued entry spin the replay engine over the port
  for the whole of an RFO fill). Worth doing as a correctness-of-meaning cleanup; not a lever
  (§14.10 item 2).

**Method.** Both §14.10 and this section came from the same move — take the counter that justifies
the next build and split it by something the counter itself cannot see. The first split found a
state entered 14 times; the second found 8.7 % of the boot filed under the wrong heading. Neither
needed RTL. `feedback_census_must_match_the_path`, twice, on the census that was written to answer
it the first time.
