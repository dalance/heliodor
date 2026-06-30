# Phase C — dcache synchronous-read (the commit-store→dcache wall body)

The next structural boundary below the MEM_PIPE PA-latch. **MEASURED 2026-06-30**
(gate trace, after the AS-b refutation): the binding wall — `head→n_inflight`
14.130 ns at FETCH_REG=1, *and* the same front leaking into the scheduler as
`head→rs1_rdy` 12.920 — is the **dcache LOOKUP**, not the MMU and not the select.

This doc plans the dcache **synchronous read** (= the SRAM migration of the dcache
arrays, `sram_inventory.md` rows 1/2). It is one front of the *coordinated*
deep-pipeline flip (`deep_pipeline_sram_plan.md`): it flips together with A-EXE
(CDB register), the front-end, and the vector vrf — a single-front flip is ~0.4 ns
whack-a-mole (proven). Companion done-work: `cp_mmu_dcache_pipeline_plan.md`
(MMU→dcache PA-latch = MEM_PIPE M1–M4, committed `d3b4b9f`).

---

## 1. The measured target (gate trace, 2026-06-30)

`--dump-timing` of `head[0] → rs1_rdy[0]` (12.920 ns; the n_inflight 14.130 path
shares the same `head→commit_store→MMU→dcache` front, just ending at the free-list
counter instead of the scheduler):

```
0.00  head (FF Q) → commit (arch_regs) → commit_store_fire             ~2.96
      → iq_issue_op → dmem_eff_priv → MMU (vm_enabled) → m_pa_q → dmem_pa_m  ~4.05   (MMU ~1.1)
      → dcache i_addr → RAM Q (tag) → next_tag cmp → next_hit → miss
        → srfo_want → index → RAM Q (2nd) → f_tag cmp → fm_0 → plru_way
        → victim_way → vic_valid → vic_dirty → fill_blocked_wb → load_sel
        → filling → dc_mem_req → i_dmem_grant → fill_start_fire → i_wen
        → wenl_fires → state → dcache_stall                            ~10.13   (dcache LOOKUP ~6.1)
      → iss_reads_dmem → iq_issue_valid → slot0_grant                  ~11.12
      → prf_ready (×7 mux2 wakeup-write) → rs1_rdy                      ~12.92   (wakeup tail ~2.4)
```

**~6.1 ns (the bulk) is the dcache combinational lookup.** Sub-breakdown (gate
trace deltas):

| range | sub-cone | ~ns |
|---|---|---|
| 4.05→4.94 | `i_addr → tag RAM read` (incl. RAM Q +0.525) | ~0.9 |
| 4.94→6.30 | `next_tag cmp → next_hit → miss → srfo_want → index` | ~1.4 |
| 6.30→7.00 | 2nd RAM read (fill-victim indexed `f_index`) | ~0.7 |
| 7.00→10.13 | **`f_tag → fm → plru → victim → vic_dirty → fill_blocked → load_sel → filling → dc_mem_req → grant → fill_start → i_wen → state → dcache_stall`** | **~3.1** |

🚨 **The DOMINANT chunk is the fill-victim/PLRU/state/stall cone (~3.1 ns), NOT the
tag read (~0.9) or data read.** The tag/data reads feed it, but the depth is the
miss→fill-arbitration→`dcache_stall` generation. **Implication: registering the
data way-mux (shape (a)) alone will NOT move CP** — the cut requires the
hit/miss + fill-victim decision to come from *registered* state so `dcache_stall`
is a shallow function of regs (§3 shape (b)+, the fill cone behind a register).
The MMU is only ~1.1 ns (commit-store pre-translate already capped that at ~2.7 %,
`cp_commit_store_pretranslate_plan.md`). **The lever is the dcache fill/stall cone,
not the MMU and not the raw array read.**

MEM_PIPE already registers the *PA* (`m_pa_q`) between the MMU and the dcache; it
did NOT register anything *inside* the dcache. Phase C registers the **next**
boundary: the array read → the hit/fill cone.

---

## 2. The arrays and their ports (`sram_inventory.md` rows 1–2, `dcache.veryl`)

| array | size | ports today | real SRAM target |
|---|---|---|---|
| `tags_0..3` (`:249`) | 64×52 ×4 | **13R1W** | register the tag read → 1RW, or replicate ×4 |
| `valid_0..3` (`:245`), `excl/dirty` | 64×1 ×4 | many-R 1W | flop (tiny) — stay combinational |
| `data_0..3` (`:256`) | 64×512 ×4 | **9R4W** | register the **way-mux** (9R→1R) → 1RW per way; serialize the 4 writes via a write-merge buffer |
| `plru` (`:283`) | 64×3 | RMW | flop |

