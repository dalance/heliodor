# CP MMU→dcache pipeline plan — unified PA-latch (M-stage split)

The next front below the FR's 20.395 ns floor. synth (all 3 FR params on) endpoint:
`head[0] → n_inflight[5]`, 206 levels, 20.395 ns. The path is the **VU memory
address → shared MMU → dcache → dcache_stall → rob_commit_ack → free-list
n_inflight** megacone (issue↔commit dmem-port sharing). Goal: register the
translated PA after MMU+PMP so the dcache access (and `dcache_stall`) happens the
NEXT cycle, for ALL memory paths — cutting CP to ~11.5 ns (the
`head→VU→MMU→PMP→PA-latch` front).

User-chosen approach (2026-06-28): "共有 MMU→dcache をパイプライン化 (PA latch,
全メモリ)" — the biggest structural lever, biggest IPC cost. Companion:
`cp_front_pipeline_plan.md` (the FR, committed `48b147a`), `cp_pipelining_strategy.md`.

---

## 1. The critical path (synth, 20.395 ns)

| range | stage | ~ns |
|-------|-------|-----|
| 0→4.7 | `head → u_vu.fifo → u_prf (scalar base) → velem64/m_base` (VU vector element addr) | 4.7 |
| 5→9 | `core_dmem_vaddr → u_dmem_mmu` TLB translate | 4 |
| 9→11.5 | `u_pmp_amo_w` PMP | 2.5 |
| 11.5→16.5 | dcache index → RAM(tag) → f_tag/victim/fill/state | 5 |
| 16.5→18.3 | dcache state → `dcache_stall` → `c_is_store` store-gate → `rob_commit_ack` → commit_trap/redirect | 2 |
| 18.3→20.4 | `rob_commit_ack → do_push2 → n_inflight` free-list counter | 2 |

The FR cut the scalar issue-select cone; the VU has its own FIFO and does NOT go
through the FR, so the VU memory address generation + the shared MMU→dcache is now
the worst-case issue→execute front, and it terminates in the commit-gate
(`rob_commit_ack` waits on `dcache_stall` for a non-buffer-eligible store at the
head — the issue↔commit shared dmem port). Registering the PA breaks this between
the MMU and the dcache.

## 2. The structure today (map — file:line)

- **VA mux** (`heliodor_core.veryl:5207`): `core_dmem_vaddr = if vu_mem_active ?
  vu_mem_vaddr : if store_drive ? c_store_addr : if mmu_walk_inflight ?
  walk_vaddr_q : agu_addr_iss`. Companions: `core_dmem_wen` (5209), `core_dmem_ren`
  (5369), `core_dmem_wdata` (5208), `core_dmem_wstrb` (5370), `core_dmem_is_amo`
  (5217).
- **MMU** `u_dmem_mmu` (`heliodor_core.veryl:6106`): `i_vaddr: core_dmem_vaddr`
  (6111) → **`o_dmem_addr: dmu_dmem_addr`** (6117, PA; declared 668) +
  `dmu_dmem_ren` (6124), `dmu_dmem_wen` (6123), `dmu_dmem_wstrb` (6125),
  `dmu_dmem_wdata` (6118). Faults `dmem_mmu_fault`/`_acc_fault`/`_gstage`/`_gpa`,
  `dmem_mmu_idle` (6160), `dmem_mmu_busy` (6151), `dmu_pbmt_unc` (6149).
  PMP inside: `acc_deny` (`dmem_mmu.veryl:266`) gates `o_dmem_ren`/`o_dmem_wen`.
- **dcache** `u_dcache` (`heliodor_core.veryl:6374`): **`i_addr` mux (6383)** =
  `if lsr_drive ? lsr_paddr_q : if replay_drive ? replay_addr : dmu_dmem_addr`;
  `i_ren` (6398) = `(dmu_dmem_ren && !lsr_capture) || replay_drive || lsr_drive`;
  `i_wen: dc_i_wen` (6389, def 6216); `i_uncached` (6399); store-drain write port
  `i_saddr`/`i_swen` (6412/6413, line-aligned from sb head, separate port);
  `o_stall: dcache_stall` (6426); read data `dcache_rdata` (6423).
