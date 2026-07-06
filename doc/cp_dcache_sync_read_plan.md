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

### 10.2 ✅ IMPLEMENTED + MEASURED (2026-07-02) — `DCACHE_SYNC_READ` DEAD scaffold; flip DOES remove the dcache from `n_inflight`, but standalone only −0.13 ns (the commit-store MMU-fault/PMP-cbo-W residual is co-located)

`const DCACHE_SYNC_READ` (`dcache.veryl:611`, DEAD default 0), pattern = VALU_PIPE (write-fold
`if DCACHE_SYNC_READ` → reset-only regs DCE, `*_eff = ? *_q : *_raw` folds to `*_raw`). Registered
the **fill/stall DECISION cone** (Stage-R result): `miss`, `load_sel`, `srfo_sel`,
`fill_blocked_wb`, `f_index`, `f_tag`, `f_offset`, `f_rfo`, `victim_way`, `vic_valid`, `vic_dirty`,
`vic_tag`. Rename-to-`_raw` + redefine-original-as-`_eff` → every downstream consumer
(`o_memr_req`/`o_memr_addr`/`o_memr_rfo`/`o_memr_ren`/`o_stall`/`o_miss_valid`/`fill_start_fire` +
the FSM fill capture) routes to `_eff` untouched; the upstream victim-computation (fm/plru/vic_*)
stays `_raw`. The victim PAYLOAD `vic_data` stays live (a data write off the critical path; the
real Stage-D re-reads it from registered `f_index`).

**DEAD (=0) — byte-identical + synth-CP-neutral (all four gates GREEN):**
- default **252/0** (litmus N2 cy=0022a330).
- synth CP **14.565 unchanged** (138 lv, `pc_q→rs1_rdy`, 159948 FF) → the `*_q` regs DCE via the
  write-fold (confirms the const-gate methodology).
- N1 boot cy-EXACT: 7.1 cy=01210060, 7.1V cy=013cc5c0, 6.6 cy=013ee8a0, v4-smoke cy=00b6a5d0.
- **ACT4 696/696** (the MEM_PIPE-class S-mode paging corners).

**FLIP CP (FETCH_REG=1 + STORE_PRETRANSLATE=1 + VALU_PIPE=1 + DCACHE_SYNC_READ=1, throwaway,
reverted):** top = `head → n_inflight[5]` **13.710** ns (was 13.840 at DCACHE_SYNC_READ=0). Gate
trace of the 13.710 path — **ZERO dcache gates**:
```
commit_store_fire → agu_addr/dmem_vaddr → u_dmem_mmu.u_mmu.tlb_vpn/level/valid/perm/read_ok  ~3.7 (biggest)
  → m_pa_q → c_store_addr → u_pmp_cbo_m_w.addr_word/mvec/lowest_oh/allow_w/is_m                ~1.9
  → commit_store_fire → rob_commit_valid → commit_excp → commit_trap → rob_commit_ack
  → u_fl.n_inflight (free-list saturating counter)                                             ~1.9 (fixed tail)
```
🔑 **The dcache tag→miss→srfo→victim→fill cone IS cut** (the §6.1 13.84 body is gone — its
`i_addr/tag RAM/f_index/victim/fill_blocked_wb/dc_mem_req` gates no longer appear anywhere in the
top-15). But CP moved only **13.840 → 13.710 (−0.13)** because the commit-store's **LIVE MMU-fault
+ PMP-`cbo_m_w`-W permission cone** — the STORE_PRETRANSLATE "cbo residual" (the fault path left
live in the trap-deferral; the §10 correction banner's "commit-store live MMU+PMP", §3 dense-band
"13.84(cbo)") — is a PARALLEL sub-path to the dcache that fed the same `commit_excp`, sitting right
underneath at 13.71. Cutting the dcache sub-path just exposed it.

