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

### 11.8 ✅ FF-insertion flip MEASURED (2026-07-06) — deltas 1-5 keep the dcache OFF `n_inflight`

Throwaway BUNDLE synth (front-end `FETCH_REG`/`ICACHE_SYNC_READ`/`IMEM_MMU_STAGE`/`DECODE_REG` + keystone
`EX_PIPE`/`SEL_PIPE`/`SPEC_WAKE` + `STORE_PRETRANSLATE` + `VALU_PIPE` + `DCACHE_SYNC_READ` all `=1`, LOAD_SPEC
`=0`; params reverted after). Result:

- **CP = 13.710 ns / 137 levels / `head → n_inflight[5]`** — EXACTLY the plan's expected bundle floor (§9,
  §12). Unchanged by the deltas-3+5 refactor.
- **The `n_inflight` cone is the live-MMU commit-store / atomic megacone**, NOT the dcache:
  `u_dmem_mmu.u_mmu.tlb_*` (×24, the LIVE V=1 TLB) → `u_pmp_cbo_m_w.*` → `commit_store_fire` /
  `commit_trap` / `rob_commit_ack` → `u_fl.n_inflight`. This is Phase E (the SMP-atomicity wall).
- **No dcache demand-read gate on the cone** (no `data_*`/`tags_*`/`cache_hit`/`o_hit_safe`/`o_data_valid`
  delivery). The one dcache-origin signal present, `dhit_line_q`, enters only via the shallow C3 term
  `dhit_c3_squash → o_stall(dcache_stall) → rob_commit_ack` — the SAME shared commit gate the live
  `inv_hits_active` already sits on, and shallow (flop→compare→AND ≈3 levels), not the 137-level binding
  depth. So it does not lift the CP (13.710 unchanged).
- Top endpoints below n_inflight: `redirect_pc_q` 13.210 (branch-mispredict-redirect arm of the same
  commit→trap cone) — also Phase E. Everything the campaign built (front-end + keystone + vrf + dcache) is
  masked below the 13.71 atomic-commit wall.

**Reading:** the D$ synchronous-read structure (deltas 1-5) is complete and correct at `=0` (byte-identical)
and, at the bundle `=1`, **cleanly off `n_inflight`** — the dcache is no longer any part of the CP floor. The
remaining CP floor is the Phase-E retire/memory-ordering µarch (`deep_pipeline_status_and_replan.md` §4), not
the dcache. **▶️ Next:** the SRAM-macro port narrowing (data `9R→1R` way-mux, tags `13R→1R`, riding delta 5's
`dhit_way_q`) is the byte-id SRAM-realism half; the FUNCTIONAL `=1` flip (load-use-neutral + commit-store +1)
is the coordinated bundle with the full §11.4 SMP ladder + IPC budget — the big SMP-critical step, gated on
the user (do NOT enter without the ladder).
### 11.9 FUNCTIONAL `=1` flip — first attempt (2026-07-07): 2 bugs fixed (byte-id at 0), 1 arch bug remains (WIP)

User chose the D$ functional flip (SRAM-realism / goal b). Enabled `DCACHE_SYNC_READ=1` and ran the arch
suite. **Two real `=1`-path bugs found + fixed (both byte-identical at `=0` — verified 252/0 + litmus N2
`cy=0022a330` + synth 14.745/141lv/160511 FF unchanged):**

1. **The folded delivery must be gated to the FOLDED plain-load Stage-B only (`dhit_ren_q`).** delta 5's
   `=1` outputs (`o_data_valid`/`o_hit_safe`/`o_rdata`) unconditionally sourced the registered `dhit`, but
   `i_ren_r = lsr_capture` fires only for a plain-load Stage-A. Every OTHER accessor sharing the `i_addr`
   port (AMO read, `replay_drive`, commit-store, slot-1, DONE re-read) then read `dhit` (=0) instead of its
   own live data → the op never completed / read garbage (full-suite hang). Fix: `dhit_ren_q` = registered
   `i_ren_r`; deliver `dhit` only when `dhit_ren_q`, else the LIVE path. (rv64ui-ld_st went red→green.)
2. **Fill-safety: a folded hit on a mid-FILL line must fall to the live path (`dhit_use`).** A folded hit
   whose line is being filled at Stage-D would read the mid-write data array. `dhit_use = dhit_ren_q &&
   \!(filling && fill_index == dhit_index_d)` — mid-fill folds to the live path (whose `fill_busy0`
   exclusion + `o_stall(FILL)` already handle it).