- **LSR (plain-load 2-stage, the template)**: regs `lsr_v_q`/`lsr_paddr_q`/
  `lsr_vaddr_q`/meta (`heliodor_core.veryl:1525-1539`); Stage-A `lsr_capture`
  (6308) latches `lsr_paddr_q = dmu_dmem_addr` (6703), suppresses Stage-A dcache
  read via `!lsr_capture` in i_ren (6398); Stage-B `lsr_drive` (6314) selects
  `lsr_paddr_q` onto i_addr + forces i_ren; completion `lsr_complete` (6678).
- **Slow-store commit**: `commit_store_fire` (5010), `store_drive` (5184) =
  `commit_store_fire && !load_walk_busy && !fast_store`; PA via the default arm of
  i_addr (`dmu_dmem_addr`); write enable `dc_i_wen` (6216). `fast_store` (5071)
  uses the store buffer (separate drain port). **`rob_commit_ack` (3217-3222)**:
  the dcache-dependent term (3219) `!(c_is_store && !sb_elig && (dcache_stall ||
  …))` — the slow store at the head waits on `dcache_stall`. → free-list
  `fl_push_en = rob_commit_ack && …` (3564) → `n_inflight`.
- **AMO**: read at execute `dc_amo_read` (5380) → `i_amo_read` (6403); watch latch
  `amo_watch_pa_q = dmu_dmem_addr` (4971) on `amo_exec_capture` (4895); write at
  commit `dc_wen_excl` (6227). dcache-internal pin `pin_line_q` (`dcache.veryl:455`).
- **VU port**: `vu_mem_active` highest-priority VA arm (5207); vector_unit inst
  (2977-2989): `o_mem_vaddr: vu_mem_vaddr`, `i_mem_rdata: dcache_rdata` (2987, VU
  read result straight off dcache), `i_mem_ready: vu_mem_ready` (2986);
  `vu_mem_ready = !dcache_stall && !dmem_mmu_busy` (6488). VU element addr
  `m_vaddr` (`vector_unit.veryl:1905`, `o_mem_vaddr` 2451), mem FSM `mem_state`
  (830).
- **Commit-gate**: `dcache_stall` (614, driven 6426) → `rob_commit_ack` term 3219
  → ROB `i_commit_ack` (3441) + free-list `fl_push_en` (3564) → `n_inflight`
  (`free_list.veryl:66`).

## 3. The design — register the PA boundary (`dmu_dmem_addr`) for all paths

The plain-load LSR already proves the split works (Stage A: AGU→MMU→latch PA;
Stage B: dcache read). Generalize it: a **dmem M-stage register** captures the MMU
output the cycle a memory op translates, and the dcache accesses it the next cycle.
Three remaining single-cycle consumers must move to the M-stage: the VU port, the
slow-store commit write, the AMO read+write. (Plain loads already use the LSR; the
M-stage either subsumes the LSR or coexists with it — see §5.)

Param-gate it: `param MEM_PIPE: bit = 0` (cycle-exact dead, like SCHED_WAKEUP/
FRONT_PIPE/VFP_PIPE). At 0, the dcache reads `dmu_dmem_addr` combinationally
(today). At 1, it reads the registered M-stage PA. Build dead → validate
byte-identical → flip + corner-debug + full gate ladder + re-synth.

### M-stage register contents (capture from the MMU output each translate cycle)
`m_pa_q` (= dmu_dmem_addr), `m_ren_q` (dmu_dmem_ren), `m_wen_q` (dc_i_wen-pre),
`m_wstrb_q`/`m_wstrb_hi_q`, `m_wdata_q`, `m_unc_q` (dc_uncached), `m_amo_read_q`,
`m_wen_excl_q`, the fault meta (`m_fault_pg_q`/`m_fault_acc_q`/`m_gstage_q`/
`m_gpa_q`), and the requester tag (which path: VU / store / AMO / load; rob_idx;
dest). The dcache `i_addr`/`i_ren`/`i_wen`/`i_uncached`/`i_wdata`/`i_wstrb` mux
gains an `if MEM_PIPE ? m_*_q : <today>` arm.

