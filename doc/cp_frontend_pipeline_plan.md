# CP — front-end pipeline (the real 14.565 floor after the wall cut)

After the AMO-wstrb wall fell (`66c0f14`, 15.300 → 14.565) and the **keystone was shown to
be mis-aimed** (`a78dee7`: registering the CDB does NOT cut `rs1_rdy`), the measured floor is
the **single-cycle front end**. This plan is grounded in `--dump-timing` traces at 14.565.

## 1. The measured cone (MEASURED, not the keystone doc's model)

The 14.565 floor is a BROAD cone rooted at the fetch PC `pc_q`, feeding *every* top endpoint —
`rs1_rdy`, `commit_cnt`, `head`, `sh_valid`, `entries` (the IQ/ROB allocate fan-out) — all at
14.3–14.6. Traced (both issue slots):

```
pc_q[FF]
  → u_imem_mmu V=1 (hypervisor two-stage) TLB  v1_vpn→v1_level→v1_valid→v1_match→v1_hit   ~5.0 ns
  → o_imem_paddr
  → u_icache  tag → valid_* → hit_* → stream_rdata → icache_rdata   (COMBINATIONAL read)  ~2.6 ns  (→7.6)
  → u_cexp/u_cexp1 (compressed-instr expand) → s1_instr → u_dec/u_dec2 (DECODE)           ~3.4 ns  (→11.0)
  → free-list pop (pdst alloc) → IQ rename/allocate → {rs1_rdy, entries, head, commit_cnt}[FF.D]  ~3.4 ns (→14.565)
```

Segment budget (of the 14.565): **imem MMU ~5.0 · icache read ~2.6 · cexp/decode ~3.4 ·
rename/allocate ~3.4.**

### 1.1 Why the fetch-buffer bypass is NOT the cut
heliodor already has a fetch buffer (`fb_instr`, depth-8) with a bypass: when the FB is empty,
decode reads the live combinational fetch (`if_*_q = fb_count!=0 ? fb[head] : <live>`,
`core.veryl:1218`). It is tempting to think "remove the bypass → decode reads a register → cut."
**MEASURED: removing ALL the `if_*_q` bypasses moves CP only 14.565 → 14.365 (−0.2 ns).** The
critical route is **not** the FB-register *read* — it is the **icache combinational *read*** that
feeds `cexp → decode` directly (via `s1_instr` on slot-1, `icache_rdata` on slot-0), regardless of
the FB bypass. The FB stores the *post-cexp* aligned instruction; the icache read upstream of it is
the long pole. So the cut must **register the icache read output**, not the FB read.

## 2. The cut order (recommended: icache sync-read FIRST, then imem-MMU staging)

Both register boundaries are ultimately needed (the campaign wants a multi-stage front end). The
question is which yields the better floor first.

| cut | register boundary | new floor | campaign role |
|---|---|---|---|
| **(A) icache synchronous read** | after `icache_rdata` (~7.6 ns) | **~7.6 ns** (imem+icache fetch half; decode/rename half ~7.0 drops below) | **Phase C/D icache SRAM migration** (a real compiler SRAM IS sync-read) — does double duty |
| (B) imem-MMU translate stage | after `o_imem_paddr` (~5.36 ns) | ~9.2 ns (icache+decode+rename half) | pure pipeline reg (the TLB is flops, not SRAM) — worse floor, not SRAM-aligned |

**→ Recommendation: (A) icache sync-read first.** It gives the better floor (~7.6 vs ~9.2), and it
**is** the front-end SRAM migration the campaign needs anyway (SRAM ⊂ pipelining) — the same
sync-read pattern as the planned dcache-sync-read warm-up, applied to the icache where the floor
actually is. After (A), the **imem MMU V=1 TLB (~5.0 ns) becomes the fetch-half bottleneck** → do
(B) next to split the fetch half (imem translate | icache access), driving toward the
decode/rename floor (~7.0 ns).

Trajectory: `14.565 → ~7.6` (A, icache sync-read) `→ ~7.0` (B, imem staging) → then the
decode/rename/allocate cone (and the execute/wakeup keystone, finally unmasked) is the floor.