The **13 tag read sites** (hit-compare, `next_*` next-dword forward, `s*` store-
drain match, `f_*` fill-victim, `inv*`/`probe` coherence, `i_addr2` slot-1) are why
the tags are "13R1W — the 2nd hardest" and the data "9R4W — the hardest". A true
1RW SRAM cannot serve all of them combinationally; resolving the ports is the
*precondition*, not an afterthought.

---

## 3. The shape: tag-then-data, 2-stage lookup

Standard pipelined cache. Split the single combinational lookup into two cycles:

- **Stage R (cycle N)** — present `index`; read `tags/valid` (the main hit port);
  compute `hit_way`, `cache_hit`, `miss`. Register {`hit_way`, `cache_hit`,
  `index`, `offset`, the request meta}.
- **Stage D (cycle N+1)** — read **only the hit way's** `data[index]` (the
  registered way-mux → **1 read port**, the `9R→1R` reduction), `rd_dword`,
  forward to the CDB. The fill/victim/PLRU/state cone runs from the *registered*
  Stage-R outputs.

**The primary lever is NOT the data read — it is registering the hit/miss + fill-
victim decision** so that `dcache_stall` (which gates the issue grant, the binding
~3.1 ns cone of §1) becomes a shallow function of registered state. Stage R
computes and registers {`cache_hit`, `hit_way`, `miss`, `f_index`, `victim_way`,
`vic_dirty`, `srfo_sel`}; Stage D consumes those regs → the fill-arbitration /
`dcache_stall` / data read are a shallow combinational tail off flops. The data
way-mux register (9R→1R, the `data_0..3` SRAM macro) rides along as the
SRAM-migration step but is *secondary* to cutting the fill cone.

Two shapes for the **tag** side:
- **(a) data-only:** keep tags flop (combinational multi-read), register only the
  data way-mux. **§1 shows this alone will NOT move CP** (the fill cone, not the
  data read, is the depth) — so (a) is insufficient by itself.
- **(b) register the lookup result:** register `cache_hit`/`hit_way`/`miss`/the
  fill-victim selection (Stage R → Stage D). **This is the real cut** — it takes
  the ~3.1 ns fill/stall cone out of the issue-grant path. Combine with the data
  way-mux register for the full SRAM migration.

**→ Lead with (b)** (register the lookup *result*, not just the array read). The
honest open question is the exact Stage-R/Stage-D split of the fill state machine
(the mid-fill abort, the ownership pin, the same-cycle invalidate all read the
live request — §5) — that split is the bulk of the implementation risk and must be
designed against `dcache.veryl` before the scaffold.

---

## 4. Folding into MEM_PIPE (the IPC question)

Loads are **already 2-stage** under MEM_PIPE: Stage-A `lsr_capture` latches
`m_pa_q`/`lsr_paddr_q` (cycle N), Stage-B `lsr_drive` presents it to the dcache
(cycle N+1) where the lookup is *combinational*. **Phase C makes that Stage-B
lookup itself 2-stage** → loads become 3-stage → **load-use latency +1**.

The win is to **fold Stage R into the existing M-stage**: present the index for the
tag/way read in the *same* cycle the PA is latched (Stage-A), so the registered
hit_way/data-read lands in Stage-B with no *extra* cycle. This needs the index
available at Stage-A — it is (`m_pa_q` is the PA; `index = m_pa_q[INDEX_W+5:6]`).
If foldable, the load-use latency is **unchanged** and Phase C is nearly IPC-free;
if not (the fill/miss path needs the hit result a cycle earlier than Stage-A can
give), it costs load-use +1. **This fold is the single most important design
question — resolve it before the flip.** Budget: the campaign's ~10–15 % IPC.

The **commit-store** path (the actual 14.130 endpoint) is a *live* lookup today
(not M-staged — `commit_store_fire→MMU→dcache` in one cycle, §1). Phase C adds a
cycle to the store-commit lookup regardless; stores are not latency-critical
(buffered), so this is cheap, but the **commit gate** (`dcache_stall →
rob_commit_ack`, the n_inflight endpoint) must tolerate the +1 (the store commit
waits one more cycle for its hit/miss verdict).

---

## 5. Corners (the dcache is the SMP heart — every one is coherence-relevant)

1. **Fill state machine** (`state`/`fill_*`, `:386`): already sequential; its
   *inputs* (`miss`, `f_index`, `victim_way`, `vic_dirty`) move to registered
   Stage-R outputs. The mid-fill abort (`inv_fill_hit`, `:417`) and the bounded
   ownership pin (`pin_cnt_q`, `:454`) must see the registered request.
2. **Same-cycle remote invalidate** (`inv_hits_active`, `:364`): today it stalls
   when a remote write races an *active* lookup. With a registered lookup the race
   window shifts by a cycle — the invalidate must be checked against the
   *registered* index/tag too, or the stall re-derived in Stage D.