**Remaining: `rv64ui-ld` subtest-5 fails (`tohost=5`) — SUBTLE, still WIP.** `lw`/`lwu`/`ld_st` pass;
pure back-to-back `ld` fails on one subtest. Instrumented the folded delivery: **`dhit_rdata_d` ALWAYS
equals the live `o_rdata_live`** when a folded hit delivers — so the bug is **NOT the folded data value**.
The divergence must be in the load COMPLETION / `dc_hit_safe` timing / a pipeline-path difference the `=1`
`o_hit_safe` (registered `dhit_v_q`, not the live `i_ren && \!i_amo && \!i_load_next && fill-safe` form)
introduces — needs cycle-by-cycle core+dcache co-tracing. Noted for the next attempt.

**State:** the `dhit_ren_q` + fill-safety fixes are committed (byte-id at 0, they harden delta 5's `=1`
semantics for the eventual flip). `DCACHE_SYNC_READ=0` remains the default — **the `=1` functional flip is
INCOMPLETE** (the ld bug + the full SMP ladder still ahead). The functional flip is confirmed to be the
large, multi-bug SMP-critical effort the plan warned of; it is not a quick enable.

**Update (2026-07-07, cont.) — 3rd fix + the ld bug is a DEEPER layer.** A 3rd `=1`-path bug fixed
(byte-id at 0): **`i_ren_folded` delivery strobe.** `dhit_use` gated only on `dhit_ren_q` (registered
`i_ren_r`) fired the folded delivery whenever a Stage-A read happened last cycle — but a STALLED `lsr_drive`
(the Stage-B consume) means `i_ren=0` on the intervening cycle, so `o_hit_safe` asserted a cycle early on a
non-consuming cycle (instrumented: `foldhs=1 livehs=0 iren=0`). Fix: a new dcache input `i_ren_folded`
(= `lsr_drive`, the core's Stage-B consume strobe); `dhit_use = dhit_ren_q && i_ren_folded && fill-safe`.
Instrumentation confirms the `o_hit_safe` divergence is then gone at `lsr_drive`. **Byte-id at 0 verified**
(252/0, litmus N2 `cy=0022a330`, synth 14.745/141lv/160511 FF).

**But `rv64ui-ld` subtest-5 STILL fails — the bug is in a layer the dcache-output diagnostics do not reach.**
Traced every load completion (`lsr_complete`/`lsr_read_done`, hit-under-miss `dc_hit_safe`): **the ld test's
`tdat` load values (`0x00ff…`) never appear on ANY dcache/LSR completion path** (only the passing `ld_st`
test's `deadbeef…` loads do). So the failing `ld` loads complete via a path that does not surface
`dcache_rdata` — most likely **store-to-load forwarding** (the harness may relocate `.data` via stores, or
the forward network serves them) or a hit-under-miss/MSHR route. At `=1` the `o_hit_safe`/`o_stall` timing
change plausibly perturbs when a store drains vs a load forwards. **This is a store-forwarding / load-path
interaction, not the folded-delivery datapath** (which is proven value-correct: `dhit_rdata_d ≡ live`).
It needs a dedicated session: trace the store-buffer drain + forward-network (`stld_fwd_*`, `sf`/`sbf`) +
the committed load result (PRF at commit) against a `=0` reference, cycle-by-cycle.

**Net (3 bugs fixed, byte-id; `=1` still incomplete):** the folded-delivery datapath is now correct
(`dhit_ren_q` gate, fill-safety, `i_ren_folded` strobe — all committed byte-id at 0). The remaining
subtest-5 failure is a deeper store-forwarding/load-path interaction, and the full SMP ladder is still ahead.
The functional flip is confirmed to be a **multi-session SMP-critical effort**, not a single sitting.
`DCACHE_SYNC_READ=0` stays default.

### 11.10 ✅ subtest-5 ROOT-CAUSED + FIXED (2026-07-07) — the cold-miss registration gap; but the AMO/misaligned/H clusters remain

The subtest-5 bug was **NOT store-forwarding** (that hypothesis was wrong). A **commit-diff** (trace every
committed `rd` write, `=1` vs `=0`, first divergence) pinned it: the first `tdat` load `ld a4,0(sp)` at
`0x1b4` (PA `0x80002000`) committed **0 at `=1`** vs `00ff…ff` at `=0`. Tracing its lifetime: at `=1` it
completed in ONE cycle (`stall=0 rdone=1`) with pre-fill `rdata=0`.

**Cause (4th `=1` bug):** the miss is registered (`miss = miss_q`, deltas 1-2's Stage-B compute), so it is a
cycle LATE vs the Stage-A-folded hit (`dhit_v_q`). On the load's first Stage-B cycle BOTH `dhit_v_q=0`
(Stage-A miss) AND `miss_q=0` (not yet) → `o_stall` dropped → premature completion with 0. **Fix:**
`dhit_miss = dhit_ren_q && i_ren_folded && \!dhit_v_q && \!i_uncached` OR'd into `o_stall` — stalls that
one-cycle gap; `miss_q` takes over next cycle, the fill runs, the live re-read delivers. **rv64ui-ld + ld_st
PASS at `=1`** (commit `04b8178`, byte-id at 0: 252/0, litmus N2 `cy=0022a330`).

**Remaining `=1` failures (functional flip still WIP — the full-suite `=1` run now completes, no hang):**
- **rv64ua AMO suite (the big cluster)** — amoadd/and/or/xor/min/max/swap {_w,_d}. AMOs are NOT plain loads
  (`i_ren_r = lsr_capture` is 0 for them → `dhit_*` off), so their dcache read is the LIVE path — the break
  is a DIFFERENT `=1` interaction, likely the SAME miss-registration-a-cycle-late class for the AMO's
  RFO/upgrade fill (`amo_upg → miss_q`) vs the single-cycle `amo_watch`/RMW-commit timing. Needs its own
  trace.
- **misaligned** (rv64mi ma_addr/sd_misaligned, rv64ui ma_data) — cross-dword loads (`i_load_next`); the
  folded `o_hit_safe` does not exclude `i_load_next` (the live form does), and `o_rdata_next` stays live —
  a folded misaligned load likely mis-delivers.
- **hypervisor** (hlv/hgpf/htwostage/hmini/…), **sv\*** (svpbmt/svnapot/svadu), **vleff**, **sysb** — TBD.

**4 `=1`-path fixes so far (all byte-id at 0):** `dhit_ren_q` gate, fill-safety, `i_ren_folded` strobe,
`dhit_miss`. The plain-load path is correct; the AMO / misaligned / H clusters are the next work. The
functional flip is a **multi-cluster SMP-critical effort** — each cluster a `=1`-path corner. `=0` default.

### 11.11 AMO cluster investigated (2026-07-07) — the cold RFO-fill line loses ownership before the AMO read (deeper than the load miss-stall)

Commit-diff on `rv64ua-amoadd_w` (`=1` vs `=0`): first divergence at `amoadd.w a4,a1,(a3)` @`0x1a8`
(a3=`0x80002000`), committed `0x0500006f` at `=1` vs the correct old value `0x80000000` at `=0` — and the
AMO **replays** (commits 3× at `=1`). The line was just written by `sw a0,0(a3)` (a0=`0x80000000`) at
`0x1a4` — a COLD store (first access to `0x80002000`).

Traced the AMO capture (`amo_exec_capture`): **first read `present=0` (line NOT owned), `rdata=…0500006f`
(the stale/DRAM value, not the store's `0x80000000`), `sbempty=1`**; the replay reads `present=1` but
`0x04fff86f` (= old`0x0500006f` + a1`0xfffff800` = the AMO's OWN prior write-back). So the store's
`0x80000000` **never reached an owned dcache line before the AMO read** — the cold `sw`'s RFO fill / line
ownership is lost by the AMO's read cycle at `=1`.

**This is deeper than the plain-load miss-stall (`dhit_miss`).** The store's RFO fill + line ownership + the
AMO's `amo_watch`/`present`/eviction all interact with deltas 1-2's REGISTERED fill selection at `=1`: the
registered `srfo_sel`/`victim`/`ev_fill_vic` shift the fill/eviction timing, and the AMO reads before the
store's RFO-owned line is established (or after a mis-timed eviction). It is the SAME "registered fill
selection is a cycle late" root as the load bug, but on the **store-RFO / AMO-ownership** path, which is
SMP-atomicity-critical (the `amo_watch`/poison machinery). A correct fix needs the store-RFO and AMO paths
to see the fill/ownership at the right cycle — analogous to `dhit_miss` but for the non-folded commit-side
accessors, and validated against the litmus/SMP ladder (not just the single-hart arch test).

**Checkpoint (this session):** the plain-load path is complete (5 `=1`-path fixes, byte-id). The AMO
cluster's root is identified (store-RFO/AMO ownership vs registered-fill timing) but its fix is a deeper,
SMP-critical piece; misaligned + hypervisor + sv\* clusters also remain. The functional flip is confirmed a
multi-session, multi-cluster SMP-critical effort. `DCACHE_SYNC_READ=0` default; tree clean.

### 11.12 ✅ AMO cluster FIXED (2026-07-07) — the non-folded read's OWN registered-miss stall gap (not the store's ownership)

§11.11 framed the AMO break as "the cold store's RFO fill / line ownership is lost by the AMO's read
cycle." A cycle-level dcache trace (gated on the `0x80002000` line) showed the root is one level shallower
and is the **AMO read's OWN miss-stall gap** — the exact non-folded analogue of the plain-load `dhit_miss`
bug (§11.10):

```
cy=179 amord=1 ren=1 radr=0x80002000 missR=1 miss=0 fsf=0 ostall=0 chit=0 chk3p=0   ← BUG cycle
cy=180 wen=1  radr=0x80002000 lsel=1 missR=1 miss=1 fsf=1 ostall=1                    ← miss_q catches up
```

At cy179 the AMO read misses LIVE (`miss_raw=1`) but the registered `miss` (`miss_q`, deltas 1-2) is still
0 (a cycle late), so `o_stall` drops. `o_stall → dcache_stall` combinationally (core:6973) and the AMO read
completes on `!dcache_stall` (`iss_dc_ok`, core:2417) — so with the line ABSENT `iq_issue_ack` fires, the
AMO watch arms with `present=0` (`o_chk3_present=0 → dc_amo_present=0 → amo_remote_hit`), the AMO is
poisoned, and its RMW writes back a value computed from raw DRAM (the cold `sw`'s `0x80000000` never
reached an owned line). It then replays on its own poisoned write, committing 3×.

**Fix (`nf_gap_stall`, one `o_stall` term):** the folded plain-load covers this gap via `dhit_miss` off the
registered Stage-A hit `dhit_v_q`; the non-folded accessors (AMO/replay reads that drive `i_addr` LIVE)
have no Stage-A read, so gate on the LIVE miss instead:
> `nf_read_now  = i_ren && !(dhit_ren_q && i_ren_folded)`  (a non-folded read this cycle)
> `nf_gap_stall = DCACHE_SYNC_READ && nf_read_now && miss_raw`  (OR'd into `o_stall`)

`miss_raw = lo_miss | hi_miss | amo_upg` requires `state==IDLE`, so it fires exactly on the genuine
miss/upgrade cycle and drops during FILL/DONE.

**🚨 The livelock lesson (one refutation):** the first attempt stalled the FIRST cycle of every NEW
non-folded read unconditionally (a registered line-compare, no `miss_raw` gate). That passed single-hart
amoadd_w but **livelocked litmus N2** — both harts wedged at the contended amoadd `0x800007a8`. Stalling a
clean **hit-exclusive** AMO (which already owns the line and should complete in one cycle) opens a
one-cycle window for the remote hart to recall the line before the RMW lands → neither hart ever makes
progress. Gating on `miss_raw` is REQUIRED: an AMO with `miss_raw=0` (owns the line) keeps its 1-cycle fast
path, so the MESI line-bounce still terminates. **SMP-atomicity rule: never stall a non-folded read that
already owns its line — only the actual miss/upgrade.**

**Verification:**
- **=1 (functional):** single-hart amoadd_w PASS; **full rv64ua 19/19 PASS**; **litmus N2 `cy=0022f150`
  pass=1** (no livelock); **litmus N4 `cy=00535020` pass=1** (IRIW + 4-way contended atomics). The full
  default suite at =1 is now down to **one** failure — `rv64ui-ma_data` (the misaligned cluster, §11.10) —
  the AMO cluster is gone.
- **=0 (byte-identical):** default **252/0**; **litmus N2 `cy=0022a330`** cycle-EXACT; synth
  `heliodor_core` **14.745 ns / 141 levels / pc_q→rs1_rdy / 160511 FF — IDENTICAL** to baseline
  (`nf_gap_stall` const-folds to 0, `nf_read_now` is then dead → DCE; no new flops; +312/1.16M comb gates =
  off-critical-path synth noise).
- **CP structure (=1 bundle):** the full-scaffold bundle synth (all fronts=1, LOAD_SPEC=0) WITH the fix is
  **13.710 ns / 137 levels / `head→n_inflight` — IDENTICAL** to the §11.8 reference floor. The top-8
  endpoints are all `n_inflight` (13.71) / `redirect_pc_q` (13.21) — **no dcache signal appears**, so
  `miss_raw` in `o_stall` stays MASKED (the dcache is still OFF `n_inflight`). The band-aid is CP-clean. A
  Stage-A tag-read fold for AMOs (extend `i_ren_r` to AMO reads, `i_addr_r` already carries `dmu_dmem_addr`)
  would give the AMO read full SRAM-realism (synchronous, no live `cache_hit`) but is NOT needed for CP —
  a possible later polish, not a blocker.

**Remaining `=1` clusters:** misaligned (`ma_data`/`ma_addr`/`sd_misaligned`, §11.10 root — the folded
`o_hit_safe` does not exclude `i_load_next` + `o_rdata_next` stays live), hypervisor, sv\*, vleff, sysb.
`DCACHE_SYNC_READ=0` default; tree clean after commit.

### 11.13 ✅ misaligned cluster FIXED (2026-07-07) — cross-line load: fold the delivery AND the stall onto the live path

A cross-line misaligned load (`i_load_next` — offset[5:3]==7, so it spans line N dword-7 + line N+1 dword-0)
needs BOTH dwords: `o_rdata` (lo) + the LIVE `o_rdata_next` (hi). Two `=1` bugs, both fixed by putting the
misaligned load fully on the LIVE path (identical to `=0`):

1. **Delivery** — the folded `dhit_use` path delivers only the registered LO dword (`dhit_rdata_d`, a cycle
   old) and asserts `o_hit_safe` off `dhit_v_q`, but the live `o_hit_safe_live` EXCLUDES `i_load_next`
   (a cross-dword span is never a single safe hit). Combining the folded lo with the live hi mis-delivers.
   **Fix:** `dhit_use = ... && !i_load_next` — a misaligned load falls back to live delivery.
2. **Stall** — commit-diff pinned `rv64ui-ma_data` to `lh 63(s0)` @`0x80000594` committing `0x003f` at `=1`
   vs `0x403f` at `=0` (the HIGH byte 0x40, from line N+1, dropped to 0). The cross-line HIGH miss
   (`hi_miss`, a `miss_raw` term) has the SAME registered-miss gap as the AMO: when the LO line HITS
   (`dhit_v_q=1 → dhit_miss=0`) but the HI line misses (`hi_miss=1` live, `miss_q=0` a cycle late),
   `o_stall` drops before line N+1 is filled → `o_rdata_next` reads 0. The AMO's `nf_gap_stall` didn't
   cover it because a misaligned load is FOLDED (`nf_read_now=0`). **Fix:** extend `nf_read_now` to include
   `i_load_next` — `nf_read_now = i_ren && (!(dhit_ren_q && i_ren_folded) || i_load_next)` — so
   `nf_gap_stall = miss_raw` covers BOTH the lo- and hi-miss gaps.

Together: the misaligned load is fully live (delivery + stall) at `=1` = byte-identical timing to `=0`.

**Verification:**
- **=1:** `rv64ui-ma_data` + `rv64mi-ma_addr` + `rv64mi-sd_misaligned` PASS. **The full default arch suite
  is now 252/0 at `=1`** (rv64ui/um/ua/mi/si + rv64uf/ud + `test_litmus_2hart` all non-ignored → the AMO
  cluster, litmus N2, and misaligned all pass at `=1` with no regression). The remaining `=1` clusters
  (hypervisor / sv\* / vleff / paging) live in ACT4 / SMP boot, not the default suite.
- **=0 (byte-identical):** default **252/0**; litmus N2 **`cy=0022a330`** cycle-EXACT; synth `heliodor_core`
  **14.745 ns / 141 levels / pc_q→rs1_rdy / 160511 FF — IDENTICAL** (`dhit_use` is dead at =0 → the extra
  `!i_load_next` DCEs; `nf_gap_stall` const-folds to 0). No new flops.
- **CP structure:** unchanged from §11.12 (13.710 `head→n_inflight`) by construction — `nf_gap_stall`'s only
  deep term is still `miss_raw` (the `|| i_load_next` just widens the shallow enable), and `dhit_use` only
  SHRANK (added `!i_load_next`), so no new deep term reaches `o_stall`.

**Remaining `=1` work (not in the default suite):** hypervisor (hlv/hgpf/htwostage), sv\* (svpbmt/svnapot/
svadu), vleff, and S-mode paging + the store/load dcache-port collision — exercised by ACT4 (696) and the
N1/N2/N4 SMP Linux boot. Those + the Verilator NBA cross-check are the gate for the FUNCTIONAL (=1) flip
default-on; the per-cluster byte-id-at-0 fixes (deltas + AMO + misaligned) are landing ahead of it.