### 2.1 🚨 MEASURED (2026-06-30) — cut A is only −0.435 ns; 13.8–14.6 is a DENSE MULTI-FRONT wall
The icache-sync-read scaffold was built (param `ICACHE_SYNC_READ`, DEAD=0 byte-identical, CP
14.565 unchanged) and **synth-flipped (=1): CP 14.565 → 14.130 (−0.435 ns only, NOT ~7.6).**
The segment prediction (~7.6) was wrong because the front end was **not** alone at 14.565 — the
13.8–14.6 band is a dense multi-front wall, and cutting the front-end front merely surfaces the
ones right behind it:
- `head → n_inflight[5]` **14.130** — the **plain-store commit translation** (`head →
  commit_store_fire → dmem_vaddr → u_dmem_mmu TLB → … → n_inflight`). The AMO-wstrb wall cut
  removed the *AMO* contribution; the **plain store still translates live at commit** → this is
  the W1 pre-translate target (`cp_commit_store_pretranslate_plan.md`), NOT a free cut.
- `head → vrf[*]` **13.880** — the **vector commit writeback** (VRF write from the ROB head).
- the `commit_cnt/sh_valid/entries` cluster **14.315** (dispatch/commit fan-out).

**→ Consequence.** A single front-end cut (icache sync-read) buys ~0.4 ns for a **real IPC cost**
(the icache becomes 1-cycle latency) — a poor trade. The free, byte-identical wins (the AMO-wstrb
wall) are **exhausted**; every remaining 13.8–14.6 front needs genuine pipelining (front-end =
icache/imem, commit = plain-store pre-translate, vector = VRF writeback), each with its own IPC
cost. Below 13.8 needs the fronts cut **together** (the campaign's "flip multiple fronts at once"),
then deeper still (imem MMU ~5 ns, dmem MMU, decode/rename, vector) for the 7.5 ns goal — the full
multi-session deep-pipeline campaign. The icache scaffold was reverted (not worth flipping alone);
rebuild it as part of a coordinated front-end+commit+vector flip when that effort is undertaken.

### 2.2 ✅ FETCH_REG — the front-end cut, done CLEANER than icache sync-read (the FB *is* the IF/ID reg)
The icache sync-read (§3) was the wrong tool. The fetch engine **already** has the IF/ID register:
the **fetch buffer (FB)**. The 14.565 cone stays combinational only because of the **S17 bypass /
S17.2 fall-through** — when the FB is empty (the common post-redirect/post-miss case) decode reads the
**live** fetch (`if_instr_q = fb_count!=0 ? fb_instr[fb_head] : fetched_instr`, and slot-1
`if_instr_q1 … : s1_instr`), so `pc_q → imem_mmu → icache → cexp → decode → rename` runs in one cycle.
The `--dump-timing` trace confirms the worst path goes through the **slot-1 bypass arm**
`icache_rdata → u_cexp1 → s1_instr → u_dec2 → rename_fire → …` — which is why the §1.25 "remove the
bypass" experiment (−0.2 ns only) **missed it**: it dropped the *valid* (`if_v_q`) but not the mux's
live arm, so the combinational `s1_instr → u_dec2` path survived.

**`const FETCH_REG` (`heliodor_core.veryl:1218`)** structurally removes the bypass/fall-through *arms*
(`if FETCH_REG ? fb_*[fb_head{,_p1}] : <existing S17 mux>` — const-folds: at 0 the bypass mux is
unchanged = byte-identical, at 1 decode/rename read **only** the registered FB head). No icache change,
no block-fetch redesign — the fetch FSM (pc_q advance, combinational icache read for RVC length /
prediction) is **untouched**; the FB it already pushes into becomes the genuine F|D stage boundary.

**MEASURED (flip = 1):** CP **14.565 → 14.130 ns** (= the icache-sync-read number, achieved without
touching the icache), endpoint moves to `head → n_inflight[5]` (commit-store) / `head → vrf`
(vector). Gate: default **252/0** (litmus N=2 incl), **N1 Linux boot 4/4** — the flip is functionally
CLEAN on the first try (no straddle/redirect/slot-1 corner, because the FB already handled the
registered path; the bypass was pure latency optimization). Committed **DEAD (=0)**, byte-identical,
as the validated front-end stage — to be flipped in the coordinated multi-front flip, NOT alone
(−0.435 ns alone is the "poor trade" §2.1 warned about).

### 2.3 🔑 The binding front after FETCH_REG = the VECTOR datapath (vrf), NOT the commit-store (MEASURED)
With the front end cut, the wall is two fronts:
- `head → n_inflight[*]` **14.130** (4 paths) = the plain-store **commit-time MMU translate**
  (`commit_store_fire → dmem_vaddr → u_dmem_mmu TLB → u_pmp PMP → rob_commit_ack → n_inflight`).
- `head → vrf[*]` **13.880** (**500+ paths — the dominant front**) = the **VU datapath**
  `head → u_vu.h_vd (vector dest) → u_vrf.vrf read (old vd) → [vector compute ~8.7 ns] →
  i_vdold_data → vrf write`. **NOT the commit-store cone** (an earlier trace misread path #5's
  `commit_store_fire` arm; re-tracing under a crude P3 confirmed the vrf worst path is the VU
  compute→writeback, untouched by the commit-store cut).

**MEASURED — the commit-store P3 is only −0.25 ns, capped by vrf.** A crude `STORE_PRETRANSLATE` flip
(c_pretx_fast → drain the registered `c_store_pa`, gate `store_drive_mmu` / `commit_store_sfault` /
`sb_pa` / `sb_vm_ok`) on top of FETCH_REG cut `n_inflight` 14.130 → gone, **CP 14.130 → 13.880** — and
vrf stayed 13.880. So the commit-store front is a 4-path adjunct worth **−0.25 ns**, exactly the §4.1
"diminishing / capped" conclusion (`cp_commit_store_pretranslate_plan.md §4.1`); it also breaks boot
(forced-slow path) and was reverted (not committed). **The binding front is the VU datapath.**

**▶️ DIRECTION CHANGE (2026-06-30, user: "optimise for the FINAL structure, not short-term CP" → agreed).**
The vrf front is the 500+-path dominant synth front (top-500 are ALL vrf), BUT it is the **VU
side-unit's own writeback** — cutting it lowers the synth number without advancing the **scalar core
structure** (depth / keystone). Picking it because it is the binding synth front is exactly the
CP-driven mole-whacking to avoid. The vrf (and commit-store) cuts ARE needed eventually (the VU can't
cap CP at 13.880 for the ~7.5 ns goal), but they are **mechanical front-pipelining, post-keystone**,
not foundational.

**The foundational direction is the KEYSTONE (Phase A): latency-speculative wakeup + replay —
decoupling select from execute.** Today the scalar core fuses issue=execute=broadcast=wakeup into one
cycle ("Stage IE"); splitting it is the only way to a 10+-stage scalar pipe, "everything depends on
it" (`deep_pipeline_sram_plan.md` Sequencing — Phase A FIRST), and it is ~80 % of the campaign
difficulty (replay + SMP). It is **masked** below the vrf/commit-store wall, so it shows **no
short-term CP** — which is fine under "not chasing short-term CP." `speculative_wakeup_design.md §1.1`
says to revisit Phase A *after* the front end is pipelined — FETCH_REG did that, so **now** is the
time. **Keep FETCH_REG** (a genuine front-end stage + a good de-risking warm-up). To avoid building
the keystone "blind", use **throwaway FF-insertion** of the vrf/commit-store fronts to expose the
keystone floor for a measurement *target* only (do not commit the side-unit cuts).

**Next = start the Phase A keystone RTL** (read `speculative_wakeup_design.md`; seed = the
`lsu-phase1-wip` 2-stage load + LSR; mind §1.0b's CDB-register writeback-arbitration conflict). The
vrf / commit-store cuts are deferred to post-keystone mechanical front-pipelining.

**🔧 REVISED (2026-06-30, after measuring the keystone floor — `speculative_wakeup_design.md §1.1c`
+ `deep_pipeline_sram_plan.md` "The keystone (REVISED)").** Exposing the keystone floor (FETCH_REG=1
+ read past the wall) measured `rs1_rdy` = **12.920**, sourced from `head` = the **scheduler
select→wakeup loop** (two serial argmin trees), NOT the execute/CDB cone (< 11.74). So "register the
CDB" (the literal E1 above) is the EXECUTE half — a real, foundational stage boundary, but **not the
binding stage** and CP-neutral today. The keystone is re-scoped into **A-EXE** (execute staging — the
E1/E2 work here), **A-SCHED** (scheduler-logic pipelining — the binding ~12.9 ns stage, PROMOTED from
a footnote), **A-LOOP** (latency-speculative wakeup + replay). **Build A-EXE first for the STRUCTURE
(not a CP number); A-SCHED is the gate to ~7.5 ns.** Full revised plan + FINAL stage list in
`deep_pipeline_sram_plan.md`.

## 3. The icache sync-read scaffold (A) — methodology (SUPERSEDED by §2.2 — keep for the SRAM phase)

Mirror the proven dcache-sync-read / MEM_PIPE pattern (`DCACHE_SYNC_READ`-style):
- `param ICACHE_SYNC_READ: bit = 0` (DEAD = today's combinational read).
- When 1: register the icache `tag`/`data`/`hit`/`rdata` outputs; the index is presented at cycle N,
  the read result is valid at N+1. Decode (`cexp`/`u_dec`) reads the **registered** `icache_rdata`,
  so `pc → imem → icache-read` ends at the icache output register; `reg → cexp → decode → rename →
  allocate` is the next stage.
- DEAD (=0): outputs fall through combinationally = byte-identical (N1 boot-cy match).
- **The flip is NOT byte-identical** — the icache becomes 1-cycle latency, adding a front-end
  stage. This is the campaign's **first real IPC cost** (+1 branch-mispredict penalty, the FB
  refill timing). Measure boot-cy / CoreMark / Dhrystone vs the ~10–15 % budget.

Corners (the flip): straddle/cross-line fetch (`straddle_q`, two-halfword instructions spanning a
cache line — `icache_rdata_next` window), the FB push/pop timing (the FB now buffers a 1-cycle-later
fetch), branch-redirect → fetch restart (+1 bubble), and the dual-issue slot-1 (`s1_instr`,
`if_*_q1`). Full gate ladder (default · backend-validate · **ACT4** · litmus N2/N4 · N2/N4 SMP boot ·
Verilator) at the flip — the front end touches everything.

## 4. Anchors
- `core.veryl:1218-1223` if_*_q FB bypass (slot-0), `:1244` if_*_q1 (slot-1, `s1_instr`).
- `core.veryl:600` icache_rdata, `:723/739/743` straddle window, `u_icache` instance.
- `mmu.veryl:318-360` imem MMU V=1 two-stage TLB (already clz-tree-ized — not a linear-scan win).
- `speculative_wakeup_design.md §1.1` (the keystone-premise correction: rs1_rdy = the allocate path).
- `deep_pipeline_sram_plan.md` (Phase C/D: caches sync-read; SRAM ⊂ pipelining).

## 5. ▶️ NEXT SESSION (2026-07-03) — Option 1 selected: Phase D front-end, after the dcache scaffold + dense-band confirmation

Phase C dcache `DCACHE_SYNC_READ` DEAD scaffold is committed (`d93c2e3`, `cp_dcache_sync_read_plan.md
§10.2`). Its FF-insertion flip **empirically confirmed the dense-band** (cut the dcache off
`n_inflight`, but −0.13 ns only — the commit-store MMU-fault/PMP-cbo-W residual sits right under).
At the strategic fork (front-end / make-functional / A-SCHED / reassess), the **user chose Option 1
= Phase D front-end** (the biggest unbuilt structural stage, lower-risk, the sync-read continuation).

**Concrete first step (§2 cut order (A), §3 methodology):** rebuild the **`ICACHE_SYNC_READ` DEAD
scaffold** — it was built once and reverted (§2.1: "rebuild as part of the coordinated flip"), so it
is NOT in the tree today. Mirror the just-committed **`DCACHE_SYNC_READ` (`d93c2e3`) template
exactly**:
- Rename the icache lookup outputs (`tag`/`hit_*`/`icache_rdata` + the straddle/next window) to
  `*_raw`, add `*_q` registers written ONLY under `if ICACHE_SYNC_READ` (reset-only → DCE at 0 =
  synth-CP-neutral, the const-gate methodology rule), and `*_eff = ICACHE_SYNC_READ ? *_q : *_raw`
  keeping the ORIGINAL names so decode (`u_cexp`/`u_dec`) routes to `*_eff` untouched.
- **DEAD (=0) verify (mandatory 4 gates, as dcache):** default 252/0 · synth 14.565 unchanged (regs
  DCE) · N1 boot cy-EXACT (7.1 `01210060` / 7.1V `013cc5c0`) · **ACT4 696/696**.
- **FF-insertion flip measure** (FETCH_REG=1 + ICACHE_SYNC_READ=1, throwaway/revert): confirm the
  icache read leaves the front-end fetch-half; expect the imem-MMU V=1 TLB (~5 ns) to become the
  fetch-half floor (→ step B).
- **Then (B) imem-MMU translate stage (F1)** — register `o_imem_paddr` (the ~5 ns V=1 two-stage TLB,
  the biggest single front-end chunk). Pure pipeline reg (TLB is flops, not SRAM). This is the F1
  stage of the FINAL diagram.

**Corners at the eventual functional flip** (§3): straddle/cross-line fetch (`straddle_q`,
`icache_rdata_next`), FB push/pop timing (icache now 1-cy later), branch-redirect fetch restart
(+1 bubble), dual-issue slot-1 (`s1_instr`/`if_*_q1`). Full ladder + IPC at the bundle flip; the
DEAD scaffold + measure is the per-session deliverable. Lower-risk than dcache (in-order front-end,
no SMP atomicity). Anchors: §4 above + `d93c2e3` as the live template.

## 6. ✅ DONE (2026-07-03) — `ICACHE_SYNC_READ` DEAD scaffold rebuilt + flip-measured; NEXT = step B (imem-MMU stage)

Rebuilt the `ICACHE_SYNC_READ` DEAD scaffold (`icache.veryl`), mirroring the `DCACHE_SYNC_READ`
(`d93c2e3`) template exactly. Registered the icache **read result** — the four CPU-side outputs
`o_rdata` / `o_rdata_next` / `o_rdata_next_valid` / `o_stall` — via rename-to-`*_raw` (the live
combinational read) + a reset-only `*_q` written only `if ICACHE_SYNC_READ` + the port redefined
`assign o_rdata = ICACHE_SYNC_READ ? o_rdata_q : o_rdata_raw` (so the core routes to the effective
value untouched — `icache_rdata`/`_next`/`_stall` in `heliodor_core.veryl` need no edit). Only
internal consumer of a registered output is `straddled_4byte` (reads the `o_rdata` port = eff).

**DEAD (=0) — all 4 gates green (byte-identical + synth-CP-neutral):**
- default **252/0** (litmus N2 `cy=0022a330`, matches the `d93c2e3` bundle).
- synth **14.565 ns unchanged**, **159948 FFs unchanged** vs baseline (the 66 new regs — o_rdata 32 +
  o_rdata_next 32 + valid 1 + stall 1 — fully DCE'd; the write-fold const-gate methodology holds;
  +68 pass-through mux gates only, off the critical path).
- N1 boot cy-EXACT: 7.1 `01210060` / 6.6 `013ee8a0` / 7.1V `013cc5c0`.
- **ACT4 696/696** (0 failed).

**FF-insertion flip measure (throwaway, reverted):**
- `ICACHE_SYNC_READ=1` alone (FETCH_REG=0): **14.565 → 14.130**; top-40 endpoints are ALL back-end
  (`head → n_inflight` commit-store 14.13, `head → vrf` 13.88) — **zero pc_q front-end endpoints**.
  So registering the icache read drops the whole front end (pc_q → rs1_rdy) from being the global CP
  (14.565) to BELOW the 13.88 vrf/back-end wall. Reproduces §2.1's 14.130 and confirms the icache
  read leaves the critical path.
- `FETCH_REG=1 + ICACHE_SYNC_READ=1`: still **14.130** (back-end capped), and the front-end is not
  in the top **80** endpoints — the fetch path is now deep below the wall. **Confirmed: the icache
  read leaves the front-end fetch-half.** (The fetch-half absolute floor is ~7 ns, masked by the
  13.88+ vrf/commit-store back-end wall — it cannot surface as a top endpoint until the whole
  back-end is cut below ~7 ns, i.e. the full campaign; so it is measured indirectly below.)

**Fetch-half decomposition (from the DEAD=0 `--dump-timing` of the 14.565 `pc_q → rs1_rdy` path —
which IS the whole front end when nothing is registered):**

| segment | range (ns) | length | component |
|---|---|---|---|
| **imem-MMU V=1 two-stage TLB** | 0.00 → 5.36 | **5.36** | `u_imem_mmu.u_mmu.v1_vpn→v1_level→v1_valid→v1_u→i_sum→v1_match→v1_hit→imem_paddr` |
| icache RAM read | 5.36 → 5.885 | 0.525 | `RAM Q` (the `data_*` array IS inferred SRAM — sync-read-ready) |
| icache tag/hit mux → cexp in | 5.885 → ~7.0 | ~1.1 | `u_icache.tag` compare + 4-way hit mux |
| cexp (RVC expand) | 7.625 → 9.305 | ~1.68 | `u_cexp` |
| decode | 9.305 → 11.355 | ~2.05 | `u_dec` |
| rename / IQ allocate | 11.355 → 14.565 | ~3.21 | `iq_alloc_rdy → rename_fire → prf_ready → rs1_rdy` |

The `ICACHE_SYNC_READ` register sits at the icache hit-mux output (~7 ns), splitting 14.565 into a
**fetch-half ~7 ns (imem-MMU 5.36 dominant, 76%)** and a **decode-half ~7.5 ns (rename/allocate 3.21
+ decode 2.05 + cexp 1.68 dominant)** — roughly balanced (§2's 7.6/7.0 estimate was close; the
icache RAM read is much cheaper than the 2.6 ns estimate because it is inferred SRAM). **§5's
prediction is confirmed: the imem-MMU V=1 TLB (5.36 ns) is the fetch-half floor** — the single
biggest contiguous chunk of the fetch path, dwarfing the 0.525 ns icache RAM read.

**▶️ NEXT SESSION — step (B): the imem-MMU translate stage (F1).** Register `o_imem_paddr` (the
5.36 ns V=1 two-stage TLB — the biggest single front-end chunk, and now the fetch-half floor). Pure
pipeline reg (the TLB is flops, not SRAM — a rename-to-`*_raw` + reset-only `*_q` + `assign … = ? q
: raw` param scaffold in `mmu.veryl` on the `o_paddr`/`o_valid`/`o_fault`/`o_acc_fault` outputs,
DCE'd at 0, same const-gate methodology). This is the F1 stage of the FINAL diagram; it splits the
fetch-half (imem translate | icache access). Note for after B: the **decode-half (~7.5 ns) is the
co-equal front-end pole** — its floor is the rename/IQ-allocate cone (3.21 ns, `iq_alloc_rdy →
rename_fire → prf_ready → rs1_rdy`), so a decode/rename stage is the third front-end lever. Anchors:
`mmu.veryl:318-360` (V=1 TLB), §4, `d93c2e3` + this session's icache scaffold as the live templates.

## 7. ✅ DONE (2026-07-03) — step B `IMEM_MMU_STAGE` DEAD scaffold; imem translate = F1; NEXT = the decode/rename half

Built the `IMEM_MMU_STAGE` DEAD scaffold in **`imem_mmu.veryl`** (NOT the shared `mmu.veryl` — the
i-side has its own wrapper module `imem_mmu` around `u_mmu`, so registering here touches ONLY the
fetch path, never the dmem MMU / commit-store front). Registered the **translation result** — the 4
output ports `o_paddr` / `o_valid` / `o_fault` / `o_acc_fault` — via rename-to-`*_raw` + reset-only
`*_q` (`if IMEM_MMU_STAGE` write-fold) + `assign o_paddr = IMEM_MMU_STAGE ? o_paddr_q : o_paddr_raw`.
The walk **handshake** (`o_busy`, the PTW port, Svadu A-bit write-back) and the V=1 **htval**
side-info (`o_gstage_fault` / `o_fault_gpa`) stay LIVE — only the 4 result outputs are staged. None
of the 4 has an internal reader (the PMP / PMA checks use the separate `fetch_pa` recompute, not
`o_paddr`), so the cut is clean.

**DEAD (=0) — all 4 gates green (byte-identical + synth-CP-neutral):**
- default **252/0** (litmus N2 `cy=0022a330`).
- synth **14.565 ns unchanged**, **159948 FFs unchanged** vs baseline (the 67 new regs — paddr 64 +
  valid/fault/acc 1 each — fully DCE'd; +132 pass-through mux gates only, off CP).
- N1 boot cy-EXACT: 7.1 `01210060` / 7.1V `013cc5c0` / 6.6 `013ee8a0`.
- **ACT4 696/696**.

**FLIP measure (throwaway, reverted) — a MASKED, pure-structural stage (as the campaign expects):**
- Full-core `ICACHE_SYNC_READ=1 + IMEM_MMU_STAGE=1`: global CP **14.130 ns unchanged** (no
  regression); FFs 160081 (= 159948 + icache o_rdata_q 66 + imem o_paddr_q 67, both scaffolds' regs
  live at flip). The fetch stages (imem 5.36 ns, icache ~1 ns) are **> 4 ns below the back-end wall**
  — a `--timing-paths 40000` dump bottoms out at **10.950 ns** (40 000 endpoints all in 10.95–14.13,
  the vrf/commit/prf/tag back-end), so the fetch endpoints (5–7 ns) are hopelessly masked and produce
  ZERO measurable global CP. Same structure-not-CP situation as the dcache (−0.13) and vrf (−0.04)
  DEAD commits.
- **Standalone `imem_mmu` synth (unmasked)**: CP **7.248 ns**, and at `IMEM_MMU_STAGE=1` the worst
  endpoint moves from the comb output `v1_vpn → o_acc_fault[0]` to the **register** `v1_vpn →
  o_acc_fault_q[0]` (FFs 4663 → 4730, +67) — direct proof the register **captures the translate
  result** off the fetch path. (In the full core the fetch DATA path was 5.36 ns to `o_paddr`; the
  isolated module's deepest of the 4 outputs is `o_acc_fault` at 7.248 ns = paddr + PMP-X +
  pma_hole — registering all 4 together cuts the deepest too.)

**Where the register lands (from step A's DEAD=0 `--dump-timing`, §6):** the imem-MMU V=1 two-stage
TLB cone is `pc_q → u_mmu.v1_vpn → … → v1_hit → mmu_paddr → o_imem_paddr = 5.36 ns`. `IMEM_MMU_STAGE`
puts the flop exactly on that 5.36 ns output, so the fetch-half splits into **imem translate (F1,
5.36 ns) | icache access (~1 ns, the RAM read is inferred SRAM, cheap)** — the biggest single
front-end chunk is now its own stage.

**▶️ NEXT SESSION — the decode/rename half (F2/F3, the co-equal front-end pole).** After B, the two
front-end poles are the **imem stage (5.36 ns, F1)** and the **decode-half (~7.5 ns)** — now the
TALLER pole. Its floor is the **rename/IQ-allocate cone (3.21 ns, `iq_alloc_rdy → rename_fire →
prf_ready → rs1_rdy`)** on top of decode (2.05) + cexp (1.68). The next lever is a decode|rename
stage boundary: register the decoded-op / free-list-pop output so `cexp+decode` (F2) and
`rename+IQ-allocate` (F3) are separate cycles. This is trickier than a cache/MMU output reg (rename
allocates the free-list + writes the RAT + IQ — the allocate is stateful, not a pure passthrough), so
it likely needs the same DEAD-scaffold discipline plus dispatch-timing corners at the flip. Note the
imem stage (5.36) is still the deepest fetch stage — a later step would split the V=1 two-stage TLB
itself (G-stage | VS-stage) if the front-end floor must go below ~5 ns for the 7.5 ns goal. Anchors:
`iq_int.veryl` (rename/allocate), `u_dec`/`u_cexp` in `heliodor_core.veryl`, §4, `8344d0a`
(ICACHE_SYNC_READ) + this session's `IMEM_MMU_STAGE` as the live templates.

## 8. ✅ DONE (2026-07-03) — step C `DECODE_REG` (D|R boundary); Phase D front-end STRUCTURALLY COMPLETE

Built the `DECODE_REG` DEAD scaffold in `heliodor_core.veryl` (the R-stage input register = the
last unbuilt front-end boundary). MEASURED clarification first: the FB holds the **post-cexp**
instruction (`fetched_instr = c_expanded_w`, pushed into `fb_instr`), so `u_cexp` sits in F2 (before
the FB), and the FB (FETCH_REG) is the F|D reg. That leaves `if_instr_q → u_dec → dec_op →
iq_alloc_rdy → rename_fire → prf_ready → rs1_rdy` = **decode (2.05) + rename/allocate (3.21) = ~5.3 ns
fused in one cycle**, with NO register between D and R. `DECODE_REG` registers the **decode output**
`dec_op` / `dec_op2` (the `DecodedOp` structs) — the minimal cut: those two structs ARE the D|R
boundary (`dec_op` feeds `iq_alloc_rdy`/rename/ROB-alloc); the fetch metadata (`if_pc_q` / `if_v_q` /
`if_ifault_q` / `if_iacc_q`) is NOT on the `rs1_rdy` critical path (it is rob-alloc payload) so it
stays live — byte-identical at 0 either way. Pattern = EX_PIPE's `alu_cdb_q` (`var *_q: DecodedOp` +
`let dec_op: DecodedOp = if DECODE_REG ? dec_op_q : dec_op_raw`, struct `'0` reset + whole-struct
mux, both proven by the `alu_cdb_eff` precedent); the `*_raw` is the live `u_dec` output, the eff
`let`s keep the ORIGINAL names `dec_op`/`dec_op2` so every rename/allocate consumer routes untouched.

**DEAD (=0) — all 4 gates green:** default **252/0** (litmus N2 `cy=0022a330`); synth **14.565 ns +
159948 FFs unchanged** (both `dec_op*_q` structs DCE'd; +164 mux gates only); N1 boot cy-EXACT (7.1
`01210060` / 7.1V `013cc5c0` / 6.6 `013ee8a0`); **ACT4 696/696**.

**FLIP measure (throwaway, reverted) — the cleanest of the three, because `dec_op_q` lands in the
visible wall band:** `DECODE_REG=1` (FETCH_REG=0): global CP **14.130** (front-end front cut). The
**`rs1_rdy[0]` source flips from `pc_q` (14.565) to `head` (12.920)** — direct proof the decode→rename
path is cut off `rs1_rdy`, exposing the **scheduler select→wakeup loop (12.920, the keystone A-SCHED
front)** underneath as the new `rs1_rdy` floor (matches the A-LOOP measurements). The new register
shows as `pc_q → dec_op2_q` at **~11.9 ns** (118 levels) = the fetch+decode cone now terminating at
the D|R flop. So `DECODE_REG` splits the ~5.3 ns decode+rename into **decode (2.05, F-side) | rename
(3.21, R-side)**.

**🏁 Phase D front-end structurally COMPLETE.** All four FINAL front-end stage boundaries are now
DEAD-scaffolded and 4-gate-validated: **F1** imem translate (`IMEM_MMU_STAGE`, 5.36) | **F2** icache
read (`ICACHE_SYNC_READ`, ~1.5) | **D** cexp+decode / F|D reg (`FETCH_REG`, cexp ~2 + decode 2.05) |
**R** rename+allocate / D|R reg (`DECODE_REG`, 3.21). **Every front-end stage is ≤ 5.36 ns — already
below the ~7.5 ns campaign target**, so the front end needs NO further splitting for 7.5 ns (the imem
5.36 is the deepest and it is under budget; a G|VS TLB split is unnecessary unless the target drops).

**▶️ The binding constraint is no longer the front end — it is the back-end wall + the keystone.**
With the front end cut, the exposed fronts are the **back-end wall** (`head → n_inflight` commit-store
14.13, `head → vrf` 13.88 — both already DEAD-scaffolded: STORE_PRETRANSLATE/trap-deferral, VALU_PIPE,
DCACHE_SYNC_READ) and the **keystone scheduler loop** (`head → rs1_rdy` 12.920, A-SCHED lowers it to
9.52; A-LOOP/A1.1 done). NEXT is a campaign-level decision (a phase transition, like the dcache
dense-band fork): (a) advance the **keystone** (A-SCHED binding-stage / A-EXE regread-execute
staging — the IS/RR/EX/WB loop, the actual gate to 7.5 ns), or (b) attempt the **coordinated bundle
flip** now that front-end + commit-store + vrf + dcache + keystone scaffolds all exist, or (c) the
deferred commit/retire (Phase E). Anchors: `deep_pipeline_sram_plan.md` (FINAL diagram + keystone),
`cp_a_loop_plan.md` / `cp_a_sched_scheduler_pipeline_plan.md` (keystone), `8344d0a`/`31b9e89` +
this `DECODE_REG` as the front-end live templates.
