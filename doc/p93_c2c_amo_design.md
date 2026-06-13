# P9.3 — Cache-to-cache transfer + in-cache AMO/LR-SC

Phase 9 step 3 (see the Phase 9 plan): retire the two remaining "big hammer"
mechanisms left from the broadcast/write-through era:

1. **Recall round-trip shortening (cache-to-cache transfer)**: a remote
   request hitting a line *owned* at the directory currently waits out
   recall → owner WB → home merge → re-LOOKUP → HWAIT → stream. The WB
   already passes through the shared write channel, so the waiting
   requester captures the line *directly off the WB* and streams it —
   owner-to-requester data transfer through the home, no second lookup.
2. **In-cache AMO / LR-SC**: the bus-wide sticky AMO lock + force-miss
   re-fill (M9.4) is replaced by MESI ownership: the AMO read acquires the
   line E/M (RFO), the RMW value is read locally, and the commit write
   merges locally (line → M) with **no bus transaction**. Atomicity comes
   from ownership + a commit-time replay backstop, not from locking the
   world.

## Why the lock can go

P9.2 made every store globally ordered through ownership: a remote hart
cannot read or write a line we hold E/M without going through the home,
which recalls it from us first. So if we hold the line E/M continuously
from the AMO's value capture to its commit write, *no remote access to
that line exists in between* — the RMW is atomic by construction, and only
accesses to that one line are ever delayed.

## Part 1 — c2c transfer (mem_ctrl fast path)

- mem_ctrl gains the granted write's data lanes (`i_w_lanes`, wired from
  the SoC's write channel).
- A slot waiting in LOOKUP on line L (the lookup verdict keeps coming back
  `owned`, recall in flight) captures a granted **WB** to L: buffer ← WB
  lanes, grant state per policy (RFO → M-capable; READ → S, same
  anti-ping-pong policy as the lookup hit), then → STREAM.
- Directory: the WB merge already clears `owned` + the writer's sharer
  bit; a new one-line port (`cadd2`) adds the requester (and sets `owned`
  for an RFO) at the same edge, ordered after the WB clear.
- Exclusions: the writer is the capturing slot's own hart (self-recall /
  own-eviction WB — keep the re-lookup path), and N=1 (no remote WBs).
- The same-cycle `lk_go` race does not exist: a WB arriving for line L
  implies the directory still shows L owned this cycle, so `lk_hit_ok`
  is false.

## Part 2 — in-cache AMO / LR-SC

### Read side (value capture)

`i_amo_read` changes meaning from "force a coherent re-fill" to
"ownership-required read":

- hit on an **E/M** way → serve like a normal hit (no stall, no bus).
- hit on an **S** way → upgrade: raise an RFO fill of the same line
  (in-place victim via the existing `f_match` path), serve after DONE.
- miss → RFO fill, serve after DONE.

The force-miss machinery (`amo_force_trigger`, `amo_filled_q`, the
invalidate-then-refill detour and its writeback-buffer capture) is
deleted. LR uses the same path (issue_amo_read covers LR), so an LR
leaves the line E here — which is what makes the SC write local.

### Write side (commit)

A new local-write mode on the combined port (`i_wen_local`, asserted by
the core for AMO/SC commit writes to in-cache-eligible addresses): merge
into the hitting **E/M** way, set dirty, **no write-channel request, no
grant wait**. If the line is no longer owned here (departed since
capture), the write does not fire — the core's watch (below) replays the
op instead. Eligibility = cacheable DRAM and not a tohost page (same
exclusions as the fast-store classifier); ineligible AMO/SC writes keep
the legacy write-through path.

### Atomicity backstop: the AMO watch (mirror of the SC watch)

Ownership can be lost between capture and commit (a remote RFO recalls
the line, our own younger load evicts it, …). A registered per-hart
watch — armed at the AMO read's issue ack with the line address, cleared
at commit/redirect — poisons when the line departs (presence-check port
+ inv/evict events, the same sources as `sc_watch`). A poisoned AMO at
the head suppresses its store and **replays from its own PC**
(`commit_amo_replay`, the `commit_sc_replay` shape): the re-executed AMO
re-acquires ownership and re-reads. If the watch is clean at the commit
write, the line was owned continuously ⇒ the RMW is atomic.

SC keeps its existing watch/poison/replay; its commit write just becomes
the local merge (LR took the line E, so a still-present reservation means
we still own it; presence loss already poisons via `sc_watch`).

### Forward progress: a bounded ownership pin

Pure optimistic replay can livelock (two harts RFO-stealing the line from
each other before either commits). The dcache gets a **pin** port
(`i_pin_v/i_pin_addr`, from the core): while pinned and a saturating
counter is below PIN_LIMIT (64), a probe targeting the pinned line is
**deferred** (not answered; the recall engine waits — it already holds
probes until answered). The counter makes the defer bounded, so no
deadlock cycle through the single recall engine can close; past the limit
the probe proceeds and the watch/replay path takes over correctness.
The core pins the AMO-watch line, else (best effort) a freshly-taken LR
reservation line, giving the LR→SC window the same protection.

### What gets deleted

- memory_bus: the sticky AMO lock (`amo_holder_q`/`amo_held_q`, both
  channel pinnings, the WB pierce), `i_amo_inflight`, `o_amo_lock_held`.
- mem_ctrl: `i_amo_locked`, the RFO accept lock-gating (`acc_lock_blk`).
- dcache: force-miss (`i_amo_read`'s old behavior, `amo_filled_q`,
  `amo_force_trigger` and its capture/departure arbitration arms).
- core: `o_amo_inflight`, `amo_read_pending_q`, `amo_issue_lock_ok` (the
  1-cycle AMO issue bubble disappears), rob `o_has_pending_amo`.

### Ordering notes (RVWMO)

- The AMO write still fires at commit, after `sb_empty` (the existing
  `c_is_amo` retire gate), so release ordering vs older stores holds.
- The read-side gates stay: `sb_ld_ovl` (AMO bytes must come from memory
  after the drain), `.aq`/`.rl` arms in `load_blocks_on_store`.
- AMO-total order per location = ownership serialization at the home
  (per-line accept blocking + recall), checked by litmus test 7; the
  RMW-vs-fence interplay by tests 6/8 and the full battery.

## Staging

- **P9.3.A**: c2c transfer only (mem_ctrl + l2 cadd2 + SoC wiring).
  Full regression before B.
- **P9.3.B**: in-cache AMO/LR-SC + lock deletion, one commit.