### Handshakes that must absorb the extra stage
1. **VU**: `vu_mem_ready` must reflect the 2-cycle access (translate, then dcache).
   The VU mem FSM (`mem_state`) holds the element one more cycle; `i_mem_rdata`
   reads the dcache the cycle AFTER translate. +1 cycle / vector element access.
2. **Slow-store commit (HIGH RISK — SMP atomicity)**: the store translates (N),
   latches PA (N→N+1), writes dcache (N+1). `rob_commit_ack` must NOT retire the
   store until its dcache write actually lands (else the +1-cycle-commit
   double-write / late-poison breaks SMP atomicity — see strategy §3.D, the litmus
   N=2 amoadd wedge). The retire must gate on the M-stage write completing, the
   way `lsr_complete` gates the load. AMO poison/watch (`amo_watch_pa_q`) and
   LR/SC reservation timing shift by +1 and must stay coherent. **This is the
   corner-debug bulk; validate with litmus N2/N4 + SMP boot every step.**
3. **AMO**: read (execute) and write (commit) each gain a cycle. `amo_watch_pa_q`
   latches from the M-stage PA; the pin/poison/coherence-probe timing shifts +1.
4. **Load (LSR)**: already 2-stage. Either fold the LSR into the M-stage (one
   unified mem-stage) or keep the LSR and add the M-stage only for VU/store/AMO.
   Folding is cleaner long-term but riskier; coexisting is the safer first cut.

### Commit-gate decoupling falls out
With MEM_PIPE, `dcache_stall` in cycle N+1 reflects the M-stage access translated
in N. `rob_commit_ack` reading `dcache_stall` is then one stage removed from the
VU/load address generation — the synth path VU-addr→…→dcache_stall→rob_commit_ack
is broken at the M-stage register. (Direction-C tried to cut the commit SIDE and
got ≤1.3ns because the issue→execute was the real floor; MEM_PIPE cuts the
issue→execute, which is the right end.)

## 4. Expected CP / IPC

- **CP**: front `head→VU velem→MMU→PMP→PA-latch` ≈ 11.5 ns; back
  `dcache→dcache_stall→commit→n_inflight` ≈ 9 ns ⇒ CP ≈ **11.5 ns** (−43% from
  20.4). The VU velem (4.7) is then the longest issue front; a later VU-addr
  pipeline (the parked Option A) could push the front toward the scalar
  AGU→MMU→PMP ≈ 7.5 ns.
- **IPC** (net vs CP, per the committed program): all memory ops +1 cycle — load-use
  +1 MORE (FR already +1 ⇒ total load-use 3→4 vs the pre-campaign baseline), store
  +1, AMO +1/+1, vector element +1. Measure boot cy + CoreMark/Dhrystone at flip;
  report net. Larger IPC hit than the FR — the user accepted it for the −43% CP.

## 5. Staged increments (each green through its gate ladder)

**M1 — M-stage register + dcache read-mux, param-gated DEAD (`MEM_PIPE=0`). ✅ DONE.**
Add the regs + the `if MEM_PIPE ? m_*_q : …` arms on the dcache inputs. Capture from
the MMU output each cycle. Gate: build byte-identical + default 251/0 + N1 boot cy
unchanged + synth 20.395 unchanged.

🔑 **Key finding — register the EFFECTIVE (post-gating) execute-path inputs, NOT the
raw MMU outputs.** First cut registered only `dmu_dmem_addr`→i_addr (+ raw ren/wen/
wstrb/wdata/unc/amo). Temp-flip synth: only **20.395→20.215** (−0.18) — the megacone
was NOT cut, because `i_load_next`/`i_ren`/`i_uncached` still carried LIVE head-cone
terms (`dc_load_next`/`dc_uncached`/`lsr_capture` from the live PA byte-offset). The
synth trace showed PMP `acc_deny`→`dmu_dmem_ren`→`dc_uncached`→`dc_load_next`→
`i_ren`→dcache still intact. **Fix: capture the effective terms** (`m_ren_q` =
`dmu_dmem_ren && !lsr_capture`, `m_unc_q` = `dc_uncached && !lsr_capture`, `m_lnext_q`
= `dc_load_next && !dc_uncached && !lsr_capture`), plus the slot-1 hit-only load port
(`m_addr2_q`/`m_ren2_q`/`m_lnext2_q`) and the misaligned-store hi strobe
(`m_wstrbhi_q`). Then at flip the dcache reads PURELY registered values; the LSR/
replay Stage-B drives and commit-side store/AMO terms (the back-half cone) stay live
and OR over the M-stage. Register set = 13 fields (216 FF bits).

