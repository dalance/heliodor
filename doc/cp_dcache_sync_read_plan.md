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

### 11.14 ✅ FLIPPED DEFAULT-ON (2026-07-07) — `DCACHE_SYNC_READ=1` is the default; the D$ demand read is synchronous (realistic SRAM), CP-neutral

With the AMO (§11.12) + misaligned (§11.13) clusters fixed, the `=1` flip passes the FULL ladder and is
**CP-neutral**, so `DCACHE_SYNC_READ` now defaults to **1**. This is the first NON-byte-identical delta of
the campaign (the commit-store demand lookup takes its designed +1) and is the SRAM-realism milestone
(goal b): the D$ demand tag/data read is now a **synchronous, registered-address read** (plain-load Stage-A
fold + registered fill selection) = a realistic 1RW/1R1W SRAM macro, not a giant async mux.

**CP: zero cost.** synth `heliodor_core` at =1 = **14.745 ns / 141 levels / pc_q→rs1_rdy — IDENTICAL** to =0.
Global CP stays front-end-bound; the sync-read is masked below it (structure-not-CP). FF **160644 vs 160511
(+133)** = the registered fill selection + the live dhit_*_q hit registers (the realistic-SRAM structure).
The CP *win* is realised only in the deep-pipe bundle (front-end cut → n_inflight/13.71 binds, §11.8); here
the flip is a pure structural step.

**IPC: negligible.** N1 boot 7.1 `cy=01217590` vs =0 `01210060` (+0.16%); 6.6 +0.38%; N2 SMP `00fd24b0`.
All boot/litmus deltas ≤ +0.4% (far under the ~10-15% budget).

**Full ladder at =1 — all green:**
- ✅ default arch suite **252/0** (rv64ui/um/ua/mi/si + rv64uf/ud + litmus N2, all non-ignored).
- ✅ litmus **N2 `cy=0022f150`** + **N4 `cy=00535020`** (contended atomics + IRIW — the SMP-atomicity gate).
- ✅ N1 Linux boot smoke/7.1/7.1V/6.6 (4/4); ✅ N2 SMP boot `cy=00fd24b0`.
- ✅ **ACT4 full 696/696** (hypervisor/sv\*/vleff/misalign + all extensions — the complete RVA23 compliance
  gate, 0 failures, 212 s single invocation).
- ✅ **Verilator N1 Linux boot** `pass=1 r3=0xAA cy=12036187` (clean SBI shutdown, NBA semantics — the
  HW-accurate cross-check that caught prior sim-masked MEM_PIPE corners).
- ✅ N4 SMP boot: reached ~17 M/17.5 M cy (97%) healthy — 4 CPUs up, deep userspace, no wedge (the 4-hart
  sim is ~2.7× the N2 wall-time ≈ 45-50 min/run; the 97% + litmus N4 + ACT4 + N2 boot are the SMP evidence).

**🔑 Process note — the earlier "box too loaded" was a MISDIAGNOSIS.** The real cause of the minutes-long
"Building simulation model" stalls was `.build` CONTENTION from running MULTIPLE `veryl` invocations
concurrently (a background N4 boot while launching ACT4). Serially, the full ACT4 (696) builds + runs in
**212 s** on the same box. **Rule: run ONE `veryl` invocation at a time**; a single long test goes in the
BACKGROUND (the Bash tool caps foreground at 10 min); do not launch another `veryl` while it runs.

**Done:** `const DCACHE_SYNC_READ: bit = 1`; final default regression 252/0 at the new default. No test
asserts an exact cycle count (all pass/x3-based) so nothing breaks; the approximate cycle refs in CLAUDE.md
are within their bands. **Next (SRAM macro):** with the read synchronous, the array port narrowing (data
9R→1R way-mux, tags 13R→1R — the 1RW/1R1W macro, `sram_inventory.md` rows 1-2) rides the registered
way-select. The icache sync-read (fetch-loop decoupling) is the remaining front-end SRAM step.

---

## 12. SRAM macro — array port narrowing (2026-07-07, post-flip)

### 12.1 ⚠️ Measurement first: the sync-read flip ADDED ports (9R4W→10R4W, 13R1W→15R1W)
`--dump-area` on `heliodor_core` at the new `DCACHE_SYNC_READ=1` default (re-measured, the
`sram_inventory.md` numbers were the pre-flip `c09f99c`):

```
64×512  10R4W  ×4   ← dcache data  (was 9R4W)
64×52   15R1W  ×4   ← dcache tags  (was 13R1W)
```

The sync-read staging did **not** narrow the arrays — it *added* a demand read port each
(`dhit_index_d` on data, `index_r`/Stage-A on tags) **on top of** the live combinational reads,
which the non-folded fallback (`o_rdata_live`, AMO / `i_load_next`) and the store-RMW still need.
So the earlier "port narrowing rides the registered way-select → 1RW/1R1W" framing was optimistic:
the synth infers a read port **per distinct index net** (not per read *site* — the 6 `data_0[index]`
reads are one port), and the demand read is only one of ten distinct index nets. **The real 1RW/1R1W
narrowing is the read-port arbitration / time-multiplex restructure — the "hardest" inventory item,
SMP-critical, a functional flip** (adds stalls, not byte-identical). The sync-read was the
*precondition* (a synchronous demand read), not the narrowing itself.

### 12.2 ✅ The byte-identical step available: fold the write-back-capture reads (data 10R→8R)
The five write-back-buffer captures — fill-victim (`vic_data`@`f_index`), probe recall
(`p_data`@`p_index`), misaligned-store lo/hi detour (`hitway_data`@`index` / `nexthit_data`@`next_index`),
flush sweep (`fl_data`@`fl_set`) — are **mutually exclusive by the `cap_*_go` priority chain**
(`cap_fill_go` > `cap_probe_go` > `cap_mis_go` > `cap_flush_go`, each `&& !`-excluding the higher ones;
"one capture per cycle" per the `dcache.veryl` arbitration comment). Each per-source line read feeds
**only** its `wb_data[l] = X[l]` capture. So they SHARE one line-read port: a single `cap_index` /
`cap_way` priority mux (mirroring the same capture priority) drives one `cap_data = data_{cap_way}[cap_index]`
read, and all five captures read `cap_data`. Byte-identical because at most one capture fires and the mux
picks its index/way.

This removes the data-array reads at `f_index` / `p_index` / `fl_set` (those indices are read *only* by
the capture on the data array; `index` / `next_index` survive for demand / next-dword-forward):
**`data_0..3` 10R4W → 8R4W.** The write-merge-buffer consolidation named in `sram_inventory.md` row 1 as
part of the 1RW target.

**Verification (byte-identical):**
- ✅ default arch suite **252/0** (incl. litmus N2).
- ✅ synth `heliodor_core` **14.745 ns / 141 levels / pc_q→rs1_rdy — IDENTICAL** to pre-narrowing;
  **FF 160644 unchanged** (`cap_data` is comb, no new flops); comb area −8362 um² (the five per-source
  muxes collapsed to one); `--dump-area` confirms **`64×512 8R4W ×4`**.
- ✅ N1 Linux boot 4/4, **7.1 `cy=01217590` cycle-EXACT** to the `=1` baseline (real flush / eviction /
  PTW paths through the capture logic); smoke `00b7b740`, 7.1V `013d8910`, 6.6 `01402120`, all `x3=0xAA`.
- ⏳ litmus N4 / ACT4 696 / N2 SMP boot / Verilator — running (SMP-critical discipline for the
  probe/flush coherence paths, even though the change is byte-identical by construction).

### 12.3 Why tags stay 15R1W, and where 8R→1RW goes next
The tag reads at `f_index` (`vic_tag`) and `p_index` (`phit`) have **non-capture consumers** —
`vic_tag` feeds `ev_fill_vic` (`vic_tag != f_tag`) every cycle, `phit` feeds `probe_depart` /
`o_probe_ack` / the `valid_N[p_index]` invalidation — so they can't fold into a capture-only port
byte-identically. The tags narrowing belongs to the functional restructure.

**The remaining 8R → 1RW/1R1W (the true SRAM macro) needs the read-port arbitration flip:** demand
(`index`/`dhit_index_d`) + store-drain (`sindex`) + fill-RMW (`fill_index`) + slot-1 (`index2`) +
next-forward (`next_index`/`next_index2`) are genuinely concurrent at different indices, so a single-port
macro must time-multiplex them with stall arbitration — a functional change (IPC cost, full SMP ladder,
coherence-relevant on the probe/store-drain ports). That is the same class of SMP-critical work as the
sync-read flip; the capture-fold (§12.2) is the clean byte-identical down-payment.

---

## 13. The read-port arbitration (7R → 1R) — the true 1R1W SRAM (functional flip, THE hardest item)

User-selected (2026-07-11 "次へ", after the write-collapse `b5a9976`) as the next campaign step: complete the
D$ data array as a **true 1R1W SRAM**. The write side is done (`8R4W → 7R1W`, byte-write-enable, cycle-
identical); this section designs the read side (`7R → 1R`).

### 13.1 The 7 read-index nets (post-write-collapse, `--dump-area` = `64×512 7R1W ×4`)

