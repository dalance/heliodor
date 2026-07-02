# Phase C — dcache synchronous-read (the commit-store→dcache wall body)

> ## 🚨 MEASURED CORRECTION (2026-06-30, gate trace of the ACTUAL binding path) — §1's premise below is REFUTED
>
> A clean `--dump-timing --timing-paths 1` trace of path #1 at FETCH_REG=1
> (`head → n_inflight[5]`, **14.130 ns = the global CP**) shows it **does NOT touch
> the dcache at all.** The path is:
> ```
> head → commit reg-read → commit_store_fire                       (2.96)
>   → store AGU/VA → u_dmem_mmu.u_mmu TLB translate (tlb_vpn/level/valid)  (~3.8)  ← biggest
>   → u_pmp_amo_w (PMP-W permission) → pmp_deny → dmem_mmu_acc_fault_s     (~1.9)  ← 2nd
>   → commit eligibility (sb_elig/c_is_store/rob_commit_valid)
>   → rob_commit_ack → commit_trap/redirect                              (~2.25)
>   → do_push2 → u_fl.n_inflight                                          (~2.0)
> ```
> n_inflight **diverges from the dcache after the MMU** — it goes MMU → PMP-W →
> commit-trap → free-list, never reaching the cache. The §1 claim "the n_inflight
> 14.130 path shares the same head→commit_store→MMU→**dcache** front" is **false**:
> that was the masked `rs1_rdy` 12.920 path (the dcache fill cone leaks there via
> grant-gating), **1.2 ns BELOW the binding wall.**
>
> **Front map at FETCH_REG=1 (top-250 endpoints, gate-trace authoritative):**
> | front | ns | paths | what |
> |---|---|---|---|
> | `n_inflight` | 14.130 | 4 | commit-store **live MMU+PMP** translation (NOT dcache) |
> | `vrf` | 13.880 | 246+ | vector VRF writeback (dominant by count) |
> | `rs1_rdy`/dcache | ~12.9 | masked | scheduler loop + **dcache fill cone** = this doc's target |
>
> → The dcache is the **masked 3rd front**, behind commit-store *and* the 246-path
> vrf. Per "optimise for structure not CP" the dcache sync-read remains a valid
> SRAM-migration step, but: (a) its §1 CP-justification for the complex **shape (b)**
> (register the fill cone to cut `dcache_stall`) is gone — `dcache_stall` is on the
> masked 12.9 path, not the 14.13 wall — so **shape (a)** (the genuine SRAM data-read
> migration, 9R→1R way-mux register) is now the cleaner variant; (b) it is **deferred**
> — the user chose the **commit-store pre-translate** front (the actual binding wall,
> `cp_commit_store_pretranslate_plan.md`) as the next structural step. This doc's §2–9
> below still hold for the eventual dcache work; only §1's "dcache is the binding
> front" framing is wrong.

The next structural boundary below the MEM_PIPE PA-latch. ~~**MEASURED 2026-06-30**
(gate trace, after the AS-b refutation): the binding wall — `head→n_inflight`
14.130 ns at FETCH_REG=1, *and* the same front leaking into the scheduler as
`head→rs1_rdy` 12.920 — is the **dcache LOOKUP**, not the MMU and not the select.~~
**(struck — see the correction banner above; n_inflight is the commit-store MMU+PMP,
not the dcache.)**

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

## 10. ✅ ACTIVE FRONT (2026-07-02) — user-selected after VALU_PIPE; design study, scaffold is next

Confirmed as the next major front (user AskUserQuestion) after the "quick" WALL scaffold-flip
fronts were exhausted: with FETCH_REG + STORE_PRETRANSLATE + VALU_PIPE all flipped, the top is
`head → n_inflight` **13.840**, gate-traced (`cp_vrf_cut_plan.md §6.1`) to the **dcache combinational
tag lookup ~5 ns** on the commit-store/cbo path — exactly this doc's target. This is the SRAM
migration + a real pipeline stage (FINAL structure), a different effort class from the scaffold flips.

**Structure studied (`dcache.veryl`, 1695 lines, SMP heart):**
- `o_stall` (`:1692`) = `(state==FILL) || miss || (state==DONE) || write_during_fill ||
  write_wait_grant || write_wait_local || inv_hits_active || inv2_hits_active ||
  (uncached_active && !i_memr_grant)`. `state` is a REGISTER (shallow); the depth is **`miss`**
  (= `!cache_hit`, the tag compare `:342-346`) feeding the fill-request→grant→stall chain.
- The ~3.1 ns dominant cone (§1) is `miss → dc_mem_req → i_dmem_grant` (a **combinational round-trip
  through the memory-bus arbiter**) `→ fill_start_fire (:597) → state`, plus `victim_way/vic_dirty/
  fill_blocked_wb (:595)`. So the cut is NOT the array read (~0.9) — it is the **miss→fill-arb→stall
  chain**, confirming §1/§3's "shape (b)".

**Confirmed design (shape (b)):** Stage R (cycle N) reads `tags/valid` at `index`, computes and
REGISTERS `{cache_hit, hit_way, miss, victim_way, vic_dirty, srfo_sel, f_index}` + the hit-way
`data[index]` read (the 9R→1R way-mux, SRAM migration). Stage D (cycle N+1) runs
`fill_start_fire`/`dc_mem_req`/`o_stall`/`rd_dword`/forward from those REGISTERS → the fill-arb/stall
chain is a shallow tail off flops (the tag-compare→miss→fill combinational depth is broken across the
register).