🔬 **Temp-flip synth (MEM_PIPE=1, NOT functionally correct — VU/store/AMO handshakes
are M2/M3) = 20.395 → 16.470 ns (−19.3%), 141 levels, new endpoint head[0]→`vrf[63]`.**
The memory megacone IS cut. **But the new floor is ~16.5 ns, NOT the plan's ~11.5** —
the exposed front is an entirely VU-INTERNAL integer datapath: head→`fifo_instr`→
`h_funct6` decode→`h_vs1/h_vs2`→VRF read (`i_vs1_data`)→`bbcast`→`vrf` write. That is
a separate pipelining target (a VU-integer analogue of the VFP_PIPE), not a memory
path. ⇒ §4's 11.5 estimate omitted this VU-integer front; the realistic MEM_PIPE
payoff (with M2/M3 correctness) is ~16.5 ns unless the VU-integer datapath is also
pipelined. Committed DEAD at MEM_PIPE=0 (CP/cy byte-identical).

**M2 — VU 2-cycle handshake under MEM_PIPE. ✅ DONE.** `mem_fetched_q` in
`vector_unit` splits each ACTIVE element into a FETCH (drive vaddr → MMU translate →
the core's M-stage latches the PA) and an ACCESS (the dcache reads the latched PA;
the result lands) cycle — the exact `fp_fetched_q`/VFP_PIPE pattern. `param MEM_PIPE`
passed from the core's `const MEM_PIPE` (one source of truth). The VU drives the same
element for both cycles; the FETCH-cycle dcache re-read of the prior (cached) element
hits (idempotent re-write for stores), so `i_mem_ready` in FETCH = `!dmem_mmu_busy` =
"translate done" → no new port needed. Masked-off elements skip the FETCH (complete
immediately). Dead at MEM_PIPE=0 (`mem_fetched_q` never set → single-cycle = today).

Gates (MEM_PIPE=0): default 251/0, N1 boot 4/4 cy byte-identical (incl. V-boot
012e46d0), synth 20.395 unchanged.

🔬 **Flip-test (temp MEM_PIPE=1): 18/19 vector arch tests PASS — the VU handshake
works.** The 1 failure is `test_arch_vleff`, the ONLY vector test that enables Sv39
paging (it sets a page-boundary fault). The VU FSM is fine; the failure is the **PTW
page-walk interacting with the M-stage**: at MEM_PIPE=1 the walk's PTE reads go
through the dcache via the registered M-stage (+1 cycle), but the MMU walk FSM expects
MEM_PIPE=0 timing → wrong/stale PTE → hang (tohost=0). This is a GENERAL flip blocker
(every TLB-miss walk, so V-boot + all VM code), NOT a VU bug. ⇒ added step **M2.5**.

**M2.5 — PTW walk + M-stage (the vleff blocker). ✅ DONE (option a).** `dmem_mmu`
exposes a CLEAN short-path walk-dcache bundle — `o_ptw_dc_active` (= `vm && (ptw_req
|| ptw_wen)`), `o_ptw_dc_ren`, `o_ptw_dc_addr` (= `ptw_addr`), `o_ptw_dc_wdata` (=
`ptw_wdata`) — with NO TLB-hit/PMP cone (unlike `dmu_dmem_addr`, which muxes
`ptw_paddr`). At MEM_PIPE=1 the core's `dmem_*_m` selectors route the dcache LIVE off
this bundle while `ptw_dc_active` (walk read = plain cached read; A/D write = `dmu_ad_wb`
+ 0xFF strobe), else the M-stage. The multi-cycle walk thus keeps its MEM_PIPE=0 timing
(only the post-translate DATA access is registered), and `m_pa_q` naturally holds
`ptw_paddr` at the walk-complete cycle — aligned with the VU's FETCH/ACCESS so the data
access reads the right PA. Megacone stays cut (ptw_addr is short).