| # | index net | RTL site | produces | consumer (`o_*`) | timing | fires | port-yield cost |
|---|---|---|---|---|---|---|---|
| R1 | `index` = `i_addr[IW+5:6]` | `:402` `rdata_0..3` | live demand rdata + `stream_rdata0` | `o_rdata` (non-folded), `o_hit_safe` | **comb, same-cy** | every IDLE hit that is **non-folded** (AMO / misaligned / uncached) or streaming | — (demand, must serve) |
| R2 | `dhit_index_d` = `dhit_line_q[IW-1:0]` (flop) | `:810` `dhit_rdata_d` | registered demand rdata | `o_rdata` (folded plain load) | **registered** (SRAM-shaped: address = `index_r` presented at Stage-A, read at Stage-D) | folded plain load, `DCACHE_SYNC_READ=1` | — (demand, the SRAM's natural registered read) |
| R3 | `cap_index` (5-src priority mux `:1047`) | `:1070` `cap_data[0..7]` | full-line capture | writeback / probe-recall / flush / misaligned detour | comb but **rare** (priority chain, mutually exclusive) | fill-victim / probe / misaligned / flush | rare → stall cheap |
| R4 | `next_index` = `index+8` | `:1724` `next_rdata_{same,xline}` | next-dword | `o_rdata_next` | **comb, same-cy** | misaligned **cross-line** load (`i_load_next`) | rare → 2-cy serialize |
| R5 | `fill_index` (state reg) | `:1844` `o_fill_rdata` | filled dword at miss offset | `o_fill_rdata` (DONE) | registered (state-synced) | `State::DONE` completion cy | that load is already waiting → ~free |
| R6 | `index2` = `i_addr2[IW+5:6]` | `:1875` `rdata2_0..3` | slot-1 demand | `o_rdata2`, `o_hit2` | **comb, same-cy** | slot-1 dual-issue load hit | **best-effort** — deny → `o_hit2=0` → pipe-0 fallback (no stall) |
| R7 | `next_index2` = `index2+8` | `:1893` `next_rdata2_*` | slot-1 next-dword | `o_rdata2_next` | comb, same-cy | slot-1 misaligned | best-effort (with R6) |

(The byte-write-enable RMW retention read `data_k[d1_idx]` at `:1463` folds into the **write** port's
byte-enable — not a read port. R1 and R2 are the SAME logical demand read at two stages: R2 is the SRAM-
shaped registered form, R1 is the combinational live form the real SRAM cannot provide.)

### 13.2 Target and the governing principle

**Target: 1R1W** (matches L2 data). One **write** port (already collapsed, byte-write-enable, independent)
+ one **read** port. Only the 7 *reads* contend; R/W do not (separate ports, a real 1R1W allows co-fire —
mind the read-during-write-same-index hazard: model **read-old**, matching today's `always_ff` write-next-
edge / read-sees-old semantics).

**Principle — the demand read owns the port; everything else is time-multiplexed with a stall.** A real
SRAM read is *synchronous*: present ONE index at cycle N, data registered out at N+1. The demand read (R2)
is already this shape (address `index_r` @Stage-A → data @Stage-D). The flip makes the port present **one
arbitrated index per cycle** and forces the other six reads onto it:
- **R1 (live demand)** — eliminated. Its consumers (non-folded AMO/misaligned/uncached loads, streaming)
  switch to the registered read; those accesses become 2-stage (present index, +1, read registered). They
  are already multi-cycle-ish, so +1 is cheap. This is the deepest change (touches the AMO/misaligned/
  uncached delivery that §11.11-11.13 fought).
- **R3/R4/R5 (cap / next / fill-DONE)** — rare; when they need the port, **stall the demand pipe** one
  cycle (present their index, demand waits). Often the demand pipe is *already* stalled in the state these
  fire (FILL/DONE/capture/flush), so the added stall is frequently hidden.
- **R6/R7 (slot-1)** — **best-effort**: grant only when the demand read is idle that cycle; else `o_hit2=0`
  → the slot-1 load re-issues on pipe-0 (`ld2_complete` `core:7389`). No stall — pure loss of a dual-issue
  load. Since slot-1 loads dual-issue *with* a slot-0 demand (same cycle), they almost always lose the
  arbitration → dual-issue loads effectively disappear unless we **bank** (see 13.5). This is the largest
  single IPC lever and the place to spend the optimization budget.

**Arbitration priority (single read port):** `demand (index_r) > cap > next > fill-DONE > slot-1`.

### 13.3 Per-read handling (the flip deltas)

1. **Demand R1→R2 unify.** Route `o_rdata` / `o_hit_safe` / streaming entirely off the registered read.
   Non-folded loads (AMO `i_amo_read`, cross-line `i_load_next`, `i_uncached`) currently use the LIVE
   `o_rdata_live` (R1). Under the flip they must present their index to the port and read it registered
   → they gain a Stage. Fold them the way §11.2(b) folded the plain load (a Stage-A `i_addr_r` read),
   OR give them an explicit +1 stall (`nf_gap_stall` already stalls them a cycle on a registered-miss —
   extend that to a registered-read cycle). **This is the SMP-critical delta** (AMO read-capture atomicity,
   §11.11): the AMO value-capture must still see the owned line at the RMW window — verify the registered
   read does not open a recall gap (litmus N2 amoadd is the probe).
2. **next_index (R4) 2-cy serialize.** A cross-line misaligned load presents `index` at N (lo dword) and
   `next_index` at N+1 (hi dword), stalling one cycle; assemble `o_rdata` + `o_rdata_next` across the two
   registered reads. Same-line spans (`next_same_line`, `offset!=7`) already have `next_index==index` in
   value → serve both dwords from the one registered line read (no extra cycle — the full 512-bit line is
   registered, both dwords extract from it). **Only the cross-line case pays +1.**
3. **cap_index (R3) stall-arbitrate.** The capture reads the victim/probe/flush line. Present `cap_index`
   on the port that cycle (demand yields). The capture already coincides with fill-start / probe / flush —
   states where the demand load is held — so this is mostly hidden. Keep the capture's *consumers*
   (writeback buffer, `ev_fill_vic`) reading the registered line.
4. **fill-DONE (R5) ~free.** `o_fill_rdata` at DONE: the missing load is waiting on this cycle; present
   `fill_index` on the port at DONE, deliver registered. No net stall (the load was blocked anyway).
   **⚠️ SUPERSEDED by §13.8:** this is WRONG — `o_fill_rdata` is also sampled *early* and *combinationally*
   (`o_fill_data_ready`, critical-word-first, ~7cy before DONE), so a registered read is 1cy stale and the
   boot hangs; and non-blocking hit-under-miss collides with the fill re-read on the shared port. R5 is
   folded via a dedicated critical-word flop instead (§13.8, DONE, cycle-identical).
5. **slot-1 (R6/R7) best-effort or bank.** Default: `o_hit2` additionally requires winning the port
   (`rd1_gnt_slot1`); else `o_hit2=0`. Optimization (13.5): **bank by `index[0]`** so a slot-1 read to the
   *other* bank co-fires with the demand read — recovers dual-issue at the cost of 2 banks (each a 32-entry
   1R1W). Banking is the `sram_inventory.md` row-1 "banked 1RW" target; decide after measuring the
   best-effort IPC hit.

### 13.4 Increment sequence (DEAD scaffold → staged flip)

Unlike the write-collapse, the read flip is **not** byte-identical (it adds stalls / a stage). Stage it by
IPC-cost tier so each step is small and independently verifiable:

- **S0 — DEAD scaffold (byte-identical, this session).** `const DCACHE_DATA_READ_1R: bit = 0;` + the single
  read-port skeleton: `rd1_index` (priority mux of the 7 requesters), `rd1_way`, registered `rd1_data_q =
  data_X[rd1_index]` (all gated `else if DCACHE_DATA_READ_1R` → reset-only at 0 → **DCE**, byte-identical),
  and `rd1_stall` (=0 at 0). Verify: default 252/0, synth `7R1W` unchanged, FF unchanged (the §10.2 DCE
  methodology). Establishes the const + arbiter net; no consumer re-routing yet.
- **S1 — fold the rare reads (R3 cap, R5 fill-DONE).** Route their consumers off `rd1_data_q`; stall demand
  when they win. Nearly free (they fire in already-stalled states). Full ladder.
- **S2 — next_index (R4) 2-cy serialize.** Cross-line misaligned only. Full ladder + ma_data arch tests.
- **S3 — demand R1→R2 unify (eliminate the live read).** The AMO/misaligned/uncached delivery onto the
  registered port. SMP-critical (AMO atomicity). Full ladder + ACT4 696 + litmus N2/N4 + Verilator.
- **S4 — slot-1 (R6/R7).** Best-effort first (measure the dual-issue-load IPC loss), then bank if the loss
  exceeds budget. Full ladder.
- **S5 — flip default-on** (`DCACHE_DATA_READ_1R=1`), `--dump-area` = `64×512 1R1W ×4`, retire the scaffold
  const if clean.

### 13.5 Verification ladder (dcache = SMP heart; every read touches coherence)

Same discipline as §11.4 / the sync-read flip — the read port is on the LR/SC-reservation, AMO-watch, and
probe/store-drain-visible paths:
- **Correctness:** default 252/0 + backend-validate + **ACT4 696/696** (S-mode paging + store/load port
  collision) + litmus N2/N4 (AMO atomicity + MP dropped-value classes) + N2/N4 SMP boot + **Verilator**
  (NBA ground truth — caught the MEM_PIPE and L2-byte-write-enable corners the Veryl sim masked).
- **IPC (the gate):** load-use latency **unchanged** for the common (folded plain load, already registered)
  — the single most important number; the +1 falls only on AMO/misaligned/cross-line/cap and (if not
  banked) dual-issue loads. Measure boot-cy / CoreMark / Dhrystone, ~10-15% budget. If slot-1 best-effort
  blows the budget, bank by `index[0]` (13.3.5).

### 13.6 Risks / open questions

- **AMO atomicity (S3)** is the highest risk: the registered read must not desync the RMW ownership window
  (§11.11 fought exactly this on the *stall* side). Probe = litmus N2 amoadd wedge.
- **read-during-write same-index** hazard (R/W co-fire on one line): confirm the veryl-inferred 1R1W macro
  models read-old (today's semantics). If it models read-new, the store-merge-then-load-same-line ordering
  breaks — add an explicit bypass or a 1-cy stall.
- **Banking (S4)** interacts with the write port (byte-write-enable) — a banked read + a full-line write
  (fill) to the same bank still collide; the fill already stalls the demand, so likely fine, but re-measure.

### 13.7 ✅ De-risked (2026-07-11) — the demand read fold is CYCLE-IDENTICAL; port reduction needs statement-block gating

Two findings from temp-flipping `DCACHE_DATA_READ_1R=1` on the S0 scaffold (`edda6e9`; reverted, tree
stays =0):

**(1) The demand hot-path read via the registered SRAM port is cycle-identical — the #1 risk (§13.6) is
resolved.** With the folded plain load's `o_rdata` delivered from `rd1_data_*` (the arbitrated port's
registered four-way line, index presented at Stage-A) instead of the fake-flop comb read
`data_X[dhit_index_d]`, the full ladder is **cycle-EXACT**: default **252/0**, litmus N2 `cy=0022f150`
(exact), N1 Linux boot **7.1 `01217590` / 7.1V `013d8910` / 6.6 `01402120` — all cycle-EXACT** to the =0
baseline. So the **read-during-write same-index hazard is fully masked by the core's byte-granular
store-to-load forwarding** for the demand load: `rd1_data` (registered at the presentation edge) is one
write-generation staler than the comb read, but any store that wrote the load's dword in that window is
supplied byte-exact by the SB forward layer, and a store to *other* bytes/dwords of the line leaves the
load's dword unchanged (stale == current). The boot cy-exactness (not just litmus — the L2 byte-write-
enable lesson was that litmus's full-word stores miss partial-byte retention bugs that boot's partial
stores expose) is strong evidence the demand fold is correct, not merely test-lucky. **The hardest part
of the read side — the demand hot path onto a synchronous SRAM read — is free.**