3. **Store-drain port** (`i_saddr`/`scache_hit`, `:463`): a separate tag-match
   port. Keep it (tags stay flop in shape (a)); under (b) it needs its own read or
   to share the registered read.
4. **Next-dword forward** (`next_*`, M8.B, `:423`): a 2nd combinational read at
   `next_index`. Either keep flop or register a 2nd way-mux.
5. **Slot-1 load port** (`i_addr2`/`o_hit2`, `:92`): hit-only, no fill. Its
   read also goes synchronous (or stays flop in (a)).
6. **AMO/LR in-cache RMW** (`amo_upg`, `hit_excl`, `:407`): the owned-hit read and
   the commit write are **atomicity-critical** — `cp_cut_the_wall_plan.md`/
   MEM_PIPE M3b proved an AMO commit write must stay a *live* single-cycle write
   (a +1cy M-stage AMO commit broke SMP litmus). Phase C must keep the AMO commit
   write live; only the *read* lookup may pipeline. Re-verify litmus N4 + SMP.
7. **Forwarding** (`o_rdata`/`dcache_rdata`): the load result now arrives a cycle
   later in the worst case; the scheduled-wakeup/FR timing (the `prf_done`
   present-guard) must still line up (loads are variable-latency, on the CDB-snoop
   wakeup, not the scheduled one — so this is mostly already handled).

---

## 6. Scaffold strategy (DEAD param → FF-insertion → bundle flip)

`const DCACHE_SYNC_READ: bit = 0` in `dcache.veryl`. Pattern (as ICACHE_SYNC_READ
`cp_frontend_pipeline_plan.md §3`, FETCH_REG, MEM_PIPE):

1. Rename the array-read outputs to `*_raw` (combinational), add registered copies,
   `*_eff = DCACHE_SYNC_READ ? *_q : *_raw`. Consumers read `*_eff`.
2. DEAD (=0): `*_eff == *_raw`, byte-identical. Verify default 252/0 + **ACT4**
   (MEM_PIPE corners) + N1 boot cy exact + synth CP unchanged (regs DCE'd).
3. FF-insertion measure (=1, with FETCH_REG=1 to expose the wall): confirm the
   dcache lookup leaves the `head→n_inflight`/`head→rs1_rdy` path. **If it does
   not, §3 shape (a) was wrong — escalate to (b)/register the fill cone.**
4. Flip in the **bundle** (A-EXE + front-end + vector + AS-c), full ladder.

The flip is **not byte-identical** (load-use +1 unless §4 folds cleanly) — the
first real coordinated-IPC flip of the campaign. Two-axis metric (CP + IPC:
boot-cy / CoreMark / Dhrystone, ~10–15 % budget).

---

## 7. Verification ladder (dcache = SMP-critical, ACT4 mandatory)

default 252/0 + backend-validate + **ACT4 696/696** (the MEM_PIPE-class corners:
S-mode paging loads, the store/load dcache-port collision `f9bea4a`) + litmus
N2/N4 + N2/N4 SMP boot (atomicity: AMO commit must stay live, §5.6) + Verilator
(NBA semantics caught the MEM_PIPE corners the Veryl sim masked).

---

## 8. Sequencing within the bundle

1. **This front first as a DEAD scaffold** (shape (b): register the lookup result
   — hit/miss/fill-victim → shallow `dcache_stall`; data way-mux register rides
   along). §1 already shows (a) data-only is insufficient.
2. A-EXE flip (committed E1/E2 scaffold) — the CDB-snoop 12.320 front.
3. front-end (icache sync-read / imem-MMU stage) + vector vrf.
4. AS-c (grant-gating decouple) folded in last (no standalone lever, §0 of
   `cp_a_sched_scheduler_pipeline_plan.md`).
5. Coordinated flip of all fronts → measure CP + IPC.

## 9. Anchors
- `dcache.veryl`: arrays `:245-283`; hit `:342-371`; rd_dword `:374`; state machine
  `:380-401`; pin `:454`; store-drain `:463-474`; miss/srfo/fill `:481-546`;
  victim/PLRU `:528-558`.
- `heliodor_core.veryl`: dcache inst `:6374`; `i_addr` mux `:6383`; MEM_PIPE M-stage
  regs `m_*_q` `:1637-1647`; LSR 2-stage `:1525-1539`,`:6308`,`:6678`.
- `sram_inventory.md` rows 1–2 (the port analysis); `cp_mmu_dcache_pipeline_plan.md`
  (the PA-latch, done = MEM_PIPE); `deep_pipeline_sram_plan.md` (the bundle).
- Measure: `veryl synth --top heliodor_core --dump-timing --timing-paths N`,
  FETCH_REG=1 to expose the wall (revert after).