Gates (MEM_PIPE=0): default 251/0, N1 boot 4/4 cy byte-identical, synth 20.375 (-0.02
ns mapping noise from the dead MMU-output fanout on ptw_addr; 206lv/head->n_inflight).

Flip-test (temp MEM_PIPE=1): all 19/19 vector tests PASS (vleff fixed). Full default
suite at flip = 224/251 pass, 27 fail — and the 27 are EXACTLY the scalar store +
AMO/LR-SC + misaligned-store + litmus-N2 tests (sb/sh/sw/sd/st_ld/ld_st/ma_data, all
amo*, lrsc, sw/sd_misaligned/ma_addr, litmus_2hart, zfhmin[FP st_ld]). Cleanly scopes
M3: the slow store writes the registered PA one cycle late but rob_commit_ack retires
it immediately. Loads (LSR) + VU + walks are all correct at flip.

**M3a — slow-store commit 2-cycle retire gate. ✅ DONE.** `store_fetched_q` gives a
slow store (`c_is_store && !sb_elig`, the i_wen path) a translate cycle (M-stage
latches PA+wen) before its dcache write cycle: a new `rob_commit_ack` term
`!(MEM_PIPE && c_is_store && !sb_elig && !store_fetched_q)` holds retire for the
translate cycle. `store_fetched_q` sets when the slow store drives + `!dmem_mmu_busy`,
clears on retire/redirect (so the next store gets its own translate cycle). The write
cycle's dup re-write of the prior store is idempotent (same M-stage tuple). Dead at
MEM_PIPE=0. Gates: default 251/0 (incl litmus N2), N1 boot 4/4 cy byte-identical.
🔬 Flip-test: 224→**235/251** (+11): all plain-store + misaligned + zfhmin tests now
PASS. Remaining 16 = AMO/LR-SC (all amo*, lrsc) + litmus_2hart → M3b.

**M3b — AMO / LR-SC read-at-execute + LIVE commit write. ✅ DONE (dead).** The 16
flip failures (all amo* + lrsc + litmus_2hart) are fixed by TWO sub-fixes:

🔧 **(1) `amo_fetched_q` — AMO/LR 2-cycle read handshake.** A real AMO + LR
(`issue_amo_read`, excludes SC) is HELD at the issue port for a FETCH cycle (drive read
→ MMU translate → M-stage latches PA + amo_read) before its ACCESS cycle (dcache reads
the latched PA → `dcache_rdata` = the AMO value → alu_wrap computes the RMW). `amo_fetch_hold`
suppresses iq_issue_ack + u_alu completion in the fetch cycle; cleared when the AMO stops
driving its read (`!dc_amo_read`: port lost / blocked) so a re-fetch re-latches the right
PA, and on ack/redirect so back-to-back AMOs each re-fetch. Tail-RFO elimination: the held
issue keeps `dc_amo_read` (→ `m_amo_read_q`/`m_ren_q`) asserted through the access cycle, so
the unconditional M-stage capture re-drives the dcache the cycle AFTER the AMO completes — a
spurious tail RFO that RE-ACQUIRES the departed line and masks a remote recall from the watch.
Gated off via `m_amo_tail` (dmem_ren_m) + `amo_fetched_q` (dmem_amord_m).