**Exposed band (top-15 at the flip), dcache absent throughout:**
| # | ns | endpoint | what |
|---|---|---|---|
| 1–5 | 13.42–13.71 | `n_inflight` | commit-store MMU-fault + PMP-cbo-W residual + free-list counter |
| 6–9 | 13.22–13.23 | `s1_prod_q → s1_sum_q` (146 lv) | a registered-operand multiply tree (int/FP) |
| 10–15 | 13.21 | `redirect_pc_q` | the redirect/mispredict-PC front (the §3 "redirect 13.35", now 13.21) |

🎯 **Result: the dcache sync-read cut is REAL and structurally correct** (the SRAM-migration goal +
a genuine pipeline stage = FINAL structure), but its **standalone CP is ~0** (−0.13) — the
prediction "exposes redirect_pc_q 13.35" was optimistic: `redirect_pc_q` IS exposed (13.21) but the
**commit-store MMU-fault/PMP-cbo-W residual (13.71) caps above it.** This is exactly the
`cp_vrf_cut_plan.md §3` dense-band picture (every front worth ~0.05–0.5 ns, cumulative only in a
coordinated bundle). Per "optimise for structure not CP", the scaffold is **committed DEAD** as a
needed bundle component; a permanent flip waits for the bundle (front-end + commit-store(+cbo) + vrf
+ **dcache** + redirect), and the fold (§10.1, load-use unchanged) + full ladder (§7) apply then.

**▶️ Next front candidate (data-backed):** the **commit-store MMU-fault + PMP-cbo-W residual**
(the 13.71 body now exposed) — the live MMU permission (`tlb_valid/perm/read_ok` ~3.7) + the
`u_pmp_cbo_m_w` PMP cone (~1.9) feeding `commit_excp`. STORE_PRETRANSLATE deferred the *store fault*
but left this cbo/MMU-fault path live (§9.7 of `cp_commit_store_pretranslate_plan.md`). This is the
true `n_inflight` cap once the dcache is registered; the free-list counter tail (~1.9) is the floor
under it.

## 11. ✅ Q2 RESOLVED (2026-07-06) — the coherence Stage-R/Stage-D split design (the SMP-critical crux)

Direction picked by the user (2026-07-06): pivot to the **SRAM migration** (`deep_pipeline_status_and_replan.md`
§6.2 (ii)). The D$ is the plan's #1 SRAM target and its DEAD scaffold + Q1 (the IPC fold) are done; the
one remaining gate before a *functional* flip is **Q2 — the fill/coherence Stage-R/Stage-D split** (§10's
"the bulk of the implementation risk," flagged unresolved). This section resolves it against the full
`dcache.veryl` (1765 lines) + the core-side load Stage-A/B driving.

### 11.0 The governing principle (register the SELECTION, re-read the STATE)

The current scaffold (§10.2) registers a **decision cone** that mixes two categories: the fill *selection*
(which line / which victim way) **and** the victim's *payload/state* (`vic_valid_q`/`vic_dirty_q`/
`vic_tag_q`, and `vic_data` is left live-but-wrong-indexed). Registering the payload is the **latent bug**
in the =1 flip: between the Stage-R decision (cycle N) and the Stage-D fill start (cycle N+1) a concurrent
coherence event can mutate the victim line — a **store-drain merging into the victim** (`store_can_drain`,
`:1199`) flips its dirty bit, a **remote invalidate** clears its valid, a **probe** captures+invalidates
it. A registered `vic_dirty_q=0` then skips the writeback of a line that became dirty in the window →
**silently dropped store** (a litmus MP-class violation, exactly the class MEM_PIPE M3b guarded).

**Principle.** Register **only the SELECTION** — the deep tag-compare→miss→srfo→victim-argmin cone that
was the ~3.1 ns depth (§1):
> `miss_q`, `load_sel_q`, `srfo_sel_q`, `f_index_q`, `f_tag_q`, `f_offset_q`, `f_rfo_q`, `victim_way_q`

**Re-read / re-evaluate at Stage-D from the registered selection** (a *shallow* single-array-indexed-by-a-
flop mux, ≈0.5 ns — does NOT re-introduce the deep cone, so the §10.2 CP cut survives):
> `vic_valid`, `vic_dirty`, `vic_tag`, `vic_data` ← `dirty_X[f_index_q]` / `tags_X[f_index_q]` /
> `data_X[f_index_q]` selected by `victim_way_q`; and the **fill-start GATING**
> (`fill_blocked_wb` ← live `wb_v`/`wb_line`; `i_memr_grant` live; the same-cycle clashes).

