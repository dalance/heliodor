# CP Direction C — store-commit / dmem-port separation (area cost, ~0 IPC)

Seeded 2026-06-27 after the user chose Direction C over IPC-pipelining. Goal:
**decouple the slow-store commit decision (`rob_commit_ack` → commit cluster:
`n_inflight` / `redirect_pc_q` / `mhpm*` / `mip`) from the issuing LOAD's dcache
front**, so the ~25 ns synth critical path (a real single-cycle path, confirmed via
the FF-insertion test — see `cp_pipelining_strategy.md` §0 + memory
`feedback_ff_insertion_falsepath_test`) loses its top cones at **area cost, no IPC
loss**. Companion: `doc/cp_pipelining_strategy.md` (Direction C), `lsu_pipeline_plan.md`.

## 1. The coupling (grounded, `veryl synth --dump-timing` on `lsu-phase1-wip`)

The top-1500 synth endpoints are ALL the commit cluster, every one starting at
`head[0]` (ROB head FF) and threading the shared front:

```
head → ROB blk_cand argmin → IQ issue-select → PRF → AGU → MMU TLB → PMP
     → dcache tag/RAM → o_stall(=dcache_stall) → rob_commit_ack → n_inflight / redirect / mhpm
```

The front (`head … dcache`, ~21 ns) is the **issuing LOAD's** datapath
(`i_addr = agu_addr_iss`). It reaches the commit cluster through one signal:

- `dcache.veryl:1692  o_stall = (state==FILL) || miss || (state==DONE) || write_during_fill || write_wait_grant`
- `miss` (`dcache.veryl:481,484`) = `i_ren && !cache_hit && …` — the **load's
  combinational tag-compare**, the slow front.
- `heliodor_core.veryl:3219  rob_commit_ack &= !(c_is_store && !sb_elig && (dcache_stall || …))`

So a **slow store** (`!sb_elig`: AMO / SC / misaligned / MMIO / Sv39-TLB-miss) at
the ROB head has its commit/free-list-pop/redirect/hpm-bump gated by the issuing
load's `miss`. It is a REAL single-cycle path: the slow store and the load share the
dcache MAIN port (`cpu_req = i_wen || i_ren`, `dcache.veryl:421`), so the store must
wait while a load drives+misses the port.

**Why plain stores are NOT the problem (already decoupled):** an `sb_elig` store
retires into the store buffer and drains later through the dcache's **separate
store-drain port** (`i_saddr` / `i_swen`, `dcache.veryl:98-119`), which "coexists
with a load read." Its commit gate is `sb_full && !sb_merge_ok` (`:3220`), no
`dcache_stall`. The coupling is exclusively the **main-port slow stores**.

**Why the store, not the load, normally wins:** when a slow store is actually
driving (`store_drive = commit_store_fire && !load_walk_busy && !fast_store`,
`:5184`), the load is held (`load_blocks_on_store`, `:5298`). The coupling lives in
the window where the slow store is at the head but **waiting** (`store_drive=0`, e.g.
`!sb_empty`/grant/fill) and a load issues+misses — the load's `miss` then extends the
store's wait combinationally. Cannot be cured by dropping `miss` from the gate: it
reflects the real shared-port conflict. The prior session's "register the
commit-drain stall" broke SMP AMO atomicity (a +1-cycle commit slip lets a remote
hit interleave) — that is the FF-test telling us the commit DECISION is single-cycle.
**This plan does NOT register the commit; it moves the store WRITE to a
load-decoupled port, keeping the commit decision single-cycle.**

## 2. Key enabler — the AMO commit write is already a "write into an owned line"

The in-cache AMO (P9.3) reads+computes at EXECUTE; at COMMIT it only **writes the
RMW result into an E/M-owned line** (`wenl_fires = i_wen && i_wen_excl && IDLE &&
hit_excl`, `dcache.veryl:816`), with the `amo_watch`/`amo_poison` mechanism replaying
if the line was stolen. That is **structurally identical** to the store-drain port's
local merge (`store_can_drain = i_swen && IDLE && !i_wen && s_hit_excl`,
`dcache.veryl:650`). So the slow-store commit write can ride the **already
load-decoupled store-drain port** instead of needing a brand-new tag+data port.

## 3. Design fork

- **C1 (recommended) — reuse/extend the store-drain port.** Route the slow-store
  commit write (AMO i_wen_excl merge; misaligned partial WT; Sv39 store) through the
  existing `i_saddr`/`i_swen` channel (extended to carry exclusive/AMO data + partial
  strobes + the watch/poison interplay). Gate the slow-store commit on the
  store-drain ack (`dc_sdrain_ack`, load-decoupled) instead of `dcache_stall`. Lowest
  area (one existing port, +data/strobe width), reuses verified drain infra.
- **C2 — dedicated 2nd commit port.** Add a separate tag-compare + data-write port
  for commit-side stores. Cleanest isolation, but a real 2nd data-write port on the
  `logic<512>[SETS]` array (dual-write RMW arbitration) → most area. Fallback if C1's
  AMO/coherence interplay proves intractable.

## 4. Staging (escalate only on green; gates per `feedback_regression_cadence`)

0. **Confirm coupling** — synth shows `head→…→o_stall.miss→rob_commit_ack→n_inflight`.
   DONE (this session).
1. **Misaligned + Sv39 slow stores → store-drain port.** The simplest non-AMO slow
   stores: route their commit write off the main `i_wen` path onto the drain port;
   change their commit gate to the drain ack. Gate: `default` 251/0 → N1 boot.
2. **AMO/SC → store-drain port** (the hard one: `i_wen_excl` merge + `amo_watch`/
   `amo_poison` must hold on the new port; RFO-on-miss when not E/M). Gate: rv64ua +
   `default` → **litmus N2/N4** → N2/N4 SMP boot → Verilator SMP (the decisive
   atomicity gates).
3. **MMIO store gate** — MMIO doesn't touch the dcache (bus path); just drop the
   conservative `dcache_stall` term from its commit gate (it needs only `!sb_empty`).
4. **Re-synth + IPC.** Confirm `n_inflight`/`redirect`/`mhpm` no longer ride the load
   `miss` (CP top cones drop toward the load's own front / the next real wall).
   Re-baseline boot cycles + CoreMark/Dhrystone (expect ~0 IPC change — the store now
   commits in the window it previously waited the load out).

## 5. Hard gates (memory-ordering is not separable)

`default veryl test` 251/0 + `--backend-validate` + N1 boot cy + **litmus N2/N4** +
N2/N4 SMP boot + Verilator SMP. AMO atomicity (Stage 2) breaks silently on
single-hart tests — only litmus/SMP catches it. The `lsu-phase1-wip` load split is
unrelated here; this plan targets the commit/store side and can land on master
independently (the commit cluster is master's #2 cone behind the load).

## 6. Open questions for the user

- C1 vs C2 (reuse store-drain port vs new port) — recommend C1.
- Acceptable area delta for the extended drain port (data+strobe width, watch logic).
- Land on master directly (commit cluster is master #2) or stack on `lsu-phase1-wip`
  (where it is #1)? Recommend master — independent, and makes the win measurable.