**(2) Port reduction requires const-guarded STATEMENT blocks, not ternary gating (the L2 P3.b lesson,
`8e01034`).** Routing a read's *consumer* to `rd1_data` does NOT drop its array read port: veryl's RAM
inference (`conv/ram.rs`) counts a read port **per distinct array-index net, before global DCE**, so the
old `let x = ...data_X[old_index]...` still infers a port even when `x` is downstream-dead. Measured at =1
(demand routed via `rd1`, old reads left as ternary `let`s): synth = **`8R1W ×4`** (rd1 *added*, nothing
dropped); wrapping `dhit_rdata_d` in a ternary `if DCACHE_DATA_READ_1R ? 0 : data_X[...]` still measured
`8R1W`. To make an old read DCE at =1 it must become a **const-guarded statement block** — a `var` +
`always_comb`/statement `if !DCACHE_DATA_READ_1R { x = data_X[idx] }` — exactly the ternary→statement-block
conversion that fixed L2 P3.b Problem 2 (`3R1W → 1R1W`). So each fold is two parts: (a) route the consumer
to `rd1_data` (cycle-identical for the demand, per (1)), and (b) convert the old fake-flop read to a
statement block so the port DCEs at =1.

**Refined S1 (next):** convert the demand read (`dhit_rdata_d`) to the statement-block form so at =1 it
DCEs and the arbiter port (`rd1_index`) is the single consolidated demand read (7R at =1 = neutral vs the
=0 7R — the demand read *is* `rd1_index`, not an extra port). The actual reduction below 7R then comes as
`cap` / `fill-DONE` / `next` / `slot-1` fold into the same `rd1_index` time-mux (each: statement-block the
old read + arbitrate/stall). The demand fold being cycle-identical means the foundation is proven; the
remaining reads are the per-read arbitration/stall work (S1-S4), each with the full SMP ladder.

### 13.8 ✅ S2 (2026-07-11) — R5 fill-DONE folds via a CRITICAL-WORD FLOP, not the arbiter port (7R1W → 6R1W, cycle-identical)

