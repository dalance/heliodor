# CP — cut the commit-store/dcache-fill WALL (the campaign's gating front)

The user chose (2026-06-30) to **cut the wall first**, before the keystone. This is the
concrete implementation plan, grounded in this session's measurements.

Entry: master `41dc569` / tree at **P1' `7598185`** (the verified store TLB probe, DEAD).
CP **15.300 ns**.

## 0. What the wall is (MEASURED, `veryl synth --timing-paths 80`)

The top **~200** endpoints are ALL the commit-store/dcache-fill front:
- `head[0] → n_inflight[0..5]` — **15.01–15.300** (the free-list / commit decision).
- `head[0] → valid_1[0..63]`, `valid_3[*]` — **14.870** (every bit of two 64-bit dcache
  **way-valid** words = the dcache **fill/invalidate**).

`rs1_rdy` (14.565, the keystone floor) is **not in the top-80** — masked. So **nothing**
below 14.87 (keystone, Phase B, …) shows on synth CP until this whole wall falls.

Both fronts share one combinational sweep from the ROB head:
```
head → arch_regs/cas compare → commit_store_fire → store/AMO VA → core_dmem_vaddr
     → u_dmem_mmu TLB translate (dmu_dmem_addr / fault)
     → { commit decision (fault → commit_excp → rob_commit_ack) → n_inflight }      (15.300)
     → { dcache index → hit_* (tag cmp) → valid_*[index] invalidate / fill }         (14.870)
```
- `n_inflight` tail: the live store/AMO **fault** (`dmem_mmu_fault_s`/`acc_fault_s` →
  `commit_store_sfault`/`sacc` → `commit_excp`) gates the commit → free-list. `core.veryl:3778`.
- `valid_*` tail: a **write-through** store (AMO/LR-SC, misaligned, MMIO, slow) drives the
  dcache port LIVE at commit (`core_dmem_wen=store_drive`, addr `dmu_dmem_addr`); the index +
  `hit_*` tag compare clears `valid_w[index]` (invalidate) / sets it (fill). `dcache.veryl:944-963`.

## 1. Why P3 only moved it 0.41 ns

The P3 flip (`cp_commit_store_pretranslate_plan.md §4.1`) routed the **plain** store's
`sb_vm_ok`/`sb_pa` to the registered probe PA, cutting the plain-store `n_inflight` piece
(→14.890). But it left standing:
1. the **AMO/SC** commit translation (atomicity → single-cycle live MMU) feeding both fronts,
2. the **valid_\*** dcache invalidate/fill (the write-through stores still drive the dcache
   live from `dmu_dmem_addr`),
3. and it **broke the boot** by forcing non-pre-translated cacheable stores onto the slow
   M-stage path (lost store).

So the headline stayed at the next plateau. **To drop the wall, ALL three must register.**

## 2. The unifying principle

**No committing store/AMO may use a live-MMU PA in the same cycle it feeds the commit
decision OR the dcache write.** Every store/AMO commit drains a **registered** PA. Then
`head → … → MMU` leaves both the `n_inflight` and `valid_*` cones; the new wall floor is
`redirect_pc_q` (14.8) → `rs1_rdy` (14.565), where the keystone takes over.

The MEM_PIPE M-stage already registers the **slow-store** write (`m_pa_q`/`m_wen_q`,
`core.veryl:1577+`). The gaps are: plain fast stores (SB path, must not regress), the
non-pre-translated cacheable store (P3 boot bug), and the LIVE AMO/SC commit.

## 3. The three sub-steps (each: DEAD param-gate → flip → full gate ladder)

### W1 — plain stores: pre-translate + 2-cycle registered SB push for the miss case
- Pre-translated plain DRAM store (`c_pretx_fast`, P1' probe): commit drains `c_store_pa`
  to the SB in 1 cycle, no MMU. (The P3 logic, minus the broken fallback.)
- **Non-pre-translated cacheable VM store** (TLB-hit at commit, missed at execute): do NOT
  force it to the M-stage write (the P3 boot bug — that path can't write-allocate a cacheable
  line). Instead **register its commit MMU translation one cycle (a new 2-cycle *SB-push*
  path), then SB-push the registered PA** — so it still goes to the SB (correct) but with a
  registered PA (front cut). Distinct from the M-stage *dcache-write* slow path.
- Result: every plain store SB-pushes a registered PA → plain-store `n_inflight` + (no
  dcache drive) cut. Gate: ACT4 + litmus + SMP + the boot that P3 failed.

### W2 — AMO/SC: pre-translate the PA, keep the atomic RMW write live at commit
- The atomicity constraint is on the **write** (a +1-cy AMO commit-write slip broke litmus
  N2 — `project_heliodor_lsu_pipelining` M3b). The **translation** can move to execute:
  latch the AMO's probe PA (extend P1' to AMOs — they issue at ROB head, so the probe is
  even simpler) and drive the atomic dcache RMW from the **registered** PA at commit. The
  write still fires in the single commit cycle; only the VA→PA translate is pre-done.
- Risk: **critical** (SMP atomicity). Gate every sub-step on litmus N2/N4 + SMP. This is the
  hardest correctness piece of the wall.

### W3 — dcache fill/invalidate (`valid_*`) fed from the registered PA
- Once W1+W2 register the PA, the dcache write port (`core_dmem_wen`, addr) for every
  committing store/AMO is a registered PA, so `dcache.veryl`'s `index`/`hit_*`/`valid_*`
  consume a flop, not `head→MMU`. Confirm the misaligned (`i_wstrb_hi`) invalidate and the
  AMO RMW both index off the registered PA. The `valid_*` 14.870 front then drops.
