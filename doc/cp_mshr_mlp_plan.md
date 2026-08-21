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
