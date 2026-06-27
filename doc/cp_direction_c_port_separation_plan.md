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

## 7. RESULT — C1 drain-ack variant FAILED (2026-06-27); re-evaluation + new plan

Implemented C1 exactly as §3 (route the eligible cacheable AMO/SC commit merge
through the store-drain port with an exclusive mode `i_swen_excl`, gate the AMO
retire on `dc_excl_drain_ack` instead of `dcache_stall`). **Functionally green**
(default 251/0, rv64ua+backend-validate, ACT4 zaamo/zalrsc/zabha/zacas incl
amocas.q/zacaszabha/svadu, litmus N2 2.17M / N4 5.35M, N1 boot 11.47M cy-unchanged,
N2 SMP 15.88M cycle-IDENTICAL to baseline, N4 SMP 21.39M) — IPC-neutral, and a
real cas_q-mismatch deadlock was found+fixed (gate must wait on the ack only when
a write is actually pending, not for every drain-eligible AMO). Saved as
`doc/cp_c1_amo_drain_routing.patch`; reverted from the tree.

**But CP REGRESSED +1.4 ns (25.105 → 26.510 ns)** — the opposite of the goal.
Root cause (bisected: not the gate, not `dc_i_wen`, not the live-MMU address):
routing the AMO commit to the drain port puts the **drain-port tag-compare**
(`stag`/`shit_0`/`store_can_drain` → `o_excl_drain_ack`) onto the n_inflight cone,
~1.4 ns longer than the main-port path it replaced. **The premise of §3 is wrong
for AMOs:** "gate on the drain ack = decoupled & short" holds for the store BUFFER
(which retires on buffer-ROOM `sb_merge_ok`, the merge is background) but NOT for
the AMO, which must gate on the *merge itself* (`dc_excl_drain_ack` = a tag
compare). Routing just swaps one tag-compare-gated commit for another.

### 7.1 Megacone segmentation (baseline 25.105 ns, `head[0] → n_inflight[5]`)

| segment | dur | what |
|---|---|---|
| ROB store-age argmin tree (`blk_cand`) | ~4.2 ns | oldest blocking-store age (already a depth-5 pairwise-argmin tree) |
| IQ load-issue select (`cand0`/`iss0`) | ~3.15 ns | pick the issuing load |
| issue→AGU wiring | ~2.2 ns | |
| MMU translate (TLB) | ~4.4 ns | already tree-ized (TLB match clz) |
| PMP | ~2.0 ns | already tree-ized |
| DCACHE tag/RAM | ~4.6 ns | the issuing load's tag compare / data read |
| commit-gate (`dcache_stall`→`rob_commit_ack`) | ~2.0 ns | the §1 coupling |
| FREELIST `n_inflight` | ~1.7 ns | inflight counter update |

It is the **load's single-cycle issue→execute path (~18 ns) extended into the
commit (~4 ns) via `dcache_stall`**. Every piece is already CP-optimized — a
balanced multi-front wall, no cheap single-cone win. The only no/low-IPC
structural lever is **cutting `dcache_stall → rob_commit_ack` (~4 ns → ~21 ns)**;
below 21 ns needs load pipelining (IPC cost, = the parked `lsu-phase1-wip` split).

### 7.2 NEW plan — slow-store COMPLETION buffer (deferred merge), not drain-ack

The cut must make the slow-store retire gate use **registered** state, never the
live merge tag-compare. So slow stores must retire like fast stores: into a
completion structure on **buffer-room / a registered condition**, with the
write/merge done in the **background**. A 1-entry slow-completion slot suffices
(slow stores already serialize behind `sb_empty`).

**The crux is AMO/SC atomicity across a deferred merge** (misaligned/MMIO have
none). Invariant: the line must not depart between the AMO's read (execute) and
its background merge. Design:

- AMO read at execute arms the watch **and the ownership PIN** (already exists,
  P9.3 — defers remote probes for a bounded window).
- At the head the AMO retires iff: slot free **and the watch is clean** (line
  still owned — a *registered* `!amo_poison_q`, NOT a live tag compare). If
  poisoned → `commit_amo_replay` (unchanged — it has not retired yet).
- On retire the merge is pushed into the slot; **the pin holds the line owned
  until the background merge fires** (`store_can_drain`, local, needs IDLE).
  While a deferred merge is pending, **suppress new fill starts** so the merge
  takes the next IDLE cycle — bounding retire→merge to ≤1 fill (≤40) < pin bound
  (64). The watch/pin CLEAR moves from retire to the **merge** (not retire).