**Keep entirely LIVE (never pipelined):** the AMO/SC in-cache commit write (`wenl_fires`, §5.6 —
atomicity-critical), the store-drain merge (`store_can_drain`), the next-dword / slot-1 / 3× presence
reads, the probe & invalidate array mutations, the flush sweep, and the S14 streaming reads. These read
registered arrays and mutate on their own live requests; the demand-lookup pipelining does not touch them.

**Why this keeps CP:** the §10.2 measurement already proved registering `{miss, f_index, f_tag, victim_way,
…}` removes the dcache gates from the `n_inflight` path. The Stage-D re-reads are `array[flop]`→mux (the
same shape as the existing `o_fill_rdata` re-read at `:1608`, which is not on any top-15 front). So the cut
is preserved and the correctness hole is closed.

### 11.1 Corner-by-corner resolution (every dcache behaviour, classified)

| # | behaviour (RTL) | stage | hazard from registered SELECTION | resolution |
|---|---|---|---|---|
| C1 | **victim writeback payload** (`vic_data`/`vic_dirty`/`vic_tag`/`vic_valid`, `:548-595`, capture `:977`) | **Stage-D re-read** | registered payload goes stale if a drain dirties / an inv or probe drops the victim in the R→D window → dropped dirty line | drop `vic_*_q` from the registered set; re-read `{valid,dirty,tag,data}_X[f_index_q]` by `victim_way_q` at the fill start. The writeback then carries **current** bytes. |
| C2 | **fill-start gating** (`fill_blocked_wb`, `:595`,`:666`; `want_fill_start` `:1564`) | **Stage-D re-eval** | `wb_v` can set/clear in the R→D window; a stale `fill_blocked_wb_q=0` starts a fill while the WB buffer holds the fetched line → stale-fill (the `:592` bug) | re-eval `fill_blocked_wb = wb_v && (vic_dirty_reread || wb_line=={f_tag_q,f_index_q})` at Stage-D from live `wb_v` + registered selection. |
| C3 | **demand HIT vs remote invalidate** (`inv_hits_active` `:364`; hit `:342`) | **Stage-D re-validate** | the fold reads tags at Stage-A (cy N−1) but delivers data at Stage-B (cy N); an inv landing at N−1 or N on the hit line makes the registered hit stale → the load reads a value older than a write it is ordered after | carry the Stage-A hit line ({tag,index}) to Stage-B; **squash the registered hit** (→ `o_stall` → replay/refetch) if `i_inv*_valid` matched that line at either the Stage-A tag-read cycle or the Stage-B delivery cycle. Same contract the live `inv_hits_active` enforces today, checked one stage later. |
| C4 | **same-cycle clashes on fill start** (`drain_fill_set_clash` `:715`, `wenl_fires`'s `fill_start_fire && f_index==index` `:886`, `pin_arm_fill` `:890`) | **Stage-D, live-vs-registered** | none — these compare the LIVE drain/AMO request against the fill that *actually starts this cycle* | already correct with `f_index_q`: `fill_start_fire` fires at Stage-D from the registered selection; the live `sindex`/`index` clash against `f_index_q` is exactly "does this cycle's live request collide with the fill mutating arrays this cycle." No change. |
| C5 | **AMO/LR in-cache RMW commit write** (`wenl_fires` `:885`, write `:1077`) | **LIVE (unchanged)** | must stay a single-cycle live write (M3b: a +1cy AMO commit desyncs SMP litmus) | the write path uses the **live** `i_addr` hit (`hit_excl`), never the registered fill decision. The AMO *read* value-capture serves from a live E/M hit; an S-hit/miss folds into `amo_upg`→`miss_q` (registered fill, fine). Keep the entire `wenl_*` block on the live port. |
| C6 | **store-drain merge** (`scache_hit` `:471`, merge `:1199`) | **LIVE (unchanged)** | independent `i_saddr` tag-match; a live single-cycle merge | keep live. Its only interaction with the pipelined fill is C4's `drain_fill_set_clash` (already correct). A drain that cannot merge raises `srfo_sel` (registered fill) — fine. |
| C7 | **mid-fill abort / completion-edge fold** (`inv_fill_hit` `:417`, `p_fill_hit` `:812`, `inv_hits_done` `:1132`) | **LIVE (unchanged)** | operates on the FSM regs (`fill_index`/`fill_tag`, set from `f_index_q`/`f_tag_q` at fill start), not the raw decision | unchanged — the abort machinery already keys off the latched fill line, which now originates from the registered selection. Correct by construction. |
| C8 | **probe / recall, remote invalidate array writes** (`:1321`,`:1443`,`:1461`) | **LIVE (unchanged)** | mutate arrays on their own live ports | unchanged. They race the demand pipeline only via C1/C3, resolved there. |
| C9 | **next-dword / slot-1 / 3× presence / streaming reads** (`:1493`,`:1634`,`:1723`,`:685`) | **LIVE (unchanged)** | pure combinational reads of registered arrays; no dependence on the demand decision | unchanged. Note the slot-1 (`i_addr2`) and presence ports already exclude the mid-fill victim way — that exclusion still holds. |
| C10 | **eviction departure events** (`ev_fill_vic` `:918`→`o_evict1`) | **Stage-D (naturally)** | the victim departs when the fill *starts* (Stage-D); the poison scan must see the eviction the cycle the array is mutated | `ev_fill_vic` keys off `fill_start_fire`+`vic_valid`(re-read)+`vic_tag`(re-read)/`f_tag_q` → fires at Stage-D, the cycle the line actually leaves. Correct — eviction event is tied to the mutation, not the decision. |

**Reading of the table:** exactly **three** corners need a change (C1 re-read the victim payload, C2 re-eval the
WB block, C3 add the R→D hit re-validation); **all seven** coherence/atomicity corners the plan flagged as
SMP-critical (§5, §10-Q2) either stay LIVE untouched (C5-C9) or are already correct because they key off the
*latched fill line* / *actual array mutation* rather than the raw decision (C4, C7, C10). The AMO write —
the one the plan singled out as unpipelineable — never enters the pipelined path.

### 11.2 The fold interface (Q1's load-use-neutral path) — the one real interface change

§10.1 resolved that the fold is IPC-free, but the **current scaffold does not implement it** — it registers
the *Stage-B* decision (`i_addr=lsr_paddr_q` is driven at Stage-B by `lsr_drive`, `core:6772`), so a load's
registered fill lands at Stage-B+1 = **load-use +1**. To get load-use-neutral, the Stage-R tag read must be
presented at the **Stage-A index** so its hit is registered *into* Stage-B:

- Stage-A has `dmu_dmem_addr` live (the MMU-translated PA that feeds `lsr_paddr_q`, `core:1612`), hence
  `index = dmu_dmem_addr[INDEX_W+5:6]` is available a cycle before `lsr_drive`.
- **Interface:** add a Stage-A **tag-read index** input to the dcache (or drive `i_addr` with `dmu_dmem_addr`
  during Stage-A and register the hit inside the dcache). Stage-A reads tags→computes+registers
  `{cache_hit, hit_way, miss_q, victim_way_q, f_*_q}`; Stage-B consumes them for the data read + fill.
- **No comb loop** (§10.1): the Stage-A tag read produces only the registered hit; it must NOT feed
  `dcache_stall` (the fill/miss/stall stays in Stage-B off `miss_q`). `lsr_capture` already excludes
  `iss_dc_ok` (`core:6766`), so the loop stays open.
- The **commit-store** path has no Stage-A to fold into (it is a live `commit_store_fire→MMU→dcache` in one
  cycle, §10.1) → it takes the +1 (register its lookup, the commit gate reads it next cycle). Stores are
  SB-buffered → cheap. **This is where the CP is cut** (the `n_inflight` endpoint), so the +1 is the point.

So the functional flip is **two RTL pieces**: (a) the §11.0-§11.1 selection/re-read correction *inside*
dcache (makes =1 correct but load-use +1), and (b) the Stage-A tag-read port (makes the load load-use-
neutral). (a) is the SMP-critical part; (b) is a timing optimization that can land second.

### 11.3 Scaffold-extension plan (concrete deltas to `dcache.veryl`)

1. **Shrink the registered set** to the selection only: keep `miss_q,load_sel_q,srfo_sel_q,f_index_q,
   f_tag_q,f_offset_q,f_rfo_q,victim_way_q`; **delete** `vic_valid_q,vic_dirty_q,vic_tag_q` (and the
   half-done live `vic_data`).
2. **Stage-D victim re-read** (new lets, gated `if DCACHE_SYNC_READ`): `vic_valid_d/vic_dirty_d/vic_tag_d/
   vic_data_d = {valid,dirty,tags,data}_X[f_index_q]` by `victim_way_q`. Route the FILL-start capture
   (`:978`) and `ev_fill_vic`/`o_evict1_addr` to the `_d` forms.
3. **Stage-D `fill_blocked_wb`** re-eval from live `wb_v`/`wb_line` + `vic_dirty_d`.
4. **R→D hit re-validation** (the fold, C3): register the demand hit line at Stage-R; at Stage-D squash it
   (add to `o_stall`, drop `o_data_valid`/`o_hit_safe`) if `i_inv*` matched it in the window → replay.
5. **Stage-A tag-read port** (11.2(b)) — core interface: a new `i_addr_r`/`i_ren_r` Stage-A index, or reuse
   `i_addr` driven with `dmu_dmem_addr` during Stage-A. Register the hit inside dcache.
6. Keep `DCACHE_SYNC_READ=0` default until the bundle; each delta is byte-identical at 0 (the `_d`/`_q`
   forms fold to `_raw` via the const gate, DCE'd — the §10.2 methodology).

### 11.4 Verification ladder + measurement (unchanged from §7, re-stated for the functional flip)

The =1 flip is **not byte-identical** (commit-store +1; load-use neutral iff 11.2(b) lands). Two-axis:
- **CP:** confirm the dcache cone stays out of `n_inflight` (was −0.13 standalone; real win is in the bundle
  with the commit-store cbo/MMU-fault cut of §10.2's "next front").
- **IPC (the gate):** load-use latency **unchanged** (fold check — the single most important number),
  commit-store +1 (buffered, expect ≈0 boot-cy). Measure boot-cy / CoreMark / Dhrystone, ~10-15 % budget.
- **Correctness (SMP-critical):** default 252/0 + backend-validate + **ACT4 696/696** (S-mode paging +
  the store/load dcache-port collision) + litmus N2/N4 (the C1 dropped-dirty + C5 AMO-write classes) +
  N2/N4 SMP boot + **Verilator** (NBA semantics — the tool that caught the MEM_PIPE M-stage corners the
  Veryl sim masked). C1/C3 are the new-hazard classes; litmus MP + amoadd are the targeted probes.

### 11.5 ✅ IMPLEMENTED + VERIFIED (2026-07-06) — deltas 1-2 (the C1/C2 selection/re-read correction), byte-identical at =0

`dcache.veryl`: the scaffold registered set is **shrunk to the SELECTION only**
(`miss_q,load_sel_q,srfo_sel_q,f_index_q,f_tag_q,f_offset_q,f_rfo_q,victim_way_q`; **dropped**
`fill_blocked_wb_q,vic_valid_q,vic_dirty_q,vic_tag_q`). The victim state (`vic_valid/vic_dirty/vic_tag/
vic_data`) and `fill_blocked_wb` are now **Stage-D re-reads** off the registered selection (`{valid,dirty,
tags,data}_X[f_index]` by `victim_way`; `fill_blocked_wb = wb_v && (vic_dirty || wb_line=={f_tag,f_index})`).
This closes the C1 dropped-dirty-victim + C2 stale-fill holes that a registered stale payload would open at
=1, while staying byte-identical at =0 (the `_eff` `f_index`/`victim_way` fold to `*_raw`).

**DEAD (=0) verification — all green:**
- default **252/0**; **litmus N2 `cy=0022a330`** (cycle-EXACT vs §10.2's reference → SMP byte-identical).
- synth **CP 14.745 ns / 141 levels / `pc_q→rs1_rdy` / 160507 FF — IDENTICAL** to the committed baseline
  (the dropped `_q` regs DCE exactly; +151/1.16M gates = synth noise, CP/FF/levels unchanged → the
  const-gate DCE methodology survives the restructure).
- `veryl check`: no NEW errors (the 101 pre-existing "Not reset" on the data/tags memory arrays are a
  known false-positive, identical count on baseline — `veryl check` is not a project gate; `veryl test` is).

**▶️ Next step:** delta 3 (C3 R→D demand-hit re-validation — carry the Stage-A hit line to Stage-B, squash
on an intervening `i_inv*`) and delta 5 (the §11.2 Stage-A tag-read port = the load-use-neutral fold), then
the FF-insertion flip to confirm the dcache cone is still off `n_inflight`, then the coordinated bundle flip
(front-end + commit-store cbo/MMU-fault + vrf + dcache + redirect) with the full §11.4 ladder + IPC. The
array **port narrowing** (data 9R→1R way-mux macro, tags 13R→1R — the realistic 1RW/1R1W SRAM,
`sram_inventory.md` rows 1-2) rides delta 1-2's registered way-select and is the SRAM-macro half of the
same migration. Deltas 1-2 are DEAD at 0 → safe to ship as the scaffold-correctness fix ahead of the flip;
the full N4-litmus / N2-N4 SMP-boot / Verilator ladder is the gate for the FUNCTIONAL (=1) flip, not this
byte-identical refactor.

### 11.6 ✅ IMPLEMENTED + VERIFIED (2026-07-06) — delta 3 (the C3 R→D demand-hit re-validation), byte-identical at =0

`dcache.veryl`: the **C3 re-validation machinery** is in place. A demand-load HIT that the synchronous
read decides at Stage-R and delivers at Stage-D can go stale if a remote invalidate lands on that line in
the R→D window (the load would then read a value OLDER than a write it is ordered after — the litmus
MP class the LIVE `inv_hits_active` guards one stage earlier). The scaffold registers the hit's line and
an "inv-hit-at-Stage-R" flag, then squashes the registered hit at Stage-D:
> `dhit_v_q` = `i_ren && !i_amo_read && !i_uncached && cache_hit` (a demand-load hit in-flight R→D);
> `dhit_line_q` = `{tag, index}`; `dhit_inv_r_q` = `inv_hits_active || inv2_hits_active` (Stage-R inv).
> `dhit_inv_d` = live `i_inv*` matches `dhit_line_q` (Stage-D inv);
> `dhit_c3_squash` = `DCACHE_SYNC_READ && dhit_v_q && (dhit_inv_r_q || dhit_inv_d)`.

`dhit_c3_squash` is added to `o_stall` (→ replay/refetch) and drops `o_data_valid` / `o_hit_safe`. Same
contract `inv_hits_active` enforces today, checked one stage later. delta 3 registers the hit LINE + squash
only; it does NOT move the DATA read — the Stage-A tag/data read (which registers the hit INTO Stage-D and
makes the =1 semantics complete + load-use-neutral) is delta 5, so at =1 delta 3 alone is still partial (it
flips together with delta 5 for the functional read path).

**DEAD (=0) verification — all green (matches deltas 1-2's byte-id signature):**
- default **252/0**; **litmus N2 `cy=0022a330`** (cycle-EXACT vs §11.5 reference → SMP byte-identical).
- synth **CP 14.745 ns / 141 levels / `pc_q→rs1_rdy` / 160511 FF — IDENTICAL** to the HEAD (`cdaebda`)
  baseline (the `dhit_*_q` regs DCE exactly; +231/1.16M comb gates = synth noise, off the critical path —
  the same category as deltas 1-2's +151). CP/FF/levels/endpoint all unchanged.
- **N1 boot cy-EXACT:** 7.1 `01210060`, 6.6 `013ee8a0`, 7.1V `013cc5c0` (all == baseline).

**▶️ Next step:** delta 5 (the §11.2 Stage-A tag-read port = register the hit INTO Stage-D from a Stage-A
`dmu_dmem_addr` read → makes the demand read synchronous AND load-use-neutral, and completes delta 3's =1
semantics), then the FF-insertion flip, then the coordinated bundle flip with the full §11.4 ladder + IPC.

### 11.7 ✅ IMPLEMENTED + VERIFIED (2026-07-06) — delta 5 (the Stage-A tag-read port / load-use fold), byte-identical at =0

The **Stage-A demand-load tag-read port** is in place (`§11.2(b)`, the load-use-neutral half of the flip).
New dcache inputs `i_addr_r` / `i_ren_r`; the core drives them from the Stage-A latch:
`i_addr_r = dmu_dmem_addr` (the translated PA that feeds `lsr_paddr_q`), `i_ren_r = lsr_capture` (the
plain-load Stage-A enable). Inside the dcache, Stage-A reads tags/valid at `index_r = i_addr_r[…]`, computes
`cache_hit_r` / `hit_way_r`, and **registers the demand hit** into the (delta-3) `dhit_*_q` — re-sourced
from the Stage-A read: `dhit_v_q = i_ren_r && cache_hit_r`, `dhit_way_q = hit_way_r`,
`dhit_line_q = {tag_r, index_r}`, `dhit_off_q = offset_r`, `dhit_inv_r_q = inv_r_at_a`. At Stage-B the demand
hit delivers off flops — data from `dhit_rdata_d = rd_dword(data_{dhit_way_q}[dhit_index_d], dhit_off_q)`
(the 9R→1R way-mux read = the future 1RW SRAM macro), `o_data_valid`/`o_hit_safe`/`o_rdata` all sourced from
`dhit_v_q` under `DCACHE_SYNC_READ`, C3-revalidated. This is a **synchronous read with no extra load-use
cycle** (the tag read is presented at Stage-A, one cycle before Stage-B delivery). Only the demand HIT folds
to Stage-A; the miss/fill selection stays on the Stage-B port (deltas 1-2 — a miss is fill-latency-bound, so
its registered-at-Stage-B fill start pays a negligible +1). Every changed output is
`if DCACHE_SYNC_READ ? <=1 registered path> : <exact original>`, so `=0` is byte-identical.

**DEAD (=0) verification — all green:**
- default **252/0** (incl. the dcache unit tbs — the new ports are omitted there = tied 0 = Stage-A read off,
  DCE); **litmus N2 `cy=0022a330`** (cycle-EXACT → SMP byte-identical).
- synth **CP 14.745 ns / 141 levels / `pc_q→rs1_rdy` / 160511 FF — IDENTICAL** to the HEAD baseline
  (`dhit_way_q`/`dhit_off_q` + the Stage-A tag-read cone DCE exactly; +114/1.16M comb gates = synth noise).
  CP/FF/levels/endpoint all unchanged.
- **N1 boot cy-EXACT:** 7.1 `01210060`, 6.6 `013ee8a0`, 7.1V `013cc5c0` (all == baseline).

**▶️ Next step:** the **FF-insertion flip measurement** — a throwaway BUNDLE synth (front-end scaffolds
`=1` to lower the ~14.745 rs1_rdy front so the back-end `n_inflight` 13.71 floor is exposed) + `DCACHE_SYNC_READ=1`,
to confirm the deltas-1-5 refactor keeps the dcache cone OFF `n_inflight` (was −0.13 standalone in §10.2) and
that the demand read is load-use-neutral. Then the **coordinated bundle flip** (the functional `=1`) with the
full §11.4 ladder (litmus N2/N4 + N2/N4 SMP boot + Verilator + ACT4) + the IPC budget — the big SMP-critical
step, not to be entered without the ladder. The remaining SRAM-macro half (data `9R→1R` way-mux macro, tags
`13R→1R`) rides delta 5's registered `dhit_way_q` way-select.