- This is largely a *consequence* of W1+W2 (same registered-PA source), not separate RTL —
  but verify with synth that all 128 `valid_*` paths leave the MMU.

## 4. Expected trajectory (synth)
`15.300 → ~14.8` (after W1+W2 drop n_inflight & valid_*; redirect_pc_q surfaces) `→ ~14.565`
(after redirect_pc_q, the rs1_rdy keystone floor surfaces) → **keystone** for below.
IPC cost: the non-pre-translated store's +1-cycle SB push + (AMO translate-at-execute is
latency-neutral). Measure boot-cy / CoreMark / Dhrystone vs the ~10–15 % budget.

## 5. Gates (every sub-step — memory ordering is not separable)
default 251/0 · `--backend-validate` · **ACT4 696/696** · litmus N2/N4 · N2/N4 SMP boot ·
Verilator SMP · the **N1 boot that P3 failed** (the cacheable-store corner). Dual metric:
synth CP + IPC, judged NET.

## 6. Anchors
- `dcache.veryl:944-963` write-through invalidate (`valid_*`), `:342-345` hit, `:245-248`
  valid arrays.
- `core.veryl:3778` commit_store_sfault/sacc → commit_excp → n_inflight; `:5145`
  commit_store_fire; `:5319` store_drive; `:1577+` MEM_PIPE M-stage (`m_pa_q`/`m_wen_q`);
  `:6548` amo_commit_live.
- P1' probe: `mmu.o_sprobe_*` / `dmem_mmu.o_sprobe_*` / `store_pretx_*` (`7598185`).
- `cp_commit_store_pretranslate_plan.md §2.1/§4.1` (the premise correction + P3 result).
- `speculative_wakeup_design.md §1.0a/§1.0b` (the 200-path wall + CDB-register conflict).

## 7. ✅✅ RESULT (2026-06-30) — the wall was ONE dead AMO signal; cut byte-identically, 15.300 → 14.565

**The W1/W2/W3 pre-translate framing above was unnecessary.** Tracing the real worst path
(`--dump-timing`) showed the 15.300 `n_inflight` endpoint (and the 14.870 `valid_*` plateau)
does **not** ride a plain-store translation — it rides the **AMO commit's `dmem_wstrbhi_m`
arm** (`core.veryl:6601`):

```
head → arch_regs (amocas.q compare) → commit_store_fire
     → core_dmem_vaddr → u_dmem_mmu TLB → PMP-W → dmem_mmu_acc_fault_s
     → sb_vm_ok → dc_i_wen → dc_st_wstrb_hi                 ← the LIVE MMU dependency
     → [mux dmem_wstrbhi_m: amo_commit_live ? dc_st_wstrb_hi : m_wstrbhi_q]
     → u_dcache.i_wstrb_hi → mis_active → dcache state/stall
     → rob_commit_ack → commit_excp → n_inflight (15.300)   AND  → valid_* (14.870)
```

At `MEM_PIPE=1` the AMO commit already drains a **registered** PA (`ac_pa_q`) and a
registered write-OK (`ac_wok_q`); the address/wen/wdata left the MMU in M3b/M4. The **one**
straggler was `dmem_wstrbhi_m`, whose `amo_commit_live` arm still pulled the **live**
`dc_st_wstrb_hi`. And `dc_st_wstrb_hi = dc_i_wen ? st_wstrb_hi : 0`, where `dc_i_wen` pulls
the live MMU `acc_fault` through `sb_vm_ok`. That single live net **was the entire wall** —
both the `n_inflight` (via the dcache stall cone → `rob_commit_ack`) and the `valid_*`
(via the dcache fill) endpoints.

**It is functionally dead.** A committing AMO/SC is ALWAYS naturally aligned (a misaligned
atomic faults at issue, never reaching `amo_commit_live`), so `st_wstrb_hi = st_mask_ext[15:8]`
is provably 0 (the mask never straddles a dword); amocas.q's hi dword sits in the same 64B
line (16B-aligned) and writes via `i_wen_excl_q`/`cas_q_new_hi`, not the misaligned hi-strobe.
So `dc_st_wstrb_hi ≡ 0` whenever `amo_commit_live`.

**Fix (one line, `core.veryl:6601`):** tie the atomic arm to constant `8'd0`:
```
dmem_wstrbhi_m = MEM_PIPE ? (ptw_dc_active ? 0 : (amo_commit_live ? 8'd0 : m_wstrbhi_q)) : dc_st_wstrb_hi;
```
**Synth: 15.300 → 14.565 ns** (the whole `head → MMU → {n_inflight, valid_*}` wall drops to
the `pc_q → rs1_rdy` keystone floor in one shot). **Byte-identical**: default `veryl test`
252/0 (incl. litmus N2 + rv64ua), N1 boot 4/4 with **7.1 cy=01210060 matching the pre-fix
baseline exactly**, litmus N4 + N2 SMP boot byte-identical (atomicity unaffected — only a
provably-0 strobe changed). No pre-translate, no IPC cost, no 2-cycle SB push.

**→ Consequence:** the wall is gone; `rs1_rdy` (14.565) now surfaces and the **keystone**
(`speculative_wakeup_design.md`, the campaign's real ~80 % lever) is finally measurable on
synth CP. W1 (plain-store pre-translate) and the P1' probe scaffold (`7598185`) are
**unnecessary for the wall** and can be dropped or repurposed; the plain-store `n_inflight`
front was never the headline. Next: the keystone (execute-staging / scheduled wakeup).
