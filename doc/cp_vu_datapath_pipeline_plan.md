# CP next front — VU (vector unit) datapath pipeline

Status: PLAN (RTL not started). Follows the MEM_PIPE campaign (committed CP
25.105 → 17.040 ns). Goal: cut below the **16.47 ns VU-datapath floor**.
User-approved direction (2026-06-29): proceed with the VU integer/mem pipeline,
accepting vector IPC cost.

## Where the 17.04 ns CP actually is (synth measurements, this session)

The committed critical path is `head[0] → n_inflight[5]` at 17.040 ns / 175
levels, routed: VU element address → shared MMU → store-commit gating →
free-list `n_inflight`. But that is **not** the real bottleneck:

- **Register the MMU input VA** (temp `i_vaddr = cdv_q`) → CP **16.470 ns**,
  endpoint moves to `head[0] → vrf[63]`. So the whole MMU + commit megacone is
  only **0.57 ns above** the VU floor — cutting it alone buys almost nothing.
- The real floor is the **VU combinational datapath** (`head → … → vrf[63]`),
  which never touches the MMU.

So the headline is set by the VU, and to move it we must pipeline the VU.

## The two VU sub-paths (both ~16.5–17 ns, they mask each other)

### A. Compute path — 16.47 ns (`head → vrf[63]`), the floor
```
head → fifo_instr (decode: h_funct6 / h_is_opm/narrow/widen)
     → h_vs1 → u_vrf.vrf → i_vs1_data            (VRF read port 1)
     → pm_vrg_idx (vrgather index from vs1)
     → i_vs2_data[63]   ← 5.71 → 13.50 ns  (~7.8 ns!!)   <-- DOMINANT
     → i_vdold_data → vsew → valu_res (integer ALU)
     → vrf[63]                                   (VRF write)
```
The **~7.8 ns dominant chunk is the vrgather data-dependent VRF read**: the read
index for vs2 (`pm_vrg_idx`) is computed from vs1, so `i_vs2_data` is a dynamic
(data-indexed) VRF select. This is the permute (vrgather / vcompress) datapath,
not the plain integer ALU — the ALU (`valu_res`) is only the ~1.5 ns back-end.

### B. Mem path — 17.04 ns (`head → … → MMU → commit → n_inflight`)
```
head → fifo → PRF (i_scalar2_data = stride)
     → i_scalar2_data * velem64   (strided-address 64b MULTIPLY, ~2.4 ns)
     → m_vaddr (= m_base + offset) → o_mem_vaddr → core_dmem_vaddr
     → MMU: tlb_vpn / tlb_level / tlb_valid (assoc match ~4.3 ns)
          + u_pmp_amo_w (AMO-write PMP ~2.2 ns) → acc_deny       (~6.6 ns total)
     → commit_store_fire → dcache i_wen → commit/trap/redirect
     → rob_commit_ack → u_fl.n_inflight ripple
```
The MMU translate (~6.6 ns) is the single biggest block, shared by every memory
op. MEM_PIPE registered the MMU *output* (PA → `m_pa_q`); the MMU *input* VA
(velem → multiply → m_vaddr) is still live. The `acc_deny → commit_store_fire`
tail is suspected **false path** (when the VU drives the port `vu_mem_active=1`,
`commit_store_fire` is gated off — mutually exclusive), but veryl synth does not
prune it.

## Cuts (multi-front; the headline only moves when the near-16.5 fronts are all cut)

1. **vrgather/permute dynamic read** (highest leverage, the 7.8 ns chunk):
   register the gather index (`pm_vrg_idx`) after computing it from vs1, then do
   the dynamic vs2 read + result the next cycle. vrgather/vcompress +1 cy/elem.
2. **VU mem-address → MMU input**: register `m_vaddr` (the VA) before the shared
   MMU — extend MEM_PIPE's PA-latch to a VA-latch (a VU mem FETCH that registers
   the address, not just the post-translate PA). vector mem +1 cy/elem.
3. **Integer ALU back-end** (`valu_res`) and the strided-address multiply — fold
   into the operand-register FETCH stage if still on the path after 1+2.

## Template: VFP_PIPE (already pipelines the VU *FP* datapath)

`vector_unit.veryl` `fp_state==COMPUTE` adds a FETCH phase gated by
`param VFP_PIPE`: when `!fp_fetched_q` it latches the FP operands
(`fp_s1/2/3_q`, `fp_int_rs1_q`) and does NOT issue u_vfpu (gated on
`fp_fetched_q`); `present` runs next cycle on the registered copies; dead at
VFP_PIPE=0 (cycle-exact). The integer analog is `VINT_PIPE`: a FETCH phase in
the integer/permute COMPUTE FSM (`pm_state` / the valu element walk) that
registers the VU integer operands + the gather index before the deep compute.
MEM_PIPE's `mem_fetched_q` is the template for cut #2 (the VU mem element
already 2-phases FETCH/ACCESS — extend the FETCH to also register the VA).

## Workflow (same as MEM_PIPE / VFP_PIPE)

dead param scaffold (`VINT_PIPE` etc., built at 0 = cycle-exact)
→ synth-measure each cut (FF-insertion: CP drop + which front is exposed next)
→ flip together (multi-front) + full gate ladder
→ corner-debug (the +1-shift element-loop / writeback timing).

## Risks / open questions

- **False paths**: both the 17.04 (VU-vaddr + scalar-commit tail) and parts of
  the 16.47 (vrgather-index + valu_res) may combine mutually-exclusive ops. Use
  the FF-insertion test (synth CP **and** the full test matrix, per
  feedback_ff_insertion_falsepath_test): all-green = false/multicycle (cut was
  harmless); breakage = real, needs a proper handshake like VFP_PIPE/MEM_PIPE.
