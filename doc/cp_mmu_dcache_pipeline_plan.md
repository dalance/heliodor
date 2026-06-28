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

**M1 — M-stage register + dcache read-mux, param-gated DEAD (`MEM_PIPE=0`).** Add
the regs + the `if MEM_PIPE ? m_*_q : …` arms on the dcache i_addr/i_ren/i_uncached
/i_wen/i_wdata/i_wstrb. Capture from the MMU output each cycle. Gate: build
byte-identical + default 251/0 + N1 boot cy unchanged + synth 20.395 unchanged.

**M2 — VU 2-cycle handshake under MEM_PIPE.** vu_mem_ready / mem_state absorb the
extra cycle; i_mem_rdata reads the dcache the cycle after translate. Still dead at
MEM_PIPE=0. Flip-test VU in isolation (vector tests + V-boot).

**M3 — slow-store + AMO commit retire gates on M-stage write completion.** The
high-risk atomicity work. rob_commit_ack must wait for the M-stage dcache write
(mirror lsr_complete). amo_watch_pa_q / pin / LR-SC shift +1 coherently.

**M4 — flip ON (`MEM_PIPE=1`) + full corner-debug.** Expect memory-ordering
corners (the FR flip's lesson: trace with $display, bisect with sub-params).

### Gate ladder (every flip/behavioral step — memory ordering not separable)
default 251/0 + `--backend-validate` + N1 boot cy + litmus N2/N4 + N2/N4 SMP boot
+ Verilator SMP. The +1-cycle-commit failure (strategy §3.D) is the cautionary
tale — SMP atomicity breaks silently on single-hart tests; only litmus/SMP catches
it. Run litmus N2 + N2 SMP every M3/M4 sub-step.

## 6. Status
- 2026-06-28: plan seeded after the FR campaign converged (commit `48b147a`, CP
  25.105→20.395). Map done (§2). Implementation not started.
- Next: M1 (M-stage register, dead). Then M2/M3/M4.