🔧 **(2) LIVE AMO/SC commit write (`amo_commit_live`) — the §3.D atomicity fix.** 🚨 The
original M3b plan (let M3a's `store_fetched_q` give the AMO commit write a translate cycle)
is WRONG and breaks SMP atomicity: at MEM_PIPE=1 a registered (M-staged) AMO commit write
fires the cycle AFTER it latches, and a remote recall landing on that write cycle still merges
the STALE value — the dcache's `wenl_fires` gates on a LIVE `hit_excl` while the write-enable
is the registered M-stage input, and the two SKEW (chk3 says departed, hit_excl says owned),
so the write lands AND the watch poison only registers the next cycle, too late: the watch is
already cleared, no replay, the increment is LOST. Manifested as the litmus N=2 sense-reversing
barrier wedge — both harts amoadd-read old=0, neither becomes the releaser, both spin forever at
0x800007b8 (DRAM `count` stuck at 1; root-caused with a per-event `$display` trace of ARM /
REMOTEHIT / WRITE on the barrier line). FIX: a real AMO / SC commit (`store_drive && c_is_amo`;
LR never store_drives) drives the dcache write LIVE off the commit store path
(`amo_commit_live ? dmu_dmem_addr/dc_i_wen/dc_wen_excl/… : m_*_q`), so the write, its hit_excl
ownership gate, the poison check (commit_store_fire excludes the registered replay) and the
retire all COINCIDE in one cycle — byte-identical to MEM_PIPE=0. AMOs are excluded from the
M3a `store_fetched_q` retire gate (`!c_is_amo`) and from the M-stage read at their commit
cycle (`!amo_commit_live` on dmem_ren_m). Plain slow stores keep the M3a 2-cycle path.
(Gating the registered write by a LIVE recall signal instead would close a dcache
i_wen→o_chk3_present→amo_remote_hit combinational loop — the live-write approach avoids it.)

🔬 **Flip gates ALL GREEN: default 251/251, litmus N2 (cy 2.27M, 46 replays = recall races
now poison→replay) + N4 (cy 5.4M), N2 SMP Linux boot (cy ~16.5M).** DEAD (MEM_PIPE=0):
default 251/0 + N1 boot cy byte-identical (all fixes are MEM_PIPE-gated).

— (historical root-cause notes below) —

🔬 **Root cause CONFIRMED (the AMO read at execute is stale):** `alu_wrap` computes the
AMO RMW combinationally from `i_load_data` (= `dcache_rdata`) AT the execute cycle
(`amo_old_algn = i_load_data >> {amo_byte_off,3'b0}`, `alu_wrap.veryl:275`; old→rd,
new→commit-write). At MEM_PIPE=1 the dcache reads the AMO's PA only the NEXT cycle (the
registered `m_pa_q`), so at the execute cycle `dcache_rdata` is the PRIOR access's data
→ wrong old value → wrong result + wrong commit-write. Need a 2-cycle AMO read
handshake (translate cycle → read+compute cycle), the LSR pattern but for the alu_wrap
blocking AMO. (The AMO commit WRITE side — `dc_wen_excl`→`m_wen_excl_q`, M1 — is c_is_store
&& !sb_elig, so M3a's `store_fetched_q` ALREADY gives it a translate cycle; verify that
suffices.) LR loads have the same execute-read staleness; SC writes via the store path.

Signal map (file:line, heliodor_core.veryl unless noted):
- AMO read at execute: `dc_amo_read` 5430 → `i_amo_read` 6481 (= `dmem_amord_m && !replay_drive`;
  at flip `dmem_amord_m`=`m_amo_read_q`, +1). alu_wrap old-value read: `amo_old_algn`
  `alu_wrap.veryl:275` (reads `i_load_data`=`dcache_rdata`, combinational).
- AMO watch (FINE — issue-time translated PA, combinational, no M-stage): `amo_watch_pa_q`
  5021 = `dmu_dmem_addr` on `amo_exec_capture` 4945; `i_chk3_addr` 6540, `dc_amo_present` 6541.
- AMO commit write: `dc_wen_excl` 6282 → `i_wen_excl`/`dmem_wexcl_m` (M1, +1). Retire gate:
  `commit_amo_replay` 3208, `rob_commit_ack` 3264 (M3a `store_fetched_q` term applies).
- LR/SC: `sc_walk_drive` 5412, reservation `rsv_pa_q`/`sc_watch_addr_q` (`i_chk_addr`/`i_chk2_addr`
  6.5k). `dc_amo_read` excludes SC (SC reads nothing; only the fault-walk matters).
- Likely approach: a `amo_fetched_q` (mirror `mem_fetched_q`/`store_fetched_q`) that holds
  the alu_wrap AMO/LR execute one cycle so it reads `dcache_rdata` AFTER the M-stage access.
  The AMO is at the ROB head (oldest) so the execute handshake is simpler than a general load.

Gate ladder EVERY sub-step: default + litmus N2/N4 + N2/N4 SMP boot (SMP atomicity — the
+1cy-commit amoadd wedge, cp_pipelining_strategy.md §3.D, is invisible single-hart).