- **Multi-front masking**: A and B are within 0.57 ns; cutting one exposes the
  other. Expect the headline to barely move until both (and the shared MMU's
  ~6.6 ns, if real) are cut — accept no-gain intermediate steps
  (feedback_commit_to_structural_cp_change).
- **IPC**: vector integer / permute / mem ops +1 cy/element. VU-active only, so
  scalar-dominated workloads (boot, most ACT4, litmus) are unaffected; the
  7.1-V boot and the inline `test_arch_v*` vector tests are the IPC witnesses.
- **MUST gate ACT4** (`veryl test --ignored --test test_act_`) into every flip
  measurement — MEM_PIPE's S-mode+paging corner proved the default ladder is
  not sufficient.

## Validated synth measurements (FF-insertion, this session) — the campaign is de-risked

Temp registers inserted (synth-only, reverted) to measure the achievable floor:

| cut(s) registered                          | CP (ns) | endpoint                | exposed front |
|--------------------------------------------|---------|-------------------------|---------------|
| none (committed)                           | 17.040  | head → n_inflight[5]    | VU mem path   |
| MMU input VA (`core_dmem_vaddr`)           | 16.470  | head → vrf[63]          | VU compute    |
| VRF rd-addr (`vu_vs2_addr`)                | 17.040  | head → n_inflight[5]    | VU mem (back) |
| **BOTH** (MMU input + VRF rd-addr)         | **14.565** | **pc_q → rs1_rdy[0]** | **scalar issue/wakeup** |

So: the two VU fronts mask each other (cut one, the other re-emerges at ~16.5–17);
cut **both** → **14.565 ns (−14.5%)** and the endpoint leaves the VU entirely for
the scalar front-end (`pc_q → … → rs1_rdy`, the rename/issue/scheduled-wakeup
dependency). That scalar path (14.57 ns) is the floor *after* this campaign — the
next front beyond VU. The "register `vu_vs2_addr`" cut is a uniform VRF-read
pipeline stage (all vector reads +1 cy); the proper impl may instead be a
permute-specific FETCH (gather-index register) if vrgather is the only deep
dynamic read — to be decided when implementing cut #1.

**Conclusion: the VU pipeline is worth ~2.5 ns (−14.5%) but ONLY if both fronts
are cut together** (a one-front cut moves the headline 0.0–0.6 ns = mole-whack).

## Verification gates (per flip)

default 251/0 · **ACT4 696/696** · backend-validate · N1 boot 4/4 (incl 7.1-V) ·
inline `test_arch_v*` vector · litmus N2/N4 · N2/N4 SMP boot. Cycle counts:
the campaign is NOT cycle-exact for vector ops (element latency +1) — verify
vector correctness, not cycle identity; scalar boot cy should stay identical
(VU dead) as the no-regression check.

## Implementation result (param `VINT_PIPE`, vector_unit.veryl)

Implemented + flipped. **CP 17.040 → 15.300 ns (−10.2%)**, not the 14.565 the
FF table above predicted. The gap is structural, not a bug:

- **cut #1** = a FETCH phase in the permute COMPUTE FSM (`pm_need_fetch =
  VINT_PIPE && h_is_perm`) that registers the UNIFIED source register
  (`pm_src_reg`) + in-register offset (`pm_src_bitoff`) + OOB, so `o_vs2_addr`
  starts at a register for vrgather AND slide (the first flip pinned at 15.87 ns
  via a false combine: slide's `scalar→sidx→sreg` source address feeding the
  VRF read whose data feeds the integer ALU `bbcast/valu` — mutually exclusive
  ops veryl synth doesn't prune). vcompress takes the same FETCH for uniformity.
- **cut #2** = a VADDR phase in the mem ACCESS FSM that latches `m_vaddr` into
  `mem_va_q` with `o_mem_active` gated off (the VADDR gap is safe — the port is
  held so scalar load issue is blocked, and the VU op is the ROB head so no
  scalar store commits), then the FETCH drives the REGISTERED VA into the MMU.
  The store write stays M-staged and lands the correct PA in ACCESS.

After both cuts the VU is no longer the bottleneck — the endpoint moves to the
**scalar commit-store megacone** (`commit_store_fire → core_dmem_vaddr → MMU →
n_inflight`) at 15.300 ns. The FF table's 14.565 registered the SHARED
`core_dmem_vaddr` (the MMU input), which also cuts the scalar store-commit VA;
my cut #2 only registers the VU's own `mem_va_q`. Cutting the scalar
store-commit VA = deferring the commit decision by a cycle = the commit
pipeline, which the MEM_PIPE campaign proved breaks SMP atomicity (the +1 cy
amoadd wedge). So **15.300 ns is the real VU-campaign floor; 14.565 needs the
separate, SMP-risky commit-store pipeline** (next front).

**IPC cost (measured):** N1 7.1-V boot cy 013c5090 → 013cc5c0 = **+0.13 %** (the
kernel uses little vector mem/permute). Permute / vector-mem ops are +1 cy/elem,
hidden by OoO in scalar-dominated workloads.

**Gates (flip, all green):** default 252/0 · ACT4 696/696 · backend-validate
vector 20/20 (cc/cranelift) · vector 20/20 (incl. new `test_arch_vperm`) ·
N1 7.1-V boot · litmus N2/N4 · N2/N4 SMP boot. Dead (VINT_PIPE=0): default
252/0 · synth 17.040 unchanged · N1 boot cy byte-identical.