**🔑 The two hard design questions to resolve BEFORE the scaffold (the bulk of the risk):**
1. **MEM_PIPE fold (§4, the IPC crux).** Loads are already 2-stage (Stage-A latches `m_pa_q`/
   `lsr_paddr_q`; Stage-B presents `i_addr=lsr_paddr_q`, `heliodor_core.veryl:6789`, combinational
   lookup). If Stage R folds into Stage-A (present `index=m_pa_q[INDEX_W+5:6]` for the tag read the
   same cycle the PA is latched, register hit_way into Stage-B), load-use latency is UNCHANGED
   (IPC-free). If not, loads become 3-stage (load-use +1). **Resolve first** — read the exact
   Stage-A/Stage-B timing of `m_pa_q`/`lsr_capture`/`lsr_drive`.
2. **The fill/coherence Stage-R/Stage-D split (SMP-critical, §5).** The mid-fill abort
   (`inv_fill_hit :417`), same-cycle remote invalidate (`inv_hits_active :364`), ownership pin
   (`pin_cnt_q :454`), store-drain port (`scache_hit :463`), next-dword forward (`next_* :423`),
   slot-1 hit port (`i_addr2/o_hit2`), and — atomicity-critical — the **AMO/LR in-cache RMW commit
   write MUST stay a LIVE single-cycle write** (MEM_PIPE M3b: a +1cy M-stage AMO commit broke SMP
   litmus; only the READ lookup may pipeline). Each must see the REGISTERED request or re-derive its
   stall in Stage D.

### 10.1 ✅ Q1 (the MEM_PIPE fold) RESOLVED (2026-07-02) — the fold IS feasible & IPC-free; the load stays 2-stage, only the commit-store pays +1

Read the load M-stage timing (`heliodor_core.veryl`):
- **Stage-A** (`lsr_capture`, cycle N, `:1583`): latches `lsr_paddr_q = dmu_dmem_addr` (the MMU-
  translated PA). **The dcache read is SUPPRESSED here** — deliberately, to avoid the comb loop
  `i_ren → dcache miss → dcache_stall → iss_dc_ok (:2358) → issue gate → i_ren`. Critically,
  `lsr_capture` EXCLUDES `iss_dc_ok`/`dcache_stall` (`:1580`), so the capture does NOT depend on the
  stall.
- **Stage-B** (`lsr_drive`, cycle N+1): `i_addr = lsr_paddr_q` (`:6789`) → the dcache lookup is
  **combinational** (tag→hit→miss→fill→stall, the ~5 ns of §1) → forward → CDB.

🔑 **The fold works.** `dmu_dmem_addr` (hence `index = dmu_dmem_addr[INDEX_W+5:6]`) is ALREADY
available in Stage-A (it is what feeds `lsr_paddr_q`). So Stage-R (tag read + `hit_way`/`cache_hit`
compute) can run in Stage-A and register its result into Stage-B; Stage-B then does the hit-way data
read + forward + (on a registered miss) the fill — all from the REGISTERED hit. **Load-use latency is
UNCHANGED (still 2 stages)** — Stage-R is folded into the existing Stage-A, not added as a 3rd stage.
- **No comb loop:** the Stage-A tag read computes ONLY `hit`/`hit_way` (registered); it must NOT feed
  `dcache_stall` (the fill/miss/stall stays in Stage-B/D off the registered miss). Since `lsr_capture`
  already excludes `iss_dc_ok`, and the Stage-A hit doesn't generate a stall, the loop stays open.
- **Stage-A budget:** Stage-A gains ≈ MMU (~1.1) + tag read+compare (~1.4) = ~2.5 ns of hit-compute —
  well under the post-WALL target cycle (~9–13 ns), so the fold does NOT make Stage-A critical.
- **Commit-store** (the actual 13.84 endpoint): a LIVE lookup today (`commit_store_fire → MMU →
  dcache` in one cycle, not M-staged). It pays the +1 cycle (register its lookup result → the commit
  gate `rob_commit_ack` reads it next cycle). Stores are buffered (SB) → not latency-critical →
  **cheap IPC.** This is where the CP is cut.

**→ Phase C can be nearly IPC-free** (loads folded into Stage-A; only the buffered commit-store pays
+1). The fallback (no fold — make the Stage-B load lookup 2-stage → load-use +1) is simpler but costs
IPC; prefer the fold.

**Scaffold structure (recommended):** register the lookup RESULT {`cache_hit`, `hit_way`, `miss`,
`victim_way`, `vic_dirty`, `srfo_sel`, `f_index`} + the hit-way data read. For the load path, the
Stage-R read is presented at the Stage-A index (`dmu_dmem_addr`) — this needs a Stage-A tag-read port
into the dcache (or the core presents the index and the dcache registers the hit). For the
commit-store, Stage-R is the commit-store's live lookup, registered before the commit gate. Q2 (the
fill/coherence Stage-R/D split, §10 above) remains the SMP-critical implementation risk.

**▶️ Next-session first step:** build the `const DCACHE_SYNC_READ` DEAD scaffold (§6 pattern:
`*_raw`/`*_q`/`*_eff` on the lookup result), verify byte-identical (default 252/0 + **ACT4** + N1
boot cy exact + synth CP unchanged/DCE), then FF-insertion measure the flip
(FETCH_REG+STORE_PRETRANSLATE+VALU_PIPE+DCACHE_SYNC_READ) to confirm the dcache leaves the
`n_inflight` 13.84 path → exposes `redirect_pc_q` 13.35. Full ladder (§7: ACT4 696 + litmus N4 +
N2/N4 SMP + Verilator) + IPC (fold check: load-use latency unchanged) at the bundle flip.
Multi-session build.