- A departed line after retire must be impossible (pin); if the pin ever expired
  the retired AMO could not replay — so fill-suppression + the bound are the
  safety argument, validated by litmus N4 / SMP / Verilator.

Staging: (1) misaligned+MMIO → slot (no atomicity; validates the mechanism;
no CP win yet — AMO still on `dcache_stall`). (2) AMO/SC → slot with the pinned
deferred merge (cuts the last `dcache_stall` feeder → CP drops toward ~21 ns).
Gates per §5 — litmus N2/N4 + N2/N4 SMP + Verilator are decisive for stage 2.
Note: `sb_merge_ok` (fast-store buffer, via MMU) is ALSO a co-critical n_inflight
feeder (§7.1) — re-synth after stage 2 to confirm the cut actually moves CP and
the new wall is the load path, not a residual buffer-commit cone.

### 7.3 KEY SIMPLIFICATION — AMO merge stays SYNCHRONOUS, gate goes registered

A completion buffer / deferred merge is NOT needed for the AMO (only for
misaligned/MMIO). Insight: **during the AMO's commit cycle loads are BLOCKED**
(`load_blocks_on_store = issue_is_load && store_drive`), so no load issues → no
miss → `fill_start_fire = 0`. Combined with the ownership PIN (defers probes →
no `wenl_probe_clash`) and the line being E/M-owned (no bus `i_inv` — an owned
line is recalled by a probe, not invalidated), **every clash term of `wenl_fires`
is guaranteed false**. So when the dcache is IDLE and the line is pin-owned, the
AMO commit merge ALWAYS fires this cycle — it cannot be blocked.

Therefore the AMO retire can gate on **registered preconditions that guarantee
the merge** instead of the live merge result:

```
retire AMO when:  sb_empty (release order, unchanged)
               && dcache state == IDLE          (state FF compare — SHORT, not via i_addr/miss)
               && amo_pin_active_q              (pin covers the watched line — registered)
               && !amo_poison_q                 (watch clean — registered, existing)
```

`dcache_stall` (which carries the issuing load's `miss` via the shared i_addr
mux) is GONE from the AMO branch. The live `hit_excl`/`wenl_fires` still drive
the dcache data write (correct, off the commit cone). No buffer, no deferral, no
extra retire→merge window — the merge is same-cycle as today, only the GATE
changed. This is fundamentally different from the prior session's "register the
stall" (which slipped the commit +1 cycle and opened an atomicity window): here
the commit does NOT slip; registered preconditions just *predict* the guaranteed
same-cycle merge.

Edge case — PIN EXPIRY (bounded 64): if the pin lapses before the AMO commits
(rare — AMOs issue at the head, so execute≈commit; only a >64-cycle fill storm
in between), `amo_pin_active_q=0` and the gate would stall with no way to re-arm
(the head AMO is not re-issuing its read). Recover by REUSING the existing replay:
`amo at head && watch valid && !amo_pin_active_q && !amo_poison_q` ⇒ poison ⇒
`commit_amo_replay` ⇒ re-fetch → re-read → re-arm pin. Conservative (may replay a
still-owned line) but safe and rare.

dcache exposes two registered outputs: `o_state_idle` (state==IDLE) and
`o_amo_pin_active` (`!pin_cnt_q[6] && pin_line_q == i_chk3_addr[63:6]` — the pin
covers the AMO-watch line). Misaligned/MMIO still need the §7.2 slot (no pin to
lean on), but they are rare; AMO is the common atomic case and the clean win.

### 7.4 IMPLEMENTED (2026-06-27) — gate on `amo_owned_q`, NOT the pin

Gating on `o_amo_pin_active` (§7.3) FAILED: the pin RELEASES at each AMO's merge
(`wenl_fires`, by design — lets a waiting hart take the line) and the `!= pin_line`
re-arm guard then blocks a back-to-back AMO to the SAME line from re-arming, so
`dc_amo_pin_active` reads 0 at the next AMO's commit → deadlock (ACT4 zaamo hung;
rv64ua passed only because its AMOs are sparse). Re-arming on an expired pin
(`|| pin_cnt_q[6]`) fixed that but reintroduced an **SMP livelock** (litmus N4
TIMED OUT at 30 M cy) — the local hart re-pins every 64 cycles and starves the
remote. **The pin must not be repurposed as the gate predictor.**

Final design: leave the pin UNCHANGED (it keeps deferring probes for forward
progress) and gate on a separate REGISTERED ownership flag:

- dcache exposes `o_amo_owned` = the AMO-watch line is E/M-owned (chk3 hit in an
  excl way, on the watch's registered PA — not the live i_addr/miss port) and
  `o_amo_probe_clash` = a same-cycle unpinned probe is recalling that line (a
  short probe-addr compare, no tag-RAM).
- core registers `amo_owned_q <= dc_amo_owned` and gates the AMO commit on
  `dc_state_idle && amo_owned_q && !dc_amo_probe_clash` (plus `!sb_empty`). A
  departed line drops `amo_owned_q` AND sets `amo_poison_q` → `commit_amo_replay`.
- `amo_owned_q` PERSISTS across back-to-back AMOs (the line stays M-owned), so no
  pin-release deadlock; and the pin is untouched, so no livelock.
- merge guarantee unchanged (loads blocked ⇒ no fill clash; E/M ⇒ no bus inv;
  `!dc_amo_probe_clash` ⇒ no probe clash) — `wenl_fires` fires the cycle the gate
  retires, so atomicity holds with no deferral, no completion buffer.
- The pin-lapse replay (§7.3) is GONE — ownership/departure is fully covered by
  `amo_owned_q` + the existing `amo_poison_q` replay.

Gated to the WATCHED in-cache real-AMO only (`amo_at_head_incache = amo_watch_valid_q
&& rob_commit_idx==amo_watch_rob_q && amo_incache_q`, all registered). SC uses
`sc_watch` (not `amo_watch`) so its `amo_owned_q` would be wrong → SC keeps the
dcache_stall gate (TODO: an `sc_owned_q` mirror). MMIO/tohost AMOs and misaligned
stores also keep dcache_stall.

VERIFIED: default 251/0 · rv64ua+backend-validate 19/19 · ACT4
zaamo18/zalrsc4/zabha18/zacas5/zacaszabha2 all pass · litmus N2 2.17M / **N4 5.35M
(cycle-identical to baseline — no livelock, no IPC cost)**. CP 25.355 ns (+0.25 ns
gate mux; the AMO is OFF the dcache_stall cone, but SC + misaligned + MMIO still
hold it, so the headline only drops once they are cut too — next steps). dcache
+27 lines, core +60 lines (much smaller/cleaner than the §3 drain-ack attempt).

NEXT: (a) SC → `sc_owned_q` mirror (same shape, on `sc_watch_addr_q`); (b)
misaligned + MMIO → the §7.2 completion slot; then re-synth — only when ALL slow
stores leave `dcache_stall` does `n_inflight` drop off the load front (~25→~21 ns).

## 8. VERDICT — Direction C is NOT the lever (≤1.3 ns); STOP (2026-06-27)

Before extending the AMO step to SC/misaligned/MMIO, measured the actual ceiling
by FORCING the commit terms off the dcache/MMU in synth (functionally broken,
CP-isolation only):

| variant | CP | endpoint |
|---|---|---|
| baseline | 25.105 ns | head → n_inflight |
| AMO via `amo_owned_q` (real) | 25.355 ns | head → n_inflight (+0.25 mux) |
| slow-store `dcache_stall`→0 | 24.775 ns | head → n_inflight (**−0.33**) |
| **+ fast-store `sb_full`→0** | 23.825 ns | head → **valid_2** (**−1.28**, cone left n_inflight) |

So cutting the WHOLE commit cone off the dcache — both the slow-store
`dcache_stall` (Direction C's target) AND the fast-store-buffer `sb_merge_ok`
(via the MMU-translated PA → `sb_match`, which Direction C never addressed) —
buys only **~1.3 ns**, and the residual CP (23.8 ns) is a pure dcache-internal
fill/victim path (`head → MMU → srfo/fill-victim → valid bit`), i.e. the load's
own issue→execute datapath. **`dcache_stall` was never the bottleneck** (−0.33 ns
alone); the §1 premise mis-identified the cone. The megacone (§7.1) is a balanced
multi-front wall: issue-select 7.3 + MMU/PMP 6.5 + dcache 4.6 dominate, and the
commit tail is only ~1.3 ns of slack. Below ~24 ns needs PIPELINING the
issue→execute path (the parked `lsu-phase1-wip` load split — IPC cost), not
commit-side decoupling.

DECISION: abandon Direction C. The `amo_owned_q` AMO step is correct and fully
validated (litmus N4 / N2-N4 SMP green) but NET-NEGATIVE in isolation (+0.25 ns
CP, +1.8 % N4-SMP IPC for a ≤1.3 ns ceiling it cannot reach alone), so it is NOT
committed — reverted from the tree. Both negative-result attempts are preserved
as patches (`doc/cp_c1_amo_drain_routing.patch` = §3 drain-ack; the amo_owned_q
step is recoverable from this doc) for whoever revisits the commit cluster. The
real CP work is the load issue→execute pipeline (IPC trade) or accepting ~25 ns.