**Result.** `o_fill_rdata` (R5, the miss re-read at `data_X[fill_index]`) is dropped from the SRAM by
**capturing the critical-word-first beat #0 into a 64-bit flop** (`fill_crit_q`) and delivering
`o_fill_rdata` from it, instead of routing it onto the arbitrated `rd1_index` port. `--dump-area` =
`64×512 6R1W ×4` at =1 (from 7R1W); DEAD at =0 (byte-identical). This is the critical-word buffer a real
critical-word-first fill already implies — the demanded dword arrives on the bus once (beat #0) and is
re-delivered to the owner from a register, never re-read from the array.

**Why NOT the arbiter port (the arbiter-routing attempt hangs the boot).** First tried the §13.7 recipe:
route `o_fill_rdata` off the registered `rd1_data_*` (presenting `fill_index` during FILL/DONE) + statement-
block the old read. It measured `6R1W` and passed **default 252/0 + litmus N2 `0022f150` cycle-exact** — but
**every N1 Linux boot HUNG** (7.1/7.1v/6.6 all ran to the 100M-cycle cap, `x3 != 0xAA`). Root cause, two
compounding facts the arch/litmus suites don't exercise:
1. **The early restart samples combinationally.** The core latches `dc_fill_rdata` on `dc_fill_ready`
   (= `o_fill_data_ready`, which rises at `fill_count==1`, i.e. the cycle beat #0 becomes *visible*) —
   ~7 cycles *before* DONE (`heliodor_core:7688,7766` `mshr*_fill_done`). `o_fill_rdata` is read
   **combinationally** the cycle the critical word lands. A *registered* SRAM read (`rd1_data`, index
   presented last cycle) is **one cycle stale** at that sample → the MSHR latches the pre-fill dword →
   the load completes with garbage → boot wedge. (litmus N2's loads complete via the replay path, not
   the early-restart, so it stays cycle-exact — the same "litmus misses what boot hits" asymmetry as the
   L2 byte-write-enable retention bug.)
2. **Non-blocking → the fill re-read collides with hit-under-miss.** heliodor is non-blocking (MSHR a/b),
   so during FILL the primary demand port serves *other* loads (`index_r != fill_index`). The single
   arbitrated port cannot present both `fill_index` (for `o_fill_rdata`) and the hit-under-miss `index_r`
   on the same cycle — forcing `fill_index` corrupts the concurrent demand read. So §13.3.4's "~free /
   no net stall" was **wrong**: folding R5 onto the shared port needs a genuine stall.

**The flop-capture sidesteps both.** `fill_crit_q = i_mem_rdata` when `filling && i_memr_grant &&
fill_woff == fill_offset` (beat #0). It needs **no read port and no arbitration**, so it never collides
with a hit-under-miss demand read, and it is not registered off the array so it is not a cycle stale.
**Byte-identity:** `fill_crit_q` (visible from `fill_count==1`) equals `data_X[fill_index][fill_offset]`
(beat #0 written at `fill_count==0`), and the demanded dword is written exactly once (CWF writes each dword
once; stores only write in IDLE), so it is stable through DONE — matching the live read cycle-for-cycle at
every sample point (early `dc_fill_ready` *and* `o_fill_complete` at DONE). Cost: one 64-bit flop (+64 FF).

**Verification (=1 de-risk, matching the S1 `a115a35` rigor):** default **252/0**, litmus N2 `0022f150`,
N1 boot **7.1 `01217590` / 7.1V `013d8910` / 6.6 `01402120` — all cycle-EXACT** to the =0 baseline (the
boots that hung under the arbiter attempt). synth data `6R1W` (from 7R1W), FF 157573 → 159685 (+2048 = the
S1 `rd1_data` demand port, +64 = `fill_crit_q`). Committed at =0 (byte-identical); the SMP ladder (litmus
N4 / SMP boot / ACT4 / Verilator) is for the eventual default-on flip (S5).

**Lesson for the remaining folds.** R5 was the plan's "nearly free" read, yet the naive arbiter fold hung
the boot. The clean fold used a *dedicated register* (the natural critical-word buffer), not the shared
read port. Re-examine cap (R3) / next (R4) / slot-1 (R6/R7) for the same: a read that is consumed
combinationally at a write-visible or issue-decision edge cannot be served by the registered shared port
without a stall — prefer a dedicated capture/bypass where the datum already exists off the array
(cap latches the victim line at the WB buffer; next same-line extracts from the demand's own registered
line; slot-1 to the demand's line when `index2==index_r`). §13.3.4's stall model still applies where no
such shortcut exists.

### 13.9 ✅ S3 (2026-07-11) — R6/R7 slot-1 best-effort deny is FREE; banking is UNNECESSARY (6R1W → 4R1W)

**Result.** The slot-1 dual-issue read port (R6 `index2` + R7 `next_index2`, the live combinational 2nd
hit port) is **best-effort denied** under `DCACHE_DATA_READ_1R`: `o_hit2` is forced 0 so the core re-issues
that load on pipe-0 (`ld2_complete`, no stall), and the `rdata2` / `next_rdata2` reads become const-guarded
statement blocks that DCE at =1. `--dump-area` = `64×512 4R1W ×4` at =1 (from 6R1W — **two** ports dropped);
DEAD at =0 (byte-identical). Taken ahead of the plan's S3 (R1-demand-unify) because cap/next/R1 are harder
(coherence stall / S3-coupled) and slot-1 is coherence-risk-free (a pure read port, no state writes).

**The key measurement — slot-1 deny costs ZERO IPC.** §13.3 called slot-1 "the largest single IPC lever"
and expected banking (13.3.5) to be needed. It is not. At =1 vs the =0 baseline, cycle counts are
**byte-for-byte identical** across every workload measured, including the load-heavy worst case:

| workload | =0 cycles | =1 cycles | Δ |
|---|---|---|---|
| N1 boot 7.1 | `013d8910`* | `013d8910` | 0 |
| Dhrystone | 230937 | 230937 | 0 |
| CoreMark | 327980 | 327980 | 0 |
| bench_memcpy | 87097 | 87097 | 0 |

(*7.1V, cycle-exact; 7.1 also PASS.) So **dual-issue LOADS — two loads issue-ready in the same cycle —
are rare enough that denying the second dcache read port is free**, even in memcpy (its loads/stores
serialize through the LSU rather than pairing two loads into the dcache same cycle). **Banking is
unnecessary**; best-effort deny is the final slot-1 handling. This retires 13.3.5's open question and the
plan's worry that slot-1 would blow the IPC budget.

**Verification.** DEAD at =0: default **252/0**, litmus N2 `0022f150`, synth `7R1W`, FF 157573, gates/CP
neutral. =1: synth data `4R1W` (from 6R1W), FF 159685 (unchanged from S2 — deny adds no FF), default
**252/0** (pipe-0 fallback correct), litmus N2 `0022f150`, boot 7.1/7.1V/Dhrystone/CoreMark/memcpy all
cycle-exact. Committed at =0; SMP ladder deferred to the default-on flip (S5).

**State: 8R1W → 4R1W.** Demand (S1) + fill (S2) + slot-1 (S3) folded, all IPC-free. The remaining 4 read
ports at =1 are R1 (`index`, live demand), R3 (`cap_index`), R4 (`next_index`), and `rd1_index` (the
consolidated demand). To reach true 1R: R1→R2 unify (SMP-critical, AMO atomicity — the plan's original S3)
absorbs R4 (misaligned loads ride the live path), and R3 cap needs the WB-capture present-then-latch stall.
These three are the coherence-critical remainder; the free wins are exhausted at 4R1W.

## 14. R1→R2 unify — eliminate the live demand read (4R1W → 2R1W), the §11.11-class SMP fold (user-selected 2026-07-11)

Design-first, mirroring the §11 sync-read methodology (the hard SMP work is the design). R1 (`index`, the
live combinational demand read `rdata_0..3`) + R4 (`next_index`, the misaligned hi-dword) are the last
"fake-flop" reads a real SRAM cannot do. Folding them onto the registered `rd1_index` port is the plan's
original S3 (the §13.6 highest-risk item). This section is the implementation design.

### 14.1 What R1/R4 actually serve (post S1-S3)

Under `DCACHE_SYNC_READ=1` the **folded** plain load already delivers off the registered read
(`dhit_rdata_d` → `rd1_dhit_rdata`, S1). R1 remains alive for the **non-folded** accesses, which drive
`i_addr` LIVE at Stage-B (no Stage-A `i_ren_r` strobe — the core excludes them, `dcache:100-104`):
- **AMO reads** (`i_amo_read`): `o_rdata_live` at the RMW value-capture. **The atomicity crux.**
- **Misaligned loads** (`i_load_next`, `dhit_use` excludes them): lo dword via `o_rdata_live` (R1) +
  hi dword via `o_rdata_next` (R4, `next_rdata_same`/`_xline`).
- **Streaming / hit-under-miss** (`stream_rdata0`, `dcache:882`): reads `rdata_0..3` (R1) selected by
  `fill_way` — the early-restart from a partially-filled line during FILL.
- **Uncached** loads use `i_mem_rdata`, NOT the array — so they do NOT keep R1 alive.

So R1's consumers = {non-folded AMO/misaligned-lo hit delivery, streaming}; R4 = {misaligned hi dword}.
DCE is all-or-nothing: R1 drops only when *every* consumer is off `rdata_0..3`; R4 drops only when both
same-line and cross-line misaligned hi are off `next_index`.

### 14.2 The two structural problems

**(a) No Stage-A registration for non-folded → +1 stage + Stage-A/Stage-B port contention.** A folded load
presents its PA one cycle early (`i_addr_r`/`i_ren_r` at `lsr_capture`) so its data is registered by
Stage-B. Non-folded loads have no such early strobe — they read R1 combinationally at Stage-B. To serve
them from the registered port they must **present `index` at Stage-B and read `rd1_data` at Stage-B+1**
= a +1 stall, plus an internal nf-Stage-A registration (`nf_way_q`/`nf_off_q`/`nf_v_q`, mirroring
`dhit_*_q`). Worse: on a back-to-back stream, cycle T carries load-N's non-folded Stage-B (wants
`rd1_index=index`) AND load-(N+1)'s folded Stage-A (wants `rd1_index=index_r`) — a **single-port
contention**. Priority demand(folded Stage-A) > nf, and the loser stalls a cycle. (This is why the arbiter
exists; nf is a new requester below demand.)

**(b) The AMO atomicity crux (§11.11 livelock).** `nf_gap_stall` today deliberately gates on `miss_raw`,
NOT "a new non-folded read", because **stalling a clean hit-EXCLUSIVE AMO one cycle opens a window for the
remote hart to recall the line before the RMW writes back → contended-atomic LIVELOCK** (observed: litmus
N2 both harts wedged at `amoadd 0x800007a8`, `dcache:820-825`). A +1 *registered-read* stall re-introduces
exactly that window on the AMO's clean-hit fast path. So the AMO cannot naively take the +1: the line must
be **pinned** (`pin_line_q`/`pin_cnt_q`, `dcache:1030`) across the registered-read cycle so no recall lands
between the read and the write-back. The pin already exists for the RMW itself (`pin_arm_hit` on a
hit-excl AMO); extend/verify it to cover the extra read cycle. **This is the make-or-break** — the litmus
N2/N4 amoadd/amoswap wedge is the probe.

### 14.3 Staged implementation

- **14.3-a — nf-Stage-A + arbiter nf request (DEAD scaffold).** Add `nf_v_q`/`nf_way_q`/`nf_off_q`
  registered on a non-folded read (gated `DCACHE_DATA_READ_1R`, reset-only → DCE at 0), and
  `rd1_req_nf` presenting `index` below demand priority. No delivery reroute yet → byte-identical at 0.
- **14.3-b — misaligned same-line via registered-line extract (cycle-identical).** For a same-line span
  (`next_same_line`, `offset!=7`), `next_index==index` in value, so the hi dword extracts from the SAME
  registered line at `next_offset`: `o_rdata_next = rd_dword(rd1_line, next_off)`. Cycle-identical (full
  512-bit line registered), no extra read. **Only cross-line pays** the +1 serialize (present `next_index`,
  stall, read). This absorbs R4's same-line usage for free; cross-line joins the nf serialize.
- **14.3-c — AMO pin-across-read (the crux).** Route the AMO value-capture through the registered read,
  holding `pin_line_q` from the read cycle through the RMW write-back so no recall intervenes. Verify with
  litmus N2/N4 amoadd; a clean hit-excl AMO must NOT lose its progress guarantee.
- **14.3-d — streaming from the registered line.** `stream_rdata0` reads the (partially-filled) fill line;
  under the fold it must come from the registered read of `fill_index`/`index` — overlaps the S2
  `fill_crit_q` idea (the demanded dword is already captured). Reconcile: streaming may reuse `fill_crit_q`
  for the demanded dword and the registered line for the rest.
- **14.3-e — statement-block R1/R4 → 2R1W.** Once every consumer is off `rdata_0..3`/`next_index`, convert
  them to `if !DCACHE_DATA_READ_1R` statement blocks so both ports DCE at 1. `--dump-area` = `2R1W`
  (R1+R4 gone; leaves R3 `cap_index` + `rd1_index`).
- **14.3-f — flip / then R3 cap → true 1R.** After R1→R2 unify lands (2R1W), only R3 cap remains for the
  final 1R (§13 cap present-then-latch).

### 14.4 Verification (the SMP heart — every step)

Full ladder EACH stage: default 252/0 + **litmus N2/N4 amoadd/amoswap** (atomicity — the pin probe) +
**ma_data / ma_addr arch** (misaligned lo+hi) + **ACT4 696** (S-mode paging load/store-port collision) +
SMP boot N2/N4 + **Verilator** (NBA ground truth). IPC: the +1 falls on non-folded AMO/misaligned/streaming
and the Stage-A/Stage-B contention loser — measure boot-cy / CoreMark; the folded plain-load hot path
(the common case) stays load-use-unchanged. The AMO clean-hit fast path must keep its 1-cycle progress
(pin), else the contended-atomic litmus wedges.

### 14.5 Progress + the 14.3-c implementation recipe (derived from the code, 2026-07-11)

**Landed (DEAD at 0, byte-identical — the reroute infrastructure):**
- **14.3-a (`9046e5f`)** — `rd1_req_nf` (non-folded reads present `index` below demand in the arbiter) +
  nf-Stage-A regs `nf_v_q`/`nf_way_q`/`nf_off_q` + `rd1_nf_rdata` (the +1-late delivery source, still
  unconsumed). synth 7R1W / FF 157573 / CP 14.745, default 252/0, litmus N2 `0022f150` — all exact.
- **14.3-b (`d448b83`)** — misaligned same-line hi via `rd1_next_same = rd_dword(rd1_nf_line, nf_next_off_q)`;
  `nf_next_off_q`/`nf_next_same_q` register next_offset/next_same_line so the +1-late delivery selects
  same-vs-cross line consistently. Cross-line still reads live `next_rdata_xline` (joins 14.3-e). Byte-id at 0.

**The 14.3-c crux — precise mechanism (read `heliodor_core.veryl:2054-2068` + `dcache.veryl:800-837,1034-1053`):**

The AMO read is ALREADY 2-cycle in the core under MEM_PIPE=1 (M3b `amo_fetched_q`): a FETCH cycle (drive
read → MMU translate → M-stage latches PA `m_pa_q` + `amo_read`) then an ACCESS cycle (dcache reads the
registered `m_pa_q` → `dcache_rdata` = AMO value → alu_wrap does the RMW). **Crucially the dcache sees the
AMO's index ONLY at the ACCESS cycle** (i_addr = m_pa_q), so there is no earlier cycle to pre-read from —
the registered read fundamentally needs a **+1 within the dcache** (present `index` at ACCESS, deliver the
registered dword at ACCESS+1). That +1 is exactly the stall the `nf_gap_stall = miss_raw` gate REFUSES to
apply to a clean hit-excl AMO (dcache.veryl:820-822: stalling it opens a 1-cycle remote-recall window →
contended-atomic LIVELOCK, litmus N2 wedge at `amoadd 0x800007a8`). **So 14.3-c re-introduces that stall
on purpose and must close the window with the pin.**

Why the pin closes it: `pin_arm_hit` (dcache.veryl:1040) is COMBINATIONAL on the current cycle's
`i_amo_read && i_ren && IDLE && cache_hit && hit_excl` — it fires on the AMO's ACCESS cycle (N) whether or
not that cycle stalls (i_ren/cache_hit/hit_excl are all held during the stall). So the pin arms at edge
N→N+1 and is active through the registered-read delivery (N+1) AND the RMW write (N+2), releasing on
`wenl_fires` (N+2→N+3). The only unpinned cycle is N (the request) — identical to today's =0 fast path,
where N is also unpinned and the write at N+1 is pin-covered. The +1 merely shifts write N+1→N+2, still
pinned. `pin_arm_hit`'s `{tag,index} != pin_line_q` guard prevents re-arm thrash at N+1 (already pinned).

**The nf handshake (the intricate part — needs the back-to-back + port-contention cases right):**
- **Port contention**: priority is demand > nf. A folded Stage-A demand read (`index_r`) wins the port over
  a same-cycle non-folded read (`index`). So nf only "wins" when `nf_won = rd1_req_nf && !rd1_req_demand`;
  otherwise it stalls extra until it wins.
- **Sequencing (must handle gapless back-to-back nf reads to the same line / different offset)**: a bare
  `nf_reg_stall = rd1_req_nf && !nf_v_q` MISDELIVERS a new read whose predecessor left `nf_v_q=1` (index
  match is NOT "same read" — offset can differ). Use a toggling in-flight flag: register `nf_won_q = nf_won`;
  `nf_reg_stall = rd1_req_nf && !nf_won_q`; register `nf_way_q`/`nf_off_q`/`nf_next_*` on the cycle nf WINS
  the port (nf_won), aligned with `rd1_data_*` (loaded from `index` at that same edge). Trace: N (win,
  stall, capture) → N+1 (nf_won_q=1, deliver `rd1_nf_rdata`, core completes) → N+2 (next nf read wins, its
  own capture). Each nf read gets exactly one stall + one deliver; the toggle re-arms per read even with
  i_ren held high. Verify the delivery-cycle clear so a stalled-by-other-source N+1 doesn't drop the flag.
- **Delivery reroute (=1)**: `o_rdata` non-folded arm → `rd1_nf_rdata` (was `o_rdata_live`'s hit part);
  `o_data_valid` non-folded (cache_hit) held 0 at N, 1 at N+1; `o_hit_safe` already excludes AMO/misaligned
  so unaffected; `o_stall` gains `nf_reg_stall` (gated DCACHE_DATA_READ_1R). Streaming/mem-fallback part of
  `o_rdata_live` stays for 14.3-d.
- **Core coordination**: the dcache `o_stall` must hold `m_pa_q` (M-stage) stable across N→N+1 so the ACCESS
  index is stable — verify `dcache_stall` feeds the M-stage hold (it gates `iss_dc_ok`/completion). The
  core's `amo_fetch_hold` already sequences per-AMO re-fetch; the dcache +1 just lengthens the ACCESS.

**Why 14.3-c is NOT a safe DEAD-at-0 commit**: unlike a/b (inert comb rewiring), c introduces STALL + STATE
(nf_won_q toggle) + PIN timing — control logic whose entire correctness lives at =1. Byte-identity at 0
proves nothing about it. c must be developed together with 14.3-d (streaming) to reach a =1-testable state,
then temp-flipped =1 and validated on litmus N2/N4 amoadd (the livelock probe) + SMP boot + ACT4 + Verilator
before committing. This is the make-or-break cohesive unit; it is design-first per the §11 methodology.

### 14.6 ✅ 14.3-c IMPLEMENTED + VALIDATED on the Veryl-sim ladder (2026-07-12) — the CRUX works; 🚨 but Verilator exposed a PRE-EXISTING S1/S2/S3 NBA hang

Committed DEAD at 0 (byte-identical; `const DCACHE_DATA_READ_1R = 0`). The AMO/misaligned-lo reroute was
temp-flipped =1, validated across the full Veryl-sim ladder, then reverted for the checkpoint. R1 does NOT
DCE yet — replay/streaming/cross-line-hi stay LIVE (that is 14.3-d/e), so =1 today ADDS the rd1 read without
removing R1 (worse area); it stays DEAD until the fold completes.

**Design (refined from the §14.5 recipe):**
- **Reroute narrowed to `nf_reroute = i_amo_read || i_load_next`** — only the blocking-path reads (the ones
  `o_hit_safe_live` excludes via `!i_amo_read && !i_load_next`). 🔑 **Replay is ALSO non-folded but delivers
  LIVE via `o_hit_safe`** (`i_ren = dmem_ren_m || replay_drive || lsr_drive`; a replayed load has `dhit_use=0`
  so `rd1_req_nf=1`, yet it completes through `o_hit_safe_live`, +0). Rerouting it to the +1 registered read
  while o_hit_safe stays live MISDELIVERS. So replay/streaming keep the live R1 read; R1 stays alive until
  14.3-d/e fold them too. (Streaming = `cache_hit=0` mid-fill → excluded by the `cache_hit` gate anyway.)
- **Line-match handshake (dropped the recipe's nf_off_q toggle)**: `nf_won = rd1_req_nf && !rd1_req_demand`;
  register `nf_won_q` + `nf_addr_q = {tag,index}` on the winning cycle; `nf_ready = nf_won_q &&
  ({tag,index}==nf_addr_q)`. Deliver `rd_dword(rd1_nf_line, offset)` at the LIVE offset from the registered
  line selected by the LIVE `hit_way` (a {tag,index} match ⟹ same line, same way). Correct-by-construction:
  gapless same-line-different-offset delivers (no extra stall); different-line stalls + re-reads. This
  structurally avoids the misdelivery the recipe warned about and DROPS the nf_way_q/nf_off_q/nf_next_off_q/
  nf_next_same_q/nf_v_q regs (superseding the 14.3-a/b scaffold SHAPE — a/b's regs are gone, their INTENT
  stands). Same-line misaligned hi = `rd_dword(rd1_nf_line, next_offset)`; cross-line hi stays live.
- **AMO pin**: `pin_arm_hit` (combinational on the ACCESS cycle) fires whether or not that cycle stalls, so
  the +1 delivery cycle and the RMW write stay pin-covered — no new remote-recall window. Confirmed by litmus.

**🚨 THE DEADLOCK BUG (found + fixed):** the first `nf_reg_stall = nf_reroute && cache_hit && !nf_ready`
(no `i_ren`) HUNG ma_data / ld_st / vfarith. When a store took the port (`lsr_drive=0` → `i_ren=0`) while
`nf_reroute && cache_hit` held, nf_reg_stall stayed high but `nf_won` (needs `rd1_req_nf` → `i_ren`) could
never win → stall with no way to clear. Fix: **gate `nf_reg_stall` on `i_ren`** (the read must actually be
driven for the +1 to make progress). This is the nf analogue of the M4 `m_store_wr_busy` store-vs-load
port-collision lesson: a non-folded stall must not fire when the port is yielded to a store.

**Verification (temp-flip =1, then reverted to =0):**
- ✅ Veryl sim ladder ALL GREEN: default **252/0** · litmus N2 pass (cy=00231860, no forbidden) · **litmus N4
  pass (cy=00535020 — IDENTICAL to the =0 baseline, no forbidden)** · **ACT4 696/0** (the M4 S-mode-paging
  port-collision gate) · boot N1 ×4 (5.15 `00b7de50` / 7.1 `01225ff0` / 6.6 `013f5dd0` / 7.1v `013d8910`,
  x3=0xAA) · boot N2 SMP (cy=`00fd4bc0`, pass). DEAD at 0: default 252/0, litmus N2 `0022f150` (byte-identical).
- 🚨🚨 **Verilator N1 boot HANGS at =1** (r3=`ffffffff80a85b60`, cy 100M cap; a kernel-address wedge). The
  Veryl sim (all backends) is green — the classic NBA-race-masked-by-the-sim pattern (cf. SMP LR/SC livelock,
  L2 byte-write-enable JIT, MEM_PIPE). **ISOLATED via a new `const DCACHE_NF_REROUTE`** (gates ONLY the nf
  delivery/stall; separate from `DCACHE_DATA_READ_1R` which gates S1/S2/S3 + the nf regs): with
  `DCACHE_DATA_READ_1R=1, DCACHE_NF_REROUTE=0` (S1/S2/S3 on, my reroute OFF, AMO/misaligned LIVE) Verilator
  **hangs at the IDENTICAL address** → **the hang is a PRE-EXISTING S1/S2/S3 (demand/fill/slot-1 fold) NBA
  bug, NOT 14.3-c.** S1/S2/S3 were "de-risked on the Veryl sim" (boot cy-EXACT) but NEVER Verilator-tested
  (deferred to "S5 default-on"); this session is the first `DCACHE_DATA_READ_1R=1` Verilator run and it
  exposed the latent hang. **My 14.3-c reroute is exonerated.** The whole =1 path (goal-b D$ read-port
  narrowing) is Verilator-blocked until the S1/S2/S3 NBA hang is root-caused.

**⏭️ Next (priority order):**
1. **🚨 ROOT-CAUSE the S1/S2/S3 Verilator/NBA hang** (blocks ALL of =1). Prime suspect: the arbitrated
   registered read `rd1_data_* = data_X[rd1_index]` is read-OLD under NBA (correct SRAM), but the Veryl sim
   may have delivered read-NEW, masking a load that needs the same-cycle write when store-to-load forwarding
   doesn't cover it (§13.7 claimed cycle-identical on the Veryl sim ONLY). Add per-fold isolation consts
   (S1 demand / S2 fill_crit / S3 slot-1) to bisect; instrument the wedge PC on Verilator. Both hang at the
   SAME PC, so a single common root cause.
2. **14.3-d** streaming reroute (fill_crit_q + registered line) + cross-line hi serialize.
3. **14.3-e** statement-block R1/R4 → DCE (`--dump-area` 2R1W).
4. **14.3-f** flip default-on — GATED on (1) being fixed and the full ladder INCLUDING Verilator green.

### 14.7 ✅ The S1/S2/S3 Verilator NBA hang ROOT-CAUSED + FIXED (2026-07-13) — read-during-write on the registered read; write-forward bypass

The §14.6 blocker is resolved. Bisected with the per-fold isolation consts (`S1_DEMAND` / `S2_FILL` /
`S3_SLOT1`, each gating one fold's delivery): with `DCACHE_DATA_READ_1R=1, S1_DEMAND=0` (S1 demand reverted
to the live read, S2/S3 folded) the **Verilator N1 boot PASSES at the exact =0 baseline cy 12036187** →
**the hang is S1, the demand registered read** (`rd1_data_* = data_X[rd1_index]`).

**Root cause — read-during-write, read-OLD under NBA vs read-NEW on the Veryl sim.** At the folded load's
Stage-B (cycle T+1) the two reads diverge for a store that writes the load's line at the Stage-A cycle T
(landing at the T→T+1 edge):
- **=0 live read** `dhit_rdata_d = data_X[dhit_index_d]` is combinational at Stage-B → reads data_X AFTER the
  store landed = **read-NEW**.
- **=1 registered read** `rd1_data <= data_X[rd1_index]` samples at the T→T+1 edge with the OLD (pre-edge)
  data_X values = **read-OLD** — it misses the cycle-T store.

The §13.7 de-risk ("boot cy-EXACT on the Veryl sim") held because **the Veryl sim evaluates the write before
the read within an edge = read-NEW**, so the registered read saw the store and matched =0. **Verilator (true
NBA) is read-OLD**, so the registered read lags one write-generation. The gap is a *just-drained* store: the
store buffer forwards in-flight stores (§13.7's masking), but once a store DRAINS to data_X the SB no longer
forwards it, and a load reading that line the same cycle gets the stale (pre-drain) value → a kernel spinlock
never sees the release → boot wedge (r3=`ffffffff80a85b60`, cy 100M). litmus / ACT4 / N-hart boot on the
**Veryl sim** all passed (read-NEW there), which is why "de-risked on the Veryl sim ≠ Verilator-clean".

**Fix — a write-forward bypass on the registered read (write-first SRAM emulation).** In the `rd1_data_*`
always_ff, when the byte-write-enable write fires to the read line this cycle, forward the merged value:
`rd1_data_k <= (d1_fire_k && d1_idx == rd1_index) ? (data_k[rd1_index] & ~d1_msk) | (d1_new & d1_msk)
: data_k[rd1_index]`. Under NBA the RHS `data_k[rd1_index]` is read-OLD; the merge reconstructs the post-write
value, so `rd1_data` becomes read-NEW = matches the =0 live read. **No new read port** (same `data_k[rd1_index]`
net + the already-computed `d1_new`/`d1_msk`); it is the standard external write-first bypass a real SRAM
macro needs — realistic, not a hack. Reset-only → DCE at 0.

**Validation:** =0 byte-identical (252/0, litmus N2 `0022f150`). =1 Veryl sim UNCHANGED (the bypass is a
Veryl-sim NO-OP — it was already read-NEW): default 252/0, litmus N2 `00231860`, boot N1 ×4 (7.1 `01225ff0`
/ 7.1v `013d8910` / 6.6 `013f5dd0`, cy IDENTICAL to the pre-bypass =1). **=1 Verilator N1 boot now PASSES**:
S1/S2/S3 + bypass (nf off) = cy `12036187` (=0 baseline EXACT, the folds are cycle-identical on Verilator
too); full stack S1/S2/S3 + 14.3-c reroute + bypass = cy `12048346` (+12k = the AMO/misaligned +1). **Verilator
SMP N2 boot also PASSES** (full stack, cy `16590558`, "SMP(N=2) LINUX BOOT PASSED", x3=0xAA) — the bypass is
correct under multi-hart NBA coherence, not just single-hart. **The whole =1 D$ read-port-narrowing path is
Verilator-clean.** Committed DEAD (still not default-on: R1 does not DCE until 14.3-d/e). 🔑 Campaign process fix: **every fold flip must be Verilator-gated, not just Veryl-sim
de-risked** — the sim's write-before-read masks read-during-write NBA hazards.

**⏭️ Next:** 14.3-d (streaming) → 14.3-e (R1/R4 DCE → 2R1W) → 14.3-f (default-on, now with the Verilator
gate satisfiable). Re-run the FULL Verilator ladder (SMP boot N2/N4, litmus) at 14.3-f time.

### 14.8 ✅ 14.3-d streaming reroute IMPLEMENTED + VALIDATED (2026-07-14) — the mid-fill early-restart read folds onto fill_crit_q, CYCLE-IDENTICAL, Verilator-clean

Streaming (`stream_rdata0`, the hit-under-miss early-restart that reads the partially-filled line via
`data_X[index]` = an R1 consumer) now sources the demanded dword from the S2 critical-word flop
(`fill_crit_q`) instead of the live R1 read. Committed DEAD at 0 (byte-identical); the new `const S4_STREAM
= DCACHE_DATA_READ_1R` gates it.

**The equivalence (why fill_crit_q is exactly right).** With CWF (`s14_cwf_en=1`, always on) the fill bursts
the demanded dword as beat #0, so a streaming demand is the CRITICAL word: `offset == fill_offset`, i.e.
`stream_rel == 0`. Its value in the array is `data_{fill_way}[fill_index]` at dword `fill_offset` =
`i_mem_rdata` of beat #0 = `fill_crit_q` — the SAME equivalence §13.8 (S2) already uses for `o_fill_rdata`.
Timing lines up: `stream_hit0(critical)` needs `fill_count >= 1`, which becomes true at the same edge beat
#0 writes `fill_crit_q`, and the flop holds stable through DONE.

**Design:**
- **`stream_hit0` restricted to the critical word at =1** (`&& (!S4_STREAM || stream_rel == 3'd0)`). A
  non-critical stream hit (`offset != fill_offset`) is DENIED and completes via the DONE path — a
  best-effort deny, like S3 slot-1. At 0 unrestricted = byte-identical.
- **`stream_rdata0 = if S4_STREAM ? fill_crit_q : stream_rdata0_live`** (the live `rdata_X` hit mux renamed
  to `stream_rdata0_live`, kept for the =0 arm). At =1 no `data_X[index]` read → streaming's R1 dependency
  drops. (Ternary, not a statement block — the actual R1 port DCE waits for 14.3-e, which also needs the
  replay consumer of `live_hit_rdata` off R1; converting the source `rdata_X` reads to `if !DCACHE_DATA_READ_1R`
  statement blocks is 14.3-e's job.)
- **`fill_crit_q` moved up** to before the streaming block (Veryl requires definition-before-reference for
  module-level `let`/`var`; SV would allow the forward ref, Veryl does not). The `fill_rdata_live` =0 arm +
  the `o_fill_rdata` const-mux stay in place (backward ref to the flop).

**Validation — the FULL ladder, every result BYTE-IDENTICAL to the 14.3-c =1 baseline** (so the critical
reroute is cycle-exact AND the non-critical deny NEVER fires — every streaming hit in the suite + all boots
is the critical word, exactly as CWF predicts, so the deny is zero-IPC):
- DEAD at 0: `veryl test` **252/0**, litmus N2 **`0022f150`** (byte-identical).
- =1 Veryl sim: default **252/0** · litmus N2 **`00231860`** · litmus N4 **`00535020`** · **ACT4 696/0** ·
  boot N1 7.1 **`01225ff0`** / 7.1v **`013d8910`** · boot N2 SMP **`00fd4bc0`** — ALL identical to 14.3-c =1.
- =1 **Verilator** (the NBA ground truth — the §14.7 make-or-break gate): **N1 boot `12048346`** and
  **N2 SMP boot `16590558`** — both PASS (x3==0xAA), both EXACT to the 14.7 full-stack baseline. Streaming
  from the flop is Verilator-clean under single- and multi-hart NBA coherence.

R1 (`data_X[index]`) at =1 now has ONE remaining consumer: `live_hit_rdata` (the **replay** non-folded hit,
which delivers LIVE via `o_hit_safe` — the §14.6 note flagged rerouting it as misdelivering while o_hit_safe
stays live). R4 (`data_X[next_index]`) still serves cross-line misaligned hi (`next_rdata_xline`, live).
**⏭️ Next: 14.3-e** — fold the replay consumer + cross-line hi off R1/R4, then convert `rdata_X`/`next_rdata`
to `if !DCACHE_DATA_READ_1R` statement blocks so both ports DCE (`--dump-area` 2R1W). Then 14.3-f default-on.

### 14.9 ✅ 14.3-e replay reroute IMPLEMENTED + VALIDATED (2026-07-14) — R1's last consumer folds onto the registered read; Verilator-clean. R1 DCE deferred (a TB read-contract update)

The **replay** (an MSHR miss re-read — the non-folded ordinary cache-hit) was R1's (`data_X[index]`) last
live consumer. It now delivers from the registered read (`rd1_nf_rdata`, the 14.3-c nf line) instead of the
live `live_hit_rdata`. Committed DEAD at 0; the new `const DCACHE_NF_REPLAY = DCACHE_NF_REROUTE` gates it
(separable for a Verilator bisect).

**The crux — a replay demands SAME-CYCLE completion, unlike AMO/misaligned.** The core samples
`dcache_rdata` (= `o_rdata`) combinationally on `replay_hit_fire = replay_drive && dc_hit_safe`
(`heliodor_core:7677,7763`). A registered read is +1 late, so the reroute would misdeliver on the request
cycle. The fix: **gate the replay's `o_hit_safe` on `nf_ready`** (`o_hit_safe_live`'s hit terms →
`hit_lo_safe && nf_replay_ready`) so the safe-hit does NOT assert until `rd1_nf_rdata` is valid. The core
then holds `replay_q` and re-drives the *stable* MSHR address one cycle later, when `nf_ready` delivers the
correct dword. This is sound because, on the un-ready cycle:
- `dc_miss_valid` (= `o_miss_valid = load_sel && …`) is **0 on a hit** (`load_sel` needs a real miss), so
  `replay_claim` cannot false-fire (`heliodor_core:7716`).
- `replay_q` **persists** (no hit → no retire, no fill → no claim) and re-drives next cycle (`:7714-7722`).
- `mshr_capture_*` requires `!replay_q`, so no spurious re-capture during the +1 (`:7456-7457`).
During a replay the issue port is blocked (`iss_dc_ok` has `!replay_q`) and AMO/misaligned are gated
`!replay_drive`, so nf always wins the read port — the +1 is a clean 2-cycle handshake. `nf_reroute` reduces
to `rd1_req_nf` at DCACHE_NF_REPLAY=1 (the unified R1→R2 fold: AMO ∪ misaligned ∪ replay).

**Validation — full ladder + Verilator, all green at =1:**
- DEAD at 0: `veryl test` **252/0**, litmus N2 **`0022f150`** (byte-identical).
- =1 Veryl sim: default **252/0** · litmus N2 **`0022f150`** · litmus N4 **`00535020`** (NO forbidden) ·
  **ACT4 696/0** · boot N1 7.1 **`0122d520`** / 7.1v **`013e9a80`** · boot N2 SMP **`00fe5d30`**.
- =1 **Verilator** (NBA ground truth): **N1 boot `12137740`** and **N2 SMP boot `16660573`** — both PASS
  (x3==0xAA). The replay's +1 re-drive is NBA-correct single- AND multi-hart.
- **IPC:** the replay +1 shows as a small boot slowdown (N1 7.1 +0x7530 ≈ 30 k cy / ~0.16 %; Verilator N1
  +89 k / ~0.7 %; N2 SMP +0x11170 ≈ 70 k / ~0.4 %) — replays are post-miss, so the +1 rides an already-slow
  path. Litmus N2 *dropped* to the =0 value (0022f150, was 00231860 at 14.3-d) — the replay serialization
  changes the contended-atomic interleaving; it still PASSES (no forbidden), and litmus N4 is unchanged, so
  it is a benign timing artifact of the stress test, not a reroute regression (boot cy *rising* confirms the
  reroute engages).

**🚨 R1 DCE deferred — a TB read-contract issue, not a design bug.** Converting `rdata_X` to a statement
block (so `data_X[index]` DCEs → 3R1W) FAILS `test_cache_edge` at =1 while the full core ladder + Verilator
pass. Root cause: `test_cache_edge` (a directed dcache TB) does not connect `i_ren_r`/`i_ren_folded` (all
reads are non-folded) and samples `o_rdata` at **`i_ren=0`** (a passive read of the just-filled line at
`tc=3/6/9`). With `i_ren=0`, `nf_replay=0` → `nf_reroute=0` → `nf_hit_sel` falls to `live_hit_rdata`
(`rdata_X`); the reroute-only build keeps `rdata_X` live so it reads correctly, but the DCE build zeroes it.
This is exactly the **fake-flop read the campaign is removing**: a realistic 1R1W SRAM cannot deliver
combinational `o_rdata` for a held address without a driven read. The REAL core never samples `o_rdata` at
`i_ren=0` (it always drives the read — `replay_hit_fire`/`o_hit_safe`/`o_data_valid` all need `i_ren`), so
the fold is correct; only the TB's fake-flop sampling must be updated. R1 DCE is deferred to a focused
follow-up that updates `test_cache_edge` to sample via a driven read (then `--dump-area` 3R1W).

**⏭️ Next:** (1) update `test_cache_edge` to a driven-read sample + statement-block `rdata_X` → R1 DCE
(4R1W→3R1W); (2) cross-line hi (`next_rdata_xline`, R4) nf serialize + statement-block `next_rdata` → R4 DCE
(→2R1W); (3) 14.3-f default-on (Verilator ladder).

### 14.10 ✅ R1 DCE LANDED (2026-07-14) — `data_X[index]` drops: 4R1W → 3R1W

`rdata_0..3` (the live demand read R1) converted to a const-guarded statement block gated on
`DCACHE_R1_DCE = DCACHE_NF_REROUTE && DCACHE_NF_REPLAY && S4_STREAM` (all R1 consumers off — AMO/misaligned
+ replay rerouted, streaming on `fill_crit_q`, RMW-old dead at DCACHE_DATA_1RW=1; the `&&` of the three
keeps the §14.7 bisect configs correct). At =1 the four `data_X[index]` read ports DCE.

**`test_cache_edge` updated to the realistic-SRAM read model.** The §14.9 blocker: the TB sampled `o_rdata`
at `i_ren=0` (a fake-flop held-address read the 1R1W SRAM removes). Rewrote its harness FSM to **drive
`i_ren=1` and sample `o_rdata` on the completion cycle (`!o_stall` while driven)** — the demand fills, then
the +1 nf registered-read handshake delivers the dword. Same conflict-miss + eviction + refill sequence,
now via driven reads (matches how the real core always samples `o_rdata` under `i_ren=1`). Passes at =0 AND
=1.

**Validated:** `--dump-area` **`64×512 3R1W ×4`** (was 4R1W — R1 gone). DEAD at 0: `veryl test` **252/0**
(incl. the rewritten `test_cache_edge`), litmus N2 **`0022f150`** (byte-identical). =1: **252/0**, litmus N2
`0022f150`, boot N1 7.1 **`0122d520`** / 7.1v **`013e9a80`**, **Verilator N1 boot `12137740`** — all IDENTICAL
to the 14.3-e reroute-only =1 (the DCE removes an unused read, so it is byte-identical, Verilator-clean).

**⏭️ Next:** cross-line hi (`next_rdata_xline`, R4) nf serialize + statement-block `next_rdata` → R4 DCE
(3R1W→2R1W); then 14.3-f default-on (full Verilator ladder).

### 14.11 ✅ R4 CROSS-LINE SERIALIZE + DCE LANDED (2026-07-14) — `data_X[next_index]` drops: 3R1W → 2R1W

The last R4 consumer — a CROSS-line misaligned load's hi dword (`next_rdata_xline` = `data_X[next_index]`)
— folds onto the single registered read port by SERIALIZING the two lines it needs. Committed DEAD at 0
(byte-identical); the new `const DCACHE_NF_XLINE = DCACHE_NF_REROUTE` gates the serialize and
`DCACHE_R4_DCE = DCACHE_NF_REROUTE && DCACHE_NF_XLINE` gates the port DCE (separable for a Verilator bisect).

**The problem.** A same-line misaligned load reads ONE 512-bit line, so the nf registered read (14.3-c) yields
both dwords (`rd1_nf_rdata` at `offset`, `rd1_next_same` at `next_offset`) from the SAME `rd1_nf_line`. A
CROSS-line load (`offset==7`) needs the lo line (`index`) AND the hi line (`next_index`) — two reads, one
registered port. The core's LSU samples `o_rdata` (lo) and `o_rdata_next` (hi) **combinationally on the SAME
cycle** (`{i_load_data_next, i_load_data} >> byte_off*8` in `lsu.veryl`), so both must be valid together on
the final delivery cycle; but the LSR re-drives the load every cycle while `dcache_stall=1` and completes on
`!dcache_stall`, so extra stall cycles are free — only the *delivered data* must be right, not its latency.

**The design (a 2-phase serialize with a held-dword write-forward bypass).**
- **`xline_ph_q`** sequences the port: phase 0 presents the lo line (`index`, the existing nf read), phase 1
  presents the hi line (`next_index`). `nf_rd_index`/`nf_rd_tag`/`nf_rd_way` switch the arbiter target +
  `nf_addr_q`/`nf_ready`/`rd1_nf_line` way-select to the hi line in phase 1. `xline_arm` = a cross-line
  misaligned load with BOTH lines cached; the phase advances 0→1 on the phase-0 `nf_ready` and resets to 0
  when not arming (load done / miss / not cross-line).
- **`xline_lo_q`** captures the lo dword at the phase-0 `nf_ready` and HOLDS it across the hi read (in phase 1
  the registered port holds the HI line, so `rd1_nf_rdata` is no longer the lo). Delivery: `o_rdata =
  xline_lo_q` (phase 1), `o_rdata_next = rd1_next_same` = `rd_dword(rd1_nf_line, next_offset)` on the
  registered hi line — both on the final unstalled cycle.
- **The held-dword hazard (the crux — same class as §14.7).** A store-drain (`d1_drain_fire` at `sindex`) can
  land on the lo line WHILE `xline_lo_q` is held (the read port is busy on the hi line, so the §14.7 rd1_data
  bypass — keyed on `rd1_index=next_index` — does NOT cover a write to `index`). So `xline_lo_q` carries its
  OWN write-forward bypass: at the capture (`xline_lo_byp_cap`, base `rd1_nf_rdata`) and every hold cycle
  (`xline_lo_byp_hold`, base `xline_lo_q`) it merges a `d1_fire` to the lo way at `index` for the this-cycle
  store, so the held lo always equals the `=0` live read (`reflects stores ≤ C`).
- **`nf_deliver_ready` = `nf_ready && (!xline_arm || xline_ph_q)`** extends `nf_reg_stall` through BOTH phases
  (the stall no longer drops on the phase-0 lo-ready). Folds to `nf_ready` for every non-xline access
  (AMO / misaligned-lo / same-line / replay) = byte-identical.
- **No deadlock.** `rd1_req_demand = i_ren_r` (the folded Stage-A demand) is driven 0 by the core for a
  non-folded misaligned load (the core excludes it, `dcache.veryl:809`), so nf wins the read port every
  cycle in both phases — the priority-demand contention that a folded read would cause never arises here.

**R4 DCE.** With both `next_rdata_same` (same-line, off via nf_reroute → `rd1_next_same`) and
`next_rdata_xline` (cross-line, off via the xline serialize → `rd1_next_same`) converted to const-guarded
STATEMENT blocks (`if !DCACHE_R4_DCE`), the four `data_X[next_index]` reads DCE at =1. With R1 (§14.10) and
R4 gone the data array is **2R1W** (R2 `rd1_index` + R3 `cap_index` remain).

**Validated — the FULL ladder + Verilator, all green.** `--dump-area` **`64×512 2R1W ×4`** (was 3R1W — R4
gone). DEAD at 0: `veryl test` **252/0**, litmus N2 **`0022f150`** (byte-identical). =1 Veryl sim: default
**252/0** · litmus N2 **`0022f150`** · litmus N4 **`00535020`** (NO forbidden) · **ACT4 696/0** (incl. the
`misalign*` suites — cross-line misaligned in S-mode paging) · boot N1 7.1v **`013ec190`** / 6.6 **`01410b80`**
· boot N2 SMP **`00fe5d30`**. =1 **Verilator** (the NBA ground truth — the §14.7 make-or-break gate): **N1
boot `12144008`** and **N2 SMP boot `16662467`** — both PASS (x3==0xAA). The held-dword write-forward bypass
is NBA-correct single- AND multi-hart. **IPC:** the cross-line serialize adds ~2-3 cy per cross-line
misaligned load (rare), showing as a small boot slowdown ONLY on misaligned-heavy paths (N1 7.1v +0x2710 vs
§14.10, Verilator N1 +0x67C8, N2 SMP +0x766); litmus N4 and the veryl-sim N2 SMP are unchanged (few/no
cross-line misaligned loads). All-green includes the Veryl-sim ladder + both Verilator boots.

**⏭️ Next: R3 cap → true 1R (2R1W → 1R1W).** The cap read (`cap_data` = `data_X[cap_index]`, R3) is the last
non-arbitrated data read. Fold it onto `rd1_index` (the arbiter already has `rd1_req_cap` presenting
`cap_index`; the 5 cap FSM latches are a present-then-latch that can ride the `+1` when demand stalls — watch
the WB/probe-recall livelock) → statement-block `cap_data` → true 1R1W. Then **14.3-f default-on** (flip
`DCACHE_DATA_READ_1R`/`DCACHE_NF_REROUTE` to 1 permanently, re-run the full Verilator ladder incl. N4).

### 14.12 ✅ 14.3-f DEFAULT-ON (2026-07-14) — the 2R1W read side is the SHIPPED design (7R1W → 2R1W)

`DCACHE_DATA_READ_1R` and `DCACHE_NF_REROUTE` flipped to **1 permanently** (user decision: bank the validated
2R1W win now, do R3 cap → 1R1W as a follow-up). The whole staged read-fold stack is now live in the shipped
design: **S1** demand (registered read) / **S2** fill-DONE (critical-word flop) / **S3** slot-1 (best-effort
deny) / **14.3-c** AMO + misaligned-lo reroute / **14.3-d** streaming (fill_crit_q) / **14.3-e** replay
reroute + R1 DCE / **14.3-f** cross-line serialize + R4 DCE. The dcache data array is a **2R1W** SRAM
(R2 `rd1_index` arbitrated + R3 `cap_index`), down from the original 7R1W (the write side was already 1W via
`DCACHE_DATA_1RW`). The per-fold bisect knobs (`S1_DEMAND`/`S2_FILL`/`S3_SLOT1`/`S4_STREAM`/
`DCACHE_NF_REPLAY`/`DCACHE_NF_XLINE`) stay; set `DCACHE_DATA_READ_1R` back to 0 to restore the byte-identical
7R1W live-read design for debugging.

**This is a REAL design change (NOT byte-identical).** The synchronous registered read adds `+1` stalls to
the non-folded paths (AMO / misaligned-lo / replay / cross-line serialize) — the small IPC cost the campaign
accepts for the realistic-SRAM port reduction. The =1 behaviour was validated as a cohesive unit in
§14.3-c..f + §14.10/§14.11; this flip just makes it the default, so the results carry over exactly.

**Shipped baselines (=1, the new default).** `veryl test` **252/0** · litmus N2 **`0022f150`** · litmus N4
**`00535020`** (no forbidden) · **ACT4 696/0** · boot N1 7.1v **`013ec190`** / 6.6 **`01410b80`** · boot N2
SMP **`00fe5d30`** · boot N4 SMP **`015eccb0`**. **Verilator** (NBA ground truth): N1 boot **`12144008`**, N2
SMP boot **`16662467`** — both PASS (x3==0xAA). (Prior =0 shipped baselines for reference: N2 SMP ~`00fd24b0`
7R1W; the flip raises boot cy by the non-folded `+1` stalls.)

**⏭️ Next: R3 cap → true 1R1W** (the final read fold). Present the victim/probe/mis/flush index during the
preceding stall so the registered line is ready when the capture fires (present-then-latch). The eviction
case is the crux: the fill overwrites the victim at `cap_index` from beat #0, so the victim MUST be registered
BEFORE the fill's first write — present `f_index` during the miss/grant-wait stall (the "demand-stall hides
the +1"), not at `fill_start_fire`. Then `cap_data` as a statement block → true **1R1W**.

### 14.13 🔬 R3 cap → 1R1W — feasibility + design (investigated 2026-07-15, NOT yet implemented)

The cap read (`cap_data` = `data_X[cap_index]`, an 8-dword WHOLE-LINE read into the writeback buffer
`wb_data`) is the last non-arbitrated data read (R3). Folding it onto `rd1_index` needs a per-source
present-then-latch. A read-only FSM trace (the 5 sources: `cap_fill_go` evict / `cap_probe_go` recall /
`cap_mis_go` misaligned-detour lo+hi / `cap_flush_go` sweep) found the fold is tractable but coherence-critical
and needs **two distinct capture mechanisms** — this is qualitatively the hardest fold in §14:

- **Fill (eviction) — present-early, coherence-neutral.** `f_index`/`victim_way` are already registered
  (`f_index_q`/`victim_way_q`, DCACHE_SYNC_READ), and `fill_start_fire` is preceded by a grant-wait stall
  (`= … && i_memr_grant`; the request precedes the grant by ≥1 cycle). So present `f_index_q`/`victim_way_q`
  via a high-priority pre-fill arbiter request DURING the grant-wait; `rd1_data` holds the victim by
  `fill_start_fire`; latch `wb_data` there (same cycle as `wb_v`, synchronized). The victim-integrity window
  is exactly the fill-start cycle — the fill RMW overwrites `data_X[f_index]` from beat #0 (next cycle), so
  the victim MUST be captured from the pre-registered read, never a +1-late read. The pre-fill request must
  WIN the port during the stall (demand isn't progressing then, so give it priority).
- **Probe / mis / flush — +1-latch with a `wb_data_ready` gate, coherence-neutral.** These fire
  combinationally with NO preceding stall to present early. Present `cap_index` at the `cap_*_go` cycle
  (the existing `rd1_req_cap`), latch `wb_data` from `rd1_data[cap_way_q]` the NEXT cycle. Keep `wb_v` /
  the line invalidation / `o_evict1_v` / `o_probe_ack` AT `cap_*_go` (UNCHANGED — the line's DATA survives
  invalidation, only `valid` clears, and no writer touches `cap_index` right after for these three). The
  drain reads `wb_data` combinationally (`o_memw_wdata = wb_data` when `wb_v`, single-cycle full-line write
  on `wb_fire = wb_v && i_memw_grant`); today `wb_v`+`wb_data` are set by the SAME NBA at `cap_*_go`, both
  valid next cycle. With a +1 `wb_data` latch, gate `wb_fire` on a new `wb_data_ready` flag so the drain
  can't read `wb_data` before it lands (≤1 extra drain cycle only if the write grant was instant). This
  keeps ALL coherence timing at `cap_*_go`; only the drain's first beat may slip one cycle.

Then `cap_data` → a `if !DCACHE_CAP_1R` statement block so `data_X[cap_index]` DCEs → **1R1W**.

**Why it's the hard one (and needs the full slow gate).** Unlike R1/R4 (single-dword load delivery), cap is
a whole-line writeback capture fused with line invalidation + the coherence eviction notify. The design above
is coherence-NEUTRAL by construction (capture timing / notify / invalidate all stay at `cap_*_go`; only the
data SOURCE changes and the drain's first beat may slip), but the failure modes (a stale writeback = silent
dirty-data loss; a probe-recall or eviction-notify livelock) are exactly what only Verilator + the litmus N4
battery + SMP boot catch — and those runs are ~15–55 min each on this box. Implement behind `DCACHE_CAP_1R=0`
(byte-identical DEAD), then flip + run the FULL ladder incl. Verilator N1/N2 + litmus N4 + SMP N2/N4 boot.
Alternative if the +1-latch coherence proves fragile: a uniform "+1-arm" that delays the WHOLE capture
(wb_v + invalidate + notify + fill-start) by one cycle — simpler/atomic but shifts coherence timing +1 for
the rare cap events (the memory-model livelock risk the campaign has flagged).