**M4 — flip ON (`MEM_PIPE=1`) + full corner-debug.** Expect memory-ordering
corners (the FR flip's lesson: trace with $display, bisect with sub-params).

### Gate ladder (every flip/behavioral step — memory ordering not separable)
default 251/0 + `--backend-validate` + N1 boot cy + litmus N2/N4 + N2/N4 SMP boot
+ Verilator SMP. The +1-cycle-commit failure (strategy §3.D) is the cautionary
tale — SMP atomicity breaks silently on single-hart tests; only litmus/SMP catches
it. Run litmus N2 + N2 SMP every M3/M4 sub-step.

## 6. Status
- 2026-06-28: plan seeded after the FR campaign converged (commit `48b147a`, CP
  25.105→20.395). Map done (§2).
- 2026-06-28: **M1 DONE (dead, committed).** M-stage register (13 fields, effective
  execute-path dcache inputs) + dcache read-mux, `const MEM_PIPE: bit = 0`. Gates:
  default 251/0, N1 boot 4/4 (cy byte-identical 7.1V=012e46d0 / 6.6=013ec190 /
  7.1=01206420 / smoke=00b630a0), synth 20.395/206lv/head→n_inflight UNCHANGED.
  Temp-flip synth = 20.395→16.470 (megacone cut, new front = VU-integer datapath
  head→vrf — see §5 M1 finding). All in `src/core/heliodor_core.veryl`.
- 2026-06-28: **M2 DONE (dead, committed).** `mem_fetched_q` VU 2-cycle handshake,
  `param MEM_PIPE` from the core. Gates: default 251/0, N1 boot 4/4 cy byte-identical,
  synth 20.395 unchanged. Flip-test: 18/19 vector tests pass (VU handshake validated);
  vleff fails on the PTW-walk M-stage interaction → new step M2.5.
- 2026-06-28: **M2.5 DONE (dead, committed).** Clean walk-dcache bundle from dmem_mmu;
  live PTW under MEM_PIPE. Gates: default 251/0, N1 boot 4/4 cy byte-identical, synth
  20.375. Flip: 19/19 vector PASS; full default 224/27, the 27 = exactly the M3 scope.
- 2026-06-28: **M3a DONE (dead, committed `f4f1e3d`).** `store_fetched_q` slow-store
  commit 2-cycle retire gate. Flip default 224→235/251 (all plain-store + misaligned +
  zfhmin pass); remaining 16 = AMO/LR-SC + litmus_2hart.
- 2026-06-28: **M3b DONE (dead, committed).** AMO/LR `amo_fetched_q` 2-cycle read
  handshake + tail-RFO elimination + **LIVE AMO/SC commit write** (`amo_commit_live`).
  🚨 The planned "let M3a's store_fetched_q give the AMO commit a translate cycle" was
  WRONG: a registered M-staged AMO commit write fires stale on a remote recall (the
  live-hit_excl vs registered-input skew) with the poison registering too late — the
  litmus N=2 sense-barrier lost-update wedge (root-caused via $display trace of the
  DRAM `count` at 0x80002000). Fix = AMO/SC commits write SINGLE-CYCLE LIVE off the
  commit store path, byte-identical to MEM_PIPE=0 (write + hit_excl + poison + retire
  coincide). Gates: **flip default 251/251, litmus N2 (2.27M) + N4 (5.4M), N2 SMP
  Linux boot (16.5M) all pass** (see §5 M3b). DEAD (MEM_PIPE=0): default 251/0, N1
  boot cy byte-identical, synth unchanged. All in `src/core/heliodor_core.veryl`.
- Next: **M4 — flip ON (`MEM_PIPE=1`).** All 27 flip failures fixed (M3a+M3b); the flip
  atomicity matrix is green. M4 = set `MEM_PIPE=1` permanently + re-synth (expect CP
  20.4→~16.5) + the full regression at the new IPC point (boot cy + CoreMark/Dhrystone)
  + Verilator SMP. Reminder: post-flip floor is the VU-INTEGER datapath (~16.5 ns);
  pushing below that needs a separate VU-integer operand pipeline (à la VFP_PIPE), OOS here.
